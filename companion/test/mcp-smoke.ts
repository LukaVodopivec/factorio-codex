import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const surface = process.env.MCP_SURFACE ?? "full";
const readOnly = ["connect_status","map_summary","progression_status","production_requirements","describe_prototype","observe_local","inspect_entity","plan_status","can_place","find_placement","factory_status","activity_log","next_event","build_layout","connect_entities","blueprint_list","blueprint_describe","blueprint_export","blueprint_place","place_tiles","platform_status"];
const expected = (surface === "read-only"
  ? readOnly
  : [...readOnly, "get_items","walk_to","mine","pickup_items","place_entity","craft_items","insert_items","extract_items","set_recipe","rotate_entity","build_plan","queue_plan","run_plan","start_research","stop",
    "move_entity","explore","blueprint_capture","blueprint_create","blueprint_delete","build_ghosts","deconstruct_area","upgrade_area","copy_settings",
    "configure_entity","set_requests","create_platform","launch_rocket","set_platform_route","travel"]).sort();
const cwd = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const entry = process.env.MCP_ENTRY ?? "src/cli.ts";
const home = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-mcp-home-"));
const command = entry.endsWith(".ts") ? "npx" : "node";
const surfaceArgs = surface === "read-only" ? ["--surface", "read-only"] : [];
const args = entry.endsWith(".ts") ? ["tsx", entry, "mcp", ...surfaceArgs] : [entry, "mcp", ...surfaceArgs];
const child = spawn(command, args, { cwd, stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, HOME: home } });
let buffer = "", stderr = "", next = 1;
const pending = new Map<number, (value: any) => void>();
child.stderr.on("data", (data) => { stderr += data.toString(); });
child.stdout.on("data", (data) => {
  buffer += data;
  let at;
  while ((at = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, at); buffer = buffer.slice(at + 1);
    if (!line) continue;
    const message = JSON.parse(line); pending.get(message.id)?.(message); pending.delete(message.id);
  }
});
const request = (method: string, params?: unknown) => new Promise<any>((resolve, reject) => {
  const id = next++; pending.set(id, resolve);
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  setTimeout(() => reject(new Error(`timeout: ${method}; stderr=${stderr}`)), 10000);
});

try {
  const init = await request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "offline-smoke", version: "1" } });
  if (init.result?.serverInfo?.name !== "factorio-codex" || init.result?.serverInfo?.version !== "0.28.0") throw new Error(`wrong server metadata; stderr=${stderr}`);
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  const tools = (await request("tools/list")).result.tools;
  const names = tools.map((tool: any) => tool.name).sort();
  if (JSON.stringify(names) !== JSON.stringify(expected)) throw new Error(`tool mismatch: ${names}`);
  if (/agent_id|companion|background|image|lua|console/i.test(JSON.stringify(tools))) throw new Error("forbidden schema/content exposed");
  const summaryTool = tools.find((tool: any) => tool.name === "map_summary");
  const includeSchema = summaryTool?.inputSchema?.properties?.include;
  if (JSON.stringify(includeSchema?.items?.enum) !== JSON.stringify(["stockpiles", "sites", "patches", "power", "problems", "flows_all"])
    || (summaryTool?.inputSchema?.required ?? []).includes("include")) throw new Error("map_summary must expose optional include with the six player-parity sections");
  if (!/charted/.test(summaryTool?.description ?? "") || !/remote: true/.test(tools.find((tool: any) => tool.name === "inspect_entity")?.description ?? "")) throw new Error("map_summary and inspect_entity must disclose the charted own-force read scope");
  if (surface === "read-only") {
    const forbidden = ["get_items", "walk_to", "mine", "pickup_items", "place_entity", "craft_items", "insert_items", "extract_items",
      "set_recipe", "rotate_entity", "build_plan", "queue_plan", "run_plan", "start_research", "stop", "move_entity", "explore",
      "blueprint_capture", "blueprint_create", "blueprint_delete", "build_ghosts", "deconstruct_area", "upgrade_area", "copy_settings",
      "configure_entity", "set_requests", "create_platform", "launch_rocket", "set_platform_route", "travel"];
    if (forbidden.some((name) => names.includes(name))) throw new Error(`read-only surface exposed mutation: ${names}`);
    for (const name of ["build_layout", "connect_entities", "blueprint_place", "place_tiles"]) {
      const checkOnly = tools.find((tool: any) => tool.name === name)?.inputSchema?.properties?.check_only;
      if (checkOnly?.const !== true && JSON.stringify(checkOnly?.enum) !== "[true]") throw new Error(`read-only ${name} must be a dry run only: ${JSON.stringify(checkOnly)}`);
    }
    const platformSchema = tools.find((tool: any) => tool.name === "platform_status")?.inputSchema?.properties ?? {};
    if (JSON.stringify(platformSchema.detail?.enum) !== JSON.stringify(["compact", "full"]) || !platformSchema.platform) throw new Error("read-only platform_status must take platform and detail compact|full");
    for (const name of ["factory_status", "map_summary", "inspect_entity", "can_place", "find_placement"]) {
      if (!tools.find((tool: any) => tool.name === name)?.inputSchema?.properties?.surface) throw new Error(`read-only ${name} must read another surface`);
    }
    if (!tools.find((tool: any) => tool.name === "production_requirements")?.inputSchema?.properties?.planet) throw new Error("production_requirements must plan per planet");
    console.log(`PASS initialize, exact ${names.length} read-only tools, dry-run-only layouts, routes, blueprint placements and tiles, platform reads, reads of every surface, no physical mutation surface`);
  } else {
  const placementTool = tools.find((tool: any) => tool.name === "find_placement");
  if (!/input_target, output_target, or output_recipient_item require cardinal directions only: 0, 4, 8, 12/.test(placementTool?.description ?? "")) throw new Error("find_placement must disclose the targeted cardinal constraint");
  const rejectedPlacement = await request("tools/call", { name: "find_placement", arguments: {
    item: "inserter", preferred: { x: 0, y: 0 }, input_target: { x: 1, y: 0 }, directions: [0, 1],
  } });
  const placementText = rejectedPlacement.result?.content?.[0]?.text ?? "";
  if (!rejectedPlacement.result?.isError || !placementText.includes("cardinal: 0, 4, 8, or 12") || /Offline:/.test(placementText)) throw new Error(`targeted noncardinal placement reached connection handling instead of validation: ${placementText}`);
  const rotateSchema = tools.find((tool: any) => tool.name === "rotate_entity")?.inputSchema?.properties ?? {};
  if (!rotateSchema.direction || rotateSchema.reverse) throw new Error("rotate_entity must expose Lua direction, never reverse");
  const describeSchema = tools.find((tool: any) => tool.name === "describe_prototype")?.inputSchema?.properties ?? {};
  if (describeSchema.names?.maxItems !== 10) throw new Error("describe_prototype must match Lua's 10-name cap");
  if (JSON.stringify(describeSchema.kind?.enum) !== JSON.stringify(["auto", "entity", "recipe", "item"]) || describeSchema.kind?.default !== "auto") throw new Error("describe_prototype must expose kind auto|entity|recipe|item with auto default");
  const extractSchema = tools.find((tool: any) => tool.name === "extract_items")?.inputSchema ?? {};
  if ((extractSchema.required ?? []).includes("items")) throw new Error("extract_items must allow omitted items for all=true extraction");
  const planSchema = tools.find((tool: any) => tool.name === "build_plan")?.inputSchema?.properties ?? {};
  if (planSchema.stop_on_error?.default !== true || planSchema.steps?.maxItems !== 25) throw new Error("build_plan must default fail-fast and cap steps at 25");
  for (const name of ["place_entity", "build_plan", "queue_plan", "run_plan"]) {
    const schema = JSON.stringify(tools.find((tool: any) => tool.name === name)?.inputSchema ?? {});
    if (!schema.includes('"belt_to_ground_type":{"type":"string","enum":["input","output"]}')) throw new Error(`${name} must expose optional belt_to_ground_type input|output`);
  }
  const tooManySteps = Array.from({ length: 26 }, (_, x) => ({ x, y: 0, name: "transport-belt" }));
  const rejectedPlan = await request("tools/call", { name: "build_plan", arguments: { steps: tooManySteps } });
  const rejectedText = rejectedPlan.result?.content?.[0]?.text ?? "";
  if (!rejectedPlan.result?.isError || /Offline:/.test(rejectedText)) throw new Error(`26-step plan reached runtime instead of input rejection: ${rejectedText}`);
  const mineSchema = tools.find((tool: any) => tool.name === "mine")?.inputSchema?.properties ?? {};
  if (mineSchema.count?.default !== 1 || mineSchema.count?.maximum !== 200) throw new Error("mine must expose count 1-200 default 1");
  if (mineSchema.target_kind?.default !== undefined || JSON.stringify(mineSchema.target_kind?.enum) !== JSON.stringify(["natural", "owned"])) throw new Error("mine must expose optional natural|owned target identity for overlap disambiguation");
  if (!mineSchema.expected_name || mineSchema.observed_tick?.minimum !== 0
    || (tools.find((tool: any) => tool.name === "mine")?.inputSchema?.required ?? []).some((field: string) => field === "expected_name" || field === "observed_tick")) throw new Error("mine must keep expected_name and observed_tick optional");
  const pickupSchema = tools.find((tool: any) => tool.name === "pickup_items")?.inputSchema ?? {};
  if (!/belt tile/.test(tools.find((tool: any) => tool.name === "pickup_items")?.description ?? "")) throw new Error("pickup_items must disclose belt pickup");
  if (!pickupSchema.required?.includes("x") || !pickupSchema.required?.includes("y") || !pickupSchema.required?.includes("item") || !pickupSchema.required?.includes("count")) throw new Error("pickup_items must require exact observed position/item/count");
  const runPlanSchema = tools.find((tool: any) => tool.name === "run_plan")?.inputSchema ?? {};
  if (runPlanSchema.properties?.steps?.maxItems !== 200 || runPlanSchema.properties?.steps?.minItems !== 1) throw new Error("run_plan must accept 1-200 steps");
  if (runPlanSchema.properties?.final_observation_radius?.default !== 15 || runPlanSchema.properties?.observation_radius) throw new Error("run_plan must expose only final_observation_radius");
  const serializedSteps = JSON.stringify(runPlanSchema.properties?.steps);
  for (const action of ["wait_for_research", "get_items", "build_layout", "explore", "move_entity", "blueprint_place",
    "build_ghosts", "deconstruct_area", "upgrade_area", "copy_settings", "configure_entity", "flush_fluid", "place_tiles", "set_requests", "equip", "create_platform", "launch_rocket", "set_platform_route", "travel"]) if (!serializedSteps.includes(`\"const\":\"${action}\"`)) throw new Error(`run_plan must expose ${action}`);
  if (serializedSteps.includes('"const":"blueprint_capture"')) throw new Error("blueprint_capture is a package step, never a plan step");
  if (serializedSteps.includes('"const":"build_block"') || names.includes("build_block")) throw new Error("build_block is gone: the bots design their own layouts");
  const craftSchema = tools.find((tool: any) => tool.name === "craft_items")?.inputSchema?.properties ?? {};
  if (craftSchema.wait_for_completion?.default !== undefined) throw new Error("craft_items must not wait for completion by default");
  const routeSchema = tools.find((tool: any) => tool.name === "connect_entities")?.inputSchema?.properties ?? {};
  if (routeSchema.max_length?.maximum !== 200 || routeSchema.check_only?.default !== false) throw new Error("connect_entities must take up to 200 pieces and a check_only dry run");
  if (/validate_factory_component|duration_seconds/.test(serializedSteps)) throw new Error("run_plan exposes the removed validation step");
  const serializedRunPlan = JSON.stringify(runPlanSchema);
  if (/"const":"(?:build_plan|start_research|stop|sleep)"|"by_name":/.test(serializedRunPlan)) throw new Error("run_plan exposes a forbidden nested step");
  const status = await request("tools/call", { name: "connect_status", arguments: {} });
  const text = status.result?.content?.[0]?.text ?? "";
  if (!text.startsWith("Offline:") || !text.includes("factorio-codex setup")) throw new Error(`offline status not actionable: ${text}`);
  if (stderr.trim()) throw new Error(`unexpected pre-init/offline stderr: ${stderr}`);
  const queueSchema = tools.find((tool: any) => tool.name === "queue_plan")?.inputSchema?.properties ?? {};
  if (queueSchema.after_plan_id?.exclusiveMinimum !== 0 || queueSchema.observation_detail?.default !== "none") throw new Error("queue_plan dependency/detail schema mismatch");
  const statusSchema = tools.find((tool: any) => tool.name === "plan_status")?.inputSchema?.properties ?? {};
  if (statusSchema.wait_until?.default !== "current" || statusSchema.timeout_seconds?.default !== 30
    || statusSchema.timeout_seconds?.maximum !== 60) throw new Error("plan_status bounded wait schema mismatch");
  const eventSchema = tools.find((tool: any) => tool.name === "next_event")?.inputSchema?.properties ?? {};
  if (eventSchema.timeout_seconds?.minimum !== 1 || eventSchema.timeout_seconds?.maximum !== 120 || !eventSchema.since_tick) throw new Error("next_event must take timeout_seconds 1-120 and since_tick");
  const inspectSchema = tools.find((tool: any) => tool.name === "inspect_entity")?.inputSchema?.properties ?? {};
  if (inspectSchema.positions?.maxItems !== 64 || !serializedSteps.includes('"maxItems":64')) throw new Error("inspect_entity and inspect_entities must read up to 64 positions");
  const roles = JSON.stringify(tools.find((tool: any) => tool.name === "extract_items")?.inputSchema?.properties?.inventory?.enum);
  if (roles !== JSON.stringify(["main", "input", "output", "fuel", "burnt_result", "modules", "trash", "robots", "material", "rocket"])) throw new Error(`extract_items must expose the inventory roles: ${roles}`);
  const sections = tools.find((tool: any) => tool.name === "factory_status")?.inputSchema?.properties?.sections?.items?.enum ?? [];
  if (!sections.includes("logistics") || !sections.includes("platforms")) throw new Error("factory_status must offer the logistics and platforms sections");
  // Remote platform work: platform selectors on the steps that act without the body.
  for (const name of ["set_recipe", "configure_entity", "build_layout", "blueprint_place", "deconstruct_area"]) {
    if (!tools.find((tool: any) => tool.name === name)?.inputSchema?.properties?.platform) throw new Error(`${name} must take platform`);
  }
  if (tools.find((tool: any) => tool.name === "upgrade_area")?.inputSchema?.properties?.platform) throw new Error("upgrade_area takes no platform");
  const target = JSON.stringify(tools.find((tool: any) => tool.name === "set_requests")?.inputSchema?.properties?.target ?? {});
  if (!target.includes('"platform"')) throw new Error("set_requests must take a platform hub target");
  const cargo = JSON.stringify(tools.find((tool: any) => tool.name === "launch_rocket")?.inputSchema?.properties?.cargo ?? {});
  if (!cargo.includes('"const":"requests"')) throw new Error('launch_rocket cargo must accept "requests"');
  // Trips: travel takes a surface; a route's waits are the game's own wait condition types.
  const travelSchema = tools.find((tool: any) => tool.name === "travel")?.inputSchema ?? {};
  if (!(travelSchema.required ?? []).includes("to") || travelSchema.properties?.max_wait_minutes?.maximum !== 240) throw new Error("travel must take to and max_wait_minutes up to 240");
  const route = JSON.stringify(tools.find((tool: any) => tool.name === "set_platform_route")?.inputSchema ?? {});
  if (!route.includes('"all_requests_satisfied"') || !route.includes('"go_to"') || !route.includes('"paused"')) throw new Error("set_platform_route must take stops with wait conditions, go_to and paused");
  if (!tools.find((tool: any) => tool.name === "queue_plan")?.inputSchema?.properties?.surface) throw new Error("queue_plan must take surface");
  console.log(`PASS initialize, exact ${names.length} tools, Lua-parity schemas, platform parameters, trips and routes, forbidden-schema scan, actionable offline status`);
  }
} finally {
  child.kill();
  fs.rmSync(home, { recursive: true, force: true });
  if (fs.existsSync(home)) throw new Error(`temporary HOME cleanup failed`);
}
