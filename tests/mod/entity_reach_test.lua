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
package.loaded["scripts.actions.walk"] = {
  begin = function(_, _, target, goal)
    walked_to = { x = target.x, y = target.y }
    walk_goal = goal
  end,
  step = function() return walk_result end,
}
local real_approach = require("scripts.actions.approach")
local reach_checks = 0
local body = {
  position = { x = 0, y = 0 },
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
check(type(arrived_result) == "table" and arrived_result.status == "failed"
  and reach_checks == checks_before_arrival + 2,
  "completed approach rechecks Factorio reach and fails closed")

body.can_reach_entity = function() return true end
local authority_ok, authority_result = pcall(real_approach.ensure_entity, edge_task, body, edge_entity)
check(authority_ok and authority_result == "ok",
  "Factorio can_reach_entity is the authoritative mutation gate")

-- Prove every retained nearby-entity action waits on the shared gate before
-- invoking its mutating LuaEntity method.
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

local gate_calls = 0
package.loaded["scripts.actions.approach"] = {
  ensure = function() return "ok" end,
  find_entity_near = function() return entity end,
  ensure_entity = function()
    gate_calls = gate_calls + 1
    return nil
  end,
}

body.valid = true
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

local rotate = { target = { x = 6, y = 0 } }
build.rotate.start(rotate)
check(build.rotate.tick(rotate) == nil and mutations.rotate == 0,
  "rotate cannot use the nearby lookup as a 1.5-tile reach extension")

local recipe = { target = { x = 6, y = 0 }, recipe = "iron-gear-wheel" }
build.set_recipe.start(recipe)
check(build.set_recipe.tick(recipe) == nil and mutations.recipe == 0,
  "set_recipe waits for authoritative entity reach")

local insert = { target = { x = 6, y = 0 }, items = { coal = 1 } }
transfer.insert.start(insert)
check(transfer.insert.tick(insert) == nil and mutations.insert == 0,
  "insert waits for authoritative entity reach")

local extract = { target = { x = 6, y = 0 }, items = { coal = 1 } }
transfer.extract.start(extract)
check(transfer.extract.tick(extract) == nil and mutations.extract == 0,
  "extract waits for authoritative entity reach")
check(gate_calls == 4, "all four nearby-entity actions use the shared reach gate")

os.exit(failures == 0 and 0 or 1)
