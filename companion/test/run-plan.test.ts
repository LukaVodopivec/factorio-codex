import { describe, expect, it, vi } from "vitest";
import { type TaskClock } from "../src/bridge.js";
import type { Bridge } from "../src/bridge.js";
import { executeRunPlan, queuePlanSchema, runPlanSchema } from "../src/mcp/runPlan.js";
import { registerMcpTools } from "../src/mcp/server.js";

const validConfig = () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } } as const);
const observation = { tick: 9, detail: "compact", entities: {}, resource_patches: {}, character: { inventory: {}, crafting: { queue_size: 0 } } };

describe("protocol-v11 plans", () => {
  it("validates the complete plan before acquiring a bridge", async () => {
    const handlers: Record<string, (args: unknown) => Promise<any>> = {};
    const provider = vi.fn(async () => ({} as Bridge));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, provider, validConfig);
    await expect(handlers.run_plan!({ steps: [{ action: "walk_to", x: 0, y: 0, sleep: 1 }] })).rejects.toThrow();
    expect(provider).not.toHaveBeenCalled();
    expect(runPlanSchema.safeParse({ steps: [] }).success).toBe(false);
    expect(runPlanSchema.safeParse({ steps: Array(26).fill({ action: "walk_to", x: 0, y: 0 }) }).success).toBe(false);
    expect(runPlanSchema.parse({ steps: [{ action: "craft_items", recipe: "gear", crafts: 1 }] }).steps[0]).toMatchObject({ crafts: 1, wait_for_completion: true });
    expect(runPlanSchema.safeParse({ steps: [{ action: "craft_items", recipe: "gear", count: 1 }] }).success).toBe(false);
    expect(runPlanSchema.parse({ steps: [{ action: "mine", x: 0, y: 0 }] }).steps[0]).toMatchObject({ count: 1, target_kind: "natural" });
    expect(runPlanSchema.safeParse({ steps: [{ action: "mine", x: 0, y: 0, target_kind: "machine" }] }).success).toBe(false);
  });

  it("queue_plan returns immediately and forwards dependency and observation selection", async () => {
    const call = vi.fn(async () => ({ plan_id: 8 }));
    const handlers: Record<string, (args: unknown) => Promise<any>> = {};
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, async () => ({ call } as unknown as Bridge), validConfig);
    const output = await handlers.queue_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }], after_plan_id: 7, observation_detail: "full" });
    expect(output.structuredContent).toEqual({ plan_id: 8 });
    expect(call).toHaveBeenCalledWith("queue_plan", queuePlanSchema.parse({ steps: [{ action: "walk_to", x: 1, y: 2 }], after_plan_id: 7, observation_detail: "full" }));
  });

  it("accepts exact grounded pickup steps and rejects incomplete targets", () => {
    expect(queuePlanSchema.safeParse({ steps: [{ action: "pickup_items", x: 1.25, y: 2.5, item: "iron-ore", count: 3 }] }).success).toBe(true);
    expect(queuePlanSchema.safeParse({ steps: [{ action: "pickup_items", x: 1.25, y: 2.5, item: "iron-ore" }] }).success).toBe(false);
  });

  it("preserves exact inserter input and output targets through queued plans", () => {
    const parsed = queuePlanSchema.parse({ steps: [{ action: "place_entity", name: "inserter", x: 1, y: 2,
      input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } }] });
    expect(parsed.steps[0]).toMatchObject({ input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } });
  });

  it("run_plan queues once, polls plan_status, and returns Lua's terminal observation", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    const call = vi.fn(async (method: string) => method === "queue_plan" ? { plan_id: 9 } : {
      plan_id: 9, status: "completed", source_tick: 42, completed_steps: 1, current_step: 1,
      outcomes: [{ step: 1, action: "walk_to", status: "completed", result: "done" }], observation,
    });
    const result = await executeRunPlan({ call } as unknown as Bridge, runPlanSchema.parse({ steps: [{ action: "walk_to", x: 1, y: 2 }] }), undefined, clock);
    expect(result).toMatchObject({ plan_id: 9, status: "completed", source_tick: 42, completed_steps: 1 });
    expect(result.observation).toEqual({ ...observation, entities: [], resource_patches: [], ground_items: [] });
    expect(call.mock.calls.map(([method]) => method)).toEqual(["queue_plan", "plan_status"]);
  });

  it("preserves failed terminal outcomes and cancels the exact plan on abort", async () => {
    let now = 0;
    const controller = new AbortController();
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; controller.abort(); } };
    const call = vi.fn(async (method: string) => method === "queue_plan" ? { plan_id: 10 } : { cancelled: 1 });
    const result = await executeRunPlan({ call } as unknown as Bridge, runPlanSchema.parse({ steps: [{ action: "mine", x: 1, y: 2 }] }), controller.signal, clock);
    expect(result).toMatchObject({ plan_id: 10, status: "cancelled" });
    expect(call).toHaveBeenLastCalledWith("cancel", { plan_id: 10 });
  });

  it("plan_status normalizes terminal empty collections", async () => {
    const handlers: Record<string, (args: unknown) => Promise<any>> = {};
    const call = vi.fn(async () => ({ plan_id: 11, status: "failed", completed_steps: 0, outcomes: [], observation }));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, async () => ({ call } as unknown as Bridge), validConfig);
    const output = await handlers.plan_status!({ plan_id: 11 });
    expect(output.isError).toBe(true);
    expect(output.structuredContent.observation).toMatchObject({ entities: [], resource_patches: [] });
  });
});
