local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local from_entity = { valid = true, name = "belt-a", type = "transport-belt", position = { x = 0.5, y = 0.5 } }
local to_entity = { valid = true, name = "belt-b", type = "transport-belt", position = { x = 4.5, y = 0.5 } }
local charted = true
local blocked_position
local force = { is_chunk_charted = function() return charted end }
-- Ore under a point sorts before poles and belts by name; locate must look past it.
local ores = {}
local surface = {
  find_entities_filtered = function(filter)
    local ore = ores[filter.position.x]
    if ore then
      local found = { ore }
      for _, entity in ipairs({ from_entity, to_entity }) do
        if math.abs(filter.position.x - entity.position.x) < 0.01 then found[#found + 1] = entity end
      end
      return found
    end
    if math.abs(filter.position.x - from_entity.position.x) < 0.01 then return { from_entity } end
    if math.abs(filter.position.x - to_entity.position.x) < 0.01 then return { to_entity } end
    return {}
  end,
  can_place_entity = function(args)
    local pos = args.position
    if blocked_position and pos.x == blocked_position.x and pos.y == blocked_position.y then return false end
    if args.name == "small-electric-pole" then
      for _, entity in ipairs({ from_entity, to_entity }) do
        local box = entity.bounding_box
        if box and pos.x + 0.2 > box.left_top.x and pos.x - 0.2 < box.right_bottom.x
          and pos.y + 0.2 > box.left_top.y and pos.y - 0.2 < box.right_bottom.y then return false end
      end
    end
    return args.name == "small-electric-pole" or not (math.abs(pos.x - 2.5) < 0.01 and math.abs(pos.y - 0.5) < 0.01)
  end,
}
package.loaded["scripts.companion"] = { require_companion = function() return { surface = surface, force = force } end }
_G.defines = { build_check_type = { manual = 1 } }
_G.prototypes = { item = { ["transport-belt"] = { place_result = { name = "transport-belt", type = "transport-belt" } } } }
local connect = require("scripts.connect_entities")
local jobs = require("scripts.jobs")
local function connect_entities(params) return jobs.run_now(connect.job, params) end
local route = connect_entities({ kind = "belt", prototype = "transport-belt", from = { x = 0.5, y = 0.5 }, to = { x = 4.5, y = 0.5 }, max_length = 10 })
check(route.physical == true and route.ghosts == false and route.length == #route.steps and route.length <= 10,
  "route contract is physical, bounded and contains no ghosts")
local uses_detour = false
for _, step in ipairs(route.steps) do
  if step.y ~= 0.5 then uses_detour = true end
  check(step.name == "transport-belt" and step.x ~= nil and step.y ~= nil, "route steps are public build_plan DTOs")
end
check(uses_detour, "belt route obeys authoritative placement rejection and finds a charted detour")
check(route.materials == nil, "a build's route carries no bill")
force.recipes = {}
local dry = connect_entities({ kind = "belt", prototype = "transport-belt", from = { x = 0.5, y = 0.5 }, to = { x = 4.5, y = 0.5 },
  max_length = 10, check_only = true })
check(#dry.materials == 1 and dry.materials[1].item == "transport-belt" and dry.materials[1].count == dry.length
  and dry.materials[1].short == dry.length and dry.materials[1].needs_machine["transport-belt"] == dry.length,
  "a dry run bills its pieces (supply.bill): none carried or stocked here, and no hand recipe")
ores[6.5] = { valid = true, name = "copper-ore", type = "resource", position = { x = 6.5, y = 0.5 } }
local onto_ore = connect_entities({ kind = "belt", prototype = "transport-belt", from = { x = 0.5, y = 0.5 }, to = { x = 6.5, y = 0.5 }, max_length = 10 })
local last_belt = onto_ore.steps[#onto_ore.steps]
check(last_belt.x == 6.5 and last_belt.y == 0.5, "a belt endpoint on a bare ore tile routes onto it as a free tile")
ores[6.5] = nil
from_entity.type, to_entity.type = "pipe", "pipe"
_G.prototypes.item.pipe = { place_result = { name = "pipe", type = "pipe" } }
local pipe = connect_entities({ kind = "pipe", prototype = "pipe", from = { x = 0.5, y = 0.5 }, to = { x = 4.5, y = 0.5 }, max_length = 10 })
check(pipe.length > 0 and pipe.steps[1].direction == nil, "pipe routes use physical pipe placements without invented belt direction")

from_entity.type, from_entity.name = "boiler", "boiler"
to_entity.type, to_entity.name = "generator", "steam-engine"
from_entity.fluidbox = { {}, get_pipe_connections = function() return { {
  connection_type = "normal", position = { x = 1, y = 0.5 }, target_position = { x = 1.5, y = 0.5 },
} } end }
to_entity.fluidbox = { {}, get_pipe_connections = function() return { {
  connection_type = "normal", position = { x = 4, y = 0.5 }, target_position = { x = 3.5, y = 0.5 },
} } end }
local machine_pipe = connect_entities({ kind = "pipe", prototype = "pipe", from = { x = 0.5, y = 0.5 }, to = { x = 4.5, y = 0.5 }, max_length = 10 })
local includes_source_port, includes_target_port = false, false
for _, step in ipairs(machine_pipe.steps) do
  if step.x == 1.5 and step.y == 0.5 then includes_source_port = true end
  if step.x == 3.5 and step.y == 0.5 then includes_target_port = true end
end
check(includes_source_port and includes_target_port,
  "pipe routes accept fluid-capable machines and physically fill their external connection tiles")

local function pole_prototype(quality, reach)
  return { get_max_wire_distance = function(actual_quality)
    assert(actual_quality == quality, "wire reach must use the pole's actual quality")
    return reach
  end }
end
local proposed_supply = 2.5
local proposed_pole = {
  name = "small-electric-pole", type = "electric-pole",
  get_max_wire_distance = function(quality)
    assert(quality == "normal", "proposed wire reach must use normal quality")
    return 5
  end,
  get_supply_area_distance = function(quality)
    assert(quality == "normal", "proposed supply area must use normal quality")
    return proposed_supply
  end,
  collision_box = { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } },
}
_G.prototypes.item["small-electric-pole"] = { place_result = proposed_pole }
local function power_route(max_length)
  return connect_entities({ kind = "power", prototype = "small-electric-pole",
    from = from_entity.position, to = to_entity.position, max_length = max_length or 10 })
end
-- A power route that fits no poles fails typed: the route's failure row.
local function rejects_power(max_length, code, message)
  local ok, result = pcall(power_route, max_length)
  local failure = ok and result.failure
  return failure and failure.code == code and failure.reason:find(message, 1, true) ~= nil and not result.steps and failure
end
local function within_wire_reach(route, from_reach, to_reach)
  local previous, reach = from_entity.position, from_reach
  for _, step in ipairs(route.steps) do
    local dx, dy = step.x - previous.x, step.y - previous.y
    if math.sqrt(dx * dx + dy * dy) > math.min(reach, 5) then return false end
    previous, reach = step, 5
  end
  local dx, dy = to_entity.position.x - previous.x, to_entity.position.y - previous.y
  return math.sqrt(dx * dx + dy * dy) <= math.min(reach, to_reach)
end
from_entity.type, to_entity.type = "electric-pole", "electric-pole"
from_entity.quality, to_entity.quality = { name = "normal" }, { name = "normal" }
from_entity.prototype = pole_prototype(from_entity.quality, 5)
to_entity.prototype = pole_prototype(to_entity.quality, 5)
to_entity.position.x = 10.5
local power = power_route()
check(power.length == 1 and power.steps[1].x == 5.5 and power.steps[1].y == 0.5
  and within_wire_reach(power, 5, 5), "power routes respect endpoint and prototype wire reach")
from_entity.name = "small-electric-pole"
ores[from_entity.position.x] = { valid = true, name = "iron-ore", type = "resource", position = { x = 0.5, y = 0.5 } }
local pole_on_ore = power_route()
check(pole_on_ore.length == 1 and pole_on_ore.steps[1].x == 5.5 and within_wire_reach(pole_on_ore, 5, 5),
  "a pole standing on ore is the power endpoint, not the ore under it")
ores[from_entity.position.x] = nil
from_entity.name = "boiler"

from_entity.quality, to_entity.quality = { name = "rare" }, { name = "epic" }
from_entity.prototype = pole_prototype(from_entity.quality, 5)
to_entity.prototype = pole_prototype(to_entity.quality, 3)
local unequal_power = power_route()
check(unequal_power.length == 3 and unequal_power.steps[1].x == 3.5
  and unequal_power.steps[2].x == 5.5 and unequal_power.steps[3].x == 8.5
  and within_wire_reach(unequal_power, 5, 3), "different endpoint qualities and reaches produce deterministic bounded wire spans")
local few = rejects_power(2, "ROUTE_TOO_LONG", "needs at least 3 poles; max_length is 2")
check(few and few.min_length == 3 and few.lower_bound == true and few.limit == 2,
  "too few allowed poles: ROUTE_TOO_LONG with the least poles wire reach needs")
blocked_position = { x = 5.5, y = 0.5 }
local pole_blocked = rejects_power(10, "ROUTE_BLOCKED", "power route is blocked at (5.5, 0.5)")
check(pole_blocked and pole_blocked.at.x == 5.5 and pole_blocked.at.y == 0.5,
  "a blocked intermediate pole: ROUTE_BLOCKED at the pole position")
blocked_position = nil
from_entity.prototype = pole_prototype(from_entity.quality, 3)
to_entity.prototype = pole_prototype(to_entity.quality, 5)
local short_source = power_route()
check(short_source.length == 3 and within_wire_reach(short_source, 3, 5), "short source reach also bounds the route")
to_entity.position.x = 3.5
check(power_route().length == 0, "already reachable poles need no new placement")
to_entity.position.x = 10.5

from_entity.type, from_entity.name = "generator", "steam-engine"
to_entity.type, to_entity.name = "lab", "lab"
from_entity.prototype, to_entity.prototype = { electric_energy_source_prototype = {} }, { electric_energy_source_prototype = {} }
from_entity.bounding_box = { left_top = { x = -0.5, y = -0.5 }, right_bottom = { x = 1.5, y = 1.5 } }
to_entity.bounding_box = { left_top = { x = 9.5, y = -0.5 }, right_bottom = { x = 11.5, y = 1.5 } }
local machine_power = power_route()
local function covers(step, entity)
  local box = entity.bounding_box
  local dx = math.max(box.left_top.x - step.x, 0, step.x - box.right_bottom.x)
  local dy = math.max(box.left_top.y - step.y, 0, step.y - box.right_bottom.y)
  return dx <= proposed_supply and dy <= proposed_supply
end
check(machine_power.length >= 2 and machine_power.length <= 10
  and covers(machine_power.steps[1], from_entity) and covers(machine_power.steps[#machine_power.steps], to_entity),
  "machine routes include physical poles covering both endpoints with normal-quality supply area")
for index = 2, #machine_power.steps do
  local a, b = machine_power.steps[index - 1], machine_power.steps[index]
  check((b.x - a.x)^2 + (b.y - a.y)^2 <= 25, "machine route pole spans fit normal wire reach")
end
local coverage = rejects_power(1, "ROUTE_TOO_LONG", "needs at least 2 poles; max_length is 1")
check(coverage and coverage.min_length == 2, "endpoint-covering poles count toward max_length")
proposed_supply = 0.25
local uncovered = rejects_power(10, "ROUTE_BLOCKED", "no charted physical pole placement covers the power endpoint at (0.5, 0.5)")
check(uncovered and uncovered.at.x == 0.5, "machine endpoint coverage refuses placements outside supply area")
proposed_supply = 2.5
-- The job steps on a later tick: an endpoint mined in between is reported, not read.
local pending = connect.job.start({ kind = "power", prototype = "small-electric-pole",
  from = from_entity.position, to = to_entity.position, max_length = 10 })
to_entity.valid = false
local gone_ok, gone_error = pcall(connect.job.step, pending, { left = 600 })
check(not gone_ok and tostring(gone_error) == "the power endpoint at (10.5, 0.5) is gone",
  "a power endpoint gone before the job steps fails with a route answer")
to_entity.valid = true
check(connect.job.start({ kind = "power", prototype = "small-electric-pole", from = from_entity.position,
  to = to_entity.position }).max_length == connect.MAX_LENGTH and connect.MAX_LENGTH == 200,
  "a route without max_length may use up to 200 pieces")
charted = false
local uncharted, uncharted_error = pcall(connect_entities, { kind = "power", prototype = "small-electric-pole", from = { x = 0.5, y = 0.5 }, to = { x = 10.5, y = 0.5 }, max_length = 10 })
check(not uncharted and tostring(uncharted_error):match("force%-charted") ~= nil, "uncharted exact endpoints are refused")

-- Snapping poles to tile centres can stretch a span past wire reach (16 even
-- segments over 115 tiles snap to some 8-tile spans); the span adds a pole.
local small_pole = { get_max_wire_distance = function(quality) assert(quality == "normal"); return 7.5 end }
local long_from, long_to = { x = -48.5, y = -10.5 }, { x = 66.5, y = -10.5 }
local long_ok, long_poles = pcall(connect.route_poles, "small-electric-pole", small_pole, long_from, long_to, 200,
  function() return true end, function() return false end)
local spans_fit = long_ok and #long_poles >= 2
local previous = long_from
for index = 2, long_ok and #long_poles or 0 do
  local pole = long_poles[index]
  if (pole.x - previous.x)^2 + (pole.y - previous.y)^2 > 7.5 * 7.5 then spans_fit = false end
  previous = pole
end
check(spans_fit and long_poles[1].x == long_from.x and long_poles[#long_poles].x == long_to.x,
  "a straight 115-tile pole route adds poles until every snapped span fits wire reach")
local diagonal_ok, diagonal = pcall(connect.route_poles, "small-electric-pole", small_pole, { x = 0.5, y = 0.5 },
  { x = 90.5, y = 47.5 }, 200, function() return true end, function() return false end)
local diagonal_fits = diagonal_ok
for index = 2, diagonal_ok and #diagonal or 0 do
  local a, b = diagonal[index - 1], diagonal[index]
  if (b.x - a.x)^2 + (b.y - a.y)^2 > 7.5 * 7.5 then diagonal_fits = false end
end
check(diagonal_fits, "a diagonal pole route keeps every snapped span within wire reach")
local layout_failure = {}
local layout_ok, layout_err = pcall(connect.route_poles, "small-electric-pole", small_pole, long_from, long_to, 16,
  function() return true end, function() return false end, layout_failure)
local layout_typed = connect.failure(layout_err, layout_failure)
check(not layout_ok and layout_typed and layout_typed.code == "ROUTE_TOO_LONG" and layout_typed.min_length > 16
  and layout_typed.limit == 16 and layout_typed.lower_bound == true,
  "a pole route that needs more poles than max_length fails ROUTE_TOO_LONG (build_layout's typed row)")
os.exit(failures == 0 and 0 or 1)
