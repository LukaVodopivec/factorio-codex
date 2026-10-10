import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Bridge, ModError } from "../src/bridge.js";
import { companionVersion, configPath, diagnoseConfig, saveConfig } from "../src/config.js";
import { createBridgeProvider, MCP_SERVER_VERSION } from "../src/mcp/server.js";
import type { RconClient } from "../src/rcon.js";

const settings = { host: "127.0.0.1", port: 19015, password: "secret" };

class FakeRcon extends EventEmitter {
  connected = false;
  connect = vi.fn(async () => { this.connected = true; });
  close = vi.fn(() => { this.connected = false; this.emit("close"); });
}

function deferred() {
  let resolve!: () => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<void>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

const homes: string[] = [];

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  homes.splice(0).forEach((home) => fs.rmSync(home, { recursive: true, force: true }));
});

describe("lazy MCP bridge connection", () => {
  it("rejects an upgraded mod on reconnect even when package metadata on disk changed", async () => {
    const loadedVersion = companionVersion();
    const first = new FakeRcon();
    const upgraded = new FakeRcon();
    const retry = new FakeRcon();
    const factory = vi.fn()
      .mockReturnValueOnce(first as unknown as RconClient)
      .mockReturnValueOnce(upgraded as unknown as RconClient)
      .mockReturnValueOnce(retry as unknown as RconClient);
    vi.spyOn(Bridge.prototype, "unlock").mockResolvedValue();
    const ping = vi.spyOn(Bridge.prototype, "call").mockResolvedValue({ protocol_version: 29, mod_version: loadedVersion });
    const getBridge = createBridgeProvider(settings, factory);
    await expect(getBridge()).resolves.toBeInstanceOf(Bridge);
    first.close();

    // Simulate an in-place checkout/package upgrade after these modules loaded.
    const readFile = fs.readFileSync;
    vi.spyOn(fs, "readFileSync").mockImplementation(((file: any, ...args: any[]) =>
      String(file).endsWith("/package.json")
        ? JSON.stringify({ name: "factorio-codex", version: "99.0.0" })
        : (readFile as any)(file, ...args)) as any);
    ping.mockResolvedValue({ protocol_version: 29, mod_version: "99.0.0" });
    await expect(getBridge()).rejects.toThrow(`mod v99.0.0, app v${loadedVersion}`);
    expect(upgraded.close).toHaveBeenCalledOnce();
    expect(companionVersion()).toBe(loadedVersion);
    expect(MCP_SERVER_VERSION).toBe(loadedVersion);

    ping.mockResolvedValue({ protocol_version: 29, mod_version: loadedVersion });
    await expect(getBridge()).resolves.toBeInstanceOf(Bridge);
    retry.close();
  });

  it("recovers in-process when setup creates a valid config after offline startup", async () => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-lazy-config-test-"));
    homes.push(home);
    vi.stubEnv("HOME", home);
    const rcon = new FakeRcon();
    const factory = vi.fn(() => rcon as unknown as RconClient);
    vi.spyOn(Bridge.prototype, "unlock").mockResolvedValue();
    vi.spyOn(Bridge.prototype, "call").mockResolvedValue({ protocol_version: 29, mod_version: "0.38.0" });
    const getBridge = createBridgeProvider(diagnoseConfig, factory);

    await expect(getBridge()).rejects.toThrow("configuration is missing");
    expect(factory).not.toHaveBeenCalled();

    const factorioUserDir = path.join(home, "factorio");
    fs.mkdirSync(factorioUserDir);
    saveConfig({ factorioUserDir, rcon: settings });
    expect(fs.statSync(configPath()).mode & 0o777).toBe(0o600);

    await expect(getBridge()).resolves.toBeInstanceOf(Bridge);
    expect(factory).toHaveBeenCalledOnce();
    expect(factory).toHaveBeenCalledWith(settings);
  });

  it("singleflights concurrent first calls onto one RCON handshake", async () => {
    const ready = deferred();
    const rcon = new FakeRcon();
    rcon.connect.mockImplementation(async () => { await ready.promise; rcon.connected = true; });
    const factory = vi.fn(() => rcon as unknown as RconClient);
    vi.spyOn(Bridge.prototype, "unlock").mockResolvedValue();
    vi.spyOn(Bridge.prototype, "call").mockResolvedValue({ protocol_version: 29, mod_version: "0.38.0" });
    const getBridge = createBridgeProvider(settings, factory);

    const first = getBridge();
    const second = getBridge();
    expect(factory).toHaveBeenCalledTimes(1);
    expect(rcon.connect).toHaveBeenCalledTimes(1);
    ready.resolve();
    const [a, b] = await Promise.all([first, second]);
    expect(a).toBe(b);
  });

  it("reuses one connected Bridge across 25 sequential handler-style acquisitions", async () => {
    const rcon = new FakeRcon();
    const factory = vi.fn(() => rcon as unknown as RconClient);
    const unlock = vi.spyOn(Bridge.prototype, "unlock").mockResolvedValue();
    const call = vi.spyOn(Bridge.prototype, "call").mockResolvedValue({
      protocol_version: 29,
      mod_version: "0.38.0",
    });
    const getBridge = createBridgeProvider(settings, factory);

    const acquired: Bridge[] = [];
    for (let index = 0; index < 25; index += 1) {
      acquired.push(await getBridge());
    }

    expect(acquired).toHaveLength(25);
    expect(acquired.every((bridge) => bridge === acquired[0])).toBe(true);
    expect(factory).toHaveBeenCalledTimes(1);
    expect(rcon.connect).toHaveBeenCalledTimes(1);
    expect(unlock).toHaveBeenCalledTimes(1);
    expect(call).toHaveBeenCalledTimes(1);
    expect(call).toHaveBeenCalledWith("ping");
  });

  it("ignores a stale socket close after a replacement becomes healthy", async () => {
    const first = new FakeRcon();
    const second = new FakeRcon();
    const factory = vi.fn()
      .mockReturnValueOnce(first as unknown as RconClient)
      .mockReturnValueOnce(second as unknown as RconClient);
    vi.spyOn(Bridge.prototype, "unlock").mockResolvedValue();
    vi.spyOn(Bridge.prototype, "call").mockResolvedValue({ protocol_version: 29, mod_version: "0.38.0" });
    const getBridge = createBridgeProvider(settings, factory);

    await getBridge();
    first.connected = false;
    const healthy = await getBridge();
    first.emit("close");
    expect(await getBridge()).toBe(healthy);
    expect(factory).toHaveBeenCalledTimes(2);
  });

  it.each(["connect", "unlock", "protocol", "mod"] as const)("closes the candidate after a failed %s handshake", async (stage) => {
    const failed = new FakeRcon();
    const retry = new FakeRcon();
    const factory = vi.fn()
      .mockReturnValueOnce(failed as unknown as RconClient)
      .mockReturnValueOnce(retry as unknown as RconClient);
    if (stage === "connect") failed.connect.mockRejectedValue(new Error("connect failed"));
    vi.spyOn(Bridge.prototype, "unlock").mockImplementation(async function () {
      if (stage === "unlock" && (this as any).rcon === failed) throw new ModError("unlock failed");
    });
    vi.spyOn(Bridge.prototype, "call").mockImplementation(async function () {
      if (stage === "protocol" && (this as any).rcon === failed) return { protocol_version: 6, mod_version: "0.38.0" };
      if (stage === "mod" && (this as any).rcon === failed) return { protocol_version: 29, mod_version: "0.6.0" };
      return { protocol_version: 29, mod_version: "0.38.0" };
    });
    const getBridge = createBridgeProvider(settings, factory);

    await expect(getBridge()).rejects.toThrow();
    expect(failed.close).toHaveBeenCalledTimes(1);
    await expect(getBridge()).resolves.toBeInstanceOf(Bridge);
    expect(factory).toHaveBeenCalledTimes(2);
  });

  it.each([
    { host: "192.0.2.10", port: 19015, password: "secret" },
    { host: "127.0.0.1", port: 19016, password: "secret" },
  ])("rejects non-canonical RCON config before opening a socket: $host:$port", async (invalid) => {
    const factory = vi.fn();
    const getBridge = createBridgeProvider(invalid, factory);
    await expect(getBridge()).rejects.toThrow("RCON must use 127.0.0.1:19015");
    expect(factory).not.toHaveBeenCalled();
  });
});
