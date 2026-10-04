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

-- Every read-only RPC result carries the body's FIFO state from the same Lua
-- read, so a reader sees an idle body without another round trip.
-- idle_seconds is 0 while work or hand-crafting runs, counts from when the
-- last of either ended, and is absent when no physical task has finished
-- since load or the last emergency stop.
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
  -- human_control: The owner's control input holds the body and the FIFO is parked,
  -- which is neither idleness nor failure; human_idle_ticks counts since it.
  -- A failed read never holds.
  local ok, human_control, human_idle_ticks = pcall(companion.human_control)
  human_control = ok and human_control == true
  if not ok then human_idle_ticks = nil end
  return { active_plan_id = active and active.type == "plan" and active.id or nil,
    queue_depth = depth, idle_seconds = idle_seconds,
    human_control = human_control, human_idle_ticks = human_idle_ticks }
end
local function read(handler)
  return function(params)
    local result = handler(params)
    if type(result) == "table" and result[1] == nil then result.fifo = fifo_state() end
    return result
  end
end

rpc.register("ping", read(function()
  return {
    protocol_version = 23,
    mod_version = script.active_mods["agentic-companion"],
    factorio_version = script.active_mods["base"],
    tick = game.tick,
    companion_exists = companion.get() ~= nil,
    companion_ever_created = companion.record() ~= nil,
    companion_dead = companion.record() ~= nil and companion.get() == nil,
  }
end))
rpc.register("spawn_companion", companion.connect)
rpc.register("observe_local", read(spatial.observe_local))
rpc.register("inspect", read(inspect.inspect))
rpc.register("start_research", research.start_research)
rpc.register("can_place", read(spatial.can_place))
rpc.register("find_placement", read(find_placement.find_placement))
rpc.register("map_summary", read(map_summary.map_summary))
rpc.register("production_requirements", read(production_requirements.production_requirements))
rpc.register("run_snapshot", run_snapshot.capture)
rpc.register("connect_entities", connect_entities.connect_entities)
rpc.register("describe_prototype", read(spatial.describe_prototype))
rpc.register("progression_status", read(research.progression_status))
rpc.register("enqueue", tasks.enqueue)
rpc.register("get_task", read(tasks.get))
rpc.register("queue_plan", tasks.queue_plan)
rpc.register("plan_status", read(tasks.plan_status))
rpc.register("cancel", tasks.cancel)
-- get_chunk is registered inside rpc.lua itself.

remote.add_interface("agentic", {
  rpc = function(method, params_json)
    rpc.dispatch(method, params_json)
  end,
})

local function initialize()
  state.init()
  tasks.set_observer(spatial.observe_local)
  companion.enforce_peaceful_world()
  for _, player in pairs(game.connected_players) do
    companion.on_player_available({ player_index = player.index })
  end
  companion.enforce_normal_speed()
end
tasks.set_observer(spatial.observe_local)

script.on_init(initialize)
script.on_configuration_changed(initialize)
script.on_nth_tick(120, function()
  companion.update_map_tag()
end)
script.on_event(defines.events.on_tick, function(event)
  tasks.on_tick(event)
  companion.follow_spectators()
end)
script.on_event(defines.events.on_script_path_request_finished, walk.on_path_finished)
script.on_event(defines.events.on_player_created, companion.on_player_available)
script.on_event(defines.events.on_player_joined_game, companion.on_player_available)
script.on_event(defines.events.on_player_left_game, companion.on_player_left)
script.on_event(defines.events.on_player_died, companion.on_player_died)
script.on_event(defines.events.on_player_respawned, companion.on_player_respawned)
-- Human takeover: real control input on the Codex client (data.lua's linked
-- custom inputs, and any GUI it opens) parks the FIFO.
for _, control in ipairs(human_inputs.controls) do
  script.on_event(human_inputs.input_name(control), companion.on_human_input)
end
script.on_event(defines.events.on_gui_opened, companion.on_human_input)
script.on_event(defines.events.on_surface_created, companion.enforce_peaceful_world)
if defines.events.on_player_removed then
  script.on_event(defines.events.on_player_removed, companion.on_player_removed)
end
