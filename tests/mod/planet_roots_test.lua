-- production_requirements resource roots per planet (C11): roots come from
-- planet prototype data only (autoplace settings and controls, tile
-- liquids, asteroid spawns of locations and connections), are built once per
-- load, and say how each raw is gathered; `planet` limits recipes to those
-- whose surface conditions hold there. Prototypes are strict 2.0.77 mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local function mined(products) return { minable = true, products = products } end
local function item(name, amount) return { type = "item", name = name, amount = amount or 1 } end
local entities = {
  ["burner-mining-drill"] = mock.entity_prototype({ name = "burner-mining-drill", type = "mining-drill",
    resource_categories = { ["basic-solid"] = true } }),
  ["electric-mining-drill"] = mock.entity_prototype({ name = "electric-mining-drill", type = "mining-drill",
    resource_categories = { ["basic-solid"] = true } }),
  ["big-mining-drill"] = mock.entity_prototype({ name = "big-mining-drill", type = "mining-drill",
    resource_categories = { ["basic-solid"] = true, ["hard-solid"] = true } }),
  ["iron-ore"] = mock.entity_prototype({ name = "iron-ore", type = "resource", resource_category = "basic-solid",
    mineable_properties = mined({ item("iron-ore") }) }),
  ["tungsten-ore"] = mock.entity_prototype({ name = "tungsten-ore", type = "resource", resource_category = "hard-solid",
    mineable_properties = mined({ item("tungsten-ore") }) }),
  ["sulfuric-acid-geyser"] = mock.entity_prototype({ name = "sulfuric-acid-geyser", type = "resource",
    resource_category = "basic-fluid", mineable_properties = mined({ { type = "fluid", name = "sulfuric-acid", amount = 10 } }) }),
  ["big-volcanic-rock"] = mock.entity_prototype({ name = "big-volcanic-rock", type = "simple-entity",
    mineable_properties = mined({ item("stone", 20), item("tungsten-ore", 4) }) }),
  ["yumako-tree"] = mock.entity_prototype({ name = "yumako-tree", type = "plant",
    mineable_properties = mined({ item("yumako", 50) }) }),
  -- A tree no autoplace setting names: its control places it on Nauvis.
  ["tree-01"] = mock.entity_prototype({ name = "tree-01", type = "tree", autoplace_specification = { control = "trees" },
    mineable_properties = mined({ item("wood", 4) }) }),
  ["stone-furnace"] = mock.entity_prototype({ name = "stone-furnace", type = "furnace",
    mineable_properties = mined({ item("stone-furnace") }) }),
}
local filtered = 0
local tiles = {
  water = mock.tile_prototype({ name = "water", fluid = { name = "water" } }),
  grass = mock.tile_prototype({ name = "grass" }),
  lava = mock.tile_prototype({ name = "lava", fluid = { name = "lava" } }),
  ["wetland-yumako"] = mock.tile_prototype({ name = "wetland-yumako", fluid = { name = "water" } }),
}
local function settings(names) local out = {}; for _, name in ipairs(names) do out[name] = {} end; return { settings = out } end
_G.prototypes = {
  entity = entities, tile = tiles, item = {}, fluid = {},
  space_location = {
    nauvis = mock.space_location_prototype({ name = "nauvis", surface_properties = { pressure = 1000 },
      map_gen_settings = { autoplace_controls = { trees = {} },
        autoplace_settings = { entity = settings({ "iron-ore" }), tile = settings({ "water", "grass" }) } },
      asteroid_spawn_definitions = { { type = "asteroid-chunk", asteroid = "metallic-asteroid-chunk", probability = 0.1, speed = 1 } } }),
    vulcanus = mock.space_location_prototype({ name = "vulcanus", surface_properties = { pressure = 4000 },
      map_gen_settings = { autoplace_settings = {
        entity = settings({ "tungsten-ore", "sulfuric-acid-geyser", "big-volcanic-rock" }), tile = settings({ "lava" }) } } }),
    gleba = mock.space_location_prototype({ name = "gleba", surface_properties = { pressure = 2000 },
      map_gen_settings = { autoplace_settings = { entity = settings({ "yumako-tree" }), tile = settings({ "wetland-yumako" }) } } }),
    -- No map generation: no planet roots.
    ["solar-system-edge"] = mock.space_location_prototype({ name = "solar-system-edge" }),
  },
  space_connection = {
    ["nauvis-vulcanus"] = mock.space_connection_prototype({ name = "nauvis-vulcanus", asteroid_spawn_definitions = {
      { type = "asteroid-chunk", asteroid = "carbonic-asteroid-chunk", spawn_points = {} },
      { type = "entity", asteroid = "medium-carbonic-asteroid", spawn_points = {} } } }),
  },
  asteroid_chunk = {
    ["metallic-asteroid-chunk"] = mock.asteroid_chunk_prototype({ name = "metallic-asteroid-chunk",
      mineable_properties = mined({ item("metallic-asteroid-chunk") }) }),
    ["carbonic-asteroid-chunk"] = mock.asteroid_chunk_prototype({ name = "carbonic-asteroid-chunk",
      mineable_properties = mined({ item("carbonic-asteroid-chunk") }) }),
  },
  surface_property = { pressure = mock.surface_property_prototype({ name = "pressure", default_value = 1000 }) },
  get_entity_filtered = function(filters)
    filtered = filtered + 1
    local wanted = {}
    for _, kind in ipairs(type(filters[1].type) == "table" and filters[1].type or { filters[1].type }) do wanted[kind] = true end
    local found = {}
    for name, proto in pairs(entities) do if wanted[proto.type] then found[name] = proto end end
    return mock.custom_table(found)
  end,
}
for _, name in ipairs({ "tungsten-plate", "tungsten-ore", "iron-ore", "iron-plate", "yumako", "wood", "stone",
  "metallic-asteroid-chunk", "carbonic-asteroid-chunk", "mystery", "sulfur", "big-mining-drill" }) do
  prototypes.item[name] = {}
end
for _, name in ipairs({ "lava", "water", "sulfuric-acid" }) do prototypes.fluid[name] = {} end
prototypes.space_location = mock.custom_table(prototypes.space_location)
prototypes.space_connection = mock.custom_table(prototypes.space_connection)

-- Recipes: the force's LuaRecipe tables, each with its strict prototype.
local function recipe(name, ingredients, products, conditions)
  return { name = name, enabled = true, energy = 1, category = "crafting", ingredients = ingredients, products = products,
    prototype = mock.recipe_prototype({ name = name, surface_conditions = conditions }) }
end
local PRESSURE_4000 = { { property = "pressure", min = 4000, max = 4000 } }
local force = { recipes = {
  ["tungsten-plate"] = recipe("tungsten-plate", { item("tungsten-ore", 4) }, { item("tungsten-plate") }, PRESSURE_4000),
  ["big-mining-drill"] = recipe("big-mining-drill", { item("tungsten-plate", 20) }, { item("big-mining-drill") }, PRESSURE_4000),
  ["iron-plate"] = recipe("iron-plate", { item("iron-ore") }, { item("iron-plate") }),
  ["sulfuric-acid"] = recipe("sulfuric-acid", { item("sulfur", 5) }, { { type = "fluid", name = "sulfuric-acid", amount = 50 } }),
} }
force.recipes["metallic-asteroid-crushing"] = recipe("metallic-asteroid-crushing",
  { item("metallic-asteroid-chunk") }, { item("iron-ore", 20) })
force.recipes["metallic-asteroid-crushing"].enabled = false
-- The body stands on Nauvis.
local body = { valid = true, force = force, position = { x = 0, y = 0 },
  surface = { name = "nauvis", index = 1, planet = { name = "nauvis" } },
  get_main_inventory = function() return nil end }
package.loaded["scripts.companion"] = { get = function() return body end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
_G.game = { tick = 1 }
_G.defines = { flow_precision_index = { one_minute = 2 } }
_G.storage = _G.storage or {}
local production = require("scripts.production_requirements")
local function ask(params) return production.production_requirements(params) end

-- A planet's liquids (observe_local's "~" legend, the power block) come from
-- that planet's own tiles alone: no roots walk over every prototype.
check(production.has_liquid("nauvis", "water") and not production.has_liquid("nauvis", "lava")
  and production.has_liquid("vulcanus", "lava") and production.has_liquid("gleba", "water")
  and not production.has_liquid("solar-system-edge", "water") and filtered == 0,
  "a planet's liquids are read from its own tiles, without building the roots")

-- Tungsten plates from Nauvis: the ore is Vulcanus's, by big drill or by hand
-- (big volcanic rocks); the plate recipe needs Vulcanus's pressure.
local plates = ask({ targets = { ["tungsten-plate"] = 2 } })
local roots = plates.roots["tungsten-ore"]
check(plates.planet == "nauvis" and #plates.nodes == 1 and plates.raw["tungsten-ore"] == 8 and #roots == 2
  and roots[1].planet == "vulcanus" and roots[1].via == "big_drill" and roots[2].planet == "vulcanus" and roots[2].via == "hand",
  "tungsten ore from Nauvis is rooted on Vulcanus: big drill (only it mines hard-solid) and hand (big volcanic rock)")
check(#plates.surface_limited == 1 and plates.surface_limited[1].recipe == "tungsten-plate"
  and plates.surface_limited[1].condition.property == "pressure" and plates.surface_limited[1].condition.min == 4000
  and #plates.surface_limited[1].planets == 1 and plates.surface_limited[1].planets[1] == "vulcanus",
  "a recipe with surface conditions is surface_limited, naming the planets that allow it")
check(filtered == 2, "roots read the drills and the hand-gathered entities through two type filters")

local lava = ask({ targets = { lava = 100 } })
check(lava.raw.lava == 100 and lava.roots.lava[1].planet == "vulcanus" and lava.roots.lava[1].via == "offshore",
  "lava is an offshore root of Vulcanus")
local fruit = ask({ targets = { yumako = 10 } })
check(#fruit.roots.yumako == 2 and fruit.roots.yumako[1].via == "hand" and fruit.roots.yumako[2].via == "tower"
  and fruit.roots.yumako[1].planet == "gleba", "a plant is gathered by hand or an agricultural tower on its planet")
local wood = ask({ targets = { wood = 4 } })
check(wood.roots.wood and wood.roots.wood[1].planet == "nauvis" and wood.roots.wood[1].via == "hand",
  "a tree placed by an autoplace control (trees) is a hand root of that planet")
local chunks = ask({ targets = { ["metallic-asteroid-chunk"] = 1, ["carbonic-asteroid-chunk"] = 1 } })
check(chunks.roots["metallic-asteroid-chunk"][1].planet == "nauvis" and chunks.roots["metallic-asteroid-chunk"][1].via == "asteroid"
  and chunks.roots["carbonic-asteroid-chunk"][1].planet == "nauvis-vulcanus" and #chunks.roots["carbonic-asteroid-chunk"] == 1,
  "asteroid chunks root where they spawn: a location's orbit or a space connection (entity asteroids are not chunks)")
local mystery = ask({ targets = { mystery = 1, ["iron-ore"] = 3 } })
check(#mystery.unobtainable == 1 and mystery.unobtainable[1] == "mystery" and mystery.raw["iron-ore"] == 3
  and mystery.roots["iron-ore"][1].via == "drill", "a raw nothing gathers is unobtainable; native ore is a drill root")
local acid = ask({ targets = { ["sulfuric-acid"] = 50 } })
check(acid.raw.sulfur == 5 and acid.raw["sulfuric-acid"] == nil,
  "on Nauvis a Vulcanus geyser fluid expands through its recipe; roots are per planet")

-- planet: plan there. On Vulcanus the geyser fluid and the ore are native;
-- on Nauvis the plate recipe's pressure condition fails, so it is no route.
local vulcan = ask({ targets = { ["sulfuric-acid"] = 50, ["tungsten-plate"] = 1 }, planet = "vulcanus" })
check(vulcan.planet == "vulcanus" and vulcan.raw["sulfuric-acid"] == 50 and vulcan.raw["tungsten-ore"] == 4
  and vulcan.roots["sulfuric-acid"][1].via == "pump", "planning for Vulcanus takes its geyser fluid and ore as raw (pump root)")
local nauvis_only = ask({ targets = { ["tungsten-plate"] = 1 }, planet = "nauvis" })
check(#nauvis_only.nodes == 0 and nauvis_only.raw["tungsten-plate"] == 1 and nauvis_only.unobtainable[1] == "tungsten-plate",
  "planning for Nauvis drops recipes whose surface conditions fail there")
check(not pcall(ask, { targets = { ["iron-plate"] = 1 }, planet = "atlantis" }), "an unknown planet is refused")

-- The roots are built once per load: later reads walk no prototype.
check(filtered == 2, "the roots table is built once and reused (" .. filtered .. " filtered walks)")

-- Surface-limited recipes name their planets from the roots' planet list
-- (no map_gen_settings copy per node), and a recipe's surface conditions
-- are read only when it makes the product looked for.
local settings_reads, condition_reads = 0, 0
for _, location in pairs(prototypes.space_location) do
  local ok_value, value = pcall(function() return location.map_gen_settings end)
  mock.read(location, "map_gen_settings", function() settings_reads = settings_reads + 1; return ok_value and value or nil end)
end
for _, each in pairs(force.recipes) do
  local conditions = each.prototype.surface_conditions
  mock.read(each.prototype, "surface_conditions", function() condition_reads = condition_reads + 1; return conditions end)
end
local drill = ask({ targets = { ["big-mining-drill"] = 1 } })
check(settings_reads == 0 and #drill.surface_limited == 2 and drill.surface_limited[1].planets[1] == "vulcanus",
  "surface-limited planets come from the roots' list, with no map_gen_settings read (" .. settings_reads .. ")")
condition_reads = 0
ask({ targets = { ["iron-plate"] = 1 }, planet = "nauvis" })
check(condition_reads <= 2, "only recipes that make the product have their surface conditions read (" .. condition_reads .. ")")

-- Aboard a platform the plan is for the platform's location.
body.surface = { name = "platform-1", index = 5, platform = { space_location = { name = "vulcanus" } } }
local aboard = ask({ targets = { ["sulfuric-acid"] = 10 } })
check(aboard.planet == "vulcanus" and aboard.raw["sulfuric-acid"] == 10, "aboard, the plan is for the platform's location")

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
