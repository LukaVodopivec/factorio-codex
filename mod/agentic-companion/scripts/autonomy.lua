-- Factory lines: what each group of machines is doing, kept by the mod so no
-- bot has to watch, wait or prove anything.
--
-- A line is the own machines on one surface making the same product (same
-- machine class and recipe or mined resource) whose centres lie within
-- LINK_TILES of another member. Lines on every factory surface are kept (a
-- line's `surface` is its surface index); reads name the surface they want. Topology is refreshed only after something is built, removed or
-- reconfigured (debounced), plus a slow safety cadence for changes that raise
-- no event; it reads the event-maintained registry (registry.lua), never an
-- entity query, and waits until the registry's bootstrap is ready. A refresh
-- identifies REFRESH_PER_TICK machines a tick and regroups on its last tick;
-- the previous lines stay in use until then. A silo's rocket becoming ready
-- is recorded in the space event ring (platforms.lua) by the same samples,
-- with no read of its own. A bucketed
-- sampler reads each machine (never belts) every SAMPLE_PERIOD ticks through
-- its stored entity reference, so about machines/30 entities are read a tick.
--
-- Per line the mod keeps:
--   state           running (some machine progressed in the last 10 s, or a
--                   farm waits for its plants to grow) | starved |
--                   output_full | depleted (a drill's resource ran out) |
--                   no_fuel | no_power | frozen | no_heat | disabled | idle
--                   (the worst state among the machines that are not
--                   progressing)
--   cause           why the worst machine stalls: the item or fluid a starved
--                   one lacks ("seed" for an agricultural tower with no spot
--                   its seeds take; the game's status, such as
--                   no_ingredients, when no lack can be named, as for a
--                   furnace that never smelted), no_recipe / recipe_not_researched /
--                   not_connected_to_hub_or_pad / no_research (labs while no
--                   research is active) for an idle one (rocket_ready for a
--                   silo whose rocket waits for its launch), burnt_result for
--                   spent fuel that has nowhere to go, outlet_no_fuel for a
--                   full machine whose burner inserter taking from it ran
--                   dry (cause_position is that inserter), the resource a
--                   depleted drill last mined;
--                   worked out when the cause machine or its status changes
--                   (and every 10 s while it lasts), never by a read
--   meets           (a fluid cause) the other fluid the lacking box's
--                   connections meet, as heavy oil piped to a crude-oil inlet
--   temperature     (power lines with a reactor or heat exchanger) the lowest
--                   sampled heat-source temperature
--   working         machines that progressed in the last 10 s
--   rate_per_min    products finished over the last minute (items, or crafts)
--   max_per_min     what the members make a minute at full duty, worked out
--                   when the line regroups (machine_capacity); absent while
--                   a member's is unknown
--   utilisation     rate_per_min / max_per_min
--   share_10m       the share of the evaluates of about the last 10 minutes
--                   the line spent in each state, from one counter bin a
--                   minute; shown once the line was not running nearly all
--                   of that time
--   fuel_s          (lines with burner members) seconds of fuel the lowest
--                   member has left at its measured burn rate (fuel_energy)
--   supply_states   (no_power rows, and map_summary's power rows short of
--                   power) the generating lines on the same electric
--                   network: state, position and fuel_s (supply_states)
--   hand_fed        a character transfer into one of its machines in the last 60 s
--   degraded        (running lines) {state, cause_position}: the worst
--                   member problem past its threshold (a dry boiler beside
--                   working engines)
--   self_sustaining 60 s running with no character transfer, no stall and
--                   no member out of fuel or power past its threshold
--   hand_transfers  character transfers into or out of its machines in the
--                   last 10 minutes, shown from the second on: a line served
--                   by hand again is not yet automated (no belt, inserter or chest feeds it)
--   hand_seconds    body time those insert/extract steps took in the last 10
--                   minutes (walking and fetching included), shown from 10 s:
--                   what keeping the line running by hand costs
--   feed            (a starved line lacking an item, a no_fuel line, a
--                   degraded no_fuel member and the no_fuel problem row of a
--                   line machine whose feed was read) the inserters that drop
--                   into that machine, read once per episode and again after
--                   each line refresh (see read_feed)
local registry = require("scripts.registry")
local platforms = require("scripts.platforms")
local surfaces = require("scripts.surfaces")
local fluid_connections = require("scripts.fluid_connections")

local M = {}

local SAMPLE_PERIOD = 30
local REFRESH_DEBOUNCE_TICKS = 300
local REFRESH_SAFETY_TICKS = 3600
local REFRESH_PER_TICK = 32 -- machines a refresh identifies a tick
local MINUTE_TICKS = 3600
-- A machine that made progress this recently counts as running.
local PRODUCTIVE_TICKS = 600
local RATE_BIN_TICKS, RATE_BINS = 600, 6
-- State share counters: one bin a minute, ten kept.
local SHARE_BIN_TICKS, SHARE_BINS = MINUTE_TICKS, 10
-- share_10m is shown once running fell below this share.
local SHARE_SHOWN_BELOW = 0.99
-- Generating lines a supply_states list names.
local MAX_SUPPLY = 3
local LINK_TILES = 6
-- Hand transfers a line keeps (ticks), and how long each counts.
local REPEAT_WINDOW_TICKS, MAX_REPEAT_TICKS = 10 * MINUTE_TICKS, 8

local MACHINE_TYPES = registry.MACHINE_TYPES
-- Beacons, roboports and burner inserters make nothing: sampled for
-- problems, never a line.
local PROBLEM_ONLY_TYPES = registry.PROBLEM_ONLY_TYPES
local BURNER_ONLY_TYPES = registry.BURNER_ONLY_TYPES
local CRAFTING_TYPES = { furnace = true, ["assembling-machine"] = true, ["rocket-silo"] = true }
-- Steam, nuclear and fusion power is one line: pumps, boilers, heat
-- exchangers, reactors (and heating towers) and engines feed each other;
-- lightning attractors join it.
local POWER_TYPES = { boiler = true, generator = true, ["burner-generator"] = true, ["offshore-pump"] = true,
  reactor = true, ["fusion-reactor"] = true, ["fusion-generator"] = true, ["lightning-attractor"] = true }

-- Raw entity status -> line state class of a machine that is not progressing.
local STATUS_CLASS = {
  no_power = "no_power", low_power = "no_power", not_plugged_in_electric_network = "no_power",
  no_fuel = "no_fuel", low_temperature = "no_heat", frozen = "frozen",
  full_output = "output_full", waiting_for_space_in_destination = "output_full",
  full_burnt_result_output = "output_full", waiting_for_space_in_platform_hub = "output_full",
  no_ingredients = "starved", item_ingredient_shortage = "starved", fluid_ingredient_shortage = "starved",
  waiting_for_source_items = "starved", missing_science_packs = "starved", no_minable_resources = "depleted",
  missing_required_fluid = "starved", no_input_fluid = "starved", low_input_fluid = "starved",
  pipeline_overextended = "starved", no_spot_seedable_by_inputs = "starved",
  disabled_by_control_behavior = "disabled", disabled_by_script = "disabled",
  no_recipe = "idle", recipe_not_researched = "idle", not_connected_to_hub_or_pad = "idle",
  no_research_in_progress = "idle",
}
-- Statuses that count as progress: a farm waiting for its plants to grow.
local PROGRESS_STATUS = { working = true, waiting_for_plants_to_grow = true }
-- Statuses whose cause is the fluid a fluidbox filter names.
local FLUID_STATUS = { missing_required_fluid = true, no_input_fluid = true, low_input_fluid = true,
  pipeline_overextended = true }
-- The worst present state names the line when it is not running.
local STATE_PRIORITY = { "no_power", "frozen", "no_heat", "no_fuel", "output_full", "depleted", "starved", "disabled",
  "idle" }
local STATE_RANK = {}
for rank, name in ipairs(STATE_PRIORITY) do STATE_RANK[name] = rank end
-- A member out of fuel or power past its threshold: the line is not
-- self-sustaining even while other members still run.
local DEAD_CLASSES = { no_fuel = true, no_power = true }
-- Statuses that are problems once they last this many ticks. Output full
-- is ordinary backpressure for a while; dead machines are not. Labs with no
-- research active say research is idle (the strategist's cue).
local PROBLEM_TICKS = {
  no_power = 60, not_plugged_in_electric_network = 60, no_fuel = 60,
  no_minable_resources = 60, full_output = 600, waiting_for_space_in_destination = 600,
  low_temperature = 600, no_modules_to_transmit = 600, pipeline_overextended = 600,
  frozen = 60, no_research_in_progress = 600,
}
-- A burner inserter waiting on its source or target is ordinary: only fuel
-- is its problem.
local FUEL_PROBLEM_TICKS = { no_fuel = PROBLEM_TICKS.no_fuel }
-- Problem rows that carry a fixed cause.
local PROBLEM_CAUSE = { no_modules_to_transmit = "module", no_research_in_progress = "research_idle" }
-- Statuses upkeep serves (chores.lua): kept per status as unit sets, with
-- the "low_fuel" set: working burner machines with fewer than
-- LOW_FUEL_ITEMS fuel items left beside what burns, refuelled before they
-- run dry.
local CHORE_STATUSES = { no_fuel = true, missing_science_packs = true }
local LOW_FUEL_ITEMS = 2
-- How long a computed line cause is trusted while its machine and status
-- stay the same.
local CAUSE_TICKS = 600
-- Line causes worked out per evaluate (each reads a machine's inventory and
-- recipe); the lines past it keep their cause and go first next time.
local MAX_CAUSES = 16

local status_names
local function status_name(entity)
  local status = entity.status
  if status == nil then return nil end
  if not status_names then
    status_names = {}
    for name, value in pairs((defines and defines.entity_status) or {}) do status_names[value] = name end
  end
  return status_names[status] or tostring(status)
end

local function data() return storage and storage.autonomy end

-- A machine's place: its surface index and position.
local function position_key(surface, position)
  return string.format("%d@%.2f,%.2f", surface or 0, position.x, position.y)
end

local function current_recipe(entity)
  local recipe = entity.get_recipe()
  if recipe or entity.type ~= "furnace" then return recipe end
  -- An idle furnace keeps the recipe it last smelted (a name or a prototype).
  local ok, previous = pcall(function() return entity.previous_recipe end)
  local name = ok and previous or nil
  for _ = 1, 2 do if name ~= nil and type(name) ~= "string" then name = name.name end end
  return type(name) == "string" and prototypes.recipe[name] or nil
end

-- Items a product gives per cycle on average: its amount (the midpoint of
-- a ranged amount) times its probability, plus any extra count fraction.
local function expected_amount(product)
  local amount = tonumber(product.amount)
  if not amount then
    local low, high = tonumber(product.amount_min), tonumber(product.amount_max)
    amount = low and high and (low + high) / 2 or 1
  end
  return amount * (tonumber(product.probability) or 1) + (tonumber(product.extra_count_fraction) or 0)
end

-- {key, product, yield, recipe, energy}: what a machine makes (its recipe's
-- or resource's first product), how many of it per cycle on average, and the
-- recipe's name and energy for crafting machines.
local function identity(entity)
  if POWER_TYPES[entity.type] then return "power", "electricity", 0 end
  if entity.type == "lab" then return "lab", "research", 0 end
  local product, yield, recipe_name, energy
  if entity.type == "mining-drill" then
    local ok, target = pcall(function() return entity.mining_target end)
    local mineable = ok and target and target.prototype.mineable_properties
    local first = mineable and mineable.products and mineable.products[1]
    if first then product, yield = first.name, expected_amount(first) end
  else
    local ok, recipe = pcall(current_recipe, entity)
    local first = ok and recipe and recipe.products and recipe.products[1]
    if first then
      product, yield, recipe_name, energy = first.name, expected_amount(first), recipe.name, tonumber(recipe.energy)
    end
  end
  if not product then return entity.type .. ":" .. entity.name, nil, 0 end
  return entity.type .. ":" .. product, product, yield, recipe_name, energy
end

local function number_of(read)
  local ok, value = pcall(read)
  return ok and type(value) == "number" and value or nil
end

-- A drill's installed nominal capacity a minute (items of every product),
-- independent of duty, status and bonuses, or nil: it needs a current
-- target in a charted chunk and fixed, certain item products. map_summary's
-- machine groups sum it too.
function M.nominal_mining_capacity(entity, force, surface, platform)
  local ok, rate = pcall(function()
    local target = entity.mining_target
    if not (target and target.valid and type(target.position) == "table") then return nil end
    if not surfaces.charted(force, surface, math.floor(target.position.x / 32), math.floor(target.position.y / 32),
      platform) then return nil end
    local mining = target.prototype.mineable_properties
    local speed, time = entity.prototype.mining_speed, mining.mining_time
    if type(speed) ~= "number" or speed <= 0 or speed >= math.huge
      or type(time) ~= "number" or time <= 0 or time >= math.huge then return nil end
    local yield, count = 0, 0
    for _, product in pairs(mining.products) do
      if product.type ~= "item" or type(product.name) ~= "string"
        or (product.probability ~= nil and product.probability ~= 1) then return nil end
      local amount = product.amount
      if amount == nil and product.amount_min == product.amount_max then amount = product.amount_min end
      if type(amount) ~= "number" or amount <= 0 or amount >= math.huge then return nil end
      yield, count = yield + amount, count + 1
    end
    if count == 0 then return nil end
    local result = 60 * speed / time * yield
    if result > 0 and result < math.huge then return result end
  end)
  return ok and rate or nil
end

-- What a machine makes a minute at full duty, in its line's units, and its
-- productivity bonus. A crafting machine: crafting speed (modules, beacons
-- and quality included) / recipe energy, as map_summary's
-- theoretical_crafts_per_second, x (1 + productivity) x yield x 60, where
-- productivity is the entity's (modules and beacons) plus the force's
-- research bonus for the recipe (2.0.77 keeps that one off the entity), at
-- most the recipe's maximum. A drill: its nominal mining capacity x (1 +
-- speed bonus) x (1 + productivity: the entity's includes the force's
-- mining productivity). nil for other machines and when a value cannot be
-- read. A drill also gives its cycle in ticks at full duty and its target's
-- mining time (the unit both its progress bars count in), for the sampler.
-- Read when the lines regroup, so module and research changes count from
-- the next refresh (at most a minute).
local function machine_capacity(entity, rec, force)
  if not rec.product or (rec.yield or 0) <= 0 then return nil end
  local productivity = number_of(function() return entity.productivity_bonus end) or 0
  if rec.recipe then
    productivity = productivity + (number_of(function() return entity.force.recipes[rec.recipe].productivity_bonus end) or 0)
    local most = number_of(function() return prototypes.recipe[rec.recipe].maximum_productivity end)
    if most and productivity > most then productivity = most end
  end
  if rec.type == "mining-drill" then
    local nominal = M.nominal_mining_capacity(entity, force, entity.surface)
    if not nominal then return nil end
    local speed = number_of(function() return entity.speed_bonus end) or 0
    local time = number_of(function() return entity.mining_target.prototype.mineable_properties.mining_time end)
    local base = number_of(function() return entity.prototype.mining_speed end)
    local cycle = time and base and base * (1 + speed) > 0 and 60 * time / (base * (1 + speed)) or nil
    return nominal * (1 + speed) * (1 + productivity), productivity, cycle, time
  end
  if not (CRAFTING_TYPES[rec.type] and rec.energy and rec.energy > 0) then return nil end
  local speed = number_of(function() return entity.crafting_speed end)
  if not (speed and speed > 0) then return nil end
  return speed / rec.energy * (1 + productivity) * rec.yield * 60, productivity
end

-- Reactors and heat exchangers (boilers with a heat energy source) report
-- the temperature of their heat source.
local function heat_powered(entity)
  if entity.type == "reactor" then return true end
  if entity.type ~= "boiler" then return false end
  local ok, source = pcall(function() return entity.prototype.heat_energy_source_prototype end)
  return ok and source ~= nil
end

function M.mark_dirty()
  local a = data()
  if a and not a.dirty_tick then a.dirty_tick = game.tick end
end

-- Build/remove events: only machines change lines (an inserter only with a
-- burner: one more read, for inserters alone).
function M.on_entity_changed(event)
  local entity = event and (event.entity or event.created_entity)
  local ok, kind = pcall(function() return entity and entity.valid and entity.type end)
  if not (ok and kind and MACHINE_TYPES[kind]) then return end
  local burner = false
  if BURNER_ONLY_TYPES[kind] then
    local read, value = pcall(function() return entity.burner end)
    burner = read and value ~= nil
  end
  if registry.is_machine(kind, burner) then M.mark_dirty() end
end

local function new_line(a, key, product)
  local id = a.next_line_id
  a.next_line_id = id + 1
  return { id = id, key = key, product = product, created_tick = game.tick, changed_tick = game.tick,
    state = "idle", rate_bins = {}, rate_bin = nil }
end

-- Starts a refresh: the unit numbers of the own machines on every surface,
-- in the registry's add order (a pure Lua pass; no entity read, no sort).
local function refresh_start(a)
  a.dirty_tick, a.last_refresh_tick = nil, game.tick
  a.refresh_job = { units = registry.machine_units(), index = 1, list = {}, recs = {}, charted = {} }
end

-- What each machine makes, `count` machines at a time (onto its kept record,
-- which the sampler goes on reading): only valid machines in charted chunks
-- (one chart check per surface and chunk) join the job's list. True once
-- every machine is done. A refresh a 0.22.2 or older save left half done
-- starts again.
local function refresh_identify(a, count)
  local job = a.refresh_job
  if not job.units then
    refresh_start(a)
    job = a.refresh_job
  end
  local units = job.units
  local stop = math.min(#units, job.index + count - 1)
  local force = job.index <= stop and registry.own_force()
  for i = job.index, stop do
    local entry = registry.charted_machine(units[i], force, job.charted)
    local entity, unit = entry and entry.entity, units[i]
    if entity then
      job.list[#job.list + 1] = entry
      local rec = a.machines[unit] or { unit = unit }
      rec.entity, rec.name, rec.type, rec.surface = entity, entry.name, entry.type, entry.surface
      rec.position = { x = entry.position.x, y = entry.position.y }
      if PROBLEM_ONLY_TYPES[entry.type] then
        rec.key, rec.product, rec.yield, rec.recipe, rec.line_id = nil, nil, 0, nil, nil
      else
        local ok, key, product, yield, recipe, energy = pcall(identity, entity)
        if ok then rec.key, rec.product, rec.yield, rec.recipe, rec.energy = key, product, yield, recipe, energy
        else rec.key, rec.product, rec.yield, rec.recipe, rec.energy = entry.type .. ":" .. entry.name, nil, 0, nil, nil end
        local read, capacity, productivity, cycle, mining_time = pcall(machine_capacity, entity, rec, force)
        rec.capacity, rec.productivity = read and capacity or nil, read and productivity or nil
        rec.cycle, rec.mining_time = read and cycle or nil, read and mining_time or nil
        -- A drill keeps the resource it last mined: once depleted it has none.
        if entry.type == "mining-drill" and rec.product then rec.resource = rec.product end
        if rec.heat == nil then rec.heat = heat_powered(entity) end
      end
      job.recs[unit] = rec
    end
  end
  job.index = stop + 1
  return job.index > #units
end

-- The chore status sets: waiting[raw or "low_fuel"][surface index][unit] =
-- true, so upkeep reads only the machines on the body's surface.
local function add_waiting(waiting, rec, set)
  local surface = rec.surface or 0
  set = set or rec.raw
  local by_surface = waiting[set] or {}
  waiting[set] = by_surface
  by_surface[surface] = by_surface[surface] or {}
  by_surface[surface][rec.unit] = true
end

-- The refresh's last tick: groups the identified machines into lines (pure
-- Lua) and swaps lines, buckets and chore sets in at once.
local function refresh_finish(a)
  local job = a.refresh_job
  a.refresh_job = nil
  local old_lines = a.lines
  local machines, list, machine_at, problem_only, waiting = {}, {}, {}, {}, {}
  for _, entry in ipairs(job.list) do
    local unit = entry.unit
    local rec = job.recs[unit]
    if rec then
      machines[unit] = rec
      -- Feeders may have been built or rebuilt: the feed is read again.
      if rec.feed then rec.feed.stale = true end
      if CHORE_STATUSES[rec.raw] then add_waiting(waiting, rec) end
      if rec.low_fuel then add_waiting(waiting, rec, "low_fuel") end
      if PROBLEM_ONLY_TYPES[rec.type] then
        problem_only[#problem_only + 1] = unit
      else
        list[#list + 1] = rec
        machine_at[position_key(rec.surface, rec.position)] = unit
      end
    end
  end
  -- Same surface and product and within LINK_TILES (Chebyshev) of a
  -- member: one line.
  local parent, cells = {}, {}
  local function root(unit)
    while parent[unit] ~= unit do parent[unit] = parent[parent[unit]]; unit = parent[unit] end
    return unit
  end
  for _, rec in ipairs(list) do
    parent[rec.unit] = rec.unit
    local cx, cy = math.floor(rec.position.x / LINK_TILES), math.floor(rec.position.y / LINK_TILES)
    local prefix = (rec.surface or 0) .. "@"
    for dy = -1, 1 do for dx = -1, 1 do
      for _, other in ipairs(cells[prefix .. (cx + dx) .. "," .. (cy + dy)] or {}) do
        if other.key == rec.key and math.abs(other.position.x - rec.position.x) <= LINK_TILES
          and math.abs(other.position.y - rec.position.y) <= LINK_TILES then
          local ra, rb = root(other.unit), root(rec.unit)
          if ra ~= rb then parent[math.max(ra, rb)] = math.min(ra, rb) end
        end
      end
    end end
    local cell = prefix .. cx .. "," .. cy
    cells[cell] = cells[cell] or {}
    table.insert(cells[cell], rec)
  end
  local groups, group_order = {}, {}
  for _, rec in ipairs(list) do
    local r = root(rec.unit)
    if not groups[r] then groups[r] = {}; group_order[#group_order + 1] = r end
    table.insert(groups[r], rec)
  end
  -- A group keeps the line its most members belonged to (lowest id on a tie),
  -- so state and rate survive builds next to it (a line kept from before
  -- lines had surfaces takes its members' surface).
  local lines, order, taken = {}, {}, {}
  for _, r in ipairs(group_order) do
    local members, votes, best = groups[r], {}, nil
    for _, rec in ipairs(members) do
      local id = rec.line_id
      local old = id and old_lines[id]
      if old and old.key == rec.key and (old.surface == nil or old.surface == rec.surface) and not taken[id] then
        votes[id] = (votes[id] or 0) + 1
      end
    end
    for id, count in pairs(votes) do
      if not best or count > votes[best] or count == votes[best] and id < best then best = id end
    end
    local line = best and old_lines[best] or new_line(a, members[1].key, members[1].product)
    taken[line.id] = true
    local units, sx, sy, last_transfer, capacity = {}, 0, 0, nil, 0
    for _, rec in ipairs(members) do
      rec.line_id = line.id
      units[#units + 1] = rec.unit
      sx, sy = sx + rec.position.x, sy + rec.position.y
      capacity = capacity and rec.capacity and capacity + rec.capacity or nil
      local transfer = a.transfer_tick[position_key(rec.surface, rec.position)]
      if transfer and (not last_transfer or transfer > last_transfer) then last_transfer = transfer end
    end
    if #units ~= #(line.machines or {}) then line.changed_tick = game.tick end
    line.machines, line.product, line.surface = units, members[1].product, members[1].surface
    line.max_per_min = capacity
    line.position = { x = math.floor(sx / #members + 0.5), y = math.floor(sy / #members + 0.5) }
    if last_transfer and (not line.last_transfer_tick or last_transfer > line.last_transfer_tick) then
      line.last_transfer_tick = last_transfer
    end
    lines[line.id] = line
    order[#order + 1] = line.id
  end
  table.sort(order)
  -- Stable buckets: a machine is always read at the same phase.
  local buckets = {}
  for _, rec in pairs(machines) do
    local bucket = rec.unit % SAMPLE_PERIOD
    buckets[bucket] = buckets[bucket] or {}
    table.insert(buckets[bucket], rec.unit)
  end
  for _, units in pairs(buckets) do table.sort(units) end
  for key, tick in pairs(a.transfer_tick) do
    if game.tick - tick > MINUTE_TICKS then a.transfer_tick[key] = nil end
  end
  a.machines, a.lines, a.line_order, a.buckets, a.machine_at = machines, lines, order, buckets, machine_at
  a.problem_only, a.waiting = problem_only, waiting
end

-- Refreshes the lines within this call (tests, and a first refresh).
function M.refresh()
  local a = data()
  refresh_start(a)
  if a.refresh_job then
    refresh_identify(a, math.huge)
    refresh_finish(a)
  end
end

local function add_output(line, tick, amount)
  local bin = math.floor(tick / RATE_BIN_TICKS)
  if line.rate_bin ~= bin then
    -- Clear the bins skipped since the last output.
    for b = (line.rate_bin and math.max(line.rate_bin + 1, bin - RATE_BINS + 1) or bin - RATE_BINS + 1), bin do
      line.rate_bins[b % RATE_BINS + 1] = 0
    end
    line.rate_bin = bin
  end
  local slot = bin % RATE_BINS + 1
  line.rate_bins[slot] = (line.rate_bins[slot] or 0) + amount
end

-- Counts one evaluate of a line in a state: share_bins[slot] = {[state] =
-- evaluates} for each of the last SHARE_BINS minutes.
local function count_state(line, tick, state)
  local bin = math.floor(tick / SHARE_BIN_TICKS)
  local bins = line.share_bins or {}
  if line.share_bin ~= bin then
    -- Clear the bins skipped since the last count.
    for b = (line.share_bin and math.max(line.share_bin + 1, bin - SHARE_BINS + 1) or bin - SHARE_BINS + 1), bin do
      bins[b % SHARE_BINS + 1] = {}
    end
    line.share_bins, line.share_bin = bins, bin
  end
  local slot = bins[bin % SHARE_BINS + 1]
  slot[state] = (slot[state] or 0) + 1
end

-- The share of about the last 10 minutes' evaluates in each state (two
-- places, shares under 0.005 left out), or nil while running took at least
-- SHARE_SHOWN_BELOW of them.
local function share_10m(line, tick)
  local bin = math.floor(tick / SHARE_BIN_TICKS)
  if not line.share_bin or bin - line.share_bin >= SHARE_BINS then return nil end
  local counts, total = {}, 0
  for b = math.max(line.share_bin - SHARE_BINS + 1, bin - SHARE_BINS + 1), line.share_bin do
    for state, n in pairs(line.share_bins[b % SHARE_BINS + 1] or {}) do
      counts[state], total = (counts[state] or 0) + n, total + n
    end
  end
  if total == 0 or (counts.running or 0) >= total * SHARE_SHOWN_BELOW then return nil end
  local out = {}
  for state, n in pairs(counts) do
    local share = math.floor(n / total * 100 + 0.5) / 100
    if share > 0 then out[state] = share end
  end
  return out
end

-- Keeps the chore status sets (upkeep reads them) as a machine's status
-- changes.
local function set_raw(a, rec, raw)
  local old = rec.raw
  if old == raw then return end
  local by_surface = CHORE_STATUSES[old] and a.waiting[old]
  local units = by_surface and by_surface[rec.surface or 0]
  if units then units[rec.unit] = nil end
  rec.raw = raw
  if CHORE_STATUSES[raw] then add_waiting(a.waiting, rec) end
end

-- An item's fuel value in joules (0 when it has none), cached per name.
local fuel_values = {}
local function fuel_value(name)
  local value = fuel_values[name]
  if value == nil then
    value = number_of(function() return prototypes.item[name].fuel_value end) or 0
    fuel_values[name] = value
  end
  return value
end

-- The joules a burner holds (its fuel inventory's items' fuel values plus
-- remaining_burning_fuel) and its fuel item count, in two reads.
local function fuel_energy(burner)
  local energy, count = number_of(function() return burner.remaining_burning_fuel end) or 0, 0
  for _, row in ipairs(burner.inventory.get_contents()) do
    count = count + row.count
    energy = energy + row.count * fuel_value(row.name)
  end
  return energy, count
end

-- The burn rate (joules a tick) is what the energy fell by since the last
-- sample: the current consumption, 0 while the machine burns nothing. A
-- sample with more energy than the last was refuelled in between, so the
-- last rate stands.
local function measure_burn(rec, energy, tick)
  if rec.fuel_j and rec.fuel_tick and tick > rec.fuel_tick and energy <= rec.fuel_j then
    rec.burn = (rec.fuel_j - energy) / (tick - rec.fuel_tick)
  end
  rec.fuel_j, rec.fuel_tick = energy, tick
end

-- A burner member's runway in whole seconds: 0 with no fuel, nil while it
-- burns nothing (or before a rate is measured).
local function fuel_seconds(rec)
  if not rec.fuel_j then return nil end
  if rec.fuel_j <= 0 then return 0 end
  if rec.burn and rec.burn > 0 then return math.floor(rec.fuel_j / rec.burn / 60) end
end

-- Keeps the low_fuel set as a burner machine's fuel runs low or is topped
-- up: low only while working with fewer than LOW_FUEL_ITEMS fuel items (a
-- failed read is not low). The same reads measure its fuel energy and burn
-- rate (fuel_s). A burner inserter is never low: one moving coal fuels
-- itself from its hand an item at a time, so only no_fuel needs upkeep.
local function set_low_fuel(a, rec, entity, raw, tick)
  if rec.burner == nil then
    local ok, burner = pcall(function() return entity.burner end)
    rec.burner = ok and burner ~= nil
  end
  local low = false
  if rec.burner and not BURNER_ONLY_TYPES[rec.type] then
    local ok, energy, count = pcall(function() return fuel_energy(entity.burner) end)
    if ok then
      measure_burn(rec, energy, tick)
      low = raw == "working" and count < LOW_FUEL_ITEMS
    else
      rec.fuel_j, rec.fuel_tick, rec.burn = nil, nil, nil
    end
  end
  if (rec.low_fuel == true) == low then return end
  rec.low_fuel = low or nil
  if low then add_waiting(a.waiting, rec, "low_fuel") return end
  local units = a.waiting.low_fuel and a.waiting.low_fuel[rec.surface or 0]
  if units then units[rec.unit] = nil end
end

-- Mining time of the resource whose first product is this item, once per
-- load from prototypes (false when none, or resources that disagree; a
-- failed read is not kept).
local mining_times = {}
local function mining_time(product)
  local known = mining_times[product]
  if known ~= nil then return known or nil end
  known = false
  local ok, resources = pcall(function() return prototypes.get_entity_filtered({ { filter = "type", type = "resource" } }) end)
  if not ok then return nil end
  for _, proto in pairs(resources or {}) do
    local mining = proto.mineable_properties
    local first = mining and mining.products and mining.products[1]
    local time = mining and tonumber(mining.mining_time)
    if first and first.name == product and first.type ~= "fluid" and time and time > 0 then
      if known and known ~= time then known = false; break end
      known = time
    end
  end
  mining_times[product] = known
  return known or nil
end

local function sample(a, rec, tick)
  local entity = rec.entity
  if not (entity and entity.valid) then a.dirty_tick = a.dirty_tick or tick; return end
  local raw = status_name(entity)
  if rec.heat then
    local ok, temperature = pcall(function() return entity.temperature end)
    rec.temperature = ok and type(temperature) == "number" and temperature or nil
  end
  local progressed, produced = PROGRESS_STATUS[raw] == true, 0
  if rec.type == "mining-drill" then
    local progress = entity.mining_progress
    -- Productivity's extra products fill a progress bar of their own (read
    -- only for a drill with a bonus), so the rate and max_per_min agree.
    local bonus = (rec.productivity or 0) > 0 and number_of(function() return entity.bonus_mining_progress end) or nil
    if rec.progress and progress ~= rec.progress then
      progressed = true
      local mined = progress < rec.progress and 1 or 0
      local extra = bonus and rec.bonus_progress and bonus < rec.bonus_progress and 1 or 0
      -- A drill whose cycle is shorter than a sample period wraps its bars
      -- more than once between samples. Working at both samples, it ran the
      -- elapsed ticks at full duty: the cycles finished are the bar's
      -- advance (elapsed / cycle in mining-time units; the bonus bar's is
      -- that x productivity) plus the old reading less the new.
      if rec.cycle and rec.cycle < SAMPLE_PERIOD and rec.mining_time and rec.progress_tick
        and raw == "working" and rec.raw == "working" then
        local cycles = (tick - rec.progress_tick) / rec.cycle
        mined = math.max(mined, math.floor(cycles + (rec.progress - progress) / rec.mining_time + 0.01))
        if bonus and rec.bonus_progress then
          extra = math.max(extra, math.floor(cycles * rec.productivity + (rec.bonus_progress - bonus) / rec.mining_time + 0.01))
        end
      end
      produced = mined + extra
    end
    rec.progress, rec.bonus_progress, rec.progress_tick = progress, bonus, tick
  elseif CRAFTING_TYPES[rec.type] then
    local finished = entity.products_finished
    if rec.finished and finished > rec.finished then progressed, produced = true, finished - rec.finished end
    rec.finished = finished
  end
  if rec.type == "rocket-silo" then
    -- Only a transition counts: a silo first sampled with a ready rocket is
    -- not news.
    local ready = entity.rocket_silo_status == defines.rocket_silo_status.rocket_ready
    if ready and rec.rocket_ready == false then platforms.on_rocket_ready(entity) end
    rec.rocket_ready = ready
  end
  if progressed then
    rec.productive_tick = tick
    -- A furnace's first smelt fixes its recipe: regroup it.
    if not rec.product and CRAFTING_TYPES[rec.type] then a.dirty_tick = a.dirty_tick or tick end
  end
  if produced > 0 and rec.yield > 0 then
    local line = a.lines[rec.line_id]
    if line then add_output(line, tick, produced * rec.yield) end
  end
  if BURNER_ONLY_TYPES[rec.type] then
    -- A dry inserter marks the machine it takes from (its pickup target,
    -- read once per dry episode), so a full machine names its dry outlet.
    if raw ~= "no_fuel" then rec.pickup_unit = nil
    elseif rec.raw ~= "no_fuel" then
      local ok, unit = pcall(function() local target = entity.pickup_target; return target and target.unit_number end)
      rec.pickup_unit = ok and unit or nil
    end
    local target = rec.pickup_unit and a.machines[rec.pickup_unit]
    if target then target.dry_picker = rec.unit end
  end
  set_raw(a, rec, raw)
  set_low_fuel(a, rec, entity, raw, tick)
  local threshold = (BURNER_ONLY_TYPES[rec.type] and FUEL_PROBLEM_TICKS or PROBLEM_TICKS)[raw]
  if threshold then
    -- The same problem returning inside the recovery window is the old
    -- episode: it keeps its start and is not announced again.
    rec.clear_since = nil
    if rec.problem ~= raw then
      rec.problem, rec.problem_since, rec.problem_counted, rec.problem_announced_tick = raw, tick, nil, nil
    end
    if not rec.problem_counted and tick - rec.problem_since >= threshold then
      rec.problem_counted, rec.problem_announced_tick = true, tick
      a.last_problem_tick = tick
    end
  elseif rec.problem then
    -- Hysteresis: a problem clears only after PRODUCTIVE_TICKS without it,
    -- so backpressure that flaps with short working bursts is one problem.
    rec.clear_since = rec.clear_since or tick
    if tick - rec.clear_since >= PRODUCTIVE_TICKS then
      rec.problem, rec.problem_since, rec.problem_counted, rec.clear_since, rec.problem_announced_tick = nil, nil, nil, nil, nil
    end
  end
end

-- The item a starved machine lacks: its first recipe ingredient below one
-- craft's need, or a lab's missing pack.
local INPUT_INVENTORY = { furnace = "crafter_input", ["assembling-machine"] = "crafter_input",
  ["rocket-silo"] = "crafter_input", lab = "lab_input" }
local function missing_input(rec)
  local entity = rec.entity
  local inventory_id = INPUT_INVENTORY[rec.type] and defines.inventory[INPUT_INVENTORY[rec.type]]
  local inventory = inventory_id and entity.get_inventory(inventory_id)
  local ingredients
  if rec.type == "lab" then
    local research = entity.force.current_research
    ingredients = research and research.research_unit_ingredients
  else
    local recipe = current_recipe(entity)
    ingredients = recipe and recipe.ingredients
  end
  for _, ingredient in ipairs(ingredients or {}) do
    if ingredient.type == "fluid" then
      local ok, amount = pcall(entity.get_fluid_count, ingredient.name)
      if ok and (amount or 0) < (ingredient.amount or 1) then return ingredient.name, "fluid" end
    elseif inventory and inventory.get_item_count(ingredient.name) < (ingredient.amount or 1) then
      return ingredient.name, "item"
    end
  end
end

-- The item names a machine's recipe (a lab's current research) takes.
local function ingredient_names(rec)
  local entity, names, ingredients = rec.entity, {}, nil
  if rec.type == "lab" then
    local research = entity.force.current_research
    ingredients = research and research.research_unit_ingredients
  elseif CRAFTING_TYPES[rec.type] then
    local recipe = current_recipe(entity)
    ingredients = recipe and recipe.ingredients
  end
  for _, ingredient in ipairs(ingredients or {}) do
    if ingredient.type ~= "fluid" then names[ingredient.name] = true end
  end
  return names
end

-- The other fluid what a box's connections reach holds (fluid_connections
-- target_fluid: a pipe of heavy oil at a crude-oil inlet), else nil.
local function box_meets(entity, index, fluid)
  local ok, connections = pcall(entity.fluidbox.get_pipe_connections, index)
  for _, connection in ipairs(ok and connections or {}) do
    local target = connection.target
    local met = target and fluid_connections.target_fluid(target.owner, connection.target_fluidbox_index)
    if met and met ~= fluid then return met end
  end
end

-- The other fluid the inlet a machine takes this fluid through meets, else
-- nil (box_meets of its first input box filtered to it).
local function fluid_meets(entity, fluid)
  local boxes = entity.fluidbox
  for index = 1, #boxes do
    local filter = boxes.get_filter(index)
    if filter and filter.name == fluid and fluid_connections.live_role(entity, index) ~= "output" then
      return box_meets(entity, index, fluid)
    end
  end
end

-- The fluid a fluid-starved machine lacks: the filter of its first input
-- fluidbox (else of any fluidbox), else "fluid"; then fluid_meets.
local function fluid_cause(entity)
  local boxes = entity.fluidbox
  local first
  for index = 1, #boxes do
    local filter = boxes.get_filter(index)
    if filter then
      first = first or filter.name
      if fluid_connections.live_role(entity, index) ~= "output" then return filter.name, fluid_meets(entity, filter.name) end
    end
  end
  return first or "fluid"
end

-- What a dry machine's feed lacks: any fuel its burner burns.
local FUEL = "fuel"

-- Why a line's worst machine stalls (see the header), or nil, and the item
-- its feeders are read for (read_feed): the item a starved one lacks, FUEL
-- for a dry one.
local function cause_of(rec, state)
  local raw = rec.raw
  if state == "starved" then
    if FLUID_STATUS[raw] then
      local fluid, meets = fluid_cause(rec.entity)
      return fluid, nil, meets
    end
    if raw == "no_spot_seedable_by_inputs" then return "seed" end
    local lack, kind = missing_input(rec)
    if kind == "fluid" then return lack, nil, fluid_meets(rec.entity, lack) end
    return lack, kind == "item" and lack or nil
  elseif state == "no_fuel" then
    return nil, FUEL
  elseif state == "idle" and (raw == "no_recipe" or raw == "recipe_not_researched"
    or raw == "not_connected_to_hub_or_pad") then
    return raw
  elseif state == "idle" and raw == "no_research_in_progress" then
    return "no_research"
  elseif state == "idle" and raw == "waiting_to_launch_rocket" then
    return "rocket_ready"
  elseif state == "output_full" and raw == "full_burnt_result_output" then
    return "burnt_result"
  elseif state == "output_full" and raw == "no_fuel" then
    -- The cause is the full machine's dry outlet inserter (dry_outlet).
    return "outlet_no_fuel"
  elseif state == "depleted" then
    return rec.product or rec.resource
  end
end

-- The dry burner inserter taking from a full machine (its unit), if one
-- still is: a pure Lua check of the mark the inserter's sample left.
local function dry_outlet(a, unit, rec)
  local picker = rec.dry_picker and a.machines[rec.dry_picker]
  if picker and picker.raw == "no_fuel" and picker.pickup_unit == unit then return rec.dry_picker end
  rec.dry_picker = nil
end

-- Feed facts. Once per episode of a starved machine lacking an item or of a
-- dry machine, and again after each line refresh (after a build, at least
-- once a minute: feeders may have changed, and a read an uncharted chunk
-- kept out or that failed is retried), inside the cause refresh and its
-- MAX_CAUSES cap, one bounded query finds the inserters within FEED_MARGIN tiles of its footprint that
-- drop into it (feeders); the first MAX_FEEDERS are read: status, the item
-- in hand (holding) and their pickup target, with the item names on each lane
-- of a belt (lanes; a splitter's lanes are those of the half the inserter
-- picks from) or in another entity's output inventory (items), at most
-- MAX_FEED_NAMES each (omitted_names counts the rest). Facts only, in a
-- charted area: an inserter or pickup in an uncharted chunk is not read. The
-- class says what the read found:
--   inserter_bound  the lacking item (any fuel the burner burns, for a dry
--                   one) is at a feeder's pickup and that feeder is working
--   foreign_item    no pickup has it, and a feeder's pickup holds only items
--                   the machine takes for neither its recipe nor its fuel
--   source_empty    no pickup has it (and none holds only such items)
-- and is absent when the item is at a pickup whose feeder is not working
-- (its status says why), when no feeder's pickup could be read (no pickup
-- entity, or one in an uncharted chunk) or nothing feeds the machine
-- (feeders = 0). Rows
-- show the feeder that decided the class (inserters), to stay small.
-- The search box reaches a long-handed inserter's centre.
local FEED_MARGIN = 2.5
local MAX_FEEDERS, MAX_FEED_NAMES = 4, 3
local BELT_TYPES = { ["transport-belt"] = true, ["underground-belt"] = true, splitter = true,
  loader = true, ["loader-1x1"] = true, ["linked-belt"] = true, ["lane-splitter"] = true }

-- The episode a feed read belongs to: a dry machine's problem episode (it
-- outlasts short refuels, see sample), a starved one's last progress.
local function feed_episode(rec, state)
  if state == "no_fuel" then return rec.problem_since or 0 end
  return rec.productive_tick or 0
end

-- The machine's feed read for this episode and lacking item, or nil.
local function current_feed(rec, state, wanted)
  local feed = rec.feed
  if feed and feed.state == state and feed.episode == feed_episode(rec, state)
    and (wanted == nil or feed.missing == wanted) then return feed end
end

-- Whether the machine's feed is due a read: none for this episode, or one
-- read before the last line refresh (shown until the new read replaces it).
local function feed_due(rec, state, wanted)
  local feed = current_feed(rec, state, wanted)
  return not feed or feed.stale == true
end

local function xy_of(position) return { x = position.x, y = position.y } end

-- The transport lines an inserter picking from this belt entity reads, as
-- {left lane, right lane} each a list of line indexes. A splitter has eight:
-- 1/2 and 5/6 its left half (input and output side), 3/4 and 7/8 its right
-- half; the half is the side of its centre the pickup position lies on.
local function pickup_lines(pickup, at)
  if pickup.type ~= "splitter" then return { { 1 }, { 2 } } end
  local direction, fx, fy = pickup.direction, 0, -1
  if direction == defines.direction.east then fx, fy = 1, 0
  elseif direction == defines.direction.south then fx, fy = 0, 1
  elseif direction == defines.direction.west then fx, fy = -1, 0 end
  local centre = pickup.position
  -- Left of travel is (fy, -fx).
  if at and (at.x - centre.x) * fy - (at.y - centre.y) * fx > 0 then return { { 1, 5 }, { 2, 6 } } end
  return { { 3, 7 }, { 4, 8 } }
end

-- Sorted item names of get_contents rows (of one or more lists), all of
-- them (for the class) and at most MAX_FEED_NAMES shown.
local function content_names(lists, all)
  local names, seen = {}, {}
  for _, contents in ipairs(lists) do
    for _, row in pairs(contents or {}) do
      local name = type(row) == "table" and row.name
      if name and not seen[name] then seen[name] = true; names[#names + 1] = name end
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do all[name] = true end
  local shown = {}
  for i = 1, math.min(#names, MAX_FEED_NAMES) do shown[i] = names[i] end
  return shown, #names - #shown
end

-- One feeder's facts, the item names at its pickup (a set), and whether that
-- pickup was read.
local function feeder_row(inserter, force, surface, platform)
  local row = { position = xy_of(inserter.position), status = status_name(inserter) }
  local held = inserter.held_stack
  if held and held.valid_for_read then row.holding = held.name end
  local names, omitted = {}, 0
  local pickup = inserter.pickup_target
  local at = pickup and pickup.position
  if at and surfaces.charted(force, surface, math.floor(at.x / 32), math.floor(at.y / 32), platform) then
    row.from, row.from_position = pickup.name, xy_of(at)
    if BELT_TYPES[pickup.type] then
      row.lanes = {}
      for lane, indexes in ipairs(pickup_lines(pickup, inserter.pickup_position)) do
        local lists = {}
        for i, index in ipairs(indexes) do lists[i] = pickup.get_transport_line(index).get_contents() end
        local shown, more = content_names(lists, names)
        row.lanes[lane], omitted = shown, omitted + more
      end
    else
      local ok, inventory = pcall(pickup.get_output_inventory)
      if ok and inventory then
        local shown, more = content_names({ inventory.get_contents() }, names)
        row.items, omitted = shown, more
      end
    end
  end
  if omitted > 0 then row.omitted_names = omitted end
  return row, names, row.lanes ~= nil or row.items ~= nil
end

-- Reads a machine's feed (see above) for this episode onto its record.
local function read_feed(rec, state, wanted, tick)
  local entity = rec.entity
  local feed = { state = state, missing = wanted, episode = feed_episode(rec, state), tick = tick }
  rec.feed = feed
  local box = entity.bounding_box
  local area = { left_top = { x = box.left_top.x - FEED_MARGIN, y = box.left_top.y - FEED_MARGIN },
    right_bottom = { x = box.right_bottom.x + FEED_MARGIN, y = box.right_bottom.y + FEED_MARGIN } }
  local surface, force = entity.surface, entity.force
  local platform = surfaces.is_platform(surface)
  if not surfaces.footprint_charted(force, surface, area, platform) then return feed end
  -- What the machine takes: its recipe's items, any fuel its burner burns,
  -- and (a furnace picks its recipe from its input) what it accepts now.
  local takes = ingredient_names(rec)
  local burner = entity.burner
  local categories = burner and burner.fuel_categories or {}
  local function fuel(name)
    local ok, category = pcall(function() return prototypes.item[name].fuel_category end)
    return ok and category ~= nil and categories[category] == true
  end
  local function taken(name)
    if takes[name] == nil then
      takes[name] = fuel(name) or rec.type == "furnace" and entity.can_insert({ name = name, count = 1 }) or false
    end
    return takes[name]
  end
  local rows, feeders = {}, 0
  for _, inserter in ipairs(surface.find_entities_filtered({ area = area, type = { "inserter" }, force = force })) do
    local target = inserter.drop_target
    if target and target.unit_number == rec.unit then
      feeders = feeders + 1
      if feeders <= MAX_FEEDERS then
        local row, names, read = feeder_row(inserter, force, surface, platform)
        local has, only_foreign = false, next(names) ~= nil
        for name in pairs(names) do
          if (wanted == FUEL and fuel(name)) or name == wanted then has = true end
          if taken(name) then only_foreign = false end
        end
        rows[#rows + 1] = { row = row, has = has, foreign = only_foreign, working = row.status == "working", read = read }
      end
    end
  end
  feed.feeders = feeders
  if #rows == 0 then return feed end
  local first
  for _, test in ipairs({
    function(r) return r.has and r.working end, function(r) return r.has end, function(r) return r.foreign end,
    function(r) return r.read end }) do
    for i, r in ipairs(rows) do if not first and test(r) then first = i end end
  end
  -- No pickup read: what is there is not known, so no class.
  local deciding = rows[first or 1]
  if deciding.has then feed.class = deciding.working and "inserter_bound" or nil
  elseif deciding.foreign then feed.class = "foreign_item"
  elseif deciding.read then feed.class = "source_empty" end
  feed.inserters = { deciding.row }
  return feed
end

-- The public facts of a current feed (nil for an uncharted area or a
-- failed read: only a finished read sets feeders).
local function feed_row(feed)
  if not (feed and feed.feeders) then return nil end
  return { class = feed.class, missing = feed.missing, feeders = feed.feeders, inserters = feed.inserters }
end

-- A small table's facts as one string (keys sorted), to tell a changed read.
local function facts_key(value)
  if type(value) ~= "table" then return tostring(value) end
  local parts = {}
  for key, item in pairs(value) do parts[#parts + 1] = tostring(key) .. "=" .. facts_key(item) end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Reads a machine's feed; true when its public facts changed.
local function refeed(rec, state, wanted, tick)
  local before = facts_key(feed_row(current_feed(rec, state, wanted)))
  read_feed(rec, state, wanted, tick)
  return facts_key(feed_row(rec.feed)) ~= before
end

local function evaluate(a, tick)
  local problems = 0
  for _, unit in ipairs(a.problem_only) do
    local rec = a.machines[unit]
    if rec and rec.problem_counted then problems = problems + 1 end
  end
  -- Lines are visited from the cause cursor on, so lines a full evaluate
  -- left without a fresh cause are first in line.
  local order, causes_left, cursor = a.line_order, MAX_CAUSES, nil
  local n = #order
  local start = n > 0 and ((a.cause_cursor or 1) - 1) % n + 1 or 1
  for k = 0, n - 1 do
    local index = (start + k - 1) % n + 1
    local id = order[index]
    local line = a.lines[id]
    local count, productive, worst, worst_rank, worst_unit, temperature = 0, 0, nil, nil, nil, nil
    -- The worst member problem past its threshold, productive or not, and
    -- whether a member is out of fuel or power.
    local degraded, degraded_rank, degraded_unit, dead, worst_outlet = nil, nil, nil, false, nil
    local dry_names, fuel_s = {}, nil
    for _, unit in ipairs(line.machines) do
      local rec = a.machines[unit]
      if rec then
        count = count + 1
        local runway = fuel_seconds(rec)
        if runway and (not fuel_s or runway < fuel_s) then fuel_s = runway end
        -- The first dry machine of each kind (the one its problem row names)
        -- gets its feed read before the problem is announced.
        if rec.raw == "no_fuel" and rec.problem == "no_fuel" and not dry_names[rec.name] then
          dry_names[rec.name] = true
          if feed_due(rec, "no_fuel", FUEL) then
            if causes_left > 0 then
              causes_left = causes_left - 1
              local ok, changed = pcall(refeed, rec, "no_fuel", FUEL, tick)
              if ok and changed then line.changed_tick = tick end
            elseif not cursor then
              cursor = index
            end
          end
        end
        if rec.temperature and (not temperature or rec.temperature < temperature) then temperature = rec.temperature end
        if rec.problem_counted then
          problems = problems + 1
          local class = STATUS_CLASS[rec.problem] or "idle"
          local rank = STATE_RANK[class]
          if not degraded_rank or rank < degraded_rank then
            degraded, degraded_rank = class, rank
            degraded_unit = class == "output_full" and dry_outlet(a, unit, rec) or unit
          end
          if DEAD_CLASSES[class] then dead = true end
        end
        if rec.productive_tick and tick - rec.productive_tick <= PRODUCTIVE_TICKS then
          productive = productive + 1
        else
          local class = STATUS_CLASS[rec.raw] or "idle"
          local rank = STATE_RANK[class]
          local outlet = class == "output_full" and dry_outlet(a, unit, rec) or nil
          -- Among full machines, one whose outlet ran dry names that inserter.
          if not worst_rank or rank < worst_rank or rank == worst_rank and outlet and not worst_outlet then
            worst, worst_rank, worst_unit, worst_outlet = class, rank, outlet or unit, outlet
          end
        end
      end
    end
    -- A line that produces is running; how much is its rate.
    local state = productive > 0 and "running" or worst or "idle"
    if state == "running" then line.running_since = line.running_since or tick else line.running_since = nil end
    local hand_fed = line.last_transfer_tick ~= nil and tick - line.last_transfer_tick < MINUTE_TICKS
    local self_sustaining = line.running_since ~= nil and tick - line.running_since >= MINUTE_TICKS and not hand_fed
      and not dead
    local cause_unit = state ~= "running" and worst_unit or nil
    if state ~= "running" then degraded, degraded_unit = nil, nil end
    if state ~= line.state or hand_fed ~= line.hand_fed or self_sustaining ~= line.self_sustaining
      or cause_unit ~= line.cause_unit or degraded ~= line.degraded or degraded_unit ~= line.degraded_unit then
      line.changed_tick = tick
    end
    line.state, line.hand_fed, line.self_sustaining, line.cause_unit = state, hand_fed, self_sustaining, cause_unit
    line.degraded, line.degraded_unit = degraded, degraded_unit
    line.working, line.temperature, line.fuel_s = productive, temperature, fuel_s
    -- A new line's first 10 s read idle until a second sample shows
    -- progress: they are not counted.
    if tick - line.created_tick >= PRODUCTIVE_TICKS then count_state(line, tick, state) end
    local cause_rec = cause_unit and a.machines[cause_unit]
    if not cause_rec then
      line.cause, line.cause_for, line.cause_raw, line.cause_tick, line.cause_meets = nil, nil, nil, nil, nil
    elseif cause_unit ~= line.cause_for or cause_rec.raw ~= line.cause_raw or tick - line.cause_tick >= CAUSE_TICKS then
      if causes_left > 0 then
        causes_left = causes_left - 1
        local ok, cause, wanted, meets = pcall(cause_of, cause_rec, state)
        cause, meets = ok and cause or nil, ok and meets or nil
        -- Its feeders, once per episode and after a line refresh (in the
        -- same cause unit).
        if ok and wanted and feed_due(cause_rec, state, wanted) then
          local read, changed = pcall(refeed, cause_rec, state, wanted, tick)
          if read and changed then line.changed_tick = tick end
        end
        -- A starved machine whose lack cannot be named (a furnace that never
        -- smelted has no recipe to read) gives the game's own status.
        if not cause and state == "starved" then cause = cause_rec.raw end
        if cause ~= line.cause or meets ~= line.cause_meets then line.changed_tick = tick end
        -- Capped, lines that stalled together are worked out over several
        -- evaluates, so their causes also age out on different ones.
        line.cause, line.cause_for, line.cause_raw, line.cause_tick = cause, cause_unit, cause_rec.raw, tick
        line.cause_meets = meets
      elseif not cursor then
        cursor = index
      end
    end
  end
  if cursor then a.cause_cursor = cursor end
  a.problem_count = problems
end

function M.on_tick(tick)
  local a = data()
  if not a then return end
  local due = not a.refresh_job and registry.ready() and ((a.dirty_tick and tick - a.dirty_tick >= REFRESH_DEBOUNCE_TICKS)
    or not a.last_refresh_tick or tick - a.last_refresh_tick >= REFRESH_SAFETY_TICKS)
  if due or a.refresh_job then
    -- Line tracking is a report: a failed refresh keeps the previous lines,
    -- names its error and never stops the game.
    local ok, err = pcall(function()
      if due then refresh_start(a) end
      if a.refresh_job and refresh_identify(a, REFRESH_PER_TICK) then
        refresh_finish(a)
        a.refresh_error = nil
      end
    end)
    -- A dirty mark set while the job ran is kept (refresh_start cleared
    -- the older one).
    if not ok then
      a.refresh_job, a.refresh_error = nil, tostring(err)
      a.last_refresh_tick = tick
    end
  end
  for _, unit in ipairs(a.buckets[tick % SAMPLE_PERIOD] or {}) do
    local rec = a.machines[unit]
    if rec and not pcall(sample, a, rec, tick) then a.dirty_tick = a.dirty_tick or tick end
  end
  if tick % SAMPLE_PERIOD == SAMPLE_PERIOD - 1 then evaluate(a, tick) end
end

-- The ticks of a line's hand transfers that still count.
local function recent_transfers(line, tick)
  local kept = {}
  for _, at in ipairs(line.hand_transfer_ticks or {}) do
    if tick - at < REPEAT_WINDOW_TICKS then kept[#kept + 1] = at end
  end
  return kept
end

-- The body's anchor surface index (its physical surface, the hub aboard).
local function body_surface() return registry.anchor_index() end

-- Body ticks a line's hand service took in the last 10 minutes.
local MAX_HAND_TIMES = 16
local function hand_ticks(line, tick)
  local kept, total = {}, 0
  for _, row in ipairs(line.hand_times or {}) do
    if tick - row.at < REPEAT_WINDOW_TICKS then kept[#kept + 1] = row; total = total + row.ticks end
  end
  return kept, total
end

-- An insert or extract step at this position on the body's surface took
-- `ticks` of body time (its walk and fetch included).
function M.on_body_time(position, ticks)
  local a = data()
  if not a or type(position) ~= "table" or not (ticks and ticks > 0) then return end
  local unit = a.machine_at and a.machine_at[position_key(body_surface(), position)]
  local rec = unit and a.machines[unit]
  local line = rec and a.lines[rec.line_id]
  if not line then return end
  local kept = hand_ticks(line, game.tick)
  kept[#kept + 1] = { at = game.tick, ticks = ticks }
  while #kept > MAX_HAND_TIMES do table.remove(kept, 1) end
  line.hand_times = kept
end

-- A character transfer into (insert) or out of (extract) the entity at this
-- position on the body's surface. Only an insert feeds the machine; both
-- count as hand transfers.
function M.on_transfer(position, kind)
  local a = data()
  if not a or type(position) ~= "table" then return end
  local key = position_key(body_surface(), position)
  local feeds = kind ~= "extract"
  if feeds then a.transfer_tick[key] = game.tick end
  local unit = a.machine_at and a.machine_at[key]
  local rec = unit and a.machines[unit]
  local line = rec and a.lines[rec.line_id]
  if not line then return end
  if feeds then line.last_transfer_tick = game.tick end
  local ticks = recent_transfers(line, game.tick)
  ticks[#ticks + 1] = game.tick
  while #ticks > MAX_REPEAT_TICKS do table.remove(ticks, 1) end
  line.hand_transfer_ticks = ticks
  if #ticks >= 2 then line.changed_tick = game.tick end
end

local function rate_per_min(line, tick)
  local bin = math.floor(tick / RATE_BIN_TICKS)
  local total = 0
  if line.rate_bin and bin - line.rate_bin < RATE_BINS then
    for b = math.max(line.rate_bin - RATE_BINS + 1, bin - RATE_BINS + 1), line.rate_bin do
      total = total + (line.rate_bins[b % RATE_BINS + 1] or 0)
    end
  end
  -- The bins summed cover from the oldest one's start (or the line's
  -- creation) to now: the newest is still filling.
  local span = math.max(RATE_BIN_TICKS, tick - math.max((bin - RATE_BINS + 1) * RATE_BIN_TICKS, line.created_tick))
  return math.floor(total * 3600 / span * 10 + 0.5) / 10
end

-- A machine's surface index; a record kept from before records had
-- surfaces (until the next refresh) reads its entity's once.
local function rec_surface(rec)
  if rec.surface == nil then
    local ok, index = pcall(function() return rec.entity.surface_index end)
    rec.surface = ok and index or nil
  end
  return rec.surface
end

-- A line's surface index: its own, else (a line kept from before lines had
-- surfaces, until its next refresh) its first machine's.
local function line_surface(a, line)
  if line.surface then return line.surface end
  local rec = a.machines[line.machines[1]]
  return rec and rec_surface(rec)
end

-- Whether a line is on the surface wanted (an index; nil or "all": any).
local function on(a, line, surface)
  return surface == nil or surface == "all" or line_surface(a, line) == surface
end

-- Items a minute one machine makes at full duty from prototypes alone:
-- crafting speed (normal quality) x (1 + built-in and researched recipe
-- productivity, at most the recipe's maximum) / recipe energy x yield, or
-- a drill's mining speed x (1 + the force's mining productivity, for drills
-- that use it) / mining time x yield. Modules, beacons and quality are
-- not counted. nil when unknown (a furnace that never smelted, a fluid, a
-- pumpjack).
local function nameplate(rec, force)
  local proto = prototypes.entity[rec.name]
  if not (proto and rec.yield and rec.yield > 0) then return nil end
  if rec.type == "mining-drill" then
    local time = rec.product and mining_time(rec.product)
    local speed = tonumber(proto.mining_speed)
    if not (time and speed) then return nil end
    local bonus = proto.uses_force_mining_productivity_bonus ~= false
      and tonumber(force and force.mining_drill_productivity_bonus) or 0
    return speed * (1 + bonus) / time * rec.yield * 60
  end
  local recipe = CRAFTING_TYPES[rec.type] and rec.recipe and prototypes.recipe[rec.recipe]
  local energy = recipe and tonumber(recipe.energy)
  local speed = recipe and tonumber(proto.get_crafting_speed())
  if not (energy and energy > 0 and speed) then return nil end
  local effect = proto.effect_receiver and proto.effect_receiver.base_effect
  local researched = force and force.recipes[rec.recipe]
  local productivity = math.min((tonumber(effect and effect.productivity) or 0)
    + (tonumber(researched and researched.productivity_bonus) or 0), tonumber(recipe.maximum_productivity) or math.huge)
  return speed * (1 + productivity) / energy * rec.yield * 60
end

-- What own lines on a surface (default the body's: products elsewhere are
-- not in its reach) make of this item a minute (summed rates), how many
-- lines make it and, when `nameplate_too` and every member's is known,
-- their summed nameplate a minute (see nameplate): one pass over the lines,
-- prototype reads once per machine kind, no entity read.
function M.producing(item, surface, nameplate_too)
  local a = data()
  local rate, count, max = 0, 0, nameplate_too and 0 or nil
  if not a then return rate, count, max end
  surface = surface or body_surface()
  local force = nameplate_too and registry.own_force()
  local per_kind = {}
  for _, id in ipairs(a.line_order) do
    local line = a.lines[id]
    if line.product == item and on(a, line, surface) then
      count = count + 1
      rate = rate + rate_per_min(line, game.tick)
      for _, unit in ipairs(max and line.machines or {}) do
        local rec = a.machines[unit]
        local key = rec and rec.name .. "\0" .. tostring(rec.recipe)
        if key and per_kind[key] == nil then
          local ok, value = pcall(nameplate, rec, force)
          per_kind[key] = ok and value or false
        end
        if not (key and per_kind[key]) then max = nil; break end
        max = max + per_kind[key]
      end
    end
  end
  return rate, count, max and math.floor(max * 10 + 0.5) / 10
end

-- Labs on every surface (research is the force's) whose status lacks
-- science packs and that have not progressed in the last 10 s, with which
-- of `packs` (names) each holds none of: reads each such lab's input
-- inventory, at most `limit` labs. Returns rows {position, surface, lacks =
-- {names}}, the inventory reads made and how many such labs were not read.
function M.labs_lacking(packs, limit)
  local a = data()
  local rows, reads, read_labs, unread = {}, 0, 0, 0
  local by_surface = a and a.waiting and a.waiting.missing_science_packs
  if not by_surface or #packs == 0 then return rows, reads, unread end
  local surfaces_sorted = {}
  for index in pairs(by_surface) do surfaces_sorted[#surfaces_sorted + 1] = index end
  table.sort(surfaces_sorted)
  local input = defines.inventory.lab_input
  for _, index in ipairs(surfaces_sorted) do
    local units = {}
    for unit in pairs(by_surface[index]) do units[#units + 1] = unit end
    table.sort(units)
    for _, unit in ipairs(units) do
      local rec = a.machines[unit]
      if rec and rec.type == "lab" and rec.raw == "missing_science_packs"
        and not (rec.productive_tick and game.tick - rec.productive_tick <= PRODUCTIVE_TICKS) then
        if read_labs >= limit then unread = unread + 1
        else
          read_labs = read_labs + 1
          local ok, lacks = pcall(function()
            local inventory = rec.entity.get_inventory(input)
            local out = {}
            for _, name in ipairs(packs) do
              if not inventory or inventory.get_item_count(name) == 0 then out[#out + 1] = name end
            end
            return out
          end)
          reads = reads + 1 + #packs
          if ok and #lacks > 0 then
            rows[#rows + 1] = { position = { x = rec.position.x, y = rec.position.y }, surface = rec.surface, lacks = lacks }
          end
        end
      end
    end
  end
  return rows, reads, unread
end

-- Whether a power line has a member on this electric network (the
-- registry's network id of each member, kept by its maintenance pass).
local function on_network(line, network)
  for _, unit in ipairs(line.machines) do
    if registry.network_of(unit) == network then return true end
  end
  return false
end

-- The generating lines (product electricity) on one surface with a member
-- on this electric network, as {line, state, position, degraded?, fuel_s?}:
-- the position is that of the member the state or degraded names, else the
-- line's. Lines needing attention first (then by id), at most MAX_SUPPLY,
-- and how many the cap left out; nil without one. Pure Lua over the lines.
function M.supply_states(surface, network)
  local a = data()
  if not (a and network) then return nil end
  local rows = {}
  for _, id in ipairs(a.line_order) do
    local line = a.lines[id]
    if line.product == "electricity" and line_surface(a, line) == surface and on_network(line, network) then
      local unit = line.state == "running" and line.degraded and line.degraded_unit or line.cause_unit
      local member = unit and a.machines[unit]
      rows[#rows + 1] = { line = id, state = line.state, degraded = line.state == "running" and line.degraded or nil,
        position = member and { x = member.position.x, y = member.position.y } or line.position, fuel_s = line.fuel_s,
        _rank = STATE_RANK[line.state] or (line.degraded and #STATE_PRIORITY + 1 or #STATE_PRIORITY + 2) }
    end
  end
  if #rows == 0 then return nil end
  table.sort(rows, function(x, y)
    if x._rank ~= y._rank then return x._rank < y._rank end
    return x.line < y.line
  end)
  local omitted = math.max(0, #rows - MAX_SUPPLY)
  while #rows > MAX_SUPPLY do table.remove(rows) end
  for _, row in ipairs(rows) do row._rank = nil end
  return rows, omitted > 0 and omitted or nil
end

local function round_to(value, places)
  local scale = 10 ^ places
  return math.floor(value * scale + 0.5) / scale
end

-- Public line rows of one surface (an index; nil or "all": every surface),
-- ordered by id.
-- since_tick keeps only lines that changed state, flags, membership or cause
-- since then.
function M.lines(since_tick, surface)
  local a = data()
  local rows = {}
  if not a then return rows end
  -- supply_states once per surface and network, however many rows share it.
  local supply = {}
  for _, id in ipairs(a.line_order) do
    local line = a.lines[id]
    if (not since_tick or line.changed_tick >= since_tick) and on(a, line, surface) then
      local row = { id = id, product = line.product, machines = #line.machines, working = line.working, state = line.state,
        rate_per_min = rate_per_min(line, game.tick), hand_fed = line.hand_fed == true,
        self_sustaining = line.self_sustaining == true, position = line.position }
      local repeats = #recent_transfers(line, game.tick)
      if repeats >= 2 then row.hand_transfers = repeats end
      local _, spent = hand_ticks(line, game.tick)
      if spent >= 600 then row.hand_seconds = math.floor(spent / 60) end
      local rec = line.cause_unit and a.machines[line.cause_unit]
      if rec then
        row.cause_position = { x = rec.position.x, y = rec.position.y }
        row.cause = line.cause
        row.feed = feed_row(current_feed(rec, line.state, line.state == "no_fuel" and FUEL or line.cause))
        row.meets = line.cause_meets
      end
      local member = line.degraded_unit and a.machines[line.degraded_unit]
      if line.state == "running" and line.degraded and member then
        row.degraded = { state = line.degraded, cause_position = { x = member.position.x, y = member.position.y },
          feed = line.degraded == "no_fuel" and feed_row(current_feed(member, "no_fuel", FUEL)) or nil }
      end
      if line.temperature then row.temperature = math.floor(line.temperature * 10 + 0.5) / 10 end
      if line.max_per_min then
        row.max_per_min = round_to(line.max_per_min, 1)
        row.utilisation = round_to(row.rate_per_min / line.max_per_min, 2)
      end
      row.share_10m, row.fuel_s = share_10m(line, game.tick), line.fuel_s
      -- A machine short of power names the generating lines of its network
      -- (none when it is on no network).
      if line.state == "no_power" and rec then
        row.network_id = registry.network_of(line.cause_unit)
        local key = tostring(line_surface(a, line)) .. ":" .. tostring(row.network_id)
        supply[key] = supply[key] or { M.supply_states(line_surface(a, line), row.network_id) }
        row.supply_states, row.supply_omitted = supply[key][1], supply[key][2]
      end
      if not line.product then
        local first = a.machines[line.machines[1]]
        row.entity = first and first.name
      end
      rows[#rows + 1] = row
    end
  end
  return rows
end

-- Machines on one surface (an index; nil or "all": every surface) whose
-- problem status has
-- lasted past its threshold, grouped by status and entity name per line
-- (beacons, roboports and burner inserters, which have no line, after
-- them); since_tick keeps rows that began since.
-- Adds a problem machine to its row (by line, status and entity name).
local function add_problem(rows, by_key, id, rec)
  local key = tostring(id) .. "\0" .. rec.problem .. "\0" .. rec.name
  local row = by_key[key]
  if row then row.count = row.count + 1
  else
    row = { status = rec.problem, name = rec.name, position = { x = rec.position.x, y = rec.position.y },
      count = 1, line = id, cause = PROBLEM_CAUSE[rec.problem],
      feed = rec.problem == "no_fuel" and feed_row(current_feed(rec, "no_fuel", FUEL)) or nil }
    by_key[key] = row
    rows[#rows + 1] = row
  end
end

function M.problems(since_tick, surface)
  local a = data()
  local rows, by_key = {}, {}
  if not a then return rows end
  local function add(id, unit)
    local rec = a.machines[unit]
    if rec and rec.problem_counted and (not since_tick or (rec.problem_announced_tick or rec.problem_since) >= since_tick)
      and (surface == nil or surface == "all" or rec_surface(rec) == surface) then
      add_problem(rows, by_key, id, rec)
    end
  end
  for _, id in ipairs(a.line_order) do
    for _, unit in ipairs(a.lines[id].machines) do add(id, unit) end
  end
  for _, unit in ipairs(a.problem_only) do add(nil, unit) end
  return rows
end

-- Every surface at once, in one pass over the lines and the problem-only
-- machines: {[surface index] = {line_count, running_line_count, problems =
-- rows as M.problems gives them, with the same announcement cursor}}.
function M.by_surface(since_tick)
  local a = data()
  local out, keys = {}, {}
  if not a then return out end
  local function of(surface)
    surface = surface or 0
    local row = out[surface]
    if not row then
      row = { line_count = 0, running_line_count = 0, problems = {} }
      out[surface], keys[surface] = row, {}
    end
    return row, keys[surface]
  end
  local function add(id, unit)
    local rec = a.machines[unit]
    if rec and rec.problem_counted and (not since_tick or (rec.problem_announced_tick or rec.problem_since) >= since_tick) then
      local row, by_key = of(rec_surface(rec))
      add_problem(row.problems, by_key, id, rec)
    end
  end
  for _, id in ipairs(a.line_order) do
    local line = a.lines[id]
    local row = of(line_surface(a, line))
    row.line_count = row.line_count + 1
    if line.state == "running" then row.running_line_count = row.running_line_count + 1 end
    for _, unit in ipairs(line.machines) do add(id, unit) end
  end
  for _, unit in ipairs(a.problem_only) do add(nil, unit) end
  return out
end

-- Labs that progressed in the last 10 s, on every surface (research is the
-- force's): one pass over the lines, no entity read.
function M.labs_working()
  local a = data()
  local working = 0
  for _, id in ipairs(a and a.line_order or {}) do
    local line = a.lines[id]
    if line.product == "research" then working = working + (line.working or 0) end
  end
  return working
end

-- Line counts of one surface (an index), or of every surface when nil.
function M.counts(surface)
  local a = data()
  local counts = { line_count = 0, running_line_count = 0, self_sustaining_line_count = 0, hand_fed_line_count = 0 }
  if not a then return counts end
  for _, id in ipairs(a.line_order) do
    local line = a.lines[id]
    if surface == nil or line_surface(a, line) == surface then
      counts.line_count = counts.line_count + 1
      if line.state == "running" then counts.running_line_count = counts.running_line_count + 1 end
      if line.self_sustaining then counts.self_sustaining_line_count = counts.self_sustaining_line_count + 1 end
      if line.hand_fed then counts.hand_fed_line_count = counts.hand_fed_line_count + 1 end
    end
  end
  return counts
end

return M
