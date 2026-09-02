import { Bridge } from "./bridge.js";
import { companionVersion, diagnoseConfig, type Settings } from "./config.js";
import { EXPECTED_RCON_HOST, EXPECTED_RCON_PORT, connectionCompatibility, type PingIdentity } from "./compatibility.js";
import { PROTOCOL_VERSION } from "./protocol/contract.js";
import { RconClient } from "./rcon.js";

export interface DoctorCheck { name: string; ok: boolean; detail: string; fix?: string }
export interface DoctorReport { ok: boolean; app_version: string; rcon: { host: string; port: number; password_configured: boolean }; checks: DoctorCheck[] }
export async function collectDoctorReport(settings: Settings): Promise<DoctorReport> {
  const checks: DoctorCheck[] = []; const diagnostic = diagnoseConfig();
  checks.push(diagnostic.ok
    ? { name: "config", ok: true, detail: "exact shape, mode 0600, Factorio user-data directory exists" }
    : { name: "config", ok: false, detail: diagnostic.error, fix: diagnostic.error.includes("launch Factorio") ? "launch Factorio once, then run setup again" : "run `factorio-codex setup`" });
  if (!diagnostic.ok) return finish();
  const endpoint = connectionCompatibility(settings.rcon);
  checks.push(endpoint.endpoint ? { name: "rcon-config", ok: true, detail: `${EXPECTED_RCON_HOST}:${EXPECTED_RCON_PORT}` } : { name: "rcon-config", ok: false, detail: `must be ${EXPECTED_RCON_HOST}:${EXPECTED_RCON_PORT}`, fix: "run setup again" });
  if (!endpoint.endpoint) return finish();
  const rcon = new RconClient(settings.rcon);
  try {
    try {
      await rcon.connect();
      checks.push({ name: "rcon", ok: true, detail: "authenticated" });
    } catch (error) {
      checks.push({ name: "rcon", ok: false, detail: redact(error), fix: "start Factorio with RCON enabled and verify the configured password" });
      return finish();
    }

    const bridge = new Bridge(rcon);
    let ping: PingIdentity;
    try {
      await bridge.unlock();
      ping = await bridge.call("ping");
    } catch (error) {
      checks.push({ name: "mod", ok: false, detail: `RPC unavailable: ${redact(error)}`, fix: `install and enable Factorio Codex Companion v${companionVersion()}, then host the save` });
      return finish();
    }

    const compatible = connectionCompatibility(settings.rcon, ping, companionVersion());
    checks.push({ name: "protocol", ok: compatible.protocol === true, detail: `mod v${ping.protocol_version}, app v${PROTOCOL_VERSION}`, ...compatible.protocol === true ? {} : { fix: `install Factorio Codex Companion v${companionVersion()} and restart Factorio` } });
    checks.push({ name: "mod", ok: compatible.mod === true, detail: `mod v${ping.mod_version}, app v${companionVersion()}`, ...compatible.mod === true ? {} : { fix: `install Factorio Codex Companion v${companionVersion()} and restart Factorio` } });
  } finally {
    rcon.close();
  }
  return finish();
  function redact(error: unknown): string { const raw = error instanceof Error ? error.message : "connection failed"; return settings.rcon.password ? raw.split(settings.rcon.password).join("[redacted]") : raw; }
  function finish(): DoctorReport { return { ok: checks.every((c) => c.ok), app_version: companionVersion(), rcon: { host: settings.rcon.host, port: settings.rcon.port, password_configured: settings.rcon.password.length > 0 }, checks }; }
}
export async function runDoctor(settings: Settings, options: { json?: boolean } = {}): Promise<void> { const report = await collectDoctorReport(settings); if (options.json) console.log(JSON.stringify(report, null, 2)); else for (const c of report.checks) console.log(`${c.ok ? "✓" : "✗"} ${c.name}: ${c.detail}${c.fix ? `\n  fix: ${c.fix}` : ""}`); if (!report.ok) process.exitCode = 1; }
