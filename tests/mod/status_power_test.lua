-- 0.22 factory_status depth: line states and causes for every status the
-- sampler maps (autonomy.lua), beacons and roboports as problems only, the
-- reactor temperature, the power model built from the registry's network
-- aggregates (map_summary.build_power: day/night light, the planet's
-- solar-power property, accumulators, add_to_cover) and the opt-in
-- logistics section. Entities, prototypes, surfaces and statistics are
-- strict 2.0.77 mocks; engine reads are counted per tick and per read.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local NAMES = { "working", "no_power", "low_power", "no_fuel", "full_output", "no_ingredients", "missing_required_fluid",
  "no_input_fluid", "low_input_fluid", "pipeline_overextended", "no_recipe", "recipe_not_researched",
  "full_burnt_result_output", "low_temperature", "disabled_by_control_behavior", "disabled_by_script",
  "no_modules_to_transmit", "normal", "no_minable_resources", "missing_science_packs" }
local RAW = {}
for index, name in ipairs(NAMES) do RAW[name] = index end
_G.defines = { entity_status = RAW, inventory = { crafter_input = 2, lab_input = 3 },
  flow_precision_index = { five_seconds = 0 }, events = {} }
local PLATE = { name = "iron-plate", ingredients = { { name = "iron-ore", type = "item", amount = 1 } },
  products = { { name = "iron-plate", type = "item", amount = 1 } } }
local GEAR = { name = "iron-gear-wheel", ingredients = { { name = "iron-plate", type = "item", amount = 2 } },
  products = { { name = "iron-gear-wheel", type = "item", amount = 1 } } }
_G.prototypes = { recipe = { ["iron-plate"] = PLATE }, entity = {
  ["steam-engine"] = { type = "generator", get_max_energy_production = function() return 15000 end },
  ["solar-panel"] = { type = "solar-panel", get_max_energy_production = function() return 1000 end },
  accumulator = { type = "accumulator", electric_energy_source_prototype = { buffer_capacity = 5000000 } } } }
_G.game = { tick = 0 }
_G.storage = {}
_G.script = { register_on_object_destroyed = function() return 1 end }

local surface_values = { index = 1, name = "nauvis", solar_power_multiplier = 1, always_day = false, daytime = 0,
  ticks_per_day = 25000, daytime_parameters = { dusk = 0.25, evening = 0.45, morning = 0.55, dawn = 0.75 } }
local surface_reads = 0
local surface = mock.surface({ index = 1, name = "nauvis",
  get_property = function(name) surface_reads = surface_reads + 1; assert(name == "solar-power"); return surface_values.power or 100 end })
for _, key in ipairs({ "solar_power_multiplier", "always_day", "daytime", "ticks_per_day", "daytime_parameters", "platform" }) do
  mock.read(surface, key, function() surface_reads = surface_reads + 1; return surface_values[key] end)
end
local force = mock.force({ name = "player", is_chunk_charted = function() return true end })
local body = { valid = true, position = { x = 0, y = 0 }, force = force, surface = surface }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end,
  human_control = function() return false, 999 end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)

local state = require("scripts.state")
local registry = require("scripts.registry")
local autonomy = require("scripts.autonomy")
local map_summary = require("scripts.map_summary")
state.init()
storage.registry.ready, storage.registry.force = true, "player"

local reads, next_unit = 0, 100
local function electric_prototype(extra)
  local values = { electric_energy_source_prototype = {}, get_max_energy_usage = function() return 1000 end,
    get_max_energy_production = function() return 0 end }
  for key, value in pairs(extra or {}) do values[key] = value end
  return mock.entity_prototype(values)
end
local function machine(kind, name, x, y, status, extra)
  next_unit = next_unit + 1
  local values = { valid = true, name = name, type = kind, position = { x = x, y = y }, unit_number = next_unit,
    force = force, surface = surface, prototype = mock.entity_prototype({}) }
  for key, value in pairs(extra or {}) do values[key] = value end
  local entity = mock.entity(values)
  mock.state(entity).status = RAW[status]
  mock.read(entity, "status", function() reads = reads + 1; return mock.state(entity).status end)
  registry.add(entity)
  return entity
end
local function run(ticks)
  for _ = 1, ticks do game.tick = game.tick + 1; autonomy.on_tick(game.tick) end
end
local function line_at(x)
  for _, line in ipairs(autonomy.lines()) do if line.position.x == x then return line end end
end

-- Fluid boxes: a uranium drill's acid input; a boiler's water input and
-- steam output. Each read of a filter is counted.
local filter_reads = 0
local function fluidbox(boxes)
  local box = mock.fluidbox({
    get_filter = function(index) filter_reads = filter_reads + 1; return boxes[index].filter end,
    get_prototype = function(index) return { production_type = boxes[index].production } end,
  })
  mock.length(box, function() return #boxes end)
  return box
end
machine("mining-drill", "electric-mining-drill", 0, 0, "missing_required_fluid", { mining_target = { prototype =
  { mineable_properties = { products = { { name = "uranium-ore", amount = 1 } } } } },
  fluidbox = fluidbox({ { filter = { name = "sulfuric-acid", minimum_temperature = 15, maximum_temperature = 100 }, production = "input" } }) })
machine("boiler", "boiler", 20, 0, "no_input_fluid", { fluidbox = fluidbox({
  { filter = { name = "steam" }, production = "output" }, { filter = { name = "water" }, production = "input" } }),
  prototype = mock.entity_prototype({}) })
machine("assembling-machine", "assembling-machine-1", 40, 0, "pipeline_overextended", { get_recipe = function() return GEAR end,
  fluidbox = fluidbox({}) })
machine("assembling-machine", "assembling-machine-2", 60, 0, "no_recipe", { get_recipe = function() return nil end })
machine("assembling-machine", "assembling-machine-3", 80, 0, "recipe_not_researched", { get_recipe = function() return nil end })
machine("furnace", "stone-furnace", 100, 0, "full_burnt_result_output", { get_recipe = function() return PLATE end,
  products_finished = 0 })
machine("lab", "lab", 120, 0, "disabled_by_script")
machine("lab", "lab", 140, 0, "disabled_by_control_behavior")
-- Nuclear: a reactor and a heat exchanger (a boiler with a heat source).
machine("reactor", "nuclear-reactor", 160, 0, "low_temperature", { temperature = 410 })
machine("boiler", "heat-exchanger", 163, 0, "low_temperature", { temperature = 380,
  prototype = mock.entity_prototype({ heat_energy_source_prototype = {} }) })
machine("boiler", "boiler", 166, 0, "no_fuel", { fluidbox = fluidbox({}) })
-- Problems only: a beacon without modules, a roboport.
machine("beacon", "beacon", 200, 0, "no_modules_to_transmit")
machine("roboport", "roboport", 220, 0, "working")

game.tick = 1
autonomy.on_tick(game.tick)
run(700)
local function line(x) return line_at(x) or {} end
check(line(0).state == "starved" and line(0).cause == "sulfuric-acid",
  "a drill missing its required fluid is starved of the fluid its filter names")
check(line(20).state == "starved" and line(20).cause == "water",
  "a boiler with no input fluid is starved of its input box's fluid, not its steam output")
check(line(40).state == "starved" and line(40).cause == "fluid", "an overextended pipeline with no filter is starved of fluid")
check(line(60).state == "idle" and line(60).cause == "no_recipe" and line(80).state == "idle"
  and line(80).cause == "recipe_not_researched", "an assembler without a usable recipe is idle and says why")
check(line(100).state == "output_full" and line(100).cause == "burnt_result",
  "a full spent-fuel slot is output_full with cause burnt_result")
check(line(120).state == "disabled" and line(140).state == "disabled", "script- and circuit-disabled machines are disabled")
local nuclear = line_at(163) or line_at(162) or line_at(161)
for _, candidate in ipairs(autonomy.lines()) do if candidate.position.x >= 160 and candidate.position.x <= 166 then nuclear = candidate end end
check(nuclear and nuclear.state == "no_heat" and nuclear.temperature == 380 and nuclear.machines == 3,
  "a reactor, exchanger and boiler are one power line: no_heat outranks no_fuel, with the lowest temperature")
local beacon_line, roboport_line = line_at(200), line_at(220)
local problem
for _, row in ipairs(autonomy.problems()) do if row.status == "no_modules_to_transmit" then problem = row end end
check(beacon_line == nil and roboport_line == nil and problem and problem.cause == "module" and problem.line == nil
  and problem.name == "beacon", "beacons and roboports form no line; a beacon without modules is a problem with cause module")
local overextended
for _, row in ipairs(autonomy.problems()) do if row.status == "pipeline_overextended" then overextended = row end end
check(overextended and storage.autonomy.problem_count >= 4,
  "pipeline_overextended, low_temperature and no_modules_to_transmit become problems after ten seconds")

-- Causes are worked out when a cause changes and every 600 ticks while it
-- lasts; a read makes no engine call.
local filters_before, reads_before = filter_reads, reads
run(600)
local per_tick_filters = (filter_reads - filters_before) / 600
reads = 0
local rows = autonomy.lines()
check(per_tick_filters <= 0.02 and reads == 0 and #rows >= 9,
  "fluid causes cost about " .. per_tick_filters .. " filter reads a tick, and reading lines reads no entity")
local machines = 0
for _ in pairs(storage.autonomy.machines) do machines = machines + 1 end
check((reads_before > 0) and machines == 13, "every sampled machine, problem-only ones included, is in the sampler")

-- ---------------------------------------------------------------- power
-- A solar network: 20 panels (60 kW each) and 10 accumulators, on network
-- 3 with a pole; consumers drawing 1.2 MW nominal.
local function powered(kind, name, x, y, values)
  next_unit = next_unit + 1
  local all = { valid = true, name = name, type = kind, position = { x = x, y = y }, unit_number = next_unit,
    force = force, surface = surface, electric_network_id = 3 }
  for key, value in pairs(values or {}) do all[key] = value end
  local entity = mock.entity(all)
  registry.add(entity)
  return entity
end
local flow_reads = 0
local production = { ["solar-panel"] = 600000 / 60, accumulator = 0 }
local statistics = mock.flow_statistics({ output_counts = { ["solar-panel"] = 1, accumulator = 1 },
  get_flow_count = function(query)
    flow_reads = flow_reads + 1
    return production[query.name]
  end })
local pole = powered("electric-pole", "medium-electric-pole", 300, 0, { electric_network_statistics = statistics,
  prototype = mock.entity_prototype({}) })
for i = 1, 20 do
  powered("solar-panel", "solar-panel", 300 + i, 3, { prototype = electric_prototype({
    get_max_energy_production = function() return 1000 end }) })
end
for i = 1, 10 do
  powered("accumulator", "accumulator", 300 + i, 6, { energy = 2500000, electric_buffer_size = 5000000,
    prototype = electric_prototype() })
end
for i = 1, 20 do powered("assembling-machine", "assembling-machine-2", 300 + i * 4, 12, { status = RAW.working,
  prototype = electric_prototype({ get_max_energy_usage = function() return 1000 end }) }) end
local net = storage.registry.networks[3]
check(net and net.pole == pole and net.sources.solar.count == 20 and net.sources.solar.nameplate_w == 1200000
  and net.accumulators.count == 10 and net.accumulators.capacity_j == 50000000 and net.demand_w == 1200000,
  "built panels, accumulators and consumers join their network's aggregates at once")

local function row_for(id)
  local rows = map_summary.build_power(surface, 8)
  for _, candidate in ipairs(rows) do if candidate.network_id == id then return candidate end end
end
surface_values.daytime = 0
local noon = row_for(3)
check(noon.capacity_w == 1200000 and noon.sustained_w == 840000 and noon.headroom_w == -360000
  and noon.night_s == 125 and noon.production_w == 600000 and noon.sources[1].kind == "solar"
  and noon.accumulators.charge == 0.5 and noon.accumulators.stored_j == 25000000,
  "at noon solar capacity is the nameplate; the day average is 70 % on Nauvis defaults")
check(noon.add_to_cover.solar_panel == 9 and noon.add_to_cover.steam_engine == nil,
  "a short solar network asks for the panels that cover its day average")
-- The night: 29 panels give 1.74 MW peak; integrate the 1.2 MW demand they
-- cannot carry over 100 light samples of a 25,000-tick day.
local expected_j = 0
for i = 1, 100 do
  local t, light = (i - 0.5) / 100, 1
  if t > 0.25 and t < 0.45 then light = 1 - (t - 0.25) / 0.2 elseif t >= 0.45 and t <= 0.55 then light = 0
  elseif t > 0.55 and t < 0.75 then light = (t - 0.55) / 0.2 end
  expected_j = expected_j + math.max(0, 1200000 - 1740000 * light) * (25000 / 60 / 100)
end
check(noon.add_to_cover.accumulator == math.ceil(expected_j / 5000000) - 10,
  "accumulators carry the night deficit of the covering panels (" .. noon.add_to_cover.accumulator .. " more)")
surface_values.daytime = 0.5
local midnight = row_for(3)
check(midnight.capacity_w == 0 and midnight.sustained_w == 840000, "at midnight solar capacity is zero, its average unchanged")
surface_values.daytime, surface_values.power = 0.35, 400
local vulcanus = row_for(3)
check(vulcanus.capacity_w == 2400000 and vulcanus.sustained_w == 3360000 and vulcanus.add_to_cover == nil,
  "a solar-power property of 400 multiplies solar fourfold (half light at 0.35)")
surface_values.power, surface_values.always_day = nil, true
local bright = row_for(3)
check(bright.capacity_w == 1200000 and bright.sustained_w == 1200000 and bright.night_s == 0, "always_day is full light")
surface_values.always_day = false

-- A steam network short of demand asks for steam engines.
next_unit = next_unit + 1
local steam_pole = mock.entity({ valid = true, name = "small-electric-pole", type = "electric-pole", position = { x = 400, y = 0 },
  unit_number = next_unit, force = force, surface = surface, electric_network_id = 4, prototype = mock.entity_prototype({}),
  electric_network_statistics = mock.flow_statistics({ output_counts = { ["steam-engine"] = 1 },
    get_flow_count = function() flow_reads = flow_reads + 1; return 15000 end }) })
registry.add(steam_pole)
next_unit = next_unit + 1
registry.add(mock.entity({ valid = true, name = "steam-engine", type = "generator", position = { x = 402, y = 0 },
  unit_number = next_unit, force = force, surface = surface, electric_network_id = 4,
  prototype = electric_prototype({ get_max_energy_production = function() return 15000 end, maximum_temperature = 165 }) }))
for i = 1, 30 do
  next_unit = next_unit + 1
  registry.add(mock.entity({ valid = true, name = "electric-furnace", type = "furnace", position = { x = 410 + i * 3, y = 0 },
    unit_number = next_unit, force = force, surface = surface, electric_network_id = 4, status = RAW.low_power,
    prototype = electric_prototype({ get_max_energy_usage = function() return 3000 end }) }))
end
flow_reads, surface_reads = 0, 0
local rows_all, omitted = map_summary.build_power(surface, 1)
local steam = rows_all[1]
check(#rows_all == 1 and omitted == 1 and steam.network_id == 4 and steam.demand_w == 5400000
  and steam.satisfaction == 0.167 and steam.add_to_cover.steam_engine == 5 and steam.add_to_cover.solar_panel == nil
  and steam.sources[1].kind == "steam" and steam.sources[1].production_w == 900000,
  "a starved steam network asks for steam engines; the limit keeps the largest network")
check(flow_reads == 1 and surface_reads <= 8,
  "rows read one statistics row per output name of each kept network and a few surface attributes ("
    .. flow_reads .. " flow, " .. surface_reads .. " surface reads)")

-- A turbine (steam above 165 degrees) is nuclear.
check(registry.power_kind("steam-engine") == "steam", "a steam engine is steam power")
prototypes.entity["steam-turbine"] = { type = "generator", maximum_temperature = 500 }
check(registry.power_kind("steam-turbine") == "nuclear", "a 500-degree turbine is nuclear power")

-- A platform surface: capacity is measured solar, no day average.
surface_values.platform = {}
local platform = row_for(3)
check(platform.capacity_w == 600000 and platform.sustained_w == nil and platform.add_to_cover == nil
  and platform.night_s == nil, "on a platform solar capacity is what it produces and there is no day average")
surface_values.platform = nil

-- ----------------------------------------------------------- logistics
local logistics = require("scripts.logistics")
local cell_reads = 0
local function cell(x, y)
  return setmetatable({ owner = { position = { x = x, y = y } }, logistic_radius = 25, construction_radius = 55,
    to_charge_robot_count = 1 }, { __index = function() cell_reads = cell_reads + 1 end })
end
local cells = {}
for i = 1, 100 do cells[i] = cell(i * 10, 0) end
local contents = {}
for i = 1, 30 do contents[i] = { name = string.format("item-%02d", i), quality = "normal", count = i * 10 } end
local function network(id, x)
  return mock.logistic_network({ network_id = id, cells = cells, all_logistic_robots = 50, available_logistic_robots = 20,
    all_construction_robots = 10, available_construction_robots = 9, get_contents = function() return contents end,
    find_cell_closest_to = function() return cell(x, 0) end })
end
force.logistic_networks = { nauvis = { network(1, 500), network(2, 5), network(3, 50), network(4, 900) } }
local section = logistics.section(body)
local first = section.networks[1]
check(#section.networks == 3 and section.omitted_networks == 1 and first.network_id == 2 and section.networks[2].network_id == 3
  and first.cells == 100 and first.cells_read == 64 and first.charging_queue == 64 and #first.coverage == 12
  and first.coverage[1].position.x == 10 and #first.contents == 8 and first.contents[1].item == "item-30"
  and first.robots.logistic.available == 20 and first.robots.construction.all == 10,
  "logistics lists the three networks nearest the body with robots, capped coverage and contents")
local function size(value)
  if type(value) ~= "table" then return #tostring(value) + 2 end
  local n, count = 2, 0
  for _ in pairs(value) do count = count + 1 end
  for key, item in pairs(value) do n = n + (count == #value and 1 or #tostring(key) + 4) + size(item) end
  return n
end
check(size(section) < 3 * 1600, "with every cap full the logistics section stays under 4.8 KB (" .. size(section) .. ")")
cells = { cell(10, 0), cell(60, 0), cell(110, 0) }
contents = { { name = "iron-plate", quality = "normal", count = 400 }, { name = "copper-plate", quality = "normal", count = 200 },
  { name = "iron-plate", quality = "rare", count = 5 } }
force.logistic_networks = { nauvis = { network(1, 10) } }
local small = logistics.section(body)
check(size(small) < 900 and small.networks[1].contents[1].count == 405 and small.networks[1].cells_read == nil,
  "a first robot network (three roboports) reads under 900 bytes (" .. size(small) .. ")")

-- An upgraded 0.21.1 save keeps its lines and gains the 0.22 sampler sets.
storage.autonomy.problem_only, storage.autonomy.waiting, storage.autonomy.dirty_tick = nil, nil, nil
local lines_before = #autonomy.lines()
state.init()
check(storage.autonomy.problem_only and storage.autonomy.waiting and #autonomy.lines() == lines_before
  and storage.autonomy.dirty_tick == game.tick, "state.init adds the 0.22 sampler sets to an existing line store")
run(301)
check(#storage.autonomy.problem_only == 2 and storage.autonomy.waiting.no_fuel ~= nil,
  "the refresh it schedules fills them: beacons and roboports, and machines waiting for upkeep")

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
