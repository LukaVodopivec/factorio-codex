-- Own entities, kept by events so no read, chore or line refresh scans the
-- force. Every RCON command and every on_tick handler runs inside one game
-- tick on the server and every client, so a whole-force query freezes all of
-- them; this registry is what those paths read instead.
--
-- Kept per entity (by unit_number, own force only):
--   machines  by type (the line sampler's machine types, plus beacons and
--             roboports, which it samples for problems only)
--   holders   chests and crafting-machine outputs (stock)
--   burners   entities with a burner (fuel)
--   electric  poles, producers, accumulators and electric consumers (power)
--   belts     counted, never listed: no read walks belts
-- Added on the build, revive and clone events and directly where the mod
-- itself creates an entity; removed on the mined, died and destroy events and
-- through script.register_on_object_destroyed. An upgraded save fills it once
-- by a bootstrap spread over ticks, a few charted chunks per tick; until that
-- ends `ready` is false and reads say so.
--
-- Aggregates (what factory_status and map_summary's power rows read, never
-- by walking entities): per surface, every type's count and nameplate sum;
-- per electric network, its sources by kind, accumulators, the nominal demand
-- of its consumers that try to run, and a pole for its statistics; per
-- surface, every item's stock in own holders with its largest holder. Build
-- and remove events update them at once. A maintenance cursor (maintain,
-- MAINTAIN_WORK_PER_TICK work items a tick) walks the entries in a ring and
-- refreshes what changes without an event: network ids (they change when
-- poles connect or split networks), consumer status, accumulator charge and
-- holder contents. pass_tick is when the last full pass ended.
local companion = require("scripts.companion")
local jobs = require("scripts.jobs")

local M = {}

-- Work budgets count items, never time (Lua has no clock).
M.BOOTSTRAP_CHUNKS_PER_TICK = 4
M.BOOTSTRAP_ENTITIES_PER_TICK = 400
M.MAINTAIN_WORK_PER_TICK = 64

-- Productive machines make something and form factory lines.
local PRODUCTIVE_TYPES = {
  ["mining-drill"] = true, furnace = true, ["assembling-machine"] = true, ["rocket-silo"] = true,
  lab = true, boiler = true, generator = true, ["burner-generator"] = true, ["offshore-pump"] = true,
  reactor = true,
}
-- Sampled for problems only: no product, never a line.
local PROBLEM_ONLY_TYPES = { beacon = true, roboport = true }
local MACHINE_TYPES = {}
for kind in pairs(PRODUCTIVE_TYPES) do MACHINE_TYPES[kind] = true end
for kind in pairs(PROBLEM_ONLY_TYPES) do MACHINE_TYPES[kind] = true end
M.MACHINE_TYPES, M.PRODUCTIVE_TYPES, M.PROBLEM_ONLY_TYPES = MACHINE_TYPES, PRODUCTIVE_TYPES, PROBLEM_ONLY_TYPES
local CHEST_TYPES = { container = true, ["logistic-container"] = true }
local OUTPUT_TYPES = { furnace = true, ["assembling-machine"] = true, ["rocket-silo"] = true }
local BELT_TYPES = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
  loader = true, ["loader-1x1"] = true, ["linked-belt"] = true }
local SKIPPED_TYPES = { character = true, ["entity-ghost"] = true, ["tile-ghost"] = true }
local SETS = { "holders", "burners", "electric", "poles" }
-- Electric producers by power kind; a generator built for steam hotter than
-- an engine's 165 degrees is a turbine, counted as nuclear.
local SOURCE_TYPES = { ["solar-panel"] = "solar", generator = "steam", ["burner-generator"] = "burner" }
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

local function chunk_charted(entry)
  local ok, value = pcall(function()
    local entity = entry.entity
    return entity.force.is_chunk_charted(entity.surface,
      { x = math.floor(entry.position.x / 32), y = math.floor(entry.position.y / 32) })
  end)
  return ok and value == true
end

-- What a holder offers: a chest's contents or a crafting machine's output.
function M.holder_inventory(entity)
  local ok, inventory = pcall(function()
    if CHEST_TYPES[entity.type] then return entity.get_inventory(defines.inventory.chest) end
    return entity.get_output_inventory()
  end)
  return ok and inventory or nil
end

function M.holder_kind(entry) return CHEST_TYPES[entry.type] and "chest" or "machine_output" end

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
  if r.holders[entry.unit] then
    local contents = {}
    if entry.charted then
      local inventory = M.holder_inventory(entity)
      local ok, rows = pcall(function() return inventory and inventory.get_contents() or {} end)
      for _, row in ipairs(ok and rows or {}) do
        if type(row.name) == "string" then contents[row.name] = (contents[row.name] or 0) + (tonumber(row.count) or 0) end
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
      holders = CHEST_TYPES[kind] or OUTPUT_TYPES[kind] or nil,
      burners = ok_burner and burner ~= nil or nil,
      electric = electric(entity) or nil,
      poles = kind == "electric-pole" or nil,
    }
    if not (MACHINE_TYPES[kind] or flags.holders or flags.burners or flags.electric) then return false end
    local position = entity.position
    local ok_surface, surface = pcall(function() return entity.surface.index end)
    local entry = { entity = entity, unit = unit, name = entity.name, type = kind,
      position = { x = position.x, y = position.y }, surface = ok_surface and surface or nil }
    r.entries[unit] = entry
    if MACHINE_TYPES[kind] then
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
  local row = type_row(r, entry.surface, entry.type)
  row.count = math.max(0, row.count - 1)
  if entry.role == "source" then row.nameplate_w = row.nameplate_w - (entry.nominal_w or 0) end
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
  end
end

-- A failing step never stops the game: it is retried next tick and its
-- error is kept for counts().
function M.on_tick(tick)
  local r = data()
  if not r or r.ready then return end
  local c = companion.get()
  if not (c and c.valid) then return end
  local ok, err = pcall(bootstrap_step, r, c, tick)
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

-- Valid entries of one set (or of the machine types listed) on the body's
-- surface in charted chunks, ordered by unit number. An entry whose entity
-- is gone is dropped here (its destroy event may still be pending).
local function collect(units_of, c)
  local r = data()
  local rows = {}
  if not (r and c and c.valid) then return rows end
  local surface_index = c.surface.index
  local charted = {}
  for _, units in ipairs(units_of) do
    for unit in pairs(units) do
      local entry = r.entries[unit]
      if entry and not (entry.entity and entry.entity.valid) then
        M.remove(unit)
      elseif entry and (entry.surface == nil or entry.surface == surface_index) then
        local cx, cy = math.floor(entry.position.x / 32), math.floor(entry.position.y / 32)
        local key = cx .. "," .. cy
        if charted[key] == nil then
          local ok, value = pcall(c.force.is_chunk_charted, c.surface, { x = cx, y = cy })
          charted[key] = ok and value == true
        end
        if charted[key] then rows[#rows + 1] = entry end
      end
    end
  end
  table.sort(rows, function(a, b) return a.unit < b.unit end)
  return rows
end

-- holders | burners | electric | poles
function M.list(set)
  local r = data()
  return collect({ r and r[set] or {} }, companion.get())
end

-- Machines of the given types (all machine types when nil).
function M.machines(types)
  local r = data()
  local sets = {}
  if r then
    if types then
      for _, kind in ipairs(types) do sets[#sets + 1] = r.machines[kind] or {} end
    else
      for _, units in pairs(r.machines) do sets[#sets + 1] = units end
    end
  end
  return collect(sets, companion.get())
end

-- Whether any own entity of these types is registered and still valid: a
-- walk over the registry's sets only (no sort, no chunk read, no query).
-- Machine types are looked up directly; others (solar panels) through the
-- electric set.
function M.any(types)
  local r = data()
  if not r then return false end
  local function live(unit)
    local entry = r.entries[unit]
    return entry ~= nil and entry.entity ~= nil and entry.entity.valid
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

local function body_surface()
  local c = companion.get()
  local ok, index = pcall(function() return c.surface.index end)
  return ok and index or 1
end

-- Up to `cap` registered holders on the body's surface whose last read held
-- the item, nearest `position` first, skipping those skip(entry) names: a
-- Lua pass over the holder set, with no engine read (the caller confirms the
-- live count of the few it gets).
function M.holders_with(item, position, cap, skip)
  local r = data()
  local heap = {}
  if not r then return heap end
  local surface = body_surface()
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
-- are not counted) on the body's surface, as the maintenance cursor last
-- read them: no holder is walked here. What is actually taken is read again
-- where it is taken.
function M.stock_totals(items)
  local r = data()
  local stock = r and r.stock[body_surface()] or {}
  local totals = {}
  for _, name in ipairs(items) do totals[name] = stock[name] and stock[name].total or 0 end
  return totals
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
