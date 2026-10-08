-- factory_status: one compact read of the whole factory for both roles.
-- event_state: the cheap probe the bridge's next_event wait polls.
-- Both never query or walk entities: lines and problems come from
-- autonomy.lua's samples (causes worked out by the sampler), stock and power
-- from the registry's aggregates (kept by build events and its maintenance
-- cursor; stock_power_tick is when its last full pass ended) with one
-- statistics read per power row shown, patches from map_summary's per-chunk
-- cache, research from a set of available technologies kept by the research
-- events (live current/progress/queue) and labs from the registry's lab
-- aggregate and the line sampler's lab lines. The only scan is rebuilding
-- that set once after a load, an upgrade or a reversed research.
-- registry_ready, stock_power_ready and patches_ready are false while an
-- upgraded save's bootstrap or first pass still runs. The default read
-- stays under about 6 KB: one RCON chunk pair, not a multi-part answer (feed
-- facts on up to three stalled rows add up to about 1.6 KB). logistics
-- (robot networks) is opt-in through sections. platforms lists the force's
-- space platforms, one attribute-read line each (platforms.lua).
--
-- Surfaces (multi-surface rule 6): `surface` names the surface the detailed
-- sections (lines, problems, power, stock, patches, logistics) describe, the
-- body's anchor surface unless the read names one; stock is per surface
-- (items on another planet are not in the body's reach). `elsewhere` sums up
-- every other factory surface in one row each (its lines, problems, the
-- three worst problems and its lowest power satisfaction), all from the same
-- aggregates; the header lists the unlocked space locations. Labs with no
-- research active are a problem row (no_research_in_progress, cause
-- research_idle): research stands still. `trial` (benchmark.lua) is the
-- benchmark clock and live score, present only while a benchmark exists.
local companion = require("scripts.companion")
local surfaces = require("scripts.surfaces")
local items = require("scripts.items")
local autonomy = require("scripts.autonomy")
local map_summary = require("scripts.map_summary")
local research = require("scripts.research")
local registry = require("scripts.registry")
local tasks = require("scripts.tasks")
local logistics = require("scripts.logistics")
local platforms = require("scripts.platforms")
local jobs = require("scripts.jobs")
local benchmark = require("scripts.benchmark")

local M = {}

local SECTIONS = { lines = true, problems = true, power = true, stock = true, research = true,
  body = true, patches = true, logistics = true, platforms = true, elsewhere = true }
-- Sections only named in `sections` add.
local OPT_IN = { logistics = true }
-- One power row: the network with the most capacity (a 0.22 row carries its
-- sources, accumulators and cover; omitted_power counts the other networks
-- and map_summary include power lists them all).
local MAX_LINES, MAX_PROBLEMS, MAX_POWER, MAX_STOCK_ITEMS = 10, 6, 1, 6
local MAX_PATCHES, MAX_AVAILABLE, MAX_INVENTORY = 4, 6, 8
-- Other factory surfaces summed up, and the worst problems each names.
local MAX_ELSEWHERE, MAX_ELSEWHERE_PROBLEMS = 8, 3
-- Lines that need attention survive the cap first: a starved line with a
-- high id is never hidden behind running ones, nor a degraded running line
-- behind healthy ones.
local LINE_RANK = { no_power = 1, frozen = 2, no_heat = 3, no_fuel = 4, starved = 5, depleted = 6, output_full = 7,
  disabled = 8, idle = 9, running = 10 }
local function line_rank(row) return (LINE_RANK[row.state] or 9) - (row.degraded and 0.5 or 0) end
-- Dead machines first, then blocked output.
local PROBLEM_RANK = { no_power = 1, not_plugged_in_electric_network = 1, no_fuel = 1, frozen = 1,
  no_minable_resources = 2, low_temperature = 2, pipeline_overextended = 2, no_modules_to_transmit = 2,
  no_research_in_progress = 2, full_output = 3, waiting_for_space_in_destination = 3 }

local function cap(rows, limit)
  local omitted = math.max(0, #rows - limit)
  while #rows > limit do table.remove(rows) end
  return omitted > 0 and omitted or nil
end

-- Feed facts (autonomy.lua read_feed) ride on at most MAX_FEEDS rows a read,
-- lines first in their order; a problem row whose machine's feed its line row
-- already shows says feed_in_line instead. omitted_feeds counts the rest.
local MAX_FEEDS = 3
local function cap_feeds(result)
  local shown, omitted, at = 0, 0, {}
  local function key(position) return position and (position.x .. "," .. position.y) end
  local function keep(holder)
    if shown < MAX_FEEDS then shown = shown + 1; return true end
    holder.feed, omitted = nil, omitted + 1
  end
  for _, row in ipairs(result.lines or {}) do
    if row.feed and keep(row) then at[key(row.cause_position)] = true end
    if row.degraded and row.degraded.feed and keep(row.degraded) then at[key(row.degraded.cause_position)] = true end
  end
  for _, row in ipairs(result.problems or {}) do
    if row.feed and at[key(row.position)] then row.feed, row.feed_in_line = nil, true
    elseif row.feed then keep(row) end
  end
  if omitted > 0 then result.omitted_feeds = omitted end
end

local function xy(position) return { x = position.x, y = position.y } end

local function parse(params)
  if params.surface ~= nil and type(params.surface) ~= "string" and type(params.surface) ~= "table" then
    error("factory_status surface must be a planet name, \"platform:<index>\" or {platform = name or index}", 0)
  end
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

-- The body: where it is (its state, absent while it stands on a surface;
-- its surface when the read describes another; its health, absent while
-- full), what it carries (by item key, spoilable items with when they
-- spoil) and its work. Aboard or in transit the character's inventory still
-- travels with it.
local function body_section(body, read_surface)
  local c = body.character
  local out = { state = body.state ~= "on_surface" and body.state or nil,
    surface = body.surface_ref ~= read_surface and body.surface_ref or nil,
    position = body.position and xy(body.position) or nil,
    queue_depth = tasks.queue_length(), active_step = tasks.active_summary() }
  local ok, held = pcall(companion.human_control)
  out.human_control = ok and held == true
  -- A bounded queue-time snapshot, not a fresh stock/reach or success claim.
  out.upkeep_selection = storage.chores and storage.chores.last_selection or nil
  if not (c and c.valid) then return out end
  local ok_ratio, ratio = pcall(function() return c.get_health_ratio() end)
  if ok_ratio and type(ratio) == "number" and ratio < 1 then out.health_ratio = math.floor(ratio * 1000 + 0.5) / 1000 end
  local inventory = c.get_main_inventory()
  local counts = {}
  for key, count in pairs(items.sum_contents(inventory)) do counts[#counts + 1] = { name = key, count = count } end
  table.sort(counts, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  out.inventory_omitted = cap(counts, MAX_INVENTORY)
  local summary, names = {}, {}
  for _, row in ipairs(counts) do summary[row.name], names[#names + 1] = row.count, row.name end
  out.inventory_summary = summary
  local spoils = items.spoil(inventory, names)
  if next(spoils) then out.inventory_spoils = spoils end
  out.crafting_queue_size = c.crafting_queue_size or 0
  return out
end

-- Stock rows of a surface, spoilable ones with when their largest holder's
-- stacks spoil (that holder only): one pass over each such holder's slots
-- for all the rows it is the largest holder of.
local function stock_section(index)
  local rows, omitted = registry.stock_rows(index, MAX_STOCK_ITEMS)
  local holders, order = {}, {}
  for _, row in ipairs(rows) do
    local entry = row.holders[1] and items.spoilable(row.item) and registry.largest_holder(index, row.item)
    if entry then
      local group = holders[entry.unit]
      if not group then
        group = { entry = entry, names = {}, rows = {} }
        holders[entry.unit], order[#order + 1] = group, entry.unit
      end
      group.names[#group.names + 1], group.rows[#group.rows + 1] = row.item, row
    end
  end
  local reads = 0
  for _, unit in ipairs(order) do
    local group = holders[unit]
    local spoils, cost = items.spoil(registry.holder_inventory(group.entry.entity), group.names)
    reads = reads + cost
    for _, row in ipairs(group.rows) do
      local spoil = spoils[row.item]
      if spoil then row.spoils_in_s, row.spoil_percent_max = spoil.spoils_in_s, spoil.spoil_percent_max end
    end
  end
  jobs.charge(reads)
  return rows, omitted
end

local function patches_section(index, from)
  local cached, ready = map_summary.patches(index)
  local rows = {}
  for _, patch in ipairs(cached) do
    -- bbox: the patch's outline, so a site beside it can be chosen off the ore.
    local box = patch.bbox
    -- minutes_left, remaining_fraction (mined patches) or yield_percent (an
    -- infinite resource): map_summary's patch cache depletion.
    local row = { name = patch.name, amount = patch.amount, tiles = patch.tiles, position = patch.centroid,
      bbox = box and { left_top = { x = box.left_top.x, y = box.left_top.y },
        right_bottom = { x = box.right_bottom.x, y = box.right_bottom.y } } or nil,
      minutes_left = patch.minutes_left, remaining_fraction = patch.remaining_fraction, yield_percent = patch.yield_percent }
    if from then
      local dx, dy = patch.centroid.x - from.x, patch.centroid.y - from.y
      row.distance = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
    end
    rows[#rows + 1] = row
  end
  -- Nearest the body first on its surface; elsewhere the largest first (the
  -- cache's order).
  if from then
    table.sort(rows, function(x, y)
      if x.distance ~= y.distance then return x.distance < y.distance end
      return x.name < y.name
    end)
  end
  return rows, cap(rows, MAX_PATCHES), ready
end

local function problem_before(x, y)
  local rx, ry = PROBLEM_RANK[x.status] or 4, PROBLEM_RANK[y.status] or 4
  if rx ~= ry then return rx < ry end
  if x.position.y ~= y.position.y then return x.position.y < y.position.y end
  return x.position.x < y.position.x
end

-- One row per other factory surface (at most MAX_ELSEWHERE, by index): its
-- current line counts, cursor-filtered problems and lowest power satisfaction,
-- from one pass over the line sampler's lines and one over the registry's
-- networks (a statistics read for at most one network a surface, the
-- neediest whose consumers are short of power).
local function elsewhere_section(here_index, since_tick)
  local rows, others = {}, {}
  for _, index in ipairs(registry.surfaces()) do
    if index ~= here_index then others[#others + 1] = index end
  end
  if #others == 0 then return rows, 0 end
  local overview, networks = autonomy.by_surface(since_tick), registry.networks_by_surface()
  local reads = 0
  for _, index in ipairs(others) do
    if #rows >= MAX_ELSEWHERE then break end
    local surface = surfaces.by_index(index)
    if surface then
      local summary = overview[index] or { line_count = 0, running_line_count = 0, problems = {} }
      local problems = summary.problems
      table.sort(problems, problem_before)
      local top = {}
      for i = 1, math.min(MAX_ELSEWHERE_PROBLEMS, #problems) do
        local p = problems[i]
        top[i] = { status = p.status, name = p.name, position = p.position, count = p.count }
      end
      local power, cost = map_summary.power_min_satisfaction(networks[index] or {})
      reads = reads + cost
      rows[#rows + 1] = { surface = surfaces.ref(surface), lines_total = summary.line_count,
        lines_running = summary.running_line_count, problems = #problems, top_problems = top,
        power_min_satisfaction = power }
    end
  end
  jobs.charge(reads)
  return rows, #others - #rows
end

-- The space locations the force has unlocked (a handful of reads); nil
-- while that is at most the home planet.
local function unlocked_locations(force)
  local names = {}
  for name in pairs(prototypes.space_location or {}) do
    if platforms.location_unlocked(force, name) then names[#names + 1] = name end
  end
  if #names < 2 then return nil end
  table.sort(names)
  return names
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

local function round(value, places)
  local scale = 10 ^ places
  return math.floor(value * scale + 0.5) / scale
end

-- Labs on every surface (absent until the force has one): count, working
-- (progressed in the last 10 s) and speed (summed research speed, force
-- bonus, modules and beacons included).
-- With speed, what the current research needs to keep them all busy: packs
-- a minute (pack_rate x 60 / unit_time_s x amount: a biolab drains half a
-- pack a unit, productivity does not change consumption) and eta_seconds
-- (remaining units at full speed, each lab's productivity counted). A few
-- reads of the current technology.
local function labs_section(force, out)
  local labs = registry.labs()
  if labs.count > 0 then
    out.labs = { count = labs.count, working = autonomy.labs_working(), speed = round(labs.speed, 3) }
  end
  local current = force.current_research
  if not current then return end
  local unit_time_s = research.unit_time_s(current)
  out.unit_time_s = unit_time_s
  -- Float sums can keep a tiny positive leftover after the last lab goes.
  if not (unit_time_s and unit_time_s > 0 and labs.count > 0 and labs.speed > 0) then return end
  local per_minute = labs.pack_rate * 60 / unit_time_s
  local needed = {}
  local ok, ingredients = pcall(function() return current.research_unit_ingredients end)
  for _, ingredient in ipairs(ok and ingredients or {}) do
    needed[ingredient.name] = round(per_minute * (ingredient.amount or 1), 2)
  end
  if next(needed) then out.packs_per_minute_needed = needed end
  local count_ok, count = pcall(function() return current.research_unit_count end)
  if count_ok and type(count) == "number" and labs.progress_rate > 0 then
    local remaining = count * (1 - (force.research_progress or 0))
    -- The sums drift by float rounding as labs come and go; a whole second
    -- must not round up to the next.
    out.eta_seconds = math.ceil(remaining * unit_time_s / labs.progress_rate - 1e-6)
  end
end

-- Current research, progress and queue are cheap live reads; available is
-- the kept set, sorted.
local function research_section(force)
  local cache = storage.research_cache
  if not (cache and cache.force == force.name) then cache = rebuild_available(force) end
  local queue = {}
  for _, technology in ipairs(force.research_queue or {}) do queue[#queue + 1] = technology.name end
  local available = {}
  for name in pairs(cache.available) do available[#available + 1] = name end
  table.sort(available)
  local out = { current = force.current_research and force.current_research.name or nil,
    progress = force.research_progress or 0, queue = queue, available = available,
    omitted_available = cap(available, MAX_AVAILABLE) }
  labs_section(force, out)
  return out
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
  local anchor = companion.anchor()
  local own = anchor and anchor.force and anchor.force.name or force
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

-- measure (the pilot's bridge only, never a tool): a build package's verify
-- metrics, 1-3, measured now on the read's surface, as `measured` rows in
-- their order. Measurement only: nothing is fixed, chosen or queued.
--   {item, per_min_at_least}  per_min: that item or fluid made on the
--                             surface over the last minute (the force's
--                             production statistics)
--   {line_at = {x, y}, state} the factory line of the own machine whose box
--                             holds that position: line_id, product, state,
--                             cause, rate_per_min, machines, working
-- Each row adds met (the measured value against the stated one); a metric
-- that cannot be measured has error (UNKNOWN_ITEM, UNCHARTED or NO_LINE)
-- and met false.
local MAX_MEASURE = 3
local function measure_section(target, metrics)
  if type(metrics) ~= "table" or #metrics == 0 or #metrics > MAX_MEASURE then
    error("measure lists 1-" .. MAX_MEASURE .. " metrics", 0)
  end
  local rows = {}
  for i, metric in ipairs(metrics) do
    local p = type(metric) == "table" and metric.line_at
    if type(metric) == "table" and type(metric.item) == "string" and type(metric.per_min_at_least) == "number" then
      local getter = prototypes.item[metric.item] and "get_item_production_statistics"
        or prototypes.fluid[metric.item] and "get_fluid_production_statistics"
      local ok, rate = false, nil
      if getter then
        ok, rate = pcall(function()
          return target.force[getter](target.surface).get_flow_count({ name = metric.item, category = "input",
            precision_index = defines.flow_precision_index.one_minute, count = false })
        end)
      end
      if ok and type(rate) == "number" then
        local per_min = math.floor(rate * 10 + 0.5) / 10
        rows[i] = { per_min = per_min, met = per_min >= metric.per_min_at_least }
      else
        rows[i] = { error = "UNKNOWN_ITEM", met = false }
      end
    elseif type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(metric.state) == "string" then
      if not surfaces.charted(target.force, target.surface, math.floor(p.x / 32), math.floor(p.y / 32)) then
        rows[i] = { error = "UNCHARTED", met = false }
      else
        local ok, found = pcall(target.surface.find_entities_filtered, { position = { x = p.x, y = p.y }, force = target.force })
        local line
        for _, entity in ipairs(ok and found or {}) do
          line = line or autonomy.line_at(target.surface.index, entity.position)
        end
        if line then line.met = line.state == metric.state end
        rows[i] = line or { error = "NO_LINE", met = false }
      end
    else
      error("measure " .. i .. " is neither {item, per_min_at_least} nor {line_at = {x, y}, state}", 0)
    end
  end
  return rows
end

function M.factory_status(params)
  local since, want = parse(params or {})
  local target = surfaces.target(params and params.surface)
  local index, body = target.surface.index, target.body
  local result = { tick = game.tick, since_tick = since, registry_ready = registry.ready(), surface = target.ref,
    unlocked_locations = unlocked_locations(target.force), trial = benchmark.trial() }
  if params and params.measure ~= nil then result.measured = measure_section(target, params.measure) end
  if want.lines then
    result.lines = autonomy.lines(since, index)
    table.sort(result.lines, function(x, y)
      local rx, ry = line_rank(x), line_rank(y)
      if rx ~= ry then return rx < ry end
      return x.id < y.id
    end)
    result.omitted_lines = cap(result.lines, MAX_LINES)
    result.lines_error = storage.autonomy and storage.autonomy.refresh_error
  end
  if want.problems then
    local rows = autonomy.problems(since, index)
    table.sort(rows, problem_before)
    result.problems, result.omitted_problems = rows, cap(rows, MAX_PROBLEMS)
  end
  cap_feeds(result)
  if want.power or want.stock then
    local maintenance = registry.maintenance()
    result.stock_power_tick, result.stock_power_ready = maintenance.pass_tick, maintenance.ready
    if want.power then
      local rows, omitted = map_summary.build_power(target.surface, MAX_POWER)
      result.power, result.omitted_power = rows, omitted > 0 and omitted or nil
    end
    if want.stock then
      local rows, omitted = stock_section(index)
      result.stock, result.omitted_stock = rows, omitted > 0 and omitted or nil
    end
  end
  if want.research then result.research = research_section(target.force) end
  if want.body then result.body = body_section(body, target.ref) end
  if want.patches then
    result.patches, result.omitted_patches, result.patches_ready =
      patches_section(index, target.here and body.position or nil)
  end
  if want.logistics then
    result.logistics = logistics.section({ surface = target.surface, force = target.force,
      position = target.here and body.position or { x = 0, y = 0 } })
  end
  if want.platforms then
    local rows, omitted, work = platforms.compact(target.force)
    jobs.charge(work)
    -- Absent until the force has a platform.
    if #rows > 0 then result.platforms, result.omitted_platforms = rows, omitted > 0 and omitted or nil end
  end
  if want.elsewhere then
    local rows, omitted = elsewhere_section(index, since)
    -- Absent while the factory stands on one surface.
    if #rows > 0 then result.elsewhere, result.omitted_elsewhere = rows, omitted > 0 and omitted or nil end
  end
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
  local space_tick, space_events = platforms.event_state()
  -- Whether the force's labs stand idle: it has labs (the registry's cached
  -- count; trigger technologies finish before any lab exists) and no
  -- research running. nil while there is no body to name the force.
  local research_ok, idle = pcall(function()
    local anchor = companion.anchor()
    if anchor and anchor.force then return anchor.force.current_research == nil and registry.labs().count > 0 end
  end)
  local research_idle = nil
  if research_ok and type(idle) == "boolean" then research_idle = idle end
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
    research_idle = research_idle,
    last_cancel_all_tick = t.last_cancel_all_tick,
    -- Upkeep stays off after an emergency stop until a plan finishes.
    upkeep_off_since_tick = not t.last_finished_tick and t.last_cancel_all_tick or nil,
    -- The space event ring (platforms.lua): the newest entry's tick and the
    -- last few (rocket_launched, platform_state_changed, cargo_delivered,
    -- rocket_ready).
    last_space_event_tick = space_tick, space_events = space_events,
  }
end

return M
