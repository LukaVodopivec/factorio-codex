-- Deterministic physical route planning between exact, already-charted endpoints.
local companion = require("scripts.companion")

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
  if kind == "pipe" then return PIPE[entity.type] == true end
  return entity.type == "electric-pole"
end

local function direction(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  if math.abs(dx) > math.abs(dy) then return dx > 0 and 4 or 12 end
  return dy > 0 and 8 or 0
end

local function key(pos) return string.format("%.3f,%.3f", pos.x, pos.y) end

local function can_place(c, proto, pos, direction_value)
  local box = proto.collision_box
  if box then
    local lt, rb = box.left_top, box.right_bottom
    if direction_value == 4 or direction_value == 12 then lt, rb = { x = lt.y, y = lt.x }, { x = rb.y, y = rb.x } end
    for _, corner in ipairs({
      { x = pos.x + lt.x, y = pos.y + lt.y }, { x = pos.x + rb.x - 0.001, y = pos.y + lt.y },
      { x = pos.x + lt.x, y = pos.y + rb.y - 0.001 }, { x = pos.x + rb.x - 0.001, y = pos.y + rb.y - 0.001 },
    }) do if not charted(c.force, c.surface, corner) then return false end end
  elseif not charted(c.force, c.surface, pos) then return false end
  return c.surface.can_place_entity({
    name = proto.name, position = pos, direction = direction_value or 0, force = c.force,
    build_check_type = defines.build_check_type.manual,
  })
end

local function grid_route(c, item_name, proto, from, to, max_length, kind, from_entity)
  local dx, dy = to.x - from.x, to.y - from.y
  if math.abs(dx - math.floor(dx + 0.5)) > 0.001 or math.abs(dy - math.floor(dy + 0.5)) > 0.001 then
    error(kind .. " endpoints must lie on the same one-tile placement grid")
  end
  local queue, head = { { position = from, path = {} } }, 1
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
    end
  end
  error("no charted physical " .. kind .. " route fits max_length and current placement constraints")
end

local function power_route(c, item_name, proto, from, to, from_entity, to_entity, max_length)
  local new_reach = tonumber(proto.maximum_wire_distance)
  local from_reach = tonumber(from_entity.prototype and from_entity.prototype.maximum_wire_distance)
  local to_reach = tonumber(to_entity.prototype and to_entity.prototype.maximum_wire_distance)
  if not new_reach or not from_reach or not to_reach then error("power endpoints and prototype must expose wire reach") end
  local dx, dy = to.x - from.x, to.y - from.y
  local distance = math.sqrt(dx * dx + dy * dy)
  if distance <= math.min(from_reach, to_reach) then return {} end
  local spacing = math.min(new_reach, from_reach, to_reach)
  local segments = math.ceil(distance / spacing)
  local count = segments - 1
  if count > max_length then error("power route needs " .. count .. " poles, beyond max_length") end
  local steps = {}
  for index = 1, count do
    local fraction = index / segments
    local pos = { x = math.floor(from.x + dx * fraction) + 0.5, y = math.floor(from.y + dy * fraction) + 0.5 }
    if not can_place(c, proto, pos, 0) then error(string.format("power route is blocked at (%.1f, %.1f)", pos.x, pos.y)) end
    local previous = index == 1 and from or { x = steps[index - 1].x, y = steps[index - 1].y }
    local gap_x, gap_y = pos.x - previous.x, pos.y - previous.y
    if math.sqrt(gap_x * gap_x + gap_y * gap_y) > spacing then error("power route cannot satisfy physical wire reach on the placement grid") end
    steps[index] = { name = item_name, x = pos.x, y = pos.y }
  end
  local last = steps[#steps] and { x = steps[#steps].x, y = steps[#steps].y } or from
  local last_dx, last_dy = to.x - last.x, to.y - last.y
  if math.sqrt(last_dx * last_dx + last_dy * last_dy) > math.min(new_reach, to_reach) then
    error("power route cannot satisfy final physical wire reach")
  end
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
  else steps = grid_route(c, params.prototype, proto, from, to, max_length, kind, from_entity) end
  return { kind = kind, prototype = params.prototype, from = from, to = to, length = #steps, steps = steps, physical = true, ghosts = false }
end

return M
