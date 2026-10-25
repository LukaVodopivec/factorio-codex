// A real process is killed by the parent after writing a checkpoint. Only
// RCON/configuration and time are mocked; persistence and the kernel lock are real.
import fs from "node:fs";
import { mock } from "node:test";
import { performance } from "node:perf_hooks";
import { Bridge } from "../../src/bridge.js";
import { RconClient } from "../../src/rcon.js";
import { companionVersion, configPath } from "../../src/config.js";
import { PROTOCOL_VERSION } from "../../src/protocol/contract.js";
import { recordRun } from "../../src/runs/telemetry.js";

const [ledger, root, rollout, originText] = process.argv.slice(2) as [string, string, string, string];
const origin = Number(originText);
mock.timers.enable({ apis: ["Date", "setTimeout", "setInterval"], now: origin });
mock.method(performance, "now", () => Date.now() - origin);
const read = fs.readFileSync;
mock.method(fs, "readFileSync", (file: unknown, ...args: unknown[]) => file === configPath()
  ? JSON.stringify({ factorioUserDir: root, rcon: { host: "127.0.0.1", port: 19015, password: "test" } })
  : Reflect.apply(read, fs, [file, ...args]));
mock.method(RconClient.prototype, "connect", async () => {});
mock.method(RconClient.prototype, "close", () => {});
mock.method(Bridge.prototype, "call", async (method: string) => {
  if (method === "ping") return { protocol_version: PROTOCOL_VERSION, mod_version: companionVersion(), factorio_version: "2.0.77", companion_exists: true };
  if (method === "run_snapshot") return { tick: 100 + (Date.now() - origin) / 10, character: {}, progression: {}, factory: {},
    statistics: { items: { produced: [{ name: "iron-ore", count: 5 + (Date.now() - origin) / 1000 }], consumed: [] },
      fluids: { produced: [], consumed: [] }, raw_resources: [{ type: "item", name: "iron-ore" }],
      semantics: { produced: "force_surface_input_counts", consumed: "force_surface_output_counts" } } };
  if (method === "say" || method === "say_now") return {};
  throw new Error(`unexpected RPC ${method}`);
});
let ready!: () => void;
const started = new Promise<void>(resolve => { ready = resolve; });
mock.method(console, "log", (message: unknown) => { if (String(message).startsWith("GO ")) ready(); });
// Keep IPC alive until the parent kills this recorder, without finalization.
process.on("message", () => {});
void recordRun({ ledger, root, kind: "debug", variant: "loss", change: "loss", pilotRollout: rollout })
  .catch(error => { process.send?.({ error: String(error) }); process.exitCode = 1; });
await started;
fs.appendFileSync(rollout, `${JSON.stringify({ timestamp: new Date().toISOString(), type: "response_item",
  payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "persisted before loss" }] } })}\n`);
mock.timers.tick(300_000);
await new Promise<void>(resolve => setImmediate(resolve));
process.send?.({ checkpoint: true });
