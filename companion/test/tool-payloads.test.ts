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
    };
    const output = result(normalizeObservation(value));
    expect(output.content[0].text).toBe(JSON.stringify(value));
    expect(JSON.parse(output.content[0].text)).toEqual(value);
    expect(JSON.parse(output.content[0].text)).toEqual(output.structuredContent);
    expect(output.content[0].text).toContain('"resource_patches"');
  });
  it("normalizes Lua empty tables to arrays before rendering text and structure", () => {
    const output = result(normalizeObservation({ tick: 2, entities: {}, resource_patches: {} }));
    expect(output.structuredContent).toEqual({ tick: 2, entities: [], resource_patches: [] });
    expect(JSON.parse(output.content[0].text)).toEqual(output.structuredContent);
  });
  it("maps every coordinate action to the retained Lua DTO", () => {
    expect(toolPayloads.target({ x: 1, y: 2 })).toEqual({ target: { x: 1, y: 2 } });
    expect(toolPayloads.mine({ x: 1, y: 2, count: 3 })).toEqual({ target: { x: 1, y: 2 }, count: 3 });
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

describe("registered MCP handler parity with Lua v5", () => {
  it("invokes handlers with exact RPC and task payloads", async () => {
    const handlers: Record<string, (args: any) => Promise<unknown>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => method === "ping"
      ? { companion_exists: true, companion_ever_created: true, protocol_version: 5, mod_version: "0.8.0", factorio_version: "2.0.0", tick: 1 }
      : method === "observe_local" ? { entities: [], resource_patches: [] } : { ok: method });
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
    expect(call).toHaveBeenLastCalledWith("observe_local", { radius: 15 });
    expect(schemas.observe_local.shape.center).toBeUndefined();
    expect(schemas.observe_local.safeParse({ radius: 15, center: { x: 999, y: 999 } }).data).toEqual({ radius: 15 });
    await handlers.describe_prototype({ names: ["transport-belt"] });
    expect(call).toHaveBeenLastCalledWith("describe_prototype", { names: ["transport-belt"] });
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
    expect(schemas.mine.safeParse({ x: 0, y: 0 }).data.count).toBe(1);
    expect(schemas.mine.safeParse({ x: 0, y: 0, count: 201 }).success).toBe(false);
    await handlers.place_entity({ x: 13, y: 14, name: "stone-furnace", direction: 8 });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "place", item: "stone-furnace", position: { x: 13, y: 14 }, direction: 8 });
    await handlers.craft_items({ recipe: "iron-gear-wheel", count: 2 });
    expect(enqueueAndWait).toHaveBeenLastCalledWith({ type: "craft", recipe: "iron-gear-wheel", count: 2 });
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
    expect(Object.keys(handlers)).toHaveLength(17);
  });
});

describe("connect_status body lifecycle", () => {
  it("reports a persistent death without calling spawn", async () => {
    const call = vi.fn().mockResolvedValue({ companion_dead: true, companion_exists: false, companion_ever_created: true, protocol_version: 5, mod_version: "0.8.0" });
    const output = await connectStatus(async () => ({ call } as unknown as Bridge), validConfig);
    expect(output.isError).toBe(true);
    expect(output.content[0].text).toMatch(/dead.*never auto-respawns/i);
    expect(call).toHaveBeenCalledTimes(1);
  });

  it("rejects a stale mod before reporting connected", async () => {
    const call = vi.fn().mockResolvedValue({ companion_dead: false, companion_exists: true, companion_ever_created: true, protocol_version: 5, mod_version: "0.6.0" });
    await expect(connectStatus(async () => ({ call } as unknown as Bridge), validConfig)).rejects.toThrow("mod version mismatch: mod v0.6.0, app v0.8.0");
    expect(call).toHaveBeenCalledTimes(1);
  });

  it("spawns Codex exactly once only for a never-created save", async () => {
    const call = vi.fn(async (method: string) => method === "ping"
      ? { companion_dead: false, companion_exists: false, companion_ever_created: false, protocol_version: 5, mod_version: "0.8.0", factorio_version: "2.0.0", tick: 1 }
      : { name: "Codex" });
    const output = await connectStatus(async () => ({ call } as unknown as Bridge), validConfig);
    expect(output.isError).toBe(false);
    expect(call).toHaveBeenNthCalledWith(2, "spawn_companion", {});
    expect(call).toHaveBeenCalledTimes(2);
  });
});
