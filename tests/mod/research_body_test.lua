local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local body
package.loaded["scripts.companion"] = {
  require_companion = function()
    if not (body and body.valid) then error("companion 'Codex' does not exist — call connect_status first") end
    return body
  end,
}

local queued
local technology = { name = "automation", researched = false, prerequisites = {}, prototype = {} }
local codex_force = {
  technologies = { automation = technology },
  research_queue = {},
  add_research = function(name) queued = name; return true end,
}
_G.game = { forces = { player = {
  technologies = { automation = technology },
  research_queue = {},
  add_research = function() error("first-player/global force fallback was used") end,
} } }

local research = require("scripts.research")
body = nil
local pre_spawn, pre_spawn_error = pcall(research.start_research, { technology = "automation" })
check(not pre_spawn and tostring(pre_spawn_error):match("does not exist") ~= nil,
  "pre-spawn research requires the live Codex body")

body = { valid = false, force = codex_force }
local dead, dead_error = pcall(research.start_research, { technology = "automation" })
check(not dead and tostring(dead_error):match("does not exist") ~= nil,
  "dead-body research cannot fall back to the player force")

body = { valid = true, force = codex_force }
local live, result = pcall(research.start_research, { technology = "automation" })
check(live and result.queued == true and queued == "automation",
  "research queues only on the live Codex body's force")

os.exit(failures == 0 and 0 or 1)
