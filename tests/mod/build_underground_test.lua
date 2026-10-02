-- Offline tests for explicit underground-belt ends on place and build_plan.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
_G.storage = {}
_G.game = { tick = 100 }
_G.defines = { build_check_type = { manual = 1 }, direction = { north = 0, east = 4, south = 8, west = 12 } }
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

local inventory, created, neighbour = {}, {}, nil
local character = {
  valid = true, position = { x = 20, y = 20 }, build_distance = 10, crafting_queue_size = 0,
  force = { recipes = {} },
  get_item_count = function(name) return inventory[name] or 0 end,
  remove_item = function(args) inventory[args.name] = inventory[args.name] - args.count end,
  can_reach_entity = function() return true end,
}
character.surface = {
  can_place_entity = function() return true end,
  find_entities_filtered = function() return {} end,
  create_entity = function(args)
    created[#created + 1] = args
    local belt = args.name == "underground-belt"
    local entity = { valid = true, name = args.name, position = args.position,
      type = belt and "underground-belt" or "transport-belt", belt_to_ground_type = belt and (args.type or "input") or nil }
    if belt then
      entity.neighbours = neighbour
    else
      setmetatable(entity, { __index = function(_, key)
        if key == "neighbours" then error("neighbours is not available for transport-belt") end
      end })
    end
    return entity
  end,
}
package.loaded["scripts.companion"] = {
  require_companion = function() return character end,
  get = function() return character end,
}
package.loaded["scripts.actions.approach"] = {
  ensure = function() return "ok" end,
  ensure_entity = function() return "ok" end,
}
_G.prototypes = { item = {
  ["underground-belt"] = { place_result = { name = "underground-belt", type = "underground-belt" } },
  ["transport-belt"] = { place_result = { name = "transport-belt", type = "transport-belt" } },
} }

local build = require("scripts.actions.build")
local build_plan = require("scripts.actions.build_plan")

-- place: validation before any walking.
inventory = { ["underground-belt"] = 4, ["transport-belt"] = 4 }
local ok, err = pcall(build.place.start, { item = "transport-belt", position = { x = 0.5, y = 0.5 },
  belt_to_ground_type = "input" })
check(not ok and tostring(err):match("applies only to underground belts; transport%-belt places a transport%-belt") ~= nil,
  "place: belt_to_ground_type on a non-underground item fails clearly")
ok, err = pcall(build.place.start, { item = "underground-belt", position = { x = 0.5, y = 0.5 },
  belt_to_ground_type = "sideways" })
check(not ok and tostring(err):match('must be "input" or "output"') ~= nil,
  "place: an unknown belt_to_ground_type is rejected")

-- place: the requested end reaches create_entity and the pairing is reported.
neighbour = { valid = true, name = "underground-belt", belt_to_ground_type = "input", position = { x = 0.5, y = 3.5 } }
local task = { item = "underground-belt", position = { x = 0.5, y = 0.5 }, direction = 0, belt_to_ground_type = "output" }
build.place.start(task)
local result = build.place.tick(task)
check(created[#created].type == "output" and created[#created].direction == 0,
  "place: create_entity receives type=output")
check(result and result.status == "done" and result.outcome and result.outcome.underground
  and result.outcome.underground.belt_to_ground_type == "output"
  and result.outcome.underground.neighbour.position.y == 3.5
  and result.outcome.underground.neighbour.belt_to_ground_type == "input"
  and result.detail:match("as output end paired with underground%-belt at %(0%.5, 3%.5%)") ~= nil
  and result.outcome.detail == result.detail,
  "place: the bound neighbour is reported in the structured outcome and detail")

neighbour = nil
task = { item = "underground-belt", position = { x = 0.5, y = 0.5 }, belt_to_ground_type = "input" }
build.place.start(task)
result = build.place.tick(task)
check(result.status == "done" and result.outcome.underground.neighbour == nil
  and result.detail:match("as input end; no paired underground yet") ~= nil,
  "place: an unpaired end says so")

task = { item = "transport-belt", position = { x = 0.5, y = 0.5 } }
build.place.start(task)
result = build.place.tick(task)
check(created[#created].type == nil and result.status == "done" and result.outcome == nil,
  "place: ordinary items keep the unchanged create_entity request and result")

-- build_plan: same validation and pass-through.
ok, err = pcall(build_plan.start, { steps = {
  { item = "underground-belt", position = { x = 0.5, y = 0.5 } },
  { item = "transport-belt", position = { x = 0.5, y = 1.5 }, belt_to_ground_type = "output" },
} })
check(not ok and tostring(err):match("step 2 is malformed: belt_to_ground_type applies only to underground belts") ~= nil,
  "build_plan: belt_to_ground_type on a non-underground step fails clearly")
ok, err = pcall(build_plan.start, { steps = {
  { item = "underground-belt", position = { x = 0.5, y = 0.5 }, belt_to_ground_type = 1 },
} })
check(not ok and tostring(err):match('step 1 is malformed: belt_to_ground_type must be "input" or "output"') ~= nil,
  "build_plan: an unknown belt_to_ground_type is rejected")

neighbour = nil
local plan = { auto_craft = false, steps = {
  { item = "underground-belt", position = { x = 0.5, y = 0.5 }, belt_to_ground_type = "input" },
  { item = "underground-belt", position = { x = 0.5, y = 3.5 }, belt_to_ground_type = "output" },
} }
build_plan.start(plan)
check(build_plan.tick(plan) == nil and created[#created].type == "input",
  "build_plan: the first step places the input end")
neighbour = { valid = true, name = "underground-belt", belt_to_ground_type = "input", position = { x = 0.5, y = 0.5 } }
result = build_plan.tick(plan)
check(created[#created].type == "output" and result and result.status == "done"
  and result.detail:match("step 2: placed underground%-belt as output end paired with underground%-belt at %(0%.5, 0%.5%)") ~= nil,
  "build_plan: the output end reaches create_entity and its pairing is reported")

if failures > 0 then os.exit(1) end
