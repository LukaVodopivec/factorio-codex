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

local function entity_amount(e)
  if not (e and e.valid) then return nil end
  local ok, amount = pcall(function() return e.amount end)
  if ok and type(amount) == "number" then return amount end
  return nil
end

-- Physical character mining cannot complete when its inventory cannot accept
-- the entity's products. Fail before starting the mining state instead of
-- waiting until the bridge timeout or bypassing the character with scripted
-- entity mining.
local function character_accepts_products(c, e)
  local required = {}
  local products = e.prototype.mineable_properties.products or {}
  for _, product in ipairs(products) do
    if (product.type == nil or product.type == "item") and product.name then
      local count = tonumber(product.amount) or tonumber(product.amount_max)
        or tonumber(product.amount_min) or 1
      required[product.name] = (required[product.name] or 0) + math.max(1, math.ceil(count))
    end
  end
  for name, count in pairs(required) do
    if not c.can_insert({ name = name, count = count }) then return false end
  end
  return true
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
  task._entity, task._entity_name = found, found.name
end

function M.tick(task)
  local c, e = companion.get(), task._entity
  if not c then return { status = "failed", detail = "the Codex character is gone" } end
  if not task._mining_started then
    if not (e and e.valid) then return { status = "failed", detail = "the exact target was removed before mining started" } end
    local reached = approach.ensure(task, c, e.position, c.resource_reach_distance)
    if type(reached) == "table" then return reached end
    if reached ~= "ok" then return nil end
    local inv = c.get_main_inventory()
    if not inv then return { status = "failed", detail = "the Codex character has no inventory" } end
    if not character_accepts_products(c, e) then
      return { status = "failed", detail = "cannot mine " .. e.name .. " — Codex inventory is full" }
    end
    task._target_amount = entity_amount(e)
    task._inventory_before = inv.get_item_count()
    task._mining_started = true
    c.mining_state = { mining = true, position = e.position }
    return nil
  end

  local current_amount = entity_amount(e)
  local target_changed = not (e and e.valid)
    or (task._target_amount ~= nil and current_amount ~= nil and current_amount < task._target_amount)
  if not target_changed then return nil end

  c.mining_state = { mining = false }
  local inv = c.get_main_inventory()
  local gained = inv and (inv.get_item_count() - task._inventory_before) or 0
  if gained <= 0 then
    return { status = "failed", detail = "the exact target changed without mined items reaching Codex inventory" }
  end
  return { status = "done", detail = string.format("mined %s at exact coordinate (+%d items)", task._entity_name, gained) }
end

return M
