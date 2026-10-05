-- Offline tests for build_plan's auto-supply of placeable items (hand-crafting
-- when no own stock holds them) and its bounded follow-up recoveries.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
_G.storage = {}
_G.game = { tick = 100 }
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

local crafted = {}
local inventory = { ["transport-belt"] = 0 }
local placed_count = 0
local followup_reachable = true
local followup_failure = false
local followup_reach_checks = 0
local character
character = {
  crafting_queue_size = 0, crafting_queue = {},
  force = { recipes = {
    ["transport-belt"] = { name = "transport-belt", enabled = true,
      products = { { type = "item", name = "transport-belt", amount = 2 } } },
    ["burner-mining-drill"] = { name = "burner-mining-drill", enabled = true,
      products = { { type = "item", name = "burner-mining-drill", amount = 1 } } },
    ["misleading-machine"] = { name = "misleading-machine", enabled = true,
      products = { { type = "item", name = "iron-plate", amount = 1 } } },
    ["uncertain-machine"] = { name = "uncertain-machine", enabled = true,
      products = { { type = "item", name = "uncertain-machine", amount = 3, probability = 0.5 } } },
  } },
  get_item_count = function(name) return inventory[type(name) == "table" and name.name or name] or 0 end,
  get_main_inventory = function() return { get_insertable_count = function() return 1000 end } end,
  begin_crafting = function(args)
    crafted[args.recipe] = (crafted[args.recipe] or 0) + args.count
    character.crafting_queue_size = character.crafting_queue_size + args.count
    character.crafting_queue[#character.crafting_queue + 1] = { index = #character.crafting_queue + 1,
      recipe = args.recipe, count = args.count, prerequisite = false }
    return args.count
  end,
  build_distance = 6,
  surface = {
    can_place_entity = function() return true end,
    create_entity = function(args)
      placed_count = placed_count + 1
      return { valid = true, name = args.name, type = "transport-belt" }
    end,
  },
  remove_item = function(args) inventory[args.name] = inventory[args.name] - args.count; return args.count end,
  can_reach_entity = function()
    followup_reach_checks = followup_reach_checks + 1
    return followup_reachable
  end,
}

package.loaded["scripts.companion"] = {
  require_companion = function() return character end,
  get = function() return character end,
}
local approach_stub = {
  ensure = function() return "ok" end,
  ensure_entity = function(_, c, built)
    if c.can_reach_entity(built) then return "ok" end
    if followup_failure then
      return { status = "failed", detail = "couldn't get within physical reach of the " .. built.name }
    end
    return nil
  end,
}
package.loaded["scripts.actions.approach"] = approach_stub
_G.prototypes = { item = {
  ["transport-belt"] = { place_result = { name = "transport-belt" } },
  ["burner-mining-drill"] = { place_result = { name = "burner-mining-drill" } },
  ["misleading-machine"] = { place_result = { name = "misleading-machine" } },
  ["uncertain-machine"] = { place_result = { name = "uncertain-machine" } },
} }
_G.defines = { build_check_type = { manual = 1 } }

local build_plan = require("scripts.actions.build_plan")
local task = { steps = {
  { item = "transport-belt", position = { x = 0, y = 0 } },
  { item = "transport-belt", position = { x = 1, y = 0 } },
} }
build_plan.start(task)
check(next(crafted) == nil and task._supply == nil,
  "build_plan: does not supply anything during start")
-- Supply runs one source scan a tick (holders, then belts), so the craft
-- starts a few ticks in.
local function tick_until(t, done)
  local result
  for _ = 1, 5 do result = build_plan.tick(t); if result or done() then break end end
  return result
end
check(tick_until(task, function() return crafted["transport-belt"] end) == nil and crafted["transport-belt"] == 1
  and placed_count == 0,
  "build_plan: one two-output recipe craft supplies both belts the plan needs")
check(build_plan.tick(task) == nil and placed_count == 0,
  "build_plan: construction waits for the real crafting queue")
inventory["transport-belt"] = 2
character.crafting_queue_size, character.crafting_queue = 0, {}
game.tick = game.tick + 30
check(build_plan.tick(task) == nil and placed_count == 1 and inventory["transport-belt"] == 1,
  "build_plan: places the current step only after crafting completes")
local two_belts = build_plan.tick(task)
check(two_belts and two_belts.status == "done" and placed_count == 2
  and inventory["transport-belt"] == 0 and crafted["transport-belt"] == 1,
  "build_plan: reuses multi-output surplus without another craft")

local wrong_product = { steps = {
  { item = "misleading-machine", position = { x = 0, y = 0 } },
} }
build_plan.start(wrong_product)
local wrong_product_failure = tick_until(wrong_product, function() return false end)
check(wrong_product_failure and wrong_product_failure.status == "failed"
  and wrong_product_failure.detail:match("does not produce requested item misleading%-machine")
  and crafted["misleading-machine"] == nil,
  "build_plan: refuses a recipe that does not produce the requested item")

local uncertain_product = { steps = {
  { item = "uncertain-machine", position = { x = 0, y = 0 } },
} }
build_plan.start(uncertain_product)
local uncertain_wait = tick_until(uncertain_product, function() return crafted["uncertain-machine"] end)
check(uncertain_wait == nil and build_plan.tick(uncertain_product) == nil
  and crafted["uncertain-machine"] == 1,
  "build_plan: matching uncertain item product uses a conservative yield of one")

crafted = {}
character.crafting_queue_size, character.crafting_queue = 0, {}
build_plan.start({ auto_craft = false, steps = {
  { item = "transport-belt", position = { x = 0, y = 0 } },
  { item = "transport-belt", position = { x = 1, y = 0 } },
} })
check(next(crafted) == nil, "build_plan: auto-supply can be disabled (auto_craft is its 0.20 name)")

local too_many = {}
for i = 1, 201 do too_many[i] = { item = "transport-belt", position = { x = i, y = 0 } } end
local accepted, limit_error = pcall(build_plan.start, { steps = too_many })
check(not accepted and tostring(limit_error):match("at most 200 steps") ~= nil,
  "build_plan: Lua rejects more than 200 steps")

inventory["transport-belt"] = 1
local create_entity = character.surface.create_entity
character.surface.create_entity = function() return nil end
local fail_fast = { steps = {
  { item = "transport-belt", position = { x = 0, y = 0 } },
  { item = "burner-mining-drill", position = { x = 1, y = 0 } },
} }
build_plan.start(fail_fast)
local failure = build_plan.tick(fail_fast)
check(fail_fast.stop_on_error == true and failure and failure.status == "failed"
  and fail_fast._index == 2 and crafted["burner-mining-drill"] == nil,
  "build_plan: first placement failure prevents every later-step craft side effect")
character.surface.create_entity = create_entity

local semantic_fail_fast = { steps = {
  { item = "not-a-placeable-item", position = { x = 0, y = 0 } },
  { item = "burner-mining-drill", position = { x = 1, y = 0 } },
} }
build_plan.start(semantic_fail_fast)
local semantic_failure = build_plan.tick(semantic_fail_fast)
check(semantic_failure and semantic_failure.status == "failed"
  and semantic_failure.detail:match("no item called 'not%-a%-placeable%-item'")
  and next(crafted) == nil,
  "build_plan: semantic failure of the first step starts zero later-step crafts")

local placed_name
inventory["transport-belt"] = 1
character.build_distance = 6
character.surface = {
  can_place_entity = function(args) placed_name = args.name return true end,
  create_entity = function(args) return { valid = true, name = args.name, type = "transport-belt" } end,
}
character.remove_item = function(args) inventory[args.name] = inventory[args.name] - args.count; return args.count end
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

-- Placement is legal at build reach, but recipe/insert follow-ups must wait
-- for the newly created entity to become physically interactable.
inventory["assembling-machine-1"] = 1
inventory.coal = 1
prototypes.item.coal = {}
local followup_creates, recipe_mutations, insert_mutations = 0, 0, 0
local built_followup
character.surface.create_entity = function(args)
  followup_creates = followup_creates + 1
  local recipe
  built_followup = {
    valid = true, name = args.name, type = "assembling-machine",
    set_recipe = function(name) recipe_mutations = recipe_mutations + 1; recipe = name; return {} end,
    get_recipe = function() return recipe and { name = recipe } or nil end,
    insert = function(stack) insert_mutations = insert_mutations + 1 return stack.count end,
  }
  return built_followup
end
followup_reachable = false
local reach_before = followup_reach_checks
local followup_plan = { auto_craft = false, steps = {
  { item = "assembling-machine-1", position = { x = 6, y = 0 },
    recipe = "iron-gear-wheel", insert = { coal = 1 } },
} }
build_plan.start(followup_plan)
local waiting = build_plan.tick(followup_plan)
check(waiting == nil and followup_plan._built == built_followup
  and followup_creates == 1 and recipe_mutations == 0 and insert_mutations == 0
  and followup_reach_checks == reach_before + 1,
  "build_plan: placed follow-ups wait for Codex can_reach_entity before mutation")
followup_reachable = true
local followed_up = build_plan.tick(followup_plan)
check(followed_up and followed_up.status == "done" and followup_creates == 1
  and recipe_mutations == 1 and insert_mutations == 1
  and followup_reach_checks == reach_before + 2,
  "build_plan: reachable follow-ups mutate the already placed entity exactly once")

inventory["assembling-machine-1"] = 1
inventory.coal = 1
followup_reachable = false
followup_failure = true
local unreachable_plan = { auto_craft = false, steps = {
  { item = "assembling-machine-1", position = { x = 6, y = 0 },
    recipe = "iron-gear-wheel", insert = { coal = 1 } },
} }
build_plan.start(unreachable_plan)
check(build_plan.tick(unreachable_plan) == nil and unreachable_plan._reach_index == 1,
  "build_plan: an out-of-reach placed entity is approached once more")
local unreachable = build_plan.tick(unreachable_plan)
check(unreachable and unreachable.status == "failed" and unreachable.outcome.code == "BUILD_PLAN_STEP_FAILED"
  and unreachable.detail:match("placed the assembling%-machine%-1, but couldn't get within physical reach")
  and recipe_mutations == 1 and insert_mutations == 1,
  "build_plan: unreachable placed follow-ups fail honestly before either mutation")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
