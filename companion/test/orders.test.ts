import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { JobBusyError, ModError, WriterRetiredError, type Bridge } from "../src/bridge.js";
import { createOrdersTracker, createPackageQueue, holdLock, packageFailures, packageVerifications, readPackageQueue } from "../src/coordination/orders.js";
import { registerMcpTools, result, runMcpServer, type McpSurface, type SessionRole } from "../src/mcp/server.js";
import * as coordination from "../src/coordination/orders.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { currentRunDir, currentRunPointer, runPaths } from "../src/server/server.js";

const dirs: string[] = [];
afterEach(() => {
  vi.unstubAllEnvs();
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.restoreAllMocks();
  dirs.splice(0).forEach((dir) => fs.rmSync(dir, { recursive: true, force: true }));
});
const runDir = () => { const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-orders-")); dirs.push(dir); return dir; };

const furnaces = (id: string, after: string | null = null) => ({
  package_id: id, serves: "NOW", intent: "smelt iron", after_package_id: after, source_tick: 10,
  anchor: { x: 0, y: 0 }, required_items: {}, success_check: "plates appear",
  steps: [{ action: "place_entity", x: 1.5, y: 2.5, name: "stone-furnace" },
    { action: "build_layout", site: { near: { x: 0, y: 0 } }, entities: [{ name: "stone-furnace", dx: 0, dy: 0 }] }],
});
function writeLedger(dir: string, revision: number, packages: unknown[], objective = "automate iron", research?: string[]) {
  const priority = (text: string) => ({ objective: text, strategic_reason: "r", completion_condition: "c", essential_prerequisite: null });
  fs.writeFileSync(path.join(dir, "operations.json"), JSON.stringify({
    schema_version: 2, run: { id: "run-1", release_sha: "a".repeat(40), baseline_save_sha256: "b".repeat(64),
      save_identity: "s", created_at: "2026-10-04T00:00:00Z",
      roles: { pilot: { model: "gpt-6-luna", reasoning: "low", fast: true }, strategist: { model: "gpt-6.1-sol", reasoning: "medium", fast: false } } },
    revision, source_tick: 10, phase: "start", bottleneck: "iron", latest_measured_capacity: [],
    task_list: { NOW: priority(objective), NEXT: priority("copper"), LATER: priority("science") },
    assumptions: [], build_packages: packages, ...(research === undefined ? {} : { research }),
  }));
}

/** A fake game: ping, event_state, can_place, layout and blueprint checks, captures, queue_plan and plan_status.
 *  No pilot plan has run: the FIFO reports no idle time. */
function fakeBridge(overrides: Record<string, (params: any) => unknown> = {}) {
  let next = 40;
  const sources = new Map<number, string>();
  const answer = async (method: string, params: any): Promise<any> => {
    if (overrides[method]) return overrides[method]!(params);
    if (method === "ping") return { companion_exists: true, tick: 900, body: { state: "on_surface", surface_ref: "nauvis" }, fifo: { queue_depth: 0 } };
    if (method === "event_state") return { tick: 900, queue_depth: 0, fifo_empty: true, human_hold: false };
    if (method === "can_place") return { results: params.placements.map(() => ({ can_place: true })) };
    if (method === "build_layout") return { placed: {}, failed: {} };
    if (method === "blueprint_place") return { check_only: true, ok: true, collisions: {} };
    if (method === "blueprint_capture") return { name: params.name, entities: 4 };
    if (method === "queue_plan") return { plan_id: ++next };
    if (method === "plan_status") return { plan_id: params.plan_id, status: "running", source: sources.get(params.plan_id) };
    // The change journal: nothing changed in any footprint.
    if (method === "activity_log") return { tick: 900, entries: {}, omitted: 0, changes: { rows: {}, omitted: 0, size: 200 } };
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
    expect(call).toHaveBeenCalledWith("can_place", { placements: [{ item: "stone-furnace", position: { x: 1.5, y: 2.5 }, direction: undefined }], surface: "nauvis" });
    expect(call).toHaveBeenCalledWith("build_layout", { site: { near: { x: 0, y: 0 } }, entities: [{ name: "stone-furnace", dx: 0, dy: 0 }], check_only: true });
    expect(readPackageQueue(dir)?.packages).toMatchObject({ "iron-a": { status: "queued", plan_id: 41, revision: 3, tick: 900 },
      "iron-b": { status: "queued", plan_id: 42 } });
    expect(fs.statSync(path.join(dir, "package-queue.json")).mode & 0o777).toBe(0o600);
    // A later tick and a second process never queue them again.
    await createPackageQueue(() => dir, bridge).tick();
    expect(queuedPlans(call)).toHaveLength(2);
    expect(createOrdersTracker(() => dir).attach(result({ summary: "ok" })).structuredContent.orders.packages)
      .toEqual([{ id: "iron-a", status: "queued", plan_id: 41 }, { id: "iron-b", status: "queued", plan_id: 42 }]);
  });

  it("spans a package's footprint over its anchor and every position its steps name, padded", () => {
    const entry = { ...furnaces("wide"), steps: [
      { action: "place_entity", x: 1.5, y: 2.5, name: "stone-furnace" },
      { action: "build_layout", anchor: { x: 10, y: 10 }, entities: [{ name: "lab", dx: 4, dy: -2 }] },
      { action: "deconstruct_area", center: { x: -5, y: 0 }, radius: 2 },
      { action: "copy_settings", from: { x: 0, y: 0 }, to: [{ x: 3, y: -4 }] },
      // Hub-relative positions on a platform are not on the package's surface.
      { action: "set_recipe", x: 99, y: 99, recipe: "x", platform: 1 }] };
    expect(coordination.packageFootprint(entry as never)).toEqual({ left_top: { x: -10, y: -7 }, right_bottom: { x: 17, y: 13 } });
  });

  it("records what changed in a package's footprint after its source_tick, and queues it anyway", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("iron-a"), furnaces("iron-b")]);
    const row = { tick: 50, op: "removed", name: "stone-furnace", by: "human", surface: "nauvis", position: { x: 1.5, y: 2.5 } };
    // A merged row stands for each change it covers.
    const merged = { tick: 60, op: "built", name: "transport-belt", by: "human", surface: "nauvis", count: 5,
      area: { left_top: { x: 0, y: 0 }, right_bottom: { x: 4, y: 0 } } };
    const asked: unknown[] = [];
    const { call, bridge } = fakeBridge({ activity_log: (params) => {
      asked.push(params);
      return asked.length === 1 ? { tick: 900, entries: {}, omitted: 0, changes: { rows: [row, merged], omitted: 2, size: 200 } }
        : (() => { throw new ModError("unknown method"); })();
    } });
    await createPackageQueue(() => dir, bridge).tick();
    expect(asked[0]).toEqual({ limit: 1, changes: { since_tick: 10, surface: "nauvis", limit: 3,
      area: { left_top: { x: -3, y: -3 }, right_bottom: { x: 4.5, y: 5.5 } } } });
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:iron-a", "package:iron-b"]);
    const records = readPackageQueue(dir)!.packages;
    expect(records["iron-a"]).toMatchObject({ status: "queued", footprint_changed: { count: 8, changes: [row, merged] } });
    // A journal that cannot be read (an older mod) records nothing and holds nothing.
    expect(records["iron-b"]).toMatchObject({ status: "queued" });
    expect(records["iron-b"]).not.toHaveProperty("footprint_changed");
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

  it("fails a layout whose dry run reports failed placements, or a mod error", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("no-water")]);
    const { call, bridge } = fakeBridge({ build_layout: () => ({ placed: {}, failed: [{ index: 2, code: "NO_SITE", reason: "no water nearby" }] }) });
    await createPackageQueue(() => dir, bridge).tick();
    expect(queuedPlans(call)).toEqual([]);
    expect(packageFailures(dir)[0]?.reason).toBe("check failed: build_layout: NO_SITE no water nearby");
    const other = runDir();
    writeLedger(other, 1, [furnaces("refused")]);
    const refused = fakeBridge({ queue_plan: () => { throw new ModError("queue_plan requires 1-200 steps"); } });
    await createPackageQueue(() => other, refused.bridge).tick();
    expect(packageFailures(other)).toEqual([expect.objectContaining({ package_id: "refused", reason: "queue_plan requires 1-200 steps" })]);
  });

  it("retries a package whose dry run or capture met busy job slots or a slow game, never failing it", async () => {
    for (const method of ["build_layout", "blueprint_capture"]) {
      const dir = runDir();
      const captured = { ...furnaces("iron-a"), steps: [{ action: "blueprint_capture", name: "cell", center: { x: 0, y: 0 }, radius: 4 },
        ...furnaces("iron-a").steps] };
      writeLedger(dir, 1, [captured]);
      let busy = true;
      const { call, bridge } = fakeBridge({ [method]: (params: any) => {
        if (busy) { busy = false; throw new JobBusyError(`JOBS_BUSY: 8 jobs are pending or unread`); }
        return method === "build_layout" ? { placed: {}, failed: {} } : { name: params.name, entities: 4 };
      } });
      const queue = createPackageQueue(() => dir, bridge);
      await queue.tick();
      expect(readPackageQueue(dir)?.packages["iron-a"]).toBeUndefined();
      expect(packageFailures(dir)).toEqual([]);
      await queue.tick();
      expect(readPackageQueue(dir)?.packages["iron-a"]).toMatchObject({ status: "queued" });
      expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:iron-a"]);
    }
  });

  it("checks only the steps before a landfill against the map, and holds a successor of a landfill package", async () => {
    const dir = runDir();
    const across = { ...furnaces("across-lake"), steps: [
      { action: "place_entity", x: -3.5, y: 0.5, name: "wooden-chest" },
      { action: "place_tiles", item: "landfill", area: { left_top: { x: 0, y: 0 }, right_bottom: { x: 6, y: 6 } } },
      { action: "place_entity", x: 2.5, y: 2.5, name: "stone-furnace" },
      { action: "build_layout", anchor: { x: 3, y: 3 }, entities: [{ name: "stone-furnace", dx: 0, dy: 0 }] }] };
    writeLedger(dir, 1, [across]);
    // The lake is still water: anything checked on it would fail.
    const { call, bridge } = fakeBridge({
      can_place: (params) => ({ results: params.placements.map((place: any) => place.position.x > 0
        ? { can_place: false, reason: "touches water at (2.5, 2.5)" } : { can_place: true }) }),
      build_layout: () => ({ placed: {}, failed: [{ index: 0, code: "BLOCKED", reason: "water" }] }),
    });
    const queue = createPackageQueue(() => dir, bridge);
    await queue.tick();
    expect(packageFailures(dir)).toEqual([]);
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:across-lake"]);
    expect(call).toHaveBeenCalledWith("can_place", { placements: [{ item: "wooden-chest", position: { x: -3.5, y: 0.5 }, direction: undefined }], surface: "nauvis" });
    expect(call.mock.calls.some(([method]) => method === "build_layout")).toBe(false);
    // A successor is checked once the landfill package has ended, not while it runs.
    writeLedger(dir, 2, [across, { ...furnaces("on-land", "across-lake"), steps: [{ action: "place_entity", x: 1.5, y: 2.5, name: "stone-furnace" }] }]);
    await queue.tick();
    expect(readPackageQueue(dir)?.packages["on-land"]).toBeUndefined();
  });

  it("checks only the steps before a removal against the map, and holds a successor of a removing package", async () => {
    // The belt still stands where the underground replaces it: anything checked there would fail.
    const { call } = fakeBridge({
      can_place: (params) => ({ results: params.placements.map(() => ({ can_place: false, reason: "blocked by transport-belt at (60.5, -42.5)" })) }),
      build_layout: () => ({ placed: {}, failed: [{ index: 0, code: "BLOCKED", reason: "underground-belt at (60.5, -42.5): blocked by transport-belt at (60.5, -42.5)" }] }),
    });
    const bridge = { call } as unknown as Bridge;
    const layout = { action: "build_layout", anchor: { x: 60, y: -43 }, entities: [{ name: "underground-belt", dx: 0, dy: 0 }] };
    const area = { left_top: { x: 60, y: -43 }, right_bottom: { x: 61, y: -42 } };
    for (const removal of [
      { action: "mine", x: 60.5, y: -42.5, expected_name: "transport-belt" },
      { action: "deconstruct_area", area },
      { action: "move_entity", from: { x: 60.5, y: -42.5 }, to: { x: 64.5, y: -42.5 } },
    ]) {
      const steps = [{ action: "get_items", item: "underground-belt", count: 2 }, removal, layout,
        { action: "place_entity", x: 60.5, y: -42.5, name: "underground-belt" }];
      expect(await coordination.checkPackage(bridge, { ...furnaces("replace"), steps } as any)).toBeNull();
    }
    expect(call.mock.calls.some(([method]) => method === "build_layout" || method === "can_place")).toBe(false);
    // Before the removal the map is still checked.
    expect(await coordination.checkPackage(bridge, { ...furnaces("replace"), steps: [layout, { action: "mine", x: 60.5, y: -42.5 }] } as any))
      .toContain("blocked by transport-belt");

    const dir = runDir();
    const removing = { ...furnaces("remove-belt"), steps: [{ action: "mine", x: 60.5, y: -42.5, expected_name: "transport-belt" }] };
    writeLedger(dir, 1, [removing]);
    const queue = createPackageQueue(() => dir, fakeBridge().bridge);
    await queue.tick();
    writeLedger(dir, 2, [removing, { ...furnaces("underground", "remove-belt"), steps: [layout] }]);
    await queue.tick();
    expect(readPackageQueue(dir)?.packages.underground).toBeUndefined();    // The strategist drops the queued removal from the ledger: its successor still waits.
    expect(readPackageQueue(dir)?.packages["remove-belt"]).toMatchObject({ status: "queued", changes_ground: true });
    writeLedger(dir, 3, [{ ...furnaces("underground-2", "remove-belt"), steps: [layout] }]);
    await queue.tick();
    expect(readPackageQueue(dir)?.packages["underground-2"]).toBeUndefined();
  });

  it("rejects a package over lava or an ocean, or one whose building the planet's conditions forbid", async () => {
    for (const [result, text] of [
      [{ can_place: false, reason: "the footprint touches lava — pick dry land or cover it with place_tiles first" }, "touches lava"],
      [{ can_place: false, reason: "the footprint touches heavy-oil ocean — pick dry land or cover it with place_tiles first" }, "heavy-oil ocean"],
      [{ can_place: false, code: "SURFACE_CONDITION", reason: "SURFACE_CONDITION: big-mining-drill needs pressure = 4000; this surface has 1000" },
        "SURFACE_CONDITION"],
    ] as const) {
      const dir = runDir();
      writeLedger(dir, 1, [furnaces("wet")]);
      const { call, bridge } = fakeBridge({ can_place: (params) => ({ results: params.placements.map(() => result) }) });
      await createPackageQueue(() => dir, bridge).tick();
      expect(readPackageQueue(dir)?.packages.wet).toMatchObject({ status: "failed" });
      expect(readPackageQueue(dir)?.packages.wet?.reason).toContain(text);
      expect(queuedPlans(call)).toEqual([]);
    }
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

  it("retires for good at a newer writer generation, giving up its lock, and never fails a package for it", async () => {
    const dir = runDir();
    const lock = path.join(dir, "package-queue.lock");
    writeLedger(dir, 1, [furnaces("iron-a")]);
    let generation = 1;
    const ping = () => ({ companion_exists: true, tick: 900, writer_generation: generation, body: { state: "on_surface", surface_ref: "nauvis" } });
    const old = fakeBridge({ ping });
    const queue = createPackageQueue(() => dir, async () => ({ call: old.call, writerGeneration: 1 } as unknown as Bridge));
    await queue.tick();
    expect(queuedPlans(old.call)).toHaveLength(1);
    expect(fs.readFileSync(lock, "utf8").trim()).toBe(String(process.pid));
    // A replacement pilot claimed generation 2: the old process stops and frees the run.
    generation = 2;
    writeLedger(dir, 2, [furnaces("iron-a"), furnaces("iron-b")]);
    await queue.tick();
    old.call.mockClear();
    await queue.tick();
    expect(old.call).not.toHaveBeenCalled();
    expect(queuedPlans(old.call)).toEqual([]);
    expect(fs.existsSync(lock)).toBe(false);
    expect(readPackageQueue(dir)?.packages["iron-b"]).toBeUndefined();
    // Claimed between its ping and its write: the mod refuses, the record stays queuing, and the new pilot's bridge sends it.
    const raced = runDir();
    writeLedger(raced, 1, [furnaces("iron-a")]);
    const refused = fakeBridge({ ping, queue_plan: () => { throw new WriterRetiredError("WRITER_RETIRED: writer generation 2 was replaced by generation 3"); } });
    const racing = createPackageQueue(() => raced, async () => ({ call: refused.call, writerGeneration: 2 } as unknown as Bridge));
    await racing.tick();
    expect(readPackageQueue(raced)?.packages["iron-a"]).toMatchObject({ status: "queuing" });
    expect(fs.existsSync(path.join(raced, "package-queue.lock"))).toBe(false);
    refused.call.mockClear();
    await racing.tick();
    expect(refused.call).not.toHaveBeenCalled();
    const next = fakeBridge({ ping: () => ({ ...ping(), writer_generation: 3 }) });
    await createPackageQueue(() => raced, async () => ({ call: next.call, writerGeneration: 3 } as unknown as Bridge)).tick();
    expect(queuedPlans(next.call)).toHaveLength(1);
    expect(readPackageQueue(raced)?.packages["iron-a"]).toMatchObject({ status: "queued" });
  });

  it("queues a package only while the body is on its surface; elsewhere it waits, never fails", async () => {
    const dir = runDir();
    // A package stored without a surface (before protocol 28) is for nauvis.
    writeLedger(dir, 1, [{ ...furnaces("foundry"), surface: "vulcanus" }, furnaces("iron-a", "foundry")]);
    let body: unknown = { state: "aboard_platform", surface_ref: "platform:3", platform_name: "Orbit" };
    const { call, bridge } = fakeBridge({ ping: () => ({ companion_exists: true, tick: 900, body }) });
    const queue = createPackageQueue(() => dir, bridge);
    await queue.tick();
    expect(queuedPlans(call)).toEqual([]);
    expect(call.mock.calls.some(([method]) => method === "can_place")).toBe(false);
    expect(readPackageQueue(dir)?.packages).toMatchObject({
      foundry: { status: "waiting_surface", reason: "the body is on platform:3; the package is for vulcanus" },
      "iron-a": { status: "waiting_surface", reason: "the body is on platform:3; the package is for nauvis" } });
    expect(packageFailures(dir)).toEqual([]);
    expect(createOrdersTracker(() => dir).attach(result({ summary: "ok" })).structuredContent.orders.packages)
      .toEqual([{ id: "foundry", status: "waiting_surface", reason: "the body is on platform:3; the package is for vulcanus" },
        { id: "iron-a", status: "waiting_surface", reason: "the body is on platform:3; the package is for nauvis" }]);
    // An unchanged wait is not rewritten every tick.
    const written = fs.statSync(path.join(dir, "package-queue.json")).mtimeMs;
    await queue.tick();
    expect(fs.statSync(path.join(dir, "package-queue.json")).mtimeMs).toBe(written);
    // Landed on Vulcanus: its package is checked on that surface and queued
    // there; its nauvis successor keeps waiting.
    body = { state: "on_surface", surface_ref: "vulcanus" };
    await queue.tick();
    expect(queuedPlans(call)).toEqual([expect.objectContaining({ source: "package:foundry", surface: "vulcanus" })]);
    expect(call).toHaveBeenCalledWith("can_place", { placements: [{ item: "stone-furnace", position: { x: 1.5, y: 2.5 }, direction: undefined }], surface: "vulcanus" });
    expect(readPackageQueue(dir)?.packages).toMatchObject({ foundry: { status: "queued" }, "iron-a": { status: "waiting_surface" } });
    body = { state: "on_surface", surface_ref: "nauvis" };
    await queue.tick();
    expect(queuedPlans(call).map((plan: any) => [plan.source, plan.surface, plan.after_plan_id])).toEqual([["package:foundry", "vulcanus", undefined],
      ["package:iron-a", "nauvis", 41]]);
  });

  it("holds a package for the departure planet while the body rides a pod or a trip is pending", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("iron-a")]);
    // A travel to platform:3 is queued; the body still stands on nauvis.
    let body: unknown = { state: "on_surface", surface_ref: "nauvis", bound_for: "platform:3" };
    const { call, bridge } = fakeBridge({ ping: () => ({ companion_exists: true, tick: 900, body }) });
    const queue = createPackageQueue(() => dir, bridge);
    await queue.tick();
    expect(queuedPlans(call)).toEqual([]);
    expect(readPackageQueue(dir)?.packages["iron-a"])
      .toMatchObject({ status: "waiting_surface", reason: "the body is bound for platform:3; the package is for nauvis" });
    // Riding up: the pod is still over nauvis.
    body = { state: "in_transit", surface_ref: "nauvis" };
    await queue.tick();
    expect(queuedPlans(call)).toEqual([]);
    expect(readPackageQueue(dir)?.packages["iron-a"])
      .toMatchObject({ status: "waiting_surface", reason: "the body is in a cargo pod; the package is for nauvis" });
    // Back, settled on nauvis with nothing pending: queued.
    body = { state: "on_surface", surface_ref: "nauvis" };
    await queue.tick();
    expect(queuedPlans(call)).toEqual([expect.objectContaining({ source: "package:iron-a", surface: "nauvis" })]);
  });

  it("holds packages written before an emergency stop until the strategist rewrites the ledger, and waits out a human hold", async () => {
    const dir = runDir();
    const ledger = path.join(dir, "operations.json");
    const at = (time: string) => new Date(`2026-10-05T${time}Z`);
    writeLedger(dir, 1, [furnaces("iron-a")]);
    fs.utimesSync(ledger, at("09:00:00"), at("09:00:00"));
    let events: Record<string, unknown> = { tick: 900, human_hold: true };
    let clock = at("10:00:00");
    const { call, bridge } = fakeBridge({ event_state: () => events });
    const queue = createPackageQueue(() => dir, bridge, () => clock);
    await queue.tick();
    expect(queuedPlans(call)).toEqual([]);
    // The stop at tick 800 is first seen at 10:00, 100 ticks after it, and after the ledger was written.
    events = { tick: 900, human_hold: false, last_cancel_all_tick: 800 };
    await queue.tick();
    expect(queuedPlans(call)).toEqual([]);
    expect(readPackageQueue(dir)?.cancel_all).toEqual({ tick: 800, observed_at: "2026-10-05T09:59:58.333Z" });
    clock = at("10:05:00");
    await createPackageQueue(() => dir, bridge, () => clock).tick();
    expect(queuedPlans(call)).toEqual([]);
    expect(readPackageQueue(dir)?.cancel_all?.observed_at).toBe("2026-10-05T09:59:58.333Z");
    // The strategist rewrites the ledger after the stop: the package is queued with no pilot plan having run.
    writeLedger(dir, 2, [furnaces("iron-a")]);
    fs.utimesSync(ledger, at("10:01:00"), at("10:01:00"));
    await queue.tick();
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:iron-a"]);
    expect(readPackageQueue(dir)?.packages["iron-a"]).toMatchObject({ status: "queued", revision: 2 });
  });

  it("records a stop while no package exists, so the first package written after it is queued", async () => {
    // The pre-GO rehearsal ends with a stop while the ledger has no packages.
    const dir = runDir();
    const ledger = path.join(dir, "operations.json");
    const at = (time: string) => new Date(`2026-10-05T${time}Z`);
    writeLedger(dir, 1, []);
    fs.utimesSync(ledger, at("09:00:00"), at("09:00:00"));
    let clock = at("10:00:00");
    const { call, bridge } = fakeBridge({ event_state: () => ({ tick: 48_000, human_hold: false, last_cancel_all_tick: 48_000 }) });
    const queue = createPackageQueue(() => dir, bridge, () => clock);
    await queue.tick();
    expect(readPackageQueue(dir)?.cancel_all).toEqual({ tick: 48_000, observed_at: "2026-10-05T10:00:00.000Z" });
    // After GO the strategist writes its first package; the next pass queues it.
    writeLedger(dir, 2, [furnaces("iron-a")]);
    fs.utimesSync(ledger, at("10:10:00"), at("10:10:00"));
    clock = at("10:10:01");
    await queue.tick();
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:iron-a"]);
  });

  it("dates a stop it first sees back to when it happened, so a package written after the stop is queued", async () => {
    // A new bridge starts 10 minutes (36000 ticks) after a stop; the strategist wrote a package 5 minutes after the stop.
    const dir = runDir();
    const ledger = path.join(dir, "operations.json");
    const at = (time: string) => new Date(`2026-10-05T${time}Z`);
    writeLedger(dir, 3, [furnaces("iron-a")]);
    fs.utimesSync(ledger, at("10:05:00"), at("10:05:00"));
    const { call, bridge } = fakeBridge({ event_state: () => ({ tick: 84_000, human_hold: false, last_cancel_all_tick: 48_000 }) });
    await createPackageQueue(() => dir, bridge, () => at("10:10:00")).tick();
    expect(readPackageQueue(dir)?.cancel_all).toEqual({ tick: 48_000, observed_at: "2026-10-05T10:00:00.000Z" });
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:iron-a"]);
  });

  it("queues again a package whose record is newer than the loaded save (a rollback), never chaining onto its stale plan", async () => {
    const dir = runDir();
    writeLedger(dir, 2, [furnaces("p3"), furnaces("p4", "p3")]);
    fs.writeFileSync(path.join(dir, "package-queue.json"), JSON.stringify({ packages: {
      p3: { status: "queued", plan_id: 57, revision: 1, at: "2026-10-04T00:00:00Z", tick: 1000 } } }));
    const { call, bridge } = fakeBridge({ ping: () => ({ companion_exists: true, tick: 400, body: { state: "on_surface", surface_ref: "nauvis" } }) });
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

  it("queues nothing more once an emergency stop or a human hold comes during a pass", async () => {
    for (const late of [{ last_cancel_all_tick: 950 }, { human_hold: true }]) {
      const dir = runDir();
      writeLedger(dir, 1, [furnaces("iron-a"), furnaces("iron-b")]);
      let reads = 0;
      const { call, bridge } = fakeBridge({ event_state: () => ({ tick: 900, human_hold: false, ...(++reads <= 2 ? {} : late) }) });
      await createPackageQueue(() => dir, bridge).tick();
      expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:iron-a"]);
      expect(readPackageQueue(dir)?.packages["iron-b"]).toBeUndefined();
    }
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
    expect(call.mock.calls.filter(([method]) => method === "build_layout")).toHaveLength(2);
    expect(packageFailures(dir)).toEqual([]);
    expect(call.mock.calls.some(([method, params]) => method === "plan_status" && params.plan_id === undefined)).toBe(false);
  });

  it("checks blueprint placements and fails a package whose blueprint position is blocked", async () => {
    const dir = runDir();
    const place = (id: string) => ({ ...furnaces(id), steps: [{ action: "blueprint_place", name: "smelter", position: { x: 4, y: 4 } }] });
    writeLedger(dir, 1, [place("open"), place("blocked")]);
    let checks = 0;
    const { call, bridge } = fakeBridge({ blueprint_place: () => checks++ === 0 ? { ok: true }
      : { ok: false, collisions: [{ code: "PLACE_BLOCKED" }], free_position: { x: 9, y: 4 } } });
    await createPackageQueue(() => dir, bridge).tick();
    expect(call).toHaveBeenCalledWith("blueprint_place", { name: "smelter", position: { x: 4, y: 4 }, check_only: true });
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:open"]);
    expect(packageFailures(dir)[0]).toMatchObject({ package_id: "blocked",
      reason: "check failed: blueprint_place smelter at (4, 4): the position is blocked; the nearest free position is (9, 4)" });
  });

  it("fails a package whose layout or blueprint needs an item the body cannot obtain now, naming it", async () => {
    const dir = runDir();
    const place = { ...furnaces("bp-arm"), steps: [{ action: "blueprint_place", name: "smelter", position: { x: 4, y: 4 } }] };
    const opening = { ...furnaces("opening"), steps: [{ action: "build_layout", site: { near: { x: 0, y: 0 }, on_resource: "iron-ore" }, entities: [{ name: "burner-mining-drill", dx: 1, dy: 1 }, { name: "burner-mining-drill", dx: 3, dy: 1 }] }] };
    writeLedger(dir, 1, [opening, place]);
    const reason = "burner-mining-drill can't be carried now (needs 1 more iron-plate): no idle own furnace smelts it (smelting)";
    const { call, bridge } = fakeBridge({
      build_layout: () => ({ ok: false, placed: [{ name: "burner-mining-drill" }],
        failed: [{ code: "ITEM_UNOBTAINABLE", item: "burner-mining-drill", reason }] }),
      blueprint_place: () => ({ ok: false, collisions: {}, free_position: { x: 4, y: 4 },
        unobtainable: [{ code: "ITEM_UNOBTAINABLE", item: "inserter", reason: "inserter can't be carried now: not researched" }] }),
    });
    await createPackageQueue(() => dir, bridge).tick();
    expect(queuedPlans(call)).toEqual([]);
    expect(packageFailures(dir).map((failure) => [failure.package_id, failure.reason])).toEqual([
      ["opening", `check failed: build_layout: ITEM_UNOBTAINABLE ${reason}`],
      ["bp-arm", "check failed: blueprint_place smelter: ITEM_UNOBTAINABLE inserter can't be carried now: not researched"],
    ]);
  });

  it("checks items only for a package's first step, and for no step while its predecessor's plan is pending", async () => {
    const dir = runDir();
    // The furnace the first step places smelts the plates the later steps need.
    const smelter = { ...furnaces("smelter"), steps: [...furnaces("smelter").steps,
      { action: "blueprint_place", name: "arm", position: { x: 4, y: 4 } }] };
    const mining = { ...furnaces("mining", "smelter"), steps: [{ action: "build_layout", site: { near: { x: 0, y: 0 }, on_resource: "iron-ore" }, entities: [{ name: "burner-mining-drill", dx: 1, dy: 1 }, { name: "burner-mining-drill", dx: 3, dy: 1 }] }] };
    writeLedger(dir, 1, [smelter, mining]);
    const short = [{ code: "ITEM_UNOBTAINABLE", item: "burner-mining-drill", reason: "burner-mining-drill can't be carried now" }];
    const { call, bridge } = fakeBridge({
      build_layout: () => ({ ok: false, placed: {}, failed: short }),
      blueprint_place: () => ({ ok: false, collisions: {}, unobtainable: short }),
    });
    const queue = createPackageQueue(() => dir, bridge);
    await queue.tick();
    await queue.tick();
    expect(packageFailures(dir)).toEqual([]);
    expect(queuedPlans(call).map((plan: any) => [plan.source, plan.after_plan_id])).toEqual([
      ["package:smelter", undefined], ["package:mining", 41]]);
  });

  it("makes a package's leading blueprint captures before its steps, after its predecessor's plan has ended", async () => {
    const dir = runDir();
    const capture = { action: "blueprint_capture", name: "smelter", center: { x: 0, y: 0 }, radius: 6 };
    const reuse = { action: "blueprint_place", name: "smelter", position: { x: 20, y: 0 } };
    writeLedger(dir, 1, [furnaces("build"), { ...furnaces("copy", "build"), steps: [capture, reuse] }]);
    let status = "running";
    const { call, bridge } = fakeBridge({ plan_status: (params) => ({ plan_id: params.plan_id, status, source: "package:build" }) });
    const queue = createPackageQueue(() => dir, bridge);
    await queue.tick();
    // The capture waits until what it records is built.
    expect(queuedPlans(call).map((plan: any) => plan.source)).toEqual(["package:build"]);
    expect(call.mock.calls.some(([method]) => method === "blueprint_capture")).toBe(false);
    status = "completed";
    await queue.tick();
    const methods = call.mock.calls.map(([method]) => method);
    expect(methods.indexOf("blueprint_capture")).toBeLessThan(methods.lastIndexOf("blueprint_place"));
    expect(call).toHaveBeenCalledWith("blueprint_capture", { name: "smelter", center: { x: 0, y: 0 }, radius: 6 });
    expect(queuedPlans(call).at(-1)).toEqual({ steps: [reuse], final_observation_radius: 15, observation_detail: "none", surface: "nauvis", source: "package:copy" });
    expect(readPackageQueue(dir)?.packages.copy).toMatchObject({ status: "queued", plan_id: 42, captured: ["smelter"] });
    // A package of captures only has no plan; one that follows it is not held.
    writeLedger(dir, 2, [{ ...furnaces("snap"), steps: [capture] }, furnaces("after", "snap")]);
    await queue.tick();
    expect(readPackageQueue(dir)?.packages.snap).toEqual(expect.objectContaining({ status: "queued", captured: ["smelter"] }));
    expect(readPackageQueue(dir)?.packages.snap).not.toHaveProperty("plan_id");
    expect(queuedPlans(call).at(-1)).toMatchObject({ source: "package:after" });
    expect(queuedPlans(call).at(-1)).not.toHaveProperty("after_plan_id");
    // A capture the game refuses fails its package.
    writeLedger(dir, 3, [{ ...furnaces("bad"), steps: [capture, reuse] }]);
    const refused = fakeBridge({ blueprint_capture: () => { throw new ModError("blueprint_capture: no own entities stand in that area"); } });
    await createPackageQueue(() => dir, refused.bridge).tick();
    expect(readPackageQueue(dir)?.packages.bad).toMatchObject({ status: "failed",
      reason: "capture failed: blueprint_capture: no own entities stand in that area" });
    expect(queuedPlans(refused.call)).toEqual([]);
  });

  it("queues the ledger's research once per revision that lists any, during a human hold and with the body elsewhere", async () => {
    const dir = runDir();
    writeLedger(dir, 4, [], "automate science", ["automation", "logistics"]);
    const researched: any[] = [];
    const { call, bridge } = fakeBridge({
      ping: () => ({ companion_exists: true, tick: 900, body: { state: "aboard_platform", surface_ref: "platform:1" } }),
      event_state: () => ({ tick: 900, human_hold: true }),
      start_research: (params) => { researched.push(params); return { queued: true, technologies: ["logistics"], skipped: ["automation"] }; },
    });
    const queue = createPackageQueue(() => dir, bridge, () => new Date("2026-10-05T10:00:00Z"));
    await queue.tick();
    expect(researched).toEqual([{ technologies: ["automation", "logistics"], origin: "ledger/r4" }]);
    expect(readPackageQueue(dir)?.research).toEqual({ revision: 4, status: "queued", technologies: ["automation", "logistics"],
      queued: ["logistics"], skipped: ["automation"], at: "2026-10-05T10:00:00.000Z", tick: 900 });
    // Once per revision: later passes and another process leave it alone.
    await queue.tick();
    await createPackageQueue(() => dir, bridge).tick();
    expect(researched).toHaveLength(1);
    // A revision without research changes nothing; a later one that lists research again is applied.
    writeLedger(dir, 5, [], "automate science", []);
    await queue.tick();
    expect(researched).toHaveLength(1);
    writeLedger(dir, 6, [], "automate science", ["automation", "logistics"]);
    await queue.tick();
    expect(researched.map((params) => params.origin)).toEqual(["ledger/r4", "ledger/r6"]);
    expect(queuedPlans(call)).toEqual([]);
  });

  it("records a refused research as failed once, retries a lost answer, and holds research written before a stop", async () => {
    const dir = runDir();
    const at = (time: string) => new Date(`2026-10-05T${time}Z`);
    writeLedger(dir, 2, [], "automate science", ["trigger-alpha"]);
    let answer: () => unknown = () => { throw new Error("RCON timeout"); };
    const { call, bridge } = fakeBridge({ start_research: () => answer() });
    const queue = createPackageQueue(() => dir, bridge);
    await queue.tick();
    expect(readPackageQueue(dir)?.research).toBeUndefined();
    answer = () => { throw new ModError("cannot queue trigger technology trigger-alpha"); };
    await queue.tick();
    expect(readPackageQueue(dir)?.research).toMatchObject({ revision: 2, status: "failed",
      reason: "cannot queue trigger technology trigger-alpha" });
    await queue.tick();
    expect(call.mock.calls.filter(([method]) => method === "start_research")).toHaveLength(2);
    // A stop after the ledger was written holds its research until the strategist rewrites it.
    const stopped = runDir();
    writeLedger(stopped, 3, [], "automate science", ["automation"]);
    fs.utimesSync(path.join(stopped, "operations.json"), at("09:00:00"), at("09:00:00"));
    const held = fakeBridge({ event_state: () => ({ tick: 900, human_hold: false, last_cancel_all_tick: 900 }),
      start_research: () => ({ queued: true, technologies: ["automation"] }) });
    await createPackageQueue(() => stopped, held.bridge, () => at("10:00:00")).tick();
    expect(held.call.mock.calls.some(([method]) => method === "start_research")).toBe(false);
    writeLedger(stopped, 4, [], "automate science", ["automation"]);
    fs.utimesSync(path.join(stopped, "operations.json"), at("10:01:00"), at("10:01:00"));
    await createPackageQueue(() => stopped, held.bridge, () => at("10:02:00")).tick();
    expect(readPackageQueue(stopped)?.research).toMatchObject({ revision: 4, status: "queued", queued: ["automation"] });
  });

  it("shows the ledger research outcome in activity_log, with the mod's research row in the summary", async () => {
    const dir = runDir();
    writeLedger(dir, 4, [], "automate science", ["automation"]);
    const { bridge } = fakeBridge({ start_research: () => ({ queued: true, technologies: ["automation"] }),
      activity_log: () => ({ tick: 900, omitted: 0, entries: [{ kind: "research", tick: 900, origin: "ledger/r4",
        technologies: ["automation"], after_plan_id: 3 }] }) });
    await createPackageQueue(() => dir, bridge).tick();
    const handlers: Record<string, (args: any) => Promise<any>> = {};
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } }, bridge,
      () => ({ ok: false, error: "offline fixture" }), "read-only", () => dir, "strategist");
    const log = (await handlers.activity_log!({})).structuredContent;
    expect(log.research).toMatchObject({ revision: 4, status: "queued", technologies: ["automation"], queued: ["automation"] });
    expect(log.summary).toBe("1 row; last: research by ledger/r4: queued automation");
  });

  it("applies research again when its record is newer than the loaded save (a rollback)", async () => {
    const dir = runDir();
    writeLedger(dir, 2, [], "automate science", ["automation"]);
    fs.writeFileSync(path.join(dir, "package-queue.json"), JSON.stringify({ packages: {},
      research: { revision: 2, status: "queued", technologies: ["automation"], queued: ["automation"], at: "2026-10-04T00:00:00Z", tick: 1000 } }));
    const { call, bridge } = fakeBridge({ start_research: () => ({ queued: true, technologies: ["automation"] }) });
    await createPackageQueue(() => dir, bridge).tick();
    expect(call).toHaveBeenCalledWith("start_research", { technologies: ["automation"], origin: "ledger/r2" });
    expect(readPackageQueue(dir)?.research).toMatchObject({ revision: 2, tick: 900 });
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

describe("package verify", () => {
  const verify = [{ item: "iron-plate", per_min_at_least: 30 }, { line_at: { x: 1.5, y: 2.5 }, state: "running" }];
  /** A game whose clock and plan end the test sets; factory_status answers the measure. */
  function game(measured: unknown[], overrides: Record<string, (params: any) => unknown> = {}) {
    const clock = { tick: 900, plan: "running", finished: undefined as number | undefined, source: "package:iron-a" };
    const fake = fakeBridge({
      ping: () => ({ companion_exists: true, tick: clock.tick, body: { state: "on_surface", surface_ref: "nauvis" } }),
      event_state: () => ({ tick: clock.tick, queue_depth: 0, fifo_empty: true, human_hold: false }),
      plan_status: (params) => ({ plan_id: params.plan_id, status: clock.plan, source: clock.source, finished_tick: clock.finished }),
      factory_status: () => ({ tick: clock.tick, measured }),
      ...overrides,
    });
    return { ...fake, clock };
  }
  const measures = (call: ReturnType<typeof fakeBridge>["call"]) =>
    call.mock.calls.filter(([method]) => method === "factory_status").map(([, params]) => params);

  it("measures once, two minutes of game time after the plan ended, and reports package_verified", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [{ ...furnaces("iron-a"), verify }]);
    const { call, bridge, clock } = game([{ per_min: 31.5, met: true },
      { line_id: 4, product: "iron-plate", state: "running", rate_per_min: 31.5, machines: 2, working: 2, met: true }]);
    let ms = 0;
    const queue = createPackageQueue(() => dir, bridge, () => new Date(Date.UTC(2026, 9, 8) + ms));
    await queue.tick();
    expect(readPackageQueue(dir)?.packages["iron-a"]).toMatchObject({ status: "queued", verify, surface: "nauvis" });
    // Still running: nothing measured.
    ms += 20_000; clock.tick = 3000;
    await queue.tick();
    expect(measures(call)).toEqual([]);
    clock.plan = "completed"; clock.finished = 3100; ms += 20_000; clock.tick = 3200;
    await queue.tick();
    expect(readPackageQueue(dir)?.packages["iron-a"]).toMatchObject({ plan_ended_tick: 3100, plan_status: "completed" });
    clock.tick = 3100 + 7199; ms += 1_000;
    await queue.tick();
    expect(measures(call)).toEqual([]);
    clock.tick = 3100 + 7200; ms += 1_000;
    await queue.tick();
    expect(measures(call)).toEqual([{ sections: [], surface: "nauvis", measure: verify }]);
    const record = readPackageQueue(dir)?.packages["iron-a"];
    expect(record?.verification).toMatchObject({ status: "verified", tick: 10300, metrics: [
      { item: "iron-plate", per_min_at_least: 30, measured: { per_min: 31.5 }, met: true },
      { line_at: { x: 1.5, y: 2.5 }, state: "running", measured: { line_id: 4, state: "running", rate_per_min: 31.5 }, met: true }] });
    expect(packageVerifications(dir)).toEqual([expect.objectContaining({ event: "package_verified", package_id: "iron-a",
      plan_status: "completed", tick: 10300 })]);
    // Measured once: a later pass, even after the ledger drops the package, measures nothing more.
    writeLedger(dir, 2, []);
    clock.tick = 20000; ms += 1_000;
    await queue.tick();
    expect(measures(call)).toHaveLength(1);
    // Nothing is queued again.
    expect(queuedPlans(call)).toHaveLength(1);
  });

  it("reports package_unmet with the measured values when one metric falls short", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [{ ...furnaces("iron-a"), verify }]);
    const { bridge, clock } = game([{ per_min: 12, met: false }, { error: "NO_LINE", met: false }]);
    let ms = 0;
    const queue = createPackageQueue(() => dir, bridge, () => new Date(Date.UTC(2026, 9, 8) + ms));
    await queue.tick();
    clock.plan = "failed"; clock.finished = 1000; clock.tick = 1000 + 7200; ms += 20_000;
    await queue.tick();
    await queue.tick();
    expect(packageVerifications(dir)).toEqual([expect.objectContaining({ event: "package_unmet", plan_status: "failed",
      metrics: [expect.objectContaining({ measured: { per_min: 12 }, met: false }),
        expect.objectContaining({ measured: { error: "NO_LINE" }, met: false })] })]);
  });

  it("records unmet with the reason once the mod refused the measurement five minutes past due", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [{ ...furnaces("iron-a"), verify }]);
    const { call, bridge, clock } = game([], { factory_status: () => { throw new ModError("surface vulcan is not charted"); } });
    let ms = 0;
    const queue = createPackageQueue(() => dir, bridge, () => new Date(Date.UTC(2026, 9, 8) + ms));
    await queue.tick();
    clock.plan = "completed"; clock.finished = 1000; clock.tick = 1000 + 7200; ms += 20_000;
    await queue.tick();
    clock.tick = 1000 + 7200 + 17_999;
    await queue.tick();
    expect(measures(call)).toHaveLength(2);
    expect(readPackageQueue(dir)?.packages["iron-a"]).not.toHaveProperty("verification");
    clock.tick = 1000 + 7200 + 18_000;
    await queue.tick();
    expect(readPackageQueue(dir)?.packages["iron-a"]?.verification).toMatchObject({ status: "unmet", metrics: [],
      reason: expect.stringContaining("surface vulcan is not charted"), tick: 26200 });
    expect(packageVerifications(dir)).toEqual([expect.objectContaining({ event: "package_unmet" })]);
  });

  it("dates the end of a plan the mod no longer knows to when that was seen", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [{ ...furnaces("iron-a"), verify }]);
    let pruned = false;
    const { call, bridge, clock } = game([{ per_min: 31, met: true }, { state: "running", met: true }], {
      plan_status: (params) => {
        if (pruned) throw new ModError(`unknown plan_id ${params.plan_id}`);
        return { plan_id: params.plan_id, status: "running", source: "package:iron-a" };
      },
    });
    let ms = 0;
    const queue = createPackageQueue(() => dir, bridge, () => new Date(Date.UTC(2026, 9, 8) + ms));
    await queue.tick();
    pruned = true; clock.tick = 2000; ms += 20_000;
    await queue.tick();
    const record = readPackageQueue(dir)?.packages["iron-a"];
    expect(record).toMatchObject({ plan_ended_tick: 2000 });
    expect(record).not.toHaveProperty("plan_status");
    clock.tick = 2000 + 7200;
    await queue.tick();
    expect(measures(call)).toHaveLength(1);
    expect(readPackageQueue(dir)?.packages["iron-a"]?.verification).toMatchObject({ status: "verified", tick: 9200 });
  });

  it("ignores an ended plan whose source is another's, and measures nothing for it", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [{ ...furnaces("iron-a"), verify }]);
    const { call, bridge, clock } = game([{ per_min: 31, met: true }, { state: "running", met: true }]);
    let ms = 0;
    const queue = createPackageQueue(() => dir, bridge, () => new Date(Date.UTC(2026, 9, 8) + ms));
    await queue.tick();
    clock.plan = "completed"; clock.finished = 1000; clock.source = "pilot"; clock.tick = 1000 + 9000; ms += 20_000;
    await queue.tick();
    expect(call.mock.calls.filter(([method]) => method === "plan_status").length).toBeGreaterThan(0);
    expect(readPackageQueue(dir)?.packages["iron-a"]).not.toHaveProperty("plan_ended_tick");
    expect(measures(call)).toEqual([]);
  });

  it("takes a plan end and measurement from a rolled-back save line again", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [{ ...furnaces("iron-a"), verify }]);
    // Queued before the restored save's tick; its end and measurement came after it.
    fs.writeFileSync(path.join(dir, "package-queue.json"), JSON.stringify({ packages: {
      "iron-a": { status: "queued", plan_id: 57, revision: 1, at: "2026-10-04T00:00:00Z", tick: 300, verify, surface: "nauvis",
        plan_ended_tick: 5000, plan_status: "completed",
        verification: { status: "unmet", tick: 12200, at: "2026-10-04T00:10:00Z", metrics: [] } } } }));
    const { call, bridge, clock } = game([{ per_min: 31, met: true }, { state: "running", met: true }]);
    clock.tick = 4000;
    let ms = 0;
    const queue = createPackageQueue(() => dir, bridge, () => new Date(Date.UTC(2026, 9, 8) + ms));
    await queue.tick();
    const record = readPackageQueue(dir)?.packages["iron-a"];
    expect(record).toMatchObject({ status: "queued", plan_id: 57, tick: 300 });
    for (const field of ["plan_ended_tick", "plan_status", "verification"]) expect(record).not.toHaveProperty(field);
    expect(packageVerifications(dir)).toEqual([]);
    // The plan runs again here; it is measured two minutes after this end.
    clock.plan = "completed"; clock.finished = 6000; clock.tick = 6100; ms += 20_000;
    await queue.tick();
    expect(readPackageQueue(dir)?.packages["iron-a"]).toMatchObject({ plan_ended_tick: 6000 });
    expect(measures(call)).toEqual([]);
    clock.tick = 6000 + 7200;
    await queue.tick();
    expect(packageVerifications(dir)).toEqual([expect.objectContaining({ event: "package_verified", tick: 13200 })]);
    expect(queuedPlans(call)).toEqual([]);
  });

  it("keeps a package without verify free of measurement", async () => {
    const dir = runDir();
    writeLedger(dir, 1, [furnaces("iron-a")]);
    const { call, bridge, clock } = game([]);
    const queue = createPackageQueue(() => dir, bridge);
    await queue.tick();
    clock.plan = "completed"; clock.finished = 900; clock.tick = 900 + 8000;
    await queue.tick();
    expect(measures(call)).toEqual([]);
    expect(readPackageQueue(dir)?.packages["iron-a"]).not.toHaveProperty("verify");
    expect(packageVerifications(dir)).toEqual([]);
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

// Exercise the actual runtime startup and timer, not a separately exported
// policy predicate. No connection, live bridge, ledger or listeners are used.
describe("MCP package pump ownership", () => {
  it.each([
    ["full", "pilot", true], ["full", "supervisor", false],
    ["read-only", "strategist", false], ["read-only", "advisor", false], ["full", "unknown", false],
    ["read-only", "pilot", false],
  ] as [McpSurface, SessionRole, boolean][])("%s/%s starts package pumping: %s", async (surface, role, enabled) => {
    vi.useFakeTimers();
    vi.spyOn(McpServer.prototype, "connect").mockResolvedValue();
    const tick = vi.fn(async () => undefined);
    const queue = vi.spyOn(coordination, "createPackageQueue").mockReturnValue({ tick });
    await runMcpServer(surface, undefined, role);
    await vi.advanceTimersByTimeAsync(3_000);
    expect(queue).toHaveBeenCalledTimes(enabled ? 1 : 0);
    expect(tick).toHaveBeenCalledTimes(enabled ? 3 : 0);
  });

  it("leaves a default unlabelled full-surface session without a package pump", async () => {
    vi.useFakeTimers();
    vi.spyOn(McpServer.prototype, "connect").mockResolvedValue();
    const tick = vi.fn(async () => undefined);
    const queue = vi.spyOn(coordination, "createPackageQueue").mockReturnValue({ tick });
    await runMcpServer();
    await vi.advanceTimersByTimeAsync(3_000);
    expect(queue).not.toHaveBeenCalled();
    expect(tick).not.toHaveBeenCalled();
  });
});
