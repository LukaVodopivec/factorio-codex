-- Offline tests for place_tiles (actions/tiles.lua): where an item may go
-- comes from its place_as_tile_result and the current tile's prototype
-- (landfill only on water, stone path and concrete not on water, nothing over
-- a tile that cannot be covered, uncharted land refused); a lake whose middle
-- is beyond build distance from the shore is filled nearest first, walking as
-- the shore grows, at most 8 tiles a tick, one item per tile; a repeat finds
-- every tile already done and pays nothing; check_only only reads.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local mock = dofile(here .. "/factorio_api_mock.lua")
_G.storage, _G.game = {}, { tick = 1 }
_G.defines = { inventory = {} }

-- Tile prototypes: water collides with water_tile, land with ground_tile.
local function tile_proto(name, layer, extra)
  local values = { name = name, collision_mask = { layers = { [layer] = true } }, allows_being_covered = true }
  for k, v in pairs(extra or {}) do values[k] = v end
  return mock.tile_prototype(values)
end
local landfill_tile = tile_proto("landfill", "ground_tile", { items_to_place_this = { { name = "landfill", count = 1 } } })
local tiles = {
  grass = tile_proto("grass-1", "ground_tile"),
  landfill = landfill_tile,
  water = tile_proto("water", "water_tile", { default_cover_tile = landfill_tile, fluid = { name = "water" } }),
  ["stone-path"] = tile_proto("stone-path", "ground_tile", { mineable_properties = { minable = true, mining_time = 0.1,
    products = { { type = "item", name = "stone-brick", amount = 1 } } } }),
  concrete = tile_proto("concrete", "ground_tile"),
  foundation = tile_proto("space-platform-foundation", "ground_tile", { allows_being_covered = false }),
}
local function item(name, place)
  return mock.item_prototype({ name = name, place_as_tile_result = place })
end
_G.prototypes = { item = {
  landfill = item("landfill", { result = tiles.landfill, condition_size = 1, condition = { layers = { ground_tile = true } },
    invert = false, tile_condition = { tiles.water } }),
  ["stone-brick"] = item("stone-brick", { result = tiles["stone-path"], condition_size = 1,
    condition = { layers = { water_tile = true } }, invert = false, tile_condition = {} }),
  concrete = item("concrete", { result = tiles.concrete, condition_size = 1, condition = { layers = { water_tile = true } },
    invert = false, tile_condition = {} }),
  ["iron-chest"] = mock.item_prototype({ name = "iron-chest", place_result = mock.entity_prototype({ name = "iron-chest" }) }),
} }

-- The world: "x,y" -> tile key; water is a 6 x 6 lake at x 20..25, y 0..5.
local world = {}
local function at(x, y) return world[x .. "," .. y] or "grass" end
for x = 20, 25 do for y = 0, 5 do world[x .. "," .. y] = "water" end end
world["0,0"] = "foundation"
local occupied = { ["30,30"] = true }
local per_tick, max_per_tick, set_calls, tile_reads = 0, 0, 0, 0
local surface = mock.surface({
  get_tile = function(x, y)
    tile_reads = tile_reads + 1
    local key = at(x, y)
    return mock.tile({ name = tiles[key].name, prototype = tiles[key], hidden_tile = key ~= "water" and "grass-1" or nil })
  end,
  set_tiles = function(list, correct, colliding, decoratives, raise, player)
    assert(#list == 1 and correct == true and colliding == "abort_on_collision" and decoratives == true and raise == true
      and player == nil, "one tile, corrected, aborting on collision, raising the event, no player")
    set_calls, per_tick = set_calls + 1, per_tick + 1
    max_per_tick = math.max(max_per_tick, per_tick)
    local p = list[1].position
    if occupied[p.x .. "," .. p.y] then return end
    for key, proto in pairs(tiles) do if proto.name == list[1].name then world[p.x .. "," .. p.y] = key end end
  end,
})
local force = mock.force({ is_chunk_charted = function(s, chunk) return s == surface and chunk.x < 3 and chunk.y < 3 end })

-- carried[name] counts normal quality; uncommon[name] another quality, which
-- a bare-name count includes and a normal-quality removal never takes.
local carried, uncommon, inserted = {}, {}, {}
local body = { valid = true, position = { x = 10.5, y = 2.5 }, build_distance = 3, surface = surface, force = force }
function body.get_item_count(filter)
  if type(filter) == "table" then
    assert(filter.quality == "normal", "a tile item count names normal quality")
    return carried[filter.name] or 0
  end
  return (carried[filter] or 0) + (uncommon[filter] or 0)
end
function body.remove_item(stack)
  assert(stack.quality == "normal", "a tile item is taken at normal quality")
  local n = math.min(stack.count, carried[stack.name] or 0)
  carried[stack.name] = (carried[stack.name] or 0) - n
  return n
end
function body.insert(stack)
  carried[stack.name] = (carried[stack.name] or 0) + stack.count
  inserted[stack.name] = (inserted[stack.name] or 0) + stack.count
  return stack.count
end

-- Walking: the body stands reach - 0.5 from the target, on dry land only.
local walks = {}
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function(_, c, target, reach)
  local dx, dy = c.position.x - target.x, c.position.y - target.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d <= reach then return "ok" end
  local spot = { x = target.x + dx / d * (reach - 0.5), y = target.y + dy / d * (reach - 0.5) }
  walks[#walks + 1] = spot
  if at(math.floor(spot.x), math.floor(spot.y)) == "water" then return { status = "failed", detail = "no path" } end
  c.position = spot
  return nil
end }
local supplied = {}
package.loaded["scripts.actions.supply"] = { resume = function() end,
  ensure = function(_, needs) supplied[#supplied + 1] = needs[1]; return { status = "done" } end }
package.loaded["scripts.actions.craft"] = { awaits = function() return false end }
local tiles_action = require("scripts.actions.tiles")
local jobs = require("scripts.jobs")

local function run(step, max_ticks)
  tiles_action.action.validate(step, 1)
  local task = tiles_action.action.make_task(step)
  task.id = 5
  tiles_action.action.runner.start(task)
  for _ = 1, max_ticks or 400 do
    game.tick = game.tick + 1
    per_tick = 0
    local result = tiles_action.action.runner.tick(task)
    if result then return result, task end
  end
end

-- The lake, nearest first: its middle is 3+ tiles from every shore.
carried.landfill = 36
local lake = run({ action = "place_tiles", item = "landfill", area = { left_top = { x = 20, y = 0 }, right_bottom = { x = 26, y = 6 } } })
local all_land = true
for x = 20, 25 do for y = 0, 5 do all_land = all_land and at(x, y) == "landfill" end end
check(lake and lake.status == "done" and lake.outcome.placed == 36 and all_land and carried.landfill == 0
  and lake.outcome.consumed.landfill == 36, "a 6 x 6 lake is landfilled, one landfill per tile")
check(max_per_tick <= tiles_action.PLACE_PER_TICK and #walks >= 2,
  "at most 8 tiles a tick, walking along as the shore grows into the lake")
local repeat_lake = run({ action = "place_tiles", item = "landfill", area = { left_top = { x = 20, y = 0 }, right_bottom = { x = 26, y = 6 } } })
check(repeat_lake.status == "done" and repeat_lake.outcome.already == 36 and repeat_lake.outcome.placed == 0
  and next(repeat_lake.outcome.consumed) == nil, "a repeat finds every tile already landfilled and pays nothing")

-- Stone path on grass; concrete on water is refused with the item to use.
carried["stone-brick"] = 9
local path = run({ action = "place_tiles", item = "stone-brick", area = { left_top = { x = 10, y = 10 }, right_bottom = { x = 13, y = 13 } } })
check(path.status == "done" and path.outcome.placed == 9 and at(11, 11) == "stone-path" and carried["stone-brick"] == 0,
  "stone brick lays stone path on grass")
world["40,10"] = "water"
carried.concrete = 5
local wet = run({ action = "place_tiles", item = "concrete", positions = { { x = 40.4, y = 10.7 } } })
check(wet.status == "failed" and wet.outcome.ineligible[1].code == "TILE_INELIGIBLE" and wet.outcome.ineligible[1].current == "water"
  and wet.outcome.ineligible[1].liquid == "water" and wet.outcome.ineligible[1].hint == "use landfill" and carried.concrete == 5,
  "concrete on water is TILE_INELIGIBLE, names the liquid and landfill, and consumes nothing")
local covered = run({ action = "place_tiles", item = "concrete", positions = { { x = 0, y = 0 } } })
check(covered.outcome.ineligible[1].code == "TILE_INELIGIBLE" and covered.outcome.ineligible[1].current == "space-platform-foundation"
  and covered.outcome.ineligible[1].liquid == nil,
  "a tile that cannot be covered is refused")
local far = run({ action = "place_tiles", item = "concrete", positions = { { x = 200, y = 0 } } })
check(far.outcome.ineligible[1].code == "TILE_UNCHARTED", "uncharted land is refused")
local blocked = run({ action = "place_tiles", item = "concrete", positions = { { x = 30, y = 30 }, { x = 31, y = 30 } } })
check(blocked.status == "partial" and blocked.outcome.placed == 1 and blocked.outcome.ineligible[1].code == "TILE_OCCUPIED"
  and carried.concrete == 4, "a tile an entity blocks is TILE_OCCUPIED and costs nothing")

-- Short of items: what is carried is laid; the rest is reported.
carried["stone-brick"] = 2
local short = run({ action = "place_tiles", item = "stone-brick", area = { left_top = { x = 10, y = 20 }, right_bottom = { x = 14, y = 21 } } })
check(short.status == "partial" and short.outcome.placed == 2 and short.outcome.remaining == 2 and supplied[#supplied].count == 4,
  "short of items, the carried ones are laid and the rest reported (supply asked once for all)")

-- A tile the body cannot get near ends the step with what is left.
for x = 60, 69 do for y = 0, 9 do world[x .. "," .. y] = "water" end end
world["64,4"], world["64,5"] = "grass", "grass"
carried.concrete = 2
body.position = { x = 50.5, y = 4.5 }
local island = run({ action = "place_tiles", item = "concrete", positions = { { x = 64, y = 4 }, { x = 64, y = 5 } } })
check(island.status == "failed" and island.outcome.code == "TILE_UNREACHABLE" and island.outcome.remaining == 2,
  "a tile the body cannot reach is TILE_UNREACHABLE with the remaining count")

-- Inputs.
local function refused(step, pattern)
  local ok, err = pcall(tiles_action.action.validate, step, 3)
  return not ok and tostring(err):match(pattern) ~= nil
end
check(refused({ item = "iron-chest", positions = { { x = 0, y = 0 } } }, "NOT_A_TILE_ITEM.*use place_entity"),
  "an entity item is NOT_A_TILE_ITEM, pointing at place_entity")
check(refused({ item = "landfill", area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 40, y = 40 } } }, "at most 1024"),
  "more than 1,024 tiles are refused")
check(refused({ item = "landfill" }, "exactly one of area"), "an area or positions is required")
check(refused({ item = "landfill", positions = { { x = 0, y = 0 } }, check_only = true }, "dry run"),
  "check_only is not a plan step")

-- check_only: reads, never writes.
for x = 70, 72 do world[x .. ",20"] = "water" end
local before = set_calls
local dry = jobs.run_now(tiles_action.check_job, { item = "landfill", check_only = true,
  area = { left_top = { x = 70, y = 20 }, right_bottom = { x = 74, y = 21 } } })
check(dry.check_only and dry.would_place == 3 and dry.items_needed == 3 and dry.ineligible[1].code == "TILE_INELIGIBLE"
  and set_calls == before, "check_only counts the tiles and items an area needs without placing any")

-- Concrete over stone path gives the bricks back, as brushing does.
carried.concrete, carried["stone-brick"], inserted["stone-brick"] = 9, 0, 0
local paved = run({ action = "place_tiles", item = "concrete", area = { left_top = { x = 10, y = 10 }, right_bottom = { x = 13, y = 13 } } })
check(paved.status == "done" and paved.outcome.placed == 9 and at(11, 11) == "concrete" and carried.concrete == 0
  and carried["stone-brick"] == 9 and paved.outcome.returned and paved.outcome.returned["stone-brick"] == 9
  and paved.detail:match("got back 9 stone%-brick"),
  "concrete over stone path returns one stone brick per covered tile")
check(run({ action = "place_tiles", item = "stone-brick", positions = { { x = 80, y = 1 } } }).outcome.returned == nil,
  "covering a tile that gives nothing returns nothing")

-- A tile that became the target after classification is counted, never paid.
for x = 74, 77 do world[x .. ",0"] = "water" end
carried.landfill = 4
body.position = { x = 75.5, y = 2.5 }
local later = { action = "place_tiles", item = "landfill", positions = { { x = 74, y = 0 }, { x = 75, y = 0 },
  { x = 76, y = 0 }, { x = 77, y = 0 } }, auto_supply = false }
local later_task = tiles_action.action.make_task(later)
later_task.id = 7
tiles_action.action.runner.start(later_task)
-- Classify everything, but hold placement by walking first.
later_task._walk_to = { x = 75, y = 0 }
local approach_mock = package.loaded["scripts.actions.approach"]
local real_ensure = approach_mock.ensure
approach_mock.ensure = function() return nil end
tiles_action.action.runner.tick(later_task)
approach_mock.ensure = real_ensure
check(later_task._s.index > #later_task._s.tiles and #later_task._s.eligible == 4, "all four tiles were classified eligible")
world["75,0"], world["76,0"] = "landfill", "landfill"
local real_set = set_calls
local raced
for _ = 1, 20 do raced = tiles_action.action.runner.tick(later_task); if raced then break end end
check(raced and raced.status == "done" and raced.outcome.placed == 2 and raced.outcome.already == 2
  and carried.landfill == 2 and set_calls - real_set == 2,
  "tiles landfilled by someone else after classification count as already and cost nothing")

-- Only an uncommon item carried: nothing is laid and nothing is created.
for x = 78, 79 do world[x .. ",0"] = "water" end
carried.landfill, uncommon.landfill = 0, 5
body.position = { x = 78.5, y = 2.5 }
real_set = set_calls
local quality = run({ action = "place_tiles", item = "landfill", positions = { { x = 78, y = 0 }, { x = 79, y = 0 } },
  auto_supply = false })
check(quality.status == "failed" and quality.outcome.code == "NO_CARRIED_ITEMS" and quality.outcome.placed == 0
  and set_calls == real_set and at(78, 0) == "water" and uncommon.landfill == 5,
  "carrying only an uncommon item lays nothing and creates no free tile")
uncommon.landfill = 0

-- check_only over a 128 x 128 area lists the first 1,024 tiles, counts the
-- rest arithmetically, and classifies under the work allowance.
tile_reads = 0
local big, big_ticks = jobs.run_now(tiles_action.check_job, { item = "stone-brick", check_only = true,
  area = { left_top = { x = -128, y = -128 }, right_bottom = { x = 0, y = 0 } } }, 600)
check(big and big.requested == tiles_action.MAX_TILES and big.omitted == 128 * 128 - tiles_action.MAX_TILES
  and tile_reads == tiles_action.MAX_TILES and big_ticks >= 3,
  "a 128 x 128 check_only reads 1,024 tiles over several ticks and counts the other 15,360")

mock.assert_clean()
print(failures == 0 and "\nALL PLACE TILES TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
