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
import { readLedger, type RunDir } from "../coordination/orders.js";
import { BUILT_IN_MODS } from "../server/server.js";
import { createThoughtFeed, createTimeSplit, type ThoughtFeed, type ThoughtRole } from "./thoughts.js";
import { roleProfiles, runRolesSchema } from "./profiles.js";
import { BENCHMARK_SECONDS, benchmarkEvidenceSchema, cutoffIssues } from "./benchmark.js";

const countRow = z.object({ name: z.string(), count: z.number() }).strict();
const resourceName = z.object({ type: z.enum(["item", "fluid"]), name: z.string() }).strict();
const counters = z.object({ produced: z.array(countRow), consumed: z.array(countRow), unavailable: z.boolean().optional() }).strict();
const snapshotBodySchema = z.object({ state: z.string(), surface_ref: z.string().optional(), platform_name: z.string().optional(),
  rebind_refused: z.object({ tick: z.number().int().nonnegative(), characters: z.number().int().nonnegative() }).strict().optional(),
}).strict();
const whole = z.number().int().nonnegative();
/** What the body did by state, cumulative since since_tick (mod tasks.body_time). */
export const bodyTimeSchema = z.object({ since_tick: whole,
  /** The recorder baseline's mark: a gap open then counts from here when it closes. */
  window_tick: whole.optional(), state: z.string(), state_since: whole,
  ticks: z.record(z.string(), whole),
  /** Idle gaps by the state that ended them. */
  gaps: z.record(z.string(), z.object({ count: whole, ticks: whole, longest: whole,
    longest_end_tick: whole.optional() }).strict()),
}).strict();
/** Facts for an unassisted run; bonuses lists only modifiers research does not explain. */
export const attestationSchema = z.object({ game_speed: z.number().optional(), cheat_mode: z.boolean().optional(),
  controller: z.string().optional(), physical_controller: z.string().optional(),
  mods: z.record(z.string(), z.string()),
  bonuses: z.array(z.object({ scope: z.enum(["force", "character"]), name: z.string(), value: z.number(),
    from_research: z.number() }).strict()),
}).strict();
export type RunAttestation = z.infer<typeof attestationSchema>;
export const runSnapshotSchema = z.object({
  // null while the body is aboard a platform or in a cargo pod without a readable character (mod 0.22.3 on).
  tick: z.number().int().nonnegative(), character: z.record(z.string(), z.unknown()).nullable(),
  /** Where the body is (mod 0.22.3 on). */
  body: snapshotBodySchema.optional(),
  progression: z.record(z.string(), z.unknown()), factory: z.record(z.string(), z.unknown()),
  // Async get_job adds its FIFO readback; direct and historical samples may omit it.
  fifo: z.object({ active_plan_id: z.number().int().positive().optional(),
    queue_depth: z.number().int().nonnegative(), idle_seconds: z.number().int().nonnegative().optional(),
    human_control: z.boolean(), human_idle_ticks: z.number().int().nonnegative().optional(),
    body: snapshotBodySchema.extend({ bound_for: z.string().optional() }).strict(),
  }).strict().optional(),
  lines: z.object({ line_count: z.number().int().nonnegative(), running_line_count: z.number().int().nonnegative(),
    self_sustaining_line_count: z.number().int().nonnegative(), hand_fed_line_count: z.number().int().nonnegative() }).strict().optional(),
  /** Absent from samples recorded before the mod reported them. */
  body_time: bodyTimeSchema.optional(),
  attestation: attestationSchema.optional(),
  statistics: z.object({
    /** Summed over every surface with own buildings (from mod 0.22.3; the body's surface before). */
    items: counters,
    fluids: counters,
    /** The same counters per surface (mod 0.22.3 on). */
    by_surface: z.record(z.string(), z.object({ items: counters, fluids: counters }).strict()).optional(),
    raw_resources: z.array(resourceName),
    /** Items the Codex player hand-crafted since since_tick, cumulative (mod 0.22.0 on). */
    hand_crafted: z.object({ since_tick: z.number().int().nonnegative(), items: z.array(countRow) }).strict().optional(),
    semantics: z.object({ produced: z.literal("force_surface_input_counts"), consumed: z.literal("force_surface_output_counts"),
      items: z.literal("summed_over_factory_surfaces").optional() }).strict(),
  }).strict(),
}).strict();
export type RunSnapshot = z.infer<typeof runSnapshotSchema>;

function luaArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : value && typeof value === "object" && Object.keys(value).length === 0 ? [] : value as unknown[];
}
function counterLists(counts: any): void {
  if (!counts) return;
  counts.produced = luaArray(counts.produced);
  counts.consumed = luaArray(counts.consumed);
}
export function parseRunSnapshot(value: any): RunSnapshot {
  if (value?.statistics) {
    for (const kind of ["items", "fluids"]) counterLists(value.statistics[kind]);
    // An empty Lua table is a record here; each surface's counters are lists.
    if (Array.isArray(value.statistics.by_surface) && value.statistics.by_surface.length === 0) value.statistics.by_surface = {};
    for (const row of Object.values(value.statistics.by_surface ?? {}) as any[]) for (const kind of ["items", "fluids"]) counterLists(row?.[kind]);
    value.statistics.raw_resources = luaArray(value.statistics.raw_resources);
    if (value.statistics.hand_crafted) value.statistics.hand_crafted.items = luaArray(value.statistics.hand_crafted.items);
  }
  // An empty Lua table is a list here; these are records (and bonuses a list).
  const record = (holder: any, key: string) => { if (Array.isArray(holder?.[key]) && holder[key].length === 0) holder[key] = {}; };
  record(value?.body_time, "ticks"); record(value?.body_time, "gaps"); record(value?.attestation, "mods");
  if (value?.attestation) value.attestation.bonuses = luaArray(value.attestation.bonuses);
  // Lua omits a nil character (the body away) and standing_on; a sample always states them.
  if (value && typeof value === "object" && value.character === undefined) value.character = null;
  if (value?.character && typeof value.character === "object" && value.character.standing_on === undefined) value.character.standing_on = null;
  return runSnapshotSchema.parse(value);
}

/** Mods a run may have active: the game's own set and the companion. */
export const ALLOWED_MODS = [...BUILT_IN_MODS, "agentic-companion"] as const;
const BYPASS_CONTROLLERS = new Set(["editor", "god"]);
/** Each attested fact that differs from an unassisted run: game speed other
 *  than 1, cheat mode not off, an editor or god controller, a mod outside
 *  ALLOWED_MODS, or a modifier above what research grants. */
export function attestationIssues(attestation: RunAttestation | undefined): string[] {
  if (!attestation) return ["the snapshot carries no attestation"];
  const issues: string[] = [];
  if (attestation.game_speed !== 1) issues.push(`game.speed is ${attestation.game_speed ?? "unreadable"}`);
  if (attestation.cheat_mode !== false) issues.push(`the Codex player's cheat_mode is ${attestation.cheat_mode ?? "unreadable"}`);
  for (const [label, name] of [["controller", attestation.controller], ["physical controller", attestation.physical_controller]] as const)
    if (name && BYPASS_CONTROLLERS.has(name)) issues.push(`the Codex player's ${label} is ${name}`);
  for (const [name, version] of Object.entries(attestation.mods).sort(([a], [b]) => a.localeCompare(b)))
    if (!(ALLOWED_MODS as readonly string[]).includes(name)) issues.push(`mod ${name} ${version} is active`);
  for (const row of attestation.bonuses) if (row.value > row.from_research + 1e-9)
    issues.push(`${row.scope} ${row.name} is ${row.value}; research grants ${row.from_research}`);
  return issues;
}

const timeSplitSchema = z.object({ turns: whole, turn_ms: z.number().nonnegative(), model_ms: z.number().nonnegative(),
  tool_ms: z.number().nonnegative(), compaction_ms: z.number().nonnegative(), tool_calls: whole, compactions: whole }).strict();
const shareRow = z.object({ ticks: whole, share: z.number().nonnegative() }).strict();
const bodySummarySchema = z.object({ window_ticks: whole, busy_share: z.number().nonnegative(),
  states: z.record(z.string(), shareRow),
  gaps: z.record(z.string(), z.object({ count: whole, total_seconds: z.number().nonnegative(),
    mean_seconds: z.number().nonnegative(), longest_seconds: z.number().nonnegative().nullable() }).strict()),
}).strict();
/** The run summary's telemetry: each role's time split from its rollout and
 *  the body's time by state between the baseline and final samples. */
const runTelemetrySchema = z.object({ roles: z.record(z.string(), timeSplitSchema), body: bodySummarySchema.nullable() }).strict();
const BUSY_STATES = ["pilot", "package", "upkeep", "crafting"];
const round = (value: number, digits = 3) => Math.round(value * 10 ** digits) / 10 ** digits;
const gapRow = (count: number, ticks: number, longest: number | null) => ({ count, total_seconds: round(ticks / 60, 2),
  mean_seconds: round(ticks / count / 60, 2), longest_seconds: longest === null ? null : round(longest / 60, 2) });
/** Body-busy share and idle gaps between two snapshots: the counters' deltas.
 *  The baseline marked the window, so the gap open then counts only from
 *  the baseline; a gap's longest counts only when it lies inside the window,
 *  and idle still open at the final sample is the gap "open". */
export function bodySummary(baseline: RunSnapshot, final: RunSnapshot): z.infer<typeof bodySummarySchema> | null {
  const a = baseline.body_time, b = final.body_time;
  if (!a || !b || a.since_tick !== b.since_tick || b.window_tick !== baseline.tick || final.tick <= baseline.tick) return null;
  const window = final.tick - baseline.tick;
  const states = Object.fromEntries(Object.keys(b.ticks).sort().flatMap((state) => {
    const ticks = b.ticks[state]! - (a.ticks[state] ?? 0);
    return ticks > 0 ? [[state, { ticks, share: round(ticks / window) }]] : [];
  }));
  const busy = BUSY_STATES.reduce((sum, state) => sum + (states[state]?.ticks ?? 0), 0);
  const gaps = Object.fromEntries(Object.keys(b.gaps).sort().flatMap((by) => {
    const now = b.gaps[by]!, then = a.gaps[by];
    const count = now.count - (then?.count ?? 0), ticks = now.ticks - (then?.ticks ?? 0);
    if (count <= 0) return [];
    const inside = now.longest_end_tick !== undefined && now.longest_end_tick - now.longest >= baseline.tick;
    return [[by, gapRow(count, ticks, inside ? now.longest : null)]];
  }));
  const open = b.state === "idle" ? final.tick - Math.max(b.state_since, baseline.tick) : 0;
  if (open > 0) gaps.open = gapRow(1, open, open);
  return { window_ticks: window, busy_share: round(busy / window), states, gaps };
}

// A manifest keeps the role profiles its run recorded, so runs from earlier
// role pairs stay readable; only a new ledger pins the current pair.
const manifestSchema = z.object({
  schema_version: z.literal(1), run: operationsLedgerSchema.shape.run.extend({
    roles: runRolesSchema }),
  variant: z.string().min(1), change: z.string().min(1), kind: z.enum(["debug", "benchmark"]),
  status: z.enum(["recording", "finished", "interrupted"]), assisted: z.boolean(),
  app_version: z.string(), mod_version: z.string(), factorio_version: z.string(),
  started_at: z.string(), start_tick: z.number().int().nonnegative(),
  ended_at: z.string().nullable(), end_tick: z.number().int().nonnegative().nullable(),
  benchmark: benchmarkEvidenceSchema.optional(),
  telemetry: runTelemetrySchema.optional(),
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
    thoughts: path.join(dir, "thoughts.jsonl"), toolOutcomes: path.join(dir, "tool_outcomes.jsonl") };
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

/** Supervisor recovery after retiring writers and reconciling a dead recorder.
 * Never converts an interrupted run into scored evidence or changes samples. */
export function interruptRun(root: string, id: string, reason: string, at = new Date()): void {
  if (!reason.trim()) throw new Error("interrupt requires a non-empty reconciliation reason");
  const files = runPaths(root, id), manifest = readManifest(root, id);
  if (manifest.status !== "recording") return;
  appendJson(files.events, { type: "recorder_interrupted", at: at.toISOString(), reason });
  writeManifest(files.manifest, { ...manifest, status: "interrupted",
    ended_at: manifest.ended_at ?? at.toISOString(), end_tick: manifest.end_tick });
}

/** Run attestation for the recorder: each new deviation in the baseline or a
 *  sample marks the run assisted (markRunAssisted), once per fact; returns
 *  the new ones. A failed mark is reported, never thrown into the recorder. */
export function createAttestor(root: string, id: string) {
  const seen = new Set<string>();
  return (snapshot: RunSnapshot): string[] => {
    const fresh = attestationIssues(snapshot.attestation).filter((issue) => !seen.has(issue));
    for (const issue of fresh) {
      seen.add(issue);
      try { markRunAssisted(root, id, `attestation: ${issue}`); }
      catch (error) { console.error(`ATTESTATION RECORD ERROR ${error instanceof Error ? error.message : String(error)}`); }
    }
    return fresh;
  };
}

/** tool_outcomes.jsonl stops growing at this size. */
export const TOOL_OUTCOMES_MAX_BYTES = 16 * 1024 * 1024;
const TOOL_OUTCOMES_PENDING_MAX = 256;
export interface ToolOutcome { at: string; role: string; tool: string; status: string; code: string | null; duration_ms: number }
/** A tool result's status and code: the structured status, else ok or failed by isError. */
export function toolOutcome(value: unknown): { status: string; code: string | null } {
  const result = value as { isError?: unknown; structuredContent?: Record<string, unknown> } | null | undefined;
  const structured = result?.structuredContent;
  return { status: typeof structured?.status === "string" ? structured.status : result?.isError === true ? "failed" : "ok",
    code: typeof structured?.code === "string" ? structured.code : null };
}
/** Appends one row per MCP tool call to tool_outcomes.jsonl beside the
 *  samples of the run the current run directory's ledger names, while the
 *  recorder's run directory exists (nothing is created). Writes are
 *  asynchronous and in order; a full queue, a missing run, an oversized file
 *  or a failed write drops the row, never the call. */
export function createToolOutcomeLog(runDir: RunDir, role: string, root: () => string = () => runRoot()) {
  const pending: Array<{ file: string; row: string }> = [];
  let draining: Promise<void> | null = null;
  // appendFile creates the file, never the run directory: no run, no row.
  const drain = () => draining ??= (async () => {
    try {
      while (pending.length) {
        const next = pending.shift()!;
        try {
          const size = await fs.promises.stat(next.file).then((stat) => stat.size, () => 0);
          if (size + Buffer.byteLength(next.row) > TOOL_OUTCOMES_MAX_BYTES) continue;
          await fs.promises.appendFile(next.file, next.row, { encoding: "utf8", mode: 0o600 });
        } catch { /* evidence only */ }
      }
    } finally { draining = null; }
  })();
  return {
    record(tool: string, durationMs: number, value: unknown, at = new Date()): Promise<void> {
      try {
        const dir = runDir(), id = dir ? readLedger(dir)?.run.id : undefined;
        if (!id || pending.length >= TOOL_OUTCOMES_PENDING_MAX) return Promise.resolve();
        const row: ToolOutcome = { at: at.toISOString(), role, tool, ...toolOutcome(value), duration_ms: Math.round(durationMs) };
        pending.push({ file: runPaths(root(), id).toolOutcomes, row: `${JSON.stringify(row)}\n` });
        return drain();
      } catch { return Promise.resolve(); }
    },
  };
}
export type ToolOutcomeLog = ReturnType<typeof createToolOutcomeLog>;

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
  pilotRollout?: string; strategistRollout?: string; durationSeconds?: number; incumbentSummary?: string }
export function checkpointDelay(checkpoint: number, elapsedMs: number): number {
  return Math.max(0, checkpoint * 300_000 - elapsedMs);
}
export async function recordRun(options: RecordRunOptions): Promise<void> {
  const config = loadConfig();
  if (!config) throw new Error("configuration is missing or invalid; run `factorio-codex setup`");
  const ledger = operationsLedgerSchema.parse(JSON.parse(fs.readFileSync(options.ledger, "utf8")));
  const profiles = roleProfiles(ledger.run.roles);
  const duration = options.durationSeconds ?? BENCHMARK_SECONDS;
  if (!Number.isInteger(duration) || duration < 1 || duration > BENCHMARK_SECONDS)
    throw new Error("durationSeconds must be an integer from 1 to 1200");
  assertConnectionCompatibility(config.rcon);
  const rcon = new RconClient(config.rcon), bridge = new Bridge(rcon);
  // Deadline control must not queue behind the recorder's jobs or thought feed.
  const controlRcon = options.kind === "benchmark" ? new RconClient(config.rcon) : undefined;
  const control = controlRcon ? new Bridge(controlRcon) : undefined;
  let feed: ThoughtFeed | undefined, timer: NodeJS.Timeout | undefined, cutoffTimer: NodeJS.Timeout | undefined;
  let finishing = false, chain = Promise.resolve(), freezePromise: Promise<void> | undefined;
  let finishSignal: (() => void) | undefined;
  const signalFinish = () => { if (!finishing) { finishing = true; if (timer) clearTimeout(timer); finishSignal?.(); } };
  process.once("SIGINT", signalFinish); process.once("SIGTERM", signalFinish);
  try {
    await rcon.connect(); await bridge.unlock();
    if (controlRcon && control) { await controlRcon.connect(); await control.unlock(); }
    const ping = await bridge.call<any>("ping"); assertRuntimeCompatibility(ping, companionVersion());
    if (!ping.companion_exists) throw new Error("native player 'Codex' must have a living character before GO");
    // Refuse duplicate run stores before changing the game state.
    const root = runRoot(options.root);
    if (fs.existsSync(runPaths(root, ledger.run.id).manifest)) throw new Error("run already has recording evidence");
    if (control) await control.call("benchmark_control", { action: "prepare", run_id: ledger.run.id,
      duration_seconds: duration, label: `${options.variant}: ${profiles.map(p => `${p.id} ${p.model}/${p.reasoning}${p.fast ? "/Fast" : "/normal"}`).join("; ")}`,
      summary: options.incumbentSummary });
    // The baseline marks the body-time window: idle before GO is not a gap of this run.
    const baseline = parseRunSnapshot(await bridge.call("run_snapshot", { window: true }));
    const startedAt = new Date(), startedMono = performance.now();
    let manifest: RunManifest = { schema_version: 1, run: ledger.run, variant: options.variant, change: options.change,
      kind: options.kind, status: "recording", assisted: false, app_version: companionVersion(),
      mod_version: ping.mod_version, factorio_version: ping.factorio_version, started_at: startedAt.toISOString(),
      start_tick: baseline.tick, ended_at: null, end_tick: null };
    const files = createRunStore(root, manifest);
    appendJson(files.samples, { status: "ok", kind: "baseline", scheduled_elapsed_ms: 0, actual_elapsed_ms: 0,
      capture_started_at: startedAt.toISOString(), capture_completed_at: startedAt.toISOString(), capture_latency_ms: 0,
      tick: baseline.tick, tick_delta: 0, snapshot: baseline, delta: snapshotDelta(baseline, baseline) });
    const attestor = createAttestor(root, ledger.run.id);
    const attest = (snapshot: RunSnapshot) => {
      const issues = attestor(snapshot);
      if (issues.length) manifest.assisted = true;
      for (const issue of issues) console.log(`ASSISTED attestation: ${issue}`);
    };
    attest(baseline);
    const stopped = new Promise<void>(resolve => { finishSignal = resolve; if (finishing) resolve(); });
    let freezeError: unknown;
    const freeze = () => {
      if (freezePromise) return freezePromise;
      freezePromise = (async () => {
        const requested = new Date();
        try {
          const result = await control!.call<any>("benchmark_control", { action: "freeze", run_id: ledger.run.id });
          const completed = new Date();
          manifest.benchmark = benchmarkEvidenceSchema.parse({ duration_seconds: duration,
            deadline_at: new Date(startedAt.getTime() + duration * 1000).toISOString(),
            freeze_started_at: requested.toISOString(), freeze_completed_at: completed.toISOString(),
            freeze_skew_ms: performance.now() - startedMono - duration * 1000,
            start_tick: baseline.tick,
            frozen_tick: result.frozen_tick, reason: result.freeze_reason, metrics: result.metrics });
          const live = readManifest(root, ledger.run.id);
          manifest.assisted = manifest.assisted || live.assisted || result.assisted === true;
          // A terminal timestamp closes ledger updates before collecting heavy reads.
          manifest.ended_at = completed.toISOString(); manifest.end_tick = result.frozen_tick;
          writeManifest(files.manifest, manifest);
          appendJson(files.events, { type: "benchmark_frozen", at: completed.toISOString(), evidence: manifest.benchmark });
        } catch (error) { freezeError = error; }
        finally { signalFinish(); }
      })();
      return freezePromise;
    };
    if (control && !finishing) {
      await control.call("benchmark_control", { action: "begin", run_id: ledger.run.id });
      cutoffTimer = setTimeout(() => { void freeze(); }, Math.max(0, duration * 1000 - (performance.now() - startedMono)));
    }
    if (!finishing) console.log(`GO ${manifest.started_at} tick=${manifest.start_tick} run=${manifest.run.id}`);
    const pointer = path.join(path.dirname(options.ledger), "rollouts.json");
    const sources = profiles.map(p => ({ role: p.id as ThoughtRole,
      file: rolloutResolver(pointer, p.id, p.id === "pilot" ? options.pilotRollout : p.id === "strategist" ? options.strategistRollout : undefined) }));
    // The game shows only the ledger writer's thinking (the strategist; the pilot in a solo trial).
    const splits = new Map(profiles.map(p => [p.id as ThoughtRole, createTimeSplit()]));
    feed = createThoughtFeed({ sources, out: files.thoughts, say: (role, text) => bridge.call("say", { role, text }),
      onLine: (role, line) => splits.get(role)?.line(line),
      shown: role => profiles.some(p => p.id === role && p.ledger_writer),
      now: { read: () => {
        try { return operationsLedgerSchema.parse(JSON.parse(fs.readFileSync(options.ledger, "utf8"))).task_list.NOW.objective; }
        catch { return null; }
      }, say: text => bridge.call("say_now", { text }) } });
    const capture = async (kind: "checkpoint" | "final", scheduled: number): Promise<RunSample> => {
      const began = new Date(), before = performance.now();
      try {
        const snapshot = parseRunSnapshot(await bridge.call("run_snapshot"));
        return { status: "ok", kind, scheduled_elapsed_ms: scheduled, actual_elapsed_ms: performance.now() - startedMono,
          capture_started_at: began.toISOString(), capture_completed_at: new Date().toISOString(), capture_latency_ms: performance.now() - before,
          tick: snapshot.tick, tick_delta: snapshot.tick - baseline.tick, snapshot, delta: snapshotDelta(snapshot, baseline) };
      } catch (error) {
        return { status: "error", kind, scheduled_elapsed_ms: scheduled, actual_elapsed_ms: performance.now() - startedMono,
          capture_started_at: began.toISOString(), capture_completed_at: new Date().toISOString(), capture_latency_ms: performance.now() - before,
          error: error instanceof Error ? error.message : String(error) };
      }
    };
    let nextCheckpoint = 1;
    const schedule = () => {
      const deadline = nextCheckpoint * 300_000;
      if (control && deadline >= duration * 1000) return; // final sample is the frozen boundary
      timer = setTimeout(() => {
        nextCheckpoint++;
        chain = chain.then(async () => {
          const sample = await capture("checkpoint", deadline); appendJson(files.samples, sample);
          if (sample.status === "ok") attest(sample.snapshot);
          console.log(sample.status === "ok" ? `CHECKPOINT +${deadline / 60_000}m tick=${sample.tick}` : `CHECKPOINT ERROR ${sample.error}`);
        });
        if (!finishing) schedule();
      }, checkpointDelay(nextCheckpoint, performance.now() - startedMono));
    };
    if (!finishing) schedule();
    await stopped;
    if (control) await freeze();
    if (cutoffTimer) clearTimeout(cutoffTimer);
    feed.stop(); feed = undefined;
    await chain;
    const final = await capture("final", control ? duration * 1000 : performance.now() - startedMono);
    appendJson(files.samples, final);
    if (final.status === "ok") attest(final.snapshot);
    manifest.telemetry = { roles: Object.fromEntries([...splits].map(([role, split]) => [role, split.summary()])),
      body: final.status === "ok" ? bodySummary(baseline, final.snapshot) : null };
    // Preserve the ordinary 20-minute comparison checkpoint using frozen state.
    if (control && final.status === "ok") appendJson(files.samples, { ...final, kind: "checkpoint" });
    const live = readManifest(root, ledger.run.id);
    manifest = { ...manifest, assisted: live.assisted || manifest.assisted,
      status: final.status === "ok" && !freezeError ? "finished" : "interrupted",
      ended_at: manifest.ended_at ?? new Date().toISOString(), end_tick: final.status === "ok" ? final.tick : null };
    writeManifest(files.manifest, manifest);
    console.log(`FINISH ${manifest.ended_at} run=${manifest.run.id} status=${manifest.status}`);
    if (freezeError) throw freezeError;
  } finally {
    if (timer) clearTimeout(timer); if (cutoffTimer) clearTimeout(cutoffTimer);
    process.removeListener("SIGINT", signalFinish); process.removeListener("SIGTERM", signalFinish);
    feed?.stop(); rcon.close(); controlRcon?.close();
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
    if (value.benchmark) reasons.push(...cutoffIssues(value.benchmark).map(reason => `${label}: ${reason}`));
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
