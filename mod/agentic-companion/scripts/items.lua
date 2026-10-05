-- Item keys and spoil reads shared by every summary of items.
--   key(name, quality)   "name" for normal quality, "name@quality" otherwise,
--                        so a summary never counts a rare plate as a normal
--                        one (nothing over-reports what supply can move)
--   sum_contents(inv)    {[key] = count} of an inventory's get_contents()
--   spoilable(name)      whether the item spoils (cached per name)
--   spoil(inv, names)    {[name] = {spoils_in_s, spoil_percent_max}} for the
--                        spoilable names given, one pass over the slots
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

return M
