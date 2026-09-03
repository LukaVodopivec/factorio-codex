-- Read-only summary of the force's already charted world. No chart or generation calls.
local companion = require("scripts.companion")
local factory_activity = require("scripts.factory_activity")

local M = {}
local MAX_EDGES = 256
local MAX_LANDMARKS = 256
local MAX_FACTORY_GROUPS = 64
local MAX_FLOW_ROWS = 64
local MAX_FLOW_NODES = 32
local MAX_FLOW_EDGES = 64

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

local function is_water(surface, x, y)
  local ok, tile = pcall(surface.get_tile, x, y)
  if not ok or not tile then return false end
  for _, layer in ipairs({ "water_tile", "water-tile", "player" }) do
    local collision_ok, collides = pcall(tile.collides_with, layer)
    if collision_ok and collides then return true end
  end
  return false
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
    for _, row in pairs(rows) do
      if type(row) == "table" and type(row.name) == "string" then
        destination[#destination + 1] = { name = row.name, type = row.type == "fluid" and "fluid" or "item" }
      end
    end
  end
  collect("ingredients", fact.ingredients)
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

local function build_material_flow(flow_entities, node_by_key, activity, omissions)
  local nodes = sorted_rows(node_by_key, key_position)
  omissions.capped_flow_nodes = cap_rows(nodes, MAX_FLOW_NODES)
  local retained, key_to_id = {}, {}
  for index, node in ipairs(nodes) do
    node.id = "node-" .. index
    key_to_id[node._key] = node.id
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
  omissions.capped_flow_edges = cap_rows(edges, MAX_FLOW_EDGES)
  table.sort(diagnostics, function(a, b)
    return a.node_id == b.node_id and a.reason < b.reason or a.node_id < b.node_id
  end)
  omissions.capped_edge_diagnostics = cap_rows(diagnostics, MAX_FLOW_EDGES)

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
      products_finished_total = 0, character_transfer_actions = 0 }
    by_root[r] = component
    component.node_ids[#component.node_ids + 1] = node.id
    component.roles[node.role] = (component.roles[node.role] or 0) + 1
    component.status_counts[node.status] = (component.status_counts[node.status] or 0) + 1
    component.products_finished_total = component.products_finished_total + (node.products_finished or 0)
  end
  for _, edge in ipairs(edges) do by_root[root(edge.from)].edge_count = by_root[root(edge.from)].edge_count + 1 end
  for _, event in ipairs(activity.target_actions or {}) do
    if event.target then
      local key = string.format("%s\0%s\0%.17g\0%.17g", event.target.name, event.target.type,
        event.target.position.x, event.target.position.y)
      local node = retained[key]
      if node then by_root[root(node.id)].character_transfer_actions = by_root[root(node.id)].character_transfer_actions + event.transfer_actions end
    end
  end
  local components = sorted_rows(by_root, function(a, b) return a.node_ids[1] < b.node_ids[1] end)
  for index, component in ipairs(components) do
    component.component_id = "component-" .. index
    local has_path_roles = (component.roles.source or 0) > 0 and (component.roles.processor or 0) > 0
      and ((component.roles.sink or 0) > 0 or (component.roles.buffer or 0) > 0)
    local local_work = (component.status_counts.working or 0) > 0
    component.state = {
      machine_present = true,
      locally_operating = local_work,
      autonomous_end_to_end = false,
      autonomy_evidence = component.character_transfer_actions > 0 and "character_transfer_observed"
        or has_path_roles and "unattended_output_acceptance_not_yet_proven" or "physical_end_to_end_path_not_proven",
    }
  end
  for _, node in ipairs(nodes) do node._key, node._entity = nil, nil end
  return { nodes = nodes, edges = edges, components = components, diagnostics = diagnostics,
    relationship_semantics = "exact_runtime_targets_only; absence_or_unsupported_is_not_a_connection" }
end

function M.map_summary(params)
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

  local resources_by_name, landmarks, seen_landmark, seen_resource, water_edges, seen_edge = {}, {}, {}, {}, {}, {}
  local groups_by_key, flow_candidates, electric_networks = {}, {}, {}
  local flow_entities, flow_nodes_by_key = {}, {}
  local omissions = { capped_groups = 0, capped_flows = 0, unsupported_entities = 0,
    invalid_entities = 0, unsupported_flow_statistics = 0, capped_flow_nodes = 0,
    capped_flow_edges = 0, capped_edge_diagnostics = 0 }
  for _, name in ipairs(params.flow_items or {}) do add_flow_candidate(flow_candidates, "item", name) end
  for _, name in ipairs(params.flow_fluids or {}) do add_flow_candidate(flow_candidates, "fluid", name) end
  local explicit_flows = params.flow_items ~= nil or params.flow_fluids ~= nil
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
              recipe = recipe and recipe.name or nil,
              products_finished = number_property(entity, "products_finished"),
              power_state = raw_status == "no_power" and "missing" or raw_status == "low_power" and "low" or "not_exactly_observed",
              fuel_state = raw_status == "no_fuel" and "missing" or "not_exactly_observed",
            }
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
    if detail == "full" then for y = y0, y0 + 31 do
      for x = x0, x0 + 31 do
        local current = is_water(c.surface, x, y)
        for _, delta in ipairs({ { 1, 0 }, { 0, 1 } }) do
          local nx, ny = x + delta[1], y + delta[2]
          local neighbor_chunk = { x = math.floor(nx / 32), y = math.floor(ny / 32) }
          if c.force.is_chunk_charted(c.surface, neighbor_chunk) then
            local neighbor = is_water(c.surface, nx, ny)
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
  local activity = factory_activity.snapshot(params.activity_since_tick)
  local material_flow = build_material_flow(flow_entities, flow_nodes_by_key, activity, omissions)
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

return M
