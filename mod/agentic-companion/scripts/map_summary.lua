-- Read-only summary of the force's already charted world. No chart or generation calls.
local companion = require("scripts.companion")

local M = {}
local MAX_EDGES = 256
local MAX_LANDMARKS = 256

local function charted(force, surface, pos)
  return force.is_chunk_charted(surface, { x = math.floor(pos.x / 32), y = math.floor(pos.y / 32) })
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

local function status_name(entity)
  local ok, status = pcall(function() return entity.status end)
  if not ok or status == nil then return nil end
  for name, value in pairs((defines and defines.entity_status) or {}) do if value == status then return name end end
  return tostring(status)
end

local function recipe_name(entity)
  local ok, recipe = pcall(function() return entity.get_recipe and entity.get_recipe() end)
  if ok and recipe then return recipe.name end
  return nil
end

local function key_position(a, b)
  if a.position.y ~= b.position.y then return a.position.y < b.position.y end
  if a.position.x ~= b.position.x then return a.position.x < b.position.x end
  if a.name ~= b.name then return a.name < b.name end
  return a.type < b.type
end

function M.map_summary(_params)
  local c = companion.require_companion()
  local chunks = {}
  for chunk in c.force.get_charted_chunks(c.surface) do chunks[#chunks + 1] = { x = chunk.x, y = chunk.y } end
  table.sort(chunks, function(a, b) return a.y == b.y and a.x < b.x or a.y < b.y end)

  local resources_by_name, landmarks, seen_landmark, seen_resource, water_edges, seen_edge = {}, {}, {}, {}, {}, {}
  for _, chunk in ipairs(chunks) do
    local x0, y0 = chunk.x * 32, chunk.y * 32
    local area = { { x0, y0 }, { x0 + 32, y0 + 32 } }
    for _, entity in ipairs(c.surface.find_entities_filtered({ area = area, type = "resource" })) do
      local resource_key = entity.valid and charted(c.force, c.surface, entity.position)
        and string.format("%s\0%.17g\0%.17g", entity.name, entity.position.x, entity.position.y) or nil
      if resource_key and not seen_resource[resource_key] then
        seen_resource[resource_key] = true
        local row = resources_by_name[entity.name] or { name = entity.name, entity_count = 0, total_amount = 0, nearest = nil, observed_tick = game.tick, _distance = nil }
        resources_by_name[entity.name] = row
        row.entity_count = row.entity_count + 1
        row.total_amount = row.total_amount + (tonumber(entity.amount) or 0)
        local dx, dy = entity.position.x - c.position.x, entity.position.y - c.position.y
        local distance = dx * dx + dy * dy
        if row._distance == nil or distance < row._distance
          or (distance == row._distance and (entity.position.y < row.nearest.y
            or (entity.position.y == row.nearest.y and entity.position.x < row.nearest.x))) then
          row._distance = distance
          row.nearest = { x = entity.position.x, y = entity.position.y }
        end
      end
    end
    for _, entity in ipairs(c.surface.find_entities_filtered({ area = area, force = c.force })) do
      if entity.valid and charted(c.force, c.surface, entity.position)
        and entity ~= c and entity.type ~= "character" and entity.type ~= "entity-ghost" then
        local key = string.format("%s\0%s\0%.17g\0%.17g", entity.name, entity.type, entity.position.x, entity.position.y)
        if not seen_landmark[key] then
          seen_landmark[key] = true
          landmarks[#landmarks + 1] = {
            name = entity.name, type = entity.type,
            position = { x = entity.position.x, y = entity.position.y },
            direction = entity.direction, status = status_name(entity), recipe = recipe_name(entity),
            observed_tick = game.tick,
          }
        end
      end
    end
    for y = y0, y0 + 31 do
      for x = x0, x0 + 31 do
        local current = is_water(c.surface, x, y)
        for _, delta in ipairs({ { 1, 0 }, { 0, 1 } }) do
          local nx, ny = x + delta[1], y + delta[2]
          local neighbor_chunk = { x = math.floor(nx / 32), y = math.floor(ny / 32) }
          if c.force.is_chunk_charted(c.surface, neighbor_chunk) then
            local neighbor = is_water(c.surface, nx, ny)
            if current ~= neighbor then
              local land = current and { x = nx, y = ny } or { x = x, y = y }
              local water = current and { x = x, y = y } or { x = nx, y = ny }
              local edge_key = string.format("%d,%d:%d,%d", land.x, land.y, water.x, water.y)
              if not seen_edge[edge_key] then
                seen_edge[edge_key] = true
                water_edges[#water_edges + 1] = { land = land, water = water, observed_tick = game.tick }
              end
            end
          end
        end
      end
    end
  end

  local resources = {}; for _, row in pairs(resources_by_name) do row._distance = nil; resources[#resources + 1] = row end
  table.sort(resources, function(a, b) return a.name < b.name end)
  table.sort(landmarks, key_position)
  table.sort(water_edges, function(a, b)
    if a.land.y ~= b.land.y then return a.land.y < b.land.y end
    if a.land.x ~= b.land.x then return a.land.x < b.land.x end
    if a.water.y ~= b.water.y then return a.water.y < b.water.y end
    return a.water.x < b.water.x
  end)
  local omitted_water_edges = math.max(0, #water_edges - MAX_EDGES)
  local omitted_factory_landmarks = math.max(0, #landmarks - MAX_LANDMARKS)
  while #water_edges > MAX_EDGES do table.remove(water_edges) end
  while #landmarks > MAX_LANDMARKS do table.remove(landmarks) end
  return {
    tick = game.tick, charted_chunks = #chunks, resources = resources,
    water_edges = water_edges, omitted_water_edges = omitted_water_edges,
    factory_landmarks = landmarks, omitted_factory_landmarks = omitted_factory_landmarks,
  }
end

return M
