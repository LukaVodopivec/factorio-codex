-- Read-only summary of the force's already charted world. No chart or generation calls.
local companion = require("scripts.companion")
local factory_activity = require("scripts.factory_activity")
local fluid_connections = require("scripts.fluid_connections")
local output_target = require("scripts.output_target")

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
-- A validated producer that is out of fuel, power, resources or enabled
-- state is not currently autonomous; ordinary input/output waits are.
local AUTONOMY_REVOKING_STATUSES = { no_fuel = true, no_power = true, no_resources = true, disabled = true }
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

-- A validation window passes `retained`, its own per-drill products from
-- earlier samples: a drill whose mining_target reads nil for a sample keeps
-- the identity it last mined, like a furnace's previous_recipe. A replaced
-- drill still changes the window's signature through its unit number.
local function mining_products(entity, retained)
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
  local key = retained and entity_key(entity)
  if key and #products > 0 then
    retained[key] = {}
    for index, product in ipairs(products) do retained[key][index] = { name = product.name, type = product.type } end
  elseif key and ok and target == nil and retained[key] then
    for index, product in ipairs(retained[key]) do
      products[index] = { name = product.name, type = product.type,
        fuel_category = product.type ~= "fluid" and item_fuel_category(product.name) or nil }
    end
  end
  return products
end

local function products_with_fuel(products)
  for _, product in ipairs(products or {}) do
    product.fuel_category = product.type ~= "fluid" and item_fuel_category(product.name) or nil
  end
  return products or {}
end

-- Installed nominal capacity, independent of duty/status and bonuses. Unlike
-- validation's retained product identity, this requires a current charted target.
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

-- Stored fuel energy (fuel inventory plus the burning remainder), item count
-- and one stocked item's fuel value: a private validation sample, nil when
-- unreadable. The item value is nil when no stock or burning item is known.
local function stored_fuel(entity)
  local ok, energy, items, item_energy = pcall(function()
    local total, count, value = entity.burner.remaining_burning_fuel, 0, nil
    for _, stack in ipairs(entity.get_fuel_inventory().get_contents()) do
      value = prototypes.item[stack.name].fuel_value
      total, count = total + stack.count * value, count + stack.count
    end
    if not value then
      -- Factorio 2.0 ItemIDAndQualityIDPair: name is the LuaItemPrototype.
      local burning = entity.burner.currently_burning
      value = burning and burning.name.fuel_value
    end
    return total, count, value
  end)
  if ok and type(energy) == "number" and type(items) == "number" then
    return energy, items, type(item_energy) == "number" and item_energy > 0 and item_energy or nil
  end
  return nil
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

-- `activity` is the requested window; `history` is the whole retained run.
-- Retained proofs are assessed only for public summaries: a new validation
-- sample (`internal`) assesses its own window without inheriting a prior
-- proof's exemptions, though it still names its power supply's proof.
local function build_material_flow(flow_entities, node_by_key, activity, network_poles, history, internal)
  local nodes = sorted_rows(node_by_key, key_position)
  local retained = {}
  for index, node in ipairs(nodes) do
    node.id = "node-" .. index
    retained[node._key] = node
  end
  -- Fluid pools: a segment, or one box outside any segment (its own stock).
  -- Natively get_capacity is one box's capacity, so a segment's capacity sums
  -- its sampled member boxes; an unsampled member only makes it look fuller.
  -- A proven pipe connection touching an out-of-segment box joins the two
  -- pools into one mass-balance domain (a boiler output and the steam
  -- segment it fills); the domain key is its smallest member pool.
  local segment_capacity, pool_parent = {}, {}
  for _, node in ipairs(nodes) do
    for _, box in ipairs(node._fluid_boxes or {}) do
      box.pool = box.segment or node._key .. "#" .. box.index
      if box.segment then segment_capacity[box.segment] = (segment_capacity[box.segment] or 0) + box.capacity end
    end
  end
  local function pool_domain(pool)
    while pool_parent[pool] do pool = pool_parent[pool] end
    return pool
  end
  local function join_pools(a, b)
    a, b = pool_domain(a), pool_domain(b)
    if a == b then return end
    if tostring(a) < tostring(b) then pool_parent[b] = a else pool_parent[a] = b end
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
            if proven and not (source_box.segment and target_box.segment) then join_pools(source_box.pool, target_box.pool) end
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
  -- A segment's stock is its native contents (every member box included); an
  -- out-of-segment box's stock is its own buffer, never an invented segment.
  -- get_fluid_segment_contents is documented as uint32, so a domain's amount
  -- is trusted to one unit per member segment (at least one): its rounding
  -- allowance. 2.0.77 returns float32-precise fractions; the allowance guards
  -- the documented contract and is conservative there.
  local domain_amount, domain_segments, counted = {}, {}, {}
  for _, node in ipairs(nodes) do
    for _, box in ipairs(node._fluid_boxes or {}) do
      box.domain = pool_domain(box.pool)
      box.segment_capacity = box.segment and segment_capacity[box.segment] or box.capacity
      if not counted[box.pool] then
        counted[box.pool] = true
        domain_amount[box.domain] = (domain_amount[box.domain] or 0) + (box.segment and box.segment_amount or box.amount)
        if box.segment then domain_segments[box.domain] = (domain_segments[box.domain] or 0) + 1 end
      end
    end
  end
  for _, node in ipairs(nodes) do
    for _, box in ipairs(node._fluid_boxes or {}) do
      box.domain_amount, box.domain_rounding = domain_amount[box.domain], math.max(1, domain_segments[box.domain] or 0)
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
        local pole = network_poles and network_poles[network]
        -- Natively an electric network's producers are its output counts and
        -- its consumers its input counts, both cumulative joules by name.
        local ok, outputs = pcall(function() return pole.electric_network_statistics.output_counts end)
        if ok and type(outputs) == "table" then node._network_generation = outputs
        else diagnostic(node, "electrical_generation_attribution_unproven", "unsupported") end
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
      -- Natively an electric network's consumers are its input counts.
      local ok_inputs, inputs = pcall(function() return network_poles[network].electric_network_statistics.input_counts end)
      node._network_consumption = ok_inputs and type(inputs) == "table" and inputs or nil
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
  -- demand is neither an interruption nor blocked output. Standby never
  -- proves anything by itself: autonomy still needs retained validation.
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
      _transfers = {}, _edges = {}, _diagnostics = {} }
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
  for _, event in ipairs(history.events or {}) do
    if event.target then
      local key = string.format("%s\0%s\0%.17g\0%.17g", event.target.name, event.target.type,
        event.target.position.x, event.target.position.y)
      local node = retained[key]
      if node then
        local component = by_root[root(node.id)]
        component._transfers[#component._transfers + 1] = { event = event, node = node }
        if event.tick >= activity.since_tick then
          component.character_transfer_actions = component.character_transfer_actions + 1
          component.last_character_transfer_tick = math.max(component.last_character_transfer_tick or 0,
            tonumber(event.tick) or 0)
        end
      end
    end
  end
  for key, tick in pairs(history.target_last_tick or {}) do
    local node = retained[key]
    local component = node and by_root[root(node.id)]
    if component then
      component._history_last_transfer_tick = math.max(component._history_last_transfer_tick or 0, tick)
    end
  end
  local components = sorted_rows(by_root, function(a, b) return a.node_ids[1] < b.node_ids[1] end)
  local node_by_id, incoming, outgoing = {}, {}, {}
  for _, node in ipairs(nodes) do node_by_id[node.id], incoming[node.id], outgoing[node.id] = node, {}, {} end
  for _, edge in ipairs(edges) do
    if edge.kind ~= "electrical_dependency" then
      incoming[edge.to][#incoming[edge.to] + 1] = edge.from
      outgoing[edge.from][#outgoing[edge.from] + 1] = edge.to
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
  -- The nodes a node's output reaches first, through transport (and, when
  -- asked, through intermediate buffers) only.
  local function first_reached(start_id, through_buffers)
    local reached, queue, seen, head = {}, { start_id }, { [start_id] = true }, 1
    while head <= #queue do
      local id = queue[head]; head = head + 1
      for _, next_id in ipairs(outgoing[id] or {}) do
        local next_node = node_by_id[next_id]
        if not seen[next_id] and next_node then
          seen[next_id] = true
          if next_node.role == "transport" or through_buffers and next_node.role == "buffer" and not next_node._downstream_buffer then
            queue[#queue + 1] = next_id
          else reached[#reached + 1] = next_node end
        end
      end
    end
    return reached
  end
  -- Whether a pump's fluid reaches engines through fluid entities only, and
  -- every engine it reaches is on standby: it stopped from backpressure.
  local function feeds_only_standby(start_id)
    local queue, seen, head, found = { start_id }, { [start_id] = true }, 1, false
    while head <= #queue do
      local id = queue[head]; head = head + 1
      for _, next_id in ipairs(outgoing[id] or {}) do
        local next_node = node_by_id[next_id]
        if not seen[next_id] and next_node then
          seen[next_id] = true
          if next_node.type == "generator" then
            if not next_node._standby then return false end
            found = true
          elseif FLUID_TYPES[next_node.type] then queue[#queue + 1] = next_id
          else return false end
        end
      end
    end
    return found
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
  -- A burner producer takes these products only as fuel: one burns in its
  -- categories and none is a recipe ingredient that could be material input.
  local function fuel_inlet(products, target)
    if not target.requires_fuel or (target.role ~= "source" and target.role ~= "processor") then return false end
    local fuel = false
    for _, product in pairs(products) do
      if product.fuel_category and (target.fuel_categories or {})[product.fuel_category] then fuel = true end
      for _, ingredient in ipairs(target.ingredients or {}) do
        if ingredient.type == product.type and ingredient.name == product.name then return false end
      end
    end
    return fuel
  end
  -- The sources whose fuel physically reaches a burner through transport and
  -- buffers (a self-fuelling source included). A processor supplying the
  -- same fuel makes the supply unmodelled for supply-rate judgements.
  local function fuel_suppliers(start_id, categories)
    local found, modelled, queue, seen, head = {}, true, {}, { [start_id] = true }, 1
    for _, id in ipairs(incoming[start_id]) do queue[#queue + 1] = id end
    while head <= #queue do
      local id = queue[head]; head = head + 1
      local node = node_by_id[id]
      if node and node.role == "source" and product_matches(node, categories, true) then found[node._key] = true end
      if node and not seen[id] then
        seen[id] = true
        if node.role == "processor" and product_matches(node, categories, true) then modelled = false end
        if node.role == "transport" or node.role == "buffer" then
          for _, parent_id in ipairs(incoming[id] or {}) do queue[#queue + 1] = parent_id end
        end
      end
    end
    local keys = {}
    for key in pairs(found) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys, modelled
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
        elseif upstream.role == "transport" or upstream.role == "buffer" or upstream.type == "lab" or id == start_id then
          for _, parent_id in ipairs(incoming[id]) do queue[#queue + 1] = parent_id end
        end
      end
    end
    return products
  end
  -- A fuel feeder waiting for source items at a burner may owe it nothing:
  -- name the burner when the pickup's proven supply is only fuel for it, so
  -- validation judges the wait against that burner's sampled fuel stock.
  -- Only the burner's sole physical fuel inlet of any provenance qualifies
  -- (the inlet rule of fuel_refill_via): another inlet's replenishment, even
  -- from an unproven hand-stocked chest, never excuses an inactive return.
  local function fuel_inlet_count(burner)
    local count = 0
    for _, parent in ipairs(incoming[burner.id] or {}) do
      local upstream = node_by_id[parent]
      if upstream.role == "transport" or upstream.role == "buffer"
        or product_matches(upstream, burner.fuel_categories or {}, true) then count = count + 1 end
    end
    return count
  end
  for _, node in ipairs(nodes) do
    if node.type == "inserter" and node.status == "insufficient_input" then
      local pickup, destination
      for _, edge in ipairs(edges) do
        if edge.from == node.id and edge.kind == "inserter_drop" then destination = node_by_id[edge.to] end
        if edge.to == node.id and edge.kind == "inserter_pickup" then pickup = node_by_id[edge.from] end
      end
      local categories = destination and destination.fuel_categories or {}
      if pickup and destination and fuel_inlet(upstream_products(pickup.id), destination)
        and ((pickup.role == "source" or pickup.role == "processor") and product_matches(pickup, categories, true)
          or (pickup.role == "transport" or pickup.role == "buffer") and upstream_proven(pickup.id, categories, true))
        and fuel_inlet_count(destination) == 1 then
        node._fuel_feed_to = destination._key
      end
    end
  end
  for _, node in ipairs(nodes) do
    if node.role == "buffer" or node.role == "sink" then
      local products = upstream_products(node.id)
      -- A buffer is terminal when nothing leaves it, or when everything that
      -- leaves only refuels producers upstream of it: a self-fuelling loop's
      -- chest is where its surplus ends, not an intermediate stage.
      node._downstream_buffer = false
      if node.role == "buffer" then
        local reached, upstream = first_reached(node.id, false), nil
        node._downstream_buffer = #outgoing[node.id] == 0 or #reached > 0
        for _, target in ipairs(reached) do
          upstream = upstream or ancestors(node.id)
          if not (upstream[target.id] and fuel_inlet(products, target)) then node._downstream_buffer = false end
        end
        local all_fuel = next(products) ~= nil
        for _, product in pairs(products) do if not product.fuel_category then all_fuel = false end end
        if node._downstream_buffer and all_fuel then
          -- A terminal fuel buffer behind fuel takeoffs on its own supply
          -- line only receives what those burners leave over.
          local takeoffs, listed, queue, seen, head = {}, {}, { node.id }, { [node.id] = true }, 1
          while head <= #queue do
            local id = queue[head]; head = head + 1
            for _, parent_id in ipairs(incoming[id]) do
              if not seen[parent_id] and node_by_id[parent_id].role == "transport" then
                seen[parent_id] = true
                queue[#queue + 1] = parent_id
                for _, target in ipairs(first_reached(parent_id, false)) do
                  if target.id ~= node.id and not listed[target.id] and fuel_inlet(products, target) then
                    listed[target.id] = true
                    takeoffs[#takeoffs + 1] = target._key
                  end
                end
              end
            end
          end
          table.sort(takeoffs)
          if #takeoffs > 0 then node._fuel_takeoffs = takeoffs end
        elseif not node._downstream_buffer and all_fuel and #reached > 0 then
          -- An intermediate buffer that only refuels burners drains on their
          -- demand, not on a schedule.
          node._fuel_only_buffer = true
          for _, target in ipairs(reached) do
            if not fuel_inlet(products, target) then node._fuel_only_buffer = nil end
          end
        end
      end
      node._accepted_stock, node._accepted_products = {}, {}
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
      for key, product in pairs(products) do
        -- Inventory values are private interval samples, never serialized.
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
          node._accepted_stock[key] = count
          node._accepted_products[key] = accepting
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
  -- A component holding a network's generators is judged after the supplies
  -- powering it and before any component consuming its power, so each can
  -- name its supply's proof. Supplies powering each other stay unproven in
  -- any order.
  local supplier_of, order, suppliers, consumers_only = {}, {}, {}, {}
  for index, component in ipairs(components) do
    component.component_id = "component-" .. index
    local supplies = false
    for _, id in ipairs(component.node_ids) do
      local node = node_by_id[id]
      if node.type == "generator" and node._power_network then supplier_of[node._power_network], supplies = component, true end
    end
    component._supplies_power = supplies or nil
    if supplies then suppliers[#suppliers + 1] = component else consumers_only[#consumers_only + 1] = component end
  end
  local placed = {}
  local function place(component)
    if placed[component] then return end
    placed[component] = true
    for _, id in ipairs(component.node_ids) do
      local node = node_by_id[id]
      local supplier = node._power_consumer and supplier_of[node._power_network]
      if supplier and supplier ~= component then place(supplier) end
    end
    order[#order + 1] = component
  end
  for _, component in ipairs(suppliers) do place(component) end
  for _, component in ipairs(consumers_only) do order[#order + 1] = component end
  for _, component in ipairs(order) do
    local local_work = (component.status_counts.working or 0) > 0
    local rows, signature_rows, producing_nodes, accepting_sinks = {}, {}, 0, 0
    local buffers, consumers, blocked_output, interrupted = 0, 0, false, nil
    local unreached, endpoints, supplied_by = {}, {}, {}
    component._downstream, component._production, component._source_production = {}, {}, {}
    component._native_activity = {}
    component._node_status, component._buffers, component._inputs, component._fuel_buffers = {}, {}, {}, {}
    -- Every row is located at the node where a repair or inspection starts.
    -- Transient rows are single status samples and never gate topology.
    local function block(node, reason, class, related_edge, gate)
      rows[#rows + 1] = { reason = reason, class = class, node_id = node.id, position = node.position,
        entity = node.name, related_edge = related_edge, gate = gate }
    end
    local drop_of = {}
    for _, edge in ipairs(component._edges) do
      if edge.kind == "inserter_drop" then drop_of[edge.from] = node_by_id[edge.to]._key end
    end
    for _, id in ipairs(component.node_ids) do
      local node = node_by_id[id]
      local status = { status = node.status, role = node.role, position = node.position,
        entity = node.name, saturated = node.fuel_return_saturation ~= nil or nil, drop_to = drop_of[id],
        fuel_feed_to = node._fuel_feed_to }
      if node.fuel_return_saturation then
        status.fuel_return_to = node_by_id[node.fuel_return_saturation.destination_node_id]._key
      end
      if node.requires_fuel and (node.role == "source" or node.role == "processor") then
        status.fuel_energy, status.fuel_items, status.fuel_item_energy = stored_fuel(node._entity)
        status.fuel_unreadable = status.fuel_energy == nil or nil
        local suppliers, modelled = fuel_suppliers(id, node.fuel_categories or {})
        if #suppliers > 0 then status.fuel_sources, status.fuel_supply_unmodelled = suppliers, not modelled or nil end
        -- Attribute a fuel rise only when one physical inlet can have
        -- delivered it. Transport/buffers may carry stocked fuel even without
        -- production provenance, so another such inlet makes it ambiguous.
        local inlet, ambiguous
        for _, parent in ipairs(incoming[id] or {}) do
          local upstream = node_by_id[parent]
          if upstream.role == "transport" or upstream.role == "buffer"
            or product_matches(upstream, node.fuel_categories or {}, true) then
            if inlet then ambiguous = true end
            inlet = upstream
          end
        end
        if inlet and not ambiguous and inlet.type == "inserter"
          and upstream_proven(inlet.id, node.fuel_categories or {}, true) then
          status.fuel_refill_via = inlet._key
        end
      end
      if node.role == "processor" then
        -- Input stock is sampled so a starter packet cannot stand in for a
        -- dead feeder.
        local inventory_id = defines and defines.inventory and (node.type == "furnace" and defines.inventory.furnace_source
          or node.type == "assembling-machine" and defines.inventory.assembling_machine_input) or nil
        local stock = {}
        for _, ingredient in ipairs(inventory_id and node.ingredients or {}) do
          if ingredient.type == "item" then
            local ok, count = pcall(function() return node._entity.get_inventory(inventory_id).get_item_count(ingredient.name) end)
            if ok and type(count) == "number" then stock[ingredient.name] = count end
          end
        end
        if next(stock) then component._inputs[node._key] = stock end
      end
      if FLUID_TYPES[node.type] or node._power_consumer then
        local native = { type = node.type, boxes = node._fluid_boxes,
          input = node._fluid_input, output = node._fluid_output,
          source = node._fluid_source, generator = node._generator, power_network = node._power_network,
          network_generation = node._network_generation, name = node.name,
          network_consumption = node._network_consumption, working = node._power_consumer and node.status == "working" or nil,
          pumped = (node.type == "offshore-pump" or node.type == "pump") and number_property(node._entity, "pumped_last_tick") or nil,
          generated = node.type == "generator" and number_property(node._entity, "energy_generated_last_tick") or nil,
          energy = node._power_consumer and number_property(node._entity, "energy") or nil,
          consumer = node._power_consumer, drain = node._power_consumer and number_property(node._entity, "electric_drain") or nil,
          fuel_energy = status.fuel_energy,
          burning_energy = node.requires_fuel and number_property(node._entity.burner, "remaining_burning_fuel") or nil }
        component._native_activity[node._key] = native
        if native.consumer and (native.energy == nil or native.energy <= 0) then interrupted = "electrical_delivery_inactive" end
        signature_rows[#signature_rows + 1] = node._key .. ":network:" .. tostring(node._power_network)
        if node._generator then
          for _, field in ipairs({ "default_temperature", "heat_capacity", "effectivity", "maximum_temperature" }) do
            signature_rows[#signature_rows + 1] = node._key .. ":generator:" .. field .. ":" .. tostring(node._generator[field])
          end
        end
      end
      component._node_status[node._key] = status
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
        component._downstream[node._key] = { kind = "consumer", accepting = node._accepting, products = node._accepted_products,
          lab = node.type == "lab" or nil }
      elseif node._downstream_buffer then
        buffers = buffers + 1
        endpoints[#endpoints + 1] = node
        component._downstream[node._key] = { kind = "buffer", accepting = node._accepting, stock = node._accepted_stock,
          fuel_takeoffs = node._fuel_takeoffs }
        if node._accepting then accepting_sinks = accepting_sinks + 1 end
      elseif node.role == "buffer" then
        -- Intermediate stock is sampled so a window can tell a fed stage
        -- from starter stock draining with no inflow.
        component._buffers[node._key] = node._accepted_stock
        component._fuel_buffers[node._key] = node._fuel_only_buffer
      end
      -- Only an inventory that cannot accept the item proves blocked output.
      if node._blocked_output then blocked_output = true; block(node, "blocked_output", "structural") end
      if node.role == "source" or node.role == "processor" then
        producing_nodes = producing_nodes + 1
        if AUTONOMY_REVOKING_STATUSES[node.status] then interrupted = node.status end
        if node.role == "source" then
          if node.type ~= "offshore-pump" then component._source_production[node._key] = node._source_production end
          if not node._source_production.working then block(node, "source_not_locally_operating", "transient") end
          -- A source whose output only refuels other producers runs at their
          -- burn rate; validation judges it by theirs.
          local fuel_consumers = {}
          for _, target in ipairs(first_reached(id, true)) do
            if target.id ~= id then
              if not fuel_inlet(node.products, target) then fuel_consumers = nil; break end
              fuel_consumers[#fuel_consumers + 1] = target._key
            end
          end
          if fuel_consumers and #fuel_consumers > 0 then node._source_production.fuel_consumers = fuel_consumers end
        end
        if node.role == "processor" and node.type ~= "boiler" then component._production[node._key] = node.products_finished or false end
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
      if node.type == "generator" and not node._standby
        and (not node._accepting or (number_property(node._entity, "energy_generated_last_tick") or 0) <= 0)
        or (node.type == "offshore-pump" or node.type == "pump")
        and (number_property(node._entity, "pumped_last_tick") or 0) <= 0 and not feeds_only_standby(id) then
        interrupted = "native_fluid_dependency_inactive"
      end
      if node.role == "sink" and node._accepting then accepting_sinks = accepting_sinks + 1 end
      for _, ingredient in ipairs(node.ingredients or {}) do
        if not upstream_proven(id, ingredient, false) then
          block(node, "material_input_provenance_unresolved:" .. ingredient.type .. ":" .. ingredient.name, "structural",
            { kind = "material_input" })
        end
      end
      -- Power provenance is a node property: the network's supply must be
      -- this component or another one currently proven autonomous.
      if node._power_consumer then
        local supplier = supplier_of[node._power_network]
        if supplier ~= component and not (supplier and supplier._supply_proven) then
          block(node, "power_supply_component_not_proven", "evidence", { kind = "electrical_supply" }, "readiness")
        end
        if supplier and supplier ~= component then supplied_by[supplier] = true end
      end
      if node.requires_fuel and not upstream_proven(id, node.fuel_categories or {}, true) then
        local related_edge = { kind = "fuel_input" }
        -- A burner inserter refuels only from fuel it carries. When its
        -- produced cargo is known and none of it burns here, say so: it needs
        -- a fuel feed of its own, not proof of the cargo it already moves.
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
    component._supplied_by = supplied_by
    for _, edge in ipairs(component._edges) do
      signature_rows[#signature_rows + 1] = node_by_id[edge.from]._key .. "->" .. node_by_id[edge.to]._key .. ":" .. edge.kind .. ":" .. tostring(edge.from_fluidbox) .. ":" .. tostring(edge.to_fluidbox)
    end
    -- Observe delivery to exact electrical dependents without joining their
    -- material paths or importing their finite cargo as supply provenance.
    for _, edge in ipairs(edges) do
      if edge.kind == "electrical_dependency" and by_root[root(edge.from)] == component
        and by_root[root(edge.to)] ~= component then
        local node = node_by_id[edge.to]
        component._native_activity[node._key] = { name = node.name, type = node.type,
          consumer = true, electrical_only = true, power_network = node._power_network,
          network_consumption = node._network_consumption, working = node.status == "working" or nil,
          status = node.status, position = node.position, entity = node.name,
          energy = number_property(node._entity, "energy"), drain = number_property(node._entity, "electric_drain"),
          buffer = number_property(node._entity, "electric_buffer_size") }
        local energy = component._native_activity[node._key].energy
        if not energy or energy <= 0 then interrupted = "electrical_delivery_inactive" end
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
    component._signature = table.concat(signature_rows, "|")
    -- Compact presentation identifier; exact private identity is compared for validation.
    local h1, h2 = 0, 0
    for i = 1, #component._signature do
      local byte = component._signature:byte(i)
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
    local validation
    for _, candidate in ipairs(not internal and history.validations or {}) do
      if candidate._signature == component._signature and candidate.proven then validation = candidate end
    end
    -- Bootstrap transfers before a successful bounded validation are historical
    -- debt, not evidence that the now-connected component still needs the
    -- character. Only accepted-product harvesting from a matching terminal
    -- buffer after the unattended interval may retain that proof. Raw counts
    -- still include harvesting; incomplete telemetry remains unproven.
    local transfer_observed = false
    for _, transfer in ipairs(component._transfers) do
      local event, node = transfer.event, transfer.node
      if event.tick >= (validation and validation.start_tick or activity.since_tick) then
        local harvest = validation and event.tick > validation.end_tick and event.action == "extract"
          and node._downstream_buffer and #event.items > 0
        if harvest then
          for _, item in ipairs(event.items) do
            if node._accepted_products["item:" .. item.name] ~= true then harvest = false end
          end
        end
        if not harvest then transfer_observed = true; break end
      end
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
    component._blocker_rows = rows
    local history_complete = factory_activity.history_complete(validation and validation.start_tick or activity.since_tick)
    local topology_ready = #hard_rows == 0 and history_complete and not transfer_observed
    local autonomous = topology_ready and validation ~= nil and not interrupted
    -- A supply's proof usually ended before a later window or checkpoint, so
    -- its consumers judge it on retained run history: proven and still
    -- operating, with complete telemetry and no character transfer since.
    local supply_start = (history.supply_proof_tick or {})[component._signature]
    component._supply_proven = #hard_rows == 0 and not interrupted and supply_start ~= nil
      and (history.target_last_tick_after == nil or supply_start > history.target_last_tick_after)
      and not ((component._history_last_transfer_tick or -1) >= supply_start)
    component.state = {
      downstream_kind = buffers > 0 and (consumers > 0 and "mixed" or "buffer") or (consumers > 0 and "consumer" or "none"),
      blocked_output = blocked_output,
      machine_present = true,
      locally_operating = local_work,
      autonomy_topology_ready = topology_ready,
      autonomous_end_to_end = autonomous,
      autonomy_evidence = autonomous and "bounded_multi_tick_no_character_transfer_validation"
        or transfer_observed and "character_transfer_observed"
        or not history_complete and "character_transfer_history_incomplete"
        or topology_ready and validation and "validated_producer_nonproductive"
        or topology_ready and "bounded_multi_tick_production_not_yet_proven"
        or "physical_end_to_end_path_not_proven",
      autonomy_blockers = blocker_names,
      blocker_details = details,
      validation = validation,
    }
  end
  -- A window judges its supply's continuity with its own: the supplying
  -- component's burners, their feeders and fuel sources are sampled with
  -- this one's nodes, so a supply whose stored fuel outlasts a dead refill
  -- fails it; its fuel sources' cycles bound their refill waits but are
  -- not this window's own source cycles. A supply's own supplies are
  -- sampled too, transitively. Copies are collected from every component's
  -- own nodes first, so suppliers may come in any order and may power each
  -- other.
  local copies = {}
  for _, component in ipairs(order) do
    local status_copy, source_copy = {}, {}
    local seen, queue, head = { [component] = true }, {}, 1
    for supplier in pairs(component._supplied_by) do queue[#queue + 1] = supplier end
    while head <= #queue do
      local supplier = queue[head]; head = head + 1
      if not seen[supplier] then
        seen[supplier] = true
        for further in pairs(supplier._supplied_by or {}) do queue[#queue + 1] = further end
        local fuelled = {}
        for key, status in pairs(supplier._node_status) do
          if status.fuel_energy ~= nil or status.fuel_unreadable then fuelled[key] = true end
        end
        for key, status in pairs(supplier._node_status) do
          if fuelled[key] or fuelled[status.drop_to] or fuelled[status.fuel_feed_to] then
            status_copy[key] = status
            for _, source in ipairs(status.fuel_sources or {}) do source_copy[source] = supplier._source_production[source] end
          end
        end
      end
    end
    copies[component] = { status_copy, source_copy }
  end
  for component, copy in pairs(copies) do
    for key, status in pairs(copy[1]) do component._node_status[key] = status end
    component._supply_sources, component._supplied_by = copy[2], nil
  end
  return { nodes = nodes, edges = edges, components = components, diagnostics = diagnostics,
    relationship_semantics = "exact_runtime_targets_only; absence_or_unsupported_is_not_a_connection" }
end

-- Caps are a presentation concern. Never mutate the graph used by sampling.
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
        if state.validation then
          local validation = {}; for key, value in pairs(state.validation) do if key ~= "_signature" then validation[key] = value end end
          state.validation = validation
        end
        row.state = state
      end
      result[field][#result[field] + 1] = row
    end
  end
  -- Whole-graph counters beside the capped rows, so a recorder never
  -- measures the factory from the presented subset.
  result.component_count, result.edge_count = #flow.components, #flow.edges
  result.autonomous_component_count, result.validated_component_count, result.products_finished_total = 0, 0, 0
  for _, component in ipairs(flow.components) do
    if component.state.autonomous_end_to_end then result.autonomous_component_count = result.autonomous_component_count + 1 end
    if component.state.validation then result.validated_component_count = result.validated_component_count + 1 end
    result.products_finished_total = result.products_finished_total + component.products_finished_total
  end
  omissions.capped_flow_nodes = #flow.nodes - #result.nodes
  omissions.capped_flow_edges = #flow.edges - #result.edges
  omissions.capped_flow_components = #flow.components - #result.components
  omissions.capped_edge_diagnostics = #flow.diagnostics - #result.diagnostics
  return result
end

local function collect_summary(params, internal, drill_products)
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
                or (entity.type == "mining-drill" and mining_products(entity, drill_products) or {})),
              requires_fuel = has_burner(entity),
              fuel_categories = burner_categories(entity),
              power_state = raw_status == "no_power" and "missing" or raw_status == "low_power" and "low" or "not_exactly_observed",
              fuel_state = raw_status == "no_fuel" and "missing" or "not_exactly_observed",
            }
            if role == "source" then
              -- Located so a supplying component's source can carry a row.
              node._source_production = { working = node.status == "working", progress = number_property(entity, "mining_progress"),
                position = node.position, entity = node.name }
              local ok, target = pcall(function() return entity.mining_target end)
              if ok and entity_key(target) and charted(c.force, c.surface, target.position) then
                node._source_production.resource_key = entity_key(target)
                node._source_production.remaining = number_property(target, "amount")
                -- Nominal ticks per mined item at full duty, without
                -- productivity bonuses: the supply-limited fuel period.
                local ok_period, period = pcall(function()
                  return 60 * target.prototype.mineable_properties.mining_time / entity.prototype.mining_speed
                end)
                if ok_period and type(period) == "number" and period > 0 and period < math.huge then
                  node._source_production.mining_period_ticks = period
                end
              end
              for _, product in ipairs(node.products) do
                if product.fuel_category and not node._source_production.fuel_value then
                  local ok_value, value = pcall(function() return prototypes.item[product.name].fuel_value end)
                  if ok_value and type(value) == "number" and value > 0 then node._source_production.fuel_value = value end
                end
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
  local activity = factory_activity.snapshot(params.activity_since_tick, true)
  -- Current proofs must see assistance since their own start, even when public
  -- telemetry requests a narrower window, and a supply's proof is judged on
  -- the whole run from any window. Both snapshots reuse bounded storage.
  local history = activity.since_tick == activity.epoch_tick and activity or factory_activity.snapshot(nil, true)
  local material_flow = build_material_flow(flow_entities, flow_nodes_by_key, activity, network_poles, history, internal)
  local public_flow = present_flow(material_flow, omissions)
  if not internal then
    material_flow = public_flow
    activity = factory_activity.snapshot(params.activity_since_tick)
  end
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
        exact_remote_inventories = false, exact_remote_fluids = false,
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
  if detail == "aggregate" then return { tick = game.tick, summary = summary_text, factory = factory } end

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
  return {
    tick = game.tick, charted_chunks = #chunks, resources = resources,
    water_edges = water_edges, omitted_water_edges = omitted_water_edges,
    factory_landmarks = landmarks, omitted_factory_landmarks = omitted_factory_landmarks,
    factory = factory, summary = summary_text,
  }
end

function M.map_summary(params) return collect_summary(params, false) end

-- Resolve an exact caller-named set of charted factory positions to one
-- aggregate component. This deliberately returns counters and provenance, not
-- remote inventories or fluids, so a parked plan can compare two bounded
-- samples without introducing another observer.
function M.factory_component_sample(params)
  if type(params) ~= "table" or type(params.positions) ~= "table"
    or #params.positions < 1 or #params.positions > 16 then
    error("factory component sample requires 1-16 positions")
  end
  local summary = collect_summary({ activity_since_tick = params.source_tick }, true, params.drill_products)
  local flow = summary.factory.material_flow
  local selected_component
  local selected_ids = {}
  local component_signatures_by_position, split = {}, false
  for _, position in ipairs(params.positions) do
    local found, matches
    for _, node in ipairs(flow.nodes) do
      if node.position.x == position.x and node.position.y == position.y then found, matches = node, (matches or 0) + 1 end
    end
    if not found then error(string.format("FACTORY_COMPONENT_TARGET_NOT_FOUND: no charted node at %.17g,%.17g", position.x, position.y)) end
    if matches > 1 then error(string.format("FACTORY_COMPONENT_TARGET_AMBIGUOUS: multiple charted nodes at %.17g,%.17g", position.x, position.y)) end
    local component
    for _, candidate in ipairs(flow.components) do
      for _, id in ipairs(candidate.node_ids) do if id == found.id then component = candidate; break end end
      if component then break end
    end
    if not component then error("FACTORY_COMPONENT_TARGET_OMITTED: selected node has no component") end
    if selected_component and selected_component.component_id ~= component.component_id then
      split = true
    end
    component_signatures_by_position[#component_signatures_by_position + 1] = {
      position = { x = position.x, y = position.y }, component_id = component.component_id,
      component_signature = component.component_signature,
    }
    selected_component = component
    selected_ids[#selected_ids + 1] = found.id
  end
  if split then return { code = "FACTORY_COMPONENT_SPLIT", stage = "selector",
    component_signatures_by_position = component_signatures_by_position } end
  table.sort(selected_ids)
  return {
    tick = summary.tick, source_tick = params.source_tick,
    component_id = selected_component.component_id,
    component_signature = selected_component.component_signature,
    _signature = selected_component._signature, _downstream = selected_component._downstream,
    _production = selected_component._production, _source_production = selected_component._source_production,
    _supply_sources = selected_component._supply_sources, _supplies_power = selected_component._supplies_power,
    _native_activity = selected_component._native_activity,
    downstream_kind = selected_component.state.downstream_kind,
    blocked_output = selected_component.state.blocked_output,
    selected_node_ids = selected_ids,
    products_finished_total = selected_component.products_finished_total,
    character_transfer_actions = selected_component.character_transfer_actions,
    character_history_complete = summary.factory.character_transfers.history_complete,
    topology_ready = selected_component.state.autonomy_topology_ready,
    blockers = selected_component.state.autonomy_blockers,
    _blocker_rows = selected_component._blocker_rows, _node_status = selected_component._node_status,
    _buffers = selected_component._buffers, _inputs = selected_component._inputs,
    _fuel_buffers = selected_component._fuel_buffers,
    graph_omissions = {
      nodes = summary.factory.omissions.capped_flow_nodes,
      edges = summary.factory.omissions.capped_flow_edges,
      diagnostics = summary.factory.omissions.capped_edge_diagnostics,
    },
    evidence_class = "charted_component_counter_sample",
    exact_remote_inventories = false, exact_remote_fluids = false,
  }
end

return M
