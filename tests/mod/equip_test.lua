-- Offline tests for equip (actions/equip.lua): armor is worn from the
-- inventory (the old one takes its slot), equipment goes into the worn
-- armor's grid at the first place it fits and comes back out into the
-- inventory, items are only ever moved, never made; an armor change that
-- would shrink the inventory over occupied slots is refused before anything
-- changes. Inventories, stacks, grids and prototypes are strict 2.0.77 mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local mock = dofile(here .. "/factorio_api_mock.lua")
_G.storage, _G.game = {}, { tick = 1 }
_G.defines = { inventory = { character_main = 1, character_armor = 5 } }

-- Equipment and armor prototypes.
local function equipment_proto(name, w, h, kind)
  return mock.equipment_prototype({ name = name, type = kind, shape = { width = w, height = h } })
end
local equipment = {
  ["exoskeleton-equipment"] = equipment_proto("exoskeleton-equipment", 2, 4, "movement-bonus-equipment"),
  ["solar-panel-equipment"] = equipment_proto("solar-panel-equipment", 1, 1, "solar-panel-equipment"),
  ["battery-equipment"] = equipment_proto("battery-equipment", 1, 2, "battery-equipment"),
  ["personal-roboport-equipment"] = equipment_proto("personal-roboport-equipment", 2, 2, "roboport-equipment"),
  ["toolbelt-equipment"] = equipment_proto("toolbelt-equipment", 2, 1, "inventory-bonus-equipment"),
}
local slot_bonus = { ["toolbelt-equipment"] = 10 }
local items = {}
for name, proto in pairs(equipment) do
  items[name] = mock.item_prototype({ name = name, type = "item", place_as_equipment_result = proto })
  mock.read(proto, "take_result", function() return items[name] end)
end
local grid_proto = {}
items["modular-armor"] = mock.item_prototype({ name = "modular-armor", type = "armor", equipment_grid = grid_proto,
  get_inventory_size_bonus = function() return 10 end })
items["heavy-armor"] = mock.item_prototype({ name = "heavy-armor", type = "armor",
  get_inventory_size_bonus = function() return 5 end })
items["iron-plate"] = mock.item_prototype({ name = "iron-plate", type = "item" })
_G.prototypes = { item = items }

-- A 5 x 5 grid that keeps what is put in it.
local function new_grid()
  local placed = {}
  local grid = mock.equipment_grid({ width = 5, height = 5, inventory_bonus = 0, battery_capacity = 0,
    available_in_batteries = 0, max_solar_energy = 0 })
  local function cells(eq)
    local out = {}
    for dy = 0, eq.shape.height - 1 do
      for dx = 0, eq.shape.width - 1 do out[#out + 1] = (eq.position.x + dx) .. "," .. (eq.position.y + dy) end
    end
    return out
  end
  mock.read(grid, "equipment", function() local out = {}; for i, eq in ipairs(placed) do out[i] = eq end; return out end)
  mock.read(grid, "movement_bonus", function()
    local n = 0
    for _, eq in ipairs(placed) do if eq.name == "exoskeleton-equipment" then n = n + 0.3 end end
    return n
  end)
  grid.put = function(args)
    assert(args.by_player == nil, "equipment is never put for a player")
    local proto = equipment[args.name]
    local p = args.position
    if p.x + proto.shape.width > 5 or p.y + proto.shape.height > 5 then return nil end
    local taken = {}
    for _, eq in ipairs(placed) do for _, cell in ipairs(cells(eq)) do taken[cell] = true end end
    local eq = mock.equipment({ name = args.name, position = { x = p.x, y = p.y },
      shape = { width = proto.shape.width, height = proto.shape.height }, prototype = proto,
      inventory_bonus = slot_bonus[args.name] or 0 })
    for _, cell in ipairs(cells(eq)) do if taken[cell] then return nil end end
    placed[#placed + 1] = eq
    return eq
  end
  grid.find = function(name) for _, eq in ipairs(placed) do if eq.name == name then return eq end end end
  grid.get = function(p)
    for _, eq in ipairs(placed) do for _, cell in ipairs(cells(eq)) do if cell == p.x .. "," .. p.y then return eq end end end
  end
  grid.take = function(args)
    assert(args.by_player == nil, "equipment is never taken for a player")
    for i, eq in ipairs(placed) do
      if eq == args.equipment then table.remove(placed, i); return { name = eq.name, count = 1, quality = "normal" } end
    end
  end
  return grid
end

-- Stacks: swap_stack exchanges contents.
local FIELDS = { "valid_for_read", "name", "count", "prototype", "grid" }
local function stack(name, count)
  local s = mock.item_stack({ valid_for_read = name ~= nil, name = name, count = count or (name and 1 or 0),
    prototype = name and items[name] or nil })
  s.swap_stack = function(other)
    for _, field in ipairs(FIELDS) do s[field], other[field] = other[field], s[field] end
    return true
  end
  s.create_grid = function() s.grid = new_grid(); return s.grid end
  return s
end
local function slots(n)
  local values = {}
  for i = 1, n do values[i] = stack(nil) end
  local inv = mock.inventory(values)
  mock.length(inv, function() return n end)
  inv.find_item_stack = function(name)
    for i = 1, n do if inv[i].valid_for_read and inv[i].name == name then return inv[i], i end end
  end
  return inv
end
local main, worn = slots(20), slots(1)

local body = { valid = true }
function body.get_main_inventory() return main end
function body.get_inventory(id) return id == defines.inventory.character_armor and worn or nil end
-- Equipment of another quality: a bare-name count includes it, a
-- normal-quality removal never takes it.
local uncommon = {}
function body.get_item_count(name)
  local n = uncommon[name] or 0
  for i = 1, #main do if main[i].valid_for_read and main[i].name == name then n = n + main[i].count end end
  return n
end
function body.insert(s)
  for i = 1, #main do if main[i].valid_for_read and main[i].name == s.name then main[i].count = main[i].count + s.count; return s.count end end
  for i = 1, #main do
    if not main[i].valid_for_read then
      main[i].valid_for_read, main[i].name, main[i].count, main[i].prototype = true, s.name, s.count, items[s.name]
      return s.count
    end
  end
  return 0
end
function body.can_insert(s)
  for i = 1, #main do if not main[i].valid_for_read or main[i].name == s.name then return true end end
  return false
end
function body.remove_item(s)
  assert(s.quality == "normal", "equipment is taken from the inventory at normal quality")
  for i = 1, #main do
    if main[i].valid_for_read and main[i].name == s.name then
      main[i].count = main[i].count - s.count
      if main[i].count <= 0 then main[i].valid_for_read, main[i].name, main[i].prototype = false, nil, nil end
      return s.count
    end
  end
  return 0
end

package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
local supplies = {}
package.loaded["scripts.actions.supply"] = { resume = function() end,
  ensure = function(_, needs) supplies[#supplies + 1] = needs; return { status = "done" } end }
package.loaded["scripts.actions.craft"] = { awaits = function() return false end }
local equip = require("scripts.actions.equip")

local function run(step)
  equip.action.validate(step, 1)
  local task = equip.action.make_task(step)
  task.id = 9
  equip.action.runner.start(task)
  return equip.action.runner.tick(task)
end

for _, name in ipairs({ "modular-armor", "exoskeleton-equipment", "personal-roboport-equipment", "battery-equipment" }) do
  body.insert({ name = name, count = 1 })
end
body.insert({ name = "solar-panel-equipment", count = 2 })
local suit = run({ action = "equip", armor = "modular-armor", put = { { name = "exoskeleton-equipment" },
  { name = "solar-panel-equipment" }, { name = "solar-panel-equipment" }, { name = "battery-equipment" },
  { name = "personal-roboport-equipment" } } })
check(suit.status == "done" and suit.outcome.armor == "modular-armor" and worn[1].name == "modular-armor"
  and #suit.outcome.grid.equipment == 5 and suit.outcome.grid.movement_bonus > 0,
  "modular armor is worn and its grid lists the five pieces")
check(body.get_item_count("modular-armor") == 0 and body.get_item_count("exoskeleton-equipment") == 0
  and body.get_item_count("solar-panel-equipment") == 0 and body.get_item_count("battery-equipment") == 0
  and body.get_item_count("personal-roboport-equipment") == 0, "the inventory lost exactly those items")
check(#supplies == 0, "carried items need no supply")

local back = run({ action = "equip", take = { { name = "battery-equipment" } } })
check(back.status == "done" and body.get_item_count("battery-equipment") == 1 and #back.outcome.grid.equipment == 4,
  "take returns the battery to the inventory")
local cell = run({ action = "equip", take = { { x = 0, y = 0 } } })
check(cell.status == "done" and body.get_item_count("exoskeleton-equipment") == 1, "take by cell takes what covers it")

body.insert({ name = "exoskeleton-equipment", count = 2 })
local crowded = run({ action = "equip", put = { { name = "exoskeleton-equipment" }, { name = "exoskeleton-equipment" },
  { name = "exoskeleton-equipment" } } })
local codes = {}
for _, p in ipairs(crowded.outcome.problems or {}) do codes[#codes + 1] = p.code end
check(crowded.status == "partial" and codes[1] == "EQUIPMENT_DOES_NOT_FIT"
  and body.get_item_count("exoskeleton-equipment") == #codes, "an exoskeleton that does not fit stays in the inventory")

-- An armor with fewer slots while the last ones are full: refused, nothing changes.
body.insert({ name = "heavy-armor", count = 1 })
main[20].valid_for_read, main[20].name, main[20].count, main[20].prototype = true, "iron-plate", 50, items["iron-plate"]
local overflow = run({ action = "equip", armor = "heavy-armor" })
check(overflow.status == "failed" and overflow.outcome.code == "INVENTORY_WOULD_OVERFLOW" and worn[1].name == "modular-armor",
  "an armor change that would lose occupied slots is refused")
local no_grid = run({ action = "equip", armor = "heavy-armor", put = { { name = "battery-equipment" } } })
check(no_grid.outcome.code == "NO_GRID" and worn[1].name == "modular-armor", "equipment for an armor without a grid is NO_GRID")
body.remove_item({ name = "iron-plate", count = 50, quality = "normal" })
local swapped = run({ action = "equip", armor = "heavy-armor" })
check(swapped.status == "done" and worn[1].name == "heavy-armor" and body.get_item_count("modular-armor") == 1
  and main.find_item_stack("modular-armor").grid ~= nil, "the old armor, with its equipment, takes the new one's slot")
local off = run({ action = "equip", armor = false })
check(off.status == "done" and not worn[1].valid_for_read and body.get_item_count("heavy-armor") == 1 and off.outcome.armor == false,
  "armor false takes the armor off into the inventory")

-- Not carried: auto-supply is asked once; nothing is made.
local again = run({ action = "equip", armor = "modular-armor" })
check(#supplies == 0 and again.status == "done" and #again.outcome.grid.equipment > 0,
  "the carried armor is worn again with its equipment, without supply")
local none = run({ action = "equip", put = { { name = "personal-roboport-equipment" } } })
check(none.status == "failed" and none.outcome.code == "NOT_CARRIED" and #supplies == 1 and supplies[1][1].name == "personal-roboport-equipment"
  and none.outcome.problems[1].code == "NOT_CARRIED", "a missing piece is asked of supply once and named when still missing")

-- Only an uncommon piece carried: nothing goes in, nothing is made.
uncommon["battery-equipment"] = 1
while body.get_item_count("battery-equipment") > 1 do body.remove_item({ name = "battery-equipment", count = 1, quality = "normal" }) end
local before_pieces = #again.outcome.grid.equipment
local rare = run({ action = "equip", put = { { name = "battery-equipment" } }, auto_supply = false })
check(rare.status == "failed" and rare.outcome.code == "NOT_CARRIED" and #worn[1].grid.equipment == before_pieces
  and uncommon["battery-equipment"] == 1, "a piece carried only at another quality is NOT_CARRIED and no free one appears")
uncommon["battery-equipment"] = nil

-- A toolbelt adds 10 slots: taking it out while the last ones are full is refused.
body.insert({ name = "toolbelt-equipment", count = 1 })
local belt = run({ action = "equip", put = { { name = "toolbelt-equipment" } } })
check(belt.status == "done" and worn[1].grid.find("toolbelt-equipment") ~= nil, "the toolbelt goes into the grid")
main[20].valid_for_read, main[20].name, main[20].count, main[20].prototype = true, "iron-plate", 50, items["iron-plate"]
local spill = run({ action = "equip", take = { { name = "toolbelt-equipment" } } })
check(spill.status == "failed" and spill.outcome.code == "INVENTORY_WOULD_OVERFLOW" and spill.outcome.problems[1].slots == 10
  and worn[1].grid.find("toolbelt-equipment") ~= nil and main[20].count == 50,
  "taking a toolbelt out over occupied last slots is refused and nothing moves")
body.remove_item({ name = "iron-plate", count = 50, quality = "normal" })
local unbelted = run({ action = "equip", take = { { name = "toolbelt-equipment" } } })
check(unbelted.status == "done" and body.get_item_count("toolbelt-equipment") == 1
  and worn[1].grid.find("toolbelt-equipment") == nil, "with the last slots free the toolbelt comes out")

local function refused(step, pattern)
  local ok, err = pcall(equip.action.validate, step, 2)
  return not ok and tostring(err):match(pattern) ~= nil
end
check(refused({ armor = "iron-plate" }, "armor must be an armor"), "a non-armor is refused")
check(refused({ put = { { name = "iron-plate" } } }, "equipment item"), "a non-equipment put is refused")
check(refused({ take = { { name = "battery-equipment", x = 1, y = 1 } } }, "{name} or {x, y}"), "a take names one way")
check(refused({}, "needs armor, put or take"), "an empty equip is refused")

mock.assert_clean()
print(failures == 0 and "\nALL EQUIP TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
