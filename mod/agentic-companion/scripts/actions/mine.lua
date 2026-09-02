-- Mine exactly the visible entity occupying the requested coordinate.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local M = {}
local NATURAL_MINABLE_TYPES = { resource = true, tree = true, ["simple-entity"] = true }

local function occupies(e, target)
  local box = e.selection_box or e.bounding_box
  if box then
    return target.x >= box.left_top.x and target.x < box.right_bottom.x
      and target.y >= box.left_top.y and target.y < box.right_bottom.y
  end
  return math.floor(e.position.x) == math.floor(target.x) and math.floor(e.position.y) == math.floor(target.y)
end

local function entity_amount(e)
  if not (e and e.valid) then return nil end
  local ok, amount = pcall(function() return e.amount end)
  if ok and type(amount) == "number" then return amount end
  return nil
end

local function quality_name(quality)
  if type(quality) == "string" then return quality end
  if quality == nil then return nil end
  local ok, name = pcall(function() return quality.name end)
  if ok and type(name) == "string" then return name end
  return nil
end

local function normal_filter_name(filter)
  if type(filter) == "string" then return filter end
  if type(filter) ~= "table" or type(filter.name) ~= "string" then return nil end
  if filter.quality == nil then return filter.name end
  if quality_name(filter.quality) ~= "normal" then return nil end
  if filter.comparator == nil or filter.comparator == "=" then return filter.name end
  return nil
end

-- Physical character mining cannot complete when its inventory cannot accept
-- the entity's products. Fail before starting the mining state instead of
-- waiting until the bridge timeout or bypassing the character with scripted
-- entity mining.
local function character_accepts_products(inv, e)
  local required = {}
  local products = e.prototype.mineable_properties.products or {}
  for _, product in ipairs(products) do
    if (product.type == nil or product.type == "item") and product.name then
      local count = tonumber(product.amount) or tonumber(product.amount_max)
        or tonumber(product.amount_min) or 1
      required[product.name] = (required[product.name] or 0) + math.max(1, math.ceil(count))
    end
  end
  local names = {}
  for name in pairs(required) do names[#names + 1] = name end
  table.sort(names)

  -- LuaControl.can_insert only means that some of a stack fits, and separate
  -- queries can double-count shared empty slots. Simulate allocation from the
  -- read-only inventory slot state so the preflight neither creates nor moves
  -- any item. Existing partial stacks are consumed first, followed by matching
  -- filtered slots and then shared unfiltered slots in deterministic order.
  local available, filtered_empty, shared_empty = {}, {}, {}
  local last = #inv
  local ok_bar, bar = pcall(function() return inv.get_bar() end)
  if ok_bar and type(bar) == "number" and bar > 0 then last = math.min(last, bar - 1) end
  for index = 1, last do
    local stack = inv[index]
    local ok_filter, filter = pcall(function() return inv.get_filter(index) end)
    if not ok_filter then filter = nil end
    if stack and stack.valid_for_read then
      if required[stack.name] and quality_name(stack.quality) == "normal" then
        local stack_size = tonumber(stack.prototype and stack.prototype.stack_size) or stack.count
        available[stack.name] = (available[stack.name] or 0) + math.max(0, stack_size - stack.count)
      end
    elseif filter then
      local filter_name = normal_filter_name(filter)
      if filter_name then
        filtered_empty[filter_name] = (filtered_empty[filter_name] or 0) + 1
      end
    else
      shared_empty[#shared_empty + 1] = index
    end
  end

  for _, name in ipairs(names) do
    local remaining = required[name] - (available[name] or 0)
    local proto = prototypes and prototypes.item and prototypes.item[name]
    local stack_size = tonumber(proto and proto.stack_size)
    if remaining > 0 and not stack_size then return false end
    local reserved = filtered_empty[name] or 0
    if remaining > 0 and reserved > 0 then
      local used = math.min(reserved, math.ceil(remaining / stack_size))
      filtered_empty[name] = reserved - used
      remaining = remaining - used * stack_size
    end
    while remaining > 0 and #shared_empty > 0 do
      table.remove(shared_empty)
      remaining = remaining - stack_size
    end
    if remaining > 0 then return false end
  end
  return true
end

function M.start(task)
  local c = companion.require_companion()
  local target = task.target
  if type(target) ~= "table" or type(target.x) ~= "number" or type(target.y) ~= "number" then error("mine requires target = {x, y}") end
  local count = tonumber(task.count) or 1
  if count ~= math.floor(count) or count < 1 or count > 200 then error("mine count must be an integer from 1 to 200") end
  local candidates = c.surface.find_entities_filtered({ area = { { target.x, target.y }, { target.x + 0.001, target.y + 0.001 } } })
  local found
  for _, e in ipairs(candidates) do
    local physically_allowed = NATURAL_MINABLE_TYPES[e.type]
      or (e.force == c.force and e.type ~= "character")
    local mineable = e.prototype and e.prototype.mineable_properties
    if e.valid and physically_allowed and mineable and mineable.minable and occupies(e, target) then
      if found then error("more than one minable entity occupies that coordinate; observe again and choose an unambiguous point") end
      found = e
    end
  end
  if not found then error(string.format("nothing minable occupies exact coordinate (%.1f, %.1f)", target.x, target.y)) end
  if count > 1 and found.type ~= "resource" then error("mine count greater than 1 is only valid for resources") end
  task._entity, task._entity_name = found, found.name
  task._requested, task._completed, task._actual_gain = count, 0, 0
end

local function partial_failure(task, reason)
  return {
    status = "failed",
    detail = string.format("mining %s stopped: requested %d cycles, completed %d, actual gain %d items — %s",
      task._entity_name, task._requested, task._completed, task._actual_gain, reason),
  }
end

function M.tick(task)
  local c, e = companion.get(), task._entity
  if not c then return partial_failure(task, "the Codex character is gone") end
  if not task._mining_started then
    if not (e and e.valid) then
      if task._completed > 0 then return partial_failure(task, "the initially selected resource was exhausted") end
      return partial_failure(task, "the exact target was removed before mining started")
    end
    local reached = approach.ensure(task, c, e.position, c.resource_reach_distance)
    if type(reached) == "table" then return reached end
    if reached ~= "ok" then return nil end
    local inv = c.get_main_inventory()
    if not inv then return { status = "failed", detail = "the Codex character has no inventory" } end
    if not character_accepts_products(inv, e) then
      return partial_failure(task, "Codex inventory is full")
    end
    task._target_amount = entity_amount(e)
    task._inventory_before = inv.get_item_count()
    -- mining_state targets the control's selected entity; the position alone
    -- does not select one for a script-created character. Select through the
    -- physical LuaControl API and refuse to mine a different overlapping
    -- entity.
    c.update_selected_entity(e.position)
    if c.selected ~= e then
      return partial_failure(task, "could not select the exact mining target")
    end
    task._mining_started = true
    c.mining_state = { mining = true, position = e.position }
    return nil
  end

  local current_amount = entity_amount(e)
  local target_changed = not (e and e.valid)
    or (task._target_amount ~= nil and current_amount ~= nil and current_amount < task._target_amount)
  if not target_changed then
    -- A real connected client can clear LuaPlayer.selected from its native
    -- input state between ticks. Reassert the already-resolved exact entity
    -- and physical mining state; never resolve or switch to a nearby target.
    if c.selected ~= e then c.update_selected_entity(e.position) end
    if c.selected ~= e then
      c.mining_state = { mining = false }
      return partial_failure(task, "could not reselect the exact mining target")
    end
    c.mining_state = { mining = true, position = e.position }
    return nil
  end

  c.mining_state = { mining = false }
  local inv = c.get_main_inventory()
  local gained = inv and (inv.get_item_count() - task._inventory_before) or 0
  if gained <= 0 then
    return partial_failure(task, "the exact target changed without mined items reaching Codex inventory")
  end
  task._completed = task._completed + 1
  task._actual_gain = task._actual_gain + gained
  task._mining_started = false
  if task._completed >= task._requested then
    return {
      status = "done",
      detail = string.format("mined %s at exact coordinate: requested %d cycles, completed %d, actual gain %d items",
        task._entity_name, task._requested, task._completed, task._actual_gain),
    }
  end
  if not (e and e.valid) then return partial_failure(task, "the initially selected resource was exhausted") end
  return nil
end

return M
