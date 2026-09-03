import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { applyLedgerFile, reduceLedger } from "../src/coordination/ledger.js";

const dirs: string[] = [];
afterEach(() => dirs.splice(0).forEach((dir) => fs.rmSync(dir, { recursive: true, force: true })));

const run = {
  id: "run-1", release_sha: "a".repeat(40), baseline_save_sha256: "b".repeat(64),
  save_identity: "save-1", created_at: "2026-09-03T00:00:00Z",
  roles: { strategist: "sol-medium", pilot: "terra-low" },
};

const ledger = () => ({
  schema_version: 1, run, revision: 4, source_tick: 64748,
  phase: "bootstrap", success: false, capacity: {}, utilization: {}, bottleneck: "fuel",
  current_plan: { plan_id: 4 }, queued_successor: null, fallbacks: [],
  current_bom: {}, next_bom: {}, latest_observation: { source_tick: 64748 }, decisions: [],
  strategy_proposal: null, invalidations: [], outcome: {},
});

const envelope = (overrides: Record<string, unknown> = {}) => ({
  run_id: "run-1", save_identity: "save-1", source_tick: 500000,
  mirror: {
    phase: "automation", success: false,
    capacity: { mining: 2, smelting: 1 }, utilization: { smelting: 0.8 },
    bottleneck: "ore transfer", current_plan: { plan_id: 5 },
    queued_successor: { plan_id: 6, after_plan_id: 5, status: "queued" },
    fallbacks: ["fuel reserve"], current_bom: { gear: 10 }, next_bom: { science: 20 },
    latest_observation: { source_tick: 500000, technologies: ["automation", "steel-processing"] },
    decisions: ["preserve working steam"], invalidations: [],
    outcome: { interventions: ["bridge pole"] },
  },
  strategy_proposal: { proposal_id: "proposal-5", source_tick: 500000 },
  ...overrides,
});

describe("strategist ledger reducer", () => {
  it("applies a valid newer material mirror and preserves immutable run data", () => {
    const reduced = reduceLedger(ledger(), envelope());
    expect(reduced.result).toEqual({ status: "applied", revision: 5, source_tick: 500000 });
    expect(reduced.ledger?.run).toEqual(run);
    expect(reduced.ledger).toMatchObject({
      revision: 5, source_tick: 500000, phase: "automation", bottleneck: "ore transfer",
      capacity: { mining: 2, smelting: 1 }, outcome: { interventions: ["bridge pole"] },
    });
  });

  it.each([
    ["duplicate", envelope({ source_tick: 64748, mirror: { ...envelope().mirror, latest_observation: { source_tick: 64748 } } }), "DUPLICATE_REPORT"],
    ["stale", envelope({ source_tick: 10, mirror: { ...envelope().mirror, latest_observation: { source_tick: 10 } } }), "STALE_REPORT"],
    ["wrong run", envelope({ run_id: "other" }), "WRONG_RUN"],
    ["wrong save", envelope({ save_identity: "other" }), "WRONG_SAVE"],
    ["wrong observation tick", envelope({ mirror: { ...envelope().mirror, latest_observation: { source_tick: 9 } } }), "OBSERVATION_TICK_MISMATCH"],
    ["unconfirmed successor", envelope({ mirror: { ...envelope().mirror, queued_successor: { plan_id: 6, after_plan_id: 4, status: "waiting" } } }), "UNCONFIRMED_SUCCESSOR"],
    ["malformed successor", envelope({ mirror: { ...envelope().mirror, queued_successor: "plan-6" } }), "UNCONFIRMED_SUCCESSOR"],
  ])("discards %s without a candidate write", (_name, report, reason) => {
    const reduced = reduceLedger(ledger(), report);
    expect(reduced).toEqual({ result: { status: "discarded", reason } });
  });

  it("atomically replaces a private ledger and leaves discarded bytes untouched", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-ledger-"));
    dirs.push(dir);
    const file = path.join(dir, "operations.json");
    fs.writeFileSync(file, `${JSON.stringify(ledger(), null, 2)}\n`, { mode: 0o600 });
    expect(applyLedgerFile(file, envelope())).toMatchObject({ status: "applied", revision: 5 });
    expect(fs.statSync(file).mode & 0o777).toBe(0o600);
    const applied = fs.readFileSync(file, "utf8");
    expect(applyLedgerFile(file, envelope())).toEqual({ status: "discarded", reason: "DUPLICATE_REPORT" });
    expect(fs.readFileSync(file, "utf8")).toBe(applied);
  });

  it("refuses to rewrite a ledger whose existing mode is not private", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-ledger-"));
    dirs.push(dir);
    const file = path.join(dir, "operations.json");
    fs.writeFileSync(file, JSON.stringify(ledger()), { mode: 0o644 });
    const before = fs.readFileSync(file, "utf8");
    expect(applyLedgerFile(file, envelope())).toEqual({ status: "discarded", reason: "UNSAFE_LEDGER_MODE" });
    expect(fs.readFileSync(file, "utf8")).toBe(before);
  });
});
