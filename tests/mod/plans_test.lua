local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local body = { valid = true, position = { x = 0, y = 0 }, walking_state = {}, mining_state = {}, crafting_queue = {}, crafting_queue_size = 0 }
body.cancel_crafting = function(args) table.remove(body.crafting_queue, args.index); body.crafting_queue_size = #body.crafting_queue end
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
local starts = {}
local function runner(kind) return { start = function() starts[#starts + 1] = kind end, tick = function(task) local fails = kind == "mine" and task.target and task.target.x == 1; return { status = fails and "failed" or "done", detail = fails and "physical failure" or kind .. " done" } end } end
local walk, mine, craft = runner("walk_to"), runner("mine"), runner("craft")
package.loaded["scripts.actions.walk"], package.loaded["scripts.actions.mine"], package.loaded["scripts.actions.craft"] = walk, mine, craft
package.loaded["scripts.actions.build"] = { place = runner("place"), rotate = runner("rotate"), set_recipe = runner("set_recipe") }
package.loaded["scripts.actions.transfer"] = { insert = runner("insert"), extract = runner("extract") }
package.loaded["scripts.actions.build_plan"] = runner("build_plan")
local inspected = 0
package.loaded["scripts.inspect"] = { inspect = function() inspected = inspected + 1; return { entities = { { inventories = { output = { ["iron-plate"] = inspected >= 2 and 1 or 0 } } } } } end }
_G.game, _G.defines = { tick = 0 }, { shooting = { not_shooting = 0 } }
_G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
local tasks = require("scripts.tasks")
tasks.set_observer(function(params) return { tick = game.tick, detail = params.detail, entities = {}, resource_patches = {}, character = { inventory = {} } } end)
local first = tasks.queue_plan({ steps = { { action = "walk_to", x = 1, y = 2 }, { action = "mine", x = 3, y = 4, count = 1 } }, observation_detail = "compact" })
local successor = tasks.queue_plan({ steps = { { action = "craft_items", recipe = "gear", count = 1, wait_for_completion = false } }, after_plan_id = first.plan_id })
check(first.plan_id == 1 and successor.plan_id == 2, "queue_plan returns IDs immediately in the flat FIFO")
for tick = 1, 5 do game.tick = tick; tasks.on_tick() end
local a, b = tasks.plan_status({ plan_id = 1 }), tasks.plan_status({ plan_id = 2 })
check(a.status == "completed" and a.completed_steps == 2, "Lua plan executes all steps contiguously")
check(b.status == "completed" and table.concat(starts, ",") == "walk_to,mine,craft", "successful predecessor releases successor without interleaving")
check(a.observation and a.observation.detail == "compact", "terminal plan includes selected observation")
local bad = tasks.queue_plan({ steps = { { action = "mine", x = 1, y = 1 } } })
local blocked = tasks.queue_plan({ steps = { { action = "walk_to", x = 9, y = 9 } }, after_plan_id = bad.plan_id })
for tick = 6, 9 do game.tick = tick; tasks.on_tick() end
check(tasks.plan_status({ plan_id = bad.plan_id }).status == "failed", "plan failure is observable")
check(tasks.plan_status({ plan_id = blocked.plan_id }).status == "cancelled", "failed predecessor cancels successor pre-side-effect")
local waiting = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1 } } })
game.tick = 10; tasks.on_tick(); game.tick = 11; tasks.on_tick()
check(tasks.plan_status({ plan_id = waiting.plan_id }).status == "completed" and inspected == 2, "tick-side wait_for_item uses structured inventory")
local interrupted = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 2 } } })
game.tick = 12; tasks.on_tick(); tasks.cancel({ plan_id = interrupted.plan_id })
local interrupted_status = tasks.plan_status({ plan_id = interrupted.plan_id })
check(interrupted_status.status == "cancelled" and interrupted_status.outcomes[1].status == "cancelled",
  "active plan cancellation records the interrupted step")
inspected = 0
local parked = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 99 } } })
local useful = tasks.queue_plan({ steps = { { action = "walk_to", x = 7, y = 7 } } })
game.tick = 13; tasks.on_tick()
check(tasks.plan_status({ plan_id = parked.plan_id }).status == "waiting",
  "unsatisfied read-only wait parks at the tail of the same FIFO")
game.tick = 14; tasks.on_tick()
check(tasks.plan_status({ plan_id = useful.plan_id }).status == "completed"
  and tasks.plan_status({ plan_id = parked.plan_id }).status == "waiting",
  "parked read-only wait does not monopolize the physical body while useful work exists")
tasks.cancel({ plan_id = parked.plan_id })
body.crafting_queue, body.crafting_queue_size = { { count = 3 } }, 1
check(tasks.cancel({ all = true }).cancelled == 0 and body.crafting_queue_size == 0, "stop cancels residual nonblocking crafting")
os.exit(failures == 0 and 0 or 1)
