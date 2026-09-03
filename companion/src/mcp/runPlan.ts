import { z } from "zod";
import { DEFAULT_TASK_TIMEOUT_MS, ModError, TaskCancelledError, type TaskClock } from "../bridge.js";
import type { Bridge } from "../bridge.js";
import { normalizeObservation } from "./observation.js";

const position = { x: z.number(), y: z.number() };
const items = z.record(z.string(), z.number().int().positive());
export const planStepSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("walk_to"), ...position }).strict(),
  z.object({ action: z.literal("mine"), ...position, count: z.number().int().min(1).max(200).default(1), target_kind: z.enum(["natural", "owned"]).default("natural"), allow_fluid_loss: z.boolean().default(false) }).strict(),
  z.object({ action: z.literal("pickup_items"), ...position, item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict(),
  z.object({ action: z.literal("place_entity"), ...position, name: z.string(), direction: z.number().int().optional(), output_target: z.object(position).strict().optional() }).strict(),
  z.object({ action: z.literal("craft_items"), recipe: z.string(), crafts: z.number().int().min(1).max(100), wait_for_completion: z.boolean().default(true) }).strict(),
  z.object({ action: z.literal("insert_items"), ...position, items }).strict(),
  z.object({ action: z.literal("extract_items"), ...position, items: items.optional() }).strict(),
  z.object({ action: z.literal("set_recipe"), ...position, recipe: z.string() }).strict(),
  z.object({ action: z.literal("rotate_entity"), ...position, direction: z.number().int().min(0).max(15).optional() }).strict(),
  z.object({ action: z.literal("wait_for_item"), ...position, inventory: z.enum(["input", "output", "fuel", "main"]), item: z.string(), count: z.number().int().positive(), timeout_seconds: z.number().min(1).max(300).default(120) }).strict(),
]);
export const queuePlanSchema = z.object({
  steps: z.array(planStepSchema).min(1).max(25),
  final_observation_radius: z.number().int().min(5).max(30).default(15),
  observation_detail: z.enum(["compact", "full"]).default("compact"),
  after_plan_id: z.number().int().positive().optional(),
}).strict();
export const runPlanSchema = queuePlanSchema;
export type RunPlanInput = z.infer<typeof runPlanSchema>;
export interface PlanOutcome { step: number; action: RunPlanInput["steps"][number]["action"]; status: "completed" | "failed" | "cancelled"; result?: string; error?: string }
export interface RunPlanResult {
  plan_id?: number; status: "completed" | "failed" | "cancelled"; source_tick?: number;
  position?: { x: number; y: number }; current_step?: number; completed_steps: number;
  total_steps?: number; outcomes: PlanOutcome[]; queue_depth?: number;
  observation?: Record<string, unknown>; observation_error?: string;
}
const realClock: TaskClock = { now: Date.now, sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) };

export async function executeRunPlan(bridge: Bridge, input: RunPlanInput, signal?: AbortSignal, clock: TaskClock = realClock): Promise<RunPlanResult> {
  if (signal?.aborted) return { status: "cancelled", completed_steps: 0, outcomes: [] };
  const { plan_id } = await bridge.call<{ plan_id: number }>("queue_plan", input);
  const deadline = clock.now() + DEFAULT_TASK_TIMEOUT_MS;
  try {
    while (clock.now() < deadline) {
      if (signal?.aborted) throw new TaskCancelledError("run_plan was cancelled");
      await clock.sleep(Math.min(500, deadline - clock.now()));
      if (signal?.aborted) throw new TaskCancelledError("run_plan was cancelled");
      const status = await bridge.call<RunPlanResult>("plan_status", { plan_id });
      if (["completed", "failed", "cancelled"].includes(status.status)) {
        if (status.observation) status.observation = normalizeObservation(status.observation);
        return status;
      }
    }
    throw new ModError("run_plan gave up after 570s");
  } catch (error) {
    await bridge.call("cancel", { plan_id }).catch(() => {});
    if (error instanceof TaskCancelledError || signal?.aborted) {
      return { plan_id, status: "cancelled", completed_steps: 0, outcomes: [], observation_error: error instanceof Error ? error.message : String(error) };
    }
    throw error;
  }
}
