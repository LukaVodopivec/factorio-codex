import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { atomicWriteFile } from "./setup/atomic.js";

export interface RconSettings { host: string; port: number; password: string }
export interface AppConfig { factorioUserDir: string; rcon: RconSettings }
export interface Settings { rcon: RconSettings }
export type ConfigDiagnostic = { ok: true; config: AppConfig } | { ok: false; error: string };
export const configDir = () => path.join(os.homedir(), ".config", "factorio-codex");
export const configPath = () => path.join(configDir(), "config.json");
export const dataDir = () => process.env.XDG_DATA_HOME
  ? path.join(process.env.XDG_DATA_HOME, "factorio-codex")
  : path.join(os.homedir(), ".local", "share", "factorio-codex");
function exactConfig(value: unknown): value is AppConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const root = value as Record<string, unknown>;
  if (Object.keys(root).sort().join(",") !== "factorioUserDir,rcon" || typeof root.factorioUserDir !== "string" || !root.factorioUserDir) return false;
  if (!root.rcon || typeof root.rcon !== "object" || Array.isArray(root.rcon)) return false;
  const rcon = root.rcon as Record<string, unknown>;
  return Object.keys(rcon).sort().join(",") === "host,password,port" && rcon.host === "127.0.0.1" && rcon.port === 19015 && typeof rcon.password === "string" && rcon.password.length > 0;
}
function readRawConfig(): unknown { try { return JSON.parse(fs.readFileSync(configPath(), "utf8")); } catch { return null; } }
export function loadConfig(): AppConfig | null { const value = readRawConfig(); return exactConfig(value) ? value : null; }
export function diagnoseConfig(): ConfigDiagnostic {
  if (!fs.existsSync(configPath())) return { ok: false, error: "configuration is missing; run `factorio-codex setup`" };
  const config = loadConfig();
  if (!config) return { ok: false, error: "configuration is invalid; run `factorio-codex setup`" };
  const mode = fs.statSync(configPath()).mode & 0o777;
  if (mode !== 0o600) return { ok: false, error: `configuration mode is ${mode.toString(8)}; expected 600; run setup again` };
  try {
    if (!fs.statSync(config.factorioUserDir).isDirectory()) throw new Error("not a directory");
  } catch {
    return { ok: false, error: "configured Factorio user-data directory is missing; launch Factorio once, then run setup again" };
  }
  return { ok: true, config };
}
export function existingRconPassword(): string | undefined { const value = readRawConfig() as { rcon?: { password?: unknown } } | null; return typeof value?.rcon?.password === "string" && value.rcon.password.length > 0 ? value.rcon.password : undefined; }
export function saveConfig(config: AppConfig): void { fs.mkdirSync(configDir(), { recursive: true }); atomicWriteFile(configPath(), `${JSON.stringify(config, null, 2)}\n`, 0o600); }
export function resolveSettings(): Settings { const cfg = loadConfig(); return { rcon: cfg?.rcon ?? { host: "127.0.0.1", port: 19015, password: "" } }; }
export function packageRoot(): string { let dir = path.dirname(fileURLToPath(import.meta.url)); for (let i = 0; i < 6; i++) { const pkg = path.join(dir, "package.json"); try { if (JSON.parse(fs.readFileSync(pkg, "utf8")).name === "factorio-codex") return dir; } catch {} const parent = path.dirname(dir); if (parent === dir) break; dir = parent; } return path.dirname(path.dirname(fileURLToPath(import.meta.url))); }
// Identify loaded code: an in-place upgrade must not let an old bridge
// authenticate as the new release when its RCON connection is recreated.
export function companionVersion(): string { return "0.36.0"; }
