-- Read-only summary of the force's already charted world. No chart or generation calls.
local companion = require("scripts.companion")
local factory_activity = require("scripts.factory_activity")

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
  no_resources = "no_resources", disabled_by_control_behavior = "disabled",
  disabled_by_script = "disabled", marked_for_deconstruction = "disabled",
  turned_off_during_daytime = "disabled",
}

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

local function recipe_fact(entity)
  local ok, recipe = pcall(function() return entity.get_recipe and entity.get_recipe() end)
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

local function build_material_flow(flow_entities, node_by_key, activity, sample_transport_waits)
  local nodes = sorted_rows(node_by_key, key_position)
  local retained = {}
  for index, node in ipairs(nodes) do
    node.id = "node-" .. index
    retained[node._key] = node
  end
  local edges, seen_edges, diagnostics = {}, {}, {}
  local function diagnostic(node, reason, confidence)
    diagnostics[#diagnostics + 1] = { node_id = node.id, reason = reason, confidence = confidence or "exact" }
  end
  local function add_edge(from_entity, to_entity, kind)
    local from_key, to_key = entity_key(from_entity), entity_key(to_entity)
    local from, to = from_key and retained[from_key], to_key and retained[to_key]
    if not from or not to then return false end
    local key = from.id .. "\0" .. to.id .. "\0" .. kind
    if seen_edges[key] then return true end
    seen_edges[key] = true
    edges[#edges + 1] = { from = from.id, to = to.id, kind = kind, confidence = "exact_runtime_relationship" }
    return true
  end
  for _, entity in ipairs(flow_entities) do
    local node = retained[entity_key(entity)]
    if node then
      if entity.type == "inserter" then
        local ok_pickup, pickup = pcall(function() return entity.pickup_target end)
        local ok_drop, drop = pcall(function() return entity.drop_target end)
        if not ok_pickup then diagnostic(node, "inserter_pickup_ambiguous_requires_local_inspection", "ambiguous")
        elseif not pickup or not add_edge(pickup, entity, "inserter_pickup") then diagnostic(node, "inserter_pickup_has_no_eligible_entity") end
        if not ok_drop then diagnostic(node, "inserter_drop_ambiguous_requires_local_inspection", "ambiguous")
        elseif not drop or not add_edge(entity, drop, "inserter_drop") then diagnostic(node, "inserter_drop_has_no_eligible_sink") end
      elseif entity.type == "mining-drill" then
        local ok_drop, drop = pcall(function() return entity.drop_target end)
        if not ok_drop then diagnostic(node, "output_connection_ambiguous_requires_local_inspection", "ambiguous")
        elseif not drop or not add_edge(entity, drop, "machine_output") then diagnostic(node, "output_has_no_physical_sink") end
      elseif entity.type == "transport-belt" or entity.type == "underground-belt"
        or entity.type == "splitter" or entity.type == "loader" or entity.type == "loader-1x1" then
        local ok_neighbours, neighbours = pcall(function() return entity.belt_neighbours end)
        if ok_neighbours and type(neighbours) == "table" then
          for _, input in pairs(neighbours.inputs or {}) do add_edge(input, entity, "belt_direction") end
          local outputs = 0
          for _, output in pairs(neighbours.outputs or {}) do if add_edge(entity, output, "belt_direction") then outputs = outputs + 1 end end
          if outputs == 0 then diagnostic(node, "belt_orientation_does_not_reach_consumer") end
        else
          diagnostic(node, "belt_connection_ambiguous_requires_local_inspection", "ambiguous")
        end
      end
      if node.status == "full_output" then diagnostic(node, "downstream_inventory_blocked") end
      if node.status == "no_power" or node.status == "low_power" then diagnostic(node, "missing_power") end
      if node.status == "no_fuel" then diagnostic(node, "missing_fuel") end
      if node.status == "insufficient_input" then diagnostic(node, "missing_or_mismatched_input", "status_only") end
    end
  end
  table.sort(edges, function(a, b)
    if a.from ~= b.from then return a.from < b.from end
    if a.to ~= b.to then return a.to < b.to end
    return a.kind < b.kind
  end)

  local parent = {}; for _, node in ipairs(nodes) do parent[node.id] = node.id end
  local function root(id)
    while parent[id] ~= id do parent[id] = parent[parent[id]]; id = parent[id] end
    return id
  end
  local function join(a, b) a, b = root(a), root(b); if a ~= b then parent[b] = a end end
  for _, edge in ipairs(edges) do join(edge.from, edge.to) end
  local by_root = {}
  for _, node in ipairs(nodes) do
    local r = root(node.id)
    local component = by_root[r] or { node_ids = {}, roles = {}, status_counts = {}, edge_count = 0,
      products_finished_total = 0, character_transfer_actions = 0, last_character_transfer_tick = nil, _edges = {}, _diagnostics = {} }
    by_root[r] = component
    component.node_ids[#component.node_ids + 1] = node.id
    component.roles[node.role] = (component.roles[node.role] or 0) + 1
    component.status_counts[node.status] = (component.status_counts[node.status] or 0) + 1
    component.products_finished_total = component.products_finished_total + (node.products_finished or 0)
  end
  for _, edge in ipairs(edges) do
    local component = by_root[root(edge.from)]
    component.edge_count = component.edge_count + 1
    component._edges[#component._edges + 1] = edge
  end
  for _, event in ipairs(activity.target_actions or {}) do
    if event.target then
      local key = string.format("%s\0%s\0%.17g\0%.17g", event.target.name, event.target.type,
        event.target.position.x, event.target.position.y)
      local node = retained[key]
      if node then
        local component = by_root[root(node.id)]
        component.character_transfer_actions = component.character_transfer_actions + event.transfer_actions
        component.last_character_transfer_tick = math.max(component.last_character_transfer_tick or 0,
          tonumber(event.last_transfer_tick) or 0)
      end
    end
  end
  local components = sorted_rows(by_root, function(a, b) return a.node_ids[1] < b.node_ids[1] end)
  local node_by_id, incoming, outgoing = {}, {}, {}
  for _, node in ipairs(nodes) do node_by_id[node.id], incoming[node.id], outgoing[node.id] = node, {}, {} end
  for _, edge in ipairs(edges) do
    incoming[edge.to][#incoming[edge.to] + 1] = edge.from
    outgoing[edge.from][#outgoing[edge.from] + 1] = edge.to
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
  -- Prove held or burning-and-stocked fuel and physical supply; never infer
  -- a hard-coded stock limit or exempt other full-output entities.
  for _, node in ipairs(nodes) do
    if node.type == "inserter" then
      local pickup, destination
      for _, edge in ipairs(edges) do
        if edge.from == node.id and edge.kind == "inserter_drop" then destination = node_by_id[edge.to] end
        if edge.to == node.id and edge.kind == "inserter_pickup" then pickup = node_by_id[edge.from] end
      end
      local function pickup_supplies(product, fuel_only)
        return pickup and ((pickup.role == "source" or pickup.role == "processor") and product_matches(pickup, product, fuel_only)
          or (pickup.role == "transport" or pickup.role == "buffer") and upstream_proven(pickup.id, product, fuel_only))
      end
      -- Unreadable compartment evidence cannot erase the fuel obligation.
      -- Establish the physical candidate first, then prove its compartment.
      local fuel_return = destination and (destination.role == "source" or destination.role == "processor")
        and destination.requires_fuel
        and pickup_supplies(destination.fuel_categories, true)
      node._fuel_return_required = fuel_return or false
      if fuel_return and destination._fuel_destination_proven and destination.status == "working" then
        local ok, fuel, quality, identity = pcall(function()
          local held = node._entity.held_stack
          local burner = destination._entity.burner
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
            -- Factorio 2.0: empty LuaItemStack identity is unreadable. The
            -- burning pair returns prototypes; inventory contents return names.
            -- Require one unambiguous stocked pair matching the burning pair.
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
            and (not node._waiting_for_destination or inventory.can_insert(item) == true) then
            return name, quality_name, identity_source
          end
        end)
        local product = { name = fuel, type = "item" }
        local supplied = pickup_supplies(product, false)
        if ok and fuel and supplied then
          node._fuel_return_supply = { destination_node_id = destination.id, fuel = fuel, quality = quality,
            identity_source = identity,
            evidence = "supplied_working_burner_with_stocked_fuel" }
          if node._waiting_for_destination then
            node.fuel_return_saturation = node._fuel_return_supply
            node.fuel_return_saturation.observed_status = "waiting_for_space_in_destination"
            node.fuel_return_saturation.evidence = "supplied_working_burner_with_fuel_inventory_space"
          end
        end
      end
      if node._waiting_for_source and pickup and destination then
        local ok_empty, empty = pcall(function() return node._entity.held_stack.valid_for_read == false end)
        local supplied = false
        if fuel_return then
          supplied = node._fuel_return_supply ~= nil
        else
          for _, candidate in ipairs(nodes) do
            if candidate.role == "source" or candidate.role == "processor" then
              for _, product in ipairs(candidate.products) do
                if pickup_supplies(product, false) and (destination.role == "buffer" or destination.role == "sink"
                  or destination.role == "processor" and product_matches({ products = destination.ingredients }, product, false)) then
                  supplied = true
                end
              end
            end
          end
        end
        if ok_empty and empty and supplied then
          node.transport_wait = { observed_status = "waiting_for_source_items", destination_node_id = destination.id,
            evidence = "exact_supplied_transport_requires_bounded_resumption" }
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
  for _, node in ipairs(nodes) do
    if node.role == "buffer" or node.role == "sink" then
      node._downstream_buffer = node.role == "buffer" and #outgoing[node.id] == 0
      local products, queue, seen, head = {}, { node.id }, {}, 1
      while head <= #queue do
        local id = queue[head]; head = head + 1
        if not seen[id] then
          seen[id] = true
          local upstream = node_by_id[id]
          if upstream.role == "source" or upstream.role == "processor" then
            for _, product in ipairs(upstream.products) do products[product.type .. ":" .. product.name] = product end
          elseif upstream.role == "transport" or upstream.role == "buffer" or id == node.id then
            for _, parent_id in ipairs(incoming[id]) do queue[#queue + 1] = parent_id end
          end
        end
      end
      node._accepted_stock, node._accepted_products = {}, {}
      node._accepting = next(products) ~= nil and (node.role == "buffer" or node.status == "working")
      for key, product in pairs(products) do
        -- Inventory values are private interval samples, never serialized.
        -- Unsupported fluid endpoints remain unproven rather than guessing capacity.
        local ok, count, accepting = pcall(function()
          if product.type ~= "item" then error("unsupported fluid endpoint acceptance") end
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
          if not accepting then node._accepting = false; node._blocked_output = true end
        end
      end
    end
  end
  for _, row in ipairs(diagnostics) do
    if row.reason == "downstream_inventory_blocked" and node_by_id[row.node_id].fuel_return_saturation then
      row.nonblocking_reason = "proven_fuel_return_saturation"
    elseif row.reason == "missing_or_mismatched_input" and node_by_id[row.node_id].transport_wait then
      row.validation_nonblocking_reason = "provisional_transport_wait_requires_bounded_resumption"
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
    local blockers, signature_rows, producing_nodes, accepting_sinks = {}, {}, 0, 0
    local buffers, consumers, blocked_output = 0, 0, false
    component._downstream, component._production, component._source_production = {}, {}, {}
    component._transport_waits, component._transport_working, component._fuel_returns = {}, {}, {}
    for _, id in ipairs(component.node_ids) do
      local node = node_by_id[id]
      if node.transport_wait then component._transport_waits[node._key] = true end
      if node.type == "inserter" and node.status == "working" then component._transport_working[node._key] = true end
      if node._fuel_return_required then component._fuel_returns[node._key] = node._fuel_return_supply ~= nil end
      signature_rows[#signature_rows + 1] = node._key .. ":" .. tostring(node.direction) .. ":"
        .. tostring(number_property(node._entity, "unit_number")) .. ":" .. tostring(node.recipe)
      for _, ingredient in ipairs(node.ingredients) do signature_rows[#signature_rows + 1] = node._key .. ":input:" .. ingredient.type .. ":" .. ingredient.name end
      for _, product in ipairs(node.products) do signature_rows[#signature_rows + 1] = node._key .. ":output:" .. product.type .. ":" .. product.name end
      if node.role == "sink" then
        consumers = consumers + 1
        component._downstream[node._key] = { kind = "consumer", accepting = node._accepting, products = node._accepted_products }
      elseif node._downstream_buffer then
        buffers = buffers + 1
        component._downstream[node._key] = { kind = "buffer", accepting = node._accepting, stock = node._accepted_stock }
        if node._accepting then accepting_sinks = accepting_sinks + 1 end
      end
      if node._blocked_output or node.status == "full_output" and not node.fuel_return_saturation then blocked_output = true end
      if node.role == "source" or node.role == "processor" then
        producing_nodes = producing_nodes + 1
        if node.role == "source" then
          component._source_production[node._key] = node._source_production
          if not node._source_production.working then blockers[#blockers + 1] = { node_id = id, reason = "source_not_locally_operating" } end
        end
        if node.role == "processor" then component._production[node._key] = node.products_finished or false end
        if #node.products == 0 then blockers[#blockers + 1] = { node_id = id, reason = "output_identity_unproven" } end
        if not reaches_downstream(id) then blockers[#blockers + 1] = { node_id = id, reason = "downstream_acceptance_path_unproven" } end
      end
      if node.role == "sink" and node._accepting then accepting_sinks = accepting_sinks + 1 end
      for _, ingredient in ipairs(node.ingredients or {}) do
        if not upstream_proven(id, ingredient, false) then
          blockers[#blockers + 1] = { node_id = id, reason = "material_input_provenance_unresolved", input = ingredient }
        end
      end
      if node.requires_fuel and not upstream_proven(id, node.fuel_categories or {}, true) then
        blockers[#blockers + 1] = { node_id = id,
          reason = next(node.fuel_categories or {}) and "fuel_input_provenance_unresolved" or "fuel_compatibility_unproven" }
      end
      if node.status == "no_power" or node.status == "low_power" or node.status == "no_fuel"
        or node.status == "insufficient_input" and not (sample_transport_waits and node.transport_wait)
        or node.status == "full_output" and not node.fuel_return_saturation
        or node.status == "disabled" or node.status == "no_resources" then
        blockers[#blockers + 1] = { node_id = id, reason = "nonproductive_status", status = node.status }
      end
    end
    for _, edge in ipairs(component._edges) do
      signature_rows[#signature_rows + 1] = node_by_id[edge.from]._key .. "->" .. node_by_id[edge.to]._key .. ":" .. edge.kind
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
      local exempt = diagnostic.reason == "downstream_inventory_blocked" and node_by_id[diagnostic.node_id].fuel_return_saturation
        or sample_transport_waits and diagnostic.reason == "missing_or_mismatched_input" and node_by_id[diagnostic.node_id].transport_wait
      if not exempt then
        blockers[#blockers + 1] = { node_id = diagnostic.node_id, reason = "relationship_diagnostic", diagnostic = diagnostic.reason }
      end
    end
    if producing_nodes == 0 or (component.roles.source or 0) == 0
      or buffers + consumers == 0 then
      blockers[#blockers + 1] = { reason = "physical_source_downstream_path_unproven" }
    end
    if accepting_sinks == 0 then blockers[#blockers + 1] = { reason = "downstream_acceptance_not_observed" } end
    if blocked_output then blockers[#blockers + 1] = { reason = "blocked_output" } end
    local validation
    for _, candidate in ipairs(activity.validations or {}) do
      if candidate._signature == component._signature and candidate.proven then validation = candidate end
    end
    if validation then
      for _, supplied in pairs(component._fuel_returns) do
        if not supplied then blockers[#blockers + 1] = { reason = "fuel_return_supply_unproven" }; break end
      end
    end
    -- Bootstrap transfers before a successful bounded validation are historical
    -- debt, not evidence that the now-connected component still needs the
    -- character. Any transfer at or after the validation interval begins
    -- revokes it; incomplete telemetry remains conservatively unproven.
    local transfer_observed = validation and component.last_character_transfer_tick
      and component.last_character_transfer_tick >= validation.start_tick
      or not validation and component.character_transfer_actions > 0
    local topology_ready = #blockers == 0 and activity.history_complete and not transfer_observed
    local autonomous = topology_ready and validation ~= nil
    local blocker_names, seen_blocker = {}, {}
    for _, blocker in ipairs(blockers) do
      local name = blocker.reason
      if blocker.input then name = name .. ":" .. blocker.input.type .. ":" .. blocker.input.name end
      if blocker.status then name = name .. ":" .. blocker.status end
      if blocker.diagnostic then name = name .. ":" .. blocker.diagnostic end
      if not seen_blocker[name] then seen_blocker[name] = true; blocker_names[#blocker_names + 1] = name end
    end
    table.sort(blocker_names)
    component.state = {
      downstream_kind = buffers > 0 and (consumers > 0 and "mixed" or "buffer") or (consumers > 0 and "consumer" or "none"),
      blocked_output = blocked_output,
      machine_present = true,
      locally_operating = local_work,
      autonomy_topology_ready = topology_ready,
      autonomous_end_to_end = autonomous,
      autonomy_evidence = autonomous and "bounded_multi_tick_no_character_transfer_validation"
        or transfer_observed and "character_transfer_observed"
        or not activity.history_complete and "character_transfer_history_incomplete"
        or topology_ready and "bounded_multi_tick_production_not_yet_proven"
        or "physical_end_to_end_path_not_proven",
      autonomy_blockers = blocker_names,
      validation = validation,
    }
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
  omissions.capped_flow_nodes = #flow.nodes - #result.nodes
  omissions.capped_flow_edges = #flow.edges - #result.edges
  omissions.capped_flow_components = #flow.components - #result.components
  omissions.capped_edge_diagnostics = #flow.diagnostics - #result.diagnostics
  return result
end

local function collect_summary(params, internal)
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
  local groups_by_key, flow_candidates, electric_networks = {}, {}, {}
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
          if network_id then electric_networks[network_id] = true end
          if role then
            local node = {
              _key = key, _entity = entity, name = entity.name, type = entity.type,
              role = role, position = { x = entity.position.x, y = entity.position.y },
              direction = entity.direction, status = normalize_status(raw_status),
              _waiting_for_destination = raw_status == "waiting_for_space_in_destination",
              _waiting_for_source = raw_status == "waiting_for_source_items",
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
              node._source_production = { working = node.status == "working", progress = number_property(entity, "mining_progress") }
              local ok, target = pcall(function() return entity.mining_target end)
              if ok and entity_key(target) and charted(c.force, c.surface, target.position) then
                node._source_production.resource_key = entity_key(target)
                node._source_production.remaining = number_property(target, "amount")
              end
            end
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
  local material_flow = build_material_flow(flow_entities, flow_nodes_by_key, activity, internal and params._sample_transport_waits)
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
  local summary = collect_summary({ activity_since_tick = params.source_tick, _sample_transport_waits = params.sample_transport_waits }, true)
  local flow = summary.factory.material_flow
  local selected_component
  local selected_ids = {}
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
      error("FACTORY_COMPONENT_SPLIT: positions do not belong to one exact physical component")
    end
    selected_component = component
    selected_ids[#selected_ids + 1] = found.id
  end
  table.sort(selected_ids)
  local blockers = { table.unpack(selected_component.state.autonomy_blockers) }
  for _, supplied in pairs(selected_component._fuel_returns) do
    if not supplied then blockers[#blockers + 1] = "fuel_return_supply_unproven"; break end
  end
  return {
    tick = summary.tick, source_tick = params.source_tick,
    component_id = selected_component.component_id,
    component_signature = selected_component.component_signature,
    _signature = selected_component._signature, _downstream = selected_component._downstream,
    _production = selected_component._production, _source_production = selected_component._source_production,
    _transport_waits = selected_component._transport_waits, _transport_working = selected_component._transport_working,
    downstream_kind = selected_component.state.downstream_kind,
    blocked_output = selected_component.state.blocked_output,
    selected_node_ids = selected_ids,
    products_finished_total = selected_component.products_finished_total,
    character_transfer_actions = selected_component.character_transfer_actions,
    character_history_complete = summary.factory.character_transfers.history_complete,
    topology_ready = selected_component.state.autonomy_topology_ready and #blockers == 0,
    blockers = blockers,
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
