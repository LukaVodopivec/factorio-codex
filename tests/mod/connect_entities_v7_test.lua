local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local from_entity = { valid = true, name = "belt-a", type = "transport-belt", position = { x = 0.5, y = 0.5 } }
local to_entity = { valid = true, name = "belt-b", type = "transport-belt", position = { x = 4.5, y = 0.5 } }
local charted = true
local force = { is_chunk_charted = function() return charted end }
local surface = {
  find_entities_filtered = function(filter)
    if math.abs(filter.position.x - from_entity.position.x) < 0.01 then return { from_entity } end
    if math.abs(filter.position.x - to_entity.position.x) < 0.01 then return { to_entity } end
    return {}
  end,
  can_place_entity = function(args) return not (math.abs(args.position.x - 2.5) < 0.01 and math.abs(args.position.y - 0.5) < 0.01) end,
}
package.loaded["scripts.companion"] = { require_companion = function() return { surface = surface, force = force } end }
_G.defines = { build_check_type = { manual = 1 } }
_G.prototypes = { item = { ["transport-belt"] = { place_result = { name = "transport-belt", type = "transport-belt" } } } }
local connect = require("scripts.connect_entities")
local route = connect.connect_entities({ kind = "belt", prototype = "transport-belt", from = { x = 0.5, y = 0.5 }, to = { x = 4.5, y = 0.5 }, max_length = 10 })
check(route.physical == true and route.ghosts == false and route.length == #route.steps and route.length <= 10,
  "route contract is physical, bounded and contains no ghosts")
local uses_detour = false
for _, step in ipairs(route.steps) do
  if step.y ~= 0.5 then uses_detour = true end
  check(step.name == "transport-belt" and step.x ~= nil and step.y ~= nil, "route steps are public build_plan DTOs")
end
check(uses_detour, "belt route obeys authoritative placement rejection and finds a charted detour")
from_entity.type, to_entity.type = "pipe", "pipe"
_G.prototypes.item.pipe = { place_result = { name = "pipe", type = "pipe" } }
local pipe = connect.connect_entities({ kind = "pipe", prototype = "pipe", from = { x = 0.5, y = 0.5 }, to = { x = 4.5, y = 0.5 }, max_length = 10 })
check(pipe.length > 0 and pipe.steps[1].direction == nil, "pipe routes use physical pipe placements without invented belt direction")

from_entity.type, from_entity.name = "boiler", "boiler"
to_entity.type, to_entity.name = "generator", "steam-engine"
from_entity.fluidbox = { {}, get_pipe_connections = function() return { { connection_type = "normal", target_position = { x = 1.5, y = 0.5 } } } end }
to_entity.fluidbox = { {}, get_pipe_connections = function() return { { connection_type = "normal", target_position = { x = 3.5, y = 0.5 } } } end }
local machine_pipe = connect.connect_entities({ kind = "pipe", prototype = "pipe", from = { x = 0.5, y = 0.5 }, to = { x = 4.5, y = 0.5 }, max_length = 10 })
local includes_source_port, includes_target_port = false, false
for _, step in ipairs(machine_pipe.steps) do
  if step.x == 1.5 and step.y == 0.5 then includes_source_port = true end
  if step.x == 3.5 and step.y == 0.5 then includes_target_port = true end
end
check(includes_source_port and includes_target_port,
  "pipe routes accept fluid-capable machines and physically fill their external connection tiles")

from_entity.type, to_entity.type = "electric-pole", "electric-pole"
from_entity.prototype, to_entity.prototype = { maximum_wire_distance = 5 }, { maximum_wire_distance = 5 }
to_entity.position.x = 10.5
_G.prototypes.item["small-electric-pole"] = { place_result = { name = "small-electric-pole", type = "electric-pole", maximum_wire_distance = 5, supply_area_distance = 2.5, collision_box = { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } } } }
local power = connect.connect_entities({ kind = "power", prototype = "small-electric-pole", from = { x = 0.5, y = 0.5 }, to = { x = 10.5, y = 0.5 }, max_length = 10 })
check(power.length == 1 and power.steps[1].x == 5.5, "power routes respect endpoint and prototype wire reach")

from_entity.type, from_entity.name = "generator", "steam-engine"
to_entity.type, to_entity.name = "lab", "lab"
from_entity.prototype, to_entity.prototype = { electric_energy_source_prototype = {} }, { electric_energy_source_prototype = {} }
from_entity.bounding_box = { left_top = { x = -0.5, y = -0.5 }, right_bottom = { x = 1.5, y = 1.5 } }
to_entity.bounding_box = { left_top = { x = 9.5, y = -0.5 }, right_bottom = { x = 11.5, y = 1.5 } }
local machine_power = connect.connect_entities({ kind = "power", prototype = "small-electric-pole", from = { x = 0.5, y = 0.5 }, to = { x = 10.5, y = 0.5 }, max_length = 10 })
check(machine_power.length >= 2 and machine_power.length <= 10,
  "power routes accept producing and consuming machines and include physical endpoint-covering poles")
charted = false
local uncharted, uncharted_error = pcall(connect.connect_entities, { kind = "power", prototype = "small-electric-pole", from = { x = 0.5, y = 0.5 }, to = { x = 10.5, y = 0.5 }, max_length = 10 })
check(not uncharted and tostring(uncharted_error):match("force%-charted") ~= nil, "uncharted exact endpoints are refused")
os.exit(failures == 0 and 0 or 1)
