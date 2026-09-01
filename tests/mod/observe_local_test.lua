local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local player_force, enemy_force, neutral_force = {}, {}, {}
local character
local entities = {}
local function entity(name, x, y, width, height)
  return { valid = true, name = name, type = "assembling-machine", force = player_force, position = { x = x, y = y }, selection_box = { left_top = { x = x - width / 2, y = y - height / 2 }, right_bottom = { x = x + width / 2, y = y + height / 2 } } }
end
local function resource(name, x, y, amount)
  return { valid = true, name = name, type = "resource", force = neutral_force, amount = amount, position = { x = x, y = y }, selection_box = { left_top = { x = x - 0.49, y = y - 0.49 }, right_bottom = { x = x + 0.49, y = y + 0.49 } } }
end
entities[1] = entity("z-machine", 3, 3, 1, 1)
entities[2] = entity("a-machine", 0, 0, 2, 2)
entities[3] = resource("iron-ore", 5, 0, 100)
entities[4] = resource("iron-ore", 6, 0, 200)
entities[5] = resource("iron-ore", 12, 0, 50)
entities[6] = resource("copper-ore", -5, 0, 75)
for i = 1, 258 do entities[#entities + 1] = entity("machine-" .. i, (i % 21) - 10, math.floor(i / 21) - 6, 1, 1) end
local surface = {
  get_tile = function() return { collides_with = function() return false end } end,
  find_entities_filtered = function() return entities end,
}
local inventory = { get_contents = function() return { { name = "iron-plate", count = 3 } } end }
character = { valid = true, name = "character", type = "character", force = player_force, surface = surface, position = { x = 0, y = 0 }, health = 250, reach_distance = 10, build_distance = 10, get_main_inventory = function() return inventory end }
entities[#entities + 1] = character
package.loaded["scripts.companion"] = { require_companion = function() return character end }
package.loaded["scripts.tasks"] = { active_summary = function() return nil end }
_G.game = { tick = 123, forces = { enemy = enemy_force } }
local observation = require("scripts.spatial").observe_local({ radius = 15 })
check(observation.tick == 123 and observation.radius == 15, "observation includes current tick and radius")
check(observation.character.inventory["iron-plate"] == 3, "observation includes character inventory")
check(observation.grid.rows[15]:sub(15, 16) == "aa" and observation.grid.rows[16]:sub(15, 16) == "a@", "full 2x2 footprint is painted beneath higher-priority Codex")
check(observation.grid.legend.a == "a-machine" and observation.grid.legend.b:match("machine") ~= nil, "building glyphs are assigned lexically")
check(#observation.entities == 256 and observation.omitted_entities == 9, "nearest 256 entity cap is explicit")
check(observation.grid.coordinate_rule:match("north%-to%-south") ~= nil, "coordinate rule is explicit")
check(observation.grid.legend.A == "copper-ore" and observation.grid.legend.B == "iron-ore", "resource glyphs are assigned lexically")
local iron_patches = {}
for _, patch in ipairs(observation.resource_patches) do if patch.name == "iron-ore" then iron_patches[#iron_patches + 1] = patch end end
table.sort(iron_patches, function(a, b) return a.entity_count > b.entity_count end)
check(#iron_patches == 2 and iron_patches[1].entity_count == 2 and iron_patches[1].total_amount == 300 and iron_patches[2].entity_count == 1 and iron_patches[2].total_amount == 50,
  "connected resource tiles become deterministic amount-bearing patches")
os.exit(failures == 0 and 0 or 1)
