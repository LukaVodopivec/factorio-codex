import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { initialProfiles, profileListSchema } from "../src/runs/profiles.js";
import { benchmarkScore, cutoffIssues, type BenchmarkEvidence } from "../src/runs/benchmark.js";
import { initializeCampaign, nextTrial, recordTrial, confirmationWins, trialWins, setCampaignStatus, type Trial } from "../src/runs/campaign.js";
import { createRunStore, interruptRun, snapshotDelta, type RunManifest, type RunSnapshot } from "../src/runs/telemetry.js";

const dirs: string[] = [];
afterEach(() => dirs.splice(0).forEach(dir => fs.rmSync(dir, { recursive: true, force: true })));
function setup() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-campaign-")); dirs.push(dir);
  const baseline = path.join(dir, "source.zip"), file = path.join(dir, "campaign", "campaign.json");
  fs.writeFileSync(baseline, Buffer.from("504b030401", "hex"));
  initializeCampaign(file, baseline, "search", "a".repeat(40)); return { file, dir };
}
const metrics = { "iron-ore": 100, "copper-ore": 20, coal: 10, stone: 5, "iron-plate": 70, "copper-plate": 10 };
const evidence: BenchmarkEvidence = { duration_seconds: 1200, deadline_at: "2026-10-06T00:20:00Z",
  freeze_started_at: "2026-10-06T00:20:00Z", freeze_completed_at: "2026-10-06T00:20:00Z", freeze_skew_ms: 0,
  start_tick: 100, frozen_tick: 72100, reason: "recorder", metrics };
function record(file: string, dir: string, input: number, assisted = false, alter?: (files: ReturnType<typeof createRunStore>) => void) {
  const { campaign: c, configuration: config } = nextTrial(file);
  const id = c.pending!.run_id;
  const meta: RunManifest = { schema_version: 1, run: { id, release_sha: config!.release_sha,
    baseline_save_sha256: c.baseline_save_sha256, save_identity: "fresh", created_at: "2026-10-06T00:00:00Z", roles: config!.profiles },
    variant: config!.id, change: config!.change, kind: "benchmark", status: "finished", assisted,
    app_version: "0.23.0", mod_version: "0.23.0", factorio_version: "2.0.77", started_at: "2026-10-06T00:00:00Z",
    start_tick: 100, ended_at: "2026-10-06T00:20:00Z", end_tick: 72100,
    benchmark: { ...evidence, metrics: { ...metrics, "iron-ore": input } } };
  const files = createRunStore(dir, meta);
  const snap: RunSnapshot = { tick: 54100, character: {}, progression: {}, factory: {}, statistics: {
    items: { produced: [{ name: "iron-ore", count: input / 2 }], consumed: [] }, fluids: { produced: [], consumed: [] },
    raw_resources: [{ name: "iron-ore", type: "item" }], semantics: { produced: "force_surface_input_counts", consumed: "force_surface_output_counts" } } };
  const zero = { ...snap, statistics: { ...snap.statistics, items: { produced: [], consumed: [] } } };
  fs.appendFileSync(files.samples, JSON.stringify({ status: "ok", kind: "checkpoint", scheduled_elapsed_ms: 900000,
    actual_elapsed_ms: 900000, capture_started_at: "2026-10-06T00:15:00Z", capture_completed_at: "2026-10-06T00:15:00Z",
    capture_latency_ms: 0, tick: 54100, tick_delta: 54000, snapshot: snap, delta: snapshotDelta(snap, zero) }) + "\n");
  alter?.(files);
  return recordTrial(file, id, dir);
}
describe("finite benchmark campaign", () => {
  it("accepts 1-4 brains with one body writer and ledger owner", () => {
    for (const count of [1, 2, 3, 4]) {
      const roles = initialProfiles(count); expect(roles).toHaveLength(count);
      expect(roles.filter(r => r.role === "pilot")).toHaveLength(1);
      expect(roles.filter(r => r.ledger_writer)).toHaveLength(1);
    }
    expect(() => initialProfiles(5)).toThrow();
    const roles = initialProfiles(3);
    expect(profileListSchema.safeParse(roles.map(r => ({ ...r, ledger_writer: true }))).success).toBe(false);
    expect(profileListSchema.safeParse(roles.map(r => r.id === "mining" ? { ...r, role: "pilot" } : r)).success).toBe(false);
  });
  it("rejects late, short, slowed, incomplete cutoff evidence", () => {
    expect(cutoffIssues(evidence)).toEqual([]);
    for (const value of [undefined, { ...evidence, duration_seconds: 10 }, { ...evidence, freeze_skew_ms: 1100 },
      { ...evidence, frozen_tick: 70000 }, { ...evidence, metrics: {} }]) expect(cutoffIssues(value).length).toBeGreaterThan(0);
    expect(benchmarkScore(metrics)).toMatchObject({ input: 135, output: 80 });
  });
  it("keeps pending selection stable, pauses, and retries excluded trials", () => {
    const { file, dir } = setup();
    expect(nextTrial(file)).toEqual(nextTrial(file));
    const c = record(file, dir, 100, true);
    expect(c.trials[0]!.eligible).toBe(false); expect(c.screening_queue[0]).toBe("brains-2");
    expect(nextTrial(file).campaign.pending!.run_id).toBe("search-trial-0002");
    setCampaignStatus(file, "paused"); expect(nextTrial(file).configuration).toBeUndefined();
  });
  it("promotes only after three fresh alternating pairs", () => {
    const { file, dir } = setup();
    record(file, dir, 100); // two-brain incumbent baseline
    let c = record(file, dir, 200); // solo screen
    expect(c.incumbent).toBe("brains-2"); expect(c.confirmation?.challenger).toBe("brains-1");
    for (const [config, score] of [["brains-1", 200], ["brains-2", 100], ["brains-2", 100],
      ["brains-1", 200], ["brains-1", 200], ["brains-2", 100]] as const) {
      expect(nextTrial(file).configuration!.id).toBe(config); c = record(file, dir, score);
    }
    expect(c.incumbent).toBe("brains-1"); expect(c.confirmation).toBeNull();
    expect(recordTrial(file, c.trials.at(-1)!.run_id, dir)).toEqual(c);
  });
  it("selects trials for the longest accepted campaign name", () => {
    const { file } = setup(), c = JSON.parse(fs.readFileSync(file, "utf8"));
    c.id = "x".repeat(120); fs.writeFileSync(file, JSON.stringify(c));
    expect(nextTrial(file).campaign.pending!.run_id).toHaveLength(131);
  });
  it("excludes delayed and torn checkpoint evidence without sticking the campaign", () => {
    for (const malformed of [false, true]) {
      const { file, dir } = setup();
      const c = record(file, dir, 100, false, files => {
        const sample = JSON.parse(fs.readFileSync(files.samples, "utf8"));
        sample.actual_elapsed_ms += 1500;
        fs.writeFileSync(files.samples, JSON.stringify(sample) + "\n" + (malformed ? '{"status":' : ""));
      });
      expect(c.trials[0]!.eligible).toBe(false);
      expect(nextTrial(file).campaign.pending!.run_id).toBe("search-trial-0002");
    }
  });
  it("closes a reconciled dead recorder as interrupted and preserves evidence", () => {
    const { file, dir } = setup();
    const c = record(file, dir, 100, false, files => {
      const meta = JSON.parse(fs.readFileSync(files.manifest, "utf8"));
      meta.status = "recording"; meta.ended_at = null; meta.end_tick = null;
      fs.writeFileSync(files.manifest, JSON.stringify(meta));
      const samples = fs.readFileSync(files.samples, "utf8");
      interruptRun(dir, meta.run.id, "writers retired; saved server stopped; recorder absent");
      interruptRun(dir, meta.run.id, "duplicate recovery");
      expect(fs.readFileSync(files.samples, "utf8")).toBe(samples);
      expect(fs.readFileSync(files.events, "utf8").trim().split("\n")).toHaveLength(1);
    });
    expect(c.trials[0]!.reasons).toContain("trial did not finish");
    expect(nextTrial(file).campaign.pending!.run_id).toBe("search-trial-0002");
  });
  it("uses plates within five percent but rejects a one-off win", () => {
    const t = (input: number, output: number) => ({ input, output, eligible: true, final_input_per_minute: 0 }) as Trial;
    expect(trialWins(t(100, 110), t(100, 100))).toBe(true);
    expect(confirmationWins([[t(120, 100), t(100, 100)], [t(90, 100), t(100, 100)], [t(90, 100), t(100, 100)]])).toBe(false);
    expect(confirmationWins(Array.from({ length: 3 }, () => [t(100, 110), t(100, 100)]))).toBe(true);
  });
});
