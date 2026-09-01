import { describe, expect, it } from "vitest";
import { PROTOCOL_VERSION, RPC_METHODS, assertProtocolCompatibility, parseRpcEnvelope } from "../src/protocol/contract.js";

describe("bridge protocol v5", () => {
  it("has the expected version and retained methods", () => {
    expect(PROTOCOL_VERSION).toBe(5);
    expect(RPC_METHODS).toContain("observe_local");
    expect(RPC_METHODS).toContain("enqueue");
    expect(RPC_METHODS).not.toContain("take_screenshot");
  });
  it("validates normal, error, and chunk envelopes", () => {
    expect(parseRpcEnvelope('{"ok":true,"data":{"tick":1}}')).toMatchObject({ ok: true });
    expect(parseRpcEnvelope('{"ok":false,"error":"nope"}')).toEqual({ ok: false, error: "nope" });
    expect(parseRpcEnvelope('{"ok":true,"chunked":true,"id":1,"parts":2,"data":"x"}')).toMatchObject({ chunked: true, parts: 2 });
  });
  it("rejects mismatched mods", () => expect(() => assertProtocolCompatibility({ protocol_version: 4 })).toThrow("protocol mismatch"));
});
