-- Honest item pickup by the sole character: an exact observed ground stack
-- through Factorio's own picking, or items riding a transport belt at the
-- observed position through an exact, conserved transfer from that belt's
-- lanes into the character. Nothing is created, and only the requested item
-- leaves the belt.
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

-- The third result counts the ground stacks at the position, whatever they hold.
local function matching_target(surface, target, item, count)
  local match, stacks = nil, 0
  for _, entity in ipairs(surface.find_entities_filtered({
    position = target, radius = TARGET_RADIUS, type = "item-entity",
  })) do
    local name, available = stack_snapshot(entity)
    if name then stacks = stacks + 1 end
    if name == item and available == count then
      if match then return nil, "more than one exact matching ground stack occupies the observed position", stacks end
      match = entity
    end
  end
  if not match then return nil, "the exact observed ground stack is gone or changed", stacks end
  return match
end

-- Belt pickup. Items ride a belt's two lanes a quarter tile either side of its
-- centre line. Native picking would take every item kind within
-- item_pickup_distance, on either lane and on neighbouring belts, and its
-- inventory gain cannot be told apart from hand-crafting or the owner's own gains.
-- So the body stands beside the lane that carries the item (never on the
-- belt, which would carry it away) and, while the belt's centre is within
-- item_pickup_distance of the body, the requested item moves from the tile's
-- transport lines into the inventory: what the lines give up is exactly what
-- the inventory takes, and that is the reported count. The inventory must be
-- able to hold the whole outstanding count before anything leaves the belt;
-- nothing is ever spilled or created.
local LANE_OFFSET = 0.25
local UNSUPPORTED_BELT_TYPES = { "underground-belt", "splitter", "loader", "loader-1x1", "linked-belt" }
local LANE_NAMES = { "left", "right" }

local function belt_at(surface, target)
  for _, entity in ipairs(surface.find_entities_filtered({ position = target, type = "transport-belt" })) do
    if entity.valid and entity.type == "transport-belt" then return entity end
  end
  return nil
end

local function lane_count(belt, lane, item)
  local ok, count = pcall(function() return belt.get_transport_line(lane).get_item_count(item) end)
  return ok and tonumber(count) or 0
end

-- Lane 1 is the left lane in the belt's direction of travel, lane 2 the right.
local function lane_point(belt, lane)
  local dx, dy = 0, -1
  if belt.direction == defines.direction.east then dx, dy = 1, 0
  elseif belt.direction == defines.direction.south then dx, dy = 0, 1
  elseif belt.direction == defines.direction.west then dx, dy = -1, 0 end
  local side = lane == 1 and LANE_OFFSET or -LANE_OFFSET
  return { x = belt.position.x + side * dy, y = belt.position.y - side * dx }
end

-- "left lane (west side)": the side of the belt the body must stand on.
local function lane_label(belt, lane)
  local point = lane_point(belt, lane)
  local dx, dy = point.x - belt.position.x, point.y - belt.position.y
  local side = dx < 0 and "west" or dx > 0 and "east" or dy < 0 and "north" or "south"
  return string.format("%s lane (%s side)", LANE_NAMES[lane], side)
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
  local entity, reason, stacks = matching_target(c.surface, task.target, task.item, count)
  if not entity then
    -- With no ground stack at the position, the target is the belt under it.
    local belt = stacks == 0 and belt_at(c.surface, task.target) or nil
    if not belt then
      if stacks == 0 then
        for _, other in ipairs(c.surface.find_entities_filtered({ position = task.target, type = UNSUPPORTED_BELT_TYPES })) do
          if other.valid then
            error(string.format("pickup_items takes belt items only from a plain transport-belt; the %s (%s) at the position"
              .. " is not supported - target a plain transport-belt tile of the same run", other.name, other.type))
          end
        end
      end
      error(reason)
    end
    task._belt, task._picked, task._wait_tick = belt, 0, game.tick
    return
  end
  task._entity = entity
end

-- After a human hold the body stands somewhere else and its inventory is
-- whatever the owner left: approach again and count nothing gained during the
-- hold. A belt pickup keeps only what its own transfers moved. A ground
-- pickup takes its inventory baseline when picking starts again; one whose
-- stack was already taken, with exactly its count gained, is left to finish.
function M.resume(task)
  if task._belt then
    task._picking_started, task._wait_tick = false, game.tick
    return
  end
  if task._picking_started and not stack_snapshot(task._entity) then
    local c = companion.get()
    if c and c.get_main_inventory().get_item_count(task.item) - task._inventory_before == task.count then return end
  end
  task._picking_started = false
end

local function fail(c, detail, outcome)
  stop(c)
  return { status = "failed", detail = detail, outcome = outcome }
end

local function belt_outcome(task, belt)
  return { source = "belt", item = task.item, requested = task.count, picked_up = task._picked,
    removed_from_belt = task._picked + (task._lost or 0),
    belt = { name = belt.name, position = { x = belt.position.x, y = belt.position.y } } }
end

local function belt_stopped(c, task, reason)
  local belt = task._belt
  return fail(c, string.format("belt pickup stopped: requested %d %s, picked up %d - %s",
    task.count, task.item, task._picked, reason),
    task._picked > 0 and belt and belt.valid and belt_outcome(task, belt) or nil)
end

local function within(a, b, distance)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy <= distance * distance
end

-- Moves up to `want` of the item from one lane into the inventory and returns
-- the count moved. Nothing leaves the line unless the inventory can take it,
-- and what the line gives up is what the inventory is given. Should the
-- inventory still take fewer, the remainder goes back onto the same line;
-- an item the line will not take back is counted, never hidden.
local function take(task, inventory, lane, want)
  local line = task._belt.get_transport_line(lane)
  -- can_insert is true when any part fits; only the insertable count bounds a removal.
  want = math.min(want, line.get_item_count(task.item), inventory.get_insertable_count(task.item))
  if want < 1 then return 0 end
  local removed = line.remove_item({ name = task.item, count = want })
  if removed < 1 then return 0 end
  local inserted = inventory.insert({ name = task.item, count = removed })
  for _ = inserted + 1, removed do
    task._refused = (task._refused or 0) + 1
    if not line.insert_at_back({ name = task.item, count = 1 }) then task._lost = (task._lost or 0) + 1 end
  end
  return inserted
end

-- Switches once to the other lane when it carries the item.
local function other_lane(task)
  local other = 3 - task._lane
  if task._lane_retried or lane_count(task._belt, other, task.item) < 1 then return false end
  task._lane_retried = { lane = task._lane }
  task._lane, task._picking_started, task._approach = other, false, nil
  return true
end

-- `count` items of one kind from the belt tile, while the belt's centre is
-- within pickup distance of the body. The count is what its lines gave up.
local function belt_tick(task, c)
  local belt, inventory = task._belt, c.get_main_inventory()
  if not (belt and belt.valid) then return belt_stopped(c, task, "the belt at the observed position is gone") end
  local distance = tonumber(c.item_pickup_distance) or 0

  -- The transfer needs reach, not a resting place: take what is in reach now,
  -- also while still approaching or while standing on a belt in a dense area.
  if not task._picking_started and within(c.position, belt.position, distance) then
    task._lane = task._lane or (lane_count(belt, 1, task.item) >= lane_count(belt, 2, task.item) and 1 or 2)
    task._picking_started, task._progress_tick = true, game.tick
  end
  if not task._picking_started then
    if inventory.get_insertable_count(task.item) < task.count - task._picked then
      return belt_stopped(c, task, string.format("Codex inventory cannot hold the %d %s still requested; nothing was taken from the belt for them",
        task.count - task._picked, task.item))
    end
    if not task._lane then
      local left, right = lane_count(belt, 1, task.item), lane_count(belt, 2, task.item)
      if left == 0 and right == 0 then
        if game.tick - task._wait_tick >= PICKUP_TIMEOUT_TICKS then
          return belt_stopped(c, task, string.format("the belt tile carried none for %d ticks", PICKUP_TIMEOUT_TICKS))
        end
        return nil
      end
      task._lane = left >= right and 1 or 2
    end
    local reached = approach.ensure(task, c, lane_point(belt, task._lane), math.max(distance - LANE_OFFSET, 0.1))
    if reached ~= "ok" then
      if type(reached) ~= "table" then return nil end
      local blocked = string.format("could not stand within pickup distance of the %s: %s",
        lane_label(belt, task._lane), tostring(reached.detail))
      if task._lane_retried then
        return belt_stopped(c, task, string.format("%s; %s", task._lane_retried.detail or
          ("the " .. lane_label(belt, task._lane_retried.lane) .. " was tried first"), blocked))
      end
      if other_lane(task) then
        task._lane_retried.detail = blocked
        return nil
      end
      return belt_stopped(c, task, string.format("%s; the %s carries no %s on this tile - try another plain belt tile of the run",
        blocked, lane_label(belt, 3 - task._lane), task.item))
    end
    task._picking_started, task._progress_tick = true, game.tick
  end

  -- Acting needs reach, measured before anything is removed: the belt's centre
  -- must be within pickup distance of the body, or the body approaches again.
  if not within(c.position, belt.position, distance) then
    task._picking_started = false
    return nil
  end
  if inventory.get_insertable_count(task.item) < task.count - task._picked then
    return belt_stopped(c, task, string.format("Codex inventory can no longer hold the %d %s still requested",
      task.count - task._picked, task.item))
  end
  for _, lane in ipairs({ task._lane, 3 - task._lane }) do
    if task._picked < task.count and not task._refused then
      local moved = take(task, inventory, lane, task.count - task._picked)
      if moved > 0 then task._picked, task._progress_tick = task._picked + moved, game.tick end
    end
  end
  if task._refused then
    return belt_stopped(c, task, string.format("the inventory refused %d %s it had accepted; %d went back onto the belt and %d could not be returned",
      task._refused, task.item, task._refused - (task._lost or 0), task._lost or 0))
  end
  if task._picked >= task.count then
    stop(c)
    return { status = "done", detail = string.format(
        "physically picked up %d %s from the %s at (%.1f, %.1f) by exact transfer from its %s; the belt gave up %d and the inventory gained %d of %d requested",
        task._picked, task.item, belt.name, belt.position.x, belt.position.y, lane_label(belt, task._lane),
        task._picked, task._picked, task.count),
      outcome = belt_outcome(task, belt) }
  end
  if game.tick - task._progress_tick >= PICKUP_TIMEOUT_TICKS then
    local dry = lane_label(belt, task._lane)
    if other_lane(task) then return nil end
    return belt_stopped(c, task, string.format("none came along the %s within pickup distance for %d ticks", dry, PICKUP_TIMEOUT_TICKS))
  end
  return nil
end

function M.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the Codex character is gone" } end
  if task._belt then return belt_tick(task, c) end
  local inventory = c.get_main_inventory()
  local name, remaining = stack_snapshot(task._entity)

  if task._picking_started then
    local gained = inventory.get_item_count(task.item) - task._inventory_before
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
  -- The exact stack was verified just above and nothing is taken yet: the
  -- pickup's inventory gain is measured from here, not from before the walk.
  task._picking_started = true
  task._picking_started_tick = game.tick
  task._inventory_before = inventory.get_item_count(task.item)
  c.picking_state = true
  return nil
end

return M
