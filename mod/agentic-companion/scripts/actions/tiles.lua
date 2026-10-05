-- place_tiles {item, area? | positions?, auto_supply?}: lays landfill, stone
-- path, concrete, foundation or ice platform from the body's inventory, one
-- item per tile, the way a player brushes tiles: only within build distance,
-- at most PLACE_PER_TICK tiles a tick, nearest first, walking toward the
-- nearest tile still to do when none is in reach (a lake's middle becomes
-- reachable as its shore is filled). Where an item may go comes from its
-- place_as_tile_result (tile condition, collision condition, invert) and the
-- current tile's allows_being_covered, so every planet's rules come from the
-- game. Tiles already of that kind are counted, never paid for. A covered
-- mineable tile (stone path under concrete) gives its items back to the body,
-- as brushing over it does for a player. Only normal-quality items are laid.
-- Result: {tile, requested, placed, already, ineligible:[{x, y, code,
-- current?, liquid?, hint?}] (first 16), omitted_ineligible, consumed:{[item]: n},
-- returned?:{[item]: n}, shortfall?, remaining?}. Over RPC (check_only) it only reads: would_place,
-- items_needed, carried.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local supply = require("scripts.actions.supply")
local craft = require("scripts.actions.craft")

local M = {}

local MAX_TILES = 1024
local MAX_CHECK_AREA = 128 * 128 -- a check_only area reports its first MAX_TILES
local PLACE_PER_TICK = 8
local CLASSIFY_PER_TICK = 256 -- work items: 2 per tile read, 6 more per new tile kind
local MAX_ROWS = 16

local function point(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

-- ----------------------------------------------------------------- inputs

-- Integer tile positions, deduplicated, in input order: at most MAX_TILES,
-- plus how many more a check_only area holds. An area has no duplicates: it
-- is listed row by row up to MAX_TILES and the rest only counted.
local function expand(params, label, check_only)
  if (params.area == nil) == (params.positions == nil) then
    error(label .. " takes exactly one of area {left_top, right_bottom} or positions [{x, y}]", 0)
  end
  local tiles = {}
  if params.area ~= nil then
    local a = params.area
    if not (type(a) == "table" and point(a.left_top) and point(a.right_bottom)
      and a.right_bottom.x > a.left_top.x and a.right_bottom.y > a.left_top.y) then
      error(label .. " area must be {left_top:{x,y}, right_bottom:{x,y}} with right_bottom below and right of left_top", 0)
    end
    local x1, y1 = math.floor(a.left_top.x), math.floor(a.left_top.y)
    local x2, y2 = math.ceil(a.right_bottom.x) - 1, math.ceil(a.right_bottom.y) - 1
    local n = (x2 - x1 + 1) * (y2 - y1 + 1)
    if n > (check_only and MAX_CHECK_AREA or MAX_TILES) then
      error(string.format("%s area covers %d tiles; at most %d", label, n, check_only and MAX_CHECK_AREA or MAX_TILES), 0)
    end
    local count = 0
    for y = y1, y2 do
      for x = x1, x2 do
        if count >= MAX_TILES then break end
        count = count + 1
        tiles[count] = { x = x, y = y }
      end
      if count >= MAX_TILES then break end
    end
    return tiles, n - count
  else
    local list = params.positions
    if type(list) ~= "table" or #list < 1 or #list > MAX_TILES then
      error(string.format("%s positions must list 1-%d tiles", label, MAX_TILES), 0)
    end
    local seen = {}
    for i, p in ipairs(list) do
      if not point(p) then error(string.format("%s positions[%d] must be {x, y}", label, i - 1), 0) end
      local x, y = math.floor(p.x), math.floor(p.y)
      local key = x .. "," .. y
      if not seen[key] then
        seen[key] = true
        tiles[#tiles + 1] = { x = x, y = y }
      end
    end
  end
  return tiles, 0
end

-- The item and the tile it places, or an error.
local function tile_item(name, label)
  local item = type(name) == "string" and prototypes.item[name] or nil
  if not item then error(string.format("UNKNOWN_ITEM: %s: no item called '%s'", label, tostring(name)), 0) end
  local place = item.place_as_tile_result
  if not place then
    error(string.format("NOT_A_TILE_ITEM: %s places no tile%s", name, item.place_result and "; use place_entity" or ""), 0)
  end
  return item, place
end

-- ------------------------------------------------------------ eligibility

-- The item a tile prototype is placed with, else its own name.
local function placing_item(tile)
  local ok, items = pcall(function() return tile.items_to_place_this end)
  local first = ok and type(items) == "table" and items[1] or nil
  return first and first.name or tile.name
end

-- What the item does on a tile of this prototype: "eligible", "already" or
-- an ineligible row's {code, current, hint?}. It depends on the tile's kind
-- only, so callers memoise it by name.
local function classify_kind(place, tile_name, tp)
  if tile_name == place.result.name then return "already" end
  local blocked = tp.allows_being_covered == false
  local allowed = place.tile_condition
  if not blocked and allowed and #allowed > 0 then
    blocked = true
    for _, tile in ipairs(allowed) do if tile.name == tile_name then blocked = false end end
  end
  if not blocked then
    local mask = tp.collision_mask and tp.collision_mask.layers or {}
    local collides = false
    for layer in pairs(place.condition and place.condition.layers or {}) do
      if mask[layer] then collides = true end
    end
    blocked = collides ~= (place.invert == true)
  end
  if not blocked then return "eligible" end
  local row = { code = "TILE_INELIGIBLE", current = tile_name }
  -- A liquid tile names its liquid (lava and the oceans take foundation or
  -- ice platform, not landfill: the hint says which).
  local layers = tp.collision_mask and tp.collision_mask.layers or {}
  if layers.water_tile then
    local ok_fluid, fluid = pcall(function() return tp.fluid.name end)
    row.liquid = ok_fluid and fluid or nil
  end
  local ok, cover = pcall(function() return tp.default_cover_tile end)
  if ok and cover then row.hint = "use " .. placing_item(cover) end
  return row
end

-- The class of the tile t (memoised by its name in s.by_tile) and the work
-- it cost: 0 on a memo hit, 6 when the kind was read.
local function class_of(s, t)
  local name = t.name
  local class = s.by_tile[name]
  if class then return class, 0 end
  class = classify_kind(prototypes.item[s.item].place_as_tile_result, name, t.prototype)
  s.by_tile[name] = class
  return class, 6
end

-- A copy of a memoised ineligible row, so each tile's row has its own x, y.
local function row_copy(class)
  return { code = class.code, current = class.current, liquid = class.liquid, hint = class.hint }
end

local function note_ineligible(s, x, y, row)
  s.ineligible_count = s.ineligible_count + 1
  if #s.rows < MAX_ROWS then
    row.x, row.y = x, y
    s.rows[#s.rows + 1] = row
  end
end

-- Classifies tiles from s.index on while budget (work items) lasts: 1 per
-- chunk charted check and per uncharted tile, 2 per tile read, 6 more per
-- new tile kind. Returns
-- whether all are done and the work used.
local function classify_more(c, s, budget)
  if s.index > #s.tiles then return true, 0 end
  local used, surface, force = 0, c.surface, c.force
  while s.index <= #s.tiles do
    if used >= budget then return false, used end
    local tile = s.tiles[s.index]
    local key = math.floor(tile.x / 32) .. "," .. math.floor(tile.y / 32)
    if s.charted[key] == nil then
      s.charted[key] = force.is_chunk_charted(surface, { x = math.floor(tile.x / 32), y = math.floor(tile.y / 32) }) == true
      used = used + 1
    end
    local class, cost = { code = "TILE_UNCHARTED" }, 1
    if s.charted[key] then
      class, cost = class_of(s, surface.get_tile(tile.x, tile.y))
      cost = cost + 2
    end
    used = used + cost
    if class == "eligible" then s.eligible[#s.eligible + 1] = tile
    elseif class == "already" then s.already = s.already + 1
    else note_ineligible(s, tile.x, tile.y, row_copy(class)) end
    s.index = s.index + 1
  end
  return true, used
end

local function new_state(item, place, tiles)
  return { item = item.name, tile = place.result.name, tiles = tiles, index = 1, eligible = {},
    already = 0, rows = {}, ineligible_count = 0, charted = {}, by_tile = {}, returns = {} }
end

-- The items brushing over a tile of this kind gives back (memoised in
-- s.returns by name; false when it gives none).
local function covered_products(s, t)
  local name = t.name
  local products = s.returns[name]
  if products ~= nil then return products end
  products = false
  local ok, mineable = pcall(function() return t.prototype.mineable_properties end)
  if ok and mineable and mineable.minable then
    for _, product in ipairs(mineable.products or {}) do
      local count = product.type == "item" and (product.amount or product.amount_min) or 0
      if count > 0 then
        products = products or {}
        products[#products + 1] = { name = product.name, count = count }
      end
    end
  end
  s.returns[name] = products
  return products
end

-- Gives the covered tile's items to the body, spilling what does not fit.
local function give_back(task, c, products)
  task._returned = task._returned or {}
  for _, product in ipairs(products) do
    local kept = c.insert({ name = product.name, count = product.count })
    if kept < product.count then
      pcall(c.surface.spill_item_stack, { position = c.position,
        stack = { name = product.name, count = product.count - kept }, force = c.force, allow_belts = false })
    end
    task._returned[product.name] = (task._returned[product.name] or 0) + product.count
  end
end

-- --------------------------------------------------------------- the step

local Runner = {}
Runner.resume = supply.resume

function Runner.start(task)
  companion.require_companion()
  local label = "place_tiles"
  local item, place = tile_item(task.item, label)
  local tiles = expand(task, label, false)
  task._s = new_state(item, place, tiles)
  task._placed = 0
end

local function centre(tile) return { x = tile.x + 0.5, y = tile.y + 0.5 } end

-- The item laid: normal quality only, the quality remove_item takes.
local function carried(c, s) return c.get_item_count({ name = s.item, quality = "normal" }) end

local function result(task, ended)
  local s = task._s
  local requested = #s.tiles
  local remaining = #s.eligible
  local consumed = {}
  if task._placed > 0 then consumed[s.item] = task._placed end
  local status = task._placed + s.already == requested and "done"
    or (task._placed > 0 or s.already > 0) and "partial" or "failed"
  local code = ended or (status == "done" and "TILES_PLACED" or status == "partial" and "TILES_PARTIAL"
    or s.rows[1] and s.rows[1].code or "TILES_NOT_PLACED")
  local outcome = { code = code, tile = s.tile, requested = requested, placed = task._placed, already = s.already,
    ineligible = s.rows, omitted_ineligible = math.max(0, s.ineligible_count - #s.rows), consumed = consumed,
    returned = task._returned, shortfall = task._shortfall, remaining = remaining > 0 and remaining or nil }
  local detail = string.format("place_tiles %s: placed %d, already %d, ineligible %d of %d tiles", s.tile,
    task._placed, s.already, s.ineligible_count, requested)
  if remaining > 0 then detail = detail .. string.format(" — %d not placed (%s)", remaining, ended or "no items left") end
  if task._returned then
    local parts = {}
    for name, n in pairs(task._returned) do parts[#parts + 1] = string.format("%d %s", n, name) end
    table.sort(parts)
    detail = detail .. "; got back " .. table.concat(parts, ", ")
  end
  if task._shortfall then detail = detail .. " — " .. task._shortfall end
  if s.rows[1] and s.rows[1].hint then detail = detail .. " — " .. s.rows[1].current .. ": " .. s.rows[1].hint end
  return { status = status, detail = detail, outcome = outcome }
end

function Runner.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  local s = task._s
  if not classify_more(c, s, CLASSIFY_PER_TICK) then return nil end
  if #s.eligible == 0 then return result(task) end
  -- Supply once, for every eligible tile; a shortfall lays what is carried.
  if task.auto_supply ~= false and not task._supplied then
    if carried(c, s) < #s.eligible then
      local supplied = supply.ensure(task, { { name = s.item, count = #s.eligible } }, { bulk = true })
      if not supplied then return nil end
      if supplied.status ~= "done" then task._shortfall = supplied.detail end
    end
    task._supplied = true
  end
  if carried(c, s) == 0 then
    if craft.awaits(c, s.item, 1) then return nil end
    return result(task, task._placed > 0 and "TILES_PARTIAL" or "NO_CARRIED_ITEMS")
  end
  -- Keep walking to the chosen tile; then brush what is in reach.
  if task._walk_to then
    local reached = approach.ensure(task, c, centre(task._walk_to), c.build_distance)
    if type(reached) == "table" then return result(task, "TILE_UNREACHABLE") end
    if reached ~= "ok" then return nil end
    task._walk_to = nil
  end
  local p, reach = c.position, c.build_distance
  local px, py, reach_sq = p.x - 0.5, p.y - 0.5, reach * reach
  local near, nearest, nearest_d = {}, nil, nil
  for i, tile in ipairs(s.eligible) do
    local dx, dy = tile.x - px, tile.y - py
    local d = dx * dx + dy * dy
    if d <= reach_sq then near[#near + 1] = { i = i, d = d } end
    if not nearest_d or d < nearest_d then nearest, nearest_d = tile, d end
  end
  if #near == 0 then
    task._walk_to = nearest
    return nil
  end
  table.sort(near, function(a, b) return a.d < b.d or a.d == b.d and a.i < b.i end)
  local surface, done, out = c.surface, {}, nil
  for k = 1, math.min(PLACE_PER_TICK, #near) do
    local index = near[k].i
    local tile = s.eligible[index]
    -- The tile may have changed since it was classified (the owner, a robot).
    local now = surface.get_tile(tile.x, tile.y)
    local class = class_of(s, now)
    if class == "already" then
      s.already = s.already + 1
    elseif class ~= "eligible" then
      note_ineligible(s, tile.x, tile.y, row_copy(class))
    else
      -- Take the item first; lay the tile only for what was taken.
      if c.remove_item({ name = s.item, count = 1, quality = "normal" }) ~= 1 then out = "NO_CARRIED_ITEMS"; break end
      local products = covered_products(s, now)
      local covered = now.name
      surface.set_tiles({ { name = s.tile, position = { x = tile.x, y = tile.y } } }, true, "abort_on_collision", true, true)
      local after = surface.get_tile(tile.x, tile.y)
      if after.name == s.tile then
        task._placed = task._placed + 1
        -- A covered mineable tile is gone unless it became the hidden tile.
        if products and after.hidden_tile ~= covered then give_back(task, c, products) end
      else
        c.insert({ name = s.item, count = 1, quality = "normal" })
        note_ineligible(s, tile.x, tile.y, { code = "TILE_OCCUPIED", current = after.name })
      end
    end
    done[#done + 1] = index
  end
  -- Swap-remove the handled tiles, highest index first.
  table.sort(done, function(a, b) return a > b end)
  local eligible = s.eligible
  for _, index in ipairs(done) do
    eligible[index] = eligible[#eligible]
    eligible[#eligible] = nil
  end
  if out then return result(task, task._placed > 0 and "TILES_PARTIAL" or out) end
  if #eligible == 0 then return result(task) end
  return nil
end

-- The plan action for tasks.register_action.
M.action = {
  runner = Runner,
  make_task = function(step)
    return { item = step.item, area = step.area, positions = step.positions, auto_supply = step.auto_supply }
  end,
  validate = function(step, index)
    local label = "queue_plan place_tiles step " .. index
    if step.check_only then error(label .. ": check_only is the place_tiles dry run, not a plan step", 0) end
    tile_item(step.item, label)
    expand(step, label, false)
  end,
  -- Walking and brushing: about a second's work per eight tiles.
  budget_steps = function(step)
    local n = type(step.positions) == "table" and #step.positions or MAX_TILES
    if type(step.area) == "table" and point(step.area.left_top) and point(step.area.right_bottom) then
      n = math.abs((step.area.right_bottom.x - step.area.left_top.x) * (step.area.right_bottom.y - step.area.left_top.y))
    end
    return math.max(1, math.ceil(n / PLACE_PER_TICK))
  end,
}

-- RPC place_tiles {.., check_only = true}: what the area needs, read only,
-- as a job (one work item per tile read).
M.check_job = {
  start = function(params)
    local label = "place_tiles"
    if type(params) ~= "table" or params.check_only ~= true then
      error(label .. " over RPC is a dry run: pass check_only = true, and queue it as a plan step to lay tiles", 0)
    end
    companion.require_companion()
    local item, place = tile_item(params.item, label)
    local tiles, omitted = expand(params, label, true)
    local s = new_state(item, place, tiles)
    s.omitted = omitted
    return s
  end,
  step = function(s, budget)
    local c = companion.require_companion()
    local finished, used = classify_more(c, s, math.max(1, budget.left))
    budget.left = budget.left - used
    if not finished then return nil end
    return { check_only = true, tile = s.tile, item = s.item, requested = #s.tiles, would_place = #s.eligible,
      already = s.already, ineligible = s.rows, omitted_ineligible = math.max(0, s.ineligible_count - #s.rows),
      items_needed = #s.eligible, carried = carried(c, s), omitted = s.omitted > 0 and s.omitted or nil }
  end,
}

M.MAX_TILES, M.PLACE_PER_TICK = MAX_TILES, PLACE_PER_TICK

return M
