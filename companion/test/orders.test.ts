import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ModError, type Bridge } from "../src/bridge.js";
import { createOrdersTracker, createPackageQueue, holdLock, packageFailures, readPackageQueue } from "../src/coordination/orders.js";
import { result } from "../src/mcp/server.js";
import { currentRunDir, currentRunPointer, runPaths } from "../src/server/server.js";

const dirs: string[] = [];
afterEach(() => {
  vi.unstubAllEnvs();
  dirs.splice(0).forEach((dir) => fs.rmSync(dir, { recursive: true, force: true }));
});
const runDir = () => { const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-orders-")); dirs.push(dir); return dir; };

const furnaces = (id: string, after: string | null = null) => ({
  package_id: id, serves: "NOW", intent: "smelt iron", after_package_id: after, source_tick: 10,
  anchor: { x: 0, y: 0 }, required_items: {}, success_check: "plates appear",
  steps: [{ action: "place_entity", x: 1.5, y: 2.5, name: "stone-furnace" },
    { action: "build_block", block: "smelting", count: 4, near: { x: 0, y: 0 } }],
});
function writeLedger(dir: string, revision: number, packages: unknown[], objective = "automate iron") {
  const priority = (text: string) => ({ objective: text, strategic_reason: "r", completion_condition: "c", essential_prerequisite: null });
  fs.writeFileSync(path.join(dir, "operations.json"), JSON.stringify({
    schema_version: 2, run: { id: "run-1", release_sha: "a".repeat(40), baseline_save_sha256: "b".repeat(64),
      save_identity: "s", created_at: "2026-10-04T00:00:00Z",
      roles: { pilot: { model: "gpt-6-luna", reasoning: "low", fast: true }, strategist: { model: "gpt-6-astra", reasoning: "medium", fast: false } } },
    revision, source_tick: 10, phase: "start", bottleneck: "iron", latest_measured_capacity: [],
    task_list: { NOW: priority(objective), NEXT: priority("copper"), LATER: priority("science") },
    assumptions: [], build_packages: packages,
  }));
}

/** A fake game: ping, can_place, build_block checks, queue_plan and plan_status. */
function fakeBridge(overrides: Record<string, (params: any) => unknown> = {}) {
  let next = 40;
  const sources = new Map<number, string>();
  const answer = async (method: string, params: any): Promise<any> => {
    if (overrides[method]) return overrides[method]!(params);
    if (method === "ping") return { companion_exists: true, tick: 900, fifo: { idle_seconds: 0 } };
    if (method === "can_place") return { results: params.placements.map(() => ({ can_place: true })) };
    if (method === "build_block" || method === "build_layout") return { placed: {}, failed: {} };
    if (method === "queue_plan") return { plan_id: ++next };
    if (method === "plan_status") return { plan_id: params.plan_id, status: "running", source: sources.get(params.plan_id) };
    throw new Error(`unexpected ${method}`);
  };
  const call = vi.fn(async (method: string, params: any) => {
    const value = await answer(method, params);
    if (method === "queue_plan" && typeof value?.plan_id === "number") sources.set(value.plan_id, params.source);
    return value;
  });
  return { call, bridge: async () => ({ call } as unknown as Bridge), sources };
}
const queuedPlans = (call: ReturnType<typeof fakeBridge>["call"]) =>
  call.mock.calls.filter(([method]) => method === "queue_plan").map(([, params]) => params);

describe("orders attached to tool results", () => {
  it("attaches NOW and package states once per ledger revision", () => {
    const dir = runDir();
    const tracker = createOrdersTracker(() => dir);
    expect(tracker.attach(result({ status: "completed", summary: "ok" })).structuredContent).not.toHaveProperty("orders");
    writeLedger(dir, 1, [furnaces("iron-a")]);
    expect(tracker.changed()).toBe(true);
    const first = tracker.attach(result({ status: "completed", summary: "ok" }));
    expect(first.structuredContent.orders).toEqual({ revision: 1, NOW: expect.objectContaining({ objective: "automate iron" }),
      packages: [{ id: "iron-a", status: "pending" }] });
    expect(first.content[0]!.text).toBe("orders revision 1: NOW automate iron; ok");
    expect(tracker.changed()).toBe(false);
    expect(tracker.attach(result({ status: "completed", summary: "ok" })).structuredContent).not.toHaveProperty("orders");
    writeLedger(dir, 2, [], "automate copper");
    expect(tracker.attach(result({ status: "completed", summary: "ok" })).structuredContent.orders)
      .toMatchObject({ revision: 2, NOW: { objective: "automate copper" }, packages: [] });
  });

  it("attaches nothing without a run, or for a malformed ledger", () => {
    expect(createOrdersTracker(() => null).attach(result({ summary: "ok" })).structuredContent).toEqual({ summary: "ok" });
    const dir = runDir();
    fs.writeFileSync(path.join(dir, "operations.json"), "{broken");
    const tracker = createOrdersTracker(() => dir);
    expect(tracker.changed()).toBe(false);
    expect(tracker.attach(result({ summary: "ok" })).structuredContent).toEqual({ summary: "ok" });
  });
});

describe("package auto-queue", () => {
  it("queues each new package once, in ledger order, after its check, with source package:<id>", async () => {
    const dir = runDir();
    writeLedger(dir, 3, [furnaces("iron-a"), furnaces("iron-b")]);
    const { call, bridge } = fakeBridge();
    await createPackageQueue(() => dir, bridge).tick();
    const plans = queuedPlans(call);
    expect(plans.map((plan: any) => plan.source)).toEqual(["package:iron-a", "package:iron-b"]);
    expect(plans[0]).toMatchObject({ steps: furnaces("iron-a").steps, final_observation_radius: 15, observation_detail: "none" });
    expect(call).toHaveBeenCalledWith("can_place", { placements: [{ item: "stone-furnace", position: { x: 1.5, y: 2.5 }, direction: undefined }] });
    expect(call).toHaveBeenCalledWith("build_block", { block: "smelting", count: 4, near: { x: 0, y: 0 }, check_only: true });
    expect(readPackageQueue(dir)?.packages).toMatchObject({ "iron-a": { status: "queued", plan_id: 41, revision: 3, tick: 900 },
      "iron-b": { status: "queued", plan_id: 42 } });
    expect(fs.statSync(path.join(dir, "package-queue.json")).mode & 0o777).toBe(0o600);
    // A later tick and a second process never queue them again.
    await createPackageQueue(() => dir, bridge).tick();
    expect(queuedPlans(call)).toHaveLength(2);
    expect(createOrdersTracker(() => dir).attach(result({ summary: "ok" })).structuredContent.orders.packages)
      .toEqual([{ id: "iron-a", status: "queued", plan_id: 41 }, { id: "iron-b", status: "queued", plan_id: 42 }]);
  });

  it("records a failed check, never queues it, and surfaces the failure", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("blocked"), furnaces("tree-only")]);
    let checks = 0;
    const { call, bridge } = fakeBridge({
      can_place: (params) => ({ results: params.placements.map(() => checks++ === 0
        ? { can_place: false, reason: "blocked by iron-chest at (1.5, 2.5)" }
        : { can_place: false, reason: "blocked by tree-01 at (1.5, 2.5)" }) }),
    });
    await createPackageQueue(() => dir, bridge).tick();
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:tree-only"]);
    expect(packageFailures(dir)).toEqual([{ package_id: "blocked", tick: 900, at: expect.any(String),
      reason: "check failed: place_entity stone-furnace at (1.5, 2.5): blocked by iron-chest at (1.5, 2.5)" }]);
  });

  it("fails a layout or block whose dry run reports failed placements, or a mod error", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("no-water")]);
    const { call, bridge } = fakeBridge({ build_block: () => ({ placed: {}, failed: [{ index: 2, code: "NO_SITE", reason: "no water nearby" }] }) });
    await createPackageQueue(() => dir, bridge).tick();
    expect(queuedPlans(call)).toEqual([]);
    expect(packageFailures(dir)[0]?.reason).toBe("check failed: build_block: NO_SITE no water nearby");
    const other = runDir();
    writeLedger(other, 1, [furnaces("refused")]);
    const refused = fakeBridge({ queue_plan: () => { throw new ModError("queue_plan requires 1-200 steps"); } });
    await createPackageQueue(() => other, refused.bridge).tick();
    expect(packageFailures(other)).toEqual([expect.objectContaining({ package_id: "refused", reason: "queue_plan requires 1-200 steps" })]);
  });

  it("chains after_package_id onto a pending predecessor and fails after a failed one", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("first")]);
    const { call, bridge } = fakeBridge();
    const queue = createPackageQueue(() => dir, bridge);
    await queue.tick();
    writeLedger(dir, 2, [furnaces("second", "first"), furnaces("third", "gone")]);
    await queue.tick();
    expect(queuedPlans(call).at(-1)).toMatchObject({ source: "package:second", after_plan_id: 41 });
    expect(readPackageQueue(dir)?.packages.third).toMatchObject({ status: "failed", reason: "after_package_id gone was never queued" });
    writeLedger(dir, 3, [furnaces("fourth", "third")]);
    await queue.tick();
    expect(readPackageQueue(dir)?.packages.fourth).toMatchObject({ status: "failed", reason: "after_package_id third failed" });
  });

  it("waits while the body is missing, offline, or another live process holds the run", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("iron-a")]);
    const absent = fakeBridge({ ping: () => ({ companion_exists: false }) });
    await createPackageQueue(() => dir, absent.bridge).tick();
    await createPackageQueue(() => dir, async () => { throw new Error("configuration is missing"); }).tick();
    fs.writeFileSync(path.join(dir, "package-queue.lock"), `${process.ppid}\n`);
    const present = fakeBridge();
    await createPackageQueue(() => dir, present.bridge).tick();
    expect(queuedPlans(absent.call)).toEqual([]);
    expect(queuedPlans(present.call)).toEqual([]);
    expect(fs.existsSync(path.join(dir, "package-queue.json"))).toBe(false);
    // A lock left by a process that is gone is taken over.
    fs.writeFileSync(path.join(dir, "package-queue.lock"), "999999999\n");
    await createPackageQueue(() => dir, present.bridge).tick();
    expect(queuedPlans(present.call)).toHaveLength(1);
  });

  it("queues nothing while the mod's FIFO latch is closed: before the pilot's first plan or after an emergency stop", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("iron-a")]);
    let fifo: Record<string, number> = {};
    const { call, bridge } = fakeBridge({ ping: () => ({ companion_exists: true, tick: 900, fifo }) });
    const queue = createPackageQueue(() => dir, bridge);
    await queue.tick();
    expect(queuedPlans(call)).toEqual([]);
    fifo = { idle_seconds: 0 };
    await queue.tick();
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:iron-a"]);
  });

  it("queues again a package whose record is newer than the loaded save (a rollback), never chaining onto its stale plan", async () => {
    const dir = runDir();
    writeLedger(dir, 2, [furnaces("p3"), furnaces("p4", "p3")]);
    fs.writeFileSync(path.join(dir, "package-queue.json"), JSON.stringify({ packages: {
      p3: { status: "queued", plan_id: 57, revision: 1, at: "2026-10-04T00:00:00Z", tick: 1000 } } }));
    const { call, bridge } = fakeBridge({ ping: () => ({ companion_exists: true, tick: 400, fifo: { idle_seconds: 3 } }) });
    await createPackageQueue(() => dir, bridge).tick();
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:p3", "package:p4"]);
    expect(queuedPlans(call)[1]).toMatchObject({ after_plan_id: 41 });
    expect(call.mock.calls.some(([method, params]) => method === "plan_status" && params.plan_id === 57)).toBe(false);
    expect(readPackageQueue(dir)?.packages.p3).toMatchObject({ status: "queued", plan_id: 41, tick: 400 });
  });

  it("re-queues a package whose recorded plan_id now names another plan after a save restore", async () => {
    const dir = runDir();
    writeLedger(dir, 2, [furnaces("p3"), furnaces("p4", "p3")]);
    // Both records predate the restored save's tick, so the tick check keeps them.
    fs.writeFileSync(path.join(dir, "package-queue.json"), JSON.stringify({ packages: {
      p3: { status: "queued", plan_id: 57, revision: 1, at: "2026-10-04T00:00:00Z", tick: 300 },
      p4: { status: "queued", plan_id: 58, revision: 1, at: "2026-10-04T00:00:00Z", tick: 300 } } }));
    const { call, bridge, sources } = fakeBridge();
    sources.set(57, "pilot-plan-that-reused-57" as string);
    sources.set(58, "package:p4");
    await createPackageQueue(() => dir, bridge).tick();
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:p3"]);
    expect(readPackageQueue(dir)?.packages).toMatchObject({ p3: { status: "queued", plan_id: 41 }, p4: { plan_id: 58 } });
    // A successor whose predecessor's plan_id was reused re-queues the predecessor first.
    const other = runDir();
    writeLedger(other, 2, [furnaces("a"), furnaces("b", "a")]);
    const second = fakeBridge();
    const queue = createPackageQueue(() => other, second.bridge);
    await queue.tick();
    writeLedger(other, 3, [furnaces("a"), furnaces("c", "a")]);
    second.sources.set(41, "upkeep");
    await queue.tick();
    expect(readPackageQueue(other)?.packages.a).toBeUndefined();
    await queue.tick();
    expect(queuedPlans(second.call).map((plan: any) => plan.source)).toEqual(["package:a", "package:b", "package:a", "package:c"]);
    expect(queuedPlans(second.call).at(-1)).toMatchObject({ after_plan_id: 43 });
  });

  it("queues nothing more once an emergency stop closes the latch during a pass", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("iron-a"), furnaces("iron-b")]);
    let pings = 0;
    const { call, bridge } = fakeBridge({ ping: () => ({ companion_exists: true, tick: 900,
      fifo: ++pings <= 2 ? { idle_seconds: 0 } : {} }) });
    await createPackageQueue(() => dir, bridge).tick();
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:iron-a"]);
    expect(readPackageQueue(dir)?.packages["iron-b"]).toBeUndefined();
  });

  it("keeps a package whose queue answer was lost as queuing and resends it; the mod answers with the same plan", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("first"), furnaces("second", "first")]);
    const bySource = new Map<string, number>();
    let lost = true;
    const { call, bridge } = fakeBridge({
      queue_plan: (params) => {
        const plan = bySource.get(params.source) ?? 70 + bySource.size;
        bySource.set(params.source, plan);
        if (lost) { lost = false; throw new Error("RCON timeout"); }
        return { plan_id: plan };
      },
    });
    const queue = createPackageQueue(() => dir, bridge);
    await queue.tick();
    expect(readPackageQueue(dir)?.packages.first).toMatchObject({ status: "queuing" });
    expect(readPackageQueue(dir)?.packages.second).toBeUndefined();
    expect(packageFailures(dir)).toEqual([]);
    await queue.tick();
    expect(readPackageQueue(dir)?.packages).toMatchObject({ first: { status: "queued", plan_id: 70 },
      second: { status: "queued", plan_id: 71 } });
    expect(queuedPlans(call).at(-1)).toMatchObject({ source: "package:second", after_plan_id: 70 });
    expect(call.mock.calls.filter(([method]) => method === "build_block")).toHaveLength(2);
    expect(packageFailures(dir)).toEqual([]);
    expect(call.mock.calls.some(([method, params]) => method === "plan_status" && params.plan_id === undefined)).toBe(false);
  });

  it("dry runs that stop at their one tick of work do not fail a package", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("big")]);
    const { call, bridge } = fakeBridge({ build_block: () => ({ placed: {}, incomplete: true,
      failed: [{ code: "SITE_SEARCH_INCOMPLETE", reason: "the dry run checked 120 sites" }] }) });
    await createPackageQueue(() => dir, bridge).tick();
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:big"]);
  });

  it("takes over a dead process's lock atomically: a lock replaced meanwhile is put back", () => {
    const dir = runDir();
    const lock = path.join(dir, "package-queue.lock");
    fs.writeFileSync(lock, "999999999\n");
    const live = new Set([111, 222]);
    // While 222 judges the stale owner dead, 111 takes the lock over first.
    const racing = (pid: number) => {
      if (pid === 999999999) { fs.rmSync(lock); fs.writeFileSync(lock, "111\n"); return false; }
      return live.has(pid);
    };
    expect(holdLock(dir, 222, racing)).toBe(false);
    expect(fs.readFileSync(lock, "utf8")).toBe("111\n");
    expect(fs.readdirSync(dir)).toEqual(["package-queue.lock"]);
    expect(holdLock(dir, 111, (pid) => live.has(pid))).toBe(true);
    expect(holdLock(dir, 222, (pid) => live.has(pid))).toBe(false);
    live.delete(111);
    expect(holdLock(dir, 222, (pid) => live.has(pid))).toBe(true);
    expect(fs.readFileSync(lock, "utf8")).toBe("222\n");
  });

  it("queues nothing when the outcome record is unreadable", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("iron-a")]);
    fs.writeFileSync(path.join(dir, "package-queue.json"), "{broken");
    const { call, bridge } = fakeBridge();
    await createPackageQueue(() => dir, bridge).tick();
    expect(call).not.toHaveBeenCalled();
  });
});

describe("current run directory", () => {
  it("names the run that server start launched only while its server runs", () => {
    vi.stubEnv("XDG_DATA_HOME", runDir());
    const dir = runDir();
    expect(currentRunDir()).toBeNull();
    fs.mkdirSync(path.dirname(currentRunPointer()), { recursive: true });
    fs.writeFileSync(currentRunPointer(), `${dir}\n`);
    fs.writeFileSync(runPaths(dir).pid, "4242\n");
    expect(currentRunDir(() => ({ exe: "/opt/factorio/bin/x64/factorio", cwd: dir }))).toBe(path.resolve(dir));
    expect(currentRunDir(() => { throw new Error("gone"); })).toBeNull();
  });
});
