-- Chores the mod does without any bot:
-- * Upkeep: while the FIFO is empty (and not after an emergency stop), the owner
--   is not holding the body and the body stands on a surface (nothing aboard
--   or in transit), the body refuels own burner machines on its surface that
--   ran dry, with a fuel their burner takes (by fuel category: biochambers
--   nutrients, heating towers chemical fuel), and brings the current
--   research's science packs to own labs on its surface that take them, from
--   what it carries or own stock (insert's auto-supply walks to it). A lab
--   gets only the packs it accepts and has room for; one that would take
--   nothing is skipped, and the same lab and pack are never tried again
--   within LAB_RETRY_TICKS. With no research active no lab is fed. It is an
--   ordinary plan with source "upkeep", so activity_log shows it and any
--   queued plan takes the body at the next step boundary.
-- * Charting: every minute the force charts the chunks around the body that
--   it has not charted yet, on planet surfaces only, and once when the body
--   arrives on a planet, so patches and water appear without scouting.
-- All state lives in storage.chores (created by state.init on load or upgrade).
local companion = require("scripts.companion")
local tasks = require("scripts.tasks")
local registry = require("scripts.registry")
local explore = require("scripts.actions.explore")
local supply = require("scripts.actions.supply")

local M = {}

local UPKEEP_PERIOD = 300
local CHART_PERIOD = 3600
local CHART_RADIUS_CHUNKS = 5        -- 11 x 11 chunks: about 350 tiles across
local REFUEL_COOLDOWN_TICKS = 3600   -- one refuel attempt per machine a minute
M.LAB_RETRY_TICKS = 600              -- one try per lab and pack in ten seconds
local MAX_REFUELS = 8
local FUEL_PER_MACHINE = 10
local MAX_LABS = 8
local PACKS_PER_LAB = 10
-- Machines one upkeep pass looks at per status: the line sampler keeps the
-- units in each chore status, so a pass never walks every machine.
local MAX_CANDIDATES = 64

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

local function held()
  local ok, value = pcall(companion.human_control)
  return ok and value == true
end

-- Empty, and some plan has finished since load or the last emergency stop
-- (cancel all clears last_finished_tick): a stop is never undone by upkeep.
local function fifo_empty()
  local t = storage.tasks
  return t and not t.active and #t.queue == 0 and t.last_finished_tick ~= nil
end

-- Own machines on the body's surface in a raw sampler state (of one type
-- when given), not skipped by `skip(unit)` (a pure Lua test), nearest
-- first: from the sampler's set of that state on that surface, at most
-- MAX_CANDIDATES of them looked at (machines elsewhere are never counted).
local function machines_in(c, raw, kind, skip)
  local a = storage.autonomy
  local rows, seen = {}, 0
  local function nearer(x, y)
    if x.distance ~= y.distance then return x.distance < y.distance end
    return x.unit < y.unit
  end
  local by_surface = a and a.waiting and a.waiting[raw]
  for unit in pairs(by_surface and by_surface[c.surface_index] or {}) do
    if seen >= MAX_CANDIDATES then break end
    local rec = a.machines[unit]
    if rec and rec.raw == raw and (kind == nil or rec.type == kind) and not (skip and skip(unit)) then
      seen = seen + 1
      local entity = rec.entity
      if entity and entity.valid then
        local dx, dy = rec.position.x - c.position.x, rec.position.y - c.position.y
        rows[#rows + 1] = { unit = unit, position = rec.position, entity = entity, distance = dx * dx + dy * dy }
      end
    end
  end
  table.sort(rows, nearer)
  return rows
end

-- Fuel items by fuel category, from the engine's item filter, worked out
-- once per category (prototypes change only with a configuration change).
local fuels_cache = {}
local function fuels_of(category)
  local names = fuels_cache[category]
  if not names then
    names = {}
    for name in pairs(prototypes.get_item_filtered({ { filter = "fuel-category", ["fuel-category"] = category } })) do
      names[#names + 1] = name
    end
    table.sort(names)
    fuels_cache[category] = names
  end
  return names
end

-- The fuel for a machine's burner, carried or in own stock on the body's
-- surface (one registry pass per burner kind), and how much in all; nil
-- when there is none. The body's own fuel order comes first (coal, wood,
-- solid fuel: never rocket or nuclear fuel while one of those is at hand);
-- a burner that takes none of them (nutrients, ...) gets what the body has
-- most of. `known` keeps each answer for the pass, by category list.
local function fuel_for(c, entity, known)
  local categories = {}
  for category in pairs(read(function() return entity.burner.fuel_categories end) or {}) do
    categories[#categories + 1] = category
  end
  table.sort(categories)
  local key = table.concat(categories, ",")
  if known[key] == nil then
    local names = {}
    for _, category in ipairs(categories) do
      for _, name in ipairs(fuels_of(category)) do names[#names + 1] = name end
    end
    local stored = #names > 0 and registry.stock_totals(names) or {}
    local totals = {}
    for _, name in ipairs(names) do totals[name] = c.get_item_count(name) + (stored[name] or 0) end
    local best, most = false, 0
    for _, name in ipairs(supply.FUELS) do
      if (totals[name] or 0) > 0 then best, most = name, totals[name]; break end
    end
    if not best then
      for _, name in ipairs(names) do
        if totals[name] > most then best, most = name, totals[name] end
      end
    end
    known[key] = best and { name = best, available = most } or false
  end
  return known[key] or nil
end

-- Insert steps that refuel own burner machines out of fuel: the machines
-- sharing a fuel share what there is of it.
local function refuel_steps(c, tick, steps)
  local refueled = storage.chores.refueled
  local machines = machines_in(c, "no_fuel", nil, function(unit)
    return refueled[unit] ~= nil and tick - refueled[unit] < REFUEL_COOLDOWN_TICKS
  end)
  while #machines > MAX_REFUELS do table.remove(machines) end
  if #machines == 0 then return end
  local known, groups, order = {}, {}, {}
  for _, machine in ipairs(machines) do
    local fuel = fuel_for(c, machine.entity, known)
    if fuel then
      local group = groups[fuel.name]
      if not group then
        group = { fuel = fuel, machines = {} }
        groups[fuel.name], order[#order + 1] = group, fuel.name
      end
      group.machines[#group.machines + 1] = machine
    end
  end
  for _, name in ipairs(order) do
    local group = groups[name]
    local list, available = group.machines, group.fuel.available
    local each = math.min(FUEL_PER_MACHINE, math.floor(available / #list))
    while each < 1 and #list > 1 do
      table.remove(list)
      each = math.min(FUEL_PER_MACHINE, math.floor(available / #list))
    end
    if each >= 1 then
      for _, machine in ipairs(list) do
        steps[#steps + 1] = { action = "insert_items", x = machine.position.x, y = machine.position.y, items = { [name] = each } }
        storage.chores.refueled[machine.unit] = tick
      end
    end
  end
  table.sort(steps, function(a, b)
    local da = (a.x - c.position.x) ^ 2 + (a.y - c.position.y) ^ 2
    local db = (b.x - c.position.x) ^ 2 + (b.y - c.position.y) ^ 2
    if da ~= db then return da < db end
    return a.y == b.y and a.x < b.x or a.y < b.y
  end)
end

local function lab_key(unit, pack) return unit .. ":" .. pack end

-- How many of a pack the lab takes now: it must be one of the lab's inputs
-- and fit its input inventory (the lab's own answer).
local function lab_room(entity, pack)
  local accepts = false
  for _, input in ipairs(read(function() return entity.prototype.lab_inputs end) or {}) do
    if input == pack then accepts = true end
  end
  if not accepts then return 0 end
  local inventory = read(function() return entity.get_inventory(defines.inventory.lab_input) end)
  if not inventory then return 0 end
  local item = { name = pack, quality = "normal" }
  if not read(function() return inventory.can_insert(item) end) then return 0 end
  return read(function() return inventory.get_insertable_count(item) end) or 0
end

-- Insert steps that bring the current research's packs, from what the body
-- carries or own stock holds (one registry pass), to labs on its surface
-- that take them: the nearest labs that would take some pack not tried
-- within LAB_RETRY_TICKS, at most MAX_LABS. A pack short for every lab that
-- takes it goes to the nearest ones first (as fuel does).
local function lab_steps(c, tick, steps)
  local research = c.force.current_research
  if not research then return end
  local names = {}
  for _, ingredient in ipairs(research.research_unit_ingredients or {}) do
    if ingredient.type ~= "fluid" then names[#names + 1] = ingredient.name end
  end
  if #names == 0 then return end
  local fed = storage.chores.fed_labs
  local function tried(unit, name)
    local at = fed[lab_key(unit, name)]
    return at ~= nil and tick - at < M.LAB_RETRY_TICKS
  end
  -- A lab with every pack tried lately is left out before the nearest are
  -- taken, so labs further away get their turn.
  local candidates = machines_in(c, "missing_science_packs", "lab", function(unit)
    for _, name in ipairs(names) do if not tried(unit, name) then return false end end
    return true
  end)
  -- The lab's own answer, nearest first, until MAX_LABS labs take something.
  local labs, takers = {}, {}
  for _, lab in ipairs(candidates) do
    if #labs >= MAX_LABS then break end
    local rooms, any = {}, false
    for _, name in ipairs(names) do
      local room = not tried(lab.unit, name) and lab_room(lab.entity, name) or 0
      if room > 0 then
        rooms[name], any = room, true
        takers[name] = takers[name] or {}
        table.insert(takers[name], #labs + 1)
      end
    end
    if any then labs[#labs + 1] = { lab = lab, rooms = rooms, items = {} } end
  end
  if #labs == 0 then return end
  local stored = registry.stock_totals(names)
  for _, name in ipairs(names) do
    local list = takers[name]
    local available = list and c.get_item_count(name) + (stored[name] or 0) or 0
    local kept = list and math.min(#list, available) or 0
    for i = 1, kept do
      local row = labs[list[i]]
      row.items[name] = math.min(PACKS_PER_LAB, row.rooms[name], math.max(1, math.floor(available / kept)))
      fed[lab_key(row.lab.unit, name)] = tick
    end
  end
  for _, row in ipairs(labs) do
    if next(row.items) then
      steps[#steps + 1] = { action = "insert_items", x = row.lab.position.x, y = row.lab.position.y, items = row.items }
    end
  end
end

function M.upkeep(tick)
  local c = companion.get()
  if not (c and c.valid and storage.chores) or not fifo_empty() or held() then return end
  for unit, at in pairs(storage.chores.refueled) do
    if tick - at >= REFUEL_COOLDOWN_TICKS then storage.chores.refueled[unit] = nil end
  end
  for key, at in pairs(storage.chores.fed_labs) do
    if tick - at >= M.LAB_RETRY_TICKS then storage.chores.fed_labs[key] = nil end
  end
  local steps = {}
  refuel_steps(c, tick, steps)
  lab_steps(c, tick, steps)
  if #steps > 0 then pcall(tasks.queue_plan, { steps = steps, source = "upkeep" }) end
end

-- Chart the uncharted chunks around the body, on a planet's surface only;
-- charted ones are left alone.
function M.chart(_)
  local c = companion.get()
  if not (c and c.valid) then return end
  local surface = c.surface
  if read(function() return surface.platform == nil and surface.planet ~= nil end) ~= true then return end
  explore.chart_around(c, CHART_RADIUS_CHUNKS)
end

-- The body arrived on another surface: chart around it at once.
function M.on_arrival(change)
  if change and change.state == "on_surface" then pcall(M.chart, game.tick) end
end

M.on_nth = {
  -- A chore that fails is skipped; it never stops the game.
  [UPKEEP_PERIOD] = function(event) pcall(M.upkeep, event.tick) end,
  [CHART_PERIOD] = function(event) pcall(M.chart, event.tick) end,
}

return M
