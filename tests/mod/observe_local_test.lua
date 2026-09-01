local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local player_force, enemy_force = {}, {}
local character
local entities = {}
local function entity(name, x, y, width, height)
  return { valid = true, name = name, type = "assembling-machine", force = player_force, position = { x = x, y = y }, selection_box = { left_top = { x = x - width / 2, y = y - height / 2 }, right_bottom = { x = x + width / 2, y = y + height / 2 } } }
end
entities[1] = entity("z-machine", 3, 3, 1, 1)
entities[2] = entity("a-machine", 0, 0, 2, 2)
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
local observation = require("scripts.spatial").scan_area({ radius = 15 })
check(observation.tick == 123 and observation.radius == 15, "observation includes current tick and radius")
check(observation.character.inventory["iron-plate"] == 3, "observation includes character inventory")
check(observation.grid.rows[15]:sub(15, 16) == "aa" and observation.grid.rows[16]:sub(15, 16) == "a@", "full 2x2 footprint is painted beneath higher-priority Codex")
check(observation.grid.legend.a == "a-machine" and observation.grid.legend.b:match("machine") ~= nil, "building glyphs are assigned lexically")
check(#observation.entities == 256 and observation.omitted_entities == 5, "nearest 256 entity cap is explicit")
check(observation.grid.coordinate_rule:match("north%-to%-south") ~= nil, "coordinate rule is explicit")
os.exit(failures == 0 and 0 or 1)
