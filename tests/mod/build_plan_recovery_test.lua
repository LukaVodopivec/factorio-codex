-- Offline tests for build_plan's bounded in-action recoveries: walking out of
-- a footprint the body stands in, and the outcome code that keeps the
-- dispatcher from rerunning a whole build.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.storage = {}
_G.game = { tick = 100 }
_G.defines = { build_check_type = { manual = 1, ghost_revive = 5 } }
_G.prototypes = { item = {
  ["stone-furnace"] = { stack_size = 50, place_result = { name = "stone-furnace", type = "furnace",
    collision_box = { left_top = { x = -0.9, y = -0.9 }, right_bottom = { x = 0.9, y = 0.9 } } } },
} }

local inventory = { ["stone-furnace"] = 2 }
local created = 0
local character = {
  valid = true, name = "character", position = { x = 10, y = 10 }, build_distance = 10,
  force = { recipes = {} }, crafting_queue_size = 0,
  get_item_count = function(name) return inventory[name] or 0 end,
  remove_item = function(args) inventory[args.name] = inventory[args.name] - args.count end,
}
character.surface = {
  find_non_colliding_position = function(_, position) return { x = position.x, y = position.y } end,
  create_entity = function(args) created = created + 1; return { valid = true, name = args.name, type = "furnace", position = args.position } end,
}
package.loaded["scripts.companion"] = { get = function() return character end, require_companion = function() return character end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end, ensure_entity = function() return "ok" end }
local walks = {}
package.loaded["scripts.actions.walk"] = {
  start = function(task) walks[#walks + 1] = task end,
  tick = function(task)
    if task.target.x == -99 then return { status = "failed", detail = "BODY_ENCLOSED: boxed in" } end
    character.position = { x = task.target.x, y = task.target.y }
    return { status = "done", detail = "arrived" }
  end,
}

local geometry = require("scripts.placement_geometry")
local overlap_until_moved = function(c, proto, position)
  if math.abs(c.position.x - position.x) < 2 and math.abs(c.position.y - position.y) < 2 then
    return false, "CODEX_BODY_OVERLAP"
  end
  return true, "placeable"
end
geometry.can_place = overlap_until_moved
local build_plan = require("scripts.actions.build_plan")

local plan = { id = 41, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(plan)
check(build_plan.tick(plan) == nil and walks[1] and walks[1].id == 41 and walks[1].arrival_mode == "exact" and created == 0,
  "a body standing in the footprint walks clear under the plan's id instead of failing")
local exit = walks[1].target
check(math.abs(exit.x - 10) >= 2.15 or math.abs(exit.y - 10) >= 2.15, "the exit spot lies clear of the furnace footprint")
local placed = build_plan.tick(plan)
check(placed and placed.status == "done" and created == 1, "after walking clear the step places")

-- Bounded per step: a body that is still in the way after three different
-- spots beside the footprint fails with a code and says so.
character.position = { x = 10, y = 10 }
geometry.can_place = function() return false, "CODEX_BODY_OVERLAP" end
local stuck = { id = 42, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(stuck)
local failed
for _ = 1, 10 do failed = build_plan.tick(stuck); if failed then break end end
check(failed and failed.status == "failed" and failed.detail:match("CODEX_BODY_OVERLAP")
  and failed.detail:match("still in it after walking to 3 spot%(s%) beside it")
  and failed.outcome.code == "BUILD_PLAN_STEP_FAILED" and failed.outcome.placed == 0 and #walks == 4,
  "an overlap that survives three exits fails with the build's own code, so the dispatcher does not rerun the build")
local spots = {}
for n = 2, 4 do
  for m = 2, n - 1 do
    if (walks[n].target.x - walks[m].target.x) ^ 2 + (walks[n].target.y - walks[m].target.y) ^ 2 < 1 then spots.repeated = true end
  end
end
check(not spots.repeated, "each retry walks to a different spot")

-- a dense layout fills the four spots two tiles beside the
-- footprint; a farther or corner spot still gets the body out.
geometry.can_place = overlap_until_moved
character.position = { x = 10, y = 10 }
inventory["stone-furnace"] = 5
character.surface.find_non_colliding_position = function(_, position)
  if (position.x - 10) ^ 2 + (position.y - 10) ^ 2 < 3.5 ^ 2 then return nil end
  return { x = position.x, y = position.y }
end
local dense = { id = 50, auto_supply = false, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(dense)
created = 0
local dense_result
for _ = 1, 10 do dense_result = build_plan.tick(dense); if dense_result then break end end
check(dense_result and dense_result.status == "done" and created == 1,
  "a body boxed in on its four near sides walks to a farther spot and places")

-- the first walk ends with the body still in the footprint; it
-- tries another spot instead of failing.
character.surface.find_non_colliding_position = function(_, position) return { x = position.x, y = position.y } end
character.position = { x = 10, y = 10 }
local walk_mock = package.loaded["scripts.actions.walk"]
local full_tick, short = walk_mock.tick, 1
walk_mock.tick = function(task)
  if short > 0 then
    short = short - 1
    character.position = { x = 10, y = 11 } -- stopped short, still overlapping
    return { status = "done", detail = "arrived" }
  end
  return full_tick(task)
end
local short_plan = { id = 51, auto_supply = false, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(short_plan)
created = 0
local before = #walks
local short_result
for _ = 1, 10 do short_result = build_plan.tick(short_plan); if short_result then break end end
check(short_result and short_result.status == "done" and created == 1 and #walks == before + 2,
  "a walk that leaves the body in the footprint is followed by a walk to another spot, then the step places")
walk_mock.tick = full_tick

geometry.can_place = overlap_until_moved
character.surface.find_non_colliding_position = function() return { x = -99, y = 10 } end
character.position = { x = 10, y = 10 }
local enclosed = { id = 43, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(enclosed)
build_plan.tick(enclosed)
local walk_failed = build_plan.tick(enclosed)
check(walk_failed and walk_failed.status == "failed" and walk_failed.detail:match("walking clear failed: BODY_ENCLOSED"),
  "a failed walk out of the footprint fails the step and names why")

-- A build that 0.20 started before an in-place upgrade (auto_craft,
-- _waiting_for_crafts; no auto_supply or _short) keeps running: a step whose
-- item the body lacks fails as that step, not with a Lua error.
geometry.can_place = function() return true, "placeable" end
character.surface.find_non_colliding_position = function(_, position) return { x = position.x, y = position.y } end
character.position = { x = 30, y = 30 }
inventory["stone-furnace"] = 0
local legacy = { id = 44, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } },
  auto_craft = false, _auto_crafted = {}, _waiting_for_crafts = true, stop_on_error = true,
  _index = 1, _placed = 0, _results = {}, _failures = {} }
local ok, legacy_result = pcall(build_plan.tick, legacy)
check(ok and legacy_result and legacy_result.status == "failed" and legacy_result.detail:match("don't have any stone%-furnace")
  and legacy._short ~= nil and legacy.auto_supply == false,
  "a build_plan started by 0.20 is upgraded in place and fails a missing item as a step, not a Lua error")

-- A step whose approach failed for where the body stood (BODY_ON_CONVEYOR,
-- START_COLLISION) is tried once more after the last step, if the body
-- stands elsewhere by then; other failures and stop_on_error plans are not
-- retried. A successful approach walks the body to the step.
local approach_mock = package.loaded["scripts.actions.approach"]
local attempts, refuse = {}, nil
approach_mock.ensure = function(_, _, position)
  local key = position.x .. ":" .. position.y
  attempts[key] = (attempts[key] or 0) + 1
  local answer = refuse(key, attempts[key])
  if answer == "ok" then character.position = { x = position.x, y = position.y } end
  return answer
end
local function three_step_plan(id, stop_on_error)
  attempts, created = {}, 0
  character.position = { x = -6, y = 0 }
  inventory["stone-furnace"] = 3
  local p = { id = id, auto_supply = false, stop_on_error = stop_on_error, steps = {
    { item = "stone-furnace", position = { x = 0, y = 0 } },
    { item = "stone-furnace", position = { x = 4, y = 0 } },
    { item = "stone-furnace", position = { x = 8, y = 0 } } } }
  build_plan.start(p)
  local result
  for _ = 1, 20 do
    result = build_plan.tick(p)
    if result then break end
  end
  return p, result
end
local on_belt = { status = "failed", detail = "couldn't get in range: BODY_ON_CONVEYOR: the body stands on transport-belt",
  outcome = { code = "BODY_ON_CONVEYOR" } }
refuse = function(key, n) if key == "0:0" and n == 1 then return on_belt end return "ok" end
local retried, retried_result = three_step_plan(45, false)
check(retried_result and retried_result.status == "done" and created == 3 and attempts["0:0"] == 2
  and retried._results[1].ok and #retried._failures == 0 and retried_result.detail:match("^placed 3/3"),
  "a BODY_ON_CONVEYOR step is retried once after the last step and placed")

refuse = function(key) if key == "4:0" then return on_belt end return "ok" end
local twice, twice_result = three_step_plan(46, false)
check(twice_result and twice_result.status == "done" and created == 2 and attempts["4:0"] == 2
  and #twice._failures == 1 and twice._failures[1].index == 2
  and twice._failures[1].why:match("BODY_ON_CONVEYOR.*retried once after the last step%)$"),
  "a step failing again on its retry is listed once, saying it was retried")

refuse = function(key) if key == "0:0" then return { status = "failed",
  detail = "couldn't get in range: PATH_NOT_FOUND", outcome = { code = "PATH_NOT_FOUND" } } end return "ok" end
local unreachable = three_step_plan(47, false)
check(attempts["0:0"] == 1 and #unreachable._failures == 1, "a failure unrelated to where the body stood is not retried")

refuse = function(key) if key == "8:0" then return on_belt end return "ok" end
local unmoved, unmoved_result = three_step_plan(49, false)
check(unmoved_result and attempts["8:0"] == 1 and #unmoved._failures == 1
  and not unmoved._failures[1].why:match("retried"),
  "a step that failed where the body still stands is not retried")

refuse = function(key) if key == "0:0" then return on_belt end return "ok" end
local _, stopped = three_step_plan(48, true)
check(stopped and stopped.status == "failed" and attempts["0:0"] == 1 and created == 0,
  "a stop_on_error plan stops at the failure instead of retrying it")
approach_mock.ensure = function() return "ok" end

-- enclosed by own entities at the first placement, the body steps
-- out once (move_entity's escape: take the named blocker up, walk out, put
-- it back), then places; the step's detail says what was moved and restored.
local supply = require("scripts.actions.supply")
local escapes, escape_result = {}, nil
supply.register_runner("move_entity", { start = function(task) escapes[#escapes + 1] = task end,
  tick = function() return escape_result end })
local enclosed_walk = { status = "failed",
  detail = "couldn't get in range: BODY_ENCLOSED: no path; enclosed by owned entities: mine owned fast-inserter at (187.5,-7.5) to open a route",
  outcome = { code = "BODY_ENCLOSED", diagnostics = { path = {
    suggested_recovery = { tool = "mine", target_kind = "owned", x = 187.5, y = -7.5, expected_name = "fast-inserter" } } } } }
local enclosed_calls = 0
local function enclosed_until(n)
  enclosed_calls = 0
  approach_mock.ensure = function()
    enclosed_calls = enclosed_calls + 1
    return enclosed_calls <= n and enclosed_walk or "ok"
  end
end
local function layout(id)
  created, character.position = 0, { x = 0, y = 0 }
  inventory["stone-furnace"] = 3
  local p = { id = id, auto_supply = false, steps = { { item = "stone-furnace", position = { x = 0, y = 0 } } } }
  build_plan.start(p)
  local result
  for _ = 1, 10 do result = build_plan.tick(p); if result then break end end
  return result
end
enclosed_until(1)
escape_result = { status = "done", detail = "stepped out through the fast-inserter at (187.5, -7.5): took it up and put it back",
  outcome = { code = "ESCAPED" } }
local escaped = layout(60)
local escape = escapes[1]
check(escape and escape.type == "move_entity" and escape.id == 60 and escape.from.x == 187.5 and escape.from.y == -7.5
  and escape.to.x == 187.5 and escape.through.x == 0 and escape.expected_name == "fast-inserter"
  and escape.reach == character.build_distance,
  "an enclosed approach starts one escape through the named own blocker toward the step")
check(escaped and escaped.status == "done" and created == 1
  and escaped.detail:match("step 1: stepped out through the fast%-inserter at %(187%.5, %-7%.5%): took it up and put it back"),
  "after stepping out the step places, and its detail names what was taken up and put back")

enclosed_until(1)
escape_result = { status = "failed", detail = "MOVE_PLACE_FAILED: the fast-inserter is in my inventory — something stands there" }
local unrestored = layout(61)
check(unrestored and unrestored.status == "failed" and created == 0
  and unrestored.detail:match("BODY_ENCLOSED and stepping out failed: MOVE_PLACE_FAILED: the fast%-inserter is in my inventory"),
  "an escape that cannot put the blocker back fails the step and says the entity is in the inventory")

enclosed_until(99)
escapes = {}
escape_result = { status = "done", detail = "stepped out through the fast-inserter at (187.5, -7.5): took it up and put it back" }
local still = layout(62)
check(still and still.status == "failed" and #escapes == 1 and still.detail:match("BODY_ENCLOSED: no path"),
  "an enclosure still there after one escape fails the step: one escape per step")
approach_mock.ensure = function() return "ok" end

os.exit(failures == 0 and 0 or 1)
