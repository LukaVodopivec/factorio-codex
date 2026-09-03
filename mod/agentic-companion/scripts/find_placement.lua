-- Deterministic, side-effect-free placement search over already charted terrain.
local companion = require("scripts.companion")
local output_targets = require("scripts.output_target")

local M = {}

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

local function rotate(offset, direction)
  if direction == 0 then return { x = offset.x, y = offset.y } end
  if direction == 4 then return { x = -offset.y, y = offset.x } end
  if direction == 8 then return { x = -offset.x, y = -offset.y } end
  if direction == 12 then return { x = offset.y, y = -offset.x } end
  return nil
end

local function drill_resource_coverage(force, surface, proto, pos)
  if proto.type ~= "mining-drill" then return nil end
  local ok_radius, radius = pcall(function() return proto.mining_drill_radius end)
  radius = ok_radius and tonumber(radius) or nil
  if not radius or radius <= 0 then return nil end
  local area = {
    left_top = { x = pos.x - radius, y = pos.y - radius },
    right_bottom = { x = pos.x + radius, y = pos.y + radius },
  }
  if not footprint_charted(force, surface, area) then return nil end
  local ok_categories, categories = pcall(function() return proto.resource_categories end)
  if not ok_categories or type(categories) ~= "table" then return {} end
  local by_name = {}
  for _, resource in ipairs(surface.find_entities_filtered({
    area = area,
    type = "resource",
  })) do
    local resource_position = resource.valid and resource.position or nil
    local center_inside = resource_position
      and resource_position.x >= area.left_top.x and resource_position.x < area.right_bottom.x
      and resource_position.y >= area.left_top.y and resource_position.y < area.right_bottom.y
    if center_inside then
      local ok_category, category = pcall(function() return resource.prototype.resource_category end)
      if ok_category and type(category) == "string" and categories[category] then
        local row = by_name[resource.name] or { name = resource.name, entity_count = 0, total_amount = 0 }
        row.entity_count = row.entity_count + 1
        row.total_amount = row.total_amount + (tonumber(resource.amount) or 0)
        by_name[resource.name] = row
      end
    end
  end
  local rows = {}
  for _, row in pairs(by_name) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
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

  local inserter_pickup_offset, inserter_drop_offset
  if proto.type == "inserter" then
    local ok_pickup, raw_pickup = pcall(function() return proto.inserter_pickup_position end)
    local ok_drop, raw_drop = pcall(function() return proto.inserter_drop_position end)
    if ok_pickup and raw_pickup and ok_drop and raw_drop then
      inserter_pickup_offset = prototype_vector(raw_pickup)
      inserter_drop_offset = prototype_vector(raw_drop)
    end
  end

  local output_target, drop_offset
  if params.output_target ~= nil then
    output_target = output_targets.resolve(c, params.output_target, "find_placement output_target")
    local ok, raw = pcall(function() return proto.vector_to_place_result end)
    if ok and raw then drop_offset = prototype_vector(raw) end
    if not drop_offset and proto.type == "inserter" then drop_offset = inserter_drop_offset end
    if not drop_offset then error(params.item .. " has no deterministic output offset") end
  end
  if output_target then
    for _, direction in ipairs(directions) do
      if not rotate(drop_offset, direction) then
        error("targeted placement directions must be cardinal: 0, 4, 8, or 12")
      end
    end
  end

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
            local output_offset = drop_offset and rotate(drop_offset, direction) or nil
            local output_position = output_offset and { x = x + output_offset.x, y = y + output_offset.y } or nil
            local pickup_offset = inserter_pickup_offset and rotate(inserter_pickup_offset, direction) or nil
            local inserter_output_offset = inserter_drop_offset and rotate(inserter_drop_offset, direction) or nil
            local pickup_position = pickup_offset and { x = x + pickup_offset.x, y = y + pickup_offset.y } or nil
            local drop_position = inserter_output_offset and { x = x + inserter_output_offset.x, y = y + inserter_output_offset.y } or nil
            if proto.type == "inserter" and output_target then output_position = drop_position end
            local output_matches = not output_target or output_targets.contains(output_target.entity, output_position)
            if output_matches and footprint_charted(c.force, c.surface, area) and c.surface.can_place_entity({
              name = proto.name, position = pos, direction = direction, force = c.force,
              build_check_type = defines.build_check_type.manual,
            }) then
              candidates[#candidates + 1] = {
                item = params.item, entity = proto.name, position = pos, direction = direction,
                distance = math.sqrt(pdx * pdx + pdy * pdy),
                distance_from_codex = math.sqrt(codex_distance_sq),
                terrain = terrain(c.force, c.surface, proto, area),
                output_position = output_position,
                pickup_position = pickup_position,
                drop_position = drop_position,
                resource_coverage = drill_resource_coverage(c.force, c.surface, proto, pos),
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
  return { item = params.item, entity = proto.name, preferred = preferred,
    output_target = output_target and output_target.identity or nil,
    candidates = candidates }
end

return M
