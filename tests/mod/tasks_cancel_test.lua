local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local cancelled_crafts = 0
local body
	body = {
  valid = true,
  walking_state = {},
	  mining_state = {},
	  picking_state = true,
  crafting_queue = {},
  crafting_queue_size = 0,
  cancel_crafting = function(args)
    check(args.index == 1 and args.count == 4, "stop cancels the active Factorio crafting queue entry")
    table.remove(body.crafting_queue, args.index)
    body.crafting_queue_size = #body.crafting_queue
    cancelled_crafts = cancelled_crafts + 1
  end,
}
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
local runner = { start = function() end, tick = function() return nil end }
runner.place, runner.rotate = runner, runner
runner.set_recipe_action = { runner = runner, make_task = function() return {} end }
runner.insert, runner.extract = runner, runner
runner.flush_action = { runner = runner, make_task = function() return {} end }
for _, name in ipairs({ "walk", "mine", "pickup", "build", "transfer" }) do package.loaded["scripts.actions." .. name] = runner end
local crafting_runner = {
  start = function()
    body.crafting_queue = { { count = 4 } }
    body.crafting_queue_size = 1
  end,
  tick = function() return nil end,
}
package.loaded["scripts.actions.craft"] = crafting_runner
package.loaded["scripts.actions.build_plan"] = crafting_runner
_G.game = { tick = 1 }; _G.defines = { shooting = { not_shooting = 0 } }
local tasks = require("scripts.tasks")

local function check_crafting_stop(task_type)
  _G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
  local first = tasks.enqueue({ task = { type = task_type } })
  tasks.on_tick()
  local second = tasks.enqueue({ task = { type = "mine" } })
  local task_state = storage.tasks
  check(first.task_id == 1 and second.task_id == 2 and task_state.active.id == 1 and task_state.queue[1].id == 2,
    task_type .. " remains active while a later action queues")
  local stopped = tasks.cancel({ origin = "stop/supervisor", all = true })
  check(stopped.cancelled == 2, "stop cancels active " .. task_type .. " and queued action")
  check(storage.tasks.records[1].status == "cancelled" and storage.tasks.records[2].status == "cancelled",
    task_type .. " and queued action cancellation remains observable")
  check(body.crafting_queue_size == 0, "stop empties Factorio crafting begun by " .. task_type)
end

check_crafting_stop("craft")
check_crafting_stop("build_plan")
check(cancelled_crafts == 2, "both crafting task types invoke physical queue cancellation")

_G.storage = { tasks = { next_id = 2, records = {}, queue = {}, active = { id = 1, type = "mine" } } }
body.mining_state = { mining = true, position = { x = 4, y = 5 } }
local stopped_mining = tasks.cancel({ origin = "stop/supervisor", task_id = 1 })
check(stopped_mining.cancelled == 1 and body.mining_state.mining == false,
  "cancelling the active mine stops LuaControl mining immediately")
check(storage.tasks.records[1].status == "cancelled", "mine cancellation remains observable")
check(body.picking_state == false, "cancelling active work clears LuaControl picking_state")

-- A direct build_plan cancelled mid step-out: its cancelled hook's note (the
-- escape's taken-up entity) is the record's outcome.
crafting_runner.cancelled = function() return { code = "ESCAPE_CANCELLED", in_inventory = true } end
for _, how in ipairs({ { task_id = 1 }, { all = true } }) do
  _G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
  tasks.enqueue({ task = { type = "build_plan" } })
  tasks.on_tick()
  how.origin = "stop/supervisor"
  tasks.cancel(how)
  local record = storage.tasks.records[1]
  check(record.status == "cancelled" and record.outcome and record.outcome.code == "ESCAPE_CANCELLED"
    and record.outcome.in_inventory, "a cancelled direct build_plan records its escape note (" .. (how.all and "stop" or "cancel") .. ")")
end
crafting_runner.cancelled = nil
os.exit(failures == 0 and 0 or 1)
