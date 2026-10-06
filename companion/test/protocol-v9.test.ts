import { describe, expect, it, vi } from "vitest";
import type { Bridge } from "../src/bridge.js";
import { MCP_SERVER_VERSION, registerMcpTools } from "../src/mcp/server.js";
import { normalizeActivityLog, normalizeCanPlace, normalizeFactoryStatus, normalizeInspection, normalizeMapSummary, normalizePhysicalRoute, normalizePlacementSearch, normalizePlanDiagnostics, normalizePlatformStatus, normalizeProductionRequirements, planStatusSummary, queuedPlanSummary, toolPayloads } from "../src/mcp/toolPayloads.js";
import { PROTOCOL_VERSION, RPC_METHODS } from "../src/protocol/contract.js";
import { packageStepSchema } from "../src/mcp/runPlan.js";

const validConfig = () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } } as const);

describe("protocol v28 DTO and tool registry", () => {
  it("declares v28 and the exact accepted RPC surface", () => {
    expect(PROTOCOL_VERSION).toBe(28);
    expect(MCP_SERVER_VERSION).toBe("0.25.0");
    expect(RPC_METHODS).toHaveLength(43);
    expect(RPC_METHODS).toEqual(expect.arrayContaining(["find_placement", "map_summary", "production_requirements", "run_snapshot", "connect_entities",
      "factory_status", "activity_log", "event_state", "build_layout", "build_block", "say", "say_now", "get_job",
      "blueprint_capture", "blueprint_create", "blueprint_list", "blueprint_describe", "blueprint_delete", "blueprint_export", "blueprint_place", "place_tiles", "platform_status", "create_platform", "set_requests", "configure_entity", "set_recipe", "set_platform_route", "travel"]));
  });

  it("registers exactly 52 tools and forwards exact v28 payloads", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => method === "connect_entities"
      ? { kind: "belt", prototype: "transport-belt", from: { x: 0.5, y: 0.5 }, to: { x: 4.5, y: 0.5 }, length: 1, steps: [{ name: "transport-belt", x: 1.5, y: 0.5, direction: 4 }], physical: true, ghosts: false }
      : { method });
    const enqueueAndWait = vi.fn(async () => "built 1/1 placements");
    const enqueueAndWaitResult = vi.fn(async () => ({ status: "done" as const, detail: "done" }));
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; schemas[name] = config.inputSchema; } }, async () => ({ call, enqueueAndWait, enqueueAndWaitResult } as unknown as Bridge), validConfig);
    expect(Object.keys(handlers)).toHaveLength(52);

    const find = schemas.find_placement.parse({ item: "offshore-pump", preferred: { x: 1, y: 2 } });
    await handlers.find_placement(find);
    expect(call).toHaveBeenLastCalledWith("find_placement", { item: "offshore-pump", preferred: { x: 1, y: 2 }, radius: 10, directions: [0, 4, 8, 12], limit: 8 }, undefined);
    await handlers.find_placement({ ...find, output_target: { x: 3, y: 4 } });
    expect(call).toHaveBeenLastCalledWith("find_placement", { item: "offshore-pump", preferred: { x: 1, y: 2 }, radius: 10, directions: [0, 4, 8, 12], limit: 8, output_target: { x: 3, y: 4 } }, undefined);
    expect(schemas.find_placement.safeParse({ ...find, input_target: { x: 0, y: 1 } }).success).toBe(true);
    expect(schemas.find_placement.safeParse({ ...find, output_target: { x: 3, y: 4 }, output_recipient_item: "wooden-chest" }).success).toBe(false);
    const place = schemas.place_entity.parse({ name: "inserter", x: 1, y: 2, input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } });
    await handlers.place_entity(place);
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "place", item: "inserter", position: { x: 1, y: 2 }, direction: undefined, input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } }, { tool: "place_entity", role: "unknown" });
    await handlers.place_entity({ ...place, auto_supply: false });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith(expect.objectContaining({ type: "place", auto_supply: false }), { tool: "place_entity", role: "unknown" });
    const build = schemas.build_plan.parse({ steps: [{ name: "inserter", x: 1, y: 2, input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } }] });
    await handlers.build_plan(build);
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "build_plan", auto_craft: true, stop_on_error: true,
      steps: [{ item: "inserter", position: { x: 1, y: 2 }, input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } }] }, { tool: "build_plan", role: "unknown" });
    await handlers.map_summary({});
    expect(call).toHaveBeenLastCalledWith("map_summary", { detail: "aggregate", flow_precision: "one_minute" }, undefined);
    await handlers.production_requirements({ targets: { "automation-science-pack": 10 }, recipe_choices: { "petroleum-gas": "advanced-oil-processing" } });
    expect(call).toHaveBeenLastCalledWith("production_requirements", { targets: { "automation-science-pack": 10 }, recipe_choices: { "petroleum-gas": "advanced-oil-processing" } });
    await handlers.production_requirements({ technology: "automation", flow_precision: "one_minute" });
    expect(call).toHaveBeenLastCalledWith("production_requirements", { technology: "automation", flow_precision: "one_minute" });
    await handlers.production_requirements({ location: "solar-system-edge", flow_precision: "ten_minutes" });
    expect(call).toHaveBeenLastCalledWith("production_requirements", { location: "solar-system-edge", flow_precision: "ten_minutes" });
    expect(schemas.production_requirements.safeParse({ targets: { gear: 1 }, technology: "automation" }).success).toBe(false);
    const route = schemas.connect_entities.parse({ kind: "belt", prototype: "transport-belt", from: { x: 0.5, y: 0.5 }, to: { x: 4.5, y: 0.5 } });
    await handlers.connect_entities(route);
    expect(call).toHaveBeenLastCalledWith("connect_entities", { kind: "belt", prototype: "transport-belt", from: { x: 0.5, y: 0.5 }, to: { x: 4.5, y: 0.5 }, max_length: 200 }, undefined);
    expect(enqueueAndWait).toHaveBeenCalledWith({
      type: "build_plan", auto_craft: true, stop_on_error: true,
      steps: [{ item: "transport-belt", position: { x: 1.5, y: 0.5 }, direction: 4 }],
    }, expect.objectContaining({ tool: "connect_entities", role: "unknown" }));
    expect(schemas.find_placement.safeParse({ item: "x", preferred: { x: 0, y: 0 }, radius: 31 }).success).toBe(false);
    expect(schemas.connect_entities.safeParse({ kind: "belt", prototype: "x", from: { x: 0, y: 0 }, to: { x: 1, y: 0 }, max_length: 200 }).success).toBe(true);
    expect(schemas.connect_entities.safeParse({ kind: "belt", prototype: "x", from: { x: 0, y: 0 }, to: { x: 1, y: 0 }, max_length: 201 }).success).toBe(false);
  });

  it("accepts a route-only layout (connections from an anchor) as a tool call and as a package step", () => {
    const schemas: Record<string, any> = {};
    registerMcpTools({ registerTool(name: string, config: any) { schemas[name] = config.inputSchema; } },
      async () => ({} as Bridge), validConfig);
    const route = { kind: "belt", prototype: "transport-belt", from: { dx: 0.5, dy: 0.5 }, to: { dx: 9.5, dy: 0.5 } };
    expect(schemas.build_layout.safeParse({ anchor: { x: 0, y: 0 }, entities: [], connections: [route] }).success).toBe(true);
    expect(schemas.build_layout.safeParse({ anchor: { x: 0, y: 0 }, entities: [] }).success).toBe(false);
    expect(schemas.build_layout.safeParse({ site: { near: { x: 0, y: 0 } }, entities: [], connections: [route] }).success).toBe(false);
    expect(packageStepSchema.safeParse({ action: "build_layout", anchor: { x: 0, y: 0 }, entities: [], connections: [route] }).success)
      .toBe(true);
  });

  it("forwards the 0.21.1 actions: moves, exploring, blueprints, area work, several insert targets and research lists", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string, params?: any) => method === "queue_plan" ? { plan_id: 8 }
      : method === "plan_status" ? { plan_id: 8, status: "completed", outcomes: [] }
      : method === "connect_entities" ? { kind: "pipe", steps: [{ name: "pipe", x: 1.5, y: 0.5 }] }
      : { method, params });
    const enqueueAndWait = vi.fn(async () => "built");
    const enqueueAndWaitResult = vi.fn(async () => ({ status: "done" as const, detail: "done" }));
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; schemas[name] = config.inputSchema; } },
      async () => ({ call, enqueueAndWait, enqueueAndWaitResult } as unknown as Bridge), validConfig);
    const queued = () => call.mock.calls.filter(([method]) => method === "queue_plan").at(-1)?.[1];
    const plans: Array<[string, Record<string, unknown>]> = [
      ["move_entity", { from: { x: 1.5, y: 1.5 }, to: { x: 5.5, y: 1.5 } }],
      ["move_entity", { from: { x: 1.5, y: 1.5 }, to: { x: 5.5, y: 1.5 }, mode: "body" }],
      ["move_entity", { from: { x: 1.5, y: 1.5 }, to: { x: 5.5, y: 1.5 }, mode: "robots" }],
      ["explore", { resource: "crude-oil", max_distance: 500 }],
      ["blueprint_place", { name: "smelter", position: { x: 10, y: 10 }, direction: 4, mode: "hand" }],
      ["build_ghosts", { center: { x: 0, y: 0 }, radius: 8 }],
      ["deconstruct_area", { area: { left_top: { x: 0, y: 0 }, right_bottom: { x: 8, y: 8 } }, mode: "robots", filter: ["stone-furnace"] }],
      ["upgrade_area", { center: { x: 0, y: 0 }, radius: 4, from: "transport-belt", to: "fast-transport-belt" }],
      ["copy_settings", { from: { x: 0.5, y: 0.5 }, to: [{ x: 3.5, y: 0.5 }] }],
    ];
    for (const [tool, args] of plans) {
      const parsed = schemas[tool].parse(args);
      expect(parsed).not.toHaveProperty("check_only", true);
      await handlers[tool]!(parsed);
      expect(queued(), tool).toMatchObject({ steps: [{ action: tool, ...args }] });
    }
    const moveArgs = { from: { x: 1.5, y: 1.5 }, to: { x: 5.5, y: 1.5 } };
    expect(schemas.move_entity.parse(moveArgs)).not.toHaveProperty("mode");
    expect(schemas.move_entity.safeParse({ ...moveArgs, mode: "teleport" }).success).toBe(false);
    expect(packageStepSchema.parse({ action: "move_entity", ...moveArgs, mode: "robots" })).toMatchObject({ mode: "robots" });
    expect(packageStepSchema.safeParse({ action: "move_entity", ...moveArgs, mode: "teleport" }).success).toBe(false);
    await handlers.blueprint_place(schemas.blueprint_place.parse({ name: "smelter", position: { x: 10, y: 10 }, check_only: true }));
    expect(call).toHaveBeenLastCalledWith("blueprint_place", { name: "smelter", position: { x: 10, y: 10 }, check_only: true }, undefined);
    for (const [tool, args] of [["blueprint_capture", { name: "smelter", center: { x: 0, y: 0 }, radius: 6 }],
      ["blueprint_create", { name: "pair", entities: [{ name: "stone-furnace", dx: 0, dy: 0 }] }],
      ["blueprint_list", {}], ["blueprint_describe", { name: "smelter" }], ["blueprint_export", { name: "smelter" }],
      ["blueprint_delete", { name: "smelter" }]] as const) {
      await handlers[tool]!(args);
      expect(call).toHaveBeenLastCalledWith(tool, tool === "blueprint_list" ? {} : args, undefined);
    }
    await handlers.insert_items({ targets: { name: "stone-furnace", near: { x: 0, y: 0 }, radius: 10 }, per_target: { coal: 5 } });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "insert", targets: { name: "stone-furnace", near: { x: 0, y: 0 }, radius: 10 },
      items: { coal: 5 } }, { tool: "insert_items", role: "unknown" });
    await handlers.insert_items({ x: 1, y: 2, items: { coal: 5 } });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "insert", target: { x: 1, y: 2 }, items: { coal: 5 } }, { tool: "insert_items", role: "unknown" });
    await handlers.place_entity({ name: "stone-furnace", x: 1, y: 2, insert: { coal: 5 } });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "place", item: "stone-furnace", position: { x: 1, y: 2 }, direction: undefined,
      insert: { coal: 5 } }, { tool: "place_entity", role: "unknown" });
    await handlers.start_research({ technologies: ["automation", "logistics"] });
    expect(call).toHaveBeenLastCalledWith("start_research", { technologies: ["automation", "logistics"] }, undefined);
    const routed = await handlers.connect_entities(schemas.connect_entities.parse({ kind: "pipe", prototype: "pipe", from: { x: 0.5, y: 0.5 },
      to: { x: 2.5, y: 0.5 }, fluid: "water", underground: false, check_only: true }));
    expect(call).toHaveBeenLastCalledWith("connect_entities", { kind: "pipe", prototype: "pipe", from: { x: 0.5, y: 0.5 }, to: { x: 2.5, y: 0.5 },
      max_length: 200, fluid: "water", underground: false }, undefined);
    expect(routed.structuredContent).toMatchObject({ check_only: true, steps: [{ name: "pipe" }] });
    expect(enqueueAndWait).not.toHaveBeenCalled();

    const area = (extra: Record<string, unknown>) => schemas.build_ghosts.safeParse(extra).success;
    expect(area({ area: { left_top: { x: 0, y: 0 }, right_bottom: { x: 1, y: 1 } }, center: { x: 0, y: 0 }, radius: 1 })).toBe(false);
    expect(area({ center: { x: 0, y: 0 } })).toBe(false);
    expect(area({})).toBe(false);
    expect(area({ center: { x: 0, y: 0 }, radius: 33 })).toBe(false);
    expect(schemas.insert_items.safeParse({ x: 1, y: 2, items: { coal: 1 }, per_target: { coal: 1 } }).success).toBe(false);
    expect(schemas.insert_items.safeParse({ x: 1, y: 2, targets: [{ x: 3, y: 4 }], items: { coal: 1 } }).success).toBe(false);
    expect(schemas.insert_items.safeParse({ x: 1, y: 2, per_target: { coal: 1 } }).success).toBe(false);
    expect(schemas.insert_items.safeParse({ targets: Array(33).fill({ x: 0, y: 0 }), items: { coal: 1 } }).success).toBe(false);
    expect(schemas.build_block.safeParse({ block: "blueprint", blueprint: "smelter" }).success).toBe(true);
    expect(schemas.build_block.safeParse({ block: "blueprint" }).success).toBe(false);
    expect(schemas.build_block.safeParse({ block: "labs" }).success).toBe(false);
    expect(schemas.blueprint_place.safeParse({ name: "smelter", position: { x: 0, y: 0 }, direction: 2 }).success).toBe(false);
    expect(schemas.blueprint_capture.safeParse({ name: "../x", center: { x: 0, y: 0 }, radius: 4 }).success).toBe(false);
    expect(schemas.start_research.safeParse({ technology: "automation", technologies: ["logistics"] }).success).toBe(false);
    expect(schemas.start_research.safeParse({ technologies: Array(8).fill("automation") }).success).toBe(false);
    expect(schemas.craft_items.parse({ recipe: "iron-gear-wheel", crafts: 2 })).not.toHaveProperty("wait_for_completion");
  });

  it("forwards the 0.22.0 actions: settings, tiles, requests, equipment, fluids and inventory roles", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string, params?: any) => method === "queue_plan" ? { plan_id: 9 }
      : method === "plan_status" ? { plan_id: 9, status: "completed", outcomes: [] } : { method, params });
    const enqueueAndWaitResult = vi.fn(async () => ({ status: "done" as const, detail: "done" }));
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; schemas[name] = config.inputSchema; } },
      async () => ({ call, enqueueAndWaitResult } as unknown as Bridge), validConfig);
    const queued = () => call.mock.calls.filter(([method]) => method === "queue_plan").at(-1)?.[1];

    // null clears a setting; the mod receives false (a Lua table holds no null).
    await handlers.configure_entity(schemas.configure_entity.parse({ x: 1.5, y: 2.5,
      inserter: { filters: ["iron-plate", "copper-plate"], stack_size: 1 }, chest: { slots: null, storage_filter: null } }));
    expect(queued()).toMatchObject({ steps: [{ action: "configure_entity", x: 1.5, y: 2.5,
      inserter: { filters: ["iron-plate", "copper-plate"], stack_size: 1 }, chest: { slots: false, storage_filter: false } }] });
    for (const bad of [{ x: 0, y: 0 }, { x: 0, y: 0, inserter: {} }, { x: 0, y: 0, inserter: { filters: Array(6).fill("coal") } },
      { x: 0, y: 0, splitter: { input_priority: "middle" } }, { x: 0, y: 0, chest: { slots: -1 } }, { x: 0, y: 0, circuit: {} }])
      expect(schemas.configure_entity.safeParse(bad).success, JSON.stringify(bad)).toBe(false);

    const requests = { target: { x: 4.5, y: 4.5 }, requests: [{ item: "iron-plate", min: 50, max: 100 }], request_from_buffers: true };
    await handlers.set_requests(schemas.set_requests.parse(requests));
    expect(queued()).toMatchObject({ steps: [{ action: "set_requests", ...requests }] });
    expect(schemas.set_requests.safeParse({ ...requests, section: "mall" }).success).toBe(true);
    expect(schemas.set_requests.safeParse({ target: { x: 0, y: 0 }, mode: "set" }).success).toBe(true);
    for (const bad of [{ target: { x: 0, y: 0 } }, { ...requests, requests: [{ item: "coal", min: 5, max: 4 }] },
      { ...requests, requests: [{ item: "coal", min: 1 }, { item: "coal", min: 2 }] },
      { ...requests, requests: [{ item: "coal", min: 1, import_from: "nauvis" }] }, { ...requests, section: 0 }])
      expect(schemas.set_requests.safeParse(bad).success, JSON.stringify(bad)).toBe(false);

    const tiles = { item: "landfill", area: { left_top: { x: 0, y: 0 }, right_bottom: { x: 6, y: 6 } } };
    await handlers.place_tiles(schemas.place_tiles.parse(tiles));
    expect(queued()).toMatchObject({ steps: [{ action: "place_tiles", ...tiles }] });
    await handlers.place_tiles(schemas.place_tiles.parse({ ...tiles, check_only: true }));
    expect(call).toHaveBeenLastCalledWith("place_tiles", { ...tiles, check_only: true }, undefined);
    expect(schemas.place_tiles.safeParse({ ...tiles, positions: [{ x: 0, y: 0 }] }).success).toBe(false);
    expect(schemas.place_tiles.safeParse({ item: "landfill" }).success).toBe(false);
    expect(schemas.place_tiles.safeParse({ item: "landfill", positions: Array(1025).fill({ x: 0, y: 0 }) }).success).toBe(false);

    await handlers.extract_items({ x: 1, y: 2, inventory: "fuel" });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "extract", target: { x: 1, y: 2 }, all: true, inventory: "fuel" },
      { tool: "extract_items", role: "unknown" });
    await handlers.insert_items(schemas.insert_items.parse({ x: 1, y: 2, items: { "speed-module": 2 }, inventory: "modules" }));
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "insert", target: { x: 1, y: 2 }, items: { "speed-module": 2 }, inventory: "modules" },
      { tool: "insert_items", role: "unknown" });
    expect(schemas.extract_items.safeParse({ x: 1, y: 2, inventory: "cargo" }).success).toBe(false);
    await handlers.place_entity({ x: 3, y: 4, name: "oil-refinery", mirror: true });
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "place", item: "oil-refinery", position: { x: 3, y: 4 }, direction: undefined, mirror: true },
      { tool: "place_entity", role: "unknown" });
    const sorter = { name: "fast-inserter", x: 1.5, y: 0.5, settings: { inserter: { filters: ["coal"], mode: "blacklist" } } };
    await handlers.build_plan(schemas.build_plan.parse({ steps: [sorter] }));
    expect(enqueueAndWaitResult).toHaveBeenLastCalledWith({ type: "build_plan", auto_craft: true, stop_on_error: true,
      steps: [{ item: "fast-inserter", position: { x: 1.5, y: 0.5 }, settings: sorter.settings }] }, { tool: "build_plan", role: "unknown" });
    const created = { name: "sorter", entities: [{ name: "splitter", dx: 0, dy: 0, settings: { splitter: { filter: "coal", output_priority: "right" } } },
      { name: "chemical-plant", dx: 3, dy: 0, mirror: true }] };
    await handlers.blueprint_create(schemas.blueprint_create.parse(created));
    expect(call).toHaveBeenLastCalledWith("blueprint_create", created, undefined);

    // Layout entities take typed settings, mirror and an underground end.
    const layout = { anchor: { x: 0, y: 0 }, entities: [{ name: "inserter", dx: 0, dy: 0, settings: { inserter: { filters: ["coal"] } } },
      { name: "underground-belt", dx: 1, dy: 0, direction: 4, belt_to_ground_type: "input" }, { name: "oil-refinery", dx: 6, dy: 0, mirror: true }] };
    await handlers.build_layout(schemas.build_layout.parse(layout));
    expect(queued()).toMatchObject({ steps: [{ action: "build_layout", ...layout }] });
    for (const settings of [{}, { inserter: { filters: ["coal"] }, bar: 3 }])
      expect(schemas.build_layout.safeParse({ ...layout, entities: [{ name: "inserter", dx: 0, dy: 0, settings }] }).success, JSON.stringify(settings)).toBe(false);
    // A 0.21.1 layout entity (free-form blueprint settings) is upgraded, not refused.
    const old = schemas.build_layout.safeParse({ ...layout, entities: [
      { name: "underground-belt", dx: 0, dy: 0, direction: 4, settings: { type: "input" } },
      { name: "chest", dx: 1, dy: 0, settings: { bar: 3, mirror: false } }] });
    expect(old.success && old.data.entities).toEqual([
      { name: "underground-belt", dx: 0, dy: 0, direction: 4, belt_to_ground_type: "input" },
      { name: "chest", dx: 1, dy: 0, mirror: false, settings: { chest: { slots: 2 } } }]);

    // Plan steps only: equip and flush_fluid; inspection reads up to 64 positions.
    const plan = { steps: [{ action: "equip", armor: "modular-armor", put: [{ name: "exoskeleton-equipment" }, { name: "battery-equipment", x: 2, y: 0 }],
      take: [{ name: "solar-panel-equipment" }, { x: 0, y: 0 }] },
      { action: "flush_fluid", x: 1.5, y: 1.5, fluid: "crude-oil" }, { action: "equip", armor: false },
      { action: "inspect_entities", positions: Array.from({ length: 64 }, (_, x) => ({ x, y: 0 })) }] };
    expect(schemas.queue_plan.safeParse(plan).success).toBe(true);
    expect(schemas.equip).toBeUndefined();
    expect(schemas.flush_fluid).toBeUndefined();
    for (const bad of [{ action: "equip" }, { action: "equip", put: [{ name: "battery-equipment", x: 1 }] },
      { action: "flush_fluid", x: 1 }, { action: "inspect_entities", positions: Array(65).fill({ x: 0, y: 0 }) }])
      expect(schemas.queue_plan.safeParse({ steps: [bad] }).success, JSON.stringify(bad)).toBe(false);
    expect(packageStepSchema.safeParse({ action: "configure_entity", x: 0, y: 0, splitter: { filter: null } }).data)
      .toEqual({ action: "configure_entity", x: 0, y: 0, splitter: { filter: false } });
  });

  it("forwards the 0.22.2 rocket and platform actions: remote ones without the body", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string, params?: any) => method === "queue_plan" ? { plan_id: 10 }
      : method === "plan_status" ? { plan_id: 10, status: "completed", outcomes: [] }
      : method === "create_platform" ? { code: "PLATFORM_CREATED", platform: { index: 3, name: "Orbit", state: "waiting_for_starter_pack", planet: "nauvis" } }
      : method === "set_requests" ? { code: "REQUESTS_SET", target: { kind: "space-platform-hub", platform_name: "Orbit" },
        sections: [{ index: 1, group: "", type: "manual", active: true, items: {} }] }
      : method === "set_recipe" ? { code: "RECIPE_SET", recipe: params.recipe, entity: { name: "crusher", position: { x: 2.5, y: -3.5 }, surface: "platform:3" } }
      : method === "configure_entity" ? { code: "CONFIGURED", entity: { name: "asteroid-collector", position: { x: 0.5, y: -6.5 }, surface: "platform:3" },
        settings: { collector: { filters: {} } }, changed: {} }
      : { method, params });
    const enqueueAndWaitResult = vi.fn(async () => ({ status: "done" as const, detail: "done" }));
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; schemas[name] = config.inputSchema; } },
      async () => ({ call, enqueueAndWaitResult } as unknown as Bridge), validConfig);
    const queued = () => call.mock.calls.filter(([method]) => method === "queue_plan").at(-1)?.[1];

    // create_platform and a hub's requests are one RPC each; they answer at once.
    const created = await handlers.create_platform(schemas.create_platform.parse({ name: "Orbit" }));
    expect(call).toHaveBeenLastCalledWith("create_platform", { name: "Orbit" });
    expect(created.content[0].text).toBe("created platform Orbit (3) over nauvis; it waits for its starter pack");
    expect(schemas.create_platform.safeParse({ name: "" }).success).toBe(false);
    expect(schemas.create_platform.safeParse({ name: "x".repeat(61) }).success).toBe(false);
    // launch_rocket only ever sends a normal starter pack.
    expect(schemas.create_platform.safeParse({ name: "Orbit", quality: "normal" }).success).toBe(true);
    expect(schemas.create_platform.safeParse({ name: "Orbit", quality: "uncommon" }).success).toBe(false);
    const hub = { target: { platform: "Orbit" }, requests: [{ item: "iron-plate", min: 400, import_from: "nauvis", minimum_delivery_count: 100 }] };
    const set = await handlers.set_requests(schemas.set_requests.parse(hub));
    expect(call).toHaveBeenLastCalledWith("set_requests", hub);
    expect(set.structuredContent.sections).toEqual([{ index: 1, group: "", type: "manual", active: true, items: [] }]);
    expect(call.mock.calls.some(([method]) => method === "queue_plan")).toBe(false);
    // A landing pad is a positional target: the body walks there (a plan step).
    const pad = { target: { x: 4.5, y: 4.5 }, requests: [{ item: "space-science-pack", min: 0 }] };
    await handlers.set_requests(schemas.set_requests.parse(pad));
    expect(queued()).toMatchObject({ steps: [{ action: "set_requests", ...pad }] });
    for (const bad of [{ target: { x: 0, y: 0 }, requests: [{ item: "coal", min: 1, minimum_delivery_count: 5 }] },
      { target: { platform: 3 }, request_from_buffers: true }, { target: { platform: 0 }, mode: "set" },
      { target: { platform: "Orbit", x: 1 }, mode: "set" }])
      expect(schemas.set_requests.safeParse(bad).success, JSON.stringify(bad)).toBe(false);

    // launch_rocket needs the body (loading and the button): a one-step plan.
    const launch = { silo: { x: 10.5, y: 10.5 }, platform: 3, cargo: "requests" };
    await handlers.launch_rocket(schemas.launch_rocket.parse(launch));
    expect(queued()).toMatchObject({ steps: [{ action: "launch_rocket", ...launch }] });
    const pack = { silo: { x: 10.5, y: 10.5 }, platform: "Orbit", cargo: { "space-platform-starter-pack": 1 }, partial: false };
    await handlers.launch_rocket(schemas.launch_rocket.parse(pack));
    expect(queued()).toMatchObject({ steps: [{ action: "launch_rocket", ...pack }] });
    for (const bad of [{ silo: { x: 0, y: 0 } }, { ...launch, cargo: {} }, { ...launch, cargo: "everything" },
      { ...launch, cargo: Object.fromEntries(Array.from({ length: 21 }, (_, i) => [`item-${i}`, 1])) }, { ...launch, cargo: { coal: 0 } }])
      expect(schemas.launch_rocket.safeParse(bad).success, JSON.stringify(bad)).toBe(false);

    // Remote settings and recipes on a platform are one RPC each, at once (no
    // FIFO); on a planet the body walks (a plan step). Collector filters and
    // silo requests are settings.
    const plans = () => call.mock.calls.filter(([method]) => method === "queue_plan").length;
    const before = plans();
    const crusher = { x: 2.5, y: -3.5, recipe: "metallic-asteroid-crushing", platform: "Orbit" };
    const recipe = await handlers.set_recipe(schemas.set_recipe.parse(crusher));
    expect(call).toHaveBeenLastCalledWith("set_recipe", crusher);
    expect(recipe.content[0].text).toBe("set the crusher's recipe to metallic-asteroid-crushing on platform Orbit");
    const collector = { x: 0.5, y: -6.5, platform: 3, collector: { filters: ["metallic-asteroid-chunk", "carbonic-asteroid-chunk"] } };
    const configured = await handlers.configure_entity(schemas.configure_entity.parse(collector));
    expect(call).toHaveBeenLastCalledWith("configure_entity", collector);
    expect(configured.structuredContent).toMatchObject({ changed: [], settings: { collector: { filters: [] } }, status: "completed" });
    expect(configured.content[0].text).toBe("configured the asteroid-collector on platform 3: nothing changed");
    expect(plans()).toBe(before);
    await handlers.set_recipe(schemas.set_recipe.parse({ x: 1.5, y: 1.5, recipe: "iron-gear-wheel" }));
    expect(queued()).toMatchObject({ steps: [{ action: "set_recipe", x: 1.5, y: 1.5, recipe: "iron-gear-wheel" }] });
    await handlers.configure_entity(schemas.configure_entity.parse({ x: 1.5, y: 1.5, chest: { slots: 4 } }));
    expect(queued()).toMatchObject({ steps: [{ action: "configure_entity", x: 1.5, y: 1.5, chest: { slots: 4 } }] });
    expect(schemas.configure_entity.safeParse({ x: 1, y: 1, silo: { auto_requests: true } }).success).toBe(true);
    expect(schemas.configure_entity.safeParse({ x: 1, y: 1, collector: {} }).success).toBe(false);
    expect(schemas.configure_entity.safeParse({ x: 1, y: 1, silo: { auto_orbit: true } }).success).toBe(false);

    // Platform layouts: ghosts from an anchor relative to the hub, with foundation tiles.
    const layout = { anchor: { x: 0, y: -8 }, platform: "Orbit",
      entities: [{ name: "asteroid-collector", dx: 0, dy: 0, settings: { collector: { filters: ["metallic-asteroid-chunk"] } } },
        { name: "crusher", dx: 3, dy: 2, recipe: "metallic-asteroid-crushing" }],
      tiles: [{ name: "space-platform-foundation", dx: 5, dy: 0 }],
      tile_rects: [{ name: "space-platform-foundation", from: { dx: -2, dy: -2 }, to: { dx: 2, dy: 2 } }] };
    await handlers.build_layout(schemas.build_layout.parse(layout));
    expect(queued()).toMatchObject({ steps: [{ action: "build_layout", ...layout }] });
    await handlers.build_layout(schemas.build_layout.parse({ ...layout, check_only: true }));
    expect(call).toHaveBeenLastCalledWith("build_layout", { ...layout, check_only: true }, undefined);
    const foundationOnly = { anchor: { x: 0, y: 0 }, platform: 3, entities: [], tile_rects: layout.tile_rects };
    expect(schemas.build_layout.safeParse(foundationOnly).success).toBe(true);
    expect(schemas.build_layout.safeParse({ anchor: { x: 0, y: 0 }, mode: "ghosts", entities: [{ name: "lab", dx: 0, dy: 0 }] }).success).toBe(true);
    for (const bad of [{ ...layout, mode: "hand" }, { ...layout, anchor: undefined, site: { near: { x: 0, y: 0 } } },
      { ...layout, platform: undefined }, { ...foundationOnly, tile_rects: undefined },
      { ...layout, entities: [{ name: "lab", dx: 0, dy: 0, insert: { "automation-science-pack": 1 } }] },
      { ...layout, tiles: [{ name: "space-platform-foundation", dx: 0.5, dy: 0 }] },
      { ...foundationOnly, tile_rects: [{ name: "space-platform-foundation", from: { dx: 0, dy: 0 }, to: { dx: 31, dy: 31 } }] }])
      expect(schemas.build_layout.safeParse(bad).success, JSON.stringify(bad)).toBe(false);

    // Blueprints and deconstruction on a platform: ghosts and robot orders only.
    const stamp = { name: "crusher-pair", position: { x: 4, y: 0 }, platform: "Orbit", mode: "ghosts" };
    await handlers.blueprint_place(schemas.blueprint_place.parse(stamp));
    expect(queued()).toMatchObject({ steps: [{ action: "blueprint_place", ...stamp }] });
    expect(schemas.blueprint_place.safeParse({ ...stamp, mode: "hand" }).success).toBe(false);
    const clear = { center: { x: 4, y: 0 }, radius: 3, platform: 3, mode: "robots" };
    await handlers.deconstruct_area(schemas.deconstruct_area.parse(clear));
    expect(queued()).toMatchObject({ steps: [{ action: "deconstruct_area", ...clear }] });
    expect(schemas.deconstruct_area.safeParse({ ...clear, mode: "hand" }).success).toBe(false);
    expect(schemas.deconstruct_area.safeParse({ platform: 3, mode: "robots" }).success).toBe(false);
    expect(schemas.upgrade_area.safeParse({ center: { x: 0, y: 0 }, radius: 2, from: "a", to: "b", platform: 3 }).success).toBe(false);

    // Every remote step is a plan and package step too, so the strategist's packages carry them.
    const steps = [{ action: "create_platform", name: "Second" }, { action: "set_requests", ...hub }, { action: "launch_rocket", ...launch },
      { action: "set_recipe", ...crusher }, { action: "configure_entity", ...collector }, { action: "build_layout", ...layout },
      { action: "blueprint_place", ...stamp }, { action: "deconstruct_area", ...clear }, { action: "extract_items", x: 1, y: 2, inventory: "rocket" }];
    expect(schemas.queue_plan.safeParse({ steps }).success).toBe(true);
    for (const step of steps) expect(packageStepSchema.safeParse(step).success, step.action).toBe(true);
    expect(enqueueAndWaitResult).not.toHaveBeenCalled();
  });

  it("normalizes platform screens and factory_status platform rows", () => {
    expect(normalizeFactoryStatus({ platforms: {} })).toEqual({ platforms: [] });
    expect(normalizePlatformStatus({ tick: 5, platforms: {} })).toEqual({ tick: 5, platforms: [] });
    // Routes: compact rows count each stop's waits; one platform's screen lists them.
    const row = { index: 3, name: "Orbit", state: "on_the_path", travel: { from: "nauvis", to: "vulcanus", distance_fraction: 0.25, length_km: 15000 },
      schedule: { current: 2, records: {} } };
    expect(normalizePlatformStatus({ platforms: [row] }).platforms).toEqual([{ ...row, schedule: { current: 2, records: [] } }]);
    expect(normalizeFactoryStatus({ platforms: [row] }).platforms).toEqual([{ ...row, schedule: { current: 2, records: [] } }]);
    const screen = normalizePlatformStatus({ platform: row, schedule: { current: 1, records: [{ station: "nauvis", wait_conditions: {} }] } });
    expect(screen.schedule).toEqual({ current: 1, records: [{ station: "nauvis", wait_conditions: [] }] });
    expect(screen.platform.schedule).toEqual({ current: 2, records: [] });
    const full = { tick: 9, platform: { index: 3, name: "Orbit", state: "waiting_at_station", location: "nauvis" },
      foundation: { tiles: 100, bbox: {}, rows: {} }, hub: { position: { x: 0, y: 0 }, inventory: {}, trash: {}, free_slots: 39 },
      requests: [{ index: 1, items: {} }], entities: [{ name: "asteroid-collector", position: { x: 0, y: -6 }, filters: {} }],
      ghosts: { entities: 0, tiles: 0, missing: {} }, damage: { damaged_tiles: 0, total: 0 } };
    expect(normalizePlatformStatus(full)).toEqual({ ...full, foundation: { ...full.foundation, rows: [] },
      hub: { ...full.hub, inventory: [], trash: [] }, requests: [{ index: 1, items: [] }],
      entities: [{ ...full.entities[0], filters: [] }], ghosts: { ...full.ghosts, missing: [] } });
    expect(normalizeInspection({ entities: [{ name: "asteroid-collector", settings: { collector: { filters: {} } } }] }).entities[0])
      .toEqual({ name: "asteroid-collector", settings: { collector: { filters: [] } } });
    const silo = { status: "building_rocket", parts: 12, parts_required: 50, cargo: {}, auto_requests: false };
    expect(normalizeInspection({ entities: [{ name: "rocket-silo", silo }] }).entities[0]).toEqual({ name: "rocket-silo", silo: { ...silo, cargo: [] } });
    expect(normalizeInspection({ entities: [{ name: "cargo-landing-pad", landing_pad: { inventory: {}, requests: [{ index: 1, items: {} }] } }] }).entities[0])
      .toEqual({ name: "cargo-landing-pad", landing_pad: { inventory: [], requests: [{ index: 1, items: [] }] } });
  });

  it("forwards the 0.22.3 trips: travel queues a pilot plan, a platform route is set at once, plans name their surface", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string, params?: any) => method === "travel" ? { plan_id: 12, queue_depth: 1, to: "vulcanus" }
      : method === "set_platform_route" ? { code: "ROUTE_SET", platform: { index: 3, name: "Orbit" }, state: "on_the_path", paused: false,
        schedule: { current: 1, records: [{ station: "nauvis", wait_conditions: {}, allows_unloading: true }] }, changed: ["stops", "go_to"] }
      : method === "queue_plan" ? { plan_id: 13 } : { method, params });
    const enqueueAndWaitResult = vi.fn();
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; schemas[name] = config.inputSchema; } },
      async () => ({ call, enqueueAndWaitResult } as unknown as Bridge), validConfig);

    // travel is one RPC that queues the trip as a plan and answers at once.
    const trip = await handlers.travel(schemas.travel.parse({ to: "vulcanus", max_wait_minutes: 90 }));
    expect(call).toHaveBeenLastCalledWith("travel", { to: "vulcanus", max_wait_minutes: 90 });
    expect(trip.structuredContent).toMatchObject({ status: "queued", terminal: false, plan_id: 12, next_action: { tool: "next_event" } });
    expect(trip.content[0].text).toBe("queued plan 12; travel to vulcanus");
    await handlers.travel(schemas.travel.parse({ to: { platform: "Orbit" }, via_silo: { x: 10.5, y: 10.5 } }));
    expect(call).toHaveBeenLastCalledWith("travel", { to: { platform: "Orbit" }, via_silo: { x: 10.5, y: 10.5 } });
    for (const bad of [{}, { to: "" }, { to: "vulcanus", max_wait_minutes: 0 }, { to: "vulcanus", max_wait_minutes: 241 }, { to: { platform: 0 } }])
      expect(schemas.travel.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    expect(enqueueAndWaitResult).not.toHaveBeenCalled();

    // A platform's route is its window: one RPC, no body, no FIFO; the wait
    // conditions go to the mod as the game's own literals.
    const route = { platform: "Orbit", stops: [{ location: "nauvis", wait: [{ type: "all_requests_satisfied" },
      { type: "time", compare_type: "or", ticks: 18000 }] }, { location: "vulcanus", unloading: false }], go_to: 1 };
    const set = await handlers.set_platform_route(schemas.set_platform_route.parse(route));
    expect(call).toHaveBeenLastCalledWith("set_platform_route", route);
    expect(set.structuredContent).toMatchObject({ status: "completed", changed: ["stops", "go_to"],
      schedule: { current: 1, records: [{ station: "nauvis", wait_conditions: [] }] } });
    expect(set.content[0].text).toBe("platform Orbit's route: stops, go_to set");
    expect(schemas.set_platform_route.safeParse({ platform: 3, paused: true }).success).toBe(true);
    for (const bad of [{ platform: "Orbit" }, { ...route, go_to: 3 }, { ...route, stops: [] },
      { ...route, stops: Array(11).fill({ location: "nauvis" }) }, { platform: "Orbit", stops: [{ location: "nauvis", wait: [{ type: "forever" }] }] },
      { platform: "Orbit", stops: [{ location: "nauvis", wait: [{ type: "time", ticks: -1 }] }] },
      { platform: "Orbit", stops: [{ location: "nauvis", wait: [{ type: "time", hours: 1 }] }] }])
      expect(schemas.set_platform_route.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    expect(call.mock.calls.some(([method]) => method === "queue_plan")).toBe(false);

    // Plans: the trip and the route are plan steps too; surface names the
    // surface a plan's positions are on.
    const plan = { surface: "vulcanus", steps: [{ action: "travel", to: "vulcanus" }, { action: "walk_to", x: 1, y: 2 },
      { action: "set_platform_route", platform: 3, paused: false }] };
    expect(schemas.queue_plan.safeParse(plan).success).toBe(true);
    expect(schemas.queue_plan.safeParse({ ...plan, surface: { platform: "Orbit" } }).success).toBe(true);
    expect(schemas.queue_plan.safeParse({ ...plan, steps: [{ action: "set_platform_route", platform: 3 }] }).success).toBe(false);
    await handlers.queue_plan(plan);
    expect(call).toHaveBeenLastCalledWith("queue_plan", expect.objectContaining({ surface: "vulcanus",
      steps: [plan.steps[0], { action: "walk_to", x: 1, y: 2, arrival_mode: "exact", arrival_radius: 1 }, plan.steps[2]] }));
  });

  it("reads another surface: factory_status, map_summary, inspect, placements and per-planet requirements", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => method === "factory_status"
      ? { tick: 7, surface: "vulcanus", unlocked_locations: {}, lines: {}, elsewhere: [{ surface: "nauvis", lines_running: 40, lines_total: 44,
        problems: 2, top_problems: {}, power_min_satisfaction: 1 }] }
      : method === "production_requirements" ? { nodes: {}, roots: { "tungsten-ore": [{ planet: "vulcanus", via: "big_drill" }], calcite: {} },
        unobtainable: {}, surface_limited: [{ recipe: "big-mining-drill", condition: "pressure", planets: {} }] }
      : method === "can_place" ? { results: [{ can_place: true }] }
      : method === "find_placement" ? { candidates: {} }
      : method === "inspect" ? { tick: 7, entities: [] } : {});
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; schemas[name] = config.inputSchema; } },
      async () => ({ call } as unknown as Bridge), validConfig, "read-only");

    const status = await handlers.factory_status(schemas.factory_status.parse({ surface: "vulcanus", sections: ["lines", "elsewhere"] }));
    expect(call).toHaveBeenLastCalledWith("factory_status", { surface: "vulcanus", sections: ["lines", "elsewhere"] });
    expect(status.structuredContent).toMatchObject({ unlocked_locations: [], lines: [], elsewhere: [{ surface: "nauvis", top_problems: [] }] });
    expect(status.content[0].text).toBe("tick 7 on vulcanus: 0 lines; 1 other surface in elsewhere");
    await handlers.map_summary(schemas.map_summary.parse({ surface: "all" }));
    expect(call).toHaveBeenLastCalledWith("map_summary", { detail: "aggregate", flow_precision: "one_minute", surface: "all" }, undefined);
    await handlers.inspect_entity(schemas.inspect_entity.parse({ positions: [{ x: 1, y: 2 }], surface: { platform: "Orbit" } }));
    expect(call).toHaveBeenLastCalledWith("inspect", { targets: [{ x: 1, y: 2 }], surface: { platform: "Orbit" } });
    await handlers.can_place(schemas.can_place.parse({ placements: [{ name: "foundry", x: 3.5, y: 3.5 }], surface: "vulcanus" }));
    expect(call).toHaveBeenLastCalledWith("can_place", { placements: [{ item: "foundry", position: { x: 3.5, y: 3.5 }, direction: undefined }], surface: "vulcanus" });
    await handlers.find_placement(schemas.find_placement.parse({ item: "offshore-pump", preferred: { x: 0, y: 0 }, fluid: "lava", surface: "vulcanus" }));
    expect(call).toHaveBeenLastCalledWith("find_placement", { item: "offshore-pump", preferred: { x: 0, y: 0 }, radius: 10, directions: [0, 4, 8, 12],
      limit: 8, fluid: "lava", surface: "vulcanus" }, undefined);
    const roots = await handlers.production_requirements(schemas.production_requirements.parse({ targets: { "tungsten-plate": 10 }, planet: "vulcanus" }));
    expect(call).toHaveBeenLastCalledWith("production_requirements", { targets: { "tungsten-plate": 10 }, flow_precision: "one_minute", planet: "vulcanus" });
    expect(roots.structuredContent).toMatchObject({ roots: { "tungsten-ore": [{ planet: "vulcanus", via: "big_drill" }], calcite: [] },
      unobtainable: [], surface_limited: [{ recipe: "big-mining-drill", planets: [] }] });
    // Read-only sessions read every surface but never travel or route a platform.
    expect(handlers.travel).toBeUndefined();
    expect(handlers.set_platform_route).toBeUndefined();
  });

  it("sets the body's own requests at once, checks another planet's ground in dry runs, and sites near any liquid", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => method === "set_requests"
      ? { code: "REQUESTS_SET", target: { kind: "character", name: "character" }, sections: [{ index: 1, items: {} }] }
      : method === "build_layout" ? { check_only: true, ok: true, placed: {}, failed: {} } : {});
    const enqueueAndWaitResult = vi.fn();
    registerMcpTools({ registerTool(name: string, config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; schemas[name] = config.inputSchema; } },
      async () => ({ call, enqueueAndWaitResult } as unknown as Bridge), validConfig);

    // Personal requests need no reach: one RPC, no FIFO; trash is theirs alone.
    const own = { target: "character", requests: [{ item: "iron-plate", min: 200 }], trash: ["wood"], trash_unrequested: false };
    const set = await handlers.set_requests(schemas.set_requests.parse(own));
    expect(call).toHaveBeenLastCalledWith("set_requests", own);
    expect(set.structuredContent).toMatchObject({ status: "completed", sections: [{ index: 1, items: [] }] });
    expect(set.content[0].text).toBe("your own requests set (1 sections)");
    expect(enqueueAndWaitResult).not.toHaveBeenCalled();
    for (const bad of [{ target: { x: 1, y: 1 }, trash: ["wood"] }, { target: "character", trash: ["wood"], requests: [{ item: "wood", min: 1 }] },
      { target: "character", request_from_buffers: true }, { target: "character" }, { target: "body", trash_unrequested: true }])
      expect(schemas.set_requests.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    expect(schemas.set_requests.safeParse({ target: "character", trash_unrequested: true }).success).toBe(true);

    // A layout dry run may name another surface; a build may not (its plan's surface decides).
    const layout = { site: { near: { x: 0, y: 0 }, near_liquid: "lava" }, entities: [{ name: "offshore-pump", dx: 0, dy: 0 }] };
    await handlers.build_layout(schemas.build_layout.parse({ ...layout, check_only: true, surface: "vulcanus" }));
    expect(call).toHaveBeenLastCalledWith("build_layout", { ...layout, check_only: true, surface: "vulcanus" }, undefined);
    expect(schemas.build_layout.safeParse({ ...layout, surface: "vulcanus" }).success).toBe(false);
    expect(schemas.build_block.safeParse({ block: "power", count: 1, check_only: true, surface: "nauvis" }).success).toBe(true);
    expect(schemas.build_block.safeParse({ block: "power", count: 1, surface: "nauvis" }).success).toBe(false);
    expect(schemas.build_layout.safeParse({ ...layout, site: { near: { x: 0, y: 0 }, near_liquid: "mud" } }).success).toBe(false);
    expect(schemas.queue_plan.safeParse({ steps: [{ action: "build_layout", ...layout }] }).success).toBe(true);
    expect(schemas.queue_plan.safeParse({ steps: [{ action: "create_platform", name: "Ferry", planet: "vulcanus" }] }).success).toBe(true);
    expect(schemas.create_platform.safeParse({ name: "Ferry", planet: "vulcanus" }).success).toBe(true);
  });

  it("names the protocol 28 states, parameters and fields in the tool descriptions", () => {
    const described: Record<string, string> = {};
    registerMcpTools({ registerTool(name: string, config: any) { described[name] = config.description; } },
      async () => ({ call: vi.fn() } as unknown as Bridge), validConfig);
    expect(described.factory_status).toMatch(/no_power, frozen, no_heat/);
    expect(described.factory_status).toMatch(/research_idle/);
    expect(described.create_platform).toMatch(/unlocked planet named in planet/);
    expect(described.travel).toMatch(/max_wait_minutes, default 60; NO_ROUTE/);
    expect(described.platform_status).toMatch(/trip \(from, to, how far along\), speed, paused, schedule/);
    expect(described.platform_status).toMatch(/thrusters/);
    expect(described.build_layout).toMatch(/near_liquid picks water, lava, heavy-oil or ammoniacal-solution; a dry run may name surface/);
    expect(described.build_block).toMatch(/A dry run may name surface/);
  });

  it("reports where the body is: ping, the FIFO and connect_status", async () => {
    const aboard = { state: "aboard_platform", surface_ref: "platform:3", platform_name: "Orbit" };
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const call = vi.fn(async (method: string) => method === "ping"
      ? { protocol_version: 28, mod_version: "0.25.0", factorio_version: "2.0.77", tick: 5, companion_exists: true,
        companion_ever_created: true, companion_dead: false, body: aboard }
      : { tick: 5, lines: [], fifo: { active_plan_id: 12, queue_depth: 1, idle_seconds: 0, body: aboard } });
    registerMcpTools({ registerTool(name: string, _config: any, handler: (args: any) => Promise<any>) { handlers[name] = handler; } },
      async () => ({ call } as unknown as Bridge), validConfig);
    const connected = await handlers.connect_status({});
    expect(connected.structuredContent).toMatchObject({ status: "connected", companion_exists: true, body: aboard });
    expect(connected.content[0].text).toBe("Connected; the body is aboard platform Orbit: physical actions fail with BODY_ABOARD until it lands; remote platform tools work");
    expect(call).not.toHaveBeenCalledWith("spawn_companion", expect.anything());
    const status = await handlers.factory_status({});
    expect(status.structuredContent.fifo).toMatchObject({ queue_depth: 1, body: aboard });
    // Riding up, the pod is still over the planet it left; the trip's destination is bound_for.
    const riding = { state: "in_transit", surface_ref: "nauvis", bound_for: "platform:3" };
    call.mockImplementation(async (method: string) => method === "ping"
      ? { protocol_version: 28, mod_version: "0.25.0", factorio_version: "2.0.77", tick: 6, companion_exists: true,
        companion_ever_created: true, companion_dead: false, body: riding } : {});
    expect((await handlers.connect_status({})).content[0].text)
      .toBe("Connected; the body is in a cargo pod (now over nauvis), bound for platform:3");
  });

  it("normalizes 0.22 power rows, robot networks and inspected inventories", () => {
    const row = { network_id: 4, satisfaction: 1, demand_w: 900000, capacity_w: 1200000, sources: {}, night_s: 0 };
    expect(normalizeFactoryStatus({ power: [row], logistics: { networks: [{ network_id: 2, coverage: {}, contents: {} }] } })).toEqual({
      power: [{ ...row, sources: [], accumulators: null }], logistics: { networks: [{ network_id: 2, coverage: [], contents: [] }] } });
    const short = { ...row, sources: [{ kind: "solar", count: 10, nameplate_w: 600000 }],
      accumulators: { count: 2, stored_j: 1, capacity_j: 10000000, charge: 0 }, add_to_cover: { solar_panel: 3, accumulator: 4 } };
    expect(normalizeMapSummary({ power: { networks: [short], networks_omitted: 0 } }).power.networks).toEqual([short]);
    expect(normalizeInspection({ entities: [{ name: "assembling-machine-2", inventories: { input: [], output: { "iron-gear-wheel": 3 } },
      settings: { inserter: { filters: {} } } }] }).entities[0]).toEqual({ name: "assembling-machine-2",
      inventories: { input: {}, output: { "iron-gear-wheel": 3 } }, settings: { inserter: { filters: [] } } });
  });

  it("summarizes activity_log rows that are not plan outcomes: cancels with who asked, and blueprint changes", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    let entries: unknown[] = [];
    const call = vi.fn(async () => ({ tick: 900, entries, omitted: 0 }));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call } as unknown as Bridge), validConfig, "read-only");
    const plan = { plan_id: 4, source: "pilot", status: "completed", summary: "built 4 furnaces", start_tick: 1, end_tick: 2 };
    const cancel = { kind: "cancel", tick: 800, origin: "stop/supervisor", all: true, after_plan_id: 4, cancelled_count: 3 };
    entries = [plan, cancel];
    const cancelled = await handlers.activity_log({ limit: 16 });
    expect(cancelled.structuredContent.entries).toEqual([plan, cancel]);
    expect(cancelled.content[0].text).toBe("2 rows; last: cancel by stop/supervisor (3 cancelled)");
    entries = [plan, cancel, { kind: "blueprint", action: "capture", name: "smelter", tick: 850, after_plan_id: 4 }];
    expect((await handlers.activity_log({ limit: 16 })).content[0].text).toBe("3 rows; last: blueprint capture smelter");
    entries = [plan];
    expect((await handlers.activity_log({ limit: 16 })).content[0].text).toBe("1 row; last: plan 4 built 4 furnaces");
    entries = {} as unknown[];
    expect((await handlers.activity_log({ limit: 16 })).content[0].text).toBe("0 rows");
  });

  it("parses and forwards both underground ends through placement search and returns verbatim plan steps", async () => {
    const schemas: Record<string, any> = {};
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const call = vi.fn(async (_method: string, payload: any) => ({ candidates: [{ build_steps: [{
      name: payload.item, x: payload.preferred.x, y: payload.preferred.y,
      direction: payload.directions[0], belt_to_ground_type: payload.belt_to_ground_type,
    }] }] }));
    registerMcpTools({ registerTool(name, config, handler) { schemas[name] = config.inputSchema; handlers[name] = handler; } },
      async () => ({ call } as unknown as Bridge), validConfig);
    const base = { item: "underground-belt", preferred: { x: 2.5, y: 3.5 }, directions: [4] };
    for (const belt_to_ground_type of ["input", "output"]) {
      const request = schemas.find_placement.parse({ ...base, belt_to_ground_type });
      const output = await handlers.find_placement(request);
      expect(call).toHaveBeenLastCalledWith("find_placement", { ...base, radius: 10, limit: 8, belt_to_ground_type }, undefined);
      const candidate = output.structuredContent.candidates[0];
      expect(candidate.build_steps).toEqual([{ name: base.item, x: 2.5, y: 3.5, direction: 4, belt_to_ground_type }]);
      expect(candidate.plan_steps).toEqual([{ action: "place_entity", ...candidate.build_steps[0] }]);
      for (const tool of ["queue_plan", "run_plan"]) {
        expect(schemas[tool].parse({ steps: candidate.plan_steps }).steps).toEqual(candidate.plan_steps);
      }
    }
    for (const belt_to_ground_type of ["sideways", "", null, 0, false]) {
      expect(schemas.find_placement.safeParse({ ...base, belt_to_ground_type }).success).toBe(false);
    }
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
    const selection = { tick: 10, refuel: { candidates: {}, selected: {} } };
    const upkeep = { selection_tick: 10, unfinished_targets: [{ step: 2, position: { x: 20, y: 2 },
      requested_items: { coal: 10 }, state: "not_started" }], preempted: true };
    expect(normalizePlanDiagnostics({ upkeep, upkeep_selection: selection }).upkeep).toEqual(upkeep);
    expect(normalizePlanDiagnostics({ upkeep_selection: selection }).upkeep_selection.refuel.selected).toEqual([]);
    expect(normalizeActivityLog({ entries: [{ source: "upkeep", upkeep: { unfinished_targets: {} } }] })
      .entries[0].upkeep.unfinished_targets).toEqual([]);
    expect(normalizeFactoryStatus({ body: { upkeep_selection: selection } }).body.upkeep_selection.refuel.candidates).toEqual([]);
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

  it("aliases measured production and consumption without inventing missing rates", () => {
    const rows = [
      { type: "item", name: "ore", input_rate: 2.125, output_rate: 3.5, precision: "one_minute", window_ticks: 3600, units: "units_per_minute", source: "force_flow_statistics" },
      { type: "fluid", name: "water", input_rate: 0, output_rate: 0 },
      { type: "item", name: "missing" },
      { type: "item", name: "invalid", input_rate: NaN, output_rate: Infinity },
    ];
    const normalized = normalizeMapSummary({ factory: { force_flows: rows } }).factory.force_flows;
    expect(normalized).toEqual([
      { ...rows[0], produced_per_minute: 2.125, consumed_per_minute: 3.5 },
      { ...rows[1], produced_per_minute: 0, consumed_per_minute: 0 }, rows[2], rows[3],
    ]);
    expect(rows[0]).not.toHaveProperty("produced_per_minute");
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
      inserted_items: {}, extracted_items: {}, target_actions: {}, events: {},
    } } })).toMatchObject({ factory: { groups: [], force_flows: [], character_transfers: {
      inserted_items: [], extracted_items: [], target_actions: [], events: [],
    } } });
    expect(normalizeFactoryStatus({ lines: {}, problems: {}, power: {}, patches: {}, stock: [{ item: "coal", holders: {} }],
      research: { available: {}, queue: {} }, body: { inventory_summary: [] } })).toEqual({ lines: [], problems: [], power: [], patches: [],
      stock: [{ item: "coal", holders: [] }], research: { available: [], queue: [] }, body: { inventory_summary: {} } });
    expect(normalizeActivityLog({ tick: 5, entries: {}, omitted: 0 })).toEqual({ tick: 5, entries: [], omitted: 0 });
    expect(normalizeProductionRequirements({ nodes: {} }).nodes).toEqual([]);
    // Technology and location modes carry the roots inside deterministic_requirements.
    const closure = normalizeProductionRequirements({ technology: "automation", deterministic_requirements: { nodes: {},
      roots: { "iron-ore": [{ planet: "nauvis", via: "drill" }], "wood": {} }, unobtainable: {},
      surface_limited: [{ recipe: "tungsten-plate", planets: {} }] } });
    expect(closure.deterministic_requirements).toMatchObject({ unobtainable: [], roots: { "iron-ore": [{ planet: "nauvis", via: "drill" }], wood: [] },
      surface_limited: [{ recipe: "tungsten-plate", planets: [] }] });
    expect(normalizeProductionRequirements({ technology: "automation", deterministic_requirements: { surface_limited: {} } })
      .deterministic_requirements.surface_limited).toEqual([]);
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

describe("plan_status idle feedback", () => {
  it("says the body is idle only when a terminal plan leaves the FIFO empty", () => {
    expect(planStatusSummary({ status: "completed", fifo_empty: true }, true)).toBe("completed; the FIFO is empty and the body is idle");
    expect(planStatusSummary({ status: "completed", fifo_empty: false }, true)).toBe("completed");
    expect(planStatusSummary({ status: "running", fifo_empty: true }, false)).toBe("running");
  });
});
