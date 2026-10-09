-- Stable world-space fluid connection facts for live entities and candidates.
local M = {}

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

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

-- One tile step out of an entity side, by cardinal direction.
local UNIT = { [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } }

-- A north-frame offset turned clockwise to a cardinal direction.
local function rotate(p, direction)
  if direction == 4 then return { x = -p.y, y = p.x } end
  if direction == 8 then return { x = -p.x, y = -p.y } end
  if direction == 12 then return { x = p.y, y = -p.x } end
  return { x = p.x, y = p.y }
end

-- The normal pipe connections of a prototype facing a cardinal direction,
-- as ports {box, at, target} relative to its position: at lies in the
-- entity's own tile the connection leaves from, target in the tile it
-- points at (a neighbour there connects back from it); the tile is what
-- counts, so a caller takes floor of each once placed. area is the
-- footprint at the origin. A definition position inside the footprint is
-- that tile (2.0: the connection's direction, turned with the entity, leads
-- out); one outside it is the target itself. Underground and linked
-- connections are left out; an unreadable box gives no ports. mirror: the
-- entity is placed mirrored, which reflects each north-frame connection
-- across the entity's vertical axis (x to -x, east and west swapped) before
-- the turn to direction (the order the game's horizontal blueprint flip
-- implies: direction 16 - d with mirroring toggled).
function M.ports(proto, direction, area, mirror)
  local out = {}
  direction = math.floor(tonumber(direction) or 0) % 16
  if direction % 4 ~= 0 then return out end
  local ok, boxes = pcall(function() return proto.fluidbox_prototypes end)
  if not ok or type(boxes) ~= "table" then return out end
  local lt, rb = area.left_top, area.right_bottom
  for index, box in pairs(boxes) do
    pcall(function()
      local box_index = tonumber(box.index) or tonumber(index)
      for _, connection in ipairs(box.pipe_connections or {}) do
        local kind = connection.connection_type
        local p = vec(connection.positions and connection.positions[mirror and 1 or direction / 4 + 1])
        local d = tonumber(connection.direction)
        if p and mirror then
          p = rotate({ x = -p.x, y = p.y }, direction)
          d = d and (16 - math.floor(d)) % 16
        end
        if p and (kind == nil or kind == "normal") then
          if p.x > lt.x and p.x < rb.x and p.y > lt.y and p.y < rb.y then
            local step = d and UNIT[(math.floor(d) + direction) % 16]
            if step then out[#out + 1] = { box = box_index, at = p, target = { x = p.x + step[1], y = p.y + step[2] } } end
          else
            out[#out + 1] = { box = box_index, target = p,
              at = { x = math.min(math.max(p.x, lt.x + 0.01), rb.x - 0.01), y = math.min(math.max(p.y, lt.y + 0.01), rb.y - 0.01) } }
          end
        end
      end
    end)
  end
  return out
end

-- ------------------------------------------------- recipe fluid boxes
-- How a crafting machine's recipe uses its fluid boxes, as Factorio 2.0.77
-- sets them (read live on every base and Space Age crafter): input boxes
-- take the recipe's fluid ingredients, output boxes its fluid products, each
-- role in prototype box order against the recipe's fluids in recipe order.
--  * No fluid of a role: the game removes that role's boxes, connections
--    and all (an assembler on gears has no box).
--  * Fluids that name a fluidbox_index (basic oil processing: crude oil 2,
--    petroleum gas 3) take the role's box at that place; the role's other
--    boxes are removed.
--  * As many fluids as boxes: one box each, in order.
--  * Fewer: the first fluid takes the first boxes merged into one, each
--    later fluid one of the last boxes (two fluids in three boxes: 1+2, 3).
--    Seen for up to three boxes of a role, which every crafter has.
-- {[box index] = {role, fluid}}: fluid is false for a removed box; a box
-- whose use is not known (more than three boxes of a role with fewer
-- fluids, an index only some fluids name, a box neither input nor output)
-- is left out.
local RECIPE_ROLE = { input = "ingredients", output = "products" }
local recipe_box_cache = {}
function M.recipe_boxes(proto, recipe_name)
  local key = tostring(proto and proto.name) .. "|" .. tostring(recipe_name)
  local cached = recipe_box_cache[key]
  if cached then return cached end
  local out = {}
  pcall(function()
    local recipe = prototypes.recipe[recipe_name]
    local boxes = { input = {}, output = {} }
    for index, box in pairs(proto.fluidbox_prototypes) do
      local list = boxes[box.production_type]
      if list then list[#list + 1] = tonumber(box.index) or tonumber(index) end
    end
    for role, field in pairs(RECIPE_ROLE) do
      local list = boxes[role]
      table.sort(list)
      local fluids, indexed = {}, 0
      for _, row in ipairs(recipe[field] or {}) do
        if row.type == "fluid" then
          fluids[#fluids + 1] = row
          if tonumber(row.fluidbox_index) and row.fluidbox_index > 0 then indexed = indexed + 1 end
        end
      end
      local m, n = #list, #fluids
      if n == 0 then
        for _, b in ipairs(list) do out[b] = { role = role, fluid = false } end
      elseif indexed == n then
        for _, b in ipairs(list) do out[b] = { role = role, fluid = false } end
        for _, row in ipairs(fluids) do
          local b = list[row.fluidbox_index]
          if b then out[b] = { role = role, fluid = row.name } end
        end
      elseif indexed == 0 and n <= m and (n == m or m <= 3) then
        for k, b in ipairs(list) do
          out[b] = { role = role, fluid = fluids[math.max(1, k - (m - n))].name }
        end
      end
    end
  end)
  recipe_box_cache[key] = out
  return out
end

-- M.ports of a crafting machine on a recipe, each port with its role and
-- fluid (recipe_boxes; fluid false: a removed box that connects nothing,
-- nil: not known).
function M.recipe_ports(proto, recipe_name, direction, area, mirror)
  local ports = M.ports(proto, direction, area, mirror)
  local uses = recipe_name and M.recipe_boxes(proto, recipe_name) or {}
  for _, port in ipairs(ports) do
    local use = uses[port.box]
    if use then port.role, port.fluid = use.role, use.fluid end
  end
  return ports
end

-- The role of a live box ("input", "output", ...), merged boxes included
-- (all members of one share it), nil when unreadable.
local function live_role(entity, index)
  local ok, role = pcall(function()
    local proto = entity.fluidbox.get_prototype(index)
    if type(proto) == "table" and proto[1] ~= nil then proto = proto[1] end
    return proto.production_type
  end)
  return ok and type(role) == "string" and role or nil
end
M.live_role = live_role

-- The fluid a live box is set to take: its runtime filter (a crafter's
-- comes from its recipe), else the fluid it is locked to; nil when neither.
function M.takes(entity, index)
  local ok, filter = pcall(function() return entity.fluidbox.get_filter(index) end)
  if ok and type(filter) == "table" and type(filter.name) == "string" then return filter.name end
  local locked_ok, locked = pcall(function() return entity.fluidbox.get_locked_fluid(index) end)
  return locked_ok and type(locked) == "string" and locked or nil
end

-- The fluid on the far side of a live connection: what the box it reaches
-- holds, else what that box's fluid segment holds; nil when nothing.
function M.target_fluid(target_entity, target_index)
  if not (target_entity and target_index) then return nil end
  local ok, name = pcall(function()
    local held = target_entity.fluidbox[target_index]
    if held and type(held.name) == "string" then return held.name end
    local contents = target_entity.fluidbox.get_fluid_segment_contents(target_index)
    for fluid, amount in pairs(contents or {}) do
      if type(fluid) == "string" and amount > 0 then return fluid end
    end
  end)
  return ok and name or nil
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

-- M.live rows as inspect shows them, each with what its box takes (M.takes)
-- and, when connected, the fluid it meets (M.target_fluid); mismatch when
-- both are known and differ.
function M.inspected(entity)
  local rows = M.live(entity, true)
  local takes = {}
  for _, row in ipairs(rows) do
    local index = row.fluidbox_index
    if takes[index] == nil then takes[index] = M.takes(entity, index) or false end
    row.takes = takes[index] or nil
    row.meets = M.target_fluid(row._target_entity, row._target_fluidbox_index)
    if row.takes and row.meets and row.takes ~= row.meets then row.mismatch = true end
    row._pipe_connection_index, row._target_entity, row._target_fluidbox_index = nil, nil, nil
    row._target_pipe_connection_index = nil
  end
  return rows
end

-- The fluid a live box takes: its runtime filter (a crafting machine's comes
-- from its recipe), else its prototype filter, else what it holds; nil when
-- none says.
function M.box_fluid(entity, index, prototype_filter)
  local ok, filter = pcall(function() return entity.fluidbox.get_filter(index) end)
  if ok and type(filter) == "table" and type(filter.name) == "string" then return filter.name end
  if prototype_filter then return prototype_filter end
  local held_ok, fluid = pcall(function() return entity.fluidbox[index] end)
  return held_ok and type(fluid) == "table" and type(fluid.name) == "string" and fluid.name or nil
end

-- Private component samples only: runtime filters and stock, not recipe
-- ingredients or identities inferred from stock. Natively get_capacity is
-- this box's own capacity, while segment contents include every member box.
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
      -- Output and transfer boxes in 2.0.77 (offshore pumps, separate-pipe
      -- boiler outputs, pumps) can have no segment at all. A successful nil
      -- pair is native absence, not zero stock: such a box's own buffer is its
      -- whole pool. Input boxes always have a segment; failed calls still
      -- refuse this sample through the enclosing pcall.
      local absent = segment == nil and contents == nil and proto.production_type ~= "input"
      local segment_name, segment_amount
      if not absent then
        if not finite(segment) or segment <= 0 or segment % 1 ~= 0 or type(contents) ~= "table" then
          error("unreadable fluid segment")
        end
        segment_amount = 0
        for name, amount in pairs(contents) do
          if segment_name or type(name) ~= "string" or not finite(amount) or amount < 0 then error("ambiguous fluid segment") end
          segment_name, segment_amount = name, amount
        end
        if fluid and segment_name ~= fluid.name then error("inconsistent fluid segment identity") end
      end
      if not finite(capacity) or capacity <= 0 then error("unreadable fluid capacity") end
      if fluid and (type(fluid.name) ~= "string" or not finite(fluid.amount) or fluid.amount < 0
        or not finite(fluid.temperature)) then error("unreadable fluid") end
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
