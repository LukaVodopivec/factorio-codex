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
--   create_platform the "new platform" button over the body's planet: the
--                 platform waits for its starter pack, which launch_rocket
--                 sends; nothing is built or consumed
--   events        a ring of the last space events (rockets launched, platform
--                 state changes, cargo pods landed, rockets ready) that
--                 event_state and next_event read; only event handlers write it
-- storage.space = {created = {[index] = planet}, events = {...}, last_event_tick}.
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

-- One platform's line: attribute reads, the hub's free slots and its
-- request count (one read per request section); and the work it took.
function M.compact_row(p)
  local pack = read(function() return p.starter_pack end)
  local row = { index = p.index, name = p.name, state = M.state_name(p), location = M.location(p),
    scheduled_for_deletion = p.scheduled_for_deletion, speed = read(function() return p.speed end),
    starter_pack = pack and name_of(pack.name) or nil }
  local hub, work = hub_of(p), 4
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

-- A thruster's fuel and oxidizer amounts and capacities.
local function add_thruster(s, e)
  local t = s.thrusters
  t.count = t.count + 1
  if read(function() return e.status end) == defines.entity_status.working then t.working = t.working + 1 end
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
        s.thrusters = { count = 0, working = 0, fuel_amount = 0, fuel_capacity = 0, oxidizer_amount = 0, oxidizer_capacity = 0 }
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
          jobs.keep_first(s.kept, M.MAX_ENTITIES, entity_row(e), before)
          budget.left = budget.left - 2
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
        tick = game.tick, platform = row, surface = M.surface_ref(p),
        foundation = { tiles = s.count, bbox = { left_top = { x = box[1], y = box[2] },
          right_bottom = { x = box[3] + 1, y = box[4] + 1 } }, rows = rows,
          omitted_rows = omitted_rows > 0 and omitted_rows or nil },
        hub = { position = xy(hub.position), inventory = s.inventory, omitted_inventory = s.omitted_inventory, trash = s.trash,
          free_slots = s.free_slots },
        requests = s.requests,
        entities = s.kept, omitted_entities = s.entity_count > #s.kept and s.entity_count - #s.kept or nil,
        thrusters = t.count > 0 and { count = t.count, working = t.working, fuel_fill = fill(t.fuel_amount, t.fuel_capacity),
          oxidizer_fill = fill(t.oxidizer_amount, t.oxidizer_capacity) } or nil,
        ghosts = { entities = s.ghosts.entities, tiles = s.ghosts.tiles, missing = s.short },
        damage = { damaged_tiles = #damaged, total = math.floor(total * 10 + 0.5) / 10 },
      }
    end
  end
  return nil
end

M.status_job = {
  start = function(params)
    local detail = params.detail or "compact"
    if detail ~= "compact" and detail ~= "full" then error('platform_status detail must be "compact" or "full"', 0) end
    if params.platform ~= nil then M.check_selector(params.platform, "platform_status platform") end
    if detail == "full" and params.platform == nil then error("platform_status detail full reads one platform: name it", 0) end
    companion.require_companion()
    return { detail = detail, platform = params.platform, phase = "chunks" }
  end,
  step = function(s, budget)
    local force = companion.require_companion().force
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
  -- The pack launch_rocket supplies and loads is a normal one.
  if params.quality ~= nil and params.quality ~= "normal" then error(label .. ' quality must be "normal"', 0) end
end

-- The new platform, or nil, the code and why. Validated before the one write.
local function create(c, params)
  local force = c.force
  if not force.is_space_platforms_unlocked() then
    return nil, "PLATFORMS_LOCKED", "space platforms are not unlocked yet (research rocket-silo)"
  end
  for _, p in ipairs(M.list(force)) do
    if p.name == params.name then return nil, "NAME_TAKEN", "platform " .. p.index .. " is already called " .. params.name end
  end
  local planet = read(function() return c.surface.planet.name end)
  if not planet then return nil, "NOT_ON_A_PLANET", "a platform is made over the planet the body stands on" end
  local ok, p = pcall(force.create_space_platform, { name = params.name, planet = planet,
    starter_pack = { name = M.STARTER_PACK, quality = "normal" } })
  if not (ok and p) then return nil, "CREATE_FAILED", ok and "the game made no platform" or tostring(p) end
  local created = space().created
  for index in pairs(created) do
    if not (force.platforms[index] and force.platforms[index].valid) then created[index] = nil end
  end
  created[p.index] = planet
  return { code = "PLATFORM_CREATED", platform = { index = p.index, name = p.name, state = M.state_name(p), planet = planet },
    next = "craft a " .. M.STARTER_PACK .. " and launch it to this platform with launch_rocket" }
end

-- create_platform {name, quality?} over RPC: at once.
function M.create_platform(params)
  check_create(params, "create_platform")
  local result, code, why = create(companion.require_companion(), params)
  if not result then error(code .. ": " .. why, 0) end
  return result
end

local CreateRunner = {}
function CreateRunner.start(task)
  companion.require_companion()
  check_create(task, "create_platform")
end
function CreateRunner.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  local result, code, why = create(c, task)
  if not result then return { status = "failed", detail = code .. ": " .. why, outcome = { code = code } } end
  return { status = "done", detail = string.format("created platform %s (%d) over %s: it waits for its starter pack",
    result.platform.name, result.platform.index, result.platform.planet), outcome = result }
end

-- The plan action: remote, done in the tick the FIFO reaches it.
M.create_action = {
  runner = CreateRunner,
  make_task = function(step) return { name = step.name } end,
  validate = function(step, index) check_create(step, "queue_plan create_platform step " .. index) end,
  remote = function() return true end,
}

-- ------------------------------------------------------------------ events

local function own(force)
  local c = companion.get()
  local ok, same = pcall(function() return not (c and c.valid) or force.name == c.force.name end)
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
    M.record("rocket_launched", { silo = xy(silo.position), platform = p and platform_ref(p) or nil })
  end)
end

function M.on_platform_state_changed(event)
  pcall(function()
    local p = event.platform
    if not own(p.force) then return end
    M.record("platform_state_changed", { platform = platform_ref(p), old = define_name("space_platform_state", event.old_state),
      new = M.state_name(p) })
    -- Its pack landed: the platform names its own location from now on.
    if M.location(p) then space().created[p.index] = nil end
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
  pcall(function() M.record("rocket_ready", { silo = xy(silo.position) }) end)
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
