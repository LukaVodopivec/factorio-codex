import { describe, expect, it, vi } from "vitest";
import type { Bridge } from "../src/bridge.js";
import { MCP_SERVER_VERSION, registerMcpTools } from "../src/mcp/server.js";
import { normalizeCanPlace, normalizeInspection, normalizeMapSummary, normalizePhysicalRoute, normalizePlacementSearch, normalizePlanDiagnostics, normalizeProductionRequirements, toolPayloads } from "../src/mcp/toolPayloads.js";
import { PROTOCOL_VERSION, RPC_METHODS } from "../src/protocol/contract.js";

const validConfig = () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } } as const);

describe("protocol v10 DTO and tool registry", () => {
  it("declares v10 and the exact accepted RPC surface", () => {
    expect(PROTOCOL_VERSION).toBe(10);
    expect(MCP_SERVER_VERSION).toBe("0.13.0");
    expect(RPC_METHODS).toHaveLength(18);
    expect(RPC_METHODS).toEqual(expect.arrayContaining(["find_placement", "map_summary", "production_requirements", "connect_entities"]));
  });

  it("registers exactly 25 tools and forwards exact v10 payloads", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => method === "connect_entities"
      ? { kind: "belt", prototype: "transport-belt", from: { x: 0.5, y: 0.5 }, to: { x: 4.5, y: 0.5 }, length: 1, steps: [{ name: "transport-belt", x: 1.5, y: 0.5, direction: 4 }], physical: true, ghosts: false }
      : { method });
    const enqueueAndWait = vi.fn(async () => "built 1/1 placements");
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; schemas[name] = config.inputSchema; } }, async () => ({ call, enqueueAndWait } as unknown as Bridge), validConfig);
    expect(Object.keys(handlers)).toHaveLength(25);

    const find = schemas.find_placement.parse({ item: "offshore-pump", preferred: { x: 1, y: 2 } });
    await handlers.find_placement(find);
    expect(call).toHaveBeenLastCalledWith("find_placement", { item: "offshore-pump", preferred: { x: 1, y: 2 }, radius: 10, directions: [0, 4, 8, 12], limit: 8 });
    await handlers.find_placement({ ...find, output_target: { x: 3, y: 4 } });
    expect(call).toHaveBeenLastCalledWith("find_placement", { item: "offshore-pump", preferred: { x: 1, y: 2 }, radius: 10, directions: [0, 4, 8, 12], limit: 8, output_target: { x: 3, y: 4 } });
    await handlers.map_summary({});
    expect(call).toHaveBeenLastCalledWith("map_summary", {});
    await handlers.production_requirements({ targets: { "automation-science-pack": 10 }, recipe_choices: { "petroleum-gas": "advanced-oil-processing" } });
    expect(call).toHaveBeenLastCalledWith("production_requirements", { targets: { "automation-science-pack": 10 }, recipe_choices: { "petroleum-gas": "advanced-oil-processing" } });
    const route = schemas.connect_entities.parse({ kind: "belt", prototype: "transport-belt", from: { x: 0.5, y: 0.5 }, to: { x: 4.5, y: 0.5 } });
    await handlers.connect_entities(route);
    expect(call).toHaveBeenLastCalledWith("connect_entities", { kind: "belt", prototype: "transport-belt", from: { x: 0.5, y: 0.5 }, to: { x: 4.5, y: 0.5 }, max_length: 25 });
    expect(enqueueAndWait).toHaveBeenCalledWith({
      type: "build_plan", auto_craft: true, stop_on_error: true,
      steps: [{ item: "transport-belt", position: { x: 1.5, y: 0.5 }, direction: 4 }],
    });
    expect(schemas.find_placement.safeParse({ item: "x", preferred: { x: 0, y: 0 }, radius: 31 }).success).toBe(false);
    expect(schemas.connect_entities.safeParse({ kind: "belt", prototype: "x", from: { x: 0, y: 0 }, to: { x: 1, y: 0 }, max_length: 26 }).success).toBe(false);
  });

  it("retains placement identity and exposes compact electrical/plan diagnostics", () => {
    expect(normalizeCanPlace({ results: [{ can_place: false, reason: "water" }] }, [{ name: "pipe", x: 2, y: 3 }])).toEqual({ results: [{ item: "pipe", position: { x: 2, y: 3 }, direction: 0, can_place: false, reason: "water" }] });
    expect(normalizeInspection({ entities: [{ name: "pole", energy: 12, electric_network_id: 7 }] }).entities[0].electrical).toEqual({ energy: 12, network_id: 7 });
    const diagnostics = normalizePlanDiagnostics({ outcomes: [{ step: 2, action: "place_entity", status: "failed", error: "blocked" }], observation: { entities: [{ name: "assembler", position: { x: 1, y: 1 }, status: "no_power" }] } });
    expect(diagnostics.diagnostics.route[0]).toMatchObject({ step: 2, detail: "blocked" });
    expect(diagnostics.diagnostics.machines[0]).toMatchObject({ entity: "assembler", status: "no_power" });
  });

  it("keeps payload construction explicit and lossless", () => {
    expect(toolPayloads.pickup({ x: 1.25, y: 2.5, item: "iron-ore", count: 3 })).toEqual({ target: { x: 1.25, y: 2.5 }, item: "iron-ore", count: 3 });
    expect(toolPayloads.findPlacement({ item: "pipe", preferred: { x: 1, y: 2 }, radius: 3, directions: [0], limit: 1 })).toEqual({ item: "pipe", preferred: { x: 1, y: 2 }, radius: 3, directions: [0], limit: 1 });
    expect(toolPayloads.connectEntities({ kind: "pipe", prototype: "pipe", from: { x: 1, y: 2 }, to: { x: 3, y: 2 }, max_length: 2 })).toEqual({ kind: "pipe", prototype: "pipe", from: { x: 1, y: 2 }, to: { x: 3, y: 2 }, max_length: 2 });
    expect(toolPayloads.productionRequirements({ targets: { gear: 2, pipe: 3 }, recipe_choices: { pipe: "pipe" } })).toEqual({ targets: { gear: 2, pipe: 3 }, recipe_choices: { pipe: "pipe" } });
  });

  it("normalizes Lua empty tables at every v9 array boundary", () => {
    expect(normalizePlacementSearch({ candidates: {} }).candidates).toEqual([]);
    expect(normalizeMapSummary({ resources: {}, water_edges: {}, factory_landmarks: {} })).toMatchObject({ resources: [], water_edges: [], factory_landmarks: [] });
    expect(normalizeProductionRequirements({ nodes: {} }).nodes).toEqual([]);
    expect(normalizePhysicalRoute({ steps: {} }).steps).toEqual([]);
  });
});
