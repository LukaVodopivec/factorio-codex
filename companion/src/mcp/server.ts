import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { Bridge } from "../bridge.js";
import { RconClient } from "../rcon.js";
import { assertConnectionCompatibility, assertRuntimeCompatibility } from "../compatibility.js";
import { companionVersion, diagnoseConfig, type ConfigDiagnostic, type RconSettings } from "../config.js";
import { createOrdersTracker, createPackageQueue, packageFailures, readPackageQueue, type RunDir } from "../coordination/orders.js";
import { currentRunDir } from "../server/server.js";
import { eventSummary, nextEventSchema, waitForEvent, type FailureDelivery } from "./events.js";
import { normalizeObservation } from "./observation.js";
import { blockFields, executeRunPlan, layoutFields, planStatusSchema, queuePlanSchema, runPlanSchema, waitForPlanStatus, type RunPlanResult } from "./runPlan.js";
import { normalizeActivityLog, normalizeCanPlace, normalizeFactoryStatus, normalizeFifo, normalizeInspection, normalizeMapSummary, normalizePhysicalRoute, normalizePlacementSearch, normalizePlanDiagnostics, normalizeProductionRequirements, planStatusSummary, queuedPlanSummary, toolPayloads } from "./toolPayloads.js";

export { normalizeObservation, toolPayloads };
export const MCP_SERVER_VERSION = "0.21.0";

const position = z.object({ x: z.number(), y: z.number() });
const beltToGroundType = z.enum(["input", "output"]).optional();
const items = z.record(z.string(), z.number().int().positive());
const walkInput = position.extend({ arrival_mode: z.enum(["exact", "vicinity"]).default("exact"),
  arrival_radius: z.number().min(0.5).max(6).default(1) }).strict()
  .refine((p) => p.arrival_mode === "vicinity" || p.arrival_radius === 1,
    { message: "exact arrival uses the fixed 1-tile tolerance; use vicinity for a wider radius", path: ["arrival_radius"] });
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
export const FACTORY_STATUS_SECTIONS = ["lines", "problems", "power", "stock", "research", "body", "patches"] as const;

export type McpSurface = "full" | "read-only";
export const READ_ONLY_TOOLS = [
  "connect_status", "map_summary", "progression_status", "production_requirements",
  "describe_prototype", "observe_local", "inspect_entity", "plan_status", "can_place", "find_placement",
  "factory_status", "activity_log", "next_event", "build_layout", "build_block",
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
        companion_dead: ping.companion_dead, read_only: true, ...(ping.fifo ? { fifo: ping.fifo } : {}),
        summary: "Connected read-only; no living Codex character is currently available",
      });
    }
    await b.call("spawn_companion", {});
    ping = await b.call("ping");
    assertRuntimeCompatibility(ping, companionVersion());
    if (!ping.companion_exists) throw new Error("native player 'Codex' did not provide a living character");
  }
  return result({
    status: "connected", app_version: companionVersion(), protocol_version: ping.protocol_version,
    mod_version: ping.mod_version, factorio_version: ping.factorio_version, tick: ping.tick,
    companion_exists: ping.companion_exists, companion_ever_created: ping.companion_ever_created,
    companion_dead: ping.companion_dead, ...(ping.fifo ? { fifo: ping.fifo } : {}),
  });
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
  if (value?.body) parts.push(`queue ${value.body.queue_depth ?? 0}${value.body.human_control ? ", human hold" : ""}`);
  return `tick ${value?.tick}: ${parts.join("; ")}`;
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
): void {
  const orders = createOrdersTracker(runDir);
  const failureDelivery: FailureDelivery = { keys: null };
  // Every result carries Astra's orders once per new ledger revision.
  const tools: ToolRegistrar = { registerTool: (name, config, handler) =>
    server.registerTool(name, config, async (args, extra) => orders.attach(await handler(args, extra))) };
  const rpc = async (method: any, params: unknown = {}) => {
    try { return result(await (await bridge()).call(method, params)); }
    catch (error) { return failure(error); }
  };
  // A TUI turn interruption aborts the MCP request; the bridge then cancels the owned game task.
  const task = async (type: string, params: Record<string, unknown>, signal?: AbortSignal) => {
    try {
      const terminal = signal
        ? await (await bridge()).enqueueAndWaitResult({ type, ...params } as never, { signal })
        : await (await bridge()).enqueueAndWaitResult({ type, ...params } as never);
      const status = terminal.status === "done" ? "completed" : terminal.status;
      return result({ status, terminal: true, summary: terminal.detail || status,
        ...(terminal.human_control ? { human_control: true } : {}),
        ...(terminal.outcome ?? {}), next_action: null }, status === "failed" || status === "cancelled");
    } catch (error) { return failure(error); }
  };
  const runPlan = async (input: unknown, signal?: AbortSignal) => {
    const parsed = runPlanSchema.parse(input);
    try {
      const outcome = await executeRunPlan(await bridge(), parsed, signal);
      const terminal = ["completed", "partial", "failed", "cancelled"].includes(outcome.status);
      return result(normalizePlanDiagnostics({ ...outcome, terminal, next_action: terminal ? null
        : { tool: "next_event", arguments: { timeout_seconds: 60 } } }),
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
  // build_layout/build_block: a dry run is a read-only mod check; a build is a one-step plan.
  const build = async (action: "build_layout" | "build_block", { check_only, ...params }: Record<string, unknown>, signal?: AbortSignal) => {
    if (check_only) return rpc(action, { ...params, check_only: true });
    return runPlan({ steps: [{ action, ...params }] }, signal);
  };
  const layoutSite = (layout: { anchor?: unknown; site?: unknown }) => (layout.anchor === undefined) !== (layout.site === undefined);
  const siteMessage = { message: "give exactly one of anchor or site" };
  const layoutSchema = z.object({ ...layoutFields, check_only: surface === "full" ? z.boolean().default(false) : z.literal(true).default(true) })
    .strict().refine(layoutSite, siteMessage);
  const blockSchema = z.object({ ...blockFields, check_only: surface === "full" ? z.boolean().default(false) : z.literal(true).default(true) }).strict();
  const dryRun = (surface === "full" ? " check_only: true is a dry run that builds nothing." : " Dry run only: checks without building.")
    + " A dry run does one tick of site search: SITE_SEARCH_INCOMPLETE means no site was found yet, not that none fits.";

  tools.registerTool("connect_status", { description: "Check config, RCON, mod and protocol versions, then bind the connected native player named Codex.", inputSchema: z.object({}) }, async () => {
    try {
      return await connectStatus(bridge, configDiagnostic, surface === "full");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return result({ status: "offline", terminal: true, summary: `Offline: ${message}`, next_action: null }, false);
    }
  });
  tools.registerTool("observe_local", { description: "Nearby entities, ground items and resource patches around the body. compact is bounded; full returns more.", inputSchema: z.object({ radius: z.number().int().min(5).max(30).default(15), detail: z.enum(["compact", "full"]).default("compact") }) }, async ({ radius, detail }) => {
    try { return result(normalizeObservation(await (await bridge()).call("observe_local", { radius, detail }))); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("inspect_entity", { description: 'Inspect up to 16 exact positions. Beyond 30 tiles only own entities in charted chunks are read, marked remote: true. Input: {"positions":[{"x":1.5,"y":2.5}]}.', inputSchema: z.object({ positions: z.array(position).min(1).max(16) }) }, async ({ positions }) => {
    try { return result(normalizeInspection(await (await bridge()).call("inspect", toolPayloads.inspect(positions)))); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("describe_prototype", { description: "Describe up to 10 item, entity or recipe prototypes; auto tries entity, then item, then recipe.", inputSchema: z.object({ names: z.array(z.string()).min(1).max(10), kind: z.enum(["auto", "entity", "recipe", "item"]).default("auto") }) }, async (p) => rpc("describe_prototype", p));
  tools.registerTool("progression_status", { description: "Researched technologies, what can be researched now, and what each unlocks.", inputSchema: z.object({}) }, async () => rpc("progression_status"));
  tools.registerTool("can_place", { description: "Check up to 24 placements without building. Each result keeps the request and gives can_place, the reason, overlaps_batch (indexes of overlapping placements in the batch), and what an inserter would pick up from and drop onto.", inputSchema: z.object({ placements: z.array(position.extend({ name: z.string(), direction: z.number().int().min(0).max(15).optional() })).min(1).max(24) }) }, async ({ placements }) => {
    try { return result(normalizeCanPlace(await (await bridge()).call("can_place", toolPayloads.canPlace(placements)), placements)); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("find_placement", { description: "Find valid placements near a point, nearest first. Requests with input_target, output_target, or output_recipient_item require cardinal directions only: 0, 4, 8, 12. Each candidate's plan_steps go straight into queue_plan (with fuel inserts when fuel is given). An empty result has a hint: change the request as it says.", inputSchema: z.object({ item: z.string(), preferred: position, radius: z.number().int().min(1).max(30).default(10), directions: z.array(z.number().int().min(0).max(15)).min(1).max(16).default([0, 4, 8, 12]), limit: z.number().int().min(1).max(24).default(8), input_target: position.optional(), output_target: position.optional(), output_recipient_item: z.string().min(1).optional(), belt_to_ground_type: beltToGroundType, fuel: items.optional() }).strict().refine((p) => !(p.output_target && p.output_recipient_item), "use output_target or output_recipient_item, not both").refine((p) => !(p.input_target !== undefined || p.output_target !== undefined || p.output_recipient_item !== undefined) || p.directions.every((direction) => direction % 4 === 0), { message: "targeted placement directions must be cardinal: 0, 4, 8, or 12", path: ["directions"] }) }, async (p) => {
    try { return result(normalizePlacementSearch(await (await bridge()).call("find_placement", toolPayloads.findPlacement(p)), p.fuel)); }
    catch (error) { return failure(error); }
  });
  const mapSummarySchema = z.object({
    detail: z.enum(["aggregate", "full"]).default("aggregate"),
    flow_precision: z.enum(["five_seconds", "one_minute", "ten_minutes", "one_hour"]).default("one_minute"),
    flow_items: z.array(z.string().min(1)).max(32).optional(),
    flow_fluids: z.array(z.string().min(1)).max(32).optional(),
    activity_since_tick: z.number().int().nonnegative().optional(),
    include: z.array(z.enum(MAP_SUMMARY_SECTIONS)).max(MAP_SUMMARY_SECTIONS.length).optional(),
  }).strict();
  tools.registerTool("map_summary", { description: "Detailed graph of the charted own factory: machine groups, flow rates, connections, line counts and character transfers. Prefer factory_status for routine reads. include adds capped sections: stockpiles, sites, patches, power, problems (problems_by_status counts every problem machine by status), flows_all. Reading is not reach.", inputSchema: mapSummarySchema }, async (p) => {
    try { return result(normalizeMapSummary(await (await bridge()).call("map_summary", mapSummarySchema.parse(p)))); }
    catch (error) { return failure(error); }
  });
  const productionRequirementsSchema = z.object({
    targets: z.record(z.string(), z.number().positive()).refine((value) => Object.keys(value).length >= 1 && Object.keys(value).length <= 16, "targets must contain 1-16 entries").optional(),
    technology: z.string().min(1).optional(), location: z.string().min(1).optional(),
    recipe_choices: z.record(z.string(), z.string()).optional(),
    flow_precision: z.enum(["five_seconds", "one_minute", "ten_minutes", "one_hour"]).default("one_minute"),
  }).strict().superRefine((value, ctx) => {
    const modes = Number(value.targets !== undefined) + Number(value.technology !== undefined) + Number(value.location !== undefined);
    if (modes !== 1) ctx.addIssue({ code: "custom", message: "provide exactly one of targets, technology, or location" });
  });
  tools.registerTool("production_requirements", { description: 'Expand item targets, a technology, or a space location into recipes, raw materials and prerequisites. Input: {"targets":{"automation-science-pack":10}}, {"technology":"automation"} or {"location":"solar-system-edge"}.', inputSchema: productionRequirementsSchema }, async (p) => {
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
        next_action: terminal ? null : { tool: "next_event", arguments: { timeout_seconds: 60 } },
      }), value.status === "failed" || value.status === "cancelled");
    } catch (error) { return failure(error); }
  });
  const factoryStatusSchema = z.object({
    since_tick: z.number().int().nonnegative().optional(),
    sections: z.array(z.enum(FACTORY_STATUS_SECTIONS)).min(1).max(FACTORY_STATUS_SECTIONS.length).optional(),
  }).strict();
  tools.registerTool("factory_status", { description: "One compact read of the whole factory: production lines with state (running, starved, output_full, no_fuel, no_power, idle), rate, cause and position; problem machines; power; stock; research; the body; nearby resource patches. since_tick returns only lines and problems changed since then; sections picks parts.", inputSchema: factoryStatusSchema }, async (p) => {
    try {
      const value = normalizeFactoryStatus(await (await bridge()).call("factory_status", factoryStatusSchema.parse(p)));
      return result({ ...value, summary: factoryStatusSummary(value) });
    } catch (error) { return failure(error); }
  });
  const activityLogSchema = z.object({ since_plan_id: z.number().int().nonnegative().optional(), limit: z.number().int().min(1).max(64).default(16) }).strict();
  tools.registerTool("activity_log", { description: "What the body did: recent plan outcomes, oldest first, each with source (pilot, upkeep or package:<id>), status and a summary; plus the queue status of Astra's packages.", inputSchema: activityLogSchema }, async (p) => {
    try {
      const value = normalizeActivityLog(await (await bridge()).call("activity_log", activityLogSchema.parse(p)));
      const dir = runDir();
      const packages = Object.entries((dir ? readPackageQueue(dir)?.packages : undefined) ?? {}).slice(-16)
        .map(([package_id, record]) => ({ package_id, ...record }));
      const entries: any[] = value?.entries ?? [];
      return result({ ...value, ...(packages.length ? { packages } : {}),
        summary: `${entries.length} plan outcomes${entries.length ? `; last: plan ${entries.at(-1)?.plan_id} ${entries.at(-1)?.summary ?? ""}` : ""}` });
    } catch (error) { return failure(error); }
  });
  tools.registerTool("next_event", { description: "Wait up to timeout_seconds for the next thing to act on: plan_ended, queue_empty, new_problem, package_failed, orders_changed, human_hold_started, human_hold_ended, or timeout. Without since_tick an already empty queue returns queue_empty at once; with since_tick, a plan end, problem or package failure after that tick returns at once.", inputSchema: nextEventSchema }, async (input, extra) => {
    try {
      const value = await waitForEvent(await bridge(), nextEventSchema.parse(input), {
        ordersChanged: orders.changed,
        packageFailures: () => { const dir = runDir(); return dir ? packageFailures(dir) : []; },
        delivery: failureDelivery,
      }, extra?.signal);
      return result({ ...value, status: "completed", terminal: true, summary: eventSummary(value), next_action: null });
    } catch (error) { return failure(error); }
  });
  tools.registerTool("build_layout", { description: `Build a layout given as offsets (dx, dy) from an anchor, or from a site the mod finds (near a point, on a resource, near water): entities with direction and recipe, plus belt, pipe and power connections. The mod checks every placement, fetches or crafts the materials, clears trees and rocks, walks and builds.${dryRun}`, inputSchema: layoutSchema }, async (p, extra) => {
    try { return await build("build_layout", layoutSchema.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  tools.registerTool("build_block", { description: `Build count copies of a standard block near a point: mining (drills on a resource), smelting (furnace column), assembly (assembler row for a recipe), power (steam at water), labs. The mod works out tiles and directions, then builds it like build_layout.${dryRun}`, inputSchema: blockSchema }, async (p, extra) => {
    try { return await build("build_block", blockSchema.parse(p), extra?.signal); }
    catch (error) { return failure(error); }
  });
  if (surface === "read-only") return;
  tools.registerTool("get_items", { description: "Get count of an item into the inventory: from the nearest own chest, belt or machine output, else by crafting it with its intermediates, else by hand-gathering a raw resource no drill produces. The result names any shortfall.", inputSchema: z.object({ item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict() }, async (p, extra) =>
    runPlan({ steps: [{ action: "get_items", ...p }] }, extra?.signal));
  tools.registerTool("connect_entities", { description: "Build a belt, pipe or power-pole route of at most 25 pieces between two exact points, walking and placing from the inventory.", inputSchema: z.object({ kind: z.enum(["belt", "pipe", "power"]), prototype: z.string(), from: position, to: position, max_length: z.number().int().min(1).max(25).default(25) }).strict() }, async (p, extra) => {
    try {
      const b = await bridge();
      const route: any = normalizePhysicalRoute(await b.call("connect_entities", toolPayloads.connectEntities(p)));
      const detail = route.steps.length === 0
        ? "endpoints already have a physical connection"
        : await b.enqueueAndWait({ type: "build_plan", ...toolPayloads.buildPlan(route.steps, { auto_craft: true, stop_on_error: true }) } as never, ...(extra?.signal ? [{ signal: extra.signal }] : []));
      if (p.kind !== "power") return result({ ...route, status: "completed", terminal: true, summary: detail, detail, next_action: null });

      const ordered = [p.from, ...route.steps.map((step: any) => ({ x: step.x, y: step.y })), p.to];
      const inspected: Array<{ position: { x: number; y: number }; network_id: number | null }> = new Array(ordered.length);
      for (let offset = 0; offset < ordered.length; offset += 16) {
        const points = ordered.slice(offset, offset + 16);
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
    }
    catch (error) { return failure(error); }
  });
  tools.registerTool("walk_to", { description: "Walk to a point. exact stops within 1 tile; vicinity accepts a free spot within arrival_radius. Other actions walk to their targets by themselves.", inputSchema: walkInput }, async (p, extra) => task("walk_to", toolPayloads.target(p), extra?.signal));
  tools.registerTool("mine", { description: "Mine the entity or resource at a position, count times. target_kind picks natural or owned where both overlap; owned removes your own empty building. A result with drill_produced: true means own drills already mine it: take it from their output instead.", inputSchema: position.extend({ count: z.number().int().min(1).max(200).default(1), target_kind: z.enum(["natural", "owned"]).optional(), allow_fluid_loss: z.boolean().default(false), expected_name: z.string().min(1).optional(), observed_tick: z.number().int().nonnegative().optional() }).strict() }, async (p, extra) => task("mine", toolPayloads.mine(p), extra?.signal));
  tools.registerTool("pickup_items", { description: "Pick up one item stack from the ground, or take count items riding a plain belt tile. The whole count must fit in the inventory or nothing is taken; nothing is created; a belt tile that runs dry ends the step with the count actually picked up.", inputSchema: position.extend({ item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict() }, async (p, extra) => task("pickup", toolPayloads.pickup(p), extra?.signal));
  tools.registerTool("place_entity", { description: 'Place one item at a position. auto_supply (default on) fetches or crafts it first; trees and rocks in the way are cleared. Use name, never item: {"name":"wooden-chest","x":1.5,"y":2.5}. Optional input_target/output_target must match what an inserter picks from and drops into. Underground belts take belt_to_ground_type input|output.', inputSchema: position.extend({ name: z.string(), direction: z.number().int().optional(), input_target: position.strict().optional(), output_target: position.strict().optional(), belt_to_ground_type: beltToGroundType, auto_supply: z.boolean().optional() }).strict() }, async (p, extra) => task("place", toolPayloads.place(p), extra?.signal));
  const craftInput = z.object({ recipe: z.string(), crafts: z.number().int().min(1).max(100), wait_for_completion: z.boolean().default(true) }).strict();
  tools.registerTool("craft_items", { description: 'Hand-craft a recipe a number of times: {"recipe":"iron-gear-wheel","crafts":2}.', inputSchema: craftInput }, async (p, extra) => task("craft", toolPayloads.craft(p), extra?.signal));
  tools.registerTool("insert_items", { description: "Put items from the inventory into the entity at a position. auto_supply (default on) fetches missing items first. A partial insert reports what is left.", inputSchema: position.extend({ items, auto_supply: z.boolean().optional() }) }, async (p, extra) => task("insert", toolPayloads.insert(p), extra?.signal));
  tools.registerTool("extract_items", { description: "Take the named items, or everything when items is omitted, out of the entity at a position.", inputSchema: position.extend({ items: items.optional() }) }, async (p, extra) => task("extract", toolPayloads.extract(p), extra?.signal));
  tools.registerTool("set_recipe", { description: "Set the recipe of your assembler at a position. Furnaces choose their own recipe from their input.", inputSchema: position.extend({ recipe: z.string() }) }, async (p, extra) => task("set_recipe", toolPayloads.recipe(p), extra?.signal));
  tools.registerTool("rotate_entity", { description: "Rotate the entity at a position once, or set its direction 0-15.", inputSchema: position.extend({ direction: z.number().int().min(0).max(15).optional() }) }, async (p, extra) => task("rotate", toolPayloads.rotate(p), extra?.signal));
  tools.registerTool("build_plan", { description: "Place up to 25 items in order; each may set a recipe and insert items. Stops at the first failure by default; earlier placements stay.", inputSchema: z.object({ steps: z.array(position.extend({ name: z.string(), direction: z.number().int().optional(), input_target: position.strict().optional(), output_target: position.strict().optional(), belt_to_ground_type: beltToGroundType, recipe: z.string().optional(), insert: items.optional() })).min(1).max(25), auto_craft: z.boolean().default(true), auto_supply: z.boolean().optional(), stop_on_error: z.boolean().default(true) }) }, async ({ steps, ...rest }, extra) => task("build_plan", toolPayloads.buildPlan(steps, rest), extra?.signal));
  tools.registerTool("queue_plan", { description: "Queue a plan of 1-200 steps and return at once, so the body works while you think. Prefer goal-level steps: get_items, build_layout, build_block. after_plan_id runs it only after that plan completes. Wait with next_event.", inputSchema: queuePlanSchema }, async (input) => {
    try {
      const queued: any = await (await bridge()).call("queue_plan", queuePlanSchema.parse(input));
      return result({ ...queued, status: "queued", terminal: false, summary: queuedPlanSummary(queued),
        next_action: { tool: "next_event", arguments: { timeout_seconds: 60 } } });
    } catch (error) { return failure(error); }
  });
  tools.registerTool("run_plan", { description: "Run 1-200 steps and block until the plan is terminal (up to 570 s, then it returns the plan still running and never cancels it); the queue stays empty while you then think, so prefer queue_plan.", inputSchema: runPlanSchema }, async (input, extra) => runPlan(input, extra?.signal));
  tools.registerTool("start_research", { description: "Start researching an unlocked technology.", inputSchema: z.object({ technology: z.string() }) }, async (p) => rpc("start_research", p));
  tools.registerTool("stop", { description: "Emergency stop: cancels the active and queued plans and hand-crafting. Supervisor only, never for gameplay or routine recovery.", inputSchema: z.object({}) }, async () => rpc("cancel", { all: true }));
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
): Promise<void> {
  const instructions = surface === "read-only"
    ? "Read Factorio state without moving, mutating, queueing, cancelling, or controlling the Codex character."
    : "Control one physical Factorio character named Codex. queue_plan returns immediately, while run_plan and single physical tools hold the only physical slot until they finish. Wait with next_event instead of polling. Never use screenshots or screen capture.";
  const server = new McpServer({ name: "factorio-codex", version: MCP_SERVER_VERSION }, { instructions });
  const bridge = createBridgeProvider(configDiagnostic);
  registerMcpTools(server as unknown as ToolRegistrar, bridge, configDiagnostic, surface, currentRunDir);
  if (surface === "full") {
    // Astra's packages start without a pilot turn; one full-surface process per run queues them.
    const packages = createPackageQueue(currentRunDir, bridge);
    setInterval(() => { void packages.tick(); }, 1_000).unref();
  }
  await server.connect(new StdioServerTransport());
}
