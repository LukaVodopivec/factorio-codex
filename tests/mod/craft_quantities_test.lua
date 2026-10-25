local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local inventory = { ["iron-plate"] = 6, ["transport-belt"] = 0 }
local recipe = { name = "transport-belt", enabled = true,
  ingredients = { { type = "item", name = "iron-plate", amount = 3 } },
  products = { { type = "item", name = "transport-belt", amount = 2 } } }
local body = { force = { recipes = { ["transport-belt"] = recipe } }, crafting_queue_size = 0 }
body.get_item_count = function(name) return name and (inventory[name] or 0) or 0 end
body.begin_crafting = function(args)
  inventory["iron-plate"] = inventory["iron-plate"] - 3 * args.count
  inventory["transport-belt"] = inventory["transport-belt"] + 2 * args.count
  return args.count
end
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
_G.game, _G.storage = { tick = 0 }, {}
local craft = require("scripts.actions.craft")

local task = { recipe = "transport-belt", count = 2, wait_for_completion = true }
craft.start(task)
check(craft.tick(task) == nil and inventory["iron-plate"] == 0, "a waiting craft queues its crafts on its first tick")
game.tick = 30
local done = craft.tick(task)
check(done and done.status == "done" and done.detail:match("2 recipe crafts")
  and done.detail:match("%+4 transport%-belt") and done.outcome.crafts_started == 2
  and done.outcome.products[1].carried_delta == 4 and not done.outcome.queue.retained,
  "craft result distinguishes recipe crafts from actual output item count")

-- By default the crafts run in the background: the step ends once queued.
inventory["iron-plate"] = 3
local background = { recipe = "transport-belt", count = 1 }
craft.start(background)
local queued = craft.tick(background)
check(queued and queued.status == "done" and queued.detail:match("hand%-crafting queue"),
  "a craft step does not wait for its crafts unless asked to")

-- An ingredient still in the crafting queue is waited for, not re-crafted.
local gear = { name = "iron-gear-wheel", enabled = true,
  ingredients = { { type = "item", name = "iron-plate", amount = 2 } },
  products = { { type = "item", name = "iron-gear-wheel", amount = 1 } } }
local inserter = { name = "burner-inserter", enabled = true,
  ingredients = { { type = "item", name = "iron-plate", amount = 1 }, { type = "item", name = "iron-gear-wheel", amount = 1 } },
  products = { { type = "item", name = "burner-inserter", amount = 1 } } }
body.force.recipes["iron-gear-wheel"], body.force.recipes["burner-inserter"] = gear, inserter
inventory["iron-plate"], inventory["iron-gear-wheel"] = 1, 0
body.crafting_queue = { { index = 1, recipe = "iron-gear-wheel", count = 1, prerequisite = false } }
local began = 0
body.begin_crafting = function(args) began = began + args.count; return args.count end
check(craft.queued(body, "iron-gear-wheel") == 1 and craft.awaits(body, "iron-gear-wheel", 1)
  and not craft.awaits(body, "iron-plate", 1), "queued output counts toward what the body will carry")
local consumer = { recipe = "burner-inserter", count = 1 }
craft.start(consumer)
check(craft.tick(consumer) == nil and began == 0, "a craft waits while its ingredient is still being crafted")
body.crafting_queue, inventory["iron-gear-wheel"] = {}, 1
local consumed = craft.tick(consumer)
check(consumed and consumed.status == "done" and began == 1, "the craft starts once its ingredient is carried")
body.crafting_queue = { { index = 1, recipe = "iron-gear-wheel", count = 5, prerequisite = true } }
check(craft.queued(body, "iron-gear-wheel") == 0, "a prerequisite craft's output is consumed by the next one, never counted")
local missing_count_ok = pcall(craft.start, { recipe = "transport-belt" })
check(not missing_count_ok, "craft rejects a missing recipe execution count")
for _, invalid in ipairs({ 0, 1.5, 101 }) do
  local ok = pcall(craft.start, { recipe = "transport-belt", count = invalid })
  check(not ok, "craft rejects missing, noninteger, and out-of-range recipe execution counts")
end
recipe.products = { { type = "item", name = "transport-belt", amount_min = 1, amount_max = 3 } }
inventory["iron-plate"] = 3
local variable = { recipe = "transport-belt", count = 1, wait_for_completion = false }
craft.start(variable)
local accepted = craft.tick(variable)
check(accepted and accepted.detail:match("variable transport%-belt")
  and not accepted.detail:match("expected outputs: 3 transport%-belt"),
  "craft never reports amount_min or amount_max as an exact output")

-- A craft no hand-craft could start is a coded refusal: MISSING_INGREDIENTS
-- names what is short, NOT_HAND_CRAFTABLE the recipe's category. Refusals at
-- start are raised without a source location (deliberate, not faults).
do
  local errors = require("scripts.errors")
  body.crafting_queue = {}
  body.begin_crafting = function() return 0 end
  inventory["iron-plate"] = 1
  local short = { recipe = "iron-gear-wheel", count = 2 }
  craft.start(short)
  local missing = craft.tick(short)
  check(missing.status == "failed" and missing.outcome.code == "MISSING_INGREDIENTS"
    and missing.outcome.recipe == "iron-gear-wheel" and missing.outcome.missing[1].item == "iron-plate"
    and missing.outcome.missing[1].missing == 3 and missing.detail:match("^MISSING_INGREDIENTS: ") ~= nil,
    "a craft short of ingredients is MISSING_INGREDIENTS with each missing item and count")
  inventory["iron-plate"] = 10
  gear.category = "smelting"
  local by_machine = { recipe = "iron-gear-wheel", count = 1 }
  craft.start(by_machine)
  local refused = craft.tick(by_machine)
  check(refused.status == "failed" and refused.outcome.code == "NOT_HAND_CRAFTABLE"
    and refused.outcome.category == "smelting" and refused.detail:match("^NOT_HAND_CRAFTABLE: ") ~= nil,
    "a recipe the body cannot hand-craft is NOT_HAND_CRAFTABLE with its category")
  local remedy = false
  for _, text in ipairs({ missing.detail, refused.detail }) do
    for _, word in ipairs({ "should", "consider", "try ", "instead", "build ", "research " }) do
      if text:lower():find(word, 1, true) then remedy = true end
    end
  end
  check(not remedy, "the coded craft refusals state facts only")
  for _, bad in ipairs({ { recipe = "no-such-recipe", count = 1, code = "RECIPE_UNKNOWN" },
    { recipe = "iron-gear-wheel", count = 0, code = "CRAFT_INVALID" } }) do
    local ok, why = pcall(craft.start, bad)
    check(not ok and errors.deliberate(why) and not tostring(why):find(".lua:", 1, true)
      and tostring(why):sub(1, #bad.code + 2) == bad.code .. ": ", "a craft refused at start is coded: " .. tostring(why))
  end
end

-- queue_summary: the head entry and the seconds the queue still needs at
-- the body's crafting speed; queue_touches: whether a queued recipe makes or
-- uses one of the named items.
do
  gear.energy, inserter.energy = 0.5, 0.5
  body.force.manual_crafting_speed_modifier, body.character_crafting_speed_modifier = 0.5, 0.5
  body.crafting_queue_size, body.crafting_queue_progress = 3, 0.2
  body.crafting_queue = { { recipe = "iron-gear-wheel", count = 2 }, { recipe = "burner-inserter", count = 1 } }
  local summary = craft.queue_summary(body)
  check(summary.recipe == "iron-gear-wheel" and summary.count == 2 and summary.queue_s == 0.7,
    "queue_summary: (2 x 0.5 s - 0.2 x 0.5 s + 0.5 s) at speed 2 is 0.7 s")
  check(craft.queue_touches(body, { ["burner-inserter"] = true }) and craft.queue_touches(body, { ["iron-plate"] = true })
    and not craft.queue_touches(body, { ["stone-furnace"] = true }),
    "queue_touches sees a queued recipe's products and ingredients only")
  body.crafting_queue_size, body.crafting_queue = 0, {}
  check(craft.queue_summary(body) == nil, "an empty queue has no summary")
end
-- A native craft may consume only part of a stack and then stay at completed
-- progress because its products have no slot. Acceptance is not delivery.
do
  inventory["iron-plate"], inventory["iron-gear-wheel"] = 100, 0
  body.begin_crafting = function(args)
    inventory["iron-plate"] = inventory["iron-plate"] - 2 * args.count
    body.crafting_queue = { { recipe = "iron-gear-wheel", count = args.count, prerequisite = false } }
    body.crafting_queue_size, body.crafting_queue_progress = 1, 0
    return args.count
  end
  local full = { recipe = "iron-gear-wheel", count = 1, wait_for_completion = true }
  craft.start(full)
  check(craft.tick(full) == nil, "a full-inventory craft is accepted before result capacity is known")
  body.crafting_queue_progress = 1.0333333333
  game.tick = game.tick + 30
  check(craft.tick(full) == nil, "a ready head gets a native tick to deliver after an inventory change")
  game.tick = game.tick + 30
  local blocked = craft.tick(full)
  check(blocked and blocked.status == "failed" and blocked.outcome.code == "CRAFT_OUTPUT_BLOCKED"
    and blocked.outcome.crafts_started == 1 and blocked.outcome.products[1].carried_delta == 0
    and blocked.outcome.queue.retained and blocked.outcome.queue.entries[1].count == 1
    and inventory["iron-plate"] == 98,
    "a capacity-blocked native craft releases its wait and reports accepted, carried and retained quantities")

  -- Before readiness, a full inventory is not a refusal: ingredients can
  -- free a slot, or an existing result stack can accept the products.
  body.crafting_queue_progress = 0.5
  game.tick = game.tick + 30
  check(craft.tick(full) == nil, "capacity is evaluated from native delivery, not inventory fullness before consumption")
  body.crafting_queue, body.crafting_queue_size = {}, 0
  inventory["iron-gear-wheel"] = 1
  game.tick = game.tick + 30
  check(craft.tick(full).status == "done", "a result delivered into a freed slot completes normally")

  -- A batch can deliver some products then block, with another unrelated
  -- recipe behind it. Report the delivered evidence and retain both entries.
  inventory["iron-gear-wheel"], inventory["iron-plate"] = 0, 100
  local batch = { recipe = "iron-gear-wheel", count = 3, wait_for_completion = true }
  craft.start(batch); craft.tick(batch)
  inventory["iron-gear-wheel"] = 2
  body.crafting_queue[1].count = 1
  body.crafting_queue[2] = { recipe = "burner-inserter", count = 4 }
  body.crafting_queue_size, body.crafting_queue_progress = 2, 1.0333333333
  game.tick = game.tick + 30
  craft.tick(batch)
  game.tick = game.tick + 30
  local partial = craft.tick(batch)
  check(partial and partial.status == "failed" and partial.outcome.crafts_started == 3
    and partial.outcome.products[1].carried_delta == 2 and partial.outcome.products[1].expected == 3
    and partial.outcome.queue.size == 2 and partial.outcome.queue.entries[2].count == 4,
    "a partially delivered batch never claims completion and leaves unrelated native crafting intact")
  local ended = craft.cancelled(batch)
  check(ended.queue.retained and ended.queue.size == 2 and ended.products[1].carried_delta == 2,
    "terminal craft reconciliation reports retained work without cancellation or refunds")

  for i = 3, 40 do body.crafting_queue[i] = { recipe = "burner-inserter", count = 1 } end
  local capped = craft.cancelled(batch)
  check(#capped.queue.entries == 32 and capped.queue.omitted_entries == 8 and capped.queue.size == 40,
    "queue reconciliation bounds its work and explicitly counts omitted native entries")

  gear.products = { { type = "item", name = "iron-gear-wheel", amount = 1 },
    { type = "item", name = "burner-inserter", amount = 2 } }
  inventory["iron-gear-wheel"], inventory["burner-inserter"] = 0, 0
  local multi = { recipe = "iron-gear-wheel", count = 1, wait_for_completion = true }
  craft.start(multi); craft.tick(multi)
  body.crafting_queue, body.crafting_queue_size = {}, 0
  inventory["iron-gear-wheel"], inventory["burner-inserter"] = 1, 2
  game.tick = game.tick + 30
  local complete = craft.tick(multi)
  check(complete.status == "done" and #complete.outcome.products == 2
    and complete.outcome.products[2].carried_delta == 2 and complete.outcome.queue.size == 0,
    "a native-delivered multi-output recipe completes with each product counted")
  inventory["iron-gear-wheel"], inventory["burner-inserter"] = 0, 0
  local short = { recipe = "iron-gear-wheel", count = 1, wait_for_completion = true }
  craft.start(short); craft.tick(short)
  body.crafting_queue, body.crafting_queue_size = {}, 0
  inventory["iron-gear-wheel"] = 1
  game.tick = game.tick + 30
  local missing = craft.tick(short)
  check(missing.status == "failed" and missing.outcome.code == "CRAFT_PRODUCTS_MISSING"
    and missing.outcome.products[2].carried_delta == 0 and missing.outcome.queue.size == 0,
    "one missing product never falsely completes a multi-output craft")
end
os.exit(failures == 0 and 0 or 1)
