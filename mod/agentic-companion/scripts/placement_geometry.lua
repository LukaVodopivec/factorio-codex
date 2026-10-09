-- Shared collision geometry for every placement surface and path-start check.
local M = {}

local function xy(value)
  if type(value) ~= "table" then return nil end
  local x, y = tonumber(value.x) or tonumber(value[1]), tonumber(value.y) or tonumber(value[2])
  if x == nil or y == nil then return nil end
  return { x = x, y = y }
end

function M.footprint(proto, position, direction)
  local box = proto and proto.collision_box
  local lt = box and xy(box.left_top) or { x = -0.1, y = -0.1 }
  local rb = box and xy(box.right_bottom) or { x = 0.1, y = 0.1 }
  direction = math.floor(tonumber(direction) or 0) % 16
  -- Cardinal rotations are exact axis swaps; only diagonal directions need trig.
  if direction == 4 then
    lt, rb = { x = -rb.y, y = lt.x }, { x = -lt.y, y = rb.x }
  elseif direction == 8 then
    lt, rb = { x = -rb.x, y = -rb.y }, { x = -lt.x, y = -lt.y }
  elseif direction == 12 then
    lt, rb = { x = lt.y, y = -rb.x }, { x = rb.y, y = -lt.x }
  elseif direction ~= 0 then
    local angle = direction * math.pi / 8
    local cosine, sine = math.cos(angle), math.sin(angle)
    local min_x, min_y, max_x, max_y
    for _, point in ipairs({
      { x = lt.x, y = lt.y }, { x = rb.x, y = lt.y },
      { x = lt.x, y = rb.y }, { x = rb.x, y = rb.y },
    }) do
      local x, y = point.x * cosine - point.y * sine, point.x * sine + point.y * cosine
      min_x, max_x = math.min(min_x or x, x), math.max(max_x or x, x)
      min_y, max_y = math.min(min_y or y, y), math.max(max_y or y, y)
    end
    lt, rb = { x = min_x, y = min_y }, { x = max_x, y = max_y }
  end
  return {
    left_top = { x = position.x + math.min(lt.x, rb.x), y = position.y + math.min(lt.y, rb.y) },
    right_bottom = { x = position.x + math.max(lt.x, rb.x), y = position.y + math.max(lt.y, rb.y) },
  }
end

-- Entity types that never stop a building from being placed.
M.NON_BLOCKING_TYPES = { character = true, resource = true, ["item-entity"] = true, fish = true,
  corpse = true, ["character-corpse"] = true, ["entity-ghost"] = true, ["tile-ghost"] = true,
  ["deconstructible-tile-proxy"] = true, ["item-request-proxy"] = true }

-- A coordinate as text that reads back as the same number (positions are
-- multiples of 1/256), so a message's position can be targeted exactly.
function M.exact(n)
  local text = string.format("%.15g", n)
  if tonumber(text) ~= n then text = string.format("%.17g", n) end
  return text
end

-- {name, count, position} of an item stack lying on the ground
-- (item-entity), or nil for anything else.
function M.ground_item_row(e)
  if not (e and e.valid and e.type == "item-entity") then return nil end
  local ok, name, count = pcall(function()
    local stack = e.stack
    if stack and stack.valid_for_read then return stack.name, stack.count end
  end)
  if not (ok and name) then return nil end
  return { name = name, count = count, position = { x = e.position.x, y = e.position.y } }
end

-- Up to `limit` item stacks lying on the ground over an area, in one engine
-- query: their rows, and the entities in the same order.
function M.ground_items(surface, area, limit)
  local rows, entities = {}, {}
  local ok, found = pcall(surface.find_entities_filtered, { area = area, type = "item-entity", limit = limit })
  for _, e in ipairs(ok and type(found) == "table" and found or {}) do
    local row = M.ground_item_row(e)
    if row then rows[#rows + 1], entities[#entities + 1] = row, e end
  end
  return rows, entities
end

-- "item-on-ground iron-plate x3 at (4.5, -41.65234375)": exact, as
-- pickup_items matches it.
function M.ground_item_text(row)
  return string.format("item-on-ground %s x%d at (%s, %s)", row.name, row.count,
    M.exact(row.position.x), M.exact(row.position.y))
end

function M.overlaps(a, b)
  return a and b and a.left_top and a.right_bottom and b.left_top and b.right_bottom
    and a.left_top.x < b.right_bottom.x and a.right_bottom.x > b.left_top.x
    and a.left_top.y < b.right_bottom.y and a.right_bottom.y > b.left_top.y
end

-- Factorio refuses a placement whose box only touches another box, edge on
-- edge; a strict overlap misses those, so blocker searches grow by a hair.
function M.touching(area)
  local m = 0.005
  return { left_top = { x = area.left_top.x - m, y = area.left_top.y - m },
    right_bottom = { x = area.right_bottom.x + m, y = area.right_bottom.y + m } }
end

-- Everything the engine's placement check reads: the footprint plus each
-- tile_buildability_rules area turned the same way (an offshore pump's
-- water lies tiles behind its box), so a chart check covers it all.
function M.placement_area(proto, position, direction)
  local area = M.footprint(proto, position, direction)
  local ok, rules = pcall(function() return proto.tile_buildability_rules end)
  for _, rule in ipairs(ok and type(rules) == "table" and rules or {}) do
    local box = type(rule) == "table" and type(rule.area) == "table" and rule.area or nil
    local lt, rb = box and xy(box.left_top or box[1]), box and xy(box.right_bottom or box[2])
    if lt and rb then
      local r = M.footprint({ collision_box = { left_top = lt, right_bottom = rb } }, position, direction)
      area.left_top.x, area.left_top.y = math.min(area.left_top.x, r.left_top.x), math.min(area.left_top.y, r.left_top.y)
      area.right_bottom.x = math.max(area.right_bottom.x, r.right_bottom.x)
      area.right_bottom.y = math.max(area.right_bottom.y, r.right_bottom.y)
    end
  end
  return area
end

-- How many tiles an area touches: one ore entity each at most, which a
-- capped blocker search adds to its limit so ore never crowds a blocker out.
function M.tile_count(area)
  return (math.ceil(area.right_bottom.x) - math.floor(area.left_top.x))
    * (math.ceil(area.right_bottom.y) - math.floor(area.left_top.y))
end

-- The fluids a plain pipe would join: the game refuses a pipe that free
-- neighbouring pipe connections of different fluids point into (a pipe
-- connects on all four sides; other fluid entities only where their own
-- connections are, so they are left out). Returns two or more sorted fluid
-- names, or nil. Reads at most 16 non-ore entities within a tile and a half.
local PLAIN_PIPES = { pipe = true, ["infinity-pipe"] = true }
function M.fluid_mix(surface, proto, position, direction)
  if not (proto and PLAIN_PIPES[proto.type]) then return nil end
  local area = M.footprint(proto, position, direction)
  local lt, rb = area.left_top, area.right_bottom
  local ok, found = pcall(surface.find_entities_filtered, { area = { left_top = { x = lt.x - 1.5, y = lt.y - 1.5 },
    right_bottom = { x = rb.x + 1.5, y = rb.y + 1.5 } }, type = "resource", invert = true, limit = 16 })
  if not ok then return nil end
  local fluids, names = {}, {}
  for _, e in ipairs(found) do
    local fb = e.valid and e.fluidbox
    for i = 1, (fb and #fb or 0) do
      local fluid = fb[i] and fb[i].name
      local got, connections = pcall(fb.get_pipe_connections, i)
      if fluid and not fluids[fluid] and got then
        for _, connection in ipairs(connections) do
          local t = connection.target_position
          if connection.connection_type == "normal" and connection.target == nil
            and t and t.x > lt.x and t.x < rb.x and t.y > lt.y and t.y < rb.y then
            fluids[fluid] = true
            names[#names + 1] = fluid
            break
          end
        end
      end
    end
  end
  if #names < 2 then return nil end
  table.sort(names)
  return names
end

function M.fluid_mix_reason(fluids)
  return string.format("it would join %s pipes, and fluids never mix — route around them or pass under with pipe-to-ground",
    table.concat(fluids, " and "))
end

function M.character_box(c)
  if c.bounding_box and c.bounding_box.left_top then return c.bounding_box end
  local proto = c.prototype or (prototypes and prototypes.entity and prototypes.entity[c.name or "character"])
  return proto and M.footprint(proto, c.position, 0) or nil
end

-- Belts never collide with the character but carry it while it stands still.
M.CONVEYOR_TYPES = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
  ["lane-splitter"] = true, loader = true, ["loader-1x1"] = true, ["linked-belt"] = true }
local CONVEYOR_FILTER = {}
for name in pairs(M.CONVEYOR_TYPES) do CONVEYOR_FILTER[#CONVEYOR_FILTER + 1] = name end
table.sort(CONVEYOR_FILTER)

-- First conveyor whose box overlaps `box` (default: the body's box), or nil.
function M.conveyor_under(c, box)
  box = box or M.character_box(c)
  if not box then return nil end
  local ok, found = pcall(c.surface.find_entities_filtered, { area = box, type = CONVEYOR_FILTER })
  if not ok or type(found) ~= "table" then return nil end
  for _, entity in ipairs(found) do
    if entity.valid and M.CONVEYOR_TYPES[entity.type]
      and (not entity.bounding_box or M.overlaps(box, entity.bounding_box)) then
      return entity
    end
  end
  return nil
end

function M.overlaps_character(c, proto, position, direction)
  return M.overlaps(M.footprint(proto, position, direction), M.character_box(c))
end

function M.can_place(c, proto, position, direction)
  local area = M.footprint(proto, position, direction)
  if M.overlaps(area, M.character_box(c)) then return false, "CODEX_BODY_OVERLAP", area, 0 end
  local params = {
    name = proto.name, position = position, direction = direction or 0, force = c.force,
    build_check_type = defines.build_check_type.manual,
  }
  local ok = c.surface.can_place_entity(params)
  local checks = 1
  -- Manual checks permit fast replacement (e.g. underground belt over belt),
  -- but our physical create_entity never replaces existing entities. Require
  -- revival clearance too; script checks alone allow non-manual overlaps.
  if ok then
    params.build_check_type = defines.build_check_type.ghost_revive
    ok = c.surface.can_place_entity(params)
    checks = 2
  end
  return ok, ok and "placeable" or "blocked", area, checks
end

-- ---------------------------------------------------------------- liquids
-- One liquid check for every placement and walking test: a tile is liquid
-- when it collides with the water_tile layer (water, deep water, lava, oil
-- ocean, ammoniacal ocean, wetlands); its fluid is the tile prototype's
-- (water, lava, heavy-oil, ammoniacal-solution) and it is walkable when it
-- does not collide with the player layer (oil ocean, shallow water and
-- wetlands are; lava, deep water and the ammoniacal ocean are not).
local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

-- Whether the tile is liquid: two engine reads (get_tile, collides_with).
function M.is_liquid(surface, x, y)
  local tile = read(function() return surface.get_tile(x, y) end)
  return tile ~= nil and read(function() return tile.collides_with("water_tile") end) == true
end

-- {fluid, walkable} of a liquid tile, else nil.
function M.tile_liquid(tile)
  if not tile or read(function() return tile.collides_with("water_tile") end) ~= true then return nil end
  return { fluid = read(function() return tile.prototype.fluid.name end),
    walkable = read(function() return tile.collides_with("player") end) == false }
end

-- {fluid, walkable} of the tile at (x, y), else nil (land, or unreadable).
function M.liquid_at(surface, x, y)
  return M.tile_liquid(read(function() return surface.get_tile(x, y) end))
end

-- The fluid an offshore pump at this spot and direction pumps: the liquid
-- under position + its prototype's fluid_source_offset turned to direction;
-- nil for another entity or no liquid there.
function M.pumped_fluid(surface, proto, position, direction)
  local offset = read(function() return proto.fluid_source_offset end)
  local x, y = offset and (tonumber(offset.x) or tonumber(offset[1])), offset and (tonumber(offset.y) or tonumber(offset[2]))
  if not (x and y) then return nil end
  local angle = (math.floor(tonumber(direction) or 0) % 16) * math.pi / 8
  local cosine, sine = math.floor(math.cos(angle) * 1e6 + 0.5) / 1e6, math.floor(math.sin(angle) * 1e6 + 0.5) / 1e6
  local tx, ty = position.x + x * cosine - y * sine, position.y + x * sine + y * cosine
  local liquid = M.liquid_at(surface, math.floor(tx), math.floor(ty))
  return liquid and liquid.fluid
end

-- --------------------------------------------------------- surface conditions
-- The first of a prototype's surface_conditions the surface breaks:
-- {property, value, min?, max?}, else nil. A property the surface does not
-- set reads as its prototype default (LuaSurface.get_property).
function M.surface_condition(surface, conditions)
  for _, condition in ipairs(conditions or {}) do
    local value = read(function() return surface.get_property(condition.property) end)
    if type(value) == "number" and ((condition.min and value < condition.min) or (condition.max and value > condition.max)) then
      return { property = condition.property, value = value, min = condition.min, max = condition.max }
    end
  end
  return nil
end

-- The SURFACE_CONDITION text of a broken condition.
function M.condition_text(name, broken)
  local range = broken.min and broken.max and broken.min == broken.max and ("= " .. broken.min)
    or broken.min and broken.max and (broken.min .. "-" .. broken.max)
    or broken.min and (">= " .. broken.min) or ("<= " .. tostring(broken.max))
  return string.format("SURFACE_CONDITION: %s needs %s %s; this surface has %s", name, broken.property, range,
    tostring(broken.value))
end

-- Surface conditions of an entity or recipe prototype by name, read once per
-- load (prototypes change only with a configuration change); false when it
-- has none.
local conditions_cache = { entity = {}, recipe = {} }
local function conditions_of(kind, name)
  if type(name) ~= "string" then return nil end
  local known = conditions_cache[kind][name]
  if known == nil then
    local conditions = read(function() return prototypes[kind][name].surface_conditions end)
    known = type(conditions) == "table" and #conditions > 0 and conditions or false
    conditions_cache[kind][name] = known
  end
  return known or nil
end

-- The SURFACE_CONDITION refusal of building an entity, setting a recipe or
-- hand-crafting it (kind "entity" or "recipe") on a surface:
-- {code, reason, condition} when the surface breaks one of its conditions,
-- else nil. Only a prototype with conditions reads the surface.
function M.condition_refusal(surface, kind, name)
  local conditions = conditions_of(kind, name)
  local broken = conditions and surface and M.surface_condition(surface, conditions)
  if not broken then return nil end
  return { code = "SURFACE_CONDITION", reason = M.condition_text(name, broken), condition = broken }
end

-- Factorio 2.0 CollisionMask semantics. Selection boxes never prove collision.
local function mask_overlap(a, b, tile)
  if not a or not b or type(a.layers) ~= "table" or type(b.layers) ~= "table" then return nil end
  if not tile then
    if a.colliding_with_tiles_only or b.colliding_with_tiles_only then return false end
    if a.not_colliding_with_itself and b.not_colliding_with_itself then
      local equal = true
      for layer in pairs(a.layers) do if not b.layers[layer] then equal = false end end
      for layer in pairs(b.layers) do if not a.layers[layer] then equal = false end end
      if equal then return false end
    end
  end
  for layer in pairs(a.layers) do if b.layers[layer] then return true end end
  return false
end
-- Whether two CollisionMasks collide (entity against entity, or tile with
-- `tile`); nil when either mask is unknown.
M.mask_overlap = mask_overlap

-- Whether a tile the footprint covers collides with proto's mask (water and
-- the like; an unknown mask meets water): one tile query over the covered
-- tiles, one mask read per tile name.
function M.tiles_refuse(surface, proto, area)
  local mask_ok, mask = pcall(function() return proto.collision_mask end)
  local tile_mask = mask_ok and type(mask) == "table" and mask or { layers = { water_tile = true } }
  local tiles = { left_top = { x = math.floor(area.left_top.x), y = math.floor(area.left_top.y) },
    right_bottom = { x = math.ceil(area.right_bottom.x), y = math.ceil(area.right_bottom.y) } }
  local ok, found = pcall(surface.find_tiles_filtered, { area = tiles, limit = M.tile_count(tiles) })
  local meets = {}
  for _, tile in ipairs(ok and found or {}) do
    local name_ok, name = pcall(function() return tile.name end)
    local key = name_ok and name or tile
    if meets[key] == nil then
      local tile_ok, other = pcall(function() return tile.prototype.collision_mask end)
      meets[key] = mask_overlap(tile_mask, tile_ok and other or nil, true) == true
    end
    if meets[key] then return true end
  end
  return false
end

-- Why proto cannot stand at position for a reason of its own, whatever item
-- stacks lie there (the build takes those up first): a surface condition it
-- breaks, a mining drill with no resource it mines in its mining area (the
-- game places a drill when ore lies anywhere there; `found`, the entities
-- read over its footprint, when its radius is unknown), an offshore pump
-- with no liquid at its source. nil when none applies.
function M.proto_refusal(surface, proto, position, direction, found)
  local condition = M.condition_refusal(surface, "entity", proto.name)
  if condition then return condition.reason end
  if proto.type == "mining-drill" then
    local categories = read(function() return proto.resource_categories end)
    -- One bounded read: a drill's area is a few tiles across.
    local radius = tonumber(read(function() return proto.mining_drill_radius end))
    if radius and radius > 0 and type(position) == "table" then
      local ok, ores = pcall(surface.find_entities_filtered, { type = "resource",
        area = { left_top = { x = position.x - radius, y = position.y - radius },
          right_bottom = { x = position.x + radius, y = position.y + radius } } })
      if ok then found = ores end
    end
    for _, e in ipairs(found or {}) do
      if e.valid and e.type == "resource" then
        local category = read(function() return e.prototype.resource_category end)
        if type(categories) ~= "table" or category == nil or categories[category] then return nil end
      end
    end
    return "no resource it can mine under it"
  end
  if proto.type == "offshore-pump" and not M.pumped_fluid(surface, proto, position, direction) then
    return "it needs a land tile with water behind it"
  end
  return nil
end

function M.path_start(c)
  local result = { clear = false, state = "unknown", collisions = {} }
  local reasons = {}
  local function unknown(reason) reasons[reason] = true end
  local proto = c.prototype or (prototypes and prototypes.entity and prototypes.entity[c.name or "character"])
  local mask = proto and proto.collision_mask
  local box = c.bounding_box or (proto and proto.collision_box)
  if not box or not xy(box.left_top) or not xy(box.right_bottom)
    or not mask or type(mask.layers) ~= "table" then
    result.reason = "character collision geometry or mask unavailable"
    return result
  end
  local area = c.bounding_box or M.footprint(proto, c.position, 0)
  -- Bound both the engine query and the evidence. An unsupported large body
  -- or truncated query is uncertainty, never a claim of clearance.
  if area.right_bottom.x - area.left_top.x > 8 or area.right_bottom.y - area.left_top.y > 8 then
    result.reason = "character collision footprint exceeds local evidence bound"
    return result
  end
  if c.force.is_chunk_charted then
    for _, point in ipairs({ area.left_top,
      { x = area.right_bottom.x - 0.001, y = area.left_top.y },
      { x = area.left_top.x, y = area.right_bottom.y - 0.001 },
      { x = area.right_bottom.x - 0.001, y = area.right_bottom.y - 0.001 } }) do
      local chart_ok, charted = pcall(c.force.is_chunk_charted, c.surface,
        { x = math.floor(point.x / 32), y = math.floor(point.y / 32) })
      if not chart_ok or not charted then
        result.reason = "character collision footprint crosses uncharted or unavailable terrain"
        return result
      end
    end
  end
  local ok, entities = pcall(c.surface.find_entities_filtered, { area = area, limit = 65 })
  if not ok or type(entities) ~= "table" then
    unknown("entity collision query failed")
  else
    if #entities >= 65 then
      unknown("entity collision query reached local evidence bound")
      entities = {} -- A truncated engine subset cannot supply stable entity evidence.
    end
    for _, entity in ipairs(entities) do
      if entity.valid and entity ~= c then
        local entity_proto = entity.prototype or (prototypes and prototypes.entity and prototypes.entity[entity.name])
        local collides = mask_overlap(mask, entity_proto and entity_proto.collision_mask, false)
        if collides == nil then
          unknown("entity collision mask unavailable")
        elseif collides then
          local box = entity.bounding_box
          if not box or not xy(box.left_top) or not xy(box.right_bottom) then
            unknown("entity collision geometry unavailable")
          elseif M.overlaps(area, box) then
            -- Gates have a runtime mask; diagonal bounding boxes can enclose
            -- space outside the rotated collision shape. Neither proves overlap.
            if entity.type == "gate" or (entity.direction and entity.direction % 4 ~= 0)
              or (entity.orientation and (entity.orientation * 4) % 1 ~= 0) then
              unknown("runtime collision shape unsupported")
            else
              result.collisions[#result.collisions + 1] = { kind = "entity", name = entity.name, type = entity.type,
                position = { x = entity.position.x, y = entity.position.y } }
            end
          end
        end
      end
    end
  end
  local left, right = math.floor(area.left_top.x), math.ceil(area.right_bottom.x) - 1
  local top, bottom = math.floor(area.left_top.y), math.ceil(area.right_bottom.y) - 1
  if mask.consider_tile_transitions then
    left, right = math.floor(c.position.x), math.floor(c.position.x)
    top, bottom = math.floor(c.position.y), math.floor(c.position.y)
  end
  for y = top, bottom do
    for x = left, right do
      local tile_ok, tile = pcall(c.surface.get_tile, x, y)
      local collides
      if tile_ok and tile then
        -- LuaTile.collides_with accepts one layer. Keep the pcall's two
        -- results separate: boolean expressions discard additional Lua returns.
        collides = false
        for layer in pairs(mask.layers) do
          local collision_ok, value = pcall(tile.collides_with, layer)
          if not collision_ok or type(value) ~= "boolean" then
            unknown("tile collision query failed")
          elseif value then collides = true end
        end
      else unknown("tile query failed") end
      if collides then
        result.collisions[#result.collisions + 1] = { kind = "tile", name = tile.name,
          position = { x = x, y = y } }
      end
    end
  end
  table.sort(result.collisions, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    if a.name ~= b.name then return a.name < b.name end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return a.position.x < b.position.x
  end)
  if #result.collisions > 16 then
    result.omitted_collisions = #result.collisions - 16
    while #result.collisions > 16 do table.remove(result.collisions) end
  end
  local ordered = {}
  for reason in pairs(reasons) do ordered[#ordered + 1] = reason end
  table.sort(ordered)
  result.reason = #ordered > 0 and table.concat(ordered, "; ") or nil
  result.state = #result.collisions > 0 and "blocked" or (#ordered > 0 and "unknown" or "clear")
  result.clear = result.state == "clear"
  return result
end

return M
