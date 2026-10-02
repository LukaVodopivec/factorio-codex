local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

-- The caller coordinate is exactly within nominal reach, but the entity
-- selected by the retained radius-1.5 lookup is another 1.5 tiles away.
local walked_to, walk_goal, walk_result
local walk_stub = {
  begin = function(_, _, target, goal)
    walked_to = { x = target.x, y = target.y }
    walk_goal = goal
  end,
  step = function() return walk_result end,
}
package.loaded["scripts.actions.walk"] = walk_stub
local real_approach = require("scripts.actions.approach")
local reach_checks = 0
local body = {
  position = { x = 0, y = 0 },
  prototype = { collision_mask = { layers = { player = true } },
    collision_box = { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } } },
  force = {},
  surface = { find_entities_filtered = function() return {} end,
    get_tile = function() return { collides_with = function() return false end } end },
  reach_distance = 6,
  walking_state = {},
  can_reach_entity = function() reach_checks = reach_checks + 1 return false end,
}
local edge_entity = { valid = true, name = "wooden-chest", position = { x = 7.5, y = 0 } }
local edge_task = { id = 1 }
check(real_approach.ensure(edge_task, body, { x = 6, y = 0 }, body.reach_distance) == "ok",
  "caller coordinate alone is within nominal reach")
local reach_ok, reach_result = pcall(real_approach.ensure_entity, edge_task, body, edge_entity)
check(reach_ok and reach_result == nil and walked_to and walked_to.x == 7.5 and walk_goal < body.reach_distance,
  "selected entity 1.5 tiles farther away requires approach to its actual position")

local checks_before_arrival = reach_checks
walk_result = "arrived"
local arrived_result = real_approach.ensure_entity(edge_task, body, edge_entity)
check(arrived_result == nil and reach_checks == checks_before_arrival + 2 and edge_task._approach_close == true,
  "a completed approach that Factorio still rejects earns one closer approach")
walk_goal = nil
local close_result = real_approach.ensure_entity(edge_task, body, edge_entity)
check(type(close_result) == "table" and close_result.status == "failed" and walk_goal == 1
  and edge_task._approach_close == nil,
  "the closer approach targets the entity itself, then rechecks Factorio reach and fails closed")

local retry_task = { id = 2 }
local reachable_after_close = false
body.can_reach_entity = function() return reachable_after_close end
check(real_approach.ensure_entity(retry_task, body, edge_entity) == nil and retry_task._approach_close == true,
  "first post-approach reach miss schedules the closer approach")
reachable_after_close = true
check(real_approach.ensure_entity(retry_task, body, edge_entity) == "ok" and retry_task._approach_close == nil,
  "an offset path end recovers once the closer approach reaches the entity")

body.can_reach_entity = function() return true end
local authority_ok, authority_result = pcall(real_approach.ensure_entity, edge_task, body, edge_entity)
check(authority_ok and authority_result == "ok",
  "Factorio can_reach_entity is the authoritative mutation gate")

-- Prove every retained nearby-entity action preserves and completes the real
-- multi-tick walk to the resolved entity. The public coordinate is at reach
-- 6, while the entity selected around it is at 7.5.
local entity = {
  valid = true,
  name = "assembling-machine-1",
  type = "assembling-machine",
  position = { x = 7.5, y = 0 },
  direction = 0,
}
local mutations = { rotate = 0, recipe = 0, insert = 0, extract = 0 }
entity.rotate = function() mutations.rotate = mutations.rotate + 1 return true end
entity.set_recipe = function() mutations.recipe = mutations.recipe + 1 return {} end
entity.get_recipe = function() return { name = "iron-gear-wheel" } end
entity.insert = function(stack) mutations.insert = mutations.insert + 1 return stack.count end
entity.remove_item = function(stack) mutations.extract = mutations.extract + 1 return stack.count end
entity.get_output_inventory = function() return nil end
entity.get_inventory = function() return nil end

package.loaded["scripts.actions.approach"] = real_approach

body.valid = true
local action_reach_checks = 0
body.can_reach_entity = function(candidate)
  check(candidate == entity, "action reach gate checks the resolved entity")
  action_reach_checks = action_reach_checks + 1
  return math.abs(body.position.x - candidate.position.x) <= body.reach_distance - 0.5
end
body.surface = { find_entities_filtered = function(filter) return filter.limit and {} or { entity } end,
  get_tile = function() return { collides_with = function() return false end } end }
body.force = { recipes = { ["iron-gear-wheel"] = { enabled = true } } }
body.get_item_count = function() return 1 end
body.remove_item = function() return 1 end
body.insert = function(stack) return stack.count end
package.loaded["scripts.companion"] = {
  require_companion = function() return body end,
  get = function() return body end,
}
_G.defines = {
  direction = { north = 0, east = 4, south = 8, west = 12 },
  inventory = { chest = 1 },
}
_G.prototypes = { item = { coal = {} } }

local build = require("scripts.actions.build")
local transfer = require("scripts.actions.transfer")

local walk_begins, walk_steps, arrival_x
walk_stub.begin = function(_, _, target)
  walk_begins = walk_begins + 1
  check(target.x == entity.position.x and target.y == entity.position.y,
    "entity approach targets the resolved entity position")
end
walk_stub.step = function()
  walk_steps = walk_steps + 1
  if walk_steps == 2 then
    body.position = { x = arrival_x, y = 0 }
    return "arrived"
  end
  return nil
end

local function completes_after_real_approach(label, runner, task, mutation, entity_x, reached_x)
  entity.position = { x = entity_x, y = 0 }
  body.position = { x = 0, y = 0 }
  arrival_x = reached_x
  walk_begins, walk_steps = 0, 0
  local before = mutations[mutation]
  runner.start(task)
  local first = runner.tick(task)
  check(first == nil and task._approach and task._approach.target.x == entity_x
    and task._approach.reach == body.reach_distance - 0.5
    and walk_begins == 1 and mutations[mutation] == before,
    label .. " starts one real approach to the resolved entity")
  local second = runner.tick(task)
  check(second and second.status == "done" and walk_begins == 1
    and walk_steps == 2 and mutations[mutation] == before + 1,
    label .. " resumes that approach next tick and mutates only after arrival")
end

completes_after_real_approach("rotate", build.rotate,
  { id = 10, target = { x = 6, y = 0 } }, "rotate", 7.5, 2)
completes_after_real_approach("set_recipe", build.set_recipe,
  { id = 11, target = { x = 6, y = 0 }, recipe = "iron-gear-wheel" }, "recipe", 7.5, 2)
completes_after_real_approach("insert", transfer.insert,
  { id = 12, target = { x = 6, y = 0 }, items = { coal = 1 } }, "insert", 7.5, 2)
completes_after_real_approach("extract", transfer.extract,
  { id = 13, target = { x = 6, y = 0 }, items = { coal = 1 } }, "extract", 7.5, 2)

completes_after_real_approach("same-coordinate rotate", build.rotate,
  { id = 20, target = { x = 6, y = 0 } }, "rotate", 6, 0.5)
completes_after_real_approach("same-coordinate set_recipe", build.set_recipe,
  { id = 21, target = { x = 6, y = 0 }, recipe = "iron-gear-wheel" }, "recipe", 6, 0.5)
completes_after_real_approach("same-coordinate insert", transfer.insert,
  { id = 22, target = { x = 6, y = 0 }, items = { coal = 1 } }, "insert", 6, 0.5)
completes_after_real_approach("same-coordinate extract", transfer.extract,
  { id = 23, target = { x = 6, y = 0 }, items = { coal = 1 } }, "extract", 6, 0.5)
check(action_reach_checks == 24,
  "all four actions recheck Factorio reach across both multi-tick entity approach identities")

body.position, entity.position = { x = 6, y = 0 }, { x = 6, y = 0 }
body.get_item_count = function() return 1 end
entity.insert = function(stack) mutations.insert = mutations.insert + 1 return stack.count end
local partial_insert = { id = 30, target = { x = 6, y = 0 }, items = { coal = 2 } }
transfer.insert.start(partial_insert)
local partial_insert_result = transfer.insert.tick(partial_insert)
check(partial_insert_result and partial_insert_result.status == "partial"
  and partial_insert_result.detail:match("requested 2 coal, inserted 1, remainder 1")
  and partial_insert_result.outcome.total_inserted == 1
  and partial_insert_result.outcome.transfers[1].remainder == 1,
  "partial insert is an explicit bounded partial with requested, moved, and remainder counts")

os.exit(failures == 0 and 0 or 1)
