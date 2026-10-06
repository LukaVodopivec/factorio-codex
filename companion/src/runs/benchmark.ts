import { z } from "zod";

export const BENCHMARK_SECONDS = 1200;
export const INPUT_ITEMS = ["iron-ore", "copper-ore", "coal", "stone"] as const;
export const OUTPUT_ITEMS = ["iron-plate", "copper-plate"] as const;
export const benchmarkEvidenceSchema = z.object({
  duration_seconds: z.number().int().positive(), deadline_at: z.string(),
  freeze_started_at: z.string(), freeze_completed_at: z.string(),
  freeze_skew_ms: z.number().finite(), frozen_tick: z.number().int().nonnegative(),
  start_tick: z.number().int().nonnegative(),
  reason: z.string(), metrics: z.record(z.string(), z.number().nonnegative()),
}).strict();
export type BenchmarkEvidence = z.infer<typeof benchmarkEvidenceSchema>;
export function cutoffIssues(evidence?: BenchmarkEvidence): string[] {
  if (!evidence) return ["no frozen cutoff evidence"];
  return [
    ...(evidence.duration_seconds !== BENCHMARK_SECONDS ? ["duration is not 20 minutes"] : []),
    ...(Math.abs(evidence.freeze_skew_ms) > 1000 ? ["freeze differs from deadline by more than one second"] : []),
    ...(Math.abs(evidence.frozen_tick - evidence.start_tick - evidence.duration_seconds * 60) > 60
      ? ["simulation did not sustain the normal 60 UPS clock"] : []),
    ...([...INPUT_ITEMS, ...OUTPUT_ITEMS].some(name => evidence.metrics[name] === undefined) ? ["scored counters are missing"] : []),
  ];
}
export function benchmarkScore(metrics: Record<string, number>) {
  const input = INPUT_ITEMS.reduce((sum, name) => sum + (metrics[name] ?? 0), 0);
  const output = OUTPUT_ITEMS.reduce((sum, name) => sum + (metrics[name] ?? 0), 0);
  return { input, output, resources: Object.fromEntries(INPUT_ITEMS.map(name => [name, metrics[name] ?? 0])),
    plates: Object.fromEntries(OUTPUT_ITEMS.map(name => [name, metrics[name] ?? 0])) };
}
