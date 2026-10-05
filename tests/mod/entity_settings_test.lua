-- Offline tests for build.read_settings / build.apply_settings: the settings
-- a blueprint keeps (mirror, inserter filters, splitter priorities and
-- filter, a chest's bar) read from one entity and put on another, through
-- 2.0.77 LuaEntity and LuaInventory members only; a setting an entity does
-- not take is reported, never raised.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local mock = dofile(here .. "/factorio_api_mock.lua")
_G.storage, _G.game = {}, { tick = 1 }
_G.defines = { inventory = { chest = 1 }, direction = { north = 0, east = 4, south = 8, west = 12 } }
package.loaded["scripts.companion"] = { get = function() end, require_companion = function() end }
package.loaded["scripts.registry"] = { add = function() end }
local build = require("scripts.actions.build")

local function inserter(values)
  local filters = values.filters or {}
  values.filters = nil
  local e = mock.entity(values)
  e.get_filter = function(index) return filters[index] and { name = filters[index], quality = "normal" } or nil end
  e.set_filter = function(index, filter) filters[index] = filter end
  return e, filters
end
local source = inserter({ valid = true, name = "fast-inserter", type = "inserter", mirroring = false, filter_slot_count = 5,
  use_filters = true, inserter_filter_mode = "blacklist", filters = { [2] = "coal" } })
local settings = build.read_settings(source)
check(settings.use_filters and settings.filter_mode == "blacklist" and #settings.filters == 1
  and settings.filters[1].index == 2 and settings.filters[1].name == "coal" and settings.mirror == nil,
  "an inserter's filter settings are read")
local target, target_filters = inserter({ valid = true, name = "fast-inserter", type = "inserter", mirroring = false,
  filter_slot_count = 5, use_filters = false, inserter_filter_mode = "whitelist" })
local unset = build.apply_settings(target, settings)
check(#unset == 0 and target.use_filters == true and target.inserter_filter_mode == "blacklist" and target_filters[2] == "coal",
  "and put on another inserter")
check(build.read_settings(mock.entity({ valid = true, name = "inserter", type = "inserter", mirroring = false,
  filter_slot_count = 0 })) == nil, "an entity without settings reads as none")

local splitter = mock.entity({ valid = true, name = "splitter", type = "splitter", mirroring = false,
  splitter_input_priority = "left", splitter_output_priority = "none", splitter_filter = { name = "iron-plate" } })
local split_settings = build.read_settings(splitter)
check(split_settings.input_priority == "left" and split_settings.output_priority == nil and split_settings.filter.name == "iron-plate",
  "a splitter's priorities and filter are read")
local other = mock.entity({ valid = true, name = "splitter", type = "splitter", splitter_input_priority = "none",
  splitter_output_priority = "none" })
build.apply_settings(other, split_settings)
check(other.splitter_input_priority == "left" and other.splitter_filter.name == "iron-plate", "and put on another splitter")

local bar = 10
local chest_inventory = mock.inventory({ supports_bar = function() return true end, get_bar = function() return bar end,
  set_bar = function(value) bar = value end })
mock.length(chest_inventory, function() return 16 end)
local chest = mock.entity({ valid = true, name = "iron-chest", type = "container", mirroring = false,
  get_inventory = function(id) return id == defines.inventory.chest and chest_inventory or nil end })
check(build.read_settings(chest).bar == 10, "a chest's bar is read")
bar = 17
check(build.read_settings(chest) == nil, "a chest without a bar has no settings")
build.apply_settings(chest, { bar = 4 })
check(bar == 4, "a bar is set on a chest")

local machine = mock.entity({ valid = true, name = "chemical-plant", type = "assembling-machine", mirroring = false })
local issues = build.apply_settings(machine, { mirror = true })
check(#issues == 0 and machine.mirroring == true, "a mirror is set")
local rigid = mock.entity({ valid = true, name = "inserter", type = "inserter" })
mock.read(rigid, "mirroring", function() return false end)
local refused = build.apply_settings(rigid, { filters = { { index = 1, name = "coal" } } })
check(#refused == 1 and refused[1]:match("couldn't set filter coal"), "a setting the entity refuses is reported, not raised")

mock.assert_clean()
print(failures == 0 and "\nALL ENTITY SETTINGS TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
