import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Bridge } from "../src/bridge.js";
import { companionVersion, configPath, diagnoseConfig, existingRconPassword, loadConfig, saveConfig } from "../src/config.js";
import { collectDoctorReport } from "../src/doctor.js";
import { connectStatus, READ_ONLY_TOOLS } from "../src/mcp/server.js";
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
    expect(report.checks).toEqual([
      expect.objectContaining({ name: "node", ok: true }),
      expect.objectContaining({ name: "config", ok: false }),
    ]);
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
    { ping: { protocol_version: 6, mod_version: "0.32.0" }, failedCheck: "protocol" },
    { ping: { protocol_version: 29, mod_version: "0.6.0" }, failedCheck: "mod" },
  ])("reports a $failedCheck mismatch without contradicting authenticated RCON", async ({ ping, failedCheck }) => {
    const settings = validDoctorSettings();
    vi.spyOn(RconClient.prototype, "connect").mockResolvedValueOnce();
    vi.spyOn(Bridge.prototype, "unlock").mockResolvedValueOnce();
    vi.spyOn(Bridge.prototype, "call").mockResolvedValueOnce(ping as never);
    const report = await collectDoctorReport(settings);
    expect(report.checks.filter((check) => check.name === "rcon")).toEqual([{ name: "rcon", ok: true, detail: "authenticated" }]);
    expect(report.checks).toContainEqual(expect.objectContaining({ name: failedCheck, ok: false, fix: expect.stringContaining("install Factorio Codex Companion") }));
  });
  it("names the writer generation that holds the gameplay writes", async () => {
    const settings = validDoctorSettings();
    vi.spyOn(RconClient.prototype, "connect").mockResolvedValue();
    vi.spyOn(Bridge.prototype, "unlock").mockResolvedValue();
    const call = vi.spyOn(Bridge.prototype, "call").mockResolvedValueOnce({ protocol_version: 29, mod_version: "0.32.0", writer_generation: 4 } as never);
    expect((await collectDoctorReport(settings)).checks).toContainEqual({ name: "writer", ok: true, detail: "writer generation 4 holds the gameplay writes" });
    call.mockResolvedValueOnce({ protocol_version: 29, mod_version: "0.32.0", writer_generation: 0 } as never);
    expect((await collectDoctorReport(settings)).checks).toContainEqual({ name: "writer", ok: true, detail: "no writer generation claimed" });
  });
  it("doctor reuses exact endpoint validation and never connects to a remote or wrong port", async () => {
    const home = isolatedHome(); const userDir = path.join(home, "factorio"); fs.mkdirSync(userDir);
    saveConfig({ factorioUserDir: userDir, rcon: { host: "127.0.0.1", port: 19015, password: "secret" } });
    const connect = vi.spyOn(RconClient.prototype, "connect");
    const report = await collectDoctorReport({ rcon: { host: "192.0.2.10", port: 19016, password: "secret" } });
    expect(report.checks).toContainEqual(expect.objectContaining({ name: "rcon-config", ok: false, detail: "must be 127.0.0.1:19015" }));
    expect(connect).not.toHaveBeenCalled();
  });
  it("keeps root, package, lockfile, runtime, mod, and docs at 0.32.0", () => {
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
    ]).toEqual(Array(7).fill("0.32.0"));
    expect(fs.readFileSync(path.join(root, "README.md"), "utf8")).toContain("Current release: **0.32.0**");
    expect(fs.readFileSync(path.join(root, "docs/LIVE-VALIDATION.md"), "utf8")).toContain("release **0.32.0**");
  });
  it("keeps visible locale title and description aligned with one-body mod metadata", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const info = JSON.parse(fs.readFileSync(path.join(root, "mod/agentic-companion/info.json"), "utf8"));
    const locale = fs.readFileSync(path.join(root, "mod/agentic-companion/locale/en/agentic-companion.cfg"), "utf8");
    const values = [...locale.matchAll(/^agentic-companion=(.+)$/gm)].map((match) => match[1]);
    expect(info).toMatchObject({ version: "0.32.0", title: "Factorio Codex Companion" });
    expect(values).toEqual([info.title, info.description]);
    expect(locale).not.toMatch(/movement.speed|multiplier/i);
    expect(locale).not.toMatch(/Agentic Companion|AI companion|companions|characters|vehicles/i);
  });

  it("uses the source MCP entry and contains no retired speed-setting path", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const config = fs.readFileSync(path.join(root, ".codex/config.toml"), "utf8");
    expect(config).toContain('command = "./scripts/start-factorio-mcp"');
    expect(config).toMatch(/\[mcp_servers\.factorio\][\s\S]*args = \[\][\s\S]*enabled = true/);
    expect(config).toMatch(/\[mcp_servers\.factorio-readonly\][\s\S]*args = \["--surface", "read-only"\][\s\S]*enabled = false/);
    expect(config).toContain(`enabled_tools = [${READ_ONLY_TOOLS.map((name) => `"${name}"`).join(", ")}]`);
    const launcher = fs.readFileSync(path.join(root, "scripts/start-factorio-mcp"), "utf8");
    expect(launcher).toContain('"$nvm_root/versions/node/v*/bin/node"');
    expect(launcher).not.toContain('source "$nvm_root/nvm.sh"');
    expect(launcher).not.toContain("nvm use --silent 22");
    expect(launcher).toMatch(/a === 22 && b >= 12/);
    expect(launcher).toMatch(/if \[\[ ! -x node_modules\/\.bin\/tsx \]\][\s\S]*"\$npm_bin" ci [^\n]*1>&2/);
    expect(launcher).toContain('exec "$node_bin" node_modules/.bin/tsx companion/src/cli.ts mcp "${surface_args[@]}"');
    expect(config).not.toMatch(/^cwd\s*=/m);
    expect(fs.existsSync(path.join(root, "mod/agentic-companion/settings.lua"))).toBe(false);
    const modSource = ["control.lua", "scripts/companion.lua", "locale/en/agentic-companion.cfg"]
      .map((file) => fs.readFileSync(path.join(root, "mod/agentic-companion", file), "utf8")).join("\n");
    expect(modSource).not.toMatch(/movement.speed|movement_speed|runtime_mod_setting/i);
  });

  it("keeps the player skill text-only and aligned with the two-brain MCP contract", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const skill = fs.readFileSync(path.join(root, ".agents/skills/factorio-player/SKILL.md"), "utf8");
    const normalizedSkill = skill.replace(/\s+/g, " ");
    const liveValidation = fs.readFileSync(path.join(root, "docs/LIVE-VALIDATION.md"), "utf8");
    expect(skill).toMatch(/run_plan/);
    expect(skill).toMatch(/build_plan/);
    expect(skill).toMatch(/MCP_GAP/);
    expect(skill).toMatch(/two persistent reasoning sessions[\s\S]*pilot[\s\S]*sole gameplay writer[\s\S]*strategist[\s\S]*long-horizon priorities/i);
    expect(skill).toMatch(/screenshots[\s\S]*never use[\s\S]*gameplay evidence|never use screenshots/i);
    expect(normalizedSkill).toMatch(/highest-payback capacity expansion.*satisfying only the next deficit is never the default/i);
    expect(skill).toContain("[player knowledge v1](PLAYER-KNOWLEDGE-v1.md)");
    expect(skill).toContain("GOAL-STRATEGIST-v1.md");
    expect(liveValidation).toMatch(/Prior-release 0\.7\.0 live evidence/);
    expect(liveValidation).toMatch(/Delivery is not consumption: a message counts as received only when its text\s+appears in a turn of the exact target session/);
    expect(liveValidation).toMatch(/The pilot's GO text names the strategist's exact thread ID/);
    expect(liveValidation).toMatch(/historical 0\.7\.0 evidence[\s\S]*not live validation of[\s\S]*0\.8\.0/);
    expect(liveValidation).toMatch(/gameplay pilot remains MCP-text-only[\s\S]*screenshot capability of any[\s\S]*must never be used for Factorio perception or play/i);
    expect(liveValidation).toMatch(/post-run screenshots are permitted only after the scored run is frozen[\s\S]*structured MCP evidence is insufficient[\s\S]*non-authoritative[\s\S]*must not contribute coordinates, routes, tactics, or[\s\S]*durable knowledge[\s\S]*revalidate every finding[\s\S]*structured in-game MCP data[\s\S]*does not authorize desktop GUI control of the game/i);
    expect(liveValidation).not.toMatch(/192\.168\.|DESKTOP-|Windows-MCP|couch-ui|VK-\d+/);
    expect(liveValidation).toMatch(/dedicated-server process arguments contain the RCON secret[\s\S]*never[\s\S]*`ps` full args[\s\S]*`\/proc` command-line[\s\S]*WMI `CommandLine`[\s\S]*user-service state, PID, executable basename, and `doctor`[\s\S]*secret-redacted/i);
    expect(liveValidation).toContain("%APPDATA%\\Factorio\\mods\\mod-list.json");
    expect(liveValidation).not.toContain("%APPDATA%\\Factorio\\mod-list.json");
  });

  it("keeps Candidate B historical and locks the player-knowledge boundary", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const benchmark = fs.readFileSync(path.join(root, "docs/AGENT-PLAY-PERFORMANCE.md"), "utf8");
    const knowledge = fs.readFileSync(path.join(root, ".agents/skills/factorio-player/PLAYER-KNOWLEDGE-v1.md"), "utf8");
    const normalizedKnowledge = knowledge.replace(/\s+/g, " ");
    expect(benchmark).toMatch(/Candidate B historically used exactly[\s\S]*Sol-medium read\/plan-only master[\s\S]*Terra-low\s+sole-writer pilot[\s\S]*Terra-low read-only specialist[\s\S]*fast mode off/i);
    expect(benchmark).toMatch(/superseded the earlier prospective wave matrix/i);
    expect(benchmark).not.toMatch(/\| W[123] —/);
    // The owner's unassisted standard: wiki-level mechanics, rates and ratios as facts, and generic principles; no guides.
    expect(normalizedKnowledge).toMatch(/Wiki-level mechanics in this repository's own words: recipes, crafting times, machine speeds, rates and ratios stated as facts, what technologies unlock and require, and fluid, power, belt, inserter and silo mechanics; plus generic planning principles with their reasons\. No guides: no step-by-step or opening sequences, build, research or planet orders, recommended counts for a run, layouts, map coordinates/);
    for (const forbidden of ["map coordinates", "tutorials", "external blueprint strings", "copied layouts", "online build sequences", "anything from earlier runs"])
      expect(normalizedKnowledge).toContain(forbidden);
    expect(normalizedKnowledge).toMatch(/overridable, never a build or technology order: measured state wins/);
    // Rates and machine-count ratios are wiki facts, stated as what keeps what busy, never as what to build.
    expect(normalizedKnowledge).toContain("1 boiler (1.8 MW) runs 2 steam engines");
    expect(normalizedKnowledge).toContain("Electric drill 0.5 ore/s, burner drill 0.25 ore/s, stone furnace 0.3125 plates/s");
    for (const ratio of ["One electric drill's ore keeps 1.6 stone furnaces busy (5 drills keep 8 furnaces busy)", "A full yellow belt carries the ore of 30 electric drills and keeps 48 stone furnaces busy", "Red science takes 5 s and green 6 s, so 5 assemblers making red make as many packs as 6 making green", "3 assemblers making copper cable keep 2 making electronic circuits busy", "Quality brings the edge no closer"])
      expect(normalizedKnowledge).toContain(ratio);
    expect(normalizedKnowledge).not.toMatch(/\b(?:build|place|use) \d+ (?:electric |burner |stone )?(?:drills?|furnaces?|assemblers?)/i);
    const agents = fs.readFileSync(path.join(root, "AGENTS.md"), "utf8").replace(/\s+/g, " ");
    expect(agents).toMatch(/The bots may have, in this repository's own words, anything the Factorio wiki explains about how the game works \(recipes, crafting times, machine speeds, rates and ratios stated as facts, what technologies unlock and require, fluid, power, belt, inserter and silo mechanics\), generic planning principles with their reasons, and the harness rules and tool contracts\. No guides: no step-by-step or opening sequences, build, research or planet orders, recommended counts for a run, layouts, coordinates, imported blueprint strings, or anything from earlier runs\./);
    expect(agents).not.toMatch(/overridable hints/);
    expect(agents).not.toMatch(/research-order hint/);
    // Future developer agents keep the mod and the instructions from doing the bots' thinking.
    expect(agents).toMatch(/Anything deterministic \(monitoring, supply, recoveries, layout arithmetic, upkeep\) belongs in the mod as a tool, not in the bots' instructions, never choices/);
    expect(agents).toMatch(/\*\*Enable thinking, never replace it\.\*\* The mod and the instructions let the bots show their thinking; they never do it for them/);
    expect(agents).toMatch(/The mod may execute a bot's decision \(walk, fetch, craft, clear, upkeep, recovery\), give honest player-visible information[\s\S]*and do deterministic arithmetic/);
    expect(agents).toMatch(/The mod never chooses a design, site, order, quantity or timing, and never grants free items or energy, or uncharted or cross-run map knowledge/);
    expect(agents).toMatch(/Instructions pass the same test: rules, mechanics, tool contracts, and principles with their reasons; never build, research or planet orders, opening scripts, fixed counts, layouts or coordinates/);
    expect(agents).toMatch(/Self-check: if a tool or passage lets a bot act well without deciding what, where, when or how many, it is doing the thinking/);
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
    expect(couchLauncher).toMatch(/\[Parameter\(Mandatory = \$true\)\]\[string\]\$Address,/);
    expect(couchLauncher).not.toMatch(/\d+\.\d+\.\d+\.\d+:34197/);
    expect(couchLauncher).toMatch(/Join-Path \$dataRoot "space-age"\) -PathType Container/);
    for (const name of ["elevated-rails", "quality", "space-age", "agentic-companion"]) {
      expect(couchLauncher).toContain(`{"name":"${name}","enabled":true}`);
    }
    expect(couchLauncher).toMatch(/--mp-connect[\s\S]*--force-graphics-preset extreme[\s\S]*--graphics-quality high[\s\S]*--video-memory-usage all[\s\S]*--window-size 3840x2160/);
    expect(couchLauncher).not.toMatch(/--force-graphics-preset very-low|--video-memory-usage low/);
    for (const key of ["graphics-quality=high", "video-memory-usage=all", "texture-compression-level=none", "high-quality-animations=true", "high-quality-shadows=true"])
      expect(couchLauncher).toMatch(new RegExp(`\\[graphics\\][\\s\\S]*${key}`));
    expect(couchLauncher).not.toContain("--window-size 640x480");
    expect(couchLauncher).not.toContain("--disable-audio");
    const readme = fs.readFileSync(path.join(root, "README.md"), "utf8");
    const liveValidation = fs.readFileSync(path.join(root, "docs/LIVE-VALIDATION.md"), "utf8");
    // The public README documents the isolated standalone Codex client, not one machine layout.
    expect(readme).toMatch(/standalone \(non-Steam\) Factorio build[\s\S]*launch-native-client\.ps1/);
    expect(liveValidation).toMatch(/no dedicated[\s\S]*GPU[\s\S]*permanently headless[\s\S]*Both visual Factorio processes run exclusively on the couch PC/);
  });

  it("keeps exactly one pilot and one read-only strategist prompt", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const skill = fs.readFileSync(path.join(root, ".agents/skills/factorio-player/SKILL.md"), "utf8");
    const pilot = fs.readFileSync(path.join(root, ".agents/skills/factorio-player/GOAL-PILOT-v1.md"), "utf8");
    expect(skill).toContain("](GOAL-PILOT-v1.md)");
    const strategist = fs.readFileSync(path.join(root, ".agents/skills/factorio-player/GOAL-STRATEGIST-v1.md"), "utf8");
    expect(fs.existsSync(path.join(root, ".agents/skills/factorio-player/GOAL-STRATEGIST-v1.md"))).toBe(true);
    expect(fs.existsSync(path.join(root, ".agents/skills/factorio-player/GOAL-MASTER-v1.md"))).toBe(false);
    expect(fs.existsSync(path.join(root, ".agents/skills/factorio-player/GOAL-SPECIALIST-v1.md"))).toBe(false);
    expect(`${skill}\n${pilot}`).toMatch(/gpt-6-luna[\s\S]*low[\s\S]*fast mode enabled/i);
    expect(strategist).toMatch(/gpt-6\.1-sol[\s\S]*medium[\s\S]*mechanically read-only/i);
    expect(`${skill}\n${pilot}\n${strategist}`).toMatch(/sole (?:Factorio )?(?:MCP|gameplay) writer[\s\S]*(?:the )?latest exact local state/i);
    expect(pilot).toMatch(/continuation is the default[\s\S]*progress report is not a completion or pause boundary/i);
    expect(pilot).toMatch(/highest-payback expansion[\s\S]*before another manual deficit batch/i);
    expect(pilot).toMatch(/exactly one physical MCP call may be in flight/i);
  });

  it("keeps every durable gameplay prompt semantic and route-free", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const files = ["SKILL.md", "GOAL-PILOT-v1.md", "GOAL-STRATEGIST-v1.md", "PLAYER-KNOWLEDGE-v1.md", "FACTORIO-REFERENCE.md"];
    const texts = files.map((file) => fs.readFileSync(path.join(root, ".agents/skills/factorio-player", file), "utf8"));
    for (const text of texts) {
      expect(text).not.toMatch(/\b(?:first|start by)\s+(?:mine|craft|place|build|research)\b/i);
      expect(text).not.toMatch(/\bthen\s+(?:mine|craft|place|build|research)\b/i);
      expect(text).not.toMatch(/\b(?:at|by|after)\s+(?:minute\s*)?\d+\s*(?:m|min|minutes?)?\s*[,,:-]?\s*(?:mine|craft|place|build|research)\b/i);
      expect(text).not.toMatch(/\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)/);
    }
    const combined = texts.join("\n");
    for (const rejected of [/(?:timed\s+phase|elapsed-time\s+milestone)/i, /fixed\s+build\s+order/i, /named\s+route/i, /(?:map|cross-run|world)\s+coordinate/i, /(?:prescribed technology order|prescriptive\s+progression\s+sequence)/i, /cop(?:y|ied) layouts/i, /tutorials/i, /online\s+(?:build\s+)?sequences/i])
      expect(combined).toMatch(rejected);
    expect(texts[0]).toMatch(/state-driven growth loop[\s\S]*observe fresh exact state[\s\S]*measured factory bottleneck/i);
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
    expect(joined).toMatch(/Candidate B historically used exactly[\s\S]*Sol-medium read\/plan-only master[\s\S]*Terra-low\s+sole-writer pilot[\s\S]*Terra-low read-only specialist[\s\S]*fast mode off/i);
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
    const candidate = performance.slice(performance.indexOf("### Historical Candidate B acceptance run"));
    expect(candidate).toMatch(/both graphical clients exclusively on the couch PC/i);
    expect(candidate).toMatch(/one Codex body[\s\S]*one FIFO lane/i);
  });

  it("requires bounded reuse discovery before greenfield gameplay code", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const agentGuide = fs.readFileSync(path.join(root, "AGENTS.md"), "utf8");
    const skill = fs.readFileSync(path.join(root, ".agents/skills/factorio-player/SKILL.md"), "utf8");
    // Engineering reuse is supervisor guidance: AGENTS.md owns it, the player skill does not repeat it.
    expect(skill).not.toMatch(/greenfield code/);
    for (const text of [agentGuide]) {
      const normalized = text.replace(/\s+/g, " ");
      expect(text).toMatch(/newly observed gameplay difficulty appears to require greenfield code[\s\S]*bounded Firecrawl reuse survey/i);
      expect(normalized).toMatch(/license,.*maintenance,.*current Factorio API compatibility,.*one-body\/one-writer\/\s*text-only physical fit/i);
      for (const risk of ["cheats", "uncharted map state", "raw console", "imported blueprints", "tutorial sequences"])
        expect(normalized.toLowerCase()).toContain(risk);
      expect(normalized).toMatch(/reuse or adapt the.*smallest maintained compatible path.*design evidence.*patch the smallest existing active path/i);
      expect(normalized).toMatch(/not a service, gate, or report workflow|do not create a.*service, gate, or report workflow/i);
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
