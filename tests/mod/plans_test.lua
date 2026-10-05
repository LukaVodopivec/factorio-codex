local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local inventory_count = 2
-- The body's surface for the tags (nil: no tags) is set by the surface tests.
local anchor_ref
local body = { valid = true, position = { x = 0, y = 0 }, walking_state = {}, mining_state = {}, crafting_queue = {}, crafting_queue_size = 0 }
body.get_main_inventory = function() return { get_contents = function() return { { name = "iron-plate", count = inventory_count } } end } end
body.cancel_crafting = function(args) table.remove(body.crafting_queue, args.index); body.crafting_queue_size = #body.crafting_queue end
package.loaded["scripts.companion"] = { require_companion = function() return body end,
  -- Any body state but absent (remote actions, reads, queue_plan); no surface tag.
  require_present = function() return { state = "on_surface", force = body.force, surface = body.surface } end,
  anchor = function() return anchor_ref and { surface_ref = anchor_ref, state = "on_surface" } or nil end,
  get = function() return body end }
local starts = {}
local queued_place_output_target
local walk_arrival
local function runner(kind) return { start = function(task) starts[#starts + 1] = kind; if kind == "place" then queued_place_output_target = task.output_target end; if kind == "walk_to" then walk_arrival = { mode = task.arrival_mode, radius = task.arrival_radius } end end, tick = function(task) local fails = kind == "mine" and task.target and task.target.x == 1; if kind == "mine" and not fails then inventory_count = 5 end; return { status = fails and "failed" or "done", detail = fails and "physical failure" or kind .. " done" } end } end
local walk, mine, craft = runner("walk_to"), runner("mine"), runner("craft")
package.loaded["scripts.actions.walk"], package.loaded["scripts.actions.mine"], package.loaded["scripts.actions.pickup"], package.loaded["scripts.actions.craft"] = walk, mine, runner("pickup"), craft
package.loaded["scripts.actions.build"] = { place = runner("place"), rotate = runner("rotate"),
  set_recipe_action = { runner = runner("set_recipe"), make_task = function() return {} end } }
package.loaded["scripts.actions.transfer"] = { insert = runner("insert"), extract = runner("extract"),
  flush_action = { runner = runner("flush_fluid"), make_task = function() return {} end } }
package.loaded["scripts.actions.build_plan"] = runner("build_plan")
local inspected = 0
package.loaded["scripts.inspect"] = { MAX_TARGETS = 64, inspect = function() inspected = inspected + 1; return { entities = { { inventories = { output = { ["iron-plate"] = inspected >= 2 and 1 or 0 } } } } } end }
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
check(not pcall(tasks.queue_plan, { steps = { { action = "wait_for_research", technology = "x", timeout_seconds = 1.5 } } }),
  "parked research steps enforce their bounded DTOs in Lua")
local removed_ok, removed_error = pcall(tasks.queue_plan, { steps = { { action = "validate_factory_component",
  source_tick = 0, positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
check(not removed_ok and tostring(removed_error):match("unknown plan action") ~= nil,
  "the removed validate_factory_component action is no longer accepted")
local role_ok, role_error = pcall(tasks.queue_plan, { steps = { { action = "extract_items", x = 1, y = 1,
  inventory = "furnace_source" } } })
check(not role_ok and tostring(role_error):match("inventory must be one of main, input, output") ~= nil
  and not pcall(tasks.queue_plan, { steps = { { action = "insert_items", x = 1, y = 1, items = { coal = 1 }, inventory = "cargo" } } }),
  "insert and extract inventory roles are checked at queue time")
check(not pcall(tasks.queue_plan, { steps = { { action = "configure_entity", x = 1, y = 1 } } })
  and not pcall(tasks.queue_plan, { steps = { { action = "place_tiles", item = "landfill" } } })
  and not pcall(tasks.queue_plan, { steps = { { action = "equip" } } })
  and not pcall(tasks.queue_plan, { steps = { { action = "set_requests", target = { x = 1, y = 1 }, requests = {} } } }),
  "the stage A actions are plan actions whose steps are validated at queue time")
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
game.tick = 41; tasks.on_tick(); tasks.cancel({ origin = "stop/supervisor", plan_id = interrupted.plan_id })
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
tasks.cancel({ origin = "stop/supervisor", plan_id = parked.plan_id })
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


-- 0.21: step limit, plan source, activity log.
tasks.set_observer(function(params) return { tick = game.tick } end)
local many = {}
for i = 1, 200 do many[i] = { action = "walk_to", x = i, y = 0 } end
local limit_ok = pcall(tasks.queue_plan, { steps = many })
many[201] = { action = "walk_to", x = 201, y = 0 }
local over_ok, over_error = pcall(tasks.queue_plan, { steps = many })
check(limit_ok and not over_ok and tostring(over_error):match("1%-200 steps") ~= nil,
  "a plan takes up to 200 steps")
tasks.cancel({ origin = "stop/supervisor", all = true })
check(not pcall(tasks.queue_plan, { steps = { { action = "walk_to", x = 1, y = 1 } }, source = "astra" })
  and not pcall(tasks.queue_plan, { steps = { { action = "walk_to", x = 1, y = 1 } }, source = "package:" }),
  "plan source is pilot, upkeep or package:<id>")
local from_package = tasks.queue_plan({ steps = { { action = "walk_to", x = 1, y = 1 } }, source = "package:iron-1" })
local again = tasks.queue_plan({ steps = { { action = "walk_to", x = 1, y = 1 } }, source = "package:iron-1" })
check(again.plan_id == from_package.plan_id and again.duplicate == true and #storage.tasks.queue + (storage.tasks.active and 1 or 0) == 1,
  "a package queued again (a retried call whose answer was lost) gets its existing plan, not a second one")
local from_pilot = tasks.queue_plan({ steps = { { action = "walk_to", x = 2, y = 2 } } })
game.tick = 172; tasks.on_tick(); game.tick = 173; tasks.on_tick()
local log = tasks.activity_log({ since_plan_id = from_package.plan_id - 1 })
check(tasks.plan_status({ plan_id = from_package.plan_id }).source == "package:iron-1"
  and log.entries[1].plan_id == from_package.plan_id and log.entries[1].source == "package:iron-1"
  and log.entries[1].status == "completed" and log.entries[1].steps == 1 and log.entries[1].end_tick == 172
  and log.entries[2].plan_id == from_pilot.plan_id and log.entries[2].source == "pilot",
  "activity_log keeps each plan outcome with its source")
check(tasks.queue_plan({ steps = { { action = "walk_to", x = 1, y = 1 } }, source = "package:iron-1" }).plan_id
  == from_package.plan_id, "a package that already ran is not queued again")
check(#tasks.activity_log({ limit = 1 }).entries == 1 and tasks.activity_log({ limit = 1 }).omitted > 0
  and not pcall(tasks.activity_log, { limit = 65 }),
  "activity_log is bounded by limit")
check(storage.tasks.last_plan_ended.plan_id == from_pilot.plan_id and storage.tasks.last_plan_ended.status == "completed",
  "the last plan to end is kept for event_state")
local from_upkeep = tasks.queue_plan({ steps = { { action = "walk_to", x = 3, y = 3 } }, source = "upkeep" })
game.tick = 174; tasks.on_tick(); game.tick = 175; tasks.on_tick()
local upkeep_log = tasks.activity_log({ since_plan_id = from_upkeep.plan_id - 1 })
check(upkeep_log.entries[1] and upkeep_log.entries[1].source == "upkeep"
  and storage.tasks.last_plan_ended.plan_id == from_pilot.plan_id,
  "an upkeep plan's end is logged but never wakes the pilot through event_state")
for i = 1, 70 do
  tasks.queue_plan({ steps = { { action = "walk_to", x = i, y = 3 } } })
  game.tick = 175 + i; tasks.on_tick()
end
check(#storage.activity_log == 64, "the activity log is a ring of 64 plan outcomes")

-- A step saved by 0.20 completes as a no-op.
game.tick = 300
storage.tasks.next_id = storage.tasks.next_id + 1
local legacy = { type = "plan", id = storage.tasks.next_id - 1, status = "waiting", current_step = 1, completed_steps = 0,
  outcomes = {}, steps = { { action = "validate_factory_component", source_tick = 1, positions = { { x = 0, y = 0 } },
  duration_seconds = 60 }, { action = "walk_to", x = 1, y = 1 } }, current_task = { type = "validate_factory_component" },
  started_tick = 290, next_check_tick = 299, observation_detail = "none" }
table.insert(storage.tasks.queue, legacy)
game.tick = 301; tasks.on_tick(); game.tick = 302; tasks.on_tick()
local legacy_status = tasks.plan_status({ plan_id = legacy.id })
check(legacy_status.status == "completed" and legacy_status.outcomes[1].result.code == "REMOVED_ACTION",
  "a persisted validate_factory_component step completes as REMOVED_ACTION")

-- Upkeep gives way to queued work at the next step boundary.
local upkeep = tasks.queue_plan({ steps = { { action = "walk_to", x = 1, y = 1 }, { action = "walk_to", x = 2, y = 2 } },
  source = "upkeep" })
game.tick = 303; tasks.on_tick()
local after_upkeep = tasks.queue_plan({ steps = { { action = "walk_to", x = 3, y = 3 } } })
game.tick = 304; tasks.on_tick(); game.tick = 305; tasks.on_tick()
local upkeep_status = tasks.plan_status({ plan_id = upkeep.plan_id })
check(upkeep_status.status == "cancelled" and upkeep_status.completed_steps == 1
  and tasks.plan_status({ plan_id = after_upkeep.plan_id }).status == "completed"
  and tasks.activity_log({ since_plan_id = upkeep.plan_id - 1 }).entries[1].code == "PREEMPTED",
  "an upkeep plan is preempted by queued work at a step boundary")

-- Deterministic recoveries.
local function scripted(results)
  local calls = 0
  return function(task)
    calls = calls + 1
    local result = results[math.min(calls, #results)]
    return type(result) == "function" and result(task) or result
  end
end
local insert_runner = package.loaded["scripts.actions.transfer"].insert
local inserted_items = {}
local original_insert_tick = insert_runner.tick
insert_runner.tick = scripted({
  function(task) inserted_items[#inserted_items + 1] = task.items; return { status = "partial", detail = "partial insert",
    outcome = { code = "PARTIAL_INSERT", transfers = { { item = "coal", requested = 5, inserted = 2, remainder = 3 } },
      target = { name = "stone-furnace", type = "furnace", position = { x = 1, y = 1 } } } } end,
  function(task) inserted_items[#inserted_items + 1] = task.items; return { status = "done", detail = "inserted" } end,
})
local refuel = tasks.queue_plan({ steps = { { action = "insert_items", x = 1, y = 1, items = { coal = 5 } } } })
for tick = 306, 370 do game.tick = tick; tasks.on_tick() end
local refuel_status = tasks.plan_status({ plan_id = refuel.plan_id })
check(refuel_status.status == "completed" and inserted_items[2].coal == 3
  and refuel_status.outcomes[1].recovery.code == "PARTIAL_INSERT" and refuel_status.outcomes[1].recovery.fix == "retry_remainder",
  "a partial insert retries its remainder once")
insert_runner.tick = original_insert_tick

local walk_tick, mine_tick = walk.tick, mine.tick
local mined
walk.tick = scripted({
  { status = "failed", detail = "BODY_ENCLOSED: boxed in", outcome = { code = "BODY_ENCLOSED", diagnostics = { path = {
    suggested_recovery = { tool = "mine", target_kind = "owned", x = 5.5, y = 0.5, expected_name = "wooden-chest" } } } } },
  { status = "done", detail = "arrived" },
})
mine.tick = function(task) mined = task; return { status = "done", detail = "mined" } end
local enclosed = tasks.queue_plan({ steps = { { action = "walk_to", x = 20, y = 0 } } })
for tick = 371, 374 do game.tick = tick; tasks.on_tick() end
local enclosed_status = tasks.plan_status({ plan_id = enclosed.plan_id })
check(enclosed_status.status == "completed" and mined and mined.target.x == 5.5 and mined.target_kind == "owned"
  and mined.count == 1 and enclosed_status.outcomes[1].recovery.fix == "mine",
  "an enclosed body mines the suggested owned blocker and walks again")
walk.tick = scripted({
  { status = "failed", detail = "BODY_ENCLOSED: boxed in", outcome = { code = "BODY_ENCLOSED", diagnostics = { path = {
    suggested_recovery = { x = 5.5, y = 0.5 } } } } },
})
mine.tick = function() return { status = "failed", detail = "refusing to recover a chest with contents" } end
local still_enclosed = tasks.queue_plan({ steps = { { action = "walk_to", x = 20, y = 0 } } })
for tick = 375, 380 do game.tick = tick; tasks.on_tick() end
local still_status = tasks.plan_status({ plan_id = still_enclosed.plan_id })
check(still_status.status == "failed" and still_status.outcomes[1].error:match("^BODY_ENCLOSED")
  and still_status.outcomes[1].recovery.fix_error:match("refusing"),
  "a failed recovery returns the original failure with the fix error")
walk.tick, mine.tick = walk_tick, mine_tick

local reach_calls = 0
mine.tick = function()
  reach_calls = reach_calls + 1
  if reach_calls == 1 then return { status = "failed", detail = "TARGET_OUT_OF_REACH: moved", outcome = { code = "TARGET_OUT_OF_REACH" } } end
  return { status = "done", detail = "mined" }
end
local reach = tasks.queue_plan({ steps = { { action = "mine", x = 7, y = 7, count = 1 } } })
for tick = 381, 384 do game.tick = tick; tasks.on_tick() end
check(tasks.plan_status({ plan_id = reach.plan_id }).status == "completed" and reach_calls == 2,
  "an out-of-reach step re-approaches once")
mine.tick = mine_tick

local place_runner = package.loaded["scripts.actions.build"].place
local place_tick = place_runner.tick
local walked_to
_G.prototypes = { item = { ["stone-furnace"] = { place_result = { collision_box = {
  left_top = { x = -1, y = -1 }, right_bottom = { x = 1, y = 1 } } } } } }
body.position = { x = 10, y = 10 }
body.surface = { find_non_colliding_position = function(_, position) return { x = position.x, y = position.y } end }
place_runner.tick = scripted({
  { status = "failed", detail = "can't place stone-furnace at (10.0, 10.0) — CODEX_BODY_OVERLAP — walk clear" },
  { status = "done", detail = "placed" },
})
local walk_start = walk.start
walk.start = function(task) walked_to = task.target end
local overlap = tasks.queue_plan({ steps = { { action = "place_entity", name = "stone-furnace", x = 10, y = 10 } } })
for tick = 385, 390 do game.tick = tick; tasks.on_tick() end
check(tasks.plan_status({ plan_id = overlap.plan_id }).status == "completed" and walked_to
  and (walked_to.y <= 10 - 1 - 1.25 or walked_to.y >= 10 + 1 + 1.25 or walked_to.x <= 10 - 1 - 1.25 or walked_to.x >= 10 + 1 + 1.25),
  "a body standing in the placement footprint walks clear and places again")
walk.start, place_runner.tick = walk_start, place_tick
body.position = { x = 0, y = 0 }
body.crafting_queue, body.crafting_queue_size = { { count = 3 } }, 1
check(tasks.cancel({ origin = "stop/supervisor", all = true }).cancelled == 0 and body.crafting_queue_size == 0, "stop cancels residual nonblocking crafting")

-- Cancel provenance: every cancel names its origin and is kept in
-- activity_log and the server log; a cancel without one is refused.
local logged = {}
_G.log = function(message) logged[#logged + 1] = message end
local walk_tick = walk.tick
walk.tick = function() return nil end
local victim = tasks.queue_plan({ steps = { { action = "walk_to", x = 5, y = 5 } } })
game.tick = 400; tasks.on_tick()
check(not pcall(tasks.cancel, { plan_id = victim.plan_id }) and storage.tasks.active.id == victim.plan_id,
  "a cancel without an origin is refused and cancels nothing")
check(tasks.cancel({ plan_id = victim.plan_id, origin = "cancel/pilot" }).cancelled == 1, "a cancel with an origin cancels")
local victim_status = tasks.plan_status({ plan_id = victim.plan_id })
local rows = tasks.activity_log({ since_plan_id = victim.plan_id - 1 }).entries
check(victim_status.status == "cancelled" and victim_status.outcomes[1].error == "CANCELLED by cancel/pilot"
  and rows[#rows].kind == "cancel" and rows[#rows].origin == "cancel/pilot" and rows[#rows].plan_id == victim.plan_id
  and rows[#rows].cancelled_count == 1 and rows[#rows].tick == 400 and rows[#rows - 1].plan_id == victim.plan_id
  and rows[#rows - 1].summary:match("CANCELLED by cancel/pilot")
  and logged[#logged]:match("cancel origin=cancel/pilot target=plan " .. victim.plan_id .. " cancelled=1 tick=400"),
  "the cancelled plan, activity_log and the server log all name who cancelled it")
tasks.queue_plan({ steps = { { action = "walk_to", x = 5, y = 5 } } })
game.tick = 401; tasks.on_tick()
check(tasks.cancel({ all = true, origin = "stop/supervisor" }).cancelled == 1 and storage.tasks.last_cancel_all_tick == 401,
  "a cancel-all records its tick for the bridge's package latch")
local stop_row = storage.activity_log[#storage.activity_log]
check(stop_row.kind == "cancel" and stop_row.all and stop_row.after_plan_id == storage.tasks.next_id - 1
  and stop_row.cancelled_count == 1 and logged[#logged]:match("target=all"),
  "a cancel-all is one activity_log row naming the newest plan at the time")
check(tasks.cancel({ plan_id = 9999, origin = "direct-task-timeout/pilot" }).cancelled == 0
  and storage.activity_log[#storage.activity_log].cancelled_count == 0,
  "even a cancel that finds nothing is logged")
require("scripts.state").init()
check(storage.tasks.last_cancel_all_tick == 401, "the last cancel-all survives a reload")
_G.log = nil

-- Surface tags (multi-surface rules 2-4). Each positional step carries the
-- surface its positions belong to: the queue_plan surface, else the
-- destination of the last travel pending in the FIFO, else the body's; a
-- travel step hands its destination to the steps after it. Remote steps,
-- crafting, reads and travel carry none.
anchor_ref = "nauvis"
game.planets = { nauvis = {}, vulcanus = {} }
local walk_start_fn = walk.start
local surface_starts = 0
walk.start = function() surface_starts = surface_starts + 1 end
local travel_runner = require("scripts.actions.travel").action.runner
local travel_tick, travel_start = travel_runner.tick, travel_runner.start
travel_runner.start, travel_runner.tick = function() end, function() return nil end
local function queued_plan(id)
  if storage.tasks.active and storage.tasks.active.id == id then return storage.tasks.active end
  for _, plan in ipairs(storage.tasks.queue) do if plan.id == id then return plan end end
end
local tagged = tasks.queue_plan({ steps = { { action = "walk_to", x = 5, y = 5 }, { action = "craft_items", recipe = "gear", crafts = 1 },
  { action = "create_platform", name = "alpha" }, { action = "travel", to = "vulcanus" }, { action = "mine", x = 2, y = 2, count = 1 } } })
local steps = queued_plan(tagged.plan_id).steps
check(steps[1]._surface == "nauvis" and steps[2]._surface == nil and steps[3]._surface == nil and steps[4]._surface == nil
  and steps[4]._to == "vulcanus" and steps[5]._surface == "vulcanus" and queued_plan(tagged.plan_id).surface == "nauvis"
  and tasks.plan_status({ plan_id = tagged.plan_id }).surface == "nauvis",
  "positional steps carry the body's surface, steps after a travel its destination; remote, crafting and travel none")
local behind = tasks.queue_plan({ steps = { { action = "walk_to", x = 1, y = 1 } } })
check(queued_plan(behind.plan_id).steps[1]._surface == "vulcanus", "a plan queued behind a pending travel is for its destination")
local named = tasks.queue_plan({ surface = "nauvis", steps = { { action = "walk_to", x = 1, y = 1 } } })
local bad_ok, bad = pcall(tasks.queue_plan, { surface = "mars", steps = { { action = "walk_to", x = 1, y = 1 } } })
check(queued_plan(named.plan_id).steps[1]._surface == "nauvis" and not bad_ok and tostring(bad):match("^SURFACE_UNKNOWN"),
  "queue_plan surface names the tag; an unknown surface is refused")
local remote_plan = tasks.queue_plan({ steps = { { action = "create_platform", name = "beta" } } })
check(queued_plan(remote_plan.plan_id).surface == nil and queued_plan(remote_plan.plan_id).steps[1]._surface == nil,
  "a remote-only plan carries no surface tag")
check(not pcall(tasks.queue_plan, { source = "package:p1", steps = { { action = "travel", to = "vulcanus" } } })
  and not pcall(tasks.queue_plan, { steps = { { action = "travel", to = "mars" } } })
  and not pcall(tasks.queue_plan, { steps = { { action = "travel", to = "vulcanus", max_wait_minutes = 241 } } }),
  "travel is the pilot's, to a known surface, waiting at most 240 minutes")
tasks.cancel({ all = true, origin = "test/plans" })

-- The one cancel rule. A: active on nauvis; B: nauvis; C: vulcanus, queued
-- before any travel; F: holds a travel to vulcanus; G: vulcanus, behind F;
-- D: remote. The body leaves for platform 1: A, B and C are cancelled with
-- SURFACE_LEFT and leave the FIFO; F is exempt (its own first step then
-- fails SURFACE_MISMATCH when it starts); G, behind F's travel, and D stay.
walk.tick = function() return nil end
body.crafting_queue, body.crafting_queue_size = { { count = 2 } }, 1
game.tick = 430
local A = tasks.queue_plan({ steps = { { action = "walk_to", x = 5, y = 5 } } })
tasks.on_tick()
local B = tasks.queue_plan({ steps = { { action = "walk_to", x = 6, y = 5 } } })
local C = tasks.queue_plan({ surface = "vulcanus", steps = { { action = "walk_to", x = 7, y = 5 } } })
local F = tasks.queue_plan({ steps = { { action = "walk_to", x = 1, y = 1 }, { action = "travel", to = "vulcanus" },
  { action = "walk_to", x = 2, y = 2 } } })
local G = tasks.queue_plan({ steps = { { action = "walk_to", x = 3, y = 3 } } })
local D = tasks.queue_plan({ steps = { { action = "create_platform", name = "gamma" } } })
check(storage.tasks.active.id == A.plan_id and #storage.tasks.queue == 5, "the FIFO holds one active and five queued plans")
anchor_ref = "platform:1"
tasks.on_body_surface_changed({ from = "nauvis", to = "platform:1", state = "aboard_platform" })
game.tick = 431; tasks.on_tick()
local function status_of(plan) return tasks.plan_status({ plan_id = plan.plan_id }) end
local a, c = status_of(A), status_of(C)
local left = a.outcomes[#a.outcomes]
local a_row
for _, row in ipairs(storage.activity_log) do if row.plan_id == A.plan_id then a_row = row end end
check(a.status == "cancelled" and left.result.code == "SURFACE_LEFT" and left.result.expected == "nauvis"
  and left.result.actual == "platform:1" and status_of(B).status == "cancelled" and c.status == "cancelled"
  and c.outcomes[1].result.code == "SURFACE_LEFT" and c.outcomes[1].result.expected == "vulcanus",
  "plans whose next positional step is for another surface are cancelled with SURFACE_LEFT")
check(a_row and a_row.code == "SURFACE_LEFT" and a_row.surface == "nauvis" and storage.tasks.last_plan_ended.surface ~= nil,
  "activity_log and the plan-ended event name the code and the plan's surface")
check(body.crafting_queue_size == 1, "a surface change never cancels hand-crafting")
local f = status_of(F)
check(f.status == "failed" and f.outcomes[1].result.code == "SURFACE_MISMATCH" and f.outcomes[1].result.expected == "nauvis"
  and f.outcomes[1].result.actual == "platform:1",
  "a plan holding a travel is exempt; a step that starts on the wrong surface fails SURFACE_MISMATCH")
check(status_of(G).status == "queued" and status_of(D).status == "queued" and #storage.tasks.queue == 2,
  "a plan behind a pending travel to its surface and a remote plan stay; cancelled plans leave queue_depth")
tasks.cancel({ all = true, origin = "test/plans" })
body.crafting_queue, body.crafting_queue_size = {}, 0

-- A plan an older version queued carries one tag for the plan: its
-- positional steps keep it.
storage.tasks.queue[1] = { type = "plan", id = 990, status = "queued", surface = "nauvis", current_step = 0,
  completed_steps = 0, outcomes = {}, source = "pilot", steps = { { action = "walk_to", x = 1, y = 1 } } }
game.tick = 432; tasks.on_tick()
local legacy = tasks.plan_status({ plan_id = 990 })
check(legacy.status == "failed" and legacy.outcomes[1].result.code == "SURFACE_MISMATCH",
  "a plan from 0.22.2 keeps its plan-wide tag on its positional steps")


-- A travel step keeps the FIFO while it waits; the step watchdog leaves a
-- deliberate wait alone; a cancel after its launch reports that the trip
-- finishes natively.
anchor_ref = "nauvis"
storage.travel = { arrivals = {} }
travel_runner.tick = function(task) task._phase = "board_wait"; return nil end
local trip = tasks.queue_plan({ steps = { { action = "travel", to = "vulcanus" }, { action = "walk_to", x = 1, y = 1 } } })
local after = tasks.queue_plan({ steps = { { action = "create_platform", name = "delta" } } })
for tick = 440, 440 + 4000, 20 do game.tick = tick; tasks.on_tick() end
check(storage.tasks.active and storage.tasks.active.id == trip.plan_id and status_of(after).status == "queued",
  "a waiting travel keeps the FIFO for over a minute without STEP_STALLED; plans behind it wait")
storage.tasks.active.current_task._launched = true
storage.travel.active = { task_id = trip.plan_id, to = "vulcanus", since_tick = game.tick }
tasks.cancel({ plan_id = trip.plan_id, origin = "stop/supervisor" })
local stopped = status_of(trip)
check(stopped.status == "cancelled" and stopped.outcomes[1].result.cancelled_after_launch == true
  and storage.travel.active.cancelled == true,
  "a cancel after the launch says the trip finishes natively")
tasks.cancel({ all = true, origin = "test/plans" })
travel_runner.tick, travel_runner.start = travel_tick, travel_start
walk.start, walk.tick = walk_start_fn, walk_tick
anchor_ref = nil

-- A 0.22.1 save upgraded in place: its running plan (one plan-wide tag, a
-- step under way) and the plan queued behind it go on while the body stands
-- on their surface.
anchor_ref = "nauvis"
storage.tasks.active = { type = "plan", id = 991, status = "running", surface = "nauvis", current_step = 1,
  completed_steps = 0, outcomes = {}, source = "pilot", started_tick = 4499, observation_detail = "none",
  final_observation_radius = 15, steps = { { action = "walk_to", x = 1, y = 1 }, { action = "mine", x = 3, y = 4, count = 1 } },
  current_task = { type = "walk_to", id = 991 } }
storage.tasks.queue[#storage.tasks.queue + 1] = { type = "plan", id = 992, status = "queued", surface = "nauvis",
  current_step = 0, completed_steps = 0, outcomes = {}, source = "pilot", observation_detail = "none",
  final_observation_radius = 15, steps = { { action = "walk_to", x = 2, y = 2 } } }
for tick = 4500, 4507 do game.tick = tick; tasks.on_tick() end
local resumed, behind = tasks.plan_status({ plan_id = 991 }), tasks.plan_status({ plan_id = 992 })
check(resumed.status == "completed" and resumed.completed_steps == 2 and behind.status == "completed",
  "a 0.22.1 plan under way and the one queued behind it finish on their own surface after the upgrade")
anchor_ref = nil

-- Step fields reach their runners: place_entity's insert map, insert_items'
-- targets (per_target or items), and the explore action.
local place_start = place_runner.start
local seen_place
place_runner.start = function(task) seen_place = task end
local insert_runner = package.loaded["scripts.actions.transfer"].insert
local insert_start = insert_runner.start
local seen_insert
insert_runner.start = function(task) seen_insert = task end
tasks.queue_plan({ steps = {
  { action = "place_entity", name = "stone-furnace", x = 1, y = 1, insert = { coal = 5 } },
  { action = "insert_items", targets = { { x = 1, y = 1 }, { x = 3, y = 1 } }, per_target = { coal = 2 } } } })
for tick = 420, 423 do game.tick = tick; tasks.on_tick() end
check(seen_place and seen_place.insert.coal == 5, "place_entity's insert map reaches the place runner")
check(seen_insert and #seen_insert.targets == 2 and seen_insert.items.coal == 2 and seen_insert.target == nil,
  "insert_items' targets and per_target counts reach the insert runner")
place_runner.start, insert_runner.start = place_start, insert_start
check(not pcall(tasks.queue_plan, { steps = { { action = "insert_items", targets = { { x = 1, y = 1 } },
  per_target = { coal = 1 }, items = { coal = 1 } } } }),
  "insert_items takes per_target or items, not both")
check(not pcall(tasks.queue_plan, { steps = { { action = "explore", max_distance = 5 } } })
  and pcall(tasks.queue_plan, { steps = { { action = "explore", max_distance = 200 } } }),
  "explore is a plan action with its own validation")
-- Blueprint and area actions are plan actions with their own validation.
check(pcall(tasks.queue_plan, { steps = {
  { action = "move_entity", from = { x = 1, y = 1 }, to = { x = 4, y = 1 } },
  { action = "blueprint_place", name = "gears", position = { x = 10, y = 10 }, direction = 4, mode = "hand" },
  { action = "build_ghosts", center = { x = 10, y = 10 }, radius = 8 },
  { action = "deconstruct_area", area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 8, y = 8 } }, mode = "robots" },
  { action = "upgrade_area", center = { x = 0, y = 0 }, radius = 4, from = "transport-belt", to = "fast-transport-belt" },
  { action = "copy_settings", from = { x = 1, y = 1 }, to = { { x = 5, y = 1 } } } } }),
  "move_entity, blueprint_place, build_ghosts, deconstruct_area, upgrade_area and copy_settings queue as plan steps")
check(not pcall(tasks.queue_plan, { steps = { { action = "move_entity", from = { x = 1, y = 1 } } } })
  and not pcall(tasks.queue_plan, { steps = { { action = "deconstruct_area", center = { x = 0, y = 0 }, radius = 2, mode = "fire" } } })
  and not pcall(tasks.queue_plan, { steps = { { action = "copy_settings", from = { x = 1, y = 1 }, to = {} } } }),
  "their steps are validated when queued")
tasks.cancel({ all = true, origin = "stop/supervisor" })
-- Rows that are not plan outcomes (a blueprint stored) name the newest plan,
-- so since_plan_id reads them like cancel rows.
local newest = storage.tasks.next_id - 1
tasks.log_event({ kind = "blueprint", action = "capture", name = "gears", tick = game.tick })
local rows = tasks.activity_log({ since_plan_id = newest - 1 }).entries
local later = tasks.activity_log({ since_plan_id = newest }).entries
check(rows[#rows].kind == "blueprint" and rows[#rows].after_plan_id == newest and later[#later].kind ~= "blueprint",
  "a blueprint row in activity_log carries the newest plan ID for since_plan_id")
tasks.cancel({ all = true, origin = "stop/supervisor" })
os.exit(failures == 0 and 0 or 1)
