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

-- Steering holds its direction while the bearing stays near it: a leg
-- between two of the eight directions becomes one straight run and one
-- diagonal run instead of a per-tick zig-zag.
do
  local unit = {}
  for name, angle in pairs({ north = 0, northeast = 45, east = 90, southeast = 135, south = 180, southwest = 225, west = 270, northwest = 315 }) do
    unit[defines.direction[name]] = { x = math.sin(math.rad(angle)), y = -math.cos(math.rad(angle)) }
  end
  for _, goal in ipairs({ { x = 10, y = 3 }, { x = 6, y = 2.5 }, { x = 3, y = 10 }, { x = -7, y = -4 } }) do
    local state, pos, last, changes, ticks = {}, { x = 0, y = 0 }, nil, 0, 0
    while (pos.x - goal.x) ^ 2 + (pos.y - goal.y) ^ 2 > 0.25 and ticks < 400 do
      local d = walk.steer(state, pos, goal)
      if last and d ~= last then changes = changes + 1 end
      last, ticks = d, ticks + 1
      pos = { x = pos.x + unit[d].x * 0.15, y = pos.y + unit[d].y * 0.15 }
    end
    check(changes <= 2 and ticks < 400, string.format(
      "steering to (%g, %g) arrives with %d direction changes in %d ticks", goal.x, goal.y, changes, ticks))
  end
end
os.exit(failures == 0 and 0 or 1)
