-- Deterministic, side-effect-free placement search over already charted terrain.
local companion = require("scripts.companion")

local M = {}

local function position(value, label)
  if type(value) ~= "table" or tonumber(value.x) == nil or tonumber(value.y) == nil then
    error(label .. " must be {x, y}")
  end
  return { x = tonumber(value.x), y = tonumber(value.y) }
end

local function charted(force, surface, pos)
  return force.is_chunk_charted(surface, { x = math.floor(pos.x / 32), y = math.floor(pos.y / 32) })
end

local function footprint(proto, pos, direction)
  local box = proto.collision_box
  local lt, rb = box.left_top, box.right_bottom
  if direction == 4 or direction == 12 then
    lt, rb = { x = lt.y, y = lt.x }, { x = rb.y, y = rb.x }
  elseif direction ~= 0 and direction ~= 8 then
    -- Diagonal orientations need a conservative square bound. The actual
    -- authoritative answer still comes from can_place_entity below.
    local extent = math.max(math.abs(lt.x), math.abs(lt.y), math.abs(rb.x), math.abs(rb.y))
    lt, rb = { x = -extent, y = -extent }, { x = extent, y = extent }
  end
  return {
    left_top = { x = pos.x + lt.x, y = pos.y + lt.y },
    right_bottom = { x = pos.x + rb.x, y = pos.y + rb.y },
  }
end

local function footprint_charted(force, surface, area)
  local chunks = {
    { x = area.left_top.x, y = area.left_top.y },
    { x = area.right_bottom.x - 0.001, y = area.left_top.y },
    { x = area.left_top.x, y = area.right_bottom.y - 0.001 },
    { x = area.right_bottom.x - 0.001, y = area.right_bottom.y - 0.001 },
  }
  for _, corner in ipairs(chunks) do if not charted(force, surface, corner) then return false end end
  return true
end

local function is_water(surface, x, y)
  local ok, tile = pcall(surface.get_tile, x, y)
  if not ok or not tile then return false end
  for _, layer in ipairs({ "water_tile", "water-tile", "player" }) do
    local collision_ok, collides = pcall(tile.collides_with, layer)
    if collision_ok and collides then return true end
  end
  return false
end

local function terrain(force, surface, proto, area)
  if proto.type == "offshore-pump" then return "offshore" end
  local water, land = false, false
  for y = math.floor(area.left_top.y) - 1, math.ceil(area.right_bottom.y) do
    for x = math.floor(area.left_top.x) - 1, math.ceil(area.right_bottom.x) do
      if charted(force, surface, { x = x, y = y }) then
        if is_water(surface, x, y) then water = true else land = true end
      end
    end
  end
  return water and land and "shoreline" or (water and "offshore" or "land")
end

local function snapped(value, tiles)
  local offset = tiles % 2 == 1 and 0.5 or 0
  return math.floor(value - offset + 0.5) + offset
end

function M.find_placement(params)
  local c = companion.require_companion()
  if type(params.item) ~= "string" then error("find_placement item must be an item name") end
  local item = prototypes.item[params.item]
  if not item or not item.place_result then error(params.item .. " is not a placeable item") end
  local proto = item.place_result
  local preferred = position(params.preferred, "find_placement preferred")
  local radius = math.floor(tonumber(params.radius) or 10)
  local limit = math.floor(tonumber(params.limit) or 8)
  if radius < 1 or radius > 30 then error("find_placement radius must be 1-30") end
  if limit < 1 or limit > 24 then error("find_placement limit must be 1-24") end
  local directions = params.directions or { 0, 4, 8, 12 }
  if type(directions) ~= "table" or #directions == 0 then error("find_placement directions must be a non-empty array") end
  local unique = {}
  for _, raw in ipairs(directions) do
    local direction = tonumber(raw)
    if not direction or direction % 1 ~= 0 or direction < 0 or direction > 15 then
      error("find_placement directions must contain Factorio directions 0-15")
    end
    unique[direction] = true
  end
  directions = {}; for direction in pairs(unique) do directions[#directions + 1] = direction end; table.sort(directions)

  local width, height = tonumber(proto.tile_width) or 1, tonumber(proto.tile_height) or 1
  local origin_x, origin_y = snapped(preferred.x, width), snapped(preferred.y, height)
  local candidates = {}
  for y = origin_y - radius, origin_y + radius do
    for x = origin_x - radius, origin_x + radius do
      local pdx, pdy = x - preferred.x, y - preferred.y
      if pdx * pdx + pdy * pdy <= radius * radius then
        local cdx, cdy = x - c.position.x, y - c.position.y
        local codex_distance_sq = cdx * cdx + cdy * cdy
        if codex_distance_sq <= 900 then
          for _, direction in ipairs(directions) do
            local pos = { x = x, y = y }
            local area = footprint(proto, pos, direction)
            if footprint_charted(c.force, c.surface, area) and c.surface.can_place_entity({
              name = proto.name, position = pos, direction = direction, force = c.force,
              build_check_type = defines.build_check_type.manual,
            }) then
              candidates[#candidates + 1] = {
                item = params.item, entity = proto.name, position = pos, direction = direction,
                distance = math.sqrt(pdx * pdx + pdy * pdy),
                distance_from_codex = math.sqrt(codex_distance_sq),
                terrain = terrain(c.force, c.surface, proto, area),
              }
            end
          end
        end
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    return a.direction < b.direction
  end)
  while #candidates > limit do table.remove(candidates) end
  return { item = params.item, entity = proto.name, preferred = preferred, candidates = candidates }
end

return M
