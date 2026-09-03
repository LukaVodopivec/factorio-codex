-- Building actions: place, rotate, set_recipe. Each approaches its target
-- first (build_distance for place, reach_distance otherwise).
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local output_targets = require("scripts.output_target")

local M = {}

local direction_names = {}
for name, value in pairs(defines.direction) do
  direction_names[value] = name
end

local function dir_name(d)
  return direction_names[d] or tostring(d)
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

M.place = {}

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
  if c.get_item_count(task.item) == 0 then
    error("I don't have any " .. task.item .. " in my inventory — craft or collect one first")
  end
  task.direction = math.floor(tonumber(task.direction) or 0) % 16
  task._entity_name = result.name
  if task.output_target ~= nil then
    task._output_target = output_targets.resolve(c, task.output_target, "place output_target")
    local matches, endpoint = output_targets.geometry_matches(c, result, task.position, task.direction,
      task._output_target.entity)
    if not matches then
      error(string.format("place output_target is not at the exact output endpoint%s",
        endpoint and string.format(" (%.1f, %.1f)", endpoint.x, endpoint.y) or ""))
    end
  end
end

function M.place.tick(task)
  local c = companion.get()
  if not c then return gone() end

  if task._placed_entity then
    if game.tick <= task._placed_tick then return nil end
    local built, expected_output = task._placed_entity, task._expected_output
    local binding = output_targets.binding_status(built, expected_output, task._placed_tick)
    if binding == "pending" then return nil end
    task._placed_entity, task._placed_tick, task._expected_output = nil, nil, nil
    if binding == "invalid" then
      return { status = "failed", detail = "the exact placed entity vanished before output binding could be verified" }
    end
    if binding == "target-invalid" then
      return { status = "failed", detail = "the exact expected output target vanished before its output tile could be verified" }
    end
    if binding ~= "matched" then
      return {
        status = "failed",
        detail = string.format("placed %s at (%.1f, %.1f), but its live output tile did not resolve to the expected target (%s); recover the exact placed entity before retrying",
          task.item, built.position.x, built.position.y, binding),
      }
    end
    return {
      status = "done",
      detail = string.format("placed %s at (%.1f, %.1f)%s",
        task.item, built.position.x, built.position.y,
        task.direction ~= 0 and (" facing " .. dir_name(task.direction)) or ""),
    }
  end

  local reached = approach.ensure(task, c, task.position, c.build_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  if c.get_item_count(task.item) == 0 then
    return { status = "failed", detail = "I no longer have any " .. task.item .. " in my inventory" }
  end

  local expected_output
  if task._output_target then
    local current = output_targets.resolve(c, task.output_target, "place output_target")
    if current.entity ~= task._output_target.entity then
      return { status = "failed", detail = "place output_target changed before placement; observe again" }
    end
    local matches = output_targets.geometry_matches(c, prototypes.item[task.item].place_result,
      task.position, task.direction, current.entity)
    if not matches then
      return { status = "failed", detail = "place output geometry changed before placement; observe again" }
    end
    expected_output = current.entity
  end

  local can_place = c.surface.can_place_entity({
    name = task._entity_name,
    position = task.position,
    direction = task.direction,
    force = c.force,
    build_check_type = defines.build_check_type.manual,
  })
  if not can_place then
    return {
      status = "failed",
      detail = string.format("can't place %s at (%.1f, %.1f) — %s",
        task.item, task.position.x, task.position.y, blocked_reason(c, task.position)),
    }
  end

  local built = c.surface.create_entity({
    name = task._entity_name,
    position = task.position,
    direction = task.direction,
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
  if expected_output then
    task._placed_entity, task._placed_tick, task._expected_output = built, game.tick, expected_output
    return nil
  end
  return {
    status = "done",
    detail = string.format("placed %s at (%.1f, %.1f)%s",
      task.item, built.position.x, built.position.y,
      task.direction ~= 0 and (" facing " .. dir_name(task.direction)) or ""),
  }
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
      }
    end
    return { status = "failed", detail = "the " .. e.name .. " can't have a recipe set — only crafting machines can" }
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
