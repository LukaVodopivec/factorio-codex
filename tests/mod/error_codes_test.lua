-- Every failure carries a code and no message names the mod's Lua source:
-- the RPC error path, plan steps (a runner that raises at start or tick, one
-- that fails without a code, a partial one), direct tasks and the activity
-- log; caught errors land in the bounded error ring that ping shows.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local LOCATION = "%.lua:%d+:"

-- The message Factorio gave for a mine refusal on an entity
-- holding fluid, with the mod's chunk location in front.
local FLUID_REFUSAL = "__agentic-companion__/scripts/actions/mine.lua:294: refusing to recover a player-owned entity"
  .. " with fluids; set allow_fluid_loss=true to discard fluids through ordinary dismantling"

local errors = require("scripts.errors")
check(errors.plain(FLUID_REFUSAL) == "refusing to recover a player-owned entity with fluids; set allow_fluid_loss=true"
  .. " to discard fluids through ordinary dismantling", "plain drops the leading chunk location of a raised error")
check(errors.plain("couldn't clear rock: __agentic-companion__/scripts/actions/build.lua:159: no room")
  == "couldn't clear rock: no room", "plain drops a location a detail embeds from an inner error")
check(errors.plain("SURFACE_MISMATCH: step 3 (walk_to) acts on nauvis") == "SURFACE_MISMATCH: step 3 (walk_to) acts on nauvis"
  and errors.plain("...nion__/scripts/a.lua:1: __core__/lualib/util.lua:22: bad") == "bad",
  "plain keeps a coded message whole and drops nested and truncated locations")
check(errors.code("failed") == "STEP_FAILED_UNCLASSIFIED" and errors.code("partial") == "STEP_PARTIAL_UNCLASSIFIED"
  and errors.code("failed", nil, "NO_ENTITY: nothing there") == "NO_ENTITY"
  and errors.code("failed", { code = "BODY_MISSING" }, "the body is gone") == "BODY_MISSING",
  "a failure's code is its outcome's, else its detail's, else STEP_FAILED_UNCLASSIFIED")

-- The RPC error path.
_G.game, _G.defines = { tick = 7 }, { shooting = { not_shooting = 0 } }
_G.storage = { rpc_outbox = { next_id = 1, by_id = {} } }
local printed
_G.helpers = { table_to_json = dofile(here .. "/table_to_json.lua"), json_to_table = function() return {} end }
_G.rcon = { print = function(text) printed = text end }
local rpc = require("scripts.rpc")
rpc.register("raises_located", function() error("refusing: the entity holds fluid") end)
rpc.register("raises_factorio", function() error(FLUID_REFUSAL, 0) end)
rpc.dispatch("raises_located", "")
check(printed:find('"ok":false', 1, true) and printed:find("refusing: the entity holds fluid", 1, true)
  and not printed:find(LOCATION), "an RPC handler's raised error reaches the app without its location")
rpc.dispatch("raises_factorio", "")
check(not printed:find(LOCATION) and printed:find("refusing to recover a player-owned entity", 1, true),
  "the fluid mine refusal reaches the app without the mod's source path")
local ring = storage.handler_errors
check(ring and ring.count == 2 and ring.recent[1].where == "rpc:raises_located" and ring.recent[2].tick == 7
  and not ring.recent[1].error:find(LOCATION), "RPC handler errors are kept, plain, in the error ring")
rpc.register("refuses_busy", function() error("JOBS_BUSY: 8 jobs are pending or unread") end)
rpc.register("refuses_input", function() error("radius must be a number", 0) end)
rpc.dispatch("refuses_busy", "")
check(printed:find("JOBS_BUSY: 8 jobs", 1, true) and not printed:find(LOCATION), "a coded refusal reaches the app plain")
rpc.dispatch("refuses_input", "")
check(printed:find("radius must be a number", 1, true) and ring.count == 2,
  "deliberate refusals (coded, or raised without a location) do not fill the error ring")

for i = 1, errors.RING_SIZE + 5 do errors.record("event:test", "x.lua:" .. i .. ": error " .. i) end
local summary = errors.summary()
check(#storage.handler_errors.recent == errors.RING_SIZE and summary.count == errors.RING_SIZE + 7
  and #summary.recent == errors.SHOWN and summary.recent[errors.SHOWN].error == "error " .. (errors.RING_SIZE + 5)
  and summary.recent[1].error == "error " .. (errors.RING_SIZE + 3),
  "the ring keeps the last twenty; ping shows the total count and the newest three, oldest first")
storage.handler_errors = { count = 0, recent = {} }
check(errors.summary() == nil, "ping shows no handler errors before the first")

-- Every caught fault also leaves one line in the server log, plain, with
-- the ring's cut message (never inside a UTF-8 character).
do
  local lines = {}
  _G.log = function(line) lines[#lines + 1] = line end
  errors.record("event:logged", "x.lua:3: bad\nthing " .. string.rep("\u{2014}", 200))
  _G.log = nil
  local kept = storage.handler_errors.recent[1].error
  check(#lines == 1 and lines[1]:find("handler fault event:logged tick=", 1, true) and not lines[1]:find("\n", 1, true)
    and not lines[1]:find(LOCATION) and #kept == 298 and utf8.len(kept) ~= nil
    and lines[1]:sub(-#kept) == kept:gsub("\n", " "),
    "a caught fault is logged as one plain line with the ring's message, cut at a character boundary")
  storage.handler_errors = { count = 0, recent = {} }
end

-- Plan steps and direct tasks through the real dispatcher.
local body = { valid = true, position = { x = 0, y = 0 }, walking_state = {}, mining_state = {}, crafting_queue = {},
  crafting_queue_size = 0 }
body.get_main_inventory = function() return { get_contents = function() return {} end } end
package.loaded["scripts.companion"] = { require_companion = function() return body end,
  require_present = function() return { state = "on_surface", force = body.force, surface = body.surface } end,
  anchor = function() return nil end, get = function() return body end }
-- mine raises the fluid refusal at start; walk_to raises at tick (a real
-- error, located in this file); pickup fails with no code; insert is partial
-- with no code; extract fails with its own code.
local function runner(start, tick) return { start = start or function() end, tick = tick } end
local mine = runner(function() error(FLUID_REFUSAL, 0) end)
local walk = runner(nil, function() error("the path request vanished") end)
local pickup = runner(nil, function() return { status = "failed",
  detail = "couldn't pick up: __agentic-companion__/scripts/actions/pickup.lua:120: no room" } end)
local insert = runner(nil, function() return { status = "partial", detail = "inserted 3 of 5 coal" } end)
local extract = runner(nil, function() return { status = "failed", detail = "the chest is empty",
  outcome = { code = "NOTHING_TO_TAKE" } } end)
local done = runner(nil, function() return { status = "done", detail = "done" } end)
-- An inner error deep in an outcome, as build_plan's failures[i].why holds.
local INNER = "couldn't clear rock: __agentic-companion__/scripts/actions/build.lua:159: no room"
local place = runner(nil, function() return { status = "failed", detail = "1 of 1 placements failed",
  outcome = { failures = { { index = 1, why = INNER } } } } end)
local build_plan = runner(nil, function() return { status = "failed",
  detail = "step 1: couldn't get within physical reach of (3, 4)", outcome = { failures = { { index = 1, why = INNER } } } } end)
-- rotate never finishes (a deliberate wait, so the watchdog leaves it to the
-- plan budget); its cancel note has its own code.
local rotate = runner(nil, function() return nil end)
rotate.waiting = function() return true end
rotate.cancelled = function() return { code = "MOVE_ROBOT_CANCELLED", detail = "the robot move was cancelled" } end
package.loaded["scripts.actions.walk"], package.loaded["scripts.actions.mine"] = walk, mine
done.queued = function() return 0 end -- pickup reads the crafting queue
package.loaded["scripts.actions.pickup"], package.loaded["scripts.actions.craft"] = pickup, done
package.loaded["scripts.actions.build"] = { place = place, rotate = rotate,
  set_recipe_action = { runner = done, make_task = function() return {} end } }
package.loaded["scripts.actions.transfer"] = { insert = insert, extract = extract,
  flush_action = { runner = done, make_task = function() return {} end } }
package.loaded["scripts.actions.build_plan"] = build_plan
package.loaded["scripts.inspect"] = { MAX_TARGETS = 64, inspect = function() return { entities = {} } end }
storage.tasks = { next_id = 1, records = {}, queue = {}, active = nil }
storage.activity_log = {}
local tasks = require("scripts.tasks")

local function run(steps, observation_detail)
  local plan = tasks.queue_plan({ steps = steps, observation_detail = observation_detail })
  for _ = 1, 3 do game.tick = game.tick + 1; tasks.on_tick() end
  return tasks.plan_status({ plan_id = plan.plan_id })
end
local function no_location(value, seen)
  seen = seen or {}
  if type(value) == "string" then return not value:find(LOCATION) end
  if type(value) ~= "table" or seen[value] then return true end
  seen[value] = true
  for key, item in pairs(value) do
    if not no_location(key, seen) or not no_location(item, seen) then return false end
  end
  return true
end

local refused = run({ { action = "mine", x = 3, y = 4, count = 1 } })
local outcome = refused.outcomes[1]
check(refused.status == "failed" and outcome.code == "STEP_FAILED_UNCLASSIFIED" and outcome.action == "mine"
  and outcome.error:find("^refusing to recover a player%-owned entity with fluids"),
  "a mine refused at start fails with STEP_FAILED_UNCLASSIFIED and the plain refusal")
check(no_location(refused) and refused.diagnostics.failure == outcome.error,
  "nothing in the failed plan's status names a Lua source location")
local entry = storage.activity_log[#storage.activity_log]
check(entry.code == "STEP_FAILED_UNCLASSIFIED" and entry.summary:find("mine: refusing", 1, true) and no_location(entry),
  "the activity log row carries the fallback code, the step's action and the plain reason")

local walked = run({ { action = "walk_to", x = 5, y = 5 } })
check(walked.status == "failed" and walked.outcomes[1].code == "STEP_FAILED_UNCLASSIFIED"
  and walked.outcomes[1].error == "the path request vanished" and no_location(walked),
  "a runner error raised at tick fails its step with a code and no location")

local picked = run({ { action = "pickup_items", x = 1, y = 1, item = "coal", count = 1 } })
check(picked.outcomes[1].code == "STEP_FAILED_UNCLASSIFIED" and picked.outcomes[1].error == "couldn't pick up: no room",
  "a step failure without a code gets the fallback code; an embedded location is dropped from its detail")

local inserted = run({ { action = "insert_items", x = 1, y = 1, items = { coal = 5 } } })
check(inserted.status == "partial" and inserted.outcomes[1].code == "STEP_PARTIAL_UNCLASSIFIED"
  and inserted.outcomes[1].result == "inserted 3 of 5 coal"
  and storage.activity_log[#storage.activity_log].code == "STEP_PARTIAL_UNCLASSIFIED",
  "a partial step without a code names STEP_PARTIAL_UNCLASSIFIED and keeps its detail")

local extracted = run({ { action = "extract_items", x = 1, y = 1 } })
check(extracted.outcomes[1].code == "NOTHING_TO_TAKE" and extracted.outcomes[1].result.code == "NOTHING_TO_TAKE"
  and storage.activity_log[#storage.activity_log].code == "NOTHING_TO_TAKE",
  "a step's own code is kept on the outcome, its result and the activity log")

local completed = run({ { action = "craft_items", recipe = "gear", crafts = 1 } })
check(completed.status == "completed" and completed.outcomes[1].code == nil
  and storage.activity_log[#storage.activity_log].code == nil, "a completed step and plan name no failure code")

local direct = tasks.enqueue({ task = { type = "mine" } })
game.tick = game.tick + 1; tasks.on_tick()
local record = storage.tasks.records[direct.task_id]
check(record.status == "failed" and record.outcome.code == "STEP_FAILED_UNCLASSIFIED" and record.outcome.action == "mine"
  and not record.detail:find(LOCATION), "a direct task that fails names a code and a plain detail")

check(storage.handler_errors.count == 3 and storage.handler_errors.recent[1].where == "task:mine:start"
  and storage.handler_errors.recent[2].where == "task:walk_to:tick"
  and storage.handler_errors.recent[3].where == "task:mine:start" and no_location(storage.handler_errors),
  "each runner error the dispatcher caught is in the ring; returned failures are not")

-- A deliberate refusal a runner raises leads with its code: it fails its
-- step or task with the plain message and that code, and never fills the
-- error ring. An engine error carries no location either, but no code: it is
-- a fault, kept in the ring.
do
  local count = storage.handler_errors.count
  local mine_start, walk_tick = mine.start, walk.tick
  mine.start = function() error("CRAFT_INVALID: craft crafts must be an integer from 1 to 100", 0) end
  walk.tick = function() error("AREA_INVALID: queue_plan build_ghosts step 1 area must be {left_top, right_bottom}", 0) end
  local plain = run({ { action = "mine", x = 3, y = 4, count = 1 } })
  local coded = run({ { action = "walk_to", x = 5, y = 5 } })
  local direct_refusal = tasks.enqueue({ task = { type = "mine" } })
  game.tick = game.tick + 1; tasks.on_tick()
  check(plain.outcomes[1].error == "CRAFT_INVALID: craft crafts must be an integer from 1 to 100"
    and plain.outcomes[1].code == "CRAFT_INVALID" and coded.outcomes[1].code == "AREA_INVALID"
    and storage.tasks.records[direct_refusal.task_id].detail == "CRAFT_INVALID: craft crafts must be an integer from 1 to 100"
    and storage.handler_errors.count == count,
    "coded refusals at step start, step tick and task start are no handler faults")
  mine.start = function() error("LuaEntity API call when LuaEntity was invalid.", 0) end
  local engine = run({ { action = "mine", x = 3, y = 4, count = 1 } })
  mine.start, walk.tick = mine_start, walk_tick
  local last = storage.handler_errors.recent[#storage.handler_errors.recent]
  check(engine.outcomes[1].error == "LuaEntity API call when LuaEntity was invalid."
    and storage.handler_errors.count == count + 1 and last.where == "task:mine:start"
    and last.error == "LuaEntity API call when LuaEntity was invalid.",
    "an engine error without a location or code is a handler fault in the ring")
end

-- A failed or partial plan leaves one server-log line with its code and
-- reason; a completed one none. next_event's last_plan_ended names the code.
do
  local lines = {}
  _G.log = function(line) lines[#lines + 1] = line end
  local failed = run({ { action = "pickup_items", x = 1, y = 1, item = "coal", count = 1 } })
  local ended = storage.tasks.last_plan_ended
  run({ { action = "craft_items", recipe = "gear", crafts = 1 } })
  _G.log = nil
  check(#lines == 1 and lines[1]:find("[agentic-companion] plan " .. failed.plan_id
      .. " source=pilot status=failed code=STEP_FAILED_UNCLASSIFIED steps=0/1 tick=", 1, true)
    and lines[1]:sub(-#"detail=couldn't pick up: no room") == "detail=couldn't pick up: no room",
    "a failed plan leaves one server-log line with its code and detail; a completed plan none")
  check(ended.plan_id == failed.plan_id and ended.code == "STEP_FAILED_UNCLASSIFIED"
    and storage.tasks.last_plan_ended.code == nil, "last_plan_ended carries the ended plan's code")
end

local placed = run({ { action = "place_entity", name = "inserter", x = 1.5, y = 2.5 } })
check(placed.outcomes[1].code == "STEP_FAILED_UNCLASSIFIED" and placed.outcomes[1].result.failures[1].why
  == "couldn't clear rock: no room" and no_location(placed) and no_location(storage.activity_log),
  "an inner error nested in a step's outcome reaches plan_status and the activity log plain")
local built = tasks.enqueue({ task = { type = "build_plan" } })
game.tick = game.tick + 1; tasks.on_tick()
record = storage.tasks.records[built.task_id]
check(record.outcome.failures[1].why == "couldn't clear rock: no room" and record.outcome.code == "TARGET_OUT_OF_REACH",
  "a direct task's nested outcome is plain and its code is classified as a plan step's would be")

local budget = tasks.queue_plan({ steps = { { action = "rotate_entity", x = 1, y = 1 } } })
for _ = 1, 2 do game.tick = game.tick + 1; tasks.on_tick() end
game.tick = game.tick + 600 * 60; tasks.on_tick()
local over = tasks.plan_status({ plan_id = budget.plan_id })
check(over.status == "failed" and over.outcomes[1].code == "PLAN_BUDGET_EXCEEDED"
  and over.outcomes[1].result.cancelled.code == "MOVE_ROBOT_CANCELLED"
  and storage.activity_log[#storage.activity_log].code == "PLAN_BUDGET_EXCEEDED",
  "a plan out of budget reports PLAN_BUDGET_EXCEEDED, the cancelled step's note kept beside it")
check(over.outcomes[1].result.crafting == nil and over.outcomes[1].result.supply == nil
  and not over.outcomes[1].error:find("hand-crafting", 1, true),
  "with no crafting queue and no supply, the budget cut adds neither")

-- What a running step waits on is visible: plan_status diagnostics name the
-- step's supply and the crafting queue (head recipe, count, seconds left),
-- and a budget cut keeps the same facts; queued hand-crafts keep running.
do
  local REMEDY = { "should", "consider", "try ", "instead", "build ", "research ", "recommend" }
  local function facts_only(value, depth)
    depth = depth or 0
    if type(value) == "string" then
      for _, word in ipairs(REMEDY) do if value:lower():find(word, 1, true) then return false end end
      return true
    end
    if type(value) ~= "table" or depth > 6 then return true end
    for key, item in pairs(value) do
      if not facts_only(key, depth + 1) or not facts_only(item, depth + 1) then return false end
    end
    return true
  end
  local real_craft = dofile(here .. "/../../mod/agentic-companion/scripts/actions/craft.lua")
  done.queue_summary = real_craft.queue_summary
  body.force = { recipes = { gear = { energy = 0.5 } } }
  body.crafting_queue_size, body.crafting_queue, body.crafting_queue_progress = 4, { { recipe = "gear", count = 4 } }, 0
  local rotate_start = rotate.start
  -- The running step's own supply, as a get_items step holds it.
  rotate.start = function(task) task._stack = { { name = "gear", count = 4, phase = "take", takes = 1 } } end
  local held = tasks.queue_plan({ steps = { { action = "rotate_entity", x = 1, y = 1 } } })
  for _ = 1, 2 do game.tick = game.tick + 1; tasks.on_tick() end
  local running = tasks.plan_status({ plan_id = held.plan_id }).diagnostics
  check(running.crafting.recipe == "gear" and running.crafting.count == 4 and running.crafting.queue_s == 2
    and running.supply.stage == "get_items" and running.supply.supply.item == "gear"
    and running.supply.supply.phase == "take", "plan_status diagnostics name the step's supply and the crafting queue")
  game.tick = game.tick + 600 * 60; tasks.on_tick()
  local cut = tasks.plan_status({ plan_id = held.plan_id }).outcomes[1]
  rotate.start = rotate_start
  check(cut.code == "PLAN_BUDGET_EXCEEDED" and cut.result.crafting.queue_s == 2 and cut.result.supply.supply.item == "gear"
    and cut.error:find("; hand-crafting continues: 2 s queued", 1, true),
    "a budget cut keeps the step's supply and the crafting queue, and says queued hand-crafts continue")
  local cut_row = storage.activity_log[#storage.activity_log]
  check(cut_row.code == "PLAN_BUDGET_EXCEEDED"
    and cut_row.detail:find("; supply: stage get_items, fetching 4 gear (phase take, 1 takes, running nothing)", 1, true) ~= nil,
    "the budget cut's activity row (and server log line) keeps what the supply was doing")
  check(facts_only(running) and facts_only(cut), "the diagnostics and the budget cut carry facts only")
  body.crafting_queue_size, body.crafting_queue, body.crafting_queue_progress, body.force = 0, {}, nil, nil
  done.queue_summary = nil
end

-- queue_plan returns the hand-craft bill of the plan's needs (the supply's
-- arithmetic over them), and leaves it out when nothing would be hand-crafted.
do
  local supply = require("scripts.actions.supply")
  local hand_craft, asked = supply.hand_craft, nil
  local bill = { total_s = 9.5, items = { { item = "gear", count = 19, short = 19, hand_craftable = 19, hand_craft_s = 9.5 } } }
  supply.hand_craft = function(_, wants) asked = wants; return bill end
  local billed = tasks.queue_plan({ steps = { { action = "get_items", item = "gear", count = 19 } } })
  tasks.cancel({ plan_id = billed.plan_id, origin = "test/error-codes" })
  supply.hand_craft = function() return nil end
  local none = tasks.queue_plan({ steps = { { action = "get_items", item = "gear", count = 1 } } })
  tasks.cancel({ plan_id = none.plan_id, origin = "test/error-codes" })
  supply.hand_craft = hand_craft
  check(billed.hand_craft == bill and #asked == 1 and asked[1].name == "gear" and asked[1].count == 19
    and none.hand_craft == nil, "queue_plan returns the plan's hand-craft bill, and none when it is empty")
end

tasks.set_observer(function() error("the observer broke") end)
local observed = run({ { action = "craft_items", recipe = "gear", crafts = 1 } }, "compact")
tasks.set_observer(nil)
entry = storage.activity_log[#storage.activity_log]
check(observed.status == "failed" and observed.outcomes[1].status == "completed" and entry.code == "FINAL_OBSERVATION_FAILED"
  and entry.summary == "failed after 1/1 steps: the final observation raised: the observer broke"
  and storage.handler_errors.recent[#storage.handler_errors.recent].where == "task:plan:observe",
  "a plan whose steps completed but whose final observation raised names that, not its last step")

-- A long failure reason: the activity_log summary stays short, its detail
-- keeps the reason whole up to 800 bytes, both cut at a character boundary.
-- A failed plan's record is kept 30 minutes, a completed one's 5.
do
  local reason = "can't place boiler at (-32.5, 8.0) \u{2014} " .. string.rep("item-on-ground at (-31.5, 9.0); ", 8)
    .. "last attempt: (-33.5, 8.0)"
  local long = string.rep("x", 795) .. "\u{2014}\u{2014}"
  local reasons = { reason, long }
  local tick_before = insert.tick
  for _, text in ipairs(reasons) do
    insert.tick = function() return { status = "failed", detail = text } end
    run({ { action = "insert_items", x = 1, y = 1, items = { coal = 1 } } })
    entry = storage.activity_log[#storage.activity_log]
    local whole = #text <= 800
    check(entry.status == "failed" and #entry.summary < 200 and utf8.len(entry.summary) ~= nil
      and (whole and entry.detail == text or not whole and #entry.detail == 798 and text:sub(1, 798) == entry.detail),
      "activity_log keeps a short summary and the reason as detail (" .. #text .. " bytes), cut at a character boundary")
  end
  insert.tick = tick_before
  local failed_id = entry.plan_id
  local completed_id = run({ { action = "craft_items", recipe = "gear", crafts = 1 } }).plan_id
  check(storage.activity_log[#storage.activity_log].detail == nil, "a completed plan's row has no detail")
  local function prune_at(minutes)
    game.tick = (math.floor(game.tick / 3600) + minutes + 1) * 3600
    tasks.on_tick()
  end
  prune_at(5)
  local ok_failed, kept = pcall(tasks.plan_status, { plan_id = failed_id })
  local ok_completed, gone = pcall(tasks.plan_status, { plan_id = completed_id })
  check(ok_failed and kept.status == "failed" and not ok_completed
    and tostring(gone):find("unknown plan_id: " .. completed_id .. ": never queued, or it ended more than 5 minutes ago (30 if it failed", 1, true)
    and tostring(gone):find("activity_log keeps the last 64 plan outcomes", 1, true),
    "after 5 minutes a completed plan is pruned and says why; a failed one is still readable")
  prune_at(25)
  check(not pcall(tasks.plan_status, { plan_id = failed_id }), "a failed plan's record is pruned after 30 minutes")
end

-- move_entity's refusals lead with their own code (the real runner: no own
-- entity stands at the source), never STEP_FAILED_UNCLASSIFIED.
body.surface = { find_entities_filtered = function() return {} end }
local unmoved = run({ { action = "move_entity", from = { x = 500, y = 500 }, to = { x = 0, y = 0 } } })
body.surface = nil
entry = storage.activity_log[#storage.activity_log]
check(unmoved.status == "failed" and unmoved.outcomes[1].code == "MOVE_SOURCE_MISSING"
  and unmoved.outcomes[1].error == "MOVE_SOURCE_MISSING: no own entity stands at (500.0, 500.0)"
  and entry.code == "MOVE_SOURCE_MISSING",
  "a move_entity refusal fails its step with its leading MOVE_ code")
for _, detail in ipairs({ "MOVE_TARGET_BLOCKED: the inserter can't go to (82.5, -26.5): transport-belt stands at (82.5, -26.5)",
  "MOVE_SOURCE_MISMATCH: a inserter, not the fast-inserter, stands at (1.0, 1.0)",
  "MOVE_NOT_PLACEABLE: no item places a crash-site-chest",
  "MOVE_ALREADY_THERE: the inserter already stands at (1.0, 1.0) facing that way" }) do
  check(errors.code("failed", nil, detail) == detail:match("^([A-Z_]+):"), "errors.code reads " .. detail:match("^([A-Z_]+):"))
end

-- The real transfer and pickup refusals carry their own codes through the
-- dispatcher: no target to take from, a ground stack gone or changed, and a
-- pickup whose stack vanished with too little gained.
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end, find_entity_near = function() return nil end }
package.loaded["scripts.actions.transfer"] = nil
package.loaded["scripts.actions.pickup"] = nil
local real_transfer = require("scripts.actions.transfer")
local real_pickup = require("scripts.actions.pickup")
extract.start, extract.tick = real_transfer.extract.start, real_transfer.extract.tick
local missing = run({ { action = "extract_items", x = 1, y = 1 } })
check(missing.outcomes[1].code == "TRANSFER_TARGET_MISSING"
  and storage.activity_log[#storage.activity_log].code == "TRANSFER_TARGET_MISSING",
  "extract with nothing at the target is TRANSFER_TARGET_MISSING, not unclassified")
local lying = { valid = true, type = "item-entity", name = "item-on-ground", position = { x = 1, y = 1 },
  stack = { valid_for_read = true, name = "coal", count = 2 } }
body.surface = { find_entities_filtered = function() return { lying } end }
pickup.start, pickup.tick = real_pickup.start, real_pickup.tick
local changed = run({ { action = "pickup_items", x = 1, y = 1, item = "coal", count = 3 } })
check(changed.outcomes[1].code == "GROUND_STACK_CHANGED" and changed.outcomes[1].error:find("item-on-ground coal x2 at (1, 1)", 1, true)
  and storage.activity_log[#storage.activity_log].code == "GROUND_STACK_CHANGED",
  "a pickup whose observed stack changed is GROUND_STACK_CHANGED and names what lies there")
local counts = { coal = 0 }
body.item_pickup_distance = 1
body.update_selected_entity = function() body.selected = lying end
body.get_main_inventory = function() return { get_item_count = function(name) return counts[name] or 0 end,
  can_insert = function() return true end } end
local vanished_task = { target = { x = 1, y = 1 }, item = "coal", count = 2, id = 1 }
real_pickup.start(vanished_task)
real_pickup.tick(vanished_task)
counts.coal, lying.valid = 1, false
local vanished = real_pickup.tick(vanished_task)
check(errors.code(vanished.status, vanished.outcome, vanished.detail) == "PICKUP_COUNT_MISMATCH",
  "a pickup whose stack vanished with too little gained is PICKUP_COUNT_MISMATCH")

-- The dispatchers never hand a caught error on raw: every one goes through
-- errors.plain or errors.record.
for _, name in ipairs({ "rpc", "tasks" }) do
  local file = assert(io.open(here .. "/../../mod/agentic-companion/scripts/" .. name .. ".lua"))
  local source = file:read("a")
  file:close()
  local raw = {}
  for caught in source:gmatch("ok, ([%w_]+) = pcall%(") do
    if caught ~= "_" and source:find("tostring%(" .. caught .. "%)") then raw[#raw + 1] = caught end
  end
  check(#raw == 0, name .. ".lua passes no caught error on through tostring (" .. table.concat(raw, ", ") .. ")")
end
os.exit(failures == 0 and 0 or 1)
