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

local function grid_route(c, item_name, proto, from, to, max_length, kind, from_entity, include_from, include_to)
  local dx, dy = to.x - from.x, to.y - from.y
  if math.abs(dx - math.floor(dx + 0.5)) > 0.001 or math.abs(dy - math.floor(dy + 0.5)) > 0.001 then
    error(kind .. " endpoints must lie on the same one-tile placement grid")
  end
  local initial = {}
  if include_from then
    if not can_place(c, proto, from, 0) then error("physical " .. kind .. " route is blocked at its source connection") end
    initial[1] = { name = item_name, x = from.x, y = from.y }
  end
  if #initial > max_length then error(kind .. " route exceeds max_length at its source connection") end
  local queue, head = { { position = from, path = initial } }, 1
  local seen = { [key(from)] = true }
  local deltas = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
  while head <= #queue do
    local current = queue[head]; head = head + 1
    for _, delta in ipairs(deltas) do
      local first_direction = direction(from, { x = from.x + delta[1], y = from.y + delta[2] })
      local allowed_first = #current.path > 0 or kind ~= "belt" or from_entity.direction == nil or from_entity.direction == first_direction
      if allowed_first then
        local next_position = { x = current.position.x + delta[1], y = current.position.y + delta[2] }
        local next_key = key(next_position)
        if not seen[next_key] then
          seen[next_key] = true
          local reaches_goal = math.abs(next_position.x - to.x) < 0.001 and math.abs(next_position.y - to.y) < 0.001
          local next_path = {}; for i, step in ipairs(current.path) do next_path[i] = step end
          if reaches_goal then
            if include_to then
              if #next_path >= max_length then goto continue_neighbor end
              if not can_place(c, proto, to, 0) then goto continue_neighbor end
              next_path[#next_path + 1] = { name = item_name, x = to.x, y = to.y }
            end
            for index, step in ipairs(next_path) do
              local following = next_path[index + 1] and { x = next_path[index + 1].x, y = next_path[index + 1].y } or to
              step.direction = kind == "belt" and direction(step, following) or nil
            end
            return next_path
          end
          if #next_path < max_length then
            local toward = direction(next_position, to)
            if can_place(c, proto, next_position, toward) then
              next_path[#next_path + 1] = { name = item_name, x = next_position.x, y = next_position.y, direction = kind == "belt" and toward or nil }
              queue[#queue + 1] = { position = next_position, path = next_path }
            end
          end
        end
      end
      ::continue_neighbor::
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
      local ok, route = pcall(grid_route, c, item_name, proto, from_terminal.position, to_terminal.position,
        max_length, "pipe", from_entity, not from_terminal.existing, not to_terminal.existing)
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
    local reach = tonumber(entity.prototype and entity.prototype.maximum_wire_distance)
    if not reach then error("power pole endpoint does not expose wire reach") end
    return { position = entity.position, reach = reach, step = nil }
  end
  local supply = tonumber(proto.supply_area_distance)
  local reach = tonumber(proto.maximum_wire_distance)
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

local function power_route(c, item_name, proto, from, to, from_entity, to_entity, max_length)
  local new_reach = tonumber(proto.maximum_wire_distance)
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
  local distance = math.sqrt(dx * dx + dy * dy)
  if distance <= math.min(from_reach, to_reach) then
    if to_terminal.step then steps[#steps + 1] = to_terminal.step end
    return steps
  end
  local spacing = math.min(new_reach, from_reach, to_reach)
  local segments = math.ceil(distance / spacing)
  local count = segments - 1
  if count + terminal_count > max_length then error("power route needs " .. (count + terminal_count) .. " poles, beyond max_length") end
  local previous = from
  for index = 1, count do
    local fraction = index / segments
    local pos = { x = math.floor(from.x + dx * fraction) + 0.5, y = math.floor(from.y + dy * fraction) + 0.5 }
    if not can_place(c, proto, pos, 0) then error(string.format("power route is blocked at (%.1f, %.1f)", pos.x, pos.y)) end
    local gap_x, gap_y = pos.x - previous.x, pos.y - previous.y
    if math.sqrt(gap_x * gap_x + gap_y * gap_y) > spacing then error("power route cannot satisfy physical wire reach on the placement grid") end
    steps[#steps + 1] = { name = item_name, x = pos.x, y = pos.y }
    previous = pos
  end
  local last = previous
  local last_dx, last_dy = to.x - last.x, to.y - last.y
  if math.sqrt(last_dx * last_dx + last_dy * last_dy) > math.min(new_reach, to_reach) then
    error("power route cannot satisfy final physical wire reach")
  end
  if to_terminal.step then steps[#steps + 1] = to_terminal.step end
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
  else steps = grid_route(c, params.prototype, proto, from, to, max_length, kind, from_entity, false, false) end
  return { kind = kind, prototype = params.prototype, from = from, to = to, length = #steps, steps = steps, physical = true, ghosts = false }
end

return M
