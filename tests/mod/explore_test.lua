-- Offline tests for the explore plan action (scripts/actions/explore.lua):
-- legs toward the frontier, charting after each leg, a stop on a charted
-- patch of the wanted resource or at the distance budget, and turning a
-- heading the body cannot walk. Walking is a stub that moves the body.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.storage = {}
_G.game = { tick = 0 }
_G.prototypes = { entity = { ["crude-oil"] = { type = "resource" }, ["iron-ore"] = { type = "resource" },
  ["stone-furnace"] = { type = "furnace" } } }

local charted, pending, charts = {}, {}, 0
local function key(chunk) return chunk.x .. "," .. chunk.y end
local resources = {}
local body = { valid = true, position = { x = 0.5, y = 0.5 }, surface = {} }
body.force = {
  is_chunk_charted = function(_, chunk) return charted[key(chunk)] == true end,
  is_chunk_requested_for_charting = function(_, chunk) return pending[key(chunk)] ~= nil end,
  chart = function(_, area)
    charts = charts + 1
    pending[key({ x = math.floor(area[1][1] / 32), y = math.floor(area[1][2] / 32) })] = game.tick
  end,
}
local queries = {}
body.surface.find_entities_filtered = function(filter)
  queries[#queries + 1] = filter
  local out = {}
  for _, e in ipairs(resources) do
    local dx, dy = e.position.x - filter.position.x, e.position.y - filter.position.y
    if e.name == filter.name and dx * dx + dy * dy <= filter.radius * filter.radius then out[#out + 1] = e end
    if #out >= filter.limit then break end
  end
  return out
end
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }

-- Walking: the body reaches the leg's end unless the heading is blocked.
local legs, blocked = {}, function() return false end
package.loaded["scripts.actions.supply"] = {
  begin = function(owner, field, sub)
    assert(sub.type == "walk_to" and sub.arrival_mode == "vicinity", "a leg is an ordinary vicinity walk")
    legs[#legs + 1] = sub.target
    owner[field] = sub
  end,
  step = function(owner, field)
    local sub = owner[field]
    owner[field] = nil
    if blocked(sub.target) then return { status = "failed", detail = "PATH_NOT_FOUND: water" } end
    body.position = { x = sub.target.x, y = sub.target.y }
    return { status = "done" }
  end,
  resume = function() end,
}
local explore = require("scripts.actions.explore")

local function chart_around_body(radius)
  local cx, cy = math.floor(body.position.x / 32), math.floor(body.position.y / 32)
  for y = cy - radius, cy + radius do for x = cx - radius, cx + radius do charted[x .. "," .. y] = true end end
end
-- Requested chunks are charted chart_delay ticks after the request (the
-- next tick by default).
local chart_delay = 0
local function run(task, ticks)
  explore.start(task)
  for _ = 1, ticks or 5000 do
    local result = explore.tick(task)
    if result then return result end
    game.tick = game.tick + 1
    for k, at in pairs(pending) do
      if game.tick > at + chart_delay then charted[k], pending[k] = true, nil end
    end
  end
end
local function reset()
  charted, pending, charts, legs, queries, resources = {}, {}, 0, {}, {}, {}
  body.position = { x = 0.5, y = 0.5 }
  chart_around_body(2)
  blocked = function() return false end
  chart_delay = 0
end

-- Oil 400 tiles east: legs east, a chart pass after each, and a stop once
-- the patch is charted within view.
reset()
resources = { { valid = true, name = "crude-oil", position = { x = 400.5, y = 3.5 } } }
local oil = run({ resource = "crude-oil", direction = 4, max_distance = 1000 })
check(oil and oil.status == "done" and oil.outcome.code == "PATCH_FOUND" and oil.outcome.patch.position.x == 400.5
  and oil.outcome.walked >= 300 and oil.outcome.walked <= 400,
  "explore walks east until the oil patch 400 tiles away is charted in view")
local east = true
for _, leg in ipairs(legs) do if leg.y ~= 0.5 then east = false end end
check(east and #legs == oil.outcome.legs and charts > #legs, "every leg heads east and is charted around")
local bounded = true
for _, q in ipairs(queries) do if not (q.radius and q.radius <= explore.VIEW_RADIUS and q.limit and q.limit <= 64) then bounded = false end end
check(bounded and #queries == #legs + 1, "one bounded resource query per leg (and one before the first)")

-- The search covers what explore charts: a patch about 110 tiles beside a
-- leg's end (beyond the old 96-tile view) is found.
do
  reset()
  resources = { { valid = true, name = "crude-oil", position = { x = 200.5, y = 110.5 } } }
  local beside = run({ resource = "crude-oil", direction = 4, max_distance = 400 })
  check(explore.VIEW_RADIUS == 128 and beside and beside.status == "done" and beside.outcome.code == "PATCH_FOUND"
    and beside.outcome.patch.distance > 100 and beside.outcome.patch.distance <= 128,
    "explore searches the 128 tiles it charts around a leg's end and finds a patch 110 tiles beside it")
  -- Charting takes time: the search after a leg waits until the outer ring
  -- of the chunks it requested is charted, so a patch at the ring's edge
  -- counts (the body's own chunk was charted long before).
  reset()
  chart_delay = 40
  resources = { { valid = true, name = "crude-oil", position = { x = 192.4, y = 0.5 } } }
  local edge = run({ resource = "crude-oil", direction = 4, max_distance = 64 })
  check(edge and edge.status == "done" and edge.outcome.code == "PATCH_FOUND" and edge.outcome.patch.position.x == 192.4,
    "after a leg explore waits for the outer ring of its chart before it searches")
  -- A ring that is never charted ends the wait at the deadline, as before.
  reset()
  chart_delay = math.huge
  for x = -4, 4 do for y = -4, 4 do charted[x .. "," .. y] = true end end
  local stalled = run({ resource = "crude-oil", direction = 4, max_distance = 64 })
  check(stalled and stalled.status == "failed" and stalled.outcome.code == "EXPLORE_NOT_FOUND"
    and stalled.detail:match("within 128 tiles of the start or any leg's end"),
    "an uncharted ring ends the settle at its deadline and the shortfall names the searched radius")
end

-- The budget: no patch within max_distance is a named shortfall.
reset()
local none = run({ resource = "iron-ore", direction = 8, max_distance = 150 })
check(none and none.status == "failed" and none.outcome.code == "EXPLORE_NOT_FOUND" and none.outcome.walked >= 142
  and none.outcome.walked <= 150 and none.detail:match("after walking"),
  "explore stops at its distance budget and says the resource was not found")

-- No direction: the heading whose uncharted land is nearest.
reset()
for x = -3, 3 do for y = -6, 6 do charted[x .. "," .. y] = true end end
for y = -6, 6 do charted["4," .. y], charted["5," .. y], charted["-4," .. y] = true, true, true end
charted["-4,0"] = nil -- the land four chunks west is the nearest not charted
local scouted = run({ max_distance = 64 })
check(scouted and scouted.status == "done" and scouted.outcome.code == "EXPLORED" and legs[1].x < 0 and legs[1].y == 0.5,
  "without a heading explore walks toward the nearest uncharted land")

-- A heading the body cannot walk is turned 45 degrees at a time.
reset()
blocked = function(target) return target.y == 0.5 end
local turned = run({ direction = 4, max_distance = 100 })
check(turned and turned.status == "done" and legs[1].y == 0.5 and legs[2].y > 0.5 and legs[2].x > 0.5,
  "a blocked heading is turned to its neighbour")
reset()
blocked = function() return true end
local walled = run({ direction = 4, max_distance = 500 })
check(walled and walled.status == "failed" and walled.outcome.code == "EXPLORE_BLOCKED" and #legs == 4,
  "a heading and its neighbours all blocked end the explore")

check(not pcall(explore.action.validate, { max_distance = 10 }, 1)
  and not pcall(explore.action.validate, { max_distance = 100, resource = "stone-furnace" }, 1)
  and not pcall(explore.action.validate, { max_distance = 100, direction = 16 }, 1)
  and pcall(explore.action.validate, { max_distance = 100, resource = "crude-oil", direction = 12 }, 1),
  "explore takes max_distance 32-3000, a resource name and a direction 0-15")
check(explore.action.budget_steps({ max_distance = 640 }) == 22, "a plan's budget grows with the distance to walk")

os.exit(failures == 0 and 0 or 1)
