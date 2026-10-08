-- The repeat counter and recent draws on plan outcomes (tasks.lua), the
-- change journal and own entity losses (journal.lua): who changed what,
-- merged and bounded rings, and the reads built on them.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local nauvis = { index = 1, name = "nauvis", valid = true }
local orbit = { index = 2, name = "platform-1", valid = true, platform = { index = 1 } }
local by_index = { nauvis, orbit }
_G.game = { tick = 0, get_surface = function(index) return by_index[index] end }
_G.defines = { shooting = { not_shooting = 0 } }
_G.storage = {}
local carried = { ["steel-plate"] = 30 }
local body = { valid = true, position = { x = 0, y = 0 }, surface = nauvis, force = { name = "player" },
  walking_state = {}, mining_state = {}, crafting_queue = {}, crafting_queue_size = 0 }
body.get_main_inventory = function() return { get_contents = function()
  local rows = {}
  for name, count in pairs(carried) do if count > 0 then rows[#rows + 1] = { name = name, count = count } end end
  return rows
end } end
local held = false
local stub = { get = function() return body end, require_companion = function() return body end,
  human_control = function() return held, 0 end }
package.loaded["scripts.companion"] = stub
dofile(here .. "/body_stub.lua")(stub, function() return body end)

-- Scripted step results: the place runner answers the next one; a take
-- from own stores is reported to the draw listener tasks.lua set.
local results = {}
local function runner(kind) return { start = function() end, tick = function()
  local result = kind == "place" and table.remove(results, 1) or { status = "done", detail = kind .. " done" }
  if result.take then draw(result.take[1], result.take[2]); result.take = nil end
  if result.use then carried[result.use[1]] = carried[result.use[1]] - result.use[2]; result.use = nil end
  return result
end } end
package.loaded["scripts.actions.walk"], package.loaded["scripts.actions.mine"] = runner("walk_to"), runner("mine")
package.loaded["scripts.actions.pickup"], package.loaded["scripts.actions.craft"] = runner("pickup"), runner("craft")
package.loaded["scripts.actions.build"] = { place = runner("place"), rotate = runner("rotate"),
  set_recipe_action = { runner = runner("set_recipe"), make_task = function() return {} end } }
package.loaded["scripts.actions.transfer"] = { insert = runner("insert"), extract = runner("extract"),
  flush_action = { runner = runner("flush_fluid"), make_task = function() return {} end } }
package.loaded["scripts.actions.build_plan"] = runner("build_plan")
local supply = require("scripts.actions.supply")
local set_listener = supply.set_draw_listener
supply.set_draw_listener = function(fn) _G.draw = fn; set_listener(fn) end
local state = require("scripts.state")
local tasks = require("scripts.tasks")
local journal = require("scripts.journal")
state.init()
storage.registry.force = "player"

local function run(plan)
  local queued = tasks.queue_plan(plan)
  for _ = 1, 4 do game.tick = game.tick + 1; tasks.on_tick() end
  return tasks.plan_status({ plan_id = queued.plan_id })
end
local function shortfall()
  return { status = "failed", detail = "SUPPLY_SHORTFALL: missing 5 steel-plate",
    outcome = { code = "SUPPLY_SHORTFALL", missing = { { item = "steel-plate", missing = 5 } } } }
end
local place = { action = "place_entity", name = "steam-engine", x = 1.5, y = 1.5 }

-- A package takes 20 steel from own stores; a pilot plan uses 10 carried.
results = { { status = "done", detail = "placed", take = { "steel-plate", 20 } } }
local package_plan = run({ steps = { { action = "place_entity", name = "pipe", x = 9, y = 9 } }, source = "package:oil" })
results = { { status = "done", detail = "placed", use = { "steel-plate", 10 } } }
local engine_plan = run({ steps = { { action = "place_entity", name = "steam-engine", x = 20, y = 1 } } })
results = { shortfall() }
local first = run({ steps = { place } })
local draws = first.outcomes[1].result.recent_draws
check(first.status == "failed" and first.outcomes[1]["repeat"] == nil and draws and #draws == 2
  and draws[1].from == "inventory" and draws[1].count == 10 and draws[1].plan_id == engine_plan.plan_id
  and draws[1].source == "pilot" and draws[2].from == "stores" and draws[2].count == 20
  and draws[2].source == "package:oil" and draws[2].plan_id == package_plan.plan_id,
  "a SUPPLY_SHORTFALL names the newest plans that took or used its item, newest first")

results = { shortfall() }
local second = run({ steps = { { action = "walk_to", x = 0, y = 0 }, place } })
local log = tasks.activity_log({ limit = 1 }).entries[1]
check(second.outcomes[2]["repeat"] == 2 and log.plan_id == second.plan_id and log["repeat"] == 2
  and log.code == "SUPPLY_SHORTFALL",
  "the same code at the same action and target again says repeat 2 on the outcome and the activity_log row")
results = { shortfall() }
check(run({ steps = { place } }).outcomes[1]["repeat"] == 3, "the count goes on: 3")
results = { { status = "failed", detail = "PLACEMENT_BLOCKED: blocked by rock", outcome = { code = "PLACEMENT_BLOCKED" } } }
check(run({ steps = { place } }).outcomes[1]["repeat"] == nil, "another code at the same target starts again")
results = { { status = "done", detail = "placed" } }
run({ steps = { place } })
results = { { status = "failed", detail = "PLACEMENT_BLOCKED: blocked by rock", outcome = { code = "PLACEMENT_BLOCKED" } } }
check(run({ steps = { place } }).outcomes[1]["repeat"] == nil and storage.repeats.size == 1,
  "a completed step at the target clears its count")
results = { shortfall() }
check(run({ steps = { { action = "place_entity", name = "steam-engine", x = 30, y = 1 } } }).outcomes[1]["repeat"] == nil,
  "another target counts on its own")
for i = 1, tasks.MAX_REPEAT_KEYS + 5 do
  results = { shortfall() }
  run({ steps = { { action = "place_entity", name = "pipe", x = 100 + i, y = 1 } } })
end
check(storage.repeats.size == tasks.MAX_REPEAT_KEYS, "the counter keeps at most MAX_REPEAT_KEYS targets")

-- The journal: a plan step's change names the plan and its action.
local rotate = run({ steps = { { action = "rotate_entity", x = 4.5, y = 4.5 } }, source = "package:belts" })
local changes = tasks.activity_log({ limit = 1, changes = { since_tick = rotate.transitions[1].tick } }).changes
check(#changes.rows == 1 and changes.rows[1].op == "rotated" and changes.rows[1].action == "rotate_entity"
  and changes.rows[1].by == "package:belts" and changes.rows[1].plan_id == rotate.plan_id
  and changes.rows[1].surface == "nauvis" and changes.rows[1].position.x == 4.5 and changes.size == journal.SIZE,
  "a rotate step's change names its package and plan in the journal")

local function entity(name, x, y, force, surface)
  return { valid = true, name = name, type = name, position = { x = x, y = y }, surface = surface or nauvis,
    force = { name = force or "player" } }
end
storage.companion = { player_index = 1 }
local since = game.tick
game.tick = game.tick + 1
storage.tasks.active = { type = "plan", id = 77, source = "package:smelt" }
for i = 1, 5 do journal.on_built({ entity = entity("transport-belt", i, 0) }) end
journal.on_removed({ entity = entity("stone-furnace", 1, 1), player_index = 1 })
held = true
journal.on_removed({ entity = entity("stone-furnace", 3, 1), player_index = 1 })
held = false
storage.tasks.active = nil
journal.on_built({ entity = entity("inserter", 2, 2), player_index = 1 })
journal.on_built({ entity = entity("inserter", 2, 3), player_index = 2 })
journal.on_built({ entity = entity("roboport", 8, 8), robot = {} })
journal.on_built({ entity = entity("pipe", 0, 0, nil, orbit), platform = {} })
journal.on_built({ entity = entity("tree", 5, 5, "neutral") })
journal.on_built({ entity = entity("entity-ghost", 6, 6) })
journal.on_rotated({ entity = entity("inserter", 2, 2), player_index = 1 })
journal.on_settings_pasted({ destination = entity("assembling-machine-1", 7, 7), player_index = 2 })
local rows = tasks.activity_log({ limit = 1, changes = { since_tick = since, limit = 64 } }).changes.rows
check(#rows == 8 and rows[1].op == "built" and rows[1].count == 5 and rows[1].by == "package:smelt"
  and rows[1].plan_id == 77 and rows[1].area.left_top.x == 1 and rows[1].area.right_bottom.x == 5
  and rows[1].position == nil, "consecutive builds of one plan merge into a row with a count and their area")
check(rows[2].op == "removed" and rows[2].by == "package:smelt" and rows[2].position.x == 1 and rows[3].by == "human"
  and rows[4].by == "human" and rows[4].count == 2 and rows[5].by == "robot"
  and rows[6].by == "platform" and rows[6].surface == "platform:1" and rows[7].op == "rotated"
  and rows[7].by == "human" and rows[8].op == "changed" and rows[8].name == "assembling-machine-1",
  "the body's own mining is its plan's, a held body's or another player's change a human's, robots and platforms theirs; "
    .. "foreign entities and ghosts are not journaled")
local inside = tasks.activity_log({ limit = 1, changes = { since_tick = since, surface = "nauvis",
  area = { left_top = { x = 1.5, y = 0.5 }, right_bottom = { x = 3, y = 2.5 } }, limit = 2 } }).changes
check(#inside.rows == 2 and inside.omitted == 1 and inside.rows[1].name == "inserter" and inside.rows[2].op == "rotated",
  "a journal read keeps the newest rows touching the area on the surface and counts the rest")
check(not pcall(tasks.activity_log, { changes = { limit = 65 } })
  and not pcall(tasks.activity_log, { changes = { area = { left_top = { x = 1 } } } }),
  "a journal read validates its filter")
for i = 1, journal.SIZE + 10 do journal.note("built", "pipe-" .. i, { x = i, y = 0 }, 1, "human") end
local all = tasks.activity_log({ limit = 1, changes = { limit = 64 } }).changes
check(#all.rows == 64 and all.omitted == journal.SIZE - 64 and all.rows[64].name == "pipe-" .. (journal.SIZE + 10),
  "the journal is a fixed ring of SIZE rows, newest kept")

-- Losses: own deaths only, merged, with what killed them.
local train = { valid = true, name = "locomotive", type = "locomotive" }
game.tick = 1000
journal.on_entity_died({ entity = entity("transport-belt", 10, 10), cause = train, force = { name = "player" } })
game.tick = 1010
journal.on_entity_died({ entity = entity("transport-belt", 11, 10), cause = train, force = { name = "player" } })
journal.on_entity_died({ entity = entity("small-biter", 11, 11, "enemy") })
game.tick = 1020
journal.on_entity_died({ entity = entity("solar-panel", 0, 0, nil, orbit), cause = { valid = true, name = "small-asteroid",
  type = "asteroid" }, force = { name = "enemy" } })
local loss_tick, losses = journal.loss_state()
check(loss_tick == 1020 and #losses == 2 and losses[1].name == "transport-belt" and losses[1].count == 2
  and losses[1].position.x == 11 and losses[1].killed_by.name == "locomotive" and losses[1].surface == "nauvis"
  and losses[2].surface == "platform:1" and losses[2].killed_by.force == "enemy",
  "own deaths are kept as merged losses with what killed them; another force's are not")
local problem = journal.problem_rows(1, nil)
check(#problem == 1 and problem[1].status == "destroyed" and problem[1].count == 2 and #journal.problem_rows(1, 1010) == 0
  and #journal.problem_rows(2, nil) == 1, "losses are destroyed problem rows of their own surface, since a tick")
game.tick = 1020 + journal.LOSS_WINDOW_TICKS + 1
check(#journal.problem_rows(1, nil) == 0, "without since_tick only the last five minutes of losses are problems")
local died = tasks.activity_log({ limit = 1, changes = { since_tick = 999 } }).changes.rows
check(died[#died].op == "died" and died[#died].by == "small-asteroid" and died[#died - 1].by == "locomotive"
  and died[#died - 1].count == 2, "a death is a journal row whose by is what killed it")
for i = 1, journal.LOSS_SIZE + 4 do
  game.tick = game.tick + 1000
  journal.on_entity_died({ entity = entity("wall-" .. i, i, 0) })
end
local _, shown = journal.loss_state()
check(#shown == journal.SHOWN_LOSSES and shown[#shown].name == "wall-" .. (journal.LOSS_SIZE + 4)
  and #journal.losses(-1) == journal.LOSS_SIZE, "the loss ring is bounded and event_state shows the newest few")

if failures > 0 then print(failures .. " FAILURES"); os.exit(1) end
print("ALL EVENTS JOURNAL TESTS PASSED")
