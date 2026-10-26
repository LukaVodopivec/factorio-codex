import fs from "node:fs";
import os from "node:os";
import net from "node:net";
import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MAP_GEN_SETTINGS, SERVER_SETTINGS, createArgs, prepareMods, runPaths, serverPid, startArgs, startServer, currentRunPointer } from "../src/server/server.js";

import { companionVersion } from "../src/config.js";
import { PROTOCOL_VERSION } from "../src/protocol/contract.js";

const startup = vi.hoisted(() => ({ config: { factorioUserDir: "unused", rcon: { host: "127.0.0.1", port: 0, password: "fixture-password" } } }));
vi.mock("../src/config.js", async (original) => ({ ...await original() as typeof import("../src/config.js"), loadConfig: () => startup.config }));
vi.mock("node:child_process", async (original) => {
  const actual = await original() as typeof import("node:child_process");
  return { ...actual, spawn: vi.fn(actual.spawn) };
});
const dirs: string[] = [];
const tempDir = () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-server-test-"));
  dirs.push(dir);
  return dir;
};
afterEach(async () => {
  for (const result of vi.mocked(spawn).mock.results) {
    const child = result.value as ChildProcess | undefined;
    if (!child?.pid || child.exitCode !== null || child.signalCode !== null) continue;
    const exited = once(child, "exit");
    child.kill("SIGKILL");
    await exited;
  }
  vi.mocked(spawn).mockClear();
  vi.unstubAllEnvs();
  dirs.splice(0).forEach((dir) => fs.rmSync(dir, { recursive: true, force: true }));
});

describe("run-local server lifecycle", () => {
  it("installs the companion beside the full Space Age mod set", () => {
    const mods = path.join(tempDir(), "mods");
    prepareMods(mods);
    const list = JSON.parse(fs.readFileSync(path.join(mods, "mod-list.json"), "utf8")).mods as { name: string; enabled: boolean }[];
    for (const name of ["base", "elevated-rails", "quality", "space-age", "agentic-companion"]) {
      expect(list.find((mod) => mod.name === name)?.enabled).toBe(true);
    }
    expect(fs.existsSync(path.join(mods, "agentic-companion", "info.json"))).toBe(true);
  });

  it("re-enables expansion mods that an existing list disabled", () => {
    const mods = path.join(tempDir(), "mods");
    fs.mkdirSync(mods);
    fs.writeFileSync(path.join(mods, "mod-list.json"), JSON.stringify({ mods: [{ name: "base", enabled: true }, { name: "space-age", enabled: false }] }));
    prepareMods(mods);
    const list = JSON.parse(fs.readFileSync(path.join(mods, "mod-list.json"), "utf8")).mods as { name: string; enabled: boolean }[];
    expect(list.filter((mod) => mod.name === "space-age")).toEqual([{ name: "space-age", enabled: true }]);
  });

  it("generates a peaceful world without enemies", () => {
    expect(MAP_GEN_SETTINGS.peaceful_mode).toBe(true);
    expect(MAP_GEN_SETTINGS.no_enemies_mode).toBe(true);
    expect(MAP_GEN_SETTINGS.autoplace_controls["enemy-base"].frequency).toBe(0);
  });

  it("autosaves every 30 minutes, since a save blocks every client's frames", () => {
    expect(SERVER_SETTINGS.autosave_interval).toBe(30);
  });

  it("keeps every server path inside the run directory and binds RCON to loopback only", () => {
    const paths = runPaths(tempDir());
    expect(createArgs(paths)).toEqual(["--create", paths.save, "--map-gen-settings", paths.mapGen, "--mod-directory", paths.mods]);
    for (const bind of [undefined, "10.0.0.5"]) {
      const args = startArgs(paths, "secret", bind);
      expect(args).not.toContain("--disable-audio");
      expect(args).toEqual(["--start-server", paths.save, "--server-settings", paths.serverSettings,
        "--mod-directory", paths.mods, ...(bind ? ["--bind", bind] : []), "--port", "34197",
        "--rcon-bind", "127.0.0.1:19015", "--rcon-password", "secret"]);
    }
  });

  it("only trusts a recorded pid that is a factorio executable running in this run directory", () => {
    const paths = runPaths(tempDir());
    fs.writeFileSync(paths.pid, "4242\n");
    expect(serverPid(paths, () => ({ exe: "/opt/Factorio/bin/x64/factorio", cwd: paths.dir }))).toBe(4242);
    expect(serverPid(paths, () => ({ exe: "/opt/Factorio/bin/x64/factorio", cwd: "/srv/elsewhere" }))).toBeNull();
    expect(serverPid(paths, () => ({ exe: "/usr/bin/bash", cwd: paths.dir }))).toBeNull();
    expect(serverPid(paths, () => { throw new Error("gone"); })).toBeNull();
  });
});

// The executable fixture uses only a disposable loopback listener and files in
// its own run. No installed Factorio, real configuration or gameplay port.
async function startupRun(mode = "ready", overrides: Record<string, unknown> = {}) {
  const dir = tempDir();
  const reservation = net.createServer();
  await new Promise<void>((resolve) => reservation.listen(0, "127.0.0.1", resolve));
  const port = (reservation.address() as net.AddressInfo).port;
  await new Promise<void>((resolve, reject) => reservation.close((error) => error ? reject(error) : resolve()));
  const settings = { port, mode, password: startup.config.rcon.password, protocol: PROTOCOL_VERSION, version: companionVersion(), ...overrides };
  const fixture = path.join(dir, "factorio");
  fs.writeFileSync(fixture, `#!${process.execPath}\n${fs.readFileSync(new URL("fixtures/server.cjs", import.meta.url), "utf8")}`, { mode: 0o700 });
  fs.writeFileSync(path.join(dir, "fixture.json"), JSON.stringify(settings));
  fs.writeFileSync(runPaths(dir).save, "fixture save");
  startup.config.rcon.port = settings.port;
  vi.stubEnv("XDG_DATA_HOME", tempDir());
  fs.mkdirSync(path.dirname(currentRunPointer()), { recursive: true });
  return { dir, fixture, port: settings.port, paths: runPaths(dir) };
}

function lastChild() { return vi.mocked(spawn).mock.results.at(-1)!.value as ChildProcess; }
function expectSettled(dir: string) {
  expect(lastChild().exitCode !== null || lastChild().signalCode !== null).toBe(true);
  expect(fs.existsSync(runPaths(dir).pid)).toBe(false);
}

async function foreignRun(overrides: Record<string, unknown> = {}) {
  const run = await startupRun("ready", overrides);
  const child = spawn(run.fixture, [], { cwd: run.dir, stdio: "ignore" });
  await vi.waitFor(() => expect(fs.existsSync(path.join(run.dir, "listening"))).toBe(true));
  fs.writeFileSync(run.paths.pid, `${child.pid}\n`);
  return { ...run, child };
}

describe("owned startup readiness", () => {
  it("publishes only a live owned compatible server and preserves result fields", async () => {
    const run = await startupRun();
    const result = await startServer(run.dir, { factorio: run.fixture, readyTimeoutMs: 2000 });
    expect(result).toEqual({ pid: lastChild().pid, save: run.paths.save, log: run.paths.log,
      factorio_version: "2.0.fixture", mod_version: companionVersion(), protocol_version: PROTOCOL_VERSION });
    expect(fs.readFileSync(currentRunPointer(), "utf8")).toBe(`${run.dir}\n`);
    expect(fs.readFileSync(run.paths.pid, "utf8")).toBe(`${result.pid}\n`);
    expect(lastChild().exitCode).toBeNull();
    await vi.waitFor(() => expect(fs.readFileSync(path.join(run.dir, "commands"), "utf8")).toContain('"ping"'));
  });

  it("rejects after the conflicting child exits even when the foreign endpoint returns a compatible reply", async () => {
    const a = await foreignRun({ authDelayMs: 700 });
    const b = await startupRun("conflict", { port: a.port });
    fs.writeFileSync(currentRunPointer(), `${a.dir}\n`);
    await expect(startServer(b.dir, { factorio: b.fixture, readyTimeoutMs: 2000 })).rejects.toThrow(/exited/);
    expect(lastChild().exitCode).toBe(24);
    expect(fs.readFileSync(currentRunPointer(), "utf8")).toBe(`${a.dir}\n`);
    expect(a.child.exitCode).toBeNull();
    expect(fs.existsSync(path.join(a.dir, "commands"))).toBe(false);
    expectSettled(b.dir);
  });

  it("handles asynchronous spawn failure without an unhandled error", async () => {
    const run = await startupRun();
    await expect(startServer(run.dir, { factorio: path.join(run.dir, "missing"), readyTimeoutMs: 1000 })).rejects.toThrow(/spawn|start/);
    expect(fs.existsSync(run.paths.pid)).toBe(false);
    expect(fs.existsSync(currentRunPointer())).toBe(false);
  });

  it("rejects an early child exit promptly", async () => {
    const run = await startupRun("exit");
    const started = Date.now();
    await expect(startServer(run.dir, { factorio: run.fixture, readyTimeoutMs: 5000 })).rejects.toThrow(/exited/);
    expect(Date.now() - started).toBeLessThan(2000);
    expectSettled(run.dir);
  });

  it.each(["wait", "auth-stall", "ping-stall"])("bounds %s startup and settles its child", async (mode) => {
    const run = await startupRun(mode);
    fs.writeFileSync(currentRunPointer(), "retained run\n");
    const started = Date.now();
    await expect(startServer(run.dir, { factorio: run.fixture, readyTimeoutMs: 500 })).rejects.toThrow(/timeout/);
    expect(Date.now() - started).toBeLessThan(2000);
    expect(fs.readFileSync(currentRunPointer(), "utf8")).toBe("retained run\n");
    expectSettled(run.dir);
  });

  it.each([{ protocol: -1 }, { version: "incompatible" }])("cleans up an owned incompatible server: %j", async (incompatible) => {
    const run = await startupRun("ready", incompatible);
    fs.writeFileSync(currentRunPointer(), "retained run\n");
    await expect(startServer(run.dir, { factorio: run.fixture, readyTimeoutMs: 2000 })).rejects.toThrow(/protocol|version/);
    expect(fs.readFileSync(currentRunPointer(), "utf8")).toBe("retained run\n");
    expect(fs.readFileSync(path.join(run.dir, "commands"), "utf8")).not.toContain("server-save");
    expectSettled(run.dir);
  });

  it("never unlocks or saves an incompatible foreign endpoint", async () => {
    const a = await foreignRun({ protocol: -1 });
    const b = await startupRun("wait", { port: a.port });
    fs.writeFileSync(currentRunPointer(), `${a.dir}\n`);
    await expect(startServer(b.dir, { factorio: b.fixture, readyTimeoutMs: 1500 })).rejects.toThrow(/does not belong/);
    expect(fs.existsSync(path.join(a.dir, "commands"))).toBe(false);
    expect(fs.readFileSync(currentRunPointer(), "utf8")).toBe(`${a.dir}\n`);
    expect(a.child.exitCode).toBeNull();
    expectSettled(b.dir);
  });

  it("rejects a compatible foreign endpoint while the conflicting child is still alive", async () => {
    const a = await foreignRun();
    const b = await startupRun("conflict", { port: a.port, conflictDelayMs: 2000 });
    fs.writeFileSync(currentRunPointer(), `${a.dir}\n`);
    await expect(startServer(b.dir, { factorio: b.fixture, readyTimeoutMs: 1500 })).rejects.toThrow(/does not belong/);
    expect(lastChild().signalCode).toBe("SIGKILL");
    expect(lastChild().exitCode).toBeNull();
    expect(fs.readFileSync(currentRunPointer(), "utf8")).toBe(`${a.dir}\n`);
    expect(a.child.exitCode).toBeNull();
    expect(a.child.signalCode).toBeNull();
    expect(fs.readFileSync(a.paths.pid, "utf8")).toBe(`${a.child.pid}\n`);
    expect(fs.existsSync(path.join(a.dir, "commands"))).toBe(false);
    expectSettled(b.dir);
  });
});
