local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
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
  { valid = true, name = "iron-ore", type = "resource", amount = 20, position = { x = 8, y = 1 } },
  { valid = true, name = "iron-ore", type = "resource", amount = 10, position = { x = 3, y = 1 } },
  { valid = true, name = "copper-ore", type = "resource", amount = 999, position = { x = 33, y = 1 } },
}
local force = {
  is_chunk_charted = function(_, chunk) return chunk.x == 0 and chunk.y == 0 end,
  is_chunk_visible = function(_, chunk) return chunk.x == 0 and chunk.y == 0 end,
  get_item_production_statistics = function() return { get_flow_count = function(params)
    return params.category == "input" and 2 or 3
  end } end,
  get_fluid_production_statistics = function() return { get_flow_count = function() return 0 end } end,
}
local machine = { valid = true, name = "assembling-machine-1", type = "assembling-machine", position = { x = 5, y = 5 }, direction = 4, status = 1, force = force,
  crafting_speed = 1, get_inventory = function() error("aggregate must not inspect remote inventory") end,
  get_recipe = function() return { name = "gear", energy = 0.5,
    ingredients = { { name = "iron", type = "item" } }, products = { { name = "gear", type = "item" } } } end }
local foreign_force = {}
local foreign_machine = { valid = true, name = "foreign-machine", type = "assembling-machine",
  position = { x = 6, y = 5 }, force = foreign_force, status = 1 }
local invalid_machine = { valid = false, name = "invalid-machine", type = "furnace", position = { x = 7, y = 5 }, force = force }
local body = { valid = true, name = "character", type = "character", position = { x = 0, y = 0 }, force = force }
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
package.loaded["scripts.companion"] = { require_companion = function() return body end }
_G.prototypes = { tile = {
  land = { collision_mask = { layers = {} } },
  water = { collision_mask = { layers = { water_tile = true, player = true } } },
} }
_G.game = { tick = 777 }
_G.storage = {}
_G.defines = { entity_status = { no_power = 1 }, flow_precision_index = { one_minute = 1 } }
local summary = require("scripts.map_summary").map_summary({ detail = "full" })
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
local aggregate = require("scripts.map_summary").map_summary({})
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
  and not aggregate.factory.material_flow.components[1].state.autonomous_end_to_end,
  "machine presence, local operation, and end-to-end autonomy remain distinct")
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

local dense = {}
for i = 1, 70 do
  dense[i] = { valid = true, name = string.format("machine-%02d", i), type = "assembling-machine",
    position = { x = (i % 28) + 0.1, y = math.floor(i / 28) + 10.1 }, force = force, status = 1,
    crafting_speed = 1, get_recipe = function() return { name = string.format("recipe-%02d", i), energy = 1,
      ingredients = {}, products = { { name = string.format("product-%02d", i), type = "item" } } } end }
end
surface.find_entities_filtered = function(filter) if filter.type == "resource" then return {} end; return dense end
local bounded = require("scripts.map_summary").map_summary({})
check(#bounded.factory.groups == 12 and bounded.factory.omissions.capped_groups == 58
  and #bounded.factory.material_flow.nodes == 12 and bounded.factory.omissions.capped_flow_nodes == 58
  and #bounded.factory.force_flows == 12 and bounded.factory.omissions.capped_flows == 58
  and bounded.factory.partial,
  "factory groups, graph nodes, and flow rows have deterministic caps and omission counts")
local bounded_full = require("scripts.map_summary").map_summary({ detail = "full" })
local aggregate_bytes, full_bytes = #canonical(bounded), #canonical(bounded_full)
check(aggregate_bytes <= 18000 and aggregate_bytes * 5 < full_bytes * 4,
  "bounded aggregate stays at or below 18k fixture bytes and at least 20% smaller than full detail (aggregate="
    .. aggregate_bytes .. ", full=" .. full_bytes .. ")")

-- A component qualifies only after exact topology and a bounded unattended
-- production interval. Recipe/source identities prove material provenance;
-- buffers and finite hand-loaded burner stock never serve as roots.
local function flow_fixture(buffer_root, burner)
  local source = { valid = true, name = buffer_root and "wooden-chest" or "electric-mining-drill",
    type = buffer_root and "container" or "mining-drill", position = { x = 1, y = 1 }, force = force,
    status = 3, products_finished = 5 }
  if not buffer_root then source.mining_target = { valid = true, name = "ore", type = "resource", position = source.position, amount = 100, prototype = { mineable_properties = {
    products = { { name = "ore", type = "item" } },
  } } } end
  local processor = { valid = true, name = "processor", type = "assembling-machine",
    position = { x = 3, y = 1 }, force = force, status = 2, products_finished = 10,
    burner = burner and {} or nil, crafting_speed = 1,
    get_recipe = function() return { name = "process", energy = 1,
      ingredients = { { name = "ore", type = "item" } }, products = { { name = "plate", type = "item" } } } end }
  if burner then processor.prototype = { burner_prototype = { fuel_categories = { chemical = true } } } end
  local sink = { valid = true, name = "lab", type = "lab", position = { x = 5, y = 1 }, force = force, status = 3, get_inventory = function() return {
      can_insert = function(stack) return stack.name == "plate" end,
    } end }
  local feed = { valid = true, name = "feed", type = "inserter", position = { x = 2, y = 1 }, force = force,
    status = 2, pickup_target = source, drop_target = processor }
  local unload = { valid = true, name = "unload", type = "inserter", position = { x = 4, y = 1 }, force = force,
    status = 2, pickup_target = processor, drop_target = sink }
  if not buffer_root then source.drop_target = feed end
  return { source, feed, processor, unload, sink }, source, processor
end

prototypes.item = { coal = { fuel_value = 8, fuel_category = "chemical" } }
defines.entity_status.normal = 2
defines.entity_status.working = 3
defines.inventory = { lab_input = 2 }
storage = {}
local flow_entities, flow_source, flow_processor = flow_fixture(false, false)
surface.find_entities_filtered = function(filter) if filter.type == "resource" then return {} end; return flow_entities end
game.tick = 900
local ready = require("scripts.map_summary").map_summary({})
local ready_component = ready.factory.material_flow.components[1]
check(ready_component.state.autonomy_topology_ready and not ready_component.state.autonomous_end_to_end
  and ready_component.state.autonomy_evidence == "bounded_multi_tick_production_not_yet_proven",
  "complete material provenance and downstream path still require bounded production evidence")
local sample = require("scripts.map_summary").factory_component_sample({ source_tick = 900,
  positions = { { x = flow_source.position.x, y = flow_source.position.y },
    { x = flow_processor.position.x, y = flow_processor.position.y } } })
require("scripts.factory_activity").record_validation({ proven = true, component_signature = sample.component_signature,
  start_tick = 901, end_tick = 960, duration_ticks = 59, products_finished_delta = 3, downstream_kind = "consumer", downstream_acceptance_samples = 3, source_cycles_observed = 3,
  character_transfer_actions = 0 }, sample._signature)
game.tick = 960
local proven = require("scripts.map_summary").map_summary({ activity_since_tick = 900 })
check(proven.factory.material_flow.components[1].state.autonomous_end_to_end
  and proven.factory.material_flow.components[1].state.validation.products_finished_delta == 3,
  "matching bounded multi-tick validation promotes the unchanged component to autonomous end to end")
storage.factory_activity.events[#storage.factory_activity.events + 1] = {
  tick = 900, action = "insert", item_count = 1, target = {
    name = flow_processor.name, type = flow_processor.type, position = flow_processor.position,
  }, items = { { name = "ore", count = 1 } },
}
local bootstrapped = require("scripts.map_summary").map_summary({ activity_since_tick = 900 })
check(bootstrapped.factory.material_flow.components[1].state.autonomous_end_to_end,
  "a proven interval can sunset earlier bootstrap transfers without calling a hand-fed loop autonomous")
-- Produce the transfer through real build-plan placement and starter insertion.
package.loaded["scripts.companion"].get = function() return body end
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end, ensure_entity = function() return "ok" end }
prototypes.item.processor = { place_result = { name = "processor", type = "assembling-machine" } }
prototypes.item.ore = { name = "ore" }
defines.build_check_type = { manual = 1 }
body.build_distance = 6
local starter_stock = { processor = 1, ore = 2 }
body.get_item_count = function(name) return starter_stock[name] or 0 end
body.remove_item = function(stack) starter_stock[stack.name] = starter_stock[stack.name] - stack.count end
surface.can_place_entity = function() return true end
surface.create_entity = function() return flow_processor end
flow_processor.insert = function(stack) return stack.count end
local build_plan = require("scripts.actions.build_plan")
local starter_plan = { steps = { { item = "processor", position = flow_processor.position, insert = { ore = 2 } } } }
build_plan.start(starter_plan)
local starter_result = build_plan.tick(starter_plan)
check(starter_result.status == "done" and starter_stock.processor == 0 and starter_stock.ore == 0,
  "offline build-plan fixture commits placement and conserved starter insertion")
local touched = require("scripts.map_summary").map_summary({ activity_since_tick = 900 })
check(not touched.factory.material_flow.components[1].state.autonomous_end_to_end
  and touched.factory.material_flow.components[1].state.autonomy_evidence == "character_transfer_observed",
  "a later character transfer revokes unattended autonomy for that component")
local transfers = touched.factory.character_transfers
check(transfers.transfer_actions == 2 and transfers.transferred_items == 3
  and transfers.inserted_items[1].name == "ore" and transfers.inserted_items[1].count == 3
  and transfers.target_actions[1].transfer_actions == 2
  and transfers.target_actions[1].target.name == flow_processor.name
  and transfers.target_actions[1].target.type == flow_processor.type
  and transfers.target_actions[1].target.position.x == flow_processor.position.x
  and transfers.target_actions[1].last_transfer_tick == 960 and transfers.history_complete,
  "map summary includes build-plan accepted items and exact target actions in the requested interval")
local touched_sample = require("scripts.map_summary").factory_component_sample({ source_tick = 960,
  positions = { flow_processor.position } })
check(touched_sample.character_transfer_actions == 1 and touched_sample.character_history_complete,
  "component evidence includes build-plan transfer at the assessed interval boundary")
game.tick = 961
check(require("scripts.map_summary").map_summary({ activity_since_tick = 961 }).factory.character_transfers.transfer_actions == 0,
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
local buffered = require("scripts.map_summary").map_summary({})
check(not buffered.factory.material_flow.components[1].state.autonomy_topology_ready
  and table.concat(buffered.factory.material_flow.components[1].state.autonomy_blockers, ","):match("material_input_provenance_unresolved"),
  "a buffer root cannot prove non-character material provenance")

storage = {}
local burner_entities = flow_fixture(false, true)
surface.find_entities_filtered = function(filter) if filter.type == "resource" then return {} end; return burner_entities end
game.tick = 1100
local burner_flow = require("scripts.map_summary").map_summary({})
check(not burner_flow.factory.material_flow.components[1].state.autonomy_topology_ready
  and table.concat(burner_flow.factory.material_flow.components[1].state.autonomy_blockers, ","):match("fuel_input_provenance_unresolved"),
  "finite hand-loaded burner fuel cannot prove autonomous fuel provenance")

-- A burner drill drops its mined output into a chest; a return inserter
-- feeds the chest back into the drill's fuel slot.
local function self_fed_fixture(ore)
local coal_drill = { valid = true, name = "burner-mining-drill", type = "mining-drill", position = { x = 1, y = 1 },
  force = force, status = 3, products_finished = 5, burner = {},
  prototype = { burner_prototype = { fuel_categories = { chemical = true } } } }
coal_drill.mining_target = { valid = true, name = ore, type = "resource", position = coal_drill.position, amount = 100,
  prototype = { mineable_properties = { products = { { name = ore, type = "item" } } } } }
local coal_chest = { valid = true, name = "wooden-chest", type = "container", position = { x = 5, y = 1 }, force = force, status = 3,
  get_inventory = function() return { get_contents = function() return { { name = ore, count = 10 } } end, is_full = function() return false end, can_insert = function() return true end } end }
local refuel = { valid = true, name = "refuel", type = "inserter", position = { x = 2, y = 2 }, force = force,
  status = 2, pickup_target = coal_chest, drop_target = coal_drill }
coal_drill.drop_target = coal_chest
storage = {}
local self_fed = { coal_drill, refuel, coal_chest }
surface.find_entities_filtered = function(filter) if filter.type == "resource" then return {} end; return self_fed end
local blockers = {}
for _, component in ipairs(require("scripts.map_summary").map_summary({}).factory.material_flow.components) do
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
  large[#large + 1] = { valid = true, name = "feed-" .. i, type = "inserter", position = { x = i, y = 1 },
    force = force, status = 2, pickup_target = large_source, drop_target = large_processor }
end
large_source.drop_target = large[5]
surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or large end
local map = require("scripts.map_summary")
local large_summary = map.map_summary({})
local large_component = large_summary.factory.material_flow.components[1]
check(#large_summary.factory.material_flow.nodes == 12 and #large_summary.factory.material_flow.edges == 24
  and large_summary.factory.omissions.capped_flow_nodes == 5 and large_summary.factory.omissions.capped_flow_edges == 5
  and large_component.node_count == 17 and large_component.edge_count == 29
  and large_component.state.autonomy_topology_ready,
  "full connected graph exceeding 12 nodes and 24 edges computes before presentation caps")
local large_sample = map.factory_component_sample({ source_tick = 1200, positions = { large_processor.position, large_sink.position } })
check(large_sample.topology_ready and #large_sample.selected_node_ids == 2
  and large_sample.products_finished_total == 15 and large_sample.graph_omissions.nodes == 5,
  "exact component sampling selects nodes beyond the serialized cap and uses complete counters")
local original_signature = large_sample.component_signature
for _, row in ipairs(dense) do large[#large + 1] = row end
local unrelated = map.factory_component_sample({ source_tick = 1200, positions = { large_sink.position } })
check(unrelated.topology_ready and unrelated.component_signature == original_signature
  and unrelated.graph_omissions.nodes == 75,
  "unrelated components affect presentation omissions without invalidating selected evidence")
local before_rewire = unrelated._signature
large[6].drop_target = large_sink
local rewired = map.factory_component_sample({ source_tick = 1200, positions = { large_sink.position } })
check(rewired._signature ~= before_rewire and rewired.component_signature ~= original_signature,
  "changed physical relationships change the complete component signature even with identical node positions")
large[6].drop_target = large_processor
local ok_missing, missing = pcall(map.factory_component_sample, { source_tick = 1200, positions = { { x = 31, y = 31 } } })
local ok_split, split = pcall(map.factory_component_sample, { source_tick = 1200, positions = { large_sink.position, dense[1].position } })
local duplicate = { valid = true, name = "overlap", type = "container", position = large_sink.position, force = force, status = 2 }
large[#large + 1] = duplicate
local ok_ambiguous, ambiguous = pcall(map.factory_component_sample, { source_tick = 1200, positions = { large_sink.position } })
table.remove(large)
check(not ok_missing and missing:match("FACTORY_COMPONENT_TARGET_NOT_FOUND") and not ok_split and split:match("FACTORY_COMPONENT_SPLIT")
  and not ok_ambiguous and ambiguous:match("FACTORY_COMPONENT_TARGET_AMBIGUOUS"),
  "full-graph sampling preserves structured missing, split and ambiguous failures")
local too_many = {}; for i = 1, 17 do too_many[i] = large_sink.position end
check(not pcall(map.factory_component_sample, { source_tick = 1200, positions = {} })
  and not pcall(map.factory_component_sample, { source_tick = 1200, positions = too_many }),
  "component sampling retains the 1-16 position bound")
for i = 1, 20 do
  local target = { name = "unrelated-" .. i, type = "container", position = { x = i, y = 0 } }
  require("scripts.factory_activity").record("insert", { target = target, transfers = { { item = "ore", inserted = 1 } } })
end
require("scripts.factory_activity").record("insert", { target = large_processor, transfers = { { item = "ore", inserted = 1 } } })
local transfer_sample = map.factory_component_sample({ source_tick = 1200, positions = { large_sink.position } })
local transfer_public = map.map_summary({ activity_since_tick = 1200 })
check(transfer_sample.character_transfer_actions == 1 and transfer_sample.character_history_complete
  and not transfer_sample.topology_ready and #transfer_public.factory.character_transfers.target_actions == 16
  and transfer_public.factory.character_transfers.target_actions_omitted == 5,
  "full internal target attribution catches transfers beyond the public target-row cap")

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
local buffer_summary = map.map_summary({})
check(buffer_summary.factory.material_flow.components[1].state.downstream_kind == "buffer"
  and buffer_summary.factory.material_flow.components[1].state.autonomy_topology_ready
  and not buffer_summary.factory.material_flow.components[1].state.autonomous_end_to_end,
  "buffer endpoints are explicit and capacity alone cannot prove unattended acceptance")
local buffer_sample = map.factory_component_sample({ source_tick = 1300, positions = { buffer_processor.position } })
require("scripts.factory_activity").record_validation({ proven = true, component_signature = buffer_sample.component_signature,
  start_tick = 1300, end_tick = 1360, duration_ticks = 60, products_finished_delta = 3,
  downstream_kind = "buffer", downstream_acceptance_samples = 3, source_cycles_observed = 3, character_transfer_actions = 0 }, buffer_sample._signature)
game.tick = 1360
check(map.map_summary({ activity_since_tick = 1300 }).factory.material_flow.components[1].state.autonomous_end_to_end,
  "a matching bounded unattended buffer acceptance proof promotes the segment")
buffer_accepting = false
local full_buffer = map.map_summary({ activity_since_tick = 1300 })
check(full_buffer.factory.material_flow.components[1].state.blocked_output
  and not full_buffer.factory.material_flow.components[1].state.autonomous_end_to_end
  and table.concat(full_buffer.factory.material_flow.components[1].state.autonomy_blockers, ","):match("blocked_output"),
  "a full or nonaccepting downstream buffer revokes current autonomy with blocked_output")
check(not canonical(full_buffer):match("accepted_stock") and not canonical(full_buffer):match('"stock"')
  and not canonical(full_buffer):match('"_signature"'),
  "private stock and exact signature samples never leak into public summary evidence")

-- Exercise the real parked validator against the real graph, using simulated
-- production/ordinary inventory arrivals. This is offline stub evidence only.
package.loaded["scripts.companion"].get = function() return body end
-- Physical action runners are unused by these parked validation plans.
for _, action in ipairs({ "walk", "mine", "pickup", "craft", "build_plan" }) do
  package.loaded["scripts.actions." .. action] = {}
end
package.loaded["scripts.actions.build"] = { place = {}, rotate = {}, set_recipe = {} }
package.loaded["scripts.actions.transfer"] = { insert = {}, extract = {} }
local tasks = require("scripts.tasks")
buffer_accepting = true
buffer_source.burner, buffer_processor.burner = {}, {}
buffer_processor.type, buffer_processor.name = "furnace", "stone-furnace"
local burner_prototype = { burner_prototype = { fuel_categories = { chemical = true } } }
buffer_source.prototype, buffer_processor.prototype = burner_prototype, burner_prototype
local coal_source = { valid = true, name = "coal-drill", type = "mining-drill", position = { x = 1, y = 3 }, force = force,
  status = 3, products_finished = 0, mining_target = { valid = true, name = "coal", type = "resource", position = { x = 1, y = 3 }, amount = 100, prototype = { mineable_properties = { products = { { name = "coal", type = "item" } } } } } }
local fuel_feed = { valid = true, name = "fuel-feed", type = "inserter", position = { x = 2, y = 3 }, force = force,
  status = 3, pickup_target = coal_source, drop_target = buffer_source }
local furnace_fuel = { valid = true, name = "furnace-fuel", type = "inserter", position = { x = 3, y = 3 }, force = force,
  status = 3, pickup_target = coal_source, drop_target = buffer_processor }
coal_source.drop_target = fuel_feed
buffer_segment[6], buffer_segment[7], buffer_segment[8] = coal_source, fuel_feed, furnace_fuel
-- Offline reproduction of the reported ordinary five-coal replenishment limit.
-- Inventory capacity is larger than the inserter's normal replenishment target.
-- These exact runtime relationship stubs are not evidence from the live save.
defines.entity_status.waiting_for_space_in_destination = 5
defines.entity_status.full_output = 6
local fuel_count = 5
buffer_processor.status = 3
buffer_source.burner = { currently_burning = { name = "coal", quality = "normal" }, remaining_burning_fuel = 4 }
buffer_source.get_fuel_inventory = function() return {
  get_item_count = function(item) assert(item.name == "coal" and item.quality == "normal"); return fuel_count end,
  can_insert = function(item) assert(item.name == "coal" and item.quality == "normal" and item.count == 1); return true end,
} end
fuel_feed.held_stack = { valid_for_read = true, name = "coal", quality = { name = "normal" }, count = 1 }
fuel_feed.status = 5
local saturated = map.map_summary({})
local saturation_component = saturated.factory.material_flow.components[1]
local saturation_node
for _, node in ipairs(saturated.factory.material_flow.nodes) do if node.name == "fuel-feed" then saturation_node = node end end
check(not saturation_component.state.blocked_output and saturation_component.state.autonomy_topology_ready
  and not saturation_component.state.autonomous_end_to_end
  and not canonical(saturation_component.state.autonomy_blockers):match("full_output")
  and not canonical(saturation_component.state.autonomy_blockers):match("downstream_inventory_blocked")
  and saturation_node.status == "full_output" and saturation_node.fuel_return_saturation.fuel == "coal"
  and canonical(saturated.factory.material_flow.diagnostics):match("proven_fuel_return_saturation"),
  "proven ordinary replenishment saturation clears all three blockers, preserves waiting status and does not establish autonomy")
local fuel_inventory = buffer_source.get_fuel_inventory
local function rejects_saturation(label, mutate, restore)
  mutate()
  local component = map.map_summary({}).factory.material_flow.components[1]
  check(component.state.blocked_output and not component.state.autonomy_topology_ready
    and canonical(component.state.autonomy_blockers):match("nonproductive_status:full_output")
    and canonical(component.state.autonomy_blockers):match("relationship_diagnostic:downstream_inventory_blocked"), label)
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
local furnace_saturated = map.map_summary({})
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
rejects_saturation("unresolved held fuel identity remains blocked",
  function() fuel_feed.held_stack.valid_for_read = false end,
  function() fuel_feed.held_stack.valid_for_read = true end)
prototypes.item.incompatible = { fuel_value = 8, fuel_category = "nuclear" }
rejects_saturation("incompatible held fuel remains blocked",
  function() fuel_feed.held_stack.name = "incompatible" end,
  function() fuel_feed.held_stack.name = "coal" end)
rejects_saturation("unresolved physical fuel provenance remains blocked",
  function() coal_source.mining_target.prototype.mineable_properties.products[1].name = "ore" end,
  function() coal_source.mining_target.prototype.mineable_properties.products[1].name = "coal" end)
rejects_saturation("missing pickup cannot be replaced by a machine-output edge",
  function() fuel_feed.pickup_target = nil end, function() fuel_feed.pickup_target = coal_source end)
rejects_saturation("unreadable pickup remains unproven despite a machine-output edge",
  function()
    fuel_feed.pickup_target = nil
    setmetatable(fuel_feed, { __index = function(_, key) if key == "pickup_target" then error("unsupported") end end })
  end,
  function() setmetatable(fuel_feed, nil); fuel_feed.pickup_target = coal_source end)
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
-- A real reported end-belt diagnostic must remain effective independently
-- of the now-proven replenishment branch.
local coal_belt = { valid = true, name = "transport-belt", type = "transport-belt", position = { x = 1, y = 4 },
  force = force, status = 2, belt_neighbours = { inputs = {}, outputs = {} } }
coal_source.drop_target, fuel_feed.pickup_target, furnace_fuel.pickup_target = coal_belt, coal_belt, coal_belt
buffer_segment[9] = coal_belt
-- Match the reported self-return binding as well as the useful furnace branch.
coal_source.burner, coal_source.prototype, coal_source.get_fuel_inventory = buffer_source.burner, burner_prototype, fuel_inventory
fuel_feed.drop_target = coal_source
local oriented = map.map_summary({}).factory.material_flow.components[1]
check(not oriented.state.blocked_output and not oriented.state.autonomy_topology_ready
  and canonical(oriented.state.autonomy_blockers):match("belt_orientation_does_not_reach_consumer"),
  "exact drill-to-belt-to-fuel-inserter bindings preserve the independent end-belt orientation blocker")
coal_source.drop_target, fuel_feed.pickup_target, furnace_fuel.pickup_target = fuel_feed, coal_source, coal_source
buffer_segment[9] = nil
coal_source.burner, coal_source.prototype, coal_source.get_fuel_inventory = nil, nil, nil
fuel_feed.drop_target = buffer_source
fuel_feed.status = 3
local bypass_stock = 0
local function simulate_validation(mode)
  game.tick = game.tick + 100
  local start = game.tick
  storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
  buffer_accepting, buffer_stock, buffer_processor.products_finished = true, 0, 10
  buffer_source.status, buffer_processor.status = 3, 3
  fuel_feed.status = (mode == "saturated" or mode == "replenish" or mode == "ambiguous_return"
    or mode == "incompatible_return" or mode == "blocked_output") and 5 or 3
  fuel_feed.held_stack.name = mode == "incompatible_return" and "incompatible" or "coal"
  buffer_source.get_fuel_inventory = mode == "ambiguous_return" and function() error("unsupported") end or fuel_inventory
  buffer_segment[4].status = mode == "blocked_output" and 6 or 3
  buffer_source.mining_progress, coal_source.mining_progress = 0.9, 0.9
  map.map_summary({}) -- establish the run-local epoch before source_tick
  local queued = tasks.queue_plan({ observation_detail = "none", steps = { { action = "validate_factory_component",
    source_tick = start, positions = { buffer_sink.position }, duration_seconds = 1 } } })
  game.tick = start + 1; tasks.on_tick()
  for i = 1, 3 do
    game.tick = start + 1 + i * 20
    if mode ~= "no_source_production" then
      buffer_source.mining_progress, coal_source.mining_progress = 0.9 - i * 0.1, 0.9 - i * 0.1
      buffer_source.mining_target.amount = buffer_source.mining_target.amount - 1
      coal_source.mining_target.amount = coal_source.mining_target.amount - 1
    end
    if mode ~= "no_production" then buffer_processor.products_finished = buffer_processor.products_finished + 1 end
    if mode ~= "no_acceptance" and mode ~= "wrong_product" then buffer_stock = buffer_stock + 1 end
    if mode == "wrong_product" then bypass_stock = bypass_stock + 1 end
    if mode == "blocked" and i == 2 then buffer_accepting = false end
    if mode == "no_fuel" and i == 2 then buffer_processor.status = 4 end
    if mode == "replenish" then
      fuel_feed.status = i == 2 and 3 or 5
      fuel_count = i == 2 and 4 or 5
    end
    if mode == "transfer" and i == 2 then
      require("scripts.factory_activity").record("insert", { target = buffer_processor, transfers = { { item = "ore", inserted = 1 } } })
    end
    tasks.on_tick()
  end
  return tasks.plan_status({ plan_id = queued.plan_id })
end
defines.entity_status.no_fuel = 4
local accepted_buffer = simulate_validation("accept")
check(accepted_buffer.status == "completed" and accepted_buffer.outcomes[1].result.downstream_kind == "buffer"
  and accepted_buffer.outcomes[1].result.downstream_acceptance_samples == 3
  and map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
  "real graph and validator prove supplied burner drill-furnace-chest acceptance across three unattended cycles")
local saturated_interval = simulate_validation("saturated")
check(saturated_interval.status == "completed" and map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
  "parked validator permits proven saturated fuel replenishment only with independent multi-tick production and acceptance")
local replenished_interval = simulate_validation("replenish")
check(replenished_interval.status == "completed",
  "offline replenishment resumes after fuel consumption and returns to ordinary saturation without changing topology")
for _, mode in ipairs({ "ambiguous_return", "incompatible_return", "blocked_output" }) do
  local rejected = simulate_validation(mode)
  check(rejected.status == "failed" and rejected.outcomes[1].result.blocked_output,
    "parked validator rejects " .. mode .. " despite a productive material path")
end
simulate_validation("accept") -- restore the ordinary productive fixture
local regular_inventory = buffer_sink.get_inventory
buffer_sink.get_inventory = function() return {
  get_item_count = function(name) return name == "ore" and bypass_stock or buffer_stock end,
  can_insert = function() return true end,
} end
local bypass = { valid = true, name = "bypass", type = "inserter", position = { x = 6, y = 1 }, force = force,
  status = 3, pickup_target = buffer_source, drop_target = buffer_sink }
buffer_segment[9] = bypass
local wrong_output = simulate_validation("wrong_product")
check(wrong_output.status == "failed" and canonical(wrong_output.outcomes[1].result.blockers):match("bounded_downstream_acceptance_not_observed"),
  "raw source arrivals into a shared buffer cannot prove acceptance of absent processor output")
buffer_segment[9], buffer_sink.get_inventory = nil, regular_inventory
local middle_chest = { valid = true, name = "middle-chest", type = "container", position = { x = 4, y = 2 }, force = force, status = 2,
  get_inventory = function() return { get_item_count = function() return 0 end, can_insert = function() return true end } end }
local relay = { valid = true, name = "relay", type = "inserter", position = { x = 5, y = 2 }, force = force, status = 3,
  pickup_target = middle_chest, drop_target = buffer_sink }
buffer_segment[4].drop_target, buffer_segment[9], buffer_segment[10] = middle_chest, middle_chest, relay
local relayed_output = simulate_validation("accept")
check(relayed_output.status == "completed" and relayed_output.outcomes[1].result.downstream_kind == "buffer",
  "ordinary intermediate buffers transport proven upstream product identities without becoming production roots")
middle_chest.get_inventory = function() return { get_item_count = function() return 10 end, can_insert = function() return false end } end
local blocked_middle = simulate_validation("accept")
check(blocked_middle.status == "failed" and blocked_middle.outcomes[1].result.blocked_output,
  "a full intermediate downstream buffer also blocks current autonomy")
buffer_segment[4].drop_target, buffer_segment[9], buffer_segment[10] = buffer_sink, nil, nil
local stationary_sources = simulate_validation("no_source_production")
check(stationary_sources.status == "failed" and canonical(stationary_sources.outcomes[1].result.blockers):match("several_source_cycles_not_observed"),
  "processor cycles from accumulated inputs cannot replace later physical source production")
local stationary_buffer = simulate_validation("no_acceptance")
check(stationary_buffer.status == "failed" and canonical(stationary_buffer.outcomes[1].result.blockers):match("bounded_downstream_acceptance_not_observed"),
  "buffer presence and producer cycles cannot replace measured ordinary downstream arrivals")
local no_production = simulate_validation("no_production")
check(no_production.status == "failed" and canonical(no_production.outcomes[1].result.blockers):match("bounded_production_delta_not_observed"),
  "downstream stock changes cannot replace later processor production evidence")
local blocked_interval = simulate_validation("blocked")
check(blocked_interval.status == "failed" and blocked_interval.outcomes[1].result.blocked_output,
  "a nonaccepting buffer during the unattended interval prevents validation")
local interrupted_fuel = simulate_validation("no_fuel")
check(interrupted_fuel.status == "failed" and canonical(interrupted_fuel.outcomes[1].result.blockers):match("nonproductive_status:no_fuel"),
  "fuel interruption during the interval fails continuous supplied operation")
local transferred_interval = simulate_validation("transfer")
check(transferred_interval.status == "failed" and canonical(transferred_interval.outcomes[1].result.blockers):match("character_transfer_observed"),
  "a character transfer during the real unattended interval invalidates acceptance")
check(not canonical(accepted_buffer):match('"stock"') and not canonical(accepted_buffer):match('"_signature"')
  and not canonical(map.map_summary({})):match('"_signature"'),
  "public validation and retained history expose no private stock samples or exact identity strings")

-- A period dividing the nominal 30-tick interval must not stay phase-locked.
storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
game.tick = 3000
buffer_accepting, buffer_processor.status, buffer_source.status = true, 3, 3
buffer_stock, buffer_source.mining_progress, coal_source.mining_progress = 0, 0, 0
buffer_source.mining_target.amount, coal_source.mining_target.amount = 1000, 1000
map.map_summary({})
local alias_plan = tasks.queue_plan({ observation_detail = "none", steps = { { action = "validate_factory_component",
  source_tick = 3000, positions = { buffer_sink.position }, duration_seconds = 6 } } })
for tick = 3001, 3361 do
  game.tick = tick
  local elapsed = tick - 3001
  buffer_source.mining_progress, coal_source.mining_progress = (elapsed % 30) / 30, (elapsed % 30) / 30
  buffer_source.mining_target.amount, coal_source.mining_target.amount = 1000 - math.floor(elapsed / 30), 1000 - math.floor(elapsed / 30)
  buffer_processor.products_finished, buffer_stock = 10 + math.floor(elapsed / 30), math.floor(elapsed / 30)
  tasks.on_tick()
end
local alias_result = tasks.plan_status({ plan_id = alias_plan.plan_id })
check(alias_result.status == "completed" and alias_result.outcomes[1].result.source_cycles_observed >= 3,
  "adjacent sampling intervals prove productive drills whose mining period divides the nominal cadence")
storage = {}; game.tick = game.tick + 100
local extra = {}
for i = 1, 40 do
  extra[#extra + 1] = { valid = true, name = "unconnected-belt-" .. i, type = "transport-belt", force = force, status = 2,
    position = { x = (i % 25) + 0.1, y = math.floor(i / 25) * 0.1 }, belt_neighbours = { inputs = {}, outputs = {} } }
end
for _, row in ipairs(buffer_segment) do extra[#extra + 1] = row end
buffer_source.status, buffer_processor.status, buffer_accepting = 3, 3, true
surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or extra end
local omitted_diagnostics = map.map_summary({})
local complete_sample = map.factory_component_sample({ source_tick = game.tick, positions = { buffer_sink.position } })
local serialized_component = false
for _, row in ipairs(omitted_diagnostics.factory.material_flow.components) do
  if row.component_id == complete_sample.component_id then serialized_component = true end
end
check(omitted_diagnostics.factory.omissions.capped_edge_diagnostics == 16 and complete_sample.topology_ready
  and not serialized_component and #omitted_diagnostics.factory.material_flow.diagnostics == 24,
  "unrelated diagnostic and component omissions never remove selected full-graph evidence")
local duplicate_drill = { valid = true, name = "shared-resource-drill", type = "mining-drill", force = force, status = 3,
  position = { x = 7, y = 2 }, mining_target = buffer_source.mining_target, mining_progress = 0.5, drop_target = buffer_segment[2] }
extra[#extra + 1] = duplicate_drill
local shared_target = map.factory_component_sample({ source_tick = game.tick, positions = { buffer_sink.position } })
check(not shared_target.topology_ready and canonical(shared_target.blockers):match("shared_mining_target_production_ambiguous"),
  "shared resource depletion cannot be attributed to one drill as independent source evidence")
-- Source-only proof uses the same real graph, parked sampler and transfer ledger.
-- Exact runtime bindings are simulated; no fixture is live autonomy evidence.
local previous_entities = surface.find_entities_filtered
local function source_only_validation(mode)
  game.tick = game.tick + 100
  local start = game.tick
  storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
  local stock, accepting = 0, true
  local target = { valid = true, name = "coal", type = "resource", position = { x = 1, y = 4 }, amount = 100,
    prototype = { mineable_properties = { products = { { name = "coal", type = "item" } } } } }
  local source = { valid = true, name = "source-only-drill", type = "mining-drill", force = force,
    position = { x = 1, y = 4 }, status = 3, mining_target = target, mining_progress = 0.9,
    prototype = burner_prototype, burner = { currently_burning = { name = "coal" }, remaining_burning_fuel = 4 },
    get_fuel_inventory = function() return {
      get_item_count = function() return 5 end, can_insert = function() return true end,
    } end }
  local middle = { valid = true, name = "source-relay-chest", type = "container", force = force,
    position = { x = 2, y = 4 }, status = 2, get_inventory = function() return {
      get_item_count = function() return 10 end, can_insert = function() return true end,
    } end }
  local sink = { valid = true, name = "source-terminal-chest", type = "container", force = force,
    position = { x = 4, y = 4 }, status = 2, get_inventory = function() return {
      get_item_count = function() return stock end, can_insert = function() return accepting end,
    } end }
  local unload = { valid = true, name = "source-unload", type = "inserter", force = force,
    position = { x = 3, y = 4 }, status = 3, pickup_target = middle, drop_target = sink }
  local refill = { valid = true, name = "source-self-return", type = "inserter", force = force,
    position = { x = 2, y = 5 }, status = 5, pickup_target = middle, drop_target = source,
    held_stack = { valid_for_read = true, name = "coal", quality = { name = "normal" }, count = 1 } }
  source.drop_target = middle
  local entities = { source, middle, unload, sink, refill }
  if mode == "electric" then
    source.burner, source.prototype = nil, nil
    entities[5] = nil
  elseif mode == "starter_only" then entities[5] = nil
  elseif mode == "missing_return" then refill.drop_target = nil
  elseif mode == "wrong_return" then refill.drop_target = sink
  elseif mode == "missing_pickup" then refill.pickup_target = nil
  elseif mode == "stock_root" then source.drop_target = sink; unload.pickup_target = source
  elseif mode == "transformed_return" then
    middle.type = "assembling-machine"
    middle.get_recipe = function() return { name = "transform-coal", ingredients = { { name = "coal", type = "item" } },
      products = { { name = "plate", type = "item" } } } end
  elseif mode == "no_energy" then source.burner.remaining_burning_fuel = 0
  elseif mode == "incompatible_fuel" then refill.held_stack.name = "incompatible"
  elseif mode == "full_fuel" then source.get_fuel_inventory = function() return {
    get_item_count = function() return 5 end, can_insert = function() return false end,
  } end
  elseif mode == "unsupported_fuel" then source.get_fuel_inventory = function() error("unsupported") end
  elseif mode == "generic_full" then refill.status = 6
  elseif mode == "shared_target" then
    entities[6] = { valid = true, name = "other-source", type = "mining-drill", force = force,
      position = { x = 1, y = 5 }, status = 3, mining_target = target, mining_progress = 0.9, drop_target = middle }
  elseif mode == "orientation" then
    local belt = { valid = true, name = "unrepaired-terminal", type = "transport-belt", force = force,
      position = { x = 2, y = 6 }, status = 3, belt_neighbours = { inputs = {}, outputs = {} } }
    source.drop_target, unload.pickup_target, refill.pickup_target = belt, belt, belt
    entities[2] = belt
  end
  if mode == "consumer" or mode == "consumer_wrong_output" or mode == "consumer_multi_output" or mode == "consumer_full"
    or mode == "consumer_interruption" or mode == "consumer_unavailable" then
    sink.type, sink.name, sink.status = "burner-generator", "source-consumer", 3
    sink.prototype, sink.burner = burner_prototype, { currently_burning = { name = "coal" }, remaining_burning_fuel = 4 }
    sink.get_fuel_inventory = function() return {
      can_insert = function(stack) return stack.name == "coal" and mode ~= "consumer_full" and accepting end,
    } end
    if mode == "consumer_unavailable" then sink.get_fuel_inventory = function() error("unsupported") end end
    if mode == "consumer_wrong_output" then
      sink.type, sink.name, sink.burner, sink.prototype = "lab", "incompatible-science-consumer", nil, nil
      sink.get_inventory = function(index)
        assert(index == defines.inventory.lab_input)
        return { can_insert = function(stack) return stack.name == "automation-science-pack" end }
      end
    elseif mode == "consumer_multi_output" then
      target.prototype.mineable_properties.products[2] = { name = "ore", type = "item" }
    end
  end
  if mode == "unavailable" then source.mining_progress = nil end
  if mode == "unavailable_target" then source.mining_target = nil end
  if mode == "unsupported_buffer" then sink.get_inventory = function() error("unsupported") end end
  surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end
  map.map_summary({}) -- open complete run-local transfer history
  if mode == "incomplete_history" then
    storage.factory_activity.events_omitted, storage.factory_activity.latest_evicted_tick = 1, start + 1
  end
  local queued = tasks.queue_plan({ observation_detail = "none", steps = { { action = "validate_factory_component",
    source_tick = start, positions = { sink.position }, duration_seconds = 1 } } })
  game.tick = start + 1; tasks.on_tick()
  local preflight = map.factory_component_sample({ source_tick = game.tick, positions = { sink.position } })
  for i = 1, 3 do
    game.tick = start + 1 + i * 20
    if mode ~= "unavailable" and mode ~= "aliased" then source.mining_progress = 0.9 - i * 0.1 end
    if mode ~= "no_depletion" then target.amount = target.amount - 1 end
    if mode ~= "stagnant" then stock = stock + 1 end
    if i == 2 then
      if mode == "full_buffer" or mode == "consumer_interruption" then accepting = false end
      if mode == "fuel_interruption" then source.status = 4 end
      if mode == "power_interruption" then source.status = 1 end
      if mode == "topology" then unload.direction = 2 end
      if mode == "target_change" then target.position = { x = 1, y = 6 } end
      if mode == "transfer" then
        require("scripts.factory_activity").record("insert", { target = middle, transfers = { { item = "coal", inserted = 1 } } })
      end
    end
    tasks.on_tick()
  end
  return tasks.plan_status({ plan_id = queued.plan_id }), preflight, map.map_summary({})
end
for _, mode in ipairs({ "self_return", "electric", "consumer" }) do
  local result, preflight, final = source_only_validation(mode)
  check(preflight.topology_ready and next(preflight._production) == nil and result.status == "completed"
    and result.outcomes[1].result.products_finished_delta == 0
    and result.outcomes[1].result.source_cycles_observed == 3
    and result.outcomes[1].result.downstream_acceptance_samples == 3
    and final.factory.material_flow.components[1].state.autonomous_end_to_end,
    "source-only " .. mode .. " proves three unattended source cycles and endpoint samples with no processor production")
  check(not canonical(result):match('"stock"') and not canonical(result):match('"remaining"')
    and not canonical(final):match('"resource_key"') and not canonical(final):match('"_signature"'),
    "source-only " .. mode .. " exposes no private inventory, resource samples or exact signatures")
end
for _, case in ipairs({
  { "consumer_wrong_output", "blocked_output" },
  { "consumer_multi_output", "blocked_output" }, { "consumer_full", "blocked_output" },
  { "consumer_interruption", "blocked_output" },
  { "consumer_unavailable", "downstream_consumer_acceptance_unproven" },
  { "starter_only", "fuel_input_provenance_unresolved" },
  { "missing_return", "fuel_input_provenance_unresolved" },
  { "wrong_return", "fuel_input_provenance_unresolved" },
  { "missing_pickup", "fuel_input_provenance_unresolved" },
  { "stock_root", "fuel_input_provenance_unresolved" },
  { "transformed_return", "fuel_input_provenance_unresolved" },
  { "no_energy", "blocked_output" }, { "incompatible_fuel", "blocked_output" },
  { "full_fuel", "blocked_output" }, { "unsupported_fuel", "blocked_output" },
  { "generic_full", "blocked_output" },
  { "unavailable", "several_source_cycles_not_observed" },
  { "unavailable_target", "output_identity_unproven" },
  { "aliased", "several_source_cycles_not_observed" },
  { "no_depletion", "several_source_cycles_not_observed" },
  { "shared_target", "shared_mining_target_production_ambiguous" },
  { "stagnant", "bounded_downstream_acceptance_not_observed" },
  { "full_buffer", "blocked_output" }, { "unsupported_buffer", "downstream_buffer_acceptance_unproven" },
  { "fuel_interruption", "nonproductive_status:no_fuel" },
  { "power_interruption", "missing_power" },
  { "topology", "component_topology_changed_during_validation" },
  { "target_change", "several_source_cycles_not_observed" },
  { "transfer", "character_transfer_observed" },
  { "incomplete_history", "character_transfer_history_incomplete" },
  { "orientation", "belt_orientation_does_not_reach_consumer" },
}) do
  local result = source_only_validation(case[1])
  check(result.status == "failed" and canonical(result.outcomes[1].result.blockers):match(case[2]),
    "source-only rejects " .. case[1] .. " with " .. case[2])
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
  assert(filter.area[2][1] == x0 + 32 and filter.area[2][2] == y0 + 32, "chunk query extent")
  local names, tiles = {}, {}
  for _, name in ipairs(filter.name) do names[name] = true end
  for y = y0, y0 + 31 do
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
  local actual = require("scripts.map_summary").map_summary({ detail = "full" })
  local expected, omitted = predecessor_edges()
  check(canonical(actual.water_edges) == canonical(expected) and actual.omitted_water_edges == omitted,
    name .. " matches predecessor coordinates, ordering, cap and omissions")
  check(tile_queries == #chunks, name .. " uses exactly one tile query per charted chunk")
  reverse_results, tile_queries = true, 0
  local shuffled = require("scripts.map_summary").map_summary({ detail = "full" })
  check(canonical(actual) == canonical(shuffled) and tile_queries == #chunks,
    name .. " has byte-identical complete output with shuffled tile results")
  tile_queries = 0
  local compact = require("scripts.map_summary").map_summary({ detail = "aggregate" })
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

os.exit(failures == 0 and 0 or 1)
