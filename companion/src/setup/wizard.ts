import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import * as p from "@clack/prompts";
import { configPath, existingRconPassword, saveConfig } from "../config.js";
import { patchRconConfig } from "./configini.js";
import { installMod } from "./installMod.js";
import { factorioConfigPath, factorioUserDir, modsDir } from "./locate.js";
import { setupTransaction } from "./transaction.js";

export async function runWizard(): Promise<void> {
  p.intro("factorio-codex setup");
  let userDir = factorioUserDir();
  if (!userDir) {
    const answer = await p.text({ message: "Factorio user-data folder (contains config/ and mods/)", validate: (v) => v && fs.existsSync(v) ? undefined : "Directory not found" });
    if (p.isCancel(answer)) { p.cancel("Setup cancelled; no changes made."); return; }
    userDir = answer;
  }
  const password = existingRconPassword() || crypto.randomBytes(24).toString("hex");
  const rcon = { host: "127.0.0.1", port: 19015, password };
  const ini = factorioConfigPath(userDir); const mods = modsDir(userDir); const modDest = path.join(mods, "agentic-companion");
  try {
    setupTransaction([ini, `${ini}.agentic-bak`, path.join(mods, "mod-list.json"), modDest, configPath()], () => {
      patchRconConfig(ini, rcon); installMod(mods); saveConfig({ factorioUserDir: userDir, rcon });
    });
  } catch (error) { const raw = error instanceof Error ? error.message : String(error); p.cancel(`Setup failed; previous files restored. ${raw.split(password).join("[redacted]")}`); process.exitCode = 1; return; }
  p.log.success("Configured loopback RCON on port 19015, installed the mod, and saved mode-0600 settings.");
  p.note("Restart Factorio, enable the mod, host a dedicated save, then run `factorio-codex doctor`.", "Next steps");
  p.outro("Setup complete.");
}
