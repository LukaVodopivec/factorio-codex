-- Honest item-on-ground pickup through the sole character's LuaControl state.
-- The caller supplies the exact observed stack; Factorio performs the pickup.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")

local M = {}
local TARGET_RADIUS = 0.01
local PICKUP_TIMEOUT_TICKS = 120

local function stop(c)
  c.picking_state = false
end

local function stack_snapshot(entity)
  if not (entity and entity.valid and entity.type == "item-entity") then return nil end
  local stack = entity.stack
  if not (stack and stack.valid_for_read) then return nil end
  return stack.name, stack.count
end

local function matching_target(surface, target, item, count)
  local match
  for _, entity in ipairs(surface.find_entities_filtered({
    position = target, radius = TARGET_RADIUS, type = "item-entity",
  })) do
    local name, available = stack_snapshot(entity)
    if name == item and available == count then
      if match then return nil, "more than one exact matching ground stack occupies the observed position" end
      match = entity
    end
  end
  if not match then return nil, "the exact observed ground stack is gone or changed" end
  return match
end

function M.start(task)
  local c = companion.require_companion()
  if type(task.target) ~= "table" or type(task.target.x) ~= "number" or type(task.target.y) ~= "number" then
    error("pickup requires target = {x, y}")
  end
  if type(task.item) ~= "string" or task.item == "" then error("pickup requires an item name") end
  local count = tonumber(task.count)
  if not count or count % 1 ~= 0 or count < 1 then error("pickup count must be a positive integer") end
  task.count = count
  local entity, reason = matching_target(c.surface, task.target, task.item, count)
  if not entity then error(reason) end
  task._entity = entity
  task._inventory_before = c.get_main_inventory().get_item_count(task.item)
end

local function fail(c, detail)
  stop(c)
  return { status = "failed", detail = detail }
end

function M.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the Codex character is gone" } end
  local inventory = c.get_main_inventory()
  local gained = inventory.get_item_count(task.item) - task._inventory_before
  local name, remaining = stack_snapshot(task._entity)

  if task._picking_started then
    local depleted = task.count - (remaining or 0)
    if not name then
      if gained == task.count then
        stop(c)
        return { status = "done", detail = string.format(
          "physically picked up %d %s; inventory delta %d and selected ground stack depleted",
          task.count, task.item, gained) }
      end
      return fail(c, string.format(
        "the selected ground stack disappeared but inventory gained %d of the expected %d %s",
        gained, task.count, task.item))
    end
    if name ~= task.item or remaining > task.count or depleted ~= gained then
      return fail(c, "the selected ground stack or inventory changed without matching pickup evidence")
    end
    if gained == task.count then
      stop(c)
      return { status = "done", detail = string.format(
        "physically picked up %d %s; inventory delta %d and selected ground stack depleted",
        task.count, task.item, gained) }
    end
    if not inventory.can_insert({ name = task.item, count = task.count - gained }) then
      return fail(c, string.format("Codex inventory became full after picking up %d of %d %s", gained, task.count, task.item))
    end
    if game.tick - task._picking_started_tick >= PICKUP_TIMEOUT_TICKS then
      return fail(c, string.format("physical pickup made no complete progress within %d ticks", PICKUP_TIMEOUT_TICKS))
    end
    if c.selected ~= task._entity then c.update_selected_entity(task._entity.position) end
    if c.selected ~= task._entity then
      return fail(c, "could not reselect the exact ground stack")
    end
    c.picking_state = true
    return nil
  end

  if name ~= task.item or remaining ~= task.count then
    return fail(c, "the exact observed ground stack was invalidated before pickup")
  end
  if not inventory.can_insert({ name = task.item, count = task.count }) then
    return fail(c, "Codex inventory cannot hold the exact observed ground stack")
  end
  local reach = math.max((tonumber(c.item_pickup_distance) or 0) - 0.25, 0.1)
  local reached = approach.ensure(task, c, task._entity.position, reach)
  if reached ~= "ok" then
    if type(reached) == "table" then return fail(c, reached.detail) end
    return nil
  end
  name, remaining = stack_snapshot(task._entity)
  if name ~= task.item or remaining ~= task.count then
    return fail(c, "the exact observed ground stack was invalidated during approach")
  end
  c.update_selected_entity(task._entity.position)
  if c.selected ~= task._entity then
    return fail(c, "could not select the exact ground stack")
  end
  task._picking_started = true
  task._picking_started_tick = game.tick
  c.picking_state = true
  return nil
end

return M
