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
  crafting_queue = {},
  crafting_queue_size = 0,
  cancel_crafting = function(args)
    check(args.index == 1 and args.count == 4, "stop cancels the active Factorio crafting queue entry")
    table.remove(body.crafting_queue, args.index)
    body.crafting_queue_size = #body.crafting_queue
    cancelled_crafts = cancelled_crafts + 1
  end,
}
package.loaded["scripts.companion"] = { DEFAULT = "Codex", require_companion = function() return body end, get = function() return body end }
local runner = { start = function() end, tick = function() return nil end }
runner.place, runner.rotate, runner.set_recipe = runner, runner, runner
runner.insert, runner.extract = runner, runner
for _, name in ipairs({ "walk", "mine", "build", "transfer" }) do package.loaded["scripts.actions." .. name] = runner end
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
  _G.storage = { tasks = { next_id = 1, records = {}, lane = { queue = {}, active = nil }, failed_chains = {} } }
  local first = tasks.enqueue({ task = { type = task_type } })
  tasks.on_tick()
  local second = tasks.enqueue({ task = { type = "mine" } })
  local lane = storage.tasks.lane
  check(first.task_id == 1 and second.task_id == 2 and lane.active.id == 1 and lane.queue[1].id == 2,
    task_type .. " remains active while a later action queues")
  local stopped = tasks.cancel({ all = true })
  check(stopped.cancelled == 2, "stop cancels active " .. task_type .. " and queued action")
  check(storage.tasks.records[1].status == "cancelled" and storage.tasks.records[2].status == "cancelled",
    task_type .. " and queued action cancellation remains observable")
  check(body.crafting_queue_size == 0, "stop empties Factorio crafting begun by " .. task_type)
end

check_crafting_stop("craft")
check_crafting_stop("build_plan")
check(cancelled_crafts == 2, "both crafting task types invoke physical queue cancellation")
os.exit(failures == 0 and 0 or 1)
