-- Own entities, kept by events so no read, chore or line refresh scans the
-- force. Every RCON command and every on_tick handler runs inside one game
-- tick on the server and every client, so a whole-force query freezes all of
-- them; this registry is what those paths read instead.
--
-- Kept per entity (by unit_number, own force only, on every surface; each
-- entry names its surface index):
--   machines  by type (the line sampler's machine types, the planet machines
--             among them, plus beacons, roboports and burner inserters,
--             which it samples for problems only)
--   holders   chests, cargo landing pads and crafting-machine outputs (stock)
--   burners   entities with a burner (fuel)
--   electric  poles, producers, accumulators and electric consumers (power)
--   belts     counted, never listed: no read walks belts
-- Added on the build, revive and clone events and directly where the mod
-- itself creates an entity; removed on the mined, died and destroy events and
-- through script.register_on_object_destroyed. An upgraded save fills it once
-- by a bootstrap spread over ticks, a few charted chunks of the body's
-- surface per tick; until that ends `ready` is false and reads say so.
-- Factory surfaces (surfaces()) are the surfaces with own entries; a deleted
-- surface takes its aggregates with it (on_surface_deleted).
--
-- Reads name a surface by index (or "all"); without one they read the body's
-- anchor surface (companion.anchor: its physical surface, the hub aboard).
--
-- Aggregates (what factory_status and map_summary's power rows read, never
-- by walking entities): per surface, every type's count and nameplate sum
-- (and for labs the sum of their research speeds);
-- per electric network, its sources by kind, accumulators, the nominal demand
-- of its consumers that try to run, and a pole for its statistics; per
-- surface, every item's stock in own holders with its largest holder, keyed
-- by items.key (a non-normal quality is "name@quality"). Build
-- and remove events update them at once. A maintenance cursor (maintain,
-- MAINTAIN_WORK_PER_TICK work items a tick) walks the entries in a ring and
-- refreshes what changes without an event: network ids (they change when
-- poles connect or split networks), consumer status, accumulator charge,
-- holder contents and lab speed. pass_tick is when the last full pass ended.
local companion = require("scripts.companion")
local jobs = require("scripts.jobs")
local surfaces = require("scripts.surfaces")
local items = require("scripts.items")

local M = {}

-- Work budgets count items, never time (Lua has no clock).
M.BOOTSTRAP_CHUNKS_PER_TICK = 4
M.BOOTSTRAP_ENTITIES_PER_TICK = 400
M.MAINTAIN_WORK_PER_TICK = 64
M.RESCAN_CHUNKS_PER_TICK = 4

-- Productive machines make something and form factory lines.
-- The planet machines are of these types too: foundries, electromagnetic and
-- cryogenic plants, biochambers, crushers and captive spawners are
-- assembling machines, the recycler a furnace, the heating tower a reactor.
local PRODUCTIVE_TYPES = {
  ["mining-drill"] = true, furnace = true, ["assembling-machine"] = true, ["rocket-silo"] = true,
  lab = true, boiler = true, generator = true, ["burner-generator"] = true, ["offshore-pump"] = true,
  reactor = true, ["fusion-reactor"] = true, ["fusion-generator"] = true, ["lightning-attractor"] = true,
  ["agricultural-tower"] = true, ["asteroid-collector"] = true,
}
-- Sampled for problems only: no product, never a line. Inserters only with
-- a burner (BURNER_ONLY_TYPES): a dry one strands what it should move, and
-- upkeep refuels it; electric inserters are no machine.
local PROBLEM_ONLY_TYPES = { beacon = true, roboport = true, inserter = true }
local BURNER_ONLY_TYPES = { inserter = true }
local MACHINE_TYPES = {}
for kind in pairs(PRODUCTIVE_TYPES) do MACHINE_TYPES[kind] = true end
for kind in pairs(PROBLEM_ONLY_TYPES) do MACHINE_TYPES[kind] = true end
M.MACHINE_TYPES, M.PRODUCTIVE_TYPES, M.PROBLEM_ONLY_TYPES = MACHINE_TYPES, PRODUCTIVE_TYPES, PROBLEM_ONLY_TYPES
M.BURNER_ONLY_TYPES = BURNER_ONLY_TYPES

-- Whether an entity of this type, with a burner or not, is a machine.
function M.is_machine(kind, burner)
  return MACHINE_TYPES[kind] == true and (not BURNER_ONLY_TYPES[kind] or burner == true)
end
local CHEST_TYPES = { container = true, ["logistic-container"] = true }
-- Stores whose items the body takes: their inventory by type (a crafting
-- machine's is its output).
local STORE_INVENTORY = { container = "chest", ["logistic-container"] = "chest",
  ["cargo-landing-pad"] = "cargo_landing_pad_main" }
M.STORE_INVENTORY = STORE_INVENTORY
local OUTPUT_TYPES = { furnace = true, ["assembling-machine"] = true, ["rocket-silo"] = true }
local BELT_TYPES = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
  loader = true, ["loader-1x1"] = true, ["linked-belt"] = true }
local SKIPPED_TYPES = { character = true, ["entity-ghost"] = true, ["tile-ghost"] = true }
local SETS = { "holders", "burners", "electric", "poles" }
-- Electric producers by power kind; a generator built for steam hotter than
-- an engine's 165 degrees is a turbine, counted as nuclear.
local SOURCE_TYPES = { ["solar-panel"] = "solar", generator = "steam", ["burner-generator"] = "burner",
  ["fusion-generator"] = "fusion", ["lightning-attractor"] = "lightning" }
local ENGINE_STEAM_DEGREES = 165
-- Consumer statuses that draw (or ask for) work power.
local DRAWING = { working = true, low_power = true, no_power = true }
local STARVED = { low_power = true, no_power = true }

local function data() return storage and storage.registry end

function M.ready()
  local r = data()
  return r ~= nil and r.ready == true
end

local function own_force_name(r)
  if r.force then return r.force end
  local c = companion.get()
  local ok, name = pcall(function() return c and c.valid and c.force.name end)
  return ok and name or "player"
end

local function electric(entity)
  if entity.type == "electric-pole" then return true end
  local ok, source = pcall(function() return entity.prototype.electric_energy_source_prototype end)
  return ok and source ~= nil
end

local function number(read)
  local ok, value = pcall(read)
  return ok and type(value) == "number" and value or nil
end

local status_names
local function status_name(entity)
  local ok, status = pcall(function() return entity.status end)
  if not ok or status == nil then return nil end
  if not status_names then
    status_names = {}
    for name, value in pairs((defines and defines.entity_status) or {}) do status_names[value] = name end
  end
  return status_names[status]
end

-- The power kind of an entity type: solar, steam, nuclear, burner,
-- accumulator (discharge) or other; the prototype tells a turbine.
local function kind_for(type_name, prototype)
  if type_name == "accumulator" then return "accumulator" end
  local kind = SOURCE_TYPES[type_name] or "other"
  if kind == "steam" then
    local degrees = number(function() return prototype.maximum_temperature end)
    if degrees and degrees > ENGINE_STEAM_DEGREES then kind = "nuclear" end
  end
  return kind
end

-- The power kind of an entity prototype name (output_counts rows are keyed
-- by name), cached per name.
local kinds = {}
function M.power_kind(name)
  local kind = kinds[name]
  if kind then return kind end
  local ok, prototype = pcall(function() return prototypes.entity[name] end)
  local ok_type, type_name = pcall(function() return prototype.type end)
  kind = ok and ok_type and kind_for(type_name, prototype) or "other"
  kinds[name] = kind
  return kind
end

-- Nameplate production or nominal usage in watts, cached per name and
-- quality (get_max_energy_production and get_max_energy_usage are joules a
-- tick).
local nameplates = {}
local function nameplate(entity, method)
  local ok, quality = pcall(function() return entity.quality.name end)
  quality = ok and type(quality) == "string" and quality or "normal"
  local key = entity.name .. "\0" .. quality .. "\0" .. method
  local watts = nameplates[key]
  if watts == nil then
    watts = (number(function() return entity.prototype[method](quality) end) or 0) * 60
    nameplates[key] = watts
  end
  return watts
end

-- A lab's base research speed: its prototype's at its quality, cached per
-- name and quality.
local lab_bases = {}
local function lab_base(entity)
  local ok, quality = pcall(function() return entity.quality.name end)
  quality = ok and type(quality) == "string" and quality or "normal"
  local key = entity.name .. "\0" .. quality
  local speed = lab_bases[key]
  if speed == nil then
    speed = number(function() return entity.prototype.get_researching_speed(quality) end) or 0
    lab_bases[key] = speed
  end
  return speed
end

-- The share of a pack a lab drains per unit (the biolab's is 0.5), cached
-- per name.
local lab_drains = {}
local function lab_drain(entity)
  local drain = lab_drains[entity.name]
  if drain == nil then
    drain = (number(function() return entity.prototype.science_pack_drain_rate_percent end) or 100) / 100
    lab_drains[entity.name] = drain
  end
  return drain
end

-- A lab's sums in its surface's lab row: research speed, packs drained (speed
-- x drain) and research progress (speed x (1 + productivity)).
local LAB_SUMS = { "research_speed", "pack_rate", "progress_rate" }

-- ------------------------------------------------------------- aggregates

local function type_row(r, surface, kind)
  local by_type = r.types[surface or 0]
  if not by_type then by_type = {}; r.types[surface or 0] = by_type end
  local row = by_type[kind]
  if not row then row = { count = 0, nameplate_w = 0 }; by_type[kind] = row end
  return row
end

local function network_of(r, id, surface)
  local net = r.networks[id]
  if not net then
    net = { id = id, surface = surface, members = 0, sources = {}, demand_w = 0, starved = 0,
      accumulators = { count = 0, capacity_j = 0, stored_j = 0 } }
    r.networks[id] = net
  end
  return net
end

-- Adds (sign 1) or takes back (sign -1) an entry's share of its network.
local function share(r, entry, net, sign)
  net.members = net.members + sign
  if entry.role == "source" then
    local source = net.sources[entry.power_kind] or { count = 0, nameplate_w = 0 }
    net.sources[entry.power_kind] = source
    source.count, source.nameplate_w = source.count + sign, source.nameplate_w + sign * (entry.nominal_w or 0)
  elseif entry.role == "accumulator" then
    local a = net.accumulators
    a.count, a.capacity_j = a.count + sign, a.capacity_j + sign * (entry.buffer_j or 0)
    a.stored_j = a.stored_j + sign * (entry.stored_j or 0)
  elseif entry.role == "consumer" then
    net.demand_w = net.demand_w + sign * (entry.demand_w or 0)
    net.starved = net.starved + sign * (entry.starved and 1 or 0)
  end
end

local function leave_network(r, entry)
  local net = entry.network and r.networks[entry.network]
  if net then
    if entry.role == "pole" then
      if net.pole == entry.entity then net.pole = nil end
    else
      share(r, entry, net, -1)
    end
  end
  entry.network = nil
end

local function join_network(r, entry, id)
  entry.network = id
  if not id then return end
  local net = network_of(r, id, entry.surface)
  if entry.role == "pole" then
    if not (net.pole and net.pole.valid) then net.pole = entry.entity end
  else
    share(r, entry, net, 1)
  end
end

local function stock_of(r, surface)
  local stock = r.stock[surface or 0]
  if not stock then stock = {}; r.stock[surface or 0] = stock end
  return stock
end

-- Replaces a holder's contribution with `contents` ({[item] = count}).
local function restock(r, entry, contents)
  local stock = stock_of(r, entry.surface)
  local old = entry.stock or {}
  for item, count in pairs(old) do
    if not contents[item] then
      local row = stock[item]
      if row then
        row.total = row.total - count
        if row.unit == entry.unit then row.unit, row.count = nil, 0 end
        if row.total <= 0 then stock[item] = nil end
      end
    end
  end
  for item, count in pairs(contents) do
    local row = stock[item]
    if not row then row = { total = 0, count = 0 }; stock[item] = row end
    row.total = row.total + count - (old[item] or 0)
    -- The largest holder seen: kept until a fuller one is read.
    if row.unit == entry.unit or count > row.count then row.unit, row.count = entry.unit, count end
  end
  entry.stock = next(contents) and contents or nil
end

-- Network, power role and nameplate, once per entry (on add, or on the
-- first maintenance visit of an entry an older version registered).
local function classify(r, entry)
  entry.classified = true
  local entity, kind = entry.entity, entry.type
  if kind == "electric-pole" then
    entry.role = "pole"
  elseif kind == "accumulator" then
    entry.role = "accumulator"
    entry.buffer_j = number(function() return entity.electric_buffer_size end) or 0
  elseif SOURCE_TYPES[kind] then
    local kind_of = kinds[entry.name]
    if not kind_of then
      local ok, prototype = pcall(function() return entity.prototype end)
      kind_of = kind_for(kind, ok and prototype or nil)
      kinds[entry.name] = kind_of
    end
    entry.role, entry.power_kind = "source", kind_of
    entry.nominal_w = nameplate(entity, "get_max_energy_production")
  elseif r.electric[entry.unit] then
    entry.role, entry.nominal_w = "consumer", nameplate(entity, "get_max_energy_usage")
  end
  if entry.role == "source" then
    local row = type_row(r, entry.surface, kind)
    row.nameplate_w = row.nameplate_w + entry.nominal_w
  end
end

-- The one chart rule (surfaces.charted): all of a platform's surface counts
-- as charted.
local function chunk_charted(entry)
  local ok, value = pcall(function()
    local entity = entry.entity
    return surfaces.charted(entity.force, entity.surface, math.floor(entry.position.x / 32),
      math.floor(entry.position.y / 32))
  end)
  return ok and value == true
end

-- What a holder offers: a chest's or landing pad's contents or a crafting
-- machine's output.
function M.holder_inventory(entity)
  local ok, inventory = pcall(function()
    local id = STORE_INVENTORY[entity.type]
    if id then return entity.get_inventory(defines.inventory[id]) end
    return entity.get_output_inventory()
  end)
  return ok and inventory or nil
end

function M.holder_kind(entry)
  if entry.type == "cargo-landing-pad" then return "landing_pad" end
  return CHEST_TYPES[entry.type] and "chest" or "machine_output"
end

-- Re-reads one entry's changing state into the aggregates. Returns the work
-- items it cost (about one per engine call).
local function visit(r, entry)
  local entity = entry.entity
  if not (entity and entity.valid) then M.remove(entry.unit); return 1 end
  local cost = 1
  if not entry.classified then classify(r, entry); cost = cost + 3 end
  if not entry.charted then entry.charted = chunk_charted(entry); cost = cost + 1 end
  if entry.role then
    local id = entry.charted and number(function() return entity.electric_network_id end) or nil
    cost = cost + 1
    leave_network(r, entry)
    if entry.role == "consumer" and id then
      local status = status_name(entity)
      entry.demand_w = DRAWING[status] and entry.nominal_w or 0
      entry.starved = STARVED[status] == true
      cost = cost + 1
    elseif entry.role == "accumulator" and id then
      entry.stored_j = number(function() return entity.energy end) or 0
      cost = cost + 1
    end
    join_network(r, entry, id)
  end
  if entry.type == "lab" then
    -- speed_bonus and productivity_bonus each sum the force's lab research
    -- bonus, modules and beacons.
    entry.lab_base = entry.lab_base or lab_base(entity)
    entry.lab_drain = entry.lab_drain or lab_drain(entity)
    local speed = entry.lab_base * (1 + (number(function() return entity.speed_bonus end) or 0))
    local productivity = number(function() return entity.productivity_bonus end) or 0
    local sums = { research_speed = speed, pack_rate = speed * entry.lab_drain,
      progress_rate = speed * (1 + productivity) }
    local row = type_row(r, entry.surface, "lab")
    for _, key in ipairs(LAB_SUMS) do
      row[key] = (row[key] or 0) + sums[key] - (entry[key] or 0)
      entry[key] = sums[key]
    end
    cost = cost + 3
  end
  if r.holders[entry.unit] then
    local contents = {}
    if entry.charted then
      local inventory = M.holder_inventory(entity)
      local ok, rows = pcall(function() return inventory and inventory.get_contents() or {} end)
      for _, row in ipairs(ok and rows or {}) do
        if type(row.name) == "string" then
          local key = items.key(row.name, row.quality)
          contents[key] = (contents[key] or 0) + (tonumber(row.count) or 0)
        end
      end
      cost = cost + 2 + math.floor(#(ok and rows or {}) / 8)
    end
    restock(r, entry, contents)
  end
  return cost
end

-- Adds an own entity. Idempotent; returns true when it was new.
function M.add(entity)
  local r = data()
  if not (r and entity and entity.valid) then return false end
  local kind = entity.type
  if SKIPPED_TYPES[kind] then return false end
  local unit = entity.unit_number
  if not unit or r.entries[unit] or r.belts[unit] then return false end
  local ok_force, force = pcall(function() return entity.force.name end)
  if not ok_force or force ~= own_force_name(r) then return false end
  if BELT_TYPES[kind] then
    r.belts[unit], r.belt_count = true, r.belt_count + 1
  else
    local ok_burner, burner = pcall(function() return entity.burner end)
    local flags = {
      holders = STORE_INVENTORY[kind] and true or OUTPUT_TYPES[kind] or nil,
      burners = ok_burner and burner ~= nil or nil,
      electric = electric(entity) or nil,
      poles = kind == "electric-pole" or nil,
    }
    if not (M.is_machine(kind, flags.burners) or flags.holders or flags.burners or flags.electric) then return false end
    local position = entity.position
    local ok_surface, surface = pcall(function() return entity.surface.index end)
    local entry = { entity = entity, unit = unit, name = entity.name, type = kind,
      position = { x = position.x, y = position.y }, surface = ok_surface and surface or nil,
      burner = BURNER_ONLY_TYPES[kind] and flags.burners or nil }
    r.entries[unit] = entry
    if M.is_machine(kind, flags.burners) then
      r.machines[kind] = r.machines[kind] or {}
      r.machines[kind][unit] = true
    end
    for _, set in ipairs(SETS) do if flags[set] then r[set][unit] = true end end
    local row = type_row(r, entry.surface, kind)
    row.count = row.count + 1
    r.order[#r.order + 1] = unit
    -- A built entity counts at once; the cursor keeps it current. The
    -- bootstrap leaves its entities to the cursor's first pass.
    if r.ready then pcall(visit, r, entry) end
  end
  if script and script.register_on_object_destroyed then pcall(script.register_on_object_destroyed, entity) end
  return true
end

-- Removes by unit number. Returns the removed entry ("belt" for a belt).
function M.remove(unit)
  local r = data()
  if not (r and unit) then return nil end
  if r.belts[unit] then
    r.belts[unit], r.belt_count = nil, math.max(0, r.belt_count - 1)
    return "belt"
  end
  local entry = r.entries[unit]
  if not entry then return nil end
  r.entries[unit] = nil
  if r.machines[entry.type] then r.machines[entry.type][unit] = nil end
  leave_network(r, entry)
  if entry.stock then restock(r, entry, {}) end
  -- A deleted surface's aggregates went with it; never recreate its row.
  local by_type = r.types[entry.surface or 0]
  local row = by_type and by_type[entry.type]
  if row then
    row.count = math.max(0, row.count - 1)
    if entry.role == "source" then row.nameplate_w = row.nameplate_w - (entry.nominal_w or 0) end
    for _, key in ipairs(LAB_SUMS) do
      if entry[key] then row[key] = (row[key] or 0) - entry[key] end
    end
  end
  for _, set in ipairs(SETS) do r[set][unit] = nil end
  return entry
end

-- ------------------------------------------------------------------ events

-- on_built_entity, on_robot_built_entity, on_space_platform_built_entity,
-- script_raised_built, script_raised_revive, on_entity_cloned.
function M.on_built(event)
  local entity = event and (event.entity or event.destination)
  if entity then pcall(M.add, entity) end
end

-- The mined, died and script-destroy events, which name the entity.
function M.on_removed(event)
  local entity = event and event.entity
  local ok, unit = pcall(function() return entity and entity.unit_number end)
  if ok and unit then return M.remove(unit) end
end

-- on_object_destroyed: useful_id is the unit number for an entity.
function M.on_object_destroyed(event)
  if not event then return end
  local entity_type = defines and defines.target_type and defines.target_type.entity
  if entity_type ~= nil and event.type ~= nil and event.type ~= entity_type then return end
  return M.remove(event.useful_id)
end

-- ---------------------------------------------------------------- bootstrap

-- Reads up to BOOTSTRAP_CHUNKS_PER_TICK charted chunks (fewer once
-- BOOTSTRAP_ENTITIES_PER_TICK own entities were read) per tick. The first
-- tick only lists the charted chunks. Build and remove events keep working
-- meanwhile; add is idempotent.
local function bootstrap_step(r, c, tick)
  local b = r.bootstrap
  if not b.chunks then
    r.force = c.force.name
    b.chunks, b.cursor = {}, 1
    for chunk in c.surface.get_chunks() do
      if c.force.is_chunk_charted(c.surface, chunk) then b.chunks[#b.chunks + 1] = { x = chunk.x, y = chunk.y } end
    end
    return
  end
  local chunks, items = 0, 0
  while b.cursor <= #b.chunks and chunks < M.BOOTSTRAP_CHUNKS_PER_TICK and items < M.BOOTSTRAP_ENTITIES_PER_TICK do
    local chunk = b.chunks[b.cursor]
    b.cursor, chunks = b.cursor + 1, chunks + 1
    local x0, y0 = chunk.x * 32, chunk.y * 32
    local ok, found = pcall(c.surface.find_entities_filtered,
      { area = { { x0, y0 }, { x0 + 32, y0 + 32 } }, force = c.force })
    for _, entity in ipairs(ok and found or {}) do
      items = items + 1
      pcall(M.add, entity)
    end
  end
  if b.cursor > #b.chunks then
    -- The charted chunk list seeds map_summary's patch cache, so the
    -- surface's chunks are listed once, not again on a later tick.
    r.ready, r.ready_tick, r.charted_seed, r.bootstrap = true, tick, b.chunks, nil
    r.charted_seed_surface = c.surface.index
  end
end

-- Types a registry from an older version skipped (r.rescan.types, set by
-- state.init on the upgrade) are found once the bootstrap is done: one typed
-- query of one charted chunk each, RESCAN_CHUNKS_PER_TICK chunks a tick, over
-- the chunk list map_summary keeps for the body's surface. That list is
-- seeded after the bootstrap (an upgrade mid-bootstrap leaves it empty until
-- then): the rescan waits.
local function rescan_step(r, c)
  local job = r.rescan
  local cache = storage.patch_caches and storage.patch_caches[c.surface.index]
  if not (cache and cache.seeded) then return end
  local chunks = cache.charted or {}
  local read = 0
  while job.cursor <= #chunks and read < M.RESCAN_CHUNKS_PER_TICK do
    local chunk = chunks[job.cursor]
    job.cursor, read = job.cursor + 1, read + 1
    local x0, y0 = chunk.x * 32, chunk.y * 32
    local ok, found = pcall(c.surface.find_entities_filtered,
      { area = { { x0, y0 }, { x0 + 32, y0 + 32 } }, force = c.force, type = job.types })
    for _, entity in ipairs(ok and found or {}) do pcall(M.add, entity) end
  end
  if job.cursor > #chunks then r.rescan = nil end
end

-- A failing step never stops the game: it is retried next tick and its
-- error is kept for counts().
function M.on_tick(tick)
  local r = data()
  if not r or r.ready and not r.rescan then return end
  local c = companion.get()
  if not (c and c.valid) then return end
  local ok, err = pcall(r.ready and rescan_step or bootstrap_step, r, c, tick)
  r.error = not ok and tostring(err) or nil
end

-- One tick of the maintenance cursor: entries in add order, compacted in
-- place (removed units are dropped as the cursor passes them). A pass ends
-- at the list's end: networks left without members are forgotten.
local function maintain_step(r, tick)
  local order, budget = r.order, M.MAINTAIN_WORK_PER_TICK
  while budget > 0 do
    local read = r.cursor
    if read > #order then
      for index = #order, r.write, -1 do order[index] = nil end
      r.cursor, r.write, r.pass_tick = 1, 1, tick
      for id, net in pairs(r.networks) do if net.members <= 0 then r.networks[id] = nil end end
      return
    end
    local unit = order[read]
    r.cursor = read + 1
    local entry = r.entries[unit]
    if entry then
      order[r.write], r.write = unit, r.write + 1
      local ok, cost = pcall(visit, r, entry)
      budget = budget - (ok and cost or 1)
    else
      budget = budget - 1
    end
  end
end

function M.maintain(tick)
  local r = data()
  if not (r and r.ready) then return end
  local ok, err = pcall(maintain_step, r, tick)
  r.maintain_error = not ok and tostring(err) or nil
end

-- ------------------------------------------------------------------- reads

-- The body's anchor surface index (its physical surface, the hub aboard),
-- or nil without a connected Codex player. A caller that read the anchor
-- passes it.
local function anchor_index(anchor)
  anchor = anchor or companion.anchor()
  local ok, index = pcall(function() return anchor.surface.index end)
  return ok and index or nil
end
M.anchor_index = function() return anchor_index() end

-- The own force for chart checks: the body's, else the registry's.
local function own_force(r, anchor)
  if anchor and anchor.force then return anchor.force end
  local ok, force = pcall(function() return game.forces[r.force] end)
  return ok and force or nil
end

-- Which surface a read covers: an index, "all", or nil (the anchor's).
-- Returns a predicate on an entry's surface index, or nil when there is
-- nothing to read.
local function on_surface(surface, anchor)
  if surface == "all" then return function() return true end end
  local index = surface
  if index == nil then index = anchor_index(anchor) end
  if index == nil then return nil end
  return function(entry_surface) return entry_surface == nil or entry_surface == index end
end

-- Whether an entry lies in a charted chunk: the maintenance cursor's own
-- answer once it found the chunk charted, else one chart check per surface
-- and chunk, kept in `cache` (plain data: chunk keys, and per surface index
-- whether it is a platform's).
local function entry_charted(entry, force, cache)
  if entry.charted then return true end
  local index = entry.surface or 0
  local cx, cy = math.floor(entry.position.x / 32), math.floor(entry.position.y / 32)
  local key = index .. ":" .. cx .. "," .. cy
  local known = cache[key]
  if known == nil then
    local surface = surfaces.by_index(entry.surface) or entry.entity.surface
    local platform = cache[index]
    if platform == nil then platform = surfaces.is_platform(surface); cache[index] = platform end
    known = surfaces.charted(force, surface, cx, cy, platform)
    cache[key] = known
  end
  return known
end

-- Valid entries of one set (or of the machine types listed) on the surface
-- (see on_surface) in charted chunks, ordered by unit number. An entry whose
-- entity is gone is dropped here (its destroy event may still be pending).
-- One chart check per surface and chunk.
local function collect(units_of, surface)
  local r = data()
  local rows = {}
  if not r then return rows end
  local anchor = companion.anchor()
  local wanted = on_surface(surface, anchor)
  if not wanted then return rows end
  local force = own_force(r, anchor)
  if not force then return rows end
  local cache = {}
  for _, units in ipairs(units_of) do
    for unit in pairs(units) do
      local entry = r.entries[unit]
      if entry and not (entry.entity and entry.entity.valid) then
        M.remove(unit)
      elseif entry and wanted(entry.surface) and entry_charted(entry, force, cache) then
        rows[#rows + 1] = entry
      end
    end
  end
  table.sort(rows, function(a, b) return a.unit < b.unit end)
  return rows
end

-- Unit numbers of every registered machine on every surface, in add order
-- (the maintenance cursor's list, read once each): one pure Lua pass, no
-- engine read and no sort. The line refresh then reads them a few a tick
-- through charted_machine.
function M.machine_units()
  local r = data()
  local units, seen = {}, {}
  if not r then return units end
  for _, unit in ipairs(r.order) do
    local entry = not seen[unit] and r.entries[unit]
    local set = entry and r.machines[entry.type]
    if set and set[unit] then units[#units + 1], seen[unit] = unit, true end
  end
  return units
end

-- The own force for chart checks (the body's, else the registry's), or nil.
function M.own_force()
  local r = data()
  return r and own_force(r, companion.anchor()) or nil
end

-- The entry of a registered machine whose entity is valid and lies in a
-- chunk the force (M.own_force) has charted, else nil (a gone entity is
-- dropped). `cache` keeps the chart checks across calls (see
-- entry_charted); about one engine read.
function M.charted_machine(unit, force, cache)
  local r = data()
  local entry = r and r.entries[unit]
  if not entry then return nil end
  if not (entry.entity and entry.entity.valid) then M.remove(unit); return nil end
  if not (force and entry_charted(entry, force, cache)) then return nil end
  return entry
end

-- holders | burners | electric | poles, on a surface (index, "all", or nil
-- for the anchor's).
function M.list(set, surface)
  local r = data()
  return collect({ r and r[set] or {} }, surface)
end

-- Machines of the given types (all machine types when nil) on a surface
-- (index, "all", or nil for the anchor's).
function M.machines(types, surface)
  local r = data()
  local sets = {}
  if r then
    if types then
      for _, kind in ipairs(types) do sets[#sets + 1] = r.machines[kind] or {} end
    else
      for _, units in pairs(r.machines) do sets[#sets + 1] = units end
    end
  end
  return collect(sets, surface)
end

-- Whether any own entity of these types is registered and still valid on a
-- surface (index, or nil for the anchor's): a walk over the registry's sets
-- only (no sort, no chunk read, no query). Machine types are looked up
-- directly; others (solar panels) through the electric set.
function M.any(types, surface)
  local r = data()
  local wanted = r and on_surface(surface)
  if not wanted then return false end
  local function live(unit)
    local entry = r.entries[unit]
    return entry ~= nil and wanted(entry.surface) and entry.entity ~= nil and entry.entity.valid
  end
  local others = {}
  for _, kind in ipairs(types) do
    if MACHINE_TYPES[kind] then
      for unit in pairs(r.machines[kind] or {}) do if live(unit) then return true end end
    else
      others[kind] = true
    end
  end
  if next(others) then
    for unit in pairs(r.electric) do
      local entry = r.entries[unit]
      if entry and others[entry.type] and live(unit) then return true end
    end
  end
  return false
end

-- Up to `cap` registered holders on the body's surface whose last read held
-- the item, nearest `position` first, skipping those skip(entry) names: a
-- Lua pass over the holder set, with no engine read (the caller confirms the
-- live count of the few it gets).
function M.holders_with(item, position, cap, skip)
  local r = data()
  local heap = {}
  local surface = anchor_index()
  if not (r and surface) then return heap end
  local function nearer(a, b) return a.d < b.d or a.d == b.d and a.entry.unit < b.entry.unit end
  for unit in pairs(r.holders) do
    local entry = r.entries[unit]
    local held = entry and entry.stock and entry.stock[item]
    if held and held > 0 and (entry.surface == nil or entry.surface == surface) and not (skip and skip(entry)) then
      local dx, dy = entry.position.x - position.x, entry.position.y - position.y
      jobs.keep_first(heap, cap, { d = dx * dx + dy * dy, entry = entry }, nearer)
    end
  end
  table.sort(heap, nearer)
  local entries = {}
  for i, row in ipairs(heap) do entries[i] = row.entry end
  return entries
end

-- {[item] = count} held by own holders (chests and crafting outputs; belts
-- are not counted) on a surface (index, or nil for the body's: items on
-- another planet are not in its reach), as the maintenance cursor last read
-- them: no holder is walked here. What is actually taken is read again where
-- it is taken.
function M.stock_totals(items, surface)
  local r = data()
  local index = surface or anchor_index()
  local stock = r and index and r.stock[index] or {}
  local totals = {}
  for _, name in ipairs(items) do totals[name] = stock[name] and stock[name].total or 0 end
  return totals
end

-- The factory surfaces: indices of the surfaces holding own registered
-- entities (any type's count above zero), ascending. Pure Lua over the type
-- aggregates.
function M.surfaces()
  local r = data()
  local list = {}
  for index, by_type in pairs(r and r.types or {}) do
    if index ~= 0 then
      for _, row in pairs(by_type) do
        if row.count > 0 then list[#list + 1] = index; break end
      end
    end
  end
  table.sort(list)
  return list
end

-- on_surface_deleted: its aggregates go at once; its entries leave through
-- their own destroy events (or when a read or the cursor finds them invalid).
function M.on_surface_deleted(event)
  local r = data()
  local index = event and event.surface_index
  if not (r and index) then return end
  r.types[index], r.stock[index] = nil, nil
  for id, net in pairs(r.networks) do if net.surface == index then r.networks[id] = nil end end
end

-- The `limit` most held items of a surface, most first, each with its
-- largest holder: {item, total, holders = {{position, kind, count}}}, and how
-- many items the limit left out. One pass over the surface's items.
function M.stock_rows(surface, limit)
  local r = data()
  local rows, total = {}, 0
  local function before(a, b)
    if a.total ~= b.total then return a.total > b.total end
    return a.item < b.item
  end
  local heap = {}
  local keep = jobs.keep_first
  for item, row in pairs(r and r.stock[surface] or {}) do
    if row.total > 0 then
      total = total + 1
      keep(heap, limit, { item = item, total = row.total, unit = row.unit, count = row.count }, before)
    end
  end
  table.sort(heap, before)
  for _, row in ipairs(heap) do
    local entry = row.unit and r.entries[row.unit]
    local holders = {}
    if entry then holders[1] = { position = { x = entry.position.x, y = entry.position.y }, kind = M.holder_kind(entry),
      count = row.count } end
    rows[#rows + 1] = { item = row.item, total = row.total, holders = holders }
  end
  return rows, total - #rows
end

-- The live entry of the largest holder of an item on a surface (as the
-- cursor last read it), or nil.
function M.largest_holder(surface, item)
  local r = data()
  local row = r and r.stock[surface] and r.stock[surface][item]
  local entry = row and row.unit and r.entries[row.unit]
  if entry and entry.entity and entry.entity.valid then return entry end
  return nil
end

-- How many electric networks have members, on every surface: one pass, no
-- sort.
function M.network_count()
  local r = data()
  local n = 0
  for _, net in pairs(r and r.networks or {}) do if net.members > 0 then n = n + 1 end end
  return n
end

-- The electric networks with members, by surface index: {[index] = nets
-- by id}, in one pass over the networks.
function M.networks_by_surface()
  local r = data()
  local by_surface = {}
  for _, net in pairs(r and r.networks or {}) do
    if net.members > 0 and net.surface ~= nil then
      local list = by_surface[net.surface] or {}
      by_surface[net.surface] = list
      list[#list + 1] = net
    end
  end
  for _, list in pairs(by_surface) do table.sort(list, function(a, b) return a.id < b.id end) end
  return by_surface
end

-- The electric networks with members on a surface, by id.
function M.networks(surface)
  local r = data()
  local rows = {}
  for _, net in pairs(r and r.networks or {}) do
    if net.surface == surface and net.members > 0 then rows[#rows + 1] = net end
  end
  table.sort(rows, function(a, b) return a.id < b.id end)
  return rows
end

-- Per type on a surface: {[type] = {count, nameplate_w}} (nameplate for
-- electric producers).
function M.aggregate(surface)
  local r = data()
  local out = {}
  for kind, row in pairs(r and r.types[surface] or {}) do out[kind] = { count = row.count, nameplate_w = row.nameplate_w } end
  return out
end

-- Own labs on every surface (research is the force's): {count, speed,
-- pack_rate, progress_rate}, each summed as the maintenance cursor last read
-- each lab (see LAB_SUMS). Pure Lua over the type aggregates.
function M.labs()
  local r = data()
  local count, speed, pack_rate, progress_rate = 0, 0, 0, 0
  for _, by_type in pairs(r and r.types or {}) do
    local row = by_type.lab
    if row then
      count, speed = count + row.count, speed + (row.research_speed or 0)
      pack_rate, progress_rate = pack_rate + (row.pack_rate or 0), progress_rate + (row.progress_rate or 0)
    end
  end
  return { count = count, speed = math.max(0, speed), pack_rate = math.max(0, pack_rate),
    progress_rate = math.max(0, progress_rate) }
end

-- {ready, pass_tick}: whether the aggregates have had one full pass.
function M.maintenance()
  local r = data()
  return { ready = r ~= nil and r.pass_tick ~= nil, pass_tick = r and r.pass_tick, error = r and r.maintain_error }
end

-- machines: productive machines on every surface (the one machine count
-- every report uses).
function M.counts()
  local r = data()
  local counts = { registry_ready = M.ready(), entities = 0, machines = 0, belts = r and r.belt_count or 0,
    error = r and r.error }
  if not r then return counts end
  for _ in pairs(r.entries) do counts.entities = counts.entities + 1 end
  for _, by_type in pairs(r.types) do
    for kind, row in pairs(by_type) do
      if PRODUCTIVE_TYPES[kind] then counts.machines = counts.machines + row.count end
    end
  end
  if not r.ready and r.bootstrap and r.bootstrap.chunks then
    counts.bootstrap_chunks, counts.bootstrap_done = #r.bootstrap.chunks, r.bootstrap.cursor - 1
  end
  return counts
end

return M
