local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
_G.storage = {}; _G.settings = nil
local tag = { valid = true, position = { x = 1, y = 2 }, destroy = function() end }
local force = { add_chart_tag = function() return tag end }
local body = { valid = true, unit_number = 41, position = { x = 1, y = 2 }, force = force }
local surface
surface = {
  find_non_colliding_position = function() return { x = 1, y = 2 } end,
  create_entity = function() body.surface = surface return body end,
}
local player = { surface = surface, position = { x = 0, y = 0 }, force = force }
_G.game = { connected_players = { player }, forces = { player = force }, surfaces = { surface } }
_G.rendering = { draw_text = function() return { valid = true, destroy = function() end } end }
local companion = require("scripts.companion")
check(companion.movement_speed_multiplier() == 1.6, "configured movement remains physical")
local missing, missing_error = pcall(companion.require_companion)
check(not missing and tostring(missing_error):match("call connect_status first") ~= nil
  and tostring(missing_error):match("spawn_companion") == nil,
  "missing-body guidance names only the public connect_status tool")
local created = companion.spawn()
local response_keys = {}; for key in pairs(created) do response_keys[#response_keys + 1] = key end
check(#response_keys == 1 and response_keys[1] == "position",
  "spawn returns only the fixed body's position without selectable identity")
local record_keys = {}; for key in pairs(storage.companion) do record_keys[#record_keys + 1] = key end; table.sort(record_keys)
check(table.concat(record_keys, ",") == "entity,label,map_tag", "storage contains exactly one fixed Codex record")
companion.apply_movement_speed()
check(math.abs(body.character_running_speed_modifier - 0.6) < 0.000001, "movement modifier applies to Codex")
storage.companion.entity = { valid = false }
check(companion.get() == nil and companion.record() ~= nil, "death persists without auto-respawn")
local respawned, respawn_error = pcall(companion.spawn)
check(not respawned and tostring(respawn_error):match("never respawns") ~= nil, "persistent death tombstone refuses respawn")
os.exit(failures == 0 and 0 or 1)
