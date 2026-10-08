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
-- left on left and right on right; a belt joining from the side puts both
-- its lanes onto the receiver's lane on that side (onto an underground belt
-- too, where the hood may hold back one of the feeder's lanes).
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

-- What one lane ("left" or "right") of a belt-like entity holds.
local function lane_contents(e, lane, into)
  into = into or {}
  for i = 1, line_count(e) do
    if lane_of(i) == lane then
      local line = read(function() return e.get_transport_line(i) end)
      if line then add_contents(line, into) end
    end
  end
  return into
end

-- What each lane of a belt-like entity holds, and how they mix:
-- empty; pure (one item kind on the belt); separated (each lane one kind,
-- not the same); mixed (a lane holds more than one kind).
function M.lanes(e)
  if not M.BELT_TYPES[e.type] then return nil end
  local lanes = { left = lane_contents(e, "left"), right = lane_contents(e, "right") }
  local kinds, per_lane = {}, {}
  for name, lane in pairs(lanes) do
    per_lane[name] = 0
    for key in pairs(lane) do per_lane[name] = per_lane[name] + 1; kinds[key] = true end
  end
  local total = 0
  for _ in pairs(kinds) do total = total + 1 end
  local mix = total == 0 and "empty" or (per_lane.left > 1 or per_lane.right > 1) and "mixed"
    or total == 1 and "pure" or "separated"
  return lanes, mix
end

-- ------------------------------------------------------------ the trace

local DIRECTION = { [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } }

-- The side of a belt a point lies on, along the belt's direction (nil when
-- it is in line with it).
local function lateral(belt, point)
  local d = DIRECTION[belt.direction]
  if not d then return nil end
  local s = (point.x - belt.position.x) * d[2] - (point.y - belt.position.y) * d[1]
  if s > 0.1 then return "left" elseif s < -0.1 then return "right" end
  return nil
end

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
-- left, right to right) or the receiver's lane both side-load onto.
local function join(feeder, receiver)
  if SPLITTERS[feeder.type] or SPLITTERS[receiver.type] or LOADERS[feeder.type] or LOADERS[receiver.type]
    or feeder.type == "underground-belt" and receiver.type == "underground-belt"
    or feeder.direction == receiver.direction or curved(receiver) then
    return "straight"
  end
  return lateral(receiver, feeder.position) or "straight"
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

-- Admits a belt to the walk: counts it, reads who drops onto it. False when
-- the walk may not go there (cap, chart, force).
local function admit(state, c, e, budget)
  local id = e.unit_number
  if state.belts[id] then return true end
  if state.stopped[id] then return false end
  if state.belt_count >= state.cap then state.truncated = true; return false end
  budget.left = budget.left - M.PER_BELT
  if e.force ~= c.force then
    state.stopped[id] = true
    state.stops.other_force = state.stops.other_force + 1
    return false
  end
  if not chunk_visible(state, c, e.position) then
    state.stopped[id] = true
    state.stops.uncharted = state.stops.uncharted + 1
    return false
  end
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

local function feeder_row(state, node, feeder, kind)
  local contents = lane_contents(feeder, "left")
  lane_contents(feeder, "right", contents)
  source(state, node.label, "f" .. feeder.unit_number .. ":" .. node.entity.unit_number, { kind = kind,
    name = feeder.name, position = at(feeder.position), onto = at(node.entity.position), lane = node.lane,
    items = kind == "side_load" and contents or lane_contents(feeder, node.lane), belts_from_start = node.steps })
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
      local onto = join(feeder, e)
      if onto == "straight" then follow(state, c, node, feeder, node.lane, budget)
      elseif onto == node.lane then
        feeder_row(state, node, feeder, "side_load")
        follow(state, c, node, feeder, "left", budget)
        follow(state, c, node, feeder, "right", budget)
      end
    end
    return
  end
  -- Down: what joins a walked lane past the start belt (what feeds the
  -- start belt itself is upstream of it), then where the lane goes.
  if node.steps > 0 then
    for _, feeder in ipairs(feeders(e)) do
      local onto = join(feeder, e)
      if onto == "straight" and not state.seen[key(feeder, node.lane, node.label)] then
        feeder_row(state, node, feeder, "belt")
      elseif onto == node.lane and not (state.seen[key(feeder, "left", node.label)]
        or state.seen[key(feeder, "right", node.label)]) then
        feeder_row(state, node, feeder, "side_load")
      end
    end
  end
  for _, receiver in ipairs(receivers(e)) do
    local onto = join(e, receiver)
    follow(state, c, node, receiver, onto == "straight" and node.lane or onto, budget)
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
