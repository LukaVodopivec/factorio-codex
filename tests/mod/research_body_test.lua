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
-- Research needs a connected body in any state (body_stub: a valid one).
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)

local queued
local add_research_calls = 0
local prerequisite = { name = "electronics", researched = true }
local technology = { name = "automation", researched = false, enabled = true,
  prerequisites = { electronics = prerequisite },
  prototype = { research_unit_ingredients = { { name = "logistic-science-pack", amount = 1 }, { name = "automation-science-pack", amount = 2 } }, research_unit_count = 10, research_unit_energy = 600,
    effects = { { type = "unlock-recipe", recipe = "long-handed-inserter" },
      { type = "laboratory-speed", modifier = 0.1, recipe = "ignored-ordinary" },
      { type = "unlock-recipe", recipe = "assembling-machine-1" } } } }
local completed = { name = "steam-power", researched = true, enabled = true, prerequisites = {}, prototype = {} }
local trigger_technology = { name = "trigger-alpha", researched = false, enabled = true,
  prerequisites = {}, prototype = { research_trigger = {
    type = "craft-item", item = { name = "iron-gear-wheel", quality = "rare", comparator = ">=" }, count = 12,
  }, effects = { { type = "unlock-recipe", recipe = "steel-plate" },
    { type = "laboratory-productivity", modifier = 0.1, recipe = "ignored-trigger" },
    { type = "unlock-recipe", recipe = "steel-chest" } } } }
local later_trigger = { name = "trigger-zeta", researched = false, enabled = true,
  prerequisites = {}, prototype = { research_trigger = {
    type = "scripted", trigger_description = { "", "Launch ", { "item-name.rocket-part" }, 1 },
  }, effects = {} } }
local platform_trigger = { name = "trigger-platform", researched = false, enabled = true,
  prerequisites = {}, prototype = { research_trigger = { type = "create-space-platform" }, effects = {} } }
local build_trigger = { name = "trigger-build", researched = false, enabled = true,
  prerequisites = {}, prototype = { research_trigger = {
    type = "build-entity", entity = { name = "lab", quality = "epic", comparator = "=" },
  }, effects = {} } }
local send_trigger = { name = "trigger-send", researched = false, enabled = true,
  prerequisites = {}, prototype = { research_trigger = {
    type = "send-item-to-orbit", item = { name = "space-science-pack", quality = "uncommon", comparator = ">" },
  }, effects = {} } }
local blocked = { name = "advanced", researched = false, enabled = true,
  prerequisites = { missing = { researched = false } }, prototype = { effects = {} } }
local direct_effect_reads = 0
local technology_api = { __index = function(_, key)
  if key == "effects" then
    direct_effect_reads = direct_effect_reads + 1
    error("LuaTechnology effects must be read from its prototype")
  end
end }
local codex_force = {
  name = "codex-force", technologies = { advanced = blocked, automation = technology,
    ["steam-power"] = completed, ["trigger-alpha"] = trigger_technology,
    ["trigger-build"] = build_trigger, ["trigger-platform"] = platform_trigger,
    ["trigger-send"] = send_trigger, ["trigger-zeta"] = later_trigger },
  recipes = { zeta = { enabled = true }, alpha = { enabled = true }, disabled = { enabled = false } },
  research_queue = {},
  current_research = technology, research_progress = 0.25,
  add_research = function(name) add_research_calls = add_research_calls + 1; queued = name; return true end,
}
for _, tech in pairs(codex_force.technologies) do setmetatable(tech, technology_api) end
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
  and tostring(trigger_error):match("quality >= rare")
  and tostring(trigger_error):match("progression_status"),
  "start_research refuses trigger technology with actionable evidence before queueing")
codex_force.research_queue = { technology, completed }
local progression = research.progression_status()
check(progression.force == "codex-force" and progression.current_research == "automation"
  and progression.research_progress == 0.25 and progression.researched[1] == "steam-power"
  and progression.available[1].name == "automation" and progression.available[2] == nil
  and progression.available[1].prerequisites[1] == "electronics"
  and progression.available[1].science_requirements[1].name == "automation-science-pack"
  and progression.available[1].science_requirements[2].name == "logistic-science-pack"
  and progression.available[1].science_count == 10 and progression.available[1].unit_time_s == 10
  and progression.available[1].science_time == nil
  and progression.available[1].unlocks[1] == "assembling-machine-1"
  and progression.available[1].unlocks[2] == "long-handed-inserter"
  and #progression.available[1].unlocks == 2
  and progression.research_queue[1] == "automation" and progression.research_queue[2] == "steam-power"
  and progression.trigger_unlocks[1].name == "trigger-alpha"
  and progression.trigger_unlocks[1].trigger.type == "craft-item"
  and progression.trigger_unlocks[1].trigger.item == "iron-gear-wheel"
  and progression.trigger_unlocks[1].trigger.item_filter.name == "iron-gear-wheel"
  and progression.trigger_unlocks[1].trigger.item_filter.quality == "rare"
  and progression.trigger_unlocks[1].trigger.item_filter.comparator == ">="
  and progression.trigger_unlocks[1].trigger.count == 12
  and progression.trigger_unlocks[1].unlocks[1] == "steel-chest"
  and progression.trigger_unlocks[1].unlocks[2] == "steel-plate"
  and #progression.trigger_unlocks[1].unlocks == 2
  and progression.trigger_unlocks[2].name == "trigger-build"
  and progression.trigger_unlocks[2].trigger.entity == "lab"
  and progression.trigger_unlocks[2].trigger.entity_filter.quality == "epic"
  and progression.trigger_unlocks[2].trigger.entity_filter.comparator == "="
  and progression.trigger_unlocks[3].name == "trigger-platform"
  and progression.trigger_unlocks[3].trigger.type == "create-space-platform"
  and type(progression.trigger_unlocks[3].unlocks) == "table"
  and next(progression.trigger_unlocks[3].unlocks) == nil
  and progression.trigger_unlocks[4].name == "trigger-send"
  and progression.trigger_unlocks[4].trigger.item == "space-science-pack"
  and progression.trigger_unlocks[4].trigger.item_filter.quality == "uncommon"
  and progression.trigger_unlocks[4].trigger.item_filter.comparator == ">"
  and progression.trigger_unlocks[5].name == "trigger-zeta"
  and progression.trigger_unlocks[5].trigger.type == "scripted"
  and progression.trigger_unlocks[5].trigger.trigger_description[2] == "Launch "
  and progression.trigger_unlocks[5].trigger.trigger_description[3][1] == "item-name.rocket-part"
  and progression.trigger_unlocks[5].trigger.trigger_description[4] == 1
  and progression.enabled_recipes[1] == "alpha" and progression.enabled_recipes[2] == "zeta",
  "progression_status separates deterministic queueable and trigger unlock records")
check(progression.trigger_unlocks[1].trigger.hint == "craft 12 of it"
  and progression.trigger_unlocks[2].trigger.hint == "build that entity (on a platform: as a ghost the hub builds)"
  and progression.trigger_unlocks[3].trigger.hint == "create_platform, then launch_rocket the starter pack"
  and progression.trigger_unlocks[4].trigger.hint == nil and progression.trigger_unlocks[5].trigger.hint == nil,
  "trigger records carry the tool hint for their type, and none for types without one")

technology.prototype.effects = {}
local empty_progression = research.progression_status()
check(type(empty_progression.available[1].unlocks) == "table"
  and next(empty_progression.available[1].unlocks) == nil,
  "ordinary technology with empty prototype effects preserves empty unlocks")
check(direct_effect_reads == 0, "progression never accesses unsupported direct technology.effects")

local trigger_prereq = { researched = false, prototype = { research_trigger = {
  type = "build-entity", entity = { name = "lab", quality = "epic", comparator = "=" },
} } }
local ordinary_prereq = { researched = false, prototype = {} }
local gated = { name = "gated", researched = false, enabled = true,
  prerequisites = { zeta = ordinary_prereq, alpha = trigger_prereq }, prototype = { effects = {} } }
codex_force.technologies.gated = setmetatable(gated, technology_api)
codex_force.add_research = function() add_research_calls = add_research_calls + 1; return false end
local gated_ok, gated_error = pcall(research.start_research, { technology = "gated" })
local gated_message = tostring(gated_error)
check(not gated_ok
  and gated_message:match("alpha requires in%-game trigger build%-entity lab %(quality = epic%) and cannot be queued")
  and gated_message:match("zeta must be researched first")
  and gated_message:find("alpha", 1, true) < gated_message:find("zeta", 1, true)
  and gated_message:match("progression_status and retry"),
  "failed queue reports sorted trigger and ordinary prerequisite actions with exact filter constraints")

-- A list of technologies is queued in its order.
local logistics = setmetatable({ name = "logistics", researched = false, enabled = true, prerequisites = {}, prototype = {} },
  technology_api)
local optics = setmetatable({ name = "optics", researched = false, enabled = true, prerequisites = {}, prototype = {} },
  technology_api)
codex_force.technologies.logistics, codex_force.technologies.optics = logistics, optics
codex_force.research_queue = {}
codex_force.add_research = function(name)
  codex_force.research_queue[#codex_force.research_queue + 1] = codex_force.technologies[name]
  return true
end
local listed = research.start_research({ technologies = { "optics", "logistics" } })
check(listed.queued and listed.technologies[1] == "optics" and listed.technologies[2] == "logistics"
  and listed.research_queue[1] == "optics" and listed.research_queue[2] == "logistics",
  "start_research queues a list of technologies in its order")
codex_force.research_queue = {}
local stopped_ok, stopped_error = pcall(research.start_research, { technologies = { "optics", "trigger-alpha", "logistics" } })
check(not stopped_ok and tostring(stopped_error):match("cannot queue trigger technology trigger%-alpha")
  and tostring(stopped_error):match("queued before it: optics") and #codex_force.research_queue == 1,
  "a list stops at the first technology the game refuses and says which were queued")
check(not pcall(research.start_research, { technologies = {} })
  and not pcall(research.start_research, { technology = "optics", technologies = { "optics" } }),
  "a list holds 1-7 names and replaces the single technology")

os.exit(failures == 0 and 0 or 1)
