// Shared lifecycle for opt-in disposable native tests. Owns only the server it
// spawns; every run has separate data, mods, save, ports and RCON credentials.
import { spawn, type ChildProcess } from "node:child_process";
import crypto from "node:crypto";
import dgram from "node:dgram";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { Bridge } from "../src/bridge.js";
import { RconClient } from "../src/rcon.js";
import { MAP_GEN_SETTINGS, SERVER_SETTINGS, createArgs, prepareMods, runPaths } from "../src/server/server.js";

const freeTcpPort = () => new Promise<number>((resolve, reject) => {
  const server = net.createServer().once("error", reject);
  server.listen(0, "127.0.0.1", () => {
    const { port } = server.address() as net.AddressInfo;
    server.close(() => resolve(port));
  });
});
const freeUdpPort = () => new Promise<number>((resolve, reject) => {
  const socket = dgram.createSocket("udp4").once("error", reject);
  socket.bind(0, "127.0.0.1", () => { const { port } = socket.address(); socket.close(() => resolve(port)); });
});

export class LiveHarness {
  readonly dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-live-"));
  readonly paths = runPaths(this.dir);
  private child: ChildProcess | null = null;
  rcon: RconClient | null = null;
  private cleaning: Promise<void> | undefined;

  constructor(private readonly bin: string, private readonly seed: number) {}

  async start({ save, prepare }: { save?: string; prepare?: (modDir: string) => void } = {}): Promise<Bridge> {
    const configIni = path.join(this.dir, "config.ini");
    if (!save) {
      fs.writeFileSync(configIni, `[path]\nread-data=__PATH__executable__/../../data\nwrite-data=${this.dir}\n`);
      prepareMods(this.paths.mods);
      prepare?.(path.join(this.paths.mods, "agentic-companion"));
      fs.writeFileSync(this.paths.mapGen, JSON.stringify({ ...MAP_GEN_SETTINGS, seed: this.seed }));
      fs.writeFileSync(this.paths.serverSettings, JSON.stringify({ ...SERVER_SETTINGS,
        description: "Factorio Codex live smoke suite", visibility: { public: false, lan: false }, auto_pause: false }));
      const create = this.child = spawn(this.bin, ["-c", configIni, ...createArgs(this.paths)],
        { stdio: ["ignore", "pipe", "pipe"] });
      let output = "";
      create.stdout!.on("data", (chunk) => { output += chunk; });
      create.stderr!.on("data", (chunk) => { output += chunk; });
      const status = await new Promise<number | null>((resolve, reject) => create.once("error", reject).once("close", resolve));
      if (status !== 0 || !fs.existsSync(this.paths.save)) {
        throw new Error(`factorio --create failed (exit ${status}): ${output.trim().split("\n").slice(-5).join(" | ")}`);
      }
    }
    if (this.cleaning) throw new Error("interrupted");
    const password = crypto.randomBytes(12).toString("hex");
    const gamePort = await freeUdpPort(), rconPort = await freeTcpPort();
    if (this.cleaning) throw new Error("interrupted");
    const log = fs.openSync(this.paths.log, "a");
    const child = this.child = spawn(this.bin, ["-c", configIni, "--start-server", save ?? this.paths.save,
      "--server-settings", this.paths.serverSettings, "--mod-directory", this.paths.mods,
      "--bind", "127.0.0.1", "--port", String(gamePort), "--rcon-bind", `127.0.0.1:${rconPort}`,
      "--rcon-password", password], { cwd: this.dir, stdio: ["ignore", log, log] });
    fs.closeSync(log);
    for (const deadline = Date.now() + 180_000; ; await sleep(1000)) {
      if (this.cleaning) throw new Error("interrupted");
      if (child.exitCode !== null || child.signalCode !== null) throw new Error(`server exited: ${this.logTail()}`);
      const client = new RconClient({ host: "127.0.0.1", port: rconPort, password, timeoutMs: 20_000 });
      try {
        await client.connect();
        const bridge = new Bridge(client);
        await bridge.unlock();
        this.rcon = client;
        return bridge;
      } catch (error) {
        client.close();
        if (!(error instanceof Error) || !/cannot connect to RCON|auth timed out|ECONNRESET|closed/i.test(error.message)) throw error;
        if (Date.now() > deadline) throw new Error(`server did not accept RCON in 180 s: ${String(error)}`);
      }
    }
  }

  logTail(): string {
    try { return fs.readFileSync(this.paths.log, "utf8").trim().split("\n").slice(-5).join(" | "); }
    catch { return "(no log)"; }
  }

  // Used for actual save/reload tests, without deleting the owned directory.
  async stop(): Promise<void> {
    this.rcon?.close();
    this.rcon = null;
    const child = this.child;
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
      child.kill("SIGINT");
      const timer = new AbortController();
      try {
        if (!await Promise.race([exited.then(() => true), sleep(30_000, false, { signal: timer.signal })])) {
          child.kill("SIGKILL");
          await exited;
        }
      } finally { timer.abort(); }
    }
    this.child = null;
  }

  cleanup(): Promise<void> {
    return this.cleaning ??= this.stop().then(() => { fs.rmSync(this.dir, { recursive: true, force: true }); });
  }

  // Setup/analysis console access remains confined to this disposable test
  // server; production MCP never exposes it.
  async lua<T = any>(body: string): Promise<T> {
    const code = body.split("\n").map((line) => line.trim()).filter(Boolean).join(" ");
    if (code.includes("--")) throw new Error("scenario Lua must not contain -- (one console line)");
    const prelude = 'local function mod(n) return package.loaded["__agentic-companion__/scripts/" .. n .. ".lua"] end local rpc = mod("rpc")';
    const raw = (await this.rcon!.exec(`/silent-command __agentic-companion__ ${prelude} local ok,res=pcall(function() ${code} end)`
      + ' rcon.print(rpc.to_json({ok=ok,result=ok and res or nil,error=not ok and tostring(res) or nil}))')).trim();
    let reply: { ok: boolean; result?: T; error?: string };
    try { reply = JSON.parse(raw); } catch { throw new Error(`console reply is not JSON: ${raw.slice(0, 300)}`); }
    if (!reply.ok) throw new Error(`Lua error: ${reply.error}`);
    return reply.result as T;
  }
}
