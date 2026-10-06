import { describe, expect, it, vi } from "vitest";
import type { Bridge, TaskClock } from "../src/bridge.js";
import { eventSummary, IDLE_NOW, RESEARCH_IDLE, waitForEvent, type EventState, type PackageFailure } from "../src/mcp/events.js";
import { registerMcpTools, type McpSurface } from "../src/mcp/server.js";

const idle: EventState = { tick: 100, queue_depth: 0, fifo_empty: true, human_hold: false };
const busy: EventState = { tick: 100, queue_depth: 1, fifo_empty: false, human_hold: false, active_plan_id: 5,
  last_plan_ended: { plan_id: 4, status: "completed", tick: 90 } };

/** Plays event_state samples in order (the last repeats); factory_status answers problems, plan_status the ended plan. */
function game(samples: EventState[]) {
  let index = 0;
  const call = vi.fn(async (method: string, params?: any) => {
    if (method === "factory_status") return { tick: 1, problems: [{ status: "no_fuel", name: "stone-furnace", position: { x: 1, y: 2 } }] };
    if (method === "plan_status") return { plan_id: params.plan_id, status: "completed", source: "pilot",
      outcomes: [{ step: 1, action: "get_items", status: "completed", result: { supplied: { "iron-plate": 10 } } }],
      inventory_delta: { "iron-plate": 10 } };
    return samples[Math.min(index++, samples.length - 1)];
  });
  return { call, bridge: { call } as unknown as Bridge };
}
function fakeClock(): TaskClock & { slept: number } {
  let now = 0;
  return { slept: 0, now: () => now, async sleep(ms) { now += ms; this.slept += ms; } };
}
const quiet = (failures: PackageFailure[] = [], orders = false) => ({ ordersChanged: () => orders, packageFailures: () => failures });
const input = (extra: { since_tick?: number } = {}) => ({ timeout_seconds: 60, ...extra });

describe.each(["full", "read-only"] as McpSurface[])("next_event MCP readback (%s)", (surface) => {
  function handler(bridge: Bridge) {
    const handlers: Record<string, (args: any, extra?: any) => Promise<any>> = {};
    registerMcpTools({ registerTool(name, _config, run) { handlers[name] = run; } }, async () => bridge,
      () => ({ ok: false, error: "offline fixture" }), surface, () => null, surface === "full" ? "pilot" : "strategist");
    return handlers.next_event!;
  }

  it.each(["completed", "partial", "failed", "cancelled"])("retains native %s plan outcome separately from read completion", async (status) => {
    const outcomes = [{ step: 1, action: "insert_items", status: status === "completed" ? "completed" : "failed",
      result: { inserted: { coal: 2 } }, error: status === "completed" ? undefined : "PATH_NOT_FOUND" }];
    const call = vi.fn(async (method: string) => method === "event_state"
      ? { ...busy, last_plan_ended: { plan_id: 4, status, tick: 95, surface: "nauvis" } }
      : { source: "package:fixture", status, outcomes, inventory_delta: { coal: -2 } });
    const value = await handler({ call } as unknown as Bridge)({ timeout_seconds: 1, since_tick: 90 });
    expect(value.isError).not.toBe(true);
    expect(value.structuredContent).toMatchObject({ event: "plan_ended", plan_id: 4, status, read_status: "completed",
      source: "package:fixture", surface: "nauvis", outcomes, inventory_delta: { coal: -2 }, terminal: true, next_action: null });
    expect(value.content[0].text).toContain(`plan 4 ended ${status}`);
    expect(call.mock.calls.map(([method]) => method)).toEqual(["event_state", "plan_status"]);
  });

  it("retains native failure when detailed outcomes are unavailable", async () => {
    const call = vi.fn(async (method: string) => {
      if (method === "plan_status") throw new Error("unknown plan_id");
      return { ...busy, last_plan_ended: { plan_id: 4, status: "failed", tick: 95 } };
    });
    const value = await handler({ call } as unknown as Bridge)({ timeout_seconds: 1, since_tick: 90 });
    expect(value.structuredContent).toMatchObject({ event: "plan_ended", status: "failed", read_status: "completed" });
    expect(value.structuredContent).not.toHaveProperty("outcomes");
    expect(value.isError).not.toBe(true);
  });

  it("distinguishes a non-plan read and a read error without inventing a plan outcome", async () => {
    const value = await handler(game([idle]).bridge)({ timeout_seconds: 1 });
    expect(value.structuredContent).toMatchObject({ event: "queue_empty", status: "completed", read_status: "completed" });
    expect(value.structuredContent).not.toHaveProperty("plan_id");
    const failed = await handler({ call: async () => { throw new Error("read failed"); } } as unknown as Bridge)({ timeout_seconds: 1 });
    expect(failed.isError).toBe(true);
    expect(failed.structuredContent).toMatchObject({ status: "failed", read_status: "failed", code: "TOOL_ERROR" });
    expect(failed.structuredContent).not.toHaveProperty("event");
    expect(failed.structuredContent).not.toHaveProperty("outcomes");
  });

  it("reports wait cancellation without cancelling physical plans", async () => {
    const controller = new AbortController(); controller.abort();
    const { bridge, call } = game([busy]);
    const value = await handler(bridge)({ timeout_seconds: 1 }, { signal: controller.signal });
    expect(value.structuredContent).toMatchObject({ event: "cancelled", status: "cancelled", read_status: "cancelled" });
    expect(value.structuredContent).not.toHaveProperty("plan_id");
    expect(call.mock.calls.map(([method]) => method)).toEqual(["event_state"]);
  });
});

describe("next_event package failures", () => {
  it("delivers a failure recorded after the session saw a later tick, once", async () => {
    const failures: PackageFailure[] = [];
    const delivery = { keys: null as Set<string> | null };
    const sources = { ordersChanged: () => false, packageFailures: () => failures, delivery };
    const ended = { ...idle, tick: 160, last_plan_ended: { plan_id: 5, status: "completed", tick: 150 } };
    // Call 1 returns the plan end at tick 160 before the bridge writes the failure.
    expect(await waitForEvent(game([busy, ended]).bridge, input(), sources, undefined, fakeClock()))
      .toMatchObject({ event: "plan_ended", tick: 160 });
    // The bridge then records it stamped with its pass's earlier ping tick.
    failures.push({ package_id: "p2", reason: "check failed: blocked", tick: 120, at: "2026-10-04T00:00:01Z" });
    const next = await waitForEvent(game([{ ...ended, fifo_empty: false, queue_depth: 1 }]).bridge, input({ since_tick: 160 }), sources,
      undefined, fakeClock());
    expect(next).toMatchObject({ event: "package_failed", package_id: "p2", reason: "check failed: blocked" });
    expect(next).not.toHaveProperty("at");
    const clock = fakeClock();
    expect(await waitForEvent(game([{ ...ended, fifo_empty: false, queue_depth: 1 }]).bridge,
      { timeout_seconds: 2, since_tick: 160 }, sources, undefined, clock)).toMatchObject({ event: "timeout" });
    // The same package failing again (re-queued after a rollback) is a new record.
    failures[0] = { ...failures[0]!, at: "2026-10-04T00:05:00Z", tick: 50 };
    expect(await waitForEvent(game([{ ...ended, fifo_empty: false, queue_depth: 1 }]).bridge, input({ since_tick: 160 }), sources,
      undefined, fakeClock())).toMatchObject({ event: "package_failed", package_id: "p2" });
  });
});

describe("next_event research beside a plan end", () => {
  it("carries a research that finished in the same poll as a plan end, which a later since_tick call would miss", async () => {
    const both = { ...idle, tick: 170, last_plan_ended: { plan_id: 5, status: "completed", tick: 160 },
      last_research_finished: { technology: "automation", tick: 150 } };
    const polled = await waitForEvent(game([busy, both]).bridge, input(), quiet(), undefined, fakeClock());
    expect(polled).toMatchObject({ event: "plan_ended", plan_id: 5, research_finished: { technology: "automation", research_tick: 150 } });
    expect(eventSummary(polled)).toBe(`plan 5 ended completed; research automation finished; ${IDLE_NOW}`);
    const since = await waitForEvent(game([both]).bridge, input({ since_tick: 140 }), quiet(), undefined, fakeClock());
    expect(since).toMatchObject({ event: "plan_ended", research_finished: { technology: "automation", research_tick: 150 } });
    const older = await waitForEvent(game([both]).bridge, input({ since_tick: 155 }), quiet(), undefined, fakeClock());
    expect(older).toMatchObject({ event: "plan_ended" });
    expect(older).not.toHaveProperty("research_finished");
  });

  it("says plainly when a finished research leaves no research running and the labs idle", async () => {
    const stalled = { ...idle, tick: 170, last_plan_ended: { plan_id: 5, status: "completed", tick: 160 },
      last_research_finished: { technology: "automation", tick: 150 }, research_idle: true };
    const polled = await waitForEvent(game([busy, stalled]).bridge, input(), quiet(), undefined, fakeClock());
    expect(polled).toMatchObject({ research_finished: { technology: "automation", research_idle: true } });
    expect(eventSummary(polled)).toBe(`plan 5 ended completed; research automation finished: ${RESEARCH_IDLE}; ${IDLE_NOW}`);
    const running = { ...busy, tick: 300, last_research_finished: { technology: "automation", tick: 290 }, research_idle: false };
    const next = await waitForEvent(game([busy, running]).bridge, input(), quiet(), undefined, fakeClock());
    expect(next).not.toHaveProperty("research_idle");
    expect(eventSummary(next)).toBe("research automation finished");
    const finished = await waitForEvent(game([busy, { ...running, research_idle: true }]).bridge, input(), quiet(), undefined, fakeClock());
    expect(finished).toMatchObject({ event: "research_finished", technology: "automation", research_idle: true });
    expect(eventSummary(finished)).toBe(`research automation finished: ${RESEARCH_IDLE}`);
    expect(RESEARCH_IDLE).toBe("no research is running and labs are idle; the ledger writer picks research in the ledger");
  });

  it("says plainly that labs are idle when a new problem is a research_idle one", () => {
    expect(eventSummary({ event: "new_problem", problems: [{ status: "no_research_in_progress", cause: "research_idle", name: "lab" }] }))
      .toBe(`new machine problem (1 rows); ${RESEARCH_IDLE}`);
    expect(eventSummary({ event: "new_problem", problems: [{ status: "no_fuel", name: "stone-furnace" }] }))
      .toBe("new machine problem (1 rows)");
  });
});

describe("next_event rocket and platform events", () => {
  const launched = { tick: 210, kind: "rocket_launched" as const, silo: { x: 10.5, y: 10.5 }, platform: { index: 3, name: "Orbit" } };
  const landed = { tick: 230, kind: "cargo_delivered" as const, platform: { index: 3, name: "Orbit" } };
  const ready = { tick: 120, kind: "rocket_ready" as const, silo: { x: 10.5, y: 10.5 } };

  it("fires on a new space event during the wait, never on one from before the call", async () => {
    const before = { ...busy, last_space_event_tick: 120, space_events: [ready] };
    const after = { ...before, tick: 220, last_space_event_tick: 210, space_events: [ready, launched] };
    const event = await waitForEvent(game([before, before, after]).bridge, input(), quiet(), undefined, fakeClock());
    expect(event).toMatchObject({ event: "rocket_launched", event_tick: 210, silo: { x: 10.5, y: 10.5 }, platform: { index: 3, name: "Orbit" }, tick: 220 });
    expect(event).not.toHaveProperty("space_events");
    expect(eventSummary(event)).toBe("a rocket was launched from (10.5, 10.5) to platform Orbit");
    const clock = fakeClock();
    expect(await waitForEvent(game([before]).bridge, { timeout_seconds: 2 }, quiet(), undefined, clock)).toMatchObject({ event: "timeout" });
  });

  it("returns an event after since_tick at once, oldest first, with the later ones alongside", async () => {
    const state = { ...busy, tick: 240, last_space_event_tick: 230, space_events: [ready, launched, landed] };
    const event = await waitForEvent(game([state]).bridge, input({ since_tick: 200 }), quiet(), undefined, fakeClock());
    expect(event).toMatchObject({ event: "rocket_launched", event_tick: 210, space_events: [launched, landed] });
    const last = await waitForEvent(game([state]).bridge, input({ since_tick: 215 }), quiet(), undefined, fakeClock());
    expect(last).toMatchObject({ event: "cargo_delivered", platform: { name: "Orbit" } });
    expect(eventSummary(last)).toBe("a cargo pod landed on platform Orbit");
    const changed = { tick: 250, kind: "platform_state_changed" as const, platform: { index: 3, name: "Orbit" },
      old: "starter_pack_on_the_way", new: "waiting_at_station" };
    expect(eventSummary(await waitForEvent(game([{ ...state, space_events: [changed] }]).bridge, input({ since_tick: 245 }), quiet(),
      undefined, fakeClock()))).toBe("platform Orbit: starter_pack_on_the_way -> waiting_at_station");
    expect(eventSummary({ event: "cargo_delivered", surface: "nauvis" })).toBe("a cargo pod landed on nauvis");
    expect(eventSummary({ event: "rocket_ready", silo: { x: 1.5, y: 2.5 } })).toBe("a rocket is ready in the silo at (1.5, 2.5)");
  });

  it("carries space events that arrive with a plan end, which the next since_tick call would miss", async () => {
    const ended = { ...idle, tick: 240, last_plan_ended: { plan_id: 5, status: "completed", tick: 235 },
      last_space_event_tick: 230, space_events: [launched, landed] };
    const event = await waitForEvent(game([busy, ended]).bridge, input(), quiet(), undefined, fakeClock());
    expect(event).toMatchObject({ event: "plan_ended", plan_id: 5, space_events: [launched, landed] });
    expect(eventSummary(event)).toBe(`plan 5 ended completed; 2 rocket, platform or travel events in space_events; ${IDLE_NOW}`);
    // An empty Lua ring arrives as {} and is no event.
    const empty = { ...busy, last_space_event_tick: 120, space_events: {} as never };
    expect(await waitForEvent(game([empty]).bridge, { timeout_seconds: 1, since_tick: 100 }, quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "timeout" });
  });

  it("reports a trip: travel phases, a platform's arrival and the body's move to another surface", async () => {
    const phase = { tick: 300, kind: "travel_phase" as const, phase: "wait_arrival", from: "nauvis", to: "vulcanus" };
    const arrived = { tick: 9000, kind: "platform_arrived" as const, platform: { index: 3, name: "Orbit" }, location: "vulcanus" };
    const moved = { tick: 9400, kind: "body_surface_changed" as const, from: "platform:3", to: "vulcanus", state: "on_surface" };
    const before = { ...busy, last_space_event_tick: 300, space_events: [phase] };
    const after = { ...before, tick: 9010, last_space_event_tick: 9000, space_events: [phase, arrived] };
    const event = await waitForEvent(game([before, after]).bridge, input(), quiet(), undefined, fakeClock());
    expect(event).toMatchObject({ event: "platform_arrived", event_tick: 9000, location: "vulcanus", platform: { name: "Orbit" } });
    expect(eventSummary(event)).toBe("platform Orbit arrived at vulcanus");
    const landed = { ...after, tick: 9410, last_space_event_tick: 9400, space_events: [phase, arrived, moved] };
    const move = await waitForEvent(game([landed]).bridge, input({ since_tick: 9005 }), quiet(), undefined, fakeClock());
    expect(move).toMatchObject({ event: "body_surface_changed", from: "platform:3", to: "vulcanus", state: "on_surface" });
    expect(eventSummary(move)).toBe("the body moved from platform:3 to vulcanus (on_surface)");
    expect(eventSummary(await waitForEvent(game([landed]).bridge, input({ since_tick: 200 }), quiet(), undefined, fakeClock())))
      .toBe("travel to vulcanus: wait_arrival");
    // A plan that ends names the surface its positions were on.
    const cancelled = { ...idle, tick: 9420, last_plan_ended: { plan_id: 8, status: "cancelled", tick: 9401, surface: "nauvis" } };
    expect(await waitForEvent(game([cancelled]).bridge, input({ since_tick: 9400 }), quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "plan_ended", plan_id: 8, status: "cancelled", surface: "nauvis" });
  });
});

describe("next_event", () => {
  it("returns queue_empty at once for an idle body, but waits when since_tick says it was already idle", async () => {
    expect(await waitForEvent(game([idle]).bridge, input(), quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "queue_empty", tick: 100, body: { active_plan_id: null, queue_depth: 0, fifo_empty: true, human_hold: false } });
    const clock = fakeClock();
    expect(await waitForEvent(game([idle]).bridge, { timeout_seconds: 5, since_tick: 100 }, quiet(), undefined, clock))
      .toMatchObject({ event: "timeout", waited_seconds: 5 });
    expect(clock.slept).toBe(5_000);
  });

  it("tells the pilot to queue work when the last plan ends with the FIFO empty, and not during a human hold", async () => {
    const ended = { ...idle, tick: 160, last_plan_ended: { plan_id: 5, status: "completed", tick: 150 } };
    const last = await waitForEvent(game([busy, ended]).bridge, input(), quiet(), undefined, fakeClock());
    expect(last).toMatchObject({ event: "plan_ended", body: { fifo_empty: true } });
    expect(eventSummary(last)).toBe(`plan 5 ended completed; ${IDLE_NOW}`);
    const more = await waitForEvent(game([busy, { ...ended, queue_depth: 1, fifo_empty: false }]).bridge, input(), quiet(), undefined, fakeClock());
    expect(eventSummary(more)).toBe("plan 5 ended completed");
    const timeout = await waitForEvent(game([idle]).bridge, { timeout_seconds: 5, since_tick: 100 }, quiet(), undefined, fakeClock());
    expect(eventSummary(timeout)).toBe(`nothing happened in 5 s; ${IDLE_NOW}`);
    expect(eventSummary({ event: "queue_empty", body: { fifo_empty: true, human_hold: false } })).toBe(IDLE_NOW);
    expect(eventSummary({ event: "timeout", waited_seconds: 5, body: { fifo_empty: true, human_hold: true } })).toBe("nothing happened in 5 s");
  });

  it("reports the plan that ended while it waited, polling about every 500 ms", async () => {
    const ended = { ...idle, tick: 160, last_plan_ended: { plan_id: 5, status: "partial", tick: 150 } };
    const { bridge, call } = game([busy, busy, ended]);
    const clock = fakeClock();
    // The event carries the plan's outcomes, so no follow-up read is needed.
    expect(await waitForEvent(bridge, input(), quiet(), undefined, clock)).toMatchObject({ event: "plan_ended", plan_id: 5, status: "partial", tick: 160,
      source: "pilot", outcomes: [{ step: 1, action: "get_items", status: "completed" }], inventory_delta: { "iron-plate": 10 } });
    expect(clock.slept).toBe(1_000);
    expect(call.mock.calls.map(([method]) => method)).toEqual(["event_state", "event_state", "event_state", "plan_status"]);
    expect(call).toHaveBeenLastCalledWith("plan_status", { plan_id: 5 });
  });

  it("still reports a plan end when its outcomes cannot be read, with empty Lua tables as records", async () => {
    const ended = { ...idle, tick: 160, last_plan_ended: { plan_id: 6, status: "completed", tick: 150 } };
    let samples = 0;
    const failing = { call: vi.fn(async (method: string) => {
      if (method === "plan_status") throw new Error("unknown plan_id: 6");
      return samples++ === 0 ? busy : ended;
    }) } as unknown as Bridge;
    const value = await waitForEvent(failing, input(), quiet(), undefined, fakeClock());
    expect(value).toMatchObject({ event: "plan_ended", plan_id: 6, status: "completed" });
    expect(value).not.toHaveProperty("outcomes");
    const empty = { call: vi.fn(async (method: string) => method === "plan_status" ? { outcomes: {}, inventory_delta: [] } : ended) } as unknown as Bridge;
    expect(await waitForEvent(empty, input({ since_tick: 140 }), quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "plan_ended", outcomes: [], inventory_delta: {} });
  });

  it("reports a finished research while it waits, and at once after since_tick", async () => {
    const researched = { ...busy, tick: 300, last_research_finished: { technology: "automation", tick: 290 } };
    const value = await waitForEvent(game([busy, researched]).bridge, input(), quiet(), undefined, fakeClock());
    expect(value).toMatchObject({ event: "research_finished", technology: "automation", research_tick: 290, tick: 300 });
    expect(eventSummary(value)).toBe("research automation finished");
    expect(await waitForEvent(game([researched]).bridge, input({ since_tick: 280 }), quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "research_finished", technology: "automation" });
    // A research finished before since_tick is history, and one already seen at the start is not new.
    const clock = fakeClock();
    expect(await waitForEvent(game([researched]).bridge, { timeout_seconds: 2, since_tick: 295 }, quiet(), undefined, clock))
      .toMatchObject({ event: "timeout" });
  });

  it("returns at once for a plan end or problem after since_tick", async () => {
    expect(await waitForEvent(game([{ ...busy, last_plan_ended: { plan_id: 4, status: "failed", tick: 95 } }]).bridge,
      input({ since_tick: 80 }), quiet(), undefined, fakeClock())).toMatchObject({ event: "plan_ended", plan_id: 4, status: "failed" });
    const problem = await waitForEvent(game([{ ...busy, last_problem_tick: 99 }]).bridge, input({ since_tick: 95 }), quiet(), undefined, fakeClock());
    expect(problem).toMatchObject({ event: "new_problem", problems: [{ status: "no_fuel", name: "stone-furnace" }] });
  });

  it("names problems on other surfaces when the body's surface has none new", async () => {
    let index = 0;
    const samples = [busy, { ...busy, tick: 130, last_problem_tick: 120 }];
    const call = vi.fn(async (method: string) => {
      if (method === "factory_status") return { tick: 130, problems: {}, elsewhere: [
        { surface: "nauvis", problems: 2, top_problems: [{ status: "no_fuel", name: "stone-furnace", position: { x: 1, y: 2 }, count: 2 }] },
        { surface: "platform:1", problems: 0, top_problems: {} }] };
      return samples[Math.min(index++, samples.length - 1)];
    });
    const event = await waitForEvent({ call } as unknown as Bridge, input(), quiet(), undefined, fakeClock());
    expect(event).toMatchObject({ event: "new_problem",
      problems: [{ status: "no_fuel", name: "stone-furnace", count: 2, surface: "nauvis" }] });
    expect((event as any).problems).toHaveLength(1);
  });

  it("reports a new problem, a human hold starting and ending, and new package failures while waiting", async () => {
    const { bridge, call } = game([busy, { ...busy, tick: 130, last_problem_tick: 120 }]);
    expect(await waitForEvent(bridge, input(), quiet(), undefined, fakeClock())).toMatchObject({ event: "new_problem", tick: 130 });
    expect(call).toHaveBeenLastCalledWith("factory_status", { sections: ["problems", "elsewhere"], since_tick: 100 });
    expect(await waitForEvent(game([busy, { ...busy, human_hold: true }]).bridge, input(), quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "human_hold_started", body: { human_hold: true } });
    // A hold at the start is not idleness; its end is the event.
    const held = { ...idle, human_hold: true };
    expect(await waitForEvent(game([held, held, idle]).bridge, input(), quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "human_hold_ended" });
    const failures: PackageFailure[] = [{ package_id: "old", reason: "x" }];
    const sources = { ordersChanged: () => false, packageFailures: () => failures };
    const waiting = waitForEvent(game([busy]).bridge, input(), sources, undefined,
      { now: () => 0, sleep: async () => { failures.push({ package_id: "new", reason: "check failed: blocked" }); } });
    expect(await waiting).toMatchObject({ event: "package_failed", package_id: "new", reason: "check failed: blocked" });
  });

  it("returns orders_changed while unseen orders wait, and stops on abort", async () => {
    expect(await waitForEvent(game([busy]).bridge, input(), quiet([], true), undefined, fakeClock())).toMatchObject({ event: "orders_changed" });
    const controller = new AbortController();
    const clock = fakeClock();
    const aborting = { now: clock.now, sleep: async (ms: number) => { await clock.sleep(ms); controller.abort(); } };
    expect(await waitForEvent(game([busy]).bridge, input(), quiet(), controller.signal, aborting)).toMatchObject({ event: "cancelled" });
  });
});
