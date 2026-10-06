-- A run that has never left Nauvis behaves as it did on 0.22.2, in cost and
-- in results (the multi-surface work of 0.22.3 must not touch it). One
-- Nauvis-only factory, upgraded in place from a 0.22.2 save (its single
-- patch cache), goes through the registry bootstrap, the line sampler, the
-- maintenance pass, the patch cache, upkeep, a default factory_status and a
-- map_summary with every section. Each phase's engine calls (entity
-- queries, chart checks, live state and inventory reads, statistics reads,
-- work items) and each result, serialized with sorted keys, are compared to
-- the values this same scenario gave on 0.22.2 (recorded by running this
-- file against the 0.22.2 mod). The only result differences allowed are the
-- fields 0.22.3 adds, which the comparison names and drops: factory_status
-- `surface`, map_summary `surface` and `factory.surface`. The additive
-- upkeep selection is asserted separately before comparing retained fields.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local RAW = { working = 1, no_fuel = 2, normal = 3, no_power = 4, no_ingredients = 5, low_power = 6,
  no_minable_resources = 7, full_output = 8 }
_G.defines = { entity_status = RAW, inventory = { chest = 1, fuel = 2, furnace_source = 3, cargo_landing_pad_main = 4,
  crafter_input = 5, lab_input = 6 }, target_type = { entity = 7, gui_element = 9 },
  flow_precision_index = { five_seconds = 0, one_minute = 1, ten_minutes = 2, one_hour = 3 } }
_G.prototypes = { item = { coal = { stack_size = 50 }, wood = { stack_size = 100 }, ["iron-plate"] = { stack_size = 100 },
  ["iron-gear-wheel"] = { stack_size = 100 } }, recipe = {}, entity = { ["steam-engine"] = { type = "generator" } },
  -- Upkeep's fuels by category (0.22.3) through the engine's item filter.
  get_item_filtered = function() return { coal = {}, wood = {} } end }
_G.game = { tick = 0 }
_G.storage = {}
_G.script = { register_on_object_destroyed = function(entity) return entity.unit_number, entity.unit_number, 7 end }

-- Engine calls, by kind.
local calls = { finds = 0, charted = 0, live = 0, contents = 0, statistics = 0, chunk_lists = 0 }
local CHARTED = {}
for x = 0, 9 do CHARTED[x .. ",0"] = true end
local ALL_CHUNKS = {}
for x = 0, 9 do ALL_CHUNKS[#ALL_CHUNKS + 1] = { x = x, y = 0 } end
local world = {}
local surface
local force = mock.force({ name = "player", technologies = {}, research_queue = {}, research_progress = 0,
  is_chunk_charted = function(target, chunk)
    assert(target == surface, "every chart check is Nauvis's")
    calls.charted = calls.charted + 1
    return CHARTED[chunk.x .. "," .. chunk.y] == true
  end,
  get_item_production_statistics = function()
    calls.statistics = calls.statistics + 1
    return mock.flow_statistics({ input_counts = { ["iron-plate"] = 120 }, output_counts = { coal = 40 },
      get_flow_count = function(query) return query.name == "iron-plate" and 2 or 0 end })
  end,
  get_fluid_production_statistics = function()
    calls.statistics = calls.statistics + 1
    return mock.flow_statistics({ input_counts = {}, output_counts = {}, get_flow_count = function() return 0 end })
  end })
local function in_area(position, area)
  local lt, rb = area.left_top or area[1], area.right_bottom or area[2]
  return position.x >= (lt.x or lt[1]) and position.x < (rb.x or rb[1]) and position.y >= (lt.y or lt[2]) and position.y < (rb.y or rb[2])
end
surface = mock.surface({ index = 1, name = "nauvis", valid = true,
  get_chunks = function()
    calls.chunk_lists = calls.chunk_lists + 1
    local i = 0
    return function() i = i + 1; return ALL_CHUNKS[i] end
  end,
  find_entities_filtered = function(filter)
    calls.finds = calls.finds + 1
    local found = {}
    for _, e in ipairs(world) do
      if e.valid and (filter.area == nil or in_area(e.position, filter.area))
        and (filter.force == nil or e.force == filter.force)
        and (filter.type == nil or e.type == filter.type or type(filter.type) == "table" and filter.type[1] == e.type)
        and (filter.name == nil or e.name == filter.name) then
        found[#found + 1] = e
      end
    end
    return found
  end,
  get_property = function() return 100 end, daytime = 0.5, always_day = true, solar_power_multiplier = 1 })
game.get_surface = function(index) return index == 1 and surface or nil end
game.surfaces = { nauvis = surface }

-- The body stands in its character on Nauvis: the companion module's
-- accessors as 0.22.2 and 0.22.3 both call them.
local main = mock.inventory({ get_contents = function() return { { name = "coal", quality = "normal", count = 7 } } end,
  get_item_count = function(name) return name == "coal" and 7 or 0 end })
local body = { valid = true, name = "character", position = { x = 2, y = 2 }, force = force, surface = surface,
  surface_index = 1, crafting_queue_size = 0, reach_distance = 10,
  get_item_count = function(name) return name == "coal" and 7 or 0 end,
  get_main_inventory = function() return main end }
local present = { state = "on_surface", force = force, surface = surface, surface_ref = "nauvis", position = { x = 2, y = 2 },
  character = body }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end,
  require_present = function() return present end, body = function() return present end,
  anchor = function() return { surface = surface, position = present.position, force = force, state = "on_surface",
    surface_ref = "nauvis" } end,
  surface_ref = function(s) return s and s.name end, human_control = function() return false, 999 end,
  body_summary = function() return { state = "on_surface", surface_ref = "nauvis" } end,
  burning_item = function() return nil end }
local queued = {}
package.loaded["scripts.tasks"] = { queue_length = function() return 0 end, active_summary = function() return nil end,
  queue_plan = function(params) queued[#queued + 1] = params; return { plan_id = #queued } end }
package.loaded["scripts.research"] = { research_trigger = function() return nil end, unit_time_s = function() return nil end,
  progression_status = function() return { researched = {} } end }

-- The factory: a dry furnace with plates out, a coal chest, a burner drill,
-- belts, steam power with a pole, an unpowered assembler, an inserter, and
-- iron and copper ore.
local next_unit = 0
local function inventory(contents)
  return mock.inventory({
    get_contents = function()
      calls.contents = calls.contents + 1
      local rows = {}
      for name, count in pairs(contents) do rows[#rows + 1] = { name = name, quality = "normal", count = count } end
      table.sort(rows, function(a, b) return a.name < b.name end)
      return rows
    end,
    get_item_count = function(name) return contents[type(name) == "table" and name.name or name] or 0 end,
  })
end
local ELECTRIC = {}
local live = {}
local LIVE_KEYS = { "status", "electric_network_id", "energy" }
local function entity(values)
  next_unit = next_unit + 1
  values.valid, values.unit_number = true, next_unit
  values.force = values.force or force
  values.surface, values.surface_index = surface, 1
  values.status = values.status or RAW.working
  local production = values.production
  if values.electric or production then
    values.prototype = mock.entity_prototype({ name = values.name, type = values.type, electric_energy_source_prototype = ELECTRIC,
      get_max_energy_usage = function() return 1000 end,
      get_max_energy_production = function() return production or 0 end })
  else
    values.prototype = mock.entity_prototype({ name = values.name, type = values.type })
  end
  values.electric, values.production = nil, nil
  local current = {}
  for _, key in ipairs(LIVE_KEYS) do current[key], values[key] = values[key], nil end
  local e = mock.entity(values)
  live[e] = current
  for _, key in ipairs(LIVE_KEYS) do
    mock.read(e, key, function() calls.live = calls.live + 1; return live[e][key] end)
  end
  world[#world + 1] = e
  return e
end
local function furnace(x, y, contents, status)
  return entity({ name = "stone-furnace", type = "furnace", position = { x = x, y = y },
    burner = { fuel_categories = { chemical = true } }, status = status, products_finished = 0,
    get_recipe = function() return nil end, get_output_inventory = function() return inventory(contents or {}) end,
    get_inventory = function() return inventory({}) end })
end
furnace(1.5, 1.5, { ["iron-plate"] = 12 }, RAW.no_fuel)
furnace(6.5, 1.5, { ["iron-plate"] = 3 })
entity({ name = "wooden-chest", type = "container", position = { x = 4.5, y = 4.5 },
  get_inventory = function() return inventory({ coal = 30, wood = 5 }) end })
entity({ name = "burner-mining-drill", type = "mining-drill", position = { x = 33, y = 1 }, burner = {}, mining_progress = 0 })
for i = 1, 3 do entity({ name = "transport-belt", type = "transport-belt", position = { x = 64.5 + i, y = 0.5 } }) end
local pole = entity({ name = "small-electric-pole", type = "electric-pole", position = { x = 96.5, y = 0.5 }, electric_network_id = 5 })
entity({ name = "steam-engine", type = "generator", position = { x = 100, y = 2 }, production = 15000, electric_network_id = 5 })
entity({ name = "assembling-machine-1", type = "assembling-machine", position = { x = 104.5, y = 4.5 }, electric = true,
  electric_network_id = 5, status = RAW.no_power, products_finished = 0, get_recipe = function() return nil end,
  get_output_inventory = function() return inventory({ ["iron-gear-wheel"] = 4 }) end })
entity({ name = "inserter", type = "inserter", position = { x = 108.5, y = 0.5 }, electric = true, electric_network_id = 5 })
pole.electric_network_statistics = mock.flow_statistics({ output_counts = { ["steam-engine"] = 1 },
  get_flow_count = function() calls.statistics = calls.statistics + 1; return 600 end })
for i = 0, 3 do
  world[#world + 1] = mock.entity({ valid = true, name = "iron-ore", type = "resource", position = { x = 28.5 + i, y = 10.5 },
    amount = 100, surface_index = 1, prototype = mock.entity_prototype({ name = "iron-ore" }) })
end
for i = 0, 2 do
  world[#world + 1] = mock.entity({ valid = true, name = "copper-ore", type = "resource", position = { x = 260.5 + i, y = 3.5 },
    amount = 50, surface_index = 1, prototype = mock.entity_prototype({ name = "copper-ore" }) })
end

-- A 0.22.2 save: its one patch cache (Nauvis's), never read yet.
storage.patch_cache = { version = 1, seeded = false, filled = false, chunks = {}, known = {}, pending = {}, head = 1,
  queued = {}, refresh = {}, dirty = true, rows = nil, updated_tick = nil, charted = {}, charted_set = {}, build = nil }

-- Deterministic text of a value (sorted keys; numbers to 6 significant digits).
local function text(value)
  local kind = type(value)
  if kind == "number" then return string.format("%.6g", value) end
  if kind ~= "table" then return tostring(value) end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. text(value[key]) end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function snapshot()
  local copy = {}
  for key, value in pairs(calls) do copy[key] = value end
  return copy
end
local function spent(before)
  local parts = {}
  for _, key in ipairs({ "finds", "charted", "live", "contents", "statistics", "chunk_lists" }) do
    parts[#parts + 1] = key .. "=" .. (calls[key] - before[key])
  end
  return table.concat(parts, " ")
end

local state = require("scripts.state")
local registry = require("scripts.registry")
local autonomy = require("scripts.autonomy")
local chores = require("scripts.chores")
local map_summary = require("scripts.map_summary")
local factory_status = require("scripts.factory_status")
local jobs = require("scripts.jobs")
state.init()
storage.tasks.last_finished_tick = 1

local measured = {}
-- 1. The registry bootstrap, a few chunks a tick.
local before, ticks = snapshot(), 0
for tick = 1, 20 do game.tick = tick; ticks = ticks + 1; registry.on_tick(tick); if registry.ready() then break end end
measured.bootstrap = spent(before) .. " ticks=" .. ticks
-- 2. The line sampler.
before = snapshot()
for tick = 21, 700 do game.tick = tick; autonomy.on_tick(tick) end
measured.sampler = spent(before) .. " lines=" .. #autonomy.lines()
-- 3. The maintenance pass.
before, ticks = snapshot(), 0
for tick = 701, 800 do game.tick = tick; ticks = ticks + 1; map_summary.status_tick(tick); if storage.registry.pass_tick then break end end
measured.maintenance = spent(before) .. " ticks=" .. ticks
-- 4. The patch cache, two chunks a tick, and its rows.
before, ticks = snapshot(), 0
for tick = 801, 840 do
  game.tick = tick; ticks = ticks + 1; map_summary.patch_tick(tick)
  local cache = storage.patch_caches and storage.patch_caches[1] or storage.patch_cache
  if cache.filled and not cache.build and not cache.dirty then break end
end
measured.patches = spent(before) .. " ticks=" .. ticks
-- 5. Upkeep.
before = snapshot()
chores.upkeep(game.tick)
measured.upkeep = spent(before) .. " plan=" .. text(queued)
-- 6. The default factory_status read.
before = snapshot()
local status = factory_status.factory_status({})
measured.status_cost = spent(before)
local dropped = { "factory_status.surface", "map_summary.surface and factory.surface" }
status.surface = nil
local upkeep_selection = status.body and status.body.upkeep_selection
check(upkeep_selection and upkeep_selection.tick == game.tick
  and upkeep_selection.queue_status == "queued" and upkeep_selection.refuel.selected[1].count == 10,
  "the additive body readback retains exact bounded upkeep selection without extra native reads")
if status.body then status.body.upkeep_selection = nil end
measured.status = text(status)
-- 7. map_summary with every section, as one job.
before = snapshot()
local summary, job_ticks = jobs.run_now(map_summary.summary_job, { detail = "aggregate", flow_precision = "one_minute",
  include = { "stockpiles", "sites", "patches", "power", "problems", "flows_all" } })
measured.summary_cost = spent(before) .. " ticks=" .. job_ticks
summary.surface = nil
if summary.factory then summary.factory.surface = nil end
summary.tick, summary.source_tick = nil, nil
measured.summary = text(summary)

-- `texlua tests/mod/nauvis_unchanged_test.lua record` prints this
-- scenario's values; fixtures/nauvis-0.22.2.lua holds them as the 0.22.2 mod
-- gave them.
if arg and arg[1] == "record" then
  local names = {}
  for name in pairs(measured) do names[#names + 1] = name end
  table.sort(names)
  print("return {")
  for _, name in ipairs(names) do print(string.format("  %s = %q,", name, measured[name])) end
  print("}")
  os.exit(0)
end
local EXPECTED = dofile(here .. "/fixtures/nauvis-0.22.2.lua")
for _, name in ipairs({ "bootstrap", "sampler", "maintenance", "patches", "upkeep", "status_cost", "summary_cost" }) do
  check(measured[name] == EXPECTED[name], name .. " costs what it did on 0.22.2 (" .. measured[name] .. ")")
end
check(measured.status == EXPECTED.status, "the retained factory_status fields match 0.22.2, apart from surface and additive upkeep evidence")
check(measured.summary == EXPECTED.summary, "map_summary with every section is 0.22.2's, but for " .. dropped[2])
if measured.status ~= EXPECTED.status then print(measured.status); print(EXPECTED.status) end
if measured.summary ~= EXPECTED.summary then print(measured.summary); print(EXPECTED.summary) end

mock.assert_clean()
print(failures == 0 and "\nALL NAUVIS UNCHANGED TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
