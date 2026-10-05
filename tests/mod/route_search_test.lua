-- Offline tests for connect_entities as a job: tile endpoints, long routes
-- searched over ticks within a per-tick engine budget, underground belt and
-- pipe-to-ground hops, and fluid-filter port choice.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

_G.game = { tick = 1 }
_G.storage = {}
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
_G.prototypes = { item = {
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

-- 3. Without an underground the wall is a dead end within max_length.
for y = -120, 120 do blocked[tile(75.5, y + 0.5)] = true end
local _, _, _, err = route({ kind = "belt", prototype = "transport-belt", underground = false,
  from = { x = 0.5, y = 0.5 }, to = { x = 150.5, y = 0.5 }, max_length = 200 })
check(err and tostring(err):match("route"), "underground = false forbids hops: no route (" .. tostring(err) .. ")")
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
local walled_route, walled_ticks, _, walled_err = route({ kind = "belt", prototype = "transport-belt", underground = false,
  from = { x = 0.5, y = 50.5 }, to = { x = 50.5, y = 50.5 }, max_length = 200 })
check(not walled_route and walled_ticks == 1 and tostring(walled_err):match("walled in"),
  "a walled-in end is named at once (" .. tostring(walled_err) .. ")")
blocked = {}

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
