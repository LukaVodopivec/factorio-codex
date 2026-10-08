-- Offline tests for inventory roles (inventory_roles.lua) in extract_items
-- and insert_items, and for flush_fluid (actions/transfer.lua): a role names
-- one inventory by the entity's type through non-deprecated defines, a
-- missing one is INVENTORY_NOT_PRESENT listing the roles the entity has,
-- other inventories are untouched; without a role behaviour is unchanged.
-- flush_fluid empties each fluidbox's system of pipes and tanks only.
-- Entities and inventories are strict 2.0.77 mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local mock = dofile(here .. "/factorio_api_mock.lua")
local stacks = dofile(here .. "/item_stack_mock.lua")
_G.storage, _G.game = {}, { tick = 1, create_inventory = stacks.create_inventory }
_G.defines = { inventory = { chest = 1, fuel = 1, crafter_input = 2, crafter_output = 3, crafter_modules = 4,
  crafter_trash = 5, assembling_machine_dump = 6, burnt_result = 6, lab_input = 2, roboport_robot = 1,
  roboport_material = 2, logistic_container_trash = 2 } }
_G.prototypes = { item = { coal = {}, ["iron-ore"] = {}, ["iron-plate"] = {}, ["speed-module"] = {} },
  fluid = { ["crude-oil"] = {}, water = {} } }

-- The body: a plain character whose main inventory keeps what it is given;
-- items move as real stacks (item_stack_mock), one per name over these counts.
local held = {}
local body = { valid = true, reach_distance = 10 }
function body.get_item_count(name) return held[type(name) == "table" and name.name or name] or 0 end
local function main_view() return stacks.view(held) end
body.get_main_inventory = main_view
local own = { name = "player" }
body.force = own

local function inventory(contents)
  return stacks.view(contents), contents
end

local target
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end, ensure_entity = function() return "ok" end,
  find_entity_near = function() return target end }
package.loaded["scripts.actions.supply"] = { register_runner = function() end, resume = function() end }
package.loaded["scripts.actions.craft"] = { awaits = function() return false end }
package.loaded["scripts.factory_activity"] = { record = function() end }
local transfer = require("scripts.actions.transfer")

local function run(runner, task)
  runner.start(task)
  return runner.tick(task)
end

-- A furnace: fuel, input and output by role; robots it does not have.
local fuel, fuel_held = inventory({ coal = 5 })
local source, source_held = inventory({ ["iron-ore"] = 10 })
local result_inv, result_held = inventory({ ["iron-plate"] = 10 })
local furnace = mock.entity({ valid = true, name = "stone-furnace", type = "furnace", force = own, position = { x = 0, y = 0 },
  get_fuel_inventory = function() return fuel end, get_output_inventory = function() return result_inv end,
  get_burnt_result_inventory = function() return nil end, get_module_inventory = function() return nil end,
  get_inventory = function(id) return id == defines.inventory.crafter_input and source or nil end })
target = furnace
local took = run(transfer.extract, { target = { x = 0, y = 0 }, all = true, inventory = "fuel" })
check(took.status == "done" and held.coal == 5 and fuel_held.coal == 0 and result_held["iron-plate"] == 10
  and source_held["iron-ore"] == 10 and took.outcome.inventory == "fuel",
  "extract inventory fuel empties only the fuel")
local input = run(transfer.extract, { target = { x = 0, y = 0 }, items = { ["iron-ore"] = 4 }, inventory = "input" })
check(input.status == "done" and held["iron-ore"] == 4 and source_held["iron-ore"] == 6 and result_held["iron-plate"] == 10,
  "extract inventory input takes the named items from the input only")
local default = run(transfer.extract, { target = { x = 0, y = 0 }, all = true })
check(default.status == "done" and held["iron-plate"] == 10 and source_held["iron-ore"] == 6 and default.outcome.inventory == nil,
  "without a role extract empties the output, as before")
local missing = run(transfer.extract, { target = { x = 0, y = 0 }, all = true, inventory = "robots" })
check(missing.status == "failed" and missing.outcome.code == "INVENTORY_NOT_PRESENT"
  and table.concat(missing.outcome.present, ",") == "input,output,fuel",
  "a role the furnace lacks is INVENTORY_NOT_PRESENT, listing the roles it has")
check(not pcall(transfer.extract.start, { target = { x = 0, y = 0 }, all = true, inventory = "furnace_source" }),
  "an unknown role is refused at start")

-- A burner drill: its output getter returns the fuel inventory, which is fuel
-- only, so an output extraction never takes the drill's reserve fuel.
local drill_fuel, drill_fuel_held = inventory({ wood = 4 })
local drill = mock.entity({ valid = true, name = "burner-mining-drill", type = "mining-drill", force = own,
  position = { x = 9, y = 9 }, get_fuel_inventory = function() return drill_fuel end,
  get_output_inventory = function() return drill_fuel end, get_burnt_result_inventory = function() return nil end,
  get_module_inventory = function() return nil end, get_inventory = function() return nil end })
local roles = require("scripts.inventory_roles")
check(table.concat(roles.present(drill), ",") == "fuel" and #roles.get(drill, "output") == 0,
  "a burner drill's fuel inventory is listed once, as fuel, never as output")
target = drill
local wrong = run(transfer.extract, { target = { x = 9, y = 9 }, all = true, inventory = "output" })
check(wrong.status == "failed" and wrong.outcome.code == "INVENTORY_NOT_PRESENT" and drill_fuel_held.wood == 4,
  "extracting a burner drill's output leaves its reserve fuel in place")
local plain = run(transfer.extract, { target = { x = 9, y = 9 }, all = true })
check(plain.status == "failed" and drill_fuel_held.wood == 4,
  "a default extract from a burner drill takes nothing, never its fuel")
drill.get_output_inventory = function() return nil end
drill.get_inventory = function(id) return id == 1 and drill_fuel or nil end
local by_index = run(transfer.extract, { target = { x = 9, y = 9 }, all = true })
check(by_index.status == "failed" and drill_fuel_held.wood == 4,
  "a default extract never reads fuel through the shared chest/fuel inventory index")

-- An assembler: modules by role; insert into the module inventory; trash is two.
local modules, modules_held = inventory({ ["speed-module"] = 2 })
local trash, trash_held = inventory({ coal = 1 })
local dump, dump_held = inventory({ coal = 2 })
local machine_input, machine_input_held = inventory({ ["iron-plate"] = 4 })
local assembler = mock.entity({ valid = true, name = "assembling-machine-2", type = "assembling-machine", force = own,
  position = { x = 5, y = 5 }, get_module_inventory = function() return modules end,
  get_fuel_inventory = function() return nil end, get_output_inventory = function() return nil end,
  get_burnt_result_inventory = function() return nil end,
  get_inventory = function(id)
    if id == defines.inventory.crafter_input then return machine_input end
    if id == defines.inventory.crafter_trash then return trash end
    if id == defines.inventory.assembling_machine_dump then return dump end
  end,
  insert = function() error("insert_items with a role must not route through the entity") end })
target = assembler
held = {}
local mods = run(transfer.extract, { target = { x = 5, y = 5 }, all = true, inventory = "modules" })
check(mods.status == "done" and held["speed-module"] == 2 and modules_held["speed-module"] == 0
  and machine_input_held["iron-plate"] == 4, "extract inventory modules empties the module slots only")
local trashed = run(transfer.extract, { target = { x = 5, y = 5 }, all = true, inventory = "trash" })
check(trashed.status == "done" and held.coal == 3 and trash_held.coal == 0 and dump_held.coal == 0,
  "an assembler's trash role empties its trash and dump")
local put = run(transfer.insert, { target = { x = 5, y = 5 }, items = { ["speed-module"] = 2 }, inventory = "modules",
  auto_supply = false })
check(put.status == "done" and modules_held["speed-module"] == 2 and held["speed-module"] == 0 and put.outcome.inventory == "modules",
  "insert inventory modules puts modules into the module slots")
-- Only normal quality is handed over by name: a rare module the body
-- carries stays with it, and the count inserted is what left the body.
local carried = stacks.inventory(4)
stacks.put(carried, 1, { name = "speed-module", count = 1, quality = "rare" })
body.get_main_inventory = function() return carried end
local rare = run(transfer.insert, { target = { x = 5, y = 5 }, items = { ["speed-module"] = 1 }, inventory = "modules",
  auto_supply = false })
check(rare.status == "failed" and modules_held["speed-module"] == 2 and carried[1].count == 1,
  "carrying no normal-quality module inserts nothing")
stacks.put(carried, 2, { name = "speed-module", count = 1 })
local short_give = run(transfer.insert, { target = { x = 5, y = 5 }, items = { ["speed-module"] = 2 }, inventory = "modules",
  auto_supply = false })
check(short_give.outcome.total_inserted == 1 and modules_held["speed-module"] == 3 and not carried[2].valid_for_read
  and carried[1].quality.name == "rare",
  "an insert of two carrying one normal module hands over that one and keeps the rare one")
body.get_main_inventory = main_view

-- flush_fluid: pipes and tanks only, every fluidbox of the entity.
local flushes = {}
local pipe = mock.entity({ valid = true, name = "pipe", type = "pipe", force = own, position = { x = 9.5, y = 0.5 },
  fluidbox = { [1] = { name = "crude-oil", amount = 100 },
    flush = function(index, fluid) flushes[#flushes + 1] = { index, fluid }; return { ["crude-oil"] = 500 } end } })
target = pipe
local flushed = run(transfer.flush, { target = { x = 9.5, y = 0.5 } })
check(flushed.status == "done" and flushed.outcome.flushed["crude-oil"] == 500 and #flushes == 1 and flushes[1][1] == 1
  and flushed.outcome.entity.name == "pipe", "flush_fluid flushes the pipe's system and reports the amount")
flushes = {}
run(transfer.flush, { target = { x = 9.5, y = 0.5 }, fluid = "water" })
check(flushes[1][2] == "water", "a named fluid is passed to the flush")
check(not pcall(transfer.flush.start, { target = { x = 9.5, y = 0.5 }, fluid = "lava-ish" }), "an unknown fluid is refused")
check(not pcall(transfer.flush_action.validate, { x = 1, y = 1, fluid = 5 }, 1)
  and pcall(transfer.flush_action.validate, { x = 1, y = 1 }, 1), "a flush_fluid step is validated at queue time")
target = mock.entity({ valid = true, name = "boiler", type = "boiler", force = own, position = { x = 0, y = 9 } })
local boiler = run(transfer.flush, { target = { x = 0, y = 9 } })
check(boiler.status == "failed" and boiler.outcome.code == "NOT_FLUSHABLE" and boiler.detail:match("mine the boiler"),
  "a boiler is NOT_FLUSHABLE, with how else to empty it")

mock.assert_clean()
print(failures == 0 and "\nALL INVENTORY ROLE TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
