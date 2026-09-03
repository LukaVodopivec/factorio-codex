local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local force = { is_chunk_charted = function() return true end }
local recipient = { valid = true, name = "stone-furnace", type = "furnace", force = force,
  position = { x = 2, y = 0 }, selection_box = { left_top = { x = 1.5, y = -0.5 }, right_bottom = { x = 2.5, y = 0.5 } } }
local replacement = { valid = true, name = "steel-furnace", type = "furnace", force = force,
  position = { x = 2, y = 0 }, selection_box = recipient.selection_box }
local source = { valid = true, name = "wooden-chest", type = "container", force = force,
  position = { x = 0, y = -1 }, selection_box = { left_top = { x = -0.5, y = -1.5 }, right_bottom = { x = 0.5, y = -0.5 } } }
local target_matches, created, removed, pickup_target, drop_target = { recipient }, 0, 0, source, recipient
local surface = {
  find_entities_filtered = function() return target_matches end,
  can_place_entity = function() return true end,
  create_entity = function(args) created = created + 1; return { valid = true, name = args.name,
    type = args.name == "burner-inserter" and "inserter" or "mining-drill", position = args.position,
    pickup_target = pickup_target, drop_target = drop_target } end,
}
local body = { valid = true, position = { x = 0, y = 0 }, build_distance = 6, force = force, surface = surface,
  get_item_count = function() return 1 end, remove_item = function(args) removed = removed + args.count end }
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end }
_G.defines = { direction = { north = 0 }, build_check_type = { manual = 1 } }
_G.prototypes = { item = {
  ["burner-mining-drill"] = { place_result = { name = "burner-mining-drill", type = "mining-drill" } },
  ["burner-inserter"] = { place_result = { name = "burner-inserter", type = "inserter" } },
} }
local place = require("scripts.actions.build").place
local valid = { item = "burner-mining-drill", position = { x = 1, y = 0 }, output_target = { x = 2, y = 0 } }
place.start(valid)
local valid_result = place.tick(valid)
check(valid_result and valid_result.status == "done" and created == 1 and removed == 1, "placement verifies Factorio's exact valid output recipient")
created, removed, target_matches, recipient.valid = 0, 0, { recipient }, true
local invalidated = { item = "burner-mining-drill", position = { x = 1, y = 0 }, output_target = { x = 2, y = 0 } }
place.start(invalidated)
recipient.valid, target_matches = false, { replacement }
local invalidated_result = place.tick(invalidated)
check(invalidated_result and invalidated_result.status == "failed" and invalidated_result.detail:match("changed before placement") and created == 0 and removed == 0, "placement refuses an output recipient invalidated after search")
recipient.valid, target_matches, drop_target = true, { recipient }, nil
local mismatch = { item = "burner-mining-drill", position = { x = 1, y = 0 }, output_target = { x = 2, y = 0 } }
place.start(mismatch)
local mismatch_result = place.tick(mismatch)
check(mismatch_result and mismatch_result.status == "failed" and mismatch_result.detail:match("did not bind the expected output target") and created == 1 and removed == 1, "post-place recipient mismatch is explicit and requires physical recovery")
created, removed, pickup_target, drop_target = 0, 0, source, recipient
surface.find_entities_filtered = function(args)
  return { recipient }
end
local inserter = { item = "burner-inserter", position = { x = 1, y = 0 },
  output_target = { x = 2, y = 0 } }
place.start(inserter)
local inserter_result = place.tick(inserter)
check(inserter_result and inserter_result.status == "done" and created == 1 and removed == 1,
  "inserter placement prechecks and verifies its exact output binding")
local build_plan = require("scripts.actions.build_plan")
body.force.recipes, body.crafting_queue_size = {}, 0
created, removed, pickup_target = 0, 0, source
local planned = { steps = { { item = "burner-inserter", position = { x = 1, y = 0 },
  output_target = { x = 2, y = 0 } } } }
build_plan.start(planned)
local planned_result = build_plan.tick(planned)
check(planned_result and planned_result.status == "done" and created == 1 and removed == 1,
  "build_plan uses the same exact inserter output verification path")
os.exit(failures == 0 and 0 or 1)
