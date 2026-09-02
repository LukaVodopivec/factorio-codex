local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local output_count = 0
local output_inventory = { is_empty = function() return output_count == 0 end,
  get_contents = function() return output_count == 0 and {} or { { name = "iron-plate", count = output_count } } end }
local empty_inventory = { is_empty = function() return true end, get_contents = function() return {} end }
local entity = { valid = true, name = "stone-furnace", type = "furnace", direction = 0,
  position = { x = 2, y = 2 }, fluidbox = {},
  get_inventory = function(index) return index == 2 and output_inventory or empty_inventory end,
  get_recipe = function() return nil end, get_fluid_contents = function() return {} end }
local surface = { find_entities_filtered = function(filter)
  check(filter.position.x == 2 and filter.position.y == 2,
    "wait_for_item passes its exact position through real batch inspection")
  return { entity }
end }
local body = { valid = true, position = { x = 0, y = 0 }, surface = surface,
  walking_state = {}, mining_state = {}, crafting_queue = {} }
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
local function runner() return { start = function() end, tick = function() return { status = "done" } end } end
package.loaded["scripts.actions.walk"], package.loaded["scripts.actions.mine"], package.loaded["scripts.actions.craft"] = runner(), runner(), runner()
package.loaded["scripts.actions.build"] = { place = runner(), rotate = runner(), set_recipe = runner() }
package.loaded["scripts.actions.transfer"] = { insert = runner(), extract = runner() }
package.loaded["scripts.actions.build_plan"] = runner()
_G.defines = { inventory = { fuel = 1, furnace_result = 2 }, entity_status = {}, shooting = { not_shooting = 0 } }
_G.game = { tick = 0 }
_G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
-- Keep scripts.inspect real: exercise plan -> wait -> batch inspect -> inventory.
package.loaded["scripts.inspect"], package.loaded["scripts.tasks"] = nil, nil
local tasks = require("scripts.tasks")
local queued = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2,
  inventory = "output", item = "iron-plate", count = 2, timeout_seconds = 3 } } })
game.tick = 1; tasks.on_tick()
check(tasks.plan_status({ plan_id = queued.plan_id }).status == "waiting",
  "real wait path parks without occupying the body before the requested count exists")
output_count = 2; game.tick = 2; tasks.on_tick()
local terminal = tasks.plan_status({ plan_id = queued.plan_id })
check(terminal.status == "completed" and terminal.completed_steps == 1
  and terminal.outcomes[1].status == "completed"
  and terminal.outcomes[1].result:match("output has 2 iron%-plate") ~= nil,
  "real wait path preserves inventory item count and completes on a later tick")
os.exit(failures == 0 and 0 or 1)
