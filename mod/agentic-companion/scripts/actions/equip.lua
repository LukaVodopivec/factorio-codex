-- equip {armor?: name | false, put?: [{name, x?, y?}], take?: [{name} | {x, y}],
-- auto_supply?}: the character's own armor window. The armor is worn from
-- the inventory (auto-supply fetches or crafts it) and the old armor, with
-- its equipment, takes its inventory slot; false takes the armor off. Then
-- equipment comes out of the worn armor's grid into the inventory, and
-- carried equipment goes in, at x, y or the first place it fits. Order:
-- armor, take, put. No reach, no walking; one tick once supplied. Nothing is
-- lost: an armor change, or taking out equipment that adds inventory slots
-- (a toolbelt), that would shrink the inventory over occupied slots is
-- refused (INVENTORY_WOULD_OVERFLOW). Only normal-quality equipment is put in.
-- Result: {armor, grid?:{width, height, equipment:[{name, x, y}],
-- movement_bonus, inventory_bonus, battery_capacity_j, stored_j,
-- max_solar_w}, changed:[...], problems?:[{code, ...}], shortfall?}.
local companion = require("scripts.companion")
local supply = require("scripts.actions.supply")
local craft = require("scripts.actions.craft")

local M = {}

local MAX_ENTRIES = 20
local MAX_PUT_TRIES = 8 -- grid.put calls per entry once the Lua fit check found room

local function count_field(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

local function equipment_of(name)
  local item = type(name) == "string" and prototypes.item[name] or nil
  return item and item.place_as_equipment_result
end

local function validate(step, label)
  local armor = step.armor
  if armor ~= nil and armor ~= false then
    local item = type(armor) == "string" and prototypes.item[armor] or nil
    if not (item and item.type == "armor") then error(label .. ": armor must be an armor item name, or false to take it off", 0) end
  end
  for _, field in ipairs({ "put", "take" }) do
    local list = step[field]
    if list ~= nil and (type(list) ~= "table" or #list < 1 or #list > MAX_ENTRIES) then
      error(string.format("%s %s must list 1-%d entries", label, field, MAX_ENTRIES), 0)
    end
  end
  for i, entry in ipairs(step.put or {}) do
    local at = string.format("%s put[%d]", label, i - 1)
    if type(entry) ~= "table" or not equipment_of(entry.name) then
      error(at .. " must name an equipment item ({name, x?, y?})", 0)
    end
    if (entry.x == nil) ~= (entry.y == nil) or entry.x ~= nil and not (count_field(entry.x) and count_field(entry.y)) then
      error(at .. " x and y go together, as grid cells from 0", 0)
    end
  end
  for i, entry in ipairs(step.take or {}) do
    local at = string.format("%s take[%d]", label, i - 1)
    local by_name = type(entry) == "table" and type(entry.name) == "string"
    local by_cell = type(entry) == "table" and count_field(entry.x) and count_field(entry.y)
    if by_name == by_cell then error(at .. " must be {name} or {x, y}", 0) end
  end
  if armor == nil and step.put == nil and step.take == nil then error(label .. " needs armor, put or take", 0) end
end

-- ------------------------------------------------------------------ reading

local function armor_slot(c)
  local inventory = c.get_inventory(defines.inventory.character_armor)
  return inventory and inventory[1]
end

-- Inventory slots an armor stack adds (its prototype and its grid).
local function bonus(stack)
  if not (stack and stack.valid_for_read) then return 0 end
  local n = tonumber(stack.prototype.get_inventory_size_bonus()) or 0
  local grid = stack.grid
  if grid then n = n + (tonumber(grid.inventory_bonus) or 0) end
  return n
end

-- True when the last `lost` main slots are empty and `keep` (a slot index
-- that will hold an item) lies before them.
local function fits(main, lost, keep)
  if lost <= 0 then return true end
  local size = #main
  if keep and keep > size - lost then return false end
  for i = size - lost + 1, size do
    if main[i].valid_for_read then return false end
  end
  return true
end

local function grid_view(grid)
  local rows = {}
  for _, eq in ipairs(grid.equipment) do rows[#rows + 1] = { name = eq.name, x = eq.position.x, y = eq.position.y } end
  table.sort(rows, function(a, b) return a.y < b.y or a.y == b.y and a.x < b.x end)
  return { width = grid.width, height = grid.height, equipment = rows, movement_bonus = grid.movement_bonus,
    inventory_bonus = grid.inventory_bonus, battery_capacity_j = grid.battery_capacity,
    stored_j = grid.available_in_batteries, max_solar_w = grid.max_solar_energy * 60 }
end

-- Free cells of a grid, as occupied["x,y"].
local function occupancy(grid)
  local used = {}
  for _, eq in ipairs(grid.equipment) do
    local shape = eq.shape
    for dy = 0, shape.height - 1 do
      for dx = 0, shape.width - 1 do used[(eq.position.x + dx) .. "," .. (eq.position.y + dy)] = true end
    end
  end
  return used
end

-- Row-major top-left cells where a w x h piece fits the free cells.
local function free_spots(grid, used, w, h)
  local spots = {}
  for y = 0, grid.height - h do
    for x = 0, grid.width - w do
      local free = true
      for dy = 0, h - 1 do
        for dx = 0, w - 1 do if used[(x + dx) .. "," .. (y + dy)] then free = false end end
      end
      if free then spots[#spots + 1] = { x = x, y = y } end
    end
  end
  return spots
end

-- ------------------------------------------------------------------ runner

local Runner = {}
Runner.resume = supply.resume

function Runner.start(task)
  companion.require_companion()
  validate(task, "equip")
end

-- What must be carried: the armor (unless worn) and each put item.
local function needs(c, task)
  local want, order = {}, {}
  local function add(name, n)
    if not want[name] then order[#order + 1] = name end
    want[name] = (want[name] or 0) + n
  end
  local slot = armor_slot(c)
  local worn = slot and slot.valid_for_read and slot.name or nil
  if type(task.armor) == "string" and worn ~= task.armor then add(task.armor, 1) end
  for _, entry in ipairs(task.put or {}) do add(entry.name, 1) end
  local list = {}
  for _, name in ipairs(order) do list[#list + 1] = { name = name, count = want[name] } end
  return list
end

local function failed(code, detail, extra)
  local outcome = { code = code }
  for k, v in pairs(extra or {}) do outcome[k] = v end
  return { status = "failed", detail = code .. ": " .. detail, outcome = outcome }
end

-- Wears, swaps or takes off the armor. Returns a change label, or nil and
-- the failed result. Nothing changes on a refusal.
local function change_armor(c, task, slot)
  local main = c.get_main_inventory()
  local worn = slot.valid_for_read and slot.name or nil
  if task.armor == false then
    if not worn then return nil end
    local lost = bonus(slot)
    local keep
    for i = 1, #main - lost do
      if not main[i].valid_for_read then keep = i; break end
    end
    if not (keep and fits(main, lost, keep)) then
      return nil, failed("INVENTORY_WOULD_OVERFLOW", string.format("taking off the %s removes %d inventory slots;"
        .. " free them (and one more for the armor) first", worn, lost))
    end
    if not main[keep].swap_stack(slot) then return nil, failed("ARMOR_NOT_REMOVED", "the game kept the " .. worn .. " on") end
    return "armor off: " .. worn
  end
  if type(task.armor) ~= "string" or worn == task.armor then return nil end
  local stack, index = main.find_item_stack(task.armor)
  if not stack then
    return nil, failed("NOT_CARRIED", "I carry no " .. task.armor, { shortfall = task._shortfall })
  end
  local lost = bonus(slot) - bonus(stack)
  if not fits(main, lost, worn and index or nil) then
    return nil, failed("INVENTORY_WOULD_OVERFLOW", string.format("the %s gives %d fewer inventory slots than the %s;"
      .. " free the last %d slots first", task.armor, lost, worn, lost))
  end
  if not slot.swap_stack(stack) then return nil, failed("ARMOR_NOT_WORN", "the game refused to put on the " .. task.armor) end
  return "armor on: " .. task.armor
end

-- The worn armor's grid (made when the armor has one and it is missing).
local function worn_grid(slot)
  if not slot.valid_for_read then return nil end
  local grid = slot.grid
  if not grid and slot.prototype.equipment_grid then grid = slot.create_grid() end
  return grid
end

local function take_one(c, grid, entry)
  local eq = entry.name and grid.find(entry.name) or (not entry.name and grid.get({ x = entry.x, y = entry.y }))
  if not eq then
    return nil, { code = "NOT_IN_GRID", name = entry.name, x = entry.x, y = entry.y }
  end
  local result = eq.prototype.take_result
  local item = result and result.name or eq.name
  -- Equipment that adds slots (a toolbelt) shrinks the inventory when taken:
  -- its last slots must be free, and one before them for the taken item.
  local lost = tonumber(eq.inventory_bonus) or 0
  if lost > 0 then
    local main = c.get_main_inventory()
    local keep
    for i = 1, #main - lost do
      if not main[i].valid_for_read then keep = i; break end
    end
    if not (keep and fits(main, lost, keep)) then
      return nil, { code = "INVENTORY_WOULD_OVERFLOW", name = eq.name, slots = lost }
    end
  elseif not c.can_insert({ name = item, count = 1 }) then
    return nil, { code = "INVENTORY_FULL", name = eq.name }
  end
  local taken = grid.take({ equipment = eq })
  if taken then
    local kept = c.insert(taken)
    if kept < taken.count then
      pcall(c.surface.spill_item_stack, { position = c.position, stack = { name = taken.name, count = taken.count - kept,
        quality = taken.quality }, force = c.force, allow_belts = false })
    end
  end
  return "took " .. eq.name
end

-- Takes the carried normal-quality item first and puts the equipment in for
-- it; the item goes back when no spot takes it.
local function put_one(c, grid, entry, used)
  local proto = equipment_of(entry.name)
  if c.remove_item({ name = entry.name, count = 1, quality = "normal" }) ~= 1 then
    return nil, { code = "NOT_CARRIED", name = entry.name }
  end
  local placed
  if entry.x ~= nil then
    placed = grid.put({ name = proto.name, position = { x = entry.x, y = entry.y } })
  else
    local shape = proto.shape
    local spots = free_spots(grid, used, shape.width, shape.height)
    for k = 1, math.min(#spots, MAX_PUT_TRIES) do
      placed = grid.put({ name = proto.name, position = spots[k] })
      if placed then break end
    end
  end
  if not placed then
    c.insert({ name = entry.name, count = 1, quality = "normal" })
    return nil, { code = "EQUIPMENT_DOES_NOT_FIT", name = entry.name, x = entry.x, y = entry.y }
  end
  for dy = 0, placed.shape.height - 1 do
    for dx = 0, placed.shape.width - 1 do used[(placed.position.x + dx) .. "," .. (placed.position.y + dy)] = true end
  end
  return string.format("put %s at %d,%d", placed.name, placed.position.x, placed.position.y)
end

function Runner.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  if task.auto_supply ~= false and not task._supplied then
    local short = {}
    for _, need in ipairs(needs(c, task)) do
      if c.get_item_count(need.name) < need.count then short[#short + 1] = need end
    end
    if #short > 0 then
      local supplied = supply.ensure(task, short, { bulk = true })
      if not supplied then return nil end
      if supplied.status ~= "done" then task._shortfall = supplied.detail end
    end
    task._supplied = true
  end
  for _, need in ipairs(needs(c, task)) do
    if craft.awaits(c, need.name, need.count) then return nil end
  end
  local slot = armor_slot(c)
  if not slot then return failed("NO_ARMOR_SLOT", "this body has no armor slot") end
  -- Everything that can refuse the whole step is checked before a change.
  local target = task.armor == false and nil or type(task.armor) == "string" and task.armor
    or slot.valid_for_read and slot.name or nil
  local target_proto = target and prototypes.item[target]
  if (task.put or task.take) and not (target_proto and target_proto.equipment_grid) then
    return failed("NO_GRID", (target or "no armor") .. " has no equipment grid")
  end
  local changed, problems = {}, {}
  local change, refusal = change_armor(c, task, slot)
  if refusal then return refusal end
  if change then changed[#changed + 1] = change end
  local grid = (task.put or task.take) and worn_grid(slot) or nil
  for _, entry in ipairs(task.take or {}) do
    local done, problem = take_one(c, grid, entry)
    changed[#changed + 1] = done
    problems[#problems + 1] = problem
  end
  local used = grid and occupancy(grid)
  for _, entry in ipairs(task.put or {}) do
    local done, problem = put_one(c, grid, entry, used)
    changed[#changed + 1] = done
    problems[#problems + 1] = problem
  end
  local view = slot.valid_for_read and worn_grid(slot)
  local outcome = { armor = slot.valid_for_read and slot.name or false, grid = view and grid_view(view) or nil,
    changed = changed, problems = #problems > 0 and problems or nil, shortfall = task._shortfall }
  local status = #problems == 0 and "done" or #changed > 0 and "partial" or "failed"
  outcome.code = status == "done" and "EQUIPPED" or status == "partial" and "EQUIP_PARTIAL" or problems[1].code
  local detail = #changed > 0 and ("equip: " .. table.concat(changed, ", ")) or "equip: nothing changed"
  if #problems > 0 then
    local codes = {}
    for _, p in ipairs(problems) do codes[#codes + 1] = p.code .. (p.name and (" " .. p.name) or "") end
    detail = detail .. " — " .. table.concat(codes, "; ")
  end
  if task._shortfall then detail = detail .. " — " .. task._shortfall end
  return { status = status, detail = detail, outcome = outcome }
end

-- The plan action for tasks.register_action.
M.action = {
  runner = Runner,
  make_task = function(step)
    return { armor = step.armor, put = step.put, take = step.take, auto_supply = step.auto_supply }
  end,
  validate = function(step, index) validate(step, "queue_plan equip step " .. index) end,
}

return M
