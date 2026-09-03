local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

_G.defines = {
  direction = { north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14 },
}
_G.prototypes = { entity = { character = { collision_mask = {} } } }

local next_path_id, blocker_filter, chart_all = 0, nil, true
local entity_queries, tile_queries = 0, 0
local body = {
  valid = true,
  position = { x = 0, y = 0 },
  force = { is_chunk_charted = function(_, chunk) return chart_all or chunk.x == 0 end },
  walking_state = {},
  surface = { request_path = function()
    next_path_id = next_path_id + 1
    return next_path_id
  end,
  get_tile = function(x, y) tile_queries = tile_queries + 1; return { position = { x = math.floor(x), y = math.floor(y) },
    name = x >= 0.5 and "water" or "grass", collides_with = function(layer) return layer == "player" and x >= 0.5 end } end,
  find_entities_filtered = function(filter) entity_queries = entity_queries + 1; blocker_filter = filter; return { { valid = true, name = "stone-furnace", type = "furnace",
    position = { x = 1, y = 0 } } } end },
}
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
local walk = require("scripts.actions.walk")
local approach = require("scripts.actions.approach")

local function reset(target)
  next_path_id = 0
  body.position = { x = 0, y = 0 }
  body.walking_state = {}
  _G.game = { tick = 0 }
  local task = { id = 7, target = target or { x = 10, y = 0 } }
  _G.storage = { tasks = { active = task }, path_request = nil }
  task._walk = {}
  walk.begin(task._walk, body, task.target, 0.5)
  return task
end

local function deliver(path, transient)
  local id = storage.path_request.id
  local event_path
  if path then
    event_path = {}
    for i, p in ipairs(path) do event_path[i] = { position = p } end
  end
  walk.on_path_finished({ id = id, path = event_path, try_again_later = transient })
end

local task = reset()
check(walk.step(task._walk, body, task.id) == nil and body.walking_state.walking == false,
  "native walker waits for Factorio's path result")
deliver({ { x = 5, y = 0 }, { x = 10, y = 0 } })
check(walk.step(task._walk, body, task.id) == nil and body.walking_state.walking == true,
  "successful native path drives ordinary walking_state")
body.position = { x = 10, y = 0 }
check(walk.step(task._walk, body, task.id) == "arrived" and body.walking_state.walking == false,
  "native path success finishes at physical position")

task = reset()
walk.step(task._walk, body, task.id); deliver(nil, false)
local result = walk.step(task._walk, body, task.id)
check(result and result.failed:match("^PATH_NOT_FOUND:"),
  "no-path result fails deterministically without blind walking")
check(result.failed:match("collision segment") and result.failed:match("stone%-furnace") and result.failed:match("water"),
  "no-path result includes bounded local collision-segment evidence")
check(blocker_filter.collision_mask == prototypes.entity.character.collision_mask,
  "blocker evidence uses the same character collision mask as native pathfinding")

chart_all = false
task = reset({ x = 40, y = 0 })
body.position = { x = 31.8, y = 0 }
entity_queries, tile_queries = 0, 0
walk.step(task._walk, body, task.id); deliver(nil, false)
local boundary_result = walk.step(task._walk, body, task.id)
check(boundary_result.failed:match("crosses uncharted terrain") and entity_queries == 0 and tile_queries == 0,
  "collision evidence makes zero entity or tile queries when its bounded area crosses an uncharted chunk")
chart_all = true

task = reset()
local transient_result
for attempt = 1, 4 do
  walk.step(task._walk, body, task.id)
  deliver(nil, true)
  transient_result = walk.step(task._walk, body, task.id)
  if attempt < 4 then
    game.tick = game.tick + 30
    walk.step(task._walk, body, task.id)
  end
end
check(transient_result and transient_result.failed:match("^PATH_TRANSIENT:")
  and transient_result.failed:match("4 native path attempts"),
  "transient pathfinder replies retry finitely with deterministic diagnostics")

task = reset()
walk.step(task._walk, body, task.id)
game.tick = 91
result = walk.step(task._walk, body, task.id)
check(result and result.failed == "PATH_TIMEOUT: no native path result arrived within 90 ticks",
  "missing native result times out deterministically")

task = reset()
walk.step(task._walk, body, task.id); deliver({ { x = 10, y = 0 } })
walk.step(task._walk, body, task.id)
game.tick = 60
check(walk.step(task._walk, body, task.id) == nil and storage.path_request.id == 2,
  "stalled walking requests one fresh native recovery path")
deliver({ { x = 10, y = 0 } })
walk.step(task._walk, body, task.id)
game.tick = 120
result = walk.step(task._walk, body, task.id)
check(result and result.failed:match("^PATH_STALLED:"),
  "repeated physical stall ends with a deterministic diagnostic")
check(result.failed:match("collision segment") and result.failed:match("stone%-furnace"),
  "stalled path includes the same bounded local blocker evidence")

task = reset()
walk.step(task._walk, body, task.id); deliver({ { x = 0, y = 0 } })
check(walk.step(task._walk, body, task.id) == nil and storage.path_request.id == 2,
  "incomplete native path requests one recovery path")
deliver({ { x = 0, y = 0 } })
result = walk.step(task._walk, body, task.id)
check(result and result.failed:match("^PATH_INCOMPLETE:"),
  "repeated incomplete path fails instead of walking blind")

task = reset({ x = 10, y = 0 })
result = approach.ensure(task, body, task.target, 2)
check(result == nil and storage.path_request.task_id == task.id,
  "embedded approach uses the same native path request")
deliver(nil, false)
result = approach.ensure(task, body, task.target, 2)
check(result and result.status == "failed"
  and result.detail:match("couldn't get in range: PATH_NOT_FOUND:"),
  "embedded approach preserves deterministic native path failure")

os.exit(failures == 0 and 0 or 1)
