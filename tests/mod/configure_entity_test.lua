-- Offline tests for configure_entity (actions/configure.lua): the body walks
-- within reach of an own entity, the settings are checked before any write
-- (an assembler with inserter settings is CONFIG_NOT_APPLICABLE and left as
-- it was), only what differs is written, the result reads the touched
-- fields back, and repeating the step changes nothing.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local mock = dofile(here .. "/factorio_api_mock.lua")
_G.storage, _G.game = {}, { tick = 1 }
_G.defines = { inventory = { chest = 1 } }
_G.prototypes = { item = { ["iron-plate"] = {}, ["copper-plate"] = {}, coal = {} } }

local own, enemy = { name = "player" }, { name = "enemy" }
local body = { valid = true, reach_distance = 10, force = own }
local target
local walked = {}
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
package.loaded["scripts.actions.approach"] = {
  ensure = function(_, _, position, reach) walked[#walked + 1] = { position = position, reach = reach }; return "ok" end,
  ensure_entity = function(_, _, e) walked[#walked + 1] = { entity = e }; return "ok" end,
  find_entity_near = function() return target end,
}
local configure = require("scripts.actions.configure")
local tasks_spec = configure.action

local function run(step)
  tasks_spec.validate(step, 1)
  local task = tasks_spec.make_task(step)
  task.id = 4
  tasks_spec.runner.start(task)
  return tasks_spec.runner.tick(task)
end

local filters = {}
local arm = mock.entity({ valid = true, name = "fast-inserter", type = "inserter", force = own, position = { x = 3.5, y = 4.5 },
  filter_slot_count = 5, use_filters = false, inserter_filter_mode = "whitelist", inserter_stack_size_override = 0,
  inserter_spoil_priority = "none",
  get_filter = function(index) return filters[index] and { name = filters[index] } or nil end,
  set_filter = function(index, filter) filters[index] = filter end,
  prototype = mock.entity_prototype({ name = "fast-inserter", type = "inserter", filter_count = 5 }) })
target = arm
local step = { action = "configure_entity", x = 3.5, y = 4.5,
  inserter = { filters = { "iron-plate", "copper-plate" }, mode = "whitelist", stack_size = 1 } }
local done = run(step)
check(done.status == "done" and done.outcome.code == "CONFIGURED" and walked[1].reach == 10 and walked[2].entity == arm,
  "configure_entity walks within reach of the entity first")
check(arm.use_filters == true and filters[1] == "iron-plate" and filters[2] == "copper-plate"
  and arm.inserter_stack_size_override == 1 and done.outcome.settings.inserter.stack_size == 1
  and #done.outcome.settings.inserter.filters == 2 and done.outcome.settings.inserter.spoil_priority == nil,
  "the filters and stack size are set and read back, and only the touched fields are returned")
check(#done.outcome.changed == 2 and done.outcome.changed[1] == "inserter.filters" and done.outcome.changed[2] == "inserter.stack_size",
  "changed names what was written (the mode already was whitelist)")
local repeated = run(step)
check(repeated.status == "done" and #repeated.outcome.changed == 0 and repeated.detail:match("already had"),
  "repeating it changes nothing")

local recipe = "iron-gear-wheel"
local machine = mock.entity({ valid = true, name = "assembling-machine-2", type = "assembling-machine", force = own,
  position = { x = 10.5, y = 10.5 }, get_recipe = function() return { name = recipe } end,
  prototype = mock.entity_prototype({ name = "assembling-machine-2", type = "assembling-machine" }) })
target = machine
local refused = run({ action = "configure_entity", x = 10.5, y = 10.5, inserter = { stack_size = 2 } })
check(refused.status == "failed" and refused.outcome.code == "CONFIG_NOT_APPLICABLE"
  and refused.detail:match("assembling%-machine") and recipe == "iron-gear-wheel",
  "an assembler with inserter settings is CONFIG_NOT_APPLICABLE and left as it was")

target = mock.entity({ valid = true, name = "fast-inserter", type = "inserter", force = enemy, position = { x = 1, y = 1 } })
local foreign = run({ action = "configure_entity", x = 1, y = 1, inserter = { stack_size = 2 } })
check(foreign.status == "failed" and foreign.outcome.code == "NO_ENTITY", "another force's entity is not configured")

check(not pcall(tasks_spec.validate, { action = "configure_entity", x = 1, y = 1 }, 1),
  "a step without settings is refused at queue time")
local ok, err = pcall(tasks_spec.validate, { action = "configure_entity", x = 1, y = 1, splitter = { filter = "nope" } }, 2)
check(not ok and tostring(err):match("^UNKNOWN_ITEM: queue_plan configure_entity step 2.splitter.filter"),
  "an unknown item is refused at queue time")
check(configure.read_settings(arm).inserter.stack_size == 1 and configure.apply_settings ~= nil,
  "configure exports the one read and apply path")

mock.assert_clean()
print(failures == 0 and "\nALL CONFIGURE TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
