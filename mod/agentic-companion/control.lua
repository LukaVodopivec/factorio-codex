local state = require("scripts.state")
local rpc = require("scripts.rpc")
local companion = require("scripts.companion")
local tasks = require("scripts.tasks")
local inspect = require("scripts.inspect")
local research = require("scripts.research")
local walk = require("scripts.actions.walk")
local spatial = require("scripts.spatial")

rpc.register("ping", function()
  return {
    protocol_version = 5,
    mod_version = script.active_mods["agentic-companion"],
    factorio_version = script.active_mods["base"],
    tick = game.tick,
    companion_exists = companion.get() ~= nil,
    companion_ever_created = companion.record() ~= nil,
    companion_dead = companion.record() ~= nil and companion.get() == nil,
    companion_movement_speed = companion.movement_speed_multiplier(),
  }
end)
rpc.register("spawn_companion", companion.spawn)
rpc.register("observe_local", spatial.scan_area)
rpc.register("inspect", inspect.inspect)
rpc.register("start_research", research.start_research)
rpc.register("can_place", spatial.can_place)
rpc.register("describe_prototype", spatial.describe_prototype)
rpc.register("enqueue", tasks.enqueue)
rpc.register("get_task", tasks.get)
rpc.register("cancel", tasks.cancel)
-- get_chunk and echo are registered inside rpc.lua itself.

remote.add_interface("agentic", {
  rpc = function(method, params_json)
    rpc.dispatch(method, params_json)
  end,
})

local function initialize()
  state.init()
  companion.apply_movement_speed()
end

script.on_init(initialize)
script.on_configuration_changed(initialize)
script.on_event(defines.events.on_runtime_mod_setting_changed, companion.on_runtime_setting_changed)
script.on_nth_tick(120, function()
  companion.update_map_tag()
end)
script.on_event(defines.events.on_tick, tasks.on_tick)
script.on_event(defines.events.on_script_path_request_finished, walk.on_path_finished)
