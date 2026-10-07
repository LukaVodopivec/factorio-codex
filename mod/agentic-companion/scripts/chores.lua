-- Chores the mod does without any bot:
-- * Upkeep: while nothing queued takes the body (the FIFO is empty or holds
--   only parked waits or plans whose predecessor is pending, or the running
--   plan's step only waits on hand-crafting: tasks.upkeep_room), never after
--   an emergency stop before a plan has finished (a stop with keep_upkeep,
--   the supervisor's reconciliation, leaves upkeep on), while the owner is not holding
--   the body and the body stands on a surface (nothing aboard or in
--   transit), the body refuels own burner machines on its surface within
--   96 tiles of it (UPKEEP_RADIUS; after two idle minutes, also within 96
--   tiles of the work sites where recent pilot or package plans began) that ran
--   dry or are working on their last fuel item, with a fuel their burner
--   takes (by fuel category: biochambers nutrients, heating towers chemical
--   fuel), and brings the current research's science packs to own labs on
--   its surface that take them, from what it carries or own stock (insert's
--   auto-supply walks to it). A machine's refuel cooldown starts when its
--   refuel step ends (fuel inserted, or the attempt failed), so a machine a
--   pre-empted plan never reached is chosen again at the next pass. A lab
--   gets only the packs it accepts and has room for; one that would take
--   nothing is skipped, and the same lab and pack are never tried again
--   within LAB_RETRY_TICKS. With no research active no lab is fed. It is an
--   ordinary plan with source "upkeep", so activity_log shows it, and any
--   queued plan that takes the body takes it at the next step boundary.
--   Beside pending work the plan ends with a walk back to where the body
--   stood, taken even when the plan ends early, so a parked wait still reads
--   its target from there; beside a running craft it never moves what that
--   craft makes or uses, and beside a parked wait_for_item it uses only what
--   the body carries of the item the wait counts (tasks.upkeep_room). A burner still burning gets only a fuel its fuel
--   slot takes beside what is there.
-- * Plan-boundary upkeep: back-to-back plans leave no such moment, so just
--   before the dispatcher starts a queued pilot or package plan, one
--   ordinary pass runs first when a machine within 96 tiles of the body or
--   of the work sites has been dry for a minute and no upkeep step ended
--   (nor this pass looked) in the last two minutes; it serves machines near
--   the body and dry burners near the work sites, never moves an item the
--   plan it goes ahead of names, is never pre-empted and ends with the walk back, so that
--   plan starts where it would have.
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
local RETURN_RADIUS = 2               -- the walk back beside pending work
local FUEL_PER_MACHINE = 10
local MAX_LABS = 8
local PACKS_PER_LAB = 10
-- Machines one upkeep pass looks at per status: the line sampler keeps the
-- units in each chore status, so a pass never walks every machine.
local MAX_CANDIDATES = 64
-- Upkeep serves machines within this many tiles of the body; after two idle
-- minutes (the FIFO empty) also of the work sites, and at a plan boundary
-- the dry burners near them (one pass in BOUNDARY_GAP_TICKS at most, which
-- may walk the body to a site and back). A machine farther from all of them
-- gets no round trip: factory_status shows it no_fuel, and supplying or
-- retiring it is the bots' call.
local UPKEEP_RADIUS = 96
-- The plan-boundary pass: a machine dry this long calls it, at most once
-- in BOUNDARY_GAP_TICKS and never that soon after an upkeep step ended.
local DRY_TICKS = 3600
local BOUNDARY_GAP_TICKS = 7200
-- Matching machines one pass may look at in all, far ones included, so a
-- dry outpost never hides the machines beside the body.
local SITE_IDLE_TICKS = 2 * 3600       -- idle this long before upkeep reaches the work sites
local MAX_LOOKED = 4 * MAX_CANDIDATES

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

local function held()
  local ok, value = pcall(companion.human_control)
  return ok and value == true
end

-- Whether `position` lies within UPKEEP_RADIUS of the body or of a site in
-- `sites` ({x, y} list, optional).
local function within_reach(position, c, sites)
  local r2 = UPKEEP_RADIUS * UPKEEP_RADIUS
  local dx, dy = position.x - c.position.x, position.y - c.position.y
  if dx * dx + dy * dy <= r2 then return true end
  for _, site in ipairs(sites or {}) do
    local sx, sy = position.x - site.x, position.y - site.y
    if sx * sx + sy * sy <= r2 then return true end
  end
  return false
end

-- The work sites (tasks' work_sites: where recent pilot or package plans
-- began) on the body's surface, or nil when there are none.
local function work_sites(c)
  local sites
  for _, site in ipairs(storage.tasks and storage.tasks.work_sites or {}) do
    if site.surface_index == c.surface_index then
      sites = sites or {}
      sites[#sites + 1] = site
    end
  end
  return sites
end

-- Own machines on the body's surface in a raw sampler state, or in the
-- sampler's "low_fuel" set (of one type when given), not skipped by
-- `skip(unit)` (a pure Lua test), within UPKEEP_RADIUS of the body or of a
-- site in `sites` ({x, y} list, optional), nearest the body first: from the sampler's set on
-- that surface, at most MAX_CANDIDATES of them taken and MAX_LOOKED looked at
-- (machines elsewhere are never counted). An audit records at most MAX_CANDIDATES rows in all.
local function machines_in(c, raw, kind, skip, audit, sites)
  local a = storage.autonomy
  local rows, seen, looked = {}, 0, 0
  local audit_left = audit and MAX_CANDIDATES - audit.observed_candidates or 0
  local function nearer(x, y)
    if x.distance ~= y.distance then return x.distance < y.distance end
    return x.unit < y.unit
  end
  local by_surface = a and a.waiting and a.waiting[raw]
  for unit in pairs(by_surface and by_surface[c.surface_index] or {}) do
    if seen >= MAX_CANDIDATES or looked >= MAX_LOOKED then
      if audit then audit.scan_complete = false end
      break
    end
    local rec = a.machines[unit]
    local matches = rec and (raw == "low_fuel" and rec.low_fuel == true or rec.raw == raw)
      and (kind == nil or rec.type == kind)
    local skipped = matches and skip and skip(unit)
    local evidence
    if audit and matches and audit_left > 0 then
      audit_left = audit_left - 1
      audit.observed_candidates = audit.observed_candidates + 1
      local at = storage.chores.refueled[unit]
      evidence = { unit = unit, position = rec.position, raw = rec.raw, low_fuel = rec.low_fuel or nil,
        decision = skipped and "cooldown" or "candidate", last_attempt_tick = at,
        retry_tick = at and at + REFUEL_COOLDOWN_TICKS or nil }
      audit.candidates[#audit.candidates + 1] = evidence
      -- Stop diagnostic bookkeeping independently of the existing selector.
      -- At saturation the count is a lower bound, never a population count.
      if audit_left == 0 then audit.candidates_capped = true end
    end
    if matches and not skipped then
      looked = looked + 1
      local entity = rec.entity
      local dx, dy = rec.position.x - c.position.x, rec.position.y - c.position.y
      local distance = dx * dx + dy * dy
      if not within_reach(rec.position, c, sites) then
        if evidence then evidence.decision = "too_far" end
      elseif entity and entity.valid then
        seen = seen + 1
        rows[#rows + 1] = { unit = unit, position = rec.position, entity = entity, distance = distance,
          evidence = evidence }
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
-- most of. `known` keeps each answer for the pass, by category list. Items
-- reserved `true` (what a lending craft makes or uses) are never chosen;
-- reserved "carried" (what a parked wait counts) only from what the body carries.
local function fuel_for(c, entity, known, reserved)
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
    for _, name in ipairs(names) do
      totals[name] = reserved[name] ~= true and c.get_item_count(name) + (not reserved[name] and stored[name] or 0) or 0
    end
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

-- The fuel for a burner still burning: its fuel inventory holds what it
-- burns, and one fuel slot takes only more of the same item. The chosen fuel
-- when it fits beside what is there, else more of the fuel already in it
-- when the body has some, else nil.
local function low_fuel_for(c, entity, fuel, known, reserved)
  local inventory = read(function() return entity.burner.inventory end)
  if not inventory then return fuel end
  if fuel and read(function() return inventory.can_insert({ name = fuel.name, quality = "normal" }) end) ~= false then
    return fuel
  end
  for _, item in ipairs(read(function() return inventory.get_contents() end) or {}) do
    local name, key = item.name, "item:" .. tostring(item.name)
    if (item.quality or "normal") == "normal" and reserved[name] ~= true then
      if known[key] == nil then
        local total = c.get_item_count(name) + (not reserved[name] and registry.stock_totals({ name })[name] or 0)
        known[key] = total > 0 and { name = name, available = total } or false
      end
      if known[key] then return known[key] end
    end
  end
end

-- Insert steps that refuel own burner machines out of fuel (also near
-- `dry_sites`), then those working on their last fuel item (also near
-- `low_sites`): the machines sharing a fuel share what there is of it. Each
-- step's machine is kept in `units` by the step.
local function refuel_steps(c, tick, steps, audit, units, reserved, dry_sites, low_sites)
  local refueled = storage.chores.refueled
  local function cooling(unit)
    return refueled[unit] ~= nil and tick - refueled[unit] < REFUEL_COOLDOWN_TICKS
  end
  local machines = machines_in(c, "no_fuel", nil, cooling, audit, dry_sites)
  for _, machine in ipairs(machines_in(c, "low_fuel", nil, cooling, audit, low_sites)) do
    machine.low = true
    machines[#machines + 1] = machine
  end
  while #machines > MAX_REFUELS do
    local excluded = table.remove(machines)
    if excluded.evidence then excluded.evidence.decision = "selection_limit" end
  end
  if #machines == 0 then return end
  local known, groups, order = {}, {}, {}
  for _, machine in ipairs(machines) do
    local fuel = fuel_for(c, machine.entity, known, reserved)
    if machine.low then fuel = low_fuel_for(c, machine.entity, fuel, known, reserved) end
    if fuel then
      local group = groups[fuel.name]
      if not group then
        group = { fuel = fuel, machines = {} }
        groups[fuel.name], order[#order + 1] = group, fuel.name
      end
      group.machines[#group.machines + 1] = machine
    elseif machine.evidence then
      machine.evidence.decision = "no_fuel_selected"
    end
  end
  for _, name in ipairs(order) do
    local group = groups[name]
    local list, available = group.machines, group.fuel.available
    local each = math.min(FUEL_PER_MACHINE, math.floor(available / #list))
    while each < 1 and #list > 1 do
      local excluded = table.remove(list)
      if excluded.evidence then excluded.evidence.decision = "insufficient_share" end
      each = math.min(FUEL_PER_MACHINE, math.floor(available / #list))
    end
    if each >= 1 then
      for _, machine in ipairs(list) do
        local step = { action = "insert_items", x = machine.position.x, y = machine.position.y, items = { [name] = each } }
        steps[#steps + 1], units[step] = step, machine.unit
        if machine.evidence then machine.evidence.decision = "selected" end
        audit.selected[#audit.selected + 1] = { unit = machine.unit, position = machine.position,
          item = name, count = each, available_snapshot = available }
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
-- takes it goes to the nearest ones first (as fuel does). Packs in
-- reserved `true` are left alone; reserved "carried" come only from what the
-- body carries.
local function lab_steps(c, tick, steps, reserved, sites)
  local research = c.force.current_research
  if not research then return end
  local names = {}
  for _, ingredient in ipairs(research.research_unit_ingredients or {}) do
    if ingredient.type ~= "fluid" and reserved[ingredient.name] ~= true then names[#names + 1] = ingredient.name end
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
  end, nil, sites)
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
    local available = list and c.get_item_count(name) + (not reserved[name] and stored[name] or 0) or 0
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

-- One upkeep pass in `room` ("idle", "busy" or "boundary"): queues the
-- plan, if there is anything to do, and returns its ID.
local function pass(c, tick, room, reserved)
  reserved = reserved or {}
  for unit, at in pairs(storage.chores.refueled) do
    if tick - at >= REFUEL_COOLDOWN_TICKS then storage.chores.refueled[unit] = nil end
  end
  for key, at in pairs(storage.chores.fed_labs) do
    if tick - at >= M.LAB_RETRY_TICKS then storage.chores.fed_labs[key] = nil end
  end
  -- Also near the work sites on this surface: after SITE_IDLE_TICKS idle,
  -- everything upkeep serves, so an idle body at a far site never leaves the
  -- base dry; at a plan boundary (called by a machine dry for a minute, at
  -- most once in BOUNDARY_GAP_TICKS), only the dry burners there, so
  -- back-to-back plans far off never leave the base's burners dry; that pass
  -- may walk the body to a site and back before the plan it goes ahead of.
  -- Otherwise (a busy body, a short pause between plans) only near the body.
  local idle_long = room == "idle" and storage.tasks and storage.tasks.last_finished_tick ~= nil
    and tick - storage.tasks.last_finished_tick >= SITE_IDLE_TICKS
  local sites = (idle_long or room == "boundary") and work_sites(c) or nil
  local all_sites = idle_long and sites or nil
  local steps, units = {}, {}
  local selection = { tick = tick, surface_index = c.surface_index, room = room, sites = sites,
    refuel = { candidate_limit = MAX_CANDIDATES, selected_limit = MAX_REFUELS,
      retry_ticks = REFUEL_COOLDOWN_TICKS, candidates = {}, selected = {},
      observed_candidates = 0, scan_complete = true } }
  refuel_steps(c, tick, steps, selection.refuel, units, reserved, sites, all_sites)
  lab_steps(c, tick, steps, reserved, all_sites)
  selection.step_count = #steps
  if #steps > 0 and room ~= "idle" then
    steps[#steps + 1] = { action = "walk_to", x = c.position.x, y = c.position.y,
      arrival_mode = "vicinity", arrival_radius = RETURN_RADIUS, upkeep_return = true }
  end
  if #steps > 0 then
    local ok, result = pcall(tasks.queue_plan, { steps = steps, source = "upkeep" }, selection)
    selection.queue_status = ok and "queued" or "rejected"
    selection.plan_id = ok and result.plan_id or nil
    if not ok then selection.queue_error = tostring(result):sub(1, 240) end
    -- The machine each refuel step serves, by step index, for the cooldown.
    local by_index = {}
    for index, step in ipairs(steps) do by_index[index] = units[step] end
    storage.chores.refuel_plan = ok and { plan_id = result.plan_id, units = by_index } or nil
  else selection.queue_status = "no_steps" end
  storage.chores.last_selection = selection
  return selection.plan_id
end

function M.upkeep(tick)
  local c = companion.get()
  if not (c and c.valid and storage.chores) or held() then return end
  local room, reserved = tasks.upkeep_room()
  if room then pass(c, tick, room, reserved) end
end

-- Whether a machine within UPKEEP_RADIUS of the body or of a work site has
-- been out of fuel for DRY_TICKS and is not cooling down: the plan-boundary
-- pass's cue. It looks at no more than MAX_LOOKED machines of the sampler's
-- no_fuel set.
local function long_dry(c, tick)
  local sites = work_sites(c)
  local a = storage.autonomy
  local units = a and a.waiting and a.waiting.no_fuel and a.waiting.no_fuel[c.surface_index]
  local refueled, looked = storage.chores.refueled, 0
  for unit in pairs(units or {}) do
    looked = looked + 1
    if looked > MAX_LOOKED then return false end
    local rec = a.machines[unit]
    local at = refueled[unit]
    if rec and rec.raw == "no_fuel" and rec.problem == "no_fuel" and rec.problem_since
      and tick - rec.problem_since >= DRY_TICKS and not (at and tick - at < REFUEL_COOLDOWN_TICKS)
      and within_reach(rec.position, c, sites) then
      return true
    end
  end
  return false
end

-- The plan-boundary pass (tasks' dispatcher, just before a queued pilot or
-- package plan starts): one ordinary pass in room "boundary" (sparing what
-- that plan names: tasks.upkeep_room), whose plan
-- runs first, is never pre-empted and ends with the walk back (near a work
-- site it serves only dry burners), when a
-- machine near the body or a work site has been dry for DRY_TICKS, no
-- upkeep step ended and this pass did not look within BOUNDARY_GAP_TICKS.
-- Returns the plan ID.
function M.boundary_upkeep(tick)
  local c, chores = companion.get(), storage.chores
  if not (c and c.valid and chores) or held() then return nil end
  if tick - (chores.step_tick or -BOUNDARY_GAP_TICKS) < BOUNDARY_GAP_TICKS
    or tick - (chores.boundary_tick or -BOUNDARY_GAP_TICKS) < BOUNDARY_GAP_TICKS or not long_dry(c, tick) then
    return nil
  end
  local room, reserved = tasks.upkeep_room(true)
  if not room then return nil end
  chores.boundary_tick = tick
  return pass(c, tick, room, reserved)
end

-- A step of an upkeep plan ended (tasks' upkeep listener): a refuel step's
-- machine starts its cooldown now, whether the fuel went in or the attempt
-- failed, so one unreachable machine never holds up the rest.
function M.on_upkeep_step(plan, index, status)
  if storage.chores then storage.chores.step_tick = game.tick end
  local pending = storage.chores and storage.chores.refuel_plan
  local unit = status ~= "cancelled" and pending and pending.plan_id == plan.id and pending.units[index]
  if unit then storage.chores.refueled[unit] = game.tick end
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
