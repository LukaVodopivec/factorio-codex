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
_G.prototypes = { entity = { character = { collision_mask = { layers = { player = true } }, collision_box = { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } } } } }

local next_path_id = 0
local body = {
  valid = true,
  position = { x = 0, y = 0 },
  force = {},
  walking_state = {},
  mining_state = {},
  crafting_queue = {},
  crafting_queue_size = 0,
  surface = { find_entities_filtered = function() return {} end,
    get_tile = function() return { collides_with = function() return false end } end, request_path = function()
    next_path_id = next_path_id + 1
    return next_path_id
  end },
}
body.cancel_crafting = function() end

package.loaded["scripts.companion"] = {
  get = function() return body end,
  require_companion = function() return body end,
  -- Any body state but absent (remote actions, reads, queue_plan); no surface tag.
  require_present = function() return { state = "on_surface", force = body.force, surface = body.surface } end,
  anchor = function() return nil end,
}
local inert = { start = function() end, tick = function() return { status = "done", detail = "done" } end }
package.loaded["scripts.actions.mine"] = inert
package.loaded["scripts.actions.craft"] = inert
package.loaded["scripts.actions.build"] = { place = inert, rotate = inert,
  set_recipe_action = { runner = inert, make_task = function() return {} end } }
package.loaded["scripts.actions.transfer"] = { insert = inert, extract = inert,
  flush_action = { runner = inert, make_task = function() return {} end } }
package.loaded["scripts.actions.build_plan"] = inert
package.loaded["scripts.inspect"] = { MAX_TARGETS = 64, inspect = function() error("unexpected inspect") end }

local walk = require("scripts.actions.walk")
local tasks = require("scripts.tasks")

local function reset()
  next_path_id = 0
  body.position = { x = 0, y = 0 }
  body.walking_state = {}
  body.mining_state = {}
  _G.game = { tick = 0 }
  _G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil }, path_request = nil }
  tasks.set_observer(function(params)
    return {
      tick = game.tick,
      detail = params.detail,
      character = { position = { x = body.position.x, y = body.position.y }, inventory = {} },
      entities = {},
      resource_patches = {},
    }
  end)
end

local function queue_walk()
  return tasks.queue_plan({
    steps = { { action = "walk_to", x = 10, y = 0 } },
    observation_detail = "compact",
  }).plan_id
end

reset()
local plan_id = queue_walk()
game.tick = 1
tasks.on_tick()
check(storage.path_request and storage.path_request.task_id == plan_id,
  "nested plan walk registers its native path request against the owning plan")
walk.on_path_finished({ id = storage.path_request.id, path = { { position = { x = 10, y = 0 } } } })
game.tick = 2
tasks.on_tick()
check(body.walking_state.walking == true,
  "Factorio path-completion event reaches the nested plan walk runner")
body.position = { x = 10, y = 0 }
game.tick = 3
tasks.on_tick()
local completed = tasks.plan_status({ plan_id = plan_id })
check(completed.status == "completed" and completed.outcomes[1].action == "walk_to",
  "nested native walk completes its queued plan")
check(completed.observation and completed.observation.tick == 3
  and completed.observation.character.position.x == 10,
  "completed plan exposes the terminal observation consumed by run_plan")

reset()
plan_id = queue_walk()
game.tick = 1
tasks.on_tick()
game.tick = 602
tasks.on_tick()
local timed_out = tasks.plan_status({ plan_id = plan_id })
check(timed_out.status == "failed" and timed_out.outcomes[1].error:match("^PATH_TIMEOUT:"),
  "nested walk retains deterministic missing-event timeout coverage")
check(timed_out.observation and timed_out.observation.tick == 602,
  "timed-out plan still exposes its terminal observation")

reset()
plan_id = queue_walk()
game.tick = 1
tasks.on_tick()
local stale_request = storage.path_request.id
local cancelled = tasks.cancel({ origin = "stop/supervisor", plan_id = plan_id })
local cancelled_status = tasks.plan_status({ plan_id = plan_id })
check(cancelled.cancelled == 1 and cancelled_status.status == "cancelled"
  and cancelled_status.outcomes[1].status == "cancelled" and body.walking_state.walking == false,
  "cancelling a nested walk stops the sole body and records the interrupted step")
walk.on_path_finished({ id = stale_request, path = { { position = { x = 10, y = 0 } } } })
check(storage.tasks.active == nil and body.walking_state.walking == false,
  "late native path event cannot revive a cancelled plan")

-- The additive cap reason survives the plan's public failure outcome.
reset()
body.force.is_chunk_charted = function() return true end
body.surface.find_non_colliding_position = function(_, requested) return requested end
local requested = {}
body.surface.request_path = function(options)
  next_path_id = next_path_id + 1
  requested[next_path_id] = options.goal
  return next_path_id
end
plan_id = queue_walk()
game.tick = 1; tasks.on_tick()
storage.tasks.active.current_task._walk.frontier_segments = 3
walk.on_path_finished({ id = storage.path_request.id })
game.tick = 2; tasks.on_tick()
for _ = 1, 8 do
  local id = storage.path_request.id
  walk.on_path_finished({ id = id, path = { { position = requested[id] } } })
  game.tick = game.tick + 1; tasks.on_tick()
end
local capped = tasks.plan_status({ plan_id = plan_id })
local cap_result = capped.outcomes[1].result
check(capped.status == "failed" and capped.completed_steps == 0
  and cap_result.code == "PATH_NOT_FOUND"
  and cap_result.diagnostics.path.recovery.termination_reason == "segment_limit_with_progress"
  and capped.outcomes[1].error:match("reachability is unproven")
  and next_path_id == 9 and body.walking_state.walking == false,
  "plan failure exposes the cap reason without another segment or successful step")

os.exit(failures == 0 and 0 or 1)
