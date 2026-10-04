-- The event-maintained registry of own entities (registry.lua), its bootstrap
-- spread over ticks on an upgraded save, the reads built on it (chores fuel,
-- autonomy lines, factory_status power and stock) making no entity query, and
-- map_summary's per-chunk patch cache. Entities, forces and the surface are
-- strict 2.0.77 mocks; every find_entities_filtered call is counted.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local RAW = { working = 1, no_fuel = 2, normal = 3, no_power = 4, no_ingredients = 5 }
_G.defines = { entity_status = RAW, inventory = { chest = 1, fuel = 2, furnace_source = 3 },
  target_type = { entity = 7, gui_element = 9 } }
_G.prototypes = { item = { coal = { stack_size = 50 }, wood = { stack_size = 100 } }, recipe = {}, entity = {} }
_G.game = { tick = 0 }
_G.storage = {}
local registered = {}
_G.script = { register_on_object_destroyed = function(entity)
  registered[#registered + 1] = entity
  return #registered, entity.unit_number, defines.target_type.entity
end }

-- World: charted chunks (0..9, 0); chunk (20, 20) is not charted yet.
local CHARTED = {}
for x = 0, 9 do CHARTED[x .. ",0"] = true end
local ALL_CHUNKS = {}
for x = 0, 9 do ALL_CHUNKS[#ALL_CHUNKS + 1] = { x = x, y = 0 } end
ALL_CHUNKS[#ALL_CHUNKS + 1] = { x = 20, y = 20 }

local world, finds = {}, { all = 0, resource = 0, own = 0 }
local chunk_lists = 0
local surface
local force = mock.force({ name = "player",
  is_chunk_charted = function(target, chunk) assert(target == surface); return CHARTED[chunk.x .. "," .. chunk.y] == true end })
local enemy = mock.force({ name = "enemy" })
local function in_area(position, area)
  return position.x >= area[1][1] and position.x < area[2][1] and position.y >= area[1][2] and position.y < area[2][2]
end
surface = mock.surface({ index = 1, name = "nauvis",
  get_chunks = function()
    chunk_lists = chunk_lists + 1
    local i = 0
    return function() i = i + 1; return ALL_CHUNKS[i] end
  end,
  find_entities_filtered = function(filter)
    finds.all = finds.all + 1
    assert(filter.area and filter.area[2][1] - filter.area[1][1] == 32 and filter.area[2][2] - filter.area[1][2] == 32,
      "every entity query names one chunk, never the whole surface")
    if filter.type == "resource" then finds.resource = finds.resource + 1 else finds.own = finds.own + 1 end
    local found = {}
    for _, entity in ipairs(world) do
      if entity.valid and in_area(entity.position, filter.area)
        and (filter.force == nil or entity.force == filter.force)
        and (filter.type == nil or entity.type == filter.type) then
        found[#found + 1] = entity
      end
    end
    return found
  end })
local body = { valid = true, position = { x = 0, y = 0 }, force = force, surface = surface, crafting_queue_size = 0,
  get_item_count = function() return 0 end,
  get_main_inventory = function() return { get_contents = function() return {} end } end }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end,
  human_control = function() return false, 999 end }

local next_unit = 0
local function inventory(contents)
  return mock.inventory({
    get_contents = function()
      local rows = {}
      for name, count in pairs(contents) do rows[#rows + 1] = { name = name, quality = "normal", count = count } end
      table.sort(rows, function(a, b) return a.name < b.name end)
      return rows
    end,
    get_item_count = function(name) return contents[name] or 0 end,
  })
end
local ELECTRIC = {}
local function entity(values)
  next_unit = next_unit + 1
  values.valid, values.unit_number = true, values.unit_number or next_unit
  values.force = values.force or force
  values.surface = surface
  values.status = values.status or RAW.working
  local production = values.production
  if values.electric or production then
    values.prototype = mock.entity_prototype({ electric_energy_source_prototype = ELECTRIC,
      get_max_energy_usage = function() return 1000 end,
      get_max_energy_production = function() return production or 0 end })
  else
    values.prototype = mock.entity_prototype({ name = values.name })
  end
  values.electric, values.production = nil, nil
  local e = mock.entity(values)
  world[#world + 1] = e
  return e
end
local stone = {}
local function furnace(x, y, contents, status)
  return entity({ name = "stone-furnace", type = "furnace", position = { x = x, y = y }, burner = {},
    status = status, products_finished = 0, get_recipe = function() return nil end,
    get_output_inventory = function() return inventory(contents or {}) end,
    get_inventory = function() return inventory({}) end })
end
local function chest(x, y, contents, owner)
  return entity({ name = "wooden-chest", type = "container", position = { x = x, y = y }, force = owner,
    get_inventory = function() return inventory(contents) end })
end
local ore = {}
local function resource(name, x, y, amount)
  local e = mock.entity({ valid = true, name = name, type = "resource", position = { x = x, y = y }, amount = amount,
    prototype = mock.entity_prototype({ name = name }) })
  world[#world + 1] = e
  ore[#ore + 1] = e
  return e
end

-- Chunk 0: a dry burner furnace with plates out, a coal chest. Chunk 1: a
-- burner drill. Chunk 2: belts. Chunk 3: steam power, a pole, an assembler,
-- an inserter. Chunk 4: an enemy chest. Chunk 5: a ghost. Chunk 6: walls,
-- enough to end that tick's budget.
local dry = furnace(1.5, 1.5, { ["iron-plate"] = 12 }, RAW.no_fuel)
local coal_chest = chest(4.5, 4.5, { coal = 30, wood = 5 })
local drill = entity({ name = "burner-mining-drill", type = "mining-drill", position = { x = 33, y = 1 }, burner = {},
  mining_progress = 0 })
for i = 1, 3 do entity({ name = "transport-belt", type = "transport-belt", position = { x = 64.5 + i, y = 0.5 } }) end
local pole = entity({ name = "small-electric-pole", type = "electric-pole", position = { x = 96.5, y = 0.5 },
  electric_network_id = 5 })
local engine = entity({ name = "steam-engine", type = "generator", position = { x = 100, y = 2 }, production = 15000,
  electric_network_id = 5 })
local assembler = entity({ name = "assembling-machine-1", type = "assembling-machine", position = { x = 104.5, y = 4.5 },
  electric = true, electric_network_id = 5, status = RAW.no_power, products_finished = 0,
  get_recipe = function() return nil end, get_output_inventory = function() return inventory({ ["iron-gear-wheel"] = 4 }) end })
local inserter = entity({ name = "inserter", type = "inserter", position = { x = 108.5, y = 0.5 }, electric = true,
  electric_network_id = 5, status = RAW.working })
chest(128.5, 0.5, { coal = 999 }, enemy)
entity({ name = "entity-ghost", type = "entity-ghost", position = { x = 160.5, y = 0.5 } })
for i = 1, 450 do stone[i] = entity({ name = "stone-wall", type = "wall", position = { x = 192.5 + i % 30, y = 0.5 + math.floor(i / 30) } }) end
-- Resources: one iron patch across chunks 0 and 1, copper in chunk 8,
-- uranium in uncharted chunk (20, 20).
for i = 0, 3 do resource("iron-ore", 28.5 + i, 10.5, 100) end
resource("iron-ore", 32.5, 10.5, 100); resource("iron-ore", 33.5, 10.5, 100)
for i = 0, 2 do resource("copper-ore", 260.5 + i, 3.5, 50) end
local uranium = resource("uranium-ore", 650.5, 650.5, 70)

local state = require("scripts.state")
local registry = require("scripts.registry")
state.init()
check(storage.registry and storage.registry.ready == false and storage.patch_cache and storage.patch_cache.seeded == false,
  "state.init creates the registry (not ready) and the patch cache")

-- Bootstrap: the first tick lists charted chunks only; then at most four
-- chunks a tick, fewer once 400 entities were read.
local per_tick = {}
for tick = 1, 10 do
  game.tick = tick
  local before = finds.own
  registry.on_tick(tick)
  per_tick[#per_tick + 1] = finds.own - before
  if registry.ready() then break end
end
check(per_tick[1] == 0 and per_tick[2] == 4 and per_tick[3] == 3 and per_tick[4] == 3 and #per_tick == 4
  and registry.ready() and storage.registry.ready_tick == 4,
  "the bootstrap reads the ten charted chunks over three ticks, a few chunks a tick (" .. table.concat(per_tick, ",") .. ")")
local counts = registry.counts()
check(counts.registry_ready and counts.machines == 4 and counts.belts == 3 and counts.entities == 7,
  "bootstrap keeps machines, holders, burners and electric entities, counts belts, and skips walls, ghosts and other forces ("
    .. counts.entities .. " entries)")
local listed = {}
for _, set in ipairs({ "holders", "burners", "electric", "poles" }) do
  local names = {}
  for _, entry in ipairs(registry.list(set)) do names[#names + 1] = entry.name end
  listed[set] = table.concat(names, ",")
end
check(listed.holders == "stone-furnace,wooden-chest,assembling-machine-1"
  and listed.burners == "stone-furnace,burner-mining-drill"
  and listed.electric == "small-electric-pole,steam-engine,assembling-machine-1,inserter"
  and listed.poles == "small-electric-pole", "each set lists its own entities in unit order")
check(#registered == 10, "every kept entity and belt is registered for on_object_destroyed (" .. #registered .. ")")
finds.all = 0
check(registry.any({ "generator", "burner-generator", "solar-panel" }) and not registry.any({ "solar-panel", "burner-generator" })
  and finds.all == 0, "whether the force generates power is read from the registry with no entity query")
check(chunk_lists == 1 and #storage.registry.charted_seed == 10, "the bootstrap lists the surface's chunks once and keeps the charted ones")

-- Build, clone and remove events keep it current.
local built = furnace(2.5, 6.5)
registry.on_built({ entity = built })
check(#registry.machines({ "furnace" }) == 2 and registered[#registered] == built, "a built machine is added and registered")
check(registry.add(built) == false and #registry.machines({ "furnace" }) == 2, "adding again is a no-op")
local clone = furnace(7.5, 6.5)
registry.on_built({ source = built, destination = clone })
check(#registry.machines({ "furnace" }) == 3, "a cloned entity is added")
local foreign = chest(10.5, 10.5, { coal = 5 }, enemy)
registry.on_built({ entity = foreign })
check(#registry.list("holders") == 5, "another force's entity is never added")
local belt = entity({ name = "transport-belt", type = "transport-belt", position = { x = 12.5, y = 12.5 } })
registry.on_built({ entity = belt })
check(registry.counts().belts == 4 and storage.registry.entries[belt.unit_number] == nil, "a belt is counted, not listed")
registry.on_removed({ entity = built })
check(#registry.machines({ "furnace" }) == 2 and storage.registry.entries[built.unit_number] == nil,
  "a mined machine is removed")
registry.on_object_destroyed({ type = defines.target_type.gui_element, useful_id = clone.unit_number })
check(#registry.machines({ "furnace" }) == 2 and storage.registry.entries[clone.unit_number] ~= nil,
  "another object type's destroy event changes nothing")
registry.on_object_destroyed({ type = defines.target_type.entity, useful_id = clone.unit_number })
registry.on_object_destroyed({ type = defines.target_type.entity, useful_id = belt.unit_number })
check(storage.registry.entries[clone.unit_number] == nil and registry.counts().belts == 3,
  "on_object_destroyed removes an entity and uncounts a belt")
clone.valid = false
check(#registry.machines({ "furnace" }) == 1, "an entity gone without an event is dropped on read")

-- Reads after the bootstrap make no entity query.
package.loaded["scripts.research"] = { progression_status = function() return { available = {} } end }
local queued = {}
package.loaded["scripts.tasks"] = { queue_length = function() return 0 end, active_summary = function() return nil end,
  queue_plan = function(params) queued[#queued + 1] = params; return { plan_id = #queued } end }
storage.tasks.last_finished_tick = 1
local autonomy = require("scripts.autonomy")
local chores = require("scripts.chores")
local map_summary = require("scripts.map_summary")
local factory_status = require("scripts.factory_status")
finds.all = 0
for tick = 5, 700 do game.tick = tick; autonomy.on_tick(tick) end
local lines = autonomy.lines()
check(#lines == 4 and finds.all == 0, "autonomy builds its lines from the registry with no entity query ("
  .. #lines .. " lines, " .. finds.all .. " queries)")
chores.upkeep(game.tick)
check(#queued == 1 and queued[1].steps[1].items.coal == 10 and queued[1].steps[1].x == 1.5 and finds.all == 0,
  "upkeep refuels the dry furnace from registry stock with no entity query")
-- Stock and power come from a cache refreshed a few entities a tick; a read
-- before its first refresh says so instead of scanning.
for i = 1, 100 do registry.on_built({ entity = chest(40.5 + i % 50, 20.5 + math.floor(i / 50), {}) }) end
local early = factory_status.factory_status({ sections = { "stock", "power" } })
check(early.stock_power_ready == false and #early.stock == 0 and #early.power == 0 and early.stock_power_tick == nil,
  "before the first refresh factory_status reports stock and power not ready, without scanning")
local per_tick, refresh_ticks = {}, 0
for tick = 701, 760 do
  game.tick = tick
  local job = storage.status_cache.job
  local before = job and #job.own or 0
  map_summary.status_tick(tick)
  refresh_ticks = refresh_ticks + 1
  job = storage.status_cache.job
  if job then per_tick[#per_tick + 1] = #job.own - before end
  if storage.status_cache.updated_tick then break end
end
local most = 0
for _, n in ipairs(per_tick) do most = math.max(most, n) end
check(finds.all == 0 and storage.status_cache.updated_tick == 700 + refresh_ticks and refresh_ticks >= 4
  and most <= map_summary.STATUS_ENTITIES_PER_TICK and storage.status_cache.job == nil,
  "the stock and power cache reads at most " .. map_summary.STATUS_ENTITIES_PER_TICK
    .. " entities a tick over " .. refresh_ticks .. " ticks with no entity query (most " .. most .. ")")
local refreshed_at = storage.status_cache.updated_tick
for tick = refreshed_at + 1, refreshed_at + 299 do game.tick = tick; map_summary.status_tick(tick) end
check(storage.status_cache.job == nil and storage.status_cache.updated_tick == refreshed_at,
  "the next refresh waits 300 ticks")
local status = factory_status.factory_status({})
local coal_row, gear_row
for _, row in ipairs(status.stock) do
  if row.item == "coal" then coal_row = row end
  if row.item == "iron-gear-wheel" then gear_row = row end
end
check(finds.all == 0 and status.registry_ready == true and coal_row and coal_row.total == 30
  and gear_row and gear_row.holders[1].kind == "machine_output" and #status.power == 1
  and status.power[1].network_id == 5 and status.power[1].capacity_w == 900000 and status.power[1].satisfaction < 1
  and status.stock_power_ready and status.stock_power_tick == refreshed_at,
  "factory_status stock and power come from the registry with no entity query")
check(status.patches_ready == false and #status.patches == 0, "patches say not ready before the cache is filled")
local snapshot_factory = map_summary.registry_factory()
check(finds.all == 0 and snapshot_factory.machine_count == 4 and snapshot_factory.belt_count == 3
  and snapshot_factory.power.network_count == 1 and snapshot_factory.registry_ready,
  "the recorder's factory counts come from the registry with no entity query")

-- Patch cache: seeded on the first tick, then two chunks a tick.
local resource_reads = {}
for tick = 1000, 1010 do
  game.tick = tick
  local before = finds.resource
  map_summary.patch_tick(tick)
  resource_reads[#resource_reads + 1] = finds.resource - before
  if storage.patch_cache.filled then break end
end
check(resource_reads[1] == 0 and resource_reads[2] == 2 and resource_reads[6] == 2 and resource_reads[7] == 0
  and storage.patch_cache.filled, "the patch cache reads the ten charted chunks two a tick (" .. table.concat(resource_reads, ",") .. ")")
check(chunk_lists == 1 and storage.registry.charted_seed == nil,
  "the patch cache is seeded from the bootstrap's chunk list without listing the surface again")
finds.all = 0
local patches, ready = map_summary.patches()
local by_name = {}
for _, patch in ipairs(patches) do by_name[patch.name] = patch end
check(ready and finds.all == 0 and by_name["iron-ore"].tiles == 6 and by_name["iron-ore"].amount == 600
  and by_name["copper-ore"].tiles == 3 and by_name["uranium-ore"] == nil,
  "patches join touching chunks, read from the cache with no entity query, and stay inside charted land")

-- Depletion: the chunk is read again on a later tick.
local depleted = ore[1]
map_summary.on_resource_depleted({ entity = depleted })
depleted.valid = false
game.tick = 1101
local before = finds.resource
map_summary.patch_tick(game.tick)
patches = map_summary.patches()
for _, patch in ipairs(patches) do by_name[patch.name] = patch end
check(finds.resource == before + 1 and by_name["iron-ore"].tiles == 5 and by_name["iron-ore"].amount == 500,
  "a depleted resource invalidates its chunk only")

-- Charting: a newly charted chunk of the own force is read; another
-- force's charting is ignored.
map_summary.on_chunk_charted({ force = enemy, surface_index = 1, position = { x = 20, y = 20 } })
check(#storage.patch_cache.pending - storage.patch_cache.head + 1 == 0, "another force's charted chunk is ignored")
CHARTED["20,20"] = true
map_summary.on_chunk_charted({ force = force, surface_index = 1, position = { x = 20, y = 20 } })
game.tick = 1102
map_summary.patch_tick(game.tick)
patches = map_summary.patches()
by_name = {}
for _, patch in ipairs(patches) do by_name[patch.name] = patch end
check(by_name["uranium-ore"] and by_name["uranium-ore"].amount == 70, "a newly charted chunk's resources join the patches")
for _ = 1, 3 do map_summary.on_chunk_charted({ force = force, surface_index = 1, position = { x = 20, y = 20 } }) end
check(storage.patch_cache.head > #storage.patch_cache.pending, "a re-charted chunk is not read again")

-- Idle refresh: one cached resource chunk every 120 ticks so mining shows.
uranium.amount = 40
before = finds.resource
for tick = 1103, 1103 + 120 * 4 - 1 do game.tick = tick; map_summary.patch_tick(tick) end
patches = map_summary.patches()
for _, patch in ipairs(patches) do by_name[patch.name] = patch end
check(finds.resource - before == 4 and by_name["uranium-ore"].amount == 40,
  "while idle one cached resource chunk is read again every 120 ticks (" .. (finds.resource - before) .. " reads)")

-- An upgraded save without a registry gets a fresh one, which bootstraps.
storage.registry = nil
state.init()
check(storage.registry.ready == false and storage.registry.bootstrap.chunks == nil, "an upgrade starts a new bootstrap")
local kept = storage.registry
state.init()
check(storage.registry == kept, "a repeated init keeps the registry")

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
