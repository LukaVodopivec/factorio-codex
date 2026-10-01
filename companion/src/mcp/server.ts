import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { Bridge } from "../bridge.js";
import { RconClient } from "../rcon.js";
import { assertConnectionCompatibility, assertRuntimeCompatibility } from "../compatibility.js";
import { companionVersion, diagnoseConfig, type ConfigDiagnostic, type RconSettings } from "../config.js";
import { normalizeObservation } from "./observation.js";
import { executeRunPlan, planStatusSchema, queuePlanSchema, runPlanSchema, waitForPlanStatus, type RunPlanResult } from "./runPlan.js";
import { normalizeCanPlace, normalizeInspection, normalizeMapSummary, normalizePhysicalRoute, normalizePlacementSearch, normalizePlanDiagnostics, normalizeProductionRequirements, toolPayloads } from "./toolPayloads.js";

export { normalizeObservation, toolPayloads };
export const MCP_SERVER_VERSION = "0.17.0";

const position = z.object({ x: z.number(), y: z.number() });
const items = z.record(z.string(), z.number().int().positive());
const walkInput = position.extend({ arrival_mode: z.enum(["exact", "vicinity"]).default("exact"),
  arrival_radius: z.number().min(0.5).max(6).default(1) }).strict()
  .refine((p) => p.arrival_mode === "vicinity" || p.arrival_radius === 1,
    { message: "exact arrival uses the fixed 1-tile tolerance; use vicinity for a wider radius", path: ["arrival_radius"] });
export function result(value: unknown, isError = false) {
  const structured = value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : { status: isError ? "failed" : "completed", terminal: true, summary: String(value), next_action: null };
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
  return { content: [{ type: "text" as const, text: summary.slice(0, 500) }], structuredContent: structured, isError };
}

function failure(error: unknown, prefix = "Error") {
  const message = error instanceof Error ? error.message : String(error);
  return result({ status: "failed", terminal: true, code: "TOOL_ERROR", summary: `${prefix}: ${message}`, next_action: null }, true);
}

export type McpSurface = "full" | "read-only";
export const READ_ONLY_TOOLS = [
  "connect_status", "map_summary", "progression_status", "production_requirements",
  "describe_prototype", "observe_local", "inspect_entity", "plan_status",
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
        companion_dead: ping.companion_dead, read_only: true,
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
    companion_dead: ping.companion_dead,
  });
}

type ToolRegistrar = {
  registerTool(name: string, config: unknown, handler: (args: any, extra?: { signal?: AbortSignal }) => Promise<unknown>): unknown;
};

/** Register the complete public surface against an injectable bridge provider.
 *  Tests use the same handlers with a fake Bridge to prove the exact Lua DTOs. */
export function registerMcpTools(
  server: ToolRegistrar,
  bridge: () => Promise<Bridge>,
  configDiagnostic: () => ConfigDiagnostic,
  surface: McpSurface = "full",
): void {
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
        ...(terminal.outcome ?? {}), next_action: null }, status === "failed" || status === "cancelled");
    } catch (error) { return failure(error); }
  };

  server.registerTool("connect_status", { description: "Validate config, RCON, mod, app and protocol, then bind the exact connected native player named Codex without creating a character.", inputSchema: z.object({}) }, async () => {
    try {
      return await connectStatus(bridge, configDiagnostic, surface === "full");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return result({ status: "offline", terminal: true, summary: `Offline: ${message}`, next_action: null }, false);
    }
  });
  server.registerTool("observe_local", { description: "Current deterministic local observation. Compact returns bounded nearest entities, ground items, and resource patches with explicit omission counts; full deliberately requests larger bounded detail.", inputSchema: z.object({ radius: z.number().int().min(5).max(30).default(15), detail: z.enum(["compact", "full"]).default("compact") }) }, async ({ radius, detail }) => {
    try { return result(normalizeObservation(await (await bridge()).call("observe_local", { radius, detail }))); }
    catch (error) { return failure(error); }
  });
  server.registerTool("inspect_entity", { description: 'Batch-inspect up to 16 exact positions within 30 tiles. Canonical input: {"positions":[{"x":1.5,"y":2.5}]}.', inputSchema: z.object({ positions: z.array(position).min(1).max(16) }) }, async ({ positions }) => {
    try { return result(normalizeInspection(await (await bridge()).call("inspect", toolPayloads.inspect(positions)))); }
    catch (error) { return failure(error); }
  });
  server.registerTool("describe_prototype", { description: "Batch-describe up to 10 exact item, entity, or recipe prototypes; kind=auto resolves placeable items as entities, then genuine items, then recipes.", inputSchema: z.object({ names: z.array(z.string()).min(1).max(10), kind: z.enum(["auto", "entity", "recipe", "item"]).default("auto") }) }, async (p) => rpc("describe_prototype", p));
  server.registerTool("progression_status", { description: "Read researched technologies, ordinary queueable research, and action/trigger unlocks with authoritative item/entity quality filters and scripted descriptions from Codex's live force.", inputSchema: z.object({}) }, async () => rpc("progression_status"));
  if (surface === "full") {
    server.registerTool("can_place", { description: "Batch-check up to 24 identified placements within 30 tiles without side effects; every result retains the requested item, position, direction and rejection reason.", inputSchema: z.object({ placements: z.array(position.extend({ name: z.string(), direction: z.number().int().min(0).max(15).optional() })).min(1).max(24) }) }, async ({ placements }) => {
      try { return result(normalizeCanPlace(await (await bridge()).call("can_place", toolPayloads.canPlace(placements)), placements)); }
      catch (error) { return failure(error); }
    });
    server.registerTool("find_placement", { description: "Find stable force-charted placements. Optional input_target constrains an inserter pickup. Use either an existing output_target or output_recipient_item to search a provisional recipient-first pair; geometry never claims runtime binding.", inputSchema: z.object({ item: z.string(), preferred: position, radius: z.number().int().min(1).max(30).default(10), directions: z.array(z.number().int().min(0).max(15)).min(1).max(16).default([0, 4, 8, 12]), limit: z.number().int().min(1).max(24).default(8), input_target: position.optional(), output_target: position.optional(), output_recipient_item: z.string().min(1).optional() }).strict().refine((p) => !(p.output_target && p.output_recipient_item), "use output_target or output_recipient_item, not both") }, async (p) => {
      try { return result(normalizePlacementSearch(await (await bridge()).call("find_placement", toolPayloads.findPlacement(p)))); }
      catch (error) { return failure(error); }
    });
  }
  const mapSummarySchema = z.object({
    detail: z.enum(["aggregate", "full"]).default("aggregate"),
    flow_precision: z.enum(["five_seconds", "one_minute", "ten_minutes", "one_hour"]).default("one_minute"),
    flow_items: z.array(z.string().min(1)).max(32).optional(),
    flow_fluids: z.array(z.string().min(1)).max(32).optional(),
    activity_since_tick: z.number().int().nonnegative().optional(),
  }).strict();
  server.registerTool("map_summary", { description: "Compact aggregate of already charted, player-force factory entities: installed capacity estimates, normalized status, native force/surface flow rates, conservative physical connectivity, and run-local character transfers. Read material_flow.components[].state (autonomy_blockers, downstream_kind) and character_transfers to find the automation-debt head. It never charts terrain or exposes exact remote inventories. Use detail=full only for rare bounded landmark/resource/shoreline scouting.", inputSchema: mapSummarySchema }, async (p) => {
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
  server.registerTool("production_requirements", { description: 'Expand one item/fluid target map, technology prerequisite closure, or space-location unlock closure. Canonical inputs: {"targets":{"automation-science-pack":10}}, {"technology":"automation"}, or {"location":"solar-system-edge"}. Technology/location results separate deterministic requirements from triggers, ambiguities, and variable operating costs; exact remote inventories are never credited.', inputSchema: productionRequirementsSchema }, async (p) => {
    try { return result(normalizeProductionRequirements(await (await bridge()).call("production_requirements", toolPayloads.productionRequirements(p)))); }
    catch (error) { return failure(error); }
  });
  server.registerTool("plan_status", { description: "Read plan state immediately, or wait up to 60 seconds for a completed step, waiting state, or terminal outcome. Waiting monitors only and never cancels physical work.", inputSchema: planStatusSchema }, async (input, extra) => {
    try {
      const p = planStatusSchema.parse(input);
      const value: any = await waitForPlanStatus(await bridge(), p.plan_id, p.wait_until, p.timeout_seconds * 1_000, extra?.signal);
      if (value.observation) value.observation = normalizeObservation(value.observation);
      const terminal = ["completed", "partial", "failed", "cancelled"].includes(value.status);
      return result(normalizePlanDiagnostics({ ...value, terminal,
        next_action: terminal ? null : { tool: "plan_status", arguments: {
          plan_id: value.plan_id, wait_until: p.wait_until === "current" ? "progress" : p.wait_until, timeout_seconds: p.timeout_seconds,
        } },
      }), value.status === "failed" || value.status === "cancelled");
    } catch (error) { return failure(error); }
  });
  if (surface === "read-only") return;
  server.registerTool("connect_entities", { description: "Build a deterministic physical belt, pipe or power route between exact force-charted endpoints through the existing inventory-backed build runner, respecting the selected prototype, maximum length, walking, reach, collision and elapsed time; never creates ghosts.", inputSchema: z.object({ kind: z.enum(["belt", "pipe", "power"]), prototype: z.string(), from: position, to: position, max_length: z.number().int().min(1).max(25).default(25) }).strict() }, async (p, extra) => {
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
  server.registerTool("walk_to", { description: "Scout or relocate through ordinary native walking. exact uses the fixed 1-tile goal tolerance; vicinity explicitly permits a reported collision-free point within arrival_radius only after native path confirmation. Goal collisions and route failures are distinct, and recovery is capped at three progress-monotonic nonrepeated frontiers. Positional actions already auto-approach.", inputSchema: walkInput }, async (p, extra) => task("walk_to", toolPayloads.target(p), extra?.signal));
  server.registerTool("mine", { description: 'Auto-approach and physically mine the exact observed target without substituting a neighbor. Canonical fresh-observation input: {"x":3.25,"y":4.75,"count":1,"expected_name":"tree-01","observed_tick":12345}. Overlapping natural/owned targets require explicit target_kind; target_kind=owned recovers one empty player-owned entity through ordinary mining.', inputSchema: position.extend({ count: z.number().int().min(1).max(200).default(1), target_kind: z.enum(["natural", "owned"]).optional(), allow_fluid_loss: z.boolean().default(false), expected_name: z.string().min(1).optional(), observed_tick: z.number().int().nonnegative().optional() }).strict() }, async (p, extra) => task("mine", toolPayloads.mine(p), extra?.signal));
  server.registerTool("pickup_items", { description: "Auto-approach and physically pick up one exact item stack reported by observe_local. The item and count must still match, the full stack must fit, and Factorio's normal picking state performs collection.", inputSchema: position.extend({ item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict() }, async (p, extra) => task("pickup", toolPayloads.pickup(p), extra?.signal));
  server.registerTool("place_entity", { description: 'Auto-approach and place one inventory item. Optional input_target/output_target require exact runtime binding after placement; a failure leaves the placed entity committed. Canonical input: {"name":"wooden-chest","x":1.5,"y":2.5}; use name, never item.', inputSchema: position.extend({ name: z.string(), direction: z.number().int().optional(), input_target: position.strict().optional(), output_target: position.strict().optional() }).strict() }, async (p, extra) => task("place", toolPayloads.place(p), extra?.signal));
  const craftInput = z.object({ recipe: z.string(), crafts: z.number().int().min(1).max(100), wait_for_completion: z.boolean().default(true) }).strict();
  server.registerTool("craft_items", { description: 'Queue exact recipe crafts, not output items. Canonical input: {"recipe":"iron-gear-wheel","crafts":2}; use recipe/crafts, never items.', inputSchema: craftInput }, async (p, extra) => task("craft", toolPayloads.craft(p), extra?.signal));
  server.registerTool("insert_items", { description: "Auto-approach and insert exact carried item counts into an exact-position entity. Reports full completion, useful bounded partial completion with the truthful remainder, or zero-progress failure; dependent plan steps stop after a partial result.", inputSchema: position.extend({ items }) }, async (p, extra) => task("insert", toolPayloads.insert(p), extra?.signal));
  server.registerTool("extract_items", { description: "Auto-approach and extract named items, or everything when items is omitted, from an exact-position entity.", inputSchema: position.extend({ items: items.optional() }) }, async (p, extra) => task("extract", toolPayloads.extract(p), extra?.signal));
  server.registerTool("set_recipe", { description: "Auto-approach and set a player-owned crafting-machine recipe. Furnaces auto-select from inserted input; never call set_recipe on a furnace.", inputSchema: position.extend({ recipe: z.string() }) }, async (p, extra) => task("set_recipe", toolPayloads.recipe(p), extra?.signal));
  server.registerTool("rotate_entity", { description: "Auto-approach and rotate an exact-position entity once, or set Factorio direction 0–15.", inputSchema: position.extend({ direction: z.number().int().min(0).max(15).optional() }) }, async (p, extra) => task("rotate", toolPayloads.rotate(p), extra?.signal));
  server.registerTool("build_plan", { description: "Build up to 25 sequential placements. Optional input_target/output_target require exact runtime binding; use recipient-first build_steps returned by find_placement for coupled construction. Geometry is provisional, failures leave earlier placements committed, and failures stop by default.", inputSchema: z.object({ steps: z.array(position.extend({ name: z.string(), direction: z.number().int().optional(), input_target: position.strict().optional(), output_target: position.strict().optional(), recipe: z.string().optional(), insert: items.optional() })).min(1).max(25), auto_craft: z.boolean().default(true), stop_on_error: z.boolean().default(true) }) }, async ({ steps, ...rest }, extra) => task("build_plan", toolPayloads.buildPlan(steps, rest), extra?.signal));
  server.registerTool("queue_plan", { description: "Queue one contiguous 1–25-step physical plan and return immediately, so the body works while you read, reason, and queue one grounded successor with after_plan_id (a current plan ID). Use steps and documented action discriminators; never use summary/actions. A physical audit uses walk_to followed by inspect_entities (1–16 local positions), preserving per-step ticks and truthful partial results. The result carries the exact plan_status next action.", inputSchema: queuePlanSchema }, async (input) => {
    try {
      const queued: any = await (await bridge()).call("queue_plan", queuePlanSchema.parse(input));
      return result({ ...queued, status: "queued", terminal: false, summary: `queued plan ${queued.plan_id}`,
        next_action: { tool: "plan_status", arguments: { plan_id: queued.plan_id, wait_until: "progress", timeout_seconds: 30 } } });
    } catch (error) { return failure(error); }
  });
  server.registerTool("run_plan", { description: 'Run 1–25 dependent physical or local-inspection steps and block until the plan is terminal (up to 570 s): the physical FIFO stays empty while you then reason, so prefer queue_plan when a successor can be prepared. Canonical input: {"steps":[{"action":"craft_items","recipe":"iron-gear-wheel","crafts":2,"wait_for_completion":true}]}; physical audit pattern: walk_to then inspect_entities. Steps commit sequentially without rollback; use steps, never summary/actions.', inputSchema: runPlanSchema }, async (input, extra) => {
    const parsed = runPlanSchema.parse(input);
    try {
      const outcome = await executeRunPlan(await bridge(), parsed, extra?.signal);
      return result(normalizePlanDiagnostics({ ...outcome, terminal: true, next_action: null }), outcome.status === "failed" || outcome.status === "cancelled");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const status = extra?.signal?.aborted ? "cancelled" : "failed";
      const outcome: RunPlanResult = {
        status,
        outcomes: [],
        observation_error: message,
        execution: { mode: "sequential_nontransactional", rollback: "none", effects_state: "unknown" },
      };
      return result(normalizePlanDiagnostics({ ...outcome, terminal: true, next_action: null }), true);
    }
  });
  server.registerTool("start_research", { description: "Start ordinary unlocked research using the force's real queue; requested trigger technologies and missing trigger prerequisites return explicit in-game action guidance.", inputSchema: z.object({ technology: z.string() }) }, async (p) => rpc("start_research", p));
  server.registerTool("stop", { description: "Cancel active and queued work after a TUI interruption.", inputSchema: z.object({}) }, async () => rpc("cancel", { all: true }));
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
    : "Control one physical Factorio character named Codex. Keep one rolling current plan plus one prepared successor: queue_plan returns immediately, while run_plan and single physical tools hold the only physical slot until they finish. Never use screenshots or screen capture.";
  const server = new McpServer({ name: "factorio-codex", version: MCP_SERVER_VERSION }, { instructions });
  const bridge = createBridgeProvider(configDiagnostic);
  registerMcpTools(server as unknown as ToolRegistrar, bridge, configDiagnostic, surface);
  await server.connect(new StdioServerTransport());
}
