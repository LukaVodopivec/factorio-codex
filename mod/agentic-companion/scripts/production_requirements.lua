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
  if type(params.item) ~= "string" then error("production_requirements item must be an item or fluid name") end
  if not ((prototypes.item and prototypes.item[params.item]) or (prototypes.fluid and prototypes.fluid[params.item])) then
    error("no item or fluid called '" .. params.item .. "'")
  end
  local requested = tonumber(params.count)
  if not requested or requested <= 0 or requested % 1 ~= 0 then error("production_requirements count must be a positive integer") end
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
        item = product, required = 0, recipe = recipe.name, crafts = 0, output = output,
        category = recipe.category or "crafting", time = tonumber(recipe.energy) or 0,
        ingredients = ingredients_of(recipe), products = products,
      }
      nodes_by_item[product] = node
    end
    local old_crafts = node.crafts
    node.required = node.required + count
    node.crafts = math.ceil(node.required / output)
    local added_crafts = node.crafts - old_crafts
    if added_crafts == 0 then return end
    visiting[product] = true
    for ingredient, per_craft in pairs(node.ingredients) do require_item(ingredient, per_craft * added_crafts) end
    visiting[product] = nil
    for name, per_craft in pairs(node.products) do all_products[name] = (all_products[name] or 0) + per_craft * added_crafts end
  end

  require_item(params.item, requested)
  local nodes, total_time = {}, 0
  for _, node in pairs(nodes_by_item) do
    total_time = total_time + node.time * node.crafts
    nodes[#nodes + 1] = node
  end
  table.sort(nodes, function(a, b) return a.item == b.item and a.recipe < b.recipe or a.item < b.item end)
  return { item = params.item, count = requested, nodes = nodes, raw = raw, products = all_products, total_time = total_time }
end

return M
