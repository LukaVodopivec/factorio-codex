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
  body_time = { since_tick = 0, state = "idle", state_since = 0, ticks = {}, gaps = {} } },
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
companion.on_human_input({ player_index = 1 })
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

-- A save without the counter (before state.init made it) reads nil and is not accounted.
storage.tasks.body_time = nil
ticks(1)
check(tasks.body_time() == nil and storage.tasks.body_time == nil, "no counter: nothing is accounted or read")

os.exit(failures == 0 and 0 or 1)
