-- Exact, read-only endpoint resolution shared by placement search and physical
-- placement verification.
local M = {}

-- Ordinary inserter pickup inventories/transport. Labs can supply science packs.
local PICKUP_TYPES = {
  ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
  container = true, ["logistic-container"] = true, furnace = true,
  ["assembling-machine"] = true, ["cargo-wagon"] = true, lab = true,
}

-- These additional types may receive items (including burner fuel), but are
-- not pickup inventories. Type eligibility is provisional, not item acceptance.
local DROP_ONLY_TYPES = { ["mining-drill"] = true, boiler = true, inserter = true }

function M.can_target_type(entity_type, kind)
  return PICKUP_TYPES[entity_type] == true
    or (kind ~= "input" and DROP_ONLY_TYPES[entity_type] == true)
end

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

function M.resolve(c, requested, label, kind)
  local target = position(requested, label or "output_target")
  local dx, dy = c.position.x - target.x, c.position.y - target.y
  if dx * dx + dy * dy > 900 then error((label or "output_target") .. " must be within 30 tiles of Codex") end
  if not c.force.is_chunk_charted(c.surface, { x = math.floor(target.x / 32), y = math.floor(target.y / 32) }) then
    error((label or "output_target") .. " must be force-charted")
  end
  local matches, covering = {}, nil
  for _, entity in ipairs(c.surface.find_entities_filtered({ position = target })) do
    if entity.valid and entity.force == c.force and entity.type ~= "character" and entity.type ~= "resource" then
      if entity.position.x == target.x and entity.position.y == target.y then
        matches[#matches + 1] = entity
      else
        covering = covering or entity
      end
    end
  end
  if #matches == 0 then
    if covering then
      error(string.format("%s does not identify a player-owned entity; it lies inside %s, whose exact position is (%.17g, %.17g) — use that position",
        label or "output_target", covering.name, covering.position.x, covering.position.y))
    end
    error((label or "output_target") .. " does not identify a player-owned entity; use the exact entity position from observe_local or inspect_entity")
  end
  if #matches > 1 then error((label or "output_target") .. " is ambiguous") end
  local entity = matches[1]
  if not M.can_target_type(entity.type, kind) then
    local guidance = kind == "input"
      and "use a supported belt or pickup inventory (for example a chest, furnace, assembler, wagon, or lab)"
      or "use a supported belt or item inlet (for example a chest, furnace, assembler, wagon, lab, or burner fuel inlet)"
    error((label or "output_target") .. " identifies " .. entity.name .. ", which is not a supported "
      .. (kind == "input" and "pickup source; " or "drop recipient; ") .. guidance
      .. "; provisional geometry does not prove item acceptance or runtime binding")
  end
  return {
    entity = entity,
    position = target,
    identity = { name = entity.name, type = entity.type, position = { x = entity.position.x, y = entity.position.y } },
  }
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

function M.input_offset(proto)
  if proto.type ~= "inserter" then return nil end
  local ok, raw = pcall(function() return proto.inserter_pickup_position end)
  if ok and raw then return prototype_vector(raw) end
  return nil
end

function M.output_position(proto, position, direction)
  local offset = M.output_offset(proto)
  local rotated = offset and rotate(offset, direction)
  if not rotated then return nil end
  return { x = position.x + rotated.x, y = position.y + rotated.y }
end

function M.input_position(proto, position, direction)
  local offset = M.input_offset(proto)
  local rotated = offset and rotate(offset, direction)
  if not rotated then return nil end
  return { x = position.x + rotated.x, y = position.y + rotated.y }
end

-- Factorio rounds endpoint vectors and collision boxes to 1/256 tiles. A
-- 2.0.77 probe (burner drills flush against stone furnaces in all directions,
-- burner inserters around furnaces) bound exactly when the endpoint lay inside
-- the collision box closed by this tolerance: flush drill outputs land about
-- 1/256 outside the furnace box yet bind. Boxes of distinct entities are at
-- least 0.2 tiles apart, so the tolerance never selects a neighbour.
local ENDPOINT_TOLERANCE = 1 / 128

function M.box_contains(box, point)
  return box and box.left_top and box.right_bottom and point
    and point.x >= box.left_top.x - ENDPOINT_TOLERANCE and point.x <= box.right_bottom.x + ENDPOINT_TOLERANCE
    and point.y >= box.left_top.y - ENDPOINT_TOLERANCE and point.y <= box.right_bottom.y + ENDPOINT_TOLERANCE
    or false
end

local function contains_point(entity, point)
  return M.box_contains(entity.bounding_box, point)
end

-- Grid centres at which a not-yet-placed recipient's collision box contains the
-- endpoint, nearest the producer first. Callers still check overlap and placement.
function M.planned_recipient_positions(proto, point, producer_position)
  local box = proto and proto.collision_box
  local lt = box and (box.left_top or box[1])
  local rb = box and (box.right_bottom or box[2])
  if not (point and lt and rb) then return {} end
  local function axis(value, tiles, low, high)
    local offset = tiles % 2 == 1 and 0.5 or 0
    local values = {}
    for centre = math.floor(value - high - ENDPOINT_TOLERANCE - offset) + offset,
      value - low + ENDPOINT_TOLERANCE do
      if value >= centre + low - ENDPOINT_TOLERANCE and value <= centre + high + ENDPOINT_TOLERANCE then
        values[#values + 1] = centre
      end
    end
    return values
  end
  local lx, ly = tonumber(lt.x or lt[1]), tonumber(lt.y or lt[2])
  local rx, ry = tonumber(rb.x or rb[1]), tonumber(rb.y or rb[2])
  local positions = {}
  for _, y in ipairs(axis(point.y, tonumber(proto.tile_height) or 1, ly, ry)) do
    for _, x in ipairs(axis(point.x, tonumber(proto.tile_width) or 1, lx, rx)) do
      positions[#positions + 1] = { x = x, y = y }
    end
  end
  local origin = producer_position or point
  table.sort(positions, function(a, b)
    local da = (a.x - origin.x) ^ 2 + (a.y - origin.y) ^ 2
    local db = (b.x - origin.x) ^ 2 + (b.y - origin.y) ^ 2
    if da ~= db then return da < db end
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end)
  return positions
end

-- Search-time endpoint evidence is provisional. Only an entity whose collision
-- box contains the exact prototype-derived point (within the probed tolerance)
-- is eligible; never a whole endpoint tile. Runtime pickup_target/drop_target
-- remains authoritative after physical placement.
function M.recipient_at(c, point, kind)
  if not point then return nil, nil, "no-endpoint" end
  if not c.force.is_chunk_charted(c.surface,
    { x = math.floor(point.x / 32), y = math.floor(point.y / 32) }) then return nil, nil, "uncharted" end
  local area = { left_top = { x = point.x - ENDPOINT_TOLERANCE, y = point.y - ENDPOINT_TOLERANCE },
    right_bottom = { x = point.x + ENDPOINT_TOLERANCE, y = point.y + ENDPOINT_TOLERANCE } }
  local matches = {}
  for _, entity in ipairs(c.surface.find_entities_filtered({ area = area })) do
    if entity.valid and entity.force == c.force and M.can_target_type(entity.type, kind)
      and contains_point(entity, point) then
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

function M.input_geometry_matches(c, proto, position, direction, expected)
  local point = M.input_position(proto, position, direction)
  if not point then return false, nil end
  local source = M.recipient_at(c, point, "input")
  return source == expected, point
end

function M.binding_status(built, expected, placed_tick, kind)
  kind = kind or "output"
  if not built.valid then return "invalid" end
  if not expected.valid then return "target-invalid" end
  if game.tick <= placed_tick then return "pending" end
  local ok_target, actual_target = pcall(function()
    if kind == "input" then return built.pickup_target end
    return built.drop_target
  end)
  if not ok_target then return "unreadable" end
  if actual_target == expected then return "matched" end
  if actual_target ~= nil then return "mismatch" end
  if kind == "output" and built.type == "mining-drill" then return "pending-output" end
  return "unbound"
end

return M
