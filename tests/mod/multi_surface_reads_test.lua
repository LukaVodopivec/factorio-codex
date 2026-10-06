-- Reads per surface (C3, C7, C8; rule 6): the registry and the line sampler
-- keep every factory surface (Nauvis, Vulcanus and a platform here), lines
-- never merge across surfaces, factory_status describes one surface and
-- sums up the others in `elsewhere`, stock is per surface, planet machines
-- and states are sampled, labs with no research are a problem row, patch
-- caches are per planet surface, and map_summary keeps its surface in the
-- job. Engine calls are counted per read and per tick with the surfaces
-- populated. Surfaces, forces and entities are strict 2.0.77 mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local RAW = { working = 1, no_power = 2, frozen = 3, no_research_in_progress = 4, waiting_for_plants_to_grow = 5,
  waiting_for_space_in_platform_hub = 6, no_spot_seedable_by_inputs = 7, normal = 8, full_output = 9 }
_G.defines = { entity_status = RAW, inventory = { chest = 1, crafter_input = 2, lab_input = 3 },
  target_type = { entity = 7 }, flow_precision_index = { five_seconds = 0, one_minute = 1 },
  rocket_silo_status = { rocket_ready = 10 } }
_G.storage = {}
_G.script = { register_on_object_destroyed = function() return 1 end }
local PLATE = { name = "iron-plate", ingredients = { { name = "iron-ore", type = "item", amount = 1 } },
  products = { { name = "iron-plate", type = "item", amount = 1 } } }
_G.prototypes = { recipe = { ["iron-plate"] = PLATE }, item = {},
  space_location = { nauvis = {}, vulcanus = {}, gleba = {}, fulgora = {}, aquilo = {} } }

-- Engine calls a read or a tick makes: entity queries per surface, chart
-- checks, statistics reads, location checks and machine samples.
local calls = { finds = {}, charted = 0, statistics = 0, unlocked = 0, samples = 0, chunk_lists = 0 }
local function count(key) calls[key] = calls[key] + 1 end
local entities_on = { {}, {}, {} }
local function surface(index, name, extra)
  local values = { index = index, name = name, valid = true,
    find_entities_filtered = function(filter)
      calls.finds[name] = (calls.finds[name] or 0) + 1
      local found = {}
      for _, e in ipairs(entities_on[index]) do
        if (filter.type == nil or e.type == filter.type) and (filter.force == nil or e.force == filter.force) then
          found[#found + 1] = e
        end
      end
      return found
    end,
    get_chunks = function()
      count("chunk_lists")
      local list, i = { { x = 0, y = 0 }, { x = 1, y = 0 } }, 0
      return function() i = i + 1; return list[i] end
    end,
    get_property = function() return 100 end,
    is_chunk_generated = function() return true end,
  }
  for key, value in pairs(extra or {}) do values[key] = value end
  return mock.surface(values)
end
local nauvis = surface(1, "nauvis", { planet = mock.planet({ name = "nauvis" }) })
local vulcanus = surface(2, "vulcanus", { planet = mock.planet({ name = "vulcanus" }) })
local platform = mock.space_platform({ valid = true, index = 1, name = "alpha", scheduled_for_deletion = 0 })
local deck = surface(3, "platform-1", { platform = platform })
local by_index = { nauvis, vulcanus, deck }
local unlocked = { nauvis = true, vulcanus = true }
local item_stats = {}
local force = mock.force({ name = "player",
  is_chunk_charted = function(target, chunk) count("charted"); return chunk.x >= 0 and chunk.x <= 1 and chunk.y == 0 end,
  is_chunk_visible = function() return true end,
  is_space_location_unlocked = function(name) count("unlocked"); return unlocked[name] == true end,
  get_item_production_statistics = function(target)
    count("statistics")
    return item_stats[target.index]
  end,
  get_fluid_production_statistics = function(target)
    count("statistics")
    return mock.flow_statistics({ input_counts = {}, output_counts = {}, get_flow_count = function() return 0 end })
  end,
  technologies = {}, research_queue = {}, research_progress = 0, platforms = {} })
for index, produced in pairs({ [1] = { ["iron-plate"] = 600 }, [2] = { ["iron-plate"] = 60, calcite = 90 }, [3] = {} }) do
  item_stats[index] = mock.flow_statistics({ input_counts = produced, output_counts = {},
    get_flow_count = function(args)
      return args.category == "input" and (produced[args.name] or 0) or 0
    end })
end
_G.game = { tick = 0, forces = { player = force }, get_surface = function(index) return by_index[index] end,
  planets = { nauvis = mock.planet({ name = "nauvis", surface = nauvis }), vulcanus = mock.planet({ name = "vulcanus", surface = vulcanus }) } }

-- The body: a character on Nauvis.
local main = mock.inventory({ get_contents = function() return { { name = "coal", quality = "normal", count = 20 } } end })
local body = mock.entity({ valid = true, name = "character", type = "character", position = { x = 5, y = 5 },
  surface = nauvis, surface_index = 1, force = force, crafting_queue_size = 0,
  get_main_inventory = function() return main end, get_health_ratio = function() return 0.75 end })
package.loaded["scripts.companion"] = { human_control = function() return false, 999 end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
package.loaded["scripts.tasks"] = { queue_length = function() return 0 end, active_summary = function() return nil end }

local next_unit = 100
local state = require("scripts.state")
local registry = require("scripts.registry")
local autonomy = require("scripts.autonomy")
local map_summary = require("scripts.map_summary")
local factory_status = require("scripts.factory_status")
local jobs = require("scripts.jobs")
state.init()
storage.registry.ready, storage.registry.force = true, "player"

-- Machines: the same two furnace positions on Nauvis and on Vulcanus, a
-- lab on Nauvis while no research is active, a frozen assembler and a farm
-- waiting for its plants on Vulcanus, an asteroid collector whose hub is
-- full on the platform.
local function machine(on, kind, name, x, y, status, extra)
  next_unit = next_unit + 1
  local values = { valid = true, name = name, type = kind, position = { x = x, y = y }, unit_number = next_unit,
    force = force, surface = by_index[on], surface_index = on,
    prototype = mock.entity_prototype({ name = name, electric_energy_source_prototype = nil }) }
  for key, value in pairs(extra or {}) do values[key] = value end
  local e = mock.entity(values)
  mock.state(e).status = RAW[status]
  mock.read(e, "status", function() count("samples"); return mock.state(e).status end)
  entities_on[on][#entities_on[on] + 1] = e
  registry.add(e)
  return e
end
local function furnace(on, x, y)
  return machine(on, "furnace", "stone-furnace", x, y, "working", { products_finished = 0,
    get_recipe = function() return PLATE end })
end
local nauvis_furnaces = { furnace(1, 0, 0), furnace(1, 0, 2) }
local vulcanus_furnaces = { furnace(2, 0, 0), furnace(2, 0, 2) }
local lab = machine(1, "lab", "lab", 10, 0, "no_research_in_progress")
machine(2, "assembling-machine", "foundry", 20, 0, "frozen", { products_finished = 0, get_recipe = function() return nil end })
machine(2, "agricultural-tower", "agricultural-tower", 30, 0, "waiting_for_plants_to_grow")
machine(3, "asteroid-collector", "asteroid-collector", 0, -4, "full_output")
local function chest(on, x, y, contents)
  return machine(on, "container", "iron-chest", x, y, "normal", { get_inventory = function()
    return mock.inventory({ get_contents = function() return contents end })
  end })
end
chest(1, 4, 4, { { name = "iron-plate", quality = "normal", count = 50 }, { name = "iron-plate", quality = "rare", count = 7 } })
chest(2, 4, 4, { { name = "calcite", quality = "normal", count = 30 } })
-- A chest holding two spoilable items (the largest holder of both): its
-- slots are read once for both stock rows.
prototypes.item.yumako = { get_spoil_ticks = function() return 3600 end }
prototypes.item.jellynut = { get_spoil_ticks = function() return 3600 end }
local slot_reads = 0
local fruit_slots = {}
for i, row in ipairs({ { "yumako", 40 }, { "jellynut", 30 } }) do
  fruit_slots[i] = setmetatable({}, { __index = function(_, key)
    slot_reads = slot_reads + 1
    local values = { valid_for_read = true, name = row[1], count = row[2], spoil_tick = 10000 + 600 * i, spoil_percent = 0.1 * i }
    return values[key]
  end })
end
machine(1, "container", "iron-chest", 8, 8, "normal", { get_inventory = function()
  return setmetatable({ get_contents = function()
    return { { name = "yumako", quality = "normal", count = 40 }, { name = "jellynut", quality = "normal", count = 30 } }
  end }, { __len = function() return #fruit_slots end, __index = fruit_slots })
end })
-- A chest on the platform, in a chunk the engine does not report charted:
-- all of a platform counts as charted (one chart rule).
chest(3, 1, -4, { { name = "iron-gear-wheel", quality = "normal", count = 12 } })

local surfaces_list = registry.surfaces()
check(#surfaces_list == 3 and surfaces_list[1] == 1 and surfaces_list[2] == 2 and surfaces_list[3] == 3,
  "the registry's factory surfaces are every surface with own entities")
check(#registry.machines({ "furnace" }) == 2 and #registry.machines({ "furnace" }, 2) == 2
  and #registry.machines(nil, "all") == 8, "registry reads default to the body's surface; an index or all names others")

-- A line refresh starts from the machines' unit numbers (no engine read, no
-- sort) and then checks each machine's chunk, once per surface and chunk.
local charted_before = calls.charted
local units = registry.machine_units()
check(#units == 8 and calls.charted == charted_before, "the refresh's machine list is a pure Lua pass (8 machines)")
local cache, found = {}, 0
for _, unit in ipairs(units) do
  if registry.charted_machine(unit, force, cache) then found = found + 1 end
end
check(found == 8 and calls.charted - charted_before <= 3,
  "each machine's chunk is checked once per surface and chunk (" .. calls.charted - charted_before .. " checks)")

-- The sampler: every machine on every surface once per 30 ticks.
for tick = 1, 700 do
  game.tick = tick
  autonomy.on_tick(tick)
  -- Furnaces make plates; the cursor keeps the stock aggregates.
  if tick % 60 == 0 then
    for _, f in ipairs(nauvis_furnaces) do f.products_finished = f.products_finished + 1 end
    for _, f in ipairs(vulcanus_furnaces) do f.products_finished = f.products_finished + 1 end
  end
  if tick % 30 == 0 then map_summary.status_tick(tick) end
end
calls.samples = 0
for tick = 701, 730 do game.tick = tick; autonomy.on_tick(tick) end
check(calls.samples == 8, "each of the 8 machines on three surfaces is sampled once per 30 ticks (" .. calls.samples .. ")")
check(registry.stock_totals({ "iron-gear-wheel" }, 3)["iron-gear-wheel"] == 12,
  "a platform's holders count in its stock, whatever the engine's chart says of its chunks")
local nauvis_lines, vulcanus_lines = autonomy.lines(nil, 1), autonomy.lines(nil, 2)
local function line_of(rows, product, entity)
  for _, row in ipairs(rows) do
    if (product and row.product == product) or (entity and row.entity == entity) then return row end
  end
end
check(line_of(nauvis_lines, "iron-plate").machines == 2 and line_of(vulcanus_lines, "iron-plate").machines == 2
  and line_of(nauvis_lines, "iron-plate").id ~= line_of(vulcanus_lines, "iron-plate").id,
  "furnaces at the same position on two surfaces form two lines, never one")
check(line_of(vulcanus_lines, nil, "foundry").state == "frozen" and line_of(vulcanus_lines, nil, "agricultural-tower").state == "running"
  and line_of(autonomy.lines(nil, 3), nil, "asteroid-collector").state == "output_full",
  "planet states: frozen, a farm growing counts as running, a collector with a full hub is output_full")
local lab_line = line_of(nauvis_lines, "research")
check(lab_line.state == "idle" and lab_line.cause == "no_research", "labs with no research active are idle: no_research")

-- factory_status on the body's surface, with the others summed up.
calls.finds, calls.statistics, calls.unlocked, calls.samples = {}, 0, 0, 0
local status = factory_status.factory_status({})
local finds = 0
for _, n in pairs(calls.finds) do finds = finds + n end
local research_idle
for _, row in ipairs(status.problems) do if row.status == "no_research_in_progress" then research_idle = row end end
check(status.surface == "nauvis" and line_of(status.lines, "iron-plate") and #status.lines == 2
  and research_idle and research_idle.cause == "research_idle" and research_idle.name == "lab",
  "factory_status describes the body's surface; research standing still is a problem row")
local elsewhere = {}
for _, row in ipairs(status.elsewhere or {}) do elsewhere[row.surface] = row end
check(elsewhere.vulcanus and elsewhere.vulcanus.lines_total == 3 and elsewhere.vulcanus.lines_running == 2
  and elsewhere.vulcanus.problems == 1 and elsewhere.vulcanus.top_problems[1].status == "frozen"
  and elsewhere["platform:1"] and elsewhere["platform:1"].lines_total == 1 and elsewhere.nauvis == nil,
  "elsewhere sums up every other factory surface: lines, problems, the worst ones")
-- One pass gives every surface's line counts and problems, the same as the
-- per-surface reads.
local overview = autonomy.by_surface()
local same_counts = true
for index = 1, 3 do
  local counts, problems = autonomy.counts(index), autonomy.problems(nil, index)
  local row = overview[index]
  if not (row and row.line_count == counts.line_count and row.running_line_count == counts.running_line_count
    and #row.problems == #problems) then same_counts = false end
end
check(same_counts, "autonomy.by_surface gives each surface's counts and problems in one pass")
-- Power elsewhere: of two networks short of power, only the neediest one's
-- statistics are read; the other is judged by its nameplate.
local stat_reads = 0
local function short_net(id, demand, produced)
  local pole = { valid = true, electric_network_id = id, electric_network_statistics = {
    output_counts = { ["steam-engine"] = 1 },
    get_flow_count = function() stat_reads = stat_reads + 1; return produced / 60 end } }
  return { id = id, pole = pole, starved = 1, demand_w = demand,
    sources = { steam = { count = 1, nameplate_w = 900000 } }, accumulators = { count = 0 } }
end
local lowest, power_reads = map_summary.power_min_satisfaction({ short_net(1, 100000, 50000), short_net(2, 400000, 100000) })
check(lowest == 0.25 and stat_reads == 1 and power_reads >= 1,
  "power elsewhere reads the statistics of one starved network a surface (" .. stat_reads .. " reads)")
check(#status.unlocked_locations == 2 and status.unlocked_locations[1] == "nauvis" and status.unlocked_locations[2] == "vulcanus",
  "the header lists the unlocked space locations")
check(status.body.state == nil and status.body.surface == nil and status.body.health_ratio == 0.75,
  "standing on the read's surface the body section has no state or surface; a wounded body gives its health")
local stock, spoils = {}, {}
for _, row in ipairs(status.stock) do stock[row.item], spoils[row.item] = row.total, row.spoils_in_s end
check(spoils.yumako and spoils.jellynut and spoils.jellynut - spoils.yumako == 10 and slot_reads <= 6 * #fruit_slots,
  "spoilable stock rows with one largest holder read its slots once (" .. slot_reads .. " slot reads)")
check(stock["iron-plate"] == 50 and stock["iron-plate@rare"] == 7 and stock.calcite == nil,
  "stock is the body's surface's, a non-normal quality keyed name@quality")
check(finds == 0 and calls.samples == 0 and calls.statistics == 0 and calls.unlocked == 5,
  "a factory_status read with three surfaces queries no entity and reads no machine (" .. finds .. " queries, "
    .. calls.unlocked .. " location checks)")
local function size(value)
  local kind = type(value)
  if kind == "string" then return #value + 2 end
  if kind ~= "table" then return #tostring(value) end
  local total = 2
  for key, inner in pairs(value) do total = total + #tostring(key) + 4 + size(inner) end
  return total
end
check(size(status) < 6144, "the default read with elsewhere stays under 6 KB (" .. size(status) .. ")")

-- Another surface named: its lines and stock; the body is elsewhere.
local remote = factory_status.factory_status({ surface = "vulcanus" })
local remote_stock = {}
for _, row in ipairs(remote.stock) do remote_stock[row.item] = row.total end
local remote_elsewhere = {}
for _, row in ipairs(remote.elsewhere or {}) do remote_elsewhere[row.surface] = row end
check(remote.surface == "vulcanus" and #remote.lines == 3 and remote_stock.calcite == 30 and remote_stock["iron-plate"] == nil
  and remote_elsewhere.nauvis and remote_elsewhere.nauvis.lines_total == 2 and remote.body.surface == "nauvis",
  "factory_status {surface} reads that surface; the body's own surface joins elsewhere")
check(not pcall(factory_status.factory_status, { surface = "atlantis" }), "an unknown surface is refused")

-- A summary works out once whether its surface is a platform's: its scan
-- reads the surface's index a bounded number of times, not once per entity.
local index_reads = 0
mock.read(vulcanus, "index", function() index_reads = index_reads + 1; return 2 end)
jobs.run_now(map_summary.summary_job, { surface = "vulcanus" })
mock.read(vulcanus, "index", function() return 2 end)
check(index_reads <= 6, "a summary's scan reads its surface's index a bounded number of times (" .. index_reads .. ")")

-- A summary a 0.22.2 save left mid-job resumes on 0.22.3: one left at its
-- finish reads its flows first; one in flows_all had listed every name.
local function resume(S)
  for _ = 1, 50 do
    local done = map_summary.summary_job.step(S, { left = 600 })
    if done then return done end
  end
end
-- Steps a new job a work item at a time until it stands at that stage.
local function advance_to(S, stage)
  for _ = 1, 5000 do
    if S.stage == stage then return S end
    map_summary.summary_job.step(S, { left = 1 })
  end
end
local at_finish = advance_to(map_summary.summary_job.start({ surface = "vulcanus", flow_items = { "calcite" } }), "flows_all")
at_finish.stage = "finish"
local finished = resume(at_finish)
check(finished and finished.factory.force_flows[1].name == "calcite" and finished.factory.force_flows[1].input_rate == 90,
  "a summary left at its finish by an older save reads its flows before it finishes")
local in_all = advance_to(map_summary.summary_job.start({ surface = "vulcanus", include = { "flows_all" } }), "flows_all")
in_all.all = { rows = { { name = "calcite", kind = "item", lifetime_produced = 90,
  lifetime_consumed = 0 } }, next = 1 }
local listed = resume(in_all)
check(listed and listed.force_flows_all and listed.force_flows_all[1].name == "calcite"
  and listed.force_flows_all[1].produced_per_minute == 90,
  "a flows_all section an older save left with its names listed goes on to their rates")

-- map_summary keeps its surface in the job: started on Vulcanus while the
-- body stands on Nauvis, it reads only Vulcanus, even after the body moves.
calls.finds = {}
local summary = jobs.run_now(map_summary.summary_job, { surface = "vulcanus" })
check(summary.surface == "vulcanus" and (calls.finds.vulcanus or 0) > 0 and calls.finds.nauvis == nil,
  "map_summary {surface} scans that surface only")
local calcite = jobs.run_now(map_summary.summary_job, { surface = "vulcanus", flow_items = { "calcite", "iron-plate" } })
check(calcite.factory.force_flows[1].name == "calcite" and calcite.factory.force_flows[1].input_rate == 90
  and calcite.factory.force_flows[2].input_rate == 60, "map_summary reads that surface's flow statistics")
local all = jobs.run_now(map_summary.summary_job, { surface = "all", flow_items = { "iron-plate" } })
check(all.factory.flow_surface == "all" and all.factory.force_flows[1].name == "iron-plate"
  and all.factory.force_flows[1].input_rate == 660, "surface:all sums the flows of every factory surface")
calls.finds = {}
local S = map_summary.summary_job.start({})
body.surface, body.surface_index = vulcanus, 2
local result
for _ = 1, 50 do
  result = map_summary.summary_job.step(S, { left = 4 })
  if result then break end
end
check(result and result.surface == "nauvis" and calls.finds.vulcanus == nil and (calls.finds.nauvis or 0) > 0,
  "a summary started on Nauvis keeps reading Nauvis when the body changes surface")
body.surface, body.surface_index = nauvis, 1

-- Patch caches: one per planet surface, made by the force's chart; a
-- platform gets none; one cache works a tick.
map_summary.on_chunk_charted({ force = force, surface_index = 1, position = { x = 0, y = 0 } })
map_summary.on_chunk_charted({ force = force, surface_index = 2, position = { x = 0, y = 0 } })
map_summary.on_chunk_charted({ force = force, surface_index = 3, position = { x = 0, y = 0 } })
check(storage.patch_caches[1] and storage.patch_caches[2] and storage.patch_caches[3] == nil,
  "a charted chunk makes its planet surface's patch cache; a platform has none")
local per_tick = {}
for tick = 2000, 2007 do
  calls.finds = {}
  map_summary.patch_tick(tick)
  per_tick[#per_tick + 1] = (calls.finds.nauvis or 0) + (calls.finds.vulcanus or 0)
end
local most = 0
for _, n in ipairs(per_tick) do most = math.max(most, n) end
check(most <= 2 and storage.patch_caches[1].seeded and storage.patch_caches[2].seeded,
  "patch caches take turns: at most two chunk reads a tick across the planets (" .. table.concat(per_tick, ",") .. ")")
check(select(1, map_summary.patches(2)) ~= nil and map_summary.patches(3) ~= nil,
  "patches are read per surface")

-- A fresh planet problem must not relabel an old platform problem as news.
-- Use the native sampler/debounce rather than fabricating announcement state.
local problem_cursor = game.tick
mock.state(vulcanus_furnaces[1]).status = RAW.frozen
for tick = problem_cursor + 1, problem_cursor + 150 do
  game.tick = tick
  autonomy.on_tick(tick)
end
local changed = factory_status.factory_status({ sections = { "problems", "elsewhere" }, since_tick = problem_cursor })
local changed_elsewhere = {}
for _, row in ipairs(changed.elsewhere or {}) do changed_elsewhere[row.surface] = row end
check(changed_elsewhere.vulcanus and changed_elsewhere.vulcanus.problems == 1
  and #changed_elsewhere.vulcanus.top_problems == 1
  and changed_elsewhere.vulcanus.top_problems[1].name == "stone-furnace"
  and changed_elsewhere["platform:1"].problems == 0
  and #changed_elsewhere["platform:1"].top_problems == 0,
  "since_tick elsewhere reports the newly matured planet problem without repeating old platform backpressure")
local fresh_overview = autonomy.by_surface(problem_cursor)
local consistent = true
for index = 1, 3 do
  if #fresh_overview[index].problems ~= #autonomy.problems(problem_cursor, index) then consistent = false end
end
check(consistent and fresh_overview[2].line_count == autonomy.counts(2).line_count,
  "cursor-filtered all-surface problems match per-surface reads while line counts remain current")
local fresh_record = storage.autonomy.machines[vulcanus_furnaces[1].unit_number]
local announced = fresh_record.problem_announced_tick
check(#autonomy.by_surface(announced)[2].problems == #autonomy.problems(announced, 2)
  and #autonomy.by_surface(announced)[2].problems > 0,
  "all-surface readback preserves the existing inclusive announcement boundary")
-- Saves made before announcement ticks were stored use the episode start.
fresh_record.problem_announced_tick = nil
check(#autonomy.by_surface(fresh_record.problem_since)[2].problems
    == #autonomy.problems(fresh_record.problem_since, 2)
  and #autonomy.by_surface(fresh_record.problem_since + 1)[2].problems
    == #autonomy.problems(fresh_record.problem_since + 1, 2),
  "legacy problem records use the same episode-start cursor fallback on every surface")
fresh_record.problem_announced_tick = announced
local after_news = factory_status.factory_status({ sections = { "elsewhere" }, since_tick = game.tick + 1 })
local no_news = true
for _, row in ipairs(after_news.elsewhere) do
  if row.problems ~= 0 or #row.top_problems ~= 0 then no_news = false end
end
check(no_news, "an elsewhere cursor after all announcements has no repeated problem rows")

-- The benchmark clock rides along only while a trial exists, whatever the sections.
check(status.trial == nil and after_news.trial == nil, "no trial field without a benchmark")
local benchmark = require("scripts.benchmark")
local real_trial = benchmark.trial
benchmark.trial = function() return { status = "running", remaining_seconds = 900 } end
local timed = factory_status.factory_status({ sections = { "elsewhere" } })
check(timed.trial and timed.trial.remaining_seconds == 900, "factory_status carries the benchmark trial")
benchmark.trial = real_trial
local current = factory_status.factory_status({ sections = { "elsewhere" } })
local current_platform
for _, row in ipairs(current.elsewhere) do if row.surface == "platform:1" then current_platform = row end end
check(current_platform and current_platform.problems > 0 and #current_platform.top_problems > 0,
  "an unfiltered current-state read still exposes persistent platform problems")

-- A deleted surface (a platform removed) leaves the factory surfaces.
registry.on_surface_deleted({ surface_index = 3 })
local after = registry.surfaces()
check(#after == 2 and after[2] == 2, "a deleted surface takes its aggregates with it")

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
