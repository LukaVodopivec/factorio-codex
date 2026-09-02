import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { Bridge } from "../bridge.js";
import { RconClient } from "../rcon.js";
import { assertConnectionCompatibility, assertRuntimeCompatibility } from "../compatibility.js";
import { companionVersion, diagnoseConfig, type ConfigDiagnostic, type RconSettings } from "../config.js";
import { normalizeObservation } from "./observation.js";
import { executeRunPlan, queuePlanSchema, runPlanSchema, type RunPlanResult } from "./runPlan.js";
import { toolPayloads } from "./toolPayloads.js";

export { normalizeObservation, toolPayloads };

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
  const ping: any = await b.call("ping");
  assertRuntimeCompatibility(ping, companionVersion());
  if (ping.companion_dead) return result("Connected, but Codex is dead. This interface never auto-respawns.", true);
  if (!ping.companion_exists && !ping.companion_ever_created) await b.call("spawn_companion", {});
  return result({ status: "connected", app_version: companionVersion(), protocol_version: ping.protocol_version, mod_version: ping.mod_version, factorio_version: ping.factorio_version, tick: ping.tick });
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

  server.registerTool("connect_status", { description: "Validate config, RCON, mod, app and protocol; create Codex only if this save never had one.", inputSchema: z.object({}) }, async () => {
    try {
      return await connectStatus(bridge, configDiagnostic);
    } catch (error) { return result(`Offline: ${error instanceof Error ? error.message : String(error)}`, false); }
  });
  server.registerTool("observe_local", { description: "Current deterministic local text observation centered on Codex; compact omits only the ASCII grid.", inputSchema: z.object({ radius: z.number().int().min(5).max(30).default(15), detail: z.enum(["compact", "full"]).default("compact") }) }, async ({ radius, detail }) => {
    try { return result(normalizeObservation(await (await bridge()).call("observe_local", { radius, detail }))); }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("inspect_entity", { description: "Batch-inspect entities at up to 16 exact positions within 30 tiles.", inputSchema: z.object({ positions: z.array(position).min(1).max(16) }) }, async ({ positions }) => rpc("inspect", toolPayloads.inspect(positions)));
  server.registerTool("describe_prototype", { description: "Batch-describe up to 10 exact prototypes; use {name,kind} to disambiguate same-named recipes/items/entities.", inputSchema: z.object({ names: z.array(z.union([z.string(), z.object({ name: z.string(), kind: z.enum(["item", "entity", "recipe"]) }).strict()])).min(1).max(10) }) }, async (p) => rpc("describe_prototype", p));
  server.registerTool("progression_status", { description: "Read research progression from Codex's live force.", inputSchema: z.object({}) }, async () => rpc("progression_status"));
  server.registerTool("can_place", { description: "Batch-check up to 24 placements within 30 tiles without side effects.", inputSchema: z.object({ placements: z.array(position.extend({ name: z.string(), direction: z.number().int().optional() })).min(1).max(24) }) }, async ({ placements }) => rpc("can_place", toolPayloads.canPlace(placements)));
  server.registerTool("walk_to", { description: "Scout or relocate by walking physically to an exact position; positional actions already auto-approach.", inputSchema: position }, async (p) => task("walk_to", toolPayloads.target(p)));
  server.registerTool("mine", { description: "Auto-approach and physically mine 1–200 cycles from the same entity at this exact visible position; no by-name discovery.", inputSchema: position.extend({ count: z.number().int().min(1).max(200).default(1) }) }, async (p) => task("mine", toolPayloads.mine(p)));
  server.registerTool("place_entity", { description: "Auto-approach and place an inventory item at an exact position.", inputSchema: position.extend({ name: z.string(), direction: z.number().int().optional() }) }, async (p) => task("place", toolPayloads.place(p)));
  server.registerTool("craft_items", { description: "Queue legitimate Factorio hand crafting; optionally return once Factorio accepts the queue.", inputSchema: z.object({ recipe: z.string(), count: z.number().int().positive(), wait_for_completion: z.boolean().default(true) }) }, async (p) => task("craft", p));
  server.registerTool("insert_items", { description: "Auto-approach and insert carried items into an exact-position entity.", inputSchema: position.extend({ items }) }, async (p) => task("insert", toolPayloads.insert(p)));
  server.registerTool("extract_items", { description: "Auto-approach and extract named items, or everything when items is omitted, from an exact-position entity.", inputSchema: position.extend({ items: items.optional() }) }, async (p) => task("extract", toolPayloads.extract(p)));
  server.registerTool("set_recipe", { description: "Auto-approach and set an exact-position crafting machine recipe.", inputSchema: position.extend({ recipe: z.string() }) }, async (p) => task("set_recipe", toolPayloads.recipe(p)));
  server.registerTool("rotate_entity", { description: "Auto-approach and rotate an exact-position entity once, or set Factorio direction 0–15.", inputSchema: position.extend({ direction: z.number().int().min(0).max(15).optional() }) }, async (p) => task("rotate", toolPayloads.rotate(p)));
  server.registerTool("build_plan", { description: "Build layouts of up to 25 sequential placements; auto-craft is legitimate and failures stop by default.", inputSchema: z.object({ steps: z.array(position.extend({ name: z.string(), direction: z.number().int().optional(), recipe: z.string().optional(), insert: items.optional() })).min(1).max(25), auto_craft: z.boolean().default(true), stop_on_error: z.boolean().default(true) }) }, async ({ steps, ...rest }) => task("build_plan", toolPayloads.buildPlan(steps, rest)));
  server.registerTool("queue_plan", { description: "Immediately queue one contiguous 1-25-step physical plan, optionally after a successful predecessor.", inputSchema: queuePlanSchema }, async (input) => rpc("queue_plan", queuePlanSchema.parse(input)));
  server.registerTool("plan_status", { description: "Read a queued, running, or terminal plan with step outcomes and terminal observation.", inputSchema: z.object({ plan_id: z.number().int().positive() }) }, async (p) => {
    try {
      const value: any = await (await bridge()).call("plan_status", p);
      if (value.observation) value.observation = normalizeObservation(value.observation);
      return result(value, value.status === "failed" || value.status === "cancelled");
    } catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("run_plan", { description: "Run 1–25 known dependent physical steps sequentially with fail-fast cancellation and a final observation; prefer this for two or more dependent actions.", inputSchema: runPlanSchema }, async (input, extra) => {
    const parsed = runPlanSchema.parse(input);
    try {
      const outcome = await executeRunPlan(await bridge(), parsed, extra?.signal);
      return result(outcome, outcome.status !== "completed");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const status = extra?.signal?.aborted ? "cancelled" : "failed";
      const outcome: RunPlanResult = {
        status,
        completed_steps: 0,
        outcomes: [],
        observation_error: message,
      };
      return result(outcome, true);
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
  const server = new McpServer({ name: "factorio-codex", version: "0.9.0" }, { instructions: "Control one physical Factorio character named Codex. Keep one rolling current plan plus one prepared successor. Never use screenshots or screen capture." });
  const bridge = createBridgeProvider(configDiagnostic);
  registerMcpTools(server as unknown as ToolRegistrar, bridge, configDiagnostic);
  await server.connect(new StdioServerTransport());
}
