import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { describe, expect, it, vi } from "vitest";
import { DEFAULT_TASK_TIMEOUT_MS, type Bridge } from "../src/bridge.js";
import { connectStatus, MAP_SUMMARY_SECTIONS, normalizeObservation, READ_ONLY_TOOLS, registerMcpTools, result, toolPayloads } from "../src/mcp/server.js";
import { queuePlanSchema } from "../src/mcp/runPlan.js";
import { FIFO_HUMAN_HINT, FIFO_IDLE_HINT, normalizeFifo, normalizePlacementSearch, planStatusSummary, queuedPlanSummary } from "../src/mcp/toolPayloads.js";
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
  it("preserves component state and line counts through the registered map summary normalization", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const components = ["buffer", "consumer"].map(downstream_kind => ({
      component_id: downstream_kind, node_count: 17, omitted_node_ids: 5,
      state: { downstream_kind, blocked_output: downstream_kind === "buffer", autonomy_blockers: [] },
    }));
    const value = { tick: 42, factory: { groups: {}, force_flows: {},
      material_flow: { nodes: {}, edges: {}, diagnostics: {}, components, line_count: 3, running_line_count: 2,
        self_sustaining_line_count: 1, hand_fed_line_count: 1 },
      omissions: { capped_flow_nodes: 5, capped_flow_edges: 7, capped_flow_components: 2 },
      character_transfers: { target_actions: {}, events: {} } } };
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call: vi.fn(async () => value) } as unknown as Bridge), validConfig);
    const output = await handlers.map_summary({});
    expect(output.structuredContent.factory.material_flow.components).toEqual(components);
    expect(output.structuredContent.factory.material_flow).toMatchObject({ nodes: [], line_count: 3, running_line_count: 2,
      self_sustaining_line_count: 1, hand_fed_line_count: 1 });
    expect(output.structuredContent.factory.omissions).toEqual(value.factory.omissions);
    expect(output.structuredContent.factory.character_transfers).toMatchObject({ target_actions: [], events: [] });
    expect(output.structuredContent.factory.character_transfers).not.toHaveProperty("validations");
  });
  it("exposes flow aliases and nominal drill capacity through registered text and structure", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const group = { entity: "drill", type: "mining-drill", machine_count: 2,
      theoretical_items_per_minute: 90, capacity_state: "complete", evidenced_drill_count: 2,
      capacity_basis: "nominal_prototype_mining_speed_times_item_yield_divided_by_current_resource_mining_time" };
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call: vi.fn(async () => ({ tick: 42, summary: "factory tick 42", factory: {
        groups: [group], force_flows: [{ type: "item", name: "ore", input_rate: 0, output_rate: 3 }],
      } })) } as unknown as Bridge), validConfig);
    const output = await handlers.map_summary({});
    expect(output.structuredContent.factory.groups).toEqual([group]);
    expect(output.structuredContent.factory.force_flows[0]).toMatchObject({ produced_per_minute: 0, consumed_per_minute: 3 });
    expect(output.content[0].text).toContain("produced_per_minute=0, consumed_per_minute=3");
    expect(output.content[0].text).toContain("theoretical_items_per_minute=90 (complete)");
  });
  it("forwards map_summary include and returns every player-parity section with its omission counts", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const holder = { entity: "iron-chest", position: { x: 80.5, y: -3.5 }, count: 400, kind: "chest" };
    const network = { id: 4, production_w: 900000, consumption_w: 450000, capacity_w: 1800000, satisfaction: 1,
      accumulator_j: 0, accumulator_capacity_j: 0, statistics_available: true, starved_consumers: 0,
      producers: { "steam-engine": 2 }, consumers: {} };
    const value = { tick: 42, summary: "factory tick 42", factory: { groups: {}, force_flows: {} },
      stockpiles: [{ item: "iron-plate", total: 400, holders: [holder], holders_omitted: 0 },
        { item: "coal", total: 0, holders: {}, holders_omitted: 0 }], stockpiles_omitted: 3,
      sites: [{ chunk: { x: 2, y: -1 }, position: { x: 80, y: -4 }, machines: { "electric-mining-drill": 5 } }], sites_omitted: 0,
      patches: {}, patches_omitted: 0,
      power: { networks: [network], networks_omitted: 1 },
      problems: [{ entity: "stone-furnace", position: { x: 1, y: 2 }, status: "no_fuel" }], problems_total: 70,
      force_flows_all: {}, force_flows_all_omitted: 0 };
    const call = vi.fn(async () => value);
    registerMcpTools({ registerTool(name, config: any, handler) { schemas[name] = config.inputSchema; handlers[name] = handler; } },
      async () => ({ call } as unknown as Bridge), validConfig);
    const output = await handlers.map_summary({ include: [...MAP_SUMMARY_SECTIONS] });
    expect(call).toHaveBeenLastCalledWith("map_summary", { detail: "aggregate", flow_precision: "one_minute",
      include: ["stockpiles", "sites", "patches", "power", "problems", "flows_all"] }, undefined);
    expect(output.structuredContent).toMatchObject({ stockpiles_omitted: 3, sites: value.sites, sites_omitted: 0,
      patches: [], patches_omitted: 0, power: { networks: [network], networks_omitted: 1 },
      problems: value.problems, problems_total: 70, force_flows_all: [], force_flows_all_omitted: 0 });
    expect(output.structuredContent.stockpiles).toEqual([{ item: "iron-plate", total: 400, holders: [holder], holders_omitted: 0 },
      { item: "coal", total: 0, holders: [], holders_omitted: 0 }]);
    await handlers.map_summary({});
    expect(call).toHaveBeenLastCalledWith("map_summary", { detail: "aggregate", flow_precision: "one_minute" }, undefined);
    expect((await handlers.map_summary({ include: ["inventories"] })).isError).toBe(true);
    expect(call).toHaveBeenCalledTimes(2);
    expect(schemas.map_summary.safeParse({ include: ["power", "everything"] }).success).toBe(false);
    for (const key of ["stockpiles", "sites", "patches", "power", "problems", "force_flows_all"]) {
      expect((await handlers.map_summary({})).structuredContent, key).toHaveProperty(key);
    }
    // problems_by_status is a status-count record; Lua serializes an empty one as [].
    call.mockResolvedValueOnce({ ...value, problems: {}, problems_total: 0, problems_by_status: [] } as never);
    expect((await handlers.map_summary({ include: ["problems"] })).structuredContent)
      .toMatchObject({ problems: [], problems_total: 0, problems_by_status: {} });
    call.mockResolvedValueOnce({ ...value, problems_by_status: { no_fuel: 60, no_power: 10 } } as never);
    expect((await handlers.map_summary({ include: ["problems"] })).structuredContent.problems_by_status)
      .toEqual({ no_fuel: 60, no_power: 10 });
    call.mockResolvedValueOnce({ tick: 1, factory: { groups: {}, force_flows: {} } } as never);
    const plain = (await handlers.map_summary({})).structuredContent;
    for (const key of ["stockpiles", "sites", "patches", "power", "problems", "force_flows_all"]) expect(plain, key).not.toHaveProperty(key);
  });
  it("passes the remote marker of a charted own-force inspection through unchanged", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const call = vi.fn(async () => ({ tick: 9, entities: [
      { name: "iron-chest", position: { x: 300.5, y: 2.5 }, remote: true },
      { name: "stone-furnace", position: { x: 1.5, y: 2.5 } },
      { error: "inspect positions must be within 30 tiles of Codex, or on an own-force entity in a charted chunk" }] }));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call } as unknown as Bridge), validConfig);
    const entities = (await handlers.inspect_entity({ positions: [{ x: 300.5, y: 2.5 }, { x: 1.5, y: 2.5 }, { x: 900, y: 900 }] })).structuredContent.entities;
    expect(entities[0].remote).toBe(true);
    expect(entities[1]).not.toHaveProperty("remote");
    expect(entities[2].error).toContain("charted chunk");
  });
  it("returns the hand-mining drill hint and the belt pickup outcome as structured fields", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const descriptions: Record<string, string> = {};
    const enqueueAndWaitResult = vi.fn()
      .mockResolvedValueOnce({ status: "done", detail: "mined iron-ore; drill_produced: 3 own mining drill(s) already mine iron-ore",
        outcome: { drill_produced: true, drills: 3, stockpile_total: 1250 } })
      .mockResolvedValueOnce({ status: "done", detail: "physically picked up 4 iron-plate from the transport-belt",
        outcome: { source: "belt", item: "iron-plate", requested: 4, picked_up: 4,
          belt: { name: "transport-belt", position: { x: 5.5, y: 6.5 } } } });
    registerMcpTools({ registerTool(name, config: any, handler) { descriptions[name] = config.description; handlers[name] = handler; } },
      async () => ({ enqueueAndWaitResult } as unknown as Bridge), validConfig);
    const mined = await handlers.mine({ x: 1, y: 2, count: 5 });
    expect(mined.structuredContent).toMatchObject({ status: "completed", drill_produced: true, drills: 3, stockpile_total: 1250 });
    expect(mined.content[0].text).toContain("drill_produced");
    const picked = await handlers.pickup_items({ x: 5.5, y: 6.5, item: "iron-plate", count: 4 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "pickup", target: { x: 5.5, y: 6.5 }, item: "iron-plate", count: 4 }, { tool: "pickup_items", role: "unknown" });
    expect(picked.structuredContent).toMatchObject({ status: "completed", source: "belt", requested: 4, picked_up: 4,
      belt: { name: "transport-belt", position: { x: 5.5, y: 6.5 } } });
    expect(descriptions.pickup_items).toMatch(/plain belt tile/);
    expect(descriptions.pickup_items).toMatch(/whole count must fit in the inventory or nothing is taken; nothing is created/);
    expect(descriptions.pickup_items).toMatch(/runs dry ends the step with the count actually picked up/);
    expect(descriptions.map_summary).toMatch(/problems_by_status counts every problem machine by status/);
    expect(descriptions.mine).toMatch(/drill_produced/);
    expect(descriptions.inspect_entity).toMatch(/remote: true/);
    for (const section of MAP_SUMMARY_SECTIONS) expect(descriptions.map_summary, section).toContain(section);
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
          expect(call).toHaveBeenLastCalledWith("find_placement", { ...base, ...target, radius: 10, limit: 8, directions: directions ?? [0, 4, 8, 12] }, expect.anything());
        }
      }
      const directions = Array.from({ length: 16 }, (_, direction) => direction);
      expect(schema.safeParse({ ...base, directions }).success).toBe(true);
      expect((await client.callTool({ name: "find_placement", arguments: { ...base, directions } })).isError).not.toBe(true);
      expect(call).toHaveBeenLastCalledWith("find_placement", { ...base, radius: 10, limit: 8, directions }, expect.anything());
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
    expect(enqueueAndWaitResult.mock.calls[0]?.[1]).toEqual({ tool: "walk_to", role: "unknown", signal: controller.signal });
    expect(output.structuredContent).toMatchObject({ status: "cancelled", terminal: true });
  });

  it("names its session role in the origin of every cancel it makes", async () => {
    for (const role of ["pilot", "supervisor"] as const) {
      const handlers: Record<string, (args: any, extra?: { signal?: AbortSignal }) => Promise<any>> = {};
      const call = vi.fn(async () => ({ cancelled_count: 0 }));
      const enqueueAndWaitResult = vi.fn(async () => ({ status: "cancelled", detail: "" }));
      registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
        async () => ({ call, enqueueAndWaitResult } as unknown as Bridge), validConfig, "full", () => null, role);
      await handlers.stop!({});
      expect(call).toHaveBeenLastCalledWith("cancel", { all: true, origin: `stop/${role}` }, undefined);
      await handlers.walk_to!({ x: 1, y: 2 });
      expect((enqueueAndWaitResult.mock.calls.at(-1) as any[])[1]).toMatchObject({ tool: "walk_to", role });
    }
  });

  it("passes the abort signal to the build_plan owned by connect_entities", async () => {
    const handlers: Record<string, (args: any, extra?: { signal?: AbortSignal }) => Promise<any>> = {};
    const enqueueAndWait = vi.fn(async () => "cancelled");
    const call = vi.fn(async () => ({ steps: [{ name: "transport-belt", x: 0, y: 0 }], kind: "belt" }));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call, enqueueAndWait } as unknown as Bridge), validConfig);
    const controller = new AbortController(); controller.abort();
    const before = Date.now();
    await handlers.connect_entities({ kind: "belt", prototype: "transport-belt", from: { x: 0, y: 0 }, to: { x: 1, y: 0 } }, { signal: controller.signal });
    const options: any = enqueueAndWait.mock.calls[0]?.[1];
    expect(options).toMatchObject({ tool: "connect_entities", role: "unknown", signal: controller.signal });
    // The route search came first: the build's return guard counts from the tool's start, not from its enqueue.
    expect(call.mock.calls[0]?.[2]).toBe(controller.signal);
    expect(options.returnByMs).toBe(options.deadlineMs);
    expect(options.returnByMs).toBeGreaterThanOrEqual(before + DEFAULT_TASK_TIMEOUT_MS);
    expect(options.returnByMs).toBeLessThanOrEqual(Date.now() + DEFAULT_TASK_TIMEOUT_MS);
  });

  it("invokes handlers with exact RPC and task payloads", async () => {
    const handlers: Record<string, (args: any) => Promise<unknown>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => method === "ping"
      ? { companion_exists: true, companion_ever_created: true, protocol_version: 28, mod_version: "0.22.4", factorio_version: "2.0.0", tick: 1 }
      : method === "observe_local" ? { entities: [], resource_patches: [], ground_items: [] }
      : method === "queue_plan" ? { plan_id: 3 }
      : method === "plan_status" ? { plan_id: 3, status: "completed", outcomes: [] } : { ok: method });
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
    expect(call).toHaveBeenLastCalledWith("observe_local", { radius: 15, detail: undefined }, undefined);
    expect(schemas.observe_local.shape.center).toBeUndefined();
    expect(schemas.observe_local.safeParse({ radius: 15, center: { x: 999, y: 999 } }).data).toEqual({ radius: 15, detail: "compact" });
    await handlers.describe_prototype({ names: ["transport-belt"] });
    expect(call).toHaveBeenLastCalledWith("describe_prototype", { names: ["transport-belt"] }, undefined);
    expect(schemas.describe_prototype.safeParse({ names: ["transport-belt"] }).data.kind).toBe("auto");
    await handlers.describe_prototype({ names: ["transport-belt"], kind: "entity" });
    expect(call).toHaveBeenLastCalledWith("describe_prototype", { names: ["transport-belt"], kind: "entity" }, undefined);
    expect(schemas.describe_prototype.safeParse({ names: ["x"], kind: "item" }).success).toBe(true);
    expect(schemas.describe_prototype.safeParse({ names: Array(10).fill("x") }).success).toBe(true);
    expect(schemas.describe_prototype.safeParse({ names: Array(11).fill("x") }).success).toBe(false);
    expect(schemas.inspect_entity.safeParse({ x: 1, y: 2 }).success).toBe(false);
    expect(schemas.production_requirements.safeParse({ target: "gear", count: 2 }).success).toBe(false);
    expect(schemas.place_entity.safeParse({ item: "stone-furnace", x: 1, y: 2 }).success).toBe(false);
    expect(schemas.craft_items.safeParse({ items: { "iron-gear-wheel": 2 } }).success).toBe(false);

    await handlers.extract_items({ x: 1, y: 2 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "extract", target: { x: 1, y: 2 }, all: true }, { tool: "extract_items", role: "unknown" });
    await handlers.extract_items({ x: 1, y: 2, items: { coal: 3 } });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "extract", target: { x: 1, y: 2 }, items: { coal: 3 } }, { tool: "extract_items", role: "unknown" });

    await handlers.rotate_entity({ x: 3, y: 4, direction: 12 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "rotate", target: { x: 3, y: 4 }, direction: 12 }, { tool: "rotate_entity", role: "unknown" });
    expect(schemas.rotate_entity.shape.direction).toBeDefined();
    expect(schemas.rotate_entity.shape.reverse).toBeUndefined();

    await handlers.inspect_entity({ positions: [{ x: 5, y: 6 }] });
    expect(call).toHaveBeenLastCalledWith("inspect", { targets: [{ x: 5, y: 6 }] });
    await handlers.can_place({ placements: [{ x: 7, y: 8, name: "transport-belt", direction: 4 }] });
    expect(call).toHaveBeenLastCalledWith("can_place", { placements: [{ item: "transport-belt", position: { x: 7, y: 8 }, direction: 4 }] });
    await handlers.walk_to({ x: 9, y: 10 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "walk_to", target: { x: 9, y: 10 }, arrival_mode: "exact", arrival_radius: 1 }, { tool: "walk_to", role: "unknown" });
    expect(schemas.walk_to.safeParse({ x: 9, y: 10, arrival_mode: "exact", arrival_radius: 2 }).success).toBe(false);
    await handlers.mine({ x: 11, y: 12, count: 4 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "mine", target: { x: 11, y: 12 }, count: 4 }, { tool: "mine", role: "unknown" });
    await handlers.mine({ x: 11, y: 12, count: 1, target_kind: "owned" });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "mine", target: { x: 11, y: 12 }, count: 1, target_kind: "owned" }, { tool: "mine", role: "unknown" });
    await handlers.mine({ x: 11, y: 12, count: 1, target_kind: "owned", allow_fluid_loss: true });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "mine", target: { x: 11, y: 12 }, count: 1, target_kind: "owned", allow_fluid_loss: true }, { tool: "mine", role: "unknown" });
    await handlers.mine({ x: 11.25, y: 12.5, count: 1, expected_name: "tree-01", observed_tick: 42 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "mine", target: { x: 11.25, y: 12.5 }, count: 1, expected_name: "tree-01", observed_tick: 42 }, { tool: "mine", role: "unknown" });
    expect(schemas.mine.safeParse({ x: 0, y: 0 }).data.count).toBe(1);
    expect(schemas.mine.safeParse({ x: 0, y: 0 }).data.target_kind).toBeUndefined();
    expect(schemas.mine.safeParse({ x: 0, y: 0, target_kind: "owned" }).success).toBe(true);
    expect(schemas.mine.safeParse({ x: 0, y: 0, target_kind: "owned", allow_fluid_loss: true }).success).toBe(true);
    expect(schemas.mine.safeParse({ x: 0, y: 0, count: 2 }).success).toBe(true);
    expect(schemas.mine.safeParse({ x: 0, y: 0, count: 201 }).success).toBe(false);
    expect(schemas.mine.safeParse({ x: 0, y: 0, expected_name: "tree-01", observed_tick: 0 }).success).toBe(true);
    expect(schemas.mine.safeParse({ x: 0, y: 0, expected_name: "", observed_tick: -1 }).success).toBe(false);
    await handlers.pickup_items({ x: 11.25, y: 12.5, item: "iron-ore", count: 3 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "pickup", target: { x: 11.25, y: 12.5 }, item: "iron-ore", count: 3 }, { tool: "pickup_items", role: "unknown" });
    expect(schemas.pickup_items.safeParse({ x: 0, y: 0, item: "iron-ore", count: 0 }).success).toBe(false);
    await handlers.place_entity({ x: 13, y: 14, name: "stone-furnace", direction: 8 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "place", item: "stone-furnace", position: { x: 13, y: 14 }, direction: 8 }, { tool: "place_entity", role: "unknown" });
    await handlers.place_entity({ x: 13, y: 14, name: "inserter", input_target: { x: 13, y: 13 }, output_target: { x: 13, y: 15 } });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "place", item: "inserter", position: { x: 13, y: 14 }, direction: undefined,
      input_target: { x: 13, y: 13 }, output_target: { x: 13, y: 15 } }, { tool: "place_entity", role: "unknown" });
    await handlers.craft_items({ recipe: "iron-gear-wheel", crafts: 2 });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "craft", recipe: "iron-gear-wheel", count: 2 }, { tool: "craft_items", role: "unknown" });
    expect(schemas.craft_items.safeParse({ recipe: "iron-gear-wheel", count: 2 }).success).toBe(false);
    await handlers.insert_items({ x: 15, y: 16, items: { coal: 2 } });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "insert", target: { x: 15, y: 16 }, items: { coal: 2 } }, { tool: "insert_items", role: "unknown" });
    // set_recipe is a one-step plan (the mod's set_recipe action, remote on a platform).
    await handlers.set_recipe(schemas.set_recipe.parse({ x: 17, y: 18, recipe: "iron-gear-wheel" }));
    expect(call).toHaveBeenCalledWith("queue_plan", expect.objectContaining({ steps: [{ action: "set_recipe", x: 17, y: 18, recipe: "iron-gear-wheel" }] }));
    await handlers.build_plan({ steps: [{ x: 19, y: 20, name: "transport-belt" }], auto_craft: true, stop_on_error: true });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "build_plan", auto_craft: true, stop_on_error: true, steps: [{ item: "transport-belt", position: { x: 19, y: 20 } }] }, { tool: "build_plan", role: "unknown" });
    await handlers.start_research({ technology: "automation" });
    expect(call).toHaveBeenLastCalledWith("start_research", { technology: "automation" }, undefined);
    await handlers.stop({});
    // A process started without --role names itself unknown.
    expect(call).toHaveBeenLastCalledWith("cancel", { all: true, origin: "stop/unknown" }, undefined);
    await handlers.factory_status({ since_tick: 600, sections: ["lines", "problems"] });
    expect(call).toHaveBeenLastCalledWith("factory_status", { since_tick: 600, sections: ["lines", "problems"] });
    expect(schemas.factory_status.safeParse({ sections: ["validations"] }).success).toBe(false);
    await handlers.activity_log({ since_plan_id: 4 });
    expect(call).toHaveBeenLastCalledWith("activity_log", { since_plan_id: 4, limit: 16 });
    // A layout or block dry run is a direct mod check; a real build is a one-step plan.
    const layout = { anchor: { x: 1, y: 2 }, entities: [{ name: "stone-furnace", dx: 0, dy: 0 }] };
    await handlers.build_layout({ ...layout, check_only: true });
    expect(call).toHaveBeenLastCalledWith("build_layout", { ...layout, check_only: true }, undefined);
    expect(schemas.build_layout.safeParse({ entities: layout.entities }).success).toBe(false);
    await handlers.build_block({ block: "smelting", count: 4, near: { x: 0, y: 0 }, check_only: true });
    expect(call).toHaveBeenLastCalledWith("build_block", { block: "smelting", count: 4, near: { x: 0, y: 0 }, check_only: true }, undefined);
    call.mockClear();
    await handlers.build_layout(layout);
    await handlers.get_items({ item: "iron-plate", count: 20 });
    const queued = call.mock.calls.filter(([method]) => method === "queue_plan").map(([, params]) => (params as any).steps);
    expect(queued).toEqual([[{ action: "build_layout", ...layout }], [{ action: "get_items", item: "iron-plate", count: 20 }]]);
    expect(Object.keys(handlers)).toHaveLength(52);
  });
});

describe("read-only FIFO state", () => {
  const fifoValue = (fifo: Record<string, unknown>) => ({ status: "completed", companion_exists: true, companion_ever_created: true,
    protocol_version: 28, mod_version: "0.22.4", factorio_version: "2.0.0", tick: 1,
    entities: [], resource_patches: [], ground_items: [], results: [], candidates: [], outcomes: [], steps: [], fifo });
  const args: Record<string, unknown> = {
    connect_status: {}, map_summary: {}, progression_status: {}, production_requirements: { targets: { "iron-plate": 1 } },
    describe_prototype: { names: ["transport-belt"] }, observe_local: { radius: 15 }, inspect_entity: { positions: [{ x: 1, y: 2 }] },
    plan_status: { plan_id: 7 }, can_place: { placements: [{ x: 1, y: 2, name: "transport-belt" }] },
    find_placement: { item: "transport-belt", preferred: { x: 0, y: 0 } },
    factory_status: {}, activity_log: {}, build_layout: { anchor: { x: 0, y: 0 }, entities: [{ name: "lab", dx: 0, dy: 0 }] },
    build_block: { block: "labs", count: 1 },
    connect_entities: { kind: "belt", prototype: "transport-belt", from: { x: 0, y: 0 }, to: { x: 3, y: 0 } },
    blueprint_list: {}, blueprint_describe: { name: "smelter" }, blueprint_export: { name: "smelter" },
    blueprint_place: { name: "smelter", position: { x: 0, y: 0 } },
    place_tiles: { item: "landfill", positions: [{ x: 0, y: 0 }] }, platform_status: {},
  };
  // next_event reports the body in its own block from the cheap event probe.
  const fifoTools = READ_ONLY_TOOLS.filter((name) => name !== "next_event");
  const register = (value: unknown) => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call: vi.fn(async () => value) } as unknown as Bridge), validConfig, "read-only");
    return handlers;
  };

  it("carries the Lua fifo state on every read-only tool and hints only past 30 idle seconds", async () => {
    const idle = register(fifoValue({ queue_depth: 0, idle_seconds: 45 }));
    expect(Object.keys(idle).sort()).toEqual([...READ_ONLY_TOOLS].sort());
    for (const name of fifoTools) {
      const output = await idle[name]!(args[name]);
      expect(output.isError, name).toBe(false);
      expect(output.structuredContent.fifo, name).toEqual({ active_plan_id: null, queue_depth: 0, idle_seconds: 45, hint: FIFO_IDLE_HINT });
      expect(output.content[0].text.startsWith(`${FIFO_IDLE_HINT}; `), name).toBe(true);
    }
    const busy = register(fifoValue({ active_plan_id: 7, queue_depth: 1, idle_seconds: 0 }));
    for (const name of fifoTools) {
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
  });

  it("reports a human hold on every read-only tool, replacing the idle hint", async () => {
    const held = register(fifoValue({ active_plan_id: 7, queue_depth: 2, idle_seconds: 45, human_control: true, human_idle_ticks: 12 }));
    for (const name of fifoTools) {
      const output = await held[name]!(args[name]);
      expect(output.isError, name).toBe(false);
      expect(output.structuredContent.fifo, name).toEqual({ active_plan_id: 7, queue_depth: 2, idle_seconds: 45,
        human_control: true, human_idle_ticks: 12, hint: FIFO_HUMAN_HINT });
      expect(output.content[0].text, name).not.toContain(FIFO_IDLE_HINT);
    }
    expect(normalizeFifo({ queue_depth: 0, idle_seconds: 45, human_control: false, human_idle_ticks: 900 })).toEqual({
      active_plan_id: null, queue_depth: 0, idle_seconds: 45, human_control: false, human_idle_ticks: 900, hint: FIFO_IDLE_HINT });
    expect(normalizeFifo({ queue_depth: 0, human_control: false })).toEqual({
      active_plan_id: null, queue_depth: 0, idle_seconds: null, human_control: false });
  });

  it("keeps human_control on observations and plan results and names it in plan summaries", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const call = vi.fn(async (method: string) => method === "observe_local"
      ? { tick: 3, entities: [], resource_patches: [], ground_items: [], character: { human_control: true, human_idle_ticks: 40 } }
      : method === "queue_plan" ? { plan_id: 9, human_control: true }
      : { plan_id: 9, status: "completed", outcomes: [], fifo_empty: true, human_control: true });
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call } as unknown as Bridge), validConfig);
    const observed = await handlers.observe_local({ radius: 15, detail: "compact" });
    expect(observed.structuredContent.character).toEqual({ human_control: true, human_idle_ticks: 40 });
    const queued = await handlers.queue_plan({ steps: [{ action: "craft_items", recipe: "iron-gear-wheel", crafts: 1 }] });
    expect(queued.isError).toBe(false);
    expect(queued.structuredContent).toMatchObject({ plan_id: 9, status: "queued", human_control: true });
    expect(queued.content[0].text).toContain("a human holds the body");
    const status = await handlers.plan_status({ plan_id: 9 });
    expect(status.isError).toBe(false);
    expect(status.structuredContent).toMatchObject({ status: "completed", human_control: true });
    expect(status.content[0].text).toBe("completed; the FIFO is empty and the body is idle; a human hold delayed this plan (not a failure): re-observe before relying on earlier positions");
    expect(planStatusSummary({ status: "running" }, false)).toBe("running");
    expect(queuedPlanSummary({ plan_id: 3 })).toBe("queued plan 3");
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
      direction: 4, belt_to_ground_type: "output" }, { tool: "place_entity", role: "unknown" });
    await handlers.build_plan({ steps: [{ ...placement, belt_to_ground_type: "input" }], auto_craft: true, stop_on_error: true });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "build_plan", auto_craft: true, stop_on_error: true,
      steps: [{ item: "underground-belt", position: { x: 1.5, y: 2.5 }, direction: 4, belt_to_ground_type: "input" }] }, { tool: "build_plan", role: "unknown" });
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
        steps: [{ item: placement.name, position: { x: placement.x, y: placement.y }, direction: 4, belt_to_ground_type }] }, { tool: "build_plan", role: "unknown" });
    }
  });
});

describe("connect_status body lifecycle", () => {
  it("rebinds an absent native Codex player without creating a body", async () => {
    let pings = 0;
    const call = vi.fn(async (method: string) => method === "ping"
      ? (++pings === 1
        ? { companion_dead: true, companion_exists: false, companion_ever_created: true, protocol_version: 28, mod_version: "0.22.4", tick: 1 }
        : { companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 28, mod_version: "0.22.4", tick: 2 })
      : { name: "Codex", bound: true });
    const output = await connectStatus(async () => ({ call } as unknown as Bridge), validConfig);
    expect(output.isError).toBe(false);
    expect(call).toHaveBeenNthCalledWith(2, "spawn_companion", {});
    expect(call).toHaveBeenCalledTimes(3);
  });

  it("rejects a stale mod before reporting connected", async () => {
    const call = vi.fn().mockResolvedValue({ companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 28, mod_version: "0.6.0" });
    await expect(connectStatus(async () => ({ call } as unknown as Bridge), validConfig)).rejects.toThrow("mod version mismatch: mod v0.6.0, app v0.22.4");
    expect(call).toHaveBeenCalledTimes(1);
  });

  it("reports world-policy write failures from ping, and nothing when there are none", async () => {
    const ping = { companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 28, mod_version: "0.22.4", factorio_version: "2.0.0", tick: 5 };
    const failed = [{ tick: 4, surface: "vulcanus", write: "map_gen_settings", error: "denied" }];
    const withErrors = await connectStatus(async () => ({ call: vi.fn().mockResolvedValue({ ...ping, world_policy_errors: failed }) } as unknown as Bridge), validConfig);
    expect((withErrors.structuredContent as any).world_policy_errors).toEqual(failed);
    const clean = await connectStatus(async () => ({ call: vi.fn().mockResolvedValue(ping) } as unknown as Bridge), validConfig);
    expect(clean.structuredContent).not.toHaveProperty("world_policy_errors");
  });

  it("binds exact native Codex when a fresh save reports no body", async () => {
    let pings = 0;
    const call = vi.fn(async (method: string) => method === "ping"
      ? (++pings === 1
        ? { companion_dead: false, companion_exists: false, companion_ever_created: false, protocol_version: 28, mod_version: "0.22.4", factorio_version: "2.0.0", tick: 1 }
        : { companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 28, mod_version: "0.22.4", factorio_version: "2.0.0", tick: 2 })
      : { name: "Codex", bound: true });
    const output = await connectStatus(async () => ({ call } as unknown as Bridge), validConfig);
    expect(output.isError).toBe(false);
    expect(call).toHaveBeenNthCalledWith(2, "spawn_companion", {});
    expect(call).toHaveBeenCalledTimes(3);
  });

  it("surfaces the bind-only no-player error without retrying or creating", async () => {
    const call = vi.fn()
      .mockResolvedValueOnce({ protocol_version: 28, mod_version: "0.22.4", companion_exists: false, companion_ever_created: false, companion_dead: false })
      .mockRejectedValueOnce(new Error("native player 'Codex' is not connected with a living character"));
    await expect(connectStatus(async () => ({ call } as unknown as Bridge), validConfig)).rejects.toThrow("native player 'Codex' is not connected");
    expect(call.mock.calls).toEqual([["ping"], ["spawn_companion", {}]]);
  });
});
