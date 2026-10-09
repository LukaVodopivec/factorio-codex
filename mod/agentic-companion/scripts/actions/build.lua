-- Building actions: place, rotate, set_recipe. Each approaches its target
-- first (build_distance for place, reach_distance otherwise). place is
-- idempotent: the same own entity already standing there is done (turned
-- when it faces another way); `insert` puts starter items (fuel) into what
-- was placed; `mirror` places it flipped (refineries, chemical plants).
local companion = require("scripts.companion")
local registry = require("scripts.registry")
local approach = require("scripts.actions.approach")
local output_targets = require("scripts.output_target")
local placement_geometry = require("scripts.placement_geometry")
local supply = require("scripts.actions.supply")
local transfer = require("scripts.actions.transfer")
local craft = require("scripts.actions.craft")
local platforms = require("scripts.platforms")
local items = require("scripts.items")

local M = {}

local function dir_name(d)
  for name, value in pairs(defines.direction) do
    if value == d then return name end
  end
  return tostring(d)
end

local function validate_position(pos, action)
  if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
    error(action .. " requires target = {x, y}")
  end
end

local function gone()
  return { status = "failed", detail = "the companion character is gone" }
end

-- ------------------------------------------------------------------ place

-- Why can_place_entity said no: name the blocker if we can find one, first
-- what touches the footprint itself, then anything within a tile.
local function blocked_reason(c, pos, proto, direction)
  local mix = placement_geometry.fluid_mix(c.surface, proto, pos, direction)
  if mix then return placement_geometry.fluid_mix_reason(mix) end
  local searches = { { position = pos, radius = 1.0 } }
  if proto then
    table.insert(searches, 1, { area = placement_geometry.touching(placement_geometry.footprint(proto, pos, direction)) })
  end
  for _, search in ipairs(searches) do
    for _, e in ipairs(c.surface.find_entities_filtered(search)) do
      if e.valid and e ~= c and e.type ~= "resource" then
        local lying = placement_geometry.ground_item_row(e)
        if lying then return placement_geometry.ground_item_text(lying) .. " is in the way" end
        return string.format("%s at (%s, %s) is in the way — pick a clear spot or remove it first",
          e.name, placement_geometry.exact(e.position.x), placement_geometry.exact(e.position.y))
      end
    end
  end
  -- A liquid other than water names itself (lava, an oil or ammoniacal ocean).
  local liquid = placement_geometry.liquid_at(c.surface, math.floor(pos.x), math.floor(pos.y))
  if liquid and liquid.fluid and liquid.fluid ~= "water" then
    return string.format("the ground there is %s — cover it with place_tiles (foundation or ice platform) first",
      liquid.fluid == "lava" and "lava" or (liquid.fluid .. " ocean"))
  end
  local water = false
  pcall(function()
    water = c.surface.get_tile(math.floor(pos.x), math.floor(pos.y)).collides_with("player")
  end)
  if water then
    return "the ground there is water or otherwise unbuildable"
  end
  local dx, dy = c.position.x - pos.x, c.position.y - pos.y
  if dx * dx + dy * dy < 9 then
    return "I might be standing in the way — walk a couple of tiles away and try again"
  end
  return "the spot is blocked — try a nearby position"
end
M.blocked_reason = blocked_reason

-- Underground belts take an explicit input/output end; every other item rejects the field.
function M.belt_to_ground_error(item, place_result, value)
  if value == nil then return nil end
  if value ~= "input" and value ~= "output" then
    return "belt_to_ground_type must be \"input\" or \"output\""
  end
  if place_result.type ~= "underground-belt" then
    return string.format("belt_to_ground_type applies only to underground belts; %s places a %s",
      item, place_result.type)
  end
  return nil
end

-- Runtime pairing of a placed underground belt, or nil for any other entity.
function M.underground_pairing(built)
  if not (built and built.valid and built.type == "underground-belt") then return nil end
  local pairing = { direction = built.direction, belt_to_ground_type = built.belt_to_ground_type }
  local ok, neighbour = pcall(function() return built.neighbours end)
  if ok and neighbour and neighbour.valid then
    pairing.neighbour = { name = neighbour.name, direction = neighbour.direction, belt_to_ground_type = neighbour.belt_to_ground_type,
      position = { x = neighbour.position.x, y = neighbour.position.y } }
  end
  return pairing
end

local function pairing_note(pairing)
  if not pairing then return "" end
  if not pairing.neighbour then return string.format(" as %s end; no paired underground yet", pairing.belt_to_ground_type) end
  return string.format(" as %s end paired with %s at (%.1f, %.1f)", pairing.belt_to_ground_type,
    pairing.neighbour.name, pairing.neighbour.position.x, pairing.neighbour.position.y)
end
M.pairing_note = pairing_note

-- Native underground auto-pairing may reverse the new end. Never rotate it:
-- Factorio would also rotate its existing partner. Keep the paid entity and
-- report its actual state instead of claiming the requested configuration.
function M.underground_error(built, direction, end_type)
  local pairing = M.underground_pairing(built)
  if not pairing then return nil end
  if pairing.direction == direction and (end_type == nil or pairing.belt_to_ground_type == end_type) then return nil end
  return string.format("UNDERGROUND_CONFIGURATION_MISMATCH: placed %s at (%.1f, %.1f), requested direction %d%s; native direction %d%s; paid entity retained",
    built.name, built.position.x, built.position.y, direction,
    end_type and (" as " .. end_type .. " end") or "", pairing.direction, pairing_note(pairing))
end

-- ------------------------------------------------- footprint housekeeping

-- Trees and rocks never stop a placement: the body mines them first, one by
-- one, through the ordinary physical mine action. Returns "ok" once the
-- footprint holds none, nil while clearing, or a failed result.
local MAX_CLEARS = 16
local NATURAL_BLOCKERS = { "simple-entity", "tree", "plant" }
local function natural_blocker(c, area)
  area = placement_geometry.touching(area)
  local ok, found = pcall(c.surface.find_entities_filtered, { area = area, type = NATURAL_BLOCKERS })
  if not ok or type(found) ~= "table" then return nil end
  for _, e in ipairs(found) do
    local ok_minable, minable = pcall(function()
      return e.valid and e.force ~= c.force and e.prototype.mineable_properties.minable
    end)
    if ok_minable and minable and (not e.bounding_box or placement_geometry.overlaps(area, e.bounding_box)) then return e end
  end
  return nil
end

-- Item stacks lying on the footprint go into the body's main inventory, as
-- the game's own building takes them up: up to GROUND_PICKS stacks a call,
-- each moved as its real stack (items.move_stacks), so only what the
-- inventory took leaves the ground. A stack the inventory cannot take whole
-- stays where it lies and fails the placement with GROUND_ITEMS_NO_ROOM;
-- nothing is spilled. task._picked_up keeps this footprint's rows
-- {item, count, x, y} (M.picked_up). Returns "ok" once none lies there, nil
-- when more may, or a failed result.
local GROUND_PICKS = 32
local function pick_ground_items(task, c, area, position)
  local rows, found = placement_geometry.ground_items(c.surface, placement_geometry.touching(area), GROUND_PICKS)
  if #found == 0 then return "ok" end
  local log = task._picked_up
  if not (log and log.x == position.x and log.y == position.y) then
    log = { x = position.x, y = position.y, rows = {} }
    task._picked_up = log
  end
  local inventory = c.get_main_inventory()
  for i, e in ipairs(found) do
    local row, stack = rows[i], e.stack
    local quality = items.quality_name(stack.quality)
    local at = row.position
    local moved, short = 0, inventory.get_insertable_count({ name = row.name, quality = quality }) < row.count
    if not short then
      moved, short = items.move_stacks({ stack }, inventory, row.name, quality, row.count, {
        remove = function(part)
          local left = e.valid and e.stack
          if not (left and left.valid_for_read) then return 0 end
          if left.count <= part.count then e.destroy() else left.count = left.count - part.count end
          return part.count
        end,
        -- The stack went away under the split: the part goes back where it lay.
        put_back = function(held)
          local count = held.count
          return c.surface.create_entity({ name = "item-on-ground", position = at, stack = held }) and count or 0
        end,
      })
    end
    if moved > 0 then
      log.rows[#log.rows + 1] = { item = row.name, quality = quality ~= "normal" and quality or nil, count = moved,
        x = at.x, y = at.y }
    end
    if e.valid and not (e.stack and e.stack.valid_for_read) then e.destroy() end
    if short then
      return { status = "failed",
        detail = string.format("GROUND_ITEMS_NO_ROOM: Codex inventory cannot take the %s lying on the placement footprint; %d stay on the ground",
          placement_geometry.ground_item_text(row), row.count - moved),
        outcome = { code = "GROUND_ITEMS_NO_ROOM", item = row.name, count = row.count - moved, x = at.x, y = at.y,
          picked_up = #log.rows > 0 and log.rows or nil } }
    end
  end
  return #found < GROUND_PICKS and "ok" or nil
end

-- The ground stacks clear_footprint took from the footprint at position:
-- {item, count, x, y} rows, or nil.
function M.picked_up(task, position)
  local log = task._picked_up
  if log and position and log.x == position.x and log.y == position.y and #log.rows > 0 then return log.rows end
  return nil
end

function M.clear_footprint(task, c, proto, position, direction)
  if task._clear then
    local result = supply.step(task, "_clear")
    if not result then return nil end
    if result.status ~= "done" then
      return { status = "failed", detail = "couldn't clear the placement footprint: " .. tostring(result.detail) }
    end
  end
  if task.auto_clear == false then return "ok" end
  local area = placement_geometry.footprint(proto, position, direction)
  local blocker = natural_blocker(c, area)
  if not blocker then
    -- Ground stacks last, from where the body stands to build (or just
    -- mined a tree or rock in this footprint).
    local picked = pick_ground_items(task, c, area, position)
    if picked == "ok" then task._clears = nil; return "ok" end
    if picked then return picked end
    task._clears = (task._clears or 0) + 1
    if task._clears > MAX_CLEARS then
      return { status = "failed", detail = string.format("the placement footprint still holds item stacks after picking up %d stacks a tick for %d ticks",
        GROUND_PICKS, MAX_CLEARS) }
    end
    return nil
  end
  task._clears = (task._clears or 0) + 1
  if task._clears > MAX_CLEARS then
    return { status = "failed", detail = string.format("the placement footprint still holds %s after clearing %d trees and rocks",
      blocker.name, MAX_CLEARS) }
  end
  local ok, err = pcall(supply.begin, task, "_clear", { type = "mine", entity = blocker, count = 1,
    target = { x = blocker.position.x, y = blocker.position.y }, target_kind = "natural" })
  if not ok then
    return { status = "failed", detail = string.format("couldn't clear %s from the placement footprint: %s", blocker.name, tostring(err)) }
  end
  return nil
end

-- A spot beside the placement footprint where the body stands clear of it,
-- nearest the body first, or nil. Candidates lie on the four sides and four
-- corners, 2, 3.5 and 5 tiles out (24 point queries at most), so a dense
-- layout that blocks the nearest sides still leaves a way out; each keeps
-- 1.25 tiles from the footprint, so a walk there that stops within its
-- 1-tile arrival tolerance stands clear. `tried` lists exits already walked
-- to: a spot within a tile of one is not offered again.
local EXIT_GAPS = { 2, 3.5, 5 }
function M.footprint_exit(c, proto, position, direction, tried)
  local area = placement_geometry.footprint(proto, position, direction)
  local p, lt, rb = c.position, area.left_top, area.right_bottom
  local candidates = {}
  for _, gap in ipairs(EXIT_GAPS) do
    local n, s, w, e = lt.y - gap, rb.y + gap, lt.x - gap, rb.x + gap
    for _, spot in ipairs({ { x = p.x, y = n }, { x = p.x, y = s }, { x = w, y = p.y }, { x = e, y = p.y },
      { x = w, y = n }, { x = e, y = n }, { x = w, y = s }, { x = e, y = s } }) do
      candidates[#candidates + 1] = spot
    end
  end
  table.sort(candidates, function(a, b)
    local da = (a.x - p.x) ^ 2 + (a.y - p.y) ^ 2
    local db = (b.x - p.x) ^ 2 + (b.y - p.y) ^ 2
    if da ~= db then return da < db end
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end)
  for _, candidate in ipairs(candidates) do
    local ok, clear = pcall(c.surface.find_non_colliding_position, c.name or "character", candidate, 0.5, 0.1)
    local fresh = ok and clear ~= nil
    for _, old in ipairs(fresh and tried or {}) do
      if (old.x - clear.x) ^ 2 + (old.y - clear.y) ^ 2 < 1 then fresh = false end
    end
    if fresh and not placement_geometry.overlaps(area,
      { left_top = { x = clear.x - 1.25, y = clear.y - 1.25 }, right_bottom = { x = clear.x + 1.25, y = clear.y + 1.25 } }) then
      return { x = clear.x, y = clear.y }
    end
  end
end

-- ------------------------------------------------------- idempotent place

-- The own entity of this prototype already standing at the placement spot
-- (its centre within half a tile of the requested position), or nil. An
-- underground belt counts only with the same end and direction.
function M.existing(c, proto, position, direction, belt_to_ground_type)
  local ok, e = pcall(c.surface.find_entity, proto.name, position)
  if not (ok and e and e.valid) or e.force ~= c.force then return nil end
  if math.abs(e.position.x - position.x) > 0.5 or math.abs(e.position.y - position.y) > 0.5 then return nil end
  if e.type == "underground-belt" and (e.direction ~= direction
    or (belt_to_ground_type ~= nil and e.belt_to_ground_type ~= belt_to_ground_type)) then
    return nil
  end
  return e
end

-- Takes an existing entity as the placement: "same" when it already faces
-- the requested way (or has no direction) and is mirrored as requested,
-- "rotated" or "mirrored" once the body turned or flipped it within reach,
-- "gone" when it vanished, nil while walking, or a failed result. A nil
-- mirror leaves the entity's mirroring alone.
function M.adopt(task, c, e, direction, mirror, end_type)
  if not e.valid then return "gone" end
  local mismatch = M.underground_error(e, direction, end_type)
  if mismatch then
    return { status = "failed", detail = mismatch, outcome = { code = "UNDERGROUND_CONFIGURATION_MISMATCH",
      underground = M.underground_pairing(e) } }
  end
  local turn = e.supports_direction and e.direction ~= direction
  local ok_read, mirrored = pcall(function() return e.mirroring == true end)
  local flip = mirror ~= nil and (not ok_read or mirrored ~= (mirror == true))
  if not turn and not flip then return "same" end
  local reached = approach.ensure_entity(task, c, e)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end
  if turn then
    local ok = pcall(function() e.direction = direction end)
    if not ok or e.direction ~= direction then
      return { status = "failed", detail = string.format("the %s already at (%.1f, %.1f) can't face %s",
        e.name, e.position.x, e.position.y, dir_name(direction)) }
    end
  end
  if flip then
    local ok = pcall(function() e.mirroring = mirror == true end)
    local ok_back, now = pcall(function() return e.mirroring == true end)
    if not (ok and ok_back and now == (mirror == true)) then
      return { status = "failed", detail = string.format("the %s already at (%.1f, %.1f) can't be %s",
        e.name, e.position.x, e.position.y, mirror and "mirrored" or "unmirrored") }
    end
    return "mirrored"
  end
  return "rotated"
end

function M.adopted_note(e, how)
  if how == "mirrored" then
    return string.format("%s already stands at (%.1f, %.1f) — %s it%s", e.name, e.position.x, e.position.y,
      e.mirroring and "mirrored" or "unmirrored",
      e.supports_direction and (", facing " .. dir_name(e.direction)) or "")
  end
  return string.format("%s already stands at (%.1f, %.1f)%s", e.name, e.position.x, e.position.y,
    how == "rotated" and (" — turned it to face " .. dir_name(e.direction)) or "; nothing to place")
end

M.place = {}
M.place.resume = supply.resume

-- {"coal":5} -> sorted {name, count} list, or an error.
local function insert_list(items)
  if items == nil then return nil end
  if type(items) ~= "table" then error('place insert must map item names to counts, e.g. {"coal":5}') end
  local list = {}
  for name, count in pairs(items) do
    if type(name) ~= "string" or type(count) ~= "number" or count < 1 then
      error("place insert must map item names to positive counts")
    end
    if not prototypes.item[name] then error("no item called '" .. name .. "'") end
    list[#list + 1] = { name = name, count = math.floor(count) }
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return #list > 0 and list or nil
end

-- After the entity stands: put the starter items in (within reach, once
-- queued crafts of them are done), then report the placement.
local function placed(task, c, built, result)
  local mismatch = M.underground_error(built, task.direction, task.belt_to_ground_type)
  if mismatch then
    return { status = "failed", detail = mismatch, outcome = { code = "UNDERGROUND_CONFIGURATION_MISMATCH",
      placed = 1, underground = M.underground_pairing(built), picked_up = M.picked_up(task, task.position) } }
  end
  local picked = M.picked_up(task, task.position)
  if picked then
    result.outcome = result.outcome or {}
    result.outcome.picked_up = picked
    result.detail = string.format("%s; first took up %d item stack%s lying on its footprint", result.detail, #picked,
      #picked == 1 and "" or "s")
  end
  if not task._insert then return result end
  task._inserting = { entity = built, result = result }
  return nil
end

local function insert_phase(task, c)
  local s = task._inserting
  local e, result = s.entity, s.result
  if not e.valid then
    return { status = "partial", detail = result.detail .. "; it vanished before its starter items went in",
      outcome = result.outcome }
  end
  local reached = approach.ensure_entity(task, c, e)
  if type(reached) == "table" then
    return { status = "partial", detail = result.detail .. "; starter items not inserted: " .. tostring(reached.detail),
      outcome = result.outcome }
  end
  if reached ~= "ok" then return nil end
  if transfer.awaits_crafting(c, task._insert) then return nil end
  local problems, _, transfers = transfer.insert_list(c, e, task._insert)
  local outcome = result.outcome or {}
  outcome.inserted = transfers
  local parts = {}
  for _, row in ipairs(transfers) do
    if row.inserted > 0 then parts[#parts + 1] = string.format("%d %s", row.inserted, row.item) end
  end
  local detail = result.detail .. (#parts > 0 and ("; inserted " .. table.concat(parts, ", ")) or "")
  if #problems > 0 then
    outcome.code = "PLACED_PARTIAL_INSERT"
    return { status = "partial", detail = detail .. " — " .. table.concat(problems, "; ")
      .. (task._shortfall and ("; " .. task._shortfall) or ""), outcome = outcome }
  end
  return { status = "done", detail = detail, outcome = outcome }
end

function M.place.start(task)
  local c = companion.require_companion()
  if type(task.item) ~= "string" then
    error("place requires item = <item name>")
  end
  if type(task.position) ~= "table" or type(task.position.x) ~= "number" or type(task.position.y) ~= "number" then
    error("place requires position = {x, y}")
  end
  local proto = prototypes.item[task.item]
  if not proto then
    error("no item called '" .. task.item .. "'")
  end
  local result = proto.place_result
  if not result then
    error(task.item .. " is not a placeable item")
  end
  task._insert = insert_list(task.insert)
  if task.mirror ~= nil and type(task.mirror) ~= "boolean" then error("place mirror must be true or false") end
  task.direction = math.floor(tonumber(task.direction) or 0) % 16
  task._entity_name = result.name
  local belt_error = M.belt_to_ground_error(task.item, result, task.belt_to_ground_type)
  if belt_error then error(belt_error) end
  -- The planet's (or platform's) conditions: no spot on this surface helps.
  local refused = placement_geometry.condition_refusal(c.surface, "entity", result.name)
  if refused then error(refused.reason, 0) end
  -- The same entity already standing there is the placement.
  task._existing = M.existing(c, result, task.position, task.direction, task.belt_to_ground_type) or false
  if not task._existing and c.get_item_count(task.item) == 0 and task.auto_supply == false
    and craft.queued(c, task.item) == 0 then
    error("I don't have any " .. task.item .. " in my inventory — craft or collect one first")
  end
  -- Targets are checked for reach after the approach walk (in tick), so a
  -- place begun far from its position is not refused before it walks there.
  if task.input_target ~= nil then
    if result.type ~= "inserter" then error(task.item .. " has no deterministic input target") end
    task._input_target = output_targets.resolve(c, task.input_target, "place input_target", "input", true)
    local matches, endpoint = output_targets.input_geometry_matches(c, result, task.position, task.direction,
      task._input_target.entity, true)
    if not matches then
      error(string.format("place input_target is not at the exact provisional input endpoint%s",
        endpoint and string.format(" (%.1f, %.1f)", endpoint.x, endpoint.y) or ""))
    end
  end
  if task.output_target ~= nil then
    task._output_target = output_targets.resolve(c, task.output_target, "place output_target", nil, true)
    local matches, endpoint = output_targets.geometry_matches(c, result, task.position, task.direction,
      task._output_target.entity, true)
    if not matches then
      error(string.format("place output_target is not at the exact provisional output endpoint%s",
        endpoint and string.format(" (%.1f, %.1f)", endpoint.x, endpoint.y) or ""))
    end
  end
end

function M.place.tick(task)
  local c = companion.get()
  if not c then return gone() end

  if task._inserting then return insert_phase(task, c) end
  if task._placed_entity then
    if game.tick <= task._placed_tick then return nil end
    local built = task._placed_entity
    local input_binding = task._expected_input
      and output_targets.binding_status(built, task._expected_input, task._placed_tick, "input") or "matched"
    local output_binding = task._expected_output
      and output_targets.binding_status(built, task._expected_output, task._placed_tick, "output") or "matched"
    if input_binding == "pending" or output_binding == "pending" then return nil end
    task._placed_entity, task._placed_tick, task._expected_input, task._expected_output = nil, nil, nil, nil
    local binding, binding_kind = input_binding ~= "matched" and input_binding or output_binding,
      input_binding ~= "matched" and "input" or "output"
    if binding == "invalid" then
      return { status = "failed", detail = "the exact placed entity vanished before runtime binding could be verified" }
    end
    if binding == "target-invalid" then
      return { status = "failed", detail = "the exact expected " .. binding_kind .. " target vanished before runtime binding could be verified" }
    end
    if binding == "pending-output" then
      return placed(task, c, built, {
        status = "done",
        detail = string.format("placed %s at (%.1f, %.1f); provisional output geometry is valid, but Factorio's runtime output target is pending first output",
          task.item, built.position.x, built.position.y),
      })
    end
    if binding == "mismatch" then
      return {
        status = "failed",
        detail = string.format("placed %s at (%.1f, %.1f), but Factorio exposed a different runtime %s target; recover the exact placed entity before retrying",
          task.item, built.position.x, built.position.y, binding_kind),
      }
    end
    if binding ~= "matched" then
      return {
        status = "failed",
        detail = string.format("placed %s at (%.1f, %.1f), but Factorio did not bind the expected runtime %s target (%s); recover the exact placed entity before retrying",
          task.item, built.position.x, built.position.y, binding_kind, binding),
      }
    end
    return placed(task, c, built, {
      status = "done",
      detail = string.format("placed %s at (%.1f, %.1f)%s",
        task.item, built.position.x, built.position.y,
        task.direction ~= 0 and (" facing " .. dir_name(task.direction)) or ""),
    })
  end

  local proto = prototypes.item[task.item].place_result
  -- A place begun by 0.21.0 has not looked for the same entity yet.
  if task._existing == nil then
    task._existing = M.existing(c, proto, task.position, task.direction, task.belt_to_ground_type) or false
  end
  if task._existing then
    local e = task._existing
    local how = M.adopt(task, c, e, task.direction, task.mirror, task.belt_to_ground_type)
    if how == nil then return nil end
    if type(how) == "table" then return how end
    task._existing = false
    if how ~= "gone" then
      return placed(task, c, e, { status = "done", detail = M.adopted_note(e, how),
        outcome = { code = how == "rotated" and "ROTATED_EXISTING" or how == "mirrored" and "MIRRORED_EXISTING"
          or "ALREADY_PLACED" } })
    end
  end

  -- Auto-supply (default on): fetch the item once, up to a stack, and the
  -- starter items.
  if task.auto_supply ~= false and not task._supplied then
    local needs = {}
    if c.get_item_count(task.item) == 0 then needs[1] = { name = task.item, count = 1 } end
    for _, it in ipairs(task._insert or {}) do
      if c.get_item_count(it.name) < it.count then needs[#needs + 1] = { name = it.name, count = it.count } end
    end
    if #needs > 0 then
      local supplied = supply.ensure(task, needs, { bulk = true })
      if not supplied then return nil end
      if supplied.status ~= "done" then
        if c.get_item_count(task.item) == 0 and craft.queued(c, task.item) == 0 then
          task._supplied = true
          return { status = "failed", detail = "can't place " .. task.item .. ": " .. tostring(supplied.detail),
            outcome = supplied.outcome }
        end
        task._shortfall = supplied.detail
      end
    end
    task._supplied = true
  end

  -- A tree or rock being cleared moves the body: finish that first.
  if task._clear then
    local cleared = M.clear_footprint(task, c, proto, task.position, task.direction)
    if cleared ~= "ok" then return cleared end
  end
  local reached = approach.ensure(task, c, task.position, c.build_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local cleared = M.clear_footprint(task, c, proto, task.position, task.direction)
  if cleared ~= "ok" then return cleared end
  -- The item is still being hand-crafted: wait for it here.
  if craft.awaits(c, task.item, 1) then return nil end
  if c.get_item_count(task.item) == 0 then
    return { status = "failed", detail = "I no longer have any " .. task.item .. " in my inventory" }
  end

  local expected_input, expected_output
  if task._input_target then
    local current = output_targets.resolve(c, task.input_target, "place input_target", "input")
    if current.entity ~= task._input_target.entity then
      return { status = "failed", detail = "place input_target changed before placement; observe again" }
    end
    local matches = output_targets.input_geometry_matches(c, prototypes.item[task.item].place_result,
      task.position, task.direction, current.entity)
    if not matches then
      return { status = "failed", detail = "place provisional input geometry changed before placement; observe again" }
    end
    expected_input = current.entity
  end
  if task._output_target then
    local current = output_targets.resolve(c, task.output_target, "place output_target")
    if current.entity ~= task._output_target.entity then
      return { status = "failed", detail = "place output_target changed before placement; observe again" }
    end
    local matches = output_targets.geometry_matches(c, prototypes.item[task.item].place_result,
      task.position, task.direction, current.entity)
    if not matches then
      return { status = "failed", detail = "place provisional output geometry changed before placement; observe again" }
    end
    expected_output = current.entity
  end

  local can_place, placement_reason = placement_geometry.can_place(c,
    prototypes.item[task.item].place_result, task.position, task.direction)
  if not can_place then
    local picked = M.picked_up(task, task.position)
    return {
      status = "failed",
      detail = string.format("can't place %s at (%.1f, %.1f) — %s",
        task.item, task.position.x, task.position.y,
        placement_reason == "CODEX_BODY_OVERLAP" and "CODEX_BODY_OVERLAP — walk clear of the exact collision footprint" or blocked_reason(c, task.position, prototypes.item[task.item].place_result, task.direction)),
      outcome = picked and { picked_up = picked } or nil,
    }
  end

  local built = c.surface.create_entity({
    name = task._entity_name,
    position = task.position,
    direction = task.direction,
    mirror = task.mirror or nil,
    type = task.belt_to_ground_type,
    force = c.force,
    raise_built = true,
  })
  if not built then
    return {
      status = "failed",
      detail = string.format("placing %s at (%.1f, %.1f) failed unexpectedly — try a slightly different spot",
        task.item, task.position.x, task.position.y),
    }
  end
  c.remove_item({ name = task.item, count = 1 })
  -- raise_built also reaches the registry; add is idempotent.
  pcall(registry.add, built)
  if expected_input or expected_output then
    task._placed_entity, task._placed_tick = built, game.tick
    task._expected_input, task._expected_output = expected_input, expected_output
    return nil
  end
  local pairing = M.underground_pairing(built)
  local detail = string.format("placed %s at (%.1f, %.1f)%s%s",
    task.item, built.position.x, built.position.y,
    built.direction ~= 0 and (" facing " .. dir_name(built.direction)) or "", pairing_note(pairing))
  return placed(task, c, built, { status = "done", detail = detail,
    outcome = pairing and { detail = detail, underground = pairing } or nil })
end

-- ----------------------------------------------------------------- rotate

M.rotate = {}

function M.rotate.start(task)
  companion.require_companion()
  validate_position(task.target, "rotate")
  if task.direction ~= nil then
    task.direction = math.floor(tonumber(task.direction) or 0) % 16
  end
end

function M.rotate.tick(task)
  local c = companion.get()
  if not c then return gone() end

  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local e = approach.find_entity_near(c, task.target)
  if not e then
    return {
      status = "failed",
      detail = string.format("nothing to rotate at (%.1f, %.1f)", task.target.x, task.target.y),
    }
  end

  local entity_reached = approach.ensure_entity(task, c, e)
  if type(entity_reached) == "table" then return entity_reached end
  if entity_reached ~= "ok" then return nil end

  if task.direction then
    local ok = pcall(function() e.direction = task.direction end)
    if not ok or e.direction ~= task.direction then
      return { status = "failed", detail = "the " .. e.name .. " can't face that way" }
    end
    return { status = "done", detail = string.format("turned %s to face %s", e.name, dir_name(task.direction)) }
  end

  if not e.rotate() then
    return { status = "failed", detail = "the " .. e.name .. " can't be rotated" }
  end
  return { status = "done", detail = string.format("rotated %s — it now faces %s", e.name, dir_name(e.direction)) }
end

-- ------------------------------------------------------------- set_recipe
-- set_recipe {x, y, recipe, platform?}: on a planet the body walks within
-- reach and takes back what the old recipe held. With platform it is remote
-- (the platform's window, no body): the machine at {x, y} on that platform is
-- set in the tick the step runs and what it held goes to the hub. The recipe
-- must be unlocked and of a category the machine crafts (crushers: crushing).

local function validate_recipe_step(task, label)
  validate_position(task.target, label)
  if type(task.recipe) ~= "string" then error(label .. " requires recipe = <recipe name>", 0) end
  if task.platform ~= nil then platforms.check_selector(task.platform, label .. " platform") end
end

-- Why this machine takes no such recipe: {status = failed, ...} or nil.
local function recipe_refusal(e, recipe)
  local refused = placement_geometry.condition_refusal(e.surface, "recipe", recipe.name)
  if refused then
    return { status = "failed", detail = refused.reason, outcome = { code = refused.code, condition = refused.condition } }
  end
  if e.type ~= "assembling-machine" then
    if e.type == "furnace" then
      return {
        status = "failed",
        detail = "the " .. e.name .. " is a furnace — it picks its recipe automatically from what you insert",
        outcome = { code = "WRONG_MACHINE_TYPE", expected = "crafting_machine", actual = "furnace",
          corrective_hint = "Insert the smeltable input; do not call set_recipe for furnaces." },
      }
    end
    return { status = "failed", detail = "the " .. e.name .. " can't have a recipe set — only crafting machines can",
      outcome = { code = "WRONG_MACHINE_TYPE", expected = "crafting_machine", actual = e.type } }
  end
  local ok, categories = pcall(function() return e.prototype.crafting_categories end)
  if ok and type(categories) == "table" and not categories[recipe.category] then
    local names = {}
    for name in pairs(categories) do names[#names + 1] = name end
    table.sort(names)
    return { status = "failed",
      detail = string.format("the %s crafts %s recipes; %s is %s", e.name, table.concat(names, ", "), recipe.name,
        recipe.category),
      outcome = { code = "RECIPE_NOT_SETTABLE", category = recipe.category, crafts = names } }
  end
end

-- Puts items back somewhere real: into `into`'s inventory, the rest spilled
-- at `at` on `surface` (items.spill, recorded in `spilled`). Returns the
-- count taken in.
local function take_back(removed, into, surface, at, spilled)
  local taken = 0
  for _, stack in ipairs(type(removed) == "table" and removed or {}) do
    if stack.name and (stack.count or 0) > 0 then
      local item = { name = stack.name, count = stack.count, quality = stack.quality }
      local inserted = into and into.insert(item) or 0
      taken = taken + inserted
      if inserted < stack.count then
        item.count = stack.count - inserted
        items.spill(surface, at, item, spilled)
      end
    end
  end
  return taken
end

-- Sets the recipe on a reached machine; `into` takes what it held.
local function apply_recipe(task, e, recipe, into, surface, at, where)
  if not recipe then return { status = "failed", detail = "unknown recipe: '" .. task.recipe .. "'" } end
  local refused = recipe_refusal(e, recipe)
  if refused then return refused end
  local ok, removed = pcall(e.set_recipe, task.recipe)
  local spilled = {}
  local taken = ok and take_back(removed, into, surface, at, spilled) or 0
  local spill_note = spilled.count and string.format(" (spilled %d that did not fit at (%.1f, %.1f))", spilled.count,
    spilled.position.x, spilled.position.y) or ""
  local read_ok, assigned = pcall(e.get_recipe)
  if not ok or not read_ok or not assigned or assigned.name ~= task.recipe then
    return {
      status = "failed",
      detail = string.format("couldn't set %s on the %s — that machine probably can't craft it%s",
        task.recipe, e.name, spill_note),
      outcome = spilled.count and { code = "RECIPE_NOT_SET", spilled = spilled } or nil,
    }
  end
  return {
    status = "done",
    detail = string.format("set %s's recipe to %s%s%s", e.name, task.recipe,
      taken > 0 and string.format(" (took %d leftover items into %s)", taken, where) or "", spill_note),
    outcome = spilled.count and { code = "RECIPE_SET", spilled = spilled } or nil,
  }
end

M.set_recipe = {}

function M.set_recipe.start(task)
  -- A platform machine needs only a connected body (aboard or in transit
  -- too); a planet machine needs the character.
  local c = task.platform ~= nil and companion.require_present() or companion.require_companion()
  validate_recipe_step(task, "set_recipe")
  local r = c.force.recipes[task.recipe]
  if not r then
    error("unknown recipe: '" .. task.recipe .. "'")
  end
  if not r.enabled then
    error("recipe " .. task.recipe .. " isn't unlocked yet — research it first")
  end
end

-- A platform machine: remote, in this tick; what it held goes to the hub.
local function set_recipe_remote(task, c)
  local p, code, why = platforms.resolve(c.force, task.platform)
  if not p then return { status = "failed", detail = code .. ": " .. why, outcome = { code = code } } end
  local e, no_surface, why_not = platforms.entity_at(p, c.force, task.target)
  if no_surface then return { status = "failed", detail = no_surface .. ": " .. why_not, outcome = { code = no_surface } } end
  if not e then
    return { status = "failed", outcome = { code = "NO_ENTITY" },
      detail = string.format("NO_ENTITY: nothing at (%.1f, %.1f) on platform %s to set a recipe on",
        task.target.x, task.target.y, p.name) }
  end
  local hub = p.hub
  local into = hub and hub.valid and hub.get_inventory(defines.inventory.hub_main) or nil
  local result = apply_recipe(task, e, c.force.recipes[task.recipe], into, p.surface, e.position, "the hub")
  result.outcome = result.outcome or { code = result.status == "done" and "RECIPE_SET" or "RECIPE_NOT_SET" }
  result.outcome.entity = { name = e.name, position = { x = e.position.x, y = e.position.y },
    surface = platforms.surface_ref(p) }
  return result
end

function M.set_recipe.tick(task)
  if task.platform ~= nil then return set_recipe_remote(task, companion.require_present()) end
  local c = companion.get()
  if not c then return gone() end

  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local e = approach.find_entity_near(c, task.target)
  if not e then
    return {
      status = "failed",
      detail = string.format("nothing at (%.1f, %.1f) to set a recipe on", task.target.x, task.target.y),
    }
  end
  local entity_reached = approach.ensure_entity(task, c, e)
  if type(entity_reached) == "table" then return entity_reached end
  if entity_reached ~= "ok" then return nil end
  -- Ingredients of the previous recipe come back to us; overflow spills.
  return apply_recipe(task, e, c.force.recipes[task.recipe], c, c.surface, c.position, "my inventory")
end

local function recipe_task(step)
  return { target = { x = step.x, y = step.y }, recipe = step.recipe, platform = step.platform }
end

-- The plan action for tasks.register_action. A platform machine is remote:
-- no body, no reach, done in the tick the FIFO reaches it.
M.set_recipe_action = {
  runner = M.set_recipe,
  make_task = recipe_task,
  validate = function(step, index) validate_recipe_step(recipe_task(step), "queue_plan set_recipe step " .. index) end,
  remote = function(step) return step.platform ~= nil end,
}

-- set_recipe over RPC: a platform machine's recipe, at once (its platform's
-- window needs no body). A planet machine needs the body: a plan step.
function M.set_recipe_rpc(params)
  local body = companion.require_present()
  if type(params) ~= "table" or params.platform == nil then
    error("set_recipe over RPC sets a platform machine ({platform, x, y, recipe}); a planet machine needs the body:"
      .. " queue it as a plan step", 0)
  end
  local task = recipe_task(params)
  M.set_recipe.start(task)
  local result = set_recipe_remote(task, body)
  if result.status ~= "done" then
    local code = result.outcome and result.outcome.code
    local detail = tostring(result.detail)
    error((code and detail:sub(1, #code) ~= code) and (code .. ": " .. detail) or detail, 0)
  end
  result.outcome.recipe, result.outcome.detail = task.recipe, result.detail
  return result.outcome
end

return M
