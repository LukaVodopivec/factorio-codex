import { describe, expect, it, vi } from "vitest";
import type { Bridge, TaskClock } from "../src/bridge.js";
import { registerMcpTools } from "../src/mcp/server.js";
import { executeRunPlan, runPlanSchema } from "../src/mcp/runPlan.js";

const validConfig = () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } } as const);
const observation = { tick: 9, entities: {}, resource_patches: {}, character: { inventory: {} } };

function bridgeWith(overrides: Partial<Bridge> = {}): Bridge {
  return {
    call: vi.fn(async (method: string) => method === "observe_local" ? observation : {}),
    enqueueAndWait: vi.fn(async (task: { type: string }) => `${task.type} done`),
    ...overrides,
  } as unknown as Bridge;
}

describe("run_plan", () => {
  it("validates all steps before acquiring the one bridge", async () => {
    const handlers: Record<string, (args: unknown, extra?: { signal?: AbortSignal }) => Promise<any>> = {};
    const provider = vi.fn(async () => bridgeWith());
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, provider, validConfig);
    const invalid = { steps: [{ action: "walk_to", x: 0, y: 0, sleep: 1 }] };
    await expect(handlers.run_plan!(invalid)).rejects.toThrow();
    expect(provider).not.toHaveBeenCalled();
    expect(runPlanSchema.safeParse({ steps: [] }).success).toBe(false);
    expect(runPlanSchema.safeParse({ steps: Array(26).fill({ action: "walk_to", x: 0, y: 0 }) }).success).toBe(false);
    expect(runPlanSchema.safeParse({ steps: [{ action: "build_plan", steps: [] }] }).success).toBe(false);
    expect(runPlanSchema.safeParse({ steps: [{ action: "start_research", technology: "automation" }] }).success).toBe(false);
    expect(runPlanSchema.safeParse({ steps: [{ action: "stop" }] }).success).toBe(false);
  });

  it("acquires one provider and returns compact text identical to structured content", async () => {
    const handlers: Record<string, (args: unknown, extra?: { signal?: AbortSignal }) => Promise<any>> = {};
    const provider = vi.fn(async () => bridgeWith());
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, provider, validConfig);
    const output = await handlers.run_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] });
    expect(provider).toHaveBeenCalledTimes(1);
    expect(output.content[0].text).toBe(JSON.stringify(output.structuredContent));
    expect(output.structuredContent).toMatchObject({ status: "completed", completed_steps: 1 });
  });

  it("maps existing action paths in order, uses one deadline, and observes once", async () => {
    let now = 1_000;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    const tasks: unknown[] = [];
    const deadlines: number[] = [];
    const bridge = bridgeWith({
      enqueueAndWait: vi.fn(async (task, opts) => {
        tasks.push(task); deadlines.push(opts?.deadlineMs ?? -1); now += 10; return `${task.type} ok`;
      }),
    } as Partial<Bridge>);
    const parsed = runPlanSchema.parse({ steps: [
      { action: "walk_to", x: 1, y: 2 },
      { action: "mine", x: 3, y: 4, count: 2 },
      { action: "place_entity", x: 5, y: 6, name: "stone-furnace", direction: 8 },
      { action: "craft_items", recipe: "iron-gear-wheel", count: 3 },
      { action: "insert_items", x: 7, y: 8, items: { coal: 1 } },
      { action: "extract_items", x: 9, y: 10 },
      { action: "set_recipe", x: 11, y: 12, recipe: "iron-gear-wheel" },
      { action: "rotate_entity", x: 13, y: 14, direction: 4 },
    ] });
    const result = await executeRunPlan(bridge, parsed, undefined, clock);
    expect(result.status).toBe("completed");
    expect(result.completed_steps).toBe(8);
    expect(tasks).toEqual([
      { type: "walk_to", target: { x: 1, y: 2 } },
      { type: "mine", target: { x: 3, y: 4 }, count: 2 },
      { type: "place", item: "stone-furnace", position: { x: 5, y: 6 }, direction: 8 },
      { type: "craft", recipe: "iron-gear-wheel", count: 3 },
      { type: "insert", target: { x: 7, y: 8 }, items: { coal: 1 } },
      { type: "extract", target: { x: 9, y: 10 }, all: true },
      { type: "set_recipe", target: { x: 11, y: 12 }, recipe: "iron-gear-wheel" },
      { type: "rotate", target: { x: 13, y: 14 }, direction: 4 },
    ]);
    expect(new Set(deadlines)).toEqual(new Set([571_000]));
    expect(result.observation).toEqual({ ...observation, entities: [], resource_patches: [] });
    expect(vi.mocked(bridge.call)).toHaveBeenCalledTimes(1);
  });

  it("polls wait_for_item through inspect without mutation", async () => {
    let now = 0;
    const sleeps: number[] = [];
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { sleeps.push(ms); now += ms; } };
    let inspections = 0;
    const call = vi.fn(async (method: string) => {
      if (method === "observe_local") return observation;
      inspections++;
      return { entities: [{ inventories: { output: { "iron-plate": inspections >= 3 ? 2 : 1 } } }] };
    });
    const bridge = bridgeWith({ call } as Partial<Bridge>);
    const result = await executeRunPlan(bridge, runPlanSchema.parse({ steps: [
      { action: "wait_for_item", x: 4, y: 5, inventory: "output", item: "iron-plate", count: 2 },
    ] }), undefined, clock);
    expect(result.status).toBe("completed");
    expect(sleeps).toEqual([500, 500]);
    expect(vi.mocked(bridge.enqueueAndWait)).not.toHaveBeenCalled();
    expect(call).toHaveBeenNthCalledWith(1, "inspect", { targets: [{ x: 4, y: 5 }] });
  });

  it("fails fast, enqueues nothing later, and still observes", async () => {
    const enqueueAndWait = vi.fn(async (task: { type: string }) => {
      if (task.type === "mine") throw new Error("resource exhausted");
      return "unexpected";
    });
    const bridge = bridgeWith({ enqueueAndWait } as Partial<Bridge>);
    const result = await executeRunPlan(bridge, runPlanSchema.parse({ steps: [
      { action: "mine", x: 1, y: 1, count: 2 },
      { action: "craft_items", recipe: "stone-furnace", count: 1 },
    ] }));
    expect(result).toMatchObject({ status: "failed", completed_steps: 0, failed_step: { step: 1, action: "mine", error: "resource exhausted" } });
    expect(enqueueAndWait).toHaveBeenCalledTimes(1);
    expect(vi.mocked(bridge.call)).toHaveBeenCalledWith("observe_local", { radius: 15 });
  });

  it("uses one absolute 570-second deadline and never starts a later step after it", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    const enqueueAndWait = vi.fn(async () => { now = 570_000; return "walked"; });
    const bridge = bridgeWith({ enqueueAndWait } as Partial<Bridge>);
    const result = await executeRunPlan(bridge, runPlanSchema.parse({ steps: [
      { action: "walk_to", x: 1, y: 1 },
      { action: "mine", x: 2, y: 2 },
    ] }), undefined, clock);
    expect(result).toMatchObject({
      status: "failed",
      completed_steps: 1,
      failed_step: { step: 2, action: "mine", error: "run_plan exceeded its 570-second deadline" },
    });
    expect(enqueueAndWait).toHaveBeenCalledTimes(1);
    expect(enqueueAndWait.mock.calls[0]?.[1]).toMatchObject({ deadlineMs: 570_000 });
  });

  it("honors abort between steps and records final-observation failure", async () => {
    const controller = new AbortController();
    const enqueueAndWait = vi.fn(async () => { controller.abort(); return "walked"; });
    const call = vi.fn(async () => { throw new Error("observation unavailable"); });
    const bridge = bridgeWith({ enqueueAndWait, call } as Partial<Bridge>);
    const result = await executeRunPlan(bridge, runPlanSchema.parse({ steps: [
      { action: "walk_to", x: 1, y: 1 }, { action: "mine", x: 2, y: 2 },
    ] }), controller.signal);
    expect(result).toMatchObject({ status: "cancelled", completed_steps: 1, failed_step: { step: 2, action: "mine" }, observation_error: "observation unavailable" });
    expect(enqueueAndWait).toHaveBeenCalledTimes(1);
  });

  it("times out wait_for_item under its bounded deadline and observes", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    const call = vi.fn(async (method: string) => method === "observe_local"
      ? observation : { entities: [{ inventories: { output: {} } }] });
    const result = await executeRunPlan(bridgeWith({ call } as Partial<Bridge>), runPlanSchema.parse({ steps: [
      { action: "wait_for_item", x: 0, y: 0, inventory: "output", item: "iron-plate", count: 1, timeout_seconds: 1 },
    ] }), undefined, clock);
    expect(result.status).toBe("failed");
    expect(result.failed_step?.error).toMatch(/timed out/);
    expect(now).toBe(1_000);
    expect(call).toHaveBeenLastCalledWith("observe_local", { radius: 15 });
  });
});
