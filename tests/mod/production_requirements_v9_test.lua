local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local function recipe(name, ingredients, products, enabled, energy, category)
  return { name = name, ingredients = ingredients, products = products, enabled = enabled, energy = energy, category = category }
end
local native_autoplace = { autoplace_settings = {
  entity = { settings = { deposit = {}, unmineable = {} } }, tile = { settings = { water = {}, grass = {} } },
} }
-- Roots come from the planet prototype's map generation (prototype data).
local character = { valid = true, surface = { name = "nauvis", planet = { name = "nauvis" } } }
local force = { recipes = {
  gear = recipe("gear", { { name = "iron-plate", amount = 2 } }, { { name = "gear", amount = 1 } }, true, 0.5, "crafting"),
  widget_a = recipe("widget-a", { { name = "gear", amount = 1 } }, { { name = "widget", amount = 2 } }, true, 1, "crafting"),
  widget_b = recipe("widget-b", { { name = "copper-plate", amount = 1 } }, { { name = "widget", amount = 1 } }, true, 2, "advanced-crafting"),
  locked = recipe("locked", { { name = "stone", amount = 1 } }, { { name = "future", amount = 1 } }, false, 1, "crafting"),
} }
character.force = force
character.get_main_inventory = function() return { get_item_count = function() return 0 end } end
package.loaded["scripts.companion"] = { require_companion = function() return character end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return character end)
_G.prototypes = { item = { widget = {}, gear = {}, ["iron-plate"] = {}, ["copper-plate"] = {}, future = {}, stone = {} }, fluid = {},
  space_location = { nauvis = { name = "nauvis", map_gen_settings = native_autoplace } }, space_connection = {} }
function prototypes.get_entity_filtered(filters)
  local wanted = {}
  for _, kind in ipairs(type(filters[1].type) == "table" and filters[1].type or { filters[1].type }) do wanted[kind] = true end
  local found = {}
  for name, proto in pairs(prototypes.entity or {}) do if wanted[proto.type] then found[name] = proto end end
  return mock.custom_table(found)
end
-- Roots are built once per load (prototypes never change at runtime): a
-- test that changes prototype data loads the module again.
local function reload()
  package.loaded["scripts.production_requirements"] = nil
  return require("scripts.production_requirements")
end
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
-- The force's recipes are read once a request, not once a product; the
-- job reads them a few work items per recipe over ticks, then expands on a
-- fresh tick, with the same answer.
do
  local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  local jobs = require("scripts.jobs")
  local params = { targets = { widget = 3, gear = 1 }, recipe_choices = { widget = "widget-a" } }
  local walks = 0
  setmetatable(force.recipes, { __pairs = function(t) walks = walks + 1; return next, t, nil end })
  local direct = production.production_requirements(params)
  check(walks == 1, "a request reads the force's recipes once, not once per product (" .. walks .. " reads)")
  local sliced, ticks = jobs.run_now(production.job, params, 1)
  check(ticks > 4 and same(sliced, direct),
    "the job reads its recipes over " .. ticks .. " ticks and answers like the direct read")
  local whole, whole_ticks = jobs.run_now(production.job, params)
  check(whole_ticks == 1 and same(whole, direct), "with a whole tick's budget the job answers in its first tick")
  setmetatable(force.recipes, nil)
  local refused, reason = pcall(production.job.start, { targets = { widget = 1 }, technology = "x" })
  check(not refused and tostring(reason):find("exactly one of", 1, true) ~= nil,
    "the job checks the request when it starts (the RPC's error)")
  local failed, why = pcall(jobs.run_now, production.job, { targets = { widget = 3 } })
  check(not failed and tostring(why):match("ambiguous production route") ~= nil, "an expansion error fails the job")
end
local progressed, progress_error = pcall(production.production_requirements, { targets = { future = 1 } })
check(not progressed and tostring(progress_error):match("no progression route") ~= nil, "locked-only products refuse a nonexistent progression route")

-- A refusal is deliberate (no source location): the RPC and job
-- dispatchers answer it without counting a handler fault.
local errors = require("scripts.errors")
local function rejects(params, message, name)
  local ok, reason = pcall(production.production_requirements, params)
  check(not ok and tostring(reason):find(message, 1, true) ~= nil and errors.deliberate(reason), name)
end
check(errors.deliberate(ambiguity), "an ambiguous route is a deliberate refusal, not a handler fault")
do
  local refused, reason = pcall(production.production_requirements, { targets = { widget = 0 } })
  check(not refused and errors.deliberate(reason), "request validation refuses deliberately")
end
for _, name in ipairs({ "iron-ore", "custom-mineral", "scrap", "cycle-a", "cycle-b" }) do prototypes.item[name] = {} end
prototypes.fluid["native-fluid"] = {}
prototypes.entity = {
  deposit = { type = "resource", mineable_properties = { minable = true, products = {
    { type = "item", name = "iron-ore", amount = 1 }, { type = "item", name = "custom-mineral", amount = 1 },
    { type = "fluid", name = "native-fluid", amount = 10 },
  } } },
  machine = { type = "assembling-machine", mineable_properties = { minable = true, products = { { name = "widget", amount = 1 } } } },
  wreck = { type = "simple-entity", mineable_properties = { minable = true, products = { { name = "widget", amount = 1 } } } },
  unmineable = { type = "resource", mineable_properties = { minable = false, products = { { name = "future", amount = 1 } } } },
}
production = reload()
force.recipes.smelting = recipe("smelting", { { name = "iron-ore", amount = 1 } }, { { name = "iron-plate", amount = 1 } }, true, 3.2, "smelting")
force.recipes.plate_recycling = recipe("plate-recycling", { { name = "scrap", amount = 1 } }, { { name = "iron-plate", amount = 1 } }, true)
force.recipes.ore_recycling = recipe("ore-recycling", { { name = "scrap", amount = 2 } }, { { name = "iron-ore", amount = 1 } }, true)
force.recipes.other_recycling = recipe("other-recycling", { { name = "scrap", amount = 3 } }, { { name = "iron-ore", amount = 1 } }, true)
force.recipes.custom_recycling = recipe("custom-recycling", {}, { { name = "custom-mineral", amount = 1 } }, false)
force.recipes.fluid_recycling = recipe("fluid-recycling", {}, { { name = "native-fluid", amount = 10 } }, true)
local smelted = production.production_requirements({ targets = { ["iron-plate"] = 7 }, recipe_choices = { ["iron-plate"] = "smelting" } })
check(#smelted.nodes == 1 and smelted.raw["iron-ore"] == 7 and smelted.products["iron-plate"] == 7,
  "explicit smelting terminates at native ore despite multiple recycling routes")
local mined = production.production_requirements({ targets = { ["iron-ore"] = 4, ["custom-mineral"] = 2, ["native-fluid"] = 15 } })
check(#mined.nodes == 0 and mined.raw["iron-ore"] == 4 and mined.raw["custom-mineral"] == 2 and mined.raw["native-fluid"] == 15,
  "generic item and fluid resource products are roots even with enabled or locked producers")
local recycled = production.production_requirements({ targets = { ["iron-ore"] = 3 }, recipe_choices = { ["iron-ore"] = "ore-recycling" } })
check(#recycled.nodes == 1 and recycled.raw.scrap == 6, "explicit native-resource recycling remains selectable")
rejects({ targets = { ["iron-ore"] = 1 }, recipe_choices = { ["iron-ore"] = "smelting" } }, "not a permitted", "invalid native-resource route remains an error")
rejects({ targets = { ["iron-ore"] = 1 }, recipe_choices = { ["iron-ore"] = 42 } }, "must be a recipe name", "native-resource choice type is validated")
rejects({ targets = { ["custom-mineral"] = 1 }, recipe_choices = { ["custom-mineral"] = "custom-recycling" } }, "not a permitted", "explicit locked resource route remains an error")
rejects({ targets = { widget = 1 } }, "ambiguous production route", "dismantled machines and wreckage do not make manufactured products raw roots")
rejects({ targets = { future = 1 } }, "no progression route", "unmineable resources do not bypass locked-only refusal")
force.recipes.cycle_a = recipe("cycle-a", { { name = "cycle-b", amount = 1 } }, { { name = "cycle-a", amount = 1 } }, true)
force.recipes.cycle_b = recipe("cycle-b", { { name = "cycle-a", amount = 1 } }, { { name = "cycle-b", amount = 1 } }, true)
rejects({ targets = { ["cycle-a"] = 1 } }, "recipe cycle", "manufactured recipe cycles remain errors")
force.recipes.other_recycling.products[1].probability = 0.5
rejects({ targets = { ["iron-ore"] = 1 }, recipe_choices = { ["iron-ore"] = "other-recycling" } }, "probabilistic product", "explicit resource routes retain nondeterministic-product refusal")

-- Factorio 2.0 quality recycling recipes are enabled from tick 0 but hidden; they are never routes.
for _, name in ipairs({ "steel", "steel-raw" }) do prototypes.item[name] = {} end
force.recipes.steel = recipe("steel", { { name = "steel-raw", amount = 5 } }, { { name = "steel", amount = 1 } }, true, 16, "smelting")
force.recipes.steel_recycling = recipe("steel-recycling", { { name = "steel", amount = 1 } }, { { name = "steel", amount = 1, probability = 0.25 } }, true)
force.recipes.steel_recycling.hidden = true
force.recipes.raw_steel_recycling = recipe("steel-raw-recycling", { { name = "widget", amount = 1 } }, { { name = "steel-raw", amount = 1 } }, true)
force.recipes.raw_steel_recycling.hidden = true
local unhidden = production.production_requirements({ targets = { steel = 2 } })
check(#unhidden.nodes == 1 and unhidden.nodes[1].recipe == "steel" and unhidden.raw["steel-raw"] == 10,
  "hidden enabled recycling recipes are neither candidates nor locked producers")
rejects({ targets = { steel = 1 }, recipe_choices = { steel = "steel-recycling" } }, "not a permitted", "explicitly choosing a hidden recipe is refused")
-- Offshore-pump tile fluids are acquisition roots even when a locked recipe can also produce them.
prototypes.fluid.water = {}
prototypes.tile = { water = { name = "water", fluid = { name = "water" } }, grass = { name = "grass" } }
production = reload()
force.recipes.ice_melting = recipe("ice-melting", { { name = "custom-mineral", amount = 1 } }, { { name = "water", amount = 20 } }, false)
local pumped = production.production_requirements({ targets = { water = 100 } })
check(#pumped.nodes == 0 and pumped.raw.water == 100, "offshore tile fluid is a raw root despite a locked producer")
force.recipes.ice_melting = nil

-- Roots follow the companion planet's own autoplace settings: another planet's
-- geyser fluid or ocean fluid keeps its ordinary recipe or ambiguity handling.
for _, name in ipairs({ "acid", "sulfur", "heavy", "coal-feed", "oil-feed" }) do prototypes.fluid[name] = {}; prototypes.item[name] = {} end
prototypes.entity.geyser = { type = "resource", mineable_properties = { minable = true, products = { { type = "fluid", name = "acid", amount = 10 } } } }
prototypes.tile.ocean = { name = "ocean", fluid = { name = "heavy" } }
force.recipes.acid = recipe("acid", { { name = "sulfur", amount = 5 } }, { { name = "acid", amount = 50, type = "fluid" } }, true, 1, "chemistry")
force.recipes.heavy_a = recipe("heavy-a", { { name = "oil-feed", amount = 1 } }, { { name = "heavy", amount = 1, type = "fluid" } }, true, 1, "oil-processing")
force.recipes.heavy_b = recipe("heavy-b", { { name = "coal-feed", amount = 1 } }, { { name = "heavy", amount = 1, type = "fluid" } }, true, 1, "oil-processing")
prototypes.space_location.nauvis.map_gen_settings = { autoplace_settings = {
  entity = { settings = { deposit = {} } }, tile = { settings = { water = {}, grass = {} } },
} }
production = reload()
local native = production.production_requirements({ targets = { acid = 50, ["iron-ore"] = 2, water = 10 } })
check(#native.nodes == 1 and native.nodes[1].recipe == "acid" and native.raw.sulfur == 5 and native.raw.acid == nil
  and native.raw["iron-ore"] == 2 and native.raw.water == 10,
  "a resource not autoplaced on the companion's planet is expanded through its recipe; native roots stay raw")
rejects({ targets = { heavy = 1 } }, "ambiguous production route", "a tile fluid from another surface keeps ambiguity refusal")
prototypes.space_location.nauvis.map_gen_settings = nil
production = reload()
local unreadable = production.production_requirements({ targets = { acid = 10 } })
check(unreadable.raw.acid == nil and unreadable.raw.sulfur == 5 and unreadable.nodes[1].recipe == "acid",
  "a planet without map generation gives no raw-root shortcut")
prototypes.space_location.nauvis.map_gen_settings = native_autoplace
production = reload()
force.recipes.acid, force.recipes.heavy_a, force.recipes.heavy_b = nil, nil, nil
prototypes.entity.geyser, prototypes.tile.ocean = nil, nil

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
    prototype = { effects = { { type = "unlock-recipe", recipe = pack } }, research_unit_count = count,
      research_unit_energy = 1800, research_unit_ingredients = { { name = pack, amount = 1 } } } }
  force.technologies[technology.name] = technology
  prerequisites[technology.name] = technology
end
force.technologies["edge-closure"] = { name = "edge-closure", researched = false, prerequisites = prerequisites,
  prototype = { effects = { { type = "unlock-space-location", space_location = "solar-system-edge" } }, research_unit_count = 0, research_unit_ingredients = {} } }
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

-- Lab time: remaining units x unit time per missing lab technology (the
-- current one's progress credited), summed at speed 1 and over the labs'
-- summed progress rate (speed and productivity); arithmetic only.
do
  local registry = require("scripts.registry")
  local real_labs = registry.labs
  local pre = { name = "lab-pre", researched = false, prerequisites = {},
    prototype = { effects = {}, research_unit_count = 100, research_unit_energy = 1800,
      research_unit_ingredients = { { name = "automation-science-pack", amount = 1 } } } }
  local target = { name = "lab-target", researched = false, prerequisites = { ["lab-pre"] = pre },
    prototype = { effects = {}, research_unit_count = 10, research_unit_energy = 600,
      research_unit_ingredients = { { name = "automation-science-pack", amount = 1 } } } }
  force.technologies["lab-pre"], force.technologies["lab-target"] = pre, target
  force.current_research, force.research_progress = pre, 0.5
  registry.labs = function() return { count = 2, speed = 2, pack_rate = 2, progress_rate = 2.5 } end
  local timed = production.production_requirements({ technology = "lab-target" })
  local estimate = timed.time_estimate
  local rows = {}
  for _, row in ipairs(timed.missing_technologies) do rows[row.name] = row end
  local allowed = { complete = true, bottleneck_seconds = true, basis = true, lab_seconds_at_speed_1 = true,
    lab_seconds = true }
  local facts_only = true
  for key, value in pairs(estimate) do
    if not allowed[key] or (type(value) == "string" and key ~= "basis") then facts_only = false end
  end
  check(rows["lab-pre"].unit_time_s == 30 and rows["lab-target"].unit_time_s == 10
    and estimate.lab_seconds_at_speed_1 == 1600 and estimate.lab_seconds == 640 and facts_only,
    "a closure's time_estimate adds lab seconds at speed 1 (1600) and at the labs' progress rate (640), facts only")
  registry.labs = function() return { count = 0, speed = 0, pack_rate = 0, progress_rate = 0 } end
  local no_labs = production.production_requirements({ technology = "lab-target" }).time_estimate
  check(no_labs.lab_seconds_at_speed_1 == 1600 and no_labs.lab_seconds == nil,
    "without labs a closure gives lab seconds at speed 1 only")
  pre.prototype.research_unit_energy = nil
  local unknown = production.production_requirements({ technology = "lab-target" })
  check(unknown.time_estimate.lab_seconds_at_speed_1 == nil and unknown.partial == true
    and unknown.variable_operating_requirements[#unknown.variable_operating_requirements].kind == "technology_unit_time_unavailable",
    "a technology with no unit time leaves the lab total out and names it")
  registry.labs = real_labs
  force.technologies["lab-pre"], force.technologies["lab-target"] = nil, nil
  force.current_research, force.research_progress = nil, 0
end

force.technologies["trigger-path"] = { name = "trigger-path", researched = false, prerequisites = {},
  prototype = { effects = {}, research_trigger = { type = "craft-item", item = "gear", count = 3 } } }
local triggered = production.production_requirements({ technology = "trigger-path" })
check(triggered.partial == true and #triggered.trigger_conditions == 1
  and triggered.trigger_conditions[1].action:match("craft%-item 3 gear") ~= nil,
  "trigger technologies remain explicit variable conditions rather than fabricated science")
force.technologies["formula-path"] = { name = "formula-path", researched = false, prerequisites = {},
  prototype = { effects = {}, research_unit_count_formula = "2^L", research_unit_ingredients = { { name = "automation-science-pack", amount = 1 } } } }
local formula = production.production_requirements({ technology = "formula-path" })
check(formula.partial == true and formula.variable_operating_requirements[1].kind == "technology_research_cost_unavailable",
  "non-fixed research formulas remain explicit rather than falsely exact")

-- LuaTechnology has no effects field: unlock modifiers live on its prototype.
force.technologies["mineral-science"] = { name = "mineral-science", researched = false, prerequisites = {}, prototype = {
  effects = { { type = "unlock-recipe", recipe = "mineral-pack" }, { type = "unlock-space-location", space_location = "mineral-world" } },
  research_unit_count = 5, research_unit_energy = 600, research_unit_ingredients = { { name = "mineral-pack", amount = 2 } },
} }
prototypes.space_location["mineral-world"] = { name = "mineral-world" }
force.recipes["mineral-pack"] = recipe("mineral-pack", { { name = "iron-ore", amount = 2 } }, { { name = "mineral-pack", amount = 1 } }, false, 1)
for _, technology in pairs(force.technologies) do
  setmetatable(technology, { __index = function(_, key) if key == "effects" then error("LuaTechnology has no effects field") end end })
end
for _, params in ipairs({ { technology = "mineral-science" }, { location = "mineral-world" } }) do
  local mineral = production.production_requirements(params)
  check(mineral.partial == false and #mineral.ambiguities == 0 and mineral.remaining_science_packs["mineral-pack"] == 10
    and #mineral.deterministic_requirements.nodes == 1 and mineral.deterministic_requirements.raw["iron-ore"] == 20,
    params.technology and "technology closure permits prototype-unlocked recipe and terminates at mined ore"
      or "location closure uses prototype string unlock and has no resource recycling ambiguity")
end
rejects({ location = "unknown-world" }, "unknown space location", "unknown locations remain explicit errors")
prototypes.space_location["no-unlock"] = {}
rejects({ location = "no-unlock" }, "no installed technology unlocks", "installed locations without unlocks remain explicit errors")
force.technologies["second-unlock"] = { name = "second-unlock", prototype = {
  effects = { { type = "unlock-space-location", space_location = "mineral-world" } },
} }
local multiple = production.production_requirements({ location = "mineral-world" })
check(multiple.partial == true and multiple.ambiguities[1].kind == "location_unlock_technology"
  and multiple.ambiguities[1].candidates[1] == "mineral-science" and multiple.ambiguities[1].candidates[2] == "second-unlock"
  and next(multiple.remaining_science_packs) == nil and #multiple.missing_technologies == 0,
  "multiple location unlocks require a choice without fabricated science or technologies")
-- The resource catalogue is built a step per work item: the first request
-- after a cold cache spreads it over ticks, and a peer whose cache is warm
-- charges the same work tick by tick (a job's progress is game state on
-- every peer) and answers the same.
do
  local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  local jobs = require("scripts.jobs")
  local entity = native_autoplace.autoplace_settings.entity
  local saved = entity.settings
  local many = {}
  for name in pairs(saved) do many[name] = {} end
  for i = 1, 400 do many["autoplaced-" .. i] = {} end
  entity.settings = many
  production = reload()
  local params = { targets = { ["iron-plate"] = 7 }, recipe_choices = { ["iron-plate"] = "smelting" } }
  local spent = {}
  local job = { start = production.job.start, step = function(S, budget)
    local before = budget.left
    local result = production.job.step(S, budget)
    spent[#spent + 1] = before - budget.left
    return result
  end }
  local cold, cold_ticks = jobs.run_now(job, params)
  local cold_spent = spent
  spent = {}
  local warm, warm_ticks = jobs.run_now(job, params)
  local most = 0
  for _, n in ipairs(cold_spent) do most = math.max(most, n) end
  check(cold ~= nil and cold.raw["iron-ore"] == 7 and cold_ticks > 1 and most <= jobs.WORK_PER_TICK + production.ROOT_ENTRY_WORK * 402,
    "the first request after a cold cache builds the catalogue over " .. cold_ticks .. " ticks")
  check(warm_ticks == cold_ticks and same(spent, cold_spent) and same(warm, cold),
    "a warm catalogue is charged the same work each tick and answers the same")
  -- A peer that loaded mid-build catches up on its next step, charged alike.
  production = reload()
  local S = production.job.start(params)
  local first
  repeat first = production.job.step(S, { left = 20 }) until first ~= nil or (S.roots_step or 1) > 1
  local mid, at = first == nil and not S.roots_done, S.roots_step
  production = reload()
  local resumed = jobs.run_now({ start = function() return S end, step = production.job.step }, params)
  check(mid and same(resumed, cold), "a catalogue build interrupted by a load (at step " .. tostring(at)
    .. ") finishes with the same answer")
  entity.settings = saved
  production = reload()
end
os.exit(failures == 0 and 0 or 1)
