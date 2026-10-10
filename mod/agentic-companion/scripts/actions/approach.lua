-- Shared "walk within reach first" phase for every action task with a map
-- target. Sub-state lives under task._approach.
local walk = require("scripts.actions.walk")
local set_walking = require("scripts.human_inputs").set_walking
local placement_geometry = require("scripts.placement_geometry")

local M = {}

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- The walk is stepping the body off a belt: searching, walking or routed.
local function settling(w)
  return w.phase == "settling" or w.phase == "settle_search"
end

local function failed(failure)
  return { status = "failed", detail = "couldn't get in range: " .. failure.failed, outcome = failure.outcome }
end

-- One approach is bounded. task._approach_guard = {escapes, cleared, retried}
-- outlives the walks of an approach (a caller whose target moves starts a new
-- walk): every walk draws on the same escape allowance (walk.lua), so a start
-- that keeps clearing and blocking again cannot restart the approach for
-- ever, and a walk that fails after an escape cleared the start is started
-- over once, with a fresh allowance, never more. A completed approach clears
-- the guard. Made when first needed (a step from an older save has none).
local function begin(task, c, target_pos, reach, settle_reach)
  local a = { target = { x = target_pos.x, y = target_pos.y }, reach = reach, walk = {} }
  walk.begin(a.walk, c, a.target, math.max(reach - 0.5, 0.5), "reach")
  a.walk.settle_anchor, a.walk.settle_limit = a.target, settle_reach or reach
  a.walk.escapes = task._approach_guard and task._approach_guard.escapes or nil
  task._approach = a
  return a
end

-- Call every tick before acting on target_pos. Returns "ok" once within
-- `reach` tiles, nil while still walking, or {status="failed", detail=...,
-- outcome={code=...}} as soon as the walk fails: every walk failure ends the
-- approach with the walk's own code. A body that ends on a belt steps off
-- to a tile within settle_reach of the target (default reach): an entity's
-- closer approach still settles anywhere within the body's real reach.
function M.ensure(task, c, target_pos, reach, settle_reach)
  local evidence = placement_geometry.path_start(c)
  local active = task._approach
  -- A failed blocked start survives step changes; proven clearance retires it.
  if active and active.walk.escape_failed and evidence.clear then
    task._approach, active = nil, nil
    set_walking(c, { walking = false })
  end
  if dist_sq(c.position, target_pos) <= reach * reach
    and evidence.clear then
    -- A belt carries a standing body, so "in reach" first means off the belt,
    -- with the off-belt tile still within reach of the target.
    if active and settling(active.walk) then
      local r = walk.step(active.walk, c, task.id)
      if r == "arrived" then
        task._approach, task._approach_guard = nil, nil
        return "ok"
      elseif type(r) == "table" then
        task._approach = nil
        return failed(r)
      end
      return nil
    end
    if placement_geometry.conveyor_under(c) then
      local a = { target = { x = target_pos.x, y = target_pos.y }, reach = reach, walk = {} }
      task._approach = a
      walk.begin(a.walk, c, a.target, math.max(reach - 0.5, 0.5), "reach")
      local failure = walk.begin_settle(a.walk, c, a.target, settle_reach or reach)
      if failure then
        task._approach = nil
        return failed(failure)
      end
      return nil
    end
    -- This target's own walk is complete. An escape that cleared the start
    -- is over whatever it was heading for; any other walk toward another
    -- point (the exact entity, see ensure_entity) is left to its own call.
    if active and active.target.x == target_pos.x and active.target.y == target_pos.y
      and active.reach == reach then
      task._approach, task._approach_guard = nil, nil
      set_walking(c, { walking = false })
    elseif active and active.walk.phase == "escaping" then
      if task._approach_guard then task._approach_guard.cleared = true end
      task._approach = nil
      set_walking(c, { walking = false })
    end
    return "ok"
  end

  local a = task._approach
  local moved = a and (a.target.x ~= target_pos.x or a.target.y ~= target_pos.y or a.reach ~= reach)
  -- Recovery belongs to the physical start, even when a plan advances
  -- targets: an escape still under way is never restarted for a new target.
  if not a or (moved and not a.walk.escape_failed and (a.walk.phase ~= "escaping" or evidence.clear)) then
    a = begin(task, c, target_pos, reach, settle_reach)
  end

  local r = walk.step(a.walk, c, task.id)
  if r == "arrived" then
    task._approach, task._approach_guard = nil, nil
    return "ok"
  end
  local guard = task._approach_guard
  if a.walk.escapes and not guard then
    guard = {}
    task._approach_guard = guard
  end
  if guard then
    guard.escapes = a.walk.escapes
    -- Past its escape: the start cleared (the walk is no longer escaping).
    if a.walk.escape_cleared_tick or (a.walk.escapes and a.walk.phase ~= "escaping" and not a.walk.escape_failed) then
      guard.cleared = true
    end
  end
  if type(r) == "table" then
    if guard and guard.cleared and not guard.retried then
      -- The escape worked and the walk from the new spot failed: once more
      -- from scratch.
      task._approach_guard = { retried = true }
      task._approach = nil
      return nil
    end
    if a.walk.phase ~= "escaping" and not a.walk.escape_failed then task._approach = nil end
    return failed(r)
  end
  return nil
end

-- Nearest operable entity around a target position (for insert/extract/
-- rotate/set_recipe). Skips the companion itself and things those actions
-- never apply to. A ready rocket and its cargo pod sit at the centre of
-- their silo, which owns the rocket's inventory: inspect skips those too.
M.ROCKET_TYPES = { ["rocket-silo-rocket"] = true, ["rocket-silo-rocket-shadow"] = true, ["cargo-pod"] = true }
local SKIP_TYPES = { character = true, resource = true, tree = true, ["item-entity"] = true }
for kind in pairs(M.ROCKET_TYPES) do SKIP_TYPES[kind] = true end

function M.find_entity_near(c, pos, radius)
  local candidates = c.surface.find_entities_filtered({ position = pos, radius = radius or 1.5 })
  local best, best_d
  for _, e in ipairs(candidates) do
    if e.valid and e ~= c and not SKIP_TYPES[e.type] then
      local d = dist_sq(e.position, pos)
      if not best or d < best_d then
        best, best_d = e, d
      end
    end
  end
  return best
end

-- Factorio owns the final reach decision for entity mutations. A caller
-- coordinate can be within reach while the entity selected around it is not.
-- Walk toward that exact entity with a small margin, then ask Factorio again.
function M.ensure_entity(task, c, e)
  if not e.valid then
    return { status = "failed", detail = "the selected entity is gone" }
  end
  if c.can_reach_entity(e) and placement_geometry.path_start(c).clear
    and not (task._approach and settling(task._approach.walk))
    and not placement_geometry.conveyor_under(c) then
    if task._approach then
      task._approach = nil
      set_walking(c, { walking = false })
    end
    task._approach_close, task._approach_guard = nil, nil
    return "ok"
  end

  -- A path can end offset from the entity (obstacles such as trees block the
  -- goal tile), so one failed reach check earns one closer approach before
  -- the task fails closed.
  -- Either way a belt under the body is left for a tile within the body's
  -- real reach of the entity, never only within the closer radius.
  local radius = task._approach_close and 1.5 or math.max(c.reach_distance - 0.5, 0.5)
  local reached = M.ensure(task, c, e.position, radius, math.max(radius, tonumber(c.reach_distance) or radius))
  if reached ~= "ok" then return reached end
  if not e.valid then
    return { status = "failed", detail = "the selected entity is gone" }
  end
  if not c.can_reach_entity(e) then
    if not task._approach_close then
      task._approach_close = true
      return nil
    end
    task._approach_close = nil
    return { status = "failed", detail = "couldn't get within physical reach of the " .. e.name }
  end
  task._approach_close = nil
  return "ok"
end

return M
