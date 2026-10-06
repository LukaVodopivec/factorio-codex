-- Offline tests for production_requirements per_minute (the rate planner):
-- machines per tier, fuel and power, drills per resource and belt capacity,
-- all from prototype data with Factorio 2.0 base values.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local function recipe(name, ingredients, products, enabled, energy, category)
  return { name = name, ingredients = ingredients, products = products, enabled = enabled, energy = energy, category = category }
end

local character = { valid = true, surface = { name = "nauvis", planet = { name = "nauvis" } } }
local force = { recipes = {
  ["iron-plate"] = recipe("iron-plate", { { name = "iron-ore", amount = 1 } }, { { name = "iron-plate", amount = 1 } }, true, 3.2, "smelting"),
  ["iron-gear-wheel"] = recipe("iron-gear-wheel", { { name = "iron-plate", amount = 2 } }, { { name = "iron-gear-wheel", amount = 1 } }, true, 0.5, "crafting"),
  ["stone-furnace"] = recipe("stone-furnace", {}, { { name = "stone-furnace", amount = 1 } }, true, 0.5, "crafting"),
  ["burner-mining-drill"] = recipe("burner-mining-drill", {}, { { name = "burner-mining-drill", amount = 1 } }, true, 2, "crafting"),
  ["electric-mining-drill"] = recipe("electric-mining-drill", {}, { { name = "electric-mining-drill", amount = 1 } }, false, 2, "crafting"),
  ["assembling-machine-1"] = recipe("assembling-machine-1", {}, { { name = "assembling-machine-1", amount = 1 } }, false, 0.5, "crafting"),
  ["transport-belt"] = recipe("transport-belt", {}, { { name = "transport-belt", amount = 2 } }, true, 0.5, "crafting"),
  mash = recipe("mash", { { name = "iron-plate", amount = 1 } }, { { name = "mash", amount = 1 } }, true, 2, "organic"),
  biochamber = recipe("biochamber", {}, { { name = "biochamber", amount = 1 } }, true, 10, "crafting"),
} }
character.force = force
character.get_main_inventory = function() return { get_item_count = function() return 0 end } end
package.loaded["scripts.companion"] = { require_companion = function() return character end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return character end)

local function placed(name) return { { name = name, count = 1 } } end
local function machine(kind, name, fields)
  local proto = { type = kind, name = name, items_to_place_this = placed(name) }
  for key, value in pairs(fields) do proto[key] = value end
  return proto
end
local burner = { effectivity = 1, fuel_categories = { chemical = true } }
_G.prototypes = {
  item = { ["iron-ore"] = {}, ["iron-plate"] = {}, ["iron-gear-wheel"] = {}, coal = { fuel_value = 4e6, fuel_category = "chemical" }, wood = { fuel_value = 2e6, fuel_category = "chemical" },
    ["iron-plate-fuel"] = {}, bioflux = { fuel_value = 6e6, fuel_category = "food" }, mash = {} },
  fluid = {},
  space_location = { nauvis = { name = "nauvis", map_gen_settings = { autoplace_settings = {
    entity = { settings = { ["iron-ore"] = {} } }, tile = { settings = {} } } } } },
  space_connection = {},
  entity = {
    ["iron-ore"] = { type = "resource", name = "iron-ore", resource_category = "basic-solid",
      mineable_properties = { minable = true, mining_time = 1, products = { { type = "item", name = "iron-ore", amount = 1 } } } },
    -- 90 kW stone furnace (1500 J/tick), 150 kW burner drill, 90 kW electric drill (3000 J/tick), 75 kW assembler 1.
    ["stone-furnace"] = machine("furnace", "stone-furnace", { crafting_categories = { smelting = true }, burner_prototype = burner,
      get_crafting_speed = function() return 1 end, get_max_energy_usage = function() return 1500 end }),
    ["assembling-machine-1"] = machine("assembling-machine", "assembling-machine-1", { crafting_categories = { crafting = true },
      electric_energy_source_prototype = {}, get_crafting_speed = function() return 0.5 end, get_max_energy_usage = function() return 1250 end }),
    ["burner-mining-drill"] = machine("mining-drill", "burner-mining-drill", { resource_categories = { ["basic-solid"] = true },
      mining_speed = 0.25, burner_prototype = burner, get_max_energy_usage = function() return 2500 end }),
    ["electric-mining-drill"] = machine("mining-drill", "electric-mining-drill", { resource_categories = { ["basic-solid"] = true },
      mining_speed = 0.5, electric_energy_source_prototype = {}, get_max_energy_usage = function() return 1500 end }),
    ["transport-belt"] = machine("transport-belt", "transport-belt", { belt_speed = 0.03125 }),
    -- A nutrient-burning machine with +50% built-in productivity (like a biochamber).
    biochamber = machine("assembling-machine", "biochamber", { crafting_categories = { organic = true },
      burner_prototype = { effectivity = 1, fuel_categories = { nutrients = true } }, effect_receiver = { base_effect = { productivity = 0.5 } },
      get_crafting_speed = function() return 2 end, get_max_energy_usage = function() return 8000 end }),
    ["crash-site-assembler"] = { type = "assembling-machine", name = "crash-site-assembler", crafting_categories = { crafting = true },
      get_crafting_speed = function() return 1 end, get_max_energy_usage = function() return 0 end },
  },
}
function prototypes.get_entity_filtered(filters)
  local wanted = {}
  for _, kind in ipairs(type(filters[1].type) == "table" and filters[1].type or { filters[1].type }) do wanted[kind] = true end
  local found = {}
  for name, proto in pairs(prototypes.entity) do if wanted[proto.type] then found[name] = proto end end
  return mock.custom_table(found)
end
_G.game = { tick = 1 }
_G.defines = { flow_precision_index = { five_seconds = 1, one_minute = 2, ten_minutes = 3, one_hour = 4 } }
local production = require("scripts.production_requirements")

local function close(a, b) return a ~= nil and math.abs(a - b) < 0.011 end
local plan = production.production_requirements({ targets = { ["iron-plate"] = 30 }, per_minute = true }).rates
local smelt = plan.stages[1]
local furnace = smelt.machines[1]
check(plan.units == "per_minute" and smelt.item == "iron-plate" and close(smelt.executions_per_minute, 30)
  and furnace.entity == "stone-furnace" and close(furnace.machines, 1.6) and furnace.machines_to_build == 2
  and furnace.energy == "burner" and close(furnace.fuel_per_minute, 2.16) and furnace.unlocked,
  "30 iron plates per minute need 1.6 stone furnaces burning 2.16 coal per minute")
local ore = plan.raw[1]
local by_drill = {}
for _, row in ipairs(ore.drills) do by_drill[row.entity] = row end
check(ore.item == "iron-ore" and close(ore.units_per_minute, 30) and ore.resource == "iron-ore"
  and close(by_drill["burner-mining-drill"].machines, 2) and close(by_drill["burner-mining-drill"].fuel_per_minute, 4.5)
  and close(by_drill["electric-mining-drill"].machines, 1) and close(by_drill["electric-mining-drill"].power_kw, 90)
  and by_drill["electric-mining-drill"].unlocked == false,
  "30 ore per minute need 2 burner drills (4.5 coal/min) or 1 electric drill (90 kW, still locked)")
check(#plan.belts == 1 and plan.belts[1].entity == "transport-belt" and close(plan.belts[1].items_per_minute, 900)
  and plan.reference_fuel.item == "coal" and close(plan.reference_fuel.megajoules, 4),
  "a yellow belt carries 900 items per minute; coal is the reference fuel at 4 MJ")

local gears = production.production_requirements({ targets = { ["iron-gear-wheel"] = 15 }, per_minute = true, fuel = "wood" }).rates
local by_item = {}
for _, stage in ipairs(gears.stages) do by_item[stage.item] = stage end
check(close(by_item["iron-gear-wheel"].machines[1].machines, 0.25) and close(by_item["iron-gear-wheel"].machines[1].power_kw, 18.75)
  and close(by_item["iron-plate"].units_per_minute, 30) and close(by_item["iron-plate"].machines[1].fuel_per_minute, 4.32),
  "15 gears per minute chain to 30 plates per minute; fuel is priced in the chosen fuel")
check(not pcall(production.production_requirements, { targets = { ["iron-plate"] = 30 }, per_minute = true, fuel = "nothing" })
  and not pcall(production.production_requirements, { targets = { ["iron-plate"] = 30 }, per_minute = true, fuel = "iron-plate-fuel" }),
  "an unknown fuel or an item with no fuel value is refused")
local mash = production.production_requirements({ targets = { mash = 60 }, per_minute = true }).rates
local organic
for _, stage in ipairs(mash.stages) do if stage.item == "mash" then organic = stage.machines end end
check(#organic == 1 and close(organic[1].machines, 0.67) and organic[1].fuel_per_minute == nil
  and organic[1].fuel_categories[1] == "nutrients",
  "built-in productivity shares the work, and coal is never priced for a machine that cannot burn it")
check(#gears.stages[1].machines == 1, "machines with no placing item (crash-site wrecks) are not listed")
check(close(production.production_requirements({ targets = { ["iron-plate"] = 7.5 }, per_minute = true }).rates.stages[1].machines[1].machines, 0.4),
  "fractional rates are accepted and planned exactly")
os.exit(failures == 0 and 0 or 1)
