-- Protocol-v10 local perception: compact by default; full adds the ASCII grid.
-- (dry-run placement check with blocker naming),
-- clear rectangle) and describe_prototype (geometry/energy facts about items,
-- entities and recipes). All instant methods — no tasks, no side effects.
local companion = require("scripts.companion")
local tasks = require("scripts.tasks")

local M = {}

local SCAN_DEFAULT_RADIUS = 15
local SCAN_MIN_RADIUS = 5
local SCAN_MAX_RADIUS = 30
local DESCRIBE_MAX_NAMES = 10

local UPPER_LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local LOWER_LETTERS = "abcdefghijklmnopqrstuvwxyz"

-- ---------------------------------------------------------------- helpers

local function require_position(pos, message)
  if type(pos) ~= "table" or tonumber(pos.x) == nil or tonumber(pos.y) == nil then
    error(message)
  end
  return { x = tonumber(pos.x), y = tonumber(pos.y) }
end

-- Water test for one tile. 2.0 names the collision layer "water_tile"; we
-- probe once per session (falling back to the hyphenated spelling, then to
-- reading the prototype collision mask directly) so a rename never breaks us.
local water_layer -- nil = not probed yet, false = probing failed, string = layer id

local function tile_is_water(tile)
  if water_layer then
    local ok, res = pcall(function() return tile.collides_with(water_layer) end)
    if ok then return res == true end
  end
  if water_layer == nil then
    for _, layer in ipairs({ "water_tile", "water-tile" }) do
      local ok, res = pcall(function() return tile.collides_with(layer) end)
      if ok then
        water_layer = layer
        return res == true
      end
    end
    water_layer = false
  end
  local ok, mask = pcall(function() return tile.prototype.collision_mask end)
  if ok and type(mask) == "table" and type(mask.layers) == "table" then
    return mask.layers["water_tile"] == true or mask.layers["water-tile"] == true
  end
  return false
end

local function is_water_at(surface, x, y)
  local ok, tile = pcall(surface.get_tile, x, y)
  if not ok or not tile then return false end
  return tile_is_water(tile)
end

-- Normalize a Factorio Vector ({x=,y=} or {1,2}) to a plain {x, y} table.
local function vec_xy(v)
  if type(v) ~= "table" then return nil end
  local x = tonumber(v.x) or tonumber(v[1])
  local y = tonumber(v.y) or tonumber(v[2])
  if x == nil or y == nil then return nil end
  return { x = x, y = y }
end

-- Sorted list of the keys of a {name = true} dictionary (nil when empty).
local function sorted_keys(dict)
  if type(dict) ~= "table" then return nil end
  local keys = {}
  for k in pairs(dict) do keys[#keys + 1] = k end
  if #keys == 0 then return nil end
  table.sort(keys)
  return keys
end

-- World-space union of the selection and collision/bounding boxes. Keeping
-- the precise floats in details while using floor/ceil only for grid painting
-- makes edge-overlap behavior observable without shrinking large entities.
local function entity_bounds(e)
  local left, top, right, bottom
  local function include(box)
    if box and box.left_top and box.right_bottom then
      left = left and math.min(left, box.left_top.x) or box.left_top.x
      top = top and math.min(top, box.left_top.y) or box.left_top.y
      right = right and math.max(right, box.right_bottom.x) or box.right_bottom.x
      bottom = bottom and math.max(bottom, box.right_bottom.y) or box.right_bottom.y
    end
  end
  include(e.selection_box)
  include(e.bounding_box)
  if not left then
    left, top, right, bottom = e.position.x, e.position.y, e.position.x + 1, e.position.y + 1
  end
  return { left_top = { x = left, y = top }, right_bottom = { x = right, y = bottom } }
end

local function entity_status(e)
  local ok, status = pcall(function() return e.status end)
  if ok and status ~= nil then
    for name, value in pairs((defines and defines.entity_status) or {}) do if value == status then return name end end
    return tostring(status)
  end
  return nil
end

local function entity_recipe(e)
  local ok, recipe = pcall(function() return e.get_recipe and e.get_recipe() end)
  if ok and recipe then return recipe.name end
  return nil
end

-- Area queries are collision-based, while the observation contract reports
-- the union of collision and selection footprints. Expand only the bounded
-- local query by the largest installed prototype extent, then precisely
-- intersect each returned entity with the requested grid below.
local footprint_query_margin
local function max_footprint_extent()
  if footprint_query_margin ~= nil then return footprint_query_margin end
  local margin = 0
  for _, proto in pairs((prototypes and prototypes.entity) or {}) do
    local function include(box)
      if box then
        local lt, rb = vec_xy(box.left_top), vec_xy(box.right_bottom)
        if lt and rb then
          margin = math.max(margin, math.abs(lt.x), math.abs(lt.y), math.abs(rb.x), math.abs(rb.y))
        end
      end
    end
    include(proto.collision_box)
    include(proto.selection_box)
  end
  footprint_query_margin = margin
  return margin
end

-- ----------------------------------------------------------- observe_local

-- Higher paints over lower when several things share a tile.
local PRIORITY = {
  land = 0, water = 1, cliff = 2, rock = 3, tree = 4,
  resource = 5, ground_item = 6, building = 7, player = 8, companion = 9,
}

function M.observe_local(params)
  local c = companion.require_companion()
  local surface = c.surface

  local radius = math.floor(tonumber(params.radius) or SCAN_DEFAULT_RADIUS)
  radius = math.max(SCAN_MIN_RADIUS, math.min(radius, SCAN_MAX_RADIUS))

  local center = c.position
  local ox = math.floor(center.x) - radius
  local oy = math.floor(center.y) - radius
  local size = radius * 2 + 1

  -- Fixed symbols are pre-registered so dynamically assigned letters can
  -- never collide with them (T/R/P and lowercase c are reserved).
  local legend = {
    ["."] = "buildable land",
    ["~"] = "water",
    ["c"] = "cliff",
    ["T"] = "tree",
    ["R"] = "rock",
    ["@"] = "you",
    ["P"] = "player",
    ["*"] = "item stack on ground",
  }

  -- Assign the next free letter of `alphabet` to each distinct name.
  local function letter_for(name, assigned, alphabet)
    local ch = assigned[name]
    if ch then return ch end
    for i = 1, #alphabet do
      local cand = string.sub(alphabet, i, i)
      if legend[cand] == nil then
        assigned[name] = cand
        legend[cand] = name
        return cand
      end
    end
    -- More than the alphabet can hold — extremely unlikely at radius <= 30.
    assigned[name] = "?"
    legend["?"] = "several different things (ran out of letters)"
    return "?"
  end
  local resource_letters, building_letters = {}, {}

  -- Terrain pass: land / water.
  local chars, prio, paint_key = {}, {}, {}
  for row = 1, size do
    local crow, prow, krow = {}, {}, {}
    chars[row], prio[row], paint_key[row] = crow, prow, krow
    for col = 1, size do
      if is_water_at(surface, ox + col - 1, oy + row - 1) then
        crow[col], prow[col], krow[col] = "~", PRIORITY.water, "water"
      else
        crow[col], prow[col], krow[col] = ".", PRIORITY.land, "land"
      end
    end
  end

  -- Entity pass: paint complete selection/collision footprints.
  local query_margin = max_footprint_extent()
  local entities = surface.find_entities_filtered({
    area = { { ox - query_margin, oy - query_margin }, { ox + size + query_margin, oy + size + query_margin } },
  })
  -- Factorio does not promise entity iteration order. First retain everything
  -- whose precise footprint intersects the grid, including centers outside it.
  local visible = {}
  for _, e in ipairs(entities) do
    if e.valid then
      local bounds = entity_bounds(e)
      if bounds.right_bottom.x > ox and bounds.left_top.x < ox + size
        and bounds.right_bottom.y > oy and bounds.left_top.y < oy + size then
        visible[#visible + 1] = { entity = e, bounds = bounds }
      end
    end
  end

  -- Pre-assign dynamic glyphs from lexical entity names so shuffled engine
  -- iteration cannot change the grid or legend.
  local resource_names, building_names, seen_resource, seen_building = {}, {}, {}, {}
  for _, entry in ipairs(visible) do
    local e = entry.entity
    if e.valid and e.type == "resource" and not seen_resource[e.name] then seen_resource[e.name] = true; resource_names[#resource_names + 1] = e.name
    elseif e.valid and e.type == "item-entity" then
    elseif e.valid and e.force == c.force and e ~= c and e.type ~= "character" and not seen_building[e.name] then seen_building[e.name] = true; building_names[#building_names + 1] = e.name end
  end
  table.sort(resource_names); table.sort(building_names)
  for _, name in ipairs(resource_names) do letter_for(name, resource_letters, UPPER_LETTERS) end
  for _, name in ipairs(building_names) do letter_for(name, building_letters, LOWER_LETTERS) end
  local details, resources_by_name, ground_items = {}, {}, {}
  for _, entry in ipairs(visible) do
    local e, bounds = entry.entity, entry.bounds
    if e.valid then
        local ch, p
        if e == c then
          ch, p = "@", PRIORITY.companion
        elseif e.type == "character" then
          ch, p = "P", PRIORITY.player
        elseif e.type == "item-entity" then
          local stack = e.stack
          if stack and stack.valid_for_read then
            ch, p = "*", PRIORITY.ground_item
            local ddx, ddy = e.position.x - c.position.x, e.position.y - c.position.y
            ground_items[#ground_items + 1] = {
              item = stack.name, count = stack.count,
              position = { x = e.position.x, y = e.position.y },
              distance = math.sqrt(ddx * ddx + ddy * ddy),
            }
          end
        elseif e.force == c.force then
          ch, p = letter_for(e.name, building_letters, LOWER_LETTERS), PRIORITY.building
        elseif e.type == "resource" then
          ch, p = letter_for(e.name, resource_letters, UPPER_LETTERS), PRIORITY.resource
        elseif e.type == "tree" then
          ch, p = "T", PRIORITY.tree
        elseif e.type == "simple-entity" then
          ch, p = "R", PRIORITY.rock
        elseif e.type == "cliff" then
          ch, p = "c", PRIORITY.cliff
        end
        local x1, y1 = math.floor(bounds.left_top.x), math.floor(bounds.left_top.y)
        local x2, y2 = math.ceil(bounds.right_bottom.x), math.ceil(bounds.right_bottom.y)
        if ch then
          local key = string.format("%s\0%s\0%.17g\0%.17g\0%d", e.name, e.type,
            e.position.y, e.position.x, tonumber(e.unit_number) or -1)
          for py = y1, y2 - 1 do for px = x1, x2 - 1 do
            local rr, cc = py - oy + 1, px - ox + 1
            if rr >= 1 and rr <= size and cc >= 1 and cc <= size
              and (p > prio[rr][cc] or (p == prio[rr][cc] and key < paint_key[rr][cc])) then
              chars[rr][cc], prio[rr][cc], paint_key[rr][cc] = ch, p, key
            end
          end end
          if e.type == "resource" then
            resources_by_name[e.name] = resources_by_name[e.name] or {}
            resources_by_name[e.name][#resources_by_name[e.name] + 1] = e
          elseif e.type ~= "item-entity" then
            local ddx, ddy = e.position.x - c.position.x, e.position.y - c.position.y
            details[#details + 1] = { symbol = ch, name = e.name, type = e.type, position = { x = e.position.x, y = e.position.y }, direction = e.direction, status = entity_status(e), recipe = entity_recipe(e), bounds = bounds, footprint = { width = bounds.right_bottom.x - bounds.left_top.x, height = bounds.right_bottom.y - bounds.left_top.y }, _distance = ddx * ddx + ddy * ddy, _unit = tonumber(e.unit_number) or -1 }
          end
        end
    end
  end

  local grid = {}
  for row = 1, size do
    grid[row] = table.concat(chars[row])
  end

  table.sort(details, function(a, b)
    if a._distance ~= b._distance then return a._distance < b._distance end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.name ~= b.name then return a.name < b.name end
    if a.type ~= b.type then return a.type < b.type end
    return a._unit < b._unit
  end)
  local omitted = math.max(0, #details - 256); while #details > 256 do table.remove(details) end
  table.sort(details, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.name ~= b.name then return a.name < b.name end
    if a.type ~= b.type then return a.type < b.type end
    return a._unit < b._unit
  end)
  for _, detail in ipairs(details) do detail._distance, detail._unit = nil, nil end
  table.sort(ground_items, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.item ~= b.item then return a.item < b.item end
    return a.count < b.count
  end)
  local omitted_ground_items = math.max(0, #ground_items - 256)
  while #ground_items > 256 do table.remove(ground_items) end
  table.sort(ground_items, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.item ~= b.item then return a.item < b.item end
    return a.count < b.count
  end)
  local patches = {}
  for name, resources in pairs(resources_by_name) do
    table.sort(resources, function(a, b)
      if a.position.y ~= b.position.y then return a.position.y < b.position.y end
      if a.position.x ~= b.position.x then return a.position.x < b.position.x end
      if (a.amount or 0) ~= (b.amount or 0) then return (a.amount or 0) < (b.amount or 0) end
      return (tonumber(a.unit_number) or -1) < (tonumber(b.unit_number) or -1)
    end)
    local visited = {}
    for start = 1, #resources do if not visited[start] then
      local queue, head, count, amount, sx, sy, members = { start }, 1, 0, 0, 0, 0, {}; visited[start] = true
      local nearest, nearest_distance_sq, nearest_unit
      while head <= #queue do
        local index = queue[head]; head = head + 1; local e = resources[index]
        count, amount, sx, sy = count + 1, amount + (e.amount or 0), sx + e.position.x, sy + e.position.y
        local ndx, ndy = e.position.x - c.position.x, e.position.y - c.position.y
        local distance_sq, unit = ndx * ndx + ndy * ndy, tonumber(e.unit_number) or -1
        if not nearest or distance_sq < nearest_distance_sq
          or (distance_sq == nearest_distance_sq and (e.position.y < nearest.position.y
            or (e.position.y == nearest.position.y and (e.position.x < nearest.position.x
              or (e.position.x == nearest.position.x and ((e.amount or 0) < (nearest.amount or 0)
                or ((e.amount or 0) == (nearest.amount or 0) and unit < nearest_unit))))))) then
          nearest, nearest_distance_sq, nearest_unit = e, distance_sq, unit
        end
        members[#members + 1] = string.format("%.17g,%.17g,%.17g,%d", e.position.x, e.position.y,
          e.amount or 0, tonumber(e.unit_number) or -1)
        for other = 1, #resources do if not visited[other] then local o = resources[other]; if math.abs(e.position.x - o.position.x) <= 1.1 and math.abs(e.position.y - o.position.y) <= 1.1 then visited[other] = true; queue[#queue + 1] = other end end end
      end
      local center = { x = sx / count, y = sy / count }; local dx, dy = center.x - c.position.x, center.y - c.position.y
      patches[#patches + 1] = { name = name, entity_count = count, total_amount = amount, center = center, distance = math.sqrt(dx * dx + dy * dy), nearest_target = { x = nearest.position.x, y = nearest.position.y, amount = nearest.amount or 0, distance = math.sqrt(nearest_distance_sq) }, _members = table.concat(members, ";") }
    end end
  end
  table.sort(patches, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.name ~= b.name then return a.name < b.name end
    if a.center.y ~= b.center.y then return a.center.y < b.center.y end
    if a.center.x ~= b.center.x then return a.center.x < b.center.x end
    if a.entity_count ~= b.entity_count then return a.entity_count < b.entity_count end
    if a.total_amount ~= b.total_amount then return a.total_amount < b.total_amount end
    return a._members < b._members
  end)
  for _, patch in ipairs(patches) do patch._members = nil end
  local inventory = {}; for _, item in ipairs(c.get_main_inventory().get_contents()) do inventory[item.name] = (inventory[item.name] or 0) + item.count end
  local crafting = { queue_size = c.crafting_queue_size or 0, progress = c.crafting_queue_progress or 0, queue = {} }
  for _, entry in ipairs(c.crafting_queue or {}) do
    local recipe = entry.recipe
    pcall(function() recipe = entry.recipe.name end)
    crafting.queue[#crafting.queue + 1] = { recipe = recipe, count = entry.count }
  end
  local result = {
    tick = game.tick, radius = radius, detail = params.detail == "full" and "full" or "compact",
    character = { position = { x = c.position.x, y = c.position.y }, health = c.health,
      inventory = inventory, active_task = tasks.active_summary(), queue_depth = tasks.queue_length(),
      crafting = crafting, reach_distance = c.reach_distance, build_distance = c.build_distance },
    entities = details, resource_patches = patches, ground_items = ground_items,
    omitted_entities = omitted, omitted_ground_items = omitted_ground_items,
  }
  if result.detail == "full" then
    result.grid = { origin = { x = ox, y = oy }, width = size, height = size, rows = grid, legend = legend,
      coordinate_rule = "rows north-to-south; columns west-to-east; x=origin.x+column, y=origin.y+row" }
  end
  return result
end

-- --------------------------------------------------------------- can_place

-- The entity's collision box translated to `pos` (quarter turns swap the
-- axes — a good-enough approximation for the blocker search).
local function footprint(proto, pos, direction)
  local box = proto.collision_box
  local lt, rb = box.left_top, box.right_bottom
  if direction == 4 or direction == 12 then
    lt, rb = { x = lt.y, y = lt.x }, { x = rb.y, y = rb.x }
  end
  return {
    { pos.x + lt.x, pos.y + lt.y },
    { pos.x + rb.x, pos.y + rb.y },
  }
end

local function footprint_touches_water(surface, area)
  local x1, y1 = area[1][1], area[1][2]
  local x2, y2 = area[2][1], area[2][2]
  for ty = math.floor(y1), math.max(math.ceil(y2) - 1, math.floor(y1)) do
    for tx = math.floor(x1), math.max(math.ceil(x2) - 1, math.floor(x1)) do
      if is_water_at(surface, tx, ty) then return true end
    end
  end
  return false
end

local function can_place_one(c, surface, item, position, direction)
  if type(item) ~= "string" then
    error("can_place requires item = <item name>")
  end
  local pos = require_position(position, "can_place requires position = {x, y}")
  local dx, dy = pos.x - c.position.x, pos.y - c.position.y
  if math.sqrt(dx * dx + dy * dy) > 30 then error("can_place positions must be within 30 tiles of Codex") end
  direction = math.floor(tonumber(direction) or 0) % 16

  local item_proto = prototypes.item[item]
  if not item_proto then
    error("no item called '" .. item .. "' — check the spelling with describe_prototype")
  end
  local entity_proto = item_proto.place_result
  if not entity_proto then
    error(item .. " is not a placeable item — it doesn't turn into a building")
  end

  local ok = surface.can_place_entity({
    name = entity_proto.name,
    position = pos,
    direction = direction,
    force = c.force,
    build_check_type = defines.build_check_type.manual,
  })
  local identity = {
    item = item,
    entity = entity_proto.name,
    position = { x = pos.x, y = pos.y },
    direction = direction,
  }
  if ok then
    identity.can_place = true
    identity.reason = "placeable"
    return identity
  end

  -- Best-effort explanation: name whatever occupies the would-be footprint.
  local area = footprint(entity_proto, pos, direction)
  local blocker, companion_in_way
  for _, e in ipairs(surface.find_entities_filtered({ area = area })) do
    if e.valid then
      if e == c then
        companion_in_way = true
      elseif e.type ~= "resource" and e.type ~= "item-entity" and not blocker then
        blocker = e
      end
    end
  end

  local reason
  if blocker then
    reason = string.format("blocked by %s at (%.1f, %.1f)",
      blocker.name, blocker.position.x, blocker.position.y)
    if companion_in_way then
      reason = reason .. " — and I'm standing in the footprint too, I'll need to step aside"
    end
  elseif footprint_touches_water(surface, area) then
    reason = "the footprint touches water — pick dry land or place landfill first"
    if companion_in_way then
      reason = reason .. " (I'm also standing there)"
    end
  elseif companion_in_way then
    reason = "I'm standing there — I'll need to step aside before this can be placed"
  else
    reason = "blocked (terrain or overlap)"
  end
  identity.can_place = false
  identity.reason = reason
  return identity
end

local MAX_PLACEMENTS = 24

-- placements = [{item, position = {x,y}, direction?}, ...] checks up to
-- MAX_PLACEMENTS spots in one call.
function M.can_place(params)
  local c = companion.require_companion()
  local surface = c.surface

  if type(params) ~= "table" or type(params.placements) ~= "table" or #params.placements == 0 then
    error("placements must be a non-empty array")
  end
  if #params.placements > MAX_PLACEMENTS then
    error("can_place takes at most " .. MAX_PLACEMENTS .. " placements per call — split the list")
  end
  for i, p in ipairs(params.placements) do
    if type(p) ~= "table" or type(p.item) ~= "string" then
      error("placements[" .. i .. "].item must be an item name")
    end
  end
  local out = {}
  for i, p in ipairs(params.placements) do
    local ok, res = pcall(can_place_one, c, surface, p.item, p.position, p.direction)
    if not ok then
      res = { can_place = false, reason = tostring(res):gsub("^.-:%d+:%s*", "") }
    end
    res.item = res.item or p.item
    res.direction = res.direction or math.floor(tonumber(p.direction) or 0) % 16
    res.position = {
      x = tonumber(type(p.position) == "table" and p.position.x or nil),
      y = tonumber(type(p.position) == "table" and p.position.y or nil),
    }
    out[i] = res
  end
  return { results = out }
end

-- -------------------------------------------------------- describe_prototype

local function describe_entity(ent, item_name)
  local out = { kind = "entity", entity = ent.name }

  if not item_name then
    -- Which item places this entity (nice to know when the caller asked by
    -- entity name).
    local ok, items = pcall(function() return ent.items_to_place_this end)
    if ok and type(items) == "table" and type(items[1]) == "table" and items[1].name then
      item_name = items[1].name
    end
  end
  if item_name then out.placed_by_item = item_name end

  local ok, v

  ok, v = pcall(function() return ent.tile_width end)
  if ok and type(v) == "number" then out.tile_width = v end
  ok, v = pcall(function() return ent.tile_height end)
  if ok and type(v) == "number" then out.tile_height = v end

  -- Mining drills: where the ore comes out, at direction 0 (rotate with the
  -- entity — 4:(x,y)->(-y,x), 8:(-x,-y), 12:(y,-x)).
  ok, v = pcall(function() return ent.vector_to_place_result end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.drop_offset = offset end
  end

  local burner, electric
  ok, v = pcall(function() return ent.burner_prototype end)
  if ok then burner = v end
  ok, v = pcall(function() return ent.electric_energy_source_prototype end)
  if ok then electric = v end
  out.energy = (burner and "burner") or (electric and "electric") or "none"
  if burner then
    ok, v = pcall(function() return burner.fuel_categories end)
    if ok then out.fuel_categories = sorted_keys(v) end
    ok, v = pcall(function() return burner.effectivity end)
    if ok and type(v) == "number" then out.burner_effectivity = v end
    ok, v = pcall(function() return burner.fuel_inventory_size end)
    if ok and type(v) == "number" then out.fuel_inventory_size = v end
  end

  ok, v = pcall(function() return ent.mining_speed end)
  if ok and type(v) == "number" then out.mining_speed = v end
  ok, v = pcall(function() return ent.get_crafting_speed() end)
  if ok and type(v) == "number" then out.crafting_speed = v end
  ok, v = pcall(function() return ent.get_max_energy_usage() end)
  if ok and type(v) == "number" then out.max_energy_usage = v end
  ok, v = pcall(function() return ent.get_max_energy_production() end)
  if ok and type(v) == "number" then out.max_energy_production = v end

  ok, v = pcall(function() return ent.mineable_properties end)
  if ok and type(v) == "table" then
    if type(v.mining_time) == "number" then out.mining_time = v.mining_time end
    local products = {}
    for _, product in ipairs(v.products or {}) do
      if product.name then
        local amount = tonumber(product.amount)
        if amount == nil and product.amount_min == product.amount_max then amount = tonumber(product.amount_min) end
        if amount ~= nil and (product.probability == nil or product.probability == 1) then
          products[product.name] = (products[product.name] or 0) + amount
        end
      end
    end
    if next(products) ~= nil then out.mining_products = products end
  end

  local fuel_item = prototypes.item[item_name or ent.name]
  if fuel_item then
    ok, v = pcall(function() return fuel_item.fuel_value end)
    if ok and type(v) == "number" and v > 0 then out.fuel_value = v end
    ok, v = pcall(function() return fuel_item.fuel_category end)
    if ok and type(v) == "string" then out.fuel_category = v end
  end

  ok, v = pcall(function() return ent.crafting_categories end)
  if ok then out.crafting_categories = sorted_keys(v) end

  -- Gun range lives on the ITEM prototype; turrets carry theirs on the entity.
  if item_name then
    local it = prototypes.item[item_name]
    if it then
      ok, v = pcall(function() return it.attack_parameters end)
      if ok and type(v) == "table" and type(v.range) == "number" then out.range = v.range end
    end
  end
  if out.range == nil then
    ok, v = pcall(function() return ent.attack_parameters end)
    if ok and type(v) == "table" and type(v.range) == "number" then out.range = v.range end
  end

  ok, v = pcall(function() return ent.inserter_pickup_position end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.inserter_pickup_offset = offset end
  end
  ok, v = pcall(function() return ent.inserter_drop_position end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.inserter_drop_offset = offset end
  end

  ok, v = pcall(function() return ent.belt_speed end)
  if ok and type(v) == "number" then out.belt_speed = v end

  return out
end

local function describe_recipe(rec, force)
  local ingredients, products = {}, {}
  for _, ing in ipairs(rec.ingredients or {}) do
    if ing.name then
      ingredients[ing.name] = (ingredients[ing.name] or 0) + (ing.amount or 1)
    end
  end
  for _, p in ipairs(rec.products or {}) do
    if p.name then
      local amount = tonumber(p.amount)
      if amount == nil and p.amount_min == p.amount_max then amount = tonumber(p.amount_min) end
      if amount ~= nil and (p.probability == nil or p.probability == 1) then
        products[p.name] = (products[p.name] or 0) + amount
      end
    end
  end
  local force_recipe = force.recipes[rec.name]
  return {
    kind = "recipe",
    ingredients = ingredients,
    products = products,
    energy = rec.energy,
    category = rec.category,
    enabled = (force_recipe and force_recipe.enabled) or false,
  }
end

local function describe_item(item)
  local out = { kind = "item", item = item.name, stack_size = item.stack_size }
  local ok, value = pcall(function() return item.fuel_value end)
  if ok and type(value) == "number" and value > 0 then out.fuel_value = value end
  ok, value = pcall(function() return item.fuel_category end)
  if ok and type(value) == "string" then out.fuel_category = value end
  ok, value = pcall(function() return item.place_result end)
  if ok and value then out.place_result = value.name end
  return out
end

function M.describe_prototype(params)
  local names = params.names
  local kind = params.kind or "auto"
  if type(names) ~= "table" or #names == 0 then
    error('describe_prototype requires names = ["burner-mining-drill", ...]')
  end
  if #names > DESCRIBE_MAX_NAMES then
    error(string.format(
      "describe_prototype takes at most %d names per call — split the list and call again",
      DESCRIBE_MAX_NAMES))
  end
  if kind ~= "auto" and kind ~= "entity" and kind ~= "recipe" and kind ~= "item" then
    error("describe_prototype kind must be auto, entity, recipe, or item")
  end

  local force = companion.require_companion().force

  local out = {}
  for _, name in ipairs(names) do
    if type(name) == "string" then
      local item = prototypes.item[name]
      local placed = item and item.place_result
      local key = kind ~= "auto" and (kind .. ":" .. name) or name
      if kind == "recipe" and prototypes.recipe[name] then
        out[key] = describe_recipe(prototypes.recipe[name], force)
      elseif kind == "item" and item then
        out[key] = describe_item(item)
      elseif kind == "entity" and prototypes.entity[name] then
        out[key] = describe_entity(prototypes.entity[name], nil)
      elseif kind == "entity" and placed then
        out[key] = describe_entity(placed, name)
      elseif kind == "auto" and placed then
        out[key] = describe_entity(placed, name)
      elseif kind == "auto" and prototypes.entity[name] then
        out[key] = describe_entity(prototypes.entity[name], nil)
      elseif kind == "auto" and item then
        out[key] = describe_item(item)
      elseif kind == "auto" and prototypes.recipe[name] then
        out[key] = describe_recipe(prototypes.recipe[name], force)
      else
        out[key] = { kind = "unknown" }
      end
    end
  end
  return out
end

return M
