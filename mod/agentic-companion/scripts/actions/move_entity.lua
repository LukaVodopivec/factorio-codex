-- move_entity {from:{x,y}, to:{x,y}, direction?, allow_fluid_loss?}: the body
-- moves one own entity the way a player does. It walks to it and mines it
-- (its contents go into the inventory with it, mining time kept), walks to
-- `to` and places it there (auto-clear and the checks of place_entity), then
-- restores what the API allows: the recipe, the direction (unless one is
-- given), its settings (entity_settings), the mirror (placed mirrored), and
-- the fuel, modules and ingredients it held. Products it held stay in the inventory.
-- Result: {moved, from, to, restored:{recipe, direction, items, settings},
-- shortfall?}. A placement that fails leaves the entity in the inventory and
-- says so. Before mining, the target spot is checked so a move that cannot
-- land never takes the entity up.
local companion = require("scripts.companion")
local registry = require("scripts.registry")
local approach = require("scripts.actions.approach")
local placement_geometry = require("scripts.placement_geometry")
local build = require("scripts.actions.build")
local entity_settings = require("scripts.entity_settings")
local supply = require("scripts.actions.supply")

local M = {}

-- The nested place runs through supply's nested runner table.
supply.register_runner("place", build.place)

local NEVER = { character = true, ["entity-ghost"] = true, ["tile-ghost"] = true, ["item-request-proxy"] = true,
  resource = true, ["item-entity"] = true, tree = true, ["simple-entity"] = true, plant = true }
local NATURAL = { tree = true, ["simple-entity"] = true, plant = true }
-- The inventory a type's ingredients (or stored items) live in.
local INPUTS = { ["assembling-machine"] = "crafter_input", furnace = "crafter_input", ["rocket-silo"] = "crafter_input",
  lab = "lab_input", container = "chest", ["logistic-container"] = "chest", ["ammo-turret"] = "turret_ammo" }
-- Restored in this order, after the recipe.
local GROUPS = { "modules", "fuel", "input" }

local function plain(err) return (tostring(err):gsub("^.-:%d+:%s*", "")) end

local function point(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

local function validate(step, label)
  if not point(step.from) then error(label .. " needs from = {x, y}", 0) end
  if not point(step.to) then error(label .. " needs to = {x, y}", 0) end
  local d = step.direction
  if d ~= nil and (type(d) ~= "number" or d % 1 ~= 0 or d < 0 or d > 15) then
    error(label .. " direction must be an integer 0-15", 0)
  end
end

local function own_entity_at(c, position)
  local ok, found = pcall(c.surface.find_entities_filtered, { position = position, force = c.force })
  for _, e in ipairs(ok and found or {}) do
    if e.valid and not NEVER[e.type] then return e end
  end
end

local function inventories(e)
  local out = {}
  pcall(function() out.fuel = e.get_fuel_inventory() end)
  pcall(function() out.modules = e.get_module_inventory() end)
  local id = INPUTS[e.type] and defines.inventory[INPUTS[e.type]]
  if id then pcall(function() out.input = e.get_inventory(id) end) end
  return out
end

local function contents(inventory)
  local out = {}
  local ok, rows = pcall(function() return inventory.get_contents() end)
  for _, r in ipairs(ok and rows or {}) do out[r.name] = (out[r.name] or 0) + r.count end
  return next(out) and out or nil
end

local function snapped(value, tiles)
  local offset = tiles % 2 == 1 and 0.5 or 0
  return math.floor(value - offset + 0.5) + offset
end

-- Why `to` cannot take the entity (anything but trees and rocks, which the
-- placement clears, the body, which steps aside, or the entity itself, which
-- frees its own footprint once mined), or nil.
local function blocked(c, e, proto, to, direction)
  local area = placement_geometry.footprint(proto, to, direction)
  local own_spot = placement_geometry.overlaps(area, e.bounding_box)
  if not own_spot then
    local ok, why = placement_geometry.can_place(c, proto, to, direction)
    if ok or why == "CODEX_BODY_OVERLAP" then return nil end
  end
  local mask_ok, layers = pcall(function() return proto.collision_mask.layers end)
  layers = mask_ok and type(layers) == "table" and layers or nil
  local found_ok, found = pcall(c.surface.find_entities_filtered, { area = area, collision_mask = layers, limit = 33 })
  local natural = false
  for _, other in ipairs(found_ok and found or {}) do
    if other.valid and other ~= c and other ~= e and not placement_geometry.NON_BLOCKING_TYPES[other.type] then
      if not NATURAL[other.type] then
        return string.format("%s stands at (%.1f, %.1f)", other.name, other.position.x, other.position.y)
      end
      natural = true
    end
  end
  -- Water or other tiles the entity collides with, over every tile it covers.
  local tiles = { left_top = { x = math.floor(area.left_top.x), y = math.floor(area.left_top.y) },
    right_bottom = { x = math.ceil(area.right_bottom.x), y = math.ceil(area.right_bottom.y) } }
  local tiles_ok, wet = pcall(c.surface.count_tiles_filtered, { area = tiles,
    collision_mask = layers or "water_tile", limit = 1 })
  if tiles_ok and wet > 0 then return "the ground there is water or otherwise unbuildable" end
  if own_spot or natural then return nil end
  return "the ground there is water or otherwise unbuildable"
end

function M.start(task)
  local c = companion.require_companion()
  validate(task, "move_entity")
  local e = own_entity_at(c, task.from)
  if not e then error(string.format("move_entity: no own entity stands at (%.1f, %.1f)", task.from.x, task.from.y), 0) end
  local proto = e.prototype
  local ok_items, items = pcall(function() return proto.items_to_place_this end)
  local first = ok_items and type(items) == "table" and items[1] or nil
  local item = type(first) == "string" and first or type(first) == "table" and first.name or nil
  if not item then error("move_entity: no item places a " .. e.name, 0) end
  local direction = task.direction ~= nil and math.floor(task.direction) % 16 or e.direction
  local w, h = tonumber(proto.tile_width) or 1, tonumber(proto.tile_height) or 1
  if direction % 8 == 4 then w, h = h, w end
  local to = { x = snapped(task.to.x, w), y = snapped(task.to.y, h) }
  if to.x == e.position.x and to.y == e.position.y and direction == e.direction then
    error(string.format("move_entity: the %s already stands at (%.1f, %.1f) facing that way", e.name, to.x, to.y), 0)
  end
  local why = blocked(c, e, proto, to, direction)
  if why then error(string.format("move_entity: the %s can't go to (%.1f, %.1f): %s", e.name, to.x, to.y, why), 0) end
  -- Only an assembling machine takes a recipe (set_recipe); a furnace's
  -- follows its input.
  local recipe
  if e.type == "assembling-machine" or e.type == "rocket-silo" then pcall(function() local r = e.get_recipe(); recipe = r and r.name end) end
  local held = {}
  for group, inventory in pairs(inventories(e)) do held[group] = contents(inventory) end
  local ok_mirror, mirrored = pcall(function() return e.mirroring == true end)
  mirrored = ok_mirror and mirrored
  task._entity, task._proto, task._item, task._to, task._direction = e, proto, item, to, direction
  task._snapshot = { name = e.name, from = { x = e.position.x, y = e.position.y }, direction = e.direction,
    recipe = recipe, settings = entity_settings.read(e), held = held,
    mirror = mirrored or nil,
    belt_to_ground_type = e.type == "underground-belt" and e.belt_to_ground_type or nil }
  task._phase = "mine"
end

M.resume = supply.resume

-- in_inventory: the entity was mined and not placed again.
local function failed(task, code, detail, in_inventory)
  return { status = "failed", detail = code .. ": " .. detail, outcome = { code = code, moved = false,
    from = task._snapshot.from, in_inventory = in_inventory } }
end

-- Recipe, settings and contents onto the placed entity.
local function restore(task, c, e)
  local snap = task._snapshot
  local restored = { direction = e.direction, items = {} }
  local notes, shortfall = {}, {}
  if snap.recipe then
    local ok = pcall(e.set_recipe, snap.recipe)
    local now
    pcall(function() local r = e.get_recipe(); now = r and r.name end)
    if ok and now == snap.recipe then restored.recipe = snap.recipe
    else notes[#notes + 1] = "couldn't set recipe " .. snap.recipe end
  end
  if snap.settings then
    local _, unset = entity_settings.apply(e, snap.settings)
    for _, issue in ipairs(unset) do notes[#notes + 1] = issue end
    restored.settings = #unset == 0
  end
  local targets = inventories(e)
  for _, group in ipairs(GROUPS) do
    local inventory = targets[group]
    local names = {}
    for name in pairs(snap.held[group] or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local want = snap.held[group][name]
      local n = math.min(want, c.get_item_count(name))
      local inserted = 0
      if inventory and n > 0 then
        local ok, count = pcall(inventory.insert, { name = name, count = n })
        inserted = ok and count or 0
        if inserted > 0 then c.remove_item({ name = name, count = inserted }) end
      end
      if inserted > 0 then restored.items[name] = (restored.items[name] or 0) + inserted end
      if inserted < want then shortfall[#shortfall + 1] = { item = name, missing = want - inserted, into = group } end
    end
  end
  if not next(restored.items) then restored.items = nil end
  local detail = string.format("moved the %s from (%.1f, %.1f) to (%.1f, %.1f)", snap.name, snap.from.x, snap.from.y,
    e.position.x, e.position.y)
  if #shortfall > 0 then detail = detail .. string.format(" — %d kinds of its items did not go back in", #shortfall) end
  if #notes > 0 then detail = detail .. " — " .. table.concat(notes, "; ") end
  return { status = "done", detail = detail, outcome = { code = "MOVED", moved = true, name = snap.name,
    from = snap.from, to = { x = e.position.x, y = e.position.y }, restored = restored,
    shortfall = #shortfall > 0 and shortfall or nil, notes = #notes > 0 and notes or nil } }
end

function M.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  local snap = task._snapshot
  if task._sub then
    local kind = task._sub.type
    local result = supply.step(task, "_sub")
    if not result then return nil end
    if kind == "mine" then
      if result.status ~= "done" then
        return failed(task, "MOVE_MINE_FAILED", string.format("the %s stays where it was — %s", snap.name, tostring(result.detail)))
      end
      task._phase = "place"
    elseif kind == "place" then
      if result.status ~= "done" and result.status ~= "partial" then
        local overlap = type(result.detail) == "string" and result.detail:find("CODEX_BODY_OVERLAP", 1, true)
        if overlap and not task._exited then
          task._exited = true
          local exit = build.footprint_exit(c, task._proto, task._to, task._direction)
          if exit and pcall(supply.begin, task, "_sub", { type = "walk_to", target = exit, arrival_mode = "exact",
            arrival_radius = 1 }) then
            return nil
          end
        end
        return failed(task, "MOVE_PLACE_FAILED", string.format("the %s is in my inventory — %s", task._item,
          tostring(result.detail)), true)
      end
      task._phase = "restore"
    end
    -- A walk clear of the footprint ends here: place again.
  end
  if task._phase == "mine" then
    local e = task._entity
    if not e.valid then return failed(task, "MOVE_SOURCE_GONE", "the entity is gone") end
    local ok, err = pcall(supply.begin, task, "_sub", { type = "mine", target = { x = e.position.x, y = e.position.y },
      count = 1, target_kind = "owned", expected_name = e.name, allow_fluid_loss = task.allow_fluid_loss == true })
    if not ok then return failed(task, "MOVE_MINE_FAILED", plain(err)) end
    return nil
  end
  if task._phase == "place" then
    local ok, err = pcall(supply.begin, task, "_sub", { type = "place", item = task._item, position = task._to,
      direction = task._direction, mirror = snap.mirror, auto_supply = false, belt_to_ground_type = snap.belt_to_ground_type })
    if not ok then
      return failed(task, "MOVE_PLACE_FAILED", string.format("the %s is in my inventory — %s", task._item, plain(err)), true)
    end
    return nil
  end
  -- restore: the placed entity, within reach.
  local e = build.existing(c, task._proto, task._to, task._direction, snap.belt_to_ground_type)
  if not e then return failed(task, "MOVE_PLACED_GONE", "the placed " .. snap.name .. " is gone") end
  pcall(registry.add, e)
  local reached = approach.ensure_entity(task, c, e)
  if type(reached) == "table" then
    -- Moved, but out of reach for its settings: they and its items wait in the inventory.
    return { status = "partial", detail = string.format("moved the %s to (%.1f, %.1f); its recipe, settings and items"
      .. " were not restored: %s", snap.name, e.position.x, e.position.y, tostring(reached.detail)),
      outcome = { code = "MOVED_NOT_RESTORED", moved = true, name = snap.name, from = snap.from,
        to = { x = e.position.x, y = e.position.y } } }
  end
  if reached ~= "ok" then return nil end
  return restore(task, c, e)
end

-- The plan action for tasks.register_action.
M.action = {
  runner = M,
  make_task = function(step)
    return { from = step.from, to = step.to, direction = step.direction, allow_fluid_loss = step.allow_fluid_loss }
  end,
  validate = function(step, index) validate(step, "queue_plan move_entity step " .. index) end,
  budget_steps = function() return 3 end,
}

return M
