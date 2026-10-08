-- Deterministic physical route planning over charted ground: belts and pipes
-- by a resumable A* search, poles by wire reach. Endpoints are an existing
-- belt, pipe, pole or fluid/electric machine at an exact position, or a free
-- tile (the route then covers it, e.g. a drill's drop tile). Belt and pipe
-- routes hop obstacles with an underground belt or pipe-to-ground pair; a
-- pipe route picks the machine ports whose fluid filter matches.
--
-- The connect_entities RPC is a job (jobs.lua): a route of up to 200 tiles
-- is searched over ticks, a budget of work items per tick, never all of it
-- inside the one tick of the command. build_layout drives the same search
-- with its own placement checks.
--
-- A search that finds no route within max_length fails typed (M.failure):
-- ROUTE_TOO_LONG (the shortest route's length, or a lower bound when the
-- budget ended the search first), ROUTE_BLOCKED (nothing reachable meets an
-- end: the explored tile nearest one) or SEARCH_BUDGET (the node budget ran
-- out first). The search goes on past max_length within its node budget, so
-- a route that exists but is too long is told apart from a blocked one. A
-- power route fails with the same codes from its pole arithmetic.
local companion = require("scripts.companion")
local placement_geometry = require("scripts.placement_geometry")
local fluid_connections = require("scripts.fluid_connections")
local belt_joins = require("scripts.belt_joins")
local errors = require("scripts.errors")

local M = {}
M.MAX_LENGTH = 200
M.MAX_VIA = 8 -- waypoints a belt or pipe route may pass, in the bot's order
M.CODES = { ROUTE_TOO_LONG = true, ROUTE_BLOCKED = true, SEARCH_BUDGET = true }
local BELT = { ["transport-belt"] = true }
local PIPE = { pipe = true }
-- Work items: a placement check is one can_place_entity pair plus the chunk
-- reads around it; a node expansion is the heap and table work.
local FIT_COST, NODE_COST, GAP_COST = 4, 1, 2
-- Ancestors a step checks for its own tile (on_path).
local PATH_CHECK = 16

local function position(value, label)
  if type(value) ~= "table" or tonumber(value.x) == nil or tonumber(value.y) == nil then error(label .. " must be {x, y}") end
  return { x = tonumber(value.x), y = tonumber(value.y) }
end

local function charted(force, surface, pos)
  return force.is_chunk_charted(surface, { x = math.floor(pos.x / 32), y = math.floor(pos.y / 32) })
end

-- The entity standing exactly at pos (its centre within 0.2), or nil. Ore is
-- ground, not an endpoint: a pole or belt on it is found, and a bare ore tile
-- is a free tile.
local function locate(surface, pos)
  local found = {}
  for _, entity in ipairs(surface.find_entities_filtered({ position = pos, radius = 0.2 })) do
    if entity.valid and entity.type ~= "resource" and math.abs(entity.position.x - pos.x) <= 0.2 and math.abs(entity.position.y - pos.y) <= 0.2 then found[#found + 1] = entity end
  end
  table.sort(found, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.name ~= b.name then return a.name < b.name end
    return a.type < b.type
  end)
  return found[1]
end

local function supports(kind, entity)
  if kind == "belt" then return BELT[entity.type] == true end
  if kind == "pipe" then
    if PIPE[entity.type] then return true end
    local ok, count = pcall(function() return #entity.fluidbox end)
    return ok and count > 0
  end
  if entity.type == "electric-pole" then return true end
  local ok, source = pcall(function() return entity.prototype.electric_energy_source_prototype end)
  return ok and source ~= nil
end

local function direction(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  if math.abs(dx) > math.abs(dy) then return dx > 0 and 4 or 12 end
  return dy > 0 and 8 or 0
end

local function key(pos) return string.format("%.3f,%.3f", pos.x, pos.y) end

local function can_place(c, proto, pos, direction_value)
  local area = placement_geometry.footprint(proto, pos, direction_value or 0)
  for _, corner in ipairs({ area.left_top,
    { x = area.right_bottom.x - 0.001, y = area.left_top.y },
    { x = area.left_top.x, y = area.right_bottom.y - 0.001 },
    { x = area.right_bottom.x - 0.001, y = area.right_bottom.y - 0.001 },
  }) do if not charted(c.force, c.surface, corner) then return false end end
  return placement_geometry.can_place(c, proto, pos, direction_value or 0)
end

-- ------------------------------------------------------------ underground

-- The underground item a belt or pipe route may hop with, its reach
-- (entrance to exit, in tiles) and, for pipes, the direction its
-- underground connection faces on a north-facing entity. requested is an
-- item name, false (no hops) or nil (the belt's own tier, or pipe-to-ground,
-- when the force can craft it or the body carries it).
function M.underground(c, kind, proto, requested)
  if requested == false or (kind ~= "belt" and kind ~= "pipe") then return nil end
  local name = requested
  if name == nil then
    if kind == "belt" then
      local ok, related = pcall(function() return proto.related_underground_belt end)
      name = ok and related and related.name or nil
    else
      name = "pipe-to-ground"
    end
  end
  local item = type(name) == "string" and prototypes.item[name]
  local under = item and item.place_result
  local wanted = kind == "belt" and "underground-belt" or "pipe-to-ground"
  if not under or under.type ~= wanted then
    if requested then error(tostring(requested) .. " is not a " .. wanted .. " item for a " .. kind .. " route", 0) end
    return nil
  end
  if requested == nil then
    local ok, usable = pcall(function()
      local recipe = c.force.recipes[name]
      return (recipe and recipe.enabled) or c.get_item_count(name) > 0
    end)
    if not (ok and usable) then return nil end
  end
  local distance, faces = nil, nil
  if kind == "belt" then
    local ok, value = pcall(function() return under.max_underground_distance end)
    distance = ok and tonumber(value) or nil
  else
    pcall(function()
      for _, box in pairs(under.fluidbox_prototypes) do
        for _, connection in ipairs(box.pipe_connections or {}) do
          if connection.connection_type == "underground" then
            distance = tonumber(connection.max_underground_distance) or distance
            faces = tonumber(connection.direction) or faces
          end
        end
      end
    end)
    if not distance then
      local ok, value = pcall(function() return under.max_underground_distance end)
      distance = ok and tonumber(value) or nil
    end
  end
  if not distance or distance < 2 then return nil end
  -- Base 2.0: a north-facing pipe-to-ground connects normally north and
  -- underground south.
  return { item = name, proto = under, distance = math.floor(distance), faces = faces or 8 }
end

-- ------------------------------------------------------------ route search

local DELTAS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
local HEADING = { 0, 4, 8, 12 }

-- A resumable shortest route by A* over tiles (Manhattan distance to the
-- nearest goal). spec = {kind = belt|pipe, item, max_length (tiles),
-- under = M.underground(..) | nil, starts = {{position, include, only?,
-- arrive?}}, goals = {{position, include}}, base? (tiles of earlier legs,
-- counted in a failure's min_length and limit)}: an included endpoint gets a
-- piece on its tile, an excluded one is an existing entity the route ends
-- against; only is the one direction a belt may leave a start in, arrive the
-- heading a waypoint start was reached with (its piece may then become an
-- underground entrance only that way). The state is plain data (parent
-- pointers, no closures), so a job keeps it in storage between ticks.
function M.new_search(spec)
  local goals, goal_list = {}, {}
  for index, goal in ipairs(spec.goals) do
    local g = { x = goal.position.x, y = goal.position.y, include = goal.include, index = index }
    goals[key(g)], goal_list[#goal_list + 1] = g, g
  end
  return { kind = spec.kind, item = spec.item, under = spec.under, max_length = spec.max_length, base = spec.base or 0,
    starts = spec.starts, goals = goals, goal_list = goal_list,
    max_nodes = math.max(2000, math.floor(spec.max_length * spec.max_length / 2)),
    heap = {}, order = 0, best = {}, fit = {}, expanded = 0, started = false }
end

-- The fewest tiles a route from (x, y) still needs: the Manhattan distance to
-- a goal, one less to an excluded goal (stepping onto it adds no piece). It
-- never overestimates and drops by at most a step's cost, so the first goal
-- popped is the shortest route and a popped node's f bounds every route left.
local function remaining(R, x, y)
  local best
  for _, g in ipairs(R.goal_list) do
    local d = math.floor(math.abs(x - g.x) + math.abs(y - g.y) + 0.5) - (g.include and 0 or 1)
    if not best or d < best then best = d end
  end
  return math.max(0, best or 0)
end

-- Manhattan tiles from (x, y) to the nearest end, for a failure's report.
local function distance_to_end(R, x, y)
  local best
  for _, g in ipairs(R.goal_list) do
    local d = math.floor(math.abs(x - g.x) + math.abs(y - g.y) + 0.5)
    if not best or d < best then best = d end
  end
  return best or 0
end

-- ------------------------------------------------------- typed failures

-- A failed search: R.failure = {code, reason, ...} and the error
-- "CODE: reason" (a deliberate refusal, never a fault).
local function fail(R, code, reason, fields)
  local row = fields or {}
  row.code, row.reason = code, reason
  R.failure, R.heap, R.best, R.fit = row, {}, {}, {}
  error(code .. ": " .. reason, 0)
end

local function closest_fields(R, fields)
  local c = R.closest
  if c then fields.closest, fields.remaining = { x = c.x, y = c.y }, c.remaining end
  return fields
end

local function nearest(R)
  local c = R.closest
  if not c then return "" end
  return string.format("; the nearest tile reached is (%.1f, %.1f), %d tiles from the end", c.x, c.y, c.remaining)
end

-- The failure of a search whose budget ended before a goal was popped, with
-- f the lowest f still open: past max_length every route left is too long
-- (f is then a lower bound on the shortest), else the budget ran out.
local function spent(R, f)
  if f and f > R.max_length then
    return { code = "ROUTE_TOO_LONG", min_length = R.base + f, lower_bound = true, limit = R.base + R.max_length,
      reason = string.format("a charted %s route needs at least %d tiles; max_length is %d (the search spent its budget, %d tiles explored, before finding the shortest)",
        R.kind, R.base + f, R.base + R.max_length, R.expanded) }
  end
  local row = closest_fields(R, { code = "SEARCH_BUDGET", explored = R.expanded })
  row.reason = string.format("the %s route search spent its budget (%d tiles explored) before reaching the end%s",
    R.kind, R.expanded, nearest(R))
  return row
end

-- The SEARCH_BUDGET (or lower-bound ROUTE_TOO_LONG) row of a search its
-- caller stopped at its own work ceiling (build_layout).
function M.spent(R)
  local row = spent(R, R.heap[1] and R.heap[1].f or nil)
  R.failure, R.heap, R.best, R.fit = row, {}, {}, {}
  return row
end

-- The typed failure behind a caught route error: R's row when the search
-- raised it, else {code, reason} when the message leads with a route code;
-- nil for any other error.
function M.failure(err, R)
  local message = errors.plain(err)
  local code, reason = message:match("^([A-Z_]+): (.*)$")
  if not (code and M.CODES[code]) then return nil end
  if R and R.failure and R.failure.code == code then return R.failure end
  return { code = code, reason = reason }
end

local function before(a, b)
  if a.f ~= b.f then return a.f < b.f end
  if a.h ~= b.h then return a.h < b.h end
  return a.order < b.order
end

local function push(R, node)
  R.order = R.order + 1
  node.order, node.h = R.order, node.goal and 0 or remaining(R, node.x, node.y)
  node.f = node.length + node.h
  local heap = R.heap
  heap[#heap + 1] = node
  local i = #heap
  while i > 1 do
    local parent = math.floor(i / 2)
    if not before(heap[i], heap[parent]) then break end
    heap[i], heap[parent] = heap[parent], heap[i]
    i = parent
  end
end

local function pop(R)
  local heap = R.heap
  local top = heap[1]
  heap[1] = heap[#heap]
  heap[#heap] = nil
  local i = 1
  while true do
    local l, r, m = 2 * i, 2 * i + 1, i
    if heap[l] and before(heap[l], heap[m]) then m = l end
    if heap[r] and before(heap[r], heap[m]) then m = r end
    if m == i then break end
    heap[i], heap[m] = heap[m], heap[i]
    i = m
  end
  return top
end

-- Whether a node improves the best length known for its state: tile, the
-- one direction it must leave in (if any) and, when hops are possible, the
-- direction it arrived in (which decides whether its piece can become an
-- underground entrance).
local function improves(R, x, y, only, arrive, length)
  local state = key({ x = x, y = y }) .. "|" .. tostring(only) .. "|" .. tostring(R.under and arrive or nil)
  if R.best[state] ~= nil and R.best[state] <= length then return false end
  R.best[state] = length
  return true
end

-- Cached placement check of one piece (role "piece" or "under").
local function fits(R, env, x, y, dir, role)
  local k = string.format("%.3f,%.3f|%s|%d", x, y, role, role == "piece" and 0 or dir)
  local value = R.fit[k]
  if value == nil then
    value = env.fits({ x = x, y = y }, dir, role) and true or false
    R.fit[k] = value
  end
  return value
end

local function piece(R, x, y) return { name = R.item, x = x, y = y } end

-- Entrance and exit of an underground pair heading d.
local function hop_pieces(R, ex, ey, xx, xy, d)
  local under = R.under
  if R.kind == "belt" then
    return { name = under.item, x = ex, y = ey, direction = d, belt_to_ground_type = "input", fixed = true },
      { name = under.item, x = xx, y = xy, direction = d, belt_to_ground_type = "output", fixed = true }
  end
  -- The entrance's underground side faces d, the exit's faces back.
  return { name = under.item, x = ex, y = ey, direction = (d - under.faces) % 16, fixed = true },
    { name = under.item, x = xx, y = xy, direction = (d + 8 - under.faces) % 16, fixed = true }
end

-- The pieces from the first start to node, in order. A hop node turns its
-- parent's piece into the entrance.
local function path_to(node)
  local reversed, entrance = {}, nil
  while node do
    if node.hop then
      reversed[#reversed + 1] = node.hop.exit
      entrance = node.hop.entrance
    elseif node.piece then
      reversed[#reversed + 1] = entrance or node.piece
      entrance = nil
    end
    node = node.parent
  end
  local path = {}
  for i = #reversed, 1, -1 do
    local step = {}
    for k, v in pairs(reversed[i]) do step[k] = v end
    path[#path + 1] = step
  end
  return path
end

-- Belt pieces point at the next piece; one on the goal tile keeps the
-- heading it arrived with. Underground ends keep their own.
local function finish(R, goal_node)
  local path = path_to(goal_node.parent)
  if goal_node.hop then
    path[#path] = nil -- re-added below as the pair
    local entrance, exit = goal_node.hop.entrance, goal_node.hop.exit
    local function copy(t) local o = {}; for k, v in pairs(t) do o[k] = v end; return o end
    path[#path + 1] = copy(entrance)
    path[#path + 1] = copy(exit)
  elseif goal_node.goal.include then
    path[#path + 1] = piece(R, goal_node.x, goal_node.y)
  end
  local to = { x = goal_node.x, y = goal_node.y }
  local seen = {}
  for index, step in ipairs(path) do
    local tile = key(step)
    if seen[tile] then error(string.format("the planned %s route crosses itself at (%.1f, %.1f)", R.kind, step.x, step.y), 0) end
    seen[tile] = true
    if not step.fixed then
      local following = path[index + 1] and { x = path[index + 1].x, y = path[index + 1].y } or to
      if R.kind ~= "belt" then
        step.direction = nil
      elseif following.x == step.x and following.y == step.y then
        local previous = path[index - 1]
        step.direction = previous and previous.direction or (R.starts[1].only or direction(R.starts[1].position, to))
      else
        step.direction = direction(step, following)
      end
    end
    step.fixed = nil
  end
  return path
end

local function start_search(R, env)
  R.started = true
  local any = false
  R.start_keys = {}
  for _, start in ipairs(R.starts) do R.start_keys[key(start.position)] = true end
  for index, start in ipairs(R.starts) do
    local s = start.position
    local goal = R.goals[key(s)]
    if goal then
      R.result = (start.include or goal.include) and { piece(R, s.x, s.y) } or {}
      if R.kind == "belt" and R.result[1] then R.result[1].direction = start.only or 0 end
      R.length, R.ends = #R.result, { start = index, goal = goal.index }
      return
    end
    local length = start.include and 1 or 0
    if (not start.include or fits(R, env, s.x, s.y, 0, "piece")) and length <= R.max_length then
      any = true
      if improves(R, s.x, s.y, start.only, start.arrive, length) then
        push(R, { x = s.x, y = s.y, length = length, only = start.only, start = true, origin = index, arrive = start.arrive,
          piece = start.include and piece(R, s.x, s.y) or nil })
      end
    end
  end
  if not any then fail(R, "ROUTE_BLOCKED", "the " .. R.kind .. " route is blocked at its source connection") end
  -- A free-tile goal that takes no piece, or a goal with no free tile beside
  -- it, is blocked: say so now, not after searching everything within
  -- max_length. (An underground belt exit may land on a free goal tile.)
  local reason
  for _, g in ipairs(R.goal_list) do
    if g.include and not fits(R, env, g.x, g.y, 0, "piece") then
      reason = reason or string.format("the %s route's end at (%.1f, %.1f) takes no piece", R.kind, g.x, g.y)
    elseif g.include and R.kind == "belt" and R.under then
      return
    else
      for _, delta in ipairs(DELTAS) do
        local nx, ny = g.x + delta[1], g.y + delta[2]
        if R.start_keys[key({ x = nx, y = ny })] or fits(R, env, nx, ny, 0, "piece") then return end
      end
      reason = reason or string.format("the %s route's end at (%.1f, %.1f) is walled in: no free tile beside it", R.kind, g.x, g.y)
    end
  end
  fail(R, "ROUTE_BLOCKED", reason)
end

-- Whether (x, y) is one of node's last PATH_CHECK tiles. With hops a state
-- holds its arrival heading, so a route could turn round over its own tile
-- to reach a tile in another heading; such a turn is short, and a longer
-- crossing is still refused by finish.
local function on_path(node, x, y)
  for _ = 1, PATH_CHECK do
    if not node then return false end
    if node.x == x and node.y == y then return true end
    node = node.parent
  end
  return false
end

-- Expands one node: plain steps to the four neighbours, and where the next
-- tile is blocked, underground hops from this node's own piece.
local function expand(R, env, current)
  for index, delta in ipairs(DELTAS) do
    local d = HEADING[index]
    if not current.only or current.only == d then
      local nx, ny = current.x + delta[1], current.y + delta[2]
      local goal = R.goals[key({ x = nx, y = ny })]
      local blocked = false
      if goal then
        local length = current.length + (goal.include and 1 or 0)
        if (not goal.include or fits(R, env, nx, ny, d, "piece"))
          and improves(R, nx, ny, "goal", nil, length) then
          push(R, { x = nx, y = ny, length = length, parent = current, goal = goal })
        end
      elseif R.start_keys[key({ x = nx, y = ny })] then
        -- A route never returns over its own start.
      else
        if fits(R, env, nx, ny, d, "piece") then
          if not (R.under and on_path(current, nx, ny)) and improves(R, nx, ny, nil, d, current.length + 1) then
            push(R, { x = nx, y = ny, length = current.length + 1, parent = current, arrive = d,
              piece = piece(R, nx, ny) })
          end
        else
          blocked = true
        end
      end
      -- An underground pair: this node's plain piece becomes the entrance
      -- (the route must arrive heading d), the exit lands past the obstacle.
      local entrance_ok = current.piece ~= nil and not current.hop and (current.arrive == d
        or (current.start and R.kind == "belt" and current.arrive == nil and (current.only == nil or current.only == d)))
      if blocked and R.under and entrance_ok then
        for span = 2, R.under.distance do
          local xx, xy = current.x + delta[1] * span, current.y + delta[2] * span
          local length = current.length + span
          local landing = R.goals[key({ x = xx, y = xy })]
          if landing and not (landing.include and R.kind == "belt") then break end
          if R.start_keys[key({ x = xx, y = xy })] then break end
          local entrance, exit = hop_pieces(R, current.x, current.y, xx, xy, d)
          if span == 2 and not fits(R, env, current.x, current.y, entrance.direction, "under") then break end
          if fits(R, env, xx, xy, exit.direction, "under") and not on_path(current, xx, xy)
            and (not env.gap_clear or env.gap_clear({ x = current.x, y = current.y }, { x = xx, y = xy }, d))
            and improves(R, xx, xy, landing and "goal" or d, landing and nil or d, length) then
            push(R, { x = xx, y = xy, length = length, parent = current, only = not landing and d or nil,
              arrive = d, hop = { entrance = entrance, exit = exit }, goal = landing })
          end
        end
      end
    end
  end
end

-- Advances the search while env.more() allows. Returns the route's pieces
-- once found (R.length its tiles, R.ends the start and goal it joins); nil
-- when the tick's budget is spent first; raises a typed failure (M.failure)
-- when no route fits max_length.
-- env = {fits(pos, direction, role), gap_clear?(entrance, exit, d), more()}.
function M.search_step(R, env)
  if R.result then return R.result end
  if not R.started then
    start_search(R, env)
    if R.result then return R.result end
  end
  while #R.heap > 0 do
    if not env.more() then return nil end
    local current = pop(R)
    if current.goal then
      if current.length > R.max_length then
        fail(R, "ROUTE_TOO_LONG", string.format("the shortest charted %s route is %d tiles; max_length is %d",
          R.kind, R.base + current.length, R.base + R.max_length),
          { min_length = R.base + current.length, limit = R.base + R.max_length })
      end
      local origin = current
      while origin.parent do origin = origin.parent end
      R.result, R.length, R.ends = finish(R, current), current.length, { start = origin.origin, goal = current.goal.index }
      R.heap, R.best, R.fit = {}, {}, {}
      return R.result
    end
    local near = distance_to_end(R, current.x, current.y)
    if not R.closest or near < R.closest.remaining then R.closest = { x = current.x, y = current.y, remaining = near } end
    R.expanded = R.expanded + 1
    if R.expanded > R.max_nodes then
      R.expanded = R.expanded - 1
      local row = spent(R, current.f)
      fail(R, row.code, row.reason, row)
    end
    if env.spend then env.spend(NODE_COST) end
    expand(R, env, current)
  end
  fail(R, "ROUTE_BLOCKED", string.format("no charted %s route reaches the end%s", R.kind, nearest(R)), closest_fields(R, {}))
end

-- ------------------------------------------------------------- endpoints

-- A machine's free fluid ports, each with the fluid its box takes.
local function free_ports(entity)
  local rows, fluids = {}, {}
  for _, connection in ipairs(fluid_connections.live(entity)) do
    if not connection.connected_target then
      local index = connection.fluidbox_index
      if fluids[index] == nil then fluids[index] = fluid_connections.box_fluid(entity, index, connection.filter) or false end
      rows[#rows + 1] = { position = connection.target_position, fluid = fluids[index] or nil }
    end
  end
  return rows
end

-- Free fluid ports of a machine as route terminals on the tile outside each:
-- those for fluid (or, when none takes it by name, those that take anything).
local function machine_ports(entity, fluid)
  local rows = free_ports(entity)
  if fluid then
    local exact, open = {}, {}
    for _, row in ipairs(rows) do
      if row.fluid == fluid then exact[#exact + 1] = row elseif row.fluid == nil then open[#open + 1] = row end
    end
    rows = #exact > 0 and exact or open
  end
  local terminals = {}
  for _, row in ipairs(rows) do terminals[#terminals + 1] = { position = row.position, include = true } end
  return terminals
end

local function port_filters(entity)
  local set = {}
  for _, row in ipairs(free_ports(entity)) do if row.fluid then set[row.fluid] = true end end
  return set
end

local function names(set)
  local out = {}
  for name in pairs(set) do out[#out + 1] = name end
  table.sort(out)
  return out
end

-- The fluid a pipe route carries: given, or the one filter both ends share
-- (or the only one one end has).
local function route_fluid(fluid, from_entity, to_entity)
  if fluid then return fluid end
  local from = from_entity and not PIPE[from_entity.type] and port_filters(from_entity) or {}
  local to = to_entity and not PIPE[to_entity.type] and port_filters(to_entity) or {}
  local common = {}
  for name in pairs(from) do if to[name] then common[name] = true end end
  local list = names(common)
  if #list == 1 then return list[1] end
  if #list > 1 then error("the ends share ports for " .. table.concat(list, ", ") .. "; say which with fluid", 0) end
  local a, b = names(from), names(to)
  if #a > 0 and #b > 0 then
    error(string.format("no matching ports: one end carries %s, the other %s", table.concat(a, ", "), table.concat(b, ", ")), 0)
  end
  local only = #a > 0 and a or b
  if #only == 1 then return only[1] end
  if #only > 1 then error("the machine has ports for " .. table.concat(only, ", ") .. "; say which with fluid", 0) end
  return nil
end

local function entity_box(entity)
  return entity.bounding_box or entity.selection_box or {
    left_top = { x = entity.position.x - 0.1, y = entity.position.y - 0.1 },
    right_bottom = { x = entity.position.x + 0.1, y = entity.position.y + 0.1 },
  }
end

-- A power route's typed failure into P (a plain table, fail's R): poles are
-- placed by arithmetic, not searched, so ROUTE_BLOCKED gives at, the pole
-- position that takes no pole, and ROUTE_TOO_LONG a lower bound in poles.
local function pole_blocked(P, pos)
  fail(P or {}, "ROUTE_BLOCKED", string.format("power route is blocked at (%.1f, %.1f)", pos.x, pos.y),
    { at = { x = pos.x, y = pos.y } })
end

local function poles_beyond(P, needed, limit)
  fail(P or {}, "ROUTE_TOO_LONG", string.format("a power route needs at least %d poles; max_length is %d", needed, limit),
    { min_length = needed, lower_bound = true, limit = limit })
end

local function terminal_pole(c, item_name, proto, entity, tile, P)
  local reach_new = tonumber(proto.get_max_wire_distance("normal"))
  if not entity then
    if not can_place(c, proto, tile, 0) then pole_blocked(P, tile) end
    return { position = tile, reach = reach_new, step = { name = item_name, x = tile.x, y = tile.y } }
  end
  if entity.type == "electric-pole" then
    local reach = tonumber(entity.prototype.get_max_wire_distance(entity.quality))
    if not reach then error("power pole endpoint does not expose wire reach") end
    return { position = entity.position, reach = reach, step = nil }
  end
  local supply = tonumber(proto.get_supply_area_distance("normal"))
  if not supply or not reach_new then error("power route prototype must expose supply area and wire reach") end
  local box, candidates = entity_box(entity), {}
  local min_x, max_x = math.floor(box.left_top.x - supply), math.ceil(box.right_bottom.x + supply)
  local min_y, max_y = math.floor(box.left_top.y - supply), math.ceil(box.right_bottom.y + supply)
  for y = min_y, max_y do
    for x = min_x, max_x do
      local pos = { x = x + 0.5, y = y + 0.5 }
      local dx = math.max(box.left_top.x - pos.x, 0, pos.x - box.right_bottom.x)
      local dy = math.max(box.left_top.y - pos.y, 0, pos.y - box.right_bottom.y)
      if dx <= supply and dy <= supply and can_place(c, proto, pos, 0) then
        local px, py = pos.x - entity.position.x, pos.y - entity.position.y
        candidates[#candidates + 1] = { position = pos, distance = px * px + py * py }
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return a.position.x < b.position.x
  end)
  if not candidates[1] then
    fail(P or {}, "ROUTE_BLOCKED", string.format("no charted physical pole placement covers the power endpoint at (%.1f, %.1f)",
      entity.position.x, entity.position.y), { at = { x = entity.position.x, y = entity.position.y } })
  end
  local pos = candidates[1].position
  return { position = pos, reach = reach_new, step = { name = item_name, x = pos.x, y = pos.y } }
end

-- Intermediate poles on the placement grid for one segment count, or nil
-- when a snapped span exceeds spacing or the last one final_reach.
local function snapped_span(from, to, segments, spacing, final_reach)
  local dx, dy = to.x - from.x, to.y - from.y
  local positions, previous = {}, from
  for index = 1, segments - 1 do
    local fraction = index / segments
    local pos = { x = math.floor(from.x + dx * fraction) + 0.5, y = math.floor(from.y + dy * fraction) + 0.5 }
    local gap_x, gap_y = pos.x - previous.x, pos.y - previous.y
    if math.sqrt(gap_x * gap_x + gap_y * gap_y) > spacing then return nil end
    positions[#positions + 1] = pos
    previous = pos
  end
  local last_dx, last_dy = to.x - previous.x, to.y - previous.y
  if math.sqrt(last_dx * last_dx + last_dy * last_dy) > final_reach then return nil end
  return positions
end

-- Intermediate poles on the placement grid between two pole positions, so no
-- wire span exceeds spacing and the last one fits final_reach. Snapping a pole
-- to a tile centre moves it up to half a tile per axis, so a span may grow by
-- up to about 1.5 tiles; then one more pole shortens every span. Spans of
-- spacing - 1.5 always fit, so this is arithmetic over a few counts. fixed:
-- the terminal poles already counted against max_length (fixed + budget).
local function pole_span(fits_pole, item_name, from, to, spacing, final_reach, budget, P, fixed)
  local dx, dy = to.x - from.x, to.y - from.y
  local segments = math.ceil(math.sqrt(dx * dx + dy * dy) / spacing)
  fixed = fixed or 0
  local positions
  while true do
    if segments - 1 > budget then poles_beyond(P, segments - 1 + fixed, budget + fixed) end
    positions = snapped_span(from, to, segments, spacing, final_reach)
    if positions then break end
    segments = segments + 1
  end
  local steps = {}
  for _, pos in ipairs(positions) do
    if not fits_pole(pos) then pole_blocked(P, pos) end
    steps[#steps + 1] = { name = item_name, x = pos.x, y = pos.y }
  end
  return steps
end

-- Poles between two endpoints (entities or free tiles). Linear in the
-- route's pole count, so it runs in one step. A failure is typed into P.
local function power_route(c, item_name, proto, from, to, from_entity, to_entity, max_length, P)
  local new_reach = tonumber(proto.get_max_wire_distance("normal"))
  if not new_reach then error("power route prototype must expose wire reach") end
  local from_terminal = terminal_pole(c, item_name, proto, from_entity, from, P)
  local to_terminal = terminal_pole(c, item_name, proto, to_entity, to, P)
  local from_reach, to_reach = from_terminal.reach, to_terminal.reach
  from, to = from_terminal.position, to_terminal.position
  local steps = {}
  if from_terminal.step then steps[#steps + 1] = from_terminal.step end
  local terminal_count = (from_terminal.step and 1 or 0) + (to_terminal.step and 1 or 0)
  if terminal_count > max_length then poles_beyond(P, terminal_count, max_length) end
  local dx, dy = to.x - from.x, to.y - from.y
  if math.sqrt(dx * dx + dy * dy) <= math.min(from_reach, to_reach) then
    if to_terminal.step then steps[#steps + 1] = to_terminal.step end
    return steps
  end
  for _, step in ipairs(pole_span(function(pos) return can_place(c, proto, pos, 0) end, item_name, from, to,
    math.min(new_reach, from_reach, to_reach), math.min(new_reach, to_reach), max_length - terminal_count, P, terminal_count)) do
    steps[#steps + 1] = step
  end
  if to_terminal.step then steps[#steps + 1] = to_terminal.step end
  return steps
end

-- Layout poles (build_layout), between planned endpoints that may not exist
-- yet: poles at from and to (unless has_pole says one stands or is planned
-- there) and between them within wire reach. A failure is typed into P
-- (M.failure(err, P)).
function M.route_poles(item_name, proto, from, to, max_length, fits_pole, has_pole, P)
  local reach = tonumber(proto.get_max_wire_distance("normal"))
  if not reach then error("power route prototype must expose wire reach") end
  local function pole_at(endpoint)
    if has_pole(endpoint) then return nil end
    if not fits_pole(endpoint) then pole_blocked(P, endpoint) end
    return { name = item_name, x = endpoint.x, y = endpoint.y }
  end
  local head = pole_at(from)
  local tail = not (from.x == to.x and from.y == to.y) and pole_at(to) or nil
  local terminals = (head and 1 or 0) + (tail and 1 or 0)
  local steps = { head }
  for _, step in ipairs(pole_span(fits_pole, item_name, from, to, reach, reach, max_length - terminals, P, terminals)) do
    steps[#steps + 1] = step
  end
  steps[#steps + 1] = tail
  return steps
end

-- ------------------------------------------------------------------- job

-- The game's pipeline extent limit: UtilityConstants default_pipeline_extent
-- (320 in 2.0.77). A FluidBox's max_pipeline_extent may lower it for a
-- pipeline holding that box, but 2.0.77 has it only at the prototype stage
-- (no runtime field) and base and Space Age set none.
local function pipeline_limit()
  local ok, value = pcall(function() return prototypes.utility_constants.default_pipeline_extent end)
  return ok and tonumber(value) or nil
end

-- The fluid segment a pipe route makes, as a row {extent, limit,
-- over_extent?, standing?, standing_uncharted?}: extent is the larger side of
-- its bounding box in tiles (2.0.77: a straight run of 320 pipes works, 321
-- is overextended, an L of 160 by 162 works), over the route's pieces and
-- every standing segment a piece connects to (standing: how many), found by
-- a survey of each piece's neighbours over ticks within the job budget: a
-- neighbour of the companion's force whose normal pipe connection points at
-- the piece, on a side the piece connects on (a pipe all four, a
-- pipe-to-ground its normal side). A standing segment whose box reaches
-- uncharted ground is only counted in standing_uncharted. A crafting
-- machine's fluid box belongs to no segment (2.0.77: get_fluid_segment_id is
-- nil on it, piped or not), so it adds nothing.
local function segment_start(steps)
  local seg = { next = 1, seen = {}, standing = 0, uncharted = 0 }
  for _, s in ipairs(steps) do
    local x, y = math.floor(s.x), math.floor(s.y)
    seg.min_x, seg.min_y = math.min(seg.min_x or x, x), math.min(seg.min_y or y, y)
    seg.max_x, seg.max_y = math.max(seg.max_x or x, x), math.max(seg.max_y or y, y)
  end
  return seg
end

-- The tile offsets a planned piece connects on.
local function piece_sides(state, s)
  local under = state.under
  if under and s.name == under.item then
    -- Its underground side faces direction + faces; the normal side is opposite.
    local side = ((s.direction or 0) + under.faces + 8) % 16
    return { DELTAS[side / 4 + 1] }
  end
  return DELTAS
end

-- Surveys the next piece's neighbours.
local function segment_scan(c, state, steps, budget)
  local seg = state.segment
  local s = steps[seg.next]
  seg.next = seg.next + 1
  local x, y = math.floor(s.x), math.floor(s.y)
  local wanted = {}
  for _, d in ipairs(piece_sides(state, s)) do wanted[(x + d[1]) .. "," .. (y + d[2])] = true end
  budget.left = budget.left - GAP_COST
  local ok, found = pcall(c.surface.find_entities_filtered,
    { area = { left_top = { x = x - 0.9, y = y - 0.9 }, right_bottom = { x = x + 1.9, y = y + 1.9 } }, force = c.force })
  if not (ok and type(found) == "table") then return end
  for _, e in ipairs(found) do
    budget.left = budget.left - NODE_COST
    if e.valid and charted(c.force, c.surface, e.position) then
      for _, row in ipairs(fluid_connections.live(e)) do
        local t, from = row.target_position, row.position
        if (row.connection_type == nil or row.connection_type == "normal") and math.floor(t.x) == x and math.floor(t.y) == y
          and wanted[math.floor(from.x) .. "," .. math.floor(from.y)] then
          local id_ok, id = pcall(function() return e.fluidbox.get_fluid_segment_id(row.fluidbox_index) end)
          if id_ok and id and not seg.seen[id] then
            seg.seen[id] = true
            budget.left = budget.left - FIT_COST
            local bb_ok, bb = pcall(function() return e.fluidbox.get_fluid_segment_extent_bounding_box(row.fluidbox_index) end)
            if bb_ok and type(bb) == "table" and bb.left_top then
              if charted(c.force, c.surface, bb.left_top) and charted(c.force, c.surface, bb.right_bottom) then
                seg.standing = seg.standing + 1
                seg.min_x, seg.min_y = math.min(seg.min_x, math.floor(bb.left_top.x)), math.min(seg.min_y, math.floor(bb.left_top.y))
                seg.max_x = math.max(seg.max_x, math.ceil(bb.right_bottom.x) - 1)
                seg.max_y = math.max(seg.max_y, math.ceil(bb.right_bottom.y) - 1)
              else
                seg.uncharted = seg.uncharted + 1
              end
            end
          end
        end
      end
    end
  end
end

local function segment_row(seg)
  local row = { extent = math.max(seg.max_x - seg.min_x, seg.max_y - seg.min_y) + 1, limit = pipeline_limit() }
  if row.limit and row.extent > row.limit then row.over_extent = true end
  if seg.standing > 0 then row.standing = seg.standing end
  if seg.uncharted > 0 then row.standing_uncharted = seg.uncharted end
  return row
end

local function tile_key(pos) return math.floor(pos.x) .. "," .. math.floor(pos.y) end

local function manhattan(a, b) return math.floor(math.abs(a.x - b.x) + math.abs(a.y - b.y) + 0.5) end

-- Whether a new underground pair (entrance, exit) leaves the earlier legs'
-- pairs ({a, b} each) paired as laid: no earlier end lies strictly between
-- the new ends, and neither new end lies strictly inside an earlier pair's
-- span on the same line (it would pair with that pair's entrance instead).
function M.pairs_clear(pairs, entrance, exit)
  local vertical = entrance.x == exit.x
  local function between(v, lo, hi) return v > math.min(lo, hi) and v < math.max(lo, hi) end
  for _, p in ipairs(pairs) do
    for _, u in ipairs({ p.a, p.b }) do
      if vertical and u.x == entrance.x and between(u.y, entrance.y, exit.y) then return false end
      if not vertical and u.y == entrance.y and between(u.x, entrance.x, exit.x) then return false end
    end
    if vertical and p.a.x == p.b.x and p.a.x == entrance.x
      and (between(entrance.y, p.a.y, p.b.y) or between(exit.y, p.a.y, p.b.y)) then return false end
    if not vertical and p.a.y == p.b.y and p.a.y == entrance.y
      and (between(entrance.x, p.a.x, p.b.x) or between(exit.x, p.a.x, p.b.x)) then return false end
  end
  return true
end

-- Starts the search of the current leg. A leg after the first starts at its
-- waypoint: from the underground exit the last leg put there (no new
-- piece), else on the last leg's piece there, taken back so this leg lays it
-- again pointing on (and an underground entrance only in the way it was
-- reached).
local function begin_leg(state)
  local k, via = state.leg, state.via
  local starts = state.first_starts
  if k > 1 then
    local wp, last = via[k - 1], state.steps[#state.steps]
    if last and last.belt_to_ground_type == "output" and tile_key(last) == tile_key(wp) then
      starts = { { position = wp, include = false, only = last.direction } }
    else
      state.steps[#state.steps] = nil
      state.occupied[tile_key(wp)] = nil
      state.used = state.used - 1
      local before = state.steps[#state.steps]
      local arrive = state.kind == "belt" and last and last.direction or (before and direction(before, wp)) or nil
      starts = { { position = wp, include = true, arrive = arrive } }
    end
  end
  local goals = k <= #via and { { position = via[k], include = true } } or state.last_goals
  state.search = M.new_search({ kind = state.kind, item = state.prototype, max_length = math.max(0, state.max_length - state.used),
    base = state.used, under = state.under, starts = starts, goals = goals })
end

-- The route of every leg, in order; nil while the tick's budget is spent.
-- Raises a typed failure (M.failure) naming the leg that failed.
local function route_legs(c, state, budget)
  local under = state.under
  local env = {
    more = function() return budget.left > 0 end,
    spend = function(n) budget.left = budget.left - n end,
    fits = function(pos, dir, role)
      if state.occupied[tile_key(pos)] then return false end
      budget.left = budget.left - FIT_COST
      return can_place(c, role == "under" and under.proto or state.proto, pos, dir)
    end,
    -- Another underground of the same item on the axis between the ends,
    -- standing or laid by an earlier leg, would pair with the entrance
    -- instead; so would a new pair inside an earlier leg's pair.
    gap_clear = function(entrance, exit, d)
      budget.left = budget.left - GAP_COST
      if not M.pairs_clear(state.unders, entrance, exit) then return false end
      local area = { left_top = { x = math.min(entrance.x, exit.x) - 0.4, y = math.min(entrance.y, exit.y) - 0.4 },
        right_bottom = { x = math.max(entrance.x, exit.x) + 0.4, y = math.max(entrance.y, exit.y) + 0.4 } }
      local ok, found = pcall(c.surface.find_entities_filtered, { area = area, name = under.proto.name })
      return ok and type(found) == "table" and #found == 0
    end,
  }
  while true do
    if not state.search then begin_leg(state) end
    local R = state.search
    local ok, leg = pcall(M.search_step, R, env)
    if not ok then
      local failure = M.failure(leg, R)
      if failure and #state.via > 0 then
        local k = state.leg
        if failure.code == "ROUTE_TOO_LONG" then
          -- Earlier legs count as routed; legs after this one add at least
          -- the Manhattan tiles between their ends.
          if k <= #state.via then
            local rest, previous = 0, state.via[k]
            for j = k + 1, #state.via do rest, previous = rest + manhattan(previous, state.via[j]), state.via[j] end
            local last
            for _, g in ipairs(state.last_goals) do
              local d = math.max(0, manhattan(previous, g.position) - (g.include and 0 or 1))
              if not last or d < last then last = d end
            end
            failure.min_length, failure.lower_bound = failure.min_length + rest + (last or 0), true
          end
          failure.reason = string.format("a charted %s route through the waypoints, its earlier legs as routed, %s %d tiles; max_length is %d",
            state.kind, failure.lower_bound and "needs at least" or "is", failure.min_length, failure.limit)
        end
        failure.leg = k - 1
        failure.reason = failure.reason .. (k <= #state.via and string.format(" (the leg to via[%d])", k - 1)
          or " (the leg to `to`)")
      end
      error(leg, 0)
    end
    if not leg then return nil end
    local entrance
    for _, s in ipairs(leg) do
      state.steps[#state.steps + 1] = s
      state.occupied[tile_key(s)] = true
      if under and s.name == under.item then
        if entrance then
          state.unders[#state.unders + 1] = { a = entrance, b = { x = s.x, y = s.y } }
          entrance = nil
        else
          entrance = { x = s.x, y = s.y }
        end
      end
    end
    state.used = state.used + R.length
    if state.leg > #state.via then return state.steps end
    state.leg, state.search = state.leg + 1, nil
  end
end

-- connect_entities {kind, prototype, from, to, max_length? (1-200, default
-- 200), via? (belt and pipe: up to MAX_VIA waypoints {x, y}), fluid? (pipe),
-- underground? (item name, or false for none), joins? (true for a dry run)}
-- -> {kind, prototype, from, to, via?, length, steps, physical, ghosts,
-- belt_joins?, fluid_segments?} or, when no route fits, {kind, prototype,
-- from, to, via?, failure = {code, reason, ...}} (M.failure; leg: the via
-- index the failing leg ends at, #via for the leg to `to`). Steps are
-- build_plan placements; underground belt ends carry belt_to_ground_type.
-- The route passes the waypoints in order, a piece on each, each leg its own
-- search with its own node budget; max_length bounds the whole route. With
-- joins, a belt route also lists where it joins standing belts
-- (belt_joins.lua), surveyed after the search within the same job budget; a
-- pipe route lists its fluid segment against the game's pipeline extent,
-- surveyed the same way (segment_scan). A power route that fits no poles
-- fails typed too. Nothing is built: the caller queues the steps.
local function start(params)
  local c = companion.require_companion()
  local kind = params.kind
  if kind ~= "belt" and kind ~= "pipe" and kind ~= "power" then error("connect_entities kind must be belt, pipe, or power", 0) end
  if type(params.prototype) ~= "string" then error("connect_entities prototype must be a placeable item name", 0) end
  local item = prototypes.item[params.prototype]
  local proto = item and item.place_result
  if not proto then error(params.prototype .. " is not a placeable route prototype", 0) end
  if (kind == "belt" and proto.type ~= "transport-belt")
    or (kind == "pipe" and proto.type ~= "pipe")
    or (kind == "power" and proto.type ~= "electric-pole") then
    error(params.prototype .. " is not a supported physical " .. kind .. " route prototype", 0)
  end
  local from, to = position(params.from, "connect_entities from"), position(params.to, "connect_entities to")
  local max_length = math.floor(tonumber(params.max_length) or M.MAX_LENGTH)
  if max_length < 1 or max_length > M.MAX_LENGTH then
    error("connect_entities max_length must be 1-" .. M.MAX_LENGTH, 0)
  end
  if params.fluid ~= nil and (kind ~= "pipe" or type(params.fluid) ~= "string") then
    error("connect_entities fluid names the fluid of a pipe route", 0)
  end
  if params.underground ~= nil and params.underground ~= false and type(params.underground) ~= "string" then
    error("connect_entities underground is an underground item name, or false for none", 0)
  end
  if params.joins ~= nil and type(params.joins) ~= "boolean" then
    error("connect_entities joins is true for a dry run's belt joins", 0)
  end
  if not charted(c.force, c.surface, from) or not charted(c.force, c.surface, to) then
    error("connect_entities endpoints must both be force-charted", 0)
  end
  local function tile(p) return { x = math.floor(p.x) + 0.5, y = math.floor(p.y) + 0.5 } end
  local via = {}
  if params.via ~= nil then
    if kind == "power" then error("connect_entities via routes belts and pipes", 0) end
    if type(params.via) ~= "table" or #params.via > M.MAX_VIA then
      error("connect_entities via is a list of up to " .. M.MAX_VIA .. " waypoints {x, y}", 0)
    end
    -- from, each waypoint and to are distinct tiles.
    local named = { [tile_key(from)] = "from" }
    for i, point in ipairs(params.via) do
      local name = "via[" .. (i - 1) .. "]"
      local wp = tile(position(point, "connect_entities " .. name))
      if not charted(c.force, c.surface, wp) then error("connect_entities " .. name .. " must be force-charted", 0) end
      if named[tile_key(wp)] then error("connect_entities " .. name .. " repeats the tile of " .. named[tile_key(wp)], 0) end
      via[i], named[tile_key(wp)] = wp, name
    end
    if #via > 0 and named[tile_key(to)] then error("connect_entities to repeats the tile of " .. named[tile_key(to)], 0) end
  end
  local from_entity, to_entity = locate(c.surface, from), locate(c.surface, to)
  for _, pair in ipairs({ { from_entity, from }, { to_entity, to } }) do
    local entity, at = pair[1], pair[2]
    if entity and not supports(kind, entity) then
      error(string.format("the endpoint at (%.1f, %.1f) is a %s, which takes no %s connection", at.x, at.y, entity.name, kind), 0)
    end
  end
  local state = { kind = kind, prototype = params.prototype, proto = proto, from = from, to = to, max_length = max_length,
    from_entity = from_entity, to_entity = to_entity, report_joins = params.joins == true }
  if kind == "power" then
    state.from, state.to = from_entity and from or tile(from), to_entity and to or tile(to)
    return state
  end
  local starts, goals
  local function exact(entity) local p = entity.position; return { x = p.x, y = p.y } end
  if kind == "belt" then
    starts = { from_entity and { position = exact(from_entity), include = false, only = from_entity.direction }
      or { position = tile(from), include = true } }
    goals = { to_entity and { position = exact(to_entity), include = false } or { position = tile(to), include = true } }
  else
    local fluid = route_fluid(params.fluid, from_entity, to_entity)
    local function terminals(entity, at)
      if not entity then return { { position = tile(at), include = true } } end
      if PIPE[entity.type] then return { { position = exact(entity), include = false } } end
      local ports = machine_ports(entity, fluid)
      if #ports == 0 then
        error(string.format("%s at (%.1f, %.1f) has no free %sport", entity.name, at.x, at.y, fluid and (fluid .. " ") or ""), 0)
      end
      return ports
    end
    starts, goals = terminals(from_entity, from), terminals(to_entity, to)
    state.fluid = fluid
  end
  state.under, state.first_starts, state.last_goals = M.underground(c, kind, proto, params.underground), starts, goals
  state.via, state.leg, state.used, state.steps, state.occupied, state.unders = via, 1, 0, {}, {}, {}
  return state
end

local function step(state, budget)
  local c = companion.require_companion()
  local steps
  if state.kind == "power" then
    -- The job may step on a later tick: an endpoint mined since is no route.
    for _, pair in ipairs({ { state.from_entity, state.from }, { state.to_entity, state.to } }) do
      if pair[1] and not pair[1].valid then
        error(string.format("the power endpoint at (%.1f, %.1f) is gone", pair[2].x, pair[2].y), 0)
      end
    end
    local P = {}
    local ok, value = pcall(power_route, c, state.prototype, state.proto, state.from, state.to, state.from_entity,
      state.to_entity, state.max_length, P)
    if not ok then
      local failure = M.failure(value, P)
      if not failure then error(value, 0) end
      return { kind = state.kind, prototype = state.prototype, from = state.from, to = state.to, failure = failure }
    end
    steps = value
    budget.left = budget.left - FIT_COST * (#steps + 2)
  elseif state.route then
    steps = state.route
  else
    local ok, value = pcall(route_legs, c, state, budget)
    if not ok then
      local failure = M.failure(value, state.search)
      if not failure then error(value, 0) end
      return { kind = state.kind, prototype = state.prototype, from = state.from, to = state.to,
        via = #state.via > 0 and state.via or nil, fluid = state.fluid, failure = failure }
    end
    if not value then return nil end
    steps, state.route, state.search, state.occupied = value, value, nil, nil
  end
  local out = { kind = state.kind, prototype = state.prototype, from = state.from, to = state.to,
    via = state.via and #state.via > 0 and state.via or nil, fluid = state.fluid,
    length = #steps, steps = steps, physical = true, ghosts = false }
  if state.kind == "pipe" and #steps > 0 then
    -- The pieces' neighbours, a scan per piece within the budget, over ticks.
    state.segment = state.segment or segment_start(steps)
    while state.segment.next <= #steps do
      if budget.left <= 0 then return nil end
      segment_scan(c, state, steps, budget)
    end
    out.fluid_segments = { segment_row(state.segment) }
  end
  if state.kind ~= "belt" or #steps == 0 or not state.report_joins then return out end
  -- The route's belt joins, a scan per piece within the budget, over ticks.
  if not state.joins then
    local planned = {}
    for _, s in ipairs(steps) do
      local item = prototypes.item[s.name]
      local proto = item and item.place_result
      if proto then
        local position, direction = { x = s.x, y = s.y }, s.direction or 0
        planned[#planned + 1] = { name = proto.name, proto = proto, position = position, direction = direction,
          area = placement_geometry.footprint(proto, position, direction), under = s.belt_to_ground_type }
      end
    end
    state.planned, state.tiles, state.joins = planned, belt_joins.index(planned), belt_joins.start(planned)
  end
  local io = {
    query = function(area)
      budget.left = budget.left - GAP_COST
      local ok, found = pcall(c.surface.find_entities_filtered, { area = area, type = belt_joins.TYPES, force = c.force })
      if not (ok and type(found) == "table") then return {} end
      budget.left = budget.left - math.ceil(#found / 4)
      local seen = {}
      for _, e in ipairs(found) do
        if e.valid and charted(c.force, c.surface, e.position) then seen[#seen + 1] = e end
      end
      return seen
    end,
    charge = function(n) budget.left = budget.left - n end,
    charted = function(point) return charted(c.force, c.surface, point) end,
  }
  while not belt_joins.done(state.joins) do
    if budget.left <= 0 then return nil end
    budget.left = budget.left - NODE_COST
    belt_joins.scan(state.joins, state.planned, state.tiles, io)
  end
  local rows = belt_joins.finish(state.joins, state.planned, state.tiles, io)
  if #rows > 0 then out.belt_joins = rows end
  return out
end

M.job = { start = start, step = step }

return M
