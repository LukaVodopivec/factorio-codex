import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Bridge, ModError } from "../src/bridge.js";
import { registerMcpTools } from "../src/mcp/server.js";
import type { RconClient } from "../src/rcon.js";
import { attestationIssues, bodySummary, checkpointDelay, compareRuns, createAttestor, createRunStore, createToolOutcomeLog, markRunAssisted, readManifest, resourceVerdict,
  parseRunSnapshot, rolloutResolver, runEvents, sampleSchema, snapshotDelta, TOOL_OUTCOMES_MAX_BYTES, toolOutcome,
  type RunAttestation, type RunManifest, type RunSample, type RunSnapshot } from "../src/runs/telemetry.js";

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
    roles: { pilot: { model: "gpt-6-luna", reasoning: "low", fast: true }, strategist: { model: "gpt-6.1-sol", reasoning: "medium", fast: false } } },
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
  const fifo = { active_plan_id: 1907, queue_depth: 1, idle_seconds: 0, human_control: false, human_idle_ticks: 500,
    body: { state: "on_surface", surface_ref: "nauvis", bound_for: "vulcanus",
      rebind_refused: { tick: 100, characters: 2 } } };
  it.each([false, true])("validates and retains a snapshot from the bridge (async=%s)", async (async) => {
    const source = snapshot(200, 15);
    const rcon = { exec: async (cmd: string) => JSON.stringify({ ok: true, data: !async ? source
      : cmd.includes('"get_job"') ? { job_id: 1, job_status: "done", result: source, fifo }
        : { job_id: 1, job_status: "pending" } }) } as unknown as RconClient;
    const bridge = new Bridge(rcon, { now: () => 0, sleep: async () => {} });
    const parsed = parseRunSnapshot(await bridge.call("run_snapshot"));
    expect(parsed.fifo).toEqual(async ? fifo : undefined);
    const recorded = checkpoint(parsed, snapshot(100, 5));
    expect(recorded.snapshot.fifo).toEqual(parsed.fifo);
    expect(recorded.delta.items).toEqual([{ name: "iron-ore", produced: 10, consumed: 0 }]);
  });

  it("retains every fifo_state field a get_job result carries during active play", async () => {
    const busy = { ...fifo, queued_demand: { "iron-plate": 40, "copper-cable": 12 }, omitted_queued_demand: 3,
      short_by: { "iron-plate": 15 }, omitted_short_by: 1, upkeep_off_since_tick: 3600,
      upkeep_skipped: { tick: 3500, items: ["coal"], free_slots: 0 } };
    const rcon = { exec: async (cmd: string) => JSON.stringify({ ok: true, data: cmd.includes('"get_job"')
      ? { job_id: 1, job_status: "done", result: snapshot(200, 15), fifo: busy }
      : { job_id: 1, job_status: "pending" } }) } as unknown as RconClient;
    const bridge = new Bridge(rcon, { now: () => 0, sleep: async () => {} });
    const parsed = parseRunSnapshot(await bridge.call("run_snapshot"));
    expect(parsed.fifo).toEqual(busy);
    expect(checkpoint(parsed, snapshot(100, 5)).snapshot.fifo).toEqual(busy);
    for (const invalid of [{ ...busy, short_by: { "iron-plate": -1 } }, { ...busy, queued_demand: { "iron-plate": 1.5 } },
      { ...busy, omitted_short_by: 0 }, { ...busy, upkeep_off_since_tick: "3600" },
      { ...busy, upkeep_skipped: { tick: 3500, items: [] } }]) {
      expect(() => parseRunSnapshot({ ...snapshot(200, 15), fifo: invalid })).toThrow();
    }
  });

  it("rejects malformed FIFO and unrelated extra fields instead of concealing them", () => {
    for (const invalid of [{ ...fifo, queue_depth: -1 }, { ...fifo, human_control: "false" },
      { ...fifo, unknown: 1 }, { ...fifo, body: { ...fifo.body, unknown: 1 } }]) {
      expect(() => parseRunSnapshot({ ...snapshot(200, 15), fifo: invalid })).toThrow();
    }
    expect(() => parseRunSnapshot({ ...snapshot(200, 15), fifo, unknown: 1 })).toThrow();
  });

  it("retains native top-level rebind refusal and rejects malformed or extra body metadata", () => {
    const body = { state: "on_surface", surface_ref: "nauvis", rebind_refused: { tick: 100, characters: 2 } };
    expect(parseRunSnapshot({ ...snapshot(200, 15), body }).body).toEqual(body);
    for (const invalid of [{ ...body, rebind_refused: { tick: -1, characters: 2 } },
      { ...body, rebind_refused: { ...body.rebind_refused, unknown: 1 } }, { ...body, unknown: 1 }]) {
      expect(() => parseRunSnapshot({ ...snapshot(200, 15), body: invalid })).toThrow();
    }
  });

  it("keeps async native failures as errors without snapshot metrics", async () => {
    const rcon = { exec: async (cmd: string) => JSON.stringify({ ok: true, data: cmd.includes('"get_job"')
      ? { job_id: 1, job_status: "failed", error: "snapshot computation failed", fifo }
      : { job_id: 1, job_status: "pending" } }) } as unknown as RconClient;
    const bridge = new Bridge(rcon, { now: () => 0, sleep: async () => {} });
    await expect(bridge.call("run_snapshot")).rejects.toThrow(ModError);
    const error = sampleSchema.parse({ status: "error", kind: "checkpoint", scheduled_elapsed_ms: 300_000,
      actual_elapsed_ms: 300_050, capture_started_at: "2026-09-04T08:05:00Z",
      capture_completed_at: "2026-09-04T08:05:00.050Z", capture_latency_ms: 50, error: "snapshot computation failed" });
    expect(error).not.toHaveProperty("snapshot");
    expect(error).not.toHaveProperty("delta");
    expect(() => sampleSchema.parse({ ...error, snapshot: snapshot(200, 15) })).toThrow();
  });

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

  it("reads 0.22.3 snapshots: summed counters with each surface's, the body's place, no character while it is away", () => {
    const value: any = snapshot(100, 12);
    delete value.character;
    value.body = { state: "aboard_platform", surface_ref: "platform:3", platform_name: "Orbit" };
    value.statistics.semantics.items = "summed_over_factory_surfaces";
    value.statistics.by_surface = { nauvis: { items: { produced: [{ name: "iron-ore", count: 10 }], consumed: {} }, fluids: { produced: {}, consumed: {} } },
      vulcanus: { items: { produced: [{ name: "iron-ore", count: 2 }], consumed: {} }, fluids: { produced: {}, consumed: {}, unavailable: true } } };
    const parsed = parseRunSnapshot(value);
    expect(parsed.character).toBeNull();
    expect(parsed.body).toEqual({ state: "aboard_platform", surface_ref: "platform:3", platform_name: "Orbit" });
    expect(parsed.statistics.by_surface?.vulcanus).toEqual({ items: { produced: [{ name: "iron-ore", count: 2 }], consumed: [] },
      fluids: { produced: [], consumed: [], unavailable: true } });
    // The recorder's deltas read the sums, as before.
    expect(snapshotDelta(parsed, snapshot(50, 5)).items).toEqual([{ name: "iron-ore", produced: 7, consumed: 0 }]);
    expect(parseRunSnapshot({ ...snapshot(100, 0), statistics: { ...snapshot(100, 0).statistics, by_surface: [] } }).statistics.by_surface).toEqual({});
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
    const pilot = rolloutResolver(pointer, "pilot", "/first/pilot.jsonl");
    expect(pilot()).toBe("/first/pilot.jsonl");
    fs.writeFileSync(pointer, JSON.stringify({ pilot: "/second/pilot.jsonl" }));
    expect(pilot()).toBe("/second/pilot.jsonl");
    fs.writeFileSync(pointer, '{"pilot": "/second/pi');
    expect(pilot()).toBeNull();
    fs.writeFileSync(pointer, JSON.stringify({ strategist: "/strategist.jsonl" }));
    expect(pilot()).toBe("/first/pilot.jsonl");
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
    earlier.run.roles.strategist = { model: "gpt-6-astra", reasoning: "medium", fast: false };
    storedRun(store, earlier, checkpoint(snapshot(18100, 10), zero));
    storedRun(store, manifest("run-b", "new"), checkpoint(snapshot(18100, 12), zero));
    expect(readManifest(store, "run-a").run.roles.strategist.model).toBe("gpt-6-astra");
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

describe("run attestation", () => {
  const clean: RunAttestation = { game_speed: 1, cheat_mode: false, controller: "remote", physical_controller: "character",
    mods: { base: "2.0.77", "elevated-rails": "2.0.77", quality: "2.0.77", "space-age": "2.0.77", "agentic-companion": "0.32.0" },
    bonuses: [] };
  it("finds nothing in an unassisted game and names every deviating fact", () => {
    expect(attestationIssues(clean)).toEqual([]);
    expect(attestationIssues({ ...clean, controller: "map" as string, physical_controller: "ghost" })).toEqual([]);
    expect(attestationIssues({ game_speed: 4, cheat_mode: true, controller: "editor", physical_controller: "god",
      mods: { ...clean.mods, "even-distribution": "2.0.1" },
      bonuses: [{ scope: "force", name: "manual_crafting_speed_modifier", value: 2, from_research: 0 },
        { scope: "force", name: "laboratory_speed_modifier", value: 0.5, from_research: 0.6 },
        { scope: "character", name: "character_reach_distance_bonus", value: 5, from_research: 0 }] })).toEqual([
      "game.speed is 4", "the Codex player's cheat_mode is true", "the Codex player's controller is editor",
      "the Codex player's physical controller is god", "mod even-distribution 2.0.1 is active",
      "force manual_crafting_speed_modifier is 2; research grants 0",
      "character character_reach_distance_bonus is 5; research grants 0"]);
  });

  it("treats a missing attestation or unreadable fact as a deviation", () => {
    expect(attestationIssues(undefined)).toEqual(["the snapshot carries no attestation"]);
    expect(attestationIssues({ ...clean, game_speed: undefined, cheat_mode: undefined })).toEqual([
      "game.speed is unreadable", "the Codex player's cheat_mode is unreadable"]);
  });

  it("marks the recorded run assisted once per deviating fact, with the reason", () => {
    const store = root();
    createRunStore(store, { ...manifest("run-x", "v"), status: "recording", ended_at: null, end_tick: null });
    const attest = createAttestor(store, "run-x");
    expect(attest({ ...snapshot(100, 0), attestation: clean })).toEqual([]);
    expect(readManifest(store, "run-x").assisted).toBe(false);
    expect(attest({ ...snapshot(200, 0), attestation: { ...clean, game_speed: 2 } })).toEqual(["game.speed is 2"]);
    expect(attest({ ...snapshot(300, 0), attestation: { ...clean, game_speed: 2, cheat_mode: true } }))
      .toEqual(["the Codex player's cheat_mode is true"]);
    expect(readManifest(store, "run-x").assisted).toBe(true);
    const events = fs.readFileSync(path.join(store, "run-run-x", "events.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
    expect(events.map((row) => [row.type, row.reason])).toEqual([["supervisor_intervention", "attestation: game.speed is 2"],
      ["supervisor_intervention", "attestation: the Codex player's cheat_mode is true"]]);
  });

  it("parses the mod's attestation and body time, empty Lua tables included", () => {
    const parsed = parseRunSnapshot({ ...snapshot(100, 1),
      attestation: { game_speed: 1, cheat_mode: false, controller: "character", physical_controller: "character", mods: [], bonuses: {} },
      body_time: { since_tick: 0, state: "idle", state_since: 0, ticks: [], gaps: [], phases: [], tiles: 0 } });
    expect(parsed.attestation).toMatchObject({ mods: {}, bonuses: [] });
    expect(parsed.body_time).toMatchObject({ ticks: {}, gaps: {}, phases: {}, tiles: 0 });
    // The waiting state and phase ticks of a 0.37 mod; older snapshots carry neither.
    expect(parseRunSnapshot({ ...snapshot(100, 1), body_time: { since_tick: 0, state: "waiting", state_since: 0,
      ticks: { waiting: 30, pilot: 60 }, gaps: [], phases: { walk: 40, craft_wait: 20 }, tiles: 12.5 } }).body_time)
      .toMatchObject({ state: "waiting", ticks: { waiting: 30 }, phases: { walk: 40, craft_wait: 20 }, tiles: 12.5 });
    expect(() => parseRunSnapshot({ ...snapshot(100, 1), body_time: { since_tick: 0, state: "idle", state_since: 0, ticks: [], gaps: [],
      phases: { walk: -1 } } })).toThrow();
    expect(() => parseRunSnapshot({ ...snapshot(100, 1), attestation: { ...clean, extra: 1 } })).toThrow();
  });

  it("parses the record the mod's run_snapshot sends, waiting state, phases and tiles included", () => {
    // Written by tests/mod/run_snapshot_test.lua from the real record (empty Lua tables as []).
    const fixture = JSON.parse(fs.readFileSync(new URL("../../tests/mod/fixtures/run-snapshot-0.37.json", import.meta.url), "utf8"));
    const parsed = parseRunSnapshot(structuredClone(fixture));
    expect(parsed.body_time).toMatchObject({ state: "waiting", ticks: { waiting: 20, pilot: 90 },
      phases: { walk: 60, mine: 10, smelt_wait: 5, craft_wait: 15, other: 20 }, tiles: 21.3 });
    // Ten more seconds waiting: a waiting state share, never a gap; the phases and tiles their deltas.
    const later = structuredClone(fixture);
    later.tick += 600;
    later.body_time.ticks.waiting += 600;
    later.body_time.phases.walk += 30;
    later.body_time.tiles += 4;
    expect(bodySummary(parsed, parseRunSnapshot(later))).toMatchObject({ window_ticks: 600, busy_share: 0,
      states: { waiting: { ticks: 600, share: 1 } }, phases: { walk: { ticks: 30, share: 0.05 } }, tiles: 4 });
    expect(bodySummary(parsed, parseRunSnapshot(later))?.gaps).toEqual({});
  });
});

describe("body time summary", () => {
  type BodyTime = NonNullable<RunSnapshot["body_time"]>;
  // The baseline at tick 600 marked the window unless a test says otherwise.
  const timed = (tick: number, ticks: Record<string, number>, gaps: BodyTime["gaps"], extra: Partial<BodyTime> = {}): RunSnapshot =>
    ({ ...snapshot(tick, 0), body_time: { since_tick: 0, window_tick: 600, state: "idle", state_since: tick, ticks, gaps, ...extra } });
  it("reports busy share and idle gaps by what ended them between the baseline and the final sample", () => {
    const baseline = timed(600, { idle: 500, pilot: 100 }, { pilot: { count: 1, ticks: 500, longest: 500, longest_end_tick: 500 } });
    const final = timed(72_600, { idle: 18_500, pilot: 30_100, package: 18_000, upkeep: 3_000, crafting: 2_400, hold: 600 }, {
      pilot: { count: 7, ticks: 9_500, longest: 6_000, longest_end_tick: 40_000 },
      package: { count: 4, ticks: 8_400, longest: 3_000, longest_end_tick: 30_000 },
      hold: { count: 1, ticks: 100, longest: 100, longest_end_tick: 500 } });
    // Upkeep keeps its row but is not busy: pilot, package and crafting are.
    expect(bodySummary(baseline, final)).toEqual({ window_ticks: 72_000, busy_share: 0.7,
      states: { crafting: { ticks: 2_400, share: 0.033 }, hold: { ticks: 600, share: 0.008 }, idle: { ticks: 18_000, share: 0.25 },
        package: { ticks: 18_000, share: 0.25 }, pilot: { ticks: 30_000, share: 0.417 }, upkeep: { ticks: 3_000, share: 0.042 } },
      gaps: { package: { count: 4, total_seconds: 140, mean_seconds: 35, longest_seconds: 50 },
        pilot: { count: 6, total_seconds: 150, mean_seconds: 25, longest_seconds: 100 },
        hold: { count: 1, total_seconds: 1.67, mean_seconds: 1.67, longest_seconds: null } } });
  });
  it("counts the gap open at the baseline from the baseline, and idle still open at the end as the gap open", () => {
    // Idle since tick 100 (before GO) at the baseline; the mod counts that gap from the window mark when it closes.
    const baseline = timed(600, { idle: 600 }, {}, { state_since: 100 });
    const final = timed(7_800, { idle: 600 + 300 + 1_200 + 1_800, pilot: 3_900 }, {
      pilot: { count: 2, ticks: 300 + 1_200, longest: 1_200, longest_end_tick: 3_000 } }, { state_since: 6_000 });
    expect(bodySummary(baseline, final)).toEqual({ window_ticks: 7_200, busy_share: 0.542,
      states: { idle: { ticks: 3_300, share: 0.458 }, pilot: { ticks: 3_900, share: 0.542 } },
      gaps: { pilot: { count: 2, total_seconds: 25, mean_seconds: 12.5, longest_seconds: 20 },
        open: { count: 1, total_seconds: 30, mean_seconds: 30, longest_seconds: 30 } } });
    // A longest gap that began before the baseline is not the window's.
    const straddled = timed(7_800, { idle: 3_300, pilot: 3_900 }, { pilot: { count: 1, ticks: 1_000, longest: 1_000, longest_end_tick: 900 } },
      { state: "pilot", state_since: 6_000 });
    expect(bodySummary(timed(600, {}, {}), straddled)?.gaps).toEqual({ pilot: { count: 1, total_seconds: 16.67,
      mean_seconds: 16.67, longest_seconds: null } });
    // Idle the whole window is one open gap.
    expect(bodySummary(baseline, timed(1_200, { idle: 1_200 }, {}, { state_since: 100 }))?.gaps)
      .toEqual({ open: { count: 1, total_seconds: 10, mean_seconds: 10, longest_seconds: 10 } });
  });
  it("reports plan phases and tiles walked in the window, and an open waiting stretch only as waiting time", () => {
    const baseline = timed(600, { pilot: 600 }, {}, { state: "pilot", phases: { walk: 400, other: 200 }, tiles: 50 });
    const final = timed(7_800, { pilot: 4_200, waiting: 600, idle: 3_000 }, {}, { state: "waiting", state_since: 7_200,
      phases: { walk: 2_200, mine: 600, smelt_wait: 300, craft_wait: 500, other: 600 }, tiles: 290.25 });
    expect(bodySummary(baseline, final)).toMatchObject({ window_ticks: 7_200,
      states: { waiting: { ticks: 600, share: 0.083 } },
      phases: { walk: { ticks: 1_800, share: 0.25 }, mine: { ticks: 600, share: 0.083 }, smelt_wait: { ticks: 300, share: 0.042 },
        craft_wait: { ticks: 500, share: 0.069 }, other: { ticks: 400, share: 0.056 } },
      tiles: 240.3 });
    expect(bodySummary(baseline, final)?.gaps).toEqual({});
    // Waiting is not busy; a mod without phases reports none.
    expect(bodySummary(baseline, final)?.busy_share).toBe(0.5);
    expect(bodySummary(timed(600, {}, {}), timed(1_200, { idle: 600 }, {}))).not.toHaveProperty("phases");
  });
  it("is kept in the run summary beside each role's time split", () => {
    const store = root(), body = bodySummary(timed(0, {}, {}, { window_tick: 0 }), timed(600, { idle: 300, pilot: 300 }, {}, { window_tick: 0 }));
    const telemetry = { roles: { pilot: { turns: 3, turn_ms: 9_000, model_ms: 5_000, tool_ms: 1_000, wait_ms: 2_000, compaction_ms: 1_000,
      model_calls: 4, mcp_calls: 6, compactions: 1, reasoning_items: 10, reasoning_summarized: 3 } }, body,
      milestones: { rocket_launched: { tick: 1_632_057, elapsed_s: 27_179.3 } }, holds: { count: 1, total_seconds: 5, recent: [] }, handler_errors: 0 };
    createRunStore(store, { ...manifest("run-t", "v"), telemetry });
    expect(readManifest(store, "run-t").telemetry).toEqual(telemetry);
    expect(body).toMatchObject({ busy_share: 0.5, gaps: {} });
    // A manifest from before 0.36 (tool_calls, no wait split) stays readable.
    const legacy = { roles: { pilot: { turns: 3, turn_ms: 9_000, model_ms: 6_000, tool_ms: 2_000, compaction_ms: 1_000,
      tool_calls: 4, compactions: 1 } }, body };
    createRunStore(store, { ...manifest("run-old", "v"), telemetry: legacy });
    expect(readManifest(store, "run-old").telemetry).toEqual(legacy);
  });

  it("has no summary without both counters from one save and the baseline's window", () => {
    expect(bodySummary(snapshot(100, 0), timed(200, {}, {}))).toBeNull();
    expect(bodySummary(timed(100, {}, {}), { ...timed(200, {}, {}), body_time: { ...timed(200, {}, {}).body_time, since_tick: 150 } })).toBeNull();
    // Without the baseline's window mark the gap open at GO would count its time before GO.
    expect(bodySummary(timed(600, {}, {}), timed(900, {}, {}, { window_tick: 300 }))).toBeNull();
  });
});

describe("run milestones, holds and handler faults", () => {
  it("parses the mod's fields, empty Lua tables included, and rejects unknown ones", () => {
    const parsed = parseRunSnapshot({ ...snapshot(100, 1), milestones: [], holds: { count: 0, total_ticks: 0, recent: {} }, handler_errors: 0 });
    expect(parsed).toMatchObject({ milestones: {}, holds: { count: 0, total_ticks: 0, recent: [] }, handler_errors: 0 });
    expect(parseRunSnapshot({ ...snapshot(100, 1), milestones: { rocket_ready_tick: 90, research: [] } }).milestones)
      .toEqual({ rocket_ready_tick: 90, research: {} });
    expect(() => parseRunSnapshot({ ...snapshot(100, 1), milestones: { rocket_landed_tick: 5 } })).toThrow();
    expect(() => parseRunSnapshot({ ...snapshot(100, 1), holds: { count: 1, total_ticks: 0, recent: [{ start_tick: 5, why: "x" }] } })).toThrow();
  });

  it("summarizes the final sample against the baseline: rocket ticks from GO, holds and faults in the window", () => {
    const baseline: RunSnapshot = { ...snapshot(1_299, 0), holds: { count: 2, total_ticks: 600, recent: [
      { start_tick: 100, end_tick: 400, cause: "movement" }, { start_tick: 500, end_tick: 800, cause: "mining" }] }, handler_errors: 3 };
    const final: RunSnapshot = { ...snapshot(1_635_153, 0),
      milestones: { rocket_ready_tick: 1_612_260, rocket_launch_ordered_tick: 1_631_000, rocket_launched_tick: 1_632_057,
        research: { automation: 5_000 } },
      holds: { count: 5, total_ticks: 600 + 1_536, recent: [{ start_tick: 500, end_tick: 800, cause: "mining" },
        { start_tick: 9_000, end_tick: 10_000, cause: "build" }, { start_tick: 20_000, end_tick: 20_536, cause: "movement" },
        { start_tick: 1_635_000, cause: "gui" }] },
      handler_errors: 4 };
    expect(runEvents(baseline, final)).toEqual({
      milestones: { rocket_ready: { tick: 1_612_260, elapsed_s: 26_849.35 }, rocket_launch_ordered: { tick: 1_631_000, elapsed_s: 27_161.68 },
        rocket_launched: { tick: 1_632_057, elapsed_s: 27_179.3 } },
      holds: { count: 3, total_seconds: 25.6, recent: [{ start_tick: 9_000, end_tick: 10_000, cause: "build" },
        { start_tick: 20_000, end_tick: 20_536, cause: "movement" }, { start_tick: 1_635_000, cause: "gui" }] },
      handler_errors: 1 });
    // The space milestones (mod 0.38 on) come the same way.
    const space = { platform_created_tick: 1_640_000, boarded_tick: 1_650_000, arrived_tick: 1_660_000, landed_tick: 1_660_600 };
    expect(parseRunSnapshot({ ...snapshot(1_700_000, 0), milestones: space }).milestones).toEqual(space);
    expect(runEvents(baseline, { ...snapshot(1_700_000, 0), milestones: space }).milestones).toEqual({
      platform_created: { tick: 1_640_000, elapsed_s: 27_311.68 }, boarded: { tick: 1_650_000, elapsed_s: 27_478.35 },
      arrived: { tick: 1_660_000, elapsed_s: 27_645.02 }, landed: { tick: 1_660_600, elapsed_s: 27_655.02 } });
    // Nothing yet: an empty milestones record; an older mod: no fields at all.
    expect(runEvents(baseline, { ...snapshot(2_000, 0), milestones: {} })).toEqual({ milestones: {} });
    expect(runEvents(snapshot(1, 0), snapshot(2, 0))).toEqual({});
    // Counters that fell come from another save: left out.
    expect(runEvents(baseline, { ...snapshot(2_000, 0), holds: { count: 1, total_ticks: 0, recent: [] }, handler_errors: 0 })).toEqual({});
  });
});

describe("tool outcomes", () => {
  function writeLedger(dir: string, id: string) {
    const priority = { objective: "o", strategic_reason: "r", completion_condition: "c", essential_prerequisite: null };
    fs.writeFileSync(path.join(dir, "operations.json"), JSON.stringify({ schema_version: 2,
      run: { id, release_sha: "a".repeat(40), baseline_save_sha256: "b".repeat(64), save_identity: "s", created_at: "2026-10-04T00:00:00Z",
        roles: { pilot: { model: "gpt-6-luna", reasoning: "low", fast: true }, strategist: { model: "gpt-6.1-sol", reasoning: "medium", fast: false } } },
      revision: 1, source_tick: 10, phase: "start", bottleneck: "iron", latest_measured_capacity: [],
      task_list: { NOW: priority, NEXT: priority, LATER: priority }, assumptions: [], build_packages: [] }));
  }
  const rows = (store: string, id: string) => fs.readFileSync(path.join(store, `run-${id}`, "tool_outcomes.jsonl"), "utf8")
    .trim().split("\n").map((line) => JSON.parse(line));

  it("states each result's status and code, whether the call succeeded, and its event", () => {
    expect(toolOutcome({ structuredContent: { status: "failed", code: "OUT_OF_REACH" }, isError: true }))
      .toEqual({ status: "failed", code: "OUT_OF_REACH", ok: false });
    expect(toolOutcome({ structuredContent: { tick: 3 } })).toEqual({ status: "ok", code: null, ok: true });
    expect(toolOutcome({ isError: true })).toEqual({ status: "failed", code: null, ok: false });
    // next_event's kind; a timeout or plan end is a successful call.
    expect(toolOutcome({ structuredContent: { event: "timeout", status: "completed", summary: "nothing happened in 60 s" } }))
      .toEqual({ status: "completed", code: null, ok: true, event: "timeout" });
    expect(toolOutcome({ structuredContent: { event: "plan_ended", status: "failed", summary: "plan 5 ended failed" } }))
      .toEqual({ status: "failed", code: null, ok: true, event: "plan_ended", summary: "plan 5 ended failed" });
  });

  it("keeps a failed call's text, cut to 200 characters, and never an ok row's", () => {
    const long = `Error: ambiguous production route for petroleum-gas: ${"x".repeat(300)}`;
    expect(toolOutcome({ content: [{ type: "text", text: "ignored" }], structuredContent: { status: "failed", code: "TOOL_ERROR", summary: long },
      isError: true })).toEqual({ status: "failed", code: "TOOL_ERROR", ok: false, summary: long.slice(0, 200) });
    expect(toolOutcome({ content: [{ type: "text", text: "boom" }], isError: true })).toEqual({ status: "failed", code: null, ok: false, summary: "boom" });
    expect(toolOutcome({ structuredContent: { status: "completed", summary: "done" } })).toEqual({ status: "completed", code: null, ok: true });
    expect(toolOutcome({ structuredContent: { status: "running", summary: "walking" } })).toEqual({ status: "running", code: null, ok: true });
  });

  it("takes a failed plan's code and error from its first outcome that did not complete", () => {
    const outcomes = [{ step: 1, action: "walk_to", status: "completed" },
      { step: 2, action: "get_items", status: "failed", code: "SUPPLY_SHORTFALL", error: "short 20 iron-plate" },
      { step: 3, action: "place_entity", status: "cancelled", code: "PLAN_CANCELLED" }];
    expect(toolOutcome({ structuredContent: { event: "plan_ended", status: "failed", summary: "plan 5 ended failed", outcomes } }))
      .toEqual({ status: "failed", code: "SUPPLY_SHORTFALL", ok: true, event: "plan_ended",
        summary: "plan 5 ended failed; SUPPLY_SHORTFALL: short 20 iron-plate" });
    // plan_status of a failed plan is isError; its own code wins.
    expect(toolOutcome({ structuredContent: { plan_id: 5, status: "partial", outcomes: outcomes.slice(1, 2) }, isError: true }))
      .toMatchObject({ status: "partial", code: "SUPPLY_SHORTFALL", ok: false, summary: "SUPPLY_SHORTFALL: short 20 iron-plate" });
    expect(toolOutcome({ structuredContent: { status: "failed", code: "PLAN_BUDGET_EXCEEDED", outcomes } }))
      .toMatchObject({ code: "PLAN_BUDGET_EXCEEDED" });
    // A completed plan keeps a quiet row.
    expect(toolOutcome({ structuredContent: { event: "plan_ended", status: "completed", summary: "plan 6 ended completed", outcomes: outcomes.slice(0, 1) } }))
      .toEqual({ status: "completed", code: null, ok: true, event: "plan_ended" });
  });

  it("keeps the text of package_failed and package_unmet events", () => {
    expect(toolOutcome({ structuredContent: { event: "package_failed", status: "completed", package_id: "p1",
      summary: "package p1 was not queued: check failed: blocked" } })).toEqual({ status: "completed", code: null, ok: true,
      event: "package_failed", summary: "package p1 was not queued: check failed: blocked" });
    expect(toolOutcome({ structuredContent: { event: "package_unmet", status: "completed", summary: "package p2 unmet: iron-plate 12/min < 30" } }))
      .toMatchObject({ event: "package_unmet", summary: "package p2 unmet: iron-plate 12/min < 30" });
    expect(toolOutcome({ structuredContent: { event: "package_verified", status: "completed", summary: "package p3 verified" } }))
      .not.toHaveProperty("summary");
  });

  it("records a failed dry run as not_ok with its code or its first failed row's", () => {
    const dry = { check_only: true, ok: false, failed: [{ code: "LAYOUT_OVERLAP", reason: "burner-inserter overlaps entities[0]" },
      { code: "BLOCKED" }] };
    expect(toolOutcome({ content: [{ type: "text", text: "structured result" }], structuredContent: dry }))
      .toEqual({ status: "not_ok", code: "LAYOUT_OVERLAP", ok: true, summary: "structured result; LAYOUT_OVERLAP: burner-inserter overlaps entities[0]" });
    expect(toolOutcome({ structuredContent: { ...dry, code: "SEARCH_BUDGET", summary: "no placement" } }))
      .toEqual({ status: "not_ok", code: "SEARCH_BUDGET", ok: true, summary: "no placement; LAYOUT_OVERLAP: burner-inserter overlaps entities[0]" });
    // A passed dry run, and a status that says more than ok, stay as they were.
    expect(toolOutcome({ structuredContent: { check_only: true, ok: true, failed: [] } })).toEqual({ status: "ok", code: null, ok: true });
    expect(toolOutcome({ structuredContent: { status: "queued", ok: false } })).toMatchObject({ status: "queued", code: null });
  });

  it("takes a refused placement's code from its first collision", () => {
    const refused = { check_only: true, blueprint: "smelter", ok: false,
      collisions: [{ index: 3, code: "BLOCKED", reason: "stone-furnace blocked by a tree" }, { index: 4, code: "UNCHARTED" }] };
    expect(toolOutcome({ content: [{ type: "text", text: "blocked" }], structuredContent: refused }))
      .toEqual({ status: "not_ok", code: "BLOCKED", ok: true, summary: "blocked; BLOCKED: stone-furnace blocked by a tree" });
    // Its own code still wins; a placement that went through keeps no collision code.
    expect(toolOutcome({ structuredContent: { ...refused, code: "ITEM_UNOBTAINABLE" } })).toMatchObject({ code: "ITEM_UNOBTAINABLE" });
    expect(toolOutcome({ structuredContent: { ...refused, ok: true } })).toEqual({ status: "ok", code: null, ok: true });
  });

  it("appends one row per call beside the samples of the ledger's run, and only while that run directory exists", async () => {
    const dir = root(), store = root();
    writeLedger(dir, "run-7");
    const log = createToolOutcomeLog(() => dir, "pilot", () => store);
    await log.record("observe_local", 12.4, { structuredContent: { tick: 5 } });
    expect(fs.existsSync(path.join(store, "run-run-7"))).toBe(false);
    createRunStore(store, { ...manifest("run-7", "v"), status: "recording", ended_at: null, end_tick: null });
    void log.record("queue_plan", 3, { structuredContent: { status: "queued" } }, new Date("2026-10-04T10:00:00Z"));
    await log.record("run_plan", 1500.6, { structuredContent: { status: "failed", code: "STEP_STALLED" }, isError: true },
      new Date("2026-10-04T10:00:01Z"));
    expect(rows(store, "run-7")).toEqual([
      { at: "2026-10-04T10:00:00.000Z", role: "pilot", tool: "queue_plan", status: "queued", code: null, ok: true, duration_ms: 3 },
      { at: "2026-10-04T10:00:01.000Z", role: "pilot", tool: "run_plan", status: "failed", code: "STEP_STALLED", ok: false, duration_ms: 1501 }]);
    // No run directory pointer, or a ledger without a run: nothing written, nothing thrown.
    await createToolOutcomeLog(() => null, "pilot", () => store).record("x", 1, {});
    await createToolOutcomeLog(() => { throw new Error("pointer unreadable"); }, "pilot", () => store).record("x", 1, {});
    expect(rows(store, "run-7")).toHaveLength(2);
  });

  it("stops at the size cap", async () => {
    const dir = root(), store = root();
    writeLedger(dir, "run-8");
    createRunStore(store, { ...manifest("run-8", "v"), status: "recording", ended_at: null, end_tick: null });
    const file = path.join(store, "run-run-8", "tool_outcomes.jsonl");
    fs.writeFileSync(file, "x".repeat(TOOL_OUTCOMES_MAX_BYTES - 10));
    await createToolOutcomeLog(() => dir, "pilot", () => store).record("observe_local", 1, {});
    expect(fs.statSync(file).size).toBe(TOOL_OUTCOMES_MAX_BYTES - 10);
  });

  it("is written by every registered MCP tool without changing its result", async () => {
    const dir = root(), store = root();
    writeLedger(dir, "run-9");
    createRunStore(store, { ...manifest("run-9", "v"), status: "recording", ended_at: null, end_tick: null });
    const handlers: Record<string, (args: unknown) => Promise<any>> = {};
    const call = async (method: string) => { if (method === "factory_status") return { tick: 9, lines: [] }; throw new Error(`unexpected ${method}`); };
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler as never; } }, async () => ({ call } as unknown as Bridge),
      () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } }) as never,
      "read-only", () => dir, "strategist", () => store);
    const value = await handlers.factory_status!({});
    expect(value.structuredContent).toMatchObject({ tick: 9 });
    await vi.waitFor(() => expect(rows(store, "run-9")[0]).toMatchObject({ role: "strategist", tool: "factory_status", status: "ok", code: null, ok: true }));
    // A tool error keeps its message, which carries the cause.
    const failed = await handlers.production_requirements!({ item: "rocket-silo", per_min: 1 });
    expect(failed.isError).toBe(true);
    await vi.waitFor(() => expect(rows(store, "run-9")[1]).toMatchObject({ tool: "production_requirements", status: "failed",
      code: "TOOL_ERROR", ok: false, summary: expect.stringContaining("unexpected production_requirements") }));
  });
});
