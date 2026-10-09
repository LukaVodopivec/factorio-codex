#!/usr/bin/env node
import { parseArgs } from "node:util";
import { resolveSettings } from "./config.js";
import { runDoctor } from "./doctor.js";
import { runMcpServer, SESSION_ROLES, type SessionRole } from "./mcp/server.js";
import { runWizard } from "./setup/wizard.js";
import { assertNodeRuntime } from "./runtime.js";
import { AFTER_PACKAGE_ID_RULE, OMITTED_UNQUEUED_RULE, VERIFY_RULE, packageContract, runLedgerApply } from "./coordination/ledger.js";
import { compareRuns, interruptRun, markRunAssisted, recordRun, renderComparison, runRoot } from "./runs/telemetry.js";
import { createServerSave, serverTimelapse, startServer, stopServer } from "./server/server.js";
import fs from "node:fs";
import { addConfiguration, initializeCampaign, nextTrial, readCampaign, recordTrial, setCampaignStatus } from "./runs/campaign.js";

const HELP = `factorio-codex — text-only Factorio control for Codex\n\nUsage:\n  factorio-codex setup\n  factorio-codex doctor [--json]\n  factorio-codex mcp [--surface full|read-only] [--role pilot|strategist|advisor|supervisor]\n  factorio-codex ledger-apply --ledger <operations.json>   (stdin: update envelope, or {"init":true,...} for an absent ledger)\n      ${AFTER_PACKAGE_ID_RULE}\n      ${VERIFY_RULE}\n      ${OMITTED_UNQUEUED_RULE}\n  factorio-codex ledger-apply --schema   (prints the update envelope and every update, package and step field, from the schemas ledger-apply checks)\n  factorio-codex runs record --ledger <operations.json> --variant <name> --change <description> [--kind debug|benchmark] [--pilot-rollout <rollout.jsonl>] [--strategist-rollout <rollout.jsonl>]\n  factorio-codex runs interrupt <run-id> --reason <reconciliation>\n  factorio-codex runs mark-assisted <run-id> --reason <text>\n  factorio-codex runs compare <baseline-run-id> <candidate-run-id> [--json]\n  factorio-codex campaign init --campaign <campaign.json> --baseline <save.zip> --id <name> --release-sha <sha>\n  factorio-codex campaign next|status|pause|resume --campaign <campaign.json>\n  factorio-codex campaign add --campaign <campaign.json> --profile <configuration.json>\n  factorio-codex campaign record <run-id> --campaign <campaign.json>\n  factorio-codex server create <run-dir> [--seed <n>] [--factorio <path>]\n  factorio-codex server start <run-dir> [--bind <address>] [--factorio <path>]\n  factorio-codex server stop <run-dir>\n  factorio-codex server timelapse start <folder> | status | stop`;

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({ options: {
    json: { type: "boolean" }, ledger: { type: "string" }, surface: { type: "string" }, role: { type: "string" },
    variant: { type: "string" }, change: { type: "string" }, kind: { type: "string" }, reason: { type: "string" },
    "pilot-rollout": { type: "string" }, "strategist-rollout": { type: "string" },
    factorio: { type: "string" }, bind: { type: "string" }, seed: { type: "string" },
    campaign: { type: "string" }, baseline: { type: "string" }, id: { type: "string" },
    "release-sha": { type: "string" }, profile: { type: "string" }, "duration-seconds": { type: "string" },
    "incumbent-summary": { type: "string" },
    schema: { type: "boolean" },
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
    // The session launcher names the role; cancels this process makes carry it.
    const role = values.role ?? process.env.FACTORIO_CODEX_ROLE ?? "unknown";
    if (!(SESSION_ROLES as readonly string[]).includes(role)) throw new Error(`mcp --role must be one of ${SESSION_ROLES.join(", ")}`);
    if ((role === "strategist" || role === "advisor") && surface !== "read-only")
      throw new Error(`${role} requires the read-only MCP surface`);
    return runMcpServer(surface, undefined, role as SessionRole);
  }
  if (command === "ledger-apply") {
    if (values.schema) { console.log(packageContract()); return; }
    if (!values.ledger) throw new Error("ledger-apply requires --ledger <operations.json>");
    return runLedgerApply(values.ledger);
  }
  if (command === "campaign") {
    if (!values.campaign) throw new Error("campaign commands require --campaign <campaign.json>");
    const action = positionals[1];
    let output: unknown;
    if (action === "init") {
      if (!values.baseline || !values.id || !values["release-sha"]) throw new Error("campaign init requires --baseline, --id and --release-sha");
      output = initializeCampaign(values.campaign, values.baseline, values.id, values["release-sha"]);
    } else if (action === "next") output = nextTrial(values.campaign);
    else if (action === "status") output = readCampaign(values.campaign);
    else if (action === "add") {
      if (!values.profile) throw new Error("campaign add requires --profile <configuration.json>");
      output = addConfiguration(values.campaign, JSON.parse(fs.readFileSync(values.profile, "utf8")));
    } else if (action === "record") {
      if (!positionals[2]) throw new Error("campaign record requires <run-id>");
      output = recordTrial(values.campaign, positionals[2]);
    } else if (action === "pause" || action === "resume") output = setCampaignStatus(values.campaign, action === "pause" ? "paused" : "active");
    else throw new Error("campaign action must be init, next, status, add, record, pause or resume");
    console.log(JSON.stringify(output, null, 2)); return;
  }
  if (command === "runs") {
    const action = positionals[1];
    if (action === "record") {
      if (!values.ledger || !values.variant || !values.change) throw new Error("runs record requires --ledger, --variant, and --change");
      const kind = values.kind ?? "debug";
      if (kind !== "debug" && kind !== "benchmark") throw new Error("runs record --kind must be debug or benchmark");
      return recordRun({ ledger: values.ledger, variant: values.variant, change: values.change, kind,
        durationSeconds: values["duration-seconds"] === undefined ? undefined : Number(values["duration-seconds"]),
        incumbentSummary: values["incumbent-summary"],
        pilotRollout: values["pilot-rollout"], strategistRollout: values["strategist-rollout"] });
    }
    if (action === "interrupt") {
      if (!positionals[2] || !values.reason) throw new Error("runs interrupt requires <run-id> and --reason");
      interruptRun(runRoot(), positionals[2], values.reason); return;
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
  if (command === "server") {
    const action = positionals[1], runDir = positionals[2];
    if (action === "timelapse") {
      const step = positionals[2];
      if (step !== "start" && step !== "status" && step !== "stop") throw new Error("server timelapse requires start <folder>, status or stop");
      if (step === "start" && !positionals[3]) throw new Error("server timelapse start requires <folder>");
      console.log(JSON.stringify(await serverTimelapse(step, positionals[3]), null, 2)); return;
    }
    if (!runDir) throw new Error("server commands require <run-dir>");
    if (action === "create") {
      const seed = values.seed === undefined ? undefined : Number(values.seed);
      if (seed !== undefined && !(Number.isInteger(seed) && seed >= 0 && seed < 2 ** 32)) throw new Error("server create --seed must be an unsigned 32-bit integer");
      const paths = createServerSave(runDir, { factorio: values.factorio, seed });
      console.log(JSON.stringify({ save: paths.save, mods: paths.mods }, null, 2)); return;
    }
    if (action === "start") { console.log(JSON.stringify(await startServer(runDir, { factorio: values.factorio, bind: values.bind }), null, 2)); return; }
    if (action === "stop") { console.log(JSON.stringify(await stopServer(runDir), null, 2)); return; }
    throw new Error(`unknown server command: ${action ?? "missing"}`);
  }
  console.error(`Unknown command: ${command}\n${HELP}`);
  process.exitCode = 1;
}

main().catch((error) => { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; });
