local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.game = { tick = 1 }
local contents = { ["iron-ore"] = 4 }
local inventory = {
  get_item_count = function(name) return contents[name] or 0 end,
  can_insert = function(stack) return stack.name == "iron-ore" and stack.count <= 3 end,
}
local ground = {
  valid = true, type = "item-entity", name = "item-on-ground", position = { x = 4, y = 0 },
  stack = { valid_for_read = true, name = "iron-ore", count = 3 },
}
local neighbor = {
  valid = true, type = "item-entity", name = "item-on-ground", position = { x = 4.5, y = 0 },
  stack = { valid_for_read = true, name = "copper-ore", count = 2 },
}
local candidates = { neighbor, ground }
local surface = {
  find_entities_filtered = function(filter)
    -- A miss lists the stacks lying within a tile, in a bounded area query.
    if filter.area then
      check(filter.type == "item-entity" and filter.limit and filter.area.right_bottom.x - filter.area.left_top.x == 2,
        "a miss reads only the item stacks within a tile, bounded")
      local out = {}
      for _, e in ipairs(candidates) do
        if e.valid and e.position.x >= filter.area.left_top.x and e.position.x <= filter.area.right_bottom.x
          and e.position.y >= filter.area.left_top.y and e.position.y <= filter.area.right_bottom.y then out[#out + 1] = e end
      end
      return out
    end
    check(filter.type == "item-entity" and filter.position.x == 4 and filter.position.y == 0 and filter.radius == 0.01,
      "pickup resolves only an item-on-ground at the exact observed position")
    return candidates
  end,
}
local body = {
  valid = true, position = { x = 0, y = 0 }, surface = surface,
  item_pickup_distance = 1, picking_state = false, walking_state = {},
  selected = nil,
  get_main_inventory = function() return inventory end,
}
body.update_selected_entity = function(position)
  body.selected = nil
  for _, entity in ipairs(candidates) do
    if entity.valid and entity.position.x == position.x and entity.position.y == position.y then
      body.selected = entity
      return
    end
  end
end
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
local approach_result, captured_reach
package.loaded["scripts.actions.approach"] = {
  ensure = function(_, _, _, reach) captured_reach = reach return approach_result end,
}

local pickup = require("scripts.actions.pickup")

local invalid_count_ok, invalid_count_error = pcall(pickup.start, { target = { x = 4, y = 0 }, item = "iron-ore", count = 2 })
check(not invalid_count_ok, "pickup rejects a stale observed stack count before movement")
check(tostring(invalid_count_error):match("^GROUND_STACK_CHANGED: ") and tostring(invalid_count_error):find(
  "item stacks within 1 tile: item-on-ground copper-ore x2 at (4.5, 0), item-on-ground iron-ore x3 at (4, 0)", 1, true),
  "a miss is coded and lists every stack lying within a tile, exactly")
local errors = require("scripts.errors")
check(errors.code("failed", nil, errors.plain(invalid_count_error)) == "GROUND_STACK_CHANGED",
  "the miss classifies as GROUND_STACK_CHANGED")
local saved_candidates = candidates
-- The exact-position mock returns every candidate; the one stack lies 5 tiles off.
candidates = { { valid = true, type = "item-entity", name = "item-on-ground", position = { x = 9, y = 0 },
  stack = { valid_for_read = true, name = "iron-ore", count = 5 } } }
local none_ok, none_error = pcall(pickup.start, { target = { x = 4, y = 0 }, item = "iron-ore", count = 3 })
check(not none_ok and tostring(none_error):find("no item stack lies within 1 tile", 1, true),
  "a miss with nothing lying near says so")
candidates = saved_candidates

local task = { target = { x = 4, y = 0 }, item = "iron-ore", count = 3 }
pickup.start(task)
approach_result = nil
check(pickup.tick(task) == nil and body.picking_state == false and captured_reach == 0.75,
  "pickup waits for physical approach inside LuaControl item_pickup_distance")
approach_result = "ok"
check(pickup.tick(task) == nil and body.picking_state == true,
  "pickup enables only LuaControl picking_state after physical approach")
check(body.selected == ground, "pickup authoritatively selects the exact stack instead of its neighbor")

body.selected = neighbor
check(pickup.tick(task) == nil and body.selected == ground and body.picking_state == true,
  "in-flight pickup reselects only the already-resolved exact stack")

contents["iron-ore"] = 7
ground.valid = false
game.tick = 2
local completed = pickup.tick(task)
check(completed.status == "done" and completed.detail:match("picked up 3 iron%-ore") and body.picking_state == false,
  "pickup succeeds only from matching actual inventory delta and target depletion")

ground = {
  valid = true, type = "item-entity", name = "item-on-ground", position = { x = 4, y = 0 },
  stack = { valid_for_read = true, name = "iron-ore", count = 3 },
}
candidates = { neighbor, ground }
contents["iron-ore"] = 4
inventory.can_insert = function() return false end
local full = { target = { x = 4, y = 0 }, item = "iron-ore", count = 3 }
pickup.start(full)
local full_result = pickup.tick(full)
check(full_result.status == "failed" and full_result.detail:match("inventory") and body.picking_state == false,
  "pickup fails closed before picking when inventory cannot hold the exact stack")

inventory.can_insert = function() return true end
local lost = { target = { x = 4, y = 0 }, item = "iron-ore", count = 3 }
pickup.start(lost)
approach_result = "ok"
pickup.tick(lost)
ground.valid = false
local lost_result = pickup.tick(lost)
check(lost_result.status == "failed" and lost_result.detail:match("disappeared") and body.picking_state == false,
  "pickup fails closed when the selected target disappears without matching inventory gain")
check(lost_result.outcome.code == "PICKUP_COUNT_MISMATCH" and lost_result.outcome.gained == 0
  and lost_result.outcome.expected == 3, "a short gain is coded PICKUP_COUNT_MISMATCH with the measured gain")

-- Picking takes every stack within reach: a gain above the request, once the
-- selected stack is gone, is done and reports the surplus as measured.
local function fresh_ground()
  ground = { valid = true, type = "item-entity", name = "item-on-ground", position = { x = 4, y = 0 },
    stack = { valid_for_read = true, name = "iron-ore", count = 3 } }
  candidates = { neighbor, ground }
end
fresh_ground()
contents["iron-ore"] = 4
local greedy = { target = { x = 4, y = 0 }, item = "iron-ore", count = 3 }
pickup.start(greedy)
pickup.tick(greedy)
contents["iron-ore"] = 9
ground.valid = false
local greedy_result = pickup.tick(greedy)
check(greedy_result.status == "done" and greedy_result.outcome.surplus == 2 and greedy_result.outcome.picked_up == 5
  and greedy_result.detail:match("2 more than the 3 requested") and body.picking_state == false,
  "a gain above the request finishes done and names the surplus")
fresh_ground()
contents["iron-ore"] = 4
local shrunk = { target = { x = 4, y = 0 }, item = "iron-ore", count = 3 }
pickup.start(shrunk)
pickup.tick(shrunk)
ground.stack.count = 2
local shrunk_result = pickup.tick(shrunk)
check(shrunk_result.status == "failed" and shrunk_result.outcome.code == "GROUND_STACK_CHANGED",
  "a selected stack that shrinks without the inventory gaining is coded GROUND_STACK_CHANGED")
fresh_ground()
contents["iron-ore"] = 4

ground.valid = true
contents["iron-ore"] = 4
local wrong_selection = { target = { x = 4, y = 0 }, item = "iron-ore", count = 3 }
pickup.start(wrong_selection)
body.update_selected_entity = function() body.selected = neighbor end
local refused = pickup.tick(wrong_selection)
check(refused.status == "failed" and refused.detail:match("select the exact ground stack") and body.picking_state == false,
  "pickup refuses to enable picking when Factorio selects a neighboring stack")

os.exit(failures == 0 and 0 or 1)
