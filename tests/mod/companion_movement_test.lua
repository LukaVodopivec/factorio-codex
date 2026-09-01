local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
_G.storage = { companions = {} }; _G.settings = nil
local companion = require("scripts.companion")
check(companion.DEFAULT == "Codex", "sole body has fixed Codex identity")
check(companion.movement_speed_multiplier() == 1.6, "configured movement remains physical")
local body = { valid = true }; storage.companions = { Codex = { entity = body } }; companion.apply_movement_speed()
check(math.abs(body.character_running_speed_modifier - 0.6) < 0.000001, "movement modifier applies to Codex")
storage.companions.Codex.entity = { valid = false }
check(companion.get() == nil and companion.record() ~= nil, "death persists without auto-respawn")
local respawned, respawn_error = pcall(companion.spawn, {})
check(not respawned and tostring(respawn_error):match("never respawns") ~= nil, "persistent death tombstone refuses respawn")
os.exit(failures == 0 and 0 or 1)
