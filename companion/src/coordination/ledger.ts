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
/** A strategist note in the run's notebook, relative to the ledger's directory. */
export const NOTES_RULE = "notes are relative notebook/<name>.md paths without '..' or absolute parts";
const notePath = z.string().max(160).refine((note) => {
  const segments = note.split("/");
  return segments.length >= 2 && segments[0] === "notebook" && note.endsWith(".md")
    && segments.slice(1).every((segment) => /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(segment));
}, NOTES_RULE);
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
/** What after_package_id means, for the schema and the ledger-apply help. */
export const AFTER_PACKAGE_ID_RULE = "after_package_id: set it only when a package really needs its predecessor's result"
  + " (a capture of it, its landfill, its machines to connect, or items it makes that this package's first step needs:"
  + " only then is that first step's ITEM_UNOBTAINABLE left to run time); the FIFO already runs packages in ledger order,"
  + " and a package whose predecessor ends partial, failed or cancelled is cancelled, never run, except after a predecessor"
  + " whose last step's insert ended partial only because its target was full (TARGET_CAPACITY)";
/** A plan's active budget (tasks.lua tick_plan and each action's budget_steps), for queue_plan and the package help. */
export const PLAN_BUDGET_RULE = "a plan's active budget is max(570 s, 12 s x its steps) from its start, human holds not"
  + " charged; a hand build_layout counts each entity and route tile as a step, a hand blueprint_place each entity,"
  + " build_ghosts 100, a hand deconstruct_area or upgrade_area 60, place_tiles one per 8 tiles, explore 2 plus one per"
  + " 32 tiles of max_distance, travel its wait; past it the plan fails PLAN_BUDGET_EXCEEDED and queued hand-crafts keep"
  + " running";
/** Factory line states (autonomy.lua), as factory_status names them. */
export const LINE_STATES = ["running", "starved", "output_full", "depleted", "no_fuel", "no_power", "frozen",
  "no_heat", "disabled", "idle"] as const;
/** What a package's verify declares, for the schema, the ledger-apply help and the tool descriptions. */
export const VERIFY_RULE = "verify (optional): 1-3 metrics the pilot's bridge measures once, 2 minutes of game time after"
  + " the package's plan ends, on the package's surface: {item, per_min_at_least} (that item or fluid made there over"
  + " the last minute, from the game's production statistics) or {line_at: {x, y}, state} (the factory line of the"
  + " machine whose box holds that position, with its state, cause and rate). All met: a package_verified event, else"
  + " package_unmet, each with the measured values (next_event; activity_log's packages keep them as verification)."
  + " Only a completed or partial plan is measured (a partial plan's NO_LINE row carries plan_status); a failed or"
  + " cancelled plan's verify is not_measured, with no event. A metric's surface (optional) measures it on that planet"
  + " or \"platform:<index>\" instead, such as a platform package's output on its platform. Measurement only: nothing"
  + " is fixed or queued again";
const itemName = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/, "items are names such as \"iron-plate\"");
export const verifyMetricSchema = z.union([
  z.object({ item: itemName, per_min_at_least: z.number().finite().positive(), surface: packageSurface.optional() }).strict(),
  z.object({ line_at: z.object({ x: z.number().finite(), y: z.number().finite() }).strict(),
    state: z.enum(LINE_STATES), surface: packageSurface.optional() }).strict(),
]);
export const verifySchema = z.array(verifyMetricSchema).min(1).max(3);
export type VerifyMetric = z.infer<typeof verifyMetricSchema>;
const packageFields = z.object({
  package_id: packageId,
  serves: z.enum(["NOW", "NEXT"]),
  intent: text(240),
  after_package_id: packageId.nullable().default(null).describe(AFTER_PACKAGE_ID_RULE),
  source_tick: z.number().int().nonnegative(),
  anchor: z.object({ x: z.number().finite(), y: z.number().finite() }).strict(),
  required_items: z.record(z.string().min(1), z.number().int().positive())
    .refine((required) => Object.keys(required).length <= 16, "at most 16 required items"),
  steps: z.array(packageStepSchema).min(1).max(MAX_PLAN_STEPS),
  success_check: text(240),
  notes: z.array(notePath).max(3).optional(),
  verify: verifySchema.optional().describe(VERIFY_RULE),
}).strict();
const buildPackage = packageFields.extend({ surface: packageSurface.default("nauvis") });
const writtenPackage = packageFields.extend({ surface: packageSurface });
const MAX_PACKAGE_BYTES = 8192;
// The strategist's research selection: technologies in queue order. The
// pilot's bridge queues them once for each revision that lists any, through
// the mod's start_research, skipping those already researched or queued, and
// records the outcome in activity_log (coordination/orders.ts).
export const MAX_RESEARCH = 7;
const technology = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/, "technologies are names such as \"automation\"");
const research = z.array(technology).max(MAX_RESEARCH)
  .refine((names) => new Set(names).size === names.length, "research lists each technology once");

export const operationsLedgerSchema = z.object({
  schema_version: z.literal(2), run: runSchema,
  revision: z.number().int().nonnegative(), source_tick: z.number().int().nonnegative().nullable(),
  phase: text(120), bottleneck: text(240),
  latest_measured_capacity: z.array(capacity).max(12),
  task_list: z.object({ NOW: priority, NEXT: priority, LATER: priority }).strict(),
  assumptions: z.array(assumption).max(8),
  build_packages: z.array(buildPackage).max(2).default([]),
  research: research.default([]),
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
/** What an applied update's omitted_unqueued means, for the ledger-apply help. */
export const OMITTED_UNQUEUED_RULE = "omitted_unqueued (applied result, when any): packages the previous revision listed"
  + " that the pilot's bridge had not queued and this update no longer lists; they will not be queued."
  + " omitted_possibly_queued: dropped packages whose queue_plan was sent but its answer lost; the mod may already hold their plan";
export type LedgerApplyResult = { status: "applied"; revision: number; source_tick: number | null; omitted_unqueued?: string[];
  omitted_possibly_queued?: string[] }
  | { status: "discarded"; reason: string; issues?: string[] };

const discard = (reason: string, issues?: string[]): LedgerApplyResult =>
  ({ status: "discarded", reason, ...(issues && issues.length > 0 ? { issues } : {}) });

export function reduceLedger(existingValue: unknown, envelopeValue: unknown):
  { result: LedgerApplyResult; ledger?: OperationsLedger } {
  const existing = operationsLedgerSchema.safeParse(existingValue);
  if (!existing.success) return { result: discard("MALFORMED_OR_UNSUPPORTED_LEDGER") };
  const envelope = ledgerEnvelopeSchema.safeParse(envelopeValue);
  if (!envelope.success) return { result: discard("MALFORMED_UPDATE", schemaIssues(envelope.error)) };
  const issues = packageIssues(envelope.data.update.build_packages, envelope.data.source_tick);
  if (issues.length > 0) return { result: discard("MALFORMED_UPDATE", issues) };
  if (envelope.data.run_id !== existing.data.run.id) return { result: discard("WRONG_RUN") };
  if (envelope.data.save_identity !== existing.data.run.save_identity) return { result: discard("WRONG_SAVE") };
  if (existing.data.source_tick !== null && envelope.data.source_tick <= existing.data.source_tick) {
    return { result: discard(envelope.data.source_tick === existing.data.source_tick ? "DUPLICATE_UPDATE" : "STALE_UPDATE",
      [`source_tick must exceed ${existing.data.source_tick}`]) };
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
type QueueRecords = Record<string, { status?: string }>;
/** package-queue.json's records beside the ledger: {} when absent, null when unreadable. */
function queueRecords(file: string): QueueRecords | null {
  try {
    const value = JSON.parse(fs.readFileSync(path.join(path.dirname(file), "package-queue.json"), "utf8"));
    return value && typeof value.packages === "object" && !Array.isArray(value.packages) ? value.packages : null;
  } catch (error) { return (error as NodeJS.ErrnoException).code === "ENOENT" ? {} : null; }
}
/** The packages the existing ledger lists, as the schema reads them (a 0.21.1 layout entity is upgraded). */
function listedPackages(existing: unknown): Array<{ package_id?: unknown }> {
  const parsed = operationsLedgerSchema.safeParse(existing);
  const listed = parsed.success ? parsed.data.build_packages : (existing as { build_packages?: unknown })?.build_packages;
  return Array.isArray(listed) ? listed as Array<{ package_id?: unknown }> : [];
}
function reusedPackageIds(records: QueueRecords | null, existing: unknown, packages: Array<{ package_id: string }>): string[] {
  if (!records) return [];
  const previous = listedPackages(existing);
  return packages.flatMap((entry, index) => {
    const record = records[entry.package_id];
    if (!record) return [];
    const same = previous.find((old) => old?.package_id === entry.package_id);
    if (same && isDeepStrictEqual(same, JSON.parse(JSON.stringify(entry)))) return [];
    return [`build_packages.${index}.package_id: ${entry.package_id} was already used (status ${record.status ?? "unknown"}); give a changed or re-listed package a new package_id`];
  });
}

/** Package ids the existing ledger lists that the bridge never settled and
 *  the update no longer lists: the bridge queues only listed packages.
 *  unqueued (no record, or waiting_surface) will not be queued; possibly
 *  (queuing: the queue_plan call was sent and its answer lost) may already
 *  be in the mod's FIFO. Facts for the strategist, never a refusal.
 *  Unreadable queue: none. */
function omittedUnqueued(records: QueueRecords | null, existing: unknown, packages: Array<{ package_id: string }>):
  { unqueued: string[]; possibly: string[] } {
  const omitted = { unqueued: [] as string[], possibly: [] as string[] };
  if (!records) return omitted;
  const kept = new Set(packages.map((entry) => entry.package_id));
  for (const entry of listedPackages(existing)) {
    const id = entry?.package_id;
    if (typeof id !== "string" || kept.has(id)) continue;
    const status = records[id]?.status;
    if (status === "queuing") omitted.possibly.push(id);
    else if (status !== "queued" && status !== "failed") omitted.unqueued.push(id);
  }
  return omitted;
}

export function applyLedgerFile(file: string, envelopeValue: unknown): LedgerApplyResult {
  const envelope = applyEnvelopeSchema.safeParse(envelopeValue);
  if (!envelope.success) {
    const isInitShape = typeof envelopeValue === "object" && envelopeValue !== null && "init" in envelopeValue;
    const specific = (isInitShape ? ledgerInitSchema : ledgerEnvelopeSchema).safeParse(envelopeValue);
    return discard("MALFORMED_UPDATE", specific.success ? [] : schemaIssues(specific.error));
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
  if (noteIssues.length > 0) return discard("MALFORMED_UPDATE", noteIssues);
  let destination: fs.Stats | undefined;
  try { destination = fs.lstatSync(file); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") return discard("LEDGER_READ_FAILED");
  }
  let reduced: { result: LedgerApplyResult; ledger?: OperationsLedger };
  const isInit = "init" in envelope.data;
  if ("init" in envelope.data) {
    const issues = packageIssues(envelope.data.update.build_packages, envelope.data.source_tick);
    if (issues.length > 0) return discard("MALFORMED_UPDATE", issues);
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
    const records = queueRecords(file);
    const reused = reusedPackageIds(records, existing, envelope.data.update.build_packages);
    if (reused.length > 0) return discard("MALFORMED_UPDATE", reused);
    reduced = reduceLedger(existing, envelope.data);
    const omitted = omittedUnqueued(records, existing, envelope.data.update.build_packages);
    if (reduced.ledger && reduced.result.status === "applied") {
      if (omitted.unqueued.length > 0) reduced.result.omitted_unqueued = omitted.unqueued;
      if (omitted.possibly.length > 0) reduced.result.omitted_possibly_queued = omitted.possibly;
    }
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

// One field's type in a line, from its JSON Schema: nested objects name
// their fields one level deep (? marks optional ones).
type JsonSchema = { [key: string]: any };
function fieldType(schema: JsonSchema | undefined, depth = 0): string {
  if (!schema || typeof schema !== "object") return "any";
  if (schema.const !== undefined) return JSON.stringify(schema.const);
  if (Array.isArray(schema.enum)) return schema.enum.map((value: unknown) => typeof value === "string" ? value : JSON.stringify(value)).join("|");
  const options = schema.anyOf ?? schema.oneOf;
  if (Array.isArray(options)) return options.map((option: JsonSchema) => fieldType(option, depth)).join(" or ");
  if (schema.type === "array") {
    const bounds = schema.maxItems !== undefined ? ` (${schema.minItems ?? 0}-${schema.maxItems})` : "";
    return `[${fieldType(schema.items, depth)}]${bounds}`;
  }
  if (schema.type === "object") {
    if (!schema.properties) return "{name: count}";
    const required: string[] = schema.required ?? [];
    return `{${Object.entries(schema.properties).map(([key, value]) => `${key}${required.includes(key) ? "" : "?"}`
      + (depth >= 1 ? "" : `: ${fieldType(value as JsonSchema, depth + 1)}`)).join(", ")}}`;
  }
  const type = Array.isArray(schema.type) ? schema.type.join("|") : schema.type ?? "any";
  if (schema.pattern) return `${type} matching ${schema.pattern}`;
  // A numeric cap prints with its floor (an integer's safe-integer limit is no cap).
  const max = typeof schema.maximum === "number" && schema.maximum < Number.MAX_SAFE_INTEGER ? schema.maximum : undefined;
  if (max === undefined) return type;
  return typeof schema.minimum === "number" && schema.minimum > Number.MIN_SAFE_INTEGER ? `${type} ${schema.minimum}-${max}` : `${type} <=${max}`;
}
// "required fields | optional fields" of an object schema, leaving out the named keys.
function fieldLine(schema: z.ZodType, skip: string[]): string {
  const json = z.toJSONSchema(schema, { io: "input", unrepresentable: "any" }) as JsonSchema;
  const required: string[] = json.required ?? [];
  const fields = Object.entries(json.properties ?? {}).filter(([key]) => !skip.includes(key));
  const list = (want: boolean) => fields.filter(([key]) => required.includes(key) === want)
    .map(([key, value]) => `${key}: ${fieldType(value as JsonSchema)}`).join("; ");
  return `${list(true) || "-"} | optional: ${list(false) || "-"}`;
}
/** The contract ledger-apply --schema prints, generated from the schemas it
 *  checks: the update envelope, the update's fields, a package's fields and
 *  each step action's fields. */
export function packageContract(): string {
  const steps = packageStepSchema.options.filter((option) => option.shape.action.value !== "travel")
    .map((option) => `  ${option.shape.action.value}: ${fieldLine(option, ["action"])}`);
  return [
    `envelope (required | optional): ${fieldLine(ledgerEnvelopeSchema, ["update"])}; update: the object below;`
      + " source_tick must exceed the ledger's; an absent ledger takes {init: true, run, source_tick, update} instead",
    `update (required | optional): ${fieldLine(mutableSchema, ["build_packages", "research"])}; build_packages and research below;`
      + " every update restates the packages still wanted",
    `build_packages: at most 2 per update, together at most ${MAX_PACKAGE_BYTES} bytes of JSON; each package (required | optional):`,
    `  ${fieldLine(writtenPackage, ["steps"])}`,
    `  steps: 1-${MAX_PLAN_STEPS} of the steps below; blueprint_capture steps come first; travel is never a package step`,
    `  a package runs as one plan: ${PLAN_BUDGET_RULE}`, `  ${AFTER_PACKAGE_ID_RULE}`, `  ${VERIFY_RULE}`, `  ${NOTES_RULE}, each an existing file beside the ledger`,
    `research: at most ${MAX_RESEARCH} technologies in queue order, each once`,
    "steps (action: required | optional):", ...steps,
  ].join("\n");
}

/** Appends one ledger-apply outcome to ledger-history.jsonl beside the
 *  ledger: at, status, revision (applied) or reason and issues (discarded),
 *  and the update's package_ids. Evidence only: a failed append changes
 *  nothing. */
export function recordLedgerHistory(file: string, envelope: unknown, result: LedgerApplyResult, at = new Date()): void {
  try {
    const sent = envelope as { run_id?: unknown; run?: { id?: unknown }; update?: { build_packages?: unknown } } | null;
    const runId = typeof sent?.run_id === "string" ? sent.run_id : typeof sent?.run?.id === "string" ? sent.run.id : undefined;
    const listed = sent?.update?.build_packages;
    const packageIds = Array.isArray(listed) ? listed.flatMap((entry) =>
      typeof entry?.package_id === "string" ? [entry.package_id] : []) : [];
    const row = { at: at.toISOString(), run_id: runId, ...result, package_ids: packageIds };
    fs.appendFileSync(path.join(path.dirname(file), "ledger-history.jsonl"), `${JSON.stringify(row)}\n`, { encoding: "utf8", mode: 0o600 });
  } catch { /* evidence only */ }
}

export async function runLedgerApply(file: string): Promise<void> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(Buffer.from(chunk));
  let envelope: unknown;
  let result: LedgerApplyResult | undefined;
  try { envelope = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { result = discard("MALFORMED_UPDATE"); }
  result ??= applyLedgerFile(file, envelope);
  recordLedgerHistory(file, envelope, result);
  console.log(JSON.stringify(result));
}
