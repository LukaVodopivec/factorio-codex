import { z } from "zod";
import type { Bridge, TaskClock } from "../bridge.js";
import { luaArray } from "./toolPayloads.js";

export const nextEventSchema = z.object({
  timeout_seconds: z.number().int().min(1).max(120).default(60),
  since_tick: z.number().int().nonnegative().optional(),
}).strict();
export type NextEventInput = z.infer<typeof nextEventSchema>;

/** The mod's cheap event_state probe. */
export interface EventState {
  tick: number; queue_depth: number; fifo_empty: boolean; human_hold: boolean;
  active_plan_id?: number; problem_count?: number; last_problem_tick?: number;
  last_plan_ended?: { plan_id: number; status: string; tick: number };
}
export interface PackageFailure { package_id: string; reason?: string; tick?: number; at?: string }
/** Package failures one session already received, kept across its calls:
 *  null until its first next_event, which treats earlier ones as history. */
export interface FailureDelivery { keys: Set<string> | null }
export interface EventSources {
  /** True while orders this session has not received are waiting. */
  ordersChanged(): boolean;
  /** Packages the bridge failed to queue. */
  packageFailures(): PackageFailure[];
  /** This session's delivery record; without one, failures present when the
   *  call starts count as delivered. */
  delivery?: FailureDelivery;
}

const realClock: TaskClock = { now: () => Date.now(), sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) };
export const EVENT_POLL_MS = 500;

/** Blocks until something the pilot should act on happens: a plan ends, the
 *  FIFO empties, a machine problem appears, a package fails its check, the
 *  orders change, a human hold starts or ends; otherwise times out. */
export async function waitForEvent(bridge: Bridge, input: NextEventInput, sources: EventSources,
  signal?: AbortSignal, clock: TaskClock = realClock): Promise<Record<string, unknown>> {
  const read = () => bridge.call<EventState>("event_state");
  const started = clock.now();
  let previous = await read();
  const done = (event: string, state: EventState, details: Record<string, unknown> = {}) => ({
    event, ...details, tick: state.tick,
    body: { active_plan_id: state.active_plan_id ?? null, queue_depth: state.queue_depth,
      fifo_empty: state.fifo_empty, human_hold: state.human_hold },
  });
  const problems = async (since: number, state: EventState) => {
    try {
      const status = await bridge.call<{ problems?: unknown }>("factory_status", { sections: ["problems"], since_tick: since });
      return done("new_problem", state, { problems: luaArray(status?.problems ?? []) });
    } catch { return done("new_problem", state); }
  };
  const since = input.since_tick;
  // A package failure is delivered once per session, by its record, never by
  // comparing ticks: the bridge may record it after this session already saw
  // a later tick.
  const delivery = sources.delivery ?? { keys: null };
  const keyOf = (failure: PackageFailure) => `${failure.package_id}@${failure.at ?? failure.tick ?? ""}`;
  if (!delivery.keys) {
    delivery.keys = new Set(sources.packageFailures()
      .filter((failure) => since === undefined || (failure.tick ?? -1) <= since).map(keyOf));
  }
  const keys = delivery.keys;
  const undelivered = (state: EventState) => {
    const failed = sources.packageFailures().find((failure) => !keys.has(keyOf(failure)));
    if (!failed) return null;
    keys.add(keyOf(failed));
    const { at: _at, ...details } = failed;
    return done("package_failed", state, { ...details });
  };
  if (since !== undefined) {
    const ended = previous.last_plan_ended;
    if (ended && ended.tick > since) return done("plan_ended", previous, { plan_id: ended.plan_id, status: ended.status });
    if ((previous.last_problem_tick ?? -1) > since) return problems(since, previous);
  }
  const failedEarlier = undelivered(previous);
  if (failedEarlier) return failedEarlier;
  if (sources.ordersChanged()) return done("orders_changed", previous);
  if (since === undefined && previous.fifo_empty && !previous.human_hold) return done("queue_empty", previous);

  const deadline = started + input.timeout_seconds * 1_000;
  while (clock.now() < deadline) {
    if (signal?.aborted) return done("cancelled", previous);
    await clock.sleep(Math.min(EVENT_POLL_MS, deadline - clock.now()));
    if (signal?.aborted) return done("cancelled", previous);
    const state = await read();
    const ended = state.last_plan_ended, before = previous.last_plan_ended;
    if (ended && (ended.plan_id !== before?.plan_id || ended.tick !== before?.tick)) {
      return done("plan_ended", state, { plan_id: ended.plan_id, status: ended.status });
    }
    if (state.human_hold !== previous.human_hold) return done(state.human_hold ? "human_hold_started" : "human_hold_ended", state);
    if ((state.last_problem_tick ?? -1) > (previous.last_problem_tick ?? -1)) return problems(previous.tick, state);
    const failed = undelivered(state);
    if (failed) return failed;
    if (sources.ordersChanged()) return done("orders_changed", state);
    if (state.fifo_empty && !previous.fifo_empty && !state.human_hold) return done("queue_empty", state);
    previous = state;
  }
  return done("timeout", previous, { waited_seconds: input.timeout_seconds });
}

export const IDLE_NOW = "the FIFO is empty and the body is idle: queue work now";

function eventText(value: Record<string, unknown>): string {
  switch (value.event) {
    case "plan_ended": return `plan ${value.plan_id} ended ${value.status}`;
    case "package_failed": return `package ${value.package_id} was not queued: ${value.reason ?? "unknown reason"}`;
    case "new_problem": return `new machine problem (${Array.isArray(value.problems) ? value.problems.length : "?"} rows)`;
    case "queue_empty": return IDLE_NOW;
    case "orders_changed": return "Astra's orders changed";
    case "human_hold_started": return "a human took the body; plans stay queued";
    case "human_hold_ended": return "the human hold ended; queued plans resume";
    case "timeout": return `nothing happened in ${value.waited_seconds} s`;
    default: return String(value.event);
  }
}

/** One line for the result. With since_tick a FIFO that is already empty
 *  never fires queue_empty again, so any event that finds the body idle (and
 *  not held by a human) says so: the last plan ending is the pilot's cue. */
export function eventSummary(value: Record<string, unknown>): string {
  const text = eventText(value);
  const body = value.body as { fifo_empty?: boolean; human_hold?: boolean } | undefined;
  const idle = body?.fifo_empty === true && body.human_hold !== true;
  return idle && !["queue_empty", "cancelled", "human_hold_started"].includes(String(value.event)) ? `${text}; ${IDLE_NOW}` : text;
}
