-- Building actions: place, rotate, set_recipe. Each approaches its target
-- first (build_distance for place, reach_distance otherwise).
local companion = require("scripts.companion")
local registry = require("scripts.registry")
local approach = require("scripts.actions.approach")
local output_targets = require("scripts.output_target")
local placement_geometry = require("scripts.placement_geometry")
local supply = require("scripts.actions.supply")

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

-- Why can_place_entity said no: name the blocker if we can find one.
local function blocked_reason(c, pos)
  for _, e in ipairs(c.surface.find_entities_filtered({ position = pos, radius = 1.0 })) do
    if e.valid and e ~= c and e.type ~= "resource" then
      return string.format("%s is in the way — pick a clear spot or remove it first", e.name)
    end
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
  local pairing = { belt_to_ground_type = built.belt_to_ground_type }
  local ok, neighbour = pcall(function() return built.neighbours end)
  if ok and neighbour and neighbour.valid then
    pairing.neighbour = { name = neighbour.name, belt_to_ground_type = neighbour.belt_to_ground_type,
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

-- ------------------------------------------------- footprint housekeeping

-- Trees and rocks never stop a placement: the body mines them first, one by
-- one, through the ordinary physical mine action. Returns "ok" once the
-- footprint holds none, nil while clearing, or a failed result.
local MAX_CLEARS = 16
local NATURAL_BLOCKERS = { "simple-entity", "tree" }
local function natural_blocker(c, area)
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

function M.clear_footprint(task, c, proto, position, direction)
  if task._clear then
    local result = supply.step(task, "_clear")
    if not result then return nil end
    if result.status ~= "done" then
      return { status = "failed", detail = "couldn't clear the placement footprint: " .. tostring(result.detail) }
    end
  end
  if task.auto_clear == false then return "ok" end
  local blocker = natural_blocker(c, placement_geometry.footprint(proto, position, direction))
  if not blocker then task._clears = nil; return "ok" end
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
-- nearest first; nil when none is found.
function M.footprint_exit(c, proto, position, direction)
  local area = placement_geometry.footprint(proto, position, direction)
  local p, lt, rb = c.position, area.left_top, area.right_bottom
  local candidates = { { x = p.x, y = lt.y - 2 }, { x = p.x, y = rb.y + 2 },
    { x = lt.x - 2, y = p.y }, { x = rb.x + 2, y = p.y } }
  table.sort(candidates, function(a, b)
    local da = (a.x - p.x) ^ 2 + (a.y - p.y) ^ 2
    local db = (b.x - p.x) ^ 2 + (b.y - p.y) ^ 2
    if da ~= db then return da < db end
    return a.y == b.y and a.x < b.x or a.y < b.y
  end)
  for _, candidate in ipairs(candidates) do
    local ok, clear = pcall(c.surface.find_non_colliding_position, c.name or "character", candidate, 0.5, 0.1)
    if ok and clear and not placement_geometry.overlaps(area,
      { left_top = { x = clear.x - 1.25, y = clear.y - 1.25 }, right_bottom = { x = clear.x + 1.25, y = clear.y + 1.25 } }) then
      return { x = clear.x, y = clear.y }
    end
  end
end

M.place = {}
M.place.resume = supply.resume

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
  if c.get_item_count(task.item) == 0 and task.auto_supply == false then
    error("I don't have any " .. task.item .. " in my inventory — craft or collect one first")
  end
  task.direction = math.floor(tonumber(task.direction) or 0) % 16
  task._entity_name = result.name
  local belt_error = M.belt_to_ground_error(task.item, result, task.belt_to_ground_type)
  if belt_error then error(belt_error) end
  if task.input_target ~= nil then
    if result.type ~= "inserter" then error(task.item .. " has no deterministic input target") end
    task._input_target = output_targets.resolve(c, task.input_target, "place input_target", "input")
    local matches, endpoint = output_targets.input_geometry_matches(c, result, task.position, task.direction,
      task._input_target.entity)
    if not matches then
      error(string.format("place input_target is not at the exact provisional input endpoint%s",
        endpoint and string.format(" (%.1f, %.1f)", endpoint.x, endpoint.y) or ""))
    end
  end
  if task.output_target ~= nil then
    task._output_target = output_targets.resolve(c, task.output_target, "place output_target")
    local matches, endpoint = output_targets.geometry_matches(c, result, task.position, task.direction,
      task._output_target.entity)
    if not matches then
      error(string.format("place output_target is not at the exact provisional output endpoint%s",
        endpoint and string.format(" (%.1f, %.1f)", endpoint.x, endpoint.y) or ""))
    end
  end
end

function M.place.tick(task)
  local c = companion.get()
  if not c then return gone() end

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
      return {
        status = "done",
        detail = string.format("placed %s at (%.1f, %.1f); provisional output geometry is valid, but Factorio's runtime output target is pending first output",
          task.item, built.position.x, built.position.y),
      }
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
    return {
      status = "done",
      detail = string.format("placed %s at (%.1f, %.1f)%s",
        task.item, built.position.x, built.position.y,
        task.direction ~= 0 and (" facing " .. dir_name(task.direction)) or ""),
    }
  end

  -- Auto-supply (default on): fetch the item once, up to a stack.
  if c.get_item_count(task.item) == 0 and task.auto_supply ~= false and not task._supplied then
    local supplied = supply.ensure(task, { { name = task.item, count = 1 } }, { bulk = true })
    if not supplied then return nil end
    task._supplied = true
    if supplied.status ~= "done" then
      return { status = "failed", detail = "can't place " .. task.item .. ": " .. tostring(supplied.detail),
        outcome = supplied.outcome }
    end
  end

  local proto = prototypes.item[task.item].place_result
  -- A tree or rock being cleared moves the body: finish that first.
  if task._clear then
    local cleared = M.clear_footprint(task, c, proto, task.position, task.direction)
    if cleared ~= "ok" then return cleared end
  end
  local reached = approach.ensure(task, c, task.position, c.build_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  if c.get_item_count(task.item) == 0 then
    return { status = "failed", detail = "I no longer have any " .. task.item .. " in my inventory" }
  end
  local cleared = M.clear_footprint(task, c, proto, task.position, task.direction)
  if cleared ~= "ok" then return cleared end

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
    return {
      status = "failed",
      detail = string.format("can't place %s at (%.1f, %.1f) — %s",
        task.item, task.position.x, task.position.y,
        placement_reason == "CODEX_BODY_OVERLAP" and "CODEX_BODY_OVERLAP — walk clear of the exact collision footprint" or blocked_reason(c, task.position)),
    }
  end

  local built = c.surface.create_entity({
    name = task._entity_name,
    position = task.position,
    direction = task.direction,
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
    task.direction ~= 0 and (" facing " .. dir_name(task.direction)) or "", pairing_note(pairing))
  return { status = "done", detail = detail,
    outcome = pairing and { detail = detail, underground = pairing } or nil }
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

M.set_recipe = {}

function M.set_recipe.start(task)
  local c = companion.require_companion()
  validate_position(task.target, "set_recipe")
  if type(task.recipe) ~= "string" then
    error("set_recipe requires recipe = <recipe name>")
  end
  local r = c.force.recipes[task.recipe]
  if not r then
    error("unknown recipe: '" .. task.recipe .. "'")
  end
  if not r.enabled then
    error("recipe " .. task.recipe .. " isn't unlocked yet — research it first")
  end
end

function M.set_recipe.tick(task)
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

  local ok, removed = pcall(e.set_recipe, task.recipe)
  if not ok then
    return {
      status = "failed",
      detail = string.format("couldn't set %s on the %s — that machine probably can't craft it",
        task.recipe, e.name),
    }
  end

  -- Ingredients of the previous recipe come back to us; overflow spills.
  local taken = 0
  if type(removed) == "table" then
    for _, stack in ipairs(removed) do
      if stack.name and (stack.count or 0) > 0 then
        local inserted = c.insert({ name = stack.name, count = stack.count })
        taken = taken + inserted
        if inserted < stack.count then
          pcall(c.surface.spill_item_stack, {
            position = c.position,
            stack = { name = stack.name, count = stack.count - inserted },
            force = c.force,
          })
        end
      end
    end
  end
  local read_ok, assigned = pcall(e.get_recipe)
  if not read_ok or not assigned or assigned.name ~= task.recipe then
    return {
      status = "failed",
      detail = string.format("couldn't set %s on the %s — that machine probably can't craft it",
        task.recipe, e.name),
    }
  end
  return {
    status = "done",
    detail = string.format("set %s's recipe to %s%s", e.name, task.recipe,
      taken > 0 and string.format(" (took %d leftover items into my inventory)", taken) or ""),
  }
end

return M
