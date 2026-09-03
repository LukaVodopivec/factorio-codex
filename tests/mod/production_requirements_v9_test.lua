local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local function recipe(name, ingredients, products, enabled, energy, category)
  return { name = name, ingredients = ingredients, products = products, enabled = enabled, energy = energy, category = category }
end
local character = { surface = { name = "nauvis" } }
local force = { recipes = {
  gear = recipe("gear", { { name = "iron-plate", amount = 2 } }, { { name = "gear", amount = 1 } }, true, 0.5, "crafting"),
  widget_a = recipe("widget-a", { { name = "gear", amount = 1 } }, { { name = "widget", amount = 2 } }, true, 1, "crafting"),
  widget_b = recipe("widget-b", { { name = "copper-plate", amount = 1 } }, { { name = "widget", amount = 1 } }, true, 2, "advanced-crafting"),
  locked = recipe("locked", { { name = "stone", amount = 1 } }, { { name = "future", amount = 1 } }, false, 1, "crafting"),
} }
character.force = force
character.get_main_inventory = function() return { get_item_count = function() return 0 end } end
package.loaded["scripts.companion"] = { require_companion = function() return character end }
_G.prototypes = { item = { widget = {}, gear = {}, ["iron-plate"] = {}, ["copper-plate"] = {}, future = {}, stone = {} }, fluid = {}, space_location = {} }
_G.game = { tick = 42 }
_G.defines = { flow_precision_index = { five_seconds = 1, one_minute = 2, ten_minutes = 3, one_hour = 4 } }
local production = require("scripts.production_requirements")
local ambiguous, ambiguity = pcall(production.production_requirements, { targets = { widget = 3 } })
check(not ambiguous and tostring(ambiguity):match("ambiguous production route") ~= nil, "multiple unlocked producers require an explicit recipe choice")
local result = production.production_requirements({ targets = { widget = 3, gear = 1 }, recipe_choices = { widget = "widget-a" } })
check(#result.nodes == 2 and result.nodes[1].item == "gear" and result.nodes[2].item == "widget", "DAG nodes are deterministically sorted")
check(result.nodes[1].recipe_executions == 3 and result.nodes[2].recipe_executions == 2
  and result.nodes[1].required_units == 3 and result.nodes[2].output_units_per_execution == 2
  and result.nodes[1].ingredient_units_per_execution["iron-plate"] == 2
  and result.raw["iron-plate"] == 6 and result.products.widget == 4
  and result.total_craft_time_seconds_at_speed_1 == 3.5 and result.targets.gear == 1
  and result.units.targets == "item_or_fluid_units" and result.units.time == "seconds_at_crafting_speed_1",
  "multiple targets aggregate craft counts, raw inputs, products, categories and time")
local progressed, progress_error = pcall(production.production_requirements, { targets = { future = 1 } })
check(not progressed and tostring(progress_error):match("no progression route") ~= nil, "locked-only products refuse a nonexistent progression route")

local science_totals = {
  ["automation-science-pack"] = 21905,
  ["logistic-science-pack"] = 21705,
  ["chemical-science-pack"] = 18950,
  ["military-science-pack"] = 2420,
  ["space-science-pack"] = 16000,
  ["production-science-pack"] = 9500,
  ["utility-science-pack"] = 9500,
  ["metallurgic-science-pack"] = 8000,
  ["agricultural-science-pack"] = 12000,
  ["electromagnetic-science-pack"] = 7500,
  ["cryogenic-science-pack"] = 4500,
}
force.technologies = {}
local prerequisites = {}
for pack, count in pairs(science_totals) do
  prototypes.item[pack] = {}
  prototypes.item[pack .. "-raw"] = {}
  force.recipes[pack] = recipe(pack, { { name = pack .. "-raw", amount = 1 } }, { { name = pack, amount = 1 } }, false, 1, "crafting")
  local technology = { name = pack .. "-closure", researched = false, prerequisites = {},
    effects = { { type = "unlock-recipe", recipe = pack } },
    prototype = { research_unit_count = count, research_unit_ingredients = { { name = pack, amount = 1 } } } }
  force.technologies[technology.name] = technology
  prerequisites[technology.name] = technology
end
force.technologies["edge-closure"] = { name = "edge-closure", researched = false, prerequisites = prerequisites,
  effects = { { type = "unlock-space-location", space_location = { name = "solar-system-edge" } } },
  prototype = { research_unit_count = 0, research_unit_ingredients = {} } }
prototypes.space_location["solar-system-edge"] = { name = "solar-system-edge" }
force.current_research = nil
force.research_progress = 0
force.get_item_production_statistics = function()
  return { get_flow_count = function() return 60 end }
end

local closure = production.production_requirements({ location = "solar-system-edge", flow_precision = "one_minute" })
local total = 0
for pack, expected in pairs(science_totals) do
  check(closure.remaining_science_packs[pack] == expected, "Solar System Edge closure includes exact " .. pack .. " fixture total")
  total = total + closure.remaining_science_packs[pack]
end
check(total == 131980 and #closure.missing_technologies == 12,
  "Factorio 2.0.77 Solar System Edge closure fixture preserves all listed per-pack totals")
check(closure.target_kind == "location" and closure.target_technology == "edge-closure"
  and closure.stock_credit.scope == "character_main_inventory"
  and closure.stock_credit.remote_inventories_credited == false,
  "location closure uses current-force technology and never credits exact remote inventories")
check(#closure.deterministic_requirements.nodes == 11 and #closure.force_flows == 11
  and closure.time_estimate.complete == true and closure.time_estimate.bottleneck_seconds ~= nil,
  "locked closure recipes expand deterministically and measured rates produce an explicit estimate")
force.technologies["automation-science-pack-closure"].researched = true
local progressed_closure = production.production_requirements({ location = "solar-system-edge" })
check(progressed_closure.remaining_science_packs["automation-science-pack"] == nil
  and #progressed_closure.missing_technologies == 11,
  "current-force researched prerequisites are credited without inspecting remote stock")
force.technologies["automation-science-pack-closure"].researched = false

force.technologies["trigger-path"] = { name = "trigger-path", researched = false, prerequisites = {}, effects = {},
  prototype = { research_trigger = { type = "craft-item", item = "gear", count = 3 } } }
local triggered = production.production_requirements({ technology = "trigger-path" })
check(triggered.partial == true and #triggered.trigger_conditions == 1
  and triggered.trigger_conditions[1].action:match("craft%-item 3 gear") ~= nil,
  "trigger technologies remain explicit variable conditions rather than fabricated science")
force.technologies["formula-path"] = { name = "formula-path", researched = false, prerequisites = {}, effects = {},
  prototype = { research_unit_count_formula = "2^L", research_unit_ingredients = { { name = "automation-science-pack", amount = 1 } } } }
local formula = production.production_requirements({ technology = "formula-path" })
check(formula.partial == true and formula.variable_operating_requirements[1].kind == "technology_research_cost_unavailable",
  "non-fixed research formulas remain explicit rather than falsely exact")
os.exit(failures == 0 and 0 or 1)
