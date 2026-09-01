local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local function ore(name, x)
  return { valid = true, name = name, type = "resource", position = { x = x, y = 0 }, selection_box = { left_top = { x = x - 0.49, y = -0.49 }, right_bottom = { x = x + 0.49, y = 0.49 } }, prototype = { mineable_properties = { minable = true, mining_time = 1, products = {} } } }
end
local exact, adjacent = ore("iron-ore", 0), ore("copper-ore", 1)
local body = { force = { manual_mining_speed_modifier = 0 }, surface = { find_entities_filtered = function(filter) check(filter.area ~= nil and filter.radius == nil, "mining queries an exact area without a nearby radius"); return { adjacent, exact } end } }
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end }
local mine = require("scripts.actions.mine")
local task = { target = { x = 0, y = 0 } }; mine.start(task)
check(task._entity_name == "iron-ore", "mining selects only the entity occupying the exact coordinate")
exact.valid = false
local vanished = mine.tick(task)
check(vanished and vanished.status == "failed" and vanished.detail:match("exact target was removed") ~= nil,
  "mining fails when the exact target vanishes instead of substituting adjacent ore")
check(adjacent.valid, "adjacent ore remains untouched after the exact target vanishes")
local ok = pcall(mine.start, { resource = "iron-ore", count = 10 })
check(not ok, "by-name resource discovery is rejected")
os.exit(failures == 0 and 0 or 1)
