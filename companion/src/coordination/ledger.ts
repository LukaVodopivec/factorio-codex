import fs from "node:fs";
import { z } from "zod";
import { atomicWriteFile } from "../setup/atomic.js";

const TOP_LEVEL_KEYS = [
  "schema_version", "run", "revision", "source_tick", "phase", "success",
  "capacity", "utilization", "bottleneck", "current_plan", "queued_successor",
  "fallbacks", "current_bom", "next_bom", "latest_observation", "decisions",
  "strategy_proposal", "invalidations", "outcome",
] as const;

const runSchema = z.object({
  id: z.string().min(1),
  release_sha: z.string().min(1),
  baseline_save_sha256: z.string().min(1),
  save_identity: z.string().min(1),
  created_at: z.string().min(1),
}).passthrough();

const ledgerSchema = z.object({
  schema_version: z.number().int().positive(),
  run: runSchema,
  revision: z.number().int().nonnegative(),
  source_tick: z.number().int().nonnegative().nullable(),
  phase: z.unknown(), success: z.unknown(), capacity: z.unknown(), utilization: z.unknown(),
  bottleneck: z.unknown(), current_plan: z.unknown(), queued_successor: z.unknown(),
  fallbacks: z.unknown(), current_bom: z.unknown(), next_bom: z.unknown(),
  latest_observation: z.unknown().nullable(), decisions: z.unknown(),
  strategy_proposal: z.unknown().nullable(), invalidations: z.unknown(), outcome: z.unknown(),
}).strict();

const mirrorSchema = ledgerSchema.omit({
  schema_version: true, run: true, revision: true, source_tick: true,
  strategy_proposal: true,
});

export const ledgerEnvelopeSchema = z.object({
  run_id: z.string().min(1),
  save_identity: z.string().min(1),
  source_tick: z.number().int().nonnegative(),
  mirror: mirrorSchema,
  strategy_proposal: z.unknown().nullable(),
}).strict();

export type OperationsLedger = z.infer<typeof ledgerSchema>;
export type LedgerApplyEnvelope = z.infer<typeof ledgerEnvelopeSchema>;
export type LedgerApplyResult =
  | { status: "applied"; revision: number; source_tick: number }
  | { status: "discarded"; reason: string };

function discard(reason: string): LedgerApplyResult { return { status: "discarded", reason }; }

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}

export function reduceLedger(existingValue: unknown, envelopeValue: unknown):
  { result: LedgerApplyResult; ledger?: OperationsLedger } {
  const existingParsed = ledgerSchema.safeParse(existingValue);
  if (!existingParsed.success) return { result: discard("MALFORMED_LEDGER") };
  const envelopeParsed = ledgerEnvelopeSchema.safeParse(envelopeValue);
  if (!envelopeParsed.success) return { result: discard("MALFORMED_REPORT") };
  const existing = existingParsed.data;
  const envelope = envelopeParsed.data;
  if (envelope.run_id !== existing.run.id) return { result: discard("WRONG_RUN") };
  if (envelope.save_identity !== existing.run.save_identity) return { result: discard("WRONG_SAVE") };
  if (existing.source_tick !== null && envelope.source_tick <= existing.source_tick) {
    return { result: discard(envelope.source_tick === existing.source_tick ? "DUPLICATE_REPORT" : "STALE_REPORT") };
  }
  const observation = record(envelope.mirror.latest_observation);
  if (!observation || observation.source_tick !== envelope.source_tick) {
    return { result: discard("OBSERVATION_TICK_MISMATCH") };
  }
  const queued = record(envelope.mirror.queued_successor);
  if (envelope.mirror.queued_successor !== null && !queued) {
    return { result: discard("UNCONFIRMED_SUCCESSOR") };
  }
  if (queued) {
    const current = record(envelope.mirror.current_plan);
    if (queued.status !== "queued" || !Number.isInteger(queued.plan_id) ||
        !Number.isInteger(queued.after_plan_id) || queued.after_plan_id !== current?.plan_id) {
      return { result: discard("UNCONFIRMED_SUCCESSOR") };
    }
  }
  const ledger: OperationsLedger = {
    schema_version: existing.schema_version,
    run: existing.run,
    revision: existing.revision + 1,
    source_tick: envelope.source_tick,
    ...envelope.mirror,
    strategy_proposal: envelope.strategy_proposal,
  };
  return { result: { status: "applied", revision: ledger.revision, source_tick: ledger.source_tick! }, ledger };
}

export function applyLedgerFile(file: string, envelopeValue: unknown): LedgerApplyResult {
  let original: string;
  let existingValue: unknown;
  try {
    original = fs.readFileSync(file, "utf8");
    existingValue = JSON.parse(original);
  } catch {
    return discard("MALFORMED_LEDGER");
  }
  const reduced = reduceLedger(existingValue, envelopeValue);
  if (!reduced.ledger) return reduced.result;
  if ((fs.statSync(file).mode & 0o777) !== 0o600) return discard("UNSAFE_LEDGER_MODE");
  atomicWriteFile(file, `${JSON.stringify(reduced.ledger, null, 2)}\n`, 0o600);
  const readBack = ledgerSchema.safeParse(JSON.parse(fs.readFileSync(file, "utf8")));
  if (!readBack.success || readBack.data.revision !== reduced.ledger.revision ||
      (fs.statSync(file).mode & 0o777) !== 0o600) {
    throw new Error("ledger atomic write verification failed");
  }
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

export { TOP_LEVEL_KEYS };
