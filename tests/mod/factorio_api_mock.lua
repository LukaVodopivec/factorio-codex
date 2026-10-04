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

local function allowed(class, key)
  return members[class][key] or class == "LuaFluidBox" and type(key) == "number"
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
  local readers = {}
  objects[values] = { class = class, simulation = simulation or {}, unreadable = unreadable, readers = readers }
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
function M.length(object, reader)
  assert(objects[object] and objects[object].class == "LuaFluidBox", "length requires a fluidbox mock")
  -- The proxy metatable remains protected; only the native length behavior changes.
  objects[object].length = reader
end
function M.assert_clean()
  assert(#M.violations == 0, table.concat(M.violations, "\n"))
end
return M
