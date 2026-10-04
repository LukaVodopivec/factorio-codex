-- get_items and auto-supply: the body fetches what a step needs the way a
-- player would. For each wanted item, in order: take it from the nearest own
-- chest or machine output (then belt), walking there; else hand-craft it,
-- supplying the recipe's ingredients the same way first (so intermediates
-- follow); else hand-gather it, only when no own mining drill produces it.
-- Whatever is still missing is a named shortfall. Every move is physical:
-- the nested walk/extract/pickup/craft/mine actions keep reach and time.
--
-- A supply task is { items = {{name, count}, ...} } where count is the total
-- the body should carry; exclude = {x, y} is never taken from (an insert's
-- own target); bulk = true takes up to a stack of a placeable item from a
-- source, so a plan placing many of one item fetches them once.
local companion = require("scripts.companion")
local walk = require("scripts.actions.walk")
local mine = require("scripts.actions.mine")
local pickup = require("scripts.actions.pickup")
local craft = require("scripts.actions.craft")
local factory_activity = require("scripts.factory_activity")
local registry = require("scripts.registry")

local M = {}

local MAX_DEPTH = 4          -- recipe levels supplied below a wanted item
local MAX_TAKES = 6          -- sources tried per item
local MAX_GATHERS = 8        -- hand-mining actions per item
local MAX_RESOURCE_CYCLES = 50
local MAX_CRAFTS = 100
local MAX_SHORTFALL_ROWS = 8
local GATHER_RADII = { 8, 16, 32, 48, 64 }
local GATHER_LIMIT = 100     -- natural entities read per query
-- Belts are not listed by the registry: only belts this near the body are
-- searched (an area query of bounded size and count, never the whole force).
local BELT_SEARCH_RADIUS = 48
local BELT_SEARCH_LIMIT = 64
local CHEST_TYPES = { container = true, ["logistic-container"] = true }
local NATURAL_TYPES = { "simple-entity", "tree", "resource" }

-- Nested physical actions. transfer.lua registers extract here itself
-- (it requires this module for insert's auto-supply).
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
local NESTED_FIELDS = { "_supply", "_sub", "_clear", "_exit" }
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

-- --------------------------------------------------------------- reading

local function carried(c, name) return c.get_item_count(name) end

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
    local inventory = CHEST_TYPES[entity.type] and entity.get_inventory(defines.inventory.chest)
      or entity.get_output_inventory()
    return inventory and inventory.get_item_count(item) or 0
  end)
  return ok and tonumber(count) or 0
end

-- Nearest own chest or machine output holding the item (the registry's
-- holders); a belt near the body only when no chest or machine holds any.
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
            kind = entity.type == "transport-belt" and "belt" or CHEST_TYPES[entity.type] and "chest" or "machine_output" }
        end
      end
    end
  end
  return best
end

local function nearest_holder(c, task, item, tried)
  local holders = {}
  local ok, entries = pcall(registry.list, "holders")
  for _, entry in ipairs(ok and entries or {}) do holders[#holders + 1] = entry.entity end
  return nearest_of(c, task, item, tried, holders, false)
end

local function nearest_belt(c, task, item, tried)
  local ok, belts = pcall(c.surface.find_entities_filtered, { position = c.position, radius = BELT_SEARCH_RADIUS,
    force = c.force, type = "transport-belt", limit = BELT_SEARCH_LIMIT })
  return nearest_of(c, task, item, tried, ok and type(belts) == "table" and belts or {}, true)
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

-- Nearest natural entity (resource tile, tree, rock) in charted land around
-- the body that yields the item. The engine filters by the names that yield
-- it, each query reads at most GATHER_LIMIT entities, and small radii come
-- first, so a forest or ore patch never means a large read; an item nothing
-- natural yields makes no query.
local function natural_source(c, item)
  local names = natural_names(item)
  if #names == 0 then return nil end
  local chunks = {}
  for _, radius in ipairs(GATHER_RADII) do
    local best, best_d
    local ok, found = pcall(c.surface.find_entities_filtered,
      { position = c.position, radius = radius, name = names, limit = GATHER_LIMIT })
    for _, entity in ipairs(ok and found or {}) do
      if entity.valid then
        local position = entity.position
        local key = math.floor(position.x / 32) .. "," .. math.floor(position.y / 32)
        if chunks[key] == nil then chunks[key] = charted(c, position) end
        if chunks[key] then
          local d = dist_sq(c.position, position)
          if not best or d < best_d then best, best_d = entity, d end
        end
      end
    end
    if best then return best end
  end
  return nil
end

-- ------------------------------------------------------------------ runner

local function push(task, name, count, depth)
  task._stack[#task._stack + 1] = { name = name, count = count, depth = depth, phase = "take",
    tried = {}, takes = 0, gathers = 0 }
end

local function in_stack(task, name)
  for _, frame in ipairs(task._stack) do if frame.name == name then return true end end
  return false
end

local function note(task, kind, item, count)
  if count <= 0 then return end
  local book = task._report[kind]
  book[item] = (book[item] or 0) + count
end

local function shortfall(task, frame, missing, reason)
  local rows = task._shortfall
  if #rows < MAX_SHORTFALL_ROWS then
    rows[#rows + 1] = { item = frame.name, missing = missing, reason = reason }
  end
end

function M.start(task)
  local c = companion.require_companion()
  if type(task.items) ~= "table" or #task.items == 0 then error("get_items requires an item and a count") end
  task._before, task._stack, task._shortfall = {}, {}, {}
  task._report = { taken = {}, crafted = {}, gathered = {} }
  for index = #task.items, 1, -1 do
    local want = task.items[index]
    if type(want.name) ~= "string" or not prototypes.item[want.name] then
      error("no item called '" .. tostring(want.name) .. "'")
    end
    local count = tonumber(want.count)
    if not count or count % 1 ~= 0 or count < 1 then error("get_items count must be a positive integer") end
    want.count = count
    task._before[want.name] = carried(c, want.name)
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

-- One frame step. Returns true when a nested action started or this tick's
-- scan is spent (either ends the tick).
local function advance(task, c, frame)
  local need = frame.count - carried(c, frame.name)
  if need <= 0 then table.remove(task._stack); return false end

  if frame.phase == "take" then
    -- Never walk to a source for more than the inventory has room for.
    local inventory = c.get_main_inventory()
    local room = inventory and inventory.get_insertable_count(frame.name) or need
    if room <= 0 then
      frame.error, frame.phase = "my inventory is full", "end"
      return false
    end
    if frame.takes < MAX_TAKES then
      if not scan(task) then return true end
      -- Chests and machine outputs first; nearby belts only when none holds it.
      local source
      if frame.belts then source = nearest_belt(c, task, frame.name, frame.tried)
      else
        source = nearest_holder(c, task, frame.name, frame.tried)
        if not source then frame.belts = true; return false end
      end
      if source then
        frame.belts = nil
        frame.takes, frame.tried[source.key] = frame.takes + 1, true
        local want = need
        local proto = prototypes.item[frame.name]
        if task.bulk and proto.place_result then want = math.max(need, tonumber(proto.stack_size) or need) end
        want = math.min(want, source.count, room)
        local sub
        if source.kind == "belt" then
          sub = { type = "pickup", target = source.position, item = frame.name, count = math.max(1, math.min(need, room)) }
        else
          sub = { type = "extract", target = source.position, items = { [frame.name] = want } }
        end
        frame.source_kind, frame.before = source.kind, carried(c, frame.name)
        local ok, err = pcall(M.begin, task, "_sub", sub)
        if ok then return true end
        frame.error = tostring(err)
        return false
      end
    end
    frame.phase = "craft"
    return false
  end

  if frame.phase == "craft" then
    local recipe, per_craft = hand_recipe(c, frame.name)
    if not recipe or frame.depth >= MAX_DEPTH then
      frame.craft_error = recipe and "too many recipe levels" or per_craft
      frame.phase = "gather"
      return false
    end
    local crafts = math.min(math.ceil(need / per_craft), MAX_CRAFTS)
    frame.phase, frame.recipe, frame.per_craft = "craft_start", recipe.name, per_craft
    -- Ingredients first (the first is fetched first); an ingredient already
    -- being supplied further up is a cycle and is left to the craft.
    local ingredients = recipe.ingredients or {}
    for index = #ingredients, 1, -1 do
      local ingredient = ingredients[index]
      if ingredient.type ~= "fluid" and not in_stack(task, ingredient.name) then
        push(task, ingredient.name, math.ceil((tonumber(ingredient.amount) or 1) * crafts), frame.depth + 1)
      end
    end
    return false
  end

  if frame.phase == "craft_start" then
    frame.phase = "end"
    local crafts = math.min(math.ceil(need / frame.per_craft), MAX_CRAFTS)
    frame.before = carried(c, frame.name)
    local ok, err = pcall(M.begin, task, "_sub", { type = "craft", recipe = frame.recipe, count = crafts })
    if ok then frame.source_kind = "craft"; return true end
    frame.error = tostring(err):gsub("^.-:%d+:%s*", "")
    return false
  end

  if frame.phase == "gather" then
    if frame.gathers < MAX_GATHERS then
      if frame.drills == nil then
        if #natural_names(frame.name) > 0 and not scan(task) then return true end
        frame.drills = drills_producing(c, frame.name)
      end
      if frame.drills == 0 then
        if #natural_names(frame.name) > 0 and not scan(task) then return true end
        local entity = natural_source(c, frame.name)
        if entity then
          frame.gathers = frame.gathers + 1
          local cycles = entity.type == "resource" and math.min(need, MAX_RESOURCE_CYCLES) or 1
          frame.source_kind, frame.before = "gather", carried(c, frame.name)
          local ok, err = pcall(M.begin, task, "_sub", { type = "mine", entity = entity, count = cycles,
            target = { x = entity.position.x, y = entity.position.y }, target_kind = "natural" })
          if ok then return true end
          frame.error = tostring(err)
        elseif frame.gathers == 0 then
          frame.gather_error = string.format("none within %d tiles to hand-gather", GATHER_RADII[#GATHER_RADII])
        end
      end
    end
    frame.phase = "end"
    return false
  end

  -- end: name why this item is still short.
  local reason
  if frame.drills and frame.drills > 0 then
    reason = string.format("%d own mining drill(s) produce it but none is stored where Codex can take it", frame.drills)
  else
    local parts = {}
    if frame.takes == 0 then parts[#parts + 1] = "no own chest, machine output or belt holds it" end
    if frame.craft_error then parts[#parts + 1] = "not hand-craftable: " .. frame.craft_error end
    if frame.gather_error then parts[#parts + 1] = frame.gather_error end
    if frame.error then parts[#parts + 1] = "last attempt: " .. frame.error end
    reason = #parts > 0 and table.concat(parts, "; ") or "every source ran dry"
  end
  shortfall(task, frame, need, reason)
  table.remove(task._stack)
  return false
end

local function summary_list(book)
  local names, parts = {}, {}
  for name in pairs(book) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do parts[#parts + 1] = string.format("%d %s", book[name], name) end
  return table.concat(parts, ", ")
end

local function finish(task, c)
  local missing, gained = {}, 0
  for _, want in ipairs(task.items) do
    local have = carried(c, want.name)
    gained = gained + math.max(0, have - (task._before[want.name] or 0))
    if have < want.count then missing[#missing + 1] = { item = want.name, missing = want.count - have } end
  end
  local ways = {}
  for _, kind in ipairs({ "taken", "crafted", "gathered" }) do
    local list = summary_list(task._report[kind])
    if list ~= "" then ways[#ways + 1] = kind .. " " .. list end
  end
  local how = #ways > 0 and (" (" .. table.concat(ways, "; ") .. ")") or " (already carried)"
  local report = { taken = task._report.taken, crafted = task._report.crafted, gathered = task._report.gathered }
  if #missing == 0 then
    local parts = {}
    for _, want in ipairs(task.items) do parts[#parts + 1] = string.format("%d %s", want.count, want.name) end
    return { status = "done", detail = "carrying " .. table.concat(parts, ", ") .. how,
      outcome = { code = "SUPPLIED", supplied = report } }
  end
  local parts = {}
  for _, row in ipairs(missing) do parts[#parts + 1] = string.format("%d %s", row.missing, row.item) end
  local reasons = {}
  for _, row in ipairs(task._shortfall) do reasons[#reasons + 1] = row.item .. ": " .. row.reason end
  return { status = gained > 0 and "partial" or "failed",
    detail = "SUPPLY_SHORTFALL: missing " .. table.concat(parts, ", ") .. (#ways > 0 and how or "")
      .. (#reasons > 0 and (" — " .. table.concat(reasons, "; ")) or ""),
    outcome = { code = "SUPPLY_SHORTFALL", missing = missing, shortfall = task._shortfall, supplied = report } }
end

function M.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  if task._sub then
    local kind = task._sub.type
    local result = M.step(task, "_sub")
    if not result then return nil end
    -- Taking from a chest or machine is a character transfer like any other.
    if kind == "extract" then factory_activity.record("extract", result.outcome) end
    local frame = task._stack[#task._stack]
    if frame then
      local got = carried(c, frame.name) - (frame.before or 0)
      note(task, frame.source_kind == "craft" and "crafted" or frame.source_kind == "gather" and "gathered" or "taken",
        frame.name, got)
      if result.status ~= "done" and got <= 0 then frame.error = result.detail end
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
    if not ok then return { status = "failed", detail = tostring(err):gsub("^.-:%d+:%s*", "") } end
    owner._supply = s
  end
  local ok, result = pcall(M.tick, owner._supply)
  if not ok then result = { status = "failed", detail = tostring(result) } end
  if result then owner._supply = nil end
  return result
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
