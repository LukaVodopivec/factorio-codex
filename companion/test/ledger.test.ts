import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { applyLedgerFile, operationsLedgerSchema, reduceLedger } from "../src/coordination/ledger.js";

const temporary: string[] = [];
afterEach(() => temporary.splice(0).forEach((dir) => fs.rmSync(dir, { recursive: true, force: true })));

function ledger() {
  return {
    schema_version: 2 as const,
    run: { id: "run-1", release_sha: "a".repeat(40), baseline_save_sha256: "b".repeat(64),
      save_identity: "fresh-space-age", created_at: "2026-09-03T20:00:00Z",
      roles: { pilot: { model: "gpt-5.6-luna" as const, reasoning: "high" as const, fast: true as const },
        strategist: { model: "gpt-5.6-sol" as const, reasoning: "high" as const } } },
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
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-ledger-")); temporary.push(dir);
    const file = path.join(dir, "operations.json");
    fs.writeFileSync(file, `${JSON.stringify(ledger())}\n`, { mode: 0o600 });
    expect(applyLedgerFile(file, envelope())).toEqual({ status: "applied", revision: 1, source_tick: 100 });
    expect(fs.statSync(file).mode & 0o777).toBe(0o600);
    expect(JSON.parse(fs.readFileSync(file, "utf8"))).toMatchObject({ revision: 1, source_tick: 100,
      run: { id: "run-1", roles: ledger().run.roles } });
  });
});
