-- configure_entity {x, y, platform?, inserter?, splitter?, chest?, collector?,
-- silo?}: sets what a player sets in an own entity's window
-- (entity_settings.lua): every setting is checked against the entity before
-- anything is written, and only what differs is written. No items, no time.
-- On a planet the body walks within reach. With platform it is remote (the
-- platform's window, no body): the entity at {x, y} on that platform's
-- surface is set in the tick the step runs, or at once over RPC.
-- Result: {entity:{name, position, surface?}, settings: the touched fields as
-- they now are, changed:[group.field], notes?}. Repeating it changes nothing.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local entity_settings = require("scripts.entity_settings")
local platforms = require("scripts.platforms")

local M = {}

-- The one settings path, for every caller.
M.read_settings, M.apply_settings = entity_settings.read, entity_settings.apply

local function point(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

local function settings_of(step)
  return { inserter = step.inserter, splitter = step.splitter, chest = step.chest, collector = step.collector,
    silo = step.silo }
end

local function validate(step, label)
  if not point(step.target) then error(label .. " needs x and y", 0) end
  if step.platform ~= nil then platforms.check_selector(step.platform, label .. " platform") end
  entity_settings.validate(step.settings, label)
end

local Runner = {}

function Runner.start(task)
  companion.require_companion()
  validate(task, "configure_entity")
end

local function failed(code, detail, e, surface)
  return { status = "failed", detail = detail, outcome = { code = code,
    entity = e and { name = e.name, position = { x = e.position.x, y = e.position.y }, surface = surface } or nil } }
end

-- Checks, writes and reads back the settings on a reached entity.
local function configure(task, e, surface)
  local code, message = entity_settings.check(e, task.settings)
  if code then return failed(code, message, e, surface) end
  local changed, notes = entity_settings.apply(e, task.settings)
  local outcome = { code = "CONFIGURED",
    entity = { name = e.name, position = { x = e.position.x, y = e.position.y }, surface = surface },
    settings = entity_settings.readback(e, task.settings), changed = changed, notes = #notes > 0 and notes or nil }
  local detail = #changed > 0 and string.format("configured the %s: %s", e.name, table.concat(changed, ", "))
    or string.format("the %s already had these settings", e.name)
  if #notes > 0 then detail = detail .. " — " .. table.concat(notes, "; ") end
  return { status = "done", detail = detail, outcome = outcome }
end

-- A platform entity: remote, in this tick.
local function configure_remote(task, force)
  local p, code, why = platforms.resolve(force, task.platform)
  if not p then return failed(code, code .. ": " .. why) end
  local e, no_surface, why_not = platforms.entity_at(p, force, task.target)
  if no_surface then return failed(no_surface, no_surface .. ": " .. why_not) end
  local surface = platforms.surface_ref(p)
  if not e then
    return failed("NO_ENTITY", string.format("NO_ENTITY: no own entity at (%.1f, %.1f) on platform %s to configure",
      task.target.x, task.target.y, p.name))
  end
  return configure(task, e, surface)
end

function Runner.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  if task.platform ~= nil then return configure_remote(task, c.force) end
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
  return configure(task, e)
end

local function make_task(step)
  return { target = { x = step.x, y = step.y }, platform = step.platform, settings = settings_of(step) }
end

-- The plan action for tasks.register_action. A platform target is remote: no
-- body, no reach, done in the tick the FIFO reaches it.
M.action = {
  runner = Runner,
  make_task = make_task,
  validate = function(step, index) validate(make_task(step), "queue_plan configure_entity step " .. index) end,
  remote = function(step) return step.platform ~= nil end,
}

-- configure_entity over RPC: a platform entity's settings, at once (its
-- platform's window needs no body). A planet entity needs the body: a plan
-- step.
function M.rpc(params)
  local c = companion.require_companion()
  if type(params) ~= "table" or params.platform == nil then
    error("configure_entity over RPC sets a platform entity ({platform, x, y, ...}); a planet entity needs the body:"
      .. " queue it as a plan step", 0)
  end
  local task = make_task(params)
  validate(task, "configure_entity")
  local result = configure_remote(task, c.force)
  if result.status ~= "done" then error(result.detail, 0) end
  return result.outcome
end

return M
