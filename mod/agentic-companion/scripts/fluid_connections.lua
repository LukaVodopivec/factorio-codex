-- Stable world-space fluid connection facts for live entities and candidates.
local M = {}

local function vec(value)
  if type(value) ~= "table" then return nil end
  local x, y = tonumber(value.x) or tonumber(value[1]), tonumber(value.y) or tonumber(value[2])
  if x == nil or y == nil then return nil end
  return { x = x, y = y }
end

local function filter_name(value)
  if type(value) == "string" then return value end
  local ok, name = pcall(function() return value and value.name end)
  return ok and name or nil
end

function M.prototype(proto, position, direction)
  local rows = {}
  direction = math.floor(tonumber(direction) or 0) % 16
  if direction % 4 ~= 0 then return rows end
  local direction_index = direction / 4 + 1
  local ok, boxes = pcall(function() return proto.fluidbox_prototypes end)
  if not ok or type(boxes) ~= "table" then return rows end
  for index, box in pairs(boxes) do
    local connections_ok, connections = pcall(function() return box.pipe_connections end)
    if connections_ok then
      for _, connection in ipairs(connections or {}) do
        local relative = vec(connection.positions and connection.positions[direction_index])
        if relative then
          rows[#rows + 1] = { fluidbox_index = tonumber(box.index) or tonumber(index),
            production_type = box.production_type, filter = filter_name(box.filter),
            connection_type = connection.connection_type,
            position = { x = position.x + relative.x, y = position.y + relative.y } }
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    return (a.fluidbox_index or 0) < (b.fluidbox_index or 0)
  end)
  return rows
end

function M.live(entity)
  local rows, count = {}, 0
  local count_ok = pcall(function() count = #entity.fluidbox end)
  if not count_ok then return rows end
  for index = 1, count do
    local proto_ok, box = pcall(function() return entity.get_fluid_box_prototype(index) end)
    local ok, connections = pcall(function() return entity.fluidbox.get_pipe_connections(index) end)
    if ok then
      for _, connection in ipairs(connections or {}) do
        local position, target_position = vec(connection.position), vec(connection.target_position)
        if position and target_position and connection.connection_type ~= "linked" then
          local target
          pcall(function()
            local owner = connection.target and connection.target.owner
            if owner and owner.valid then target = { name = owner.name, type = owner.type,
              position = { x = owner.position.x, y = owner.position.y } } end
          end)
          rows[#rows + 1] = { fluidbox_index = index,
            production_type = proto_ok and box and box.production_type or nil,
            filter = proto_ok and box and filter_name(box.filter) or nil,
            connection_type = connection.connection_type, flow_direction = connection.flow_direction,
            position = position, target_position = target_position, connected_target = target or false }
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    return a.fluidbox_index < b.fluidbox_index
  end)
  return rows
end

return M
