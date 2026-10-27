import { z } from "zod";
import { fieldLine, stepLines } from "../src/mcp/schemaContract.js";
import { describe, expect, it, vi } from "vitest";
import { Bridge, DEFAULT_TASK_TIMEOUT_MS, ModError, OutcomeUnknownError, WriterRetiredError, type TaskClock } from "../src/bridge.js";
import { RconError } from "../src/rcon.js";
import type { RconClient } from "../src/rcon.js";
import { executeRunPlan, packageStepSchema, planStepSchema, planContract, planStatusSchema, queuePlanSchema, runPlanSchema, waitForPlanStatus } from "../src/mcp/runPlan.js";
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
    expect(runPlanSchema.safeParse({ steps: Array(200).fill({ action: "walk_to", x: 0, y: 0 }) }).success).toBe(true);
    expect(runPlanSchema.safeParse({ steps: Array(201).fill({ action: "walk_to", x: 0, y: 0 }) }).success).toBe(false);
    // Crafting does not hold the body unless asked to.
    expect(runPlanSchema.parse({ steps: [{ action: "craft_items", recipe: "gear", crafts: 1 }] }).steps[0]).not.toHaveProperty("wait_for_completion");
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
    const output = await handlers.queue_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }], after_plan_id: 7, observation_detail: "compact" });
    expect(output.structuredContent).toMatchObject({ plan_id: 8, status: "queued", terminal: false,
      next_action: { tool: "next_event", arguments: { timeout_seconds: 25 } } });
    expect(call).toHaveBeenCalledWith("queue_plan", { ...queuePlanSchema.parse({ steps: [{ action: "walk_to", x: 1, y: 2 }], after_plan_id: 7, observation_detail: "compact" }),
      client_key: expect.stringMatching(/^[0-9a-f-]{36}$/) });
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
      positions: [{ x: 1, y: 2 }] }] }).success).toBe(false);
  });

  it("accepts the goal-level steps and auto_supply, and checks a layout's anchor or site", () => {
    const layout = { action: "build_layout", entities: [{ name: "stone-furnace", dx: 0, dy: 2, direction: 0 }],
      connections: [{ kind: "belt", prototype: "transport-belt", from: { dx: 0, dy: 0 }, to: { dx: 4, dy: 0 } }] };
    const parsed = queuePlanSchema.parse({ steps: [
      { action: "get_items", item: "iron-gear-wheel", count: 10 },
      { ...layout, anchor: { x: 10, y: 20 } },
      { ...layout, site: { near: { x: 0, y: 0 }, on_resource: "iron-ore" } },
      { action: "place_entity", name: "wooden-chest", x: 1, y: 1, auto_supply: false },
      { action: "insert_items", x: 1, y: 1, items: { coal: 5 }, auto_supply: true },
    ] });
    expect(parsed.steps.map((step) => step.action)).toEqual(["get_items", "build_layout", "build_layout", "place_entity", "insert_items"]);
    expect(queuePlanSchema.safeParse({ steps: [layout] }).success).toBe(false);
    expect(queuePlanSchema.safeParse({ steps: [{ ...layout, anchor: { x: 0, y: 0 }, site: { near: { x: 0, y: 0 } } }] }).success).toBe(false);
    expect(queuePlanSchema.safeParse({ steps: [{ ...layout, anchor: { x: 0, y: 0 }, check_only: true }] }).success).toBe(false);
    expect(queuePlanSchema.safeParse({ steps: [{ action: "build_block", block: "mining", count: 1, resource: "iron-ore" }] }).success).toBe(false);
    // get_items craft: false is a plan and package step option too, kept as given and absent when not given.
    const noCraft = { action: "get_items", item: "iron-gear-wheel", count: 10, craft: false };
    expect(queuePlanSchema.parse({ steps: [noCraft] }).steps[0]).toEqual(noCraft);
    expect(packageStepSchema.parse(noCraft)).toEqual(noCraft);
    expect(parsed.steps[0]).not.toHaveProperty("craft");
    expect(queuePlanSchema.safeParse({ steps: [{ ...noCraft, craft: 0 }] }).success).toBe(false);
  });

  it("preserves exact inserter input and output targets through queued plans", () => {
    const parsed = queuePlanSchema.parse({ steps: [{ action: "place_entity", name: "inserter", x: 1, y: 2,
      input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } }] });
    expect(parsed.steps[0]).toMatchObject({ input_target: { x: 1, y: 1 }, output_target: { x: 1, y: 3 } });
    expect(queuePlanSchema.safeParse({ steps: [{ action: "place_entity", name: "inserter", x: 1, y: 2,
      input_target: { x: "stale", y: 1 } }] }).success).toBe(false);
  });

  it("caps and defaults plan_status waits at next_event's 25 s, under the 31 s code-mode exec yield", () => {
    expect(planStatusSchema.parse({ plan_id: 1 })).toEqual({ plan_id: 1, wait_until: "current", timeout_seconds: 25 });
    expect(planStatusSchema.safeParse({ plan_id: 1, timeout_seconds: 25 }).success).toBe(true);
    expect(planStatusSchema.safeParse({ plan_id: 1, timeout_seconds: 26 }).success).toBe(false);
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
    ] }), controller.signal, clock, "build_plan", "pilot");
    expect(result).toMatchObject({ plan_id: 10, status: "cancelled", completed_steps: 1,
      execution: { rollback: "none", incomplete_step: { effects: "unknown" } } });
    expect(call.mock.calls.map(([method]) => method)).toEqual(["queue_plan", "plan_status", "cancel", "plan_status"]);
    // The cancel names the tool and that the bridge aborted its own plan.
    expect(call).toHaveBeenCalledWith("cancel", { plan_id: 10, origin: "build_plan/pilot/abort" });
  });

  it.each([
    ["transport", () => { throw new RconError("connection closed"); }],
    ["mod refusal", () => { throw new ModError("status unavailable"); }],
    ["unexpected error", () => { throw new Error("monitor failed"); }],
    ["null reply", () => null],
    ["invalid status", () => ({ status: "nonsense" })],
    ["missing identity", () => ({ status: "completed", outcomes: [] })],
    ["wrong identity", () => ({ plan_id: 99, status: "completed", outcomes: [] })],
    ["invalid outcomes", () => ({ plan_id: 41, status: "completed", outcomes: 7 })],
    ["invalid outcome row", () => ({ plan_id: 41, status: "completed", outcomes: [7] })],
  ])("keeps accepted work after a %s monitoring failure, including committed steps", async (_name, fail) => {
    for (const committed of [false, true]) {
      let reads = 0;
      let now = 0;
      const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
      const latest = { plan_id: 41, status: "running", current_step: 8, completed_steps: 7,
        outcomes: [{ step: 7, action: "build_plan", status: "completed" }],
        execution: { mode: "sequential_nontransactional", rollback: "none", committed_steps: [1, 2, 3, 4, 5, 6, 7] } };
      const call = vi.fn(async (method: string) => {
        if (method === "queue_plan") return { plan_id: 41 };
        if (committed && ++reads === 1) return latest;
        return fail();
      });
      const error = await executeRunPlan({ call } as unknown as Bridge,
        runPlanSchema.parse({ steps: [{ action: "walk_to", x: 1, y: 2 }] }), undefined, clock)
        .catch((error: unknown) => error);
      expect(error).toBeInstanceOf(OutcomeUnknownError);
      expect(error).toMatchObject({ accepted: { plan_id: 41 }, message: expect.stringContaining("physical state is unknown") });
      expect((error as OutcomeUnknownError).lastKnown).toEqual(committed ? latest : undefined);
      expect(call.mock.calls.map(([method]) => method)).toEqual(committed
        ? ["queue_plan", "plan_status", "plan_status"] : ["queue_plan", "plan_status"]);
    }
  });

  it("accepts Lua's empty outcomes table without mistaking it for a monitoring failure", async () => {
    const terminal = { plan_id: 44, status: "completed", outcomes: {} };
    const call = vi.fn(async (method: string) => method === "queue_plan" ? { plan_id: 44 } : terminal);
    const output = await executeRunPlan({ call } as unknown as Bridge,
      runPlanSchema.parse({ steps: [{ action: "walk_to", x: 1, y: 2 }] }));
    expect(output).toEqual(terminal);
    expect(call.mock.calls.map(([method]) => method)).toEqual(["queue_plan", "plan_status"]);
  });

  it("exposes accepted identity and uncertainty through the MCP result", async () => {
    const handlers: Record<string, (args: unknown, extra?: { signal?: AbortSignal }) => Promise<any>> = {};
    const call = vi.fn(async (method: string) => {
      if (method === "queue_plan") return { plan_id: 42 };
      throw new Error("status unavailable");
    });
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call } as unknown as Bridge), validConfig, "full", () => null, "pilot");
    const output = await handlers.run_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] });
    expect(output.isError).toBe(true);
    expect(output.structuredContent).toMatchObject({ status: "outcome_unknown", code: "OUTCOME_UNKNOWN",
      plan_id: 42, physical_state: "unknown" });
    expect(call.mock.calls.map(([method]) => method)).toEqual(["queue_plan", "plan_status"]);

    const controller = new AbortController();
    call.mockImplementation(async (method: string) => {
      if (method === "queue_plan") { controller.abort(); return { plan_id: 43 }; }
      if (method === "cancel") return { cancelled: 1 };
      return { plan_id: 43, status: "cancelled", outcomes: [] };
    });
    await handlers.run_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] }, { signal: controller.signal });
    expect(call).toHaveBeenCalledWith("cancel", { plan_id: 43, origin: "run_plan/pilot/abort" });
  });

  it("preserves a structured failure result in a failed terminal bridge response", async () => {
    const positions = [{ x: 0, y: 0 }, { x: 2, y: 0 }];
    const selector = { code: "LAYOUT_PARTIAL", failed: positions.map((position, index) => ({ index, code: "BLOCKED", position })) };
    const terminal = { plan_id: 17, status: "failed", completed_steps: 0,
      outcomes: [{ step: 1, action: "build_layout", status: "failed",
        error: "LAYOUT_PARTIAL", result: selector }] };
    const call = vi.fn(async (method: string) => method === "queue_plan" ? { plan_id: 17 } : terminal);
    const result = await executeRunPlan({ call } as unknown as Bridge, runPlanSchema.parse({ steps: [
      { action: "build_layout", anchor: { x: 0, y: 0 }, entities: positions.map(({ x, y }) => ({ name: "stone-furnace", dx: x, dy: y })) },
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
    ] }), controller.signal, clock).catch((error: unknown) => error);
    expect(output).toBeInstanceOf(OutcomeUnknownError);
    expect(output).toMatchObject({ accepted: { plan_id: 16 },
      lastKnown: { status: "running", completed_steps: 1, outcomes: [{ step: 1, status: "completed" }] },
      cancellation: { acknowledgement: { cancelled: 1 }, readback_error: "readback unavailable" } });
    expect(output).not.toHaveProperty("execution.incomplete_step");
  });

  it.each([
    ["fence", "running"], ["transport", "running"], ["transport", "unavailable"],
    ["malformed", "malformed"], ["zero", "mismatched"], ["acknowledged", "running"],
    ["acknowledged", "unavailable"], ["acknowledged", "malformed"], ["acknowledged", "invalid observation"],
  ])("retains seven committed steps with %s cancel and %s readback", async (cancel, readback) => {
    const controller = new AbortController();
    const latest = { plan_id: 91, status: "running", current_step: 8, completed_steps: 7,
      outcomes: Array.from({ length: 7 }, (_, i) => ({ step: i + 1, action: "mine", status: "completed" })),
      execution: { mode: "sequential_nontransactional", rollback: "none", committed_steps: [1, 2, 3, 4, 5, 6, 7] } };
    let requested = false;
    const call = vi.fn(async (method: string) => {
      if (method === "queue_plan") return { plan_id: 91 };
      if (method === "cancel") {
        requested = true;
        if (cancel === "fence") throw new WriterRetiredError("WRITER_RETIRED: newer writer");
        if (cancel === "transport") throw new RconError("transport lost");
        return cancel === "malformed" ? { cancelled: "1" } : { cancelled: cancel === "zero" ? 0 : 1 };
      }
      if (!requested || readback === "running") return latest;
      if (readback === "unavailable") throw new Error("readback unavailable");
      if (readback === "invalid observation") return { ...latest, status: "completed", observation: { entities: 7 } };
      return readback === "mismatched" ? { plan_id: 92, status: "completed", outcomes: [] }
        : { plan_id: 91, status: "cancelled", outcomes: [{ step: 1, action: "mine", status: "nonsense" }] };
    });
    const clock: TaskClock = { now: () => 0, sleep: async () => { controller.abort(); } };
    const output = await executeRunPlan({ call } as unknown as Bridge,
      runPlanSchema.parse({ steps: [{ action: "mine", x: 1, y: 2 }] }), controller.signal, clock, "build_plan", "pilot")
      .catch((error: unknown) => error);
    expect(output).toBeInstanceOf(OutcomeUnknownError);
    expect(output).toMatchObject({ accepted: { plan_id: 91 }, lastKnown: latest,
      cancellation: { origin: "build_plan/pilot/abort", readback_error: expect.any(String) } });
    expect((output as Error).message).toContain("last_known is historical");
    if (cancel === "fence") expect(output).toMatchObject({ cancellation: { code: "WRITER_RETIRED" } });
    if (cancel === "transport") expect(output).toMatchObject({ cancellation: { error: "transport lost" } });
    if (cancel === "malformed") expect(output).toMatchObject({ cancellation: { error: expect.stringContaining("malformed") } });
    expect(call.mock.calls.map(([method]) => method)).toEqual(["queue_plan", "plan_status", "cancel", "plan_status"]);
    expect(call).toHaveBeenCalledWith("cancel", { plan_id: 91, origin: "build_plan/pilot/abort" });
  });

  it.each(["completed", "partial", "failed", "cancelled"])("preserves authoritative plan %s after a zero cancellation", async (status) => {
    const controller = new AbortController();
    let requested = false;
    const terminal = { plan_id: 91, status, completed_steps: 1,
      outcomes: [{ step: 1, action: "mine", status: "completed" }] };
    const call = vi.fn(async (method: string) => {
      if (method === "queue_plan") return { plan_id: 91 };
      if (method === "cancel") { requested = true; return { cancelled: 0 }; }
      return requested ? terminal : { plan_id: 91, status: "running", outcomes: [] };
    });
    const clock: TaskClock = { now: () => 0, sleep: async () => { controller.abort(); } };
    const result = await executeRunPlan({ call } as unknown as Bridge,
      runPlanSchema.parse({ steps: [{ action: "mine", x: 1, y: 2 }] }), controller.signal, clock);
    expect(result).toMatchObject({ ...terminal, cancellation: { acknowledgement: { cancelled: 0 } } });
    expect(call.mock.calls.map(([method]) => method)).toEqual(["queue_plan", "plan_status", "cancel", "plan_status"]);
  });

  it.each(["run_plan", "walk_to", "connect_entities"])("exposes cancellation rejection and historical evidence through MCP %s", async (tool) => {
    const controller = new AbortController();
    const handlers: Record<string, (args: any, extra?: any) => Promise<any>> = {};
    let reads = 0;
    const plan = { plan_id: 91, status: "running", current_step: 8, completed_steps: 7,
      outcomes: Array.from({ length: 7 }, (_, i) => ({ step: i + 1, action: "mine", status: "completed" })),
      execution: { mode: "sequential_nontransactional", rollback: "none", committed_steps: [1, 2, 3, 4, 5, 6, 7] } };
    const task = { status: "running", detail: "historical progress", outcome: { inserted: 7 } };
    const methods: string[] = [];
    const exec = vi.fn(async (cmd: string) => {
      const method = /"rpc","([a-z_]+)"/.exec(cmd)![1]!;
      methods.push(method);
      if (method === "connect_entities") return JSON.stringify({ ok: true, data: { kind: "belt", steps: [{ x: 1, y: 0, name: "transport-belt" }] } });
      if (method === "enqueue" || method === "queue_plan") return JSON.stringify({ ok: true, data: { task_id: 92, plan_id: 91 } });
      if (method === "cancel") return JSON.stringify({ ok: false, error: "WRITER_RETIRED: newer writer" });
      if (++reads === 1) controller.abort();
      return JSON.stringify({ ok: true, data: tool === "run_plan" ? plan : task });
    });
    const bridge = new Bridge({ exec } as unknown as RconClient);
    bridge.writerGeneration = 4;
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, async () => bridge, validConfig);
    vi.useFakeTimers();
    try {
      const pending = handlers[tool]!(tool === "run_plan" ? { steps: [{ action: "mine", x: 1, y: 2 }] } : tool === "connect_entities"
        ? { kind: "belt", prototype: "transport-belt", from: { x: 0, y: 0 }, to: { x: 2, y: 0 } } : { x: 1, y: 2 },
        { signal: controller.signal });
      await vi.advanceTimersByTimeAsync(2_000);
      const output = await pending;
      expect(output.isError).toBe(true);
      expect(output.structuredContent).toMatchObject({ status: "outcome_unknown", code: "OUTCOME_UNKNOWN", physical_state: "unknown",
        ...(tool === "run_plan" ? { plan_id: 91, last_known: plan } : { task_id: 92, last_known: task }),
        cancellation: { code: "WRITER_RETIRED", error: "WRITER_RETIRED: newer writer",
          origin: `${tool}/unknown/abort` } });
      expect(output.content[0].text).toContain("was not confirmed");
      expect(output.content[0].text).not.toMatch(/was cancelled|task cancelled|retry the call/);
      expect(methods).toEqual(tool === "run_plan" ? ["queue_plan", "plan_status", "cancel", "plan_status"]
        : [...(tool === "connect_entities" ? ["connect_entities"] : []), "enqueue", "get_task", "cancel", "get_task"]);
      const cancel = exec.mock.calls.find(([cmd]) => cmd.includes('"cancel"'))![0];
      expect(cancel).toContain('writer_generation');
      expect(methods).not.toContain("claim_writer");
    } finally { vi.useRealTimers(); }
  });

  it.each(["fence", "transport", "malformed"])("keeps terminal plan results and %s cancellation evidence", async (failure) => {
    const controller = new AbortController();
    let requested = false;
    const terminal = { plan_id: 91, status: "completed", completed_steps: 1,
      outcomes: [{ step: 1, action: "mine", status: "completed" }] };
    const call = vi.fn(async (method: string) => {
      if (method === "queue_plan") return { plan_id: 91 };
      if (method === "cancel") {
        requested = true;
        if (failure === "fence") throw new WriterRetiredError("WRITER_RETIRED: newer writer");
        if (failure === "transport") throw new RconError("transport lost");
        return null;
      }
      return requested ? terminal : { plan_id: 91, status: "running", outcomes: [] };
    });
    const clock: TaskClock = { now: () => 0, sleep: async () => { controller.abort(); } };
    const output = await executeRunPlan({ call } as unknown as Bridge,
      runPlanSchema.parse({ steps: [{ action: "mine", x: 1, y: 2 }] }), controller.signal, clock);
    expect(output).toMatchObject({ ...terminal, cancellation: { error: expect.any(String) } });
    expect(call.mock.calls.map(([method]) => method)).toEqual(["queue_plan", "plan_status", "cancel", "plan_status"]);
  });

  it.each(["belt", "power"])("connect_entities preserves terminal results and zero cancellation for %s routes", async (kind) => {
    for (const status of ["done", "partial", "failed", "cancelled"]) {
    const controller = new AbortController();
    const handlers: Record<string, (args: any, extra?: any) => Promise<any>> = {};
    let requested = false;
    const outcome = { placed: 7, requested: 8 };
    const exec = vi.fn(async (cmd: string) => {
      const method = /"rpc","([a-z_]+)"/.exec(cmd)![1]!;
      let data: unknown;
      if (method === "connect_entities") data = { kind, steps: [{ x: 1, y: 0, name: "transport-belt" }] };
      else if (method === "enqueue") data = { task_id: 92 };
      else if (method === "cancel") { requested = true; data = { cancelled: 0 }; }
      else { controller.abort(); data = requested ? { status, detail: "native progress", outcome } : { status: "running" }; }
      return JSON.stringify({ ok: true, data });
    });
    const bridge = new Bridge({ exec } as unknown as RconClient);
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, async () => bridge, validConfig);
    vi.useFakeTimers();
    try {
      const pending = handlers.connect_entities!({ kind, prototype: kind === "power" ? "small-electric-pole" : "transport-belt", from: { x: 0, y: 0 }, to: { x: 2, y: 0 } },
        { signal: controller.signal });
      await vi.advanceTimersByTimeAsync(2_000);
      const output = await pending;
      expect(output.structuredContent).toMatchObject({ status: status === "done" ? "completed" : status, task_id: 92,
        cancellation: { acknowledgement: { cancelled: 0 } }, ...outcome });
      if (kind === "power" && status === "done") expect(output.content[0].text).toContain("electrical continuity was not checked");
      expect(output.isError).toBe(status === "failed" || status === "cancelled");
      expect(exec).toHaveBeenCalledTimes(5);
    } finally { vi.useRealTimers(); }
    }
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

describe("run_plan and direct tools under a human hold", () => {
  const steps = runPlanSchema.parse({ steps: [{ action: "walk_to", x: 1, y: 2 }] });

  it("run_plan never cancels a held plan and returns it nonterminal before the tool timeout", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    const call = vi.fn(async (method: string) => method === "queue_plan" ? { plan_id: 31 }
      : method === "cancel" ? { cancelled: 1 }
      : { plan_id: 31, status: "running", outcomes: [], human_control: true, fifo: { human_control: true, human_idle_ticks: 5 } });
    const result = await executeRunPlan({ call } as unknown as Bridge, steps, undefined, clock);
    expect(result).toMatchObject({ plan_id: 31, status: "running", human_control: true,
      wait: { condition: "terminal", timed_out: true, waited_ms: DEFAULT_TASK_TIMEOUT_MS } });
    expect(result.summary).toMatch(/a human holds the body, so nothing was cancelled/);
    expect(call.mock.calls.map(([method]) => method)).not.toContain("cancel");
    expect(now).toBe(DEFAULT_TASK_TIMEOUT_MS);
  });

  it("run_plan returns a plan still running at the call limit without cancelling it: the mod owns its budget", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    // An earlier plan's sticky human_control must not count as a current hold.
    const call = vi.fn(async (method: string) => method === "queue_plan" ? { plan_id: 32 }
      : method === "cancel" ? { cancelled: 1 }
      : { plan_id: 32, status: "running", outcomes: [], human_control: true, fifo: { human_control: false } });
    const result = await executeRunPlan({ call } as unknown as Bridge, steps, undefined, clock);
    expect(result).toMatchObject({ plan_id: 32, status: "running",
      wait: { condition: "terminal", timed_out: true, waited_ms: DEFAULT_TASK_TIMEOUT_MS } });
    expect(result).not.toHaveProperty("human_control");
    expect(result.summary).toMatch(/570 s call limit; nothing was cancelled and the mod enforces the plan's own budget/);
    expect(call.mock.calls.map(([method]) => method)).not.toContain("cancel");
    expect(now).toBe(DEFAULT_TASK_TIMEOUT_MS);
  });

  it("run_plan reports the latest sample: a plan running long after a hold ended is not reported as held", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    // Held for the first 100 s (credited), then running unheld until the return guard.
    const call = vi.fn(async (method: string) => method === "queue_plan" ? { plan_id: 33 }
      : method === "cancel" ? { cancelled: 1 }
      : { plan_id: 33, status: "running", outcomes: [], human_control: true, fifo: { human_control: now < 100_000 } });
    const result = await executeRunPlan({ call } as unknown as Bridge, steps, undefined, clock);
    expect(result).toMatchObject({ plan_id: 33, status: "running",
      wait: { condition: "terminal", timed_out: true, waited_ms: DEFAULT_TASK_TIMEOUT_MS } });
    expect(result).not.toHaveProperty("human_control");
    expect(result.summary).not.toMatch(/a human holds the body/);
    expect(result.summary).toMatch(/earlier human hold delayed it; nothing was cancelled, so wait with next_event/);
    expect(call.mock.calls.map(([method]) => method)).not.toContain("cancel");
  });

  it("direct tools fail with a retry-after-hold result and cancel the task; run_plan stays nonterminal", async () => {
    const handlers: Record<string, (args: any, extra?: any) => Promise<any>> = {};
    const methods: string[] = [];
    let cancelled = false;
    const reply = (data: unknown) => JSON.stringify({ ok: true, data });
    const exec = vi.fn(async (cmd: string) => {
      const method = /"rpc","([a-z_]+)"/.exec(cmd)![1]!;
      methods.push(method);
      switch (method) {
        case "enqueue": return reply({ task_id: 41 });
        case "get_task": return reply(cancelled ? { status: "cancelled" } : { status: "running", detail: "", fifo: { human_control: true, human_idle_ticks: 2 } });
        case "cancel": cancelled = true; return reply({ cancelled: 1 });
        case "connect_entities": return reply({ kind: "belt", prototype: "transport-belt", from: { x: 0, y: 0 }, to: { x: 2, y: 0 },
          length: 1, steps: [{ x: 1, y: 0, name: "transport-belt", direction: 4 }], physical: true, ghosts: false });
        case "queue_plan": return reply({ plan_id: 51 });
        default: return reply({ plan_id: 51, status: "queued", outcomes: [], human_control: true, fifo: { human_control: true } });
      }
    });
    const bridge = new Bridge({ exec } as unknown as RconClient);
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, async () => bridge, validConfig);

    vi.useFakeTimers();
    try {
      const settle = async (pending: Promise<any>) => { await vi.advanceTimersByTimeAsync(DEFAULT_TASK_TIMEOUT_MS + 5_000); return pending; };
      for (const [name, args] of [["walk_to", { x: 1, y: 2 }],
        ["connect_entities", { kind: "belt", prototype: "transport-belt", from: { x: 0, y: 0 }, to: { x: 2, y: 0 } }]] as const) {
        methods.length = 0;
        cancelled = false;
        const out = await settle(handlers[name]!(args));
        expect(out.isError).toBe(true);
        expect(out.structuredContent).toMatchObject({ status: "cancelled", task_id: 41, terminal: true, next_action: null,
          cancellation: { acknowledgement: { cancelled: 1 } } });
        expect(out.content[0].text).toMatch(/a human holds the body: task 41 was still running after 570s and was cancelled/);
        expect(out.content[0].text).toMatch(/retry the call after the hold ends/);
        expect(methods.slice(-2)).toEqual(["cancel", "get_task"]);
      }

      methods.length = 0;
      const ran = await settle(handlers.run_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] }));
      expect(ran.isError).toBe(false);
      expect(ran.structuredContent).toMatchObject({ plan_id: 51, status: "queued", terminal: false, human_control: true,
        next_action: { tool: "next_event", arguments: { timeout_seconds: 25 } } });
      expect(ran.content[0].text).toContain("nothing was cancelled");
      expect(methods).not.toContain("cancel");
    } finally { vi.useRealTimers(); }
  });
});


describe("schema-derived plan contracts", () => {
  it("retains deep settings, offsets, equipment unions, route records and honest unconstrained values", () => {
    const contract = planContract();
    expect(contract).toContain('arrival_mode: "exact"|"vicinity" default "exact"');
    expect(contract).toContain("arrival_radius: number (>=0.5, <=6) default 1");
    expect(contract).toContain("final_observation_radius: integer (>=5, <=30) default 15");
    expect(contract).toContain('settings?: {inserter?: {filters?: [string (length >=1)] (items <=5), mode?: "whitelist"|"blacklist"');
    expect(contract).toContain("from: {dx: number, dy: number} (strict), to: {dx: number, dy: number} (strict)");
    expect(contract).toContain("take: [({name: string (length >=1)} (strict) or {x: integer (>=0, <=9007199254740991), y: integer (>=0, <=9007199254740991)} (strict))] (items >=1, items <=20)");
    expect(contract).toContain('wait?: [{type: "time"|"full"');
    expect(contract).toContain("condition?: {[key: string]: unknown (any JSON value)}");
    expect(contract).toContain("direction: integer (>=0, <=12, multiple of 4)");
    expect(contract).toContain("Additional validation (not represented by the structural JSON Schema conversion)");
    expect(contract).not.toContain("blueprint_capture");
    expect(contract).toContain("  travel: to:");
    expect(contract).not.toContain("{name: count}");
    // A plain recipe string has no name/length constraint added by the formatter.
    expect(contract).toContain("craft_items: recipe: string; crafts: integer (>=1, <=100)");
  });

  it("propagates new actions, fields and changed constraints without an action/type definition list", () => {
    const changed = planStepSchema.options[0].extend({
      arrival_radius: z.number().min(2).max(9).default(3),
      detail: z.object({ nested: z.object({ label: z.string().min(2).max(7).regex(/^ok/),
        flags: z.record(z.string().min(3), z.boolean()), open: z.looseObject({ value: z.unknown() }) }).strict() }).strict().optional(),
    });
    const added = z.object({ action: z.literal("new_action"), entries: z.array(z.string()).min(2),
      scale: z.number().gt(0).lt(5).multipleOf(0.5) }).strict();
    const lines = stepLines([changed, added]);
    expect(lines[0]).toContain("arrival_radius: number (>=2, <=9) default 3");
    expect(lines[0]).toContain("label: string (length >=2, length <=7, matching ^ok)");
    expect(lines[0]).toContain("flags: {[key: string (length >=3)]: boolean}");
    expect(lines[0]).toContain("open: {value: unknown (any JSON value), [key: string]: unknown (any JSON value)}");
    expect(lines[1]).toBe("  new_action: entries: [string] (items >=2); scale: number (>0, <5, multiple of 0.5) | optional: -");
    expect(fieldLine(z.object({ literal: z.literal(false), values: z.array(z.number()).length(2).default([1, 2]) }).strict()))
      .toBe("literal: false | optional: values: [number] (items >=2, items <=2) default [1,2]");
  });
});
