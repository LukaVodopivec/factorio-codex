-- Deterministic expansion of the live force's unlocked recipe graph.
local companion = require("scripts.companion")

local M = {}

local function amount(entry, recipe_name)
  if entry.probability ~= nil and entry.probability ~= 1 then
    error("recipe " .. recipe_name .. " has probabilistic products and cannot form a deterministic production plan")
  end
  if entry.amount ~= nil then return tonumber(entry.amount) end
  if entry.amount_min ~= nil and entry.amount_max ~= nil and entry.amount_min == entry.amount_max then return tonumber(entry.amount_min) end
  error("recipe " .. recipe_name .. " has a non-deterministic product amount")
end

local function products_of(recipe)
  local out = {}
  for _, product in ipairs(recipe.products or {}) do
    if product.name then out[product.name] = (out[product.name] or 0) + amount(product, recipe.name) end
  end
  return out
end

local function ingredients_of(recipe)
  local out = {}
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    if ingredient.name then out[ingredient.name] = (out[ingredient.name] or 0) + (tonumber(ingredient.amount) or 1) end
  end
  return out
end

local function candidate_recipes(force, product)
  local enabled, locked = {}, {}
  for name, recipe in pairs(force.recipes or {}) do
    local produces = false
    for _, candidate in ipairs(recipe.products or {}) do if candidate.name == product then produces = true end end
    if produces then
      local products = products_of(recipe)
      local target = recipe.enabled and enabled or locked
      target[#target + 1] = recipe
    end
  end
  table.sort(enabled, function(a, b) return a.name < b.name end)
  table.sort(locked, function(a, b) return a.name < b.name end)
  return enabled, locked
end

function M.production_requirements(params)
  local targets = params.targets
  if type(targets) ~= "table" then error("production_requirements targets must map item or fluid names to positive integer counts") end
  local target_names = {}
  for target, raw_count in pairs(targets) do
    if type(target) ~= "string" or not ((prototypes.item and prototypes.item[target]) or (prototypes.fluid and prototypes.fluid[target])) then
      error("no item or fluid called '" .. tostring(target) .. "'")
    end
    local count = tonumber(raw_count)
    if not count or count <= 0 or count % 1 ~= 0 then error("production_requirements target counts must be positive integers") end
    target_names[#target_names + 1] = target
  end
  if #target_names < 1 or #target_names > 16 then error("production_requirements targets must contain 1-16 entries") end
  table.sort(target_names)
  local choices = params.recipe_choices or {}
  if type(choices) ~= "table" then error("production_requirements recipe_choices must map product names to recipe names") end
  local force = companion.require_companion().force
  local nodes_by_item, raw, all_products, visiting = {}, {}, {}, {}

  local function choose(product)
    local enabled, locked = candidate_recipes(force, product)
    local choice = choices[product]
    if choice ~= nil then
      if type(choice) ~= "string" then error("recipe choice for " .. product .. " must be a recipe name") end
      for _, recipe in ipairs(enabled) do if recipe.name == choice then return recipe end end
      error("recipe choice " .. choice .. " is not an unlocked deterministic route for " .. product)
    end
    if #enabled > 1 then
      local names = {}; for _, recipe in ipairs(enabled) do names[#names + 1] = recipe.name end
      error("ambiguous production route for " .. product .. ": " .. table.concat(names, ", ") .. "; supply recipe_choices." .. product)
    end
    if #enabled == 1 then return enabled[1] end
    if #locked > 0 then error("no progression route for " .. product .. ": producing recipes are not unlocked") end
    return nil
  end

  local function require_item(product, count)
    if visiting[product] then error("no progression route for " .. product .. ": recipe cycle") end
    local recipe = choose(product)
    if not recipe then raw[product] = (raw[product] or 0) + count; return end
    local products = products_of(recipe)
    local output = products[product]
    local node = nodes_by_item[product]
    if node and node.recipe ~= recipe.name then error("inconsistent recipe choice for " .. product) end
    if not node then
      node = {
        item = product, required_units = 0, recipe = recipe.name, recipe_executions = 0,
        output_units_per_execution = output,
        category = recipe.category or "crafting",
        craft_time_seconds_per_execution = tonumber(recipe.energy) or 0,
        ingredient_units_per_execution = ingredients_of(recipe),
        product_units_per_execution = products,
      }
      nodes_by_item[product] = node
    end
    local old_crafts = node.recipe_executions
    node.required_units = node.required_units + count
    node.recipe_executions = math.ceil(node.required_units / output)
    local added_crafts = node.recipe_executions - old_crafts
    if added_crafts == 0 then return end
    visiting[product] = true
    for ingredient, per_craft in pairs(node.ingredient_units_per_execution) do require_item(ingredient, per_craft * added_crafts) end
    visiting[product] = nil
    for name, per_craft in pairs(node.product_units_per_execution) do all_products[name] = (all_products[name] or 0) + per_craft * added_crafts end
  end

  for _, target in ipairs(target_names) do require_item(target, tonumber(targets[target])) end
  local nodes, total_time = {}, 0
  for _, node in pairs(nodes_by_item) do
    total_time = total_time + node.craft_time_seconds_per_execution * node.recipe_executions
    nodes[#nodes + 1] = node
  end
  table.sort(nodes, function(a, b) return a.item == b.item and a.recipe < b.recipe or a.item < b.item end)
  return {
    units = {
      targets = "item_or_fluid_units", raw = "item_or_fluid_units",
      products = "item_or_fluid_units", time = "seconds_at_crafting_speed_1",
    },
    targets = targets, nodes = nodes, raw = raw, products = all_products,
    total_craft_time_seconds_at_speed_1 = total_time,
  }
end

return M
