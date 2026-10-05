-- Offline tests for idempotent placement and starter items
-- (scripts/actions/build.lua place, scripts/actions/build_plan.lua): the same
-- own entity already standing there is the placement (turned when it faces
-- another way), an insert map goes into what was placed, and an item still
-- in the crafting queue is waited for at the placement.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.storage = {}
_G.game = { tick = 10 }
_G.defines = { build_check_type = { manual = 1, ghost_revive = 2 }, inventory = { chest = 1 },
  direction = { north = 0, east = 4, south = 8, west = 12 } }
local half = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } }
local whole = { left_top = { x = -0.9, y = -0.9 }, right_bottom = { x = 0.9, y = 0.9 } }
_G.prototypes = { item = {
  ["transport-belt"] = { name = "transport-belt", stack_size = 100,
    place_result = { name = "transport-belt", type = "transport-belt", collision_box = half } },
  ["underground-belt"] = { name = "underground-belt", stack_size = 50,
    place_result = { name = "underground-belt", type = "underground-belt", collision_box = half } },
  ["stone-furnace"] = { name = "stone-furnace", stack_size = 50,
    place_result = { name = "stone-furnace", type = "furnace", collision_box = whole } },
  coal = { name = "coal", stack_size = 50 },
} }

local own = { name = "player" }
local inventory, world, created, rotations = {}, {}, {}, 0
local function spawn(name, kind, position, direction, extra)
  local e = { valid = true, name = name, type = kind, force = own, position = position, direction = direction or 0,
    supports_direction = kind ~= "furnace", inserted = {} }
  e.insert = function(stack) e.inserted[stack.name] = (e.inserted[stack.name] or 0) + stack.count; return stack.count end
  for k, v in pairs(extra or {}) do e[k] = v end
  world[#world + 1] = e
  return e
end
local body
body = {
  valid = true, position = { x = 0, y = 0 }, force = own, build_distance = 10, reach_distance = 10,
  crafting_queue = {}, crafting_queue_size = 0,
  get_item_count = function(name) return inventory[name] or 0 end,
  remove_item = function(stack) inventory[stack.name] = inventory[stack.name] - stack.count; return stack.count end,
  get_main_inventory = function() return { get_insertable_count = function() return 1000 end } end,
  surface = {
    find_entity = function(name, position)
      for _, e in ipairs(world) do
        if e.valid and e.name == name and math.abs(e.position.x - position.x) < 1 and math.abs(e.position.y - position.y) < 1 then
          return e
        end
      end
    end,
    can_place_entity = function(args)
      for _, e in ipairs(world) do
        if e.valid and math.abs(e.position.x - args.position.x) < 1 and math.abs(e.position.y - args.position.y) < 1 then
          return false
        end
      end
      return true
    end,
    create_entity = function(args)
      local e = spawn(args.name, prototypes.item[args.name].place_result.type, args.position, args.direction)
      created[#created + 1] = e
      return e
    end,
    find_entities_filtered = function() return {} end,
  },
}
own.recipes = { ["transport-belt"] = { name = "transport-belt", enabled = true,
  products = { { type = "item", name = "transport-belt", amount = 2 } } } }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
local reached = 0
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end,
  ensure_entity = function() reached = reached + 1; return "ok" end }
package.loaded["scripts.registry"] = { add = function() end, list = function() return {} end,
  machines = function() return {} end, stock_totals = function() return {} end }
local build = require("scripts.actions.build")
local build_plan = require("scripts.actions.build_plan")

local function place(task)
  build.place.start(task)
  local result
  for _ = 1, 20 do result = build.place.tick(task); if result then return result end end
end

-- The same belt facing the same way: done, nothing built, nothing used.
local belt = spawn("transport-belt", "transport-belt", { x = 3.5, y = 0.5 }, 4)
inventory["transport-belt"] = 1
local same = place({ item = "transport-belt", position = { x = 3.5, y = 0.5 }, direction = 4 })
check(same and same.status == "done" and same.outcome.code == "ALREADY_PLACED" and #created == 0
  and inventory["transport-belt"] == 1 and reached == 0,
  "placing a belt where the same belt already stands is done without building or walking")
-- Facing another way: the body turns it within reach.
local turned = place({ item = "transport-belt", position = { x = 3.5, y = 0.5 }, direction = 8 })
check(turned and turned.status == "done" and turned.outcome.code == "ROTATED_EXISTING" and belt.direction == 8
  and reached == 1 and #created == 0 and turned.detail:match("turned it to face south"),
  "placing it facing another way turns the existing belt")
-- Another entity there is no placement: the ordinary blocked failure.
inventory["stone-furnace"] = 1
local blocked = place({ item = "stone-furnace", position = { x = 3.5, y = 0.5 } })
check(blocked and blocked.status == "failed" and #created == 0, "a different entity on the spot still blocks the placement")
-- An underground belt counts only as the same end.
spawn("underground-belt", "underground-belt", { x = 6.5, y = 0.5 }, 4, { belt_to_ground_type = "input" })
check(build.existing(body, prototypes.item["underground-belt"].place_result, { x = 6.5, y = 0.5 }, 4, "output") == nil
  and build.existing(body, prototypes.item["underground-belt"].place_result, { x = 6.5, y = 0.5 }, 4, "input") ~= nil,
  "an underground belt is the same placement only as the same end")

-- Starter items: the insert map goes into what was placed.
inventory["stone-furnace"], inventory.coal = 1, 5
local fuelled = place({ item = "stone-furnace", position = { x = 10, y = 10 }, insert = { coal = 5 } })
check(fuelled and fuelled.status == "done" and #created == 1 and created[1].inserted.coal == 5 and inventory.coal == 0
  and fuelled.detail:match("inserted 5 coal"),
  "place_entity with insert fuels the furnace it placed")
inventory.coal = 3
local topped = place({ item = "stone-furnace", position = { x = 10, y = 10 }, insert = { coal = 3 } })
check(topped and topped.status == "done" and topped.outcome.code == "ALREADY_PLACED" and created[1].inserted.coal == 8,
  "placing it again only tops up its starter items")
inventory.coal = 1
local short = place({ item = "stone-furnace", position = { x = 10, y = 10 }, insert = { coal = 3 }, auto_supply = false })
check(short and short.status == "partial" and short.outcome.code == "PLACED_PARTIAL_INSERT",
  "starter items the body lacks make the placement partial")
check(not pcall(build.place.start, { item = "stone-furnace", position = { x = 0, y = 0 }, insert = { coal = 0 } }),
  "an insert map needs positive counts")

-- An item still being hand-crafted: the body goes there and waits for it.
inventory["transport-belt"] = 0
body.crafting_queue = { { index = 1, recipe = "transport-belt", count = 1, prerequisite = false } }
local waiting = { item = "transport-belt", position = { x = 20.5, y = 0.5 } }
build.place.start(waiting)
local early
for _ = 1, 5 do early = build.place.tick(waiting) end
check(early == nil and #created == 1, "a placement waits while its item is still in the crafting queue")
body.crafting_queue, inventory["transport-belt"] = {}, 2
local later = build.place.tick(waiting)
check(later and later.status == "done" and #created == 2 and inventory["transport-belt"] == 1,
  "and places it once the craft is done")

-- build_plan: the same rules per step.
created = {}
local run_belt = spawn("transport-belt", "transport-belt", { x = 30.5, y = 0.5 }, 0)
spawn("transport-belt", "transport-belt", { x = 31.5, y = 0.5 }, 4)
inventory["transport-belt"] = 1
local plan = { id = 5, auto_supply = false, steps = {
  { item = "transport-belt", position = { x = 30.5, y = 0.5 }, direction = 4 },
  { item = "transport-belt", position = { x = 31.5, y = 0.5 }, direction = 4 },
  { item = "transport-belt", position = { x = 32.5, y = 0.5 }, direction = 4 } } }
build_plan.start(plan)
local built
for _ = 1, 20 do built = build_plan.tick(plan); if built then break end end
check(built and built.status == "done" and plan._placed == 3 and #created == 1 and run_belt.direction == 4
  and inventory["transport-belt"] == 0 and plan._results[1].detail:match("turned it") and plan._results[2].detail:match("nothing to place"),
  "a build plan re-run over its own belts turns the wrong one, skips the right one and builds the missing one")

os.exit(failures == 0 and 0 or 1)
