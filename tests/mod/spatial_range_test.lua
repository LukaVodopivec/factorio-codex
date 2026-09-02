local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local checks = 0
local surface = { can_place_entity = function() checks = checks + 1 return true end }
local body = { valid = true, position = { x = 0, y = 0 }, surface = surface, force = {} }
package.loaded["scripts.companion"] = { require_companion = function() return body end }
_G.defines = { build_check_type = { manual = 1 } }
_G.prototypes = { item = {
  ["transport-belt"] = { place_result = { name = "transport-belt", collision_box = {
    left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 },
  } } },
} }

local spatial = require("scripts.spatial")
local accepted = spatial.can_place({ item = "transport-belt", position = { x = 30, y = 0 } })
check(accepted.can_place == true and checks == 1, "can_place accepts the exact 30-tile boundary")

local beyond, beyond_error = pcall(spatial.can_place, {
  item = "transport-belt", position = { x = 30.000001, y = 0 },
})
check(not beyond and tostring(beyond_error):match("within 30 tiles") ~= nil and checks == 1,
  "can_place rejects a single position beyond 30 tiles before querying the surface")

local batch = spatial.can_place({ placements = {
  { item = "transport-belt", position = { x = 0, y = 30.000001 } },
} })
check(batch.results[1].can_place == false and batch.results[1].reason:match("within 30 tiles") ~= nil and checks == 1,
  "batched can_place reports an over-range public placement as a physical rejection")

os.exit(failures == 0 and 0 or 1)
