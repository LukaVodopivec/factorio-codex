import { describe, expect, it, vi } from "vitest";
import type { Bridge } from "../src/bridge.js";
import { MCP_SERVER_VERSION, registerMcpTools } from "../src/mcp/server.js";
import { normalizeCanPlace, normalizeInspection, normalizeMapSummary, normalizePhysicalRoute, normalizePlacementSearch, normalizePlanDiagnostics, normalizeProductionRequirements, queuedPlanSummary, toolPayloads } from "../src/mcp/toolPayloads.js";
import { PROTOCOL_VERSION, RPC_METHODS } from "../src/protocol/contract.js";

const validConfig = () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } } as const);

describe("protocol v22 DTO and tool registry", () => {
  it("declares v22 and the exact accepted RPC surface", () => {
    expect(PROTOCOL_VERSION).toBe(22);
    expect(MCP_SERVER_VERSION).toBe("0.19.2");
    expect(RPC_METHODS).toHaveLength(19);
    expect(RPC_METHODS).toEqual(expect.arrayContaining(["find_placement", "map_summary", "production_requirements", "run_snapshot", "connect_entities"]));
  });

  it("registers exactly 25 tools and forwards exact v22 payloads", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => method === "connect_entities"
      ? { kind: "belt", prototype: "transport-belt", from: { x: 0.5, y: 0.5 }, to: { x: 4.5, y: 0.5 }, length: 1, steps: [{ name: "transport-belt", x: 1.5, y: 0.5, direction: 4 }], physical: true, ghosts: false }
      : { method });
    const enqueueAndWait = vi.fn(async () => "built 1/1 placements");
    const enqueueAndWaitResult = vi.fn(async () => ({ status: "done" as const, detail: "done" }));
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; schemas[name] = config.inputSchema; } }, async () => ({ call, enqueueAndWait, enqueueAndWaitResult } as unknown as Bridge), validConfig);
    expect(Object.keys(handlers)).toHaveLength(25);

    const find = schemas.find_placement.parse({ item: "offshore-pump", preferred: { x: 1, y: 2 } });
    await handlers.find_placement(find);
    expect(call).toHaveBeenLastCalledWith("find_placement", { item: "offshore-pump", preferred: { x: 1, y: 2 }, radius: 10, directions: [0, 4, 8, 12], limit: 8 });
    await handlers.find_placement({ ...find, output_target: { x: 3, y: 4 } });
    expect(call).toHaveBeenLastCalledWith("find_placement", { item: "offshore-pump", preferred: { x: 1, y: 2 }, radius: 10, directions: [0, 4, 8, 12], limit: 8, output_target: { x: 3, y: 4 } });
    expect(schemas.find_placement.safeParse({ ...find, input_target: { x: 0, y: 1 } }).success).toBe(true);
    expect(schemas.find_placement.safeParse({ ...find, output_target: { x: 3, y: 4 }, output_recipient_item: "wooden-chest" }).success).toBe(false);
    const place = schemas.place_entity.parse({ name: "inserter", x: 1, y: 2, input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } });
    await handlers.place_entity(place);
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "place", item: "inserter", position: { x: 1, y: 2 }, direction: undefined, input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } });
    const build = schemas.build_plan.parse({ steps: [{ name: "inserter", x: 1, y: 2, input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } }] });
    await handlers.build_plan(build);
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "build_plan", auto_craft: true, stop_on_error: true,
      steps: [{ item: "inserter", position: { x: 1, y: 2 }, input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } }] });
    await handlers.map_summary({});
    expect(call).toHaveBeenLastCalledWith("map_summary", { detail: "aggregate", flow_precision: "one_minute" });
    await handlers.production_requirements({ targets: { "automation-science-pack": 10 }, recipe_choices: { "petroleum-gas": "advanced-oil-processing" } });
    expect(call).toHaveBeenLastCalledWith("production_requirements", { targets: { "automation-science-pack": 10 }, recipe_choices: { "petroleum-gas": "advanced-oil-processing" } });
    await handlers.production_requirements({ technology: "automation", flow_precision: "one_minute" });
    expect(call).toHaveBeenLastCalledWith("production_requirements", { technology: "automation", flow_precision: "one_minute" });
    await handlers.production_requirements({ location: "solar-system-edge", flow_precision: "ten_minutes" });
    expect(call).toHaveBeenLastCalledWith("production_requirements", { location: "solar-system-edge", flow_precision: "ten_minutes" });
    expect(schemas.production_requirements.safeParse({ targets: { gear: 1 }, technology: "automation" }).success).toBe(false);
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

  it("never equates complete power-pole placement with electrical continuity", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const networks = new Map([ ["0,0", 1], ["4,0", 1], ["8,0", 9] ]);
    const call = vi.fn(async (method: string, payload: any) => {
      if (method === "connect_entities") return { kind: "power", prototype: "small-electric-pole",
        from: { x: 0, y: 0 }, to: { x: 8, y: 0 }, length: 1,
        steps: [{ name: "small-electric-pole", x: 4, y: 0 }], physical: true, ghosts: false };
      if (method === "inspect") {
        return { entities: payload.targets.map((point: { x: number; y: number }) =>
          ({ name: "electrical-member", electric_network_id: networks.get(`${point.x},${point.y}`) })) };
      }
      return {};
    });
    const enqueueAndWait = vi.fn(async () => "placed 1/1");
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call, enqueueAndWait } as unknown as Bridge), validConfig);
    const output = await handlers.connect_entities({ kind: "power", prototype: "small-electric-pole",
      from: { x: 0, y: 0 }, to: { x: 8, y: 0 }, max_length: 25 });
    expect(output.structuredContent).toMatchObject({
      status: "placed_unconnected",
      placement: { requested: 1, placed: 1, complete: true },
      endpoint_coverage: { from: { covered: true, network_id: 1 }, to: { covered: false, network_id: 9 } },
      network_continuity: { connected: false, split_after_index: 1 },
    });
    expect(call).toHaveBeenLastCalledWith("inspect", { targets: [{ x: 0, y: 0 }, { x: 4, y: 0 }, { x: 8, y: 0 }] });
  });

  it("reports placed power routes as unverified when local network evidence is incomplete", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const call = vi.fn(async (method: string) => method === "connect_entities"
      ? { kind: "power", prototype: "small-electric-pole", from: { x: 0, y: 0 }, to: { x: 8, y: 0 },
        length: 1, steps: [{ name: "small-electric-pole", x: 4, y: 0 }], physical: true, ghosts: false }
      : { entities: [{ electric_network_id: 1 }, { error: "no entity" }, { electric_network_id: 1 }] });
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, async () => ({
      call, enqueueAndWait: vi.fn(async () => "placed 1/1"),
    } as unknown as Bridge), validConfig);
    const output = await handlers.connect_entities({ kind: "power", prototype: "small-electric-pole",
      from: { x: 0, y: 0 }, to: { x: 8, y: 0 }, max_length: 25 });
    expect(output.structuredContent).toMatchObject({ status: "placed_unverified",
      placement: { complete: true }, validation: { missing_member_indexes: [1] } });
  });

  it("retains placement identity and exposes compact electrical/plan diagnostics", () => {
    expect(normalizeCanPlace({ results: [{ can_place: false, reason: "water" }] }, [{ name: "pipe", x: 2, y: 3 }])).toEqual({ results: [{ item: "pipe", position: { x: 2, y: 3 }, direction: 0, can_place: false, reason: "water" }] });
    expect(normalizeInspection({ entities: [{ name: "pole", energy: 12, electric_network_id: 7 }] }).entities[0].electrical).toEqual({ energy: 12, network_id: 7 });
    const inserterEvidence = { name: "inserter", pickup_position: { x: 1, y: 0 }, drop_position: { x: 1, y: 2 }, pickup_target: { name: "belt", type: "transport-belt", position: { x: 1, y: 0 } } };
    expect(normalizeInspection({ entities: [inserterEvidence] }).entities[0]).toEqual(inserterEvidence);
    expect(normalizeInspection({ entities: [{ name: "drill", drop_target: false, drop_target_bound: false }] }).entities[0])
      .toEqual({ name: "drill", drop_target: null, drop_target_bound: false });
    expect(normalizeInspection({ entities: [{ name: "drill", drop_target: {}, drop_target_bound: false }] }).entities[0].drop_target)
      .toEqual({});
    const diagnostics = normalizePlanDiagnostics({ outcomes: [{ step: 2, action: "place_entity", status: "failed", error: "blocked" }], observation: { entities: [{ name: "assembler", position: { x: 1, y: 1 }, status: "no_power" }] } });
    expect(diagnostics.diagnostics.route[0]).toMatchObject({ step: 2, detail: "blocked" });
    expect(diagnostics.diagnostics.machines[0]).toMatchObject({ entity: "assembler", status: "no_power" });
    expect(normalizePlanDiagnostics({ transitions: {} }).transitions).toEqual([]);
    const audit = normalizePlanDiagnostics({ plan_id: 9, status: "completed", outcomes: [
      { step: 2, action: "inspect_entities", result: { tick: 100, entities: [{ name: "furnace" }], omitted_entities: 0 } },
      { step: 4, action: "inspect_entities", result: { tick: 145, entities: [{ name: "lab" }], omitted_entities: 0 } },
    ] }).physical_audit;
    expect(audit).toMatchObject({ audit_id: "plan-9", start_tick: 100, end_tick: 145,
      snapshot_skew_ticks: 45, evidence_class: "time_skewed_physical_tour", partial: false });
    expect(audit.clusters).toHaveLength(2);
  });

  it("keeps payload construction explicit and lossless", () => {
    expect(toolPayloads.pickup({ x: 1.25, y: 2.5, item: "iron-ore", count: 3 })).toEqual({ target: { x: 1.25, y: 2.5 }, item: "iron-ore", count: 3 });
    expect(toolPayloads.findPlacement({ item: "pipe", preferred: { x: 1, y: 2 }, radius: 3, directions: [0], limit: 1 })).toEqual({ item: "pipe", preferred: { x: 1, y: 2 }, radius: 3, directions: [0], limit: 1 });
    expect(toolPayloads.place({ name: "inserter", x: 1, y: 2, output_target: { x: 1, y: 3 } })).toEqual({ item: "inserter", position: { x: 1, y: 2 }, direction: undefined, output_target: { x: 1, y: 3 } });
    expect(toolPayloads.connectEntities({ kind: "pipe", prototype: "pipe", from: { x: 1, y: 2 }, to: { x: 3, y: 2 }, max_length: 2 })).toEqual({ kind: "pipe", prototype: "pipe", from: { x: 1, y: 2 }, to: { x: 3, y: 2 }, max_length: 2 });
    expect(toolPayloads.productionRequirements({ targets: { gear: 2, pipe: 3 }, recipe_choices: { pipe: "pipe" } })).toEqual({ targets: { gear: 2, pipe: 3 }, recipe_choices: { pipe: "pipe" } });
  });

  it("normalizes Lua empty tables at every array boundary", () => {
    expect(normalizePlacementSearch({ rejected_no_compatible_resource: 5, candidates: {} }))
      .toEqual({ rejected_no_compatible_resource: 5, candidates: [] });
    expect(normalizePlacementSearch({ candidates: [{ resource_coverage: {} }] }).candidates[0].resource_coverage).toEqual([]);
    expect(normalizePlacementSearch({ candidates: [{ output_position: { x: 1, y: 2 }, output_target: false }] }).candidates[0])
      .toEqual({ output_position: { x: 1, y: 2 }, output_target: null,
        output_precondition: { endpoint: { x: 1, y: 2 }, state: "unbound", recipient: null,
          requires_player_owned_target_before_placement: true } });
    expect(normalizeInspection({ entities: [{ name: "drill", type: "mining-drill", drop_target: false }] }).entities[0].drop_target).toBeNull();
    expect(normalizeMapSummary({ resources: {}, water_edges: {}, factory_landmarks: {} })).toMatchObject({ resources: [], water_edges: [], factory_landmarks: [] });
    expect(normalizeMapSummary({ factory: { groups: {}, force_flows: {}, character_transfers: {
      inserted_items: {}, extracted_items: {}, target_actions: {}, events: {}, validations: {},
    } } })).toMatchObject({ factory: { groups: [], force_flows: [], character_transfers: {
      inserted_items: [], extracted_items: [], target_actions: [], events: [], validations: [],
    } } });
    expect(normalizeProductionRequirements({ nodes: {} }).nodes).toEqual([]);
    expect(normalizePhysicalRoute({ steps: {} }).steps).toEqual([]);
  });
});

describe("placement results an executor can pass through", () => {
  const drillPair = { candidates: [{ position: { x: 45, y: -32 }, direction: 8, build_steps: [
    { name: "stone-furnace", x: 45, y: -30, direction: 0, fuel_inlet: true },
    { name: "burner-mining-drill", x: 45, y: -32, direction: 8, fuel_inlet: true, output_target: { x: 45, y: -30 } },
  ] }] };

  it("derives queue_plan steps in build order, fuelling burner inlets only when fuel is requested", () => {
    const fuelled = normalizePlacementSearch(drillPair, { coal: 5 }).candidates[0].plan_steps;
    expect(fuelled).toEqual([
      { action: "place_entity", x: 45, y: -30, name: "stone-furnace", direction: 0 },
      { action: "place_entity", x: 45, y: -32, name: "burner-mining-drill", direction: 8, output_target: { x: 45, y: -30 } },
      { action: "insert_items", x: 45, y: -30, items: { coal: 5 } },
      { action: "insert_items", x: 45, y: -32, items: { coal: 5 } },
    ]);
    expect(normalizePlacementSearch(drillPair).candidates[0].plan_steps.map((step: any) => step.action))
      .toEqual(["place_entity", "place_entity"]);
  });

  it("passes empty-result diagnostics through unchanged", () => {
    const empty = { evaluated: 40, rejections: { pickup_not_on_source: 30, output_not_on_recipient: 10 },
      closest_rejected: { reason: "output_not_on_recipient", position: { x: 1.5, y: 2.5 }, direction: 4 },
      hint: "wooden-chest at (38.5, -47.5) and stone-furnace at (40, -48) are adjacent (0 free tiles)", candidates: {} };
    expect(normalizePlacementSearch(empty)).toEqual({ ...empty, candidates: [] });
  });

  it("reports batch relations for can_place with null for nothing found", () => {
    const placements = [{ name: "stone-furnace", x: 45, y: -30 }, { name: "burner-mining-drill", x: 45, y: -32, direction: 8 }];
    const results = normalizeCanPlace({ results: [
      { can_place: true, overlaps_batch: {}, output_lands_on: false },
      { can_place: true, overlaps_batch: [0], output_position: { x: 45.5, y: -30.7 }, output_lands_on: { batch_index: 0, name: "stone-furnace" } },
    ] }, placements).results;
    expect(results[0]).toMatchObject({ overlaps_batch: [], output_lands_on: null });
    expect(results[1]).toMatchObject({ overlaps_batch: [0], output_lands_on: { batch_index: 0, name: "stone-furnace" } });
  });
});

describe("queued plan idle feedback", () => {
  it("names the body's idle time before a plan once it reaches ten seconds", () => {
    expect(queuedPlanSummary({ plan_id: 4, body_idle_ticks: 0 })).toBe("queued plan 4");
    expect(queuedPlanSummary({ plan_id: 4, body_idle_ticks: 599 })).toBe("queued plan 4");
    expect(queuedPlanSummary({ plan_id: 5, body_idle_ticks: 2700 })).toMatch(/^queued plan 5; the body sat idle 45 s before it: queue work that outlasts your next decision/);
  });
});
