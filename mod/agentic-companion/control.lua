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

rpc.register("ping", function()
  return {
    protocol_version = 16,
    mod_version = script.active_mods["agentic-companion"],
    factorio_version = script.active_mods["base"],
    tick = game.tick,
    companion_exists = companion.get() ~= nil,
    companion_ever_created = companion.record() ~= nil,
    companion_dead = companion.record() ~= nil and companion.get() == nil,
  }
end)
rpc.register("spawn_companion", companion.connect)
rpc.register("observe_local", spatial.observe_local)
rpc.register("inspect", inspect.inspect)
rpc.register("start_research", research.start_research)
rpc.register("can_place", spatial.can_place)
rpc.register("find_placement", find_placement.find_placement)
rpc.register("map_summary", map_summary.map_summary)
rpc.register("production_requirements", production_requirements.production_requirements)
rpc.register("connect_entities", connect_entities.connect_entities)
rpc.register("describe_prototype", spatial.describe_prototype)
rpc.register("progression_status", research.progression_status)
rpc.register("enqueue", tasks.enqueue)
rpc.register("get_task", tasks.get)
rpc.register("queue_plan", tasks.queue_plan)
rpc.register("plan_status", tasks.plan_status)
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
script.on_event(defines.events.on_surface_created, companion.enforce_peaceful_world)
if defines.events.on_player_removed then
  script.on_event(defines.events.on_player_removed, companion.on_player_removed)
end
