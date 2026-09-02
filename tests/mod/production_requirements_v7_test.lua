local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local function recipe(name, ingredients, products, enabled, energy, category)
  return { name = name, ingredients = ingredients, products = products, enabled = enabled, energy = energy, category = category }
end
local force = { recipes = {
  gear = recipe("gear", { { name = "iron-plate", amount = 2 } }, { { name = "gear", amount = 1 } }, true, 0.5, "crafting"),
  widget_a = recipe("widget-a", { { name = "gear", amount = 1 } }, { { name = "widget", amount = 2 } }, true, 1, "crafting"),
  widget_b = recipe("widget-b", { { name = "copper-plate", amount = 1 } }, { { name = "widget", amount = 1 } }, true, 2, "advanced-crafting"),
  locked = recipe("locked", { { name = "stone", amount = 1 } }, { { name = "future", amount = 1 } }, false, 1, "crafting"),
} }
package.loaded["scripts.companion"] = { require_companion = function() return { force = force } end }
_G.prototypes = { item = { widget = {}, gear = {}, ["iron-plate"] = {}, ["copper-plate"] = {}, future = {}, stone = {} }, fluid = {} }
local production = require("scripts.production_requirements")
local ambiguous, ambiguity = pcall(production.production_requirements, { targets = { widget = 3 } })
check(not ambiguous and tostring(ambiguity):match("ambiguous production route") ~= nil, "multiple unlocked producers require an explicit recipe choice")
local result = production.production_requirements({ targets = { widget = 3, gear = 1 }, recipe_choices = { widget = "widget-a" } })
check(#result.nodes == 2 and result.nodes[1].item == "gear" and result.nodes[2].item == "widget", "DAG nodes are deterministically sorted")
check(result.nodes[1].crafts == 3 and result.nodes[2].crafts == 2 and result.raw["iron-plate"] == 6
  and result.products.widget == 4 and result.total_time == 3.5 and result.targets.gear == 1,
  "multiple targets aggregate craft counts, raw inputs, products, categories and time")
local progressed, progress_error = pcall(production.production_requirements, { targets = { future = 1 } })
check(not progressed and tostring(progress_error):match("no progression route") ~= nil, "locked-only products refuse a nonexistent progression route")
os.exit(failures == 0 and 0 or 1)
