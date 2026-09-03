-- walk_to + reusable pathfinder walker. Other actions embed the walker via
-- M.begin/M.step (plain-data state, storage-safe). Pathfinder results arrive
-- through on_script_path_request_finished → M.on_path_finished (wired in
-- control.lua); storage.path_request belongs to the sole active task.
local companion = require("scripts.companion")
local placement_geometry = require("scripts.placement_geometry")

local M = {}

local WAYPOINT_RADIUS_SQ = 0.25 -- advance to the next waypoint within 0.5 tiles
local STUCK_CHECK_TICKS = 60
local STUCK_EPSILON_SQ = 0.01 -- moved less than 0.1 tiles in a check window = stuck
local PATH_WAIT_TICKS = 90
local RETRY_DELAY_TICKS = 30
local MAX_RETRIES = 3
local MAX_RECOVERIES = 1
local MAX_FRONTIER_SEGMENTS = 3
local MIN_FRONTIER_PROGRESS_SQ = 0.01
local ESCAPE_TICKS = 90

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

local function request_path(state, c, task_id, target, phase)
  target = target or state.target
  local id = c.surface.request_path({
    bounding_box = { { -0.2, -0.2 }, { 0.2, 0.2 } },
    collision_mask = prototypes.entity["character"].collision_mask,
    start = c.position,
    goal = target,
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
  state.phase = phase or "waiting"
  state.last_check_tick = nil
  state.last_pos = nil
end

local function stop(c)
  c.walking_state = { walking = false }
end

local function fail(c, code, detail, outcome)
  stop(c)
  return { failed = code .. ": " .. detail, outcome = outcome }
end

local function collision_labels(collisions)
  local labels = {}
  for _, collision in ipairs(collisions) do
    labels[#labels + 1] = string.format("%s:%s@(%.1f,%.1f)", collision.kind, collision.name,
      collision.position.x, collision.position.y)
  end
  return #labels > 0 and table.concat(labels, ",") or "none"
end

local function begin_escape(state, c)
  local collisions = placement_geometry.start_collisions(c)
  if #collisions == 0 then return false end
  local ok, target = pcall(c.surface.find_non_colliding_position,
    c.name or "character", c.position, 1.5, 0.1, false)
  if not ok or not target then
    return fail(c, "START_COLLISION", "character path body overlaps " .. collision_labels(collisions)
      .. "; Factorio found no clear position within 1.5 tiles")
  end
  state.phase = "escaping"
  state.escape_target = { x = target.x, y = target.y }
  state.escape_started_tick = game.tick
  state.escape_started_position = { x = c.position.x, y = c.position.y }
  state.start_collisions = collision_labels(collisions)
  return true
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
        entities[#entities + 1] = {
          name = entity.name, type = entity.type,
          x = entity.position.x, y = entity.position.y,
        }
      end
    end
  end
  table.sort(entities, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    if a.type ~= b.type then return a.type < b.type end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)
  while #entities > 8 do table.remove(entities) end
  local entity_labels = {}
  for _, entity in ipairs(entities) do
    entity_labels[#entity_labels + 1] = string.format("%s:%s@(%.1f,%.1f)",
      entity.name, entity.type, entity.x, entity.y)
  end

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
        tiles[#tiles + 1] = { name = tile.name or "collision-tile", x = tx, y = ty }
      end
    end
  end
  table.sort(tiles, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)
  while #tiles > 8 do table.remove(tiles) end
  local tile_labels = {}
  for _, tile in ipairs(tiles) do
    tile_labels[#tile_labels + 1] = string.format("%s@(%d,%d)", tile.name, tile.x, tile.y)
  end
  local evidence
  if #entity_labels == 0 and #tile_labels == 0 then
    evidence = string.format(
      "immediate charted collision segment (%.1f,%.1f)->(%.1f,%.1f); inferred visible collision evidence only, not an authoritative blocker; no immediate charted blocker identified",
      from.x, from.y, to.x, to.y)
  else
    evidence = string.format("immediate charted collision segment (%.1f,%.1f)->(%.1f,%.1f); inferred visible collision evidence only, not authoritative blockers; visible_collision_candidates=%s; collision_tiles=%s",
      from.x, from.y, to.x, to.y, #entity_labels > 0 and table.concat(entity_labels, ",") or "none",
      #tile_labels > 0 and table.concat(tile_labels, ",") or "none")
  end
  state.blocker_evidence = evidence
  return evidence
end

local FRONTIER_OFFSETS = {
  { x = 0, y = -4 }, { x = 4, y = -4 }, { x = 4, y = 0 }, { x = 4, y = 4 },
  { x = 0, y = 4 }, { x = -4, y = 4 }, { x = -4, y = 0 }, { x = -4, y = -4 },
}

local function charted(c, point)
  return c.force.is_chunk_charted(c.surface,
    { x = math.floor(point.x / 32), y = math.floor(point.y / 32) })
end

local function point_key(point)
  return string.format("%.2f:%.2f", point.x, point.y)
end

local function goal_occupancy(c, point)
  local current_box = placement_geometry.character_box(c)
  if not current_box then return { state = "unknown", reason = "character collision box unavailable" } end
  local dx, dy = point.x - c.position.x, point.y - c.position.y
  local area = {
    left_top = { x = current_box.left_top.x + dx, y = current_box.left_top.y + dy },
    right_bottom = { x = current_box.right_bottom.x + dx, y = current_box.right_bottom.y + dy },
  }
  local corners = { area.left_top,
    { x = area.right_bottom.x - 0.001, y = area.left_top.y },
    { x = area.left_top.x, y = area.right_bottom.y - 0.001 },
    { x = area.right_bottom.x - 0.001, y = area.right_bottom.y - 0.001 } }
  for _, corner in ipairs(corners) do
    if not charted(c, corner) then
      return { state = "unknown", reason = "goal collision box crosses uncharted terrain" }
    end
  end
  local entities, tiles = {}, {}
  local ok, found = pcall(c.surface.find_entities_filtered, {
    area = area, collision_mask = prototypes.entity["character"].collision_mask,
  })
  if ok then
    for _, entity in ipairs(found or {}) do
      if entity.valid and entity ~= c and entity.type ~= "resource" and entity.type ~= "item-entity" then
        entities[#entities + 1] = { name = entity.name, type = entity.type,
          position = { x = entity.position.x, y = entity.position.y }, player_owned = entity.force == c.force }
      end
    end
  end
  table.sort(entities, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return a.position.x < b.position.x
  end)
  while #entities > 8 do table.remove(entities) end
  local seen = {}
  for _, corner in ipairs(corners) do
    local tile_ok, tile = pcall(c.surface.get_tile, corner.x, corner.y)
    local collision_ok, collides = tile_ok and tile and pcall(tile.collides_with, "player")
    if collision_ok and collides then
      local key = math.floor(corner.x) .. ":" .. math.floor(corner.y)
      if not seen[key] then
        seen[key] = true
        tiles[#tiles + 1] = { name = tile.name or "collision-tile",
          position = { x = math.floor(corner.x), y = math.floor(corner.y) } }
      end
    end
  end
  return { state = (#entities > 0 or #tiles > 0) and "occupied" or "clear",
    entities = entities, tiles = tiles }
end

local function path_charted(c, path)
  for _, waypoint in ipairs(path or {}) do
    if not charted(c, waypoint) then return false end
  end
  return true
end

local function request_next_frontier(state, c, task_id)
  state.frontier_index = state.frontier_index + 1
  local candidate = state.frontier_candidates[state.frontier_index]
  if not candidate then return false end
  request_path(state, c, task_id, candidate, "frontier_waiting")
  return true
end

local function begin_frontier_diagnostics(state, c, task_id)
  state.frontier_candidates, state.frontier_paths, state.frontier_index = {}, {}, 0
  for _, offset in ipairs(FRONTIER_OFFSETS) do
    local requested = { x = c.position.x + offset.x, y = c.position.y + offset.y }
    if charted(c, requested) then
      local ok, clear = pcall(c.surface.find_non_colliding_position,
        c.name or "character", requested, 0.5, 0.1, false)
      if ok and clear and charted(c, clear) then
        state.frontier_candidates[#state.frontier_candidates + 1] = { x = clear.x, y = clear.y }
      end
    end
  end
  return request_next_frontier(state, c, task_id)
end

local function nearby_collision_evidence(c)
  local area = { left_top = { x = c.position.x - 4, y = c.position.y - 4 },
    right_bottom = { x = c.position.x + 4, y = c.position.y + 4 } }
  for _, point in ipairs({ area.left_top, area.right_bottom }) do
    if not charted(c, point) then return {}, {}, "bounded cage area crosses uncharted terrain" end
  end
  local entities, tiles = {}, {}
  local ok, found = pcall(c.surface.find_entities_filtered, {
    area = area, collision_mask = prototypes.entity["character"].collision_mask,
  })
  if ok then for _, entity in ipairs(found or {}) do
    if entity.valid and entity ~= c and entity.type ~= "resource" and entity.type ~= "item-entity" then
      entities[#entities + 1] = { name = entity.name, type = entity.type,
        position = { x = entity.position.x, y = entity.position.y },
        player_owned = entity.force == c.force }
    end
  end end
  table.sort(entities, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    return a.name < b.name
  end)
  while #entities > 16 do table.remove(entities) end
  for y = math.floor(area.left_top.y), math.ceil(area.right_bottom.y) - 1 do
    for x = math.floor(area.left_top.x), math.ceil(area.right_bottom.x) - 1 do
      local tile_ok, tile = pcall(c.surface.get_tile, x, y)
      local collision_ok, collides = tile_ok and tile and pcall(tile.collides_with, "player")
      if collision_ok and collides then tiles[#tiles + 1] = { name = tile.name or "collision-tile", position = { x = x, y = y } } end
    end
  end
  while #tiles > 16 do table.remove(tiles) end
  return entities, tiles, nil
end

local function resolve_frontiers(state, c)
  for _, entry in ipairs(state.frontier_paths or {}) do
    entry.reduction = math.sqrt(dist_sq(c.position, state.target)) - math.sqrt(dist_sq(entry.position, state.target))
  end
  table.sort(state.frontier_paths, function(a, b)
    if a.reduction ~= b.reduction then return a.reduction > b.reduction end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return a.position.x < b.position.x
  end)
  local frontiers = {}
  for _, entry in ipairs(state.frontier_paths or {}) do
    local partial_route = {}
    for index = 1, math.min(#entry.path, 12) do partial_route[index] = entry.path[index] end
    frontiers[#frontiers + 1] = {
      position = entry.position,
      reduction = entry.reduction,
      partial_route = partial_route,
      omitted_waypoints = math.max(0, #entry.path - 12),
    }
  end
  local recommended = frontiers[1]
  local occupancy = state.goal_occupancy
    or (state.arrival_mode == "exact" and goal_occupancy(c, state.requested_goal) or nil)
  if (not occupancy or occupancy.state ~= "occupied")
    and (state.frontier_segments or 0) < MAX_FRONTIER_SEGMENTS then
    local current_distance = dist_sq(c.position, state.target)
    for index, candidate in ipairs(frontiers) do
      local key = point_key(candidate.position)
      if not state.visited_frontiers[key]
        and dist_sq(candidate.position, state.target) + MIN_FRONTIER_PROGRESS_SQ < current_distance then
        state.frontier_segments = (state.frontier_segments or 0) + 1
        state.visited_frontiers[key] = true
        state.recovery_history[#state.recovery_history + 1] = {
          from = { x = c.position.x, y = c.position.y }, to = candidate.position,
          reduction = candidate.reduction,
        }
        state.path, state.waypoint, state.phase = state.frontier_paths[index].path, 1, "frontier_following"
        state.frontier_start_distance = current_distance
        stop(c)
        return nil
      end
    end
  end
  local evidence = blocker_evidence(state, c, state.target)
  local collision_candidates, collision_tiles, evidence_error = nearby_collision_evidence(c)
  local code = occupancy and occupancy.state == "occupied" and "GOAL_OCCUPIED" or "PATH_NOT_FOUND"
  local diagnostics = { code = code, evidence_scope = "charted_visible_only",
    start = { x = c.position.x, y = c.position.y }, requested_goal = state.requested_goal,
    resolved_goal = state.target, arrival_mode = state.arrival_mode, arrival_radius = state.arrival_radius,
    reachable_frontier = recommended and recommended.position or nil,
    reachable_frontiers = frontiers,
    partial_route = recommended and recommended.partial_route or {},
    omitted_waypoints = recommended and recommended.omitted_waypoints or 0,
    blocker_evidence = evidence,
    goal_occupancy = occupancy,
    recovery = { segments_completed = state.frontier_segments or 0,
      limit = MAX_FRONTIER_SEGMENTS, history = state.recovery_history },
    owned_collision_candidates = collision_candidates, collision_tiles = collision_tiles,
    cage_evidence_error = evidence_error }
  return fail(c, code, string.format(
    "Factorio found no character path to resolved goal (%.1f, %.1f) after %d bounded monotonic frontier segment(s); %s; reachable_frontier=%s",
    state.target.x, state.target.y, state.frontier_segments or 0, evidence,
    recommended and string.format("(%.1f,%.1f)", recommended.position.x, recommended.position.y) or "none"),
    { code = code, diagnostics = { path = diagnostics } })
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
function M.begin(state, c, target, arrive_within, arrival_mode, arrival_radius)
  -- Walking tasks take over from driving: hop out first.
  pcall(function()
    if c.driving then c.driving = false end
  end)
  for k in pairs(state) do
    state[k] = nil
  end
  state.requested_goal = { x = target.x, y = target.y }
  state.arrival_mode = arrival_mode or "exact"
  state.arrival_radius = tonumber(arrival_radius) or tonumber(arrive_within) or 1.0
  state.target = { x = target.x, y = target.y }
  state.arrive_within = math.max(tonumber(arrive_within) or 1.0, 0.1)
  if state.arrival_mode == "vicinity" then
    local ok, clear = pcall(c.surface.find_non_colliding_position,
      c.name or "character", state.requested_goal, state.arrival_radius, 0.1, false)
    if ok and clear and charted(c, clear) then
      state.target = { x = clear.x, y = clear.y }
      state.arrive_within = 0.5
    else
      state.resolve_failure = "no charted collision-free vicinity candidate was found"
    end
  end
  state.phase = "request"
  state.retries = 0
  state.recoveries = 0
  state.frontier_segments = 0
  state.visited_frontiers = { [point_key(c.position)] = true }
  state.recovery_history = {}
end

-- Advance the walker one tick. Returns nil while moving, "arrived" once within
-- arrive_within of the target, or {failed = "reason"} when it gives up.
function M.step(state, c, task_id)
  local pos = c.position

  if state.resolve_failure then
    return fail(c, "VICINITY_NOT_FOUND", state.resolve_failure, { code = "VICINITY_NOT_FOUND",
      diagnostics = { path = { evidence_scope = "charted_visible_only",
        requested_goal = state.requested_goal, resolved_goal = nil,
        arrival_mode = state.arrival_mode, arrival_radius = state.arrival_radius } } })
  end

  if dist_sq(pos, state.target) <= state.arrive_within * state.arrive_within then
    stop(c)
    return "arrived"
  end

  if state.phase == "request" then
    local escape = begin_escape(state, c)
    if type(escape) == "table" then return escape end
    if escape then
      c.walking_state = { walking = true, direction = direction_toward(c.position, state.escape_target) }
      return nil
    end
    request_path(state, c, task_id)
  end


  if state.phase == "escaping" then
    local collisions = placement_geometry.start_collisions(c)
    if #collisions == 0 then
      state.escape_cleared_tick = game.tick
      request_path(state, c, task_id)
      stop(c)
      return nil
    end
    if game.tick - state.escape_started_tick >= ESCAPE_TICKS then
      return fail(c, "START_COLLISION", string.format(
        "ordinary walking could not clear %s toward free position (%.1f, %.1f) within %d ticks",
        state.start_collisions, state.escape_target.x, state.escape_target.y, ESCAPE_TICKS))
    end
    c.walking_state = { walking = true, direction = direction_toward(c.position, state.escape_target) }
    return nil
  end

  if state.phase == "waiting" then
    local result = take_path_result(state, task_id)
    if result then
      if result.try_again_later then
        local failed = retry_or_fail(state, c, "PATH_TRANSIENT",
          "Factorio's pathfinder remained temporarily unavailable")
        if failed then return failed end
      elseif not result.path or #result.path == 0 then
        if state.arrival_mode == "exact" then
          if not state.goal_occupancy or state.goal_occupancy.state == "unknown" then
            state.goal_occupancy = goal_occupancy(c, state.requested_goal)
          end
          if state.goal_occupancy.state == "occupied" then
            state.frontier_candidates, state.frontier_paths, state.frontier_index = {}, {}, 0
            return resolve_frontiers(state, c)
          end
        end
        if not begin_frontier_diagnostics(state, c, task_id) then return resolve_frontiers(state, c) end
        return nil
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


  if state.phase == "frontier_waiting" then
    local result = take_path_result(state, task_id)
    if result then
      if result.path and #result.path > 0 and path_charted(c, result.path) then
        state.frontier_paths[#state.frontier_paths + 1] = {
          position = state.frontier_candidates[state.frontier_index], path = result.path,
        }
      end
      if not request_next_frontier(state, c, task_id) then return resolve_frontiers(state, c) end
      return nil
    elseif game.tick - state.request_tick > PATH_WAIT_TICKS then
      if not request_next_frontier(state, c, task_id) then return resolve_frontiers(state, c) end
      return nil
    end
    stop(c)
    return nil
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
  if state.phase == "following" or state.phase == "frontier_following" then
    local following_frontier = state.phase == "frontier_following"
    local path = state.path
    while state.waypoint <= #path and dist_sq(pos, path[state.waypoint]) <= WAYPOINT_RADIUS_SQ do
      state.waypoint = state.waypoint + 1
    end
    if state.waypoint > #path then
      state.path = nil
      if following_frontier then
        if dist_sq(pos, state.target) + MIN_FRONTIER_PROGRESS_SQ >= state.frontier_start_distance then
          return fail(c, "PATH_RECOVERY_CYCLE", "frontier traversal did not strictly reduce distance to the resolved goal",
            { code = "PATH_RECOVERY_CYCLE", diagnostics = { path = { requested_goal = state.requested_goal,
              resolved_goal = state.target, recovery = { segments_completed = state.frontier_segments,
                limit = MAX_FRONTIER_SEGMENTS, history = state.recovery_history } } } })
        end
        request_path(state, c, task_id)
        stop(c)
        return nil
      end
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
  task.arrival_mode = task.arrival_mode or "exact"
  if task.arrival_mode ~= "exact" and task.arrival_mode ~= "vicinity" then
    error("walk_to arrival_mode must be exact or vicinity")
  end
  task.arrival_radius = tonumber(task.arrival_radius) or 1.0
  if task.arrival_radius < (task.arrival_mode == "vicinity" and 0.5 or 0.1) or task.arrival_radius > 6 then
    error("walk_to arrival_radius is outside the supported range")
  end
  task.arrive_within = task.arrival_mode == "vicinity" and 0.5 or task.arrival_radius
  task._walk = {}
  M.begin(task._walk, c, t, task.arrive_within, task.arrival_mode, task.arrival_radius)
end

function M.tick(task)
  local c = companion.get()
  if not c then
    return { status = "failed", detail = "the companion character is gone" }
  end
  local r = M.step(task._walk, c, task.id)
  if r == "arrived" then
    return { status = "done", detail = string.format("arrived at (%.1f, %.1f)", c.position.x, c.position.y),
      outcome = { requested_goal = task._walk.requested_goal, resolved_goal = task._walk.target,
        arrival_mode = task._walk.arrival_mode, arrival_radius = task._walk.arrival_radius,
        recovery_segments = task._walk.frontier_segments } }
  elseif type(r) == "table" then
    return { status = "failed", detail = r.failed, outcome = r.outcome }
  end
  return nil
end

return M
