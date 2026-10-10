// The strategist's orders and build packages, read from the current run's
// operations.json. Tool results carry the orders once per new ledger revision,
// and one full-surface bridge queues each new package into the FIFO by itself,
// first making the blueprint captures a package starts with, while the body
// is on the package's surface. The same bridge queues the ledger's research
// once per revision that lists any, records when each package's plan ended
// and how, and measures a package's verify metrics once its plan has ended
// and settled.
import fs from "node:fs";
import path from "node:path";
import { ModError, WriterRetiredError, type Bridge } from "../bridge.js";
import type { PackageVerificationEvent } from "../mcp/events.js";
import { queuePlanSchema } from "../mcp/runPlan.js";
import { luaArray, toolPayloads } from "../mcp/toolPayloads.js";
import { atomicWriteFile } from "../setup/atomic.js";
import { operationsLedgerSchema, verifySchema, type OperationsLedger, type VerifyMetric } from "./ledger.js";

export type RunDir = () => string | null;
type BuildPackage = OperationsLedger["build_packages"][number];
export interface PackageRecord {
  /** queuing: the queue_plan call was sent without a recorded answer;
   *  waiting_surface: the body is on another surface than the package's (not
   *  a failure: it is queued once the body is back). */
  status: "queuing" | "waiting_surface" | "queued" | "failed"; revision: number; at: string;
  tick?: number; plan_id?: number; reason?: string;
  /** Blueprints captured for the package, as each capture returned them
   *  (also when its check failed); a package of captures only has no plan. */
  captured?: CapturedBlueprint[];
  /** Its steps lay tiles or remove entities: a successor waits for its end even after the ledger drops it. */
  changes_ground?: boolean;
  /** Changes to own buildings in its footprint after its source_tick, read
   *  from the mod's change journal as it was queued: count is at least how
   *  many (a merged row counts each change it covers, an omitted row one);
   *  a fact, never a refusal. */
  footprint_changed?: FootprintChanged;
  /** The package's verify metrics and surface, kept from when it was queued
   *  (the ledger may drop it before they are measured). */
  verify?: VerifyMetric[]; surface?: string;
  /** When its plan ended (the record's tick for captures only) and how. */
  plan_ended_tick?: number; plan_status?: string;
  verification?: Verification;
}
/** The measured verify metrics: verified when every one is met, else unmet
 *  (reason: why nothing could be measured), or not_measured (reason: plan
 *  failed or plan cancelled) for a plan that failed or was cancelled. Each
 *  metric is the declared one plus measured (the mod's values: per_min, or
 *  the line's line_id, product, state, cause, rate_per_min, machines and
 *  working, or error) and met; a NO_LINE row of a partial plan also carries
 *  plan_status. */
export interface Verification {
  status: "verified" | "unmet" | "not_measured"; tick: number; at: string;
  metrics: Array<VerifyMetric & { measured: Record<string, unknown>; met: boolean; plan_status?: string }>; reason?: string;
}
export interface FootprintChanged { count: number; changes: unknown[] }
/** One blueprint_capture's result: its name, how many entities and wires it holds, and its
 *  origin (world position = origin + dx/dy), when the capture returned one. */
export interface CapturedBlueprint { name: string; entities: number; wires: number; origin?: { x: number; y: number } }
/** The outcome of the ledger's research for one revision: queued (the
 *  technologies the game added; skipped: already researched or queued) or
 *  failed (the mod's refusal, which names those queued before it). */
export interface ResearchRecord {
  revision: number; status: "queued" | "failed"; technologies: string[];
  queued?: string[]; skipped?: string[]; reason?: string; at: string; tick?: number;
}
export interface PackageQueueState {
  packages: Record<string, PackageRecord>;
  research?: ResearchRecord;
  /** The last emergency stop (the mod's last_cancel_all_tick) and when it
   *  happened: when a bridge first saw it, dated back by the game time
   *  since its tick. */
  cancel_all?: { tick: number; observed_at: string };
}
/** A queued package's plan as the game has it now: queued (in the FIFO),
 *  running, ended (its end not yet recorded) or how it ended. */
export type PackagePlanStatus = "queued" | "running" | "ended" | "completed" | "partial" | "failed" | "cancelled";
export interface Orders {
  revision: number; NOW: OperationsLedger["task_list"]["NOW"];
  /** status: the bridge's record (pending: none yet); plan_status: a queued
   *  package's plan, live when the orders were attached. */
  packages: Array<{ id: string; status: "pending" | PackageRecord["status"]; plan_id?: number; reason?: string;
    plan_status?: PackagePlanStatus }>;
}
/** The mod's FIFO as event_state reads it: the running pilot-work plan, the
 *  package plans still in the FIFO, and the last pilot or package plan to end. */
export interface LivePlans {
  active_plan_id?: number | null; package_plans?: unknown;
  last_plan_ended?: { plan_id: number; status: string } | null;
}

/** A queued record's plan now: its recorded end, else (with a live read)
 *  running, queued or ended; absent without a live read, which would only
 *  repeat the stale queued. Captures only have no plan and are done. */
function planStatusOf(record: PackageRecord, live?: LivePlans): PackagePlanStatus | undefined {
  if (record.status !== "queued") return undefined;
  if (record.plan_status !== undefined) return record.plan_status as PackagePlanStatus;
  if (record.plan_id === undefined) return "completed";
  if (!live) return undefined;
  if (live.active_plan_id === record.plan_id) return "running";
  if ((luaArray(live.package_plans ?? []) as unknown[]).includes(record.plan_id)) return "queued";
  const last = live.last_plan_ended;
  return last && last.plan_id === record.plan_id ? last.status as PackagePlanStatus : "ended";
}

/** Ledger packages not yet ended, live: not yet queued (no record yet,
 *  queuing, or waiting for the body's surface), or queued with its plan
 *  still in the mod's FIFO (package_plans). A failed or ended one is not
 *  open, nor is one written before the last emergency stop (held until the
 *  strategist rewrites the ledger). null without a run or ledger. */
export function packagesOpen(dir: string, live: LivePlans): number | null {
  const ledger = readLedger(dir);
  const state = readPackageQueue(dir);
  if (!ledger || !state) return null;
  const inFifo = new Set(luaArray(live.package_plans ?? []) as unknown[]);
  const held = state.cancel_all !== undefined && ledgerWrittenMs(dir) <= Date.parse(state.cancel_all.observed_at);
  return ledger.build_packages.filter((entry) => {
    const record = state.packages[entry.package_id];
    if (!record || record.status === "queuing" || record.status === "waiting_surface") return !held || record?.status === "queuing";
    if (record.status !== "queued" || record.plan_id === undefined || record.plan_ended_tick !== undefined) return false;
    return inFifo.has(record.plan_id);
  }).length;
}

export const ledgerFile = (dir: string) => path.join(dir, "operations.json");
export const packageQueueFile = (dir: string) => path.join(dir, "package-queue.json");
const lockFile = (dir: string) => path.join(dir, "package-queue.lock");

const ledgers = new Map<string, { key: string; ledger: OperationsLedger | null }>();
/** The run's valid ledger, or null; reparsed only when the file changes. */
export function readLedger(dir: string): OperationsLedger | null {
  const file = ledgerFile(dir);
  let stat: fs.Stats;
  try { stat = fs.statSync(file); } catch { return null; }
  const key = `${stat.ino}:${stat.mtimeMs}:${stat.size}`;
  const cached = ledgers.get(file);
  if (cached?.key === key) return cached.ledger;
  let ledger: OperationsLedger | null = null;
  try {
    const parsed = operationsLedgerSchema.safeParse(JSON.parse(fs.readFileSync(file, "utf8")));
    if (parsed.success) ledger = parsed.data;
  } catch { /* absent or mid-replacement: no orders */ }
  ledgers.set(file, { key, ledger });
  return ledger;
}

/** Recorded package outcomes; null when the file exists but cannot be read,
 *  so nothing is queued a second time from a lost record. */
export function readPackageQueue(dir: string): PackageQueueState | null {
  let text: string;
  try { text = fs.readFileSync(packageQueueFile(dir), "utf8"); }
  catch (error) { return (error as NodeJS.ErrnoException).code === "ENOENT" ? { packages: {} } : null; }
  try {
    const value = JSON.parse(text);
    return value && typeof value.packages === "object" && !Array.isArray(value.packages) ? value : null;
  } catch { return null; }
}

/** Verify outcomes, for next_event: package_verified or package_unmet with
 *  the plan's end and the measured metrics; at identifies the outcome. */
export function packageVerifications(dir: string): PackageVerificationEvent[] {
  return Object.entries(readPackageQueue(dir)?.packages ?? {}).flatMap(([id, record]) => {
    const result = record.verification;
    // A failed or cancelled plan was already reported; its verify was not measured.
    if (!result || typeof result !== "object" || result.status === "not_measured") return [];
    return [{ event: result.status === "verified" ? "package_verified" as const : "package_unmet" as const,
      package_id: id, ...(record.plan_status === undefined ? {} : { plan_status: record.plan_status }),
      metrics: result.metrics ?? [], ...(result.reason === undefined ? {} : { reason: result.reason }),
      tick: result.tick, at: result.at }];
  });
}

/** Packages that were not queued, for next_event; at identifies the record
 *  (a package re-queued after a save rollback can fail again). */
export function packageFailures(dir: string): Array<{ package_id: string; reason?: string; tick?: number; at: string }> {
  return Object.entries(readPackageQueue(dir)?.packages ?? {}).flatMap(([id, record]) => record.status === "failed"
    ? [{ package_id: id, ...(record.reason === undefined ? {} : { reason: record.reason }),
      ...(record.tick === undefined ? {} : { tick: record.tick }), at: record.at }] : []);
}

export function readOrders(dir: string, live?: LivePlans): Orders | null {
  const ledger = readLedger(dir);
  if (!ledger) return null;
  const records = readPackageQueue(dir)?.packages ?? {};
  return { revision: ledger.revision, NOW: ledger.task_list.NOW, packages: ledger.build_packages.map((entry) => {
    const record = records[entry.package_id];
    const plan = record ? planStatusOf(record, live) : undefined;
    return { id: entry.package_id, status: record?.status ?? "pending",
      ...(record?.plan_id === undefined ? {} : { plan_id: record.plan_id }),
      ...(record?.reason === undefined ? {} : { reason: record.reason }),
      ...(plan === undefined ? {} : { plan_status: plan }) };
  }) };
}

/** Attaches the orders to a tool result whenever the ledger revision differs
 *  from the one this session last received; live (the mod's FIFO, read by
 *  the caller only then) gives each queued package's plan_status as it is
 *  now. The block is a snapshot of that moment. */
export function createOrdersTracker(runDir: RunDir) {
  let delivered: string | undefined;
  const current = (live?: LivePlans) => {
    const dir = runDir();
    const orders = dir ? readOrders(dir, live) : null;
    return orders ? { key: `${dir}#${orders.revision}`, orders } : null;
  };
  return {
    changed(): boolean {
      const now = current();
      return now !== null && now.key !== delivered;
    },
    attach<T>(result: T, live?: LivePlans): T {
      const value = result as { structuredContent?: unknown; content?: Array<{ type: string; text: string }> };
      const structured = value?.structuredContent;
      if (!structured || typeof structured !== "object" || Array.isArray(structured)) return result;
      const now = current(live);
      if (!now || now.key === delivered) return result;
      delivered = now.key;
      const note = `orders revision ${now.orders.revision}: NOW ${now.orders.NOW.objective}`;
      return { ...value, structuredContent: { ...structured, orders: now.orders },
        content: (value.content ?? []).map((entry, index) => index === 0 && entry.type === "text"
          ? { ...entry, text: `${note}; ${entry.text}`.slice(0, 500) } : entry) } as T;
    },
  };
}

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
}
/** Gives up this process's package lock, if it holds it. */
export function releaseLock(dir: string, pid = process.pid): void {
  const file = lockFile(dir);
  try { if (Number(fs.readFileSync(file, "utf8").trim()) === pid) fs.rmSync(file); } catch { /* none */ }
}
/** One process per run queues packages: whoever holds the lock while alive.
 *  A dead owner's lock is taken over atomically: it is moved aside, and if
 *  what was moved is not the stale lock judged dead (a live process replaced
 *  it meanwhile) it is put back, so two bridges never both hold it. */
export function holdLock(dir: string, pid = process.pid, isAlive: (pid: number) => boolean = alive): boolean {
  const file = lockFile(dir);
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      fs.writeFileSync(file, `${pid}\n`, { flag: "wx", mode: 0o600 });
      if (pid === process.pid) {
        process.once("exit", () => {
          try { if (Number(fs.readFileSync(file, "utf8")) === pid) fs.rmSync(file); } catch { /* gone */ }
        });
      }
      return true;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") return false;
    }
    let text: string;
    try { text = fs.readFileSync(file, "utf8"); } catch { continue; }
    const owner = Number(text.trim());
    if (owner === pid) return true;
    if (Number.isInteger(owner) && owner > 0 && isAlive(owner)) return false;
    const aside = `${file}.${pid}`;
    try { fs.renameSync(file, aside); } catch { continue; }
    let moved: string | undefined;
    try { moved = fs.readFileSync(aside, "utf8"); } catch { /* vanished */ }
    if (moved !== text) {
      try { fs.linkSync(aside, file); } catch { /* a newer lock already stands */ }
      fs.rmSync(aside, { force: true });
      return false;
    }
    fs.rmSync(aside, { force: true });
  }
  return false;
}

const message = (error: unknown) => error instanceof Error ? error.message : String(error);
// Trees and rocks are cleared by the placement itself; reach and body overlap
// are handled when the step runs. Only a standing building, a liquid (water,
// lava, an ocean) or the planet's surface conditions reject.
function hardRejection(entry: any): string | null {
  if (!entry || entry.can_place !== false) return null;
  if (luaArray(entry.overlaps_batch ?? []).length > 0) return "overlaps another placement in the package";
  const reason = typeof entry.reason === "string" ? entry.reason : "";
  if (entry.code === "SURFACE_CONDITION") return reason || "SURFACE_CONDITION";
  const blocker = /^blocked by (\S+)/.exec(reason)?.[1];
  if ((blocker && !/tree|rock/.test(blocker)) || /touches (?:water|lava|[a-z-]+ ocean)\b/.test(reason)) return reason;
  return null;
}

/** Whether a step changes the ground the steps after it stand on: landfill
 *  makes it, and mining, deconstruction, a move or picking up ground items
 *  clears it, so the map does not have it yet. */
const changesGround = (step: { action: string }) =>
  ["place_tiles", "mine", "deconstruct_area", "move_entity", "pickup_items"].includes(step.action);
const changesGroundIn = (entry: BuildPackage | undefined) => entry?.steps.some(changesGround) === true;

/** The mod's own placement check for one package; a reason when it fails,
 *  also when its first step is a layout or blueprint that needs an
 *  item the body can neither carry nor obtain now (ITEM_UNOBTAINABLE).
 *  Only steps before the first one that changes the ground (place_tiles,
 *  mine, deconstruct_area, move_entity, pickup_items) are checked against the map: a
 *  landfill makes the ground the later ones need and a removal clears it, and
 *  the mod checks them when they run. Items are like ground: a later step, or
 *  any step while a predecessor's plan is still pending (afterPending), may
 *  use what runs before it builds or carries, so the mod checks those when
 *  they run. */
export async function checkPackage(bridge: Bridge, entry: BuildPackage, afterPending = false): Promise<string | null> {
  try {
    const cut = entry.steps.findIndex(changesGround);
    const checked = cut < 0 ? entry.steps : entry.steps.slice(0, cut);
    // The only step whose items are checked now.
    const first = afterPending ? undefined : entry.steps.find((step) => step.action !== "blueprint_capture");
    const places = checked.flatMap((step) => step.action === "place_entity" ? [step] : []);
    for (let start = 0; start < places.length; start += 24) {
      const batch = places.slice(start, start + 24);
      const checked = await bridge.call<{ results?: unknown[] }>("can_place", toolPayloads.canPlace(batch, entry.surface));
      for (const [index, result] of luaArray(checked?.results ?? []).entries()) {
        const reason = hardRejection(result);
        const step = batch[index]!;
        if (reason) return `place_entity ${step.name} at (${step.x}, ${step.y}): ${reason}`;
      }
    }
    // Dry runs search over ticks until they have the site or a definite answer.
    for (const step of checked) {
      if (step.action === "blueprint_place") {
        const { action, ...params } = step;
        const checked = await bridge.call<{ ok?: boolean; free_position?: { x: number; y: number };
          collisions?: unknown; unobtainable?: unknown }>(action, { ...params, check_only: true });
        const collisions = luaArray(checked?.collisions ?? []) as Array<{ reason?: string }>;
        const short = luaArray(checked?.unobtainable ?? []) as Array<{ code?: string; reason?: string }>;
        if (short.length > 0 && step === first) {
          return `blueprint_place ${step.name}: ${[short[0]?.code, short[0]?.reason].filter(Boolean).join(" ")}`;
        }
        // Short items alone make hand mode not ok too; the position is blocked when it collides.
        if (checked?.ok === false && (short.length === 0 || collisions.length > 0)) {
          const blocker = typeof collisions[0]?.reason === "string" ? `: ${collisions[0].reason}` : "";
          const free = checked.free_position ? `; the nearest free position is (${checked.free_position.x}, ${checked.free_position.y})` : "";
          return `blueprint_place ${step.name} at (${step.position.x}, ${step.position.y}): the position is blocked${blocker}${free}`;
        }
        continue;
      }
      if (step.action !== "build_layout") continue;
      const { action, ...params } = step;
      const checked = await bridge.call<{ failed?: unknown }>(action, { ...params, check_only: true });
      const failed = (luaArray(checked?.failed ?? []) as Array<{ code?: string; reason?: string }>)
        .filter((row) => row?.code !== "ITEM_UNOBTAINABLE" || step === first);
      if (failed.length > 0) return `${action}: ${[failed[0]?.code, failed[0]?.reason].filter(Boolean).join(" ")}`;
    }
    return null;
  } catch (error) {
    if (error instanceof ModError) return message(error);
    throw error;
  }
}

type Point = { x: number; y: number };
const isPoint = (value: unknown): value is Point => typeof (value as Point | undefined)?.x === "number"
  && typeof (value as Point | undefined)?.y === "number";
/** Tiles around a package's named positions its footprint also covers: a
 *  building placed at a position reaches past it. */
export const FOOTPRINT_PAD = 3;
/** A package's footprint: the area around its anchor and every position its
 *  steps name (a layout's offsets from its anchor, an area's corners, a
 *  centre with its radius), padded by FOOTPRINT_PAD tiles. Steps on a space
 *  platform (positions relative to its hub) and site-searched layouts beyond
 *  their near point are not covered. */
export function packageFootprint(entry: BuildPackage): { left_top: Point; right_bottom: Point } {
  const points: Point[] = [entry.anchor];
  const add = (value: unknown, origin: Point = { x: 0, y: 0 }) => {
    if (isPoint(value)) points.push({ x: origin.x + value.x, y: origin.y + value.y });
  };
  const offset = (value: unknown, origin: Point) => {
    const at = value as { dx?: unknown; dy?: unknown } | undefined;
    if (typeof at?.dx === "number" && typeof at?.dy === "number") points.push({ x: origin.x + at.dx, y: origin.y + at.dy });
  };
  for (const step of entry.steps as Array<Record<string, any>>) {
    if (step.platform !== undefined) continue;
    add(step);
    for (const key of ["position", "from", "input_target", "output_target", "target"]) add(step[key]);
    for (const list of [step.positions, step.to, step.targets]) if (Array.isArray(list)) list.forEach((point) => add(point));
    if (!Array.isArray(step.to)) add(step.to);
    if (step.targets && !Array.isArray(step.targets)) {
      const radius = typeof step.targets.radius === "number" ? step.targets.radius : 0;
      add(step.targets.near, { x: -radius, y: -radius }); add(step.targets.near, { x: radius, y: radius });
    }
    if (step.area) { add(step.area.left_top); add(step.area.right_bottom); }
    if (isPoint(step.center) && typeof step.radius === "number") {
      add(step.center, { x: -step.radius, y: -step.radius }); add(step.center, { x: step.radius, y: step.radius });
    }
    if (step.action === "build_layout") {
      add(step.site?.near);
      if (isPoint(step.anchor)) {
        const origin = step.anchor as Point;
        add(origin);
        for (const row of [...(step.entities ?? []), ...(step.tiles ?? [])]) offset(row, origin);
        for (const row of [...(step.tile_rects ?? []), ...(step.connections ?? [])]) { offset(row.from, origin); offset(row.to, origin); }
      }
    }
  }
  const xs = points.map((point) => point.x), ys = points.map((point) => point.y);
  return { left_top: { x: Math.min(...xs) - FOOTPRINT_PAD, y: Math.min(...ys) - FOOTPRINT_PAD },
    right_bottom: { x: Math.max(...xs) + FOOTPRINT_PAD, y: Math.max(...ys) + FOOTPRINT_PAD } };
}
/** Changes to own buildings in a package's footprint after its source_tick
 *  (the mod's change journal: up to three rows, and at least how many
 *  changes matched), or undefined when none did or the journal could not be read:
 *  the check only reports, it never holds a package. */
async function footprintChanges(b: Bridge, entry: BuildPackage): Promise<FootprintChanged | undefined> {
  try {
    const answer = await b.call<{ changes?: { rows?: unknown; omitted?: number } }>("activity_log", { limit: 1,
      changes: { since_tick: entry.source_tick, area: packageFootprint(entry), surface: entry.surface, limit: 3 } });
    const rows = luaArray(answer?.changes?.rows ?? []) as Array<{ count?: number }>;
    const count = rows.reduce((sum, row) => sum + (typeof row?.count === "number" ? row.count : 1), answer?.changes?.omitted ?? 0);
    return rows.length > 0 ? { count, changes: rows } : undefined;
  } catch { return undefined; }
}

/** The source of a plan the mod still knows, or null for an unknown (pruned)
 *  plan. The bridge's own plan_status polls are compact: plan_id, source,
 *  status and finished_tick only. */
async function planSource(b: Bridge, planId: number): Promise<string | undefined | null> {
  try { return (await b.call<{ source?: string }>("plan_status", { plan_id: planId, compact: true })).source; }
  catch (error) { if (error instanceof ModError) return null; throw error; }
}

const ledgerWrittenMs = (dir: string) => { try { return fs.statSync(ledgerFile(dir)).mtimeMs; } catch { return 0; } };

/** Game ticks from a package's plan end to its verify measurement. */
export const VERIFY_SETTLE_TICKS = 7200;
/** A measurement the mod keeps refusing is given up this long after it was due. */
const VERIFY_GIVE_UP_TICKS = 18000;
/** How often a package's plan is asked whether it ended (ms). */
const VERIFY_POLL_MS = 10_000;
const ENDED = new Set(["completed", "partial", "failed", "cancelled"]);

/** Records when every queued package's plan ended and how (plan_ended_tick,
 *  plan_status), and measures a package's verify metrics once,
 *  VERIFY_SETTLE_TICKS after its plan ended, through factory_status measure
 *  on its surface, recording the outcome on its record; a failed or
 *  cancelled plan's verify is not_measured. Measurement only: nothing is
 *  fixed or queued again. A mod refusal is retried until
 *  VERIFY_GIVE_UP_TICKS past due, then recorded as unmet with its reason. */
async function verifyPackages(b: Bridge, state: PackageQueueState, tick: number, write: () => void,
  now: () => Date, polled: Map<string, number>): Promise<void> {
  for (const [id, record] of Object.entries(state.packages)) {
    if (record.status !== "queued") continue;
    if (record.plan_ended_tick === undefined) {
      if (record.plan_id === undefined) {
        record.plan_ended_tick = record.tick ?? tick;
      } else {
        const key = `${id}#${record.plan_id}`;
        if (now().getTime() - (polled.get(key) ?? -Infinity) < VERIFY_POLL_MS) continue;
        polled.set(key, now().getTime());
        try {
          const plan = await b.call<{ status?: string; source?: string; finished_tick?: number }>("plan_status",
            { plan_id: record.plan_id, compact: true });
          // Another plan's id after a save rollback: the record is dropped and queued again.
          if (plan?.source !== `package:${id}` || !ENDED.has(String(plan.status))) continue;
          record.plan_ended_tick = typeof plan.finished_tick === "number" ? plan.finished_tick : tick;
          record.plan_status = plan.status;
        } catch (error) {
          // A pruned plan ended long ago.
          if (!(error instanceof ModError)) throw error;
          record.plan_ended_tick = tick;
        }
      }
      write();
    }
    if (record.verify === undefined || record.verification !== undefined) continue;
    const done = (result: Omit<Verification, "at" | "tick">) => {
      record.verification = { ...result, tick, at: now().toISOString() };
      write();
    };
    const metrics = verifySchema.safeParse(record.verify);
    if (!metrics.success) { done({ status: "unmet", metrics: [], reason: "its verify metrics in package-queue.json are malformed" }); continue; }
    if (record.plan_status === "failed" || record.plan_status === "cancelled") {
      done({ status: "not_measured", metrics: [], reason: `plan ${record.plan_status}` });
      continue;
    }
    const due = record.plan_ended_tick + VERIFY_SETTLE_TICKS;
    if (tick < due) continue;
    try {
      const answer = await b.call<{ measured?: unknown }>("factory_status",
        { sections: [], surface: record.surface ?? "nauvis", measure: metrics.data });
      const measured = luaArray(answer?.measured ?? []) as Array<Record<string, unknown>>;
      const rows = metrics.data.map((metric, index) => {
        const { met, ...values } = measured[index] ?? { error: "NOT_MEASURED" };
        // A partial plan may not have built the line: its NO_LINE row says how the plan ended.
        const partial = values.error === "NO_LINE" && record.plan_status === "partial" ? { plan_status: "partial" } : {};
        return { ...metric, measured: values, met: met === true, ...partial };
      });
      done({ status: rows.every((row) => row.met) ? "verified" : "unmet", metrics: rows });
    } catch (error) {
      if (!(error instanceof ModError)) throw error;
      if (tick >= due + VERIFY_GIVE_UP_TICKS) done({ status: "unmet", metrics: [], reason: `not measured: ${message(error)}` });
    }
  }
}

/** Queues each new ledger package once, in ledger order, as a plan with
 *  source package:<id>; leading blueprint_capture steps are made first.
 *  Outcomes persist in <run_dir>/package-queue.json; a connection problem is
 *  retried on the next tick. It never waits for a pilot plan: nothing is
 *  queued only while a human holds the body, or while the ledger is older than
 *  the last emergency stop (packages written before a stop stay held until
 *  the strategist rewrites the ledger). The ledger's research is queued once
 *  per revision that lists any (origin ledger/r<revision>, a row in
 *  activity_log), held only by a stop, as packages are. A newer writer
 *  generation (a replacement pilot claimed one) retires it for good: it
 *  gives up its lock, so the new pilot's bridge queues from then on. */
export function createPackageQueue(runDir: RunDir, bridge: () => Promise<Bridge>, now = () => new Date()) {
  // Directories whose queued records this process has checked against the loaded save.
  const verified = new Set<string>();
  // When each package's plan was last asked whether it ended.
  const polled = new Map<string, number>();
  const process_ = async () => {
    const dir = runDir();
    const ledger = dir ? readLedger(dir) : null;
    if (!dir || !ledger) return;
    const known = readPackageQueue(dir);
    if (!known) return;
    const settled = (state: PackageQueueState, id: string) => {
      const record = state.packages[id];
      return record !== undefined && (record.status === "queued" || record.status === "failed");
    };
    // Every pass reads the game, even with no package yet: an emergency stop
    // is recorded when it happens, not when the first package after it appears.
    const b = await bridge();
    const ping = await b.call<{ companion_exists?: boolean; tick?: number; writer_generation?: number;
      body?: { state?: string; surface_ref?: string; bound_for?: string } }>("ping");
    if (b.writerGeneration !== undefined && typeof ping.writer_generation === "number" && ping.writer_generation > b.writerGeneration) {
      throw new WriterRetiredError(`writer generation ${b.writerGeneration} was replaced by generation ${ping.writer_generation}`);
    }
    if (!ping.companion_exists || !holdLock(dir)) return;
    const state = readPackageQueue(dir);
    if (!state) return;
    const write = () => atomicWriteFile(packageQueueFile(dir), `${JSON.stringify(state, null, 2)}\n`, 0o600);
    // A record newer than the live tick is from a save line that was rolled
    // back (a restart from an earlier save): that plan never existed here and
    // its plan_id may be reused, so the package is queued again.
    if (typeof ping.tick === "number") {
      const stale = Object.keys(state.packages).filter((id) => (state.packages[id]!.tick ?? -1) > ping.tick!);
      const staleResearch = (state.research?.tick ?? -1) > ping.tick;
      if (staleResearch) delete state.research;
      // A kept package whose plan end or verify measurement is newer runs
      // again here: both are taken again from this save line.
      const staleEnd = Object.keys(state.packages).filter((id) => {
        const record = state.packages[id]!;
        return !stale.includes(id) && ((record.plan_ended_tick ?? -1) > ping.tick! || (record.verification?.tick ?? -1) > ping.tick!);
      });
      for (const id of staleEnd) {
        const record = state.packages[id]!;
        delete record.plan_ended_tick; delete record.plan_status; delete record.verification;
      }
      if (stale.length > 0 || staleResearch || staleEnd.length > 0) {
        for (const id of stale) delete state.packages[id];
        write();
      }
    }
    const events = await b.call<{ tick?: number; human_hold?: boolean; last_cancel_all_tick?: number }>("event_state");
    const stopTick = events.last_cancel_all_tick;
    if (typeof stopTick === "number" && state.cancel_all?.tick !== stopTick) {
      // First seen now, but it happened (tick - stopTick) game ticks ago.
      const agoMs = typeof events.tick === "number" ? Math.max(0, events.tick - stopTick) * 1000 / 60 : 0;
      state.cancel_all = { tick: stopTick, observed_at: new Date(now().getTime() - agoMs).toISOString() };
      write();
    }
    const heldByStop = state.cancel_all !== undefined && ledgerWrittenMs(dir) <= Date.parse(state.cancel_all.observed_at);
    // Research moves no body, so neither a human hold nor the body's surface
    // holds it; a ledger older than the last stop does, as for packages.
    if (ledger.research.length > 0 && state.research?.revision !== ledger.revision && !heldByStop) {
      const at = () => ({ at: now().toISOString(), ...(typeof ping.tick === "number" ? { tick: ping.tick } : {}) });
      const base = { revision: ledger.revision, technologies: ledger.research };
      try {
        const answer = await b.call<{ technologies?: unknown; skipped?: unknown }>("start_research",
          { technologies: ledger.research, origin: `ledger/r${ledger.revision}` });
        const skipped = luaArray(answer?.skipped ?? []) as string[];
        state.research = { ...base, status: "queued", queued: luaArray(answer?.technologies ?? []) as string[],
          ...(skipped.length > 0 ? { skipped } : {}), ...at() };
      } catch (error) {
        // A lost answer is retried next pass: what it queued is then skipped.
        if (!(error instanceof ModError)) throw error;
        state.research = { ...base, status: "failed", reason: message(error), ...at() };
      }
      write();
    }
    // A package's plan end is recorded and its verify measured whatever holds the queue: it moves nothing.
    if (typeof ping.tick === "number") await verifyPackages(b, state, ping.tick, write, now, polled);
    // Records exist: each pass checks them against the loaded save.
    if (Object.keys(state.packages).length === 0 && ledger.build_packages.length === 0) return;
    if (events.human_hold === true) return;
    // A save restored past a record's tick keeps the record, but its plan_id
    // may now name another plan: once per process, a queued record whose plan
    // has a different source is dropped, so the package is queued again. An
    // unknown (pruned) plan ended long ago and keeps its record.
    if (!verified.has(dir)) {
      let dropped = false;
      for (const [id, entry] of Object.entries(state.packages)) {
        if (entry.status !== "queued" || entry.plan_id === undefined) continue;
        const source = await planSource(b, entry.plan_id);
        if (source !== null && source !== `package:${id}`) { delete state.packages[id]; dropped = true; }
      }
      if (dropped) write();
      verified.add(dir);
    }
    if (ledger.build_packages.every((entry) => settled(state, entry.package_id))) return;
    if (heldByStop) return;
    const record = (id: string, entry: Omit<PackageRecord, "revision" | "at" | "tick">) => {
      state.packages[id] = { ...entry, revision: ledger.revision, at: now().toISOString(),
        ...(typeof ping.tick === "number" ? { tick: ping.tick } : {}) };
      write();
    };
    for (const entry of ledger.build_packages) {
      const id = entry.package_id;
      if (settled(state, id)) continue;
      // queuing: the call was sent and its answer lost; the mod returns the
      // same plan for a package source, so it is sent again unchecked.
      const retry = state.packages[id]?.status === "queuing";
      // Any other package for another surface waits until the body is
      // settled there: standing on it (or aboard), with no travel pending
      // in the FIFO to somewhere else (bound_for), and not in a cargo pod.
      const body = ping.body;
      const atRest = body?.state === "on_surface" || body?.state === "aboard_platform";
      const here = atRest ? body?.bound_for ?? body?.surface_ref : undefined;
      if (!retry && here !== entry.surface) {
        const where = !atRest ? (body?.state === "in_transit" ? "in a cargo pod" : "on no surface")
          : body?.bound_for !== undefined ? `bound for ${body.bound_for}` : `on ${body?.surface_ref}`;
        const reason = `the body is ${where}; the package is for ${entry.surface}`;
        if (state.packages[id]?.status !== "waiting_surface" || state.packages[id]?.reason !== reason) {
          record(id, { status: "waiting_surface", reason });
        }
        continue;
      }
      const captures = entry.steps.flatMap((step) => step.action === "blueprint_capture" ? [step] : []);
      const steps = entry.steps.filter((step) => step.action !== "blueprint_capture");
      let afterPlanId: number | undefined;
      if (entry.after_package_id !== null) {
        const before = state.packages[entry.after_package_id];
        if (!before) {
          // A predecessor later in this ledger is queued first; this one follows next tick.
          if (ledger.build_packages.some((other) => other.package_id === entry.after_package_id)) continue;
          record(id, { status: "failed", reason: `after_package_id ${entry.after_package_id} was never queued` });
          continue;
        }
        if (before.status === "failed") {
          record(id, { status: "failed", reason: `after_package_id ${entry.after_package_id} failed` });
          continue;
        }
        // Its queue answer is still unknown, or it waits for its surface:
        // wait until it is resolved.
        if (before.status === "queuing" || before.status === "waiting_surface") continue;
        // A predecessor of captures only has no plan and is done.
        if (before.plan_id !== undefined) {
          let status: string | undefined, source: string | undefined;
          try {
            ({ status, source } = await b.call<{ status: string; source?: string }>("plan_status", { plan_id: before.plan_id, compact: true }));
          }
          catch (error) { if (!(error instanceof ModError)) throw error; /* pruned: it ended long ago */ }
          if (status !== undefined && source !== `package:${entry.after_package_id}`) {
            // The plan_id now names another plan (a save rollback): the
            // predecessor is queued again first and this one follows it.
            delete state.packages[entry.after_package_id];
            write();
            continue;
          }
          if (status === "queued" || status === "running" || status === "waiting") {
            // A capture records what the predecessor built, and a check needs
            // the ground its landfill makes or its removals clear, so either
            // waits for its end.
            const predecessor = ledger.build_packages.find((other) => other.package_id === entry.after_package_id);
            if (captures.length > 0 || changesGroundIn(predecessor) || before.changes_ground === true) continue;
            afterPlanId = before.plan_id;
          } else if (status !== undefined && status !== "completed") {
            record(id, { status: "failed", reason: `after_package_id ${entry.after_package_id} ended ${status}` });
            continue;
          }
        }
      }
      // What each capture returned (a retry keeps the first ones).
      const made: CapturedBlueprint[] = retry ? state.packages[id]?.captured ?? [] : [];
      const kept = () => made.length > 0 ? { captured: [...made] } : {};
      if (!retry) {
        // Captures come first: the package's own steps may place what they capture.
        try {
          for (const { action, ...params } of captures) {
            const summary = await b.call<{ entities?: number; wires?: number; origin?: unknown }>(action, params);
            const origin = isPoint(summary?.origin) ? { x: summary.origin.x, y: summary.origin.y } : undefined;
            made.push({ name: params.name, entities: summary?.entities ?? 0, wires: summary?.wires ?? 0, ...(origin ? { origin } : {}) });
          }
        } catch (error) {
          if (!(error instanceof ModError)) throw error;
          record(id, { status: "failed", reason: `capture failed: ${message(error)}`, ...kept() });
          continue;
        }
        const problem = await checkPackage(b, entry, afterPlanId !== undefined);
        if (problem) { record(id, { status: "failed", reason: `check failed: ${problem}`, ...kept() }); continue; }
      }
      // What changed in its footprint since the strategist read it: a fact
      // kept with the record (a retry keeps the first reading).
      const changed = retry ? state.packages[id]?.footprint_changed : await footprintChanges(b, entry);
      const captured = { ...kept(), ...(changed ? { footprint_changed: changed } : {}) };
      // A package's verify metrics go with its record.
      const verify = entry.verify ? { verify: entry.verify, surface: entry.surface } : {};
      if (steps.length === 0) { record(id, { status: "queued", ...captured, ...verify }); continue; }
      const plan = queuePlanSchema.safeParse({ steps, surface: entry.surface, ...(afterPlanId ? { after_plan_id: afterPlanId } : {}) });
      if (!plan.success) { record(id, { status: "failed", reason: plan.error.issues[0]?.message ?? "invalid steps" }); continue; }
      // An emergency stop or a human hold during this pass: nothing more is queued.
      const latest = await b.call<{ human_hold?: boolean; last_cancel_all_tick?: number }>("event_state");
      if (latest.human_hold === true || latest.last_cancel_all_tick !== stopTick) return;
      // Recorded before the call, so a crash in between retries it, never queues it twice.
      if (!retry) record(id, { status: "queuing", ...captured });
      try {
        const queued = await b.call<{ plan_id: number }>("queue_plan", { ...plan.data, source: `package:${id}` });
        record(id, { status: "queued", plan_id: queued.plan_id, ...(changesGroundIn(entry) ? { changes_ground: true } : {}), ...captured, ...verify });
      } catch (error) {
        // Only the mod's own refusal is a failure; a lost answer stays queuing.
        if (!(error instanceof ModError)) throw error;
        record(id, { status: "failed", reason: message(error) });
      }
    }
  };
  let busy = false;
  let retired = false;
  return {
    async tick(): Promise<void> {
      if (busy || retired) return;
      busy = true;
      try { await process_(); }
      catch (error) {
        // Otherwise offline or interrupted: retried next tick.
        if (error instanceof WriterRetiredError) {
          retired = true;
          const dir = runDir();
          if (dir) releaseLock(dir);
        }
      } finally { busy = false; }
    },
  };
}
