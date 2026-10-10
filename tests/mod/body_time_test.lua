-- Body time (run telemetry): the dispatcher accounts every tick to one body
-- state (a task by its source, hand-crafting, a human hold, idle), keeps the
-- idle gaps by the state that ended them, and tasks.body_time() reads it with
-- the open interval included. Offline: the real dispatcher and companion
-- module over a mocked LuaPlayer.
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
  gui_type = { none = 0, entity = 1, controller = 3, item = 5 },
  events = setmetatable({}, { __index = function(_, key) return key end }),
}
_G.prototypes = { entity = { character = { collision_mask = { layers = { player = true } },
  collision_box = { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } } } } }
_G.rendering = { draw_text = function() return { valid = true, destroy = function() end } end }

local body = {
  valid = true, position = { x = 0, y = 0 }, force = {}, character_running_speed_modifier = 0,
  walking_state = {}, mining_state = {}, picking_state = false,
  crafting_queue = {}, crafting_queue_size = 0, cancel_crafting = function() end,
}
body.surface = {
  find_entities_filtered = function() return {} end,
  get_tile = function() return { collides_with = function() return false end } end,
  request_path = function() return 1 end,
}
local player = { index = 1, valid = true, connected = true, name = "Codex", character = body, force = body.force,
  controller_type = defines.controllers.character, physical_controller_type = defines.controllers.character, afk_time = 100000,
  opened_gui_type = defines.gui_type.none, cursor_stack = { valid_for_read = false } }
_G.game = { tick = 0, get_player = function(index) return index == 1 and player or nil end, connected_players = { player } }

local inert = { start = function() end, tick = function() return { status = "done", detail = "done" } end }
package.loaded["scripts.actions.craft"] = inert
package.loaded["scripts.actions.build"] = { place = inert, rotate = inert,
  set_recipe_action = { runner = inert, make_task = function() return {} end } }
package.loaded["scripts.actions.transfer"] = { insert = inert, extract = inert,
  flush_action = { runner = inert, make_task = function() return {} end } }
package.loaded["scripts.actions.build_plan"] = inert
package.loaded["scripts.inspect"] = { MAX_TARGETS = 64, PER_TARGET = 40,
  job = { start = function() return {} end, step = function() return {} end }, inspect = function() error("unexpected inspect") end }

local companion = require("scripts.companion")
local tasks = require("scripts.tasks")

_G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil,
  body_time = { since_tick = 0, state = "idle", state_since = 0, ticks = {}, gaps = {} },
  holds = { count = 0, total_ticks = 0, recent = {} } },
  companion = { player_index = 1, entity = body } }
local function ticks(n)
  for _ = 1, n do game.tick = game.tick + 1; tasks.on_tick() end
end
-- A walk whose path is never answered keeps its plan active until cancelled.
local function busy(source, n)
  tasks.queue_plan({ source = source, steps = { { action = "walk_to", x = 50, y = 0 } } })
  ticks(n)
  tasks.cancel({ all = true, origin = "test/body-time" })
end

check(tasks.body_time().state == "idle" and tasks.body_time().ticks.idle == 0, "a fresh counter starts idle at its since tick")
ticks(10)
busy("pilot", 20)
ticks(7)
busy("package:p1", 30)
ticks(3)
busy("upkeep", 15)
ticks(4)
body.crafting_queue_size = 2
ticks(5)
body.crafting_queue_size = 0
ticks(6)
companion.on_human_input({ player_index = 1, input_name = "agentic-companion-mine" })
ticks(320)
ticks(2)

local time = tasks.body_time()
local total = 0
for _, n in pairs(time.ticks) do total = total + n end
check(total == game.tick - time.since_tick, "every tick since since_tick is accounted to exactly one state (" .. total .. ")")
-- Each tick's state is read as the tick begins: a plan the dispatcher
-- starts in tick t counts from t + 1, and a hold the tick detects counts
-- from the next one; a cancel or crafting between ticks counts at once.
check(time.ticks.pilot == 19 and time.ticks.package == 29 and time.ticks.upkeep == 14,
  "a plan's ticks go to its source: pilot, package or upkeep")
check(time.ticks.crafting == 5, "hand-crafting with no task is body work, not idle")
check(time.ticks.hold == 299, "a human hold is its own state, neither idle nor work")
check(time.gaps.pilot.count == 1 and time.gaps.pilot.ticks == 12 and time.gaps.package.ticks == 8
  and time.gaps.upkeep.ticks == 4 and time.gaps.crafting.ticks == 4 and time.gaps.hold.ticks == 7,
  "each idle gap is kept under the state that ended it")
check(time.gaps.pilot.longest == 12 and time.gaps.pilot.longest_end_tick == 12, "the longest gap and its end tick are kept")
check(time.state == "idle" and time.ticks.idle == 12 + 8 + 4 + 4 + 7 + (game.tick - time.state_since),
  "the open idle interval counts in the read without closing a gap")
local before = storage.tasks.body_time.ticks.idle
tasks.body_time()
check(storage.tasks.body_time.ticks.idle == before, "the read never writes the counters")

-- Each hold is an episode with its cause: the linked control's name.
local holds = tasks.holds()
local first = holds.recent[1]
check(holds.count == 1 and #holds.recent == 1 and first.cause == "mine" and first.end_tick ~= nil
  and first.end_tick - first.start_tick == time.ticks.hold and holds.total_ticks == time.ticks.hold,
  "a hold is kept as an episode {start_tick, end_tick, cause} with its ticks in total_ticks")

-- The poll's causes (an open GUI, a held item) and another controller's.
player.opened_gui_type = defines.gui_type.entity
ticks(2)
local open = tasks.holds()
check(open.count == 2 and open.recent[2].cause == "gui" and open.recent[2].end_tick == nil
  and open.total_ticks == time.ticks.hold + game.tick - open.recent[2].start_tick
  and storage.tasks.holds.total_ticks == time.ticks.hold,
  "an open hold has no end_tick yet; the read counts its ticks so far without writing them")
player.opened_gui_type = defines.gui_type.none
ticks(310)
check(tasks.holds().recent[2].end_tick ~= nil, "a closed GUI releases the hold")
player.cursor_stack.valid_for_read = true
ticks(1)
player.cursor_stack.valid_for_read = false
ticks(305)
player.controller_type = defines.controllers.spectator
ticks(3)
player.controller_type = defines.controllers.character
ticks(2)
holds = tasks.holds()
check(holds.count == 4 and holds.recent[3].cause == "cursor" and holds.recent[4].cause == "controller"
  and holds.recent[4].end_tick - holds.recent[4].start_tick == 3, "a held item and another controller name their causes")
-- The ring keeps the last 16 episodes; count and total_ticks keep every one.
local total = holds.total_ticks
for _ = 1, 20 do
  companion.on_human_input({ player_index = 1 })
  ticks(301)
end
holds = tasks.holds()
check(holds.count == 24 and #holds.recent == 16 and holds.recent[16].cause == "gui"
  and holds.total_ticks == total + 20 * 299, "the ring keeps the last 16 episodes; count and total_ticks keep all")

-- The recorder's window mark: the gap open at the mark counts from it when
-- it closes; the idle ticks themselves stay whole.
ticks(10)
local idle_before = tasks.body_time().ticks.idle
tasks.mark_body_window()
local mark = game.tick
ticks(5)
busy("pilot", 4)
time = tasks.body_time()
check(time.window_tick == mark, "the read reports the window mark")
check(time.gaps.pilot.count == 2 and time.gaps.pilot.ticks == 12 + 7 and time.gaps.pilot.longest == 12,
  "a gap open at the mark counts only its ticks after the mark (" .. time.gaps.pilot.ticks .. ")")
check(time.ticks.idle == idle_before + 7, "idle ticks before the mark still count as idle")

-- waiting: pilot or package plans are queued but none can take the body
-- (a parked wait, a plan behind it). Work the dispatcher starts in the same
-- tick never counts as waiting (the pilot and package ticks above).
do
  storage.tasks.body_time = { since_tick = game.tick, state = "idle", state_since = game.tick, ticks = {}, gaps = {},
    phases = {}, tiles = 0 }
  local first_plan = tasks.queue_plan({ steps = { { action = "walk_to", x = 50, y = 0 } } })
  ticks(2)
  local parked = storage.tasks.active
  storage.tasks.active, parked.status, parked.next_check_tick = nil, "waiting", game.tick + 100
  table.insert(storage.tasks.queue, 1, parked)
  tasks.queue_plan({ steps = { { action = "walk_to", x = 60, y = 0 } }, after_plan_id = first_plan.plan_id })
  ticks(10)
  local waited = tasks.body_time()
  check(waited.state == "waiting" and waited.ticks.waiting == 9 and waited.gaps.waiting == nil,
    "a parked plan and one behind it leave the body waiting, not idle")
  tasks.cancel({ all = true, origin = "test/body-time" })
  ticks(1)
  check(tasks.body_time().state == "idle", "with nothing queued the body is idle again")
end

-- traveling: a travel step waiting for a rocket, for its platform to
-- arrive, or riding, is its own state, never pilot or package work.
do
  storage.tasks.body_time = { since_tick = game.tick, state = "idle", state_since = game.tick, ticks = {}, gaps = {},
    phases = {}, tiles = 0 }
  tasks.queue_plan({ steps = { { action = "walk_to", x = 50, y = 0 } } })
  ticks(3)
  -- A travel step that keeps waiting (its runner here never ends).
  tasks.register_action("travel", { runner = { start = function() end, tick = function() return nil end },
    make_task = function() return {} end })
  local walk = storage.tasks.active.current_task
  storage.tasks.active.current_task = { type = "travel", _phase = "wait_arrival" }
  ticks(5)
  storage.tasks.active.current_task = { type = "travel", _phase = "land" }
  ticks(2)
  storage.tasks.active.current_task = walk
  tasks.cancel({ all = true, origin = "test/body-time" })
  ticks(1)
  local time = tasks.body_time()
  check(time.ticks.traveling == 5 and time.ticks.pilot == 2 + 2 and time.state == "idle",
    "a travel step's waiting phases count as traveling; boarding or landing stays pilot work ("
      .. tostring(time.ticks.traveling) .. ", " .. tostring(time.ticks.pilot) .. ")")
end

-- Body phases: each pilot or package tick is one phase, walk first (tiles
-- add up the distance moved), then mine, smelt_wait, craft_wait, other; no
-- upkeep, hold or idle tick counts. They add up to the pilot and package ticks.
do
  storage.tasks.body_time = { since_tick = game.tick, state = "idle", state_since = game.tick, ticks = {}, gaps = {},
    phases = {}, tiles = 0 }
  tasks.queue_plan({ steps = { { action = "walk_to", x = 50, y = 0 } } })
  ticks(4) -- dispatched in the first tick: 3 ticks standing still
  for _ = 1, 5 do body.position = { x = body.position.x + 0.2, y = body.position.y }; ticks(1) end
  body.position = { x = body.position.x + 40, y = body.position.y } -- a landing, not a walk
  ticks(1)
  body.mining_state = { mining = true }
  ticks(2)
  body.mining_state = { mining = false }
  storage.tasks.active.current_task._stack = { { name = "iron-plate", phase = "smelt_wait" } }
  ticks(2)
  storage.tasks.active.current_task._stack = nil
  body.crafting_queue_size = 3
  for _ = 1, 3 do storage.craft_wait_tick = game.tick + 1; ticks(1) end
  -- Walking while it waits on crafting is walking.
  storage.craft_wait_tick = game.tick + 1
  body.position = { x = body.position.x + 0.2, y = body.position.y }
  ticks(1)
  body.crafting_queue_size, storage.craft_wait_tick = 0, nil
  tasks.cancel({ all = true, origin = "test/body-time" })
  busy("upkeep", 6)
  busy("package:p2", 3)
  ticks(1) -- closes the package interval (an open one counts up to the tick before)
  local time = tasks.body_time()
  local phases, sum = time.phases, 0
  for _, n in pairs(phases) do sum = sum + n end
  check(phases.walk == 6 and phases.mine == 2 and phases.smelt_wait == 2 and phases.craft_wait == 3
    and phases.other == 3 + 1 + 2, "each pilot or package tick is one phase, walk first")
  check(time.tiles == 1.2, "tiles add up the distance walked; a jump of 40 tiles is no walk (" .. tostring(time.tiles) .. ")")
  check(sum == time.ticks.pilot + time.ticks.package and time.ticks.upkeep == 5,
    "the phases add up to the pilot and package ticks; upkeep is left out (" .. sum .. ")")
  local snapshot = tasks.body_time()
  snapshot.phases.walk = 0
  check(storage.tasks.body_time.phases.walk == 6, "the read copies the phases")
end

-- next_event's idle_since_tick: the end of the last pilot work. The mod's
-- own upkeep never moves it; a human hold restarts it.
do
  busy("pilot", 3)
  local ended = game.tick
  check(storage.tasks.last_pilot_finished_tick == ended, "a pilot plan's end is the last pilot work's end")
  ticks(2)
  busy("upkeep", 3)
  check(storage.tasks.last_pilot_finished_tick == ended, "an upkeep plan's end leaves it alone")
  companion.on_human_input({ player_index = 1, input_name = "agentic-companion-mine" })
  ticks(2)
  check(storage.tasks.last_pilot_finished_tick == game.tick, "a human hold keeps restarting it")
  ticks(320)
end

-- A save without the counter (before state.init made it) reads nil and is not accounted.
storage.tasks.body_time = nil
ticks(1)
check(tasks.body_time() == nil and storage.tasks.body_time == nil, "no counter: nothing is accounted or read")

os.exit(failures == 0 and 0 or 1)
