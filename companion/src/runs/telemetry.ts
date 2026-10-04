import fs from "node:fs";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { z } from "zod";
import { Bridge } from "../bridge.js";
import { assertConnectionCompatibility, assertRuntimeCompatibility } from "../compatibility.js";
import { companionVersion, dataDir, loadConfig } from "../config.js";
import { operationsLedgerSchema } from "../coordination/ledger.js";
import { RconClient } from "../rcon.js";
import { atomicWriteFile } from "../setup/atomic.js";
import { createThoughtFeed, type ThoughtFeed, type ThoughtRole } from "./thoughts.js";

const countRow = z.object({ name: z.string(), count: z.number() }).strict();
const resourceName = z.object({ type: z.enum(["item", "fluid"]), name: z.string() }).strict();
export const runSnapshotSchema = z.object({
  tick: z.number().int().nonnegative(), character: z.record(z.string(), z.unknown()),
  progression: z.record(z.string(), z.unknown()), factory: z.record(z.string(), z.unknown()),
  lines: z.object({ line_count: z.number().int().nonnegative(), running_line_count: z.number().int().nonnegative(),
    self_sustaining_line_count: z.number().int().nonnegative(), hand_fed_line_count: z.number().int().nonnegative() }).strict().optional(),
  statistics: z.object({
    items: z.object({ produced: z.array(countRow), consumed: z.array(countRow), unavailable: z.boolean().optional() }).strict(),
    fluids: z.object({ produced: z.array(countRow), consumed: z.array(countRow), unavailable: z.boolean().optional() }).strict(),
    raw_resources: z.array(resourceName),
    semantics: z.object({ produced: z.literal("force_surface_input_counts"), consumed: z.literal("force_surface_output_counts") }).strict(),
  }).strict(),
}).strict();
export type RunSnapshot = z.infer<typeof runSnapshotSchema>;

function luaArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : value && typeof value === "object" && Object.keys(value).length === 0 ? [] : value as unknown[];
}
export function parseRunSnapshot(value: any): RunSnapshot {
  if (value?.statistics) {
    for (const kind of ["items", "fluids"]) {
      if (value.statistics[kind]) {
        value.statistics[kind].produced = luaArray(value.statistics[kind].produced);
        value.statistics[kind].consumed = luaArray(value.statistics[kind].consumed);
      }
    }
    value.statistics.raw_resources = luaArray(value.statistics.raw_resources);
  }
  // Lua omits a nil standing_on; a sample always states it.
  if (value?.character && typeof value.character === "object" && value.character.standing_on === undefined) value.character.standing_on = null;
  return runSnapshotSchema.parse(value);
}

// A manifest keeps the role profiles its run recorded, so runs from earlier
// role pairs stay readable; only a new ledger pins the current pair.
const recordedRole = z.object({ model: z.string().min(1).max(80), reasoning: z.string().min(1).max(40),
  fast: z.boolean().optional() }).strict();
const manifestSchema = z.object({
  schema_version: z.literal(1), run: operationsLedgerSchema.shape.run.extend({
    roles: z.object({ pilot: recordedRole, strategist: recordedRole }).strict() }),
  variant: z.string().min(1), change: z.string().min(1), kind: z.enum(["debug", "benchmark"]),
  status: z.enum(["recording", "finished", "interrupted"]), assisted: z.boolean(),
  app_version: z.string(), mod_version: z.string(), factorio_version: z.string(),
  started_at: z.string(), start_tick: z.number().int().nonnegative(),
  ended_at: z.string().nullable(), end_tick: z.number().int().nonnegative().nullable(),
}).strict();
export type RunManifest = z.infer<typeof manifestSchema>;

const deltaRows = z.array(z.object({ name: z.string(), produced: z.number(), consumed: z.number() }).strict());
export const sampleSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("ok"), kind: z.enum(["baseline", "checkpoint", "final"]),
    scheduled_elapsed_ms: z.number().nonnegative(), actual_elapsed_ms: z.number().nonnegative(),
    capture_started_at: z.string(), capture_completed_at: z.string(), capture_latency_ms: z.number().nonnegative(),
    tick: z.number().int().nonnegative(), tick_delta: z.number().int(), snapshot: runSnapshotSchema,
    delta: z.object({ items: deltaRows, fluids: deltaRows,
      raw_resources: z.array(z.object({ type: z.enum(["item", "fluid"]), name: z.string(), produced: z.number(), consumed: z.number() }).strict()) }).strict(),
  }).strict(),
  z.object({ status: z.literal("error"), kind: z.enum(["checkpoint", "final"]),
    scheduled_elapsed_ms: z.number().nonnegative(), actual_elapsed_ms: z.number().nonnegative(),
    capture_started_at: z.string(), capture_completed_at: z.string(), capture_latency_ms: z.number().nonnegative(),
    error: z.string().min(1),
  }).strict(),
]);
export type RunSample = z.infer<typeof sampleSchema>;

function rowsMap(rows: Array<{ name: string; count: number }>): Map<string, number> {
  return new Map(rows.map((row) => [row.name, row.count]));
}

function counterDelta(current: RunSnapshot["statistics"]["items"], baseline: RunSnapshot["statistics"]["items"]): Array<{ name: string; produced: number; consumed: number }> {
  const cp = rowsMap(current.produced), cc = rowsMap(current.consumed);
  const bp = rowsMap(baseline.produced), bc = rowsMap(baseline.consumed);
  const names = [...new Set([...cp.keys(), ...cc.keys(), ...bp.keys(), ...bc.keys()])].sort();
  return names.map((name) => ({ name, produced: (cp.get(name) ?? 0) - (bp.get(name) ?? 0),
    consumed: (cc.get(name) ?? 0) - (bc.get(name) ?? 0) }))
    .filter((row) => row.produced !== 0 || row.consumed !== 0);
}

export function snapshotDelta(current: RunSnapshot, baseline: RunSnapshot) {
  const items = counterDelta(current.statistics.items, baseline.statistics.items);
  const fluids = counterDelta(current.statistics.fluids, baseline.statistics.fluids);
  const byKind = { item: new Map(items.map((row) => [row.name, row])), fluid: new Map(fluids.map((row) => [row.name, row])) };
  const raw = new Map<string, { type: "item" | "fluid"; name: string }>();
  for (const row of [...baseline.statistics.raw_resources, ...current.statistics.raw_resources]) raw.set(`${row.type}\0${row.name}`, row);
  return { items, fluids, raw_resources: [...raw.values()].sort((a, b) => a.type.localeCompare(b.type) || a.name.localeCompare(b.name))
    .map((row) => ({ ...row, produced: byKind[row.type].get(row.name)?.produced ?? 0,
      consumed: byKind[row.type].get(row.name)?.consumed ?? 0 })) };
}

export function runRoot(root = path.join(dataDir(), "runs")): string { return root; }
function runPaths(root: string, id: string) {
  const dir = path.join(root, `run-${encodeURIComponent(id)}`);
  return { dir, manifest: path.join(dir, "manifest.json"), samples: path.join(dir, "samples.jsonl"), events: path.join(dir, "events.jsonl"),
    thoughts: path.join(dir, "thoughts.jsonl") };
}
function writeManifest(file: string, manifest: RunManifest): void {
  atomicWriteFile(file, `${JSON.stringify(manifest, null, 2)}\n`, 0o600);
}
function appendJson(file: string, value: unknown): void { fs.appendFileSync(file, `${JSON.stringify(value)}\n`, { encoding: "utf8", mode: 0o600 }); }

export function createRunStore(root: string, manifest: RunManifest): ReturnType<typeof runPaths> {
  const files = runPaths(root, manifest.run.id);
  fs.mkdirSync(files.dir, { recursive: true });
  const sampleFd = fs.openSync(files.samples, "wx", 0o600); fs.closeSync(sampleFd);
  const eventFd = fs.openSync(files.events, "wx", 0o600); fs.closeSync(eventFd);
  writeManifest(files.manifest, manifest);
  return files;
}

export function readManifest(root: string, id: string): RunManifest {
  return manifestSchema.parse(JSON.parse(fs.readFileSync(runPaths(root, id).manifest, "utf8")));
}
export function readSamples(root: string, id: string): RunSample[] {
  const text = fs.readFileSync(runPaths(root, id).samples, "utf8");
  return text.split("\n").filter(Boolean).map((line) => sampleSchema.parse(JSON.parse(line)));
}

export function markRunAssisted(root: string, id: string, reason: string, at = new Date()): void {
  if (!reason.trim()) throw new Error("mark-assisted requires a non-empty reason");
  const files = runPaths(root, id), manifest = readManifest(root, id);
  appendJson(files.events, { type: "supervisor_intervention", at: at.toISOString(), reason });
  writeManifest(files.manifest, { ...manifest, assisted: true });
}

/** Resolves a role's rollout file from <run_dir>/rollouts.json. Only an absent
 *  pointer file falls back to the launch flag; any other read or parse error
 *  (for example a partly written file) returns null, which keeps the file the
 *  feed already follows instead of switching back to a retired session. */
export function rolloutResolver(pointer: string, role: ThoughtRole, flag: string | undefined): () => string | null {
  return () => {
    let text: string;
    try { text = fs.readFileSync(pointer, "utf8"); }
    catch (error) { return (error as NodeJS.ErrnoException)?.code === "ENOENT" ? flag ?? null : null; }
    try {
      const value = JSON.parse(text)?.[role];
      return typeof value === "string" && value ? value : flag ?? null;
    } catch { return null; }
  };
}

export interface RecordRunOptions { ledger: string; variant: string; change: string; kind: "debug" | "benchmark"; root?: string;
  pilotRollout?: string; strategistRollout?: string }
export function checkpointDelay(checkpoint: number, elapsedMs: number): number {
  return Math.max(0, checkpoint * 300_000 - elapsedMs);
}
export async function recordRun(options: RecordRunOptions): Promise<void> {
  const config = loadConfig();
  if (!config) throw new Error("configuration is missing or invalid; run `factorio-codex setup`");
  const ledger = operationsLedgerSchema.parse(JSON.parse(fs.readFileSync(options.ledger, "utf8")));
  assertConnectionCompatibility(config.rcon);
  const rcon = new RconClient(config.rcon), bridge = new Bridge(rcon);
  let feed: ThoughtFeed | undefined;
  try {
  await rcon.connect(); await bridge.unlock();
  const ping = await bridge.call<any>("ping"); assertRuntimeCompatibility(ping, companionVersion());
  if (!ping.companion_exists) throw new Error("native player 'Codex' must have a living character before GO");
  const baseline = parseRunSnapshot(await bridge.call("run_snapshot"));
  const startedAt = new Date(), startedMono = performance.now(), root = runRoot(options.root);
  let manifest: RunManifest = { schema_version: 1, run: ledger.run, variant: options.variant, change: options.change,
    kind: options.kind, status: "recording", assisted: false, app_version: companionVersion(),
    mod_version: ping.mod_version, factorio_version: ping.factorio_version, started_at: startedAt.toISOString(),
    start_tick: baseline.tick, ended_at: null, end_tick: null };
  const files = createRunStore(root, manifest);
  const baselineSample: RunSample = { status: "ok", kind: "baseline", scheduled_elapsed_ms: 0, actual_elapsed_ms: 0,
    capture_started_at: startedAt.toISOString(), capture_completed_at: startedAt.toISOString(), capture_latency_ms: 0,
    tick: baseline.tick, tick_delta: 0, snapshot: baseline, delta: snapshotDelta(baseline, baseline) };
  appendJson(files.samples, baselineSample);
  console.log(`GO ${manifest.started_at} tick=${manifest.start_tick} run=${manifest.run.id}`);
  // <run_dir>/rollouts.json ({"luna": path, "astra": path}), which the
  // supervisor rewrites when it replaces a role session, overrides the flags.
  const pointer = path.join(path.dirname(options.ledger), "rollouts.json");
  const rollout = (role: ThoughtRole, flag: string | undefined) => rolloutResolver(pointer, role, flag);
  const sources = ([["luna", options.pilotRollout], ["astra", options.strategistRollout]] as const)
    .map(([role, flag]) => ({ role, file: rollout(role, flag) }));
  const nowObjective = () => {
    try { return operationsLedgerSchema.parse(JSON.parse(fs.readFileSync(options.ledger, "utf8"))).task_list.NOW.objective; }
    catch { return null; }
  };
  feed = createThoughtFeed({ sources, out: files.thoughts, say: (role, text) => bridge.call("say", { role, text }),
    now: { read: nowObjective, say: (text) => bridge.call("say_now", { text }) } });

  let nextCheckpoint = 1, finishing = false, timer: NodeJS.Timeout | undefined, chain = Promise.resolve();
  const capture = async (kind: "checkpoint" | "final", scheduled: number): Promise<RunSample> => {
    const captureStart = new Date(), before = performance.now();
    try {
      const snapshot = parseRunSnapshot(await bridge.call("run_snapshot"));
      const after = performance.now();
      return { status: "ok", kind, scheduled_elapsed_ms: scheduled, actual_elapsed_ms: after - startedMono,
        capture_started_at: captureStart.toISOString(), capture_completed_at: new Date().toISOString(), capture_latency_ms: after - before,
        tick: snapshot.tick, tick_delta: snapshot.tick - baseline.tick, snapshot, delta: snapshotDelta(snapshot, baseline) };
    } catch (error) {
      const after = performance.now();
      return { status: "error", kind, scheduled_elapsed_ms: scheduled, actual_elapsed_ms: after - startedMono,
        capture_started_at: captureStart.toISOString(), capture_completed_at: new Date().toISOString(), capture_latency_ms: after - before,
        error: error instanceof Error ? error.message : String(error) };
    }
  };
  const schedule = () => {
    const deadline = nextCheckpoint * 300_000;
    timer = setTimeout(() => {
      const scheduled = deadline; nextCheckpoint += 1;
      chain = chain.then(async () => { const sample = await capture("checkpoint", scheduled); appendJson(files.samples, sample);
        console.log(sample.status === "ok" ? `CHECKPOINT +${scheduled / 60_000}m tick=${sample.tick}` : `CHECKPOINT +${scheduled / 60_000}m ERROR ${sample.error}`); });
      if (!finishing) schedule();
    }, checkpointDelay(nextCheckpoint, performance.now() - startedMono));
  };
  schedule();

  await new Promise<void>((resolve) => {
    const finish = () => { if (finishing) return; finishing = true; if (timer) clearTimeout(timer); resolve(); };
    process.once("SIGINT", finish); process.once("SIGTERM", finish);
  });
  await chain;
  feed?.stop(); feed = undefined;
  const final = await capture("final", performance.now() - startedMono); appendJson(files.samples, final);
  const currentManifest = readManifest(root, manifest.run.id);
  manifest = { ...manifest, assisted: currentManifest.assisted,
    status: final.status === "ok" ? "finished" : "interrupted", ended_at: new Date().toISOString(),
    end_tick: final.status === "ok" ? final.tick : null };
  writeManifest(files.manifest, manifest);
  console.log(`FINISH ${manifest.ended_at} run=${manifest.run.id} status=${manifest.status}`);
  } finally {
    feed?.stop();
    rcon.close();
  }
}

function rawMap(sample: Extract<RunSample, { status: "ok" }>): Map<string, number> {
  return new Map(sample.delta.raw_resources.map((row) => [`${row.type}:${row.name}`, row.produced]));
}
export type ResourceVerdict = "improved" | "worse" | "equal" | "mixed";
export function resourceVerdict(a: Extract<RunSample, { status: "ok" }>, b: Extract<RunSample, { status: "ok" }>): ResourceVerdict {
  const av = rawMap(a), bv = rawMap(b), names = new Set([...av.keys(), ...bv.keys()]);
  let higher = false, lower = false;
  for (const name of names) { const delta = (bv.get(name) ?? 0) - (av.get(name) ?? 0); if (delta > 0) higher = true; if (delta < 0) lower = true; }
  if (higher && lower) return "mixed"; if (higher) return "improved"; if (lower) return "worse"; return "equal";
}

export function compareRuns(root: string, baselineId: string, candidateId: string) {
  const baseline = readManifest(root, baselineId), candidate = readManifest(root, candidateId);
  const reasons: string[] = [];
  if (baseline.run.baseline_save_sha256 !== candidate.run.baseline_save_sha256) reasons.push("baseline save hashes differ");
  for (const [label, value] of [["baseline", baseline], ["candidate", candidate]] as const) {
    if (value.kind !== "benchmark") reasons.push(`${label} is not a benchmark run`);
    if (value.status !== "finished") reasons.push(`${label} is not finished`);
    if (value.assisted) reasons.push(`${label} was assisted`);
  }
  const a = readSamples(root, baselineId).filter((s): s is Extract<RunSample, { status: "ok" }> => s.status === "ok" && s.kind === "checkpoint");
  const b = readSamples(root, candidateId).filter((s): s is Extract<RunSample, { status: "ok" }> => s.status === "ok" && s.kind === "checkpoint");
  const byScheduled = new Map(b.map((sample) => [sample.scheduled_elapsed_ms, sample]));
  let previousA = new Map<string, number>(), previousB = new Map<string, number>();
  const checkpoints = a.flatMap((left) => { const right = byScheduled.get(left.scheduled_elapsed_ms); if (!right) return [];
    const leftRaw = rawMap(left), rightRaw = rawMap(right), names = new Set([...leftRaw.keys(), ...rightRaw.keys()]);
    const resources = [...names].sort().map((name) => {
      const av = leftRaw.get(name) ?? 0, bv = rightRaw.get(name) ?? 0;
      const ai = av - (previousA.get(name) ?? 0), bi = bv - (previousB.get(name) ?? 0);
      return { resource: name, baseline: av, candidate: bv, delta: bv - av,
        interval_baseline: ai, interval_candidate: bi, interval_delta: bi - ai,
        percent: av === 0 ? (bv === 0 ? 0 : null) : (bv - av) / av * 100 };
    });
    previousA = leftRaw; previousB = rightRaw;
    const context = (sample: typeof left) => {
      const progression = sample.snapshot.progression as any, factory = sample.snapshot.factory as any;
      return { machine_count: typeof factory.machine_count === "number" ? factory.machine_count : null,
        researched_count: Array.isArray(progression.researched) ? progression.researched.length : null,
        power: factory.power ?? null,
        character_transfer_actions: typeof factory.character_transfers?.transfer_actions === "number"
          ? factory.character_transfers.transfer_actions : null };
    };
    return [{ elapsed_minutes: left.scheduled_elapsed_ms / 60_000, verdict: resourceVerdict(left, right), resources,
      context: { baseline: context(left), candidate: context(right) } }]; });
  if (checkpoints.length === 0) reasons.push("no common successful five-minute checkpoints");
  const rawVerdicts = new Set(checkpoints.map((row) => row.verdict).filter((v) => v !== "equal"));
  const descriptive = rawVerdicts.size === 0 ? "equal" : rawVerdicts.size === 1 ? [...rawVerdicts][0]! : "mixed";
  return { eligible: reasons.length === 0, reasons, verdict: reasons.length === 0 ? descriptive : "ineligible",
    descriptive_verdict: descriptive,
    baseline: { id: baselineId, variant: baseline.variant, change: baseline.change, release_sha: baseline.run.release_sha },
    candidate: { id: candidateId, variant: candidate.variant, change: candidate.change, release_sha: candidate.run.release_sha }, checkpoints };
}

export function renderComparison(comparison: ReturnType<typeof compareRuns>): string {
  const lines = [`${comparison.baseline.variant} (${comparison.baseline.id}, ${comparison.baseline.release_sha.slice(0, 12)}) → ${comparison.candidate.variant} (${comparison.candidate.id}, ${comparison.candidate.release_sha.slice(0, 12)})`,
    `Changes: ${comparison.baseline.change} → ${comparison.candidate.change}`,
    `Verdict: ${comparison.verdict}${comparison.reasons.length ? ` — ${comparison.reasons.join("; ")}` : ""}`];
  for (const checkpoint of comparison.checkpoints) {
    lines.push(`\n+${checkpoint.elapsed_minutes}m: ${checkpoint.verdict}`, "resource                         baseline  candidate  delta  interval Δ      change");
    for (const row of checkpoint.resources) lines.push(`${row.resource.padEnd(32)} ${String(row.baseline).padStart(8)} ${String(row.candidate).padStart(10)} ${String(row.delta).padStart(6)} ${String(row.interval_delta).padStart(11)} ${row.percent === null ? "      new" : `${row.percent.toFixed(1)}%`.padStart(10)}`);
    lines.push(`context: ${JSON.stringify(checkpoint.context.baseline)} → ${JSON.stringify(checkpoint.context.candidate)}`);
  }
  return lines.join("\n");
}
