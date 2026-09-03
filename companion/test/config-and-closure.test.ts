import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Bridge } from "../src/bridge.js";
import { companionVersion, configPath, diagnoseConfig, existingRconPassword, loadConfig, saveConfig } from "../src/config.js";
import { collectDoctorReport } from "../src/doctor.js";
import { connectStatus } from "../src/mcp/server.js";
import { RconClient } from "../src/rcon.js";

const homes: string[] = [];
function isolatedHome(): string {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-config-test-"));
  homes.push(home); vi.stubEnv("HOME", home); return home;
}
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); homes.splice(0).forEach((home) => fs.rmSync(home, { recursive: true, force: true })); });

describe("exact local configuration", () => {
  function validDoctorSettings(password = "secret") {
    const home = isolatedHome(); const userDir = path.join(home, "factorio"); fs.mkdirSync(userDir);
    const settings = { rcon: { host: "127.0.0.1", port: 19015, password } } as const;
    saveConfig({ factorioUserDir: userDir, rcon: settings.rcon });
    return settings;
  }

  async function expectConnectConfigError(pattern: RegExp) {
    const bridge = vi.fn(async () => ({ call: vi.fn() } as unknown as Bridge));
    const output = await connectStatus(bridge, diagnoseConfig);
    expect(output.isError).toBe(false);
    expect(output.content[0].text).toMatch(pattern);
    expect(bridge).not.toHaveBeenCalled();
  }

  it("persists only the accepted keys with mode 0600", () => {
    const home = isolatedHome(); const userDir = path.join(home, "factorio"); fs.mkdirSync(userDir);
    saveConfig({ factorioUserDir: userDir, rcon: { host: "127.0.0.1", port: 19015, password: "top-secret" } });
    fs.chmodSync(configPath(), 0o644);
    saveConfig({ factorioUserDir: userDir, rcon: { host: "127.0.0.1", port: 19015, password: "top-secret" } });
    expect(loadConfig()).toEqual({ factorioUserDir: userDir, rcon: { host: "127.0.0.1", port: 19015, password: "top-secret" } });
    expect(fs.statSync(configPath()).mode & 0o777).toBe(0o600);
    expect(Object.keys(JSON.parse(fs.readFileSync(configPath(), "utf8"))).sort()).toEqual(["factorioUserDir", "rcon"]);
  });
  it("rejects obsolete keys but can reuse only the existing local password", () => {
    isolatedHome(); fs.mkdirSync(path.dirname(configPath()), { recursive: true });
    fs.writeFileSync(configPath(), JSON.stringify({ factorioUserDir: "/tmp/f", provider: "old", rcon: { host: "127.0.0.1", port: 19015, password: "keep-me" } }));
    expect(loadConfig()).toBeNull(); expect(existingRconPassword()).toBe("keep-me");
  });
  it.each([
    { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "" } },
    { factorioUserDir: "/factorio", rcon: { host: "localhost", port: 19015, password: "secret" } },
    { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 27099, password: "secret" } },
    { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret", extra: true } },
  ])("rejects an inexact or empty-secret config schema", (candidate) => {
    isolatedHome(); fs.mkdirSync(path.dirname(configPath()), { recursive: true });
    fs.writeFileSync(configPath(), JSON.stringify(candidate));
    expect(loadConfig()).toBeNull();
  });
  it("reports invalid/missing config without leaking or mangling an empty password", async () => {
    isolatedHome();
    const report = await collectDoctorReport({ rcon: { host: "127.0.0.1", port: 19015, password: "" } });
    const rendered = JSON.stringify(report);
    expect(rendered).not.toMatch(/provider|brain|telemetry|api.?key/i);
    expect(rendered).not.toContain("[redacted]");
    expect(report.checks).toEqual([expect.objectContaining({ name: "config", ok: false })]);
  });
  it("connect_status reports a missing config before creating RCON", async () => {
    isolatedHome();
    await expectConnectConfigError(/Offline: configuration is missing.*factorio-codex setup/);
  });
  it("connect_status reports an invalid exact config before creating RCON", async () => {
    isolatedHome(); fs.mkdirSync(path.dirname(configPath()), { recursive: true });
    fs.writeFileSync(configPath(), JSON.stringify({ factorioUserDir: "/factorio", rcon: { host: "localhost" } }));
    await expectConnectConfigError(/Offline: configuration is invalid.*factorio-codex setup/);
  });
  it("connect_status reports a missing Factorio user-data directory before creating RCON", async () => {
    const home = isolatedHome();
    saveConfig({ factorioUserDir: path.join(home, "absent-factorio"), rcon: { host: "127.0.0.1", port: 19015, password: "secret" } });
    await expectConnectConfigError(/Offline: configured Factorio user-data directory is missing.*launch Factorio once.*setup again/);
  });
  it("connect_status reports a non-0600 config before creating RCON", async () => {
    const home = isolatedHome(); const userDir = path.join(home, "factorio"); fs.mkdirSync(userDir);
    saveConfig({ factorioUserDir: userDir, rcon: { host: "127.0.0.1", port: 19015, password: "secret" } });
    fs.chmodSync(configPath(), 0o644);
    await expectConnectConfigError(/Offline: configuration mode is 644; expected 600; run setup again/);
  });
  it("redacts a configured password from doctor text and JSON failures", async () => {
    const secret = "never-print-this";
    const settings = validDoctorSettings(secret);
    vi.spyOn(RconClient.prototype, "connect").mockRejectedValueOnce(new Error(`auth failed for ${secret}`));
    const report = await collectDoctorReport(settings);
    expect(JSON.stringify(report)).not.toContain(secret);
    expect(report.checks.find((check) => check.name === "rcon")?.detail).toContain("[redacted]");
  });
  it.each([
    { stage: "unlock", unlockError: new Error("unlock failed") },
    { stage: "ping", callError: new Error("ping failed") },
  ])("keeps authenticated RCON successful when $stage cannot reach the mod", async ({ unlockError, callError }) => {
    const settings = validDoctorSettings();
    vi.spyOn(RconClient.prototype, "connect").mockResolvedValueOnce();
    vi.spyOn(Bridge.prototype, "unlock").mockImplementationOnce(async () => { if (unlockError) throw unlockError; });
    const call = vi.spyOn(Bridge.prototype, "call");
    if (callError) call.mockRejectedValueOnce(callError);
    const report = await collectDoctorReport(settings);
    expect(report.checks.filter((check) => check.name === "rcon")).toEqual([{ name: "rcon", ok: true, detail: "authenticated" }]);
    expect(report.checks).toContainEqual(expect.objectContaining({ name: "mod", ok: false, detail: expect.stringMatching(/RPC unavailable: (unlock|ping) failed/), fix: expect.stringContaining("install and enable") }));
  });
  it.each([
    { ping: { protocol_version: 6, mod_version: "0.13.8" }, failedCheck: "protocol" },
    { ping: { protocol_version: 15, mod_version: "0.6.0" }, failedCheck: "mod" },
  ])("reports a $failedCheck mismatch without contradicting authenticated RCON", async ({ ping, failedCheck }) => {
    const settings = validDoctorSettings();
    vi.spyOn(RconClient.prototype, "connect").mockResolvedValueOnce();
    vi.spyOn(Bridge.prototype, "unlock").mockResolvedValueOnce();
    vi.spyOn(Bridge.prototype, "call").mockResolvedValueOnce(ping as never);
    const report = await collectDoctorReport(settings);
    expect(report.checks.filter((check) => check.name === "rcon")).toEqual([{ name: "rcon", ok: true, detail: "authenticated" }]);
    expect(report.checks).toContainEqual(expect.objectContaining({ name: failedCheck, ok: false, fix: expect.stringContaining("install Factorio Codex Companion") }));
  });
  it("doctor reuses exact endpoint validation and never connects to a remote or wrong port", async () => {
    const home = isolatedHome(); const userDir = path.join(home, "factorio"); fs.mkdirSync(userDir);
    saveConfig({ factorioUserDir: userDir, rcon: { host: "127.0.0.1", port: 19015, password: "secret" } });
    const connect = vi.spyOn(RconClient.prototype, "connect");
    const report = await collectDoctorReport({ rcon: { host: "192.0.2.10", port: 19016, password: "secret" } });
    expect(report.checks).toContainEqual(expect.objectContaining({ name: "rcon-config", ok: false, detail: "must be 127.0.0.1:19015" }));
    expect(connect).not.toHaveBeenCalled();
  });
  it("keeps root, package, lockfile, runtime, mod, and docs at 0.13.8", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const read = (relative: string) => JSON.parse(fs.readFileSync(path.join(root, relative), "utf8"));
    const lock = read("package-lock.json");
    expect([
      read("package.json").version,
      read("companion/package.json").version,
      read("mod/agentic-companion/info.json").version,
      lock.version,
      lock.packages[""].version,
      lock.packages.companion.version,
      companionVersion(),
    ]).toEqual(Array(7).fill("0.13.8"));
    expect(fs.readFileSync(path.join(root, "README.md"), "utf8")).toContain("Current release: **0.13.8**");
    expect(fs.readFileSync(path.join(root, "docs/LIVE-VALIDATION.md"), "utf8")).toContain("release **0.13.8**");
  });
  it("keeps visible locale title and description aligned with one-body mod metadata", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const info = JSON.parse(fs.readFileSync(path.join(root, "mod/agentic-companion/info.json"), "utf8"));
    const locale = fs.readFileSync(path.join(root, "mod/agentic-companion/locale/en/agentic-companion.cfg"), "utf8");
    const values = [...locale.matchAll(/^agentic-companion=(.+)$/gm)].map((match) => match[1]);
    expect(info).toMatchObject({ version: "0.13.8", title: "Factorio Codex Companion" });
    expect(values).toEqual([info.title, info.description]);
    expect(locale).not.toMatch(/movement.speed|multiplier/i);
    expect(locale).not.toMatch(/Agentic Companion|AI companion|companions|characters|vehicles/i);
  });

  it("uses the source MCP entry and contains no retired speed-setting path", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const config = fs.readFileSync(path.join(root, ".codex/config.toml"), "utf8");
    expect(config).toContain('command = "node"');
    expect(config).toContain('args = ["node_modules/.bin/tsx", "companion/src/cli.ts", "mcp"]');
    expect(config).not.toMatch(/^cwd\s*=/m);
    expect(fs.existsSync(path.join(root, "mod/agentic-companion/settings.lua"))).toBe(false);
    const modSource = ["control.lua", "scripts/companion.lua", "locale/en/agentic-companion.cfg"]
      .map((file) => fs.readFileSync(path.join(root, "mod/agentic-companion", file), "utf8")).join("\n");
    expect(modSource).not.toMatch(/movement.speed|movement_speed|runtime_mod_setting/i);
  });

  it("keeps the player skill text-only and aligned with batching and MCP_GAP", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const skill = fs.readFileSync(path.join(root, ".agents/skills/factorio-player/SKILL.md"), "utf8");
    const liveValidation = fs.readFileSync(path.join(root, "docs/LIVE-VALIDATION.md"), "utf8");
    expect(skill).toMatch(/run_plan/);
    expect(skill).toMatch(/build_plan/);
    expect(skill).toMatch(/MCP_GAP/);
    expect(skill).toMatch(/never use screenshots or screen capture for live gameplay perception,[\s\S]*navigation,[\s\S]*targeting,[\s\S]*placement choice,[\s\S]*action selection/i);
    expect(skill).toMatch(/after a\s+scored\s+run is frozen,[\s\S]*structured MCP evidence is insufficient[\s\S]*non-authoritative review evidence[\s\S]*no coordinates, routes,[\s\S]*tactics, or durable knowledge[\s\S]*revalidated through structured in-game MCP data/i);
    expect(skill).toMatch(/Finish every packet with an authoritative observation[\s\S]*terminal observation[\s\S]*missing or became stale/);
    expect(skill).not.toMatch(/finish every packet with `observe_local`/i);
    expect(skill).toContain("[player knowledge v1](PLAYER-KNOWLEDGE-v1.md)");
    expect(skill).toMatch(/do not assume a Sol\/Luna winner/i);
    expect(liveValidation).toMatch(/Prior-release 0\.7\.0 live evidence/);
    expect(liveValidation).toMatch(/historical 0\.7\.0 evidence[\s\S]*not live validation of[\s\S]*0\.8\.0/);
    expect(liveValidation).toMatch(/Optional couch UI navigation layer/);
    expect(liveValidation).toMatch(/non-game couch UI, administration, or[\s\S]*reconnection steps that SSH cannot perform/);
    expect(liveValidation).toMatch(/AutoHotkey-based `couch-ui` fallback/);
    expect(liveValidation).toMatch(/gameplay pilot remains MCP-text-only[\s\S]*Screenshot capability must never be used for Factorio[\s\S]*perception or play/i);
    expect(liveValidation).toMatch(/post-run screenshots are permitted only after the scored run is frozen[\s\S]*structured MCP evidence is insufficient[\s\S]*non-authoritative[\s\S]*must not contribute coordinates, routes, tactics, or[\s\S]*durable knowledge[\s\S]*revalidate every finding[\s\S]*structured in-game MCP data[\s\S]*does not authorize couch GUI control or expand the Windows-MCP boundary/i);
    expect(liveValidation).toContain("%APPDATA%\\\\Factorio\\\\mods\\\\mod-list.json");
    expect(liveValidation).not.toContain("%APPDATA%\\\\Factorio\\\\mod-list.json");
  });

  it("locks the selected Candidate B and player-knowledge boundary", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const benchmark = fs.readFileSync(path.join(root, "docs/AGENT-PLAY-PERFORMANCE.md"), "utf8");
    const knowledge = fs.readFileSync(path.join(root, ".agents/skills/factorio-player/PLAYER-KNOWLEDGE-v1.md"), "utf8");
    const normalizedKnowledge = knowledge.replace(/\s+/g, " ");
    expect(benchmark).toMatch(/Candidate B is exactly[\s\S]*Sol-medium read\/plan-only master[\s\S]*Terra-low\s+sole-writer pilot[\s\S]*Terra-low read-only specialist[\s\S]*fast mode off/i);
    expect(benchmark).toMatch(/supersedes the earlier prospective wave matrix/i);
    expect(benchmark).not.toMatch(/\| W[123] —/);
    expect(knowledge).toMatch(/recipes[\s\S]*calculations[\s\S]*operations[\s\S]*relative layouts/);
    for (const forbidden of ["map coordinates", "tutorials", "external blueprint strings", "online build sequences"])
      expect(normalizedKnowledge).toContain(forbidden);
  });

  it("ships only the couch-PC native Codex client launcher", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    expect(fs.existsSync(path.join(root, "scripts/launch-native-client.sh"))).toBe(false);
    const couchLauncher = fs.readFileSync(path.join(root, "scripts/launch-native-client.ps1"), "utf8");
    expect(couchLauncher).toMatch(/Couch-PC-only visual launcher/);
    expect(couchLauncher).toMatch(/server-and-agent workstation has no[\s\S]*dedicated GPU[\s\S]*must never run a Factorio GUI or client/);
    expect(couchLauncher).toMatch(/LOCALAPPDATA[\s\S]*factorio-codex\\native-client/);
    expect(couchLauncher).toMatch(/service-username.*Codex/);
    expect(couchLauncher).toMatch(/Steam Factorio build replaces the isolated Codex identity/);
    expect(couchLauncher).toMatch(/--mp-connect[\s\S]*--force-graphics-preset very-low[\s\S]*--disable-audio/);
    const readme = fs.readFileSync(path.join(root, "README.md"), "utf8");
    const liveValidation = fs.readFileSync(path.join(root, "docs/LIVE-VALIDATION.md"), "utf8");
    expect(readme).toMatch(/no dedicated GPU[\s\S]*permanently[\s\S]*headless[\s\S]*All visual workloads run on the couch PC/);
    expect(liveValidation).toMatch(/no dedicated[\s\S]*GPU[\s\S]*permanently headless[\s\S]*Both visual Factorio processes run exclusively on the couch PC/);
  });

  it("keeps W1C prompts automation-first, adaptive, and authority-separated", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const skill = fs.readFileSync(path.join(root, ".agents/skills/factorio-player/SKILL.md"), "utf8");
    const readPrompt = (role: string) => fs.readFileSync(path.join(root, `.agents/skills/factorio-player/GOAL-${role}-v1.md`), "utf8");
    const master = readPrompt("MASTER"), pilot = readPrompt("PILOT"), specialist = readPrompt("SPECIALIST");
    for (const link of ["GOAL-MASTER-v1.md", "GOAL-PILOT-v1.md", "GOAL-SPECIALIST-v1.md"])
      expect(skill).toContain(`](${link})`);
    expect(master).toMatch(/read\/plan-only/i);
    expect(master).toMatch(/global goal[\s\S]*dominant bottleneck[\s\S]*current plan[\s\S]*exactly one actually queued successor/i);
    expect(master).toMatch(/outcome-labeled[\s\S]*replan mid-run/i);
    expect(master).toMatch(/PLAYER-KNOWLEDGE-v1\.md[\s\S]*in-game learned recipes, calculations, operations[\s\S]*relative layouts/i);
    expect(pilot).toMatch(/only ordinary MCP action writer/i);
    expect(pilot).toMatch(/latest terminal observation wins/i);
    expect(specialist).toMatch(/strictly read-only/i);
    expect(specialist).toMatch(/recipes, prerequisites, rates, BOMs, capacity, utilization, automation payback[\s\S]*relative layouts/i);
    expect(specialist).toMatch(/assumptions, provenance, uncertainty/i);
    expect(specialist).toContain("`observe_local`, `inspect_entity`, `describe_prototype`, `progression_status`, `can_place`, `find_placement`, `map_summary`, `production_requirements`, and `plan_status`");
    expect(specialist).toMatch(/`connect_entities` is mutating[\s\S]*pilot-only/i);
    for (const text of [skill, master, pilot, specialist]) {
      expect(text).toMatch(/(?:no (?:second|another)|another) body|(?:one|sole) physical Codex body/i);
      expect(text).toMatch(/never use screenshots or screen capture for live gameplay perception[\s\S]*action selection/i);
      expect(text).toMatch(/raw Lua\/console/i);
      expect(text).toMatch(/bounded falsifiable experiment[\s\S]*uncertainty[\s\S]*predicted[\s\S]*safe bound[\s\S]*numeric stop/i);
      expect(text).toMatch(/copied layouts[\s\S]*tutorials[\s\S]*online sequences/i);
    }
    for (const text of [skill, master, pilot]) {
      expect(text).toMatch(/After bootstrap[\s\S]*manual mining(?:\s+or\s+crafting|\/crafting) batch|After bootstrap[\s\S]*manual mining\/crafting batch/i);
      expect(text).toMatch(/exact net deficit[\s\S]*carried stock[\s\S]*machine buffers\/output[\s\S]*(?:work in progress|WIP)[\s\S]*machine unlock or fuel consumer[\s\S]*uptime[\s\S]*payback[\s\S]*item\/time units[\s\S]*break-even[\s\S]*numeric stop/i);
      expect(text).toMatch(/automat(?:e|ion)[\s\S]*(bulk extraction|smelting)[\s\S]*(logistics|science)/i);
      expect(text).toMatch(/never wait[\s\S]*safe\s+productive action exists/i);
    }
    expect(specialist).toMatch(/After bootstrap[\s\S]*manual mining\/crafting batch[\s\S]*exact net deficit[\s\S]*payback[\s\S]*numeric stop/i);
    expect(pilot).toMatch(/Never prepend `walk_to` to a positional action that already auto-approaches/i);
    expect(pilot).toMatch(/call `queue_plan`[\s\S]*returned `plan_id` and `after_plan_id`[\s\S]*`plan_status` confirms status `queued`[\s\S]*`queued_successor: null`/i);
  });

  it("keeps every durable gameplay prompt semantic and route-free", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const files = [
      "SKILL.md", "GOAL-MASTER-v1.md", "GOAL-PILOT-v1.md",
      "GOAL-SPECIALIST-v1.md", "PLAYER-KNOWLEDGE-v1.md",
    ];
    const texts = files.map((file) => fs.readFileSync(path.join(root, ".agents/skills/factorio-player", file), "utf8"));
    for (const text of texts) {
      for (const concept of ["observ", "bottleneck", "falsifiable hypothesis", "predicted", "actual", "retain", "revise", "discard", "provenance", "uncertainty"])
        expect(text.toLowerCase()).toContain(concept);
      for (const rejected of [/(?:timed\s+phase|elapsed-time\s+milestone)/i, /fixed\s+build\s+order/i, /named\s+route/i, /(?:map|cross-run|world)\s+coordinate/i, /prescriptive\s+progression\s+sequence/i])
        expect(text).toMatch(rejected);
      for (const rejected of [/cop(?:y|ied) layouts/i, /tutorials/i, /online\s+(?:build\s+)?sequences/i])
        expect(text).toMatch(rejected);
      expect(text).not.toMatch(/\b(?:first|start by)\s+(?:mine|craft|place|build|research)\b/i);
      expect(text).not.toMatch(/\bthen\s+(?:mine|craft|place|build|research)\b/i);
      expect(text).not.toMatch(/\b(?:at|by|after)\s+(?:minute\s*)?\d+\s*(?:m|min|minutes?)?\s*[,,:-]?\s*(?:mine|craft|place|build|research)\b/i);
      expect(text).not.toMatch(/\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)/);
    }
    for (const text of texts.slice(0, 2)) {
      expect(text).toMatch(/observe[\s\S]*bottleneck[\s\S]*falsifiable hypothesis[\s\S]*predict[\s\S]*safe action[\s\S]*compare[\s\S]*retain[\s\S]*revise[\s\S]*discard/i);
    }
  });

  it("documents the W1C research basis as principles rather than a route", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const performance = fs.readFileSync(path.join(root, "docs/AGENT-PLAY-PERFORMANCE.md"), "utf8");
    const normalized = performance.replace(/\s+/g, " ");
    for (const source of ["Tutorial:Quick_start_guide", "/Crafting", "fff-327", "jpg8l", "2210.03629", "2302.01560", "2305.16291", "2303.11366", "2310.03903v2"])
      expect(performance).toContain(source);
    expect(performance).toMatch(/untrusted evidence[\s\S]*principles[\s\S]*not[\s\S]*(exact )?build routes/i);
    expect(normalized).toMatch(/manual bootstrap.*automated extraction.*production.*science/i);
    expect(performance).toMatch(/outcomes[\s\S]*failures[\s\S]*self-verification/i);
  });

  it("locks Candidate B timing snapshot and continuous rocket acceptance", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const performance = fs.readFileSync(path.join(root, "docs/AGENT-PLAY-PERFORMANCE.md"), "utf8");
    const live = fs.readFileSync(path.join(root, "docs/LIVE-VALIDATION.md"), "utf8");
    const joined = `${performance}\n${live}`;
    expect(joined).toMatch(/Candidate B[\s\S]*Sol-medium read\/plan-only master[\s\S]*Terra-low\s+sole-writer pilot[\s\S]*Terra-low read-only specialist[\s\S]*fast mode off/i);
    expect(joined).toMatch(/fresh[\s\S]*immutable[\s\S]*peaceful[\s\S]*enemy bases disabled[\s\S]*couch PC/i);
    expect(performance).toMatch(/Record `GO` as one UTC wall-clock timestamp[\s\S]*monotonic-clock instant[\s\S]*Factorio tick/i);
    expect(performance).toMatch(/`GO\+1200s` \(`GO\+20m`\)[\s\S]*first structured observation at or after[\s\S]*before the next ordinary action/i);
    expect(performance).toMatch(/never backdate[\s\S]*grant grace/i);
    expect(performance).toMatch(/`SNAPSHOT_AT_20M`[\s\S]*progress vector[\s\S]*without a\s+pass\/fail judgment/i);
    expect(performance).toMatch(/drain the FIFO lane[\s\S]*queued plan cannot start across the deadline/i);
    expect(performance).toMatch(/work completed during collection latency[\s\S]*must not be attributed to the deadline/i);
    for (const field of ["carried and factory inventory", "hand-mined totals", "hand-craft counts/time", "capacity", "utilization", "automated extraction", "research, power", "work in progress", "inter-plan timing", "dominant bottleneck", "queued expansion"])
      expect(performance.toLowerCase()).toContain(field);
    expect(performance).toMatch(/20-minute result freezes and terminates the scored trial[\s\S]*cancel and drain[\s\S]*no post-snapshot gameplay[\s\S]*fresh byte-identical baseline/i);
    expect(performance).toMatch(/run goal is a legitimately paid rocket launch[\s\S]*20-minute mark is an instructions-only throughput and[\s\S]*resource-processing snapshot[\s\S]*not a steam-power milestone or binary success\s+gate/i);
    expect(joined).not.toMatch(/PASS_AT_20M|MISS_AT_20M|Success is a coal-fired steam plant/i);
    expect(performance).toMatch(/no human tactical coaching or prompt\s+amendment/i);
    expect(performance).not.toContain("do not imply continuing autonomous gameplay");
    expect(performance).not.toMatch(/\| W[123] —/);
    const candidate = performance.slice(performance.indexOf("### Candidate B acceptance run"));
    expect(candidate).toMatch(/both graphical clients exclusively on the couch PC/i);
    expect(candidate).toMatch(/one Codex body[\s\S]*one FIFO lane/i);
  });

  it("requires bounded reuse discovery before greenfield gameplay code", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const agentGuide = fs.readFileSync(path.join(root, "AGENTS.md"), "utf8");
    const skill = fs.readFileSync(path.join(root, ".agents/skills/factorio-player/SKILL.md"), "utf8");
    for (const text of [agentGuide, skill]) {
      const normalized = text.replace(/\s+/g, " ");
      expect(text).toMatch(/newly observed gameplay difficulty appears to require greenfield code[\s\S]*bounded Firecrawl reuse survey/i);
      expect(normalized).toMatch(/license,.*maintenance,.*current Factorio API compatibility,.*one-body\/one-writer\/\s*text-only physical fit/i);
      for (const risk of ["cheats", "hidden map state", "raw console", "imported blueprints", "tutorial sequences"])
        expect(normalized.toLowerCase()).toContain(risk);
      expect(normalized).toMatch(/reuse or adapt the.*smallest maintained compatible path.*design evidence.*patch the smallest existing active path/i);
      expect(text).toMatch(/not a service, gate, or report workflow|do not create a[\s\S]*service, gate, or report workflow/i);
    }

    const normalizedGuidance = `${agentGuide}\n${skill}`.replace(/\s+/g, " ");
    expect(normalizedGuidance).toMatch(/mine`? count means physical mining cycles.*item ceilings.*in-game learned per-cycle yield.*actual inventory deltas/i);
    expect(normalizedGuidance).toMatch(/current plan plus one grounded queued successor.*avoid micro-packet idle gaps/i);

    const performance = fs.readFileSync(path.join(root, "docs/AGENT-PLAY-PERFORMANCE.md"), "utf8");
    expect(performance).toMatch(/maintained[\s\S]*MIT[\s\S]*SimpleAdjustableInserters[\s\S]*quick-adjustable-inserters/i);
    expect(performance).toMatch(/custom inserter vectors|player adjustment interactions/i);
    expect(performance.replace(/\s+/g, " ")).toMatch(/neither fits.*No candidate code was imported/i);
    for (const field of ["pickup_target", "drop_target", "pickup_position", "drop_position"])
      expect(performance).toContain(`\`${field}\``);
  });
});

describe("Lua dependency closure", () => {
  it("all literal scripts.* requires resolve inside the packaged mod", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const mod = path.join(root, "mod/agentic-companion");
    const files: string[] = [];
    const walk = (dir: string) => fs.readdirSync(dir, { withFileTypes: true }).forEach((entry) => entry.isDirectory() ? walk(path.join(dir, entry.name)) : entry.name.endsWith(".lua") && files.push(path.join(dir, entry.name)));
    walk(mod);
    for (const file of files) for (const match of fs.readFileSync(file, "utf8").matchAll(/require\(["'](scripts\.[^"']+)["']\)/g)) {
      const dependency = path.join(mod, `${match[1].replaceAll(".", "/")}.lua`);
      expect(fs.existsSync(dependency), `${path.relative(root, file)} -> ${path.relative(root, dependency)}`).toBe(true);
    }
  });
});
