local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local body = { valid = true, walking_state = {}, mining_state = {} }
package.loaded["scripts.companion"] = { DEFAULT = "Codex", set_context = function() end, context = function() return "AI" end, require_companion = function() return body end, get = function() return body end }
local runner = { start = function() end, tick = function() return nil end }
runner.place, runner.rotate, runner.set_recipe = runner, runner, runner
runner.insert, runner.extract, runner.deliver = runner, runner, runner
for _, name in ipairs({ "walk", "mine", "build", "craft", "transfer", "build_plan" }) do package.loaded["scripts.actions." .. name] = runner end
_G.storage = { tasks = { next_id = 1, records = {}, by_companion = {}, failed_chains = {} } }; _G.game = { tick = 1 }; _G.defines = { shooting = { not_shooting = 0 } }
local tasks = require("scripts.tasks")
local first = tasks.enqueue({ task = { type = "walk_to" } })
tasks.on_tick()
local second = tasks.enqueue({ task = { type = "mine" } })
local lane = storage.tasks.by_companion.Codex
check(first.task_id == 1 and second.task_id == 2 and lane.active.id == 1 and lane.queue[1].id == 2, "normal actions append without replacing active work")
check(storage.tasks.by_companion.AI == nil, "task routing remains fixed to Codex even when stale context says AI")
local stopped = tasks.cancel({ all = true })
check(stopped.cancelled == 2, "stop cancels active and queued work")
check(storage.tasks.records[1].status == "cancelled" and storage.tasks.records[2].status == "cancelled", "cancelled status remains observable")
os.exit(failures == 0 and 0 or 1)
