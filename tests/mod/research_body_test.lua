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
local prerequisite = { name = "electronics", researched = true }
local technology = { name = "automation", researched = false, enabled = true,
  prerequisites = { electronics = prerequisite },
  prototype = { research_unit_ingredients = { { name = "logistic-science-pack", amount = 1 }, { name = "automation-science-pack", amount = 2 } }, research_unit_count = 10, research_unit_energy = 30 },
  effects = { { type = "unlock-recipe", recipe = "long-handed-inserter" }, { type = "unlock-recipe", recipe = "assembling-machine-1" } } }
local completed = { name = "steam-power", researched = true, enabled = true, prerequisites = {}, prototype = {} }
local blocked = { name = "advanced", researched = false, enabled = true,
  prerequisites = { missing = { researched = false } }, prototype = {}, effects = {} }
local codex_force = {
  name = "codex-force", technologies = { advanced = blocked, automation = technology, ["steam-power"] = completed },
  recipes = { zeta = { enabled = true }, alpha = { enabled = true }, disabled = { enabled = false } },
  research_queue = {},
  current_research = technology, research_progress = 0.25,
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
local progression = research.progression_status()
check(progression.force == "codex-force" and progression.current_research == "automation"
  and progression.research_progress == 0.25 and progression.researched[1] == "steam-power"
  and progression.available[1].name == "automation" and progression.available[2] == nil
  and progression.available[1].prerequisites[1] == "electronics"
  and progression.available[1].science_requirements[1].name == "automation-science-pack"
  and progression.available[1].science_requirements[2].name == "logistic-science-pack"
  and progression.available[1].science_count == 10 and progression.available[1].science_time == 30
  and progression.available[1].unlocks[1] == "assembling-machine-1"
  and progression.available[1].unlocks[2] == "long-handed-inserter"
  and progression.enabled_recipes[1] == "alpha" and progression.enabled_recipes[2] == "zeta",
  "progression_status returns deterministic live-force progression records")

os.exit(failures == 0 and 0 or 1)
