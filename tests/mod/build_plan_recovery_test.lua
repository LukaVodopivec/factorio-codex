-- Offline tests for build_plan's bounded in-action recoveries: walking out of
-- a footprint the body stands in, and the outcome code that keeps the
-- dispatcher from rerunning a whole build.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.storage = {}
_G.game = { tick = 100 }
_G.defines = { build_check_type = { manual = 1, ghost_revive = 5 } }
_G.prototypes = { item = {
  ["stone-furnace"] = { stack_size = 50, place_result = { name = "stone-furnace", type = "furnace",
    collision_box = { left_top = { x = -0.9, y = -0.9 }, right_bottom = { x = 0.9, y = 0.9 } } } },
} }

local inventory = { ["stone-furnace"] = 2 }
local created = 0
local character = {
  valid = true, name = "character", position = { x = 10, y = 10 }, build_distance = 10,
  force = { recipes = {} }, crafting_queue_size = 0,
  get_item_count = function(name) return inventory[name] or 0 end,
  remove_item = function(args) inventory[args.name] = inventory[args.name] - args.count end,
}
character.surface = {
  find_non_colliding_position = function(_, position) return { x = position.x, y = position.y } end,
  create_entity = function(args) created = created + 1; return { valid = true, name = args.name, type = "furnace", position = args.position } end,
}
package.loaded["scripts.companion"] = { get = function() return character end, require_companion = function() return character end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end, ensure_entity = function() return "ok" end }
local walks = {}
package.loaded["scripts.actions.walk"] = {
  start = function(task) walks[#walks + 1] = task end,
  tick = function(task)
    if task.target.x == -99 then return { status = "failed", detail = "BODY_ENCLOSED: boxed in" } end
    character.position = { x = task.target.x, y = task.target.y }
    return { status = "done", detail = "arrived" }
  end,
}

local geometry = require("scripts.placement_geometry")
local overlap_until_moved = function(c, proto, position)
  if math.abs(c.position.x - position.x) < 2 and math.abs(c.position.y - position.y) < 2 then
    return false, "CODEX_BODY_OVERLAP"
  end
  return true, "placeable"
end
geometry.can_place = overlap_until_moved
local build_plan = require("scripts.actions.build_plan")

local plan = { id = 41, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(plan)
check(build_plan.tick(plan) == nil and walks[1] and walks[1].id == 41 and walks[1].arrival_mode == "exact" and created == 0,
  "a body standing in the footprint walks clear under the plan's id instead of failing")
local exit = walks[1].target
check(math.abs(exit.x - 10) >= 2.15 or math.abs(exit.y - 10) >= 2.15, "the exit spot lies clear of the furnace footprint")
local placed = build_plan.tick(plan)
check(placed and placed.status == "done" and created == 1, "after walking clear the step places")

-- Bounded per step: a body that is still in the way after three different
-- spots beside the footprint fails with a code and says so.
character.position = { x = 10, y = 10 }
geometry.can_place = function() return false, "CODEX_BODY_OVERLAP" end
local stuck = { id = 42, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(stuck)
local failed
for _ = 1, 10 do failed = build_plan.tick(stuck); if failed then break end end
check(failed and failed.status == "failed" and failed.detail:match("CODEX_BODY_OVERLAP")
  and failed.detail:match("still in it after walking to 3 spot%(s%) beside it")
  and failed.outcome.code == "BUILD_PLAN_STEP_FAILED" and failed.outcome.placed == 0 and #walks == 4,
  "an overlap that survives three exits fails with the build's own code, so the dispatcher does not rerun the build")
local spots = {}
for n = 2, 4 do
  for m = 2, n - 1 do
    if (walks[n].target.x - walks[m].target.x) ^ 2 + (walks[n].target.y - walks[m].target.y) ^ 2 < 1 then spots.repeated = true end
  end
end
check(not spots.repeated, "each retry walks to a different spot")

-- Footprint step-out: a dense layout fills the four spots two tiles beside the
-- footprint; a farther or corner spot still gets the body out.
geometry.can_place = overlap_until_moved
character.position = { x = 10, y = 10 }
inventory["stone-furnace"] = 5
character.surface.find_non_colliding_position = function(_, position)
  if (position.x - 10) ^ 2 + (position.y - 10) ^ 2 < 3.5 ^ 2 then return nil end
  return { x = position.x, y = position.y }
end
local dense = { id = 50, auto_supply = false, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(dense)
created = 0
local dense_result
for _ = 1, 10 do dense_result = build_plan.tick(dense); if dense_result then break end end
check(dense_result and dense_result.status == "done" and created == 1,
  "a body boxed in on its four near sides walks to a farther spot and places")

-- Footprint step-out: the first walk ends with the body still in the footprint; it
-- tries another spot instead of failing.
character.surface.find_non_colliding_position = function(_, position) return { x = position.x, y = position.y } end
character.position = { x = 10, y = 10 }
local walk_mock = package.loaded["scripts.actions.walk"]
local full_tick, short = walk_mock.tick, 1
walk_mock.tick = function(task)
  if short > 0 then
    short = short - 1
    character.position = { x = 10, y = 11 } -- stopped short, still overlapping
    return { status = "done", detail = "arrived" }
  end
  return full_tick(task)
end
local short_plan = { id = 51, auto_supply = false, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(short_plan)
created = 0
local before = #walks
local short_result
for _ = 1, 10 do short_result = build_plan.tick(short_plan); if short_result then break end end
check(short_result and short_result.status == "done" and created == 1 and #walks == before + 2,
  "a walk that leaves the body in the footprint is followed by a walk to another spot, then the step places")
walk_mock.tick = full_tick

geometry.can_place = overlap_until_moved
character.surface.find_non_colliding_position = function() return { x = -99, y = 10 } end
character.position = { x = 10, y = 10 }
local enclosed = { id = 43, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } } }
build_plan.start(enclosed)
build_plan.tick(enclosed)
local walk_failed = build_plan.tick(enclosed)
check(walk_failed and walk_failed.status == "failed" and walk_failed.detail:match("walking clear failed: BODY_ENCLOSED"),
  "a failed walk out of the footprint fails the step and names why")

-- A build that 0.20 started before an in-place upgrade (auto_craft,
-- _waiting_for_crafts; no auto_supply or _short) keeps running: a step whose
-- item the body lacks fails as that step, not with a Lua error.
geometry.can_place = function() return true, "placeable" end
character.surface.find_non_colliding_position = function(_, position) return { x = position.x, y = position.y } end
character.position = { x = 30, y = 30 }
inventory["stone-furnace"] = 0
local legacy = { id = 44, steps = { { item = "stone-furnace", position = { x = 10, y = 10 } } },
  auto_craft = false, _auto_crafted = {}, _waiting_for_crafts = true, stop_on_error = true,
  _index = 1, _placed = 0, _results = {}, _failures = {} }
local ok, legacy_result = pcall(build_plan.tick, legacy)
check(ok and legacy_result and legacy_result.status == "failed" and legacy_result.detail:match("don't have any stone%-furnace")
  and legacy._short ~= nil and legacy.auto_supply == false,
  "a build_plan started by 0.20 is upgraded in place and fails a missing item as a step, not a Lua error")

-- A step whose approach failed for where the body stood (BODY_ON_CONVEYOR,
-- START_COLLISION) is tried once more after the last step, if the body
-- stands elsewhere by then; other failures and stop_on_error plans are not
-- retried. A successful approach walks the body to the step.
local approach_mock = package.loaded["scripts.actions.approach"]
local attempts, refuse = {}, nil
approach_mock.ensure = function(_, _, position)
  local key = position.x .. ":" .. position.y
  attempts[key] = (attempts[key] or 0) + 1
  local answer = refuse(key, attempts[key])
  if answer == "ok" then character.position = { x = position.x, y = position.y } end
  return answer
end
local function three_step_plan(id, stop_on_error)
  attempts, created = {}, 0
  character.position = { x = -6, y = 0 }
  inventory["stone-furnace"] = 3
  local p = { id = id, auto_supply = false, stop_on_error = stop_on_error, steps = {
    { item = "stone-furnace", position = { x = 0, y = 0 } },
    { item = "stone-furnace", position = { x = 4, y = 0 } },
    { item = "stone-furnace", position = { x = 8, y = 0 } } } }
  build_plan.start(p)
  local result
  for _ = 1, 20 do
    result = build_plan.tick(p)
    if result then break end
  end
  return p, result
end
local on_belt = { status = "failed", detail = "couldn't get in range: BODY_ON_CONVEYOR: the body stands on transport-belt",
  outcome = { code = "BODY_ON_CONVEYOR" } }
refuse = function(key, n) if key == "0:0" and n == 1 then return on_belt end return "ok" end
local retried, retried_result = three_step_plan(45, false)
check(retried_result and retried_result.status == "done" and created == 3 and attempts["0:0"] == 2
  and retried._results[1].ok and #retried._failures == 0 and retried_result.detail:match("^placed 3/3"),
  "a BODY_ON_CONVEYOR step is retried once after the last step and placed")

refuse = function(key) if key == "4:0" then return on_belt end return "ok" end
local twice, twice_result = three_step_plan(46, false)
check(twice_result and twice_result.status == "done" and created == 2 and attempts["4:0"] == 2
  and #twice._failures == 1 and twice._failures[1].index == 2
  and twice._failures[1].why:match("BODY_ON_CONVEYOR.*retried once after the last step%)$"),
  "a step failing again on its retry is listed once, saying it was retried")

refuse = function(key) if key == "0:0" then return { status = "failed",
  detail = "couldn't get in range: PATH_NOT_FOUND", outcome = { code = "PATH_NOT_FOUND" } } end return "ok" end
local unreachable = three_step_plan(47, false)
check(attempts["0:0"] == 1 and #unreachable._failures == 1, "a failure unrelated to where the body stood is not retried")

refuse = function(key) if key == "8:0" then return on_belt end return "ok" end
local unmoved, unmoved_result = three_step_plan(49, false)
check(unmoved_result and attempts["8:0"] == 1 and #unmoved._failures == 1
  and not unmoved._failures[1].why:match("retried"),
  "a step that failed where the body still stands is not retried")

refuse = function(key) if key == "0:0" then return on_belt end return "ok" end
local _, stopped = three_step_plan(48, true)
check(stopped and stopped.status == "failed" and attempts["0:0"] == 1 and created == 0,
  "a stop_on_error plan stops at the failure instead of retrying it")
approach_mock.ensure = function() return "ok" end

-- Enclosure escape: enclosed by own entities at the first placement, the body steps
-- out once (move_entity's escape: take the named blocker up, walk out, put
-- it back), then places; the step's detail says what was moved and restored.
local supply = require("scripts.actions.supply")
local escapes, escape_result = {}, nil
supply.register_runner("move_entity", { start = function(task) escapes[#escapes + 1] = task end,
  tick = function() return escape_result end })
local enclosed_walk = { status = "failed",
  detail = "couldn't get in range: BODY_ENCLOSED: no path; enclosed by owned entities; owned blocker toward the goal: the fast-inserter at (187.5,-7.5)",
  outcome = { code = "BODY_ENCLOSED", diagnostics = { path = {
    suggested_recovery = { x = 187.5, y = -7.5, expected_name = "fast-inserter" } } } } }
local enclosed_calls = 0
local function enclosed_until(n)
  enclosed_calls = 0
  approach_mock.ensure = function()
    enclosed_calls = enclosed_calls + 1
    return enclosed_calls <= n and enclosed_walk or "ok"
  end
end
local function layout(id)
  created, character.position = 0, { x = 0, y = 0 }
  inventory["stone-furnace"] = 3
  local p = { id = id, auto_supply = false, steps = { { item = "stone-furnace", position = { x = 0, y = 0 } } } }
  build_plan.start(p)
  local result
  for _ = 1, 10 do result = build_plan.tick(p); if result then break end end
  return result
end
enclosed_until(1)
escape_result = { status = "done", detail = "stepped out through the fast-inserter at (187.5, -7.5): took it up and put it back",
  outcome = { code = "ESCAPED" } }
local escaped = layout(60)
local escape = escapes[1]
check(escape and escape.type == "move_entity" and escape.id == 60 and escape.from.x == 187.5 and escape.from.y == -7.5
  and escape.to.x == 187.5 and escape.through.x == 0 and escape.expected_name == "fast-inserter",
  "an enclosed approach starts one escape through the named own blocker toward the step")
check(escaped and escaped.status == "done" and created == 1
  and escaped.detail:match("step 1: stepped out through the fast%-inserter at %(187%.5, %-7%.5%): took it up and put it back"),
  "after stepping out the step places, and its detail names what was taken up and put back")

enclosed_until(1)
escape_result = { status = "failed", detail = "MOVE_PLACE_FAILED: the fast-inserter is in my inventory — something stands there" }
local unrestored = layout(61)
check(unrestored and unrestored.status == "failed" and created == 0
  and unrestored.detail:match("BODY_ENCLOSED and stepping out failed: MOVE_PLACE_FAILED: the fast%-inserter is in my inventory"),
  "an escape that cannot put the blocker back fails the step and says the entity is in the inventory")

enclosed_until(99)
escapes = {}
escape_result = { status = "done", detail = "stepped out through the fast-inserter at (187.5, -7.5): took it up and put it back" }
local still = layout(62)
check(still and still.status == "failed" and #escapes == 1 and still.detail:match("BODY_ENCLOSED: no path"),
  "an enclosure still there after one escape fails the step: one escape per step")
approach_mock.ensure = function() return "ok" end

-- Enclosure escape, end to end with move_entity's own escape: the body stands
-- in a room whose east wall (x 200-201) has one inserter as its only gap,
-- and the step lies 11 tiles east, just beyond the build distance. The
-- escape walks out through the gap with the step within build distance
-- after a tile; that is not stepping out. It puts the inserter back only
-- once the body stands a tile clear outside, so the step places instead of
-- the body being shut in again (a spot beside the gap inside the room).
supply.register_runner("move_entity", package.loaded["scripts.actions.move_entity"])
local mine_runner = { start = function() end, tick = function(sub)
  for _, e in ipairs(character.surface._world) do
    if e.valid and math.abs(e.position.x - sub.target.x) < 0.5 and math.abs(e.position.y - sub.target.y) < 0.5 then
      e.valid = false
      inventory[e.name] = (inventory[e.name] or 0) + 1
      return { status = "done", detail = "mined" }
    end
  end
  return { status = "failed", detail = "nothing there" }
end }
supply.register_runner("mine", mine_runner)
local function body_box(at) return { left_top = { x = at.x - 0.2, y = at.y - 0.2 }, right_bottom = { x = at.x + 0.2, y = at.y + 0.2 } } end
local function set_body(x, y)
  character.position = { x = x, y = y }
  character.bounding_box = body_box(character.position)
end
local inserter_proto = { name = "inserter", type = "inserter", tile_width = 1, tile_height = 1,
  collision_box = { left_top = { x = -0.35, y = -0.35 }, right_bottom = { x = 0.35, y = 0.35 } },
  items_to_place_this = { { name = "inserter", count = 1 } } }
prototypes.item.inserter = { stack_size = 50, place_result = inserter_proto }
local world = {}
local function spawn_gate()
  local e = { valid = true, name = "inserter", type = "inserter", position = { x = 200.5, y = 0.5 }, direction = 4,
    force = character.force, prototype = inserter_proto }
  e.bounding_box = geometry.footprint(inserter_proto, e.position, e.direction)
  world[#world + 1] = e
  return e
end
local function gate_standing()
  for _, e in ipairs(world) do if e.valid and e.name == "inserter" then return e end end
end
local surface = character.surface
surface._world = world
surface.find_entities_filtered = function(filter)
  local out = {}
  for _, e in ipairs(world) do
    local area = filter.area or { left_top = filter.position, right_bottom = filter.position }
    if e.valid and geometry.overlaps(area, e.bounding_box) and (not filter.force or filter.force == e.force) then out[#out + 1] = e end
  end
  return out
end
surface.find_entity = function(name, position)
  for _, e in ipairs(world) do
    if e.valid and e.name == name and math.abs(e.position.x - position.x) < 0.5 and math.abs(e.position.y - position.y) < 0.5 then return e end
  end
end
surface.count_tiles_filtered = function() return 0 end
-- The wall's other tiles take no body: a spot in them is never clear.
surface.find_non_colliding_position = function(_, position)
  if position.x > 199.6 and position.x < 201.4 and math.abs(position.y - 0.5) > 0.6 and math.abs(position.y - 0.5) < 6 then return nil end
  return { x = position.x, y = position.y }
end
local inside = function(at) return at.x < 201 and math.abs(at.y - 0.5) < 6 end
-- The escape's put-back, as the place runner does it: never onto the body.
local put_back_at
supply.register_runner("place", { start = function() end, tick = function(sub)
  local area = geometry.footprint(prototypes.item[sub.item].place_result, sub.position, sub.direction)
  if geometry.overlaps(area, character.bounding_box) then
    return { status = "failed", detail = string.format("can't place %s at (%.1f, %.1f) — CODEX_BODY_OVERLAP — walk clear",
      sub.item, sub.position.x, sub.position.y) }
  end
  put_back_at = { x = character.position.x, y = character.position.y }
  inventory[sub.item] = inventory[sub.item] - 1
  spawn_gate().direction = sub.direction
  return { status = "done", detail = "placed" }
end })
-- Walks: straight, half a tile a tick, "ok" within the asked reach; from
-- inside the room to outside only while the gap is open.
local enclosed_room = { status = "failed", detail = "couldn't get in range: BODY_ENCLOSED: no path; enclosed by owned entities",
  outcome = { code = "BODY_ENCLOSED", diagnostics = { path = {
    suggested_recovery = { x = 200.5, y = 0.5, expected_name = "inserter" } } } } }
approach_mock.ensure = function(_, c, target, reach)
  local dx, dy = target.x - c.position.x, target.y - c.position.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d <= reach then return "ok" end
  if inside(c.position) and not inside(target) and gate_standing() then return enclosed_room end
  local step = math.min(0.5, d)
  set_body(c.position.x + dx / d * step, c.position.y + dy / d * step)
  return nil
end
walk_mock.tick = function(task)
  set_body(task.target.x, task.target.y)
  return { status = "done", detail = "arrived" }
end
geometry.can_place = function(c, proto, position, direction)
  if geometry.overlaps(geometry.footprint(proto, position, direction), c.bounding_box) then return false, "CODEX_BODY_OVERLAP" end
  return true, "placeable"
end
spawn_gate()
set_body(199.5, 0.5)
created, inventory["stone-furnace"], inventory.inserter = 0, 1, 0
local room = { id = 63, auto_supply = false, steps = { { item = "stone-furnace", position = { x = 210.5, y = 0.5 } } } }
build_plan.start(room)
local room_result
for _ = 1, 200 do room_result = build_plan.tick(room); if room_result then break end end
local gate_back = gate_standing()
check(room_result and room_result.status == "done" and created == 1 and gate_back and gate_back.direction == 4
  and inventory.inserter == 0 and put_back_at and not inside(put_back_at)
  and not geometry.overlaps({ left_top = { x = 199.15, y = -0.85 }, right_bottom = { x = 201.85, y = 1.85 } }, body_box(put_back_at))
  and room_result.detail:match("stepped out through the inserter at %(200%.5, 0%.5%): took it up and put it back"),
  "a layout step beyond an enclosure's gap steps out, puts the gate back with the body a tile clear outside, and places")

-- The build ends mid step-out (a cancel, a stop, its plan's budget): its
-- cancelled hook hands over to the escape's, which puts the gate back.
set_body(199.5, 0.5)
inventory["stone-furnace"], inventory.inserter = 1, 0
local cut = { id = 64, auto_supply = false, steps = { { item = "stone-furnace", position = { x = 214.5, y = 0.5 } } } }
build_plan.start(cut)
for _ = 1, 200 do
  if build_plan.tick(cut) then break end
  if cut._escape and cut._escape._phase == "through" and character.position.x >= 201.5 then break end
end
local mid_escape = cut._escape ~= nil and gate_standing() == nil and inventory.inserter == 1
-- The hook places as the game does, onto this world.
local plain_create = surface.create_entity
surface.create_entity = function(args)
  if args.name ~= "inserter" then return plain_create(args) end
  local e = spawn_gate()
  e.direction = args.direction
  return e
end
character.can_reach_entity = function() return true end
local note = build_plan.cancelled and build_plan.cancelled(cut)
check(mid_escape and note and note.code == "ESCAPE_CANCELLED" and note.put_back and gate_standing() ~= nil
  and inventory.inserter == 0 and note.detail:match("put the inserter back at %(200%.5, 0%.5%)"),
  "a build ended mid step-out puts the taken-up gate back through its escape's cancelled hook")
surface.create_entity, character.can_reach_entity = plain_create, nil
walk_mock.tick = full_tick

-- Auto-supply enclosed: the fetch from an own chest ends BODY_ENCLOSED, the
-- supply's step-out fails, and the step names BODY_ENCLOSED and the failed
-- step-out, not a SUPPLY_SHORTFALL. A build ended mid supply step-out lets
-- go of the taken-up entity through the supply's escape.
do
  local registry = require("scripts.registry")
  local saved = { stock_totals = registry.stock_totals, holders_with = registry.holders_with,
    holder_inventory = registry.holder_inventory, holder_kind = registry.holder_kind }
  local store = { valid = true, name = "wooden-chest", type = "container", position = { x = 5.5, y = 0.5 } }
  registry.stock_totals = function(names) local out = {}; for _, n in ipairs(names) do out[n] = 4 end; return out end
  registry.holders_with = function() return { { entity = store, position = store.position } } end
  registry.holder_inventory = function() return { get_item_count = function() return 4 end } end
  registry.holder_kind = function() return "chest" end
  character.force.is_chunk_charted = function() return true end
  character.get_main_inventory = function() return nil end
  local extracts, escapes2, released, escape_answer = 0, {}, {}, nil
  supply.register_runner("extract", { start = function() extracts = extracts + 1 end, tick = function()
    return { status = "failed", detail = "couldn't get in range: BODY_ENCLOSED: no path; enclosed by owned entities",
      outcome = { code = "BODY_ENCLOSED", diagnostics = { path = {
        suggested_recovery = { x = 1.5, y = 0.5, expected_name = "inserter" } } } } }
  end })
  supply.register_runner("move_entity", { start = function(task) escapes2[#escapes2 + 1] = task end,
    tick = function() return escape_answer end,
    cancelled = function(task) released[#released + 1] = task; return { code = "ESCAPE_CANCELLED", detail = "put it back" } end })
  escape_answer = { status = "failed", detail = "ESCAPE_FAILED: took up the inserter at (1.5, 0.5), the walk out failed" }
  set_body(0.5, 0.5)
  inventory["stone-furnace"], created = 0, 0
  local fed = { id = 65, steps = { { item = "stone-furnace", position = { x = 10.5, y = 0.5 } } } }
  build_plan.start(fed)
  local fed_result
  for _ = 1, 40 do fed_result = build_plan.tick(fed); if fed_result then break end end
  check(fed_result and fed_result.status == "failed" and created == 0 and extracts == 1 and #escapes2 == 1
    and escapes2[1].through.x == 5.5 and fed._supply_result and fed._supply_result.code == "BODY_ENCLOSED"
    and fed_result.detail:match("BODY_ENCLOSED: missing 1 stone%-furnace; stepping out failed: ESCAPE_FAILED")
    and not fed_result.detail:match("SUPPLY_SHORTFALL"),
    "an auto-supply enclosed at its fetch steps out once and the step names BODY_ENCLOSED, not a shortfall")

  escape_answer = nil
  local cut2 = { id = 66, steps = { { item = "stone-furnace", position = { x = 10.5, y = 0.5 } } } }
  build_plan.start(cut2)
  for _ = 1, 10 do if build_plan.tick(cut2) or cut2._supply and cut2._supply._escape then break end end
  local cut_note = cut2._supply and cut2._supply._escape and build_plan.cancelled(cut2)
  check(cut_note and cut_note.code == "ESCAPE_CANCELLED" and #released == 1 and released[1] == cut2._supply._escape,
    "a build ended mid supply step-out reaches the supply's escape through its cancelled hook")
  for key, value in pairs(saved) do registry[key] = value end
  character.force.is_chunk_charted, character.get_main_inventory = nil, nil
  supply.register_runner("move_entity", package.loaded["scripts.actions.move_entity"])
end

-- Ground stacks clear_footprint took up are reported per step, never
-- overwritten by the next step's footprint.
do
  local build = require("scripts.actions.build")
  local real_clear = build.clear_footprint
  build.clear_footprint = function(t, _, _, position)
    t._picked_up = { x = position.x, y = position.y,
      rows = { { item = "iron-plate", count = position.x == 70 and 2 or 5, x = position.x + 0.25, y = position.y } } }
    return "ok"
  end
  geometry.can_place = function() return true, "placeable" end
  inventory["stone-furnace"] = 2
  set_body(60, 10)
  local two = { id = 67, auto_supply = false, steps = { { item = "stone-furnace", position = { x = 70, y = 10 } },
    { item = "stone-furnace", position = { x = 74, y = 10 } } } }
  build_plan.start(two)
  local two_result
  for _ = 1, 20 do two_result = build_plan.tick(two); if two_result then break end end
  build.clear_footprint = real_clear
  local rows = two_result and two_result.outcome and two_result.outcome.picked_up
  check(two_result and two_result.status == "done" and rows and #rows == 2 and rows[1].step == 1 and rows[1].count == 2
    and rows[1].x == 70.25 and rows[2].step == 2 and rows[2].count == 5 and rows[2].x == 74.25,
    "a build names the ground stacks each step's placement took up")
end

os.exit(failures == 0 and 0 or 1)
