-- Read-only summary of the force's already charted world. No chart or generation calls.
-- map_summary is a job (summary_job, below) spread over ticks by a work budget;
-- factory_status and the run recorder read the patch caches kept here (one
-- per planet surface) and the power rows built here from the registry's
-- aggregates (build_power).
-- map_summary {surface?} describes one surface: the body's anchor surface
-- (its physical surface, the hub aboard) or the one named, kept in the job's
-- state, never re-read from the body. surface:"all" sums the flows of every
-- factory surface; its map sections describe the body's surface.
local companion = require("scripts.companion")
local schema = require("scripts.state")
local surfaces = require("scripts.surfaces")
local items = require("scripts.items")
local factory_activity = require("scripts.factory_activity")
local autonomy = require("scripts.autonomy")
local fluid_connections = require("scripts.fluid_connections")
local output_target = require("scripts.output_target")
local registry = require("scripts.registry")
local jobs = require("scripts.jobs")

local M = {}
local sort_step, heap_keep = jobs.sort_step, jobs.keep_first
local MAX_EDGES = 256
local MAX_LANDMARKS = 256
local MAX_FACTORY_GROUPS = 12
local MAX_FLOW_ROWS = 12
local MAX_FLOW_NODES = 12
local MAX_FLOW_EDGES = 24
local MAX_FLOW_COMPONENTS = 8

local MACHINE_TYPES = {
  ["assembling-machine"] = true, furnace = true, ["mining-drill"] = true,
  lab = true, ["rocket-silo"] = true, boiler = true, generator = true,
  ["burner-generator"] = true, reactor = true, ["offshore-pump"] = true,
  pump = true, inserter = true,
}

local FLOW_NODE_ROLES = {
  ["mining-drill"] = "source", ["offshore-pump"] = "source",
  inserter = "transport", ["transport-belt"] = "transport",
  ["underground-belt"] = "transport", splitter = "transport", loader = "transport",
  ["loader-1x1"] = "transport", pump = "transport", pipe = "transport",
  ["pipe-to-ground"] = "transport",
  ["assembling-machine"] = "processor", furnace = "processor", ["rocket-silo"] = "processor",
  boiler = "processor", reactor = "processor",
  container = "buffer", ["logistic-container"] = "buffer", ["storage-tank"] = "buffer",
  lab = "sink", generator = "sink", ["burner-generator"] = "sink",
}

local STATUS_BUCKETS = {
  working = "working", charging = "working", discharging = "working",
  normal = "idle", idle = "idle", not_plugged_in_electric_network = "no_power",
  no_power = "no_power", low_power = "low_power", no_fuel = "no_fuel",
  no_ingredients = "insufficient_input", item_ingredient_shortage = "insufficient_input",
  fluid_ingredient_shortage = "insufficient_input", waiting_for_source_items = "insufficient_input",
  full_output = "full_output", waiting_for_space_in_destination = "full_output",
  no_minable_resources = "no_resources", disabled = "disabled",
  disabled_by_control_behavior = "disabled",
  disabled_by_script = "disabled", marked_for_deconstruction = "disabled",
  turned_off_during_daytime = "disabled",
}

-- A status is one sample. Only these raw statuses describe the build itself;
-- every other nonproductive status is a transient wait judged by throughput.
local STRUCTURAL_RAW_STATUSES = {
  no_minable_resources = true, disabled = true,
  disabled_by_control_behavior = true, disabled_by_script = true,
  not_plugged_in_electric_network = true, marked_for_deconstruction = true,
}
-- Electrical consumers in these sampled states draw no work power.
local IDLE_CONSUMER_STATUSES = { idle = true, insufficient_input = true, full_output = true }
local MAX_COMPONENT_BLOCKER_DETAILS = 3

local FLOW_PRECISIONS = {
  five_seconds = { ticks = 300, units = "units_per_minute" },
  one_minute = { ticks = 3600, units = "units_per_minute" },
  ten_minutes = { ticks = 36000, units = "units_per_minute" },
  one_hour = { ticks = 216000, units = "units_per_minute" },
}

-- The force's chart (all of a platform's surface counts as charted). A
-- caller reading many positions of one surface passes whether it is a
-- platform's, worked out once.
local function charted(force, surface, pos, platform)
  return surfaces.charted(force, surface, math.floor(pos.x / 32), math.floor(pos.y / 32), platform)
end

local function status_name(entity)
  local ok, status = pcall(function() return entity.status end)
  if not ok or status == nil then return nil end
  for name, value in pairs((defines and defines.entity_status) or {}) do if value == status then return name end end
  return tostring(status)
end

local function recipe_name(entity)
  local ok, recipe = pcall(function() return entity.get_recipe and entity.get_recipe() end)
  if ok and recipe then return recipe.name end
  return nil
end

local function normalize_status(raw)
  return STATUS_BUCKETS[raw] or "other"
end

local function number_property(object, name)
  local ok, value = pcall(function() return object[name] end)
  if ok and type(value) == "number" then return value end
  return nil
end

-- An idle furnace reports no current recipe between input arrivals; its
-- previous_recipe keeps the identity it last crafted. Before its first craft
-- it has none. In 2.0 it is a recipe/quality pair whose name reads back as a
-- LuaRecipePrototype (userdata), like LuaBurner.currently_burning.
local function previous_furnace_recipe(entity)
  local ok, recipe = pcall(function()
    if entity.type ~= "furnace" then return nil end
    local name = entity.previous_recipe
    for _ = 1, 2 do
      if name ~= nil and type(name) ~= "string" then name = name.name end
    end
    if type(name) ~= "string" then return nil end
    return prototypes.recipe[name]
  end)
  if ok then return recipe end
  return nil
end

local function recipe_fact(entity)
  local ok, recipe = pcall(function() return entity.get_recipe and entity.get_recipe() end)
  if ok and not recipe then recipe = previous_furnace_recipe(entity) end
  if not ok or not recipe then return nil end
  local fact = { name = recipe.name, energy = number_property(recipe, "energy"), ingredients = {}, products = {} }
  local function collect(source, destination)
    local ok_rows, rows = pcall(function() return recipe[source] end)
    if not ok_rows or type(rows) ~= "table" then return end
    local complete = true
    for _, row in pairs(rows) do
      if type(row) == "table" and type(row.name) == "string" then
        destination[#destination + 1] = { name = row.name, type = row.type == "fluid" and "fluid" or "item" }
      else complete = false end
    end
    return complete
  end
  fact.ingredients_proven = collect("ingredients", fact.ingredients)
  collect("products", fact.products)
  return fact
end

local function add_flow_candidate(candidates, kind, name)
  if type(name) ~= "string" or name == "" then return end
  local key = kind .. "\0" .. name
  candidates[key] = { type = kind, name = name }
end

local function add_current_research_flows(force, candidates)
  local ok, technology = pcall(function() return force.current_research end)
  if not ok or not technology then return end
  local ok_ingredients, ingredients = pcall(function() return technology.research_unit_ingredients end)
  if not ok_ingredients or type(ingredients) ~= "table" then return end
  for _, ingredient in pairs(ingredients) do
    if type(ingredient) == "table" then add_flow_candidate(candidates, "item", ingredient.name) end
  end
end

local function sorted_rows(map, compare)
  local rows = {}
  for _, row in pairs(map) do rows[#rows + 1] = row end
  table.sort(rows, compare)
  return rows
end

local function cap_rows(rows, limit)
  local omitted = math.max(0, #rows - limit)
  while #rows > limit do table.remove(rows) end
  return omitted
end

-- The force's production statistics of a kind ("item" or "fluid") for each
-- surface listed: a list of LuaFlowStatistics, or nil when one is unreadable.
local function statistics_of(force, surface_list, kind)
  local getter_name = kind == "fluid" and "get_fluid_production_statistics" or "get_item_production_statistics"
  local list = {}
  for _, surface in ipairs(surface_list) do
    local ok, statistics = pcall(function() return force[getter_name](surface) end)
    if not (ok and statistics) then return nil end
    list[#list + 1] = statistics
  end
  return list
end
M.statistics_of = statistics_of

-- A flow rate summed over statistics, or nil when one cannot say.
local function summed_rate(list, name, category, precision_index)
  local total = 0
  for _, statistics in ipairs(list or {}) do
    local ok, value = pcall(function()
      return statistics.get_flow_count({ name = name, category = category, precision_index = precision_index, count = false })
    end)
    if not (ok and type(value) == "number") then return nil end
    total = total + value
  end
  return list and total or nil
end

local function key_position(a, b)
  if a.position.y ~= b.position.y then return a.position.y < b.position.y end
  if a.position.x ~= b.position.x then return a.position.x < b.position.x end
  if a.name ~= b.name then return a.name < b.name end
  return a.type < b.type
end

local function entity_key(entity)
  if not entity or not entity.valid or type(entity.position) ~= "table" then return nil end
  return string.format("%s\0%s\0%.17g\0%.17g", entity.name, entity.type, entity.position.x, entity.position.y)
end

local function item_fuel_category(name)
  local ok, prototype = pcall(function() return prototypes and prototypes.item and prototypes.item[name] end)
  if not ok or not prototype then return nil end
  local ok_value, value = pcall(function() return prototype.fuel_value end)
  local ok_category, category = pcall(function() return prototype.fuel_category end)
  if ok_value and type(value) == "number" and value > 0 and ok_category and type(category) == "string" then return category end
  return nil
end

local function mining_products(entity)
  local products = {}
  local ok, target = pcall(function() return entity.mining_target end)
  local mineable = ok and target and target.prototype and target.prototype.mineable_properties
  for _, product in pairs(mineable and mineable.products or {}) do
    if type(product) == "table" and type(product.name) == "string" then
      products[#products + 1] = { name = product.name, type = product.type == "fluid" and "fluid" or "item",
        fuel_category = product.type ~= "fluid" and item_fuel_category(product.name) or nil }
    end
  end
  table.sort(products, function(a, b) return a.type == b.type and a.name < b.name or a.type < b.type end)
  return products
end

local function products_with_fuel(products)
  for _, product in ipairs(products or {}) do
    product.fuel_category = product.type ~= "fluid" and item_fuel_category(product.name) or nil
  end
  return products or {}
end

-- Installed nominal capacity, independent of duty/status and bonuses. This
-- requires a current charted target.
local function nominal_mining_capacity(entity, force, surface, platform)
  local ok, rate = pcall(function()
    local target = entity.mining_target
    if not entity_key(target) or not charted(force, surface, target.position, platform) then return nil end
    local mining = target.prototype.mineable_properties
    local speed, time = entity.prototype.mining_speed, mining.mining_time
    if type(speed) ~= "number" or speed <= 0 or speed >= math.huge
      or type(time) ~= "number" or time <= 0 or time >= math.huge then return nil end
    local yield, count = 0, 0
    for _, product in pairs(mining.products) do
      if product.type ~= "item" or type(product.name) ~= "string"
        or (product.probability ~= nil and product.probability ~= 1) then return nil end
      local amount = product.amount
      if amount == nil and product.amount_min == product.amount_max then amount = product.amount_min end
      if type(amount) ~= "number" or amount <= 0 or amount >= math.huge then return nil end
      yield, count = yield + amount, count + 1
    end
    if count == 0 then return nil end
    local result = 60 * speed / time * yield
    if result > 0 and result < math.huge then return result end
  end)
  return ok and rate or nil
end

local function has_burner(entity)
  local ok, burner = pcall(function() return entity.burner end)
  return ok and burner ~= nil
end

local function burner_categories(entity)
  local result = {}
  local ok, categories = pcall(function() return entity.prototype.burner_prototype.fuel_categories end)
  if not ok or type(categories) ~= "table" then return result end
  for key, value in pairs(categories) do
    local name = type(key) == "string" and key or type(value) == "string" and value
      or type(value) == "table" and value.name or nil
    if name then result[name] = true end
  end
  return result
end

-- Native fluid identities are independent of crafting recipes and starter stock.
local FLUID_TYPES = { ["offshore-pump"] = true, boiler = true, generator = true,
  pipe = true, ["pipe-to-ground"] = true, pump = true, ["storage-tank"] = true }
local function fluid_facts(node)
  if not FLUID_TYPES[node.type] then return end
  local entity = node._entity
  node._fluid_boxes = fluid_connections.sample(entity)
  node._fluid_connections, node._fluid_connections_complete = fluid_connections.live(entity, true)
  local ok = pcall(function()
    local boxes, proto = node._fluid_boxes, entity.prototype
    if not boxes or #boxes == 0 then error("fluidbox evidence unavailable") end
    if node.type == "offshore-pump" then
      local name = entity.get_fluid_source_fluid()
      local fluid = prototypes.fluid[name]
      if #boxes ~= 1 or boxes[1].production_type ~= "output" or not fluid
        or boxes[1].filter and boxes[1].filter ~= name then error("source identity unavailable") end
      node.products = { { name = name, type = "fluid", temperature = fluid.default_temperature } }
      node._fluid_source = name
    elseif node.type == "boiler" then
      if proto.boiler_mode ~= "output-to-separate-pipe" or #boxes ~= 2 then error("unsupported boiler") end
      local input, output
      for _, box in ipairs(boxes) do
        if box.production_type == "input" then input = box end
        if box.production_type == "output" then output = box end
      end
      if not input or not output or not input.filter or not output.filter
        or type(proto.target_temperature) ~= "number" then error("boiler identity unavailable") end
      node.ingredients = { { name = input.filter, type = "fluid" } }
      node.products = { { name = output.filter, type = "fluid", temperature = proto.target_temperature } }
      node._fluid_input, node._fluid_output = input.index, output.index
      node._fuel_destination_proven = true
    elseif node.type == "generator" then
      local box = boxes[1]
      local fluid = prototypes.fluid[box.filter]
      if #boxes ~= 1 or box.production_type ~= "input" or not fluid or proto.burns_fluid ~= false
        or type(proto.effectivity) ~= "number" or proto.effectivity <= 0
        or type(proto.maximum_temperature) ~= "number" or fluid.heat_capacity <= 0 then error("unsupported generator") end
      node.ingredients = { { name = box.filter, type = "fluid" } }
      node._generator = { default_temperature = fluid.default_temperature, heat_capacity = fluid.heat_capacity,
        effectivity = proto.effectivity, maximum_temperature = proto.maximum_temperature }
    elseif node.type == "pump" then
      -- A 2.0 pump has one box carrying both its input and output
      -- connections (their flow_direction orients its edges), outside any
      -- segment, so the join below puts both neighbouring pools in one
      -- domain where its draw and feed cancel. A pump box inside a segment
      -- would hide its transfer between pools and is refused.
      if #boxes ~= 1 or boxes[1].segment ~= nil then error("unsupported pump box") end
      node._fluid_input, node._fluid_output = 1, 1
    elseif #boxes ~= 1 then error("unsupported multiple transport boxes") end
  end)
  node._fluid_supported = ok
end

local function fluid_compatible(box, name, temperature)
  return box and type(name) == "string" and (not box.filter or box.filter == name)
    and (not box.name or box.name == name)
    and (not box.minimum_temperature or type(temperature) == "number" and temperature >= box.minimum_temperature)
    and (not box.maximum_temperature or type(temperature) == "number" and temperature <= box.maximum_temperature)
end

-- ------------------------------------------------------- material flow
-- The exact runtime relationships between the charted own flow nodes and the
-- components they form, built in stages (the map_summary job): every loop
-- over entities or nodes resumes at a cursor, so a tick reads at most its
-- budget. F is plain data kept in the job between ticks.

-- A drill's pending recipient: the one charted flow node of the drill's
-- force whose collision box holds its drop position, by the native
-- point/collision endpoint query, that can take a mined product: a conveyor
-- carries anything, other recipients must accept one natively.
local CONVEYORS = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
  ["lane-splitter"] = true, loader = true, ["loader-1x1"] = true, ["linked-belt"] = true }
local function pending_drill_recipient(F, entity)
  local ok, found = pcall(function()
    local point, products = entity.drop_position, mining_products(entity)
    local function accepts(candidate)
      if CONVEYORS[candidate.type] then return true end
      for _, product in ipairs(products) do
        if product.type == "item" and candidate.can_insert({ name = product.name, count = 1 }) then return true end
      end
      return false
    end
    local match
    for _, candidate in ipairs(entity.surface.find_entities_filtered({
      area = output_target.endpoint_area(point, entity.type, "output"), force = entity.force })) do
      if candidate.valid and candidate ~= entity and F.retained[entity_key(candidate)]
        and output_target.can_target_type(candidate.type, "output")
        and output_target.recipient_contains(candidate.bounding_box, point, entity.type, "output")
        and accepts(candidate) then
        if match then return nil end
        match = candidate
      end
    end
    return match
  end)
  return ok and found ~= nil
end

local function diagnostic(F, node, reason, confidence, class, related_edge)
  confidence = confidence or "exact"
  F.diagnostics[#F.diagnostics + 1] = { node_id = node.id, reason = reason, confidence = confidence,
    class = class or ((confidence == "ambiguous" or confidence == "unsupported") and "evidence" or "structural"),
    related_edge = related_edge }
end

local function status_class(node)
  return STRUCTURAL_RAW_STATUSES[node._raw_status] and "structural" or "transient"
end

local function add_edge(F, from_entity, to_entity, kind, from_box, to_box)
  local from_key, to_key = entity_key(from_entity), entity_key(to_entity)
  local from, to = from_key and F.retained[from_key], to_key and F.retained[to_key]
  if not from or not to then return false end
  local key = from.id .. "\0" .. to.id .. "\0" .. kind .. ":" .. tostring(from_box) .. ":" .. tostring(to_box)
  if F.seen_edges[key] then return true end
  F.seen_edges[key] = true
  F.edges[#F.edges + 1] = { from = from.id, to = to.id, kind = kind, confidence = "exact_runtime_relationship",
    from_fluidbox = from_box, to_fluidbox = to_box }
  return true
end

-- Calls fn(i) for i from F.cursor up to n while the budget lasts, charging
-- cost each (fn may charge more). True once all are done.
local function each(F, budget, n, cost, fn)
  local i = F.cursor or 1
  while i <= n do
    if budget.left <= 0 then F.cursor = i; return false end
    budget.left = budget.left - cost
    fn(i)
    i = i + 1
  end
  F.cursor = nil
  return true
end

-- Pure-Lua passes over nodes, edges and rows cost this much per element.
local LUA_ITEM = 0.5

-- Nodes in position order (their scan order sorted over ticks).
local function flow_sort_nodes(F, budget)
  local sorted = sort_step(F, "_sort", F.node_list, key_position, budget)
  if not sorted then return false end
  F.nodes, F.node_list = sorted, nil
  F.retained, F.segment_capacity = {}, {}
  F.edges, F.seen_edges, F.diagnostics = {}, {}, {}
  return true
end

-- Node ids. Natively get_capacity is one box's capacity, so a segment's
-- capacity sums its sampled member boxes; an unsampled member only makes it
-- look fuller.
local function flow_prepare(F, budget)
  return each(F, budget, #F.nodes, LUA_ITEM, function(index)
    local node = F.nodes[index]
    node.id = "node-" .. index
    F.retained[node._key] = node
    for _, box in ipairs(node._fluid_boxes or {}) do
      if box.segment then F.segment_capacity[box.segment] = (F.segment_capacity[box.segment] or 0) + box.capacity end
    end
  end)
end

-- One flow entity's exact relationships.
local function link_entity(F, entity, budget)
  local node = entity.valid and F.retained[entity_key(entity)]
  if not node then return end
  if entity.type == "inserter" then
    local ok_pickup, pickup = pcall(function() return entity.pickup_target end)
    local ok_drop, drop = pcall(function() return entity.drop_target end)
    if not ok_pickup then diagnostic(F, node, "inserter_pickup_ambiguous_requires_local_inspection", "ambiguous")
    elseif not pickup or not add_edge(F, pickup, entity, "inserter_pickup") then
      diagnostic(F, node, "inserter_pickup_has_no_eligible_entity", nil, nil, { kind = "inserter_pickup" })
    end
    if not ok_drop then diagnostic(F, node, "inserter_drop_ambiguous_requires_local_inspection", "ambiguous")
    elseif not drop or not add_edge(F, entity, drop, "inserter_drop") then
      diagnostic(F, node, "inserter_drop_has_no_eligible_sink", nil, nil, { kind = "inserter_drop" })
    end
  elseif entity.type == "mining-drill" then
    local ok_drop, drop = pcall(function() return entity.drop_target end)
    if not ok_drop then diagnostic(F, node, "output_connection_ambiguous_requires_local_inspection", "ambiguous")
    elseif drop == nil and pending_drill_recipient(F, entity) then
      -- Factorio binds a drill's drop_target at its first output; until
      -- then exactly one charted recipient at its drop position is a
      -- pending binding, not a missing sink. It still proves no path.
      budget.left = budget.left - 8
      node._output_pending = true
    elseif not drop or not add_edge(F, entity, drop, "machine_output") then
      diagnostic(F, node, "output_has_no_physical_sink", nil, nil, { kind = "machine_output" })
    end
  elseif entity.type == "transport-belt" or entity.type == "underground-belt"
    or entity.type == "splitter" or entity.type == "loader" or entity.type == "loader-1x1" then
    local ok_neighbours, neighbours = pcall(function() return entity.belt_neighbours end)
    if ok_neighbours and type(neighbours) == "table" then
      for _, input in pairs(neighbours.inputs or {}) do add_edge(F, input, entity, "belt_direction") end
      local outputs = 0
      for _, output in pairs(neighbours.outputs or {}) do if add_edge(F, entity, output, "belt_direction") then outputs = outputs + 1 end end
      -- belt_neighbours omits the other end of an underground pair.
      if entity.type == "underground-belt" then
        local ok_kind, kind = pcall(function() return entity.belt_to_ground_type end)
        local ok_exit, exit = pcall(function() return entity.neighbours end)
        if ok_kind and kind == "input" and ok_exit and exit and add_edge(F, entity, exit, "belt_direction") then outputs = outputs + 1 end
      end
      node._belt_outputs = outputs
    else
      diagnostic(F, node, "belt_connection_ambiguous_requires_local_inspection", "ambiguous")
    end
    if entity.type == "loader" or entity.type == "loader-1x1" then
      local ok_container, container = pcall(function() return entity.loader_container end)
      local ok_kind, kind = pcall(function() return entity.loader_type end)
      if ok_container and container and ok_kind and kind == "input" then add_edge(F, entity, container, "loader_container")
      elseif ok_container and container and ok_kind and kind == "output" then add_edge(F, container, entity, "loader_container") end
    end
  end
  if FLUID_TYPES[node.type] then
    budget.left = budget.left - 2 * #(node._fluid_connections or {})
    if number_property(entity, "unit_number") == nil then diagnostic(F, node, "fluid_entity_identity_unproven", "unsupported") end
    if not node._fluid_supported or not node._fluid_connections_complete then
      diagnostic(F, node, "fluid_native_evidence_unproven", "unsupported")
    end
    for _, connection in ipairs(node._fluid_connections or {}) do
      local target = connection._target_entity
      if target then
        local other = target.valid and F.retained[entity_key(target)]
        local source_box = node._fluid_boxes and node._fluid_boxes[connection.fluidbox_index]
        local target_box = other and other._fluid_boxes and other._fluid_boxes[connection._target_fluidbox_index]
        local proven = other and other._entity == target and target.surface == entity.surface and target_box and source_box
        if not proven then
          diagnostic(F, node, "fluid_connected_target_unproven", "unsupported")
        elseif connection.flow_direction == "output" or connection.flow_direction == "input-output" then
          local name = source_box.filter or source_box.name or target_box.filter or target_box.name
          local temperature = source_box.temperature
          if not temperature then
            for _, product in ipairs(node.products) do
              if product.type == "fluid" and product.name == name then temperature = product.temperature end
            end
          end
          if name and (source_box.filter and source_box.filter ~= name or target_box.filter and target_box.filter ~= name
            or source_box.name and source_box.name ~= name or target_box.name and target_box.name ~= name
            or temperature and not (fluid_compatible(source_box, name, temperature) and fluid_compatible(target_box, name, temperature))) then
            diagnostic(F, node, "fluid_connection_incompatible", nil, "structural")
          end
          add_edge(F, entity, target, "fluid_connection", source_box.index, target_box.index)
        elseif connection.flow_direction ~= "input" then
          diagnostic(F, node, "fluid_direction_unproven", "unsupported")
        end
      end
    end
  end
  if node.status == "full_output" then diagnostic(F, node, "downstream_inventory_blocked", nil, status_class(node)) end
  if node.status == "no_power" or node.status == "low_power" then diagnostic(F, node, "missing_power", nil, status_class(node)) end
  if node.status == "no_fuel" then diagnostic(F, node, "missing_fuel", nil, status_class(node)) end
  if node.status == "insufficient_input" then diagnostic(F, node, "missing_or_mismatched_input", "status_only", status_class(node)) end
end

local function flow_links(F, budget)
  return each(F, budget, #F.flow_entities, 16, function(i) link_entity(F, F.flow_entities[i], budget) end)
end

-- Segment capacities onto every box; generators by electric network.
local function flow_generators(F, budget)
  if not F.generators then F.generators = {} end
  return each(F, budget, #F.nodes, 1, function(i)
    local node = F.nodes[i]
    for _, box in ipairs(node._fluid_boxes or {}) do
      box.segment_capacity = box.segment and F.segment_capacity[box.segment] or box.capacity
    end
    if node.type == "generator" then
      budget.left = budget.left - 2
      local network = node._entity.valid and number_property(node._entity, "electric_network_id") or nil
      node._power_network = network
      if not network then diagnostic(F, node, "generator_electrical_network_unproven", "unsupported")
      else
        F.generators[network] = F.generators[network] or {}
        F.generators[network][#F.generators[network] + 1] = node
      end
    end
  end)
end

-- Electrical consumers on a generator's network that matter to material
-- flow depend on it; power is a dependency, not a path. One edge per
-- consumer, from the network's first generator: the graph joins a
-- network's generators into one component, so that edge names the supply.
local function flow_consumers(F, budget)
  if not F.touches then
    -- Nodes on a non-fluid edge (computed before any electrical edge exists).
    F.touches = {}
    for _, edge in ipairs(F.edges) do
      if edge.kind ~= "fluid_connection" then F.touches[edge.from], F.touches[edge.to] = true, true end
    end
  end
  return each(F, budget, #F.nodes, 3, function(i)
    local node = F.nodes[i]
    local entity = node._entity
    if not entity.valid then return end
    local ok, energy_source = pcall(function() return entity.prototype.electric_energy_source_prototype end)
    local network = number_property(entity, "electric_network_id")
    local material_relevant = node.role == "source" or node.role == "processor" or node.type == "pump"
      or (F.touches[node.id] and (node.role == "transport" or node.role == "sink"))
    if ok and energy_source and node.type ~= "generator" and F.generators[network] and material_relevant then
      node._power_network = network
      node._power_consumer = true
      if energy_source.usage_priority ~= "primary-input" and energy_source.usage_priority ~= "secondary-input" then
        diagnostic(F, node, "electrical_consumer_usage_unproven", "unsupported")
      end
      local generators = F.generators[network]
      add_edge(F, generators[1]._entity, entity, "electrical_dependency")
      F.delivering = F.delivering or {}
      if not F.delivering[network] then
        F.delivering[network] = true
        budget.left = budget.left - #generators
        for _, generator in ipairs(generators) do generator._power_delivery = true end
      end
    end
  end)
end

-- Material demand per network: a consumer that is not idle with a charged
-- buffer draws more than its constant drain.
local function flow_demand(F, budget)
  if not F.demand then
    F.demand = {}
    for _, node in ipairs(F.nodes) do
      if node.type == "generator" and not node._power_delivery then
        diagnostic(F, node, "electrical_material_consumer_unproven", "unsupported")
      end
    end
  end
  return each(F, budget, #F.nodes, 1, function(i)
    local node = F.nodes[i]
    if node._power_consumer then
      budget.left = budget.left - 1
      local energy = node._entity.valid and number_property(node._entity, "energy") or nil
      if not IDLE_CONSUMER_STATUSES[node.status] or not energy or energy <= 0 then F.demand[node._power_network] = true end
    end
  end)
end

-- An engine on standby: its own box holds steam above the fluid's default
-- temperature and every material consumer on its network is idle with a
-- charged buffer, so it serves at most their constant drain. No material
-- demand is neither an interruption nor blocked output.
local function flow_standby(F, budget)
  return each(F, budget, #F.nodes, 1, function(i)
    local node = F.nodes[i]
    local box = node.type == "generator" and node._fluid_supported and node._fluid_boxes and node._fluid_boxes[1]
    if box and node._power_delivery and not F.demand[node._power_network] then
      budget.left = budget.left - 1
      if (node._entity.valid and number_property(node._entity, "energy_generated_last_tick") or -1) >= 0
        and box.amount > 0 and type(box.temperature) == "number" and box.temperature > node._generator.default_temperature
        and fluid_compatible(box, box.name, box.temperature) then
        node._standby = true
      end
    end
  end)
end

local function run_root(F, id)
  local parent = F.run_parent
  while parent[id] ~= id do parent[id] = parent[parent[id]]; id = parent[id] end
  return id
end

local function root(F, id)
  local parent = F.parent
  while parent[id] ~= id do parent[id] = parent[parent[id]]; id = parent[id] end
  return id
end

-- The graph from the edges, without engine reads, in stages a budget at a
-- time: edges in order, belt runs, components, adjacency, character
-- transfers and the edges per node.
local function edge_order(a, b)
  if a.from ~= b.from then return a.from < b.from end
  if a.to ~= b.to then return a.to < b.to end
  if a.kind ~= b.kind then return a.kind < b.kind end
  if a.from_fluidbox ~= b.from_fluidbox then return (a.from_fluidbox or 0) < (b.from_fluidbox or 0) end
  return (a.to_fluidbox or 0) < (b.to_fluidbox or 0)
end

local function graph_sort_edges(F, budget)
  F.seen_edges = nil
  local sorted = sort_step(F, "_sort", F.edges, edge_order, budget)
  if not sorted then return false end
  F.edges = sorted
  F.run_parent, F.run_consumed, F.parent = {}, {}, {}
  return true
end

-- A belt run is the tiles joined by belt_direction edges. Its consumer may
-- pick up anywhere along it (inserter pickup, loader container), so a dead
-- end is decided per run, after every exact edge exists, at its last tile.
local function graph_run_tiles(F, budget)
  return each(F, budget, #F.nodes, LUA_ITEM, function(i)
    local node = F.nodes[i]
    F.parent[node.id] = node.id
    if node._belt_outputs then F.run_parent[node.id] = node.id end
  end)
end

local function graph_run_joins(F, budget)
  return each(F, budget, #F.edges, LUA_ITEM, function(i)
    local edge = F.edges[i]
    if edge.kind == "belt_direction" and F.run_parent[edge.from] and F.run_parent[edge.to] then
      local a, b = run_root(F, edge.from), run_root(F, edge.to)
      if a ~= b then F.run_parent[b] = a end
    end
  end)
end

local function graph_run_consumers(F, budget)
  return each(F, budget, #F.edges, LUA_ITEM, function(i)
    local edge = F.edges[i]
    if edge.kind ~= "belt_direction" and F.run_parent[edge.from] then F.run_consumed[run_root(F, edge.from)] = true end
  end)
end

local function graph_dead_ends(F, budget)
  if not each(F, budget, #F.nodes, LUA_ITEM, function(i)
    local node = F.nodes[i]
    if node._belt_outputs == 0 and not F.run_consumed[run_root(F, node.id)] then
      diagnostic(F, node, "belt_dead_end_without_consumer", nil, "structural", { kind = "belt_or_pickup" })
    end
  end) then return false end
  F.run_parent, F.run_consumed = nil, nil
  return true
end

local function join(F, a, b)
  a, b = root(F, a), root(F, b)
  if a ~= b then F.parent[b] = a end
end

-- Power is a dependency, not a material path: a consumer keeps its own
-- material component and names its network's supply (checked per
-- component below). Generators sharing a network supply it together.
local function graph_joins(F, budget)
  if not each(F, budget, #F.edges, LUA_ITEM, function(i)
    local edge = F.edges[i]
    if edge.kind ~= "electrical_dependency" then join(F, edge.from, edge.to) end
  end) then return false end
  for _, list in pairs(F.generators) do
    for index = 2, #list do join(F, list[1].id, list[index].id) end
  end
  F.by_root, F.component_list = {}, {}
  F.node_by_id, F.incoming, F.outgoing, F.pickup_of, F.edges_of = {}, {}, {}, {}, {}
  return true
end

local function graph_components(F, budget)
  return each(F, budget, #F.nodes, LUA_ITEM, function(i)
    local node = F.nodes[i]
    local r = root(F, node.id)
    local component = F.by_root[r]
    if not component then
      component = { node_ids = {}, roles = {}, status_counts = {}, edge_count = 0,
        products_finished_total = 0, character_transfer_actions = 0, last_character_transfer_tick = nil,
        _edges = {}, _diagnostics = {}, _electrical = {} }
      F.by_root[r] = component
      F.component_list[#F.component_list + 1] = component
    end
    component.node_ids[#component.node_ids + 1] = node.id
    component.roles[node.role] = (component.roles[node.role] or 0) + 1
    component.status_counts[node.status] = (component.status_counts[node.status] or 0) + 1
    component.products_finished_total = component.products_finished_total + (node.products_finished or 0)
    F.node_by_id[node.id], F.incoming[node.id], F.outgoing[node.id], F.edges_of[node.id] = node, {}, {}, {}
  end)
end

local function graph_adjacency(F, budget)
  local by_root = F.by_root
  return each(F, budget, #F.edges, LUA_ITEM, function(i)
    local edge = F.edges[i]
    local from_list, to_list = F.edges_of[edge.from], F.edges_of[edge.to]
    from_list[#from_list + 1] = edge
    if edge.to ~= edge.from then to_list[#to_list + 1] = edge end
    if edge.kind ~= "electrical_dependency" then
      local component = by_root[root(F, edge.from)]
      component.edge_count = component.edge_count + 1
      component._edges[#component._edges + 1] = edge
      F.incoming[edge.to][#F.incoming[edge.to] + 1] = edge.from
      F.outgoing[edge.from][#F.outgoing[edge.from] + 1] = edge.to
      if edge.kind == "inserter_pickup" then F.pickup_of[edge.to] = edge.from end
    else
      -- Electrical dependents outside the supplying component, one edge
      -- (and so one entry) per consumer.
      local supplier = by_root[root(F, edge.from)]
      if by_root[root(F, edge.to)] ~= supplier then supplier._electrical[#supplier._electrical + 1] = edge end
    end
  end)
end

local function graph_transfers(F, budget)
  local events = F.activity.events or {}
  return each(F, budget, #events, LUA_ITEM, function(i)
    local event = events[i]
    if event.target then
      local key = string.format("%s\0%s\0%.17g\0%.17g", event.target.name, event.target.type,
        event.target.position.x, event.target.position.y)
      local node = F.retained[key]
      if node then
        local component = F.by_root[root(F, node.id)]
        component.character_transfer_actions = component.character_transfer_actions + 1
        component.last_character_transfer_tick = math.max(component.last_character_transfer_tick or 0,
          tonumber(event.tick) or 0)
      end
    end
  end)
end

local function graph_sort_components(F, budget)
  local sorted = sort_step(F, "_sort", F.component_list, function(a, b) return a.node_ids[1] < b.node_ids[1] end, budget)
  if not sorted then return false end
  F.components, F.component_list, F.source_by_resource = sorted, nil, {}
  return true
end

local function graph_sources(F, budget)
  if not each(F, budget, #F.nodes, LUA_ITEM, function(i)
    local node = F.nodes[i]
    local source = node._source_production
    if source and source.resource_key then
      local previous = F.source_by_resource[source.resource_key]
      if previous then
        diagnostic(F, previous, "shared_mining_target_production_ambiguous", "ambiguous")
        diagnostic(F, node, "shared_mining_target_production_ambiguous", "ambiguous")
      else F.source_by_resource[source.resource_key] = node end
    end
  end) then return false end
  F.source_by_resource = nil
  return true
end

-- Graph walks (pure Lua). Each returns how many nodes it visited as its
-- last value, which the caller charges.
local function product_matches(node, ingredient, fuel_only)
  for _, product in ipairs(node.products or {}) do
    if fuel_only and product.fuel_category and ingredient[product.fuel_category] then return true end
    if not fuel_only and product.name == ingredient.name and product.type == ingredient.type then return true end
  end
  return false
end

local function upstream_proven(F, start_id, ingredient, fuel_only)
  local queue, seen, head = {}, { [start_id] = true }, 1
  for _, id in ipairs(F.incoming[start_id]) do queue[#queue + 1] = id end
  while head <= #queue do
    local id = queue[head]; head = head + 1
    -- A burner source may physically refuel itself from its own output
    -- (a coal drill feeding back through transport): that loop is fuel
    -- provenance. Its own product never stands in for another input.
    if id == start_id and fuel_only and F.node_by_id[id].role == "source"
      and product_matches(F.node_by_id[id], ingredient, true) then return true, head end
    if not seen[id] then
      seen[id] = true
      local node = F.node_by_id[id]
      if node and node.role ~= "buffer" and product_matches(node, ingredient, fuel_only) then return true, head end
      -- A processor transforms its inputs; an ancestor's product cannot
      -- stand in for this node's different physical output.
      if node and (node.role == "transport" or node.role == "buffer") then
        for _, parent_id in ipairs(F.incoming[id] or {}) do queue[#queue + 1] = parent_id end
      end
    end
  end
  return false, head
end

local function reaches_downstream(F, start_id)
  local queue, seen, head = { start_id }, {}, 1
  while head <= #queue do
    local id = queue[head]; head = head + 1
    if not seen[id] then
      seen[id] = true
      local node = F.node_by_id[id]
      if id ~= start_id and node and (node.role == "sink" or node._downstream_buffer) then return true, head end
      for _, next_id in ipairs(F.outgoing[id] or {}) do queue[#queue + 1] = next_id end
    end
  end
  return false, head
end

-- The nodes a node's output reaches first, through transport only.
local function first_reached(F, start_id)
  local reached, queue, seen, head = {}, { start_id }, { [start_id] = true }, 1
  while head <= #queue do
    local id = queue[head]; head = head + 1
    for _, next_id in ipairs(F.outgoing[id] or {}) do
      local next_node = F.node_by_id[next_id]
      if not seen[next_id] and next_node then
        seen[next_id] = true
        if next_node.role == "transport" and not (next_node.type == "inserter" and F.pickup_of[next_id] ~= id) then
          queue[#queue + 1] = next_id
        else reached[#reached + 1] = next_node end
      end
    end
  end
  return reached, head
end

local function ancestors(F, start_id)
  local queue, seen, head = { start_id }, {}, 1
  while head <= #queue do
    local id = queue[head]; head = head + 1
    for _, parent_id in ipairs(F.incoming[id] or {}) do
      if not seen[parent_id] then seen[parent_id] = true; queue[#queue + 1] = parent_id end
    end
  end
  return seen, head
end

-- A burner takes these products only as fuel: one burns in its
-- categories and none is a recipe ingredient that could be material input.
local function fuel_inlet(products, target)
  if not target.requires_fuel or (target.role ~= "source" and target.role ~= "processor"
    and target.type ~= "inserter") then return false end
  local fuel = false
  for _, product in pairs(products) do
    if product.fuel_category and (target.fuel_categories or {})[product.fuel_category] then fuel = true end
    for _, ingredient in ipairs(target.ingredients or {}) do
      if ingredient.type == product.type and ingredient.name == product.name then return false end
    end
  end
  return fuel
end

-- Whether a producer upstream through transport and buffers makes
-- something that is not fuel: material that will give a furnace that has
-- not smelted yet its recipe.
local function material_upstream(F, start_id)
  local queue, seen, head = {}, { [start_id] = true }, 1
  for _, id in ipairs(F.incoming[start_id]) do queue[#queue + 1] = id end
  while head <= #queue do
    local id = queue[head]; head = head + 1
    local node = F.node_by_id[id]
    if node and not seen[id] then
      seen[id] = true
      if node.role == "source" or node.role == "processor" then
        for _, product in ipairs(node.products) do if not product.fuel_category then return true, head end end
      elseif node.role == "transport" or node.role == "buffer" then
        for _, parent_id in ipairs(F.incoming[id] or {}) do queue[#queue + 1] = parent_id end
      end
    end
  end
  return false, head
end

-- The products that physically reach a node: its own when it produces,
-- otherwise its producers' through transport, buffers and labs (an
-- inserter relays a lab's packs into the next lab of a chain).
local function upstream_products(F, start_id)
  local products, queue, seen, head = {}, { start_id }, {}, 1
  while head <= #queue do
    local id = queue[head]; head = head + 1
    if not seen[id] then
      seen[id] = true
      local upstream = F.node_by_id[id]
      if upstream.role == "source" or upstream.role == "processor" then
        for _, product in ipairs(upstream.products) do products[product.type .. ":" .. product.name] = product end
      elseif upstream.type == "inserter" then
        -- Another inserter drops into this burner's fuel inventory, never
        -- its hand. Only the pickup target supplies cargo relayed onward.
        if F.pickup_of[id] then queue[#queue + 1] = F.pickup_of[id] end
      elseif upstream.role == "transport" or upstream.role == "buffer" or upstream.type == "lab" or id == start_id then
        for _, parent_id in ipairs(F.incoming[id]) do queue[#queue + 1] = parent_id end
      end
    end
  end
  return products, head
end

-- Walk lengths are charged at this many nodes per work item.
local WALK_NODES_PER_ITEM = 16

-- A replenishment inserter may wait at the ordinary fuel target while
-- the burner continues working and its fuel inventory still has space.
-- Prove the specific held fuel and physical supply, never infer a limit
-- from a hard-coded stock count or exempt other full-output entities.
local function fuel_return(F, node, budget)
  local pickup, destination
  for _, edge in ipairs(F.edges_of[node.id]) do
    if edge.from == node.id and edge.kind == "inserter_drop" then destination = F.node_by_id[edge.to] end
    if edge.to == node.id and edge.kind == "inserter_pickup" then pickup = F.node_by_id[edge.from] end
  end
  if not (pickup and destination and destination._fuel_destination_proven
    and destination.requires_fuel and destination.status == "working") then return end
  budget.left = budget.left - 12
  local ok, fuel, quality, identity = pcall(function()
    local held = node._entity.held_stack
    local burner = destination._entity.burner
    -- Factorio 2.0 ItemIDAndQualityIDPair: name and quality are prototypes.
    local burning = burner.currently_burning
    if not burning or type(burning.name.name) ~= "string" or type(burning.quality.name) ~= "string"
      or not destination.fuel_categories[item_fuel_category(burning.name.name)]
      or not (burner.remaining_burning_fuel > 0) then return end
    local inventory = destination._entity.get_fuel_inventory()
    local name, quality_name, identity_source
    if held.valid_for_read == true then
      if held.count <= 0 then return end
      name, quality_name, identity_source = held.name, held.quality.name, "held_stack"
    elseif held.valid_for_read == false then
      -- An empty stack's identity is unreadable; require one stocked
      -- pair matching the burning pair (inventory contents carry names).
      local contents = inventory.get_contents()
      if type(contents) ~= "table" or #contents ~= 1 then return end
      for index in pairs(contents) do if index ~= 1 then return end end
      local stock = contents[1]
      if type(stock) ~= "table" or type(stock.count) ~= "number" or stock.count <= 0
        or stock.name ~= burning.name.name or stock.quality ~= burning.quality.name then return end
      name, quality_name, identity_source = stock.name, stock.quality, "burning_and_stocked_fuel"
    else return end
    if type(name) ~= "string" or name == "" or type(quality_name) ~= "string" or quality_name == "" then return end
    local category = item_fuel_category(name)
    if not category or not destination.fuel_categories[category] then return end
    -- A fuel that is also a recipe ingredient could be waiting on
    -- material input instead; the destination compartment is ambiguous.
    for _, ingredient in ipairs(destination.ingredients) do
      if ingredient.type == "item" and ingredient.name == name then return end
    end
    local item = { name = name, quality = quality_name, count = 1 }
    if inventory.get_item_count({ name = item.name, quality = item.quality }) > 0
      and inventory.can_insert(item) == true then
      return name, quality_name, identity_source
    end
  end)
  local product = { name = fuel, type = "item" }
  local supplied, visited = false, 0
  if pickup.role == "source" or pickup.role == "processor" then
    supplied = product_matches(pickup, product, false)
  elseif pickup.role == "transport" or pickup.role == "buffer" then
    supplied, visited = upstream_proven(F, pickup.id, product, false)
  end
  budget.left = budget.left - math.ceil(visited / WALK_NODES_PER_ITEM)
  if ok and fuel and supplied then
    node.fuel_return_saturation = { destination_node_id = destination.id, fuel = fuel, quality = quality,
      identity_source = identity, observed_status = "waiting_for_space_in_destination",
      evidence = "supplied_working_burner_with_fuel_inventory_space" }
  end
end

local function flow_fuel(F, budget)
  return each(F, budget, #F.nodes, 1, function(i)
    local node = F.nodes[i]
    if node.type == "inserter" and node._waiting_for_destination and node._entity.valid then fuel_return(F, node, budget) end
  end)
end

-- Which buffers and sinks are terminal, accept what reaches them, or block.
local function buffer_or_sink(F, node, budget)
  local products, visited = upstream_products(F, node.id)
  budget.left = budget.left - math.ceil(visited / WALK_NODES_PER_ITEM)
  -- A buffer is terminal when nothing leaves it, or when everything that
  -- leaves only refuels producers upstream of it: a self-fuelling loop's
  -- chest is where its surplus ends, not an intermediate stage.
  node._downstream_buffer = false
  if node.role == "buffer" then
    local reached, walked = first_reached(F, node.id)
    local upstream = nil
    budget.left = budget.left - math.ceil(walked / WALK_NODES_PER_ITEM)
    node._downstream_buffer = #F.outgoing[node.id] == 0 or #reached > 0
    for _, target in ipairs(reached) do
      if not upstream then
        upstream, walked = ancestors(F, node.id)
        budget.left = budget.left - math.ceil(walked / WALK_NODES_PER_ITEM)
      end
      if not (upstream[target.id] and fuel_inlet(products, target)) then node._downstream_buffer = false end
    end
  end
  budget.left = budget.left - 4
  -- A lab waiting for science packs consumes only when the line supplies
  -- every pack its current research needs; otherwise it never starts.
  -- Any lab with research in progress, whatever its status, needs that
  -- supply: hand-stocked packs only defer the wait.
  local lab_waiting = node.type == "lab" and node._raw_status == "missing_science_packs"
  if node.type == "lab" and node._raw_status ~= "no_research_in_progress" then
    local ok, ingredients = pcall(function() return node._entity.force.current_research.research_unit_ingredients end)
    local readable = ok and type(ingredients) == "table" and next(ingredients) ~= nil
    if not readable then lab_waiting = false end
    for _, ingredient in pairs(readable and ingredients or {}) do
      if type(ingredient) ~= "table" or not products[(ingredient.type or "item") .. ":" .. tostring(ingredient.name)] then
        lab_waiting, node._missing_science_pack = false, true
      end
    end
  end
  node._accepting = next(products) ~= nil and (node.role == "buffer" or node.status == "working" or lab_waiting)
  for _, product in pairs(products) do
    budget.left = budget.left - 2
    -- Unsupported fluid endpoints remain unproven rather than guessing capacity.
    local ok, count, accepting = pcall(function()
      if product.type == "fluid" then
        if not node._fluid_supported or (node.type ~= "generator" and node.type ~= "storage-tank") then
          error("unsupported fluid endpoint acceptance")
        end
        local box = node._fluid_boxes[1]
        local temperature = box.temperature or product.temperature
        local compatible = fluid_compatible(box, product.name, temperature)
        if node.type == "generator" then
          -- An engine that generated last tick consumed steam then; a
          -- pump refills its own segment to exactly full after that.
          return 0, compatible and (box.segment_amount < box.segment_capacity
              or (number_property(node._entity, "energy_generated_last_tick") or 0) > 0) and box.amount > 0
            and type(box.temperature) == "number" and box.temperature > node._generator.default_temperature
        end
        return box.amount, compatible and box.segment_amount < box.segment_capacity
      end
      local inventory
      if node.role == "buffer" then inventory = node._entity.get_inventory(defines.inventory.chest)
      elseif node.type == "lab" then inventory = node._entity.get_inventory(defines.inventory.lab_input)
      elseif node.type == "burner-generator" then inventory = node._entity.get_fuel_inventory()
      else error("unsupported consumer acceptance") end
      if node.role == "sink" then return 0, inventory.can_insert({ name = product.name, count = 1 }) end
      return inventory.get_item_count(product.name), inventory.can_insert({ name = product.name, count = 1 })
    end)
    if not ok or type(count) ~= "number" or type(accepting) ~= "boolean" then
      node._accepting = false
      diagnostic(F, node, node.role == "buffer" and "downstream_buffer_acceptance_unproven"
        or "downstream_consumer_acceptance_unproven", "unsupported")
    else
      -- A full intermediate buffer is ordinary backpressure; only a
      -- terminal endpoint that refuses the item proves blocked output.
      if not accepting then
        node._accepting = false
        if node._downstream_buffer or (node.role == "sink" and not node._standby) then node._blocked_output = true end
      end
    end
  end
end

local function flow_buffers(F, budget)
  return each(F, budget, #F.nodes, 1, function(i)
    local node = F.nodes[i]
    if node.role == "buffer" or node.role == "sink" then buffer_or_sink(F, node, budget) end
  end)
end

-- Diagnostics in order, each on its component.
local function diagnostic_order(a, b)
  return a.node_id == b.node_id and a.reason < b.reason or a.node_id < b.node_id
end

local function diagnostics_mark(F, budget)
  return each(F, budget, #F.diagnostics, LUA_ITEM, function(i)
    local row = F.diagnostics[i]
    if row.reason == "downstream_inventory_blocked" and F.node_by_id[row.node_id].fuel_return_saturation then
      row.nonblocking_reason = "proven_fuel_return_saturation"
    end
  end)
end

local function diagnostics_sort(F, budget)
  local sorted = sort_step(F, "_sort", F.diagnostics, diagnostic_order, budget)
  if not sorted then return false end
  F.diagnostics = sorted
  return true
end

local function diagnostics_assign(F, budget)
  return each(F, budget, #F.diagnostics, LUA_ITEM, function(i)
    local row = F.diagnostics[i]
    local component = F.by_root[root(F, row.node_id)]
    component._diagnostics[#component._diagnostics + 1] = row
  end)
end

-- A component's signature is an order-independent sum of its rows' hashes,
-- so each row is hashed as it is made and no whole-component string is
-- built or sorted.
local HASH_P1, HASH_P2 = 4294967291, 4294967279
local HASH_BYTES_PER_ITEM = 16
local function sign(C, row, budget)
  local h1, h2 = 0, 0
  for index = 1, #row do
    local byte = row:byte(index)
    h1, h2 = (h1 * 31 + byte) % HASH_P1, (h2 * 37 + byte) % HASH_P2
  end
  C.h1, C.h2 = (C.h1 + h1) % HASH_P1, (C.h2 + h2) % HASH_P2
  budget.left = budget.left - math.ceil((#row + 1) / HASH_BYTES_PER_ITEM)
end

-- Every row is located at the node where a repair or inspection starts.
-- Transient rows are single status samples and never gate topology.
local function block(C, node, reason, class, related_edge, gate)
  C.rows[#C.rows + 1] = { reason = reason, class = class, node_id = node.id, position = node.position,
    entity = node.name, related_edge = related_edge, gate = gate }
end

-- One node's share of its component's state and signature.
local function component_node(F, C, id, budget)
  local node = F.node_by_id[id]
  local walked = 0
  local function walk(found, visited)
    walked = walked + (visited or 0)
    return found
  end
  if FLUID_TYPES[node.type] or node._power_consumer then
    sign(C, node._key .. ":network:" .. tostring(node._power_network), budget)
    if node._generator then
      for _, field in ipairs({ "default_temperature", "heat_capacity", "effectivity", "maximum_temperature" }) do
        sign(C, node._key .. ":generator:" .. field .. ":" .. tostring(node._generator[field]), budget)
      end
    end
  end
  sign(C, node._key .. ":" .. tostring(node.direction) .. ":"
    .. tostring(node._unit) .. ":" .. tostring(node.recipe), budget)
  for _, box in ipairs(node._fluid_boxes or {}) do
    sign(C, table.concat({ node._key, "box", tostring(box.index),
      tostring(box.segment), tostring(box.production_type), tostring(box.filter), tostring(box.name),
      tostring(box.minimum_temperature), tostring(box.maximum_temperature), tostring(box.capacity) }, ":"), budget)
  end
  for _, connection in ipairs(node._fluid_connections or {}) do
    sign(C, table.concat({ node._key, "connection",
      tostring(connection.fluidbox_index), tostring(connection._pipe_connection_index),
      tostring(connection.connection_type), tostring(connection.flow_direction),
      tostring(connection.position.x), tostring(connection.position.y),
      tostring(connection.target_position.x), tostring(connection.target_position.y),
      tostring(connection._target_key), tostring(connection._target_fluidbox_index),
      tostring(connection._target_pipe_connection_index) }, ":"), budget)
  end
  for _, product in ipairs(node.products) do
    if product.type == "fluid" then sign(C, node._key .. ":temperature:" .. tostring(product.temperature), budget) end
  end
  for _, ingredient in ipairs(node.ingredients) do sign(C, node._key .. ":input:" .. ingredient.type .. ":" .. ingredient.name, budget) end
  for _, product in ipairs(node.products) do sign(C, node._key .. ":output:" .. product.type .. ":" .. product.name, budget) end
  if node.role == "sink" then
    C.consumers = C.consumers + 1
    -- A lab with no research selected consumes nothing until one is.
    if node.type == "lab" and node._raw_status == "no_research_in_progress" then
      block(C, node, "consumer_idle_no_research", "evidence", nil, "readiness")
    elseif node._missing_science_pack then
      block(C, node, "consumer_missing_required_science_pack", "evidence", nil, "readiness")
    end
    C.endpoints[#C.endpoints + 1] = node
  elseif node._downstream_buffer then
    C.buffers = C.buffers + 1
    C.endpoints[#C.endpoints + 1] = node
    if node._accepting then C.accepting_sinks = C.accepting_sinks + 1 end
  end
  -- Only an inventory that cannot accept the item proves blocked output.
  if node._blocked_output then C.blocked_output = true; block(C, node, "blocked_output", "structural") end
  if node.role == "source" or node.role == "processor" then
    C.producing_nodes = C.producing_nodes + 1
    if node.role == "source" and not node._source_production.working then
      block(C, node, "source_not_locally_operating", "transient")
    end
    -- A furnace before its first smelt has no recipe yet: with material
    -- arriving from upstream, that is a later start, not a defect.
    if #node.products == 0 and node.type == "furnace" and walk(material_upstream(F, id)) then
      block(C, node, "furnace_recipe_not_yet_established", "evidence", { kind = "material_input" }, "readiness")
    elseif #node.products == 0 then block(C, node, "output_identity_unproven", "structural") end
    if not walk(reaches_downstream(F, id)) then
      C.unreached[#C.unreached + 1] = node
      if node._output_pending then
        block(C, node, "drill_output_target_pending_first_output", "evidence", { kind = "machine_output" }, "readiness")
      else
        block(C, node, "downstream_acceptance_path_unproven", "structural",
          { kind = "downstream_path" }, "readiness")
      end
    end
  end
  if node.role == "sink" and node._accepting then C.accepting_sinks = C.accepting_sinks + 1 end
  for _, ingredient in ipairs(node.ingredients or {}) do
    if not walk(upstream_proven(F, id, ingredient, false)) then
      block(C, node, "material_input_provenance_unresolved:" .. ingredient.type .. ":" .. ingredient.name, "structural",
        { kind = "material_input" })
    end
  end
  if node.requires_fuel and not walk(upstream_proven(F, id, node.fuel_categories or {}, true)) then
    local related_edge = { kind = "fuel_input" }
    -- A burner inserter refuels only from fuel it carries. When its
    -- produced cargo is known and none of it burns here, say so: it needs
    -- a fuel feed of its own.
    if node.role == "transport" then
      local cargo = walk(upstream_products(F, id))
      if next(cargo) then
        related_edge.transport_cargo_fuel = false
        for _, product in pairs(cargo) do
          if product.fuel_category and (node.fuel_categories or {})[product.fuel_category] then
            related_edge.transport_cargo_fuel = nil
          end
        end
      end
    end
    block(C, node, next(node.fuel_categories or {}) and "fuel_input_provenance_unresolved" or "fuel_compatibility_unproven",
      "structural", related_edge, "readiness")
  end
  if node.status == "no_power" or node.status == "low_power" or node.status == "no_fuel"
    or node.status == "insufficient_input" or node.status == "full_output" and not node.fuel_return_saturation
    or node.status == "disabled" or node.status == "no_resources" then
    block(C, node, "nonproductive_status:" .. node.status, status_class(node))
  end
  budget.left = budget.left - math.ceil(walked / WALK_NODES_PER_ITEM)
end

-- A component's signature rows from its edges and electrical dependents
-- (and each dependent's own edges), a budget at a time: true once done.
local function component_edges(F, component, C, budget)
  while C.edge <= #component._edges do
    if budget.left <= 0 then return false end
    local edge = component._edges[C.edge]
    sign(C, F.node_by_id[edge.from]._key .. "->" .. F.node_by_id[edge.to]._key .. ":" .. edge.kind .. ":"
      .. tostring(edge.from_fluidbox) .. ":" .. tostring(edge.to_fluidbox), budget)
    C.edge = C.edge + 1
  end
  -- Electrical dependents are part of the supplying component's identity
  -- without joining their material paths.
  while C.dependent <= #component._electrical do
    if budget.left <= 0 then return false end
    local node = F.node_by_id[component._electrical[C.dependent].to]
    sign(C, table.concat({ "electrical-dependent", node._key,
      tostring(node._unit), tostring(node._power_network), tostring(node.direction) }, ":"), budget)
    for _, connection in ipairs(F.edges_of[node.id]) do
      sign(C, table.concat({ "electrical-dependent-connection", connection.kind,
        F.node_by_id[connection.from]._key, F.node_by_id[connection.to]._key }, ":"), budget)
    end
    C.dependent = C.dependent + 1
  end
  return true
end

-- Calls fn(row) for each row of list from C.i on while the budget lasts:
-- true once all are done.
local function component_each(C, budget, list, fn)
  local i = C.i or 1
  while i <= #list do
    if budget.left <= 0 then C.i = i; return false end
    budget.left = budget.left - LUA_ITEM
    fn(list[i])
    i = i + 1
  end
  C.i = nil
  return true
end

-- Hard rows in presentation order: readiness rows first, then by position.
local function hard_order(a, b)
  if (a.gate == "readiness") ~= (b.gate == "readiness") then return a.gate == "readiness" end
  if a.position.y ~= b.position.y then return a.position.y < b.position.y end
  if a.position.x ~= b.position.x then return a.position.x < b.position.x end
  return a.reason < b.reason
end

-- Keeps C.best the first MAX_COMPONENT_BLOCKER_DETAILS hard rows at
-- distinct sites, as a full sort would list them, without sorting them all.
local function keep_detail(C, row)
  local key = string.format("%.17g\0%.17g", row.position.x, row.position.y)
  local best = C.best
  for index, kept in ipairs(best) do
    if kept.key == key then
      if hard_order(row, kept.row) then best[index] = { key = key, row = row } else return end
      table.sort(best, function(a, b) return hard_order(a.row, b.row) end)
      return
    end
  end
  if #best < MAX_COMPONENT_BLOCKER_DETAILS then best[#best + 1] = { key = key, row = row }
  elseif hard_order(row, best[#best].row) then best[#best] = { key = key, row = row }
  else return end
  table.sort(best, function(a, b) return hard_order(a.row, b.row) end)
end

-- The component's rows and state, a budget at a time: true once done.
local function component_finish(F, component, C, budget)
  if C.phase == 1 then
    if not component_each(C, budget, component._diagnostics, function(row)
      local node = F.node_by_id[row.node_id]
      if row.reason ~= "downstream_inventory_blocked" or not node.fuel_return_saturation then
        block(C, node, "relationship_diagnostic:" .. row.reason, row.class, row.related_edge)
      end
    end) then return false end
    -- Component-level gaps attach to the producers lacking a downstream
    -- path, or to the component's first node when no producer can carry the row.
    C.anchors = #C.unreached > 0 and C.unreached or { F.node_by_id[component.node_ids[1]] }
    C.phase = 2
  end
  if C.phase == 2 then
    if C.producing_nodes == 0 or (component.roles.source or 0) == 0 or C.buffers + C.consumers == 0 then
      if not component_each(C, budget, C.anchors, function(node)
        block(C, node, "physical_source_downstream_path_unproven", "structural", { kind = "downstream_path" }, "readiness")
      end) then return false end
    end
    C.phase = 3
  end
  if C.phase == 3 then
    if C.accepting_sinks == 0 then
      if not component_each(C, budget, #C.endpoints > 0 and C.endpoints or C.anchors, function(node)
        block(C, node, "downstream_acceptance_not_observed", "transient")
      end) then return false end
    end
    C.phase, C.best, C.blocker_names, C.seen_blocker, C.hard_rows = 4, {}, {}, {}, 0
  end
  if not component_each(C, budget, C.rows, function(row)
    if row.class ~= "transient" then
      C.hard_rows = C.hard_rows + 1
      if not C.seen_blocker[row.reason] then C.seen_blocker[row.reason] = true; C.blocker_names[#C.blocker_names + 1] = row.reason end
      keep_detail(C, row)
    end
  end) then return false end
  table.sort(C.blocker_names)
  -- One compact row per distinct site; every name stays in autonomy_blockers.
  local details = {}
  for _, kept in ipairs(C.best) do
    local row = kept.row
    details[#details + 1] = { reason = row.reason, class = row.class, position = row.position,
      entity = row.entity, related_edge = row.related_edge }
  end
  component.component_signature = string.format("%08x%08x", C.h1, C.h2)
  component.state = {
    downstream_kind = C.buffers > 0 and (C.consumers > 0 and "mixed" or "buffer") or (C.consumers > 0 and "consumer" or "none"),
    blocked_output = C.blocked_output,
    machine_present = true,
    locally_operating = (component.status_counts.working or 0) > 0,
    autonomy_topology_ready = C.hard_rows == 0,
    autonomy_blockers = C.blocker_names,
    blocker_details = details,
  }
  return true
end

-- Components one at a time, their nodes, signature rows and blocker rows a
-- budget's worth per tick.
local function flow_components(F, budget)
  while true do
    local index = F.component_index or 1
    local component = F.components[index]
    if not component then
      F.component_index, F.current = nil, nil
      return true
    end
    local C = F.current
    if not C then
      component.component_id = "component-" .. index
      C = { rows = {}, producing_nodes = 0, accepting_sinks = 0, buffers = 0, consumers = 0,
        blocked_output = false, unreached = {}, endpoints = {}, node = 1, edge = 1, dependent = 1,
        h1 = 0, h2 = 0, phase = 1 }
      F.current = C
    end
    while C.node <= #component.node_ids do
      if budget.left <= 0 then return false end
      budget.left = budget.left - 2
      component_node(F, C, component.node_ids[C.node], budget)
      C.node = C.node + 1
    end
    if not component_edges(F, component, C, budget) then return false end
    if not component_finish(F, component, C, budget) then return false end
    F.current, F.component_index = nil, index + 1
  end
end

-- The finished graph, as the presentation reads it.
local function flow_result(F)
  return { nodes = F.nodes, edges = F.edges, components = F.components, diagnostics = F.diagnostics,
    relationship_semantics = "exact_runtime_targets_only; absence_or_unsupported_is_not_a_connection" }
end

-- Stages in order; each returns true once done.
local FLOW_STAGES = {
  flow_sort_nodes, flow_prepare, flow_links, flow_generators, flow_consumers, flow_demand, flow_standby,
  graph_sort_edges, graph_run_tiles, graph_run_joins, graph_run_consumers, graph_dead_ends, graph_joins,
  graph_components, graph_adjacency, graph_transfers, graph_sort_components, graph_sources,
  flow_fuel, flow_buffers, diagnostics_mark, diagnostics_sort, diagnostics_assign, flow_components,
}

-- Advances the material flow; true once the graph is complete.
local function flow_step(F, budget)
  while F.stage <= #FLOW_STAGES do
    if budget.left <= 0 then return false end
    if not FLOW_STAGES[F.stage](F, budget) then return false end
    F.stage, F.cursor = F.stage + 1, nil
  end
  return true
end

-- Caps are a presentation concern. Never mutate the graph itself.
local function present_flow(flow, omissions, surface_index)
  local result = { relationship_semantics = flow.relationship_semantics }
  for _, field in ipairs({ "nodes", "edges", "components", "diagnostics" }) do
    result[field] = {}
    local limit = field == "components" and MAX_FLOW_COMPONENTS
      or (field == "edges" or field == "diagnostics") and MAX_FLOW_EDGES or MAX_FLOW_NODES
    for i = 1, math.min(limit, #flow[field]) do
      local row = {}; for key, value in pairs(flow[field][i]) do
        if key:sub(1, 1) ~= "_" and key ~= "ingredients" and key ~= "products" and key ~= "requires_fuel" and key ~= "fuel_categories" then row[key] = value end
      end
      if field == "components" then
        row.node_count = #row.node_ids
        row.node_ids = { table.unpack(row.node_ids, 1, math.min(MAX_FLOW_NODES, #row.node_ids)) }
        row.omitted_node_ids = row.node_count - #row.node_ids
        local state = {}; for key, value in pairs(row.state) do state[key] = value end
        state.autonomy_blockers = { table.unpack(state.autonomy_blockers, 1, math.min(MAX_FLOW_EDGES, #state.autonomy_blockers)) }
        state.omitted_autonomy_blockers = #row.state.autonomy_blockers - #state.autonomy_blockers
        row.state = state
      end
      result[field][#result[field] + 1] = row
    end
  end
  -- Whole-graph counters beside the capped rows, so a recorder never
  -- measures the factory from the presented subset.
  result.component_count, result.edge_count = #flow.components, #flow.edges
  result.products_finished_total = 0
  for _, component in ipairs(flow.components) do
    result.products_finished_total = result.products_finished_total + component.products_finished_total
  end
  -- Production lines the mod tracks on this surface (autonomy.lua), beside
  -- the components.
  for key, value in pairs(autonomy.counts(surface_index)) do result[key] = value end
  omissions.capped_flow_nodes = #flow.nodes - #result.nodes
  omissions.capped_flow_edges = #flow.edges - #result.edges
  omissions.capped_flow_components = #flow.components - #result.components
  omissions.capped_edge_diagnostics = #flow.diagnostics - #result.diagnostics
  return result
end

-- Player-parity sections, computed only when map_summary names them in
-- `include`. They read what a player's map, production and electric-network
-- views show: own-force entities and resources in chunks the force has already
-- charted on the character's surface. Every section is capped and counts what
-- it left out. Reading is not reach: acting on any of it still needs the body.
local INCLUDE_SECTIONS = { stockpiles = true, sites = true, patches = true, power = true,
  problems = true, flows_all = true }
local MAX_STOCK_ITEMS, MAX_STOCK_HOLDERS = 64, 8
local MAX_SITES, MAX_PATCHES, MAX_POWER_NETWORKS, MAX_PROBLEMS, MAX_FLOWS_ALL = 256, 64, 32, 64, 256
local SITE_TYPES = {
  ["mining-drill"] = true, furnace = true, ["assembling-machine"] = true, lab = true,
  boiler = true, generator = true, ["burner-generator"] = true, reactor = true,
  ["offshore-pump"] = true, pump = true, ["rocket-silo"] = true,
}
local CHEST_TYPES = { container = true, ["logistic-container"] = true }
local OUTPUT_TYPES = { furnace = true, ["assembling-machine"] = true, ["rocket-silo"] = true }
local BELT_TYPES = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
  loader = true, ["loader-1x1"] = true, ["linked-belt"] = true }
local STOCK_TYPE_NAMES = {}
for _, types in ipairs({ CHEST_TYPES, OUTPUT_TYPES, BELT_TYPES }) do
  for name in pairs(types) do STOCK_TYPE_NAMES[#STOCK_TYPE_NAMES + 1] = name end
end
table.sort(STOCK_TYPE_NAMES)
local PROBLEM_STATUSES = {
  no_power = true, low_power = true, not_plugged_in_electric_network = true, no_fuel = true,
  full_output = true, no_minable_resources = true, no_ingredients = true,
  item_ingredient_shortage = true, fluid_ingredient_shortage = true,
}
-- Dead machines first, blocked ones next. Input waits are routine in a working
-- factory and sort last so they cannot evict the others from the row cap.
local PROBLEM_RANK = { no_power = 1, not_plugged_in_electric_network = 1, no_fuel = 1,
  no_minable_resources = 2, full_output = 2, low_power = 2 }
local INPUT_WAIT_RANK = 3

local function parse_include(include)
  local want = {}
  if include == nil then return want end
  if type(include) ~= "table" then error("map_summary include must be an array of section names") end
  for _, name in ipairs(include) do
    if not INCLUDE_SECTIONS[name] then error("unsupported map_summary include: " .. tostring(name)) end
    want[name] = true
  end
  return want
end

local function xy(position) return { x = position.x, y = position.y } end

local function row_position(a, b)
  if a.position.y ~= b.position.y then return a.position.y < b.position.y end
  if a.position.x ~= b.position.x then return a.position.x < b.position.x end
  return a.entity < b.entity
end

-- What can be taken: a chest's contents or a crafting machine's output.
-- Mining drills have no output inventory (native returns nil).
local function stock_inventory(entity)
  local ok, inventory = pcall(function()
    if CHEST_TYPES[entity.type] then return entity.get_inventory(defines.inventory.chest) end
    return entity.get_output_inventory()
  end)
  if ok then return inventory end
  return nil
end

local function belt_lines(entity)
  local lines, max_index = {}, 2
  pcall(function() max_index = entity.get_max_transport_line_index() end)
  for index = 1, max_index do
    local ok, line = pcall(entity.get_transport_line, index)
    if ok and line then lines[#lines + 1] = line end
  end
  return lines
end

-- Inventories and transport lines both return an array of {name, quality, count}.
-- Contents by item key (a non-normal quality is "name@quality").
local function add_contents(bucket, source)
  local ok, contents = pcall(function() return source.get_contents() end)
  if not ok or type(contents) ~= "table" then return end
  for _, row in ipairs(contents) do
    if type(row) == "table" and type(row.name) == "string" then
      local key = items.key(row.name, row.quality)
      bucket[key] = (bucket[key] or 0) + (tonumber(row.count) or 0)
    end
  end
end

-- Resource entities are bucketed per chunk while the charted chunks are
-- scanned; a patch is the same resource across touching (8-neighbour) chunks.
-- That is coarser than tile adjacency but needs no per-tile work.
local function add_patch_resource(cells, entity)
  local cx, cy = math.floor(entity.position.x / 32), math.floor(entity.position.y / 32)
  local by_name = cells[entity.name] or {}
  cells[entity.name] = by_name
  local key = cx .. "," .. cy
  local cell = by_name[key]
  local x, y = entity.position.x, entity.position.y
  if not cell then
    cell = { cx = cx, cy = cy, amount = 0, tiles = 0, x = 0, y = 0, left = x, right = x, top = y, bottom = y }
    by_name[key] = cell
  end
  cell.amount, cell.tiles = cell.amount + (tonumber(entity.amount) or 0), cell.tiles + 1
  cell.x, cell.y = cell.x + x, cell.y + y
  cell.left, cell.right = math.min(cell.left, x), math.max(cell.right, x)
  cell.top, cell.bottom = math.min(cell.top, y), math.max(cell.bottom, y)
end

-- ------------------------------------------------------------ power rows
-- One row per electric network on a surface (factory_status power and
-- map_summary include power), from the registry's network aggregates (no
-- entity walk), with one statistics read for each network the limit keeps:
--   production_w   the five-second average of the network's native
--                  electric_network_statistics output rows (joules a tick,
--                  times 60), accumulator discharge included
--   demand_w       nominal usage of the consumers trying to run (working,
--                  low_power or no_power), as the registry's cursor last read
--   satisfaction   1 while no consumer reads low_power or no_power, else
--                  min(1, production_w / demand_w)
--   capacity_w     available now: non-solar nameplate plus solar nameplate x
--                  the surface's solar factor x light now
--   sustained_w    the day average: solar at its average light (planets)
--   headroom_w     sustained_w - demand_w
--   sources        per kind (steam, nuclear, solar, burner, other): count,
--                  nameplate_w and the production_w the statistics name
--   accumulators   count, stored_j, capacity_j, charge (or nil)
--   night_s        dark seconds a day on this surface (planets)
--   add_to_cover   only while sustained_w < demand_w: steam engines for a
--                  steam network, else solar panels for the average and the
--                  accumulators that carry the night deficit of those panels
-- The solar factor is the surface's "solar-power" property / 100 times its
-- solar_power_multiplier. Light (daytime 0 is noon) is full outside
-- dusk..dawn, falls linearly from dusk to evening, is zero to morning and
-- rises to dawn; always_day is full light. On a platform surface solar
-- capacity is its measured production and there is no day average.
local STEAM_ENGINE_WATTS = 900000
local ACCUMULATOR_JOULES = 5000000
local LIGHT_SAMPLES = 100

local function prototype_watts(name, fallback)
  local ok, watts = pcall(function() return prototypes.entity[name].get_max_energy_production("normal") * 60 end)
  return ok and type(watts) == "number" and watts > 0 and watts or fallback
end

local function prototype_buffer(name)
  local ok, joules = pcall(function() return prototypes.entity[name].electric_energy_source_prototype.buffer_capacity end)
  return ok and type(joules) == "number" and joules > 0 and joules or ACCUMULATOR_JOULES
end

local function light_at(day, t)
  if day.always_day then return 1 end
  if t <= day.dusk or t >= day.dawn then return 1 end
  if t < day.evening then return 1 - (t - day.dusk) / (day.evening - day.dusk) end
  if t <= day.morning then return 0 end
  return (t - day.morning) / (day.dawn - day.morning)
end

-- The light of LIGHT_SAMPLES evenly spaced daytimes, cached per surface for
-- its daytime parameters (pure arithmetic, so a cache rebuilt after a load
-- is the same).
local light_tables = {}
local function light_table(index, day)
  local key = table.concat({ day.dusk, day.evening, day.morning, day.dawn, tostring(day.always_day) }, ",")
  local cached = light_tables[index]
  if cached and cached.key == key then return cached.values end
  local values = {}
  for i = 1, LIGHT_SAMPLES do values[i] = light_at(day, (i - 0.5) / LIGHT_SAMPLES) end
  light_tables[index] = { key = key, values = values }
  return values
end

-- What the rows need of the surface, in a few attribute reads.
local function power_environment(surface)
  local env = { index = number_property(surface, "index") or 0 }
  local ok_platform, platform = pcall(function() return surface.platform end)
  env.platform = ok_platform and platform ~= nil
  local ok_property, value = pcall(function() return surface.get_property("solar-power") end)
  local property = ok_property and type(value) == "number" and value or 100
  env.factor = property / 100 * (number_property(surface, "solar_power_multiplier") or 1)
  if env.platform then return env end
  local ok, day = pcall(function()
    local parameters = surface.daytime_parameters
    return { dusk = parameters.dusk, evening = parameters.evening, morning = parameters.morning,
      dawn = parameters.dawn, always_day = surface.always_day == true }
  end)
  if not ok then day = { dusk = 0.25, evening = 0.45, morning = 0.55, dawn = 0.75, always_day = false } end
  env.ticks_per_day = number_property(surface, "ticks_per_day") or 25000
  env.light_now = light_at(day, number_property(surface, "daytime") or 0)
  if day.always_day then
    env.average, env.night_s = 1, 0
  else
    env.average = 1 - (day.evening - day.dusk) / 2 - (day.morning - day.evening) - (day.dawn - day.morning) / 2
    env.night_s = ((day.morning - day.evening) + ((day.evening - day.dusk) + (day.dawn - day.morning)) / 2)
      * env.ticks_per_day / 60
  end
  env.light = light_table(env.index, day)
  return env
end

-- Production watts per power kind from the network's statistics (read
-- through its pole), or nil when no live pole of the network is known; and
-- the engine reads it made.
local function production_by_kind(net)
  local pole = net.pole
  local reads = 3
  local ok, by_kind = pcall(function()
    if not (pole and pole.valid and pole.electric_network_id == net.id) then return nil end
    local statistics = pole.electric_network_statistics
    local precision = defines.flow_precision_index.five_seconds
    local out = {}
    for name in pairs(statistics.output_counts) do
      local kind = registry.power_kind(name)
      out[kind] = (out[kind] or 0) + statistics.get_flow_count({ name = name, category = "output",
        precision_index = precision, count = false }) * 60
      reads = reads + 1
    end
    return out
  end)
  return ok and by_kind or nil, reads
end

local function watts(value) return math.floor(value + 0.5) end

local function total_of(by_kind)
  local total = 0
  for _, value in pairs(by_kind) do total = total + value end
  return total
end

-- 1 while no consumer reads low_power or no_power, else production over
-- demand (0 when production is unknown).
local function satisfaction_of(net, production_w)
  if net.starved == 0 then return 1 end
  if production_w and net.demand_w > 0 then
    return math.floor(math.min(1, production_w / net.demand_w) * 1000 + 0.5) / 1000
  end
  return 0
end

local function cover(row, net, env, solar_w, other_w)
  local deficit = row.demand_w - row.sustained_w
  local solar = net.sources.solar
  if (solar and solar.count > 0) or other_w == 0 then
    local panel_w = solar and solar.count > 0 and solar.nameplate_w / solar.count or prototype_watts("solar-panel", 60000)
    local per_panel = panel_w * env.factor * env.average
    if per_panel <= 0 then return nil end
    local panels = math.ceil(deficit / per_panel)
    -- The night: energy the panels (with the added ones) cannot give,
    -- integrated over the day's light samples.
    local peak = (solar_w + panels * panel_w) * env.factor
    local seconds = env.ticks_per_day / 60 / LIGHT_SAMPLES
    local short_j = 0
    for _, light in ipairs(env.light) do
      short_j = short_j + math.max(0, row.demand_w - other_w - peak * light) * seconds
    end
    local stored = net.accumulators
    local buffer = stored.count > 0 and stored.capacity_j / stored.count or prototype_buffer("accumulator")
    local accumulators = math.ceil(short_j / buffer) - stored.count
    return { solar_panel = panels, accumulator = accumulators > 0 and accumulators or nil }
  end
  return { steam_engine = math.ceil(deficit / prototype_watts("steam-engine", STEAM_ENGINE_WATTS)) }
end

-- Rows for a surface's networks, most capacity first, at most `limit`, and
-- how many the limit left out.
function M.build_power(surface, limit)
  local env = power_environment(surface)
  local rows = {}
  for _, net in ipairs(registry.networks(env.index)) do
    local solar_w, other_w = 0, 0
    for kind, source in pairs(net.sources) do
      if kind == "solar" then solar_w = solar_w + source.nameplate_w else other_w = other_w + source.nameplate_w end
    end
    local capacity = env.platform and other_w or other_w + solar_w * env.factor * env.light_now
    rows[#rows + 1] = { network_id = net.id, capacity_w = watts(capacity), demand_w = watts(net.demand_w),
      _net = net, _solar_w = solar_w, _other_w = other_w }
  end
  table.sort(rows, function(a, b)
    if a.capacity_w ~= b.capacity_w then return a.capacity_w > b.capacity_w end
    return a.network_id < b.network_id
  end)
  local omitted = cap_rows(rows, limit)
  for _, row in ipairs(rows) do
    local net, solar_w, other_w = row._net, row._solar_w, row._other_w
    row._net, row._solar_w, row._other_w = nil, nil, nil
    local by_kind = production_by_kind(net)
    if by_kind then
      row.production_w = watts(total_of(by_kind))
      if env.platform then row.capacity_w = watts(other_w + (by_kind.solar or 0)) end
    end
    row.satisfaction = satisfaction_of(net, row.production_w)
    local sources = {}
    for kind, source in pairs(net.sources) do
      if source.count > 0 then
        sources[#sources + 1] = { kind = kind, count = source.count, nameplate_w = watts(source.nameplate_w),
          production_w = by_kind and watts(by_kind[kind] or 0) or nil }
      end
    end
    table.sort(sources, function(a, b) return a.kind < b.kind end)
    row.sources = sources
    local stored = net.accumulators
    if stored.count > 0 then
      row.accumulators = { count = stored.count, stored_j = watts(stored.stored_j), capacity_j = watts(stored.capacity_j),
        charge = stored.capacity_j > 0 and math.floor(stored.stored_j / stored.capacity_j * 1000 + 0.5) / 1000 or 0 }
    end
    if not env.platform then
      row.sustained_w = watts(other_w + solar_w * env.factor * env.average)
      row.headroom_w = row.sustained_w - row.demand_w
      row.night_s = math.floor(env.night_s * 10 + 0.5) / 10
      if row.sustained_w < row.demand_w then row.add_to_cover = cover(row, net, env, solar_w, other_w) end
    end
  end
  return rows, omitted
end

-- The lowest satisfaction among one surface's networks (the registry's
-- network rows; nil without one), as the power rows give it, and the
-- engine reads it made: the statistics of at most one network are read,
-- the one with the most demand among those whose consumers are short of
-- power; another such network is judged by its sources' nameplate.
function M.power_min_satisfaction(nets)
  local read
  for _, net in ipairs(nets) do
    if net.starved > 0 and (read == nil or net.demand_w > read.demand_w) then read = net end
  end
  local lowest, reads = nil, 0
  for _, net in ipairs(nets) do
    local production
    if net == read then
      local by_kind, cost = production_by_kind(net)
      production, reads = by_kind and total_of(by_kind), reads + cost
    elseif net.starved > 0 then
      production = 0
      for _, source in pairs(net.sources) do production = production + source.nameplate_w end
    end
    local satisfaction = satisfaction_of(net, production)
    if lowest == nil or satisfaction < lowest then lowest = satisfaction end
  end
  return lowest, reads
end

-- The sections map_summary's include reads, accumulated a record at a time
-- as the scan reads each own entity, so building them never walks every
-- entity in one tick (power rows come from the registry: build_power). Records are plain (no entity reads): chests and crafting outputs
-- carry record.contents; belts carry record.belt = {outputs = unit numbers
-- it feeds, pair = its underground partner's unit, bucket = what its lines
-- hold}.
local function sections_new(want)
  return { want = want, items = {}, belts = {}, sites = {}, problems = {}, problems_total = 0,
    problems_by_status = {} }
end

local function holder_order(a, b)
  if a.count ~= b.count then return a.count > b.count end
  return row_position(a, b)
end

local function hold(A, item, count, entity, kind)
  if count <= 0 then return end
  local row = A.items[item]
  if not row then
    row = { item = item, total = 0, holders = {}, holder_count = 0 }
    A.items[item] = row
  end
  row.total, row.holder_count = row.total + count, row.holder_count + 1
  heap_keep(row.holders, MAX_STOCK_HOLDERS,
    { entity = entity.name, position = xy(entity.position), count = count, kind = kind }, holder_order)
end

-- Input waits last, then machines before inserters (a dead network must not
-- fill the cap with arms), then the more severe status.
local function problem_order(a, b)
  local a_wait, b_wait = a._rank == INPUT_WAIT_RANK, b._rank == INPUT_WAIT_RANK
  if a_wait ~= b_wait then return b_wait end
  if a._inserter ~= b._inserter then return b._inserter end
  if a._rank ~= b._rank then return a._rank < b._rank end
  return row_position(a, b)
end

local function sections_add(A, record)
  local entity, want = record.entity, A.want
  local kind = entity.type
  if want.stockpiles then
    if BELT_TYPES[kind] then
      if record.belt then A.belts[#A.belts + 1] = record end
    elseif CHEST_TYPES[kind] or OUTPUT_TYPES[kind] then
      for item, count in pairs(record.contents or {}) do hold(A, item, count, entity, CHEST_TYPES[kind] and "chest" or "machine_output") end
    end
  end
  if want.sites and SITE_TYPES[kind] then
    local cx, cy = math.floor(entity.position.x / 32), math.floor(entity.position.y / 32)
    local key = cx .. "," .. cy
    local site = A.sites[key] or { chunk = { x = cx, y = cy }, machines = {}, _count = 0, _x = 0, _y = 0 }
    A.sites[key] = site
    site.machines[entity.name] = (site.machines[entity.name] or 0) + 1
    site._count, site._x, site._y = site._count + 1, site._x + entity.position.x, site._y + entity.position.y
  end
  if want.problems and PROBLEM_STATUSES[record.status] then
    A.problems_total = A.problems_total + 1
    A.problems_by_status[record.status] = (A.problems_by_status[record.status] or 0) + 1
    heap_keep(A.problems, MAX_PROBLEMS, { entity = entity.name, position = xy(entity.position),
      status = record.status, _inserter = kind == "inserter", _rank = PROBLEM_RANK[record.status] or INPUT_WAIT_RANK },
      problem_order)
  end
end

-- Belt contents as stock, a budget at a time: one holder per connected
-- belt run, located at the run's entity carrying most of that item. Runs
-- join through belt_neighbours among the collected (own, charted) belts
-- only, so a run never reaches into uncharted chunks. True once done.
local function sections_belts(A, budget)
  local belts = A.belts
  A.phase = A.phase or 1
  if A.phase == 1 then
    A.parent, A.index_of = A.parent or {}, A.index_of or {}
    if not each(A, budget, #belts, LUA_ITEM, function(index)
      A.parent[index] = index
      local unit = belts[index].entity.unit_number
      if unit then A.index_of[unit] = index end
    end) then return false end
    A.phase = 2
  end
  local parent = A.parent
  local function find(index)
    while parent[index] ~= index do parent[index] = parent[parent[index]]; index = parent[index] end
    return index
  end
  if A.phase == 2 then
    if not each(A, budget, #belts, LUA_ITEM, function(index)
      local record = belts[index]
      for _, unit in ipairs(record.belt.outputs) do
        local other_index = A.index_of[unit]
        if other_index then parent[find(index)] = find(other_index) end
      end
      -- belt_neighbours omits the other end of an underground pair.
      local pair_index = record.belt.pair and A.index_of[record.belt.pair]
      if pair_index then parent[find(index)] = find(pair_index) end
    end) then return false end
    A.phase, A.runs, A.run_list = 3, {}, {}
  end
  if A.phase == 3 then
    if not each(A, budget, #belts, LUA_ITEM, function(index)
      local record = belts[index]
      local belt = record.entity
      local root_index = find(index)
      local run = A.runs[root_index]
      if not run then
        run = {}
        A.runs[root_index], A.run_list[#A.run_list + 1] = run, run
      end
      for item, count in pairs(record.belt.bucket) do
        local held = run[item] or { count = 0, best = 0 }
        run[item] = held
        held.count = held.count + count
        if count > held.best or (count == held.best and held.entity and key_position(belt, held.entity)) then
          held.best, held.entity = count, belt
        end
      end
    end) then return false end
    A.phase = 4
  end
  if not each(A, budget, #A.run_list, LUA_ITEM, function(index)
    for item, held in pairs(A.run_list[index]) do if held.entity then hold(A, item, held.count, held.entity, "belt") end end
  end) then return false end
  A.belts, A.parent, A.index_of, A.runs, A.run_list, A.phase = {}, nil, nil, nil, nil, nil
  return true
end

-- The stock rows (most held first, each with its first holders) and how
-- many the cap left out.
local function sections_stockpiles(A)
  local rows = sorted_rows(A.items, function(a, b)
    if a.total ~= b.total then return a.total > b.total end
    return a.item < b.item
  end)
  for _, row in ipairs(rows) do
    table.sort(row.holders, holder_order)
    row.holders_omitted = row.holder_count - #row.holders
    row.holder_count = nil
  end
  return rows, cap_rows(rows, MAX_STOCK_ITEMS)
end

-- One row per charted chunk holding own machines. This is independent of the
-- detail=full landmark cap, so a full landmark list cannot hide a remote site.
local function sections_sites(A)
  local rows = sorted_rows(A.sites, function(a, b)
    if a._count ~= b._count then return a._count > b._count end
    if a.chunk.y ~= b.chunk.y then return a.chunk.y < b.chunk.y end
    return a.chunk.x < b.chunk.x
  end)
  for _, site in ipairs(rows) do
    site.position = { x = math.floor(site._x / site._count + 0.5), y = math.floor(site._y / site._count + 0.5) }
    site._count, site._x, site._y = nil, nil, nil
  end
  return rows, cap_rows(rows, MAX_SITES)
end

-- The first problem rows, the total and the per-status counts (which
-- cover every problem, including rows the cap left out).
local function sections_problems(A)
  local rows = A.problems
  table.sort(rows, problem_order)
  for _, row in ipairs(rows) do row._inserter, row._rank = nil, nil end
  return rows, A.problems_total, A.problems_by_status
end

-- ------------------------------------------------------- map_summary job
-- map_summary reads every own entity in the charted chunks, so it is a job
-- (jobs.lua): the RPC returns at once and on_tick advances it a budget of
-- work items per tick through these stages, its state S plain data in
-- storage between ticks:
--   scan         a chunk at a time from the patch cache's charted list: its
--                own entities (and, for full, resources and water tiles),
--                each read once into flow nodes and the requested sections
--   water_edges  (full) land/water edges a tile row at a time, pure Lua
--   flow         the material-flow graph, stage by stage (flow_step)
--   flows_all    (include) every counted item and fluid: names one surface
--                and kind a step, then their rates
--   sections     (include stockpiles) belt runs as stock holders
--   force_flows  the capped force_flows rows' rates, a row at a time
--   finish       groups and the capped rows: no list is longer than
--                its cap here, so this tick's work does not grow with the factory
-- Work items: one per engine call or so, plus the Lua work around it.
local SCAN_CHUNK_COST, SCAN_ENTITY_COST, SCAN_FLUID_COST, SCAN_RESOURCE_COST = 4, 30, 16, 6
local WATER_STRIP = 8 -- tile rows per water query (a chunk is 4 strips)

-- Charted chunks of the summary's surface: its patch cache's list once it
-- is seeded (no engine call), else listed here once (a new game's first
-- ticks, or a platform, whose chunks all count as charted).
local function chunk_source(S, c)
  local cache = storage.patch_caches and storage.patch_caches[S.surface_index]
  if cache and cache.seeded and cache.charted then
    S.from_cache, S.chunk_total = true, #cache.charted
    return
  end
  local chunks = {}
  S.chunk_set = {}
  for chunk in c.surface.get_chunks() do
    if surfaces.charted(c.force, c.surface, chunk.x, chunk.y, c.platform) then
      chunks[#chunks + 1] = { x = chunk.x, y = chunk.y }
      S.chunk_set[chunk.x .. "," .. chunk.y] = true
    end
  end
  table.sort(chunks, function(a, b) return a.y == b.y and a.x < b.x or a.y < b.y end)
  S.chunks, S.chunk_total = chunks, #chunks
end

local function summary_cache(S) return storage.patch_caches and storage.patch_caches[S.surface_index] end

local function chunk_at(S, index)
  if index > S.chunk_total then return nil end
  if S.from_cache then
    local cache = summary_cache(S)
    return cache and cache.charted[index]
  end
  return S.chunks[index]
end

local function chunk_charted(S, cx, cy)
  local key = cx .. "," .. cy
  if S.from_cache then
    local cache = summary_cache(S)
    return cache ~= nil and cache.charted_set[key] == true
  end
  return S.chunk_set[key] == true
end

local function unit_of(entity) return number_property(entity, "unit_number") end

-- A plain record of an own entity for the requested sections.
local function own_record(S, entity, raw_status)
  local record = { entity = { name = entity.name, type = entity.type, unit_number = unit_of(entity),
    position = xy(entity.position) }, status = raw_status }
  local kind = entity.type
  if S.want.stockpiles then
    if CHEST_TYPES[kind] or OUTPUT_TYPES[kind] then
      local inventory = stock_inventory(entity)
      record.contents = {}
      if inventory then add_contents(record.contents, inventory) end
    elseif BELT_TYPES[kind] then
      local belt = { outputs = {}, bucket = {} }
      local ok, outputs = pcall(function() return entity.belt_neighbours.outputs end)
      for _, other in ipairs(ok and type(outputs) == "table" and outputs or {}) do belt.outputs[#belt.outputs + 1] = unit_of(other) end
      if kind == "underground-belt" then
        local ok_pair, pair = pcall(function() return entity.neighbours end)
        belt.pair = ok_pair and pair and unit_of(pair) or nil
      end
      for _, line in ipairs(belt_lines(entity)) do add_contents(belt.bucket, line) end
      record.belt = belt
    end
  end
  return record
end

-- One own entity found in a chunk: its landmark, group, flow node and record.
local function scan_entity(S, entity, c, budget)
  local omissions = S.omissions
  if not entity.valid then
    omissions.invalid_entities = omissions.invalid_entities + 1
    return
  end
  if not (entity.force == c.force and charted(c.force, c.surface, entity.position, c.platform)
    and entity.type ~= "character" and entity.type ~= "entity-ghost") then return end
  local key = string.format("%s\0%s\0%.17g\0%.17g", entity.name, entity.type, entity.position.x, entity.position.y)
  if S.seen_landmark[key] then return end
  S.seen_landmark[key] = true
  local raw_status = status_name(entity)
  local recipe = recipe_fact(entity)
  local role = FLOW_NODE_ROLES[entity.type]
  local network_id = number_property(entity, "electric_network_id")
  if network_id then S.electric_networks[network_id] = true end
  if S.sections then sections_add(S.sections, own_record(S, entity, raw_status)) end
  if role then
    local node = {
      _key = key, _entity = entity, _unit = unit_of(entity), name = entity.name, type = entity.type,
      role = role, position = { x = entity.position.x, y = entity.position.y },
      direction = entity.direction, status = normalize_status(raw_status),
      _raw_status = raw_status,
      _waiting_for_destination = raw_status == "waiting_for_space_in_destination",
      _fuel_destination_proven = entity.type == "mining-drill" or recipe and recipe.ingredients_proven,
      recipe = recipe and recipe.name or nil,
      products_finished = number_property(entity, "products_finished"),
      ingredients = recipe and recipe.ingredients or {},
      products = products_with_fuel(recipe and recipe.products
        or (entity.type == "mining-drill" and mining_products(entity) or {})),
      requires_fuel = has_burner(entity),
      fuel_categories = burner_categories(entity),
      power_state = raw_status == "no_power" and "missing" or raw_status == "low_power" and "low" or "not_exactly_observed",
      fuel_state = raw_status == "no_fuel" and "missing" or "not_exactly_observed",
    }
    if role == "source" then
      node._source_production = { working = node.status == "working" }
      local ok, target = pcall(function() return entity.mining_target end)
      if ok and entity_key(target) and charted(c.force, c.surface, target.position, c.platform) then
        node._source_production.resource_key = entity_key(target)
      end
    end
    fluid_facts(node)
    if node._fluid_connections then
      budget.left = budget.left - SCAN_FLUID_COST
      for _, connection in ipairs(node._fluid_connections) do
        connection._target_key = entity_key(connection._target_entity)
      end
    end
    local F = S.flow
    F.flow_entities[#F.flow_entities + 1] = entity
    F.node_list[#F.node_list + 1] = node
  end
  if MACHINE_TYPES[entity.type] then
    local group_key = entity.name .. "\0" .. (recipe and recipe.name or "")
    local group = S.groups_by_key[group_key]
    if not group then
      group = { entity = entity.name, type = entity.type, recipe = recipe and recipe.name or nil,
        machine_count = 0, status_counts = {}, summed_crafting_speed = 0, _recipe_energy = recipe and recipe.energy or nil }
      S.groups_by_key[group_key] = group
    end
    group.machine_count = group.machine_count + 1
    if entity.type == "mining-drill" then
      local capacity = nominal_mining_capacity(entity, c.force, c.surface, c.platform)
      group._mining_capacity = (group._mining_capacity or 0) + (capacity or 0)
      group.evidenced_drill_count = (group.evidenced_drill_count or 0) + (capacity and 1 or 0)
    end
    local bucket = normalize_status(raw_status)
    group.status_counts[bucket] = (group.status_counts[bucket] or 0) + 1
    local speed = number_property(entity, "crafting_speed") or 0
    group.summed_crafting_speed = group.summed_crafting_speed + speed
    if recipe and not S.explicit_flows then
      for _, row in ipairs(recipe.ingredients) do add_flow_candidate(S.flow_candidates, row.type, row.name) end
      for _, row in ipairs(recipe.products) do add_flow_candidate(S.flow_candidates, row.type, row.name) end
    end
  elseif not role then
    omissions.unsupported_entities = omissions.unsupported_entities + 1
  end
  if S.detail == "full" then
    -- The first MAX_LANDMARKS in position order are kept as they arrive.
    S.landmark_total = S.landmark_total + 1
    heap_keep(S.landmarks, MAX_LANDMARKS, {
      name = entity.name, type = entity.type,
      position = { x = entity.position.x, y = entity.position.y },
      direction = entity.direction, status = raw_status, recipe = recipe and recipe.name or recipe_name(entity),
      observed_tick = game.tick,
    }, key_position)
  end
end

-- One resource (full detail): totals and the nearest to the body per name.
local function scan_resource(S, entity, c)
  local resource_key = entity.valid and charted(c.force, c.surface, entity.position, c.platform)
    and string.format("%s\0%.17g\0%.17g", entity.name, entity.position.x, entity.position.y) or nil
  if not resource_key or S.seen_resource[resource_key] then return end
  S.seen_resource[resource_key] = true
  local row = S.resources_by_name[entity.name] or { name = entity.name, entity_count = 0, total_amount = 0, nearest = nil, observed_tick = game.tick, _distance = nil }
  S.resources_by_name[entity.name] = row
  row.entity_count = row.entity_count + 1
  row.total_amount = row.total_amount + (tonumber(entity.amount) or 0)
  local dx, dy = entity.position.x - S.body.x, entity.position.y - S.body.y
  local distance = dx * dx + dy * dy
  if row._distance == nil or distance < row._distance
    or (distance == row._distance and (entity.position.y < row.nearest.y
      or (entity.position.y == row.nearest.y and entity.position.x < row.nearest.x))) then
    row._distance = distance
    row.nearest = { x = entity.position.x, y = entity.position.y }
  end
end

-- Reads the next chunk: queues its entities (and, for full, its resources
-- and water) for the scan.
local function fetch_chunk(S, chunk, c, budget)
  budget.left = budget.left - SCAN_CHUNK_COST
  local ok_visible, visible = pcall(c.force.is_chunk_visible, c.surface, chunk)
  if ok_visible and visible then S.visible_chunks = S.visible_chunks + 1 end
  local x0, y0 = chunk.x * 32, chunk.y * 32
  local area = { { x0, y0 }, { x0 + 32, y0 + 32 } }
  if S.detail == "full" then
    S.water_strip = 0
    S.rqueue, S.ri = c.surface.find_entities_filtered({ area = area, type = "resource" }), 1
  end
  S.queue, S.qi = c.surface.find_entities_filtered({ area = area, force = c.force }), 1
end

-- Water tiles of one strip of the current chunk (full detail).
local function fetch_water(S, chunk, c, budget)
  local x0, y0 = chunk.x * 32, chunk.y * 32 + S.water_strip * WATER_STRIP
  S.water_strip = S.water_strip + 1
  local tiles = c.surface.find_tiles_filtered({ area = { { x0, y0 }, { x0 + 32, y0 + WATER_STRIP } }, name = S.water_names })
  budget.left = budget.left - 1 - #tiles
  for _, tile in ipairs(tiles) do
    local position = tile.position
    local row = S.water[position.y] or {}
    S.water[position.y] = row
    row[position.x] = true
  end
end

local function scan(S, budget, c)
  while budget.left > 0 do
    local chunk = S.ci and chunk_at(S, S.ci)
    if chunk and S.water_strip and S.water_strip < 32 / WATER_STRIP then
      fetch_water(S, chunk, c, budget)
    elseif S.rqueue and S.rqueue[S.ri] then
      budget.left = budget.left - SCAN_RESOURCE_COST
      scan_resource(S, S.rqueue[S.ri], c)
      S.ri = S.ri + 1
    elseif S.queue and S.queue[S.qi] then
      budget.left = budget.left - SCAN_ENTITY_COST
      scan_entity(S, S.queue[S.qi], c, budget)
      S.qi = S.qi + 1
    else
      S.queue, S.rqueue, S.water_strip = nil, nil, nil
      S.ci = (S.ci or 0) + 1
      chunk = chunk_at(S, S.ci)
      if not chunk then return true end
      fetch_chunk(S, chunk, c, budget)
    end
  end
  return false
end

-- Land/water edges of each charted chunk (full detail), pure Lua, a tile
-- row at a time. Each pair of cells is compared by exactly one chunk (a
-- chunk's east and south borders are its own), so no edge repeats; the
-- first MAX_EDGES in presentation order are kept as they are found.
local EDGE_DIRECTIONS = { { 1, 0 }, { 0, 1 } }
local WATER_CELLS_PER_ITEM = 8
local function water_edge_order(a, b)
  if a.land.y ~= b.land.y then return a.land.y < b.land.y end
  if a.land.x ~= b.land.x then return a.land.x < b.land.x end
  if a.water.y ~= b.water.y then return a.water.y < b.water.y end
  return a.water.x < b.water.x
end
local function water_edges(S, budget)
  local water = S.water
  while budget.left > 0 do
    if not S.ey then
      S.ei = (S.ei or 0) + 1
      local chunk = chunk_at(S, S.ei)
      if not chunk then return true end
      S.ey = 0
      S.east_charted = chunk_charted(S, chunk.x + 1, chunk.y)
      S.south_charted = chunk_charted(S, chunk.x, chunk.y + 1)
    end
    local chunk = chunk_at(S, S.ei)
    local x0, y0 = chunk.x * 32, chunk.y * 32
    local y = y0 + S.ey
    budget.left = budget.left - 32 * #EDGE_DIRECTIONS / WATER_CELLS_PER_ITEM
    local row = water[y]
    for x = x0, x0 + 31 do
      local current = row and row[x] or false
      for _, delta in ipairs(EDGE_DIRECTIONS) do
        local nx, ny = x + delta[1], y + delta[2]
        if (nx < x0 + 32 and ny < y0 + 32)
          or (nx == x0 + 32 and S.east_charted)
          or (ny == y0 + 32 and S.south_charted) then
          local neighbor = water[ny] and water[ny][nx] or false
          if current ~= neighbor then
            budget.left = budget.left - 1
            local land = current and { x = nx, y = ny } or { x = x, y = y }
            local wet = current and { x = x, y = y } or { x = nx, y = ny }
            S.water_edge_total = S.water_edge_total + 1
            heap_keep(S.water_edges, MAX_EDGES, { land = land, water = wet, observed_tick = game.tick }, water_edge_order)
          end
        end
      end
    end
    S.ey = S.ey < 31 and S.ey + 1 or nil
  end
  return false
end

-- What the summary reads with: {surface, force, position} of its surface,
-- kept in S by index and resolved again on each tick it works.
local function summary_context(S)
  local body = companion.require_present()
  -- A summary a 0.22.2 save left running read the body's surface.
  if S.surface_index == nil then S.surface_index, S.surface_ref = body.surface.index, body.surface_ref end
  local surface = surfaces.stored(S.surface_index, body)
  if not surface then error("SURFACE_GONE: surface " .. tostring(S.surface_ref) .. " no longer exists", 0) end
  if S.platform == nil then S.platform = surfaces.is_platform(surface) end
  return { surface = surface, force = body.force, position = S.body, platform = S.platform }
end

-- The surfaces whose flows the summary reads: its own, or with surface:"all"
-- every factory surface (registry.surfaces) and its own.
local function flow_surfaces(S, c)
  if not S.all_flows then return { c.surface } end
  local list, seen = {}, {}
  for _, index in ipairs(registry.surfaces()) do
    local surface = surfaces.by_index(index)
    if surface then list[#list + 1], seen[index] = surface, true end
  end
  if not seen[S.surface_index] then list[#list + 1] = c.surface end
  return list
end

-- Every item and fluid the force's native statistics for the summary's
-- surfaces have ever counted (summed): input is produced, output is
-- consumed. Only this section lifts the force_flows row cap. Names are
-- listed one surface and kind a step, rates read a budget at a time.
local function flows_all(S, budget, c)
  local FLOW_KINDS = { "item", "fluid" }
  local A = S.all
  local surface_list = flow_surfaces(S, c)
  if not A then
    A = { rows = {}, next = 1, cursor = 1, by_name = { item = {}, fluid = {} } }
    S.all = A
  end
  -- A summary a 0.22.2 or older save left here listed every name at once.
  if A.cursor == nil then A.cursor = #surface_list * #FLOW_KINDS + 1 end
  -- Lifetime counts: one surface and kind a step.
  while A.cursor <= #surface_list * #FLOW_KINDS do
    if budget.left <= 0 then return false end
    local surface = surface_list[math.floor((A.cursor - 1) / #FLOW_KINDS) + 1]
    local kind = FLOW_KINDS[(A.cursor - 1) % #FLOW_KINDS + 1]
    local by_name, names = A.by_name[kind], 0
    for _, statistics in ipairs(statistics_of(c.force, { surface }, kind) or {}) do
      local function counts(field)
        local ok_counts, value = pcall(function() return statistics[field] end)
        return ok_counts and type(value) == "table" and value or {}
      end
      for field, list in pairs({ lifetime_produced = counts("input_counts"), lifetime_consumed = counts("output_counts") }) do
        for name, count in pairs(list) do
          if type(name) == "string" then
            local row = by_name[name] or { name = name, kind = kind, lifetime_produced = 0, lifetime_consumed = 0 }
            by_name[name] = row
            row[field] = row[field] + (tonumber(count) or 0)
            names = names + 1
          end
        end
      end
    end
    budget.left = budget.left - 3 - math.ceil(names / 8)
    A.cursor = A.cursor + 1
    if A.cursor > #surface_list * #FLOW_KINDS then
      for _, each in ipairs(FLOW_KINDS) do
        for _, row in pairs(A.by_name[each]) do
          if row.lifetime_produced > 0 or row.lifetime_consumed > 0 then A.rows[#A.rows + 1] = row end
        end
      end
      A.by_name = nil
      budget.left = budget.left - math.ceil(#A.rows / 8)
    end
  end
  local precision_index = defines and defines.flow_precision_index and defines.flow_precision_index[S.precision_name]
  local statistics = {}
  while A.next <= #A.rows do
    if budget.left <= 0 then return false end
    local row = A.rows[A.next]
    if statistics[row.kind] == nil then statistics[row.kind] = statistics_of(c.force, surface_list, row.kind) or false end
    local list = statistics[row.kind] or nil
    row.produced_per_minute = summed_rate(list, row.name, "input", precision_index)
    row.consumed_per_minute = summed_rate(list, row.name, "output", precision_index)
    budget.left = budget.left - 3 * #surface_list
    A.next = A.next + 1
  end
  local rows = A.rows
  table.sort(rows, function(a, b)
    local a_total, b_total = a.lifetime_produced + a.lifetime_consumed, b.lifetime_produced + b.lifetime_consumed
    if a_total ~= b_total then return a_total > b_total end
    if a.kind ~= b.kind then return a.kind < b.kind end
    return a.name < b.name
  end)
  -- Each row's keys in the order the result has always had.
  for index, row in ipairs(rows) do
    rows[index] = { name = row.name, kind = row.kind, produced_per_minute = row.produced_per_minute,
      consumed_per_minute = row.consumed_per_minute, lifetime_produced = row.lifetime_produced,
      lifetime_consumed = row.lifetime_consumed }
  end
  S.flows_all_rows, S.flows_all_omitted = rows, cap_rows(rows, MAX_FLOWS_ALL)
  S.all = nil
  return true
end

-- The force_flows rows (the candidates, capped at MAX_FLOW_ROWS): one
-- candidate's rates on every surface of the summary a work item each.
local function force_flows(S, budget, c)
  local F = S.force_flow_read
  if not F then
    if not S.explicit_flows then add_current_research_flows(c.force, S.flow_candidates) end
    local precision = FLOW_PRECISIONS[S.precision_name]
    local precision_index = defines and defines.flow_precision_index and defines.flow_precision_index[S.precision_name]
    if not precision or precision_index == nil then error("unsupported map_summary flow_precision") end
    local rows = sorted_rows(S.flow_candidates, function(a, b)
      return a.type == b.type and a.name < b.name or a.type < b.type
    end)
    S.omissions.capped_flows = cap_rows(rows, MAX_FLOW_ROWS)
    F = { rows = rows, next = 1, result = {} }
    S.force_flow_read = F
  end
  local surface_list = flow_surfaces(S, c)
  local precision = FLOW_PRECISIONS[S.precision_name]
  local precision_index = defines.flow_precision_index[S.precision_name]
  local by_kind = {}
  while F.next <= #F.rows do
    if budget.left <= 0 then return false end
    local candidate = F.rows[F.next]
    if by_kind[candidate.type] == nil then
      by_kind[candidate.type] = statistics_of(c.force, surface_list, candidate.type) or false
    end
    local list = by_kind[candidate.type] or nil
    local input_rate = summed_rate(list, candidate.name, "input", precision_index)
    local output_rate = summed_rate(list, candidate.name, "output", precision_index)
    if type(input_rate) == "number" and type(output_rate) == "number" then
      F.result[#F.result + 1] = {
        type = candidate.type, name = candidate.name,
        input_rate = input_rate, output_rate = output_rate,
        precision = S.precision_name, window_ticks = precision.ticks, units = precision.units,
        source = "force_flow_statistics",
      }
    else
      S.omissions.unsupported_flow_statistics = S.omissions.unsupported_flow_statistics + 1
    end
    budget.left = budget.left - 1 - 2 * #surface_list
    F.next = F.next + 1
  end
  S.force_flows, S.force_flow_read = F.result, nil
  return true
end

-- Groups, flows, sections and the result: bounded rows and a few
-- statistics reads.
local function finish(S, c)
  local omissions, want = S.omissions, S.want
  local groups = sorted_rows(S.groups_by_key, function(a, b)
    if a.entity ~= b.entity then return a.entity < b.entity end
    return (a.recipe or "") < (b.recipe or "")
  end)
  local machine_count = 0
  for _, group in ipairs(groups) do
    machine_count = machine_count + group.machine_count
    if group._recipe_energy and group._recipe_energy > 0 and group.summed_crafting_speed > 0 then
      group.theoretical_crafts_per_second = group.summed_crafting_speed / group._recipe_energy
      group.capacity_basis = "summed_current_crafting_speed_divided_by_recipe_energy"
    end
    group._recipe_energy = nil
    if group.type == "mining-drill" then
      group.capacity_basis = "nominal_prototype_mining_speed_times_item_yield_divided_by_current_resource_mining_time"
      group.capacity_state = group.evidenced_drill_count == group.machine_count and "complete"
        or group.evidenced_drill_count > 0 and "incomplete" or "unavailable"
      if group.capacity_state == "complete" then group.theoretical_items_per_minute = group._mining_capacity end
      group._mining_capacity = nil
    end
  end
  omissions.capped_groups = cap_rows(groups, MAX_FACTORY_GROUPS)
  local flows = S.force_flows
  local power_status_counts = {}
  for _, group in ipairs(groups) do
    for name, count in pairs(group.status_counts) do
      if name == "no_power" or name == "low_power" then
        power_status_counts[name] = (power_status_counts[name] or 0) + count
      end
    end
  end
  local network_count = 0; for _ in pairs(S.electric_networks) do network_count = network_count + 1 end
  local material_flow = present_flow(flow_result(S.flow), omissions, S.surface_index)
  local activity = factory_activity.snapshot(S.activity_since_tick)
  local partial = false; for _, count in pairs(omissions) do if count > 0 then partial = true end end
  local factory = {
    scope = "force_charted", surface = S.surface_ref, flow_surface = S.all_flows and "all" or nil,
    collected_at_tick = game.tick, started_tick = S.started_tick,
    consistency = "spread_over_ticks",
    charted_chunks = S.chunk_total, currently_visible_charted_chunks = S.visible_chunks,
    machine_count = machine_count, registry_machine_count = registry.counts().machines,
    groups = groups, force_flows = flows,
    power = { network_count = network_count, status_counts = power_status_counts },
    material_flow = material_flow, character_transfers = activity,
    evidence = {
      entity_summary = {
        evidence_class = "charted_remote_summary", source_tick = game.tick,
        scope = "currently_existing_player_force_entities_in_already_charted_chunks",
        exact_remote_inventories = want.stockpiles == true, exact_remote_fluids = false,
      },
      force_flows = {
        evidence_class = "rolling_force_surface_flow", source_tick = game.tick,
        precision = S.precision_name, window_ticks = FLOW_PRECISIONS[S.precision_name].ticks,
        exact_stock = false,
      },
      character_transfers = {
        evidence_class = "run_local_history", epoch_tick = activity.epoch_tick,
        since_tick = activity.since_tick, end_tick = activity.end_tick,
        history_complete = activity.history_complete,
      },
      cached_or_previously_observed_facts = { included = false },
    },
    omissions = omissions, partial = partial,
  }

  local summary_text = string.format("factory tick %d: %d machines in %d groups; %d flow rows; %d physical components; %d character transfers",
    game.tick, machine_count, #groups, #flows, #material_flow.components, activity.transfer_actions)
  -- Requested sections are top-level keys beside `factory`, each with the
  -- count of what its cap left out.
  local sections = {}
  if want.stockpiles then sections.stockpiles, sections.stockpiles_omitted = sections_stockpiles(S.sections) end
  if want.sites then sections.sites, sections.sites_omitted = sections_sites(S.sections) end
  if want.patches then
    sections.patches, sections.patches_complete, sections.patches_omitted = M.patches(S.surface_index)
  end
  if want.power then
    local networks, networks_omitted = M.build_power(c.surface, MAX_POWER_NETWORKS)
    sections.power = { networks = networks, networks_omitted = networks_omitted }
  end
  if want.problems then
    sections.problems, sections.problems_total, sections.problems_by_status = sections_problems(S.sections)
  end
  if want.flows_all then
    sections.force_flows_all, sections.force_flows_all_omitted = S.flows_all_rows, S.flows_all_omitted
  end
  local function with_sections(result)
    for key, value in pairs(sections) do result[key] = value end
    return result
  end
  if S.detail == "aggregate" then
    return with_sections({ tick = game.tick, surface = S.surface_ref, summary = summary_text, factory = factory })
  end

  local resources = {}; for _, row in pairs(S.resources_by_name) do row._distance = nil; resources[#resources + 1] = row end
  table.sort(resources, function(a, b) return a.name < b.name end)
  -- Both lists were kept to their caps while they were collected.
  local landmarks, edges = S.landmarks, S.water_edges
  table.sort(landmarks, key_position)
  table.sort(edges, water_edge_order)
  local omitted_water_edges = S.water_edge_total - #edges
  local omitted_factory_landmarks = S.landmark_total - #landmarks
  return with_sections({
    tick = game.tick, surface = S.surface_ref, charted_chunks = S.chunk_total, resources = resources,
    water_edges = edges, omitted_water_edges = omitted_water_edges,
    factory_landmarks = landmarks, omitted_factory_landmarks = omitted_factory_landmarks,
    factory = factory, summary = summary_text,
  })
end

local function summary_start(params)
  params = type(params) == "table" and params or {}
  local detail = params.detail or "aggregate"
  if detail ~= "aggregate" and detail ~= "full" then error("map_summary detail must be aggregate or full", 0) end
  local precision_name = params.flow_precision or "one_minute"
  if not FLOW_PRECISIONS[precision_name] then error("unsupported map_summary flow_precision", 0) end
  local precision_index = defines and defines.flow_precision_index and defines.flow_precision_index[precision_name]
  if precision_index == nil then error("unsupported map_summary flow_precision", 0) end
  for _, field in ipairs({ "flow_items", "flow_fluids" }) do
    if params[field] ~= nil and (type(params[field]) ~= "table" or #params[field] > 32) then
      error("map_summary " .. field .. " must contain at most 32 names", 0)
    end
  end
  if params.activity_since_tick ~= nil and (tonumber(params.activity_since_tick) == nil
    or tonumber(params.activity_since_tick) % 1 ~= 0) then
    error("activity_since_tick must be an integer tick", 0)
  end
  local want = parse_include(params.include)
  if params.surface ~= nil and type(params.surface) ~= "string" and type(params.surface) ~= "table" then
    error("map_summary surface must be a planet name, \"platform:<index>\", {platform = name or index} or \"all\"", 0)
  end
  local all = params.surface == "all"
  local target = surfaces.target(not all and params.surface or nil)
  -- Distances are from the body when it is on this surface.
  local at = target.here and target.body.position or { x = 0, y = 0 }
  local c = { surface = target.surface, force = target.force, position = at,
    platform = surfaces.is_platform(target.surface) }
  local S = { detail = detail, surface_index = target.surface.index, surface_ref = target.ref, all_flows = all or nil,
    platform = c.platform, precision_name = precision_name, want = want, started_tick = game.tick,
    activity_since_tick = params.activity_since_tick,
    explicit_flows = params.flow_items ~= nil or params.flow_fluids ~= nil, flow_candidates = {},
    -- Requested sections accumulate as own entities are read.
    sections = (want.stockpiles or want.sites or want.problems) and sections_new(want) or nil,
    seen_landmark = {}, groups_by_key = {}, electric_networks = {}, visible_chunks = 0,
    omissions = { capped_groups = 0, capped_flows = 0, unsupported_entities = 0,
      invalid_entities = 0, unsupported_flow_statistics = 0, capped_flow_nodes = 0,
      capped_flow_edges = 0, capped_edge_diagnostics = 0 },
    flow = { stage = 1, flow_entities = {}, node_list = {},
      activity = factory_activity.snapshot(params.activity_since_tick, true) },
    stage = "scan", body = { x = c.position.x, y = c.position.y } }
  for _, name in ipairs(params.flow_items or {}) do add_flow_candidate(S.flow_candidates, "item", name) end
  for _, name in ipairs(params.flow_fluids or {}) do add_flow_candidate(S.flow_candidates, "fluid", name) end
  if detail == "full" then
    -- Match the predecessor's any-layer classification through prototype
    -- masks. Name filtering avoids passing unsupported historical
    -- collision-layer aliases to the native query.
    local water_names = {}
    for name, prototype in pairs(prototypes.tile) do
      local layers = prototype.collision_mask.layers
      if layers.water_tile or layers["water-tile"] or layers.player then water_names[#water_names + 1] = name end
    end
    table.sort(water_names)
    S.water_names, S.water = water_names, {}
    S.resources_by_name, S.seen_resource, S.landmarks, S.water_edges = {}, {}, {}, {}
    S.landmark_total, S.water_edge_total = 0, 0
  end
  chunk_source(S, c)
  return S
end

local NEXT_STAGE = { scan = "water_edges", water_edges = "flow", flow = "flows_all", flows_all = "sections",
  sections = "force_flows", force_flows = "finish" }

local function summary_step(S, budget)
  local c = summary_context(S)
  while budget.left > 0 do
    local stage = S.stage
    local done
    if stage == "scan" then done = scan(S, budget, c)
    elseif stage == "water_edges" then done = S.detail ~= "full" or water_edges(S, budget)
    elseif stage == "flow" then done = flow_step(S.flow, budget)
    elseif stage == "flows_all" then done = not S.want.flows_all or flows_all(S, budget, c)
    elseif stage == "sections" then done = not S.sections or sections_belts(S.sections, budget)
    elseif stage == "force_flows" then done = force_flows(S, budget, c)
    -- A summary a 0.22.2 or older save left at its finish reads its flows first.
    elseif S.force_flows == nil then S.stage = "force_flows"
    else return finish(S, c) end
    if done then S.stage = NEXT_STAGE[stage] end
  end
  return nil
end

-- map_summary {detail?, include?, flow_precision?, flow_items?, flow_fluids?,
-- activity_since_tick?, surface?}: the job definition (jobs.lua registers it).
M.summary_job = { start = summary_start, step = summary_step }

-- factory_status stock and power are the registry's aggregates, kept
-- current by its maintenance cursor a budget of work items a tick (control
-- calls this every tick once the registry is ready). A read never scans.
function M.status_tick(tick) registry.maintain(tick) end

-- The factory aggregate the run recorder samples, from what the mod already
-- maintains, with no chunk walk and no entity read: the machine count and
-- belts from the event-maintained registry, machine groups by entity and
-- product with their last sampled status from the line sampler
-- (autonomy.lua, every 30 ticks), and electric networks from the registry's
-- network aggregates, all summed over every factory surface.
function M.registry_factory()
  local a = storage.autonomy
  local groups_by_key, power_status_counts = {}, {}
  for _, rec in pairs(a and a.machines or {}) do
    if registry.PRODUCTIVE_TYPES[rec.type] then
      local key = rec.name .. "\0" .. (rec.recipe or rec.product or "")
      local group = groups_by_key[key]
      if not group then
        group = { entity = rec.name, type = rec.type, product = rec.product, recipe = rec.recipe, machine_count = 0,
          status_counts = {} }
        groups_by_key[key] = group
      end
      group.machine_count = group.machine_count + 1
      -- Crafting machines: lifetime products_finished as last sampled.
      if rec.finished then group.products_finished = (group.products_finished or 0) + rec.finished end
      local bucket = normalize_status(rec.raw)
      group.status_counts[bucket] = (group.status_counts[bucket] or 0) + 1
      if bucket == "no_power" or bucket == "low_power" then
        power_status_counts[bucket] = (power_status_counts[bucket] or 0) + 1
      end
    end
  end
  local groups = sorted_rows(groups_by_key, function(a_row, b_row)
    if a_row.entity ~= b_row.entity then return a_row.entity < b_row.entity end
    return (a_row.recipe or a_row.product or "") < (b_row.recipe or b_row.product or "")
  end)
  local counts = registry.counts()
  local network_count = registry.network_count()
  local maintenance = registry.maintenance()
  return { scope = "maintained", collected_at_tick = game.tick, registry_ready = counts.registry_ready,
    lines_refreshed_tick = a and a.last_refresh_tick, power_refreshed_tick = maintenance.pass_tick,
    machine_count = counts.machines, groups = groups, belt_count = counts.belts,
    power = { network_count = network_count, status_counts = power_status_counts },
    character_transfers = factory_activity.snapshot(), omissions = { capped_groups = 0 } }
end

-- ------------------------------------------------------------ patch cache
-- Resource patches from a per-chunk cache per planet surface
-- (storage.patch_caches[surface index], made when the force first charts a
-- chunk there, as it does around the body on arrival; a 0.22.2 save's
-- single cache becomes Nauvis's in state.init). A chunk is read when it is first
-- charted (radars and the body re-chart chunks all the time; a re-chart is
-- ignored), again when a resource in it is depleted, and, while nothing else
-- is pending, one cached resource chunk every PATCH_REFRESH_TICKS so amounts
-- follow mining. A cache's first tick lists the surface's charted chunks.
-- One cache works a tick, in turn, so the per-tick work does not grow with
-- the number of planets. Platform surfaces have no cache (no resources).
-- Reads never scan.
local PATCH_CHUNKS_PER_TICK = 2
local PATCH_RESOURCES_PER_TICK = 2048
local PATCH_REFRESH_TICKS = 120

local function chunk_key(x, y) return x .. "," .. y end

-- A new, unseeded cache for a surface.
function M.new_patch_cache(surface_index)
  return {
    version = schema.PATCH_CACHE_VERSION, surface_index = surface_index, seeded = false, filled = false,
    chunks = {}, known = {}, pending = {}, head = 1, queued = {}, refresh = {}, dirty = true, rows = nil,
    updated_tick = nil, charted = {}, charted_set = {},
    -- The patch rows being rebuilt over ticks (patch_tick), or nil.
    build = nil,
  }
end

-- The cache of a planet surface, made on first use when `create`.
local function cache_for(surface, create)
  local caches = storage.patch_caches
  local ok, index = pcall(function() return surface.index end)
  if not (caches and ok and index) then return nil end
  local cache = caches[index]
  if cache or not create or surfaces.is_platform(surface) then return cache end
  cache = M.new_patch_cache(index)
  caches[index] = cache
  return cache
end

local function enqueue_chunk(cache, x, y)
  local key = chunk_key(x, y)
  -- Every charted chunk once, in the order it became known (map_summary's
  -- chunk list).
  if not cache.charted_set[key] then
    cache.charted_set[key] = true
    cache.charted[#cache.charted + 1] = { x = x, y = y }
  end
  if cache.queued[key] then return end
  cache.queued[key] = true
  cache.pending[#cache.pending + 1] = { x = x, y = y }
end

-- The own force (the body's), or nil.
local function own_force()
  local anchor = companion.anchor()
  return anchor and anchor.force or nil
end

-- The own force's name: the registry's (no engine read), else the body's.
local function own_force_name()
  local r = storage.registry
  if r and r.force then return r.force end
  local force = own_force()
  return force and force.name
end

-- on_chunk_charted: the force charted or re-charted a chunk on some surface
-- (radars re-chart all the time: a known chunk returns before any read).
function M.on_chunk_charted(event)
  local caches = storage.patch_caches
  if not (caches and event and event.position) then return end
  local cache = caches[event.surface_index]
  if cache and cache.known[chunk_key(event.position.x, event.position.y)] then return end
  local ok, own = pcall(function() return event.force.name == own_force_name() end)
  if not (ok and own) then return end
  if not cache then
    local surface = surfaces.by_index(event.surface_index)
    cache = surface and cache_for(surface, true)
    if not cache then return end
  end
  enqueue_chunk(cache, event.position.x, event.position.y)
end

-- on_resource_depleted: the resource is removed right after the event; the
-- chunk is read again on a later tick.
function M.on_resource_depleted(event)
  local entity = event and event.entity
  if not (storage.patch_caches and entity and entity.valid) then return end
  local cache = storage.patch_caches[entity.surface_index]
  if not (cache and cache.seeded) then return end
  local position = entity.position
  enqueue_chunk(cache, math.floor(position.x / 32), math.floor(position.y / 32))
end

-- on_surface_deleted: its cache goes.
function M.on_surface_deleted(event)
  if storage.patch_caches and event and event.surface_index then storage.patch_caches[event.surface_index] = nil end
end

local function read_chunk(surface, cache, chunk)
  local key = chunk_key(chunk.x, chunk.y)
  cache.queued[key], cache.known[key] = nil, true
  local x0, y0 = chunk.x * 32, chunk.y * 32
  local cells, count = {}, 0
  local ok, found = pcall(surface.find_entities_filtered,
    { area = { { x0, y0 }, { x0 + 32, y0 + 32 } }, type = "resource" })
  for _, entity in ipairs(ok and found or {}) do
    count = count + 1
    local position = entity.valid and entity.position
    -- Each resource counts in the chunk its centre lies in.
    if position and math.floor(position.x / 32) == chunk.x and math.floor(position.y / 32) == chunk.y then
      add_patch_resource(cells, entity)
    end
  end
  local by_name = {}
  for name, cell_by_key in pairs(cells) do by_name[name] = cell_by_key[key] end
  cache.chunks[key] = next(by_name) and { cx = chunk.x, cy = chunk.y, cells = by_name } or nil
  cache.dirty = true
  return count
end

-- Rebuilds the patch rows from the cached chunks on ticks with no chunk to
-- read, PATCH_CELLS_PER_TICK cells a tick (a cell is one resource in one
-- chunk), so neither a read nor map_summary ever rebuilds them. A patch is
-- the same resource across touching (8-neighbour) chunks. The first tick
-- lists the cells; a chunk read meanwhile marks the cache dirty again.
local PATCH_CELLS_PER_TICK = 256
local function patch_build_step(cache)
  local B = cache.build
  if not B then
    local cells, list = {}, {}
    for key, chunk in pairs(cache.chunks) do
      for name, cell in pairs(chunk.cells) do
        cells[name] = cells[name] or {}
        cells[name][key] = cell
        list[#list + 1] = { name = name, key = key }
      end
    end
    cache.build, cache.dirty = { cells = cells, list = list, next = 1, seen = {}, rows = {} }, false
    return
  end
  local visited = 0
  while visited < PATCH_CELLS_PER_TICK do
    local patch = B.patch
    if patch and #B.stack > 0 then
      visited = visited + 1
      local by_name = B.cells[patch.name]
      local cell = by_name[table.remove(B.stack)]
      patch.amount, patch.tiles = patch.amount + cell.amount, patch.tiles + cell.tiles
      patch._x, patch._y = patch._x + cell.x, patch._y + cell.y
      patch._left, patch._right = math.min(patch._left, cell.left), math.max(patch._right, cell.right)
      patch._top, patch._bottom = math.min(patch._top, cell.top), math.max(patch._bottom, cell.bottom)
      for dy = -1, 1 do for dx = -1, 1 do
        local key = (cell.cx + dx) .. "," .. (cell.cy + dy)
        if by_name[key] and not B.seen[patch.name .. "|" .. key] then
          B.seen[patch.name .. "|" .. key] = true
          B.stack[#B.stack + 1] = key
        end
      end end
    elseif patch then
      patch.bbox = { left_top = { x = math.floor(patch._left), y = math.floor(patch._top) },
        right_bottom = { x = math.ceil(patch._right), y = math.ceil(patch._bottom) } }
      patch.centroid = { x = math.floor(patch._x / patch.tiles * 10 + 0.5) / 10,
        y = math.floor(patch._y / patch.tiles * 10 + 0.5) / 10 }
      patch._x, patch._y, patch._left, patch._right, patch._top, patch._bottom = nil, nil, nil, nil, nil, nil
      B.rows[#B.rows + 1], B.patch = patch, nil
    elseif B.next <= #B.list then
      local first = B.list[B.next]
      B.next = B.next + 1
      if not B.seen[first.name .. "|" .. first.key] then
        B.seen[first.name .. "|" .. first.key] = true
        local cell = B.cells[first.name][first.key]
        B.patch = { name = first.name, amount = 0, tiles = 0, _x = 0, _y = 0,
          _left = cell.left, _right = cell.right, _top = cell.top, _bottom = cell.bottom }
        B.stack = { first.key }
      end
    else
      -- One row per patch: few enough to sort at once.
      local rows = B.rows
      table.sort(rows, function(a, b)
        if a.amount ~= b.amount then return a.amount > b.amount end
        if a.name ~= b.name then return a.name < b.name end
        if a.centroid.y ~= b.centroid.y then return a.centroid.y < b.centroid.y end
        return a.centroid.x < b.centroid.x
      end)
      cache.rows_omitted = cap_rows(rows, MAX_PATCHES)
      cache.rows, cache.updated_tick, cache.build = rows, game.tick, nil
      return
    end
  end
end

local function patch_step(cache, surface, tick)
  if not cache.seeded then
    local force = own_force()
    if not force then return end
    -- Seeded from the chunks the registry bootstrap already listed for this
    -- surface (no API call); chunks charted since then arrive through
    -- on_chunk_charted. Any other cache lists its surface itself, once.
    local r = storage.registry
    local seed = r and r.charted_seed
    if seed and r.charted_seed_surface == cache.surface_index then
      for _, chunk in ipairs(seed) do enqueue_chunk(cache, chunk.x, chunk.y) end
      r.charted_seed, r.charted_seed_surface = nil, nil
    else
      for chunk in surface.get_chunks() do
        if force.is_chunk_charted(surface, chunk) then enqueue_chunk(cache, chunk.x, chunk.y) end
      end
    end
    cache.seeded = true
    return
  end
  if cache.head > #cache.pending then
    -- The idle refresh starts PATCH_REFRESH_TICKS after the cache first fills.
    if not cache.filled then cache.refreshed_tick = tick end
    cache.pending, cache.head, cache.filled = {}, 1, true
    if cache.build or cache.dirty then patch_build_step(cache) end
    if tick - (cache.refreshed_tick or 0) < PATCH_REFRESH_TICKS then return end
    cache.refreshed_tick = tick
    -- Round robin over the cached resource chunks.
    if #cache.refresh == 0 then
      for key, chunk in pairs(cache.chunks) do cache.refresh[#cache.refresh + 1] = { key = key, x = chunk.cx, y = chunk.cy } end
      table.sort(cache.refresh, function(a, b) return a.key > b.key end)
    end
    local next_chunk = table.remove(cache.refresh)
    if next_chunk then enqueue_chunk(cache, next_chunk.x, next_chunk.y) end
    return
  end
  local chunks, items = 0, 0
  while cache.head <= #cache.pending and chunks < PATCH_CHUNKS_PER_TICK and items < PATCH_RESOURCES_PER_TICK do
    local chunk = cache.pending[cache.head]
    cache.pending[cache.head], cache.head = false, cache.head + 1
    items = items + read_chunk(surface, cache, chunk)
    chunks = chunks + 1
  end
end

-- One cache works a tick: the caches in turn (by surface index). A failing
-- step never stops the game; its error is kept on its cache.
function M.patch_tick(tick)
  local caches = storage.patch_caches
  if not caches then return end
  local order = {}
  for index in pairs(caches) do order[#order + 1] = index end
  if #order == 0 then return end
  table.sort(order)
  local index = order[tick % #order + 1]
  local cache, surface = caches[index], surfaces.by_index(index)
  if not surface then caches[index] = nil; return end
  local ok, err = pcall(patch_step, cache, surface, tick)
  cache.error = not ok and tostring(err) or nil
end

-- Resource patches in charted chunks of a surface (an index; default the
-- body's anchor surface) from its cache (rebuilt on ticks by patch_tick,
-- never here), whether every charted chunk has been read at least once and
-- its patches built, and how many patches the cap left out.
function M.patches(surface_index)
  if surface_index == nil then surface_index = registry.anchor_index() end
  local cache = storage.patch_caches and surface_index and storage.patch_caches[surface_index]
  if not cache then return {}, false, 0 end
  return cache.rows or {}, cache.filled == true and cache.rows ~= nil, cache.rows_omitted or 0
end

return M
