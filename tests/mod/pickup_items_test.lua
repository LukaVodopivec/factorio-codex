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

local invalid_count_ok = pcall(pickup.start, { target = { x = 4, y = 0 }, item = "iron-ore", count = 2 })
check(not invalid_count_ok, "pickup rejects a stale observed stack count before movement")

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

ground.valid = true
contents["iron-ore"] = 4
local wrong_selection = { target = { x = 4, y = 0 }, item = "iron-ore", count = 3 }
pickup.start(wrong_selection)
body.update_selected_entity = function() body.selected = neighbor end
local refused = pickup.tick(wrong_selection)
check(refused.status == "failed" and refused.detail:match("select the exact ground stack") and body.picking_state == false,
  "pickup refuses to enable picking when Factorio selects a neighboring stack")

os.exit(failures == 0 and 0 or 1)
