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
  get_tile = function(x) return { collides_with = function(layer) return (layer == "water_tile" or layer == "player") and x >= 16 end } end,
  find_entities_filtered = function(filter) if filter.type == "resource" then return resources end; return { machine, foreign_machine, invalid_machine, body } end,
}
body.surface = surface
package.loaded["scripts.companion"] = { require_companion = function() return body end }
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
    status = 2, products_finished = 5 }
  if not buffer_root then source.mining_target = { prototype = { mineable_properties = {
    products = { { name = "ore", type = "item" } },
  } } } end
  local processor = { valid = true, name = "processor", type = "assembling-machine",
    position = { x = 3, y = 1 }, force = force, status = 2, products_finished = 10,
    burner = burner and {} or nil, crafting_speed = 1,
    get_recipe = function() return { name = "process", energy = 1,
      ingredients = { { name = "ore", type = "item" } }, products = { { name = "plate", type = "item" } } } end }
  if burner then processor.prototype = { burner_prototype = { fuel_categories = { chemical = true } } } end
  local sink = { valid = true, name = "lab", type = "lab", position = { x = 5, y = 1 }, force = force, status = 3 }
  local feed = { valid = true, name = "feed", type = "inserter", position = { x = 2, y = 1 }, force = force,
    status = 2, pickup_target = source, drop_target = processor }
  local unload = { valid = true, name = "unload", type = "inserter", position = { x = 4, y = 1 }, force = force,
    status = 2, pickup_target = processor, drop_target = sink }
  if not buffer_root then source.drop_target = feed end
  return { source, feed, processor, unload, sink }, source, processor
end

_G.prototypes = { item = { coal = { fuel_value = 8, fuel_category = "chemical" } } }
defines.entity_status.normal = 2
defines.entity_status.working = 3
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
  start_tick = 900, end_tick = 960, duration_ticks = 60, products_finished_delta = 2,
  character_transfer_actions = 0 })
game.tick = 960
local proven = require("scripts.map_summary").map_summary({ activity_since_tick = 900 })
check(proven.factory.material_flow.components[1].state.autonomous_end_to_end
  and proven.factory.material_flow.components[1].state.validation.products_finished_delta == 2,
  "matching bounded multi-tick validation promotes the unchanged component to autonomous end to end")
require("scripts.factory_activity").record("insert", { target = flow_processor,
  transfers = { { item = "ore", inserted = 1 } } })
local touched = require("scripts.map_summary").map_summary({ activity_since_tick = 900 })
check(not touched.factory.material_flow.components[1].state.autonomous_end_to_end
  and touched.factory.material_flow.components[1].state.autonomy_evidence == "character_transfer_observed",
  "a later character transfer revokes unattended autonomy for that component")

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
os.exit(failures == 0 and 0 or 1)
