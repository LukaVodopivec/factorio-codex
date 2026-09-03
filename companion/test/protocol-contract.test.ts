import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { PROTOCOL_VERSION, RPC_METHODS, assertProtocolCompatibility, parseRpcEnvelope } from "../src/protocol/contract.js";

describe("bridge protocol v12", () => {
  it("has the expected version and retained methods", () => {
    expect(PROTOCOL_VERSION).toBe(12);
    expect([...RPC_METHODS]).toEqual(["ping", "spawn_companion", "observe_local", "inspect", "start_research", "can_place", "find_placement", "map_summary", "production_requirements", "connect_entities", "describe_prototype", "progression_status", "enqueue", "get_task", "queue_plan", "plan_status", "cancel", "get_chunk"]);
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
    const luaRoot = path.join(root, "mod/agentic-companion");
    const luaSources = fs.readdirSync(luaRoot, { recursive: true, encoding: "utf8" })
      .filter((file) => file.endsWith(".lua"))
      .map((file) => fs.readFileSync(path.join(luaRoot, file), "utf8"))
      .join("\n");
    const all = [
      "mod/agentic-companion/control.lua",
      "mod/agentic-companion/scripts/companion.lua",
      "mod/agentic-companion/scripts/state.lua",
      "mod/agentic-companion/scripts/tasks.lua",
      "mod/agentic-companion/scripts/actions/walk.lua",
      "mod/agentic-companion/scripts/rpc.lua",
      "mod/agentic-companion/scripts/spatial.lua",
      "mod/agentic-companion/scripts/actions/transfer.lua",
    ].map(read).join("\n");
    expect(all).not.toMatch(/params\.companion|by_companion|storage\.companions|set_context|MAX_COMPANIONS|palette|failed_chains|params\.chain|task\.chain|find_buildable_area|params(?:\.center|\[\s*["']center["']\s*\])|near_player|path_requests|M\.DEFAULT|M\.deliver|deliver_target|register\(["']echo["']/);
    expect(all).not.toMatch(/storage\.tasks\.lane|local function lane/);
    expect(read("mod/agentic-companion/scripts/state.lua")).toMatch(/storage\.tasks\s*=\s*\{\s*next_id\s*=/s);
    expect(read("mod/agentic-companion/scripts/tasks.lua")).toMatch(/storage\.tasks\.(?:queue|active|records|next_id)/);
    expect(read("mod/agentic-companion/scripts/spatial.lua")).not.toMatch(/return can_place_one\(c, surface, params\.item/);
    const inspectSource = read("mod/agentic-companion/scripts/inspect.lua");
    expect(inspectSource).not.toMatch(/unit_number|get_entity_by_unit_number|connected_players|params\.position|return inspect_one\(params/);
    expect(inspectSource).toMatch(/return \{ entities = out \}/);
    expect(read("mod/agentic-companion/scripts/research.lua")).not.toMatch(/companion\.get|game\.forces\.player|connected_players/);
    expect(read("mod/agentic-companion/scripts/research.lua")).toMatch(/companion\.require_companion\(\)\.force/);
    expect(read("mod/agentic-companion/scripts/actions/mine.lua"))
      .not.toMatch(/task\.resource|resource_name|find_entity_near|radius|\.mine\s*\(|\.insert\s*\(|spill_item_stack|create_entity/);
    const pickupSource = read("mod/agentic-companion/scripts/actions/pickup.lua");
    expect(pickupSource).toMatch(/item_pickup_distance/);
    expect(pickupSource).toMatch(/update_selected_entity/);
    expect(pickupSource).toMatch(/selected\s*~=\s*task\._entity/);
    expect(pickupSource).toMatch(/picking_state\s*=\s*true/);
    expect(pickupSource).not.toMatch(/\bdestroy\s*\(|\bmine\s*\(|\binsert\s*\(|\bstack\.count\s*=|spill_item_stack|create_entity|teleport/);
    expect(read("mod/agentic-companion/scripts/actions/build_plan.lua")).not.toMatch(/step\.entity/);
    expect(luaSources).not.toMatch(/register\(["']run_plan/);
    expect(read("mod/agentic-companion/scripts/tasks.lua")).toMatch(/wait_for_item/);
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
    expect(fs.readFileSync(path.join(root, ".github/workflows/ci.yml"), "utf8"))
      .not.toMatch(/npm pack|test:npm-package|package-assets/);
    for (const removed of [
      "companion/.npmignore",
      "companion/scripts/package-assets.mjs",
      "scripts/test-npm-package.mjs",
    ]) expect(fs.existsSync(path.join(root, removed)), removed).toBe(false);
  });
  it("guides users only through public v11 tool names", () => {
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
