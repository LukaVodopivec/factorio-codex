-- travel (actions/travel.lua): the body itself goes to another surface. On
-- a planet it boards a platform in orbit (readiness decided before any
-- walking; it waits for a ready rocket; the board is launch_rocket's engine
-- with the character); aboard it waits for the platform to arrive (the
-- platform state event), lands and rides down. Every refusal has its code;
-- each phase is a travel_phase event. The body states come from a stub
-- companion; the rocket engine is a stub that records what it was asked.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

_G.storage = { space = { created = {}, events = {} }, travel = { arrivals = {} } }
_G.game = { tick = 1000 }
_G.defines = {
  rocket_silo_status = { building_rocket = 1, rocket_ready = 10 },
  space_platform_state = { waiting_for_starter_pack = 0, starter_pack_requested = 1, starter_pack_on_the_way = 2,
    on_the_path = 3, waiting_at_station = 4, no_schedule = 5 },
}

local unlocked = { nauvis = true, vulcanus = true }
local force = { name = "player", is_space_location_unlocked = function(name) return unlocked[name] == true end }
local nauvis_surface = { valid = true, index = 1, name = "nauvis", planet = { name = "nauvis" } }
local vulcanus_surface = { valid = true, index = 6, name = "vulcanus", planet = { name = "vulcanus" } }
_G.game.planets = { nauvis = { surface = nauvis_surface }, vulcanus = {}, gleba = {} }

local records = {}
local schedule = { get_records = function() return records end, current = 1 }
local function platform(values)
  values.valid, values.scheduled_for_deletion, values.force = true, 0, force
  return values
end
local hub = { valid = true }
local alpha = platform({ index = 1, name = "alpha", state = defines.space_platform_state.waiting_at_station,
  space_location = { name = "nauvis" }, hub = hub, get_schedule = function() return schedule end })
local beta = platform({ index = 2, name = "beta", state = defines.space_platform_state.waiting_for_starter_pack })
local gamma = platform({ index = 3, name = "gamma", state = defines.space_platform_state.waiting_at_station,
  space_location = { name = "vulcanus" }, hub = { valid = true } })
force.platforms = { [1] = alpha, [2] = beta, [3] = gamma }
local alpha_surface = { valid = true, index = 5, name = "platform-1", platform = alpha }

-- The body: a state the test sets; the character stands on Nauvis.
local character = { valid = true, position = { x = 0, y = 0 }, surface = nauvis_surface, force = force }
local landings, land_ok = 0, true
local player = { land_on_planet = function() landings = landings + 1; return land_ok end }
local state = "on_surface"
local function body()
  if state == "on_surface" then
    return { state = state, player = player, character = character, surface = character.surface, force = force,
      surface_ref = character.surface.name, position = character.position }
  elseif state == "aboard_platform" then
    return { state = state, player = player, surface = alpha_surface, surface_ref = "platform:1", platform = alpha,
      force = force, position = { x = 0, y = 0 } }
  end
  return { state = state, player = player, force = force, surface_ref = "nauvis", position = { x = 0, y = 0 } }
end
package.loaded["scripts.companion"] = {
  body = body, get = function() return state == "on_surface" and character or nil end,
  require_companion = function()
    if state ~= "on_surface" then error("BODY_" .. state:upper() .. ": not on a surface", 0) end
    return character
  end,
  require_present = function() return body() end,
}
-- Silos from the registry; the rocket engine records its tasks.
local silo = { valid = true, position = { x = 30, y = 0 }, rocket_silo_status = defines.rocket_silo_status.building_rocket }
local registry_silos = { { entity = silo } }
package.loaded["scripts.registry"] = { machines = function(types)
  assert(types[1] == "rocket-silo")
  return registry_silos
end }
local launches, launch_results = {}, {}
local carries = true
package.loaded["scripts.actions.rocket"] = {
  find_silo = function(_, at) return at.x == silo.position.x and silo or nil end,
  carries_to_platforms = function() return carries end,
  runner = {
    start = function(task) launches[#launches + 1] = task end,
    tick = function()
      local r = table.remove(launch_results, 1)
      -- Another launch took the rocket: the silo builds the next one.
      if r and r.outcome.code == "ROCKET_NOT_READY" then silo.rocket_silo_status = defines.rocket_silo_status.building_rocket end
      return r
    end,
    resume = function() end,
  },
}
local travel = require("scripts.actions.travel")
local platforms = require("scripts.platforms")
local runner = travel.action.runner

local function start(step)
  travel.action.validate(step, 1)
  local task = travel.action.make_task(step)
  task.id, task.type = 7, "travel"
  runner.start(task)
  return task
end
local function tick(task, n)
  for _ = 1, n or 1 do
    local result = runner.tick(task)
    if result then return result end
    game.tick = game.tick + 1
  end
end
local function phases(result)
  local names = {}
  for _, row in ipairs(result.outcome.phases) do names[#names + 1] = row.phase end
  return table.concat(names, ",")
end

-- Validation.
local step = { action = "travel", to = { platform = "alpha" } }
travel.action.validate(step, 1)
check(step._to == "platform:1", "the destination is kept canonical")
check(not pcall(travel.action.validate, { to = "mars" }, 1) and not pcall(travel.action.validate, { to = "nauvis", via_silo = 3 }, 1)
  and not pcall(travel.action.validate, { to = "nauvis", max_wait_minutes = 0 }, 1)
  and travel.action.budget_steps({ max_wait_minutes = 60 }) >= 300,
  "an unknown destination, a bad via_silo or wait is refused; the step budget covers the wait")

-- Same surface: plain success, nothing done.
local result = tick(start({ to = "nauvis" }))
check(result.status == "done" and result.outcome.arrived and result.outcome.from == "nauvis" and #result.outcome.phases == 0,
  "travel to the body's own surface succeeds at once")

-- Refusals before any walking.
local function refused(to, code, extra)
  launches = {}
  local s = { to = to }
  for k, v in pairs(extra or {}) do s[k] = v end
  local r = tick(start(s))
  return r and r.status == "failed" and r.outcome.code == code and #launches == 0 and r.outcome.arrived == false
end
check(refused("vulcanus", "NO_ROUTE"), "from a planet the body travels only to a platform: NO_ROUTE")
check(refused({ platform = "beta" }, "PLATFORM_NOT_IN_ORBIT"), "a platform without its hub cannot be boarded")
check(refused({ platform = "gamma" }, "PLATFORM_NOT_IN_ORBIT"), "a platform over another planet cannot be boarded")
registry_silos = {}
check(refused({ platform = "alpha" }, "NO_SILO"), "no silo on the surface: NO_SILO")
registry_silos = { { entity = silo } }
check(refused({ platform = "alpha" }, "NO_SILO", { via_silo = { x = 99, y = 0 } }), "no silo at via_silo: NO_SILO")
carries = false
check(refused({ platform = "alpha" }, "SILO_NOT_FOR_PLATFORMS"), "a silo that cannot carry the body is refused")
carries = true

-- Boarding: no rocket ready, so it waits (a deliberate wait), boards when
-- one is, waits again when another launch took the rocket first, then rides
-- up until the body is aboard the platform.
storage.space.events = {}
local task = start({ to = { platform = "alpha" }, max_wait_minutes = 1 })
check(tick(task, 120) == nil and task._phase == "board_wait" and runner.waiting(task) and #launches == 0,
  "with no rocket ready the step waits, polling the silos")
silo.rocket_silo_status = defines.rocket_silo_status.rocket_ready
launch_results = { { status = "failed", detail = "ROCKET_NOT_READY: gone", outcome = { code = "ROCKET_NOT_READY" } } }
tick(task, 61)
check(#launches == 1 and launches[1].character == true and launches[1].platform == 1 and launches[1].silo.x == 30
  and task._phase == "board_wait", "a ready rocket is boarded through launch_rocket's engine; a lost race waits again")
silo.rocket_silo_status = defines.rocket_silo_status.rocket_ready
launch_results = { { status = "done", detail = "launched", outcome = { code = "ROCKET_LAUNCHED" } } }
tick(task, 61)
check(task._phase == "ride" and storage.travel.active.task_id == 7 and not runner.waiting({ _phase = "board" }),
  "after the launch the body rides; the launch counts as transit")
state = "in_transit"
check(tick(task, 30) == nil, "in the rocket the step keeps waiting")
state = "aboard_platform"
result = tick(task)
check(result.status == "done" and result.outcome.code == "ARRIVED" and result.outcome.to == "platform:1"
  and result.outcome.state == "aboard_platform" and phases(result) == "board_wait,board,board_wait,board,ride"
  and result.outcome.waited_ticks >= 180 and storage.travel.active == nil,
  "aboard the platform the trip is done, with its phases and waited ticks")
local kinds = {}
for _, row in ipairs(storage.space.events) do if row.kind == "travel_phase" then kinds[#kinds + 1] = row.phase end end
check(table.concat(kinds, ",") == "board_wait,board,board_wait,board,ride", "each phase is a travel_phase event")

-- No rocket within max_wait_minutes.
state = "on_surface"
silo.rocket_silo_status = defines.rocket_silo_status.building_rocket
task = start({ to = { platform = "alpha" }, max_wait_minutes = 1 })
result = tick(task, 3700)
check(result and result.outcome.code == "ROCKET_NOT_READY" and result.outcome.waited_ticks >= 3600,
  "no ready rocket within the wait fails ROCKET_NOT_READY")

-- A rocket ready when the deadline has passed (a hold ended past it) is
-- still taken; the deadline is its own field, which a hold moves on.
task = start({ to = { platform = "alpha" }, max_wait_minutes = 1 })
tick(task, 2)
check(task._phase == "board_wait" and task._deadline_tick == task._phase_tick + 3600,
  "a waiting phase keeps its deadline in its own field")
game.tick = task._deadline_tick + 500
silo.rocket_silo_status = defines.rocket_silo_status.rocket_ready
launches = {}
launch_results = {}
check(tick(task) == nil and #launches == 1 and task._phase == "board",
  "a rocket ready past the deadline is boarded, not refused")
launch_results = { { status = "done", detail = "launched", outcome = { code = "ROCKET_LAUNCHED" } } }
tick(task)
storage.travel.active = nil
silo.rocket_silo_status = defines.rocket_silo_status.building_rocket

-- Aboard, to a planet: locked, not on the schedule, another platform.
state = "aboard_platform"
alpha.space_location = nil
alpha.space_connection = { name = "nauvis-vulcanus" }
unlocked.vulcanus = false
check(refused("vulcanus", "LOCATION_LOCKED"), "a locked planet: LOCATION_LOCKED")
unlocked.vulcanus = true
check(refused("vulcanus", "NO_ROUTE"), "a planet the platform's schedule does not name: NO_ROUTE at once")
check(refused({ platform = "gamma" }, "NO_ROUTE"), "between platforms the body goes only through a planet")

-- Waiting for the arrival, then landing.
records = { { station = "nauvis" }, { station = "vulcanus" } }
task = start({ to = "vulcanus", max_wait_minutes = 2 })
check(tick(task, 200) == nil and task._phase == "wait_arrival" and runner.waiting(task),
  "a scheduled stop: the body waits aboard for the arrival")
local resolve, resolves = platforms.resolve, 0
platforms.resolve = function(...) resolves = resolves + 1; return resolve(...) end
tick(task, 600)
check(resolves <= 11, "waiting for the arrival looks the platform up once a second, not every tick (" .. resolves .. ")")
platforms.resolve = resolve
alpha.space_location, alpha.space_connection = { name = "vulcanus" }, nil
platforms.on_platform_state_changed({ platform = alpha, old_state = defines.space_platform_state.on_the_path })
tick(task, 2)
check(landings == 1 and task._phase == "ride" and storage.travel.active.to == "vulcanus",
  "the platform's arrival event lands the body at once")
check(runner.cancelled(task, true) == nil and storage.travel.active and not storage.travel.active.cancelled,
  "the stall watchdog's body-only cancel leaves a travel's ride marker alone")
state = "in_transit"
tick(task, 5)
character.surface = vulcanus_surface
state = "on_surface"
result = tick(task)
check(result.status == "done" and result.outcome.to == "vulcanus" and result.outcome.state == "on_surface"
  and phases(result) == "wait_arrival,land,ride", "standing on the planet the trip is done")

-- Already there: lands at once; a refused landing; a missed arrival.
state = "aboard_platform"
land_ok = false
result = tick(start({ to = "vulcanus" }), 3)
check(result and result.outcome.code == "LAND_REFUSED" and landings == 2, "a refused landing fails LAND_REFUSED")
land_ok = true
alpha.space_location, alpha.space_connection = nil, { name = "vulcanus-nauvis" }
task = start({ to = "vulcanus", max_wait_minutes = 1 })
result = tick(task, 3700)
check(result and result.outcome.code == "ARRIVAL_TIMEOUT" and result.outcome.state == "aboard_platform",
  "no arrival within the wait fails ARRIVAL_TIMEOUT with the body still aboard")
-- A ride that never ends.
alpha.space_location, alpha.space_connection = { name = "vulcanus" }, nil
task = start({ to = "vulcanus" })
tick(task, 2)
state = "in_transit"
result = tick(task, travel.RIDE_TICKS + 5)
check(result and result.outcome.code == "ARRIVAL_TIMEOUT" and storage.travel.active == nil,
  "a ride that does not arrive within 7,200 ticks fails ARRIVAL_TIMEOUT")
-- Waiting aboard reads the platform at every poll: its facts (state, speed,
-- location, thrusters, the stop it heads for, the deadline) are in the
-- travel_phase event and in M.facts, which plan_status and active_task show.
defines.entity_status = { working = 1, no_fuel = 2 }
local thrusters = { { status = defines.entity_status.working } }
alpha.surface = { valid = true, find_entities_filtered = function(filter)
  assert(filter.type == "thruster" and filter.force == force)
  return thrusters
end }
alpha.state = defines.space_platform_state.on_the_path
alpha.space_location, alpha.space_connection, alpha.speed = nil, { name = "nauvis-vulcanus" }, 0.5
records = { { station = "nauvis" }, { station = "vulcanus", wait_conditions = { { type = "time" } } } }
schedule.current = 2
state = "aboard_platform"
task = start({ to = "vulcanus", max_wait_minutes = 30 })
tick(task, 2)
local facts = travel.facts(task)
check(facts and facts.phase == "wait_arrival" and facts.to == "vulcanus" and facts.deadline_tick == task._deadline_tick
  and facts.platform.state == "on_the_path" and facts.platform.speed == 0.5 and facts.platform.location == nil
  and facts.platform.thrusters.count == 1 and facts.platform.thrusters.working == 1
  and facts.platform.current_stop.station == "vulcanus" and facts.platform.current_stop.wait_conditions == 1,
  "a waiting step keeps the platform's state, speed, location, thrusters and its deadline")
local phase_row = storage.space.events[#storage.space.events]
check(phase_row.kind == "travel_phase" and phase_row.phase == "wait_arrival" and phase_row.deadline_tick == task._deadline_tick
  and phase_row.platform.thrusters.working == 1, "the travel_phase event carries the deadline and the platform's facts")
check(travel.facts({ type = "walk_to" }) == nil, "only a travel step has travel facts")

-- The only thruster is lost: a moment of stillness is no stall, standing
-- still for STUCK_POLLS polls is PLATFORM_CANNOT_MOVE; a paused platform is
-- held, never stuck.
thrusters, alpha.speed = {}, 0
check(tick(task, 60 * 4) == nil and task._stuck ~= nil, "a few still polls do not fail the wait")
alpha.speed = 0.2
tick(task, 61)
check(task._stuck == nil, "moving again clears the stillness count")
alpha.speed, alpha.paused = 0, true
check(tick(task, 61 * (travel.STUCK_POLLS + 2)) == nil and task._stuck == nil, "a paused platform is held, not stuck")
alpha.paused = false
result = tick(task, 61 * (travel.STUCK_POLLS + 2))
check(result and result.status == "failed" and result.outcome.code == "PLATFORM_CANNOT_MOVE"
  and result.outcome.platform.thrusters.count == 0 and result.outcome.state == "aboard_platform"
  and result.detail:find("between locations", 1, true), "no working thruster and standing still fails PLATFORM_CANNOT_MOVE")
-- Thrusters without fuel between locations are as stuck; at a stop with
-- idle thrusters the platform only waits for its wait conditions.
thrusters = { { status = defines.entity_status.no_fuel } }
task = start({ to = "vulcanus", max_wait_minutes = 30 })
result = tick(task, 61 * (travel.STUCK_POLLS + 2))
check(result and result.outcome.code == "PLATFORM_CANNOT_MOVE", "unfuelled thrusters between locations cannot move it")
alpha.space_location, alpha.space_connection = { name = "nauvis" }, nil
alpha.state = defines.space_platform_state.waiting_at_station
task = start({ to = "vulcanus", max_wait_minutes = 30 })
check(tick(task, 61 * (travel.STUCK_POLLS + 2)) == nil, "idle thrusters at a stop are no stall")
thrusters = {}
result = tick(task, 61 * (travel.STUCK_POLLS + 2))
check(result and result.outcome.code == "PLATFORM_CANNOT_MOVE" and result.detail:find("at nauvis", 1, true),
  "a platform with no thruster at all cannot leave its stop")

-- The route changes during the wait: NO_ROUTE at the next poll.
thrusters = { { status = defines.entity_status.working } }
alpha.space_location, alpha.space_connection, alpha.speed = nil, { name = "nauvis-vulcanus" }, 0.4
task = start({ to = "vulcanus", max_wait_minutes = 30 })
tick(task, 2)
records, schedule.current = { { station = "nauvis" } }, 1
result = tick(task, 62)
check(result and result.outcome.code == "NO_ROUTE" and result.outcome.platform.current_stop.station == "nauvis"
  and result.outcome.state == "aboard_platform", "a destination dropped from the schedule ends the wait NO_ROUTE")

-- A refused landing carries the platform's facts.
records, schedule.current = { { station = "nauvis" }, { station = "vulcanus" } }, 2
alpha.space_location, alpha.space_connection, alpha.speed = { name = "vulcanus" }, nil, 0
alpha.state = defines.space_platform_state.waiting_at_station
land_ok = false
result = tick(start({ to = "vulcanus" }), 3)
check(result and result.outcome.code == "LAND_REFUSED" and result.outcome.platform.location == "vulcanus"
  and result.outcome.platform.state == "waiting_at_station" and result.outcome.platform.hub == true
  and result.outcome.platform.paused == false and result.outcome.platform.current_stop.index == 2
  and result.outcome.platform.current_stop.wait_conditions == 0
  and result.detail:find("heads for is 2 (vulcanus) with 0 wait conditions", 1, true),
  "LAND_REFUSED names the platform's state, location, paused, hub and the stop it heads for")
land_ok = true

-- Boarding a platform on its way here: board_wait waits for it (no launch
-- meanwhile), boards once it is over the planet; a platform that turns away
-- fails PLATFORM_NOT_IN_ORBIT.
state, character.surface = "on_surface", nauvis_surface
alpha.space_location, alpha.space_connection, alpha.speed = nil, { name = "nauvis-vulcanus" }, 0.4
alpha.state = defines.space_platform_state.on_the_path
records, schedule.current = { { station = "nauvis" }, { station = "vulcanus" } }, 1
silo.rocket_silo_status = defines.rocket_silo_status.rocket_ready
launches, launch_results = {}, {}
task = start({ to = { platform = "alpha" }, max_wait_minutes = 5 })
check(tick(task, 130) == nil and task._phase == "board_wait" and #launches == 0 and travel.facts(task).platform.location == nil,
  "a platform heading for this planet is waited for in board_wait, with no launch")
alpha.space_location, alpha.space_connection = { name = "nauvis" }, nil
tick(task, 61)
check(#launches == 1 and task._phase == "board", "once over the planet the ready rocket boards it")
alpha.space_location, alpha.space_connection = nil, { name = "nauvis-vulcanus" }
task = start({ to = { platform = "alpha" }, max_wait_minutes = 5 })
tick(task, 2)
schedule.current = 2
result = tick(task, 62)
check(result and result.outcome.code == "PLATFORM_NOT_IN_ORBIT" and result.outcome.platform.current_stop.station == "vulcanus",
  "a platform that no longer heads here fails PLATFORM_NOT_IN_ORBIT with its facts")
check(refused({ platform = "alpha" }, "PLATFORM_NOT_IN_ORBIT"), "a platform elsewhere heading elsewhere is refused at once")
-- Waiting at another stop whose next record is this planet: it returns, so
-- it is waited for; paused there, it goes nowhere and is refused.
alpha.space_location, alpha.space_connection, alpha.speed = { name = "vulcanus" }, nil, 0
alpha.state = defines.space_platform_state.waiting_at_station
launches = {}
task = start({ to = { platform = "alpha" }, max_wait_minutes = 5 })
check(tick(task, 130) == nil and task._phase == "board_wait" and #launches == 0,
  "a platform waiting at a stop before this planet is waited for in board_wait")
alpha.paused = true
check(refused({ platform = "alpha" }, "PLATFORM_NOT_IN_ORBIT"), "a paused platform at another stop is refused at once")
alpha.paused = false
silo.rocket_silo_status = defines.rocket_silo_status.building_rocket

state = "dead"
check(not pcall(runner.tick, start({ to = "vulcanus" })), "a body that is neither on a surface nor aboard fails with its state")

os.exit(failures == 0 and 0 or 1)
