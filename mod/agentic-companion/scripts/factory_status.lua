-- factory_status: one compact read of the whole factory for both roles.
-- event_state: the cheap probe the bridge's next_event wait polls.
-- Both never query or walk entities: lines and problems come from
-- autonomy.lua's samples (causes worked out by the sampler), stock and power
-- from the registry's aggregates (kept by build events and its maintenance
-- cursor; stock_power_tick is when its last full pass ended) with one
-- statistics read per power row shown, patches from map_summary's per-chunk
-- cache, research from a set of available technologies kept by the research
-- events (live current/progress/queue). The only scan is rebuilding that set
-- once after a load, an upgrade or a reversed research.
-- registry_ready, stock_power_ready and patches_ready are false while an
-- upgraded save's bootstrap or first pass still runs. The default read
-- stays under about 6 KB: one RCON chunk pair, not a multi-part answer.
-- logistics (robot networks) is opt-in through sections.
local companion = require("scripts.companion")
local autonomy = require("scripts.autonomy")
local map_summary = require("scripts.map_summary")
local research = require("scripts.research")
local registry = require("scripts.registry")
local tasks = require("scripts.tasks")
local logistics = require("scripts.logistics")

local M = {}

local SECTIONS = { lines = true, problems = true, power = true, stock = true, research = true,
  body = true, patches = true, logistics = true }
-- Sections only named in `sections` add.
local OPT_IN = { logistics = true }
-- One power row: the network with the most capacity (a 0.22 row carries its
-- sources, accumulators and cover; omitted_power counts the other networks
-- and map_summary include power lists them all).
local MAX_LINES, MAX_PROBLEMS, MAX_POWER, MAX_STOCK_ITEMS = 10, 6, 1, 6
local MAX_PATCHES, MAX_AVAILABLE, MAX_INVENTORY = 4, 6, 8
-- Lines that need attention survive the cap first: a starved line with a
-- high id is never hidden behind running ones.
local LINE_RANK = { no_power = 1, no_heat = 2, no_fuel = 3, starved = 4, output_full = 5, disabled = 6, idle = 7,
  running = 8 }
-- Dead machines first, then blocked output.
local PROBLEM_RANK = { no_power = 1, not_plugged_in_electric_network = 1, no_fuel = 1,
  no_minable_resources = 2, low_temperature = 2, pipeline_overextended = 2, no_modules_to_transmit = 2,
  full_output = 3, waiting_for_space_in_destination = 3 }

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
    for name in pairs(SECTIONS) do want[name] = not OPT_IN[name] or nil end
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

-- Research a lab can start now: enabled, not researched, every
-- prerequisite researched, and no trigger (triggers are not lab research).
local function researchable(technology)
  if technology.researched or not technology.enabled then return false end
  for _, prerequisite in pairs(technology.prerequisites) do
    if not prerequisite.researched then return false end
  end
  return research.research_trigger(technology) == nil
end

-- The available set ({[name] = true}) of the force, from every technology:
-- a few reads each, once after a load, an upgrade or a reversed research.
local function rebuild_available(force)
  local available = {}
  for name, technology in pairs(force.technologies) do
    if researchable(technology) then available[name] = true end
  end
  storage.research_cache = { force = force.name, available = available }
  return storage.research_cache
end

-- Current research, progress and queue are cheap live reads; available is
-- the kept set, sorted.
local function research_section(c)
  local force = c.force
  local cache = storage.research_cache
  if not (cache and cache.force == force.name) then cache = rebuild_available(force) end
  local queue = {}
  for _, technology in ipairs(force.research_queue or {}) do queue[#queue + 1] = technology.name end
  local available = {}
  for name in pairs(cache.available) do available[#available + 1] = name end
  table.sort(available)
  return { current = force.current_research and force.current_research.name or nil,
    progress = force.research_progress or 0, queue = queue, available = available,
    omitted_available = cap(available, MAX_AVAILABLE) }
end

-- A finished research leaves the available set and adds those of its
-- successors it made researchable (a few reads); a reversed research or an
-- effects reset drops the set for a rebuild; starting, queueing, moving or
-- cancelling research changes nothing in it. A finished research of the
-- body's force is also kept for next_event's research_finished.
function M.on_research_changed(event)
  local events = defines and defines.events or {}
  local name = event and event.name
  if name == nil or name == events.on_research_reversed or name == events.on_technology_effects_reset then
    storage.research_cache = nil
  end
  if name == nil or name ~= events.on_research_finished then return end
  local ok, technology_name, force = pcall(function() return event.research.name, event.research.force.name end)
  local c = companion.get()
  local own = c and c.valid and c.force.name or force
  if not (ok and force == own) then return end
  storage.last_research_finished = { technology = technology_name, tick = event.tick }
  local cache = storage.research_cache
  if not (cache and cache.force == force) then return end
  local updated = pcall(function()
    -- A levelled (infinite) technology stays researchable after a level.
    if not researchable(event.research) then cache.available[technology_name] = nil end
    for successor_name, successor in pairs(event.research.successors) do
      if researchable(successor) then cache.available[successor_name] = true end
    end
  end)
  if not updated then storage.research_cache = nil end
end
M.RESEARCH_EVENTS = { "on_research_started", "on_research_finished", "on_research_cancelled", "on_research_reversed",
  "on_research_queued", "on_research_moved", "on_technology_effects_reset" }

function M.factory_status(params)
  local since, want = parse(params or {})
  local c = companion.require_companion()
  local result = { tick = game.tick, since_tick = since, registry_ready = registry.ready() }
  if want.lines then
    result.lines = autonomy.lines(since)
    table.sort(result.lines, function(x, y)
      local rx, ry = LINE_RANK[x.state] or 7, LINE_RANK[y.state] or 7
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
    local maintenance = registry.maintenance()
    result.stock_power_tick, result.stock_power_ready = maintenance.pass_tick, maintenance.ready
    if want.power then
      local rows, omitted = map_summary.build_power(c.surface, MAX_POWER)
      result.power, result.omitted_power = rows, omitted > 0 and omitted or nil
    end
    if want.stock then
      local rows, omitted = registry.stock_rows(c.surface.index, MAX_STOCK_ITEMS)
      result.stock, result.omitted_stock = rows, omitted > 0 and omitted or nil
    end
  end
  if want.research then result.research = research_section(c) end
  if want.body then result.body = body_section(c) end
  if want.patches then result.patches, result.omitted_patches, result.patches_ready = patches_section(c) end
  if want.logistics then result.logistics = logistics.section(c) end
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
  local ok, held = pcall(companion.human_control)
  local queued = 0
  for _, task in ipairs(t.queue) do if pilot_work(task) then queued = queued + 1 end end
  return {
    tick = game.tick, last_plan_ended = t.last_plan_ended,
    active_plan_id = pilot_work(t.active) and t.active.type == "plan" and t.active.id or nil,
    queue_depth = queued,
    -- The pilot's cue to queue work: no plan, whatever the body still
    -- hand-crafts in the background.
    fifo_empty = not pilot_work(t.active) and queued == 0,
    problem_count = a.problem_count or 0, last_problem_tick = a.last_problem_tick,
    human_hold = ok and held == true,
    -- {technology, tick} of the last research the force finished.
    last_research_finished = storage.last_research_finished,
    last_cancel_all_tick = t.last_cancel_all_tick,
  }
end

return M
