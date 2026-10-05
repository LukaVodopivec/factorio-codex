-- run_snapshot: what the run recorder samples, as a job (jobs.lua): one
-- surface's item or fluid statistics a step, so the work does not grow in
-- one tick with the number of planets and platforms, and the result goes
-- out through the jobs encoder. Statistics are summed over every factory
-- surface in statistics.items / statistics.fluids, so the recorder's deltas
-- stay stable when the body travels; with more than one surface,
-- statistics.by_surface[ref] = {items, fluids} keeps each one's own. Works
-- in every body state but absent: the compact observation only while the
-- body stands on a surface.
local autonomy = require("scripts.autonomy")
local companion = require("scripts.companion")
local factory_activity = require("scripts.factory_activity")
local map_summary = require("scripts.map_summary")
local registry = require("scripts.registry")
local research = require("scripts.research")
local spatial = require("scripts.spatial")
local surfaces = require("scripts.surfaces")

local M = {}

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
    budget.left = budget.left - 4 - math.ceil((size(input) + size(output)) / 8)
  else
    budget.left = budget.left - 1
  end
  if S.kind < #KINDS then S.kind = S.kind + 1 else S.cursor, S.kind = S.cursor + 1, 1 end
end

local function counters(raw)
  if raw.unavailable then return { produced = {}, consumed = {}, unavailable = true } end
  return { produced = sorted_counts(raw.input), consumed = sorted_counts(raw.output) }
end

-- The character's state: the compact observation's on a surface (radius 5
-- is bounded by its small area), else what the body carries.
local function character(body)
  if companion.get() then return spatial.observe_compact({ radius = 5 }).character end
  local ok, state = pcall(spatial.character_state, body.character)
  return ok and state or nil
end

local function snapshot_finish(S, budget)
  local body = companion.require_present()
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
  budget.left = budget.left - 20 - #read * 8
  return {
    tick = game.tick,
    character = character(body),
    -- Where the body is: {state, surface_ref, platform_name?}.
    body = companion.body_summary(),
    progression = research.progression_status({}),
    -- What the mod maintains (registry, line sampler, power cache): no chunk
    -- walk and no entity read per sample.
    factory = map_summary.registry_factory(),
    -- Production lines (autonomy.lua): how many run, self-sustain or are hand-fed.
    lines = autonomy.counts(),
    statistics = {
      -- Summed over every factory surface (the recorder's keys).
      items = summed.items,
      fluids = summed.fluids,
      by_surface = by_surface,
      raw_resources = raw_resource_products(),
      -- Items the Codex player crafted by hand since since_tick (cumulative).
      hand_crafted = factory_activity.hand_crafted(),
      semantics = { produced = "force_surface_input_counts", consumed = "force_surface_output_counts",
        items = "summed_over_factory_surfaces" },
    },
  }
end

-- run_snapshot {}: the job definition (control.lua registers it).
M.job = {
  start = function() return snapshot_start() end,
  step = function(S, budget)
    local force = companion.require_present().force
    while S.cursor <= #S.surfaces do
      if budget.left <= 0 then return nil end
      read_one(S, force, budget)
    end
    if budget.left <= 0 then return nil end
    return snapshot_finish(S, budget)
  end,
}

return M
