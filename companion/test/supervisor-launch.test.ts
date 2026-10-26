import fs from "node:fs";
import { afterEach, expect, it, vi } from "vitest";
import type { Bridge } from "../src/bridge.js";
import { registerMcpTools } from "../src/mcp/server.js";

const { start } = vi.hoisted(() => ({ start: vi.fn() }));
vi.mock("../src/mcp/server.js", async (importOriginal) => ({
  ...await importOriginal<typeof import("../src/mcp/server.js")>(),
  runMcpServer: start,
}));

const originalArgv = process.argv;
afterEach(() => { process.argv = originalArgv; vi.unstubAllEnvs(); vi.clearAllMocks(); });

it("carries the documented supervisor launch through CLI role selection into both stop payloads", async () => {
  const readme = fs.readFileSync(new URL("../../README.md", import.meta.url), "utf8");
  const section = readme.split("### 5. ")[1]!.split("### 6. ")[0]!;
  const override = section.match(/codex -c 'mcp_servers\.factorio=(\{[^'\n]+\})'/)![1]!;
  expect(override).toContain('command="./scripts/start-factorio-mcp"');
  expect(override).toContain("enabled=true");
  const args = JSON.parse(override.match(/args=(\[[^\]]*\])/)![1]!) as string[];
  expect(args).toEqual(["--role", "supervisor"]);

  // An inherited role must not override the supervisor's explicit CLI argument.
  vi.stubEnv("FACTORIO_CODEX_ROLE", "pilot");
  process.argv = [originalArgv[0]!, "companion/src/cli.ts", "mcp", ...args];
  vi.resetModules();
  await import("../src/cli.js");
  await vi.waitFor(() => expect(start).toHaveBeenCalledOnce());
  expect(start).toHaveBeenCalledWith("full", undefined, "supervisor");

  const [surface, , role] = start.mock.calls[0]!;
  const handlers: Record<string, (args: any) => Promise<unknown>> = {};
  const call = vi.fn(async () => ({ cancelled_count: 0 }));
  registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
    async () => ({ call } as unknown as Bridge), () => ({ ok: false, error: "missing" }), surface, () => null, role);
  await handlers.stop!({});
  expect(call).toHaveBeenLastCalledWith("cancel", { all: true, origin: "stop/supervisor" }, undefined);
  await handlers.stop!({ keep_upkeep: true });
  expect(call).toHaveBeenLastCalledWith("cancel", { all: true, origin: "stop/supervisor", keep_upkeep: true }, undefined);
});

it("keeps the shared roleless solo configuration unidentified through CLI selection", async () => {
  const config = fs.readFileSync(new URL("../../.codex/config.toml", import.meta.url), "utf8");
  const args = JSON.parse(config.split("[mcp_servers.factorio]")[1]!.match(/args\s*=\s*(\[[^\]]*\])/)![1]!) as string[];
  expect(args).toEqual([]);
  vi.stubEnv("FACTORIO_CODEX_ROLE", undefined);
  process.argv = [originalArgv[0]!, "companion/src/cli.ts", "mcp", ...args];
  vi.resetModules();
  await import("../src/cli.js");
  await vi.waitFor(() => expect(start).toHaveBeenCalledOnce());
  expect(start).toHaveBeenCalledWith("full", undefined, "unknown");
});
