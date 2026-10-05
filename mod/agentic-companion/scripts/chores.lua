-- Chores the mod does without any bot:
-- * Upkeep: while the FIFO is empty (and not after an emergency stop) and
--   The owner is not holding the body, the body refuels own burner machines that
--   ran dry and brings the current research's science packs to own labs
--   that lack them, from what it carries or own stock (insert's auto-supply
--   walks to it). It is an ordinary plan with source "upkeep", so
--   activity_log shows it and any queued plan takes the body at the next
--   step boundary.
-- * Charting: every minute the force charts the chunks around the body that
--   it has not charted yet, so patches and water appear without scouting.
-- All state lives in storage.chores (created by state.init on load or upgrade).
local companion = require("scripts.companion")
local tasks = require("scripts.tasks")
local registry = require("scripts.registry")
local supply = require("scripts.actions.supply")
local explore = require("scripts.actions.explore")
local jobs = require("scripts.jobs")

local M = {}

local UPKEEP_PERIOD = 300
local CHART_PERIOD = 3600
local CHART_RADIUS_CHUNKS = 5        -- 11 x 11 chunks: about 350 tiles across
local REFUEL_COOLDOWN_TICKS = 3600   -- one refuel attempt per machine a minute
local MAX_REFUELS = 8
local FUEL_PER_MACHINE = 10
local MAX_LABS = 8
local PACKS_PER_LAB = 10
-- Machines one upkeep pass looks at per status: the line sampler keeps the
-- units in each chore status, so a pass never walks every machine.
local MAX_CANDIDATES = 64

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

-- Own machines in a raw sampler state (of one type when given), not served
-- within the cooldown, nearest first, at most `limit`: from the sampler's
-- set of that state, at most MAX_CANDIDATES of them looked at.
local function machines_in(c, tick, raw, kind, served, limit)
  local a = storage.autonomy
  local rows, seen = {}, 0
  local function nearer(x, y)
    if x.distance ~= y.distance then return x.distance < y.distance end
    return x.unit < y.unit
  end
  for unit in pairs(a and a.waiting and a.waiting[raw] or {}) do
    if seen >= MAX_CANDIDATES then break end
    local rec = a.machines[unit]
    if rec and rec.raw == raw and (kind == nil or rec.type == kind)
      and not (served[unit] and tick - served[unit] < REFUEL_COOLDOWN_TICKS) then
      seen = seen + 1
      if rec.entity and rec.entity.valid then
        local dx, dy = rec.position.x - c.position.x, rec.position.y - c.position.y
        jobs.keep_first(rows, limit, { unit = unit, position = rec.position, distance = dx * dx + dy * dy }, nearer)
      end
    end
  end
  table.sort(rows, nearer)
  return rows
end

-- Insert steps that refuel own burner machines out of fuel.
local function refuel_steps(c, tick, steps)
  local machines = machines_in(c, tick, "no_fuel", nil, storage.chores.refueled, MAX_REFUELS)
  if #machines == 0 then return end
  local name, available = supply.fuel_item(c)
  if not name then return end
  local each = math.min(FUEL_PER_MACHINE, math.floor(available / #machines))
  while each < 1 and #machines > 1 do
    table.remove(machines)
    each = math.min(FUEL_PER_MACHINE, math.floor(available / #machines))
  end
  if each < 1 then return end
  for _, machine in ipairs(machines) do
    steps[#steps + 1] = { action = "insert_items", x = machine.position.x, y = machine.position.y, items = { [name] = each } }
    storage.chores.refueled[machine.unit] = tick
  end
end

-- Insert steps that bring the current research's packs, from what the body
-- carries or own stock holds (one registry pass), to labs missing them.
local function lab_steps(c, tick, steps)
  local labs = machines_in(c, tick, "missing_science_packs", "lab", storage.chores.fed_labs, MAX_LABS)
  if #labs == 0 then return end
  local research = c.force.current_research
  if not research then return end
  local names = {}
  for _, ingredient in ipairs(research.research_unit_ingredients or {}) do
    if ingredient.type ~= "fluid" then names[#names + 1] = ingredient.name end
  end
  if #names == 0 then return end
  local stored = registry.stock_totals(names)
  local items, any = {}, false
  for _, name in ipairs(names) do
    local each = math.min(PACKS_PER_LAB, math.floor((c.get_item_count(name) + (stored[name] or 0)) / #labs))
    if each >= 1 then items[name], any = each, true end
  end
  if not any then return end
  for _, lab in ipairs(labs) do
    steps[#steps + 1] = { action = "insert_items", x = lab.position.x, y = lab.position.y, items = items }
    storage.chores.fed_labs[lab.unit] = tick
  end
end

function M.upkeep(tick)
  local c = companion.get()
  if not (c and c.valid and storage.chores) or not fifo_empty() or held() then return end
  for _, served in ipairs({ storage.chores.refueled, storage.chores.fed_labs }) do
    for unit, at in pairs(served) do
      if tick - at >= REFUEL_COOLDOWN_TICKS then served[unit] = nil end
    end
  end
  local steps = {}
  refuel_steps(c, tick, steps)
  lab_steps(c, tick, steps)
  if #steps > 0 then pcall(tasks.queue_plan, { steps = steps, source = "upkeep" }) end
end

-- Chart the uncharted chunks around the body; charted ones are left alone.
function M.chart(_)
  local c = companion.get()
  if not (c and c.valid) then return end
  explore.chart_around(c, CHART_RADIUS_CHUNKS)
end

M.on_nth = {
  -- A chore that fails is skipped; it never stops the game.
  [UPKEEP_PERIOD] = function(event) pcall(M.upkeep, event.tick) end,
  [CHART_PERIOD] = function(event) pcall(M.chart, event.tick) end,
}

return M
