-- Offline tests for entity_settings.lua, the one settings path: a Settings
-- object is validated (shape, item names), checked against the entity before
-- any write (CONFIG_NOT_APPLICABLE, SLOTS_OUT_OF_RANGE), written only where
-- it differs and read back; read gives non-default values only; blueprint
-- fields translate both ways; a 0.21.1 settings table saved in a plan still
-- applies. Entities, inventories and prototypes are strict 2.0.77 mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local mock = dofile(here .. "/factorio_api_mock.lua")
_G.storage, _G.game = {}, { tick = 1 }
_G.defines = { inventory = { chest = 1 } }
_G.prototypes = { item = { ["iron-plate"] = {}, ["copper-plate"] = {}, coal = {} }, entity = {} }
local settings = require("scripts.entity_settings")

local function raises(fn, pattern)
  local ok, err = pcall(fn)
  return not ok and tostring(err):match(pattern) ~= nil
end

local function inserter(values)
  local filters = values.filters or {}
  values.filters = nil
  values.valid, values.type = true, "inserter"
  values.name = values.name or "fast-inserter"
  values.prototype = mock.entity_prototype({ name = values.name, type = "inserter", filter_count = values.filter_slot_count })
  local e = mock.entity(values)
  e.get_filter = function(index) return filters[index] and { name = filters[index], quality = "normal" } or nil end
  e.set_filter = function(index, filter) filters[index] = filter end
  return e, filters
end

local function chest(name, kind, logistic_mode, size, bar_supported)
  local bar = size + 1
  local inventory = mock.inventory({ supports_bar = function() return bar_supported end, get_bar = function() return bar end,
    set_bar = function(value) bar = value or size + 1 end })
  mock.length(inventory, function() return size end)
  local e = mock.entity({ valid = true, name = name, type = kind,
    prototype = mock.entity_prototype({ name = name, type = kind, logistic_mode = logistic_mode }),
    get_inventory = function(id) return id == defines.inventory.chest and inventory or nil end })
  return e, function() return bar end
end

-- -------------------------------------------------------------- validate

check(pcall(settings.validate, { inserter = { filters = { "iron-plate" }, mode = "whitelist", stack_size = 1,
  spoil_priority = "fresh_first" }, splitter = { input_priority = "left", filter = false }, chest = { slots = 0 } }, "t"),
  "a full Settings object validates")
check(raises(function() settings.validate({}, "t") end, "^CONFIG_INVALID: t needs at least one"), "an empty object is refused")
check(raises(function() settings.validate({ circuit = { x = 1 } }, "t") end, "no setting group 'circuit'"),
  "an unknown group is refused")
check(raises(function() settings.validate({ inserter = { filter = "coal" } }, "t") end, "t.inserter has no setting 'filter'"),
  "an unknown field is refused")
check(raises(function() settings.validate({ inserter = { filters = { "coal", "coal", "coal", "coal", "coal", "coal" } } }, "t") end,
  "at most 5"), "more than five inserter filters are refused")
check(raises(function() settings.validate({ splitter = { filter = "unobtainium" } }, "t") end,
  "^UNKNOWN_ITEM: t.splitter.filter"), "an unknown item is UNKNOWN_ITEM")
check(raises(function() settings.validate({ chest = { slots = -1 } }, "t") end, "slots must be an integer"),
  "a negative slot count is refused")
check(raises(function() settings.validate({ splitter = { output_priority = "up" } }, "t") end, "left"),
  "a splitter side must be left, none or right")

-- ------------------------------------------------------------ inserters

local arm, filters = inserter({ filter_slot_count = 5, use_filters = false, inserter_filter_mode = "whitelist",
  inserter_stack_size_override = 0, inserter_spoil_priority = "none" })
check(settings.read(arm) == nil, "an inserter with game defaults reads as no settings")
local want = { inserter = { filters = { "iron-plate", "copper-plate" }, mode = "blacklist", stack_size = 2,
  spoil_priority = "spoiled_first" } }
check(settings.check(arm, want) == nil, "a filter inserter takes inserter settings")
local changed, notes = settings.apply(arm, want)
check(#changed == 4 and changed[1] == "inserter.filters" and #notes == 0 and arm.use_filters == true
  and filters[1] == "iron-plate" and filters[2] == "copper-plate" and filters[3] == nil
  and arm.inserter_filter_mode == "blacklist" and arm.inserter_stack_size_override == 2
  and arm.inserter_spoil_priority == "spoiled_first", "apply writes filters, mode, stack size and spoil priority")
local again = settings.apply(arm, want)
check(#again == 0, "applying the same settings again changes nothing")
local back = settings.readback(arm, { inserter = { filters = {}, mode = "x" } })
check(#back.inserter.filters == 2 and back.inserter.mode == "blacklist" and back.inserter.stack_size == nil,
  "readback names only the touched fields, as they now are")
local read = settings.read(arm)
check(read.inserter.filters[2] == "copper-plate" and read.inserter.stack_size == 2 and read.inserter.mode == "blacklist",
  "read gives the non-default settings")
local cleared = settings.apply(arm, { inserter = { filters = {} } })
check(cleared[1] == "inserter.filters" and arm.use_filters == false and filters[1] == nil, "[] clears the filters")

local burner = inserter({ name = "burner-inserter", filter_slot_count = 0 })
local code, message = settings.check(burner, { inserter = { filters = { "coal" } } })
check(code == "CONFIG_NOT_APPLICABLE" and message:match("no filter slots"), "an inserter without filter slots takes no filters")
check(settings.check(burner, { inserter = { stack_size = 1 } }) == nil, "but it takes a stack size")

-- A field the game does not keep is a note, not a change.
local stubborn = inserter({ filter_slot_count = 5, inserter_stack_size_override = 0 })
mock.read(stubborn, "inserter_stack_size_override", function() return 0 end)
local kept, kept_notes = settings.apply(stubborn, { inserter = { stack_size = 3 } })
check(#kept == 0 and kept_notes[1]:match("kept its inserter.stack_size"), "a value the game does not keep is reported")

-- ------------------------------------------------------------- splitters

local split = mock.entity({ valid = true, name = "splitter", type = "splitter", splitter_input_priority = "none",
  splitter_output_priority = "none" })
local split_changed, split_notes = settings.apply(split, { splitter = { input_priority = "left", filter = "iron-plate" } })
check(split.splitter_input_priority == "left" and split.splitter_output_priority == "left" and split.splitter_filter.name == "iron-plate"
  and #split_changed == 3 and split_notes[1]:match("needs an output side"),
  "a splitter filter without an output side gets the left side, and says so")
settings.apply(split, { splitter = { filter = false } })
check(split.splitter_filter == nil, "false removes the splitter filter")
local lane = mock.entity({ valid = true, name = "lane-splitter", type = "lane-splitter" })
check(settings.check(lane, { splitter = { input_priority = "right" } }) == nil, "a lane splitter takes splitter settings")
local assembler = mock.entity({ valid = true, name = "assembling-machine-2", type = "assembling-machine",
  prototype = mock.entity_prototype({ name = "assembling-machine-2", type = "assembling-machine" }) })
local refused, refusal = settings.check(assembler, { splitter = { input_priority = "left" } })
check(refused == "CONFIG_NOT_APPLICABLE" and refusal:match("assembling%-machine%-2 %(assembling%-machine%) takes no splitter"),
  "an assembler refuses splitter settings, naming its type")
local untouched, untouched_notes, untouched_code = settings.apply(assembler, { inserter = { stack_size = 1 } })
check(#untouched == 0 and untouched_code == "CONFIG_NOT_APPLICABLE" and untouched_notes[1]:match("^CONFIG_NOT_APPLICABLE"),
  "apply on an entity that takes none of it writes nothing")

-- ---------------------------------------------------------------- chests

local box, bar = chest("iron-chest", "container", nil, 32, true)
check(settings.read(box) == nil, "an unlimited chest has no settings")
local slots_changed = settings.apply(box, { chest = { slots = 4 } })
check(slots_changed[1] == "chest.slots" and bar() == 5 and settings.read(box).chest.slots == 4,
  "slots = 4 sets the bar after the fourth slot")
settings.apply(box, { chest = { slots = false } })
check(bar() == 33 and settings.read(box) == nil, "false removes the limit")
check(settings.check(box, { chest = { slots = 33 } }) == "SLOTS_OUT_OF_RANGE", "more slots than the chest has are refused")
check(settings.check(box, { chest = { storage_filter = "coal" } }) == "CONFIG_NOT_APPLICABLE",
  "a plain chest has no storage filter")
local barless = chest("infinity-thing", "container", nil, 10, false)
check(settings.check(barless, { chest = { slots = 2 } }) == "CONFIG_NOT_APPLICABLE", "a chest without a bar takes no limit")
local storage_chest = chest("storage-chest", "logistic-container", "storage", 48, true)
settings.apply(storage_chest, { chest = { storage_filter = "iron-plate" } })
check(storage_chest.storage_filter.name == "iron-plate" and storage_chest.storage_filter.quality == "normal"
  and settings.read(storage_chest).chest.storage_filter == "iron-plate", "a storage chest keeps a storage filter")

-- ------------------------------------------------------------- prototypes

local furnace_proto = mock.entity_prototype({ name = "stone-furnace", type = "furnace" })
check(settings.check_prototype(furnace_proto, { inserter = { filters = { "coal" } } }) == "CONFIG_NOT_APPLICABLE",
  "a layout entity's prototype is checked before it is built")
check(settings.check_prototype(mock.entity_prototype({ name = "inserter", type = "inserter", filter_count = 5 }),
  { inserter = { filters = { "coal" } } }) == nil, "an inserter prototype with filter slots takes filters")

-- ------------------------------------------------------------- blueprints

local row = settings.to_blueprint({ inserter = { filters = { "coal" }, mode = "blacklist", spoil_priority = "fresh_first" } },
  { name = "fast-inserter" }, "inserter")
check(row.use_filters and row.filters[1].index == 1 and row.filters[1].name == "coal" and row.filter_mode == "blacklist"
  and row.spoil_priority == "fresh-first", "settings become BlueprintEntity fields")
local round = settings.from_blueprint(row, "inserter")
check(round.inserter.filters[1] == "coal" and round.inserter.mode == "blacklist" and round.inserter.spoil_priority == "fresh_first",
  "and read back as the same settings")
check(settings.from_blueprint({ name = "iron-chest", bar = 4 }, "container").chest.slots == 4,
  "a blueprint bar is the number of usable slots")

-- A 0.21.1 plan step or move snapshot still holds blueprint fields.
local old, old_filters = inserter({ filter_slot_count = 5, use_filters = false, mirroring = false })
local old_changed = settings.apply(old, { mirror = true, use_filters = true, filters = { { index = 2, name = "coal" } } })
check(old.mirroring == true and old.use_filters == true and old_filters[1] == "coal" and old_changed[1] == "inserter.filters",
  "0.21.1 settings saved in a plan still apply")
check(settings.from_blueprint({ filters = { { index = 1, name = "coal" } } }, "inserter") == nil
  and settings.from_blueprint({ name = "inserter", filters = { { index = 1, name = "coal" } } }, "inserter") == nil,
  "filters without use_filters (0.21.1 snapshot, captured blueprint) are off, not a whitelist")
local old_box, old_bar = chest("wooden-chest", "container", nil, 16, true)
settings.apply(old_box, { bar = 5 })
check(old_bar() == 5, "a 0.21.1 bar is the inventory's bar index")

mock.assert_clean()
print(failures == 0 and "\nALL ENTITY SETTINGS TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
