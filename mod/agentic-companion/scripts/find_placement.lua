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

local function mining_radius(proto)
  if proto.type ~= "mining-drill" then return nil end
  local ok_radius, radius = pcall(function() return proto.mining_drill_radius end)
  radius = ok_radius and tonumber(radius) or nil
  if not radius or radius <= 0 then return nil end
  return radius
end

-- Returns the coverage rows and how many resource entities were read, which the
-- caller charges against its engine budget. Categories are cached per name.
local function drill_resource_coverage(force, surface, proto, pos, category_by_name)
  local radius = mining_radius(proto)
  if not radius then return nil end
  local area = {
    left_top = { x = pos.x - radius, y = pos.y - radius },
    right_bottom = { x = pos.x + radius, y = pos.y + radius },
  }
  if not footprint_charted(force, surface, area) then return nil end
  local ok_categories, categories = pcall(function() return proto.resource_categories end)
  if not ok_categories or type(categories) ~= "table" then return {} end
  local by_name = {}
  category_by_name = category_by_name or {}
  local resources = surface.find_entities_filtered({ area = area, type = "resource" })
  for _, resource in ipairs(resources) do
    local resource_position = resource.valid and resource.position or nil
    local resource_x = resource_position and resource_position.x or nil
    local resource_y = resource_position and resource_position.y or nil
    local center_inside = type(resource_x) == "number" and type(resource_y) == "number"
      and resource_x >= area.left_top.x and resource_x < area.right_bottom.x
      and resource_y >= area.left_top.y and resource_y < area.right_bottom.y
    if center_inside then
      local category = category_by_name[resource.name]
      if category == nil then
        local ok_category, value = pcall(function() return resource.prototype.resource_category end)
        category = ok_category and type(value) == "string" and value or false
        category_by_name[resource.name] = category
      end
      if category and categories[category] then
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
  return rows, #resources
end

local MAX_EVALUATIONS = 2048
local MAX_ENGINE_CALLS = 600

local function fuel_inlet(proto)
  local ok, burner = pcall(function() return proto.burner_prototype end)
  return ok and burner ~= nil or false
end

-- Occupied tile span of an entity box along one axis.
local function tile_span(box, axis)
  return math.floor(box.left_top[axis] + 0.01), math.ceil(box.right_bottom[axis] - 0.01)
end

-- An inserter's pickup and drop tiles lie on its own row or column, reach
-- tiles away on either side. Endpoints in one row or column admit an inserter
-- only for some free-tile gaps between them; report which ones.
local function endpoint_gap_hint(item, proto, input_target, output_target)
  if not (input_target and output_target and proto.type == "inserter") then return nil end
  local pickup = output_targets.input_offset(proto)
  local drop = output_targets.output_offset(proto)
  local source, recipient = input_target.entity, output_target.entity
  if not (pickup and drop and source.bounding_box and recipient.bounding_box) then return nil end
  local function reach(v) return math.floor(0.5 + math.abs(v.x) + math.abs(v.y)) end
  local pick, put = reach(pickup), reach(drop)
  local function spans(axis)
    local s_low, s_high = tile_span(source.bounding_box, axis)
    local r_low, r_high = tile_span(recipient.bounding_box, axis)
    if s_high <= r_low then return s_low, s_high, r_low, r_high end
    if r_high <= s_low then return -s_high, -s_low, -r_high, -r_low end -- mirror: recipient first
    return nil
  end
  -- Can an inserter tile sit strictly between the spans when the recipient
  -- starts gap tiles after the source ends?
  local function feasible(s_low, s_high, r_width, gap)
    local r_low = s_high + gap
    for s = math.max(s_low, s_high - pick), s_high - 1 do
      local tile = s + pick
      local r = tile + put
      if tile >= s_high and tile < r_low and r >= r_low and r < r_low + r_width then return true end
    end
    return false
  end
  local label = string.format("%s at (%.17g, %.17g) and %s at (%.17g, %.17g)", source.name, source.position.x,
    source.position.y, recipient.name, recipient.position.x, recipient.position.y)
  local function aligned(axis)
    local a_low, a_high = tile_span(source.bounding_box, axis)
    local b_low, b_high = tile_span(recipient.bounding_box, axis)
    return math.max(a_low, b_low) < math.min(a_high, b_high)
  end
  local x_low, x_high, xr_low, xr_high = spans("x")
  local y_low, y_high, yr_low, yr_high = spans("y")
  local function needs(s_low, s_high, r_width)
    local ok = {}
    for gap = 0, pick + put do if feasible(s_low, s_high, r_width, gap) then ok[#ok + 1] = gap end end
    if #ok == 0 then return "a different endpoint size" end
    local low, high = ok[1], ok[#ok]
    if low == high then return string.format("exactly %d free tile%s", low, low == 1 and "" or "s") end
    return string.format("%d-%d free tiles", low, high)
  end
  local function message(problem, requirement)
    return string.format("%s %s; %s needs %s between them in one row or column — move one endpoint",
      label, problem, item, requirement)
  end
  if x_low and y_low then return message("are diagonal, not in one row or column", needs(0, 1, 1)) end
  if not (x_low or y_low) then return message("overlap", needs(0, 1, 1)) end
  local s_low, s_high, r_low, r_high, other = x_low, x_high, xr_low, xr_high, "y"
  if not x_low then s_low, s_high, r_low, r_high, other = y_low, y_high, yr_low, yr_high, "x" end
  local requirement = needs(s_low, s_high, r_high - r_low)
  if not aligned(other) then return message("do not share a row or column", requirement) end
  local gap = r_low - s_high
  if feasible(s_low, s_high, r_high - r_low, gap) then return nil end
  return message(gap == 0 and "are adjacent (0 free tiles)"
    or string.format("have %d free tile%s", gap, gap == 1 and "" or "s"), requirement)
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
    input_target = output_targets.resolve(c, params.input_target, "find_placement input_target", "input")
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
    if not output_targets.can_target_type(output_recipient_proto.type, "output") then
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
  -- Nearest positions first, so the caps keep the most relevant area. Positions
  -- are bucketed by whole-tile distance and each bucket is sorted only when the
  -- search reaches it; the visiting order is exactly distance, then y, then x.
  local buckets = {}
  for y = origin_y - radius, origin_y + radius do
    for x = origin_x - radius, origin_x + radius do
      local pdx, pdy = x - preferred.x, y - preferred.y
      local distance_sq = pdx * pdx + pdy * pdy
      if distance_sq <= radius * radius then
        local band = math.floor(math.sqrt(distance_sq)) + 1
        local bucket = buckets[band] or {}
        bucket[#bucket + 1] = { x = x, y = y, distance_sq = distance_sq }
        buckets[band] = bucket
      end
    end
  end
  local function by_distance(a, b)
    if a.distance_sq ~= b.distance_sq then return a.distance_sq < b.distance_sq end
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end
  local function nearest_positions()
    local band, index, current = 0, 0, nil
    return function()
      while true do
        if current and index < #current then index = index + 1; return current[index] end
        band = band + 1
        if band > radius + 1 then return nil end
        current, index = buckets[band], 0
        if current then table.sort(current, by_distance) end
      end
    end
  end

  -- One reason per evaluated position and direction, in check order; a later
  -- stage means the request got further, so it drives the hint.
  local stage = {
    outside_codex_reach = 1, uncharted = 2, pickup_not_on_source = 3, output_endpoint_unknown = 4,
    output_not_on_recipient = 5, planned_recipient_unplaceable = 6, no_compatible_resource = 7,
    codex_body_overlap = 8, blocked = 9,
  }
  local rejections, closest_rejected, evaluated, truncated = {}, nil, 0, false
  local candidates, rejected_no_compatible_resource = {}, 0
  -- Positions are visited in final order for every entity except drills, which
  -- rank useful coverage first among the nearest valid positions found.
  local wanted = mining_radius(proto) and math.min(limit * 2, 48) or limit
  local category_by_name = {}
  local function reject(reason, pos, direction, area)
    rejections[reason] = (rejections[reason] or 0) + 1
    if not closest_rejected or stage[reason] > stage[closest_rejected.reason] then
      closest_rejected = { reason = reason, position = { x = pos.x, y = pos.y }, direction = direction, area = area }
    end
  end
  -- Engine queries dominate the cost of one search (about 10-15 microseconds
  -- each); the budget keeps a call within one game tick.
  local engine_calls = 0
  for spot in nearest_positions() do
    if truncated or #candidates >= wanted then break end
    local x, y = spot.x, spot.y
    local cdx, cdy = x - c.position.x, y - c.position.y
    local codex_distance_sq = cdx * cdx + cdy * cdy
    -- A drill's mining area does not depend on direction: query it once per spot.
    local spot_coverage, spot_coverage_read = nil, false
    for _, direction in ipairs(directions) do
      if evaluated >= MAX_EVALUATIONS or engine_calls >= MAX_ENGINE_CALLS then truncated = true; break end
      evaluated = evaluated + 1
      local pos = { x = x, y = y }
      local area = placement_geometry.footprint(proto, pos, direction)
      if codex_distance_sq > 900 then reject("outside_codex_reach", pos, direction); goto continue end
      if not footprint_charted(c.force, c.surface, area) then reject("uncharted", pos, direction); goto continue end
      do
        local output_position = output_targets.output_position(proto, pos, direction)
        local pickup_offset = inserter_pickup_offset and rotate(inserter_pickup_offset, direction) or nil
        local inserter_output_offset = inserter_drop_offset and rotate(inserter_drop_offset, direction) or nil
        local pickup_position = pickup_offset and { x = x + pickup_offset.x, y = y + pickup_offset.y } or nil
        local drop_position = inserter_output_offset and { x = x + inserter_output_offset.x, y = y + inserter_output_offset.y } or nil
        if proto.type == "inserter" and output_target then output_position = drop_position end
        local candidate_input_target
        if input_target then
          engine_calls = engine_calls + 1
          local input_entity, input_identity = output_targets.recipient_at(c, pickup_position, "input")
          if input_entity ~= input_target.entity then reject("pickup_not_on_source", pos, direction); goto continue end
          candidate_input_target = input_identity
        end
        if output_position then engine_calls = engine_calls + 1 end
        local recipient, recipient_identity, recipient_state = output_targets.recipient_at(c, output_position)
        if output_capable and not (output_position ~= nil and (recipient_state == "bound" or recipient_state == "none")) then
          reject("output_endpoint_unknown", pos, direction); goto continue
        end
        if output_target and recipient ~= output_target.entity then
          reject("output_not_on_recipient", pos, direction); goto continue
        end
        local candidate_output_target
        if output_position and recipient_state == "bound" then candidate_output_target = recipient_identity end
        if output_position and recipient_state == "none" then candidate_output_target = false end
        local recipient_placement
        if output_recipient_item then
          if output_position and recipient_state == "none" then
            for _, recipient_position in ipairs(output_targets.planned_recipient_positions(
              output_recipient_proto, output_position, pos)) do
              local recipient_area = placement_geometry.footprint(output_recipient_proto, recipient_position, 0)
              if not placement_geometry.overlaps(area, recipient_area)
                and footprint_charted(c.force, c.surface, recipient_area) then
                engine_calls = engine_calls + 1
                if placement_geometry.can_place(c, output_recipient_proto, recipient_position, 0) then
                  recipient_placement = { item = params.output_recipient_item,
                    entity = output_recipient_proto.name, position = recipient_position, direction = 0 }
                  break
                end
              end
            end
          end
          if not recipient_placement then reject("planned_recipient_unplaceable", pos, direction); goto continue end
        end
        -- Factorio refuses drills without ore, so coverage (one query per spot)
        -- runs before the engine placement check and names the real reason.
        if not spot_coverage_read then
          spot_coverage_read = true
          local resources_read
          spot_coverage, resources_read = drill_resource_coverage(c.force, c.surface, proto, pos, category_by_name)
          if resources_read then engine_calls = engine_calls + 1 + math.ceil(resources_read / 8) end
        end
        local resource_coverage = spot_coverage
        if resource_coverage and #resource_coverage == 0 then
          rejected_no_compatible_resource = rejected_no_compatible_resource + 1
          reject("no_compatible_resource", pos, direction); goto continue
        end
        engine_calls = engine_calls + 1
        local can_place, placement_reason = placement_geometry.can_place(c, proto, pos, direction)
        if not can_place then
          reject(placement_reason == "CODEX_BODY_OVERLAP" and "codex_body_overlap" or "blocked", pos, direction, area)
          goto continue
        end
        local producer_step = { name = params.item, x = pos.x, y = pos.y, direction = direction }
        if fuel_inlet(proto) then producer_step.fuel_inlet = true end
        if input_target then producer_step.input_target = input_target.position end
        if output_target then producer_step.output_target = output_target.position end
        if recipient_placement then producer_step.output_target = recipient_placement.position end
        local build_steps = {}
        if recipient_placement then
          build_steps[#build_steps + 1] = { name = recipient_placement.item,
            x = recipient_placement.position.x, y = recipient_placement.position.y,
            direction = recipient_placement.direction,
            fuel_inlet = fuel_inlet(output_recipient_proto) or nil }
        end
        build_steps[#build_steps + 1] = producer_step
        candidates[#candidates + 1] = {
          item = params.item, entity = proto.name, position = pos, direction = direction,
          distance = math.sqrt(spot.distance_sq),
          distance_from_codex = math.sqrt(codex_distance_sq),
          area = area,
          output_position = output_position,
          output_target = candidate_output_target,
          input_target = candidate_input_target,
          pickup_position = pickup_position,
          drop_position = drop_position,
          geometry = (input_target or output_target or output_recipient_item) and "provisional" or nil,
          output_recipient_placement = recipient_placement,
          build_steps = build_steps,
          resource_coverage = resource_coverage,
        }
      end
      ::continue::
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
  -- Terrain and fluid detail only for returned candidates.
  for _, candidate in ipairs(candidates) do
    candidate.terrain = terrain(c.force, c.surface, proto, candidate.area)
    candidate.fluid_connections = fluid_connections.prototype(proto, candidate.position, candidate.direction)
    candidate.area = nil
  end
  local blocker
  if closest_rejected and closest_rejected.reason == "blocked" and closest_rejected.area then
    for _, entity in ipairs(c.surface.find_entities_filtered({ area = closest_rejected.area })) do
      if entity.valid and not placement_geometry.NON_BLOCKING_TYPES[entity.type] then
        blocker = { name = entity.name, position = { x = entity.position.x, y = entity.position.y } }
        break
      end
    end
    closest_rejected.blocker = blocker
  end
  if closest_rejected then closest_rejected.area = nil end
  local hint
  if #candidates == 0 then
    hint = endpoint_gap_hint(params.item, proto, input_target, output_target)
    if not hint and closest_rejected then
      local reason = closest_rejected.reason
      if reason == "outside_codex_reach" then hint = "the searched area is more than 30 tiles from Codex; walk closer or move preferred"
      elseif reason == "uncharted" then hint = "the searched area is not charted; move preferred into charted terrain or walk to chart it"
      elseif reason == "pickup_not_on_source" then hint = "no position puts the pickup point on input_target; move preferred next to it or check radius"
      elseif reason == "output_endpoint_unknown" then hint = "the output point lands on several or uncharted recipients; move preferred or use a clearer endpoint"
      elseif reason == "output_not_on_recipient" then hint = "no position puts the output point on output_target; move preferred next to it or check radius"
      elseif reason == "planned_recipient_unplaceable" then hint = "no free spot for " .. tostring(params.output_recipient_item) .. " at any producer output point; clear the area or move preferred"
      elseif reason == "codex_body_overlap" then hint = "only Codex's own body blocks the best positions; walk clear and search again"
      elseif reason == "blocked" then hint = "the best positions are blocked" .. (blocker and string.format(" by %s at (%.17g, %.17g)", blocker.name, blocker.position.x, blocker.position.y) or "") .. "; clear it or move preferred"
      elseif reason == "no_compatible_resource" then hint = "no compatible resource under the mining area near preferred; move preferred onto the resource patch" end
    end
    if truncated then
      local stopped = "the search stopped after " .. evaluated .. " evaluations, before covering the whole radius; reduce radius or move preferred closer"
      hint = hint and (hint .. "; " .. stopped) or stopped
    end
  end
  return { item = params.item, entity = proto.name, preferred = preferred,
    input_target = input_target and input_target.identity or nil,
    output_target = output_target and output_target.identity or nil,
    output_recipient_item = params.output_recipient_item,
    geometry = (input_target or output_target or output_recipient_item) and "provisional" or nil,
    rejected_no_compatible_resource = proto.type == "mining-drill" and rejected_no_compatible_resource or nil,
    evaluated = evaluated, truncated = truncated or nil,
    rejections = next(rejections) and rejections or nil,
    closest_rejected = #candidates == 0 and closest_rejected or nil,
    hint = hint,
    candidates = candidates }
end

return M
