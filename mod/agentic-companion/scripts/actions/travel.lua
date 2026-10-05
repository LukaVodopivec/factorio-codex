-- travel {to, via_silo?: {x, y}, max_wait_minutes?: 1..240 (default 60)}:
-- the body itself goes to another surface the way a player does: it rides a
-- rocket up to a platform in orbit, stays aboard while the platform flies
-- its route, and lands on the planet the platform waits at. The mod never
-- picks a route (set_platform_route does), never teleports and never uses
-- enter_space_platform or leave_space_platform. One plan step in phases,
-- its progress kept in the task:
--   resolve      before any walking: where the body is and what `to` needs.
--                The same surface is plain success. On a planet `to` must be
--                a platform over that planet with a hub, and a silo whose
--                rockets launch to platforms must exist (via_silo, else any
--                own silo on this surface, from the registry). Aboard, `to`
--                must be an unlocked planet the platform is at or has a
--                schedule record for (else NO_ROUTE at once).
--   board_wait   no silo has a rocket ready: wait for one (a silo serving
--                hub requests launches on its own), within max_wait_minutes
--   board        launch_rocket's engine with the body: walk to the silo and
--                press the button with the character aboard the rocket
--   wait_arrival aboard, until the platform reaches the destination: the
--                platform state event (waiting_at_station) marks it, within
--                max_wait_minutes; the body stays aboard on a timeout
--   land         LuaPlayer.land_on_planet
--   ride         in the rocket or the landing pod, until the body is aboard
--                that platform or standing on that planet (7,200 ticks)
-- A launch or landing that started finishes natively even when the step is
-- cancelled. The step keeps the FIFO meanwhile (the body is busy): plans
-- behind it wait with it, which is why the pilot uses the direct remote
-- tools while aboard. Each phase is in next_event (travel_phase); the
-- surface change itself is body_surface_changed.
-- Result: {arrived, from, to, phases:[{phase, start_tick, end_tick}],
-- position, state, code?, waited_ticks}.
local companion = require("scripts.companion")
local platforms = require("scripts.platforms")
local rocket = require("scripts.actions.rocket")
local registry = require("scripts.registry")

local M = {}

M.RIDE_TICKS = 7200
M.POLL_TICKS = 60
M.DEFAULT_WAIT_MINUTES = 60
M.MAX_WAIT_MINUTES = 240
local WAITING = { board_wait = true, wait_arrival = true, ride = true }
local STARTER_STATES = { waiting_for_starter_pack = true, starter_pack_requested = true, starter_pack_on_the_way = true }

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

local function point(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

-- Checks the step and puts the destination's canonical reference in _to.
local function validate(step, label)
  local ref, code, why = platforms.canonical_ref(companion.require_present().force, step.to)
  if not ref then error(code .. ": " .. label .. " to: " .. why, 0) end
  step._to = ref
  if step.via_silo ~= nil and not point(step.via_silo) then error(label .. " via_silo must be {x, y}", 0) end
  local wait = step.max_wait_minutes
  if wait ~= nil and (type(wait) ~= "number" or wait % 1 ~= 0 or wait < 1 or wait > M.MAX_WAIT_MINUTES) then
    error(string.format("%s max_wait_minutes must be a whole number from 1 to %d", label, M.MAX_WAIT_MINUTES), 0)
  end
end

local function wait_ticks(task)
  return (task.max_wait_minutes or M.DEFAULT_WAIT_MINUTES) * 3600
end

-- A waiting phase's deadline is its own field (_deadline_tick), which the
-- dispatcher moves on by a hold's ticks (tasks.release_plan); _phase_tick
-- stays when the phase began, for the arrival comparison.
local function phase_limit(task, phase)
  if phase == "board_wait" or phase == "wait_arrival" then return wait_ticks(task) end
  if phase == "ride" then return M.RIDE_TICKS end
end

local function enter(task, phase)
  local last = task._phases[#task._phases]
  if last and not last.end_tick then last.end_tick = game.tick end
  task._phases[#task._phases + 1] = { phase = phase, start_tick = game.tick }
  task._phase, task._phase_tick, task._next_check = phase, game.tick, nil
  local limit = phase_limit(task, phase)
  task._deadline_tick = limit and game.tick + limit or nil
  platforms.record("travel_phase", { phase = phase, from = task._from, to = task._to })
end

local function expired(task)
  return task._deadline_tick ~= nil and game.tick >= task._deadline_tick
end

local function waited(task)
  local ticks = 0
  for _, row in ipairs(task._phases or {}) do
    if row.phase == "board_wait" or row.phase == "wait_arrival" then ticks = ticks + (row.end_tick or game.tick) - row.start_tick end
  end
  return ticks
end

local function outcome(task, code, arrived)
  local last = task._phases and task._phases[#task._phases]
  if last and not last.end_tick then last.end_tick = game.tick end
  local body = companion.body()
  return { code = code, arrived = arrived, from = task._from, to = task._to, phases = task._phases or {},
    position = body.position, state = body.state, surface = body.surface_ref, waited_ticks = waited(task) }
end

-- A launch or landing this step started and still owns.
local function release(task)
  local active = storage.travel and storage.travel.active
  if active and active.task_id == task.id then storage.travel.active = nil end
end

local function fail(task, code, detail)
  release(task)
  task._launched = nil
  return { status = "failed", detail = code .. ": " .. detail, outcome = outcome(task, code, false) }
end

local function arrived(task)
  release(task)
  task._launched = nil
  local body = companion.body()
  return { status = "done", detail = string.format("the body travelled from %s to %s (%s)", tostring(task._from),
    task._to, body.state), outcome = outcome(task, "ARRIVED", true) }
end

-- Own silos on the body's surface whose rockets launch to platforms (the
-- registry's silos in charted chunks), or the one at via_silo.
local function silos(c, task)
  if task.via_silo then
    local silo = rocket.find_silo(c, task.via_silo)
    return silo and { silo } or {}
  end
  local rows = {}
  for _, entry in ipairs(registry.machines({ "rocket-silo" })) do
    if entry.entity and entry.entity.valid then rows[#rows + 1] = entry.entity end
  end
  return rows
end

-- The nearest silo with a rocket ready, if any.
local function ready_silo(c, task)
  local best, best_d
  for _, silo in ipairs(silos(c, task)) do
    if rocket.carries_to_platforms(silo) and silo.rocket_silo_status == defines.rocket_silo_status.rocket_ready then
      local d = (silo.position.x - c.position.x) ^ 2 + (silo.position.y - c.position.y) ^ 2
      if not best or d < best_d then best, best_d = silo, d end
    end
  end
  return best
end

-- Planet -> platform: the platform over this planet with a hub, and a silo
-- that can carry the body; else the refusal.
local function resolve_board(task, body, p)
  local c = companion.require_companion()
  local planet = read(function() return body.surface.planet.name end)
  local state = platforms.state_name(p)
  if STARTER_STATES[state] or not read(function() return p.hub and p.hub.valid end) then
    return fail(task, "PLATFORM_NOT_IN_ORBIT", "platform " .. p.name .. " has no hub yet: launch its starter pack first")
  end
  local location = platforms.location(p)
  if not planet or location ~= planet then
    return fail(task, "PLATFORM_NOT_IN_ORBIT", string.format("platform %s is %s, not over %s", p.name,
      location and ("at " .. location) or "travelling", tostring(planet)))
  end
  local any, carrier = false, false
  for _, silo in ipairs(silos(c, task)) do
    any = true
    carrier = carrier or rocket.carries_to_platforms(silo)
  end
  if not any then
    return fail(task, "NO_SILO", task.via_silo and string.format("no own rocket silo at (%.1f, %.1f)", task.via_silo.x,
      task.via_silo.y) or "no own rocket silo on this surface")
  end
  if not carrier then return fail(task, "SILO_NOT_FOR_PLATFORMS", "no silo here launches rockets to space platforms") end
  task._platform = p.index
  enter(task, "board_wait")
end

-- Platform -> planet: the platform the body is aboard, at the destination
-- or with a schedule record for it.
local function resolve_land(task, body)
  local p = body.platform
  local force = body.force
  if not read(function() return game.planets[task._to] end) then
    return fail(task, "NO_ROUTE", "the body leaves a platform only by landing on a planet; " .. task._to .. " is a platform")
  end
  if not platforms.location_unlocked(force, task._to) then
    return fail(task, "LOCATION_LOCKED", task._to .. " is not unlocked yet")
  end
  task._platform = p.index
  if platforms.location(p) == task._to and not read(function() return p.space_connection end) then
    return enter(task, "land")
  end
  local scheduled = false
  local schedule = read(function() return p.get_schedule() end)
  for _, record in ipairs(schedule and read(function() return schedule.get_records() end) or {}) do
    if record.station == task._to then scheduled = true end
  end
  if not scheduled then
    return fail(task, "NO_ROUTE", string.format("platform %s's schedule has no stop at %s: add it with set_platform_route",
      p.name, task._to))
  end
  enter(task, "wait_arrival")
end

local function resolve(task)
  local body = companion.body()
  task._from, task._phases = body.surface_ref, {}
  if body.state ~= "on_surface" and body.state ~= "aboard_platform" then
    companion.require_companion() -- raises the body's own state (in transit, dead, ...)
  end
  if body.surface_ref == task._to then return arrived(task) end
  if body.state == "aboard_platform" then return resolve_land(task, body) end
  local _, code, why, p = platforms.canonical_ref(body.force, task._to)
  if code then return fail(task, code, why) end
  if not p then
    return fail(task, "NO_ROUTE", "from a planet the body travels only to a platform in orbit: travel {to = {platform = ...}},"
      .. " route it with set_platform_route, then travel to " .. task._to)
  end
  return resolve_board(task, body, p)
end

local Runner = {}

function Runner.start(task)
  companion.require_present()
  validate(task, "travel")
end

function Runner.tick(task)
  if not task._phase then
    local refused = resolve(task)
    if refused then return refused end
  end
  local phase = task._phase
  if phase == "board_wait" then
    -- A rocket ready now is taken even past the deadline.
    if task._next_check and game.tick < task._next_check and not expired(task) then return nil end
    task._next_check = game.tick + M.POLL_TICKS
    local c = companion.require_companion()
    local silo = ready_silo(c, task)
    if not silo then
      if expired(task) then
        return fail(task, "ROCKET_NOT_READY", string.format("no silo had a rocket ready within %d minutes",
          wait_ticks(task) / 3600))
      end
      return nil
    end
    task._launch = { id = task.id, silo = { x = silo.position.x, y = silo.position.y }, platform = task._platform,
      character = true }
    rocket.runner.start(task._launch)
    enter(task, "board")
    return nil
  elseif phase == "board" then
    local result = rocket.runner.tick(task._launch)
    if not result then return nil end
    if result.status ~= "done" then
      local code = result.outcome and result.outcome.code or "LAUNCH_FAILED"
      -- Another launch took the rocket first: wait for the next one.
      if code == "ROCKET_NOT_READY" then
        task._launch = nil
        enter(task, "board_wait")
        return nil
      end
      if code == "DESTINATION_NOT_IN_ORBIT" then code = "PLATFORM_NOT_IN_ORBIT" end
      return fail(task, code, (result.detail or ""):gsub("^[A-Z_]+: ", ""))
    end
    task._launch, task._launched = nil, true
    storage.travel.active = { task_id = task.id, to = task._to, since_tick = game.tick }
    enter(task, "ride")
    return nil
  elseif phase == "wait_arrival" then
    -- The arrival comes from the platform state event (a Lua read every
    -- tick); the platform itself and the deadline are checked every
    -- POLL_TICKS.
    local arrival = storage.travel.arrivals[task._platform]
    if arrival and arrival.location == task._to and arrival.tick >= task._phase_tick then return enter(task, "land") end
    if task._next_check and game.tick < task._next_check and not expired(task) then return nil end
    task._next_check = game.tick + M.POLL_TICKS
    local p = platforms.resolve(companion.require_present().force, task._platform)
    if not p then return fail(task, "UNKNOWN_PLATFORM", "the platform the body is aboard is gone") end
    if expired(task) then
      return fail(task, "ARRIVAL_TIMEOUT", string.format("platform %s did not reach %s within %d minutes; the body stays aboard",
        p.name, task._to, wait_ticks(task) / 3600))
    end
    return nil
  elseif phase == "land" then
    local body = companion.body()
    if body.state ~= "aboard_platform" or not body.platform or body.platform.index ~= task._platform then
      return fail(task, "LAND_REFUSED", "the body is no longer aboard the platform (" .. body.state .. ")")
    end
    -- It may have left already (a short stop): wait for the next arrival.
    if platforms.location(body.platform) ~= task._to then return enter(task, "wait_arrival") end
    if not body.player.land_on_planet() then
      return fail(task, "LAND_REFUSED", "the game refused the landing on " .. task._to)
    end
    task._launched = true
    storage.travel.active = { task_id = task.id, to = task._to, since_tick = game.tick }
    enter(task, "ride")
    return nil
  elseif phase == "ride" then
    local body = companion.body()
    if (body.state == "on_surface" or body.state == "aboard_platform") and body.surface_ref == task._to then
      return arrived(task)
    end
    if expired(task) then
      return fail(task, "ARRIVAL_TIMEOUT", string.format("the body did not arrive at %s within %d ticks (%s, on %s)",
        task._to, M.RIDE_TICKS, body.state, tostring(body.surface_ref)))
    end
    return nil
  end
  return fail(task, "TRAVEL_STATE", "unknown travel phase " .. tostring(phase))
end

-- The board phase walks: after a hold or a load it re-plans from where the
-- body stands.
function Runner.resume(task)
  local launch = task._launch
  if launch then
    launch._approach, launch._approach_close, launch._approach_guard = nil, nil, nil
    rocket.runner.resume(launch)
  end
end

-- Waiting for a rocket, an arrival or the end of a ride is not a stall.
function Runner.waiting(task)
  return WAITING[task._phase] == true
end

-- A cancel stops the waiting; a launch or landing already under way
-- finishes natively.
function Runner.cancelled(task)
  local active = storage.travel and storage.travel.active
  if task._launched and active and active.task_id == task.id then
    active.cancelled = true
    return { code = "CANCELLED_AFTER_LAUNCH", cancelled_after_launch = true, phase = task._phase }
  end
  release(task)
  return { code = "CANCELLED", phase = task._phase }
end

-- The plan action: untagged (it moves the body between surfaces); its
-- share of the plan budget covers the longest wait and two rides.
M.action = {
  runner = Runner,
  make_task = function(step)
    return { to = step.to, _to = step._to, via_silo = step.via_silo, max_wait_minutes = step.max_wait_minutes }
  end,
  validate = function(step, index) validate(step, "queue_plan travel step " .. index) end,
  budget_steps = function(step)
    local wait = (step.max_wait_minutes or M.DEFAULT_WAIT_MINUTES) * 3600
    return math.ceil((wait + 3 * M.RIDE_TICKS) / 720)
  end,
}

return M
