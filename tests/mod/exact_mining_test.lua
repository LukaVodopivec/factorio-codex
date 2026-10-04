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
local player_force = {}
local machine = minable("burner-mining-drill", "mining-drill", 5, nil)
machine.force = player_force
local machine_inventory_empty = true
local machine_fluids = {}
machine.get_inventory = function() return { is_empty = function() return machine_inventory_empty end } end
machine.get_fluid_contents = function() return machine_fluids end
local covered_resource = minable("iron-ore", "resource", 5, 100)
_G.prototypes = { item = {
  ["iron-ore"] = { stack_size = 2 }, ["copper-ore"] = { stack_size = 2 },
  stone = { stack_size = 2 }, ["tree-01"] = { stack_size = 2 },
  ["burner-mining-drill"] = { stack_size = 2 },
} }
local inventory = {}
local capacity_checks = 0
local slot_filters = {}
local function inventory_total(name)
  local total = 0
  for _, stack in ipairs(inventory) do
    if stack.valid_for_read and (name == nil or stack.name == name) then total = total + stack.count end
  end
  return total
end
inventory.get_item_count = inventory_total
inventory.get_bar = function() capacity_checks = capacity_checks + 1; return #inventory + 1 end
inventory.get_filter = function(index) return slot_filters[index] end
local function configure_capacity(capacity)
  for index = #inventory, 1, -1 do inventory[index] = nil end
  slot_filters = {}
  local full_slots, remainder = math.floor(capacity / 2), capacity % 2
  for _ = 1, full_slots do inventory[#inventory + 1] = { valid_for_read = false } end
  if remainder > 0 then
    inventory[#inventory + 1] = {
      valid_for_read = true, name = "iron-ore", count = 1,
      prototype = prototypes.item["iron-ore"], quality = { name = "normal" },
    }
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
      stack.valid_for_read, stack.name, stack.count, stack.prototype, stack.quality =
        true, name, added, prototypes.item[name], { name = "normal" }
      count = count - added
    end
  end
  check(count == 0, "fixture engine gain fits the preflighted inventory")
end
local candidates = { adjacent, exact, tree, covered_resource, machine }
local body = {
  valid = true, position = { x = 0, y = 0 }, resource_reach_distance = 3,
  force = player_force,
  mining_state = { mining = false }, selected = nil, crafting_queue_size = 0,
  can_insert = function() error("partial LuaControl.can_insert must not decide complete-cycle capacity") end,
  can_reach_entity = function(entity) return entity.valid end,
  get_main_inventory = function() return inventory end,
  surface = { find_entities_filtered = function(filter)
    -- The drill hint asks for own drills by force and type; a whole-surface
    -- area there stalls the game, so that one query names no area at all.
    if filter.type == "mining-drill" then
      check(filter.area == nil and filter.radius == nil and filter.force ~= nil, "the drill hint search names a force and no area")
      return {}
    end
    check(filter.area ~= nil and filter.radius == nil, "mining queries an exact area without a nearby radius")
    return candidates
  end },
}
body.update_selected_entity = function(position)
  body.selected = nil
  for _, entity in ipairs(candidates) do
    if entity.valid and entity.force == body.force and entity.position.x == position.x and entity.position.y == position.y then
      body.selected = entity; return
    end
  end
  for _, entity in ipairs(candidates) do
    if entity.valid and entity.position.x == position.x and entity.position.y == position.y then body.selected = entity; return end
  end
end
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = {
  ensure = function() return "ok" end,
  ensure_entity = function(_, _, entity) return entity.valid and "ok" or { status = "failed", detail = "gone" } end,
}
_G.defines = { inventory = { chest = 1, fuel = 2 } }
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
exact.prototype.mineable_properties.products = { { type = "item", name = "iron-ore", amount = 2 } }
configure_capacity(2)
slot_filters[1] = { name = "iron-ore", quality = "normal" }
local table_filter_task = { target = { x = 0, y = 0 } }; mine.start(table_filter_task)
check(mine.tick(table_filter_task) == nil and body.mining_state.mining,
  "mining counts a normal-quality table ItemFilter as available capacity")

reset_resource(100)
configure_capacity(2)
slot_filters[1] = { name = "iron-ore", quality = "uncommon" }
local quality_filter_task = { target = { x = 0, y = 0 } }; mine.start(quality_filter_task)
local quality_filter = mine.tick(quality_filter_task)
check(quality_filter and quality_filter.status == "failed" and body.mining_state.mining == false,
  "mining does not count a table ItemFilter that rejects normal quality")

reset_resource(100)
exact.prototype.mineable_properties.products = { { type = "item", name = "iron-ore", amount = 1 } }
configure_capacity(1)
inventory[1].quality = { name = "uncommon" }
local quality_stack_task = { target = { x = 0, y = 0 } }; mine.start(quality_stack_task)
local quality_stack = mine.tick(quality_stack_task)
check(quality_stack and quality_stack.status == "failed" and body.mining_state.mining == false,
  "mining does not count free space in a non-normal-quality item stack")

reset_resource(100)
exact.prototype.mineable_properties.products = { { type = "item", name = "iron-ore", amount = 1 } }
configure_capacity(6)
local lost_selection_task = { target = { x = 0, y = 0 }, count = 2 }; mine.start(lost_selection_task)
check(mine.tick(lost_selection_task) == nil and body.mining_state.mining,
  "physical mining starts before the lost-selection fixture")
body.selected = nil
local lost_selection = mine.tick(lost_selection_task)
check(lost_selection == nil and body.selected == exact and body.mining_state.mining,
  "in-flight native-client selection loss reselects only the resolved exact target")
body.selected = nil
local recovered_selection = run(lost_selection_task, 10)
check(recovered_selection and recovered_selection.status == "done"
  and lost_selection_task._completed == 2 and exact.amount == 98,
  "physical mining completes while native client input repeatedly clears selection")

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

machine.valid = true
body.resource_reach_distance = 8
engine_gain = 1
configure_capacity(2)
body.crafting_queue_size = 1
local crafting_recovery, crafting_recovery_error = pcall(mine.start,
  { target = { x = 5, y = 0 }, count = 1, target_kind = "owned" })
check(not crafting_recovery and tostring(crafting_recovery_error):match("active hand%-crafting") ~= nil
  and machine.valid and covered_resource.amount == 100,
  "owned recovery refuses a concurrent nonblocking handcraft before mining")
local crafting_natural = { target = { x = 5, y = 0 }, count = 1, target_kind = "natural" }; mine.start(crafting_natural)
check(crafting_natural._entity == covered_resource,
  "concurrent handcrafting does not change natural resource selection at an overlap")
body.crafting_queue_size = 0
local crafting_mid_recovery = { target = { x = 5, y = 0 }, count = 1, target_kind = "owned" }; mine.start(crafting_mid_recovery)
check(mine.tick(crafting_mid_recovery) == nil and body.mining_state.mining,
  "owned recovery starts with no handcraft in progress")
body.crafting_queue_size = 1
machine.valid, body.selected = false, nil
engine_insert("burner-mining-drill", 1)
local crafting_mid_result = mine.tick(crafting_mid_recovery)
check(crafting_mid_result and crafting_mid_result.status == "failed"
  and crafting_mid_result.detail:match("active hand%-crafting") ~= nil
  and crafting_mid_recovery._completed == 0 and crafting_mid_recovery._actual_gain == 0
  and not body.mining_state.mining and not machine.valid
  and covered_resource.amount == 100 and adjacent.amount == 100,
  "owned recovery fails closed when a same-product handcraft overlaps the physical cycle")
body.crafting_queue_size, machine.valid = 0, true
configure_capacity(2)
local filled_before_mining = { target = { x = 5, y = 0 }, count = 1, target_kind = "owned" }; mine.start(filled_before_mining)
machine_inventory_empty = false
local filled_before_result = mine.tick(filled_before_mining)
check(filled_before_result and filled_before_result.status == "failed" and not body.mining_state.mining
  and machine.valid and covered_resource.amount == 100,
  "owned recovery rechecks inventory after start and before physical mining")
machine_inventory_empty = true
local filled_during_mining = { target = { x = 5, y = 0 }, count = 1, target_kind = "owned" }; mine.start(filled_during_mining)
check(mine.tick(filled_during_mining) == nil and body.mining_state.mining,
  "owned recovery starts only while the entity remains empty")
machine_fluids = { water = 1 }
local filled_during_result = mine.tick(filled_during_mining)
check(filled_during_result and filled_during_result.status == "failed" and not body.mining_state.mining
  and machine.valid and covered_resource.amount == 100,
  "owned recovery stops if fluid contents appear during physical mining")
machine_fluids = {}
local recovery = { target = { x = 5, y = 0 }, count = 1, target_kind = "owned" }; mine.start(recovery)
local recovered = run(recovery, 10)
check(recovered and recovered.status == "done" and not machine.valid
  and covered_resource.valid and covered_resource.amount == 100
  and adjacent.valid and adjacent.amount == 100
  and inventory_total() == 1 and scripted_mine_calls == 0,
  "explicit player-owned machine recovery leaves underlying and adjacent ore untouched and uses physical LuaControl mining")

machine.valid, machine_inventory_empty = true, false
local occupied, occupied_error = pcall(mine.start, { target = { x = 5, y = 0 }, count = 1, target_kind = "owned" })
check(not occupied and tostring(occupied_error):match("nonempty inventories or fluids") ~= nil,
  "player-owned recovery fails closed for nonempty inventories")
machine_inventory_empty, machine_fluids = true, { water = 1 }
local wet, wet_error = pcall(mine.start, { target = { x = 5, y = 0 }, count = 1, target_kind = "owned" })
check(not wet and tostring(wet_error):match("nonempty inventories or fluids") ~= nil,
  "player-owned recovery fails closed for nonempty fluids")
configure_capacity(2)
local drainless = { target = { x = 5, y = 0 }, count = 1, target_kind = "owned", allow_fluid_loss = true }
mine.start(drainless)
local drainless_result = run(drainless, 10)
check(drainless_result and drainless_result.status == "done" and not machine.valid
  and drainless_result.detail:match("discarded contained fluid")
  and drainless_result.detail:match("1%.0 water"),
  "explicit fluid-loss recovery uses ordinary dismantling and reports the discarded amount")
machine.valid = true
machine_fluids = {}
covered_resource.valid, covered_resource.amount = true, 100
configure_capacity(4)
local overlap_resource = { target = { x = 5, y = 0 }, count = 2, target_kind = "natural" }; mine.start(overlap_resource)
check(overlap_resource._entity == covered_resource and machine.valid and covered_resource.amount == 100,
  "multiple mining cycles require the overlapping natural resource rather than selecting the machine")
local implicit = { target = { x = 5, y = 0 }, count = 1 }; mine.start(implicit)
local implicit_result = mine.tick(implicit)
check(implicit_result and implicit_result.outcome.code == "TARGET_KIND_REQUIRED"
  and #implicit_result.outcome.candidates == 2 and implicit._entity == nil,
  "natural/owned overlap requires explicit intent and never chooses an implicit priority")
local repeated_owned, repeated_owned_error = pcall(mine.start, { target = { x = 5, y = 0 }, count = 2, target_kind = "owned" })
check(not repeated_owned and tostring(repeated_owned_error):match("exactly one physical mining cycle") ~= nil,
  "explicit player-owned recovery permits exactly one physical cycle")
local natural_loss, natural_loss_error = pcall(mine.start,
  { target = { x = 5, y = 0 }, count = 1, target_kind = "natural", allow_fluid_loss = true })
check(not natural_loss and tostring(natural_loss_error):match("only with target_kind=owned") ~= nil,
  "fluid-loss permission cannot broaden natural-resource mining")

os.exit(failures == 0 and 0 or 1)
