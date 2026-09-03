-- walk_to + reusable pathfinder walker. Other actions embed the walker via
-- M.begin/M.step (plain-data state, storage-safe). Pathfinder results arrive
-- through on_script_path_request_finished → M.on_path_finished (wired in
-- control.lua); storage.path_request belongs to the sole active task.
local companion = require("scripts.companion")

local M = {}

local WAYPOINT_RADIUS_SQ = 0.25 -- advance to the next waypoint within 0.5 tiles
local STUCK_CHECK_TICKS = 60
local STUCK_EPSILON_SQ = 0.01 -- moved less than 0.1 tiles in a check window = stuck
local PATH_WAIT_TICKS = 90
local RETRY_DELAY_TICKS = 30
local MAX_RETRIES = 3
local MAX_RECOVERIES = 1

-- tan(22.5 deg): boundary between cardinal and diagonal octants
local OCTANT_RATIO = 0.41421356

-- Map coordinates: +x east, +y south.
local function direction_toward(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local adx, ady = math.abs(dx), math.abs(dy)
  if adx < OCTANT_RATIO * ady then
    return dy >= 0 and defines.direction.south or defines.direction.north
  end
  if ady < OCTANT_RATIO * adx then
    return dx >= 0 and defines.direction.east or defines.direction.west
  end
  if dx >= 0 then
    return dy >= 0 and defines.direction.southeast or defines.direction.northeast
  end
  return dy >= 0 and defines.direction.southwest or defines.direction.northwest
end
M.direction_toward = direction_toward

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function request_path(state, c, task_id)
  local id = c.surface.request_path({
    bounding_box = { { -0.2, -0.2 }, { 0.2, 0.2 } },
    collision_mask = prototypes.entity["character"].collision_mask,
    start = c.position,
    goal = state.target,
    force = c.force,
    radius = math.max(state.arrive_within, 0.5),
    can_open_gates = true,
    entity_to_ignore = c,
    path_resolution_modifier = 0,
    pathfind_flags = { cache = false, prefer_straight_paths = true },
  })
  storage.path_request = { id = id, task_id = task_id }
  state.request_id = id
  state.request_tick = game.tick
  state.phase = "waiting"
  state.last_check_tick = nil
  state.last_pos = nil
end

local function stop(c)
  c.walking_state = { walking = false }
end

local function fail(c, code, detail)
  stop(c)
  return { failed = code .. ": " .. detail }
end

local function blocker_evidence(state, c, goal)
  local from = c.position
  local dx, dy = goal.x - from.x, goal.y - from.y
  local distance = math.sqrt(dx * dx + dy * dy)
  local scale = distance > 2.5 and 2.5 / distance or 1
  local to = { x = from.x + dx * scale, y = from.y + dy * scale }
  local entities = {}
  local area = {
    left_top = { x = math.min(from.x, to.x) - 0.5, y = math.min(from.y, to.y) - 0.5 },
    right_bottom = { x = math.max(from.x, to.x) + 0.5, y = math.max(from.y, to.y) + 0.5 },
  }
  local corners = {
    area.left_top,
    { x = area.right_bottom.x - 0.001, y = area.left_top.y },
    { x = area.left_top.x, y = area.right_bottom.y - 0.001 },
    { x = area.right_bottom.x - 0.001, y = area.right_bottom.y - 0.001 },
  }
  for _, corner in ipairs(corners) do
    if not c.force.is_chunk_charted(c.surface,
      { x = math.floor(corner.x / 32), y = math.floor(corner.y / 32) }) then
      return "collision segment unavailable because its bounded evidence area crosses uncharted terrain"
    end
  end
  local ok_entities, found = pcall(c.surface.find_entities_filtered, {
    area = area,
    collision_mask = prototypes.entity["character"].collision_mask,
  })
  if ok_entities and type(found) == "table" then
    for _, entity in ipairs(found) do
      if entity.valid and entity ~= c and entity.type ~= "resource" and entity.type ~= "item-entity" then
        entities[#entities + 1] = string.format("%s@(%.1f,%.1f)", entity.name,
          entity.position.x, entity.position.y)
      end
    end
  end
  table.sort(entities)
  while #entities > 8 do table.remove(entities) end

  local tiles, seen = {}, {}
  for index = 0, 5 do
    local x, y = from.x + (to.x - from.x) * index / 5, from.y + (to.y - from.y) * index / 5
    local ok_tile, tile = pcall(c.surface.get_tile, x, y)
    local collision_ok, collides = false, false
    if ok_tile and tile then collision_ok, collides = pcall(tile.collides_with, "player") end
    if collision_ok and collides then
      local tx, ty = math.floor(x), math.floor(y)
      local key = tx .. ":" .. ty
      if not seen[key] then
        seen[key] = true
        tiles[#tiles + 1] = string.format("%s@(%d,%d)", tile.name or "collision-tile", tx, ty)
      end
    end
  end
  local evidence = string.format("collision segment (%.1f,%.1f)->(%.1f,%.1f); blocker_candidates=%s; collision_tiles=%s",
    from.x, from.y, to.x, to.y, #entities > 0 and table.concat(entities, ",") or "none",
    #tiles > 0 and table.concat(tiles, ",") or "none")
  state.blocker_evidence = evidence
  return evidence
end

local function retry_or_fail(state, c, code, detail)
  state.retries = state.retries + 1
  if state.retries > MAX_RETRIES then
    return fail(c, code, detail .. string.format(" after %d native path attempts", state.retries))
  end
  state.phase = "retry_wait"
  state.retry_at = game.tick + RETRY_DELAY_TICKS
  stop(c)
  return nil
end

-- Pop the pathfinder result stashed on the sole active task, but only if it
-- answers this walker's request.
local function take_path_result(state, task_id)
  local task = storage.tasks.active
  if not task or task.id ~= task_id then return nil end
  local result = task._path_result
  if not result or result.id ~= state.request_id then return nil end
  task._path_result = nil
  return result
end

-- (Re)initialize a walker. `state` must be a plain table stored on the task;
-- all fields are plain data. The first step() issues the pathfinder request.
function M.begin(state, c, target, arrive_within)
  -- Walking tasks take over from driving: hop out first.
  pcall(function()
    if c.driving then c.driving = false end
  end)
  for k in pairs(state) do
    state[k] = nil
  end
  state.target = { x = target.x, y = target.y }
  state.arrive_within = math.max(tonumber(arrive_within) or 1.0, 0.1)
  state.phase = "request"
  state.retries = 0
  state.recoveries = 0
end

-- Advance the walker one tick. Returns nil while moving, "arrived" once within
-- arrive_within of the target, or {failed = "reason"} when it gives up.
function M.step(state, c, task_id)
  local pos = c.position

  if dist_sq(pos, state.target) <= state.arrive_within * state.arrive_within then
    stop(c)
    return "arrived"
  end

  if state.phase == "request" then
    request_path(state, c, task_id)
  end

  if state.phase == "waiting" then
    local result = take_path_result(state, task_id)
    if result then
      if result.try_again_later then
        local failed = retry_or_fail(state, c, "PATH_TRANSIENT",
          "Factorio's pathfinder remained temporarily unavailable")
        if failed then return failed end
      elseif not result.path or #result.path == 0 then
        local evidence = blocker_evidence(state, c, state.target)
        return fail(c, "PATH_NOT_FOUND", string.format(
          "Factorio found no character path to (%.1f, %.1f); %s", state.target.x, state.target.y, evidence))
      else
        state.path = result.path
        state.waypoint = 1
        state.phase = "following"
      end
    elseif game.tick - state.request_tick > PATH_WAIT_TICKS then
      local pending = storage.path_request
      if pending and pending.id == state.request_id then storage.path_request = nil end
      return fail(c, "PATH_TIMEOUT", string.format(
        "no native path result arrived within %d ticks", PATH_WAIT_TICKS))
    else
      stop(c)
      return nil
    end
  end

  if state.phase == "retry_wait" then
    if game.tick >= state.retry_at then
      request_path(state, c, task_id)
    end
    stop(c)
    return nil
  end

  -- Follow only waypoints returned by Factorio's native pathfinder.
  local goal
  if state.phase == "following" then
    local path = state.path
    while state.waypoint <= #path and dist_sq(pos, path[state.waypoint]) <= WAYPOINT_RADIUS_SQ do
      state.waypoint = state.waypoint + 1
    end
    if state.waypoint > #path then
      state.path = nil
      if state.recoveries >= MAX_RECOVERIES then
        return fail(c, "PATH_INCOMPLETE", string.format(
          "native path ended %.1f tiles short of the target", math.sqrt(dist_sq(pos, state.target))))
      end
      state.recoveries = state.recoveries + 1
      request_path(state, c, task_id)
      stop(c)
      return nil
    else
      goal = path[state.waypoint]
    end
  end

  if not state.last_check_tick then
    state.last_check_tick = game.tick
    state.last_pos = { x = pos.x, y = pos.y }
  elseif game.tick - state.last_check_tick >= STUCK_CHECK_TICKS then
    if dist_sq(pos, state.last_pos) < STUCK_EPSILON_SQ then
      if state.recoveries < MAX_RECOVERIES then
        state.recoveries = state.recoveries + 1
        state.path = nil
        request_path(state, c, task_id)
        stop(c)
        return nil
      end
      local evidence = blocker_evidence(state, c, goal or state.target)
      return fail(c, "PATH_STALLED", string.format(
          "got stuck at (%.1f, %.1f), still %.1f tiles from the target; %s",
          pos.x, pos.y, math.sqrt(dist_sq(pos, state.target)), evidence))
    end
    state.last_check_tick = game.tick
    state.last_pos = { x = pos.x, y = pos.y }
  end

  -- walking_state only lasts one tick, so it must be re-set every tick
  c.walking_state = { walking = true, direction = direction_toward(pos, goal) }
  return nil
end

-- Wired in control.lua to defines.events.on_script_path_request_finished.
function M.on_path_finished(event)
  local entry = storage.path_request
  if not entry or entry.id ~= event.id then return end
  storage.path_request = nil
  local task = storage.tasks.active
  if not task or task.id ~= entry.task_id then return end
  local waypoints
  if event.path then
    waypoints = {}
    for i, wp in ipairs(event.path) do
      waypoints[i] = { x = wp.position.x, y = wp.position.y }
    end
  end
  task._path_result = {
    id = event.id,
    path = waypoints,
    try_again_later = event.try_again_later or false,
  }
end

-- walk_to task runner
function M.start(task)
  local c = companion.require_companion()
  local t = task.target
  if type(t) ~= "table" or type(t.x) ~= "number" or type(t.y) ~= "number" then
    error("walk_to requires target = {x, y}")
  end
  task.arrive_within = tonumber(task.arrive_within) or 1.0
  task._walk = {}
  M.begin(task._walk, c, t, task.arrive_within)
end

function M.tick(task)
  local c = companion.get()
  if not c then
    return { status = "failed", detail = "the companion character is gone" }
  end
  local r = M.step(task._walk, c, task.id)
  if r == "arrived" then
    return { status = "done", detail = string.format("arrived at (%.1f, %.1f)", c.position.x, c.position.y) }
  elseif type(r) == "table" then
    return { status = "failed", detail = r.failed }
  end
  return nil
end

return M
