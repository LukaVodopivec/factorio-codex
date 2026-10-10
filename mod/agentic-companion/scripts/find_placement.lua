-- Deterministic, side-effect-free placement search over already charted terrain,
-- on the body's surface or the `surface` named (reading is not reach: on
-- another surface no body stands in the way). An entity whose surface
-- conditions the surface breaks fails SURFACE_CONDITION before any search;
-- an offshore pump's candidates say which fluid it pumps there, and `fluid`
-- keeps only spots on that liquid (water, lava, heavy-oil,
-- ammoniacal-solution).
local companion = require("scripts.companion")
local surfaces = require("scripts.surfaces")
local build = require("scripts.actions.build")
local output_targets = require("scripts.output_target")
local placement_geometry = require("scripts.placement_geometry")
local fluid_connections = require("scripts.fluid_connections")
local jobs = require("scripts.jobs")

local M = {}

local function position(value, label)
  if type(value) ~= "table" or tonumber(value.x) == nil or tonumber(value.y) == nil then
    error(label .. " must be {x, y}", 0)
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

-- The force's chart; `platform` (surfaces.is_platform of the surface,
-- worked out once a step) saves the per-call platform read.
local function charted(force, surface, pos, platform)
  return surfaces.charted(force, surface, math.floor(pos.x / 32), math.floor(pos.y / 32), platform)
end

local footprint_charted = surfaces.footprint_charted

local function terrain(force, surface, proto, area, platform)
  if proto.type == "offshore-pump" then return "offshore" end
  local water, land = false, false
  for y = math.floor(area.left_top.y) - 1, math.ceil(area.right_bottom.y) do
    for x = math.floor(area.left_top.x) - 1, math.ceil(area.right_bottom.x) do
      if charted(force, surface, { x = x, y = y }, platform) then
        if placement_geometry.is_liquid(surface, x, y) then water = true else land = true end
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
-- caller charges against its engine budget (about four reads each: valid,
-- position, name, amount). Categories are cached per name.
local function drill_resource_coverage(force, surface, proto, pos, category_by_name, platform)
  local radius = mining_radius(proto)
  if not radius then return nil end
  local area = {
    left_top = { x = pos.x - radius, y = pos.y - radius },
    right_bottom = { x = pos.x + radius, y = pos.y + radius },
  }
  if not footprint_charted(force, surface, area, platform) then return nil end
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
      local name = resource.name
      local category = category_by_name[name]
      if category == nil then
        local ok_category, value = pcall(function() return resource.prototype.resource_category end)
        category = ok_category and type(value) == "string" and value or false
        category_by_name[name] = category
      end
      if category and categories[category] then
        local row = by_name[name] or { name = name, entity_count = 0, total_amount = 0 }
        row.entity_count = row.entity_count + 1
        row.total_amount = row.total_amount + (tonumber(resource.amount) or 0)
        by_name[name] = row
      end
    end
  end
  local rows = {}
  for _, row in pairs(by_name) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows, #resources
end

-- The whole search's ceilings (it is spread over ticks by the job budget).
-- Engine calls are charged as made: COST_DIRECTION per direction (footprint
-- and its four chunk checks), COST_RECIPIENT + COST_PER_ENTITY per entity an
-- endpoint query reads, COST_PLACE_CHECK per can_place_entity (plus the body
-- box), COST_COVERAGE + COST_PER_ENTITY per resource a drill spot reads, and
-- COST_TILE per terrain tile.
local MAX_EVALUATIONS = 2048
local MAX_ENGINE_CALLS = 24000
local COST_DIRECTION, COST_RECIPIENT, COST_PER_ENTITY, COST_PLACE_CHECK, COST_COVERAGE, COST_TILE = 6, 6, 4, 2, 7, 5
local COST_FLUID = 4 -- an offshore pump's source tile: offset, tile, water layer, fluid

local function fuel_inlet(proto)
  local ok, burner = pcall(function() return proto.burner_prototype end)
  return ok and burner ~= nil or false
end

-- A mining drill whose product leaves through an output fluidbox (a
-- pumpjack: its box's production_type, or in 2.0 data a pipe connection
-- whose flow_direction is output): it drops no items, so it has no item
-- endpoint to check; its candidates carry its fluid connections instead.
local function fluid_miner(proto)
  if proto.type ~= "mining-drill" then return false end
  local ok, boxes = pcall(function() return proto.fluidbox_prototypes end)
  for _, box in pairs(ok and type(boxes) == "table" and boxes or {}) do
    local read, output = pcall(function()
      if box.production_type == "output" then return true end
      for _, connection in ipairs(box.pipe_connections or {}) do
        if connection.flow_direction == "output" then return true end
      end
      return false
    end)
    if read and output then return true end
  end
  return false
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

-- find_placement is a job (jobs.lua): the positions within the radius (up
-- to 61 x 61) are listed a row at a time, then visited nearest first, each
-- evaluation charged by the engine calls it makes, then the kept candidates
-- get their terrain and fluid endpoints one at a time. Its state S is plain
-- data (names, positions and the resolved target entities) between ticks.
-- MAX_EVALUATIONS and MAX_ENGINE_CALLS bound the whole search; past either
-- it stops and says so (truncated, with a hint).
-- What the search stands on this tick: the character on its own surface,
-- else a body-less viewpoint at `preferred` on the searched surface (kept in
-- S by index), and whether the body is there.
local function search_context(S)
  local body = companion.require_present()
  -- A search a 0.22.2 save left running searched the body's surface.
  if S.surface_index == nil then S.surface_index, S.surface_ref = body.surface.index, body.surface_ref end
  local surface = surfaces.stored(S.surface_index, body)
  if not surface then error("SURFACE_GONE: surface " .. tostring(S.surface_ref) .. " no longer exists", 0) end
  local here = body.surface ~= nil and body.surface.index == S.surface_index
  return surfaces.viewpoint({ surface = surface, force = body.force, here = here, body = body }, S.preferred), here
end

local function placement_context(S, c, here)
  local item = prototypes.item[S.item]
  local proto = item and item.place_result
  if not proto then error(S.item .. " is not a placeable item", 0) end
  local X = { proto = proto, drop_offset = output_targets.output_offset(proto), here = here }
  -- Read once a step, not per evaluation.
  X.force, X.surface, X.position = c.force, c.surface, c.position
  X.platform = surfaces.is_platform(c.surface)
  X.fluid_miner = fluid_miner(proto)
  X.output_capable = not X.fluid_miner and (proto.type == "mining-drill" or proto.type == "inserter" or X.drop_offset ~= nil)
  if proto.type == "inserter" then
    local ok_pickup, raw_pickup = pcall(function() return proto.inserter_pickup_position end)
    local ok_drop, raw_drop = pcall(function() return proto.inserter_drop_position end)
    if ok_pickup and raw_pickup and ok_drop and raw_drop then
      X.inserter_pickup_offset = prototype_vector(raw_pickup)
      X.inserter_drop_offset = prototype_vector(raw_drop)
    end
  end
  if S.output_recipient_item then
    X.output_recipient_proto = prototypes.item[S.output_recipient_item].place_result
  end
  return X
end

local function search_start(params)
  if type(params.item) ~= "string" then error("find_placement item must be an item name", 0) end
  local item = prototypes.item[params.item]
  if not item or not item.place_result then error(params.item .. " is not a placeable item", 0) end
  local proto = item.place_result
  local belt_error = build.belt_to_ground_error(params.item, proto, params.belt_to_ground_type)
  if belt_error then error(belt_error, 0) end
  local preferred = position(params.preferred, "find_placement preferred")
  local target = surfaces.target(params.surface)
  local c = surfaces.viewpoint(target, preferred)
  local broken = placement_geometry.surface_condition(target.surface, proto.surface_conditions)
  if broken then error(placement_geometry.condition_text(proto.name, broken), 0) end
  if params.fluid ~= nil and (type(params.fluid) ~= "string" or proto.type ~= "offshore-pump") then
    error("find_placement fluid names the liquid an offshore pump should pump (water, lava, heavy-oil, ammoniacal-solution)", 0)
  end
  local radius = math.floor(tonumber(params.radius) or 10)
  local limit = math.floor(tonumber(params.limit) or 8)
  if radius < 1 or radius > 30 then error("find_placement radius must be 1-30", 0) end
  if limit < 1 or limit > 24 then error("find_placement limit must be 1-24", 0) end
  local directions = params.directions or { 0, 4, 8, 12 }
  if type(directions) ~= "table" or #directions == 0 then error("find_placement directions must be a non-empty array", 0) end
  local unique = {}
  for _, raw in ipairs(directions) do
    local direction = tonumber(raw)
    if not direction or direction % 1 ~= 0 or direction < 0 or direction > 15 then
      error("find_placement directions must contain Factorio directions 0-15", 0)
    end
    unique[direction] = true
  end
  directions = {}; for direction in pairs(unique) do directions[#directions + 1] = direction end; table.sort(directions)

  if params.output_target ~= nil and params.output_recipient_item ~= nil then
    error("find_placement accepts output_target or output_recipient_item, not both", 0)
  end
  if (params.output_target ~= nil or params.output_recipient_item ~= nil) and fluid_miner(proto) then
    error("find_placement: " .. params.item .. " outputs fluid through its pipe connections, not items:"
      .. " it takes no output_target or output_recipient_item", 0)
  end

  local input_target, output_target, output_recipient_item, output_recipient_proto = nil, nil, nil, nil
  local drop_offset = output_targets.output_offset(proto)
  if params.input_target ~= nil then
    if proto.type ~= "inserter" or not output_targets.input_offset(proto) then
      error(params.item .. " has no deterministic input offset", 0)
    end
    input_target = output_targets.resolve(c, params.input_target, "find_placement input_target", "input", true)
  end
  if params.output_target ~= nil then
    output_target = output_targets.resolve(c, params.output_target, "find_placement output_target", nil, true)
    if not drop_offset then error(params.item .. " has no deterministic output offset", 0) end
  end
  if params.output_recipient_item ~= nil then
    if type(params.output_recipient_item) ~= "string" then
      error("find_placement output_recipient_item must be an item name", 0)
    end
    output_recipient_item = prototypes.item[params.output_recipient_item]
    output_recipient_proto = output_recipient_item and output_recipient_item.place_result
    if not output_recipient_proto then
      error(tostring(params.output_recipient_item) .. " is not a placeable recipient item", 0)
    end
    if not output_targets.can_target_type(output_recipient_proto.type, "output") then
      error(tostring(params.output_recipient_item) .. " cannot receive placed output", 0)
    end
    if not drop_offset then error(params.item .. " has no deterministic output offset", 0) end
  end
  if input_target or output_target or output_recipient_item then
    for _, direction in ipairs(directions) do
      local required_offset = input_target and output_targets.input_offset(proto) or drop_offset
      if not rotate(required_offset, direction) then
        error("targeted placement directions must be cardinal: 0, 4, 8, or 12", 0)
      end
    end
  end

  local width, height = tonumber(proto.tile_width) or 1, tonumber(proto.tile_height) or 1
  local origin_x, origin_y = snapped(preferred.x, width), snapped(preferred.y, height)
  return {
    item = params.item, belt_to_ground_type = params.belt_to_ground_type,
    surface_index = target.surface.index, surface_ref = target.ref, fluid = params.fluid,
    output_recipient_item = params.output_recipient_item,
    preferred = preferred, radius = radius, limit = limit, directions = directions,
    input_target = input_target, output_target = output_target,
    origin_x = origin_x, origin_y = origin_y, stage = "positions", row = origin_y - radius,
    buckets = {}, band = 0, index = 0,
    rejections = {}, closest_rejected = nil, evaluated = 0, truncated = false, engine_calls = 0,
    candidates = {}, rejected_no_compatible_resource = 0, category_by_name = {}, finished = 0,
    -- Positions are visited in final order (nearest first) for every
    -- entity; a drill's resource coverage is data on its candidate.
    wanted = limit,
  }
end

-- Nearest positions first, so the caps keep the most relevant area. Positions
-- are bucketed by whole-tile distance a row at a time and each bucket is
-- sorted only when the search reaches it; the visiting order is exactly
-- distance, then y, then x.
local POSITION_COST = 0.125
local function list_positions(S, budget)
  local radius = S.radius
  while S.row <= S.origin_y + radius do
    if budget.left <= 0 then return false end
    local y = S.row
    for x = S.origin_x - radius, S.origin_x + radius do
      local pdx, pdy = x - S.preferred.x, y - S.preferred.y
      local distance_sq = pdx * pdx + pdy * pdy
      if distance_sq <= radius * radius then
        local band = math.floor(math.sqrt(distance_sq)) + 1
        local bucket = S.buckets[band] or {}
        bucket[#bucket + 1] = { x = x, y = y, distance_sq = distance_sq }
        S.buckets[band] = bucket
      end
    end
    budget.left = budget.left - (2 * radius + 1) * POSITION_COST
    S.row = y + 1
  end
  return true
end

local function by_distance(a, b)
  if a.distance_sq ~= b.distance_sq then return a.distance_sq < b.distance_sq end
  if a.y ~= b.y then return a.y < b.y end
  return a.x < b.x
end

local function next_spot(S)
  while true do
    local current = S.buckets[S.band]
    if current and S.index < #current then S.index = S.index + 1; return current[S.index] end
    S.band, S.index = S.band + 1, 0
    if S.band > S.radius + 1 then return nil end
    current = S.buckets[S.band]
    if current then table.sort(current, by_distance) end
  end
end

-- One reason per evaluated position and direction, in check order; a later
-- stage means the request got further, so it drives the hint.
local STAGE = {
  uncharted = 2, pickup_not_on_source = 3, output_endpoint_unknown = 4,
  output_not_on_recipient = 5, planned_recipient_unplaceable = 6, no_compatible_resource = 7,
  codex_body_overlap = 8, blocked = 9, wrong_fluid = 10,
}
local function reject(S, reason, pos, direction, area)
  S.rejections[reason] = (S.rejections[reason] or 0) + 1
  local closest = S.closest_rejected
  if not closest or STAGE[reason] > STAGE[closest.reason] then
    S.closest_rejected = { reason = reason, position = { x = pos.x, y = pos.y }, direction = direction, area = area }
  end
end

-- Every direction at one spot: rejections or candidates.
local function evaluate_spot(S, X, c, spot)
  local proto, x, y = X.proto, spot.x, spot.y
  local input_target, output_target = S.input_target, S.output_target
  local cdx, cdy = x - X.position.x, y - X.position.y
  local codex_distance_sq = cdx * cdx + cdy * cdy
  -- A drill's mining area does not depend on direction: query it once per spot.
  local spot_coverage, spot_coverage_read = nil, false
  for _, direction in ipairs(S.directions) do
    if S.evaluated >= MAX_EVALUATIONS or S.engine_calls >= MAX_ENGINE_CALLS then S.truncated = true; return end
    S.evaluated = S.evaluated + 1
    S.engine_calls = S.engine_calls + COST_DIRECTION
    local pos = { x = x, y = y }
    local area = placement_geometry.footprint(proto, pos, direction)
    if not footprint_charted(X.force, X.surface, placement_geometry.placement_area(proto, pos, direction), X.platform) then
      reject(S, "uncharted", pos, direction); goto continue
    end
    do
      -- A fluid miner drops nothing: no item endpoint is read.
      local output_position = not X.fluid_miner and output_targets.output_position(proto, pos, direction) or nil
      local pickup_offset = X.inserter_pickup_offset and rotate(X.inserter_pickup_offset, direction) or nil
      local inserter_output_offset = X.inserter_drop_offset and rotate(X.inserter_drop_offset, direction) or nil
      local pickup_position = pickup_offset and { x = x + pickup_offset.x, y = y + pickup_offset.y } or nil
      local drop_position = inserter_output_offset and { x = x + inserter_output_offset.x, y = y + inserter_output_offset.y } or nil
      if proto.type == "inserter" and output_target then output_position = drop_position end
      local candidate_input_target
      if input_target then
        local input_entity, input_identity, _, read = output_targets.recipient_at(c, pickup_position, "input", proto.type, true)
        S.engine_calls = S.engine_calls + COST_RECIPIENT + COST_PER_ENTITY * (read or 0)
        if input_entity ~= input_target.entity then reject(S, "pickup_not_on_source", pos, direction); goto continue end
        candidate_input_target = input_identity
      end
      local recipient, recipient_identity, recipient_state, read = output_targets.recipient_at(c, output_position, "output", proto.type, true)
      if output_position then S.engine_calls = S.engine_calls + COST_RECIPIENT + COST_PER_ENTITY * (read or 0) end
      if X.output_capable and not (output_position ~= nil and (recipient_state == "bound" or recipient_state == "none")) then
        reject(S, "output_endpoint_unknown", pos, direction); goto continue
      end
      if output_target and recipient ~= output_target.entity then
        reject(S, "output_not_on_recipient", pos, direction); goto continue
      end
      local candidate_output_target
      if output_position and recipient_state == "bound" then candidate_output_target = recipient_identity end
      if output_position and recipient_state == "none" then candidate_output_target = false end
      local recipient_placement
      if S.output_recipient_item then
        local recipient_proto = X.output_recipient_proto
        if output_position and recipient_state == "none" then
          for _, recipient_position in ipairs(output_targets.planned_recipient_positions(
            recipient_proto, output_position, pos, proto.type)) do
            local recipient_area = placement_geometry.footprint(recipient_proto, recipient_position, 0)
            if not placement_geometry.overlaps(area, recipient_area)
              and footprint_charted(X.force, X.surface, recipient_area, X.platform) then
              local recipient_ok, _, _, checks = placement_geometry.can_place(c, recipient_proto, recipient_position, 0)
              S.engine_calls = S.engine_calls + COST_DIRECTION + COST_PLACE_CHECK * (1 + checks)
              if recipient_ok then
                recipient_placement = { item = S.output_recipient_item,
                  entity = recipient_proto.name, position = recipient_position, direction = 0 }
                break
              end
            end
          end
        end
        if not recipient_placement then reject(S, "planned_recipient_unplaceable", pos, direction); goto continue end
      end
      -- Factorio refuses drills without ore, so coverage (one query per spot)
      -- runs before the engine placement check and names the real reason.
      if not spot_coverage_read then
        spot_coverage_read = true
        local resources_read
        spot_coverage, resources_read = drill_resource_coverage(X.force, X.surface, proto, pos, S.category_by_name, X.platform)
        if resources_read then S.engine_calls = S.engine_calls + COST_COVERAGE + COST_PER_ENTITY * resources_read end
      end
      local resource_coverage = spot_coverage
      if resource_coverage and #resource_coverage == 0 then
        S.rejected_no_compatible_resource = S.rejected_no_compatible_resource + 1
        reject(S, "no_compatible_resource", pos, direction); goto continue
      end
      local can_place, placement_reason, _, checks = placement_geometry.can_place(c, proto, pos, direction)
      S.engine_calls = S.engine_calls + COST_PLACE_CHECK * (1 + checks)
      if not can_place then
        reject(S, placement_reason == "CODEX_BODY_OVERLAP" and "codex_body_overlap" or "blocked", pos, direction, area)
        goto continue
      end
      local pumped
      if proto.type == "offshore-pump" then
        pumped = placement_geometry.pumped_fluid(X.surface, proto, pos, direction)
        S.engine_calls = S.engine_calls + COST_FLUID
        if S.fluid and pumped ~= S.fluid then reject(S, "wrong_fluid", pos, direction); goto continue end
      end
      local producer_step = { name = S.item, x = pos.x, y = pos.y, direction = direction }
      producer_step.belt_to_ground_type = S.belt_to_ground_type
      if fuel_inlet(proto) then producer_step.fuel_inlet = true end
      if input_target then producer_step.input_target = input_target.position end
      if output_target then producer_step.output_target = output_target.position end
      if recipient_placement then producer_step.output_target = recipient_placement.position end
      local build_steps = {}
      if recipient_placement then
        build_steps[#build_steps + 1] = { name = recipient_placement.item,
          x = recipient_placement.position.x, y = recipient_placement.position.y,
          direction = recipient_placement.direction,
          fuel_inlet = fuel_inlet(X.output_recipient_proto) or nil }
      end
      build_steps[#build_steps + 1] = producer_step
      S.candidates[#S.candidates + 1] = {
        item = S.item, entity = proto.name, position = pos, direction = direction,
        distance = math.sqrt(spot.distance_sq),
        distance_from_codex = X.here and math.sqrt(codex_distance_sq) or nil,
        fluid = pumped,
        area = area,
        output_position = output_position,
        output_target = candidate_output_target,
        input_target = candidate_input_target,
        pickup_position = pickup_position,
        drop_position = drop_position,
        geometry = (input_target or output_target or S.output_recipient_item) and "provisional" or nil,
        output_recipient_placement = recipient_placement,
        build_steps = build_steps,
        resource_coverage = resource_coverage,
      }
    end
    ::continue::
  end
end

-- Visits positions until the wanted candidates are found, the radius is
-- done or a cap is reached; true once the search is over.
local function search(S, X, c, budget)
  while budget.left > 0 do
    if S.truncated or #S.candidates >= S.wanted then return true end
    local spot = next_spot(S)
    if not spot then return true end
    local before = S.engine_calls
    evaluate_spot(S, X, c, spot)
    budget.left = budget.left - math.max(1, S.engine_calls - before)
  end
  return false
end

-- Nearest first for every type: the bot weighs a drill's resource coverage.
local function rank(a, b)
  if a.distance ~= b.distance then return a.distance < b.distance end
  if a.position.y ~= b.position.y then return a.position.y < b.position.y end
  if a.position.x ~= b.position.x then return a.position.x < b.position.x end
  return a.direction < b.direction
end

-- Terrain and fluid detail only for returned candidates, one a slice: a
-- candidate's terrain reads its footprint's tiles and their chart.
local function detail_candidates(S, X, c, budget)
  if S.finished == 0 then
    table.sort(S.candidates, rank)
    while #S.candidates > S.limit do table.remove(S.candidates) end
  end
  while S.finished < #S.candidates do
    if budget.left <= 0 then return false end
    local candidate = S.candidates[S.finished + 1]
    local area = candidate.area
    candidate.terrain = terrain(X.force, X.surface, X.proto, area, X.platform)
    candidate.fluid_connections = fluid_connections.prototype(X.proto, candidate.position, candidate.direction)
    candidate.area = nil
    local tiles = (math.ceil(area.right_bottom.x) - math.floor(area.left_top.x) + 2)
      * (math.ceil(area.right_bottom.y) - math.floor(area.left_top.y) + 2)
    budget.left = budget.left - COST_TILE * tiles - 4
    S.finished = S.finished + 1
  end
  return true
end

local function search_result(S, X, c)
  local proto, candidates, closest_rejected = X.proto, S.candidates, S.closest_rejected
  local input_target, output_target = S.input_target, S.output_target
  local blocker
  if closest_rejected and closest_rejected.reason == "blocked" and closest_rejected.area then
    for _, entity in ipairs(c.surface.find_entities_filtered({ area = placement_geometry.touching(closest_rejected.area) })) do
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
    hint = endpoint_gap_hint(S.item, proto, input_target, output_target)
    if not hint and closest_rejected then
      local reason = closest_rejected.reason
      if reason == "uncharted" then hint = "the searched area is not charted; move preferred into charted terrain or walk to chart it"
      elseif reason == "pickup_not_on_source" then hint = "no position puts the pickup point on input_target; move preferred next to it or check radius"
      elseif reason == "output_endpoint_unknown" then hint = "the output point lands on several or uncharted recipients; move preferred or use a clearer endpoint"
      elseif reason == "output_not_on_recipient" then hint = "no position puts the output point on output_target; move preferred next to it or check radius"
      elseif reason == "planned_recipient_unplaceable" then hint = "no free spot for " .. tostring(S.output_recipient_item) .. " at any producer output point; clear the area or move preferred"
      elseif reason == "codex_body_overlap" then hint = "only Codex's own body blocks the best positions; walk clear and search again"
      elseif reason == "blocked" then hint = "the best positions are blocked" .. (blocker and string.format(" by %s at (%.17g, %.17g)", blocker.name, blocker.position.x, blocker.position.y) or "") .. "; clear it or move preferred"
      elseif reason == "no_compatible_resource" then
        hint = "the mining area has no " .. (placement_geometry.mineable_names(proto) or "compatible resource")
          .. " near preferred; move preferred onto the resource patch"
      elseif reason == "wrong_fluid" then hint = "no offshore spot near preferred pumps " .. tostring(S.fluid) .. "; move preferred to the shore of that liquid" end
    end
    if S.truncated then
      local stopped = "the search stopped after " .. S.evaluated .. " evaluations, before covering the whole radius; reduce radius or move preferred closer"
      hint = hint and (hint .. "; " .. stopped) or stopped
    end
  end
  return { item = S.item, entity = proto.name, preferred = S.preferred, surface = S.surface_ref, fluid = S.fluid,
    input_target = input_target and input_target.identity or nil,
    output_target = output_target and output_target.identity or nil,
    output_recipient_item = S.output_recipient_item,
    geometry = (input_target or output_target or S.output_recipient_item) and "provisional" or nil,
    rejected_no_compatible_resource = proto.type == "mining-drill" and S.rejected_no_compatible_resource or nil,
    evaluated = S.evaluated, truncated = S.truncated or nil,
    rejections = next(S.rejections) and S.rejections or nil,
    closest_rejected = #candidates == 0 and closest_rejected or nil,
    hint = hint,
    candidates = candidates }
end

local NEXT_STAGE = { positions = "search", search = "detail", detail = "result" }

local function search_step(S, budget)
  local c, here = search_context(S)
  local X = placement_context(S, c, here)
  while budget.left > 0 do
    local stage, done = S.stage, nil
    if stage == "positions" then done = list_positions(S, budget)
    elseif stage == "search" then done = search(S, X, c, budget)
    elseif stage == "detail" then done = detail_candidates(S, X, c, budget)
    else return search_result(S, X, c) end
    if done then S.stage = NEXT_STAGE[stage] end
  end
  return nil
end

-- find_placement {item, preferred, radius?, limit?, directions?, input_target?,
-- output_target?, output_recipient_item?, belt_to_ground_type?, surface?,
-- fluid?}: the job
-- definition; the RPC answers at once when the search fits this tick.
M.job = { start = search_start, step = search_step }
jobs.register("find_placement", M.job)

function M.find_placement(params) return jobs.start("find_placement", params) end

return M
