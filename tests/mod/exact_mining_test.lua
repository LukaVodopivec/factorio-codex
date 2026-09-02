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
local inventory_count = 0
local inventory_has_room = true
local inventory = {
  get_item_count = function() return inventory_count end,
  can_insert = function(stack)
    check(stack.name == "iron-ore" and stack.count == 1,
      "mining checks capacity for the exact target's real product")
    return inventory_has_room
  end,
}
local body = {
  valid = true, position = { x = 0, y = 0 }, resource_reach_distance = 3,
  mining_state = { mining = false },
  get_main_inventory = function() return inventory end,
  surface = { find_entities_filtered = function(filter)
    check(filter.area ~= nil and filter.radius == nil, "mining queries an exact area without a nearby radius")
    return { adjacent, exact }
  end },
}
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end }
_G.game = { tick = 100 }
local mine = require("scripts.actions.mine")
inventory_has_room = false
local full_task = { target = { x = 0, y = 0 } }; mine.start(full_task)
local full = mine.tick(full_task)
check(full and full.status == "failed" and full.detail:match("inventory is full") ~= nil,
  "mining fails honestly before starting when Codex inventory cannot accept the product")
check(body.mining_state.mining == false and exact.amount == 100 and scripted_mine_calls == 0,
  "full-inventory mining neither starts physical mining nor calls scripted mine")

inventory_has_room = true
local task = { target = { x = 0, y = 0 } }; mine.start(task)
check(task._entity_name == "iron-ore", "mining selects only the entity occupying the exact coordinate")
local first_tick = mine.tick(task)
check(first_tick == nil and body.mining_state.mining == true
  and body.mining_state.position.x == exact.position.x,
  "LuaControl mining_state starts on the exact target")
game.tick = game.tick + 1
local second_tick = mine.tick(task)
check(second_tick == nil and game.tick == 101 and exact.amount == 100 and inventory_count == 0,
  "mining remains active while real game time passes")
game.tick = game.tick + 1
exact.amount = 99
inventory_count = 2
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
