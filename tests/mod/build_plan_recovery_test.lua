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

-- Only once per step: a body that is still in the way fails with a code.
character.position = { x = 10, y = 10 }
geometry.can_place = function() return false, "CODEX_BODY_OVERLAP" end
local stuck = { id = 42, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(stuck)
build_plan.tick(stuck)
local failed = build_plan.tick(stuck)
check(failed and failed.status == "failed" and failed.detail:match("CODEX_BODY_OVERLAP")
  and failed.outcome.code == "BUILD_PLAN_STEP_FAILED" and failed.outcome.placed == 0 and #walks == 2,
  "a second overlap on the same step fails with the build's own code, so the dispatcher does not rerun the build")

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

os.exit(failures == 0 and 0 or 1)
