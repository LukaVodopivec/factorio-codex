-- Offline tests for get_items / auto-supply (scripts/actions/supply.lua) and
-- footprint clearing (build.clear_footprint): where items come from, in what
-- order, and how a shortfall is named. Nested physical actions are stubs that
-- move items in a small simulated world.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.storage = {}
_G.game = { tick = 100 }
_G.defines = { inventory = { chest = 1 } }
_G.prototypes = { item = {
  ["iron-plate"] = { stack_size = 100 }, ["iron-gear-wheel"] = { stack_size = 100 },
  ["iron-ore"] = { stack_size = 50 }, coal = { stack_size = 50 }, wood = { stack_size = 100 },
  stone = { stack_size = 50 }, ["uranium-ore"] = { stack_size = 50 },
  ["transport-belt"] = { stack_size = 100, place_result = { name = "transport-belt" } },
  ["stone-furnace"] = { stack_size = 50, place_result = { name = "stone-furnace",
    collision_box = { left_top = { x = -0.9, y = -0.9 }, right_bottom = { x = 0.9, y = 0.9 } } } },
} }

local inventory = {}
local world = {}
local own_force, neutral = { name = "player" }, { name = "neutral" }
local recipes = {
  ["iron-gear-wheel"] = { name = "iron-gear-wheel", enabled = true, category = "crafting",
    ingredients = { { type = "item", name = "iron-plate", amount = 2 } },
    products = { { type = "item", name = "iron-gear-wheel", amount = 1 } } },
  ["iron-plate"] = { name = "iron-plate", enabled = true, category = "smelting",
    ingredients = { { type = "item", name = "iron-ore", amount = 1 } },
    products = { { type = "item", name = "iron-plate", amount = 1 } } },
}
local body
body = {
  valid = true, position = { x = 0, y = 0 }, force = own_force,
  prototype = { crafting_categories = { crafting = true } },
  get_item_count = function(name) return inventory[name] or 0 end,
  get_main_inventory = function() return { get_insertable_count = function() return 1000 end } end,
}
own_force.recipes = recipes
own_force.is_chunk_charted = function(_, chunk) return chunk.x < 4 end

local function holder(items)
  return { get_item_count = function(name) return items[name] or 0 end }
end
local function add(entity)
  entity.valid = true
  entity.force = entity.force or own_force
  entity.bounding_box = entity.bounding_box or { left_top = { x = entity.position.x - 0.5, y = entity.position.y - 0.5 },
    right_bottom = { x = entity.position.x + 0.5, y = entity.position.y + 0.5 } }
  world[#world + 1] = entity
  return entity
end
local function chest(position, items)
  local e = add({ type = "container", name = "wooden-chest", position = position, items = items })
  e.get_inventory = function() return holder(e.items) end
  return e
end
local function belt(position, items)
  local e = add({ type = "transport-belt", name = "transport-belt", position = position, items = items })
  e.get_transport_line = function(lane) return lane == 1 and holder(e.items) or holder({}) end
  return e
end
-- Natural entity prototypes, read through prototypes.get_entity_filtered.
local natural_protos = {
  ["iron-ore"] = { type = "resource", mineable_properties = { minable = true, products = { { name = "iron-ore", amount = 1 } } } },
  ["uranium-ore"] = { type = "resource", mineable_properties = { minable = true, required_fluid = "sulfuric-acid",
    products = { { name = "uranium-ore", amount = 1 } } } },
  ["huge-rock"] = { type = "simple-entity", mineable_properties = { minable = true,
    products = { { name = "stone", amount = 24 }, { name = "coal", amount = 24 } } } },
}
for _, name in ipairs({ "tree-01", "tree-02", "tree-03", "tree-04" }) do
  natural_protos[name] = { type = "tree", mineable_properties = { minable = true, products = { { name = "wood", amount = 4 } } } }
end
prototypes.get_entity_filtered = function(filters)
  local out = {}
  for name, proto in pairs(natural_protos) do
    for _, kind in ipairs(filters[1].type) do if proto.type == kind then out[name] = proto end end
  end
  return out
end
local function natural(kind, name, position, products)
  return add({ type = kind, name = name, position = position, force = neutral,
    prototype = { mineable_properties = { minable = true, products = products } } })
end

local function matches_type(filter, kind)
  if filter == nil then return true end
  if type(filter) == "string" then return filter == kind end
  for _, value in ipairs(filter) do if value == kind then return true end end
  return false
end
local queries = {}
body.surface = { find_entities_filtered = function(args)
  queries[#queries + 1] = args
  assert(not (args.area and not args.radius and args.force), "no area scan on a force query")
  local out = {}
  for _, e in ipairs(world) do
    local ok = e.valid and matches_type(args.type, e.type) and (args.name == nil or matches_type(args.name, e.name))
      and (args.force == nil or args.force == e.force)
    if ok and args.position then
      local dx, dy = e.position.x - args.position.x, e.position.y - args.position.y
      ok = dx * dx + dy * dy <= args.radius * args.radius
    end
    if ok and args.area then
      local a, p = args.area, e.position
      ok = p.x >= a.left_top.x - 0.5 and p.x <= a.right_bottom.x + 0.5 and p.y >= a.left_top.y - 0.5 and p.y <= a.right_bottom.y + 0.5
    end
    if ok then out[#out + 1] = e end
    if args.limit and #out >= args.limit then break end
  end
  return out
end }

package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
-- The registry (registry_test) lists own chests and machine outputs in
-- charted chunks, and own drills; belts are never listed.
local HOLDER_TYPES = { container = true, furnace = true, ["assembling-machine"] = true }
local function own_entries(keep)
  local rows = {}
  for _, e in ipairs(world) do
    if e.valid and e.force == own_force and keep(e)
      and own_force.is_chunk_charted(nil, { x = math.floor(e.position.x / 32), y = math.floor(e.position.y / 32) }) then
      rows[#rows + 1] = { entity = e, type = e.type, position = e.position }
    end
  end
  return rows
end
local registry_reads = 0
package.loaded["scripts.registry"] = {
  list = function(set)
    assert(set == "holders", "supply reads the registry's holders")
    registry_reads = registry_reads + 1
    return own_entries(function(e) return HOLDER_TYPES[e.type] end)
  end,
  machines = function(types)
    assert(types[1] == "mining-drill", "supply reads the registry's drills")
    registry_reads = registry_reads + 1
    return own_entries(function(e) return e.type == "mining-drill" end)
  end,
}

local function at(position)
  for _, e in ipairs(world) do
    if e.valid and e.position.x == position.x and e.position.y == position.y then return e end
  end
end
local calls = {}
local function stub(kind, effect)
  return { start = function(task) calls[#calls + 1] = { kind = kind, task = task } end, tick = effect }
end
local function move(source, name, want)
  local n = math.min(want, source.items[name] or 0)
  source.items[name] = (source.items[name] or 0) - n
  inventory[name] = (inventory[name] or 0) + n
  body.position = { x = source.position.x, y = source.position.y }
  return n
end
package.loaded["scripts.actions.walk"] = stub("walk_to", function(task)
  body.position = { x = task.target.x, y = task.target.y }
  return { status = "done", detail = "arrived" }
end)
package.loaded["scripts.actions.pickup"] = stub("pickup", function(task)
  local n = move(at(task.target), task.item, task.count)
  return { status = n > 0 and "done" or "failed", detail = "picked " .. n }
end)
package.loaded["scripts.actions.craft"] = stub("craft", function(task)
  local recipe = recipes[task.recipe]
  for _, ingredient in ipairs(recipe.ingredients) do
    if (inventory[ingredient.name] or 0) < ingredient.amount * task.count then
      return { status = "failed", detail = "missing " .. ingredient.name }
    end
  end
  for _, ingredient in ipairs(recipe.ingredients) do
    inventory[ingredient.name] = inventory[ingredient.name] - ingredient.amount * task.count
  end
  inventory[task.recipe] = (inventory[task.recipe] or 0) + task.count
  return { status = "done", detail = "crafted" }
end)
package.loaded["scripts.actions.mine"] = stub("mine", function(task)
  local e = task.entity
  local product = e.prototype.mineable_properties.products[1]
  inventory[product.name] = (inventory[product.name] or 0) + (e.type == "resource" and task.count or product.amount)
  if e.type ~= "resource" then e.valid = false end
  return { status = "done", detail = "mined" }
end)

local supply = require("scripts.actions.supply")
supply.register_runner("extract", stub("extract", function(task)
  local source = at(task.target)
  local transfers = {}
  for name, count in pairs(task.items) do transfers[#transfers + 1] = { item = name, extracted = move(source, name, count) } end
  return { status = "done", detail = "took", outcome = { transfers = transfers, target = { name = source.name, type = source.type, position = source.position } } }
end))

local function run(task)
  supply.start(task)
  for _ = 1, 200 do
    local result = supply.tick(task)
    if result then return result end
  end
  error("supply did not finish")
end
local function reset()
  inventory, world, calls, queries = {}, {}, {}, {}
  body.position = { x = 0, y = 0 }
end

-- Already carried: nothing moves.
inventory["iron-plate"] = 10
local carried = run({ items = { { name = "iron-plate", count = 5 } } })
check(carried.status == "done" and #calls == 0 and carried.detail:match("already carried"),
  "get_items with enough carried does nothing physical")

-- Nearest chest first; a belt only when no chest or machine holds the item.
reset()
local far_chest = chest({ x = 20.5, y = 0.5 }, { ["iron-plate"] = 50 })
local near_chest = chest({ x = 5.5, y = 0.5 }, { ["iron-plate"] = 3 })
belt({ x = 1.5, y = 0.5 }, { ["iron-plate"] = 8 })
chest({ x = 200.5, y = 0.5 }, { ["iron-plate"] = 500 }) -- in uncharted land
local taken = run({ items = { { name = "iron-plate", count = 10 } } })
check(taken.status == "done" and inventory["iron-plate"] == 10 and calls[1].kind == "extract"
  and calls[1].task.target.x == 5.5 and calls[2].kind == "extract" and calls[2].task.target.x == 20.5
  and calls[2].task.items["iron-plate"] == 7 and near_chest.items["iron-plate"] == 0 and far_chest.items["iron-plate"] == 43,
  "get_items takes from the nearest charted chest, then the next, before any belt")
check(taken.outcome.code == "SUPPLIED" and taken.outcome.supplied.taken["iron-plate"] == 10
  and taken.detail:match("taken 10 iron%-plate"), "the result says where the items came from")
local bounded = true
for _, query in ipairs(queries) do
  if query.force and not (query.type == "transport-belt" and query.position and query.radius and query.radius <= 64) then
    bounded = false
  end
end
check(bounded, "chests and machines come from the registry; only belts are searched, near the body")

reset()
belt({ x = 3.5, y = 0.5 }, { coal = 6 })
local from_belt = run({ items = { { name = "coal", count = 4 } } })
check(from_belt.status == "done" and calls[1].kind == "pickup" and calls[1].task.count == 4 and inventory.coal == 4,
  "with no chest holding it, get_items picks the item up from an own belt")

-- An insert never takes from its own target.
reset()
chest({ x = 2.5, y = 0.5 }, { coal = 20 })
local other = chest({ x = 9.5, y = 0.5 }, { coal = 20 })
local excluded = run({ items = { { name = "coal", count = 5 } }, exclude = { x = 2.5, y = 0.5 } })
check(excluded.status == "done" and calls[1].task.target.x == 9.5 and other.items.coal == 15,
  "auto-supply for an insert never takes from the insert's target")

-- Placeable items come by the stack, so a plan fetches them once.
reset()
chest({ x = 2.5, y = 0.5 }, { ["transport-belt"] = 150 })
local bulk = run({ items = { { name = "transport-belt", count = 1 } }, bulk = true })
check(bulk.status == "done" and inventory["transport-belt"] == 100, "bulk auto-supply takes up to a stack of a placeable item")

-- Crafting supplies its ingredients the same way (intermediates follow).
reset()
chest({ x = 4.5, y = 0.5 }, { ["iron-plate"] = 50 })
local gears = run({ items = { { name = "iron-gear-wheel", count = 5 } } })
check(gears.status == "done" and inventory["iron-gear-wheel"] == 5 and inventory["iron-plate"] == 0
  and calls[1].kind == "extract" and calls[1].task.items["iron-plate"] == 10
  and calls[2].kind == "craft" and calls[2].task.count == 5 and gears.outcome.supplied.crafted["iron-gear-wheel"] == 5,
  "get_items crafts an item after fetching exactly its ingredients")

-- Hand-gathering only when no own drill produces the resource.
reset()
local ore = natural("resource", "iron-ore", { x = 6.5, y = 0.5 }, { { name = "iron-ore", amount = 1 } })
local gathered = run({ items = { { name = "iron-ore", count = 7 } } })
check(gathered.status == "done" and calls[1].kind == "mine" and calls[1].task.entity == ore and calls[1].task.count == 7
  and inventory["iron-ore"] == 7 and gathered.outcome.supplied.gathered["iron-ore"] == 7,
  "get_items hand-mines a resource no own drill produces")
reset()
natural("resource", "iron-ore", { x = 6.5, y = 0.5 }, { { name = "iron-ore", amount = 1 } })
local mined_by_drill = add({ type = "resource", name = "iron-ore", position = { x = 30.5, y = 0.5 }, force = neutral,
  prototype = { mineable_properties = { minable = true, products = { { name = "iron-ore", amount = 1 } } } } })
add({ type = "mining-drill", name = "burner-mining-drill", position = { x = 30, y = 0 }, mining_target = mined_by_drill })
local drill_short = run({ items = { { name = "iron-ore", count = 7 } } })
check(drill_short.status == "failed" and #calls == 0 and drill_short.outcome.code == "SUPPLY_SHORTFALL"
  and drill_short.outcome.missing[1].item == "iron-ore" and drill_short.outcome.missing[1].missing == 7
  and drill_short.detail:match("own mining drill"),
  "a resource own drills produce is never hand-mined; the shortfall says the drills make it")

reset()
local tree = natural("tree", "tree-01", { x = 3.5, y = 3.5 }, { { name = "wood", amount = 4 } })
local second_tree = natural("tree", "tree-04", { x = 9.5, y = 3.5 }, { { name = "wood", amount = 4 } })
local wood = run({ items = { { name = "wood", count = 6 } } })
check(wood.status == "done" and inventory.wood == 8 and calls[1].task.entity == tree
  and calls[2].task.entity == second_tree and calls[2].task.count == 1 and #calls == 2,
  "wood is gathered tree by tree")

-- A forest never means a large read: gathering asks the engine only for the
-- names that yield the item, a bounded number at a time; an item nothing
-- natural yields makes no natural query at all.
reset()
for i = 1, 3000 do natural("tree", "tree-0" .. (1 + i % 4), { x = 2.5 + i % 60, y = 2.5 + math.floor(i / 60) },
  { { name = "wood", amount = 4 } }) end
local function natural_reads()
  local reads = { queries = 0, typed = 0 }
  for _, q in ipairs(queries) do
    if q.position and type(q.name) == "table" then
      reads.queries = reads.queries + 1
      if q.type ~= nil or not q.limit or q.limit > 100 then reads.typed = reads.typed + 1 end
    end
  end
  return reads
end
local no_plate = run({ items = { { name = "iron-plate", count = 5 } } })
check(no_plate.status == "failed" and natural_reads().queries == 0,
  "an item nothing natural yields (iron plate) makes no natural query in a forest")
queries = {}
local no_stone = run({ items = { { name = "stone", count = 5 } } })
local tree_named = false
for _, q in ipairs(queries) do
  for _, name in ipairs(type(q.name) == "table" and q.name or {}) do if name:match("^tree") then tree_named = true end end
end
check(no_stone.status == "failed" and natural_reads().queries > 0 and not tree_named and no_stone.detail:match("none within 64 tiles"),
  "stone with only trees around asks only for rocks, never reads the trees")
queries = {}
local forest_wood = run({ items = { { name = "wood", count = 4 } } })
local reads = natural_reads()
check(forest_wood.status == "done" and reads.queries >= 1 and reads.typed == 0,
  "wood in a forest reads trees by name, at most 100 per query")
reset()
natural("resource", "uranium-ore", { x = 4.5, y = 0.5 }, { { name = "uranium-ore", amount = 1 } })
local acid = run({ items = { { name = "uranium-ore", count = 1 } } })
check(acid.status == "failed" and #calls == 0 and natural_reads().queries == 0,
  "a resource that needs a fluid to mine is never hand-gathered")

-- One source scan per tick: a nested craft chain with nothing stored spreads
-- its registry, belt, drill and natural searches over ticks.
reset()
recipes["electronic-circuit"] = { name = "electronic-circuit", enabled = true, category = "crafting",
  ingredients = { { type = "item", name = "iron-plate", amount = 1 }, { type = "item", name = "copper-cable", amount = 3 } },
  products = { { type = "item", name = "electronic-circuit", amount = 1 } } }
recipes["copper-cable"] = { name = "copper-cable", enabled = true, category = "crafting",
  ingredients = { { type = "item", name = "copper-plate", amount = 1 } },
  products = { { type = "item", name = "copper-cable", amount = 2 } } }
prototypes.item["electronic-circuit"] = { stack_size = 200 }
prototypes.item["copper-cable"] = { stack_size = 200 }
prototypes.item["copper-plate"] = { stack_size = 100 }
natural("resource", "iron-ore", { x = 6.5, y = 0.5 }, { { name = "iron-ore", amount = 1 } })
local chain = { items = { { name = "electronic-circuit", count = 2 } } }
supply.start(chain)
local most_scans, natural_with_other, ticks = 0, false, 0
for _ = 1, 200 do
  local reads_before, queries_before = registry_reads, #queries
  local result = supply.tick(chain)
  ticks = ticks + 1
  local belt_queries, natural_queries = 0, 0
  for index = queries_before + 1, #queries do
    if queries[index].type == "transport-belt" then belt_queries = belt_queries + 1
    elseif type(queries[index].name) == "table" then natural_queries = natural_queries + 1 end
  end
  local scans = registry_reads - reads_before + belt_queries
  most_scans = math.max(most_scans, scans + (natural_queries > 0 and 1 or 0))
  if natural_queries > 0 and scans > 0 then natural_with_other = true end
  if result then break end
end
check(most_scans == 1 and not natural_with_other and ticks > 4,
  "a circuit -> plate/cable -> copper chain runs at most one registry, belt, drill or natural scan per tick (" .. ticks .. " ticks)")
recipes["electronic-circuit"], recipes["copper-cable"] = nil, nil

-- A take never asks for more than the inventory has room for.
reset()
local room = 30
body.get_main_inventory = function() return { get_insertable_count = function() return room end } end
chest({ x = 2.5, y = 0.5 }, { ["iron-plate"] = 100 })
run({ items = { { name = "iron-plate", count = 100 } } })
check(calls[1].kind == "extract" and calls[1].task.items["iron-plate"] == 30,
  "a take asks only for what fits in the inventory")
reset()
room = 0
chest({ x = 2.5, y = 0.5 }, { ["iron-plate"] = 100 })
local full = run({ items = { { name = "iron-plate", count = 10 } } })
check(#calls == 0 and full.status == "failed" and full.detail:match("my inventory is full"),
  "with a full inventory no source is visited and the shortfall says why")
body.get_main_inventory = function() return { get_insertable_count = function() return 1000 end } end

-- Smelted items are not hand-craftable: the shortfall names why.
reset()
chest({ x = 2.5, y = 0.5 }, { ["iron-plate"] = 2 })
local short = run({ items = { { name = "iron-plate", count = 5 } } })
check(short.status == "partial" and inventory["iron-plate"] == 2 and short.outcome.missing[1].missing == 3
  and short.detail:match("cannot be hand%-crafted %(smelting%)"),
  "a partial supply is partial and names the missing count and why")

-- Plan step validation.
check(not pcall(supply.action.validate, { item = "coal", count = 0 }, 1)
  and not pcall(supply.action.validate, { count = 3 }, 1) and pcall(supply.action.validate, { item = "coal", count = 3 }, 1),
  "get_items steps need an item and a positive integer count")
check(supply.action.make_task({ item = "coal", count = 3 }).items[1].count == 3, "a get_items step becomes a supply task")

-- Auto-clear: trees and rocks in a footprint are mined before placement.
reset()
local build = require("scripts.actions.build")
local blocking_tree = natural("tree", "tree-02", { x = 10.5, y = 10.5 }, { { name = "wood", amount = 4 } })
local far_tree = natural("tree", "tree-03", { x = 14.5, y = 10.5 }, { { name = "wood", amount = 4 } })
local place = { id = 7, item = "stone-furnace", position = { x = 11, y = 11 } }
local proto = prototypes.item["stone-furnace"].place_result
check(build.clear_footprint(place, body, proto, place.position, 0) == nil and place._clear.entity == blocking_tree
  and place._clear.id == 7, "a tree in the footprint is mined first, by the owning task")
check(build.clear_footprint(place, body, proto, place.position, 0) == "ok" and not blocking_tree.valid and far_tree.valid
  and inventory.wood == 4, "once the footprint is clear, placement goes on; trees outside it stay")
local kept = { id = 8, item = "stone-furnace", position = { x = 14, y = 11 }, auto_clear = false }
check(build.clear_footprint(kept, body, proto, kept.position, 0) == "ok" and far_tree.valid, "auto_clear=false leaves trees")

-- Embedded auto-supply runs once and reports.
reset()
local owner = { id = 9 }
local embedded
for _ = 1, 20 do
  embedded = supply.ensure(owner, { { name = "iron-plate", count = 1 } })
  if embedded then break end
end
check(embedded and embedded.status == "failed" and owner._supply == nil,
  "embedded supply reports a shortfall and clears itself")

-- insert_items auto-supply: the missing coal comes from a chest, then goes in.
reset()
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end,
  ensure_entity = function() return "ok" end, find_entity_near = function(_, position) return at(position) end }
local transfer = require("scripts.actions.transfer")
supply.register_runner("extract", stub("extract", function(task)
  local source = at(task.target)
  for name, count in pairs(task.items) do move(source, name, count) end
  return { status = "done", detail = "took" }
end))
body.remove_item = function(stack) inventory[stack.name] = inventory[stack.name] - stack.count end
local fed = 0
local furnace = add({ type = "furnace", name = "stone-furnace", position = { x = 2.5, y = 0.5 }, items = { coal = 30 } })
furnace.get_output_inventory = function() return holder({}) end
furnace.insert = function(stack) fed = fed + stack.count; return stack.count end
chest({ x = 6.5, y = 0.5 }, { coal = 20 })
inventory.coal = 2
local refuel = { id = 11, target = { x = 2.5, y = 0.5 }, items = { coal = 5 } }
transfer.insert.start(refuel)
local inserted
for _ = 1, 10 do inserted = transfer.insert.tick(refuel); if inserted then break end end
check(inserted and inserted.status == "done" and fed == 5 and inventory.coal == 0 and calls[1].kind == "extract"
  and calls[1].task.target.x == 6.5 and calls[1].task.items.coal == 3,
  "insert fetches only the missing coal from an own chest, never from its target, then inserts")
local empty = { id = 12, target = { x = 2.5, y = 0.5 }, items = { coal = 50 } }
world[#world].items.coal = 0
transfer.insert.start(empty)
local zero
for _ = 1, 10 do zero = transfer.insert.tick(empty); if zero then break end end
check(zero and zero.status == "failed" and zero.detail:match("SUPPLY_SHORTFALL"), "an insert with nothing to fetch names the shortfall")

os.exit(failures == 0 and 0 or 1)
