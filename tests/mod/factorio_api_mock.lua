-- Test-only LuaObject proxies. Membership comes from the official versioned API,
-- while fixture values and intentional native read failures remain independent.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local members = dofile(here .. "/fixtures/factorio-2.0.77-runtime-members.lua")
local M = { violations = {} }
local objects = setmetatable({}, { __mode = "k" })

local function invalid(class, key, action)
  local message = class .. " has no member " .. tostring(key) .. " (" .. action .. ")"
  M.violations[#M.violations + 1] = message
  error(message, 3)
end

-- LuaFluidBox and LuaInventory have a numeric index operator.
local INDEXED = { LuaFluidBox = true, LuaInventory = true }
local function allowed(class, key)
  return members[class][key] or INDEXED[class] and type(key) == "number"
    and key >= 1 and key % 1 == 0
end

local function wrap(class, values, simulation)
  values = values or {}
  if objects[values] then
    assert(objects[values].class == class, "mock class mismatch")
    return values
  end
  local data, unreadable = {}, {}
  for key, value in pairs(values) do
    if not allowed(class, key) then invalid(class, key, "definition") end
    data[key] = value
  end
  local previous = getmetatable(values) or {}
  local function nested(key, value)
    if class == "LuaEntity" and type(value) == "table" then
      if key == "burner" then return wrap("LuaBurner", value) end
      if key == "fluidbox" then return wrap("LuaFluidBox", value) end
    end
    return value
  end
  for key, value in pairs(data) do data[key] = nested(key, value); rawset(values, key, nil) end
  local readers, writers = {}, {}
  objects[values] = { class = class, simulation = simulation or {}, unreadable = unreadable, readers = readers, writers = writers }
  return setmetatable(values, {
    __metatable = "strict Factorio mock",
    __index = function(_, key)
      if not allowed(class, key) then invalid(class, key, "read") end
      if unreadable[key] then error("unreadable native " .. class .. "." .. tostring(key), 2) end
      if readers[key] then return readers[key]() end
      if data[key] ~= nil then return data[key] end
      if type(previous.__index) == "function" then return previous.__index(values, key) end
      if type(previous.__index) == "table" then return previous.__index[key] end
    end,
    __newindex = function(_, key, value)
      if not allowed(class, key) then invalid(class, key, "assignment") end
      if writers[key] then writers[key](value) end
      data[key] = nested(key, value)
    end,
    __len = function()
      local length = objects[values].length or previous.__len
      return length and length(values) or #data
    end,
    __pairs = function() return next, data, nil end,
  })
end

function M.entity(values, simulation) return wrap("LuaEntity", values, simulation) end
function M.fluidbox(values) return wrap("LuaFluidBox", values) end
function M.burner(values) return wrap("LuaBurner", values) end
-- Classes whose members a native 2.0.77 probe confirmed one by one.
function M.force(values) return wrap("LuaForce", values) end
function M.surface(values) return wrap("LuaSurface", values) end
function M.flow_statistics(values) return wrap("LuaFlowStatistics", values) end
function M.transport_line(values) return wrap("LuaTransportLine", values) end
function M.inventory(values) return wrap("LuaInventory", values) end
function M.entity_prototype(values) return wrap("LuaEntityPrototype", values) end
-- Documented 2.0.77 members (not probed natively).
function M.item_stack(values) return wrap("LuaItemStack", values) end
function M.shortcut_prototype(values) return wrap("LuaShortcutPrototype", values) end
function M.logistic_network(values) return wrap("LuaLogisticNetwork", values) end
-- Documented 2.0.77 members of the 0.22.0 stage A classes (not probed natively).
function M.item_prototype(values) return wrap("LuaItemPrototype", values) end
function M.tile(values) return wrap("LuaTile", values) end
function M.tile_prototype(values) return wrap("LuaTilePrototype", values) end
function M.equipment_grid(values) return wrap("LuaEquipmentGrid", values) end
function M.equipment(values) return wrap("LuaEquipment", values) end
function M.equipment_prototype(values) return wrap("LuaEquipmentPrototype", values) end
function M.logistic_sections(values) return wrap("LuaLogisticSections", values) end
function M.logistic_section(values) return wrap("LuaLogisticSection", values) end
function M.logistic_cell(values) return wrap("LuaLogisticCell", values) end
-- Documented 2.0.77 members of the 0.22.2 stage B classes (not probed natively).
function M.space_platform(values) return wrap("LuaSpacePlatform", values) end
function M.planet(values) return wrap("LuaPlanet", values) end
function M.space_location_prototype(values) return wrap("LuaSpaceLocationPrototype", values) end
-- Documented 2.0.77 members of the 0.22.3 stage C classes (not probed natively).
function M.space_connection_prototype(values) return wrap("LuaSpaceConnectionPrototype", values) end
function M.recipe_prototype(values) return wrap("LuaRecipePrototype", values) end
function M.surface_property_prototype(values) return wrap("LuaSurfacePropertyPrototype", values) end
function M.asteroid_chunk_prototype(values) return wrap("LuaAsteroidChunkPrototype", values) end
function M.logistic_point(values) return wrap("LuaLogisticPoint", values) end
function M.state(object)
  assert(objects[object], "simulation state requires a strict mock")
  return objects[object].simulation
end
function M.unreadable(object, key, enabled)
  local record = assert(objects[object], "native read failure requires a strict mock")
  if not allowed(record.class, key) then invalid(record.class, key, "read failure definition") end
  record.unreadable[key] = enabled ~= false
end
function M.read(object, key, reader)
  local record = assert(objects[object], "native read simulation requires a strict mock")
  if not allowed(record.class, key) then invalid(record.class, key, "read simulation definition") end
  record.readers[key] = reader
end
function M.write(object, key, writer)
  local record = assert(objects[object], "native write simulation requires a strict mock")
  if not allowed(record.class, key) then invalid(record.class, key, "write simulation definition") end
  record.writers[key] = writer
end
function M.length(object, reader)
  assert(objects[object] and INDEXED[objects[object].class], "length requires a fluidbox or inventory mock")
  -- The proxy metatable remains protected; only the native length behavior changes.
  objects[object].length = reader
end
function M.assert_clean()
  assert(#M.violations == 0, table.concat(M.violations, "\n"))
end
return M
