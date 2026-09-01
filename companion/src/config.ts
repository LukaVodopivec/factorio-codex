import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { atomicWriteFile } from "./setup/atomic.js";

export interface RconSettings { host: string; port: number; password: string }
export interface AppConfig { factorioUserDir: string; rcon: RconSettings }
export interface Settings { rcon: RconSettings }
export const configDir = () => path.join(os.homedir(), ".config", "factorio-codex");
export const configPath = () => path.join(configDir(), "config.json");
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
export function existingRconPassword(): string | undefined { const value = readRawConfig() as { rcon?: { password?: unknown } } | null; return typeof value?.rcon?.password === "string" && value.rcon.password.length > 0 ? value.rcon.password : undefined; }
export function saveConfig(config: AppConfig): void { fs.mkdirSync(configDir(), { recursive: true }); atomicWriteFile(configPath(), `${JSON.stringify(config, null, 2)}\n`, 0o600); }
export function resolveSettings(): Settings { const cfg = loadConfig(); return { rcon: cfg?.rcon ?? { host: "127.0.0.1", port: 19015, password: "" } }; }
export function packageRoot(): string { let dir = path.dirname(fileURLToPath(import.meta.url)); for (let i = 0; i < 6; i++) { const pkg = path.join(dir, "package.json"); try { if (JSON.parse(fs.readFileSync(pkg, "utf8")).name === "factorio-codex") return dir; } catch {} const parent = path.dirname(dir); if (parent === dir) break; dir = parent; } return path.dirname(path.dirname(fileURLToPath(import.meta.url))); }
export function companionVersion(): string { try { return JSON.parse(fs.readFileSync(path.join(packageRoot(), "package.json"), "utf8")).version ?? "0.0.0"; } catch { return "0.0.0"; } }
