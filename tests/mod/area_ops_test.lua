-- Offline tests for the blueprint and area plan actions (actions/area_ops.lua):
-- blueprint_place by hand through build_layout (turned, flipped, recipes and
-- settings applied) and as ghosts (build_blueprint; nothing free), its
-- check_only dry run; build_ghosts reviving ghosts with the body's own items;
-- deconstruct_area by hand (nearest first, stops on a full inventory), by
-- robot orders in bounded batches, and cancelled; upgrade_area by hand
-- fast-replace (same footprint only, recipe kept) and by robot orders;
-- copy_settings within reach.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local bp = dofile(here .. "/blueprint_mock.lua")
local mock = bp.mock

_G.storage = {}
_G.defines = { build_check_type = { manual = 1, ghost_revive = 2 }, inventory = { chest = 1, crafter_input = 2 },
  build_mode = { normal = 0, forced = 1, superforced = 2 }, direction = { north = 0, east = 4, south = 8, west = 12 } }
local codex_player = { valid = true, connected = true }
_G.game = { tick = 100, create_inventory = function(size) return bp.inventory(size) end,
  get_player = function(index) return index == 1 and codex_player or nil end }

local function box(w, h) return { left_top = { x = -w / 2 + 0.15, y = -h / 2 + 0.15 }, right_bottom = { x = w / 2 - 0.15, y = h / 2 - 0.15 } } end
local function proto(name, kind, w, h, extra)
  local p = { name = name, type = kind, tile_width = w, tile_height = h, collision_box = box(w, h),
    items_to_place_this = { { name = name, count = 1 } }, mineable_properties = { minable = true } }
  for k, v in pairs(extra or {}) do p[k] = v end
  return p
end
local entities = {
  ["assembling-machine-1"] = proto("assembling-machine-1", "assembling-machine", 3, 3, { fast_replaceable_group = "assembling-machine" }),
  ["assembling-machine-2"] = proto("assembling-machine-2", "assembling-machine", 3, 3, { fast_replaceable_group = "assembling-machine" }),
  inserter = proto("inserter", "inserter", 1, 1, { fast_replaceable_group = "inserter", filter_count = 5 }),
  ["transport-belt"] = proto("transport-belt", "transport-belt", 1, 1, { fast_replaceable_group = "transport-belt" }),
  ["fast-transport-belt"] = proto("fast-transport-belt", "transport-belt", 1, 1, { fast_replaceable_group = "transport-belt" }),
  ["wooden-chest"] = proto("wooden-chest", "container", 1, 1, { fast_replaceable_group = "container" }),
  tree = proto("tree", "tree", 1, 1),
  ["iron-ore"] = proto("iron-ore", "resource", 1, 1),
}
local items = {}
for name, p in pairs(entities) do if p.type ~= "tree" and p.type ~= "resource" then items[name] = { name = name, place_result = p, stack_size = 50 } end end
items.blueprint = { name = "blueprint" }
items["iron-gear-wheel"] = { name = "iron-gear-wheel", stack_size = 100 }
items["iron-plate"] = { name = "iron-plate", stack_size = 100 }
_G.prototypes = { item = items, entity = entities, shortcut = {}, tile = {} }

local own = { name = "player", technologies = {} }
own.recipes = { ["iron-gear-wheel"] = { name = "iron-gear-wheel", enabled = true } }
own.is_chunk_charted = function() return true end
local nature = { name = "neutral" }

-- The world: entities by list; queries are area- or position-bounded.
local world, created, robots = {}, {}, 0
local inventory = {}
local function inside(area, p)
  return p.x > area.left_top.x and p.x < area.right_bottom.x and p.y > area.left_top.y and p.y < area.right_bottom.y
end
local geometry = require("scripts.placement_geometry")
local function spawn(name, position, direction, extra)
  local p = entities[name]
  local e = { valid = true, name = name, type = p.type, position = position, direction = direction or 0,
    force = (p.type == "tree" or p.type == "resource") and nature or own, prototype = p, supports_direction = true, filters = {} }
  e.bounding_box = geometry.footprint(p, position, e.direction)
  e.insert = function(stack) return stack.count end
  e.set_filter = function(index, filter) e.filters[index] = filter end
  e.filter_slot_count = p.type == "inserter" and 5 or 0
  e.get_recipe = function() return e.recipe and { name = e.recipe } or nil end
  e.set_recipe = function(recipe) e.recipe = recipe; return {} end
  for k, v in pairs(extra or {}) do e[k] = v end
  world[#world + 1] = e
  return e
end
local function live()
  local out = {}
  for _, e in ipairs(world) do if e.valid then out[#out + 1] = e end end
  return out
end
-- A search filter field: nil, one name or a list of names.
local function matches(wanted, value)
  if wanted == nil then return true end
  if type(wanted) ~= "table" then return wanted == value end
  for _, w in ipairs(wanted) do if w == value then return true end end
  return false
end
local surface
surface = {
  can_place_entity = function(args)
    local area = geometry.footprint(entities[args.name], args.position, args.direction)
    for _, e in ipairs(live()) do
      if e.type ~= "entity-ghost" and e.type ~= "resource" and geometry.overlaps(area, e.bounding_box) then return false end
    end
    return true
  end,
  find_entities_filtered = function(filter)
    assert(filter.area or filter.position, "no entity query may search the whole surface")
    local out = {}
    for _, e in ipairs(live()) do
      local hit = filter.area and inside(filter.area, e.position)
        or filter.position and geometry.overlaps({ left_top = filter.position, right_bottom = filter.position }, e.bounding_box)
        or filter.position and e.position.x == filter.position.x and e.position.y == filter.position.y
      if hit and matches(filter.type, e.type) and matches(filter.name, e.name)
        and (not filter.force or filter.force == e.force) then
        out[#out + 1] = e
      end
      if filter.limit and #out >= filter.limit then break end
    end
    return out
  end,
  find_entity = function(name, position)
    for _, e in ipairs(live()) do
      if e.name == name and math.abs(e.position.x - position.x) < 0.5 and math.abs(e.position.y - position.y) < 0.5 then return e end
    end
  end,
  create_entity = function(args)
    created[#created + 1] = args
    if args.fast_replace then
      for _, e in ipairs(live()) do
        if e.position.x == args.position.x and e.position.y == args.position.y then
          e.valid = false
          inventory[e.name] = (inventory[e.name] or 0) + 1 -- the character's fast-replace hands it back
        end
      end
    end
    return spawn(args.name, args.position, args.direction)
  end,
  can_fast_replace = function(args)
    for _, e in ipairs(live()) do
      if e.position.x == args.position.x and e.position.y == args.position.y
        and entities[e.name].fast_replaceable_group == entities[args.name].fast_replaceable_group then return true end
    end
    return false
  end,
  find_logistic_networks_by_construction_area = function()
    return robots > 0 and { mock.logistic_network({ all_construction_robots = robots }) } or {}
  end,
  spill_item_stack = function() end,
}
local body = {
  valid = true, name = "character", position = { x = 0.5, y = 0.5 }, force = own, surface = surface,
  bounding_box = { left_top = { x = 0.3, y = 0.3 }, right_bottom = { x = 0.7, y = 0.7 } },
  build_distance = 10, reach_distance = 10, crafting_queue_size = 0, crafting_queue = {},
  get_item_count = function(name) return inventory[name] or 0 end,
  remove_item = function(stack) inventory[stack.name] = (inventory[stack.name] or 0) - stack.count; return stack.count end,
  insert = function(stack) inventory[stack.name] = (inventory[stack.name] or 0) + stack.count; return stack.count end,
  get_main_inventory = function() return { get_insertable_count = function() return 1000 end } end,
  can_reach_entity = function() return true end,
}
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end,
  record = function() return { player_index = 1 } end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
local reached = {}
package.loaded["scripts.actions.approach"] = {
  ensure = function(_, _, target) reached[#reached + 1] = { x = target.x, y = target.y }; return "ok" end,
  ensure_entity = function(_, _, e) reached[#reached + 1] = { x = e.position.x, y = e.position.y }; return "ok" end,
  find_entity_near = function() return nil end,
}
package.loaded["scripts.factory_activity"] = { record = function() end }
package.loaded["scripts.registry"] = { add = function() end, list = function() return {} end, machines = function() return {} end,
  stock_totals = function() return {} end, any = function() return false end, holder_inventory = function() end }

require("scripts.state").init()
local blueprints = require("scripts.blueprints")
local area_ops = require("scripts.actions.area_ops")
local supply = require("scripts.actions.supply")
local jobs = require("scripts.jobs")

local function run(spec, step, max_ticks)
  local task = spec.make_task(step)
  task.id = 7
  spec.runner.start(task)
  local result
  for _ = 1, max_ticks or 400 do
    game.tick = game.tick + 1
    result = spec.runner.tick(task)
    if result then return result, task end
  end
  return nil, task
end

-- ------------------------------------------------------- blueprint_place

blueprints.create({ name = "gears", entities = {
  { name = "assembling-machine-1", dx = -0.5, dy = 0.5, recipe = "iron-gear-wheel" },
  { name = "inserter", dx = 1.5, dy = 0.5, direction = 4 } } })
local stored = bp.state(storage.blueprints.inventory[storage.blueprints.by_name.gears.slot])
stored.entities[2].use_filters, stored.entities[2].filters = true, { { index = 1, name = "iron-plate" } }
inventory["assembling-machine-1"], inventory.inserter = 2, 2

local check_ok = jobs.run_now(area_ops.place_check_job, { name = "gears", position = { x = 10, y = 10 }, check_only = true })
check(check_ok.ok and #check_ok.collisions == 0 and #check_ok.missing == 0 and check_ok.tool_unlock.tool == "blueprint"
  and check_ok.on_ore == nil, "the dry run on free ground reports no collisions, nothing missing and no ore")
-- It also reports what would stand on ore, as build_layout's dry run does,
-- and only the blueprint's survey rows.
local ore = spawn("iron-ore", { x = 9.5, y = 10.5 })
local over_ore = jobs.run_now(area_ops.place_check_job, { name = "gears", position = { x = 10, y = 10 }, check_only = true })
ore.valid = false
check(over_ore.ok and over_ore.on_ore and #over_ore.on_ore == 1 and over_ore.on_ore[1].name == "assembling-machine-1"
  and over_ore.on_ore[1].ore["iron-ore"] == 1 and over_ore.inserters == nil and over_ore.unpowered == nil,
  "a blueprint dry run reports the ore tile under its machine as on_ore")
inventory.inserter = 0
local no_arm = jobs.run_now(area_ops.place_check_job, { name = "gears", position = { x = 10, y = 10 }, check_only = true })
inventory.inserter = 2
check(not no_arm.ok and #no_arm.collisions == 0 and no_arm.unobtainable and no_arm.unobtainable[1].item == "inserter"
  and no_arm.unobtainable[1].code == "ITEM_UNOBTAINABLE",
  "a hand dry run is not ok when an item is neither carried nor craftable now, and names it")
spawn("wooden-chest", { x = 9.5, y = 10.5 })
local blocked = jobs.run_now(area_ops.place_check_job, { name = "gears", position = { x = 10, y = 10 }, check_only = true })
check(not blocked.ok and blocked.collisions[1] and blocked.collisions[1].reason:match("wooden%-chest")
  and blocked.free_position and (blocked.free_position.x ~= 10 or blocked.free_position.y ~= 10),
  "a blocked dry run names the collision and the first free position near it")
check(not pcall(area_ops.place_check_job.start, { name = "gears", position = { x = 0, y = 0 } }),
  "blueprint_place over RPC is only the check_only dry run")
world[#world].valid = false

local placed, place_task = run(area_ops.place_action, { name = "gears", position = { x = 10.2, y = 9.8 }, direction = 4 })
local machine, arm
for _, e in ipairs(live()) do
  if e.name == "assembling-machine-1" then machine = e end
  if e.name == "inserter" then arm = e end
end
check(placed and placed.status == "done" and placed.outcome.code == "LAYOUT_BUILT" and placed.outcome.blueprint == "gears"
  and place_task._anchor.x == 10 and place_task._anchor.y == 10,
  "blueprint_place by hand builds the whole blueprint through build_layout at the rounded position")
check(machine and machine.position.x == 9.5 and machine.position.y == 9.5 and machine.recipe == "iron-gear-wheel",
  "the blueprint turned clockwise puts the machine at its turned offset with its recipe")
check(arm and arm.position.x == 9.5 and arm.position.y == 11.5 and arm.direction == 8 and arm.use_filters == true
  and arm.filters[1] == "iron-plate", "the turned inserter faces south and gets the blueprint's filters")
check(inventory["assembling-machine-1"] == 1 and inventory.inserter == 1, "hand placement uses the body's own items")

-- Ghosts: build_blueprint at the rounded position; robots are counted, items are not given.
robots = 0
local ghosted = run(area_ops.place_action, { name = "gears", position = { x = 30, y = 30 }, mode = "ghosts", direction = 8 })
local args = bp.built[#bp.built]
check(ghosted.status == "done" and ghosted.outcome.ghosts == 2 and args.position.x == 30 and args.direction == 8
  and args.build_mode == defines.build_mode.forced and args.force == own and args.skip_fog_of_war,
  "ghosts mode places the blueprint's ghosts with build_blueprint")
check(ghosted.outcome.construction_robots == 0 and ghosted.outcome.note:match("build_ghosts")
  and inventory["assembling-machine-1"] == 1, "no robot covers the spot: the result says so and no item was used")
run(area_ops.place_action, { name = "gears", position = { x = 40, y = 30 }, mode = "ghosts", flip = "horizontal" })
check(bp.built[#bp.built] and not storage.blueprints.inventory[require("scripts.state").BLUEPRINT_SLOTS].valid_for_read,
  "a flipped placement builds from a scratch copy, emptied afterwards")
check(not pcall(area_ops.place_action.validate, { name = "gears", position = { x = 0, y = 0 }, direction = 2 }, 1)
  and not pcall(area_ops.place_action.validate, { name = "gears", position = { x = 0, y = 0 }, check_only = true }, 1)
  and not pcall(area_ops.place_action.validate, { name = "gears", position = { x = 0, y = 0 }, mode = "air" }, 1),
  "a plan step needs a quarter-turn direction, a known mode and no check_only")
check(area_ops.place_action.budget_steps({ name = "gears" }) == 2, "a hand placement's budget follows the blueprint's size")

-- Native callbacks can return invalid or missing ghosts after a partial placement.
local native_stack = storage.blueprints.inventory[storage.blueprints.by_name.gears.slot]
local native_build = native_stack.build_blueprint
native_stack.build_blueprint = function(args)
  local result = native_build(args)
  result[2].valid = false
  return result
end
local partial = run(area_ops.place_action, { name = "gears", position = { x = 45, y = 30 }, mode = "ghosts" })
check(partial.status == "partial" and partial.outcome.code == "GHOSTS_PARTIAL" and partial.outcome.ghosts == 1
  and partial.outcome.expected == 2 and partial.outcome.submission_complete == false
  and partial.outcome.construction_complete == false and #partial.outcome.placed == 1,
  "a partial native blueprint result counts only valid ghosts and never claims full placement or robot completion")
native_stack.build_blueprint = function() return {} end
local absent = run(area_ops.place_action, { name = "gears", position = { x = 50, y = 30 }, mode = "ghosts" })
check(absent.status == "failed" and absent.outcome.ghosts == 0 and absent.outcome.expected == 2,
  "no native ghosts remains a failed submission, with expected work visible")
native_stack.build_blueprint = native_build
local native_networks = surface.find_logistic_networks_by_construction_area
surface.find_logistic_networks_by_construction_area = function() error("native network read unavailable") end
local uncertain = run(area_ops.place_action, { name = "gears", position = { x = 52, y = 30 }, mode = "ghosts" })
check(uncertain.status == "done" and uncertain.outcome.readiness.coverage == "unknown"
  and uncertain.outcome.readiness.counts_complete == false and uncertain.outcome.note:match("incomplete"),
  "native coverage read failure leaves submission observable without falsely claiming no construction robots")
surface.find_logistic_networks_by_construction_area = native_networks


stored.entities[1].wires = { { 1, 1, 2, 1 } }
local before_hand = #created
check(not pcall(run, area_ops.place_action, { name = "gears", position = { x = 55, y = 30 } }) and #created == before_hand,
  "hand blueprint placement refuses native wiring before building instead of dropping it")
stored.entities[1].wires = nil
stored.entities[1].items = { { id = { name = "speed-module", quality = "uncommon" },
  items = { in_inventory = { { inventory = 4, stack = 0, count = 1 } } } } }
check(not pcall(run, area_ops.place_action, { name = "gears", position = { x = 55, y = 30 } }) and #created == before_hand,
  "hand blueprint placement refuses qualified item requests before spending normal body stock")
stored.entities[1].items = nil

-- ------------------------------------------------------------ build_ghosts

local revived = {}
local function ghost(name, position, requests)
  local g = spawn(name, position, 0)
  g.type, g.name, g.ghost_name, g.ghost_prototype = "entity-ghost", "entity-ghost", name, entities[name]
  g.item_requests = requests or {}
  g.revive = function()
    if g.blocked then return nil end
    g.valid = false
    revived[#revived + 1] = name
    return {}, spawn(name, position, 0), #g.item_requests > 0 and { valid = true } or nil
  end
  return g
end
inventory["wooden-chest"], inventory.inserter = 2, 1
body.position = { x = 100.5, y = 100.5 }
ghost("wooden-chest", { x = 103.5, y = 100.5 })
ghost("inserter", { x = 101.5, y = 100.5 }, { { name = "speed-module", count = 1 } })
local stuck = ghost("wooden-chest", { x = 106.5, y = 100.5 })
stuck.blocked = true
local gone = ghost("wooden-chest", { x = 108.5, y = 100.5 })
local ghosts_result, ghosts_task = run(area_ops.ghosts_action, { center = { x = 104, y = 100 }, radius = 6 }, 1)
check(ghosts_result == nil and revived[1] == "inserter", "build_ghosts builds the nearest ghost first, one per tick")
gone.valid = false
for _ = 1, 20 do ghosts_result = area_ops.ghosts_action.runner.tick(ghosts_task); if ghosts_result then break end end
check(ghosts_result and ghosts_result.status == "partial" and ghosts_result.outcome.built == 2 and ghosts_result.outcome.total == 4
  and ghosts_result.outcome.failed_count == 1 and inventory["wooden-chest"] == 1 and inventory.inserter == 0,
  "each revived ghost takes one item from the body; a blocked one is reported and a vanished one skipped")
check(ghosts_result.outcome.item_requests_pending == 1, "a revived ghost's module requests are reported as pending")
check(not pcall(area_ops.ghosts_action.validate, { radius = 3 }, 1), "build_ghosts needs an area or a centre")

-- ------------------------------------------------------- deconstruct_area

body.position = { x = 200.5, y = 200.5 }
local doomed = {}
for i = 1, 60 do doomed[i] = spawn("transport-belt", { x = 200.5 + (i % 10), y = 210.5 + math.floor(i / 10) }) end
local ordered = 0
for _, e in ipairs(doomed) do
  e.order_deconstruction = function(force) assert(force == own); e.marked = true; ordered = ordered + 1; return true end
  e.to_be_deconstructed = function() return e.marked == true end
  e.cancel_deconstruction = function() e.marked = false end
end
local first_tick, robots_task = run(area_ops.deconstruct_action,
  { area = { left_top = { x = 199, y = 209 }, right_bottom = { x = 212, y = 218 } }, mode = "robots" }, 1)
check(first_tick == nil and ordered == area_ops.ORDERS_PER_TICK, "robot orders go out in bounded batches per tick")
local orders = area_ops.deconstruct_action.runner.tick(robots_task)
check(orders and orders.outcome.code == "DECONSTRUCTION_ORDERED" and orders.outcome.done == 60 and ordered == 60
  and orders.outcome.tool_unlock.tool == "deconstruction-planner",
  "deconstruct_area robots orders every own entity in the area")
local cancelled = run(area_ops.deconstruct_action,
  { area = { left_top = { x = 199, y = 209 }, right_bottom = { x = 212, y = 218 } }, mode = "cancel" })
check(cancelled.outcome.code == "DECONSTRUCTION_CANCELLED" and cancelled.outcome.done == 60 and not doomed[1].marked,
  "mode cancel cancels the orders")
for _, e in ipairs(doomed) do e.valid = false end

-- Hand: the mine runner is the body's; here a fake one records the order.
local mined = {}
local full_after
supply.register_runner("mine", {
  start = function(sub) mined[#mined + 1] = sub end,
  tick = function(sub)
    if full_after and #mined > full_after then
      return { status = "failed", detail = "mining stopped — Codex inventory is full" }
    end
    for _, e in ipairs(live()) do
      if e.position.x == sub.target.x and e.position.y == sub.target.y then e.valid = false end
    end
    return { status = "done", detail = "mined" }
  end,
})
spawn("wooden-chest", { x = 205.5, y = 200.5 })
spawn("tree", { x = 202.5, y = 200.5 })
spawn("inserter", { x = 203.5, y = 200.5 })
local by_hand = run(area_ops.deconstruct_action,
  { area = { left_top = { x = 201, y = 199 }, right_bottom = { x = 207, y = 202 } }, filter = { "tree", "wooden-chest" } })
check(by_hand.status == "done" and by_hand.outcome.code == "AREA_CLEARED" and by_hand.outcome.done == 2
  and mined[1].target.x == 202.5 and mined[1].target_kind == "natural" and mined[1].entity
  and mined[2].target_kind == "owned" and mined[2].allow_fluid_loss,
  "deconstruct_area by hand mines the filtered entities nearest first: trees as natural, own as owned")
mined, full_after = {}, 1
spawn("wooden-chest", { x = 204.5, y = 201.5 })
local stopped = run(area_ops.deconstruct_action, { center = { x = 204, y = 201 }, radius = 3 })
check(stopped.status == "partial" and stopped.outcome.stopped == "my inventory is full" and #mined == 2,
  "a full inventory stops the clearing")
full_after = nil

-- An ore field: hundreds of resource entities never crowd own buildings out.
mined = {}
body.position = { x = 500.5, y = 500.5 }
for x = 0, 19 do for y = 0, 19 do spawn("iron-ore", { x = 500.5 + x, y = 500.5 + y }) end end
spawn("wooden-chest", { x = 518.5, y = 518.5 })
spawn("inserter", { x = 519.5, y = 519.5 })
spawn("tree", { x = 517.5, y = 519.5 })
local ore_field = run(area_ops.deconstruct_action, { area = { left_top = { x = 500, y = 500 }, right_bottom = { x = 520, y = 520 } } })
check(ore_field.status == "done" and ore_field.outcome.done == 3 and ore_field.outcome.total == 3 and not ore_field.outcome.truncated,
  "deconstruct_area on 400 ore tiles still finds the own buildings and the tree, and is not truncated")
local filtered_ore = run(area_ops.deconstruct_action, { area = { left_top = { x = 500, y = 500 }, right_bottom = { x = 520, y = 520 } },
  filter = { "iron-ore" } })
check(filtered_ore.status == "done" and filtered_ore.outcome.total == 0, "resources are never listed, even by name")

-- A LuaEntity is userdata: a refused order still names it.
local refusing = io.tmpfile() -- a full userdata; its metatable is replaced below
debug.setmetatable(refusing, { __index = { valid = true, name = "wooden-chest", type = "container",
  position = { x = 600.5, y = 600.5 }, force = own, prototype = entities["wooden-chest"],
  bounding_box = geometry.footprint(entities["wooden-chest"], { x = 600.5, y = 600.5 }, 0),
  order_deconstruction = function() return false end } })
world[#world + 1] = refusing
local refused_order = run(area_ops.deconstruct_action, { center = { x = 600, y = 600 }, radius = 2, mode = "robots" })
check(refused_order.outcome.failed_count == 1 and refused_order.outcome.failed[1].name == "wooden-chest"
  and refused_order.outcome.failed[1].x == 600.5 and refused_order.outcome.failed[1].reason:match("refused"),
  "a failure row of a userdata entity keeps its name and position")
world[#world] = { valid = false, position = { x = 0, y = 0 } }

-- ------------------------------------------------------------ upgrade_area

body.position = { x = 300.5, y = 300.5 }
local slow = { spawn("transport-belt", { x = 301.5, y = 300.5 }, 4), spawn("transport-belt", { x = 302.5, y = 300.5 }, 4) }
local am1 = spawn("assembling-machine-1", { x = 305.5, y = 300.5 }, 0, { recipe = "iron-gear-wheel" })
inventory["fast-transport-belt"], inventory["assembling-machine-2"] = 5, 1
inventory["transport-belt"] = 0
codex_player.connected = false -- the owner's couch client is away: the body still upgrades
local upgraded = run(area_ops.upgrade_action, { center = { x = 302, y = 300 }, radius = 3, from = "transport-belt",
  to = "fast-transport-belt" })
local fast = {}
for _, e in ipairs(live()) do if e.name == "fast-transport-belt" then fast[#fast + 1] = e end end
local replace_args = created[#created]
check(upgraded.status == "done" and upgraded.outcome.code == "UPGRADED" and upgraded.outcome.done == 2 and #fast == 2
  and fast[1].direction == 4 and not slow[1].valid and inventory["fast-transport-belt"] == 3 and inventory["transport-belt"] == 2,
  "upgrade_area by hand fast-replaces each belt in place, keeping its direction; the old belts return to the body")
check(replace_args.fast_replace and replace_args.character == body and replace_args.player == nil and replace_args.raise_built,
  "the fast-replace is the body's own, never a player's (no undo queue entry, no connected client needed)")
local machines = run(area_ops.upgrade_action, { center = { x = 305, y = 300 }, radius = 3, from = "assembling-machine-1",
  to = "assembling-machine-2" })
local am2
for _, e in ipairs(live()) do if e.name == "assembling-machine-2" then am2 = e end end
check(machines.status == "done" and am2 and am2.recipe == "iron-gear-wheel" and not am1.valid,
  "an upgraded assembling machine keeps its recipe")
local refused = run(area_ops.upgrade_action, { center = { x = 302, y = 300 }, radius = 3, from = "fast-transport-belt",
  to = "assembling-machine-2" })
check(refused.status == "failed" and refused.outcome.code == "UPGRADE_NOT_FAST_REPLACEABLE" and refused.detail:match("mine each"),
  "a different footprint is not fast-replaced: the result says to mine and place")
local upgrade_orders = {}
for _, e in ipairs(fast) do e.order_upgrade = function(args) upgrade_orders[#upgrade_orders + 1] = args; return true end end
local by_robots = run(area_ops.upgrade_action, { center = { x = 302, y = 300 }, radius = 3, from = "fast-transport-belt",
  to = "transport-belt", mode = "robots" })
check(by_robots.outcome.code == "UPGRADE_ORDERED" and #upgrade_orders == 2 and upgrade_orders[1].target == "transport-belt"
  and upgrade_orders[1].force == own and by_robots.outcome.tool_unlock.tool == "upgrade-planner",
  "upgrade_area robots orders the upgrade of each entity")
inventory["fast-transport-belt"] = 0
local short = run(area_ops.upgrade_action, { center = { x = 309, y = 309 }, radius = 2, from = "transport-belt", to = "fast-transport-belt" })
check(short.status == "done" and short.outcome.total == 0, "an area without the entity has nothing to upgrade")

-- ----------------------------------------------------------- copy_settings

local source = spawn("assembling-machine-2", { x = 400.5, y = 400.5 }, 0, { recipe = "iron-gear-wheel" })
local copied_from = {}
local function target(position)
  local e = spawn("assembling-machine-1", position, 0)
  e.copy_settings = function(from)
    copied_from[#copied_from + 1] = from
    e.recipe = from.recipe
    return { { name = "iron-plate", count = 3, quality = "normal" } }
  end
  return e
end
local t1, t2 = target({ x = 404.5, y = 400.5 }), target({ x = 408.5, y = 400.5 })
inventory["iron-plate"] = 0
reached = {}
local copied = run(area_ops.copy_action, { from = { x = 400.5, y = 400.5 },
  to = { { x = 404.5, y = 400.5 }, { x = 408.5, y = 400.5 }, { x = 420.5, y = 420.5 } } })
check(copied.status == "partial" and copied.outcome.copied == 2 and t1.recipe == "iron-gear-wheel" and t2.recipe == "iron-gear-wheel"
  and copied_from[1] == source and copied.outcome.failed_count == 1,
  "copy_settings copies the source's settings onto each own target and reports a missing one")
check(inventory["iron-plate"] == 6 and copied.outcome.returned["iron-plate"] == 6, "what a copy pushes out goes into the inventory")
check(reached[1].x == 400.5 and reached[2].x == 404.5 and reached[3].x == 408.5, "the body reaches the source, then each target")

mock.assert_clean()
print(failures == 0 and "\nALL AREA ACTION TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
