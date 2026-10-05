-- Player-parity reads: map_summary include sections and remote
-- inspection. The fixture reproduces the cycle-8 blindness: a home factory that
-- fills the landmark cap, a remote oil site with a stocked chest, and own
-- entities in uncharted chunks that must stay hidden.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

_G.defines = {
  entity_status = { working = 1, no_power = 2, low_power = 3, no_fuel = 4, full_output = 5,
    no_minable_resources = 6, item_ingredient_shortage = 7, normal = 8, no_ingredients = 9 },
  flow_precision_index = { five_seconds = 0, one_minute = 1 },
  inventory = { fuel = 1, chest = 1, furnace_source = 2, furnace_result = 3,
    assembling_machine_input = 4, assembling_machine_output = 5 },
}
_G.prototypes = { tile = {}, item = {}, recipe = {}, entity = { ["steam-engine"] = { type = "generator" },
  ["solar-panel"] = { type = "solar-panel" }, accumulator = { type = "accumulator" } } }
_G.game = { tick = 4242 }
_G.storage = {}

local CHARTED = { ["0,0"] = true, ["1,0"] = true, ["10,10"] = true }
local ALL_CHUNKS = { { x = 0, y = 0 }, { x = 1, y = 0 }, { x = 10, y = 10 }, { x = 11, y = 10 }, { x = 20, y = 20 } }

local function statistics(produced, consumed, rate)
  return mock.flow_statistics({ input_counts = produced, output_counts = consumed,
    get_flow_count = function(query)
      assert(query.category == "input" or query.category == "output", "2.0 flow queries name a category")
      assert(query.count == false and query.precision_index ~= nil, "flow queries ask for a rate at a precision")
      return rate(query.name, query.category, query.precision_index)
    end })
end

local item_produced, item_consumed = { ["iron-plate"] = 1000, coal = 50, ["never-made"] = 0 }, { ["iron-plate"] = 400 }
for index = 1, 300 do item_produced[string.format("bulk-%03d", index)] = index end
local item_statistics = statistics(item_produced, item_consumed, function(name, category)
  if name ~= "iron-plate" then return 1 end
  return category == "input" and 30 or 12
end)
local fluid_statistics = statistics({ ["crude-oil"] = 9000 }, { ["crude-oil"] = 8000 }, function(_, category)
  return category == "input" and 600 or 540
end)

local surface
local foreign_force = mock.force({ name = "enemy" })
local force = mock.force({
  name = "player",
  is_chunk_charted = function(_, chunk) return CHARTED[chunk.x .. "," .. chunk.y] == true end,
  is_chunk_visible = function() return false end,
  get_item_production_statistics = function(target) assert(target == surface); return item_statistics end,
  get_fluid_production_statistics = function(target) assert(target == surface); return fluid_statistics end,
})

-- `spill` lists chunks whose area query also returns the entity: a native area
-- query matches a bounding box, so a wide machine centred in an uncharted
-- chunk is returned for its charted neighbour.
local world, next_unit, inventory_reads = {}, 0, 0
local function add(values, spill)
  next_unit = next_unit + 1
  values.valid, values.unit_number, values.direction = true, next_unit, values.direction or 0
  if values.force == nil then values.force = force end
  local entity = mock.entity(values)
  world[#world + 1] = { entity = entity, spill = spill }
  return entity
end
local function inventory(contents)
  local rows = {}
  for name, count in pairs(contents) do rows[#rows + 1] = { name = name, quality = "normal", count = count } end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return mock.inventory({
    get_contents = function() inventory_reads = inventory_reads + 1; return rows end,
    get_item_count = function(name) return contents[name] or 0 end,
    is_empty = function() return #rows == 0 end,
  })
end
local function chest(name, x, y, contents, owner)
  local stock = inventory(contents)
  return add({ name = name, type = "container", position = { x = x, y = y }, force = owner,
    get_inventory = function(index) return index == defines.inventory.chest and stock or nil end })
end
local function belt(x, y, contents, kind)
  local rows = {}
  for name, count in pairs(contents) do rows[#rows + 1] = { name = name, quality = "normal", count = count } end
  local line = mock.transport_line({ get_contents = function() return rows end,
    get_item_count = function(name) return contents[name] or 0 end })
  local empty = mock.transport_line({ get_contents = function() return {} end, get_item_count = function() return 0 end })
  return add({ name = kind or "transport-belt", type = kind or "transport-belt", position = { x = x, y = y },
    get_max_transport_line_index = function() return 2 end,
    get_transport_line = function(index) return index == 1 and line or empty end,
    belt_neighbours = { inputs = {}, outputs = {} } })
end
local function electric(per_tick_production, per_tick_usage)
  return mock.entity_prototype({ electric_energy_source_prototype = {},
    get_max_energy_production = function() return per_tick_production end,
    get_max_energy_usage = function() return per_tick_usage end,
  })
end

-- Home (chunk 0,0): enough walls to fill the 256-landmark cap on their own.
for index = 0, 259 do
  add({ name = "stone-wall", type = "wall", position = { x = index % 30 + 0.5, y = math.floor(index / 30) + 0.5 } })
end
local home_chest = chest("iron-chest", 5.5, 20.5, { ["iron-plate"] = 100 })
local furnace_output = inventory({ ["iron-plate"] = 40 })
add({ name = "stone-furnace", type = "furnace", position = { x = 8, y = 20 }, status = defines.entity_status.full_output,
  get_output_inventory = function() return furnace_output end,
  get_inventory = function(index) return index == defines.inventory.furnace_result and furnace_output or nil end })

-- Network 1 (home): one steam engine short of what its consumers ask for.
local home_statistics = statistics({ ["assembling-machine-1"] = 1, lab = 1 }, { ["steam-engine"] = 1 },
  function(name, category, precision)
    assert(precision == defines.flow_precision_index.five_seconds, "power reads the five-second window")
    if category == "output" then return 5000 end
    return name == "lab" and 2000 or 3000
  end)
add({ name = "small-electric-pole", type = "electric-pole", position = { x = 12.5, y = 22.5 },
  electric_network_id = 1, electric_network_statistics = home_statistics })
add({ name = "steam-engine", type = "generator", position = { x = 14.5, y = 24.5 }, status = defines.entity_status.working,
  electric_network_id = 1, prototype = electric(15000, 0) })
add({ name = "assembling-machine-1", type = "assembling-machine", position = { x = 18.5, y = 24.5 },
  status = defines.entity_status.low_power, electric_network_id = 1, prototype = electric(0, 10000) })
add({ name = "lab", type = "lab", position = { x = 22.5, y = 24.5 }, status = defines.entity_status.no_power,
  electric_network_id = 1, prototype = electric(0, 5000) })
add({ name = "accumulator", type = "accumulator", position = { x = 26, y = 24 }, electric_network_id = 1,
  energy = 2000000, electric_buffer_size = 5000000, prototype = electric(0, 0) })
add({ name = "assembling-machine-1", type = "assembling-machine", position = { x = 18.5, y = 28.5 },
  status = defines.entity_status.item_ingredient_shortage })

-- Chunk 1,0: a three-belt run whose last hop is an underground pair, a
-- separate belt, and unfuelled burner inserters. Native belt_neighbours does
-- not link the two ends of an underground pair; `neighbours` does.
local first, second, third = belt(40.5, 5.5, { ["iron-plate"] = 2 }),
  belt(41.5, 5.5, { ["iron-plate"] = 5 }, "underground-belt"), belt(42.5, 5.5, { ["iron-plate"] = 1 }, "underground-belt")
first.belt_neighbours = { inputs = {}, outputs = { second } }
second.belt_neighbours = { inputs = { first }, outputs = {} }
second.neighbours, third.neighbours = third, second
belt(50.5, 9.5, { ["copper-plate"] = 4, ["iron-plate"] = 3 })
for index = 0, 69 do
  add({ name = "burner-inserter", type = "inserter", position = { x = 33.5 + index % 20, y = 12.5 + math.floor(index / 20) },
    status = defines.entity_status.no_fuel })
end

-- Remote oil site (chunk 10,10), on its own healthy network.
local remote_statistics = statistics({ pumpjack = 1 }, { ["solar-panel"] = 1 }, function() return 1000 end)
add({ name = "medium-electric-pole", type = "electric-pole", position = { x = 328.5, y = 328.5 },
  electric_network_id = 2, electric_network_statistics = remote_statistics })
add({ name = "solar-panel", type = "solar-panel", position = { x = 326.5, y = 326.5 },
  electric_network_id = 2, prototype = electric(1000, 0) })
add({ name = "pumpjack", type = "mining-drill", position = { x = 332.5, y = 332.5 },
  status = defines.entity_status.working, electric_network_id = 2, prototype = electric(0, 1500) })
add({ name = "pumpjack", type = "mining-drill", position = { x = 338.5, y = 332.5 },
  status = defines.entity_status.no_minable_resources, electric_network_id = 2, prototype = electric(0, 1500) })
local remote_chest = chest("steel-chest", 330.5, 336.5, { ["plastic-bar"] = 77, ["iron-plate"] = 500 })

-- Charted but foreign, and own but uncharted.
local foreign_chest = chest("foreign-chest", 334.5, 340.5, { ["foreign-item"] = 5, ["iron-plate"] = 3 }, foreign_force)
local hidden_chest = chest("hidden-chest", 650.5, 650.5, { ["iron-plate"] = 9999, ["hidden-item"] = 1 })
add({ name = "hidden-drill", type = "mining-drill", position = { x = 652.5, y = 652.5 },
  status = defines.entity_status.no_fuel, electric_network_id = 9 })
local refinery_output = inventory({ ["leaked-item"] = 6, ["iron-plate"] = 60 })
local hidden_refinery = add({ name = "oil-refinery", type = "assembling-machine", position = { x = 353, y = 330.5 },
  status = defines.entity_status.full_output, electric_network_id = 8,
  get_output_inventory = function() return refinery_output end,
  get_inventory = function(index) return index == defines.inventory.assembling_machine_output and refinery_output or nil end,
}, { ["10,10"] = true })

local function resource(name, x, y, amount, spill)
  world[#world + 1] = { entity = mock.entity({ valid = true, name = name, type = "resource", amount = amount,
    position = { x = x, y = y } }), spill = spill }
end
resource("iron-ore", 3.5, 3.5, 100); resource("iron-ore", 4.5, 3.5, 200); resource("iron-ore", 31.5, 3.5, 300)
resource("iron-ore", 32.5, 3.5, 50) -- touching chunk: same patch
resource("iron-ore", 340.5, 345.5, 7) -- remote: a separate patch
resource("crude-oil", 332.5, 332.5, 1000); resource("crude-oil", 338.5, 332.5, 2000)
resource("uranium-ore", 352.5, 335.5, 123456, { ["10,10"] = true }) -- uncharted, returned to a charted query

local body = mock.entity({ valid = true, name = "character", type = "character", position = { x = 0, y = 0 }, force = force })
world[#world + 1] = { entity = body }

local function type_matches(filter, entity)
  if filter == nil then return true end
  if type(filter) == "string" then return entity.type == filter end
  for _, name in ipairs(filter) do if entity.type == name then return true end end
  return false
end
local entity_queries = 0
surface = mock.surface({
  name = "nauvis", index = 1,
  get_chunks = function()
    local index = 0
    return function() index = index + 1; return ALL_CHUNKS[index] end
  end,
  find_tiles_filtered = function() return {} end,
  find_entities_filtered = function(filter)
    entity_queries = entity_queries + 1
    local found = {}
    for _, record in ipairs(world) do
      local entity, position = record.entity, record.entity.position
      local inside = true
      if filter.area then
        local chunk = math.floor(filter.area[1][1] / 32) .. "," .. math.floor(filter.area[1][2] / 32)
        inside = position.x >= filter.area[1][1] and position.x < filter.area[2][1]
          and position.y >= filter.area[1][2] and position.y < filter.area[2][2]
          or record.spill ~= nil and record.spill[chunk] == true
      elseif filter.position then
        local dx, dy = position.x - filter.position.x, position.y - filter.position.y
        inside = math.sqrt(dx * dx + dy * dy) <= filter.radius
      end
      if inside and type_matches(filter.type, entity) and (filter.force == nil or entity.force == filter.force) then
        found[#found + 1] = entity
      end
    end
    return found
  end,
})
body.surface = surface
for _, record in ipairs(world) do record.entity.surface = surface end
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end,
  burning_item = dofile(here .. "/../../mod/agentic-companion/scripts/companion.lua").burning_item }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)

local map_summary = require("scripts.map_summary")
local function summarize(params) return require("scripts.jobs").run_now(map_summary.summary_job, params) end
local function row(rows, field, value)
  for _, candidate in ipairs(rows or {}) do if candidate[field] == value then return candidate end end
  return nil
end
local function holder(stock, entity) return stock and row(stock.holders, "entity", entity) end
local function names_anywhere(value, needle)
  if type(value) == "string" then return value:find(needle, 1, true) ~= nil end
  if type(value) ~= "table" then return false end
  for key, inner in pairs(value) do
    if names_anywhere(key, needle) or names_anywhere(inner, needle) then return true end
  end
  return false
end

-- Default output is unchanged and reads no remote inventory.
local plain = summarize({})
local plain_queries = entity_queries
check(plain.stockpiles == nil and plain.sites == nil and plain.patches == nil and plain.power == nil
  and plain.problems == nil and plain.force_flows_all == nil and plain.problems_total == nil
  and inventory_reads == 0 and plain.factory.evidence.entity_summary.exact_remote_inventories == false,
  "without include the summary adds no section and reads no inventory")
check(not pcall(map_summary.map_summary, { include = { "everything" } })
  and not pcall(map_summary.map_summary, { include = "sites" }),
  "an unknown or malformed include is rejected")

-- Patches come from the per-chunk patch cache (filled a few chunks a tick),
-- never from a resource scan per read.
require("scripts.state").init()
-- The surface's cache is made by the force's first chart of a chunk there.
game.get_surface = function(index) return index == 1 and surface or nil end
map_summary.on_chunk_charted({ force = force, surface_index = 1, position = { x = 0, y = 0 } })
-- The rows are rebuilt on the ticks after the reads, never by a read.
local function settled(cache) return cache.filled and not cache.build and not cache.dirty end
for tick = 1, 20 do map_summary.patch_tick(tick); if settled(storage.patch_caches[1]) then break end end
check(settled(storage.patch_caches[1]), "the surface's patch cache reads the charted chunks and builds their patches")
entity_queries = 0
local cached_patches = summarize({ include = { "patches" } })
check(entity_queries == plain_queries and #cached_patches.patches == 3 and cached_patches.patches_complete == true
  and cached_patches.patches_omitted == 0, "include patches reads the cache: no resource query per read")
-- Power rows come from the registry's network aggregates: entities are
-- registered as built, and the maintenance cursor reads their networks.
local registry = require("scripts.registry")
storage.registry.ready, storage.registry.force = true, "player"
for _, record in ipairs(world) do pcall(registry.add, record.entity) end
for tick = 1, 50 do registry.maintain(tick); if storage.registry.pass_tick then break end end
local everything = { "stockpiles", "sites", "patches", "power", "problems", "flows_all" }
local full = summarize({ detail = "full", include = everything })

-- Cycle 8: the landmark list is full, yet the remote site and its stock show.
check(#full.factory_landmarks == 256 and full.omitted_factory_landmarks > 0
  and row(full.factory_landmarks, "name", "pumpjack") == nil
  and row(full.factory_landmarks, "name", "steel-chest") == nil,
  "the fixture's landmark list is full and omits the remote oil site")
local oil_site
for _, site in ipairs(full.sites) do if site.chunk.x == 10 and site.chunk.y == 10 then oil_site = site end end
check(oil_site ~= nil and oil_site.machines.pumpjack == 2 and oil_site.position.x == 336 and oil_site.position.y == 333
  and full.sites_omitted == 0,
  "sites lists the remote oil site with its machines despite the full landmark list")
local home_site = full.sites[1]
check(#full.sites == 2 and home_site.chunk.x == 0 and home_site.chunk.y == 0 and home_site.machines["stone-furnace"] == 1
  and home_site.machines["assembling-machine-1"] == 2 and home_site.machines["steam-engine"] == 1
  and home_site.machines.lab == 1 and home_site.machines["stone-wall"] == nil,
  "sites groups own machines per charted chunk and counts machines only")

local plates, plastic = row(full.stockpiles, "item", "iron-plate"), row(full.stockpiles, "item", "plastic-bar")
check(plastic ~= nil and plastic.total == 77 and holder(plastic, "steel-chest").kind == "chest"
  and holder(plastic, "steel-chest").position.x == 330.5 and holder(plastic, "steel-chest").position.y == 336.5,
  "a remote chest's stock appears in stockpiles with its position")
check(plates.total == 100 + 40 + 500 + 8 + 3 and full.stockpiles[1] == plates
  and plates.holders[1].entity == "steel-chest" and plates.holders[1].count == 500
  and holder(plates, "iron-chest").count == 100 and holder(plates, "stone-furnace").kind == "machine_output"
  and holder(plates, "stone-furnace").count == 40 and plates.holders_omitted == 0 and full.stockpiles_omitted == 0,
  "stockpiles total chests and machine outputs, largest holder first")
local belt_holders = {}
for _, candidate in ipairs(plates.holders) do if candidate.kind == "belt" then belt_holders[#belt_holders + 1] = candidate end end
check(#belt_holders == 2 and belt_holders[1].count == 8 and belt_holders[1].position.x == 41.5
  and belt_holders[2].count == 3 and belt_holders[2].position.x == 50.5
  and belt_holders[1].entity == "underground-belt"
  and holder(row(full.stockpiles, "item", "copper-plate"), "transport-belt").count == 4,
  "a belt run joined through an underground pair is one holder at its fullest belt; a separate belt is its own holder")

check(#full.patches == 3 and full.patches[1].name == "crude-oil" and full.patches[1].amount == 3000
  and full.patches[1].tiles == 2 and full.patches[1].centroid.x == 335.5
  and full.patches[2].name == "iron-ore" and full.patches[2].amount == 650 and full.patches[2].tiles == 4
  and full.patches[2].bbox.left_top.x == 3 and full.patches[2].bbox.right_bottom.x == 33
  and full.patches[2].bbox.left_top.y == 3 and full.patches[2].bbox.right_bottom.y == 4
  and full.patches[3].name == "iron-ore" and full.patches[3].amount == 7 and full.patches_omitted == 0,
  "patches sum amounts and tiles, merge touching chunks and keep distant ones apart")

local home, oil = full.power.networks[1], full.power.networks[2]
check(#full.power.networks == 2 and full.power.networks_omitted == 0 and home.network_id == 1 and oil.network_id == 2,
  "power reports each electric network once")
check(home.production_w == 300000 and home.capacity_w == 900000 and home.demand_w == 900000
  and home.satisfaction == 0.333 and #home.sources == 1 and home.sources[1].kind == "steam"
  and home.sources[1].count == 1 and home.sources[1].nameplate_w == 900000 and home.sources[1].production_w == 300000
  and home.accumulators.stored_j == 2000000 and home.accumulators.capacity_j == 5000000 and home.accumulators.charge == 0.4
  and home.sustained_w == 900000 and home.headroom_w == 0 and home.add_to_cover == nil and home.engines_needed == nil,
  "a starved network reports native production by source, nameplate capacity, accumulators and satisfaction below 1")
check(oil.production_w == 60000 and oil.capacity_w == 60000 and oil.satisfaction == 1 and oil.demand_w == 90000
  and oil.sources[1].kind == "solar" and oil.sources[1].count == 1 and oil.accumulators == nil
  and oil.sustained_w == 42000 and oil.add_to_cover.solar_panel == 2 and oil.add_to_cover.accumulator > 0,
  "a healthy remote solar network reports satisfaction 1 and what covers its day average")

local function problem(status) return row(full.problems, "status", status) end
check(full.problems_total == 75 and #full.problems == 64
  and problem("full_output").entity == "stone-furnace" and problem("low_power").entity == "assembling-machine-1"
  and problem("no_power").entity == "lab" and problem("no_minable_resources").entity == "pumpjack"
  and problem("no_minable_resources").position.x == 338.5
  and problem("no_fuel").entity == "burner-inserter"
  and full.problems[1].status == "no_power" and full.problems[4].entity ~= "burner-inserter"
  and full.problems[5].entity == "burner-inserter" and problem("item_ingredient_shortage") == nil,
  "problems name each blocked machine's status, cap at 64 with the total, machines before inserters, input waits last")
local by_status, by_status_sum = full.problems_by_status, 0
for _, count in pairs(by_status) do by_status_sum = by_status_sum + count end
check(by_status.no_fuel == 70 and by_status.no_power == 1 and by_status.low_power == 1 and by_status.full_output == 1
  and by_status.no_minable_resources == 1 and by_status.item_ingredient_shortage == 1
  and by_status_sum == full.problems_total,
  "problems_by_status counts every problem per status, including rows the cap left out")

local all_flows = full.force_flows_all
check(#all_flows == 256 and full.force_flows_all_omitted == 303 - 256 and #full.factory.force_flows <= 12
  and row(all_flows, "name", "never-made") == nil,
  "force_flows_all lifts the row cap only for itself and skips zero lifetime flow")
local plate_flow, oil_flow = row(all_flows, "name", "iron-plate"), row(all_flows, "name", "crude-oil")
check(all_flows[1] == oil_flow and oil_flow.kind == "fluid" and oil_flow.produced_per_minute == 600
  and oil_flow.consumed_per_minute == 540 and oil_flow.lifetime_produced == 9000 and oil_flow.lifetime_consumed == 8000
  and plate_flow.kind == "item" and plate_flow.produced_per_minute == 30 and plate_flow.consumed_per_minute == 12
  and plate_flow.lifetime_produced == 1000 and plate_flow.lifetime_consumed == 400,
  "force_flows_all reads rates and lifetime counts from the native surface statistics")

-- Mutation guard: without the per-entity charted-chunk filter the refinery
-- centred in uncharted chunk 11,10 (returned by chunk 10,10's area query)
-- leaks into every section.
local leaked = {}
for _, needle in ipairs({ "hidden", "leaked", "oil-refinery", "uranium", "foreign" }) do
  if names_anywhere(full, needle) then leaked[#leaked + 1] = needle end
end
check(#leaked == 0, "uncharted and foreign entities appear in no section (leaked: " .. table.concat(leaked, ",") .. ")")

-- Sections add no entity query beyond the per-chunk scan.
entity_queries = 0
summarize({ include = { "stockpiles", "sites", "power", "problems", "flows_all" } })
check(entity_queries == plain_queries, "entity sections reuse the existing per-chunk scan")
local only_sites = summarize({ include = { "sites" } })
check(only_sites.sites ~= nil and only_sites.stockpiles == nil and only_sites.power == nil and only_sites.patches == nil,
  "only the requested sections are computed")

-- Remote inspection.
local inspect = require("scripts.inspect")
local inspected = inspect.inspect({ targets = {
  { x = 330.5, y = 336.5 }, -- own chest in a charted chunk, far away
  { x = 5.5, y = 20.5 }, -- own chest within the local radius
  { x = 650.5, y = 650.5 }, -- own chest in an uncharted chunk
  { x = 334.5, y = 340.5 }, -- foreign chest in a charted chunk
  { x = 351.9, y = 330.5 }, -- charted position beside an own machine centred in an uncharted chunk
  { x = 332.5, y = 332.5 }, -- own pumpjack standing on a resource
  { x = 340.5, y = 345.5 }, -- a bare resource in a charted chunk
} })
check(inspected.evidence_class == "fresh_exact_local_and_charted_remote"
  and inspected.scope == "within_30_tiles_or_own_force_charted_at_source_tick",
  "an inspect result holding a remote entity does not claim a local-only scope")
inspected = inspected.entities
local local_only = inspect.inspect({ targets = { { x = 5.5, y = 20.5 }, { x = 650.5, y = 650.5 } } })
check(local_only.evidence_class == "fresh_local_exact" and local_only.scope == "within_30_tiles_of_codex_at_source_tick"
  and local_only.entities[2].error ~= nil,
  "an inspect result without a remote entity keeps the local envelope, even beside a refused remote target")
check(inspected[1].remote == true and inspected[1].name == "steel-chest"
  and inspected[1].inventories.main["plastic-bar"] == 77 and inspected[1].error == nil,
  "remote inspect reads a charted own entity and marks it remote")
check(inspected[2].name == "iron-chest" and inspected[2].remote == nil and inspected[2].inventories.main["iron-plate"] == 100,
  "local inspect is unchanged and not marked remote")
check(inspected[3].name == nil and inspected[3].inventories == nil and inspected[3].error:find("within 30 tiles", 1, true) ~= nil,
  "remote inspect refuses an own entity in an uncharted chunk")
check(inspected[4].name == nil and inspected[4].inventories == nil and inspected[4].error == inspected[3].error,
  "remote inspect refuses a foreign entity with the same refusal")
check(inspected[5].name == nil and inspected[5].error == inspected[3].error,
  "remote inspect refuses an own entity whose centre is uncharted")
check(inspected[6].remote == true and inspected[6].name == "pumpjack" and inspected[6].status == "working",
  "remote inspect resolves the own machine, not the resource under it")
check(inspected[7].name == nil and inspected[7].error == inspected[3].error,
  "remote inspect does not read bare resources")
local queries_before_hidden = entity_queries
inspect.inspect({ targets = { { x = 650.5, y = 650.5 } } })
check(entity_queries == queries_before_hidden, "an uncharted remote position is refused without querying the surface")
check(home_chest.valid and remote_chest.valid and foreign_chest.valid and hidden_chest.valid and hidden_refinery.valid,
  "reads leave the fixture untouched")

-- Input waits past the cap: 70 idle furnaces north of five unfuelled drills.
-- Ordered by position alone they would take all 64 rows.
for index = 0, 69 do
  add({ name = "stone-furnace", type = "furnace", position = { x = index % 30 + 0.5, y = 10.5 + math.floor(index / 30) },
    status = defines.entity_status.no_ingredients })
end
for index = 0, 4 do
  add({ name = "burner-mining-drill", type = "mining-drill", position = { x = index * 2 + 1, y = 30 },
    status = defines.entity_status.no_fuel })
end
local crowded = summarize({ include = { "problems" } })
local unfuelled_drills = 0
for _, candidate in ipairs(crowded.problems) do
  if candidate.entity == "burner-mining-drill" and candidate.status == "no_fuel" then unfuelled_drills = unfuelled_drills + 1 end
end
check(crowded.problems_total == 150 and #crowded.problems == 64 and unfuelled_drills == 5
  and row(crowded.problems, "status", "no_power") ~= nil and row(crowded.problems, "status", "full_output") ~= nil
  and row(crowded.problems, "status", "no_ingredients") == nil
  and crowded.problems_by_status.no_ingredients == 70 and crowded.problems_by_status.no_fuel == 75,
  "input waits never evict unpowered, unfuelled or output-blocked rows from the problems cap")

mock.assert_clean()
if failures > 0 then error(failures .. " player parity check(s) failed") end
print("ALL PLAYER PARITY TESTS PASSED")
