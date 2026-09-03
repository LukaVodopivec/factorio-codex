import { z } from "zod";
import { DEFAULT_TASK_TIMEOUT_MS, ModError, TaskCancelledError, type TaskClock } from "../bridge.js";
import type { Bridge } from "../bridge.js";
import { normalizeObservation } from "./observation.js";

const position = { x: z.number(), y: z.number() };
const items = z.record(z.string(), z.number().int().positive());
export const planStepSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("walk_to"), ...position }).strict(),
  z.object({ action: z.literal("mine"), ...position, count: z.number().int().min(1).max(200).default(1), target_kind: z.enum(["natural", "owned"]).default("natural"), allow_fluid_loss: z.boolean().default(false), expected_name: z.string().min(1).optional(), observed_tick: z.number().int().nonnegative().optional() }).strict(),
  z.object({ action: z.literal("pickup_items"), ...position, item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict(),
  z.object({ action: z.literal("place_entity"), ...position, name: z.string(), direction: z.number().int().optional(), output_target: z.object(position).strict().optional() }).strict(),
  z.object({ action: z.literal("craft_items"), recipe: z.string(), crafts: z.number().int().min(1).max(100), wait_for_completion: z.boolean().default(true) }).strict(),
  z.object({ action: z.literal("insert_items"), ...position, items }).strict(),
  z.object({ action: z.literal("extract_items"), ...position, items: items.optional() }).strict(),
  z.object({ action: z.literal("set_recipe"), ...position, recipe: z.string() }).strict(),
  z.object({ action: z.literal("rotate_entity"), ...position, direction: z.number().int().min(0).max(15).optional() }).strict(),
  z.object({ action: z.literal("inspect_entities"), positions: z.array(z.object(position).strict()).min(1).max(16) }).strict(),
  z.object({ action: z.literal("wait_for_item"), ...position, inventory: z.enum(["input", "output", "fuel", "main"]), item: z.string(), count: z.number().int().positive(), timeout_seconds: z.number().min(1).max(300).default(120) }).strict(),
]);
export const queuePlanSchema = z.object({
  steps: z.array(planStepSchema).min(1).max(25),
  final_observation_radius: z.number().int().min(5).max(30).default(15),
  observation_detail: z.enum(["none", "compact", "full"]).default("none"),
  after_plan_id: z.number().int().positive().optional(),
}).strict();
export const runPlanSchema = queuePlanSchema;
export const planStatusSchema = z.object({
  plan_id: z.number().int().positive(),
  wait_until: z.enum(["current", "progress", "terminal"]).default("current"),
  timeout_seconds: z.number().int().min(1).max(60).default(30),
}).strict();
export type RunPlanInput = z.infer<typeof runPlanSchema>;
export interface PlanOutcome { step: number; action: RunPlanInput["steps"][number]["action"]; status: "completed" | "partial" | "failed" | "cancelled"; result?: unknown; error?: string }
export interface RunPlanResult {
  plan_id?: number; status: "queued" | "running" | "waiting" | "completed" | "partial" | "failed" | "cancelled"; source_tick?: number;
  position?: { x: number; y: number }; current_step?: number; completed_steps?: number;
  total_steps?: number; outcomes: PlanOutcome[]; queue_depth?: number;
  observation?: Record<string, unknown>; observation_error?: string;
  execution?: { mode: "sequential_nontransactional"; rollback: "none"; committed_steps?: number[]; effects_state?: "unknown";
    incomplete_step?: { step: number; status: "failed" | "cancelled"; effects: "unknown" } };
  wait?: { condition: "progress" | "terminal"; timed_out: boolean; waited_ms: number };
}
const realClock: TaskClock = { now: Date.now, sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) };

const terminalStatuses = new Set(["completed", "partial", "failed", "cancelled"]);
function isTerminal(status: RunPlanResult): boolean { return terminalStatuses.has(status.status); }
function progressMarker(status: RunPlanResult): string {
  return `${status.outcomes?.length ?? 0}:${status.status === "waiting" ? "waiting" : "active"}:${isTerminal(status) ? "terminal" : "open"}`;
}

/** Wait through the existing plan_status RPC. A request abort stops monitoring only;
 * callers that own cancellation must do so explicitly. */
export async function waitForPlanStatus(
  bridge: Bridge,
  planId: number,
  condition: "current" | "progress" | "terminal" = "current",
  timeoutMs = 30_000,
  signal?: AbortSignal,
  clock: TaskClock = realClock,
): Promise<RunPlanResult> {
  const started = clock.now();
  let status = await bridge.call<RunPlanResult>("plan_status", { plan_id: planId });
  if (condition === "current" || isTerminal(status)) return status;
  const initialMarker = progressMarker(status);
  const deadline = started + timeoutMs;
  while (clock.now() < deadline) {
    if (signal?.aborted) throw new TaskCancelledError("plan_status wait was cancelled; physical plan remains active");
    await clock.sleep(Math.min(1_000, deadline - clock.now()));
    if (signal?.aborted) throw new TaskCancelledError("plan_status wait was cancelled; physical plan remains active");
    status = await bridge.call<RunPlanResult>("plan_status", { plan_id: planId });
    if (isTerminal(status) || (condition === "progress" && progressMarker(status) !== initialMarker)) return status;
  }
  return { ...status, wait: { condition, timed_out: true, waited_ms: Math.max(0, clock.now() - started) } };
}

export async function executeRunPlan(bridge: Bridge, input: RunPlanInput, signal?: AbortSignal, clock: TaskClock = realClock): Promise<RunPlanResult> {
  if (signal?.aborted) return { status: "cancelled", completed_steps: 0, outcomes: [],
    execution: { mode: "sequential_nontransactional", rollback: "none", committed_steps: [] } };
  const { plan_id } = await bridge.call<{ plan_id: number }>("queue_plan", input);
  const deadline = clock.now() + DEFAULT_TASK_TIMEOUT_MS;
  try {
    const status = await waitForPlanStatus(bridge, plan_id, "terminal", deadline - clock.now(), signal, clock);
    if (isTerminal(status)) {
      if (status.observation) status.observation = normalizeObservation(status.observation);
      return status;
    }
    throw new ModError("run_plan gave up after 570s");
  } catch (error) {
    await bridge.call("cancel", { plan_id }).catch(() => {});
    try {
      const cancelled = await bridge.call<RunPlanResult>("plan_status", { plan_id });
      if (isTerminal(cancelled)) {
        if (cancelled.observation) cancelled.observation = normalizeObservation(cancelled.observation);
        return cancelled;
      }
    } catch (readbackError) {
      if (error instanceof TaskCancelledError || signal?.aborted) {
        return { plan_id, status: "cancelled", outcomes: [],
          observation_error: `${error instanceof Error ? error.message : String(error)}; terminal readback unavailable: ${readbackError instanceof Error ? readbackError.message : String(readbackError)}`,
          execution: { mode: "sequential_nontransactional", rollback: "none", effects_state: "unknown",
            incomplete_step: { step: 1, status: "cancelled", effects: "unknown" } } };
      }
    }
    if (error instanceof TaskCancelledError || signal?.aborted) {
      return { plan_id, status: "cancelled", outcomes: [],
        observation_error: `${error instanceof Error ? error.message : String(error)}; cancellation did not yield terminal readback`,
        execution: { mode: "sequential_nontransactional", rollback: "none", effects_state: "unknown",
          incomplete_step: { step: 1, status: "cancelled", effects: "unknown" } } };
    }
    throw error;
  }
}
