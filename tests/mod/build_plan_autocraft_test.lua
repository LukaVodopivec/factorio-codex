-- Offline tests for build_plan's automatic preparation of placeable items.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

local crafted = {}
local inventory = { ["transport-belt"] = 1 }
local character
character = {
  crafting_queue_size = 0,
  force = { recipes = {
    ["transport-belt"] = { name = "transport-belt", enabled = true },
    ["burner-mining-drill"] = { name = "burner-mining-drill", enabled = true },
  } },
  get_item_count = function(name) return inventory[name] or 0 end,
  begin_crafting = function(args)
    crafted[args.recipe] = args.count
    character.crafting_queue_size = character.crafting_queue_size + args.count
    return args.count
  end,
}

package.loaded["scripts.companion"] = {
  require_companion = function() return character end,
  get = function() return character end,
}
local approach_stub = { ensure = function() return nil end }
package.loaded["scripts.actions.approach"] = approach_stub
_G.prototypes = { item = {} }

local build_plan = require("scripts.actions.build_plan")
local task = { steps = {
  { item = "transport-belt", position = { x = 0, y = 0 } },
  { item = "transport-belt", position = { x = 1, y = 0 } },
  { item = "transport-belt", position = { x = 2, y = 0 } },
  { item = "burner-mining-drill", position = { x = 3, y = 0 } },
} }
build_plan.start(task)
check(crafted["transport-belt"] == 2 and crafted["burner-mining-drill"] == 1,
  "build_plan: crafts exactly the missing placeable items")
check(task._waiting_for_crafts == true and task._auto_crafted == 3,
  "build_plan: construction waits for its preparation queue")

crafted = {}
character.crafting_queue_size = 0
build_plan.start({ auto_craft = false, steps = {
  { item = "transport-belt", position = { x = 0, y = 0 } },
  { item = "transport-belt", position = { x = 1, y = 0 } },
} })
check(next(crafted) == nil, "build_plan: auto-crafting can be disabled")

local too_many = {}
for i = 1, 26 do too_many[i] = { item = "transport-belt", position = { x = i, y = 0 } } end
local accepted, limit_error = pcall(build_plan.start, { steps = too_many })
check(not accepted and tostring(limit_error):match("at most 25 steps") ~= nil,
  "build_plan: Lua rejects more than 25 steps")

local fail_fast = { auto_craft = false, steps = {
  { item = "missing-item", position = { x = 0, y = 0 } },
  { item = "transport-belt", position = { x = 1, y = 0 } },
} }
build_plan.start(fail_fast)
local failure = build_plan.tick(fail_fast)
check(fail_fast.stop_on_error == true and failure and failure.status == "failed" and fail_fast._index == 2,
  "build_plan: omitted stop_on_error fails at the first bad step")

local placed_name
inventory["transport-belt"] = 1
character.build_distance = 6
character.surface = {
  can_place_entity = function(args) placed_name = args.name return true end,
  create_entity = function(args) return { valid = true, name = args.name, type = "transport-belt" } end,
}
character.remove_item = function(args) inventory[args.name] = inventory[args.name] - args.count end
approach_stub.ensure = function() return "ok" end
_G.defines = { build_check_type = { manual = 1 } }
prototypes.item["transport-belt"] = { place_result = { name = "transport-belt" } }
local retained_contract = { auto_craft = false, steps = {
  { item = "transport-belt", entity = "forbidden-blueprint-override", position = { x = 4, y = 5 } },
} }
build_plan.start(retained_contract)
local placed = build_plan.tick(retained_contract)
check(placed and placed.status == "done" and placed_name == "transport-belt",
  "build_plan: placement always uses the item's place_result and ignores removed entity overrides")

inventory["assembling-machine-1"] = 1
character.force.recipes["iron-gear-wheel"] = { name = "iron-gear-wheel", enabled = true }
prototypes.item["assembling-machine-1"] = { place_result = { name = "assembling-machine-1" } }
character.surface.create_entity = function(args)
  return {
    valid = true, name = args.name, type = "assembling-machine",
    set_recipe = function() return {} end,
    get_recipe = function() return nil end,
  }
end
local incompatible_plan = { auto_craft = false, steps = {
  { item = "assembling-machine-1", position = { x = 6, y = 0 }, recipe = "iron-gear-wheel" },
} }
build_plan.start(incompatible_plan)
local incompatible = build_plan.tick(incompatible_plan)
check(incompatible and incompatible.status == "failed"
  and incompatible.detail:match("probably can't craft it") ~= nil,
  "build_plan: rejects a non-throwing incompatible machine recipe")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
