#!/usr/bin/env node
import { parseArgs } from "node:util";
import { resolveSettings } from "./config.js";
import { runDoctor } from "./doctor.js";
import { runMcpServer } from "./mcp/server.js";
import { runWizard } from "./setup/wizard.js";
import { assertNodeRuntime } from "./runtime.js";
import { runLedgerApply } from "./coordination/ledger.js";

const HELP = `factorio-codex — text-only Factorio control for Codex\n\nUsage:\n  factorio-codex setup\n  factorio-codex doctor [--json]\n  factorio-codex mcp [--surface full|read-only]\n  factorio-codex ledger-apply --ledger <operations.json>`;

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({ options: {
    json: { type: "boolean" }, ledger: { type: "string" }, surface: { type: "string" },
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
  console.error(`Unknown command: ${command}\n${HELP}`);
  process.exitCode = 1;
}

main().catch((error) => { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; });
