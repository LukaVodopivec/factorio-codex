-- Own entities, kept by events so no read, chore or line refresh scans the
-- force. Every RCON command and every on_tick handler runs inside one game
-- tick on the server and every client, so a whole-force query freezes all of
-- them; this registry is what those paths read instead.
--
-- Kept per entity (by unit_number, own force only):
--   machines  by type (autonomy.lua's machine types)
--   holders   chests and crafting-machine outputs (stock)
--   burners   entities with a burner (fuel)
--   electric  poles, producers, accumulators and electric consumers (power)
--   belts     counted, never listed: no read walks belts
-- Added on the build, revive and clone events and directly where the mod
-- itself creates an entity; removed on the mined, died and destroy events and
-- through script.register_on_object_destroyed. An upgraded save fills it once
-- by a bootstrap spread over ticks, a few charted chunks per tick; until that
-- ends `ready` is false and reads say so.
local companion = require("scripts.companion")

local M = {}

-- Work budgets count items, never time (Lua has no clock).
M.BOOTSTRAP_CHUNKS_PER_TICK = 4
M.BOOTSTRAP_ENTITIES_PER_TICK = 400

local MACHINE_TYPES = {
  ["mining-drill"] = true, furnace = true, ["assembling-machine"] = true, ["rocket-silo"] = true,
  lab = true, boiler = true, generator = true, ["burner-generator"] = true, ["offshore-pump"] = true,
}
M.MACHINE_TYPES = MACHINE_TYPES
local CHEST_TYPES = { container = true, ["logistic-container"] = true }
local OUTPUT_TYPES = { furnace = true, ["assembling-machine"] = true, ["rocket-silo"] = true }
local BELT_TYPES = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
  loader = true, ["loader-1x1"] = true, ["linked-belt"] = true }
local SKIPPED_TYPES = { character = true, ["entity-ghost"] = true, ["tile-ghost"] = true }
local SETS = { "holders", "burners", "electric", "poles" }

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
    r.entries[unit] = { entity = entity, unit = unit, name = entity.name, type = kind,
      position = { x = position.x, y = position.y }, surface = ok_surface and surface or nil }
    if MACHINE_TYPES[kind] then
      r.machines[kind] = r.machines[kind] or {}
      r.machines[kind][unit] = true
    end
    for _, set in ipairs(SETS) do if flags[set] then r[set][unit] = true end end
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

-- What a holder offers: a chest's contents or a crafting machine's output.
function M.holder_inventory(entity)
  local ok, inventory = pcall(function()
    if CHEST_TYPES[entity.type] then return entity.get_inventory(defines.inventory.chest) end
    return entity.get_output_inventory()
  end)
  return ok and inventory or nil
end

function M.holder_kind(entry) return CHEST_TYPES[entry.type] and "chest" or "machine_output" end

-- {[item] = count} over every holder in one pass (belts are not counted).
function M.stock_totals(items)
  local totals = {}
  for _, name in ipairs(items) do totals[name] = 0 end
  for _, entry in ipairs(M.list("holders")) do
    local inventory = M.holder_inventory(entry.entity)
    if inventory then
      for _, name in ipairs(items) do
        local ok, count = pcall(inventory.get_item_count, name)
        if ok and type(count) == "number" then totals[name] = totals[name] + count end
      end
    end
  end
  return totals
end

function M.counts()
  local r = data()
  local counts = { registry_ready = M.ready(), entities = 0, machines = 0, belts = r and r.belt_count or 0,
    error = r and r.error }
  if not r then return counts end
  for _ in pairs(r.entries) do counts.entities = counts.entities + 1 end
  for _, units in pairs(r.machines) do for _ in pairs(units) do counts.machines = counts.machines + 1 end end
  if not r.ready and r.bootstrap and r.bootstrap.chunks then
    counts.bootstrap_chunks, counts.bootstrap_done = #r.bootstrap.chunks, r.bootstrap.cursor - 1
  end
  return counts
end

return M
