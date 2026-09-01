import { describe, expect, it } from "vitest";
import { result, toolPayloads } from "../src/mcp/server.js";
describe("public MCP to Lua DTO mappings", () => {
  it("returns matching plain text and structured content", () => {
    const value = { tick: 1, grid: { rows: ["@"] } };
    const output = result(value);
    expect(JSON.parse(output.content[0].text)).toEqual(value);
    expect(output.structuredContent).toEqual(value);
  });
  it("maps coordinate actions explicitly", () => {
    expect(toolPayloads.target({ x: 1, y: 2 })).toEqual({ target: { x: 1, y: 2 } });
    expect(toolPayloads.place({ x: 1, y: 2, name: "furnace", direction: 4 })).toEqual({ item: "furnace", position: { x: 1, y: 2 }, direction: 4 });
    expect(toolPayloads.transfer({ x: 1, y: 2, items: { coal: 3 } })).toEqual({ target: { x: 1, y: 2 }, items: { coal: 3 } });
    expect(toolPayloads.recipe({ x: 1, y: 2, recipe: "gear" })).toEqual({ target: { x: 1, y: 2 }, recipe: "gear" });
    expect(toolPayloads.rotate({ x: 1, y: 2, reverse: true })).toEqual({ target: { x: 1, y: 2 }, reverse: true });
  });
  it("maps batches explicitly", () => {
    expect(toolPayloads.inspect([{ x: 1, y: 2 }])).toEqual({ targets: [{ x: 1, y: 2 }] });
    expect(toolPayloads.canPlace([{ x: 1, y: 2, name: "belt" }])).toEqual({ placements: [{ item: "belt", position: { x: 1, y: 2 } }] });
    expect(toolPayloads.buildPlan([{ x: 1, y: 2, name: "belt", recipe: "x" }], { stop_on_error: true })).toEqual({ stop_on_error: true, steps: [{ item: "belt", position: { x: 1, y: 2 }, recipe: "x" }] });
  });
});
