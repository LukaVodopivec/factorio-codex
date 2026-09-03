import { describe, expect, it } from "vitest";
import { assertNodeRuntime, nodeMajor, nodeRuntimeDiagnostic } from "../src/runtime.js";

describe("Node runtime preflight", () => {
  it("accepts Node 22 and newer", () => {
    expect(nodeMajor("22.0.0")).toBe(22);
    expect(nodeRuntimeDiagnostic("22.10.0")).toEqual({ ok: true, detail: "Node 22.10.0" });
    expect(nodeRuntimeDiagnostic("24.1.0").ok).toBe(true);
  });

  it("fails early with an actionable diagnostic on older Node releases", () => {
    expect(nodeRuntimeDiagnostic("20.20.2")).toEqual({
      ok: false,
      detail: "Node 20.20.2 is unsupported",
      fix: "activate Node 22 or newer before running factorio-codex",
    });
    expect(() => assertNodeRuntime("20.20.2")).toThrow(/Node 20\.20\.2 is unsupported.*Node 22 or newer/);
  });
});
