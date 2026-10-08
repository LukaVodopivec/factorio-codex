-- Line capacity and power runway (autonomy.lua): max_per_min and utilisation
-- from crafting speed, productivity and recipe energy (or a drill's nominal
-- mining capacity), share_10m from the per-minute state bins, fuel_s from
-- the burner reads the sampler makes, and supply_states naming the
-- generating lines of a network short of power. Machines are strict
-- LuaEntity mocks advanced by a small tick simulation.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local function near(a, b, tolerance) return type(a) == "number" and math.abs(a - b) <= (tolerance or 1e-6) end

local RAW = { working = 1, no_fuel = 2, no_ingredients = 3, no_power = 4, low_power = 5, normal = 6 }
_G.defines = { entity_status = RAW, inventory = { crafter_input = 2, lab_input = 3 },
  rocket_silo_status = { building_rocket = 1, rocket_ready = 10 }, direction = { north = 0, east = 4, south = 8, west = 12 } }
local GEAR = { name = "iron-gear-wheel", energy = 0.5, maximum_productivity = 0.25, ingredients = { { name = "iron-plate", type = "item", amount = 2 } },
  products = { { name = "iron-gear-wheel", type = "item", amount = 1 } } }
local PLATE = { name = "iron-plate", energy = 3.2, ingredients = { { name = "iron-ore", type = "item", amount = 1 } },
  products = { { name = "iron-plate", type = "item", amount = 1 } } }
_G.prototypes = { recipe = { ["iron-gear-wheel"] = GEAR, ["iron-plate"] = PLATE },
  item = { coal = { fuel_value = 4000000 }, wood = { fuel_value = 2000000 } } }
_G.game = { tick = 0 }
_G.storage = {}
_G.script = { register_on_object_destroyed = function() return 1 end }

-- The force's research bonus for gears (2.0.77 keeps it off the entity).
local force = { name = "player", is_chunk_charted = function() return true end,
  recipes = { ["iron-gear-wheel"] = { productivity_bonus = 0.2 } } }
local surface = { index = 1, find_entities_filtered = function() return {} end }
local body = { valid = true, position = { x = 0, y = 0 }, force = force, surface = surface }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end,
  human_control = function() return false, 999 end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)

local state = require("scripts.state")
local registry = require("scripts.registry")
local autonomy = require("scripts.autonomy")
state.init()
storage.registry.ready = true

local next_unit = 100
local function machine(kind, name, x, y, extra)
  next_unit = next_unit + 1
  local values = { valid = true, name = name, type = kind, position = { x = x, y = y }, unit_number = next_unit,
    force = force, surface = surface, status = RAW.working }
  for key, value in pairs(extra or {}) do values[key] = value end
  local entity = mock.entity(values)
  for _, key in ipairs({ "status", "products_finished", "mining_progress", "bonus_mining_progress" }) do
    mock.state(entity)[key] = values[key]
    mock.read(entity, key, function() return mock.state(entity)[key] end)
  end
  registry.add(entity)
  return entity
end
local function run(ticks, step)
  for _ = 1, ticks do
    game.tick = game.tick + 1
    if step then step(game.tick) end
    autonomy.on_tick(game.tick)
  end
end
local function line_of(product)
  for _, row in ipairs(autonomy.lines()) do if row.product == product then return row end end
end

-- ------------------------------------------------------------ capacity
-- Two assemblers (speed 0.75, +10 % productivity from modules, +20 % from
-- research, capped at the recipe's +25 %) on a 0.5 s gear recipe:
-- 0.75 / 0.5 x 1.25 x 60 = 112.5 gears a minute each.
local assemblers = {}
for i = 1, 2 do
  assemblers[i] = machine("assembling-machine", "assembling-machine-2", i * 4, 0, { products_finished = 0,
    crafting_speed = 0.75, productivity_bonus = 0.1, get_recipe = function() return GEAR end })
end
-- A stone furnace (speed 2) smelting plates: 2 / 3.2 x 60 = 37.5 a minute.
local furnace = machine("furnace", "stone-furnace", 40, 0, { products_finished = 0, crafting_speed = 2,
  get_recipe = function() return PLATE end })
-- An electric drill (mining speed 0.5) on ore taking 1 s, with +20 %
-- mining productivity: 0.5 / 1 x 60 x 1.2 = 36 ore a minute.
local ore = mock.entity({ valid = true, name = "iron-ore", type = "resource", position = { x = 80, y = 0 },
  prototype = { mineable_properties = { mining_time = 1,
    products = { { name = "iron-ore", type = "item", amount = 1 } } } } })
local drill = machine("mining-drill", "electric-mining-drill", 80, 0, { mining_progress = 0, bonus_mining_progress = 0,
  mining_target = ore, productivity_bonus = 0.2, speed_bonus = 0, prototype = { mining_speed = 0.5 } })
-- A drill whose recipe-less neighbour cannot be read leaves its line
-- without a max: a furnace that never smelted has no product at all.
game.tick = 1
autonomy.refresh()
local gears, plates, mined = line_of("iron-gear-wheel"), line_of("iron-plate"), line_of("iron-ore")
check(gears and gears.machines == 2 and near(gears.max_per_min, 225),
  "two assemblers' max_per_min sums crafting speed x (1 + module and research productivity, capped) / recipe energy x 60 (" .. tostring(gears and gears.max_per_min) .. ")")
check(plates and near(plates.max_per_min, 37.5), "a furnace's max_per_min is its crafting speed / recipe energy x 60")
check(mined and near(mined.max_per_min, 36), "a drill's max_per_min is its nominal mining capacity x (1 + productivity)")
check(near(autonomy.nominal_mining_capacity(drill, force, surface), 30),
  "the nominal mining capacity (map_summary's groups use it too) ignores bonuses")

-- Producing at full duty: gears every 0.5 / 0.75 / 1.25 s, a plate every
-- 1.6 s, ore every 2 s and a bonus ore every 10 s (20 % productivity).
local gear_progress = { 0, 0 }
local function produce(tick)
  for i, a in ipairs(assemblers) do
    gear_progress[i] = gear_progress[i] + 0.75 * 1.25 / 0.5 / 60
    if gear_progress[i] >= 1 then
      gear_progress[i] = gear_progress[i] - 1
      mock.state(a).products_finished = mock.state(a).products_finished + 1
    end
  end
  if tick % 96 == 0 then mock.state(furnace).products_finished = mock.state(furnace).products_finished + 1 end
  mock.state(drill).mining_progress = (tick % 120) / 120
  mock.state(drill).bonus_mining_progress = (tick % 600) / 600
end
run(4000, produce)
gears, plates, mined = line_of("iron-gear-wheel"), line_of("iron-plate"), line_of("iron-ore")
check(gears.utilisation >= 0.97 and gears.utilisation <= 1.03 and plates.utilisation >= 0.97 and plates.utilisation <= 1.03,
  "lines at full duty have utilisation about 1 (gears " .. gears.utilisation .. ", plates " .. plates.utilisation .. ")")
check(mined.rate_per_min >= 34 and mined.rate_per_min <= 38 and mined.utilisation >= 0.94 and mined.utilisation <= 1.06,
  "a drill's productivity bonus products count in its rate, so it meets its max (" .. mined.rate_per_min .. " a minute)")
check(gears.share_10m == nil and plates.share_10m == nil and mined.share_10m == nil,
  "a line running all the time has no share_10m")

-- ------------------------------------------------------------ share_10m
-- Ten minutes at full duty, then the furnace starves for five: about half
-- of the last ten minutes' evaluates are starved.
run(10 * 3600, produce)
mock.state(furnace).status = RAW.no_ingredients
run(5 * 3600 + 600)
plates = line_of("iron-plate")
local share = plates.share_10m
check(plates.state == "starved" and share and share.starved >= 0.45 and share.starved <= 0.6
  and near(share.running + share.starved, 1, 0.011),
  "a line starved for five of its last ten minutes shares about half each (" .. tostring(share and share.starved) .. ")")
check(plates.utilisation == 0, "a starved line's utilisation falls to 0")
run(11 * 3600)
plates = line_of("iron-plate")
check(plates.share_10m and plates.share_10m.starved == 1 and plates.share_10m.running == nil,
  "after ten more minutes only the starved bins are left")
local bins = 0
for _ in pairs(storage.autonomy.lines[plates.id].share_bins) do bins = bins + 1 end
check(bins == 10, "a line keeps ten minute bins of state counts")

-- ------------------------------------------------------------ fuel_s
-- Two stone furnaces burning coal at 90 kW (1500 J a tick): one with five
-- coal left, one with one coal; the lowest member's runway is the line's.
local function burner_furnace(x, coal)
  local fuel = { coal = coal, remaining = 2000000 }
  local f = machine("furnace", "stone-furnace", x, 200, { products_finished = 0, crafting_speed = 2,
    get_recipe = function() return PLATE end,
    burner = { inventory = mock.inventory({ get_contents = function()
      return fuel.coal > 0 and { { name = "coal", count = fuel.coal, quality = "normal" } } or {} end }) } })
  mock.read(f.burner, "remaining_burning_fuel", function() return fuel.remaining end)
  return f, fuel
end
local full_furnace, full_fuel = burner_furnace(300, 5)
local low_furnace, low_fuel = burner_furnace(302, 1)
autonomy.refresh()
local function burn(tick)
  for _, fuel in ipairs({ full_fuel, low_fuel }) do
    fuel.remaining = fuel.remaining - 1500
    if fuel.remaining <= 0 and fuel.coal > 0 then fuel.coal, fuel.remaining = fuel.coal - 1, fuel.remaining + 4000000 end
    fuel.remaining = math.max(0, fuel.remaining)
  end
  if tick % 96 == 0 then
    for _, f in ipairs({ full_furnace, low_furnace }) do mock.state(f).products_finished = mock.state(f).products_finished + 1 end
  end
end
run(120, burn)
local burning
for _, row in ipairs(autonomy.lines()) do if row.position.y == 200 then burning = row end end
-- The low furnace holds one coal (4 MJ) plus about 1.82 MJ burning: about
-- 5.82 MJ / 1500 J a tick / 60 = 64 s.
check(burning and burning.machines == 2 and burning.fuel_s and burning.fuel_s >= 63 and burning.fuel_s <= 65,
  "fuel_s is the lowest member's fuel energy over its measured burn rate (" .. tostring(burning and burning.fuel_s) .. " s)")
-- A refuel between two samples keeps the rate measured before it.
local rate = storage.autonomy.machines[low_furnace.unit_number].burn
low_fuel.coal = low_fuel.coal + 10
run(30, burn)
check(near(storage.autonomy.machines[low_furnace.unit_number].burn, rate) and near(rate, 1500),
  "a sample after a refuel keeps the last burn rate (" .. rate .. " J a tick)")
run(30, burn)
for _, row in ipairs(autonomy.lines()) do if row.position.y == 200 then burning = row end end
check(burning.fuel_s >= 235 and burning.fuel_s <= 245,
  "refuelled, the low member has the longer runway and the line's is the other member's (" .. burning.fuel_s .. " s)")
-- Out of fuel: 0 s, whatever the rate was.
full_fuel.coal, full_fuel.remaining = 0, 0
mock.state(full_furnace).status = RAW.no_fuel
run(60)
for _, row in ipairs(autonomy.lines()) do if row.position.y == 200 then burning = row end end
check(burning.fuel_s == 0, "a member out of fuel makes the line's fuel_s 0")
check(line_of("iron-gear-wheel").fuel_s == nil, "a line without a burner has no fuel_s")

-- ------------------------------------------------------------ supply_states
-- A steam line (a dry boiler beside an engine on network 5) and an
-- assembler on network 5 short of power: the assembler's row names its
-- network and the boiler line, no_fuel at the boiler.
local boiler = machine("boiler", "boiler", 500, 0, { status = RAW.no_fuel,
  burner = { inventory = mock.inventory({ get_contents = function() return {} end }) } })
mock.read(boiler.burner, "remaining_burning_fuel", function() return 0 end)
local engine = machine("generator", "steam-engine", 500, 4, { status = RAW.normal })
local unpowered = machine("assembling-machine", "assembling-machine-1", 520, 0, { status = RAW.no_power,
  products_finished = 0, crafting_speed = 0.5, get_recipe = function() return GEAR end })
-- The registry's maintenance pass keeps each entry's network (set here).
storage.registry.entries[engine.unit_number].network = 5
storage.registry.entries[unpowered.unit_number].network = 5
autonomy.refresh()
run(700)
local power, short
for _, row in ipairs(autonomy.lines()) do
  if row.product == "electricity" then power = row end
  if row.position.x == 520 then short = row end
end
check(power and power.state == "no_fuel" and power.fuel_s == 0, "the steam line is no_fuel with no fuel left")
local supply = short and short.supply_states
check(short and short.state == "no_power" and short.network_id == 5 and supply and #supply == 1
  and supply[1].line == power.id and supply[1].state == "no_fuel" and supply[1].position.x == 500
  and supply[1].position.y == 0 and supply[1].fuel_s == 0,
  "a no_power line names its network and the boiler line no_fuel at the boiler")
local rows = autonomy.supply_states(1, 5)
check(rows and #rows == 1 and autonomy.supply_states(1, 6) == nil and autonomy.supply_states(2, 5) == nil,
  "supply_states lists only the generating lines on that network and surface")
-- The boiler refuelled: the line runs and the list says so.
mock.state(boiler).status = RAW.working
mock.state(engine).status = RAW.working
mock.state(unpowered).status = RAW.low_power
run(60)
for _, row in ipairs(autonomy.lines()) do if row.position.x == 520 then short = row end end
check(short.state == "no_power" and short.supply_states[1].state == "running",
  "in a brownout (low_power) the list shows the generating line running")
-- More generating lines than MAX_SUPPLY: those needing attention first.
for i = 1, 4 do
  local e = machine("generator", "steam-engine", 600 + i * 20, 0, { status = i == 4 and RAW.no_fuel or RAW.working })
  storage.registry.entries[e.unit_number].network = 5
end
autonomy.refresh()
run(700)
local capped, omitted = autonomy.supply_states(1, 5)
check(#capped == 3 and omitted == 2 and capped[1].state ~= "running",
  "at most three supply rows, a stalled line first, and how many were left out")

-- factory_status shows a network's supply_states once: on its power row,
-- and the line row keeps only network_id.
package.loaded["scripts.map_summary"] = { build_power = function()
  return { { network_id = 5, satisfaction = 0.4, supply_states = autonomy.supply_states(1, 5) } }, 0
end, patches = function() return {}, true end }
mock.state(unpowered).status = RAW.no_power
run(60)
local factory_status = require("scripts.factory_status")
local status = factory_status.factory_status({ sections = { "lines", "power" } })
local row
for _, line in ipairs(status.lines) do if line.position.x == 520 then row = line end end
check(status.power[1].supply_states and row and row.network_id == 5 and row.supply_states == nil,
  "factory_status lists a network's supply states once, on its power row")
status = factory_status.factory_status({ sections = { "lines" } })
for _, line in ipairs(status.lines) do if line.position.x == 520 then row = line end end
check(row.supply_states and row.supply_states[1], "without the power section the line row carries them")

check(#mock.violations == 0, "no read outside the Factorio 2.0.77 API")
if failures > 0 then print(failures .. " FAILURES"); os.exit(1) end
print("ALL LINE CAPACITY TESTS PASSED")
