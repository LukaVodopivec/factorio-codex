-- Offline tests for blueprints.lua: real blueprint items in a script
-- inventory made by state.init (also on a 0.21.0 save upgraded in place),
-- captured from own entities in a charted area or created from a layout
-- spec, listed, described, exported (never imported), deleted, flipped; each
-- change is an activity_log row, and tool unlocks and robot coverage are read
-- from the game, never assumed. LuaItemStack, LuaInventory,
-- LuaShortcutPrototype and LuaLogisticNetwork members are checked against
-- the 2.0.77 API.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local bp = dofile(here .. "/blueprint_mock.lua")
local mock = bp.mock

local created_inventories = 0
_G.game = { tick = 1000, create_inventory = function(size)
  created_inventories = created_inventories + 1
  return bp.inventory(size)
end }
local function box(w, h) return { left_top = { x = -w / 2, y = -h / 2 }, right_bottom = { x = w / 2, y = h / 2 } } end
local function proto(name, kind, w, h) return { name = name, type = kind, tile_width = w, tile_height = h, collision_box = box(w, h) } end
local entities = {
  ["stone-furnace"] = proto("stone-furnace", "furnace", 2, 2),
  ["assembling-machine-1"] = proto("assembling-machine-1", "assembling-machine", 3, 3),
  inserter = proto("inserter", "inserter", 1, 1),
  splitter = proto("splitter", "splitter", 2, 1),
  ["transport-belt"] = proto("transport-belt", "transport-belt", 1, 1),
}
local items = {}
for name, p in pairs(entities) do items[name] = { name = name, place_result = p } end
items.blueprint = { name = "blueprint" }
items["iron-plate"], items.coal = { name = "iron-plate" }, { name = "coal" }
entities.inserter.filter_count = 5
local construction_robotics = { name = "construction-robotics" }
_G.prototypes = { item = items, entity = entities, shortcut = {
  ["give-blueprint"] = mock.shortcut_prototype({ item_to_spawn = { name = "blueprint" }, technology_to_unlock = construction_robotics }),
  ["give-deconstruction-planner"] = mock.shortcut_prototype({ item_to_spawn = { name = "deconstruction-planner" },
    technology_to_unlock = construction_robotics }),
  ["toggle-alt-mode"] = mock.shortcut_prototype({}),
} }

local own = { name = "player", technologies = { ["construction-robotics"] = { researched = false } },
  recipes = { ["iron-gear-wheel"] = { name = "iron-gear-wheel", enabled = true } } }
local charted = function(_, chunk) return chunk.x >= -2 and chunk.x <= 2 and chunk.y >= -2 and chunk.y <= 2 end
own.is_chunk_charted = charted
local networks = {}
local counts = {}
local surface = { find_logistic_networks_by_construction_area = function(position, force)
  assert(type(position) == "table" and force == own)
  return networks
end }
-- What the capture counts before it builds a blueprint (the body included).
surface.count_entities_filtered = function(filter)
  assert(filter.area and filter.force and filter.limit, "a capture counts own entities in its area, with a limit")
  counts[#counts + 1] = filter
  local n = 0
  for _, e in ipairs(bp.world) do
    if e.force == filter.force and e.position.x > filter.area.left_top.x and e.position.x < filter.area.right_bottom.x
      and e.position.y > filter.area.left_top.y and e.position.y < filter.area.right_bottom.y then n = n + 1 end
  end
  local p = { x = 0, y = 0 }
  if p.x >= filter.area.left_top.x and p.x <= filter.area.right_bottom.x
    and p.y >= filter.area.left_top.y and p.y <= filter.area.right_bottom.y then n = n + 1 end
  return math.min(n, filter.limit)
end
local body = { valid = true, position = { x = 0, y = 0 }, force = own, surface = surface }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)

-- A 0.21.0 save: plans in flight, no blueprint storage yet.
local active = { id = 243, type = "plan", steps = { { action = "walk_to" } }, source = "pilot" }
_G.storage = { tasks = { next_id = 300, records = { [243] = active }, queue = {}, active = active } }
local state = require("scripts.state")
state.init()
check(storage.blueprints and storage.blueprints.inventory and #storage.blueprints.inventory == state.BLUEPRINT_SLOTS
  and next(storage.blueprints.by_name) == nil and created_inventories == 1 and storage.tasks.active == active,
  "an upgraded 0.21.0 save gets the blueprint inventory in state.init and keeps its plans")
state.init()
check(created_inventories == 1, "a later configuration change keeps the inventory")

local blueprints = require("scripts.blueprints")
local jobs = require("scripts.jobs")
local logged = {}
blueprints.set_logger(function(row) logged[#logged + 1] = row end)
local function capture(params) return jobs.run_now(blueprints.capture_job, params) end
local function describe(name) return jobs.run_now(blueprints.describe_job, { name = name }) end

-- The world: an own smelting line and someone else's chest.
local other = { name = "enemy" }
bp.world = {
  { name = "stone-furnace", type = "furnace", position = { x = 1, y = 1 }, direction = 0, force = own },
  { name = "inserter", type = "inserter", position = { x = 2.5, y = 3.5 }, direction = 4, force = own },
  { name = "stone-furnace", type = "furnace", position = { x = 3, y = 1 }, direction = 0, force = own },
  { name = "transport-belt", type = "transport-belt", position = { x = 50.5, y = 0.5 }, direction = 0, force = own },
  { name = "inserter", type = "inserter", position = { x = 4.5, y = 3.5 }, direction = 0, force = other },
}
local smelter = capture({ name = "smelter", center = { x = 2, y = 2 }, radius = 4 })
local args = bp.created[1]
check(smelter.name == "smelter" and smelter.entities == 3 and smelter.size.w == 4 and smelter.size.h == 4,
  "capture reads the own entities in the area: 3 entities, 4 x 4 tiles")
check(args.force == own and args.surface == surface and args.include_entities and args.include_modules
  and not args.include_trains and not args.include_station_names and args.area.left_top.x == -2,
  "capture asks create_blueprint for own entities and modules, no trains, over the requested area")
local cost = {}
for _, row in ipairs(smelter.cost) do cost[row.item] = row.count end
check(cost["stone-furnace"] == 2 and cost.inserter == 1, "capture reports the cost to build")
check(smelter.tool_unlock.technology == "construction-robotics" and smelter.tool_unlock.researched == false,
  "the blueprint tool's unlock is read from its shortcut and the force, never assumed")
check(smelter.tool_unlock.usable == true and smelter.tool_unlock.note:match("^usable now")
  and smelter.tool_unlock.note:match("construction%-robotics is not needed"),
  "a blueprint is usable before construction-robotics, and the result says so")
check(logged[1] and logged[1].kind == "blueprint" and logged[1].action == "capture" and logged[1].name == "smelter"
  and logged[1].entities == 3, "a capture is a row in activity_log")
local scratch = storage.blueprints.inventory[state.BLUEPRINT_SLOTS]
check(not scratch.valid_for_read, "the scratch slot is empty after a capture")

local function fails(fn, pattern)
  local ok, err = pcall(fn)
  return not ok and tostring(err):match(pattern) ~= nil
end
check(fails(function() capture({ name = "far", center = { x = 200, y = 0 }, radius = 4 }) end, "uncharted"),
  "a capture reaching uncharted land is refused")
check(fails(function() capture({ name = "huge", area = { left_top = { x = -40, y = 0 }, right_bottom = { x = 40, y = 10 } } }) end,
  "at most 64"), "a capture area larger than 64 tiles a side is refused")
check(fails(function() capture({ name = "empty", center = { x = -40, y = -40 }, radius = 3 }) end, "no own entities")
  and storage.blueprints.by_name.empty == nil and not scratch.valid_for_read,
  "an area without own entities stores nothing")
check(fails(function() capture({ name = "bad/name", center = { x = 2, y = 2 }, radius = 4 }) end, "name must be"),
  "a blueprint name is checked")
local crowd = {}
for i = 1, blueprints.MAX_ENTITIES + 1 do
  crowd[i] = { name = "transport-belt", type = "transport-belt", position = { x = -30 + (i % 20) + 0.5, y = -30 + math.floor(i / 20) + 0.5 },
    direction = 0, force = own }
end
local saved_world = bp.world
bp.world = crowd
local blueprints_built = #bp.created
check(fails(function() capture({ name = "crowd", area = { left_top = { x = -31, y = -31 }, right_bottom = { x = -9, y = -20 } } }) end,
  "at most 100") and storage.blueprints.by_name.crowd == nil and #bp.created == blueprints_built
  and counts[#counts].limit == blueprints.MAX_ENTITIES + 2,
  "a blueprint takes at most 100 entities: a crowded area is refused by a bounded count, before any blueprint is built")
bp.world = saved_world

-- create_blueprint keeps world positions; the capture shifts them by an even
-- whole vector so the block sits about (0, 0) and names that vector origin.
check(smelter.origin and smelter.origin.x == 2 and smelter.origin.y == 2,
  "a capture names the even origin it moved its entities from")
bp.world = {
  { name = "assembling-machine-1", type = "assembling-machine", position = { x = 36.5, y = -35.5 }, direction = 0, force = own },
  { name = "inserter", type = "inserter", position = { x = 38.5, y = -35.5 }, direction = 4, force = own },
  { name = "stone-furnace", type = "furnace", position = { x = 40, y = -36 }, direction = 0, force = own },
}
bp.world_tiles = { { name = "stone-path", position = { x = 35, y = -37 } } }
local far_block = capture({ name = "far-block", area = { left_top = { x = 34, y = -38 }, right_bottom = { x = 42, y = -33 } } })
local far_described = describe("far-block")
local far_rows = far_described.entities
check(far_block.origin.x == 38 and far_block.origin.y == -36 and far_described.origin.x == 38 and far_described.origin.y == -36
  and far_rows[1].dx == -1.5 and far_rows[1].dy == 0.5 and far_rows[2].dx == 0.5 and far_rows[3].dx == 2 and far_rows[3].dy == 0
  and far_block.size.w == 6 and far_block.size.h == 3,
  "a capture far from (0, 0) describes small dx/dy about its origin; origin + dx/dy is where each stood")
local far_tiles = bp.state(storage.blueprints.inventory[storage.blueprints.by_name["far-block"].slot]).tiles
check(far_tiles and far_tiles[1].position.x == -3 and far_tiles[1].position.y == -1, "its tiles move by the same origin")
local far_flip = blueprints.layout("far-block", "horizontal")
check(far_flip.entities[1].dx == 1.5 and far_flip.entities[3].dx == -2 and far_flip.entities[2].direction == 12,
  "a flip of a captured block pivots at the block, not the world origin")
bp.world, bp.world_tiles = { { name = "inserter", type = "inserter", position = { x = 0.5, y = 0.5 }, direction = 0, force = own } }, {}
local near = capture({ name = "near", area = { left_top = { x = -1, y = -1 }, right_bottom = { x = 1.9, y = 1.9 } } })
check(near.origin.x == 0 and near.origin.y == 0 and describe("near").entities[1].dx == 0.5,
  "a capture already about (0, 0) stays where it is")
blueprints.delete({ name = "far-block" })
blueprints.delete({ name = "near" })
bp.world = saved_world

-- create: a layout spec, nothing in the world.
local made = blueprints.create({ name = "gears", entities = {
  { name = "assembling-machine-1", dx = 0.5, dy = 0.5, recipe = "iron-gear-wheel" },
  { name = "inserter", dx = 2.5, dy = 0.5, direction = 4 } } })
local gears = bp.state(storage.blueprints.inventory[storage.blueprints.by_name.gears.slot])
check(made.entities == 2 and gears.entities[1].name == "assembling-machine-1" and gears.entities[1].recipe == "iron-gear-wheel"
  and gears.entities[2].direction == 4 and gears.entities[1].direction == nil,
  "create sets the layout as the blueprint's entities, recipe and direction kept")
check(fails(function() blueprints.create({ name = "x", entities = { { name = "inserter", dx = 0, dy = 0, recipe = "iron-gear-wheel" } } }) end,
  "takes no recipe"), "a recipe on something that takes none is refused")
check(fails(function() blueprints.create({ name = "x", entities = { { name = "nothing", dx = 0, dy = 0 } } }) end, "no entity called"),
  "an unknown entity is refused")
-- Settings and the mirror become the blueprint's own fields.
blueprints.create({ name = "sorter", entities = {
  { name = "inserter", dx = 0.5, dy = 0.5, settings = { inserter = { filters = { "iron-plate", "coal" }, mode = "blacklist",
    stack_size = 1, spoil_priority = "spoiled_first" } } },
  { name = "splitter", dx = 2, dy = 0.5, settings = { splitter = { input_priority = "right", filter = "coal" } } },
  { name = "assembling-machine-1", dx = 5.5, dy = 1.5, mirror = true } } })
local sorter = bp.state(storage.blueprints.inventory[storage.blueprints.by_name.sorter.slot]).entities
check(sorter[1].use_filters == true and sorter[1].filters[1].index == 1 and sorter[1].filters[2].name == "coal"
  and sorter[1].filter_mode == "blacklist" and sorter[1].override_stack_size == 1 and sorter[1].spoil_priority == "spoiled-first",
  "an inserter's settings are its blueprint filters, mode, stack size and spoil priority")
check(sorter[2].input_priority == "right" and sorter[2].output_priority == "left" and sorter[2].filter.name == "coal"
  and sorter[3].mirror == true, "a splitter filter gets an output side; a mirrored machine is mirrored")
local sorted_layout = blueprints.layout("sorter")
check(sorted_layout.entities[1].settings.inserter.filters[2] == "coal" and sorted_layout.entities[1].settings.inserter.mode == "blacklist"
  and sorted_layout.entities[2].settings.splitter.filter == "coal" and sorted_layout.entities[3].mirror == true,
  "the blueprint reads back as the same settings for a hand-built layout")
check(fails(function() blueprints.create({ name = "x", entities = { { name = "stone-furnace", dx = 0, dy = 0,
  settings = { inserter = { filters = { "coal" } } } } } }) end, "CONFIG_NOT_APPLICABLE"),
  "settings an entity cannot take are refused")
check(fails(function() blueprints.create({ name = "x", entities = { { name = "inserter", dx = 0, dy = 0,
  settings = { inserter = { filters = { "unobtainium" } } } } } }) end, "UNKNOWN_ITEM"), "an unknown filter item is refused")
blueprints.delete({ name = "sorter" })

local listed = blueprints.list()
check(#listed.blueprints == 2 and listed.blueprints[1].name == "gears" and listed.blueprints[2].name == "smelter"
  and listed.blueprints[2].source == "capture" and listed.capacity == state.BLUEPRINT_SLOTS - 1,
  "list names every stored blueprint in name order")

-- describe: entities with relative positions, settings and requested items.
gears.entities[2].filters = { { index = 1, name = "iron-plate" } }
gears.entities[2].use_filters = true
gears.entities[1].items = { { id = { name = "speed-module" }, items = { in_inventory = {
  { inventory = 4, stack = 0 }, { inventory = 4, stack = 1, count = 1 } } } } }
local described = describe("gears")
local machine, arm = described.entities[1], described.entities[2]
check(described.entity_count == 2 and machine.dx == 0.5 and machine.recipe == "iron-gear-wheel" and machine.insert["speed-module"] == 2
  and arm.direction == 4 and arm.settings.inserter.filters[1] == "iron-plate",
  "describe lists relative positions, recipes, settings and the items a blueprint requests")
check(fails(function() describe("missing") end, "no blueprint called 'missing'.*stored: gears, smelter"),
  "describing an unknown blueprint names the stored ones")
local budget = { left = 100 }
local job_state = blueprints.describe_job.start({ name = "gears" })
local direct = blueprints.describe_job.step(job_state, budget)
check(direct.entity_count == 2 and budget.left == 98, "describe is a job that counts one work item per entity")

local exported = blueprints.export({ name = "smelter" })
check(type(exported.blueprint_string) == "string" and exported.note:match("not imported"),
  "export gives the string for notes; nothing imports it")

-- Replacing a name keeps its slot; the inventory holds 32 names.
local slot = storage.blueprints.by_name.smelter.slot
capture({ name = "smelter", center = { x = 1, y = 1 }, radius = 1 })
check(storage.blueprints.by_name.smelter.slot == slot and storage.blueprints.by_name.smelter.entities == 1,
  "capturing an existing name replaces it in place")
for i = 1, state.BLUEPRINT_SLOTS - 3 do
  blueprints.create({ name = "b" .. i, entities = { { name = "inserter", dx = 0.5, dy = 0.5 } } })
end
check(blueprints.count() == state.BLUEPRINT_SLOTS - 1 and fails(function()
  blueprints.create({ name = "one-more", entities = { { name = "inserter", dx = 0.5, dy = 0.5 } } })
end, "delete one first"), "a 33rd blueprint is refused until one is deleted")
local deleted = blueprints.delete({ name = "b1" })
check(deleted.deleted == "b1" and storage.blueprints.by_name.b1 == nil and logged[#logged].action == "delete",
  "delete drops the blueprint and logs it")

-- Flips mirror positions and directions (and splitter sides); turns are
-- build_layout's or build_blueprint's.
local flipped = blueprints._flipped({ name = "inserter", position = { x = 2.5, y = 0.5 }, direction = 4 }, "horizontal")
local split = blueprints._flipped({ name = "splitter", position = { x = 0, y = -1.5 }, direction = 0,
  input_priority = "left", output_priority = "right" }, "vertical")
local machine_flip = blueprints._flipped({ name = "assembling-machine-1", position = { x = 1, y = 1 } }, "horizontal")
check(flipped.position.x == -2.5 and flipped.position.y == 0.5 and flipped.direction == 12,
  "a horizontal flip mirrors x and turns east into west")
check(split.position.y == 1.5 and split.direction == 8 and split.input_priority == "right" and split.output_priority == "left",
  "a vertical flip mirrors y, turns north into south and swaps splitter sides")
check(machine_flip.mirror == true, "a flipped assembling machine is mirrored")
local layout = blueprints.layout("gears", "horizontal")
check(layout.entities[2].dx == -2.5 and layout.entities[2].direction == 12, "layout applies the flip")
local copy = blueprints.build_stack("gears", "vertical", "test")
check(copy == scratch and bp.state(copy).entities[2].position.y == -0.5, "a flipped copy is built in the scratch slot")
blueprints.clear_scratch()
check(blueprints.build_stack("gears", nil, "test") ~= scratch, "an unflipped placement uses the stored blueprint")

-- Construction robots covering a spot are counted from the networks there.
networks = { mock.logistic_network({ all_construction_robots = 7 }), mock.logistic_network({ all_construction_robots = 3 }) }
check(blueprints.construction_robots(body, { x = 0, y = 0 }) == 10, "construction robots are counted where ghosts would go")
own.technologies["construction-robotics"].researched = true
check(blueprints.tool_unlock(body, "deconstruction-planner").researched == true
  and blueprints.tool_unlock(body, "upgrade-planner").technology == nil,
  "a tool's unlock is reported per tool; one without a shortcut names none")

-- A lost inventory (e.g. a mod removed and re-added) starts empty again.
storage.blueprints.inventory = nil
state.init()
check(created_inventories == 2 and next(storage.blueprints.by_name) == nil, "a lost inventory is made again, without stale names")

mock.assert_clean()
print(failures == 0 and "\nALL BLUEPRINT TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
