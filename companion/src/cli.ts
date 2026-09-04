#!/usr/bin/env node
import { parseArgs } from "node:util";
import { resolveSettings } from "./config.js";
import { runDoctor } from "./doctor.js";
import { runMcpServer } from "./mcp/server.js";
import { runWizard } from "./setup/wizard.js";
import { assertNodeRuntime } from "./runtime.js";
import { runLedgerApply } from "./coordination/ledger.js";
import { compareRuns, markRunAssisted, recordRun, renderComparison, runRoot } from "./runs/telemetry.js";

const HELP = `factorio-codex — text-only Factorio control for Codex\n\nUsage:\n  factorio-codex setup\n  factorio-codex doctor [--json]\n  factorio-codex mcp [--surface full|read-only]\n  factorio-codex ledger-apply --ledger <operations.json>\n  factorio-codex runs record --ledger <operations.json> --variant <name> --change <description> [--kind debug|benchmark]\n  factorio-codex runs mark-assisted <run-id> --reason <text>\n  factorio-codex runs compare <baseline-run-id> <candidate-run-id> [--json]`;

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({ options: {
    json: { type: "boolean" }, ledger: { type: "string" }, surface: { type: "string" },
    variant: { type: "string" }, change: { type: "string" }, kind: { type: "string" }, reason: { type: "string" },
    help: { type: "boolean", short: "h" },
  }, allowPositionals: true });
  const command = positionals[0];
  if (values.help || !command) { console.log(HELP); return; }
  if (command !== "doctor") assertNodeRuntime();
  if (command === "setup") return runWizard();
  if (command === "doctor") return runDoctor(resolveSettings(), { json: values.json });
  if (command === "mcp") {
    const surface = values.surface ?? "full";
    if (surface !== "full" && surface !== "read-only") throw new Error("mcp --surface must be full or read-only");
    return runMcpServer(surface);
  }
  if (command === "ledger-apply") {
    if (!values.ledger) throw new Error("ledger-apply requires --ledger <operations.json>");
    return runLedgerApply(values.ledger);
  }
  if (command === "runs") {
    const action = positionals[1];
    if (action === "record") {
      if (!values.ledger || !values.variant || !values.change) throw new Error("runs record requires --ledger, --variant, and --change");
      const kind = values.kind ?? "debug";
      if (kind !== "debug" && kind !== "benchmark") throw new Error("runs record --kind must be debug or benchmark");
      return recordRun({ ledger: values.ledger, variant: values.variant, change: values.change, kind });
    }
    if (action === "mark-assisted") {
      if (!positionals[2] || !values.reason) throw new Error("runs mark-assisted requires <run-id> and --reason");
      markRunAssisted(runRoot(), positionals[2], values.reason); return;
    }
    if (action === "compare") {
      if (!positionals[2] || !positionals[3]) throw new Error("runs compare requires <baseline-run-id> and <candidate-run-id>");
      const comparison = compareRuns(runRoot(), positionals[2], positionals[3]);
      console.log(values.json ? JSON.stringify(comparison, null, 2) : renderComparison(comparison)); return;
    }
    throw new Error(`unknown runs command: ${action ?? "missing"}`);
  }
  console.error(`Unknown command: ${command}\n${HELP}`);
  process.exitCode = 1;
}

main().catch((error) => { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; });
