local state = require("scripts.state")
local rpc = require("scripts.rpc")
local companion = require("scripts.companion")
local tasks = require("scripts.tasks")
local inspect = require("scripts.inspect")
local research = require("scripts.research")
local walk = require("scripts.actions.walk")
local spatial = require("scripts.spatial")
local find_placement = require("scripts.find_placement")
local map_summary = require("scripts.map_summary")
local production_requirements = require("scripts.production_requirements")
local connect_entities = require("scripts.connect_entities")
local run_snapshot = require("scripts.run_snapshot")
local human_inputs = require("scripts.human_inputs")
local autonomy = require("scripts.autonomy")
local factory_status = require("scripts.factory_status")
local thoughts = require("scripts.thoughts")
local timelapse = require("scripts.timelapse")
local chores = require("scripts.chores")
local registry = require("scripts.registry")
local surfaces = require("scripts.surfaces")
local jobs = require("scripts.jobs")
local build_layout = require("scripts.actions.build_layout")
local blueprints = require("scripts.blueprints")
local area_ops = require("scripts.actions.area_ops")
local tiles = require("scripts.actions.tiles")
local factory_activity = require("scripts.factory_activity")
local platforms = require("scripts.platforms")
local requests = require("scripts.requests")
local configure = require("scripts.actions.configure")
local build = require("scripts.actions.build")
local timing = require("scripts.profiler")
local benchmark = require("scripts.benchmark")
local errors = require("scripts.errors")
local journal = require("scripts.journal")
benchmark.on_freeze = thoughts.refresh

-- Where the body is ({state, surface_ref, platform_name?, rebind_refused?},
-- companion.body_summary) and, while a travel step is pending in the FIFO,
-- bound_for: the last such step's destination (the bridge holds a package
-- for the old surface meanwhile).
local function body_summary()
  local summary = companion.body_summary()
  summary.bound_for = tasks.bound_for()
  return summary
end

-- Every read-only RPC result carries the body's FIFO state from the same Lua
-- read, so a reader sees an idle body without another round trip.
-- idle_seconds is 0 while work or hand-crafting runs, counts from when the
-- last of either ended, and is absent when no physical task has finished
-- since load or the last emergency stop (one with keep_upkeep starts it).
-- upkeep_off_since_tick is that stop's tick while it keeps upkeep off.
local function fifo_state()
  local t = storage.tasks
  if not t then return nil end
  local active, depth = t.active, #(t.queue or {})
  local body = companion.get()
  local crafting = body and body.valid and (body.crafting_queue_size or 0) > 0
  local idle_seconds
  if active or depth > 0 or crafting then
    idle_seconds = 0
  elseif t.last_finished_tick then
    idle_seconds = math.floor(math.max(0, game.tick - t.last_finished_tick) / 60)
  end
  -- human_control: the player's control input holds the body and the FIFO is parked,
  -- which is neither idleness nor failure; human_idle_ticks counts since it.
  -- A failed read never holds.
  local ok, human_control, human_idle_ticks = pcall(companion.human_control)
  human_control = ok and human_control == true
  if not ok then human_idle_ticks = nil end
  return { active_plan_id = active and active.type == "plan" and active.id or nil,
    queue_depth = depth, idle_seconds = idle_seconds,
    upkeep_off_since_tick = not t.last_finished_tick and t.last_cancel_all_tick or nil,
    human_control = human_control, human_idle_ticks = human_idle_ticks,
    -- Where the body is (body_summary).
    body = body_summary() }
end
local function read(handler)
  return function(params)
    local result = handler(params)
    if type(result) == "table" and result[1] == nil then result.fifo = fifo_state() end
    return result
  end
end

-- A body away on a trip (aboard a platform, in a cargo pod) still exists:
-- the player is connected with the body away.
local BODY_EXISTS = { on_surface = true, aboard_platform = true, in_transit = true }
rpc.register("ping", read(function()
  local exists = BODY_EXISTS[companion.body().state] == true
  return {
    protocol_version = 29,
    mod_version = script.active_mods["agentic-companion"],
    factorio_version = script.active_mods["base"],
    tick = game.tick,
    companion_exists = exists,
    companion_ever_created = companion.record() ~= nil,
    companion_dead = companion.record() ~= nil and not exists,
    -- The last world-policy writes that failed (per surface), if any.
    world_policy_errors = companion.world_policy_errors(),
    -- Errors a handler raised and a dispatcher caught: {count, recent}
    -- (errors.summary), absent before the first.
    handler_errors = errors.summary(),
    -- Where the body is (body_summary).
    body = body_summary(),
  }
end))
rpc.register("spawn_companion", companion.connect)
-- Heavy reads are jobs (jobs.lua): the RPC answers at once with the result
-- when it fits what is left of this tick's work, else with {job_id,
-- job_status = "pending"}; get_job {job_id} then returns it once done.
-- build_layout over RPC is a check_only dry run; the build itself is a plan
-- step.
jobs.register("observe_local", spatial.observe_job)
jobs.register("map_summary", map_summary.summary_job)
jobs.register("connect_entities", connect_entities.job)
jobs.register("build_layout", build_layout.layout_check_job)
-- Blueprints (blueprints.lua): capture and describe read up to a blueprint's
-- worth of entities; blueprint_place over RPC is its check_only dry run.
jobs.register("blueprint_capture", blueprints.capture_job)
jobs.register("blueprint_describe", blueprints.describe_job)
jobs.register("blueprint_place", area_ops.place_check_job)
-- place_tiles over RPC is its check_only dry run: two work items per tile read.
jobs.register("place_tiles", tiles.check_job)
-- inspect reads about 15 entities a tick.
jobs.register("inspect", inspect.job)
-- platform_status compact is attribute reads; full reads one platform's
-- foundation and entities over ticks.
jobs.register("platform_status", platforms.status_job)
-- run_snapshot (the run recorder's sample) reads one surface's statistics a
-- step; it carries no fifo block.
jobs.register("run_snapshot", run_snapshot.job)
rpc.register("run_snapshot", jobs.rpc("run_snapshot"))
rpc.register("benchmark_control", benchmark.control)
rpc.register("timelapse", timelapse.rpc)
for _, kind in ipairs({ "observe_local", "inspect", "map_summary", "connect_entities", "build_layout",
  "blueprint_capture", "blueprint_describe", "blueprint_place", "place_tiles", "platform_status" }) do
  rpc.register(kind, read(jobs.rpc(kind)))
end
rpc.register("blueprint_create", blueprints.create)
rpc.register("blueprint_list", read(blueprints.list))
rpc.register("blueprint_delete", blueprints.delete)
rpc.register("blueprint_export", read(blueprints.export))
blueprints.set_logger(tasks.log_event)
research.set_logger(tasks.log_event)
rpc.register("get_job", read(jobs.get))
rpc.register("start_research", research.start_research)
-- Remote actions on space platforms run at once, like start_research: the
-- platform window needs no body (each refuses a planet target, which needs
-- the body: a plan step). launch_rocket needs the body (a plan step).
rpc.register("create_platform", platforms.create_platform)
rpc.register("set_platform_route", platforms.set_platform_route)
-- travel moves the body: the direct tool queues it as a pilot plan and
-- answers at once with the plan; plan_status and next_event follow it.
rpc.register("travel", function(params)
  local step = { action = "travel", to = params.to, via_silo = params.via_silo, max_wait_minutes = params.max_wait_minutes }
  local queued = tasks.queue_plan({ steps = { step } })
  queued.to = step._to
  return queued
end)
rpc.register("set_requests", requests.rpc)
rpc.register("configure_entity", configure.rpc)
rpc.register("set_recipe", build.set_recipe_rpc)
rpc.register("can_place", read(spatial.can_place))
rpc.register("find_placement", read(find_placement.find_placement))
rpc.register("production_requirements", read(production_requirements.production_requirements))
rpc.register("describe_prototype", read(spatial.describe_prototype))
rpc.register("progression_status", read(research.progression_status))
rpc.register("enqueue", tasks.enqueue)
rpc.register("get_task", read(tasks.get))
rpc.register("queue_plan", tasks.queue_plan)
rpc.register("plan_status", read(tasks.plan_status))
rpc.register("cancel", tasks.cancel)
rpc.register("factory_status", read(factory_status.factory_status))
rpc.register("activity_log", read(tasks.activity_log))
rpc.register("event_state", factory_status.event_state)
thoughts.register_rpcs(rpc)
-- get_chunk is registered inside rpc.lua itself.

remote.add_interface("agentic", {
  rpc = function(method, params_json)
    rpc.dispatch(method, params_json)
  end,
})

-- The body moved (multi-surface rules): a rebind where the character may
-- have changed, then, when its physical surface changed, the surface cancel
-- rule and body_surface_changed in the space event ring, and when it now
-- stands on a surface it did not stand on before (also after a pod landed
-- it on a surface already seen in transit) the world policy and one chart
-- around it. The remote view moving to another surface is no move: the
-- physical surface is compared. Without an event (a load) it only records
-- or compares the surface. It never raises into the event that moved the
-- body.
local function move_body(event)
  local rec = companion.record()
  if not (rec and rec.player_index) then return end
  if event then
    if event.player_index ~= rec.player_index then return end
    companion.rebind(event)
  end
  local change = companion.note_body_surface()
  if not change then return end
  if change.changed then
    tasks.on_body_surface_changed(change)
    platforms.record("body_surface_changed", { from = change.from, to = change.to, state = change.state })
  end
  if change.arrived then
    companion.enforce_peaceful_world({ surface_index = change.surface_index })
    chores.on_arrival(change)
  end
end
local function body_moved(event)
  local ok, err = pcall(move_body, event)
  if ok then return end
  local message = errors.record("event:body_moved", err)
  if log then pcall(log, "[agentic-companion] body move handling failed: " .. message) end
end
local function initialize()
  state.init()
  -- state.init dropped any pending path request: the active step re-plans.
  tasks.resume_active()
  tasks.set_observer(spatial.observe_compact)
  companion.enforce_peaceful_world()
  for _, player in pairs(game.connected_players) do
    companion.on_player_available({ player_index = player.index })
  end
  body_moved(nil)
  companion.enforce_normal_speed()
  -- An upgrade keeps the old version's GUI elements: rebuild the panel.
  thoughts.init()
end
tasks.set_observer(spatial.observe_compact)
tasks.set_upkeep_listener(chores.on_upkeep_step)
tasks.set_boundary_upkeep(chores.boundary_upkeep)

script.on_init(initialize)
script.on_configuration_changed(initialize)
-- One handler per period: on_nth_tick replaces an earlier registration.
-- chores.on_nth is {[period] = function(event)}.
local nth = { [120] = { function() companion.update_map_tag() end } }
for period, handler in pairs(chores.on_nth) do
  nth[period] = nth[period] or {}
  table.insert(nth[period], handler)
end
for period, handlers in pairs(nth) do
  script.on_nth_tick(period, function(event)
    timing.measure(function()
      for _, handler in ipairs(handlers) do handler(event) end
    end)
  end)
end
-- Tick work is bounded by item budgets: the registry bootstrap and then the
-- patch cache read a few chunks a tick, the line sampler about machines/30,
-- and read jobs share one allowance with the build search.
local function tick(event)
  if benchmark.on_tick(event.tick) then jobs.on_tick(); return end
  tasks.on_tick(event)
  registry.on_tick(event.tick)
  -- Patch work starts the tick after the registry is ready, never on the
  -- tick that finishes the bootstrap and runs the first line refresh.
  if registry.ready() and (storage.registry.ready_tick or 0) < event.tick then
    map_summary.patch_tick(event.tick)
    map_summary.status_tick(event.tick)
  end
  autonomy.on_tick(event.tick)
  jobs.on_tick()
  companion.follow_spectators()
  if storage.benchmark and event.tick % 60 == 0 then thoughts.refresh() end
  timelapse.on_tick(event.tick)
end
script.on_event(defines.events.on_tick, function(event)
  timing.measure(tick, event)
  timing.log_ticks(event.tick)
end)
script.on_event(defines.events.on_script_path_request_finished, walk.on_path_finished)
local function player_available(event)
  companion.on_player_available(event)
  body_moved(event)
  thoughts.on_player_joined(event)
end
script.on_event(defines.events.on_player_created, player_available)
script.on_event(defines.events.on_player_joined_game, player_available)
script.on_event(defines.events.on_robot_pre_mined, tasks.on_robot_pre_mined)
-- Own entities built, cloned, mined or destroyed by anyone keep the registry
-- current; machines among them refresh the factory lines; the change journal
-- notes who did it (journal.lua). Ghosts are filtered out: none of these
-- keeps them. An own entity's death is also an own loss; the handlers check
-- the own force themselves, since it is the registry's, not fixed at load.
local NO_GHOSTS = { { filter = "ghost", invert = true } }
local function journaled(where, handler, event)
  local ok, err = pcall(handler, event)
  if not ok then errors.record("event:" .. where, err) end
end
for _, name in ipairs({ "on_built_entity", "on_robot_built_entity", "on_space_platform_built_entity",
  "script_raised_built", "script_raised_revive", "on_entity_cloned" }) do
  if defines.events[name] then
    script.on_event(defines.events[name], function(event)
      if event.name == defines.events.on_robot_built_entity then tasks.on_robot_built_entity(event) end
      registry.on_built(event)
      autonomy.on_entity_changed(event.entity and event or { entity = event.destination })
      journaled(name, journal.on_built, event)
    end, NO_GHOSTS)
  end
end
for _, name in ipairs({ "on_player_mined_entity", "on_robot_mined_entity", "on_space_platform_mined_entity",
  "on_entity_died", "script_raised_destroy" }) do
  if defines.events[name] then
    local died = name == "on_entity_died"
    script.on_event(defines.events[name], function(event)
      if event.name == defines.events.on_robot_mined_entity then tasks.on_robot_mined_entity(event) end
      registry.on_removed(event)
      autonomy.on_entity_changed(event)
      journaled(name, died and journal.on_entity_died or journal.on_removed, event)
    end, NO_GHOSTS)
  end
end
-- A player's rotation, flip (journaled as rotated) or settings paste:
-- changes the journal notes.
for name, handler in pairs({ on_player_rotated_entity = journal.on_rotated, on_player_flipped_entity = journal.on_rotated,
  on_entity_settings_pasted = journal.on_settings_pasted }) do
  if defines.events[name] then
    script.on_event(defines.events[name], function(event) journaled(name, handler, event) end)
  end
end
-- Removals no event above names (e.g. the body mining, a script destroy
-- without raise): every registered entity reports here.
script.on_event(defines.events.on_object_destroyed, function(event)
  local removed = registry.on_object_destroyed(event)
  if type(removed) == "table" and registry.is_machine(removed.type, removed.burner) then autonomy.mark_dirty() end
end)
-- factory_status keeps the available technologies until research changes.
for _, name in ipairs(factory_status.RESEARCH_EVENTS) do
  if defines.events[name] then script.on_event(defines.events[name], factory_status.on_research_changed) end
end
-- Hand-crafted items of the Codex player, counted for run_snapshot.
script.on_event(defines.events.on_player_crafted_item, factory_activity.on_player_crafted_item)
script.on_event(defines.events.on_chunk_charted, map_summary.on_chunk_charted)
script.on_event(defines.events.on_resource_depleted, map_summary.on_resource_depleted)
script.on_event(defines.events.on_player_left_game, companion.on_player_left)
script.on_event(defines.events.on_player_died, function(event)
  companion.on_player_died(event)
  body_moved(event)
end)
script.on_event(defines.events.on_player_respawned, function(event)
  companion.on_player_respawned(event)
  body_moved(event)
end)
for _, name in ipairs({ "on_player_changed_surface", "on_player_controller_changed", "on_cargo_pod_finished_ascending" }) do
  if defines.events[name] then script.on_event(defines.events[name], body_moved) end
end
-- Human takeover: real control input on the Codex client (data.lua's linked
-- custom inputs, and any GUI it opens) parks the FIFO.
for _, control in ipairs(human_inputs.controls) do
  script.on_event(human_inputs.input_name(control), companion.on_human_input)
end
script.on_event(defines.events.on_gui_opened, companion.on_human_input)
script.on_event(defines.events.on_surface_created, companion.enforce_peaceful_world)
-- A deleted surface (a platform removed) takes its registry aggregates and
-- patch cache with it; a later surface may reuse its index.
script.on_event(defines.events.on_surface_deleted, function(event)
  for _, handler in ipairs({ registry.on_surface_deleted, map_summary.on_surface_deleted, surfaces.on_surface_deleted }) do
    local ok, err = pcall(handler, event)
    if not ok then errors.record("event:on_surface_deleted", err) end
  end
end)
-- The space event ring (platforms.lua); a game without Space Age has none of
-- these events. A pod that lands with the body also moves the body.
for name, handler in pairs({ on_rocket_launch_ordered = function(event)
    platforms.on_rocket_launch_ordered(event)
    timelapse.on_rocket_launch_ordered(event)
  end,
  on_space_platform_changed_state = platforms.on_platform_state_changed,
  on_cargo_pod_finished_descending = function(event)
    platforms.on_cargo_pod_finished_descending(event)
    body_moved(event)
  end }) do
  if defines.events[name] then script.on_event(defines.events[name], handler) end
end
if defines.events.on_player_removed then
  script.on_event(defines.events.on_player_removed, companion.on_player_removed)
end
