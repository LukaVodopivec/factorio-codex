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

_G.storage = {}
_G.game = { tick = 100 }
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
local world, inventory = {}, {}
local function live()
  local out = {}
  for _, e in ipairs(world) do if e.valid then out[#out + 1] = e end end
  return out
end
local function slots(contents)
  local held = contents or {}
  return {
    get_contents = function()
      local rows = {}
      for name, count in pairs(held) do if count > 0 then rows[#rows + 1] = { name = name, count = count, quality = "normal" } end end
      table.sort(rows, function(a, b) return a.name < b.name end)
      return rows
    end,
    insert = function(stack)
      held[stack.name] = (held[stack.name] or 0) + stack.count
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
    for _, e in ipairs(live()) do if geometry.overlaps(area, e.bounding_box) then return false end end
    return true
  end,
  count_tiles_filtered = function(filter)
    assert(filter.area and filter.collision_mask and filter.limit, "a bounded tile count by collision mask")
    return math.min(wet_tiles(filter.area), filter.limit)
  end,
  find_entities_filtered = function(filter)
    assert(filter.area or filter.position, "no entity query may search the whole surface")
    local out = {}
    for _, e in ipairs(live()) do
      local hit = filter.area and geometry.overlaps(filter.area, e.bounding_box)
        or filter.position and geometry.overlaps({ left_top = filter.position, right_bottom = filter.position }, e.bounding_box)
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
  get_main_inventory = function() return { get_insertable_count = function() return 1000 end } end,
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
print(failures == 0 and "\nALL MOVE_ENTITY TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
