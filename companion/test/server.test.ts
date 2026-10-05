import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { MAP_GEN_SETTINGS, SERVER_SETTINGS, createArgs, prepareMods, runPaths, serverPid, startArgs } from "../src/server/server.js";

const dirs: string[] = [];
const tempDir = () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-server-test-"));
  dirs.push(dir);
  return dir;
};
afterEach(() => dirs.splice(0).forEach((dir) => fs.rmSync(dir, { recursive: true, force: true })));

describe("run-local server lifecycle", () => {
  it("installs the companion beside the full Space Age mod set", () => {
    const mods = path.join(tempDir(), "mods");
    prepareMods(mods);
    const list = JSON.parse(fs.readFileSync(path.join(mods, "mod-list.json"), "utf8")).mods as { name: string; enabled: boolean }[];
    for (const name of ["base", "elevated-rails", "quality", "space-age", "agentic-companion"]) {
      expect(list.find((mod) => mod.name === name)?.enabled).toBe(true);
    }
    expect(fs.existsSync(path.join(mods, "agentic-companion", "info.json"))).toBe(true);
  });

  it("re-enables expansion mods that an existing list disabled", () => {
    const mods = path.join(tempDir(), "mods");
    fs.mkdirSync(mods);
    fs.writeFileSync(path.join(mods, "mod-list.json"), JSON.stringify({ mods: [{ name: "base", enabled: true }, { name: "space-age", enabled: false }] }));
    prepareMods(mods);
    const list = JSON.parse(fs.readFileSync(path.join(mods, "mod-list.json"), "utf8")).mods as { name: string; enabled: boolean }[];
    expect(list.filter((mod) => mod.name === "space-age")).toEqual([{ name: "space-age", enabled: true }]);
  });

  it("generates a peaceful world without enemies", () => {
    expect(MAP_GEN_SETTINGS.peaceful_mode).toBe(true);
    expect(MAP_GEN_SETTINGS.no_enemies_mode).toBe(true);
    expect(MAP_GEN_SETTINGS.autoplace_controls["enemy-base"].frequency).toBe(0);
  });

  it("autosaves every 30 minutes, since a save blocks every client's frames", () => {
    expect(SERVER_SETTINGS.autosave_interval).toBe(30);
  });

  it("keeps every server path inside the run directory and binds RCON to loopback only", () => {
    const paths = runPaths(tempDir());
    expect(createArgs(paths)).toEqual(["--create", paths.save, "--map-gen-settings", paths.mapGen, "--mod-directory", paths.mods]);
    const args = startArgs(paths, "secret");
    expect(args).not.toContain("--bind");
    expect(args).toEqual(expect.arrayContaining(["--mod-directory", paths.mods, "--rcon-bind", "127.0.0.1:19015"]));
    expect(startArgs(paths, "secret", "10.0.0.5")).toEqual(expect.arrayContaining(["--bind", "10.0.0.5"]));
  });

  it("only trusts a recorded pid that is a factorio executable running in this run directory", () => {
    const paths = runPaths(tempDir());
    fs.writeFileSync(paths.pid, "4242\n");
    expect(serverPid(paths, () => ({ exe: "/opt/Factorio/bin/x64/factorio", cwd: paths.dir }))).toBe(4242);
    expect(serverPid(paths, () => ({ exe: "/opt/Factorio/bin/x64/factorio", cwd: "/home/elsewhere" }))).toBeNull();
    expect(serverPid(paths, () => ({ exe: "/usr/bin/bash", cwd: paths.dir }))).toBeNull();
    expect(serverPid(paths, () => { throw new Error("gone"); })).toBeNull();
  });
});
