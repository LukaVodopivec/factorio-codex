local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local scripted_mine_calls = 0
local function ore(name, x)
  return {
    valid = true, name = name, type = "resource", amount = 100,
    position = { x = x, y = 0 },
    selection_box = { left_top = { x = x - 0.49, y = -0.49 }, right_bottom = { x = x + 0.49, y = 0.49 } },
    prototype = { mineable_properties = { minable = true, mining_time = 1, products = {
      { type = "item", name = name, amount = 1 },
    } } },
    mine = function() scripted_mine_calls = scripted_mine_calls + 1 error("scripted mine must never run") end,
  }
end
local exact, adjacent = ore("iron-ore", 0), ore("copper-ore", 1)
local inventory_counts = {}
local inventory_capacity = 0
local function inventory_total()
  local total = 0
  for _, count in pairs(inventory_counts) do total = total + count end
  return total
end
local inventory = {
  get_item_count = inventory_total,
  insert = function(stack)
    local inserted = math.min(stack.count, math.max(inventory_capacity - inventory_total(), 0))
    inventory_counts[stack.name] = (inventory_counts[stack.name] or 0) + inserted
    return inserted
  end,
  remove = function(stack)
    local removed = math.min(stack.count, inventory_counts[stack.name] or 0)
    inventory_counts[stack.name] = (inventory_counts[stack.name] or 0) - removed
    return removed
  end,
}
local body = {
  valid = true, position = { x = 0, y = 0 }, resource_reach_distance = 3,
  mining_state = { mining = false },
  selected = nil,
  can_insert = function() error("partial LuaControl.can_insert must not decide complete-cycle capacity") end,
  get_main_inventory = function() return inventory end,
  surface = { find_entities_filtered = function(filter)
    check(filter.area ~= nil and filter.radius == nil, "mining queries an exact area without a nearby radius")
    return { adjacent, exact }
  end },
}
body.update_selected_entity = function(position)
  body.selected = nil
  for _, entity in ipairs({ adjacent, exact }) do
    if entity.valid and entity.position.x == position.x and entity.position.y == position.y then
      body.selected = entity
      return
    end
  end
end
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end }
_G.game = { tick = 100 }
local mine = require("scripts.actions.mine")
local mining_progress = 0
local function advance_game_tick()
  game.tick = game.tick + 1
  -- Model Factorio's physical entity-mining contract: mining_state only makes
  -- progress against the control's selected entity. Accepting the state write
  -- without a selection reproduces the live indefinite-running failure.
  if body.mining_state.mining and body.selected == exact and exact.valid then
    mining_progress = mining_progress + 1
    if mining_progress == 3 then
      exact.amount = exact.amount - 1
      inventory_counts["iron-ore"] = (inventory_counts["iron-ore"] or 0) + 2
    end
  end
end
exact.prototype.mineable_properties.products = {
  { type = "item", name = "iron-ore", amount = 2 },
}
inventory_capacity = 1
local full_task = { target = { x = 0, y = 0 } }; mine.start(full_task)
local full = mine.tick(full_task)
check(full and full.status == "failed" and full.detail:match("inventory is full") ~= nil,
  "mining rejects partial capacity that cannot accept the complete product stack")
check(inventory_total() == 0 and body.mining_state.mining == false
  and exact.amount == 100 and scripted_mine_calls == 0,
  "partial-capacity preflight restores inventory and never starts mining")

exact.prototype.mineable_properties.products = {
  { type = "item", name = "iron-ore", amount = 1 },
  { type = "item", name = "stone", amount = 1 },
}
inventory_capacity = 1
local aggregate_task = { target = { x = 0, y = 0 } }; mine.start(aggregate_task)
local aggregate = mine.tick(aggregate_task)
check(aggregate and aggregate.status == "failed" and inventory_total() == 0
  and body.mining_state.mining == false,
  "mining aggregates different products against shared inventory capacity")

exact.prototype.mineable_properties.products = {
  { type = "item", name = "iron-ore", amount = 2 },
}
inventory_capacity = 10
local task = { target = { x = 0, y = 0 } }; mine.start(task)
check(task._entity_name == "iron-ore", "mining selects only the entity occupying the exact coordinate")
local first_tick = mine.tick(task)
check(first_tick == nil and body.mining_state.mining == true and inventory_total() == 0
  and body.mining_state.position.x == exact.position.x and body.selected == exact,
  "physical mining selects the exact target after restoring capacity-preflight products")
advance_game_tick()
local second_tick = mine.tick(task)
advance_game_tick()
local third_tick = mine.tick(task)
check(second_tick == nil and third_tick == nil and game.tick == 102
  and exact.amount == 100 and inventory_total() == 0,
  "selected physical mining remains active while a real mining cycle advances")
advance_game_tick()
local completed = mine.tick(task)
check(completed and completed.status == "done" and completed.detail:match("%+2 items") ~= nil,
  "one real mining cycle reports the actual inventory gain")
check(body.mining_state.mining == false, "mining stops immediately after the completed cycle")
check(scripted_mine_calls == 0, "mining never calls scripted LuaEntity.mine")
check(adjacent.valid and adjacent.amount == 100, "adjacent ore remains untouched")

local vanished_task = { target = { x = 0, y = 0 } }; exact.valid = true; exact.amount = 100; mine.start(vanished_task)
mine.tick(vanished_task)
exact.valid = false
local vanished = mine.tick(vanished_task)
check(vanished and vanished.status == "failed" and vanished.detail:match("without mined items") ~= nil,
  "target removal without inventory gain is not reported as mining success")
local ok = pcall(mine.start, { resource = "iron-ore", count = 10 })
check(not ok, "by-name resource discovery is rejected")
os.exit(failures == 0 and 0 or 1)
