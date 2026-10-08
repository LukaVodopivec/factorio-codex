local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

_G.defines = {
  direction = { north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14 },
}
_G.prototypes = { entity = { character = { collision_mask = { layers = { player = true }, not_colliding_with_itself = true, consider_tile_transitions = true },
  collision_box = { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } } } } }

local next_path_id, blocker_filter, chart_all, requested_goals, entity_filters = 0, nil, true, {}, {}
local found_blockers = {
  { valid = true, name = "stone-furnace", type = "furnace", position = { x = 1, y = 0 } },
}
local tile_blocks = true
local entity_queries, tile_queries = 0, 0
local body = {
  valid = true,
  position = { x = 0, y = 0 },
  force = { is_chunk_charted = function(_, chunk) return chart_all or chunk.x == 0 end },
  walking_state = {},
  surface = { request_path = function(options)
    next_path_id = next_path_id + 1
    requested_goals[next_path_id] = options.goal
    return next_path_id
  end,
  get_tile = function(x, y) tile_queries = tile_queries + 1; return { position = { x = math.floor(x), y = math.floor(y) },
    name = x >= 0.5 and "water" or "grass", collides_with = function(layer) return tile_blocks and layer == "player" and x >= 0.5 and x < 2 end } end,
  find_entities_filtered = function(filter)
    entity_queries = entity_queries + 1; blocker_filter = filter; entity_filters[#entity_filters + 1] = filter
    -- A blocker with a box is found only by areas overlapping it (the
    -- start check and escape cells); one without a box by every query.
    local out = {}
    for _, e in ipairs(found_blockers) do
      local box, area = e.bounding_box, filter.area
      if not box then
        if not filter.limit then out[#out + 1] = e end
      elseif not area or (box.left_top.x < area.right_bottom.x and box.right_bottom.x > area.left_top.x
        and box.left_top.y < area.right_bottom.y and box.right_bottom.y > area.left_top.y) then
        out[#out + 1] = e
      end
    end
    return out
  end },
}
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
local walk = require("scripts.actions.walk")
local approach = require("scripts.actions.approach")

local function reset(target)
  next_path_id = 0
  requested_goals = {}
  body.position = { x = 0, y = 0 }
  body.walking_state = {}
  _G.game = { tick = 0 }
  local task = { id = 7, target = target or { x = 10, y = 0 } }
  _G.storage = { tasks = { active = task }, path_request = nil }
  task._walk = {}
  walk.begin(task._walk, body, task.target, 0.5)
  return task
end

-- A pinned body tries each escape direction for half a second: advance in
-- those windows until the call answers (at most four directions).
local function until_answer(call)
  for _ = 1, 4 do
    game.tick = game.tick + 30
    local answer = call()
    if answer then return answer end
  end
end

local function deliver(path, transient)
  local id = storage.path_request.id
  local event_path
  if path then
    event_path = {}
    for i, p in ipairs(path) do event_path[i] = { position = p } end
  end
  walk.on_path_finished({ id = id, path = event_path, try_again_later = transient })
end

local task = reset()
local exact_radius_ok, exact_radius_error = pcall(walk.start,
  { id = 8, target = { x = 10, y = 0 }, arrival_mode = "exact", arrival_radius = 2 })
check(not exact_radius_ok and tostring(exact_radius_error):match("fixed 1%-tile tolerance"),
  "exact arrival cannot masquerade as a wide vicinity tolerance")
check(walk.step(task._walk, body, task.id) == nil and body.walking_state.walking == false,
  "native walker waits for Factorio's path result")
deliver({ { x = 5, y = 0 }, { x = 10, y = 0 } })
check(walk.step(task._walk, body, task.id) == nil and body.walking_state.walking == true,
  "successful native path drives ordinary walking_state")
body.position = { x = 10, y = 0 }
check(walk.step(task._walk, body, task.id) == "arrived" and body.walking_state.walking == false,
  "native path success finishes at physical position")

-- A legal placement can leave the physical body inside another collision box.
-- Recovery must use ordinary walking to a Factorio-selected nearby clear point
-- before asking the native pathfinder for the requested route.
body.bounding_box = { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } }
found_blockers = { { valid = true, name = "stone-furnace", type = "furnace", position = { x = 0, y = 0 },
  prototype = { collision_mask = { layers = { player = true, object = true } } },
  bounding_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } } } }
body.surface.find_non_colliding_position = function() return { x = -1, y = 0 } end
task = reset()
check(walk.step(task._walk, body, task.id) == nil and task._walk.phase == "escaping"
  and body.walking_state.walking and storage.path_request == nil,
  "start collision begins bounded ordinary-walking escape before pathfinding")
body.position = { x = -1, y = 0 }; body.bounding_box = { left_top = { x = -1.2, y = -0.2 }, right_bottom = { x = -0.8, y = 0.2 } }
found_blockers = {}
check(walk.step(task._walk, body, task.id) == nil and task._walk.phase == "waiting"
  and storage.path_request and storage.path_request.id == 1 and body.walking_state.walking == false,
  "cleared start collision resumes the native pathfinder from the physical position")
deliver({ { x = 4, y = 0 }, { x = 10, y = 0 } })
check(walk.step(task._walk, body, task.id) == nil and body.walking_state.walking,
  "ordinary escape continues with native path traversal")
body.position = { x = 10, y = 0 }; body.bounding_box = nil
check(walk.step(task._walk, body, task.id) == "arrived", "escaped native walk finishes only at the physical goal")
body.bounding_box, body.surface.find_non_colliding_position = nil, nil
found_blockers = {
  { valid = true, name = "stone-furnace", type = "furnace", position = { x = 1, y = 0 } },
}

task = reset()
task._walk.frontier_segments = 3
walk.step(task._walk, body, task.id); deliver(nil, false)
local result = walk.step(task._walk, body, task.id)
check(result and result.failed:match("^GOAL_OCCUPIED:"),
  "no-path result diagnoses a charted occupied exact goal separately")
check(result.outcome.diagnostics.path.recovery.termination_reason == nil, "occupied goals retain their existing classification")
check(result.failed:match("collision segment") and result.failed:match("stone%-furnace:furnace@%(1%.0,0%.0%)")
  and result.failed:match("water") and result.failed:match("inferred visible collision evidence")
  and result.failed:match("not authoritative blockers"),
  "no-path result includes bounded local collision-segment evidence")
check(blocker_filter.collision_mask == prototypes.entity.character.collision_mask.layers,
  "blocker evidence uses the same character collision layers as native pathfinding")
local saw_cage_query = false
for _, filter in ipairs(entity_filters) do
  if filter.area and filter.area.left_top.x == -4 and filter.area.right_bottom.x == 4 then saw_cage_query = true end
end
check(saw_cage_query
  and result.outcome.diagnostics.path.evidence_scope == "charted_visible_only"
  and result.outcome.diagnostics.path.goal_occupancy.state == "occupied",
  "path failure separates bounded charted goal occupancy from the local cage query")

body.surface.find_non_colliding_position = function(_, requested) return requested end
found_blockers, tile_blocks = {}, false
task = reset()
walk.step(task._walk, body, task.id); deliver(nil, false)
check(walk.step(task._walk, body, task.id) == nil and task._walk.phase == "frontier_waiting",
  "no-path begins bounded native frontier probes")
local frontier_result
for _ = 1, 8 do
  local goal = requested_goals[storage.path_request.id]
  local path = { goal }
  if goal.x == 4 and goal.y == 0 then
    path = {}
    for index = 1, 14 do path[index] = { x = goal.x * index / 14, y = goal.y } end
  end
  deliver(path, false)
  frontier_result = walk.step(task._walk, body, task.id)
end
check(frontier_result == nil and task._walk.phase == "frontier_following"
  and task._walk.frontier_segments == 1 and #task._walk.path == 14,
  "no-path recovery selects the best strictly progress-making charted frontier and retains its full native path")
for _, waypoint in ipairs(task._walk.path) do
  body.position = { x = waypoint.x, y = waypoint.y }
  walk.step(task._walk, body, task.id)
end
check(task._walk.phase == "waiting" and storage.path_request ~= nil,
  "physical completion of a frontier segment retries the original resolved goal")
deliver({ { x = 10, y = 0 } }, false)
walk.step(task._walk, body, task.id)
body.position = { x = 10, y = 0 }
check(walk.step(task._walk, body, task.id) == "arrived" and task._walk.frontier_segments == 1,
  "one bounded internal frontier segment can recover the original walk without an external waypoint call")

-- Recovery is finite even while every local frontier continues to improve the
-- goal distance. Each segment is an ordinary native-path walk, followed by a
-- fresh native request to the original resolved goal.
task = reset({ x = 30, y = 0 })
for segment = 1, 3 do
  walk.step(task._walk, body, task.id); deliver(nil, false); walk.step(task._walk, body, task.id)
  for _ = 1, 8 do
    local candidate = requested_goals[storage.path_request.id]
    deliver({ candidate }, false)
    walk.step(task._walk, body, task.id)
  end
  body.position = { x = task._walk.path[#task._walk.path].x, y = task._walk.path[#task._walk.path].y }
  walk.step(task._walk, body, task.id)
end
deliver(nil, false); walk.step(task._walk, body, task.id)
local bounded_failure
for _ = 1, 8 do
  local candidate = requested_goals[storage.path_request.id]
  deliver({ candidate }, false)
  bounded_failure = walk.step(task._walk, body, task.id)
end
check(bounded_failure and bounded_failure.failed:match("^PATH_NOT_FOUND:")
  and bounded_failure.outcome.diagnostics.path.recovery.segments_completed == 3
  and #bounded_failure.outcome.diagnostics.path.recovery.history == 3,
  "monotonic recovery stops after exactly three physical frontier segments")
check(bounded_failure.outcome.diagnostics.path.recovery.termination_reason == "segment_limit_with_progress"
  and bounded_failure.failed:match("admissible native progress")
  and bounded_failure.failed:match("reachability is unproven")
  and task._walk.frontier_segments == 3 and body.walking_state.walking == false,
  "the cap with admissible progress reports its termination reason without another movement")

-- A reached cap alone is insufficient: a found path may lead to a visited
-- point or make no progress. Neither promises an unused recovery segment.
for _, case in ipairs({ { x = 4, visited = true }, { x = -4, visited = false } }) do
  task = reset({ x = 30, y = 0 })
  task._walk.frontier_segments = 3
  if case.visited then task._walk.visited_frontiers["4.00:0.00"] = true end
  body.surface.find_non_colliding_position = function(_, requested)
    if requested.x == case.x and requested.y == 0 then return requested end
  end
  walk.step(task._walk, body, task.id); deliver(nil, false); walk.step(task._walk, body, task.id)
  local denied
  while storage.path_request do
    local candidate = requested_goals[storage.path_request.id]
    deliver({ candidate }, false)
    denied = walk.step(task._walk, body, task.id)
  end
  check(denied and denied.outcome.code == "PATH_NOT_FOUND"
    and denied.outcome.diagnostics.path.recovery.termination_reason == nil
    and not denied.failed:match("admissible native progress"),
    case.visited and "a visited frontier at the cap does not claim admissible progress"
      or "a non-progress frontier at the cap does not claim admissible progress")
end
body.surface.find_non_colliding_position = function(_, requested) return requested end

-- Embedded physical actions preserve the additive diagnosis and failed code.
task = reset({ x = 30, y = 0 })
approach.ensure(task, body, task.target, 2)
task._approach.walk.frontier_segments = 3
deliver(nil, false); approach.ensure(task, body, task.target, 2)
local embedded_cap
for _ = 1, 8 do
  local candidate = requested_goals[storage.path_request.id]
  deliver({ candidate }, false)
  embedded_cap = approach.ensure(task, body, task.target, 2)
end
check(embedded_cap and embedded_cap.status == "failed" and embedded_cap.outcome.code == "PATH_NOT_FOUND"
  and embedded_cap.outcome.diagnostics.path.recovery.termination_reason == "segment_limit_with_progress"
  and embedded_cap.detail:match("couldn't get in range: PATH_NOT_FOUND:"),
  "embedded reach failure retains the cap classification without successful approach")

-- Only A->B and B->A are exposed by this fixture. The remembered starting
-- point and strict goal progress rule prevent the second leg from being used.
task = reset({ x = 10, y = 0 })
body.surface.find_non_colliding_position = function(_, requested)
  if body.position.x == 0 and requested.x == 4 and requested.y == 0 then return requested end
  if body.position.x == 4 and requested.x == 0 and requested.y == 0 then return requested end
  return nil
end
walk.step(task._walk, body, task.id); deliver(nil, false); walk.step(task._walk, body, task.id)
for _ = 1, 8 do
  local request = storage.path_request
  if not request then break end
  local candidate = requested_goals[request.id]
  deliver({ candidate }, false)
  walk.step(task._walk, body, task.id)
end
body.position = { x = 4, y = 0 }; walk.step(task._walk, body, task.id)
deliver(nil, false); walk.step(task._walk, body, task.id)
local cycle_failure
while storage.path_request do
  local candidate = requested_goals[storage.path_request.id]
  deliver({ candidate }, false)
  cycle_failure = walk.step(task._walk, body, task.id)
end
check(cycle_failure and cycle_failure.failed:match("^PATH_NOT_FOUND:")
  and task._walk.frontier_segments == 1 and #task._walk.recovery_history == 1,
  "frontier history terminates an A-B-A recovery cycle without repeating A")

-- Public vicinity mode resolves a charted collision-free point, but completes
-- only after Factorio returns and the character traverses a native path to it.
task = reset({ x = 10, y = 0 })
body.surface.find_non_colliding_position = function(_, requested, radius)
  check(requested.x == 10 and requested.y == 0 and radius == 2,
    "vicinity resolution uses the requested goal and bounded arrival radius")
  return { x = 9, y = 0 }
end
task.arrival_mode, task.arrival_radius = "vicinity", 2
walk.start(task)
walk.tick(task)
deliver({ { x = 9, y = 0 } }, false)
walk.tick(task)
body.position = { x = 9, y = 0 }
local vicinity_done = walk.tick(task)
check(vicinity_done and vicinity_done.status == "done"
  and vicinity_done.outcome.requested_goal.x == 10
  and vicinity_done.outcome.resolved_goal.x == 9
  and vicinity_done.outcome.arrival_mode == "vicinity",
  "vicinity reports distinct requested/resolved goals only after native path success")

task = reset({ x = 10, y = 0 })
body.surface.find_non_colliding_position = function() return nil end
task.arrival_mode, task.arrival_radius = "vicinity", 2
walk.start(task)
local no_vicinity = walk.tick(task)
check(no_vicinity and no_vicinity.outcome.code == "VICINITY_NOT_FOUND"
  and storage.path_request == nil,
  "vicinity fails without requesting a path when no charted collision-free candidate exists")
body.surface.find_non_colliding_position = nil
found_blockers, tile_blocks = { { valid = true, name = "stone-furnace", type = "furnace", position = { x = 1, y = 0 } } }, true

chart_all = false
task = reset({ x = 40, y = 0 })
body.position = { x = 31.9, y = 0 }
entity_queries, tile_queries = 0, 0
local boundary_result = walk.step(task._walk, body, task.id)
check(boundary_result.failed:match("START_COLLISION_UNKNOWN") and entity_queries == 0 and tile_queries == 0,
  "collision evidence makes zero entity or tile queries when its bounded area crosses an uncharted chunk")
chart_all = true

task = reset()
local transient_result
for attempt = 1, 4 do
  walk.step(task._walk, body, task.id)
  deliver(nil, true)
  transient_result = walk.step(task._walk, body, task.id)
  if attempt < 4 then
    game.tick = game.tick + 30
    walk.step(task._walk, body, task.id)
  end
end
check(transient_result and transient_result.failed:match("^PATH_TRANSIENT:")
  and transient_result.failed:match("4 native path attempts"),
  "transient pathfinder replies retry finitely with deterministic diagnostics")

task = reset()
walk.step(task._walk, body, task.id)
game.tick = 300
check(walk.step(task._walk, body, task.id) == nil, "a slow native search still has seconds to answer")
game.tick = 601
result = walk.step(task._walk, body, task.id)
check(result and result.failed == "PATH_TIMEOUT: no native path result arrived within 600 ticks",
  "missing native result times out deterministically")

task = reset()
walk.step(task._walk, body, task.id); deliver({ { x = 1, y = 0 }, { x = 10, y = 0 } })
walk.step(task._walk, body, task.id)
game.tick = 60
check(walk.step(task._walk, body, task.id) == nil and storage.path_request.id == 2,
  "stalled walking requests one fresh native recovery path")
deliver({ { x = 1, y = 0 }, { x = 10, y = 0 } })
walk.step(task._walk, body, task.id)
game.tick = 120
result = walk.step(task._walk, body, task.id)
check(result and result.failed:match("^PATH_STALLED:"),
  "repeated physical stall ends with a deterministic diagnostic")
check(result.failed:match("collision segment") and result.failed:match("stone%-furnace"),
  "stalled path includes the same bounded local blocker evidence")
check(blocker_filter.area.right_bottom.x == 1.5
  and blocker_filter.collision_mask == prototypes.entity.character.collision_mask.layers,
  "stalled evidence uses only the current-waypoint segment and excludes noncolliding entities")

found_blockers, tile_blocks = {}, false
for index = 10, 1, -1 do
  found_blockers[#found_blockers + 1] = {
    valid = true, name = string.format("block-%02d", index), type = index % 2 == 0 and "furnace" or "container",
    position = { x = index / 10, y = 0 },
  }
end
task = reset()
walk.step(task._walk, body, task.id); deliver(nil, false)
local sorted_result = walk.step(task._walk, body, task.id)
local first_block = sorted_result.failed:find("block%-01:container@", 1)
local eighth_block = sorted_result.failed:find("block%-08:furnace@", 1)
check(first_block and eighth_block and first_block < eighth_block
  and not sorted_result.failed:match("block%-09") and not sorted_result.failed:match("block%-10"),
  "collision blockers are deterministically sorted by identity and position before the eight-entry cap")

found_blockers, tile_blocks = {}, false
task = reset()
walk.step(task._walk, body, task.id); deliver(nil, false)
local clear_result = walk.step(task._walk, body, task.id)
check(clear_result.failed:match("no immediate charted blocker identified"),
  "charted collision segment says explicitly when it identifies no immediate blocker")

task = reset()
walk.step(task._walk, body, task.id); deliver({ { x = 0, y = 0 } })
check(walk.step(task._walk, body, task.id) == nil and storage.path_request.id == 2,
  "incomplete native path requests one recovery path")
deliver({ { x = 0, y = 0 } })
result = walk.step(task._walk, body, task.id)
check(result and result.failed:match("^PATH_INCOMPLETE:"),
  "repeated incomplete path fails instead of walking blind")

task = reset({ x = 10, y = 0 })
result = approach.ensure(task, body, task.target, 2)
check(result == nil and storage.path_request.task_id == task.id,
  "embedded approach uses the same native path request")
deliver(nil, false)
result = approach.ensure(task, body, task.target, 2)
check(result and result.status == "failed"
  and result.detail:match("couldn't get in range: PATH_NOT_FOUND:"),
  "embedded approach preserves deterministic native path failure")

-- Real collision metadata separates traversable footprints from physical blockers.
local geometry = require("scripts.placement_geometry")
local function overlap(name, mask, kind)
  return { valid = true, name = name, type = kind or "simple-entity", position = { x = 0, y = 0 },
    prototype = { collision_mask = mask },
    bounding_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } } }
end
for _, example in ipairs({
  overlap("transport-belt", { layers = { object = true, transport_belt = true } }, "transport-belt"),
  overlap("tree-01-stump", { layers = {} }, "corpse"),
}) do
  found_blockers, tile_blocks = { example }, false
  task = reset()
  local evidence = geometry.path_start(body)
  check(evidence.clear and #evidence.collisions == 0, example.name .. " footprint is physically traversable")
  check(walk.step(task._walk, body, task.id) == nil and storage.path_request ~= nil,
    example.name .. " overlap uses native pathfinding without destructive clearance")
end
found_blockers = { overlap("solid-object", { layers = { player = true, object = true } }) }
body.surface.find_non_colliding_position = function() return { x = -1, y = 0 } end
task = reset({ x = 0.1, y = 0 })
check(geometry.path_start(body).state == "blocked" and walk.step(task._walk, body, task.id) == nil
  and task._walk.phase == "escaping" and not storage.path_request,
  "genuine overlap inside arrival tolerance cannot report arrival")
result = until_answer(function() return walk.step(task._walk, body, task.id) end)
check(result and result.failed:match("no physical progress") and not storage.path_request
  and not body.walking_state.walking and game.tick <= 120 and result.outcome.code == "START_COLLISION"
  and #result.outcome.diagnostics.escape_targets == task._walk.escape_index,
  "stationary escape tries each direction once, then terminates with current evidence before any native request")

task = reset({ x = 0.1, y = 0 })
check(approach.ensure(task, body, task.target, 2) == nil and task._approach.walk.phase == "escaping",
  "embedded within-reach approach starts recovery for a pinned body")
local selected = { valid = true, name = "exact-machine", position = { x = 0.1, y = 0 } }
body.can_reach_entity = function(e) return e == selected end
body.reach_distance = 10
check(approach.ensure_entity(task, body, selected) == nil and task._approach.walk.phase == "escaping",
  "native entity reach cannot discard an active uncleared recovery")
found_blockers = {}
check(approach.ensure_entity(task, body, selected) == "ok", "safe native reach remains successful after clearance")
check(task._approach == nil and not body.walking_state.walking,
  "clear native reach retires completed escape state")
game.tick = 120
found_blockers = { overlap("new-solid", { layers = { player = true } }) }
check(approach.ensure(task, body, { x = 3, y = 0 }, 2) == nil and task._approach.walk.phase == "escaping"
  and task._approach.walk.escape_started_tick == 120,
  "a later obstruction obtains fresh escape state after successful recovery")
found_blockers = {}
check(approach.ensure(task, body, { x = 1, y = 0 }, 2) == "ok" and task._approach == nil,
  "clear positional reach retires completed recovery even when the requested target changes")


found_blockers = { overlap("same-mask-body", prototypes.entity.character.collision_mask) }
check(geometry.path_start(body).clear, "identical masks with not_colliding_with_itself do not block")
found_blockers = { overlap("tiles-only", { layers = { player = true }, colliding_with_tiles_only = true }) }
check(geometry.path_start(body).clear, "tiles-only masks do not block another entity")
found_blockers = { overlap("unsupported-mask", nil) }
check(geometry.path_start(body).state == "unknown" and not geometry.path_start(body).clear,
  "missing entity collision metadata cannot prove clearance")
task = reset()
result = walk.step(task._walk, body, task.id)
check(result and result.failed:match("START_COLLISION_UNKNOWN") and not storage.path_request,
  "unknown collision evidence fails with an actionable diagnostic")
found_blockers = {}
tile_blocks = true
body.position = { x = 1, y = 0 }
check(geometry.path_start(body).state == "blocked" and geometry.path_start(body).collisions[1].kind == "tile",
  "terrain collision preserves both pcall return values and blocks the character")
body.position = { x = 0.4, y = 0 }
check(geometry.path_start(body).clear, "tile transitions use the character centre rather than footprint overlap")

found_blockers = { overlap("solid-object", { layers = { player = true } }) }
tile_blocks = false
body.surface.find_non_colliding_position = function(_, requested)
  return requested.x == 0 and { x = -1, y = 0 } or { x = 0.2, y = 0 }
end
task = reset({ x = 0.1, y = 0 })
task.arrival_mode, task.arrival_radius = "vicinity", 2
walk.start(task)
check(walk.tick(task) == nil and task._walk.phase == "escaping" and task._walk.target.x == 0.2
  and not storage.path_request,
  "resolved vicinity proximity cannot finish a genuinely blocked start")
found_blockers = {}
task = reset({ x = 0.1, y = 0 })
check(walk.step(task._walk, body, task.id) == "arrived" and not storage.path_request,
  "an already safely arrived character succeeds without unnecessary native pathfinding")
local tile_query = body.surface.get_tile
body.surface.get_tile = function() error("tile unavailable") end
check(geometry.path_start(body).state == "unknown" and not geometry.path_start(body).clear,
  "failed terrain query cannot prove clearance")
body.surface.get_tile = tile_query
found_blockers = { overlap("selection-only", { layers = { player = true } }) }
found_blockers[1].selection_box, found_blockers[1].bounding_box = found_blockers[1].bounding_box, nil
-- Force this fixture's query to return its selection-overlap candidate, as a
-- real broad-phase query may do; exact collision geometry is still required.
local entity_query = body.surface.find_entities_filtered
body.surface.find_entities_filtered = function() return found_blockers end
check(geometry.path_start(body).state == "unknown" and #geometry.path_start(body).collisions == 0,
  "selection overlap without collision geometry never establishes a physical blocker")
body.surface.find_entities_filtered = entity_query

found_blockers = { overlap("solid-object", { layers = { player = true } }) }
body.surface.find_non_colliding_position = function() return { x = -1, y = 0 } end
task = reset({ x = 3, y = 0 })
approach.ensure(task, body, task.target, 2)
local retained = task._approach
body.surface.find_entities_filtered = function() error("temporary engine query failure") end
game.tick = 30
result = approach.ensure(task, body, { x = 4, y = 0 }, 2)
check(result and result.status == "failed" and result.detail:match("START_COLLISION_UNKNOWN")
  and task._approach == retained and retained.walk.escape_started_tick == 0,
  "unknown evidence cannot discard active recovery or reset its bounded escape timer")
body.surface.find_entities_filtered = entity_query
result = until_answer(function() return approach.ensure(task, body, { x = 4, y = 0 }, 2) end)
check(result and result.detail:match("no physical progress") and retained.walk.escape_failed
  and task._approach == retained and not storage.path_request and not body.walking_state.walking
  and game.tick <= 150,
  "revalidated unchanged recovery fails within its bounded escape directions")

-- Belt settle: a walk or approach never finishes with the body on a conveyor.
-- Conveyors answer only the typed query; collision queries see nothing here.
local belts = {}
body.surface.find_entities_filtered = function(filter)
  if filter.type then return belts end
  return {}
end
body.surface.find_non_colliding_position = nil
body.bounding_box, tile_blocks, chart_all = nil, false, true
local function belt(x, y, w, h)
  return { valid = true, name = "transport-belt", type = "transport-belt", direction = 4,
    position = { x = x + w / 2, y = y + h / 2 },
    bounding_box = { left_top = { x = x, y = y }, right_bottom = { x = x + w, y = y + h } } }
end
belts = { belt(10, 0, 1, 1) }
task = reset({ x = 10.5, y = 0.5 })
walk.start(task)
walk.tick(task); deliver({ { x = 10.5, y = 0.5 } }, false); walk.tick(task)
body.position = { x = 10.5, y = 0.5 }
check(walk.tick(task) == nil and task._walk.phase == "settling" and body.walking_state.walking
  and body.walking_state.direction == defines.direction.north
  and task._walk.settle.to.x == 10.5 and task._walk.settle.to.y == -0.5,
  "arrival on a belt starts one ordinary-walking step to the nearest clear off-belt tile")
body.position = { x = 10.5, y = -0.5 }
local settled = walk.tick(task)
check(settled and settled.status == "done" and settled.outcome.settle
  and settled.outcome.settle.conveyor.name == "transport-belt" and settled.outcome.settle.final.y == -0.5
  and settled.detail:match("stepped off transport%-belt") and body.walking_state.walking == false,
  "walk_to finishes only off the belt and reports the settle step")

belts = { belt(7, -3, 8, 8) }
task = reset({ x = 10.5, y = 0.5 })
walk.start(task)
walk.tick(task); deliver({ { x = 10.5, y = 0.5 } }, false); walk.tick(task)
body.position = { x = 10.5, y = 0.5 }
check(walk.tick(task) == nil and task._walk.phase == "settling" and task._walk.settle.to.y == -3.5,
  "a belt wider than 2 tiles is left toward the nearest clear tile within 4")

belts = { belt(5, -5, 12, 12) }
task = reset({ x = 10.5, y = 0.5 })
walk.start(task)
walk.tick(task); deliver({ { x = 10.5, y = 0.5 } }, false); walk.tick(task)
body.position = { x = 10.5, y = 0.5 }
local covered = walk.tick(task)
check(covered and covered.status == "failed" and covered.detail:match("^BODY_ON_CONVEYOR:")
  and covered.detail:match("within 4 tiles")
  and covered.outcome.diagnostics.path.settle_rejected.conveyor > 0,
  "no off-belt tile within 4 tiles fails truthfully as BODY_ON_CONVEYOR")

belts = { belt(10, 0, 1, 1) }
task = reset({ x = 10.5, y = 0.5 })
walk.start(task)
walk.tick(task); deliver({ { x = 10.5, y = 0.5 } }, false); walk.tick(task)
body.position = { x = 10.5, y = 0.5 }
walk.tick(task)
game.tick = 60
local routed = walk.tick(task) == nil and task._walk.phase == "settling" and task._walk.settle.routed
game.tick = 61
check(routed and walk.tick(task) == nil and task._walk.settle_route and storage.path_request ~= nil
  and requested_goals[2].x == 10.5 and requested_goals[2].y == -0.5,
  "a straight settle step that does not leave the belt in time walks to its tile by a native path")
local stuck
for _ = 1, 8 do
  if storage.path_request then deliver({ { x = 10.5, y = -0.5 } }, false) end
  walk.tick(task)
  game.tick = game.tick + 61
  stuck = walk.tick(task)
  if stuck then break end
end
check(stuck and stuck.status == "failed" and stuck.detail:match("^BODY_ON_CONVEYOR:.*off%-belt tile %(10%.5, %-0%.5%) failed: PATH_STALLED")
  and stuck.outcome.code == "BODY_ON_CONVEYOR",
  "a routed settle that never leaves the belt fails BODY_ON_CONVEYOR within its walk's own bounds")

-- A blocked start (a tree cleared, an escape) cuts the straight step short
-- and the walk asks for its path again, ending on the belt: the settle's tile
-- is walked to by its native path before the walk fails BODY_ON_CONVEYOR.
-- Here a furnace placed over the body mid-step starts an escape.
local obstacles = {}
body.surface.find_entities_filtered = function(filter)
  if filter.type then return belts end
  local out = {}
  for _, e in ipairs(obstacles) do
    local box, area = e.bounding_box, filter.area
    if not area or (box.left_top.x < area.right_bottom.x and box.right_bottom.x > area.left_top.x
      and box.left_top.y < area.right_bottom.y and box.right_bottom.y > area.left_top.y) then
      out[#out + 1] = e
    end
  end
  return out
end
belts = { belt(10, 0, 1, 1) }
task = reset({ x = 10.5, y = 0.5 })
walk.start(task)
walk.tick(task); deliver({ { x = 10.5, y = 0.5 } }, false); walk.tick(task)
body.position = { x = 10.5, y = 0.5 }
walk.tick(task)
local cut = task._walk.phase == "settling" and not task._walk.settle.routed
obstacles = { { valid = true, name = "stone-furnace", type = "furnace", position = { x = 10.5, y = 0.5 },
  prototype = { collision_mask = { layers = { player = true, object = true } } },
  bounding_box = { left_top = { x = 10.1, y = 0.1 }, right_bottom = { x = 10.9, y = 0.9 } } } }
check(cut and walk.tick(task) == nil and task._walk.phase == "escaping",
  "a start blocked during the straight settle step begins an escape")
body.position = { x = 10.5, y = -1.5 }
obstacles = {}
check(walk.tick(task) == nil and task._walk.phase == "waiting" and storage.path_request ~= nil,
  "the cleared escape asks for the walk's path again")
deliver({ { x = 10.5, y = 0.5 } }, false); walk.tick(task)
body.position = { x = 10.5, y = 0.5 }
check(walk.tick(task) == nil and task._walk.phase == "settling" and task._walk.settle.routed
  and task._walk.settle_route and task._walk.settle_route.path_radius < 0.3,
  "a walk back on the belt after its straight settle step was cut short walks to the tile by a native path")
local asked = walk.tick(task) == nil and storage.path_request ~= nil
check(asked and requested_goals[next_path_id].x == 10.5 and requested_goals[next_path_id].y == -0.5,
  "that native path goes to the settle's own off-belt tile")

-- The off-belt tile sits on the edge of the target's reach. The native path
-- stops within its radius of it, off the belt but just out of reach, and
-- something unseen blocks the last straight step: the walk fails PATH_STALLED
-- saying the body left the belt, never BODY_ON_CONVEYOR.
local edge = math.sqrt(5)
task = reset({ x = 12.5, y = 0.5 })
body.position = { x = 10.5, y = 0.5 }
check(approach.ensure(task, body, { x = 12.5, y = 0.5 }, edge) == nil
  and task._approach.walk.settle.to.x == 10.5 and task._approach.walk.settle.to.y == -0.5,
  "an approach on a belt settles to an off-belt tile on the edge of its reach")
game.tick = 60
approach.ensure(task, body, { x = 12.5, y = 0.5 }, edge)
game.tick = 61
approach.ensure(task, body, { x = 12.5, y = 0.5 }, edge)
check(task._approach.walk.settle.routed and storage.path_request ~= nil,
  "its timed-out straight step asks for a native path to the tile")
deliver({ { x = 10.3, y = -0.4 } }, false)
body.position = { x = 10.3, y = -0.4 }
local edge_result
for _ = 1, 3 do
  edge_result = approach.ensure(task, body, { x = 12.5, y = 0.5 }, edge)
  if edge_result then break end
  game.tick = game.tick + 61
end
check(type(edge_result) == "table" and edge_result.status == "failed"
  and edge_result.outcome.code == "PATH_STALLED" and edge_result.detail:match("stepped off transport%-belt")
  and edge_result.detail:match("beyond reach") and not edge_result.detail:match("did not leave"),
  "a body off the belt but just out of reach fails PATH_STALLED, not BODY_ON_CONVEYOR: "
    .. tostring(type(edge_result) == "table" and edge_result.detail))
body.surface.find_entities_filtered = function(filter)
  if filter.type then return belts end
  return {}
end

task = reset({ x = 12.5, y = 0.5 })
body.position = { x = 10.5, y = 0.5 }
check(approach.ensure(task, body, { x = 12.5, y = 0.5 }, 2.5) == nil and task._approach
  and task._approach.walk.phase == "settling" and task._approach.walk.settle.to.y == -0.5,
  "an in-reach approach on a belt settles to an off-belt tile still within reach")
body.position = { x = 10.5, y = -0.5 }
check(approach.ensure(task, body, { x = 12.5, y = 0.5 }, 2.5) == "ok" and task._approach == nil,
  "the approach succeeds once the body is off the belt and in reach")

-- A wide belt bundle: the nearest off-belt tile is 6 tiles away and within
-- build reach of the target. The approach's ring out to 8 finds it, checking
-- only cells the rings within 4 did not, a capped number a tick (the ring
-- holds about 150), and allows the longer walk its time.
belts = { belt(5, -5, 12, 12) }
task = reset({ x = 10.5, y = 0.5 })
body.position = { x = 10.5, y = 0.5 }
local belt_queries = 0
body.surface.find_entities_filtered = function(filter)
  if filter.type then belt_queries = belt_queries + 1; return belts end
  return {}
end
local wide_ticks, wide_most, wide_total, wide_answer = 0, 0, 0, nil
repeat
  belt_queries = 0
  wide_answer = approach.ensure(task, body, { x = 10.5, y = 0.5 }, 10)
  wide_ticks, wide_most, wide_total = wide_ticks + 1, math.max(wide_most, belt_queries), wide_total + belt_queries
until wide_answer ~= nil or not task._approach or task._approach.walk.phase ~= "settle_search" or wide_ticks > 10
check(wide_answer == nil and task._approach
  and task._approach.walk.phase == "settling" and task._approach.walk.settle.to.y == -5.5
  and task._approach.walk.settle.to.x == 10.5 and wide_total < 130 -- 112; 174 rechecking the inner rings
  and wide_ticks > 1 and wide_most <= 52,
  string.format("an approach on a wide belt bundle settles to the off-belt tile 6 tiles away, still within reach,"
    .. " over %d ticks of at most %d belt checks (%d in all)", wide_ticks, wide_most, wide_total))
game.tick = 60
body.position = { x = 10.5, y = -3.5 }
check(approach.ensure(task, body, { x = 10.5, y = 0.5 }, 10) == nil and task._approach.walk.phase == "settling",
  "a longer settle step keeps walking past the 4-tile allowance")
body.position = { x = 10.5, y = -5.5 }
check(approach.ensure(task, body, { x = 10.5, y = 0.5 }, 10) == "ok" and task._approach == nil,
  "the approach succeeds once the body has left the bundle")

-- Belts cover the whole reach: the search past the rings checks a fixed
-- number of tiles a tick (never the ~320 at once) and then fails truthfully.
belts = { belt(-20, -20, 60, 60) }
task = reset({ x = 10.5, y = 0.5 })
body.position = { x = 10.5, y = 0.5 }
belt_queries = 0
body.surface.find_entities_filtered = function(filter)
  if filter.type then belt_queries = belt_queries + 1; return belts end
  return {}
end
-- The first tick checks the rings out to 4, the next ones the ring out to 8
-- and then the rest of the reach, a fixed number of tiles a tick.
local answer = approach.ensure(task, body, { x = 10.5, y = 0.5 }, 10)
local most, searched = 0, 0
local first = answer == nil and task._approach.walk.phase == "settle_search"
for _ = 1, 20 do
  belt_queries = 0
  answer = approach.ensure(task, body, { x = 10.5, y = 0.5 }, 10)
  searched, most = searched + 1, math.max(most, belt_queries)
  if answer then break end
end
check(first and type(answer) == "table" and answer.outcome.code == "BODY_ON_CONVEYOR"
  and answer.detail:match("anywhere within reach %(10%.0 tiles%) of the target") and searched >= 3 and most <= 50,
  string.format("belts over the whole reach fail BODY_ON_CONVEYOR after %d search ticks of at most %d belt checks each",
    searched, most))
body.surface.find_entities_filtered = function(filter)
  if filter.type then return belts end
  return {}
end
belts = {}

-- Frontier probes: each records why it failed, one transient reply is
-- re-requested once, and ring 2 follows an empty ring 1. Only refusals the
-- pathfinder answered prove an enclosure, which names an owned collider on
-- the line toward the target for owned mining; an inconclusive probe keeps
-- PATH_NOT_FOUND with the probe reasons.
local owned = { valid = true, name = "wooden-chest", type = "container", force = body.force, position = { x = 1, y = 0 } }
local behind = { valid = true, name = "iron-chest", type = "container", force = body.force, position = { x = -0.5, y = -0.5 } }
local colliders = { owned, behind }
body.surface.find_entities_filtered = function(filter)
  if filter.type or not filter.area then return {} end
  local a, found = filter.area, {}
  for _, entity in ipairs(colliders) do
    if entity.position.x >= a.left_top.x and entity.position.x <= a.right_bottom.x
      and entity.position.y >= a.left_top.y and entity.position.y <= a.right_bottom.y then found[#found + 1] = entity end
  end
  return found
end
body.surface.find_non_colliding_position = function(_, requested) return requested end
task = reset({ x = 10, y = 0 })
walk.step(task._walk, body, task.id); deliver(nil, false)
check(walk.step(task._walk, body, task.id) == nil and task._walk.phase == "frontier_waiting",
  "no-path begins the first frontier ring")
local first_request = storage.path_request.id
deliver(nil, true); walk.step(task._walk, body, task.id)
check(task._walk.phase == "frontier_retry_wait" and task._walk.frontier_probes[1].retried,
  "a transient frontier reply waits for one bounded re-request")
game.tick = game.tick + 30
walk.step(task._walk, body, task.id)
check(task._walk.phase == "frontier_waiting" and storage.path_request.id ~= first_request
  and requested_goals[storage.path_request.id].x == requested_goals[first_request].x,
  "the same frontier probe is re-requested exactly once")
deliver(nil, true); walk.step(task._walk, body, task.id)
check(task._walk.frontier_probes[1].reason == "transient" and task._walk.frontier_index == 2,
  "a second transient reply is recorded and the next probe proceeds")
local function exhaust()
  local result
  while storage.path_request do
    deliver(nil, false)
    result = walk.step(task._walk, body, task.id)
  end
  return result, result and result.outcome and result.outcome.diagnostics.path
end
task._walk.frontier_segments = 3
local unproven, unproven_path = exhaust()
check(unproven and unproven.failed:match("^PATH_NOT_FOUND:") and unproven_path.suggested_recovery == nil
  and #unproven_path.frontier_probes == 16 and unproven_path.frontier_probes[1].reason == "transient",
  "an empty frontier list with an inconclusive probe stays PATH_NOT_FOUND and names no blocker to mine")
check(unproven_path.recovery.termination_reason == nil, "inconclusive probes at the cap do not claim native progress")
task = reset({ x = 10, y = 0 })
walk.step(task._walk, body, task.id); deliver(nil, false); walk.step(task._walk, body, task.id)
task._walk.frontier_segments = 3
local enclosed, enclosed_path = exhaust()
local ring_two, ring_two_at_8 = 0, 0
for _, probe in ipairs(enclosed_path and enclosed_path.frontier_probes or {}) do
  if probe.ring == 2 then
    ring_two = ring_two + 1
    if math.max(math.abs(probe.requested.x), math.abs(probe.requested.y)) == 8 then ring_two_at_8 = ring_two_at_8 + 1 end
  end
end
check(enclosed and enclosed.failed:match("^BODY_ENCLOSED:") and enclosed_path.failure_class == "PATH_NOT_FOUND"
  and #enclosed_path.frontier_probes == 16 and ring_two == 8 and ring_two_at_8 == 8
  and enclosed_path.frontier_probes[16].reason == "path_failed"
  and enclosed_path.suggested_recovery.tool == nil and enclosed_path.suggested_recovery.target_kind == nil
  and enclosed_path.suggested_recovery.expected_name == "wooden-chest" and enclosed_path.suggested_recovery.x == 1,
"refused probes in both rings prove an enclosure that names the owned blocker toward the target, not a nearer one behind,"
    .. " and no tool to mine it")
check(enclosed_path.recovery.termination_reason == nil, "a proven enclosure at the cap keeps its enclosure meaning")
-- What reaches the bot names the blocker and says the automatic step-out
-- failed or was not possible; it never tells the bot to mine part of a line.
check(enclosed.failed:match("the automatic step%-out through the owned wooden%-chest at %(1%.0,") ~= nil
  and enclosed_path.suggested_recovery.hint:match("automatic step%-out through this wooden%-chest .*failed or was not possible") ~= nil
  and not enclosed.failed:lower():match("mine owned") and not enclosed.failed:match("open a route")
  and not enclosed_path.suggested_recovery.hint:lower():match("mine this"),
  "an enclosure names its blocker and says the automatic step-out failed, not to mine it")
-- A dense build sorts more than the 16 reported colliders ahead of the one on
-- the line; the suggestion still comes from every collider found.
for index = 1, 16 do
  colliders[#colliders + 1] = { valid = true, name = "stone-furnace", type = "furnace", force = body.force,
    position = { x = -4 + (index - 1) % 8, y = index <= 8 and -3 or -2 } }
end
task = reset({ x = 10, y = 0 })
walk.step(task._walk, body, task.id); deliver(nil, false); walk.step(task._walk, body, task.id)
local dense, dense_path = exhaust()
check(dense and dense.failed:match("^BODY_ENCLOSED:") and dense_path.suggested_recovery.expected_name == "wooden-chest"
  and dense_path.suggested_recovery.x == 1 and #dense_path.owned_collision_candidates == 16,
  "a dense enclosure still names the owned blocker toward the target beyond the 16 reported colliders")

os.exit(failures == 0 and 0 or 1)
