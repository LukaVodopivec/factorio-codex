import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { describe, expect, it, vi } from "vitest";
import type { Bridge } from "../src/bridge.js";
import { connectStatus, normalizeObservation, READ_ONLY_TOOLS, registerMcpTools, result, toolPayloads } from "../src/mcp/server.js";
import { queuePlanSchema } from "../src/mcp/runPlan.js";
import { FIFO_IDLE_HINT, normalizeFifo, normalizePlacementSearch } from "../src/mcp/toolPayloads.js";
const validConfig = () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } } as const);
describe("public MCP to Lua DTO mappings", () => {
  it("returns canonical structured content without duplicating it as JSON text", () => {
    const value = {
      tick: 1,
      character: { position: { x: 0, y: 0 }, inventory: { "iron-plate": 3 },
        inventory_scope: "main", ammo_inventory: { "firearm-magazine": 7 } },
      grid: { origin: { x: -1, y: -1 }, rows: ["...", ".@.", "..."], legend: { "@": "you" } },
      entities: [{ name: "furnace" }],
      resource_patches: [{ name: "iron-ore", entity_count: 2, total_amount: 300, center: { x: 5.5, y: 0 } }],
      ground_items: [{ item: "iron-ore", count: 3, position: { x: 2.25, y: -1.75 } }],
    };
    const output = result(normalizeObservation(value));
    expect(output.content[0].text).toBe("observation tick 1; entities 1; resources 1; ground items 1");
    expect(() => JSON.parse(output.content[0].text)).toThrow();
    expect(output.content[0].text).not.toContain('"resource_patches"');
    expect(output.structuredContent?.character).toEqual(value.character);
  });
  it("normalizes Lua empty tables to arrays before rendering text and structure", () => {
    const output = result(normalizeObservation({ tick: 2, entities: {}, resource_patches: {}, ground_items: {} }));
    expect(output.structuredContent).toEqual({ tick: 2, entities: [], resource_patches: [], ground_items: [] });
    expect(output.content[0].text).toBe("observation tick 2; entities 0; resources 0; ground items 0");
  });
  it("preserves buffer and consumer evidence through the registered map summary normalization", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const components = ["buffer", "consumer"].map(downstream_kind => ({
      component_id: downstream_kind, node_count: 17, omitted_node_ids: 5,
      state: { downstream_kind, blocked_output: downstream_kind === "buffer",
        autonomous_end_to_end: downstream_kind === "consumer",
        validation: { downstream_kind, downstream_acceptance_samples: 3,
          native_source_activity_samples: 24, fluid_activity_samples: 3, power_delivery_samples: 12,
          mining_sources_present: true, native_power_required: true } },
    }));
    const value = { tick: 42, factory: { groups: {}, force_flows: {},
      material_flow: { nodes: {}, edges: {}, diagnostics: {}, components },
      omissions: { capped_flow_nodes: 5, capped_flow_edges: 7, capped_flow_components: 2 },
      character_transfers: { target_actions: {}, validations: [components[1].state.validation] } } };
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call: vi.fn(async () => value) } as unknown as Bridge), validConfig);
    const output = await handlers.map_summary({});
    expect(output.structuredContent.factory.material_flow.components).toEqual(components);
    expect(output.structuredContent.factory.material_flow.nodes).toEqual([]);
    expect(output.structuredContent.factory.omissions).toEqual(value.factory.omissions);
    expect(output.structuredContent.factory.character_transfers.validations[0]).toEqual(components[1].state.validation);
  });
  it("maps every coordinate action to the retained Lua DTO", () => {
    expect(toolPayloads.target({ x: 1, y: 2 })).toEqual({ target: { x: 1, y: 2 }, arrival_mode: "exact", arrival_radius: 1 });
    expect(toolPayloads.target({ x: 1, y: 2, arrival_mode: "vicinity", arrival_radius: 4 })).toEqual({
      target: { x: 1, y: 2 }, arrival_mode: "vicinity", arrival_radius: 4,
    });
    expect(toolPayloads.mine({ x: 1, y: 2, count: 3 })).toEqual({ target: { x: 1, y: 2 }, count: 3 });
    expect(toolPayloads.mine({ x: 1, y: 2, count: 1, target_kind: "owned" })).toEqual({ target: { x: 1, y: 2 }, count: 1, target_kind: "owned" });
    expect(toolPayloads.mine({ x: 1, y: 2, count: 1, target_kind: "owned", allow_fluid_loss: true })).toEqual({ target: { x: 1, y: 2 }, count: 1, target_kind: "owned", allow_fluid_loss: true });
    expect(toolPayloads.mine({ x: 1.25, y: 2.5, count: 1, expected_name: "tree-01", observed_tick: 42 })).toEqual({
      target: { x: 1.25, y: 2.5 }, count: 1, expected_name: "tree-01", observed_tick: 42,
    });
    expect(toolPayloads.pickup({ x: 1, y: 2, item: "iron-ore", count: 3 })).toEqual({ target: { x: 1, y: 2 }, item: "iron-ore", count: 3 });
    expect(toolPayloads.place({ x: 1, y: 2, name: "furnace", direction: 4 })).toEqual({ item: "furnace", position: { x: 1, y: 2 }, direction: 4 });
    expect(toolPayloads.place({ x: 1, y: 2, name: "underground-belt", direction: 4, belt_to_ground_type: "output" }))
      .toEqual({ item: "underground-belt", position: { x: 1, y: 2 }, direction: 4, belt_to_ground_type: "output" });
    expect(toolPayloads.insert({ x: 1, y: 2, items: { coal: 3 } })).toEqual({ target: { x: 1, y: 2 }, items: { coal: 3 } });
    expect(toolPayloads.extract({ x: 1, y: 2, items: { coal: 3 } })).toEqual({ target: { x: 1, y: 2 }, items: { coal: 3 } });
    expect(toolPayloads.extract({ x: 1, y: 2 })).toEqual({ target: { x: 1, y: 2 }, all: true });
    expect(toolPayloads.recipe({ x: 1, y: 2, recipe: "gear" })).toEqual({ target: { x: 1, y: 2 }, recipe: "gear" });
    expect(toolPayloads.rotate({ x: 1, y: 2, direction: 12 })).toEqual({ target: { x: 1, y: 2 }, direction: 12 });
  });
  it("maps batches explicitly", () => {
    expect(toolPayloads.inspect([{ x: 1, y: 2 }])).toEqual({ targets: [{ x: 1, y: 2 }] });
    expect(toolPayloads.placement({ x: 1, y: 2, name: "belt", direction: 4 })).toEqual({ item: "belt", position: { x: 1, y: 2 }, direction: 4 });
    expect(toolPayloads.canPlace([{ x: 1, y: 2, name: "belt" }])).toEqual({ placements: [{ item: "belt", position: { x: 1, y: 2 } }] });
    expect(toolPayloads.buildPlan([{ x: 1, y: 2, name: "belt", recipe: "x" }], { stop_on_error: true })).toEqual({ stop_on_error: true, steps: [{ item: "belt", position: { x: 1, y: 2 }, recipe: "x" }] });
    expect(toolPayloads.findPlacement({ item: "inserter", preferred: { x: 1, y: 2 }, radius: 4,
      directions: [0, 4], limit: 3, input_target: { x: 0, y: 2 }, output_recipient_item: "wooden-chest" })).toEqual({
      item: "inserter", preferred: { x: 1, y: 2 }, radius: 4, directions: [0, 4], limit: 3,
      input_target: { x: 0, y: 2 }, output_recipient_item: "wooden-chest",
    });
  });
});

describe("registered MCP handler parity with the current Lua protocol", () => {
  it("validates targeted placement directions before acquiring the bridge and preserves valid payloads", async () => {
    const schemas: Record<string, any> = {};
    registerMcpTools({ registerTool(name, config) { schemas[name] = config.inputSchema; } },
      async () => { throw new Error("schema inspection must not acquire the bridge"); }, validConfig);
    const base = { item: "inserter", preferred: { x: 1, y: 2 } };
    const targets = [
      { input_target: { x: 0, y: 2 } },
      { output_target: { x: 2, y: 2 } },
      { output_recipient_item: "wooden-chest" },
      { input_target: { x: 0, y: 2 }, output_target: { x: 2, y: 2 } },
      { input_target: { x: 0, y: 2 }, output_recipient_item: "wooden-chest" },
    ];
    const schema = schemas.find_placement;
    for (const directions of [[], Array(17).fill(0), [-1], [16], [1.5]]) {
      expect(schema.safeParse({ ...base, directions }).success).toBe(false);
    }
    expect(schema.safeParse({ ...base, unexpected: true }).success).toBe(false);
    expect(schema.safeParse({ ...base, output_target: { x: 2, y: 2 }, output_recipient_item: "wooden-chest" }).success).toBe(false);
    const call = vi.fn(async () => ({ candidates: [] }));
    const bridge = vi.fn(async () => ({ call } as unknown as Bridge));
    const server = new McpServer({ name: "placement-test", version: "1" });
    registerMcpTools(server, bridge, validConfig);
    const client = new Client({ name: "placement-test", version: "1" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    try {
      for (const target of targets) {
        for (const directions of [[1], [0, 4, 7, 12]]) {
          const input = { ...base, ...target, directions };
          const parsed = schema.safeParse(input);
          expect(parsed.success).toBe(false);
          expect(parsed.error.issues).toContainEqual(expect.objectContaining({ path: ["directions"], message: expect.stringContaining("cardinal: 0, 4, 8, or 12") }));
          const output = await client.callTool({ name: "find_placement", arguments: input });
          expect(output.isError).toBe(true);
          expect(JSON.stringify(output.content)).toContain("cardinal: 0, 4, 8, or 12");
        }
      }
      expect(bridge).not.toHaveBeenCalled();
      expect(call).not.toHaveBeenCalled();
      for (const target of [{}, ...targets]) {
        for (const directions of [undefined, [0, 4, 8, 12], [12, 0]]) {
          const input = { ...base, ...target, ...(directions ? { directions } : {}) };
          const output = await client.callTool({ name: "find_placement", arguments: input });
          expect(output.isError).not.toBe(true);
          expect(call).toHaveBeenLastCalledWith("find_placement", { ...base, ...target, radius: 10, limit: 8, directions: directions ?? [0, 4, 8, 12] });
        }
      }
      const directions = Array.from({ length: 16 }, (_, direction) => direction);
      expect(schema.safeParse({ ...base, directions }).success).toBe(true);
      expect((await client.callTool({ name: "find_placement", arguments: { ...base, directions } })).isError).not.toBe(true);
      expect(call).toHaveBeenLastCalledWith("find_placement", { ...base, radius: 10, limit: 8, directions });
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("preserves useful partial completion as a non-error structured terminal result", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const enqueueAndWaitResult = vi.fn(async () => ({ status: "partial" as const,
      detail: "requested 10 wood, inserted 7, remainder 3",
      outcome: { code: "PARTIAL_INSERT", total_inserted: 7,
        transfers: [{ item: "wood", requested: 10, inserted: 7, remainder: 3 }] } }));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ enqueueAndWaitResult } as unknown as Bridge), validConfig);
    const output = await handlers.insert_items({ x: 1, y: 2, items: { wood: 10 } });
    expect(output.isError).toBe(false);
    expect(output.structuredContent).toMatchObject({ status: "partial", terminal: true,
      code: "PARTIAL_INSERT", total_inserted: 7, next_action: null });
    expect(output.content[0].text).not.toContain("transfers");
  });

  it("passes the MCP request abort signal so a turn interruption cancels the owned game task", async () => {
    const handlers: Record<string, (args: any, extra?: { signal?: AbortSignal }) => Promise<any>> = {};
    const enqueueAndWaitResult = vi.fn(async (_task: unknown, opts?: { signal?: AbortSignal }) => ({
      status: opts?.signal?.aborted ? "cancelled" as const : "done" as const, detail: "" }));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ enqueueAndWaitResult } as unknown as Bridge), validConfig);
    const controller = new AbortController(); controller.abort();
    const output = await handlers.walk_to({ x: 1, y: 2 }, { signal: controller.signal });
    expect(enqueueAndWaitResult.mock.calls[0]?.[1]).toEqual({ signal: controller.signal });
    expect(output.structuredContent).toMatchObject({ status: "cancelled", terminal: true });
  });

  it("passes the abort signal to the build_plan owned by connect_entities", async () => {
    const handlers: Record<string, (args: any, extra?: { signal?: AbortSignal }) => Promise<any>> = {};
    const enqueueAndWait = vi.fn(async () => "cancelled");
    const call = vi.fn(async () => ({ steps: [{ name: "transport-belt", x: 0, y: 0 }], kind: "belt" }));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call, enqueueAndWait } as unknown as Bridge), validConfig);
    const controller = new AbortController(); controller.abort();
    await handlers.connect_entities({ kind: "belt", from: { x: 0, y: 0 }, to: { x: 1, y: 0 } }, { signal: controller.signal });
    expect(enqueueAndWait.mock.calls[0]?.[1]).toEqual({ signal: controller.signal });
  });

  it("invokes handlers with exact RPC and task payloads", async () => {
    const handlers: Record<string, (args: any) => Promise<unknown>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => method === "ping"
      ? { companion_exists: true, companion_ever_created: true, protocol_version: 22, mod_version: "0.19.7", factorio_version: "2.0.0", tick: 1 }
      : method === "observe_local" ? { entities: [], resource_patches: [], ground_items: [] } : { ok: method });
    const enqueueAndWaitResult = vi.fn(async () => ({ status: "done" as const, detail: "done" }));
    registerMcpTools({
      registerTool(name: string, config: any, handler: (args: any) => Promise<unknown>) {
        schemas[name] = config.inputSchema;
        handlers[name] = handler;
      },
    }, async () => ({ call, enqueueAndWaitResult } as unknown as Bridge), validConfig);

    await handlers.connect_status({});
    expect(call).toHaveBeenLastCalledWith("ping");
    await handlers.observe_local({ radius: 15, center: { x: 999, y: 999 } });
    expect(call).toHaveBeenLastCalledWith("observe_local", { radius: 15, detail: undefined });
    expect(schemas.observe_local.shape.center).toBeUndefined();
    expect(schemas.observe_local.safeParse({ radius: 15, center: { x: 999, y: 999 } }).data).toEqual({ radius: 15, detail: "compact" });
    await handlers.describe_prototype({ names: ["transport-belt"] });
    expect(call).toHaveBeenLastCalledWith("describe_prototype", { names: ["transport-belt"] });
    expect(schemas.describe_prototype.safeParse({ names: ["transport-belt"] }).data.kind).toBe("auto");
    await handlers.describe_prototype({ names: ["transport-belt"], kind: "entity" });
    expect(call).toHaveBeenLastCalledWith("describe_prototype", { names: ["transport-belt"], kind: "entity" });
    expect(schemas.describe_prototype.safeParse({ names: ["x"], kind: "item" }).success).toBe(true);
    expect(schemas.describe_prototype.safeParse({ names: Array(10).fill("x") }).success).toBe(true);
    expect(schemas.describe_prototype.safeParse({ names: Array(11).fill("x") }).success).toBe(false);
    expect(schemas.inspect_entity.safeParse({ x: 1, y: 2 }).success).toBe(false);
    expect(schemas.production_requirements.safeParse({ target: "gear", count: 2 }).success).toBe(false);
    expect(schemas.place_entity.safeParse({ item: "stone-furnace", x: 1, y: 2 }).success).toBe(false);
    expect(schemas.craft_items.safeParse({ items: { "iron-gear-wheel": 2 } }).success).toBe(false);

    await handlers.extract_items({ x: 1, y: 2 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "extract", target: { x: 1, y: 2 }, all: true });
    await handlers.extract_items({ x: 1, y: 2, items: { coal: 3 } });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "extract", target: { x: 1, y: 2 }, items: { coal: 3 } });

    await handlers.rotate_entity({ x: 3, y: 4, direction: 12 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "rotate", target: { x: 3, y: 4 }, direction: 12 });
    expect(schemas.rotate_entity.shape.direction).toBeDefined();
    expect(schemas.rotate_entity.shape.reverse).toBeUndefined();

    await handlers.inspect_entity({ positions: [{ x: 5, y: 6 }] });
    expect(call).toHaveBeenLastCalledWith("inspect", { targets: [{ x: 5, y: 6 }] });
    await handlers.can_place({ placements: [{ x: 7, y: 8, name: "transport-belt", direction: 4 }] });
    expect(call).toHaveBeenLastCalledWith("can_place", { placements: [{ item: "transport-belt", position: { x: 7, y: 8 }, direction: 4 }] });
    await handlers.walk_to({ x: 9, y: 10 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "walk_to", target: { x: 9, y: 10 }, arrival_mode: "exact", arrival_radius: 1 });
    expect(schemas.walk_to.safeParse({ x: 9, y: 10, arrival_mode: "exact", arrival_radius: 2 }).success).toBe(false);
    await handlers.mine({ x: 11, y: 12, count: 4 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "mine", target: { x: 11, y: 12 }, count: 4 });
    await handlers.mine({ x: 11, y: 12, count: 1, target_kind: "owned" });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "mine", target: { x: 11, y: 12 }, count: 1, target_kind: "owned" });
    await handlers.mine({ x: 11, y: 12, count: 1, target_kind: "owned", allow_fluid_loss: true });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "mine", target: { x: 11, y: 12 }, count: 1, target_kind: "owned", allow_fluid_loss: true });
    await handlers.mine({ x: 11.25, y: 12.5, count: 1, expected_name: "tree-01", observed_tick: 42 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "mine", target: { x: 11.25, y: 12.5 }, count: 1, expected_name: "tree-01", observed_tick: 42 });
    expect(schemas.mine.safeParse({ x: 0, y: 0 }).data.count).toBe(1);
    expect(schemas.mine.safeParse({ x: 0, y: 0 }).data.target_kind).toBeUndefined();
    expect(schemas.mine.safeParse({ x: 0, y: 0, target_kind: "owned" }).success).toBe(true);
    expect(schemas.mine.safeParse({ x: 0, y: 0, target_kind: "owned", allow_fluid_loss: true }).success).toBe(true);
    expect(schemas.mine.safeParse({ x: 0, y: 0, count: 2 }).success).toBe(true);
    expect(schemas.mine.safeParse({ x: 0, y: 0, count: 201 }).success).toBe(false);
    expect(schemas.mine.safeParse({ x: 0, y: 0, expected_name: "tree-01", observed_tick: 0 }).success).toBe(true);
    expect(schemas.mine.safeParse({ x: 0, y: 0, expected_name: "", observed_tick: -1 }).success).toBe(false);
    await handlers.pickup_items({ x: 11.25, y: 12.5, item: "iron-ore", count: 3 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "pickup", target: { x: 11.25, y: 12.5 }, item: "iron-ore", count: 3 });
    expect(schemas.pickup_items.safeParse({ x: 0, y: 0, item: "iron-ore", count: 0 }).success).toBe(false);
    await handlers.place_entity({ x: 13, y: 14, name: "stone-furnace", direction: 8 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "place", item: "stone-furnace", position: { x: 13, y: 14 }, direction: 8 });
    await handlers.place_entity({ x: 13, y: 14, name: "inserter", input_target: { x: 13, y: 13 }, output_target: { x: 13, y: 15 } });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "place", item: "inserter", position: { x: 13, y: 14 }, direction: undefined,
      input_target: { x: 13, y: 13 }, output_target: { x: 13, y: 15 } });
    await handlers.craft_items({ recipe: "iron-gear-wheel", crafts: 2 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "craft", recipe: "iron-gear-wheel", count: 2 });
    expect(schemas.craft_items.safeParse({ recipe: "iron-gear-wheel", count: 2 }).success).toBe(false);
    await handlers.insert_items({ x: 15, y: 16, items: { coal: 2 } });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "insert", target: { x: 15, y: 16 }, items: { coal: 2 } });
    await handlers.set_recipe({ x: 17, y: 18, recipe: "iron-gear-wheel" });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "set_recipe", target: { x: 17, y: 18 }, recipe: "iron-gear-wheel" });
    await handlers.build_plan({ steps: [{ x: 19, y: 20, name: "transport-belt" }], auto_craft: true, stop_on_error: true });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "build_plan", auto_craft: true, stop_on_error: true, steps: [{ item: "transport-belt", position: { x: 19, y: 20 } }] });
    await handlers.start_research({ technology: "automation" });
    expect(call).toHaveBeenLastCalledWith("start_research", { technology: "automation" });
    await handlers.stop({});
    expect(call).toHaveBeenLastCalledWith("cancel", { all: true });
    expect(Object.keys(handlers)).toHaveLength(25);
  });
});

describe("read-only FIFO state", () => {
  const fifoValue = (fifo: Record<string, unknown>) => ({ status: "completed", companion_exists: true, companion_ever_created: true,
    protocol_version: 22, mod_version: "0.19.7", factorio_version: "2.0.0", tick: 1,
    entities: [], resource_patches: [], ground_items: [], results: [], candidates: [], outcomes: [], fifo });
  const args: Record<string, unknown> = {
    connect_status: {}, map_summary: {}, progression_status: {}, production_requirements: { targets: { "iron-plate": 1 } },
    describe_prototype: { names: ["transport-belt"] }, observe_local: { radius: 15 }, inspect_entity: { positions: [{ x: 1, y: 2 }] },
    plan_status: { plan_id: 7 }, can_place: { placements: [{ x: 1, y: 2, name: "transport-belt" }] },
    find_placement: { item: "transport-belt", preferred: { x: 0, y: 0 } },
  };
  const register = (value: unknown) => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call: vi.fn(async () => value) } as unknown as Bridge), validConfig, "read-only");
    return handlers;
  };

  it("carries the Lua fifo state on every read-only tool and hints only past 30 idle seconds", async () => {
    const idle = register(fifoValue({ queue_depth: 0, idle_seconds: 45 }));
    expect(Object.keys(idle).sort()).toEqual([...READ_ONLY_TOOLS].sort());
    for (const name of READ_ONLY_TOOLS) {
      const output = await idle[name]!(args[name]);
      expect(output.isError, name).toBe(false);
      expect(output.structuredContent.fifo, name).toEqual({ active_plan_id: null, queue_depth: 0, idle_seconds: 45, hint: FIFO_IDLE_HINT });
      expect(output.content[0].text.startsWith(`${FIFO_IDLE_HINT}; `), name).toBe(true);
    }
    const busy = register(fifoValue({ active_plan_id: 7, queue_depth: 1, idle_seconds: 0 }));
    for (const name of READ_ONLY_TOOLS) {
      const output = await busy[name]!(args[name]);
      expect(output.structuredContent.fifo, name).toEqual({ active_plan_id: 7, queue_depth: 1, idle_seconds: 0 });
      expect(output.content[0].text, name).not.toContain(FIFO_IDLE_HINT);
    }
  });

  it("states unknown idle time as null without a hint", () => {
    expect(normalizeFifo({ queue_depth: 0 })).toEqual({ active_plan_id: null, queue_depth: 0, idle_seconds: null });
    expect(normalizeFifo({ queue_depth: 0, idle_seconds: 30 })).toEqual({ active_plan_id: null, queue_depth: 0, idle_seconds: 30 });
    expect(normalizeFifo({ queue_depth: 0, idle_seconds: 31 })?.hint).toBe(FIFO_IDLE_HINT);
    expect(normalizeFifo(undefined)).toBeUndefined();
    expect(result({ status: "completed" }).structuredContent).toEqual({ status: "completed" });
  });
});

describe("underground belt end selection", () => {
  it("accepts belt_to_ground_type input|output on every placement schema and forwards it", async () => {
    const handlers: Record<string, (args: any) => Promise<unknown>> = {};
    const schemas: Record<string, any> = {};
    const enqueueAndWaitResult = vi.fn(async () => ({ status: "done" as const, detail: "done" }));
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<unknown>) {
      schemas[name] = config.inputSchema; handlers[name] = handler;
    } }, async () => ({ call: vi.fn(), enqueueAndWaitResult } as unknown as Bridge), validConfig);
    const placement = { x: 1.5, y: 2.5, name: "underground-belt", direction: 4 };
    for (const type of ["input", "output"]) {
      expect(schemas.place_entity.safeParse({ ...placement, belt_to_ground_type: type }).success).toBe(true);
      expect(schemas.build_plan.safeParse({ steps: [{ ...placement, belt_to_ground_type: type }] }).success).toBe(true);
      expect(queuePlanSchema.safeParse({ steps: [{ action: "place_entity", ...placement, belt_to_ground_type: type }] }).success).toBe(true);
    }
    expect(schemas.place_entity.safeParse({ ...placement, belt_to_ground_type: "sideways" }).success).toBe(false);
    expect(schemas.build_plan.safeParse({ steps: [{ ...placement, belt_to_ground_type: "sideways" }] }).success).toBe(false);
    expect(queuePlanSchema.safeParse({ steps: [{ action: "place_entity", ...placement, belt_to_ground_type: "sideways" }] }).success).toBe(false);
    await handlers.place_entity({ ...placement, belt_to_ground_type: "output" });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "place", item: "underground-belt", position: { x: 1.5, y: 2.5 },
      direction: 4, belt_to_ground_type: "output" });
    await handlers.build_plan({ steps: [{ ...placement, belt_to_ground_type: "input" }], auto_craft: true, stop_on_error: true });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "build_plan", auto_craft: true, stop_on_error: true,
      steps: [{ item: "underground-belt", position: { x: 1.5, y: 2.5 }, direction: 4, belt_to_ground_type: "input" }] });
    for (const belt_to_ground_type of ["input", "output"] as const) {
      const request = { item: placement.name, preferred: { x: placement.x, y: placement.y },
        radius: 3, directions: [4], limit: 8, belt_to_ground_type };
      expect(toolPayloads.findPlacement(request)).toEqual(request);
      const buildStep = { ...placement, belt_to_ground_type };
      const search = normalizePlacementSearch({ candidates: [{ build_steps: [buildStep] }] });
      const candidate = search.candidates[0];
      expect(candidate.plan_steps).toEqual([{ action: "place_entity", ...buildStep }]);
      expect(schemas.queue_plan.parse({ steps: candidate.plan_steps }).steps).toEqual(candidate.plan_steps);
      expect(schemas.run_plan.parse({ steps: candidate.plan_steps }).steps).toEqual(candidate.plan_steps);
      await handlers.build_plan(schemas.build_plan.parse({ steps: candidate.build_steps }));
      expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "build_plan", auto_craft: true, stop_on_error: true,
        steps: [{ item: placement.name, position: { x: placement.x, y: placement.y }, direction: 4, belt_to_ground_type }] });
    }
  });
});

describe("connect_status body lifecycle", () => {
  it("rebinds an absent native Codex player without creating a body", async () => {
    let pings = 0;
    const call = vi.fn(async (method: string) => method === "ping"
      ? (++pings === 1
        ? { companion_dead: true, companion_exists: false, companion_ever_created: true, protocol_version: 22, mod_version: "0.19.7", tick: 1 }
        : { companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 22, mod_version: "0.19.7", tick: 2 })
      : { name: "Codex", bound: true });
    const output = await connectStatus(async () => ({ call } as unknown as Bridge), validConfig);
    expect(output.isError).toBe(false);
    expect(call).toHaveBeenNthCalledWith(2, "spawn_companion", {});
    expect(call).toHaveBeenCalledTimes(3);
  });

  it("rejects a stale mod before reporting connected", async () => {
    const call = vi.fn().mockResolvedValue({ companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 22, mod_version: "0.6.0" });
    await expect(connectStatus(async () => ({ call } as unknown as Bridge), validConfig)).rejects.toThrow("mod version mismatch: mod v0.6.0, app v0.19.7");
    expect(call).toHaveBeenCalledTimes(1);
  });

  it("binds exact native Codex when a fresh save reports no body", async () => {
    let pings = 0;
    const call = vi.fn(async (method: string) => method === "ping"
      ? (++pings === 1
        ? { companion_dead: false, companion_exists: false, companion_ever_created: false, protocol_version: 22, mod_version: "0.19.7", factorio_version: "2.0.0", tick: 1 }
        : { companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 22, mod_version: "0.19.7", factorio_version: "2.0.0", tick: 2 })
      : { name: "Codex", bound: true });
    const output = await connectStatus(async () => ({ call } as unknown as Bridge), validConfig);
    expect(output.isError).toBe(false);
    expect(call).toHaveBeenNthCalledWith(2, "spawn_companion", {});
    expect(call).toHaveBeenCalledTimes(3);
  });

  it("surfaces the bind-only no-player error without retrying or creating", async () => {
    const call = vi.fn()
      .mockResolvedValueOnce({ protocol_version: 22, mod_version: "0.19.7", companion_exists: false, companion_ever_created: false, companion_dead: false })
      .mockRejectedValueOnce(new Error("native player 'Codex' is not connected with a living character"));
    await expect(connectStatus(async () => ({ call } as unknown as Bridge), validConfig)).rejects.toThrow("native player 'Codex' is not connected");
    expect(call.mock.calls).toEqual([["ping"], ["spawn_companion", {}]]);
  });
});
