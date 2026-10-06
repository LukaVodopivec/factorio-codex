-- What a line row says about its members (autonomy.lua): burner inserters
-- sampled for problems only (a dry one joins the upkeep sets, is a problem
-- row and is the cause of the full machine it takes from), a running line's
-- degraded member (a dry boiler beside working engines), and a depleted
-- drill. Entities are strict 2.0.77 mocks, built through the registry.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local RAW = { working = 1, no_fuel = 2, full_output = 3, waiting_for_space_in_destination = 4,
  no_minable_resources = 5, waiting_for_source_items = 6 }
_G.defines = { entity_status = RAW, inventory = { crafter_input = 2, lab_input = 3 } }
local PLATE = { name = "iron-plate", ingredients = { { name = "iron-ore", type = "item", amount = 1 } },
  products = { { name = "iron-plate", type = "item", amount = 1 } } }
_G.prototypes = { recipe = { ["iron-plate"] = PLATE }, item = { coal = { stack_size = 50 } },
  get_item_filtered = function(filters)
    assert(filters[1].filter == "fuel-category" and filters[1]["fuel-category"] == "chemical")
    return { coal = {} }
  end }
_G.game = { tick = 0 }
_G.storage = {}
_G.script = { register_on_object_destroyed = function() return 1 end }

local force = mock.force({ name = "player", is_chunk_charted = function() return true end })
local surface = mock.surface({ index = 1, name = "nauvis" })
local carried = { coal = 20 }
local body = { valid = true, position = { x = 0, y = 0 }, force = force, surface = surface, surface_index = 1,
  get_item_count = function(name) return carried[name] or 0 end }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end,
  human_control = function() return false, 999 end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
local queued = {}
package.loaded["scripts.tasks"] = { upkeep_room = function() return "idle" end,
  queue_plan = function(params) queued[#queued + 1] = params; return { plan_id = #queued } end }

local state = require("scripts.state")
local registry = require("scripts.registry")
local autonomy = require("scripts.autonomy")
local chores = require("scripts.chores")
state.init()
storage.registry.ready, storage.registry.force = true, "player"
storage.tasks.last_finished_tick = 1

local next_unit = 100
local function machine(kind, name, x, y, status, extra)
  next_unit = next_unit + 1
  local values = { valid = true, name = name, type = kind, position = { x = x, y = y }, unit_number = next_unit,
    force = force, surface = surface, prototype = mock.entity_prototype({}) }
  for key, value in pairs(extra or {}) do values[key] = value end
  local entity = mock.entity(values)
  mock.state(entity).status = RAW[status]
  mock.read(entity, "status", function() return mock.state(entity).status end)
  registry.add(entity)
  return entity
end
local function run(ticks)
  for _ = 1, ticks do game.tick = game.tick + 1; autonomy.on_tick(game.tick) end
end
local function line_of(x, y)
  for _, line in ipairs(autonomy.lines()) do
    if line.position.x == x and line.position.y == y then return line end
  end
end
local function problem(name, status)
  for _, row in ipairs(autonomy.problems()) do if row.name == name and row.status == status then return row end end
end
local function burner(fuel)
  return { fuel_categories = { chemical = true },
    inventory = mock.inventory({ get_item_count = function() return fuel() end }) }
end

-- -------------------------------------------------------- burner inserters
-- A furnace whose only outlet is a burner inserter that ran dry; another
-- burner inserter waiting for room in its target; an electric inserter.
local furnace = machine("furnace", "stone-furnace", 10, 0, "full_output", { products_finished = 0,
  get_recipe = function() return PLATE end })
local outlet_fuel = 0
local outlet = machine("inserter", "burner-inserter", 10.5, 1.5, "no_fuel", { burner = burner(function() return outlet_fuel end) })
local pickup_reads = 0
mock.read(outlet, "pickup_target", function() pickup_reads = pickup_reads + 1; return furnace end)
local waiting = machine("inserter", "burner-inserter", 30.5, 0.5, "waiting_for_space_in_destination",
  { burner = burner(function() return 5 end) })
local electric = machine("inserter", "inserter", 40.5, 0.5, "no_fuel",
  { prototype = mock.entity_prototype({ electric_energy_source_prototype = {} }) })
local machines = storage.registry.machines.inserter or {}
check(machines[outlet.unit_number] and machines[waiting.unit_number] and not machines[electric.unit_number]
  and storage.registry.entries[electric.unit_number] ~= nil,
  "burner inserters are registered machines; an electric inserter is kept, but as no machine")
storage.autonomy.dirty_tick = nil
autonomy.on_entity_changed({ entity = electric })
local electric_dirty = storage.autonomy.dirty_tick
autonomy.on_entity_changed({ entity = outlet })
check(electric_dirty == nil and storage.autonomy.dirty_tick ~= nil,
  "building a burner inserter regroups the lines; building an electric one does not")

autonomy.refresh()
run(700)
local fuel_set = storage.autonomy.waiting.no_fuel and storage.autonomy.waiting.no_fuel[1]
check(fuel_set and fuel_set[outlet.unit_number] == true, "a dry burner inserter joins the upkeep no_fuel set")
local dry = problem("burner-inserter", "no_fuel")
check(dry and dry.line == nil and dry.position.x == 10.5 and dry.position.y == 1.5,
  "a dry burner inserter is a no_fuel problem row with its position and no line")
check(problem("burner-inserter", "waiting_for_space_in_destination") == nil,
  "a burner inserter waiting for room in its target is no problem")
local inserter_line = false
for _, line in ipairs(autonomy.lines()) do if line.entity == "burner-inserter" or line.entity == "inserter" then inserter_line = true end end
check(not inserter_line, "inserters form no line")
local full = line_of(10, 0)
check(full and full.state == "output_full" and full.cause == "outlet_no_fuel" and full.cause_position
  and full.cause_position.x == 10.5 and full.cause_position.y == 1.5,
  "a full furnace whose outlet inserter ran dry names that inserter as its cause")
check(pickup_reads == 1, "the dry inserter's pickup target is read once per dry episode (" .. pickup_reads .. " reads)")

chores.upkeep(game.tick)
local step = queued[1] and queued[1].steps[1]
check(step and step.action == "insert_items" and step.x == 10.5 and step.y == 1.5 and step.items.coal == 10
  and #queued[1].steps == 1, "upkeep refuels the dry burner inserter")

-- Refuelled, the inserter leaves the set and the furnace runs again.
outlet_fuel = 10
mock.state(outlet).status = RAW.waiting_for_source_items
mock.state(furnace).status = RAW.working
run(60)
check(not storage.autonomy.waiting.no_fuel[1][outlet.unit_number], "a refuelled inserter leaves the no_fuel set")
check(line_of(10, 0).state == "running" and line_of(10, 0).cause == nil, "the furnace line runs again with no cause")

-- ------------------------------------------------------- degraded members
-- A power line: an offshore pump, a boiler and a steam engine, running a
-- minute; then the boiler runs dry while the engine works on its steam.
machine("offshore-pump", "offshore-pump", 0, 50, "working")
local boiler = machine("boiler", "boiler", 3, 50, "working")
machine("generator", "steam-engine", 6, 50, "working")
autonomy.refresh()
run(3700)
local power = line_of(3, 50)
check(power and power.product == "electricity" and power.state == "running" and power.self_sustaining
  and power.degraded == nil, "a power line running a minute is self-sustaining and not degraded")
mock.state(boiler).status = RAW.no_fuel
local since = game.tick
run(120)
power = line_of(3, 50)
check(power.state == "running" and not power.self_sustaining and power.degraded
  and power.degraded.state == "no_fuel" and power.degraded.cause_position.x == 3 and power.degraded.cause_position.y == 50,
  "a dry boiler beside a working pump and engine leaves the line running, degraded no_fuel at the boiler")
local changed = false
for _, line in ipairs(autonomy.lines(since)) do if line.id == power.id then changed = true end end
check(changed, "since_tick returns the line that became degraded")

-- --------------------------------------------------------- depleted drill
-- A drill that mined iron ore runs out: its line is depleted of that ore,
-- even after a refresh finds no mining target.
local target = mock.entity({ valid = true, name = "iron-ore", type = "resource", position = { x = 0, y = 100 },
  prototype = mock.entity_prototype({ mineable_properties = { products = { { name = "iron-ore", type = "item", amount = 1 } } } }) })
local drill = machine("mining-drill", "burner-mining-drill", 0, 100, "working", { mining_progress = 0 })
local mined = target
mock.read(drill, "mining_target", function() return mined end)
autonomy.refresh()
run(60)
mined = nil
mock.state(drill).status = RAW.no_minable_resources
autonomy.refresh()
run(700)
local depleted = line_of(0, 100)
check(depleted and depleted.state == "depleted" and depleted.cause == "iron-ore" and depleted.cause_position.x == 0,
  "a drill out of resources is depleted, naming the ore it mined, not a cause-less starved")
check(problem("burner-mining-drill", "no_minable_resources") ~= nil, "the depleted drill is still a problem row")

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
