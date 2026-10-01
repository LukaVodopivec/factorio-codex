local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local inventory_count = 2
local body = { valid = true, position = { x = 0, y = 0 }, walking_state = {}, mining_state = {}, crafting_queue = {}, crafting_queue_size = 0 }
body.get_main_inventory = function() return { get_contents = function() return { { name = "iron-plate", count = inventory_count } } end } end
body.cancel_crafting = function(args) table.remove(body.crafting_queue, args.index); body.crafting_queue_size = #body.crafting_queue end
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
local starts = {}
local queued_place_output_target
local walk_arrival
local function runner(kind) return { start = function(task) starts[#starts + 1] = kind; if kind == "place" then queued_place_output_target = task.output_target end; if kind == "walk_to" then walk_arrival = { mode = task.arrival_mode, radius = task.arrival_radius } end end, tick = function(task) local fails = kind == "mine" and task.target and task.target.x == 1; if kind == "mine" and not fails then inventory_count = 5 end; return { status = fails and "failed" or "done", detail = fails and "physical failure" or kind .. " done" } end } end
local walk, mine, craft = runner("walk_to"), runner("mine"), runner("craft")
package.loaded["scripts.actions.walk"], package.loaded["scripts.actions.mine"], package.loaded["scripts.actions.pickup"], package.loaded["scripts.actions.craft"] = walk, mine, runner("pickup"), craft
package.loaded["scripts.actions.build"] = { place = runner("place"), rotate = runner("rotate"), set_recipe = runner("set_recipe") }
package.loaded["scripts.actions.transfer"] = { insert = runner("insert"), extract = runner("extract") }
package.loaded["scripts.actions.build_plan"] = runner("build_plan")
local inspected = 0
package.loaded["scripts.inspect"] = { inspect = function() inspected = inspected + 1; return { entities = { { inventories = { output = { ["iron-plate"] = inspected >= 2 and 1 or 0 } } } } } end }
_G.game, _G.defines = { tick = 0 }, { shooting = { not_shooting = 0 } }
_G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
local tasks = require("scripts.tasks")
tasks.set_observer(function(params) return { tick = game.tick, detail = params.detail, entities = {}, resource_patches = {}, character = { inventory = { ["iron-plate"] = 5 } } } end)
local old_count_ok = pcall(tasks.queue_plan, { steps = { { action = "craft_items", recipe = "gear", count = 1 } } })
local missing_crafts_ok = pcall(tasks.queue_plan, { steps = { { action = "craft_items", recipe = "gear" } } })
local fractional_crafts_ok = pcall(tasks.queue_plan, { steps = { { action = "craft_items", recipe = "gear", crafts = 1.5 } } })
check(not old_count_ok and not missing_crafts_ok and not fractional_crafts_ok,
  "direct queue_plan rejects old count and requires integer crafts from 1 to 100")
check(not pcall(tasks.queue_plan, { steps = { { action = "walk_to", x = 1, y = 2 } }, observation_detail = "brief" }),
  "direct queue_plan accepts only none, compact, or full terminal observation detail")
check(not pcall(tasks.queue_plan, { steps = { { action = "wait_for_research", technology = "x", timeout_seconds = 1.5 } } })
  and not pcall(tasks.queue_plan, { steps = { { action = "validate_factory_component", source_tick = 0,
    positions = {}, duration_seconds = 1 } } }),
  "parked research and factory validation steps enforce their bounded DTOs in Lua")
local first = tasks.queue_plan({ steps = { { action = "walk_to", x = 1, y = 2,
  arrival_mode = "within_radius", arrival_radius = 2 }, { action = "mine", x = 3, y = 4, count = 1 } }, observation_detail = "compact" })
local successor = tasks.queue_plan({ steps = { { action = "craft_items", recipe = "gear", crafts = 1, wait_for_completion = false } }, after_plan_id = first.plan_id })
check(first.plan_id == 1 and successor.plan_id == 2, "queue_plan returns IDs immediately in the flat FIFO")
for tick = 1, 5 do game.tick = tick; tasks.on_tick() end
local a, b = tasks.plan_status({ plan_id = 1 }), tasks.plan_status({ plan_id = 2 })
check(a.status == "completed" and a.completed_steps == 2, "Lua plan executes all steps contiguously")
check(walk_arrival.mode == "within_radius" and walk_arrival.radius == 2,
  "queued walk forwards its explicit arrival contract to the physical runner")
check(a.inventory_delta and a.inventory_delta["iron-plate"] == 3,
  "terminal plan exposes inventory delta independently of its observation")
check(a.execution.mode == "sequential_nontransactional" and a.execution.rollback == "none"
  and #a.execution.committed_steps == 2 and a.execution.committed_steps[1] == 1
  and a.execution.committed_steps[2] == 2 and a.execution.incomplete_step == nil,
  "terminal plan declares its committed sequential nontransactional effects")
check(b.status == "completed" and table.concat(starts, ",") == "walk_to,mine,craft", "successful predecessor releases successor without interleaving")
check(a.transitions[1].status == "queued" and a.transitions[2].status == "running"
  and a.transitions[3].status == "completed" and #a.transitions == 3
  and a.transitions[1].tick == 0 and a.transitions[2].tick == 1 and a.transitions[3].tick == 2
  and b.transitions[1].status == "queued" and b.transitions[2].status == "running"
  and b.transitions[3].status == "completed" and #b.transitions == 3
  and b.transitions[1].tick == 0 and b.transitions[2].tick == 3 and b.transitions[3].tick == 3
  and b.after_plan_id == first.plan_id,
  "terminal plan status retains exact game-tick queued-through-completed milestones even when first polled late")
local transition_count = #b.transitions
tasks.plan_status({ plan_id = 2 }); tasks.plan_status({ plan_id = 2 })
check(#tasks.plan_status({ plan_id = 2 }).transitions == transition_count,
  "plan polling does not fabricate lifecycle transitions")
local pickup_plan = tasks.queue_plan({ steps = { { action = "pickup_items", x = 4, y = 5, item = "iron-ore", count = 3 } } })
game.tick = 5.5; tasks.on_tick()
check(tasks.plan_status({ plan_id = pickup_plan.plan_id }).status == "completed" and starts[#starts] == "pickup",
  "queued plans route pickup_items through the same physical FIFO runner")
check(tasks.plan_status({ plan_id = pickup_plan.plan_id }).observation == nil
  and tasks.plan_status({ plan_id = pickup_plan.plan_id }).inventory_delta ~= nil,
  "terminal observation is opt-in while final inventory deltas remain present")
check(a.observation and a.observation.detail == "compact", "terminal plan includes selected observation")
local bad = tasks.queue_plan({ steps = { { action = "mine", x = 1, y = 1 } } })
local blocked = tasks.queue_plan({ steps = { { action = "walk_to", x = 9, y = 9 } }, after_plan_id = bad.plan_id, observation_detail = "compact" })
for tick = 6, 9 do game.tick = tick; tasks.on_tick() end
check(tasks.plan_status({ plan_id = bad.plan_id }).status == "failed", "plan failure is observable")
local blocked_status = tasks.plan_status({ plan_id = blocked.plan_id })
check(blocked_status.status == "cancelled"
  and blocked_status.after_plan_id == bad.plan_id
  and blocked_status.transitions[1].status == "queued"
  and blocked_status.transitions[2].status == "cancelled"
  and #blocked_status.transitions == 2
  and blocked_status.observation and blocked_status.observation.tick == blocked_status.transitions[2].tick,
  "failed predecessor preserves its exact ID and queued-to-cancelled successor milestones pre-side-effect")
local waiting = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1 } } })
game.tick = 10; tasks.on_tick(); game.tick = 39; tasks.on_tick(); game.tick = 40; tasks.on_tick()
check(tasks.plan_status({ plan_id = waiting.plan_id }).status == "completed" and inspected == 2, "tick-side wait_for_item uses structured inventory")
local interrupted = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 2 } } })
game.tick = 41; tasks.on_tick(); tasks.cancel({ plan_id = interrupted.plan_id })
local interrupted_status = tasks.plan_status({ plan_id = interrupted.plan_id })
check(interrupted_status.status == "cancelled" and interrupted_status.outcomes[1].status == "cancelled",
  "active plan cancellation records the interrupted step")
check(interrupted_status.transitions[1].status == "queued"
  and interrupted_status.transitions[2].status == "running"
  and interrupted_status.transitions[3].status == "waiting"
  and interrupted_status.transitions[4].status == "cancelled"
  and #interrupted_status.transitions == 4
  and interrupted_status.transitions[1].tick == 40
  and interrupted_status.transitions[2].tick == 41
  and interrupted_status.transitions[3].tick == 41
  and interrupted_status.transitions[4].tick == 41,
  "late cancellation status retains only the bounded queued, running, waiting, and final milestones")
inspected = 0
local parked = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 99 } } })
local useful = tasks.queue_plan({ steps = { { action = "walk_to", x = 7, y = 7 } } })
local dependent = tasks.queue_plan({ steps = { { action = "walk_to", x = 8, y = 8 } }, after_plan_id = parked.plan_id })
game.tick = 42; tasks.on_tick()
check(tasks.plan_status({ plan_id = parked.plan_id }).status == "waiting",
  "unsatisfied read-only wait parks at the tail of the same FIFO")
game.tick = 43; tasks.on_tick()
check(tasks.plan_status({ plan_id = useful.plan_id }).status == "completed"
  and tasks.plan_status({ plan_id = parked.plan_id }).status == "waiting"
  and tasks.plan_status({ plan_id = dependent.plan_id }).status == "queued",
  "parked read-only wait does not monopolize the physical body while useful work exists")
tasks.cancel({ plan_id = parked.plan_id })
game.tick = 44; tasks.on_tick()
check(tasks.plan_status({ plan_id = dependent.plan_id }).status == "cancelled",
  "dependent successor remains blocked and cancels when its parked predecessor is cancelled")

inspected, body.position = 0, { x = 100, y = 100 }
local remote = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1, timeout_seconds = 2 } } })
game.tick = 45; tasks.on_tick()
local remote_status = tasks.plan_status({ plan_id = remote.plan_id })
check(inspected == 0 and remote_status.status == "failed"
  and remote_status.outcomes[1].error:match("TARGET_OUT_OF_OBSERVATION_RANGE"),
  "out-of-range wait rejects immediately without hidden remote inspection")
check(remote_status.execution.incomplete_step.step == 1
  and remote_status.execution.incomplete_step.status == "failed"
  and remote_status.execution.incomplete_step.effects == "unknown",
  "failed physical step does not claim rollback or zero side effects")
body.position = { x = 0, y = 0 }
local output_plan = tasks.queue_plan({ steps = { { action = "place_entity", name = "burner-inserter", x = 1, y = 0, output_target = { x = 2, y = 0 } } } })
game.tick = 46; tasks.on_tick()
check(tasks.plan_status({ plan_id = output_plan.plan_id }).status == "completed"
  and queued_place_output_target.x == 2 and queued_place_output_target.y == 0,
  "queued placement carries the expected output identity into the physical task")

inspected = 0
local craft_predecessor = tasks.queue_plan({ steps = {
  { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1 },
} })
local craft_successor = tasks.queue_plan({ steps = {
  { action = "walk_to", x = 11, y = 11 },
}, after_plan_id = craft_predecessor.plan_id })
local standalone_craft = tasks.enqueue({ task = {
  type = "craft", recipe = "gear", count = 1, wait_for_completion = false,
} })
game.tick = 139; tasks.on_tick()
game.tick = 140; tasks.on_tick()
check(tasks.get({ task_id = standalone_craft.task_id }).status == "done"
  and tasks.plan_status({ plan_id = craft_predecessor.plan_id }).status == "waiting"
  and craft_successor.after_plan_id == craft_predecessor.plan_id
  and tasks.plan_status({ plan_id = craft_successor.plan_id }).status == "queued"
  and tasks.plan_status({ plan_id = craft_successor.plan_id }).after_plan_id == craft_predecessor.plan_id,
  "standalone legitimate craft preserves the exact successful predecessor ID on its queued successor")
game.tick = 169; tasks.on_tick()
game.tick = 170; tasks.on_tick()
check(tasks.plan_status({ plan_id = craft_predecessor.plan_id }).status == "completed"
  and tasks.plan_status({ plan_id = craft_successor.plan_id }).status == "completed"
  and tasks.plan_status({ plan_id = craft_successor.plan_id }).after_plan_id == craft_predecessor.plan_id,
  "queued successor still releases after its parked predecessor becomes satisfied")

tasks.set_observer(function() error("terminal observation unavailable") end)
local observation_failed = tasks.queue_plan({ steps = { { action = "walk_to", x = 12, y = 12 } }, observation_detail = "compact" })
game.tick = 171; tasks.on_tick()
local observation_failed_status = tasks.plan_status({ plan_id = observation_failed.plan_id })
check(observation_failed_status.status == "failed"
  and observation_failed_status.observation_error:match("terminal observation unavailable")
  and observation_failed_status.transitions[1].status == "queued"
  and observation_failed_status.transitions[2].status == "running"
  and observation_failed_status.transitions[3].status == "failed"
  and #observation_failed_status.transitions == 3
  and observation_failed_status.transitions[1].tick == 170
  and observation_failed_status.transitions[2].tick == 171
  and observation_failed_status.transitions[3].tick == 171,
  "terminal observation failure records one truthful failed milestone without a fabricated completed transition")

local unknown_ok, unknown_error = pcall(tasks.queue_plan, { steps = { { action = "walk_to", x = 1, y = 1 } }, after_plan_id = 9999 })
check(not unknown_ok and tostring(unknown_error):match("PREDECESSOR_UNKNOWN") ~= nil,
  "an unknown or pruned predecessor is refused at enqueue instead of silently cancelling the successor")

body.crafting_queue, body.crafting_queue_size = { { count = 3 } }, 1
check(tasks.cancel({ all = true }).cancelled == 0 and body.crafting_queue_size == 0, "stop cancels residual nonblocking crafting")
os.exit(failures == 0 and 0 or 1)
