-- Offline tests for get_items / auto-supply (scripts/actions/supply.lua) and
-- footprint clearing (build.clear_footprint): where items come from, in what
-- order, and how a shortfall is named. Nested physical actions are stubs that
-- move items in a small simulated world.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.storage = {}
_G.game = { tick = 100 }
_G.defines = { inventory = { chest = 1, furnace_source = 2, furnace_result = 3 } }
_G.prototypes = { item = {
  ["iron-plate"] = { stack_size = 100 }, ["iron-gear-wheel"] = { stack_size = 100 },
  ["iron-ore"] = { stack_size = 50 }, coal = { stack_size = 50 }, wood = { stack_size = 100 },
  stone = { stack_size = 50 }, ["uranium-ore"] = { stack_size = 50 },
  ["transport-belt"] = { stack_size = 100, place_result = { name = "transport-belt" } },
  ["stone-furnace"] = { stack_size = 50, place_result = { name = "stone-furnace",
    collision_box = { left_top = { x = -0.9, y = -0.9 }, right_bottom = { x = 0.9, y = 0.9 } } } },
} }

-- The engine's recipe filter: which recipes make an item (supply caches it),
-- as a LuaCustomTable, which is userdata like the engine's. Quality's hidden
-- recycling recipe also makes iron-plate and sorts before the smelting one.
prototypes.get_recipe_filtered = function(filters)
  local wanted = filters[1].elem_filters[1].name
  return mock.custom_table(wanted == "iron-plate"
    and { ["iron-chest-recycling"] = {}, ["iron-plate"] = {} } or {})
end

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
  ["iron-chest-recycling"] = { name = "iron-chest-recycling", enabled = true, hidden = true,
    category = "recycling", ingredients = { { type = "item", name = "iron-chest", amount = 1 } },
    products = { { type = "item", name = "iron-plate", amount = 2 } } },
}
local body
body = {
  valid = true, position = { x = 0, y = 0 }, force = own_force,
  prototype = { crafting_categories = { crafting = true } },
  get_item_count = function(name) return inventory[type(name) == "table" and name.name or name] or 0 end,
  get_main_inventory = function() return { get_insertable_count = function() return 1000 end } end,
}
own_force.recipes = recipes
own_force.is_chunk_charted = function(_, chunk) return chunk.x < 4 end

local function holder(items)
  return { get_item_count = function(name) return items[type(name) == "table" and name.name or name] or 0 end }
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
  return mock.custom_table(out)
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
    if ok and args.position and args.radius then
      local dx, dy = e.position.x - args.position.x, e.position.y - args.position.y
      ok = dx * dx + dy * dy <= args.radius * args.radius
    elseif ok and args.position then
      -- A point query: the entities whose box contains the point.
      local box, p = e.bounding_box, args.position
      ok = p.x >= box.left_top.x and p.x <= box.right_bottom.x and p.y >= box.left_top.y and p.y <= box.right_bottom.y
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
-- The registry (registry_test) lists own chests, landing pads and machine
-- outputs in charted chunks, and own drills; belts are never listed.
local HOLDER_TYPES = { container = true, ["cargo-landing-pad"] = true, furnace = true, ["assembling-machine"] = true }
local STORES = { container = true, ["cargo-landing-pad"] = true }
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
local holder_rows_read = 0
package.loaded["scripts.registry"] = {
  -- The registry's last read of each holder is its live content here.
  holders_with = function(item, position, cap, skip)
    registry_reads = registry_reads + 1
    local rows = {}
    for _, row in ipairs(own_entries(function(e) return HOLDER_TYPES[e.type] and (e.items[item] or 0) > 0 end)) do
      if not skip(row) then rows[#rows + 1] = row end
    end
    table.sort(rows, function(a, b)
      local da = (a.position.x - position.x) ^ 2 + (a.position.y - position.y) ^ 2
      local db = (b.position.x - position.x) ^ 2 + (b.position.y - position.y) ^ 2
      return da < db
    end)
    while #rows > cap do table.remove(rows) end
    holder_rows_read = holder_rows_read + #rows
    return rows
  end,
  machines = function(types)
    assert(#types == 1 and (types[1] == "mining-drill" or types[1] == "furnace"), "supply reads drills or furnaces")
    registry_reads = registry_reads + 1
    return own_entries(function(e) return e.type == types[1] end)
  end,
  holder_inventory = function(e) return STORES[e.type] and e.get_inventory() or e.get_output_inventory() end,
  holder_kind = function(e)
    return e.type == "cargo-landing-pad" and "landing_pad" or e.type == "container" and "chest" or "machine_output"
  end,
  stock_totals = function(names)
    local totals = {}
    for _, name in ipairs(names) do
      totals[name] = 0
      for _, row in ipairs(own_entries(function(e) return HOLDER_TYPES[e.type] end)) do
        totals[name] = totals[name] + (row.entity.items[name] or 0)
      end
    end
    return totals
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
-- Crafts finish at once here unless a test puts output in the queue.
local crafting = {}
local craft_stub
craft_stub = stub("craft", function(task)
  local recipe = recipes[task.recipe]
  for _, ingredient in ipairs(recipe.ingredients) do
    if (inventory[ingredient.name] or 0) < ingredient.amount * task.count then
      return { status = "failed", detail = "missing " .. ingredient.name }
    end
  end
  for _, ingredient in ipairs(recipe.ingredients) do
    inventory[ingredient.name] = inventory[ingredient.name] - ingredient.amount * task.count
  end
  for _, product in ipairs(recipe.products) do
    inventory[product.name] = (inventory[product.name] or 0) + product.amount * task.count
  end
  return { status = "done", detail = "crafted" }
end)
craft_stub.queued = function(_, name) return crafting[name] or 0 end
craft_stub.awaits = function(_, name, count) return (inventory[name] or 0) < count and (crafting[name] or 0) > 0 end
package.loaded["scripts.actions.craft"] = craft_stub
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
  and taken.detail == "carrying 10 iron-plate",
  "the outcome says where the items came from; the text says only what is carried (any item may be used anywhere)")
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

-- Runs a supply task to its end and counts the ticks that read belts and
-- the most belt queries in one tick (each must stay a bounded query).
local function run_belts(task)
  local belt_ticks, most = 0, 0
  supply.start(task)
  for _ = 1, 400 do
    local queries_before = #queries
    local result = supply.tick(task)
    local in_tick = 0
    for index = queries_before + 1, #queries do
      local query = queries[index]
      if query.type == "transport-belt" then
        in_tick = in_tick + 1
        if not (query.limit <= 64 and query.radius <= 48) then in_tick = 99 end
      end
    end
    if in_tick > 0 then belt_ticks = belt_ticks + 1 end
    most = math.max(most, in_tick)
    if result then return result, belt_ticks, most end
  end
  error("supply did not finish")
end

-- More belts near the body than one query reads (the engine returns them in
-- chunk order up to the limit, like this mock's insertion order): the search
-- goes on cell by cell, nearest first, a few bounded queries per tick.
reset()
for x = -5, 4 do for y = -5, 4 do belt({ x = x + 0.5, y = y + 0.5 }, {}) end end
belt({ x = 20.5, y = 0.5 }, { coal = 6 })
local dense, _, dense_most = run_belts({ items = { { name = "coal", count = 4 } } })
check(dense.status == "done" and calls[1].kind == "pickup" and calls[1].task.target.x == 20.5 and inventory.coal == 4,
  "with more belts near the body than one query reads, get_items still finds the belt that holds the item")
check(dense_most <= 4, "the belt search runs at most four bounded belt queries per tick")

-- Every cell read in full: no belt within reach holds it, and reading every
-- cell takes a few ticks, not one per cell.
reset()
for x = -5, 4 do for y = -5, 4 do belt({ x = x + 0.5, y = y + 0.5 }, {}) end end
local read_all, read_all_ticks = run_belts({ items = { { name = "coal", count = 4 } } })
check(read_all.status == "failed" and read_all.detail:match("or belt holds it"),
  "a belt search that read every belt near the body says no belt holds the item")
check(read_all_ticks <= 10, "a belt search that finds nothing in a dense area takes a few ticks, not one per cell")

-- One 16-tile cell holds more belts than one query reads (a bus), and the
-- holding belt comes last in chunk order: the cell is split until it is read.
reset()
for x = 16, 31 do for y = 0, 15 do
  if not (x == 28 and y == 12) then belt({ x = x + 0.5, y = y + 0.5 }, {}) end
end end
belt({ x = 28.5, y = 12.5 }, { coal = 6 })
local bus, _, bus_most = run_belts({ items = { { name = "coal", count = 4 } } })
check(bus.status == "done" and calls[1].kind == "pickup" and calls[1].task.target.x == 28.5 and inventory.coal == 4,
  "a cell holding more belts than one query reads is split until the belt that holds the item is read")
check(bus_most <= 4, "splitting dense cells keeps at most four bounded belt queries per tick")

-- The same bus with no holding belt: every belt is read, so the reason may
-- say no belt holds it.
reset()
for x = 16, 31 do for y = 0, 15 do belt({ x = x + 0.5, y = y + 0.5 }, {}) end end
local bus_empty = run_belts({ items = { { name = "coal", count = 4 } } })
check(bus_empty.status == "failed" and bus_empty.detail:match("or belt holds it"),
  "a belt search that split every dense cell says no belt holds the item")

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

-- Space science dropped onto the landing pad is a store like a chest: taken
-- from the pad's main inventory.
reset()
local pad = add({ type = "cargo-landing-pad", name = "cargo-landing-pad", position = { x = 6, y = 6 },
  items = { ["iron-plate"] = 40 } })
pad.get_inventory = function() return holder(pad.items) end
local from_pad = run({ items = { { name = "iron-plate", count = 30 } } })
check(from_pad.status == "done" and calls[1].kind == "extract" and calls[1].task.target.x == 6
  and calls[1].task.inventory == "main" and pad.items["iron-plate"] == 10 and inventory["iron-plate"] == 30,
  "get_items takes from a cargo landing pad's main inventory")

-- Crafting supplies its ingredients the same way (intermediates follow).
reset()
chest({ x = 4.5, y = 0.5 }, { ["iron-plate"] = 50 })
local gears = run({ items = { { name = "iron-gear-wheel", count = 5 } } })
check(gears.status == "done" and inventory["iron-gear-wheel"] == 5 and inventory["iron-plate"] == 0
  and calls[1].kind == "extract" and calls[1].task.items["iron-plate"] == 10
  and calls[2].kind == "craft" and calls[2].task.count == 5 and gears.outcome.supplied.crafted["iron-gear-wheel"] == 5,
  "get_items crafts an item after fetching exactly its ingredients")

-- Hand-gathering a raw resource.
reset()
local ore = natural("resource", "iron-ore", { x = 6.5, y = 0.5 }, { { name = "iron-ore", amount = 1 } })
local gathered = run({ items = { { name = "iron-ore", count = 7 } } })
check(gathered.status == "done" and calls[1].kind == "mine" and calls[1].task.entity == ore and calls[1].task.count == 7
  and inventory["iron-ore"] == 7 and gathered.outcome.supplied.gathered["iron-ore"] == 7,
  "get_items hand-mines a resource no own drill produces")
-- The only drill feeds its furnace: none of its ore can be taken, so the
-- body hand-gathers ore the drill and furnace do not stand on.
local function box(x1, y1, x2, y2) return { left_top = { x = x1, y = y1 }, right_bottom = { x = x2, y = y2 } } end
local function drill_on_ore(drop_target, drop_position)
  local under = natural("resource", "iron-ore", { x = 30.5, y = 0.5 }, { { name = "iron-ore", amount = 1 } })
  return add({ type = "mining-drill", name = "burner-mining-drill", position = { x = 30, y = 0 },
    bounding_box = box(29, -1, 31, 1), mining_target = under, drop_target = drop_target, drop_position = drop_position })
end
reset()
local fed = add({ type = "furnace", name = "stone-furnace", position = { x = 31, y = -2 }, items = {},
  bounding_box = box(30, -3, 32, -1) })
fed.get_output_inventory = function() return holder(fed.items) end
natural("resource", "iron-ore", { x = 30.5, y = -1.5 }, { { name = "iron-ore", amount = 1 } }) -- under the furnace
local free_ore = natural("resource", "iron-ore", { x = 27.5, y = 0.5 }, { { name = "iron-ore", amount = 1 } })
drill_on_ore(fed, { x = 30.5, y = -1.3 })
body.position = { x = 31, y = 2 }
local drill_gathered = run({ items = { { name = "iron-ore", count = 7 } } })
check(drill_gathered.status == "done" and #calls == 1 and calls[1].kind == "mine" and calls[1].task.entity == free_ore
  and calls[1].task.count == 7 and inventory["iron-ore"] == 7 and drill_gathered.outcome.supplied.gathered["iron-ore"] == 7,
  "ore an own drill mines into its furnace is hand-gathered from a tile no own building covers")

-- More covered ore tiles than one tick checks lie nearer than a free one:
-- the search resumes next tick, never hands back an unchecked tile, and
-- checks each tile once.
reset()
add({ type = "lab", name = "lab", position = { x = 4.5, y = 2 }, bounding_box = box(2, 0, 7, 4) })
for x = 2.5, 6.5 do for y = 0.5, 3.5 do natural("resource", "iron-ore", { x = x, y = y }, { { name = "iron-ore", amount = 1 } }) end end
local far_free = natural("resource", "iron-ore", { x = 10.5, y = 0.5 }, { { name = "iron-ore", amount = 1 } })
local wide_gathered = run({ items = { { name = "iron-ore", count = 7 } } })
local point_checks = 0
for _, q in ipairs(queries) do if q.force and q.position and not q.radius then point_checks = point_checks + 1 end end
check(wide_gathered.status == "done" and #calls == 1 and calls[1].kind == "mine" and calls[1].task.entity == far_free
  and inventory["iron-ore"] == 7 and point_checks == 21,
  "more than one tick's worth of covered ore is passed over across ticks before free ore is hand-gathered")

-- With no uncovered ore in reach the shortfall names the drill.
reset()
drill_on_ore(nil, nil)
body.position = { x = 31, y = 2 }
local drill_short = run({ items = { { name = "iron-ore", count = 7 } } })
check(drill_short.status == "failed" and #calls == 0 and drill_short.outcome.code == "SUPPLY_SHORTFALL"
  and drill_short.outcome.missing[1].missing == 7
  and drill_short.detail:match("1 own mining drill%(s%) produce it but none of their output can be taken now")
  and drill_short.detail:match("none within 64 tiles to hand%-gather"),
  "ore only under an own drill is never hand-mined; the shortfall names the drill")

-- A drill with no drop target leaves its ore on the ground: taken there
-- before anything is hand-gathered.
reset()
natural("resource", "iron-ore", { x = 2.5, y = 0.5 }, { { name = "iron-ore", amount = 1 } })
drill_on_ore(nil, { x = 30.5, y = -1.3 })
local loose = add({ type = "item-entity", name = "item-on-ground", position = { x = 30.5, y = -1.3 }, force = neutral,
  items = { ["iron-ore"] = 1 }, stack = { valid_for_read = true, name = "iron-ore", count = 1 } })
local dropped = run({ items = { { name = "iron-ore", count = 3 } } })
check(dropped.status == "done" and calls[1].kind == "pickup" and calls[1].task.target.x == 30.5
  and calls[1].task.target.y == -1.3 and calls[1].task.count == 1 and loose.items["iron-ore"] == 0
  and calls[2].kind == "mine" and calls[2].task.count == 2 and inventory["iron-ore"] == 3
  and dropped.outcome.supplied.taken["iron-ore"] == 1 and dropped.outcome.supplied.gathered["iron-ore"] == 2,
  "get_items takes the loose ore at an own drill's drop position, then hand-gathers the rest")

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

-- Holders are read live only where the registry's stock says the item is:
-- none of it anywhere walks no holder, and of many holders only the nearest
-- four that held it are read.
reset()
for i = 1, 30 do chest({ x = 2.5 + i, y = 4.5 }, { ["iron-plate"] = 10 }) end
local live_reads = 0
for _, e in ipairs(world) do
  local get_inventory = e.get_inventory
  e.get_inventory = function(...) live_reads = live_reads + 1; return get_inventory(...) end
end
local walks_before = registry_reads
prototypes.item["copper-ore"] = prototypes.item["copper-ore"] or { stack_size = 50 }
local nothing = { items = { { name = "copper-ore", count = 1 } } }
supply.start(nothing)
supply.tick(nothing)
check(registry_reads == walks_before and live_reads == 0, "an item no holder held walks no holder")
local rows_before = holder_rows_read
local plates = { items = { { name = "iron-plate", count = 5 } } }
supply.start(plates)
supply.tick(plates)
check(holder_rows_read - rows_before == 4 and live_reads == 4 and calls[#calls].kind == "extract"
  and calls[#calls].task.target.x == 3.5, "of 30 holders only the nearest 4 are read live")

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
check(short.outcome.missing[1].rate_per_min == nil and not short.detail:match("own machines make"),
  "no producing line: the shortfall promises nothing")

-- Own lines that make a missing item say when the rest can be fetched.
reset()
local autonomy = require("scripts.autonomy")
local producing = autonomy.producing
autonomy.producing = function(item) if item == "iron-plate" then return 1.5, 1 end return 0, 0 end
chest({ x = 2.5, y = 0.5 }, { ["iron-plate"] = 2 })
local expected = run({ items = { { name = "iron-plate", count = 5 } } })
autonomy.producing = producing
check(expected.status == "partial" and inventory["iron-plate"] == 2 and expected.outcome.missing[1].rate_per_min == 1.5
  and expected.outcome.missing[1].expected_minutes == 2
  and expected.detail:match("own machines make iron%-plate at 1%.5/min %(the missing 3 in about 2"),
  "a partial get_items carries what exists and says when own machines make the rest")

-- Output still in the crafting queue counts as supplied: never made twice.
reset()
crafting["iron-gear-wheel"] = 5
local in_queue = run({ items = { { name = "iron-gear-wheel", count = 5 } } })
check(in_queue.status == "done" and #calls == 0 and in_queue.detail:match("still in the crafting queue: 5 iron%-gear%-wheel"),
  "get_items counts gears still in the crafting queue and crafts none")
reset()
crafting["iron-gear-wheel"] = 3
chest({ x = 4.5, y = 0.5 }, { ["iron-plate"] = 50 })
local topped = run({ items = { { name = "iron-gear-wheel", count = 5 } } })
check(topped.status == "done" and calls[1].kind == "extract" and calls[1].task.items["iron-plate"] == 4
  and calls[2].kind == "craft" and calls[2].task.count == 2,
  "get_items crafts only what the queue does not already make")
crafting = {}

-- Shared ingredients: plates a recipe needs directly and through its gears
-- and pipes are all fetched, from furnace outputs, and nothing is left over.
local early_recipes = {
  ["pipe"] = { { "iron-plate", 1 } },
  ["steam-engine"] = { { "iron-gear-wheel", 8 }, { "pipe", 5 }, { "iron-plate", 10 } },
  ["copper-cable"] = { { "copper-plate", 1 } },
  ["electronic-circuit"] = { { "iron-plate", 1 }, { "copper-cable", 3 } },
  ["transport-belt"] = { { "iron-plate", 1 }, { "iron-gear-wheel", 1 } },
  ["lab"] = { { "electronic-circuit", 10 }, { "iron-gear-wheel", 10 }, { "transport-belt", 4 } },
  ["inserter"] = { { "electronic-circuit", 1 }, { "iron-gear-wheel", 1 }, { "iron-plate", 1 } },
  ["assembling-machine-1"] = { { "electronic-circuit", 3 }, { "iron-gear-wheel", 5 }, { "iron-plate", 9 } },
}
local yields_two = { ["copper-cable"] = true, ["transport-belt"] = true }
for name, ingredients in pairs(early_recipes) do
  local list = {}
  for _, row in ipairs(ingredients) do list[#list + 1] = { type = "item", name = row[1], amount = row[2] } end
  recipes[name] = { name = name, enabled = true, category = "crafting", ingredients = list,
    products = { { type = "item", name = name, amount = yields_two[name] and 2 or 1 } } }
  prototypes.item[name] = prototypes.item[name] or { stack_size = 50 }
end
prototypes.item["copper-plate"] = prototypes.item["copper-plate"] or { stack_size = 100 }
local function furnace_output(position, items)
  local f = add({ type = "furnace", name = "stone-furnace", position = position, items = items,
    prototype = { crafting_categories = { smelting = true } } })
  f.get_output_inventory = function() return holder(f.items) end
  return f
end

reset()
local iron_out = furnace_output({ x = 4, y = 0 }, { ["iron-plate"] = 31 })
local engine = run({ items = { { name = "steam-engine", count = 1 } } })
check(engine.status == "done" and inventory["steam-engine"] == 1 and iron_out.items["iron-plate"] == 0
  and (inventory["iron-plate"] or 0) == 0 and engine.outcome.supplied.taken["iron-plate"] == 31,
  "a steam engine fetches the 31 plates it needs directly and through gears and pipes (" .. engine.detail .. ")")

reset()
iron_out = furnace_output({ x = 4, y = 0 }, { ["iron-plate"] = 93 })
local copper_out = furnace_output({ x = 8, y = 0 }, { ["copper-plate"] = 21 })
local starter = run({ items = { { name = "steam-engine", count = 1 }, { name = "lab", count = 1 },
  { name = "inserter", count = 1 }, { name = "assembling-machine-1", count = 1 } } })
check(starter.status == "done" and inventory["steam-engine"] == 1 and inventory.lab == 1 and inventory.inserter == 1
  and inventory["assembling-machine-1"] == 1 and iron_out.items["iron-plate"] == 0
  and copper_out.items["copper-plate"] == 0,
  "an engine, lab, inserter and assembler sharing plates, gears and circuits come from just enough plates ("
    .. starter.detail .. ")")

reset()
chest({ x = 4.5, y = 0.5 }, { ["iron-plate"] = 50 })
local both = run({ items = { { name = "iron-plate", count = 10 }, { name = "iron-gear-wheel", count = 5 } } })
check(both.status == "done" and inventory["iron-plate"] == 10 and inventory["iron-gear-wheel"] == 5,
  "plates wanted themselves are still carried after the gears wanted alongside are crafted from more plates")
reset()
chest({ x = 4.5, y = 0.5 }, { ["iron-plate"] = 50 })
local resumed = { items = { { name = "iron-gear-wheel", count = 3 } } }
supply.start(resumed)
resumed._claims, resumed._stack[1].path = nil, nil -- begun before claims existed
local resumed_result
for _ = 1, 50 do resumed_result = supply.tick(resumed); if resumed_result then break end end
check(resumed_result and resumed_result.status == "done" and inventory["iron-gear-wheel"] == 3,
  "a supply begun before claims existed still finishes on its frame counts")
for name in pairs(early_recipes) do recipes[name] = nil end

-- Smelting: plates nothing holds and no hand recipe makes come from an own
-- furnace: ore and fuel in, wait by it, plates out.
reset()
chest({ x = 3.5, y = 0.5 }, { ["iron-ore"] = 20, coal = 10 })
local furnace = add({ type = "furnace", name = "stone-furnace", position = { x = 6, y = 0 }, items = {},
  prototype = { crafting_categories = { smelting = true } } })
local source, fuel, smelting = {}, {}, 0
local function count_of(book) return function(name)
  if name then return book[name] or 0 end
  local total = 0; for _, n in pairs(book) do total = total + n end; return total
end end
furnace.get_inventory = function(id)
  if id == defines.inventory.furnace_source then return { get_item_count = count_of(source) } end
  if id == defines.inventory.furnace_result then return { get_item_count = count_of(furnace.items) } end
end
furnace.get_output_inventory = function() return holder(furnace.items) end
furnace.get_fuel_inventory = function() return { is_empty = function() return (fuel.coal or 0) == 0 end } end
furnace.is_crafting = function() return smelting > 0 end
supply.register_runner("insert", stub("insert", function(task)
  for name, count in pairs(task.items) do
    local book = name == "coal" and fuel or source
    book[name] = (book[name] or 0) + count
    inventory[name] = inventory[name] - count
  end
  return { status = "done", detail = "inserted", outcome = { transfers = {} } }
end))
-- A plate every 10 ticks while ore and fuel are in.
local function smelt_tick()
  if (source["iron-ore"] or 0) > 0 and (fuel.coal or 0) > 0 then
    smelting = smelting + 1
    if smelting >= 10 then
      smelting, source["iron-ore"] = 0, source["iron-ore"] - 1
      furnace.items["iron-plate"] = (furnace.items["iron-plate"] or 0) + 1
    end
  end
end
local smelt_task = { items = { { name = "iron-plate", count = 5 } } }
supply.start(smelt_task)
local smelted
for _ = 1, 400 do
  smelted = supply.tick(smelt_task)
  if smelted then break end
  game.tick = game.tick + 1
  smelt_tick()
end
local kinds = {}
for _, call in ipairs(calls) do kinds[#kinds + 1] = call.kind end
check(smelted and smelted.status == "done" and inventory["iron-plate"] == 5 and smelted.outcome.supplied.smelted["iron-plate"] == 5,
  "get_items smelts iron plates through an own furnace when nothing holds them")
check(table.concat(kinds, ",") == "extract,extract,insert,extract" and calls[3].task.items["iron-ore"] == 5
  and calls[3].task.items.coal == 5 and calls[3].task.target.x == 6 and calls[4].task.items["iron-plate"] == 5,
  "the body fetches the ore and fuel, loads the furnace, waits, then takes the plates")
-- The deadline starts once the load is in: a long walk to the furnace is
-- not smelting time.
reset()
chest({ x = 3.5, y = 0.5 }, { ["iron-ore"] = 20, coal = 10 })
local far = add({ type = "furnace", name = "stone-furnace", position = { x = 6, y = 0 }, items = {},
  prototype = { crafting_categories = { smelting = true } } })
local far_source, far_fuel = {}, 0
far.get_inventory = function(id)
  if id == defines.inventory.furnace_source then return { get_item_count = count_of(far_source) } end
  return { get_item_count = count_of(far.items) }
end
far.get_output_inventory = function() return holder(far.items) end
far.get_fuel_inventory = function() return { is_empty = function() return far_fuel == 0 end } end
far.is_crafting = function() return (far_source["iron-ore"] or 0) > 0 and far_fuel > 0 end
local walked = 0
supply.register_runner("insert", stub("insert", function(task)
  walked = walked + 1
  if walked < 3000 then return nil end
  for name, count in pairs(task.items) do
    if name == "coal" then far_fuel = far_fuel + count else far_source[name] = (far_source[name] or 0) + count end
    inventory[name] = inventory[name] - count
  end
  return { status = "done", detail = "inserted", outcome = { transfers = {} } }
end))
local far_task = { items = { { name = "iron-plate", count = 2 } } }
supply.start(far_task)
local far_result
for _ = 1, 8000 do
  far_result = supply.tick(far_task)
  if far_result then break end
  game.tick = game.tick + 1
  if far.is_crafting() and game.tick % 10 == 0 then
    far_source["iron-ore"] = far_source["iron-ore"] - 1
    far.items["iron-plate"] = (far.items["iron-plate"] or 0) + 1
  end
end
check(far_result and far_result.status == "done" and walked >= 3000,
  "a long walk to the furnace does not use up the smelt wait")

-- The wait ends by its deadline even while the furnace's counts keep moving
-- the way the body's own load would (the ore slowly goes, no plate shows).
reset()
chest({ x = 3.5, y = 0.5 }, { ["iron-ore"] = 20, coal = 10 })
local churn = add({ type = "furnace", name = "stone-furnace", position = { x = 6, y = 0 }, items = {},
  prototype = { crafting_categories = { smelting = true } } })
local churn_source, loaded = {}, false
churn.get_inventory = function(id)
  if id == defines.inventory.furnace_source then return { get_item_count = count_of(churn_source) } end
  return { get_item_count = count_of(churn.items) }
end
churn.get_output_inventory = function() return holder(churn.items) end
churn.get_fuel_inventory = function() return { is_empty = function() return loaded end } end
churn.is_crafting = function() return loaded end
supply.register_runner("insert", stub("insert", function(task)
  for name, count in pairs(task.items) do
    if name ~= "coal" then churn_source[name] = (churn_source[name] or 0) + count end
    inventory[name] = inventory[name] - count
  end
  return { status = "done", detail = "inserted", outcome = { transfers = {} } }
end))
local churn_task = { items = { { name = "iron-plate", count = 5 } } }
supply.start(churn_task)
local churned, waited = nil, 0
for _ = 1, 40000 do
  churned = supply.tick(churn_task)
  if churned then break end
  game.tick, waited = game.tick + 1, waited + 1
  if (churn_source["iron-ore"] or 0) > 0 then loaded = true end
  if loaded and game.tick % 500 == 0 and churn_source["iron-ore"] > 0 then
    churn_source["iron-ore"] = churn_source["iron-ore"] - 1
  end
end
check(churned and churned.status ~= "done" and waited > 700 and waited < 20000
  and churned.detail:match("made none of this load in time"),
  "a smelt wait whose counts keep moving ends by its deadline (" .. waited .. " ticks)")

-- A line that starts feeding or emptying the furnace after the body loaded
-- it ends the wait at once (its counts move against the body's load): the
-- plates made so far are taken and the furnace is never loaded again.
reset()
chest({ x = 3.5, y = 0.5 }, { ["iron-ore"] = 60, coal = 10 })
local fed_line = add({ type = "furnace", name = "stone-furnace", position = { x = 6, y = 0 }, items = {},
  unit_number = 41, prototype = { crafting_categories = { smelting = true } } })
local fed_source, fed_loaded, fed_loads = {}, nil, 0
fed_line.get_inventory = function(id)
  if id == defines.inventory.furnace_source then return { get_item_count = count_of(fed_source) } end
  return { get_item_count = count_of(fed_line.items) }
end
fed_line.get_output_inventory = function() return holder(fed_line.items) end
fed_line.get_fuel_inventory = function() return { is_empty = function() return fed_loaded == nil end } end
fed_line.is_crafting = function() return fed_loaded ~= nil end
supply.register_runner("insert", stub("insert", function(task)
  if task.target.x == 6 then fed_loads = fed_loads + 1 end
  for name, count in pairs(task.items) do
    if name ~= "coal" then fed_source[name] = (fed_source[name] or 0) + count end
    inventory[name] = inventory[name] - count
  end
  fed_loaded = fed_loaded or game.tick
  return { status = "done", detail = "inserted", outcome = { transfers = {} } }
end))
local fed_task = { items = { { name = "iron-plate", count = 50 } } }
supply.start(fed_task)
local fed_result
for _ = 1, 4000 do
  fed_result = supply.tick(fed_task)
  if fed_result or (fed_loaded and game.tick - fed_loaded >= 3000) then break end
  game.tick = game.tick + 1
  if fed_loaded then
    -- A plate every 96 ticks. From ten seconds on the line's input inserter
    -- tops the source up, and soon after its output inserter takes every
    -- plate, so the counts keep moving and the load never visibly finishes.
    local since = game.tick - fed_loaded
    if since >= 600 and since % 30 == 0 then fed_source["iron-ore"] = (fed_source["iron-ore"] or 0) + 1 end
    if since % 96 == 0 and fed_source["iron-ore"] > 0 then
      fed_source["iron-ore"] = fed_source["iron-ore"] - 1
      fed_line.items["iron-plate"] = (fed_line.items["iron-plate"] or 0) + 1
    end
    if since >= 700 and since % 60 == 0 then fed_line.items["iron-plate"] = 0 end
  end
end
check(fed_result and fed_result.status ~= "done" and fed_loads == 1 and inventory["iron-plate"] == 6
  and fed_result.detail:match("missing 44 iron%-plate")
  and fed_result.detail:match("no own furnace is free to smelt it %(smelting%); a line feeds or empties the one it loaded"),
  "a furnace a line starts feeding or emptying ends the smelt wait and is not loaded again ("
    .. tostring(fed_result and fed_result.detail) .. ")")

-- A line that only empties the furnace (an output inserter, no feed) ends
-- the wait at the first poll that sees fewer plates, though its ore keeps
-- going down the way the body's own load would.
reset()
chest({ x = 3.5, y = 0.5 }, { ["iron-ore"] = 60, coal = 10 })
local emptied = add({ type = "furnace", name = "stone-furnace", position = { x = 6, y = 0 }, items = {},
  unit_number = 42, prototype = { crafting_categories = { smelting = true } } })
local emptied_source, emptied_loaded, emptied_loads, emptied_drop = {}, nil, 0, nil
emptied.get_inventory = function(id)
  if id == defines.inventory.furnace_source then return { get_item_count = count_of(emptied_source) } end
  return { get_item_count = count_of(emptied.items) }
end
emptied.get_output_inventory = function() return holder(emptied.items) end
emptied.get_fuel_inventory = function() return { is_empty = function() return emptied_loaded == nil end } end
emptied.is_crafting = function() return emptied_loaded ~= nil and (emptied_source["iron-ore"] or 0) > 0 end
supply.register_runner("insert", stub("insert", function(task)
  if task.target.x == 6 then emptied_loads = emptied_loads + 1 end
  for name, count in pairs(task.items) do
    if name ~= "coal" then emptied_source[name] = (emptied_source[name] or 0) + count end
    inventory[name] = inventory[name] - count
  end
  emptied_loaded = emptied_loaded or game.tick
  return { status = "done", detail = "inserted", outcome = { transfers = {} } }
end))
local emptied_task = { items = { { name = "iron-plate", count = 50 } } }
supply.start(emptied_task)
local emptied_result
for _ = 1, 8000 do
  emptied_result = supply.tick(emptied_task)
  if emptied_result then break end
  game.tick = game.tick + 1
  if emptied_loaded then
    -- A plate every 96 ticks; from 400 ticks on the output inserter takes
    -- every plate each second.
    local since = game.tick - emptied_loaded
    if since % 96 == 0 and emptied_source["iron-ore"] > 0 then
      emptied_source["iron-ore"] = emptied_source["iron-ore"] - 1
      emptied.items["iron-plate"] = (emptied.items["iron-plate"] or 0) + 1
    end
    if since >= 400 and since % 60 == 0 and (emptied.items["iron-plate"] or 0) > 0 then
      emptied.items["iron-plate"] = 0
      emptied_drop = emptied_drop or game.tick
    end
  end
end
local emptied_after = emptied_drop and game.tick - emptied_drop
check(emptied_result and emptied_result.status ~= "done" and emptied_loads == 1 and emptied_after
  and emptied_after <= 30 and emptied_result.detail:match("a line feeds or empties"),
  "a furnace a line only empties ends the smelt wait at the next poll (" .. tostring(emptied_after) .. " ticks after: "
    .. tostring(emptied_result and emptied_result.detail) .. ")")

-- A furnace a line feeds and empties (crafting, ore in its source) is never
-- picked: its counts keep moving while the body's own plates never show.
reset()
local line_furnace = add({ type = "furnace", name = "stone-furnace", position = { x = 6, y = 0 }, items = {},
  prototype = { crafting_categories = { smelting = true } } })
line_furnace.get_inventory = function(id)
  if id == defines.inventory.furnace_source then return { get_item_count = count_of({ ["iron-ore"] = 3 }) } end
  return { get_item_count = count_of(line_furnace.items) }
end
line_furnace.get_output_inventory = function() return holder(line_furnace.items) end
line_furnace.is_crafting = function() return true end
local fed = run({ items = { { name = "iron-plate", count = 5 } } })
check(fed.status == "failed" and fed.detail:match("no own furnace is free to smelt it"),
  "a furnace a line keeps feeding is not free to smelt the body's ore")
reset()
local busy = add({ type = "furnace", name = "stone-furnace", position = { x = 6, y = 0 }, items = { ["copper-plate"] = 3 },
  prototype = { crafting_categories = { smelting = true } } })
busy.get_inventory = function(id)
  if id == defines.inventory.furnace_source then return { get_item_count = count_of({}) } end
  return { get_item_count = count_of(busy.items) }
end
busy.get_output_inventory = function() return holder(busy.items) end
local no_free = run({ items = { { name = "iron-plate", count = 5 } } })
check(no_free.status == "failed" and no_free.detail:match("no own furnace is free to smelt it"),
  "a furnace holding another product is never loaded; the shortfall says so")

-- Fuel: what the body carries first, then own stock, in fuel order.
reset()
chest({ x = 3.5, y = 0.5 }, { wood = 12 })
local fuel_name, fuel_total = supply.fuel_item(body)
check(fuel_name == "wood" and fuel_total == 12, "the fuel is the first fuel carried or stored")
inventory.coal = 2
fuel_name, fuel_total = supply.fuel_item(body)
check(fuel_name == "coal" and fuel_total == 2, "coal comes before wood")

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
package.loaded["scripts.actions.transfer"] = nil -- build loaded it with the real approach
local transfer = require("scripts.actions.transfer")
supply.register_runner("extract", stub("extract", function(task)
  local source = at(task.target)
  for name, count in pairs(task.items) do move(source, name, count) end
  return { status = "done", detail = "took" }
end))
body.remove_item = function(stack) inventory[stack.name] = inventory[stack.name] - stack.count; return stack.count end
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

-- insert_items with several targets: each gets the same items, fetched in
-- one trip; a target that takes nothing is reported, the rest still filled.
reset()
local fed_by = {}
local function feedable(x, accepts)
  local f = add({ type = "furnace", name = "stone-furnace", position = { x = x, y = 0.5 }, items = {} })
  f.get_output_inventory = function() return holder({}) end
  f.insert = function(stack) if not accepts then return 0 end; fed_by[x] = (fed_by[x] or 0) + stack.count; return stack.count end
  return f
end
feedable(2.5, true); feedable(4.5, true); feedable(8.5, true); feedable(40.5, true)
chest({ x = 6.5, y = 1.5 }, { coal = 50 })
local several = { id = 13, targets = { { x = 2.5, y = 0.5 }, { x = 4.5, y = 0.5 }, { x = 8.5, y = 0.5 } }, items = { coal = 5 } }
local events_before = #((storage.factory_activity or {}).events or {})
transfer.insert.start(several)
local filled
for _ = 1, 20 do filled = transfer.insert.tick(several); if filled then break end end
check(filled and filled.status == "done" and filled.outcome.code == "INSERTED_ALL_TARGETS" and fed_by[2.5] == 5
  and fed_by[4.5] == 5 and fed_by[8.5] == 5 and #filled.outcome.targets == 3 and calls[1].kind == "extract"
  and calls[1].task.items.coal == 15 and #calls == 1,
  "insert_items fills several targets with the same items after one supply trip")
local fed_events = {}
for index = events_before + 1, #storage.factory_activity.events do
  local event = storage.factory_activity.events[index]
  if event.action == "insert" then fed_events[#fed_events + 1] = event.target.position.x end
end
check(#fed_events == 3 and fed_events[1] == 2.5 and fed_events[3] == 8.5,
  "each target's insert is recorded as a hand transfer into that machine")
reset()
fed_by = {}
feedable(2.5, true); feedable(4.5, false); feedable(9.5, true); feedable(40.5, true)
inventory.coal = 20
local named = { id = 14, targets = { name = "stone-furnace", near = { x = 3, y = 0.5 }, radius = 10 }, items = { coal = 5 } }
transfer.insert.start(named)
check(#named._targets == 3 and named._targets[1].x == 2.5 and named._targets[3].x == 9.5,
  "targets by name are own entities near a point, nearest first, within the radius")
local mixed
for _ = 1, 20 do mixed = transfer.insert.tick(named); if mixed then break end end
check(mixed and mixed.status == "partial" and mixed.outcome.code == "PARTIAL_INSERT_TARGETS"
  and fed_by[2.5] == 5 and fed_by[9.5] == 5 and fed_by[40.5] == nil and mixed.outcome.targets[2].status == "failed"
  and mixed.detail:match("1 of 3 targets"),
  "a target that takes nothing is named and the others are still filled")
check(not pcall(transfer.insert.start, { targets = { name = "stone-furnace", near = { x = 0, y = 0 }, radius = 64 }, items = { coal = 1 } })
  and not pcall(transfer.insert.start, { targets = {}, items = { coal = 1 } }),
  "a target search is bounded in radius and a target list is never empty")

local walk_state={phase="waiting",request_tick=123,requested_goal={x=4,y=5},target={x=4.5,y=5.5}}
local observed={target={x=30,y=40},_supply={_stack={{name="coal",count=10,phase="take",takes=1}},
  _sub={type="extract",target={x=4,y=5},_approach={walk=walk_state}}}}
local before_phase=walk_state.phase
local pending=supply.diagnostics(observed)
check(pending.stage=="auto_supply" and pending.target.x==30 and pending.supply.target.x==4
  and pending.supply.item=="coal" and pending.route.requested_goal.x==4
  and pending.route.resolved_goal.x==4.5 and walk_state.phase==before_phase,
  "readback separates nested stock-holder approach from final insertion target without advancing work")
check(owner._supply_result and owner._supply_result.status=="failed"
  and supply.diagnostics(owner).supply_result.status=="failed",
  "a completed embedded supply failure remains evidence after its nested owner is cleared")
observed._supply=nil;observed._supplied=true;observed._approach={walk=walk_state}
observed._supply_result={status="partial",code="SUPPLY_SHORTFALL"}
check(supply.diagnostics(observed).stage=="target"
  and supply.diagnostics(observed).supply_result.code=="SUPPLY_SHORTFALL",
  "final target approach retains the actual earlier supply result without implying insertion")
local cycle={phase="following"};cycle.walker=cycle
observed._approach={walk=cycle}
check(supply.diagnostics(observed).route.phase=="following",
  "readback terminates on a cyclic nested walker without advancing or scanning native state")
os.exit(failures == 0 and 0 or 1)
