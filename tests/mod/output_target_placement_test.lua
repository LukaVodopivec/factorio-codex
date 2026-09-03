local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local force = { is_chunk_charted = function() return true end }
local recipient = { valid = true, name = "stone-furnace", type = "furnace", force = force,
  position = { x = 2, y = 0 }, selection_box = { left_top = { x = 1.5, y = -0.5 }, right_bottom = { x = 2.5, y = 0.5 } },
  bounding_box = { left_top = { x = 1.5, y = -0.5 }, right_bottom = { x = 2.5, y = 0.5 } } }
local replacement = { valid = true, name = "steel-furnace", type = "furnace", force = force,
  position = { x = 2, y = 0 }, selection_box = recipient.selection_box }
local source = { valid = true, name = "wooden-chest", type = "container", force = force,
  position = { x = 0, y = -1 }, selection_box = { left_top = { x = -0.5, y = -1.5 }, right_bottom = { x = 0.5, y = -0.5 } } }
local target_matches, created, removed, pickup_target, drop_target, last_built = { recipient }, 0, 0, source, recipient, nil
local runtime_drop_position = { x = 2, y = 0 }
local surface
surface = {
  find_entities_filtered = function() return target_matches end,
  can_place_entity = function() return true end,
  create_entity = function(args)
    created = created + 1
    last_built = { valid = true, name = args.name,
      type = args.name == "burner-inserter" and "inserter" or "mining-drill", position = args.position,
      pickup_target = pickup_target, drop_target = drop_target,
      direction = args.direction, drop_position = runtime_drop_position, prototype = prototypes.item[args.name].place_result,
      force = force, surface = surface }
    return last_built
  end,
}
local body = { valid = true, position = { x = 0, y = 0 }, build_distance = 6, force = force, surface = surface,
  get_item_count = function() return 1 end, remove_item = function(args) removed = removed + args.count end }
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end }
_G.defines = { direction = { north = 0 }, build_check_type = { manual = 1 } }
_G.game = { tick = 100 }
_G.prototypes = { item = {
  ["burner-mining-drill"] = { place_result = { name = "burner-mining-drill", type = "mining-drill", vector_to_place_result = { x = 1, y = 0 } } },
  ["burner-inserter"] = { place_result = { name = "burner-inserter", type = "inserter", inserter_drop_position = { x = 1, y = 0 } } },
} }
local place = require("scripts.actions.build").place
drop_target = nil
local valid = { item = "burner-mining-drill", position = { x = 1, y = 0 }, output_target = { x = 2, y = 0 } }
place.start(valid)
local placed_pending = place.tick(valid)
local same_tick_pending = place.tick(valid)
check(placed_pending == nil and same_tick_pending == nil and created == 1 and removed == 1,
  "placement preserves the exact new entity and waits beyond its creation tick")
game.tick = game.tick + 1
local valid_result = place.tick(valid)
check(valid_result and valid_result.status == "done" and created == 1 and removed == 1,
  "placement verifies the live output tile one tick later without waiting for drop_target assignment")
created, removed, drop_target, runtime_drop_position = 0, 0, recipient, { x = 2.25, y = 0 }
local wrong_geometry = { item = "burner-mining-drill", position = { x = 1, y = 0 }, output_target = { x = 2, y = 0 } }
place.start(wrong_geometry)
check(place.tick(wrong_geometry) == nil, "placement retains an entity whose runtime endpoint still needs verification")
game.tick = game.tick + 1
local wrong_geometry_result = place.tick(wrong_geometry)
check(wrong_geometry_result and wrong_geometry_result.status == "done" and created == 1,
  "authoritative exact runtime binding outranks a prototype/runtime endpoint discrepancy")
runtime_drop_position = { x = 2, y = 0 }
created, removed, target_matches, recipient.valid = 0, 0, { recipient }, true
local invalidated = { item = "burner-mining-drill", position = { x = 1, y = 0 }, output_target = { x = 2, y = 0 } }
place.start(invalidated)
recipient.valid, target_matches = false, { replacement }
local invalidated_result = place.tick(invalidated)
check(invalidated_result and invalidated_result.status == "failed" and invalidated_result.detail:match("changed before placement") and created == 0 and removed == 0, "placement refuses an output recipient invalidated after search")
recipient.valid, target_matches, drop_target = true, { recipient }, nil
local mismatch = { item = "burner-mining-drill", position = { x = 1, y = 0 }, output_target = { x = 2, y = 0 } }
place.start(mismatch)
check(place.tick(mismatch) == nil and created == 1 and removed == 1,
  "placement does not report an immediate false output mismatch")
game.tick = game.tick + 1
target_matches = { replacement }
local mismatch_result = place.tick(mismatch)
check(mismatch_result and mismatch_result.status == "failed" and mismatch_result.detail:match("live output tile") and created == 1 and removed == 1, "post-place recipient mismatch is explicit and requires physical recovery")
created, removed, drop_target, target_matches = 0, 0, nil, { recipient }
local unbound = { item = "burner-mining-drill", position = { x = 1, y = 0 }, output_target = { x = 2, y = 0 } }
place.start(unbound)
check(place.tick(unbound) == nil, "placement begins later-tick output-tile verification")
target_matches = {}
game.tick = game.tick + 1
local unbound_result = place.tick(unbound)
check(unbound_result and unbound_result.status == "failed" and unbound_result.detail:match("live output tile")
  and created == 1 and removed == 1,
  "placement fails honestly when the live output tile has no recipient")
created, removed, drop_target, recipient.valid, target_matches = 0, 0, nil, true, { recipient }
local target_lost = { item = "burner-mining-drill", position = { x = 1, y = 0 }, output_target = { x = 2, y = 0 } }
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
local placed_lost = { item = "burner-mining-drill", position = { x = 1, y = 0 }, output_target = { x = 2, y = 0 } }
place.start(placed_lost)
check(place.tick(placed_lost) == nil, "placement retains the exact new entity during output binding verification")
last_built.valid = false
game.tick = game.tick + 1
local placed_lost_result = place.tick(placed_lost)
check(placed_lost_result and placed_lost_result.status == "failed"
  and placed_lost_result.detail:match("exact placed entity vanished") and created == 1 and removed == 1,
  "placement fails immediately when the exact new entity is invalidated")
created, removed, pickup_target, drop_target, target_matches = 0, 0, source, recipient, { recipient }
local inserter = { item = "burner-inserter", position = { x = 1, y = 0 },
  output_target = { x = 2, y = 0 } }
place.start(inserter)
check(place.tick(inserter) == nil, "inserter placement also defers exact output verification")
game.tick = game.tick + 1
local inserter_result = place.tick(inserter)
check(inserter_result and inserter_result.status == "done" and created == 1 and removed == 1,
  "inserter placement prechecks and verifies its exact output binding")
local build_plan = require("scripts.actions.build_plan")
body.force.recipes, body.crafting_queue_size = {}, 0
created, removed, pickup_target, drop_target, target_matches = 0, 0, source, nil, { recipient }
local planned = { steps = { { item = "burner-inserter", position = { x = 1, y = 0 },
  output_target = { x = 2, y = 0 } } } }
build_plan.start(planned)
local planned_pending = build_plan.tick(planned)
local planned_same_tick = build_plan.tick(planned)
check(planned_pending == nil and planned_same_tick == nil and created == 1 and removed == 1,
  "build_plan preserves the exact new entity through a later-tick output check")
game.tick = game.tick + 1
local planned_result = build_plan.tick(planned)
check(planned_result and planned_result.status == "done" and created == 1 and removed == 1,
  "build_plan verifies the live output tile one tick later without drop_target assignment")

created, removed, drop_target, target_matches = 0, 0, nil, { recipient }
local planned_mismatch = { steps = { { item = "burner-inserter", position = { x = 1, y = 0 },
  output_target = { x = 2, y = 0 } } } }
build_plan.start(planned_mismatch)
check(build_plan.tick(planned_mismatch) == nil and created == 1 and removed == 1,
  "build_plan does not report an immediate false output mismatch")
game.tick = game.tick + 1
target_matches = { replacement }
local planned_mismatch_result = build_plan.tick(planned_mismatch)
check(planned_mismatch_result and planned_mismatch_result.status == "failed"
  and planned_mismatch_result.detail:match("live output tile")
  and created == 1 and removed == 1,
  "build_plan reports a later-tick exact output mismatch without recreating the entity")
created, removed, drop_target, target_matches = 0, 0, nil, { recipient }
local planned_unbound = { steps = { { item = "burner-inserter", position = { x = 1, y = 0 },
  output_target = { x = 2, y = 0 } } } }
build_plan.start(planned_unbound)
check(build_plan.tick(planned_unbound) == nil, "build_plan begins later-tick output-tile verification")
target_matches = {}
game.tick = game.tick + 1
local planned_unbound_result = build_plan.tick(planned_unbound)
check(planned_unbound_result and planned_unbound_result.status == "failed"
  and planned_unbound_result.detail:match("live output tile") and created == 1 and removed == 1,
  "build_plan fails honestly when the live output tile has no recipient")
os.exit(failures == 0 and 0 or 1)
