import { describe, expect, it } from "vitest";
import { evaluateTiming, profile } from "./live-timing.js";

const rpc = (tick: number, ms: number, method = "factory_status") => `0.1 Script @mod:1: rpc ${method} tick ${tick} Duration: ${ms}ms\n`;
const job = (tick: number, ms: number, kinds = "run_snapshot") => `0.1 Script @mod:1: job_tick ${tick} ${kinds} Duration: ${ms}ms\n`;
const window = (ms = 600) => `0.1 Script @mod:1: on_tick 600 ticks Duration: ${ms}ms\n`;
const evidence = job(1, 0.1) + window();

describe("live suite timing policy", () => {
  it("passes exactly 8 ms including all RPC and job work of a tick", () => {
    const result = evaluateTiming(rpc(1, 3) + rpc(1, 2, "get_job") + job(1, 3, "run_snapshot,production_requirements") + window());
    expect(result.ok).toBe(true);
    expect(result.excursions).toEqual([]);
    expect(result.ticks).toEqual([{ tick: 1, ms: 8, methods: ["factory_status", "get_job", "job:run_snapshot", "job:production_requirements"], gc: false }]);
  });

  it.each([8.79, 9.40, 10])("allows one %s ms tick with an explicit excursion diagnostic", (ms) => {
    const result = evaluateTiming(evidence + rpc(42, ms));
    expect(result.ok).toBe(true);
    expect(result.excursions).toHaveLength(1);
    expect(result.detail).toContain("nominal-budget excursions (1, allowance 1)");
    expect(result.detail).toContain(`tick 42 ${ms.toFixed(2)} ms (factory_status; GC heap decrease not observed)`);
  });

  it("classifies exact decimal sums at 8 and 10 ms without binary rounding excursions", () => {
    const log = rpc(42, 0.56) + rpc(42, 6.98, "get_job") + job(42, 0.46)
      + rpc(43, 0.05) + rpc(43, 7.98, "get_job") + job(43, 1.97) + window();
    const result = evaluateTiming(log);
    expect(result.ok).toBe(true);
    expect(result.ticks.map((row) => row.ms)).toEqual([8, 10]);
    expect(result.excursions.map((row) => row.tick)).toEqual([43]);
    expect(evaluateTiming(log + job(43, 0.001)).ok).toBe(false);
  });

  it("fails two distinct 9 ms ticks, even in different methods", () => {
    const result = evaluateTiming(evidence + rpc(42, 9) + rpc(43, 9, "queue_plan"));
    expect(result.ok).toBe(false);
    expect(result.errors).toContain("2 distinct ticks exceed 8 ms; at most one allowed");
    expect(result.detail).toContain("tick 42 9.00 ms");
    expect(result.detail).toContain("tick 43 9.00 ms");
  });

  it("fails any tick above the 10 ms hard ceiling", () => {
    const result = evaluateTiming(evidence + rpc(42, 10.01));
    expect(result.ok).toBe(false);
    expect(result.errors).toContain("measured tick exceeds hard ceiling 10 ms");
  });

  it("fails individually fast RPC and job rows whose same-tick sum exceeds 10 ms", () => {
    const result = evaluateTiming(rpc(42, 4) + rpc(42, 3, "get_job") + job(42, 4) + window());
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("tick 42 11.00 ms (factory_status, get_job, job:run_snapshot;");
  });

  it("keeps GC time in the allowance and ceiling, reporting the annotation", () => {
    const gc = "0.1 Script @mod:1: gc_freed 42 rpc:run_snapshot\n";
    const allowed = evaluateTiming(evidence + rpc(42, 9.4, "run_snapshot") + gc);
    expect(allowed.ok).toBe(true);
    expect(allowed.detail).toContain("tick 42 9.40 ms (run_snapshot; GC heap decrease observed)");
    expect(evaluateTiming(evidence + rpc(42, 9.4) + gc + rpc(43, 9)).ok).toBe(false);
    expect(evaluateTiming(evidence + rpc(42, 10.01) + gc).ok).toBe(false);
  });

  it("fails any on_tick window above 8 ms average, even alongside faster windows", () => {
    expect(evaluateTiming(evidence + rpc(42, 1) + window(4800)).ok).toBe(true);
    const result = evaluateTiming(evidence + rpc(42, 1) + window(4800.6));
    expect(result.ok).toBe(false);
    expect(result.errors).toContain("on_tick window average exceeds 8 ms/tick");
  });

  it.each([
    ["", "missing RPC timing evidence"],
    [job(1, 1) + window(), "missing RPC timing evidence"],
    [rpc(1, 1) + window(), "missing job timing evidence"],
    [rpc(1, 1) + job(1, 1), "missing on_tick window timing evidence"],
  ])("fails missing required evidence (%s)", (log, error) => {
    const result = evaluateTiming(log);
    expect(result.ok).toBe(false);
    expect(result.errors).toContain(error);
  });

  it("defers only missing windows at checkpoints, retaining the same timing policy", () => {
    const log = rpc(42, 9) + job(1, 1);
    expect(evaluateTiming(log, { requireWindows: false }).ok).toBe(true);
    expect(evaluateTiming(log).ok).toBe(false);
    expect(evaluateTiming(log + window(4801), { requireWindows: false }).ok).toBe(false);
    expect(evaluateTiming(log + rpc(43, 9), { requireWindows: false }).ok).toBe(false);
  });

  it("does not count repeated appearances of a tick in overlapping checkpoint/final reads twice", () => {
    const first = evidence + rpc(42, 9);
    const second = first + rpc(43, 1);
    for (const log of [first, second, second]) {
      const result = evaluateTiming(log);
      expect(result.ok).toBe(true);
      expect(result.excursions.map((row) => row.tick)).toEqual([42]);
    }
    // A later checkpoint must retain earlier excursions outside its scenario
    // slice. All callers evaluate the full log prefix, not that slice alone.
    const last = second + rpc(44, 9, "production_requirements");
    expect(evaluateTiming(last).ok).toBe(false);
    expect(evaluateTiming(last).excursions.map((row) => row.tick)).toEqual([42, 44]);
  });

  it("recomputes a shared tick when later rows arrive rather than dropping or duplicating them", () => {
    const prefix = evidence + rpc(42, 8.5);
    expect(evaluateTiming(prefix).ok).toBe(true);
    const result = evaluateTiming(prefix + job(42, 2));
    expect(result.ok).toBe(false);
    expect(result.excursions).toHaveLength(1);
    expect(result.excursions[0]?.ms).toBe(10.5);
    expect(profile(prefix).ticks.find((row) => row.tick === 42)?.ms).toBe(8.5);
  });
});
