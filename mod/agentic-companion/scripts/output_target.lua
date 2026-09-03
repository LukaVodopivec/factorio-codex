-- Exact, read-only endpoint resolution shared by placement search and physical
-- placement verification. Machine outputs retain their established recipient
-- allowlist; inserter endpoints rely on Factorio's authoritative live binding.
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

local function contains(box, point)
  return box and point.x >= box.left_top.x and point.x < box.right_bottom.x
    and point.y >= box.left_top.y and point.y < box.right_bottom.y
end

local function resolve(c, requested, label, require_recipient)
  local target = position(requested, label or "output_target")
  local dx, dy = c.position.x - target.x, c.position.y - target.y
  if dx * dx + dy * dy > 900 then error((label or "output_target") .. " must be within 30 tiles of Codex") end
  if not c.force.is_chunk_charted(c.surface, { x = math.floor(target.x / 32), y = math.floor(target.y / 32) }) then
    error((label or "output_target") .. " must be force-charted")
  end
  local matches = {}
  for _, entity in ipairs(c.surface.find_entities_filtered({
    area = { { target.x, target.y }, { target.x + 0.001, target.y + 0.001 } },
  })) do
    if entity.valid and entity.force == c.force and entity.type ~= "character" and entity.type ~= "resource"
      and (contains(entity.selection_box, target) or contains(entity.bounding_box, target)) then
      matches[#matches + 1] = entity
    end
  end
  if #matches == 0 then error((label or "output_target") .. " does not identify a player-owned entity") end
  if #matches > 1 then error((label or "output_target") .. " is ambiguous") end
  local entity = matches[1]
  if require_recipient and not RECIPIENT_TYPES[entity.type] then
    error((label or "output_target") .. " identifies " .. entity.name .. ", which cannot receive placed output")
  end
  return {
    entity = entity,
    position = target,
    identity = { name = entity.name, type = entity.type, position = { x = entity.position.x, y = entity.position.y } },
  }
end

function M.resolve(c, requested, label)
  return resolve(c, requested, label, true)
end

function M.resolve_input(c, requested, label)
  return resolve(c, requested, label or "input_target", false)
end

function M.resolve_endpoint(c, requested, label)
  return resolve(c, requested, label, false)
end

function M.contains(entity, point)
  return contains(entity.selection_box, point) or contains(entity.bounding_box, point)
end

function M.verify_drop_target(built, expected)
  local ok, actual = pcall(function() return built.drop_target end)
  return ok and actual == expected
end

function M.verify_pickup_target(built, expected)
  local ok, actual = pcall(function() return built.pickup_target end)
  return ok and actual == expected
end

return M
