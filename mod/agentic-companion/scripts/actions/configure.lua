-- configure_entity {x, y, inserter?, splitter?, chest?}: sets what a player
-- sets in an own entity's window (entity_settings.lua): the body walks within
-- reach, every setting is checked against the entity before anything is
-- written, and only what differs is written. No items, no time.
-- Result: {entity:{name, position}, settings: the touched fields as they now
-- are, changed:[group.field], notes?}. Repeating it changes nothing.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local entity_settings = require("scripts.entity_settings")

local M = {}

-- The one settings path, for every caller.
M.read_settings, M.apply_settings = entity_settings.read, entity_settings.apply

local function point(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

local function settings_of(step)
  return { inserter = step.inserter, splitter = step.splitter, chest = step.chest }
end

local function validate(step, label)
  if not point(step.target) then error(label .. " needs x and y", 0) end
  entity_settings.validate(step.settings, label)
end

local Runner = {}

function Runner.start(task)
  companion.require_companion()
  validate(task, "configure_entity")
end

local function failed(code, detail, e)
  return { status = "failed", detail = detail, outcome = { code = code,
    entity = e and { name = e.name, position = { x = e.position.x, y = e.position.y } } or nil } }
end

function Runner.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end
  local e = task._entity
  if not (e and e.valid) then e = approach.find_entity_near(c, task.target) end
  if not (e and e.valid and e.force == c.force) then
    return failed("NO_ENTITY", string.format("NO_ENTITY: no own entity at (%.1f, %.1f) to configure",
      task.target.x, task.target.y))
  end
  task._entity = e
  local entity_reached = approach.ensure_entity(task, c, e)
  if type(entity_reached) == "table" then return entity_reached end
  if entity_reached ~= "ok" then return nil end
  local code, message = entity_settings.check(e, task.settings)
  if code then return failed(code, message, e) end
  local changed, notes = entity_settings.apply(e, task.settings)
  local outcome = { code = "CONFIGURED", entity = { name = e.name, position = { x = e.position.x, y = e.position.y } },
    settings = entity_settings.readback(e, task.settings), changed = changed, notes = #notes > 0 and notes or nil }
  local detail = #changed > 0 and string.format("configured the %s: %s", e.name, table.concat(changed, ", "))
    or string.format("the %s already had these settings", e.name)
  if #notes > 0 then detail = detail .. " — " .. table.concat(notes, "; ") end
  return { status = "done", detail = detail, outcome = outcome }
end

-- The plan action for tasks.register_action.
M.action = {
  runner = Runner,
  make_task = function(step) return { target = { x = step.x, y = step.y }, settings = settings_of(step) } end,
  validate = function(step, index)
    validate({ target = { x = step.x, y = step.y }, settings = settings_of(step) }, "queue_plan configure_entity step " .. index)
  end,
}

return M
