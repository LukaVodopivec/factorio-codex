local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.defines = {
  build_check_type = { manual = 1 },
  direction = { north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14 },
}
_G.game = { tick = 0 }
_G.prototypes = { item = { ["stone-furnace"] = { place_result = { name = "stone-furnace" } } }, entity = {
  character = { collision_mask = {} },
} }

local inventory = { ["stone-furnace"] = 0, ["iron-plate"] = 2, ["iron-gear-wheel"] = 0 }
local blocker = { valid = true, name = "rock-huge", type = "simple-entity", position = { x = 4, y = 0 } }
local path_id = 0
local surface = {
  can_place_entity = function() return false end,
  find_entities_filtered = function() return { blocker } end,
  request_path = function() path_id = path_id + 1 return path_id end,
}
local body = {
  valid = true,
  position = { x = 0, y = 0 },
  force = { recipes = {} },
  surface = surface,
  build_distance = 6,
  reach_distance = 10,
  walking_state = {},
  get_item_count = function(name) return inventory[name] or 0 end,
  remove_item = function(args) inventory[args.name] = inventory[args.name] - args.count end,
}
package.loaded["scripts.companion"] = {
  require_companion = function() return body end,
  get = function() return body end,
}

local approach_result, captured_reach
local target_entity = { name = "transport-belt", direction = 0 }
local approach = {
  ensure = function(_, _, _, reach) captured_reach = reach return approach_result end,
  find_entity_near = function() return target_entity end,
  ensure_entity = function() return "ok" end,
}
package.loaded["scripts.actions.approach"] = approach

local build = require("scripts.actions.build")
local no_item, no_item_error = pcall(build.place.start, {
  item = "stone-furnace", position = { x = 4, y = 0 },
})
check(not no_item and tostring(no_item_error):match("inventory") ~= nil,
  "placement refuses to create a building without the carried item")

inventory["stone-furnace"] = 1
local place = { item = "stone-furnace", position = { x = 4, y = 0 } }
build.place.start(place)
approach_result = nil
check(build.place.tick(place) == nil and captured_reach == body.build_distance,
  "placement waits for physical build reach instead of acting remotely")
approach_result = "ok"
local blocked = build.place.tick(place)
check(blocked.status == "failed" and blocked.detail:match("rock%-huge is in the way") ~= nil
  and inventory["stone-furnace"] == 1,
  "blocked placement fails without consuming inventory or creating an entity")

local explicit = { target = { x = 1, y = 0 }, direction = 12 }
build.rotate.start(explicit)
local explicit_result = build.rotate.tick(explicit)
check(explicit_result.status == "done" and target_entity.direction == 12 and captured_reach == body.reach_distance,
  "rotate sets the requested direction only after physical reach")
target_entity.direction = 0
target_entity.rotate = function() target_entity.direction = 4 return true end
local once = { target = { x = 1, y = 0 }, reverse = true }
build.rotate.start(once)
local once_result = build.rotate.tick(once)
check(once_result.status == "done" and target_entity.direction == 4,
  "rotate without direction performs one normal Factorio rotation and has no reverse behavior")

local recipe = {
  enabled = true,
  ingredients = { { type = "item", name = "iron-plate", amount = 2 } },
  products = { { type = "item", name = "iron-gear-wheel" } },
}
body.force.recipes["iron-gear-wheel"] = recipe
target_entity = {
  valid = true, name = "assembling-machine-1", type = "assembling-machine",
  set_recipe = function() return {} end,
  get_recipe = function() return nil end,
}
local incompatible_recipe = { target = { x = 1, y = 0 }, recipe = "iron-gear-wheel" }
build.set_recipe.start(incompatible_recipe)
local incompatible_result = build.set_recipe.tick(incompatible_recipe)
check(incompatible_result.status == "failed" and incompatible_result.detail:match("probably can't craft it") ~= nil,
  "set_recipe rejects a non-throwing incompatible machine")

body.crafting_queue_size = 0
body.begin_crafting = function()
  inventory["iron-plate"] = 0
  body.crafting_queue_size = 1
  return 1
end
local craft = require("scripts.actions.craft")
local craft_task = { recipe = "iron-gear-wheel", count = 1 }
craft.start(craft_task)
game.tick = 29
check(craft.tick(craft_task) == nil, "crafting cannot complete before elapsed polling ticks")
game.tick = 30
check(craft.tick(craft_task) == nil, "crafting remains active while Factorio's crafting queue is non-empty")
body.crafting_queue_size = 0
inventory["iron-gear-wheel"] = 1
game.tick = 60
local crafted = craft.tick(craft_task)
check(crafted.status == "done" and crafted.detail:match("%+1 iron%-gear%-wheel") ~= nil,
  "crafting completes only after Factorio advances and produces inventory")

package.loaded["scripts.actions.walk"] = nil
local walk = require("scripts.actions.walk")
local walk_task = { id = 7, target = { x = 20, y = 0 } }
_G.storage = { tasks = { active = walk_task }, path_request = nil }
game.tick = 0
walk.start(walk_task)
check(walk.tick(walk_task) == nil and storage.path_request.task_id == 7 and body.walking_state.walking == false,
  "walking waits for the sole pathfinder response")
walk.on_path_finished({ id = storage.path_request.id })
game.tick = 1
check(walk.tick(walk_task) == nil and body.walking_state.walking == true,
  "a no-path result falls back to physical straight-line walking")
game.tick = 61
check(walk.tick(walk_task) == nil and storage.path_request.task_id == 7,
  "a stationary body retries pathfinding once before failing")
walk.on_path_finished({ id = storage.path_request.id })
game.tick = 62
check(walk.tick(walk_task) == nil, "the retry still requires elapsed movement ticks")
game.tick = 122
local stuck = walk.tick(walk_task)
check(stuck.status == "failed" and stuck.detail:match("got stuck") ~= nil,
  "persistent blocked movement ends as an observable physical path failure")

os.exit(failures == 0 and 0 or 1)
