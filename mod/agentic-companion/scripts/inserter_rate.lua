-- Inserter throughput as prototype arithmetic: max_items_per_second is an
-- upper bound, swings a second (rotation from the pickup to the drop vector
-- and back, or the arm's extension when that takes longer) times the hand
-- size (1 plus the prototype's stack bonus plus the force's inserter, or for
-- a bulk inserter its bulk capacity, bonus; a placed inserter's stack size
-- override caps it). It leaves out what only slows an inserter down:
-- chasing items on a belt, low power, a source that has nothing or a target
-- that is full.
-- Adapted from RateCalculator by raiguard (MIT License): scripts/gui-util.lua
-- calc_inserter_cycles_per_second and the inserter hand size in get_divisor.
-- Unlike its rounding (each leg up to whole ticks), 2.0.77 hands over a leg
-- earlier: chest to chest a fast inserter swings in 24 ticks, not 26, and an
-- inserter in about 70, not 72 (measured on a live server), so each leg here
-- is one tick less than the rounded-up count; a stack inserter's hand is 1 +
-- 4 + the bulk bonus there, as below.
local M = {}

local function vector(v)
  if type(v) ~= "table" then return nil end
  local x, y = tonumber(v.x) or tonumber(v[1]), tonumber(v.y) or tonumber(v[2])
  if x == nil or y == nil then return nil end
  return x, y
end

-- Full swings (pickup to drop and back) a second, or nil when the prototype
-- is no inserter.
function M.swings_per_second(proto, quality)
  local ok, pickup, drop, rotation, extension = pcall(function()
    return proto.inserter_pickup_position, proto.inserter_drop_position,
      proto.get_inserter_rotation_speed(quality), proto.get_inserter_extension_speed(quality)
  end)
  if not ok then return nil end
  local px, py = vector(pickup)
  local dx, dy = vector(drop)
  rotation, extension = tonumber(rotation), tonumber(extension)
  if not (px and dx and rotation and rotation > 0 and extension and extension > 0) then return nil end
  local pickup_length, drop_length = math.sqrt(px * px + py * py), math.sqrt(dx * dx + dy * dy)
  if pickup_length == 0 or drop_length == 0 then return nil end
  -- Rounding can put the cosine a hair outside acos's domain.
  local cosine = math.max(-1, math.min(1, (px * dx + py * dy) / (pickup_length * drop_length)))
  -- Rotation speed is in full turns a tick; a leg ends a tick before the
  -- rounded-up count (at least one tick).
  local function leg(x) return math.max(1, math.ceil(x) - 1) end
  local ticks = 2 * leg(math.acos(cosine) / (2 * math.pi) / rotation)
  ticks = math.max(ticks, 2 * leg(math.abs(pickup_length - drop_length) / extension))
  if ticks <= 0 then return nil end
  return 60 / ticks
end

-- Items one swing moves at most.
function M.hand_size(proto, force, override)
  local ok, bulk, bonus = pcall(function() return proto.bulk, proto.inserter_stack_size_bonus end)
  if not ok then return 1 end
  local ok_force, force_bonus = pcall(function()
    return bulk and force.bulk_inserter_capacity_bonus or force.inserter_stack_size_bonus
  end)
  local size = 1 + (tonumber(bonus) or 0) + (ok_force and tonumber(force_bonus) or 0)
  override = tonumber(override)
  if override and override > 0 then size = math.min(size, override) end
  return size
end

-- Upper bound on items a second, to two decimals; nil when the prototype is
-- no inserter.
function M.max_items_per_second(proto, force, quality, override)
  local swings = M.swings_per_second(proto, quality or "normal")
  if not swings then return nil end
  return math.floor(swings * M.hand_size(proto, force, override) * 100 + 0.5) / 100
end

-- The same for a placed inserter: its quality, force and stack size override.
function M.of_entity(entity)
  local ok, proto, force, quality, override = pcall(function()
    return entity.prototype, entity.force, entity.quality, entity.inserter_stack_size_override
  end)
  if not ok then return nil end
  local ok_name, name = pcall(function() return quality.name end)
  return M.max_items_per_second(proto, force, ok_name and name or "normal", override)
end

return M
