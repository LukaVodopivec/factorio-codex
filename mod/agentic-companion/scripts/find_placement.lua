-- Deterministic, side-effect-free placement search over already charted terrain.
local companion = require("scripts.companion")
local output_targets = require("scripts.output_target")
local placement_geometry = require("scripts.placement_geometry")
local fluid_connections = require("scripts.fluid_connections")

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
    local resource_x = resource_position and resource_position.x or nil
    local resource_y = resource_position and resource_position.y or nil
    local center_inside = type(resource_x) == "number" and type(resource_y) == "number"
      and resource_x >= area.left_top.x and resource_x < area.right_bottom.x
      and resource_y >= area.left_top.y and resource_y < area.right_bottom.y
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

  if params.output_target ~= nil and params.output_recipient_item ~= nil then
    error("find_placement accepts output_target or output_recipient_item, not both")
  end

  local inserter_pickup_offset, inserter_drop_offset
  if proto.type == "inserter" then
    local ok_pickup, raw_pickup = pcall(function() return proto.inserter_pickup_position end)
    local ok_drop, raw_drop = pcall(function() return proto.inserter_drop_position end)
    if ok_pickup and raw_pickup and ok_drop and raw_drop then
      inserter_pickup_offset = prototype_vector(raw_pickup)
      inserter_drop_offset = prototype_vector(raw_drop)
    end
  end

  local input_target, output_target, output_recipient_item, output_recipient_proto = nil, nil, nil, nil
  local drop_offset = output_targets.output_offset(proto)
  local output_capable = proto.type == "mining-drill" or proto.type == "inserter" or drop_offset ~= nil
  if params.input_target ~= nil then
    if proto.type ~= "inserter" or not output_targets.input_offset(proto) then
      error(params.item .. " has no deterministic input offset")
    end
    input_target = output_targets.resolve(c, params.input_target, "find_placement input_target")
  end
  if params.output_target ~= nil then
    output_target = output_targets.resolve(c, params.output_target, "find_placement output_target")
    if not drop_offset then error(params.item .. " has no deterministic output offset") end
  end
  if params.output_recipient_item ~= nil then
    if type(params.output_recipient_item) ~= "string" then
      error("find_placement output_recipient_item must be an item name")
    end
    output_recipient_item = prototypes.item[params.output_recipient_item]
    output_recipient_proto = output_recipient_item and output_recipient_item.place_result
    if not output_recipient_proto then
      error(tostring(params.output_recipient_item) .. " is not a placeable recipient item")
    end
    if not output_targets.can_receive_type(output_recipient_proto.type) then
      error(tostring(params.output_recipient_item) .. " cannot receive placed output")
    end
    if not drop_offset then error(params.item .. " has no deterministic output offset") end
  end
  if input_target or output_target or output_recipient_item then
    for _, direction in ipairs(directions) do
      local required_offset = input_target and output_targets.input_offset(proto) or drop_offset
      if not rotate(required_offset, direction) then
        error("targeted placement directions must be cardinal: 0, 4, 8, or 12")
      end
    end
  end

  local width, height = tonumber(proto.tile_width) or 1, tonumber(proto.tile_height) or 1
  local origin_x, origin_y = snapped(preferred.x, width), snapped(preferred.y, height)
  local candidates, rejected_no_compatible_resource = {}, 0
  for y = origin_y - radius, origin_y + radius do
    for x = origin_x - radius, origin_x + radius do
      local pdx, pdy = x - preferred.x, y - preferred.y
      if pdx * pdx + pdy * pdy <= radius * radius then
        local cdx, cdy = x - c.position.x, y - c.position.y
        local codex_distance_sq = cdx * cdx + cdy * cdy
        if codex_distance_sq <= 900 then
          for _, direction in ipairs(directions) do
            local pos = { x = x, y = y }
            local area = placement_geometry.footprint(proto, pos, direction)
            local output_position = output_targets.output_position(proto, pos, direction)
            local pickup_offset = inserter_pickup_offset and rotate(inserter_pickup_offset, direction) or nil
            local inserter_output_offset = inserter_drop_offset and rotate(inserter_drop_offset, direction) or nil
            local pickup_position = pickup_offset and { x = x + pickup_offset.x, y = y + pickup_offset.y } or nil
            local drop_position = inserter_output_offset and { x = x + inserter_output_offset.x, y = y + inserter_output_offset.y } or nil
            if proto.type == "inserter" and output_target then output_position = drop_position end
            local recipient, recipient_identity, recipient_state = output_targets.recipient_at(c, output_position)
            local candidate_output_target
            if output_position and recipient_state == "bound" then candidate_output_target = recipient_identity end
            if output_position and recipient_state == "none" then candidate_output_target = false end
            local input_matches = true
            local candidate_input_target
            if input_target then
              local input_entity, input_identity = output_targets.recipient_at(c, pickup_position)
              input_matches = input_entity == input_target.entity
              if input_matches then candidate_input_target = input_identity end
            end
            local output_matches = not output_target or recipient == output_target.entity
            local output_known = not output_capable or (output_position ~= nil
              and (recipient_state == "bound" or recipient_state == "none"))
            local can_place = placement_geometry.can_place(c, proto, pos, direction)
            local recipient_placement
            if output_recipient_item and output_position and recipient_state == "none" then
              local recipient_width = tonumber(output_recipient_proto.tile_width) or 1
              local recipient_height = tonumber(output_recipient_proto.tile_height) or 1
              local recipient_position = {
                x = snapped(output_position.x, recipient_width),
                y = snapped(output_position.y, recipient_height),
              }
              local recipient_area = placement_geometry.footprint(output_recipient_proto, recipient_position, 0)
              local endpoint_tile = { left_top = { x = math.floor(output_position.x), y = math.floor(output_position.y) },
                right_bottom = { x = math.floor(output_position.x) + 1, y = math.floor(output_position.y) + 1 } }
              local provisional_overlap = placement_geometry.overlaps(endpoint_tile, recipient_area)
              local recipient_can_place = placement_geometry.can_place(c, output_recipient_proto, recipient_position, 0)
              if provisional_overlap and recipient_can_place
                and footprint_charted(c.force, c.surface, recipient_area)
                and not placement_geometry.overlaps(area, recipient_area) then
                recipient_placement = { item = params.output_recipient_item,
                  entity = output_recipient_proto.name, position = recipient_position, direction = 0 }
              end
            end
            local requested_output_ok = not output_recipient_item or recipient_placement ~= nil
            if input_matches and output_known and output_matches and requested_output_ok
              and footprint_charted(c.force, c.surface, area) and can_place then
              local resource_coverage = drill_resource_coverage(c.force, c.surface, proto, pos)
              if resource_coverage and #resource_coverage == 0 then
                rejected_no_compatible_resource = rejected_no_compatible_resource + 1
              else
                local producer_step = { name = params.item, x = pos.x, y = pos.y, direction = direction }
                if input_target then producer_step.input_target = input_target.position end
                if output_target then producer_step.output_target = output_target.position end
                if recipient_placement then producer_step.output_target = recipient_placement.position end
                local build_steps = {}
                if recipient_placement then
                  build_steps[#build_steps + 1] = { name = recipient_placement.item,
                    x = recipient_placement.position.x, y = recipient_placement.position.y,
                    direction = recipient_placement.direction }
                end
                build_steps[#build_steps + 1] = producer_step
                candidates[#candidates + 1] = {
                  item = params.item, entity = proto.name, position = pos, direction = direction,
                  distance = math.sqrt(pdx * pdx + pdy * pdy),
                  distance_from_codex = math.sqrt(codex_distance_sq),
                  terrain = terrain(c.force, c.surface, proto, area),
                  output_position = output_position,
                  output_target = candidate_output_target,
                  input_target = candidate_input_target,
                  pickup_position = pickup_position,
                  drop_position = drop_position,
                  geometry = (input_target or output_target or output_recipient_item) and "provisional" or nil,
                  output_recipient_placement = recipient_placement,
                  build_steps = build_steps,
                  fluid_connections = fluid_connections.prototype(proto, pos, direction),
                  resource_coverage = resource_coverage,
                }
              end
            end
          end
        end
      end
    end
  end
  table.sort(candidates, function(a, b)
    if proto.type == "mining-drill" then
      local function coverage(candidate)
        local amount, count = 0, 0
        for _, row in ipairs(candidate.resource_coverage or {}) do
          amount, count = amount + (row.total_amount or 0), count + (row.entity_count or 0)
        end
        return amount, count
      end
      local aa, ac = coverage(a); local ba, bc = coverage(b)
      if aa ~= ba then return aa > ba end
      if ac ~= bc then return ac > bc end
    end
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    return a.direction < b.direction
  end)
  while #candidates > limit do table.remove(candidates) end
  return { item = params.item, entity = proto.name, preferred = preferred,
    input_target = input_target and input_target.identity or nil,
    output_target = output_target and output_target.identity or nil,
    output_recipient_item = params.output_recipient_item,
    geometry = (input_target or output_target or output_recipient_item) and "provisional" or nil,
    rejected_no_compatible_resource = proto.type == "mining-drill" and rejected_no_compatible_resource or nil,
    candidates = candidates }
end

return M
