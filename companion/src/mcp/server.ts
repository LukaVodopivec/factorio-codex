import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { Bridge } from "../bridge.js";
import { RconClient } from "../rcon.js";
import { assertConnectionCompatibility, assertRuntimeCompatibility } from "../compatibility.js";
import { companionVersion, type ConfigDiagnostic, type RconSettings } from "../config.js";

const position = z.object({ x: z.number(), y: z.number() });
const items = z.record(z.string(), z.number().int().positive());
const actionNames = ["walk_to", "mine", "place_entity", "craft_items", "insert_items", "extract_items", "set_recipe", "rotate_entity", "build_plan"] as const;

export function result(value: unknown, isError = false) {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return { content: [{ type: "text" as const, text }], structuredContent: typeof value === "object" && value !== null ? value as Record<string, unknown> : undefined, isError };
}

export function normalizeObservation(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("observe_local returned an invalid object");
  const observation = value as Record<string, unknown>;
  const arrayField = (name: "entities" | "resource_patches") => {
    const field = observation[name];
    if (Array.isArray(field)) return field;
    if (field && typeof field === "object" && Object.keys(field as Record<string, unknown>).length === 0) return [];
    throw new Error(`observe_local returned invalid ${name}`);
  };
  return { ...observation, entities: arrayField("entities"), resource_patches: arrayField("resource_patches") };
}

export const toolPayloads = {
  target: (value: { x: number; y: number }) => ({ target: value }),
  place: ({ x, y, name, direction }: { x: number; y: number; name: string; direction?: number }) => ({ item: name, position: { x, y }, direction }),
  insert: ({ x, y, items: values }: { x: number; y: number; items: Record<string, number> }) => ({ target: { x, y }, items: values }),
  extract: ({ x, y, items: values }: { x: number; y: number; items?: Record<string, number> }) => values === undefined ? ({ target: { x, y }, all: true }) : ({ target: { x, y }, items: values }),
  recipe: ({ x, y, recipe }: { x: number; y: number; recipe: string }) => ({ target: { x, y }, recipe }),
  rotate: ({ x, y, direction }: { x: number; y: number; direction?: number }) => ({ target: { x, y }, direction }),
  inspect: (positions: Array<{ x: number; y: number }>) => ({ targets: positions }),
  placement: ({ x, y, name, direction }: { x: number; y: number; name: string; direction?: number }) => ({ item: name, position: { x, y }, direction }),
  canPlace: (placements: Array<{ x: number; y: number; name: string; direction?: number }>) => ({ placements: placements.map((placement) => toolPayloads.placement(placement)) }),
  buildPlan: (steps: Array<{ x: number; y: number; name: string; [key: string]: unknown }>, rest: Record<string, unknown>) => ({ ...rest, steps: steps.map(({ x, y, name, ...step }) => ({ ...step, item: name, position: { x, y } })) }),
};

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
  registerTool(name: string, config: unknown, handler: (args: any) => Promise<unknown>): unknown;
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
  server.registerTool("observe_local", { description: "Current deterministic local text observation centered on Codex.", inputSchema: z.object({ radius: z.number().int().min(5).max(30).default(15) }) }, async ({ radius }) => {
    try { return result(normalizeObservation(await (await bridge()).call("observe_local", { radius }))); }
    catch (error) { return result(`Error: ${error instanceof Error ? error.message : String(error)}`, true); }
  });
  server.registerTool("inspect_entity", { description: "Inspect entities at up to 16 positions within 30 tiles.", inputSchema: z.object({ positions: z.array(position).min(1).max(16) }) }, async ({ positions }) => rpc("inspect", toolPayloads.inspect(positions)));
  server.registerTool("describe_prototype", { description: "Describe exact item, entity or recipe prototypes.", inputSchema: z.object({ names: z.array(z.string()).min(1).max(10) }) }, async (p) => rpc("describe_prototype", p));
  server.registerTool("can_place", { description: "Check up to 24 placements within 30 tiles without side effects.", inputSchema: z.object({ placements: z.array(position.extend({ name: z.string(), direction: z.number().int().optional() })).min(1).max(24) }) }, async ({ placements }) => rpc("can_place", toolPayloads.canPlace(placements)));
  server.registerTool("walk_to", { description: "Walk physically to an exact position.", inputSchema: position }, async (p) => task("walk_to", toolPayloads.target(p)));
  server.registerTool("mine", { description: "Mine the entity at this exact visible position; no by-name discovery.", inputSchema: position }, async (p) => task("mine", toolPayloads.target(p)));
  server.registerTool("place_entity", { description: "Place an inventory item at an exact reachable position.", inputSchema: position.extend({ name: z.string(), direction: z.number().int().optional() }) }, async (p) => task("place", toolPayloads.place(p)));
  server.registerTool("craft_items", { description: "Queue legitimate Factorio hand crafting and wait for ticks.", inputSchema: z.object({ recipe: z.string(), count: z.number().int().positive() }) }, async (p) => task("craft", p));
  server.registerTool("insert_items", { description: "Insert carried items into a reachable entity.", inputSchema: position.extend({ items }) }, async (p) => task("insert", toolPayloads.insert(p)));
  server.registerTool("extract_items", { description: "Extract named items, or everything when items is omitted, from a reachable entity.", inputSchema: position.extend({ items: items.optional() }) }, async (p) => task("extract", toolPayloads.extract(p)));
  server.registerTool("set_recipe", { description: "Set a reachable crafting machine recipe.", inputSchema: position.extend({ recipe: z.string() }) }, async (p) => task("set_recipe", toolPayloads.recipe(p)));
  server.registerTool("rotate_entity", { description: "Rotate a reachable entity once, or set an explicit Factorio direction (0-15).", inputSchema: position.extend({ direction: z.number().int().min(0).max(15).optional() }) }, async (p) => task("rotate", toolPayloads.rotate(p)));
  server.registerTool("build_plan", { description: "Build up to 25 sequential steps; auto-craft is legitimate and failures stop by default.", inputSchema: z.object({ steps: z.array(position.extend({ name: z.string(), direction: z.number().int().optional(), recipe: z.string().optional(), insert: items.optional() })).min(1).max(25), auto_craft: z.boolean().default(true), stop_on_error: z.boolean().default(true) }) }, async ({ steps, ...rest }) => task("build_plan", toolPayloads.buildPlan(steps, rest)));
  server.registerTool("start_research", { description: "Start an unlocked technology using the force's real research queue.", inputSchema: z.object({ technology: z.string() }) }, async (p) => rpc("start_research", p));
  server.registerTool("stop", { description: "Cancel active and queued work after a TUI interruption.", inputSchema: z.object({}) }, async () => rpc("cancel", { all: true }));
  void actionNames;
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

export async function runMcpServer(configDiagnostic: () => ConfigDiagnostic): Promise<void> {
  const server = new McpServer({ name: "factorio-codex", version: "0.7.0" }, { instructions: "Control one physical Factorio character named Codex. Observe locally, then use honest path/reach/inventory/crafting actions." });
  const bridge = createBridgeProvider(configDiagnostic);
  registerMcpTools(server as unknown as ToolRegistrar, bridge, configDiagnostic);
  await server.connect(new StdioServerTransport());
}
