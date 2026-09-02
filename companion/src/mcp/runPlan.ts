import { z } from "zod";
import { Bridge, DEFAULT_TASK_TIMEOUT_MS, ModError, type TaskClock } from "../bridge.js";
import type { Task } from "../types.js";
import { normalizeObservation } from "./observation.js";
import { toolPayloads } from "./toolPayloads.js";

const position = { x: z.number(), y: z.number() };
const items = z.record(z.string(), z.number().int().positive());
const step = z.discriminatedUnion("action", [
  z.object({ action: z.literal("walk_to"), ...position }).strict(),
  z.object({ action: z.literal("mine"), ...position, count: z.number().int().min(1).max(200).default(1) }).strict(),
  z.object({ action: z.literal("place_entity"), ...position, name: z.string(), direction: z.number().int().optional() }).strict(),
  z.object({ action: z.literal("craft_items"), recipe: z.string(), count: z.number().int().positive() }).strict(),
  z.object({ action: z.literal("insert_items"), ...position, items }).strict(),
  z.object({ action: z.literal("extract_items"), ...position, items: items.optional() }).strict(),
  z.object({ action: z.literal("set_recipe"), ...position, recipe: z.string() }).strict(),
  z.object({ action: z.literal("rotate_entity"), ...position, direction: z.number().int().min(0).max(15).optional() }).strict(),
  z.object({
    action: z.literal("wait_for_item"), ...position,
    inventory: z.enum(["input", "output", "fuel", "main"]),
    item: z.string(), count: z.number().int().positive(),
    timeout_seconds: z.number().min(1).max(300).default(120),
  }).strict(),
]);

export const runPlanSchema = z.object({
  steps: z.array(step).min(1).max(25),
  final_observation_radius: z.number().int().min(5).max(30).default(15),
}).strict();

export type RunPlanInput = z.infer<typeof runPlanSchema>;
type PlanStep = RunPlanInput["steps"][number];

export type PlanOutcome =
  | { step: number; action: PlanStep["action"]; status: "completed"; result: string }
  | { step: number; action: PlanStep["action"]; status: "failed" | "cancelled"; error: string };

export interface RunPlanResult {
  status: "completed" | "failed" | "cancelled";
  completed_steps: number;
  outcomes: PlanOutcome[];
  failed_step?: { step: number; action: PlanStep["action"]; error: string };
  observation?: Record<string, unknown>;
  observation_error?: string;
}

const realClock: TaskClock = {
  now: Date.now,
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
};

function taskFor(step: Exclude<PlanStep, { action: "wait_for_item" }>): Task {
  switch (step.action) {
    case "walk_to": return { type: "walk_to", ...toolPayloads.target({ x: step.x, y: step.y }) };
    case "mine": return { type: "mine", ...toolPayloads.mine(step) };
    case "place_entity": return { type: "place", ...toolPayloads.place(step) };
    case "craft_items": return { type: "craft", recipe: step.recipe, count: step.count };
    case "insert_items": return { type: "insert", ...toolPayloads.insert(step) };
    case "extract_items": return { type: "extract", ...toolPayloads.extract(step) };
    case "set_recipe": return { type: "set_recipe", ...toolPayloads.recipe(step) };
    case "rotate_entity": return { type: "rotate", ...toolPayloads.rotate(step) };
  }
}

function abortError(): ModError {
  return new ModError("run_plan was cancelled");
}

async function waitForItem(
  bridge: Bridge,
  step: Extract<PlanStep, { action: "wait_for_item" }>,
  planDeadline: number,
  signal: AbortSignal | undefined,
  clock: TaskClock,
): Promise<string> {
  const deadline = Math.min(planDeadline, clock.now() + step.timeout_seconds * 1000);
  while (true) {
    if (signal?.aborted) throw abortError();
    const response = await bridge.call<{ entities?: Array<Record<string, unknown>> }>(
      "inspect", toolPayloads.inspect([{ x: step.x, y: step.y }]),
    );
    if (signal?.aborted) throw abortError();
    if (clock.now() >= deadline) throw new ModError(`timed out waiting for ${step.count} ${step.item} in ${step.inventory}`);
    const entity = response.entities?.[0];
    if (!entity || typeof entity.error === "string") {
      throw new ModError(typeof entity?.error === "string" ? entity.error : "inspect returned no entity");
    }
    const inventories = entity.inventories as Record<string, Record<string, number>> | undefined;
    const found = inventories?.[step.inventory]?.[step.item] ?? 0;
    if (found >= step.count) return `${step.inventory} has ${found} ${step.item}`;
    const remaining = deadline - clock.now();
    if (remaining <= 0) throw new ModError(`timed out waiting for ${step.count} ${step.item} in ${step.inventory}`);
    await clock.sleep(Math.min(500, remaining));
  }
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export async function executeRunPlan(
  bridge: Bridge,
  input: RunPlanInput,
  signal?: AbortSignal,
  clock: TaskClock = realClock,
): Promise<RunPlanResult> {
  const deadline = clock.now() + DEFAULT_TASK_TIMEOUT_MS;
  const outcomes: PlanOutcome[] = [];
  let terminal: RunPlanResult;

  try {
    for (let index = 0; index < input.steps.length; index++) {
      const current = input.steps[index]!;
      if (signal?.aborted) throw abortError();
      if (clock.now() >= deadline) throw new ModError("run_plan exceeded its 570-second deadline");
      const detail = current.action === "wait_for_item"
        ? await waitForItem(bridge, current, deadline, signal, clock)
        : await bridge.enqueueAndWait(taskFor(current), { deadlineMs: deadline, signal, clock });
      outcomes.push({ step: index + 1, action: current.action, status: "completed", result: detail });
    }
    terminal = { status: "completed", completed_steps: outcomes.length, outcomes };
  } catch (error) {
    const next = input.steps[outcomes.length];
    const attemptedStep = outcomes.length + 1;
    const cancelled = signal?.aborted || /cancelled/i.test(errorText(error));
    const status = cancelled ? "cancelled" : "failed";
    const message = errorText(error);
    if (next) outcomes.push({ step: attemptedStep, action: next.action, status, error: message });
    terminal = {
      status,
      completed_steps: attemptedStep - 1,
      outcomes,
      ...(next ? { failed_step: { step: attemptedStep, action: next.action, error: message } } : {}),
    };
  }

  try {
    terminal.observation = normalizeObservation(await bridge.call("observe_local", { radius: input.final_observation_radius }));
  } catch (error) {
    terminal.observation_error = errorText(error);
    if (terminal.status === "completed") terminal.status = "failed";
  }
  return terminal;
}
