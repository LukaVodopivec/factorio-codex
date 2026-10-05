import { z } from "zod";
import { DEFAULT_TASK_TIMEOUT_MS, holdAwareDeadline, TaskCancelledError, type TaskClock } from "../bridge.js";
import type { Bridge } from "../bridge.js";
import { normalizeObservation } from "./observation.js";

const position = { x: z.number(), y: z.number() };
const point = z.object(position).strict();
const items = z.record(z.string(), z.number().int().positive());
const offset = z.object({ dx: z.number(), dy: z.number() }).strict();
const direction = z.number().int().min(0).max(15);
/** A stored blueprint's name (the mod's rule). */
export const blueprintName = z.string().min(1).max(64)
  .regex(/^[A-Za-z0-9][A-Za-z0-9 ._-]*$/, "blueprint names are letters, digits, spaces, dots, dashes or underscores");
/** Relative layout the mod sites, checks, supplies, clears and builds (build_layout). */
/** A layout has entities, or only connections from an anchor (a route that
 *  joins what already stands); the mod checks the same rule. */
export const layoutEntitiesRule = (layout: { anchor?: unknown; entities: unknown[]; connections?: unknown[] }) =>
  layout.entities.length > 0 || (layout.anchor !== undefined && (layout.connections?.length ?? 0) > 0);
export const layoutEntitiesMessage = { message: "a layout needs entities, or connections from an anchor" };
export const layoutFields = {
  anchor: point.optional(),
  site: z.object({ near: point, on_resource: z.string().min(1).optional(), near_water: z.boolean().optional() }).strict().optional(),
  entities: z.array(z.object({ name: z.string().min(1), dx: z.number(), dy: z.number(),
    direction: direction.optional(), recipe: z.string().min(1).optional(), insert: items.optional(),
    settings: z.record(z.string(), z.unknown()).optional() }).strict()).max(100),
  connections: z.array(z.object({ kind: z.enum(["belt", "pipe", "power"]), prototype: z.string().min(1),
    from: offset, to: offset, underground: z.union([z.string().min(1), z.literal(false)]).optional() }).strict()).max(32).optional(),
};
/** Parametric block expanded by the mod into a layout (build_block); a
 *  blueprint block is a stored blueprint. */
export const blockFields = {
  block: z.enum(["mining", "smelting", "assembly", "power", "labs", "blueprint"]),
  count: z.number().int().min(1).max(24).optional(),
  resource: z.string().min(1).optional(),
  recipe: z.string().min(1).optional(),
  blueprint: blueprintName.optional(),
  near: point.optional(),
};
/** An area {left_top, right_bottom}, or center with radius (at most 64 x 64 tiles). */
export const areaFields = {
  area: z.object({ left_top: point, right_bottom: point }).strict().optional(),
  center: point.optional(),
  radius: z.number().positive().max(32).optional(),
};
export const moveEntityFields = { from: point, to: point, direction: direction.optional(), allow_fluid_loss: z.boolean().optional() };
export const exploreFields = { resource: z.string().min(1).optional(), direction: direction.optional(),
  max_distance: z.number().int().min(32).max(3000) };
export const blueprintPlaceFields = { name: blueprintName, position: point,
  direction: z.number().int().min(0).max(12).multipleOf(4).optional(), flip: z.enum(["horizontal", "vertical"]).optional(),
  mode: z.enum(["hand", "ghosts"]).optional() };
export const deconstructFields = { ...areaFields, mode: z.enum(["hand", "robots", "cancel"]).optional(),
  filter: z.array(z.string().min(1)).min(1).max(32).optional() };
export const upgradeFields = { ...areaFields, from: z.string().min(1), to: z.string().min(1), mode: z.enum(["hand", "robots"]).optional() };
export const copySettingsFields = { from: point, to: z.array(point).min(1).max(32) };
/** insert_items: one position with items, or several targets that each get
 *  the same items (per_target or items). */
export const insertFields = {
  x: z.number().optional(), y: z.number().optional(),
  targets: z.union([z.array(point).min(1).max(32),
    z.object({ name: z.string().min(1), near: point, radius: z.number().positive().max(32).optional() }).strict()]).optional(),
  items: items.optional(), per_target: items.optional(),
};
const autoSupply = { auto_supply: z.boolean().optional() };
const planSteps = [
  z.object({ action: z.literal("walk_to"), ...position,
    arrival_mode: z.enum(["exact", "vicinity"]).default("exact"),
    arrival_radius: z.number().min(0.5, "arrival_radius is 0.5–6 tiles").max(6, "arrival_radius is 0.5–6 tiles; for a farther goal walk to the target and use vicinity arrival").default(1) }).strict(),
  z.object({ action: z.literal("mine"), ...position, count: z.number().int().min(1).max(200).default(1), target_kind: z.enum(["natural", "owned"]).optional(), allow_fluid_loss: z.boolean().default(false), expected_name: z.string().min(1).optional(), observed_tick: z.number().int().nonnegative().optional() }).strict(),
  z.object({ action: z.literal("pickup_items"), ...position, item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict(),
  z.object({ action: z.literal("place_entity"), ...position, name: z.string(), direction: z.number().int().optional(), input_target: point.optional(), output_target: point.optional(), belt_to_ground_type: z.enum(["input", "output"]).optional(), insert: items.optional(), ...autoSupply }).strict(),
  z.object({ action: z.literal("craft_items"), recipe: z.string(), crafts: z.number().int().min(1).max(100), wait_for_completion: z.boolean().optional() }).strict(),
  z.object({ action: z.literal("insert_items"), ...insertFields, ...autoSupply }).strict(),
  z.object({ action: z.literal("extract_items"), ...position, items: items.optional() }).strict(),
  z.object({ action: z.literal("set_recipe"), ...position, recipe: z.string() }).strict(),
  z.object({ action: z.literal("rotate_entity"), ...position, direction: direction.optional() }).strict(),
  z.object({ action: z.literal("inspect_entities"), positions: z.array(point).min(1).max(16) }).strict(),
  z.object({ action: z.literal("wait_for_item"), ...position, inventory: z.enum(["input", "output", "fuel", "main"]), item: z.string(), count: z.number().int().positive(), timeout_seconds: z.number().min(1).max(300).default(120) }).strict(),
  z.object({ action: z.literal("wait_for_research"), technology: z.string().min(1), timeout_seconds: z.number().min(1).max(300).default(120) }).strict(),
  z.object({ action: z.literal("get_items"), item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict(),
  z.object({ action: z.literal("build_layout"), ...layoutFields }).strict(),
  z.object({ action: z.literal("build_block"), ...blockFields }).strict(),
  z.object({ action: z.literal("explore"), ...exploreFields }).strict(),
  z.object({ action: z.literal("move_entity"), ...moveEntityFields }).strict(),
  z.object({ action: z.literal("blueprint_place"), ...blueprintPlaceFields }).strict(),
  z.object({ action: z.literal("build_ghosts"), ...areaFields }).strict(),
  z.object({ action: z.literal("deconstruct_area"), ...deconstructFields }).strict(),
  z.object({ action: z.literal("upgrade_area"), ...upgradeFields }).strict(),
  z.object({ action: z.literal("copy_settings"), ...copySettingsFields }).strict(),
] as const;
export const planStepSchema = z.discriminatedUnion("action", [...planSteps]);
/** A build package may also start with blueprint captures, which the bridge
 *  makes before it queues the package's other steps. */
export const captureFields = { name: blueprintName, ...areaFields };
export const packageStepSchema = z.discriminatedUnion("action", [...planSteps,
  z.object({ action: z.literal("blueprint_capture"), ...captureFields }).strict()]);
export type PlanStep = z.infer<typeof planStepSchema>;
export type PackageStep = z.infer<typeof packageStepSchema>;

/** Cross-field rules one step's object schema cannot express; a message or null. */
export function areaIssue(value: { area?: unknown; center?: unknown; radius?: unknown }): string | null {
  const centred = value.center !== undefined || value.radius !== undefined;
  if ((value.area === undefined) === !centred) return "give either area {left_top, right_bottom} or center with radius";
  if (centred && (value.center === undefined || value.radius === undefined)) return "center and radius go together";
  return null;
}
export function insertIssue(value: { x?: number; y?: number; targets?: unknown; items?: unknown; per_target?: unknown }): string | null {
  if ((value.items === undefined) === (value.per_target === undefined)) return "give items or per_target, not both";
  if (value.targets === undefined) {
    if (value.x === undefined || value.y === undefined) return "give x and y, or targets";
    if (value.per_target !== undefined) return "per_target goes with targets; use items for one position";
  } else if (value.x !== undefined || value.y !== undefined) return "give x and y, or targets, not both";
  return null;
}
export function blockIssue(value: { block: string; count?: number; blueprint?: string }): string | null {
  if (value.block === "blueprint") return value.blueprint === undefined ? "a blueprint block names its blueprint" : null;
  if (value.blueprint !== undefined) return "blueprint goes with block: \"blueprint\"";
  return value.count === undefined ? `a ${value.block} block needs count` : null;
}
export function stepIssue(step: PackageStep): string | null {
  switch (step.action) {
    case "walk_to": return step.arrival_mode === "exact" && step.arrival_radius !== 1
      ? "exact arrival uses the fixed 1-tile tolerance; use vicinity for a wider radius" : null;
    case "build_layout": return (step.anchor === undefined) === (step.site === undefined) ? "build_layout takes exactly one of anchor or site" : null;
    case "build_block": return blockIssue(step);
    case "insert_items": return insertIssue(step);
    case "build_ghosts": case "deconstruct_area": case "upgrade_area": case "blueprint_capture": return areaIssue(step);
    default: return null;
  }
}
export const MAX_PLAN_STEPS = 200;
export const queuePlanSchema = z.object({
  steps: z.array(planStepSchema).min(1).max(MAX_PLAN_STEPS),
  final_observation_radius: z.number().int().min(5, "final_observation_radius is an integer 5–30 (default 15)").max(30, "final_observation_radius is an integer 5–30 (default 15)").default(15),
  observation_detail: z.enum(["none", "compact"]).default("none"),
  after_plan_id: z.number().int().positive().optional(),
}).strict().superRefine((plan, context) => {
  plan.steps.forEach((step, index) => {
    const issue = stepIssue(step);
    if (issue) context.addIssue({ code: "custom", path: ["steps", index], message: issue });
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

/** tool names the MCP tool for a cancel's origin. */
export async function executeRunPlan(bridge: Bridge, input: RunPlanInput, signal?: AbortSignal, clock: TaskClock = realClock,
  tool = "run_plan"): Promise<RunPlanResult> {
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
    await bridge.call("cancel", { plan_id, origin: `${tool}/run_plan-abort` }).catch(() => {});
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
