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
    { ping: { protocol_version: 4, mod_version: "0.7.0" }, failedCheck: "protocol" },
    { ping: { protocol_version: 5, mod_version: "0.6.0" }, failedCheck: "mod" },
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
  it("keeps root, package, lockfile, runtime, and mod versions at 0.7.0", () => {
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
    ]).toEqual(Array(7).fill("0.7.0"));
    expect(fs.readFileSync(path.join(root, "README.md"), "utf8")).toContain("Current release: **0.7.0**");
    expect(fs.readFileSync(path.join(root, "docs/LIVE-VALIDATION.md"), "utf8")).toContain("release **0.7.0**");
  });
  it("keeps visible locale title and description aligned with one-body mod metadata", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const info = JSON.parse(fs.readFileSync(path.join(root, "mod/agentic-companion/info.json"), "utf8"));
    const locale = fs.readFileSync(path.join(root, "mod/agentic-companion/locale/en/agentic-companion.cfg"), "utf8");
    const values = [...locale.matchAll(/^agentic-companion=(.+)$/gm)].map((match) => match[1]);
    expect(info).toMatchObject({ version: "0.7.0", title: "Factorio Codex Companion" });
    expect(values).toEqual([info.title, info.description]);
    expect(locale).toContain("agentic-companion-movement-speed=Codex movement speed");
    expect(locale).toContain("sole Codex character");
    expect(locale).not.toMatch(/Agentic Companion|AI companion|companions|characters|vehicles/i);
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
