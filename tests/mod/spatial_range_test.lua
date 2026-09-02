local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local checks = 0
local surface = { can_place_entity = function() checks = checks + 1 return true end }
local body = { valid = true, position = { x = 0, y = 0 }, surface = surface, force = { recipes = {} } }
package.loaded["scripts.companion"] = {
  require_companion = function() return body end,
  get = function() return body end,
}
package.loaded["scripts.tasks"] = { active_summary = function() return nil end }
_G.defines = { build_check_type = { manual = 1 } }
_G.prototypes = { item = {
  ["transport-belt"] = { place_result = { name = "transport-belt", collision_box = {
    left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 },
  } } },
  gear = { place_result = { name = "gear-entity", collision_box = { left_top = { x = 0, y = 0 }, right_bottom = { x = 1, y = 1 } } } },
}, entity = {}, recipe = {
  gear = { name = "gear", ingredients = { { name = "iron-plate", amount = 2 } }, products = { { name = "gear", amount = 1 } }, energy = 0.5, category = "crafting" },
} }
body.force.recipes.gear = { enabled = true }

local spatial = require("scripts.spatial")
local accepted = spatial.can_place({ placements = {
  { item = "transport-belt", position = { x = 30, y = 0 } },
} })
check(accepted.results[1].can_place == true and checks == 1,
  "can_place placements accept the exact 30-tile boundary")

local beyond, beyond_error = pcall(spatial.can_place, {
  item = "transport-belt", position = { x = 30.000001, y = 0 },
})
check(not beyond and tostring(beyond_error):match("placements must be a non%-empty array") ~= nil and checks == 1,
  "can_place rejects the removed single-item fallback before querying the surface")

local empty, empty_error = pcall(spatial.can_place, { placements = {} })
check(not empty and tostring(empty_error):match("placements must be a non%-empty array") ~= nil
  and checks == 1,
  "can_place rejects an empty placements array before querying the surface")

local inherited, inherited_error = pcall(spatial.can_place, {
  item = "transport-belt",
  placements = { { position = { x = 0, y = 0 } } },
})
check(not inherited and tostring(inherited_error):match("placements%[1%]%.item must be an item name") ~= nil
  and checks == 1,
  "can_place rejects top-level item inheritance before querying the surface")

local too_many = {}
for i = 1, 25 do
  too_many[i] = { item = "transport-belt", position = { x = 0, y = 0 } }
end
local oversized, oversized_error = pcall(spatial.can_place, { placements = too_many })
check(not oversized and tostring(oversized_error):match("at most 24 placements") ~= nil
  and checks == 1,
  "can_place rejects more than 24 placements before querying the surface")

local batch = spatial.can_place({ placements = {
  { item = "transport-belt", position = { x = 0, y = 30.000001 } },
} })
check(batch.results[1].can_place == false and batch.results[1].reason:match("within 30 tiles") ~= nil and checks == 1,
  "batched can_place reports an over-range public placement as a physical rejection")

local ten_names = {}
for index = 1, 10 do ten_names[index] = "unknown-" .. index end
local ten_ok, ten_result = pcall(spatial.describe_prototype, { names = ten_names })
check(ten_ok and ten_result["unknown-10"].kind == "unknown",
  "describe_prototype accepts the shared 10-name limit")
ten_names[11] = "unknown-11"
local eleven_ok, eleven_error = pcall(spatial.describe_prototype, { names = ten_names })
check(not eleven_ok and tostring(eleven_error):match("at most 10 names") ~= nil,
  "describe_prototype rejects 11 names in Lua")
local disambiguated = spatial.describe_prototype({ names = { { name = "gear", kind = "recipe" }, { name = "gear", kind = "item" } } })
check(disambiguated["recipe:gear"].kind == "recipe" and disambiguated["recipe:gear"].ingredients["iron-plate"] == 2
  and disambiguated["item:gear"].kind == "entity", "describe_prototype disambiguates same-named recipe and item")

os.exit(failures == 0 and 0 or 1)
