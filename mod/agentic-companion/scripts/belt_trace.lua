-- Belt lanes and belt traces.
--
-- A belt-like entity has numbered transport lines: odd indexes are its left
-- lane and even its right, seen along the belt's direction
-- (defines.transport_line, checked on 2.0.77: an underground belt's 3 and 4
-- are its underground part, a splitter's 1-4 its two inputs and 5-8 its two
-- outputs), and each line's get_contents is that entity's part.
--
-- A trace walks entities, not lines: in 2.0 LuaTransportLine.input_lines and
-- output_lines describe the merged segment a line belongs to (a straight run
-- reports only its segment's ends), so the walk follows belt_neighbours and
-- underground pairs (neighbours) and maps lanes as the game moves items
-- (checked on 2.0.77): straight, curved, splitter and underground joins keep
-- left on left and right on right; a belt, splitter or loader joining from
-- the side puts both its lanes onto the receiver's lane on that side. Onto
-- an underground belt only the feeder lane over the open half passes (the
-- back half of an entrance, the front half of an exit); the hood holds the
-- other lane back.
--
--   lanes(entity)                   {left = {item = count}, right = ...}, mix
--   start(entity, direction, c, cap) a trace of what feeds ("up") or is fed
--                                   by ("down") the entity's lanes
--   step(state, budget, c)          advances it; returns the result when done
--
-- A trace is a job phase (inspect.lua runs it inside the inspect job): each
-- belt it reaches costs PER_BELT work items and each lane it walks PER_LANE,
-- about 60 belts a tick; it walks at most `cap` belts. It reads only
-- own-force belts in charted chunks and stops where the belt leaves them.
-- Along the way it notes what puts items onto the walked lanes: inserters
-- and mining drills dropping onto them, side-loading belts, splitters,
-- loaders and (down) belts that join. Everything it returns is a reading,
-- never a judgement.
local items = require("scripts.items")
local surfaces = require("scripts.surfaces")
local entity_settings = require("scripts.entity_settings")

local M = {}

M.BELT_TYPES = {
  ["transport-belt"] = true,
  ["underground-belt"] = true,
  ["splitter"] = true,
  ["lane-splitter"] = true,
  ["loader"] = true,
  ["loader-1x1"] = true,
  ["linked-belt"] = true,
}
local SPLITTERS = { splitter = true, ["lane-splitter"] = true }
local LOADERS = { loader = true, ["loader-1x1"] = true }
M.MAX_BELTS = 400
M.PER_BELT = 6 -- chart check, the dropper query and its rows
M.PER_LANE = 2 -- a lane's contents and the belt's neighbours
M.MAX_SOURCES = 24 -- source rows per lane; the rest are counted
-- Inserters and mining drills that can drop onto a belt stand within this
-- many tiles of its edge (a big mining drill's centre is 2.85 from its drop).
M.DROP_REACH = 3

local LANE = { [0] = "right", [1] = "left" }
local function lane_of(index) return LANE[index % 2] end
local OTHER = { left = "right", right = "left" }

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

local function round1(v) return math.floor(v * 10 + 0.5) / 10 end
local function at(position) return { x = round1(position.x), y = round1(position.y) } end

-- Adds a line's contents to `into` by item key ("name@quality" off normal).
local function add_contents(line, into)
  local rows = read(line.get_contents)
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    if type(row.name) == "string" then
      local key = items.key(row.name, row.quality)
      into[key] = (into[key] or 0) + (tonumber(row.count) or 0)
    end
  end
end

local function line_count(e)
  return read(e.get_max_transport_line_index) or 2
end

-- What one lane ("left" or "right") of a belt-like entity holds; `per_line`
-- (optional) gets each line's own contents by line index.
local function lane_contents(e, lane, into, per_line)
  into = into or {}
  for i = 1, line_count(e) do
    if lane_of(i) == lane then
      local line = read(function() return e.get_transport_line(i) end)
      if line then
        if per_line then
          per_line[i] = {}
          add_contents(line, per_line[i])
          for k, count in pairs(per_line[i]) do into[k] = (into[k] or 0) + count end
        else
          add_contents(line, into)
        end
      end
    end
  end
  return into
end

local function count_keys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- What each lane of a belt-like entity holds, and how they mix:
-- empty; pure (one item kind on the belt); separated (each lane one kind,
-- not the same); mixed (a lane holds more than one kind). A splitter's left
-- and right sum the lanes of both its belts, inputs and outputs; its mix
-- judges each of those lanes (each transport line) on its own.
function M.lanes(e)
  if not M.BELT_TYPES[e.type] then return nil end
  local per_line = {}
  local lanes = { left = lane_contents(e, "left", nil, per_line), right = lane_contents(e, "right", nil, per_line) }
  local kinds, mixed = {}, false
  for _, lane in pairs(lanes) do
    for key in pairs(lane) do kinds[key] = true end
    if not SPLITTERS[e.type] and count_keys(lane) > 1 then mixed = true end
  end
  if SPLITTERS[e.type] then
    for _, line in pairs(per_line) do if count_keys(line) > 1 then mixed = true end end
  end
  local total = count_keys(kinds)
  local mix = total == 0 and "empty" or mixed and "mixed" or total == 1 and "pure" or "separated"
  return lanes, mix
end

-- ------------------------------------------------------------ the trace

local DIRECTION = { [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } }

-- The side of a line through `origin` along `direction` a point lies on
-- (nil when it is in line with it).
local function side(direction, origin, point)
  local d = DIRECTION[direction]
  if not d then return nil end
  local s = (point.x - origin.x) * d[2] - (point.y - origin.y) * d[1]
  if s > 0.1 then return "left" elseif s < -0.1 then return "right" end
  return nil
end
local function lateral(belt, point) return side(belt.direction, belt.position, point) end

local function curved(belt)
  return belt.type == "transport-belt" and read(function() return belt.belt_shape end) ~= "straight"
end

-- The lane of a belt a drop lands on: nil on a curve or a splitter, whose
-- lanes this cannot tell.
local function drop_lane(belt, point)
  if SPLITTERS[belt.type] or curved(belt) then return nil end
  return lateral(belt, point)
end

-- How a feeder's lanes land on a receiver it feeds: "straight" (left to
-- left, right to right) or the receiver's lane a side-load lands on, then,
-- onto an underground belt, the one feeder lane that passes its hood (nil:
-- both lanes land). Measured from the tile the feeder enters by, so a
-- two-tile splitter or loader feeds as its touching half.
local function join(feeder, receiver)
  if feeder.direction == receiver.direction or SPLITTERS[receiver.type] or LOADERS[receiver.type]
    or curved(receiver) then
    return "straight"
  end
  local f = DIRECTION[feeder.direction]
  if not f then return "straight" end
  local p = receiver.position
  local onto = lateral(receiver, { x = p.x - f[1], y = p.y - f[2] })
  if not onto then return "straight" end
  if receiver.type ~= "underground-belt" then return onto end
  local d = DIRECTION[receiver.direction]
  local half = read(function() return receiver.belt_to_ground_type end) == "input" and -0.25 or 0.25
  return onto, side(feeder.direction, p, { x = p.x + half * d[1], y = p.y + half * d[2] })
end

local function underground_pair(e, kind)
  if e.type ~= "underground-belt" or read(function() return e.belt_to_ground_type end) ~= kind then return nil end
  local pair = read(function() return e.neighbours end)
  if pair and pair.valid then return pair end
end

-- The belts that feed e (up) or that e feeds (down).
local function feeders(e)
  local bn = read(function() return e.belt_neighbours end)
  local list = {}
  for _, other in ipairs(bn and bn.inputs or {}) do list[#list + 1] = other end
  list[#list + 1] = underground_pair(e, "output")
  return list
end
local function receivers(e)
  local bn = read(function() return e.belt_neighbours end)
  local list = {}
  for _, other in ipairs(bn and bn.outputs or {}) do list[#list + 1] = other end
  list[#list + 1] = underground_pair(e, "input")
  return list
end

local function chunk_visible(state, c, position)
  local cx, cy = math.floor(position.x / 32), math.floor(position.y / 32)
  local key = cx .. "," .. cy
  local known = state.chunks[key]
  if known == nil then
    known = surfaces.charted(c.force, c.surface, cx, cy, state.platform)
    state.chunks[key] = known
  end
  return known
end

-- The tiles an entity covers: {x0, y0, x1, y1}.
local function tiles(e)
  local box = e.bounding_box
  return { math.floor(box.left_top.x + 0.01), math.floor(box.left_top.y + 0.01),
    math.floor(box.right_bottom.x - 0.01), math.floor(box.right_bottom.y - 0.01) }
end

-- Inserters and mining drills whose drop position lies on the belt, with
-- the lane they drop onto (an inserter onto the far lane, a drill onto the
-- lane its drop position is in; checked live on 2.0.77).
local function droppers(state, c, belt)
  local t = tiles(belt)
  local r = M.DROP_REACH
  local found = read(function()
    return c.surface.find_entities_filtered({ area = { { t[1] - r, t[2] - r }, { t[3] + 1 + r, t[4] + 1 + r } },
      type = { "inserter", "mining-drill" }, force = c.force })
  end) or {}
  local rows = {}
  for _, e in ipairs(found) do
    local drop = e.valid and read(function() return e.drop_position end)
    if drop and chunk_visible(state, c, e.position) then
      local x, y = math.floor(drop.x), math.floor(drop.y)
      if x >= t[1] and x <= t[3] and y >= t[2] and y <= t[4] then
        local row = { kind = e.type == "inserter" and "inserter" or "mining_drill", name = e.name, position = at(e.position) }
        if e.type == "inserter" then
          local near = drop_lane(belt, e.position)
          row.lane = near and OTHER[near] or nil
          local held = read(function() return e.held_stack end)
          if held and read(function() return held.valid_for_read end) then
            row.holding = { item = held.name, count = held.count, quality = items.quality_name(read(function() return held.quality end)) }
          else
            row.holding = false
          end
          local pickup = read(function() return e.pickup_target end)
          if pickup and pickup.valid and chunk_visible(state, c, pickup.position) then
            row.pickup_target = { name = pickup.name, position = at(pickup.position) }
          end
        else
          row.lane = drop_lane(belt, drop)
          local products = read(function() return e.mining_target.prototype.mineable_properties.products end)
          if type(products) == "table" then
            local names = {}
            for _, product in ipairs(products) do
              if type(product.name) == "string" then names[#names + 1] = product.name end
            end
            row.adds = names
          end
        end
        rows[#rows + 1] = { id = e.unit_number, row = row }
      end
    end
  end
  return rows
end

local function new_lane() return { items = {}, first_seen = {}, sources = {}, omitted_sources = 0 } end

local function source(state, label, key, row)
  if state.rows_seen[label .. ":" .. key] then return end
  state.rows_seen[label .. ":" .. key] = true
  local lane = state.lanes[label]
  if #lane.sources >= M.MAX_SOURCES then lane.omitted_sources = lane.omitted_sources + 1; return end
  lane.sources[#lane.sources + 1] = row
end

local function copy(row, steps)
  local out = { belts_from_start = steps }
  for k, v in pairs(row) do out[k] = v end
  return out
end

-- Whether a belt may be read at all: own force, in a charted chunk. Each
-- belt refused is counted once in stops.
local function visible(state, c, e)
  local id = e.unit_number
  if state.belts[id] then return true end
  if state.stopped[id] then return false end
  local why = e.force ~= c.force and "other_force" or not chunk_visible(state, c, e.position) and "uncharted"
  if not why then return true end
  state.stopped[id] = true
  state.stops[why] = state.stops[why] + 1
  return false
end

-- Admits a belt to the walk: counts it, reads who drops onto it. False when
-- the walk may not go there (cap, chart, force).
local function admit(state, c, e, budget)
  local id = e.unit_number
  if state.belts[id] then return true end
  if state.stopped[id] then return false end
  if state.belt_count >= state.cap then state.truncated = true; return false end
  budget.left = budget.left - M.PER_BELT
  if not visible(state, c, e) then return false end
  state.belts[id] = true
  state.belt_count = state.belt_count + 1
  state.droppers[id] = droppers(state, c, e)
  return true
end

-- A walk node is one lane of one belt, under the start lane (label) it
-- feeds (up) or is fed by (down).
local function key(e, lane, label) return e.unit_number .. ":" .. lane .. ":" .. label end

local function enqueue(state, e, lane, label, steps)
  local k = key(e, lane, label)
  if state.seen[k] then return false end
  state.seen[k] = true
  state.tail = state.tail + 1
  state.queue[state.tail] = { entity = e, lane = lane, label = label, steps = steps }
  return true
end

local function follow(state, c, node, other, lane, budget)
  if not admit(state, c, other, budget) then return end
  local fresh = enqueue(state, other, lane, node.label, node.steps + 1)
  if not fresh and other.unit_number == state.start_id then state.loop = true end
end

-- Rows for what this belt is (splitter, loader) and what drops onto the
-- walked lane.
local function entity_rows(state, node, here)
  local e, label = node.entity, node.label
  local id = e.unit_number
  if SPLITTERS[e.type] or LOADERS[e.type] then
    local row = { kind = LOADERS[e.type] and "loader" or "splitter", name = e.name, position = at(e.position), items = here }
    if row.kind == "loader" then row.loader_type = read(function() return e.loader_type end)
    else
      local settings = read(function() return entity_settings.read(e) end)
      if settings and settings.splitter then row.settings = settings.splitter end
    end
    source(state, label, "e" .. id, copy(row, node.steps))
  end
  for _, dropper in ipairs(state.droppers[id] or {}) do
    if dropper.row.lane == nil or dropper.row.lane == node.lane then
      local row = copy(dropper.row, node.steps)
      row.onto = at(e.position)
      source(state, label, "d" .. dropper.id, row)
    end
  end
end

-- A belt feeding the walked lane; `only` is the one feeder lane that passes
-- an underground's hood.
local function feeder_row(state, node, feeder, kind, only)
  local contents
  if kind == "belt" or only then
    contents = lane_contents(feeder, only or node.lane)
  else
    contents = lane_contents(feeder, "left")
    lane_contents(feeder, "right", contents)
  end
  source(state, node.label, "f" .. feeder.unit_number .. ":" .. node.entity.unit_number, { kind = kind,
    name = feeder.name, position = at(feeder.position), onto = at(node.entity.position), lane = node.lane,
    feeder_lane = only, items = contents, belts_from_start = node.steps })
end

local function walk(state, c, node, budget)
  local e = node.entity
  if not e.valid then return end
  budget.left = budget.left - M.PER_LANE
  local lane = state.lanes[node.label]
  local here = lane_contents(e, node.lane)
  for k, count in pairs(here) do
    lane.items[k] = (lane.items[k] or 0) + count
    local first = lane.first_seen[k]
    if not first or node.steps < first.belts_from_start then
      lane.first_seen[k] = { position = at(e.position), belts_from_start = node.steps }
    end
  end
  entity_rows(state, node, here)
  if state.direction == "up" then
    for _, feeder in ipairs(feeders(e)) do
      local onto, only = join(feeder, e)
      if onto == "straight" then follow(state, c, node, feeder, node.lane, budget)
      elseif onto == node.lane and visible(state, c, feeder) then
        feeder_row(state, node, feeder, "side_load", only)
        if only then follow(state, c, node, feeder, only, budget)
        else
          follow(state, c, node, feeder, "left", budget)
          follow(state, c, node, feeder, "right", budget)
        end
      end
    end
    return
  end
  -- Down: what joins a walked lane past the start belt (what feeds the
  -- start belt itself is upstream of it), then where the lane goes.
  if node.steps > 0 then
    for _, feeder in ipairs(feeders(e)) do
      local onto, only = join(feeder, e)
      if onto == "straight" then
        if not state.seen[key(feeder, node.lane, node.label)] and visible(state, c, feeder) then
          feeder_row(state, node, feeder, "belt")
        end
      elseif onto == node.lane and not (state.seen[key(feeder, only or "left", node.label)]
        or not only and state.seen[key(feeder, "right", node.label)]) and visible(state, c, feeder) then
        feeder_row(state, node, feeder, "side_load", only)
      end
    end
  end
  for _, receiver in ipairs(receivers(e)) do
    local onto, only = join(e, receiver)
    -- Onto an underground, the lane the hood holds back goes no further.
    if not only or only == node.lane then
      follow(state, c, node, receiver, onto == "straight" and node.lane or onto, budget)
    end
  end
end

function M.start(entity, direction, c, cap)
  if direction ~= "up" and direction ~= "down" then error("trace must be \"up\" or \"down\"", 0) end
  local state = {
    direction = direction, cap = math.max(1, math.min(cap or M.MAX_BELTS, M.MAX_BELTS)),
    platform = surfaces.is_platform(c.surface), chunks = {},
    queue = {}, head = 1, tail = 0, seen = {}, belts = {}, belt_count = 0, droppers = {}, rows_seen = {},
    stops = { uncharted = 0, other_force = 0 }, stopped = {}, truncated = false, loop = false,
    start_id = entity.unit_number, lanes = { left = new_lane(), right = new_lane() },
  }
  -- The start was found by inspect (within 30 tiles, or charted and own).
  state.belts[entity.unit_number], state.belt_count = true, 1
  state.droppers[entity.unit_number] = droppers(state, c, entity)
  enqueue(state, entity, "left", "left", 0)
  enqueue(state, entity, "right", "right", 0)
  return state
end

function M.step(state, budget, c)
  while state.head <= state.tail do
    if budget.left <= 0 then return nil end
    local node = state.queue[state.head]
    state.queue[state.head] = nil
    state.head = state.head + 1
    walk(state, c, node, budget)
  end
  local lanes = {}
  for name, lane in pairs(state.lanes) do
    lanes[name] = { items = lane.items, first_seen = lane.first_seen, sources = lane.sources,
      omitted_sources = lane.omitted_sources > 0 and lane.omitted_sources or nil }
  end
  local stops = {}
  for kind, count in pairs(state.stops) do if count > 0 then stops[kind] = count end end
  return {
    direction = state.direction, belts = state.belt_count, max_belts = state.cap,
    truncated = state.truncated, loop = state.loop,
    stopped = next(stops) and stops or nil,
    lanes = lanes,
  }
end

return M
