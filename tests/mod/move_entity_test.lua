-- Offline tests for move_entity (actions/move_entity.lua): the body mines an
-- own entity (its contents go into the inventory), places it at the target
-- and restores its recipe, direction, settings, modules, fuel and
-- ingredients; a target that cannot take it is refused before anything is
-- mined; a placement that fails after mining leaves it in the inventory and
-- says so.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local stacks = dofile(here .. "/item_stack_mock.lua")
_G.storage = {}
_G.game = { tick = 100, create_inventory = stacks.create_inventory }
_G.defines = { build_check_type = { manual = 1, ghost_revive = 2 }, inventory = { chest = 1, crafter_input = 2 },
  direction = { north = 0, east = 4, south = 8, west = 12 } }

local function box(w, h) return { left_top = { x = -w / 2 + 0.15, y = -h / 2 + 0.15 }, right_bottom = { x = w / 2 - 0.15, y = h / 2 - 0.15 } } end
local function proto(name, kind, w, h)
  return { name = name, type = kind, tile_width = w, tile_height = h, collision_box = box(w, h),
    items_to_place_this = { { name = name, count = 1 } }, mineable_properties = { minable = true } }
end
local entities = {
  ["assembling-machine-1"] = proto("assembling-machine-1", "assembling-machine", 3, 3),
  ["stone-furnace"] = proto("stone-furnace", "furnace", 2, 2),
  inserter = proto("inserter", "inserter", 1, 1),
  ["wooden-chest"] = proto("wooden-chest", "container", 1, 1),
  tree = proto("tree", "tree", 1, 1),
}
local items = {}
for name, p in pairs(entities) do if p.type ~= "tree" then items[name] = { name = name, place_result = p, stack_size = 50 } end end
for _, name in ipairs({ "iron-plate", "speed-module", "coal", "iron-gear-wheel", "wood" }) do items[name] = { name = name, stack_size = 100 } end
_G.prototypes = { item = items, entity = entities }

local own, nature = { name = "player", recipes = {} }, { name = "neutral" }
local geometry = require("scripts.placement_geometry")
local world, inventory, real_main = {}, {}, nil
local function live()
  local out = {}
  for _, e in ipairs(world) do if e.valid then out[#out + 1] = e end end
  return out
end
local function slots(contents)
  local held = contents or {}
  return {
    -- Keyed "name" or "name@quality".
    get_contents = function()
      local rows = {}
      for key, count in pairs(held) do
        local name, quality = key:match("^(.-)@(.+)$")
        if count > 0 then rows[#rows + 1] = { name = name or key, count = count, quality = quality or "normal" } end
      end
      table.sort(rows, function(a, b) return a.name < b.name end)
      return rows
    end,
    insert = function(stack)
      local quality = type(stack.quality) == "table" and stack.quality.name or stack.quality
      local key = (quality == nil or quality == "normal") and stack.name or stack.name .. "@" .. quality
      held[key] = (held[key] or 0) + stack.count
      return stack.count
    end,
    held = held,
  }
end
local function spawn(name, position, direction, extra)
  local p = entities[name]
  local e = { valid = true, name = name, type = p.type, position = position, direction = direction or 0,
    force = p.type == "tree" and nature or own, prototype = p, supports_direction = true, filters = {},
    filter_slot_count = p.type == "inserter" and 5 or 0 }
  e.bounding_box = geometry.footprint(p, position, e.direction)
  e.inventories = { modules = slots(), fuel = slots(), input = slots() }
  e.get_module_inventory = function() return p.type == "assembling-machine" and e.inventories.modules or nil end
  e.get_fuel_inventory = function() return p.type == "furnace" and e.inventories.fuel or nil end
  e.get_inventory = function(id) return id == defines.inventory.crafter_input and e.inventories.input or nil end
  e.get_recipe = function() return e.recipe and { name = e.recipe } or nil end
  e.set_recipe = function(recipe) e.recipe = recipe; return {} end
  e.get_filter = function(index) return e.filters[index] and { name = e.filters[index] } or nil end
  e.set_filter = function(index, filter) e.filters[index] = filter end
  for k, v in pairs(extra or {}) do e[k] = v end
  world[#world + 1] = e
  return e
end
-- Water tiles by "x,y" of their left-top corner.
local water = {}
local function wet_tiles(area)
  local n = 0
  for x = math.floor(area.left_top.x), math.ceil(area.right_bottom.x) - 1 do
    for y = math.floor(area.left_top.y), math.ceil(area.right_bottom.y) - 1 do
      if water[x .. "," .. y] then n = n + 1 end
    end
  end
  return n
end
local surface = {
  can_place_entity = function(args)
    local area = geometry.footprint(entities[args.name], args.position, args.direction)
    if wet_tiles(area) > 0 then return false end
    for _, e in ipairs(live()) do
      if geometry.overlaps(area, e.bounding_box)
        and geometry.mask_overlap(entities[args.name].collision_mask, e.prototype.collision_mask, false) ~= false then
        return false
      end
    end
    return true
  end,
  -- Water and land tiles with their 2.0 collision layers.
  find_tiles_filtered = function(filter)
    assert(filter.area and filter.limit and not filter.collision_mask, "a bounded tile search, matched in Lua")
    local out = {}
    for x = math.floor(filter.area.left_top.x), math.ceil(filter.area.right_bottom.x) - 1 do
      for y = math.floor(filter.area.left_top.y), math.ceil(filter.area.right_bottom.y) - 1 do
        local wet = water[x .. "," .. y]
        out[#out + 1] = { name = wet and "water" or "grass-1", position = { x = x, y = y }, prototype = { collision_mask = wet
          and { layers = { water_tile = true, resource = true, item = true, player = true, doodad = true } }
          or { layers = { ground_tile = true } } } }
      end
    end
    assert(#out <= filter.limit, "the limit covers every footprint tile")
    return out
  end,
  find_entities_filtered = function(filter)
    assert(filter.area or filter.position, "no entity query may search the whole surface")
    local out = {}
    for _, e in ipairs(live()) do
      local hit = filter.area and geometry.overlaps(filter.area, e.bounding_box)
        or filter.position and geometry.overlaps({ left_top = filter.position, right_bottom = filter.position }, e.bounding_box)
      -- A layer filter keeps only entities with every listed layer, which
      -- drops a transport belt under a chest's layers, as a live trial did.
      for layer in pairs(filter.collision_mask or {}) do
        local mask = e.prototype.collision_mask
        if not (mask and mask.layers[layer]) then hit = false end
      end
      local types = type(filter.type) == "table" and filter.type or filter.type and { filter.type } or nil
      local type_ok = not types
      for _, t in ipairs(types or {}) do if t == e.type then type_ok = true end end
      if hit and type_ok and (not filter.force or filter.force == e.force) then out[#out + 1] = e end
    end
    return out
  end,
  find_entity = function(name, position)
    for _, e in ipairs(live()) do
      if e.name == name and math.abs(e.position.x - position.x) < 0.5 and math.abs(e.position.y - position.y) < 0.5 then return e end
    end
  end,
  create_entity = function(args) return spawn(args.name, args.position, args.direction, { mirroring = args.mirror == true }) end,
}
local body = {
  valid = true, name = "character", position = { x = 0.5, y = 0.5 }, force = own, surface = surface,
  bounding_box = { left_top = { x = 0.3, y = 0.3 }, right_bottom = { x = 0.7, y = 0.7 } },
  build_distance = 10, reach_distance = 10, crafting_queue_size = 0, crafting_queue = {},
  get_item_count = function(name) return inventory[name] or 0 end,
  remove_item = function(stack) inventory[stack.name] = (inventory[stack.name] or 0) - stack.count; return stack.count end,
  insert = function(stack) inventory[stack.name] = (inventory[stack.name] or 0) + stack.count; return stack.count end,
  -- Restored contents leave as the main inventory's own stacks (one per
  -- name), or those of real_main when a case sets it.
  get_main_inventory = function() return real_main or stacks.view(inventory) end,
  can_reach_entity = function() return true end,
}
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end, ensure_entity = function() return "ok" end }
package.loaded["scripts.factory_activity"] = { record = function() end }
package.loaded["scripts.registry"] = { add = function() end, list = function() return {} end, machines = function() return {} end,
  stock_totals = function() return {} end, any = function() return false end }

local supply = require("scripts.actions.supply")
local move = require("scripts.actions.move_entity")
-- The body's mining, as the mine runner does it: the entity and every
-- inventory it holds go into the inventory.
local mines, mine_fails = {}, false
supply.register_runner("mine", {
  start = function(sub) mines[#mines + 1] = sub end,
  tick = function(sub)
    if mine_fails then return { status = "failed", detail = "Codex inventory is full" } end
    for _, e in ipairs(live()) do
      if geometry.overlaps({ left_top = sub.target, right_bottom = sub.target }, e.bounding_box) then
        e.valid = false
        if e.type ~= "tree" then inventory[e.name] = (inventory[e.name] or 0) + 1 end
        for _, inv in pairs(e.inventories) do
          for name, count in pairs(inv.held) do if type(count) == "number" then inventory[name] = (inventory[name] or 0) + count end end
        end
        return { status = "done", detail = "mined" }
      end
    end
    return { status = "failed", detail = "nothing there" }
  end,
})

local function run(step)
  local task = move.action.make_task(step)
  task.id = 3
  move.start(task)
  for _ = 1, 50 do
    game.tick = game.tick + 1
    local result = move.tick(task)
    if result then return result end
  end
end
local function find(name)
  for _, e in ipairs(live()) do if e.name == name then return e end end
end

-- An assembling machine with a recipe, a module and ingredients moves east.
local machine = spawn("assembling-machine-1", { x = 10.5, y = 10.5 }, 0, { recipe = "iron-gear-wheel" })
machine.inventories.modules.held["speed-module"] = 1
machine.inventories.input.held["iron-plate"] = 4
inventory["iron-gear-wheel"] = 0
local moved = run({ from = { x = 10.2, y = 10.7 }, to = { x = 20.4, y = 10.6 } })
local placed = find("assembling-machine-1")
check(moved and moved.status == "done" and moved.outcome.code == "MOVED" and moved.outcome.moved
  and placed.position.x == 20.5 and placed.position.y == 10.5 and not machine.valid,
  "move_entity mines the machine and places it at the target, snapped to its grid")
check(mines[1].target_kind == "owned" and mines[1].expected_name == "assembling-machine-1",
  "the move mines the exact own entity")
check(placed.recipe == "iron-gear-wheel" and placed.inventories.modules.held["speed-module"] == 1
  and placed.inventories.input.held["iron-plate"] == 4 and inventory["speed-module"] == 0 and inventory["iron-plate"] == 0
  and inventory["assembling-machine-1"] == 0 and moved.outcome.restored.recipe == "iron-gear-wheel"
  and moved.outcome.restored.items["iron-plate"] == 4, "its recipe, module and ingredients are put back")

-- Rare plates it held go back as the body's own rare plates, never as normal
-- ones made by name; the body's normal plates stay.
real_main = stacks.inventory(4)
stacks.put(real_main, 1, { name = "iron-plate", count = 10 })
stacks.put(real_main, 2, { name = "iron-plate", count = 4, quality = "rare" })
machine = find("assembling-machine-1")
machine.inventories.input.held["iron-plate"], machine.inventories.modules.held["speed-module"] = 0, 0
machine.inventories.input.held["iron-plate@rare"] = 4
local rare = run({ from = { x = 20.5, y = 10.5 }, to = { x = 26.5, y = 10.5 } })
placed = find("assembling-machine-1")
check(rare and rare.status == "done" and rare.outcome.shortfall == nil and placed.inventories.input.held["iron-plate@rare"] == 4
  and (placed.inventories.input.held["iron-plate"] or 0) == 0 and rare.outcome.restored.items["iron-plate@rare"] == 4
  and real_main.get_item_count({ name = "iron-plate", quality = "rare" }) == 0
  and real_main.get_item_count({ name = "iron-plate", quality = "normal" }) == 10,
  "rare ingredients go back as the body's own rare stacks and its normal plates stay")
real_main, inventory["iron-plate@rare"] = nil, nil

-- An inserter keeps its filters; a direction given turns it.
local arm = spawn("inserter", { x = 30.5, y = 30.5 }, 4, { use_filters = true })
arm.filters[1] = "iron-plate"
local turned = run({ from = { x = 30.5, y = 30.5 }, to = { x = 32.5, y = 30.5 }, direction = 8 })
local new_arm = find("inserter")
check(turned.status == "done" and new_arm.direction == 8 and new_arm.use_filters == true and new_arm.filters[1] == "iron-plate"
  and turned.outcome.restored.settings == true, "an inserter moves with its filters and faces the given direction")
local kept = run({ from = { x = 32.5, y = 30.5 }, to = { x = 34.5, y = 30.5 } })
check(kept.status == "done" and find("inserter").direction == 8, "without a direction the entity keeps its own")

-- A mirrored machine is placed mirrored.
local flipped = spawn("assembling-machine-1", { x = 70.5, y = 70.5 }, 0, { mirroring = true })
local flipped_move = run({ from = { x = 70.5, y = 70.5 }, to = { x = 76.5, y = 70.5 } })
local landed = surface.find_entity("assembling-machine-1", { x = 76.5, y = 70.5 })
check(flipped_move.status == "done" and not flipped.valid and landed and landed.mirroring == true,
  "a mirrored machine stays mirrored")

-- A furnace's fuel goes back, and only what it held.
local furnace = spawn("stone-furnace", { x = 40, y = 40 }, 0)
furnace.inventories.fuel.held.coal = 5
inventory.coal = 7
local fuelled = run({ from = { x = 40, y = 40 }, to = { x = 44, y = 40 } })
check(fuelled.status == "done" and find("stone-furnace").inventories.fuel.held.coal == 5 and inventory.coal == 7,
  "a furnace's fuel goes back in; the body keeps its own coal")
local moved_again = run({ from = { x = 44, y = 40 }, to = { x = 48, y = 40 } })
check(moved_again.status == "done" and find("stone-furnace").position.x == 48, "a moved entity can move again")

-- A target that cannot take it: refused before anything is mined.
mines = {}
spawn("wooden-chest", { x = 60.5, y = 40.5 })
local ok, err = pcall(move.start, move.action.make_task({ from = { x = 48, y = 40 }, to = { x = 60.5, y = 40.5 } }))
check(not ok and tostring(err):match("wooden%-chest stands") and #mines == 0 and find("stone-furnace").valid,
  "a target another entity stands on is refused before mining")
-- Trees there are cleared by the placement.
spawn("tree", { x = 70.5, y = 40.5 })
local cleared = run({ from = { x = 48, y = 40 }, to = { x = 71, y = 41 } })
check(cleared.status == "done" and find("stone-furnace").position.x == 71 and not find("tree"),
  "a tree on the target is mined by the placement")
check(not pcall(move.start, move.action.make_task({ from = { x = 71, y = 41 }, to = { x = 71, y = 41 } })),
  "a move onto its own spot facing the same way is refused")
check(not pcall(move.start, move.action.make_task({ from = { x = 500, y = 500 }, to = { x = 0, y = 0 } })),
  "a move from where no own entity stands is refused")

-- A short move overlapping its own spot still checks the rest of the target.
mines = {}
local chest = spawn("wooden-chest", { x = 72.5, y = 40.5 })
local ok_shift, err_shift = pcall(move.start, move.action.make_task({ from = { x = 71, y = 41 }, to = { x = 72, y = 41 } }))
check(not ok_shift and tostring(err_shift):match("wooden%-chest stands") and #mines == 0 and find("stone-furnace").valid,
  "a one-tile shift onto a chest is refused before mining, though it overlaps its own spot")
chest.valid = false
water["72,40"] = true
local ok_wet, err_wet = pcall(move.start, move.action.make_task({ from = { x = 71, y = 41 }, to = { x = 72, y = 41 } }))
check(not ok_wet and tostring(err_wet):match("water") and #mines == 0, "a short shift onto water is refused before mining")
water["72,40"] = nil
local shifted = run({ from = { x = 71, y = 41 }, to = { x = 72, y = 41 } })
check(shifted.status == "done" and find("stone-furnace").position.x == 72, "a free one-tile shift moves it")
-- A tree standing on water: the placement would clear the tree, never the water.
mines = {}
spawn("tree", { x = 100.5, y = 40.5 })
water["100,40"] = true
local ok_tree, err_tree = pcall(move.start, move.action.make_task({ from = { x = 72, y = 41 }, to = { x = 101, y = 41 } }))
check(not ok_tree and tostring(err_tree):match("water") and #mines == 0, "a tree on water does not hide the water")
local carried = run({ from = { x = 72, y = 41 }, to = { x = 71, y = 41 } })
check(carried.status == "done", "the furnace moves back")

-- Collision masks decide what blocks the target: a transport belt there is
-- named with its position, and an entity on another layer never blocks.
local function layers(...)
  local set = {}
  for _, layer in ipairs({ ... }) do set[layer] = true end
  return { layers = set }
end
entities["wooden-chest"].collision_mask = layers("item", "object", "player", "water_tile", "is_object", "is_lower_object")
entities["stone-furnace"].collision_mask = layers("item", "meltable", "object", "player", "water_tile", "is_object", "is_lower_object")
entities["transport-belt"] = proto("transport-belt", "transport-belt", 1, 1)
entities["transport-belt"].collision_mask = layers("floor", "meltable", "object", "transport_belt", "water_tile")
entities["elevated-straight-rail"] = proto("elevated-straight-rail", "elevated-straight-rail", 2, 2)
entities["elevated-straight-rail"].collision_mask = layers("elevated_rail")
mines = {}
local crate = spawn("wooden-chest", { x = 110.5, y = 40.5 })
local belt = spawn("transport-belt", { x = 112.5, y = 40.5 })
local ok_belt, err_belt = pcall(move.start, move.action.make_task({ from = { x = 110.5, y = 40.5 }, to = { x = 112.5, y = 40.5 } }))
check(not ok_belt and tostring(err_belt):match("transport%-belt stands at %(112%.5, 40%.5%)")
  and not tostring(err_belt):match("water") and #mines == 0 and crate.valid,
  "a transport belt on the target is named with its position, not blamed on water")
-- Water under a shift that overlaps the furnace's own spot is matched by its
-- tile's layers against the furnace's, before anything is mined.
water["72,40"] = true
local ok_layered, err_layered = pcall(move.start, move.action.make_task({ from = { x = 71, y = 41 }, to = { x = 72, y = 41 } }))
check(not ok_layered and tostring(err_layered):match("water") and #mines == 0,
  "water under a shift is matched by collision layers before mining")
water["72,40"] = nil
local rail = spawn("elevated-straight-rail", { x = 72, y = 41 })
local under_rail = run({ from = { x = 71, y = 41 }, to = { x = 72, y = 41 } })
check(under_rail.status == "done" and find("stone-furnace").position.x == 72,
  "the unfiltered blocker search still lets an elevated rail, on another layer, stand over the target")
crate.valid, belt.valid, rail.valid = false, false, false
local rail_back = run({ from = { x = 72, y = 41 }, to = { x = 71, y = 41 } })
check(rail_back.status == "done", "and the furnace moves back")

-- A furnace's current recipe follows its input: it is not set again.
local smelting = find("stone-furnace")
smelting.recipe = "iron-plate"
smelting.set_recipe = nil -- set_recipe is AssemblingMachine-only
local smelted = run({ from = { x = 71, y = 41 }, to = { x = 75, y = 41 } })
check(smelted.status == "done" and smelted.outcome.notes == nil and smelted.outcome.restored.recipe == nil
  and not smelted.detail:match("recipe"), "a moved furnace reports no recipe it could not set")
local back = run({ from = { x = 75, y = 41 }, to = { x = 71, y = 41 } })
check(back.status == "done", "and it moves back")

-- Mining fails: nothing moved. Placement fails after mining: it is in the inventory.
mine_fails = true
local stuck = run({ from = { x = 71, y = 41 }, to = { x = 80, y = 41 } })
check(stuck.status == "failed" and stuck.outcome.code == "MOVE_MINE_FAILED" and not stuck.outcome.in_inventory
  and find("stone-furnace").valid, "a failed mining leaves the entity where it was")
mine_fails = false
local task = move.action.make_task({ from = { x = 71, y = 41 }, to = { x = 90, y = 41 } })
task.id = 4
move.start(task)
local late, blocker
for _ = 1, 50 do
  late = move.tick(task)
  -- Something lands on the target while the furnace is carried.
  if not blocker and task._sub and task._sub.type == "place" then blocker = spawn("wooden-chest", { x = 90.5, y = 40.5 }) end
  if late then break end
end
check(late and late.status == "failed" and late.outcome.code == "MOVE_PLACE_FAILED" and late.outcome.in_inventory
  and inventory["stone-furnace"] == 1 and late.detail:match("in my inventory"),
  "a placement that fails after mining says the entity is in the inventory")
check(not pcall(move.action.validate, { from = { x = 0, y = 0 } }, 1)
  and not pcall(move.action.validate, { from = { x = 0, y = 0 }, to = { x = 1, y = 1 }, direction = 3.5 }, 1),
  "a move_entity step needs from, to and an integer direction")

check(move.action.make_task({ from={x=0,y=0}, to={x=4,y=0}, mode="robots" }).mode=="robots"
  and not pcall(move.action.validate,{from={x=0,y=0},to={x=4,y=0},mode="teleport"},1),
  "robot mode is explicit and unsupported move modes are refused")
local old_find=surface.find_entities_filtered
surface.find_entities_filtered=function(filter)
  check(filter.limit==17,"robot source selection has a fixed native result cap")
  local rows={};for i=1,17 do rows[i]={valid=true}end;return rows
end
local ok,why=pcall(move.start,move.action.make_task({from={x=0,y=0},to={x=4,y=0},mode="robots"}))
check(not ok and tostring(why):match("source selection exceeds 16"),"a crowded source fails before unbounded selection or robot ordering")
surface.find_entities_filtered=old_find

-- Enclosure escape: enclosed beside its own filtered inserter, the body takes
-- it up, walks out through the opening, and puts the same inserter back on
-- its spot with its direction and filters once it stands a tile clear.
local approach_mock = package.loaded["scripts.actions.approach"]
local function place_body(x, y)
  body.position = { x = x, y = y }
  body.bounding_box = { left_top = { x = x - 0.2, y = y - 0.2 }, right_bottom = { x = x + 0.2, y = y + 0.2 } }
end
-- Half a tile a tick straight toward the target (through the opening), as
-- approach.ensure does: "ok" once within the asked reach of it.
local walk_answer
approach_mock.ensure = function(_, c, target, reach)
  local dx, dy = target.x - c.position.x, target.y - c.position.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d <= reach then return "ok" end
  if walk_answer then return walk_answer end
  local step = math.min(0.5, d)
  place_body(c.position.x + dx / d * step, c.position.y + dy / d * step)
  return nil
end
-- Where the body stood when the escape put the inserter back.
local put_back_at
local plain_create = surface.create_entity
surface.create_entity = function(args)
  put_back_at = { x = body.position.x, y = body.position.y }
  return plain_create(args)
end
local function escape_run(extra)
  local task = { from = { x = 200.5, y = 0.5 }, to = { x = 200.5, y = 0.5 }, through = { x = 220.5, y = 0.5 },
    expected_name = "inserter", id = 9 }
  for k, v in pairs(extra or {}) do task[k] = v end
  move.start(task)
  local result
  for _ = 1, 80 do
    if extra and extra.during then extra.during(task) end
    result = move.tick(task)
    if result then return result, task end
  end
end
mines = {}
local gate = spawn("inserter", { x = 200.5, y = 0.5 }, 4, { use_filters = true })
gate.filters[1] = "iron-plate"
inventory.inserter = 0
place_body(199.5, 0.5)
local out = escape_run()
local back = surface.find_entity("inserter", { x = 200.5, y = 0.5 })
check(out and out.status == "done" and out.outcome.code == "ESCAPED" and not gate.valid and back and back.valid
  and back.direction == 4 and back.use_filters == true and back.filters[1] == "iron-plate" and inventory.inserter == 0,
  "an escape puts the same inserter back on its own spot with its direction and filters")
check(mines[1] and mines[1].target_kind == "owned" and mines[1].expected_name == "inserter"
  and body.position.x >= 202 and body.position.x < 203,
  "it is put back once the body has passed the opening and stands a tile clear, not at the walk's end")
check(out.detail == "stepped out through the inserter at (200.5, 0.5): took it up and put it back",
  "the escape's detail says what was taken up and put back")

-- The body is past the opening only a tile clear of the inserter's spot:
-- its footprint grown by a tile, plus the body's own box.
local function clear_of_gate(at)
  return at ~= nil and not geometry.overlaps({ left_top = { x = 200.5 - 1.35, y = 0.5 - 1.35 },
    right_bottom = { x = 200.5 + 1.35, y = 0.5 + 1.35 } },
    { left_top = { x = at.x - 0.2, y = at.y - 0.2 }, right_bottom = { x = at.x + 0.2, y = at.y + 0.2 } })
end

-- Enclosure escape at the reach edge: the step lies within the build distance of the opening
-- (build_plan used to pass its build_distance as the escape's reach) and
-- just past it. Coming within that reach, or reaching the step's spot, is
-- not stepping out: the body walks on past the gap, and only then is the
-- inserter put back, so the way behind it is closed and the body is out.
for _, case in ipairs({
  { through = { x = 210.8, y = 0.5 }, reach = body.build_distance, what = "the step lies within the build distance" },
  { through = { x = 201.5, y = 0.5 }, what = "the step lies just past the opening" },
  { through = { x = 201.5, y = 1.5 }, what = "the step lies diagonally past the opening" },
}) do
  -- Each case starts from the inserter standing in the opening.
  gate = surface.find_entity("inserter", { x = 200.5, y = 0.5 }) or spawn("inserter", { x = 200.5, y = 0.5 }, 4)
  inventory.inserter = 0
  place_body(199.5, 0.5)
  put_back_at = nil
  local result = escape_run({ through = case.through, reach = case.reach })
  check(result and result.status == "done" and result.outcome.code == "ESCAPED" and clear_of_gate(put_back_at)
    and surface.find_entity("inserter", { x = 200.5, y = 0.5 }) ~= nil and inventory.inserter == 0,
    "an escape puts the inserter back only once the body stands a tile clear past it when " .. case.what)
end

-- The walk out fails: the inserter goes back and the failure says so.
place_body(199.5, 0.5)
walk_answer = { status = "failed", detail = "couldn't get in range: BODY_ENCLOSED: still boxed in" }
local boxed = escape_run()
check(boxed and boxed.status == "failed" and boxed.outcome.code == "ESCAPE_FAILED"
  and boxed.detail:match("back in place — couldn't get in range: BODY_ENCLOSED")
  and surface.find_entity("inserter", { x = 200.5, y = 0.5 }) ~= nil,
  "a failed walk out still puts the entity back and reports it plainly")
walk_answer = nil

-- Something takes the spot while the body walks out: the inserter stays in
-- the inventory and the failure says so plainly.
place_body(199.5, 0.5)
local squatter
local lost = escape_run({ during = function(task)
  if not squatter and task._phase == "through" and body.position.x > 201 then
    squatter = spawn("wooden-chest", { x = 200.5, y = 0.5 })
  end
end })
check(lost and lost.status == "failed" and lost.outcome.code == "MOVE_PLACE_FAILED" and lost.outcome.in_inventory
  and lost.detail:match("inserter is in my inventory") and inventory.inserter == 1,
  "an entity that cannot go back stays in the inventory and the failure says so")
squatter.valid = false
inventory.inserter = 0

check(not pcall(move.start, { from = { x = 200.5, y = 0.5 }, to = { x = 200.5, y = 0.5 }, through = { x = 220.5, y = 0.5 },
  expected_name = "fast-inserter", id = 9 }), "an escape refuses an entity other than the named one")

-- The plan ends mid escape (a cancel, a stop, the plan's budget): the
-- cancelled hook puts the taken-up inserter back when the body can, with
-- its direction and filters; otherwise it names it in the inventory.
local function gate_at()
  return surface.find_entity("inserter", { x = 200.5, y = 0.5 })
end
local function fresh_gate()
  local standing = gate_at()
  if standing then standing.valid = false end
  local g = spawn("inserter", { x = 200.5, y = 0.5 }, 4, { use_filters = true })
  g.filters[1] = "iron-plate"
  inventory.inserter = 0
  place_body(199.5, 0.5)
  return g
end
local function escape_until(stop_when)
  local task = { from = { x = 200.5, y = 0.5 }, to = { x = 200.5, y = 0.5 }, through = { x = 220.5, y = 0.5 },
    expected_name = "inserter", id = 9 }
  move.start(task)
  for _ = 1, 80 do
    if move.tick(task) then return nil end
    if stop_when(task) then return task end
  end
end
fresh_gate()
local mid = escape_until(function(task) return task._phase == "through" and body.position.x >= 201.5 end)
local put = mid and move.cancelled(mid)
local again = gate_at()
check(put and put.code == "ESCAPE_CANCELLED" and put.put_back and not put.in_inventory and again and again.valid
  and again.direction == 4 and again.filters[1] == "iron-plate" and inventory.inserter == 0
  and put.detail == "the plan ended mid step-out: put the inserter back at (200.5, 0.5)",
  "a plan ended mid step-out puts the taken-up inserter back with its direction and filters, and says so")

fresh_gate()
local in_gap = escape_until(function(task) return task._phase == "through" and body.position.x >= 200.4 end)
local kept = in_gap and move.cancelled(in_gap)
check(kept and kept.code == "ESCAPE_CANCELLED" and kept.in_inventory and gate_at() == nil and inventory.inserter == 1
  and kept.detail:match("^the plan ended mid step%-out: the inserter taken up at %(200%.5, 0%.5%) is in my inventory")
  and kept.detail:match("its spot is not free %(CODEX_BODY_OVERLAP%)"),
  "a plan ended with the body in the opening names the inserter in the inventory and why it is not back")

fresh_gate()
local placing = escape_until(function(task) return task._phase == "place" end)
place_body(230.5, 0.5)
local far = placing and move.cancelled(placing)
check(far and far.in_inventory and inventory.inserter == 1 and far.detail:match("its spot is out of build reach"),
  "a plan ended with the body out of build reach of the spot names the inserter in the inventory")

-- The character finishes mining in the engine update after the step's last
-- tick: a cancel still in the "mine" phase finds the inserter taken up and
-- puts it back like one in the step-out.
local mining_gate = fresh_gate()
local mining = escape_until(function(task) return task._phase == "mine" and task._sub ~= nil end)
mining_gate.valid, inventory.inserter = false, 1
local gap_note = mining and move.cancelled(mining)
local back = gate_at()
check(gap_note and gap_note.code == "ESCAPE_CANCELLED" and gap_note.put_back and back and back.valid
  and back.direction == 4 and back.filters[1] == "iron-plate" and inventory.inserter == 0,
  "a cancel in the tick the mining finished puts the taken-up inserter back")

-- The stall watchdog's body-only cancel leaves a robot move's orders alone.
local unordered = 0
local robot_task = { mode = "robots", _robot_ordered = true, _robot_source = { valid = true, force = "player",
  cancel_deconstruction = function() unordered = unordered + 1 end } }
local robot_ok, robot_note = pcall(move.cancelled, robot_task, true)
check(robot_ok and robot_note == nil and unordered == 0 and robot_task._robot_ordered,
  "a body-only cancel of a robot move cancels no robot order")

-- Put back, but out of reach for its contents: still an escape, and the
-- result keeps the restore note.
fresh_gate()
approach_mock.ensure_entity = function() return { status = "failed", detail = "couldn't get in range: PATH_NOT_FOUND" } end
local unrestored = escape_run()
approach_mock.ensure_entity = function() return "ok" end
check(unrestored and unrestored.status == "done" and unrestored.outcome.code == "ESCAPED" and unrestored.outcome.not_restored
  and gate_at() ~= nil and unrestored.detail:match("took it up and put it back; its recipe, settings and items were not"
    .. " restored: couldn't get in range: PATH_NOT_FOUND"),
  "an escape whose restore is out of reach is still an escape and keeps the restore note")

-- Parallel belts beyond the opening: stepping out onto them, the put-back
-- would settle the body off the belt into the open gap and walk it clear of
-- the footprint inside. The escape walks on until the body is off the belts.
entities["transport-belt"] = proto("transport-belt", "transport-belt", 1, 1)
local function wall(position)
  return position.x > 199.6 and position.x < 201.4 and math.abs(position.y - 0.5) > 0.6 and math.abs(position.y - 0.5) < 6
end
surface.find_non_colliding_position = function(_, position) if not wall(position) then return position end end
supply.register_runner("walk_to", { start = function() end, tick = function(sub)
  place_body(sub.target.x, sub.target.y)
  return { status = "done", detail = "arrived" }
end })
-- Arrival in reach on a belt settles to the nearest clear off-belt tile, as the walk does.
approach_mock.ensure = function(_, c, target, reach)
  local dx, dy = target.x - c.position.x, target.y - c.position.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d <= reach then
    if not geometry.conveyor_under(c) then return "ok" end
    local tx, ty, best = math.floor(c.position.x), math.floor(c.position.y), nil
    for oy = -3, 3 do for ox = -3, 3 do
      local cell = { x = tx + ox + 0.5, y = ty + oy + 0.5 }
      local cell_box = { left_top = { x = cell.x - 0.2, y = cell.y - 0.2 }, right_bottom = { x = cell.x + 0.2, y = cell.y + 0.2 } }
      if #surface.find_entities_filtered({ area = cell_box }) == 0 then
        local dd = (cell.x - c.position.x) ^ 2 + (cell.y - c.position.y) ^ 2
        local bd = best and (best.x - c.position.x) ^ 2 + (best.y - c.position.y) ^ 2
        if not best or dd < bd or dd == bd and (cell.y < best.y or cell.y == best.y and cell.x < best.x) then best = cell end
      end
    end end
    place_body(best.x, best.y)
    return nil
  end
  local step = math.min(0.5, d)
  place_body(c.position.x + dx / d * step, c.position.y + dy / d * step)
  return nil
end
local belts = {}
for _, x in ipairs({ 201.5, 202.5, 203.5 }) do
  for y = -5, 5 do belts[#belts + 1] = spawn("transport-belt", { x = x, y = y + 0.5 }) end
end
fresh_gate()
local belted = escape_run()
check(belted and belted.status == "done" and belted.outcome.code == "ESCAPED" and gate_at() ~= nil
  and body.position.x > 201.85 and not geometry.conveyor_under(body),
  "an escape onto parallel belts walks on until the body is off them, then puts the inserter back with the body outside")
for _, b in ipairs(belts) do b.valid = false end

-- Never ESCAPED with the body back inside: here putting the inserter back
-- moves the body into the opening, and the walk clear of the footprint
-- ends inside.
fresh_gate()
local pushed = false
local inside_again = escape_run({ during = function(task)
  if task._phase == "place" and not pushed then pushed = true; place_body(200.5, 0.5) end
end })
check(pushed and inside_again and inside_again.status == "failed" and inside_again.outcome.code == "ESCAPE_FAILED"
  and inside_again.outcome.restored_in_place and gate_at() ~= nil and body.position.x < 200
  and inside_again.detail:match("putting it back moved the body into the opening"),
  "an escape whose put-back moved the body back through the opening is an ESCAPE_FAILED, not ESCAPED")
approach_mock.ensure = function() return "ok" end
place_body(0.5, 0.5)
print(failures == 0 and "\nALL MOVE_ENTITY TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
