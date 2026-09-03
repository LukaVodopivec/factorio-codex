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
local add_research_calls = 0
local prerequisite = { name = "electronics", researched = true }
local technology = { name = "automation", researched = false, enabled = true,
  prerequisites = { electronics = prerequisite },
  prototype = { research_unit_ingredients = { { name = "logistic-science-pack", amount = 1 }, { name = "automation-science-pack", amount = 2 } }, research_unit_count = 10, research_unit_energy = 30 },
  effects = { { type = "unlock-recipe", recipe = "long-handed-inserter" }, { type = "unlock-recipe", recipe = "assembling-machine-1" } } }
local completed = { name = "steam-power", researched = true, enabled = true, prerequisites = {}, prototype = {} }
local trigger_technology = { name = "trigger-alpha", researched = false, enabled = true,
  prerequisites = {}, prototype = { research_trigger = {
    type = "craft-item", item = { name = "iron-gear-wheel" }, count = 12,
  } }, effects = {} }
local later_trigger = { name = "trigger-zeta", researched = false, enabled = true,
  prerequisites = {}, prototype = { research_trigger = { type = "scripted" } }, effects = {} }
local blocked = { name = "advanced", researched = false, enabled = true,
  prerequisites = { missing = { researched = false } }, prototype = {}, effects = {} }
local codex_force = {
  name = "codex-force", technologies = { advanced = blocked, automation = technology,
    ["steam-power"] = completed, ["trigger-alpha"] = trigger_technology,
    ["trigger-zeta"] = later_trigger },
  recipes = { zeta = { enabled = true }, alpha = { enabled = true }, disabled = { enabled = false } },
  research_queue = {},
  current_research = technology, research_progress = 0.25,
  add_research = function(name) add_research_calls = add_research_calls + 1; queued = name; return true end,
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
local before_trigger = add_research_calls
local trigger_ok, trigger_error = pcall(research.start_research, { technology = "trigger-alpha" })
check(not trigger_ok and add_research_calls == before_trigger
  and tostring(trigger_error):match("cannot queue trigger technology trigger%-alpha")
  and tostring(trigger_error):match("craft%-item 12 iron%-gear%-wheel")
  and tostring(trigger_error):match("progression_status"),
  "start_research refuses trigger technology with actionable evidence before queueing")
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
  and progression.trigger_unlocks[1].name == "trigger-alpha"
  and progression.trigger_unlocks[1].trigger.type == "craft-item"
  and progression.trigger_unlocks[1].trigger.item == "iron-gear-wheel"
  and progression.trigger_unlocks[1].trigger.count == 12
  and progression.trigger_unlocks[2].name == "trigger-zeta"
  and progression.trigger_unlocks[2].trigger.type == "scripted"
  and progression.enabled_recipes[1] == "alpha" and progression.enabled_recipes[2] == "zeta",
  "progression_status separates deterministic queueable and trigger unlock records")

local trigger_prereq = { researched = false, prototype = { research_trigger = {
  type = "build-entity", entity = { name = "lab" },
} } }
local ordinary_prereq = { researched = false, prototype = {} }
local gated = { name = "gated", researched = false, enabled = true,
  prerequisites = { zeta = ordinary_prereq, alpha = trigger_prereq }, prototype = {}, effects = {} }
codex_force.technologies.gated = gated
codex_force.add_research = function() add_research_calls = add_research_calls + 1; return false end
local gated_ok, gated_error = pcall(research.start_research, { technology = "gated" })
local gated_message = tostring(gated_error)
check(not gated_ok
  and gated_message:match("alpha requires in%-game trigger build%-entity lab and cannot be queued")
  and gated_message:match("zeta must be researched first")
  and gated_message:find("alpha", 1, true) < gated_message:find("zeta", 1, true)
  and gated_message:match("progression_status and retry"),
  "failed queue reports sorted trigger and ordinary prerequisite actions")

os.exit(failures == 0 and 0 or 1)
