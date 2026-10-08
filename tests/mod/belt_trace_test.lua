-- Belt lanes and the bounded belt trace (belt_trace.lua): lane mix flags, the
-- per-call and per-tick caps, loops, the chart edge, and the sources that put
-- items onto a traced lane. Belts are joined the way 2.0.77 reports them:
-- belt_neighbours between belts, neighbours between an underground pair.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local body
package.loaded["scripts.companion"] = {}
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
_G.defines = { inventory = { fuel = 1, chest = 1 }, entity_status = {} }
_G.game = { tick = 100 }

local uncharted = {}
local force = mock.force({
  is_chunk_charted = function(_, chunk) return not uncharted[chunk.x .. "," .. chunk.y] end,
})

local droppers = {}
local queries = 0
local surface = mock.surface({
  index = 1, name = "nauvis",
  find_entities_filtered = function(filter)
    queries = queries + 1
    local area, found = filter.area, {}
    for _, e in ipairs(droppers) do
      if e.position.x >= area[1][1] and e.position.x <= area[2][1]
        and e.position.y >= area[1][2] and e.position.y <= area[2][2] then
        found[#found + 1] = e
      end
    end
    return found
  end,
})

local belt_trace = require("scripts.belt_trace")
local jobs = require("scripts.jobs")
local inspect = require("scripts.inspect")

local units = 0
local contents = {}
local function new_line()
  local line = {}
  line.get_contents = function() return contents[line] or {} end
  return mock.transport_line(line)
end

-- A belt-like entity on tile (x, y); direction 0 north, 4 east, 8 south, 12 west.
local function belt(x, y, direction, kind, line_total, shape)
  units = units + 1
  local lines = {}
  local e = mock.entity({
    valid = true, name = kind or "transport-belt", type = kind or "transport-belt", force = force, surface = surface,
    position = { x = x + 0.5, y = y + 0.5 }, direction = direction, unit_number = units, belt_shape = shape or "straight",
    belt_neighbours = { inputs = {}, outputs = {} },
    bounding_box = { left_top = { x = x + 0.1, y = y + 0.1 }, right_bottom = { x = x + 0.9, y = y + 0.9 } },
    get_max_transport_line_index = function() return #lines end,
    get_transport_line = function(i) return lines[i] end,
  })
  for i = 1, line_total or 2 do lines[i] = new_line() end
  return e, lines
end

local function link(from, to)
  local outputs, inputs = from.belt_neighbours.outputs, to.belt_neighbours.inputs
  outputs[#outputs + 1], inputs[#inputs + 1] = to, from
end

-- A straight run east along y from x0 to x1: {entity, lines} per tile.
local function run(x0, x1, y)
  local list = {}
  for x = x0, x1 do
    local e, lines = belt(x, y, 4)
    list[#list + 1] = { e = e, lines = lines }
    local prev = list[#list - 1]
    if prev then link(prev.e, e) end
  end
  return list
end

local c = { surface = surface, force = force }
local definition = {
  start = function(p) return belt_trace.start(p.entity, p.direction, c, p.cap) end,
  step = function(state, budget) return belt_trace.step(state, budget, c) end,
}

-- ------------------------------------------------------------------ lanes

local lanes_belt, lanes_of = belt(0, 10, 4)
local function mix_of(left, right)
  contents[lanes_of[1]], contents[lanes_of[2]] = left, right
  local lanes, mix = belt_trace.lanes(lanes_belt)
  return lanes, mix
end
local lanes, mix = mix_of({}, {})
check(mix == "empty" and next(lanes.left) == nil and next(lanes.right) == nil, "an empty belt is empty")
lanes, mix = mix_of({ { name = "iron-plate", count = 3, quality = "normal" } }, { { name = "iron-plate", count = 2, quality = "normal" } })
check(mix == "pure" and lanes.left["iron-plate"] == 3 and lanes.right["iron-plate"] == 2, "one kind on both lanes is pure")
lanes, mix = mix_of({ { name = "iron-plate", count = 3, quality = "normal" } }, {})
check(mix == "pure", "one kind on one lane is pure")
lanes, mix = mix_of({ { name = "iron-plate", count = 3, quality = "normal" } }, { { name = "copper-plate", count = 1, quality = "normal" } })
check(mix == "separated" and lanes.right["copper-plate"] == 1, "one kind per lane, different, is separated")
lanes, mix = mix_of({ { name = "iron-plate", count = 3, quality = "normal" }, { name = "coal", count = 1, quality = "normal" } }, {})
check(mix == "mixed" and lanes.left.coal == 1, "two kinds on one lane is mixed")
lanes, mix = mix_of({ { name = "iron-plate", count = 1, quality = "normal" }, { name = "iron-plate", count = 1, quality = { name = "uncommon" } } }, {})
check(mix == "mixed" and lanes.left["iron-plate@uncommon"] == 1, "another quality is another kind")
local underground, u_lines = belt(0, 12, 4, "underground-belt", 4)
contents[u_lines[3]] = { { name = "coal", count = 2, quality = "normal" } }
contents[u_lines[4]] = { { name = "stone", count = 1, quality = "normal" } }
lanes, mix = belt_trace.lanes(underground)
check(lanes.left.coal == 2 and lanes.right.stone == 1 and mix == "separated",
  "an underground's underground lines count in their lane (odd left, even right)")
contents[lanes_of[1]], contents[lanes_of[2]] = nil, nil

-- -------------------------------------------------------------- the caps

local long = run(0, 499, 40)
local per_tick, last = {}, 0
local capped_definition = {
  start = definition.start,
  step = function(state, budget)
    local result = belt_trace.step(state, budget, c)
    per_tick[#per_tick + 1] = state.belt_count - last
    last = state.belt_count
    return result
  end,
}
local capped, ticks = jobs.run_now(capped_definition, { entity = long[500].e, direction = "up" })
local most = 0
for _, n in ipairs(per_tick) do most = math.max(most, n) end
check(capped.belts == belt_trace.MAX_BELTS and capped.truncated == true and capped.max_belts == 400,
  "a trace walks at most 400 belts and says it was truncated")
check(ticks >= 6 and most <= 66 and most >= 50, "a trace walks about 64 belts a tick (most " .. most .. ", ticks " .. ticks .. ")")
local short = jobs.run_now(definition, { entity = long[500].e, direction = "up", cap = 10 })
check(short.belts == 10 and short.truncated, "a smaller remaining cap holds")

-- ---------------------------------------------------------------- a loop

local ring = {}
local ring_tiles = { { 0, 60, 4, "right" }, { 1, 60, 4 }, { 2, 60, 8, "right" }, { 2, 61, 8 }, { 2, 62, 12, "right" },
  { 1, 62, 12 }, { 0, 62, 0, "right" }, { 0, 61, 0 } }
for i, t in ipairs(ring_tiles) do
  local e, lines = belt(t[1], t[2], t[3], nil, nil, t[4])
  ring[i] = { e = e, lines = lines }
end
for i = 1, #ring do
  local nxt = ring[i % #ring + 1]
  link(ring[i].e, nxt.e)
end
local looped, loop_ticks = jobs.run_now(definition, { entity = ring[1].e, direction = "down" })
check(looped.loop == true and looped.belts == 8 and looped.truncated == false and loop_ticks == 1,
  "a loop is walked once and reported")
local straight = jobs.run_now(definition, { entity = long[10].e, direction = "down", cap = 5 })
check(straight.loop == false, "a straight run is no loop")

-- ------------------------------------------------------- the chart edge

local edge = run(28, 37, 0)
uncharted["1,0"] = true
local stopped = jobs.run_now(definition, { entity = edge[1].e, direction = "down" })
check(stopped.belts == 4 and stopped.stopped and stopped.stopped.uncharted == 1 and stopped.truncated == false,
  "a trace stops where the belt leaves charted chunks")
uncharted["1,0"] = nil
local other = mock.force({ is_chunk_charted = function() return true end })
edge[6].e.force = other
local foreign = jobs.run_now(definition, { entity = edge[1].e, direction = "down" })
check(foreign.belts == 5 and foreign.stopped.other_force == 1, "a trace does not enter another force's belt")
edge[6].e.force = force

-- --------------------------------------------- sources onto a mixed lane

-- An east run y = 80, x = 0..5. A drill north of x=1 drops iron ore onto
-- its left (north) lane; an inserter south of x=3 drops coal onto the far
-- (left) lane; a belt north of x=4 side-loads copper plate onto the left lane.
local line = run(0, 5, 80)
for i = 2, 6 do contents[line[i].lines[1]] = { { name = "iron-ore", count = 1, quality = "normal" } } end
for i = 4, 6 do contents[line[i].lines[1]][2] = { name = "coal", count = 1, quality = "normal" } end
contents[line[6].lines[1]][3] = { name = "copper-plate", count = 2, quality = "normal" }
contents[line[3].lines[2]] = { { name = "stone", count = 1, quality = "normal" } }
local feeder, feeder_lines = belt(4, 79, 8)
link(feeder, line[5].e)
contents[feeder_lines[1]] = { { name = "copper-plate", count = 1, quality = "normal" } }
local held = mock.item_stack({ valid_for_read = true, name = "coal", count = 1, quality = { name = "normal" } })
local chest = mock.entity({ valid = true, name = "wooden-chest", position = { x = 3.5, y = 82.5 } })
local inserter = mock.entity({ valid = true, name = "burner-inserter", type = "inserter", unit_number = 9001,
  position = { x = 3.5, y = 81.5 }, drop_position = { x = 3.5, y = 80.7 }, held_stack = held, pickup_target = chest })
local ore = mock.entity({ valid = true, prototype = mock.entity_prototype({ mineable_properties = { products = { { name = "iron-ore" } } } }) })
local drill = mock.entity({ valid = true, name = "burner-mining-drill", type = "mining-drill", unit_number = 9002,
  position = { x = 2, y = 78 }, drop_position = { x = 1.5, y = 80.3 }, mining_target = ore })
local far_inserter = mock.entity({ valid = true, name = "inserter", type = "inserter", unit_number = 9003,
  position = { x = 9.5, y = 81.5 }, drop_position = { x = 9.5, y = 80.7 }, held_stack = held })
droppers = { inserter, drill, far_inserter }

local up = jobs.run_now(definition, { entity = line[6].e, direction = "up" })
local left = up.lanes.left
local kinds = {}
for _, row in ipairs(left.sources) do kinds[row.kind] = row end
check(left.items["iron-ore"] == 5 and left.items.coal == 3 and left.items["copper-plate"] == 3,
  "the left lane's items along the trace are counted (copper on the side-loader too)")
check(left.first_seen.coal.belts_from_start == 0 and left.first_seen["iron-ore"].belts_from_start == 0
  and up.lanes.right.first_seen.stone.position.x == 2.5 and up.lanes.right.first_seen.stone.belts_from_start == 3,
  "first_seen names the nearest traced belt carrying each item")
check(kinds.inserter and kinds.inserter.lane == "left" and kinds.inserter.holding.item == "coal"
  and kinds.inserter.onto.x == 3.5 and kinds.inserter.pickup_target.name == "wooden-chest"
  and kinds.inserter.belts_from_start == 2,
  "an inserter dropping onto the lane is a source with its hand and pickup target")
check(kinds.mining_drill and kinds.mining_drill.lane == "left" and kinds.mining_drill.adds[1] == "iron-ore"
  and kinds.mining_drill.onto.x == 1.5,
  "a mining drill dropping onto the lane is a source with what it mines")
check(kinds.side_load and kinds.side_load.position.x == 4.5 and kinds.side_load.position.y == 79.5
  and kinds.side_load.items["copper-plate"] == 1 and kinds.side_load.onto.x == 4.5,
  "a side-loading belt is a source with the items on it")
check(#up.lanes.right.sources == 0, "nothing drops onto the right lane")
local far = false
for _, lane in pairs(up.lanes) do for _, row in ipairs(lane.sources) do if row.position.x == 9.5 then far = true end end end
check(not far, "an inserter dropping elsewhere is not a source")

local down = jobs.run_now(definition, { entity = line[1].e, direction = "down" })
local down_kinds = {}
for _, row in ipairs(down.lanes.left.sources) do down_kinds[row.kind] = row end
check(down.belts == 6 and down_kinds.inserter and down_kinds.mining_drill and down_kinds.side_load
  and down.lanes.left.items["copper-plate"] == 2,
  "a down trace finds what joins the lane downstream")
local from_mid = jobs.run_now(definition, { entity = line[5].e, direction = "down" })
local start_feeders = 0
for _, row in ipairs(from_mid.lanes.left.sources) do if row.kind == "side_load" or row.kind == "belt" then start_feeders = start_feeders + 1 end end
check(start_feeders == 0, "a down trace does not list what feeds its start belt")

-- A belt joining straight in a down trace: down from the side-loader, the
-- run it lands on brings items from its own upstream.
local joined = jobs.run_now(definition, { entity = feeder, direction = "down" })
local joins = {}
for _, row in ipairs(joined.lanes.left.sources) do joins[row.kind] = row end
check(joins.belt and joins.belt.position.x == 3.5 and joins.belt.items["iron-ore"] == 1,
  "a down trace lists a belt joining the walked lane with its items")

-- ------------------------- undergrounds, splitters, curves, right side-loads

-- East along y = 120: belts x=0..1, an underground pair 2 -> 5, a belt at 6,
-- a splitter at 7 (inputs: the run and a belt at (6, 121)), out at 8.
local under = run(0, 1, 120)
local entrance = belt(2, 120, 4, "underground-belt", 4)
local exit = belt(5, 120, 4, "underground-belt", 4)
entrance.belt_to_ground_type, exit.belt_to_ground_type = "input", "output"
entrance.neighbours, exit.neighbours = exit, entrance
link(under[2].e, entrance)
local after, after_lines = belt(6, 120, 4)
link(exit, after)
local splitter = belt(7, 120, 4, "splitter", 8)
splitter.bounding_box = { left_top = { x = 7.1, y = 120.1 }, right_bottom = { x = 7.9, y = 121.9 } }
local beside, beside_lines = belt(6, 121, 4)
link(after, splitter); link(beside, splitter)
local out, out_lines = belt(8, 120, 4)
link(splitter, out)
contents[under[1].lines[2]] = { { name = "coal", count = 1, quality = "normal" } }
contents[beside_lines[1]] = { { name = "stone", count = 1, quality = "normal" } }
local through = jobs.run_now(definition, { entity = out, direction = "up" })
local split_row
for _, row in ipairs(through.lanes.left.sources) do if row.kind == "splitter" then split_row = row end end
check(through.belts == 8 and through.lanes.right.first_seen.coal.belts_from_start == 6
  and through.lanes.left.first_seen.stone.position.y == 121.5 and split_row and split_row.position.x == 7.5,
  "a trace crosses an underground pair and both splitter inputs, keeping lanes")
local down_split = jobs.run_now(definition, { entity = under[1].e, direction = "down" })
local joined_split
for _, row in ipairs(down_split.lanes.left.sources) do if row.kind == "belt" then joined_split = row end end
check(down_split.belts == 7 and joined_split and joined_split.position.y == 121.5 and joined_split.items.stone == 1,
  "down, the splitter's other input is a belt joining the lane")

-- A belt heading south curves east: lanes keep their side. A belt from the
-- south side-loads the right lane only.
local bend_in, bend_lines = belt(20, 129, 8)
local bend = belt(20, 130, 4, nil, nil, "left")
local bend_out = belt(21, 130, 4)
local from_south, south_lines = belt(21, 131, 0)
link(bend_in, bend); link(bend, bend_out); link(from_south, bend_out)
contents[bend_lines[2]] = { { name = "iron-plate", count = 1, quality = "normal" } }
contents[south_lines[1]] = { { name = "sulfur", count = 1, quality = "normal" } }
local bent = jobs.run_now(definition, { entity = bend_out, direction = "up" })
local right_side = {}
for _, row in ipairs(bent.lanes.right.sources) do right_side[row.kind] = row end
check(bent.lanes.right.items["iron-plate"] == 1 and bent.lanes.left.items["iron-plate"] == nil,
  "a curve keeps the lane an item rides on")
check(right_side.side_load and right_side.side_load.position.y == 131.5 and bent.lanes.right.items.sulfur == 1
  and #bent.lanes.left.sources == 0 and bent.lanes.left.items.sulfur == nil,
  "a side-load from the right side feeds only the right lane")

-- ------------------------------ side-loaders the trace may not read

-- East along y = 128 (chunk row 4), x = 0..3. A belt from the north at
-- (1, 127) lies in chunk row 3, marked uncharted; a belt from the south at
-- (2, 129) belongs to another force. Neither is read, up or down.
local hidden_row = run(0, 3, 128)
local from_uncharted, uncharted_lines = belt(1, 127, 8)
local from_other, other_lines = belt(2, 129, 0)
from_other.force = mock.force({ is_chunk_charted = function() return true end })
link(from_uncharted, hidden_row[2].e); link(from_other, hidden_row[3].e)
contents[uncharted_lines[1]] = { { name = "sulfur", count = 1, quality = "normal" } }
contents[other_lines[1]] = { { name = "stone", count = 1, quality = "normal" } }
uncharted["0,3"] = true
local function hidden_rows(trace)
  local n = 0
  for _, lane in pairs(trace.lanes) do
    for _, row in ipairs(lane.sources) do if row.kind == "side_load" then n = n + 1 end end
    if lane.items.sulfur or lane.items.stone then n = n + 1 end
  end
  return n
end
for _, direction in ipairs({ "up", "down" }) do
  local start = direction == "up" and hidden_row[4].e or hidden_row[1].e
  local hidden = jobs.run_now(definition, { entity = start, direction = direction })
  check(hidden_rows(hidden) == 0 and hidden.belts == 4 and hidden.stopped
    and hidden.stopped.uncharted == 1 and hidden.stopped.other_force == 1,
    "a side-loader uncharted or of another force is counted, never read (" .. direction .. ")")
end
uncharted["0,3"] = nil

-- ------------------------------------------- side-loads onto undergrounds

-- East along y = 140: an entrance at x = 2 fed from the north (iron left,
-- copper right), its exit at x = 5 fed from the south (coal left, stone
-- right), then a belt at 6. Only the feeder lane over the open half passes:
-- the entrance's back half, the exit's front half (checked on 2.0.77).
local hood_in, hood_in_lines = belt(2, 140, 4, "underground-belt", 4)
local hood_out = belt(5, 140, 4, "underground-belt", 4)
hood_in.belt_to_ground_type, hood_out.belt_to_ground_type = "input", "output"
hood_in.neighbours, hood_out.neighbours = hood_out, hood_in
local hood_after = belt(6, 140, 4)
link(hood_out, hood_after)
local north_feed, north_lines = belt(2, 139, 8)
local south_feed, south_lines = belt(5, 141, 0)
link(north_feed, hood_in); link(south_feed, hood_out)
contents[north_lines[1]] = { { name = "iron-plate", count = 16, quality = "normal" } }
contents[north_lines[2]] = { { name = "copper-plate", count = 2, quality = "normal" } }
contents[south_lines[1]] = { { name = "coal", count = 16, quality = "normal" } }
contents[south_lines[2]] = { { name = "stone", count = 2, quality = "normal" } }
contents[hood_in_lines[1]] = { { name = "iron-gear-wheel", count = 1, quality = "normal" } }
local hood_up = jobs.run_now(definition, { entity = hood_after, direction = "up" })
local hood_rows = {}
for name, lane in pairs(hood_up.lanes) do
  for _, row in ipairs(lane.sources) do if row.kind == "side_load" then hood_rows[name] = row end end
end
check(hood_up.lanes.left.items["copper-plate"] == 2 and hood_up.lanes.left.items["iron-plate"] == nil
  and hood_rows.left and hood_rows.left.feeder_lane == "right" and hood_rows.left.items["copper-plate"] == 2
  and hood_rows.left.items["iron-plate"] == nil,
  "onto an entrance only the feeder lane over its back half feeds the lane")
check(hood_up.lanes.right.items.stone == 2 and hood_up.lanes.right.items.coal == nil
  and hood_rows.right and hood_rows.right.feeder_lane == "right" and hood_rows.right.items.coal == nil,
  "onto an exit only the feeder lane over its front half feeds the lane")
local hood_down = jobs.run_now(definition, { entity = north_feed, direction = "down" })
check(hood_down.lanes.left.items["iron-plate"] == 16 and hood_down.lanes.left.first_seen["iron-plate"].belts_from_start == 0
  and hood_down.lanes.left.items["iron-gear-wheel"] == nil and hood_down.lanes.right.items["iron-gear-wheel"] == 1
  and hood_down.belts == 4 and hood_down.lanes.right.items["copper-plate"] == 2,
  "down, the lane the hood holds back goes no further")
local held_back = 0
for _, row in ipairs(hood_down.lanes.right.sources) do
  if row.kind == "side_load" and row.position.y == 141.5 then held_back = held_back + 1 end
end
check(held_back == 0, "down, a side-load onto the exit's other lane is not a source of the walked lane")

-- ------------------------------------------ a splitter side-loading a row

-- A splitter facing south over tiles x = 10, 11 at y = 149 feeds the side
-- of an east row y = 150, x = 9..12 (a belt behind each, so neither curves):
-- all of it lands on the row's left (north) lane, whatever lane it rode on
-- in the splitter (checked on 2.0.77).
local side_splitter, splitter_lines = belt(10, 149, 8, "splitter", 8)
side_splitter.position = { x = 11, y = 149.5 }
side_splitter.bounding_box = { left_top = { x = 10.1, y = 149.1 }, right_bottom = { x = 11.9, y = 149.9 } }
local split_row = run(9, 12, 150)
link(side_splitter, split_row[2].e); link(side_splitter, split_row[3].e)
contents[splitter_lines[5]] = { { name = "coal", count = 4, quality = "normal" } }
contents[splitter_lines[6]] = { { name = "stone", count = 12, quality = "normal" } }
local split_up = jobs.run_now(definition, { entity = split_row[4].e, direction = "up" })
check(split_up.lanes.left.items.coal == 4 and split_up.lanes.left.items.stone == 12
  and split_up.lanes.right.items.stone == nil and #split_up.lanes.right.sources == 0,
  "a splitter side-loading a row feeds only the lane on its side")

-- A splitter's lanes sum both its belts; its mix judges each lane alone.
contents[splitter_lines[5]], contents[splitter_lines[6]] = nil, nil
contents[splitter_lines[1]] = { { name = "coal", count = 1, quality = "normal" } }
contents[splitter_lines[3]] = { { name = "stone", count = 1, quality = "normal" } }
local split_lanes, split_mix = belt_trace.lanes(side_splitter)
check(split_mix == "separated" and split_lanes.left.coal == 1 and split_lanes.left.stone == 1,
  "a splitter with one kind on each of its belts' left lanes is not mixed")
contents[splitter_lines[5]] = { { name = "coal", count = 1, quality = "normal" }, { name = "stone", count = 1, quality = "normal" } }
split_lanes, split_mix = belt_trace.lanes(side_splitter)
check(split_mix == "mixed", "a splitter lane holding two kinds is mixed")

-- ------------------------------------------- inspect with trace (one call)

body = mock.entity({ valid = true, position = { x = 0, y = 80 }, surface = surface, force = force })
local by_position = {}
for _, entry in ipairs(line) do by_position[entry.e.position.x .. "," .. entry.e.position.y] = entry.e end
surface.find_entities_filtered = function(filter)
  if filter.position then
    local e = by_position[filter.position.x .. "," .. filter.position.y]
    return e and { e } or {}
  end
  local area, found = filter.area, {}
  for _, e in ipairs(droppers) do
    if e.position.x >= area[1][1] and e.position.x <= area[2][1] and e.position.y >= area[1][2] and e.position.y <= area[2][2] then
      found[#found + 1] = e
    end
  end
  return found
end
local read = inspect.inspect({ targets = { line[6].e.position, line[3].e.position }, trace = "up" })
local first, second = read.entities[1], read.entities[2]
check(first.lane_mix == "mixed" and first.lanes.left.coal == 1 and first.trace and first.trace.belts == 7
  and second.trace and second.trace.belts == 3,
  "inspect traces every belt it reads")
check(read.evidence_class == "fresh_exact_local_and_charted_remote"
  and read.scope == "within_30_tiles_or_own_force_charted_at_source_tick",
  "a traced read says it reached charted own belts")
local plain = inspect.inspect({ targets = { line[6].e.position } })
check(plain.entities[1].trace == nil and plain.evidence_class == "fresh_local_exact", "no trace unless asked")
local bad = pcall(inspect.inspect, { targets = { line[6].e.position }, trace = "sideways" })
check(not bad, "trace takes only up or down")
local saved = belt_trace.MAX_BELTS
belt_trace.MAX_BELTS = 4
local shared = inspect.inspect({ targets = { line[6].e.position, line[3].e.position }, trace = "up" })
check(shared.entities[1].trace.belts == 4 and shared.entities[1].trace.truncated
  and shared.entities[2].trace.belts == 0 and shared.entities[2].trace.truncated,
  "one call's traces share the belt cap")
belt_trace.MAX_BELTS = saved

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
