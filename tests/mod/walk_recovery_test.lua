-- Offline tests for the walker's own recoveries (scripts/actions/walk.lua):
-- a vicinity walk ends anywhere within arrival_radius of the requested goal,
-- a start on the water edge escapes to a tile centre whose body box touches
-- no water, and a tree blocking the start is mined from where the body
-- stands. The world is a small grid of tiles and boxed entities.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.defines = {
  direction = { north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14 },
}
local character_box = { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } }
_G.prototypes = { entity = { character = { collision_mask = { layers = { player = true } }, collision_box = character_box } } }

local water = function() return false end
local entities = {}
local next_path, requested, non_colliding_calls = 0, {}, 0
local function overlaps(a, b)
  return a.left_top.x < b.right_bottom.x and a.right_bottom.x > b.left_top.x
    and a.left_top.y < b.right_bottom.y and a.right_bottom.y > b.left_top.y
end
local function listed(filter, value)
  if filter == nil then return true end
  if type(filter) == "string" then return filter == value end
  for _, v in ipairs(filter) do if v == value then return true end end
  return false
end
local body
body = {
  valid = true, name = "character", position = { x = 0.5, y = 0.5 }, walking_state = {}, mining_state = {},
  force = { is_chunk_charted = function() return true end },
  surface = {
    request_path = function(options) next_path = next_path + 1; requested[next_path] = options.goal; return next_path end,
    get_tile = function(x, y)
      local wet = water(math.floor(x), math.floor(y))
      return { name = wet and "water" or "grass", collides_with = function(layer) return layer == "player" and wet end }
    end,
    find_entities_filtered = function(filter)
      local out = {}
      for _, e in ipairs(entities) do
        local ok = e.valid and listed(filter.type, e.type) and listed(filter.name, e.name)
        if ok and filter.area then ok = overlaps(filter.area, e.bounding_box) end
        if ok and filter.position then
          local dx, dy = e.position.x - filter.position.x, e.position.y - filter.position.y
          ok = dx * dx + dy * dy <= filter.radius * filter.radius
        end
        if ok then out[#out + 1] = e end
        if filter.limit and #out >= filter.limit then break end
      end
      return out
    end,
    find_non_colliding_position = function(_, goal)
      non_colliding_calls = non_colliding_calls + 1
      return { x = goal.x - 1, y = goal.y }
    end,
  },
}
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
local walk = require("scripts.actions.walk")

local function begin(target, mode, radius)
  next_path, requested, non_colliding_calls = 0, {}, 0
  _G.game = { tick = 0 }
  local task = { id = 3, target = target, arrival_mode = mode, arrival_radius = radius }
  _G.storage = { tasks = { active = task } }
  walk.start(task)
  return task
end
local function deliver(path)
  local event_path = {}
  for i, p in ipairs(path) do event_path[i] = { position = p } end
  walk.on_path_finished({ id = storage.path_request.id, path = event_path })
end

-- A vicinity walk whose path ends short of the resolved point but inside
-- the radius the caller asked for has arrived (no PATH_INCOMPLETE retry).
local vicinity = begin({ x = 10.5, y = 0.5 }, "vicinity", 3)
check(walk.tick(vicinity) == nil and storage.path_request ~= nil and requested[1].x == 9.5,
  "a vicinity walk resolves a free point and asks the pathfinder for it")
deliver({ { x = 5, y = 0.5 }, { x = 8, y = 0.5 } })
walk.tick(vicinity)
body.position = { x = 8, y = 0.5 }
local arrived = walk.tick(vicinity)
check(arrived and arrived.status == "done" and arrived.outcome.arrival_radius == 3,
  "a vicinity walk 1.5 tiles short of its resolved point but 2.5 from the goal has arrived")
body.position = { x = 0.5, y = 0.5 }
local already = begin({ x = 2.5, y = 0.5 }, "vicinity", 3)
local at_once = walk.tick(already)
check(at_once and at_once.status == "done" and next_path == 0,
  "a body already within arrival_radius of the goal arrives without a path request")
local exact = begin({ x = 8.5, y = 0.5 }, "exact", 1)
walk.tick(exact); deliver({ { x = 6, y = 0.5 } }); walk.tick(exact)
body.position = { x = 6, y = 0.5 }
check(walk.tick(exact) == nil and exact._walk.recoveries == 1, "an exact walk still needs its 1-tile tolerance")

-- Water edge: the box overlaps a water tile. The escape aims at the nearest
-- tile centre whose whole box is dry, not a point a tenth of a tile away.
water = function(x) return x >= 2 end
body.position = { x = 2.05, y = 0.5 }
local edge = begin({ x = -10.5, y = 0.5 }, "exact", 1)
check(walk.tick(edge) == nil and edge._walk.phase == "escaping" and edge._walk.escape_target.x == 1.5
  and edge._walk.escape_target.y == 0.5 and non_colliding_calls == 0 and body.walking_state.walking
  and body.walking_state.direction == defines.direction.west,
  "a water-edge start walks to the nearest dry tile centre")
body.position = { x = 1.7, y = 0.5 }
check(walk.tick(edge) == nil and edge._walk.phase == "waiting" and storage.path_request ~= nil,
  "once the box is dry the walk asks for its path")
water = function() return false end

-- A tree overlapping the body at the start is mined from where it stands,
-- once; then the walk goes on.
local tree = { valid = true, name = "tree-01", type = "tree", position = { x = 0.5, y = 0.5 },
  bounding_box = { left_top = { x = 0.2, y = 0.2 }, right_bottom = { x = 0.8, y = 0.8 } },
  prototype = { collision_mask = { layers = { player = true } }, mineable_properties = { minable = true } } }
entities = { tree }
local clears, mining_ticks = {}, 0
walk.start_clearer = {
  start = function(task) clears[#clears + 1] = task end,
  tick = function()
    mining_ticks = mining_ticks + 1
    if mining_ticks < 3 then return nil end
    tree.valid = false
    return { status = "done", detail = "mined tree-01" }
  end,
}
body.position = { x = 0.7, y = 0.5 }
local wooded = begin({ x = 10.5, y = 0.5 }, "exact", 1)
check(walk.tick(wooded) == nil and wooded._walk.phase == "clearing" and #clears == 1 and clears[1].entity == tree
  and clears[1].from_here and not body.walking_state.walking and storage.path_request == nil,
  "a tree blocking the start is mined from where the body stands, before any path")
walk.tick(wooded); walk.tick(wooded)
check(walk.tick(wooded) == nil and wooded._walk.phase == "waiting" and storage.path_request ~= nil
  and wooded._walk.start_cleared.name == "tree-01" and wooded._walk.start_cleared.status == "done",
  "once the tree is gone the walk asks for its path")
deliver({ { x = 10.5, y = 0.5 } }); walk.tick(wooded)
body.position = { x = 10.5, y = 0.5 }
local cleared = walk.tick(wooded)
check(cleared and cleared.status == "done" and cleared.outcome.start_cleared.name == "tree-01",
  "the result names the tree it cleared")
tree.valid = true
walk.start_clearer.tick = function() return { status = "failed", detail = "inventory full" } end
body.position = { x = 0.7, y = 0.5 }
local stuck = begin({ x = 10.5, y = 0.5 }, "exact", 1)
walk.tick(stuck)
check(walk.tick(stuck) == nil and stuck._walk.clear_attempted and stuck._walk.phase == "escaping" and #clears == 2,
  "a tree that cannot be mined is tried once, then the body escapes it")
walk.start_clearer = nil

-- Steering keeps one direction until the body strays off the leg's straight
-- line, then switches to the neighbour that heads back: a leg between two of
-- the eight directions is a few long runs inside the planned corridor, not a
-- per-tick zig-zag and not an L-shaped detour off it.
do
  local unit = {}
  for name, angle in pairs({ north = 0, northeast = 45, east = 90, southeast = 135, south = 180, southwest = 225, west = 270, northwest = 315 }) do
    unit[defines.direction[name]] = { x = math.sin(math.rad(angle)), y = -math.cos(math.rad(angle)) }
  end
  for _, goal in ipairs({ { x = 10, y = 3 }, { x = 6, y = 2.5 }, { x = 3, y = 10 }, { x = -7, y = -4 }, { x = 20, y = 7 }, { x = 0, y = -9 } }) do
    local state, pos, last, changes, ticks, drift = {}, { x = 0, y = 0 }, nil, 0, 0, 0
    local len = math.sqrt(goal.x ^ 2 + goal.y ^ 2)
    while (pos.x - goal.x) ^ 2 + (pos.y - goal.y) ^ 2 > 0.25 and ticks < 600 do
      local d = walk.steer(state, pos, goal)
      if last and d ~= last then changes = changes + 1 end
      last, ticks = d, ticks + 1
      pos = { x = pos.x + unit[d].x * 0.15, y = pos.y + unit[d].y * 0.15 }
      drift = math.max(drift, math.abs(goal.x * pos.y - goal.y * pos.x) / len)
    end
    check(ticks < 600 and drift <= 0.45 and changes <= 0.7 * len, string.format(
      "steering to (%g, %g) arrives in %d ticks, %d direction changes, %.2f tiles off the line",
      goal.x, goal.y, ticks, changes, drift))
  end
end

-- A belt carrying the body sideways, or a shove off a straight leg, never
-- makes it miss the waypoint and walk on past it; a body pinned in place
-- tries the other direction once, not every tick.
do
  local unit = {}
  for name, angle in pairs({ north = 0, northeast = 45, east = 90, southeast = 135, south = 180, southwest = 225, west = 270, northwest = 315 }) do
    unit[defines.direction[name]] = { x = math.sin(math.rad(angle)), y = -math.cos(math.rad(angle)) }
  end
  local function arrives(goal, push, start)
    local state, pos, ticks = {}, start or { x = 0, y = 0 }, 0
    while (pos.x - goal.x) ^ 2 + (pos.y - goal.y) ^ 2 > 0.25 do
      if ticks >= 600 then return false end
      local d = walk.steer(state, pos, goal)
      local p = push(pos)
      pos = { x = pos.x + unit[d].x * 0.15 + p.x, y = pos.y + unit[d].y * 0.15 + p.y }
      ticks = ticks + 1
    end
    return true
  end
  local misses = 0
  for _, goal in ipairs({ { x = 9.5, y = 0 }, { x = 12, y = 0 }, { x = 12, y = 0.3 }, { x = 10, y = 3 }, { x = 7, y = -2 } }) do
    -- Perpendicular blue belts every third tile carry the body south.
    local belts = function(p) return { x = 0, y = (math.floor(p.x) % 3 == 1) and 0.094 or 0 } end
    if not arrives(goal, belts) then misses = misses + 1 end
  end
  check(misses == 0, string.format("%d of 5 legs across fast belts missed their waypoint", misses))
  local function shove(at, by)
    local done = false
    return function(p)
      if done or p.x < at then return { x = 0, y = 0 } end
      done = true
      return by
    end
  end
  check(arrives({ x = 10, y = 0 }, shove(4, { x = 0, y = 0.6 }))
    and arrives({ x = 10, y = 0 }, shove(9.6, { x = 1.5, y = 0.2 })),
    "a body shoved off a straight leg, or past its waypoint, turns back to it")
  local state, pos, flips, last = {}, { x = 0, y = 0 }, 0, nil
  for _ = 1, 60 do
    local d = walk.steer(state, pos, { x = 10, y = 3 })
    if last and d ~= last then flips = flips + 1 end
    last = d
  end
  check(flips <= 1, string.format("a pinned body changed direction %d times in 60 ticks", flips))
end

-- An escape that makes no progress toward one target walks the next target's
-- own direction, never the blocked one it held before.
-- Water fills x >= 2 except row 0, so every escape target lies west-ish and
-- the body is held in place: each retry must walk its own target's bearing.
water = function(x, y) return x >= 2 and y ~= 0 end
body.position = { x = 2.3, y = 0.9 }
local blocked = begin({ x = -10.5, y = 0.5 }, "exact", 1)
walk.tick(blocked)
local seen, matches = 0, true
for _ = 1, 8 do
  local w = blocked._walk
  if w.phase ~= "escaping" or not body.walking_state.walking then break end
  seen = seen + 1
  matches = matches and body.walking_state.direction == walk.direction_toward(body.position, w.escape_target)
  game.tick = game.tick + 31
  walk.tick(blocked)
end
check(seen >= 2 and matches, string.format("each of %d stuck escape retries walks toward its own target", seen))
water = function() return false end

-- Narrow gaps. The native pathfinder plans with a 0.2 path box, so its
-- route may run through a gap barely wider than the body. The body moves
-- in eight directions, 0.15 tiles a tick, and never into a collider (as in
-- the game, which does not slide it along the face it meets). Turning for
-- the next leg half a tile before the gap's mouth waypoint cut the corner
-- into the gap's side, and the walk stalled there.
do
  local VECTORS = { [0] = { 0, -1 }, [2] = { 1, -1 }, [4] = { 1, 0 }, [6] = { 1, 1 }, [8] = { 0, 1 },
    [10] = { -1, 1 }, [12] = { -1, 0 }, [14] = { -1, -1 } }
  local function collider(name, kind, x1, y1, x2, y2, minable)
    return { valid = true, name = name, type = kind, position = { x = (x1 + x2) / 2, y = (y1 + y2) / 2 },
      bounding_box = { left_top = { x = x1, y = y1 }, right_bottom = { x = x2, y = y2 } },
      prototype = { collision_mask = { layers = { player = true } }, mineable_properties = { minable = minable } } }
  end
  -- Walks from `start` along the native `path` (every request gets it) and
  -- returns the walk's result.
  local function through(start, goal, path, colliders)
    entities = colliders
    body.position = { x = start.x, y = start.y }
    local task = begin(goal, "exact", 1)
    for _ = 1, 1500 do
      game.tick = game.tick + 1
      if storage.path_request then deliver(path) end
      local result = walk.tick(task)
      if result then return result, task end
      local state = body.walking_state
      if state.walking then
        local v = VECTORS[state.direction]
        local k = (v[1] ~= 0 and v[2] ~= 0) and 0.15 / math.sqrt(2) or 0.15
        local to = { x = body.position.x + v[1] * k, y = body.position.y + v[2] * k }
        local moved = { left_top = { x = to.x - 0.2, y = to.y - 0.2 }, right_bottom = { x = to.x + 0.2, y = to.y + 0.2 } }
        local free = true
        for _, e in ipairs(entities) do
          if e.valid and overlaps(moved, e.bounding_box) then free = false end
        end
        if free then body.position = to end
      end
    end
    return { status = "timeout" }, task
  end
  walk.start_clearer = nil
  -- Two huge rocks 0.6 tiles apart; the route enters the gap from the
  -- north-west at its mouth waypoint.
  local rocks = { collider("huge-rock", "simple-entity", -3, -1, 0, 1, true),
    collider("huge-rock", "simple-entity", 0.6, -1, 3.6, 1, true) }
  local result = through({ x = -4.5, y = -6 }, { x = 4, y = 5 },
    { { x = 0.3, y = -1.3 }, { x = 0.3, y = 1.3 }, { x = 4, y = 5 } }, rocks)
  check(result.status == "done", "a walk through a 0.6-tile gap between two rocks arrives: "
    .. tostring(result.detail))
  -- A lab and a tree 0.6 tiles apart, on a route of tile-spaced waypoints.
  local lab = collider("lab", "lab", -2.4, -1.2, 0, 1.2, false)
  lab.force = body.force
  result = through({ x = -4.5, y = -6 }, { x = 4, y = 5 },
    { { x = -3.5, y = -5 }, { x = -2.5, y = -4 }, { x = -1.5, y = -3 }, { x = -0.5, y = -2 }, { x = 0.3, y = -1.5 },
      { x = 0.3, y = -0.5 }, { x = 0.3, y = 0.5 }, { x = 0.3, y = 1.5 }, { x = 1.3, y = 2.5 }, { x = 4, y = 5 } },
    { lab, collider("tree-01", "tree", 0.6, -0.4, 1.4, 0.4, true) })
  check(result.status == "done", "a walk between a lab and a tree 0.6 tiles apart arrives: " .. tostring(result.detail))

  -- A gap too tight for eight walking directions (0.45 tiles: the body's
  -- centre must hold within 0.025 of its middle): the stalled body mines the
  -- rock ahead of it once, from where it stands, and walks on.
  local mined = {}
  walk.start_clearer = {
    start = function(task) mined[#mined + 1] = task.entity; task.ticks = 0 end,
    tick = function(task)
      task.ticks = task.ticks + 1
      if task.ticks < 3 then return nil end
      task.entity.valid = false
      return { status = "done", detail = "mined " .. task.entity.name }
    end,
  }
  rocks = { collider("huge-rock", "simple-entity", -3, -1, 0.075, 1, true),
    collider("huge-rock", "simple-entity", 0.525, -1, 3.6, 1, true) }
  local task
  result, task = through({ x = -4.5, y = -6 }, { x = 4, y = 5 },
    { { x = 0.3, y = -1.3 }, { x = 0.3, y = 1.3 }, { x = 4, y = 5 } }, rocks)
  check(result.status == "done" and #mined == 1 and result.outcome.stall_cleared
    and result.outcome.stall_cleared.name == "huge-rock" and result.outcome.stall_cleared.status == "done",
    "a walk stalled at a rock gap it cannot thread mines the rock once and arrives: " .. tostring(result.detail))
  -- A tree beside the stalled body (nearer than the rock, and on the leg's
  -- side of it) is not in the way: only the rock the next leg runs into is
  -- mined, and the walk arrives with the tree still standing.
  mined = {}
  local tree = collider("tree-01", "tree", 0.55, -1.3, 0.95, -1.0, true)
  rocks = { collider("huge-rock", "simple-entity", -3, -1, 0.075, 1, true),
    collider("huge-rock", "simple-entity", 0.525, -1, 3.6, 1, true), tree }
  result, task = through({ x = -4.5, y = -6 }, { x = 4, y = 5 },
    { { x = 0.3, y = -1.3 }, { x = 0.3, y = 1.3 }, { x = 4, y = 5 } }, rocks)
  check(result.status == "done" and #mined == 1 and mined[1].name == "huge-rock" and tree.valid,
    "a stalled walk mines the rock ahead of its next leg, not the tree beside it: " .. tostring(result.detail)
      .. " mined " .. tostring(mined[1] and mined[1].name))
  -- An owned building is never mined: the stall fails truthfully.
  mined = {}
  local left, right = collider("stone-wall", "wall", -3, -1, 0.075, 1, true),
    collider("stone-wall", "wall", 0.525, -1, 3.6, 1, true)
  left.force, right.force = body.force, body.force
  result = through({ x = -4.5, y = -6 }, { x = 4, y = 5 },
    { { x = 0.3, y = -1.3 }, { x = 0.3, y = 1.3 }, { x = 4, y = 5 } }, { left, right })
  check(result.status == "failed" and result.detail:match("^PATH_STALLED") and #mined == 0,
    "a stall between owned buildings mines nothing and fails PATH_STALLED")
  walk.start_clearer = nil
  entities = {}
end
os.exit(failures == 0 and 0 or 1)
