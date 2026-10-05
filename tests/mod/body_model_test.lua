-- The body model (companion.lua, contract C1): the Codex player's body in
-- every controller state and on every surface. body() never errors and
-- evaluates absent/disconnected, dead, in_transit, aboard_platform,
-- on_surface, other in that order; physical runners get the character only
-- on a surface; reads anchor on the physical surface, the hub aboard, the
-- pod in transit; the human hold, rebinding after a trip or a respawn, the
-- surface-change record (the remote view is no move), connect_status with
-- the body away, the label and spectators following the body, and the
-- per-surface world policy (Vulcanus generates no demolishers).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

_G.defines = {
  controllers = { character = 1, spectator = 4, remote = 7, cutscene = 8, god = 2, editor = 3 },
  gui_type = { none = 0, entity = 1 },
}
local labels = {}
_G.rendering = { draw_text = function(args)
  local label = { valid = true, target = args.target, surface = args.surface }
  label.destroy = function() label.valid = false end
  labels[#labels + 1] = label
  return label
end }
local tags = {}
local force = { name = "player", add_chart_tag = function(surface, args)
  local tag = { valid = true, position = args.position, surface = surface }
  tag.destroy = function() tag.valid = false end
  tags[#tags + 1] = tag
  return tag
end }
local nauvis = { valid = true, index = 1, name = "nauvis", planet = { name = "nauvis" } }
local platform = { valid = true, index = 3, name = "alpha" }
local platform_surface = { valid = true, index = 5, name = "platform-3", platform = platform }
local vulcanus = { valid = true, index = 6, name = "vulcanus", planet = { name = "vulcanus" } }

local function character(position, surface)
  local c = { valid = true, position = position, surface = surface, force = force, character_running_speed_modifier = 0 }
  c.destroy = function() c.valid = false end
  return c
end
local body_entity = character({ x = 4, y = -2 }, nauvis)
local hub = { valid = true, name = "space-platform-hub", position = { x = 0, y = 0 }, surface = platform_surface }
local pod = { valid = true, name = "cargo-pod", position = { x = 1, y = 9 }, surface = nauvis }

local codex = { index = 1, valid = true, connected = true, name = "Codex", force = force, character = body_entity,
  controller_type = defines.controllers.character, physical_controller_type = defines.controllers.character,
  surface = nauvis, position = { x = 4, y = -2 }, physical_surface = nauvis, physical_position = { x = 4, y = -2 },
  opened_gui_type = defines.gui_type.none, cursor_stack = { valid_for_read = false } }
local teleports = {}
local viewer = { index = 2, valid = true, connected = true, name = "couch", controller_type = defines.controllers.spectator,
  teleport = function(position, surface) teleports[#teleports + 1] = { position = position, surface = surface } end }
local players = { codex, viewer }
_G.game = { tick = 100, connected_players = players, get_player = function(index) return players[index] end,
  surfaces = { nauvis, platform_surface }, map_settings = { enemy_expansion = { enabled = true } } }
_G.storage = { tasks = { queue = {} }, travel = { arrivals = {} } }

local companion = require("scripts.companion")
companion.on_player_available({ player_index = 1 })

-- States, in order.
-- NONE clears a field (pairs skips nil values).
local NONE = {}
local function set(fields)
  for key, value in pairs(fields) do
    if value == NONE then codex[key] = nil else codex[key] = value end
  end
end
local body = companion.body()
check(body.state == "on_surface" and body.surface_ref == "nauvis" and body.position.x == 4 and body.force == force
  and companion.get() == body_entity, "standing in its character the body is on_surface and runners get the character")
codex.connected = false
check(companion.body().state == "disconnected" and companion.get() == nil and companion.anchor() == nil,
  "a disconnected Codex player has no body to act or read with")
codex.connected = true
codex.ticks_to_respawn = 600
check(companion.body().state == "dead" and companion.get() == nil, "a player waiting to respawn is dead")
codex.ticks_to_respawn = nil

-- Aboard a platform hub: the controller reads remote and the character still
-- looks valid; aboard comes first, so no runner gets the character.
set({ hub = hub, controller_type = defines.controllers.remote, physical_surface = platform_surface,
  physical_position = { x = 0, y = 0 } })
body = companion.body()
check(body.state == "aboard_platform" and body.surface_ref == "platform:3" and body.platform == platform
  and companion.get() == nil, "in a hub the body is aboard_platform on platform:3 and no runner gets the character")
local anchor = companion.anchor()
check(anchor.surface == platform_surface and anchor.position.x == 0 and anchor.force == force,
  "reads anchor on the hub's surface and position aboard")
local ok, err = pcall(companion.require_companion)
check(not ok and tostring(err):match("^BODY_ABOARD: the body is aboard platform alpha %(platform:3%)"),
  "a physical action aboard fails BODY_ABOARD naming the platform")
check(companion.require_present().state == "aboard_platform", "remote actions and reads still find the body aboard")
local summary = companion.body_summary()
check(summary.state == "aboard_platform" and summary.surface_ref == "platform:3" and summary.platform_name == "alpha",
  "the body summary for ping names the state, surface and platform")
local connected = companion.connect()
check(connected.position.x == 0 and connected.body.state == "aboard_platform",
  "connect_status treats aboard as connected with the body away")
companion.update_map_tag()
check(storage.companion.label_target == hub and labels[#labels].target.entity == hub and tags[#tags].surface == platform_surface,
  "the label and the map tag move to the hub while aboard")
companion.follow_spectators()
check(#teleports == 1 and teleports[1].surface == platform_surface, "spectators follow the body to the platform")

-- Human hold aboard: being aboard holds nothing; a GUI on the Codex client
-- is still the owner's input.
game.tick = 200
local held = companion.human_control()
check(held == false, "aboard, the body is not held by itself")
codex.opened_gui_type = defines.gui_type.entity
companion.poll_human_activity(false)
held = companion.human_control()
check(held == true and storage.tasks.human_activity_tick == 200, "aboard, an open GUI on the Codex client holds")
codex.opened_gui_type = defines.gui_type.none
game.tick = 600
companion.on_human_input({ player_index = 1, input_name = "agentic-companion-move-up" })
check(storage.tasks.human_activity_tick == 200, "aboard, the movement keys only pan the camera: no hold")
companion.on_human_input({ player_index = 1 })
check(storage.tasks.human_activity_tick == 600, "aboard, opening a GUI is the owner's input")
game.tick = 700
companion.on_human_input({ player_index = 1, input_name = "agentic-companion-build" })
check(storage.tasks.human_activity_tick == 700, "aboard, any other linked control is the owner's input too")
game.tick = 1000

-- In a cargo pod: in transit, anchored on the pod.
set({ hub = NONE, cargo_pod = pod, physical_surface = nauvis })
body = companion.body()
check(body.state == "in_transit" and body.entity == pod and body.position.y == 9 and companion.human_control() == false,
  "in a cargo pod the body is in_transit, anchored on the pod, and holds nothing")
ok, err = pcall(companion.require_companion)
check(not ok and tostring(err):match("^BODY_IN_TRANSIT"), "a physical action in transit fails BODY_IN_TRANSIT")
set({ cargo_pod = NONE, controller_type = defines.controllers.cutscene, physical_controller_type = defines.controllers.cutscene })
check(companion.body().state == "other" and companion.human_control() == true,
  "a cutscene outside a travel step is another controller, which holds")
storage.travel.active = { task_id = 9, to = "platform:3", since_tick = game.tick }
check(companion.body().state == "in_transit" and companion.human_control() == false,
  "the launch cutscene of a travel step is transit")
storage.travel.active = nil
set({ controller_type = defines.controllers.god, physical_controller_type = defines.controllers.god })
check(companion.body().state == "other" and companion.human_control() == true, "any other controller is other and holds")
codex.ticks_to_respawn = 300
check(companion.body().state == "dead" and companion.human_control() == false, "a dead body never holds")
codex.ticks_to_respawn = nil

-- Back on a surface: the remote view on another surface changes the player's
-- surface, not the body's.
set({ controller_type = defines.controllers.character, physical_controller_type = defines.controllers.character,
  physical_surface = nauvis, physical_position = { x = 4, y = -2 } })
storage.companion.surface_ref = nil
check(companion.note_body_surface() == nil and storage.companion.surface_ref == "nauvis",
  "the first sighting records the body's surface without a change")
set({ controller_type = defines.controllers.remote, surface = vulcanus })
check(companion.note_body_surface() == nil and companion.body().state == "on_surface",
  "the remote view on another surface is no move of the body")
set({ controller_type = defines.controllers.character, surface = nauvis })

-- A landing: the character arrives on Vulcanus. The same character is
-- bound again; a new one replaces a gone one; two live associated
-- characters are refused.
body_entity.surface = vulcanus
set({ physical_surface = vulcanus, physical_position = { x = 50, y = 60 } })
local change = companion.note_body_surface()
check(change and change.from == "nauvis" and change.to == "vulcanus" and change.state == "on_surface"
  and change.surface_index == 6, "a physical surface change is recorded with from, to, state and surface")
companion.rebind({ player_index = 1 })
check(companion.get() == body_entity, "the same character is bound again after the trip")
body_entity.valid = false
local landed = character({ x = 50, y = 60 }, vulcanus)
codex.character = landed
companion.rebind({ player_index = 1 })
check(companion.get() == landed and storage.companion.entity == landed, "a gone character is replaced by the player's own")
local second = character({ x = 0, y = 0 }, nauvis)
codex.character = second
codex.get_associated_characters = function() return { landed, second } end
companion.rebind({ player_index = 1 })
check(storage.companion.entity == landed and storage.companion.rebind_refused.characters == 2,
  "two live associated characters are refused, never a second body")
ok, err = pcall(companion.require_companion)
check(not ok and tostring(err):match("^REBIND_REFUSED: the Codex player has 2 live characters")
  and companion.body_summary().rebind_refused.characters == 2,
  "a refused rebind fails physical actions REBIND_REFUSED and ping's body summary names it")
codex.get_associated_characters = function() return { second } end
companion.rebind({ player_index = 1 })
check(storage.companion.entity == second and storage.companion.rebind_refused == nil,
  "a stale stored character gives way to the player's only one")
codex.character = landed
storage.companion.entity = landed

-- Death and respawn.
check(companion.is_dead() == false, "a living body is not dead")
companion.on_player_died({ player_index = 1 })
check(companion.is_dead() == true, "a died body is dead until it respawns")
ok, err = pcall(companion.require_companion)
check(companion.body().state == "dead" and not ok and tostring(err):match("^BODY_DEAD"), "a dead body fails BODY_DEAD")
local respawned = character({ x = 0, y = 0 }, nauvis)
codex.character = respawned
set({ physical_surface = nauvis, physical_position = { x = 0, y = 0 } })
companion.on_player_respawned({ player_index = 1 })
check(companion.get() == respawned and storage.companion.dead == nil and companion.is_dead() == false
  and companion.body_summary().rebind_refused == nil, "the respawned character is bound")
change = companion.note_body_surface()
check(change and change.from == "vulcanus" and change.to == "nauvis", "a respawn on another planet is a surface change")

-- Absent: no Codex player.
storage.companion.player_index = nil
check(companion.body().state == "absent" and companion.anchor() == nil, "without a Codex player the body is absent")
ok, err = pcall(companion.require_present)
check(not ok and tostring(err):match("^BODY_UNAVAILABLE"), "remote actions and reads need a connected Codex player")
storage.companion.player_index = 1

-- World policy per surface: Vulcanus is written no-enemies when it is
-- created (map generation and the surface), Nauvis is not.
local function planet_surface(name)
  return { name = name, planet = { name = name }, peaceful_mode = false, no_enemies_mode = false,
    map_gen_settings = { autoplace_controls = {} } }
end
local new_vulcanus, home = planet_surface("vulcanus"), planet_surface("nauvis")
game.surfaces = { home, new_vulcanus }
companion.enforce_peaceful_world({ surface_index = 2 })
check(new_vulcanus.no_enemies_mode == true and new_vulcanus.map_gen_settings.no_enemies_mode == true
  and new_vulcanus.peaceful_mode == true and new_vulcanus.map_gen_settings.autoplace_controls["enemy-base"].frequency == 0,
  "a new Vulcanus surface generates no demolishers (V1)")
companion.enforce_peaceful_world({ surface_index = 1 })
check(home.no_enemies_mode == false and home.map_gen_settings.no_enemies_mode == nil and home.peaceful_mode == true,
  "Nauvis stays peaceful without no-enemies mode")

os.exit(failures == 0 and 0 or 1)
