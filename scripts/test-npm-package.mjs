import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-npm-pack-"));

function run(command, args, cwd = repo) {
  const result = spawnSync(command, args, { cwd, env: process.env, stdio: "inherit" });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} ${args.join(" ")} failed`);
}

try {
  const packed = path.join(temp, "packed");
  const installed = path.join(temp, "installed");
  fs.mkdirSync(packed);
  fs.mkdirSync(installed);
  fs.writeFileSync(path.join(installed, "package.json"), '{"private":true}\n');

  run("npm", ["pack", "-w", "companion", "--ignore-scripts=false", "--pack-destination", packed]);
  const tarballs = fs.readdirSync(packed).filter((name) => name.endsWith(".tgz"));
  assert.deepEqual(tarballs.length, 1, "npm pack must produce exactly one tarball");
  run("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", path.join(packed, tarballs[0])], installed);

  const packageDir = path.join(installed, "node_modules", "factorio-codex");
  const bundledInfo = JSON.parse(fs.readFileSync(path.join(packageDir, "assets", "agentic-companion", "info.json"), "utf8"));
  assert.equal(bundledInfo.name, "agentic-companion");
  assert.equal(bundledInfo.version, "0.7.0");

  const { installMod } = await import(pathToFileURL(path.join(packageDir, "dist", "setup", "installMod.js")));
  const mods = path.join(temp, "factorio-user-data", "mods");
  const result = installMod(mods);
  assert.equal(result.copied, true);
  assert.equal(JSON.parse(fs.readFileSync(path.join(result.dest, "info.json"), "utf8")).name, "agentic-companion");
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(mods, "mod-list.json"), "utf8")).mods.at(-1), {
    name: "agentic-companion",
    enabled: true,
  });
  assert.equal(fs.existsSync(path.join(repo, "companion", "assets")), false, "postpack must clean staged package assets");
  console.log("PASS clean npm pack, isolated install, bundled mod source, and installMod setup gate");
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
