import { z } from "zod";
import type { Bridge, TaskClock } from "../bridge.js";
import { luaArray } from "./toolPayloads.js";

// A Lua record serialized empty may arrive as [].
const record = (value: unknown) => value === undefined || (Array.isArray(value) && value.length === 0) ? {} : value;

export const nextEventSchema = z.object({
  timeout_seconds: z.number().int().min(1).max(120).default(60),
  since_tick: z.number().int().nonnegative().optional(),
}).strict();
export type NextEventInput = z.infer<typeof nextEventSchema>;

/** Rocket, platform and travel events: the kinds of the mod's space event ring. */
export const SPACE_EVENTS = ["rocket_ready", "rocket_launched", "cargo_delivered", "platform_state_changed",
  "platform_arrived", "travel_phase", "body_surface_changed"] as const;
/** One entry of the ring: a silo's position, a platform {index, name}, a
 *  state change's old and new state, the planet a cargo pod landed on, the
 *  location a platform arrived at, a travel step's phase, or the body's move
 *  from one surface to another (and its state there). */
export interface SpaceEvent {
  tick: number; kind: typeof SPACE_EVENTS[number]; silo?: { x: number; y: number };
  platform?: { index: number; name: string }; old?: string; new?: string; surface?: string;
  location?: string; phase?: string; from?: string; to?: string; state?: string;
}
/** The mod's cheap event_state probe. */
export interface EventState {
  tick: number; queue_depth: number; fifo_empty: boolean; human_hold: boolean;
  active_plan_id?: number; problem_count?: number; last_problem_tick?: number;
  /** surface: the surface the plan's positions were on (mod 0.22.3 on). */
  last_plan_ended?: { plan_id: number; status: string; tick: number; surface?: string };
  last_research_finished?: { technology: string; tick: number };
  last_cancel_all_tick?: number;
  /** The newest space event's tick and the last few entries, oldest first. */
  last_space_event_tick?: number; space_events?: SpaceEvent[];
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

/** Blocks until something the pilot should act on happens: a plan ends, a
 *  research finishes, the FIFO empties, a machine problem appears, a package
 *  fails its check, the orders change, a human hold starts or ends; otherwise
 *  times out. A plan_ended event carries the plan's step outcomes and
 *  inventory change, so no follow-up read is needed. */
export async function waitForEvent(bridge: Bridge, input: NextEventInput, sources: EventSources,
  signal?: AbortSignal, clock: TaskClock = realClock): Promise<Record<string, unknown>> {
  const read = () => bridge.call<EventState>("event_state");
  const started = clock.now();
  let previous = await read();
  const since = input.since_tick;
  // Space events after since_tick, or (without it) after the call started.
  const spaceSeen = since ?? previous.last_space_event_tick ?? -1;
  const newSpace = (state: EventState) => (luaArray(state.space_events ?? []) as SpaceEvent[]).filter((row) => row.tick > spaceSeen);
  // Space events never get lost behind another event: they ride along, since
  // the caller's next since_tick is the returned tick.
  const done = (event: string, state: EventState, details: Record<string, unknown> = {}) => {
    const space = (SPACE_EVENTS as readonly string[]).includes(event) ? [] : newSpace(state);
    return { event, ...details, ...(space.length > 0 ? { space_events: space } : {}), tick: state.tick,
      body: { active_plan_id: state.active_plan_id ?? null, queue_depth: state.queue_depth,
        fifo_empty: state.fifo_empty, human_hold: state.human_hold } };
  };
  // The oldest new space event; later ones in the same read come along.
  const spaceEvent = (state: EventState) => {
    const rows = newSpace(state);
    if (rows.length === 0) return null;
    const { tick, kind, ...fields } = rows[0]!;
    return done(kind, state, { ...fields, event_tick: tick, ...(rows.length > 1 ? { space_events: rows } : {}) });
  };
  // A research that finished in the same poll rides along: its tick is
  // older than the returned one, so a later since_tick call would miss it.
  const ended = async (state: EventState, plan: { plan_id: number; status: string; surface?: string }, research?: EventState["last_research_finished"]) => {
    const finished = research ? { research_finished: { technology: research.technology, research_tick: research.tick } } : {};
    const surface = plan.surface === undefined ? {} : { surface: plan.surface };
    try {
      const status = await bridge.call<{ outcomes?: unknown; inventory_delta?: unknown; source?: string }>("plan_status", { plan_id: plan.plan_id });
      return done("plan_ended", state, { plan_id: plan.plan_id, status: plan.status, ...surface,
        ...(status?.source === undefined ? {} : { source: status.source }),
        outcomes: luaArray(status?.outcomes ?? []), inventory_delta: record(status?.inventory_delta), ...finished });
    } catch { return done("plan_ended", state, { plan_id: plan.plan_id, status: plan.status, ...surface, ...finished }); }
  };
  const researched = (state: EventState) => done("research_finished", state, { technology: state.last_research_finished!.technology,
    research_tick: state.last_research_finished!.tick });
  // The problem tick counts machines on every surface: the body's surface's
  // new problems, then the worst ones of every other surface with any, each
  // naming its surface (the Nauvis factory stays visible from orbit).
  const problems = async (since: number, state: EventState) => {
    try {
      const status = await bridge.call<{ problems?: unknown; elsewhere?: unknown }>("factory_status",
        { sections: ["problems", "elsewhere"], since_tick: since });
      const away = luaArray(status?.elsewhere ?? []).flatMap((row: any) => row && typeof row === "object" && row.problems > 0
        ? luaArray(row.top_problems ?? []).map((problem: any) => ({ ...problem, surface: row.surface })) : []);
      return done("new_problem", state, { problems: [...luaArray(status?.problems ?? []), ...away] });
    } catch { return done("new_problem", state); }
  };
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
    const last = previous.last_plan_ended;
    const research = (previous.last_research_finished?.tick ?? -1) > since ? previous.last_research_finished : undefined;
    if (last && last.tick > since) return ended(previous, last, research);
    if ((previous.last_research_finished?.tick ?? -1) > since) return researched(previous);
    if ((previous.last_problem_tick ?? -1) > since) return problems(since, previous);
    const space = spaceEvent(previous);
    if (space) return space;
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
    const last = state.last_plan_ended, before = previous.last_plan_ended;
    const research = state.last_research_finished;
    const newResearch = research && (research.technology !== previous.last_research_finished?.technology
      || research.tick !== previous.last_research_finished?.tick) ? research : undefined;
    if (last && (last.plan_id !== before?.plan_id || last.tick !== before?.tick)) return ended(state, last, newResearch);
    if (newResearch) return researched(state);
    if (state.human_hold !== previous.human_hold) return done(state.human_hold ? "human_hold_started" : "human_hold_ended", state);
    if ((state.last_problem_tick ?? -1) > (previous.last_problem_tick ?? -1)) return problems(previous.tick, state);
    const space = spaceEvent(state);
    if (space) return space;
    const failed = undelivered(state);
    if (failed) return failed;
    if (sources.ordersChanged()) return done("orders_changed", state);
    if (state.fifo_empty && !previous.fifo_empty && !state.human_hold) return done("queue_empty", state);
    previous = state;
  }
  return done("timeout", previous, { waited_seconds: input.timeout_seconds });
}

export const IDLE_NOW = "the FIFO is empty and the body is idle: queue work now";

const at = (point: unknown) => { const p = point as { x?: number; y?: number } | undefined; return `(${p?.x}, ${p?.y})`; };
const platformName = (value: Record<string, unknown>) => (value.platform as { name?: string } | undefined)?.name;

function eventText(value: Record<string, unknown>): string {
  switch (value.event) {
    case "plan_ended": {
      const research = value.research_finished as { technology?: string } | undefined;
      return `plan ${value.plan_id} ended ${value.status}${research ? `; research ${research.technology} finished` : ""}`;
    }
    case "research_finished": return `research ${value.technology} finished`;
    case "package_failed": return `package ${value.package_id} was not queued: ${value.reason ?? "unknown reason"}`;
    case "new_problem": return `new machine problem (${Array.isArray(value.problems) ? value.problems.length : "?"} rows)`;
    case "queue_empty": return IDLE_NOW;
    case "orders_changed": return "the strategist's orders changed";
    case "human_hold_started": return "a human took the body; plans stay queued";
    case "human_hold_ended": return "the human hold ended; queued plans resume";
    case "rocket_ready": return `a rocket is ready in the silo at ${at(value.silo)}`;
    case "rocket_launched": return `a rocket was launched from ${at(value.silo)}${platformName(value) ? ` to platform ${platformName(value)}` : ""}`;
    case "cargo_delivered": return `a cargo pod landed ${platformName(value) ? `on platform ${platformName(value)}` : `on ${value.surface}`}`;
    case "platform_state_changed": return `platform ${platformName(value)}: ${value.old} -> ${value.new}`;
    case "platform_arrived": return `platform ${platformName(value)} arrived at ${value.location}`;
    case "travel_phase": return `travel to ${value.to}: ${value.phase}`;
    case "body_surface_changed": return `the body moved from ${value.from} to ${value.to} (${value.state})`;
    case "timeout": return `nothing happened in ${value.waited_seconds} s`;
    default: return String(value.event);
  }
}

/** One line for the result. With since_tick a FIFO that is already empty
 *  never fires queue_empty again, so any event that finds the body idle (and
 *  not held by a human) says so: the last plan ending is the pilot's cue. */
export function eventSummary(value: Record<string, unknown>): string {
  const space = Array.isArray(value.space_events) ? value.space_events.length : 0;
  const along = space > 0 && !(SPACE_EVENTS as readonly string[]).includes(String(value.event));
  const text = `${eventText(value)}${along ? `; ${space} rocket, platform or travel event${space === 1 ? "" : "s"} in space_events` : ""}`;
  const body = value.body as { fifo_empty?: boolean; human_hold?: boolean } | undefined;
  const idle = body?.fifo_empty === true && body.human_hold !== true;
  return idle && !["queue_empty", "cancelled", "human_hold_started"].includes(String(value.event)) ? `${text}; ${IDLE_NOW}` : text;
}
