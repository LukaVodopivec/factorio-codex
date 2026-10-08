import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { Bridge, DEFAULT_TASK_TIMEOUT_MS } from "../bridge.js";
import { RconClient } from "../rcon.js";
import { assertConnectionCompatibility, assertRuntimeCompatibility } from "../compatibility.js";
import { companionVersion, diagnoseConfig, type ConfigDiagnostic, type RconSettings } from "../config.js";
import { createOrdersTracker, createPackageQueue, packageFailures, readPackageQueue, type RunDir } from "../coordination/orders.js";
import { currentRunDir } from "../server/server.js";
import { eventSummary, nextEventSchema, RESEARCH_IDLE, researchIdleProblem, waitForEvent, type FailureDelivery } from "./events.js";
import { normalizeObservation } from "./observation.js";
import { areaFields, areaIssue, blueprintName, blueprintPlaceFields, blueprintPlaceIssue, captureFields, configureFields, copySettingsFields,
  createPlatformFields, deconstructFields, deconstructIssue, entitySettings, executeRunPlan, exploreFields, INSPECT_LIMIT, insertFields, insertIssue, inventoryRole,
  launchRocketFields, layoutFields, layoutIssue, moveEntityFields, planStatusSchema, platformRouteFields, platformSelector, queuePlanSchema, requestsFields, requestsIssue,
  routeIssue, runPlanSchema, settingsIssue, surfaceRef, tilesFields, tilesIssue, travelFields, upgradeFields, waitForPlanStatus, type RunPlanResult } from "./runPlan.js";
import { normalizeActivityLog, normalizeCanPlace, normalizeConfigured, normalizeFactoryStatus, normalizeFifo, normalizeInspection, normalizeMapSummary, normalizePhysicalRoute, normalizePlacementSearch, normalizePlanDiagnostics, normalizePlatformStatus, normalizeProductionRequirements, normalizeRequests, normalizeRoute, luaArray, planStatusSummary, queuedPlanSummary, toolPayloads } from "./toolPayloads.js";

export { normalizeObservation, toolPayloads };
export const MCP_SERVER_VERSION = companionVersion();

const position = z.object({ x: z.number(), y: z.number() }).strict();
const beltToGroundType = z.enum(["input", "output"]).optional();
const items = z.record(z.string(), z.number().int().positive());
const walkInput = position.extend({ arrival_mode: z.enum(["exact", "vicinity"]).default("exact"),
  arrival_radius: z.number().min(0.5).max(6).default(1) }).strict()
  .refine((p) => p.arrival_mode === "vicinity" || p.arrival_radius === 1,
    { message: "exact arrival uses the fixed 1-tile tolerance; use vicinity for a wider radius", path: ["arrival_radius"] });
// The wait that follows a queued or running plan, anchored one tick before the
// mod's tick: a plan that ends before the wait starts (even in that tick)
// returns plan_ended instead of queue_empty.
function nextEventAfter(tick: unknown) {
  const since = typeof tick === "number" && Number.isInteger(tick) ? { since_tick: Math.max(0, tick - 1) } : {};
  return { tool: "next_event", arguments: { timeout_seconds: 60, ...since } };
}
export function result(value: unknown, isError = false) {
  const raw = value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : { status: isError ? "failed" : "completed", terminal: true, summary: String(value), next_action: null };
  const fifo = normalizeFifo(raw.fifo);
  const structured = fifo ? { ...raw, fifo } : raw;
  const observationSummary = typeof structured.tick === "number" && Array.isArray(structured.entities)
    ? `observation tick ${structured.tick}; entities ${structured.entities.length}` +
      `${typeof structured.omitted_entities === "number" ? ` (+${structured.omitted_entities} omitted)` : ""}; ` +
      `resources ${Array.isArray(structured.resource_patches) ? structured.resource_patches.length : 0}` +
      `${typeof structured.omitted_resource_patches === "number" ? ` (+${structured.omitted_resource_patches} omitted)` : ""}; ` +
      `ground items ${Array.isArray(structured.ground_items) ? structured.ground_items.length : 0}` +
      `${typeof structured.omitted_ground_items === "number" ? ` (+${structured.omitted_ground_items} omitted)` : ""}`
    : undefined;
  const summary = typeof structured.summary === "string" ? structured.summary
    : typeof structured.detail === "string" ? structured.detail
    : typeof structured.error === "string" ? structured.error
    : typeof observationSummary === "string" ? observationSummary
    : typeof structured.status === "string" ? structured.status
    : "structured result";
  const text = fifo?.hint ? `${fifo.hint}; ${summary}` : summary;
  return { content: [{ type: "text" as const, text: text.slice(0, 500) }], structuredContent: structured, isError };
}

function failure(error: unknown, prefix = "Error") {
  const message = error instanceof Error ? error.message : String(error);
  return result({ status: "failed", terminal: true, code: "TOOL_ERROR", summary: `${prefix}: ${message}`, next_action: null }, true);
}

/** Optional map_summary sections; each adds a top-level key of the same name
 *  (flows_all adds force_flows_all), scoped to charted chunks. */
export const MAP_SUMMARY_SECTIONS = ["stockpiles", "sites", "patches", "power", "problems", "flows_all"] as const;
/** logistics is read only when named; platforms is absent until a platform
 *  exists, elsewhere while the factory stands on one surface. */
export const FACTORY_STATUS_SECTIONS = ["lines", "problems", "power", "stock", "research", "body", "patches", "logistics", "platforms", "elsewhere"] as const;

export type McpSurface = "full" | "read-only";
/** Who runs this MCP process, named in the origin of every cancel it makes:
 *  the session launcher passes --role (or FACTORIO_CODEX_ROLE). */
export const SESSION_ROLES = ["pilot", "strategist", "advisor", "supervisor", "unknown"] as const;
export type SessionRole = typeof SESSION_ROLES[number];
export const READ_ONLY_TOOLS = [
  "connect_status", "map_summary", "progression_status", "production_requirements",
  "describe_prototype", "observe_local", "inspect_entity", "plan_status", "can_place", "find_placement",
  "factory_status", "activity_log", "next_event", "build_layout", "connect_entities",
  "blueprint_list", "blueprint_describe", "blueprint_export", "blueprint_place", "place_tiles", "platform_status",
] as const;

export async function connectStatus(
  bridge: () => Promise<Bridge>,
  configDiagnostic: () => ConfigDiagnostic,
  bindCompanion = true,
) {
  const diagnostic = configDiagnostic();
  if (!diagnostic.ok) return result({ status: "offline", terminal: true, summary: `Offline: ${diagnostic.error}`, next_action: null }, false);
  const b = await bridge();
  let ping: any = await b.call("ping");
  assertRuntimeCompatibility(ping, companionVersion());
  if (!ping.companion_exists) {
    if (!bindCompanion) {
      return result({
        status: "connected", app_version: companionVersion(), protocol_version: ping.protocol_version,
        mod_version: ping.mod_version, factorio_version: ping.factorio_version, tick: ping.tick,
        companion_exists: false, companion_ever_created: ping.companion_ever_created,
        companion_dead: ping.companion_dead, read_only: true, ...bodyOf(ping), ...(ping.fifo ? { fifo: ping.fifo } : {}), ...policyErrors(ping), ...handlerErrors(ping),
        summary: "Connected read-only; no living Codex character is currently available",
      });
    }
    await b.call("spawn_companion", {});
    ping = await b.call("ping");
    assertRuntimeCompatibility(ping, companionVersion());
    if (!ping.companion_exists) throw new Error("native player 'Codex' did not provide a living character");
  }
  const away = bodyAway(ping);
  return result({
    status: "connected", app_version: companionVersion(), protocol_version: ping.protocol_version,
    mod_version: ping.mod_version, factorio_version: ping.factorio_version, tick: ping.tick,
    companion_exists: ping.companion_exists, companion_ever_created: ping.companion_ever_created,
    companion_dead: ping.companion_dead, ...bodyOf(ping), ...(ping.fifo ? { fifo: ping.fifo } : {}), ...policyErrors(ping), ...handlerErrors(ping),
    ...(away ? { summary: `Connected; the body is ${away}` } : {}),
  });
}

/** Where the body is, as ping reports it: {state, surface_ref, platform_name?, bound_for?, rebind_refused?}. */
function bodyOf(ping: any): { body?: { state: string; surface_ref?: string; platform_name?: string; bound_for?: string } } {
  return ping?.body && typeof ping.body === "object" ? { body: ping.body } : {};
}
/** A body on a trip is connected but away from any planet: aboard a platform
 *  or in a cargo pod. */
function bodyAway(ping: any): string | null {
  const body = bodyOf(ping).body;
  if (body?.state === "aboard_platform") return `aboard platform ${body.platform_name ?? body.surface_ref}: physical actions fail with BODY_ABOARD until it lands; remote platform tools work`;
  if (body?.state === "in_transit") return `in a cargo pod (now over ${body.surface_ref})${body.bound_for ? `, bound for ${body.bound_for}` : ""}`;
  return null;
}

/** World-policy writes that failed on some surface (peaceful mode, enemy
 *  bases), as ping reports them; absent when there are none. */
function policyErrors(ping: any): { world_policy_errors?: unknown[] } {
  const errors = luaArray(ping?.world_policy_errors ?? []);
  return errors.length > 0 ? { world_policy_errors: errors } : {};
}

/** Errors a mod handler raised and its dispatcher caught, as ping reports
 *  them: the count since the save gained the ring and the newest few
 *  {tick, where, error}; absent when there are none. */
function handlerErrors(ping: any): { handler_errors?: { count: number; recent: unknown[] } } {
  const errors = ping?.handler_errors;
  if (!errors || typeof errors.count !== "number" || errors.count <= 0) return {};
  return { handler_errors: { count: errors.count, recent: luaArray(errors.recent ?? []) } };
}

type ToolRegistrar = {
  registerTool(name: string, config: unknown, handler: (args: any, extra?: { signal?: AbortSignal }) => Promise<unknown>): unknown;
};

function factoryStatusSummary(value: any): string {
  const lines: any[] = Array.isArray(value?.lines) ? value.lines : [];
  const states: Record<string, number> = {};
  for (const line of lines) states[line?.state ?? "unknown"] = (states[line?.state ?? "unknown"] ?? 0) + 1;
  const parts = [`${lines.length} lines${lines.length ? ` (${Object.entries(states).map(([state, count]) => `${count} ${state}`).join(", ")})` : ""}`];
  if (Array.isArray(value?.problems)) parts.push(`${value.problems.length} problems`);
  // Labs stand still: a research_idle problem, or labs with no current research.
  const research = value?.research;
  if (researchIdleProblem(value?.problems) || (research && research.labs?.count > 0 && !research.current)) parts.push(RESEARCH_IDLE);
  if (value?.body) parts.push(`queue ${value.body.queue_depth ?? 0}${value.body.human_control ? ", human hold" : ""}`);
  if (value?.trial) parts.push(`trial ${value.trial.status}, ${value.trial.remaining_seconds} s left`);
  if (Array.isArray(value?.elsewhere) && value.elsewhere.length > 0) parts.push(`${value.elsewhere.length} other surface${value.elsewhere.length === 1 ? "" : "s"} in elsewhere`);
  return `tick ${value?.tick}${typeof value?.surface === "string" ? ` on ${value.surface}` : ""}: ${parts.join("; ")}`;
}

function platformStatusSummary(value: any): string {
  if (value?.platform) {
    const p = value.platform;
    const where = p.location ? ` at ${p.location}` : p.travel ? ` from ${p.travel.from} to ${p.travel.to}` : "";
    if (!value.hub) return `tick ${value.tick}: platform ${p.name} ${p.state}${where}; no hub yet`;
    const missing: any[] = Array.isArray(value.ghosts?.missing) ? value.ghosts.missing : [];
    return `tick ${value.tick}: platform ${p.name} ${p.state}${where}; ${value.foundation?.tiles ?? 0} foundation tiles, `
      + `${(value.entities?.length ?? 0) + (value.omitted_entities ?? 0)} entities, ghosts miss ${missing.length} item kinds`;
  }
  const rows: any[] = Array.isArray(value?.platforms) ? value.platforms : [];
  const count = rows.length + (value?.omitted_platforms ?? 0);
  return `tick ${value?.tick}: ${count} platform${count === 1 ? "" : "s"}${rows.length
    ? `: ${rows.map((row) => `${row.name} ${row.state}${row.location ? ` at ${row.location}` : row.travel ? ` from ${row.travel.from} to ${row.travel.to}` : ""}`).join("; ")}` : ""}`;
}

/** Register the complete public surface against an injectable bridge provider.
 *  Tests use the same handlers with a fake Bridge to prove the exact Lua DTOs.
 *  runDir names the current run, whose ledger supplies the attached orders. */
export function registerMcpTools(
  server: ToolRegistrar,
  bridge: () => Promise<Bridge>,
  configDiagnostic: () => ConfigDiagnostic,
  surface: McpSurface = "full",
  runDir: RunDir = () => null,
  role: SessionRole = "unknown",
): void {
  if ((role === "strategist" || role === "advisor") && surface !== "read-only")
    throw new Error(`${role} requires the read-only MCP surface`);
  const orders = createOrdersTracker(runDir);
  const failureDelivery: FailureDelivery = { keys: null };
  // Every result carries the strategist's orders once per new ledger revision.
  const tools: ToolRegistrar = { registerTool: (name, config, handler) =>
    server.registerTool(name, config, async (args, extra) => orders.attach(await handler(args, extra))) };
  // signal (the MCP request's) stops the poll of a read the game runs as a job.
  const rpc = async (method: any, params: unknown = {}, signal?: AbortSignal) => {
    try { return result(await (await bridge()).call(method, params, signal)); }
    catch (error) { return failure(error); }
  };
  // A remote action on a space platform (its window, no body): one RPC that
  // acts at once and answers with the step's outcome.
  const remote = async (method: any, params: unknown, summary: (value: any) => string, normalize = (value: any) => value) => {
    try {
      const value: any = normalize(await (await bridge()).call(method, params));
      return result({ ...value, status: "completed", terminal: true, summary: summary(value), next_action: null });
    } catch (error) { return failure(error); }
  };
  // A TUI turn interruption aborts the MCP request; the bridge then cancels
  // the owned game task, naming the tool and this process's role in the
  // cancel's origin.
  const task = async (tool: string, type: string, params: Record<string, unknown>, signal?: AbortSignal) => {
    try {
      const terminal = await (await bridge()).enqueueAndWaitResult({ type, ...params } as never, { tool, role, ...(signal ? { signal } : {}) });
      const status = terminal.status === "done" ? "completed" : terminal.status;
      return result({ status, terminal: true, summary: terminal.detail || status,
        ...(terminal.human_control ? { human_control: true } : {}),
        ...(terminal.outcome ?? {}), next_action: null }, status === "failed" || status === "cancelled");
    } catch (error) { return failure(error); }
  };
  const runPlan = async (input: unknown, signal?: AbortSignal, tool = "run_plan") => {
    const parsed = runPlanSchema.parse(input);
    try {
      const outcome = await executeRunPlan(await bridge(), parsed, signal, undefined, tool);
      const terminal = ["completed", "partial", "failed", "cancelled"].includes(outcome.status);
      return result(normalizePlanDiagnostics({ ...outcome, terminal, next_action: terminal ? null
        : nextEventAfter(outcome.source_tick) }),
      outcome.status === "failed" || outcome.status === "cancelled");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const status = signal?.aborted ? "cancelled" : "failed";
      const outcome: RunPlanResult = {
        status,
        outcomes: [],
        observation_error: message,
        execution: { mode: "sequential_nontransactional", rollback: "none", effects_state: "unknown" },
      };
      return result(normalizePlanDiagnostics({ ...outcome, terminal: true, next_action: null }), true);
    }
  };
  // A plan action as one tool: a one-step plan, or its dry run as a read-only mod check.
  const step = (action: string) => async ({ check_only, ...params }: Record<string, unknown>, signal?: AbortSignal) => {
    if (check_only) return rpc(action, { ...params, check_only: true }, signal);
    return runPlan({ steps: [{ action, ...params }] }, signal, action);
  };
  const checkOnly = surface === "full" ? z.boolean().default(false) : z.literal(true).default(true);
  const issue = <T>(check: (value: T) => string | null) => (value: T, context: z.RefinementCtx) => {
    const message = check(value);
    if (message) context.addIssue({ code: "custom", message });
  };
  // A dry run may check another planet's ground while the body is away; a
  // build's surface is the plan's (queue_plan surface).
  const drySurface = (value: { surface?: unknown; check_only?: boolean }) =>
    value.surface !== undefined && value.check_only !== true ? "surface is for the dry run (check_only: true); queue_plan surface sets a build's" : null;
  const layoutSchema = z.object({ ...layoutFields, check_only: checkOnly, surface: surfaceRef.optional() }).strict()
    .superRefine(issue(layoutIssue)).superRefine(issue(drySurface));
  const placeBlueprintSchema = z.object({ ...blueprintPlaceFields, check_only: checkOnly }).strict().superRefine(issue(blueprintPlaceIssue));
  const tilesSchema = z.object({ ...tilesFields, check_only: checkOnly }).strict().superRefine(issue(tilesIssue));
  const routeSchema = z.object({ kind: z.enum(["belt", "pipe", "power"]), prototype: z.string().min(1), from: position, to: position,
    max_length: z.number().int().min(1).max(200).default(200), fluid: z.string().min(1).optional(),
    underground: z.union([z.string().min(1), z.literal(false)]).optional(), check_only: checkOnly }).strict();
  const areaSchema = (fields: Record<string, z.ZodType>) => z.object({ ...areaFields, ...fields }).strict().superRefine(issue(areaIssue));
  const named = z.object({ name: blueprintName }).strict();
  const dryRun = surface === "full" ? " check_only: true is a dry run that builds nothing." : " Dry run only: checks without building.";
  // What a layout dry run reports as data, never as a failure.
  const oreReport = "on_ore (each placement but a drill whose footprint covers resource tiles, with the tiles by resource),"
    + " mixed_ore (each drill whose mining area holds more than one resource it can mine: mines, the one with the most"
    + " tiles, and also, the rest by tile count)";
  const fluidReport = "open_fluid_ports (a planned pump, boiler, engine, tank or other fluid machine with a fluid box no"
    + " planned or existing connection meets, a pipe run's end, a pipe-to-ground's open side; port is the tile it points at)";
  const dryReport = " Its report also lists inserters (picks_from, drops_into: a planned or existing entity, or nothing), belt_ends"
    + " (each belt nothing ahead takes from: a run's end, one facing a reversed belt or an underground exit's back, an"
    + ` entrance with no exit; with what it faces), unpowered machines no pole covers, isolated_poles no wire reaches, ${oreReport}`
    + ` and ${fluidReport}. A planned pipe or other fluid entity that, in build order, would join two fluids already standing`
    + " through the layout's own pipes fails BLOCKED (would join X and Y pipes): the game refuses that placement.";
  // connect_entities plans the route as a read; the build is a direct
  // build_plan task, and a power route is then checked for continuity.
  const connectRoute = async ({ check_only, ...p }: z.infer<typeof routeSchema>, signal?: AbortSignal) => {
    // The whole tool, route search and inspections included, returns under
    // the MCP tool timeout: the build's guard counts from here.
    const started = Date.now();
    const b = await bridge();
    const route: any = normalizePhysicalRoute(await b.call("connect_entities", toolPayloads.connectEntities(p), signal));
    if (check_only) return result({ ...route, check_only: true, status: "completed", terminal: true,
      summary: `route of ${route.steps.length} pieces planned; nothing built`, next_action: null });
    const detail = route.steps.length === 0
      ? "endpoints already have a physical connection"
      : await b.enqueueAndWait({ type: "build_plan", ...toolPayloads.buildPlan(route.steps, { auto_craft: true, stop_on_error: true }) } as never,
        { tool: "connect_entities", role, deadlineMs: started + DEFAULT_TASK_TIMEOUT_MS,
          returnByMs: started + DEFAULT_TASK_TIMEOUT_MS, ...(signal ? { signal } : {}) });
    if (p.kind !== "power") return result({ ...route, status: "completed", terminal: true, summary: detail, detail, next_action: null });

    const ordered = [p.from, ...route.steps.map((step: any) => ({ x: step.x, y: step.y })), p.to];
    const inspected: Array<{ position: { x: number; y: number }; network_id: number | null }> = new Array(ordered.length);
    for (let offset = 0; offset < ordered.length; offset += INSPECT_LIMIT) {
      const points = ordered.slice(offset, offset + INSPECT_LIMIT);
      const response: any = normalizeInspection(await b.call("inspect", toolPayloads.inspect(points)));
      for (let local = 0; local < points.length; local++) {
        const point = points[local]!;
        const entity = response.entities?.[local];
        inspected[offset + local] = { position: point,
          network_id: typeof entity?.electrical?.network_id === "number" ? entity.electrical.network_id : null };
      }
    }
    const missing = inspected.flatMap((entry, index) => entry.network_id === null ? [index] : []);
    if (missing.length > 0) {
      return result({ ...route, placement: { requested: route.steps.length, placed: route.steps.length, complete: true },
        status: "placed_unverified", terminal: true,
        summary: `placed ${route.steps.length}/${route.steps.length}; electrical network evidence missing for ${missing.length} route member(s)`,
        validation: { missing_member_indexes: missing }, next_action: null });
    }
    const firstNetwork = inspected[1]?.network_id ?? inspected[0]?.network_id ?? null;
    const lastNetwork = inspected[inspected.length - 2]?.network_id ?? inspected[inspected.length - 1]?.network_id ?? null;
    const fromCovered = firstNetwork !== null && inspected[0]?.network_id === firstNetwork;
    const toCovered = lastNetwork !== null && inspected[inspected.length - 1]?.network_id === lastNetwork;
    let splitAfter: number | null = null;
    for (let index = 0; index < inspected.length - 1; index++) {
      if (inspected[index]?.network_id === null || inspected[index]?.network_id !== inspected[index + 1]?.network_id) {
        splitAfter = index; break;
      }
    }
    const connected = fromCovered && toCovered && splitAfter === null;
    return result({ ...route,
      placement: { requested: route.steps.length, placed: route.steps.length, complete: true },
      endpoint_coverage: {
        from: { covered: fromCovered, network_id: inspected[0]?.network_id ?? null },
        to: { covered: toCovered, network_id: inspected[inspected.length - 1]?.network_id ?? null },
      },
      network_continuity: { connected, split_after_index: splitAfter,
        split: splitAfter === null ? null : { from: inspected[splitAfter], to: inspected[splitAfter + 1] } },
      status: connected ? "connected" : "placed_unconnected", terminal: true,
      summary: connected ? `placed ${route.steps.length}/${route.steps.length}; electrical route connected`
        : `placed ${route.steps.length}/${route.steps.length}; electrical route is not continuous`,
      detail, next_action: null,
    });
  };
  tools.registerTool("connect_status", { description: "Check config, RCON, mod and protocol versions, then bind the connected native player named Codex.", inputSchema: z.object({}).strict() }, async () => {
    try {
      return await connectStatus(bridge, configDiagnostic, surface === "full");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return result({ status: "offline", terminal: true, summary: `Offline: ${message}`, next_action: null }, false);
    }
  });
  tools.registerTool("observe_local", { description: "Nearby entities, ground items and resource patches around the body. compact is bounded; full returns more, out to 20 tiles (requested_radius says when you asked for more), and takes a few game ticks.", inputSchema: z.object({ radius: z.number().int().min(5).max(30).default(15), detail: z.enum(["compact", "full"]).default("compact") }).strict() }, async ({ radius, detail }, extra) => {
    try { return result(normalizeObservation(await (await bridge()).call("observe_local", { radius, detail }, extra?.signal))); }
    catch (error) { return failure(error); }
  });
  // Belts, inserter hands and belt traces (belt_trace.lua): readings only.
  const inspectBelts = ` A belt gives lanes (item counts on its left and right lane, along its direction) and lane_mix: empty, pure (one item kind), separated (one kind per lane, not the same) or mixed (a lane holds more than one kind). An inserter gives holding: the item, count and quality in its hand (null when empty). trace "up" (what feeds each belt read) or "down" (where its items go) follows the belt through side-loads, undergrounds and splitters, at most 400 belts per call, over own belts in charted chunks only. Per lane it gives items (counts on the traced belts), first_seen (the nearest traced belt carrying each item, with belts_from_start) and sources: inserters and mining drills dropping onto it (lane, holding, pickup_target, a drill's adds), side_load belts, splitters, loaders and, down, belts joining it, with the items on them. truncated: the 400-belt cap ended it; loop: it came back to the start belt; stopped counts belts not entered (uncharted, other_force).`;
  tools.registerTool("inspect_entity", { description: `Inspect up to ${INSPECT_LIMIT} exact positions: contents by inventory, settings, status; a rocket silo's rocket (parts, cargo, weight, auto requests), a landing pad's stock and requests. Beyond 30 tiles only own entities in charted chunks are read, marked remote: true. surface reads another planet or platform. Input: {"positions":[{"x":1.5,"y":2.5}]}.${inspectBelts}`, inputSchema: z.object({ positions: z.array(position).min(1).max(INSPECT_LIMIT), surface: surfaceRef.optional(), trace: z.enum(["up", "down"]).optional() }).strict() }, async ({ positions, surface, trace }) => {
    try { return result(normalizeInspection(await (await bridge()).call("inspect", toolPayloads.inspect(positions, surface, trace)))); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("describe_prototype", { description: "Describe up to 10 item, entity or recipe prototypes; auto tries entity, then item, then recipe.", inputSchema: z.object({ names: z.array(z.string()).min(1).max(10), kind: z.enum(["auto", "entity", "recipe", "item"]).default("auto") }).strict() }, async (p) => rpc("describe_prototype", p));
  tools.registerTool("progression_status", { description: "Researched technologies, what can be researched now, and what each unlocks, with science_count units of unit_time_s seconds each at lab speed 1; a trigger technology names its trigger and a hint at the tool that completes it.", inputSchema: z.object({}).strict() }, async () => rpc("progression_status"));
  tools.registerTool("can_place", { description: "Check up to 24 placements without building, anywhere charted: the body need not go there. Each result keeps the request and gives can_place, the reason, overlaps_batch (indexes of overlapping placements in the batch), and what an inserter would pick up from and drop onto. surface checks another planet or platform.", inputSchema: z.object({ placements: z.array(position.extend({ name: z.string(), direction: z.number().int().min(0).max(15).optional() }).strict()).min(1).max(24), surface: surfaceRef.optional() }).strict() }, async ({ placements, surface }) => {
    try { return result(normalizeCanPlace(await (await bridge()).call("can_place", toolPayloads.canPlace(placements, surface)), placements)); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("find_placement", { description: "Find valid placements near any charted point, nearest first for every type (a drill candidate's resource_coverage is data to compare); the body need not go there. Requests with input_target, output_target, or output_recipient_item require cardinal directions only: 0, 4, 8, 12. Each candidate's plan_steps go straight into queue_plan (with fuel inserts when fuel is given). An empty result has a hint: change the request as it says. fluid picks what an offshore pump pumps (water, lava, ...); surface searches another planet.", inputSchema: z.object({ item: z.string(), preferred: position, radius: z.number().int().min(1).max(30).default(10), directions: z.array(z.number().int().min(0).max(15)).min(1).max(16).default([0, 4, 8, 12]), limit: z.number().int().min(1).max(24).default(8), input_target: position.optional(), output_target: position.optional(), output_recipient_item: z.string().min(1).optional(), belt_to_ground_type: beltToGroundType, fuel: items.optional(), fluid: z.string().min(1).optional(), surface: surfaceRef.optional() }).strict().refine((p) => !(p.output_target && p.output_recipient_item), "use output_target or output_recipient_item, not both").refine((p) => !(p.input_target !== undefined || p.output_target !== undefined || p.output_recipient_item !== undefined) || p.directions.every((direction) => direction % 4 === 0), { message: "targeted placement directions must be cardinal: 0, 4, 8, or 12", path: ["directions"] }) }, async (p, extra) => {
    try { return result(normalizePlacementSearch(await (await bridge()).call("find_placement", toolPayloads.findPlacement(p), extra?.signal), p.fuel)); }
    catch (error) { return failure(error); }
  });
  const mapSummarySchema = z.object({
    detail: z.enum(["aggregate", "full"]).default("aggregate"),
    flow_precision: z.enum(["five_seconds", "one_minute", "ten_minutes", "one_hour"]).default("one_minute"),
    flow_items: z.array(z.string().min(1)).max(32).optional(),
    flow_fluids: z.array(z.string().min(1)).max(32).optional(),
    activity_since_tick: z.number().int().nonnegative().optional(),
    include: z.array(z.enum(MAP_SUMMARY_SECTIONS)).max(MAP_SUMMARY_SECTIONS.length).optional(),
    surface: surfaceRef.optional(),
  }).strict();
  tools.registerTool("map_summary", { description: "Detailed graph of the charted own factory on the body's surface, or the surface named (\"all\" sums flows over every surface): machine groups, flow rates, connections, line counts and character transfers. Prefer factory_status for routine reads. include adds capped sections: stockpiles, sites, patches, power, problems (problems_by_status counts every problem machine by status), flows_all. Reading is not reach.", inputSchema: mapSummarySchema }, async (p, extra) => {
    try { return result(normalizeMapSummary(await (await bridge()).call("map_summary", mapSummarySchema.parse(p), extra?.signal))); }
    catch (error) { return failure(error); }
  });
  const productionRequirementsSchema = z.object({
    targets: z.record(z.string(), z.number().positive()).refine((value) => Object.keys(value).length >= 1 && Object.keys(value).length <= 16, "targets must contain 1-16 entries").optional(),
    technology: z.string().min(1).optional(), location: z.string().min(1).optional(),
    recipe_choices: z.record(z.string(), z.string()).optional(), planet: z.string().min(1).optional(),
    flow_precision: z.enum(["five_seconds", "one_minute", "ten_minutes", "one_hour"]).default("one_minute"),
    per_minute: z.boolean().optional(), fuel: z.string().min(1).optional(),
  }).strict().superRefine((value, ctx) => {
    const modes = Number(value.targets !== undefined) + Number(value.technology !== undefined) + Number(value.location !== undefined);
    if (modes !== 1) ctx.addIssue({ code: "custom", message: "provide exactly one of targets, technology, or location" });
    if ((value.per_minute || value.fuel !== undefined) && value.targets === undefined) ctx.addIssue({ code: "custom", message: "per_minute and fuel plan rates for targets only" });
    if (value.fuel !== undefined && value.per_minute !== true) ctx.addIssue({ code: "custom", message: "fuel applies only with per_minute true" });
  });
  tools.registerTool("production_requirements", { description: 'Expand item targets, a technology, or a space location into recipes, raw materials and prerequisites. Input: {"targets":{"automation-science-pack":10}}, {"technology":"automation"} or {"location":"solar-system-edge"}. Each raw material lists roots: the planets and ways it is gathered; unobtainable lists those found nowhere. planet plans for that planet (default the body\'s) and names recipes its conditions forbid. With per_minute true, targets are units per minute and rates gives, from live prototypes, each stage\'s machines per tier (count, fuel per minute in fuel, default coal, or electric kW), the drills each raw resource needs, and what one belt of each tier carries: {"targets":{"iron-plate":30},"per_minute":true}.', inputSchema: productionRequirementsSchema }, async (p) => {
    try { return result(normalizeProductionRequirements(await (await bridge()).call("production_requirements", toolPayloads.productionRequirements(p)))); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("plan_status", { description: "Read one plan by plan_id, or wait up to 60 s for its progress or end. Waiting never cancels work. human_control: true means a human held the body: delayed, not failed.", inputSchema: planStatusSchema }, async (input, extra) => {
    try {
      const p = planStatusSchema.parse(input);
      const value: any = await waitForPlanStatus(await bridge(), p.plan_id, p.wait_until, p.timeout_seconds * 1_000, extra?.signal);
      if (value.observation) value.observation = normalizeObservation(value.observation);
      const terminal = ["completed", "partial", "failed", "cancelled"].includes(value.status);
      return result(normalizePlanDiagnostics({ ...value, terminal, summary: planStatusSummary(value, terminal),
        next_action: terminal ? null : nextEventAfter(value.source_tick),
      }), value.status === "failed" || value.status === "cancelled");
    } catch (error) { return failure(error); }
  });
  const factoryStatusSchema = z.object({
    since_tick: z.number().int().nonnegative().optional(),
    sections: z.array(z.enum(FACTORY_STATUS_SECTIONS)).min(1).max(FACTORY_STATUS_SECTIONS.length).optional(),
    surface: surfaceRef.optional(),
  }).strict();
  tools.registerTool("factory_status", { description: "One compact read of the whole factory: production lines with state (running, starved, output_full, depleted, no_fuel, no_power, frozen, no_heat, disabled, idle), rate, cause and position (outlet_no_fuel: the dry burner inserter emptying the full machine; degraded: a running line's worst member problem; hand_transfers: served by hand twice or more in ten minutes, so not yet automated; hand_seconds: body time that hand service took); problem machines (a research_idle one: labs stand still because no research is running); power by source with sustained_w and, when short, add_to_cover with both ways to cover the deficit (steam: steam_engine, plus the boiler and offshore_pump the surface's engines need beyond those standing anywhere on the surface (a pump feeding chemistry counts too), no offshore_pump where its tiles give no water; solar where the sun gives power: solar_panel, accumulator), for you to choose; stock; research (labs once there is one: count, working, summed speed; for the current research unit_time_s, packs_per_minute_needed to keep every lab busy and eta_seconds at full lab speed with lab productivity); the body; nearby resource patches with their outline (bbox: left_top, right_bottom); one line per space platform once there is one. It describes the body's surface, or the one named in surface; elsewhere has one line per other surface with buildings, so the home factory stays in view. since_tick returns only lines and problems changed since then, including elsewhere problems and top_problems; elsewhere line counts and power remain current. sections picks parts; logistics (robot networks) is read only when named, e.g. sections ['lines','power','logistics']. During a benchmark, trial gives the clock (remaining_seconds; final_window_in_seconds until the last five minutes, whose raw input rate breaks ties) and the score so far: research and made count since GO; raw_since_go is total raw input, not that final rate.", inputSchema: factoryStatusSchema }, async (p) => {
    try {
      const value = normalizeFactoryStatus(await (await bridge()).call("factory_status", factoryStatusSchema.parse(p)));
      return result({ ...value, summary: factoryStatusSummary(value) });
    } catch (error) { return failure(error); }
  });
  const activityLogSchema = z.object({ since_plan_id: z.number().int().nonnegative().optional(), limit: z.number().int().min(1).max(64).default(16) }).strict();
  tools.registerTool("activity_log", { description: "What the body did: recent plan outcomes, oldest first, each with source (pilot, upkeep or package:<id>), status and a summary; cancels (with who asked), blueprint changes and the strategist's ledger research (origin ledger/r<revision>, with what was queued or skipped); plus the queue status of the strategist's packages and of its research.", inputSchema: activityLogSchema }, async (p) => {
    try {
      const value = normalizeActivityLog(await (await bridge()).call("activity_log", activityLogSchema.parse(p)));
      const dir = runDir();
      const queue = dir ? readPackageQueue(dir) : null;
      const packages = Object.entries(queue?.packages ?? {}).slice(-16)
        .map(([package_id, record]) => ({ package_id, ...record }));
      const entries: any[] = value?.entries ?? [];
      // Plan outcomes, and rows of another kind (cancel, blueprint) without a status.
      const last = entries.at(-1);
      const lastText = !last ? "" : last.kind === undefined ? `plan ${last.plan_id} ${last.summary ?? ""}`
        : last.kind === "cancel" ? `cancel by ${last.origin} (${last.cancelled_count} cancelled)`
        : last.kind === "research" ? `research by ${last.origin}: ${last.error ?? `queued ${luaArray(last.technologies ?? []).join(", ") || "nothing new"}`}`
        : `${last.kind} ${last.action ?? ""} ${last.name ?? ""}`;
      return result({ ...value, ...(packages.length ? { packages } : {}), ...(queue?.research ? { research: queue.research } : {}),
        summary: `${entries.length} row${entries.length === 1 ? "" : "s"}${last ? `; last: ${lastText.trim()}` : ""}` });
    } catch (error) { return failure(error); }
  });
  tools.registerTool("next_event", { description: "Wait up to timeout_seconds for the next thing to act on: plan_ended (with the plan's step outcomes and inventory change), research_finished, queue_empty, new_problem, package_failed, orders_changed, human_hold_started, human_hold_ended, rocket_ready, rocket_launched, cargo_delivered, platform_state_changed, platform_arrived, travel_phase, body_surface_changed, or timeout. For plan_ended, status is the native plan outcome; read_status describes completion, cancellation or failure of this wait. Cancelling the wait leaves physical plans unchanged. Without since_tick an already empty queue returns queue_empty at once; with since_tick, a plan end, research, problem, rocket, platform or travel event or package failure after that tick returns at once.", inputSchema: nextEventSchema }, async (input, extra) => {
    try {
      const value = await waitForEvent(await bridge(), nextEventSchema.parse(input), {
        ordersChanged: orders.changed,
        packageFailures: () => { const dir = runDir(); return dir ? packageFailures(dir) : []; },
        delivery: failureDelivery,
      }, extra?.signal);
      const readStatus = value.event === "cancelled" ? "cancelled" : "completed";
      return result({ ...value, status: value.event === "plan_ended" ? value.status : readStatus,
        read_status: readStatus, terminal: true, summary: eventSummary(value), next_action: null });
    } catch (error) {
      const failed = failure(error);
      return { ...failed, structuredContent: { ...failed.structuredContent, read_status: "failed" } };
    }
  });
  tools.registerTool("build_layout", { description: `Build a layout given as offsets (dx, dy) from an anchor, or from a site the mod finds (near a point, on a resource, near water): entities with direction, recipe, starting items (insert), mirror, belt_to_ground_type (input|output) for underground belts and settings (inserter filters, splitter priorities, chest limits, set as each is built), plus belt, pipe and power connections. The mod checks every placement, fails with nothing placed when an item cannot be had, fetches or crafts the whole bill before the first placement (what the inventory has no room for, at its step), clears trees and rocks, walks and builds; a placement that fails leaves the rest placed, and one its approach could not reach for where the body stood (BODY_ON_CONVEYOR, START_COLLISION) is retried once after the last. mode ghosts places ghosts for robots instead. With platform it marks ghosts on that space platform from an anchor relative to its hub, plus foundation tiles (tiles, tile_rects; each touches foundation), and the hub builds them from its own items; the body stays put. site.near_liquid picks water, lava, heavy-oil or ammoniacal-solution; a dry run may name surface to check another planet or platform.${dryRun} A dry run fails ITEM_UNOBTAINABLE naming an item the body neither carries nor can obtain now.${dryReport}`, inputSchema: layoutSchema }, async (p, extra) => {
    try { return await step("build_layout")(layoutSchema.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("connect_entities", { description: `Connect two points with belts, pipes or power poles, up to 200 pieces. An end is an existing belt, pipe, pole or machine, or a free tile (bare ore counts as free). Belts and pipes go underground past obstacles; fluid picks the machine port. The body fetches the pieces, walks and builds.${dryRun}`, inputSchema: routeSchema }, async (p, extra) => {
    try { return await connectRoute(routeSchema.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("blueprint_list", { description: "The blueprints stored for this run, with size and entity count.", inputSchema: z.object({}).strict() }, async () => rpc("blueprint_list"));
  tools.registerTool("blueprint_describe", { description: "One stored blueprint: its entities with offsets, size and item cost.", inputSchema: named }, async (p, extra) => rpc("blueprint_describe", named.parse(p), extra?.signal));
  tools.registerTool("blueprint_export", { description: "A stored blueprint as a string for the notebook. It is never imported back.", inputSchema: named }, async (p) => rpc("blueprint_export", named.parse(p)));
  tools.registerTool("blueprint_place", { description: `Build a stored blueprint at a position, turned (direction 0, 4, 8, 12) or flipped. mode hand: the body builds it like build_layout; mode ghosts: ghosts for construction robots; platform: ghosts on that space platform, position relative to its hub.${dryRun} A dry run lists collisions, missing items, items the body cannot obtain now (unobtainable; not ok in hand mode) and the nearest free position (none where its pipes would join two fluids: free_reason names the pipe); where the blueprint fits (there or at the free position) also ${oreReport} and ${fluidReport}.`, inputSchema: placeBlueprintSchema }, async (p, extra) => {
    try { return await step("blueprint_place")(placeBlueprintSchema.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("place_tiles", { description: `Lay landfill, stone path, concrete, foundation or ice platform from the inventory over an area or a list of positions (at most 1,024 tiles), nearest first, walking along. Tiles that already have it are skipped; tiles the item cannot cover are named with the item to use.${dryRun} A dry run says how many items it needs.`, inputSchema: tilesSchema }, async (p, extra) => {
    try { return await step("place_tiles")(tilesSchema.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  const platformStatusSchema = z.object({ platform: platformSelector.optional(), detail: z.enum(["compact", "full"]).default("compact") }).strict()
    .refine((p) => p.detail === "compact" || p.platform !== undefined, { message: "detail full reads one platform: name it", path: ["platform"] });
  tools.registerTool("platform_status", { description: "Your space platforms: state, location, trip (from, to, how far along), speed, paused, schedule, hub free slots and requests. detail full (one platform) adds its thrusters, foundation rows, hub contents and requests, entities with recipes and filters, and ghosts.missing: what its ghosts still need that the hub lacks, to send up by rocket.", inputSchema: platformStatusSchema }, async (p, extra) => {
    try {
      const value = normalizePlatformStatus(await (await bridge()).call("platform_status", platformStatusSchema.parse(p), extra?.signal));
      return result({ ...value, summary: platformStatusSummary(value) });
    } catch (error) { return failure(error); }
  });
  if (surface === "read-only") return;
  tools.registerTool("get_items", { description: "Get count of an item into the inventory: from the nearest own chest, machine output, loose items at a drill's drop position or belt, else by smelting ore in an own furnace or crafting it with its intermediates, else by hand-gathering a raw resource, also one own drills mine when none of their output can be taken now. The result names any shortfall and when more is expected.", inputSchema: z.object({ item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict() }, async (p, extra) =>
    runPlan({ steps: [{ action: "get_items", ...p }] }, extra?.signal, "get_items"));
  tools.registerTool("walk_to", { description: "Walk to a point. exact stops within 1 tile; vicinity stops anywhere within arrival_radius. Other actions walk to their targets by themselves.", inputSchema: walkInput }, async (p, extra) => task("walk_to", "walk_to", toolPayloads.target(p), extra?.signal));
  tools.registerTool("mine", { description: "Mine the entity or resource at a position, count times; on trees or rocks count mines the nearest ones. target_kind picks natural or owned where both overlap; owned picks up your own building with its contents when they fit. A result with drill_produced: true means own drills also mine it: their output is there to take, and hand-mining adds to what they mine.", inputSchema: position.extend({ count: z.number().int().min(1).max(200).default(1), target_kind: z.enum(["natural", "owned"]).optional(), allow_fluid_loss: z.boolean().default(false), expected_name: z.string().min(1).optional(), observed_tick: z.number().int().nonnegative().optional() }).strict() }, async (p, extra) => task("mine", "mine", toolPayloads.mine(p), extra?.signal));
  tools.registerTool("pickup_items", { description: "Pick up one item stack from the ground, or take count items riding a plain belt tile. The whole count must fit in the inventory or nothing is taken; nothing is created; a belt tile that runs dry, or is still short after 30 s in reach, ends the step with the count actually picked up.", inputSchema: position.extend({ item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict() }, async (p, extra) => task("pickup_items", "pickup", toolPayloads.pickup(p), extra?.signal));
  tools.registerTool("place_entity", { description: 'Place one item at a position; the same entity already there counts as placed. auto_supply (default on) fetches or crafts it first; trees and rocks in the way are cleared; insert puts starting items in. Use name, never item: {"name":"wooden-chest","x":1.5,"y":2.5}. Optional input_target/output_target must match what an inserter picks from and drops into. Underground belts take belt_to_ground_type input|output; mirror flips refineries and chemical plants.', inputSchema: position.extend({ name: z.string(), direction: z.number().int().optional(), input_target: position.optional(), output_target: position.optional(), belt_to_ground_type: beltToGroundType, mirror: z.boolean().optional(), insert: items.optional(), auto_supply: z.boolean().optional() }).strict() }, async (p, extra) => task("place_entity", "place", toolPayloads.place(p), extra?.signal));
  const craftInput = z.object({ recipe: z.string(), crafts: z.number().int().min(1).max(100), wait_for_completion: z.boolean().optional() }).strict();
  tools.registerTool("craft_items", { description: 'Queue a hand-craft: {"recipe":"iron-gear-wheel","crafts":2}. The body keeps working while it crafts, and a later step that needs the item waits for it; wait_for_completion: true waits here.', inputSchema: craftInput }, async (p, extra) => task("craft_items", "craft", toolPayloads.craft(p), extra?.signal));
  const insertInput = z.object({ ...insertFields, auto_supply: z.boolean().optional() }).strict().superRefine(issue(insertIssue));
  tools.registerTool("insert_items", { description: 'Put items from the inventory into the entity at x, y, or the same items into each of up to 32 targets: a list of positions, or {"name":"stone-furnace","near":{"x":0,"y":0},"radius":10}. per_target names what each target gets. inventory puts them into that inventory (such as modules or fuel) instead of where the game routes them. auto_supply (default on) fetches missing items first, in one trip. A partial insert reports what is left.', inputSchema: insertInput }, async (p, extra) => {
    try { return await task("insert_items", "insert", toolPayloads.insert(insertInput.parse(p)), extra?.signal); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("extract_items", { description: "Take the named items, or everything when items is omitted, out of the entity at a position. inventory picks one of its inventories (output by default, a chest's contents); the result lists the ones it has.", inputSchema: position.extend({ items: items.optional(), inventory: inventoryRole.optional() }).strict() }, async (p, extra) => task("extract_items", "extract", toolPayloads.extract(p), extra?.signal));
  const configureInput = z.object(configureFields).strict().superRefine(issue(settingsIssue));
  tools.registerTool("configure_entity", { description: "Set what you would set in a building's window: inserter filters, mode and stack size, splitter priorities and filter, a chest's slot limit or storage filter (null clears), an asteroid collector's chunk filters, a rocket silo's auto_requests. The body walks there; with platform it sets that platform's entity without the body. It changes only what you name and returns the settings as they now are; repeating it changes nothing.", inputSchema: configureInput }, async (p, extra) => {
    try {
      const parsed = configureInput.parse(p);
      // A platform entity is its platform's window: one RPC, no body, no FIFO.
      if (parsed.platform !== undefined) return await remote("configure_entity", parsed, (value) =>
        `configured the ${value?.entity?.name} on platform ${parsed.platform}: ${value.changed.join(", ") || "nothing changed"}`,
      normalizeConfigured);
      return await step("configure_entity")(parsed, extra?.signal);
    } catch (error) { return failure(error); }
  });
  const requestsInput = z.object(requestsFields).strict().superRefine(issue(requestsIssue));
  tools.registerTool("set_requests", { description: "Set what a requester or buffer chest asks robots for, what a landing pad asks platforms in orbit to drop, or (target {platform}) what a platform hub keeps stocked, with import_from naming the supplying planet; target \"character\" sets your own personal requests (trash names items robots take away; logistic robotics first). merge (default) updates the named items, set replaces the section, remove clears items. A chest or pad needs the body there; a hub is set at once. Only robots and platforms deliver; network: null says no roboport covers the chest.", inputSchema: requestsInput }, async (p, extra) => {
    try {
      const parsed = requestsInput.parse(p);
      // A hub is its platform's window, and the body's own requests need no
      // reach: one RPC, no FIFO.
      if (parsed.target === "character") return await remote("set_requests", parsed, (value) =>
        `your own requests set (${value?.sections?.length ?? 0} sections)`, normalizeRequests);
      if ("platform" in parsed.target) return await remote("set_requests", parsed, (value) =>
        `platform ${value?.target?.platform_name}'s hub requests set (${value?.sections?.length ?? 0} sections)`, normalizeRequests);
      return await step("set_requests")(parsed, extra?.signal);
    } catch (error) { return failure(error); }
  });
  const recipeInput = position.extend({ recipe: z.string(), platform: platformSelector.optional() }).strict();
  tools.registerTool("set_recipe", { description: "Set the recipe of your assembler (or crusher) at a position; with platform, on that space platform without the body, its old contents going to the hub. Furnaces choose their own recipe from their input.", inputSchema: recipeInput }, async (p, extra) => {
    try {
      const parsed = recipeInput.parse(p);
      if (parsed.platform !== undefined) return await remote("set_recipe", parsed, (value) =>
        `set the ${value?.entity?.name}'s recipe to ${parsed.recipe} on platform ${parsed.platform}`);
      return await step("set_recipe")(parsed, extra?.signal);
    } catch (error) { return failure(error); }
  });
  const createPlatformInput = z.object(createPlatformFields).strict();
  tools.registerTool("create_platform", { description: "Register a new space platform over the body's planet, or over the unlocked planet named in planet, at once. It waits for its starter pack: craft one and send it with launch_rocket. Nothing is built or consumed.", inputSchema: createPlatformInput }, async (p) => {
    try {
      return await remote("create_platform", createPlatformInput.parse(p), (value) =>
        `created platform ${value?.platform?.name} (${value?.platform?.index}) over ${value?.platform?.planet}; it waits for its starter pack`);
    } catch (error) { return failure(error); }
  });
  const launchInput = z.object(launchRocketFields).strict();
  tools.registerTool("launch_rocket", { description: "Load a ready rocket at the silo with cargo (items and counts, or \"requests\": what the platform hub still requests) and launch it to that platform; a platform still waiting for its starter pack needs cargo naming it, e.g. {\"space-platform-starter-pack\": 1}. The body fetches the cargo, walks to the silo and presses launch. It fails at once with the part count when no rocket is ready; partial: true loads what it can get.", inputSchema: launchInput }, async (p, extra) => {
    try { return await step("launch_rocket")(launchInput.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  const routeInput = z.object(platformRouteFields).strict().superRefine(issue(routeIssue));
  tools.registerTool("set_platform_route", { description: "Set a space platform's route at once, without the body: stops (locations, each with optional wait conditions in the game's own form, such as {\"type\":\"all_requests_satisfied\"}) replace its schedule; go_to heads for stop n; paused holds it still. Locations must be unlocked. Returns the schedule as kept; repeating it changes nothing.", inputSchema: routeInput }, async (p) => {
    try {
      return await remote("set_platform_route", routeInput.parse(p), (value) => {
        const changed = luaArray(value?.changed ?? []);
        return `platform ${value?.platform?.name}'s route: ${changed.length > 0 ? `${changed.join(", ")} set` : "unchanged"}`;
      }, normalizeRoute);
    } catch (error) { return failure(error); }
  });
  const travelInput = z.object(travelFields).strict();
  tools.registerTool("travel", { description: "Go to another surface as a player does: by rocket from a planet up to a platform in orbit (it waits for a ready rocket; via_silo picks the silo), or from aboard down to a planet: it waits aboard until the platform reaches that planet (max_wait_minutes, default 60; NO_ROUTE when the platform's schedule has no stop there). Queues one plan and returns; follow it with next_action's next_event. Route the platform first with set_platform_route.", inputSchema: travelInput }, async (p) => {
    try {
      const queued: any = await (await bridge()).call("travel", travelInput.parse(p));
      return result({ ...queued, status: "queued", terminal: false,
        summary: `${queuedPlanSummary(queued)}; travel to ${queued.to ?? JSON.stringify(p.to)}`,
        next_action: nextEventAfter(queued.tick) });
    } catch (error) { return failure(error); }
  });
  tools.registerTool("rotate_entity", { description: "Rotate the entity at a position once, or set its direction 0-15.", inputSchema: position.extend({ direction: z.number().int().min(0).max(15).optional() }).strict() }, async (p, extra) => task("rotate_entity", "rotate", toolPayloads.rotate(p), extra?.signal));
  tools.registerTool("build_plan", { description: "Place up to 25 items in order; each may set a recipe, settings and insert items, or be mirrored. Stops at the first failure by default; earlier placements stay. Without stop_on_error, a step whose approach failed BODY_ON_CONVEYOR or START_COLLISION is retried once after the last.", inputSchema: z.object({ steps: z.array(position.extend({ name: z.string(), direction: z.number().int().optional(), input_target: position.optional(), output_target: position.optional(), belt_to_ground_type: beltToGroundType, recipe: z.string().optional(), insert: items.optional(), mirror: z.boolean().optional(), settings: entitySettings.optional() }).strict()).min(1).max(25), auto_craft: z.boolean().default(true), auto_supply: z.boolean().optional(), stop_on_error: z.boolean().default(true) }).strict() }, async ({ steps, ...rest }, extra) => task("build_plan", "build_plan", toolPayloads.buildPlan(steps, rest), extra?.signal));
  const moveInput = z.object(moveEntityFields).strict();
  tools.registerTool("move_entity", { description: "Move one of your buildings: the body picks it up with its contents, places it at to, and restores its recipe, direction (unless given), settings, fuel, modules and ingredients. A failed placement leaves it in the inventory. Explicit mode robots instead orders native robot deconstruction and blueprint rebuild within a shared covered network; the body must reach the source. Supports empty buildings with modules and native blueprint settings, refuses fluid/content or external-wire loss, waits for verified paid recovery and construction, and reports pending or partial failure. Cancellation retains paid builds; outstanding native requests may continue. Default mode body is unchanged.", inputSchema: moveInput }, async (p, extra) =>
    step("move_entity")(moveInput.parse(p), extra?.signal));
  const exploreInput = z.object(exploreFields).strict();
  tools.registerTool("explore", { description: "Scout on foot toward uncharted land (or a direction 0-15, 0 = north, 4 = east), charting as it goes, until a patch of resource is in view or max_distance tiles are walked.", inputSchema: exploreInput }, async (p, extra) =>
    step("explore")(exploreInput.parse(p), extra?.signal));
  const captureInput = areaSchema(captureFields);
  tools.registerTool("blueprint_capture", { description: "Store your buildings in a charted area (at most 64 x 64 tiles, 100 entities) as a named blueprint of this run. Nothing in the world changes; the same name replaces the old one.", inputSchema: captureInput }, async (p, extra) => {
    try { return await rpc("blueprint_capture", captureInput.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  const createInput = z.object({ name: blueprintName, entities: z.array(z.object({ name: z.string().min(1), dx: z.number(), dy: z.number(),
    direction: z.number().int().min(0).max(15).optional(), recipe: z.string().min(1).optional(), mirror: z.boolean().optional(),
    settings: entitySettings.optional() }).strict()).min(1).max(100) }).strict();
  tools.registerTool("blueprint_create", { description: "Store a named blueprint from a layout of entities (name, dx, dy, direction, recipe, mirror, settings) without building anything.", inputSchema: createInput }, async (p) => rpc("blueprint_create", createInput.parse(p)));
  tools.registerTool("blueprint_delete", { description: "Delete a stored blueprint.", inputSchema: named }, async (p) => rpc("blueprint_delete", named.parse(p)));
  const ghostsInput = areaSchema({});
  tools.registerTool("build_ghosts", { description: "Build the ghosts in an area by hand from the inventory, fetching or crafting what is missing.", inputSchema: ghostsInput }, async (p, extra) => {
    try { return await step("build_ghosts")(ghostsInput.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  const deconstructInput = z.object(deconstructFields).strict().superRefine(issue(deconstructIssue));
  tools.registerTool("deconstruct_area", { description: "Clear an area. mode hand (default): the body mines each of your buildings and the trees and rocks there; robots: mark them for construction robots; cancel: unmark. With platform (robots or cancel) the area is on that space platform and its hub takes the items back. filter limits it to those names.", inputSchema: deconstructInput }, async (p, extra) => {
    try { return await step("deconstruct_area")(deconstructInput.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  const upgradeInput = areaSchema(upgradeFields);
  tools.registerTool("upgrade_area", { description: "Replace every from entity in an area with to. mode hand (default): the body swaps same-size ones in place, keeping direction and recipe; robots: mark them for upgrade.", inputSchema: upgradeInput }, async (p, extra) => {
    try { return await step("upgrade_area")(upgradeInput.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  const copyInput = z.object(copySettingsFields).strict();
  tools.registerTool("copy_settings", { description: "Copy the recipe, filters and limits of one building onto up to 32 others of the same kind; the body walks within reach of each.", inputSchema: copyInput }, async (p, extra) =>
    step("copy_settings")(copyInput.parse(p), extra?.signal));
  tools.registerTool("queue_plan", { description: "Queue a plan of 1-200 steps and return at once, so the body works while you think. Prefer goal-level steps: get_items, build_layout, blueprint_place. equip and flush_fluid are plan steps only. Steps on a space platform (platform set) need no body. Positions are on the body's surface, or after a travel step on its destination; surface names another. A plan for a surface the body leaves is cancelled (SURFACE_LEFT). after_plan_id runs it only after that plan completes. Wait with next_action's next_event: its since_tick still catches a plan that already ended.", inputSchema: queuePlanSchema }, async (input) => {
    try {
      const queued: any = await (await bridge()).call("queue_plan", queuePlanSchema.parse(input));
      return result({ ...queued, status: "queued", terminal: false, summary: queuedPlanSummary(queued),
        next_action: nextEventAfter(queued.tick) });
    } catch (error) { return failure(error); }
  });
  tools.registerTool("run_plan", { description: "Run 1-200 steps and block until the plan is terminal (up to 570 s, then it returns the plan still running and never cancels it); the queue stays empty while you then think, so prefer queue_plan.", inputSchema: runPlanSchema }, async (input, extra) => runPlan(input, extra?.signal));
  const researchInput = z.object({ technology: z.string().min(1).optional(), technologies: z.array(z.string().min(1)).min(1).max(7).optional() }).strict()
    .refine((p) => (p.technology === undefined) !== (p.technologies === undefined), { message: "give technology or technologies, not both" });
  tools.registerTool("start_research", { description: "Start researching an unlocked technology, or queue up to 7 technologies in order (technologies).", inputSchema: researchInput }, async (p) => {
    try { return await rpc("start_research", researchInput.parse(p)); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("stop", { description: "Emergency stop: cancels the active and queued plans and hand-crafting; upkeep stays off until a plan finishes, unless keep_upkeep is true (retained-work reconciliation). Supervisor only, never for gameplay or routine recovery.", inputSchema: z.object({ keep_upkeep: z.boolean().optional() }).strict() }, async (p) => rpc("cancel", { all: true, origin: `stop/${role}`, ...(p.keep_upkeep === true ? { keep_upkeep: true } : {}) }));
}

type Connection = { rcon: RconClient; bridge: Bridge };
type RconFactory = (opts: RconSettings) => RconClient;
type ConnectionSettings = RconSettings | (() => ConfigDiagnostic);

/** Lazy, singleflight RCON handshake shared by every MCP handler. */
export function createBridgeProvider(
  settings: ConnectionSettings,
  createRcon: RconFactory = (settings) => new RconClient(settings),
): () => Promise<Bridge> {
  let connection: Connection | undefined;
  let connecting: Promise<Bridge> | undefined;

  return async () => {
    const diagnostic = typeof settings === "function" ? settings() : undefined;
    if (diagnostic && !diagnostic.ok) throw new Error(diagnostic.error);
    const opts = diagnostic ? diagnostic.config.rcon : settings as RconSettings;
    assertConnectionCompatibility(opts);
    if (!opts.password) throw new Error("setup has not been completed; run `factorio-codex setup`");
    if (connection?.rcon.connected) return connection.bridge;
    if (connecting) return connecting;

    if (connection) {
      const stale = connection;
      connection = undefined;
      stale.rcon.close();
    }

    const attempt = (async () => {
      const rcon = createRcon(opts);
      try {
        await rcon.connect();
        const bridge = new Bridge(rcon);
        await bridge.unlock();
        assertConnectionCompatibility(opts, await bridge.call("ping"), companionVersion());
        const owned = { rcon, bridge };
        connection = owned;
        rcon.on("close", () => {
          if (connection === owned) connection = undefined;
        });
        return bridge;
      } catch (error) {
        rcon.close();
        throw error;
      }
    })();
    connecting = attempt;
    attempt.then(
      () => { if (connecting === attempt) connecting = undefined; },
      () => { if (connecting === attempt) connecting = undefined; },
    );
    return attempt;
  };
}

export async function runMcpServer(
  surface: McpSurface = "full",
  configDiagnostic: () => ConfigDiagnostic = diagnoseConfig,
  role: SessionRole = "unknown",
): Promise<void> {
  const instructions = surface === "read-only"
    ? "Read Factorio state without moving, mutating, queueing, cancelling, or controlling the Codex character."
    : "Control one physical Factorio character named Codex. queue_plan returns immediately, while run_plan and single physical tools hold the only physical slot until they finish. Wait with next_event instead of polling. Never use screenshots or screen capture.";
  const server = new McpServer({ name: "factorio-codex", version: MCP_SERVER_VERSION }, { instructions });
  const bridge = createBridgeProvider(configDiagnostic);
  registerMcpTools(server as unknown as ToolRegistrar, bridge, configDiagnostic, surface, currentRunDir, role);
  if (surface === "full" && role === "pilot") {
    // Only the explicitly labelled pilot bridge queues the strategist's packages.
    // Supervisor and unlabelled full-surface sessions may read or stop.
    const packages = createPackageQueue(currentRunDir, bridge);
    setInterval(() => { void packages.tick(); }, 1_000).unref();
  }
  await server.connect(new StdioServerTransport());
}
