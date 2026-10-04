-- Deterministic physical route planning between exact, already-charted endpoints.
local companion = require("scripts.companion")
local placement_geometry = require("scripts.placement_geometry")
local fluid_connections = require("scripts.fluid_connections")

local M = {}
local BELT = { ["transport-belt"] = true }
local PIPE = { pipe = true }

local function position(value, label)
  if type(value) ~= "table" or tonumber(value.x) == nil or tonumber(value.y) == nil then error(label .. " must be {x, y}") end
  return { x = tonumber(value.x), y = tonumber(value.y) }
end

local function charted(force, surface, pos)
  return force.is_chunk_charted(surface, { x = math.floor(pos.x / 32), y = math.floor(pos.y / 32) })
end

local function locate(surface, pos)
  local found = {}
  for _, entity in ipairs(surface.find_entities_filtered({ position = pos, radius = 0.2 })) do
    if entity.valid and math.abs(entity.position.x - pos.x) <= 0.2 and math.abs(entity.position.y - pos.y) <= 0.2 then found[#found + 1] = entity end
  end
  table.sort(found, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.name ~= b.name then return a.name < b.name end
    return a.type < b.type
  end)
  if not found[1] then error(string.format("no exact entity endpoint at (%.1f, %.1f)", pos.x, pos.y)) end
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

-- fits(position, direction) says whether one route piece may stand there;
-- from_direction (belts) is the direction the first piece must leave in.
-- A shortest route by A* over tiles (Manhattan distance to the goal), so on
-- open ground the work follows the route's length, not the area within
-- max_length. Nodes keep parent pointers; fits is asked once per tile; ties
-- break by insertion order, so every peer finds the same route.
local function grid_route(fits, item_name, from, to, max_length, kind, from_direction, include_from, include_to)
  local dx, dy = to.x - from.x, to.y - from.y
  if math.abs(dx - math.floor(dx + 0.5)) > 0.001 or math.abs(dy - math.floor(dy + 0.5)) > 0.001 then
    error(kind .. " endpoints must lie on the same one-tile placement grid")
  end
  local function remaining(p) return math.floor(math.abs(p.x - to.x) + math.abs(p.y - to.y) + 0.5) end
  local start = { position = from, length = 0 }
  if include_from then
    if not fits(from, 0) then error("physical " .. kind .. " route is blocked at its source connection") end
    start.step, start.length = { name = item_name, x = from.x, y = from.y }, 1
  end
  if start.length > max_length then error(kind .. " route exceeds max_length at its source connection") end
  local heap, order = {}, 0
  local function before(a, b)
    if a.f ~= b.f then return a.f < b.f end
    if a.h ~= b.h then return a.h < b.h end
    return a.order < b.order
  end
  local function push(node)
    order = order + 1
    node.order, node.h = order, node.goal and 0 or remaining(node.position)
    node.f = node.length + node.h
    heap[#heap + 1] = node
    local i = #heap
    while i > 1 do
      local parent = math.floor(i / 2)
      if not before(heap[i], heap[parent]) then break end
      heap[i], heap[parent] = heap[parent], heap[i]
      i = parent
    end
  end
  local function pop()
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
  -- The steps from the start up to node, in order.
  local function path_to(node)
    local reversed = {}
    while node do
      if node.step then reversed[#reversed + 1] = node.step end
      node = node.parent
    end
    local path = {}
    for i = #reversed, 1, -1 do path[#path + 1] = reversed[i] end
    return path
  end
  local from_key = key(from)
  local best = { [from_key] = start.length } -- shortest length reaching each tile
  local fit = {}                              -- fits per tile (its direction depends only on the tile)
  local goal_fits
  local deltas = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
  push(start)
  while #heap > 0 do
    local current = pop()
    if current.goal then
      local path = path_to(current.parent)
      if include_to then path[#path + 1] = { name = item_name, x = to.x, y = to.y } end
      for index, step in ipairs(path) do
        local following = path[index + 1] and { x = path[index + 1].x, y = path[index + 1].y } or to
        if kind == "belt" and following.x == step.x and following.y == step.y then
          -- A belt on the goal tile keeps the heading it arrived with.
          step.direction = index > 1 and path[index - 1].direction or direction(from, to)
        else
          step.direction = kind == "belt" and direction(step, following) or nil
        end
      end
      return path
    end
    if current.length == best[key(current.position)] then
      for _, delta in ipairs(deltas) do
        local first_direction = direction(from, { x = from.x + delta[1], y = from.y + delta[2] })
        local allowed_first = current.length > 0 or kind ~= "belt" or from_direction == nil or from_direction == first_direction
        local next_position = { x = current.position.x + delta[1], y = current.position.y + delta[2] }
        local next_key = key(next_position)
        if allowed_first and next_key ~= from_key then
          if math.abs(next_position.x - to.x) < 0.001 and math.abs(next_position.y - to.y) < 0.001 then
            local length = current.length + (include_to and 1 or 0)
            if include_to and goal_fits == nil and length <= max_length then goal_fits = fits(to, 0) and true or false end
            if length <= max_length and (not include_to or goal_fits == true) and (best[next_key] == nil or length < best[next_key]) then
              best[next_key] = length
              push({ goal = true, parent = current, length = length, position = next_position })
            end
          elseif current.length < max_length then
            local length = current.length + 1
            if best[next_key] == nil or length < best[next_key] then
              local toward = direction(next_position, to)
              if fit[next_key] == nil then fit[next_key] = fits(next_position, toward) and true or false end
              if fit[next_key] then
                best[next_key] = length
                push({ position = next_position, parent = current, length = length,
                  step = { name = item_name, x = next_position.x, y = next_position.y, direction = kind == "belt" and toward or nil } })
              end
            end
          end
        end
      end
    end
  end
  error("no charted physical " .. kind .. " route fits max_length and current placement constraints")
end

local function pipe_terminals(entity)
  if PIPE[entity.type] then return { { position = entity.position, existing = true } } end
  local terminals = {}
  for _, connection in ipairs(fluid_connections.live(entity)) do
    terminals[#terminals + 1] = { position = connection.target_position, existing = false }
  end
  table.sort(terminals, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return a.position.x < b.position.x
  end)
  return terminals
end

local function pipe_route(c, item_name, proto, from_entity, to_entity, max_length)
  local best
  for _, from_terminal in ipairs(pipe_terminals(from_entity)) do
    for _, to_terminal in ipairs(pipe_terminals(to_entity)) do
      local ok, route = pcall(grid_route, function(pos, d) return can_place(c, proto, pos, d) end, item_name,
        from_terminal.position, to_terminal.position, max_length, "pipe", nil, not from_terminal.existing, not to_terminal.existing)
      if ok and (not best or #route < #best) then best = route end
    end
  end
  if not best then error("no charted physical pipe route fits endpoint connections, max_length, and current placement constraints") end
  return best
end

local function entity_box(entity)
  return entity.bounding_box or entity.selection_box or {
    left_top = { x = entity.position.x - 0.1, y = entity.position.y - 0.1 },
    right_bottom = { x = entity.position.x + 0.1, y = entity.position.y + 0.1 },
  }
end

local function terminal_pole(c, item_name, proto, entity)
  if entity.type == "electric-pole" then
    local reach = tonumber(entity.prototype.get_max_wire_distance(entity.quality))
    if not reach then error("power pole endpoint does not expose wire reach") end
    return { position = entity.position, reach = reach, step = nil }
  end
  local supply = tonumber(proto.get_supply_area_distance("normal"))
  local reach = tonumber(proto.get_max_wire_distance("normal"))
  if not supply or not reach then error("power route prototype must expose supply area and wire reach") end
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
  if not candidates[1] then error("no charted physical pole placement covers an exact power endpoint") end
  local pos = candidates[1].position
  return { position = pos, reach = reach, step = { name = item_name, x = pos.x, y = pos.y } }
end

-- Intermediate poles on the placement grid between two pole positions, so no
-- wire span exceeds spacing and the last one fits final_reach.
local function pole_span(fits, item_name, from, to, spacing, final_reach, budget)
  local dx, dy = to.x - from.x, to.y - from.y
  local segments = math.ceil(math.sqrt(dx * dx + dy * dy) / spacing)
  local count = segments - 1
  if count > budget then error("power route needs " .. count .. " intermediate poles, beyond max_length") end
  local steps, previous = {}, from
  for index = 1, count do
    local fraction = index / segments
    local pos = { x = math.floor(from.x + dx * fraction) + 0.5, y = math.floor(from.y + dy * fraction) + 0.5 }
    if not fits(pos) then error(string.format("power route is blocked at (%.1f, %.1f)", pos.x, pos.y)) end
    local gap_x, gap_y = pos.x - previous.x, pos.y - previous.y
    if math.sqrt(gap_x * gap_x + gap_y * gap_y) > spacing then error("power route cannot satisfy physical wire reach on the placement grid") end
    steps[#steps + 1] = { name = item_name, x = pos.x, y = pos.y }
    previous = pos
  end
  local last_dx, last_dy = to.x - previous.x, to.y - previous.y
  if math.sqrt(last_dx * last_dx + last_dy * last_dy) > final_reach then
    error("power route cannot satisfy final physical wire reach")
  end
  return steps
end

local function power_route(c, item_name, proto, from, to, from_entity, to_entity, max_length)
  local new_reach = tonumber(proto.get_max_wire_distance("normal"))
  if not new_reach then error("power route prototype must expose wire reach") end
  local from_terminal = terminal_pole(c, item_name, proto, from_entity)
  local to_terminal = terminal_pole(c, item_name, proto, to_entity)
  local from_reach, to_reach = from_terminal.reach, to_terminal.reach
  from, to = from_terminal.position, to_terminal.position
  local steps = {}
  if from_terminal.step then steps[#steps + 1] = from_terminal.step end
  local terminal_count = (from_terminal.step and 1 or 0) + (to_terminal.step and 1 or 0)
  if terminal_count > max_length then error("power endpoint coverage needs more poles than max_length") end
  local dx, dy = to.x - from.x, to.y - from.y
  if math.sqrt(dx * dx + dy * dy) <= math.min(from_reach, to_reach) then
    if to_terminal.step then steps[#steps + 1] = to_terminal.step end
    return steps
  end
  for _, step in ipairs(pole_span(function(pos) return can_place(c, proto, pos, 0) end, item_name, from, to,
    math.min(new_reach, from_reach, to_reach), math.min(new_reach, to_reach), max_length - terminal_count)) do
    steps[#steps + 1] = step
  end
  if to_terminal.step then steps[#steps + 1] = to_terminal.step end
  return steps
end

-- Layout routes (build_layout), between planned endpoints that may not exist
-- yet. fits(position, direction) says whether one route piece may stand on
-- that tile; the caller folds in its planned footprints and charting.
-- Belts and pipes cover from..to inclusive, except an endpoint tile that is
-- not free (the entity there is the endpoint).
function M.route_tiles(kind, item_name, from, to, max_length, fits)
  local include_from, include_to = fits(from, 0), fits(to, 0)
  if math.abs(from.x - to.x) < 0.001 and math.abs(from.y - to.y) < 0.001 then
    if not include_from then return {} end
    return { { name = item_name, x = from.x, y = from.y, direction = kind == "belt" and 0 or nil } }
  end
  return grid_route(fits, item_name, from, to, max_length, kind, nil, include_from, include_to)
end

-- Poles at from and to (unless has_pole says one stands or is planned there)
-- and between them within wire reach.
function M.route_poles(item_name, proto, from, to, max_length, fits, has_pole)
  local reach = tonumber(proto.get_max_wire_distance("normal"))
  if not reach then error("power route prototype must expose wire reach") end
  local function pole_at(endpoint)
    if has_pole(endpoint) then return nil end
    if not fits(endpoint) then error(string.format("power route is blocked at (%.1f, %.1f)", endpoint.x, endpoint.y)) end
    return { name = item_name, x = endpoint.x, y = endpoint.y }
  end
  local head = pole_at(from)
  local tail = not (from.x == to.x and from.y == to.y) and pole_at(to) or nil
  local steps = { head }
  for _, step in ipairs(pole_span(fits, item_name, from, to, reach, reach,
    max_length - (head and 1 or 0) - (tail and 1 or 0))) do
    steps[#steps + 1] = step
  end
  steps[#steps + 1] = tail
  return steps
end

function M.connect_entities(params)
  local c = companion.require_companion()
  local kind = params.kind
  if kind ~= "belt" and kind ~= "pipe" and kind ~= "power" then error("connect_entities kind must be belt, pipe, or power") end
  if type(params.prototype) ~= "string" then error("connect_entities prototype must be a placeable item name") end
  local item = prototypes.item[params.prototype]
  local proto = item and item.place_result
  if not proto then error(params.prototype .. " is not a placeable route prototype") end
  if (kind == "belt" and proto.type ~= "transport-belt")
    or (kind == "pipe" and proto.type ~= "pipe")
    or (kind == "power" and proto.type ~= "electric-pole") then
    error(params.prototype .. " is not a supported physical " .. kind .. " route prototype")
  end
  local from, to = position(params.from, "connect_entities from"), position(params.to, "connect_entities to")
  local max_length = math.floor(tonumber(params.max_length) or 25)
  if max_length < 1 or max_length > 25 then error("connect_entities max_length must be 1-25 for one physical build_plan") end
  if not charted(c.force, c.surface, from) or not charted(c.force, c.surface, to) then error("connect_entities endpoints must both be force-charted") end
  local from_entity, to_entity = locate(c.surface, from), locate(c.surface, to)
  if not supports(kind, from_entity) or not supports(kind, to_entity) then error("both exact endpoints must support " .. kind .. " connections") end
  local steps
  if kind == "power" then steps = power_route(c, params.prototype, proto, from, to, from_entity, to_entity, max_length)
  elseif kind == "pipe" then steps = pipe_route(c, params.prototype, proto, from_entity, to_entity, max_length)
  else steps = grid_route(function(pos, d) return can_place(c, proto, pos, d) end, params.prototype,
    from, to, max_length, kind, from_entity.direction, false, false) end
  return { kind = kind, prototype = params.prototype, from = from, to = to, length = #steps, steps = steps, physical = true, ghosts = false }
end

return M
