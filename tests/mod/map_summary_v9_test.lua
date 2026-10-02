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
package.loaded["scripts.companion"] = { require_companion = function() return body end,
  -- The real dependency-free burner reader, not a stub of it.
  burning_item = dofile(here .. "/../../mod/agentic-companion/scripts/companion.lua").burning_item }
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

prototypes.item = { coal = { name = "coal", fuel_value = 8, fuel_category = "chemical" } }
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
do
  local saved_storage = storage
  local activity, map = require("scripts.factory_activity"), require("scripts.map_summary")
  local function record(target)
    activity.record("insert", { target = target, transfers = { { item = "ore", inserted = 1 } } })
  end
  local function prove(component_sample, start_tick)
    activity.record_validation({ proven = true, component_signature = component_sample.component_signature,
      start_tick = start_tick, end_tick = 960, duration_ticks = 960 - start_tick,
      products_finished_delta = 3, downstream_kind = "consumer", downstream_acceptance_samples = 3,
      source_cycles_observed = 3, character_transfer_actions = 0 }, component_sample._signature)
  end
  storage = {}; game.tick = 900
  map.map_summary({})
  -- Evict real bootstrap transfers, then prove a strictly later interval.
  for i = 1, 129 do record(flow_processor) end
  game.tick = 901
  local later_sample = map.factory_component_sample({ source_tick = 901, positions = { flow_source.position } })
  prove(later_sample, 901)
  game.tick = 960
  local later = map.map_summary({})
  check(later.factory.material_flow.components[1].state.autonomous_end_to_end
    and not later.factory.character_transfers.history_complete
    and later.factory.character_transfers.transfer_actions == 128
    and #storage.factory_activity.events == 128,
    "older-event eviction does not invalidate a later proof or change bounded whole-run counts")
  game.tick = 961
  local narrow = map.map_summary({ activity_since_tick = 961 })
  check(narrow.factory.material_flow.components[1].state.autonomous_end_to_end
    and narrow.factory.character_transfers.history_complete
    and narrow.factory.character_transfers.transfer_actions == 0
    and narrow.factory.material_flow.components[1].character_transfer_actions == 0,
    "a requested window after validation ends retains proof with its own zero transfer counts")
  storage.factory_activity.latest_evicted_tick = nil
  check(not map.map_summary({ activity_since_tick = 960 }).factory.material_flow.components[1].state.autonomous_end_to_end
    and not activity.snapshot(960).history_complete,
    "missing eviction boundary cannot establish proof or requested-window completeness")
  storage.factory_activity.latest_evicted_tick = 901
  local exact = map.map_summary({ activity_since_tick = 960 })
  check(not exact.factory.material_flow.components[1].state.autonomous_end_to_end
    and exact.factory.material_flow.components[1].state.autonomy_evidence == "character_transfer_history_incomplete"
    and exact.factory.character_transfers.history_complete,
    "eviction at the exact proof start remains incomplete even with complete narrower telemetry")
  storage.factory_activity.latest_evicted_tick = 920
  check(not map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
    "eviction overlapping a proven interval prevents current autonomy")
  storage.factory_activity.latest_evicted_tick = 900
  game.tick = 961; record(flow_processor); game.tick = 962
  local hidden = map.map_summary({ activity_since_tick = 962 })
  check(not hidden.factory.material_flow.components[1].state.autonomous_end_to_end
    and hidden.factory.material_flow.components[1].state.autonomy_evidence == "character_transfer_observed"
    and hidden.factory.character_transfers.transfer_actions == 0
    and hidden.factory.material_flow.components[1].character_transfer_actions == 0,
    "a narrow activity window cannot hide post-proof assistance but preserves raw window counts")
  local fresh = map.factory_component_sample({ source_tick = 962, positions = { flow_source.position } })
  check(fresh.topology_ready and fresh.character_history_complete and fresh.character_transfer_actions == 0,
    "new validation samples assess their own clean interval without inheriting old proof assistance")
  storage.factory_activity.latest_evicted_tick = 962
  local incomplete = map.factory_component_sample({ source_tick = 962, positions = { flow_source.position } })
  check(not incomplete.topology_ready and not incomplete.character_history_complete,
    "new validation samples require complete history at their own exact start boundary")
  storage.factory_activity.latest_evicted_tick = 900
  -- Evict the disallowed post-proof insertion with unrelated later events.
  for i = 1, 128 do record({ name = "unrelated", type = "container", position = { x = -1, y = -1 } }) end
  local evicted_assistance = map.map_summary({ activity_since_tick = 962 })
  check(not evicted_assistance.factory.material_flow.components[1].state.autonomous_end_to_end
    and evicted_assistance.factory.material_flow.components[1].state.autonomy_evidence == "character_transfer_history_incomplete",
    "evicted post-proof assistance cannot disappear behind unrelated activity")

  -- Two disconnected components share one log but have different proof starts.
  local original_entities = flow_entities
  local other_entities, other_source = flow_fixture(false, false)
  for _, entity in ipairs(other_entities) do entity.position.x = entity.position.x + 10 end
  flow_entities = {}; for _, entity in ipairs(original_entities) do flow_entities[#flow_entities + 1] = entity end
  for _, entity in ipairs(other_entities) do flow_entities[#flow_entities + 1] = entity end
  storage = {}; game.tick = 899; map.map_summary({})
  local first_sample = map.factory_component_sample({ source_tick = 899, positions = { flow_source.position } })
  local second_sample = map.factory_component_sample({ source_tick = 899, positions = { other_source.position } })
  game.tick = 900
  for i = 1, 129 do record({ name = "unrelated", type = "container", position = { x = -1, y = -1 } }) end
  prove(first_sample, 900); prove(second_sample, 901); game.tick = 960
  local mixed = map.map_summary({})
  check(#mixed.factory.material_flow.components == 2
    and not mixed.factory.material_flow.components[1].state.autonomous_end_to_end
    and mixed.factory.material_flow.components[2].state.autonomous_end_to_end,
    "each component uses its own proof interval against the shared eviction watermark")
  storage.factory_activity.validations = {}
  local unvalidated = map.map_summary({})
  local unvalidated_narrow = map.map_summary({ activity_since_tick = 960 })
  check(not unvalidated.factory.material_flow.components[1].state.autonomy_topology_ready
    and unvalidated_narrow.factory.material_flow.components[1].state.autonomy_topology_ready
    and not unvalidated_narrow.factory.material_flow.components[1].state.autonomous_end_to_end,
    "unvalidated components require completeness for the requested window and never gain proof from it")
  flow_entities, storage, game.tick = original_entities, saved_storage, 960
end
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
buffer_source.burner = { currently_burning = { name = prototypes.item.coal, quality = { name = "normal" } }, remaining_burning_fuel = 4 }
buffer_source.get_fuel_inventory = function() return {
  get_contents = function() return { { name = "coal", quality = "normal", count = fuel_count } } end,
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
local function saturation_rows()
  local rows = {}
  for _, row in ipairs(map.factory_component_sample({ source_tick = game.tick, positions = { buffer_source.position } })._blocker_rows) do
    rows[#rows + 1] = row.reason .. ":" .. row.class
  end
  return table.concat(rows, ",")
end
check(not saturation_rows():match("full_output"), "a proven fuel-return saturation is not even a transient wait")
local string_burning = buffer_source.burner.currently_burning
buffer_source.burner.currently_burning = { name = { name = "coal", fuel_value = 4000000 }, quality = { name = "normal" } }
local object_saturated
for _, node in ipairs(map.map_summary({}).factory.material_flow.nodes) do
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
  local summary = map.map_summary({})
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
    and not canonical(component.state.autonomy_blockers):match("downstream_inventory_blocked")
    and saturation_rows():match("nonproductive_status:full_output:transient"), label)
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
local held_fuel = fuel_feed.held_stack
local empty_held = setmetatable({ valid_for_read = false }, {
  __index = function() error("empty stack identity is unreadable") end,
  __newindex = function() error("empty stack fields are read-only") end,
})
fuel_feed.held_stack = empty_held
local empty_wait = map.map_summary({})
local empty_wait_node
for _, node in ipairs(empty_wait.factory.material_flow.nodes) do if node.name == "fuel-feed" then empty_wait_node = node end end
check(empty_wait.factory.material_flow.components[1].state.autonomy_topology_ready
  and not empty_wait.factory.material_flow.components[1].state.autonomous_end_to_end
  and empty_wait_node.status == "full_output"
  and empty_wait_node.fuel_return_saturation.identity_source == "burning_and_stocked_fuel",
  "empty held stack wait derives identity only from the supported burning and stocked pair, without proving autonomy")
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
    setmetatable(buffer_source.burner, { __index = function() error("unreadable current fuel") end })
  end,
  function() setmetatable(buffer_source.burner, nil); buffer_source.burner.currently_burning = burning_fuel end)
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
-- A belt run ending at an inserter pickup is consumed there; only a run with
-- no consumer anywhere along it is a dead end, reported at its last tile.
local coal_belt = { valid = true, name = "transport-belt", type = "transport-belt", position = { x = 1, y = 4 },
  force = force, status = 2, belt_neighbours = { inputs = {}, outputs = {} } }
coal_source.drop_target, fuel_feed.pickup_target, furnace_fuel.pickup_target = coal_belt, coal_belt, coal_belt
buffer_segment[9] = coal_belt
-- Match the reported self-return binding as well as the useful furnace branch.
coal_source.burner, coal_source.prototype, coal_source.get_fuel_inventory = buffer_source.burner, burner_prototype, fuel_inventory
fuel_feed.drop_target = coal_source
local picked = map.map_summary({})
check(not canonical(picked.factory.material_flow.diagnostics):match("belt_")
  and not canonical(picked.factory.material_flow.components[1].state.autonomy_blockers):match("belt_"),
  "exact drill-to-belt-to-fuel-inserter bindings ending at an inserter pickup are not a dead end")
fuel_feed.pickup_target, furnace_fuel.pickup_target = coal_source, coal_source
local dead_end = map.map_summary({})
local dead_row, dead_node
for _, row in ipairs(dead_end.factory.material_flow.diagnostics) do
  if row.reason == "belt_dead_end_without_consumer" then dead_row = row end
end
for _, node in ipairs(dead_end.factory.material_flow.nodes) do if dead_row and node.id == dead_row.node_id then dead_node = node end end
local dead_sample = map.factory_component_sample({ source_tick = game.tick, positions = { coal_belt.position } })
local dead_located
for _, row in ipairs(dead_sample._blocker_rows) do
  if row.reason == "relationship_diagnostic:belt_dead_end_without_consumer" and row.class == "structural"
    and row.position.x == 1 and row.position.y == 4 and row.entity == "transport-belt" then dead_located = true end
end
check(dead_row and dead_row.class == "structural" and dead_row.related_edge.kind == "belt_or_pickup"
  and dead_node.position.x == 1 and dead_node.position.y == 4 and dead_located and not dead_sample.topology_ready
  and canonical(dead_sample.blockers):match("relationship_diagnostic:belt_dead_end_without_consumer"),
  "a belt run with no consumer anywhere is a structural dead end located at its last tile")
coal_source.drop_target, fuel_feed.pickup_target, furnace_fuel.pickup_target = fuel_feed, coal_source, coal_source
buffer_segment[9] = nil
coal_source.burner, coal_source.prototype, coal_source.get_fuel_inventory = nil, nil, nil
fuel_feed.drop_target = buffer_source
fuel_feed.status = 3
local bypass_stock = 0
defines.entity_status.waiting_for_source_items = 7
defines.entity_status.no_ingredients = 8
local function simulate_validation(mode)
  game.tick = game.tick + 100
  local start = game.tick
  storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
  buffer_accepting, buffer_stock, buffer_processor.products_finished = true, 0, 10
  buffer_source.status, buffer_processor.status = 3, 3
  buffer_processor.burner, buffer_processor.get_fuel_inventory = buffer_source.burner, fuel_inventory
  buffer_processor.get_recipe = processor_recipe
  local function unsupported_compartment()
    local recipe = processor_recipe()
    local fact = { name = recipe.name, products = recipe.products }
    if mode == "compartment_malformed" then fact.ingredients = { false }
    elseif mode == "compartment_unreadable" then
      setmetatable(fact, { __index = function(_, key) if key == "ingredients" then error("unsupported") end end })
    end
    return fact
  end
  if mode:match("^compartment_") and mode ~= "compartment_later" then
    buffer_processor.get_recipe = unsupported_compartment
    buffer_processor.get_fuel_inventory = function() error("unsupported") end
  end
  furnace_fuel.held_stack = empty_held
  buffer_segment[2].status, buffer_segment[2].held_stack = 3, empty_held
  fuel_count = 5
  fuel_feed.held_stack = mode == "empty_wait" and empty_held or held_fuel
  fuel_feed.status = (mode == "saturated" or mode == "empty_wait" or mode == "replenish" or mode == "ambiguous_return"
    or mode == "incompatible_return" or mode == "blocked_output") and 5 or 3
  held_fuel.name = mode == "incompatible_return" and "incompatible" or "coal"
  buffer_source.get_fuel_inventory = mode == "ambiguous_return" and function() error("unsupported") end or fuel_inventory
  buffer_segment[4].status = mode == "blocked_output" and 6 or 3
  buffer_segment[4].held_stack = empty_held
  if mode == "fuel_wait_preflight" or mode == "persistent_fuel_wait" then
    fuel_feed.status, fuel_feed.held_stack = 7, empty_held
  elseif mode == "material_wait_preflight" or mode == "persistent_material_wait" then buffer_segment[2].status = 7
  elseif mode == "output_wait_preflight" then buffer_segment[4].status = 7
  elseif mode == "generic_shortage" then buffer_segment[2].status = 8 end
  buffer_source.mining_progress, coal_source.mining_progress = 0.9, 0.9
  map.map_summary({}) -- establish the run-local epoch before source_tick
  if mode == "older_eviction" then
    for i = 1, 129 do
      require("scripts.factory_activity").record("insert", { target = buffer_processor,
        transfers = { { item = "ore", inserted = 1 } } })
    end
  end
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
    local halted = mode == "no_fuel" and i >= 2
    if mode ~= "no_production" and not halted then buffer_processor.products_finished = buffer_processor.products_finished + 1 end
    if mode ~= "no_acceptance" and mode ~= "wrong_product" and not halted then buffer_stock = buffer_stock + 1 end
    if mode == "wrong_product" then bypass_stock = bypass_stock + 1 end
    if mode == "blocked" and i == 2 then buffer_accepting = false end
    if mode == "no_fuel" and i == 2 then buffer_processor.status = 4 end
    if mode == "replenish" then
      fuel_feed.status = i == 2 and 3 or 5
      fuel_count = i == 2 and 4 or 5
    end
    if mode == "fuel_wait_preflight" then fuel_feed.status = 3 end
    if mode == "material_wait_preflight" then buffer_segment[2].status = 3 end
    if mode == "output_wait_preflight" then buffer_segment[4].status = 3 end
    if mode == "fuel_wait_later" then fuel_feed.status, fuel_feed.held_stack = i == 2 and 7 or 3, empty_held end
    if mode == "material_wait_later" then buffer_segment[2].status = i == 2 and 7 or 3 end
    if mode == "persistent_later_wait" and i >= 2 then fuel_feed.status, fuel_feed.held_stack = 7, empty_held end
    if i == 2 then
      if mode == "compartment_later" then
        buffer_processor.get_recipe = unsupported_compartment
        buffer_processor.get_fuel_inventory = function() error("unsupported") end
      end
      if mode == "empty_stock_later" then fuel_count = 0 end
      if mode == "no_energy_later" then buffer_source.burner.remaining_burning_fuel = 0 end
      if mode == "unsupported_fuel_later" then buffer_source.get_fuel_inventory = function() error("unsupported") end end
      if mode == "incompatible_held_later" then fuel_feed.held_stack.name = "incompatible" end
    end
    if mode == "harvest" and i == 2 then
      buffer_stock = buffer_stock - 1
      require("scripts.factory_activity").record("extract", { target = buffer_sink, transfers = { { item = "plate", extracted = 1 } } })
    end
    if mode == "transfer" and i == 2 then
      require("scripts.factory_activity").record("insert", { target = buffer_processor, transfers = { { item = "ore", inserted = 1 } } })
    end
    tasks.on_tick()
  end
  local result = tasks.plan_status({ plan_id = queued.plan_id })
  -- Restore only after the final observation; every validation sample used
  -- the actual changed fuel evidence, independently of downstream growth.
  buffer_source.burner.remaining_burning_fuel = 4
  return result
end
defines.entity_status.no_fuel = 4
local accepted_buffer = simulate_validation("accept")
check(accepted_buffer.status == "completed" and accepted_buffer.outcomes[1].result.downstream_kind == "buffer"
  and accepted_buffer.outcomes[1].result.downstream_acceptance_samples == 3
  and map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
  "real graph and validator prove supplied burner drill-furnace-chest acceptance across three unattended cycles")
local later_buffer = simulate_validation("older_eviction")
local later_buffer_summary = map.map_summary({})
check(later_buffer.status == "completed"
  and later_buffer_summary.factory.material_flow.components[1].state.autonomous_end_to_end
  and not later_buffer_summary.factory.character_transfers.history_complete,
  "real parked validation proves a later interval after bootstrap transfer eviction")
simulate_validation("accept") -- retain the ordinary harvesting fixture below
-- Harvest only after a real unattended validation; keep production and the
-- terminal inventory physically progressing for ten minutes of fixture time.
local harvest_start, produced_before = game.tick, buffer_processor.products_finished
for i = 1, 20 do
  require("scripts.factory_activity").record("insert", { target = { name = "unrelated", type = "container",
    position = { x = -i, y = -10 } }, transfers = { { item = "ore", inserted = 1 } } })
end
for i = 1, 60 do
  game.tick = harvest_start + i * 600
  buffer_processor.products_finished = buffer_processor.products_finished + 10
  buffer_source.mining_target.amount = buffer_source.mining_target.amount - 10
  coal_source.mining_target.amount = coal_source.mining_target.amount - 10
  buffer_stock = buffer_stock + 10
  buffer_stock = buffer_stock - 10
  require("scripts.factory_activity").record("extract", { target = buffer_sink,
    transfers = { { item = "plate", extracted = 10 } } })
  local summary = map.map_summary({})
  check(summary.factory.material_flow.components[1].state.autonomous_end_to_end,
    "terminal harvesting retains a real proof at simulated second " .. i * 10)
end
local harvested = map.map_summary({})
check(game.tick - harvest_start == 36000 and buffer_processor.products_finished - produced_before == 600
  and harvested.factory.character_transfers.transfer_actions == 80
  and harvested.factory.character_transfers.extracted_items[1].count == 600
  and harvested.factory.material_flow.components[1].character_transfer_actions == 60
  and harvested.factory.character_transfers.target_actions_omitted > 0,
  "ten minutes of production and capped public telemetry retain honest harvesting counts")
for _, case in ipairs({
  { "terminal insertion", "insert", buffer_sink, { { item = "plate", inserted = 1 } } },
  { "processor extraction", "extract", buffer_processor, { { item = "plate", extracted = 1 } } },
  { "unrelated item", "extract", buffer_sink, { { item = "ore", extracted = 1 } } },
  { "mixed extraction", "extract", buffer_sink, { { item = "plate", extracted = 1 }, { item = "ore", extracted = 1 } } },
}) do
  simulate_validation("accept")
  game.tick = game.tick + 1
  require("scripts.factory_activity").record(case[2], { target = case[3], transfers = case[4] })
  -- Hide the disallowed event behind the public event cap with later harvesting.
  for i = 1, 9 do
    game.tick = game.tick + 1
    require("scripts.factory_activity").record("extract", { target = buffer_sink,
      transfers = { { item = "plate", extracted = 1 } } })
  end
  local state = map.map_summary({}).factory.material_flow.components[1].state
  check(not state.autonomous_end_to_end and state.autonomy_evidence == "character_transfer_observed",
    case[1] .. " revokes proof even behind the public event cap")
end
simulate_validation("accept")
require("scripts.factory_activity").record("extract", { target = buffer_sink,
  transfers = { { item = "plate", extracted = 1 } } })
check(not map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
  "extraction at validation end tick is not post-validation harvesting")
simulate_validation("accept")
for i = 1, 129 do
  game.tick = game.tick + 1
  require("scripts.factory_activity").record("extract", { target = buffer_sink,
    transfers = { { item = "plate", extracted = 1 } } })
end
check(not map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
  "evicted harvesting history remains conservatively unproven")
simulate_validation("no_production")
game.tick = game.tick + 1
require("scripts.factory_activity").record("extract", { target = buffer_sink,
  transfers = { { item = "plate", extracted = 1 } } })
check(not map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
  "terminal harvesting never establishes a missing unattended proof")
local saturated_interval = simulate_validation("saturated")
check(saturated_interval.status == "completed" and map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
  "parked validator permits proven saturated fuel replenishment only with independent multi-tick production and acceptance")
local replenished_interval = simulate_validation("replenish")
check(replenished_interval.status == "completed",
  "offline replenishment resumes after fuel consumption and returns to ordinary saturation without changing topology")
local empty_interval = simulate_validation("empty_wait")
check(empty_interval.status == "completed" and map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
  "empty-stack waiting permits independent multi-tick production and acceptance in the parked validator")
fuel_feed.held_stack = empty_held
fuel_feed.status = 5
local empty_wait_node
for _, node in ipairs(map.map_summary({}).factory.material_flow.nodes) do if node.name == "fuel-feed" then empty_wait_node = node end end
check(empty_wait_node.fuel_return_saturation and empty_wait_node.fuel_return_saturation.identity_source == "burning_and_stocked_fuel",
  "an empty-hand return waiting at a stocked working burner derives identity from the burning and stocked pair")
fuel_feed.held_stack, fuel_feed.status = held_fuel, 3
for _, count in ipairs({ 1, 17 }) do
  fuel_count = count
  check(map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
    "positive compatible stock keeps the proof without a hard-coded stock threshold: " .. count)
end
fuel_count, fuel_feed.status = 5, 7
local waiting_summary = map.map_summary({})
check(waiting_summary.factory.material_flow.components[1].state.autonomous_end_to_end
  and canonical(waiting_summary.factory.material_flow.diagnostics):match('"class":"transient"'),
  "a current source-item wait is one transient sample and does not revoke a validated proof")
fuel_feed.status = 3
-- One wait at preflight or mid-window is a sample; the window judges flow.
for _, mode in ipairs({ "fuel_wait_preflight", "material_wait_preflight", "output_wait_preflight", "fuel_wait_later",
  "material_wait_later", "persistent_later_wait" }) do
  local interval = simulate_validation(mode)
  check(interval.status == "completed" and interval.outcomes[1].result.source_cycles_observed == 3
    and interval.outcomes[1].result.downstream_acceptance_samples == 3
    and canonical(interval.outcomes[1].result.transient_conditions):match("nonproductive_status:insufficient_input"),
    "bounded validator judges throughput, reporting the wait only as a transient condition, after " .. mode)
end
-- An inserter starved in every sample carried nothing: growth came from stock.
for _, mode in ipairs({ "persistent_fuel_wait", "persistent_material_wait", "generic_shortage" }) do
  local interval = simulate_validation(mode)
  check(interval.status == "failed" and buffer_stock == 3
    and canonical(interval.outcomes[1].result.blockers):match('"position":{"x":2,"y":%d},"reason":"transport_starved_before_end"'),
    "productive sources and rising downstream stock cannot conceal " .. mode)
end
for _, case in ipairs({ { "empty_stock_later", "fuel_return_not_yet_exercised" }, { "no_energy_later", "fuel_return_not_yet_exercised" },
  { "unsupported_fuel_later", "fuel_stock_unreadable" }, { "compartment_missing", "fuel_stock_unreadable" },
  { "compartment_unreadable", "fuel_stock_unreadable" }, { "compartment_malformed", "fuel_stock_unreadable" },
  { "compartment_later", "fuel_stock_unreadable" } }) do
  local interval = simulate_validation(case[1])
  check(interval.status == "failed" and buffer_stock > 0
    and canonical(interval.outcomes[1].result.blockers):match(case[2]),
    "rising downstream stock cannot conceal unproven burner fuel: " .. case[1])
end
local unreadable_return = simulate_validation("ambiguous_return")
check(unreadable_return.status == "failed"
  and canonical(unreadable_return.outcomes[1].result.blockers):match("fuel_stock_unreadable"),
  "an unreadable burner fuel inventory fails the window closed despite downstream growth")
-- An unproven inserter wait is one status sample; flow decides the window.
for _, mode in ipairs({ "incompatible_return", "blocked_output" }) do
  local waited = simulate_validation(mode)
  check(waited.status == "completed" and waited.outcomes[1].result.blocked_output == false
    and canonical(waited.outcomes[1].result.transient_conditions):match("nonproductive_status:full_output")
    and not canonical(waited.outcomes[1].result.blockers):match("full_output"),
    "parked validator proves " .. mode .. " from throughput and reports the wait only as a transient condition")
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
game.tick = game.tick + 1
require("scripts.factory_activity").record("extract", { target = middle_chest,
  transfers = { { item = "plate", extracted = 1 } } })
check(not map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
  "accepted-product extraction from an intermediate buffer still revokes proof")
middle_chest.get_inventory = function() return { get_item_count = function() return 10 end, can_insert = function() return false end } end
local blocked_middle = simulate_validation("accept")
check(blocked_middle.status == "completed" and not blocked_middle.outcomes[1].result.blocked_output
  and blocked_middle.outcomes[1].result.proven,
  "a full intermediate buffer is backpressure, not blocked output, while the terminal buffer accepts")
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
local blocked_row
for _, row in ipairs(blocked_interval.outcomes[1].result.blockers) do
  if row.reason == "blocked_output" and row.position.x == buffer_sink.position.x and row.position.y == buffer_sink.position.y then blocked_row = row end
end
check(blocked_interval.status == "failed" and blocked_interval.outcomes[1].result.blocked_output and blocked_row,
  "a nonaccepting buffer during the unattended interval prevents validation at the buffer's position")
local interrupted_fuel = simulate_validation("no_fuel")
check(interrupted_fuel.status == "failed"
  and canonical(interrupted_fuel.outcomes[1].result.blockers):match("several_processor_cycles_not_observed")
  and canonical(interrupted_fuel.outcomes[1].result.transient_conditions):match("nonproductive_status:no_fuel"),
  "fuel interruption that stops production fails on throughput and names the no_fuel wait as transient")
local assisted_harvest = simulate_validation("harvest")
check(assisted_harvest.status == "failed"
  and canonical(assisted_harvest.outcomes[1].result.blockers):match("character_transfer_observed"),
  "accepted terminal harvesting during validation remains character assistance")
local transferred_interval = simulate_validation("transfer")
check(transferred_interval.status == "failed" and canonical(transferred_interval.outcomes[1].result.blockers):match("character_transfer_observed"),
  "a character transfer during the real unattended interval invalidates acceptance")
check(not canonical(accepted_buffer):match('"stock"') and not canonical(accepted_buffer):match('"_signature"')
  and not canonical(map.map_summary({})):match('"_signature"'),
  "public validation and retained history expose no private stock samples or exact identity strings")

-- A 30-tick machine period near the sample interval must not stay phase-locked.
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
    prototype = burner_prototype, burner = { currently_burning = { name = prototypes.item.coal, quality = { name = "normal" } }, remaining_burning_fuel = 4 },
    get_fuel_inventory = function() return {
      get_contents = function() return { { name = "coal", quality = "normal", count = 5 } } end,
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
    get_contents = function() return { { name = "coal", quality = "normal", count = 5 } } end,
    get_item_count = function() return 5 end, can_insert = function() return false end,
  } end
  elseif mode == "unsupported_fuel" then source.get_fuel_inventory = function() error("unsupported") end
  elseif mode == "generic_full" then refill.status = 6
  elseif mode == "shared_target" then
    entities[6] = { valid = true, name = "other-source", type = "mining-drill", force = force,
      position = { x = 1, y = 5 }, status = 3, mining_target = target, mining_progress = 0.9, drop_target = middle }
  elseif mode == "belt_pickup_end" then
    local belt = { valid = true, name = "pickup-terminal", type = "transport-belt", force = force,
      position = { x = 2, y = 6 }, status = 3, belt_neighbours = { inputs = {}, outputs = {} } }
    source.drop_target, unload.pickup_target, refill.pickup_target = belt, belt, belt
    entities[2] = belt
  elseif mode == "belt_dead_end" then
    entities[6] = { valid = true, name = "spill-belt", type = "transport-belt", force = force,
      position = { x = 3, y = 6 }, status = 3, belt_neighbours = { inputs = {}, outputs = {} } }
    entities[7] = { valid = true, name = "spill", type = "inserter", force = force,
      position = { x = 3, y = 5 }, status = 3, pickup_target = middle, drop_target = entities[6] }
  end
  if mode == "consumer" or mode == "consumer_wrong_output" or mode == "consumer_multi_output" or mode == "consumer_full"
    or mode == "consumer_interruption" or mode == "consumer_unavailable" then
    sink.type, sink.name, sink.status = "burner-generator", "source-consumer", 3
    sink.prototype, sink.burner = burner_prototype, { currently_burning = { name = prototypes.item.coal, quality = { name = "normal" } }, remaining_burning_fuel = 4 }
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
    -- An interruption that matters stops progress, stock and depletion.
    local halted = (mode == "fuel_interruption" or mode == "power_interruption") and i >= 2
    if mode ~= "unavailable" and mode ~= "aliased" and not halted then source.mining_progress = 0.9 - i * 0.1 end
    if mode ~= "no_depletion" and not halted then target.amount = target.amount - 1 end
    if mode ~= "stagnant" and not halted then stock = stock + 1 end
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
-- An unproven refill wait (no energy, other fuel, full fuel inventory,
-- generic full_output) is a transient status, not a defect.
for _, mode in ipairs({ "self_return", "electric", "consumer", "belt_pickup_end",
  "no_energy", "incompatible_fuel", "full_fuel", "generic_full" }) do
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
  { "unsupported_fuel", "fuel_stock_unreadable" },
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
  { "unavailable", "several_source_cycles_not_observed" },
  { "unavailable_target", "output_identity_unproven" },
  { "aliased", "several_source_cycles_not_observed" },
  { "no_depletion", "several_source_cycles_not_observed" },
  { "shared_target", "shared_mining_target_production_ambiguous" },
  { "stagnant", "bounded_downstream_acceptance_not_observed" },
  { "full_buffer", "blocked_output" }, { "unsupported_buffer", "downstream_buffer_acceptance_unproven" },
  { "fuel_interruption", "several_source_cycles_not_observed" },
  { "power_interruption", "several_source_cycles_not_observed" },
  { "topology", "component_topology_changed_during_validation" },
  { "target_change", "several_source_cycles_not_observed" },
  { "transfer", "character_transfer_observed" },
  { "incomplete_history", "character_transfer_history_incomplete" },
  { "belt_dead_end", "relationship_diagnostic:belt_dead_end_without_consumer" },
}) do
  local result = source_only_validation(case[1])
  check(result.status == "failed" and canonical(result.outcomes[1].result.blockers):match(case[2]),
    "source-only rejects " .. case[1] .. " with " .. case[2])
end
for _, case in ipairs({ { "no_energy", "full_output" }, { "generic_full", "full_output" },
  { "fuel_interruption", "no_fuel" }, { "power_interruption", "no_power" } }) do
  local result = source_only_validation(case[1])
  check(canonical(result.outcomes[1].result.transient_conditions):match("nonproductive_status:" .. case[2]),
    "source-only " .. case[1] .. " reports its " .. case[2] .. " samples only as a transient condition")
end
local spill_result = source_only_validation("belt_dead_end")
local spill_row
for _, row in ipairs(spill_result.outcomes[1].result.blockers) do
  if row.reason:match("belt_dead_end_without_consumer") then spill_row = row end
end
check(spill_row and spill_row.position.x == 3 and spill_row.position.y == 6 and spill_row.class == "structural"
  and spill_result.outcomes[1].result.stage == "preflight" and not spill_result.outcomes[1].result.refused,
  "a dead-end belt is a located structural preflight failure, not a readiness refusal")
-- Belt dead ends are decided per run after every exact edge exists: a pickup
-- anywhere along the run, an underground exit or a loader container counts.
local many_rows_fixture
do
  local function belt(x, y, kind)
    return { valid = true, name = kind or "transport-belt", type = kind or "transport-belt", force = force,
      position = { x = x, y = y }, status = 3, belt_neighbours = { inputs = {}, outputs = {} } }
  end
  local function link(a, b)
    a.belt_neighbours.outputs[#a.belt_neighbours.outputs + 1] = b
    b.belt_neighbours.inputs[#b.belt_neighbours.inputs + 1] = a
  end
  local function drill(x, y, drop)
    return { valid = true, name = "electric-mining-drill", type = "mining-drill", force = force, position = { x = x, y = y },
      status = 3, drop_target = drop, mining_target = { valid = true, name = "coal", type = "resource", position = { x = x, y = y },
        amount = 100, prototype = { mineable_properties = { products = { { name = "coal", type = "item" } } } } } }
  end
  local function chest(x, y)
    return { valid = true, name = "wooden-chest", type = "container", force = force, position = { x = x, y = y }, status = 2,
      get_inventory = function() return { get_item_count = function() return 0 end, can_insert = function() return true end } end }
  end
  local function inserter(x, y, pickup, drop)
    return { valid = true, name = "inserter", type = "inserter", force = force, position = { x = x, y = y }, status = 3,
      pickup_target = pickup, drop_target = drop }
  end
  local function dead_ends(entities)
    storage = {}
    surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end
    local summary = map.map_summary({})
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

-- Parked validation windows over the real graph. Statuses vary per tick the
-- way supply-limited machines do; progress counters advance at that rate.
local function run_window(entities, position, duration, advance)
  game.tick = game.tick + 100
  local start = game.tick
  storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
  surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end
  advance(0)
  map.map_summary({}) -- open complete run-local transfer history
  local queued = tasks.queue_plan({ observation_detail = "none", steps = { { action = "validate_factory_component",
    source_tick = start, positions = { position }, duration_seconds = duration } } })
  local result
  for tick = start + 1, start + 1 + duration * 60 do
    game.tick = tick
    advance(tick - start - 1)
    tasks.on_tick()
    result = tasks.plan_status({ plan_id = queued.plan_id })
    if result.status == "completed" or result.status == "failed" then break end
  end
  return result, result.outcomes and result.outcomes[1].result
end
defines.entity_status.no_ingredients, defines.entity_status.waiting_for_source_items = 7, 8

do
  local segment = { buffer_source, buffer_segment[2], buffer_processor, buffer_segment[4], buffer_sink, coal_source, fuel_feed, furnace_fuel }
  buffer_sink.get_inventory, buffer_accepting = regular_inventory, true
  local function supply_limited(elapsed)
    local waiting, cycles = elapsed % 10 < 7, math.floor(elapsed / 90)
    buffer_processor.status = waiting and 7 or 3
    buffer_segment[2].status = waiting and 8 or 3
    -- The drill backs up and is sampled waiting for output space every time,
    -- yet its progress wraps and its target depletes: that is a cycle.
    buffer_source.status = 5
    buffer_source.mining_progress, coal_source.mining_progress = (elapsed % 90) / 90, (elapsed % 90) / 90
    buffer_source.mining_target.amount, coal_source.mining_target.amount = 1000 - cycles, 1000 - cycles
    buffer_processor.products_finished, buffer_stock = 10 + cycles, cycles
  end
  local limited, outcome = run_window(segment, buffer_sink.position, 60, supply_limited)
  local furnace_wait
  for _, row in ipairs(outcome.transient_conditions or {}) do
    if row.position.x == buffer_processor.position.x and row.position.y == buffer_processor.position.y then furnace_wait = row end
  end
  check(limited.status == "completed" and outcome.proven and outcome.stage == "window"
    and furnace_wait and furnace_wait.reason == "nonproductive_status:insufficient_input" and furnace_wait.class == "transient"
    and furnace_wait.nonproductive_samples / furnace_wait.samples > 0.5 and furnace_wait.nonproductive_samples / furnace_wait.samples < 0.9
    and outcome.samples_observed > 100 and #outcome.transient_conditions <= 8 and outcome.source_cycles_observed >= 3
    and map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
    "a supply-limited furnace waiting on input about 70% of samples proves autonomy from throughput")

  buffer_source.status = 4
  local dry = map.map_summary({}).factory.material_flow.components[1].state
  buffer_source.status, buffer_processor.status = 3, 7
  local waiting_state = map.map_summary({}).factory.material_flow.components[1].state
  check(dry.autonomy_topology_ready and not dry.autonomous_end_to_end and dry.autonomy_evidence == "validated_producer_nonproductive"
    and not canonical(dry.autonomy_blockers):match("no_fuel")
    and waiting_state.autonomous_end_to_end,
    "a validated drill at no_fuel loses current autonomy while an input wait does not")

  local function starved(elapsed)
    buffer_processor.status, buffer_source.status = 4, 3
    buffer_source.mining_progress, coal_source.mining_progress = 0.5, 0.5
    buffer_processor.products_finished, buffer_stock = 10, 0
  end
  local stalled, stall = run_window(segment, buffer_sink.position, 60, starved)
  local persistent
  for _, row in ipairs(stall.blockers) do
    if row.reason == "persistent_nonproductive_status:no_fuel" then persistent = row end
  end
  check(stalled.status == "failed" and persistent and persistent.class == "structural"
    and persistent.position.x == buffer_processor.position.x and persistent.position.y == buffer_processor.position.y
    and stall.duration_ticks >= 1200 and stall.duration_ticks < 3600 and #stall.blockers <= 12,
    "a processor at no_fuel through a 20 s stall fails early as a located persistent nonproductive status")

  -- The stall share counts only samples since the last progress: a segment
  -- that worked for 25 s and then stopped is judged on the stop, and the
  -- producer out of fuel carries the row, not the drill backed up behind it.
  local function runs_dry(drill_status)
    return function(elapsed)
      supply_limited(math.min(elapsed, 1499))
      if elapsed >= 1500 then buffer_processor.status, buffer_segment[2].status, buffer_source.status = 4, 8, drill_status end
    end
  end
  local function rows_at(outcome, rows, entity)
    local found = {}
    for _, row in ipairs(outcome[rows] or {}) do
      if row.position and row.position.x == entity.position.x and row.position.y == entity.position.y then found[#found + 1] = row.reason end
    end
    return table.concat(found, ",")
  end
  local late_plan, late = run_window(segment, buffer_sink.position, 60, runs_dry(4))
  check(late_plan.status == "failed" and not late.proven and late.stage == "window"
    and rows_at(late, "blockers", buffer_processor):match("persistent_nonproductive_status:no_fuel")
    and late.source_cycles_observed >= 3 and late.downstream_acceptance_samples >= 3
    and late.last_progress_tick - late.start_tick > 1400 and late.duration_ticks < 3600,
    "a segment productive for 25 s that then runs out of fuel fails on the stall, not the whole-window share")
  local backed_plan, backed = run_window(segment, buffer_sink.position, 60, runs_dry(5))
  check(backed_plan.status == "failed"
    and rows_at(backed, "blockers", buffer_processor) == "persistent_nonproductive_status:no_fuel"
    and rows_at(backed, "blockers", buffer_source) == ""
    and rows_at(backed, "transient_conditions", buffer_source) == "nonproductive_status:full_output",
    "the furnace out of fuel carries the stall row while the drill backed up behind it stays a transient symptom")
  local still_plan, still = run_window(segment, buffer_sink.position, 60, function(elapsed)
    supply_limited(math.min(elapsed, 1799))
    buffer_processor.status, buffer_segment[2].status, buffer_source.status = 3, 3, 3
  end)
  local stalled_row
  for _, row in ipairs(still.blockers) do if row.reason == "progress_stalled" then stalled_row = row end end
  check(still_plan.status == "failed" and not still.proven and stalled_row and stalled_row.class == "throughput"
    and still.source_cycles_observed >= 3 and still.duration_ticks >= 3600,
    "a window never ends proven while nothing has progressed for the stall interval")

  -- Premature segments are refused before any window, with located rows.
  local premature = flow_fixture(false, true)
  local refused_plan, refused = run_window(premature, premature[3].position, 60, function() end)
  local first, located = refused.blockers[1], true
  for _, row in ipairs(refused.blockers) do if not row.position then located = false end end
  check(refused_plan.status == "failed" and refused.code == "FACTORY_COMPONENT_NOT_READY" and refused.stage == "readiness"
    and refused.refused == true and refused.duration_ticks == 0 and located
    and first.reason == "fuel_input_provenance_unresolved" and first.class == "structural"
    and first.gate == nil and first.node_id == nil
    and first.position.x == 3 and first.position.y == 1 and first.entity == "processor" and first.related_edge.kind == "fuel_input"
    and refused_plan.outcomes[1].error:match("not ready for validation: fuel_input_provenance_unresolved at 3.0,1.0"),
    "a burner segment without a fuel edge is refused as not ready at the burner's position")
  local capped_plan, capped = run_window(many_rows_fixture, many_rows_fixture[2].position, 60, function() end)
  local capped_sites = {}
  for _, row in ipairs(capped.blockers) do capped_sites[row.reason .. "@" .. canonical(row.position)] = true end
  local distinct = 0
  for _ in pairs(capped_sites) do distinct = distinct + 1 end
  check(capped_plan.status == "failed" and capped.stage == "readiness" and #capped.blockers == 12 and distinct == 12
    and capped.omitted_blockers > 0,
    "a refusal with more than twelve located rows keeps twelve distinct rows and counts the rest")
  local open_ended = flow_fixture(false, false)
  local open_plan, open = run_window({ open_ended[1], open_ended[2], open_ended[3] }, open_ended[3].position, 60, function() end)
  local path_row
  located = true
  for _, row in ipairs(open.blockers) do
    if not row.position then located = false end
    if row.reason == "physical_source_downstream_path_unproven" then path_row = row end
  end
  check(open_plan.status == "failed" and open.code == "FACTORY_COMPONENT_NOT_READY" and located
    and path_row and path_row.related_edge.kind == "downstream_path",
    "a segment without a terminal buffer or consumer is refused with every readiness row located")
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
      local entity = { valid = true, name = row[1], type = row[2], position = { x = row[3], y = row[4] },
        direction = row[5], status = RAW_STATUS[row[6]], force = force, _stock = 0 }
      if entity.type == "transport-belt" then entity.belt_neighbours = { inputs = {}, outputs = {} } end
      if entity.type == "inserter" then entity.burner, entity.prototype = {}, burner_prototype end
      if entity.type == "container" then
        entity.get_inventory = function() return { get_item_count = function() return entity._stock end,
          can_insert = function() return true end } end
      end
      if entity.type == "mining-drill" then
        entity.prototype, entity.mining_progress = burner_prototype, 0
        entity.mining_target = { valid = true, name = "coal", type = "resource", position = { x = row[3] - 0.5, y = row[4] + 0.5 },
          amount = 3838, prototype = { mineable_properties = { products = { { name = "coal", type = "item" } } } } }
        entity.burner = { remaining_burning_fuel = 8,
          currently_burning = { name = { name = "coal", fuel_value = 4000000 }, quality = { name = "normal" } } }
        entity._fuel = 5
        entity.get_fuel_inventory = function() return { get_item_count = function() return entity._fuel end,
          can_insert = function() return true end,
          get_contents = function() return entity._fuel > 0 and { { name = "coal", quality = "normal", count = entity._fuel } } or {} end } end
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
    drill.burner.remaining_burning_fuel, drill._fuel = 8 * (1 - (elapsed % BURN) / BURN), fuel
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
      buffer._stock = cycles
    end
  end
  local function replay_passes(label, recorded, drill, terminal, buffer, fuel_return)
    local entities = replay(recorded)
    local advance = coal_loop(entities, entities[drill], entities[terminal], entities[buffer], entities[fuel_return])
    advance(0)
    storage = {}
    surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end
    local preflight = map.factory_component_sample({ source_tick = game.tick, positions = { entities[buffer].position } })
    local plan, outcome = run_window(entities, entities[buffer].position, 60, advance)
    check(preflight.topology_ready and #preflight.blockers == 0 and not preflight.blocked_output
      and plan.status == "completed" and outcome.proven and outcome.source_cycles_observed >= 3
      and outcome.downstream_acceptance_samples >= 3 and outcome.character_transfer_actions == 0
      and not canonical(outcome):match("belt_dead_end") and not canonical(outcome):match("full_output")
      and not canonical(outcome):match("fuel_replenishment"),
      label .. " passes preflight and a supply-limited window")
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
  -- The same loop with the surplus takeoff upstream of the fuel takeoff: the
  -- surplus inserter empties the belt, so the fuel return starves. The drill
  -- starts on bootstrap fuel and produces; topology is complete, so only the
  -- window can fail it: on the stall once the fuel runs out, or on the
  -- missing refill while the starter fuel outlasts the window.
  local surplus_layout = {
    nodes = {
      { "burner-mining-drill", "mining-drill", 32, -57, 8, "working" },
      { "transport-belt", "transport-belt", 32.5, -55.5, 4, "working" },
      { "transport-belt", "transport-belt", 33.5, -55.5, 4, "working" },
      { "transport-belt", "transport-belt", 34.5, -55.5, 0, "working" },
      { "transport-belt", "transport-belt", 34.5, -56.5, 0, "working" },
      { "burner-inserter", "inserter", 32.5, -54.5, 8, "insufficient_input" },
      { "wooden-chest", "container", 32.5, -53.5, 0, "idle" },
      { "burner-inserter", "inserter", 33.5, -56.5, 12, "insufficient_input" },
    },
    edges = {
      { 1, 2, "machine_output" }, { 2, 3, "belt_direction" }, { 3, 4, "belt_direction" }, { 4, 5, "belt_direction" },
      { 2, 6, "inserter_pickup" }, { 6, 7, "inserter_drop" }, { 5, 8, "inserter_pickup" }, { 8, 1, "inserter_drop" },
    },
  }
  local function surplus_window(bootstrap)
    local surplus = replay(surplus_layout)
    local drill, chest = surplus[1], surplus[7]
    local burnt_out = (bootstrap + 1) * BURN
    local plan, outcome = run_window(surplus, chest.position, 60, function(elapsed)
      local active = math.min(elapsed, burnt_out - 1)
      local cycles = math.floor(active / 120)
      drill.mining_progress, drill.mining_target.amount, chest._stock = (active % 120) / 120, 3838 - cycles, cycles
      surplus[6].status = elapsed % 10 < 5 and 3 or 8
      if elapsed < burnt_out then
        drill.status = 3
        burn(drill, elapsed, bootstrap - math.floor(elapsed / BURN))
      else
        drill.status, drill.burner.remaining_burning_fuel, drill._fuel = 4, 0, 0
      end
    end)
    local rows = {}
    for _, row in ipairs(outcome.blockers) do
      if row.position and row.position.x == 32 and row.position.y == -57 and row.entity == "burner-mining-drill" then rows[row.reason] = row end
    end
    return plan, outcome, rows
  end
  local dry_plan, dry_outcome, dry_rows = surplus_window(2)
  check(dry_plan.status == "failed" and dry_outcome.stage == "window" and not dry_outcome.proven
    and dry_rows["persistent_nonproductive_status:no_fuel"] and dry_outcome.source_cycles_observed >= 3
    and dry_outcome.downstream_acceptance_samples >= 3 and dry_outcome.duration_ticks < 3600,
    "surplus takeoff upstream of the fuel takeoff produces on starter fuel, then fails honestly as a persistent no_fuel drill")
  local starter_plan, starter_outcome, starter_rows = surplus_window(10)
  local refill = starter_rows.fuel_replenishment_not_observed
  check(starter_plan.status == "failed" and not starter_outcome.proven and refill and refill.class == "throughput"
    and refill.related_edge.kind == "fuel_input" and not starter_rows["persistent_nonproductive_status:no_fuel"]
    and starter_outcome.source_cycles_observed >= 3 and starter_outcome.downstream_acceptance_samples >= 3,
    "starter fuel outlasting the window cannot prove a fuel loop that never refills the drill")
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

-- Fluid identities and topology come from native source/prototype/connection
-- facts, independently of names, coordinates, recipes or preloaded contents.
do
  local previous_find, previous_fluids = surface.find_entities_filtered, prototypes.fluid
  prototypes.fluid = { aqua = { default_temperature = 15, heat_capacity = 200 },
    vapor = { default_temperature = 15, heat_capacity = 200 } }
  local function entity(kind, x, boxes, proto)
    local e = { valid = true, name = "opaque-" .. kind, type = kind, force = force, surface = surface,
      position = { x = x, y = 9 }, status = 3, unit_number = x, prototype = proto or {} }
    local links = {}
    e.fluidbox = {}
    for index, box in ipairs(boxes) do
      e.fluidbox[index] = box.fluid
      links[index] = {}
    end
    setmetatable(e.fluidbox, { __len = function() return #boxes end })
    e.get_fluid_box_prototype = function(index) return boxes[index] end
    e.fluidbox.get_filter = function(index)
      local box = boxes[index]
      return box.filter and { name = box.filter.name, minimum_temperature = box.minimum_temperature or -100,
        maximum_temperature = box.maximum_temperature or 1000 }
    end
    e.fluidbox.get_capacity = function() return 100 end
    e.fluidbox.get_fluid_segment_id = function(index) return x * 10 + index end
    e.fluidbox.get_fluid_segment_contents = function(index)
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
  local summary = map.map_summary({})
  local sample = map.factory_component_sample({ source_tick = game.tick, positions = { boiler.position } })
  check(#summary.factory.material_flow.edges == 3, "native connected fluidboxes create exact directed relationships including underground pipes")
  local output_edge
  for _, edge in ipairs(summary.factory.material_flow.edges) do
    if edge.from_fluidbox == 2 then output_edge = edge end
  end
  check(output_edge and output_edge.to_fluidbox == 1, "fluid relationships retain both box indices rather than entity adjacency")
  check(not canonical(sample.blockers):find("output_identity_unproven", 1, true),
    "empty native offshore and boiler boxes still establish product identity without recipes or stock")
  check(not canonical(summary):find("_fluid_boxes", 1, true) and not canonical(summary):find("_target_entity", 1, true),
    "private fluid samples and runtime entity references never escape map summary")
  local signature = sample._signature
  boiler.prototype.target_temperature = 170
  check(map.factory_component_sample({ source_tick = game.tick, positions = { boiler.position } })._signature ~= signature,
    "exact fluid component identity includes boiler output temperature")
  boiler.prototype.target_temperature = 165
  local old_force = generator.force
  generator.force = foreign_force
  local excluded = map.map_summary({})
  check(canonical(excluded.factory.material_flow.diagnostics):find("fluid_connected_target_unproven", 1, true) ~= nil,
    "native connected foreign-force target remains unproven")
  generator.force = old_force
  gl[1], pl[1] = {}, {}
  check(#map.map_summary({}).factory.material_flow.edges == 2, "disconnected pipe targets never become edges through proximity")
  surface.find_entities_filtered, prototypes.fluid = previous_find, previous_fluids
end

-- Supplied plant simulation: native per-tick pump/generator quantities,
-- conserved steam stock and burning fuel, actual electrical buffer draw and
-- recharge, and mined coal transported to fuel and material acceptance.
do
  local previous_find, old_fluids, old_coal = surface.find_entities_filtered, prototypes.fluid, prototypes.item.coal
  local function steam_validation(mode)
    game.tick = game.tick + 100
    local start = game.tick
    storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
    prototypes.item.coal = { name = "coal", fuel_value = 10000, fuel_category = "chemical" }
    prototypes.fluid = { aqua = { default_temperature = 15, heat_capacity = 1 },
      vapor = { default_temperature = 15, heat_capacity = 1 } }
    local steam, water, coal, accepted, fuel_items = 20, 20, 10, 0, 5
    local generated_total, relay_steam = 0, 20
    local electric = { electric_energy_source_prototype = { usage_priority = "secondary-input" } }
    local entities, connections, boxes_by_entity = {}, {}, {}
    local function make(kind, x, boxes, proto)
      local e = { valid = true, name = "supplied-" .. kind, type = kind, force = force, surface = surface,
        position = { x = x, y = 12 }, unit_number = 100 + x, status = 3, direction = 0, prototype = proto or {} }
      entities[#entities + 1] = e
      if boxes then
        boxes_by_entity[e], connections[e] = boxes, {}
        local fb = {}
        setmetatable(fb, { __len = function() return #boxes end, __index = function(_, index)
          if type(index) ~= "number" then return nil end
          local box = boxes[index]
          return { name = box.filter and box.filter.name or "vapor", temperature = box.segment == 1 and 15 or 165,
            amount = box.segment == 1 and water or box.segment == 3 and relay_steam or steam }
        end })
        fb.owner = e
        fb.get_pipe_connections = function(index) return connections[e][index] or {} end
        fb.get_filter = function(index)
          local box = boxes[index]
          return box.filter and { name = box.filter.name, minimum_temperature = box.minimum_temperature or -100,
            maximum_temperature = box.maximum_temperature or 1000 }
        end
        fb.get_capacity = function() return 1000 end
        fb.get_fluid_segment_id = function(index) return boxes[index].segment end
        fb.get_fluid_segment_contents = function(index)
          local box = boxes[index]
          return { [box.segment == 1 and "aqua" or "vapor"] = box.segment == 1 and water or box.segment == 3 and relay_steam or steam }
        end
        e.fluidbox = fb
        e.get_fluid_box_prototype = function(index) return boxes[index] end
      end
      return e
    end
    local function box(kind, name, segment) return { production_type = kind, filter = name and { name = name }, segment = segment } end
    local function link(a, ai, b, bi)
      connections[a][ai] = connections[a][ai] or {}
      connections[b][bi] = connections[b][bi] or {}
      table.insert(connections[a][ai], { position = a.position, target_position = b.position, connection_type = "normal",
        flow_direction = "output", target = b.fluidbox, target_fluidbox_index = bi })
      table.insert(connections[b][bi], { position = b.position, target_position = a.position, connection_type = "normal",
        flow_direction = "input", target = a.fluidbox, target_fluidbox_index = ai })
    end
    local source = make("offshore-pump", 1, { box("output", "aqua", 1) })
    source.get_fluid_source_fluid = function() return "aqua" end
    source.pumped_last_tick = 4
    local boiler = make("boiler", 2, { box("input", "aqua", 1), box("output", "vapor", 2) },
      { boiler_mode = "output-to-separate-pipe", target_temperature = 165,
        burner_prototype = { fuel_categories = { chemical = true } } })
    boiler.burner = { remaining_burning_fuel = 10000, currently_burning = {
      name = prototypes.item.coal, quality = { name = "normal" } } }
    boiler.get_fuel_inventory = function() return {
      get_contents = function() return { { name = "coal", quality = "normal", count = fuel_items } } end,
      get_item_count = function() return fuel_items end, can_insert = function() return fuel_items < 10 end } end
    local pipe = make("pipe-to-ground", 3, { box("none", nil, 2) })
    local generator = make("generator", 4, { box("input", "vapor", 2) },
      { burns_fluid = false, effectivity = 1, maximum_temperature = 165 })
    generator.electric_network_id, generator.energy_generated_last_tick = 7, 450
    link(source, 1, boiler, 1); link(boiler, 2, pipe, 1); link(pipe, 1, generator, 1)
    local pole = make("electric-pole", 5)
    pole.electric_network_id = 7
    pole.electric_network_statistics = setmetatable({}, { __index = function(_, key)
      if key == "input_counts" then return { [generator.name] = generated_total } end
    end })
    local target = { valid = true, name = "coal", type = "resource", position = { x = 6, y = 12 }, amount = 1000,
      prototype = { mineable_properties = { mining_time = 5 / 60, products = { { name = "coal", type = "item" } } } } }
    local mine = make("mining-drill", 6, nil, { mining_speed = 1, electric_energy_source_prototype = electric.electric_energy_source_prototype })
    mine.electric_network_id, mine.energy, mine.mining_target, mine.mining_progress = 7, 1000, target, 0
    local chest = make("container", 7)
    chest.get_inventory = function() return { get_item_count = function() return coal end, can_insert = function() return true end } end
    mine.drop_target = chest
    local refill = make("inserter", 8, nil, electric)
    refill.electric_network_id, refill.energy, refill.pickup_target, refill.drop_target = 7, 1000, chest, boiler
    local unload = make("inserter", 9, nil, electric)
    local terminal = make("container", 10)
    terminal.get_inventory = function() return { get_item_count = function() return accepted end, can_insert = function() return true end } end
    unload.electric_network_id, unload.energy, unload.pickup_target, unload.drop_target = 7, 1000, chest, terminal
    local extra_generator, steam_pump, water_buffer, other_boiler
    if mode == "fluid_buffer" or mode == "fluid_buffer_full" or mode == "fluid_buffer_wrong" then
      water_buffer = make("storage-tank", 11, { box("none", mode == "fluid_buffer_wrong" and "vapor" or "aqua", 1) })
      connections[source][1], connections[boiler][1] = {}, {}
      link(source, 1, water_buffer, 1)
    elseif mode == "ambiguous_boilers" then
      other_boiler = make("boiler", 11, { box("input", "aqua", 1), box("output", "vapor", 2) }, boiler.prototype)
      other_boiler.burner = { remaining_burning_fuel = 10000, currently_burning = boiler.burner.currently_burning }
      other_boiler.get_fuel_inventory = boiler.get_fuel_inventory
      local other_refill = make("inserter", 12, nil, electric)
      other_refill.electric_network_id, other_refill.energy = 7, 1000
      other_refill.pickup_target, other_refill.drop_target = chest, other_boiler
      link(source, 1, other_boiler, 1); link(other_boiler, 2, pipe, 1)
    end
    if mode == "multiple_generators" then
      extra_generator = make("generator", 11, { box("input", "vapor", 2) }, generator.prototype)
      extra_generator.electric_network_id, extra_generator.energy_generated_last_tick = 7, 225
      generator.energy_generated_last_tick = 225
      link(pipe, 1, extra_generator, 1)
    elseif mode == "steam_pump" then
      steam_pump = make("pump", 11, { box("input", "vapor", 2), box("output", "vapor", 3) }, electric)
      steam_pump.electric_network_id, steam_pump.energy, steam_pump.pumped_last_tick = 7, 1000, 4
      boxes_by_entity[generator][1].segment = 3
      connections[pipe][1], connections[boiler][2], connections[generator][1] = {}, {}, {}
      link(boiler, 2, pipe, 1); link(pipe, 1, steam_pump, 1); link(steam_pump, 2, generator, 1)
    end
    if mode == "presentation_caps" then
      connections[pipe][1], connections[boiler][2], connections[generator][1] = {}, {}, {}
      link(boiler, 2, pipe, 1)
      local previous = pipe
      for x = 11, 30 do
        local next_pipe = make("pipe", x, { box("none", nil, 2) })
        link(previous, 1, next_pipe, 1); previous = next_pipe
      end
      link(previous, 1, generator, 1)
    end
    if mode == "disconnected" then connections[pipe][1], connections[generator][1] = {}, {} end
    if mode == "wrong_fluid" then boxes_by_entity[generator][1].filter.name = "aqua" end
    if mode == "wrong_temperature" then boxes_by_entity[generator][1].minimum_temperature = 200 end
    if mode == "missing_network" then generator.electric_network_id = nil end
    if mode == "mismatched_network" then mine.electric_network_id, refill.electric_network_id, unload.electric_network_id = 8, 8, 8 end
    if mode == "foreign_force" then generator.force = foreign_force end
    if mode == "uncharted" then generator.position = { x = 1000, y = 12 } end
    if mode == "unsupported_counter" then generator.energy_generated_last_tick = nil end
    if mode == "unsupported_boiler" then boiler.prototype.boiler_mode = "heat-fluid-inside" end
    if mode == "unreadable_source" then source.get_fluid_source_fluid = function() error("unreadable source") end end
    surface.find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end
    map.map_summary({})
    local queued = tasks.queue_plan({ observation_detail = "none", steps = { { action = "validate_factory_component",
      source_tick = start, positions = { water_buffer and source.position or boiler.position }, duration_seconds = 1 } } })
    game.tick = start + 1; tasks.on_tick()
    local preflight = map.factory_component_sample({ source_tick = game.tick, positions = { water_buffer and source.position or boiler.position } })
    for tick = 1, 60 do
      game.tick = start + 1 + tick * (mode == "aliased_samples" and 2 or 1)
      mine.mining_progress = (tick % 5) / 5
      if tick % 5 == 0 then target.amount, coal = target.amount - 1, coal + 2 end
      if tick % 5 == 2 then coal, accepted = coal - 1, accepted + 1 end
      boiler.burner.remaining_burning_fuel = boiler.burner.remaining_burning_fuel - 600
      if boiler.burner.remaining_burning_fuel <= 0 then
        boiler.burner.remaining_burning_fuel, fuel_items = boiler.burner.remaining_burning_fuel + 10000, fuel_items - 1
      end
      if tick % 5 == 4 and fuel_items < 5 and mode ~= "no_fuel_refill" then fuel_items, coal = fuel_items + 1, coal - 1 end
      if mode == "starter_steam" then steam = steam - 3
      elseif mode == "steam_pump" then relay_steam = relay_steam + 1
      else steam = steam + 1 end
      if mode == "starter_water" then water, source.pumped_last_tick = water - 1, 0 end
      if water_buffer then water = mode == "fluid_buffer_full" and 1000 or water + 4 end
      if other_boiler then other_boiler.burner.remaining_burning_fuel = boiler.burner.remaining_burning_fuel end
      if mode ~= "unsupported_counter" then generator.energy_generated_last_tick = mode == "multiple_generators" and 225 or 450 end
      if mode == "inactive_generation" or mode == "generation_interruption" and tick >= 30 then generator.energy_generated_last_tick = 0 end
      generated_total = generated_total + (generator.energy_generated_last_tick or 0)
        + (extra_generator and extra_generator.energy_generated_last_tick or 0)
      if mode == "unobserved_supplier" then generated_total = generated_total + 10 end
      if mode == "full_endpoint" then steam = 1000 end
      for _, consumer in ipairs({ mine, refill, unload }) do
        consumer.energy = tick % 2 == 0 and 1000 or 850
        if mode == "starter_energy" then consumer.energy = 1000 - tick end
      end
      if steam_pump then steam_pump.energy = tick % 2 == 0 and 1000 or 999 end
      if mode == "topology_change" and tick == 20 then pipe.unit_number = 999 end
      if mode == "connection_change" and tick == 8 then connections[pipe][1][1].target_pipe_connection_index = 99 end
      if mode == "added_boiler" and tick == 8 then
        local added = make("boiler", 12, { box("input", "aqua", 1), box("output", "vapor", 2) }, boiler.prototype)
        added.burner, added.get_fuel_inventory = boiler.burner, boiler.get_fuel_inventory
        link(source, 1, added, 1); link(added, 2, pipe, 1)
      end
      if mode == "network_change" and tick == 20 then generator.electric_network_id = 9 end
      if mode == "transfer" and tick == 20 then
        require("scripts.factory_activity").record("insert", { target = chest, transfers = { { item = "coal", inserted = 1 } } })
      end
      tasks.on_tick()
    end
    local result = tasks.plan_status({ plan_id = queued.plan_id })
    local summary = map.map_summary({})
    return result, preflight, summary, { generator = generator, source = source, boiler = boiler, unload = unload, steam_pump = steam_pump }
  end
  local result, preflight, final, plant = steam_validation("supplied")
  check(preflight.topology_ready and result.status == "completed", "genuinely supplied native steam-power and accepted material segment proves autonomy")
  if result.status ~= "completed" then print("steam fixture diagnostics " .. canonical(result)) end
  check(final.factory.material_flow.components[1].state.autonomous_end_to_end
    and final.factory.material_flow.components[1].state.validation.fluid_activity_samples >= 3,
    "native proof is retained and drives current component autonomy with compact aggregate evidence")
  plant.generator.energy_generated_last_tick = 0
  check(not map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
    "current native autonomy revokes when the validated generator stops")
  plant.generator.energy_generated_last_tick, plant.source.pumped_last_tick = 450, 0
  check(not map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
    "current native autonomy revokes when its supplied water pump stops")
  plant.source.pumped_last_tick, plant.unload.energy = 4, 0
  check(not map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
    "current native autonomy revokes when its material consumer loses electrical energy")
  for _, mode in ipairs({ "multiple_generators", "steam_pump", "fluid_buffer" }) do
    local valid = steam_validation(mode)
    check(valid.status == "completed", "native proof supports " .. mode .. " with actual aggregate attribution/connectivity")
  end
  local pump_result, _, _, pump_plant = steam_validation("steam_pump")
  pump_plant.steam_pump.pumped_last_tick = 0
  check(pump_result.status == "completed" and not map.map_summary({}).factory.material_flow.components[1].state.autonomous_end_to_end,
    "current native autonomy revokes when its inline steam pump stops despite stored steam and electrical energy")
  for _, mode in ipairs({ "added_boiler", "connection_change" }) do
    local changed = steam_validation(mode)
    check(changed.status ~= "completed" and canonical(changed):find("component_topology_changed_during_validation", 1, true),
      "native " .. mode .. " returns structured topology-change evidence without a sampling fault")
  end
  local capped_result, _, capped = steam_validation("presentation_caps")
  check(capped_result.status == "completed" and capped.factory.omissions.capped_flow_nodes > 0,
    "native validation uses the full fluid/power graph independently of presentation caps")
  local serialized = canonical(final)
  check(not serialized:find("_native_activity", 1, true) and not serialized:find("segment_amount", 1, true)
    and not serialized:find("network_generation", 1, true) and not canonical(result):find("segment_amount", 1, true)
    and not canonical(result):find("_native_activity", 1, true), "native fluid/power quantities and attribution samples never escape map summary")
  for _, mode in ipairs({ "disconnected", "wrong_fluid", "wrong_temperature", "missing_network", "mismatched_network",
    "foreign_force", "uncharted", "unsupported_counter", "unsupported_boiler", "unreadable_source", "starter_steam",
    "starter_water", "starter_energy", "no_fuel_refill", "inactive_generation", "generation_interruption",
    "unobserved_supplier", "full_endpoint", "topology_change", "network_change", "transfer",
    "fluid_buffer_full", "fluid_buffer_wrong", "ambiguous_boilers", "aliased_samples" }) do
    local result = steam_validation(mode)
    check(result.status ~= "completed", "native steam-power proof rejects " .. mode)
  end
  surface.find_entities_filtered, prototypes.fluid, prototypes.item.coal = previous_find, old_fluids, old_coal
end

os.exit(failures == 0 and 0 or 1)
