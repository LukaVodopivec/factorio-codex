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
  local proto = prototypes and prototypes.entity and prototypes.entity[c.name or "character"]
  return proto and M.footprint(proto, c.position, 0) or nil
end

function M.overlaps_character(c, proto, position, direction)
  return M.overlaps(M.footprint(proto, position, direction), M.character_box(c))
end

function M.can_place(c, proto, position, direction)
  local area = M.footprint(proto, position, direction)
  if M.overlaps(area, M.character_box(c)) then return false, "CODEX_BODY_OVERLAP", area end
  local ok = c.surface.can_place_entity({
    name = proto.name, position = position, direction = direction or 0, force = c.force,
    build_check_type = defines.build_check_type.manual,
  })
  return ok, ok and "placeable" or "blocked", area
end

function M.start_collisions(c)
  -- Real LuaControl objects expose an authoritative bounding box. Lightweight
  -- unit fixtures that omit both it and the prototype collision box cannot
  -- support a truthful start-overlap check, so leave that branch unknown.
  local character_proto = prototypes and prototypes.entity and prototypes.entity[c.name or "character"]
  if not (c.bounding_box and c.bounding_box.left_top)
    and not (character_proto and character_proto.collision_box) then
    return {}
  end
  local area, collisions = M.character_box(c), {}
  if not area then return collisions end
  local ok, entities = pcall(c.surface.find_entities_filtered, { area = area })
  if ok then
    for _, entity in ipairs(entities or {}) do
      if entity.valid and entity ~= c and entity.type ~= "resource" and entity.type ~= "item-entity" then
        local box = entity.bounding_box or entity.selection_box
        if not box or M.overlaps(area, box) then
          collisions[#collisions + 1] = { kind = "entity", name = entity.name, type = entity.type,
            position = { x = entity.position.x, y = entity.position.y } }
        end
      end
    end
  end
  local corners = { area.left_top,
    { x = area.right_bottom.x - 0.001, y = area.left_top.y },
    { x = area.left_top.x, y = area.right_bottom.y - 0.001 },
    { x = area.right_bottom.x - 0.001, y = area.right_bottom.y - 0.001 } }
  local seen = {}
  for _, corner in ipairs(corners) do
    local tile_ok, tile = pcall(c.surface.get_tile, corner.x, corner.y)
    local collision_ok, collides = tile_ok and tile and pcall(tile.collides_with, "player")
    if collision_ok and collides then
      local key = math.floor(corner.x) .. ":" .. math.floor(corner.y)
      if not seen[key] then
        seen[key] = true
        collisions[#collisions + 1] = { kind = "tile", name = tile.name or "collision-tile",
          position = { x = math.floor(corner.x), y = math.floor(corner.y) } }
      end
    end
  end
  table.sort(collisions, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    if a.name ~= b.name then return a.name < b.name end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return a.position.x < b.position.x
  end)
  return collisions
end

return M
