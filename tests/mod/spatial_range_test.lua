local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local checks = 0
local surface = { can_place_entity = function() checks = checks + 1 return true end }
local charted_chunks = function(_, chunk) return chunk.y < 2 end
local body = { valid = true, position = { x = 0, y = 0 }, surface = surface,
  force = { recipes = {}, is_chunk_charted = function(...) return charted_chunks(...) end } }
package.loaded["scripts.companion"] = {
  require_companion = function() return body end,
  get = function() return body end,
}
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
package.loaded["scripts.tasks"] = { active_summary = function() return nil end }
_G.defines = { build_check_type = { manual = 1, ghost_revive = 5 } }
_G.prototypes = { item = {
  ["transport-belt"] = { place_result = { name = "transport-belt", collision_box = {
    left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 },
  } } },
  gear = { place_result = { name = "gear-entity", collision_box = { left_top = { x = 0, y = 0 }, right_bottom = { x = 1, y = 1 } } } },
  coal = { fuel_value = 4000000, fuel_category = "chemical" },
  wood = { name = "wood", stack_size = 100, fuel_value = 2000000, fuel_category = "chemical" },
  ["solid-fuel"] = { name = "solid-fuel", stack_size = 50, fuel_value = 12000000, fuel_category = "chemical" },
  ["rocket-fuel"] = { name = "rocket-fuel", stack_size = 10, fuel_value = 100000000, fuel_category = "chemical" },
}, entity = {
  ["burner-mining-drill"] = { name = "burner-mining-drill", tile_width = 2, tile_height = 2,
    vector_to_place_result = { x = 0, y = -1 }, burner_prototype = { fuel_categories = { chemical = true }, effectivity = 0.8, fuel_inventory_size = 1 },
    mining_speed = 0.25, get_crafting_speed = function() return 0.5 end,
    get_max_energy_usage = function() return 2500 end,
    get_max_energy_production = function() return 0 end },
  coal = { name = "coal", mineable_properties = { minable = true, mining_time = 1,
    products = { { name = "coal", amount = 1 } } } },
  ["variable-ore"] = { name = "variable-ore", mineable_properties = { minable = true, mining_time = 2,
    products = { { name = "variable-chunk", amount_min = 1, amount_max = 3 } } } },
  ["chance-ore"] = { name = "chance-ore", mineable_properties = { minable = true, mining_time = 3,
    products = { { name = "chance-chunk", amount = 2, probability = 0.5 } } } },
}, recipe = {
  gear = { name = "gear", ingredients = { { name = "iron-plate", amount = 2 } }, products = { { name = "gear", amount = 1 } }, energy = 0.5, category = "crafting" },
} }
body.force.recipes.gear = { enabled = true }

local spatial = require("scripts.spatial")
local accepted = spatial.can_place({ placements = {
  { item = "transport-belt", position = { x = 30, y = 0 } },
} })
check(accepted.results[1].can_place == true and accepted.results[1].reason == "placeable"
  and accepted.results[1].item == "transport-belt"
  and accepted.results[1].entity == "transport-belt"
  and accepted.results[1].position.x == 30 and accepted.results[1].direction == 0
  and checks == 2,
  "can_place returns authoritative placement identity and reason")

local beyond, beyond_error = pcall(spatial.can_place, {
  item = "transport-belt", position = { x = 30.000001, y = 0 },
})
check(not beyond and tostring(beyond_error):match("placements must be a non%-empty array") ~= nil and checks == 2,
  "can_place rejects the removed single-item fallback before querying the surface")

local empty, empty_error = pcall(spatial.can_place, { placements = {} })
check(not empty and tostring(empty_error):match("placements must be a non%-empty array") ~= nil
  and checks == 2,
  "can_place rejects an empty placements array before querying the surface")

local inherited, inherited_error = pcall(spatial.can_place, {
  item = "transport-belt",
  placements = { { position = { x = 0, y = 0 } } },
})
check(not inherited and tostring(inherited_error):match("placements%[1%]%.item must be an item name") ~= nil
  and checks == 2,
  "can_place rejects top-level item inheritance before querying the surface")

local too_many = {}
for i = 1, 25 do
  too_many[i] = { item = "transport-belt", position = { x = 0, y = 0 } }
end
local oversized, oversized_error = pcall(spatial.can_place, { placements = too_many })
check(not oversized and tostring(oversized_error):match("at most 24 placements") ~= nil
  and checks == 2,
  "can_place rejects more than 24 placements before querying the surface")

local batch = spatial.can_place({ placements = {
  { item = "transport-belt", position = { x = 0, y = 30.000001 } },
  { item = "transport-belt", position = { x = 0, y = 64.5 } },
} })
check(batch.results[1].can_place == true and checks == 4,
  "can_place checks a charted position however far it is from Codex")
check(batch.results[2].can_place == false and batch.results[2].reason:match("charted terrain") ~= nil and checks == 4,
  "can_place rejects an uncharted position without querying the surface")

local ten_names = {}
for index = 1, 10 do ten_names[index] = "unknown-" .. index end
local ten_ok, ten_result = pcall(spatial.describe_prototype, { names = ten_names })
check(ten_ok and ten_result["unknown-10"].kind == "unknown",
  "describe_prototype accepts the shared 10-name limit")
ten_names[11] = "unknown-11"
local eleven_ok, eleven_error = pcall(spatial.describe_prototype, { names = ten_names })
check(not eleven_ok and tostring(eleven_error):match("at most 10 names") ~= nil,
  "describe_prototype rejects 11 names in Lua")
local recipe = spatial.describe_prototype({ names = { "gear" }, kind = "recipe" })
local entity = spatial.describe_prototype({ names = { "gear" }, kind = "entity" })
local automatic = spatial.describe_prototype({ names = { "gear" }, kind = "auto" })
check(recipe["recipe:gear"].kind == "recipe" and recipe["recipe:gear"].ingredients["iron-plate"] == 2
  and entity["entity:gear"].kind == "entity" and automatic.gear.kind == "entity",
  "describe_prototype exposes recipe/entity and preserves auto resolution")
local fuels = spatial.describe_prototype({ names = { "wood", "solid-fuel", "rocket-fuel" }, kind = "item" })
local automatic_fuel = spatial.describe_prototype({ names = { "solid-fuel" }, kind = "auto" })
check(fuels["item:wood"].kind == "item" and fuels["item:wood"].fuel_value == 2000000
  and fuels["item:solid-fuel"].fuel_value == 12000000
  and fuels["item:rocket-fuel"].stack_size == 10 and automatic_fuel["solid-fuel"].kind == "item",
  "describe_prototype resolves genuine fuel items explicitly and through auto fallback")
local rates = spatial.describe_prototype({ names = { "burner-mining-drill", "coal" }, kind = "entity" })
check(rates["entity:burner-mining-drill"].mining_speed == 0.25
  and rates["entity:burner-mining-drill"].max_energy_usage == 2500
  and rates["entity:burner-mining-drill"].crafting_speed == 0.5
  and rates["entity:burner-mining-drill"].burner_effectivity == 0.8
  and rates["entity:burner-mining-drill"].fuel_inventory_size == 1
  and rates["entity:coal"].mining_time == 1
  and rates["entity:coal"].mining_products.coal == 1
  and rates["entity:coal"].fuel_value == 4000000,
  "prototype facts expose exact mining, energy, and fuel-budget inputs")
local uncertain_mining = spatial.describe_prototype({ names = { "variable-ore", "chance-ore" }, kind = "entity" })
check(uncertain_mining["entity:variable-ore"].mining_time == 2
  and uncertain_mining["entity:variable-ore"].mining_products == nil
  and uncertain_mining["entity:chance-ore"].mining_time == 3
  and uncertain_mining["entity:chance-ore"].mining_products == nil,
  "describe_entity omits variable and probabilistic mining quantities from exact product facts")

-- Asteroids and ammo: an asteroid's health and resistances; an ammo item's
-- category, damage per shot (through nested results), projectile and
-- modifiers.
prototypes.entity["small-metallic-asteroid"] = { name = "small-metallic-asteroid", type = "asteroid",
  get_max_health = function() return 100 end,
  resistances = { physical = { decrease = 0, percent = 0.1 }, explosion = { decrease = 2, percent = 0.5 } } }
prototypes.item["firearm-magazine"] = { name = "firearm-magazine", type = "ammo", stack_size = 200,
  ammo_category = { name = "bullet" },
  get_ammo_type = function() return { action = { { type = "direct", action_delivery = { { type = "instant",
    target_effects = { { type = "create-entity", entity_name = "explosion-hit" },
      { type = "damage", damage = { amount = 5, type = "physical" } } } } } } }, cooldown_modifier = 1 } end }
prototypes.item.rocket = { name = "rocket", type = "ammo", stack_size = 200, ammo_category = { name = "rocket" },
  get_ammo_type = function() return { action = { type = "direct", action_delivery = { type = "projectile", projectile = "rocket",
    target_effects = { type = "nested-result", action = { type = "area", action_delivery = { type = "instant",
      target_effects = { { type = "damage", damage = { amount = 20, type = "explosion" } } } } } } } }, range_modifier = 1.5 } end }
local space = spatial.describe_prototype({ names = { "small-metallic-asteroid", "firearm-magazine", "rocket" } })
local rock, magazine, rocket = space["small-metallic-asteroid"], space["firearm-magazine"], space.rocket
check(rock.kind == "entity" and rock.max_health == 100 and #rock.resistances == 2 and rock.resistances[1].type == "explosion"
  and rock.resistances[1].decrease == 2 and rock.resistances[2].percent == 0.1,
  "an asteroid gives its health and resistances by damage type")
check(magazine.kind == "item" and magazine.ammo.category == "bullet" and #magazine.ammo.damage == 1
  and magazine.ammo.damage[1].amount == 5 and magazine.ammo.damage[1].type == "physical" and magazine.ammo.cooldown_modifier == 1
  and magazine.ammo.projectiles == nil, "an ammo item gives its category and damage per shot")
check(rocket.ammo.projectiles[1] == "rocket" and rocket.ammo.damage[1].amount == 20 and rocket.ammo.damage[1].type == "explosion"
  and rocket.ammo.range_modifier == 1.5, "nested results and a fired projectile are followed")
check(spatial.describe_prototype({ names = { "coal" }, kind = "item" })["item:coal"].ammo == nil
  and rates["entity:burner-mining-drill"].max_health == nil, "other items and entities carry no ammo or asteroid facts")

os.exit(failures == 0 and 0 or 1)
