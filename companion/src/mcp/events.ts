import { z } from "zod";
import type { Bridge, TaskClock } from "../bridge.js";
import { luaArray, readsOnly, withFeedFacts } from "./toolPayloads.js";

// A Lua record serialized empty may arrive as [].
const record = (value: unknown) => value === undefined || (Array.isArray(value) && value.length === 0) ? {} : value;

/** Longest next_event wait: under the 31 s code-mode exec yield, so a wait
 *  returns within one call and no cell is abandoned. */
export const NEXT_EVENT_MAX_SECONDS = 25;
export const nextEventSchema = z.object({
  timeout_seconds: z.number().int().min(1).max(NEXT_EVENT_MAX_SECONDS).default(NEXT_EVENT_MAX_SECONDS),
  since_tick: z.number().int().nonnegative().optional(),
}).strict();
export type NextEventInput = z.infer<typeof nextEventSchema>;

/** Rocket, platform and travel events: the kinds of the mod's space event ring. */
export const SPACE_EVENTS = ["rocket_ready", "rocket_launch_ordered", "rocket_launched", "cargo_delivered", "platform_state_changed",
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
/** An own entity destroyed (the mod's loss ring): what, where, how many
 *  of the same merged into the row, when the last went, and what killed it
 *  when the game named it. */
export interface LossRow {
  name: string; position: { x: number; y: number }; surface?: string; count: number; tick: number;
  killed_by?: { name?: string; type?: string; force?: string };
}
/** The mod's cheap event_state probe. */
export interface EventState {
  tick: number; queue_depth: number; fifo_empty: boolean; human_hold: boolean;
  active_plan_id?: number; problem_count?: number; last_problem_tick?: number;
  /** surface: the surface the plan's positions were on (mod 0.22.3 on). */
  last_plan_ended?: { plan_id: number; status: string; tick: number; surface?: string };
  last_research_finished?: { technology: string; tick: number };
  /** True while the body's force has no research running; absent from older mods. */
  research_idle?: boolean;
  last_cancel_all_tick?: number;
  /** The emergency stop's tick while it keeps upkeep off (until a plan finishes). */
  upkeep_off_since_tick?: number;
  /** The newest space event's tick and the last few entries, oldest first. */
  last_space_event_tick?: number; space_events?: SpaceEvent[];
  /** The asking role's watch firings at or after the watch_since it passed, oldest first. */
  watch_fired?: WatchFiring[];
  /** The newest own loss's tick and the last few losses, oldest first (mod 0.32 on). */
  last_loss_tick?: number; losses?: LossRow[];
}
/** A watch the role set (set_watch) crossing its threshold. */
export interface WatchFiring {
  id: number; tick: number; surface?: string; value?: number; produced_per_min?: number;
  condition: { kind: "rate_below" | "consumption_above_production" | "line_below"; item?: string; line?: number; per_min?: number };
}
export interface PackageFailure { package_id: string; reason?: string; tick?: number; at?: string }
/** A package's measured verify metrics (coordination/orders.ts). */
export interface PackageVerificationEvent {
  event: "package_verified" | "package_unmet"; package_id: string; plan_status?: string;
  metrics: unknown[]; reason?: string; tick?: number; at?: string;
}
/** Package failures one session already received, kept across its calls:
 *  null until its first next_event, which treats earlier ones as history. */
export interface FailureDelivery { keys: Set<string> | null }
export interface EventSources {
  /** True while orders this session has not received are waiting. */
  ordersChanged(): boolean;
  /** Packages the bridge failed to queue. */
  packageFailures(): PackageFailure[];
  /** Packages whose verify metrics the bridge measured. */
  packageVerifications?(): PackageVerificationEvent[];
  /** This session's delivery record; without one, failures present when the
   *  call starts count as delivered. */
  delivery?: FailureDelivery;
  /** The session's role: its own watches' firings arrive as watch_fired. */
  role?: string;
}

/** Said wherever research stands still: after a research_finished with
 *  nothing queued, and with a research_idle problem. */
export const RESEARCH_IDLE = "no research is running and labs are idle; the ledger writer picks research in the ledger";
const idleResearch = (state: EventState) => state.research_idle === true ? { research_idle: true } : {};
/** Whether problem rows include labs standing still with no research. */
export const researchIdleProblem = (problems: unknown): boolean =>
  Array.isArray(problems) && problems.some((row) => (row as { cause?: unknown } | null)?.cause === "research_idle");

const realClock: TaskClock = { now: () => Date.now(), sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) };
export const EVENT_POLL_MS = 500;

/** Blocks until something the pilot should act on happens: a plan ends, a
 *  research finishes, the FIFO empties, a machine problem appears, one of the
 *  role's watches fires, own entities are destroyed, a package fails its
 *  check or has its verify measured, the orders change, a human hold starts
 *  or ends; otherwise
 *  times out. A plan_ended event carries the plan's step outcomes and
 *  inventory change, so no follow-up read is needed. */
export async function waitForEvent(bridge: Bridge, input: NextEventInput, sources: EventSources,
  signal?: AbortSignal, clock: TaskClock = realClock): Promise<Record<string, unknown>> {
  const since = input.since_tick;
  // The role's watch firings after since_tick, or (without it) after the
  // first read's tick.
  const role = sources.role;
  let watchSince = since;
  const read = () => role !== undefined && watchSince !== undefined
    ? bridge.call<EventState>("event_state", { role, watch_since: watchSince }) : bridge.call<EventState>("event_state");
  const started = clock.now();
  let previous = await read();
  watchSince ??= previous.tick;
  // Space events after since_tick, or (without it) after the call started.
  const spaceSeen = since ?? previous.last_space_event_tick ?? -1;
  const newSpace = (state: EventState) => (luaArray(state.space_events ?? []) as SpaceEvent[]).filter((row) => row.tick > spaceSeen);
  // Own losses after since_tick, or (without it) after the call started; a
  // merged row comes again with its new count.
  // An RCON read at tick T runs before that tick's update, so a loss
  // stamped T is after the read that returned since_tick T: it counts.
  const lossSeen = since !== undefined ? since - 1 : previous.last_loss_tick ?? -1;
  const newLosses = (state: EventState) => (luaArray(state.losses ?? []) as LossRow[]).filter((row) => row.tick > lossSeen);
  // Space events, watch firings and losses never get lost behind another
  // event: they ride along, since the caller's next since_tick is the
  // returned tick.
  const done = (event: string, state: EventState, details: Record<string, unknown> = {}) => {
    const space = (SPACE_EVENTS as readonly string[]).includes(event) ? [] : newSpace(state);
    const fired = event === "watch_fired" ? [] : luaArray(state.watch_fired ?? []);
    const losses = event === "entities_lost" ? [] : newLosses(state);
    return { event, ...details, ...(space.length > 0 ? { space_events: space } : {}),
      ...(fired.length > 0 ? { watches: fired } : {}), ...(losses.length > 0 ? { losses } : {}), tick: state.tick,
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
    const finished = research ? { research_finished: { technology: research.technology, research_tick: research.tick,
      ...idleResearch(state) } } : {};
    const surface = plan.surface === undefined ? {} : { surface: plan.surface };
    try {
      const status = await bridge.call<{ outcomes?: unknown; inventory_delta?: unknown; source?: string;
        walk_s?: number; tiles?: number; craft_wait_s?: number }>("plan_status", { plan_id: plan.plan_id });
      // Where the plan's time went: walking (seconds, tiles) and waiting on hand-crafts.
      const time = Object.fromEntries((["walk_s", "tiles", "craft_wait_s"] as const)
        .flatMap((key) => typeof status?.[key] === "number" ? [[key, status[key]]] : []));
      return done("plan_ended", state, { plan_id: plan.plan_id, status: plan.status, ...surface,
        ...(status?.source === undefined ? {} : { source: status.source }),
        outcomes: luaArray(status?.outcomes ?? []), inventory_delta: record(status?.inventory_delta), ...time, ...finished });
    } catch { return done("plan_ended", state, { plan_id: plan.plan_id, status: plan.status, ...surface, ...finished }); }
  };
  const watched = (state: EventState) => {
    const rows = luaArray(state.watch_fired ?? []) as WatchFiring[];
    return rows.length > 0 ? done("watch_fired", state, { watches: rows }) : null;
  };
  const lost = (state: EventState) => done("entities_lost", state, { losses: newLosses(state) });
  const researched = (state: EventState) => done("research_finished", state, { technology: state.last_research_finished!.technology,
    research_tick: state.last_research_finished!.tick, ...idleResearch(state) });
  // The problem tick counts machines on every surface: the body's surface's
  // new problems, then the worst ones of every other surface with any, each
  // naming its surface (the Nauvis factory stays visible from orbit).
  const problems = async (since: number, state: EventState) => {
    try {
      const status = await bridge.call<{ problems?: unknown; elsewhere?: unknown }>("factory_status",
        { sections: ["problems", "elsewhere"], since_tick: since });
      const away = luaArray(status?.elsewhere ?? []).flatMap((row: any) => row && typeof row === "object" && row.problems > 0
        ? luaArray(row.top_problems ?? []).map((problem: any) => ({ ...problem, surface: row.surface })) : []);
      // Destroyed buildings arrive in losses (they ride along), not twice.
      const here = luaArray(status?.problems ?? []).filter((row: any) => row?.status !== "destroyed").map(withFeedFacts);
      return done("new_problem", state, { problems: [...here, ...away] });
    } catch { return done("new_problem", state); }
  };
  // A package failure or verify outcome is delivered once per session, by
  // its record, never by comparing ticks: the bridge may record it after this
  // session already saw a later tick.
  const delivery = sources.delivery ?? { keys: null };
  const keyOf = (failure: PackageFailure | PackageVerificationEvent) =>
    `${"event" in failure ? `${failure.event}:` : ""}${failure.package_id}@${failure.at ?? failure.tick ?? ""}`;
  const packageEvents = () => [...sources.packageFailures(), ...(sources.packageVerifications?.() ?? [])];
  if (!delivery.keys) {
    delivery.keys = new Set(packageEvents()
      .filter((failure) => since === undefined || (failure.tick ?? -1) <= since).map(keyOf));
  }
  const keys = delivery.keys;
  const undelivered = (state: EventState) => {
    const next = packageEvents().find((failure) => !keys.has(keyOf(failure)));
    if (!next) return null;
    keys.add(keyOf(next));
    if ("event" in next) {
      const { at: _at, event, tick, ...details } = next as PackageVerificationEvent;
      return done(event, state, { ...details, ...(tick === undefined ? {} : { measured_tick: tick }) });
    }
    const { at: _at, ...details } = next;
    return done("package_failed", state, { ...details });
  };
  if (since !== undefined) {
    const last = previous.last_plan_ended;
    const research = (previous.last_research_finished?.tick ?? -1) > since ? previous.last_research_finished : undefined;
    if (last && last.tick > since) return ended(previous, last, research);
    if ((previous.last_research_finished?.tick ?? -1) > since) return researched(previous);
    if ((previous.last_problem_tick ?? -1) > since) return problems(since, previous);
    const fired = watched(previous);
    if (fired) return fired;
    if ((previous.last_loss_tick ?? -1) >= since) return lost(previous);
    const space = spaceEvent(previous);
    if (space) return space;
  }
  const failedEarlier = undelivered(previous);
  if (failedEarlier) return failedEarlier;
  if (sources.ordersChanged()) return done("orders_changed", previous);
  // An empty queue says when upkeep is off, so nobody counts on it.
  const empty = (state: EventState) => done("queue_empty", state,
    typeof state.upkeep_off_since_tick === "number" ? { upkeep_off_since_tick: state.upkeep_off_since_tick } : {});
  if (since === undefined && previous.fifo_empty && !previous.human_hold) return empty(previous);

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
    const fired = watched(state);
    if (fired) return fired;
    if ((state.last_loss_tick ?? -1) > (previous.last_loss_tick ?? -1)) return lost(state);
    const space = spaceEvent(state);
    if (space) return space;
    const failed = undelivered(state);
    if (failed) return failed;
    if (sources.ordersChanged()) return done("orders_changed", state);
    if (state.fifo_empty && !previous.fifo_empty && !state.human_hold) return empty(state);
    previous = state;
  }
  return done("timeout", previous, { waited_seconds: input.timeout_seconds });
}

export const IDLE_NOW = "the FIFO is empty and the body is idle: queue work now";
/** The same for a role that only reads (strategist, advisor): a fact, never a cue. */
export const IDLE_FACT = "the FIFO is empty and the body is idle";

const at = (point: unknown) => { const p = point as { x?: number; y?: number } | undefined; return `(${p?.x}, ${p?.y})`; };

const itemNames = (list: unknown): string[] => (Array.isArray(list) ? list : []).filter((name): name is string => typeof name === "string");
/** A problem row's feed facts in words, from the inserter that decided its
 *  class: what it holds and what its pickup carries. Facts, never advice. */
export function feedText(row: any): string | null {
  const feed = row?.feed;
  if (!feed || typeof feed !== "object") return null;
  const where = `${row.name} ${at(row.position)} ${row.status}`;
  if (feed.feeders === 0) return `${where}: no inserter drops into it`;
  const inserter = Array.isArray(feed.inserters) ? feed.inserters[0] : undefined;
  if (!inserter || typeof inserter !== "object") return null;
  const missing = feed.missing === "fuel" ? "fuel it burns" : String(feed.missing);
  const its = feed.feeders > 1 ? `one of its ${feed.feeders} inserters, at ${at(inserter.position)},` : `its inserter at ${at(inserter.position)}`;
  const hand = inserter.holding ? `, holding ${inserter.holding}` : "";
  const held = inserter.holding ? `; that inserter holds ${inserter.holding}` : "";
  if (inserter.from === undefined) return `${where}: ${its} has no pickup entity in a charted chunk (${inserter.status}${hand})`;
  if (inserter.lanes === undefined && inserter.items === undefined) {
    return `${where}: ${its} picks from a ${inserter.from} at ${at(inserter.from_position)} whose contents were not read (${inserter.status}${hand})`;
  }
  const lanes = Array.isArray(inserter.lanes) ? inserter.lanes.map(itemNames) : null;
  const carried = lanes ? [...new Set(lanes.flat())] : itemNames(inserter.items);
  const what = carried.length === 0 ? "nothing"
    : `${carried.join(", ")}${inserter.omitted_names ? ` and ${inserter.omitted_names} more` : ""}`;
  const source = `a ${inserter.from} at ${at(inserter.from_position)} ${lanes ? "carrying" : "holding"} ${what}`;
  switch (feed.class) {
    case "foreign_item": return `${where}: ${its} picks from ${source} only, which ${row.name} does not take${held}`;
    case "source_empty": return `${where}: ${its} picks from ${source}; no ${missing} there${held}`;
    default: return `${where}: ${missing} is at the pickup of ${its} (${source}), which is ${inserter.status}${hand}`;
  }
}
/** One watch firing in words: the numbers it compared. */
export function watchText(row: WatchFiring): string {
  const c: Partial<WatchFiring["condition"]> = row.condition ?? {};
  const on = row.surface ? ` on ${row.surface}` : "";
  if (c.kind === "consumption_above_production")
    return `watch ${row.id}: ${c.item} consumed ${row.value}/min${on}, above ${row.produced_per_min}/min made`;
  if (c.kind === "line_below") return `watch ${row.id}: line ${c.line} makes ${row.value}/min${on}, below ${c.per_min}/min`;
  return `watch ${row.id}: ${c.item} made ${row.value}/min${on}, below ${c.per_min}/min`;
}
/** One measured verify metric in words: the value against the stated one. */
function metricText(row: any): string {
  const what = typeof row?.item === "string" ? `${row.item} at least ${row.per_min_at_least}/min`
    : `line at ${at(row?.line_at)} ${row?.state}`;
  const values = row?.measured ?? {};
  if (typeof values.error === "string") return `${what}: ${values.error}`;
  const measured = typeof row?.item === "string" ? `${values.per_min}/min`
    : `line ${values.line_id} ${values.state}${values.cause ? ` (${values.cause})` : ""}, ${values.rate_per_min}/min`;
  return `${what}: ${measured}${row?.met === true ? " (met)" : " (not met)"}`;
}
const platformName = (value: Record<string, unknown>) => (value.platform as { name?: string } | undefined)?.name;

/** A loss in words: how many of what, where, and what killed it. */
export function lossText(row: LossRow): string {
  const by = row.killed_by?.name ?? row.killed_by?.force;
  return `${row.count} ${row.name} at ${at(row.position)}${row.surface ? ` on ${row.surface}` : ""}${by ? ` by ${by}` : ""}`;
}
const lossesText = (rows: LossRow[]) => `own entities destroyed: ${rows.slice(0, 2).map(lossText).join("; ") || "?"}`
  + (rows.length > 2 ? `; ${rows.length - 2} more rows` : "");
/** A plan's outcomes that repeat an earlier step's code at the same action
 *  and target: "<code> again at <action> (<n>th time)". */
function repeatText(outcomes: unknown): string {
  const repeated = (Array.isArray(outcomes) ? outcomes : []).filter((row: any) => typeof row?.repeat === "number");
  return repeated.slice(0, 2).map((row: any) => `; ${row.code} again at step ${row.step} ${row.action} (${row.repeat} in a row)`).join("");
}

function eventText(value: Record<string, unknown>, idleText: string): string {
  switch (value.event) {
    case "plan_ended": {
      const research = value.research_finished as { technology?: string; research_idle?: boolean } | undefined;
      return `plan ${value.plan_id} ended ${value.status}${repeatText(value.outcomes)}`
        + `${research ? `; research ${research.technology} finished` : ""}` + (research?.research_idle ? `: ${RESEARCH_IDLE}` : "");
    }
    case "research_finished": return `research ${value.technology} finished${value.research_idle ? `: ${RESEARCH_IDLE}` : ""}`;
    case "package_failed": return `package ${value.package_id} was not queued: ${value.reason ?? "unknown reason"}`;
    case "package_verified":
    case "package_unmet": {
      const metrics = (Array.isArray(value.metrics) ? value.metrics : []).map(metricText);
      return `package ${value.package_id} ${value.event === "package_verified" ? "verified" : "unmet"}`
        + (value.reason ? `: ${value.reason}` : metrics.length > 0 ? `: ${metrics.join("; ")}` : "");
    }
    case "new_problem": {
      const facts = (Array.isArray(value.problems) ? value.problems : []).map(feedText).filter((text) => text !== null).slice(0, 2);
      return `new machine problem (${Array.isArray(value.problems) ? value.problems.length : "?"} rows)`
        + (researchIdleProblem(value.problems) ? `; ${RESEARCH_IDLE}` : "") + facts.map((text) => `; ${text}`).join("");
    }
    case "watch_fired": {
      const rows = Array.isArray(value.watches) ? value.watches as WatchFiring[] : [];
      return `${rows.length} watch${rows.length === 1 ? "" : "es"} fired: ${rows.slice(0, 2).map(watchText).join("; ")}`
        + (rows.length > 2 ? `; ${rows.length - 2} more in watches` : "");
    }
    case "entities_lost": return lossesText(Array.isArray(value.losses) ? value.losses as LossRow[] : []);
    case "queue_empty": return typeof value.upkeep_off_since_tick === "number"
      ? `${idleText}; upkeep off since stop at tick ${value.upkeep_off_since_tick} until a plan finishes` : idleText;
    case "orders_changed": return "the strategist's orders changed";
    case "human_hold_started": return "a human took the body; plans stay queued";
    case "human_hold_ended": return "the human hold ended; queued plans resume";
    case "rocket_ready": return `a rocket is ready in the silo at ${at(value.silo)}`;
    case "rocket_launch_ordered": return `a rocket launch was ordered at the silo at ${at(value.silo)}${platformName(value) ? ` to platform ${platformName(value)}` : ""}`;
    case "rocket_launched": return `a rocket was launched${value.silo ? ` from ${at(value.silo)}` : ""}${platformName(value) ? ` to platform ${platformName(value)}` : ""}`;
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
 *  not held by a human) says so: the last plan ending is the pilot's cue. A
 *  role that only reads gets the idle fact without the cue. */
export function eventSummary(value: Record<string, unknown>, role?: string): string {
  const idleText = readsOnly(role) ? IDLE_FACT : IDLE_NOW;
  const space = Array.isArray(value.space_events) ? value.space_events.length : 0;
  const along = space > 0 && !(SPACE_EVENTS as readonly string[]).includes(String(value.event));
  const fired = value.event !== "watch_fired" && Array.isArray(value.watches) ? value.watches.length : 0;
  const lost = value.event !== "entities_lost" && Array.isArray(value.losses) ? value.losses as LossRow[] : [];
  const text = `${eventText(value, idleText)}${along ? `; ${space} rocket, platform or travel event${space === 1 ? "" : "s"} in space_events` : ""}`
    + (fired > 0 ? `; ${fired} watch${fired === 1 ? "" : "es"} fired too, in watches` : "")
    + (lost.length > 0 ? `; ${lossesText(lost)}` : "");
  const body = value.body as { fifo_empty?: boolean; human_hold?: boolean } | undefined;
  const idle = body?.fifo_empty === true && body.human_hold !== true;
  return idle && !["queue_empty", "cancelled", "human_hold_started"].includes(String(value.event)) ? `${text}; ${idleText}` : text;
}
