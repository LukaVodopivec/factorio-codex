// Opt-in live smoke suite (`npm run test:live`, never part of `npm test` or
// CI): the real mod on a real headless Factorio 2.0.x server, with no client
// and no body. A throwaway save on seed 747930220 lives in a temp dir with its
// own config, write dir and random free ports, so the user's Factorio data is
// never touched; the dir and the server are removed on success and failure.
//
// Scenarios build entities with create_entity in `/silent-command
// __agentic-companion__` console commands, then call the real mod modules or
// the mod's RPCs through the repository's RconClient and Bridge. A headless
// server has no Codex player and charts nothing, so the setup command patches
// the live Lua state of this throwaway server only: companion.body returns a
// stand-in on nauvis, surfaces.charted answers true, and the registry is
// marked ready. The physical scenarios swap in a real character as the body
// (characterStandIn). Nothing in the mod has a test flag or path.
//
// After the scenarios: ping shows no handler_errors, the server log has no
// script errors, every profiler rpc line and the rpc lines of each tick
// together stay within the 8 ms budget, and every 600-tick on_tick window
// (profiler.lua) averages within it. Tick handlers (jobs advanced on_tick)
// are only logged per window, so one slow handler tick inside a quiet
// window is not caught here.
import { spawn, type ChildProcess } from "node:child_process";
import crypto from "node:crypto";
import dgram from "node:dgram";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { Bridge } from "../src/bridge.js";
import { assertRuntimeCompatibility } from "../src/compatibility.js";
import { companionVersion } from "../src/config.js";
import { RconClient } from "../src/rcon.js";
import { MAP_GEN_SETTINGS, SERVER_SETTINGS, createArgs, prepareMods, runPaths } from "../src/server/server.js";
import { factorioBinary } from "../src/setup/locate.js";

const SEED = 747930220;
const TICK_BUDGET_MS = 8;
const BODY = { x: 30, y: 30 };

const bin = factorioBinary();
if (!bin) {
  const message = "live suite: no Factorio executable found (set FACTORIO_BIN or install the Linux Steam build)";
  if (process.env.FACTORIO_LIVE_REQUIRED === "1") { console.error(`${message}; FACTORIO_LIVE_REQUIRED=1 makes this a failure`); process.exit(1); }
  console.log(`${message}; skipped`);
  process.exit(0);
}

const freeTcpPort = () => new Promise<number>((resolve, reject) => {
  const server = net.createServer().once("error", reject);
  server.listen(0, "127.0.0.1", () => { const { port } = server.address() as net.AddressInfo; server.close(() => resolve(port)); });
});
const freeUdpPort = () => new Promise<number>((resolve, reject) => {
  const socket = dgram.createSocket("udp4").once("error", reject);
  socket.bind(0, "127.0.0.1", () => { const { port } = socket.address(); socket.close(() => resolve(port)); });
});

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-live-"));
const paths = runPaths(dir);
const configIni = path.join(dir, "config.ini");
// The Factorio process running now: --create first, then the server.
let server: ChildProcess | null = null;
let rcon: RconClient | null = null;

// One cleanup for every caller (each signal and the main flow's finally): all
// wait for the same server exit before the dir is removed. The handlers stay
// registered (not once): tsx relays a signal to this process a second time,
// and with no listener left that second one would end it mid-cleanup.
let cleaning: Promise<void> | undefined;
const cleanup = () => (cleaning ??= (async () => {
  rcon?.close();
  const child = server;
  if (child && child.exitCode === null && child.signalCode === null) {
    const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
    child.kill("SIGINT");
    if (await Promise.race([exited.then(() => true), sleep(30_000).then(() => false)]) === false) {
      child.kill("SIGKILL");
      await exited;
    }
  }
  fs.rmSync(dir, { recursive: true, force: true });
})());
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => { void cleanup().finally(() => process.exit(128 + os.constants.signals[signal])); });
}

async function startServer(): Promise<Bridge> {
  fs.writeFileSync(configIni, `[path]\nread-data=__PATH__executable__/../../data\nwrite-data=${dir}\n`);
  prepareMods(paths.mods);
  fs.writeFileSync(paths.mapGen, JSON.stringify({ ...MAP_GEN_SETTINGS, seed: SEED }));
  fs.writeFileSync(paths.serverSettings, JSON.stringify({ ...SERVER_SETTINGS, description: "Factorio Codex live smoke suite",
    visibility: { public: false, lan: false }, auto_pause: false }));
  // Not spawnSync: a blocked event loop would never run the signal handler.
  const create = server = spawn(bin!, ["-c", configIni, ...createArgs(paths)], { stdio: ["ignore", "pipe", "pipe"] });
  let output = "";
  create.stdout!.on("data", (chunk) => { output += chunk; });
  create.stderr!.on("data", (chunk) => { output += chunk; });
  const status = await new Promise<number | null>((resolve, reject) => create.once("error", reject).once("close", resolve));
  if (status !== 0 || !fs.existsSync(paths.save)) {
    throw new Error(`factorio --create failed (exit ${status}): ${output.trim().split("\n").slice(-5).join(" | ")}`);
  }
  const password = crypto.randomBytes(12).toString("hex");
  const [gamePort, rconPort] = [await freeUdpPort(), await freeTcpPort()];
  if (cleaning) throw new Error("interrupted");
  const log = fs.openSync(paths.log, "w");
  server = spawn(bin!, ["-c", configIni, "--start-server", paths.save, "--server-settings", paths.serverSettings,
    "--mod-directory", paths.mods, "--bind", "127.0.0.1", "--port", String(gamePort),
    "--rcon-bind", `127.0.0.1:${rconPort}`, "--rcon-password", password, "--disable-audio"], { cwd: dir, stdio: ["ignore", log, log] });
  fs.closeSync(log);
  for (const deadline = Date.now() + 180_000; ; await sleep(1000)) {
    if (server.exitCode !== null) throw new Error(`server exited with ${server.exitCode}: ${logTail()}`);
    const client = new RconClient({ host: "127.0.0.1", port: rconPort, password, timeoutMs: 20_000 });
    try {
      await client.connect();
      const bridge = new Bridge(client);
      await bridge.unlock();
      rcon = client;
      return bridge;
    } catch (error) {
      client.close();
      // Only a server still starting is retried (as server.ts does); a refused
      // unlock or a wrong password will not clear by waiting.
      if (!(error instanceof Error) || !/cannot connect to RCON|auth timed out|ECONNRESET|closed/i.test(error.message)) throw error;
      if (Date.now() > deadline) throw new Error(`server did not accept RCON in 180 s: ${error instanceof Error ? error.message : error}`);
    }
  }
}

const logTail = () => { try { return fs.readFileSync(paths.log, "utf8").trim().split("\n").slice(-5).join(" | "); } catch { return "(no log)"; } };

// One console command in the mod's Lua state: body is a function body whose
// return value comes back through the mod's own NaN-safe rpc.to_json. mod(n)
// is the loaded scripts/<n>.lua. One line: no Lua `--` comments.
const PRELUDE = 'local function mod(n) return package.loaded["__agentic-companion__/scripts/" .. n .. ".lua"] end local rpc = mod("rpc")';
async function lua<T = any>(body: string): Promise<T> {
  const code = body.split("\n").map((line) => line.trim()).filter(Boolean).join(" ");
  if (code.includes("--")) throw new Error("scenario Lua must not contain -- (one console line)");
  const raw = (await rcon!.exec(`/silent-command __agentic-companion__ ${PRELUDE} local ok, res = pcall(function() ${code} end)`
    + " rcon.print(rpc.to_json({ ok = ok, result = ok and res or nil, error = not ok and tostring(res) or nil }))")).trim();
  let reply: { ok: boolean; result?: T; error?: string };
  try { reply = JSON.parse(raw); } catch { throw new Error(`console reply is not JSON: ${raw.slice(0, 300)}`); }
  if (!reply.ok) throw new Error(`Lua error: ${reply.error}`);
  return reply.result as T;
}

async function until<T>(what: string, read: () => Promise<T | undefined | null | false>, timeoutMs = 30_000): Promise<T> {
  for (const deadline = Date.now() + timeoutMs; ; await sleep(500)) {
    const value = await read();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out after ${timeoutMs / 1000} s waiting for ${what}`);
  }
}

// The game's JSON writes an empty Lua table as {}: a list read may be either.
const list = (value: unknown): any[] => (Array.isArray(value) ? value : []);

function expect(condition: unknown, message: string, value?: unknown): asserts condition {
  if (!condition) throw new Error(value === undefined ? message : `${message}: ${JSON.stringify(value)}`);
}

// Test-only setup of this throwaway game (see the header), and a cleared,
// paved area around the stand-in body for the planet scenarios.
async function setup(): Promise<void> {
  await lua(`
    local s = game.surfaces.nauvis
    mod("companion").body = function() return { state = "on_surface", surface = s, surface_ref = "nauvis",
      position = { x = ${BODY.x}, y = ${BODY.y} }, force = game.forces.player } end
    mod("surfaces").charted = function() return true end
    storage.registry.ready, storage.registry.ready_tick = true, game.tick
    for _, e in pairs(s.find_entities_filtered({ area = { { 14, 14 }, { 50, 42 } } })) do e.destroy() end
    local tiles = {}
    for x = 14, 49 do for y = 14, 41 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
    s.set_tiles(tiles)
  `);
}

const BUILD = `local function make(s, name, x, y, extra)
  local spec = { name = name, position = { x, y }, force = "player", raise_built = true }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return assert(s.create_entity(spec), "could not create " .. name)
end`;

// The physical scenarios need a character: a real one, created on a second
// cleared, paved site beyond upkeep reach of the first site's burners, and
// returned by companion.get, require_companion and body for the rest of the
// run. The server never charts (force.chart and radar requests stay pending
// with no player connected), so two module-level chart gates are answered as
// the setup answers surfaces.charted, through a view of the character whose
// force changes only the chart answer (and whose surface leaves the character
// itself out of entity reads, as path_start's `entity ~= c` would for the
// character): placement_geometry.path_start skips its chart check (its entity
// and tile collision checks stay real) and
// blueprints.area finds the area charted (its shape and size checks stay
// real). The chart gates that are locals of walk.lua, supply.lua and
// build_layout.lua still see the real chart, so here the character cannot
// walk, fetch from a source, or run build_layout's checks: scenarios act
// within its reach.
const SITE = { x: 160, y: 30 };
let standIn: Promise<void> | undefined;
const characterStandIn = () => (standIn ??= lua(`
  local s = game.surfaces.nauvis
  s.request_to_generate_chunks({ ${SITE.x}, ${SITE.y} }, 2)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered({ area = { { 140, 10 }, { 200, 60 } } })) do e.destroy() end
  local tiles = {}
  for x = 140, 199 do for y = 10, 59 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
  s.set_tiles(tiles)
  storage.live_character = assert(s.create_entity({ name = "character", position = { ${SITE.x}, ${SITE.y} }, force = "player" }))
  local companion = mod("companion")
  local function get() local c = storage.live_character return c and c.valid and c or nil end
  companion.get = get
  companion.require_companion = function() return get() or error("BODY_UNAVAILABLE: the stand-in character is gone", 0) end
  companion.body = function()
    local c = get()
    if not c then return { state = "absent" } end
    return { state = "on_surface", surface = c.surface, surface_ref = "nauvis", character = c, entity = c,
      position = { x = c.position.x, y = c.position.y }, force = c.force }
  end
  local function view(c, force)
    local surface = c.surface
    local own = setmetatable({ find_entities_filtered = function(filter)
      local out = {}
      for _, e in ipairs(surface.find_entities_filtered(filter)) do if e ~= c then out[#out + 1] = e end end
      return out
    end }, { __index = function(_, key) return surface[key] end })
    return setmetatable({ force = force, surface = own }, { __index = function(_, key) return c[key] end })
  end
  local geometry, blueprints = mod("placement_geometry"), mod("blueprints")
  local path_start, area = geometry.path_start, blueprints.area
  geometry.path_start = function(c) return path_start(view(c, {})) end
  blueprints.area = function(c, ...) return area(view(c, { is_chunk_charted = function() return true end }), ...) end
`).then(() => undefined));

// Queues a plan through the mod's queue_plan and waits for its end.
async function runPlan(bridge: Bridge, steps: unknown[], timeoutMs = 30_000): Promise<any> {
  const queued = await bridge.call<any>("queue_plan", { steps });
  return until(`plan ${queued.plan_id} to end`, async () => {
    const status = await bridge.call<any>("plan_status", { plan_id: queued.plan_id });
    return ["completed", "partial", "failed", "cancelled"].includes(status.status) ? status : undefined;
  }, timeoutMs);
}

type Scenario = { name: string; run: (bridge: Bridge) => Promise<string> };
const scenarios: Scenario[] = [
  {
    name: "watch fires and the line sampler reads a powered assembler line and a dry boiler",
    async run(bridge) {
      await lua(`${BUILD}
        local s = game.surfaces.nauvis
        local eei = make(s, "electric-energy-interface", 20, 20)
        eei.power_production, eei.electric_buffer_size = 1000000, 10000000
        make(s, "substation", 25, 25)
        for _, x in ipairs({ 22.5, 26.5 }) do make(s, "assembling-machine-2", x, 29.5).set_recipe("iron-gear-wheel") end
        make(s, "infinity-pipe", 38.5, 22.5).set_infinity_pipe_filter({ name = "water", percentage = 1 })
        make(s, "boiler", 40.5, 22, { direction = defines.direction.north })
        make(s, "steam-engine", 40.5, 18.5, { direction = defines.direction.north })
      `);
      const set = await bridge.call<any>("set_watch", { role: "pilot", condition: { kind: "consumption_above_production", item: "iron-plate" } });
      expect(set.watch?.armed === true, "a watch whose value is on the safe side arms at once", set.watch);
      const since = await lua<number>(`
        for _, e in pairs(game.surfaces.nauvis.find_entities_filtered({ name = "assembling-machine-2" })) do
          e.insert({ name = "iron-plate", count = 200 })
        end
        return game.tick`);
      const fired = await until("the iron-plate watch to fire", async () => list(await lua(`return mod("watches").fired_since("pilot", ${since})`)).at(0));
      expect(fired.condition?.kind === "consumption_above_production" && fired.condition?.item === "iron-plate",
        "the firing names the watch's condition", fired);
      const lines = await until("a running gear line and a no_fuel power line", async () => {
        const rows = list(await lua(`return mod("autonomy").lines(nil, 1)`));
        const gears = rows.find((row) => row.product === "iron-gear-wheel");
        const power = rows.find((row) => row.product === "electricity");
        return gears?.state === "running" && gears.rate_per_min > 0 && power?.state === "no_fuel" ? { gears, power } : undefined;
      });
      expect(lines.gears.machines === 2 && lines.gears.working === 2, "both assemblers work", lines.gears);
      expect(lines.gears.max_per_min === 180, "two assembling-machine-2 on gears make 180/min at full duty", lines.gears);
      expect(lines.power.cause_position?.x === 40.5 && lines.power.cause_position?.y === 22, "the dry boiler is the cause", lines.power);
      // A problem row shows once its status lasted past its threshold.
      await until("the dry boiler's problem row", async () => list(await lua(`return mod("autonomy").problems(nil, 1)`))
        .some((row) => row.status === "no_fuel" && row.name === "boiler" && row.line === lines.power.id));
      return `fired at tick ${fired.tick}; gears ${lines.gears.rate_per_min}/min of ${lines.gears.max_per_min}; boiler ${lines.power.state}`;
    },
  },
  {
    name: "inspect reads each belt lane",
    async run(bridge) {
      await lua(`${BUILD}
        local belt = make(game.surfaces.nauvis, "transport-belt", 30.5, 36.5, { direction = defines.direction.east })
        belt.get_transport_line(1).insert_at_back({ name = "iron-plate", count = 1 })
        belt.get_transport_line(2).insert_at_back({ name = "copper-plate", count = 1 })
      `);
      const read = await bridge.call<any>("inspect", { targets: [{ x: 30.5, y: 36.5 }] });
      const belt = read.entities?.[0];
      expect(belt?.lanes?.left?.["iron-plate"] === 1 && belt?.lanes?.right?.["copper-plate"] === 1, "line 1 is the left lane", belt);
      expect(belt.lane_mix === "separated", "one kind on each lane is separated", belt);
      return `lanes ${JSON.stringify(belt.lanes)}, ${belt.lane_mix}`;
    },
  },
  {
    name: "build_layout dry run on a platform reports belt_joins and port_fluids",
    async run(bridge) {
      await lua(`${BUILD}
        local p = game.forces.player.create_space_platform({ name = "live", planet = "nauvis", starter_pack = "space-platform-starter-pack" })
        p.apply_starter_pack()
        local s, tiles = p.surface, {}
        for x = 5, 24 do for y = -5, 4 do tiles[#tiles + 1] = { name = "space-platform-foundation", position = { x, y } } end end
        s.set_tiles(tiles)
        local belt = make(s, "transport-belt", 12.5, 0.5, { direction = defines.direction.east })
        belt.get_transport_line(1).insert_at_back({ name = "iron-plate", count = 1 })
        belt.get_transport_line(2).insert_at_back({ name = "copper-plate", count = 1 })
        make(s, "pipe", 19.5, -1.5).insert_fluid({ name = "water", amount = 50 })
        game.forces.player.recipes["lubricant"].enabled = true
      `);
      const check = await bridge.call<any>("build_layout", { check_only: true, platform: "live", anchor: { x: 0, y: 0 }, entities: [
        { name: "transport-belt", dx: 10.5, dy: 0.5, direction: 4 },
        { name: "transport-belt", dx: 11.5, dy: 0.5, direction: 4 },
        { name: "chemical-plant", dx: 20.5, dy: 0.5, recipe: "lubricant" },
      ] });
      expect(check.ok === true && list(check.placed).length === 3, "the layout fits", check.failed ?? check);
      const join = list(check.belt_joins).find((row: any) => row.x === 12.5 && row.y === 0.5);
      expect(join?.standing === true && join.join === "straight" && join.from?.x === 11.5, "the planned belt joins the standing one from behind", check.belt_joins);
      const lanes = Object.fromEntries(list(join.lanes).map((lane) => [lane.lane, lane.items]));
      expect(lanes.left?.[0] === "iron-plate" && lanes.right?.[0] === "copper-plate", "the join carries each standing lane's items", join.lanes);
      const port = list(check.port_fluids).find((row: any) => row.port?.x === 19.5 && row.port?.y === -1.5);
      expect(port?.role === "input" && port.fluid === "heavy-oil" && port.meets === "pipe" && port.carries?.[0] === "water" && port.mismatch === true,
        "the lubricant inlet meeting a water pipe is a mismatch", check.port_fluids);
      return `belt join ${join.join}; port ${port.fluid} meets ${port.carries[0]} (mismatch)`;
    },
  },
  {
    name: "rpc.to_json writes NaN and infinities as null",
    async run() {
      const json = await lua<string>(`return rpc.to_json({ nan = 0/0, inf = 1/0, list = { -1/0, 2, -(0/0) }, text = "nan inf" })`);
      const value = JSON.parse(json);
      expect(value.nan === null && value.inf === null && JSON.stringify(value.list) === "[null,2,null]" && value.text === "nan inf",
        "non-finite numbers become null and strings stay", value);
      return json;
    },
  },
  {
    name: "items.move keeps durability and quality",
    async run() {
      const moved = await lua<any>(`${BUILD}
        local s = game.surfaces.nauvis
        local from = make(s, "wooden-chest", 33.5, 38.5).get_inventory(defines.inventory.chest)
        local to = make(s, "wooden-chest", 35.5, 38.5).get_inventory(defines.inventory.chest)
        from.insert({ name = "repair-pack", count = 1 })
        from.find_item_stack("repair-pack").durability = 150
        from.insert({ name = "iron-gear-wheel", count = 5, quality = "uncommon" })
        from.insert({ name = "iron-gear-wheel", count = 3 })
        local items = mod("items")
        local packs, gears = items.move(from, to, "repair-pack", nil, 1), items.move(from, to, "iron-gear-wheel", "uncommon", 5)
        local pack = to.find_item_stack("repair-pack")
        return { packs = packs, gears = gears, durability = pack and pack.durability,
          uncommon = to.get_item_count({ name = "iron-gear-wheel", quality = "uncommon" }),
          normal_moved = to.get_item_count({ name = "iron-gear-wheel", quality = "normal" }), left = from.get_item_count() }`);
      expect(moved.packs === 1 && moved.durability === 150, "the used repair pack keeps its durability", moved);
      expect(moved.gears === 5 && moved.uncommon === 5 && moved.normal_moved === 0 && moved.left === 3, "only the uncommon gears move", moved);
      return JSON.stringify(moved);
    },
  },
  {
    name: "place_entity takes the item stacks lying on its footprint into the body's inventory",
    async run(bridge) {
      await characterStandIn();
      const lying = await lua<any[]>(`
        local s, c = game.surfaces.nauvis, mod("companion").get()
        c.get_main_inventory().clear()
        c.insert({ name = "assembling-machine-1", count = 1 })
        local out = {}
        for _, spec in ipairs({ { "iron-plate", 7, 163.3, 30.7 }, { "copper-cable", 5, 162.4, 29.6 } }) do
          local e = assert(s.create_entity({ name = "item-on-ground", position = { spec[3], spec[4] },
            stack = { name = spec[1], count = spec[2] } }))
          out[#out + 1] = { item = spec[1], count = spec[2], x = e.position.x, y = e.position.y }
        end
        return out`);
      const status = await runPlan(bridge, [{ action: "place_entity", name: "assembling-machine-1", x: 163.5, y: 30.5 }]);
      const step = list(status.outcomes)[0];
      expect(status.status === "completed" && step?.status === "completed", "the placement completes", status.outcomes);
      const picked = list(step.result?.picked_up);
      expect(picked.length === lying.length && lying.every((row) => picked.some((p) => p.item === row.item
        && p.count === row.count && p.x === row.x && p.y === row.y)), "picked_up names each stack with its exact position", { picked, lying });
      const after = await lua<any>(`
        local s, inventory = game.surfaces.nauvis, mod("companion").get().get_main_inventory()
        return { standing = s.find_entity("assembling-machine-1", { 163.5, 30.5 }) ~= nil,
          lying = s.count_entities_filtered({ area = { { 160.5, 27.5 }, { 166.5, 33.5 } }, type = "item-entity" }),
          carried = inventory.get_contents() }`);
      expect(after.standing === true, "the machine stands", after);
      expect(after.lying === 0, "no item stack is left on the footprint", after);
      const carried = Object.fromEntries(list(after.carried).map((row) => [row.name, row.count]));
      expect(carried["iron-plate"] === 7 && carried["copper-cable"] === 5 && Object.keys(carried).length === 2,
        "the inventory holds exactly the picked-up stacks (the placed machine left it)", after.carried);
      return `picked_up ${picked.map((p) => `${p.item} x${p.count} at (${p.x}, ${p.y})`).join(", ")}`;
    },
  },
  {
    name: "blueprint_capture centres a block and its origin puts it back where it stood",
    async run(bridge) {
      await characterStandIn();
      const area = { left_top: { x: 176, y: 40 }, right_bottom: { x: 185, y: 46 } };
      const built = await lua<any[]>(`${BUILD}
        local s, out = game.surfaces.nauvis, {}
        for _, e in ipairs({ make(s, "assembling-machine-1", 178.5, 42.5), make(s, "assembling-machine-1", 182.5, 42.5),
          (make(s, "small-electric-pole", 180.5, 44.5)) }) do
          out[#out + 1] = { name = e.name, x = e.position.x, y = e.position.y }
        end
        return out`);
      const captured = await bridge.call<any>("blueprint_capture", { name: "live-block", area });
      const described = await bridge.call<any>("blueprint_describe", { name: "live-block" });
      const origin = described.origin;
      expect(origin && captured.origin?.x === origin.x && captured.origin?.y === origin.y, "capture and describe give one origin",
        { captured: captured.origin, described: origin });
      expect(origin.x % 2 === 0 && origin.y % 2 === 0 && Math.abs(origin.x) > 100, "the origin is an even whole vector to the block", origin);
      const restores = (rows: any[]) => rows.length === built.length && built.every((e) =>
        rows.some((row) => row.name === e.name && origin.x + row.dx === e.x && origin.y + row.dy === e.y));
      const rows = list(described.entities);
      expect(rows.every((row) => Math.abs(row.dx) <= 4 && Math.abs(row.dy) <= 4), "the block sits about (0, 0)", rows);
      expect(restores(rows), "origin + dx/dy is each entity's world position", { origin, rows, built });
      // Hand mode builds blueprints.hand_layout at anchor = position; its
      // build_layout checks need the chart (see characterStandIn), so here
      // only the layout it would build is compared.
      const hand = list(await lua(`return mod("blueprints").hand_layout("live-block", nil, "live").entities`));
      expect(restores(hand), "the hand layout at anchor = origin puts each entity where it stood", hand);
      // Ghosts mode (native build_blueprint) puts each ghost at position + its
      // dx/dy, flipped then turned about (0, 0) as hand mode turns them:
      // unsnapped, the engine centred the block's box on position instead,
      // a tile off here (0, 1).
      await lua(`for _, e in pairs(game.surfaces.nauvis.find_entities_filtered({ area = { { 176, 40 }, { 185, 46 } }, force = "player" })) do
        e.destroy() end`);
      const key = (row: { name: string; x: number; y: number }) => `${row.name}@${row.x},${row.y}`;
      for (const placement of [{ direction: 0 }, { direction: 4, flip: "horizontal" }]) {
        const status = await runPlan(bridge, [{ action: "blueprint_place", name: "live-block", position: origin, mode: "ghosts", ...placement }]);
        expect(status.status === "completed", `the ghosts are placed (${JSON.stringify(placement)})`, status.outcomes);
        const ghosts = list(await lua(`local out = {}
          for _, g in pairs(game.surfaces.nauvis.find_entities_filtered({ area = { { 166, 30 }, { 196, 56 } }, type = "entity-ghost" })) do
            out[#out + 1] = { name = g.ghost_name, x = g.position.x, y = g.position.y }
            g.destroy()
          end
          return out`)).map(key).sort();
        const wanted = rows.map((row) => {
          let [x, y] = [placement.flip === "horizontal" ? -row.dx : row.dx, row.dy];
          for (let turn = 0; turn < placement.direction / 4; turn++) [x, y] = [-y, x];
          return key({ name: row.name, x: origin.x + x, y: origin.y + y });
        }).sort();
        expect(JSON.stringify(ghosts) === JSON.stringify(wanted), `each ghost stands at position + its dx/dy (${JSON.stringify(placement)})`,
          { ghosts, wanted });
      }
      return `origin (${origin.x}, ${origin.y}); dx/dy ${rows.map((row) => `${row.name} (${row.dx}, ${row.dy})`).join(", ")}; `
        + "ghosts at position = origin, plain and turned + flipped, stand at origin + dx/dy";
    },
  },
];

// Profiler lines (profiler.lua): "rpc <method> tick <tick> Duration: <ms>ms"
// for each RPC, "on_tick 600 ticks Duration: <ms>ms" for all tick handlers.
// The RPCs of one tick share its budget: ticks sums their time per tick.
function profile(log: string) {
  const rpcs: { method: string; tick: number; ms: number }[] = [], windows: number[] = [];
  for (const match of log.matchAll(/ rpc (\S+) tick (\d+) Duration: ([\d.]+)ms/g)) {
    rpcs.push({ method: match[1]!, tick: Number(match[2]), ms: Number(match[3]) });
  }
  for (const match of log.matchAll(/ on_tick (\d+) ticks Duration: ([\d.]+)ms/g)) windows.push(Number(match[2]) / Number(match[1]));
  const ticks = new Map<number, { ms: number; methods: string[] }>();
  for (const row of rpcs) {
    const tick = ticks.get(row.tick) ?? { ms: 0, methods: [] };
    tick.ms += row.ms;
    tick.methods.push(row.method);
    ticks.set(row.tick, tick);
  }
  return { rpcs, windows, ticks: [...ticks].map(([tick, row]) => ({ tick, ...row })) };
}
// Stdin is closed, which the server logs as an error and ignores.
const BENIGN_ERRORS = [/InterruptibleStdioStream\.cpp.*Got EOF on stdin/];

const failures: string[] = [];
const report = (ok: boolean, name: string, detail: string) => {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? `\n     ${detail}` : ""}`);
  if (!ok) failures.push(name);
};

try {
  console.log(`live suite: ${bin}, seed ${SEED}, temp dir ${dir}`);
  const bridge = await startServer();
  const ping = await bridge.call<any>("ping");
  assertRuntimeCompatibility(ping, companionVersion());
  expect(String(ping.factorio_version).startsWith("2.0."), "the live suite targets Factorio 2.0.x", ping.factorio_version);
  console.log(`server up: Factorio ${ping.factorio_version}, mod ${ping.mod_version}, protocol ${ping.protocol_version}`);
  await setup();
  for (const scenario of scenarios) {
    try { report(true, scenario.name, await scenario.run(bridge)); }
    catch (error) { report(false, scenario.name, error instanceof Error ? error.message : String(error)); }
  }
  // One full profiler window after the scenarios, so their tick work is logged.
  const tick = await lua<number>("return game.tick");
  await until("the next profiler window", () => lua<boolean>(`return game.tick >= ${(Math.floor(tick / 600) + 2) * 600}`), 60_000);
  const after = await bridge.call<any>("ping");
  report(after.handler_errors === undefined, "no mod handler raised an error", after.handler_errors ? JSON.stringify(after.handler_errors) : "");
  const log = fs.readFileSync(paths.log, "utf8");
  const errors = log.split("\n").filter((line) => /\berror\b/i.test(line) && !line.includes("[COMMAND]")
    && !BENIGN_ERRORS.some((pattern) => pattern.test(line)));
  report(errors.length === 0, "the server log has no script errors", errors.slice(0, 5).join(" | "));
  const { rpcs, windows, ticks } = profile(log);
  const slow = rpcs.filter((row) => row.ms > TICK_BUDGET_MS);
  const slowTicks = ticks.filter((row) => row.ms > TICK_BUDGET_MS);
  const slowestTick = ticks.reduce<(typeof ticks)[number] | undefined>((worst, row) => (!worst || row.ms > worst.ms ? row : worst), undefined);
  const worstWindow = Math.max(0, ...windows);
  report(rpcs.length > 0 && windows.length > 0 && slow.length === 0 && slowTicks.length === 0 && worstWindow <= TICK_BUDGET_MS,
    `every rpc, the rpcs of each tick, and the 600-tick on_tick average stay within ${TICK_BUDGET_MS} ms`,
    `${rpcs.length} rpcs, slowest ${rpcs.length ? Math.max(...rpcs.map((row) => row.ms)).toFixed(2) : "-"} ms`
      + `${slow.length ? ` (over budget: ${slow.map((row) => `${row.method} ${row.ms.toFixed(2)}`).join(", ")})` : ""}; `
      + `${ticks.length} rpc ticks, slowest ${slowestTick ? `${slowestTick.ms.toFixed(2)} ms at tick ${slowestTick.tick}`
        + ` (${slowestTick.methods.join(", ")})` : "-"}`
      + `${slowTicks.length ? ` (over budget: ${slowTicks.map((row) => `tick ${row.tick} ${row.ms.toFixed(2)}`).join(", ")})` : ""}; `
      + `${windows.length} tick windows, worst average ${worstWindow.toFixed(3)} ms/tick`);
} catch (error) {
  report(false, "live server", `${error instanceof Error ? error.message : String(error)}; log: ${logTail()}`);
} finally {
  await cleanup();
}
console.log(failures.length ? `live suite: ${failures.length} failed` : "live suite: all passed");
process.exit(failures.length ? 1 : 0);
