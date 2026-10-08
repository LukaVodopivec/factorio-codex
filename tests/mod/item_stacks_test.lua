-- Offline tests for real item stacks (items.move, items.move_stacks) through
-- insert_items and extract_items (actions/transfer.lua, which upkeep's lab
-- feeding also runs): a partly used science pack, a half-spoiled stack, a
-- quality item and a move across several stacks keep what they are, and what
-- a target gains is exactly what left the source. Also safe spills
-- (items.spill): never for robots, never onto a belt, reported.
-- Inventories and stacks are strict 2.0.77 mocks (item_stack_mock).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local stacks = dofile(here .. "/item_stack_mock.lua")
_G.storage, _G.game = {}, { tick = 1, create_inventory = stacks.create_inventory }
_G.defines = { inventory = { chest = 1, lab_input = 2, character_ammo = 4, character_trash = 8 } }
_G.prototypes = { item = { ["automation-science-pack"] = {}, yumako = {}, ["iron-plate"] = {}, coal = {},
  ["firearm-magazine"] = {} } }
stacks.stack_sizes = { ["automation-science-pack"] = 200, yumako = 50, ["iron-plate"] = 100, coal = 50,
  ["firearm-magazine"] = 200 }
stacks.max_durability["automation-science-pack"] = 1
stacks.magazine["firearm-magazine"] = 10

local main, ammo = stacks.inventory(10), stacks.inventory(3)
local body = { valid = true, reach_distance = 10, force = { name = "player" } }
function body.get_main_inventory() return main end
function body.get_inventory(id) return id == defines.inventory.character_ammo and ammo or nil end
function body.get_item_count(item) return main.get_item_count(item) end
function body.insert() error("moves use the main inventory's own stacks") end
function body.remove_item() error("moves never remove by name") end

local target
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end, ensure_entity = function() return "ok" end,
  find_entity_near = function() return target end }
package.loaded["scripts.actions.supply"] = { register_runner = function() end, resume = function() end }
package.loaded["scripts.actions.craft"] = { awaits = function() return false end }
package.loaded["scripts.factory_activity"] = { record = function() end }
local transfer = require("scripts.actions.transfer")
local items = require("scripts.items")

local function run(runner, task)
  runner.start(task)
  return runner.tick(task)
end
local function reset_main()
  main, ammo = stacks.inventory(10), stacks.inventory(3)
  stacks.created, stacks.destroyed = 0, 0
end
-- An entity that routes inserts into one inventory, as a lab or chest does.
local function holder(name, kind, inventory, extra)
  local e = { valid = true, name = name, type = kind, force = body.force, position = { x = 3, y = 3 } }
  e.insert = function(stack) return inventory.insert(stack) end
  e.get_output_inventory = function() return nil end
  e.get_inventory = function(id) return id == defines.inventory.chest and kind == "container" and inventory or nil end
  for key, value in pairs(extra or {}) do e[key] = value end
  return e
end

-- A partly used science pack: the lab gets that very pack, used as it was.
reset_main()
stacks.put(main, 1, { name = "automation-science-pack", count = 10, durability = 0.4 })
local before = stacks.durability(main[1])
local lab_input = stacks.inventory(1)
target = holder("lab", "lab", lab_input)
local fed = run(transfer.insert, { target = { x = 3, y = 3 }, items = { ["automation-science-pack"] = 10 }, auto_supply = false })
check(fed.status == "done" and fed.outcome.total_inserted == 10 and lab_input[1].count == 10
  and math.abs(lab_input[1].durability - 0.4) < 1e-9 and not main[1].valid_for_read,
  "a partly used science pack reaches the lab with its durability, not as a fresh pack")
check(math.abs(stacks.durability(lab_input[1]) - before) < 1e-9, "the science the lab got is exactly what the body carried")
-- Part of that stack: whole packs move, the used one stays, no science is made.
reset_main()
stacks.put(main, 1, { name = "automation-science-pack", count = 10, durability = 0.4 })
lab_input = stacks.inventory(1)
target = holder("lab", "lab", lab_input)
local part = run(transfer.insert, { target = { x = 3, y = 3 }, items = { ["automation-science-pack"] = 4 }, auto_supply = false })
check(part.status == "done" and lab_input[1].count == 4 and main[1].count == 6
  and math.abs(stacks.durability(lab_input[1], main[1]) - before) < 1e-9,
  "part of a used stack moves whole packs and the total science left in both is unchanged")
check(stacks.created == 1 and stacks.destroyed == 1, "the split's one-slot buffer is made once and destroyed")

-- A half-spoiled stack: what leaves the chest is as spoiled as it was.
reset_main()
local chest = stacks.inventory(4)
stacks.put(chest, 1, { name = "yumako", count = 20, spoil_percent = 0.5 })
target = holder("wooden-chest", "container", chest)
local fruit = run(transfer.extract, { target = { x = 3, y = 3 }, items = { yumako = 5 } })
check(fruit.status == "done" and fruit.outcome.total_extracted == 5 and main[1].count == 5
  and main[1].spoil_percent == 0.5 and chest[1].count == 15 and chest[1].spoil_percent == 0.5,
  "a half-spoiled stack moves half-spoiled; nothing comes out fresh")
-- Into the body's own fresher fruit, the spoil averages as the game merges it.
stacks.put(main, 1, { name = "yumako", count = 5, spoil_percent = 0 })
run(transfer.extract, { target = { x = 3, y = 3 }, items = { yumako = 5 } })
check(main[1].count == 10 and math.abs(main[1].spoil_percent - 0.25) < 1e-9 and chest[1].count == 10,
  "spoil merges by count into a stack the body already carried")

-- A quality item: an all-extraction moves each quality as itself, and a named
-- item is its normal quality only.
reset_main()
chest = stacks.inventory(4)
stacks.put(chest, 1, { name = "iron-plate", count = 7, quality = "rare" })
stacks.put(chest, 2, { name = "iron-plate", count = 3 })
target = holder("wooden-chest", "container", chest)
local named = run(transfer.extract, { target = { x = 3, y = 3 }, items = { ["iron-plate"] = 5 } })
check(named.status == "done" and named.outcome.total_extracted == 3 and chest[1].count == 7
  and main.get_item_count({ name = "iron-plate", quality = "rare" }) == 0
  and main.get_item_count({ name = "iron-plate", quality = "normal" }) == 3,
  "a named extraction takes normal plates only and never a rare one as normal")
local all = run(transfer.extract, { target = { x = 3, y = 3 }, all = true })
check(all.status == "done" and all.outcome.total_extracted == 7 and all.outcome.transfers[1].quality == "rare"
  and main.get_item_count({ name = "iron-plate", quality = "rare" }) == 7 and chest.is_empty()
  and all.detail:match("7 iron%-plate@rare"),
  "an all-extraction moves the rare plates as rare plates and names their quality")
-- A full extraction that cannot fit hands back each quality as itself.
chest = stacks.inventory(4)
stacks.put(chest, 1, { name = "iron-plate", count = 60, quality = "rare" })
stacks.put(chest, 2, { name = "coal", count = 50, spoil_percent = 0 })
target = holder("wooden-chest", "container", chest)
main = stacks.inventory(1)
local refused = run(transfer.extract, { target = { x = 3, y = 3 }, all = true })
check(refused.status == "failed" and chest.get_item_count({ name = "iron-plate", quality = "rare" }) == 60
  and chest.get_item_count("coal") == 50 and main.is_empty(),
  "a refused full extraction restores the rare plates as rare plates")

-- A move across several stacks: the count is what left those stacks.
reset_main()
stacks.put(main, 1, { name = "coal", count = 50 })
stacks.put(main, 2, { name = "coal", count = 50 })
stacks.put(main, 3, { name = "coal", count = 20 })
chest = stacks.inventory(4)
target = holder("wooden-chest", "container", chest)
local spread = run(transfer.insert, { target = { x = 3, y = 3 }, items = { coal = 110 }, auto_supply = false })
check(spread.status == "done" and spread.outcome.total_inserted == 110 and chest.get_item_count("coal") == 110
  and main.get_item_count("coal") == 10 and not main[1].valid_for_read and not main[2].valid_for_read
  and main[3].count == 10, "an insert across several stacks moves 110 and the body keeps the last 10")
-- A target that takes fewer than offered: the rest goes back where it was.
chest = stacks.inventory(1)
target = holder("wooden-chest", "container", chest)
stacks.put(main, 1, { name = "coal", count = 50 })
local capped = run(transfer.insert, { target = { x = 3, y = 3 }, items = { coal = 60 }, auto_supply = false })
check(capped.status == "partial" and capped.outcome.total_inserted == 50 and chest.get_item_count("coal") == 50
  and main.get_item_count("coal") == 10, "a full target takes 50 of 60 and the body keeps exactly the other 10")

-- A partly used magazine keeps its rounds.
reset_main()
stacks.put(main, 1, { name = "firearm-magazine", count = 5, ammo = 3 })
local turret_ammo = stacks.inventory(1)
target = holder("gun-turret", "ammo-turret", turret_ammo)
run(transfer.insert, { target = { x = 3, y = 3 }, items = { ["firearm-magazine"] = 5 }, auto_supply = false })
check(turret_ammo[1].count == 5 and turret_ammo[1].ammo == 3, "a partly used magazine reaches the turret with its rounds")

-- Magazines in the body's ammo slot are stock too (get_item_count, and so
-- upkeep, counts them): an insert hands them over after the main inventory's.
reset_main()
stacks.put(main, 1, { name = "firearm-magazine", count = 2 })
stacks.put(ammo, 1, { name = "firearm-magazine", count = 6, ammo = 4 })
turret_ammo = stacks.inventory(1)
target = holder("gun-turret", "ammo-turret", turret_ammo)
local loaded = run(transfer.insert, { target = { x = 3, y = 3 }, items = { ["firearm-magazine"] = 5 }, auto_supply = false })
check(loaded.status == "done" and loaded.outcome.total_inserted == 5 and turret_ammo.get_item_count("firearm-magazine") == 5
  and main.is_empty() and ammo.get_item_count("firearm-magazine") == 3 and ammo[1].ammo == 4,
  "an insert takes the main inventory's magazines, then whole ones from the ammo slot")

-- Without a role, a named extraction reaches every inventory the entity
-- has, as entity.remove_item did: a turret's ammo has no role.
reset_main()
turret_ammo = stacks.inventory(1)
stacks.put(turret_ammo, 1, { name = "firearm-magazine", count = 8 })
target = holder("gun-turret", "ammo-turret", turret_ammo, {
  get_max_inventory_index = function() return 1 end,
  get_inventory = function(id) return id == 1 and turret_ammo or nil end })
local unloaded = run(transfer.extract, { target = { x = 3, y = 3 }, items = { ["firearm-magazine"] = 3 } })
check(unloaded.status == "done" and unloaded.outcome.total_extracted == 3 and turret_ammo[1].count == 5
  and main.get_item_count("firearm-magazine") == 3, "a named extraction takes magazines out of a gun turret")

-- A target whose insert raises: the held part goes back to its source and
-- the one-slot buffer is still destroyed.
reset_main()
stacks.put(main, 1, { name = "coal", count = 10 })
local broken = { insert = function() error("insert failed") end }
local raised = pcall(items.move, main, broken, "coal", "normal", 5)
check(not raised and main.get_item_count("coal") == 10 and main[1].count == 10
  and stacks.created == 1 and stacks.destroyed == 1,
  "a move that raises returns the held items to the source and destroys its buffer")

-- A source that ignores the split (as a belt stack might) still loses
-- exactly what the target gained: the difference is removed by name.
local into = stacks.inventory(2)
local frozen = stacks.view(setmetatable({}, {
  __index = function() return 4 end,
  __newindex = function() end,
  __pairs = function() return next, { ["iron-plate"] = 4 }, nil end,
}))
local removed = 0
local ignored = items.move_stacks({ frozen[1] }, into, "iron-plate", nil, 3, {
  remove = function(stack) removed = removed + stack.count; return stack.count end,
  put_back = function() return 0 end })
check(ignored == 3 and into.get_item_count("iron-plate") == 3 and removed == 3 and frozen[1].count == 4,
  "a source whose count did not drop gives up the difference by name, so nothing is created")

-- Spills: no force (no deconstruction order, no robots), never onto a belt,
-- and the count and position are reported.
local calls = {}
local surface = { spill_item_stack = function(args) calls[#calls + 1] = args; return {} end }
local record = {}
local spilled = items.spill(surface, { x = 1.5, y = -2 }, { name = "iron-plate", count = 4, quality = "rare" }, record)
local args = calls[1]
check(spilled == 4 and args and args.force == nil and args.allow_belts == false and args.position.x == 1.5
  and args.stack.count == 4 and args.enable_looted == nil,
  "a spill passes no force and allow_belts = false")
check(record.count == 4 and record.items["iron-plate@rare"] == 4 and record.position.x == 1.5 and record.position.y == -2,
  "a spill reports its count, items by quality and position")
surface.spill_item_stack = function() error("no room") end
check(items.spill(surface, { x = 0, y = 0 }, { name = "coal", count = 2 }, record) == 0 and record.count == 4,
  "a failed spill reports nothing spilled")
for _, file in ipairs({ "actions/build.lua", "actions/build_plan.lua", "actions/tiles.lua", "actions/transfer.lua",
  "actions/equip.lua", "actions/area_ops.lua", "actions/pickup.lua" }) do
  local source = assert(io.open(here .. "/../../mod/agentic-companion/scripts/" .. file)):read("a")
  check(not source:find("spill_item_stack", 1, true), file .. " spills only through items.spill")
end

stacks.assert_clean()
if failures > 0 then print(failures .. " ITEM STACK TEST(S) FAILED"); os.exit(1) end
print("ALL ITEM STACK TESTS PASSED")
