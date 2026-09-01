#!/usr/bin/env node
import { parseArgs } from "node:util";
import { resolveSettings } from "./config.js";
import { runDoctor } from "./doctor.js";
import { runMcpServer } from "./mcp/server.js";
import { runWizard } from "./setup/wizard.js";

const HELP = `factorio-codex — text-only Factorio control for Codex\n\nUsage:\n  factorio-codex setup\n  factorio-codex doctor [--json]\n  factorio-codex mcp`;

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({ options: { json: { type: "boolean" }, help: { type: "boolean", short: "h" } }, allowPositionals: true });
  const command = positionals[0];
  if (values.help || !command) { console.log(HELP); return; }
  if (command === "setup") return runWizard();
  if (command === "doctor") return runDoctor(resolveSettings(), { json: values.json });
  if (command === "mcp") return runMcpServer(resolveSettings().rcon);
  console.error(`Unknown command: ${command}\n${HELP}`);
  process.exitCode = 1;
}

main().catch((error) => { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; });
