-- factory_status: one compact read of the whole factory for both roles.
-- event_state: the cheap probe the bridge's next_event wait polls.
-- Both never query entities: lines and problems come from autonomy.lua's
-- samples, stock and power from map_summary's status cache (refreshed from
-- the event-maintained registry a few entities a tick; stock_power_tick says
-- when), patches from map_summary's per-chunk cache, research from a cache
-- that every research event drops (live current/progress/queue). The only
-- scan is refilling that research cache once after a research event.
-- registry_ready, stock_power_ready and patches_ready are false while an
-- upgraded save's bootstrap or first refresh still runs. The default read
-- stays under about 6 KB: one RCON chunk pair, not a multi-part answer.
local companion = require("scripts.companion")
local autonomy = require("scripts.autonomy")
local map_summary = require("scripts.map_summary")
local research = require("scripts.research")
local registry = require("scripts.registry")
local tasks = require("scripts.tasks")

local M = {}

local SECTIONS = { lines = true, problems = true, power = true, stock = true, research = true,
  body = true, patches = true }
local MAX_LINES, MAX_PROBLEMS, MAX_POWER, MAX_STOCK_ITEMS, MAX_HOLDERS = 10, 6, 2, 6, 1
local MAX_PATCHES, MAX_AVAILABLE, MAX_INVENTORY = 4, 6, 8
-- Lines that need attention survive the cap first: a starved line with a
-- high id is never hidden behind running ones.
local LINE_RANK = { no_power = 1, no_fuel = 2, starved = 3, output_full = 4, idle = 5, running = 6 }
-- Dead machines first, then blocked output.
local PROBLEM_RANK = { no_power = 1, not_plugged_in_electric_network = 1, no_fuel = 1,
  no_minable_resources = 2, full_output = 3, waiting_for_space_in_destination = 3 }

local function cap(rows, limit)
  local omitted = math.max(0, #rows - limit)
  while #rows > limit do table.remove(rows) end
  return omitted > 0 and omitted or nil
end

local function xy(position) return { x = position.x, y = position.y } end

local function parse(params)
  local since = params.since_tick
  if since ~= nil and (type(since) ~= "number" or since % 1 ~= 0 or since < 0) then
    error("since_tick must be a non-negative integer tick")
  end
  local want = {}
  if params.sections == nil then
    for name in pairs(SECTIONS) do want[name] = true end
  else
    if type(params.sections) ~= "table" then error("sections must be an array of section names") end
    for _, name in ipairs(params.sections) do
      if not SECTIONS[name] then error("unknown factory_status section: " .. tostring(name)) end
      want[name] = true
    end
  end
  return since, want
end

local function body_section(c)
  local counts = {}
  local inventory = c.get_main_inventory()
  for _, item in ipairs(inventory and inventory.get_contents() or {}) do
    counts[#counts + 1] = { name = item.name, count = item.count }
  end
  table.sort(counts, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  local omitted = cap(counts, MAX_INVENTORY)
  local summary = {}
  for _, row in ipairs(counts) do summary[row.name] = (summary[row.name] or 0) + row.count end
  local ok, held = pcall(companion.human_control)
  return { position = xy(c.position), inventory_summary = summary, inventory_omitted = omitted,
    queue_depth = tasks.queue_length(), active_step = tasks.active_summary(),
    crafting_queue_size = c.crafting_queue_size or 0, human_control = ok and held == true }
end

local function patches_section(c)
  local cached, ready = map_summary.patches()
  local rows = {}
  for _, patch in ipairs(cached) do
    local dx, dy = patch.centroid.x - c.position.x, patch.centroid.y - c.position.y
    rows[#rows + 1] = { name = patch.name, amount = patch.amount, tiles = patch.tiles,
      position = patch.centroid, distance = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5) }
  end
  table.sort(rows, function(x, y)
    if x.distance ~= y.distance then return x.distance < y.distance end
    return x.name < y.name
  end)
  return rows, cap(rows, MAX_PATCHES), ready
end

-- Available technologies change only on research events, which drop the
-- cache; current research, progress and queue are cheap live reads.
local function research_section(c)
  local cache = storage.research_cache
  if not cache then
    local available = {}
    for _, technology in ipairs(research.progression_status({}).available or {}) do available[#available + 1] = technology.name end
    cache = { available = available }
    storage.research_cache = cache
  end
  local force = c.force
  local queue = {}
  for _, technology in ipairs(force.research_queue or {}) do queue[#queue + 1] = technology.name end
  local available = { table.unpack(cache.available) }
  return { current = force.current_research and force.current_research.name or nil,
    progress = force.research_progress or 0, queue = queue, available = available,
    omitted_available = cap(available, MAX_AVAILABLE) }
end

function M.on_research_changed() storage.research_cache = nil end
M.RESEARCH_EVENTS = { "on_research_started", "on_research_finished", "on_research_cancelled", "on_research_reversed",
  "on_research_queued", "on_research_moved", "on_technology_effects_reset" }

function M.factory_status(params)
  local since, want = parse(params or {})
  local c = companion.require_companion()
  local result = { tick = game.tick, since_tick = since, registry_ready = registry.ready() }
  if want.lines then
    result.lines = autonomy.lines(since)
    table.sort(result.lines, function(x, y)
      local rx, ry = LINE_RANK[x.state] or 5, LINE_RANK[y.state] or 5
      if rx ~= ry then return rx < ry end
      return x.id < y.id
    end)
    result.omitted_lines = cap(result.lines, MAX_LINES)
    result.lines_error = storage.autonomy and storage.autonomy.refresh_error
  end
  if want.problems then
    local rows = autonomy.problems(since)
    table.sort(rows, function(x, y)
      local rx, ry = PROBLEM_RANK[x.status] or 4, PROBLEM_RANK[y.status] or 4
      if rx ~= ry then return rx < ry end
      if x.position.y ~= y.position.y then return x.position.y < y.position.y end
      return x.position.x < y.position.x
    end)
    result.problems, result.omitted_problems = rows, cap(rows, MAX_PROBLEMS)
  end
  if want.power or want.stock then
    local own = map_summary.status_sections()
    result.stock_power_tick, result.stock_power_ready = own.updated_tick, own.ready
    if want.power then
      local rows = {}
      for _, network in ipairs(own.power) do
        rows[#rows + 1] = { network_id = network.id, satisfaction = network.satisfaction,
          production_w = network.production_w, capacity_w = network.capacity_w, demand_w = network.demand_w,
          engines_needed = network.engines_needed }
      end
      table.sort(rows, function(x, y)
        if x.capacity_w ~= y.capacity_w then return x.capacity_w > y.capacity_w end
        return x.network_id < y.network_id
      end)
      result.power, result.omitted_power = rows, cap(rows, MAX_POWER)
    end
    if want.stock then
      local rows = {}
      for _, item in ipairs(own.stockpiles) do
        local holders = {}
        for index = 1, math.min(MAX_HOLDERS, #item.holders) do
          local holder = item.holders[index]
          holders[index] = { position = holder.position, kind = holder.kind, count = holder.count }
        end
        rows[#rows + 1] = { item = item.item, total = item.total, holders = holders }
      end
      result.stock, result.omitted_stock = rows, cap(rows, MAX_STOCK_ITEMS)
    end
  end
  if want.research then result.research = research_section(c) end
  if want.body then result.body = body_section(c) end
  if want.patches then result.patches, result.omitted_patches, result.patches_ready = patches_section(c) end
  return result
end

-- The mod's own upkeep plans are not pilot work: they neither fill nor
-- empty the FIFO for next_event, so an upkeep refuel never wakes a pilot
-- that waits on an empty queue.
local function pilot_work(task)
  return task ~= nil and not (task.type == "plan" and task.source == "upkeep")
end

function M.event_state()
  local t = storage.tasks
  local a = storage.autonomy or {}
  local body = companion.get()
  local crafting = body and body.valid and (body.crafting_queue_size or 0) > 0
  local ok, held = pcall(companion.human_control)
  local queued = 0
  for _, task in ipairs(t.queue) do if pilot_work(task) then queued = queued + 1 end end
  return {
    tick = game.tick, last_plan_ended = t.last_plan_ended,
    active_plan_id = pilot_work(t.active) and t.active.type == "plan" and t.active.id or nil,
    queue_depth = queued,
    fifo_empty = not pilot_work(t.active) and queued == 0 and not crafting,
    problem_count = a.problem_count or 0, last_problem_tick = a.last_problem_tick,
    human_hold = ok and held == true,
  }
end

return M
