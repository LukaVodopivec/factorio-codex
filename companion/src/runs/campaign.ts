import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { z } from "zod";
import { atomicWriteFile } from "../setup/atomic.js";
import { profileListSchema, initialProfiles } from "./profiles.js";
import { benchmarkScore, cutoffIssues, INPUT_ITEMS } from "./benchmark.js";
import { readManifest, readSamples, runRoot } from "./telemetry.js";

const identifier = z.string().regex(/^[a-z0-9][a-z0-9-]{0,119}$/);
const runIdentifier = z.string().regex(/^[a-z0-9][a-z0-9-]{0,159}$/);
const sha = z.string().regex(/^[a-f0-9]{40}$/);
export const configurationSchema = z.object({ id: identifier, profiles: profileListSchema,
  release_sha: sha, change: z.string().min(1), family: z.enum(["topology", "model", "instructions", "mod", "interaction"]) }).strict();
const trialSchema = z.object({ run_id: runIdentifier, configuration: identifier, eligible: z.boolean(),
  reasons: z.array(z.string()), research: z.number().nonnegative(), made: z.number().nonnegative(),
  input: z.number().nonnegative(), final_input_per_minute: z.number().nonnegative(),
  resources: z.record(z.string(), z.number()), made_items: z.record(z.string(), z.number()),
  recorded_at: z.string() }).strict();
export const campaignSchema = z.object({ schema_version: z.literal(2), id: identifier,
  status: z.enum(["active", "paused"]), baseline_save_sha256: z.string().regex(/^[a-f0-9]{64}$/),
  seed: z.literal(747930220), subscription_only: z.literal(true), duration_seconds: z.literal(1200),
  incumbent: identifier, configurations: z.array(configurationSchema).min(1), trials: z.array(trialSchema),
  screening_queue: z.array(identifier), screens_since_control: z.number().int().nonnegative(),
  unsuccessful_screens: z.number().int().nonnegative(),
  confirmation: z.object({ challenger: identifier, incumbent: identifier, results: z.array(runIdentifier).max(6) }).nullable(),
  pending: z.object({ run_id: runIdentifier, configuration: identifier, purpose: z.enum(["screen", "confirmation", "control"]) }).nullable(),
}).strict();
export type Campaign = z.infer<typeof campaignSchema>;
export type Trial = z.infer<typeof trialSchema>;
export type Configuration = z.infer<typeof configurationSchema>;

export function readCampaign(file: string): Campaign {
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  if (value?.schema_version === 1) throw new Error("campaign schema 1 predates the automation score; read it with release 0.23.0 or start a new campaign");
  return campaignSchema.parse(value);
}
function writeCampaign(file: string, value: Campaign): void {
  atomicWriteFile(file, `${JSON.stringify(campaignSchema.parse(value), null, 2)}\n`, 0o600);
}
export function initializeCampaign(file: string, baseline: string, id: string, releaseSha: string): Campaign {
  if (fs.existsSync(file)) throw new Error("campaign already exists; resume it instead");
  const bytes = fs.readFileSync(baseline);
  if (bytes.subarray(0, 4).toString("hex") !== "504b0304") throw new Error("baseline is not a Factorio save ZIP");
  // Topology was screened (campaign 20261006); later hypotheses vary one variable of the two-brain incumbent.
  const configurations = [2].map(count => configurationSchema.parse({ id: `brains-${count}`, profiles: initialProfiles(count),
    release_sha: releaseSha, change: `${count} reasoning agents, one physical body`, family: "topology" }));
  const campaign = campaignSchema.parse({ schema_version: 2, id, status: "active", seed: 747930220, subscription_only: true,
    duration_seconds: 1200, baseline_save_sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
    incumbent: "brains-2", configurations, trials: [], screening_queue: configurations.map(c => c.id),
    screens_since_control: 0, unsuccessful_screens: 0, confirmation: null, pending: null });
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.copyFileSync(baseline, path.join(path.dirname(file), "baseline-save.zip"), fs.constants.COPYFILE_EXCL);
  fs.chmodSync(path.join(path.dirname(file), "baseline-save.zip"), 0o400);
  writeCampaign(file, campaign); return campaign;
}
export function addConfiguration(file: string, value: unknown): Campaign {
  const campaign = readCampaign(file), configuration = configurationSchema.parse(value);
  if (campaign.configurations.some(c => c.id === configuration.id)) throw new Error("configuration id already exists; give a changed hypothesis a new id");
  campaign.configurations.push(configuration); campaign.screening_queue.push(configuration.id);
  writeCampaign(file, campaign); return campaign;
}
export function nextTrial(file: string): { campaign: Campaign; configuration?: Configuration; needs_hypothesis?: boolean } {
  const c = readCampaign(file);
  if (c.status !== "active") return { campaign: c };
  if (!c.pending) {
    let configuration: string | undefined, purpose: NonNullable<Campaign["pending"]>["purpose"] = "screen";
    if (c.confirmation) {
      // Three pairs alternate order: challenger/incumbent, incumbent/challenger, challenger/incumbent.
      configuration = [0, 3, 4].includes(c.confirmation.results.length) ? c.confirmation.challenger : c.confirmation.incumbent;
      purpose = "confirmation";
    } else if (c.screens_since_control >= 6) { configuration = c.incumbent; purpose = "control"; }
    else configuration = c.screening_queue[0];
    if (!configuration) return { campaign: c, needs_hypothesis: true };
    c.pending = { run_id: `${c.id}-trial-${String(c.trials.length + 1).padStart(4, "0")}`, configuration, purpose };
    writeCampaign(file, c);
  }
  return { campaign: c, configuration: c.configurations.find(config => config.id === c.pending!.configuration)! };
}

// Within five percent counts as equal, so the next measure decides:
// research, then machine-made output, then final-five-minute raw input.
// A difference under the floor (packs, items, raw per minute) is noise too.
function compare(a: number, b: number, floor: number): number {
  if (Math.abs(a - b) < floor) return 0;
  if (a > b * 1.05) return 1;
  if (b > a * 1.05) return -1;
  return 0;
}
const FLOOR = { research: 5, made: 20, rate: 5 };
type Scored = Pick<Trial, "research" | "made" | "final_input_per_minute">;
export function trialWins(candidate: Scored, incumbent: Scored): boolean {
  return (compare(candidate.research, incumbent.research, FLOOR.research) || compare(candidate.made, incumbent.made, FLOOR.made)
    || compare(candidate.final_input_per_minute, incumbent.final_input_per_minute, FLOOR.rate)) > 0;
}
function median(values: number[]): number { const sorted = [...values].sort((a, b) => a - b); return sorted[Math.floor(sorted.length / 2)]!; }
export function confirmationWins(pairs: Array<[Trial, Trial]>): boolean {
  if (pairs.length !== 3 || pairs.some(pair => pair.some(t => !t.eligible))) return false;
  const medians = (side: 0 | 1) => ({ research: median(pairs.map(p => p[side].research)), made: median(pairs.map(p => p[side].made)) });
  const a = medians(0), b = medians(1);
  return pairs.filter(([candidate, incumbent]) => trialWins(candidate, incumbent)).length >= 2
    && (compare(a.research, b.research, FLOOR.research) || compare(a.made, b.made, FLOOR.made)) > 0;
}
export function recordTrial(file: string, runId: string, evidenceRoot = runRoot()): Campaign {
  const c = readCampaign(file);
  if (c.trials.some(t => t.run_id === runId)) return c; // idempotent interrupted external readback
  if (c.pending?.run_id !== runId) throw new Error("run does not match the pending trial");
  const manifest = readManifest(evidenceRoot, runId), config = c.configurations.find(x => x.id === c.pending!.configuration)!;
  if (manifest.status === "recording") throw new Error("finish and reconcile the live trial before recording it");
  const reasons = cutoffIssues(manifest.benchmark);
  if (manifest.kind !== "benchmark") reasons.push("not a benchmark");
  if (manifest.status !== "finished") reasons.push("trial did not finish");
  if (manifest.assisted) reasons.push("human or supervisor assistance");
  if (manifest.run.baseline_save_sha256 !== c.baseline_save_sha256) reasons.push("starting save differs");
  if (manifest.run.release_sha !== config.release_sha) reasons.push("release differs from the frozen configuration");
  if (!isDeepStrictEqual(manifest.run.roles, config.profiles)) reasons.push("role profiles differ from the frozen configuration");
  const score = benchmarkScore(manifest.benchmark?.metrics ?? {});
  let samples: ReturnType<typeof readSamples> = [];
  try { samples = readSamples(evidenceRoot, runId); }
  catch { reasons.push("sample evidence is malformed or unreadable"); }
  const previous = samples.find(s => s.status === "ok" && s.kind === "checkpoint" && s.scheduled_elapsed_ms === 900_000);
  let finalInput = 0;
  if (previous?.status === "ok" && Math.abs(previous.actual_elapsed_ms - 900_000) <= 1000
    && previous.capture_latency_ms <= 1000
    && Math.abs(previous.tick_delta - 54_000) <= 60) {
    const counts = new Map(previous.delta.items.map(row => [row.name, row.produced]));
    finalInput = Math.max(0, score.input - INPUT_ITEMS.reduce((sum, name) => sum + (counts.get(name) ?? 0), 0)) / 5;
  } else reasons.push("15-minute throughput checkpoint is missing or outside its one-second boundary");
  const trial: Trial = { run_id: runId, configuration: config.id, eligible: reasons.length === 0, reasons, ...score,
    final_input_per_minute: finalInput, recorded_at: new Date().toISOString() };
  c.trials.push(trial);
  const purpose = c.pending.purpose;
  c.pending = null;
  if (trial.eligible) {
    if (purpose === "confirmation") {
      c.confirmation!.results.push(runId);
      if (c.confirmation!.results.length === 6) {
        const trials = c.confirmation!.results.map(id => c.trials.find(t => t.run_id === id)!);
        const pairs = [[trials[0]!, trials[1]!], [trials[3]!, trials[2]!], [trials[4]!, trials[5]!]] as Array<[Trial, Trial]>;
        if (confirmationWins(pairs)) { c.incumbent = c.confirmation!.challenger; c.unsuccessful_screens = 0; }
        else c.unsuccessful_screens++;
        c.confirmation = null;
      }
    } else if (purpose === "control") c.screens_since_control = 0;
    else {
      c.screening_queue.shift(); c.screens_since_control++;
      const incumbent = [...c.trials].reverse().find(t => t.eligible && t.configuration === c.incumbent && t.run_id !== runId);
      if (config.id !== c.incumbent && incumbent && trialWins(trial, incumbent))
        c.confirmation = { challenger: config.id, incumbent: c.incumbent, results: [] };
      else if (config.id !== c.incumbent) c.unsuccessful_screens++;
    }
  }
  writeCampaign(file, c); return c;
}

export function setCampaignStatus(file: string, status: Campaign["status"]): Campaign {
  const c = readCampaign(file); c.status = status; writeCampaign(file, c); return c;
}
