import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { Bridge } from "../bridge.js";
import { RconClient } from "../rcon.js";
import { assertConnectionCompatibility, assertRuntimeCompatibility } from "../compatibility.js";
import { companionVersion, diagnoseConfig, type ConfigDiagnostic, type RconSettings } from "../config.js";
import { normalizeObservation } from "./observation.js";
import { executeRunPlan, queuePlanSchema, runPlanSchema, type RunPlanResult } from "./runPlan.js";
import { normalizeCanPlace, normalizeInspection, normalizeMapSummary, normalizePhysicalRoute, normalizePlacementSearch, normalizePlanDiagnostics, normalizeProductionRequirements, toolPayloads } from "./toolPayloads.js";

export { normalizeObservation, toolPayloads };
export const MCP_SERVER_VERSION = "0.13.3";

const position = z.object({ x: z.number(), y: z.number() });
const items = z.record(z.string(), z.number().int().positive());
export function result(value: unknown, isError = false) {
  const text = typeof value === "string" ? value : JSON.stringify(value);
  return { content: [{ type: "text" as const, text }], structuredContent: typeof value === "object" && value !== null ? value as Record<string, unknown> : undefined, isError };
}

export async function connectStatus(bridge: () => Promise<Bridge>, configDiagnostic: () => ConfigDiagnostic) {
  const diagnostic = configDiagnostic();
  if (!diagnostic.ok) return result(`Offline: ${diagnostic.error}`, false);
  const b = await bridge();
  let ping: any = await b.call("ping");
  assertRuntimeCompatibility(ping, companionVersion());
  if (!ping.companion_exists) {
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
export function registerMcpTools(server: ToolRegistrar, bridge: () => Promise<Bridge>, configDiagnostic: () => ConfigDiagnostic): void {
  const rpc = async (method: any, params: unknown = {}) => {
    try { return result(await (await bridge()).call(method, params)); }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  };
  const task = async (type: string, params: Record<string, unknown>) => {
    try { return result(await (await bridge()).enqueueAndWait({ type, ...params } as never)); }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  };

  server.registerTool("connect_status", { description: "Validate config, RCON, mod, app and protocol, then bind the exact connected native player named Codex without creating a character.", inputSchema: z.object({}) }, async () => {
    try {
      return await connectStatus(bridge, configDiagnostic);
    } catch (error) { return result(`Offline: ${error instanceof Error ? error.message : String(error)}`, false); }
  });
  server.registerTool("observe_local", { description: "Current deterministic local text observation centered on Codex; compact omits only the ASCII grid.", inputSchema: z.object({ radius: z.number().int().min(5).max(30).default(15), detail: z.enum(["compact", "full"]).default("compact") }) }, async ({ radius, detail }) => {
    try { return result(normalizeObservation(await (await bridge()).call("observe_local", { radius, detail }))); }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("inspect_entity", { description: "Batch-inspect entities at up to 16 exact positions within 30 tiles, including machine state, inventories, belt contents, a drill's current resource target, and an inserter's live pickup/drop positions and valid targets.", inputSchema: z.object({ positions: z.array(position).min(1).max(16) }) }, async ({ positions }) => {
    try { return result(normalizeInspection(await (await bridge()).call("inspect", toolPayloads.inspect(positions)))); }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("describe_prototype", { description: "Batch-describe up to 10 exact item, entity, or recipe prototypes; kind=auto resolves placeable items as entities, then genuine items, then recipes.", inputSchema: z.object({ names: z.array(z.string()).min(1).max(10), kind: z.enum(["auto", "entity", "recipe", "item"]).default("auto") }) }, async (p) => rpc("describe_prototype", p));
  server.registerTool("progression_status", { description: "Read research progression from Codex's live force.", inputSchema: z.object({}) }, async () => rpc("progression_status"));
  server.registerTool("can_place", { description: "Batch-check up to 24 identified placements within 30 tiles without side effects; every result retains the requested item, position, direction and rejection reason.", inputSchema: z.object({ placements: z.array(position.extend({ name: z.string(), direction: z.number().int().min(0).max(15).optional() })).min(1).max(24) }) }, async ({ placements }) => {
    try { return result(normalizeCanPlace(await (await bridge()).call("can_place", toolPayloads.canPlace(placements)), placements)); }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("find_placement", { description: "Find stable nearest force-charted positions within 30 tiles of Codex using Factorio's authoritative placement check; drill candidates include resource coverage, while optional output_target binds a machine or cardinal inserter output to an exact recipient.", inputSchema: z.object({ item: z.string(), preferred: position, radius: z.number().int().min(1).max(30).default(10), directions: z.array(z.number().int().min(0).max(15)).min(1).max(16).default([0, 4, 8, 12]), limit: z.number().int().min(1).max(24).default(8), output_target: position.optional() }).strict() }, async (p) => {
    try { return result(normalizePlacementSearch(await (await bridge()).call("find_placement", toolPayloads.findPlacement(p)))); }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("map_summary", { description: "Summarize only already force-charted chunks: resource totals, shoreline edges, factory landmarks and observation ticks. Never charts or generates terrain.", inputSchema: z.object({}).strict() }, async () => {
    try { return result(normalizeMapSummary(await (await bridge()).call("map_summary", {}))); }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("production_requirements", { description: "Expand target item/fluid units through the unlocked deterministic production DAG into recipe executions, per-execution units, raw/product units, categories and seconds at crafting speed 1; recipe_choices resolves genuine multi-recipe ambiguity.", inputSchema: z.object({ targets: z.record(z.string(), z.number().int().positive()).refine((value) => Object.keys(value).length >= 1 && Object.keys(value).length <= 16, "targets must contain 1-16 entries"), recipe_choices: z.record(z.string(), z.string()).optional() }).strict() }, async (p) => {
    try { return result(normalizeProductionRequirements(await (await bridge()).call("production_requirements", toolPayloads.productionRequirements(p)))); }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("connect_entities", { description: "Build a deterministic physical belt, pipe or power route between exact force-charted endpoints through the existing inventory-backed build runner, respecting the selected prototype, maximum length, walking, reach, collision and elapsed time; never creates ghosts.", inputSchema: z.object({ kind: z.enum(["belt", "pipe", "power"]), prototype: z.string(), from: position, to: position, max_length: z.number().int().min(1).max(25).default(25) }).strict() }, async (p) => {
    try {
      const b = await bridge();
      const route: any = normalizePhysicalRoute(await b.call("connect_entities", toolPayloads.connectEntities(p)));
      const detail = route.steps.length === 0
        ? "endpoints already have a physical connection"
        : await b.enqueueAndWait({ type: "build_plan", ...toolPayloads.buildPlan(route.steps, { auto_craft: true, stop_on_error: true }) } as never);
      return result({ ...route, status: "completed", detail });
    }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("walk_to", { description: "Scout or relocate by walking physically to an exact position; positional actions already auto-approach.", inputSchema: position }, async (p) => task("walk_to", toolPayloads.target(p)));
  server.registerTool("mine", { description: "Auto-approach and physically mine an exact target. target_kind=natural is the default for resources, trees and rocks; target_kind=owned explicitly recovers one empty player-owned minable entity. No implicit overlap priority or by-name discovery.", inputSchema: position.extend({ count: z.number().int().min(1).max(200).default(1), target_kind: z.enum(["natural", "owned"]).default("natural") }).strict() }, async (p) => task("mine", toolPayloads.mine(p)));
  server.registerTool("pickup_items", { description: "Auto-approach and physically pick up one exact item stack reported by observe_local. The item and count must still match, the full stack must fit, and Factorio's normal picking state performs collection.", inputSchema: position.extend({ item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict() }, async (p) => task("pickup", toolPayloads.pickup(p)));
  server.registerTool("place_entity", { description: "Auto-approach and place an inventory item at an exact position; optional output_target requires Factorio to bind that exact output recipient.", inputSchema: position.extend({ name: z.string(), direction: z.number().int().optional(), output_target: position.strict().optional() }).strict() }, async (p) => task("place", toolPayloads.place(p)));
  const craftInput = z.object({ recipe: z.string(), crafts: z.number().int().min(1).max(100), wait_for_completion: z.boolean().default(true) }).strict();
  server.registerTool("craft_items", { description: "Queue an exact number of legitimate Factorio recipe crafts (not output items); reports expected or actual product-item counts.", inputSchema: craftInput }, async (p) => task("craft", toolPayloads.craft(p)));
  server.registerTool("insert_items", { description: "Auto-approach and insert carried items into an exact-position entity.", inputSchema: position.extend({ items }) }, async (p) => task("insert", toolPayloads.insert(p)));
  server.registerTool("extract_items", { description: "Auto-approach and extract named items, or everything when items is omitted, from an exact-position entity.", inputSchema: position.extend({ items: items.optional() }) }, async (p) => task("extract", toolPayloads.extract(p)));
  server.registerTool("set_recipe", { description: "Auto-approach and set an exact-position crafting machine recipe.", inputSchema: position.extend({ recipe: z.string() }) }, async (p) => task("set_recipe", toolPayloads.recipe(p)));
  server.registerTool("rotate_entity", { description: "Auto-approach and rotate an exact-position entity once, or set Factorio direction 0–15.", inputSchema: position.extend({ direction: z.number().int().min(0).max(15).optional() }) }, async (p) => task("rotate", toolPayloads.rotate(p)));
  server.registerTool("build_plan", { description: "Build layouts of up to 25 sequential placements; optional output_target verifies Factorio's exact output recipient; auto-craft is legitimate and failures stop by default.", inputSchema: z.object({ steps: z.array(position.extend({ name: z.string(), direction: z.number().int().optional(), output_target: position.strict().optional(), recipe: z.string().optional(), insert: items.optional() })).min(1).max(25), auto_craft: z.boolean().default(true), stop_on_error: z.boolean().default(true) }) }, async ({ steps, ...rest }) => task("build_plan", toolPayloads.buildPlan(steps, rest)));
  server.registerTool("queue_plan", { description: "Immediately queue one contiguous 1-25-step physical plan, optionally after a successful predecessor.", inputSchema: queuePlanSchema }, async (input) => rpc("queue_plan", queuePlanSchema.parse(input)));
  server.registerTool("plan_status", { description: "Read a queued, running, or terminal plan with step outcomes and terminal observation.", inputSchema: z.object({ plan_id: z.number().int().positive() }) }, async (p) => {
    try {
      const value: any = await (await bridge()).call("plan_status", p);
      if (value.observation) value.observation = normalizeObservation(value.observation);
      return result(normalizePlanDiagnostics(value), value.status === "failed" || value.status === "cancelled");
    } catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("run_plan", { description: "Run 1–25 known dependent physical steps sequentially with fail-fast cancellation and a final observation; prefer this for two or more dependent actions.", inputSchema: runPlanSchema }, async (input, extra) => {
    const parsed = runPlanSchema.parse(input);
    try {
      const outcome = await executeRunPlan(await bridge(), parsed, extra?.signal);
      return result(normalizePlanDiagnostics(outcome), outcome.status !== "completed");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const status = extra?.signal?.aborted ? "cancelled" : "failed";
      const outcome: RunPlanResult = {
        status,
        completed_steps: 0,
        outcomes: [],
        observation_error: message,
      };
      return result(normalizePlanDiagnostics(outcome), true);
    }
  });
  server.registerTool("start_research", { description: "Start an unlocked technology using the force's real research queue.", inputSchema: z.object({ technology: z.string() }) }, async (p) => rpc("start_research", p));
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

export async function runMcpServer(configDiagnostic: () => ConfigDiagnostic = diagnoseConfig): Promise<void> {
  const server = new McpServer({ name: "factorio-codex", version: MCP_SERVER_VERSION }, { instructions: "Control one physical Factorio character named Codex. Keep one rolling current plan plus one prepared successor. Never use screenshots or screen capture." });
  const bridge = createBridgeProvider(configDiagnostic);
  registerMcpTools(server as unknown as ToolRegistrar, bridge, configDiagnostic);
  await server.connect(new StdioServerTransport());
}
