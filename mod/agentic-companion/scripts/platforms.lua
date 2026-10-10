-- Space platforms: what the platforms window shows and does, remotely (no
-- body, no reach, no items moved).
--   resolve       one resolver for every platform selector (a name, or the
--                 platform's index); platforms pending deletion are invisible
--   platform_status (read) compact: every own platform, attribute reads
--                 and one read per hub request section; full: one platform's
--                 screen as a job (foundation runs read chunk by chunk,
--                 entities searched chunk by chunk over the foundation's box,
--                 hub stock and requests, ghosts and the items they still
--                 miss, thrusters' fuel, tile damage)
--   create_platform the "new platform" button over the body's planet (or a
--                 named unlocked one): the platform waits for its starter
--                 pack, which launch_rocket sends; nothing is built or consumed
--   set_platform_route the platform's schedule: its stops with the game's own
--                 wait conditions, which stop to head for, pause
--   surfaces      one resolver for every surface reference (a planet name,
--                 "platform:<index>" or {platform = selector})
--   events        a ring of the last space events (rocket launches ordered,
--                 rockets launched, platform state changes and arrivals,
--                 cargo pods landed, rockets ready, the body's surface
--                 changes and travel phases) that event_state and next_event
--                 read; only event handlers and the travel step write it;
--                 the rocket events also keep their first tick as a run
--                 milestone (storage.milestones)
--   trips         each platform's last trip: when it departed and the own
--                 entities lost on it since (platform_status trip)
-- storage.space = {created = {[index] = planet}, events = {...}, last_event_tick,
-- trips = {[index] = {departed_tick, from, lost}}}.
local companion = require("scripts.companion")
local jobs = require("scripts.jobs")

local M = {}

M.MAX_COMPACT = 8
M.MAX_ENTITIES = 120
M.MAX_ROWS = 200
M.MAX_HUB_ITEMS = 40
M.MAX_NAME = 60
M.EVENT_RING = 32
M.EVENT_STATE_ROWS = 4
M.STARTER_PACK = "space-platform-starter-pack"
local FOUNDATION = "space-platform-foundation"
local SCAN_PER_ITEM = 16
local CONTENTS_PER_ITEM = 4 -- inventory rows a capped read keeps per work item
local GHOST_TYPES = { ["entity-ghost"] = true, ["tile-ghost"] = true }
local RECIPE_TYPES = { ["assembling-machine"] = true, furnace = true }
local THRUSTER_FLUIDS = { ["thruster-fuel"] = "fuel", ["thruster-oxidizer"] = "oxidizer" }

local function space()
  local s = storage.space
  if not s then
    s = { created = {}, events = {} }
    storage.space = s
  end
  return s
end

local names = {}
local function define_name(group, value)
  if value == nil then return nil end
  local map = names[group]
  if not map then
    map = {}
    for name, v in pairs(defines[group] or {}) do map[v] = name end
    names[group] = map
  end
  return map[value] or tostring(value)
end

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

-- A prototype read back as a LuaObject or named by a string.
local function name_of(value)
  if type(value) == "string" or value == nil then return value end
  return read(function() return value.name end)
end

local function xy(position) return { x = position.x, y = position.y } end

-- ----------------------------------------------------------------- resolve

function M.check_selector(value, label)
  if type(value) == "string" and #value >= 1 and #value <= M.MAX_NAME then return end
  if type(value) == "number" and value % 1 == 0 and value >= 1 then return end
  error(label .. " must be a platform name or index", 0)
end

local function visible(p)
  return read(function() return p.valid and p.scheduled_for_deletion == 0 end) == true
end

-- The force's platforms that are not pending deletion, by index.
function M.list(force)
  local rows = {}
  for _, p in pairs(force.platforms or {}) do
    if visible(p) then rows[#rows + 1] = p end
  end
  table.sort(rows, function(a, b) return a.index < b.index end)
  return rows
end

-- The platform a selector names, or nil, the code and why.
function M.resolve(force, selector)
  local found
  for _, p in ipairs(M.list(force)) do
    if p.index == selector then return p end
    if p.name == selector then
      if found then
        return nil, "AMBIGUOUS_PLATFORM", string.format("two platforms are called %s: name it by index", selector)
      end
      found = p
    end
  end
  if found then return found end
  return nil, "UNKNOWN_PLATFORM", "no platform " .. (type(selector) == "number" and "with index " or "called ")
    .. tostring(selector)
end

-- The canonical reference of a platform's surface.
function M.surface_ref(p) return "platform:" .. p.index end

-- ---------------------------------------------------------------- surfaces

-- A SurfaceRef in canonical form: a planet's name (whether or not its
-- surface exists yet) or "platform:<index>", and the platform it names; or
-- nil, the code and why. Input: a planet name, "platform:<index>", or
-- {platform = name or index}.
function M.canonical_ref(force, ref)
  if type(ref) == "table" then
    if ref.platform == nil then return nil, "SURFACE_UNKNOWN", "a surface table names a platform: {platform = name or index}" end
    local p, code, why = M.resolve(force, ref.platform)
    if not p then return nil, code, why end
    return M.surface_ref(p), nil, nil, p
  end
  if type(ref) ~= "string" or ref == "" then
    return nil, "SURFACE_UNKNOWN", "a surface is a planet name, \"platform:<index>\" or {platform = name or index}"
  end
  local index = ref:match("^platform:(%d+)$")
  if index then
    local p, code, why = M.resolve(force, tonumber(index))
    if not p then return nil, code, why end
    return M.surface_ref(p), nil, nil, p
  end
  if read(function() return game.planets[ref] end) then return ref end
  return nil, "SURFACE_UNKNOWN", "no planet called " .. ref .. " (name a platform as {platform = name} or \"platform:<index>\")"
end

-- The surface a SurfaceRef names now and its canonical ref; else nil, the
-- code and why: SURFACE_NOT_CREATED for a planet nobody has reached yet,
-- NO_HUB for a platform still waiting for its starter pack.
function M.resolve_surface(force, ref)
  local canonical, code, why, p = M.canonical_ref(force, ref)
  if not canonical then return nil, code, why end
  if p then
    local surface, no_hub, reason = M.surface_of(p)
    if not surface then return nil, no_hub, reason end
    return surface, canonical
  end
  local surface = read(function() return game.planets[canonical].surface end)
  if not (surface and surface.valid) then
    return nil, "SURFACE_NOT_CREATED", "planet " .. canonical .. " has no surface yet: nobody has been there"
  end
  return surface, canonical
end

-- Space location -> the technologies whose effects unlock it (prototype
-- data, read once per load).
local unlockers
-- Whether the force has unlocked a space location. 2.0.77 documents no
-- return value for LuaForce.is_space_location_unlocked, so only a boolean
-- answer is taken from it; else the location is unlocked when a researched
-- technology unlocks it, or (a location no technology unlocks: the home
-- planet) when its surface exists.
function M.location_unlocked(force, name)
  local ok, value = pcall(force.is_space_location_unlocked, name)
  if ok and type(value) == "boolean" then return value end
  if not unlockers then
    unlockers = {}
    for tech_name, tech in pairs(read(function() return prototypes.technology end) or {}) do
      for _, effect in ipairs(read(function() return tech.effects end) or {}) do
        if effect.type == "unlock-space-location" and effect.space_location then
          local list = unlockers[effect.space_location] or {}
          unlockers[effect.space_location] = list
          list[#list + 1] = tech_name
        end
      end
    end
  end
  local techs = unlockers[name]
  if techs then
    for _, tech in ipairs(techs) do
      if read(function() return force.technologies[tech].researched end) == true then return true end
    end
    return false
  end
  return read(function() return game.planets[name].surface ~= nil end) == true
end

-- Entities a platform target never names (ghosts are built by the hub).
local NOT_TARGETS = { ["entity-ghost"] = true, ["tile-ghost"] = true, ["item-request-proxy"] = true,
  ["item-entity"] = true, character = true, ["deconstructible-tile-proxy"] = true, ["cargo-pod"] = true }

-- A platform's surface, or nil, "NO_HUB" and why: a platform still waiting
-- for its starter pack has none yet.
function M.surface_of(p)
  local surface = read(function() return p.surface end)
  if surface and surface.valid then return surface end
  return nil, "NO_HUB", "platform " .. p.name .. " has no surface yet: launch its starter pack to it first"
end

-- The force's entity on platform p nearest {x, y} (within 1.5 tiles of its
-- centre), or nil (and the code and why when the platform has no surface
-- yet): one bounded search on the platform's surface.
function M.entity_at(p, force, position)
  local surface, code, why = M.surface_of(p)
  if not surface then return nil, code, why end
  local best, best_d
  for _, e in ipairs(surface.find_entities_filtered({ position = position, radius = 1.5, force = force })) do
    if e.valid and not NOT_TARGETS[e.type] then
      local d = (e.position.x - position.x) ^ 2 + (e.position.y - position.y) ^ 2
      if not best or d < best_d then best, best_d = e, d end
    end
  end
  return best
end

function M.location(p) return name_of(read(function() return p.space_location end)) end

-- The planet a platform orbits: its location, or (still waiting for its
-- starter pack) the planet create_platform made it over.
function M.planet(p)
  return M.location(p) or space().created[p.index]
end

function M.state_name(p) return define_name("space_platform_state", p.state) end

-- ----------------------------------------------------------------- reading

-- The requests module reads hub sections (it requires this module, so it
-- hands its reader in at load).
local requests_reader
function M.set_requests_reader(reader) requests_reader = reader end

local function hub_of(p)
  local hub = read(function() return p.hub end)
  if hub and hub.valid then return hub end
end

local function hub_inventory(hub, id)
  return read(function() return hub.get_inventory(defines.inventory[id]) end)
end

-- Where a platform is headed: the connection it travels (from, to), how
-- far along (0..1) and its length; nil while it stays at a location.
local function travel_of(p)
  local connection = read(function() return p.space_connection end)
  if not connection then return nil end
  local distance = read(function() return p.distance end)
  return { from = name_of(read(function() return connection.from end)), to = name_of(read(function() return connection.to end)),
    distance_fraction = distance and math.floor(distance * 1000 + 0.5) / 1000 or nil,
    length_km = read(function() return connection.length end) }
end

-- A schedule record as read back: {station, wait_conditions, allows_unloading}
-- (full), or {station, waits = count} (compact).
local function record_row(record, full)
  if full then
    return { station = record.station, wait_conditions = record.wait_conditions or {},
      allows_unloading = record.allows_unloading ~= false }
  end
  return { station = record.station, waits = #(record.wait_conditions or {}) }
end

-- The platform's schedule: the record it heads for and its records.
local function schedule_of(p, full)
  local schedule = read(function() return p.get_schedule() end)
  if not schedule then return nil end
  local rows = {}
  for _, record in ipairs(read(function() return schedule.get_records() end) or {}) do rows[#rows + 1] = record_row(record, full) end
  return { current = read(function() return schedule.current end), records = rows }
end

-- The schedule record a platform heads for (schedule.current), its index,
-- whether any record stops at `name`, and all its records.
local function current_record(p, name)
  local schedule = read(function() return p.get_schedule() end)
  if not schedule then return nil, nil, false, {} end
  local records = read(function() return schedule.get_records() end) or {}
  local scheduled = false
  for _, record in ipairs(records) do
    if record.station == name then scheduled = true end
  end
  local current = read(function() return schedule.current end)
  return current and records[current] or nil, current, scheduled, records
end

-- Whether a platform's schedule has a stop at `name`.
function M.scheduled(p, name)
  local _, _, scheduled = current_record(p, name)
  return scheduled
end

-- Whether a platform's next stop is `name`: the stop it heads for now, or,
-- while it waits at a stop over that stop's location and is not paused, the
-- record after it (where it goes once that stop's wait conditions hold).
function M.heading_to(p, name)
  local record, current, _, records = current_record(p, name)
  if record == nil then return false end
  local location = M.location(p)
  if location ~= nil and record.station == location and #records > 1 and read(function() return p.paused end) ~= true then
    record = records[current % #records + 1]
  end
  return record ~= nil and record.station == name
end

-- A platform's thrusters: how many and how many work now. One search of the
-- platform's own surface by type, which holds only that platform (a few
-- chunks); nil while it has no surface.
function M.thrusters(p)
  local surface = read(function() return p.surface end)
  if not (surface and surface.valid) then return nil end
  local found = read(function() return surface.find_entities_filtered({ type = "thruster", force = p.force }) end)
  if not found then return nil end
  local working = 0
  for _, e in ipairs(found) do
    if read(function() return e.status end) == defines.entity_status.working then working = working + 1 end
  end
  return { count = #found, working = working }
end

-- What a trip reads of a platform (travel's phases, LAND_REFUSED): state,
-- location (nil between locations), speed, paused, whether it has its hub,
-- the stop it heads for {index, station, wait_conditions: their count} and,
-- with_thrusters, its thrusters {count, working}. Facts only.
function M.trip_facts(p, with_thrusters)
  local record, index = current_record(p, nil)
  local speed = read(function() return p.speed end)
  return { index = p.index, name = p.name, state = M.state_name(p), location = M.location(p),
    speed = type(speed) == "number" and math.floor(speed * 1000 + 0.5) / 1000 or nil,
    paused = read(function() return p.paused end), hub = hub_of(p) ~= nil,
    current_stop = record and { index = index, station = record.station,
      wait_conditions = #(record.wait_conditions or {}) } or nil,
    thrusters = with_thrusters and M.thrusters(p) or nil }
end

-- One platform's line: attribute reads, its route, the hub's free slots and
-- its request count (one read per request section); and the work it took.
function M.compact_row(p)
  local pack = read(function() return p.starter_pack end)
  local row = { index = p.index, name = p.name, state = M.state_name(p), location = M.location(p),
    scheduled_for_deletion = p.scheduled_for_deletion, speed = read(function() return p.speed end),
    paused = read(function() return p.paused end), travel = travel_of(p), schedule = schedule_of(p, false),
    starter_pack = pack and name_of(pack.name) or nil, trip = M.trip(p) }
  local hub, work = hub_of(p), 6 + (row.schedule and #row.schedule.records or 0)
  if hub then
    local main = hub_inventory(hub, "hub_main")
    row.hub_free_slots = main and main.count_empty_stacks() or nil
    if requests_reader then
      local reads
      row.requests_count, reads = requests_reader.count(hub)
      work = work + (reads or 0)
    end
  end
  return row, work
end

-- Every visible platform's line, at most MAX_COMPACT, how many the cap left
-- out, and the work it took.
function M.compact(force)
  local rows, list, work = {}, M.list(force), 1
  for i = 1, math.min(#list, M.MAX_COMPACT) do
    local spent
    rows[i], spent = M.compact_row(list[i])
    work = work + spent
  end
  return rows, math.max(0, #list - M.MAX_COMPACT), work
end

local function by_count(a, b)
  if a.count ~= b.count then return a.count > b.count end
  return a.item < b.item
end

-- An inventory's rows, the first `cap` by count kept as they are read (no
-- sort of every row); how many the cap left out, and how many were read.
local function contents(inventory, cap)
  local kept, n = {}, 0
  for _, item in ipairs(inventory and inventory.get_contents() or {}) do
    n = n + 1
    jobs.keep_first(kept, cap, { item = item.name, quality = name_of(item.quality) or "normal", count = item.count }, by_count)
  end
  table.sort(kept, by_count)
  return kept, n > cap and n - cap or nil, n
end

-- Entity rows kept: the first MAX_ENTITIES by (y, x).
local function before(a, b)
  if a.position.y ~= b.position.y then return a.position.y < b.position.y end
  if a.position.x ~= b.position.x then return a.position.x < b.position.x end
  return a.name < b.name
end

local function entity_row(e)
  local row = { name = e.name, position = xy(e.position), status = define_name("entity_status", read(function() return e.status end)) }
  local direction = read(function() return e.direction end)
  if direction and direction ~= 0 then row.direction = direction end
  if RECIPE_TYPES[e.type] then
    local recipe = read(function() return e.get_recipe() end)
    row.recipe = recipe and recipe.name or nil
  elseif e.type == "asteroid-collector" then
    local filters = {}
    for i = 1, read(function() return e.filter_slot_count end) or 0 do
      local chunk = name_of(read(function() return e.get_filter(i) end))
      if chunk then filters[#filters + 1] = chunk end
    end
    row.filters = filters
    local output = read(function() return e.get_inventory(defines.inventory.asteroid_collector_output) end)
    row.output = output and output.get_item_count() or nil
  end
  return row
end

-- Counts by entity name {name, count, working}, kept whole (never capped).
local function count_named(map, e, working)
  local row = map[e.name]
  if not row then row = { name = e.name, count = 0, working = 0 }; map[e.name] = row end
  row.count = row.count + 1
  if working then row.working = row.working + 1 end
  return row
end

-- A thruster's fuel and oxidizer amounts and capacities, and its name's count.
local function add_thruster(s, e)
  local t = s.thrusters
  t.count = t.count + 1
  local working = read(function() return e.status end) == defines.entity_status.working
  if working then t.working = t.working + 1 end
  count_named(t.by_name, e, working)
  local boxes = read(function() return e.fluidbox end)
  for i = 1, boxes and #boxes or 0 do
    local fluid = boxes[i]
    local capacity = read(function() return boxes.get_capacity(i) end) or 0
    local filter = name_of(read(function() return boxes.get_filter(i) end)) or (fluid and fluid.name)
    local kind = filter and THRUSTER_FLUIDS[filter]
    if kind then
      t[kind .. "_amount"] = t[kind .. "_amount"] + (fluid and fluid.amount or 0)
      t[kind .. "_capacity"] = t[kind .. "_capacity"] + capacity
    end
  end
end

-- Turrets by name: count, working and, for those that fire items, how many
-- hold no ammo and the ammo they hold by item. The ammo inventory's id by
-- turret type.
local TURRET_AMMO = { ["ammo-turret"] = "turret_ammo", ["artillery-turret"] = "artillery_turret_ammo",
  ["electric-turret"] = false, ["fluid-turret"] = false, turret = false }
local function add_turret(s, e)
  local row = count_named(s.turrets, e, read(function() return e.status end) == defines.entity_status.working)
  local inventory_id = TURRET_AMMO[e.type]
  if not inventory_id then return end
  local inventory = read(function() return e.get_inventory(defines.inventory[inventory_id]) end)
  local held = 0
  for _, item in ipairs(inventory and read(function() return inventory.get_contents() end) or {}) do
    held = held + item.count
    row.ammo = row.ammo or {}
    row.ammo[item.name] = (row.ammo[item.name] or 0) + item.count
  end
  if held == 0 then row.no_ammo = (row.no_ammo or 0) + 1 end
end

-- A name -> row map as rows by name; the ammo map in a row as
-- [{item, count}].
local function named_rows(map)
  local rows = {}
  for _, row in pairs(map) do
    if row.ammo then
      local ammo = {}
      for item, count in pairs(row.ammo) do ammo[#ammo + 1] = { item = item, count = count } end
      table.sort(ammo, function(a, b) return a.item < b.item end)
      row.ammo = ammo
    end
    rows[#rows + 1] = row
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

local function fill(amount, capacity)
  return capacity > 0 and math.floor(amount / capacity * 100 + 0.5) / 100 or nil
end

-- A read of `cost` work items starts only when it fits what is left of
-- this tick's budget; else it waits once for a fresh tick (which always has
-- jobs.MIN_WORK).
local function fits(s, cost, budget)
  if cost <= budget.left or s.waited then s.waited = nil; return true end
  s.waited = true
  return false
end

local CHUNK = 32
-- One chunk's tile or entity search: the call and what it returns, at most
-- a chunk's worth of tiles.
local CHUNK_READ = 1 + math.ceil(CHUNK * CHUNK / SCAN_PER_ITEM)

local function chunk_of(v) return math.floor(v / CHUNK) end

-- platform_status {platform?, detail?}. Compact: every platform's line, or
-- one platform's. Full (one platform): phases chunks -> tiles -> runs ->
-- entities <-> bucket -> hub -> requests -> missing -> finish, each spending
-- budget.left in work items. The platform's surface holds only its own
-- foundation, so the foundation is read chunk by chunk and folded into rows
-- at once; entities are searched chunk by chunk over the foundation's box,
-- each counted in the chunk its position falls in. The state is plain data
-- plus one chunk's entity references.
local function full_step(s, budget, force)
  local p, code, why = M.resolve(force, s.index or s.platform)
  if not p then error(code .. ": " .. why, 0) end
  s.index = p.index
  local hub = hub_of(p)
  if not hub then
    local row, work = M.compact_row(p)
    budget.left = budget.left - 1 - work
    return { tick = game.tick, platform = row, surface = M.surface_ref(p), hub = nil }
  end
  local surface = p.surface
  while budget.left > 0 do
    if s.phase == "chunks" then
      local chunks = {}
      for chunk in surface.get_chunks() do chunks[#chunks + 1] = { chunk.x, chunk.y } end
      s.chunks, s.ci, s.by_y, s.count = chunks, 1, {}, 0
      budget.left = budget.left - 1 - math.ceil(#chunks / SCAN_PER_ITEM)
      s.phase = "tiles"
    elseif s.phase == "tiles" then
      local chunk = s.chunks[s.ci]
      if not chunk then
        s.chunks, s.ys, s.yi, s.rows = nil, {}, 1, {}
        for key in pairs(s.by_y) do s.ys[#s.ys + 1] = tonumber(key) end
        table.sort(s.ys)
        budget.left = budget.left - 1 - math.ceil(#s.ys / SCAN_PER_ITEM)
        s.phase = "runs"
      else
        if not fits(s, CHUNK_READ, budget) then return nil end
        local x0, y0 = chunk[1] * CHUNK, chunk[2] * CHUNK
        local tiles = surface.find_tiles_filtered({ area = { { x0, y0 }, { x0 + CHUNK, y0 + CHUNK } }, name = FOUNDATION })
        for _, tile in ipairs(tiles) do
          local at = tile.position
          local x, y = at.x, at.y
          if chunk_of(x) == chunk[1] and chunk_of(y) == chunk[2] then
            local key = tostring(y)
            local xs = s.by_y[key]
            if not xs then xs = {}; s.by_y[key] = xs end
            xs[#xs + 1] = x
            s.count = s.count + 1
            if not s.box then s.box = { x, y, x, y } end
            local box = s.box
            box[1], box[2] = math.min(box[1], x), math.min(box[2], y)
            box[3], box[4] = math.max(box[3], x), math.max(box[4], y)
          end
        end
        s.ci = s.ci + 1
        budget.left = budget.left - 1 - math.ceil(#tiles / SCAN_PER_ITEM)
      end
    elseif s.phase == "runs" then
      local y = s.ys[s.yi]
      if not y then
        local box = s.box or { 0, 0, 0, 0 }
        s.by_y, s.ys, s.phase = nil, nil, "entities"
        s.cx0, s.cy0, s.cx1, s.cy1 = chunk_of(box[1]), chunk_of(box[2]), chunk_of(box[3]), chunk_of(box[4])
        s.cx, s.cy = s.cx0, s.cy0
        s.kept, s.missing, s.ghosts = {}, {}, { entities = 0, tiles = 0 }
        s.thrusters = { count = 0, working = 0, fuel_amount = 0, fuel_capacity = 0, oxidizer_amount = 0, oxidizer_capacity = 0,
          by_name = {} }
        s.turrets, s.hurt = {}, { entities = 0, missing = 0 }
        s.entity_count = 0
      else
        local xs = s.by_y[tostring(y)]
        table.sort(xs)
        local first, last = xs[1], xs[1]
        for k = 2, #xs + 1 do
          local x = xs[k]
          if x ~= last + 1 then
            s.rows[#s.rows + 1] = { y, first, last }
            first = x
          end
          last = x
        end
        s.yi = s.yi + 1
        budget.left = budget.left - 1 - math.ceil(#xs / SCAN_PER_ITEM)
      end
    elseif s.phase == "entities" then
      if s.cy > s.cy1 then
        s.phase = "hub"
      else
        if not fits(s, CHUNK_READ, budget) then return nil end
        local box = s.box or { 0, 0, 0, 0 }
        local x0, y0 = math.max(s.cx * CHUNK, box[1]), math.max(s.cy * CHUNK, box[2])
        local x1, y1 = math.min((s.cx + 1) * CHUNK, box[3] + 1), math.min((s.cy + 1) * CHUNK, box[4] + 1)
        s.found = surface.find_entities_filtered({ area = { { x0, y0 }, { x1, y1 } }, force = force })
        s.j, s.fcx, s.fcy = 1, s.cx, s.cy
        s.cx = s.cx + 1
        if s.cx > s.cx1 then s.cx, s.cy = s.cx0, s.cy + 1 end
        budget.left = budget.left - 1 - math.ceil(#s.found / SCAN_PER_ITEM)
        s.phase = "bucket"
      end
    elseif s.phase == "bucket" then
      local e = s.found[s.j]
      if not e then
        s.found, s.phase = nil, "entities"
      else
        s.j = s.j + 1
        budget.left = budget.left - 1
        -- An entity across a chunk edge counts once: in the chunk (of the
        -- box's chunks) its position falls in.
        local here = e.valid and e ~= hub
          and math.min(math.max(chunk_of(e.position.x), s.cx0), s.cx1) == s.fcx
          and math.min(math.max(chunk_of(e.position.y), s.cy0), s.cy1) == s.fcy
        if here and GHOST_TYPES[e.type] then
          local key = e.type == "tile-ghost" and "tiles" or "entities"
          s.ghosts[key] = s.ghosts[key] + 1
          local place = read(function() return e.ghost_prototype.items_to_place_this end)
          local first = place and place[1]
          if first then s.missing[first.name] = (s.missing[first.name] or 0) + (first.count or 1) end
        elseif here then
          s.entity_count = s.entity_count + 1
          if e.type == "thruster" then add_thruster(s, e) end
          if TURRET_AMMO[e.type] ~= nil then add_turret(s, e) end
          -- Damage it carries now: the health it is missing.
          local health, max = read(function() return e.health end), read(function() return e.max_health end)
          if type(health) == "number" and type(max) == "number" and health < max then
            s.hurt.entities, s.hurt.missing = s.hurt.entities + 1, s.hurt.missing + max - health
          end
          jobs.keep_first(s.kept, M.MAX_ENTITIES, entity_row(e), before)
          budget.left = budget.left - 3
        end
      end
    elseif s.phase == "hub" then
      local main, trash = hub_inventory(hub, "hub_main"), hub_inventory(hub, "hub_trash")
      local slots = (main and #main or 0) + (trash and #trash or 0)
      if not fits(s, 2 + math.ceil(slots / CONTENTS_PER_ITEM), budget) then return nil end
      local n_main, trash_rows, n_trash, _
      s.inventory, s.omitted_inventory, n_main = contents(main, M.MAX_HUB_ITEMS)
      trash_rows, _, n_trash = contents(trash, M.MAX_HUB_ITEMS)
      s.trash = trash_rows
      s.free_slots = main and main.count_empty_stacks() or nil
      budget.left = budget.left - 3 - math.ceil((n_main + n_trash) / CONTENTS_PER_ITEM)
      s.phase = "requests"
    elseif s.phase == "requests" then
      -- A read of every request slot, charged by what it read.
      if not fits(s, jobs.MIN_WORK, budget) then return nil end
      local reads
      if requests_reader then s.requests, reads = requests_reader.read(hub) end
      budget.left = budget.left - 1 - (reads or 0)
      s.missing_items = {}
      for item in pairs(s.missing) do s.missing_items[#s.missing_items + 1] = item end
      table.sort(s.missing_items)
      s.mi, s.short = 1, {}
      budget.left = budget.left - math.ceil(#s.missing_items / SCAN_PER_ITEM)
      s.phase = "missing"
    elseif s.phase == "missing" then
      -- What the ghosts need minus what the hub holds: one count per item.
      local item = s.missing_items[s.mi]
      if not item then
        s.missing_items, s.phase = nil, "finish"
      else
        s.mi = s.mi + 1
        local main = hub_inventory(hub, "hub_main")
        local short = s.missing[item] - (main and main.get_item_count({ name = item, quality = "normal" }) or 0)
        if short > 0 then s.short[#s.short + 1] = { item = item, count = short } end
        budget.left = budget.left - 1
      end
    else
      if not fits(s, jobs.MIN_WORK, budget) then return nil end
      table.sort(s.kept, before)
      local damaged = read(function() return p.damaged_tiles end) or {}
      local total = 0
      for _, tile in ipairs(damaged) do total = total + (tile.damage or 0) end
      local rows, box = s.rows, s.box or { 0, 0, 0, 0 }
      local omitted_rows = math.max(0, #rows - M.MAX_ROWS)
      while #rows > M.MAX_ROWS do table.remove(rows) end
      local t = s.thrusters
      local row, work = M.compact_row(p)
      budget.left = budget.left - 2 - work - math.ceil(#damaged / SCAN_PER_ITEM)
      return {
        tick = game.tick, platform = row, surface = M.surface_ref(p), schedule = schedule_of(p, true),
        foundation = { tiles = s.count, bbox = { left_top = { x = box[1], y = box[2] },
          right_bottom = { x = box[3] + 1, y = box[4] + 1 } }, rows = rows,
          omitted_rows = omitted_rows > 0 and omitted_rows or nil },
        hub = { position = xy(hub.position), inventory = s.inventory, omitted_inventory = s.omitted_inventory, trash = s.trash,
          free_slots = s.free_slots },
        requests = s.requests,
        entities = s.kept, omitted_entities = s.entity_count > #s.kept and s.entity_count - #s.kept or nil,
        thrusters = t.count > 0 and { count = t.count, working = t.working, fuel_fill = fill(t.fuel_amount, t.fuel_capacity),
          oxidizer_fill = fill(t.oxidizer_amount, t.oxidizer_capacity), by_name = named_rows(t.by_name) } or nil,
        -- Every turret, by name, whatever the entity list's cap left out.
        turrets = next(s.turrets) and named_rows(s.turrets) or nil,
        ghosts = { entities = s.ghosts.entities, tiles = s.ghosts.tiles, missing = s.short },
        damage = { damaged_tiles = #damaged, total = math.floor(total * 10 + 0.5) / 10,
          damaged_entities = s.hurt.entities, entity_health_missing = math.floor(s.hurt.missing * 10 + 0.5) / 10 },
        trip = M.trip(p),
      }
    end
  end
  return nil
end

-- A read: in every body state but absent (aboard and in transit too).
M.status_job = {
  start = function(params)
    local detail = params.detail or "compact"
    if detail ~= "compact" and detail ~= "full" then error('platform_status detail must be "compact" or "full"', 0) end
    if params.platform ~= nil then M.check_selector(params.platform, "platform_status platform") end
    if detail == "full" and params.platform == nil then error("platform_status detail full reads one platform: name it", 0) end
    companion.require_present()
    return { detail = detail, platform = params.platform, phase = "chunks" }
  end,
  step = function(s, budget)
    local force = companion.require_present().force
    if s.detail == "full" then return full_step(s, budget, force) end
    local rows, omitted, work
    if s.platform ~= nil then
      local p, code, why = M.resolve(force, s.platform)
      if not p then error(code .. ": " .. why, 0) end
      local row
      row, work = M.compact_row(p)
      rows, omitted = { row }, 0
    else
      rows, omitted, work = M.compact(force)
    end
    budget.left = budget.left - 1 - work
    return { tick = game.tick, platforms = rows, omitted_platforms = omitted > 0 and omitted or nil }
  end,
}

-- ----------------------------------------------------------- create_platform

local function check_create(params, label)
  if type(params.name) ~= "string" or #params.name < 1 or #params.name > M.MAX_NAME then
    error(string.format("%s name must be 1-%d characters", label, M.MAX_NAME), 0)
  end
  if params.planet ~= nil and (type(params.planet) ~= "string" or params.planet == "") then
    error(label .. " planet must be a planet name", 0)
  end
  -- The pack launch_rocket supplies and loads is a normal one.
  if params.quality ~= nil and params.quality ~= "normal" then error(label .. ' quality must be "normal"', 0) end
end

-- The new platform, or nil, the code and why. Validated before the one write.
-- Over the named planet, else the planet the body stands on.
local function create(body, params)
  local force = body.force
  if not force.is_space_platforms_unlocked() then
    return nil, "PLATFORMS_LOCKED", "space platforms are not unlocked yet (research rocket-silo)"
  end
  for _, p in ipairs(M.list(force)) do
    if p.name == params.name then return nil, "NAME_TAKEN", "platform " .. p.index .. " is already called " .. params.name end
  end
  local planet = params.planet
  if planet then
    if not read(function() return game.planets[planet] end) then return nil, "UNKNOWN_PLANET", "no planet called " .. planet end
    if not M.location_unlocked(force, planet) then return nil, "LOCATION_LOCKED", planet .. " is not unlocked yet" end
  else
    planet = read(function() return body.surface.planet.name end)
    if not planet then
      return nil, "NOT_ON_A_PLANET", "a platform is made over the planet the body stands on, or over the planet you name"
    end
  end
  local ok, p = pcall(force.create_space_platform, { name = params.name, planet = planet,
    starter_pack = { name = M.STARTER_PACK, quality = "normal" } })
  if not (ok and p) then return nil, "CREATE_FAILED", ok and "the game made no platform" or tostring(p) end
  local created = space().created
  for index in pairs(created) do
    if not (force.platforms[index] and force.platforms[index].valid) then created[index] = nil end
  end
  created[p.index] = planet
  -- A reused index starts with no trip.
  if space().trips then space().trips[p.index] = nil end
  M.milestone("platform_created_tick")
  return { code = "PLATFORM_CREATED", platform = { index = p.index, name = p.name, state = M.state_name(p), planet = planet },
    next = "craft a " .. M.STARTER_PACK .. " and launch it to this platform with launch_rocket" }
end

-- create_platform {name, quality?, planet?} over RPC: at once.
function M.create_platform(params)
  check_create(params, "create_platform")
  local result, code, why = create(companion.require_present(), params)
  if not result then error(code .. ": " .. why, 0) end
  return result
end

local CreateRunner = {}
function CreateRunner.start(task)
  companion.require_present()
  check_create(task, "create_platform")
end
function CreateRunner.tick(task)
  local result, code, why = create(companion.require_present(), task)
  if not result then return { status = "failed", detail = code .. ": " .. why, outcome = { code = code } } end
  return { status = "done", detail = string.format("created platform %s (%d) over %s: it waits for its starter pack",
    result.platform.name, result.platform.index, result.platform.planet), outcome = result }
end

-- The plan action: remote, done in the tick the FIFO reaches it.
M.create_action = {
  runner = CreateRunner,
  make_task = function(step) return { name = step.name, planet = step.planet } end,
  validate = function(step, index) check_create(step, "queue_plan create_platform step " .. index) end,
  remote = function() return true end,
}

-- -------------------------------------------------------- set_platform_route

M.MAX_STOPS = 10
M.MAX_WAITS = 10
-- WaitConditionType (2.0.77): every literal the game takes.
local WAIT_TYPES = {}
for _, name in ipairs({ "time", "full", "empty", "not_empty", "item_count", "circuit", "inactivity", "robots_inactive",
  "fluid_count", "passenger_present", "passenger_not_present", "fuel_item_count_all", "fuel_item_count_any", "fuel_full",
  "destination_full_or_no_path", "request_satisfied", "request_not_satisfied", "all_requests_satisfied",
  "any_request_not_satisfied", "any_request_zero", "any_planet_import_zero", "specific_destination_full",
  "specific_destination_not_full", "at_station", "not_at_station", "damage_taken" }) do WAIT_TYPES[name] = true end
-- WaitCondition fields and their Lua types; condition is the game's own
-- CircuitCondition or item-and-quality pair, passed through as given.
local WAIT_FIELDS = { type = "string", compare_type = "string", ticks = "number", condition = "table",
  planet = "string", station = "string", damage = "number" }

local function check_wait(wait, label)
  if type(wait) ~= "table" then error(label .. " must be a wait condition table", 0) end
  for key, value in pairs(wait) do
    if not WAIT_FIELDS[key] then
      error(string.format("%s has no field %s (type, compare_type, ticks, condition, planet, station, damage)", label, tostring(key)), 0)
    end
    if type(value) ~= WAIT_FIELDS[key] then error(string.format("%s %s must be a %s", label, key, WAIT_FIELDS[key]), 0) end
  end
  if not WAIT_TYPES[wait.type] then error(label .. " type must be a WaitConditionType literal, such as time or all_requests_satisfied", 0) end
  if wait.compare_type ~= nil and wait.compare_type ~= "and" and wait.compare_type ~= "or" then
    error(label .. ' compare_type must be "and" or "or"', 0)
  end
  for _, key in ipairs({ "ticks", "damage" }) do
    local n = wait[key]
    if n ~= nil and (n % 1 ~= 0 or n < 0) then error(label .. " " .. key .. " must be a whole number from 0", 0) end
  end
end

local function check_route(params, label)
  M.check_selector(params.platform, label .. " platform")
  if params.stops == nil and params.go_to == nil and params.paused == nil then
    error(label .. " needs stops, go_to or paused", 0)
  end
  local stops = params.stops
  if stops ~= nil then
    if type(stops) ~= "table" or #stops < 1 or #stops > M.MAX_STOPS then
      error(string.format("%s stops must list 1-%d stops", label, M.MAX_STOPS), 0)
    end
    for i, stop in ipairs(stops) do
      local at = string.format("%s stop %d", label, i)
      if type(stop) ~= "table" or type(stop.location) ~= "string" then error(at .. " needs a location", 0) end
      if not read(function() return prototypes.space_location[stop.location] end) then
        error(string.format("UNKNOWN_LOCATION: %s: no space location called %s", at, stop.location), 0)
      end
      if stop.wait ~= nil then
        if type(stop.wait) ~= "table" or #stop.wait > M.MAX_WAITS then
          error(string.format("%s wait must list at most %d wait conditions", at, M.MAX_WAITS), 0)
        end
        for k, wait in ipairs(stop.wait) do check_wait(wait, at .. " wait " .. k) end
      end
      if stop.unloading ~= nil and type(stop.unloading) ~= "boolean" then error(at .. " unloading must be true or false", 0) end
    end
  end
  local go_to = params.go_to
  if go_to ~= nil and (type(go_to) ~= "number" or go_to % 1 ~= 0 or go_to < 1 or stops and go_to > #stops) then
    error(label .. " go_to must be the 1-based number of one of its stops", 0)
  end
  if params.paused ~= nil and type(params.paused) ~= "boolean" then error(label .. " paused must be true or false", 0) end
end

-- A wait condition's `condition` with the defaults the game fills in when
-- it reads one back (2.0.77): a CircuitCondition's comparator "<", a
-- signal's type "item" (read back as nil) and quality "normal", an item
-- pair's quality "normal"; a prototype read back as an object is its name.
local SIGNAL_DEFAULTS = { type = "item", quality = "normal" }
local function normal_value(value)
  if type(value) == "userdata" or type(value) == "table" and value.object_name then
    return read(function() return value.name end)
  end
  return value
end
local function normal_condition(condition)
  if type(condition) ~= "table" then return condition end
  local out = {}
  for key, value in pairs(condition) do
    if type(value) == "table" and not value.object_name then
      local signal = {}
      for field, v in pairs(value) do signal[field] = normal_value(v) end
      for field, default in pairs(SIGNAL_DEFAULTS) do if signal[field] == nil then signal[field] = default end end
      out[key] = signal
    else
      out[key] = normal_value(value)
    end
  end
  if out.name ~= nil and out.quality == nil then out.quality = "normal" end
  if (out.first_signal ~= nil or out.second_signal ~= nil or out.constant ~= nil) and out.comparator == nil then
    out.comparator = "<"
  end
  return out
end

-- Whether every field asked for is in the read-back value (one way: the
-- game may add fields it fills in, such as a constant of 0).
local function holds(asked, got)
  if type(asked) ~= "table" then return asked == got end
  if type(got) ~= "table" then return false end
  for key, value in pairs(asked) do if not holds(value, got[key]) then return false end end
  return true
end

-- Whether a read-back record is the stop as asked: its station, unloading
-- and each wait condition's fields as given (compare_type reads back "and"
-- when it was left out; a condition compares with the game's defaults
-- filled in on both sides).
local function record_is(record, stop)
  if record.station ~= stop.location or (record.allows_unloading ~= false) ~= (stop.unloading ~= false) then return false end
  local waits, read_back = stop.wait or {}, record.wait_conditions or {}
  if #waits ~= #read_back then return false end
  for i, wait in ipairs(waits) do
    local got = read_back[i]
    for key, value in pairs(wait) do
      if key == "condition" then
        if not holds(normal_condition(value), normal_condition(got.condition)) then return false end
      elseif value ~= got[key] then
        return false
      end
    end
    if wait.compare_type == nil and (got.compare_type or "and") ~= "and" then return false end
  end
  return true
end

local function records_are(records, stops)
  if #records ~= #stops then return false end
  for i, stop in ipairs(stops) do if not record_is(records[i], stop) then return false end end
  return true
end

-- Writes the route through the platform's schedule object (never
-- LuaSpacePlatform.schedule, which drops interrupts): the stops replace the
-- records, go_to heads for one, paused holds thrust. Everything is checked
-- first; stops the game does not keep as given are put back as they were
-- (ROUTE_REJECTED). Repeating the same route changes nothing.
local function set_route(force, task)
  local p, code, why = M.resolve(force, task.platform)
  if not p then return nil, code, why end
  for _, stop in ipairs(task.stops or {}) do
    if not M.location_unlocked(force, stop.location) then
      return nil, "LOCATION_LOCKED", stop.location .. " is not unlocked yet: research its discovery technology first"
    end
  end
  local schedule = read(function() return p.get_schedule() end)
  if not schedule then return nil, "NO_SCHEDULE", "platform " .. p.name .. " has no schedule yet: launch its starter pack first" end
  local previous = schedule.get_records() or {}
  if task.go_to and not task.stops and task.go_to > #previous then
    return nil, "NO_SUCH_STOP", string.format("platform %s has %d stops; there is no stop %d", p.name, #previous, task.go_to)
  end
  local changed = {}
  if task.stops and not records_are(previous, task.stops) then
    schedule.clear_records()
    for _, stop in ipairs(task.stops) do
      schedule.add_record({ station = stop.location, wait_conditions = stop.wait, allows_unloading = stop.unloading ~= false })
    end
    local kept = schedule.get_records() or {}
    if not records_are(kept, task.stops) then
      schedule.clear_records()
      if #previous > 0 then schedule.set_records(previous) end
      return nil, "ROUTE_REJECTED", string.format("the game kept %d of the %d stops differently from what was asked;"
        .. " the old route is back (check the wait conditions against WaitCondition)", #kept, #task.stops)
    end
    changed[#changed + 1] = "stops"
  end
  if task.go_to and (changed[1] or schedule.current ~= task.go_to) then
    schedule.go_to_station(task.go_to)
    changed[#changed + 1] = "go_to"
  end
  if task.paused ~= nil and p.paused ~= task.paused then
    p.paused = task.paused
    changed[#changed + 1] = "paused"
  end
  return { code = "ROUTE_SET", platform = { index = p.index, name = p.name }, state = M.state_name(p),
    paused = p.paused, schedule = schedule_of(p, true), travel = travel_of(p), changed = changed }
end

local function route_params(params)
  return { platform = params.platform, stops = params.stops, go_to = params.go_to, paused = params.paused }
end

-- set_platform_route {platform, stops?, go_to?, paused?} over RPC: at once.
function M.set_platform_route(params)
  check_route(params, "set_platform_route")
  local result, code, why = set_route(companion.require_present().force, route_params(params))
  if not result then error(code .. ": " .. why, 0) end
  return result
end

local RouteRunner = {}
function RouteRunner.start(task)
  companion.require_present()
  check_route(task, "set_platform_route")
end
function RouteRunner.tick(task)
  local result, code, why = set_route(companion.require_present().force, task)
  if not result then return { status = "failed", detail = code .. ": " .. why, outcome = { code = code } } end
  return { status = "done", detail = string.format("platform %s's route: %s", result.platform.name,
    #result.changed > 0 and table.concat(result.changed, ", ") .. " set" or "unchanged"), outcome = result }
end

-- The plan action: remote, done in the tick the FIFO reaches it.
M.route_action = {
  runner = RouteRunner,
  make_task = route_params,
  validate = function(step, index) check_route(step, "queue_plan set_platform_route step " .. index) end,
  remote = function() return true end,
}

-- ------------------------------------------------------------------ events

-- The body's force, in every body state (aboard and in transit too).
local function own(force)
  local mine = companion.body().force
  local ok, same = pcall(function() return not mine or force.name == mine.name end)
  return ok and same
end

local function platform_ref(p)
  return read(function() return { index = p.index, name = p.name } end)
end

-- Appends one entry: {tick, kind, ...fields}.
function M.record(kind, fields)
  local s = space()
  local row = fields or {}
  row.tick, row.kind = game.tick, kind
  s.events[#s.events + 1] = row
  while #s.events > M.EVENT_RING do table.remove(s.events, 1) end
  s.last_event_tick = game.tick
end

-- The first tick of a run milestone (storage.milestones, state.lua).
local function first(key, tick)
  storage.milestones = storage.milestones or {}
  if storage.milestones[key] == nil then storage.milestones[key] = tick end
end
-- Space milestones the body's moves mark (control.lua): boarded_tick,
-- landed_tick.
function M.milestone(key) first(key, game.tick) end

-- Where a rocket's cargo pod goes: the platform, if any. Read when the
-- launch is ordered: the pod leaves the rocket before it finishes ascending.
local function destination_platform(rocket)
  local destination = read(function() return rocket.attached_cargo_pod.cargo_pod_destination end)
  if not destination then return nil end
  if destination.space_platform then return destination.space_platform end
  return read(function() return destination.station.surface.platform end)
end

function M.on_rocket_launch_ordered(event)
  pcall(function()
    local silo = event.rocket_silo
    if not own(silo.force) then return end
    local p = destination_platform(event.rocket)
    first("rocket_launch_ordered_tick", event.tick)
    M.record("rocket_launch_ordered", { silo = xy(silo.position), platform = p and platform_ref(p) or nil })
  end)
end

-- The rocket left (on_rocket_launched, after its ascent; the silo is gone
-- when it was destroyed meanwhile).
function M.on_rocket_launched(event)
  pcall(function()
    local silo = event.rocket_silo
    local force = read(function() return silo.force end) or read(function() return event.rocket.force end)
    if not (force and own(force)) then return end
    first("rocket_launched_tick", event.tick)
    M.record("rocket_launched", { silo = read(function() return xy(silo.position) end) })
  end)
end

-- A platform waiting at a station has arrived there: platform_arrived, and
-- the arrival a travel step waiting aboard reads (storage.travel.arrivals).
function M.on_platform_state_changed(event)
  pcall(function()
    local p = event.platform
    if not own(p.force) then return end
    local state = M.state_name(p)
    M.record("platform_state_changed", { platform = platform_ref(p), old = define_name("space_platform_state", event.old_state),
      new = state })
    local location = M.location(p)
    -- Its pack landed: the platform names its own location from now on.
    if location then space().created[p.index] = nil end
    -- It departs: a new trip, whose losses count from here.
    if state == "on_the_path" and define_name("space_platform_state", event.old_state) ~= "on_the_path" then
      local trips = space().trips or {}
      space().trips = trips
      trips[p.index] = { departed_tick = game.tick, from = name_of(read(function() return p.last_visited_space_location end)),
        lost = {} }
    end
    if state == "waiting_at_station" and location then
      M.record("platform_arrived", { platform = platform_ref(p), location = location })
      -- A trip's end (it was on its way), not the starter pack's landing.
      if define_name("space_platform_state", event.old_state) == "on_the_path" then first("arrived_tick", game.tick) end
      storage.travel = storage.travel or {}
      storage.travel.arrivals = storage.travel.arrivals or {}
      storage.travel.arrivals[p.index] = { location = location, tick = game.tick }
    end
  end)
end

function M.on_cargo_pod_finished_descending(event)
  pcall(function()
    local pod = event.cargo_pod
    if not own(pod.force) then return end
    local surface = pod.surface
    local p = read(function() return surface.platform end)
    M.record("cargo_delivered", p and { platform = platform_ref(p) } or { surface = surface.name })
  end)
end

-- A sampled silo's rocket became ready (autonomy's sampler).
function M.on_rocket_ready(silo)
  pcall(function()
    first("rocket_ready_tick", game.tick)
    M.record("rocket_ready", { silo = xy(silo.position) })
  end)
end

-- Trips: storage.space.trips[index] = {departed_tick, from, lost = {[name]
-- = count}}, begun at each departure (on_platform_state_changed); an own
-- entity destroyed on that platform's surface counts as lost on it.
M.MAX_LOST_NAMES = 16
function M.on_entity_died(event)
  pcall(function()
    local trips = storage.space and storage.space.trips
    if not trips then return end
    local e = event.entity
    local p = e.surface.platform
    local trip = p and trips[p.index]
    if not (trip and own(e.force)) then return end
    local lost = trip.lost
    if lost[e.name] == nil then
      local n = 0
      for _ in pairs(lost) do n = n + 1 end
      if n >= M.MAX_LOST_NAMES then trip.lost_other = (trip.lost_other or 0) + 1; return end
    end
    lost[e.name] = (lost[e.name] or 0) + 1
  end)
end

-- A platform's last trip as readers see it: {departed_tick, from, lost:
-- [{name, count}] by name, lost_other?}; nil before its first departure.
function M.trip(p)
  local trip = storage.space and storage.space.trips and storage.space.trips[p.index]
  if not trip then return nil end
  local lost = {}
  for name, count in pairs(trip.lost) do lost[#lost + 1] = { name = name, count = count } end
  table.sort(lost, function(a, b) return a.name < b.name end)
  return { departed_tick = trip.departed_tick, from = trip.from, lost = lost, lost_other = trip.lost_other }
end

-- For event_state: the tick of the newest entry and the last few.
function M.event_state()
  local s = storage.space
  if not s then return nil, nil end
  local rows = {}
  for i = math.max(1, #s.events - M.EVENT_STATE_ROWS + 1), #s.events do rows[#rows + 1] = s.events[i] end
  return s.last_event_tick, #rows > 0 and rows or nil
end

return M
