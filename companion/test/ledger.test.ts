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
        strategist: { model: "gpt-6.1-sol" as const, reasoning: "medium" as const, fast: false as const } } },
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
  };
}

function envelope(sourceTick = 100) {
  const current = ledger();
  return { run_id: current.run.id, save_identity: current.run.save_identity, source_tick: sourceTick,
    update: { phase: current.phase, bottleneck: current.bottleneck,
      latest_measured_capacity: current.latest_measured_capacity, task_list: current.task_list,
      assumptions: current.assumptions, pilot_plan_ids: current.pilot_plan_ids } };
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
    expect(reduceLedger(ledger(), report).result).toEqual({ status: "discarded", reason });
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
      expect(applyLedgerFile(file, report)).toEqual({ status: "discarded", reason });
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
    expect(applyLedgerFile(file, report)).toEqual({ status: "discarded", reason: "MALFORMED_REPORT" });
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
