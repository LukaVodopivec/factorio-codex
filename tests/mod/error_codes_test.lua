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

for i = 1, errors.RING_SIZE + 5 do errors.record("event:test", "x.lua:" .. i .. ": error " .. i) end
local summary = errors.summary()
check(#storage.handler_errors.recent == errors.RING_SIZE and summary.count == errors.RING_SIZE + 7
  and #summary.recent == errors.SHOWN and summary.recent[errors.SHOWN].error == "error " .. (errors.RING_SIZE + 5)
  and summary.recent[1].error == "error " .. (errors.RING_SIZE + 3),
  "the ring keeps the last twenty; ping shows the total count and the newest three, oldest first")
storage.handler_errors = { count = 0, recent = {} }
check(errors.summary() == nil, "ping shows no handler errors before the first")

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
package.loaded["scripts.actions.walk"], package.loaded["scripts.actions.mine"] = walk, mine
package.loaded["scripts.actions.pickup"], package.loaded["scripts.actions.craft"] = pickup, done
package.loaded["scripts.actions.build"] = { place = done, rotate = done,
  set_recipe_action = { runner = done, make_task = function() return {} end } }
package.loaded["scripts.actions.transfer"] = { insert = insert, extract = extract,
  flush_action = { runner = done, make_task = function() return {} end } }
package.loaded["scripts.actions.build_plan"] = done
package.loaded["scripts.inspect"] = { MAX_TARGETS = 64, inspect = function() return { entities = {} } end }
storage.tasks = { next_id = 1, records = {}, queue = {}, active = nil }
storage.activity_log = {}
local tasks = require("scripts.tasks")

local function run(steps)
  local plan = tasks.queue_plan({ steps = steps })
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
