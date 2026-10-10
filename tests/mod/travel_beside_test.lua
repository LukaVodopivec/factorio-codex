-- Beside a travel wait (tasks.lua): a travel step that waits lends the FIFO
-- to queued build packages whose every step acts on a platform without the
-- body; physical packages, pilot plans and upkeep still wait behind it, and
-- the travel step takes the FIFO back. plan_status and active_task show the
-- travel step's facts. cancel_plan (cancel with only_source) cancels only a
-- pending plan of that source, through the runner's cancelled hook, and its
-- origin is logged. The travel runner is a stub the test steers.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local body = { valid = true, position = { x = 0, y = 0 }, walking_state = {}, mining_state = {}, crafting_queue = {},
  crafting_queue_size = 0, surface_index = 1 }
body.get_main_inventory = function() return { get_contents = function() return {} end } end
package.loaded["scripts.companion"] = { require_companion = function() return body end,
  require_present = function() return { state = "on_surface", force = body.force } end,
  anchor = function() return { surface_ref = "nauvis", state = "on_surface" } end,
  get = function() return body end }
local starts = {}
local function runner(kind) return { start = function() starts[#starts + 1] = kind end,
  tick = function() return { status = "done", detail = kind .. " done" } end } end
package.loaded["scripts.actions.walk"] = runner("walk_to")
-- The travel step: waits until arrived is set; cancelled names its phase.
local phase, arrived, cancels = "wait_arrival", false, 0
package.loaded["scripts.actions.travel"] = {
  action = {
    runner = { start = function() starts[#starts + 1] = "travel" end,
      tick = function() if arrived then return { status = "done", detail = "arrived", outcome = { code = "ARRIVED" } } end end,
      waiting = function() return phase == "wait_arrival" end,
      cancelled = function() cancels = cancels + 1; return { code = "CANCELLED", phase = phase } end },
    make_task = function(step) return { to = step.to, _to = step._to } end,
    validate = function(step) step._to = step.to end,
  },
  facts = function(task)
    if task and task.type == "travel" then return { phase = phase, to = task._to, deadline_tick = 900 } end
  end,
}
_G.game, _G.defines = { tick = 0, planets = { nauvis = {}, vulcanus = {} } }, { shooting = { not_shooting = 0 } }
_G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
local tasks = require("scripts.tasks")
-- A remote action (as set_platform_route): done in the tick it starts.
tasks.register_action("platform_step", { runner = runner("platform_step"), make_task = function() return {} end,
  remote = function(step) return step.platform ~= nil end })

local function run(n) for _ = 1, n do game.tick = game.tick + 1; tasks.on_tick() end end

local trip = tasks.queue_plan({ steps = { { action = "travel", to = "vulcanus" } } })
local dock = tasks.queue_plan({ steps = { { action = "platform_step", platform = "Dawn" },
  { action = "platform_step", platform = "Dawn" } }, source = "package:dock" })
local walk = tasks.queue_plan({ steps = { { action = "walk_to", x = 1, y = 1 } }, source = "package:ground", surface = "nauvis" })
local mixed = tasks.queue_plan({ steps = { { action = "platform_step", platform = "Dawn" }, { action = "walk_to", x = 2, y = 2 } },
  source = "package:mixed", surface = "nauvis" })
local mine = tasks.queue_plan({ steps = { { action = "platform_step", platform = "Dawn" } } })
run(1)
local summary = tasks.active_summary()
check(summary and summary.id == trip.plan_id and summary.travel and summary.travel.phase == "wait_arrival"
  and summary.travel.deadline_tick == 900, "active_task shows the running travel step's facts")
check(tasks.plan_status({ plan_id = trip.plan_id }).diagnostics.travel.to == "vulcanus",
  "plan_status diagnostics carry the travel step's facts")
run(4)
check(tasks.plan_status({ plan_id = dock.plan_id }).status == "completed"
  and tasks.plan_status({ plan_id = trip.plan_id }).status == "running",
  "a platform-only package runs beside the travel wait, which keeps running")
check(tasks.plan_status({ plan_id = walk.plan_id }).status == "queued" and tasks.plan_status({ plan_id = mixed.plan_id }).status == "queued"
  and tasks.plan_status({ plan_id = mine.plan_id }).status == "queued",
  "a physical or mixed package and a pilot plan still wait behind the travel step")
check(storage.tasks.active and storage.tasks.active.id == trip.plan_id and not storage.tasks.active.lent,
  "with no platform-only package left the travel step takes the FIFO back")
run(3)
check(storage.tasks.active.id == trip.plan_id and #storage.tasks.queue == 3, "nothing else runs beside the wait")

-- cancel_plan: only a pending plan of the named source.
local ok, err = pcall(tasks.cancel, { plan_id = walk.plan_id, only_source = "pilot", origin = "cancel_plan/pilot" })
check(not ok and tostring(err):match("^NOT_YOUR_PLAN:") and tasks.plan_status({ plan_id = walk.plan_id }).status == "queued",
  "cancel_plan refuses a package's plan and cancels nothing")
ok, err = pcall(tasks.cancel, { plan_id = dock.plan_id, only_source = "pilot", origin = "cancel_plan/pilot" })
check(not ok and tostring(err):match("^PLAN_NOT_PENDING: plan %d+ is already completed"), "cancel_plan refuses an ended plan")
ok, err = pcall(tasks.cancel, { plan_id = 99, only_source = "pilot", origin = "cancel_plan/pilot" })
check(not ok and tostring(err):match("^PLAN_NOT_PENDING: plan 99 is unknown"), "cancel_plan refuses an unknown plan")
local logged = 0
_G.log = function(line) if line:find("origin=cancel_plan/pilot", 1, true) then logged = logged + 1 end end
local done = tasks.cancel({ plan_id = trip.plan_id, only_source = "pilot", origin = "cancel_plan/pilot" })
local status = tasks.plan_status({ plan_id = trip.plan_id })
local row = storage.activity_log[#storage.activity_log]
check(done.cancelled == 1 and status.status == "cancelled" and cancels == 1 and status.outcomes[1].result.phase == "wait_arrival"
  and row.kind == "cancel" and row.origin == "cancel_plan/pilot" and row.plan_id == trip.plan_id and logged == 1,
  "cancel_plan cancels the pilot's own travel plan through its cancelled hook; the origin is logged")
run(4)
check(tasks.plan_status({ plan_id = walk.plan_id }).status == "completed" and tasks.plan_status({ plan_id = mine.plan_id }).status == "completed",
  "the plans behind it run once the travel step is gone")

-- A lent travel plan (a guest running) is still the pilot's to cancel.
phase = "wait_arrival"
trip = tasks.queue_plan({ steps = { { action = "travel", to = "vulcanus" } } })
local slow = { start = function() end, tick = function() return nil end }
tasks.register_action("slow_platform_step", { runner = slow, make_task = function() return {} end, remote = function() return true end })
dock = tasks.queue_plan({ steps = { { action = "slow_platform_step" } }, source = "package:slow" })
run(3)
check(storage.tasks.active.id == dock.plan_id and storage.tasks.queue[1].id == trip.plan_id and storage.tasks.queue[1].lent == "travel",
  "the travel plan lends the FIFO while a platform-only package runs")
summary = tasks.active_summary()
check(summary.id == dock.plan_id and summary.beside and summary.beside.plan_id == trip.plan_id
  and summary.beside.travel.phase == "wait_arrival", "active_task names the travel wait beside the running package")
done = tasks.cancel({ plan_id = trip.plan_id, only_source = "pilot", origin = "cancel_plan/pilot" })
check(done.cancelled == 1 and tasks.plan_status({ plan_id = trip.plan_id }).status == "cancelled" and cancels == 2
  and storage.tasks.active.id == dock.plan_id, "cancelling the lent travel plan leaves the package beside it running")

os.exit(failures == 0 and 0 or 1)
