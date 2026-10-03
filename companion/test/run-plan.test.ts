import { describe, expect, it, vi } from "vitest";
import { type TaskClock } from "../src/bridge.js";
import type { Bridge } from "../src/bridge.js";
import { executeRunPlan, queuePlanSchema, runPlanSchema, waitForPlanStatus } from "../src/mcp/runPlan.js";
import { registerMcpTools } from "../src/mcp/server.js";

const validConfig = () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } } as const);
const observation = { tick: 9, detail: "compact", entities: {}, resource_patches: {}, character: { inventory: {}, crafting: { queue_size: 0 } } };

describe("current queued-plan protocol", () => {
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
    expect(runPlanSchema.parse({ steps: [{ action: "mine", x: 0, y: 0 }] }).steps[0]).toMatchObject({ count: 1 });
    expect(runPlanSchema.parse({ steps: [{ action: "mine", x: 0, y: 0 }] }).steps[0]).not.toHaveProperty("target_kind");
    expect(runPlanSchema.parse({ steps: [{ action: "mine", x: 0.25, y: 0.5, expected_name: "tree-01", observed_tick: 42 }] }).steps[0]).toMatchObject({ expected_name: "tree-01", observed_tick: 42 });
    expect(runPlanSchema.safeParse({ steps: [{ action: "mine", x: 0, y: 0, expected_name: "", observed_tick: -1 }] }).success).toBe(false);
    expect(runPlanSchema.safeParse({ steps: [{ action: "mine", x: 0, y: 0, target_kind: "machine" }] }).success).toBe(false);
  });

  it("queue_plan returns immediately and forwards dependency and observation selection", async () => {
    const call = vi.fn(async () => ({ plan_id: 8 }));
    const handlers: Record<string, (args: unknown) => Promise<any>> = {};
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, async () => ({ call } as unknown as Bridge), validConfig);
    const output = await handlers.queue_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }], after_plan_id: 7, observation_detail: "full" });
    expect(output.structuredContent).toMatchObject({ plan_id: 8, status: "queued", terminal: false,
      next_action: { tool: "plan_status", arguments: { plan_id: 8, wait_until: "progress", timeout_seconds: 30 } } });
    expect(call).toHaveBeenCalledWith("queue_plan", queuePlanSchema.parse({ steps: [{ action: "walk_to", x: 1, y: 2 }], after_plan_id: 7, observation_detail: "full" }));
  });

  it("accepts exact grounded pickup steps and rejects incomplete targets", () => {
    expect(queuePlanSchema.safeParse({ steps: [{ action: "pickup_items", x: 1.25, y: 2.5, item: "iron-ore", count: 3 }] }).success).toBe(true);
    expect(queuePlanSchema.safeParse({ steps: [{ action: "pickup_items", x: 1.25, y: 2.5, item: "iron-ore" }] }).success).toBe(false);
    expect(queuePlanSchema.parse({ steps: [{ action: "walk_to", x: 1, y: 2 }] }).steps[0])
      .toMatchObject({ arrival_mode: "exact", arrival_radius: 1 });
    expect(queuePlanSchema.safeParse({ steps: [{ action: "walk_to", x: 1, y: 2, arrival_mode: "vicinity", arrival_radius: 6 }] }).success).toBe(true);
    expect(queuePlanSchema.safeParse({ steps: [{ action: "walk_to", x: 1, y: 2, arrival_mode: "exact", arrival_radius: 2 }] }).success).toBe(false);
    expect(queuePlanSchema.safeParse({ steps: [{ action: "walk_to", x: 1, y: 2, arrival_radius: 7 }] }).success).toBe(false);
    expect(queuePlanSchema.safeParse({ steps: [{ action: "wait_for_research", technology: "automation", timeout_seconds: 30 }] }).success).toBe(true);
    expect(queuePlanSchema.safeParse({ steps: [{ action: "validate_factory_component", source_tick: 4,
      positions: [{ x: 1, y: 2 }], duration_seconds: 30 }] }).success).toBe(true);
  });

  it("preserves exact inserter input and output targets through queued plans", () => {
    const parsed = queuePlanSchema.parse({ steps: [{ action: "place_entity", name: "inserter", x: 1, y: 2,
      input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } }] });
    expect(parsed.steps[0]).toMatchObject({ input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } });
    expect(queuePlanSchema.safeParse({ steps: [{ action: "place_entity", name: "inserter", x: 1, y: 2,
      input_target: { x: "stale", y: 1 } }] }).success).toBe(false);
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

  it("waits for a meaningful plan transition and ignores dispatch-only state changes", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    const statuses = [
      { plan_id: 12, status: "queued", completed_steps: 0, outcomes: [] },
      { plan_id: 12, status: "running", completed_steps: 0, outcomes: [] },
      { plan_id: 12, status: "running", completed_steps: 1, outcomes: [{ step: 1, action: "walk_to", status: "completed" }] },
    ];
    const call = vi.fn(async () => statuses.shift());
    const output = await waitForPlanStatus({ call } as unknown as Bridge, 12, "progress", 5_000, undefined, clock);
    expect(output).toMatchObject({ status: "running", completed_steps: 1 });
    expect(call).toHaveBeenCalledTimes(3);
  });

  it("returns latest state and explicit wait timeout without cancelling physical work", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    const call = vi.fn(async () => ({ plan_id: 13, status: "running", completed_steps: 0, outcomes: [] }));
    const output = await waitForPlanStatus({ call } as unknown as Bridge, 13, "terminal", 2_000, undefined, clock);
    expect(output).toMatchObject({ status: "running", wait: { condition: "terminal", timed_out: true, waited_ms: 2_000 } });
    expect(call.mock.calls.every(([method]) => method === "plan_status")).toBe(true);
  });

  it("aborting a status wait stops monitoring without cancelling the physical plan", async () => {
    let now = 0;
    const controller = new AbortController();
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; controller.abort(); } };
    const call = vi.fn(async () => ({ plan_id: 15, status: "running", completed_steps: 0, outcomes: [] }));
    await expect(waitForPlanStatus({ call } as unknown as Bridge, 15, "terminal", 2_000, controller.signal, clock))
      .rejects.toThrow("physical plan remains active");
    expect(call.mock.calls).toEqual([["plan_status", { plan_id: 15 }]]);
  });

  it("preserves failed terminal outcomes and cancels the exact plan on abort", async () => {
    let now = 0;
    const controller = new AbortController();
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; controller.abort(); } };
    let statusReads = 0;
    const call = vi.fn(async (method: string) => method === "queue_plan" ? { plan_id: 10 }
      : method === "cancel" ? { cancelled: 1 }
      : ++statusReads === 1 ? { plan_id: 10, status: "running", completed_steps: 1,
        outcomes: [{ step: 1, action: "mine", status: "completed" }] }
      : { plan_id: 10, status: "cancelled", current_step: 2, completed_steps: 1,
        outcomes: [{ step: 1, action: "mine", status: "completed" },
          { step: 2, action: "walk_to", status: "cancelled", error: "cancelled" }],
        execution: { mode: "sequential_nontransactional", rollback: "none", committed_steps: [1],
          incomplete_step: { step: 2, status: "cancelled", effects: "unknown" } } });
    const result = await executeRunPlan({ call } as unknown as Bridge, runPlanSchema.parse({ steps: [
      { action: "mine", x: 1, y: 2 }, { action: "walk_to", x: 3, y: 4 },
    ] }), controller.signal, clock);
    expect(result).toMatchObject({ plan_id: 10, status: "cancelled", completed_steps: 1,
      execution: { rollback: "none", incomplete_step: { effects: "unknown" } } });
    expect(call.mock.calls.map(([method]) => method)).toEqual(["queue_plan", "plan_status", "cancel", "plan_status"]);
  });

  it("preserves structured split selector identities in a failed terminal bridge response", async () => {
    const positions = [{ x: 0, y: 0 }, { x: 2, y: 0 }];
    const selector = { code: "FACTORY_COMPONENT_SPLIT", stage: "selector",
      component_signatures_by_position: positions.map((position, i) => ({ position,
        component_id: `component-${i + 1}`, component_signature: `exact-component-${i + 1}` })) };
    const terminal = { plan_id: 17, status: "failed", completed_steps: 0,
      outcomes: [{ step: 1, action: "validate_factory_component", status: "failed",
        error: "FACTORY_COMPONENT_SPLIT", result: selector }] };
    const call = vi.fn(async (method: string) => method === "queue_plan" ? { plan_id: 17 } : terminal);
    const result = await executeRunPlan({ call } as unknown as Bridge, runPlanSchema.parse({ steps: [
      { action: "validate_factory_component", source_tick: 300, positions, duration_seconds: 1 },
      { action: "walk_to", x: 3, y: 0 },
    ] }));
    expect(result).toEqual(terminal);
    expect(result.outcomes[0]?.result).toEqual(selector);
    expect(call.mock.calls.map(([method]) => method)).toEqual(["queue_plan", "plan_status"]);
  });

  it("marks effects unknown instead of fabricating zero progress when cancellation readback fails", async () => {
    let now = 0;
    const controller = new AbortController();
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; controller.abort(); } };
    let statusReads = 0;
    const call = vi.fn(async (method: string) => {
      if (method === "queue_plan") return { plan_id: 16 };
      if (method === "cancel") return { cancelled: 1 };
      if (++statusReads === 1) return { plan_id: 16, status: "running", completed_steps: 1,
        outcomes: [{ step: 1, action: "mine", status: "completed" }] };
      throw new Error("readback unavailable");
    });
    const output = await executeRunPlan({ call } as unknown as Bridge, runPlanSchema.parse({ steps: [
      { action: "mine", x: 1, y: 2 }, { action: "walk_to", x: 3, y: 4 },
    ] }), controller.signal, clock);
    expect(output.completed_steps).toBeUndefined();
    expect(output).toMatchObject({ plan_id: 16, status: "cancelled",
      execution: { rollback: "none", effects_state: "unknown", incomplete_step: { effects: "unknown" } } });
  });

  it("plan_status normalizes terminal empty collections", async () => {
    const handlers: Record<string, (args: unknown) => Promise<any>> = {};
    const call = vi.fn(async () => ({ plan_id: 11, status: "failed", completed_steps: 0, outcomes: [], observation }));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, async () => ({ call } as unknown as Bridge), validConfig);
    const output = await handlers.plan_status!({ plan_id: 11 });
    expect(output.isError).toBe(true);
    expect(output.structuredContent.observation).toMatchObject({ entities: [], resource_patches: [] });
  });

  it("uses bounded status waiting without passing monitoring fields into Lua", async () => {
    const handlers: Record<string, (args: unknown, extra?: { signal?: AbortSignal }) => Promise<any>> = {};
    const call = vi.fn(async () => ({ plan_id: 14, status: "completed", completed_steps: 1, outcomes: [] }));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, async () => ({ call } as unknown as Bridge), validConfig);
    const output = await handlers.plan_status!({ plan_id: 14, wait_until: "terminal", timeout_seconds: 10 });
    expect(output.structuredContent).toMatchObject({ plan_id: 14, status: "completed", terminal: true, next_action: null });
    expect(call).toHaveBeenCalledWith("plan_status", { plan_id: 14 });
  });
});
