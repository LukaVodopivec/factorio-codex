import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { atomicWriteFile } from "./setup/atomic.js";

export interface RconSettings { host: string; port: number; password: string }
export interface AppConfig { factorioUserDir?: string; rcon?: Partial<RconSettings> }
export interface Settings { rcon: RconSettings }
export const configDir = () => path.join(os.homedir(), ".config", "factorio-codex");
export const configPath = () => path.join(configDir(), "config.json");
export function loadConfig(): AppConfig | null { try { const value: unknown = JSON.parse(fs.readFileSync(configPath(), "utf8")); return value && typeof value === "object" && !Array.isArray(value) ? value as AppConfig : null; } catch { return null; } }
export function saveConfig(config: AppConfig): void { fs.mkdirSync(configDir(), { recursive: true }); atomicWriteFile(configPath(), `${JSON.stringify(config, null, 2)}\n`, 0o600); }
export function resolveSettings(): Settings { const cfg = loadConfig(); return { rcon: { host: cfg?.rcon?.host ?? "127.0.0.1", port: cfg?.rcon?.port ?? 19015, password: cfg?.rcon?.password ?? "" } }; }
export function packageRoot(): string { let dir = path.dirname(fileURLToPath(import.meta.url)); for (let i = 0; i < 6; i++) { const pkg = path.join(dir, "package.json"); try { if (JSON.parse(fs.readFileSync(pkg, "utf8")).name === "factorio-codex") return dir; } catch {} const parent = path.dirname(dir); if (parent === dir) break; dir = parent; } return path.dirname(path.dirname(fileURLToPath(import.meta.url))); }
export function companionVersion(): string { try { return JSON.parse(fs.readFileSync(path.join(packageRoot(), "package.json"), "utf8")).version ?? "0.0.0"; } catch { return "0.0.0"; } }
