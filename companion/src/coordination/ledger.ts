import fs from "node:fs";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
import { z } from "zod";
import { atomicWriteFile } from "../setup/atomic.js";
import { MAX_PLAN_STEPS, packageStepSchema, stepIssue } from "../mcp/runPlan.js";
import { runRolesSchema } from "../runs/profiles.js";
import { dataDir } from "../config.js";

const text = (max: number) => z.string().min(1).max(max);
const gitSha = z.string().regex(/^[0-9a-f]{40}$/);
const sha256 = z.string().regex(/^[0-9a-f]{64}$/);
const priority = z.object({
  objective: text(240),
  strategic_reason: text(400),
  completion_condition: text(400),
  // One outcome sentence; item counts, travel and step sequences belong in a package.
  essential_prerequisite: z.string().min(1)
    .max(160, "essential_prerequisite is one outcome sentence of at most 160 characters").nullable(),
}).strict();
const runSchema = z.object({
  id: text(160), release_sha: gitSha, baseline_save_sha256: sha256,
  save_identity: text(240), created_at: text(80),
  roles: runRolesSchema,
}).strict();
const capacity = z.object({
  stage: text(120), measure: text(160), value: z.number().finite(), unit: text(80),
  observed_tick: z.number().int().nonnegative(),
}).strict();
const assumption = z.object({ assumption: text(400), invalidation_condition: text(400) }).strict();
// A strategist note in the run's notebook, relative to the ledger's directory.
const notePath = z.string().max(160).refine((note) => {
  const segments = note.split("/");
  return segments.length >= 2 && segments[0] === "notebook" && note.endsWith(".md")
    && segments.slice(1).every((segment) => /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(segment));
}, "notes are relative notebook/<name>.md paths without '..' or absolute parts");
const packageId = z.string().regex(/^[a-z0-9-]{1,32}$/, "package ids are 1-32 lowercase letters, digits or dashes");
// The surface a package's positions are on, as ping names the body's: a
// planet name or "platform:<index>".
const packageSurface = z.string().regex(/^(?:[a-z][a-z0-9-]{0,39}|platform:[1-9][0-9]{0,5})$/,
  'surface is a planet name such as "nauvis" or "platform:<index>"');
// A plan the strategist designed; the pilot's bridge checks its placements and queues it
// into the FIFO by itself, in ledger order, while the body is on its surface
// (coordination/orders.ts). Leading blueprint_capture steps are made by the
// bridge before the rest is queued. Every package an update writes names its
// surface; one stored before protocol 28 (no surface) was for nauvis.
const packageFields = z.object({
  package_id: packageId,
  serves: z.enum(["NOW", "NEXT"]),
  intent: text(240),
  after_package_id: packageId.nullable().default(null),
  source_tick: z.number().int().nonnegative(),
  anchor: z.object({ x: z.number().finite(), y: z.number().finite() }).strict(),
  required_items: z.record(z.string().min(1), z.number().int().positive())
    .refine((required) => Object.keys(required).length <= 16, "at most 16 required items"),
  steps: z.array(packageStepSchema).min(1).max(MAX_PLAN_STEPS),
  success_check: text(240),
  notes: z.array(notePath).max(3).optional(),
}).strict();
const buildPackage = packageFields.extend({ surface: packageSurface.default("nauvis") });
const writtenPackage = packageFields.extend({ surface: packageSurface });
const MAX_PACKAGE_BYTES = 8192;

export const operationsLedgerSchema = z.object({
  schema_version: z.literal(2), run: runSchema,
  revision: z.number().int().nonnegative(), source_tick: z.number().int().nonnegative().nullable(),
  phase: text(120), bottleneck: text(240),
  latest_measured_capacity: z.array(capacity).max(12),
  task_list: z.object({ NOW: priority, NEXT: priority, LATER: priority }).strict(),
  assumptions: z.array(assumption).max(8),
  build_packages: z.array(buildPackage).max(2).default([]),
}).strict();

type BuildPackage = z.infer<typeof buildPackage>;
/** Cross-field package checks the object schema cannot express. */
function packageIssues(packages: BuildPackage[], sourceTick: number | null): string[] {
  const issues: string[] = [];
  const ids = new Set(packages.map((entry) => entry.package_id));
  if (ids.size !== packages.length) issues.push("build_packages: package ids must be unique");
  if (Buffer.byteLength(JSON.stringify(packages), "utf8") > MAX_PACKAGE_BYTES) issues.push(`build_packages: at most ${MAX_PACKAGE_BYTES} bytes`);
  const after = new Map(packages.map((entry) => [entry.package_id, entry.after_package_id]));
  packages.forEach((entry, index) => {
    const at = `build_packages.${index}`;
    if (sourceTick !== null && entry.source_tick > sourceTick) issues.push(`${at}.source_tick: newer than the revision's source_tick`);
    // after_package_id may name a package the pilot already queued (and the strategist dropped).
    if (entry.after_package_id === entry.package_id
      || (entry.after_package_id !== null && after.get(entry.after_package_id) === entry.package_id)) {
      issues.push(`${at}.after_package_id: packages cannot depend on themselves or on each other`);
    }
    const removed = new Set(entry.steps.flatMap((step) => step.action === "mine" ? [`${step.x},${step.y}`] : []));
    entry.steps.forEach((step, stepIndex) => {
      // Travel moves the body off its surface: the pilot's decision only.
      if (step.action === "travel") issues.push(`${at}.steps.${stepIndex}: travel is the pilot's; a package never moves the body to another surface`);
      if (step.action === "place_entity" && removed.has(`${step.x},${step.y}`)) {
        issues.push(`${at}.steps.${stepIndex}: placement targets the position of this package's own mine step`);
      }
      const issue = stepIssue(step);
      if (issue) issues.push(`${at}.steps.${stepIndex}: ${issue}`);
      if (step.action === "blueprint_capture" && stepIndex > 0 && entry.steps[stepIndex - 1]!.action !== "blueprint_capture") {
        issues.push(`${at}.steps.${stepIndex}: blueprint_capture steps come first in a package`);
      }
    });
  });
  return issues.slice(0, 3);
}

/** The pilot reads named notes from the notebook beside the ledger, so each must exist. */
function missingNotes(packages: BuildPackage[], ledgerFile: string): string[] {
  const directory = path.dirname(ledgerFile);
  return packages.flatMap((entry, index) => (entry.notes ?? []).flatMap((note, noteIndex) => {
    try { if (fs.statSync(path.join(directory, note)).isFile()) return []; }
    catch { /* reported below */ }
    return [`build_packages.${index}.notes.${noteIndex}: ${note} is not a file beside the ledger`];
  })).slice(0, 3);
}

function schemaIssues(error: z.ZodError): string[] {
  return error.issues.slice(0, 3).map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`.slice(0, 160));
}

// Every update restates the pending packages: an omitted list would silently
// replace them with an empty one.
const mutableSchema = operationsLedgerSchema.omit({ schema_version: true, run: true, revision: true, source_tick: true })
  .extend({ build_packages: z.array(writtenPackage).max(2) });
export const ledgerEnvelopeSchema = z.object({
  run_id: text(160), save_identity: text(240), source_tick: z.number().int().nonnegative(),
  update: mutableSchema,
}).strict();
/** Creates revision 1 of an absent ledger, so the strategist stays its sole writer. */
export const ledgerInitSchema = z.object({
  init: z.literal(true), run: runSchema, source_tick: z.number().int().nonnegative().nullable(), update: mutableSchema,
}).strict();
const applyEnvelopeSchema = z.union([ledgerEnvelopeSchema, ledgerInitSchema]);

export type OperationsLedger = z.infer<typeof operationsLedgerSchema>;
export type LedgerApplyResult = { status: "applied"; revision: number; source_tick: number | null }
  | { status: "discarded"; reason: string; issues?: string[] };

const discard = (reason: string, issues?: string[]): LedgerApplyResult =>
  ({ status: "discarded", reason, ...(issues && issues.length > 0 ? { issues } : {}) });

export function reduceLedger(existingValue: unknown, envelopeValue: unknown):
  { result: LedgerApplyResult; ledger?: OperationsLedger } {
  const existing = operationsLedgerSchema.safeParse(existingValue);
  if (!existing.success) return { result: discard("MALFORMED_OR_UNSUPPORTED_LEDGER") };
  const envelope = ledgerEnvelopeSchema.safeParse(envelopeValue);
  if (!envelope.success) return { result: discard("MALFORMED_REPORT", schemaIssues(envelope.error)) };
  const issues = packageIssues(envelope.data.update.build_packages, envelope.data.source_tick);
  if (issues.length > 0) return { result: discard("MALFORMED_REPORT", issues) };
  if (envelope.data.run_id !== existing.data.run.id) return { result: discard("WRONG_RUN") };
  if (envelope.data.save_identity !== existing.data.run.save_identity) return { result: discard("WRONG_SAVE") };
  if (existing.data.source_tick !== null && envelope.data.source_tick <= existing.data.source_tick) {
    return { result: discard(envelope.data.source_tick === existing.data.source_tick ? "DUPLICATE_REPORT" : "STALE_REPORT") };
  }
  const ledger: OperationsLedger = {
    schema_version: 2, run: existing.data.run, revision: existing.data.revision + 1,
    source_tick: envelope.data.source_tick, ...envelope.data.update,
  };
  return { result: { status: "applied", revision: ledger.revision, source_tick: ledger.source_tick! }, ledger };
}

/** Package ids the bridge already queued or failed (package-queue.json beside
 *  the ledger) that an update lists changed or again after dropping them: the
 *  queue keys on the id, so such a package would never be queued. An
 *  unchanged repeat of a listed package is fine. Unreadable queue: no check
 *  (the queue itself then queues nothing). */
function reusedPackageIds(file: string, existing: unknown, packages: Array<{ package_id: string }>): string[] {
  let records: Record<string, { status?: string }>;
  try {
    const value = JSON.parse(fs.readFileSync(path.join(path.dirname(file), "package-queue.json"), "utf8"));
    if (!value || typeof value.packages !== "object" || Array.isArray(value.packages)) return [];
    records = value.packages;
  } catch { return []; }
  // Compared as the schema reads them (a 0.21.1 layout entity is upgraded).
  const parsed = operationsLedgerSchema.safeParse(existing);
  const listed = parsed.success ? parsed.data.build_packages : (existing as { build_packages?: unknown })?.build_packages;
  const previous = Array.isArray(listed) ? listed as Array<{ package_id?: unknown }> : [];
  return packages.flatMap((entry, index) => {
    const record = records[entry.package_id];
    if (!record) return [];
    const same = previous.find((old) => old?.package_id === entry.package_id);
    if (same && isDeepStrictEqual(same, JSON.parse(JSON.stringify(entry)))) return [];
    return [`build_packages.${index}.package_id: ${entry.package_id} was already used (status ${record.status ?? "unknown"}); give a changed or re-listed package a new package_id`];
  });
}

export function applyLedgerFile(file: string, envelopeValue: unknown): LedgerApplyResult {
  const envelope = applyEnvelopeSchema.safeParse(envelopeValue);
  if (!envelope.success) {
    const isInitShape = typeof envelopeValue === "object" && envelopeValue !== null && "init" in envelopeValue;
    const specific = (isInitShape ? ledgerInitSchema : ledgerEnvelopeSchema).safeParse(envelopeValue);
    return discard("MALFORMED_REPORT", specific.success ? [] : schemaIssues(specific.error));
  }
  const runId = "init" in envelope.data ? envelope.data.run.id : envelope.data.run_id;
  try {
    const manifestPath = path.join(dataDir(), "runs", `run-${encodeURIComponent(runId)}`, "manifest.json");
    if (fs.existsSync(manifestPath)) {
      const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
      if (manifest.kind === "benchmark") {
        if (manifest.ended_at !== null && typeof manifest.ended_at !== "string") return discard("RUN_EVIDENCE_UNREADABLE");
        if (manifest.ended_at !== null) return discard("BENCHMARK_ENDED");
      }
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") return discard("RUN_EVIDENCE_UNREADABLE");
  }
  const noteIssues = missingNotes(envelope.data.update.build_packages, file);
  if (noteIssues.length > 0) return discard("MALFORMED_REPORT", noteIssues);
  let destination: fs.Stats | undefined;
  try { destination = fs.lstatSync(file); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") return discard("LEDGER_READ_FAILED");
  }
  let reduced: { result: LedgerApplyResult; ledger?: OperationsLedger };
  const isInit = "init" in envelope.data;
  if ("init" in envelope.data) {
    const issues = packageIssues(envelope.data.update.build_packages, envelope.data.source_tick);
    if (issues.length > 0) return discard("MALFORMED_REPORT", issues);
    if (destination) return discard("LEDGER_ALREADY_EXISTS");
    const ledger: OperationsLedger = {
      schema_version: 2, run: envelope.data.run, revision: 1,
      source_tick: envelope.data.source_tick, ...envelope.data.update,
    };
    reduced = { ledger, result: { status: "applied", revision: 1, source_tick: envelope.data.source_tick } };
  } else {
    if (!destination) return discard("MISSING_LEDGER");
    if (!destination.isFile()) return discard("LEDGER_READ_FAILED");
    if ((destination.mode & 0o7777) !== 0o600) return discard("UNSAFE_LEDGER_MODE");
    let existing: unknown;
    let contents: string;
    try { contents = fs.readFileSync(file, "utf8"); }
    catch { return discard("LEDGER_READ_FAILED"); }
    try { existing = JSON.parse(contents); }
    catch { return discard("MALFORMED_OR_UNSUPPORTED_LEDGER"); }
    const reused = reusedPackageIds(file, existing, envelope.data.update.build_packages);
    if (reused.length > 0) return discard("MALFORMED_REPORT", reused);
    reduced = reduceLedger(existing, envelope.data);
  }
  if (!reduced.ledger) return reduced.result;
  // JSON has no -0; compare the readback with what JSON actually stores.
  const serialized = JSON.stringify(reduced.ledger, null, 2);
  const stored = JSON.parse(serialized) as OperationsLedger;
  try { atomicWriteFile(file, `${serialized}\n`, 0o600, !isInit); }
  catch (error) {
    if (isInit && (error as NodeJS.ErrnoException).code === "EEXIST") return discard("LEDGER_ALREADY_EXISTS");
    throw error;
  }
  const readBack = operationsLedgerSchema.safeParse(JSON.parse(fs.readFileSync(file, "utf8")));
  if (!readBack.success || !isDeepStrictEqual(readBack.data, stored) ||
      (fs.lstatSync(file).mode & 0o7777) !== 0o600) throw new Error("ledger atomic write verification failed");
  return reduced.result;
}

export async function runLedgerApply(file: string): Promise<void> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(Buffer.from(chunk));
  let envelope: unknown;
  try { envelope = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { console.log(JSON.stringify(discard("MALFORMED_REPORT"))); return; }
  console.log(JSON.stringify(applyLedgerFile(file, envelope)));
}
