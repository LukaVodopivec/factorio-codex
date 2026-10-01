import fs from "node:fs";
import { z } from "zod";
import { atomicWriteFile } from "../setup/atomic.js";

const text = (max: number) => z.string().min(1).max(max);
const gitSha = z.string().regex(/^[0-9a-f]{40}$/);
const sha256 = z.string().regex(/^[0-9a-f]{64}$/);
const priority = z.object({
  objective: text(240),
  strategic_reason: text(400),
  completion_condition: text(400),
  essential_prerequisite: text(240).nullable(),
}).strict();
const runSchema = z.object({
  id: text(160), release_sha: gitSha, baseline_save_sha256: sha256,
  save_identity: text(240), created_at: text(80),
  roles: z.object({
    pilot: z.object({ model: z.literal("gpt-6-luna"), reasoning: z.literal("low"), fast: z.literal(true) }).strict(),
    strategist: z.object({ model: z.literal("gpt-6.1-sol"), reasoning: z.literal("medium"), fast: z.literal(false) }).strict(),
  }).strict(),
}).strict();
const capacity = z.object({
  stage: text(120), measure: text(160), value: z.number().finite(), unit: text(80),
  observed_tick: z.number().int().nonnegative(),
}).strict();
const assumption = z.object({ assumption: text(400), invalidation_condition: text(400) }).strict();
const planIds = z.object({
  current_plan_id: z.number().int().positive().nullable(),
  queued_successor_plan_id: z.number().int().positive().nullable(),
  predecessor_plan_id: z.number().int().positive().nullable(),
}).strict().superRefine((plans, ctx) => {
  const hasSuccessor = plans.queued_successor_plan_id !== null;
  if (hasSuccessor !== (plans.predecessor_plan_id !== null)) {
    ctx.addIssue({ code: "custom", message: "successor and predecessor IDs must be reported together" });
  }
  if (hasSuccessor && plans.predecessor_plan_id !== plans.current_plan_id) {
    ctx.addIssue({ code: "custom", message: "successor predecessor must equal the current pilot plan" });
  }
});

export const operationsLedgerSchema = z.object({
  schema_version: z.literal(2), run: runSchema,
  revision: z.number().int().nonnegative(), source_tick: z.number().int().nonnegative().nullable(),
  phase: text(120), bottleneck: text(240),
  latest_measured_capacity: z.array(capacity).max(12),
  task_list: z.object({ NOW: priority, NEXT: priority, LATER: priority }).strict(),
  assumptions: z.array(assumption).max(8), pilot_plan_ids: planIds,
}).strict();

const mutableSchema = operationsLedgerSchema.omit({ schema_version: true, run: true, revision: true, source_tick: true });
export const ledgerEnvelopeSchema = z.object({
  run_id: text(160), save_identity: text(240), source_tick: z.number().int().nonnegative(),
  update: mutableSchema,
}).strict();

export type OperationsLedger = z.infer<typeof operationsLedgerSchema>;
export type LedgerApplyResult = { status: "applied"; revision: number; source_tick: number }
  | { status: "discarded"; reason: string };

const discard = (reason: string): LedgerApplyResult => ({ status: "discarded", reason });

export function reduceLedger(existingValue: unknown, envelopeValue: unknown):
  { result: LedgerApplyResult; ledger?: OperationsLedger } {
  const existing = operationsLedgerSchema.safeParse(existingValue);
  if (!existing.success) return { result: discard("MALFORMED_OR_UNSUPPORTED_LEDGER") };
  const envelope = ledgerEnvelopeSchema.safeParse(envelopeValue);
  if (!envelope.success) return { result: discard("MALFORMED_REPORT") };
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

export function applyLedgerFile(file: string, envelopeValue: unknown): LedgerApplyResult {
  let existing: unknown;
  try { existing = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch { return discard("MALFORMED_OR_UNSUPPORTED_LEDGER"); }
  const reduced = reduceLedger(existing, envelopeValue);
  if (!reduced.ledger) return reduced.result;
  if ((fs.statSync(file).mode & 0o777) !== 0o600) return discard("UNSAFE_LEDGER_MODE");
  atomicWriteFile(file, `${JSON.stringify(reduced.ledger, null, 2)}\n`, 0o600);
  const readBack = operationsLedgerSchema.safeParse(JSON.parse(fs.readFileSync(file, "utf8")));
  if (!readBack.success || readBack.data.revision !== reduced.ledger.revision ||
      (fs.statSync(file).mode & 0o777) !== 0o600) throw new Error("ledger atomic write verification failed");
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
