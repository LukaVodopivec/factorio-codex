-- Offline tests for connect_entities as a job: tile endpoints, long routes
-- searched over ticks within a per-tick engine budget, underground belt and
-- pipe-to-ground hops, fluid-filter port choice, typed failures
-- (ROUTE_TOO_LONG, ROUTE_BLOCKED, SEARCH_BUDGET), via waypoints routed leg by
-- leg, and a pipe route's fluid segment extent.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

_G.game = { tick = 1 }
_G.storage = {}
_G.helpers = { table_to_json = dofile(here .. "/table_to_json.lua") }
_G.defines = { build_check_type = { manual = 1, ghost_revive = 2 } }

local function box(w, h) return { left_top = { x = -w / 2, y = -h / 2 }, right_bottom = { x = w / 2, y = h / 2 } } end
local underground_belt = { name = "underground-belt", type = "underground-belt", collision_box = box(0.8, 0.8),
  max_underground_distance = 5 }
local belt = { name = "transport-belt", type = "transport-belt", collision_box = box(0.8, 0.8),
  related_underground_belt = underground_belt }
local pipe_to_ground = { name = "pipe-to-ground", type = "pipe-to-ground", collision_box = box(0.8, 0.8),
  fluidbox_prototypes = { { pipe_connections = {
    { connection_type = "normal", direction = 0 },
    { connection_type = "underground", direction = 8, max_underground_distance = 10 },
  } } } }
local pipe = { name = "pipe", type = "pipe", collision_box = box(0.8, 0.8) }
_G.prototypes = { utility_constants = { default_pipeline_extent = 320 }, item = {
  ["transport-belt"] = { place_result = belt }, ["underground-belt"] = { place_result = underground_belt },
  pipe = { place_result = pipe }, ["pipe-to-ground"] = { place_result = pipe_to_ground },
} }

-- The world: blocked tiles, endpoint entities, existing undergrounds.
local blocked, endpoints, undergrounds = {}, {}, {}
local engine = { can_place = 0, find = 0 }
local function tile(x, y) return math.floor(x) .. "," .. math.floor(y) end
local surface = {
  can_place_entity = function(args)
    engine.can_place = engine.can_place + 1
    return not blocked[tile(args.position.x, args.position.y)]
  end,
  find_entities_filtered = function(filter)
    engine.find = engine.find + 1
    if filter.position then
      local hit = endpoints[tile(filter.position.x, filter.position.y)]
      return hit and { hit } or {}
    end
    local out = {}
    for _, u in ipairs(undergrounds) do
      if u.name == filter.name and u.position.x > filter.area.left_top.x and u.position.x < filter.area.right_bottom.x
        and u.position.y > filter.area.left_top.y and u.position.y < filter.area.right_bottom.y then out[#out + 1] = u end
    end
    return out
  end,
}
local recipes = { ["underground-belt"] = { enabled = true }, ["pipe-to-ground"] = { enabled = true } }
local body = { valid = true, position = { x = 1000.5, y = 1000.5 },
  bounding_box = { left_top = { x = 1000.3, y = 1000.3 }, right_bottom = { x = 1000.7, y = 1000.7 } },
  surface = surface, force = { recipes = recipes, is_chunk_charted = function() return true end },
  get_item_count = function() return 0 end }
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }

local connect = require("scripts.connect_entities")
local jobs = require("scripts.jobs")

-- Runs a connect_entities job tick by tick; returns the result (or error),
-- the ticks it took and the most placement checks any one tick made.
local function route(params)
  local state = connect.job.start(params)
  local ticks, worst, result = 0, 0, nil
  while result == nil and ticks < 2000 do
    engine.can_place = 0
    local ok, value = pcall(connect.job.step, state, { left = jobs.WORK_PER_TICK })
    ticks, worst = ticks + 1, math.max(worst, engine.can_place)
    if not ok then return nil, ticks, worst, value end
    result = value
  end
  return result, ticks, worst
end
-- can_place_entity runs twice per check (manual, then revive); a check costs
-- 4 items, a node expansion may finish past the tick's share by its last few.
local PER_TICK_CHECKS = 2 * (jobs.WORK_PER_TICK / 4 + 32)

-- 1. A 150-tile belt between two free tiles across a wall too long to go
-- round: an underground pair hops it.
for y = -120, 120 do blocked[tile(75.5, y + 0.5)] = true end
local long, ticks, worst = route({ kind = "belt", prototype = "transport-belt",
  from = { x = 0.5, y = 0.5 }, to = { x = 150.5, y = 0.5 }, max_length = 200 })
local pair, east = {}, true
for _, step in ipairs(long and long.steps or {}) do
  if step.belt_to_ground_type then pair[#pair + 1] = step end
  if step.direction ~= 4 then east = false end
end
check(long and long.steps[1].x == 0.5 and long.steps[#long.steps].x == 150.5 and #pair == 2
  and pair[1].name == "underground-belt" and pair[1].belt_to_ground_type == "input" and pair[1].x == 74.5
  and pair[2].belt_to_ground_type == "output" and pair[2].x > 75.5 and pair[2].x - pair[1].x <= 5 and east,
  "a 150-tile belt route between free tiles hops a wall with one underground pair, all heading east")
check(long and #long.steps == 151 - (pair[2].x - pair[1].x - 1) and long.length == #long.steps,
  "tiles under the hop take no piece")
check(ticks > 1 and worst <= PER_TICK_CHECKS,
  string.format("the search spreads over ticks within its budget (%d ticks, worst %d placement checks)", ticks, worst))

-- 2. An existing underground of the same item in the gap would pair with
-- the entrance: the hop moves past it.
undergrounds = { { name = "underground-belt", position = { x = 76.5, y = 0.5 } } }
blocked[tile(76.5, 0.5)] = true
local around, around_ticks, around_worst = route({ kind = "belt", prototype = "transport-belt",
  from = { x = 0.5, y = 0.5 }, to = { x = 150.5, y = 0.5 }, max_length = 200 })
local hop_ok = true
for _, step in ipairs(around and around.steps or {}) do
  if step.belt_to_ground_type == "input" and step.y == 0.5 then hop_ok = false end
end
check(around and hop_ok and around.length <= 200 and around_worst <= PER_TICK_CHECKS,
  string.format("a hop never passes over another underground of the same item on its axis (%d ticks)", around_ticks))
undergrounds, blocked = {}, {}

-- 3. Without an underground the way round the wall is longer than
-- max_length: ROUTE_TOO_LONG, a lower bound when the budget ended first.
for y = -120, 120 do blocked[tile(75.5, y + 0.5)] = true end
local around_wall, wall_ticks, wall_worst = route({ kind = "belt", prototype = "transport-belt", underground = false,
  from = { x = 0.5, y = 0.5 }, to = { x = 150.5, y = 0.5 }, max_length = 200 })
local wall_failure = around_wall and around_wall.failure
check(wall_failure and wall_failure.code == "ROUTE_TOO_LONG" and wall_failure.min_length > 200 and wall_failure.limit == 200
  and not around_wall.steps and wall_worst <= PER_TICK_CHECKS,
  string.format("underground = false forbids hops: ROUTE_TOO_LONG, min_length %s%s, limit 200 (%d ticks)",
    tostring(wall_failure and wall_failure.min_length), wall_failure and wall_failure.lower_bound and " (lower bound)" or "",
    wall_ticks))
blocked = {}

-- 4. Length limits: 200 tiles is the most.
local too_long = pcall(connect.job.start, { kind = "belt", prototype = "transport-belt",
  from = { x = 0.5, y = 0.5 }, to = { x = 10.5, y = 0.5 }, max_length = 201 })
local open_200 = route({ kind = "belt", prototype = "transport-belt",
  from = { x = 0.5, y = 0.5 }, to = { x = 199.5, y = 0.5 }, max_length = 200 })
check(not too_long and open_200 and open_200.length == 200, "max_length runs 1-200 and an open 200-tile route fits")

-- 5. Pipe-to-ground: the entrance's underground side faces the way, the exit's back.
for y = -120, 120 do for x = 20, 22 do blocked[tile(x + 0.5, y + 0.5)] = true end end
local piped = route({ kind = "pipe", prototype = "pipe", from = { x = 0.5, y = 0.5 }, to = { x = 40.5, y = 0.5 }, max_length = 60 })
local ptg = {}
for _, step in ipairs(piped and piped.steps or {}) do if step.name == "pipe-to-ground" then ptg[#ptg + 1] = step end end
check(piped and #ptg == 2 and ptg[1].x == 19.5 and ptg[1].direction == 12 and ptg[2].x >= 23.5 and ptg[2].direction == 4,
  "a pipe route hops a 3-wide wall with a pipe-to-ground pair (entrance faces west, exit east)")
blocked = {}

-- 6. Fluid ports: the refinery's crude-oil input is chosen by its runtime filter.
local filters = { "crude-oil", "water", "heavy-oil", "light-oil", "petroleum-gas" }
local ports = {
  { position = { x = 101, y = 102.5 }, target = { x = 101.5, y = 103.5 } },
  { position = { x = 99, y = 102.5 }, target = { x = 99.5, y = 103.5 } },
  { position = { x = 98, y = 97.5 }, target = { x = 98.5, y = 96.5 } },
  { position = { x = 100, y = 97.5 }, target = { x = 100.5, y = 96.5 } },
  { position = { x = 102, y = 97.5 }, target = { x = 102.5, y = 96.5 } },
}
local fluidbox = { {}, {}, {}, {}, {},
  get_prototype = function(index) return { production_type = index <= 2 and "input" or "output" } end,
  get_pipe_connections = function(index)
    return { { connection_type = "normal", flow_direction = index <= 2 and "input" or "output",
      position = ports[index].position, target_position = ports[index].target } }
  end,
  get_filter = function(index) return { name = filters[index] } end,
}
local refinery = { valid = true, name = "oil-refinery", type = "assembling-machine", position = { x = 100.5, y = 100.5 },
  fluidbox = fluidbox }
endpoints[tile(100.5, 100.5)] = refinery
local asks_ok, asks_err = pcall(connect.job.start, { kind = "pipe", prototype = "pipe",
  from = { x = 90.5, y = 110.5 }, to = { x = 100.5, y = 100.5 } })
check(not asks_ok and tostring(asks_err):match("say which with fluid"),
  "a machine with several port fluids and a free tile at the other end asks which fluid")
local crude = route({ kind = "pipe", prototype = "pipe", fluid = "crude-oil",
  from = { x = 90.5, y = 110.5 }, to = { x = 100.5, y = 100.5 } })
local last = crude and crude.steps[#crude.steps]
check(crude and crude.fluid == "crude-oil" and last.x == 101.5 and last.y == 103.5,
  "a pipe route ends at the refinery port whose filter matches crude-oil, not the nearer water port")
local water_route = route({ kind = "pipe", prototype = "pipe", fluid = "water",
  from = { x = 90.5, y = 110.5 }, to = { x = 100.5, y = 100.5 } })
last = water_route and water_route.steps[#water_route.steps]
check(water_route and last.x == 99.5 and last.y == 103.5, "fluid = water picks the water port")
local _, none_err = pcall(connect.job.start, { kind = "pipe", prototype = "pipe", fluid = "sulfuric-acid",
  from = { x = 90.5, y = 110.5 }, to = { x = 100.5, y = 100.5 } })
check(none_err and tostring(none_err):match("no free sulfuric%-acid port"), "a fluid no port takes is refused by name")
endpoints = {}

-- 7. An end walled in on all sides fails at once, not after the whole area.
for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do blocked[tile(50.5 + d[1], 50.5 + d[2])] = true end
local walled_route, walled_ticks = route({ kind = "belt", prototype = "transport-belt", underground = false,
  from = { x = 0.5, y = 50.5 }, to = { x = 50.5, y = 50.5 }, max_length = 200 })
local walled = walled_route and walled_route.failure
check(walled and walled.code == "ROUTE_BLOCKED" and walled_ticks == 1 and walled.reason:match("walled in"),
  "a walled-in end is ROUTE_BLOCKED at once (" .. tostring(walled and walled.reason) .. ")")
blocked = {}

-- Whether pieces follow on tile by tile (an underground pair spans its gap
-- on one axis), no tile twice, each belt pointing at the next piece.
local function heading(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  if math.abs(dx) > math.abs(dy) then return dx > 0 and 4 or 12 end
  return dy > 0 and 8 or 0
end
local function chained(steps, belts)
  local seen = {}
  for i, s in ipairs(steps) do
    if seen[tile(s.x, s.y)] then return false, "tile twice at " .. s.x .. "," .. s.y end
    seen[tile(s.x, s.y)] = true
    local nxt = steps[i + 1]
    if nxt then
      local gap = math.abs(nxt.x - s.x) + math.abs(nxt.y - s.y)
      local pair = s.belt_to_ground_type == "input" or (s.name == "pipe-to-ground" and nxt.name == "pipe-to-ground")
      if gap ~= 1 and not (pair and (nxt.x == s.x or nxt.y == s.y)) then return false, "gap after " .. s.x .. "," .. s.y end
      if belts and s.direction ~= heading(s, nxt) then return false, "direction at " .. s.x .. "," .. s.y end
    end
  end
  return true
end

-- 9. A route that exists but is longer than max_length: ROUTE_TOO_LONG with
-- the shortest route's exact length (a 7-tile wall forces a 19-tile detour).
for y = -3, 3 do blocked[tile(205.5, y + 0.5)] = true end
local detour_params = { kind = "belt", prototype = "transport-belt", underground = false,
  from = { x = 200.5, y = 0.5 }, to = { x = 210.5, y = 0.5 }, max_length = 12 }
local detour = route(detour_params)
local too_long_failure = detour and detour.failure
check(too_long_failure and too_long_failure.code == "ROUTE_TOO_LONG" and too_long_failure.min_length == 19
  and too_long_failure.limit == 12 and not too_long_failure.lower_bound and too_long_failure.reason:match("19 tiles"),
  "ROUTE_TOO_LONG gives the shortest route's length (19) and the limit (12): " .. tostring(too_long_failure and too_long_failure.reason))
detour_params.max_length = 19
local fits19 = route(detour_params)
check(fits19 and not fits19.failure and fits19.length == 19 and chained(fits19.steps, true),
  "with max_length 19 the same detour is the route")
blocked = {}

-- 10. A start boxed in by a ring: nothing reachable meets the end, so
-- ROUTE_BLOCKED names the reached tile nearest the end.
for dy = -2, 2 do for dx = -2, 2 do
  if math.max(math.abs(dx), math.abs(dy)) == 2 then blocked[tile(300.5 + dx, 0.5 + dy)] = true end
end end
local boxed, boxed_ticks = route({ kind = "belt", prototype = "transport-belt", underground = false,
  from = { x = 300.5, y = 0.5 }, to = { x = 320.5, y = 0.5 }, max_length = 200 })
local blocked_failure = boxed and boxed.failure
check(blocked_failure and blocked_failure.code == "ROUTE_BLOCKED" and blocked_failure.closest.x == 301.5
  and blocked_failure.closest.y == 0.5 and blocked_failure.remaining == 19 and boxed_ticks == 1,
  "ROUTE_BLOCKED gives the closest reached tile and its distance: " .. tostring(blocked_failure and blocked_failure.reason))
blocked = {}

-- 11. The node budget: SEARCH_BUDGET while every open route still fits
-- max_length, ROUTE_TOO_LONG with a lower bound once none does; a caller
-- that stops the search at its own ceiling gets the same row (connect.spent).
local function bare_search(max_length, max_nodes)
  local R = connect.new_search({ kind = "belt", item = "transport-belt", max_length = max_length,
    starts = { { position = { x = 0.5, y = 400.5 }, include = true } },
    goals = { { position = { x = 100.5, y = 400.5 }, include = true } } })
  R.max_nodes = max_nodes
  return R
end
local open_env = { more = function() return true end, fits = function(pos) return not blocked[tile(pos.x, pos.y)] end }
local budget_search = bare_search(200, 40)
local budget_ok, budget_err = pcall(connect.search_step, budget_search, open_env)
local budget_failure = connect.failure(budget_err, budget_search)
check(not budget_ok and budget_failure and budget_failure.code == "SEARCH_BUDGET" and budget_failure.explored == 40
  and budget_failure.closest.x == 40.5 and budget_failure.remaining == 60,
  "SEARCH_BUDGET gives the tiles explored and the closest tile reached: " .. tostring(budget_failure and budget_failure.reason))
local bound_search = bare_search(30, 40)
local _, bound_err = pcall(connect.search_step, bound_search, open_env)
local bound_failure = connect.failure(bound_err, bound_search)
check(bound_failure and bound_failure.code == "ROUTE_TOO_LONG" and bound_failure.lower_bound == true
  and bound_failure.min_length == 101 and bound_failure.limit == 30,
  "a budget that ends past max_length is ROUTE_TOO_LONG with a lower bound (101 tiles, limit 30)")
local stopped, calls = bare_search(200, 2000), 0
local stopped_env = { more = function() calls = calls + 1; return calls <= 10 end, fits = open_env.fits }
check(connect.search_step(stopped, stopped_env) == nil and connect.spent(stopped).code == "SEARCH_BUDGET"
  and stopped.failure.explored == 10, "a search stopped by its caller's ceiling is SEARCH_BUDGET (connect.spent)")

-- 12. via: the route passes each waypoint in order, leg by leg, one piece on
-- each; max_length bounds the whole route and a failure names its leg.
local via_params = { kind = "belt", prototype = "transport-belt", from = { x = 500.5, y = 0.5 }, to = { x = 510.5, y = 0.5 },
  via = { { x = 505.2, y = 5.7 } }, max_length = 200 }
local via_route = route(via_params)
local on_waypoint = 0
for _, s in ipairs(via_route and via_route.steps or {}) do
  if s.x == 505.5 and s.y == 5.5 then on_waypoint = on_waypoint + 1 end
end
local via_chain, via_why = chained(via_route and via_route.steps or {}, true)
check(via_route and not via_route.failure and via_route.length == 21 and on_waypoint == 1 and via_chain
  and via_route.steps[1].x == 500.5 and via_route.steps[21].x == 510.5 and via_route.via[1].x == 505.5,
  "a belt route through one waypoint lays 21 pieces, one on the waypoint, each pointing on" .. (via_why and (" (" .. via_why .. ")") or ""))
via_params.max_length = 15
local via_long = route(via_params)
local leg_failure = via_long and via_long.failure
check(leg_failure and leg_failure.code == "ROUTE_TOO_LONG" and leg_failure.leg == 1 and leg_failure.min_length == 21
  and leg_failure.limit == 15 and leg_failure.reason:match("the leg to `to`"),
  "max_length bounds all legs: the second leg fails ROUTE_TOO_LONG with the whole route's 21 tiles, limit 15")
for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do blocked[tile(505.5 + d[1], 5.5 + d[2])] = true end
via_params.max_length, via_params.underground = 200, false
local via_walled = route(via_params)
local walled_leg = via_walled and via_walled.failure
check(walled_leg and walled_leg.code == "ROUTE_BLOCKED" and walled_leg.leg == 0 and walled_leg.reason:match("via%[0%]"),
  "a walled-in waypoint fails its leg ROUTE_BLOCKED, naming via[0]")
blocked = {}
-- A leg whose underground exit lands on the waypoint: the next leg goes on
-- from that exit, in its direction, without another piece there.
for y = -120, 120 do blocked[tile(608.5, y + 0.5)] = true end
local via_exit = route({ kind = "belt", prototype = "transport-belt", from = { x = 600.5, y = 0.5 }, to = { x = 615.5, y = 0.5 },
  via = { { x = 609.5, y = 0.5 } } })
local exits, at_waypoint = 0, nil
for _, s in ipairs(via_exit and via_exit.steps or {}) do
  if s.belt_to_ground_type == "output" then exits = exits + 1 end
  if s.x == 609.5 and s.y == 0.5 then at_waypoint = s end
end
check(via_exit and not via_exit.failure and exits == 1 and at_waypoint and at_waypoint.belt_to_ground_type == "output"
  and via_exit.length == 15 and via_exit.steps[15].x == 615.5 and chained(via_exit.steps, false),
  "an underground exit on the waypoint carries the next leg on (15 pieces)")
blocked = {}
_G.prototypes.item["small-electric-pole"] = { place_result = { name = "small-electric-pole", type = "electric-pole" } }
local power_via, power_err = pcall(connect.job.start, { kind = "power", prototype = "small-electric-pole", from = { x = 0.5, y = 0.5 },
  to = { x = 9.5, y = 0.5 }, via = { { x = 4.5, y = 4.5 } } })
local many = {}
for i = 1, connect.MAX_VIA + 1 do many[i] = { x = 500.5 + i, y = 9.5 } end
local too_many, many_err = pcall(connect.job.start, { kind = "belt", prototype = "transport-belt", from = { x = 500.5, y = 0.5 },
  to = { x = 510.5, y = 0.5 }, via = many })
local repeated_ok, repeated_err = pcall(connect.job.start, { kind = "belt", prototype = "transport-belt",
  from = { x = 500.5, y = 0.5 }, to = { x = 510.5, y = 0.5 }, via = { { x = 503.5, y = 3.5 }, { x = 503.7, y = 3.2 } } })
check(not power_via and tostring(power_err):match("via routes belts and pipes") and not too_many
  and tostring(many_err):match("up to 8 waypoints") and not repeated_ok and tostring(repeated_err):match("via%[1%] repeats"),
  "via is for belts and pipes, at most MAX_VIA waypoints, each a new tile")

-- 13. A pipe route's fluid segment: its extent (the larger side of its
-- bounding box, hops included) against the game's pipeline extent, joined
-- with the standing segment of a pipe it ends at.
local pipe_run = route({ kind = "pipe", prototype = "pipe", from = { x = 700.5, y = 0.5 }, to = { x = 730.5, y = 0.5 } })
local seg = pipe_run and pipe_run.fluid_segments and pipe_run.fluid_segments[1]
check(seg and seg.extent == 31 and seg.limit == 320 and not seg.over_extent and not seg.standing,
  "a 31-tile pipe route reports extent 31 against the 320-tile pipeline limit")
check(piped and piped.fluid_segments[1].extent == 41 and #piped.steps < 41,
  "pipe-to-ground gaps count in the extent (41 tiles, fewer pieces)")
_G.prototypes.utility_constants.default_pipeline_extent = 20
local over = route({ kind = "pipe", prototype = "pipe", from = { x = 700.5, y = 0.5 }, to = { x = 730.5, y = 0.5 } })
check(over and over.fluid_segments[1].over_extent == true and over.fluid_segments[1].limit == 20,
  "over_extent: true when the extent exceeds the limit")
_G.prototypes.utility_constants.default_pipeline_extent = 320
local standing_pipe = { valid = true, name = "pipe", type = "pipe", position = { x = 740.5, y = 0.5 }, fluidbox = {
  get_fluid_segment_id = function(index) return index == 1 and 7 or nil end,
  get_fluid_segment_extent_bounding_box = function()
    return { left_top = { x = 740.2109375, y = 0.2109375 }, right_bottom = { x = 1100.7890625, y = 0.7890625 } }
  end } }
endpoints[tile(740.5, 0.5)] = standing_pipe
local joined = route({ kind = "pipe", prototype = "pipe", from = { x = 700.5, y = 0.5 }, to = { x = 740.5, y = 0.5 } })
seg = joined and joined.fluid_segments and joined.fluid_segments[1]
check(seg and #joined.steps == 40 and seg.extent == 401 and seg.over_extent == true and seg.standing == 1,
  "joining a standing 361-tile segment makes one of 401 tiles: over_extent")
endpoints = {}
local pipe_via = route({ kind = "pipe", prototype = "pipe", from = { x = 800.5, y = 0.5 }, to = { x = 810.5, y = 0.5 },
  via = { { x = 805.5, y = 5.5 } } })
check(pipe_via and pipe_via.length == 21 and chained(pipe_via.steps, false) and pipe_via.fluid_segments[1].extent == 11,
  "a pipe route through a waypoint is one segment of extent 11")

-- 8. Through the job framework: the RPC returns a job id, get_job the route.
jobs.register("connect_entities", connect.job)
local started = jobs.start("connect_entities", { kind = "belt", prototype = "transport-belt",
  from = { x = 0.5, y = 0.5 }, to = { x = 180.5, y = 0.5 }, max_length = 200 })
local polled
for _ = 1, 100 do
  game.tick = game.tick + 1
  jobs.on_tick()
  polled = jobs.get({ job_id = started.job_id })
  if polled.job_status ~= "pending" then break end
end
check(started.job_status == "pending" and polled.job_status == "done" and polled.result.length == 181
  and polled.result.steps[181].x == 180.5, "connect_entities over RPC is a job whose route get_job returns once done")

print(failures == 0 and "\nALL ROUTE TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
