-- belt_joins: a dry run's belt joins, as data and never as a failure. One row
-- for every planned belt, underground exit or splitter output that lands on
-- a standing belt or on a planned belt another belt also feeds, every planned
-- inserter or drill drop onto a belt, every standing belt that feeds a
-- planned belt, and every standing side input a planned belt turns from a
-- curve into a side-load. Row: {name, x, y, standing (the receiving belt
-- stands now), from = {name, x, y, standing}, join, lanes = [{lane, items,
-- adds?, mixes?}]}.
--
-- The engine's rules (Factorio 2.0.77, measured live): lanes are left and
-- right facing the receiving belt's direction (transport line 1 is the left
-- lane). From behind, and as the one side input of a transport belt with
-- nothing behind it (a curve), lanes are kept: join "straight". A side input
-- of a belt with something behind it or a second side input is a side-load:
-- both of the source's lanes go onto the near lane. A side-load onto an
-- underground belt also goes onto the near lane, but only one source lane
-- passes: the one on the entrance's back half, or on the exit's front half.
-- A splitter takes only from behind. An inserter or drill drop lands on the
-- lane on the drop point's side of the belt's centre line; a point on the
-- line goes onto the right lane: join "drop".
--
-- items: on that lane now (a standing belt's transport lines, that tile
-- only), or what the layout's other inputs put there (a planned belt). adds:
-- what this source puts on that lane, as far as the dry run knows: a drill
-- what the resources in its mining area give when mined, a standing belt
-- what its lanes carry now, a planned run what its own sources add, an
-- inserter what its pickup gives (a crafter's recipe products, a chest's
-- items now, a belt's lanes), only its whitelist filters or less its
-- blacklist ones; nil (JSON null) when only unknown sources feed it (an
-- inserter whose pickup is none of those, an empty chest, a crafter with no
-- recipe, a run whose start nothing feeds). mixes: true when that lane would
-- carry more than one item kind after the build (a splitter's outputs each
-- count everything it takes in), false when not, nil when an unknown source
-- leaves it open.
--
-- A planned belt piece the same as one standing there (name, position,
-- direction, underground end) stands now: standing is true, its lanes now
-- count in items and in what it carries, and a join between it and another
-- standing belt is no row unless the build changes the join's kind.
--
-- Reads: one small query per planned belt piece whose input sides or front
-- the layout does not cover, and per drop that lands outside it, plus the
-- transport lines and belt_neighbours of the standing belts found (charted
-- chunks only), and one pickup query per inserter dropping onto a belt. The
-- state is plain data: build_layout's survey and connect_entities' job keep
-- it in storage between ticks and pass the planned list and its tile index
-- back.
local output_target = require("scripts.output_target")

local M = {}

local FLOW = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true }
M.TYPES = { "transport-belt", "underground-belt", "splitter" }
local AHEAD = { [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } }
local LOAD_PER_ITEM = 4

-- A tile's key, as build_layout's survey keys its tile index.
local function cell(x, y) return x * 2097152 + y end

local function each_tile(area, fn)
  for y = math.floor(area.left_top.y + 0.01), math.ceil(area.right_bottom.y - 0.01) - 1 do
    for x = math.floor(area.left_top.x + 0.01), math.ceil(area.right_bottom.x - 0.01) - 1 do fn(x, y) end
  end
end

-- The tile index of a planned list ({cell -> {i...}}), as build_layout's
-- survey keeps it.
function M.index(planned)
  local tiles = {}
  for i, p in ipairs(planned) do
    each_tile(p.area, function(x, y)
      local list = tiles[cell(x, y)]
      if list then list[#list + 1] = i else tiles[cell(x, y)] = { i } end
    end)
  end
  return tiles
end

-- Whether a belt-like receiver (type, direction, underground end) takes
-- what a belt heading d puts on its tile: none takes it head-on, an
-- underground exit's back is closed and a splitter takes it only from
-- behind (build_layout's takes).
local function takes(kind, direction, under, d)
  if not FLOW[kind] or direction == (d + 8) % 16 then return false end
  if kind == "splitter" then return direction == d end
  return not (kind == "underground-belt" and under == "output" and direction == d)
end

-- The tiles a belt-like entity puts items on: the tile ahead of a belt or
-- an underground exit, ahead of each of a splitter's two tiles.
local function outputs(kind, position, direction, under)
  local step = AHEAD[direction]
  if not step or kind == "underground-belt" and under ~= "output" then return {} end
  if kind == "splitter" then
    local px, py = step[2] ~= 0 and 0.5 or 0, step[1] ~= 0 and 0.5 or 0
    return { { x = math.floor(position.x - px) + step[1], y = math.floor(position.y - py) + step[2] },
      { x = math.floor(position.x + px) + step[1], y = math.floor(position.y + py) + step[2] } }
  end
  return { { x = math.floor(position.x) + step[1], y = math.floor(position.y) + step[2] } }
end

local function names_of(set)
  local list = {}
  for name in pairs(set) do list[#list + 1] = name end
  table.sort(list)
  return list
end

-- A standing belt's lanes now: the item names on its left lines (odd
-- transport line indexes) and right lines (even).
local function read_lanes(e)
  local lanes = { {}, {} }
  local max_index = 2
  pcall(function() max_index = e.get_max_transport_line_index() end)
  for index = 1, max_index do
    local ok, contents = pcall(function() return e.get_transport_line(index).get_contents() end)
    if ok and type(contents) == "table" then
      for _, row in pairs(contents) do
        if type(row) == "table" and type(row.name) == "string" then lanes[2 - index % 2][row.name] = true end
      end
    end
  end
  return { names_of(lanes[1]), names_of(lanes[2]) }
end

local function standing_key(e) return string.format("%s@%.2f,%.2f", e.name, e.position.x, e.position.y) end

local function under_of(e)
  if e.type ~= "underground-belt" then return nil end
  local ok, kind = pcall(function() return e.belt_to_ground_type end)
  return ok and kind or nil
end

-- Records a standing belt once: its geometry and lanes; as a receiver also
-- its standing inputs (belt_neighbours) on charted chunks, with their lanes.
-- An input on a tile the layout places (planned = true) counts before the
-- build only: after it, the planned piece there stands for it.
local function record(J, e, io, receiver, tiles)
  local key = standing_key(e)
  local s = J.standing[key]
  if not s then
    io.charge(1)
    s = { name = e.name, type = e.type, x = e.position.x, y = e.position.y, direction = e.direction,
      under = under_of(e), lanes = read_lanes(e) }
    J.standing[key] = s
  end
  if receiver and not s.inputs then
    s.inputs = {}
    local ok, inputs = pcall(function() return e.belt_neighbours.inputs end)
    for _, input in ipairs(ok and inputs or {}) do
      if input.valid and FLOW[input.type] then
        if tiles[cell(math.floor(input.position.x), math.floor(input.position.y))] then
          s.inputs[#s.inputs + 1] = { s = input.direction, planned = true }
        elseif not io.charted or io.charted(input.position) then
          s.inputs[#s.inputs + 1] = { key = record(J, input, io, false, tiles), s = input.direction }
        end
      end
    end
  end
  return key
end

local function same_spot(a, b) return math.abs(a.x - b.x) < 0.01 and math.abs(a.y - b.y) < 0.01 end

-- What a standing pickup gives an inserter: a crafter its recipe's item
-- products, a chest the items in it now; nil when unknown.
local CHESTS = { container = true, ["logistic-container"] = true }
local function pickup_items(e)
  local ok, found = pcall(function()
    local set = {}
    if e.type == "assembling-machine" or e.type == "furnace" then
      local recipe = e.get_recipe()
      if not recipe then return nil end
      for _, row in pairs(recipe.products) do
        if row.type == "item" and type(row.name) == "string" then set[row.name] = true end
      end
    elseif CHESTS[e.type] then
      for _, row in pairs(e.get_inventory(defines.inventory.chest).get_contents()) do
        if type(row) == "table" and type(row.name) == "string" then set[row.name] = true end
      end
      if next(set) == nil then return nil end
    else
      return nil
    end
    return names_of(set)
  end)
  return ok and found or nil
end

-- Where a planned inserter picks up: a planned entity whose footprint
-- passes the native endpoint test ({planned = j}), else what io.pickup
-- finds standing there ({standing = belt key} or {items = names}); nil
-- when nothing is known.
local function pick(J, i, p, planned, tiles, io)
  local point = output_target.input_position(p.proto, p.position, p.direction)
  if not point then return end
  for _, j in ipairs(tiles[cell(math.floor(point.x), math.floor(point.y))] or {}) do
    local q = planned[j]
    if output_target.can_target_type(q.proto.type, "input")
      and output_target.recipient_contains(q.area, point, "inserter", "input") then
      J.picks[i] = { planned = j }
      return
    end
  end
  local e = io.pickup and io.pickup(point)
  if not e then return end
  if FLOW[e.type] then
    J.picks[i] = { standing = record(J, e, io, false, tiles) }
  else
    io.charge(1)
    local items = pickup_items(e)
    if items then J.picks[i] = { items = items } end
  end
end

-- The survey of a planned list: one scan unit per planned belt piece,
-- inserter or drill (drop).
function M.start(planned)
  local units = {}
  for i, p in ipairs(planned) do
    local kind = p.proto.type
    if FLOW[kind] or kind == "inserter" or kind == "mining-drill" and output_target.output_offset(p.proto) then
      units[#units + 1] = i
    end
  end
  return { units = units, k = 1, edges = {}, seen = {}, standing = {}, mined = {}, twin = {}, picks = {} }
end

-- What a planned drill mines (resource names), from the dry run's own read
-- of its mining area.
function M.set_mined(J, i, names) J.mined[i] = names end

function M.done(J) return J.k > #J.units end

local function add_edge(J, edge)
  local key = tostring(edge.src) .. ">" .. tostring(edge.dst)
  if J.seen[key] then return end
  J.seen[key] = true
  J.edges[#J.edges + 1] = edge
end

local function covers(e, tile)
  local box = e.bounding_box
  local x, y = tile.x + 0.5, tile.y + 0.5
  return box and x > box.left_top.x and x < box.right_bottom.x and y > box.left_top.y and y < box.right_bottom.y
end

-- Scans the next unit. io = {query(area) -> own belt-like entities on
-- charted chunks, charge(n), charted(position)?, pickup(point)? -> the own
-- entity an inserter picks up from there, on a charted chunk}.
function M.scan(J, planned, tiles, io)
  local i = J.units[J.k]
  J.k = J.k + 1
  local p = planned[i]
  local kind = p.proto.type
  local need = false
  local outs, mine, drop = {}, {}, nil
  local before = #J.edges
  if FLOW[kind] then
    outs = outputs(kind, p.position, p.direction, p.under)
    each_tile(p.area, function(x, y)
      mine[cell(x, y)] = true
      for _, d in ipairs({ 0, 4, 8, 12 }) do
        local step = AHEAD[d]
        if not tiles[cell(x + step[1], y + step[2])] then need = true end
      end
    end)
    for _, t in ipairs(outs) do
      for _, j in ipairs(tiles[cell(t.x, t.y)] or {}) do
        local q = planned[j]
        if j ~= i and takes(q.proto.type, q.direction, q.under, p.direction) then
          add_edge(J, { src = i, dst = j, s = p.direction })
        end
      end
    end
  else
    drop = output_target.output_position(p.proto, p.position, p.direction)
    if not drop then return end
    local t = { x = math.floor(drop.x), y = math.floor(drop.y) }
    local list = tiles[cell(t.x, t.y)]
    for _, j in ipairs(list or {}) do
      if FLOW[planned[j].proto.type] then add_edge(J, { src = i, dst = j, drop = drop }) end
    end
    need = list == nil
    outs = { t }
  end
  if need then
    local a = drop and { left_top = { x = outs[1].x + 0.1, y = outs[1].y + 0.1 },
        right_bottom = { x = outs[1].x + 0.9, y = outs[1].y + 0.9 } }
      or { left_top = { x = p.area.left_top.x - 1, y = p.area.left_top.y - 1 },
        right_bottom = { x = p.area.right_bottom.x + 1, y = p.area.right_bottom.y + 1 } }
    for _, e in ipairs(io.query(a)) do
      local at = { x = math.floor(e.position.x), y = math.floor(e.position.y) }
      local under = FLOW[e.type] and under_of(e)
      if FLOW[e.type] and tiles[cell(at.x, at.y)] then
        -- The same piece standing where this one is planned: it stands now.
        if not drop and not J.twin[i] and e.name == p.name and same_spot(e.position, p.position)
          and e.direction == p.direction and under == p.under then
          J.twin[i] = record(J, e, io, true, tiles)
        end
      elseif FLOW[e.type] then
        for _, t in ipairs(outs) do
          if not tiles[cell(t.x, t.y)] and covers(e, t)
            and (drop or takes(e.type, e.direction, under, p.direction)) then
            add_edge(J, { src = i, dst = record(J, e, io, true, tiles), s = not drop and p.direction or nil, drop = drop })
          end
        end
        if not drop and takes(kind, p.direction, p.under, e.direction) then
          for _, t in ipairs(outputs(e.type, e.position, e.direction, under)) do
            if mine[cell(t.x, t.y)] then add_edge(J, { src = record(J, e, io, false, tiles), dst = i, s = e.direction }) end
          end
        end
      end
    end
  end
  -- An inserter dropping onto a belt: what it picks up.
  if kind == "inserter" and #J.edges > before then pick(J, i, p, planned, tiles, io) end
end

-- ----------------------------------------------------------------- finish

local function lane() return { set = {}, unknown = false } end
local function merge(into, from)
  for name in pairs(from.set) do into.set[name] = true end
  if from.unknown then into.unknown = true end
end
local function count(set)
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

-- The items a resource gives when mined (cached per name), false when its
-- prototype cannot be read.
local function products(J, resource)
  J.products = J.products or {}
  local list = J.products[resource]
  if list == nil then
    local ok, found = pcall(function()
      local out = {}
      for _, row in pairs(prototypes.entity[resource].mineable_properties.products) do
        if row.type == "item" and type(row.name) == "string" then out[#out + 1] = row.name end
      end
      return out
    end)
    list = ok and found or false
    J.products[resource] = list
  end
  return list
end

-- The item products of a planned crafter's recipe (cached per name), false
-- when it cannot be read.
local function recipe_items(J, name)
  J.recipes = J.recipes or {}
  local list = J.recipes[name]
  if list == nil then
    local ok, found = pcall(function()
      local out = {}
      for _, row in pairs(prototypes.recipe[name].products) do
        if row.type == "item" and type(row.name) == "string" then out[#out + 1] = row.name end
      end
      return out
    end)
    list = ok and found or false
    J.recipes[name] = list
  end
  return list
end

-- The rows, from the scanned edges. io.charge(n) pays for the pass.
function M.finish(J, planned, tiles, io)
  local edges, standing = J.edges, J.standing
  local into = {}
  for k, edge in ipairs(edges) do
    local list = into[edge.dst]
    if list then list[#list + 1] = k else into[edge.dst] = { k } end
  end
  io.charge(math.ceil((#J.units + #edges) / LOAD_PER_ITEM))
  local function info(ref)
    if type(ref) == "string" then return standing[ref] end
    local p = planned[ref]
    return { name = p.name, type = p.proto.type, x = p.position.x, y = p.position.y, direction = p.direction,
      under = p.under }
  end
  -- A planned underground exit's planned entrance: the nearest planned
  -- underground of its name back along its axis within reach.
  local function entrance_of(i)
    local p = planned[i]
    local back = AHEAD[(p.direction + 8) % 16]
    local ok, reach = pcall(function() return p.proto.max_underground_distance end)
    reach = ok and tonumber(reach) or 0
    for k = 1, math.floor(reach) do
      for _, j in ipairs(tiles[cell(math.floor(p.position.x) + back[1] * k, math.floor(p.position.y) + back[2] * k)] or {}) do
        local q = planned[j]
        if q.name == p.name and (q.direction == p.direction or q.direction == (p.direction + 8) % 16) then
          if q.under ~= "output" and q.direction == p.direction then return j end
          return nil
        end
      end
    end
  end
  -- The standing belt a ref is now: itself, a planned piece's standing
  -- twin, or nil.
  local function now_of(ref)
    if type(ref) == "string" then return ref end
    return J.twin[ref]
  end
  -- The receiving belt's inputs from behind and from the sides after the
  -- build (drops are not belt inputs: standing ones the layout does not
  -- replace and planned ones), and before it (what stands now).
  local function counts(ref, after)
    local q = info(ref)
    local rear, side = 0, 0
    local function add(s) if s == q.direction then rear = rear + 1 else side = side + 1 end end
    if not after then
      local now = now_of(ref)
      for _, input in ipairs(now and standing[now].inputs or {}) do add(input.s) end
      return rear, side
    end
    if type(ref) == "string" then
      for _, input in ipairs(q.inputs or {}) do if not input.planned then add(input.s) end end
    end
    for _, k in ipairs(into[ref] or {}) do
      local edge = edges[k]
      if not edge.drop and not (type(ref) == "string" and type(edge.src) == "string") then add(edge.s) end
    end
    return rear, side
  end
  local carry, contribution
  local memo, joins = {}, {}
  -- What a planned inserter moves: what its pickup gives, cut to its
  -- whitelist filters (a whitelist alone bounds it) or less its blacklist.
  local function picked(i)
    local out = lane()
    local from = J.picks[i]
    local q = from and from.planned and planned[from.planned]
    if q and FLOW[q.proto.type] then
      local c = carry(from.planned)
      merge(out, c[1])
      merge(out, c[2])
    elseif q and q.recipe and q.proto.type == "assembling-machine" and recipe_items(J, q.recipe) then
      for _, name in ipairs(recipe_items(J, q.recipe)) do out.set[name] = true end
    elseif from and from.standing then
      for l = 1, 2 do for _, name in ipairs(standing[from.standing].lanes[l]) do out.set[name] = true end end
    elseif from and from.items then
      for _, name in ipairs(from.items) do out.set[name] = true end
    else
      out.unknown = true
    end
    local settings = planned[i].settings and planned[i].settings.inserter
    local filters = settings and type(settings.filters) == "table" and settings.filters or {}
    if #filters > 0 then
      local allowed = {}
      for _, name in ipairs(filters) do if type(name) == "string" then allowed[name] = true end end
      if settings.mode == "blacklist" then
        for name in pairs(allowed) do out.set[name] = nil end
      elseif out.unknown then
        out = { set = allowed, unknown = false }
      else
        for name in pairs(out.set) do if not allowed[name] then out.set[name] = nil end end
      end
    end
    return out
  end
  -- How a source heading s joins receiver ref: kind, the receiver lane each
  -- source lane goes onto ({[1] = lane, [2] = lane}, nil where it is
  -- stopped).
  local function join(ref, s, after)
    local q = info(ref)
    local rel = (s - q.direction) % 16
    if rel == 0 then return "straight", { 1, 2 } end
    local near = rel == 4 and 1 or 2
    if q.type == "transport-belt" then
      local rear, side = counts(ref, after)
      if rear == 0 and side == 1 then return "straight", { 1, 2 } end
      return "side_load", { near, near }
    end
    -- An underground: only the source lane on the entrance's back half or
    -- the exit's front half passes.
    local left_side = (s + 12) % 16
    local open = q.under == "output" and q.direction or (q.direction + 8) % 16
    if left_side == open then return "side_load", { near, nil } end
    return "side_load", { nil, near }
  end
  -- What edge k puts on each receiver lane: {kind, [lane] = {set, unknown}}.
  contribution = function(k)
    if joins[k] then return joins[k] end
    local edge = edges[k]
    local out = { [1] = lane(), [2] = lane() }
    if edge.drop then
      local q = info(edge.dst)
      local lv = AHEAD[(q.direction + 12) % 16]
      local cx, cy = math.floor(edge.drop.x) + 0.5, math.floor(edge.drop.y) + 0.5
      local side = (edge.drop.x - cx) * lv[1] + (edge.drop.y - cy) * lv[2]
      local target = side > 0 and 1 or 2
      local p = planned[edge.src]
      local mined = p.proto.type == "mining-drill" and J.mined[edge.src]
      if mined then
        for _, resource in ipairs(mined) do
          local list = products(J, resource)
          if not list then out[target].unknown = true end
          for _, item in ipairs(list or {}) do out[target].set[item] = true end
        end
      elseif p.proto.type == "inserter" then
        out[target] = picked(edge.src)
      else
        out[target].unknown = true
      end
      out.kind, out.lanes = "drop", { target }
    else
      local kind, map = join(edge.dst, edge.s, true)
      local from = carry(edge.src)
      out.lanes = {}
      for source = 1, 2 do
        local target = map[source]
        if target then
          merge(out[target], from[source])
          if out.lanes[1] ~= target then out.lanes[#out.lanes + 1] = target end
        end
      end
      table.sort(out.lanes)
      out.kind = kind
    end
    joins[k] = out
    return out
  end
  -- What a belt carries on each lane: a standing one what it holds now, a
  -- planned one what its inputs put there (unknown when nothing feeds it).
  carry = function(ref)
    if memo[ref] then return memo[ref] end
    local result = { lane(), lane() }
    memo[ref] = result -- a loop adds nothing more
    if type(ref) == "string" then
      for l = 1, 2 do for _, name in ipairs(standing[ref].lanes[l]) do result[l].set[name] = true end end
      return result
    end
    local any = false
    -- A planned piece that stands now carries its lanes now, as a standing
    -- belt does.
    local now = J.twin[ref]
    if now then
      any = true
      for l = 1, 2 do for _, name in ipairs(standing[now].lanes[l]) do result[l].set[name] = true end end
    end
    for _, k in ipairs(into[ref] or {}) do
      any = true
      local c = contribution(k)
      merge(result[1], c[1])
      merge(result[2], c[2])
    end
    local p = planned[ref]
    if p.proto.type == "underground-belt" and p.under == "output" then
      local entrance = entrance_of(ref)
      if entrance then
        any = true
        local from = carry(entrance)
        merge(result[1], from[1])
        merge(result[2], from[2])
      end
    end
    if not any then result[1].unknown, result[2].unknown = true, true end
    return result
  end
  -- A receiving lane after the build: a standing belt's items now and every
  -- planned input; a planned belt's carry (and a standing twin's items now).
  local function total(ref, l, extra)
    local t = lane()
    local now = now_of(ref)
    if now then for _, name in ipairs(standing[now].lanes[l]) do t.set[name] = true end end
    if type(ref) == "string" then
      for _, k in ipairs(into[ref] or {}) do
        if type(edges[k].src) ~= "string" then merge(t, contribution(k)[l]) end
      end
    else
      merge(t, carry(ref)[l])
    end
    if extra then merge(t, extra) end
    return t
  end
  local function lane_row(ref, l, adds, others, extra)
    local row = { lane = l == 1 and "left" or "right" }
    local now = now_of(ref)
    if now then row.items = standing[now].lanes[l] else row.items = names_of(others.set) end
    if not (adds.unknown and next(adds.set) == nil) then row.adds = names_of(adds.set) end
    local t = total(ref, l, extra)
    if count(t.set) > 1 then row.mixes = true elseif not t.unknown then row.mixes = false end
    return row
  end
  local function source_of(ref)
    local s = info(ref)
    return { name = s.name, x = s.x, y = s.y, standing = now_of(ref) ~= nil }
  end
  local rows = {}
  for k, edge in ipairs(edges) do
    local c = contribution(k)
    local dst = edge.dst
    local belt_inputs = 0
    for _, other in ipairs(into[dst] or {}) do if not edges[other].drop then belt_inputs = belt_inputs + 1 end end
    -- A join between two belts that both stand now is a row only when the
    -- build changes its kind.
    local kept = not edge.drop and now_of(dst) and now_of(edge.src) and join(dst, edge.s, false) == c.kind
    if not kept and (type(dst) == "string" or type(edge.src) == "string" or c.kind ~= "straight" or belt_inputs > 1) then
      local q = info(dst)
      local row = { name = q.name, x = q.x, y = q.y, standing = now_of(dst) ~= nil, from = source_of(edge.src),
        join = c.kind, lanes = {} }
      for _, l in ipairs(c.lanes) do
        local others = lane()
        for _, other in ipairs(into[dst] or {}) do if other ~= k then merge(others, contribution(other)[l]) end end
        local entrance = type(dst) ~= "string" and planned[dst].under == "output" and entrance_of(dst)
        if entrance then merge(others, carry(entrance)[l]) end
        row.lanes[#row.lanes + 1] = lane_row(dst, l, c[l], others)
      end
      rows[#rows + 1] = row
    end
  end
  -- A standing belt that turns its one side input (a curve) is no curve once
  -- a planned belt joins it from behind or the other side: that input then
  -- side-loads onto its near lane.
  for ref, s in pairs(standing) do
    if s.inputs and s.type == "transport-belt" and into[ref] then
      local rear, side = counts(ref, false)
      local rear_after, side_after = counts(ref, true)
      if rear == 0 and side == 1 and not (rear_after == 0 and side_after == 1) then
        for _, input in ipairs(s.inputs) do
          if input.s ~= s.direction and not input.planned then
            local near = (input.s - s.direction) % 16 == 4 and 1 or 2
            local adds = lane()
            for l = 1, 2 do for _, name in ipairs(standing[input.key].lanes[l]) do adds.set[name] = true end end
            rows[#rows + 1] = { name = s.name, x = s.x, y = s.y, standing = true, from = source_of(input.key),
              join = "side_load", lanes = { lane_row(ref, near, adds, nil, adds) } }
          end
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    if a.x ~= b.x then return a.x < b.x end
    if a.from.y ~= b.from.y then return a.from.y < b.from.y end
    return a.from.x < b.from.x
  end)
  return rows
end

return M
