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
--
-- Escape (internal, never a tool input): {from, through = {x, y},
-- expected_name?} steps the body out of an enclosure of own entities. The
-- body takes up the named entity and walks through the opening toward
-- `through` until it has passed the entity's spot and stands a tile clear of
-- it, off any belt (a belt would carry it back); reaching `through` still
-- beside the spot (it lies just past the opening) walks on once to a spot
-- past the gap. Only that, or a failed walk, ends the walk out. Then it puts
-- the same entity back on its own spot and restores it as above (contents it
-- cannot reach stay in the inventory, and the result says so). Result:
-- {code = ESCAPED, name, from, restored}, only while the body still stands
-- outside after the put-back; else a failure that says whether the entity
-- is back in place or in the inventory. A plan that ends mid escape
-- (cancelled hook) puts the entity back when it can there and then, else
-- names it in the inventory.
local companion = require("scripts.companion")
local registry = require("scripts.registry")
local approach = require("scripts.actions.approach")
local placement_geometry = require("scripts.placement_geometry")
local build = require("scripts.actions.build")
local entity_settings = require("scripts.entity_settings")
local supply = require("scripts.actions.supply")
local set_walking = require("scripts.human_inputs").set_walking

local robot_move = require("scripts.actions.robot_move")
local M = {}

-- The nested place runs through supply's nested runner table; build_plan
-- runs an escape (below) the same way.
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
  if step.mode ~= nil and step.mode ~= "body" and step.mode ~= "robots" then error(label .. " mode must be body or robots", 0) end
  local d = step.direction
  if d ~= nil and (type(d) ~= "number" or d % 1 ~= 0 or d < 0 or d > 15) then
    error(label .. " direction must be an integer 0-15", 0)
  end
end

local function own_entity_at(c, position, robot_mode)
  local ok, found = pcall(c.surface.find_entities_filtered, { position = position, force = c.force, limit = robot_mode and 17 or nil })
  if robot_mode and ok and #found > 16 then error("MOVE_ROBOT_UNSUPPORTED: source selection exceeds 16 entities", 0) end
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
  local mask_ok, mask = pcall(function() return proto.collision_mask end)
  mask = mask_ok and type(mask) == "table" and mask or nil
  local tiles = { left_top = { x = math.floor(area.left_top.x), y = math.floor(area.left_top.y) },
    right_bottom = { x = math.ceil(area.right_bottom.x), y = math.ceil(area.right_bottom.y) } }
  local tile_count = placement_geometry.tile_count(tiles)
  -- Every entity on the footprint, then only those whose mask collides with
  -- the entity's: the engine's layer filter once dropped a belt standing there.
  -- An unknown mask counts as colliding. Ore adds at most one row a tile.
  local found_ok, found = pcall(c.surface.find_entities_filtered, { area = area, limit = 33 + tile_count })
  local natural = false
  for _, other in ipairs(found_ok and found or {}) do
    local other_ok, other_mask = pcall(function() return other.prototype.collision_mask end)
    if other.valid and other ~= c and other ~= e and not placement_geometry.NON_BLOCKING_TYPES[other.type]
      and placement_geometry.mask_overlap(mask, other_ok and other_mask or nil, false) ~= false then
      if not NATURAL[other.type] then
        return string.format("%s stands at (%.1f, %.1f)", other.name, other.position.x, other.position.y)
      end
      natural = true
    end
  end
  -- Water or other tiles the entity collides with, over every tile it covers,
  -- matched in Lua as for entities (an unknown entity mask meets water); one
  -- mask read per tile name.
  local tile_mask = mask or { layers = { water_tile = true } }
  local tiles_ok, found_tiles = pcall(c.surface.find_tiles_filtered, { area = tiles, limit = tile_count })
  local meets = {}
  for _, tile in ipairs(tiles_ok and found_tiles or {}) do
    local name_ok, name = pcall(function() return tile.name end)
    local key = name_ok and name or tile
    if meets[key] == nil then
      local tile_ok, other = pcall(function() return tile.prototype.collision_mask end)
      meets[key] = placement_geometry.mask_overlap(tile_mask, tile_ok and other or nil, true) == true
    end
    if meets[key] then return "the ground there is water or otherwise unbuildable" end
  end
  if own_spot or natural then return nil end
  return "the ground there is water or otherwise unbuildable"
end

function M.start(task)
  local c = companion.require_companion()
  validate(task, "move_entity")
  local e = own_entity_at(c, task.from, task.mode == "robots")
  if not e then error(string.format("move_entity: no own entity stands at (%.1f, %.1f)", task.from.x, task.from.y), 0) end
  if task.through ~= nil then
    if not point(task.through) then error("move_entity escape needs through = {x, y}", 0) end
    if task.expected_name and e.name ~= task.expected_name then
      error(string.format("move_entity: a %s, not the %s, stands at (%.1f, %.1f)", e.name, task.expected_name,
        task.from.x, task.from.y), 0)
    end
    task.to, task.direction, task.mode = { x = e.position.x, y = e.position.y }, nil, nil
  end
  local proto = e.prototype
  local ok_items, items = pcall(function() return proto.items_to_place_this end)
  local first = ok_items and type(items) == "table" and items[1] or nil
  local item = type(first) == "string" and first or type(first) == "table" and first.name or nil
  if not item then error("move_entity: no item places a " .. e.name, 0) end
  local direction = task.direction ~= nil and math.floor(task.direction) % 16 or e.direction
  local w, h = tonumber(proto.tile_width) or 1, tonumber(proto.tile_height) or 1
  if direction % 8 == 4 then w, h = h, w end
  local to = { x = snapped(task.to.x, w), y = snapped(task.to.y, h) }
  if to.x == e.position.x and to.y == e.position.y and direction == e.direction and not task.through then
    error(string.format("move_entity: the %s already stands at (%.1f, %.1f) facing that way", e.name, to.x, to.y), 0)
  end
  if task.mode == "robots" then
    task._proto, task._item, task._to, task._direction = proto, item, to, direction
    return robot_move.start(task, c, e)
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

-- Escape: true once the body has passed over the taken-up entity's spot and
-- stands a tile clear of it, so putting it back closes the way behind it.
-- Off any belt too: a belt carries a standing body, and the put-back would
-- settle it into the open gap first.
local function stepped_out(task, c)
  local area = placement_geometry.footprint(task._proto, task._to, task._direction)
  local function grown(margin)
    return { left_top = { x = area.left_top.x - margin, y = area.left_top.y - margin },
      right_bottom = { x = area.right_bottom.x + margin, y = area.right_bottom.y + margin } }
  end
  local p = c.position
  local near = grown(0.5)
  if p.x >= near.left_top.x and p.x <= near.right_bottom.x and p.y >= near.left_top.y and p.y <= near.right_bottom.y then
    task._through_entered = true
  end
  local body = placement_geometry.character_box(c)
  return task._through_entered == true and body ~= nil and not placement_geometry.overlaps(grown(1), body)
    and not placement_geometry.conveyor_under(c)
end

-- Escape: still outside once the entity is back. Putting it back must not
-- have moved the body into the gap (a settle off a belt, a walk clear of the
-- footprint), from where it may have stepped back inside.
local function still_out(task, c)
  if task._through_error or task._reentered then return false end
  local area = placement_geometry.footprint(task._proto, task._to, task._direction)
  local body = placement_geometry.character_box(c)
  return body ~= nil and not placement_geometry.overlaps({
    left_top = { x = area.left_top.x - 1, y = area.left_top.y - 1 },
    right_bottom = { x = area.right_bottom.x + 1, y = area.right_bottom.y + 1 } }, body)
end

-- Escape: the walk out heads for `through` with this reach, so arriving
-- never stands in for having stepped out (stepped_out decides).
local ESCAPE_REACH = 1

-- Escape: a spot past the gap, on the far side of the entity's spot from
-- the enclosure, toward `through`: far enough that a body arriving within
-- ESCAPE_REACH of it stands a tile clear of the spot, on a diagonal too.
local function past_gap(task)
  local area = placement_geometry.footprint(task._proto, task._to, task._direction)
  local cx, cy = (area.left_top.x + area.right_bottom.x) / 2, (area.left_top.y + area.right_bottom.y) / 2
  local dx, dy = task.through.x - cx, task.through.y - cy
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 0.1 then return nil end
  local half = math.max(area.right_bottom.x - area.left_top.x, area.right_bottom.y - area.left_top.y) / 2
  local out = (half + 1.5) * 1.5 + ESCAPE_REACH
  return { x = cx + dx / length * out, y = cy + dy / length * out }
end

-- Escape, with the entity back in place: the failure when the body is not
-- out (the walk out failed, or the put-back moved it into the gap), or nil.
local function escape_failure(task, c, e, restored, notes)
  if not task.through or still_out(task, c) then return nil end
  local snap = task._snapshot
  local why = task._through_error and ("the walk out failed and it is back in place — " .. task._through_error)
    or string.format("putting it back moved the body into the opening, and it is back in place: the body stands at"
      .. " (%.1f, %.1f), maybe inside again", c.position.x, c.position.y)
  return { status = "failed", detail = string.format("ESCAPE_FAILED: took up the %s at (%.1f, %.1f), %s",
    snap.name, e.position.x, e.position.y, why),
    outcome = { code = "ESCAPE_FAILED", restored_in_place = true, name = snap.name, from = snap.from,
      restored = restored, notes = notes and #notes > 0 and notes or nil } }
end

-- Recipe, settings and contents onto the placed entity: restored, notes,
-- shortfall.
local function put_contents(task, c, e)
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
  return restored, notes, shortfall
end

local function restore(task, c, e)
  local snap = task._snapshot
  local restored, notes, shortfall = put_contents(task, c, e)
  local detail = task.through and string.format("stepped out through the %s at (%.1f, %.1f): took it up and put it back",
    snap.name, e.position.x, e.position.y) or string.format("moved the %s from (%.1f, %.1f) to (%.1f, %.1f)",
    snap.name, snap.from.x, snap.from.y, e.position.x, e.position.y)
  if #shortfall > 0 then detail = detail .. string.format(" — %d kinds of its items did not go back in", #shortfall) end
  if #notes > 0 then detail = detail .. " — " .. table.concat(notes, "; ") end
  local failure = escape_failure(task, c, e, restored, notes)
  if failure then return failure end
  return { status = "done", detail = detail, outcome = { code = task.through and "ESCAPED" or "MOVED", moved = true, name = snap.name,
    from = snap.from, to = { x = e.position.x, y = e.position.y }, restored = restored,
    shortfall = #shortfall > 0 and shortfall or nil, notes = #notes > 0 and notes or nil } }
end

function M.tick(task)
  if task.mode == "robots" then
    local c = companion.get()
    if not c then return { status = "failed", detail = "BODY_MISSING", outcome = robot_move.cancelled(task) } end
    return robot_move.tick(task, c)
  end
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  local snap = task._snapshot
  if task.through and task._phase == "place" and not task._reentered and placement_geometry.overlaps(
    placement_geometry.footprint(task._proto, task._to, task._direction), placement_geometry.character_box(c)) then
    task._reentered = true
  end
  if task._sub then
    local kind = task._sub.type
    local result = supply.step(task, "_sub")
    if not result then return nil end
    if kind == "mine" then
      if result.status ~= "done" then
        return failed(task, "MOVE_MINE_FAILED", string.format("the %s stays where it was — %s", snap.name, tostring(result.detail)))
      end
      task._phase = task.through and "through" or "place"
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
  if task._phase == "through" and not stepped_out(task, c) then
    local reached = approach.ensure(task, c, task._past or task.through, ESCAPE_REACH)
    if reached == nil then return nil end
    if reached == "ok" and not task._past and not stepped_out(task, c) then
      -- At `through` but still beside the opening: on past the gap, once.
      task._past = past_gap(task)
      if task._past then return nil end
    end
    if not stepped_out(task, c) then
      task._through_error = type(reached) == "table" and tostring(reached.detail)
        or string.format("the walk out ended within a tile of the %s's spot", snap.name)
    end
  end
  if task._phase == "through" then
    task._approach, task._approach_guard = nil, nil
    set_walking(c, { walking = false })
    task._phase = "place"
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
    local unrestored = "its recipe, settings and items were not restored: " .. tostring(reached.detail)
    if task.through then
      -- Back in place with the body out: an escape, its contents still to restore.
      local failure = escape_failure(task, c, e, nil, { unrestored })
      if failure then return failure end
      return { status = "done", detail = string.format("stepped out through the %s at (%.1f, %.1f): took it up and put"
        .. " it back; %s", snap.name, e.position.x, e.position.y, unrestored),
        outcome = { code = "ESCAPED", moved = true, name = snap.name, from = snap.from,
          to = { x = e.position.x, y = e.position.y }, not_restored = true, notes = { unrestored } } }
    end
    -- Moved, but out of reach for its settings: they and its items wait in the inventory.
    return { status = "partial", detail = string.format("moved the %s to (%.1f, %.1f); its recipe, settings and items"
      .. " were not restored: %s", snap.name, e.position.x, e.position.y, tostring(reached.detail)),
      outcome = { code = "MOVED_NOT_RESTORED", moved = true, name = snap.name, from = snap.from,
        to = { x = e.position.x, y = e.position.y } } }
  end
  if reached ~= "ok" then return nil end
  return restore(task, c, e)
end

function M.observe(task) if task.mode == "robots" then robot_move.observe(task) end end
function M.waiting(task) return task.mode == "robots" and robot_move.waiting(task) end
-- The plan ends while the body holds the taken-up entity (a cancel, a stop,
-- the plan's budget). An escape puts it back on its own spot there and then
-- when the body can (in build reach, the spot free, the item carried: one
-- placement and its restore), so no unchosen hole is left; otherwise, and
-- for a move, the note names the entity and says it is in the inventory.
-- An entity already placed gets its contents restored when in reach. The
-- character can finish mining in the engine update after the step's last
-- tick: a "mine" phase whose entity is gone has taken it up too.
local function body_cancelled(task)
  local snap, phase = task._snapshot, task._phase
  local mined = phase == "mine" and task._entity ~= nil and not task._entity.valid
  if not snap or not (mined or phase == "through" or phase == "place" or phase == "restore") then return nil end
  local c = companion.get()
  if not c then return nil end
  local what = task.through and "the plan ended mid step-out" or "the plan ended mid move"
  local note = { code = task.through and "ESCAPE_CANCELLED" or "MOVE_CANCELLED", name = snap.name, from = snap.from }
  local e = build.existing(c, task._proto, task._to, task._direction, snap.belt_to_ground_type)
  local why
  if not e and task.through then
    local dx, dy = c.position.x - task._to.x, c.position.y - task._to.y
    local ok, placeable, reason = pcall(placement_geometry.can_place, c, task._proto, task._to, task._direction)
    if c.get_item_count(task._item) < 1 then why = "it is not in my inventory"
    elseif dx * dx + dy * dy > (c.build_distance or 0) ^ 2 then why = "its spot is out of build reach"
    elseif not (ok and placeable) then why = "its spot is not free (" .. tostring(ok and reason or placeable) .. ")"
    else
      local okc, built = pcall(c.surface.create_entity, { name = snap.name, position = task._to, direction = task._direction,
        mirror = snap.mirror or nil, type = snap.belt_to_ground_type, force = c.force, raise_built = true })
      if okc and built then
        e = built
        c.remove_item({ name = task._item, count = 1 })
        pcall(registry.add, e)
      else why = "placing it failed" end
    end
  end
  if not e then
    note.in_inventory = true
    note.detail = string.format("%s: the %s taken up at (%.1f, %.1f) is in my inventory%s", what, snap.name,
      snap.from.x, snap.from.y, why and (" — couldn't put it back: " .. why) or "")
    return note
  end
  note.put_back = task.through and true or nil
  note.to = { x = e.position.x, y = e.position.y }
  note.detail = task.through and string.format("%s: put the %s back at (%.1f, %.1f)", what, snap.name, e.position.x, e.position.y)
    or string.format("%s: the %s stands at (%.1f, %.1f)", what, snap.name, e.position.x, e.position.y)
  local ok_reach, reachable = pcall(c.can_reach_entity, e)
  if not (ok_reach and reachable) then
    note.not_restored = true
    note.detail = note.detail .. "; its recipe, settings and items were not restored (out of reach)"
    return note
  end
  local restored, notes, shortfall = put_contents(task, c, e)
  note.restored, note.shortfall, note.notes = restored, #shortfall > 0 and shortfall or nil, #notes > 0 and notes or nil
  if #shortfall > 0 then note.detail = note.detail .. string.format(" — %d kinds of its items did not go back in", #shortfall) end
  if #notes > 0 then note.detail = note.detail .. " — " .. table.concat(notes, "; ") end
  return note
end

function M.cancelled(task, body_only)
  if task.mode == "robots" then return not body_only and robot_move.cancelled(task) or nil end
  return body_cancelled(task)
end
function M.diagnostics(task) if task.mode == "robots" then return robot_move.diagnostics(task) end end
for _, name in ipairs({ "on_robot_pre_mined", "on_robot_mined_entity", "on_robot_built_entity" }) do
  M[name] = function(task, event) if task.mode == "robots" then robot_move[name](task, event) end end
end
supply.register_runner("move_entity", M)

-- The plan action for tasks.register_action.
M.action = {
  runner = M,
  make_task = function(step)
    return { from = step.from, to = step.to, direction = step.direction, allow_fluid_loss = step.allow_fluid_loss, mode = step.mode }
  end,
  validate = function(step, index) validate(step, "queue_plan move_entity step " .. index) end,
  budget_steps = function() return 3 end,
}

return M
