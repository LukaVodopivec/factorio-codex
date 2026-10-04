-- Parametric blocks for build_block: each one expands to a build_layout
-- layout in tile-corner offsets (the anchor is the top-left corner of the
-- block's first tile), plus the site request that fits it. The bot chooses
-- what, where and how many; this file only does the tile arithmetic.
--
-- Geometry facts (Factorio 2.0.77 base data):
--  * an inserter facing 0 picks up 1 tile north and drops 1.2 tiles south;
--    so it drops south at 0, west at 4, north at 8 and east at 12;
--  * mining drills facing 0 drop onto the tile row just above them (burner:
--    above the left column, electric: above the middle column);
--  * a boiler facing 0 is 3x2 with water ports on its lower row, west and
--    east, and steam out of the middle of its top; a steam engine facing 0
--    is 3x5 with ports at both ends; an offshore pump facing 0 takes water
--    from the north and outputs south;
--  * a small pole supplies 2.5 tiles around itself and wires 7.5 tiles.
local registry = require("scripts.registry")

local M = {}

local DROP = { south = 0, west = 4, north = 8, east = 12 }
local BELT = { north = 0, east = 4, south = 8, west = 12 }

M.BLOCKS = { mining = true, smelting = true, assembly = true, power = true, labs = true }
M.MAX_COUNT = { mining = 24, smelting = 16, assembly = 16, power = 20, labs = 24 }

-- An item the body carries or can craft now.
local function available(c, item)
  if not prototypes.item[item] then return false end
  if c.get_item_count(item) > 0 then return true end
  local recipe = c.force.recipes[item]
  return recipe ~= nil and recipe.enabled == true
end

local function first(c, names)
  for _, name in ipairs(names) do if available(c, name) then return name end end
  return nil
end

-- The force already generates electricity: read from the event-maintained
-- registry, never an entity query (with no area that would walk the whole
-- surface). Until an upgraded save's registry is ready this says no, which
-- picks the burner tier, as on a fresh map.
local function powered()
  local ok, any = pcall(registry.any, { "generator", "burner-generator", "solar-panel" })
  return ok and any == true
end

local function size(name, direction)
  local item = prototypes.item[name]
  local proto = item and item.place_result
  local w, h = tonumber(proto and proto.tile_width) or 1, tonumber(proto and proto.tile_height) or 1
  if direction % 8 == 4 then w, h = h, w end
  return w, h
end

-- A layout under construction: put() takes the top-left tile of the entity.
local function layout()
  local self = { entities = {} }
  function self.put(name, left, top, direction, recipe)
    direction = direction or 0
    local w, h = size(name, direction)
    self.entities[#self.entities + 1] = { name = name, dx = left + w / 2, dy = top + h / 2,
      direction = direction, recipe = recipe }
  end
  function self.row(name, from_x, to_x, y, direction)
    for x = from_x, to_x do self.put(name, x, y, direction) end
  end
  function self.column(name, x, from_y, to_y, direction)
    for y = from_y, to_y do self.put(name, x, y, direction) end
  end
  return self
end

local function need(value, message)
  if not value then error(message, 0) end
  return value
end

local function pole(c)
  return need(first(c, { "small-electric-pole", "medium-electric-pole" }), "no electric pole the body can carry or craft")
end

-- Drills in a row facing north onto a belt flowing west (3 or more drills)
-- or one chest each. Electric drills come in pairs around a pole.
local function mining(c, params, tiers)
  local resource = params.resource
  need(type(resource) == "string" and prototypes.entity[resource] and prototypes.entity[resource].type == "resource",
    "a mining block needs resource = a resource name such as iron-ore")
  local drill = powered() and first(c, { "electric-mining-drill" }) or first(c, { "burner-mining-drill" })
  drill = need(drill, "no mining drill the body can carry or craft")
  local width = size(drill, 0)
  local belt = params.count >= 3
  local out = belt and need(first(c, { "transport-belt" }), "no transport belt the body can carry or craft")
    or need(first(c, { "iron-chest", "wooden-chest" }), "no chest the body can carry or craft")
  local l = layout()
  local electric = drill == "electric-mining-drill"
  local pole_name = electric and pole(c) or nil
  local right = 0
  for k = 0, params.count - 1 do
    local left = electric and (7 * math.floor(k / 2) + 4 * (k % 2)) or width * k
    l.put(drill, left, 0, 0)
    if electric and k % 2 == 0 then l.put(pole_name, left + 3, 1) end
    if not belt then l.put(out, left + (electric and 1 or 0), -1) end
    right = left + width
  end
  if belt then l.row(out, 0, right - 1, -1, BELT.west) end
  tiers.drill, tiers.output, tiers.pole = drill, out, pole_name
  return l, { on_resource = resource }
end

-- Furnaces in a column between a south-flowing input belt (west) and
-- output belt (east), one inserter on each side of every furnace.
local function smelting(c, params, tiers)
  local electric = powered()
  local furnace = electric and first(c, { "electric-furnace" }) or first(c, { "steel-furnace", "stone-furnace" })
  furnace = need(furnace, "no furnace the body can carry or craft")
  local inserter = need(electric and first(c, { "inserter" }) or first(c, { "burner-inserter", "inserter" }),
    "no inserter the body can carry or craft")
  local belt = need(first(c, { "transport-belt" }), "no transport belt the body can carry or craft")
  local s = size(furnace, 0)
  local needs_power = inserter == "inserter" or furnace == "electric-furnace"
  local pole_name = needs_power and pole(c) or nil
  local l = layout()
  for k = 0, params.count - 1 do
    local top = k * s
    l.column(belt, 0, top, top + s - 1, BELT.south)
    l.put(inserter, 1, top, DROP.east)
    l.put(furnace, 2, top, 0)
    l.put(inserter, 2 + s, top, DROP.east)
    l.column(belt, 3 + s, top, top + s - 1, BELT.south)
    if pole_name then
      l.put(pole_name, 1, top + 1)
      l.put(pole_name, 2 + s, top + 1)
    end
  end
  tiers.furnace, tiers.inserter, tiers.belt, tiers.pole = furnace, inserter, belt, pole_name
  return l, {}
end

-- Assemblers in a row with a pole between each, fed from an east-flowing
-- belt above and emptied onto an east-flowing belt below.
local function assembly(c, params, tiers)
  local recipe = need(type(params.recipe) == "string" and c.force.recipes[params.recipe],
    "an assembly block needs recipe = a known recipe name")
  need(recipe.enabled, "recipe " .. params.recipe .. " isn't unlocked yet — research it first")
  local machine = need(first(c, { "assembling-machine-3", "assembling-machine-2", "assembling-machine-1" }),
    "no assembling machine the body can carry or craft")
  local inserter = need(first(c, { "inserter", "burner-inserter" }), "no inserter the body can carry or craft")
  local belt = need(first(c, { "transport-belt" }), "no transport belt the body can carry or craft")
  local pole_name = pole(c)
  local a = size(machine, 0)
  local l = layout()
  local right = params.count * (a + 1) - 1
  l.row(belt, 0, right, 0, BELT.east)
  for k = 0, params.count - 1 do
    local left = k * (a + 1)
    l.put(inserter, left + 1, 1, DROP.south)
    l.put(machine, left, 2, 0, params.recipe)
    l.put(inserter, left + 1, 2 + a, DROP.south)
    l.put(pole_name, left + a, 3)
  end
  l.row(belt, 0, right, 3 + a, BELT.east)
  tiers.machine, tiers.inserter, tiers.belt, tiers.pole = machine, inserter, belt, pole_name
  return l, {}
end

-- Offshore pump, then boilers in a row joined by pipes, two steam engines
-- above each boiler, poles in the gap columns.
local function power(c, params, tiers)
  for _, name in ipairs({ "offshore-pump", "boiler", "steam-engine", "pipe" }) do
    need(available(c, name), "no " .. name .. " the body can carry or craft")
  end
  local pole_name = pole(c)
  local l = layout()
  -- Facing 12 the pump takes water from the west and outputs east, straight
  -- into the first boiler's west water port.
  l.put("offshore-pump", -1, 1, 12)
  for k = 0, params.count - 1 do
    local left = 4 * k
    l.put("boiler", left, 0, 0)
    if k < params.count - 1 then l.put("pipe", left + 3, 1) end
    l.put("steam-engine", left, -5, 0)
    l.put("steam-engine", left, -10, 0)
    l.put(pole_name, left + 3, -3)
    l.put(pole_name, left + 3, -8)
  end
  tiers.pole = pole_name
  return l, { near_water = true }
end

-- Labs in a row; an inserter in each gap passes science to the next lab and
-- a pole there powers both neighbours.
local function labs(c, params, tiers)
  need(available(c, "lab"), "no lab the body can carry or craft")
  local inserter = need(first(c, { "inserter", "burner-inserter" }), "no inserter the body can carry or craft")
  local pole_name = pole(c)
  local s = size("lab", 0)
  local l = layout()
  for k = 0, params.count - 1 do
    local left = k * (s + 1)
    l.put("lab", left, 0, 0)
    if k < params.count - 1 then l.put(inserter, left + s, 0, DROP.east) end
    l.put(pole_name, left + s, 1)
  end
  tiers.inserter, tiers.pole = inserter, pole_name
  return l, {}
end

local EXPAND = { mining = mining, smelting = smelting, assembly = assembly, power = power, labs = labs }

-- Raises with a plain message when the request is malformed.
function M.validate(params, label)
  label = label or "build_block"
  if not M.BLOCKS[params.block] then
    error(label .. " block must be mining, smelting, assembly, power or labs", 0)
  end
  local count = tonumber(params.count)
  local max = M.MAX_COUNT[params.block]
  if not count or count % 1 ~= 0 or count < 1 or count > max then
    error(string.format("%s count for a %s block must be an integer from 1 to %d", label, params.block, max), 0)
  end
  if params.block == "mining" and type(params.resource) ~= "string" then
    error(label .. " mining needs resource, e.g. iron-ore", 0)
  end
  if params.block == "assembly" and type(params.recipe) ~= "string" then
    error(label .. " assembly needs recipe", 0)
  end
  local near = params.near
  if near ~= nil and (type(near) ~= "table" or type(near.x) ~= "number" or type(near.y) ~= "number") then
    error(label .. " near must be {x, y}", 0)
  end
end

-- {layout = {entities}, site = {near, on_resource?, near_water?}, tiers}.
-- The block's whole layout may be turned to fit the site.
function M.expand(c, params)
  M.validate(params)
  local tiers = {}
  local l, site = EXPAND[params.block](c, { count = math.floor(params.count), resource = params.resource,
    recipe = params.recipe }, tiers)
  site.near = params.near and { x = params.near.x, y = params.near.y } or { x = c.position.x, y = c.position.y }
  return { layout = { entities = l.entities }, site = site, tiers = tiers }
end

return M
