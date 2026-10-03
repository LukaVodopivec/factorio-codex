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

-- Merged crafting-machine boxes return an array, not one authoritative
-- prototype. Until supported, refuse it rather than choosing a member.
local function live_prototype(entity, index)
  local ok, box = pcall(function()
    local proto = entity.fluidbox.get_prototype(index)
    if type(proto) == "table" and rawget(proto, 1) ~= nil then error("merged fluidbox prototype") end
    if not proto or type(proto.production_type) ~= "string" then error("unreadable fluidbox prototype") end
    local filter = proto.filter
    local name = filter and (type(filter) == "string" and filter or filter.name)
    if filter and type(name) ~= "string" then error("unreadable fluidbox filter") end
    return { production_type = proto.production_type, filter = name,
      minimum_temperature = proto.minimum_temperature, maximum_temperature = proto.maximum_temperature }
  end)
  return ok and box or nil
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
      for connection_index, connection in ipairs(connections or {}) do
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

function M.live(entity, internal)
  local rows, count, complete = {}, 0, true
  local count_ok = pcall(function() count = #entity.fluidbox end)
  if not count_ok then return rows, false end
  for index = 1, count do
    local box = live_prototype(entity, index)
    if not box then complete = false end
    local ok, connections = pcall(function() return entity.fluidbox.get_pipe_connections(index) end)
    if ok then
      for connection_index, connection in ipairs(connections or {}) do
        local position, target_position = vec(connection.position), vec(connection.target_position)
        if position and target_position and connection.connection_type ~= "linked" then
          local target, target_entity
          pcall(function()
            local owner = connection.target and connection.target.owner
            if owner and owner.valid then
              target_entity = owner
              target = { name = owner.name, type = owner.type,
                position = { x = owner.position.x, y = owner.position.y } }
            end
          end)
          rows[#rows + 1] = { fluidbox_index = index,
            production_type = box and box.production_type or nil,
            filter = box and box.filter or nil,
            connection_type = connection.connection_type, flow_direction = connection.flow_direction,
            position = position, target_position = target_position, connected_target = target or false }
          if internal then
            if connection.target and not target_entity then complete = false end
            local row = rows[#rows]
            row._pipe_connection_index = connection_index
            row._target_entity, row._target_fluidbox_index = target_entity, connection.target_fluidbox_index
            row._target_pipe_connection_index = connection.target_pipe_connection_index
          end
        elseif internal then
          complete = false
        end
      end
    else
      complete = false
    end
  end
  table.sort(rows, function(a, b)
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    return a.fluidbox_index < b.fluidbox_index
  end)
  return rows, complete
end

-- Private component samples only. In 2.0 these are segment capacities and
-- runtime filters, not recipe ingredients or identities inferred from stock.
-- A merged/unsupported prototype or an unreadable field refuses the sample.
function M.sample(entity)
  local ok, rows = pcall(function()
    local boxes = {}
    for index = 1, #entity.fluidbox do
      local proto = live_prototype(entity, index)
      if not proto then error("unsupported fluidbox prototype") end
      local filter = entity.fluidbox.get_filter(index)
      local capacity = entity.fluidbox.get_capacity(index)
      local fluid = entity.fluidbox[index]
      local segment = entity.fluidbox.get_fluid_segment_id(index)
      local contents = entity.fluidbox.get_fluid_segment_contents(index)
      if type(contents) ~= "table" then error("unreadable fluid segment stock") end
      local segment_name, segment_amount = nil, 0
      for name, amount in pairs(contents) do
        if segment_name or type(name) ~= "string" or type(amount) ~= "number" then error("ambiguous fluid segment") end
        segment_name, segment_amount = name, amount
      end
      if fluid and segment_name ~= fluid.name then error("inconsistent fluid segment identity") end
      if type(capacity) ~= "number" or capacity <= 0 or type(segment) ~= "number" then error("unreadable fluid segment") end
      if fluid and (type(fluid.name) ~= "string" or type(fluid.amount) ~= "number"
        or type(fluid.temperature) ~= "number") then error("unreadable fluid") end
      boxes[index] = { index = index, production_type = proto.production_type,
        filter = filter and filter.name or filter_name(proto.filter),
        minimum_temperature = filter and filter.minimum_temperature or proto.minimum_temperature,
        maximum_temperature = filter and filter.maximum_temperature or proto.maximum_temperature,
        capacity = capacity, segment = segment, segment_name = segment_name, segment_amount = segment_amount,
        name = fluid and fluid.name, amount = fluid and fluid.amount or 0,
        temperature = fluid and fluid.temperature }
    end
    return boxes
  end)
  return ok and rows or nil
end

return M
