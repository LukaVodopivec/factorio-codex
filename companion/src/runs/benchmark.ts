import { z } from "zod";

export const BENCHMARK_SECONDS = 1200;
// The automation score: science packs labs consumed (research), then
// machine-made plates, intermediates and packs, then raw input. The mod
// subtracts nothing; hand:<item> is the body's hand-crafts of an item.
export const INPUT_ITEMS = ["iron-ore", "copper-ore", "coal", "stone"] as const;
export const MADE_ITEMS = ["iron-plate", "copper-plate", "steel-plate", "iron-gear-wheel", "electronic-circuit",
  "automation-science-pack", "logistic-science-pack"] as const;
export const SCIENCE_PACKS = ["automation-science-pack", "logistic-science-pack"] as const;
const SCORED_COUNTERS = [...INPUT_ITEMS, ...MADE_ITEMS, ...MADE_ITEMS.map(name => `hand:${name}`),
  ...SCIENCE_PACKS.map(name => `consumed:${name}`)];
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
    ...(SCORED_COUNTERS.some(name => evidence.metrics[name] === undefined) ? ["scored counters are missing"] : []),
  ];
}
export function benchmarkScore(metrics: Record<string, number>) {
  const value = (name: string) => metrics[name] ?? 0;
  const research = SCIENCE_PACKS.reduce((sum, name) => sum + Math.max(0, value(`consumed:${name}`) - value(`hand:${name}`)), 0);
  const madeItems = Object.fromEntries(MADE_ITEMS.map(name => [name, Math.max(0, value(name) - value(`hand:${name}`))]));
  return { research, made: Object.values(madeItems).reduce((a, b) => a + b, 0),
    input: INPUT_ITEMS.reduce((sum, name) => sum + value(name), 0),
    resources: Object.fromEntries(INPUT_ITEMS.map(name => [name, value(name)])), made_items: madeItems };
}
