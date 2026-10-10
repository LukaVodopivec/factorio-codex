-- Exact, read-only endpoint resolution shared by placement search and physical
-- placement verification.
local M = {}

-- Ordinary inserter pickup inventories/transport. Labs can supply science
-- packs; a space platform hub and a cargo landing pad are taken from and
-- filled both ways.
local PICKUP_TYPES = {
  ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
  container = true, ["logistic-container"] = true, furnace = true,
  ["assembling-machine"] = true, ["cargo-wagon"] = true, lab = true,
  ["space-platform-hub"] = true, ["cargo-landing-pad"] = true,
}

-- These additional types may receive items (including burner fuel, ammo and
-- a silo's rocket parts and cargo), but are not pickup inventories. Type
-- eligibility is provisional, not item acceptance.
local DROP_ONLY_TYPES = { ["mining-drill"] = true, boiler = true, inserter = true, ["ammo-turret"] = true,
  ["artillery-turret"] = true, ["rocket-silo"] = true, reactor = true }

function M.can_target_type(entity_type, kind)
  return PICKUP_TYPES[entity_type] == true
    or (kind ~= "input" and DROP_ONLY_TYPES[entity_type] == true)
end

-- A refusal of the request (never a handler fault): CODE: message, with no
-- source location.
local function refuse(code, message) error(code .. ": " .. message, 0) end

local function position(value, label)
  if type(value) ~= "table" or tonumber(value.x) == nil or tonumber(value.y) == nil then
    refuse("TARGET_INVALID", label .. " must be {x, y}")
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

-- before_walk: a placement that will first walk to its position checks the
-- 30-tile reach after that walk (its re-resolve), not from where it starts;
-- a placement search (find_placement) reads charted endpoints wherever the
-- body stands. Refusals carry a code (TARGET_INVALID, TARGET_OUT_OF_RANGE,
-- TARGET_UNCHARTED, TARGET_NOT_FOUND, TARGET_AMBIGUOUS, TARGET_UNSUPPORTED).
function M.resolve(c, requested, label, kind, before_walk)
  local target = position(requested, label or "output_target")
  local dx, dy = c.position.x - target.x, c.position.y - target.y
  if not before_walk and dx * dx + dy * dy > 900 then
    refuse("TARGET_OUT_OF_RANGE", (label or "output_target") .. " must be within 30 tiles of Codex")
  end
  if not c.force.is_chunk_charted(c.surface, { x = math.floor(target.x / 32), y = math.floor(target.y / 32) }) then
    refuse("TARGET_UNCHARTED", (label or "output_target") .. " must be force-charted")
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
      refuse("TARGET_NOT_FOUND", string.format("%s does not identify a player-owned entity; it lies inside %s, whose exact position is (%.17g, %.17g) — use that position",
        label or "output_target", covering.name, covering.position.x, covering.position.y))
    end
    refuse("TARGET_NOT_FOUND", (label or "output_target")
      .. " does not identify a player-owned entity; use the exact entity position from observe_local or inspect_entity")
  end
  if #matches > 1 then refuse("TARGET_AMBIGUOUS", (label or "output_target") .. " is ambiguous") end
  local entity = matches[1]
  if not M.can_target_type(entity.type, kind) then
    local guidance = kind == "input"
      and "a supported pickup is a belt or an inventory (for example a chest, furnace, assembler, wagon, lab, hub or landing pad)"
      or "a supported recipient is a belt or an item inlet (for example a chest, furnace, assembler, wagon, lab, hub,"
        .. " landing pad, rocket silo, turret, reactor, or burner fuel inlet)"
    refuse("TARGET_UNSUPPORTED", (label or "output_target") .. " identifies " .. entity.name .. ", which is not a supported "
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

-- Drill outputs use point/collision containment; retain the measured rounding
-- allowance for flush drill/furnace boundaries (Factorio 2.0.77).
local ENDPOINT_TOLERANCE = 1 / 128

-- Inserters query the endpoint tile inset by 12/256, then intersect recipient
-- collision boxes (closed edges). Native 2.0.77 probes include narrow inserters,
-- off-grid recipients touching either inset edge, and same-tile nonrecipients.
-- This is a producer-specific native query, never a whole-tile fallback.
function M.endpoint_area(point, producer_type, kind)
  if producer_type == "inserter" or kind == "input" then
    local x, y, inset = math.floor(point.x), math.floor(point.y), 12 / 256
    return { left_top = { x = x + inset, y = y + inset },
      right_bottom = { x = x + 1 - inset, y = y + 1 - inset } }
  end
  return { left_top = { x = point.x - ENDPOINT_TOLERANCE, y = point.y - ENDPOINT_TOLERANCE },
    right_bottom = { x = point.x + ENDPOINT_TOLERANCE, y = point.y + ENDPOINT_TOLERANCE } }
end

function M.recipient_contains(box, point, producer_type, kind)
  if not (box and box.left_top and box.right_bottom and point) then return false end
  if producer_type ~= "inserter" and kind ~= "input" then return M.box_contains(box, point) end
  local area = M.endpoint_area(point, producer_type, kind)
  return box.left_top.x <= area.right_bottom.x and box.right_bottom.x >= area.left_top.x
    and box.left_top.y <= area.right_bottom.y and box.right_bottom.y >= area.left_top.y
end

function M.box_contains(box, point)
  return box and box.left_top and box.right_bottom and point
    and point.x >= box.left_top.x - ENDPOINT_TOLERANCE and point.x <= box.right_bottom.x + ENDPOINT_TOLERANCE
    and point.y >= box.left_top.y - ENDPOINT_TOLERANCE and point.y <= box.right_bottom.y + ENDPOINT_TOLERANCE
    or false
end

-- Grid centres whose collision box intersects the native endpoint query,
-- nearest the producer first. Callers still check overlap and placement.
function M.planned_recipient_positions(proto, point, producer_position, producer_type)
  local box = proto and proto.collision_box
  local lt = box and (box.left_top or box[1])
  local rb = box and (box.right_bottom or box[2])
  if not (point and lt and rb) then return {} end
  local area = M.endpoint_area(point, producer_type)
  local function axis(low_query, high_query, tiles, low, high)
    local offset = tiles % 2 == 1 and 0.5 or 0
    local values = {}
    for centre = math.ceil(low_query - high - offset) + offset, high_query - low do
      values[#values + 1] = centre
    end
    return values
  end
  local lx, ly = tonumber(lt.x or lt[1]), tonumber(lt.y or lt[2])
  local rx, ry = tonumber(rb.x or rb[1]), tonumber(rb.y or rb[2])
  local positions = {}
  for _, y in ipairs(axis(area.left_top.y, area.right_bottom.y, tonumber(proto.tile_height) or 1, ly, ry)) do
    for _, x in ipairs(axis(area.left_top.x, area.right_bottom.x, tonumber(proto.tile_width) or 1, lx, rx)) do
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

-- Geometry is provisional; later-tick pickup_target/drop_target is authoritative.
function M.recipient_at(c, point, kind, producer_type, before_walk)
  if not point then return nil, nil, "no-endpoint" end
  if not c.force.is_chunk_charted(c.surface,
    { x = math.floor(point.x / 32), y = math.floor(point.y / 32) }) then return nil, nil, "uncharted" end
  local dx, dy = point.x - c.position.x, point.y - c.position.y
  if not before_walk and dx * dx + dy * dy > 900 then return nil, nil, "out_of_range" end
  local area = M.endpoint_area(point, producer_type, kind)
  local matches = {}
  local found = c.surface.find_entities_filtered({ area = area })
  for _, entity in ipairs(found) do
    if entity.valid then
      local dx, dy = entity.position.x - c.position.x, entity.position.y - c.position.y
      if entity.force == c.force and (before_walk or dx * dx + dy * dy <= 900)
        and c.force.is_chunk_charted(c.surface, { x = math.floor(entity.position.x / 32), y = math.floor(entity.position.y / 32) })
        and M.can_target_type(entity.type, kind)
        and M.recipient_contains(entity.bounding_box, point, producer_type, kind) then
        matches[#matches + 1] = entity
      end
    end
  end
  table.sort(matches, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.type ~= b.type then return a.type < b.type end
    return a.name < b.name
  end)
  -- The fourth value is how many entities were read (a search charges them).
  if #matches == 0 then return nil, nil, "none", #found end
  if #matches > 1 then return nil, nil, "ambiguous", #found end
  return matches[1], identity(matches[1]), "bound", #found
end

function M.geometry_matches(c, proto, position, direction, expected, before_walk)
  local point = M.output_position(proto, position, direction)
  if not point then return false, nil end
  local recipient = M.recipient_at(c, point, "output", proto.type, before_walk)
  return recipient == expected, point
end

function M.input_geometry_matches(c, proto, position, direction, expected, before_walk)
  local point = M.input_position(proto, position, direction)
  if not point then return false, nil end
  local source = M.recipient_at(c, point, "input", proto.type, before_walk)
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
