-- Offline tests for belt_joins: a dry run's belt joins as data. Lanes follow
-- what Factorio 2.0.77 did live: a straight join keeps lanes, a side-load
-- puts both source lanes on the near lane (one of them on an underground),
-- a splitter output joins like a belt, and a drop lands on the lane on its
-- side of the belt's centre line (the right lane on the line). Rows say
-- which items each joined lane holds, what the source adds and whether the
-- lane would carry more than one item kind; a connect_entities belt route
-- reports the same rows.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local function box(w, h) return { left_top = { x = -w / 2, y = -h / 2 }, right_bottom = { x = w / 2, y = h / 2 } } end
local protos = {
  ["transport-belt"] = { name = "transport-belt", type = "transport-belt", collision_box = box(0.8, 0.8) },
  ["underground-belt"] = { name = "underground-belt", type = "underground-belt", collision_box = box(0.8, 0.8),
    max_underground_distance = 5 },
  splitter = { name = "splitter", type = "splitter", collision_box = box(1.8, 0.8) },
  inserter = { name = "inserter", type = "inserter", collision_box = box(0.3, 0.3),
    inserter_pickup_position = { 0, -1 }, inserter_drop_position = { 0, 1.2 } },
  ["burner-mining-drill"] = { name = "burner-mining-drill", type = "mining-drill", collision_box = box(1.4, 1.4),
    vector_to_place_result = { -0.5, -1.3 } },
}
_G.prototypes = { entity = {
  ["iron-ore"] = { mineable_properties = { products = { { type = "item", name = "iron-ore", amount = 1 } } } },
  coal = { mineable_properties = { products = { { type = "item", name = "coal", amount = 1 } } } },
}, item = {} }
for name, proto in pairs(protos) do
  prototypes.entity[name] = proto
  prototypes.item[name] = { name = name, place_result = proto }
end

local geometry = require("scripts.placement_geometry")
local joins = require("scripts.belt_joins")

-- Standing belts: transport lines (1 left, 2 right, an underground's 3 and
-- 4 again left and right) and belt_neighbours inputs.
local world = {}
local function standing(name, x, y, direction, lanes, extra)
  local proto = protos[name]
  local e = { valid = true, name = name, type = proto.type, position = { x = x, y = y }, direction = direction,
    bounding_box = geometry.footprint(proto, { x = x, y = y }, direction), belt_neighbours = { inputs = {}, outputs = {} } }
  for k, v in pairs(extra or {}) do e[k] = v end
  local lines = e.type == "underground-belt" and 4 or 2
  e.get_max_transport_line_index = function() return lines end
  e.get_transport_line = function(index)
    local names = lanes and lanes[index] or {}
    return { get_contents = function()
      local out = {}
      for _, n in ipairs(names) do out[#out + 1] = { name = n, quality = "normal", count = 1 } end
      return out
    end }
  end
  world[#world + 1] = e
  return e
end

local queries = 0
local io = {
  query = function(area)
    queries = queries + 1
    local out = {}
    for _, e in ipairs(world) do
      local b = e.bounding_box
      if b.left_top.x < area.right_bottom.x and b.right_bottom.x > area.left_top.x
        and b.left_top.y < area.right_bottom.y and b.right_bottom.y > area.left_top.y then out[#out + 1] = e end
    end
    return out
  end,
  charge = function() end,
}

-- A planned list as build_layout's survey has it.
local function survey(list, mined)
  local planned = {}
  for i, e in ipairs(list) do
    local proto = protos[e[1]]
    local position, direction = { x = e[2], y = e[3] }, e[4] or 0
    planned[i] = { name = e[1], proto = proto, position = position, direction = direction,
      area = geometry.footprint(proto, position, direction), under = e[5] }
  end
  local tiles, J = joins.index(planned), joins.start(planned)
  for i, names in pairs(mined or {}) do joins.set_mined(J, i, names) end
  while not joins.done(J) do joins.scan(J, planned, tiles, io) end
  return joins.finish(J, planned, tiles, io)
end

local function find(rows, x, y, from_x, from_y)
  for _, row in ipairs(rows) do
    if row.x == x and row.y == y and (from_x == nil or row.from.x == from_x and row.from.y == from_y) then return row end
  end
end
local function lane(row, name)
  for _, l in ipairs(row and row.lanes or {}) do if l.lane == name then return l end end
end
local function list(t) return table.concat(t or { "nil" }, ",") end

-- A straight join that does not mix: a drill drops iron ore onto a planned
-- belt that runs into a standing iron-ore belt from behind.
world = {}
standing("transport-belt", 0.5, 0.5, 0, { { "iron-ore" }, { "iron-ore" } })
local rows = survey({ { "transport-belt", 0.5, 1.5, 0 }, { "burner-mining-drill", -1, 2, 4 } }, { [2] = { "iron-ore" } })
local straight = find(rows, 0.5, 0.5)
check(straight and straight.standing and straight.join == "straight" and not straight.from.standing
  and #straight.lanes == 2, "a planned belt from behind joins a standing belt straight, on both lanes")
local left, right = lane(straight, "left"), lane(straight, "right")
check(left and list(left.items) == "iron-ore" and list(left.adds) == "iron-ore" and left.mixes == false
  and right and list(right.adds) == "" and right.mixes == false,
  "the drill's ore lands on the left lane; iron ore onto iron ore does not mix")
local drop = find(rows, 0.5, 1.5)
check(drop and drop.join == "drop" and not drop.standing and drop.from.name == "burner-mining-drill"
  and #drop.lanes == 1 and drop.lanes[1].lane == "left" and list(drop.lanes[1].adds) == "iron-ore",
  "a drill drop west of a north belt's centre line lands on its left lane with what the drill mines")

-- The same join onto a copper lane mixes.
world = {}
standing("transport-belt", 0.5, 0.5, 0, { { "copper-ore" }, {} })
rows = survey({ { "transport-belt", 0.5, 1.5, 0 }, { "burner-mining-drill", -1, 2, 4 } }, { [2] = { "iron-ore" } })
left = lane(find(rows, 0.5, 0.5), "left")
check(left and list(left.items) == "copper-ore" and list(left.adds) == "iron-ore" and left.mixes == true,
  "iron ore joining a copper-ore lane mixes")

-- A side-load onto one lane: a standing coal belt feeds a planned belt that
-- meets a standing iron belt (with a belt behind it) from the west.
world = {}
local receiver = standing("transport-belt", 10.5, 0.5, 0, { { "iron-plate" }, { "iron-plate" } })
local behind = standing("transport-belt", 10.5, 1.5, 0, { {}, {} })
receiver.belt_neighbours.inputs = { behind }
standing("transport-belt", 8.5, 0.5, 4, { { "coal" }, { "coal" } })
rows = survey({ { "transport-belt", 9.5, 0.5, 4 } })
local side = find(rows, 10.5, 0.5)
check(side and side.join == "side_load" and #side.lanes == 1 and side.lanes[1].lane == "left"
  and list(side.lanes[1].items) == "iron-plate" and list(side.lanes[1].adds) == "coal" and side.lanes[1].mixes == true,
  "a side-load from the west puts both source lanes on the left lane; coal onto iron plates mixes")
local fed = find(rows, 9.5, 0.5)
check(fed and fed.from.standing and not fed.standing and fed.join == "straight"
  and list(lane(fed, "left").adds) == "coal" and lane(fed, "left").mixes == false,
  "a standing belt feeding a planned belt is a row, with what its lanes carry now")

-- With nothing behind the receiver, its one side input turns it: lanes
-- kept. A planned belt joining a standing curve from behind turns the
-- curve's side input into a side-load onto the near lane.
world = {}
standing("transport-belt", 10.5, 0.5, 0, { { "iron-plate" }, {} })
rows = survey({ { "transport-belt", 9.5, 0.5, 4 } })
local curve = find(rows, 10.5, 0.5)
check(curve and curve.join == "straight" and #curve.lanes == 2, "the only side input of a belt with nothing behind it keeps lanes")
world = {}
local bend = standing("transport-belt", 20.5, 0.5, 0, { { "stone" }, { "stone" } })
local east_input = standing("transport-belt", 21.5, 0.5, 12, { { "stone" }, { "stone" } })
bend.belt_neighbours.inputs = { east_input }
rows = survey({ { "transport-belt", 20.5, 1.5, 0 } })
local turned = find(rows, 20.5, 0.5, 21.5, 0.5)
check(turned and turned.join == "side_load" and turned.from.standing and #turned.lanes == 1
  and turned.lanes[1].lane == "right" and list(turned.lanes[1].adds) == "stone",
  "a planned belt behind a standing curve makes its side input side-load onto the near (right) lane")

-- A splitter output joins like a belt: onto an east belt from the south it
-- side-loads the right lane.
world = {}
local first = standing("transport-belt", 30.5, -0.5, 4, { {}, {} })
local second = standing("transport-belt", 31.5, -0.5, 4, { {}, {} })
local back = standing("transport-belt", 29.5, -0.5, 4, { {}, {} })
first.belt_neighbours.inputs, second.belt_neighbours.inputs = { back }, { first }
standing("transport-belt", 30.5, 1.5, 0, { { "stone" }, { "stone" } })
rows = survey({ { "splitter", 31, 0.5, 0 } })
local out_a, out_b = find(rows, 30.5, -0.5), find(rows, 31.5, -0.5)
check(out_a and out_b and out_a.join == "side_load" and out_b.join == "side_load" and out_a.from.name == "splitter"
  and lane(out_a, "right") and list(lane(out_a, "right").adds) == "stone" and lane(out_a, "right").mixes == false
  and lane(out_a, "left") == nil, "each splitter output side-loads the right lane of an east belt north of it")

-- An inserter drop: what it moves is unknown in a dry run (adds null), and
-- the lane is the side of the centre line its drop point is on.
world = {}
standing("transport-belt", 40.5, 1.5, 4, { {}, { "iron-plate" } })
standing("transport-belt", 50.5, 1.5, 0, { {}, { "iron-plate", "copper-plate" } })
rows = survey({ { "inserter", 40.5, 0.5, 0 }, { "inserter", 50.5, 0.5, 0 } })
local across, along = find(rows, 40.5, 1.5), find(rows, 50.5, 1.5)
check(across and across.join == "drop" and across.lanes[1].lane == "right" and across.lanes[1].adds == nil
  and across.lanes[1].mixes == nil and list(across.lanes[1].items) == "iron-plate",
  "an inserter drops on the far (right) lane of an east belt; what it adds is unknown, so mixing is open")
check(along and along.lanes[1].lane == "right" and along.lanes[1].mixes == true,
  "a drop on the centre line of a belt heading at the inserter lands on the right lane; two kinds already mix")

-- An underground entrance side-loaded from the west passes only the source
-- lane on its back half (the source's right lane) onto its left lane.
world = {}
standing("underground-belt", 60.5, 0.5, 0, { {}, {} }, { belt_to_ground_type = "input" })
standing("transport-belt", 58.5, 0.5, 4, { { "coal" }, { "stone" } })
rows = survey({ { "transport-belt", 59.5, 0.5, 4 } })
local entrance = find(rows, 60.5, 0.5)
check(entrance and entrance.join == "side_load" and #entrance.lanes == 1 and entrance.lanes[1].lane == "left"
  and list(entrance.lanes[1].adds) == "stone",
  "a side-load onto an underground entrance passes only the source lane on its back half")

-- A planned run whose start nothing feeds adds what is unknown.
world = {}
standing("transport-belt", 70.5, 0.5, 0, { { "iron-plate" }, {} })
rows = survey({ { "transport-belt", 70.5, 2.5, 0 }, { "transport-belt", 70.5, 1.5, 0 } })
local open = find(rows, 70.5, 0.5)
check(open and lane(open, "left").adds == nil and lane(open, "left").mixes == nil and lane(open, "right").mixes == nil
  and find(rows, 70.5, 1.5) == nil, "a run nothing feeds adds an unknown; a run's own belts are no join rows")

-- Two planned runs merging on a planned belt are rows; one query per piece
-- whose sides the layout leaves open.
world = {}
queries = 0
rows = survey({ { "transport-belt", 80.5, 0.5, 0 }, { "transport-belt", 80.5, 1.5, 0 }, { "transport-belt", 79.5, 0.5, 4 },
  { "burner-mining-drill", 81, 3, 0 } }, { [4] = { "coal" } })
local merge = find(rows, 80.5, 0.5, 79.5, 0.5)
check(merge and not merge.standing and merge.join == "side_load" and lane(merge, "left").mixes == nil
  and list(lane(find(rows, 80.5, 0.5, 80.5, 1.5), "right").adds) == "coal",
  "two planned runs meeting on a planned belt are both rows; the drill's coal rides the right lane")
check(queries == 3, "one small query per planned belt piece with an open side (" .. queries .. ")")

-- connect_entities: a belt route into a standing belt reports its join.
world = {}
local target = standing("transport-belt", 93.5, 5.5, 0, { { "iron-plate" }, {} })
target.belt_neighbours.inputs = { standing("transport-belt", 93.5, 6.5, 0, { {}, {} }) }
local surface = {
  find_entities_filtered = function(filter)
    if filter.area then return io.query(filter.area) end
    local out = {}
    for _, e in ipairs(world) do
      if math.abs(e.position.x - filter.position.x) < 0.3 and math.abs(e.position.y - filter.position.y) < 0.3 then out[#out + 1] = e end
    end
    return out
  end,
  can_place_entity = function(args)
    for _, e in ipairs(world) do
      if math.abs(e.position.x - args.position.x) < 0.5 and math.abs(e.position.y - args.position.y) < 0.5 then return false end
    end
    return true
  end,
}
local force = { is_chunk_charted = function() return true end, recipes = {} }
package.loaded["scripts.companion"] = { require_companion = function()
  return { surface = surface, force = force, get_item_count = function() return 0 end }
end }
_G.defines = { build_check_type = { manual = 1 } }
local connect = require("scripts.connect_entities")
local jobs = require("scripts.jobs")
local route = jobs.run_now(connect.job, { kind = "belt", prototype = "transport-belt", from = { x = 90.5, y = 5.5 },
  to = { x = 93.5, y = 5.5 }, max_length = 10, underground = false })
local joined = route and route.belt_joins and find(route.belt_joins, 93.5, 5.5)
check(joined and joined.join == "side_load" and joined.standing and lane(joined, "left")
  and list(lane(joined, "left").items) == "iron-plate" and lane(joined, "left").mixes == nil,
  "a connect_entities belt route lists its side-load onto the standing belt it ends at")

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
