-- Read-only summary of the force's already charted world. No chart or generation calls.
local companion = require("scripts.companion")
local factory_activity = require("scripts.factory_activity")
local autonomy = require("scripts.autonomy")
local fluid_connections = require("scripts.fluid_connections")
local output_target = require("scripts.output_target")
local registry = require("scripts.registry")

local M = {}
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
  no_resources = "no_resources", no_minable_resources = "no_resources", disabled = "disabled",
  disabled_by_control_behavior = "disabled",
  disabled_by_script = "disabled", marked_for_deconstruction = "disabled",
  turned_off_during_daytime = "disabled",
}

-- A status is one sample. Only these raw statuses describe the build itself;
-- every other nonproductive status is a transient wait judged by throughput.
local STRUCTURAL_RAW_STATUSES = {
  no_resources = true, no_minable_resources = true, disabled = true,
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

local function charted(force, surface, pos)
  return force.is_chunk_charted(surface, { x = math.floor(pos.x / 32), y = math.floor(pos.y / 32) })
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

local function read_force_flows(force, surface, candidates, precision_name, omissions)
  local precision = FLOW_PRECISIONS[precision_name]
  local precision_index = defines and defines.flow_precision_index and defines.flow_precision_index[precision_name]
  if not precision or precision_index == nil then error("unsupported map_summary flow_precision") end
  local rows = sorted_rows(candidates, function(a, b)
    return a.type == b.type and a.name < b.name or a.type < b.type
  end)
  omissions.capped_flows = cap_rows(rows, MAX_FLOW_ROWS)
  local result = {}
  for _, candidate in ipairs(rows) do
    local getter_name = candidate.type == "fluid" and "get_fluid_production_statistics" or "get_item_production_statistics"
    local ok_statistics, statistics = pcall(function() return force[getter_name](surface) end)
    local ok_input, input_rate = pcall(function()
      if not ok_statistics or not statistics then error("statistics unavailable") end
      return statistics.get_flow_count({ name = candidate.name, category = "input", precision_index = precision_index, count = false })
    end)
    local ok_output, output_rate = pcall(function()
      if not ok_statistics or not statistics then error("statistics unavailable") end
      return statistics.get_flow_count({ name = candidate.name, category = "output", precision_index = precision_index, count = false })
    end)
    if ok_input and ok_output and type(input_rate) == "number" and type(output_rate) == "number" then
      result[#result + 1] = {
        type = candidate.type, name = candidate.name,
        input_rate = input_rate, output_rate = output_rate,
        precision = precision_name, window_ticks = precision.ticks, units = precision.units,
        source = "force_flow_statistics",
      }
    else
      omissions.unsupported_flow_statistics = omissions.unsupported_flow_statistics + 1
    end
  end
  return result
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
local function nominal_mining_capacity(entity, force, surface)
  local ok, rate = pcall(function()
    local target = entity.mining_target
    if not entity_key(target) or not charted(force, surface, target.position) then return nil end
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

-- `activity` is the requested character-transfer window (internal snapshot).
local function build_material_flow(flow_entities, node_by_key, activity, network_poles)
  local nodes = sorted_rows(node_by_key, key_position)
  local retained = {}
  for index, node in ipairs(nodes) do
    node.id = "node-" .. index
    retained[node._key] = node
  end
  -- Natively get_capacity is one box's capacity, so a segment's capacity sums
  -- its sampled member boxes; an unsampled member only makes it look fuller.
  local segment_capacity = {}
  for _, node in ipairs(nodes) do
    for _, box in ipairs(node._fluid_boxes or {}) do
      if box.segment then segment_capacity[box.segment] = (segment_capacity[box.segment] or 0) + box.capacity end
    end
  end
  local edges, seen_edges, diagnostics = {}, {}, {}
  -- The one charted flow node of the drill's force whose collision box holds
  -- its drop position, by the native point/collision endpoint query, that can
  -- take a mined product: a conveyor carries anything, other recipients must
  -- accept one natively.
  local CONVEYORS = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
    ["lane-splitter"] = true, loader = true, ["loader-1x1"] = true, ["linked-belt"] = true }
  local function pending_drill_recipient(entity)
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
        if candidate.valid and candidate ~= entity and retained[entity_key(candidate)]
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
  local function diagnostic(node, reason, confidence, class, related_edge)
    confidence = confidence or "exact"
    diagnostics[#diagnostics + 1] = { node_id = node.id, reason = reason, confidence = confidence,
      class = class or ((confidence == "ambiguous" or confidence == "unsupported") and "evidence" or "structural"),
      related_edge = related_edge }
  end
  local function status_class(node)
    return STRUCTURAL_RAW_STATUSES[node._raw_status] and "structural" or "transient"
  end
  local function add_edge(from_entity, to_entity, kind, from_box, to_box)
    local from_key, to_key = entity_key(from_entity), entity_key(to_entity)
    local from, to = from_key and retained[from_key], to_key and retained[to_key]
    if not from or not to then return false end
    local key = from.id .. "\0" .. to.id .. "\0" .. kind .. ":" .. tostring(from_box) .. ":" .. tostring(to_box)
    if seen_edges[key] then return true end
    seen_edges[key] = true
    edges[#edges + 1] = { from = from.id, to = to.id, kind = kind, confidence = "exact_runtime_relationship",
      from_fluidbox = from_box, to_fluidbox = to_box }
    return true
  end
  for _, entity in ipairs(flow_entities) do
    local node = retained[entity_key(entity)]
    if node then
      if entity.type == "inserter" then
        local ok_pickup, pickup = pcall(function() return entity.pickup_target end)
        local ok_drop, drop = pcall(function() return entity.drop_target end)
        if not ok_pickup then diagnostic(node, "inserter_pickup_ambiguous_requires_local_inspection", "ambiguous")
        elseif not pickup or not add_edge(pickup, entity, "inserter_pickup") then
          diagnostic(node, "inserter_pickup_has_no_eligible_entity", nil, nil, { kind = "inserter_pickup" })
        end
        if not ok_drop then diagnostic(node, "inserter_drop_ambiguous_requires_local_inspection", "ambiguous")
        elseif not drop or not add_edge(entity, drop, "inserter_drop") then
          diagnostic(node, "inserter_drop_has_no_eligible_sink", nil, nil, { kind = "inserter_drop" })
        end
      elseif entity.type == "mining-drill" then
        local ok_drop, drop = pcall(function() return entity.drop_target end)
        if not ok_drop then diagnostic(node, "output_connection_ambiguous_requires_local_inspection", "ambiguous")
        elseif drop == nil and pending_drill_recipient(entity) then
          -- Factorio binds a drill's drop_target at its first output; until
          -- then exactly one charted recipient at its drop position is a
          -- pending binding, not a missing sink. It still proves no path.
          node._output_pending = true
        elseif not drop or not add_edge(entity, drop, "machine_output") then
          diagnostic(node, "output_has_no_physical_sink", nil, nil, { kind = "machine_output" })
        end
      elseif entity.type == "transport-belt" or entity.type == "underground-belt"
        or entity.type == "splitter" or entity.type == "loader" or entity.type == "loader-1x1" then
        local ok_neighbours, neighbours = pcall(function() return entity.belt_neighbours end)
        if ok_neighbours and type(neighbours) == "table" then
          for _, input in pairs(neighbours.inputs or {}) do add_edge(input, entity, "belt_direction") end
          local outputs = 0
          for _, output in pairs(neighbours.outputs or {}) do if add_edge(entity, output, "belt_direction") then outputs = outputs + 1 end end
          -- belt_neighbours omits the other end of an underground pair.
          if entity.type == "underground-belt" then
            local ok_kind, kind = pcall(function() return entity.belt_to_ground_type end)
            local ok_exit, exit = pcall(function() return entity.neighbours end)
            if ok_kind and kind == "input" and ok_exit and exit and add_edge(entity, exit, "belt_direction") then outputs = outputs + 1 end
          end
          node._belt_outputs = outputs
        else
          diagnostic(node, "belt_connection_ambiguous_requires_local_inspection", "ambiguous")
        end
        if entity.type == "loader" or entity.type == "loader-1x1" then
          local ok_container, container = pcall(function() return entity.loader_container end)
          local ok_kind, kind = pcall(function() return entity.loader_type end)
          if ok_container and container and ok_kind and kind == "input" then add_edge(entity, container, "loader_container")
          elseif ok_container and container and ok_kind and kind == "output" then add_edge(container, entity, "loader_container") end
        end
      end
      if FLUID_TYPES[node.type] then
        if number_property(entity, "unit_number") == nil then diagnostic(node, "fluid_entity_identity_unproven", "unsupported") end
        if not node._fluid_supported or not node._fluid_connections_complete then
          diagnostic(node, "fluid_native_evidence_unproven", "unsupported")
        end
        for _, connection in ipairs(node._fluid_connections or {}) do
          local target = connection._target_entity
          if target then
            local other = retained[entity_key(target)]
            local source_box = node._fluid_boxes and node._fluid_boxes[connection.fluidbox_index]
            local target_box = other and other._fluid_boxes and other._fluid_boxes[connection._target_fluidbox_index]
            local proven = other and other._entity == target and target.surface == entity.surface and target_box and source_box
            if not proven then
              diagnostic(node, "fluid_connected_target_unproven", "unsupported")
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
                diagnostic(node, "fluid_connection_incompatible", nil, "structural")
              end
              add_edge(entity, target, "fluid_connection", source_box.index, target_box.index)
            elseif connection.flow_direction ~= "input" then
              diagnostic(node, "fluid_direction_unproven", "unsupported")
            end
          end
        end
      end
      if node.status == "full_output" then diagnostic(node, "downstream_inventory_blocked", nil, status_class(node)) end
      if node.status == "no_power" or node.status == "low_power" then diagnostic(node, "missing_power", nil, status_class(node)) end
      if node.status == "no_fuel" then diagnostic(node, "missing_fuel", nil, status_class(node)) end
      if node.status == "insufficient_input" then diagnostic(node, "missing_or_mismatched_input", "status_only", status_class(node)) end
    end
  end
  for _, node in ipairs(nodes) do
    for _, box in ipairs(node._fluid_boxes or {}) do
      box.segment_capacity = box.segment and segment_capacity[box.segment] or box.capacity
    end
  end
  local generators = {}
  for _, node in ipairs(nodes) do
    if node.type == "generator" then
      local network = number_property(node._entity, "electric_network_id")
      node._power_network = network
      if not network then diagnostic(node, "generator_electrical_network_unproven", "unsupported")
      else
        generators[network] = generators[network] or {}
        generators[network][#generators[network] + 1] = node
      end
    end
  end
  for _, node in ipairs(nodes) do
    local ok, energy_source = pcall(function() return node._entity.prototype.electric_energy_source_prototype end)
    local network = number_property(node._entity, "electric_network_id")
    local material_relevant = node.role == "source" or node.role == "processor" or node.type == "pump"
    for _, edge in ipairs(edges) do
      if edge.kind ~= "fluid_connection" and (edge.from == node.id or edge.to == node.id)
        and (node.role == "transport" or node.role == "sink") then material_relevant = true end
    end
    if ok and energy_source and node.type ~= "generator" and generators[network] and material_relevant then
      node._power_network = network
      node._power_consumer = true
      if energy_source.usage_priority ~= "primary-input" and energy_source.usage_priority ~= "secondary-input" then
        diagnostic(node, "electrical_consumer_usage_unproven", "unsupported")
      end
      for _, generator in ipairs(generators[network]) do
        add_edge(generator._entity, node._entity, "electrical_dependency")
        generator._power_delivery = true
      end
    end
  end
  for _, node in ipairs(nodes) do
    if node.type == "generator" and not node._power_delivery then
      diagnostic(node, "electrical_material_consumer_unproven", "unsupported")
    end
  end
  -- An engine on standby: its own box holds steam above the fluid's default
  -- temperature and every material consumer on its network is idle with a
  -- charged buffer, so it serves at most their constant drain. No material
  -- demand is neither an interruption nor blocked output.
  local demand = {}
  for _, node in ipairs(nodes) do
    if node._power_consumer then
      local energy = number_property(node._entity, "energy")
      if not IDLE_CONSUMER_STATUSES[node.status] or not energy or energy <= 0 then demand[node._power_network] = true end
    end
  end
  for _, node in ipairs(nodes) do
    local box = node.type == "generator" and node._fluid_supported and node._fluid_boxes and node._fluid_boxes[1]
    if box and node._power_delivery and not demand[node._power_network]
      and (number_property(node._entity, "energy_generated_last_tick") or -1) >= 0
      and box.amount > 0 and type(box.temperature) == "number" and box.temperature > node._generator.default_temperature
      and fluid_compatible(box, box.name, box.temperature) then
      node._standby = true
    end
  end
  table.sort(edges, function(a, b)
    if a.from ~= b.from then return a.from < b.from end
    if a.to ~= b.to then return a.to < b.to end
    if a.kind ~= b.kind then return a.kind < b.kind end
    if a.from_fluidbox ~= b.from_fluidbox then return (a.from_fluidbox or 0) < (b.from_fluidbox or 0) end
    return (a.to_fluidbox or 0) < (b.to_fluidbox or 0)
  end)
  -- A belt run is the tiles joined by belt_direction edges. Its consumer may
  -- pick up anywhere along it (inserter pickup, loader container), so a dead
  -- end is decided per run, after every exact edge exists, at its last tile.
  local run_parent = {}
  for _, node in ipairs(nodes) do if node._belt_outputs then run_parent[node.id] = node.id end end
  local function run_root(id)
    while run_parent[id] ~= id do run_parent[id] = run_parent[run_parent[id]]; id = run_parent[id] end
    return id
  end
  local run_consumed = {}
  for _, edge in ipairs(edges) do
    if edge.kind == "belt_direction" and run_parent[edge.from] and run_parent[edge.to] then
      local a, b = run_root(edge.from), run_root(edge.to)
      if a ~= b then run_parent[b] = a end
    end
  end
  for _, edge in ipairs(edges) do
    if edge.kind ~= "belt_direction" and run_parent[edge.from] then run_consumed[run_root(edge.from)] = true end
  end
  for _, node in ipairs(nodes) do
    if node._belt_outputs == 0 and not run_consumed[run_root(node.id)] then
      diagnostic(node, "belt_dead_end_without_consumer", nil, "structural", { kind = "belt_or_pickup" })
    end
  end

  local parent = {}; for _, node in ipairs(nodes) do parent[node.id] = node.id end
  local function root(id)
    while parent[id] ~= id do parent[id] = parent[parent[id]]; id = parent[id] end
    return id
  end
  local function join(a, b) a, b = root(a), root(b); if a ~= b then parent[b] = a end end
  -- Power is a dependency, not a material path: a consumer keeps its own
  -- material component and names its network's supply (checked per
  -- component below). Generators sharing a network supply it together.
  for _, edge in ipairs(edges) do if edge.kind ~= "electrical_dependency" then join(edge.from, edge.to) end end
  for _, list in pairs(generators) do
    for index = 2, #list do join(list[1].id, list[index].id) end
  end
  local by_root = {}
  for _, node in ipairs(nodes) do
    local r = root(node.id)
    local component = by_root[r] or { node_ids = {}, roles = {}, status_counts = {}, edge_count = 0,
      products_finished_total = 0, character_transfer_actions = 0, last_character_transfer_tick = nil,
      _edges = {}, _diagnostics = {} }
    by_root[r] = component
    component.node_ids[#component.node_ids + 1] = node.id
    component.roles[node.role] = (component.roles[node.role] or 0) + 1
    component.status_counts[node.status] = (component.status_counts[node.status] or 0) + 1
    component.products_finished_total = component.products_finished_total + (node.products_finished or 0)
  end
  for _, edge in ipairs(edges) do
    if edge.kind ~= "electrical_dependency" then
      local component = by_root[root(edge.from)]
      component.edge_count = component.edge_count + 1
      component._edges[#component._edges + 1] = edge
    end
  end
  for _, event in ipairs(activity.events or {}) do
    if event.target then
      local key = string.format("%s\0%s\0%.17g\0%.17g", event.target.name, event.target.type,
        event.target.position.x, event.target.position.y)
      local node = retained[key]
      if node then
        local component = by_root[root(node.id)]
        component.character_transfer_actions = component.character_transfer_actions + 1
        component.last_character_transfer_tick = math.max(component.last_character_transfer_tick or 0,
          tonumber(event.tick) or 0)
      end
    end
  end
  local components = sorted_rows(by_root, function(a, b) return a.node_ids[1] < b.node_ids[1] end)
  local node_by_id, incoming, outgoing, pickup_of = {}, {}, {}, {}
  for _, node in ipairs(nodes) do node_by_id[node.id], incoming[node.id], outgoing[node.id] = node, {}, {} end
  for _, edge in ipairs(edges) do
    if edge.kind ~= "electrical_dependency" then
      incoming[edge.to][#incoming[edge.to] + 1] = edge.from
      outgoing[edge.from][#outgoing[edge.from] + 1] = edge.to
      if edge.kind == "inserter_pickup" then pickup_of[edge.to] = edge.from end
    end
  end
  local function product_matches(node, ingredient, fuel_only)
    for _, product in ipairs(node.products or {}) do
      if fuel_only and product.fuel_category and ingredient[product.fuel_category] then return true end
      if not fuel_only and product.name == ingredient.name and product.type == ingredient.type then return true end
    end
    return false
  end
  local function upstream_proven(start_id, ingredient, fuel_only)
    local queue, seen, head = {}, { [start_id] = true }, 1
    for _, id in ipairs(incoming[start_id]) do queue[#queue + 1] = id end
    while head <= #queue do
      local id = queue[head]; head = head + 1
      -- A burner source may physically refuel itself from its own output
      -- (a coal drill feeding back through transport): that loop is fuel
      -- provenance. Its own product never stands in for another input.
      if id == start_id and fuel_only and node_by_id[id].role == "source"
        and product_matches(node_by_id[id], ingredient, true) then return true end
      if not seen[id] then
        seen[id] = true
        local node = node_by_id[id]
        if node and node.role ~= "buffer" and product_matches(node, ingredient, fuel_only) then return true end
        -- A processor transforms its inputs; an ancestor's product cannot
        -- stand in for this node's different physical output.
        if node and (node.role == "transport" or node.role == "buffer") then
          for _, parent_id in ipairs(incoming[id] or {}) do queue[#queue + 1] = parent_id end
        end
      end
    end
    return false
  end
  -- A replenishment inserter may wait at the ordinary fuel target while
  -- the burner continues working and its fuel inventory still has space.
  -- Prove the specific held fuel and physical supply, never infer a limit
  -- from a hard-coded stock count or exempt other full-output entities.
  for _, node in ipairs(nodes) do
    if node.type == "inserter" and node._waiting_for_destination then
      local pickup, destination
      for _, edge in ipairs(edges) do
        if edge.from == node.id and edge.kind == "inserter_drop" then destination = node_by_id[edge.to] end
        if edge.to == node.id and edge.kind == "inserter_pickup" then pickup = node_by_id[edge.from] end
      end
      if pickup and destination and destination._fuel_destination_proven
        and destination.requires_fuel and destination.status == "working" then
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
        local supplied = (pickup.role == "source" or pickup.role == "processor") and product_matches(pickup, product, false)
          or (pickup.role == "transport" or pickup.role == "buffer") and upstream_proven(pickup.id, product, false)
        if ok and fuel and supplied then
          node.fuel_return_saturation = { destination_node_id = destination.id, fuel = fuel, quality = quality,
            identity_source = identity, observed_status = "waiting_for_space_in_destination",
            evidence = "supplied_working_burner_with_fuel_inventory_space" }
        end
      end
    end
  end
  local function reaches_downstream(start_id)
    local queue, seen, head = { start_id }, {}, 1
    while head <= #queue do
      local id = queue[head]; head = head + 1
      if not seen[id] then
        seen[id] = true
        if id ~= start_id and node_by_id[id] and (node_by_id[id].role == "sink" or node_by_id[id]._downstream_buffer) then return true end
        for _, next_id in ipairs(outgoing[id] or {}) do queue[#queue + 1] = next_id end
      end
    end
    return false
  end
  local source_by_resource = {}
  for _, node in ipairs(nodes) do
    local source = node._source_production
    if source and source.resource_key then
      local previous = source_by_resource[source.resource_key]
      if previous then
        diagnostic(previous, "shared_mining_target_production_ambiguous", "ambiguous")
        diagnostic(node, "shared_mining_target_production_ambiguous", "ambiguous")
      else source_by_resource[source.resource_key] = node end
    end
  end
  -- The nodes a node's output reaches first, through transport only.
  local function first_reached(start_id)
    local reached, queue, seen, head = {}, { start_id }, { [start_id] = true }, 1
    while head <= #queue do
      local id = queue[head]; head = head + 1
      for _, next_id in ipairs(outgoing[id] or {}) do
        local next_node = node_by_id[next_id]
        if not seen[next_id] and next_node then
          seen[next_id] = true
          if next_node.role == "transport" and not (next_node.type == "inserter" and pickup_of[next_id] ~= id) then
            queue[#queue + 1] = next_id
          else reached[#reached + 1] = next_node end
        end
      end
    end
    return reached
  end
  local function ancestors(start_id)
    local queue, seen, head = { start_id }, {}, 1
    while head <= #queue do
      local id = queue[head]; head = head + 1
      for _, parent_id in ipairs(incoming[id] or {}) do
        if not seen[parent_id] then seen[parent_id] = true; queue[#queue + 1] = parent_id end
      end
    end
    return seen
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
  local function material_upstream(start_id)
    local queue, seen, head = {}, { [start_id] = true }, 1
    for _, id in ipairs(incoming[start_id]) do queue[#queue + 1] = id end
    while head <= #queue do
      local id = queue[head]; head = head + 1
      local node = node_by_id[id]
      if node and not seen[id] then
        seen[id] = true
        if node.role == "source" or node.role == "processor" then
          for _, product in ipairs(node.products) do if not product.fuel_category then return true end end
        elseif node.role == "transport" or node.role == "buffer" then
          for _, parent_id in ipairs(incoming[id] or {}) do queue[#queue + 1] = parent_id end
        end
      end
    end
    return false
  end
  -- The products that physically reach a node: its own when it produces,
  -- otherwise its producers' through transport, buffers and labs (an
  -- inserter relays a lab's packs into the next lab of a chain).
  local function upstream_products(start_id)
    local products, queue, seen, head = {}, { start_id }, {}, 1
    while head <= #queue do
      local id = queue[head]; head = head + 1
      if not seen[id] then
        seen[id] = true
        local upstream = node_by_id[id]
        if upstream.role == "source" or upstream.role == "processor" then
          for _, product in ipairs(upstream.products) do products[product.type .. ":" .. product.name] = product end
        elseif upstream.type == "inserter" then
          -- Another inserter drops into this burner's fuel inventory, never
          -- its hand. Only the pickup target supplies cargo relayed onward.
          if pickup_of[id] then queue[#queue + 1] = pickup_of[id] end
        elseif upstream.role == "transport" or upstream.role == "buffer" or upstream.type == "lab" or id == start_id then
          for _, parent_id in ipairs(incoming[id]) do queue[#queue + 1] = parent_id end
        end
      end
    end
    return products
  end
  for _, node in ipairs(nodes) do
    if node.role == "buffer" or node.role == "sink" then
      local products = upstream_products(node.id)
      -- A buffer is terminal when nothing leaves it, or when everything that
      -- leaves only refuels producers upstream of it: a self-fuelling loop's
      -- chest is where its surplus ends, not an intermediate stage.
      node._downstream_buffer = false
      if node.role == "buffer" then
        local reached, upstream = first_reached(node.id), nil
        node._downstream_buffer = #outgoing[node.id] == 0 or #reached > 0
        for _, target in ipairs(reached) do
          upstream = upstream or ancestors(node.id)
          if not (upstream[target.id] and fuel_inlet(products, target)) then node._downstream_buffer = false end
        end
      end
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
          diagnostic(node, node.role == "buffer" and "downstream_buffer_acceptance_unproven"
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
  end
  for _, row in ipairs(diagnostics) do
    if row.reason == "downstream_inventory_blocked" and node_by_id[row.node_id].fuel_return_saturation then
      row.nonblocking_reason = "proven_fuel_return_saturation"
    end
  end
  table.sort(diagnostics, function(a, b)
    return a.node_id == b.node_id and a.reason < b.reason or a.node_id < b.node_id
  end)
  for _, diagnostic in ipairs(diagnostics) do
    local component = by_root[root(diagnostic.node_id)]
    component._diagnostics[#component._diagnostics + 1] = diagnostic
  end
  for index, component in ipairs(components) do
    component.component_id = "component-" .. index
    local local_work = (component.status_counts.working or 0) > 0
    local rows, signature_rows, producing_nodes, accepting_sinks = {}, {}, 0, 0
    local buffers, consumers, blocked_output = 0, 0, false
    local unreached, endpoints = {}, {}
    -- Every row is located at the node where a repair or inspection starts.
    -- Transient rows are single status samples and never gate topology.
    local function block(node, reason, class, related_edge, gate)
      rows[#rows + 1] = { reason = reason, class = class, node_id = node.id, position = node.position,
        entity = node.name, related_edge = related_edge, gate = gate }
    end
    for _, id in ipairs(component.node_ids) do
      local node = node_by_id[id]
      if FLUID_TYPES[node.type] or node._power_consumer then
        signature_rows[#signature_rows + 1] = node._key .. ":network:" .. tostring(node._power_network)
        if node._generator then
          for _, field in ipairs({ "default_temperature", "heat_capacity", "effectivity", "maximum_temperature" }) do
            signature_rows[#signature_rows + 1] = node._key .. ":generator:" .. field .. ":" .. tostring(node._generator[field])
          end
        end
      end
      signature_rows[#signature_rows + 1] = node._key .. ":" .. tostring(node.direction) .. ":"
        .. tostring(number_property(node._entity, "unit_number")) .. ":" .. tostring(node.recipe)
      for _, box in ipairs(node._fluid_boxes or {}) do
        signature_rows[#signature_rows + 1] = table.concat({ node._key, "box", tostring(box.index),
          tostring(box.segment), tostring(box.production_type), tostring(box.filter), tostring(box.name),
          tostring(box.minimum_temperature), tostring(box.maximum_temperature), tostring(box.capacity) }, ":")
      end
      for _, connection in ipairs(node._fluid_connections or {}) do
        signature_rows[#signature_rows + 1] = table.concat({ node._key, "connection",
          tostring(connection.fluidbox_index), tostring(connection._pipe_connection_index),
          tostring(connection.connection_type), tostring(connection.flow_direction),
          tostring(connection.position.x), tostring(connection.position.y),
          tostring(connection.target_position.x), tostring(connection.target_position.y),
          tostring(entity_key(connection._target_entity)), tostring(connection._target_fluidbox_index),
          tostring(connection._target_pipe_connection_index) }, ":")
      end
      for _, product in ipairs(node.products) do
        if product.type == "fluid" then signature_rows[#signature_rows + 1] = node._key .. ":temperature:" .. tostring(product.temperature) end
      end
      for _, ingredient in ipairs(node.ingredients) do signature_rows[#signature_rows + 1] = node._key .. ":input:" .. ingredient.type .. ":" .. ingredient.name end
      for _, product in ipairs(node.products) do signature_rows[#signature_rows + 1] = node._key .. ":output:" .. product.type .. ":" .. product.name end
      if node.role == "sink" then
        consumers = consumers + 1
        -- A lab with no research selected consumes nothing until one is.
        if node.type == "lab" and node._raw_status == "no_research_in_progress" then
          block(node, "consumer_idle_no_research", "evidence", nil, "readiness")
        elseif node._missing_science_pack then
          block(node, "consumer_missing_required_science_pack", "evidence", nil, "readiness")
        end
        endpoints[#endpoints + 1] = node
      elseif node._downstream_buffer then
        buffers = buffers + 1
        endpoints[#endpoints + 1] = node
        if node._accepting then accepting_sinks = accepting_sinks + 1 end
      end
      -- Only an inventory that cannot accept the item proves blocked output.
      if node._blocked_output then blocked_output = true; block(node, "blocked_output", "structural") end
      if node.role == "source" or node.role == "processor" then
        producing_nodes = producing_nodes + 1
        if node.role == "source" and not node._source_production.working then
          block(node, "source_not_locally_operating", "transient")
        end
        -- A furnace before its first smelt has no recipe yet: with material
        -- arriving from upstream, that is a later start, not a defect.
        if #node.products == 0 and node.type == "furnace" and material_upstream(id) then
          block(node, "furnace_recipe_not_yet_established", "evidence", { kind = "material_input" }, "readiness")
        elseif #node.products == 0 then block(node, "output_identity_unproven", "structural") end
        if not reaches_downstream(id) then
          unreached[#unreached + 1] = node
          if node._output_pending then
            block(node, "drill_output_target_pending_first_output", "evidence", { kind = "machine_output" }, "readiness")
          else
            block(node, "downstream_acceptance_path_unproven", "structural",
              { kind = "downstream_path" }, "readiness")
          end
        end
      end
      if node.role == "sink" and node._accepting then accepting_sinks = accepting_sinks + 1 end
      for _, ingredient in ipairs(node.ingredients or {}) do
        if not upstream_proven(id, ingredient, false) then
          block(node, "material_input_provenance_unresolved:" .. ingredient.type .. ":" .. ingredient.name, "structural",
            { kind = "material_input" })
        end
      end
      if node.requires_fuel and not upstream_proven(id, node.fuel_categories or {}, true) then
        local related_edge = { kind = "fuel_input" }
        -- A burner inserter refuels only from fuel it carries. When its
        -- produced cargo is known and none of it burns here, say so: it needs
        -- a fuel feed of its own.
        if node.role == "transport" then
          local cargo = upstream_products(id)
          if next(cargo) then
            related_edge.transport_cargo_fuel = false
            for _, product in pairs(cargo) do
              if product.fuel_category and (node.fuel_categories or {})[product.fuel_category] then
                related_edge.transport_cargo_fuel = nil
              end
            end
          end
        end
        block(node, next(node.fuel_categories or {}) and "fuel_input_provenance_unresolved" or "fuel_compatibility_unproven",
          "structural", related_edge, "readiness")
      end
      if node.status == "no_power" or node.status == "low_power" or node.status == "no_fuel"
        or node.status == "insufficient_input" or node.status == "full_output" and not node.fuel_return_saturation
        or node.status == "disabled" or node.status == "no_resources" then
        block(node, "nonproductive_status:" .. node.status, status_class(node))
      end
    end
    for _, edge in ipairs(component._edges) do
      signature_rows[#signature_rows + 1] = node_by_id[edge.from]._key .. "->" .. node_by_id[edge.to]._key .. ":" .. edge.kind .. ":" .. tostring(edge.from_fluidbox) .. ":" .. tostring(edge.to_fluidbox)
    end
    -- Electrical dependents are part of the supplying component's identity
    -- without joining their material paths.
    for _, edge in ipairs(edges) do
      if edge.kind == "electrical_dependency" and by_root[root(edge.from)] == component
        and by_root[root(edge.to)] ~= component then
        local node = node_by_id[edge.to]
        signature_rows[#signature_rows + 1] = table.concat({ "electrical-dependent", node._key,
          tostring(number_property(node._entity, "unit_number")), tostring(node._power_network),
          tostring(node.direction) }, ":")
        for _, connection in ipairs(edges) do
          if connection.from == node.id or connection.to == node.id then
            signature_rows[#signature_rows + 1] = table.concat({ "electrical-dependent-connection", connection.kind,
              node_by_id[connection.from]._key, node_by_id[connection.to]._key }, ":")
          end
        end
      end
    end
    table.sort(signature_rows)
    -- Compact identifier of the component's exact topology.
    local signature = table.concat(signature_rows, "|")
    local h1, h2 = 0, 0
    for i = 1, #signature do
      local byte = signature:byte(i)
      h1, h2 = (h1 * 31 + byte) % 4294967291, (h2 * 37 + byte) % 4294967279
    end
    component.component_signature = string.format("%08x%08x", h1, h2)
    for _, diagnostic in ipairs(component._diagnostics) do
      local node = node_by_id[diagnostic.node_id]
      if diagnostic.reason ~= "downstream_inventory_blocked" or not node.fuel_return_saturation then
        block(node, "relationship_diagnostic:" .. diagnostic.reason, diagnostic.class, diagnostic.related_edge)
      end
    end
    -- Component-level gaps attach to the producers lacking a downstream path,
    -- or to the component's first node when no producer can carry the row.
    local anchors = #unreached > 0 and unreached or { node_by_id[component.node_ids[1]] }
    if producing_nodes == 0 or (component.roles.source or 0) == 0
      or buffers + consumers == 0 then
      for _, node in ipairs(anchors) do
        block(node, "physical_source_downstream_path_unproven", "structural",
          { kind = "downstream_path" }, "readiness")
      end
    end
    if accepting_sinks == 0 then
      for _, node in ipairs(#endpoints > 0 and endpoints or anchors) do block(node, "downstream_acceptance_not_observed", "transient") end
    end
    local blocker_names, seen_blocker, details, seen_detail = {}, {}, {}, {}
    local hard_rows = {}
    for _, row in ipairs(rows) do
      if row.class ~= "transient" then
        hard_rows[#hard_rows + 1] = row
        if not seen_blocker[row.reason] then seen_blocker[row.reason] = true; blocker_names[#blocker_names + 1] = row.reason end
      end
    end
    table.sort(blocker_names)
    table.sort(hard_rows, function(a, b)
      if (a.gate == "readiness") ~= (b.gate == "readiness") then return a.gate == "readiness" end
      if a.position.y ~= b.position.y then return a.position.y < b.position.y end
      if a.position.x ~= b.position.x then return a.position.x < b.position.x end
      return a.reason < b.reason
    end)
    -- One compact row per distinct site; every name stays in autonomy_blockers.
    for _, row in ipairs(hard_rows) do
      local key = string.format("%.17g\0%.17g", row.position.x, row.position.y)
      if #details < MAX_COMPONENT_BLOCKER_DETAILS and not seen_detail[key] then
        seen_detail[key] = true
        details[#details + 1] = { reason = row.reason, class = row.class, position = row.position,
          entity = row.entity, related_edge = row.related_edge }
      end
    end
    component.state = {
      downstream_kind = buffers > 0 and (consumers > 0 and "mixed" or "buffer") or (consumers > 0 and "consumer" or "none"),
      blocked_output = blocked_output,
      machine_present = true,
      locally_operating = local_work,
      autonomy_topology_ready = #hard_rows == 0,
      autonomy_blockers = blocker_names,
      blocker_details = details,
    }
  end
  return { nodes = nodes, edges = edges, components = components, diagnostics = diagnostics,
    relationship_semantics = "exact_runtime_targets_only; absence_or_unsupported_is_not_a_connection" }
end

-- Caps are a presentation concern. Never mutate the graph itself.
local function present_flow(flow, omissions)
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
  -- Production lines the mod tracks (autonomy.lua), beside the components.
  for key, value in pairs(autonomy.counts()) do result[key] = value end
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
local POWER_PRODUCER_TYPES = { generator = true, ["burner-generator"] = true, ["solar-panel"] = true,
  ["fusion-generator"] = true }
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
local function add_contents(bucket, source)
  local ok, contents = pcall(function() return source.get_contents() end)
  if not ok or type(contents) ~= "table" then return end
  for _, row in ipairs(contents) do
    if type(row) == "table" and type(row.name) == "string" then
      bucket[row.name] = (bucket[row.name] or 0) + (tonumber(row.count) or 0)
    end
  end
end

local function build_stockpiles(own)
  local items, belts = {}, {}
  local function hold(item, count, entity, kind)
    if count <= 0 then return end
    local row = items[item] or { item = item, total = 0, holders = {} }
    items[item] = row
    row.total = row.total + count
    row.holders[#row.holders + 1] = { entity = entity.name, position = xy(entity.position), count = count, kind = kind }
  end
  for _, record in ipairs(own) do
    local entity = record.entity
    if BELT_TYPES[entity.type] then
      belts[#belts + 1] = entity
    elseif CHEST_TYPES[entity.type] or OUTPUT_TYPES[entity.type] then
      -- The status cache reads contents while it walks (record.contents).
      local bucket = record.contents
      if not bucket then
        local inventory = stock_inventory(entity)
        if inventory then bucket = {}; add_contents(bucket, inventory) end
      end
      for item, count in pairs(bucket or {}) do hold(item, count, entity, CHEST_TYPES[entity.type] and "chest" or "machine_output") end
    end
  end
  -- One holder per connected belt run, located at the run's entity carrying
  -- most of that item. Runs join through belt_neighbours among the collected
  -- (own, charted) belts only, so a run never reaches into uncharted chunks.
  local parent, index_of = {}, {}
  for index, belt in ipairs(belts) do
    parent[index] = index
    local id = number_property(belt, "unit_number")
    if id then index_of[id] = index end
  end
  local function find(index)
    while parent[index] ~= index do parent[index] = parent[parent[index]]; index = parent[index] end
    return index
  end
  for index, belt in ipairs(belts) do
    local ok, outputs = pcall(function() return belt.belt_neighbours.outputs end)
    for _, other in ipairs(ok and type(outputs) == "table" and outputs or {}) do
      local other_index = index_of[number_property(other, "unit_number") or false]
      if other_index then parent[find(index)] = find(other_index) end
    end
    -- belt_neighbours omits the other end of an underground pair.
    if belt.type == "underground-belt" then
      local ok_pair, pair = pcall(function() return belt.neighbours end)
      local pair_index = ok_pair and pair and index_of[number_property(pair, "unit_number") or false]
      if pair_index then parent[find(index)] = find(pair_index) end
    end
  end
  local runs = {}
  for index, belt in ipairs(belts) do
    local bucket = {}
    for _, line in ipairs(belt_lines(belt)) do add_contents(bucket, line) end
    local run = runs[find(index)] or {}
    runs[find(index)] = run
    for item, count in pairs(bucket) do
      local held = run[item] or { count = 0, best = 0 }
      run[item] = held
      held.count = held.count + count
      if count > held.best or (count == held.best and held.entity and key_position(belt, held.entity)) then
        held.best, held.entity = count, belt
      end
    end
  end
  for _, run in pairs(runs) do
    for item, held in pairs(run) do if held.entity then hold(item, held.count, held.entity, "belt") end end
  end
  local rows = sorted_rows(items, function(a, b)
    if a.total ~= b.total then return a.total > b.total end
    return a.item < b.item
  end)
  for _, row in ipairs(rows) do
    table.sort(row.holders, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      return row_position(a, b)
    end)
    row.holders_omitted = cap_rows(row.holders, MAX_STOCK_HOLDERS)
  end
  return rows, cap_rows(rows, MAX_STOCK_ITEMS)
end

-- One row per charted chunk holding own machines. This is independent of the
-- detail=full landmark cap, so a full landmark list cannot hide a remote site.
local function build_sites(own)
  local by_chunk = {}
  for _, record in ipairs(own) do
    local entity = record.entity
    if SITE_TYPES[entity.type] then
      local cx, cy = math.floor(entity.position.x / 32), math.floor(entity.position.y / 32)
      local key = cx .. "," .. cy
      local site = by_chunk[key] or { chunk = { x = cx, y = cy }, machines = {}, _count = 0, _x = 0, _y = 0 }
      by_chunk[key] = site
      site.machines[entity.name] = (site.machines[entity.name] or 0) + 1
      site._count, site._x, site._y = site._count + 1, site._x + entity.position.x, site._y + entity.position.y
    end
  end
  local rows = sorted_rows(by_chunk, function(a, b)
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

local function build_patches(cells)
  -- Cells may be cached (patch_cache): visits are marked here, never on them.
  local rows, seen = {}, {}
  for name, by_name in pairs(cells) do
    for _, first in pairs(by_name) do
      if not seen[first] then
        seen[first] = true
        local patch = { name = name, amount = 0, tiles = 0, _x = 0, _y = 0,
          _left = first.left, _right = first.right, _top = first.top, _bottom = first.bottom }
        local stack = { first }
        while #stack > 0 do
          local cell = table.remove(stack)
          patch.amount, patch.tiles = patch.amount + cell.amount, patch.tiles + cell.tiles
          patch._x, patch._y = patch._x + cell.x, patch._y + cell.y
          patch._left, patch._right = math.min(patch._left, cell.left), math.max(patch._right, cell.right)
          patch._top, patch._bottom = math.min(patch._top, cell.top), math.max(patch._bottom, cell.bottom)
          for dy = -1, 1 do for dx = -1, 1 do
            local neighbour = by_name[(cell.cx + dx) .. "," .. (cell.cy + dy)]
            if neighbour and not seen[neighbour] then seen[neighbour] = true; stack[#stack + 1] = neighbour end
          end end
        end
        patch.bbox = { left_top = { x = math.floor(patch._left), y = math.floor(patch._top) },
          right_bottom = { x = math.ceil(patch._right), y = math.ceil(patch._bottom) } }
        patch.centroid = { x = math.floor(patch._x / patch.tiles * 10 + 0.5) / 10,
          y = math.floor(patch._y / patch.tiles * 10 + 0.5) / 10 }
        patch._x, patch._y, patch._left, patch._right, patch._top, patch._bottom = nil, nil, nil, nil, nil, nil
        rows[#rows + 1] = patch
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.amount ~= b.amount then return a.amount > b.amount end
    if a.name ~= b.name then return a.name < b.name end
    if a.centroid.y ~= b.centroid.y then return a.centroid.y < b.centroid.y end
    return a.centroid.x < b.centroid.x
  end)
  return rows, cap_rows(rows, MAX_PATCHES)
end

-- Per electric network, as the electric-network view shows it.
--   production_w / consumption_w: the five-second average of the network's
--     native electric_network_statistics (read from one of its charted poles),
--     summed over every producer (output) and consumer (input) row. Electric
--     flow statistics count joules per tick, so the sum is multiplied by 60.
--   capacity_w: nameplate, the sum of each producer prototype's
--     get_max_energy_production (joules per tick) times 60; fuel, steam and
--     daylight are not considered.
--   satisfaction: 1 while no consumer on the network samples low_power or
--     no_power. Otherwise min(1, production_w / demand), where demand is the
--     nominal get_max_energy_usage (times 60) of the consumers that are trying
--     to run (working, low_power or no_power).
--   accumulator_j / accumulator_capacity_j: summed energy and
--     electric_buffer_size of the network's accumulators.
--   demand_w: that nominal demand; engines_needed: steam engines whose
--     nameplate covers it (how many the network needs for 100%).
local STEAM_ENGINE_WATTS = 900000
local function engine_watts()
  local ok, watts = pcall(function() return prototypes.entity["steam-engine"].get_max_energy_production() * 60 end)
  return ok and type(watts) == "number" and watts > 0 and watts or STEAM_ENGINE_WATTS
end
local function nominal_watts(entity, method)
  local ok, value = pcall(function()
    local ok_quality, quality = pcall(function() return entity.quality end)
    return entity.prototype[method](ok_quality and quality or nil)
  end)
  return ok and type(value) == "number" and value * 60 or 0
end

local function build_power(own, network_poles)
  local networks = {}
  for _, record in ipairs(own) do
    local entity, id = record.entity, record.network_id
    if id and entity.type ~= "electric-pole" then
      local network = networks[id] or { id = id, capacity_w = 0, accumulator_j = 0, accumulator_capacity_j = 0,
        producers = {}, consumers = {}, _starved = 0, _demand = 0 }
      networks[id] = network
      if entity.type == "accumulator" then
        network.accumulator_j = network.accumulator_j + (number_property(entity, "energy") or 0)
        network.accumulator_capacity_j = network.accumulator_capacity_j + (number_property(entity, "electric_buffer_size") or 0)
      elseif POWER_PRODUCER_TYPES[entity.type] then
        network.producers[entity.name] = (network.producers[entity.name] or 0) + 1
        network.capacity_w = network.capacity_w + (record.capacity_w or nominal_watts(entity, "get_max_energy_production"))
      else
        network.consumers[entity.name] = (network.consumers[entity.name] or 0) + 1
        local status = normalize_status(record.status)
        if status == "low_power" or status == "no_power" then network._starved = network._starved + 1 end
        if status == "working" or status == "low_power" or status == "no_power" then
          network._demand = network._demand + (record.usage_w or nominal_watts(entity, "get_max_energy_usage"))
        end
      end
    end
  end
  local precision_index = defines and defines.flow_precision_index and defines.flow_precision_index.five_seconds
  local rows = sorted_rows(networks, function(a, b) return a.id < b.id end)
  for _, network in ipairs(rows) do
    local ok, statistics = pcall(function() return network_poles[network.id].electric_network_statistics end)
    local function watts(counts, category)
      local ok_sum, sum = pcall(function()
        local total = 0
        for name in pairs(statistics[counts]) do
          total = total + statistics.get_flow_count({ name = name, category = category,
            precision_index = precision_index, count = false })
        end
        return total * 60
      end)
      if ok_sum and type(sum) == "number" then return sum end
      return nil
    end
    network.statistics_available = ok and statistics ~= nil and precision_index ~= nil
    if network.statistics_available then
      network.production_w, network.consumption_w = watts("output_counts", "output"), watts("input_counts", "input")
      network.statistics_available = network.production_w ~= nil and network.consumption_w ~= nil
    end
    if network._starved == 0 then
      network.satisfaction = 1
    elseif network.production_w and network._demand > 0 then
      network.satisfaction = math.floor(math.min(1, network.production_w / network._demand) * 1000 + 0.5) / 1000
    else
      network.satisfaction = 0
    end
    network.starved_consumers = network._starved
    network.demand_w = network._demand
    network.engines_needed = math.ceil(network._demand / engine_watts())
    network._starved, network._demand = nil, nil
  end
  return rows, cap_rows(rows, MAX_POWER_NETWORKS)
end

local function build_problems(own)
  local rows, by_status = {}, {}
  for _, record in ipairs(own) do
    if PROBLEM_STATUSES[record.status] then
      rows[#rows + 1] = { entity = record.entity.name, position = xy(record.entity.position),
        status = record.status, _inserter = record.entity.type == "inserter",
        _rank = PROBLEM_RANK[record.status] or INPUT_WAIT_RANK }
      by_status[record.status] = (by_status[record.status] or 0) + 1
    end
  end
  -- Input waits last, then machines before inserters (a dead network must not
  -- fill the cap with arms), then the more severe status.
  table.sort(rows, function(a, b)
    local a_wait, b_wait = a._rank == INPUT_WAIT_RANK, b._rank == INPUT_WAIT_RANK
    if a_wait ~= b_wait then return b_wait end
    if a._inserter ~= b._inserter then return b._inserter end
    if a._rank ~= b._rank then return a._rank < b._rank end
    return row_position(a, b)
  end)
  local total = #rows
  cap_rows(rows, MAX_PROBLEMS)
  for _, row in ipairs(rows) do row._inserter, row._rank = nil, nil end
  -- Per-status counts cover every problem, including rows the cap left out.
  return rows, total, by_status
end

-- Every item and fluid the force's native statistics for this surface have
-- ever counted: input is produced, output is consumed. Only this section
-- lifts the force_flows row cap.
local function read_all_flows(force, surface, precision_name)
  local precision_index = defines and defines.flow_precision_index and defines.flow_precision_index[precision_name]
  local rows = {}
  for _, kind in ipairs({ "item", "fluid" }) do
    local getter_name = kind == "fluid" and "get_fluid_production_statistics" or "get_item_production_statistics"
    local ok, statistics = pcall(function() return force[getter_name](surface) end)
    if ok and statistics then
      local function counts(field)
        local ok_counts, value = pcall(function() return statistics[field] end)
        return ok_counts and type(value) == "table" and value or {}
      end
      local produced, consumed, names = counts("input_counts"), counts("output_counts"), {}
      for name in pairs(produced) do names[name] = true end
      for name in pairs(consumed) do names[name] = true end
      for name in pairs(names) do
        local lifetime_produced, lifetime_consumed = tonumber(produced[name]) or 0, tonumber(consumed[name]) or 0
        if type(name) == "string" and (lifetime_produced > 0 or lifetime_consumed > 0) then
          local function rate(category)
            local ok_rate, value = pcall(function()
              return statistics.get_flow_count({ name = name, category = category, precision_index = precision_index, count = false })
            end)
            return ok_rate and type(value) == "number" and value or nil
          end
          rows[#rows + 1] = { name = name, kind = kind,
            produced_per_minute = rate("input"), consumed_per_minute = rate("output"),
            lifetime_produced = lifetime_produced, lifetime_consumed = lifetime_consumed }
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    local a_total, b_total = a.lifetime_produced + a.lifetime_consumed, b.lifetime_produced + b.lifetime_consumed
    if a_total ~= b_total then return a_total > b_total end
    if a.kind ~= b.kind then return a.kind < b.kind end
    return a.name < b.name
  end)
  return rows, cap_rows(rows, MAX_FLOWS_ALL)
end

local function collect_summary(params)
  params = type(params) == "table" and params or {}
  local detail = params.detail or "aggregate"
  if detail ~= "aggregate" and detail ~= "full" then error("map_summary detail must be aggregate or full") end
  local precision_name = params.flow_precision or "one_minute"
  if not FLOW_PRECISIONS[precision_name] then error("unsupported map_summary flow_precision") end
  for _, field in ipairs({ "flow_items", "flow_fluids" }) do
    if params[field] ~= nil and (type(params[field]) ~= "table" or #params[field] > 32) then
      error("map_summary " .. field .. " must contain at most 32 names")
    end
  end
  if params.activity_since_tick ~= nil and (tonumber(params.activity_since_tick) == nil
    or tonumber(params.activity_since_tick) % 1 ~= 0) then
    error("activity_since_tick must be an integer tick")
  end
  local want = parse_include(params.include)
  -- Own entities are retained only for a requested section.
  local own = (want.stockpiles or want.sites or want.power or want.problems) and {} or nil
  -- Patches come from the per-chunk patch cache (M.patches); resources are
  -- scanned only for the full detail's resource rows.
  local c = companion.require_companion()
  local chunks = {}
  local visible_chunks = 0
  for chunk in c.surface.get_chunks() do
    if c.force.is_chunk_charted(c.surface, chunk) then
      chunks[#chunks + 1] = { x = chunk.x, y = chunk.y }
      local ok_visible, visible = pcall(c.force.is_chunk_visible, c.surface, chunk)
      if ok_visible and visible then visible_chunks = visible_chunks + 1 end
    end
  end
  table.sort(chunks, function(a, b) return a.y == b.y and a.x < b.x or a.y < b.y end)

  -- Match the predecessor's any-layer classification through prototype masks.
  -- Name filtering avoids passing unsupported historical collision-layer aliases
  -- to the native query. All lookup data belongs to this single request.
  local charted_chunks, water_tiles = {}, {}
  if detail == "full" then
    local water_names = {}
    for name, prototype in pairs(prototypes.tile) do
      local layers = prototype.collision_mask.layers
      if layers.water_tile or layers["water-tile"] or layers.player then
        water_names[#water_names + 1] = name
      end
    end
    table.sort(water_names)
    for _, chunk in ipairs(chunks) do
      local chunk_row = charted_chunks[chunk.y] or {}
      charted_chunks[chunk.y] = chunk_row
      chunk_row[chunk.x] = true
      local x0, y0 = chunk.x * 32, chunk.y * 32
      for _, tile in ipairs(c.surface.find_tiles_filtered({
        area = { { x0, y0 }, { x0 + 32, y0 + 32 } }, name = water_names,
      })) do
        local position = tile.position
        local row = water_tiles[position.y] or {}
        water_tiles[position.y] = row
        row[position.x] = true
      end
    end
  end

  local resources_by_name, landmarks, seen_landmark, seen_resource, water_edges, seen_edge = {}, {}, {}, {}, {}, {}
  local groups_by_key, flow_candidates, electric_networks, network_poles = {}, {}, {}, {}
  local flow_entities, flow_nodes_by_key = {}, {}
  local omissions = { capped_groups = 0, capped_flows = 0, unsupported_entities = 0,
    invalid_entities = 0, unsupported_flow_statistics = 0, capped_flow_nodes = 0,
    capped_flow_edges = 0, capped_edge_diagnostics = 0 }
  for _, name in ipairs(params.flow_items or {}) do add_flow_candidate(flow_candidates, "item", name) end
  for _, name in ipairs(params.flow_fluids or {}) do add_flow_candidate(flow_candidates, "fluid", name) end
  local explicit_flows = params.flow_items ~= nil or params.flow_fluids ~= nil
  local edge_directions = { { 1, 0 }, { 0, 1 } }
  for _, chunk in ipairs(chunks) do
    local x0, y0 = chunk.x * 32, chunk.y * 32
    local area = { { x0, y0 }, { x0 + 32, y0 + 32 } }
    if detail == "full" then for _, entity in ipairs(c.surface.find_entities_filtered({ area = area, type = "resource" })) do
      local resource_key = entity.valid and charted(c.force, c.surface, entity.position)
        and string.format("%s\0%.17g\0%.17g", entity.name, entity.position.x, entity.position.y) or nil
      if resource_key and not seen_resource[resource_key] then
        seen_resource[resource_key] = true
        local row = resources_by_name[entity.name] or { name = entity.name, entity_count = 0, total_amount = 0, nearest = nil, observed_tick = game.tick, _distance = nil }
        resources_by_name[entity.name] = row
        row.entity_count = row.entity_count + 1
        row.total_amount = row.total_amount + (tonumber(entity.amount) or 0)
        local dx, dy = entity.position.x - c.position.x, entity.position.y - c.position.y
        local distance = dx * dx + dy * dy
        if row._distance == nil or distance < row._distance
          or (distance == row._distance and (entity.position.y < row.nearest.y
            or (entity.position.y == row.nearest.y and entity.position.x < row.nearest.x))) then
          row._distance = distance
          row.nearest = { x = entity.position.x, y = entity.position.y }
        end
      end
    end end
    for _, entity in ipairs(c.surface.find_entities_filtered({ area = area, force = c.force })) do
      if not entity.valid then
        omissions.invalid_entities = omissions.invalid_entities + 1
      elseif entity.force == c.force and charted(c.force, c.surface, entity.position)
        and entity ~= c and entity.type ~= "character" and entity.type ~= "entity-ghost" then
        local key = string.format("%s\0%s\0%.17g\0%.17g", entity.name, entity.type, entity.position.x, entity.position.y)
        if not seen_landmark[key] then
          seen_landmark[key] = true
          local raw_status = status_name(entity)
          local recipe = recipe_fact(entity)
          local role = FLOW_NODE_ROLES[entity.type]
          local network_id = number_property(entity, "electric_network_id")
          if network_id then
            electric_networks[network_id] = true
            if entity.type == "electric-pole" then
              local previous = network_poles[network_id]
              if not previous or (number_property(entity, "unit_number") or 0) < (number_property(previous, "unit_number") or 0) then
                network_poles[network_id] = entity
              end
            end
          end
          if own then own[#own + 1] = { entity = entity, status = raw_status, network_id = network_id } end
          if role then
            local node = {
              _key = key, _entity = entity, name = entity.name, type = entity.type,
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
              if ok and entity_key(target) and charted(c.force, c.surface, target.position) then
                node._source_production.resource_key = entity_key(target)
              end
            end
            fluid_facts(node)
            flow_entities[#flow_entities + 1] = entity
            flow_nodes_by_key[key] = node
          end
          if MACHINE_TYPES[entity.type] then
            local group_key = entity.name .. "\0" .. (recipe and recipe.name or "")
            local group = groups_by_key[group_key]
            if not group then
              group = { entity = entity.name, type = entity.type, recipe = recipe and recipe.name or nil,
                machine_count = 0, status_counts = {}, summed_crafting_speed = 0, _recipe_energy = recipe and recipe.energy or nil }
              groups_by_key[group_key] = group
            end
            group.machine_count = group.machine_count + 1
            if entity.type == "mining-drill" then
              local capacity = nominal_mining_capacity(entity, c.force, c.surface)
              group._mining_capacity = (group._mining_capacity or 0) + (capacity or 0)
              group.evidenced_drill_count = (group.evidenced_drill_count or 0) + (capacity and 1 or 0)
            end
            local bucket = normalize_status(raw_status)
            group.status_counts[bucket] = (group.status_counts[bucket] or 0) + 1
            local speed = number_property(entity, "crafting_speed") or 0
            group.summed_crafting_speed = group.summed_crafting_speed + speed
            if recipe and not explicit_flows then
              for _, row in ipairs(recipe.ingredients) do add_flow_candidate(flow_candidates, row.type, row.name) end
              for _, row in ipairs(recipe.products) do add_flow_candidate(flow_candidates, row.type, row.name) end
            end
          elseif not role then
            omissions.unsupported_entities = omissions.unsupported_entities + 1
          end
          if detail == "full" then
            landmarks[#landmarks + 1] = {
              name = entity.name, type = entity.type,
              position = { x = entity.position.x, y = entity.position.y },
              direction = entity.direction, status = raw_status, recipe = recipe and recipe.name or recipe_name(entity),
              observed_tick = game.tick,
            }
          end
        end
      end
    end
    if detail == "full" then
      local east_charted = charted_chunks[chunk.y][chunk.x + 1]
      local south_row = charted_chunks[chunk.y + 1]
      local south_charted = south_row and south_row[chunk.x]
      for y = y0, y0 + 31 do
      for x = x0, x0 + 31 do
        local current = water_tiles[y] and water_tiles[y][x] or false
        for _, delta in ipairs(edge_directions) do
          local nx, ny = x + delta[1], y + delta[2]
          if (nx < x0 + 32 and ny < y0 + 32)
            or (nx == x0 + 32 and east_charted)
            or (ny == y0 + 32 and south_charted) then
            local neighbor = water_tiles[ny] and water_tiles[ny][nx] or false
            if current ~= neighbor then
              local land = current and { x = nx, y = ny } or { x = x, y = y }
              local water = current and { x = x, y = y } or { x = nx, y = ny }
              local edge_key = string.format("%d,%d:%d,%d", land.x, land.y, water.x, water.y)
              if not seen_edge[edge_key] then
                seen_edge[edge_key] = true
                water_edges[#water_edges + 1] = { land = land, water = water, observed_tick = game.tick }
              end
            end
          end
        end
      end
    end end
  end

  if not explicit_flows then add_current_research_flows(c.force, flow_candidates) end
  local groups = sorted_rows(groups_by_key, function(a, b)
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
  local flows = read_force_flows(c.force, c.surface, flow_candidates, precision_name, omissions)
  local power_status_counts = {}
  for _, group in ipairs(groups) do
    for name, count in pairs(group.status_counts) do
      if name == "no_power" or name == "low_power" then
        power_status_counts[name] = (power_status_counts[name] or 0) + count
      end
    end
  end
  local network_count = 0; for _ in pairs(electric_networks) do network_count = network_count + 1 end
  local material_flow = present_flow(build_material_flow(flow_entities, flow_nodes_by_key,
    factory_activity.snapshot(params.activity_since_tick, true), network_poles), omissions)
  local activity = factory_activity.snapshot(params.activity_since_tick)
  local partial = false; for _, count in pairs(omissions) do if count > 0 then partial = true end end
  local factory = {
    scope = "force_charted", collected_at_tick = game.tick, consistency = "single_request",
    charted_chunks = #chunks, currently_visible_charted_chunks = visible_chunks,
    machine_count = machine_count, groups = groups, force_flows = flows,
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
        precision = precision_name, window_ticks = FLOW_PRECISIONS[precision_name].ticks,
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
  if want.stockpiles then sections.stockpiles, sections.stockpiles_omitted = build_stockpiles(own) end
  if want.sites then sections.sites, sections.sites_omitted = build_sites(own) end
  if want.patches then sections.patches, sections.patches_complete, sections.patches_omitted = M.patches() end
  if want.power then
    local networks, networks_omitted = build_power(own, network_poles)
    sections.power = { networks = networks, networks_omitted = networks_omitted }
  end
  if want.problems then
    sections.problems, sections.problems_total, sections.problems_by_status = build_problems(own)
  end
  if want.flows_all then
    sections.force_flows_all, sections.force_flows_all_omitted = read_all_flows(c.force, c.surface, precision_name)
  end
  local function with_sections(result)
    for key, value in pairs(sections) do result[key] = value end
    return result
  end
  if detail == "aggregate" then return with_sections({ tick = game.tick, summary = summary_text, factory = factory }) end

  local resources = {}; for _, row in pairs(resources_by_name) do row._distance = nil; resources[#resources + 1] = row end
  table.sort(resources, function(a, b) return a.name < b.name end)
  table.sort(landmarks, key_position)
  table.sort(water_edges, function(a, b)
    if a.land.y ~= b.land.y then return a.land.y < b.land.y end
    if a.land.x ~= b.land.x then return a.land.x < b.land.x end
    if a.water.y ~= b.water.y then return a.water.y < b.water.y end
    return a.water.x < b.water.x
  end)
  local omitted_water_edges = math.max(0, #water_edges - MAX_EDGES)
  local omitted_factory_landmarks = math.max(0, #landmarks - MAX_LANDMARKS)
  while #water_edges > MAX_EDGES do table.remove(water_edges) end
  while #landmarks > MAX_LANDMARKS do table.remove(landmarks) end
  return with_sections({
    tick = game.tick, charted_chunks = #chunks, resources = resources,
    water_edges = water_edges, omitted_water_edges = omitted_water_edges,
    factory_landmarks = landmarks, omitted_factory_landmarks = omitted_factory_landmarks,
    factory = factory, summary = summary_text,
  })
end

function M.map_summary(params) return collect_summary(params) end

-- The stockpiles and power sections for factory_status, from a cache in
-- storage.status_cache that status_tick refreshes from the event-maintained
-- registry (no entity query): electric entities for power, chests and
-- crafting-machine outputs for stock. Belts are counted by the registry,
-- never listed, so belt contents are not stock here. A refresh starts at most
-- every STATUS_REFRESH_TICKS: its first tick lists the registry sets, each
-- later tick reads at most STATUS_ENTITIES_PER_TICK entities (status,
-- network, inventory contents, nominal power) into plain records, and the
-- tick after the last read builds the sections from those records with only
-- one flow-statistics read per network. A read never scans.
local STATUS_ENTITIES_PER_TICK = 48
local STATUS_REFRESH_TICKS = 300
M.STATUS_ENTITIES_PER_TICK = STATUS_ENTITIES_PER_TICK

local function status_record(entry, set, network_poles)
  local entity = entry.entity
  local network_id = set == "electric" and number_property(entity, "electric_network_id") or nil
  if network_id and entry.type == "electric-pole" then
    local previous = network_poles[network_id]
    if not previous or entry.unit < (number_property(previous, "unit_number") or 0) then
      network_poles[network_id] = entity
    end
  end
  local powered = network_id and entry.type ~= "electric-pole" and not POWER_PRODUCER_TYPES[entry.type]
    and entry.type ~= "accumulator"
  -- A plain snapshot, so building the sections reads no entity.
  local snapshot = { name = entry.name, type = entry.type, unit_number = entry.unit,
    position = { x = entry.position.x, y = entry.position.y } }
  local record = { entity = snapshot, network_id = network_id, status = powered and status_name(entity) or nil }
  if entry.type == "accumulator" then
    snapshot.energy, snapshot.electric_buffer_size = number_property(entity, "energy"), number_property(entity, "electric_buffer_size")
  elseif network_id and POWER_PRODUCER_TYPES[entry.type] then
    record.capacity_w = nominal_watts(entity, "get_max_energy_production")
  elseif powered then
    record.usage_w = nominal_watts(entity, "get_max_energy_usage")
  end
  if CHEST_TYPES[entry.type] or OUTPUT_TYPES[entry.type] then
    local inventory = stock_inventory(entity)
    record.contents = {}
    if inventory then add_contents(record.contents, inventory) end
  end
  return record
end

local function status_step(cache, tick)
  local job = cache.job
  if not job then
    if cache.updated_tick and tick - cache.updated_tick < STATUS_REFRESH_TICKS then return end
    local units, seen = {}, {}
    for _, set in ipairs({ "electric", "holders" }) do
      for _, entry in ipairs(registry.list(set)) do
        if not seen[entry.unit] then seen[entry.unit] = true; units[#units + 1] = { unit = entry.unit, set = set } end
      end
    end
    cache.job = { units = units, cursor = 1, own = {}, network_poles = {} }
    return
  end
  if job.cursor > #job.units then
    cache.stockpiles = build_stockpiles(job.own)
    cache.power = build_power(job.own, job.network_poles)
    cache.updated_tick, cache.job = tick, nil
    return
  end
  local entries = storage.registry and storage.registry.entries or {}
  local last = math.min(#job.units, job.cursor + STATUS_ENTITIES_PER_TICK - 1)
  for index = job.cursor, last do
    local item = job.units[index]
    local entry = entries[item.unit]
    if entry and entry.entity and entry.entity.valid then
      job.own[#job.own + 1] = status_record(entry, item.set, job.network_poles)
    end
  end
  job.cursor = last + 1
end

-- A failing step never stops the game; its error is kept on the cache and
-- the next refresh starts over.
function M.status_tick(tick)
  local cache = storage.status_cache
  if not (cache and registry.ready()) then return end
  local ok, err = pcall(status_step, cache, tick)
  if not ok then cache.error, cache.job = tostring(err), nil else cache.error = nil end
end

-- The cached sections: {stockpiles, power, updated_tick, ready}; ready is
-- false until the first refresh after a load or upgrade has finished.
function M.status_sections()
  local cache = storage.status_cache or {}
  return { stockpiles = cache.stockpiles or {}, power = cache.power or {}, updated_tick = cache.updated_tick,
    ready = cache.updated_tick ~= nil, error = cache.error }
end

-- The factory aggregate the run recorder samples, from the registry (no
-- chunk walk, no entity query, no material-flow graph): machine groups by
-- entity and recipe with status counts and nominal capacity, electric
-- network count, character transfers and the belt count.
function M.registry_factory()
  local c = companion.require_companion()
  local groups_by_key, networks, power_status_counts = {}, {}, {}
  for _, entry in ipairs(registry.machines()) do
    local entity = entry.entity
    local recipe_ok, recipe = pcall(function() return entity.get_recipe and entity.get_recipe() end)
    if not recipe_ok or not recipe then recipe = previous_furnace_recipe(entity) end
    local recipe_name_value = recipe and recipe.name or nil
    local key = entry.name .. "\0" .. (recipe_name_value or "")
    local group = groups_by_key[key]
    if not group then
      group = { entity = entry.name, type = entry.type, recipe = recipe_name_value, machine_count = 0,
        status_counts = {}, summed_crafting_speed = 0, _recipe_energy = recipe and number_property(recipe, "energy") or nil }
      groups_by_key[key] = group
    end
    group.machine_count = group.machine_count + 1
    local bucket = normalize_status(status_name(entity))
    group.status_counts[bucket] = (group.status_counts[bucket] or 0) + 1
    if bucket == "no_power" or bucket == "low_power" then
      power_status_counts[bucket] = (power_status_counts[bucket] or 0) + 1
    end
    group.summed_crafting_speed = group.summed_crafting_speed + (number_property(entity, "crafting_speed") or 0)
    if entry.type == "mining-drill" then
      local capacity = nominal_mining_capacity(entity, c.force, c.surface)
      group._mining_capacity = (group._mining_capacity or 0) + (capacity or 0)
      group.evidenced_drill_count = (group.evidenced_drill_count or 0) + (capacity and 1 or 0)
    end
  end
  for _, entry in ipairs(registry.list("poles")) do
    local id = number_property(entry.entity, "electric_network_id")
    if id then networks[id] = true end
  end
  local groups = sorted_rows(groups_by_key, function(a, b)
    if a.entity ~= b.entity then return a.entity < b.entity end
    return (a.recipe or "") < (b.recipe or "")
  end)
  local machine_count = 0
  for _, group in ipairs(groups) do
    machine_count = machine_count + group.machine_count
    if group._recipe_energy and group._recipe_energy > 0 and group.summed_crafting_speed > 0 then
      group.theoretical_crafts_per_second = group.summed_crafting_speed / group._recipe_energy
    end
    group._recipe_energy = nil
    if group.type == "mining-drill" then
      group.capacity_state = group.evidenced_drill_count == group.machine_count and "complete"
        or group.evidenced_drill_count > 0 and "incomplete" or "unavailable"
      if group.capacity_state == "complete" then group.theoretical_items_per_minute = group._mining_capacity end
      group._mining_capacity = nil
    end
  end
  local network_count = 0
  for _ in pairs(networks) do network_count = network_count + 1 end
  local counts = registry.counts()
  return { scope = "registry", collected_at_tick = game.tick, registry_ready = counts.registry_ready,
    machine_count = machine_count, groups = groups, belt_count = counts.belts,
    power = { network_count = network_count, status_counts = power_status_counts },
    character_transfers = factory_activity.snapshot(), omissions = { capped_groups = 0 } }
end

-- ------------------------------------------------------------ patch cache
-- Resource patches from a per-chunk cache (storage.patch_cache, created by
-- state.init). A chunk is read when it is first charted (radars and the body
-- re-chart chunks all the time; a re-chart is ignored), again when a resource
-- in it is depleted, and, while nothing else is pending, one cached resource chunk
-- every PATCH_REFRESH_TICKS so amounts follow mining. The first tick lists
-- every charted chunk. Reads never scan.
local PATCH_CHUNKS_PER_TICK = 2
local PATCH_RESOURCES_PER_TICK = 2048
local PATCH_REFRESH_TICKS = 120

local function chunk_key(x, y) return x .. "," .. y end

local function enqueue_chunk(cache, x, y)
  local key = chunk_key(x, y)
  if cache.queued[key] then return end
  cache.queued[key] = true
  cache.pending[#cache.pending + 1] = { x = x, y = y }
end

local function own_force_event(force)
  local c = companion.get()
  local ok, same = pcall(function() return c and c.valid and force and force.name == c.force.name end)
  return ok and same == true, c
end

-- on_chunk_charted: the force charted or re-charted a chunk on some surface.
function M.on_chunk_charted(event)
  local cache = storage.patch_cache
  if not (cache and event and event.position) then return end
  if cache.known[chunk_key(event.position.x, event.position.y)] then return end
  local own, c = own_force_event(event.force)
  if not own or (event.surface_index ~= nil and event.surface_index ~= c.surface.index) then return end
  enqueue_chunk(cache, event.position.x, event.position.y)
end

-- on_resource_depleted: the resource is removed right after the event; the
-- chunk is read again on a later tick.
function M.on_resource_depleted(event)
  local cache = storage.patch_cache
  local entity = event and event.entity
  if not (cache and cache.seeded and entity and entity.valid) then return end
  local position = entity.position
  enqueue_chunk(cache, math.floor(position.x / 32), math.floor(position.y / 32))
end

local function read_chunk(c, cache, chunk)
  local key = chunk_key(chunk.x, chunk.y)
  cache.queued[key], cache.known[key] = nil, true
  local x0, y0 = chunk.x * 32, chunk.y * 32
  local cells, count = {}, 0
  local ok, found = pcall(c.surface.find_entities_filtered,
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

local function patch_step(cache, c, tick)
  if not cache.seeded then
    -- Seeded from the chunks the registry bootstrap already listed (no API
    -- call); chunks charted since then arrive through on_chunk_charted. Only
    -- a cache rebuilt on a ready registry lists the surface itself.
    local r = storage.registry
    local seed = r and r.charted_seed
    if seed then
      for _, chunk in ipairs(seed) do enqueue_chunk(cache, chunk.x, chunk.y) end
      r.charted_seed = nil
    else
      for chunk in c.surface.get_chunks() do
        if c.force.is_chunk_charted(c.surface, chunk) then enqueue_chunk(cache, chunk.x, chunk.y) end
      end
    end
    cache.seeded = true
    return
  end
  if cache.head > #cache.pending then
    cache.pending, cache.head, cache.filled = {}, 1, true
    if tick % PATCH_REFRESH_TICKS ~= 0 then return end
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
    items = items + read_chunk(c, cache, chunk)
    chunks = chunks + 1
  end
end

-- A failing step never stops the game; its error is kept on the cache.
function M.patch_tick(tick)
  local cache = storage.patch_cache
  if not cache then return end
  local c = companion.get()
  if not (c and c.valid) then return end
  local ok, err = pcall(patch_step, cache, c, tick)
  cache.error = not ok and tostring(err) or nil
end

-- Resource patches in charted chunks from the cache, whether every charted
-- chunk has been read at least once, and how many patches the cap left out.
function M.patches()
  local cache = storage.patch_cache
  if not cache then return {}, false end
  if cache.dirty or not cache.rows then
    local cells = {}
    for key, chunk in pairs(cache.chunks) do
      for name, cell in pairs(chunk.cells) do
        cells[name] = cells[name] or {}
        cells[name][key] = cell
      end
    end
    cache.rows, cache.rows_omitted = build_patches(cells)
    cache.dirty, cache.updated_tick = false, game.tick
  end
  return cache.rows, cache.filled == true, cache.rows_omitted or 0
end

return M
