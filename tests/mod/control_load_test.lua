local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. here .. "/../../mod/agentic-companion/?/init.lua;" .. package.path
_G.storage = {}
_G.defines = { events = { on_tick = 2, on_script_path_request_finished = 3 }, controllers = { spectator = 4 }, shooting = { not_shooting = 0 }, direction = { north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14 } }
local registered
_G.remote = { add_interface = function(name, value) assert(name == "agentic"); registered = value end }
_G.script = { active_mods = { ["agentic-companion"] = "0.9.0", base = "2.0.0" }, on_init = function() end, on_configuration_changed = function() end, on_event = function() end, on_nth_tick = function() end }
_G.helpers = { table_to_json = function() return "{}" end, json_to_table = function() return {} end }
_G.rcon = { print = function() end }
assert(loadfile(here .. "/../../mod/agentic-companion/control.lua"))()
assert(type(registered) == "table" and type(registered.rpc) == "function")
print("ok   packaged control.lua loads and registers the agentic RPC interface")
