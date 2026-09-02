import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { PROTOCOL_VERSION, RPC_METHODS, assertProtocolCompatibility, parseRpcEnvelope } from "../src/protocol/contract.js";

describe("bridge protocol v5", () => {
  it("has the expected version and retained methods", () => {
    expect(PROTOCOL_VERSION).toBe(5);
    expect([...RPC_METHODS]).toEqual(["ping", "spawn_companion", "observe_local", "inspect", "start_research", "can_place", "describe_prototype", "enqueue", "get_task", "cancel", "get_chunk"]);
  });
  it("matches the exact Lua registrations", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const sources = ["mod/agentic-companion/control.lua", "mod/agentic-companion/scripts/rpc.lua"].map((file) => fs.readFileSync(path.join(root, file), "utf8")).join("\n");
    const registered = [...sources.matchAll(/(?:rpc|M)\.register\("([^"]+)"/g)].map((match) => match[1]).sort();
    expect(registered).toEqual([...RPC_METHODS].sort());
  });
  it("keeps replaced callable paths absent from retained Lua sources", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const read = (file: string) => fs.readFileSync(path.join(root, file), "utf8");
    const all = [
      "mod/agentic-companion/control.lua",
      "mod/agentic-companion/scripts/companion.lua",
      "mod/agentic-companion/scripts/state.lua",
      "mod/agentic-companion/scripts/tasks.lua",
      "mod/agentic-companion/scripts/rpc.lua",
      "mod/agentic-companion/scripts/spatial.lua",
      "mod/agentic-companion/scripts/actions/transfer.lua",
    ].map(read).join("\n");
    expect(all).not.toMatch(/params\.companion|by_companion|storage\.companions|set_context|MAX_COMPANIONS|palette|failed_chains|params\.chain|task\.chain|find_buildable_area|params(?:\.center|\[\s*["']center["']\s*\])|near_player|path_requests|M\.DEFAULT|M\.deliver|deliver_target|register\(["']echo["']/);
    expect(read("mod/agentic-companion/scripts/state.lua")).toMatch(/storage\.tasks\s*=\s*\{\s*lane\s*=/s);
    expect(read("mod/agentic-companion/scripts/tasks.lua")).not.toMatch(/storage\.tasks\.(?:queue|active|records|next_id)/);
    expect(read("mod/agentic-companion/scripts/spatial.lua")).not.toMatch(/return can_place_one\(c, surface, params\.item/);
    const inspectSource = read("mod/agentic-companion/scripts/inspect.lua");
    expect(inspectSource).not.toMatch(/unit_number|get_entity_by_unit_number|connected_players|params\.position|return inspect_one\(params/);
    expect(inspectSource).toMatch(/return \{ entities = out \}/);
    expect(read("mod/agentic-companion/scripts/research.lua")).not.toMatch(/companion\.get|game\.forces\.player|connected_players/);
    expect(read("mod/agentic-companion/scripts/research.lua")).toMatch(/companion\.require_companion\(\)\.force/);
    expect(read("mod/agentic-companion/scripts/actions/mine.lua")).not.toMatch(/task\.resource|resource_name|find_entity_near|radius|\.mine\s*\(/);
    expect(read("mod/agentic-companion/scripts/actions/build_plan.lua")).not.toMatch(/step\.entity/);
  });
  it("keeps the private package on the repository-only mod layout", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const rootPackage = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
    const companionPackage = JSON.parse(fs.readFileSync(path.join(root, "companion/package.json"), "utf8"));
    expect(companionPackage.files).toEqual(["dist"]);
    expect(companionPackage.scripts).not.toHaveProperty("prepack");
    expect(companionPackage.scripts).not.toHaveProperty("postpack");
    expect(rootPackage.scripts).not.toHaveProperty("test:npm-package");
    expect(rootPackage.scripts.test).not.toContain("test:npm-package");
    expect(fs.readFileSync(path.join(root, "companion/src/setup/installMod.ts"), "utf8"))
      .not.toMatch(/packageRoot|assets/);
    expect(fs.readFileSync(path.join(root, ".gitignore"), "utf8"))
      .not.toContain("companion/assets/");
    for (const removed of [
      "companion/.npmignore",
      "companion/scripts/package-assets.mjs",
      "scripts/test-npm-package.mjs",
    ]) expect(fs.existsSync(path.join(root, removed)), removed).toBe(false);
  });
  it("guides users only through public fresh-v5 tool names", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const companionSource = fs.readFileSync(path.join(root, "mod/agentic-companion/scripts/companion.lua"), "utf8");
    const inspectSource = fs.readFileSync(path.join(root, "mod/agentic-companion/scripts/inspect.lua"), "utf8");
    expect(companionSource).toContain("call connect_status first");
    expect(companionSource).not.toContain("call spawn_companion");
    expect(inspectSource).toContain("call observe_local first");
    expect(inspectSource).not.toMatch(/look_around|scan_area|find_buildable_area/);
  });
  it("validates normal, error, and chunk envelopes", () => {
    expect(parseRpcEnvelope('{"ok":true,"data":{"tick":1}}')).toMatchObject({ ok: true });
    expect(parseRpcEnvelope('{"ok":false,"error":"nope"}')).toEqual({ ok: false, error: "nope" });
    expect(parseRpcEnvelope('{"ok":true,"chunked":true,"id":1,"parts":2,"data":"x"}')).toMatchObject({ chunked: true, parts: 2 });
  });
  it("rejects mismatched mods", () => expect(() => assertProtocolCompatibility({ protocol_version: 4 })).toThrow("protocol mismatch"));
});
