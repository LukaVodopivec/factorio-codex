// Deterministic headless server lifecycle for one run directory: a run-local
// Space Age mod set, a fresh peaceful save, start with a protocol check, and a
// saving stop. The run directory owns every file, so stale global mods and
// hard-coded LAN addresses never leak into a run.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { Bridge } from "../bridge.js";
import { assertRuntimeCompatibility } from "../compatibility.js";
import { companionVersion, dataDir, loadConfig } from "../config.js";
import { RconClient } from "../rcon.js";
import { atomicWriteFile } from "../setup/atomic.js";
import { installMod } from "../setup/installMod.js";
import { factorioBinary } from "../setup/locate.js";

/** Space Age requires quality and elevated-rails; all four ship with the game. */
export const BUILT_IN_MODS = ["base", "elevated-rails", "quality", "space-age"] as const;
export const GAME_PORT = 34197;

const rich = { frequency: 1.5, size: 3, richness: 3 };
/** Nauvis generation used by prior supervised runs: rich ore, no enemies. Other planets keep their defaults. */
export const MAP_GEN_SETTINGS = {
  autoplace_controls: {
    coal: rich, "copper-ore": rich, "crude-oil": rich, "iron-ore": rich, "uranium-ore": rich,
    stone: { frequency: 2, size: 6, richness: 6 },
    trees: { frequency: 0.6666666865348816, size: 0.5, richness: 1 },
    "enemy-base": { frequency: 0, size: 0, richness: 0 },
  },
  default_enable_all_autoplace_controls: true,
  starting_area: 6,
  peaceful_mode: true,
  no_enemies_mode: true,
  cliff_settings: { name: "cliff", cliff_elevation_0: 10, cliff_elevation_interval: 40, richness: 0 },
  water: 6,
} as const;
export const SERVER_SETTINGS = {
  name: "Factorio Codex",
  description: "Supervised Factorio Codex run",
  visibility: { public: false, lan: true },
  max_players: 2,
  require_user_verification: false,
  auto_pause: true,
  // Minutes. A save blocks every client for 50-85 ms; keep it rare.
  autosave_interval: 30,
  autosave_slots: 2,
} as const;

export interface RunPaths { dir: string; mods: string; save: string; mapGen: string; serverSettings: string; log: string; pid: string }
export function runPaths(runDir: string): RunPaths {
  const dir = path.resolve(runDir);
  return { dir, mods: path.join(dir, "mods"), save: path.join(dir, "save.zip"), mapGen: path.join(dir, "map-gen-settings.json"),
    serverSettings: path.join(dir, "server-settings.json"), log: path.join(dir, "server.log"), pid: path.join(dir, "server.pid") };
}

/** Install the companion into the run-local mods dir and enable the Space Age set beside it. */
export function prepareMods(modsDir: string): void {
  installMod(modsDir);
  const listPath = path.join(modsDir, "mod-list.json");
  const { mods } = JSON.parse(fs.readFileSync(listPath, "utf8")) as { mods: { name: string; enabled: boolean }[] };
  for (const name of BUILT_IN_MODS) {
    const entry = mods.find((mod) => mod.name === name);
    if (entry) entry.enabled = true; else mods.push({ name, enabled: true });
  }
  atomicWriteFile(listPath, `${JSON.stringify({ mods }, null, 2)}\n`);
}

export function createArgs(paths: RunPaths): string[] {
  return ["--create", paths.save, "--map-gen-settings", paths.mapGen, "--mod-directory", paths.mods];
}
export function startArgs(paths: RunPaths, password: string, bind?: string): string[] {
  return ["--start-server", paths.save, "--server-settings", paths.serverSettings, "--mod-directory", paths.mods,
    ...(bind ? ["--bind", bind] : []), "--port", String(GAME_PORT), "--rcon-bind", "127.0.0.1:19015",
    "--rcon-password", password];
}

function requireBinary(explicit?: string): string {
  const bin = explicit ?? factorioBinary();
  if (!bin) throw new Error("Factorio executable not found; pass --factorio <path> or set FACTORIO_BIN");
  return bin;
}
function requireConfig() {
  const config = loadConfig();
  if (!config) throw new Error("configuration is missing or invalid; run `factorio-codex setup`");
  return config;
}

export function createServerSave(runDir: string, options: { factorio?: string; seed?: number } = {}): RunPaths {
  const paths = runPaths(runDir), bin = requireBinary(options.factorio);
  if (fs.existsSync(paths.save)) throw new Error(`refusing to overwrite existing save ${paths.save}`);
  fs.mkdirSync(paths.dir, { recursive: true, mode: 0o700 });
  prepareMods(paths.mods);
  atomicWriteFile(paths.mapGen, `${JSON.stringify({ ...MAP_GEN_SETTINGS, ...(options.seed === undefined ? {} : { seed: options.seed }) }, null, 2)}\n`);
  if (!fs.existsSync(paths.serverSettings)) atomicWriteFile(paths.serverSettings, `${JSON.stringify(SERVER_SETTINGS, null, 2)}\n`);
  const log = fs.openSync(path.join(paths.dir, "create.log"), "w");
  try {
    const result = spawnSync(bin, createArgs(paths), { stdio: ["ignore", log, log] });
    if (result.status !== 0 || !fs.existsSync(paths.save)) throw new Error(`factorio --create failed (exit ${result.status}); see ${path.join(paths.dir, "create.log")}`);
  } finally { fs.closeSync(log); }
  return paths;
}

export interface ProcessIdentity { exe: string; cwd: string }
const procIdentity = (pid: number): ProcessIdentity => ({ exe: fs.readlinkSync(`/proc/${pid}/exe`), cwd: fs.readlinkSync(`/proc/${pid}/cwd`) });
/** The recorded pid is ours only while it is a factorio executable running in this run directory.
 *  Its arguments carry the RCON secret and are never read. */
export function serverPid(paths: RunPaths, identify: (pid: number) => ProcessIdentity = procIdentity): number | null {
  let pid: number;
  try { pid = Number(fs.readFileSync(paths.pid, "utf8").trim()); } catch { return null; }
  if (!Number.isInteger(pid) || pid <= 0) return null;
  try {
    const { exe, cwd } = identify(pid);
    return path.basename(exe) === "factorio" && path.resolve(cwd) === paths.dir ? pid : null;
  } catch { return null; }
}

/** The run directory `server start` last launched; its ledger feeds the MCP bridge's orders. */
export const currentRunPointer = () => path.join(dataDir(), "current-run");
/** That run directory while its recorded server is running, else null. */
export function currentRunDir(identify: (pid: number) => ProcessIdentity = procIdentity): string | null {
  let dir: string;
  try { dir = fs.readFileSync(currentRunPointer(), "utf8").trim(); } catch { return null; }
  if (!dir) return null;
  const paths = runPaths(dir);
  return serverPid(paths, identify) ? paths.dir : null;
}

async function waitForExit(pid: number, timeoutMs: number): Promise<boolean> {
  for (const deadline = Date.now() + timeoutMs; Date.now() < deadline; await sleep(500)) {
    try { process.kill(pid, 0); } catch { return true; }
  }
  return false;
}

/** Match the accepted IPv4 loopback socket, not just a listener or a live PID.
 * /proc/<pid>/net/tcp is namespace-wide; only the child's fd inode proves ownership.
 * This lifecycle already uses Linux /proc for PID identity. Never read cmdline. */
function ownsRconConnection(pid: number, localPort: number | undefined, serverPort: number): boolean {
  if (localPort === undefined) return false;
  const endpoint = (port: number) => `0100007F:${port.toString(16).toUpperCase().padStart(4, "0")}`;
  try {
    const sockets = new Set(fs.readdirSync(`/proc/${pid}/fd`).flatMap((fd) => {
      try { return [fs.readlinkSync(`/proc/${pid}/fd/${fd}`)]; } catch { return []; }
    }));
    return fs.readFileSync(`/proc/${pid}/net/tcp`, "utf8").trim().split("\n").slice(1).some((row) => {
      const fields = row.trim().split(/\s+/);
      return fields[1] === endpoint(serverPort) && fields[2] === endpoint(localPort)
        && fields[3] === "01" && sockets.has(`socket:[${fields[9]}]`);
    });
  } catch { return false; }
}

export async function startServer(runDir: string, options: { factorio?: string; bind?: string; readyTimeoutMs?: number } = {}) {
  const paths = runPaths(runDir), config = requireConfig(), bin = requireBinary(options.factorio);
  if (!fs.existsSync(paths.save)) throw new Error(`no save at ${paths.save}; run \`factorio-codex server create ${runDir}\` first`);
  if (serverPid(paths)) throw new Error(`a server for ${paths.dir} is already running`);
  const log = fs.openSync(paths.log, "a");
  let child;
  try { child = spawn(bin, startArgs(paths, config.rcon.password, options.bind), { cwd: paths.dir, detached: true, stdio: ["ignore", log, log] }); }
  finally { fs.closeSync(log); }
  let failure: Error | undefined;
  let fail!: (error: Error) => void;
  const failed = new Promise<never>((_, reject) => { fail = (error) => { failure ??= error; reject(failure); }; });
  const exited = new Promise<void>((resolve) => {
    child.once("error", () => { fail(new Error(`factorio failed to spawn; see ${paths.log}`)); resolve(); });
    child.once("exit", (code, signal) => { fail(new Error(`factorio exited during startup (${signal ?? code}); see ${paths.log}`)); resolve(); });
  });
  const timeoutMs = options.readyTimeoutMs ?? 180_000;
  const timer = setTimeout(() => fail(new Error(`server did not accept RCON within the timeout; see ${paths.log}`)), timeoutMs);
  const rcon = new RconClient({ ...config.rcon, timeoutMs });
  const assertLive = () => {
    if (failure) throw failure;
    if (!child.pid || child.exitCode !== null || child.signalCode !== null) throw new Error(`factorio exited during startup; see ${paths.log}`);
  };
  const ready = async () => {
    if (!child.pid) await failed;
    for (;;) {
      assertLive();
      try {
        await rcon.connect();
        assertLive();
        if (!ownsRconConnection(child.pid!, rcon.localPort, config.rcon.port)) {
          throw new Error("RCON endpoint does not belong to the spawned server");
        }
        const bridge = new Bridge(rcon);
        await bridge.unlock();
        assertLive();
        const ping = await bridge.call<{ protocol_version?: number; mod_version?: string; factorio_version?: string }>("ping");
        assertLive();
        assertRuntimeCompatibility(ping, companionVersion());
        if (!ownsRconConnection(child.pid!, rcon.localPort, config.rcon.port)) throw new Error("spawned server lost its RCON connection during startup");
        return ping;
      } catch (error) {
        assertLive();
        if (!(error instanceof Error) || !/cannot connect to RCON|auth timed out|ECONNRESET|closed/i.test(error.message)) throw error;
      } finally { rcon.close(); }
      await sleep(100, undefined, { signal: retry.signal });
    }
  };
  const retry = new AbortController();
  let pidWritten = false;
  try {
    const ping = await Promise.race([ready(), failed]);
    assertLive();
    atomicWriteFile(paths.pid, `${child.pid}\n`, 0o600);
    pidWritten = true;
    atomicWriteFile(currentRunPointer(), `${paths.dir}\n`);
    child.unref();
    return { pid: child.pid, save: paths.save, log: paths.log, factorio_version: ping.factorio_version, mod_version: ping.mod_version, protocol_version: ping.protocol_version };
  } catch (error) {
    // Only our ChildProcess handle may be signalled. An unverified endpoint must
    // never be saved, unlocked or stopped, even when compatibility checks fail.
    rcon.close();
    if (child.pid && child.exitCode === null && child.signalCode === null) {
      if (!child.kill("SIGKILL")) throw new Error("could not settle spawned server after startup failure", { cause: error });
      const cleanup = new AbortController();
      try {
        await Promise.race([exited, sleep(5000, undefined, { signal: cleanup.signal }).then(() => {
          throw new Error("spawned server did not exit after startup failure", { cause: error });
        })]);
      } finally { cleanup.abort(); }
    }
    if (pidWritten && fs.existsSync(paths.pid) && fs.readFileSync(paths.pid, "utf8").trim() === String(child.pid)) fs.rmSync(paths.pid);
    throw error;
  } finally {
    clearTimeout(timer);
    retry.abort();
    rcon.close();
  }
}

/** Start, read or stop the mod's 4K timelapse; the frames are written by the connected Codex client. */
export async function serverTimelapse(action: "start" | "status" | "stop", folder?: string): Promise<unknown> {
  const rcon = new RconClient(requireConfig().rcon);
  try {
    await rcon.connect();
    const bridge = new Bridge(rcon);
    await bridge.unlock();
    return await bridge.call("timelapse", action === "start" ? { action, folder } : { action });
  } finally { rcon.close(); }
}

/** Save over RCON, then interrupt the headless server and wait for it to exit. */
export async function stopServer(runDir: string): Promise<{ stopped: boolean; saved: boolean }> {
  const paths = runPaths(runDir), pid = serverPid(paths);
  if (!pid) return { stopped: false, saved: false };
  let saved = false;
  const config = loadConfig();
  if (config) {
    const rcon = new RconClient(config.rcon);
    try { await rcon.connect(); await rcon.exec("/server-save"); saved = true; await sleep(2000); } catch { /* still stop */ } finally { rcon.close(); }
  }
  process.kill(pid, "SIGINT");
  if (!(await waitForExit(pid, 60_000))) throw new Error(`server ${pid} did not exit within 60s`);
  fs.rmSync(paths.pid, { force: true });
  return { stopped: true, saved };
}
