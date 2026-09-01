-- Mine exactly the visible entity occupying the requested coordinate.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local M = {}
local MINABLE_TYPES = { "resource", "tree", "simple-entity" }

local function occupies(e, target)
  local box = e.selection_box or e.bounding_box
  if box then
    return target.x >= box.left_top.x and target.x < box.right_bottom.x
      and target.y >= box.left_top.y and target.y < box.right_bottom.y
  end
  return math.floor(e.position.x) == math.floor(target.x) and math.floor(e.position.y) == math.floor(target.y)
end

local function op_ticks(c, e)
  local mining_time = e.prototype.mineable_properties.mining_time or 1
  return math.max(10, math.ceil(mining_time * 60 / (1 + c.force.manual_mining_speed_modifier)))
end

function M.start(task)
  local c = companion.require_companion()
  local target = task.target
  if type(target) ~= "table" or type(target.x) ~= "number" or type(target.y) ~= "number" then error("mine requires target = {x, y}") end
  local candidates = c.surface.find_entities_filtered({ area = { { target.x, target.y }, { target.x + 0.001, target.y + 0.001 } }, type = MINABLE_TYPES })
  local found
  for _, e in ipairs(candidates) do
    if e.valid and e.prototype.mineable_properties.minable and occupies(e, target) then
      if found then error("more than one minable entity occupies that coordinate; observe again and choose an unambiguous point") end
      found = e
    end
  end
  if not found then error(string.format("nothing minable occupies exact coordinate (%.1f, %.1f)", target.x, target.y)) end
  task._entity, task._entity_name, task._remaining = found, found.name, op_ticks(c, found)
end

function M.tick(task)
  local c, e = companion.get(), task._entity
  if not c then return { status = "failed", detail = "the Codex character is gone" } end
  if not (e and e.valid) then return { status = "failed", detail = "the exact target was removed before mining completed" } end
  local reached = approach.ensure(task, c, e.position, c.resource_reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end
  c.mining_state = { mining = true, position = e.position }
  task._remaining = task._remaining - 1
  if task._remaining > 0 then return nil end
  c.mining_state = { mining = false }
  local inv, before = c.get_main_inventory(), c.get_main_inventory().get_item_count()
  local exhausted = e.mine({ inventory = inv, raise_destroyed = true })
  local gained = inv.get_item_count() - before
  if gained <= 0 then return { status = "failed", detail = "could not mine exact target — inventory full or no product" } end
  return { status = "done", detail = string.format("mined %s at exact coordinate (+%d items)%s", task._entity_name, gained, exhausted and " — exhausted" or "") }
end

return M
