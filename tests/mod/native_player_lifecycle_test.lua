local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

_G.defines = { controllers = { character = 1, spectator = 4 } }
local force = { add_chart_tag = function(_, args)
  return { valid = true, position = args.position, destroy = function() end }
end }
local surface = {
  peaceful_mode = false,
  map_gen_settings = { autoplace_controls = { coal = { frequency = 1 } } },
}
local players = {}
_G.game = {
  connected_players = {},
  players = players,
  surfaces = { surface },
  map_settings = { enemy_expansion = { enabled = true } },
  get_player = function(index) return players[index] end,
}
_G.rendering = { draw_text = function() return { valid = true, destroy = function() end } end }
_G.storage = {}

local companion = require("scripts.companion")
local ok, err = pcall(companion.connect)
check(not ok and tostring(err):match("native player 'Codex' is not connected") ~= nil,
  "absent native Codex reports a deterministic connection error")

local viewer_body = { valid = true }
viewer_body.destroy = function() viewer_body.valid = false end
local viewer_teleports = 0
local viewer
viewer = {
  index = 2, valid = true, connected = true, name = "couch", character = viewer_body,
  controller_type = defines.controllers.character,
  set_controller = function(args) viewer.controller_type = args.type; viewer.character = nil end,
  teleport = function() viewer_teleports = viewer_teleports + 1 end,
}
players[2] = viewer
game.connected_players = { viewer }
companion.on_player_available({ player_index = 2 })
check(viewer.controller_type == defines.controllers.spectator and viewer.character == nil and not viewer_body.valid,
  "wrong-name couch client becomes a characterless spectator")
check(companion.get() == nil and storage.companion == nil,
  "wrong-name player is never adopted as Codex")

local impostor = {
  index = 3, valid = true, connected = true, name = "Codex", character = nil,
  controller_type = defines.controllers.spectator,
}
players[3] = impostor
game.connected_players = { impostor, viewer }
companion.on_player_available({ player_index = 3 })
check(companion.get() == nil and storage.companion == nil,
  "Codex-named spectator is excluded because it has no native character")

local codex_body = {
  valid = true, position = { x = 4, y = -2 }, surface = surface, force = force,
  character_running_speed_modifier = 0.7,
}
local codex = {
  index = 1, valid = true, connected = true, name = "Codex", character = codex_body,
  controller_type = defines.controllers.character,
}
players[1] = codex
game.connected_players = { codex, viewer }
companion.on_player_available({ player_index = 1 })
check(companion.get() == codex_body and storage.companion.player_index == 1,
  "native lifecycle event binds the exact Codex LuaPlayer character")
check(codex_body.character_running_speed_modifier == 0,
  "native Codex retains ordinary Factorio movement speed")
companion.follow_spectators()
check(viewer_teleports == 1, "only the characterless couch camera follows Codex")

codex.connected = false
companion.on_player_left({ player_index = 1 })
check(companion.get() == nil and storage.companion.disconnected == true,
  "disconnect makes the native body unavailable without replacing it")
codex.connected = true
companion.on_player_available({ player_index = 1 })
check(companion.get() == codex_body and storage.companion.disconnected == nil,
  "reconnect rebinds the same native player character")

codex_body.valid = false
codex.character = nil
companion.on_player_died({ player_index = 1 })
check(companion.get() == nil and storage.companion.dead == true and storage.companion.entity == nil,
  "death records the absent body without standalone respawn")
ok, err = pcall(companion.connect)
check(not ok and tostring(err):match("native player 'Codex' is not connected") ~= nil,
  "connect cannot create or respawn a body after death")
local respawn_body = {
  valid = true, position = { x = 0, y = 0 }, surface = surface, force = force,
  character_running_speed_modifier = 0,
}
codex.character = respawn_body
companion.on_player_respawned({ player_index = 1 })
check(companion.get() == respawn_body and storage.companion.dead == nil,
  "Factorio's native respawn event is the only body replacement trigger")

local legacy_destroyed = false
storage.companion = {
  entity = { valid = true },
}
storage.companion.entity.destroy = function()
  legacy_destroyed = true
  storage.companion.entity.valid = false
end
companion.on_player_available({ player_index = 1 })
check(legacy_destroyed and companion.get() == respawn_body,
  "old standalone save record migrates once to the native body without a second character")

companion.enforce_peaceful_world()
local enemy_bases = surface.map_gen_settings.autoplace_controls["enemy-base"]
check(surface.peaceful_mode and game.map_settings.enemy_expansion.enabled == false,
  "peaceful mode and enemy expansion remain disabled")
check(enemy_bases.frequency == 0 and enemy_bases.size == 0 and enemy_bases.richness == 0,
  "enemy-base generation remains disabled on every surface")

os.exit(failures == 0 and 0 or 1)
