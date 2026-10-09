-- get_items and auto-supply: the body fetches what a step needs the way a
-- player would. For each wanted item, in order: take it from the nearest own
-- chest, cargo landing pad or machine output (then loose items an own drill
-- dropped, then belt), walking there; else hand-craft it, supplying the
-- recipe's ingredients the same way first (so intermediates follow); else
-- smelt it in an own furnace (ore and fuel in, wait, products out); else
-- hand-gather it, also an ore own drills mine when none of their output can
-- be taken now (a first burner drill feeding its furnace).
-- Whatever is still missing is a named shortfall. Every move is physical:
-- the nested walk/extract/pickup/craft/mine/insert actions keep reach and
-- time. Hand-crafts run in the background: output still in the crafting
-- queue counts as supplied (never crafted twice), and the step that consumes
-- it waits for it (craft.awaits).
--
-- A supply task is { items = {{name, count}, ...} } where count is the total
-- the body should carry. An item several frames need (plates both directly
-- and through gears or pipes) is claimed by each of them: the body carries
-- what all open claims total, and a craft or furnace load releases the claims
-- of the ingredients it consumed. exclude = {x, y} is never taken from (an insert's
-- own target); bulk = true takes up to a stack of a placeable item from a
-- source, so a plan placing many of one item fetches them once.
local companion = require("scripts.companion")
local walk = require("scripts.actions.walk")
local mine = require("scripts.actions.mine")
local errors = require("scripts.errors")
local pickup = require("scripts.actions.pickup")
local craft = require("scripts.actions.craft")
local factory_activity = require("scripts.factory_activity")
local registry = require("scripts.registry")
local autonomy = require("scripts.autonomy")

local M = {}

local MAX_DEPTH = 4          -- recipe levels supplied below a wanted item
local MAX_TAKES = 6          -- sources tried per item
local MAX_GATHERS = 8        -- hand-mining actions per item
local MAX_RESOURCE_CYCLES = 50
local MAX_CRAFTS = 100         -- hand-crafts queued per round (the craft action's own cap)
local MAX_CRAFT_ROUNDS = 10    -- rounds per item: a count over one round's cap is fetched and queued again
local MAX_SHORTFALL_ROWS = 8
local GATHER_RADII = { 8, 16, 32, 48, 64 }
local GATHER_LIMIT = 100     -- natural entities read per query
-- Belts are not listed by the registry: only belts this near the body are
-- searched (an area query of bounded size and count, never the whole force),
-- at most a few queries per supply tick. The engine returns belts in chunk
-- order, not nearest first, so a query at its limit may leave out the belt
-- that holds the item: the search then goes on in square cells, nearest
-- first, and a cell at the limit is split into four until a cell's disk
-- spans fewer tiles than the limit (one belt per tile: none is left unread).
local BELT_SEARCH_RADIUS = 48
local BELT_SEARCH_LIMIT = 64
local BELT_QUERIES_PER_TICK = 4
local BELT_CELL = 16
local BELT_CELL_MIN = 4
-- A drill with no drop target leaves its output on the ground at its drop
-- position: only the nearest few such drills are read, one point query each.
local DROPS_READ = 4
local DROP_RADIUS = 0.5
local DROP_LIMIT = 8
-- Resource candidates checked for an own building standing on them (a drill
-- or furnace on the patch), one point query each, per supply tick; a search
-- that spends them resumes next tick from the tiles already checked.
local COVER_CHECKS = 16
local NATURAL_TYPES = { "simple-entity", "tree", "plant", "resource" }
-- Smelting through an own furnace: one source stack per round, a poll every
-- half second, a furnace that makes no progress for ten seconds is done; one
-- a line feeds or empties is left at once and not loaded again.
local SMELT_POLL_TICKS = 30
local SMELT_STALL_TICKS = 600
local MAX_SMELT_ROUNDS = 4
local SMELT_FUEL = 5
-- The body's fuels, in the order it uses them (upkeep refuelling too).
local FUELS = { "coal", "wood", "solid-fuel" }
M.FUELS = FUELS

-- Nested physical actions. transfer.lua registers extract and insert here
-- itself (it requires this module for insert's auto-supply).
local runners = { walk_to = walk, mine = mine, pickup = pickup, craft = craft }
function M.register_runner(kind, runner) runners[kind] = runner end

-- ------------------------------------------------------------ nested runs

-- Starts one nested action in owner[field] under the owner's id, so path
-- results reach it through the active plan's mailbox. Raises on bad input.
function M.begin(owner, field, sub)
  local runner = runners[sub.type]
  if not runner then error("no runner for nested " .. tostring(sub.type)) end
  sub.id = owner.id
  runner.start(sub)
  owner[field] = sub
end

-- nil while owner[field] runs, else its result (and the field is cleared).
function M.step(owner, field)
  local sub = owner[field]
  local ok, result = pcall(runners[sub.type].tick, sub)
  if not ok then result = { status = "failed", detail = tostring(result) } end
  if result then owner[field] = nil end
  return result
end

-- After a human hold the body stands elsewhere: nested actions re-approach.
local NESTED_FIELDS = { "_supply", "_sub", "_clear", "_exit", "_escape" }
function M.resume(owner)
  for _, field in ipairs(NESTED_FIELDS) do
    local sub = owner[field]
    if type(sub) == "table" then
      sub._approach, sub._approach_close = nil, nil
      local runner = sub.type and runners[sub.type] or (field == "_supply" and M)
      if runner and runner.resume then runner.resume(sub) end
    end
  end
end

-- The owner ends from outside (a cancel, its plan's budget): the first
-- nested action whose cancelled hook has a note lets go of what it holds
-- (an escape's taken-up entity, also one an embedded supply's step-out
-- holds). Returns that hook's note, or nil.
function M.cancel_nested(owner, body_only)
  for _, field in ipairs(NESTED_FIELDS) do
    local sub = owner[field]
    local runner = type(sub) == "table" and (sub.type and runners[sub.type] or field == "_supply" and M)
    if runner and runner.cancelled then
      local note = runner.cancelled(sub, body_only)
      if note ~= nil then return note end
    end
  end
end
function M.cancelled(task, body_only) return M.cancel_nested(task, body_only) end

-- --------------------------------------------------------------- reading

local function carried(c, name) return c.get_item_count(name) end
-- Carried plus what the crafting queue still hands over.
local function have(c, name) return c.get_item_count(name) + craft.queued(c, name) end

local function dist_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function charted(c, position)
  local ok, value = pcall(c.force.is_chunk_charted, c.surface,
    { x = math.floor(position.x / 32), y = math.floor(position.y / 32) })
  return ok and value == true
end

local function contains(entity, point)
  local box = entity.bounding_box
  if box and box.left_top then
    return point.x >= box.left_top.x and point.x <= box.right_bottom.x
      and point.y >= box.left_top.y and point.y <= box.right_bottom.y
  end
  return dist_sq(entity.position, point) < 0.25
end

local function held(entity, item)
  local ok, count = pcall(function()
    if entity.type == "transport-belt" then
      return entity.get_transport_line(1).get_item_count(item) + entity.get_transport_line(2).get_item_count(item)
    end
    local inventory = registry.holder_inventory(entity)
    return inventory and inventory.get_item_count(item) or 0
  end)
  return ok and tonumber(count) or 0
end

-- Nearest own chest, landing pad or machine output holding the item (the
-- registry's holders); a belt near the body only when none holds any.
local function nearest_of(c, task, item, tried, entities, charted_only)
  local best
  for _, entity in ipairs(entities) do
    if entity.valid then
      local position = entity.position
      local key = string.format("%.2f,%.2f", position.x, position.y)
      if not tried[key] and not (task.exclude and contains(entity, task.exclude))
        and (not charted_only or charted(c, position)) then
        local count = held(entity, item)
        local d = count > 0 and dist_sq(c.position, position)
        if d and (not best or d < best.distance) then
          best = { key = key, position = { x = position.x, y = position.y }, count = count, distance = d,
            kind = entity.type == "transport-belt" and "belt" or registry.holder_kind(entity) }
        end
      end
    end
  end
  return best
end

-- The registry's stock (the maintenance cursor's last reads) picks the few
-- nearest holders that held the item; only those are read live. None held
-- any: no holder is walked.
local HOLDERS_READ = 4
local function nearest_holder(c, task, item, tried)
  local ok_totals, totals = pcall(registry.stock_totals, { item })
  if ok_totals and (totals[item] or 0) == 0 then return nil end
  local function skip(entry) return tried[string.format("%.2f,%.2f", entry.position.x, entry.position.y)] end
  local ok, entries = pcall(registry.holders_with, item, c.position, HOLDERS_READ, skip)
  local holders = {}
  for _, entry in ipairs(ok and entries or {}) do holders[#holders + 1] = entry.entity end
  return nearest_of(c, task, item, tried, holders, true)
end

-- A square cell at offset (x, y) from the body: its side and the squared
-- distance from the body to its nearest point.
local function belt_cell(x, y, size)
  local dx, dy = math.max(math.abs(x) - size / 2, 0), math.max(math.abs(y) - size / 2, 0)
  return { x = x, y = y, size = size, near_sq = dx * dx + dy * dy }
end

-- Inserts a cell that reaches into BELT_SEARCH_RADIUS into the queue, which
-- stays nearest first (ties by y, then x, the same on every peer).
local function queue_belt_cell(queue, cell)
  if cell.near_sq >= BELT_SEARCH_RADIUS ^ 2 then return end
  local function before(a, b)
    if a.near_sq ~= b.near_sq then return a.near_sq < b.near_sq end
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end
  local at = #queue + 1
  while at > 1 and before(cell, queue[at - 1]) do at = at - 1 end
  table.insert(queue, at, cell)
end

-- The cells tiling BELT_SEARCH_RADIUS around the body, nearest first.
local function belt_cells()
  local queue, n = {}, math.ceil(BELT_SEARCH_RADIUS / BELT_CELL)
  for i = -n, n - 1 do
    for j = -n, n - 1 do
      queue_belt_cell(queue, belt_cell((i + 0.5) * BELT_CELL, (j + 0.5) * BELT_CELL, BELT_CELL))
    end
  end
  return queue
end

-- Up to BELT_QUERIES_PER_TICK belt queries: the first reads the whole
-- radius, which suffices when under the limit; past it, frame.belt_cells
-- are read nearest first. The nearest holding belt within the radius once no
-- cell left can hold a nearer one; else nil and true (next tick goes on).
local function nearest_belt(c, task, frame)
  local best = frame.belt_best
  for _ = 1, BELT_QUERIES_PER_TICK do
    local cell, center, radius = nil, c.position, BELT_SEARCH_RADIUS
    if frame.belt_cells then
      cell = table.remove(frame.belt_cells, 1)
      center = { x = c.position.x + cell.x, y = c.position.y + cell.y }
      radius = cell.size * math.sqrt(2) / 2 + 0.5
    end
    local ok, belts = pcall(c.surface.find_entities_filtered, { position = center, radius = radius,
      force = c.force, type = "transport-belt", limit = BELT_SEARCH_LIMIT })
    belts = ok and type(belts) == "table" and belts or {}
    local found = nearest_of(c, task, frame.name, frame.tried, belts, true)
    if found and found.distance <= BELT_SEARCH_RADIUS ^ 2 and (not best or found.distance < best.distance) then
      best = found
    end
    if #belts >= BELT_SEARCH_LIMIT then
      if not cell then
        frame.belt_cells = belt_cells()
      elseif cell.size > BELT_CELL_MIN then
        local half, quarter = cell.size / 2, cell.size / 4
        for _, dx in ipairs({ -quarter, quarter }) do
          for _, dy in ipairs({ -quarter, quarter }) do
            queue_belt_cell(frame.belt_cells, belt_cell(cell.x + dx, cell.y + dy, half))
          end
        end
      end
    end
    local after = frame.belt_cells and frame.belt_cells[1]
    if not after or (best and best.distance <= after.near_sq) then
      frame.belt_cells, frame.belt_best = nil, nil
      return best
    end
  end
  frame.belt_best = best
  return nil, true
end

-- Items of `item` one craft of `recipe` yields, counting an uncertain matching
-- product as one. nil (and why) when the recipe does not make the item.
function M.output_per_craft(recipe, item)
  local found, total = false, 0
  for _, product in ipairs(recipe.products or {}) do
    if product.type == "item" and product.name == item then
      found = true
      local amount = product.amount
      if amount == nil and type(product.amount_min) == "number" and product.amount_min == product.amount_max then
        amount = product.amount_min
      end
      if (product.probability ~= nil and product.probability ~= 1) or type(amount) ~= "number" or amount <= 0 then
        amount = 1
      end
      total = total + amount
    end
  end
  if not found then
    return nil, "recipe " .. (recipe.name or "<unknown>") .. " does not produce requested item " .. item
  end
  return total
end

-- The enabled hand recipe named after the item, or nil and why not.
local function hand_recipe(c, item)
  local recipe = c.force.recipes[item]
  if not recipe then return nil, "no recipe makes it" end
  if not recipe.enabled then return nil, "recipe " .. item .. " is not researched yet" end
  local ok, categories = pcall(function() return c.prototype.crafting_categories end)
  local category = recipe.category
  if ok and type(categories) == "table" and category and not categories[category] then
    return nil, "it cannot be hand-crafted (" .. category .. ")"
  end
  for _, ingredient in ipairs(recipe.ingredients or {}) do
    if ingredient.type == "fluid" then return nil, "its recipe needs a fluid" end
  end
  local per_craft, why = M.output_per_craft(recipe, item)
  if not per_craft then return nil, why end
  return recipe, per_craft
end

local function yields(entity, item)
  local ok, found = pcall(function()
    local mineable = entity.prototype.mineable_properties
    if not mineable.minable or mineable.required_fluid then return false end
    for _, product in ipairs(mineable.products or {}) do
      if product.name == item then return true end
    end
    return false
  end)
  return ok and found
end

local natural_names
-- Own drills (registry) already mining something that yields the item; none
-- when nothing natural yields it (plates, intermediates), with no walk.
local function drills_producing(_, item)
  if #natural_names(item) == 0 then return 0 end
  local ok, drills = pcall(registry.machines, { "mining-drill" })
  if not ok or type(drills) ~= "table" then return 0 end
  local count = 0
  for _, entry in ipairs(drills) do
    local ok_target, target = pcall(function() return entry.entity.mining_target end)
    if ok_target and target and target.valid and yields(target, item) then count = count + 1 end
  end
  return count
end

-- Names of the resources, trees and rocks whose hand-mining yields the item,
-- worked out once per item from the prototypes (the same on every peer).
local natural_names_cache = {}
function natural_names(item)
  local names = natural_names_cache[item]
  if names then return names end
  names = {}
  local ok, found = pcall(prototypes.get_entity_filtered, { { filter = "type", type = NATURAL_TYPES } })
  for name, proto in pairs(ok and found or {}) do
    local ok_yields, yes = pcall(function()
      local mineable = proto.mineable_properties
      if not mineable.minable or mineable.required_fluid then return false end
      for _, product in ipairs(mineable.products or {}) do
        if product.name == item then return true end
      end
      return false
    end)
    if ok_yields and yes then names[#names + 1] = name end
  end
  table.sort(names)
  natural_names_cache[item] = names
  return names
end

-- An own building standing on a resource tile (a drill or furnace on the
-- patch) covers it: the body selects the building there, not the ore. A
-- character standing there does not.
local function covered(c, entity)
  local ok, found = pcall(c.surface.find_entities_filtered,
    { position = entity.position, force = c.force, limit = 4 })
  for _, other in ipairs(ok and type(found) == "table" and found or {}) do
    if other.valid and other.type ~= "character" then return true end
  end
  return false
end

-- Nearest natural entity (resource tile, tree, rock) in charted land around
-- the body that yields the item. The engine filters by the names that yield
-- it, each query reads at most GATHER_LIMIT entities, and small radii come
-- first, so a forest or ore patch never means a large read; an item nothing
-- natural yields makes no query. Ore an own building covers is passed over:
-- covers (kept by the caller across ticks) records each checked tile, at most
-- COVER_CHECKS new ones per call; nil, true when they are spent before a
-- free source is found, so the caller resumes the search next tick.
local function natural_source(c, item, covers)
  local names = natural_names(item)
  if #names == 0 then return nil end
  local chunks = {}
  local checks = 0
  for _, radius in ipairs(GATHER_RADII) do
    local candidates = {}
    local ok, found = pcall(c.surface.find_entities_filtered,
      { position = c.position, radius = radius, name = names, limit = GATHER_LIMIT })
    for _, entity in ipairs(ok and found or {}) do
      if entity.valid then
        local position = entity.position
        local key = math.floor(position.x / 32) .. "," .. math.floor(position.y / 32)
        if chunks[key] == nil then chunks[key] = charted(c, position) end
        if chunks[key] then
          candidates[#candidates + 1] = { entity = entity, distance = dist_sq(c.position, position), order = #candidates }
        end
      end
    end
    table.sort(candidates, function(a, b)
      if a.distance ~= b.distance then return a.distance < b.distance end
      return a.order < b.order
    end)
    for _, candidate in ipairs(candidates) do
      local entity = candidate.entity
      if entity.type ~= "resource" then return entity end
      local position = string.format("%.2f,%.2f", entity.position.x, entity.position.y)
      if covers[position] == nil then
        if checks >= COVER_CHECKS then return nil, true end
        checks = checks + 1
        covers[position] = covered(c, entity)
      end
      if not covers[position] then return entity end
    end
  end
  return nil
end

-- Loose items of the kind at the drop position of the nearest own drills
-- that mine something yielding it and drop onto the ground (no drop target):
-- the nearest stack. Drills come from the registry; at most DROPS_READ point
-- queries.
local function nearest_drop(c, task, item, tried)
  if #natural_names(item) == 0 then return nil end
  local ok, drills = pcall(registry.machines, { "mining-drill" })
  if not ok or type(drills) ~= "table" then return nil end
  local near = {}
  for _, entry in ipairs(drills) do
    local ok_drop, point = pcall(function()
      local e = entry.entity
      if not (e and e.valid) or e.drop_target then return nil end
      local target = e.mining_target
      if not (target and target.valid and yields(target, item)) then return nil end
      local drop = e.drop_position
      return drop and { x = drop.x, y = drop.y }
    end)
    if ok_drop and point then
      local d = dist_sq(c.position, point)
      local at = #near + 1
      while at > 1 and near[at - 1].distance > d do at = at - 1 end
      if at <= DROPS_READ then
        table.insert(near, at, { point = point, distance = d })
        near[DROPS_READ + 1] = nil
      end
    end
  end
  local best
  for _, drop in ipairs(near) do
    local ok_found, found = pcall(c.surface.find_entities_filtered,
      { position = drop.point, radius = DROP_RADIUS, type = "item-entity", limit = DROP_LIMIT })
    for _, entity in ipairs(ok_found and type(found) == "table" and found or {}) do
      local ok_stack, name, count = pcall(function()
        local stack = entity.valid and entity.stack
        if stack and stack.valid_for_read then return stack.name, stack.count end
      end)
      local position = entity.position
      local key = ok_stack and name == item and string.format("%.2f,%.2f", position.x, position.y)
      if key and not tried[key] and not (task.exclude and contains(entity, task.exclude)) and charted(c, position) then
        local d = dist_sq(c.position, position)
        if not best or d < best.distance then
          best = { key = key, position = { x = position.x, y = position.y }, count = count, distance = d, kind = "ground" }
        end
      end
    end
  end
  return best
end

-- The first fuel the body carries or the force stores (chests and machine
-- outputs, one pass over the registry's holders), and how much in all.
function M.fuel_item(c)
  local names = {}
  for _, name in ipairs(FUELS) do if prototypes.item[name] then names[#names + 1] = name end end
  local stored = registry.stock_totals(names)
  for _, name in ipairs(names) do
    local total = c.get_item_count(name) + (stored[name] or 0)
    if total > 0 then return name, total end
  end
end

-- The enabled recipe an own furnace would smelt the item with: one item
-- ingredient, a category the character cannot hand-craft, not hidden (quality
-- recycling recipes also make plates and sort first). Recipes come from the
-- engine's product filter (a LuaCustomTable, so userdata: no type check),
-- worked out once per item.
local smelt_recipes_cache = {}
local function smelt_recipe(c, item)
  local names = smelt_recipes_cache[item]
  if not names then
    names = {}
    local ok, found = pcall(prototypes.get_recipe_filtered,
      { { filter = "has-product-item", elem_filters = { { filter = "name", name = item } } } })
    for name in pairs(ok and found or {}) do names[#names + 1] = name end
    table.sort(names)
    smelt_recipes_cache[item] = names
  end
  local ok_categories, categories = pcall(function() return c.prototype.crafting_categories end)
  for _, name in ipairs(names) do
    local recipe = c.force.recipes[name]
    local hidden_ok, hidden = pcall(function() return recipe.hidden end)
    local ingredients = recipe and recipe.ingredients or {}
    if recipe and recipe.enabled and not (hidden_ok and hidden)
      and #ingredients == 1 and ingredients[1].type == "item"
      and not (ok_categories and type(categories) == "table" and categories[recipe.category]) then
      return recipe, ingredients[1]
    end
  end
end

-- Whether a supply could have wants ({{name, count}}) now, by its own
-- sources in its own order, without moving: what is carried, queued or
-- stored is one shared pool; then a hand recipe (MAX_DEPTH levels) whose
-- ingredients come the same way; else a smelt, which needs an own furnace
-- of the recipe's category; else hand-gathering, which anything natural
-- yields allows, also ore own drills mine (supply gathers it while their
-- output cannot be taken). Smelting counts only while all it would smelt
-- fits UNOBTAINABLE_SMELT_SECONDS at the fastest own furnace: supply smelts
-- one furnace load at a time, inside one plan's time budget. Prototype,
-- recipe and registry reads only (no
-- walk, no surface query). Returns
-- {item, missing, short?, reason} rows for what could not be had; short
-- names the ingredient that blocked a craft.
-- A furnace free for the body's own smelting: not crafting and its source
-- empty. A furnace a line feeds and empties never shows what the body's own
-- ore made. (Its result must also hold nothing but the item: smelter.)
local function idle_furnace(e)
  local ok, source = pcall(e.get_inventory, defines.inventory.furnace_source)
  return ok and source ~= nil and not e.is_crafting() and source.get_item_count() == 0
end

local UNOBTAINABLE_SMELT_SECONDS = 180
function M.unobtainable(c, wants)
  local pool, furnaces, smelt_seconds = {}, nil, 0
  local function stocked(name)
    if pool[name] == nil then
      local ok, totals = pcall(registry.stock_totals, { name })
      pool[name] = have(c, name) + (ok and totals[name] or 0)
    end
    return pool[name]
  end
  local function furnace_for(category)
    if not furnaces then
      furnaces = {}
      local ok, list = pcall(registry.machines, { "furnace" })
      for _, entry in ipairs(ok and type(list) == "table" and list or {}) do
        pcall(function()
          if entry.entity.valid and idle_furnace(entry.entity) then
            local ok_speed, speed = pcall(function() return entry.entity.prototype.get_crafting_speed() end)
            speed = ok_speed and tonumber(speed) or 1
            for name in pairs(entry.entity.prototype.crafting_categories) do
              furnaces[name] = math.max(furnaces[name] or 0, speed)
            end
          end
        end)
      end
    end
    return furnaces[category]
  end
  -- nil when count of name can be had, else the item that blocks it, how
  -- many of that item and why.
  local function obtain(name, count, depth, path)
    local take = math.min(stocked(name), count)
    pool[name] = pool[name] - take
    local need = count - take
    if need <= 0 then return nil end
    if path[name] then return name, need, "its recipe needs itself" end
    local reasons = { "not carried or stored" }
    local recipe, per_craft = hand_recipe(c, name)
    if recipe and depth < MAX_DEPTH then
      local crafts = math.ceil(need / per_craft)
      path[name] = true
      for _, ingredient in ipairs(recipe.ingredients or {}) do
        local short, missing, why = obtain(ingredient.name, math.ceil((tonumber(ingredient.amount) or 1) * crafts),
          depth + 1, path)
        if short then path[name] = nil; return short, missing, why end
      end
      path[name] = nil
      pool[name] = pool[name] + crafts * per_craft - need
      return nil
    end
    if recipe then
      reasons[#reasons + 1] = "too many recipe levels to hand-craft it"
    else
      reasons[#reasons + 1] = "not hand-craftable: " .. tostring(per_craft)
      local smelt, ore = smelt_recipe(c, name)
      if smelt and depth < MAX_DEPTH then
        local speed = furnace_for(smelt.category)
        if speed then
          local crafts = math.ceil(need / (M.output_per_craft(smelt, name) or 1))
          local seconds = crafts * (tonumber(smelt.energy) or 1) / math.max(speed, 0.01)
          if smelt_seconds + seconds > UNOBTAINABLE_SMELT_SECONDS then
            reasons[#reasons + 1] = string.format(
              "would smelt %d first (about %d s in own furnaces): get_items it or build smelting before this", need,
              math.ceil(smelt_seconds + seconds))
            return name, need, table.concat(reasons, "; ")
          end
          if not obtain(ore.name, crafts * (tonumber(ore.amount) or 1), depth + 1, path) then
            smelt_seconds = smelt_seconds + seconds
            return nil
          end
          reasons[#reasons + 1] = "not smelted: short of " .. ore.name
        else
          reasons[#reasons + 1] = "no idle own furnace smelts it (" .. tostring(smelt.category) .. ")"
        end
      end
    end
    if #natural_names(name) > 0 then return nil end
    reasons[#reasons + 1] = "nothing natural yields it"
    return name, need, table.concat(reasons, "; ")
  end
  local rows = {}
  for _, want in ipairs(wants) do
    local before = stocked(want.name)
    local short, missing, why = obtain(want.name, want.count, 0, {})
    if short then
      rows[#rows + 1] = { item = want.name, missing = math.max(1, want.count - before),
        short = short ~= want.name and { item = short, missing = missing } or nil, reason = why }
    end
  end
  return rows
end

-- Minutes own lines making an item at rate_per_min need for `missing` more,
-- rounded up to a tenth; nil without a rate.
function M.expected_minutes(missing, rate)
  if not (type(rate) == "number" and rate > 0) then return nil end
  return math.ceil(missing / rate * 10) / 10
end

local function tenth_down(x) return math.floor(x * 10) / 10 end

-- The dry-run bill (build_layout and connect_entities check_only), as
-- arithmetic over what the body carries, the registry's stock totals (as its
-- cursor last read them) and own line rates; nothing is reserved. For each
-- want {name, count} on the viewpoint's surface: carried, in_stock (own
-- holders), short (count less what is carried, queued in hand-crafting and
-- in stock), made_per_min (own lines, any row) and minutes_at_rate for the short at
-- that rate. The short splits into hand_craftable (with hand_craft_s for
-- those crafts and the intermediate ones, at the body's crafting speed,
-- within MAX_DEPTH recipe levels) and the items it then still lacks:
-- gatherable (nature yields them: mined or gathered) and needs_machine (no
-- hand recipe makes them: smelted, fluid or machine-only recipes, not yet
-- researched, or deeper than those levels). One pool of carried and stocked
-- items serves every row, direct counts first, so no stock counts twice.
-- walk_s_lower_bound: straight-line distance from the body to the nearest
-- own holder of an item it must fetch, at its running speed now.
function M.bill(c, wants)
  local body = c.get_item_count ~= nil
  local surface
  pcall(function() surface = c.surface.index end)
  local pool, stock = {}, {}
  local function available(name)
    if pool[name] == nil then
      local ok, totals = pcall(registry.stock_totals, { name }, surface)
      stock[name] = ok and totals[name] or 0
      pool[name] = (body and have(c, name) or 0) + stock[name]
    end
    return pool[name]
  end
  local speed = 1
  pcall(function() speed = speed + (tonumber(c.force.manual_crafting_speed_modifier) or 0) end)
  if body then pcall(function() speed = speed + (tonumber(c.character_crafting_speed_modifier) or 0) end) end
  speed = math.max(speed, 0.01)
  local rows, fetch = {}, {}
  for _, want in ipairs(wants) do
    local name, count = want.name, want.count
    local take = math.min(available(name), count)
    pool[name] = pool[name] - take
    local carried_now = body and carried(c, name) or 0
    rows[#rows + 1] = { item = name, count = count, carried = carried_now, in_stock = stock[name], short = count - take }
    if body and count > carried_now and stock[name] > 0 then fetch[name] = true end
  end
  for _, row in ipairs(rows) do
    local short = row.short
    local ok, rate = pcall(autonomy.producing, row.item, surface)
    if ok and type(rate) == "number" and rate > 0 then
      row.made_per_min = rate
      if short > 0 then row.minutes_at_rate = M.expected_minutes(short, rate) end
    end
    if short > 0 then
      local seconds, lacks = 0, {}
      local function lack(kind, name, n)
        lacks[kind] = lacks[kind] or {}
        lacks[kind][name] = (lacks[kind][name] or 0) + n
      end
      local function expand(name, need, depth, path)
        local recipe, per_craft = hand_recipe(c, name)
        if not recipe or depth >= MAX_DEPTH or path[name] then
          lack(#natural_names(name) > 0 and "gatherable" or "needs_machine", name, need)
          return false
        end
        local crafts = math.ceil(need / per_craft)
        seconds = seconds + crafts * (tonumber(recipe.energy) or 0.5) / speed
        path[name] = true
        for _, ingredient in ipairs(recipe.ingredients or {}) do
          local n = math.ceil((tonumber(ingredient.amount) or 1) * crafts)
          local take = math.min(available(ingredient.name), n)
          pool[ingredient.name] = pool[ingredient.name] - take
          if n > take then expand(ingredient.name, n - take, depth + 1, path) end
        end
        path[name] = nil
        pool[name] = available(name) + crafts * per_craft - need
        return true
      end
      if expand(row.item, short, 0, {}) then
        row.hand_craftable, row.hand_craft_s = short, math.ceil(seconds * 10) / 10
      end
      row.gatherable, row.needs_machine = lacks.gatherable, lacks.needs_machine
    end
  end
  local position = body and c.position
  if position and next(fetch) then
    local running
    pcall(function() running = tonumber(c.character_running_speed) end)
    local ok, nearest = pcall(registry.nearest_holders, fetch, position)
    if running and running > 0 and ok then
      for _, row in ipairs(rows) do
        local d2 = nearest[row.item]
        if d2 then row.walk_s_lower_bound = tenth_down(math.sqrt(d2) / (running * 60)) end
      end
    end
  end
  return rows
end

local function inventory_of(entity, id)
  local ok, inventory = pcall(entity.get_inventory, defines.inventory[id])
  return ok and inventory or nil
end

-- Nearest own furnace that smelts the recipe's category, is idle
-- (idle_furnace) and whose result holds nothing or the item; or `own`, the
-- furnace the frame loaded last, while its source holds only that ore.
-- Furnaces in avoid (by unit number) were seen fed or emptied by a line.
local function smelter(c, recipe, ore, item, own, avoid)
  local ok, furnaces = pcall(registry.machines, { "furnace" })
  local best, best_d
  for _, entry in ipairs(ok and type(furnaces) == "table" and furnaces or {}) do
    local e = entry.entity
    local ok_fit, fits = pcall(function()
      if not (e and e.valid and e.prototype.crafting_categories[recipe.category]) then return false end
      if avoid and avoid[e.unit_number] then return false end
      local source, result = inventory_of(e, "furnace_source"), inventory_of(e, "furnace_result")
      if not (source and result) then return false end
      if result.get_item_count() ~= result.get_item_count(item) then return false end
      if own and e == own then return source.get_item_count() == source.get_item_count(ore) end
      return idle_furnace(e)
    end)
    if ok_fit and fits then
      local d = dist_sq(c.position, e.position)
      if not best or d < best_d then best, best_d = e, d end
    end
  end
  return best
end

-- ------------------------------------------------------------------ runner

-- A frame claims count of its item for its consumer (parent); the item's
-- frames fetch until the body carries what all open claims total. path holds
-- the frame's own and its ancestors' items (a recipe cycle).
local function push(task, name, count, depth, parent)
  local path = { [name] = true }
  for item in pairs(parent and parent.path or {}) do path[item] = true end
  task._stack[#task._stack + 1] = { name = name, count = count, depth = depth, phase = "take",
    tried = {}, takes = 0, gathers = 0, path = path }
  if parent and task._claims then
    task._claims[name] = (task._claims[name] or 0) + count
    parent.claimed = parent.claimed or {}
    parent.claimed[name] = (parent.claimed[name] or 0) + count
  end
end

-- The frame's ingredients were consumed (or never will be): their claims end.
local function release(task, frame)
  for name, count in pairs(frame.claimed or {}) do
    task._claims[name] = math.max(0, (task._claims[name] or 0) - count)
  end
  frame.claimed = nil
end

local function pop(task)
  local frame = table.remove(task._stack)
  if frame and task._claims then release(task, frame) end
end

-- Whether supplying name for frame would recurse into an item being supplied
-- further up the same chain. A frame from a supply begun before paths
-- existed checks the whole stack.
local function cycles(task, frame, name)
  if frame.path then return frame.path[name] == true end
  for _, other in ipairs(task._stack) do if other.name == name then return true end end
  return false
end

-- What the body should carry of the frame's item: every open claim on it
-- (a supply begun before claims existed counts the frame alone).
local function wanted(task, frame)
  return task._claims and task._claims[frame.name] or frame.count
end

-- Called as listener(item, count) for each take from own stores (tasks.lua
-- keeps them as recent draws).
local draw_listener
function M.set_draw_listener(fn) draw_listener = fn end

local function note(task, kind, item, count)
  if count <= 0 then return end
  if kind == "taken" and draw_listener then pcall(draw_listener, item, count) end
  -- A supply begun by 0.21.0 has no smelted book.
  local book = task._report[kind] or {}
  task._report[kind] = book
  book[item] = (book[item] or 0) + count
end

local function shortfall(task, frame, missing, reason)
  local rows = task._shortfall
  if #rows < MAX_SHORTFALL_ROWS then
    rows[#rows + 1] = { item = frame.name, missing = missing, reason = reason, inventory_full = frame.full }
  end
end

function M.start(task)
  local c = companion.require_companion()
  if type(task.items) ~= "table" or #task.items == 0 then error("get_items requires an item and a count") end
  task._before, task._stack, task._shortfall, task._claims = {}, {}, {}, {}
  task._report = { taken = {}, crafted = {}, smelted = {}, gathered = {} }
  for index = #task.items, 1, -1 do
    local want = task.items[index]
    if type(want.name) ~= "string" or not prototypes.item[want.name] then
      error("no item called '" .. tostring(want.name) .. "'")
    end
    local count = tonumber(want.count)
    if not count or count % 1 ~= 0 or count < 1 then error("get_items count must be a positive integer") end
    want.count = count
    task._before[want.name] = have(c, want.name)
    -- Each wanted count is a total to carry, never added to another.
    task._claims[want.name] = math.max(task._claims[want.name] or 0, count)
    push(task, want.name, count, 0)
  end
end

-- At most one source scan (registry holders, nearby belts, own drills or the
-- natural search) per supply tick: a nested craft chain spreads its scans
-- over ticks instead of running several in one. false when this tick's scan
-- is spent; the frame then resumes next tick.
local function scan(task)
  if task._scanned then return false end
  task._scanned = true
  return true
end

-- Starts a frame's nested action. Its inputs are kept (fields the runner
-- replaces, never edits) so the frame can start it again once after an
-- enclosure step-out.
local function begin_sub(task, sub)
  local spec = {}
  for key, value in pairs(sub) do spec[key] = value end
  M.begin(task, "_sub", sub)
  task._sub_spec = spec
end

-- A nested walk ended BODY_ENCLOSED: start move_entity's escape through the
-- own blocker it names, toward the nested action's target (as build_plan's
-- placement approach does). task._step_out records the attempt; true once
-- the escape runs.
local function start_escape(task, result, target)
  local ok, blocker = pcall(function() return result.outcome.diagnostics.path.suggested_recovery end)
  if not (ok and type(blocker) == "table" and type(blocker.x) == "number" and type(blocker.y) == "number"
    and type(target) == "table") then
    task._step_out = { attempted = false, error = "the walk named no own blocker to step out through" }
    return false
  end
  local at = { x = blocker.x, y = blocker.y }
  task._step_out = { attempted = true, entity = { name = blocker.expected_name, x = at.x, y = at.y } }
  local started, err = pcall(M.begin, task, "_escape", { type = "move_entity", from = at, to = at,
    through = { x = target.x, y = target.y }, expected_name = blocker.expected_name })
  if not started then task._step_out.attempted, task._step_out.error = false, errors.plain(err) end
  return started
end

-- One frame step. Returns true when a nested action started or this tick's
-- scan is spent (either ends the tick).
local function advance(task, c, frame)
  local need = wanted(task, frame) - carried(c, frame.name)
  -- Output still in the crafting queue is on its way: never made twice.
  if need > 0 then need = need - craft.queued(c, frame.name) end
  if need <= 0 then pop(task); return false end

  -- The body cannot leave where it stands (a nested walk ended with
  -- START_COLLISION, or BODY_ENCLOSED with no step-out left): no other
  -- source is walked to in this supply.
  if task._pinned and (frame.phase == "take" or frame.phase == "smelt" or frame.phase == "gather") then
    frame.error, frame.phase = task._pinned, "end"
    return false
  end

  if frame.phase == "take" then
    -- Never walk to a source for more than the inventory has room for.
    local inventory = c.get_main_inventory()
    local room = inventory and inventory.get_insertable_count(frame.name) or need
    if room <= 0 then
      frame.error, frame.phase, frame.full = "my inventory is full", "end", true
      return false
    end
    if frame.takes < MAX_TAKES then
      if not scan(task) then return true end
      -- Chests and machine outputs first, then loose items at an own drill's
      -- drop position; nearby belts only when none holds it.
      local source
      if frame.belts then
        local more
        source, more = nearest_belt(c, task, frame)
        if more then return false end
      elseif frame.drops then
        source = nearest_drop(c, task, frame.name, frame.tried)
        if not source then frame.drops, frame.belts = nil, true; return false end
      else
        source = nearest_holder(c, task, frame.name, frame.tried)
        if not source then frame.drops = true; return false end
      end
      if source then
        frame.belts, frame.drops = nil, nil
        frame.takes, frame.tried[source.key] = frame.takes + 1, true
        local want = need
        local proto = prototypes.item[frame.name]
        if task.bulk and proto.place_result then want = math.max(need, tonumber(proto.stack_size) or need) end
        want = math.min(want, source.count, room)
        local sub
        if source.kind == "belt" then
          sub = { type = "pickup", target = source.position, item = frame.name, count = math.max(1, math.min(need, room)) }
        elseif source.kind == "ground" then
          -- A ground stack is picked up whole.
          sub = { type = "pickup", target = source.position, item = frame.name, count = source.count }
        else
          -- A landing pad's items are its main inventory (it has others).
          sub = { type = "extract", target = source.position, items = { [frame.name] = want },
            inventory = source.kind == "landing_pad" and "main" or nil }
        end
        frame.source_kind, frame.before = source.kind, have(c, frame.name)
        local ok, err = pcall(begin_sub, task, sub)
        if ok then return true end
        frame.error = tostring(err)
        return false
      end
    end
    frame.phase = "craft"
    return false
  end

  if frame.phase == "craft" then
    -- A later round follows only a round that queued all its crafts.
    if frame.craft_left and need > frame.craft_left then frame.phase = "end"; return false end
    local recipe, per_craft = hand_recipe(c, frame.name)
    if not recipe or frame.depth >= MAX_DEPTH then
      frame.craft_error = recipe and "too many recipe levels" or per_craft
      frame.phase = recipe and "gather" or "smelt"
      return false
    end
    local crafts = math.min(math.ceil(need / per_craft), MAX_CRAFTS)
    frame.phase, frame.recipe, frame.per_craft = "craft_start", recipe.name, per_craft
    -- Ingredients first (the first is fetched first); an ingredient already
    -- being supplied further up this chain is a cycle and is left to the craft.
    local ingredients = recipe.ingredients or {}
    for index = #ingredients, 1, -1 do
      local ingredient = ingredients[index]
      if ingredient.type ~= "fluid" and not cycles(task, frame, ingredient.name) then
        push(task, ingredient.name, math.ceil((tonumber(ingredient.amount) or 1) * crafts), frame.depth + 1, frame)
      end
    end
    return false
  end

  if frame.phase == "craft_start" then
    if task._claims then release(task, frame) end
    local all = math.ceil(need / frame.per_craft)
    local crafts = math.min(all, MAX_CRAFTS)
    -- A round the cap cut short comes back to the craft phase, which fetches
    -- and queues the rest, up to MAX_CRAFT_ROUNDS rounds; past them the end
    -- names the cap.
    frame.craft_rounds = (frame.craft_rounds or 0) + 1
    frame.crafts_queued = (frame.crafts_queued or 0) + crafts
    frame.craft_left = math.max(0, need - crafts * frame.per_craft)
    frame.craft_capped = all > crafts and frame.craft_rounds >= MAX_CRAFT_ROUNDS or nil
    frame.phase = all > crafts and not frame.craft_capped and "craft" or "end"
    frame.before = have(c, frame.name)
    local ok, err = pcall(begin_sub, task, { type = "craft", recipe = frame.recipe, count = crafts })
    if ok then frame.source_kind = "craft"; return true end
    frame.error = errors.plain(err)
    return false
  end

  if frame.phase == "smelt" then
    local recipe, ingredient = smelt_recipe(c, frame.name)
    if not recipe or frame.depth >= MAX_DEPTH or (frame.smelt_rounds or 0) >= MAX_SMELT_ROUNDS then
      frame.phase = "gather"
      return false
    end
    if not scan(task) then return true end
    local furnace = smelter(c, recipe, ingredient.name, frame.name, frame.smelt and frame.smelt.furnace, frame.smelt_avoid)
    if not furnace then
      frame.smelt_error = "no own furnace is free to smelt it (" .. recipe.category .. ")"
        .. (frame.smelt_avoid and "; a line feeds or empties the one it loaded" or "")
      frame.phase = "gather"
      return false
    end
    local per_craft = M.output_per_craft(recipe, frame.name) or 1
    local amount = tonumber(ingredient.amount) or 1
    local stack = tonumber(prototypes.item[ingredient.name] and prototypes.item[ingredient.name].stack_size) or amount
    local crafts = math.max(1, math.min(math.ceil(need / per_craft), math.floor(stack / amount)))
    local fuel
    local fuel_inventory = furnace.get_fuel_inventory()
    if fuel_inventory and fuel_inventory.is_empty() then fuel = M.fuel_item(c) or "coal" end
    -- The wait ends by this tick however the furnace's counts move: twice
    -- the smelting time at the furnace's speed, plus the stall allowance.
    local ok_speed, speed = pcall(function() return furnace.crafting_speed end)
    local seconds = crafts * (tonumber(recipe.energy) or 1) / math.max(ok_speed and tonumber(speed) or 1, 0.01)
    frame.smelt = { furnace = furnace, position = { x = furnace.position.x, y = furnace.position.y },
      ore = ingredient.name, ore_count = crafts * amount, fuel = fuel, wait_ticks = math.ceil(seconds * 120) + SMELT_STALL_TICKS }
    frame.phase = "smelt_load"
    -- The ore and fuel are supplied first, like a recipe's ingredients.
    if fuel and not cycles(task, frame, fuel) then push(task, fuel, SMELT_FUEL, frame.depth + 1, frame) end
    if not cycles(task, frame, ingredient.name) then
      push(task, ingredient.name, crafts * amount, frame.depth + 1, frame)
    end
    return false
  end

  if frame.phase == "smelt_load" then
    local s = frame.smelt
    if task._claims then release(task, frame) end
    local ore = math.min(carried(c, s.ore), s.ore_count)
    if ore <= 0 or not s.furnace.valid then
      frame.error, frame.phase = ore <= 0 and ("no " .. s.ore .. " to smelt") or "the furnace is gone", "gather"
      return false
    end
    local items = { [s.ore] = ore }
    if s.fuel and carried(c, s.fuel) > 0 then items[s.fuel] = math.min(SMELT_FUEL, carried(c, s.fuel)) end
    frame.phase = "smelt_wait"
    local ok, err = pcall(begin_sub, task, { type = "insert", target = s.position, items = items, auto_supply = false })
    if ok then return true end
    frame.error, frame.phase = tostring(err), "gather"
    return false
  end

  if frame.phase == "smelt_wait" then
    local s = frame.smelt
    if s.failed or not s.furnace.valid then
      frame.error, frame.phase = s.failed or "the furnace is gone", "gather"
      return false
    end
    -- The clock starts once the load is in (the walk there is not smelting).
    s.deadline = s.deadline or game.tick + (s.wait_ticks or 4 * SMELT_STALL_TICKS)
    if s.next_poll and game.tick < s.next_poll then return true end
    s.next_poll = game.tick + SMELT_POLL_TICKS
    local source, result = inventory_of(s.furnace, "furnace_source"), inventory_of(s.furnace, "furnace_result")
    local left, made = source and source.get_item_count(s.ore) or 0, result and result.get_item_count(frame.name) or 0
    -- The body's own load only lowers the ore and raises the product: more
    -- ore or fewer products means a line feeds or empties this furnace. The
    -- wait ends now with what it made, and later rounds pass it over.
    local foreign = s.left ~= nil and (left > s.left or made < s.made)
    if left ~= s.left or made ~= s.made then s.left, s.made, s.progress_tick = left, made, game.tick end
    local finished = left == 0 and not s.furnace.is_crafting()
    if not foreign and made < need and not finished and game.tick - s.progress_tick < SMELT_STALL_TICKS
      and game.tick < (s.deadline or math.huge) then return true end
    frame.smelt_rounds = (frame.smelt_rounds or 0) + 1
    frame.phase = "smelt"
    if foreign then
      frame.smelt_avoid = frame.smelt_avoid or {}
      if s.furnace.unit_number then frame.smelt_avoid[s.furnace.unit_number] = true end
      frame.smelt_error = "a line feeds or empties the furnace it loaded"
    end
    if made <= 0 then
      frame.smelt_error, frame.phase = foreign and frame.smelt_error or game.tick >= s.deadline and left > 0
        and "the furnace made none of this load in time (a line may feed or empty it)"
        or "the furnace smelted nothing (out of fuel or power?)", "gather"
      return false
    end
    frame.source_kind, frame.before = "smelt", have(c, frame.name)
    local ok, err = pcall(begin_sub, task, { type = "extract", target = s.position, items = { [frame.name] = made } })
    if ok then return true end
    frame.error, frame.phase = tostring(err), "gather"
    return false
  end

  if frame.phase == "gather" then
    -- A full inventory ends the frame as full, as the take phase does, so a
    -- layout's steps_when_full carries on instead of retrying the same tile.
    local inventory = c.get_main_inventory()
    if inventory and inventory.get_insertable_count(frame.name) <= 0 then
      frame.error, frame.phase, frame.full = "my inventory is full", "end", true
      return false
    end
    if frame.gathers < MAX_GATHERS then
      if frame.drills == nil then
        if #natural_names(frame.name) > 0 and not scan(task) then return true end
        frame.drills = drills_producing(c, frame.name)
      end
      -- Own drills' output was taken above when it could be; while none can
      -- be taken now (it feeds a furnace, or none is out yet), the rest is
      -- hand-gathered like any raw resource.
      if #natural_names(frame.name) > 0 and not scan(task) then return true end
      frame.covers = frame.covers or {}
      local entity, more = natural_source(c, frame.name, frame.covers)
      if more then return true end
      if entity then
        frame.gathers = frame.gathers + 1
        local cycles = entity.type == "resource" and math.min(need, MAX_RESOURCE_CYCLES) or 1
        frame.source_kind, frame.before = "gather", have(c, frame.name)
        local ok, err = pcall(begin_sub, task, { type = "mine", entity = entity, count = cycles,
          target = { x = entity.position.x, y = entity.position.y }, target_kind = "natural" })
        if ok then return true end
        frame.error = tostring(err)
      elseif frame.gathers == 0 then
        frame.gather_error = string.format("none within %d tiles to hand-gather", GATHER_RADII[#GATHER_RADII])
      end
    end
    frame.phase = "end"
    return false
  end

  -- end: name why this item is still short.
  local parts = {}
  if frame.drills and frame.drills > 0 then
    parts[#parts + 1] = string.format("%d own mining drill(s) produce it but none of their output can be taken now", frame.drills)
  elseif frame.takes == 0 then
    parts[#parts + 1] = "no own chest, landing pad, machine output or belt holds it"
  end
  if frame.craft_error then parts[#parts + 1] = "not hand-craftable: " .. frame.craft_error end
  if frame.craft_capped then
    parts[#parts + 1] = string.format("hand-crafting queued %d of %d crafts: get_items queues at most %d crafts"
      .. " per round and %d rounds per item", frame.crafts_queued, frame.crafts_queued + math.ceil(need / frame.per_craft),
      MAX_CRAFTS, MAX_CRAFT_ROUNDS)
  end
  if frame.smelt_error then parts[#parts + 1] = "not smelted: " .. frame.smelt_error end
  if frame.gather_error then parts[#parts + 1] = frame.gather_error end
  if frame.error then parts[#parts + 1] = "last attempt: " .. frame.error end
  local reason = #parts > 0 and table.concat(parts, "; ") or "every source ran dry"
  shortfall(task, frame, need, reason)
  pop(task)
  return false
end

local function finish(task, c)
  local missing, gained, crafting = {}, 0, {}
  for _, want in ipairs(task.items) do
    local queued = craft.queued(c, want.name)
    local count = carried(c, want.name) + queued
    gained = gained + math.max(0, count - (task._before[want.name] or 0))
    if count < want.count then missing[#missing + 1] = { item = want.name, missing = want.count - count } end
    if queued > 0 then crafting[#crafting + 1] = string.format("%d %s", queued, want.name) end
  end
  -- Any item may be used anywhere: the text says what is carried, not
  -- where it came from (outcome.supplied keeps that).
  local moved = false
  for _, kind in ipairs({ "taken", "crafted", "smelted", "gathered" }) do
    if next(task._report[kind] or {}) then moved = true end
  end
  local how = moved and "" or " (already carried)"
  if #crafting > 0 then how = how .. "; still in the crafting queue: " .. table.concat(crafting, ", ") end
  local report = { taken = task._report.taken, crafted = task._report.crafted, smelted = task._report.smelted,
    gathered = task._report.gathered }
  if #missing == 0 then
    local parts = {}
    for _, want in ipairs(task.items) do parts[#parts + 1] = string.format("%d %s", want.count, want.name) end
    local stepped = task._step_out and task._step_out.escaped and ("; " .. tostring(task._step_out.detail)) or ""
    return { status = "done", detail = "carrying " .. table.concat(parts, ", ") .. how .. stepped,
      outcome = { code = "SUPPLIED", supplied = report, step_out = task._step_out } }
  end
  -- What exists is carried; own lines that make a missing item say when the
  -- rest can be fetched (rate over the last minute).
  local parts, expected = {}, {}
  for _, row in ipairs(missing) do
    parts[#parts + 1] = string.format("%d %s", row.missing, row.item)
    local rate = autonomy.producing(row.item)
    if rate > 0 then
      row.rate_per_min = rate
      row.expected_minutes = M.expected_minutes(row.missing, rate)
      expected[#expected + 1] = string.format("%s at %s/min (the missing %d in about %s min)", row.item,
        rate, row.missing, row.expected_minutes)
    end
  end
  local reasons = {}
  for _, row in ipairs(task._shortfall) do reasons[#reasons + 1] = row.item .. ": " .. row.reason end
  -- Pinned in an enclosure: its code and the walk's diagnostics, and what
  -- the step-out did, so the plan's recovery and the bots see the cause.
  local enclosed = task._pinned and task._enclosure
  local step_out = task._step_out
  local code = enclosed and "BODY_ENCLOSED" or "SUPPLY_SHORTFALL"
  local stepped = ""
  if enclosed and step_out then
    stepped = step_out.escaped and ("; " .. tostring(step_out.detail) .. ", and the walk after it was still enclosed")
      or step_out.attempted and ("; stepping out failed: " .. tostring(step_out.error))
      or ("; no step-out started: " .. tostring(step_out.error))
  end
  return { status = gained > 0 and "partial" or "failed",
    detail = code .. ": missing " .. table.concat(parts, ", ") .. (moved and how or "") .. stepped
      .. (#reasons > 0 and (" — " .. table.concat(reasons, "; ")) or "")
      .. (#expected > 0 and ("; own machines make " .. table.concat(expected, ", ")) or ""),
    outcome = { code = code, missing = missing, shortfall = task._shortfall, supplied = report,
      diagnostics = enclosed and enclosed.diagnostics or nil, step_out = step_out } }
end

function M.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  -- An enclosure step-out runs to its end; out, the frame's nested action
  -- starts again, once. A failed one pins the supply.
  if task._escape then
    local escaped = M.step(task, "_escape")
    if not escaped then return nil end
    local frame = task._stack[#task._stack]
    if escaped.status == "done" then
      task._step_out.escaped, task._step_out.detail, task._enclosure = true, escaped.detail, nil
      if frame and task._sub_spec then
        frame.error = nil
        if frame.smelt then frame.smelt.failed = nil end
        local ok, err = pcall(begin_sub, task, task._sub_spec)
        if ok then return nil end
        frame.error = errors.plain(err)
      end
    else
      task._step_out.error = escaped.detail
      task._pinned = task._enclosure.detail
    end
  end
  if task._sub then
    local kind = task._sub.type
    local target = task._sub.target
    local result = M.step(task, "_sub")
    if not result then return nil end
    task.last_action = { action = kind, target = target and { x = target.x, y = target.y } or nil,
      status = result.status, code = result.outcome and result.outcome.code,
      detail = type(result.detail) == "string" and result.detail:sub(1, 240) or nil }
    -- Taking from a chest or machine (or loading a furnace) is a character
    -- transfer like any other.
    if kind == "extract" or kind == "insert" then factory_activity.record(kind, result.outcome) end
    if result.status == "failed" and type(result.outcome) == "table" and result.outcome.code == "START_COLLISION" then
      task._pinned = result.detail
    end
    local frame = task._stack[#task._stack]
    if frame and kind == "insert" then
      -- Ore and fuel went into a furnace: the smelt waits, or fails.
      if result.status == "failed" and frame.smelt then frame.smelt.failed = result.detail end
    elseif frame then
      local got = have(c, frame.name) - (frame.before or 0)
      local kinds = { craft = "crafted", gather = "gathered", smelt = "smelted" }
      note(task, kinds[frame.source_kind] or "taken", frame.name, got)
      if result.status ~= "done" and got <= 0 then frame.error = result.detail end
    end
    -- Enclosed by own entities: once per frame, step out and start the
    -- action again; else the supply is pinned and ends BODY_ENCLOSED.
    if result.status ~= "done" and type(result.outcome) == "table" and result.outcome.code == "BODY_ENCLOSED" then
      task._enclosure = { detail = result.detail, diagnostics = result.outcome.diagnostics }
      if frame and not frame.stepped_out then
        frame.stepped_out = true
        if start_escape(task, result, target) then return nil end
      end
      task._pinned = result.detail
    end
  end
  -- Bounded bookkeeping per tick; physical work happens in nested actions.
  task._scanned = nil
  for _ = 1, 32 do
    local frame = task._stack[#task._stack]
    if not frame then return finish(task, c) end
    if advance(task, c, frame) then return nil end
  end
  return nil
end

-- Embedded auto-supply for an action: run once, then report. Returns nil
-- while supplying, else the supply result (status done, partial or failed).
function M.ensure(owner, needs, options)
  if not owner._supply then
    local s = { items = needs, exclude = options and options.exclude, bulk = options and options.bulk }
    s.id = owner.id
    local ok, err = pcall(M.start, s)
    if not ok then return { status = "failed", detail = errors.plain(err) } end
    owner._supply = s
  end
  local ok, result = pcall(M.tick, owner._supply)
  if not ok then result = { status = "failed", detail = tostring(result) } end
  if result then
    owner._supply_result = { status = result.status,
      code = result.outcome and result.outcome.code,
      detail = type(result.detail) == "string" and result.detail:sub(1, 240) or nil,
      last_action = owner._supply.last_action }
    owner._supply = nil
  end
  return result
end

-- Pure, bounded state read: no stock/entity scan or native action. Nested
-- supply movement and final target approach are separate evidence.
function M.diagnostics(owner)
  if not owner then return nil end
  local s = owner._supply
  local frame = s and s._stack and s._stack[#s._stack]
  local sub = s and s._sub
  local walker = sub or owner
  local depth, seen = 0, {}
  while walker and not seen[walker] and depth < 8 do
    seen[walker], depth = true, depth + 1
    local next_walk = walker._walk or walker._approach and walker._approach.walk or walker.walker
    if not next_walk then break end
    walker = next_walk
  end
  local target = owner.target
  return { stage = s and "auto_supply" or (owner._supplied or owner.auto_supply == false) and "target" or "before_supply",
    target = target and { x = target.x, y = target.y } or nil,
    supply = s and { phase = frame and frame.phase, item = frame and frame.name,
      wanted = frame and frame.count, takes = frame and frame.takes,
      action = sub and sub.type, target = sub and sub.target,
      last_action = s.last_action } or nil,
    supply_result = owner._supply_result,
    shortfall = type(owner._shortfall) == "string" and owner._shortfall:sub(1, 240) or nil,
    route = walker and walker.phase and { phase = walker.phase, request_tick = walker.request_tick,
      requested_goal = walker.requested_goal, resolved_goal = walker.target,
      failure = walker.failure } or nil,
    route_depth_capped = depth == 8 or nil }
end

-- The get_items plan action {item, count}: carry at least count of item.
M.action = {
  runner = M,
  make_task = function(step) return { items = { { name = step.item, count = step.count } } } end,
  validate = function(step, index)
    if type(step.item) ~= "string" or step.item == "" then
      error("queue_plan get_items step " .. index .. " requires an item name")
    end
    local count = tonumber(step.count)
    if not count or count % 1 ~= 0 or count < 1 or count > 5000 then
      error("queue_plan get_items step " .. index .. " requires count as an integer from 1 to 5000")
    end
  end,
}

return M
