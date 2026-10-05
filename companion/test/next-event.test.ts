import { describe, expect, it, vi } from "vitest";
import type { Bridge, TaskClock } from "../src/bridge.js";
import { eventSummary, IDLE_NOW, waitForEvent, type EventState, type PackageFailure } from "../src/mcp/events.js";

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
    expect(eventSummary(event)).toBe(`plan 5 ended completed; 2 rocket/platform events in space_events; ${IDLE_NOW}`);
    // An empty Lua ring arrives as {} and is no event.
    const empty = { ...busy, last_space_event_tick: 120, space_events: {} as never };
    expect(await waitForEvent(game([empty]).bridge, { timeout_seconds: 1, since_tick: 100 }, quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "timeout" });
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

  it("reports a new problem, a human hold starting and ending, and new package failures while waiting", async () => {
    const { bridge, call } = game([busy, { ...busy, tick: 130, last_problem_tick: 120 }]);
    expect(await waitForEvent(bridge, input(), quiet(), undefined, fakeClock())).toMatchObject({ event: "new_problem", tick: 130 });
    expect(call).toHaveBeenLastCalledWith("factory_status", { sections: ["problems"], since_tick: 100 });
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
