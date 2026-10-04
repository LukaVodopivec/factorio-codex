import { z } from "zod";
import { DEFAULT_TASK_TIMEOUT_MS, holdAwareDeadline, TaskCancelledError, type TaskClock } from "../bridge.js";
import type { Bridge } from "../bridge.js";
import { normalizeObservation } from "./observation.js";

const position = { x: z.number(), y: z.number() };
const point = z.object(position).strict();
const items = z.record(z.string(), z.number().int().positive());
const offset = z.object({ dx: z.number(), dy: z.number() }).strict();
/** Relative layout the mod sites, checks, supplies, clears and builds (build_layout). */
export const layoutFields = {
  anchor: point.optional(),
  site: z.object({ near: point, on_resource: z.string().min(1).optional(), near_water: z.boolean().optional() }).strict().optional(),
  entities: z.array(z.object({ name: z.string().min(1), dx: z.number(), dy: z.number(),
    direction: z.number().int().min(0).max(15).optional(), recipe: z.string().min(1).optional() }).strict()).min(1).max(100),
  connections: z.array(z.object({ kind: z.enum(["belt", "pipe", "power"]), prototype: z.string().min(1),
    from: offset, to: offset }).strict()).max(32).optional(),
};
/** Parametric block expanded by the mod into a layout (build_block). */
export const blockFields = {
  block: z.enum(["mining", "smelting", "assembly", "power", "labs"]),
  count: z.number().int().min(1).max(32),
  resource: z.string().min(1).optional(),
  recipe: z.string().min(1).optional(),
  near: point.optional(),
};
const autoSupply = { auto_supply: z.boolean().optional() };
export const planStepSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("walk_to"), ...position,
    arrival_mode: z.enum(["exact", "vicinity"]).default("exact"),
    arrival_radius: z.number().min(0.5, "arrival_radius is 0.5–6 tiles").max(6, "arrival_radius is 0.5–6 tiles; for a farther goal walk to the target and use vicinity arrival").default(1) }).strict(),
  z.object({ action: z.literal("mine"), ...position, count: z.number().int().min(1).max(200).default(1), target_kind: z.enum(["natural", "owned"]).optional(), allow_fluid_loss: z.boolean().default(false), expected_name: z.string().min(1).optional(), observed_tick: z.number().int().nonnegative().optional() }).strict(),
  z.object({ action: z.literal("pickup_items"), ...position, item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict(),
  z.object({ action: z.literal("place_entity"), ...position, name: z.string(), direction: z.number().int().optional(), input_target: point.optional(), output_target: point.optional(), belt_to_ground_type: z.enum(["input", "output"]).optional(), ...autoSupply }).strict(),
  z.object({ action: z.literal("craft_items"), recipe: z.string(), crafts: z.number().int().min(1).max(100), wait_for_completion: z.boolean().default(true) }).strict(),
  z.object({ action: z.literal("insert_items"), ...position, items, ...autoSupply }).strict(),
  z.object({ action: z.literal("extract_items"), ...position, items: items.optional() }).strict(),
  z.object({ action: z.literal("set_recipe"), ...position, recipe: z.string() }).strict(),
  z.object({ action: z.literal("rotate_entity"), ...position, direction: z.number().int().min(0).max(15).optional() }).strict(),
  z.object({ action: z.literal("inspect_entities"), positions: z.array(point).min(1).max(16) }).strict(),
  z.object({ action: z.literal("wait_for_item"), ...position, inventory: z.enum(["input", "output", "fuel", "main"]), item: z.string(), count: z.number().int().positive(), timeout_seconds: z.number().min(1).max(300).default(120) }).strict(),
  z.object({ action: z.literal("wait_for_research"), technology: z.string().min(1), timeout_seconds: z.number().min(1).max(300).default(120) }).strict(),
  z.object({ action: z.literal("get_items"), item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict(),
  z.object({ action: z.literal("build_layout"), ...layoutFields }).strict(),
  z.object({ action: z.literal("build_block"), ...blockFields }).strict(),
]);
export const MAX_PLAN_STEPS = 200;
export const queuePlanSchema = z.object({
  steps: z.array(planStepSchema).min(1).max(MAX_PLAN_STEPS),
  final_observation_radius: z.number().int().min(5, "final_observation_radius is an integer 5–30 (default 15)").max(30, "final_observation_radius is an integer 5–30 (default 15)").default(15),
  observation_detail: z.enum(["none", "compact"]).default("none"),
  after_plan_id: z.number().int().positive().optional(),
}).strict().superRefine((plan, context) => {
  plan.steps.forEach((step, index) => {
    if (step.action === "walk_to" && step.arrival_mode === "exact" && step.arrival_radius !== 1) {
      context.addIssue({ code: "custom", path: ["steps", index, "arrival_radius"],
        message: "exact arrival uses the fixed 1-tile tolerance; use vicinity for a wider radius" });
    }
    if (step.action === "build_layout" && (step.anchor === undefined) === (step.site === undefined)) {
      context.addIssue({ code: "custom", path: ["steps", index], message: "build_layout takes exactly one of anchor or site" });
    }
  });
});
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
  /** Present only when a human hold delayed this plan: delayed, not failed. */
  human_control?: boolean;
  /** The body's FIFO state from the same Lua read; human_control is the current hold. */
  fifo?: { human_control?: boolean };
  summary?: string;
}
const realClock: TaskClock = { now: () => Date.now(), sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) };

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
  // Time under a human hold is not charged and never cancels the plan: past
  // the return guard the plan stays queued and the caller waits on plan_status.
  const started = clock.now();
  const budget = holdAwareDeadline(clock, started + DEFAULT_TASK_TIMEOUT_MS);
  try {
    for (;;) {
      if (signal?.aborted) throw new TaskCancelledError("run_plan was cancelled");
      const status = await bridge.call<RunPlanResult>("plan_status", { plan_id });
      budget.sample(status.fifo?.human_control === true);
      if (isTerminal(status)) {
        if (status.observation) status.observation = normalizeObservation(status.observation);
        return status;
      }
      if (budget.remaining() <= 0) {
        // The call returns before the MCP timeout but never cancels: the mod
        // owns the plan's active budget (up to 12 s per step, so a large
        // build_layout or build_block may run well past 570 s). Report the
        // latest read, not the plan's sticky hold marker.
        const { human_control: _sticky, ...latest } = status;
        return { ...latest, ...(budget.holding ? { human_control: true } : {}),
          wait: { condition: "terminal", timed_out: true, waited_ms: Math.max(0, clock.now() - started) },
          summary: budget.holding
            ? `plan ${plan_id} is still ${status.status}: a human holds the body, so nothing was cancelled; it runs in order once they are idle, so wait with next_event`
            : budget.parked()
              ? `plan ${plan_id} is still ${status.status} at the call time limit after an earlier human hold delayed it; nothing was cancelled, so wait with next_event`
              : `plan ${plan_id} is still ${status.status} at the 570 s call limit; nothing was cancelled and the mod enforces the plan's own budget, so wait with next_event` };
      }
      await clock.sleep(Math.min(1_000, budget.remaining()));
    }
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
