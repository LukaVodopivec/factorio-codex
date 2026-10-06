-- Deterministic item/fluid expansion plus current-force technology/location closure.
--
-- Resource roots per planet (prototype data only, never charted or hidden
-- map state; built once per load into a module-local table, since
-- prototypes change only with a configuration change): for every space
-- location with map generation, the resources, rocks, trees, plants and
-- fish its autoplace settings (or an autoplace control it has) place, and
-- the liquids of its tiles; for every location and space connection, the
-- asteroid chunks that spawn there. Each root says how it is gathered:
-- drill, big_drill (a resource category only the big mining drill mines),
-- pump (a fluid resource), offshore (a liquid tile), hand (rocks, trees,
-- plants, fish), tower (plants) or asteroid.
-- The expansion plans for one place: `planet`, else the body's planet (or
-- its platform's location). Products rooted there are raw; others expand
-- through their recipes; a raw entry that cannot be made there lists in
-- `roots` where it can be gathered, and in `unobtainable` when nowhere.
-- With `planet` given, recipes whose surface conditions that planet breaks
-- are not routes. `surface_limited` names the recipes used whose surface
-- conditions limit where they run, with the planets that allow them.
local companion = require("scripts.companion")
local research = require("scripts.research")

local M = {}
local FLOW_PRECISIONS = {
  five_seconds = { ticks = 300, units = "units_per_minute" },
  one_minute = { ticks = 3600, units = "units_per_minute" },
  ten_minutes = { ticks = 36000, units = "units_per_minute" },
  one_hour = { ticks = 216000, units = "units_per_minute" },
}

local function sorted_keys(map)
  local keys = {}; for key in pairs(map or {}) do keys[#keys + 1] = key end
  table.sort(keys); return keys
end

local function deterministic_amount(entry, recipe_name)
  if entry.probability ~= nil and tonumber(entry.probability) ~= 1 then
    return nil, "recipe " .. recipe_name .. " has a probabilistic product"
  end
  if entry.amount ~= nil then return tonumber(entry.amount) end
  if entry.amount_min ~= nil and entry.amount_max ~= nil and entry.amount_min == entry.amount_max then
    return tonumber(entry.amount_min)
  end
  return nil, "recipe " .. recipe_name .. " has a non-deterministic product amount"
end

local function products_of(recipe)
  local out = {}
  for _, product in ipairs(recipe.products or {}) do
    if product.name then
      local amount, reason = deterministic_amount(product, recipe.name)
      if not amount then return nil, reason end
      out[product.name] = (out[product.name] or 0) + amount
    end
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

-- ------------------------------------------------------------------ roots

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

local function each_key(map)
  local keys = {}
  for key in pairs(map or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local HAND_TYPES = { tree = true, plant = true, ["simple-entity"] = true, fish = true }

-- {by_product = {[name] = {{planet, via}}}, at = {[location] = {[name] =
-- true}}, properties = {[location] = {[property] = value}}, planets = the
-- locations with map generation, sorted}.
local roots_cache
local function roots()
  if roots_cache then return roots_cache end
  local R = { by_product = {}, at = {}, properties = {}, planets = {} }
  local seen = {}
  local function add(location, product, via)
    if type(product) ~= "string" then return end
    local key = location .. "\0" .. product .. "\0" .. via
    if seen[key] then return end
    seen[key] = true
    local list = R.by_product[product] or {}
    R.by_product[product] = list
    list[#list + 1] = { planet = location, via = via }
    R.at[location] = R.at[location] or {}
    R.at[location][product] = true
  end
  -- Resource categories no drill but the big mining drill mines.
  local drills_of = {}
  for name, drill in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "mining-drill" } })) do
    for category in pairs(read(function() return drill.resource_categories end) or {}) do
      drills_of[category] = drills_of[category] or {}
      drills_of[category][name] = true
    end
  end
  local function big_only(category)
    local drills = category and drills_of[category]
    if not drills or not drills["big-mining-drill"] then return false end
    for name in pairs(drills) do if name ~= "big-mining-drill" then return false end end
    return true
  end
  local function entity_roots(location, entity)
    local kind = read(function() return entity.type end)
    local mining = read(function() return entity.mineable_properties end)
    if not (mining and mining.minable) then return end
    if kind == "resource" then
      for _, product in pairs(mining.products or {}) do
        local via = product.type == "fluid" and "pump"
          or big_only(read(function() return entity.resource_category end)) and "big_drill" or "drill"
        add(location, product.name, via)
      end
    elseif HAND_TYPES[kind] then
      for _, product in pairs(mining.products or {}) do
        add(location, product.name, "hand")
        if kind == "plant" then add(location, product.name, "tower") end
      end
    end
  end
  -- Entities a control places (trees, plants), once.
  local controlled = {}
  for name, entity in pairs(prototypes.get_entity_filtered({ { filter = "type", type = each_key(HAND_TYPES) } })) do
    local control = read(function() return entity.autoplace_specification.control end)
    if control then
      controlled[control] = controlled[control] or {}
      controlled[control][#controlled[control] + 1] = name
    end
  end
  for _, names in pairs(controlled) do table.sort(names) end
  local function asteroid_roots(location, definitions)
    for _, definition in ipairs(definitions or {}) do
      if definition.type == "asteroid-chunk" and definition.asteroid then
        local chunk = read(function() return prototypes.asteroid_chunk[definition.asteroid] end)
        local mining = chunk and read(function() return chunk.mineable_properties end)
        local products = mining and mining.products
        if products and #products > 0 then
          for _, product in pairs(products) do add(location, product.name, "asteroid") end
        else
          add(location, definition.asteroid, "asteroid")
        end
      end
    end
  end
  for _, location_name in ipairs(each_key(prototypes.space_location)) do
    local location = prototypes.space_location[location_name]
    local settings = read(function() return location.map_gen_settings end)
    if settings then
      R.planets[#R.planets + 1] = location_name
      local autoplace = settings.autoplace_settings or {}
      for _, name in ipairs(each_key(autoplace.entity and autoplace.entity.settings)) do
        local entity = prototypes.entity and prototypes.entity[name]
        if entity then entity_roots(location_name, entity) end
      end
      for _, control in ipairs(each_key(settings.autoplace_controls)) do
        for _, name in ipairs(controlled[control] or {}) do entity_roots(location_name, prototypes.entity[name]) end
      end
      for _, name in ipairs(each_key(autoplace.tile and autoplace.tile.settings)) do
        local tile = prototypes.tile and prototypes.tile[name]
        add(location_name, tile and read(function() return tile.fluid.name end), "offshore")
      end
    end
    asteroid_roots(location_name, read(function() return location.asteroid_spawn_definitions end))
    R.properties[location_name] = read(function() return location.surface_properties end) or {}
  end
  for _, connection_name in ipairs(each_key(prototypes.space_connection)) do
    local connection = prototypes.space_connection[connection_name]
    asteroid_roots(connection_name, read(function() return connection.asteroid_spawn_definitions end))
  end
  for _, list in pairs(R.by_product) do
    table.sort(list, function(a, b) return a.planet == b.planet and a.via < b.via or a.planet < b.planet end)
  end
  roots_cache = R
  return R
end

-- The liquids of a location's own map-generated tiles (an offshore pump
-- there pumps them), from that location's prototype alone, once per load:
-- observe_local's legend and the power block ask it, never the whole
-- catalogue roots() reads.
local liquids_cache = {}
local function liquids_of(location)
  local known = liquids_cache[location]
  if known == nil then
    known = {}
    local settings = read(function() return prototypes.space_location[location].map_gen_settings end)
    local tiles = settings and settings.autoplace_settings and settings.autoplace_settings.tile
    for name in pairs(tiles and tiles.settings or {}) do
      local tile = prototypes.tile and prototypes.tile[name]
      local fluid = tile and read(function() return tile.fluid.name end)
      if fluid then known[fluid] = true end
    end
    liquids_cache[location] = known
  end
  return known
end

-- Whether a location's own map generation has tiles of this liquid.
function M.has_liquid(location, fluid)
  return location ~= nil and liquids_of(location)[fluid] == true
end

-- A surface property of a location: its own value, else the property's
-- default.
local function property(location, name)
  local value = (roots().properties[location] or {})[name]
  if value ~= nil then return value end
  return read(function() return prototypes.surface_property[name].default_value end)
end

-- Whether every surface condition holds at a location.
local function conditions_hold(conditions, location)
  for _, condition in ipairs(conditions or {}) do
    local value = property(location, condition.property)
    if type(value) ~= "number" or (condition.min and value < condition.min) or (condition.max and value > condition.max) then
      return false
    end
  end
  return true
end

local function recipe_conditions(recipe)
  local conditions = read(function() return recipe.prototype.surface_conditions end)
  if conditions == nil then conditions = read(function() return recipe.surface_conditions end) end
  return type(conditions) == "table" and #conditions > 0 and conditions or nil
end

-- The planets (locations with map generation) whose properties hold every
-- condition.
local function planets_allowing(conditions)
  local list = {}
  for _, name in ipairs(roots().planets) do
    if conditions_hold(conditions, name) then list[#list + 1] = name end
  end
  return list
end

-- The place an expansion plans for: the named planet, else the body's
-- planet or its platform's location (nil when none).
local function planning_location(params, body)
  if params.planet ~= nil then
    if type(params.planet) ~= "string" or not (prototypes.space_location and prototypes.space_location[params.planet]) then
      error("production_requirements planet must name a space location (nauvis, vulcanus, gleba, fulgora, aquilo)", 0)
    end
    return params.planet
  end
  local surface = body and body.surface
  return read(function() return surface.planet.name end)
    or read(function() return surface.platform.space_location.name end)
end

-- Roots, unobtainable raws and the surface-limited recipes of an expansion.
local function annotate(result, expanded, force)
  local R = roots()
  local by_raw, unobtainable = {}, {}
  for _, name in ipairs(each_key(expanded.raw)) do
    local list = R.by_product[name]
    if list then by_raw[name] = list else unobtainable[#unobtainable + 1] = name end
  end
  local limited = {}
  for _, node in ipairs(expanded.nodes) do
    local recipe = force.recipes and force.recipes[node.recipe]
    local conditions = recipe and recipe_conditions(recipe)
    if conditions then
      local first = conditions[1]
      limited[#limited + 1] = { recipe = node.recipe,
        condition = { property = first.property, min = first.min, max = first.max },
        planets = planets_allowing(conditions) }
    end
  end
  result.roots, result.unobtainable, result.surface_limited = by_raw, unobtainable, limited
  return result
end

-- ------------------------------------------------------------- expansion

local function candidate_recipes(force, product, permitted_locked, location)
  local candidates, locked = {}, {}
  for name, recipe in pairs(force.recipes or {}) do
    -- Hidden recipes (quality recycling, debug items) are never production routes.
    local hidden_ok, hidden = pcall(function() return recipe.hidden end)
    local produces = false
    if not (hidden_ok and hidden) then
      for _, candidate in ipairs(recipe.products or {}) do if candidate.name == product then produces = true end end
    end
    -- Surface conditions are read only for the few recipes that make it.
    if produces and location ~= nil and not conditions_hold(recipe_conditions(recipe), location) then produces = false end
    if produces then
      if recipe.enabled or permitted_locked and permitted_locked[name] then candidates[#candidates + 1] = recipe
      else locked[#locked + 1] = recipe end
    end
  end
  table.sort(candidates, function(a, b) return a.name < b.name end)
  table.sort(locked, function(a, b) return a.name < b.name end)
  return candidates, locked
end

local function expand_targets(force, targets, choices, options)
  local nodes_by_item, raw, all_products, visiting = {}, {}, {}, {}
  local ambiguities, variable = options.ambiguities or {}, options.variable or {}
  -- Acquisition roots are what the planning location's own map generation
  -- (or its asteroids) gives (prototype data, not charted or hidden map state).
  -- Products native to another planet keep their ordinary recipe, ambiguity, or
  -- locked handling. No location gives no roots.
  local resource_products = options.location and roots().at[options.location] or {}

  local chosen = {}
  local function choose_uncached(product)
    local choice = choices[product]
    if choice == nil and resource_products[product] then return nil end
    local candidates, locked = candidate_recipes(force, product, options.permitted_locked, options.filter_location)
    if choice ~= nil then
      if type(choice) ~= "string" then error("recipe choice for " .. product .. " must be a recipe name") end
      for _, recipe in ipairs(candidates) do if recipe.name == choice then return recipe end end
      error("recipe choice " .. choice .. " is not a permitted deterministic route for " .. product)
    end
    if #candidates > 1 then
      local names = {}; for _, recipe in ipairs(candidates) do names[#names + 1] = recipe.name end
      if not options.partial then
        error("ambiguous production route for " .. product .. ": " .. table.concat(names, ", ") .. "; supply recipe_choices." .. product)
      end
      ambiguities[#ambiguities + 1] = { kind = "recipe_choice", product = product, candidates = names }
      return nil
    end
    if #candidates == 1 then return candidates[1] end
    if #locked > 0 and not options.partial then error("no progression route for " .. product .. ": producing recipes are not unlocked") end
    return nil
  end

  -- One recipe search per product per expansion (the search reads every force recipe).
  local function choose(product)
    if chosen[product] == nil then chosen[product] = { choose_uncached(product) } end
    return chosen[product][1]
  end

  local function require_item(product, count)
    if visiting[product] then
      if not options.partial then error("no progression route for " .. product .. ": recipe cycle") end
      ambiguities[#ambiguities + 1] = { kind = "recipe_cycle", product = product }
      raw[product] = (raw[product] or 0) + count
      return
    end
    local recipe = choose(product)
    if not recipe then raw[product] = (raw[product] or 0) + count; return end
    local products, product_error = products_of(recipe)
    if not products then
      if not options.partial then error(product_error) end
      variable[#variable + 1] = { kind = "non_deterministic_recipe", product = product, recipe = recipe.name, reason = product_error }
      raw[product] = (raw[product] or 0) + count
      return
    end
    local output = products[product]
    if not output or output <= 0 then error("recipe " .. recipe.name .. " does not deterministically produce " .. product) end
    local node = nodes_by_item[product]
    if node and node.recipe ~= recipe.name then error("inconsistent recipe choice for " .. product) end
    if not node then
      node = { item = product, required_units = 0, recipe = recipe.name, recipe_executions = 0,
        output_units_per_execution = output, category = recipe.category or "crafting",
        craft_time_seconds_per_execution = tonumber(recipe.energy) or 0,
        ingredient_units_per_execution = ingredients_of(recipe), product_units_per_execution = products }
      nodes_by_item[product] = node
    end
    local old_crafts = node.recipe_executions
    node.required_units = node.required_units + count
    -- Rates keep fractional executions per minute; counts round up to whole crafts.
    node.recipe_executions = options.rate and node.required_units / output or math.ceil(node.required_units / output)
    local added_crafts = node.recipe_executions - old_crafts
    if added_crafts == 0 then return end
    visiting[product] = true
    for ingredient, per_craft in pairs(node.ingredient_units_per_execution) do require_item(ingredient, per_craft * added_crafts) end
    visiting[product] = nil
    for name, per_craft in pairs(node.product_units_per_execution) do
      all_products[name] = (all_products[name] or 0) + per_craft * added_crafts
    end
  end

  for _, target in ipairs(sorted_keys(targets)) do require_item(target, tonumber(targets[target])) end
  local nodes, total_time = {}, 0
  for _, node in pairs(nodes_by_item) do
    total_time = total_time + node.craft_time_seconds_per_execution * node.recipe_executions
    nodes[#nodes + 1] = node
  end
  table.sort(nodes, function(a, b) return a.item == b.item and a.recipe < b.recipe or a.item < b.item end)
  return { nodes = nodes, raw = raw, products = all_products,
    total_craft_time_seconds_at_speed_1 = total_time, ambiguities = ambiguities,
    variable_operating_requirements = variable }
end

local function technology_effects(technology)
  local ok, effects = pcall(function() return technology.prototype.effects end)
  return ok and type(effects) == "table" and effects or {}
end

local function closure_for(force, target_name)
  local target = force.technologies and force.technologies[target_name]
  if not target then error("unknown technology: " .. target_name) end
  local visited, ordered = {}, {}
  local function visit(technology)
    if visited[technology.name] or technology.researched then return end
    visited[technology.name] = true
    local prerequisites = {}
    for _, prerequisite in pairs(technology.prerequisites or {}) do prerequisites[#prerequisites + 1] = prerequisite end
    table.sort(prerequisites, function(a, b) return a.name < b.name end)
    for _, prerequisite in ipairs(prerequisites) do visit(prerequisite) end
    ordered[#ordered + 1] = technology
  end
  visit(target)
  return ordered
end

local function find_location_unlock(force, location)
  if not (prototypes.space_location and prototypes.space_location[location]) then error("unknown space location: " .. location) end
  local candidates = {}
  for name, technology in pairs(force.technologies or {}) do
    for _, effect in pairs(technology_effects(technology)) do
      if effect.type == "unlock-space-location" and effect.space_location == location then candidates[#candidates + 1] = name end
    end
  end
  table.sort(candidates)
  if #candidates == 0 then error("no installed technology unlocks space location " .. location) end
  return candidates
end

local function exact_inventory_credit(character, required)
  local credit, remaining = {}, {}
  local inventory = character and character.valid and character.get_main_inventory() or nil
  for _, name in ipairs(sorted_keys(required)) do
    local available = inventory and inventory.get_item_count and inventory.get_item_count(name) or 0
    local used = math.min(required[name], tonumber(available) or 0)
    if used > 0 then credit[name] = used end
    local rest = required[name] - used
    if rest > 0 then remaining[name] = rest end
  end
  return credit, remaining
end

local function flow_rows(force, surface, required, precision_name)
  local precision = FLOW_PRECISIONS[precision_name]
  local precision_index = defines and defines.flow_precision_index and defines.flow_precision_index[precision_name]
  if not precision or precision_index == nil then return {}, { kind = "flow_statistics_unavailable", precision = precision_name } end
  local ok_stats, statistics = pcall(function() return force.get_item_production_statistics(surface) end)
  if not ok_stats or not statistics then return {}, { kind = "flow_statistics_unavailable", precision = precision_name } end
  local rows, complete, bottleneck = {}, true, 0
  for _, name in ipairs(sorted_keys(required)) do
    local ok, rate = pcall(function()
      return statistics.get_flow_count({ name = name, category = "input", precision_index = precision_index, count = false })
    end)
    rate = ok and tonumber(rate) or nil
    local seconds = rate and rate > 0 and required[name] / rate * 60 or nil
    if not seconds then complete = false else bottleneck = math.max(bottleneck, seconds) end
    rows[#rows + 1] = { name = name, production_rate = rate, statistics_category = "input", precision = precision_name,
      window_ticks = precision.ticks, units = precision.units, seconds_at_observed_rate = seconds,
      source = "force_flow_statistics" }
  end
  return rows, { complete = complete, bottleneck_seconds = complete and bottleneck or nil,
    basis = "remaining_science_divided_by_observed_force_output_rate" }
end

local function closure_requirements(params, body, location, force, target_kind, target_name)
  local character = body.character
  local location_candidates = target_kind == "location" and find_location_unlock(force, target_name) or nil
  if location_candidates and #location_candidates > 1 then
    return { target_kind = target_kind, target = target_name, partial = true,
      ambiguities = { { kind = "location_unlock_technology", candidates = location_candidates } },
      remaining_science_packs = {}, missing_technologies = {}, trigger_conditions = {},
      variable_operating_requirements = {}, stock_credit = { scope = "character_main_inventory", items = {},
        remote_inventories_credited = false } }
  end
  local technology_name = location_candidates and location_candidates[1] or target_name
  local technologies = closure_for(force, technology_name)
  local missing, triggers, science, permitted_locked, ambiguities, variable = {}, {}, {}, {}, {}, {}
  for _, technology in ipairs(technologies) do
    local trigger = research.research_trigger(technology)
    local count_ok, count = pcall(function() return technology.prototype.research_unit_count end)
    count = count_ok and tonumber(count) or nil
    local ingredients_ok, ingredients = pcall(function() return technology.prototype.research_unit_ingredients end)
    local fraction = technology == force.current_research and math.max(0, 1 - (tonumber(force.research_progress) or 0)) or 1
    local row = { name = technology.name, prerequisites = sorted_keys(technology.prerequisites),
      kind = trigger and "trigger" or "research", remaining_research_units = count and count * fraction or nil }
    missing[#missing + 1] = row
    if trigger then triggers[#triggers + 1] = { technology = technology.name, trigger = trigger,
      action = research.trigger_action(trigger) }
    elseif count and ingredients_ok then
      for _, ingredient in pairs(ingredients or {}) do
        if ingredient.name then science[ingredient.name] = (science[ingredient.name] or 0) + count * fraction * (tonumber(ingredient.amount) or 1) end
      end
    else
      variable[#variable + 1] = { kind = "technology_research_cost_unavailable", technology = technology.name,
        reason = "installed prototype did not expose a fixed research unit count and ingredients" }
    end
    for _, effect in pairs(technology_effects(technology)) do
      local recipe_name = effect.recipe
      if effect.type == "unlock-recipe" and type(recipe_name) == "string" then permitted_locked[recipe_name] = true end
    end
  end
  table.sort(missing, function(a, b) return a.name < b.name end)
  table.sort(triggers, function(a, b) return a.technology < b.technology end)
  local credit, remaining = exact_inventory_credit(character, science)
  local deterministic = expand_targets(force, remaining, params.recipe_choices or {}, {
    partial = true, permitted_locked = permitted_locked, ambiguities = ambiguities, variable = variable,
    location = location, filter_location = params.planet,
  })
  annotate(deterministic, deterministic, force)
  local precision = params.flow_precision or "one_minute"
  local flows, time_estimate = flow_rows(force, body.surface, remaining, precision)
  if time_estimate.kind then variable[#variable + 1] = time_estimate end
  return {
    target_kind = target_kind, target = target_name, target_technology = technology_name,
    source_tick = game.tick, missing_technologies = missing, trigger_conditions = triggers,
    science_packs_before_stock_credit = science, remaining_science_packs = remaining,
    stock_credit = { scope = "character_main_inventory", items = credit, remote_inventories_credited = false,
      note = "exact remote machine, chest, and fluid stocks are intentionally unavailable" },
    deterministic_requirements = deterministic, force_flows = flows, time_estimate = time_estimate,
    recipe_assumptions = params.recipe_choices or {}, ambiguities = ambiguities,
    variable_operating_requirements = variable,
    partial = #ambiguities > 0 or #variable > 0 or #triggers > 0,
  }
end

-- ------------------------------------------------------------- rate plan
-- Units per minute instead of counts: per stage the machines each tier
-- needs, their fuel or electric power, the drills a raw resource needs, and
-- what one belt of each tier carries. Every number is read from live
-- prototypes at call time (crafting and mining speed, recipe and mining
-- time, energy use, burner effectivity, fuel value, belt speed); nothing is
-- tabulated. Counts are nominal full-duty capacity at normal quality with
-- no modules, beacons or mining-productivity research.

local function round(value) return math.floor(value * 100 + 0.5) / 100 end

-- Energy per machine at full duty: burner (with fuel per minute in the
-- reference fuel) or electric (kW).
local function energy_row(row, proto, count, fuel)
  local usage = read(function() return proto.get_max_energy_usage() end) or 0 -- joules per tick
  local burner = read(function() return proto.burner_prototype end)
  if burner then
    local effectivity = read(function() return burner.effectivity end) or 1
    local categories = read(function() return burner.fuel_categories end) or {}
    row.energy = "burner"
    row.fuel_mw = round(count * usage * 60 / effectivity / 1e6)
    if fuel and categories[fuel.category] then row.fuel_per_minute = round(count * usage * 3600 / effectivity / fuel.joules)
    else row.fuel_categories = sorted_keys(categories) end
  elseif read(function() return proto.electric_energy_source_prototype end) then
    row.energy = "electric"
    row.power_kw = round(count * usage * 60 / 1000)
  else row.energy = "none" end
  return row
end

local function unlocked(force, proto)
  local placed = read(function() return proto.items_to_place_this end)
  local item = placed and placed[1] and placed[1].name
  local recipe = item and force.recipes[item]
  return recipe ~= nil and recipe.enabled == true
end

-- Rows for every buildable prototype that can do the work, sorted by name;
-- a machine's built-in productivity (foundry, biochamber) shares the work.
local function tier_rows(force, protos, speed_of, work, fuel)
  local rows = {}
  for name, proto in pairs(protos) do
    local speed = speed_of(proto)
    local placed = read(function() return proto.items_to_place_this end)
    if speed and speed > 0 and placed and placed[1] then
      local productivity = read(function() return proto.effect_receiver.base_effect.productivity end) or 0
      local count = work / speed / (1 + productivity)
      rows[#rows + 1] = energy_row({ entity = name, speed = speed, machines = round(count),
        machines_to_build = math.ceil(count - 1e-9), unlocked = unlocked(force, proto) }, proto, count, fuel)
    end
  end
  table.sort(rows, function(a, b) return a.entity < b.entity end)
  return rows
end

local function rate_plan(force, expanded, fuel_name)
  local fuel_proto = prototypes.item[fuel_name]
  local fuel = { name = fuel_name, joules = fuel_proto.fuel_value, category = read(function() return fuel_proto.fuel_category end) }
  local crafters = {}
  for name, proto in pairs(prototypes.get_entity_filtered({ { filter = "type", type = { "assembling-machine", "furnace", "rocket-silo" } } })) do
    crafters[name] = { proto = proto, categories = read(function() return proto.crafting_categories end) or {} }
  end
  local stages = {}
  for _, node in ipairs(expanded.nodes) do
    local able = {}
    for name, crafter in pairs(crafters) do
      if crafter.categories[node.category] then able[name] = crafter.proto end
    end
    -- Crafting work per second at speed 1, shared out by machine speed.
    local work = node.recipe_executions / 60 * node.craft_time_seconds_per_execution
    stages[#stages + 1] = { item = node.item, recipe = node.recipe, category = node.category,
      units_per_minute = round(node.required_units), executions_per_minute = round(node.recipe_executions),
      machines = tier_rows(force, able, function(proto) return read(function() return proto.get_crafting_speed() end) end, work, fuel) }
  end
  local resources = prototypes.get_entity_filtered({ { filter = "type", type = "resource" } })
  local drills = prototypes.get_entity_filtered({ { filter = "type", type = "mining-drill" } })
  local raw, resource_names = {}, sorted_keys(resources)
  for _, item in ipairs(sorted_keys(expanded.raw)) do
    local per_minute = expanded.raw[item]
    local row = { item = item, units_per_minute = round(per_minute), drills = {} }
    for _, resource_name in ipairs(resource_names) do
      local mining = read(function() return resources[resource_name].mineable_properties end)
      local amount = 0
      for _, product in ipairs(mining and mining.products or {}) do
        if product.name == item and product.type ~= "fluid" then amount = amount + (tonumber(product.amount) or 0) end
      end
      local time = mining and tonumber(mining.mining_time)
      if amount > 0 and time and time > 0 and #row.drills == 0 then
        local category = read(function() return resources[resource_name].resource_category end)
        local able = {}
        for name, proto in pairs(drills) do
          if (read(function() return proto.resource_categories end) or {})[category] then able[name] = proto end
        end
        row.resource = resource_name
        -- Mining work per second: a drill of mining speed s yields s / time * amount per second.
        row.drills = tier_rows(force, able, function(proto) return read(function() return proto.mining_speed end) end,
          per_minute / 60 * time / amount, fuel)
      end
    end
    if #row.drills == 0 then row.note = "no drill mines it: a fluid, a hand-gathered or asteroid product, or another planet's resource" end
    raw[#raw + 1] = row
  end
  local belts = {}
  for name, proto in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "transport-belt" } })) do
    local speed = read(function() return proto.belt_speed end)
    -- A belt moves speed tiles per tick on two lanes of four items per tile.
    if speed and speed > 0 then belts[#belts + 1] = { entity = name, items_per_minute = round(speed * 480 * 60), unlocked = unlocked(force, proto) } end
  end
  table.sort(belts, function(a, b) return a.items_per_minute < b.items_per_minute end)
  return { units = "per_minute",
    basis = "nominal full-duty capacity at normal quality with built-in productivity; no modules, beacons or researched productivity",
    reference_fuel = { item = fuel.name, megajoules = round(fuel.joules / 1e6), category = fuel.category },
    stages = stages, raw = raw, belts = belts }
end

function M.production_requirements(params)
  local modes = (params.targets and 1 or 0) + (params.technology and 1 or 0) + (params.location and 1 or 0)
  if modes ~= 1 then error("production_requirements requires exactly one of targets, technology, or location") end
  local body = companion.require_present()
  local force = body.force
  local location = planning_location(params, body)
  if params.technology then return closure_requirements(params, body, location, force, "technology", params.technology) end
  if params.location then return closure_requirements(params, body, location, force, "location", params.location) end

  local targets, target_names = params.targets, {}
  if type(targets) ~= "table" then error("production_requirements targets must map item or fluid names to positive counts") end
  for target, raw_count in pairs(targets) do
    local item = type(target) == "string" and prototypes.item and prototypes.item[target]
    local fluid = type(target) == "string" and prototypes.fluid and prototypes.fluid[target]
    if not item and not fluid then error("no item or fluid called '" .. tostring(target) .. "'") end
    local count = tonumber(raw_count)
    if not count or count <= 0 or count ~= count or count == math.huge then error("production_requirements target counts must be positive finite numbers") end
    if item and count % 1 ~= 0 and params.per_minute ~= true then error("item target counts must be positive integers") end
    target_names[#target_names + 1] = target
  end
  if #target_names < 1 or #target_names > 16 then error("production_requirements targets must contain 1-16 entries") end
  local choices = params.recipe_choices or {}
  if type(choices) ~= "table" then error("production_requirements recipe_choices must map product names to recipe names") end
  local fuel = params.fuel or "coal"
  if params.per_minute == true then
    local fuel_proto = type(fuel) == "string" and prototypes.item[fuel]
    if not (fuel_proto and (tonumber(read(function() return fuel_proto.fuel_value end)) or 0) > 0) then
      error("fuel must name a fuel item, such as coal")
    end
  end
  local expanded = expand_targets(force, targets, choices,
    { partial = false, location = location, filter_location = params.planet, rate = params.per_minute == true })
  if params.per_minute == true then
    return annotate({ planet = location, targets_per_minute = targets, rates = rate_plan(force, expanded, fuel) }, expanded, force)
  end
  return annotate({ units = { targets = "item_or_fluid_units", raw = "item_or_fluid_units",
      products = "item_or_fluid_units", time = "seconds_at_crafting_speed_1" },
    planet = location, targets = targets, nodes = expanded.nodes, raw = expanded.raw, products = expanded.products,
    total_craft_time_seconds_at_speed_1 = expanded.total_craft_time_seconds_at_speed_1 }, expanded, force)
end

return M
