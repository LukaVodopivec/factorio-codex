-- Item keys, spoil reads, real-stack moves and safe spills shared by the mod.
--   key(name, quality)   "name" for normal quality, "name@quality" otherwise,
--                        so a summary never counts a rare plate as a normal
--                        one (nothing over-reports what supply can move)
--   sum_contents(inv)    {[key] = count} of an inventory's get_contents()
--   spoilable(name)      whether the item spoils (cached per name)
--   spoil(inv, names)    {[name] = {spoils_in_s, spoil_percent_max}} for the
--                        spoilable names given, one pass over the slots
--   quality_name(q)      a quality prototype, name or nil as a name
--   move(from, to, name, quality, count)
--                        real stacks of name from inventory `from` into `to`
--   move_stacks(stacks, to, name, quality, count, source)
--                        the same from any list of stacks (a belt line's)
--   spill(surface, position, stack, record)
--                        spills a stack never onto a belt nor for robots
local M = {}

function M.key(name, quality)
  if quality == nil or quality == "normal" then return name end
  if type(quality) ~= "string" then
    local ok, quality_name = pcall(function() return quality.name end)
    quality = ok and quality_name or nil
    if quality == nil or quality == "normal" then return name end
  end
  return name .. "@" .. quality
end

-- One get_contents() of an inventory (nil reads as empty), by key.
function M.sum_contents(inventory)
  local out = {}
  if not inventory then return out end
  local ok, rows = pcall(inventory.get_contents)
  for _, row in ipairs(ok and rows or {}) do
    if type(row.name) == "string" then
      local key = M.key(row.name, row.quality)
      out[key] = (out[key] or 0) + (tonumber(row.count) or 0)
    end
  end
  return out
end

local spoils = {}
function M.spoilable(name)
  local known = spoils[name]
  if known == nil then
    local ok, ticks = pcall(function() return prototypes.item[name].get_spoil_ticks() end)
    known = ok and type(ticks) == "number" and ticks > 0
    spoils[name] = known
  end
  return known
end

-- For each spoilable name, its soonest spoil in seconds (the stack with the
-- lowest spoil_tick, minus now) and the most spoiled stack's percent: one
-- read of each slot (valid_for_read and name), two more for a matching
-- stack. Returns the rows and the engine reads it made.
function M.spoil(inventory, names)
  local wanted, any = {}, false
  for _, name in ipairs(names) do
    if M.spoilable(name) then wanted[name], any = true, true end
  end
  if not (any and inventory) then return {}, 0 end
  local rows, reads = {}, 1
  local ok, size = pcall(function() return #inventory end)
  for index = 1, ok and size or 0 do
    local stack = inventory[index]
    reads = reads + 2
    if stack.valid_for_read and wanted[stack.name] then
      local tick, percent = stack.spoil_tick, stack.spoil_percent
      reads = reads + 2
      local row = rows[stack.name] or {}
      rows[stack.name] = row
      if type(tick) == "number" and tick > 0 then
        local seconds = math.max(0, math.floor((tick - game.tick) / 60 + 0.5))
        if row.spoils_in_s == nil or seconds < row.spoils_in_s then row.spoils_in_s = seconds end
      end
      if type(percent) == "number" then
        percent = math.floor(percent * 1000 + 0.5) / 10
        if row.spoil_percent_max == nil or percent > row.spoil_percent_max then row.spoil_percent_max = percent end
      end
    end
  end
  return rows, reads
end

function M.quality_name(quality)
  if quality == nil then return "normal" end
  if type(quality) == "string" then return quality end
  local ok, name = pcall(function() return quality.name end)
  return ok and type(name) == "string" and name or "normal"
end

-- Hands up to `count` items of one real stack to `to` (anything with insert:
-- an inventory, an entity, the body). The engine's own transfer_stack moves
-- them into `buffer`, a one-slot script inventory, so the split keeps each
-- item's spoil, durability, ammo and quality; `to` inserts that stack, and
-- what it did not take goes back onto the stack it came from, else to the
-- source (put_back). Returns the count `to` took.
local function give(stack, to, count, buffer, put_back)
  local held = buffer[1]
  held.transfer_stack(stack, count)
  local offered = held.valid_for_read and held.count or 0
  local taken = offered > 0 and math.min(to.insert(held) or 0, offered) or 0
  if taken >= offered then held.clear() elseif taken > 0 then held.count = offered - taken end
  if held.valid_for_read then stack.transfer_stack(held) end
  if held.valid_for_read then
    local back = math.min(put_back(held) or 0, held.count)
    if back >= held.count then held.clear() elseif back > 0 then held.count = held.count - back end
  end
  if held.valid_for_read then
    error(string.format("ITEM_MOVE_UNRETURNED: %d %s could not go back where they came from", held.count, held.name), 0)
  end
  return taken
end

-- Moves up to `count` of `name` (of `quality`; any quality when nil) from the
-- real stacks listed, in order, into `to`. Nothing is created by name: the
-- stacks themselves are handed over, and each stack's own count before and
-- after says what left it. A source that lost less than `to` gained (one that
-- ignored the split) gives up the difference through source.remove; it may
-- lose one more, when a returned part folds a partly used item into its
-- stack. source.put_back(stack) returns what it took back. Stops when `to`
-- takes less than offered; returns the count `to` gained and whether it did.
function M.move_stacks(stacks, to, name, quality, count, source)
  local moved, short, buffer = 0, false, nil
  for _, stack in ipairs(stacks) do
    if moved >= count then break end
    if stack.valid_for_read and stack.name == name
      and (quality == nil or M.quality_name(stack.quality) == quality) then
      local q, before = M.quality_name(stack.quality), stack.count
      local want = math.min(before, count - moved)
      buffer = buffer or game.create_inventory(1)
      local taken = give(stack, to, want, buffer, source.put_back)
      local left = before - (stack.valid_for_read and stack.count or 0)
      if left < taken then source.remove({ name = name, quality = q, count = taken - left }) end
      moved = moved + taken
      if taken < want then short = true; break end
    end
  end
  if buffer then buffer.destroy() end
  return moved, short
end

-- move_stacks over an inventory's slots, in slot order.
function M.move(from, to, name, quality, count)
  local stacks = {}
  for index = 1, #from do stacks[index] = from[index] end
  return M.move_stacks(stacks, to, name, quality, count, { remove = from.remove, put_back = from.insert })
end

-- Spills a stack (a LuaItemStack or {name, count, quality}) around position
-- without a force, which would mark it for deconstruction and send robots,
-- and never onto a belt. Adds the count spilled to record (count, items by
-- key, position) when given and returns it (0 when the spill failed).
function M.spill(surface, position, stack, record)
  local count = tonumber(stack.count) or 0
  if not pcall(surface.spill_item_stack, { position = position, stack = stack, allow_belts = false }) then count = 0 end
  if record and count > 0 then
    local key = M.key(stack.name, stack.quality)
    record.count = (record.count or 0) + count
    record.items = record.items or {}
    record.items[key] = (record.items[key] or 0) + count
    record.position = { x = position.x, y = position.y }
  end
  return count
end

return M
