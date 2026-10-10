import { describe, expect, it, vi } from "vitest";
import type { Bridge, TaskClock } from "../src/bridge.js";
import { ModError } from "../src/bridge.js";
import { eventSummary, feedText, IDLE_FACT, IDLE_NOW, nextEventSchema, RESEARCH_IDLE, waitForEvent, watchText, type EventState, type PackageFailure, type PackageVerificationEvent, type WatchFiring } from "../src/mcp/events.js";
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
const input = (extra: { since_tick?: number } = {}) => ({ timeout_seconds: 25, ...extra });

describe("next_event timeout bound", () => {
  it("defaults to and caps at 25 s, under the 31 s code-mode exec yield", () => {
    expect(nextEventSchema.parse({})).toEqual({ timeout_seconds: 25 });
    expect(nextEventSchema.safeParse({ timeout_seconds: 25 }).success).toBe(true);
    expect(nextEventSchema.safeParse({ timeout_seconds: 26 }).success).toBe(false);
    expect(nextEventSchema.safeParse({ timeout_seconds: 60 }).success).toBe(false);
  });
});

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

  it("carries the plan's walk_s, tiles and craft_wait_s when the mod reports them", async () => {
    const call = vi.fn(async (method: string) => method === "event_state"
      ? { ...busy, last_plan_ended: { plan_id: 4, status: "completed", tick: 95 } }
      : { source: "pilot", status: "completed", outcomes: [], inventory_delta: {}, walk_s: 41.5, tiles: 369.4, craft_wait_s: 12 });
    const value = await handler({ call } as unknown as Bridge)({ timeout_seconds: 1, since_tick: 90 });
    expect(value.structuredContent).toMatchObject({ event: "plan_ended", walk_s: 41.5, tiles: 369.4, craft_wait_s: 12 });
    const bare = vi.fn(async (method: string) => method === "event_state"
      ? { ...busy, last_plan_ended: { plan_id: 4, status: "completed", tick: 95 } }
      : { source: "pilot", status: "completed", outcomes: [], inventory_delta: {} });
    const without = await handler({ call: bare } as unknown as Bridge)({ timeout_seconds: 1, since_tick: 90 });
    expect(without.structuredContent).not.toHaveProperty("walk_s");
    expect(without.structuredContent).not.toHaveProperty("craft_wait_s");
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
    // A message that leads with the mod's code keeps it.
    const coded = await handler({ call: async () => { throw new ModError("JOB_LIMIT: too many jobs"); } } as unknown as Bridge)({ timeout_seconds: 1 });
    expect(coded.structuredContent).toMatchObject({ status: "failed", code: "JOB_LIMIT", summary: "Error: JOB_LIMIT: too many jobs" });
    const plain = await handler({ call: async () => { throw new Error("Lua: bad thing: X_Y: not a leading code"); } } as unknown as Bridge)({ timeout_seconds: 1 });
    expect(plain.structuredContent).toMatchObject({ code: "TOOL_ERROR" });
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

describe("next_event package verify outcomes", () => {
  it("delivers package_verified and package_unmet once each, with the measured values in the summary", async () => {
    const verifications: PackageVerificationEvent[] = [];
    const delivery = { keys: null as Set<string> | null };
    const sources = { ordersChanged: () => false, packageFailures: () => [], packageVerifications: () => verifications, delivery };
    const working = { ...idle, fifo_empty: false, queue_depth: 1 };
    expect(await waitForEvent(game([working]).bridge, { timeout_seconds: 1 }, sources, undefined, fakeClock()))
      .toMatchObject({ event: "timeout" });
    verifications.push({ event: "package_unmet", package_id: "smelt", plan_status: "completed", tick: 7400, at: "2026-10-08T00:00:01Z",
      metrics: [{ item: "iron-plate", per_min_at_least: 30, measured: { per_min: 12 }, met: false },
        { line_at: { x: 1.5, y: 2.5 }, state: "running", measured: { line_id: 4, state: "starved", cause: "iron-ore", rate_per_min: 12 }, met: false }] });
    const unmet = await waitForEvent(game([working]).bridge, input(), sources, undefined, fakeClock());
    expect(unmet).toMatchObject({ event: "package_unmet", package_id: "smelt", plan_status: "completed", measured_tick: 7400 });
    expect(unmet).not.toHaveProperty("at");
    expect(eventSummary(unmet)).toBe("package smelt unmet: iron-plate at least 30/min: 12/min (not met); "
      + "line at (1.5, 2.5) running: line 4 starved (iron-ore), 12/min (not met)");
    // The next outcome follows; neither is delivered again.
    verifications.push({ event: "package_verified", package_id: "smelt-b", tick: 7500, at: "2026-10-08T00:00:02Z",
      metrics: [{ item: "iron-plate", per_min_at_least: 30, measured: { per_min: 31 }, met: true }] });
    const verified = await waitForEvent(game([working]).bridge, input(), sources, undefined, fakeClock());
    expect(eventSummary(verified)).toBe("package smelt-b verified: iron-plate at least 30/min: 31/min (met)");
    expect(await waitForEvent(game([working]).bridge, { timeout_seconds: 1 }, sources, undefined, fakeClock()))
      .toMatchObject({ event: "timeout" });
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

  it("states a new problem's feed facts in words, never advice", async () => {
    const boiler = { status: "no_fuel", name: "boiler", position: { x: 0, y: 0 }, count: 1, feed: { class: "foreign_item",
      missing: "fuel", feeders: 1, inserters: [{ position: { x: 0, y: 2 }, status: "waiting_for_source_items",
        from: "transport-belt", from_position: { x: 0, y: 3 }, lanes: [["copper-ore"], {}] }] } };
    let index = 0;
    const samples = [busy, { ...busy, tick: 130, last_problem_tick: 120 }];
    const call = vi.fn(async (method: string) => method === "factory_status" ? { tick: 130, problems: [boiler] }
      : samples[Math.min(index++, samples.length - 1)]);
    const event = await waitForEvent({ call } as unknown as Bridge, input(), quiet(), undefined, fakeClock());
    expect((event as any).problems[0].feed.inserters[0].lanes).toEqual([["copper-ore"], []]);
    expect(eventSummary(event)).toBe("new machine problem (1 rows); boiler (0, 0) no_fuel: its inserter at (0, 2) picks from "
      + "a transport-belt at (0, 3) carrying copper-ore only, which boiler does not take");
    const row = (feed: object) => ({ status: "no_fuel", name: "boiler", position: { x: 5, y: 5 }, feed });
    const inserter = { position: { x: 5, y: 7 }, status: "working", holding: "iron-ore", from: "wooden-chest",
      from_position: { x: 5, y: 8 }, items: ["iron-ore"] };
    expect(eventSummary({ event: "new_problem", problems: [row({ feeders: 0, missing: "fuel" }),
      row({ class: "source_empty", missing: "fuel", feeders: 2, inserters: [{ ...inserter, holding: undefined, items: [] }] }),
      row({ class: "inserter_bound", missing: "iron-ore", feeders: 1, inserters: [inserter] })] }))
      .toBe("new machine problem (3 rows); boiler (5, 5) no_fuel: no inserter drops into it; boiler (5, 5) no_fuel: one of its 2 "
        + "inserters, at (5, 7), picks from a wooden-chest at (5, 8) holding nothing; no fuel it burns there");
    const bound = eventSummary({ event: "new_problem", problems: [row({ class: "inserter_bound", missing: "iron-ore", feeders: 1,
      inserters: [inserter] })] });
    expect(bound).toBe("new machine problem (1 rows); boiler (5, 5) no_fuel: iron-ore is at the pickup of its inserter at (5, 7) "
      + "(a wooden-chest at (5, 8) holding iron-ore), which is working, holding iron-ore");
    expect(bound).not.toMatch(/\b(add|move|should|filter|split|replace)\b/);
    // What the deciding inserter holds is stated with every class.
    const furnace = { status: "no_fuel", name: "stone-furnace", position: { x: 1, y: 1 } };
    const stuck = { position: { x: 1, y: 3 }, status: "waiting_for_source_items", holding: "coal", from: "transport-belt",
      from_position: { x: 1, y: 4 }, lanes: [["coal"], []] };
    expect(feedText({ ...furnace, feed: { class: "source_empty", missing: "iron-ore", feeders: 1, inserters: [stuck] } }))
      .toBe("stone-furnace (1, 1) no_fuel: its inserter at (1, 3) picks from a transport-belt at (1, 4) carrying coal; "
        + "no iron-ore there; that inserter holds coal");
    expect(feedText({ ...furnace, feed: { class: "foreign_item", missing: "iron-ore", feeders: 1,
      inserters: [{ ...stuck, holding: "copper-plate", lanes: [["copper-plate"], []] }] } }))
      .toBe("stone-furnace (1, 1) no_fuel: its inserter at (1, 3) picks from a transport-belt at (1, 4) carrying copper-plate "
        + "only, which stone-furnace does not take; that inserter holds copper-plate");
    // A pickup whose contents were not read gives no class and says so.
    expect(feedText({ ...furnace, feed: { missing: "fuel", feeders: 1, inserters: [{ ...stuck, lanes: undefined }] } }))
      .toBe("stone-furnace (1, 1) no_fuel: its inserter at (1, 3) picks from a transport-belt at (1, 4) whose contents "
        + "were not read (waiting_for_source_items, holding coal)");
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

  it("tells a launch order from the launch itself", async () => {
    const ordered = { tick: 200, kind: "rocket_launch_ordered" as const, silo: { x: 10.5, y: 10.5 }, platform: { index: 3, name: "Orbit" } };
    const left = { tick: 1_400, kind: "rocket_launched" as const };
    const state = { ...busy, tick: 1_500, last_space_event_tick: 1_400, space_events: [ordered, left] };
    const first = await waitForEvent(game([state]).bridge, input({ since_tick: 150 }), quiet(), undefined, fakeClock());
    expect(first).toMatchObject({ event: "rocket_launch_ordered", event_tick: 200, space_events: [ordered, left] });
    expect(eventSummary(first)).toBe("a rocket launch was ordered at the silo at (10.5, 10.5) to platform Orbit");
    const second = await waitForEvent(game([state]).bridge, input({ since_tick: 300 }), quiet(), undefined, fakeClock());
    expect(second).toMatchObject({ event: "rocket_launched", event_tick: 1_400 });
    expect(eventSummary(second)).toBe("a rocket was launched");
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

describe("next_event after a queued plan", () => {
  it("follows queue_plan, travel and plan_status with a since_tick that still reports a plan that ended before the wait", async () => {
    // Plan 1 is queued at tick 2733 and fails in that tick; the wait starts with the FIFO already empty.
    const failed: EventState = { ...idle, tick: 2951, last_plan_ended: { plan_id: 1, status: "failed", tick: 2733 } };
    const call = vi.fn(async (method: string) => {
      if (method === "queue_plan" || method === "travel") return { plan_id: 1, body_idle_ticks: 0, tick: 2733 };
      if (method === "plan_status") return { plan_id: 1, status: "running", source_tick: 2733, outcomes: [] };
      return failed;
    });
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    registerMcpTools({ registerTool(name, _config, run) { handlers[name] = run; } }, async () => ({ call } as unknown as Bridge),
      () => ({ ok: false, error: "offline fixture" }), "full", () => null, "pilot");
    for (const [tool, args] of [["queue_plan", { steps: [{ action: "walk_to", x: 1, y: 2 }] }], ["travel", { to: "vulcanus" }],
      ["plan_status", { plan_id: 1 }]] as const) {
      const next = (await handlers[tool]!(args)).structuredContent.next_action;
      expect(next).toEqual({ tool: "next_event", arguments: { timeout_seconds: 25, since_tick: 2732 } });
      expect((await handlers.next_event!(next.arguments)).structuredContent).toMatchObject({ event: "plan_ended", plan_id: 1, status: "failed" });
    }
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

  it("says on queue_empty that upkeep is off after an emergency stop until a plan finishes", async () => {
    const stopped = await waitForEvent(game([{ ...idle, upkeep_off_since_tick: 90 }]).bridge, input(), quiet(), undefined, fakeClock());
    expect(stopped).toMatchObject({ event: "queue_empty", upkeep_off_since_tick: 90 });
    expect(eventSummary(stopped)).toBe(`${IDLE_NOW}; upkeep off since stop at tick 90 until a plan finishes`);
    const on = await waitForEvent(game([idle]).bridge, input(), quiet(), undefined, fakeClock());
    expect(on).not.toHaveProperty("upkeep_off_since_tick");
    expect(eventSummary(on)).toBe(IDLE_NOW);
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
    // A role that only reads gets the fact without the cue; the supervisor keeps the pilot's words.
    expect(eventSummary(last, "strategist")).toBe(`plan 5 ended completed; ${IDLE_FACT}`);
    expect(eventSummary(timeout, "advisor")).toBe(`nothing happened in 5 s; ${IDLE_FACT}`);
    expect(eventSummary({ event: "queue_empty", upkeep_off_since_tick: 90, body: { fifo_empty: true } }, "strategist"))
      .toBe(`${IDLE_FACT}; upkeep off since stop at tick 90 until a plan finishes`);
    expect(eventSummary(last, "supervisor")).toBe(`plan 5 ended completed; ${IDLE_NOW}`);
    expect(IDLE_FACT).not.toMatch(/queue/);
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

describe("next_event watch firings", () => {
  const plates: WatchFiring = { id: 3, tick: 120, surface: "nauvis", value: 42.5,
    condition: { kind: "rate_below", item: "iron-plate", per_min: 60 } };
  const water: WatchFiring = { id: 4, tick: 120, surface: "nauvis", value: 1300, produced_per_min: 1200,
    condition: { kind: "consumption_above_production", item: "water" } };
  const sources = (role?: string) => ({ ...quiet(), ...(role ? { role } : {}) });

  it("asks event_state for the role's firings after since_tick and returns them at once", async () => {
    const { bridge, call } = game([{ ...busy, tick: 130, watch_fired: [plates, water] }]);
    const value = await waitForEvent(bridge, input({ since_tick: 110 }), sources("strategist"), undefined, fakeClock());
    expect(call).toHaveBeenCalledWith("event_state", { role: "strategist", watch_since: 110 });
    expect(value).toMatchObject({ event: "watch_fired", tick: 130, watches: [plates, water] });
    expect(eventSummary(value)).toBe("2 watches fired: watch 3: iron-plate made 42.5/min on nauvis, below 60/min; "
      + "watch 4: water consumed 1300/min on nauvis, above 1200/min made");
  });

  it("without since_tick, waits for firings after the first read's tick", async () => {
    const { bridge, call } = game([busy, busy, { ...busy, tick: 160, watch_fired: [plates] }]);
    const value = await waitForEvent(bridge, input(), sources("pilot"), undefined, fakeClock());
    expect(call.mock.calls[0]).toEqual(["event_state"]);
    expect(call.mock.calls[1]).toEqual(["event_state", { role: "pilot", watch_since: 100 }]);
    expect(value).toMatchObject({ event: "watch_fired", watches: [plates] });
  });

  it("asks for no firings without a role, and Lua's empty table is no firing", async () => {
    const { bridge, call } = game([busy, { ...busy, watch_fired: {} as unknown as WatchFiring[] }]);
    expect(await waitForEvent(bridge, { timeout_seconds: 1, since_tick: 90 }, sources(), undefined, fakeClock()))
      .toMatchObject({ event: "timeout" });
    expect(call.mock.calls.every((args) => args.length === 1)).toBe(true);
    const empty = game([{ ...busy, watch_fired: {} as unknown as WatchFiring[] }]);
    expect(await waitForEvent(empty.bridge, { timeout_seconds: 1, since_tick: 90 }, sources("pilot"), undefined, fakeClock()))
      .toMatchObject({ event: "timeout" });
  });

  it("carries firings read beside a plan end, which a later since_tick call would miss", async () => {
    const both = { ...idle, tick: 170, last_plan_ended: { plan_id: 5, status: "completed", tick: 160 }, watch_fired: [plates] };
    const value = await waitForEvent(game([busy, both]).bridge, input(), sources("pilot"), undefined, fakeClock());
    expect(value).toMatchObject({ event: "plan_ended", plan_id: 5, watches: [plates] });
    expect(eventSummary(value)).toBe(`plan 5 ended completed; 1 watch fired too, in watches; ${IDLE_NOW}`);
  });

  it("states a line watch's numbers", () => {
    expect(watchText({ id: 7, tick: 1, value: 12, condition: { kind: "line_below", line: 5, per_min: 30 } }))
      .toBe("watch 7: line 5 makes 12/min, below 30/min");
  });
});

describe.each(["full", "read-only"] as McpSurface[])("set_watch and clear_watch (%s)", (surface) => {
  it("forwards the session's role with the condition, and returns the role's watches", async () => {
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    const schemas: Record<string, any> = {};
    const call = vi.fn(async (method: string) => method === "set_watch"
      ? { watch: { id: 2, armed: false, value: 0 }, watches: [{ id: 2 }], limit: 16 }
      : { cleared: [2], watches: {}, limit: 16 });
    const role = surface === "full" ? "pilot" : "strategist";
    registerMcpTools({ registerTool(name, config: any, run) { handlers[name] = run; schemas[name] = config.inputSchema; } },
      async () => ({ call } as unknown as Bridge), () => ({ ok: false, error: "offline fixture" }), surface, () => null, role);
    const condition = { kind: "line_below", line: { x: 10.5, y: 3.5 }, per_min: 30 };
    const set = await handlers.set_watch!({ condition });
    expect(call).toHaveBeenLastCalledWith("set_watch", { role, condition }, undefined);
    expect(set.structuredContent).toMatchObject({ watch: { id: 2, armed: false }, watches: [{ id: 2 }] });
    expect(set.content[0].text).toBe("watch 2 set, not armed: already past the threshold; value 0/min; 1 of 16 watches");
    const cleared = await handlers.clear_watch!({ all: true });
    expect(call).toHaveBeenLastCalledWith("clear_watch", { role, all: true }, undefined);
    expect(cleared.structuredContent).toMatchObject({ cleared: [2], watches: [] });
    expect(schemas.set_watch.safeParse({ condition: { kind: "rate_below", item: "iron-plate" } }).success).toBe(false);
    expect(schemas.set_watch.safeParse({ condition: { kind: "consumption_above_production", item: "water", per_min: 3 } }).success).toBe(false);
    expect(schemas.set_watch.safeParse({ condition: { kind: "rate_below", item: "iron-plate", per_min: 60 }, surface: "vulcanus" }).success).toBe(true);
    expect(schemas.clear_watch.safeParse({}).success).toBe(false);
    expect(schemas.clear_watch.safeParse({ id: 1, all: true }).success).toBe(false);
  });
});

describe("next_event own losses and repeated outcomes", () => {
  const belts = { name: "transport-belt", position: { x: 11, y: 10 }, surface: "nauvis", count: 2, tick: 210,
    killed_by: { name: "locomotive", type: "locomotive", force: "player" } };
  const panel = { name: "solar-panel", position: { x: 0, y: 0 }, surface: "platform:1", count: 1, tick: 230,
    killed_by: { force: "enemy" } };

  it("fires entities_lost for losses during the wait, never for those before the call", async () => {
    const before = { ...busy, last_loss_tick: 120, losses: [{ ...belts, tick: 120 }] };
    const after = { ...before, tick: 240, last_loss_tick: 230, losses: [{ ...belts, tick: 120 }, belts, panel] };
    const event = await waitForEvent(game([before, before, after]).bridge, input(), quiet(), undefined, fakeClock());
    expect(event).toMatchObject({ event: "entities_lost", losses: [belts, panel], tick: 240 });
    expect(eventSummary(event)).toBe("own entities destroyed: 2 transport-belt at (11, 10) on nauvis by locomotive; "
      + "1 solar-panel at (0, 0) on platform:1 by enemy");
    expect(await waitForEvent(game([before]).bridge, { timeout_seconds: 2 }, quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "timeout" });
  });

  it("delivers a loss stamped at the since_tick a read returned: that read ran before that tick's update", async () => {
    const state = { ...busy, tick: 240, last_loss_tick: 230, losses: [panel] };
    expect(await waitForEvent(game([state]).bridge, input({ since_tick: 230 }), quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "entities_lost", losses: [panel] });
  });

  it("keeps destroyed rows out of new_problem: they arrive in losses", async () => {
    const state = { ...busy, tick: 240, last_problem_tick: 235 };
    const call = vi.fn(async (method: string) => method === "factory_status"
      ? { tick: 240, problems: [{ status: "destroyed", name: "wall", position: { x: 1, y: 1 } }, { status: "no_power", name: "lab", position: { x: 2, y: 2 } }] }
      : state);
    const event: any = await waitForEvent({ call } as unknown as Bridge, input({ since_tick: 230 }), quiet(), undefined, fakeClock());
    expect(event.event).toBe("new_problem");
    expect(event.problems.map((row: any) => row.status)).toEqual(["no_power"]);
  });

  it("returns losses after since_tick at once, after plan ends, research and problems", async () => {
    const state = { ...busy, tick: 240, last_loss_tick: 230, losses: [belts, panel] };
    expect(await waitForEvent(game([state]).bridge, input({ since_tick: 220 }), quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "entities_lost", losses: [panel] });
    const ended = { ...state, last_plan_ended: { plan_id: 5, status: "completed", tick: 235 } };
    const first = await waitForEvent(game([ended]).bridge, input({ since_tick: 220 }), quiet(), undefined, fakeClock());
    expect(first).toMatchObject({ event: "plan_ended", plan_id: 5, losses: [panel] });
    expect(eventSummary(first)).toContain("; own entities destroyed: 1 solar-panel at (0, 0) on platform:1 by enemy");
    // An older mod has no loss fields: nothing changes.
    expect(await waitForEvent(game([busy]).bridge, { timeout_seconds: 1, since_tick: 100 }, quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "timeout" });
  });

  it("carries losses on another event in the same poll, so the next since_tick cannot skip them", async () => {
    let index = 0;
    const before = { ...busy, last_loss_tick: 120, losses: [{ ...belts, tick: 120 }] };
    const samples = [before, { ...before, tick: 240, last_problem_tick: 230, last_loss_tick: 230, losses: [{ ...belts, tick: 120 }, panel] }];
    const call = vi.fn(async (method: string) => method === "factory_status" ? { tick: 240, problems: [] }
      : samples[Math.min(index++, samples.length - 1)]);
    const event = await waitForEvent({ call } as unknown as Bridge, input(), quiet(), undefined, fakeClock());
    expect(event).toMatchObject({ event: "new_problem", losses: [panel], tick: 240 });
  });

  it("says when a plan's step repeats the same code at the same target", () => {
    const outcomes = [{ step: 1, action: "walk_to", status: "completed" },
      { step: 2, action: "get_items", status: "failed", code: "SUPPLY_SHORTFALL", repeat: 3,
        result: { code: "SUPPLY_SHORTFALL", recent_draws: [{ item: "steel-plate", count: 20, from: "stores", source: "package:oil", plan_id: 4, tick: 90 }] } }];
    expect(eventSummary({ event: "plan_ended", plan_id: 6, status: "failed", outcomes, body: { fifo_empty: false } }))
      .toBe("plan 6 ended failed; SUPPLY_SHORTFALL again at step 2 get_items (3 in a row)");
  });
});

describe("next_event idle interval, open packages and planet cargo", () => {
  it("reports packages_open, idle_since_tick and idle_seconds in the body block", async () => {
    const state: EventState = { ...idle, tick: 4_000, idle_since_tick: 400, package_plans: [7],
      body: { state: "on_surface" } };
    const seen: EventState[] = [];
    const event = await waitForEvent(game([state]).bridge, input(), { ...quiet(), packagesOpen: (read) => { seen.push(read); return 2; } },
      undefined, fakeClock());
    expect(event).toMatchObject({ event: "queue_empty", body: { fifo_empty: true, packages_open: 2, idle_since_tick: 400,
      idle_seconds: 60, state: "on_surface" } });
    expect(seen[0]?.package_plans).toEqual([7]);
    // Busy, or without a run: no idle interval, packages_open null.
    const working = await waitForEvent(game([busy]).bridge, { timeout_seconds: 1 }, quiet(), undefined, fakeClock());
    expect(working.body).toMatchObject({ packages_open: null, idle_since_tick: null, idle_seconds: null });
    const broken = await waitForEvent(game([state]).bridge, input(), { ...quiet(), packagesOpen: () => { throw new Error("EIO"); } },
      undefined, fakeClock());
    expect(broken.body).toMatchObject({ packages_open: null });
  });

  it("lets a cargo pod landing on a planet ride along instead of waking; a platform's still wakes", async () => {
    const drop = { tick: 210, kind: "cargo_delivered" as const, surface: "nauvis" };
    const before = { ...busy, tick: 200, last_space_event_tick: 120, space_events: [] as never[] };
    const dropped = { ...before, tick: 215, last_space_event_tick: 210, space_events: [drop] };
    const clock = fakeClock();
    const quietDrop = await waitForEvent(game([before, dropped]).bridge, { timeout_seconds: 2 }, quiet(), undefined, clock);
    expect(quietDrop).toMatchObject({ event: "timeout", space_events: [drop] });
    expect(clock.slept).toBe(2_000);
    expect(eventSummary(quietDrop)).toBe("nothing happened in 2 s; 1 rocket, platform or travel event in space_events");
    // With since_tick it rides along on the next event, never returning on its own.
    expect(await waitForEvent(game([dropped]).bridge, { timeout_seconds: 1, since_tick: 205 }, quiet(), undefined, fakeClock()))
      .toMatchObject({ event: "timeout", space_events: [drop] });
    const onPlatform = { tick: 212, kind: "cargo_delivered" as const, platform: { index: 3, name: "Orbit" } };
    const both = { ...dropped, tick: 220, last_space_event_tick: 212, space_events: [drop, onPlatform] };
    const woke = await waitForEvent(game([both]).bridge, input({ since_tick: 205 }), quiet(), undefined, fakeClock());
    expect(woke).toMatchObject({ event: "cargo_delivered", event_tick: 212, platform: { name: "Orbit" }, space_events: [drop, onPlatform] });
  });

  it("gives the idle cue once per idle interval, then the fact with its seconds", () => {
    const cue = {};
    const ended = (plan: number, since: number | null, seconds: number | null) => ({ event: "plan_ended", plan_id: plan, status: "completed",
      body: { fifo_empty: true, human_hold: false, idle_since_tick: since, idle_seconds: seconds } });
    expect(eventSummary(ended(5, 1_000, 0), "pilot", { cue })).toBe(`plan 5 ended completed; ${IDLE_NOW}`);
    expect(eventSummary({ event: "timeout", waited_seconds: 25, body: { fifo_empty: true, idle_since_tick: 1_000, idle_seconds: 25 } },
      "pilot", { cue })).toBe(`nothing happened in 25 s; ${IDLE_FACT} (25 s)`);
    expect(eventSummary({ event: "queue_empty", body: { fifo_empty: true, idle_since_tick: 1_000, idle_seconds: 40 } }, "pilot", { cue }))
      .toBe(`${IDLE_FACT} (40 s)`);
    // Work in between ends the interval; the next one is cued again.
    expect(eventSummary({ event: "timeout", waited_seconds: 25, body: { fifo_empty: false } }, "pilot", { cue }))
      .toBe("nothing happened in 25 s");
    expect(eventSummary(ended(6, 3_000, 0), "pilot", { cue })).toBe(`plan 6 ended completed; ${IDLE_NOW}`);
    // A new idle start without a busy read in between is a new interval too.
    expect(eventSummary(ended(7, 4_000, 0), "pilot", { cue })).toBe(`plan 7 ended completed; ${IDLE_NOW}`);
    // A reading role gets the fact once, then with its seconds.
    const reader = {};
    expect(eventSummary(ended(5, 1_000, 0), "strategist", { cue: reader })).toBe(`plan 5 ended completed; ${IDLE_FACT}`);
    expect(eventSummary(ended(5, 1_000, 3), "strategist", { cue: reader })).toBe(`plan 5 ended completed; ${IDLE_FACT} (3 s)`);
    // A cancelled wait states nothing, so the cue is still to come.
    const later = {};
    expect(eventSummary({ event: "cancelled", body: { fifo_empty: true, idle_since_tick: 1_000 } }, "pilot", { cue: later })).toBe("cancelled");
    expect(eventSummary({ event: "queue_empty", body: { fifo_empty: true, idle_since_tick: 1_000 } }, "pilot", { cue: later })).toBe(IDLE_NOW);
  });

  it("replaces the idle cue with the aboard fact while the body is aboard a platform", () => {
    const cue = {};
    const aboard = "the body is aboard platform Dawn: physical actions and hand-crafting fail with BODY_ABOARD until it lands; remote platform tools work";
    const event = { event: "timeout", waited_seconds: 25, body: { fifo_empty: true, idle_since_tick: 500, idle_seconds: 30,
      state: "aboard_platform", platform_name: "Dawn" } };
    expect(eventSummary(event, "pilot", { cue, aboard })).toBe(`nothing happened in 25 s; ${aboard}`);
    expect(eventSummary(event, "pilot", { cue, aboard })).toBe("nothing happened in 25 s; the FIFO is empty; the body is aboard (30 s)");
    expect(eventSummary(event, "pilot", { cue, aboard })).not.toContain("queue work now");
  });

  it("says the aboard fact through the MCP handler once per interval", async () => {
    const handlers: Record<string, (args: any, extra?: any) => Promise<any>> = {};
    const state: EventState = { ...idle, tick: 2_000, idle_since_tick: 200, body: { state: "aboard_platform", platform_name: "Dawn" } };
    registerMcpTools({ registerTool(name, _config, run) { handlers[name] = run; } }, async () => game([state]).bridge,
      () => ({ ok: false, error: "offline fixture" }), "full", () => null, "pilot");
    const first = await handlers.next_event!({ timeout_seconds: 1 });
    expect(first.content[0].text).toBe("the body is aboard platform Dawn: physical actions and hand-crafting fail with BODY_ABOARD until it lands; remote platform tools work");
    expect(first.structuredContent.body).toMatchObject({ state: "aboard_platform", platform_name: "Dawn", idle_seconds: 30, packages_open: null });
    const second = await handlers.next_event!({ timeout_seconds: 1 });
    expect(second.content[0].text).toBe("the FIFO is empty; the body is aboard (30 s)");
  });
});
