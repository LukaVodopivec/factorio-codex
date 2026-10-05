-- Placement on other planets (C6, C9, C10, C7 for placement reads, C8
-- inspect, C13/C14 keys): one liquid helper (water, lava, oil ocean), the
-- fluid an offshore pump pumps, surface conditions refused before any
-- search, can_place and find_placement on a surface the body is not on (no
-- body there), build_block's drill by resource category and power only
-- where there is water, inspect's heat fields on another surface, and item
-- keys and spoil reads. Surfaces, tiles and entities are strict mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.defines = { build_check_type = { manual = 1, ghost_revive = 5 }, entity_status = { working = 1, frozen = 2 },
  inventory = { chest = 1 } }
_G.storage = {}

-- Tiles by column: west of x = 0 a liquid (lava on Vulcanus, water on
-- Nauvis), land to x = 10, then a walkable oil ocean.
local function tile_proto(name, fluid) return mock.tile_prototype({ name = name, fluid = fluid and { name = fluid } or nil }) end
local TILES = {
  lava = { proto = tile_proto("lava", "lava"), layers = { water_tile = true, player = true } },
  water = { proto = tile_proto("water", "water"), layers = { water_tile = true, player = true } },
  land = { proto = tile_proto("volcanic-ash-flats"), layers = { ground_tile = true } },
  oil = { proto = tile_proto("oil-ocean-shallow", "heavy-oil"), layers = { water_tile = true } },
}
local tile_reads = 0
local function world(liquid, pressure, name, index, planet, standing)
  local function kind(x) return x < 0 and liquid or x < 10 and "land" or "oil" end
  local surface
  surface = mock.surface({ index = index, name = name, valid = true, planet = mock.planet({ name = planet }),
    get_tile = function(x, y)
      tile_reads = tile_reads + 1
      local t = TILES[kind(x)]
      return mock.tile({ name = t.proto.name, prototype = t.proto, position = { x = x, y = y },
        collides_with = function(layer) return t.layers[layer] == true end })
    end,
    get_property = function(property) return property == "pressure" and pressure or 0 end,
    -- An offshore pump needs liquid at its source; anything else needs land.
    can_place_entity = function(args)
      local x = math.floor(args.position.x)
      if args.name == "offshore-pump" then return kind(x - 1) ~= "land" and kind(x) == "land" end
      return kind(x) == "land"
    end,
    find_entities_filtered = function() return standing or {} end,
  })
  return surface
end
local vulcanus = world("lava", 4000, "vulcanus", 2, "vulcanus")
local cold_surface -- Aquilo's, made below
local nauvis = world("water", 1000, "nauvis", 1, "nauvis")

local function box(w) return { left_top = { x = -w / 2 + 0.1, y = -w / 2 + 0.1 }, right_bottom = { x = w / 2 - 0.1, y = w / 2 - 0.1 } } end
local PRESSURE_4000 = { { property = "pressure", min = 4000, max = 4000 } }
local pump = mock.entity_prototype({ name = "offshore-pump", type = "offshore-pump", tile_width = 1, tile_height = 1,
  collision_box = box(1), fluid_source_offset = { 0, -1 } })
local entities = {
  ["offshore-pump"] = pump,
  ["iron-chest"] = mock.entity_prototype({ name = "iron-chest", type = "container", tile_width = 1, tile_height = 1,
    collision_box = box(1) }),
  ["big-mining-drill"] = mock.entity_prototype({ name = "big-mining-drill", type = "mining-drill", tile_width = 5,
    tile_height = 5, collision_box = box(5), surface_conditions = PRESSURE_4000,
    resource_categories = { ["basic-solid"] = true, ["hard-solid"] = true },
    items_to_place_this = { { name = "big-mining-drill", count = 1 } } }),
  ["burner-mining-drill"] = mock.entity_prototype({ name = "burner-mining-drill", type = "mining-drill", tile_width = 2,
    tile_height = 2, collision_box = box(2), resource_categories = { ["basic-solid"] = true },
    burner_prototype = { fuel_categories = { chemical = true } }, items_to_place_this = { { name = "burner-mining-drill", count = 1 } } }),
  ["tungsten-ore"] = mock.entity_prototype({ name = "tungsten-ore", type = "resource", resource_category = "hard-solid" }),
  ["small-electric-pole"] = mock.entity_prototype({ name = "small-electric-pole", type = "electric-pole", tile_width = 1,
    tile_height = 1, collision_box = box(1) }),
}
local items = {}
for _, name in ipairs({ "offshore-pump", "iron-chest", "big-mining-drill", "burner-mining-drill", "small-electric-pole" }) do
  items[name] = { name = name, place_result = entities[name] }
end
items["transport-belt"] = { name = "transport-belt" }
_G.prototypes = { item = items, entity = entities, tile = { water = TILES.water.proto, lava = TILES.lava.proto },
  space_location = {
    nauvis = mock.space_location_prototype({ name = "nauvis",
      map_gen_settings = { autoplace_settings = { tile = { settings = { water = {} } } } } }),
    vulcanus = mock.space_location_prototype({ name = "vulcanus",
      map_gen_settings = { autoplace_settings = { tile = { settings = { lava = {} } } } } }) },
  space_connection = {},
  get_entity_filtered = function(filters)
    local found = {}
    for name, proto in pairs(entities) do if proto.type == filters[1].type then found[name] = proto end end
    return found
  end }

-- The body stands on Vulcanus at (5, 5).
local carried = {}
local recipes = { ["iron-chest"] = { enabled = true }, ["small-electric-pole"] = { enabled = true },
  ["burner-mining-drill"] = { enabled = true }, ["transport-belt"] = { enabled = true } }
local force = mock.force({ name = "player", recipes = recipes, is_chunk_charted = function() return true end })
local body = { valid = true, name = "character", position = { x = 5.5, y = 5.5 }, surface = vulcanus, force = force,
  bounding_box = { left_top = { x = 5.3, y = 5.3 }, right_bottom = { x = 5.7, y = 5.7 } },
  get_item_count = function(name) return carried[name] or 0 end }
package.loaded["scripts.companion"] = {}
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
package.loaded["scripts.tasks"] = { active_summary = function() return nil end, queue_length = function() return 0 end }
_G.game = { tick = 100, planets = { nauvis = mock.planet({ name = "nauvis", surface = nauvis }),
  vulcanus = mock.planet({ name = "vulcanus", surface = vulcanus }) },
  get_surface = function(index) return ({ nauvis, vulcanus, cold_surface })[index] end }

local geometry = require("scripts.placement_geometry")
local spatial = require("scripts.spatial")
local finder = require("scripts.find_placement")
local jobs = require("scripts.jobs")

-- One liquid helper.
local lava, land, oil = geometry.liquid_at(vulcanus, -1, 0), geometry.liquid_at(vulcanus, 3, 0), geometry.liquid_at(vulcanus, 12, 0)
check(lava.fluid == "lava" and lava.walkable == false and land == nil and oil.fluid == "heavy-oil" and oil.walkable == true,
  "liquid_at: lava is liquid and not walkable, land is none, an oil ocean is liquid yet walkable")
check(geometry.is_liquid(nauvis, -3, 0) and not geometry.is_liquid(nauvis, 3, 0), "is_liquid reads one tile's water layer")

-- can_place: the pump's fluid, the surface's conditions, the liquid named.
local placed = spatial.can_place({ placements = {
  { item = "offshore-pump", position = { x = 0.5, y = 0.5 }, direction = 12 },
  { item = "big-mining-drill", position = { x = 5.5, y = 0.5 } },
  { item = "iron-chest", position = { x = -2.5, y = 0.5 } },
  { item = "iron-chest", position = { x = 12.5, y = 0.5 } } } }).results
check(placed[1].can_place and placed[1].fluid == "lava", "an offshore pump facing west on Vulcanus's shore pumps lava")
check(placed[2].code == nil, "Vulcanus's pressure allows the big mining drill")
check(not placed[3].can_place and placed[3].reason:match("touches lava") ~= nil
  and not placed[4].can_place and placed[4].reason:match("heavy%-oil ocean") ~= nil,
  "a building over lava or the oil ocean is refused, naming the liquid")
local on_nauvis = spatial.can_place({ surface = "nauvis", placements = {
  { item = "big-mining-drill", position = { x = 5.5, y = 0.5 } },
  { item = "offshore-pump", position = { x = 0.5, y = 0.5 }, direction = 12 },
  { item = "iron-chest", position = { x = 5.5, y = 5.5 } } } }).results
check(on_nauvis[1].can_place == false and on_nauvis[1].code == "SURFACE_CONDITION"
  and on_nauvis[1].condition.property == "pressure" and on_nauvis[1].condition.value == 1000
  and on_nauvis[1].reason:match("^SURFACE_CONDITION: big%-mining%-drill needs pressure = 4000") ~= nil,
  "can_place {surface} refuses an entity whose surface conditions that planet breaks")
check(on_nauvis[2].fluid == "water" and on_nauvis[3].can_place == true,
  "on Nauvis the same shore pumps water; the body's Vulcanus spot does not block a Nauvis chest")

-- find_placement: fluid filter, conditions before the search, another surface.
local function find(params) return jobs.run_now(finder.job, params) end
local lava_pumps = find({ item = "offshore-pump", preferred = { x = 0.5, y = 0.5 }, radius = 2, directions = { 12 }, fluid = "lava" })
check(#lava_pumps.candidates > 0 and lava_pumps.candidates[1].fluid == "lava" and lava_pumps.surface == "vulcanus",
  "find_placement names the fluid each offshore spot pumps")
local water_pumps = find({ item = "offshore-pump", preferred = { x = 0.5, y = 0.5 }, radius = 2, directions = { 12 }, fluid = "water" })
check(#water_pumps.candidates == 0 and water_pumps.rejections.wrong_fluid > 0 and water_pumps.hint:match("pumps water") ~= nil,
  "asking for water on Vulcanus finds no spot and says why")
local nauvis_pumps = find({ item = "offshore-pump", preferred = { x = 0.5, y = 0.5 }, radius = 2, directions = { 12 },
  fluid = "water", surface = "nauvis" })
check(#nauvis_pumps.candidates > 0 and nauvis_pumps.surface == "nauvis" and nauvis_pumps.candidates[1].distance_from_codex == nil,
  "find_placement {surface} searches another planet without a body there")
local refused, why = pcall(find, { item = "big-mining-drill", preferred = { x = 5.5, y = 0.5 }, surface = "nauvis" })
check(not refused and tostring(why):match("SURFACE_CONDITION") ~= nil, "a surface condition fails the search before it starts")
check(not pcall(find, { item = "iron-chest", preferred = { x = 5, y = 5 }, fluid = "lava" }),
  "fluid is only for offshore pumps")

-- build_block: tungsten needs the big mining drill; power needs water.
local blocks = require("scripts.blocks")
local no_drill, need = pcall(blocks.expand, body, { block = "mining", count = 2, resource = "tungsten-ore" })
check(not no_drill and tostring(need):match("^NEED_DRILL: .*hard%-solid.*big%-mining%-drill") ~= nil,
  "tungsten ore with no big mining drill to hand is NEED_DRILL, naming the drills that mine it")
carried["big-mining-drill"] = 2
local big = blocks.expand(body, { block = "mining", count = 2, resource = "tungsten-ore" })
local drills, poles, chests = {}, {}, {}
for _, e in ipairs(big.layout.entities) do
  if e.name == "big-mining-drill" then drills[#drills + 1] = e end
  if e.name == "small-electric-pole" then poles[#poles + 1] = e end
  if e.name == "iron-chest" then chests[#chests + 1] = e end
end
check(big.tiers.drill == "big-mining-drill" and #drills == 2 and drills[2].dx - drills[1].dx == 6 and #poles == 1
  and poles[1].dx == drills[1].dx + 3 and #chests == 2 and chests[1].dx == drills[1].dx and chests[1].dy == -0.5,
  "big drills pair around a pole, each emptying into a chest above its middle")
local dry, dry_why = pcall(blocks.expand, body, { block = "power", count = 1 })
check(not dry and tostring(dry_why):match("^NO_WATER_ON_SURFACE: vulcanus .*acid neutralisation") ~= nil,
  "a steam power block on Vulcanus is NO_WATER_ON_SURFACE with Vulcanus's usual power")
body.surface = nauvis
local wet, wet_why = pcall(blocks.expand, body, { block = "power", count = 1 })
check(tostring(wet_why):match("NO_WATER_ON_SURFACE") == nil, "Nauvis has water for boilers")
body.surface = vulcanus

-- inspect {surface}: a frozen assembler on Aquilo-like cold, read remotely.
local frozen = mock.entity({ valid = true, name = "assembling-machine-2", type = "assembling-machine",
  position = { x = 40.5, y = 0.5 }, force = force, direction = 0, status = 2, is_freezable = true, frozen = true,
  temperature = 4.25 })
local cold = world("water", 300, "aquilo", 3, "aquilo", { frozen })
cold_surface = cold
game.planets.aquilo = mock.planet({ name = "aquilo", surface = cold })
local inspect = require("scripts.inspect")
local seen = inspect.inspect({ surface = "aquilo", targets = { { x = 40.5, y = 0.5 } } })
local row = seen.entities[1]
check(seen.surface == "aquilo" and row.remote == true and row.frozen == true and row.temperature == 4.3 and row.status == "frozen",
  "inspect {surface} reads an own entity there remotely, with frozen and temperature")

-- Item keys and spoil reads.
local items_lib = require("scripts.items")
check(items_lib.key("iron-plate", "normal") == "iron-plate" and items_lib.key("iron-plate", "rare") == "iron-plate@rare"
  and items_lib.key("iron-plate", nil) == "iron-plate", "item keys: normal is the bare name, others name@quality")
prototypes.item.yumako = mock.item_prototype({ name = "yumako", get_spoil_ticks = function() return 3600 end })
prototypes.item["iron-plate"] = mock.item_prototype({ name = "iron-plate", get_spoil_ticks = function() return 0 end })
local stacks = {
  mock.item_stack({ valid_for_read = true, name = "yumako", spoil_tick = 1300, spoil_percent = 0.3 }),
  mock.item_stack({ valid_for_read = true, name = "iron-plate" }),
  mock.item_stack({ valid_for_read = false }),
  mock.item_stack({ valid_for_read = true, name = "yumako", spoil_tick = 700, spoil_percent = 0.85 }),
}
local spoil_inventory = setmetatable({}, { __index = function(_, i) return stacks[i] end, __len = function() return #stacks end })
local spoils, reads = items_lib.spoil(spoil_inventory, { "yumako", "iron-plate" })
check(spoils.yumako.spoils_in_s == 10 and spoils.yumako.spoil_percent_max == 85 and spoils["iron-plate"] == nil
  and reads == 1 + 2 * #stacks + 2 * 2, "spoil reads give the soonest spoil and the most spoiled stack of spoilable items only")

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
