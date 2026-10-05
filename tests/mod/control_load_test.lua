local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. here .. "/../../mod/agentic-companion/?/init.lua;" .. package.path
_G.storage = {}
_G.defines = { events = {
  on_tick = 2, on_script_path_request_finished = 3, on_player_created = 4,
  on_player_joined_game = 5, on_player_left_game = 6, on_player_died = 7,
  on_player_respawned = 8, on_surface_created = 9, on_player_removed = 10, on_gui_opened = 11,
  on_built_entity = 12, on_robot_built_entity = 13, script_raised_built = 14, script_raised_revive = 15,
  on_player_mined_entity = 16, on_robot_mined_entity = 17, on_entity_died = 18, script_raised_destroy = 19,
  on_space_platform_built_entity = 20, on_space_platform_mined_entity = 21, on_entity_cloned = 22,
  on_object_destroyed = 23, on_chunk_charted = 24, on_resource_depleted = 25,
  on_research_started = 26, on_research_finished = 27, on_research_cancelled = 28, on_research_reversed = 29,
  on_research_queued = 30, on_research_moved = 31, on_technology_effects_reset = 32, on_player_crafted_item = 33,
  on_rocket_launch_ordered = 34, on_space_platform_changed_state = 35, on_cargo_pod_finished_descending = 36,
}, controllers = { character = 1, spectator = 4 }, direction = { north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14 } }
local registered
local events, nth = {}, {}
_G.remote = { add_interface = function(name, value) assert(name == "agentic"); registered = value end }
_G.script = {
  active_mods = { ["agentic-companion"] = "0.21.0", base = "2.0.0" },
  on_init = function() end, on_configuration_changed = function() end,
  on_event = function(id, handler) events[id] = handler end,
  on_nth_tick = function(period, handler) nth[period] = handler end,
}
_G.helpers = { table_to_json = function() return "{}" end, json_to_table = function() return {} end }
_G.rcon = { print = function() end }
assert(loadfile(here .. "/../../mod/agentic-companion/control.lua"))()
assert(type(registered) == "table" and type(registered.rpc) == "function")
for _, id in pairs(defines.events) do assert(type(events[id]) == "function") end
assert(type(nth[120]) == "function", "the map tag keeps its 120-tick handler")
assert(type(nth[300]) == "function" and type(nth[3600]) == "function", "chores register upkeep and charting")
local handlers = require("scripts.rpc").handlers
for _, name in ipairs({ "factory_status", "activity_log", "event_state", "say", "say_now", "queue_plan", "plan_status",
  "blueprint_capture", "blueprint_create", "blueprint_list", "blueprint_describe", "blueprint_delete", "blueprint_export",
  "blueprint_place", "place_tiles", "platform_status", "create_platform", "set_requests", "configure_entity", "set_recipe" }) do
  assert(type(handlers[name]) == "function", "RPC " .. name .. " is registered")
end
-- Every custom input the data stage defines has a runtime listener and links
-- an official 2.0.77 game control.
local official_controls = dofile(here .. "/fixtures/factorio-2.0.77-linked-game-controls.lua")
local defined = 0
_G.data = { extend = function(_, prototypes)
  for _, prototype in ipairs(prototypes) do
    assert(prototype.type == "custom-input" and type(events[prototype.name]) == "function", prototype.name)
    assert(official_controls[prototype.linked_game_control] and prototype.key_sequence == "", prototype.name)
    defined = defined + 1
  end
end }
assert(loadfile(here .. "/../../mod/agentic-companion/data.lua"))()
assert(defined > 0)
print("ok   packaged control.lua loads and registers the agentic RPC interface")
