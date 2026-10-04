-- Factory lines: what each group of machines is doing, kept by the mod so no
-- bot has to watch, wait or prove anything.
--
-- A line is the own machines making the same product (same machine class and
-- recipe or mined resource) whose centres lie within LINK_TILES of another
-- member. Topology is refreshed only after something is built, removed or
-- reconfigured (debounced), plus a slow safety cadence for changes that raise
-- no event; it reads the event-maintained registry (registry.lua), never an
-- entity query, and waits until the registry's bootstrap is ready. A bucketed
-- sampler reads each machine (never belts) every SAMPLE_PERIOD ticks through
-- its stored entity reference, so about machines/30 entities are read a tick.
--
-- Per line the mod keeps:
--   state           running (some machine progressed in the last 10 s) |
--                   starved | output_full | no_fuel | no_power | idle (the
--                   worst state among the machines that are not progressing)
--   working         machines that progressed in the last 10 s
--   rate_per_min    products finished over the last minute (items, or crafts)
--   hand_fed        a character transfer into one of its machines in the last 60 s
--   self_sustaining 60 s running with no character transfer and no stall
local companion = require("scripts.companion")
local registry = require("scripts.registry")

local M = {}

local SAMPLE_PERIOD = 30
local REFRESH_DEBOUNCE_TICKS = 300
local REFRESH_SAFETY_TICKS = 3600
local MINUTE_TICKS = 3600
-- A machine that made progress this recently counts as running.
local PRODUCTIVE_TICKS = 600
local RATE_BIN_TICKS, RATE_BINS = 600, 6
local LINK_TILES = 6

local MACHINE_TYPES = registry.MACHINE_TYPES
local CRAFTING_TYPES = { furnace = true, ["assembling-machine"] = true, ["rocket-silo"] = true }
-- Steam power is one line: pumps, boilers and engines feed each other.
local POWER_TYPES = { boiler = true, generator = true, ["burner-generator"] = true, ["offshore-pump"] = true }

-- Raw entity status -> line state class of a machine that is not progressing.
local STATUS_CLASS = {
  no_power = "no_power", low_power = "no_power", not_plugged_in_electric_network = "no_power",
  no_fuel = "no_fuel",
  full_output = "output_full", waiting_for_space_in_destination = "output_full",
  no_ingredients = "starved", item_ingredient_shortage = "starved", fluid_ingredient_shortage = "starved",
  waiting_for_source_items = "starved", missing_science_packs = "starved",
  no_minable_resources = "starved", no_resources = "starved",
}
-- The worst present state names the line when it is not running.
local STATE_PRIORITY = { "no_power", "no_fuel", "output_full", "starved", "idle" }
-- Statuses that are problems once they last this many ticks. Output full
-- is ordinary backpressure for a while; dead machines are not.
local PROBLEM_TICKS = {
  no_power = 60, not_plugged_in_electric_network = 60, no_fuel = 60,
  no_minable_resources = 60, full_output = 600, waiting_for_space_in_destination = 600,
}

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

local function position_key(position)
  return string.format("%.2f,%.2f", position.x, position.y)
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

-- {key, product, yield}: what a machine makes and how many items per cycle.
local function identity(entity)
  if POWER_TYPES[entity.type] then return "power", "electricity", 0 end
  if entity.type == "lab" then return "lab", "research", 0 end
  local product, yield
  if entity.type == "mining-drill" then
    local ok, target = pcall(function() return entity.mining_target end)
    local mineable = ok and target and target.prototype.mineable_properties
    local first = mineable and mineable.products and mineable.products[1]
    if first then product, yield = first.name, tonumber(first.amount) or 1 end
  else
    local ok, recipe = pcall(current_recipe, entity)
    local first = ok and recipe and recipe.products and recipe.products[1]
    if first then product, yield = first.name, tonumber(first.amount) or 1 end
  end
  if not product then return entity.type .. ":" .. entity.name, nil, 0 end
  return entity.type .. ":" .. product, product, yield
end

function M.mark_dirty()
  local a = data()
  if a and not a.dirty_tick then a.dirty_tick = game.tick end
end

-- Build/remove events: only machines change lines.
function M.on_entity_changed(event)
  local entity = event and (event.entity or event.created_entity)
  local ok, kind = pcall(function() return entity and entity.valid and entity.type end)
  if ok and kind and MACHINE_TYPES[kind] then M.mark_dirty() end
end

local function new_line(a, key, product)
  local id = a.next_line_id
  a.next_line_id = id + 1
  return { id = id, key = key, product = product, created_tick = game.tick, changed_tick = game.tick,
    state = "idle", rate_bins = {}, rate_bin = nil }
end

function M.refresh()
  local a = data()
  local c = companion.get()
  a.dirty_tick, a.last_refresh_tick = nil, game.tick
  -- Without the body there is no force to read: try again shortly.
  if not c then a.dirty_tick = game.tick; return end
  local old_machines, old_lines = a.machines, a.lines
  local machines, list, machine_at = {}, {}, {}
  -- Own machines in charted chunks, valid, ordered by unit number.
  for _, entry in ipairs(registry.machines()) do
    local entity, unit = entry.entity, entry.unit
    local rec = old_machines[unit] or { unit = unit }
    rec.entity, rec.name, rec.type = entity, entry.name, entry.type
    rec.position = { x = entry.position.x, y = entry.position.y }
    local ok, key, product, yield = pcall(identity, entity)
    if ok then rec.key, rec.product, rec.yield = key, product, yield
    else rec.key, rec.product, rec.yield = entry.type .. ":" .. entry.name, nil, 0 end
    machines[unit] = rec
    list[#list + 1] = rec
    machine_at[position_key(rec.position)] = unit
  end
  -- Same product and within LINK_TILES (Chebyshev) of a member: one line.
  local parent, cells = {}, {}
  local function root(unit)
    while parent[unit] ~= unit do parent[unit] = parent[parent[unit]]; unit = parent[unit] end
    return unit
  end
  for _, rec in ipairs(list) do
    parent[rec.unit] = rec.unit
    local cx, cy = math.floor(rec.position.x / LINK_TILES), math.floor(rec.position.y / LINK_TILES)
    for dy = -1, 1 do for dx = -1, 1 do
      for _, other in ipairs(cells[(cx + dx) .. "," .. (cy + dy)] or {}) do
        if other.key == rec.key and math.abs(other.position.x - rec.position.x) <= LINK_TILES
          and math.abs(other.position.y - rec.position.y) <= LINK_TILES then
          local ra, rb = root(other.unit), root(rec.unit)
          if ra ~= rb then parent[math.max(ra, rb)] = math.min(ra, rb) end
        end
      end
    end end
    local cell = cx .. "," .. cy
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
  -- so state and rate survive builds next to it.
  local lines, order, taken = {}, {}, {}
  for _, r in ipairs(group_order) do
    local members, votes, best = groups[r], {}, nil
    for _, rec in ipairs(members) do
      local id = rec.line_id
      if id and old_lines[id] and old_lines[id].key == rec.key and not taken[id] then votes[id] = (votes[id] or 0) + 1 end
    end
    for id, count in pairs(votes) do
      if not best or count > votes[best] or count == votes[best] and id < best then best = id end
    end
    local line = best and old_lines[best] or new_line(a, members[1].key, members[1].product)
    taken[line.id] = true
    local units, sx, sy, last_transfer = {}, 0, 0, nil
    for _, rec in ipairs(members) do
      rec.line_id = line.id
      units[#units + 1] = rec.unit
      sx, sy = sx + rec.position.x, sy + rec.position.y
      local transfer = a.transfer_tick[position_key(rec.position)]
      if transfer and (not last_transfer or transfer > last_transfer) then last_transfer = transfer end
    end
    if #units ~= #(line.machines or {}) then line.changed_tick = game.tick end
    line.machines, line.product = units, members[1].product
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
  for _, rec in ipairs(list) do
    local bucket = rec.unit % SAMPLE_PERIOD
    buckets[bucket] = buckets[bucket] or {}
    table.insert(buckets[bucket], rec.unit)
  end
  for key, tick in pairs(a.transfer_tick) do
    if game.tick - tick > MINUTE_TICKS then a.transfer_tick[key] = nil end
  end
  a.machines, a.lines, a.line_order, a.buckets, a.machine_at = machines, lines, order, buckets, machine_at
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

local function sample(a, rec, tick)
  local entity = rec.entity
  if not (entity and entity.valid) then a.dirty_tick = a.dirty_tick or tick; return end
  local raw = status_name(entity)
  local progressed, produced = raw == "working", 0
  if rec.type == "mining-drill" then
    local progress = entity.mining_progress
    if rec.progress and progress ~= rec.progress then
      progressed = true
      if progress < rec.progress then produced = 1 end
    end
    rec.progress = progress
  elseif CRAFTING_TYPES[rec.type] then
    local finished = entity.products_finished
    if rec.finished and finished > rec.finished then progressed, produced = true, finished - rec.finished end
    rec.finished = finished
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
  rec.raw = raw
  if PROBLEM_TICKS[raw] then
    -- The same problem returning inside the recovery window is the old
    -- episode: it keeps its start and is not announced again.
    rec.clear_since = nil
    if rec.problem ~= raw then rec.problem, rec.problem_since, rec.problem_counted = raw, tick, nil end
    if not rec.problem_counted and tick - rec.problem_since >= PROBLEM_TICKS[raw] then
      rec.problem_counted = true
      a.last_problem_tick = tick
    end
  elseif rec.problem then
    -- Hysteresis: a problem clears only after PRODUCTIVE_TICKS without it,
    -- so backpressure that flaps with short working bursts is one problem.
    rec.clear_since = rec.clear_since or tick
    if tick - rec.clear_since >= PRODUCTIVE_TICKS then
      rec.problem, rec.problem_since, rec.problem_counted, rec.clear_since = nil, nil, nil, nil
    end
  end
end

local function evaluate(a, tick)
  local problems = 0
  for _, id in ipairs(a.line_order) do
    local line = a.lines[id]
    local count, productive, worst, worst_rank, worst_unit = 0, 0, nil, nil, nil
    for _, unit in ipairs(line.machines) do
      local rec = a.machines[unit]
      if rec then
        count = count + 1
        if rec.problem_counted then problems = problems + 1 end
        if rec.productive_tick and tick - rec.productive_tick <= PRODUCTIVE_TICKS then
          productive = productive + 1
        else
          local class = STATUS_CLASS[rec.raw] or "idle"
          for rank, name in ipairs(STATE_PRIORITY) do
            if name == class and (not worst_rank or rank < worst_rank) then worst, worst_rank, worst_unit = class, rank, unit end
          end
        end
      end
    end
    -- A line that produces is running; how much is its rate.
    local state = productive > 0 and "running" or worst or "idle"
    if state == "running" then line.running_since = line.running_since or tick else line.running_since = nil end
    local hand_fed = line.last_transfer_tick ~= nil and tick - line.last_transfer_tick < MINUTE_TICKS
    local self_sustaining = line.running_since ~= nil and tick - line.running_since >= MINUTE_TICKS and not hand_fed
    local cause_unit = state ~= "running" and worst_unit or nil
    if state ~= line.state or hand_fed ~= line.hand_fed or self_sustaining ~= line.self_sustaining
      or cause_unit ~= line.cause_unit then
      line.changed_tick = tick
    end
    line.state, line.hand_fed, line.self_sustaining, line.cause_unit = state, hand_fed, self_sustaining, cause_unit
    line.working = productive
  end
  a.problem_count = problems
end

function M.on_tick(tick)
  local a = data()
  if not a then return end
  if registry.ready() and ((a.dirty_tick and tick - a.dirty_tick >= REFRESH_DEBOUNCE_TICKS)
    or not a.last_refresh_tick or tick - a.last_refresh_tick >= REFRESH_SAFETY_TICKS) then
    -- Line tracking is a report: a failed refresh keeps the previous lines,
    -- names its error and never stops the game.
    local ok, err = pcall(M.refresh)
    a.refresh_error = not ok and tostring(err) or nil
    if not ok then a.dirty_tick, a.last_refresh_tick = nil, tick end
  end
  for _, unit in ipairs(a.buckets[tick % SAMPLE_PERIOD] or {}) do
    local rec = a.machines[unit]
    if rec and not pcall(sample, a, rec, tick) then a.dirty_tick = a.dirty_tick or tick end
  end
  if tick % SAMPLE_PERIOD == SAMPLE_PERIOD - 1 then evaluate(a, tick) end
end

-- A character transfer into the entity at this position.
function M.on_transfer(position)
  local a = data()
  if not a or type(position) ~= "table" then return end
  local key = position_key(position)
  a.transfer_tick[key] = game.tick
  local unit = a.machine_at and a.machine_at[key]
  local rec = unit and a.machines[unit]
  local line = rec and a.lines[rec.line_id]
  if line then line.last_transfer_tick = game.tick end
end

-- The item a starved machine lacks: its first recipe ingredient below one
-- craft's need, a lab's missing pack, or the resource a drill ran out of.
local INPUT_INVENTORY = { furnace = "furnace_source", ["assembling-machine"] = "assembling_machine_input",
  ["rocket-silo"] = "assembling_machine_input", lab = "lab_input" }
local function missing_input(rec)
  local entity = rec.entity
  if rec.raw == "no_minable_resources" or rec.raw == "no_resources" then return rec.product end
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
      if ok and (amount or 0) < (ingredient.amount or 1) then return ingredient.name end
    elseif inventory and inventory.get_item_count(ingredient.name) < (ingredient.amount or 1) then
      return ingredient.name
    end
  end
end

local function rate_per_min(line, tick)
  local bin = math.floor(tick / RATE_BIN_TICKS)
  local total = 0
  if line.rate_bin and bin - line.rate_bin < RATE_BINS then
    for b = math.max(line.rate_bin - RATE_BINS + 1, bin - RATE_BINS + 1), line.rate_bin do
      total = total + (line.rate_bins[b % RATE_BINS + 1] or 0)
    end
  end
  local span = math.max(RATE_BIN_TICKS, math.min(RATE_BIN_TICKS * RATE_BINS, tick - line.created_tick))
  return math.floor(total * 3600 / span * 10 + 0.5) / 10
end

-- Public line rows, ordered by id. since_tick keeps only lines that changed
-- state, flags, membership or cause since then.
function M.lines(since_tick)
  local a = data()
  local rows = {}
  if not a then return rows end
  for _, id in ipairs(a.line_order) do
    local line = a.lines[id]
    if not since_tick or line.changed_tick >= since_tick then
      local row = { id = id, product = line.product, machines = #line.machines, working = line.working, state = line.state,
        rate_per_min = rate_per_min(line, game.tick), hand_fed = line.hand_fed == true,
        self_sustaining = line.self_sustaining == true, position = line.position }
      local rec = line.cause_unit and a.machines[line.cause_unit]
      if rec and rec.entity and rec.entity.valid then
        row.cause_position = { x = rec.position.x, y = rec.position.y }
        if line.state == "starved" then
          local ok, item = pcall(missing_input, rec)
          if ok then row.cause = item end
        end
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

-- Machines whose problem status has lasted past its threshold, grouped by
-- status and entity name per line; since_tick keeps rows that began since.
function M.problems(since_tick)
  local a = data()
  local rows, by_key = {}, {}
  if not a then return rows end
  for _, id in ipairs(a.line_order) do
    for _, unit in ipairs(a.lines[id].machines) do
      local rec = a.machines[unit]
      if rec and rec.problem_counted and (not since_tick or rec.problem_since >= since_tick) then
        local key = id .. "\0" .. rec.problem .. "\0" .. rec.name
        local row = by_key[key]
        if row then row.count = row.count + 1
        else
          row = { status = rec.problem, name = rec.name, position = { x = rec.position.x, y = rec.position.y },
            count = 1, line = id }
          by_key[key] = row
          rows[#rows + 1] = row
        end
      end
    end
  end
  return rows
end

function M.counts()
  local a = data()
  local counts = { line_count = 0, running_line_count = 0, self_sustaining_line_count = 0, hand_fed_line_count = 0 }
  if not a then return counts end
  for _, id in ipairs(a.line_order) do
    local line = a.lines[id]
    counts.line_count = counts.line_count + 1
    if line.state == "running" then counts.running_line_count = counts.running_line_count + 1 end
    if line.self_sustaining then counts.self_sustaining_line_count = counts.self_sustaining_line_count + 1 end
    if line.hand_fed then counts.hand_fed_line_count = counts.hand_fed_line_count + 1 end
  end
  return counts
end

return M
