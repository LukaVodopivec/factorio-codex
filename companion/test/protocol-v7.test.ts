import { describe, expect, it, vi } from "vitest";
import type { Bridge } from "../src/bridge.js";
import { registerMcpTools } from "../src/mcp/server.js";
import { normalizeCanPlace, normalizeInspection, normalizeMapSummary, normalizePhysicalRoute, normalizePlacementSearch, normalizePlanDiagnostics, normalizeProductionRequirements, toolPayloads } from "../src/mcp/toolPayloads.js";
import { PROTOCOL_VERSION, RPC_METHODS } from "../src/protocol/contract.js";

const validConfig = () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } } as const);

describe("protocol v7 DTO and tool registry", () => {
  it("declares v7 and the exact eventual RPC additions", () => {
    expect(PROTOCOL_VERSION).toBe(7);
    expect(RPC_METHODS).toHaveLength(18);
    expect(RPC_METHODS).toEqual(expect.arrayContaining(["find_placement", "map_summary", "production_requirements", "connect_entities"]));
  });

  it("registers exactly 24 tools and forwards exact v7 payloads", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => ({ method }));
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; schemas[name] = config.inputSchema; } }, async () => ({ call } as unknown as Bridge), validConfig);
    expect(Object.keys(handlers)).toHaveLength(24);

    const find = schemas.find_placement.parse({ item: "offshore-pump", preferred: { x: 1, y: 2 } });
    await handlers.find_placement(find);
    expect(call).toHaveBeenLastCalledWith("find_placement", { item: "offshore-pump", preferred: { x: 1, y: 2 }, radius: 10, directions: [0, 4, 8, 12], limit: 8 });
    await handlers.map_summary({});
    expect(call).toHaveBeenLastCalledWith("map_summary", {});
    await handlers.production_requirements({ item: "automation-science-pack", count: 10, recipe_choices: { "petroleum-gas": "advanced-oil-processing" } });
    expect(call).toHaveBeenLastCalledWith("production_requirements", { item: "automation-science-pack", count: 10, recipe_choices: { "petroleum-gas": "advanced-oil-processing" } });
    const route = schemas.connect_entities.parse({ kind: "belt", prototype: "transport-belt", from: { x: 0.5, y: 0.5 }, to: { x: 4.5, y: 0.5 } });
    await handlers.connect_entities(route);
    expect(call).toHaveBeenLastCalledWith("connect_entities", { kind: "belt", prototype: "transport-belt", from: { x: 0.5, y: 0.5 }, to: { x: 4.5, y: 0.5 }, max_length: 25 });
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
    expect(toolPayloads.findPlacement({ item: "pipe", preferred: { x: 1, y: 2 }, radius: 3, directions: [0], limit: 1 })).toEqual({ item: "pipe", preferred: { x: 1, y: 2 }, radius: 3, directions: [0], limit: 1 });
    expect(toolPayloads.connectEntities({ kind: "pipe", prototype: "pipe", from: { x: 1, y: 2 }, to: { x: 3, y: 2 }, max_length: 2 })).toEqual({ kind: "pipe", prototype: "pipe", from: { x: 1, y: 2 }, to: { x: 3, y: 2 }, max_length: 2 });
  });

  it("normalizes Lua empty tables at every v7 array boundary", () => {
    expect(normalizePlacementSearch({ candidates: {} }).candidates).toEqual([]);
    expect(normalizeMapSummary({ resources: {}, water_edges: {}, factory_landmarks: {} })).toMatchObject({ resources: [], water_edges: [], factory_landmarks: [] });
    expect(normalizeProductionRequirements({ nodes: {} }).nodes).toEqual([]);
    expect(normalizePhysicalRoute({ steps: {} }).steps).toEqual([]);
  });
});
