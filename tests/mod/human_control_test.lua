-- Human takeover: real input on the Codex client (LuaPlayer.afk_time under
-- 300 ticks while connected) parks the FIFO dispatcher without cancelling or
-- reordering anything, the mod stops writing body state, and the interrupted
-- step re-plans from wherever the body stands once the input goes idle.
-- Offline: the real dispatcher, walker and companion module over a mocked
-- LuaPlayer; afk_time semantics themselves are live-client evidence.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

_G.defines = {
  direction = { north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14 },
  controllers = { character = 1, spectator = 4, remote = 7 },
  events = setmetatable({}, { __index = function(_, key) return key end }),
}
_G.prototypes = { entity = { character = { collision_mask = { layers = { player = true } },
  collision_box = { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } } } } }
_G.rendering = { draw_text = function() return { valid = true, destroy = function() end } end }

-- The body counts every write the mod makes to its physical control state.
local path_requests = {}
local state = {
  valid = true, position = { x = 0, y = 0 }, force = {}, character_running_speed_modifier = 0,
  walking_state = {}, mining_state = {}, picking_state = false,
  crafting_queue = {}, crafting_queue_size = 0, cancel_crafting = function() end,
}
state.surface = {
  find_entities_filtered = function() return {} end,
  get_tile = function() return { collides_with = function() return false end } end,
  request_path = function(request)
    path_requests[#path_requests + 1] = { x = request.start.x, y = request.start.y }
    return #path_requests
  end,
}
local writes = {}
local body = setmetatable({}, {
  __index = state,
  __newindex = function(_, key, value) writes[key] = (writes[key] or 0) + 1; state[key] = value end,
})
local function body_writes()
  return (writes.walking_state or 0) + (writes.mining_state or 0) + (writes.picking_state or 0)
end

local player = { index = 1, valid = true, connected = true, name = "Codex", character = body,
  controller_type = defines.controllers.character, afk_time = 100000 }
local players = { player }
_G.game = { tick = 0, get_player = function(index) return players[index] end, connected_players = players }

local inert = { start = function() end, tick = function() return { status = "done", detail = "done" } end }
package.loaded["scripts.actions.craft"] = inert
package.loaded["scripts.actions.build"] = { place = inert, rotate = inert, set_recipe = inert }
package.loaded["scripts.actions.transfer"] = { insert = inert, extract = inert }
package.loaded["scripts.actions.build_plan"] = inert
package.loaded["scripts.inspect"] = { inspect = function() error("unexpected inspect") end }

local companion = require("scripts.companion")
local walk = require("scripts.actions.walk")
local tasks = require("scripts.tasks")

local function reset()
  path_requests, writes = {}, {}
  state.position, state.walking_state, state.mining_state, state.picking_state = { x = 0, y = 0 }, {}, {}, false
  player.connected, player.afk_time = true, 100000
  player.controller_type, player.character = defines.controllers.character, body
  game.tick = 0
  _G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil },
    companion = { player_index = 1, entity = body } }
end
local function tick()
  game.tick = game.tick + 1
  if player.afk_time then player.afk_time = player.afk_time + 1 end
  tasks.on_tick()
end
local function queue_walk(x)
  return tasks.queue_plan({ steps = { { action = "walk_to", x = x, y = 0 } } })
end
local function answer_path(x)
  walk.on_path_finished({ id = storage.path_request.id, path = { { position = { x = x, y = 0 } } } })
end

-- The single helper decides the hold from the Codex player's afk_time.
reset()
check(companion.get() == body, "fixture binds the native Codex player's character as the body")
local held, idle = companion.human_control()
check(held == false and idle == 100000, "a long-idle connected player does not hold the body")
player.afk_time = 299
held, idle = companion.human_control()
check(held == true and idle == 299, "input younger than 300 ticks holds the body")
player.afk_time = 300
check(companion.human_control() == false, "the hold releases at exactly 300 idle ticks")
player.afk_time, player.connected = 0, false
held, idle = companion.human_control()
check(held == false and idle == nil, "a disconnected player never holds, whatever its afk_time")
player.connected, player.afk_time = true, nil
check(companion.human_control() == false, "an unreadable afk_time never holds")
storage.companion = nil
check(companion.human_control() == false, "no bound Codex player never holds")

-- Input parks an active walk without cancelling it; queued plans keep order.
reset()
local first, second, third = queue_walk(10), queue_walk(20), queue_walk(30)
check(first.human_control == nil, "a plan queued without a hold carries no human_control flag")
tick()
answer_path(10)
tick()
check(state.walking_state.walking == true and storage.tasks.active.id == first.plan_id,
  "the first walk is active and the mod drives the body before any input")
state.position = { x = 2, y = 0 }

player.afk_time = 0
writes = {}
tick()
check(storage.tasks.human_hold ~= nil and state.walking_state.walking == false and writes.walking_state == 1
  and writes.mining_state == 1 and writes.picking_state == 1,
  "real input releases the body exactly once")
writes = {}
local requests_before = #path_requests
for step = 1, 200 do
  -- The owner walks the body himself; the game, not the mod, moves it.
  state.position = { x = 2, y = step / 20 }
  state.walking_state = { walking = true, direction = defines.direction.south }
  tick()
end
check(body_writes() == 0, "the mod writes no walking, mining or picking state during the hold")
check(#path_requests == requests_before, "no step starts or ticks during the hold")
local parked = tasks.plan_status({ plan_id = first.plan_id })
check(parked.status == "running" and parked.human_control == true and #parked.outcomes == 0
  and storage.tasks.active.id == first.plan_id,
  "the interrupted walk stays the active running plan, flagged human_control, not cancelled or failed")
check(#storage.tasks.queue == 2 and storage.tasks.queue[1].id == second.plan_id and storage.tasks.queue[2].id == third.plan_id,
  "queued plans keep their order during the hold")
local during = queue_walk(40)
check(during.plan_id and during.human_control == true and #storage.tasks.queue == 3
  and storage.tasks.queue[3].id == during.plan_id,
  "queue_plan during a hold is accepted, queued last and flagged human_control")
check(tasks.plan_status({ plan_id = second.plan_id }).human_control == true
  and tasks.plan_status({ plan_id = second.plan_id }).status == "queued",
  "a queued plan delayed by the hold reports human_control while still queued")

-- Fresh input restarts the idle clock: the hold continues.
player.afk_time = 0
for _ = 1, 299 do tick() end
check(storage.tasks.human_hold ~= nil and body_writes() == 0 and #path_requests == requests_before,
  "renewed input keeps the dispatcher parked until 300 idle ticks")

-- Idle for 300 ticks: the walk re-plans from where the owner left the body.
state.walking_state = {}
tick()
check(player.afk_time == 300 and storage.tasks.human_hold == nil, "300 idle ticks release the hold")
local replanned = path_requests[#path_requests]
check(#path_requests == requests_before + 1 and replanned.x == 2 and replanned.y == 10,
  "the interrupted walk requests a new path from the body's current position")
answer_path(10)
tick()
check(state.walking_state.walking == true, "the resumed walk drives the body again")
local order, seen = {}, {}
for _ = 1, 40 do
  local active = storage.tasks.active
  if active and storage.path_request then answer_path(active.steps[1].x) end
  if active and state.walking_state.walking then state.position = { x = active.steps[1].x, y = 0 } end
  tick()
  for _, id in ipairs({ first.plan_id, second.plan_id, third.plan_id, during.plan_id }) do
    local record = storage.tasks.records[id]
    if record and record.status == "completed" and not seen[id] then seen[id] = true; order[#order + 1] = id end
  end
end
check(#order == 4 and order[1] == first.plan_id and order[2] == second.plan_id and order[3] == third.plan_id
  and order[4] == during.plan_id, "after the hold every plan completes, in its original order")
local done = tasks.plan_status({ plan_id = first.plan_id })
check(done.status == "completed" and done.human_control == true and done.outcomes[1].status == "completed",
  "the delayed plan's result reports human_control and a completed walk")
local late = queue_walk(40)
check(late.human_control == nil and tasks.plan_status({ plan_id = late.plan_id }).human_control == nil,
  "a plan queued after the hold is not flagged")

-- A hold is not charged to the active plan's budget, and is not idle time.
reset()
local long = queue_walk(10)
tick()
answer_path(10)
tick()
player.afk_time = 0
tick()
game.tick = game.tick + 700 * 60
tasks.on_tick()
check(storage.tasks.active and storage.tasks.active.id == long.plan_id, "a long hold keeps the plan active")
player.afk_time = 300
tick()
check(tasks.plan_status({ plan_id = long.plan_id }).status == "running",
  "a hold longer than the plan budget does not fail the resumed plan")
answer_path(10)
state.position = { x = 10, y = 0 }
tick()
check(tasks.plan_status({ plan_id = long.plan_id }).status == "completed", "the plan completes after the long hold")
local finished = storage.tasks.last_finished_tick
player.afk_time = 0
for _ = 1, 50 do tick() end
check(storage.tasks.last_finished_tick == game.tick and finished < game.tick,
  "time the owner plays the body with an empty queue is not counted as body idle time")
check(queue_walk(10).body_idle_ticks == 0, "a plan queued during the hold reports no body idle time")

-- A disconnected player never holds: the dispatcher keeps running (and, with
-- no body, fails the work instead of parking it).
reset()
local running = queue_walk(10)
player.connected, player.afk_time = false, 0
tick()
check(storage.tasks.human_hold == nil and tasks.plan_status({ plan_id = running.plan_id }).status == "failed"
  and tasks.plan_status({ plan_id = running.plan_id }).human_control == nil,
  "a disconnected player's afk_time never parks the dispatcher")

-- Runners with body-bound progress restart it after a hold.
local mine_task = { _mining_started = true, _completed = 2 }
package.loaded["scripts.actions.approach"] = package.loaded["scripts.actions.approach"] or { ensure = function() end }
require("scripts.actions.mine").resume(mine_task)
check(mine_task._mining_started == false and mine_task._completed == 2,
  "an interrupted mining cycle starts over from a fresh approach and keeps completed cycles")
local pickup_task = { _picking_started = true, _belt = {}, _picked = 3 }
require("scripts.actions.pickup").resume(pickup_task)
check(pickup_task._picking_started == false and pickup_task._picked == 3, "an interrupted belt pickup approaches again with its own count")

-- Map or remote view never holds: input there moves the view, not the body,
-- so the bot keeps working. A missing character parks the FIFO however long
-- the input has been idle, and no plan is failed or cancelled.
reset()
local kept_first, kept_second = queue_walk(10), queue_walk(20)
local kept_third = tasks.queue_plan({ steps = { { action = "walk_to", x = 30, y = 0 } }, after_plan_id = kept_second.plan_id })
tick()
answer_path(10)
tick()
player.controller_type = defines.controllers.remote
player.afk_time = 0
tick()
held, idle = companion.human_control()
check(held == false and storage.tasks.human_hold == nil and companion.get() == body,
  "fresh input in map or remote view does not hold the body, which stays script-controllable")
player.controller_type, player.character = defines.controllers.character, nil
player.afk_time = 100000
tick()
check(tasks.plan_status({ plan_id = kept_first.plan_id }).status == "running"
  and tasks.plan_status({ plan_id = kept_second.plan_id }).status == "queued"
  and tasks.plan_status({ plan_id = kept_third.plan_id }).status == "queued",
  "no plan fails or is cancelled while the body is not controllable")
check(companion.human_control() == true and storage.tasks.human_hold ~= nil
  and tasks.plan_status({ plan_id = kept_first.plan_id }).status == "running",
  "a connected player without a character keeps the hold")
player.character = body
tick()
check(storage.tasks.human_hold == nil and tasks.plan_status({ plan_id = kept_first.plan_id }).status == "running",
  "the hold releases once the idle player is back in its character")
for _ = 1, 40 do
  local active = storage.tasks.active
  if active and storage.path_request then answer_path(active.steps[1].x) end
  if active and state.walking_state.walking then state.position = { x = active.steps[1].x, y = 0 } end
  tick()
end
check(tasks.plan_status({ plan_id = kept_first.plan_id }).status == "completed"
  and tasks.plan_status({ plan_id = kept_second.plan_id }).status == "completed"
  and tasks.plan_status({ plan_id = kept_third.plan_id }).status == "completed",
  "every plan held while the body was missing completes afterwards")

-- A parked wait is not charged for the hold, and its condition is read
-- before its deadline is applied.
do
  reset()
  local inspect = package.loaded["scripts.inspect"]
  local unexpected, plates = inspect.inspect, 0
  inspect.inspect = function() return { tick = game.tick, entities = { { inventories = { output = { ["iron-plate"] = plates } } } } } end
  local function wait(seconds)
    return tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate",
      count = 5, timeout_seconds = seconds } } })
  end
  local waiting = wait(60)
  for _ = 1, 100 do tick() end
  check(tasks.plan_status({ plan_id = waiting.plan_id }).status == "waiting", "fixture: the wait is parked before the hold")
  player.afk_time = 0
  tick()
  game.tick, plates = game.tick + 3600, 10
  tasks.on_tick()
  player.afk_time = 299
  tick()
  check(storage.tasks.human_hold == nil and tasks.plan_status({ plan_id = waiting.plan_id }).status ~= "failed",
    "a hold longer than a parked wait's timeout does not expire the wait on release")
  for _ = 1, 40 do tick() end
  local waited = tasks.plan_status({ plan_id = waiting.plan_id })
  check(waited.status == "completed" and waited.human_control == true
    and tostring(waited.outcomes[1].result):match("output has 10 iron%-plate"),
    "the wait whose items arrived during the hold completes after it")
  -- Hold ticks extend the deadline: a still-unmet wait keeps its remaining time.
  reset()
  plates = 0
  local extended = wait(60)
  for _ = 1, 100 do tick() end
  player.afk_time = 0
  tick()
  game.tick = game.tick + 3600
  tasks.on_tick()
  player.afk_time = 299
  for _ = 1, 100 do tick() end
  check(storage.tasks.human_hold == nil and tasks.plan_status({ plan_id = extended.plan_id }).status == "waiting",
    "an unmet parked wait keeps its remaining timeout after a hold longer than the timeout")
  plates = 5
  for _ = 1, 40 do tick() end
  check(tasks.plan_status({ plan_id = extended.plan_id }).status == "completed",
    "items arriving within the extended deadline complete the wait")
  -- At the deadline, with the body free, the condition is read once more.
  reset()
  plates = 0
  local late = wait(1)
  for _ = 1, 59 do tick() end
  plates = 5
  tick(); tick()
  check(tasks.plan_status({ plan_id = late.plan_id }).status == "completed",
    "a wait whose items are present at its deadline completes instead of timing out on stale evidence")
  reset()
  plates = 0
  local never = wait(1)
  for _ = 1, 62 do tick() end
  local expired = tasks.plan_status({ plan_id = never.plan_id })
  check(expired.status == "failed" and tostring(expired.outcomes[1].error):match("timed out waiting for 5 iron%-plate"),
    "an unmet wait still times out at its deadline")

  -- A queued inspect step reports the read's own scope once any entity is remote.
  reset()
  inspect.inspect = function() return { tick = game.tick, entities = { { name = "steel-chest", remote = true }, { name = "wooden-chest" } },
    evidence_class = "fresh_exact_local_and_charted_remote", scope = "within_30_tiles_or_own_force_charted_at_source_tick" } end
  local read = tasks.queue_plan({ steps = { { action = "inspect_entities", positions = { { x = 300, y = 300 }, { x = 1, y = 1 } } } } })
  tick()
  local seen_remote = tasks.plan_status({ plan_id = read.plan_id }).outcomes[1].result
  check(seen_remote.scope == "within_30_tiles_or_own_force_charted_at_source_tick"
    and seen_remote.evidence_class == "fresh_exact_local_and_charted_remote",
    "an inspect step with a remote entity passes the read's own scope and evidence class through")
  inspect.inspect = function() return { tick = game.tick, entities = { { name = "wooden-chest" } },
    evidence_class = "fresh_local_exact", scope = "within_30_tiles_of_codex_at_source_tick" } end
  local near = tasks.queue_plan({ steps = { { action = "inspect_entities", positions = { { x = 1, y = 1 } } } } })
  tick()
  local seen_local = tasks.plan_status({ plan_id = near.plan_id }).outcomes[1].result
  check(seen_local.scope:match("^within_30_tiles") and not seen_local.scope:match("charted")
    and seen_local.evidence_class == "fresh_local_exact", "a local inspect step keeps a within-30-tiles scope")
  inspect.inspect = unexpected
end

-- A ground pickup takes its inventory baseline when picking starts, so what
-- The owner did to that item's count during a hold never fails the resumed step.
do
  reset()
  local pickup, approach = require("scripts.actions.pickup"), require("scripts.actions.approach")
  local real_ensure, real_find = approach.ensure, state.surface.find_entities_filtered
  local coal, reached = 4, nil
  local stack = { valid = true, type = "item-entity", position = { x = 1, y = 0 }, stack = { valid_for_read = true, name = "coal", count = 5 } }
  state.get_main_inventory = function() return { get_item_count = function() return coal end, can_insert = function() return true end } end
  state.surface.find_entities_filtered = function(filter) return filter.type == "item-entity" and { stack } or {} end
  state.item_pickup_distance, state.update_selected_entity = 1, function() state.selected = stack end
  approach.ensure = function() return reached end
  local ground = { target = { x = 1, y = 0 }, item = "coal", count = 5 }
  pickup.start(ground)
  check(pickup.tick(ground) == nil and state.picking_state == false, "fixture: the ground pickup is still approaching")
  coal = 2 -- the owner burns coal during the hold
  pickup.resume(ground)
  reached = "ok"
  check(pickup.tick(ground) == nil and state.picking_state == true, "the resumed ground pickup starts picking")
  coal, stack.valid = 7, false
  local picked = pickup.tick(ground)
  check(picked and picked.status == "done" and picked.detail:match("picked up 5 coal"),
    "a ground pickup completes although the item count changed during the hold")
  -- The stack was taken on the tick the hold began: the pickup is finished, not invalidated.
  stack = { valid = true, type = "item-entity", position = { x = 1, y = 0 }, stack = { valid_for_read = true, name = "coal", count = 5 } }
  coal = 7
  ground = { target = { x = 1, y = 0 }, item = "coal", count = 5 }
  pickup.start(ground)
  pickup.tick(ground)
  coal, stack.valid = 12, false
  pickup.resume(ground)
  picked = pickup.tick(ground)
  check(picked and picked.status == "done", "a stack already taken with exactly its count gained finishes after the hold")
  -- A vanished stack without the matching gain is still refused.
  stack = { valid = true, type = "item-entity", position = { x = 1, y = 0 }, stack = { valid_for_read = true, name = "coal", count = 5 } }
  ground = { target = { x = 1, y = 0 }, item = "coal", count = 5 }
  pickup.start(ground)
  pickup.tick(ground)
  coal, stack.valid = 14, false
  pickup.resume(ground)
  picked = pickup.tick(ground)
  check(picked and picked.status == "failed" and picked.detail:match("invalidated before pickup"),
    "a stack that vanished without exactly its count gained is refused, not credited")
  approach.ensure, state.surface.find_entities_filtered = real_ensure, real_find
end

-- Craft completion is the products gained, not an empty queue: a queue the owner
-- cancelled during a hold is not reported as completed crafts.
do
  reset()
  local craft = dofile(here .. "/../../mod/agentic-companion/scripts/actions/craft.lua")
  local counts = { ["iron-plate"] = 20 }
  state.force.recipes = { ["iron-gear-wheel"] = { enabled = true,
    ingredients = { { type = "item", name = "iron-plate", amount = 2 } },
    products = { { type = "item", name = "iron-gear-wheel", amount = 1 } } } }
  state.get_item_count = function(name) return counts[name] or 0 end
  state.begin_crafting = function(request) state.crafting_queue_size = request.count; return request.count end
  local function crafted(gears)
    counts["iron-gear-wheel"] = 0
    local crafting = { recipe = "iron-gear-wheel", count = 10 }
    craft.start(crafting)
    game.tick = game.tick + 31
    check(craft.tick(crafting) == nil, "fixture: the craft waits while its queue is busy")
    state.crafting_queue_size, counts["iron-gear-wheel"] = 0, gears
    game.tick = game.tick + 31
    return craft.tick(crafting)
  end
  local cancelled = crafted(0)
  check(cancelled.status == "failed" and cancelled.detail:match("0 of 10 recipe crafts") and not cancelled.detail:match("^completed"),
    "an emptied queue with no product gained fails instead of reporting completed crafts")
  local some = crafted(4)
  check(some.status == "partial" and some.detail:match("4 of 10 recipe crafts") and some.outcome.crafts_evidenced == 4,
    "an emptied queue with part of the products reports the evidenced crafts as partial")
  local all = crafted(10)
  check(all.status == "done" and all.detail:match("^completed 10 recipe crafts of iron%-gear%-wheel %(%+10 iron%-gear%-wheel%)"),
    "a queue that produced every product still completes")
end

-- Every read RPC's fifo block reports the hold from the same helper.
do
  reset()
  local responded
  _G.script = { active_mods = { ["agentic-companion"] = "test", base = "2.0.77" },
    on_init = function() end, on_configuration_changed = function() end,
    on_event = function() end, on_nth_tick = function() end }
  local registered
  _G.remote = { add_interface = function(_, value) registered = value end }
  local params = {}
  _G.helpers = { table_to_json = function(value) responded = value; return "{}" end, json_to_table = function() return params end }
  _G.rcon = { print = function() end }
  storage.rpc_outbox = { next_id = 1, by_id = {} }
  local function reader() return function() return {} end end
  package.loaded["scripts.state"] = { init = function() end }
  package.loaded["scripts.inspect"] = { inspect = reader() }
  package.loaded["scripts.research"] = { start_research = reader(), progression_status = reader() }
  package.loaded["scripts.spatial"] = { observe_local = reader(), can_place = reader(), describe_prototype = reader() }
  package.loaded["scripts.find_placement"] = { find_placement = reader() }
  package.loaded["scripts.map_summary"] = { map_summary = reader() }
  package.loaded["scripts.production_requirements"] = { production_requirements = reader() }
  package.loaded["scripts.connect_entities"] = { connect_entities = reader() }
  package.loaded["scripts.run_snapshot"] = { capture = reader() }
  assert(loadfile(here .. "/../../mod/agentic-companion/control.lua"))()
  local function fifo(method)
    responded = nil
    registered.rpc(method, "{}")
    return responded and responded.ok and responded.data and responded.data.fifo
  end
  player.afk_time = 42
  -- get_task is the direct tools' poll: it carries the same block.
  storage.tasks.records[5] = { status = "done", detail = "" }
  params = { task_id = 5 }
  local task_fifo = fifo("get_task")
  params = {}
  check(responded.data.status == "done" and task_fifo and task_fifo.human_control == true and task_fifo.human_idle_ticks == 42,
    "get_task carries the fifo block with human_control and human_idle_ticks for direct tools")
  local held_fifo = fifo("observe_local")
  check(held_fifo and held_fifo.human_control == true and held_fifo.human_idle_ticks == 42,
    "a read RPC's fifo block reports human_control and human_idle_ticks during a hold")
  player.afk_time = 900
  local free_fifo = fifo("map_summary")
  check(free_fifo and free_fifo.human_control == false and free_fifo.human_idle_ticks == 900,
    "a read RPC's fifo block reports human_control false once input is idle")
  player.connected = false
  local away_fifo = fifo("ping")
  check(away_fifo and away_fifo.human_control == false and away_fifo.human_idle_ticks == nil,
    "a disconnected player reports human_control false with no idle ticks")
end

os.exit(failures == 0 and 0 or 1)
