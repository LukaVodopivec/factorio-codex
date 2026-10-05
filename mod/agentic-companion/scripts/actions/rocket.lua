-- launch_rocket {silo:{x, y}, platform, cargo?: {[item]: count} | "requests", partial?}:
-- loads a ready rocket and presses the silo's launch button, as a player at
-- the silo does. One task in phases:
--   resolve  before any walking: the own rocket silo at `silo` on the body's
--            surface, the platform, a ready rocket (else ROCKET_NOT_READY with
--            the part count, at once), the destination (a platform waiting for
--            its starter pack takes the pack; any other needs its hub; a pack
--            already on its way is never sent twice), the platform over this
--            silo's planet, and the cargo against the rocket's weight and
--            slots. "requests" is what the hub's manual requests still lack,
--            greedy in request order, as far as it fits. What the rocket
--            already holds counts (a pack loaded earlier needs no cargo).
--   supply   the cargo through auto-supply (chests, crafting, smelting); a
--            shortfall fails unless partial, which loads what is carried
--   load     the existing insert sub-action into the rocket inventory, body
--            within reach
--   launch   the destination checks again, then the button (body at the
--            silo): it completes at the launch; the delivery comes later
--            through next_event, never waited for here.
-- Without cargo it launches what inserters or robots loaded. The mod never
-- writes rocket_parts and never applies a starter pack itself.
-- Boarding (the travel step's board phase, task.character): the same engine
-- launches the body itself to a platform's hub (a station destination: the
-- space_platform destination only takes starter packs), from a silo whose
-- prototype launches to platforms.
-- Result: {launched, silo, destination:{kind, platform}, loaded:[{item, count}],
-- cargo_weight_kg, max_weight_kg, shortfall?, rocket:{status, parts, parts_required}, launch_tick}.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local supply = require("scripts.actions.supply")
require("scripts.actions.transfer") -- registers the insert sub-action with supply
local platforms = require("scripts.platforms")
local requests = require("scripts.requests")
local craft = require("scripts.actions.craft")

local M = {}

local MAX_CARGO_ITEMS = 20
local STARTER_STATES = { waiting_for_starter_pack = true, starter_pack_requested = true }

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

local function point(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

local function validate(step, label)
  if not point(step.silo) then error(label .. " needs silo = {x, y}", 0) end
  platforms.check_selector(step.platform, label .. " platform")
  local cargo = step.cargo
  if cargo ~= nil and cargo ~= "requests" then
    if type(cargo) ~= "table" then error(label .. ' cargo must map items to counts, or be "requests"', 0) end
    local n = 0
    for name, count in pairs(cargo) do
      n = n + 1
      if type(name) ~= "string" or not prototypes.item[name] then
        error(string.format("UNKNOWN_ITEM: %s cargo: no item called '%s'", label, tostring(name)), 0)
      end
      if type(count) ~= "number" or count % 1 ~= 0 or count < 1 then error(label .. " cargo counts must be integers from 1", 0) end
    end
    if n < 1 or n > MAX_CARGO_ITEMS then error(string.format("%s cargo must name 1-%d items", label, MAX_CARGO_ITEMS), 0) end
  end
  if step.partial ~= nil and type(step.partial) ~= "boolean" then error(label .. " partial must be true or false", 0) end
end

local function status_name(value)
  for name, v in pairs(defines.rocket_silo_status) do if v == value then return name end end
  return tostring(value)
end

local function rocket_of(silo)
  return { status = status_name(silo.rocket_silo_status), parts = silo.rocket_parts,
    parts_required = read(function() return silo.prototype.rocket_parts_required end) }
end

local function kg(weight) return weight and math.floor(weight / 100 + 0.5) / 10 or nil end

local function failed(code, detail, outcome)
  outcome = outcome or {}
  outcome.code = code
  return { status = "failed", detail = code .. ": " .. detail, outcome = outcome }
end

local function find_silo(c, at)
  local found = c.surface.find_entities_filtered({ position = at, type = "rocket-silo", force = c.force, limit = 1 })
  local silo = found[1]
  if silo and silo.valid then return silo end
end
M.find_silo = find_silo

-- Whether a silo's rockets can carry the body to a platform.
function M.carries_to_platforms(silo)
  return read(function() return silo.prototype.launch_to_space_platforms end) == true
end

local function rocket_inventory(silo)
  return read(function() return silo.get_inventory(defines.inventory.rocket_silo_rocket) end)
end

-- The rocket's room: weight now and its limit (the inventory's own, else the
-- game's lift constant), and free slots.
local function room(inventory)
  local max = read(function() return inventory.max_weight end)
    or read(function() return prototypes.utility_constants["rocket_lift_weight"] end)
  return { weight = read(function() return inventory.weight end) or 0, max = tonumber(max),
    free = inventory.count_empty_stacks() }
end

-- Fits up to `want` of an item into the room left (weight and slots, a
-- partly filled stack of it first): how many, and "weight" or "slots" when
-- that ran out first. The room is charged.
local function fit(inventory, left, name, want)
  local proto = prototypes.item[name]
  local stack = tonumber(proto.stack_size) or 1
  local weight = tonumber(read(function() return proto.weight end)) or 0
  local held = inventory.get_item_count(name)
  local partial = held % stack > 0 and stack - held % stack or 0
  local count, limit = math.min(want, partial + left.free * stack), "slots"
  if weight > 0 and left.max then
    local lift = math.floor((left.max - left.weight) / weight)
    if lift < count then count, limit = lift, "weight" end
  end
  count = math.max(0, count)
  left.weight = left.weight + count * weight
  left.free = left.free - math.ceil(math.max(0, count - partial) / stack)
  return count, count < want and limit or nil
end

-- The cargo list ({name, count}, in order) and the refusal, if any. What
-- the rocket already holds of an item (an earlier load that did not launch,
-- inserters, the silo's own requests) counts towards it: only the rest is
-- supplied and loaded. An empty list launches what is loaded.
local function plan_cargo(task, silo, p, hub, planet)
  local inventory = rocket_inventory(silo)
  if not inventory then return nil, "ROCKET_NOT_READY", "the silo has no rocket to load" end
  local left = room(inventory)
  local list = {}
  if task.cargo == "requests" then
    local covered = false
    for _, want in ipairs(requests.unmet(hub, planet)) do
      local rest = want.count - inventory.get_item_count(want.name)
      covered = covered or rest < want.count
      local count = rest > 0 and fit(inventory, left, want.name, rest) or 0
      if count > 0 then list[#list + 1] = { name = want.name, count = count } end
    end
    if #list == 0 and not covered then
      return nil, "NOTHING_REQUESTED", string.format("platform %s's hub lacks nothing its requests from %s name, or none of it fits",
        p.name, planet)
    end
    return list, nil, nil, left
  end
  local names = {}
  for name in pairs(task.cargo) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local want = task.cargo[name] - inventory.get_item_count(name)
    if want > 0 then
      local before = { weight = left.weight, free = left.free }
      local count, limit = fit(inventory, left, name, want)
      if limit then
        local weight = tonumber(read(function() return prototypes.item[name].weight end)) or 0
        return nil, limit == "weight" and "OVERWEIGHT" or "NO_FREE_SLOTS",
          string.format("%d %s would bring the rocket to %s kg of the %s kg it lifts, with %d free slots; %d fit",
            want, name, kg(before.weight + want * weight), kg(left.max), before.free, count)
      end
      list[#list + 1] = { name = name, count = want }
    end
  end
  return list, nil, nil, left
end

local function starter_pack_of(p)
  local pack = read(function() return p.starter_pack.name end)
  return type(pack) == "string" and pack or read(function() return pack.name end) or platforms.STARTER_PACK
end

-- The destination the platform's state calls for now ("starter_pack", or
-- "hub" with its hub), over `planet`; else nil and the refusal's code,
-- detail and outcome fields. resolve and the button both ask it.
local function destination_of(p, planet)
  local state = platforms.state_name(p)
  if state == "starter_pack_on_the_way" then
    return nil, "STARTER_PACK_ALREADY_SENT", "platform " .. p.name .. "'s starter pack is already on its way"
  end
  local kind, hub = "starter_pack", nil
  if not STARTER_STATES[state] then
    kind, hub = "hub", p.hub
    if not (hub and hub.valid) then return nil, "NO_HUB", "platform " .. p.name .. " has no hub" end
  end
  local location = platforms.planet(p)
  if not planet or location ~= planet then
    return nil, "DESTINATION_NOT_IN_ORBIT", string.format("platform %s is at %s, not over this silo's planet %s", p.name,
      tostring(location or "an unknown location"), tostring(planet)), { location = location, silo_planet = planet }
  end
  return kind, hub
end

local function resolve(task, c)
  local silo = find_silo(c, task.silo)
  if not silo then
    return failed("NO_SILO", string.format("no own rocket silo at (%.1f, %.1f)", task.silo.x, task.silo.y))
  end
  task._silo = silo
  local p, code, why = platforms.resolve(c.force, task.platform)
  if not p then return failed(code, why) end
  local rocket = rocket_of(silo)
  if silo.rocket_silo_status ~= defines.rocket_silo_status.rocket_ready then
    return failed("ROCKET_NOT_READY", string.format("the rocket is not built yet (%d/%s parts, %s): wait for next_event rocket_ready",
      rocket.parts or 0, tostring(rocket.parts_required), rocket.status), { rocket = rocket })
  end
  local planet = read(function() return silo.surface.planet.name end)
  local kind, hub, detail, fields = destination_of(p, planet)
  if not kind then return failed(hub, detail, fields) end
  if task.character then
    if kind ~= "hub" then
      return failed("PLATFORM_NOT_IN_ORBIT", "platform " .. p.name .. " waits for its starter pack: the body boards only a platform with a hub")
    end
    if not M.carries_to_platforms(silo) then
      return failed("SILO_NOT_FOR_PLATFORMS", "this silo's rockets do not launch to space platforms")
    end
  end
  local cargo = task.cargo
  if kind == "starter_pack" then
    local pack = starter_pack_of(p)
    local inventory = rocket_inventory(silo)
    local held = inventory and inventory.get_item_count(pack) or 0
    if held < 1 and (type(cargo) ~= "table" or not cargo[pack]) then
      return failed("STARTER_PACK_REQUIRED", string.format("platform %s waits for its starter pack: cargo must hold %s", p.name, pack))
    end
    -- The pack is already in the rocket: only a named cargo is still loaded.
    if type(cargo) ~= "table" then cargo = nil end
  end
  task._kind, task._index, task._planet = kind, p.index, planet
  task._destination = { kind = kind, platform = { index = p.index, name = p.name } }
  task._phase = "launch"
  if cargo ~= nil then
    local list, refusal, why_not = plan_cargo(task, silo, p, hub, planet)
    if not list then return failed(refusal, why_not) end
    if #list > 0 then
      task._cargo = list
      task._phase = "supply"
    end
  end
end

local Runner = {}

function Runner.start(task)
  companion.require_companion()
  validate(task, "launch_rocket")
end

Runner.resume = supply.resume

local function outcome_of(task, silo, launched)
  local inventory = not task._max and rocket_inventory(silo)
  local left = inventory and room(inventory) or {}
  return { code = launched and "ROCKET_LAUNCHED" or nil, launched = launched, silo = { x = silo.position.x, y = silo.position.y },
    destination = task._destination, loaded = task._loaded or {}, cargo_weight_kg = kg(task._weight or left.weight),
    max_weight_kg = kg(task._max or left.max), shortfall = task._shortfall, rocket = rocket_of(silo),
    launch_tick = launched and game.tick or nil }
end

-- The button: the destination is rebuilt from the platform as it is now,
-- with resolve's checks again (walking and loading take a while; the
-- platform may have left orbit or got its pack meanwhile).
local function launch(task, c, silo)
  local p, code, why = platforms.resolve(c.force, task._index)
  if not p then return failed(code, why) end
  local kind, hub, detail, fields = destination_of(p, task._planet)
  if kind and kind ~= task._kind then
    kind, hub, detail = nil, "STARTER_PACK_ALREADY_SENT", "platform " .. p.name .. " got its starter pack meanwhile"
  end
  if not kind then
    local outcome = outcome_of(task, silo, false)
    for key, value in pairs(fields or {}) do outcome[key] = value end
    return failed(hub, detail .. "; the cargo stays in the rocket", outcome)
  end
  local destination
  if kind == "starter_pack" then
    destination = { type = defines.cargo_destination.space_platform, space_platform = p }
  else
    destination = { type = defines.cargo_destination.station, station = hub }
  end
  if silo.rocket_silo_status ~= defines.rocket_silo_status.rocket_ready then
    return failed("ROCKET_NOT_READY", "the rocket is no longer ready (" .. status_name(silo.rocket_silo_status) .. ")",
      outcome_of(task, silo, false))
  end
  local inventory = rocket_inventory(silo)
  if inventory then
    local left = room(inventory)
    task._weight, task._max = left.weight, left.max
  end
  -- launch_rocket(destination?, character?): positional.
  local launched
  if task.character then launched = silo.launch_rocket(destination, c) else launched = silo.launch_rocket(destination) end
  if not launched then
    return failed("LAUNCH_REFUSED", "the silo refused the launch to platform " .. p.name, outcome_of(task, silo, false))
  end
  local loaded = {}
  for _, row in ipairs(task._loaded or {}) do loaded[#loaded + 1] = string.format("%d %s", row.count, row.item) end
  local outcome = outcome_of(task, silo, true)
  outcome.boarded = task.character == true or nil
  return { status = "done",
    detail = string.format("launched the rocket to platform %s (%s)%s%s", p.name, task._kind,
      task.character and " with the body aboard" or "", #loaded > 0 and (" with " .. table.concat(loaded, ", ")) or ""),
    outcome = outcome }
end

function Runner.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  if not task._phase then
    local refused = resolve(task, c)
    if refused then return refused end
  end
  local silo = task._silo
  if not (silo and silo.valid) then return failed("NO_SILO", "the rocket silo is gone") end
  if task._phase == "supply" then
    local needs = {}
    for _, row in ipairs(task._cargo) do
      if c.get_item_count(row.name) < row.count then needs[#needs + 1] = { name = row.name, count = row.count } end
    end
    -- A supply under way runs to its end even once everything is carried.
    if task._supply or #needs > 0 then
      local result = supply.ensure(task, needs, { exclude = task.silo })
      if not result then return nil end
      if result.status ~= "done" then
        task._shortfall = result.outcome and result.outcome.missing or result.detail
        if not task.partial then
          return failed("SUPPLY_SHORTFALL", (result.detail or ""):gsub("^SUPPLY_SHORTFALL: ", "") .. "; nothing was loaded",
            { shortfall = task._shortfall })
        end
      end
    end
    -- Supplied output still in the crafting queue counts: the insert waits
    -- for it. A partial load takes what is carried or being crafted.
    local items = {}
    for _, row in ipairs(task._cargo) do
      local count = task._shortfall and math.min(row.count, c.get_item_count(row.name) + craft.queued(c, row.name)) or row.count
      if count > 0 then items[row.name] = count end
    end
    if not next(items) then return failed("SUPPLY_SHORTFALL", "none of the cargo is carried", { shortfall = task._shortfall }) end
    local ok, err = pcall(supply.begin, task, "_sub", { type = "insert", target = { x = silo.position.x, y = silo.position.y },
      items = items, inventory = "rocket", auto_supply = false })
    if not ok then return failed("LOAD_FAILED", tostring(err)) end
    task._phase = "load"
    return nil
  end
  if task._phase == "load" then
    local result = supply.step(task, "_sub")
    if not result then return nil end
    local loaded = {}
    for _, row in ipairs(result.outcome and result.outcome.transfers or {}) do
      if (row.inserted or 0) > 0 then loaded[#loaded + 1] = { item = row.item, count = row.inserted } end
    end
    task._loaded = loaded
    if result.status == "failed" or result.status == "partial" and not task.partial then
      local outcome = outcome_of(task, silo, false)
      return failed(result.status == "failed" and "LOAD_FAILED" or "PARTIAL_LOAD",
        (result.detail or "") .. (#loaded > 0 and "; what went in stays in the rocket" or ""), outcome)
    end
    task._phase = "launch"
  end
  -- The launch button is in the silo's window: the body stands at the silo.
  local reached = approach.ensure(task, c, task.silo, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end
  local entity_reached = approach.ensure_entity(task, c, silo)
  if type(entity_reached) == "table" then return entity_reached end
  if entity_reached ~= "ok" then return nil end
  return launch(task, c, silo)
end

-- inspect_entity's rocket-silo block: the rocket's state and parts, its
-- cargo and weight, and the silo's automatic requests.
function M.silo_block(silo)
  local block = rocket_of(silo)
  local inventory = rocket_inventory(silo)
  local cargo = {}
  for _, item in ipairs(inventory and inventory.get_contents() or {}) do
    cargo[#cargo + 1] = { item = item.name, count = item.count }
  end
  table.sort(cargo, function(a, b) return a.item < b.item end)
  local left = inventory and room(inventory) or {}
  block.cargo, block.cargo_weight_kg, block.max_weight_kg = cargo, kg(left.weight), kg(left.max)
  block.auto_requests = read(function() return silo.use_transitional_requests end)
  local target = read(function() return silo.transitional_request_target end)
  block.request_target = target and read(function() return { index = target.index, name = target.name } end) or nil
  return block
end

-- The runner itself, for the travel step's board phase.
M.runner = Runner

-- The plan action for tasks.register_action.
M.action = {
  runner = Runner,
  make_task = function(step)
    return { silo = step.silo, platform = step.platform, cargo = step.cargo, partial = step.partial == true }
  end,
  validate = function(step, index) validate(step, "queue_plan launch_rocket step " .. index) end,
}

return M
