local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local scripted_mine_calls = 0
local function minable(name, kind, x, amount)
  return {
    valid = true, name = name, type = kind, amount = amount,
    position = { x = x, y = 0 },
    selection_box = { left_top = { x = x - 0.49, y = -0.49 }, right_bottom = { x = x + 0.49, y = 0.49 } },
    prototype = { mineable_properties = { minable = true, mining_time = 1, products = {
      { type = "item", name = name, amount = 1 },
    } } },
    mine = function() scripted_mine_calls = scripted_mine_calls + 1 error("scripted mine must never run") end,
  }
end
local exact = minable("iron-ore", "resource", 0, 100)
local adjacent = minable("copper-ore", "resource", 1, 100)
local tree = minable("tree-01", "tree", 3, nil)
_G.prototypes = { item = {
  ["iron-ore"] = { stack_size = 2 }, ["copper-ore"] = { stack_size = 2 },
  stone = { stack_size = 2 }, ["tree-01"] = { stack_size = 2 },
} }
local inventory = {}
local capacity_checks = 0
local function inventory_total()
  local total = 0
  for _, stack in ipairs(inventory) do if stack.valid_for_read then total = total + stack.count end end
  return total
end
inventory.get_item_count = inventory_total
inventory.get_bar = function() capacity_checks = capacity_checks + 1; return #inventory + 1 end
inventory.get_filter = function() return nil end
local function configure_capacity(capacity)
  for index = #inventory, 1, -1 do inventory[index] = nil end
  local full_slots, remainder = math.floor(capacity / 2), capacity % 2
  for _ = 1, full_slots do inventory[#inventory + 1] = { valid_for_read = false } end
  if remainder > 0 then
    inventory[#inventory + 1] = { valid_for_read = true, name = "iron-ore", count = 1, prototype = prototypes.item["iron-ore"] }
  end
end
local function engine_insert(name, count)
  for _, stack in ipairs(inventory) do
    if count > 0 and stack.valid_for_read and stack.name == name then
      local added = math.min(count, stack.prototype.stack_size - stack.count)
      stack.count, count = stack.count + added, count - added
    end
  end
  for _, stack in ipairs(inventory) do
    if count > 0 and not stack.valid_for_read then
      local added = math.min(count, prototypes.item[name].stack_size)
      stack.valid_for_read, stack.name, stack.count, stack.prototype = true, name, added, prototypes.item[name]
      count = count - added
    end
  end
  check(count == 0, "fixture engine gain fits the preflighted inventory")
end
local candidates = { adjacent, exact, tree }
local body = {
  valid = true, position = { x = 0, y = 0 }, resource_reach_distance = 3,
  mining_state = { mining = false }, selected = nil,
  can_insert = function() error("partial LuaControl.can_insert must not decide complete-cycle capacity") end,
  get_main_inventory = function() return inventory end,
  surface = { find_entities_filtered = function(filter)
    check(filter.area ~= nil and filter.radius == nil, "mining queries an exact area without a nearby radius")
    return candidates
  end },
}
body.update_selected_entity = function(position)
  body.selected = nil
  for _, entity in ipairs(candidates) do
    if entity.valid and entity.position.x == position.x and entity.position.y == position.y then body.selected = entity; return end
  end
end
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end }
_G.game = { tick = 100 }
local mine = require("scripts.actions.mine")
local mining_progress = 0
local engine_gain = 2
local function advance_game_tick()
  game.tick = game.tick + 1
  -- Model Factorio's physical entity-mining contract: time advances only while
  -- mining_state points at the selected exact entity. The engine, not the
  -- action, changes resource amount and inventory, including productivity.
  if body.mining_state.mining and body.selected and body.selected.valid then
    mining_progress = mining_progress + 1
    if mining_progress == 3 then
      mining_progress = 0
      local target = body.selected
      if target.type == "resource" then
        target.amount = target.amount - 1
        if target.amount <= 0 then target.valid = false end
      else
        target.valid = false
      end
      engine_insert(target.name, engine_gain)
    end
  end
end
local function run(task, max_ticks)
  for _ = 1, max_ticks do
    local result = mine.tick(task)
    if result then return result end
    advance_game_tick()
  end
  return nil
end
local function reset_resource(amount)
  exact.valid, exact.amount, body.selected = true, amount, nil
  body.mining_state = { mining = false }
  mining_progress, capacity_checks = 0, 0
end

exact.prototype.mineable_properties.products = { { type = "item", name = "iron-ore", amount = 2 } }
configure_capacity(1)
local full_task = { target = { x = 0, y = 0 } }; mine.start(full_task)
local full = mine.tick(full_task)
check(full and full.status == "failed" and full.detail:match("inventory is full") ~= nil,
  "mining rejects partial capacity that cannot accept the complete product stack")
check(inventory_total() == 1 and inventory.insert == nil and body.mining_state.mining == false
  and exact.amount == 100 and scripted_mine_calls == 0,
  "partial-capacity preflight is read-only and never starts mining")

reset_resource(100)
exact.prototype.mineable_properties.products = {
  { type = "item", name = "iron-ore", amount = 1 }, { type = "item", name = "stone", amount = 1 },
}
configure_capacity(1)
local aggregate_task = { target = { x = 0, y = 0 } }; mine.start(aggregate_task)
local aggregate = mine.tick(aggregate_task)
check(aggregate and aggregate.status == "failed" and inventory_total() == 1 and body.mining_state.mining == false,
  "mining aggregates different products against shared inventory capacity")

reset_resource(100)
exact.prototype.mineable_properties.products = { { type = "item", name = "iron-ore", amount = 1 } }
configure_capacity(6)
local lost_selection_task = { target = { x = 0, y = 0 }, count = 2 }; mine.start(lost_selection_task)
check(mine.tick(lost_selection_task) == nil and body.mining_state.mining,
  "physical mining starts before the lost-selection fixture")
body.selected = nil
local lost_selection = mine.tick(lost_selection_task)
check(lost_selection and lost_selection.status == "failed"
  and lost_selection.detail:match("requested 2 cycles, completed 0, actual gain 0 items") ~= nil
  and lost_selection.detail:match("lost selection") ~= nil and body.mining_state.mining == false,
  "in-flight selection loss stops mining immediately with partial progress")

reset_resource(100)
configure_capacity(6)
local repeated = { target = { x = 0, y = 0 }, count = 3 }; mine.start(repeated)
local completed = run(repeated, 20)
check(completed and completed.status == "done" and repeated._completed == 3 and exact.amount == 97,
  "count mines repeated physical cycles on the same initially resolved resource")
check(completed and completed.detail:match("requested 3 cycles, completed 3, actual gain 6 items") ~= nil,
  "repeated mining reports productivity-aware actual inventory gain")
check(capacity_checks == 3, "complete product capacity is rechecked before every physical cycle")
check(body.selected == exact and adjacent.amount == 100, "repeated mining never switches to an adjacent resource")
check(body.mining_state.mining == false and scripted_mine_calls == 0,
  "repeated mining stops immediately and never calls scripted LuaEntity.mine")

reset_resource(100)
configure_capacity(3)
exact.prototype.mineable_properties.products = { { type = "item", name = "iron-ore", amount = 2 } }
local capacity_shortfall = { target = { x = 0, y = 0 }, count = 2 }; mine.start(capacity_shortfall)
local shortfall = run(capacity_shortfall, 10)
check(shortfall and shortfall.status == "failed" and shortfall.detail:match("requested 2 cycles, completed 1, actual gain 2 items") ~= nil
  and shortfall.detail:match("inventory is full") ~= nil,
  "later-cycle capacity failure reports requested, completed, and actual gains")

reset_resource(1)
configure_capacity(6)
local exhaustion_task = { target = { x = 0, y = 0 }, count = 3 }; mine.start(exhaustion_task)
local exhausted = run(exhaustion_task, 10)
check(exhausted and exhausted.status == "failed" and exhausted.detail:match("completed 1, actual gain 2 items") ~= nil
  and exhausted.detail:match("exhausted") ~= nil,
  "partial resource exhaustion fails honestly without choosing a replacement")

tree.valid = true
local non_resource, non_resource_error = pcall(mine.start, { target = { x = 3, y = 0 }, count = 2 })
check(not non_resource and tostring(non_resource_error):match("only valid for resources") ~= nil,
  "tree and rock mining reject count greater than one")
local invalid_count = pcall(mine.start, { target = { x = 0, y = 0 }, count = 201 })
check(not invalid_count, "Lua enforces the public mine count cap")
local by_name = pcall(mine.start, { resource = "iron-ore", count = 10 })
check(not by_name, "by-name resource discovery is rejected")
os.exit(failures == 0 and 0 or 1)
