// Finds the Factorio user-data directory (config + mods live under it).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/** Standard per-OS Factorio user-data dir, or null if it doesn't exist
 *  (custom install location, or Factorio never started). */
export function factorioUserDir(): string | null {
  let candidate: string;
  switch (process.platform) {
    case "darwin":
      candidate = path.join(os.homedir(), "Library", "Application Support", "factorio");
      break;
    case "win32":
      candidate = path.join(process.env.APPDATA ?? path.join(os.homedir(), "AppData", "Roaming"), "Factorio");
      break;
    default:
      candidate = path.join(os.homedir(), ".factorio");
      break;
  }
  try {
    return fs.statSync(candidate).isDirectory() ? candidate : null;
  } catch {
    return null;
  }
}

/** Factorio executable: FACTORIO_BIN, then the standard Linux Steam installs. */
export function factorioBinary(): string | null {
  const candidates = [
    process.env.FACTORIO_BIN,
    path.join(os.homedir(), ".steam", "debian-installation", "steamapps", "common", "Factorio", "bin", "x64", "factorio"),
    path.join(os.homedir(), ".local", "share", "Steam", "steamapps", "common", "Factorio", "bin", "x64", "factorio"),
    path.join(os.homedir(), ".steam", "steam", "steamapps", "common", "Factorio", "bin", "x64", "factorio"),
  ];
  for (const candidate of candidates) {
    if (!candidate) continue;
    try {
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {
      // try next
    }
  }
  return null;
}

export function factorioConfigPath(userDir: string): string {
  return path.join(userDir, "config", "config.ini");
}

export function modsDir(userDir: string): string {
  return path.join(userDir, "mods");
}
