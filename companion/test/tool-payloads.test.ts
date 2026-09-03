import { describe, expect, it, vi } from "vitest";
import type { Bridge } from "../src/bridge.js";
import { connectStatus, normalizeObservation, registerMcpTools, result, toolPayloads } from "../src/mcp/server.js";
const validConfig = () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } } as const);
describe("public MCP to Lua DTO mappings", () => {
  it("returns matching plain text and structured content for a populated observation", () => {
    const value = {
      tick: 1,
      character: { position: { x: 0, y: 0 }, inventory: { "iron-plate": 3 } },
      grid: { origin: { x: -1, y: -1 }, rows: ["...", ".@.", "..."], legend: { "@": "you" } },
      entities: [{ name: "furnace" }],
      resource_patches: [{ name: "iron-ore", entity_count: 2, total_amount: 300, center: { x: 5.5, y: 0 } }],
      ground_items: [{ item: "iron-ore", count: 3, position: { x: 2.25, y: -1.75 } }],
    };
    const output = result(normalizeObservation(value));
    expect(output.content[0].text).toBe(JSON.stringify(value));
    expect(JSON.parse(output.content[0].text)).toEqual(value);
    expect(JSON.parse(output.content[0].text)).toEqual(output.structuredContent);
    expect(output.content[0].text).toContain('"resource_patches"');
  });
  it("normalizes Lua empty tables to arrays before rendering text and structure", () => {
    const output = result(normalizeObservation({ tick: 2, entities: {}, resource_patches: {}, ground_items: {} }));
    expect(output.structuredContent).toEqual({ tick: 2, entities: [], resource_patches: [], ground_items: [] });
    expect(JSON.parse(output.content[0].text)).toEqual(output.structuredContent);
  });
  it("maps every coordinate action to the retained Lua DTO", () => {
    expect(toolPayloads.target({ x: 1, y: 2 })).toEqual({ target: { x: 1, y: 2 } });
    expect(toolPayloads.mine({ x: 1, y: 2, count: 3 })).toEqual({ target: { x: 1, y: 2 }, count: 3 });
    expect(toolPayloads.mine({ x: 1, y: 2, count: 1, target_kind: "owned" })).toEqual({ target: { x: 1, y: 2 }, count: 1, target_kind: "owned" });
    expect(toolPayloads.pickup({ x: 1, y: 2, item: "iron-ore", count: 3 })).toEqual({ target: { x: 1, y: 2 }, item: "iron-ore", count: 3 });
    expect(toolPayloads.place({ x: 1, y: 2, name: "furnace", direction: 4 })).toEqual({ item: "furnace", position: { x: 1, y: 2 }, direction: 4 });
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
  });
});

describe("registered MCP handler parity with Lua v10", () => {
  it("invokes handlers with exact RPC and task payloads", async () => {
    const handlers: Record<string, (args: any) => Promise<unknown>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => method === "ping"
      ? { companion_exists: true, companion_ever_created: true, protocol_version: 10, mod_version: "0.13.1", factorio_version: "2.0.0", tick: 1 }
      : method === "observe_local" ? { entities: [], resource_patches: [], ground_items: [] } : { ok: method });
    const enqueueAndWait = vi.fn(async (task: unknown) => ({ task }));
    registerMcpTools({
      registerTool(name: string, config: any, handler: (args: any) => Promise<unknown>) {
        schemas[name] = config.inputSchema;
        handlers[name] = handler;
      },
    }, async () => ({ call, enqueueAndWait } as unknown as Bridge), validConfig);

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

    await handlers.extract_items({ x: 1, y: 2 });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "extract", target: { x: 1, y: 2 }, all: true });
    await handlers.extract_items({ x: 1, y: 2, items: { coal: 3 } });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "extract", target: { x: 1, y: 2 }, items: { coal: 3 } });

    await handlers.rotate_entity({ x: 3, y: 4, direction: 12 });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "rotate", target: { x: 3, y: 4 }, direction: 12 });
    expect(schemas.rotate_entity.shape.direction).toBeDefined();
    expect(schemas.rotate_entity.shape.reverse).toBeUndefined();

    await handlers.inspect_entity({ positions: [{ x: 5, y: 6 }] });
    expect(call).toHaveBeenLastCalledWith("inspect", { targets: [{ x: 5, y: 6 }] });
    await handlers.can_place({ placements: [{ x: 7, y: 8, name: "transport-belt", direction: 4 }] });
    expect(call).toHaveBeenLastCalledWith("can_place", { placements: [{ item: "transport-belt", position: { x: 7, y: 8 }, direction: 4 }] });
    await handlers.walk_to({ x: 9, y: 10 });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "walk_to", target: { x: 9, y: 10 } });
    await handlers.mine({ x: 11, y: 12, count: 4 });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "mine", target: { x: 11, y: 12 }, count: 4 });
    await handlers.mine({ x: 11, y: 12, count: 1, target_kind: "owned" });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "mine", target: { x: 11, y: 12 }, count: 1, target_kind: "owned" });
    expect(schemas.mine.safeParse({ x: 0, y: 0 }).data.count).toBe(1);
    expect(schemas.mine.safeParse({ x: 0, y: 0 }).data.target_kind).toBe("natural");
    expect(schemas.mine.safeParse({ x: 0, y: 0, target_kind: "owned" }).success).toBe(true);
    expect(schemas.mine.safeParse({ x: 0, y: 0, count: 2 }).success).toBe(true);
    expect(schemas.mine.safeParse({ x: 0, y: 0, count: 201 }).success).toBe(false);
    await handlers.pickup_items({ x: 11.25, y: 12.5, item: "iron-ore", count: 3 });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "pickup", target: { x: 11.25, y: 12.5 }, item: "iron-ore", count: 3 });
    expect(schemas.pickup_items.safeParse({ x: 0, y: 0, item: "iron-ore", count: 0 }).success).toBe(false);
    await handlers.place_entity({ x: 13, y: 14, name: "stone-furnace", direction: 8 });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "place", item: "stone-furnace", position: { x: 13, y: 14 }, direction: 8 });
    await handlers.craft_items({ recipe: "iron-gear-wheel", crafts: 2 });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "craft", recipe: "iron-gear-wheel", count: 2 });
    expect(schemas.craft_items.safeParse({ recipe: "iron-gear-wheel", count: 2 }).success).toBe(false);
    await handlers.insert_items({ x: 15, y: 16, items: { coal: 2 } });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "insert", target: { x: 15, y: 16 }, items: { coal: 2 } });
    await handlers.set_recipe({ x: 17, y: 18, recipe: "iron-gear-wheel" });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "set_recipe", target: { x: 17, y: 18 }, recipe: "iron-gear-wheel" });
    await handlers.build_plan({ steps: [{ x: 19, y: 20, name: "transport-belt" }], auto_craft: true, stop_on_error: true });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "build_plan", auto_craft: true, stop_on_error: true, steps: [{ item: "transport-belt", position: { x: 19, y: 20 } }] });
    await handlers.start_research({ technology: "automation" });
    expect(call).toHaveBeenLastCalledWith("start_research", { technology: "automation" });
    await handlers.stop({});
    expect(call).toHaveBeenLastCalledWith("cancel", { all: true });
    expect(Object.keys(handlers)).toHaveLength(25);
  });
});

describe("connect_status body lifecycle", () => {
  it("rebinds an absent native Codex player without creating a body", async () => {
    let pings = 0;
    const call = vi.fn(async (method: string) => method === "ping"
      ? (++pings === 1
        ? { companion_dead: true, companion_exists: false, companion_ever_created: true, protocol_version: 10, mod_version: "0.13.1", tick: 1 }
        : { companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 10, mod_version: "0.13.1", tick: 2 })
      : { name: "Codex", bound: true });
    const output = await connectStatus(async () => ({ call } as unknown as Bridge), validConfig);
    expect(output.isError).toBe(false);
    expect(call).toHaveBeenNthCalledWith(2, "spawn_companion", {});
    expect(call).toHaveBeenCalledTimes(3);
  });

  it("rejects a stale mod before reporting connected", async () => {
    const call = vi.fn().mockResolvedValue({ companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 10, mod_version: "0.6.0" });
    await expect(connectStatus(async () => ({ call } as unknown as Bridge), validConfig)).rejects.toThrow("mod version mismatch: mod v0.6.0, app v0.13.1");
    expect(call).toHaveBeenCalledTimes(1);
  });

  it("binds exact native Codex when a fresh save reports no body", async () => {
    let pings = 0;
    const call = vi.fn(async (method: string) => method === "ping"
      ? (++pings === 1
        ? { companion_dead: false, companion_exists: false, companion_ever_created: false, protocol_version: 10, mod_version: "0.13.1", factorio_version: "2.0.0", tick: 1 }
        : { companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 10, mod_version: "0.13.1", factorio_version: "2.0.0", tick: 2 })
      : { name: "Codex", bound: true });
    const output = await connectStatus(async () => ({ call } as unknown as Bridge), validConfig);
    expect(output.isError).toBe(false);
    expect(call).toHaveBeenNthCalledWith(2, "spawn_companion", {});
    expect(call).toHaveBeenCalledTimes(3);
  });

  it("surfaces the bind-only no-player error without retrying or creating", async () => {
    const call = vi.fn()
      .mockResolvedValueOnce({ protocol_version: 10, mod_version: "0.13.1", companion_exists: false, companion_ever_created: false, companion_dead: false })
      .mockRejectedValueOnce(new Error("native player 'Codex' is not connected with a living character"));
    await expect(connectStatus(async () => ({ call } as unknown as Bridge), validConfig)).rejects.toThrow("native player 'Codex' is not connected");
    expect(call.mock.calls).toEqual([["ping"], ["spawn_companion", {}]]);
  });
});
