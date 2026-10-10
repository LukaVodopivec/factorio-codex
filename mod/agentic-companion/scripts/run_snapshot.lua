-- run_snapshot: what the run recorder samples, as a job (jobs.lua): one
-- surface's item or fluid statistics a step, so the work does not grow in
-- one tick with the number of planets and platforms, then the context in
-- phases (PHASES) that each run whole within a tick's work, so the factory
-- and the research tree growing spread the snapshot over more ticks. The
-- result is always encoded by the jobs encoder over ticks and read through
-- get_job (defer_encode). Statistics are summed over every factory
-- surface in statistics.items / statistics.fluids, so the recorder's deltas
-- stay stable when the body travels; with more than one surface,
-- statistics.by_surface[ref] = {items, fluids} keeps each one's own. Works
-- in every body state but absent: the compact observation only while the
-- body stands on a surface. Each snapshot also carries the run attestation
-- (facts the recorder checks), the body's time by state (tasks.body_time),
-- the human hold episodes (tasks.holds), the count of caught handler faults
-- (errors.lua) and the run milestones (storage.milestones, state.lua).
local autonomy = require("scripts.autonomy")
local companion = require("scripts.companion")
local factory_activity = require("scripts.factory_activity")
local map_summary = require("scripts.map_summary")
local registry = require("scripts.registry")
local research = require("scripts.research")
local spatial = require("scripts.spatial")
local surfaces = require("scripts.surfaces")
local tasks = require("scripts.tasks")

local M = {}

-- Force modifiers a researched technology raises, by its effect type.
local FORCE_BONUSES = {
  manual_crafting_speed_modifier = "character-crafting-speed",
  manual_mining_speed_modifier = "character-mining-speed",
  character_running_speed_modifier = "character-running-speed",
  character_build_distance_bonus = "character-build-distance",
  character_item_drop_distance_bonus = "character-item-drop-distance",
  character_reach_distance_bonus = "character-reach-distance",
  character_resource_reach_distance_bonus = "character-resource-reach-distance",
  character_item_pickup_distance_bonus = "character-item-pickup-distance",
  character_loot_pickup_distance_bonus = "character-loot-pickup-distance",
  character_inventory_slots_bonus = "character-inventory-slots-bonus",
  character_health_bonus = "character-health-bonus",
  laboratory_speed_modifier = "laboratory-speed",
  mining_drill_productivity_bonus = "mining-drill-productivity-bonus",
}
-- The character's own modifiers: no technology raises them.
local CHARACTER_BONUSES = {
  "character_crafting_speed_modifier", "character_mining_speed_modifier", "character_running_speed_modifier",
  "character_build_distance_bonus", "character_item_drop_distance_bonus", "character_reach_distance_bonus",
  "character_resource_reach_distance_bonus", "character_item_pickup_distance_bonus",
  "character_loot_pickup_distance_bonus", "character_inventory_slots_bonus", "character_health_bonus",
}
local EFFECT_FIELDS = {}
for field, effect in pairs(FORCE_BONUSES) do EFFECT_FIELDS[effect] = field end

-- The technologies with one of those effects: {name, effects = {{field,
-- modifier}}}, read once per load (prototypes never change at runtime).
local bonus_techs
local function bonus_technologies()
  if bonus_techs then return bonus_techs end
  local rows = {}
  for name, technology in pairs(prototypes and prototypes.technology or {}) do
    local ok, effects = pcall(function() return technology.effects end)
    local found = {}
    for _, effect in ipairs(ok and effects or {}) do
      local field = EFFECT_FIELDS[effect.type]
      if field and type(effect.modifier) == "number" then found[#found + 1] = { field = field, modifier = effect.modifier } end
    end
    if #found > 0 then rows[#rows + 1] = { name = name, effects = found } end
  end
  bonus_techs = rows
  return rows
end

-- Researched levels of a technology: a leveled (or infinite) one counts
-- each finished level from its prototype's first.
local function levels_done(technology)
  local p = technology.prototype
  local first, max = p.level or 1, p.max_level or p.level or 1
  if technology.researched then return max - first + 1 end
  return math.max(0, (technology.level or first) - first)
end

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

-- on_research_finished: the first tick the body's force finished each
-- technology (one entry per technology; a levelled one keeps its first).
function M.on_research_finished(event)
  pcall(function()
    local name, force = event.research.name, event.research.force.name
    local anchor = companion.anchor()
    if anchor and anchor.force and anchor.force.name ~= force then return end
    storage.milestones = storage.milestones or {}
    storage.milestones.research = storage.milestones.research or {}
    local research_ticks = storage.milestones.research
    if research_ticks[name] == nil then research_ticks[name] = event.tick end
  end)
end

-- A copy of the milestones: {rocket_ready_tick?, rocket_launch_ordered_tick?,
-- rocket_launched_tick?, platform_created_tick?, boarded_tick?, arrived_tick?,
-- landed_tick?, research = {[technology] = tick}}.
local function milestones()
  local kept = storage.milestones or {}
  local research_ticks = {}
  for name, tick in pairs(kept.research or {}) do research_ticks[name] = tick end
  return { rocket_ready_tick = kept.rocket_ready_tick, rocket_launch_ordered_tick = kept.rocket_launch_ordered_tick,
    rocket_launched_tick = kept.rocket_launched_tick, platform_created_tick = kept.platform_created_tick,
    boarded_tick = kept.boarded_tick, arrived_tick = kept.arrived_tick, landed_tick = kept.landed_tick,
    research = research_ticks }
end

local function controller_name(value)
  for name, id in pairs(defines and defines.controllers or {}) do if id == value then return name end end
  return value ~= nil and tostring(value) or nil
end

-- Facts the recorder checks for an unassisted run: game speed, the Codex
-- player's cheat mode and controllers, the active mods, and every checked
-- force or character modifier that differs from what research grants
-- ({scope, name, value, from_research}).
local function attestation(body)
  local player, force = body.player, body.force
  local from_research = {}
  local technologies = force and read(function() return force.technologies end)
  for _, row in ipairs(technologies and bonus_technologies() or {}) do
    local technology = technologies[row.name]
    local levels = technology and read(function() return levels_done(technology) end) or 0
    for _, effect in ipairs(row.effects) do
      from_research[effect.field] = (from_research[effect.field] or 0) + effect.modifier * levels
    end
  end
  local bonuses = {}
  local function check(scope, owner, field, expected)
    local value = owner and read(function() return owner[field] end)
    if type(value) == "number" and math.abs(value - expected) > 1e-9 then
      bonuses[#bonuses + 1] = { scope = scope, name = field, value = value, from_research = expected }
    end
  end
  for field in pairs(FORCE_BONUSES) do check("force", force, field, from_research[field] or 0) end
  local character = body.character
  for _, field in ipairs(CHARACTER_BONUSES) do check("character", character, field, 0) end
  table.sort(bonuses, function(a, b) return a.scope == b.scope and a.name < b.name or a.scope < b.scope end)
  local mods = {}
  for name, version in pairs(script and script.active_mods or {}) do mods[name] = version end
  return {
    game_speed = game.speed,
    cheat_mode = player and read(function() return player.cheat_mode end),
    controller = player and controller_name(read(function() return player.controller_type end)),
    physical_controller = player and controller_name(read(function() return player.physical_controller_type end)),
    mods = mods,
    bonuses = bonuses,
  }
end

-- Rocks and wrecks (simple-entity) also drop manufactured items, so they are
-- not raw-resource sources; rock stone and coal are already resource products.
local NATURAL_SOURCE_TYPES = {
  resource = true, tree = true, fish = true, plant = true,
}
local PRIMARY_UTILITY_FLUIDS = { water = true }

local function sorted_counts(counts)
  local rows = {}
  for name, count in pairs(counts or {}) do
    count = tonumber(count) or 0
    if count ~= 0 then rows[#rows + 1] = { name = name, count = count } end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

-- Prototypes never change at runtime: the rows are read once per load (the
-- same on every peer) and reused by every snapshot.
local raw_rows
local function raw_resource_products()
  if raw_rows then return raw_rows end
  local found = {}
  for _, prototype in pairs(prototypes and prototypes.entity or {}) do
    if NATURAL_SOURCE_TYPES[prototype.type] then
      local ok, mineable = pcall(function() return prototype.mineable_properties end)
      for _, product in ipairs(ok and mineable and mineable.products or {}) do
        local name = product.name
        local kind = product.type or "item"
        if type(name) == "string" and not (kind == "fluid" and PRIMARY_UTILITY_FLUIDS[name]) then
          found[kind .. "\0" .. name] = { type = kind, name = name }
        end
      end
    end
  end
  local rows = {}
  for _, row in pairs(found) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.type == b.type and a.name < b.name or a.type < b.type end)
  raw_rows = rows
  return rows
end

local KINDS = { { key = "items", getter = "get_item_production_statistics" },
  { key = "fluids", getter = "get_fluid_production_statistics" } }

local function add_counts(sum, counts)
  for name, count in pairs(counts or {}) do sum[name] = (sum[name] or 0) + (tonumber(count) or 0) end
end

local function size(map)
  local n = 0
  for _ in pairs(map or {}) do n = n + 1 end
  return n
end

-- The factory surfaces and the body's, by index.
local function snapshot_start()
  local body = companion.require_present()
  local list, seen = {}, {}
  for _, index in ipairs(registry.surfaces()) do list[#list + 1], seen[index] = index, true end
  local ok, index = pcall(function() return body.surface.index end)
  if ok and index and not seen[index] then list[#list + 1] = index end
  local sums = {}
  for _, kind in ipairs(KINDS) do sums[kind.key] = { input = {}, output = {} } end
  return { surfaces = list, cursor = 1, kind = 1, sums = sums, unavailable = {}, read = {} }
end

-- One surface's counters of one kind: summed, and kept for by_surface.
local function read_one(S, force, budget)
  local index, kind = S.surfaces[S.cursor], KINDS[S.kind]
  local surface = surfaces.by_index(index)
  if surface then
    local row = S.read[S.cursor] or { ref = surfaces.ref(surface) }
    S.read[S.cursor] = row
    local ok, value = pcall(function() return force[kind.getter](surface) end)
    local input, output = ok and value and value.input_counts, ok and value and value.output_counts
    if input and output then
      add_counts(S.sums[kind.key].input, input)
      add_counts(S.sums[kind.key].output, output)
      row[kind.key] = { input = input, output = output }
    else
      S.unavailable[kind.key] = true
      row[kind.key] = { unavailable = true }
    end
    local counted = size(input) + size(output)
    S.entries = (S.entries or 0) + counted
    budget.left = budget.left - 4 - math.ceil(counted / 8)
  else
    budget.left = budget.left - 1
  end
  if S.kind < #KINDS then S.kind = S.kind + 1 else S.cursor, S.kind = S.cursor + 1, 1 end
end

local function counters(raw)
  if raw.unavailable then return { produced = {}, consumed = {}, unavailable = true } end
  return { produced = sorted_counts(raw.input), consumed = sorted_counts(raw.output) }
end

-- The character's state: an observation's (spatial.body_state, without the
-- observation's entity scan) on a surface, else what the body carries.
local function character(body)
  if companion.get() then return spatial.body_state({ character = body.character, body = body }) end
  local ok, state = pcall(spatial.character_state, body.character)
  return ok and state or nil
end

-- The record, from what the phases kept, with the summed counters sorted.
local function assemble(S)
  local summed = {}
  for _, kind in ipairs(KINDS) do
    local sum = S.sums[kind.key]
    summed[kind.key] = { produced = sorted_counts(sum.input), consumed = sorted_counts(sum.output),
      unavailable = S.unavailable[kind.key] or nil }
  end
  -- One surface's own counters are the sums: by_surface only with more.
  local by_surface
  local read = {}
  for i = 1, #S.surfaces do read[#read + 1] = S.read[i] end
  if #read > 1 then
    by_surface = {}
    for _, row in ipairs(read) do
      by_surface[row.ref] = { items = counters(row.items or { unavailable = true }),
        fluids = counters(row.fluids or { unavailable = true }) }
    end
  end
  return {
    tick = S.tick,
    character = S.character,
    -- Where the body is: {state, surface_ref, platform_name?}.
    body = S.body,
    progression = S.progression,
    -- What the mod maintains (registry, line sampler, power cache): no chunk
    -- walk and no entity read per sample.
    factory = S.factory,
    -- Production lines (autonomy.lua): how many run, self-sustain or are hand-fed.
    lines = S.lines,
    -- What the body did by state since body_time.since_tick, and its pilot
    -- and package ticks by body phase with the tiles walked (tasks.body_time).
    body_time = S.body_time,
    -- Human hold episodes: {count, total_ticks, recent} (tasks.holds).
    holds = S.holds,
    -- Errors a handler raised and a dispatcher caught since the save gained
    -- the count (errors.lua).
    handler_errors = S.handler_errors,
    -- First ticks: rocket ready, launch ordered, launched, and per technology.
    milestones = S.milestones,
    attestation = S.attestation,
    statistics = {
      -- Summed over every factory surface (the recorder's keys).
      items = summed.items,
      fluids = summed.fluids,
      by_surface = by_surface,
      raw_resources = S.raw_resources,
      -- Items the Codex player crafted by hand since since_tick (cumulative).
      hand_crafted = S.hand_crafted,
      semantics = { produced = "force_surface_input_counts", consumed = "force_surface_output_counts",
        items = "summed_over_factory_surfaces" },
    },
  }
end

-- Entries of a LuaCustomTable or a list (#), 0 when unreadable.
local function length(t)
  local ok, n = pcall(function() return #t end)
  return ok and tonumber(n) or 0
end

-- Entries of a plain table: the game's table_size, else counted.
local function entries(t)
  if t == nil then return 0 end
  if table_size then return table_size(t) end
  return size(t)
end

-- After the statistics reads, each phase is one call whose work grows with
-- the factory, the research tree or the prototypes. cost(S, body) is its
-- size in work items (jobs.lua), taken before it runs from counts that are
-- cheap to read and the same on every peer: never from a per-load cache
-- (bonus_techs, raw_rows), which a client that joined later has not built,
-- so its job would take other ticks than the server's. run(S, body) keeps
-- what it read in S (assemble returns the record).
local PHASES = {
  -- Every technology (a record for each ready unresearched one) and every recipe,
  -- and the milestones (at most a first tick per technology).
  progression = {
    cost = function(_, body)
      local force = body.force
      return length(force and force.technologies) + math.ceil(length(force and force.recipes) / 8)
    end,
    run = function(S)
      S.progression = research.progression_status({})
      S.milestones = milestones()
    end,
  },
  -- Every machine the line sampler keeps, and the registry's entries counted.
  factory = {
    cost = function()
      return math.ceil(entries(storage.autonomy and storage.autonomy.machines) / 4)
        + math.ceil(entries(storage.registry and storage.registry.entries) / 64)
    end,
    run = function(S) S.factory = map_summary.registry_factory() end,
  },
  lines = {
    cost = function() return math.ceil(length(storage.autonomy and storage.autonomy.line_order) / 16) end,
    run = function(S) S.lines = autonomy.counts() end,
  },
  -- The bonus technologies (on the first snapshot after a load every
  -- technology prototype) and the force's and character's modifiers:
  -- charged as that first read on every snapshot.
  attestation = {
    cost = function() return 20 + length(prototypes and prototypes.technology) end,
    run = function(S, body) S.attestation = attestation(body) end,
  },
  -- Every entity prototype on the first snapshot after a load, later the
  -- rows: charged as that first read on every snapshot.
  resources = {
    cost = function() return math.ceil(length(prototypes and prototypes.entity) / 8) end,
    run = function(S) S.raw_resources = raw_resource_products() end,
  },
  -- The body's state and time, read together at the sample's tick.
  character = {
    cost = function() return 40 end,
    run = function(S, body)
      if S.window then tasks.mark_body_window() end
      S.tick, S.character, S.body = game.tick, character(body), companion.body_summary()
      S.body_time, S.hand_crafted = tasks.body_time(), factory_activity.hand_crafted()
      -- The hold ring is at most 16 episodes.
      S.holds = tasks.holds()
      S.handler_errors = storage.handler_errors and storage.handler_errors.count or 0
    end,
  },
  -- Sorting every counter the reads kept.
  assemble = {
    cost = function(S) return math.ceil((S.entries or 0) / 4) + 8 * #S.surfaces end,
    run = assemble,
  },
}
M.PHASES = PHASES
local PHASE_NEXT = { read = "progression", progression = "factory", factory = "lines", lines = "attestation",
  attestation = "resources", resources = "character", character = "assemble" }

-- run_snapshot {window?}: the job definition (control.lua registers it).
-- window = true (the recorder's baseline) marks the body-time window as
-- the sample is taken (tasks.mark_body_window). The phases run in
-- PHASE_NEXT order, each in a tick of its own after the reads' ticks, so
-- a snapshot spans at least one tick per phase: a phase runs once its cost
-- (plus one item, so a spent budget always ends the tick) fits what is left
-- of the tick, else it is deferred once to a fresh tick and then runs
-- whatever its cost, like the jobs encoder's calls.
M.job = {
  defer_encode = true,
  start = function(params)
    local S = snapshot_start()
    S.window = params and params.window == true
    S.phase = "read"
    return S
  end,
  step = function(S, budget)
    local body = companion.require_present()
    -- (A 0.34 snapshot in a loaded save has no phase: it was reading.)
    S.phase = S.phase or "read"
    local worked = false
    while true do
      if budget.left <= 0 then return nil end
      if S.phase == "read" then
        if S.cursor <= #S.surfaces then read_one(S, body.force, budget); worked = true else S.phase = PHASE_NEXT.read end
      else
        -- One phase a tick, and never after other work in it: a phase's
        -- cost is an estimate, and costs that fit one tick's budget together
        -- took 15.8 ms in one (trial 0013: 29 of 203 snapshots over 8 ms,
        -- the median growing with the factory). The snapshot is read
        -- through get_job anyway, so the ticks cost nothing but latency.
        if worked then return nil end
        worked = true
        local phase = PHASES[S.phase]
        local cost = 1 + phase.cost(S, body)
        if cost > budget.left and not S.waited then
          S.waited = true
          return nil
        end
        S.waited = nil
        local result = phase.run(S, body)
        budget.left = budget.left - cost
        if S.phase == "assemble" then return result end
        S.phase = PHASE_NEXT[S.phase]
      end
    end
  end,
}

return M
