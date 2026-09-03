-- Exact, read-only recipient resolution shared by placement search and physical
-- placement verification.
local M = {}

local RECIPIENT_TYPES = {
  ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
  container = true, ["logistic-container"] = true, furnace = true,
  ["assembling-machine"] = true, ["cargo-wagon"] = true,
}

local function position(value, label)
  if type(value) ~= "table" or tonumber(value.x) == nil or tonumber(value.y) == nil then
    error(label .. " must be {x, y}")
  end
  return { x = tonumber(value.x), y = tonumber(value.y) }
end

local function prototype_vector(value)
  if type(value) ~= "table" then return nil end
  local x = tonumber(value.x) or tonumber(value[1])
  local y = tonumber(value.y) or tonumber(value[2])
  if x == nil or y == nil then return nil end
  return { x = x, y = y }
end

local function rotate(offset, direction)
  if direction == 0 then return { x = offset.x, y = offset.y } end
  if direction == 4 then return { x = -offset.y, y = offset.x } end
  if direction == 8 then return { x = -offset.x, y = -offset.y } end
  if direction == 12 then return { x = offset.y, y = -offset.x } end
  return nil
end

local function identity(entity)
  return { name = entity.name, type = entity.type,
    position = { x = entity.position.x, y = entity.position.y } }
end

local function resolve(c, requested, label)
  local target = position(requested, label or "output_target")
  local dx, dy = c.position.x - target.x, c.position.y - target.y
  if dx * dx + dy * dy > 900 then error((label or "output_target") .. " must be within 30 tiles of Codex") end
  if not c.force.is_chunk_charted(c.surface, { x = math.floor(target.x / 32), y = math.floor(target.y / 32) }) then
    error((label or "output_target") .. " must be force-charted")
  end
  local matches = {}
  for _, entity in ipairs(c.surface.find_entities_filtered({ position = target })) do
    if entity.valid and entity.force == c.force and entity.type ~= "character" and entity.type ~= "resource"
      and entity.position.x == target.x and entity.position.y == target.y then
      matches[#matches + 1] = entity
    end
  end
  if #matches == 0 then error((label or "output_target") .. " does not identify a player-owned entity") end
  if #matches > 1 then error((label or "output_target") .. " is ambiguous") end
  local entity = matches[1]
  if not RECIPIENT_TYPES[entity.type] then
    error((label or "output_target") .. " identifies " .. entity.name .. ", which cannot receive placed output")
  end
  return {
    entity = entity,
    position = target,
    identity = { name = entity.name, type = entity.type, position = { x = entity.position.x, y = entity.position.y } },
  }
end

function M.resolve(c, requested, label)
  return resolve(c, requested, label)
end

function M.output_offset(proto)
  local ok, raw = pcall(function() return proto.vector_to_place_result end)
  if ok and raw then return prototype_vector(raw) end
  if proto.type == "inserter" then
    ok, raw = pcall(function() return proto.inserter_drop_position end)
    if ok and raw then return prototype_vector(raw) end
  end
  return nil
end

function M.output_position(proto, position, direction)
  local offset = M.output_offset(proto)
  local rotated = offset and rotate(offset, direction)
  if not rotated then return nil end
  return { x = position.x + rotated.x, y = position.y + rotated.y }
end

-- Factorio chooses drop_target from entities whose collision box intersects
-- the 1x1 tile box under drop_position. Keep finder prechecks identical to
-- that documented runtime geometry; selection boxes are UI-only.
function M.recipient_at(c, point)
  if not point then return nil, nil, "no-endpoint" end
  if not c.force.is_chunk_charted(c.surface,
    { x = math.floor(point.x / 32), y = math.floor(point.y / 32) }) then return nil, nil, "uncharted" end
  local tile = { left_top = { x = math.floor(point.x), y = math.floor(point.y) } }
  tile.right_bottom = { x = tile.left_top.x + 1, y = tile.left_top.y + 1 }
  local matches = {}
  for _, entity in ipairs(c.surface.find_entities_filtered({ area = tile })) do
    if entity.valid and entity.force == c.force and RECIPIENT_TYPES[entity.type] then
      matches[#matches + 1] = entity
    end
  end
  table.sort(matches, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.type ~= b.type then return a.type < b.type end
    return a.name < b.name
  end)
  if #matches == 0 then return nil, nil, "none" end
  if #matches > 1 then return nil, nil, "ambiguous" end
  return matches[1], identity(matches[1]), "bound"
end

function M.geometry_matches(c, proto, position, direction, expected)
  local point = M.output_position(proto, position, direction)
  if not point then return false, nil end
  local recipient = M.recipient_at(c, point)
  return recipient == expected, point
end

function M.binding_status(built, expected, placed_tick)
  if not built.valid then return "invalid" end
  if not expected.valid then return "target-invalid" end
  if game.tick <= placed_tick then return "pending" end
  local ok, point = pcall(function() return built.drop_position end)
  if not ok or not point or not built.surface or not built.force then return "unreadable" end
  local actual, _, state = M.recipient_at({ surface = built.surface, force = built.force }, point)
  if actual == expected then return "matched" end
  if state == "uncharted" or state == "no-endpoint" then return "unreadable" end
  if state == "ambiguous" then return "ambiguous" end
  return "mismatch"
end

return M
