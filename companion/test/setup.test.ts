import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { patchRconConfig } from "../src/setup/configini.js";
import { setupTransaction } from "../src/setup/transaction.js";
import { installMod } from "../src/setup/installMod.js";
import { atomicWriteFile } from "../src/setup/atomic.js";

const dirs: string[] = [];
const tempDir = () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-setup-test-"));
  dirs.push(dir);
  return dir;
};
afterEach(() => dirs.splice(0).forEach((dir) => fs.rmSync(dir, { recursive: true, force: true })));

describe("setup transaction", () => {
  it("rolls files and directories back when a later step fails", () => {
    const root = tempDir();
    const file = path.join(root, "config.ini");
    const mod = path.join(root, "mods", "agentic-companion");
    fs.mkdirSync(mod, { recursive: true });
    fs.writeFileSync(file, "original\n");
    fs.writeFileSync(path.join(mod, "old.lua"), "old");

    expect(() => setupTransaction([file, mod], () => {
      fs.writeFileSync(file, "changed\n");
      fs.rmSync(mod, { recursive: true });
      fs.mkdirSync(mod, { recursive: true });
      fs.writeFileSync(path.join(mod, "new.lua"), "new");
      throw new Error("late failure");
    })).toThrow("late failure");

    expect(fs.readFileSync(file, "utf8")).toBe("original\n");
    expect(fs.readFileSync(path.join(mod, "old.lua"), "utf8")).toBe("old");
    expect(fs.existsSync(path.join(mod, "new.lua"))).toBe(false);
  });

  it("commits all changes after success", () => {
    const file = path.join(tempDir(), "new.txt");
    setupTransaction([file], () => fs.writeFileSync(file, "committed"));
    expect(fs.readFileSync(file, "utf8")).toBe("committed");
  });
});

describe("atomicWriteFile", () => {
  it("replaces an existing file directly and preserves the requested mode", () => {
    const file = path.join(tempDir(), "state.json");
    fs.writeFileSync(file, "old", { mode: 0o644 });
    atomicWriteFile(file, "new", 0o600);
    expect(fs.readFileSync(file, "utf8")).toBe("new");
    expect(fs.statSync(file).mode & 0o777).toBe(0o600);
    expect(fs.readdirSync(path.dirname(file))).toEqual(["state.json"]);
  });
});

describe("patchRconConfig", () => {
  it("keeps a mode-0600 config private while adding the RCON secret", () => {
    const file = path.join(tempDir(), "config.ini");
    fs.writeFileSync(file, "[other]\n");
    fs.chmodSync(file, 0o600);
    patchRconConfig(file, { port: 19015, password: "secret" });
    expect(fs.readFileSync(file, "utf8")).toContain("local-rcon-password=secret");
    expect(fs.statSync(file).mode & 0o777).toBe(0o600);
  });

  it("tightens a mode-0664 config while adding the RCON secret", () => {
    const file = path.join(tempDir(), "config.ini");
    fs.writeFileSync(file, "[other]\n");
    fs.chmodSync(file, 0o664);
    expect(patchRconConfig(file, { port: 19015, password: "secret" }).changed).toBe(true);
    expect(fs.readFileSync(file, "utf8")).toContain("local-rcon-password=secret");
    expect(fs.statSync(file).mode & 0o777).toBe(0o600);
  });

  it("tightens mode even when the RCON contents already match", () => {
    const file = path.join(tempDir(), "config.ini");
    const contents = "[other]\nlocal-rcon-socket=127.0.0.1:19015\nlocal-rcon-password=secret\n";
    fs.writeFileSync(file, contents);
    fs.chmodSync(file, 0o664);
    expect(patchRconConfig(file, { port: 19015, password: "secret" }).changed).toBe(true);
    expect(fs.readFileSync(file, "utf8")).toBe(contents);
    expect(fs.statSync(file).mode & 0o777).toBe(0o600);
    expect(patchRconConfig(file, { port: 19015, password: "secret" }).changed).toBe(false);
  });

  it("is idempotent and preserves CRLF", () => {
    const file = path.join(tempDir(), "config.ini");
    fs.writeFileSync(file, "[other]\r\n; local-rcon-socket=old\r\n");
    expect(patchRconConfig(file, { port: 19015, password: "secret" }).changed).toBe(true);
    const once = fs.readFileSync(file, "utf8");
    expect(once).toContain("local-rcon-password=secret\r\n");
    expect(patchRconConfig(file, { port: 19015, password: "secret" }).changed).toBe(false);
    expect(fs.readFileSync(file, "utf8")).toBe(once);
  });
});

describe("mod installation", () => {
  it("installs the retained repository mod and enables it", () => {
    const mods = path.join(tempDir(), "mods");
    const installed = installMod(mods);
    expect(installed.copied).toBe(true);
    expect(JSON.parse(fs.readFileSync(path.join(installed.dest, "info.json"), "utf8"))).toMatchObject({ name: "agentic-companion", version: "0.29.2" });
    expect(JSON.parse(fs.readFileSync(path.join(mods, "mod-list.json"), "utf8")).mods).toContainEqual({ name: "agentic-companion", enabled: true });
  });
});
