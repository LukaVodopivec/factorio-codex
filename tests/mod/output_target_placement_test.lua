local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local force = { is_chunk_charted = function() return true end }
local recipient = { valid = true, name = "stone-furnace", type = "furnace", force = force,
  position = { x = 2.5, y = 0.5 }, selection_box = { left_top = { x = 2.0, y = 0.0 }, right_bottom = { x = 3.0, y = 1.0 } },
  bounding_box = { left_top = { x = 2.0, y = 0.0 }, right_bottom = { x = 3.0, y = 1.0 } } }
local replacement = { valid = true, name = "steel-furnace", type = "furnace", force = force,
  position = { x = 2.5, y = 0.5 }, selection_box = recipient.selection_box }
local source = { valid = true, name = "wooden-chest", type = "container", force = force,
  position = { x = 1.5, y = -0.5 }, selection_box = { left_top = { x = 1.0, y = -1.0 }, right_bottom = { x = 2.0, y = 0.0 } },
  bounding_box = { left_top = { x = 1.0, y = -1.0 }, right_bottom = { x = 2.0, y = 0.0 } } }
local target_matches, created, removed, inserted, pickup_target, drop_target, last_built = { recipient }, 0, 0, 0, source, recipient, nil
local insert_limit
local rejected_item
local planned_recipient
local runtime_drop_position = { x = 2.5, y = 0.5 }
local surface
surface = {
  find_entities_filtered = function() return target_matches end,
  can_place_entity = function() return true end,
  create_entity = function(args)
    created = created + 1
    local built_type = prototypes.item[args.name].place_result.type
    last_built = { valid = true, name = args.name,
      type = built_type, position = args.position,
      pickup_target = pickup_target, drop_target = drop_target,
      direction = args.direction, drop_position = runtime_drop_position, prototype = prototypes.item[args.name].place_result,
      force = force, surface = surface,
      insert = function(stack)
        local accepted = stack.name == rejected_item and 0 or math.min(stack.count, insert_limit or stack.count)
        inserted = inserted + accepted
        return accepted
      end }
    do
      last_built.bounding_box = { left_top = { x = args.position.x - 0.4, y = args.position.y - 0.4 },
        right_bottom = { x = args.position.x + 0.4, y = args.position.y + 0.4 } }
    end
    if built_type == "container" then planned_recipient = last_built end
    target_matches[#target_matches + 1] = last_built
    return last_built
  end,
}
local body = { valid = true, position = { x = 0.5, y = 0.5 }, build_distance = 6, force = force, surface = surface,
  get_item_count = function() return 1 end, remove_item = function(args) removed = removed + args.count end }
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = {
  ensure = function() return "ok" end,
  ensure_entity = function() return "ok" end,
}
_G.defines = { direction = { north = 0 }, build_check_type = { manual = 1 } }
_G.game = { tick = 100 }
_G.storage = {}
local activity = require("scripts.factory_activity")
_G.prototypes = { item = {
  wood = { name = "wood" },
  ["burner-mining-drill"] = { place_result = { name = "burner-mining-drill", type = "mining-drill", vector_to_place_result = { x = 1, y = 0 } } },
  ["burner-inserter"] = { place_result = { name = "burner-inserter", type = "inserter",
    inserter_pickup_position = { x = 0, y = -1 }, inserter_drop_position = { x = 1, y = 0 } } },
  ["wooden-chest"] = { place_result = { name = "wooden-chest", type = "container",
    collision_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } } } },
} }
local place = require("scripts.actions.build").place
drop_target = nil
local valid = { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 }, output_target = { x = 2.5, y = 0.5 } }
place.start(valid)
local placed_pending = place.tick(valid)
local same_tick_pending = place.tick(valid)
check(placed_pending == nil and same_tick_pending == nil and created == 1 and removed == 1,
  "placement preserves the exact new entity and waits beyond its creation tick")
game.tick = game.tick + 1
local valid_result = place.tick(valid)
check(valid_result and valid_result.status == "done" and valid_result.detail:match("pending first output")
  and created == 1 and removed == 1,
  "placement preserves truthful pending output while exact geometry is valid and drop_target is nil")
created, removed, drop_target, runtime_drop_position = 0, 0, recipient, { x = 2.75, y = 0.5 }
local wrong_geometry = { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 }, output_target = { x = 2.5, y = 0.5 } }
place.start(wrong_geometry)
check(place.tick(wrong_geometry) == nil, "placement retains an entity whose runtime endpoint still needs verification")
game.tick = game.tick + 1
local wrong_geometry_result = place.tick(wrong_geometry)
check(wrong_geometry_result and wrong_geometry_result.status == "done" and created == 1,
  "authoritative exact runtime binding outranks a prototype/runtime endpoint discrepancy")
runtime_drop_position = { x = 2.5, y = 0.5 }
created, removed, target_matches, recipient.valid = 0, 0, { recipient }, true
local invalidated = { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 }, output_target = { x = 2.5, y = 0.5 } }
place.start(invalidated)
recipient.valid, target_matches = false, { replacement }
local invalidated_result = place.tick(invalidated)
check(invalidated_result and invalidated_result.status == "failed" and invalidated_result.detail:match("changed before placement") and created == 0 and removed == 0, "placement refuses an output recipient invalidated after search")
recipient.valid, target_matches, drop_target = true, { recipient }, nil
local mismatch = { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 }, output_target = { x = 2.5, y = 0.5 } }
place.start(mismatch)
check(place.tick(mismatch) == nil and created == 1 and removed == 1,
  "placement does not report an immediate false output mismatch")
game.tick = game.tick + 1
last_built.drop_target = replacement
local mismatch_result = place.tick(mismatch)
check(mismatch_result and mismatch_result.status == "failed" and mismatch_result.detail:match("different runtime output target")
  and created == 1 and removed == 1,
  "a non-nil wrong runtime target fails even when exact geometry still points at the requested recipient")
created, removed, drop_target, target_matches = 0, 0, nil, { recipient }
local unbound = { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 }, output_target = { x = 2.5, y = 0.5 } }
place.start(unbound)
check(place.tick(unbound) == nil, "placement begins later-tick output-tile verification")
target_matches = {}
game.tick = game.tick + 1
local unbound_result = place.tick(unbound)
check(unbound_result and unbound_result.status == "done" and unbound_result.detail:match("pending first output")
  and created == 1 and removed == 1,
  "mining-drill placement keeps nil runtime output binding explicitly pending first output")
created, removed, drop_target, recipient.valid, target_matches = 0, 0, nil, true, { recipient }
local target_lost = { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 }, output_target = { x = 2.5, y = 0.5 } }
place.start(target_lost)
check(place.tick(target_lost) == nil, "placement retains the exact target during output binding verification")
recipient.valid = false
game.tick = game.tick + 1
local target_lost_result = place.tick(target_lost)
check(target_lost_result and target_lost_result.status == "failed"
  and target_lost_result.detail:match("expected output target vanished") and created == 1 and removed == 1,
  "placement fails immediately when the exact expected output target is invalidated")
recipient.valid = true
created, removed, drop_target, target_matches = 0, 0, nil, { recipient }
local placed_lost = { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 }, output_target = { x = 2.5, y = 0.5 } }
place.start(placed_lost)
check(place.tick(placed_lost) == nil, "placement retains the exact new entity during output binding verification")
last_built.valid = false
game.tick = game.tick + 1
local placed_lost_result = place.tick(placed_lost)
check(placed_lost_result and placed_lost_result.status == "failed"
  and placed_lost_result.detail:match("exact placed entity vanished") and created == 1 and removed == 1,
  "placement fails immediately when the exact new entity is invalidated")
created, removed, pickup_target, drop_target, target_matches = 0, 0, source, recipient, { recipient }
local inserter = { item = "burner-inserter", position = { x = 1.5, y = 0.5 },
  output_target = { x = 2.5, y = 0.5 } }
place.start(inserter)
check(place.tick(inserter) == nil, "inserter placement also defers exact output verification")
game.tick = game.tick + 1
local inserter_result = place.tick(inserter)
check(inserter_result and inserter_result.status == "done" and created == 1 and removed == 1,
  "inserter placement prechecks and verifies its exact output binding")
created, removed, pickup_target, drop_target, target_matches = 0, 0, source, recipient, { source, recipient }
local coupled_inserter = { item = "burner-inserter", position = { x = 1.5, y = 0.5 },
  input_target = { x = 1.5, y = -0.5 }, output_target = { x = 2.5, y = 0.5 } }
place.start(coupled_inserter)
check(place.tick(coupled_inserter) == nil and created == 1 and removed == 1,
  "coupled inserter placement waits for Factorio's runtime input and output targets")
game.tick = game.tick + 1
local coupled_inserter_result = place.tick(coupled_inserter)
check(coupled_inserter_result and coupled_inserter_result.status == "done",
  "coupled inserter placement completes only when both runtime targets match")
created, removed, pickup_target, drop_target, target_matches = 0, 0, replacement, recipient, { source, recipient }
local wrong_input = { item = "burner-inserter", position = { x = 1.5, y = 0.5 },
  input_target = { x = 1.5, y = -0.5 }, output_target = { x = 2.5, y = 0.5 } }
place.start(wrong_input)
check(place.tick(wrong_input) == nil and created == 1 and removed == 1,
  "coupled inserter commits one physical placement before runtime verification")
game.tick = game.tick + 1
local wrong_input_result = place.tick(wrong_input)
check(wrong_input_result and wrong_input_result.status == "failed"
  and wrong_input_result.detail:match("different runtime input target") and created == 1 and removed == 1,
  "wrong runtime input binding fails without rollback or automatic replacement")
local build_plan = require("scripts.actions.build_plan")
body.force.recipes, body.crafting_queue_size = {}, 0
created, removed, pickup_target, drop_target, target_matches = 0, 0, source, recipient, { source, recipient }
local coupled_plan = { steps = { { item = "burner-inserter", position = { x = 1.5, y = 0.5 },
  input_target = { x = 1.5, y = -0.5 }, output_target = { x = 2.5, y = 0.5 } } } }
build_plan.start(coupled_plan)
check(build_plan.tick(coupled_plan) == nil and created == 1 and removed == 1,
  "build_plan carries coupled provisional endpoints into one physical placement")
game.tick = game.tick + 1
local coupled_plan_result = build_plan.tick(coupled_plan)
check(coupled_plan_result and coupled_plan_result.status == "done",
  "build_plan accepts coupled placement only after both Factorio runtime targets match")
created, removed, pickup_target, drop_target, target_matches = 0, 0, source, nil, { recipient }
local planned = { steps = { { item = "burner-inserter", position = { x = 1.5, y = 0.5 },
  output_target = { x = 2.5, y = 0.5 } } } }
build_plan.start(planned)
local planned_pending = build_plan.tick(planned)
local planned_same_tick = build_plan.tick(planned)
check(planned_pending == nil and planned_same_tick == nil and created == 1 and removed == 1,
  "build_plan preserves the exact new entity through a later-tick output check")
game.tick = game.tick + 1
local planned_result = build_plan.tick(planned)
check(planned_result and planned_result.status == "failed" and planned_result.detail:match("did not bind")
  and created == 1 and removed == 1,
  "build_plan refuses to infer an inserter binding from provisional geometry when runtime drop_target is nil")

created, removed, drop_target, target_matches, planned_recipient = 0, 0, nil, {}, nil
local same_plan_target = { steps = {
  { item = "wooden-chest", position = { x = 2.5, y = 0.5 } },
  { item = "burner-inserter", position = { x = 1.5, y = 0.5 }, output_target = { x = 2.5, y = 0.5 } },
} }
local same_plan_ok, same_plan_error = pcall(build_plan.start, same_plan_target)
check(same_plan_ok, "build_plan preflight accepts one eligible earlier planned output recipient: " .. tostring(same_plan_error))
check(build_plan.tick(same_plan_target) == nil and planned_recipient ~= nil,
  "build_plan creates the planned recipient before resolving the producer target")
check(build_plan.tick(same_plan_target) == nil and created == 2,
  "build_plan resolves the exact player-owned runtime recipient before producer placement")
last_built.drop_target = planned_recipient
game.tick = game.tick + 1
local same_plan_result = build_plan.tick(same_plan_target)
check(same_plan_result and same_plan_result.status == "done",
  "same-plan output target completes only after exact runtime binding")

storage = {}
local insertion_tick = game.tick
created, removed, inserted, drop_target, target_matches = 0, 0, 0, nil, { recipient }
body.get_item_count = function(_, name) return name == "wood" and 1 or 1 end
local planned_flow = { steps = { { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 },
  insert = { wood = 1 }, output_target = { x = 2.5, y = 0.5 } } } }
build_plan.start(planned_flow)
local planned_flow_initial = build_plan.tick(planned_flow)
check(planned_flow_initial == nil and created == 1 and inserted == 1,
  "build_plan applies legitimate starter material before awaiting mining-drill output binding")
local starter = activity.snapshot(insertion_tick)
check(starter.transfer_actions == 1 and starter.transferred_items == 1
  and starter.events[1].tick == insertion_tick and starter.events[1].action == "insert"
  and starter.target_actions[1].target.name == "burner-mining-drill"
  and starter.target_actions[1].target.type == "mining-drill"
  and starter.target_actions[1].target.position.x == 1.5 and starter.target_actions[1].target.position.y == 0.5,
  "starter transfer is visible at its physical tick with exact placed identity while binding waits")
for _ = 1, 5 do
  game.tick = game.tick + 1
  check(build_plan.tick(planned_flow) == nil and inserted == 1,
    "build_plan keeps one exact fueled drill in flight while first output has not materialized")
end
last_built.drop_target = recipient
game.tick = game.tick + 1
local planned_flow_result = build_plan.tick(planned_flow)
check(planned_flow_result and planned_flow_result.status == "done" and inserted == 1,
  "build_plan completes after first produced output materializes the exact runtime target")
check(activity.snapshot(insertion_tick).transfer_actions == 1
  and activity.snapshot(insertion_tick + 1).transfer_actions == 0,
  "waiting ticks and completion retain one event in only the insertion interval")

created, removed, inserted, drop_target, target_matches = 0, 0, 0, nil, { recipient }
local planned_wrong_flow = { steps = { { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 },
  insert = { wood = 1 }, output_target = { x = 2.5, y = 0.5 } } } }
build_plan.start(planned_wrong_flow)
check(build_plan.tick(planned_wrong_flow) == nil and inserted == 1,
  "build_plan fuels once before a mining drill exposes a runtime target")
last_built.drop_target = replacement
game.tick = game.tick + 1
local planned_wrong_flow_result = build_plan.tick(planned_wrong_flow)
check(planned_wrong_flow_result and planned_wrong_flow_result.status == "failed"
  and planned_wrong_flow_result.detail:match("different runtime output target") and inserted == 1,
  "build_plan fails an exact non-nil wrong target exposed by first output without reinserting fuel")
check(activity.snapshot(insertion_tick).transfer_actions == 2,
  "later binding failure retains its earlier starter transfer")

created, removed, drop_target, target_matches = 0, 0, nil, { recipient }
local planned_mismatch = { steps = { { item = "burner-inserter", position = { x = 1.5, y = 0.5 },
  output_target = { x = 2.5, y = 0.5 } } } }
build_plan.start(planned_mismatch)
check(build_plan.tick(planned_mismatch) == nil and created == 1 and removed == 1,
  "build_plan does not report an immediate false output mismatch")
game.tick = game.tick + 1
target_matches = { replacement }
local planned_mismatch_result = build_plan.tick(planned_mismatch)
check(planned_mismatch_result and planned_mismatch_result.status == "failed"
  and planned_mismatch_result.detail:match("did not bind")
  and created == 1 and removed == 1,
  "build_plan reports a later-tick exact output mismatch without recreating the entity")
created, removed, drop_target, target_matches = 0, 0, nil, { recipient }
local planned_unbound = { steps = { { item = "burner-inserter", position = { x = 1.5, y = 0.5 },
  output_target = { x = 2.5, y = 0.5 } } } }
build_plan.start(planned_unbound)
check(build_plan.tick(planned_unbound) == nil, "build_plan begins later-tick output-tile verification")
target_matches = {}
game.tick = game.tick + 1
local planned_unbound_result = build_plan.tick(planned_unbound)
check(planned_unbound_result and planned_unbound_result.status == "failed"
  and planned_unbound_result.detail:match("did not bind") and created == 1 and removed == 1,
  "build_plan fails honestly when the live output tile has no recipient")

created, removed, inserted, insert_limit, target_matches = 0, 0, 0, 7, {}
body.get_item_count = function(name) return name == "wood" and 10 or 1 end
local partial_insert_plan = { steps = {
  { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 }, insert = { wood = 10 } },
  { item = "wooden-chest", position = { x = 3.5, y = 0.5 } },
} }
build_plan.start(partial_insert_plan)
local partial_insert_result = build_plan.tick(partial_insert_plan)
check(partial_insert_result and partial_insert_result.status == "partial"
  and partial_insert_result.outcome.code == "PARTIAL_INSERT"
  and partial_insert_result.outcome.total_inserted == 7
  and partial_insert_result.outcome.transfers[1].requested == 10
  and partial_insert_result.outcome.transfers[1].remainder == 3
  and created == 1 and inserted == 7,
  "build_plan stops after useful bounded partial insertion and reports its exact remainder")
check(activity.snapshot(insertion_tick).events[#activity.snapshot(insertion_tick).events].item_count == 7,
  "capacity-limited partial insertion records only accepted items")

-- Reuse real build-plan interactions with conserved simulated inventory.
local function starter_case(items, stock, limit, rejected, later_steps, stop_on_error)
  storage = {}; game.tick = game.tick + 1
  created, removed, inserted, insert_limit, rejected_item, target_matches = 0, 0, 0, limit, rejected, {}
  body.get_item_count = function(name) return stock[name] or 0 end
  body.remove_item = function(stack)
    assert((stock[stack.name] or 0) >= stack.count)
    stock[stack.name] = stock[stack.name] - stack.count
    removed = removed + stack.count
  end
  local steps = { { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 }, insert = items } }
  for _, step in ipairs(later_steps or {}) do steps[#steps + 1] = step end
  local task = { steps = steps, stop_on_error = stop_on_error }
  build_plan.start(task)
  local result = build_plan.tick(task)
  while not result do game.tick = game.tick + 1; result = build_plan.tick(task) end
  return result, activity.snapshot(), stock
end
local bare, bare_activity = starter_case(nil, { ["burner-mining-drill"] = 1 })
check(bare.status == "done" and bare_activity.transfer_actions == 0,
  "placement without starter items creates no insertion event")
local limited, limited_activity, limited_stock = starter_case({ wood = 10 },
  { ["burner-mining-drill"] = 1, wood = 3 })
check(limited.status == "partial" and limited.outcome.total_inserted == 3
  and limited.outcome.transfers[1].available == 3 and limited.outcome.transfers[1].remainder == 7
  and limited_activity.transfer_actions == 1 and limited_activity.transferred_items == 3 and limited_stock.wood == 0,
  "inventory-limited partial starter counts accepted quantities and conserves inventory")
prototypes.item.coal = { name = "coal" }
local mixed, mixed_activity, mixed_stock = starter_case({ wood = 2, coal = 3 },
  { ["burner-mining-drill"] = 1, wood = 2, coal = 3 }, nil, "coal")
check(mixed.status == "partial" and mixed_activity.transfer_actions == 1
  and mixed_activity.transferred_items == 2 and #mixed_activity.inserted_items == 1
  and mixed_activity.inserted_items[1].name == "wood" and mixed_stock.wood == 0 and mixed_stock.coal == 3,
  "mixed accepted and rejected starters produce one interaction containing accepted items only")
local multiple, multiple_activity = starter_case({ wood = 2, coal = 3 },
  { ["burner-mining-drill"] = 1, wood = 2, coal = 3 })
check(multiple.status == "done" and multiple_activity.transfer_actions == 1
  and multiple_activity.transferred_items == 5 and #multiple_activity.inserted_items == 2,
  "multiple accepted starter items count as one insertion interaction")
for _, stock in ipairs({ { ["burner-mining-drill"] = 1, wood = 2 }, { ["burner-mining-drill"] = 1 } }) do
  local zero, zero_activity = starter_case({ wood = 2 }, stock, 0)
  check(zero.status == "failed" and zero_activity.transfer_actions == 0 and inserted == 0,
    "zero acceptance creates no insertion event")
end
local multi, multi_activity = starter_case({ wood = 1 },
  { ["burner-mining-drill"] = 2, wood = 2 }, nil, nil,
  { { item = "burner-mining-drill", position = { x = 3.5, y = 0.5 }, insert = { wood = 1 } } })
check(multi.status == "done" and multi_activity.transfer_actions == 2 and multi_activity.transferred_items == 2
  and #multi_activity.target_actions == 2 and multi_activity.target_actions[2].target.position.x == 3.5,
  "multiple placed entities retain separate exact insertion interactions")
for _, stop_on_error in ipairs({ false, true }) do
  local failed, failed_activity = starter_case({ wood = 1 },
    { ["burner-mining-drill"] = 1, wood = 1 }, nil, nil,
    { { item = "wooden-chest", position = { x = 3.5, y = 0.5 } } }, stop_on_error)
  check(failed.status == (stop_on_error and "failed" or "done") and failed.detail:match("step 2 failed")
    and failed_activity.transfer_actions == 1 and inserted == 1,
    "later-step failure retains committed starter transfer with stop_on_error=" .. tostring(stop_on_error))
end
-- Dispatch real queued build plans to cover terminal cancellation and invalidation.
local tasks = require("scripts.tasks")
for _, terminal in ipairs({ "cancel", "target-invalid", "entity-invalid", "complete" }) do
  storage = { tasks = { active = nil, queue = {}, records = {}, next_id = 1 } }
  game.tick = game.tick + 1
  created, removed, inserted, insert_limit, rejected_item, drop_target, target_matches = 0, 0, 0, nil, nil, nil, { recipient }
  recipient.valid = true
  local stock = { ["burner-mining-drill"] = 1, wood = 1 }
  body.get_item_count = function(name) return stock[name] or 0 end
  body.remove_item = function(stack) stock[stack.name] = stock[stack.name] - stack.count end
  local id = tasks.enqueue({ task = { type = "build_plan", steps = {
    { item = "burner-mining-drill", position = { x = 1.5, y = 0.5 }, insert = { wood = 1 }, output_target = { x = 2.5, y = 0.5 } },
  } } }).task_id
  local tick = game.tick
  tasks.on_tick()
  check(tasks.get({ task_id = id }).status == "running" and activity.snapshot(tick).transfer_actions == 1
    and stock.wood == 0, terminal .. " task exposes conserved starter insertion before terminal status")
  if terminal == "cancel" then
    check(tasks.cancel({ task_id = id }).cancelled == 1, "real task cancellation retires waiting build plan")
  elseif terminal == "target-invalid" then recipient.valid = false
  elseif terminal == "entity-invalid" then last_built.valid = false
  else last_built.drop_target = recipient end
  game.tick = game.tick + 1
  tasks.on_tick()
  local expected = terminal == "cancel" and "cancelled" or terminal == "complete" and "done" or "failed"
  check(tasks.get({ task_id = id }).status == expected and activity.snapshot(tick).transfer_actions == 1
    and activity.snapshot(tick).transferred_items == 1 and inserted == 1,
    terminal .. " retains exactly one committed starter event after task dispatch")
end
recipient.valid = true
-- Restore the shared fixture defaults for the remaining placement cases.
insert_limit, rejected_item = nil, nil
body.get_item_count = function() return 1 end
body.remove_item = function(stack) removed = removed + stack.count end
-- A tile-corner coordinate inside an owned entity names that entity's exact
-- position instead of a bare "does not identify" failure.
local resolver = require("scripts.output_target")
local hint_body = { position = { x = 0.5, y = 0.5 }, force = force, surface = surface }
target_matches = { recipient }
local hint_ok, hint_error = pcall(resolver.resolve, hint_body, { x = 2.1, y = 0.7 })
check(not hint_ok and tostring(hint_error):match("lies inside stone%-furnace, whose exact position is %(2.5, 0.5%)") ~= nil,
  "an inexact output_target names the covering entity's exact position")
-- Exercise the new recipient types through physical placement, not just the
-- allowlist. Runtime binding is deliberately independent of eligibility.
local recipients = {
  { name = "burner-mining-drill", type = "mining-drill" },
  { name = "boiler", type = "boiler" },
  { name = "lab", type = "lab" },
  { name = "burner-inserter", type = "inserter" },
}
for _, spec in ipairs(recipients) do
  local proto = prototypes.item[spec.name] and prototypes.item[spec.name].place_result
    or { name = spec.name, type = spec.type }
  proto.collision_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } }
  prototypes.item[spec.name] = { place_result = proto }
  local target = { valid = true, name = spec.name, type = spec.type, force = force,
    position = { x = 2.5, y = 0.5 }, bounding_box = recipient.bounding_box }
  target_matches = { target }
  check(resolver.resolve(body, target.position).entity == target,
    spec.name .. " resolves as a provisional drop recipient")
  local pickup_ok, pickup_error = pcall(resolver.resolve, body, target.position, "input_target", "input")
  check((spec.type == "lab" and pickup_ok)
    or (spec.type ~= "lab" and not pickup_ok and tostring(pickup_error):match("pickup source")),
    spec.name .. " has independent mechanically supported pickup eligibility")
  local pickup_entity = resolver.recipient_at(body, target.position, "input")
  check((spec.type == "lab" and pickup_entity == target) or (spec.type ~= "lab" and pickup_entity == nil),
    spec.name .. " endpoint discovery respects the pickup role")
  if spec.type ~= "lab" then
    for _, action in ipairs({ place.start, function(task) build_plan.start({ steps = { task } }) end }) do
      local ok, err = pcall(action, { item = "burner-inserter", position = { x = 1.5, y = 0.5 }, input_target = target.position })
      check(not ok and tostring(err):match("pickup source"), spec.name .. " is rejected as an existing placement pickup source")
    end
    target_matches = {}
    local ok, err = pcall(build_plan.start, { steps = {
      { item = spec.name, position = target.position },
      { item = "burner-inserter", position = { x = 1.5, y = 0.5 }, input_target = target.position },
    } })
    check(not ok and tostring(err):match("pickup source"), spec.name .. " is rejected as a planned pickup source")
  end
  for _, mode in ipairs({ "matched", "wrong", "nil" }) do
    for _, planned in ipairs({ false, true }) do
      created, removed, target_matches, pickup_target = 0, 0, { source, target }, source
      drop_target = mode == "matched" and target or mode == "wrong" and replacement or nil
      local step = { item = "burner-inserter", position = { x = 1.5, y = 0.5 },
        input_target = source.position, output_target = target.position }
      local task = planned and { steps = { step } } or step
      local action = planned and build_plan or place
      action.start(task)
      check(action.tick(task) == nil and created == 1 and removed == 1,
        spec.name .. " " .. mode .. " waits for later-tick runtime binding in " .. (planned and "build_plan" or "place"))
      game.tick = game.tick + 1
      local result = action.tick(task)
      check(result and result.status == (mode == "matched" and "done" or "failed")
        and created == 1 and removed == 1,
        spec.name .. " " .. mode .. " runtime result preserves committed placement in " .. (planned and "build_plan" or "place"))
    end
  end
  created, removed, target_matches, drop_target = 0, 0, {}, nil
  local task = { steps = {
    { item = spec.name, position = target.position },
    { item = "burner-inserter", position = { x = 1.5, y = 0.5 }, output_target = target.position },
  } }
  build_plan.start(task)
  check(build_plan.tick(task) == nil and created == 1, spec.name .. " planned recipient is placed first")
  local planned_target = last_built
  check(build_plan.tick(task) == nil and created == 2, spec.name .. " planned recipient is resolved before inserter placement")
  last_built.drop_target = planned_target
  game.tick = game.tick + 1
  local result = build_plan.tick(task)
  check(result and result.status == "done" and created == 2 and removed == 2,
    spec.name .. " planned recipient completes only after exact runtime binding")
end
-- Revalidation must retain the input role even when an eligible entity's
-- capabilities change after preflight.
for _, planned in ipairs({ false, true }) do
  source.type, target_matches, created = "container", { source, recipient }, 0
  local step = { item = "burner-inserter", position = { x = 1.5, y = 0.5 }, input_target = source.position }
  local task = planned and { steps = { step } } or step
  local action = planned and build_plan or place
  action.start(task)
  source.type = "boiler"
  local ok, result = pcall(action.tick, task)
  check((not ok and tostring(result):match("pickup source"))
    or (ok and result and result.status == "failed"),
    "pickup eligibility is revalidated before " .. (planned and "build_plan" or "place") .. " mutation")
  check(created == 0, "ineligible pickup revalidation creates no entity")
end
source.type = "container"
created, removed, target_matches, pickup_target = 0, 0, {}, nil
local lab_input_plan = { steps = {
  { item = "lab", position = source.position },
  { item = "burner-inserter", position = { x = 1.5, y = 0.5 }, input_target = source.position },
} }
build_plan.start(lab_input_plan)
check(build_plan.tick(lab_input_plan) == nil and created == 1, "planned lab pickup inventory is placed first")
local planned_lab = last_built
pickup_target = planned_lab
check(build_plan.tick(lab_input_plan) == nil and created == 2, "planned lab pickup is resolved at the exact input endpoint")
game.tick = game.tick + 1
local lab_input_result = build_plan.tick(lab_input_plan)
check(lab_input_result and lab_input_result.status == "done", "planned lab pickup completes on exact runtime pickup_target")
local unsupported = { valid = true, name = "small-electric-pole", type = "electric-pole", force = force, position = { x = 2.5, y = 0.5 } }
target_matches = { unsupported }
for _, kind in ipairs({ "input", "output" }) do
  local ok, err = pcall(resolver.resolve, body, unsupported.position, kind .. "_target", kind)
  check(not ok and tostring(err):match(kind == "input" and "pickup source" or "drop recipient"),
    "unsupported endpoint has useful " .. kind .. " guidance")
end
-- Real narrow burner geometry and 1.2-tile vectors: both existing and earlier
-- planned recipients retain exact later-tick binding and committed consumption.
local narrow = { name = "burner-inserter", type = "inserter", tile_width = 1, tile_height = 1,
  inserter_pickup_position = { 0, -1 }, inserter_drop_position = { 0, 1.2 },
  collision_box = { left_top = { x = -38/256, y = -38/256 }, right_bottom = { x = 38/256, y = 38/256 } } }
prototypes.item["burner-inserter"].place_result = narrow
for _, direction in ipairs({ 0, 4, 8, 12 }) do
  for _, planned in ipairs({ false, true }) do
    for _, mode in ipairs({ "matched", "wrong", "nil", "vanished" }) do
      local position = { x = 0.5, y = 0.5 }
      local point = resolver.output_position(narrow, position, direction)
      local target_position = { x = math.floor(point.x) + 0.5, y = math.floor(point.y) + 0.5 }
      local target = { valid = true, name = "burner-inserter", type = "inserter", force = force,
        position = target_position, bounding_box = require("scripts.placement_geometry").footprint(narrow, target_position, 0) }
      created, removed, target_matches, drop_target = 0, 0, planned and {} or { target }, nil
      local step = { item = "burner-inserter", position = position, direction = direction, output_target = target_position }
      local task = planned and { steps = { { item = "burner-inserter", position = target_position }, step } } or step
      local action = planned and build_plan or place
      action.start(task)
      if planned then
        check(action.tick(task) == nil and created == 1, "narrow earlier recipient commits first " .. direction .. " " .. mode)
        target = last_built
        -- Model the actual prototype collision box of the committed recipient.
        target.bounding_box = require("scripts.placement_geometry").footprint(narrow, target_position, 0)
      end
      check(action.tick(task) == nil and created == (planned and 2 or 1)
        and removed == created, "narrow fuel edge remains provisional on creation tick " .. direction .. " " .. mode)
      if mode == "matched" then last_built.drop_target = target
      elseif mode == "wrong" then last_built.drop_target = replacement
      elseif mode == "vanished" then target.valid = false end
      game.tick = game.tick + 1
      local result = action.tick(task)
      check(result and result.status == (mode == "matched" and "done" or "failed")
        and created == (planned and 2 or 1) and removed == created,
        "narrow " .. (planned and "planned" or "existing") .. " " .. mode .. " preserves runtime truth and consumption " .. direction)
    end
  end
end
created, removed, target_matches = 0, 0, {}
local ambiguous_ok, ambiguous_error = pcall(build_plan.start, { steps = {
  { item = "burner-inserter", position = { x = 1.5, y = 0.5 } },
  { item = "wooden-chest", position = { x = 1.5, y = 0.5 } },
  { item = "burner-inserter", position = { x = 0.5, y = 0.5 }, direction = 12, output_target = { x = 1.5, y = 0.5 } },
} })
check(not ambiguous_ok and tostring(ambiguous_error):match("ambiguous") and created == 0 and removed == 0,
  "ambiguous earlier narrow recipients are refused before any committed effect")

local remote_plan_ok = pcall(build_plan.start, { steps = {
  { item = "burner-inserter", position = { x = 30.75, y = 0.5 } },
  { item = "burner-inserter", position = { x = 29, y = 0.5 }, direction = 12, output_target = { x = 30.75, y = 0.5 } },
} })
check(not remote_plan_ok and created == 0 and removed == 0,
  "earlier planned recipient beyond local range cannot bypass exact target bounds")

local geometry = require("scripts.placement_geometry")
local existing = { valid = true, name = "burner-inserter", type = "inserter", force = force,
  position = { x = 1.25, y = 0.5 }, bounding_box = geometry.footprint(narrow, { x = 1.25, y = 0.5 }, 0) }
target_matches = { existing }
local mixed_ok, mixed_error = pcall(build_plan.start, { steps = {
  { item = "burner-inserter", position = { x = 1.75, y = 0.5 } },
  { item = "burner-inserter", position = { x = 0.5, y = 0.5 }, direction = 12, output_target = existing.position },
} })
check(not mixed_ok and tostring(mixed_error):match("ambiguous") and created == 0 and removed == 0,
  "existing and non-overlapping earlier planned recipients remain ambiguous before mutation")
for _, kind in ipairs({ "input", "output" }) do
  created, removed, target_matches = 0, 0, {}
  local position = { x = 0.5, y = 0.5 }
  local endpoint = kind == "input" and resolver.input_position(narrow, position, 0)
    or resolver.output_position(narrow, position, 0)
  local target_position = { x = math.floor(endpoint.x) + 0.5, y = math.floor(endpoint.y) + 0.5 }
  local step = { item = "burner-inserter", position = position, direction = 0 }
  step[kind .. "_target"] = target_position
  local task = { steps = {
    { item = kind == "input" and "wooden-chest" or "burner-inserter", position = target_position }, step,
  } }
  build_plan.start(task)
  check(build_plan.tick(task) == nil and created == 1 and removed == 1,
    "exact earlier " .. kind .. " recipient commits once before substitution")
  local original = last_built
  original.valid = false
  local changed = { valid = true, name = original.name, type = original.type, force = force,
    position = original.position, bounding_box = original.bounding_box }
  target_matches = { changed }
  local result = build_plan.tick(task)
  check(result and result.status == "failed" and result.detail:match("wrong runtime identity")
    and result.detail:match("placed 1/2") and created == 1 and removed == 1,
    "same-name changed earlier " .. kind .. " target fails without another committed placement")
end

created, removed, target_matches = 0, 0, {}
local wrong_bounded_plan = pcall(build_plan.start, { steps = {
  { item = "burner-inserter", position = { x = 30.75, y = 0.5 } },
  { item = "burner-inserter", position = { x = 30.25, y = 0.5 } },
  { item = "burner-inserter", position = { x = 29, y = 0.5 }, direction = 12, output_target = { x = 30.75, y = 0.5 } },
} })
check(not wrong_bounded_plan and created == 0 and removed == 0,
  "a different bounded recipient cannot admit the exact out-of-range planned target")

os.exit(failures == 0 and 0 or 1)
