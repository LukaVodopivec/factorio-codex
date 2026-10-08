-- pickup_items on a transport belt: the body stands beside the lane carrying
-- the item and, while the belt's centre is within item_pickup_distance, the
-- action moves the requested item from the tile's transport lines into the
-- inventory by an exact, conserved transfer (remove N from the line, insert
-- exactly N), only when the inventory can hold the whole outstanding count. Native picking_state stays off: it would take every item kind in
-- reach. The fixture plays the game: were picking_state ever on, one item of
-- any kind per tick would leave every lane within reach.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.game = { tick = 1 }
_G.defines = { direction = { north = 0, east = 4, south = 8, west = 12 } }

local contents, capacity, insert_shortfall = {}, 100, 0
local function carried()
  local total = 0
  for _, count in pairs(contents) do total = total + count end
  return total
end
local inventory = {
  get_item_count = function(name) return contents[name] or 0 end,
  can_insert = function(stack) return carried() + stack.count <= capacity end,
  get_insertable_count = function() return math.max(0, capacity - carried()) end,
  insert = function(stack)
    local count = math.max(0, math.min(stack.count, math.max(0, capacity - carried())) - insert_shortfall)
    contents[stack.name] = (contents[stack.name] or 0) + count
    return count
  end,
}

-- A belt holds a count per item per lane; lane 1 is left of its direction.
-- removed counts what the action took off transport lines and line_writes
-- what it put back; any other line write is an error.
local line_writes, removed = 0, {}
local function belt(x, y, direction, left, right)
  local lanes = { left or {}, right or {} }
  local entity = { valid = true, type = "transport-belt", name = "transport-belt",
    position = { x = x, y = y }, direction = direction, lanes = lanes }
  entity.get_transport_line = function(index)
    return {
      get_item_count = function(name) return lanes[index][name] or 0 end,
      remove_item = function(stack)
        local count = math.min(stack.count, lanes[index][stack.name] or 0)
        lanes[index][stack.name] = (lanes[index][stack.name] or 0) - count
        removed[stack.name] = (removed[stack.name] or 0) + count
        return count
      end,
      insert_at = function() line_writes = line_writes + 1; error("the action must never insert belt items") end,
      insert_at_back = function(stack)
        line_writes = line_writes + 1
        lanes[index][stack.name] = (lanes[index][stack.name] or 0) + stack.count
        return true
      end,
      clear = function() line_writes = line_writes + 1; error("the action must never clear a belt") end,
    }
  end
  return entity
end
local function on_belt(entity, name)
  return (entity.lanes[1][name] or 0) + (entity.lanes[2][name] or 0)
end
local LANE_SIDE = { [0] = { -1, 0 }, [4] = { 0, -1 }, [8] = { 1, 0 }, [12] = { 0, 1 } }
local function lane_position(entity, index)
  local side = LANE_SIDE[entity.direction]
  local sign = index == 1 and 0.25 or -0.25
  return { x = entity.position.x + side[1] * sign, y = entity.position.y + side[2] * sign }
end

local belts, ground, belt_queries = {}, {}, 0
local surface = {
  find_entities_filtered = function(filter)
    if filter.type == "item-entity" then
      local found = {}
      for _, entity in ipairs(ground) do
        local dx, dy = entity.position.x - filter.position.x, entity.position.y - filter.position.y
        if dx * dx + dy * dy <= filter.radius * filter.radius then found[#found + 1] = entity end
      end
      return found
    end
    local wanted = {}
    for _, kind in ipairs(type(filter.type) == "table" and filter.type or { filter.type }) do wanted[kind] = true end
    if wanted["transport-belt"] then
      belt_queries = belt_queries + 1
      check(type(filter.type) == "string" and filter.radius == nil, "the belt lookup takes only a transport belt at the exact position")
    end
    local found = {}
    for _, entity in ipairs(belts) do
      if wanted[entity.type] and math.abs(entity.position.x - filter.position.x) <= 0.5 and math.abs(entity.position.y - filter.position.y) <= 0.5 then
        found[#found + 1] = entity
      end
    end
    return found
  end,
}
local body = {
  valid = true, position = { x = 0, y = 0 }, surface = surface,
  item_pickup_distance = 1, picking_state = false, walking_state = {}, selected = nil,
  get_main_inventory = function() return inventory end,
  update_selected_entity = function() end,
  insert = function() error("the action inserts only through the main inventory") end,
}
surface.spill_item_stack = function() error("nothing may be spilled when the inventory was asked first") end
-- The game's native picking is indiscriminate: one item of any kind per tick
-- from every lane within reach, whenever picking_state is on.
local function step_world()
  game.tick = game.tick + 1
  if not body.picking_state then return end
  for _, entity in ipairs(belts) do
    for index = 1, 2 do
      local point = lane_position(entity, index)
      local dx, dy = point.x - body.position.x, point.y - body.position.y
      if dx * dx + dy * dy <= body.item_pickup_distance * body.item_pickup_distance then
        for name, count in pairs(entity.lanes[index] or {}) do
          if count > 0 and inventory.can_insert({ name = name, count = 1 }) then
            entity.lanes[index][name], contents[name] = count - 1, (contents[name] or 0) + 1
            break
          end
        end
      end
    end
  end
end

package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
-- The approach is the shared walker; here it reports and, once allowed,
-- stands the body on the far edge of the requested reach, beside the lane.
local approach_result, approach_target, approach_reach, approaches
package.loaded["scripts.actions.approach"] = {
  ensure = function(_, c, target, reach)
    approach_target, approach_reach, approaches = target, reach, approaches + 1
    if type(approach_result) == "function" then
      local answer = approach_result(target)
      if answer ~= "ok" then return answer end
    end
    if approach_result == "ok" or type(approach_result) == "function" then
      local away = target.x < 5.5 and -1 or target.x > 5.5 and 1 or 0
      c.position = { x = target.x + away * reach, y = target.y + (away == 0 and (target.y < 0.5 and -reach or reach) or 0) }
      return "ok"
    end
    return approach_result
  end,
}
local pickup = require("scripts.actions.pickup")

local function reset(entity)
  contents, capacity, belts, ground, belt_queries, line_writes, removed = {}, 100, { entity }, {}, 0, 0, {}
  insert_shortfall = 0
  body.position, body.picking_state = { x = 0, y = 0 }, false
  approach_result, approach_target, approach_reach, approaches = nil, nil, nil, 0
end
local function run(task, limit)
  for _ = 1, limit do
    local result = pickup.tick(task)
    if result then return result end
    step_world()
  end
end

-- A north-running belt with five plates on its left (west) lane.
local north = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 5 })
reset(north)
local task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 3 }
pickup.start(task)
check(task._belt == north and belt_queries == 1, "with no ground stack at the position the target resolves to the belt under it")
check(pickup.tick(task) == nil and body.picking_state == false and approach_target.x == 5.25 and approach_target.y == 0.5
  and approach_reach == 0.75,
  "the body first approaches the lane carrying the item, inside item_pickup_distance of it")
for _ = 1, 20 do step_world(); pickup.tick(task) end
check(body.picking_state == false and on_belt(north, "iron-plate") == 5 and carried() == 0,
  "nothing is picked and picking_state stays off while the body is out of reach")
approach_result = "ok"
local result = run(task, 50)
check(result and result.status == "done" and contents["iron-plate"] == 3 and on_belt(north, "iron-plate") == 2,
  "the transfer takes exactly the requested count and leaves the rest on the belt")
check(on_belt(north, "iron-plate") + contents["iron-plate"] == 5 and removed["iron-plate"] == 3 and line_writes == 0,
  "items are conserved: the inventory gain equals the transport line's loss, and nothing else is written to a line")
check(body.picking_state == false and result.outcome.source == "belt" and result.outcome.picked_up == 3
  and result.outcome.removed_from_belt == 3
  and result.outcome.requested == 3 and result.outcome.belt.position.x == 5.5
  and result.detail:match("picked up 3 iron%-plate from the transport%-belt"),
  "the result reports the count the belt gave up and native picking_state was never left on")

-- A body already within pickup distance of the belt centre, as when it stands
-- on a belt in a dense area with no free tile, takes the items at once even
-- though no approach could settle.
north = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 5 })
reset(north)
body.position = { x = 5.5, y = 1.2 }
task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 3 }
pickup.start(task)
approach_result = { status = "failed", detail = "couldn't get in range: BODY_ON_CONVEYOR" }
result = run(task, 5)
check(result and result.status == "done" and contents["iron-plate"] == 3 and on_belt(north, "iron-plate") == 2 and approaches == 0,
  "a belt already in reach is picked from without needing a place to stand")

-- Reach refusal: an approach that cannot get in range fails without picking.
north = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 5 })
reset(north)
task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 3 }
pickup.start(task)
approach_result = { status = "failed", detail = "couldn't get in range: PATH_NOT_FOUND" }
result = run(task, 5)
check(result and result.status == "failed" and result.detail:match("picked up 0") and result.detail:match("PATH_NOT_FOUND")
  and body.picking_state == false and on_belt(north, "iron-plate") == 5 and carried() == 0,
  "a belt the body cannot reach is refused with nothing picked up")

-- The lane decides the side: right lane of a north belt is east of centre,
-- left lane of an east belt is north of centre.
local right = belt(5.5, 0.5, defines.direction.north, {}, { coal = 4 })
reset(right)
task = { target = { x = 5.5, y = 0.5 }, item = "coal", count = 4 }
pickup.start(task)
pickup.tick(task)
check(approach_target.x == 5.75 and approach_target.y == 0.5, "an item on the right lane is approached from the right side")
approach_result = "ok"
result = run(task, 50)
check(result.status == "done" and contents.coal == 4 and on_belt(right, "coal") == 0, "the right lane is picked from its own side")
local east = belt(5.5, 0.5, defines.direction.east, { coal = 2 })
reset(east)
task = { target = { x = 5.5, y = 0.5 }, item = "coal", count = 2 }
pickup.start(task)
pickup.tick(task)
check(approach_target.x == 5.5 and approach_target.y == 0.25, "the left lane of an east-running belt lies north of its centre")

-- Fewer items than requested: the honest gain is reported, never invented.
local sparse = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 1, coal = 0 })
reset(sparse)
approach_result = "ok"
task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 3 }
pickup.start(task)
result = run(task, 400)
check(result and result.status == "failed" and result.detail:match("requested 3 iron%-plate, picked up 1")
  and contents["iron-plate"] == 1 and on_belt(sparse, "iron-plate") == 0 and body.picking_state == false,
  "a belt that runs dry stops the pickup with the actual count picked up")

-- A belt tile that never carries the item: no approach, no picking.
local other = belt(5.5, 0.5, defines.direction.north, { coal = 9 })
reset(other)
approach_result = "ok"
task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 1 }
pickup.start(task)
result = run(task, 400)
check(result and result.status == "failed" and result.detail:match("carried none") and approaches == 0
  and on_belt(other, "coal") == 9 and carried() == 0,
  "a belt tile carrying none of the item fails without walking or picking anything else")

-- A full inventory refuses before any approach.
north = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 5 })
reset(north)
capacity = 0
task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 1 }
pickup.start(task)
result = pickup.tick(task)
check(result and result.status == "failed" and result.detail:match("inventory") and approaches == 0 and body.picking_state == false,
  "a full inventory refuses the belt pickup before walking")

-- A human hold mid-pickup: the body approaches again and only the pickup's
-- own transfers count. The player's gains of the same item during the hold are not
-- belt pickups, and the remaining requested items are still taken.
north = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 6 })
reset(north)
approach_result = "ok"
task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 4 }
pickup.start(task)
north.lanes[1]["iron-plate"] = 2
pickup.tick(task); step_world()
check(contents["iron-plate"] == 2 and task._picking_started and task._picked == 2, "fixture: two plates picked before the hold")
north.lanes[1]["iron-plate"] = 4
body.position, body.picking_state = { x = 0, y = 0 }, false
contents["iron-plate"] = contents["iron-plate"] + 50
pickup.resume(task)
check(task._picked == 2 and task._picking_started == false, "a gain during the hold is not credited to the belt pickup")
local before = approaches
result = run(task, 50)
check(result and result.status == "done" and approaches > before and result.outcome.picked_up == 4
  and contents["iron-plate"] == 54 and on_belt(north, "iron-plate") == 2 and removed["iron-plate"] == 4,
  "after a hold the pickup approaches again and takes the rest of the requested count from the belt")

-- Hand-crafting that finishes the same item while picking is not a belt pickup.
local gears = belt(5.5, 0.5, defines.direction.north, { ["iron-gear-wheel"] = 2 })
reset(gears)
approach_result = "ok"
task = { target = { x = 5.5, y = 0.5 }, item = "iron-gear-wheel", count = 10 }
pickup.start(task)
for _ = 1, 400 do
  result = pickup.tick(task)
  if result then break end
  step_world()
  if game.tick % 3 == 0 then contents["iron-gear-wheel"] = (contents["iron-gear-wheel"] or 0) + 1 end
end
check(result and result.status == "failed" and result.detail:match("requested 10 iron%-gear%-wheel, picked up 2")
  and result.outcome.picked_up == 2 and removed["iron-gear-wheel"] == 2 and on_belt(gears, "iron-gear-wheel") == 0,
  "gears finished by the hand-craft queue are never reported as picked up from the belt")

-- Only the requested item leaves the belts: another kind on the same lane, on
-- the other lane and on a neighbouring belt in reach stays where it is.
local mixed = belt(5.5, 0.5, defines.direction.north, { coal = 5, ["iron-ore"] = 3 }, { ["copper-ore"] = 4 })
local neighbour = belt(4.5, 0.5, defines.direction.north, {}, { ["iron-ore"] = 6, coal = 2 })
reset(mixed)
belts = { mixed, neighbour }
approach_result = "ok"
task = { target = { x = 5.5, y = 0.5 }, item = "coal", count = 5 }
pickup.start(task)
result = run(task, 50)
check(result and result.status == "done" and contents.coal == 5 and carried() == 5 and removed.coal == 5,
  "a mixed belt gives up exactly the requested item and count")
check(on_belt(mixed, "iron-ore") == 3 and on_belt(mixed, "copper-ore") == 4 and on_belt(neighbour, "iron-ore") == 6
  and on_belt(neighbour, "coal") == 2 and body.picking_state == false,
  "no other item kind, other lane or neighbouring belt in reach loses anything")

-- Acting needs reach, measured to the belt's centre before anything is
-- removed: within pickup distance of the lane point alone is not reach.
north = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 1 })
reset(north)
approach_result = "ok"
task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 3 }
pickup.start(task)
pickup.tick(task)
check(task._picked == 1 and body.position.x == 4.5, "fixture: one plate taken exactly one tile from the belt centre")
north.lanes[1]["iron-plate"] = 2
body.position, approach_result = { x = 4.4, y = 0.5 }, nil
before = approaches
pickup.tick(task); pickup.tick(task)
check(task._picked == 1 and on_belt(north, "iron-plate") == 2 and removed["iron-plate"] == 1 and approaches > before,
  "a body within pickup distance of the lane but not of the belt centre takes nothing and approaches again")
body.position = { x = 0, y = 0 }
pickup.tick(task)
check(task._picked == 1 and on_belt(north, "iron-plate") == 2, "a body far out of pickup distance takes nothing")
-- In reach of the centre, the far lane is in reach too.
local far_lane = belt(5.5, 0.5, defines.direction.north, { coal = 1 }, { coal = 1 })
reset(far_lane)
approach_result = "ok"
task = { target = { x = 5.5, y = 0.5 }, item = "coal", count = 2 }
pickup.start(task)
result = run(task, 5)
check(result and result.status == "done" and contents.coal == 2 and on_belt(far_lane, "coal") == 0 and removed.coal == 2,
  "within pickup distance of the belt centre both lanes of the tile give up the item")

-- The inventory must hold the whole requested count before anything leaves
-- the belt: no partial transfer, no spill.
north = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 5 })
reset(north)
capacity, approach_result = 2, "ok"
task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 4 }
pickup.start(task)
result = run(task, 10)
check(result and result.status == "failed" and result.detail:match("picked up 0 %- Codex inventory cannot hold the 4 iron%-plate")
  and carried() == 0 and on_belt(north, "iron-plate") == 5 and removed["iron-plate"] == nil and approaches == 0
  and result.outcome == nil,
  "an inventory that cannot hold the full requested count refuses before walking, with nothing taken")
-- Room lost mid-pickup stops it before the next removal, keeping what was moved.
north = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 2 })
reset(north)
approach_result = "ok"
task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 4 }
pickup.start(task)
pickup.tick(task)
north.lanes[1]["iron-plate"], capacity = 3, 3
result = run(task, 5)
check(result and result.status == "failed" and result.detail:match("picked up 2 %- Codex inventory can no longer hold the 2 iron%-plate")
  and contents["iron-plate"] == 2 and on_belt(north, "iron-plate") == 3 and removed["iron-plate"] == 2
  and result.outcome.picked_up == 2 and result.outcome.removed_from_belt == 2,
  "an inventory that lost its room stops the pickup before removing anything more")
-- Conservation even if the inventory takes fewer than it accepted: the
-- remainder goes back onto the line, nothing is spilled, lost or created.
north = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 5 })
reset(north)
approach_result, insert_shortfall = "ok", 1
task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 3 }
pickup.start(task)
result = run(task, 10)
check(result and result.status == "failed" and result.detail:match("picked up 2") and result.detail:match("1 went back onto the belt and 0 could not")
  and contents["iron-plate"] == 2 and on_belt(north, "iron-plate") == 3 and line_writes == 1
  and result.outcome.picked_up == 2 and result.outcome.removed_from_belt == 2,
  "an insert that returns fewer than removed puts the remainder back on the line: belt plus inventory is unchanged")
local source = io.open(here .. "/../../mod/agentic-companion/scripts/actions/pickup.lua"):read("a")
check(not source:find("spill_item_stack", 1, true), "the pickup action never calls spill_item_stack")

-- A blocked stand tile on the chosen lane's side: the other lane is tried
-- when it carries the item, and the refusal names the sides otherwise.
local both = belt(5.5, 0.5, defines.direction.north, { coal = 3 }, { coal = 3 })
reset(both)
local function left_side_blocked(target)
  if target.x < 5.5 then return { status = "failed", detail = "couldn't get in range: BODY_ON_CONVEYOR" } end
  return "ok"
end
approach_result = left_side_blocked
task = { target = { x = 5.5, y = 0.5 }, item = "coal", count = 3 }
pickup.start(task)
result = run(task, 50)
check(result and result.status == "done" and result.outcome.picked_up == 3 and both.lanes[1].coal == 3 and both.lanes[2].coal == 0
  and result.detail:match("right lane %(east side%)"),
  "a blocked left side falls back to the right lane, which also carries the item")
local one_lane = belt(5.5, 0.5, defines.direction.north, { coal = 3 })
reset(one_lane)
approach_result = left_side_blocked
task = { target = { x = 5.5, y = 0.5 }, item = "coal", count = 3 }
pickup.start(task)
result = run(task, 50)
check(result and result.status == "failed" and result.detail:match("left lane %(west side%)")
  and result.detail:match("BODY_ON_CONVEYOR") and result.detail:match("right lane %(east side%) carries no coal")
  and on_belt(one_lane, "coal") == 3,
  "a blocked stand tile is refused naming the blocked side and the empty other lane")
both = belt(5.5, 0.5, defines.direction.north, { coal = 3 }, { coal = 3 })
reset(both)
approach_result = function() return { status = "failed", detail = "couldn't get in range: BODY_ON_CONVEYOR" } end
task = { target = { x = 5.5, y = 0.5 }, item = "coal", count = 3 }
pickup.start(task)
result = run(task, 50)
check(result and result.status == "failed" and result.detail:match("left lane %(west side%)")
  and result.detail:match("right lane %(east side%)") and approaches == 2 and on_belt(both, "coal") == 6,
  "with both sides blocked each lane is tried once and both are named")

-- An underground belt, splitter or loader is refused by name, not as a vanished ground stack.
local splitter = { valid = true, type = "splitter", name = "fast-splitter", position = { x = 5.5, y = 0.5 } }
reset(splitter)
local splitter_ok, splitter_error = pcall(pickup.start, { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 1 })
check(not splitter_ok and tostring(splitter_error):match("only from a plain transport%-belt")
  and tostring(splitter_error):match("fast%-splitter") and not tostring(splitter_error):match("gone or changed"),
  "a splitter target is refused naming the unsupported belt type")

-- Ground stacks keep their exact contract and never fall through to a belt.
north = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 5 })
reset(north)
ground = { { valid = true, type = "item-entity", name = "item-on-ground", position = { x = 5.5, y = 0.5 },
  stack = { valid_for_read = true, name = "iron-plate", count = 2 } } }
local stale_ok, stale_error = pcall(pickup.start, { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 3 })
check(not stale_ok and tostring(stale_error):match("gone or changed") and belt_queries == 0,
  "a changed ground stack at the position is still refused, not replaced by the belt under it")
local exact = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 2 }
pickup.start(exact)
check(exact._entity == ground[1] and exact._belt == nil and belt_queries == 0,
  "an exact ground stack is still picked up as a ground stack")
reset(north)
belts = {}
local none_ok, none_error = pcall(pickup.start, { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 1 })
check(not none_ok and tostring(none_error):match("gone or changed"), "no ground stack and no belt at the position is refused")

-- A belt that keeps carrying the body out of reach: re-approaching is no
-- progress, so with nothing more coming along the pickup stops.
local drifting = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 1 })
reset(drifting)
approach_result = "ok"
local drift_task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 3 }
pickup.start(drift_task)
local drift_result, drift_ticks = nil, 0
for _ = 1, 3000 do
  drift_result = pickup.tick(drift_task)
  if drift_result then break end
  step_world()
  drift_ticks = drift_ticks + 1
  body.position = { x = 20, y = 0.5 }
end
check(drift_result and drift_result.status == "failed" and drift_task._picked == 1 and drift_ticks < 600,
  "a body the belt keeps carrying away stops once nothing more comes along (" .. drift_ticks .. " ticks)")
-- A body standing on the belt it picks from steps off beside the lane while
-- it takes what is in reach; where no step-off can settle (a dense area) it
-- tries once and keeps picking where it stands.
local geometry = require("scripts.placement_geometry")
local conveyor_under = geometry.conveyor_under
geometry.conveyor_under = function(c) return c.position.x == 5.5 and {} or nil end
local onbelt = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 5 })
reset(onbelt)
body.position = { x = 5.5, y = 0.6 }
approach_result = "ok"
local step_task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 3 }
pickup.start(step_task)
local stepped = run(step_task, 20)
check(stepped and stepped.status == "done" and approaches >= 1 and body.position.x ~= 5.5,
  "a body standing on the belt it picks from steps off beside the lane")
local dense_belt = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 5 })
reset(dense_belt)
body.position = { x = 5.5, y = 0.6 }
approach_result = { status = "failed", detail = "couldn't get in range: BODY_ON_CONVEYOR" }
local dense_task = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 3 }
pickup.start(dense_task)
local dense = run(dense_task, 20)
check(dense and dense.status == "done" and approaches == 1,
  "where no step-off settles, the body tries once and picks where it stands")
-- In a dense area where the step-off failed, a belt that keeps carrying the
-- body away while items keep arriving stops after a few drifts out of reach.
local drift_belt = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 1 })
reset(drift_belt)
capacity, body.position = 1000, { x = 5.5, y = 0.6 }
approach_result = function()
  if body.position.x == 5.5 and math.abs(body.position.y - 0.5) < 1 then
    return { status = "failed", detail = "couldn't get in range: BODY_ON_CONVEYOR" }
  end
  return "ok"
end
local dense_drift = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 400 }
pickup.start(dense_drift)
local drift_stop, drift_steps = nil, 0
for _ = 1, 600 do
  drift_stop = pickup.tick(dense_drift)
  if drift_stop then break end
  step_world()
  drift_steps = drift_steps + 1
  if game.tick % 10 == 0 then drift_belt.lanes[1]["iron-plate"] = drift_belt.lanes[1]["iron-plate"] + 1 end
  if dense_drift._picking_started and game.tick % 50 == 0 then body.position = { x = 5.5, y = 5 } end
end
check(dense_drift._settle_failed and drift_stop and drift_stop.status == "failed" and dense_drift._drifts == 3
  and drift_stop.detail:match("out of reach 3 times") and drift_stop.outcome.picked_up == dense_drift._picked
  and dense_drift._picked > 0,
  "with no step-off possible, the third drift out of reach stops the pickup with what it picked (" .. drift_steps .. " ticks)")
geometry.conveyor_under = conveyor_under

-- A belt that delivers one item now and then, each within the no-progress
-- limit, still ends the pickup after the total in-reach bound, with the
-- count it picked; time out of reach does not count toward it.
local trickle = belt(5.5, 0.5, defines.direction.north, { ["iron-plate"] = 1 })
reset(trickle)
capacity, approach_result = 1000, "ok"
local slow = { target = { x = 5.5, y = 0.5 }, item = "iron-plate", count = 400 }
pickup.start(slow)
local slow_result, slow_ticks = nil, 0
for _ = 1, 2400 do
  slow_result = pickup.tick(slow)
  if slow_result then break end
  step_world()
  slow_ticks = slow_ticks + 1
  if game.tick % 100 == 0 then trickle.lanes[1]["iron-plate"] = trickle.lanes[1]["iron-plate"] + 1 end
  if slow_ticks == 500 then body.position, approach_result = { x = 20, y = 0.5 }, nil end
  if slow_ticks == 700 then approach_result = "ok" end
end
check(slow_result and slow_result.status == "failed" and slow_result.detail:match("delivered too slowly")
  and slow._picked >= 18 and slow._picked <= 24 and slow_result.outcome.picked_up == slow._picked
  and contents["iron-plate"] == slow._picked and slow_ticks >= 1990 and slow_ticks < 2100,
  "a trickling belt ends the pickup after the total in-reach bound with the count picked ("
  .. slow._picked .. " in " .. slow_ticks .. " ticks)")
os.exit(failures == 0 and 0 or 1)
