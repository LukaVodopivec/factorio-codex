-- walk_to + reusable pathfinder walker. Other actions embed the walker via
-- M.begin/M.step (plain-data state, storage-safe). Pathfinder results arrive
-- through on_script_path_request_finished → M.on_path_finished (wired in
-- control.lua); storage.path_request belongs to the sole active task.
-- A blocked start is recovered in the body's own way: a tree or rock in the
-- way is mined (once), otherwise the body walks to the nearest charted tile
-- centre whose box touches no water, building or belt, trying a few such
-- centres in different directions before it gives up. The start check is not
-- run against a body moving along a native path: Factorio's pathfinder owns
-- what is traversable there (a shore route keeps the body's centre on the
-- walkable margin of water tiles, which the tile-based check reads as
-- blocked), and a body that really cannot move is caught by the stuck check.
local companion = require("scripts.companion")
local set_walking = require("scripts.human_inputs").set_walking
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
local ESCAPE_TICKS = 90 -- one escape direction's deadline
local ESCAPE_STUCK_TICKS = 30 -- no progress for this long: try the next direction
local MAX_ESCAPE_ATTEMPTS = 4 -- free tile centres tried, each in another direction
local MAX_ESCAPES = 2 -- escapes one walk may begin (typically its start and its end)
local FRONTIER_RADIUS = 0.5 -- each probe must reach its own frontier point
local MAX_FRONTIER_PROBES = 16
-- Off-belt tiles within 2 tiles of the body's tile, then (a belt crossing
-- or a wide splitter) within 4. An approach, whose tile must stay within
-- reach of its target, also tries the ring out to 8 (a wide belt bundle):
-- each ring checks only its own cells, at most about 150 in one tick.
local SETTLE_RADII = { 2, 4 }
local SETTLE_WIDE_RADIUS = 8
local SETTLE_TICKS = 60 -- per 4 tiles to the off-belt tile

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

-- The walking direction toward `to`, kept from the last tick while the
-- bearing stays within STEER_HOLD_DEG of it. Rounding the bearing afresh
-- each tick flips between two neighbouring directions on any leg that lies
-- between them (the body zig-zags and its sprite flickers); holding turns
-- such a leg into one straight run and one diagonal run.
local STEER_HOLD_DEG = 40
local atan2 = math.atan2 or math.atan -- Factorio's Lua 5.2 has atan2; 5.3+ takes two arguments
local function steer(state, from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local held = state.walk_dir
  if held and (dx ~= 0 or dy ~= 0) then
    local bearing = math.deg(atan2(dx, -dy)) -- clockwise from north
    local off = (bearing - held * 22.5) % 360
    if off > 180 then off = 360 - off end
    if off <= STEER_HOLD_DEG then return held end
  end
  state.walk_dir = direction_toward(from, to)
  return state.walk_dir
end
M.steer = steer

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- Entity searches take the layer dictionary, not the whole CollisionMask.
local function character_layers()
  local mask = prototypes.entity["character"].collision_mask
  return mask and mask.layers or mask
end

local function request_path(state, c, task_id, target, phase, radius)
  target = target or state.target
  state.walk_dir = nil
  local id = c.surface.request_path({
    bounding_box = { { -0.2, -0.2 }, { 0.2, 0.2 } },
    collision_mask = prototypes.entity["character"].collision_mask,
    start = c.position,
    goal = target,
    force = c.force,
    radius = radius or math.max(state.arrive_within, 0.5),
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
  set_walking(c, { walking = false })
end

-- M.start_clearer: the runner that mines a tree or rock blocking the start
-- (mine.lua sets itself: it needs this module through approach.lua).
local NATURAL_BLOCKERS = { tree = true, ["simple-entity"] = true, plant = true }

-- Every failure carries its code in the outcome, so the step that embeds
-- the walk ends with that code.
local function fail(c, code, detail, outcome)
  stop(c)
  return { failed = code .. ": " .. detail, outcome = outcome or { code = code } }
end

local function escape_fail(state, c, code, detail, outcome)
  state.escape_failed = true
  return fail(c, code, detail, outcome)
end

local function collision_labels(collisions)
  local labels = {}
  for _, collision in ipairs(collisions) do
    labels[#labels + 1] = string.format("%s:%s@(%.1f,%.1f)", collision.kind, collision.name,
      collision.position.x, collision.position.y)
  end
  return #labels > 0 and table.concat(labels, ",") or "none"
end

local settle_cell
-- Free tile centres around the body, nearest first, one for each walking
-- direction (at most MAX_ESCAPE_ATTEMPTS).
local function escape_cells(c)
  local cells, seen = {}, {}
  pcall(settle_cell, c, nil, nil, SETTLE_RADII[#SETTLE_RADII], function(cell)
    local direction = direction_toward(c.position, cell)
    if not seen[direction] then
      seen[direction] = true
      cells[#cells + 1] = { x = cell.x, y = cell.y }
    end
    return #cells >= MAX_ESCAPE_ATTEMPTS
  end)
  return cells
end

local function begin_escape(state, c, evidence)
  local collisions = evidence.collisions
  -- A walk begun by 0.22.0 kept a flag, not a count.
  local escapes = state.escapes or (state.escape_attempted and 1 or 0)
  if escapes >= MAX_ESCAPES then
    return escape_fail(state, c, "START_COLLISION", "start became blocked again after the bounded escape; observe and choose a reachable local route",
      { code = "START_COLLISION", diagnostics = { path_start = evidence, escapes = escapes,
        position = { x = c.position.x, y = c.position.y } } })
  end
  state.escapes, state.escape_attempted = escapes + 1, true
  local pending = storage.path_request
  if pending and pending.id == state.request_id then storage.path_request = nil end
  state.path, state.request_id = nil, nil
  -- Tile centres whose whole body box is clear: a point merely beside the
  -- blocked one (find_non_colliding_position) can leave the body on the
  -- water edge.
  local targets = escape_cells(c)
  if #targets == 0 then
    return escape_fail(state, c, "START_COLLISION", "character path body overlaps " .. collision_labels(collisions)
      .. string.format("; no charted clear tile centre within %d tiles", SETTLE_RADII[#SETTLE_RADII]),
      { code = "START_COLLISION", diagnostics = { path_start = evidence, escape_targets = {},
        position = { x = c.position.x, y = c.position.y } } })
  end
  state.phase = "escaping"
  state.escape_targets, state.escape_index, state.escape_stuck = targets, 1, 0
  state.escape_target = targets[1]
  state.escape_started_tick = game.tick
  state.escape_attempt_tick = game.tick
  state.escape_check_tick = game.tick
  state.escape_check_position = { x = c.position.x, y = c.position.y }
  return true
end

-- One tick of an escape whose start is still blocked: a direction that makes
-- no progress, or does not clear the start in time, gives way to the next
-- free tile centre; the escape fails when none is left.
local function step_escape(state, c, evidence)
  local pos = c.position
  if not state.escape_targets then
    -- An escape begun by 0.22.0 had one target and one clock.
    state.escape_targets, state.escape_index, state.escape_stuck = { state.escape_target }, 1, 0
    state.escape_attempt_tick = state.escape_started_tick
  end
  local stuck = false
  if game.tick - state.escape_check_tick >= ESCAPE_STUCK_TICKS then
    stuck = dist_sq(pos, state.escape_check_position) < STUCK_EPSILON_SQ
    state.escape_check_tick = game.tick
    state.escape_check_position = { x = pos.x, y = pos.y }
  end
  if not stuck and game.tick - state.escape_attempt_tick < ESCAPE_TICKS then return nil end
  if stuck then state.escape_stuck = state.escape_stuck + 1 end
  local tried = state.escape_index
  local nxt = state.escape_targets[tried + 1]
  if nxt then
    state.escape_index, state.escape_target, state.escape_attempt_tick = tried + 1, nxt, game.tick
    return nil
  end
  local outcome = { code = "START_COLLISION", diagnostics = { path_start = evidence,
    escape_target = state.escape_target, escape_targets = state.escape_targets,
    position = { x = pos.x, y = pos.y } } }
  if state.escape_stuck >= tried then
    return escape_fail(state, c, "START_COLLISION", string.format(
      "ordinary escape made no physical progress in %d direction(s); %s; the free destination does not prove a traversable approach",
      tried, collision_labels(evidence.collisions)), outcome)
  end
  return escape_fail(state, c, "START_COLLISION", string.format(
    "ordinary walking could not clear %s toward %d free tile centre(s), the last (%.1f, %.1f), within %d ticks each; observe and choose a reachable local route",
    collision_labels(evidence.collisions), tried, state.escape_target.x, state.escape_target.y, ESCAPE_TICKS), outcome)
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
    collision_mask = character_layers(),
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

-- Unit octant offsets; ring 1 probes them at 4 tiles, ring 2 at 8 tiles
-- only when ring 1 returned no charted path.
local FRONTIER_OFFSETS = {
  { x = 0, y = -1 }, { x = 1, y = -1 }, { x = 1, y = 0 }, { x = 1, y = 1 },
  { x = 0, y = 1 }, { x = -1, y = 1 }, { x = -1, y = 0 }, { x = -1, y = -1 },
}
local FRONTIER_RING_DISTANCE = { 4, 8 }

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
    area = area, collision_mask = character_layers(),
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
    -- Two statements: a boolean expression keeps only pcall's first result.
    local collision_ok, collides = false, false
    if tile_ok and tile then collision_ok, collides = pcall(tile.collides_with, "player") end
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

-- Each probe keeps its own outcome so an empty frontier list says why.
local function add_frontier_ring(state, c, ring)
  local distance = FRONTIER_RING_DISTANCE[ring]
  for _, offset in ipairs(FRONTIER_OFFSETS) do
    if #state.frontier_probes >= MAX_FRONTIER_PROBES then return end
    local requested = { x = c.position.x + offset.x * distance, y = c.position.y + offset.y * distance }
    local probe = { ring = ring, requested = requested }
    state.frontier_probes[#state.frontier_probes + 1] = probe
    if not charted(c, requested) then
      probe.reason = "uncharted"
    else
      local ok, clear = pcall(c.surface.find_non_colliding_position,
        c.name or "character", requested, 0.5, 0.1, false)
      if ok and clear and charted(c, clear) then
        probe.candidate = { x = clear.x, y = clear.y }
        state.frontier_candidates[#state.frontier_candidates + 1] = { x = clear.x, y = clear.y }
        state.frontier_candidate_probes[#state.frontier_candidates] = #state.frontier_probes
      else
        probe.reason = "no_clear_candidate"
      end
    end
  end
end

local function current_probe(state)
  return state.frontier_probes[state.frontier_candidate_probes[state.frontier_index]]
end

local function request_frontier(state, c, task_id)
  request_path(state, c, task_id, state.frontier_candidates[state.frontier_index], "frontier_waiting", FRONTIER_RADIUS)
end

local function request_next_frontier(state, c, task_id)
  state.frontier_index = state.frontier_index + 1
  if not state.frontier_candidates[state.frontier_index] and state.frontier_ring == 1
    and #state.frontier_paths == 0 then
    state.frontier_ring = 2
    add_frontier_ring(state, c, 2)
  end
  if not state.frontier_candidates[state.frontier_index] then return false end
  request_frontier(state, c, task_id)
  return true
end

local function begin_frontier_diagnostics(state, c, task_id)
  state.frontier_candidates, state.frontier_paths, state.frontier_index = {}, {}, 0
  state.frontier_probes, state.frontier_candidate_probes, state.frontier_ring = {}, {}, 1
  add_frontier_ring(state, c, 1)
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
    area = area, collision_mask = character_layers(),
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
  for y = math.floor(area.left_top.y), math.ceil(area.right_bottom.y) - 1 do
    for x = math.floor(area.left_top.x), math.ceil(area.right_bottom.x) - 1 do
      local tile_ok, tile = pcall(c.surface.get_tile, x, y)
      local collision_ok, collides = false, false
      if tile_ok and tile then collision_ok, collides = pcall(tile.collides_with, "player") end
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
  local progress_index
  if not occupancy or occupancy.state ~= "occupied" then
    local current_distance = dist_sq(c.position, state.target)
    for index, candidate in ipairs(frontiers) do
      local key = point_key(candidate.position)
      if not state.visited_frontiers[key]
        and dist_sq(candidate.position, state.target) + MIN_FRONTIER_PROGRESS_SQ < current_distance then
        progress_index = index
        break
      end
    end
  end
  local capped_with_progress = progress_index ~= nil and (state.frontier_segments or 0) >= MAX_FRONTIER_SEGMENTS
  if progress_index and not capped_with_progress then
    local candidate = frontiers[progress_index]
    state.frontier_segments = (state.frontier_segments or 0) + 1
    state.visited_frontiers[point_key(candidate.position)] = true
    state.recovery_history[#state.recovery_history + 1] = {
      from = { x = c.position.x, y = c.position.y }, to = candidate.position,
      reduction = candidate.reduction,
    }
    state.path, state.waypoint, state.phase = state.frontier_paths[progress_index].path, 1, "frontier_following"
    state.frontier_start_distance = dist_sq(c.position, state.target)
    stop(c)
    return nil
  end
  local evidence = blocker_evidence(state, c, state.target)
  local collision_candidates, collision_tiles, evidence_error = nearby_collision_evidence(c)
  local code = occupancy and occupancy.state == "occupied" and "GOAL_OCCUPIED" or "PATH_NOT_FOUND"
  -- The pathfinder refused every probe it answered, and none ended
  -- inconclusive (timeout, backpressure, uncharted route): the body is
  -- enclosed. Name an owned blocker so ordinary owned mining, not a
  -- teleport, can open it: one on the line toward the target first, then the
  -- nearest. Otherwise an empty frontier list stays PATH_NOT_FOUND.
  local suggested
  local refused, inconclusive = false, false
  for _, probe in ipairs(state.frontier_probes or {}) do
    if probe.reason == "path_failed" then refused = true end
    if probe.reason == "timeout" or probe.reason == "transient" or probe.reason == "path_uncharted" then inconclusive = true end
  end
  if code == "PATH_NOT_FOUND" and #(state.frontier_paths or {}) == 0 and refused and not inconclusive then
    local dx, dy = state.target.x - c.position.x, state.target.y - c.position.y
    local length = math.sqrt(dx * dx + dy * dy)
    local best, best_line, best_distance
    for _, candidate in ipairs(collision_candidates) do
      if candidate.player_owned then
        local ox, oy = candidate.position.x - c.position.x, candidate.position.y - c.position.y
        local on_line = length > 0 and (ox * dx + oy * dy) > 0 and math.abs(ox * dy - oy * dx) / length <= 1.5
        local distance = dist_sq(c.position, candidate.position)
        if not best or on_line and not best_line or on_line == best_line and distance < best_distance then
          best, best_line, best_distance = candidate, on_line, distance
        end
      end
    end
    if best then
      code = "BODY_ENCLOSED"
      suggested = { tool = "mine", target_kind = "owned", x = best.position.x, y = best.position.y,
        expected_name = best.name,
        hint = "mine this owned blocker (extract its contents first if it holds items), then retry the walk" }
    end
  end
  -- The suggestion considers every collider found; the report keeps 16.
  while #collision_candidates > 16 do table.remove(collision_candidates) end
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
      limit = MAX_FRONTIER_SEGMENTS, history = state.recovery_history,
      termination_reason = capped_with_progress and "segment_limit_with_progress" or nil },
    owned_collision_candidates = collision_candidates, collision_tiles = collision_tiles,
    cage_evidence_error = evidence_error,
    frontier_probes = state.frontier_probes,
    failure_class = code == "BODY_ENCLOSED" and "PATH_NOT_FOUND" or nil,
    suggested_recovery = suggested }
  local reason = capped_with_progress and string.format(
    "bounded frontier recovery stopped at its %d-segment limit with admissible native progress remaining; full goal reachability is unproven; resolved goal (%.1f, %.1f)",
    MAX_FRONTIER_SEGMENTS, state.target.x, state.target.y) or string.format(
    "Factorio found no character path to resolved goal (%.1f, %.1f) after %d bounded monotonic frontier segment(s)",
    state.target.x, state.target.y, state.frontier_segments or 0)
  return fail(c, code, string.format("%s; %s; reachable_frontier=%s%s", reason, evidence,
    recommended and string.format("(%.1f,%.1f)", recommended.position.x, recommended.position.y) or "none",
    suggested and string.format("; enclosed by owned entities: mine owned %s at (%.1f,%.1f) to open a route",
      suggested.expected_name, suggested.x, suggested.y) or ""),
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

local function conveyor_label(conveyor)
  return { name = conveyor.name, type = conveyor.type, direction = conveyor.direction,
    position = { x = conveyor.position.x, y = conveyor.position.y } }
end

-- Nearest charted tile centre within `radius` tiles whose body box touches no
-- conveyor and no character collider, optionally within `limit` of `anchor`.
-- `inner` (optional) skips the cells an earlier, smaller radius checked.
-- `accept` (optional) sees each such centre, nearest first, and ends the
-- search by returning true.
function settle_cell(c, anchor, limit, radius, accept, inner)
  local pos = c.position
  local tx, ty = math.floor(pos.x), math.floor(pos.y)
  local cells = {}
  local skip = inner and inner * inner or -1
  for dy = -radius, radius do
    for dx = -radius, radius do
      local d2 = dx * dx + dy * dy
      if d2 <= radius * radius and d2 > skip then
        local cell = { x = tx + dx + 0.5, y = ty + dy + 0.5 }
        cells[#cells + 1] = { position = cell, distance = dist_sq(pos, cell) }
      end
    end
  end
  table.sort(cells, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return a.position.x < b.position.x
  end)
  local box = placement_geometry.character_box(c)
  local rejected = { out_of_range = 0, uncharted = 0, conveyor = 0, collision = 0 }
  for _, entry in ipairs(cells) do
    local cell = entry.position
    if anchor and dist_sq(cell, anchor) > limit * limit + 1e-6 then
      rejected.out_of_range = rejected.out_of_range + 1
    elseif not charted(c, cell) then
      rejected.uncharted = rejected.uncharted + 1
    else
      local dx, dy = cell.x - pos.x, cell.y - pos.y
      local shifted = box and { left_top = { x = box.left_top.x + dx, y = box.left_top.y + dy },
        right_bottom = { x = box.right_bottom.x + dx, y = box.right_bottom.y + dy } }
      if not shifted or placement_geometry.conveyor_under(c, shifted) then
        rejected.conveyor = rejected.conveyor + 1
      elseif goal_occupancy(c, cell).state ~= "clear" then
        rejected.collision = rejected.collision + 1
      elseif not accept or accept(cell) then
        return cell, rejected
      end
    end
  end
  return nil, rejected
end

-- Belts carry a standing body, so a walk never finishes on one. Step once by
-- ordinary walking to the nearest clear off-belt tile, or fail truthfully.
function M.begin_settle(state, c, anchor, limit)
  local conveyor = placement_geometry.conveyor_under(c)
  if not conveyor then return nil end
  state.settle_anchor = anchor and { x = anchor.x, y = anchor.y } or nil
  state.settle_limit = limit
  state.settle_attempted = true
  local radii = {}
  for i, radius in ipairs(SETTLE_RADII) do radii[i] = radius end
  if state.settle_anchor and limit and limit > radii[#radii] then
    radii[#radii + 1] = math.min(SETTLE_WIDE_RADIUS, math.floor(limit))
  end
  local cell, inner
  local rejected = { out_of_range = 0, uncharted = 0, conveyor = 0, collision = 0 }
  for _, radius in ipairs(radii) do
    local ring_rejected
    cell, ring_rejected = settle_cell(c, state.settle_anchor, limit, radius, nil, inner)
    for key, count in pairs(ring_rejected) do rejected[key] = rejected[key] + count end
    inner = radius
    if cell then break end
  end
  if not cell then
    return fail(c, "BODY_ON_CONVEYOR", string.format(
      "the body stands on %s at (%.1f, %.1f) and no charted clear off-belt tile lies within %d tiles%s",
      conveyor.name, conveyor.position.x, conveyor.position.y, inner,
      anchor and " and within reach of the target" or ""),
      { code = "BODY_ON_CONVEYOR", diagnostics = { path = { evidence_scope = "charted_visible_only",
        start = { x = c.position.x, y = c.position.y }, conveyor = conveyor_label(conveyor),
        settle_rejected = rejected, settle_anchor = state.settle_anchor, settle_limit = limit } } })
  end
  state.phase = "settling"
  state.settle = { from = { x = c.position.x, y = c.position.y }, to = cell,
    conveyor = conveyor_label(conveyor), started_tick = game.tick,
    ticks_allowed = SETTLE_TICKS * math.max(1, math.ceil(math.sqrt(dist_sq(c.position, cell)) / 4)) }
  state.walk_dir = nil
  set_walking(c, { walking = true, direction = steer(state, c.position, cell) })
  return nil
end

local function step_settle(state, c)
  local pos, settle = c.position, state.settle
  local anchored = not state.settle_anchor
    or dist_sq(pos, state.settle_anchor) <= state.settle_limit * state.settle_limit + 1e-6
  if anchored and not placement_geometry.conveyor_under(c) then
    stop(c)
    settle.final = { x = pos.x, y = pos.y }
    settle.ticks = game.tick - settle.started_tick
    return "arrived"
  end
  -- A settle begun by 0.27.0 has no allowance of its own.
  local allowed = settle.ticks_allowed or SETTLE_TICKS
  if game.tick - settle.started_tick >= allowed then
    return fail(c, "BODY_ON_CONVEYOR", string.format(
      "ordinary walking did not leave %s toward (%.1f, %.1f) within %d ticks",
      settle.conveyor.name, settle.to.x, settle.to.y, allowed),
      { code = "BODY_ON_CONVEYOR", diagnostics = { path = { evidence_scope = "charted_visible_only",
        start = { x = pos.x, y = pos.y }, settle = settle } } })
  end
  set_walking(c, { walking = true, direction = steer(state, pos, settle.to) })
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

-- A tree or rock (not own) among the start collisions, as an entity.
local function natural_start_blocker(c, evidence)
  for _, collision in ipairs(evidence.collisions or {}) do
    if collision.kind == "entity" and NATURAL_BLOCKERS[collision.type] then
      local ok, found = pcall(c.surface.find_entities_filtered, { position = collision.position, radius = 0.5,
        name = collision.name, limit = 4 })
      for _, e in ipairs(ok and type(found) == "table" and found or {}) do
        local ok_minable, minable = pcall(function()
          return e.valid and e.force ~= c.force and e.prototype.mineable_properties.minable
        end)
        if ok_minable and minable then return e end
      end
    end
  end
end

-- Mines the start blocker from where the body stands; true while mining.
local function step_clear(state, c)
  local ok, result = pcall(M.start_clearer.tick, state.clearing)
  if ok and result == nil then return true end
  state.start_cleared = { name = state.clearing.entity_name, position = state.clearing.target,
    status = ok and result.status or "failed", detail = ok and result.detail or tostring(result) }
  state.clearing, state.phase = nil, "request"
  c.mining_state = { mining = false }
  return false
end

local function begin_clear(state, c, task_id, evidence)
  if state.clear_attempted or not M.start_clearer then return false end
  local blocker = natural_start_blocker(c, evidence)
  if not blocker then return false end
  state.clear_attempted = true
  local clearing = { id = task_id, type = "mine", entity = blocker, count = 1, target_kind = "natural", from_here = true,
    target = { x = blocker.position.x, y = blocker.position.y }, entity_name = blocker.name }
  if not pcall(M.start_clearer.start, clearing) then return false end
  state.clearing, state.phase = clearing, "clearing"
  stop(c)
  return true
end

-- (Re)initialize a walker. `state` must be a plain table stored on the task;
-- all fields are plain data. The first step() issues the pathfinder request.
-- arrival_mode "reach" (embedded approaches) aims at an occupied entity centre,
-- so goal occupancy never short-circuits its frontier recovery.
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
-- Within reach of where the walk should end: the resolved point, or, for a
-- vicinity walk, anywhere within arrival_radius of the requested goal.
local function at_goal(state, pos)
  if dist_sq(pos, state.target) <= state.arrive_within * state.arrive_within then return true end
  return state.arrival_mode == "vicinity"
    and dist_sq(pos, state.requested_goal) <= state.arrival_radius * state.arrival_radius
end

function M.step(state, c, task_id)
  local pos = c.position

  if state.phase == "clearing" and M.start_clearer and step_clear(state, c) then return nil end

  local evidence = placement_geometry.path_start(c)
  if evidence.state == "unknown" then
    return fail(c, "START_COLLISION_UNKNOWN", evidence.reason .. "; re-observe collision evidence before retrying",
      { code = "START_COLLISION_UNKNOWN", diagnostics = { path_start = evidence } })
  end
  -- A body moving along a native path is not at a start: the check waits for
  -- the path's end, the goal, or the stuck check's new request.
  local following = (state.phase == "following" or state.phase == "frontier_following") and not at_goal(state, pos)
  if evidence.state == "blocked" and not following then
    if state.phase ~= "escaping" and begin_clear(state, c, task_id, evidence) then return nil end
    if state.escape_failed then
      return fail(c, "START_COLLISION", "the previous bounded escape failed and the current start remains blocked: "
        .. collision_labels(evidence.collisions) .. "; observe and choose a reachable local route",
        { code = "START_COLLISION", diagnostics = { path_start = evidence } })
    end
    if state.phase ~= "escaping" then
      local failure = begin_escape(state, c, evidence)
      if type(failure) == "table" then return failure end
    end
    local failure = step_escape(state, c, evidence)
    if failure then return failure end
    set_walking(c, { walking = true, direction = steer(state, pos, state.escape_target) })
    return nil
  end

  if state.phase == "settling" then return step_settle(state, c) end

  -- Arrival requires current proven clearance, including during an escape,
  -- and a body that no belt can carry away.
  if at_goal(state, pos) then
    local conveyor = placement_geometry.conveyor_under(c)
    if conveyor then
      if state.settle_attempted then
        return fail(c, "BODY_ON_CONVEYOR", "the body still stands on " .. conveyor.name
          .. " after its bounded off-belt step", { code = "BODY_ON_CONVEYOR",
            diagnostics = { path = { start = { x = pos.x, y = pos.y }, conveyor = conveyor_label(conveyor) } } })
      end
      return M.begin_settle(state, c, state.settle_anchor, state.settle_limit)
    end
    stop(c)
    return "arrived"
  end
  if state.resolve_failure then
    return fail(c, "VICINITY_NOT_FOUND", state.resolve_failure, { code = "VICINITY_NOT_FOUND",
      diagnostics = { path = { evidence_scope = "charted_visible_only",
        requested_goal = state.requested_goal, resolved_goal = nil,
        arrival_mode = state.arrival_mode, arrival_radius = state.arrival_radius } } })
  end
  if state.phase == "escaping" then
    state.escape_cleared_tick = game.tick
    state.phase = "request"
  end
  if state.phase == "request" then request_path(state, c, task_id) end

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
    local probe = current_probe(state)
    if result then
      if result.try_again_later and not probe.retried then
        -- One bounded re-request for pathfinder backpressure.
        probe.retried = true
        state.phase, state.retry_at = "frontier_retry_wait", game.tick + RETRY_DELAY_TICKS
        stop(c)
        return nil
      elseif result.try_again_later then
        probe.reason = "transient"
      elseif result.path and #result.path > 0 and path_charted(c, result.path) then
        probe.reason = "path_found"
        state.frontier_paths[#state.frontier_paths + 1] = {
          position = state.frontier_candidates[state.frontier_index], path = result.path,
        }
      else
        probe.reason = result.path and #result.path > 0 and "path_uncharted" or "path_failed"
      end
      if not request_next_frontier(state, c, task_id) then return resolve_frontiers(state, c) end
      return nil
    elseif game.tick - state.request_tick > PATH_WAIT_TICKS then
      probe.reason = "timeout"
      if not request_next_frontier(state, c, task_id) then return resolve_frontiers(state, c) end
      return nil
    end
    stop(c)
    return nil
  end

  if state.phase == "frontier_retry_wait" then
    if game.tick >= state.retry_at then request_frontier(state, c, task_id) end
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
  set_walking(c, { walking = true, direction = steer(state, pos, goal) })
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
  if task.arrival_mode == "exact" and task.arrival_radius ~= 1 then
    error("walk_to exact arrival uses the fixed 1-tile tolerance; use vicinity for a wider radius")
  end
  task.arrive_within = task.arrival_mode == "vicinity" and 0.5 or task.arrival_radius
  task._walk = {}
  M.begin(task._walk, c, t, task.arrive_within, task.arrival_mode, task.arrival_radius)
end

-- After a human hold the body stands somewhere else: plan the same walk
-- again from the current position.
function M.resume(task)
  local c = companion.get()
  if not c then return end
  M.begin(task._walk, c, task.target, task.arrive_within, task.arrival_mode, task.arrival_radius)
end

function M.tick(task)
  local c = companion.get()
  if not c then
    return { status = "failed", detail = "the companion character is gone" }
  end
  local r = M.step(task._walk, c, task.id)
  if r == "arrived" then
    local settle = task._walk.settle
    return { status = "done", detail = string.format("arrived at (%.1f, %.1f)%s", c.position.x, c.position.y,
        settle and string.format("; stepped off %s at (%.1f, %.1f)", settle.conveyor.name,
          settle.conveyor.position.x, settle.conveyor.position.y) or ""),
      outcome = { requested_goal = task._walk.requested_goal, resolved_goal = task._walk.target,
        arrival_mode = task._walk.arrival_mode, arrival_radius = task._walk.arrival_radius,
        recovery_segments = task._walk.frontier_segments, settle = settle, start_cleared = task._walk.start_cleared } }
  elseif type(r) == "table" then
    return { status = "failed", detail = r.failed, outcome = r.outcome }
  end
  return nil
end

return M
