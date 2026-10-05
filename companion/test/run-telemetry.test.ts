import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { checkpointDelay, compareRuns, createRunStore, markRunAssisted, readManifest, resourceVerdict,
  parseRunSnapshot, rolloutResolver, sampleSchema, snapshotDelta, type RunManifest, type RunSample, type RunSnapshot } from "../src/runs/telemetry.js";

const roots: string[] = [];
afterEach(() => roots.splice(0).forEach((root) => fs.rmSync(root, { recursive: true, force: true })));
const root = () => { const value = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-runs-")); roots.push(value); return value; };

function snapshot(tick: number, iron: number, copper = 0): RunSnapshot {
  return { tick, character: {}, progression: {}, factory: {}, statistics: {
    items: { produced: [{ name: "iron-ore", count: iron }, ...(copper ? [{ name: "copper-ore", count: copper }] : [])], consumed: [] },
    fluids: { produced: [], consumed: [] }, raw_resources: [{ type: "item", name: "copper-ore" }, { type: "item", name: "iron-ore" }],
    semantics: { produced: "force_surface_input_counts", consumed: "force_surface_output_counts" },
  } };
}
function manifest(id: string, variant: string, baseline = "b".repeat(64)): RunManifest {
  return { schema_version: 1, run: { id, release_sha: "a".repeat(40), baseline_save_sha256: baseline,
    save_identity: "fresh-save", created_at: "2026-09-04T08:00:00Z",
    roles: { pilot: { model: "gpt-6-luna", reasoning: "low", fast: true }, strategist: { model: "gpt-6-astra", reasoning: "medium", fast: false } } },
    variant, change: `${variant} change`, kind: "benchmark", status: "finished", assisted: false,
    app_version: "0.17.0", mod_version: "0.17.0", factorio_version: "2.0.77",
    started_at: "2026-09-04T08:00:00Z", start_tick: 100, ended_at: "2026-09-04T08:20:00Z", end_tick: 72100 };
}
function checkpoint(current: RunSnapshot, baseline: RunSnapshot, minutes = 5): Extract<RunSample, { status: "ok" }> {
  return sampleSchema.parse({ status: "ok", kind: "checkpoint", scheduled_elapsed_ms: minutes * 60_000,
    actual_elapsed_ms: minutes * 60_000 + 50, capture_started_at: "2026-09-04T08:05:00Z",
    capture_completed_at: "2026-09-04T08:05:00.050Z", capture_latency_ms: 50,
    tick: current.tick, tick_delta: current.tick - baseline.tick, snapshot: current, delta: snapshotDelta(current, baseline) }) as Extract<RunSample, { status: "ok" }>;
}
function storedRun(store: string, meta: RunManifest, sample: RunSample) {
  const files = createRunStore(store, { ...meta, status: "recording", ended_at: null, end_tick: null });
  fs.appendFileSync(files.samples, `${JSON.stringify(sample)}\n`);
  fs.writeFileSync(files.manifest, `${JSON.stringify(meta)}\n`, { mode: 0o600 });
}

describe("five-minute run telemetry", () => {
  it("schedules from absolute five-minute deadlines without chained drift", () => {
    expect(checkpointDelay(1, 1_000)).toBe(299_000);
    expect(checkpointDelay(2, 301_000)).toBe(299_000);
    expect(checkpointDelay(2, 601_000)).toBe(0);
  });

  it("subtracts GO counters and derives only the raw-resource vector", () => {
    const delta = snapshotDelta(snapshot(200, 15, 8), snapshot(100, 5, 2));
    expect(delta.items).toEqual([{ name: "copper-ore", produced: 6, consumed: 0 }, { name: "iron-ore", produced: 10, consumed: 0 }]);
    expect(delta.raw_resources).toEqual([{ type: "item", name: "copper-ore", produced: 6, consumed: 0 }, { type: "item", name: "iron-ore", produced: 10, consumed: 0 }]);
  });

  it("normalizes Factorio's empty Lua tables at the protocol boundary", () => {
    const value: any = snapshot(100, 0); value.statistics.items.produced = {}; value.statistics.items.consumed = {};
    value.statistics.fluids.produced = {}; value.statistics.fluids.consumed = {}; value.statistics.raw_resources = {};
    expect(parseRunSnapshot(value).statistics).toMatchObject({ items: { produced: [], consumed: [] },
      fluids: { produced: [], consumed: [] }, raw_resources: [] });
  });

  it("records standing_on as null when Lua omits it and keeps a reported conveyor", () => {
    expect(parseRunSnapshot(snapshot(100, 0)).character.standing_on).toBeNull();
    const onBelt: any = snapshot(100, 0);
    onBelt.character.standing_on = { name: "transport-belt", type: "transport-belt", direction: 4 };
    expect(parseRunSnapshot(onBelt).character.standing_on).toEqual({ name: "transport-belt", type: "transport-belt", direction: 4 });
  });

  it("accepts the mod's production-line counts and snapshots without them", () => {
    const lines = { line_count: 3, running_line_count: 2, self_sustaining_line_count: 1, hand_fed_line_count: 1 };
    const withLines: any = { ...snapshot(100, 0), lines };
    expect(parseRunSnapshot(withLines).lines).toEqual(lines);
    expect(parseRunSnapshot(snapshot(100, 0)).lines).toBeUndefined();
    expect(() => parseRunSnapshot({ ...snapshot(100, 0), lines: { ...lines, line_count: -1 } })).toThrow();
  });

  it("accepts the hand-crafted counter, empty as a Lua table, and samples recorded before it", () => {
    const counted: any = snapshot(100, 0);
    counted.statistics.hand_crafted = { since_tick: 50, items: [{ name: "iron-gear-wheel", count: 4 }] };
    expect(parseRunSnapshot(counted).statistics.hand_crafted).toEqual({ since_tick: 50, items: [{ name: "iron-gear-wheel", count: 4 }] });
    const empty: any = snapshot(100, 0);
    empty.statistics.hand_crafted = { since_tick: 50, items: {} };
    expect(parseRunSnapshot(empty).statistics.hand_crafted?.items).toEqual([]);
    expect(parseRunSnapshot(snapshot(100, 0)).statistics.hand_crafted).toBeUndefined();
  });

  it("resolves a role rollout from the pointer file and falls back to the flag only when it is absent", () => {
    const dir = root(), pointer = path.join(dir, "rollouts.json");
    const luna = rolloutResolver(pointer, "luna", "/first/pilot.jsonl");
    expect(luna()).toBe("/first/pilot.jsonl");
    fs.writeFileSync(pointer, JSON.stringify({ luna: "/second/pilot.jsonl" }));
    expect(luna()).toBe("/second/pilot.jsonl");
    fs.writeFileSync(pointer, '{"luna": "/second/pi');
    expect(luna()).toBeNull();
    fs.writeFileSync(pointer, JSON.stringify({ astra: "/astra.jsonl" }));
    expect(luna()).toBe("/first/pilot.jsonl");
  });

  it("uses conservative vector dominance instead of summing resources", () => {
    const base = snapshot(100, 0), lower = checkpoint(snapshot(200, 10, 10), base);
    expect(resourceVerdict(lower, checkpoint(snapshot(200, 11, 10), base))).toBe("improved");
    expect(resourceVerdict(lower, checkpoint(snapshot(200, 9, 11), base))).toBe("mixed");
    expect(resourceVerdict(lower, checkpoint(snapshot(200, 9, 9), base))).toBe("worse");
  });

  it("persists separate run identities and refuses accidental overwrite", () => {
    const store = root(), meta = manifest("run-1", "baseline");
    const files = createRunStore(store, meta);
    expect(fs.statSync(files.manifest).mode & 0o777).toBe(0o600);
    expect(() => createRunStore(store, meta)).toThrow();
  });

  it("compares matching clean benchmarks and excludes assisted evidence", () => {
    const store = root(), zero = snapshot(100, 0);
    storedRun(store, manifest("run-a", "old"), checkpoint(snapshot(18100, 10, 5), zero));
    storedRun(store, manifest("run-b", "new"), checkpoint(snapshot(18100, 12, 5), zero));
    expect(compareRuns(store, "run-a", "run-b")).toMatchObject({ eligible: true, verdict: "improved",
      checkpoints: [{ elapsed_minutes: 5, verdict: "improved" }] });
    markRunAssisted(store, "run-b", "teleport recovery");
    expect(readManifest(store, "run-b").assisted).toBe(true);
    expect(compareRuns(store, "run-a", "run-b")).toMatchObject({ eligible: false, verdict: "ineligible",
      descriptive_verdict: "improved", reasons: ["candidate was assisted"] });
  });

  it("keeps runs recorded with an earlier strategist profile readable", () => {
    const store = root(), zero = snapshot(100, 0), earlier = manifest("run-a", "old");
    earlier.run.roles.strategist = { model: "gpt-6.1-sol", reasoning: "medium", fast: false };
    storedRun(store, earlier, checkpoint(snapshot(18100, 10), zero));
    storedRun(store, manifest("run-b", "new"), checkpoint(snapshot(18100, 12), zero));
    expect(readManifest(store, "run-a").run.roles.strategist.model).toBe("gpt-6.1-sol");
    expect(compareRuns(store, "run-a", "run-b")).toMatchObject({ eligible: true, verdict: "improved" });
  });

  it("rejects automatic verdicts across different baseline saves", () => {
    const store = root(), zero = snapshot(100, 0), sample = checkpoint(snapshot(18100, 10), zero);
    storedRun(store, manifest("run-a", "old"), sample);
    storedRun(store, manifest("run-b", "new", "c".repeat(64)), sample);
    expect(compareRuns(store, "run-a", "run-b")).toMatchObject({ eligible: false, verdict: "ineligible",
      reasons: ["baseline save hashes differ"] });
  });

  it("does not call absent or failed common checkpoints equal", () => {
    const store = root(), zero = snapshot(100, 0);
    storedRun(store, manifest("run-a", "old"), checkpoint(snapshot(18100, 10), zero, 5));
    storedRun(store, manifest("run-b", "new"), checkpoint(snapshot(36100, 20), zero, 10));
    expect(compareRuns(store, "run-a", "run-b")).toMatchObject({ eligible: false, verdict: "ineligible",
      reasons: ["no common successful five-minute checkpoints"], checkpoints: [] });
  });
});
