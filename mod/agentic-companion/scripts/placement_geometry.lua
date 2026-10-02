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

function M.overlaps(a, b)
  return a and b and a.left_top and a.right_bottom and b.left_top and b.right_bottom
    and a.left_top.x < b.right_bottom.x and a.right_bottom.x > b.left_top.x
    and a.left_top.y < b.right_bottom.y and a.right_bottom.y > b.left_top.y
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
