import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { JOB_METHODS, PROTOCOL_VERSION, RPC_METHODS, assertProtocolCompatibility, parseRpcEnvelope } from "../src/protocol/contract.js";
import { planStepSchema } from "../src/mcp/runPlan.js";

describe("bridge protocol v28", () => {
  it("has the expected version and retained methods", () => {
    expect(PROTOCOL_VERSION).toBe(28);
    expect([...RPC_METHODS]).toEqual(["ping", "spawn_companion", "observe_local", "inspect", "start_research", "can_place", "find_placement", "map_summary", "production_requirements", "run_snapshot", "connect_entities", "describe_prototype", "progression_status", "enqueue", "get_task", "queue_plan", "plan_status", "cancel", "get_chunk", "factory_status", "activity_log", "event_state", "build_layout", "build_block", "say", "say_now",
      "get_job", "blueprint_capture", "blueprint_create", "blueprint_list", "blueprint_describe", "blueprint_delete", "blueprint_export", "blueprint_place", "place_tiles",
      "platform_status", "create_platform", "set_requests", "configure_entity", "set_recipe", "set_platform_route", "travel"]);
  });
  it("matches the exact Lua registrations", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    // control.lua, rpc.lua, and the optional modules that register their own RPCs.
    const luaRoot = path.join(root, "mod/agentic-companion");
    const sources = fs.readdirSync(luaRoot, { recursive: true, encoding: "utf8" }).filter((file) => file.endsWith(".lua"))
      .map((file) => fs.readFileSync(path.join(luaRoot, file), "utf8")).join("\n");
    const registered = [...sources.matchAll(/(?:rpc|M)\.register\("([^"]+)"/g)].map((match) => match[1]!);
    // Most job reads register in one loop over their kinds (control.lua);
    // a module may also answer its own RPC through its job (find_placement).
    const loop = /for _, kind in ipairs\(\{([^}]*)\}\) do\s*rpc\.register\(kind, read\(jobs\.rpc\(kind\)\)\)/.exec(sources);
    const looped = [...(loop?.[1] ?? "").matchAll(/"([^"]+)"/g)].map((match) => match[1]!);
    const jobs = [...sources.matchAll(/jobs\.register\("([^"]+)"/g)].map((match) => match[1]!);
    expect(jobs.sort()).toEqual([...JOB_METHODS].sort());
    expect([...registered, ...looped].sort()).toEqual([...RPC_METHODS].sort());
  });
  it("dispatches every plan step action the bridge accepts", () => {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const tasks = fs.readFileSync(path.join(root, "mod/agentic-companion/scripts/tasks.lua"), "utf8");
    const registered = [...tasks.matchAll(/M\.register_action\("([^"]+)"/g)].map((match) => match[1]!);
    const table = /local ACTIONS = \{([^}]*)\}/.exec(tasks)?.[1] ?? "";
    const builtIn = [...table.matchAll(/([a-z_]+) = "/g)].map((match) => match[1]!);
    // The steps queue_plan itself runs (waits and batched inspection).
    const inline = ["wait_for_item", "wait_for_research", "inspect_entities"].filter((action) => tasks.includes(`"${action}"`));
    const actions = planStepSchema.options.map((option) => option.shape.action.value as string);
    expect(new Set(actions).size).toBe(actions.length);
    expect([...actions].sort()).toEqual([...registered, ...builtIn, ...inline].sort());
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
    expect(inspectSource).toMatch(/evidence_class = "fresh_local_exact"[\s\S]*entities = state\.entities/);
    // Every envelope variant and map_summary section the mod returns is in the companion types.
    const types = fs.readFileSync(path.join(root, "companion/src/types.ts"), "utf8");
    const variants = [...inspectSource.matchAll(/(?:evidence_class|scope) = "([^"]+)"/g)].map((match) => match[1]!);
    expect(variants).toEqual(expect.arrayContaining(["fresh_exact_local_and_charted_remote", "within_30_tiles_or_own_force_charted_at_source_tick"]));
    for (const variant of variants) expect(types).toContain(`"${variant}"`);
    expect(read("mod/agentic-companion/scripts/map_summary.lua")).toMatch(/sections\.problems_by_status/);
    expect(types).toMatch(/problems_by_status\?: Record<string, number>/);
    expect(read("mod/agentic-companion/scripts/research.lua")).not.toMatch(/companion\.get|game\.forces\.player|connected_players/);
    // Research reads the live Codex body's force in every body state (aboard too), never a fallback force.
    expect(read("mod/agentic-companion/scripts/research.lua")).toMatch(/companion\.require_present\(\)\.force/);
    // Mining keeps its exact target; only a count > 1 on trees or rocks looks
    // for the next one of the same type, never an own entity or a resource.
    const mineSource = read("mod/agentic-companion/scripts/actions/mine.lua");
    const nextNatural = /local function next_natural\(c, task\)[\s\S]*?\nend\n/.exec(mineSource)?.[0] ?? "";
    expect(nextNatural).toMatch(/type = task\._resolved_target\.type/);
    expect(nextNatural).toMatch(/e\.force ~= c\.force/);
    expect(mineSource).toMatch(/if task\._resolved_target\.type == "resource" then[\s\S]*?next_natural\(c, task\)/);
    expect(mineSource.replace(nextNatural, ""))
      .not.toMatch(/task\.resource|resource_name|find_entity_near|radius|\.mine\s*\(|\.insert\s*\(|spill_item_stack|create_entity/);
    const pickupSource = read("mod/agentic-companion/scripts/actions/pickup.lua");
    expect(pickupSource).toMatch(/item_pickup_distance/);
    expect(pickupSource).toMatch(/update_selected_entity/);
    expect(pickupSource).toMatch(/selected\s*~=\s*task\._entity/);
    expect(pickupSource).toMatch(/picking_state\s*=\s*true/);
    expect(pickupSource).not.toMatch(/\bdestroy\s*\(|\bmine\s*\(|\bstack\.count\s*=|spill_item_stack|create_entity|give_item|teleport/);
    // Belt pickup is an exact conserved transfer: an inventory insert appears
    // only where the transport line's remove_item feeds it, in the same function.
    expect(pickupSource).toMatch(/remove_item\s*\(/);
    const inserts = [...pickupSource.matchAll(/(?<!table)[.:]insert\s*\(/g)].map((match) => match.index!);
    expect(inserts.length).toBeGreaterThan(0);
    for (const at of inserts) expect(pickupSource.slice(pickupSource.lastIndexOf("function", at), at)).toMatch(/remove_item\s*\(/);
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
