-- Surface conditions (contract C10): before placing an entity, setting a
-- recipe or hand-crafting, the surface's properties are compared with the
-- prototype's surface_conditions, and a broken one fails SURFACE_CONDITION
-- {property, value, min, max} before anything is walked to, consumed or
-- built. Prototypes without conditions read nothing from the surface (each
-- prototype's conditions are read once per load).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.game, _G.storage = { tick = 1 }, {}
_G.defines = { inventory = { chest = 1 }, build_check_type = { manual = 0, ghost_revive = 1 } }
local proto_reads = 0
local function counted(t)
  return setmetatable({}, { __index = function(_, key)
    if key == "surface_conditions" then proto_reads = proto_reads + 1 end
    return t[key]
  end })
end
local PRESSURE_4000 = { { property = "pressure", min = 4000, max = 4000 } }
_G.prototypes = {
  entity = { ["big-mining-drill"] = counted({ name = "big-mining-drill", type = "mining-drill", surface_conditions = PRESSURE_4000 }),
    ["iron-chest"] = counted({ name = "iron-chest", type = "container" }) },
  recipe = { ["casting-iron"] = counted({ name = "casting-iron", surface_conditions = PRESSURE_4000 }),
    ["iron-gear-wheel"] = counted({ name = "iron-gear-wheel" }) },
  item = {},
}
prototypes.item["big-mining-drill"] = { name = "big-mining-drill", place_result = prototypes.entity["big-mining-drill"] }
prototypes.item["iron-chest"] = { name = "iron-chest", place_result = prototypes.entity["iron-chest"] }

local property_reads = 0
local function planet(pressure)
  return { name = "planet", get_property = function(name)
    property_reads = property_reads + 1
    return name == "pressure" and pressure or 0
  end }
end
local nauvis, vulcanus = planet(1000), planet(4000)
local placement_geometry = require("scripts.placement_geometry")

local refused = placement_geometry.condition_refusal(nauvis, "entity", "big-mining-drill")
check(refused and refused.code == "SURFACE_CONDITION" and refused.condition.property == "pressure"
  and refused.condition.value == 1000 and refused.condition.min == 4000
  and refused.reason == "SURFACE_CONDITION: big-mining-drill needs pressure = 4000; this surface has 1000",
  "an entity whose pressure condition the surface breaks is refused, naming property, value and range")
check(placement_geometry.condition_refusal(vulcanus, "entity", "big-mining-drill") == nil,
  "the same entity on a surface that meets its conditions is allowed")
property_reads = 0
check(placement_geometry.condition_refusal(nauvis, "entity", "iron-chest") == nil and property_reads == 0,
  "an entity without conditions reads nothing from the surface")
local before = proto_reads
for _ = 1, 5 do placement_geometry.condition_refusal(nauvis, "entity", "iron-chest") end
check(proto_reads == before, "a prototype's conditions are read once per load")
check(placement_geometry.condition_refusal(nauvis, "recipe", "casting-iron").reason:match("^SURFACE_CONDITION: casting%-iron")
  and placement_geometry.condition_refusal(nauvis, "recipe", "iron-gear-wheel") == nil,
  "recipes are checked by their own conditions")
check(placement_geometry.condition_refusal(nauvis, "entity", nil) == nil
  and placement_geometry.condition_refusal(nauvis, "entity", "no-such-entity") == nil,
  "an unknown or nameless prototype has no conditions to break")

-- The actions: placing, setting a recipe and hand-crafting refuse before
-- anything else happens.
local body = { valid = true, surface = nauvis, position = { x = 0, y = 0 }, reach_distance = 10,
  force = { recipes = { ["casting-iron"] = { name = "casting-iron", enabled = true, category = "crafting" },
    ["iron-gear-wheel"] = { name = "iron-gear-wheel", enabled = true, category = "crafting" } } },
  get_item_count = function() return 1 end }
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
package.loaded["scripts.actions.approach"] = { ensure = function() error("nothing walks") end }
local craft = require("scripts.actions.craft")
local ok_craft, craft_error = pcall(craft.start, { recipe = "casting-iron", count = 1 })
check(not ok_craft and tostring(craft_error):match("^SURFACE_CONDITION: casting%-iron needs pressure"),
  "hand-crafting a recipe the planet forbids fails SURFACE_CONDITION before anything is consumed")
check(pcall(craft.start, { recipe = "iron-gear-wheel", count = 1 }), "a recipe without conditions starts as before")

local build = require("scripts.actions.build")
local ok_place, place_error = pcall(build.place.start, { item = "big-mining-drill", position = { x = 5.5, y = 5.5 }, auto_supply = false })
check(not ok_place and tostring(place_error):match("^SURFACE_CONDITION: big%-mining%-drill"),
  "placing an entity the planet forbids fails SURFACE_CONDITION before any walk")

if failures > 0 then print(failures .. " SURFACE CONDITION TEST(S) FAILED"); os.exit(1) end
print("ALL SURFACE CONDITION TESTS PASSED")
