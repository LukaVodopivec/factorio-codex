import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { applyLedgerFile, operationsLedgerSchema, reduceLedger } from "../src/coordination/ledger.js";

const temporary: string[] = [];
afterEach(() => {
  vi.restoreAllMocks();
  temporary.splice(0).forEach((dir) => fs.rmSync(dir, { recursive: true, force: true }));
});

function ledgerFile() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-ledger-")); temporary.push(dir);
  return path.join(dir, "operations.json");
}

function ledger() {
  return {
    schema_version: 2 as const,
    run: { id: "run-1", release_sha: "a".repeat(40), baseline_save_sha256: "b".repeat(64),
      save_identity: "fresh-space-age", created_at: "2026-09-03T20:00:00Z",
      roles: { pilot: { model: "gpt-6-luna" as const, reasoning: "low" as const, fast: true as const },
        strategist: { model: "gpt-6-astra" as const, reasoning: "medium" as const, fast: false as const } } },
    revision: 0, source_tick: null,
    phase: "bootstrap", bottleneck: "sustained power",
    latest_measured_capacity: [],
    task_list: {
      NOW: { objective: "establish stable power", strategic_reason: "removes recurring outages",
        completion_condition: "accepted output remains powered for the validation interval", essential_prerequisite: null },
      NEXT: { objective: "expand the measured processing bottleneck", strategic_reason: "raises sustained throughput",
        completion_condition: "downstream accepted rate increases", essential_prerequisite: "stable power" },
      LATER: { objective: "establish orbital logistics", strategic_reason: "opens interplanetary capacity",
        completion_condition: "a functional platform sustains ordinary operation", essential_prerequisite: "rocket capacity" },
    },
    assumptions: [],
    pilot_plan_ids: { current_plan_id: null, queued_successor_plan_id: null, predecessor_plan_id: null },
    build_packages: [] as unknown[],
  };
}

function envelope(sourceTick = 100) {
  const current = ledger();
  return { run_id: current.run.id, save_identity: current.run.save_identity, source_tick: sourceTick,
    update: { phase: current.phase, bottleneck: current.bottleneck,
      latest_measured_capacity: current.latest_measured_capacity, task_list: current.task_list,
      assumptions: current.assumptions, pilot_plan_ids: current.pilot_plan_ids, build_packages: [] as unknown[] } };
}

function initialization(sourceTick: number | null = 100) {
  return { init: true, run: ledger().run, source_tick: sourceTick, update: envelope().update };
}

describe("compact strategist operations ledger", () => {
  it("accepts a valid newer material report and advances the mirror exactly once", () => {
    const reduced = reduceLedger(ledger(), envelope());
    expect(reduced.result).toEqual({ status: "applied", revision: 1, source_tick: 100 });
    expect(operationsLedgerSchema.parse(reduced.ledger).task_list.NOW.objective).toBe("establish stable power");
  });

  it.each([
    ["malformed", {}, "MALFORMED_REPORT"],
    ["wrong run", { ...envelope(), run_id: "other" }, "WRONG_RUN"],
    ["wrong save", { ...envelope(), save_identity: "other" }, "WRONG_SAVE"],
  ])("discards %s evidence without changing the ledger", (_label, report, reason) => {
    expect(reduceLedger(ledger(), report).result).toMatchObject({ status: "discarded", reason });
  });

  it("discards duplicate and stale reports without blocking the pilot", () => {
    const existing = { ...ledger(), source_tick: 100, revision: 4 };
    expect(reduceLedger(existing, envelope(100)).result).toEqual({ status: "discarded", reason: "DUPLICATE_REPORT" });
    expect(reduceLedger(existing, envelope(99)).result).toEqual({ status: "discarded", reason: "STALE_REPORT" });
  });

  it("writes atomically with mode 0600 and preserves immutable run identity", () => {
    const file = ledgerFile();
    fs.writeFileSync(file, `${JSON.stringify(ledger())}\n`, { mode: 0o600 });
    expect(applyLedgerFile(file, envelope())).toEqual({ status: "applied", revision: 1, source_tick: 100 });
    expect(fs.statSync(file).mode & 0o777).toBe(0o600);
    expect(JSON.parse(fs.readFileSync(file, "utf8"))).toMatchObject({ revision: 1, source_tick: 100,
      run: { id: "run-1", roles: ledger().run.roles } });
  });

  it("initializes schema v2 directly at revision 1 and accepts subsequent updates", () => {
    const file = ledgerFile();
    expect(applyLedgerFile(file, initialization())).toEqual({ status: "applied", revision: 1, source_tick: 100 });
    const expected = { ...ledger(), revision: 1, source_tick: 100 };
    expect(JSON.parse(fs.readFileSync(file, "utf8"))).toEqual(expected);
    expect(fs.statSync(file).mode & 0o7777).toBe(0o600);
    for (const [report, reason] of [
      [envelope(100), "DUPLICATE_REPORT"], [envelope(99), "STALE_REPORT"],
      [{ ...envelope(101), run_id: "other" }, "WRONG_RUN"],
      [{ ...envelope(101), save_identity: "other" }, "WRONG_SAVE"],
      [{ ...envelope(101), update: {} }, "MALFORMED_REPORT"],
    ] as const) {
      expect(applyLedgerFile(file, report)).toMatchObject({ status: "discarded", reason });
      expect(JSON.parse(fs.readFileSync(file, "utf8"))).toEqual(expected);
    }
    expect(applyLedgerFile(file, { ...envelope(101), update: { ...envelope().update, phase: "growth" } }))
      .toEqual({ status: "applied", revision: 2, source_tick: 101 });
    expect(JSON.parse(fs.readFileSync(file, "utf8"))).toEqual({ ...expected, revision: 2, source_tick: 101, phase: "growth" });
  });

  it.each([
    { ...initialization(), run: { ...ledger().run, release_sha: "invalid" } },
    { ...initialization(), run: { ...ledger().run, roles: {} } },
    { ...initialization(), init: false },
    { ...initialization(), source_tick: -1 },
    { ...initialization(), update: {} },
    { ...initialization(), run_id: "run-1", save_identity: "fresh-space-age" },
  ])("rejects invalid or ambiguous initialization without creating a file", (report) => {
    const file = ledgerFile();
    expect(applyLedgerFile(file, report)).toMatchObject({ status: "discarded", reason: "MALFORMED_REPORT" });
    expect(fs.existsSync(file)).toBe(false);
    expect(fs.readdirSync(path.dirname(file))).toEqual([]);
  });

  it.each([
    [JSON.stringify(ledger()), 0o600], ["{broken", 0o600],
    [JSON.stringify({ ...ledger(), schema_version: 99 }), 0o600], [JSON.stringify(ledger()), 0o644],
  ])("never replaces an existing destination or its mode", (contents, mode) => {
    const file = ledgerFile();
    fs.writeFileSync(file, contents); fs.chmodSync(file, mode);
    expect(applyLedgerFile(file, initialization())).toEqual({ status: "discarded", reason: "LEDGER_ALREADY_EXISTS" });
    expect(fs.readFileSync(file, "utf8")).toBe(contents);
    expect(fs.statSync(file).mode & 0o7777).toBe(mode);
  });

  it("does not initialize for an ordinary update against a missing file", () => {
    const file = ledgerFile();
    expect(applyLedgerFile(file, envelope())).toEqual({ status: "discarded", reason: "MISSING_LEDGER" });
    expect(fs.existsSync(file)).toBe(false);
  });

  it("retains explicit null source ticks for pre-observation initialization", () => {
    const file = ledgerFile();
    expect(applyLedgerFile(file, initialization(null))).toEqual({ status: "applied", revision: 1, source_tick: null });
    expect(applyLedgerFile(file, envelope(0))).toEqual({ status: "applied", revision: 2, source_tick: 0 });
  });

  it("does not clobber a destination created after the absence check", () => {
    const file = ledgerFile();
    const contents = "concurrent ledger";
    vi.spyOn(fs, "lstatSync").mockImplementationOnce(() => {
      fs.writeFileSync(file, contents, { mode: 0o644 });
      fs.chmodSync(file, 0o644);
      throw Object.assign(new Error("absent when checked"), { code: "ENOENT" });
    });
    expect(applyLedgerFile(file, initialization())).toEqual({ status: "discarded", reason: "LEDGER_ALREADY_EXISTS" });
    expect(fs.readFileSync(file, "utf8")).toBe(contents);
    expect(fs.statSync(file).mode & 0o7777).toBe(0o644);
    expect(fs.readdirSync(path.dirname(file))).toEqual(["operations.json"]);
  });

  it("rejects existing directories and dangling symlinks as initialization destinations", () => {
    const file = ledgerFile();
    fs.mkdirSync(file);
    expect(applyLedgerFile(file, initialization())).toEqual({ status: "discarded", reason: "LEDGER_ALREADY_EXISTS" });
    expect(fs.lstatSync(file).isDirectory()).toBe(true);
    fs.rmdirSync(file);
    fs.symlinkSync("absent.json", file);
    expect(applyLedgerFile(file, initialization())).toEqual({ status: "discarded", reason: "LEDGER_ALREADY_EXISTS" });
    expect(fs.readlinkSync(file)).toBe("absent.json");
  });

  it("does not treat destination lookup or read failures as absence", () => {
    const file = ledgerFile();
    const lookup = vi.spyOn(fs, "lstatSync").mockImplementationOnce(() => {
      throw Object.assign(new Error("denied"), { code: "EACCES" });
    });
    expect(applyLedgerFile(file, initialization())).toEqual({ status: "discarded", reason: "LEDGER_READ_FAILED" });
    lookup.mockRestore();
    expect(fs.existsSync(file)).toBe(false);
    const contents = JSON.stringify(ledger());
    fs.writeFileSync(file, contents, { mode: 0o600 });
    const read = vi.spyOn(fs, "readFileSync").mockImplementationOnce(() => {
      throw Object.assign(new Error("removed after lookup"), { code: "ENOENT" });
    });
    expect(applyLedgerFile(file, envelope())).toEqual({ status: "discarded", reason: "LEDGER_READ_FAILED" });
    read.mockRestore();
    expect(fs.readFileSync(file, "utf8")).toBe(contents);
  });

  it.each([
    ["{broken", 0o600, "MALFORMED_OR_UNSUPPORTED_LEDGER"],
    [JSON.stringify({ ...ledger(), schema_version: 99 }), 0o600, "MALFORMED_OR_UNSUPPORTED_LEDGER"],
    [JSON.stringify(ledger()), 0o644, "UNSAFE_LEDGER_MODE"],
  ])("preserves rejected existing ledgers on ordinary updates", (contents, mode, reason) => {
    const file = ledgerFile();
    fs.writeFileSync(file, contents); fs.chmodSync(file, mode);
    expect(applyLedgerFile(file, envelope())).toEqual({ status: "discarded", reason });
    expect(fs.readFileSync(file, "utf8")).toBe(contents);
    expect(fs.statSync(file).mode & 0o7777).toBe(mode);
  });

  it.each([
    { run: { ...ledger().run, id: "other" } }, { revision: 2 }, { source_tick: 101 }, { phase: "other" },
  ])("does not report success when persisted content differs", (changed) => {
    const file = ledgerFile();
    vi.spyOn(fs, "readFileSync").mockReturnValueOnce(JSON.stringify({ ...ledger(), revision: 1, source_tick: 100, ...changed }));
    expect(() => applyLedgerFile(file, initialization())).toThrow("ledger atomic write verification failed");
  });

  it("does not report success when readback permissions are unsafe", () => {
    const file = ledgerFile();
    const link = fs.linkSync;
    vi.spyOn(fs, "linkSync").mockImplementationOnce((source, target) => {
      link(source, target);
      fs.chmodSync(target, 0o644);
    });
    expect(() => applyLedgerFile(file, initialization())).toThrow("ledger atomic write verification failed");
  });
});

describe("validated build packages", () => {
  const drillPair = (id = "coal-drill-furnace", tick = 100) => ({
    package_id: id, serves: "NOW" as const, intent: "burner drill feeding a stone furnace on the nearest iron patch",
    after_package_id: null, source_tick: tick, anchor: { x: 40, y: -30 },
    required_items: { "burner-mining-drill": 1, "stone-furnace": 1, coal: 10 },
    steps: [
      { action: "place_entity", x: 45, y: -30, name: "stone-furnace", direction: 0 },
      { action: "place_entity", x: 45, y: -32, name: "burner-mining-drill", direction: 8, output_target: { x: 45, y: -30 } },
      { action: "insert_items", x: 45, y: -32, items: { coal: 5 } },
    ],
    validated_place_steps: [0, 1], success_check: "furnace receives ore from the drill without a character transfer",
  });
  const withPackages = (packages: unknown[], tick = 101) => ({ ...envelope(tick), update: { ...envelope(tick).update, build_packages: packages } });

  it("stores up to two validated packages and keeps old ledgers without the field valid", () => {
    const second = { ...drillPair("fuel-loop"), serves: "NEXT" as const, after_package_id: "coal-drill-furnace" };
    const reduced = reduceLedger(ledger(), withPackages([drillPair(), second]));
    expect(reduced.result).toMatchObject({ status: "applied", revision: 1 });
    expect(reduced.ledger?.build_packages.map((entry) => entry.package_id)).toEqual(["coal-drill-furnace", "fuel-loop"]);
    const { build_packages: _omitted, ...older } = ledger();
    expect(reduceLedger(older, envelope(101)).result).toMatchObject({ status: "applied" });
  });

  it("accepts a segment package that ends by waiting for output and validating the component", () => {
    const validated = { ...drillPair(), steps: [...drillPair().steps,
      { action: "wait_for_item", x: 45, y: -30, inventory: "output", item: "iron-plate", count: 2, timeout_seconds: 120 },
      { action: "validate_factory_component", source_tick: 100, positions: [{ x: 45, y: -30 }], duration_seconds: 60 }] };
    expect(reduceLedger(ledger(), withPackages([validated])).result).toMatchObject({ status: "applied", revision: 1 });
  });

  it("accepts a package that empties and removes one owned entity it supersedes", () => {
    const removal = { ...drillPair(), steps: [...drillPair().steps,
      { action: "extract_items", x: 48, y: -30, items: { "iron-plate": 10 } },
      { action: "mine", x: 48, y: -30, target_kind: "owned", expected_name: "wooden-chest" }] };
    const reduced = reduceLedger(ledger(), withPackages([removal]));
    expect(reduced.result).toMatchObject({ status: "applied", revision: 1 });
    expect(reduced.ledger?.build_packages[0].steps.at(-1)).toMatchObject({ action: "mine", count: 1, allow_fluid_loss: false });
  });

  it("rejects package removals that are not one guarded owned entity, or that it places on", () => {
    const mine = { action: "mine", x: 48, y: -30, target_kind: "owned", expected_name: "wooden-chest" };
    const removal = (step: Record<string, unknown>) => ({ ...drillPair(), steps: [step], validated_place_steps: [] });
    const { target_kind: _kind, ...untargeted } = mine;
    const { expected_name: _name, ...unnamed } = mine;
    for (const step of [untargeted, { ...mine, target_kind: "natural" }, unnamed, { ...mine, count: 2 }, { ...mine, allow_fluid_loss: true }]) {
      const result = reduceLedger(ledger(), withPackages([removal(step)])).result;
      expect(result).toMatchObject({ status: "discarded", reason: "MALFORMED_REPORT" });
      expect(result.status === "discarded" && result.issues?.some((issue) => issue.includes("build_packages.0.steps.0")
        && issue.includes("one owned entity"))).toBe(true);
    }
    const replaced = { ...drillPair(), steps: [{ ...mine, x: 45, y: -30, expected_name: "wooden-chest" }, ...drillPair().steps],
      validated_place_steps: [1, 2] };
    const result = reduceLedger(ledger(), withPackages([replaced])).result;
    expect(result).toMatchObject({ status: "discarded", reason: "MALFORMED_REPORT" });
    expect(result.status === "discarded" && result.issues?.some((issue) => issue.includes("build_packages.0.steps.1")
      && issue.includes("own mine step"))).toBe(true);
  });

  it("rejects packages it could not execute as written, with the offending path", () => {
    const cases: Array<[unknown[], string]> = [
      [[drillPair("a"), drillPair("b"), drillPair("c")], "build_packages"],
      [[drillPair("a", 500)], "build_packages.0.source_tick"],
      [[{ ...drillPair(), steps: [{ action: "walk_to", x: 1, y: 2 }] }], "build_packages.0.steps.0"],
      [[{ ...drillPair(), validated_place_steps: [0] }], "build_packages.0.steps.1"],
      [[{ ...drillPair(), validated_place_steps: [0, 1, 2] }], "build_packages.0.validated_place_steps"],
      [[{ ...drillPair("a"), after_package_id: "a" }], "build_packages.0.after_package_id"],
      [[{ ...drillPair("a"), after_package_id: "b" }, { ...drillPair("b"), after_package_id: "a" }], "depend on themselves or on each other"],
      [[{ ...drillPair(), steps: [{ action: "craft_items", recipe: "stone-furnace", crafts: 1 }], validated_place_steps: [] }], "build_packages.0.steps.0"],
      [[drillPair("same"), drillPair("same")], "package ids must be unique"],
      [[{ ...drillPair(), intent: "x".repeat(240), success_check: "y".repeat(240), steps: Array.from({ length: 25 }, (_, i) =>
        ({ action: "insert_items", x: i, y: i, items: Object.fromEntries(Array.from({ length: 8 }, (_, j) => [`item-${j}-${"z".repeat(20)}`, 1])) })),
        validated_place_steps: [] }], "bytes"],
    ];
    for (const [packages, path] of cases) {
      const result = reduceLedger(ledger(), withPackages(packages)).result;
      expect(result).toMatchObject({ status: "discarded", reason: "MALFORMED_REPORT" });
      expect(result.status === "discarded" && result.issues?.some((issue) => issue.includes(path))).toBe(true);
    }
  });

  it("accepts a successor of an already-queued package and requires every update to restate packages", () => {
    const successor = { ...drillPair("fuel-loop"), after_package_id: "coal-drill-furnace" };
    expect(reduceLedger(ledger(), withPackages([successor])).result).toMatchObject({ status: "applied" });
    const { build_packages: _omitted, ...update } = envelope(101).update;
    const result = reduceLedger(ledger(), { ...envelope(101), update }).result;
    expect(result).toMatchObject({ status: "discarded", reason: "MALFORMED_REPORT" });
    expect(result.status === "discarded" && result.issues?.some((issue) => issue.includes("update.build_packages"))).toBe(true);
  });

  it("stores negative zero as JSON does without failing the readback", () => {
    const file = ledgerFile();
    expect(applyLedgerFile(file, initialization())).toMatchObject({ status: "applied", revision: 1 });
    const zero = { ...drillPair(), anchor: { x: -0, y: 0 }, source_tick: 100 };
    expect(applyLedgerFile(file, withPackages([zero]))).toMatchObject({ status: "applied", revision: 2 });
  });

  it("keeps essential_prerequisite to one short outcome sentence", () => {
    const update = envelope(101).update;
    const long = { ...envelope(101), update: { ...update, task_list: { ...update.task_list,
      NOW: { ...update.task_list.NOW, essential_prerequisite: "x".repeat(161) } } } };
    const result = reduceLedger(ledger(), long).result;
    expect(result).toMatchObject({ status: "discarded", reason: "MALFORMED_REPORT" });
    expect(result.status === "discarded" && result.issues?.some((issue) =>
      issue.includes("update.task_list.NOW.essential_prerequisite") && issue.includes("one outcome sentence"))).toBe(true);
  });

  it("lets a package name up to three existing notebook notes beside the ledger", () => {
    const file = ledgerFile();
    expect(applyLedgerFile(file, initialization())).toMatchObject({ status: "applied", revision: 1 });
    const notebook = path.join(path.dirname(file), "notebook");
    fs.mkdirSync(path.join(notebook, "templates"), { recursive: true });
    for (const note of ["README.md", "fuel-loop.md", "templates/smelter.md"]) fs.writeFileSync(path.join(notebook, note), "# note\n");
    const notes = ["notebook/fuel-loop.md", "notebook/templates/smelter.md", "notebook/README.md"];
    expect(applyLedgerFile(file, withPackages([{ ...drillPair(), notes }]))).toMatchObject({ status: "applied", revision: 2 });
    expect(JSON.parse(fs.readFileSync(file, "utf8")).build_packages[0].notes).toEqual(notes);
  });

  it.each([
    [["/tmp/notebook/a.md"], "build_packages.0.notes.0"],
    [["notebook/../operations.md"], "build_packages.0.notes.0"],
    [["notebook/a.txt"], "build_packages.0.notes.0"],
    [["notes/a.md"], "build_packages.0.notes.0"],
    [["notebook/.hidden.md"], "build_packages.0.notes.0"],
    [["notebook/a.md", "notebook/b.md", "notebook/c.md", "notebook/d.md"], "build_packages.0.notes"],
  ])("rejects package notes %j outside the bounded notebook shape", (notes, issuePath) => {
    const result = reduceLedger(ledger(), withPackages([{ ...drillPair(), notes }])).result;
    expect(result).toMatchObject({ status: "discarded", reason: "MALFORMED_REPORT" });
    expect(result.status === "discarded" && result.issues?.some((issue) => issue.includes(issuePath))).toBe(true);
  });

  it("rejects a package note that does not exist without changing the ledger", () => {
    const file = ledgerFile();
    expect(applyLedgerFile(file, initialization())).toMatchObject({ status: "applied", revision: 1 });
    const before = fs.readFileSync(file, "utf8");
    const result = applyLedgerFile(file, withPackages([{ ...drillPair(), notes: ["notebook/absent.md"] }]));
    expect(result).toMatchObject({ status: "discarded", reason: "MALFORMED_REPORT",
      issues: ["build_packages.0.notes.0: notebook/absent.md is not a file beside the ledger"] });
    expect(fs.readFileSync(file, "utf8")).toBe(before);
  });

  it("rejects an invalid package at initialization without creating the ledger", () => {
    const file = ledgerFile();
    const init = { ...initialization(), update: { ...initialization().update, build_packages: [drillPair("a", 500)] } };
    expect(applyLedgerFile(file, init)).toMatchObject({ status: "discarded", reason: "MALFORMED_REPORT" });
    expect(fs.existsSync(file)).toBe(false);
  });
});
