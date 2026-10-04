-- Chores the mod does without any bot:
-- * Upkeep: while the FIFO is empty (and not after an emergency stop) and
--   The owner is not holding the body, the body refuels own burner machines that
--   ran dry, from carried fuel or own stock (insert's auto-supply walks to it). It is an ordinary plan with
--   source "upkeep", so activity_log shows it and any queued plan takes the
--   body at the next step boundary.
-- * Charting: every minute the force charts the chunks around the body that
--   it has not charted yet, so patches and water appear without scouting.
-- All state lives in storage.chores (created by state.init on load or upgrade).
local companion = require("scripts.companion")
local tasks = require("scripts.tasks")
local registry = require("scripts.registry")

local M = {}

local UPKEEP_PERIOD = 300
local CHART_PERIOD = 3600
local CHART_RADIUS_CHUNKS = 5        -- 11 x 11 chunks: about 350 tiles across
local REFUEL_COOLDOWN_TICKS = 3600   -- one refuel attempt per machine a minute
local MAX_REFUELS = 8
local FUEL_PER_MACHINE = 10
local FUELS = { "coal", "wood", "solid-fuel" }

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

-- Own burner machines out of fuel, from the factory lines' sampler.
local function dry_machines(c, tick)
  local a, refueled = storage.autonomy, storage.chores.refueled
  local rows = {}
  for unit, rec in pairs(a and a.machines or {}) do
    if rec.raw == "no_fuel" and rec.entity and rec.entity.valid
      and not (refueled[unit] and tick - refueled[unit] < REFUEL_COOLDOWN_TICKS) then
      local dx, dy = rec.position.x - c.position.x, rec.position.y - c.position.y
      rows[#rows + 1] = { unit = unit, position = rec.position, distance = dx * dx + dy * dy }
    end
  end
  table.sort(rows, function(x, y)
    if x.distance ~= y.distance then return x.distance < y.distance end
    return x.unit < y.unit
  end)
  while #rows > MAX_REFUELS do table.remove(rows) end
  return rows
end

-- The first fuel the body carries or the force stores (chests and machine
-- outputs, one pass over the registry's holders), and how much.
local function fuel(c)
  local names = {}
  for _, name in ipairs(FUELS) do if prototypes.item[name] then names[#names + 1] = name end end
  local stored = registry.stock_totals(names)
  for _, name in ipairs(names) do
    local total = c.get_item_count(name) + (stored[name] or 0)
    if total > 0 then return name, total end
  end
end

function M.upkeep(tick)
  local c = companion.get()
  if not (c and c.valid and storage.chores) or not fifo_empty() or held() then return end
  for unit, at in pairs(storage.chores.refueled) do
    if tick - at >= REFUEL_COOLDOWN_TICKS then storage.chores.refueled[unit] = nil end
  end
  local machines = dry_machines(c, tick)
  if #machines == 0 then return end
  local name, available = fuel(c)
  if not name then return end
  local each = math.min(FUEL_PER_MACHINE, math.floor(available / #machines))
  while each < 1 and #machines > 1 do
    table.remove(machines)
    each = math.min(FUEL_PER_MACHINE, math.floor(available / #machines))
  end
  if each < 1 then return end
  local steps = {}
  for index, machine in ipairs(machines) do
    steps[index] = { action = "insert_items", x = machine.position.x, y = machine.position.y, items = { [name] = each } }
    storage.chores.refueled[machine.unit] = tick
  end
  pcall(tasks.queue_plan, { steps = steps, source = "upkeep" })
end

-- Chart the uncharted chunks around the body; charted ones are left alone.
function M.chart(_)
  local c = companion.get()
  if not (c and c.valid) then return end
  local force, surface = c.force, c.surface
  local cx, cy = math.floor(c.position.x / 32), math.floor(c.position.y / 32)
  for y = cy - CHART_RADIUS_CHUNKS, cy + CHART_RADIUS_CHUNKS do
    for x = cx - CHART_RADIUS_CHUNKS, cx + CHART_RADIUS_CHUNKS do
      local chunk = { x = x, y = y }
      if not force.is_chunk_charted(surface, chunk) and not force.is_chunk_requested_for_charting(surface, chunk) then
        force.chart(surface, { { x * 32, y * 32 }, { x * 32 + 31, y * 32 + 31 } })
      end
    end
  end
end

M.on_nth = {
  -- A chore that fails is skipped; it never stops the game.
  [UPKEEP_PERIOD] = function(event) pcall(M.upkeep, event.tick) end,
  [CHART_PERIOD] = function(event) pcall(M.chart, event.tick) end,
}

return M
