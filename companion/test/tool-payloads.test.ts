import { describe, expect, it, vi } from "vitest";
import type { Bridge } from "../src/bridge.js";
import { connectStatus, result, toolPayloads } from "../src/mcp/server.js";
describe("public MCP to Lua DTO mappings", () => {
  it("returns matching plain text and structured content", () => {
    const value = {
      tick: 1,
      character: { position: { x: 0, y: 0 }, inventory: { "iron-plate": 3 } },
      grid: { origin: { x: -1, y: -1 }, rows: ["...", ".@.", "..."], legend: { "@": "you" } },
      resource_patches: [{ name: "iron-ore", entity_count: 2, total_amount: 300, center: { x: 5.5, y: 0 } }],
    };
    const output = result(value);
    expect(JSON.parse(output.content[0].text)).toEqual(value);
    expect(output.structuredContent).toEqual(value);
    expect(output.content[0].text).toContain('"resource_patches"');
  });
  it("maps every coordinate action to the retained Lua DTO", () => {
    expect(toolPayloads.target({ x: 1, y: 2 })).toEqual({ target: { x: 1, y: 2 } }); // walk_to and mine
    expect(toolPayloads.place({ x: 1, y: 2, name: "furnace", direction: 4 })).toEqual({ item: "furnace", position: { x: 1, y: 2 }, direction: 4 });
    expect(toolPayloads.transfer({ x: 1, y: 2, items: { coal: 3 } })).toEqual({ target: { x: 1, y: 2 }, items: { coal: 3 } });
    expect(toolPayloads.transfer({ x: 1, y: 2 })).toEqual({ target: { x: 1, y: 2 } });
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

describe("connect_status body lifecycle", () => {
  it("reports a persistent death without calling spawn", async () => {
    const call = vi.fn().mockResolvedValue({ companion_dead: true, companion_exists: false, companion_ever_created: true });
    const output = await connectStatus({ call } as unknown as Bridge);
    expect(output.isError).toBe(true);
    expect(output.content[0].text).toMatch(/dead.*never auto-respawns/i);
    expect(call).toHaveBeenCalledTimes(1);
  });

  it("spawns Codex exactly once only for a never-created save", async () => {
    const call = vi.fn(async (method: string) => method === "ping"
      ? { companion_dead: false, companion_exists: false, companion_ever_created: false, protocol_version: 5, mod_version: "0.7.0", factorio_version: "2.0.0", tick: 1 }
      : { name: "Codex" });
    const output = await connectStatus({ call } as unknown as Bridge);
    expect(output.isError).toBe(false);
    expect(call).toHaveBeenNthCalledWith(2, "spawn_companion", { name: "Codex" });
    expect(call).toHaveBeenCalledTimes(2);
  });
});
