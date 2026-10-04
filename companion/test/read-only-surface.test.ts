import { describe, expect, it, vi } from "vitest";
import type { Bridge } from "../src/bridge.js";
import { READ_ONLY_TOOLS, registerMcpTools } from "../src/mcp/server.js";
import { queuePlanSchema } from "../src/mcp/runPlan.js";

const validConfig = () => ({ ok: true, config: {
  factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" },
} } as const);

describe("strategist read-only MCP surface", () => {
  it("registers exactly the audited read-only tools", () => {
    const names: string[] = [];
    registerMcpTools({ registerTool(name) { names.push(name); } }, async () => ({} as Bridge), validConfig, "read-only");
    expect(names.sort()).toEqual([...READ_ONLY_TOOLS].sort());
    expect([...READ_ONLY_TOOLS].sort()).toEqual(["can_place", "connect_status", "describe_prototype", "find_placement",
      "inspect_entity", "map_summary", "observe_local", "plan_status", "production_requirements", "progression_status"]);
  });

  it("does not create a body and read calls never enter the physical FIFO lane", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const call = vi.fn(async (method: string) => {
      if (method === "ping") return { protocol_version: 23, mod_version: "0.20.0", factorio_version: "2.0.77",
        tick: 12, companion_exists: false, companion_ever_created: false, companion_dead: false };
      if (method === "observe_local") return { tick: 12, entities: [], resource_patches: [], ground_items: [] };
      if (method === "inspect") return { tick: 12, entities: [{ name: "iron-chest", position: { x: 400.5, y: 0.5 }, remote: true }] };
      if (method === "map_summary") return { tick: 12, factory: {}, stockpiles: {}, sites: {}, patches: {},
        power: { networks: {} }, problems: {}, force_flows_all: {} };
      if (method === "plan_status") return { plan_id: 7, status: "completed" };
      if (method === "can_place") return { results: [{ can_place: true }] };
      if (method === "find_placement") return { candidates: [{ position: { x: 1, y: 1 }, direction: 0,
        build_steps: [{ name: "stone-furnace", x: 1, y: 1, direction: 0, fuel_inlet: true }] }] };
      return {};
    });
    const enqueueAndWait = vi.fn();
    const enqueueAndWaitResult = vi.fn();
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, async () => ({
      call, enqueueAndWait, enqueueAndWaitResult,
    } as unknown as Bridge), validConfig, "read-only");

    const connected = await handlers.connect_status({});
    expect(connected.structuredContent).toMatchObject({ status: "connected", read_only: true, companion_exists: false });
    expect(call).not.toHaveBeenCalledWith("spawn_companion", expect.anything());

    await handlers.observe_local({ radius: 15, detail: "compact" });
    const inspected = await handlers.inspect_entity({ positions: [{ x: 400.5, y: 0.5 }] });
    expect(inspected.structuredContent.entities[0].remote).toBe(true);
    const include = ["stockpiles", "sites", "patches", "power", "problems", "flows_all"];
    const summary = await handlers.map_summary({ detail: "aggregate", flow_precision: "one_minute", include });
    expect(call).toHaveBeenCalledWith("map_summary", { detail: "aggregate", flow_precision: "one_minute", include });
    expect(summary.structuredContent).toMatchObject({ stockpiles: [], sites: [], patches: [],
      power: { networks: [] }, problems: [], force_flows_all: [] });
    await handlers.progression_status({});
    await handlers.production_requirements({ technology: "automation", flow_precision: "one_minute" });
    await handlers.describe_prototype({ names: ["assembling-machine-1"], kind: "entity" });
    await handlers.plan_status({ plan_id: 7, wait_until: "current", timeout_seconds: 1 });
    await handlers.can_place({ placements: [{ name: "stone-furnace", x: 1, y: 1 }] });
    const placement = await handlers.find_placement({ item: "stone-furnace", preferred: { x: 1, y: 1 }, radius: 3,
      directions: [0], limit: 1, fuel: { coal: 5 } });
    const sentToLua = call.mock.calls.find(([method]) => method === "find_placement")?.[1];
    expect(sentToLua).not.toHaveProperty("fuel");
    const steps = placement.structuredContent.candidates[0].plan_steps;
    expect(queuePlanSchema.safeParse({ steps }).success).toBe(true);
    expect(steps.at(-1)).toEqual({ action: "insert_items", x: 1, y: 1, items: { coal: 5 } });

    expect(enqueueAndWait).not.toHaveBeenCalled();
    expect(enqueueAndWaitResult).not.toHaveBeenCalled();
    const methods = call.mock.calls.map(([method]) => method);
    expect(methods).not.toEqual(expect.arrayContaining([
      "spawn_companion", "start_research", "enqueue", "queue_plan", "cancel", "connect_entities",
    ]));
  });
});
