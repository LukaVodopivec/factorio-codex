-- control.lua's body-move wiring: the Codex player's surface events rebind
-- the body and, when its physical surface changed, set the surface cancel
-- flag, record body_surface_changed in the space event ring and, on a
-- planet, apply the world policy and chart once. Switching the remote view
-- to another surface is no move; another player's event is ignored; a
-- failure never raises into the game's event. The travel RPC queues a
-- pilot plan. The real companion and platforms modules; tasks and chores
-- record what they are asked.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

_G.storage = { rpc_outbox = { next_id = 1, by_id = {} }, space = { created = {}, events = {} }, travel = { arrivals = {} },
  tasks = { queue = {} } }
_G.defines = { events = setmetatable({}, { __index = function(_, key) return key end }),
  controllers = { character = 1, spectator = 4, remote = 7 } }
local events = {}
_G.script = {
  active_mods = { ["agentic-companion"] = "0.22.3", base = "2.0.77" },
  on_init = function() end, on_configuration_changed = function() end,
  on_event = function(id, handler) events[id] = handler end, on_nth_tick = function() end,
}
local registered
_G.remote = { add_interface = function(_, value) registered = value end }
local responded
_G.helpers = { table_to_json = function(value) responded = value; return "{}" end,
  json_to_table = function() return { to = "vulcanus" } end }
_G.rcon = { print = function() end }
_G.rendering = { draw_text = function() return { valid = true, destroy = function() end } end }

local function stub(name, value) package.loaded[name] = value end
stub("scripts.state", { init = function() end })
local flags, queued = {}, {}
local fail_flag = false
local bound_for
stub("scripts.tasks", { set_observer = function() end, set_upkeep_listener = function() end, set_boundary_upkeep = function() end, on_tick = function() end, resume_active = function() end,
  bound_for = function() return bound_for end,
  on_body_surface_changed = function(change)
    if fail_flag then error("broken") end
    flags[#flags + 1] = change
  end,
  queue_plan = function(params) queued[#queued + 1] = params; params.steps[1]._to = "vulcanus"; return { plan_id = 12 } end,
  plan_status = function() end, enqueue = function() end, get = function() end, cancel = function() end,
  activity_log = function() end, log_event = function() end, register_action = function() end })
local arrivals = {}
stub("scripts.chores", { on_nth = {}, on_arrival = function(change) arrivals[#arrivals + 1] = change end })
stub("scripts.thoughts", { register_rpcs = function() end, init = function() end, on_player_joined = function() end })

local force = { name = "player", add_chart_tag = function() return { valid = true, position = { x = 0, y = 0 },
  destroy = function() end } end }
local nauvis = { valid = true, index = 1, name = "nauvis", planet = { name = "nauvis" }, peaceful_mode = false,
  map_gen_settings = { autoplace_controls = {} } }
local vulcanus = { valid = true, index = 6, name = "vulcanus", planet = { name = "vulcanus" }, peaceful_mode = false,
  no_enemies_mode = false, map_gen_settings = { autoplace_controls = {} } }
local character = { valid = true, position = { x = 0, y = 0 }, surface = nauvis, force = force, character_running_speed_modifier = 0 }
local codex = { index = 1, valid = true, connected = true, name = "Codex", force = force, character = character,
  controller_type = defines.controllers.character, physical_controller_type = defines.controllers.character,
  surface = nauvis, physical_surface = nauvis, physical_position = { x = 0, y = 0 } }
_G.game = { tick = 500, connected_players = { codex }, get_player = function(i) return i == 1 and codex or nil end,
  surfaces = { [1] = nauvis, [6] = vulcanus }, map_settings = { enemy_expansion = { enabled = true } } }

assert(loadfile(here .. "/../../mod/agentic-companion/control.lua"))()
local companion = require("scripts.companion")
companion.on_player_available({ player_index = 1 })
local moved = events.on_player_changed_surface
moved({ player_index = 1 })
check(#flags == 0 and storage.companion.surface_ref == "nauvis", "the first sighting records the surface, no change")

-- The remote view on Vulcanus: the player's surface moves, the body does not.
codex.controller_type, codex.surface = defines.controllers.remote, vulcanus
moved({ player_index = 1 })
check(#flags == 0 and #storage.space.events == 0, "switching the remote view to another surface moves nothing")

-- The body lands on Vulcanus.
codex.controller_type, codex.physical_surface, character.surface = defines.controllers.character, vulcanus, vulcanus
moved({ player_index = 2 })
check(#flags == 0, "another player's surface event is ignored")
events.on_cargo_pod_finished_descending({ player_index = 1, cargo_pod = { force = force, surface = vulcanus } })
local ring = storage.space.events[#storage.space.events]
check(#flags == 1 and flags[1].from == "nauvis" and flags[1].to == "vulcanus" and ring.kind == "body_surface_changed"
  and ring.from == "nauvis" and ring.to == "vulcanus" and ring.state == "on_surface",
  "a landing sets the surface cancel flag and records body_surface_changed")
check(#arrivals == 1 and vulcanus.peaceful_mode == true and vulcanus.no_enemies_mode == true,
  "arriving on a planet applies its world policy and charts once")
moved({ player_index = 1 })
check(#flags == 1, "the same surface again is no change")

-- A pod lands the body on Fulgora, its surface change already seen while
-- it rode down: the landing itself is the arrival (world policy, one chart).
local fulgora = { valid = true, index = 7, name = "fulgora", planet = { name = "fulgora" }, peaceful_mode = false,
  map_gen_settings = { autoplace_controls = {} } }
game.surfaces[7] = fulgora
local pod = { valid = true, surface = fulgora, position = { x = 3, y = 4 } }
codex.cargo_pod, codex.physical_surface = pod, fulgora
moved({ player_index = 1 })
check(#flags == 2 and flags[2].to == "fulgora" and flags[2].state == "in_transit" and #arrivals == 1,
  "a surface change seen in the pod is recorded, with no arrival yet")
codex.cargo_pod, character.surface = nil, fulgora
events.on_cargo_pod_finished_descending({ player_index = 1, cargo_pod = { force = force, surface = fulgora } })
check(#flags == 2 and #arrivals == 2 and arrivals[2].to == "fulgora" and fulgora.peaceful_mode == true,
  "standing on the planet after the pod is the arrival: world policy and one chart, no second surface change")
moved({ player_index = 1 })
check(#arrivals == 2, "an arrival is handled once")
codex.physical_surface, character.surface = vulcanus, vulcanus
moved({ player_index = 1 })
check(#flags == 3 and #arrivals == 3, "a direct change while standing is a change and an arrival at once")

-- ping names a pending travel destination.
bound_for = "platform:3"
registered.rpc("ping", "")
check(responded.ok and responded.data.body.bound_for == "platform:3" and responded.data.body.state == "on_surface",
  "ping carries the destination of the travel step pending in the FIFO")
bound_for = nil

-- A failure inside the handling never raises into the event.
fail_flag = true
codex.physical_surface, character.surface = nauvis, nauvis
check(pcall(moved, { player_index = 1 }), "a failing handler never raises into the game's event")
fail_flag = false

-- travel over RPC queues a pilot plan with one travel step.
registered.rpc("travel", '{"to":"vulcanus"}')
check(#queued == 1 and queued[1].steps[1].action == "travel" and queued[1].source == nil
  and responded.ok and responded.data.plan_id == 12 and responded.data.to == "vulcanus",
  "the travel tool queues a pilot plan and answers with it")

os.exit(failures == 0 and 0 or 1)
