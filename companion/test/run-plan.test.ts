import { describe, expect, it, vi } from "vitest";
import { Bridge, type TaskClock } from "../src/bridge.js";
import { registerMcpTools } from "../src/mcp/server.js";
import { executeRunPlan, runPlanSchema } from "../src/mcp/runPlan.js";
import type { RconClient } from "../src/rcon.js";

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
    expect(runPlanSchema.safeParse({ steps: [{ action: "walk_to", x: 0, y: 0 }], observation_radius: 20 }).success).toBe(false);
    expect(runPlanSchema.parse({ steps: [{ action: "walk_to", x: 0, y: 0 }], final_observation_radius: 20 }).final_observation_radius).toBe(20);
  });

  it("runs valid mapped steps in order through one registered-handler provider", async () => {
    const handlers: Record<string, (args: unknown, extra?: { signal?: AbortSignal }) => Promise<any>> = {};
    const enqueueAndWait = vi.fn(async (task: { type: string }) => `${task.type} done`);
    const call = vi.fn(async (method: string) => method === "observe_local" ? observation : {});
    const provider = vi.fn(async () => bridgeWith({ enqueueAndWait, call } as Partial<Bridge>));
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, provider, validConfig);
    const output = await handlers.run_plan!({ final_observation_radius: 21, steps: [
      { action: "walk_to", x: 1, y: 2 },
      { action: "mine", x: 3, y: 4, count: 2 },
    ] });
    expect(provider).toHaveBeenCalledTimes(1);
    expect(enqueueAndWait.mock.calls.map(([task]) => task)).toEqual([
      { type: "walk_to", target: { x: 1, y: 2 } },
      { type: "mine", target: { x: 3, y: 4 }, count: 2 },
    ]);
    expect(call).toHaveBeenCalledWith("observe_local", { radius: 21 });
    expect(output.isError).toBe(false);
    expect(output.content[0].text).toBe(JSON.stringify(output.structuredContent));
    expect(output.structuredContent).toMatchObject({
      status: "completed",
      completed_steps: 2,
      outcomes: [
        { step: 1, action: "walk_to", status: "completed", result: "walk_to done" },
        { step: 2, action: "mine", status: "completed", result: "mine done" },
      ],
    });
  });

  it("sets registered-handler isError for action and final-observation failures", async () => {
    const cases = [
      {
        bridge: bridgeWith({ enqueueAndWait: vi.fn(async () => { throw new Error("physical failure"); }) } as Partial<Bridge>),
        completedSteps: 0,
        errorField: "failed_step",
      },
      {
        bridge: bridgeWith({ call: vi.fn(async () => { throw new Error("final observation failure"); }) } as Partial<Bridge>),
        completedSteps: 1,
        errorField: "observation_error",
      },
    ];
    for (const scenario of cases) {
      const handlers: Record<string, (args: unknown) => Promise<any>> = {};
      const provider = vi.fn(async () => scenario.bridge);
      registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, provider, validConfig);
      const output = await handlers.run_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] });
      expect(provider).toHaveBeenCalledTimes(1);
      expect(output.isError).toBe(true);
      expect(output.structuredContent.status).toBe("failed");
      expect(output.structuredContent.completed_steps).toBe(scenario.completedSteps);
      expect(output.structuredContent[scenario.errorField]).toBeDefined();
      expect(output.content[0].text).toBe(JSON.stringify(output.structuredContent));
    }
  });

  it("reports provider failure before execution without fabricating an attempted step", async () => {
    const handlers: Record<string, (args: unknown) => Promise<any>> = {};
    const provider = vi.fn(async () => { throw new Error("RCON acquisition failed"); });
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, provider, validConfig);

    const output = await handlers.run_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] });

    expect(provider).toHaveBeenCalledTimes(1);
    expect(output.isError).toBe(true);
    expect(output.structuredContent).toEqual({
      status: "failed",
      completed_steps: 0,
      outcomes: [],
      observation_error: "RCON acquisition failed",
    });
    expect(output.structuredContent).not.toHaveProperty("failed_step");
    expect(output.content[0].text).toBe(JSON.stringify(output.structuredContent));
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
    const parsed = runPlanSchema.parse({ final_observation_radius: 23, steps: [
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
    expect(result.outcomes.every((outcome) => outcome.status === "completed" && "result" in outcome)).toBe(true);
    expect(vi.mocked(bridge.call)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(bridge.call)).toHaveBeenLastCalledWith("observe_local", { radius: 23 });
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
    expect(result).toMatchObject({
      status: "failed",
      completed_steps: 0,
      outcomes: [{ step: 1, action: "mine", status: "failed", error: "resource exhausted" }],
      failed_step: { step: 1, action: "mine", error: "resource exhausted" },
    });
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
      outcomes: [
        { step: 1, action: "walk_to", status: "completed", result: "walked" },
      ],
    });
    expect(result).not.toHaveProperty("failed_step");
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
    expect(result).toMatchObject({
      status: "cancelled",
      completed_steps: 1,
      outcomes: [
        { step: 1, action: "walk_to", status: "completed", result: "walked" },
      ],
      observation_error: "observation unavailable",
    });
    expect(result).not.toHaveProperty("failed_step");
    expect(enqueueAndWait).toHaveBeenCalledTimes(1);
  });

  it("records no attempted step when execution starts pre-aborted and still observes", async () => {
    const controller = new AbortController();
    controller.abort();
    const bridge = bridgeWith();

    const result = await executeRunPlan(bridge, runPlanSchema.parse({
      steps: [{ action: "walk_to", x: 1, y: 2 }],
    }), controller.signal);

    expect(result).toEqual({
      status: "cancelled",
      completed_steps: 0,
      outcomes: [],
      observation: { ...observation, entities: [], resource_patches: [] },
    });
    expect(result).not.toHaveProperty("failed_step");
    expect(vi.mocked(bridge.enqueueAndWait)).not.toHaveBeenCalled();
    expect(vi.mocked(bridge.call)).toHaveBeenCalledWith("observe_local", { radius: 15 });
  });

  it("classifies an in-step Bridge deadline timeout as failed, not cancelled", async () => {
    const methods: string[] = [];
    const exec = vi.fn(async (command: string) => {
      let data: unknown;
      if (command.includes('"enqueue"')) { methods.push("enqueue"); data = { task_id: 42 }; }
      else if (command.includes('"get_task"')) { methods.push("get_task"); data = { status: "running" }; }
      else if (command.includes('"cancel"')) { methods.push("cancel"); data = { cancelled: 1 }; }
      else if (command.includes('"observe_local"')) { methods.push("observe_local"); data = observation; }
      else throw new Error(`unexpected command: ${command}`);
      return JSON.stringify({ ok: true, data });
    });
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async () => { now = 570_000; } };
    const bridge = new Bridge({ exec } as unknown as RconClient);

    const result = await executeRunPlan(bridge, runPlanSchema.parse({
      steps: [{ action: "mine", x: 1, y: 2 }],
    }), undefined, clock);

    expect(result.status).toBe("failed");
    expect(result.completed_steps).toBe(0);
    expect(result.outcomes).toEqual([{
      step: 1,
      action: "mine",
      status: "failed",
      error: "gave up after 570s — task cancelled",
    }]);
    expect(result.failed_step).toEqual({
      step: 1,
      action: "mine",
      error: "gave up after 570s — task cancelled",
    });
    expect(result.observation).toEqual({ ...observation, entities: [], resource_patches: [] });
    expect(methods).toEqual(["enqueue", "cancel", "observe_local"]);
  });

  it("classifies an exact remote task-cancelled outcome as cancelled", async () => {
    const exec = vi.fn(async (command: string) => {
      const data = command.includes('"enqueue"') ? { task_id: 43 }
        : command.includes('"get_task"') ? { status: "cancelled" }
          : command.includes('"cancel"') ? { cancelled: 1 }
            : command.includes('"observe_local"') ? observation
              : undefined;
      return JSON.stringify({ ok: true, data });
    });
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };

    const result = await executeRunPlan(
      new Bridge({ exec } as unknown as RconClient),
      runPlanSchema.parse({ steps: [{ action: "mine", x: 1, y: 2 }] }),
      undefined,
      clock,
    );

    expect(result.status).toBe("cancelled");
    expect(result.outcomes).toEqual([{
      step: 1,
      action: "mine",
      status: "cancelled",
      error: "the task was cancelled",
    }]);
    expect(result.failed_step).toEqual({
      step: 1,
      action: "mine",
      error: "the task was cancelled",
    });
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

  it("fails a fully executed plan when its mandatory final observation fails", async () => {
    const call = vi.fn(async () => { throw new Error("final observation unavailable"); });
    const result = await executeRunPlan(bridgeWith({ call } as Partial<Bridge>), runPlanSchema.parse({
      steps: [{ action: "walk_to", x: 1, y: 2 }],
    }));
    expect(result).toEqual({
      status: "failed",
      completed_steps: 1,
      outcomes: [{ step: 1, action: "walk_to", status: "completed", result: "walk_to done" }],
      observation_error: "final observation unavailable",
    });
  });
});
