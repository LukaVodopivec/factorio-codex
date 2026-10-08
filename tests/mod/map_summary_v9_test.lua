local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
local stacks = dofile(here .. "/item_stack_mock.lua")
-- Keep mock/locator in an outer scope: this suite reaches Lua's local limit.
-- map_summary is a job; this runs one to its end, a tick's budget at a time.
local function summarize(params)
  return require("scripts.jobs").run_now(require("scripts.map_summary").summary_job, params)
end
local function run()
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local function canonical(value)
  if type(value) ~= "table" then return type(value) == "string" and string.format("%q", value) or tostring(value) end
  local is_array, count = true, 0
  for key in pairs(value) do if type(key) ~= "number" then is_array = false end; count = count + 1 end
  if is_array then local out = {}; for i = 1, count do out[i] = canonical(value[i]) end; return "[" .. table.concat(out, ",") .. "]" end
  local keys = {}; for key in pairs(value) do keys[#keys + 1] = key end; table.sort(keys)
  local out = {}; for _, key in ipairs(keys) do out[#out + 1] = string.format("%q", key) .. ":" .. canonical(value[key]) end
  return "{" .. table.concat(out, ",") .. "}"
end
local resources = {
  mock.entity({ valid = true, name = "iron-ore", type = "resource", amount = 20, position = { x = 8, y = 1 } }),
  mock.entity({ valid = true, name = "iron-ore", type = "resource", amount = 10, position = { x = 3, y = 1 } }),
  mock.entity({ valid = true, name = "copper-ore", type = "resource", amount = 999, position = { x = 33, y = 1 } }),
}
local force = {
  is_chunk_charted = function(_, chunk) return chunk.x == 0 and chunk.y == 0 end,
  is_chunk_visible = function(_, chunk) return chunk.x == 0 and chunk.y == 0 end,
  get_item_production_statistics = function() return { get_flow_count = function(params)
    return params.category == "input" and 2 or 3
  end } end,
  get_fluid_production_statistics = function() return { get_flow_count = function() return 0 end } end,
}
local machine = mock.entity({ valid = true, name = "assembling-machine-1", type = "assembling-machine", position = { x = 5, y = 5 }, direction = 4, status = 1, force = force,
  crafting_speed = 1, get_inventory = function() error("aggregate must not inspect remote inventory") end,
  get_recipe = function() return { name = "gear", energy = 0.5,
    ingredients = { { name = "iron", type = "item" } }, products = { { name = "gear", type = "item" } } } end })
local foreign_force = {}
local foreign_machine = mock.entity({ valid = true, name = "foreign-machine", type = "assembling-machine",
  position = { x = 6, y = 5 }, force = foreign_force, status = 1 })
local invalid_machine = mock.entity({ valid = false, name = "invalid-machine", type = "furnace", position = { x = 7, y = 5 }, force = force })
local body = mock.entity({ valid = true, name = "character", type = "character", position = { x = 0, y = 0 }, force = force })
local surface = {
  get_chunks = function()
    local chunks, index = { { x = 1, y = 0 }, { x = 0, y = 0 } }, 0
    return function() index = index + 1; return chunks[index] end
  end,
  find_tiles_filtered = function(filter)
    local tiles = {}
    for y = filter.area[1][2], filter.area[2][2] - 1 do
      for x = filter.area[1][1], filter.area[2][1] - 1 do
        if x >= 16 then tiles[#tiles + 1] = { position = { x = x, y = y } } end
      end
    end
    return tiles
  end,
  find_entities_filtered = function(filter) if filter.type == "resource" then return resources end; return { machine, foreign_machine, invalid_machine, body } end,
}
body.surface = surface
package.loaded["scripts.companion"] = { require_companion = function() return body end,
  -- The real dependency-free burner reader, not a stub of it.
  burning_item = dofile(here .. "/../../mod/agentic-companion/scripts/companion.lua").burning_item }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
_G.prototypes = { tile = {
  land = { collision_mask = { layers = {} } },
  water = { collision_mask = { layers = { water_tile = true, player = true } } },
} }
_G.game = { tick = 777, create_inventory = stacks.create_inventory }
_G.storage = {}
_G.defines = { entity_status = { no_power = 1 }, flow_precision_index = { one_minute = 1 } }
local summary = summarize({ detail = "full" })
check(summary.tick == 777 and summary.charted_chunks == 1, "map summary carries source tick and charted chunk count")
check(#summary.resources == 1 and summary.resources[1].total_amount == 30 and summary.resources[1].nearest.x == 3,
  "resource totals and nearest target are deterministic and exclude uncharted entity centers")
check(#summary.water_edges > 0 and summary.water_edges[1].land.x == 15 and summary.water_edges[1].water.x == 16,
  "water edge samples stay inside charted terrain")
check(#summary.factory_landmarks == 1 and summary.factory_landmarks[1].status == "no_power"
  and summary.factory_landmarks[1].recipe == "gear" and summary.factory_landmarks[1].observed_tick == 777,
  "factory landmarks include machine facts and observation ticks without characters or ghosts")
check(force.chart == nil and surface.request_to_generate_chunks == nil, "summary exposes no terrain generation path")
check(force.get_charted_chunks == nil, "summary uses the Factorio 2.0 surface iterator and force chart filter")
local aggregate = summarize({})
check(aggregate.resources == nil and aggregate.water_edges == nil and aggregate.factory_landmarks == nil,
  "aggregate is the compact default and omits legacy detail")
check(aggregate.factory.scope == "force_charted" and aggregate.factory.charted_chunks == 1
  and aggregate.factory.currently_visible_charted_chunks == 1,
  "aggregate distinguishes charted scope from current visibility")
check(aggregate.factory.machine_count == 1 and #aggregate.factory.groups == 1
  and aggregate.factory.groups[1].status_counts.no_power == 1
  and aggregate.factory.groups[1].theoretical_crafts_per_second == 2,
  "factory groups expose deterministic installed capacity and normalized status")
check(#aggregate.factory.force_flows == 2 and aggregate.factory.force_flows[1].window_ticks == 3600
  and aggregate.factory.force_flows[1].units == "units_per_minute"
  and aggregate.factory.force_flows[1].source == "force_flow_statistics",
  "native force flows carry explicit source, precision window, and units")
check(#aggregate.factory.material_flow.nodes == 1
  and aggregate.factory.material_flow.components[1].state.machine_present
  and not aggregate.factory.material_flow.components[1].state.locally_operating
  and aggregate.factory.material_flow.components[1].state.autonomous_end_to_end == nil
  and aggregate.factory.material_flow.components[1].state.autonomy_evidence == nil,
  "machine presence and local operation are reported without proof fields")
check(aggregate.factory.character_transfers.transfer_actions == 0,
  "aggregate includes bounded run-local character transfer evidence")
check(aggregate.factory.machine_count == 1,
  "aggregate excludes foreign-force entities (machine_count=" .. tostring(aggregate.factory.machine_count) .. ")")
check(aggregate.factory.omissions.invalid_entities == 1,
  "aggregate reports invalid owned candidates (invalid=" .. tostring(aggregate.factory.omissions.invalid_entities) .. ")")
check(aggregate.factory.evidence.entity_summary.evidence_class == "charted_remote_summary"
  and not aggregate.factory.evidence.entity_summary.exact_remote_inventories
  and aggregate.factory.evidence.force_flows.evidence_class == "rolling_force_surface_flow"
  and aggregate.factory.evidence.cached_or_previously_observed_facts.included == false,
  "aggregate labels charted, rolling, and absent cached evidence without exposing remote stock")

-- Nominal mining capacity uses each currently evidenced resource, independently
-- of achieved flow, status and the existing material-flow validation evidence.
do
  local original_find = surface.find_entities_filtered
  local function drill(x, time, amount, status)
    local target = mock.entity({ valid = true, name = "ore", type = "resource",
      position = { x = x, y = 2 }, amount = 100,
      prototype = { mineable_properties = { mining_time = time,
        products = { { type = "item", name = "ore", amount = amount } } } } })
    return mock.entity({ valid = true, name = "test-drill", type = "mining-drill",
      position = { x = x, y = 2 }, force = force, status = status,
      prototype = { mining_speed = 0.5 }, mining_target = target })
  end
  local first, second = drill(1, 1, 1, 1), drill(2, 2, 2, 2)
  defines.entity_status.no_fuel = 2
  local installed = { first }
  surface.find_entities_filtered = function(filter)
    if filter.type == "resource" then return {} end
    return installed
  end
  local function group()
    return summarize({ flow_items = { "ore" } }).factory.groups[1]
  end
  local one = group()
  check(one.theoretical_items_per_minute == 30 and one.capacity_state == "complete"
    and one.evidenced_drill_count == 1 and one.status_counts.no_power == 1,
    "one idle installed drill has nominal capacity independent of status")
  second.prototype.mining_speed = 1
  installed = { second, first }
  local many = group()
  check(many.theoretical_items_per_minute == 90 and many.machine_count == 2
    and many.status_counts.no_fuel == 1
    and many.capacity_state == "complete" and many.evidenced_drill_count == 2
    and many.capacity_basis == "nominal_prototype_mining_speed_times_item_yield_divided_by_current_resource_mining_time",
    "mixed-resource-time drill group sums per-drill speed/time/item-yield capacities")
  local measured = summarize({ flow_items = { "ore" } })
  check(measured.factory.force_flows[1].input_rate == 2
    and measured.factory.groups[1].theoretical_items_per_minute == 90,
    "nominal installed capacity remains distinct from rolling force production")
  second.mining_target = nil
  local partial = group()
  check(partial.capacity_state == "incomplete" and partial.evidenced_drill_count == 1
    and partial.theoretical_items_per_minute == nil,
    "missing target cannot turn a partial group into a complete total")
  installed = { first }
  local target, mining = first.mining_target, first.mining_target.prototype.mineable_properties
  local cases = {
    { "missing target", function() first.mining_target = nil end },
    { "uncharted target", function() target.position = { x = 33, y = 2 } end },
    { "invalid target", function() target.valid = false end },
    { "zero mining time", function() mining.mining_time = 0 end },
    { "missing mining time", function() mining.mining_time = nil end },
    { "NaN mining time", function() mining.mining_time = 0/0 end },
    { "negative speed", function() first.prototype.mining_speed = -1 end },
    { "missing speed", function() first.prototype.mining_speed = nil end },
    { "nonfinite speed", function() first.prototype.mining_speed = math.huge end },
    { "missing yield", function() mining.products[1].amount = nil end },
    { "zero yield", function() mining.products[1].amount = 0 end },
    { "nonfinite yield", function() mining.products[1].amount = math.huge end },
    { "empty products", function() mining.products = {} end },
    { "variable yield", function() mining.products[1] = { name = "ore", type = "item", amount_min = 1, amount_max = 2 } end },
    { "probabilistic yield", function() mining.products[1].probability = 0.5 end },
    { "fluid product", function() mining.products[1].type = "fluid" end },
  }
  for _, case in ipairs(cases) do
    first.mining_target, target.valid, target.position = target, true, { x = 1, y = 2 }
    first.prototype.mining_speed, mining.mining_time = 0.5, 1
    mining.products = { { name = "ore", type = "item", amount = 1 } }
    case[2]()
    local missing = group()
    check(missing.capacity_state == "unavailable" and missing.evidenced_drill_count == 0
      and missing.theoretical_items_per_minute == nil, case[1] .. " leaves mining capacity explicitly unavailable")
  end
  first.mining_target, mining.mining_time = target, 1
  first.prototype.mining_speed = 0.5
  mining.products = { { name = "ore", type = "item", amount_min = 2, amount_max = 2, probability = 1 },
    { name = "stone", type = "item", amount = 1 } }
  check(group().theoretical_items_per_minute == 90, "fixed item yields are summed including equal minimum/maximum amounts")
  mock.unreadable(first, "prototype")
  check(group().capacity_state == "unavailable", "unreadable drill prototype leaves nominal capacity unavailable")
  mock.unreadable(first, "prototype", false)
  installed = { machine }
  local crafting = group()
  check(crafting.theoretical_items_per_minute == nil and crafting.capacity_state == nil
    and crafting.theoretical_crafts_per_second == 2,
    "non-drill groups retain crafting capacity without mining labels")
  surface.find_entities_filtered = original_find
  defines.entity_status.no_fuel = nil
end

local dense = {}
for i = 1, 70 do
  dense[i] = mock.entity({ valid = true, name = string.format("machine-%02d", i), type = "assembling-machine",
    position = { x = (i % 28) + 0.1, y = math.floor(i / 28) + 10.1 }, force = force, status = 1,
    crafting_speed = 1, get_recipe = function() return { name = string.format("recipe-%02d", i), energy = 1,
      ingredients = {}, products = { { name = string.format("product-%02d", i), type = "item" } } } end })
end
surface.find_entities_filtered = function(filter) if filter.type == "resource" then return {} end; return dense end
local bounded = summarize({})
check(#bounded.factory.groups == 12 and bounded.factory.omissions.capped_groups == 58
  and #bounded.factory.material_flow.nodes == 12 and bounded.factory.omissions.capped_flow_nodes == 58
  and #bounded.factory.force_flows == 12 and bounded.factory.omissions.capped_flows == 58
  and bounded.factory.partial,
  "factory groups, graph nodes, and flow rows have deterministic caps and omission counts")
check(bounded.factory.material_flow.component_count == 70 and #bounded.factory.material_flow.components == 8
  and bounded.factory.material_flow.edge_count == 0 and bounded.factory.material_flow.line_count == 0
  and bounded.factory.material_flow.self_sustaining_line_count == 0
  and bounded.factory.material_flow.autonomous_component_count == nil,
  "whole-graph component counters stay uncapped beside the capped component rows")
local bounded_full = summarize({ detail = "full" })
local aggregate_bytes, full_bytes = #canonical(bounded), #canonical(bounded_full)
-- 18k plus the uncapped whole-graph and line counters beside the capped rows.
check(aggregate_bytes <= 18250 and aggregate_bytes * 5 < full_bytes * 4,
  "bounded aggregate stays at or below 18.25k fixture bytes and at least 20% smaller than full detail (aggregate="
    .. aggregate_bytes .. ", full=" .. full_bytes .. ")")

-- The public component of the node at a position (fixtures stay within the
-- presentation caps).
local function component_at(position)
  local flow = summarize({}).factory.material_flow
  local id
  for _, node in ipairs(flow.nodes) do
    if node.position.x == position.x and node.position.y == position.y then id = node.id end
  end
  for _, component in ipairs(flow.components) do
    for _, node_id in ipairs(component.node_ids) do
      if node_id == id then
        return { topology_ready = component.state.autonomy_topology_ready, blockers = component.state.autonomy_blockers,
          rows = component.state.blocker_details, blocked_output = component.state.blocked_output,
          component_id = component.component_id, component_signature = component.component_signature }
      end
    end
  end
end

-- A component is topology-ready once every material and fuel input has a
-- physical source. Recipe/source identities prove material provenance;
-- buffers and finite hand-loaded burner stock never serve as roots.
local function flow_fixture(buffer_root, burner)
  local source = mock.entity({ valid = true, name = buffer_root and "wooden-chest" or "electric-mining-drill",
    type = buffer_root and "container" or "mining-drill", position = { x = 1, y = 1 }, force = force,
    status = 3, products_finished = 5 })
  if not buffer_root then source.mining_target = mock.entity({ valid = true, name = "ore", type = "resource", position = source.position, amount = 100, prototype = { mineable_properties = {
    products = { { name = "ore", type = "item" } },
  } } }) end
  local processor = mock.entity({ valid = true, name = "processor", type = "assembling-machine",
    position = { x = 3, y = 1 }, force = force, status = 2, products_finished = 10,
    burner = burner and {} or nil, crafting_speed = 1,
    get_recipe = function() return { name = "process", energy = 1,
      ingredients = { { name = "ore", type = "item" } }, products = { { name = "plate", type = "item" } } } end })
  if burner then processor.prototype = { burner_prototype = { fuel_categories = { chemical = true } } } end
  local sink = mock.entity({ valid = true, name = "lab", type = "lab", position = { x = 5, y = 1 }, force = force, status = 3, get_inventory = function() return {
      can_insert = function(stack) return stack.name == "plate" end,
    } end })
  local feed = mock.entity({ valid = true, name = "feed", type = "inserter", position = { x = 2, y = 1 }, force = force,
    status = 2, pickup_target = source, drop_target = processor })
  local unload = mock.entity({ valid = true, name = "unload", type = "inserter", position = { x = 4, y = 1 }, force = force,
    status = 2, pickup_target = processor, drop_target = sink })
  if not buffer_root then source.drop_target = feed end
  return { source, feed, processor, unload, sink }, source, processor
end

prototypes.item = { coal = { name = "coal", fuel_value = 8, fuel_category = "chemical" } }
defines.entity_status.normal = 2
defines.entity_status.working = 3
defines.inventory = { lab_input = 2 }
storage = {}
local flow_entities, flow_source, flow_processor = flow_fixture(false, false)
surface.find_entities_filtered = function(filter) if filter.type == "resource" then return {} end; return flow_entities end
game.tick = 900
local ready = summarize({})
local ready_component = ready.factory.material_flow.components[1]
check(ready_component.state.autonomy_topology_ready and ready_component.state.autonomous_end_to_end == nil
  and ready_component.state.validation == nil,
  "complete material provenance and downstream path make the component topology-ready, with no proof fields")
game.tick = 960
storage.factory_activity.events[#storage.factory_activity.events + 1] = {
  tick = 900, action = "insert", item_count = 1, target = {
    name = flow_processor.name, type = flow_processor.type, position = flow_processor.position,
  }, items = { { name = "ore", count = 1 } },
}
-- Produce the transfer through real build-plan placement and starter insertion.
package.loaded["scripts.companion"].get = function() return body end
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end, ensure_entity = function() return "ok" end }
prototypes.item.processor = { place_result = { name = "processor", type = "assembling-machine" } }
prototypes.item.ore = { name = "ore" }
defines.build_check_type = { manual = 1 }
body.build_distance = 6
local starter_stock = { processor = 1, ore = 2 }
body.get_item_count = function(name) return starter_stock[type(name) == "table" and name.name or name] or 0 end
body.remove_item = function(stack) starter_stock[stack.name] = starter_stock[stack.name] - stack.count; return stack.count end
-- Starter inserts hand over real stacks (item_stack_mock) over the same stock.
body.get_main_inventory = function() return stacks.view(starter_stock) end
surface.can_place_entity = function() return true end
surface.create_entity = function() return flow_processor end
flow_processor.insert = function(stack) return stack.count end
local build_plan = require("scripts.actions.build_plan")
local starter_plan = { steps = { { item = "processor", position = flow_processor.position, insert = { ore = 2 } } } }
build_plan.start(starter_plan)
local starter_result = build_plan.tick(starter_plan)
check(starter_result.status == "done" and starter_stock.processor == 0 and starter_stock.ore == 0,
  "offline build-plan fixture commits placement and conserved starter insertion")
local touched = summarize({ activity_since_tick = 900 })
check(touched.factory.material_flow.components[1].character_transfer_actions == 2
  and touched.factory.material_flow.components[1].state.autonomy_topology_ready,
  "character transfers are counted per component without changing its topology")
local transfers = touched.factory.character_transfers
check(transfers.transfer_actions == 2 and transfers.transferred_items == 3
  and transfers.inserted_items[1].name == "ore" and transfers.inserted_items[1].count == 3
  and transfers.target_actions[1].transfer_actions == 2
  and transfers.target_actions[1].target.name == flow_processor.name
  and transfers.target_actions[1].target.type == flow_processor.type
  and transfers.target_actions[1].target.position.x == flow_processor.position.x
  and transfers.target_actions[1].last_transfer_tick == 960 and transfers.history_complete,
  "map summary includes build-plan accepted items and exact target actions in the requested interval")
game.tick = 961
check(summarize({ activity_since_tick = 961 }).factory.character_transfers.transfer_actions == 0,
  "map summary excludes starter insertion from a later interval")
force.recipes = { process = { enabled = true } }
flow_processor.set_recipe = function(name) assert(name == "process"); return {} end
starter_stock.processor = 1
local recipe_only = { steps = { { item = "processor", position = flow_processor.position, recipe = "process" } } }
build_plan.start(recipe_only)
check(build_plan.tick(recipe_only).status == "done"
  and require("scripts.factory_activity").snapshot(961).transfer_actions == 0,
  "recipe-only build-plan interaction creates no insertion telemetry")

storage = {}
local buffer_entities = flow_fixture(true, false)
surface.find_entities_filtered = function(filter) if filter.type == "resource" then return {} end; return buffer_entities end
game.tick = 1000
local buffered = summarize({})
check(not buffered.factory.material_flow.components[1].state.autonomy_topology_ready
  and table.concat(buffered.factory.material_flow.components[1].state.autonomy_blockers, ","):match("material_input_provenance_unresolved"),
  "a buffer root cannot prove non-character material provenance")

storage = {}
local burner_entities = flow_fixture(false, true)
surface.find_entities_filtered = function(filter) if filter.type == "resource" then return {} end; return burner_entities end
game.tick = 1100
local burner_flow = summarize({})
check(not burner_flow.factory.material_flow.components[1].state.autonomy_topology_ready
  and table.concat(burner_flow.factory.material_flow.components[1].state.autonomy_blockers, ","):match("fuel_input_provenance_unresolved"),
  "finite hand-loaded burner fuel cannot prove autonomous fuel provenance")

-- A burner drill drops its mined output into a chest; a return inserter
-- feeds the chest back into the drill's fuel slot.
local function self_fed_fixture(ore)
local coal_drill = mock.entity({ valid = true, name = "burner-mining-drill", type = "mining-drill", position = { x = 1, y = 1 },
  force = force, status = 3, products_finished = 5, burner = {},
  prototype = { burner_prototype = { fuel_categories = { chemical = true } } } })
coal_drill.mining_target = mock.entity({ valid = true, name = ore, type = "resource", position = coal_drill.position, amount = 100,
  prototype = { mineable_properties = { products = { { name = ore, type = "item" } } } } })
local coal_chest = mock.entity({ valid = true, name = "wooden-chest", type = "container", position = { x = 5, y = 1 }, force = force, status = 3,
  get_inventory = function() return { get_contents = function() return { { name = ore, count = 10 } } end, is_full = function() return false end, can_insert = function() return true end } end })
local refuel = mock.entity({ valid = true, name = "refuel", type = "inserter", position = { x = 2, y = 2 }, force = force,
  status = 2, pickup_target = coal_chest, drop_target = coal_drill })
coal_drill.drop_target = coal_chest
storage = {}
local self_fed = { coal_drill, refuel, coal_chest }
surface.find_entities_filtered = function(filter) if filter.type == "resource" then return {} end; return self_fed end
local blockers = {}
for _, component in ipairs(summarize({}).factory.material_flow.components) do
  for _, blocker in ipairs(component.state.autonomy_blockers) do blockers[#blockers + 1] = blocker end
end
return table.concat(blockers, ",")
end
game.tick = 1150
check(not self_fed_fixture("coal"):match("fuel_input_provenance_unresolved"),
  "a burner drill refuelled from its own mined coal through a chest has physical fuel provenance")
check(self_fed_fixture("iron-ore"):match("fuel_input_provenance_unresolved") ~= nil,
  "the same loop returning a non-fuel product never proves fuel provenance")

-- More than both graph response caps, all in one physically connected component.
storage = {}
game.tick = 1200
local large, large_source, large_processor = flow_fixture(false, false)
large_source.position = { x = 0, y = 1 }
large_processor.position = { x = 28, y = 1 }
local large_sink, large_unload = large[5], large[4]
large_sink.position, large_unload.position = { x = 30, y = 1 }, { x = 29, y = 1 }
large = { large_source, large_processor, large_sink, large_unload }
for i = 1, 13 do
  large[#large + 1] = mock.entity({ valid = true, name = "feed-" .. i, type = "inserter", position = { x = i, y = 1 },
    force = force, status = 2, pickup_target = large_source, drop_target = large_processor })
end
large_source.drop_target = large[5]
surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or large end
local map = require("scripts.map_summary")
local large_summary = summarize({})
local large_component = large_summary.factory.material_flow.components[1]
check(#large_summary.factory.material_flow.nodes == 12 and #large_summary.factory.material_flow.edges == 24
  and large_summary.factory.omissions.capped_flow_nodes == 5 and large_summary.factory.omissions.capped_flow_edges == 5
  and large_component.node_count == 17 and large_component.edge_count == 29
  and large_component.state.autonomy_topology_ready,
  "full connected graph exceeding 12 nodes and 24 edges computes before presentation caps")
for i = 1, 20 do
  local target = { name = "unrelated-" .. i, type = "container", position = { x = i, y = 0 } }
  require("scripts.factory_activity").record("insert", { target = target, transfers = { { item = "ore", inserted = 1 } } })
end
require("scripts.factory_activity").record("insert", { target = large_processor, transfers = { { item = "ore", inserted = 1 } } })
local transfer_public = summarize({ activity_since_tick = 1200 })
check(#transfer_public.factory.character_transfers.target_actions == 16
  and transfer_public.factory.character_transfers.target_actions_omitted == 5
  and transfer_public.factory.material_flow.components[1].character_transfer_actions == 1,
  "component transfer counts use full internal attribution beyond the public target-row cap")

storage = {}; game.tick = 1300
local buffer_segment, buffer_source, buffer_processor = flow_fixture(false, false)
local buffer_sink = buffer_segment[5]
local buffer_stock, buffer_accepting = 0, true
buffer_sink.name, buffer_sink.type, buffer_sink.status = "wooden-chest", "container", 2
buffer_sink.get_inventory = function(index)
  assert(index == defines.inventory.chest)
  return { get_item_count = function(name) assert(name == "plate"); return buffer_stock end,
    can_insert = function(stack) assert(stack.name == "plate" and stack.count == 1); return buffer_accepting end }
end
defines.inventory = { chest = 1, lab_input = 2 }
surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or buffer_segment end
local buffer_summary = summarize({})
check(buffer_summary.factory.material_flow.components[1].state.downstream_kind == "buffer"
  and buffer_summary.factory.material_flow.components[1].state.autonomy_topology_ready
  and buffer_summary.factory.material_flow.components[1].state.autonomy_topology_ready,
  "buffer endpoints are explicit")
buffer_accepting = false
local full_buffer = summarize({ activity_since_tick = 1300 })
check(full_buffer.factory.material_flow.components[1].state.blocked_output
  and table.concat(full_buffer.factory.material_flow.components[1].state.autonomy_blockers, ","):match("blocked_output"),
  "a full or nonaccepting downstream buffer reports blocked_output")
check(not canonical(full_buffer):match("accepted_stock") and not canonical(full_buffer):match('"stock"')
  and not canonical(full_buffer):match('"_signature"'),
  "private stock and exact signature samples never leak into public summary evidence")

buffer_accepting = true
buffer_source.burner, buffer_processor.burner = {}, {}
buffer_processor.type, buffer_processor.name = "furnace", "stone-furnace"
local burner_prototype = { burner_prototype = { fuel_categories = { chemical = true } } }
buffer_source.prototype, buffer_processor.prototype = burner_prototype, burner_prototype
local coal_source = mock.entity({ valid = true, name = "coal-drill", type = "mining-drill", position = { x = 1, y = 3 }, force = force,
  status = 3, products_finished = 0, mining_target = mock.entity({ valid = true, name = "coal", type = "resource", position = { x = 1, y = 3 }, amount = 100, prototype = { mineable_properties = { products = { { name = "coal", type = "item" } } } } }) })
local fuel_feed = mock.entity({ valid = true, name = "fuel-feed", type = "inserter", position = { x = 2, y = 3 }, force = force,
  status = 3, pickup_target = coal_source, drop_target = buffer_source })
local furnace_fuel = mock.entity({ valid = true, name = "furnace-fuel", type = "inserter", position = { x = 3, y = 3 }, force = force,
  status = 3, pickup_target = coal_source, drop_target = buffer_processor })
coal_source.drop_target = fuel_feed
buffer_segment[6], buffer_segment[7], buffer_segment[8] = coal_source, fuel_feed, furnace_fuel
-- Offline reproduction of the reported ordinary five-coal replenishment limit.
-- Inventory capacity is larger than the inserter's normal replenishment target.
-- These exact runtime relationship stubs are not evidence from the live save.
defines.entity_status.waiting_for_space_in_destination = 5
defines.entity_status.full_output = 6
local fuel_count = 5
buffer_processor.status = 3
buffer_source.burner = { currently_burning = { name = prototypes.item.coal, quality = { name = "normal" } }, remaining_burning_fuel = 4 }
buffer_source.get_fuel_inventory = function() return {
  get_contents = function() return { { name = "coal", quality = "normal", count = fuel_count } } end,
  get_item_count = function(item) assert(item.name == "coal" and item.quality == "normal"); return fuel_count end,
  can_insert = function(item) assert(item.name == "coal" and item.quality == "normal" and item.count == 1); return true end,
} end
fuel_feed.held_stack = { valid_for_read = true, name = "coal", quality = { name = "normal" }, count = 1 }
fuel_feed.status = 5
local saturated = summarize({})
local saturation_component = saturated.factory.material_flow.components[1]
local saturation_node
for _, node in ipairs(saturated.factory.material_flow.nodes) do if node.name == "fuel-feed" then saturation_node = node end end
check(not saturation_component.state.blocked_output and saturation_component.state.autonomy_topology_ready
  and not canonical(saturation_component.state.autonomy_blockers):match("full_output")
  and not canonical(saturation_component.state.autonomy_blockers):match("downstream_inventory_blocked")
  and saturation_node.status == "full_output" and saturation_node.fuel_return_saturation.fuel == "coal"
  and canonical(saturated.factory.material_flow.diagnostics):match("proven_fuel_return_saturation"),
  "proven ordinary replenishment saturation clears all three blockers and preserves waiting status")
local string_burning = buffer_source.burner.currently_burning
buffer_source.burner.currently_burning = { name = { name = "coal", fuel_value = 4000000 }, quality = { name = "normal" } }
local object_saturated
for _, node in ipairs(summarize({}).factory.material_flow.nodes) do
  if node.name == "fuel-feed" then object_saturated = node.fuel_return_saturation end
end
check(object_saturated and object_saturated.fuel == "coal",
  "saturation reads the Factorio 2.0 prototype-object currently_burning shape")
buffer_source.burner.currently_burning = string_burning
local fuel_inventory = buffer_source.get_fuel_inventory
-- Without proof the wait stays a transient status sample: it never proves
-- blocked output or a topology blocker, and never earns the exemption.
local function rejects_saturation(label, mutate, restore)
  mutate()
  local summary = summarize({})
  local component = summary.factory.material_flow.components[1]
  local feed_id, feed_saturation, wait_class, wait_exempt
  for _, node in ipairs(summary.factory.material_flow.nodes) do
    if node.name == "fuel-feed" then feed_id, feed_saturation = node.id, node.fuel_return_saturation end
  end
  for _, row in ipairs(summary.factory.material_flow.diagnostics) do
    if row.node_id == feed_id and row.reason == "downstream_inventory_blocked" then wait_class, wait_exempt = row.class, row.nonblocking_reason end
  end
  check(feed_saturation == nil and wait_class == "transient" and wait_exempt == nil
    and not component.state.blocked_output
    and not canonical(component.state.autonomy_blockers):match("full_output")
    and not canonical(component.state.autonomy_blockers):match("downstream_inventory_blocked"), label)
  restore()
end
rejects_saturation("unavailable destination fuel inventory remains blocked",
  function() buffer_source.get_fuel_inventory = function() error("unsupported") end end,
  function() buffer_source.get_fuel_inventory = fuel_inventory end)
rejects_saturation("empty compatible fuel stock is not ordinary saturation",
  function() fuel_count = 0 end, function() fuel_count = 5 end)
rejects_saturation("physically full fuel inventory remains blocked",
  function() buffer_source.get_fuel_inventory = function() return {
    get_item_count = function() return 50 end, can_insert = function() return false end } end end,
  function() buffer_source.get_fuel_inventory = fuel_inventory end)
rejects_saturation("fuel-inventory acceptance of another quality does not prove the held fuel",
  function() fuel_feed.held_stack.quality.name = "uncommon" end,
  function() fuel_feed.held_stack.quality.name = "normal" end)
local processor_recipe = buffer_processor.get_recipe
fuel_feed.drop_target = buffer_processor
buffer_processor.status, buffer_processor.burner, buffer_processor.get_fuel_inventory = 3, buffer_source.burner, fuel_inventory
local furnace_saturated = summarize({})
local furnace_return
for _, node in ipairs(furnace_saturated.factory.material_flow.nodes) do
  if node.name == "fuel-feed" then furnace_return = node end
end
check(furnace_return.fuel_return_saturation and not furnace_saturated.factory.material_flow.components[1].state.blocked_output,
  "supported working furnace ingredients positively establish an unambiguous fuel destination")
fuel_feed.drop_target = buffer_source
buffer_processor.status, buffer_processor.burner, buffer_processor.get_fuel_inventory = 3, {}, nil
rejects_saturation("fuel also used as a recipe ingredient leaves the destination compartment ambiguous",
  function()
    fuel_feed.drop_target = buffer_processor
    buffer_processor.status, buffer_processor.burner, buffer_processor.get_fuel_inventory = 3, buffer_source.burner, fuel_inventory
    buffer_processor.get_recipe = function() return { name = "process-coal", ingredients = { { name = "coal", type = "item" } },
      products = { { name = "plate", type = "item" } } } end
  end,
  function()
    fuel_feed.drop_target = buffer_source
    buffer_processor.status, buffer_processor.burner, buffer_processor.get_fuel_inventory, buffer_processor.get_recipe = 3, {}, nil, processor_recipe
  end)
for _, case in ipairs({
  { "unavailable recipe", function() error("unsupported") end },
  { "unreadable ingredients", function() return setmetatable({ name = "process", products = { { name = "plate", type = "item" } } },
    { __index = function(_, key) if key == "ingredients" then error("unsupported") end end }) end },
  { "malformed ingredients", function() return { name = "process", ingredients = { false },
    products = { { name = "plate", type = "item" } } } end },
}) do
  rejects_saturation(case[1] .. " leaves fuel/material destination ambiguity unproven",
    function()
      fuel_feed.drop_target = buffer_processor
      buffer_processor.status, buffer_processor.burner, buffer_processor.get_fuel_inventory = 3, buffer_source.burner, fuel_inventory
      buffer_processor.get_recipe = case[2]
    end,
    function()
      fuel_feed.drop_target = buffer_source
      buffer_processor.status, buffer_processor.burner, buffer_processor.get_fuel_inventory, buffer_processor.get_recipe = 3, {}, nil, processor_recipe
    end)
end
local held_fuel = fuel_feed.held_stack
local empty_held = setmetatable({ valid_for_read = false }, {
  __index = function() error("empty stack identity is unreadable") end,
  __newindex = function() error("empty stack fields are read-only") end,
})
fuel_feed.held_stack = empty_held
local empty_wait = summarize({})
local empty_wait_node
for _, node in ipairs(empty_wait.factory.material_flow.nodes) do if node.name == "fuel-feed" then empty_wait_node = node end end
check(empty_wait.factory.material_flow.components[1].state.autonomy_topology_ready
  and empty_wait_node.status == "full_output"
  and empty_wait_node.fuel_return_saturation.identity_source == "burning_and_stocked_fuel",
  "empty held stack wait derives identity only from the supported burning and stocked pair")
fuel_feed.held_stack = held_fuel
for _, case in ipairs({
  { "unavailable stocked contents", function() error("unsupported") end },
  { "absent stocked contents", function() return {} end },
  { "contradictory stocked fuel", function() return { { name = "wood", quality = "normal", count = 5 } } end },
  { "contradictory stocked quality", function() return { { name = "coal", quality = "uncommon", count = 5 } } end },
  { "ambiguous stocked fuels", function() return { { name = "coal", quality = "normal", count = 5 },
      { name = "wood", quality = "normal", count = 5 } } end },
  { "ambiguous stocked qualities", function() return { { name = "coal", quality = "normal", count = 5 },
      { name = "coal", quality = "uncommon", count = 5 } } end },
}) do
  rejects_saturation("empty-stack " .. case[1] .. " remains blocked",
    function()
      fuel_feed.held_stack = empty_held
      buffer_source.get_fuel_inventory = function()
        local inventory = fuel_inventory(); inventory.get_contents = case[2]; return inventory
      end
    end,
    function() fuel_feed.held_stack = held_fuel; buffer_source.get_fuel_inventory = fuel_inventory end)
end
rejects_saturation("unreadable held-stack validity remains blocked",
  function() fuel_feed.held_stack = setmetatable({}, { __index = function() error("unsupported") end }) end,
  function() fuel_feed.held_stack = held_fuel end)
prototypes.item.incompatible = { name = "incompatible", fuel_value = 8, fuel_category = "nuclear" }
rejects_saturation("incompatible held fuel remains blocked",
  function() fuel_feed.held_stack.name = "incompatible" end,
  function() fuel_feed.held_stack.name = "coal" end)
local burning_fuel = buffer_source.burner.currently_burning
rejects_saturation("incompatible currently burning fuel remains blocked",
  function() buffer_source.burner.currently_burning = { name = prototypes.item.incompatible, quality = { name = "normal" } } end,
  function() buffer_source.burner.currently_burning = burning_fuel end)
rejects_saturation("missing currently burning fuel remains blocked",
  function() buffer_source.burner.currently_burning = nil end,
  function() buffer_source.burner.currently_burning = burning_fuel end)
rejects_saturation("unreadable currently burning fuel remains blocked",
  function()
    buffer_source.burner.currently_burning = nil
    mock.unreadable(buffer_source.burner, "currently_burning")
  end,
  function() mock.unreadable(buffer_source.burner, "currently_burning", false); buffer_source.burner.currently_burning = burning_fuel end)
rejects_saturation("unreadable burning item prototype remains blocked",
  function() buffer_source.burner.currently_burning = { name = setmetatable({}, {
    __index = function() error("unreadable item name") end }) } end,
  function() buffer_source.burner.currently_burning = burning_fuel end)
rejects_saturation("unresolved physical fuel provenance remains blocked",
  function() coal_source.mining_target.prototype.mineable_properties.products[1].name = "ore" end,
  function() coal_source.mining_target.prototype.mineable_properties.products[1].name = "coal" end)
rejects_saturation("missing pickup cannot be replaced by a machine-output edge",
  function() fuel_feed.pickup_target = nil end, function() fuel_feed.pickup_target = coal_source end)
rejects_saturation("unreadable pickup remains unproven despite a machine-output edge",
  function()
    fuel_feed.pickup_target = nil
    mock.unreadable(fuel_feed, "pickup_target")
  end,
  function() mock.unreadable(fuel_feed, "pickup_target", false); fuel_feed.pickup_target = coal_source end)
rejects_saturation("contradictory pickup cannot borrow fuel provenance from another incoming edge",
  function() fuel_feed.pickup_target = buffer_source end, function() fuel_feed.pickup_target = coal_source end)
rejects_saturation("ambiguous drop relationship remains blocked",
  function() fuel_feed.drop_target = nil end, function() fuel_feed.drop_target = buffer_source end)
rejects_saturation("generic full_output status is not a replenishment exemption",
  function() fuel_feed.status = 6 end, function() fuel_feed.status = 5 end)
rejects_saturation("nonoperating destination remains blocked",
  function() buffer_source.status = 4 end, function() buffer_source.status = 3 end)
rejects_saturation("no remaining burning energy is not supplied saturation",
  function() buffer_source.burner.remaining_burning_fuel = 0 end,
  function() buffer_source.burner.remaining_burning_fuel = 4 end)
-- A belt run ending at an inserter pickup is consumed there; only a run with
-- no consumer anywhere along it is a dead end, reported at its last tile.
local coal_belt = mock.entity({ valid = true, name = "transport-belt", type = "transport-belt", position = { x = 1, y = 4 },
  force = force, status = 2, belt_neighbours = { inputs = {}, outputs = {} } })
coal_source.drop_target, fuel_feed.pickup_target, furnace_fuel.pickup_target = coal_belt, coal_belt, coal_belt
buffer_segment[9] = coal_belt
-- Match the reported self-return binding as well as the useful furnace branch.
coal_source.burner, coal_source.prototype, coal_source.get_fuel_inventory = buffer_source.burner, burner_prototype, fuel_inventory
fuel_feed.drop_target = coal_source
local picked = summarize({})
check(not canonical(picked.factory.material_flow.diagnostics):match("belt_")
  and not canonical(picked.factory.material_flow.components[1].state.autonomy_blockers):match("belt_"),
  "exact drill-to-belt-to-fuel-inserter bindings ending at an inserter pickup are not a dead end")
fuel_feed.pickup_target, furnace_fuel.pickup_target = coal_source, coal_source
local dead_end = summarize({})
local dead_row, dead_node
for _, row in ipairs(dead_end.factory.material_flow.diagnostics) do
  if row.reason == "belt_dead_end_without_consumer" then dead_row = row end
end
for _, node in ipairs(dead_end.factory.material_flow.nodes) do if dead_row and node.id == dead_row.node_id then dead_node = node end end
local dead_component = component_at(coal_belt.position)
check(dead_row and dead_row.class == "structural" and dead_row.related_edge.kind == "belt_or_pickup"
  and dead_node.position.x == 1 and dead_node.position.y == 4 and dead_component and not dead_component.topology_ready
  and canonical(dead_component.blockers):match("relationship_diagnostic:belt_dead_end_without_consumer"),
  "a belt run with no consumer anywhere is a structural dead end located at its last tile")
coal_source.drop_target, fuel_feed.pickup_target, furnace_fuel.pickup_target = fuel_feed, coal_source, coal_source
buffer_segment[9] = nil
coal_source.burner, coal_source.prototype, coal_source.get_fuel_inventory = nil, nil, nil
fuel_feed.drop_target = buffer_source
fuel_feed.status = 3
do
  local shared_entities, shared_source = flow_fixture(false, false)
  shared_entities[#shared_entities + 1] = mock.entity({ valid = true, name = "shared-resource-drill", type = "mining-drill",
    force = force, status = 3, position = { x = 1, y = 2 }, mining_target = shared_source.mining_target,
    drop_target = shared_entities[2] })
  storage = {}
  surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or shared_entities end
  local shared = component_at(shared_source.position)
  check(shared and not shared.topology_ready and canonical(shared.blockers):match("shared_mining_target_production_ambiguous"),
    "two drills on one resource tile cannot each claim it as independent source evidence")
end
local previous_entities = surface.find_entities_filtered
-- Belt dead ends are decided per run after every exact edge exists: a pickup
-- anywhere along the run, an underground exit or a loader container counts.
local many_rows_fixture
do
  local function belt(x, y, kind)
    return mock.entity({ valid = true, name = kind or "transport-belt", type = kind or "transport-belt", force = force,
      position = { x = x, y = y }, status = 3, belt_neighbours = { inputs = {}, outputs = {} } })
  end
  local function link(a, b)
    a.belt_neighbours.outputs[#a.belt_neighbours.outputs + 1] = b
    b.belt_neighbours.inputs[#b.belt_neighbours.inputs + 1] = a
  end
  local function drill(x, y, drop)
    return mock.entity({ valid = true, name = "electric-mining-drill", type = "mining-drill", force = force, position = { x = x, y = y },
      status = 3, drop_target = drop, mining_target = mock.entity({ valid = true, name = "coal", type = "resource", position = { x = x, y = y },
        amount = 100, prototype = { mineable_properties = { products = { { name = "coal", type = "item" } } } } }) })
  end
  local function chest(x, y)
    return mock.entity({ valid = true, name = "wooden-chest", type = "container", force = force, position = { x = x, y = y }, status = 2,
      get_inventory = function() return { get_item_count = function() return 0 end, can_insert = function() return true end } end })
  end
  local function inserter(x, y, pickup, drop)
    return mock.entity({ valid = true, name = "inserter", type = "inserter", force = force, position = { x = x, y = y }, status = 3,
      pickup_target = pickup, drop_target = drop })
  end
  local function dead_ends(entities)
    storage = {}
    surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end
    local summary = summarize({})
    local positions, by_id = {}, {}
    for _, node in ipairs(summary.factory.material_flow.nodes) do by_id[node.id] = node.position end
    for _, row in ipairs(summary.factory.material_flow.diagnostics) do
      if row.reason == "belt_dead_end_without_consumer" then positions[#positions + 1] = by_id[row.node_id] end
    end
    return positions, summary.factory.material_flow.components[1].state, summary
  end

  local b1, b2, b3, sink = belt(1, 11), belt(2, 11), belt(3, 11), chest(2, 13)
  link(b1, b2); link(b2, b3)
  local mid_dead, mid_state = dead_ends({ drill(1, 10, b1), b1, b2, b3, inserter(2, 12, b2, sink), sink })
  check(#mid_dead == 0 and mid_state.autonomy_topology_ready,
    "a belt line picked up partway along is consumed although its last tile backs up")

  local u1, entrance, exit, u_end, u_sink = belt(1, 21), belt(2, 21, "underground-belt"), belt(5, 21, "underground-belt"), belt(6, 21), chest(6, 23)
  entrance.belt_to_ground_type, entrance.neighbours, exit.belt_to_ground_type = "input", exit, "output"
  link(u1, entrance); link(exit, u_end)
  local underground = { drill(1, 20, u1), u1, entrance, exit, u_end, inserter(6, 22, u_end, u_sink), u_sink }
  local under_dead, under_state = dead_ends(underground)
  check(#under_dead == 0 and under_state.autonomy_topology_ready and under_state.downstream_kind == "buffer",
    "an underground pair joins its entrance to its exit through LuaEntity.neighbours")
  entrance.neighbours = nil
  local split_dead = dead_ends(underground)
  check(#split_dead == 1 and split_dead[1].x == 2 and split_dead[1].y == 21,
    "an underground entrance without a readable exit is the dead end of its run")

  local l1, loader, l_sink = belt(1, 31), belt(2, 31, "loader-1x1"), chest(3, 31)
  loader.loader_type, loader.loader_container = "input", l_sink
  link(l1, loader)
  local loader_dead, loader_state = dead_ends({ drill(1, 30, l1), l1, loader, l_sink })
  check(#loader_dead == 0 and loader_state.autonomy_topology_ready and loader_state.downstream_kind == "buffer",
    "a loader feeding a container is the consumer edge of its belt run")

  local o_source, o_loader, o_belt, o_sink = chest(1, 15), belt(2, 15, "loader-1x1"), belt(3, 15), chest(3, 17)
  o_loader.loader_type, o_loader.loader_container = "output", o_source
  link(o_loader, o_belt)
  local output_dead, output_state, output_summary = dead_ends({ drill(1, 14, o_source), o_source, o_loader, o_belt,
    inserter(3, 16, o_belt, o_sink), o_sink })
  local ids, container_edge = {}, false
  for _, node in ipairs(output_summary.factory.material_flow.nodes) do ids[node.position.x .. "," .. node.position.y] = node.id end
  for _, edge in ipairs(output_summary.factory.material_flow.edges) do
    if edge.kind == "loader_container" and edge.from == ids["1,15"] and edge.to == ids["2,15"] then container_edge = true end
  end
  check(#output_dead == 0 and container_edge and output_state.autonomy_topology_ready and output_state.downstream_kind == "buffer",
    "an output loader takes from its container onto a run that an inserter consumes")

  -- Many located rows: thirteen inserters lift from a chest and drop nowhere.
  local hub = chest(1, 5)
  many_rows_fixture = { drill(1, 4, hub), hub }
  for x = 2, 14 do many_rows_fixture[#many_rows_fixture + 1] = inserter(x, 6, hub, nil) end
  local _, many_state = dead_ends(many_rows_fixture)
  check(#many_state.blocker_details == 3 and #many_state.autonomy_blockers >= 2,
    "a component with more than three blocker sites keeps three located details")

  local d1, d2 = belt(1, 26), belt(2, 26)
  link(d1, d2)
  local true_dead, dead_state = dead_ends({ drill(1, 25, d1), d1, d2 })
  local detail
  for _, row in ipairs(dead_state.blocker_details) do
    if row.reason == "relationship_diagnostic:belt_dead_end_without_consumer" then detail = row end
  end
  check(#true_dead == 1 and true_dead[1].x == 2 and true_dead[1].y == 26
    and detail and detail.position.x == 2 and detail.position.y == 26 and detail.class == "structural"
    and detail.entity == "transport-belt" and detail.related_edge.kind == "belt_or_pickup"
    and #dead_state.blocker_details <= 3 and dead_state.blocker_details[1].reason == "downstream_acceptance_path_unproven",
    "a run with no consumer is flagged once at its last tile and readiness rows lead the located details")
end

-- Readiness rows are located at the node where a repair starts.
do
  local function component_of(entities, position)
    storage = {}
    surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end
    return component_at(position)
  end
  local premature = flow_fixture(false, true)
  local refused = component_of(premature, premature[3].position)
  local first = refused.rows[1]
  check(not refused.topology_ready and first.reason == "fuel_input_provenance_unresolved" and first.class == "structural"
    and first.position.x == 3 and first.position.y == 1 and first.entity == "processor" and first.related_edge.kind == "fuel_input",
    "a burner segment without a fuel edge names the burner's position first")
  local open_ended = flow_fixture(false, false)
  local open = component_of({ open_ended[1], open_ended[2], open_ended[3] }, open_ended[3].position)
  check(not open.topology_ready and canonical(open.blockers):match("physical_source_downstream_path_unproven"),
    "a segment without a terminal buffer or consumer is not topology-ready")

  -- A lab with no research selected consumes nothing; a lab whose research
  -- needs a pack the line never supplies does not either.
  defines.entity_status.no_research_in_progress, defines.entity_status.missing_science_packs = 40, 41
  local idle_lab_line = flow_fixture(false, false)
  local idle_lab = idle_lab_line[5]
  idle_lab.status = defines.entity_status.no_research_in_progress
  local idle = component_of(idle_lab_line, idle_lab_line[3].position)
  check(not idle.topology_ready and idle.rows[1].reason == "consumer_idle_no_research" and idle.rows[1].class == "evidence"
    and idle.rows[1].position.x == idle_lab.position.x and idle.rows[1].entity == "lab",
    "a lab with no research in progress is named at the lab")
  local plate_research = { research_unit_ingredients = { { type = "item", name = "plate", amount = 1 } } }
  local two_pack_research = { research_unit_ingredients = { { type = "item", name = "plate", amount = 1 },
    { type = "item", name = "green-pack", amount = 1 } } }
  local function lab_blockers(status, research)
    force.current_research = research or plate_research
    local line = flow_fixture(false, false)
    line[5].status = status
    line[5].get_inventory = function(index)
      assert(index == defines.inventory.lab_input)
      return { can_insert = function(stack) return stack.name == "plate" end }
    end
    return canonical(component_of(line, line[5].position).blockers)
  end
  local waiting_blockers = lab_blockers(defines.entity_status.missing_science_packs)
  local unselected_blockers = lab_blockers(defines.entity_status.no_research_in_progress)
  local short_blockers = lab_blockers(defines.entity_status.missing_science_packs, two_pack_research)
  check(not waiting_blockers:match("consumer_idle_no_research") and unselected_blockers:match("consumer_idle_no_research")
    and short_blockers:match("consumer_missing_required_science_pack")
    and not waiting_blockers:match("consumer_missing_required_science_pack"),
    "only a lab without research is idle, and a lab missing a pack the line never supplies is named")
  -- An inserter relays the line's packs from one lab into the next: the
  -- chained lab is supplied through the first, working or waiting.
  local function lab_chain(status, research)
    force.current_research = research
    local line = flow_fixture(false, false)
    local first_lab = line[5]
    first_lab.status = status
    local second = mock.entity({ valid = true, name = "lab", type = "lab", position = { x = 7, y = 1 }, force = force, status = status,
      get_inventory = function() return { can_insert = function(stack) return stack.name == "plate" end } end })
    line[#line + 1] = mock.entity({ valid = true, name = "relay", type = "inserter", position = { x = 6, y = 1 }, force = force,
      status = 3, pickup_target = first_lab, drop_target = second })
    line[#line + 1] = second
    local component = component_of(line, first_lab.position)
    local missing = {}
    for _, row in ipairs(component.rows) do
      if row.reason == "consumer_missing_required_science_pack" then missing[#missing + 1] = row.position.x end
    end
    table.sort(missing)
    return table.concat(missing, ","), component.topology_ready
  end
  check(canonical({ lab_chain(3, plate_research) }) == '["",true]'
    and canonical({ lab_chain(defines.entity_status.missing_science_packs, plate_research) }) == '["",true]'
    and canonical({ lab_chain(3, two_pack_research) }) == '["5,7",false]',
    "a chained lab receives the line's packs through the first lab, working or waiting")
  force.current_research = nil
end

-- Replays of recorded material_flow graphs. Nodes are {name, type, x, y,
-- direction, normalized status}; edges are {from, to, kind} node indexes.
-- Status timing is simulated; the topology is what the live game reported.
do
  -- The recorded loop sits in a chunk this fixture force has not charted.
  local fixture_charted = force.is_chunk_charted
  force.is_chunk_charted = function() return true end
  local RAW_STATUS = { working = 3, idle = 2, insufficient_input = 8, full_output = 5, no_fuel = 4 }
  local function replay(recorded)
    local entities = {}
    for index, row in ipairs(recorded.nodes) do
      local entity = mock.entity({ valid = true, name = row[1], type = row[2], position = { x = row[3], y = row[4] },
        direction = row[5], status = RAW_STATUS[row[6]], force = force}, { stock = 0  })
      if entity.type == "transport-belt" then entity.belt_neighbours = { inputs = {}, outputs = {} } end
      if entity.type == "inserter" then entity.burner, entity.prototype = {}, burner_prototype end
      if entity.type == "container" then
        entity.get_inventory = function() return { get_item_count = function() return mock.state(entity).stock end,
          can_insert = function() return true end } end
      end
      if entity.type == "mining-drill" then
        entity.prototype, entity.mining_progress = burner_prototype, 0
        entity.mining_target = mock.entity({ valid = true, name = "coal", type = "resource", position = { x = row[3] - 0.5, y = row[4] + 0.5 },
          amount = 3838, prototype = { mineable_properties = { products = { { name = "coal", type = "item" } } } } })
        entity.burner = { remaining_burning_fuel = 8,
          currently_burning = { name = { name = "coal", fuel_value = 4000000 }, quality = { name = "normal" } } }
        mock.state(entity).fuel = 5
        entity.get_fuel_inventory = function() return { get_item_count = function() return mock.state(entity).fuel end,
          can_insert = function() return true end,
          get_contents = function() return mock.state(entity).fuel > 0 and { { name = "coal", quality = "normal", count = mock.state(entity).fuel } } or {} end } end
      end
      entities[index] = entity
    end
    for _, edge in ipairs(recorded.edges) do
      local from, to, kind = entities[edge[1]], entities[edge[2]], edge[3]
      if kind == "belt_direction" then
        from.belt_neighbours.outputs[#from.belt_neighbours.outputs + 1] = to
        to.belt_neighbours.inputs[#to.belt_neighbours.inputs + 1] = from
      elseif kind == "inserter_pickup" then to.pickup_target = from
      else from.drop_target = to end
    end
    return entities
  end
  -- One coal (fuel_value 8 here) burns for BURN ticks; each burn start draws
  -- an item from the fuel inventory.
  local BURN = 400
  local function burn(drill, elapsed, fuel)
    drill.burner.remaining_burning_fuel, mock.state(drill).fuel = 8 * (1 - (elapsed % BURN) / BURN), fuel
  end
  local function coal_loop(entities, drill, terminal, buffer, fuel_return)
    fuel_return.held_stack = { valid_for_read = true, name = "coal", quality = { name = "normal" }, count = 1 }
    return function(elapsed)
      local cycles = math.floor(elapsed / 120)
      drill.status, drill.mining_progress, drill.mining_target.amount = 3, (elapsed % 120) / 120, 3838 - cycles
      -- The fuel return refills each drawn coal a moment after the draw.
      burn(drill, elapsed, elapsed % BURN < 20 and 4 or 5)
      terminal.status = elapsed % 10 < 7 and 8 or 3
      fuel_return.status = elapsed % 10 < 8 and 5 or 3
      mock.state(buffer).stock = cycles
    end
  end
  local function replay_passes(label, recorded, drill, terminal, buffer, fuel_return)
    local entities = replay(recorded)
    coal_loop(entities, entities[drill], entities[terminal], entities[buffer], entities[fuel_return])(0)
    storage = {}
    surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end
    local component = component_at(entities[buffer].position)
    check(component.topology_ready and #component.blockers == 0 and not component.blocked_output,
      label .. " is topology-ready")
  end
  -- Cycle 5 plan 36 coal loop (material_flow at tick 88854). The live
  -- validator refused it at preflight with blocked_output, full_output and an
  -- end-belt orientation row at the tile the chest inserter picks up from.
  replay_passes("recorded cycle-5 plan-36 coal loop", {
    nodes = {
      { "wooden-chest", "container", 34.5, -59.5, 0, "idle" },
      { "burner-inserter", "inserter", 34.5, -58.5, 8, "insufficient_input" },
      { "transport-belt", "transport-belt", 34.5, -57.5, 0, "working" },
      { "burner-mining-drill", "mining-drill", 32, -57, 8, "working" },
      { "burner-inserter", "inserter", 33.5, -56.5, 4, "insufficient_input" },
      { "transport-belt", "transport-belt", 34.5, -56.5, 0, "working" },
      { "transport-belt", "transport-belt", 32.5, -55.5, 4, "working" },
      { "transport-belt", "transport-belt", 33.5, -55.5, 4, "working" },
      { "transport-belt", "transport-belt", 34.5, -55.5, 0, "working" },
    },
    edges = {
      { 2, 1, "inserter_drop" }, { 3, 2, "inserter_pickup" }, { 4, 7, "machine_output" }, { 5, 4, "inserter_drop" },
      { 6, 3, "belt_direction" }, { 6, 5, "inserter_pickup" }, { 7, 8, "belt_direction" }, { 8, 9, "belt_direction" },
      { 9, 6, "belt_direction" },
    },
  }, 4, 2, 1, 5)
  -- Continuation coal-return-buffer (material_flow snapshot at tick 152241,
  -- component signature d5d77a374040576b; 149331 is its last character
  -- transfer tick). The fuel pickup sits on the run's last tile, downstream of
  -- the surplus pickup: this layout is itself surplus-upstream-of-fuel and
  -- passes only because its scripted timeline keeps the drill refuelled.
  -- Topology-level surplus-before-fuel detection is deferred.
  replay_passes("recorded continuation coal-return-buffer", {
    nodes = {
      { "burner-mining-drill", "mining-drill", 32, -57, 8, "working" },
      { "burner-inserter", "inserter", 33.5, -56.5, 4, "full_output" },
      { "transport-belt", "transport-belt", 34.5, -56.5, 4, "working" },
      { "transport-belt", "transport-belt", 32.5, -55.5, 4, "working" },
      { "transport-belt", "transport-belt", 33.5, -55.5, 4, "working" },
      { "transport-belt", "transport-belt", 34.5, -55.5, 0, "working" },
      { "burner-inserter", "inserter", 35.5, -55.5, 12, "insufficient_input" },
      { "wooden-chest", "container", 36.5, -55.5, 0, "idle" },
    },
    edges = {
      { 5, 6, "belt_direction" }, { 6, 7, "inserter_pickup" }, { 6, 3, "belt_direction" }, { 7, 8, "inserter_drop" },
      { 1, 4, "machine_output" }, { 2, 1, "inserter_drop" }, { 3, 2, "inserter_pickup" }, { 4, 5, "belt_direction" },
    },
  }, 1, 7, 8, 2)
  -- Burner inserters refuel only from fuel they carry. The fuel row on one
  -- whose produced cargo is known and burns nowhere says so, so a plate
  -- carrier reads as needing its own fuel feed rather than a self-refuel
  -- refusal. Unknown cargo (a hand-stocked chest) keeps the bare row.
  local function iron_furnace(entity)
    entity.prototype, entity.burner = burner_prototype, {}
    entity.get_recipe = function() return { name = "iron-plate", energy = 3.2,
      ingredients = { { name = "iron-ore", type = "item" } }, products = { { name = "iron-plate", type = "item" } } } end
  end
  local function inserter_fuel_rows(recorded, inserter, setup)
    local entities = replay(recorded)
    if setup then setup(entities) end
    storage = {}
    surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end
    local position = entities[inserter].position
    local component = component_at(position)
    local rows = {}
    for _, row in ipairs(component.rows) do
      if row.position.x == position.x and row.position.y == position.y and row.reason:find("fuel", 1, true) then
        rows[#rows + 1] = row
      end
    end
    return rows, component
  end
  local plate_rows = inserter_fuel_rows({
    nodes = { { "stone-furnace", "furnace", 40, -50, 0, "working" },
      { "burner-inserter", "inserter", 40.5, -48.5, 0, "insufficient_input" },
      { "wooden-chest", "container", 40.5, -47.5, 0, "idle" } },
    edges = { { 1, 2, "inserter_pickup" }, { 2, 3, "inserter_drop" } },
  }, 2, function(entities) iron_furnace(entities[1]) end)
  check(#plate_rows == 1 and plate_rows[1].reason == "fuel_input_provenance_unresolved"
    and plate_rows[1].related_edge.kind == "fuel_input" and plate_rows[1].related_edge.transport_cargo_fuel == false,
    "a burner inserter carrying plates is blocked with exactly one fuel row marking its non-fuel cargo")
  check(#inserter_fuel_rows({
    nodes = { { "burner-mining-drill", "mining-drill", 50, -50, 8, "working" },
      { "transport-belt", "transport-belt", 50.5, -48.5, 4, "working" },
      { "burner-inserter", "inserter", 50.5, -47.5, 0, "insufficient_input" },
      { "wooden-chest", "container", 50.5, -46.5, 0, "idle" } },
    edges = { { 1, 2, "machine_output" }, { 2, 3, "inserter_pickup" }, { 3, 4, "inserter_drop" } },
  }, 3) == 0, "a burner inserter picking mined coal from a belt has proven fuel provenance")
  local chest_rows = inserter_fuel_rows({
    nodes = { { "wooden-chest", "container", 60.5, -50.5, 0, "idle" },
      { "burner-inserter", "inserter", 60.5, -49.5, 0, "insufficient_input" },
      { "wooden-chest", "container", 60.5, -48.5, 0, "idle" } },
    edges = { { 1, 2, "inserter_pickup" }, { 2, 3, "inserter_drop" } },
  }, 2)
  check(#chest_rows == 1 and chest_rows[1].reason == "fuel_input_provenance_unresolved"
    and chest_rows[1].related_edge.kind == "fuel_input" and chest_rows[1].related_edge.transport_cargo_fuel == nil,
    "a burner inserter fed from a hand-stocked chest stays blocked on unproven fuel supply")
  local mixed_rows = inserter_fuel_rows({
    nodes = { { "burner-mining-drill", "mining-drill", 70, -50, 8, "working" },
      { "transport-belt", "transport-belt", 70.5, -48.5, 4, "working" },
      { "stone-furnace", "furnace", 72, -48, 0, "working" },
      { "inserter", "inserter", 71.5, -48.5, 12, "working" },
      { "burner-inserter", "inserter", 70.5, -47.5, 0, "insufficient_input" },
      { "wooden-chest", "container", 70.5, -46.5, 0, "idle" } },
    edges = { { 1, 2, "machine_output" }, { 3, 4, "inserter_pickup" }, { 4, 2, "inserter_drop" },
      { 2, 5, "inserter_pickup" }, { 5, 6, "inserter_drop" } },
  }, 5, function(entities)
    iron_furnace(entities[3])
    entities[4].burner, entities[4].prototype = nil, {}
  end)
  check(#mixed_rows == 0, "a burner inserter on a belt mixing mined coal and plates has proven fuel provenance")
  -- A fresh drill binds drop_target only at its first output. With exactly
  -- one charted recipient under its drop position that is a pending binding
  -- (evidence), not the structural missing sink it is without one.
  local function fresh_drill(with_belt, recipient)
    local entities = replay({
      nodes = { { "burner-mining-drill", "mining-drill", 80, -50, 0, "working" },
        recipient or { "transport-belt", "transport-belt", 80.5, -51.5, 4, "working" } },
      edges = {},
    })
    local drill, belt = entities[1], entities[2]
    if recipient then belt.can_insert = function() return false end end
    drill.surface, drill.drop_position = surface, { x = 80.3, y = -51.3 }
    belt.bounding_box = { left_top = { x = 80.1, y = -51.9 }, right_bottom = { x = 80.9, y = -51.1 } }
    if not with_belt then belt.bounding_box = { left_top = { x = 81.1, y = -51.9 }, right_bottom = { x = 81.9, y = -51.1 } } end
    storage = {}
    surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end
    local component = component_at(drill.position)
    local names = {}
    for _, name in ipairs(component.blockers) do names[name] = true end
    return names, component
  end
  local pending, pending_component = fresh_drill(true)
  local pending_row = pending_component.rows[1]
  check(pending.drill_output_target_pending_first_output and pending_row.reason == "drill_output_target_pending_first_output"
    and pending_row.class == "evidence" and pending_row.related_edge.kind == "machine_output"
    and not pending["relationship_diagnostic:output_has_no_physical_sink"]
    and not pending.downstream_acceptance_path_unproven and not pending_component.topology_ready,
    "a fresh drill with a recipient at its drop position reports a pending first-output binding, still unready")
  local missing = fresh_drill(false)
  check(missing["relationship_diagnostic:output_has_no_physical_sink"] and missing.downstream_acceptance_path_unproven
    and not missing.drill_output_target_pending_first_output,
    "a drill with no recipient at its drop position keeps the structural missing-sink row")
  local refusing = fresh_drill(true, { "inserter", "inserter", 80.5, -51.5, 0, "waiting_for_source_items" })
  check(refusing["relationship_diagnostic:output_has_no_physical_sink"] and refusing.downstream_acceptance_path_unproven
    and not refusing.drill_output_target_pending_first_output,
    "a recipient at the drop position that cannot take the mined product is no pending binding")
  force.is_chunk_charted = fixture_charted
end
surface.find_entities_filtered = previous_entities

-- An independent predecessor oracle enumerates charted east/south boundaries.
-- Native tile objects are deliberately unavailable to the implementation.
local collision_layers = {
  land = {}, water = { water_tile = true }, player_only = { player = true },
  both = { water_tile = true, player = true }, legacy = { ["water-tile"] = true },
  unrelated = { object = true },
}
prototypes.tile = {}
for name, layers in pairs(collision_layers) do
  prototypes.tile[name] = { collision_mask = { layers = layers } }
end
local fixture_chunks, tile_name, reverse_results, tile_queries = {}, nil, false, 0
local function fixture_charted(x, y)
  for _, chunk in ipairs(fixture_chunks) do if chunk.x == x and chunk.y == y then return true end end
  return false
end
force.is_chunk_charted = function(_, chunk) return fixture_charted(chunk.x, chunk.y) end
surface.get_chunks = function()
  local index = 0
  return function() index = index + 1; return fixture_chunks[index] end
end
surface.get_tile = function() error("per-tile get_tile path must be absent") end
surface.find_entities_filtered = function(filter) return filter.type == "resource" and resources or { machine } end
surface.find_tiles_filtered = function(filter)
  tile_queries = tile_queries + 1
  local x0, y0 = filter.area[1][1], filter.area[1][2]
  assert(fixture_charted(math.floor(x0 / 32), math.floor(y0 / 32)), "uncharted query")
  -- A chunk is read in four strips of eight rows, so no tick reads more
  -- than 256 tiles.
  assert(filter.area[2][1] == x0 + 32 and filter.area[2][2] == y0 + 8 and y0 % 8 == 0, "chunk strip query extent")
  local names, tiles = {}, {}
  for _, name in ipairs(filter.name) do names[name] = true end
  for y = y0, y0 + 7 do
    for x = x0, x0 + 31 do
      if names[tile_name(x, y)] then tiles[#tiles + 1] = { position = { x = x, y = y } } end
    end
  end
  if reverse_results then
    for i = 1, math.floor(#tiles / 2) do tiles[i], tiles[#tiles + 1 - i] = tiles[#tiles + 1 - i], tiles[i] end
  end
  return tiles
end
local function predecessor_edges()
  local edges = {}
  local function water(x, y)
    local layers = collision_layers[tile_name(x, y)]
    return layers.water_tile or layers["water-tile"] or layers.player or false
  end
  for _, chunk in ipairs(fixture_chunks) do
    for y = chunk.y * 32, chunk.y * 32 + 31 do
      for x = chunk.x * 32, chunk.x * 32 + 31 do
        for _, delta in ipairs({ { 1, 0 }, { 0, 1 } }) do
          local nx, ny = x + delta[1], y + delta[2]
          if fixture_charted(math.floor(nx / 32), math.floor(ny / 32)) and water(x, y) ~= water(nx, ny) then
            edges[#edges + 1] = {
              land = water(x, y) and { x = nx, y = ny } or { x = x, y = y },
              water = water(x, y) and { x = x, y = y } or { x = nx, y = ny }, observed_tick = game.tick,
            }
          end
        end
      end
    end
  end
  table.sort(edges, function(a, b)
    if a.land.y ~= b.land.y then return a.land.y < b.land.y end
    if a.land.x ~= b.land.x then return a.land.x < b.land.x end
    if a.water.y ~= b.water.y then return a.water.y < b.water.y end
    return a.water.x < b.water.x
  end)
  local omitted = math.max(0, #edges - 256)
  while #edges > 256 do table.remove(edges) end
  return edges, omitted
end
local function equivalence_case(name, chunks, terrain)
  fixture_chunks, tile_name, reverse_results, tile_queries = chunks, terrain, false, 0
  local actual = summarize({ detail = "full" })
  local expected, omitted = predecessor_edges()
  check(canonical(actual.water_edges) == canonical(expected) and actual.omitted_water_edges == omitted,
    name .. " matches predecessor coordinates, ordering, cap and omissions")
  check(tile_queries == 4 * #chunks, name .. " uses exactly four strip tile queries per charted chunk")
  reverse_results, tile_queries = true, 0
  local shuffled = summarize({ detail = "full" })
  check(canonical(actual) == canonical(shuffled) and tile_queries == 4 * #chunks,
    name .. " has byte-identical complete output with shuffled tile results")
  tile_queries = 0
  local compact = summarize({ detail = "aggregate" })
  check(tile_queries == 0 and canonical(compact.factory) == canonical(actual.factory)
    and compact.summary == actual.summary, name .. " preserves aggregate with zero tile queries")
  return actual
end
local adjacent = { { x = 0, y = 1 }, { x = 1, y = 0 }, { x = 0, y = 0 } }
equivalence_case("adjacent charted east/south chunks", adjacent,
  function(x, y) return (x >= 32 or y >= 32) and "water" or "land" end)
equivalence_case("uncharted borders", { { x = 0, y = 0 } },
  function(x, y) return (x == 31 or y == 31 or x < 0 or y < 0) and "water" or "land" end)
equivalence_case("negative cross-chunk coordinates", { { x = -1, y = -1 }, { x = 0, y = -1 }, { x = -1, y = 0 } },
  function(x, y) return (x >= 0 or y >= 0) and "player_only" or "land" end)
equivalence_case("all land", adjacent, function() return "land" end)
equivalence_case("all water", adjacent, function() return "water" end)
local names = { "land", "water", "player_only", "both", "legacy", "unrelated" }
local dense_edges = equivalence_case("mixed collision masks and over 256 edges", adjacent,
  function(x, y) return names[(x + y) % #names + 1] end)
check(#dense_edges.water_edges == 256 and dense_edges.omitted_water_edges > 0, "dense fixture exercises edge cap")
local changed = equivalence_case("terrain changed in the same tick", adjacent, function() return "land" end)
check(#changed.water_edges == 0, "request-local classification reflects changed terrain immediately")
equivalence_case("charting changed in the same tick", { { x = 0, y = 0 }, { x = -1, y = 0 } },
  function(x) return x < 0 and "water" or "land" end)
local saved_prototypes = prototypes.tile
prototypes.tile = { land = saved_prototypes.land }
equivalence_case("empty matching name list", adjacent, function() return "land" end)
prototypes.tile = saved_prototypes
local source_file = assert(io.open(here .. "/../../mod/agentic-companion/scripts/map_summary.lua", "r"))
local source = source_file:read("*a"); source_file:close()
check(not source:find("get_tile", 1, true) and not source:find("collides_with", 1, true),
  "production shoreline scan contains no per-tile native calls")

-- Fluid identities and topology come from native source/prototype/connection
-- facts, independently of names, coordinates, recipes or preloaded contents.
do
  local previous_find, previous_fluids = surface.find_entities_filtered, prototypes.fluid
  prototypes.fluid = { aqua = { default_temperature = 15, heat_capacity = 200 },
    vapor = { default_temperature = 15, heat_capacity = 200 } }
  local function entity(kind, x, boxes, proto)
    local e = mock.entity({ valid = true, name = "opaque-" .. kind, type = kind, force = force, surface = surface,
      position = { x = x, y = 9 }, status = 3, unit_number = x, prototype = proto or {} })
    local links = {}
    e.fluidbox = {}
    for index, box in ipairs(boxes) do
      e.fluidbox[index] = box.fluid
      links[index] = {}
    end
    mock.length(e.fluidbox, function() return #boxes end)
    e.fluidbox.get_prototype = function(index) return boxes[index] end
    e.fluidbox.get_filter = function(index)
      local box = boxes[index]
      return box.filter and { name = box.filter.name, minimum_temperature = box.minimum_temperature or -100,
        maximum_temperature = box.maximum_temperature or 1000 }
    end
    e.fluidbox.get_capacity = function() return 100 end
    e.fluidbox.get_fluid_segment_id = function(index)
      if boxes[index].production_type ~= "output" then return x * 10 + index end
    end
    e.fluidbox.get_fluid_segment_contents = function(index)
      if boxes[index].production_type == "output" then return nil end
      local fluid = boxes[index].fluid
      return fluid and { [fluid.name] = fluid.amount } or {}
    end
    e.fluidbox.get_pipe_connections = function(index) return links[index] end
    return e, links
  end
  local source, sl = entity("offshore-pump", 1, { { production_type = "output", filter = { name = "aqua" } } })
  source.get_fluid_source_fluid = function() return "aqua" end
  local boiler, bl = entity("boiler", 2, {
    { production_type = "input", filter = { name = "aqua" } },
    { production_type = "output", filter = { name = "vapor" } } },
    { boiler_mode = "output-to-separate-pipe", target_temperature = 165 })
  local pipe, pl = entity("pipe-to-ground", 3, { { production_type = "none" } })
  local generator, gl = entity("generator", 5, { { production_type = "input", filter = { name = "vapor" } } },
    { burns_fluid = false, effectivity = 1, maximum_temperature = 165 })
  local function link(a, al, ai, b, bl, bi)
    al[ai][#al[ai] + 1] = { position = a.position, target_position = b.position, connection_type = "normal",
      flow_direction = "output", target = b.fluidbox, target_fluidbox_index = bi }
    bl[bi][#bl[bi] + 1] = { position = b.position, target_position = a.position, connection_type = "normal",
      flow_direction = "input", target = a.fluidbox, target_fluidbox_index = ai }
    a.fluidbox.owner, b.fluidbox.owner = a, b
  end
  link(source, sl, 1, boiler, bl, 1); link(boiler, bl, 2, pipe, pl, 1); link(pipe, pl, 1, generator, gl, 1)
  surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or { generator, pipe, boiler, source } end
  local summary = summarize({})
  local sample = component_at(boiler.position)
  check(#summary.factory.material_flow.edges == 3, "native connected fluidboxes create exact directed relationships including underground pipes")
  local output_edge
  for _, edge in ipairs(summary.factory.material_flow.edges) do
    if edge.from_fluidbox == 2 then output_edge = edge end
  end
  check(output_edge and output_edge.to_fluidbox == 1, "fluid relationships retain both box indices rather than entity adjacency")
  -- Positive native proof, so a silently refused fluidbox read fails here:
  -- every relationship is a fluid connection, the boiler names its steam
  -- product at its target temperature, and pump, boiler, pipe and engine
  -- form one component.
  local fluid_edges = 0
  for _, edge in ipairs(summary.factory.material_flow.edges) do
    if edge.kind == "fluid_connection" then fluid_edges = fluid_edges + 1 end
  end
  check(fluid_edges == 3 and #summary.factory.material_flow.components == 1
    and summary.factory.material_flow.components[1].node_count == 4
    and not canonical(summary.factory.material_flow.diagnostics):find("fluid_native_evidence_unproven", 1, true),
    "boiler, pipe and engine join one native fluid component with a boiler steam product")
  -- A recipe-merged box reads back as an array of prototypes: unsupported.
  local boiler_prototype = boiler.fluidbox.get_prototype
  boiler.fluidbox.get_prototype = function(index) return { boiler_prototype(1), boiler_prototype(2) } end
  local merged = summarize({})
  check(canonical(merged.factory.material_flow.diagnostics):find("fluid_native_evidence_unproven", 1, true) ~= nil
    and #merged.factory.material_flow.edges < 3,
    "a merged fluidbox prototype array stays unsupported native evidence")
  boiler.fluidbox.get_prototype = boiler_prototype
  check(not canonical(sample.blockers):find("output_identity_unproven", 1, true),
    "empty native offshore and boiler boxes still establish product identity without recipes or stock")
  local native = require("scripts.fluid_connections")
  local boiler_boxes, generator_boxes = native.sample(boiler), native.sample(generator)
  check(boiler_boxes[1].filter == "aqua" and boiler_boxes[1].production_type == "input"
    and boiler_boxes[2].filter == "vapor" and boiler_boxes[2].production_type == "output"
    and generator_boxes[1].filter == "vapor" and generator_boxes[1].production_type == "input",
    "LuaFluidBox prototypes establish boiler input/output and generator input identities on empty boxes")
  check(boiler_boxes[1].minimum_temperature == -100 and boiler_boxes[2].maximum_temperature == 1000,
    "native fluid samples preserve runtime filter temperature constraints")
  check(native.sample(source)[1].segment == nil and native.sample(source)[1].segment_amount == nil
    and boiler_boxes[2].segment == nil and boiler_boxes[2].segment_amount == nil and boiler_boxes[1].segment ~= nil,
    "successful nil output segment reads retain native absence without inventing zero stock or IDs")
  local segment_id, segment_contents = boiler.fluidbox.get_fluid_segment_id, boiler.fluidbox.get_fluid_segment_contents
  for _, case in ipairs({
    { label = "failed ID read", id = function() error("native read failed") end },
    { label = "failed contents read", contents = function() error("native read failed") end },
    { label = "malformed ID", id = function() return "segment" end },
    { label = "numeric ID with nil contents", id = function() return 42 end },
    { label = "nil ID with table contents", contents = function() return {} end },
    { label = "nil input segment", id = function() return nil end, contents = function() return nil end },
  }) do
    boiler.fluidbox.get_fluid_segment_id = case.id or segment_id
    boiler.fluidbox.get_fluid_segment_contents = case.contents or segment_contents
    check(native.sample(boiler) == nil, case.label .. " refuses native sampling rather than treating it as output absence")
    local refused = component_at(boiler.position)
    check(not refused.topology_ready, case.label .. " cannot establish native readiness")
  end
  boiler.fluidbox.get_fluid_segment_id, boiler.fluidbox.get_fluid_segment_contents = segment_id, segment_contents
  local get_prototype = boiler.fluidbox.get_prototype
  local bad_prototypes = {
    { label = "merged prototype array", get = function(index) return { get_prototype(index), get_prototype(index) } end },
    { label = "single-member prototype array", get = function(index) return { get_prototype(index) } end },
    { label = "missing prototype", get = function() return nil end },
    { label = "empty prototype array", get = function() return {} end },
    { label = "unreadable prototype", get = function() error("native read failed") end },
    { label = "unreadable prototype field", get = function()
      return setmetatable({}, { __index = function() error("native field read failed") end })
    end },
  }
  for _, case in ipairs(bad_prototypes) do
    boiler.fluidbox.get_prototype = case.get
    local endpoints, complete = native.live(boiler, true)
    check(native.sample(boiler) == nil and not complete and endpoints[1].filter == nil
      and endpoints[1].production_type == nil, case.label .. " refuses sample and endpoint identity")
    local refused = summarize({})
    check(#refused.factory.material_flow.edges == 1
      and canonical(refused.factory.material_flow.diagnostics):find("fluid_native_evidence_unproven", 1, true),
      case.label .. " never creates boiler topology from connected endpoints")
    check(canonical(component_at(boiler.position).blockers)
      :find("output_identity_unproven", 1, true) ~= nil, case.label .. " leaves boiler products unproven")
  end
  boiler.fluidbox.get_prototype = get_prototype
  check(not canonical(summary):find("_fluid_boxes", 1, true) and not canonical(summary):find("_target_entity", 1, true),
    "private fluid samples and runtime entity references never escape map summary")
  local signature = sample.component_signature
  boiler.prototype.target_temperature = 170
  check(component_at(boiler.position).component_signature ~= signature,
    "exact fluid component identity includes boiler output temperature")
  boiler.prototype.target_temperature = 165
  local old_force = generator.force
  generator.force = foreign_force
  local excluded = summarize({})
  check(canonical(excluded.factory.material_flow.diagnostics):find("fluid_connected_target_unproven", 1, true) ~= nil,
    "native connected foreign-force target remains unproven")
  generator.force = old_force
  gl[1], pl[1] = {}, {}
  check(#summarize({}).factory.material_flow.edges == 2, "disconnected pipe targets never become edges through proximity")
  surface.find_entities_filtered, prototypes.fluid = previous_find, previous_fluids
end

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
end
run()
