-- Sole-body FIFO dispatcher. Plans are atomic queue entries whose steps run
-- contiguously on tick, so RCON cannot interleave physical work.
local companion = require("scripts.companion")
local items = require("scripts.items")
local inspect = require("scripts.inspect")
local surfaces = require("scripts.surfaces")
local walk = require("scripts.actions.walk")
local mine = require("scripts.actions.mine")
local pickup = require("scripts.actions.pickup")
local build = require("scripts.actions.build")
local craft = require("scripts.actions.craft")
local transfer = require("scripts.actions.transfer")
local build_plan = require("scripts.actions.build_plan")
local supply = require("scripts.actions.supply")
local build_layout = require("scripts.actions.build_layout")
local explore = require("scripts.actions.explore")
local move_entity = require("scripts.actions.move_entity")
local area_ops = require("scripts.actions.area_ops")
local configure = require("scripts.actions.configure")
local tiles = require("scripts.actions.tiles")
local equip = require("scripts.actions.equip")
local requests = require("scripts.requests")
local platforms = require("scripts.platforms")
local rocket = require("scripts.actions.rocket")
local travel = require("scripts.actions.travel")
local inventory_roles = require("scripts.inventory_roles")
local set_walking = require("scripts.human_inputs").set_walking
local factory_activity = require("scripts.factory_activity")
local autonomy = require("scripts.autonomy")
local errors = require("scripts.errors")
local registry = require("scripts.registry")
local journal = require("scripts.journal")
local jobs = require("scripts.jobs")
local M = {}
-- Finished task and plan records are kept 5 minutes, a failed or partial
-- one 30 (plan_status reads its outcomes).
local RECORD_TTL_TICKS, PRUNE_INTERVAL_TICKS = 5 * 60 * 60, 3600
local FAILED_RECORD_TTL_TICKS = 30 * 60 * 60
-- A plan's active budget: 570 s, or 12 s per step for long build packages.
local PLAN_BUDGET_TICKS, STEP_BUDGET_TICKS = 570 * 60, 12 * 60
local function tenth(x) return math.floor(x * 10 + 0.5) / 10 end
-- A plan's ticks of one kind (walking, waiting on hand-crafts) as seconds to
-- a tenth; nil before any.
local function plan_time(ticks) return ticks and tenth(ticks / 60) or nil end
local MAX_PLAN_STEPS = 200
-- Pilot queue_plan client keys kept (storage.tasks.client_keys).
M.MAX_CLIENT_KEYS = 32
local ACTIVITY_LOG_SIZE = 64
-- An activity_log row's summary keeps SUMMARY_REASON bytes of the reason,
-- its detail DETAIL_BYTES of the whole reason.
local SUMMARY_REASON, DETAIL_BYTES = 160, 800
local INSPECT_PER_TICK = 16 -- positions an inspect_entities step reads a tick
-- Watchdog: a running step with no progress for 60 s fails with STEP_STALLED.
-- Progress is read once a second; the body counts as moved once it is more
-- than a tile from where it last stood and from where it stood before that.
local STALL_TICKS, STALL_SAMPLE_TICKS, STALL_MOVE_SQ = 60 * 60, 60, 1
local runners = {
  walk_to = walk, mine = mine, pickup = pickup, place = build.place, rotate = build.rotate,
  craft = craft, insert = transfer.insert,
  extract = transfer.extract, build_plan = build_plan,
}
local observer
function M.set_observer(fn) observer = fn end
-- Called as listener(plan, step_index, status) when a step of an upkeep plan
-- ends with an outcome (chores.lua starts a refuel cooldown there).
local upkeep_listener
function M.set_upkeep_listener(fn) upkeep_listener = fn end
-- Called as boundary(tick) -> plan_id or nil when the dispatcher is about to
-- start a queued pilot or package plan (chores.lua may queue one upkeep plan
-- that runs first: the plan-boundary pass).
local boundary_upkeep
function M.set_boundary_upkeep(fn) boundary_upkeep = fn end
-- Plan actions other modules add (get_items, build_layout, ...): spec is
-- { runner = {start, tick, resume?}, make_task = function(step) -> task,
-- validate = function(step, index) (optional, raises on a bad step),
-- budget_steps = function(step) -> n (optional: the step's share of the
-- plan's active budget, counted in ordinary steps), remote = function(step)
-- -> boolean (optional: the step acts on a space platform without the body,
-- so it carries no surface tag) }. A runner may add waiting(task) -> boolean
-- (a deliberate wait the step watchdog leaves alone) and cancelled(task,
-- body_only) -> table (what a cancel of the running step reports; with
-- body_only, from the stall watchdog, only an entity the body has taken up
-- is let go of: robot orders and travel markers are left alone).
local extensions = {}
function M.register_action(action, spec)
  assert(type(action) == "string" and type(spec) == "table" and type(spec.runner) == "table"
    and type(spec.make_task) == "function", "register_action requires an action name, runner and make_task")
  extensions[action] = spec
  runners[action] = spec.runner
end
-- Who queued a plan: the pilot (default), the mod's own upkeep, or the
-- bridge for one of the strategist's build packages.
local function valid_source(source)
  return type(source) == "string" and #source <= 80
    and (source == "pilot" or source == "upkeep" or source:match("^package:.+") ~= nil)
end

local function stop_body()
  local c = companion.get()
  if not c then return end
  set_walking(c, { walking = false })
  c.mining_state, c.picking_state = { mining = false }, false
end
-- The canonical surface of the body (planet name or "platform:<index>"):
-- where it stands, the hub's surface aboard, the pod's in transit; or nil.
local function body_surface()
  local anchor = companion.anchor()
  return anchor and anchor.surface_ref or nil
end
-- Surface tags (multi-surface rules 2-4). Only physical positional steps
-- carry one (step._surface): the surface their positions belong to. Remote
-- steps (an extension's remote(step)), hand-crafting, research waits, reads,
-- equipment and travel itself carry none.
local UNTAGGED = { craft_items = true, wait_for_research = true, inspect_entities = true, equip = true, travel = true }
local function tagged(step)
  if UNTAGGED[step.action] then return false end
  local extension = extensions[step.action]
  return not (extension and extension.remote and extension.remote(step))
end
-- A step's surface tag. A plan queued by 0.22.2 or older carries one tag
-- for the whole plan (plan.surface), which then holds for every step that
-- would carry one.
local function step_surface(plan, index)
  local step = plan.steps[index]
  if not step then return nil end
  if plan.step_tags then return step._surface end
  return plan.surface ~= nil and tagged(step) and plan.surface or nil
end
-- The tag of the plan's next unfinished positional step, if any.
local function next_surface(plan)
  for index = plan.completed_steps + 1, #plan.steps do
    local tag = step_surface(plan, index)
    if tag then return tag end
  end
end
-- The destinations (step._to) of the plan's unfinished travel steps, in order.
local function pending_travel(plan, into)
  for index = plan.completed_steps + 1, #plan.steps do
    local step = plan.steps[index]
    if step.action == "travel" and step._to then into[#into + 1] = step._to end
  end
  return into
end
-- Every pending travel destination in FIFO order: the active plan's, then
-- the queued plans'.
local function fifo_travel()
  local tasks, into = storage.tasks, {}
  if tasks.active and tasks.active.type == "plan" then pending_travel(tasks.active, into) end
  for _, queued in ipairs(tasks.queue) do
    if queued.type == "plan" then pending_travel(queued, into) end
  end
  return into
end
-- The destination of the last travel step pending in the FIFO, or nil.
function M.bound_for()
  local into = fifo_travel()
  return into[#into]
end
-- The player's real control input on the Codex client holds the body (companion.human_control
-- owns the rule, and names the cause). A failed read never holds.
local function human_control()
  local ok, held, idle, cause = pcall(companion.human_control)
  if not ok then return false end
  return held == true, idle, cause
end
-- A step or task error the dispatcher caught, as its failed detail: a
-- refusal that leads with its code (CRAFT_INVALID: ...) as it stands;
-- anything else is a fault kept in the error ring. A missing source location
-- proves nothing here: the engine's own API errors ("LuaEntity API call when
-- LuaEntity was invalid.") carry none either.
local function caught(where, err)
  local message = errors.plain(err)
  if message:match("^[A-Z][A-Z0-9_]+[A-Z0-9]:") then return message end
  return errors.record(where, err)
end
-- The body's crafting queue for plan diagnostics ({recipe, count, queue_s}:
-- its head entry and the seconds it still needs), or nil when it is empty.
local function crafting_summary()
  local c = companion.get()
  if not (c and c.valid) then return nil end
  local ok, summary = pcall(craft.queue_summary, c)
  return ok and summary or nil
end
-- A running step's supply (a get_items step's own or an embedded
-- auto-supply, running or ended), or nil for a step with none.
local function supply_state(task)
  if task and (task._stack or task._supply or task._supply_result) then return supply.diagnostics(task) end
end
local function cancel_crafting()
  local c = companion.get()
  if not c then return end
  local queue = c.crafting_queue or {}
  for i = #queue, 1, -1 do c.cancel_crafting({ index = i, count = queue[i].count }) end
end
local function task_crafts(task)
  local current = task.type == "plan" and task.current_task or task
  -- get_items and auto-supply may hand-craft inside any step.
  return current and (current.type == "craft" or current.type == "build_plan" or current.type == "get_items"
    or current.type == "build_layout" or current.type == "blueprint_place"
    or current.type == "build_ghosts" or current.type == "upgrade_area" or current.type == "place_tiles"
    or current.type == "equip" or current.type == "launch_rocket" or current._supply ~= nil)
end
local function set_plan_status(plan, status)
  plan.status = status
  plan.transitions = plan.transitions or {}
  for _, transition in ipairs(plan.transitions) do
    if transition.status == status then return end
  end
  plan.transitions[#plan.transitions + 1] = { status = status, tick = game.tick }
end
local function observe_terminal(plan)
  if plan.observation_detail == "none" then return end
  if plan.observation or plan.observation_error or not observer then return end
  -- A plan persisted by an older version may still ask for full: compact.
  local ok, value = pcall(observer, { radius = plan.final_observation_radius, detail = "compact" })
  if ok then plan.observation = value else plan.observation_error = errors.record("task:plan:observe", value) end
end
-- What the body carries, by item key (a non-normal quality is
-- "name@quality"): its character's main inventory in every body state (the
-- character travels with it aboard), or nil when none can be read, so a plan
-- that ends aboard or in a pod shows no invented loss.
local function inventory_snapshot()
  local ok, inv = pcall(function()
    local c = companion.get() or companion.body().character
    return c and c.get_main_inventory()
  end)
  if not (ok and inv) then return nil end
  return items.sum_contents(inv)
end
local function inventory_delta(plan)
  if not plan.start_inventory or not plan.final_inventory then return {} end
  local final = plan.final_inventory or {}
  local initial, names, seen, delta = plan.start_inventory or {}, {}, {}, {}
  for name in pairs(initial) do seen[name], names[#names + 1] = true, name end
  for name in pairs(final) do if not seen[name] then names[#names + 1] = name end end
  table.sort(names)
  for _, name in ipairs(names) do
    local change = (tonumber(final[name]) or 0) - (tonumber(initial[name]) or 0)
    if change ~= 0 then delta[name] = change end
  end
  return delta
end
-- Recent draws: a ring of DRAWS_SIZE rows {tick, item, count, from,
-- source, plan_id?} of what plans (or a direct task: source pilot) took
-- from own stores (from = "stores", each take of a supply) or ended with
-- fewer of in the body's inventory (from = "inventory", the plan's net
-- change). A SUPPLY_SHORTFALL outcome names the newest rows of its missing
-- items (recent_draws), facts about where the item went.
local DRAWS_SIZE, MAX_RECENT_DRAWS = 32, 4
local function record_draw(item, count, from, plan)
  local ring = storage.draws
  if not ring or count <= 0 then return end
  local active = plan or storage.tasks.active
  local source = active and active.type == "plan" and (active.source or "pilot") or "pilot"
  local plan_id = active and active.type == "plan" and active.id or nil
  for back = 0, math.min(ring.n, DRAWS_SIZE, 3) - 1 do
    local row = ring.rows[(ring.n - 1 - back) % DRAWS_SIZE + 1]
    if row.item == item and row.from == from and row.source == source and row.plan_id == plan_id then
      row.count, row.tick = row.count + count, game.tick
      return
    end
  end
  ring.n = ring.n + 1
  ring.rows[(ring.n - 1) % DRAWS_SIZE + 1] = { tick = game.tick, item = item, count = count, from = from,
    source = source, plan_id = plan_id }
end
supply.set_draw_listener(function(item, count) record_draw(item, count, "stores") end)
-- The newest draws of these items (an item key "name@quality" counts as its
-- name), newest first, or nil.
local function recent_draws(names)
  local ring, wanted, rows = storage.draws, {}, {}
  if not ring then return nil end
  for _, name in ipairs(names) do wanted[name] = true end
  for back = 0, math.min(ring.n, DRAWS_SIZE) - 1 do
    local row = ring.rows[(ring.n - 1 - back) % DRAWS_SIZE + 1]
    if wanted[row.item] or wanted[row.item:match("^(.-)@") or ""] then
      rows[#rows + 1] = { item = row.item, count = row.count, from = row.from, source = row.source,
        plan_id = row.plan_id, tick = row.tick }
      if #rows >= MAX_RECENT_DRAWS then break end
    end
  end
  return #rows > 0 and rows or nil
end

-- The repeat counter: a failed or partial step's code, kept per action and
-- target in storage.repeats (so it outlives any reader's memory); the n-th
-- time in a row the same code ends that action there, its outcome says
-- repeat = n (from 2). A completed step there clears it.
M.MAX_REPEAT_KEYS = 64
local function tile(position)
  if type(position) == "table" and type(position.x) == "number" and type(position.y) == "number" then
    return math.floor(position.x) .. "," .. math.floor(position.y)
  end
end
-- What a step acts on: its tile (or its targets' near point or first
-- position), else the item, recipe, entity or technology it names; nil when
-- it names none, so unrelated steps never share a count.
local function step_target(step)
  local area = type(step.area) == "table" and step.area or nil
  local targets = type(step.targets) == "table" and step.targets or nil
  local positions = type(step.positions) == "table" and step.positions or nil
  local named = step.item or step.recipe or step.name or step.technology or step.to
  return tile(step) or tile(step.position) or tile(step.anchor) or tile(step.from) or tile(step.center)
    or tile(type(step.site) == "table" and step.site.near or nil) or tile(area and area.left_top)
    or tile(targets and (targets.near or targets[1])) or tile(positions and positions[1])
    or (type(named) == "string" and named or nil)
end
local function count_repeat(step, code)
  local repeats = storage.repeats
  local target = repeats and step and step.action and step_target(step)
  if not target then return nil end
  local key = step.action .. "|" .. target
  local row = repeats.by_key[key]
  if not code then
    if row then repeats.by_key[key], repeats.size = nil, repeats.size - 1 end
    return nil
  end
  if row and row.code == code then
    row.count, row.tick = row.count + 1, game.tick
    return row.count
  end
  if not row then
    if repeats.size >= M.MAX_REPEAT_KEYS then
      local oldest, oldest_tick
      for other, entry in pairs(repeats.by_key) do
        if not oldest_tick or entry.tick < oldest_tick then oldest, oldest_tick = other, entry.tick end
      end
      if oldest then repeats.by_key[oldest], repeats.size = nil, repeats.size - 1 end
    end
    repeats.size = repeats.size + 1
  end
  repeats.by_key[key] = { code = code, count = 1, tick = game.tick }
  return nil
end

-- Plan steps that change an entity without an event naming it: the change
-- journal's row names the step's action.
local CHANGE_STEPS = { rotate_entity = "rotated", set_recipe = "changed", configure_entity = "changed",
  copy_settings = "changed" }
-- A direct rotate_entity tool call is the pilot's (journal_step(nil, ...)).
local function journal_step(plan, step)
  local op = CHANGE_STEPS[step.action]
  if not op or step.platform ~= nil or not storage.journal then return end
  local ok, surface = pcall(function() return companion.get().surface.index end)
  if not (ok and surface) then return end
  local positions = step.action == "copy_settings" and type(step.to) == "table" and step.to or { step }
  for _, at in ipairs(positions) do
    if type(at.x) == "number" and type(at.y) == "number" then
      journal.note(op, nil, { x = at.x, y = at.y }, surface, plan and plan.source or "pilot", plan and plan.id,
        step.action)
    end
  end
end

-- activity_log: the last ACTIVITY_LOG_SIZE plan outcomes, so a reader sees
-- what the body did without polling each plan: a short summary and, for a
-- plan that did not complete, the reason in full as detail.
local function upkeep_readback(plan)
  if plan.source ~= "upkeep" then return nil end
  local targets, by_step = {}, {}
  -- Outcomes by step: a walk back after an early end skips steps.
  for _, outcome in ipairs(plan.outcomes) do by_step[outcome.step] = outcome end
  local first = plan.completed_steps + 1
  local stop = math.min(#plan.steps, first + 15)
  for index = first, stop do
    local step, requested, count, capped = plan.steps[index], {}, 0, false
    for name, amount in pairs(step.items or {}) do
      if count >= 8 then capped = true; break end
      requested[name], count = amount, count + 1
    end
    local outcome = by_step[index]
    targets[#targets + 1] = { step = index, action = step.action, surface = step_surface(plan, index),
      position = step.x and { x = step.x, y = step.y } or nil,
      requested_items = requested, items_capped = capped or nil,
      state = outcome and outcome.status or plan.current_task and index == plan.current_step and "running" or "not_started",
      outcome = outcome }
  end
  return { selection_tick = plan.upkeep_selection and plan.upkeep_selection.tick,
    completed_steps = plan.completed_steps, unfinished_targets = targets,
    omitted_targets = math.max(0, #plan.steps - stop), preempted = plan.preempted or nil,
    active = plan.current_task and { step = plan.current_step, context = supply.diagnostics(plan.current_task) } or nil }
end
-- A step result's code: its outcome's, else one its detail names (the
-- recoveries below key on it), else nil.
local function result_code(result)
  local outcome = type(result.outcome) == "table" and result.outcome or nil
  if outcome and type(outcome.code) == "string" then return outcome.code end
  local detail = type(result.detail) == "string" and result.detail or ""
  if detail:find("CODEX_BODY_OVERLAP", 1, true) then return "CODEX_BODY_OVERLAP" end
  if detail:find("couldn't get within physical reach", 1, true) then return "TARGET_OUT_OF_REACH" end
  return detail:match("^([A-Z][A-Z0-9_]+[A-Z0-9])")
end
-- A plan that ended partial only because its last step's insert met a full
-- target: every item it did not insert was refused for TARGET_CAPACITY (the
-- target holds all it can). It did all its steps, so a plan chained after
-- it (after_plan_id) runs as after a completed one.
local function satisfies_chain(plan)
  if plan.status ~= "partial" then return false end
  local last = plan.outcomes[#plan.outcomes]
  if not (last and last.status == "partial" and last.step == #plan.steps and last.code == "PARTIAL_INSERT") then
    return false
  end
  local short = false
  for _, row in ipairs(type(last.result) == "table" and type(last.result.transfers) == "table"
    and last.result.transfers or {}) do
    if (tonumber(row.remainder) or 0) > 0 then
      if row.reason ~= "TARGET_CAPACITY" then return false end
      short = true
    end
  end
  return short
end
-- The status a finished plan hands a plan chained after it: completed for a
-- completed plan or one that satisfies_chain, else its own.
function M.chain_status(plan)
  if plan.status == "completed" or satisfies_chain(plan) then return "completed" end
  return plan.status
end
local function log_plan(plan, detail)
  local log_line = log
  -- After a walk back the last outcome is the walk's: report what ended the
  -- plan early (a pre-emption has no outcome). A cancel during the walk is
  -- its own last outcome.
  local ending = plan.ending and plan.ending.walked and plan.ending
  local last = ending and ending.outcome_index and plan.outcomes[ending.outcome_index]
    or not ending and plan.outcomes[#plan.outcomes] or nil
  local result = last and type(last.result) == "table" and last.result or nil
  local reason = last and last.error or detail
  -- Every step completed and only the final observation raised: that, not
  -- the last step, failed the plan.
  local observe_failed = plan.status == "failed" and plan.observation_error ~= nil
    and last ~= nil and last.status == "completed"
  if observe_failed then reason = plan.observation_error end
  -- A failed or partial plan always names a code: STEP_FAILED_UNCLASSIFIED
  -- (STEP_PARTIAL_UNCLASSIFIED) when nothing classified its end; the summary
  -- names the step's action.
  local code = observe_failed and "FINAL_OBSERVATION_FAILED"
    or result and type(result.code) == "string" and result.code
    or last and type(last.code) == "string" and last.code
    or plan.preempted and (ending or not plan.ending) and "PREEMPTED"
    or type(reason) == "string" and reason:match("^([A-Z][A-Z0-9_]+[A-Z0-9])") or nil
  if not code and (plan.status == "failed" or plan.status == "partial") then code = errors.code(plan.status) end
  -- The budget ended a step mid-supply: what that supply was doing stays in
  -- the reason (and so in the row's detail and the server log line).
  if code == "PLAN_BUDGET_EXCEEDED" and type(reason) == "string" and result and type(result.supply) == "table" then
    local supplying = result.supply.supply
    local parts = { "stage " .. tostring(result.supply.stage) }
    if type(supplying) == "table" then
      parts[#parts + 1] = string.format("fetching %s %s (phase %s, %s takes, running %s)", tostring(supplying.wanted),
        tostring(supplying.item), tostring(supplying.phase), tostring(supplying.takes), tostring(supplying.action or "nothing"))
      local last_action = type(supplying.last_action) == "table" and supplying.last_action or nil
      if last_action then
        parts[#parts + 1] = string.format("last %s %s%s", tostring(last_action.action), tostring(last_action.status),
          last_action.code and (" " .. last_action.code) or "")
      end
    end
    local ended = type(result.supply.supply_result) == "table" and result.supply.supply_result or nil
    if ended then parts[#parts + 1] = string.format("supply ended %s %s", tostring(ended.status), tostring(ended.code)) end
    reason = reason .. "; supply: " .. table.concat(parts, ", ")
  end
  local summary, full
  if plan.status == "completed" then
    summary = string.format("completed %d/%d steps", plan.completed_steps, #plan.steps)
  elseif observe_failed then
    full = tostring(reason)
    summary = string.format("failed after %d/%d steps: the final observation raised: %s", plan.completed_steps,
      #plan.steps, errors.cut(full, SUMMARY_REASON))
  else
    local step = last and last.step or ending and ending.step or plan.current_step
    local action = last and last.action or plan.steps[step] and plan.steps[step].action
    full = type(reason) == "string" and reason ~= "" and reason or nil
    summary = string.format("%s at step %d/%d%s%s", plan.status, step, #plan.steps,
      action and (" " .. action) or "", full and (": " .. errors.cut(full, SUMMARY_REASON)) or "")
  end
  local log = storage.activity_log or {}
  storage.activity_log = log
  log[#log + 1] = { plan_id = plan.id, source = plan.source or "pilot", steps = #plan.steps,
    status = plan.status, code = code, summary = summary, detail = full and errors.cut(full, DETAIL_BYTES) or nil,
    start_tick = plan.started_tick, end_tick = game.tick,
    surface = plan.surface, upkeep = upkeep_readback(plan),
    -- The ending step's repeat count, when its code is the plan's.
    ["repeat"] = last and last.code == code and last["repeat"] or nil,
    walk_s = plan_time(plan.walk_ticks), tiles = plan.tiles and tenth(plan.tiles) or nil,
    craft_wait_s = plan_time(plan.craft_wait_ticks) }
  while #log > ACTIVITY_LOG_SIZE do table.remove(log, 1) end
  -- A failed or partial plan also leaves one line in the server log, its
  -- reason cut as the row's detail, so it outlives the ring.
  if log_line and (plan.status == "failed" or plan.status == "partial") then
    pcall(log_line, string.format("[agentic-companion] plan %d source=%s status=%s code=%s steps=%d/%d tick=%d detail=%s",
      plan.id, plan.source or "pilot", plan.status, tostring(code), plan.completed_steps, #plan.steps, game.tick,
      full and (errors.cut(full, DETAIL_BYTES):gsub("%s*\n%s*", " ")) or ""))
  end
  -- next_event wakes the pilot on this: the mod's own upkeep (often
  -- pre-empted) is in activity_log only.
  if plan.source ~= "upkeep" then
    storage.tasks.last_plan_ended = { plan_id = plan.id, status = plan.status, tick = game.tick, surface = plan.surface,
      code = code }
  end
end
-- keep_crafting: a surface change cancels plans but never hand-crafting.
local function finish(task, status, detail, preserve_body, outcome, keep_crafting)
  if type(detail) == "string" then detail = errors.plain(detail) end
  errors.scrub(outcome)
  -- A direct task that failed names a code, as a plan step does.
  if task.type ~= "plan" and (status == "failed" or status == "partial")
    and not (type(outcome) == "table" and type(outcome.code) == "string") then
    outcome = type(outcome) == "table" and outcome or { action = task.type }
    outcome.code = result_code({ detail = detail, outcome = outcome }) or errors.code(status)
  end
  if status == "cancelled" and not keep_crafting and task_crafts(task) then cancel_crafting() end
  if storage.tasks.active and storage.tasks.active.id == task.id then storage.tasks.active = nil end
  storage.tasks.last_finished_tick = game.tick
  -- next_event's idle_since_tick: when pilot work (any task but the mod's
  -- own upkeep) last ended.
  if not (task.type == "plan" and task.source == "upkeep") then storage.tasks.last_pilot_finished_tick = game.tick end
  if not preserve_body then stop_body() end
  if task.type == "plan" then
    task.finished_tick = game.tick
    task.final_inventory = inventory_snapshot()
    for name, change in pairs(inventory_delta(task)) do
      if change < 0 then record_draw(name, -change, "inventory", task) end
    end
    observe_terminal(task)
    local final_status = status == "done" and "completed" or status
    if final_status == "completed" and task.observation_error then final_status = "failed" end
    set_plan_status(task, final_status)
    log_plan(task, detail)
    -- Plans chained after this one keep its final status: its record may be
    -- pruned before they start.
    local handed = M.chain_status(task)
    for _, queued in ipairs(storage.tasks.queue) do
      if queued.type == "plan" and queued.after_plan_id == task.id then queued.predecessor_final = handed end
    end
  end
  storage.tasks.records[task.id] = {
    status = task.type == "plan" and task.status or status, detail = detail or "",
    outcome = outcome,
    finished_tick = game.tick, plan = task.type == "plan" and task or nil,
  }
end
local function assign(task)
  local tasks = storage.tasks
  task.id = tasks.next_id
  if task.type == "plan" then set_plan_status(task, "queued") else task.status = "queued" end
  -- Accepted and queued during a hold; the result says the hold delayed it.
  if task.type == "plan" and human_control() then task.human_control = true end
  tasks.next_id = tasks.next_id + 1
  tasks.queue[#tasks.queue + 1] = task
  return task.id
end

function M.enqueue(params)
  local task = params.task
  if type(task) ~= "table" or not runners[task.type] then error("unknown task type: " .. tostring(type(task) == "table" and task.type or task)) end
  companion.require_companion()
  return { task_id = assign(task) }
end

M.register_action("set_recipe", build.set_recipe_action)
M.register_action("get_items", supply.action)
M.register_action("build_layout", build_layout.layout_action)
M.register_action("explore", explore.action)
M.register_action("move_entity", move_entity.action)
M.register_action("blueprint_place", area_ops.place_action)
M.register_action("build_ghosts", area_ops.ghosts_action)
M.register_action("deconstruct_area", area_ops.deconstruct_action)
M.register_action("upgrade_area", area_ops.upgrade_action)
M.register_action("copy_settings", area_ops.copy_action)
M.register_action("configure_entity", configure.action)
M.register_action("flush_fluid", transfer.flush_action)
M.register_action("place_tiles", tiles.action)
M.register_action("equip", equip.action)
M.register_action("set_requests", requests.action)
M.register_action("create_platform", platforms.create_action)
M.register_action("launch_rocket", rocket.action)
M.register_action("set_platform_route", platforms.route_action)
M.register_action("travel", travel.action)

local ACTIONS = {
  walk_to = "walk_to", mine = "mine", pickup_items = "pickup", place_entity = "place", craft_items = "craft",
  insert_items = "insert", extract_items = "extract", rotate_entity = "rotate",
}
local function make_step_task(step)
  local extension = extensions[step.action]
  if extension then
    local task = extension.make_task(step)
    task.type = step.action
    return task
  end
  local kind = ACTIONS[step.action]
  if not kind then error("unknown plan action: " .. tostring(step.action)) end
  local task = { type = kind }
  if kind == "walk_to" or kind == "mine" then
    task.target = { x = step.x, y = step.y }; task.count = step.count
    if kind == "walk_to" then task.arrival_mode, task.arrival_radius = step.arrival_mode, step.arrival_radius end
    if kind == "mine" then
      task.target_kind, task.allow_fluid_loss = step.target_kind, step.allow_fluid_loss
      task.expected_name, task.observed_tick = step.expected_name, step.observed_tick
    end
  end
  if kind == "pickup" then task.target, task.item, task.count = { x = step.x, y = step.y }, step.item, step.count end
  if kind == "place" then
    task.item, task.position, task.direction = step.name, { x = step.x, y = step.y }, step.direction
    task.input_target, task.output_target = step.input_target, step.output_target
    task.belt_to_ground_type, task.mirror = step.belt_to_ground_type, step.mirror
    task.auto_supply, task.auto_clear, task.insert = step.auto_supply, step.auto_clear, step.insert
  end
  if kind == "craft" then task.recipe, task.count, task.wait_for_completion = step.recipe, step.crafts, step.wait_for_completion end
  if kind == "insert" then
    -- Several targets each get the same items (per_target, or items).
    task.target = step.targets == nil and { x = step.x, y = step.y } or nil
    task.targets, task.items, task.auto_supply = step.targets, step.per_target or step.items, step.auto_supply
    task.inventory = step.inventory
  end
  if kind == "extract" then
    task.target, task.items, task.all = { x = step.x, y = step.y }, step.items, step.items == nil
    task.inventory = step.inventory
  end
  if kind == "rotate" then task.target, task.direction = { x = step.x, y = step.y }, step.direction end
  return task
end
-- What a step takes from the body's own items, read from the step alone at
-- queue time ({use?, fetch?, made?}, each {[item] = count}): use is what it
-- places (a layout's entities by hand, tiles, equipment), starts entities
-- with, inserts (once per listed target) or crafts from; fetch is what a
-- get_items step makes the body carry; made is what a craft step yields.
-- Pieces a connection, blueprint or area step
-- resolves later are not in it, nor what ghosts and platforms take (robots
-- and the hub supply those).
local function placing_item(name)
  local ok, item = pcall(function()
    if prototypes.item[name] then return name end
    local first = prototypes.entity[name].items_to_place_this[1]
    return first and first.name
  end)
  return ok and type(item) == "string" and item or name
end
local function step_needs(step)
  local use = {}
  local function add(name, n)
    n = tonumber(n)
    if type(name) == "string" and n and n > 0 then use[name] = (use[name] or 0) + n end
  end
  local function add_map(map, times)
    for name, n in pairs(type(map) == "table" and map or {}) do add(name, (tonumber(n) or 0) * times) end
  end
  local action = step.action
  if action == "get_items" then
    add(step.item, step.count)
    return next(use) and { fetch = use } or nil
  elseif action == "place_entity" then
    add(placing_item(step.name), 1); add_map(step.insert, 1)
  elseif action == "insert_items" then
    local targets = type(step.targets) == "table" and #step.targets > 0 and #step.targets or 1
    add_map(step.per_target or step.items, targets)
  elseif action == "craft_items" then
    local crafts = tonumber(step.crafts) or 0
    local ok, recipe = pcall(function() return prototypes.recipe[step.recipe] end)
    recipe = ok and recipe or nil
    for _, ingredient in ipairs(recipe and recipe.ingredients or {}) do
      if ingredient.type ~= "fluid" then add(ingredient.name, (tonumber(ingredient.amount) or 0) * crafts) end
    end
    local made = {}
    for _, product in ipairs(recipe and recipe.products or {}) do
      local per_craft = product.type == "item" and not made[product.name] and supply.output_per_craft(recipe, product.name)
      if per_craft and crafts > 0 then made[product.name] = per_craft * crafts end
    end
    if next(made) then return { use = next(use) and use or nil, made = made } end
  elseif action == "build_layout" and step.mode ~= "ghosts" and step.platform == nil then
    for _, entity in ipairs(type(step.entities) == "table" and step.entities or {}) do
      if type(entity) == "table" then add(placing_item(entity.name), 1); add_map(entity.insert, 1) end
    end
  elseif action == "place_tiles" then
    local area, count = step.area, type(step.positions) == "table" and #step.positions or 0
    if type(area) == "table" and type(area.left_top) == "table" and type(area.right_bottom) == "table" then
      count = count + math.max(0, math.ceil(area.right_bottom.x) - math.floor(area.left_top.x))
        * math.max(0, math.ceil(area.right_bottom.y) - math.floor(area.left_top.y))
    end
    add(step.item, count)
  elseif action == "equip" then
    if type(step.armor) == "string" then add(step.armor, 1) end
    for _, row in ipairs(type(step.put) == "table" and step.put or {}) do
      if type(row) == "table" then add(row.name, 1) end
    end
  end
  return next(use) and { use = use } or nil
end
-- A plan's needs from step `from` on, added into `total`: per item the
-- larger of what its get_items steps fetch and what its other steps use
-- beyond what its craft steps make (a fetch usually brings what a later step
-- uses; a crafted item is the plan's own, so a later step using it needs only
-- the craft's ingredients).
local function add_needs(plan, from, total)
  local fetch, use, made = {}, {}, {}
  for i = math.max(1, from), #plan.steps do
    local needs = type(plan.steps[i]) == "table" and plan.steps[i]._needs
    for kind, into in pairs({ fetch = fetch, use = use, made = made }) do
      for name, n in pairs(needs and needs[kind] or {}) do into[name] = (into[name] or 0) + n end
    end
  end
  for name, n in pairs(use) do
    local need = math.max(n - (made[name] or 0), fetch[name] or 0)
    if need > 0 then total[name] = (total[name] or 0) + need end
  end
  for name, n in pairs(fetch) do
    if not use[name] then total[name] = (total[name] or 0) + n end
  end
  return total
end
function M.queue_plan(params, upkeep_selection)
  -- Plans may be queued in every body state but absent (aboard, for the
  -- planet the body is about to land on); their steps check the body.
  local present = companion.require_present()
  if type(params.steps) ~= "table" or #params.steps < 1 or #params.steps > MAX_PLAN_STEPS then
    error("queue_plan requires 1-" .. MAX_PLAN_STEPS .. " steps")
  end
  local source = params.source == nil and "pilot" or params.source
  if not valid_source(source) then
    error("source must be pilot, upkeep or package:<id> (at most 80 characters)")
  end
  -- A package is queued once: the bridge retries a queue_plan whose answer
  -- it lost (an RCON timeout after the mod ran it) and gets the same plan.
  if source:sub(1, 8) == "package:" then
    local tasks = storage.tasks
    local existing
    if tasks.active and tasks.active.type == "plan" and tasks.active.source == source then existing = tasks.active.id end
    for _, queued in ipairs(tasks.queue) do
      if not existing and queued.type == "plan" and queued.source == source then existing = queued.id end
    end
    for _, row in ipairs(storage.activity_log or {}) do
      if not existing and row.source == source then existing = row.plan_id end
    end
    if existing then return { plan_id = existing, duplicate = true } end
  end
  -- client_key: the MCP layer's key for one queue_plan call, sent again when
  -- it retries after losing the answer; the same key returns the plan the
  -- first call queued.
  local key = params.client_key
  if key ~= nil and (type(key) ~= "string" or #key < 1 or #key > 64) then
    error("client_key must be a string of 1-64 characters")
  end
  for _, row in ipairs(key and storage.tasks.client_keys or {}) do
    if row.key == key then return { plan_id = row.plan_id, duplicate = true, tick = row.tick } end
  end
  -- A terminal observation runs inside the tick that ends the plan; full
  -- detail is never taken there (observe_local is the read for it).
  if params.observation_detail ~= nil and params.observation_detail ~= "none"
    and params.observation_detail ~= "compact" then
    error("observation_detail must be none or compact")
  end
  for i, step in ipairs(params.steps) do
    if type(step) ~= "table" or (step.action ~= "wait_for_item" and step.action ~= "wait_for_research"
      and step.action ~= "inspect_entities" and not ACTIONS[step.action] and not extensions[step.action]) then
      error("unknown plan action at step " .. i .. ": " .. tostring(type(step) == "table" and step.action or step))
    end
    if step.action == "craft_items" then
      if step.count ~= nil then error("queue_plan craft_items step " .. i .. " uses removed field count; use crafts") end
      local crafts = tonumber(step.crafts)
      if not crafts or crafts % 1 ~= 0 or crafts < 1 or crafts > 100 then
        error("queue_plan craft_items step " .. i .. " requires crafts as an integer from 1 to 100")
      end
    end
    if step.action == "insert_items" and step.per_target ~= nil and step.items ~= nil then
      error("queue_plan insert_items step " .. i .. " takes per_target or items, not both")
    end
    if (step.action == "insert_items" or step.action == "extract_items") and step.inventory ~= nil
      and not inventory_roles.ROLES[step.inventory] then
      error("queue_plan " .. step.action .. " step " .. i .. " inventory must be one of "
        .. table.concat(inventory_roles.ORDER, ", "))
    end
    if step.action == "inspect_entities" then
      if type(step.positions) ~= "table" or #step.positions < 1 or #step.positions > inspect.MAX_TARGETS then
        error("queue_plan inspect_entities step " .. i .. " requires 1-" .. inspect.MAX_TARGETS .. " positions")
      end
      for _, position in ipairs(step.positions) do
        if type(position) ~= "table" or type(position.x) ~= "number" or type(position.y) ~= "number" then
          error("queue_plan inspect_entities step " .. i .. " positions require numeric x and y")
        end
      end
    end
    if step.action == "wait_for_research" then
      if type(step.technology) ~= "string" or step.technology == ""
        or type(step.timeout_seconds) ~= "number" or step.timeout_seconds % 1 ~= 0
        or step.timeout_seconds < 1 or step.timeout_seconds > 300 then
        error("queue_plan wait_for_research step " .. i .. " requires technology and timeout_seconds from 1 to 300")
      end
    end
    local extension = extensions[step.action]
    if extension and extension.validate then extension.validate(step, i) end
    -- Travel moves the body off its planet: the pilot's decision only.
    if step.action == "travel" and source ~= "pilot" then
      error("queue_plan travel step " .. i .. " is the pilot's: packages and upkeep never move the body off its surface")
    end
  end
  -- The surface the positional steps belong to: the one named, else the
  -- destination of the last travel step already pending in the FIFO, else
  -- the body's own (always for upkeep, which serves the body's surface beside
  -- pending work); a travel step hands its destination to the steps after it.
  local current
  if params.surface ~= nil then
    local ref, code, why = platforms.canonical_ref(present.force, params.surface)
    if not ref then error(code .. ": queue_plan surface: " .. why, 0) end
    current = ref
  else
    local pending = fifo_travel()
    current = source ~= "upkeep" and pending[#pending] or body_surface()
  end
  local first_tag
  for _, step in ipairs(params.steps) do
    step._surface = nil
    if step.action == "travel" then current = step._to
    elseif tagged(step) then
      step._surface = current
      first_tag = first_tag or current
    end
  end
  for _, step in ipairs(params.steps) do step._needs = step_needs(step) end
  local budget_steps = 0
  for _, step in ipairs(params.steps) do
    local extension = extensions[step.action]
    budget_steps = budget_steps + (extension and extension.budget_steps and extension.budget_steps(step) or 1)
  end
  local predecessor = params.after_plan_id and tonumber(params.after_plan_id) or nil
  if params.after_plan_id ~= nil and (not predecessor or predecessor < 1) then error("after_plan_id must be a positive plan ID") end
  if predecessor then
    local known = storage.tasks.records[predecessor] and storage.tasks.records[predecessor].plan ~= nil
      or storage.tasks.active and storage.tasks.active.id == predecessor and storage.tasks.active.type == "plan"
    for _, queued in ipairs(storage.tasks.queue) do
      if queued.id == predecessor and queued.type == "plan" then known = true end
    end
    if not known then
      error("PREDECESSOR_UNKNOWN: after_plan_id " .. predecessor .. " names no current or retained plan"
        .. " (pruned, a single task, or never queued); omit it or use a current plan ID")
    end
  end
  local plan = {
    type = "plan", steps = params.steps, current_step = 0, completed_steps = 0, outcomes = {},
    final_observation_radius = tonumber(params.final_observation_radius) or 15,
    observation_detail = params.observation_detail == "compact" and "compact" or "none",
    after_plan_id = predecessor, source = source, budget_steps = budget_steps,
    -- Second argument is internal only; RPC callers supply only params.
    upkeep_selection = source == "upkeep" and upkeep_selection or nil,
    -- The first step tag; each positional step carries its own.
    surface = first_tag, step_tags = true,
  }
  -- Ticks the FIFO sat empty before this plan: the body's idle time while the
  -- caller reasoned, so a short plan's cost is visible in the next result.
  local tasks, body = storage.tasks, companion.get()
  local crafting = body and body.valid and (body.crafting_queue_size or 0) > 0
  local body_idle_ticks = (not tasks.active and #tasks.queue == 0 and not crafting and tasks.last_finished_tick)
    and math.max(0, game.tick - tasks.last_finished_tick) or 0
  -- tick anchors the caller's next_event: a plan that ends before that wait
  -- starts still returns plan_ended, not an empty queue.
  -- needs: item totals its steps take (add_needs), nothing reserved.
  local needs = add_needs(plan, 1, {})
  -- hand_craft: what of the needs hand-crafting would make beyond what is
  -- carried and stocked, in seconds at the body's speed (supply.hand_craft,
  -- arithmetic from current stock; absent when none).
  local hand_craft
  if source ~= "upkeep" and body and body.valid and next(needs) then
    local wants = {}
    for name, count in pairs(needs) do wants[#wants + 1] = { name = name, count = count } end
    table.sort(wants, function(a, b) return a.name < b.name end)
    local ok, bill = pcall(supply.hand_craft, body, wants)
    hand_craft = ok and bill or nil
  end
  local plan_id = assign(plan)
  if key then
    local keys = storage.tasks.client_keys or {}
    storage.tasks.client_keys = keys
    keys[#keys + 1] = { key = key, plan_id = plan_id, tick = game.tick }
    if #keys > M.MAX_CLIENT_KEYS then table.remove(keys, 1) end
  end
  return { plan_id = plan_id, after_plan_id = predecessor, body_idle_ticks = body_idle_ticks,
    human_control = plan.human_control, tick = game.tick, needs = next(needs) and needs or nil, hand_craft = hand_craft }
end
local function plan_payload(plan)
  local c = companion.get()
  local diagnostics
  if plan.current_task then
    diagnostics = { action = plan.steps[plan.current_step] and plan.steps[plan.current_step].action,
      next_check_tick = plan.next_check_tick }
    diagnostics.robot_relocation = move_entity.diagnostics(plan.current_task)
    local walker = plan.current_task._walk
      or (plan.current_task._approach and plan.current_task._approach.walk)
      or plan.current_task.walker
      or plan.current_task
    if walker.phase or walker.retries or walker.failure then
      diagnostics.route = {
        phase = walker.phase,
        retries = walker.retries or 0,
        failure = walker.failure,
        request_tick = walker.request_tick,
        last_progress_tick = walker.last_progress_tick,
        blocker_evidence = walker.blocker_evidence,
      }
    end
    local target = plan.current_task.target or plan.current_task.position
    if target then diagnostics.machine = { position = { x = target.x, y = target.y } } end
    -- The step's supply (get_items or an embedded auto-supply) and the body's
    -- crafting queue: recipe and count at its head, seconds it still needs.
    diagnostics.supply = supply_state(plan.current_task)
    diagnostics.crafting = crafting_summary()
    -- A travel step: its phase, deadline and the platform's facts.
    diagnostics.travel = travel.facts(plan.current_task)
  elseif plan.status == "failed" and plan.outcomes[#plan.outcomes] then
    diagnostics = { failure = plan.outcomes[#plan.outcomes].error }
  end
  local committed_steps = {}
  local incomplete_step
  for _, outcome in ipairs(plan.outcomes) do
    if outcome.status == "completed" or outcome.status == "partial" then
      committed_steps[#committed_steps + 1] = outcome.step
    elseif outcome.status == "failed" or outcome.status == "cancelled" then
      incomplete_step = { step = outcome.step, status = outcome.status, effects = "unknown" }
    end
  end
  return {
    plan_id = plan.id, after_plan_id = plan.after_plan_id, source = plan.source,
    status = plan.status, source_tick = game.tick,
    -- When it ended (the package bridge times a package's verify from it).
    finished_tick = plan.finished_tick,
    -- Where the plan's next positional step acts (its first tag once done).
    surface = plan.status ~= "completed" and next_surface(plan) or plan.surface,
    -- Present only when a human hold delayed this plan: delayed, not failed.
    human_control = plan.human_control,
    position = c and { x = c.position.x, y = c.position.y } or nil,
    current_step = plan.current_step, completed_steps = plan.completed_steps,
    total_steps = #plan.steps, outcomes = plan.outcomes, queue_depth = #storage.tasks.queue,
    -- Nothing active, queued, parked, or hand-crafting: the body is idle now.
    fifo_empty = not storage.tasks.active and #storage.tasks.queue == 0
      and not (c and c.valid and (c.crafting_queue_size or 0) > 0),
    transitions = plan.transitions,
    inventory_delta = inventory_delta(plan),
    observation = plan.observation, observation_error = plan.observation_error,
    upkeep = upkeep_readback(plan), upkeep_selection = plan.upkeep_selection,
    execution = { mode = "sequential_nontransactional", rollback = "none",
      committed_steps = committed_steps, incomplete_step = incomplete_step },
    diagnostics = diagnostics,
    -- A partial plan after which a chained plan still runs (satisfies_chain).
    satisfies_chain = satisfies_chain(plan) or nil,
    -- Where its time went so far: walking (seconds, tiles) and waiting on
    -- hand-crafting (account_phase).
    walk_s = plan_time(plan.walk_ticks), tiles = plan.tiles and tenth(plan.tiles) or nil,
    craft_wait_s = plan_time(plan.craft_wait_ticks),
  }
end
-- compact (the package bridge's own polls): only what it asks, {plan_id,
-- source, status, satisfies_chain, finished_tick, source_tick}: no outcomes,
-- observation or diagnostics are built.
local function compact_payload(plan)
  return { plan_id = plan.id, source = plan.source, status = plan.status, satisfies_chain = satisfies_chain(plan) or nil,
    finished_tick = plan.finished_tick, source_tick = game.tick }
end
-- A plan_status payload of more than PLAN_STATUS_DIRECT_NODES nodes (a
-- long plan's outcomes with their layouts and supply rows, its terminal
-- observation) is never encoded whole in the RPC's tick: it is a job whose
-- result the jobs encoder writes over ticks, read through get_job (the
-- bridge waits for it). One plan_status took 17.5 ms (trial 0013) while
-- the median stayed 0.3 ms: the cost is the payload's size. The lists the
-- payload shares with the live plan are copied, so a step that ends while
-- it is encoded changes nothing already counted, and so are the running
-- step's diagnostics and upkeep context, which hold the live task's own
-- tables (a supply result, a walk's goal and failure): the encoder resolves
-- each key over later ticks, and a key the task cleared meanwhile would
-- leave a hole in the JSON.
local PLAN_STATUS_DIRECT_NODES = jobs.WORK_PER_TICK
M.PLAN_STATUS_DIRECT_NODES = PLAN_STATUS_DIRECT_NODES
jobs.register("plan_status", {
  defer_encode = true,
  start = function(params) return { payload = params.payload } end,
  step = function(state, budget)
    budget.left = budget.left - 1
    return state.payload
  end,
})
local function plan_answer(plan)
  local payload = plan_payload(plan)
  if jobs.count_nodes(payload, PLAN_STATUS_DIRECT_NODES) <= PLAN_STATUS_DIRECT_NODES then return payload end
  local function copy(value, seen)
    if type(value) ~= "table" then return value end
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do out[k] = copy(v, seen) end
    return out
  end
  payload.outcomes = { table.unpack(payload.outcomes or {}) }
  if payload.transitions then payload.transitions = { table.unpack(payload.transitions) } end
  payload.diagnostics = copy(payload.diagnostics, {})
  if payload.upkeep and payload.upkeep.active then payload.upkeep.active = copy(payload.upkeep.active, {}) end
  -- With every job slot taken (JOBS_BUSY) it is answered at once, as before.
  local ok, pending = pcall(jobs.start, "plan_status", { payload = payload })
  return ok and pending or payload
end
function M.plan_status(params)
  local id = tonumber(params.plan_id)
  if not id then error("plan_status requires plan_id") end
  local answer = params.compact == true and compact_payload or plan_answer
  local tasks = storage.tasks
  if tasks.active and tasks.active.id == id and tasks.active.type == "plan" then return answer(tasks.active) end
  for _, queued in ipairs(tasks.queue) do if queued.id == id and queued.type == "plan" then return answer(queued) end end
  local record = tasks.records[id]
  if record and record.plan then
    if answer == compact_payload then return answer(record.plan) end
    observe_terminal(record.plan); return plan_answer(record.plan)
  end
  error("unknown plan_id: " .. id .. ": never queued, or it ended more than " .. math.floor(RECORD_TTL_TICKS / 3600)
    .. " minutes ago (" .. math.floor(FAILED_RECORD_TTL_TICKS / 3600) .. " if it failed or was partial);"
    .. " activity_log keeps the last " .. ACTIVITY_LOG_SIZE .. " plan outcomes", 0)
end
function M.get(params)
  local id = tonumber(params.task_id)
  if not id then error("get_task requires task_id") end
  local tasks = storage.tasks
  if tasks.active and tasks.active.id == id then return { status = "running", detail = "" } end
  for _, queued in ipairs(tasks.queue) do if queued.id == id then return { status = "queued", detail = "" } end end
  local record = tasks.records[id]
  if record then return { status = record.status, detail = record.detail, outcome = record.outcome } end
  error("unknown task_id: " .. id)
end
-- Every cancel names who asked (the bridge's tool and role) and is kept in
-- activity_log and the server log: {kind = "cancel", tick, origin, plan_id |
-- all, cancelled_count}. A cancel-all row names the newest plan ID at that
-- moment (after_plan_id); since_plan_id filters it by that ID.
local MAX_ORIGIN = 120
-- A row that is not a plan outcome ({kind, ...}): without a plan_id it names
-- the newest plan ID at that moment (after_plan_id), which since_plan_id
-- filters by.
function M.log_event(row)
  if not row.plan_id then row.after_plan_id = storage.tasks.next_id - 1 end
  local log_rows = storage.activity_log or {}
  storage.activity_log = log_rows
  log_rows[#log_rows + 1] = row
  while #log_rows > ACTIVITY_LOG_SIZE do table.remove(log_rows, 1) end
end
local function log_cancel(origin, id, cancelled)
  local row = { kind = "cancel", tick = game.tick, origin = origin, cancelled_count = cancelled }
  if id then row.plan_id = id else row.all = true end
  M.log_event(row)
  if log then
    pcall(log, string.format("[agentic-companion] cancel origin=%s target=%s cancelled=%d tick=%d", origin,
      id and ("plan " .. id) or "all", cancelled, game.tick))
  end
end

-- A running step or direct task ends from outside (a cancel, the plan's
-- budget, or with body_only the stall watchdog): its runner's cancelled
-- hook, if any, lets go of what it holds (a travel step's launch marker, an
-- escape's taken-up entity). Returns the hook's note, or nil. A runner with
-- no hook may still embed an auto-supply whose step-out holds an entity.
local function task_cancelled(task, body_only)
  local runner = task and runners[task.type]
  local noted, note = pcall(function()
    if runner and runner.cancelled then return runner.cancelled(task, body_only) end
    return task and supply.cancel_nested(task, body_only) or nil
  end)
  return noted and note or nil
end
local function step_cancelled(plan) return task_cancelled(plan.current_task) end
-- The running direct task's note, as its cancelled outcome.
local function direct_cancelled(task) if task.type ~= "plan" then return task_cancelled(task) end end

function M.cancel(params)
  local origin = params.origin
  if type(origin) ~= "string" or origin == "" or #origin > MAX_ORIGIN then
    error("cancel requires origin: who asks, as <tool>/<role> (at most " .. MAX_ORIGIN .. " characters)")
  end
  local tasks, n = storage.tasks, 0
  local detail = "CANCELLED by " .. origin
  local function record_cancelled_step(plan)
    if plan.type == "plan" then plan.cancel_origin = origin end
    if plan.type == "plan" and plan.current_task then
      local step = plan.steps[plan.current_step]
      plan.outcomes[#plan.outcomes + 1] = {
        step = plan.current_step, action = step.action,
        status = "cancelled", error = detail, result = step_cancelled(plan),
        upkeep_context = plan.source == "upkeep" and supply.diagnostics(plan.current_task) or nil,
      }
      plan.current_task = nil
    end
  end
  if params.all then
    local queued_tasks = tasks.queue
    tasks.queue = {}
    for _, queued in ipairs(queued_tasks) do
      record_cancelled_step(queued)
      finish(queued, "cancelled", detail, true)
      n = n + 1
    end
    if tasks.active then
      record_cancelled_step(tasks.active)
      finish(tasks.active, "cancelled", detail, nil, direct_cancelled(tasks.active)); n = n + 1
    end
    cancel_crafting()
    -- Emergency cancellation is not the next plan's idle time, and upkeep
    -- stays off until a plan finishes. keep_upkeep (the supervisor's
    -- retained-work reconciliation) leaves upkeep on, idle from now.
    tasks.last_finished_tick = params.keep_upkeep == true and game.tick or nil
    tasks.last_cancel_all_tick = game.tick
    log_cancel(origin, nil, n)
    return { cancelled = n }
  end
  local id = tonumber(params.task_id or params.plan_id)
  if not id then error("cancel requires task_id, plan_id, or all=true") end
  -- only_source (cancel_plan): the plan must be that source's, and queued or
  -- running (a lent or parked plan too); else a coded refusal, nothing
  -- cancelled and nothing logged.
  if params.only_source ~= nil then
    local plan = tasks.active and tasks.active.id == id and tasks.active or nil
    for _, queued in ipairs(tasks.queue) do if queued.id == id then plan = queued end end
    if not plan or plan.type ~= "plan" then
      local record = tasks.records[id]
      error(string.format("PLAN_NOT_PENDING: plan %d is %s: only a queued or running plan can be cancelled", id,
        plan and "a direct tool's task, not a plan" or record and ("already " .. tostring(record.status)) or "unknown"), 0)
    end
    if (plan.source or "pilot") ~= params.only_source then
      error(string.format("NOT_YOUR_PLAN: plan %d is %s's, not %s's", id, tostring(plan.source), params.only_source), 0)
    end
  end
  if tasks.active and tasks.active.id == id then
    record_cancelled_step(tasks.active)
    finish(tasks.active, "cancelled", detail, nil, direct_cancelled(tasks.active))
    log_cancel(origin, id, 1)
    return { cancelled = 1 }
  end
  for i, queued in ipairs(tasks.queue) do if queued.id == id then
    table.remove(tasks.queue, i)
    record_cancelled_step(queued)
    finish(queued, "cancelled", detail, true)
    log_cancel(origin, id, 1)
    return { cancelled = 1 }
  end end
  log_cancel(origin, id, 0)
  return { cancelled = 0 }
end
-- The running plan or task; a travel plan that lends the FIFO (lent =
-- "travel") still holds the body: it is the running plan between its
-- guests, and beside a guest it is named as beside {plan_id, travel}.
function M.active_summary()
  local active, head = storage.tasks.active, storage.tasks.queue[1]
  local lent = head and head.lent == "travel" and head or nil
  if not active then active, lent = lent, nil end
  if not active then return nil end
  if active.type == "plan" then
    local step = active.steps[active.current_step]
    return { id = active.id, type = "plan", status = "running", current_step = active.current_step,
      total_steps = #active.steps, action = step and step.action, source = active.source or "pilot",
      travel = travel.facts(active.current_task),
      beside = lent and { plan_id = lent.id, travel = travel.facts(lent.current_task) } or nil }
  end
  return { id = active.id, type = active.type, status = "running" }
end
-- activity_log {since_plan_id?, limit?, changes?}: recent plan outcomes,
-- oldest first; changes ({since_tick?, area?, surface?, limit?}) adds the
-- change journal's matching rows (journal.changes).
function M.activity_log(params)
  local since = params.since_plan_id ~= nil and tonumber(params.since_plan_id) or nil
  if params.since_plan_id ~= nil and not since then error("since_plan_id must be a plan ID") end
  local limit = params.limit ~= nil and tonumber(params.limit) or 16
  if not limit or limit % 1 ~= 0 or limit < 1 or limit > ACTIVITY_LOG_SIZE then
    error("limit must be an integer from 1 to " .. ACTIVITY_LOG_SIZE)
  end
  local rows = {}
  for _, entry in ipairs(storage.activity_log) do
    if not since or (entry.plan_id or entry.after_plan_id) > since then
      rows[#rows + 1] = entry
    end
  end
  local omitted = math.max(0, #rows - limit)
  if omitted > 0 then rows = { table.unpack(rows, omitted + 1) } end
  return { tick = game.tick, entries = rows, omitted = omitted,
    changes = params.changes ~= nil and journal.changes(params.changes) or nil }
end
function M.queue_length() return #storage.tasks.queue end

-- Totals over the plans the FIFO still holds (the running one from its
-- current step): queued_demand (add_needs per plan) and short_by, what of it
-- the body's carried items plus own stock on its surface (registry totals)
-- do not cover; each the `limit` largest, with omitted_* counting the rest.
-- Totals only: nothing is reserved or ordered. nil with nothing queued.
local function largest(map, limit)
  local names = {}
  for name in pairs(map) do names[#names + 1] = name end
  if #names == 0 then return nil, nil end
  table.sort(names, function(a, b)
    if map[a] ~= map[b] then return map[a] > map[b] end
    return a < b
  end)
  local out = {}
  for i = 1, math.min(limit, #names) do out[names[i]] = map[names[i]] end
  return out, #names > limit and #names - limit or nil
end
function M.queued_demand(limit)
  local tasks = storage.tasks
  if not tasks then return nil end
  local total = {}
  local active = tasks.active
  if active and active.type == "plan" then add_needs(active, active.current_step or 1, total) end
  for _, queued in ipairs(tasks.queue) do
    if queued.type == "plan" then add_needs(queued, 1, total) end
  end
  if not next(total) then return nil end
  local names = {}
  for name in pairs(total) do names[#names + 1] = name end
  local ok, stock = pcall(registry.stock_totals, names)
  local c = companion.get()
  local short = {}
  for _, name in ipairs(names) do
    local have = (ok and stock[name] or 0) + (c and c.valid and c.get_item_count(name) or 0)
    if total[name] > have then short[name] = total[name] - have end
  end
  local out = {}
  out.queued_demand, out.omitted_queued_demand = largest(total, limit)
  out.short_by, out.omitted_short_by = largest(short, limit)
  return out
end

-- Steps that can add, remove or reconfigure machines refresh the factory
-- lines (script-created entities raise no player build event).
local TOPOLOGY_TASKS = { place = true, mine = true, set_recipe = true, rotate = true, build_plan = true }
-- An upkeep plan run beside pending work ends with a walk back to where the
-- body stood (chores.lua marks that step upkeep_return), so a parked wait
-- still reads its target from there. Ended early (pre-empted, or a step
-- failed), the plan still takes that walk, then ends as it would have.
local function return_step(plan)
  local index = #plan.steps
  return plan.source == "upkeep" and plan.steps[index].upkeep_return == true and index or nil
end
local function walk_back(plan, status, detail, outcome_index)
  local back = return_step(plan)
  if not back or plan.ending or plan.current_step >= back then return false end
  -- outcome_index: the step outcome that ended it (a pre-emption has none).
  plan.ending = { status = status, detail = detail, completed_steps = plan.completed_steps,
    step = outcome_index and plan.current_step or plan.completed_steps + 1, outcome_index = outcome_index }
  return true
end
local function finish_step(plan, result)
  local kind = plan.current_task and plan.current_task.type
  -- A merged insert retry (merge_retry): its first attempt was recorded when
  -- it ended, so only the retry's own transfers are new.
  local merged = type(result.outcome) == "table" and type(result.outcome.retry) == "table" and result.outcome or nil
  factory_activity.record(kind, merged and { target = merged.target, transfers = merged.retry.transfers } or result.outcome)
  if kind and (TOPOLOGY_TASKS[kind] or extensions[kind]) then autonomy.mark_dirty() end
  local step = plan.steps[plan.current_step]
  -- Hand service a line cost the body (factory_status hand_seconds): the
  -- step's time from its first attempt, shared by the machines it served.
  local recovering = plan._recovery and plan._recovery.step == plan.current_step and plan._recovery
  local started = plan.current_task and plan.current_task.started_tick or recovering and recovering.started_tick
  if started and (step.action == "insert_items" or step.action == "extract_items") then
    local outcome, spots = type(result.outcome) == "table" and result.outcome or {}, {}
    if type(outcome.target) == "table" and type(outcome.target.position) == "table" then
      spots[1] = outcome.target.position
    else
      for _, row in ipairs(type(outcome.targets) == "table" and outcome.targets or {}) do
        if row.x then spots[#spots + 1] = { x = row.x, y = row.y } end
      end
    end
    for _, at in ipairs(spots) do autonomy.on_body_time(at, math.floor((game.tick - started) / #spots)) end
  end
  local status = result.status == "done" and "completed" or result.status
  local recovery = plan._recovery
  if type(result.detail) == "string" then result.detail = errors.plain(result.detail) end
  errors.scrub(result.outcome)
  -- Every failed or partial step names a code (errors.code).
  local code = (status == "failed" or status == "partial") and (result_code(result) or errors.code(status)) or nil
  local repeated = status ~= "cancelled" and count_repeat(step, code) or nil
  local outcome = type(result.outcome) == "table" and result.outcome or nil
  if outcome and outcome.code == "SUPPLY_SHORTFALL" and type(outcome.missing) == "table" then
    local names = {}
    for _, row in ipairs(outcome.missing) do if type(row.item) == "string" then names[#names + 1] = row.item end end
    outcome.recent_draws = recent_draws(names)
  end
  if status == "completed" or status == "partial" then journal_step(plan, step) end
  plan.outcomes[#plan.outcomes + 1] = {
    step = plan.current_step, action = step.action, status = status, code = code, ["repeat"] = repeated,
    upkeep_context = plan.source == "upkeep" and supply.diagnostics(plan.current_task) or nil,
    result = result.outcome or ((status == "completed" or status == "partial") and (result.detail or status) or nil),
    error = (status == "failed" or status == "cancelled") and (result.detail or status) or nil,
    recovery = recovery and recovery.step == plan.current_step and { code = recovery.code,
      fix = recovery.fix and recovery.fix.type or (recovery.items and "retry_remainder" or "retry"),
      fix_error = recovery.fix_error, fix_detail = recovery.fix_detail,
      exits = recovery.exits and #recovery.exits or nil } or nil,
  }
  plan.current_task = nil
  if plan.source == "upkeep" and upkeep_listener then
    local ok, err = pcall(upkeep_listener, plan, plan.current_step, status)
    if not ok then errors.record("task:upkeep_listener", err) end
  end
  local ending = plan.ending
  if ending then
    -- The walk back after an early end has ended: the plan ends as it would
    -- have, its contiguous steps unchanged.
    plan.completed_steps = ending.completed_steps
    ending.walked = true
    finish(plan, ending.status, ending.detail)
    return
  end
  if status ~= "completed" then
    if not walk_back(plan, status, result.detail, #plan.outcomes) then finish(plan, status, result.detail) end
    return
  end
  plan.completed_steps = plan.current_step
  if plan.completed_steps == #plan.steps then finish(plan, "done", "") end
end
local function wait_timeout_ticks(step)
  return math.floor((tonumber(step.timeout_seconds) or 120) * 60)
end
local function wait_for_research(plan, step)
  plan.wait_started_tick = plan.wait_started_tick or game.tick
  step._wait_started_tick = step._wait_started_tick or plan.wait_started_tick
  local force = companion.require_present().force
  local technology = force.technologies and force.technologies[step.technology]
  if not technology then return { status = "failed", detail = "UNKNOWN_TECHNOLOGY: " .. step.technology,
    outcome = { code = "UNKNOWN_TECHNOLOGY", technology = step.technology } } end
  if technology.researched then
    local elapsed = game.tick - step._wait_started_tick
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    return { status = "done", detail = step.technology .. " research completed",
      outcome = { code = "RESEARCH_COMPLETED", technology = step.technology,
        start_tick = step._wait_started_tick, completed_tick = game.tick, elapsed_ticks = elapsed } }
  end
  local active = force.current_research and force.current_research.name == step.technology
  if not active then for _, queued in pairs(force.research_queue or {}) do
    if queued and (queued.name == step.technology or queued == step.technology) then active = true; break end
  end end
  if not active then return { status = "failed", detail = "RESEARCH_NOT_ACTIVE: " .. step.technology,
    outcome = { code = "RESEARCH_NOT_ACTIVE", technology = step.technology } } end
  if game.tick - plan.wait_started_tick >= wait_timeout_ticks(step) then
    local elapsed = game.tick - step._wait_started_tick
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    return { status = "failed", detail = string.format("timed out waiting for research %s after %d ticks", step.technology, elapsed),
      outcome = { code = "RESEARCH_WAIT_TIMEOUT", technology = step.technology, elapsed_ticks = elapsed } }
  end
  plan.next_check_tick = game.tick + 30
end

local PARKED_ACTIONS = { wait_for_item = true, wait_for_research = true }
-- Actions a save from an older version may still hold, and how such a step
-- ends: a dropped check as done, a dropped build as failed (nothing was built).
local REMOVED_ACTIONS = { validate_factory_component = "done", build_block = "failed" }
local function removed_result(action)
  return { status = REMOVED_ACTIONS[action], detail = "REMOVED_ACTION: " .. action .. " no longer exists",
    outcome = { code = "REMOVED_ACTION", action = action } }
end
-- What a wait_for_item has seen, arithmetic only: the count now, the net
-- inflow per minute since the wait began (first read to latest), the
-- seconds to the target at that inflow (absent while it does not rise; 0
-- once met), the seconds waited and the timeout. trial 0013: a 300 s wait
-- for 89 plates at 16/min timed out with no word on the rate.
local function wait_progress(step)
  local start = tonumber(step._starting_count) or 0
  local current = tonumber(step._current_count) or start
  local elapsed = step._wait_started_tick and game.tick - step._wait_started_tick or 0
  local per_min = elapsed > 0 and math.floor((current - start) * 3600 / elapsed * 10 + 0.5) / 10 or nil
  local to_target
  if current >= step.count then to_target = 0
  elseif per_min and per_min > 0 then to_target = math.ceil((step.count - current) * 60 / ((current - start) * 3600 / elapsed)) end
  return { item = step.item, count = current, target = step.count, starting_count = start, net_per_min = per_min,
    seconds_to_target = to_target, waited_s = math.floor(elapsed / 60), timeout_s = math.floor(wait_timeout_ticks(step) / 60) }
end
local function wait_timeout_detail(step)
  local p = wait_progress(step)
  local elapsed = step._wait_started_tick and game.tick - step._wait_started_tick or 0
  local rate = p.seconds_to_target
    and string.format("; net inflow %.1f/min: %d s more to %d at that rate", p.net_per_min, p.seconds_to_target, p.target)
    or string.format("; net inflow %.1f/min: the count does not rise", p.net_per_min or 0)
  return string.format("ITEM_WAIT_TIMEOUT: timed out waiting for %d %s in %s: starting %d, current %d, observed delta %d after %d ticks%s",
    step.count, step.item, step.inventory, p.starting_count, p.count, p.count - p.starting_count, elapsed, rate)
end
local function wait_timeout_result(step)
  local outcome = wait_progress(step)
  outcome.code = "ITEM_WAIT_TIMEOUT"
  return { status = "failed", detail = wait_timeout_detail(step), outcome = outcome }
end
local function wait_for_item(plan, step)
  plan.wait_started_tick = plan.wait_started_tick or game.tick
  step._wait_started_tick = step._wait_started_tick or plan.wait_started_tick
  -- The condition is read before the deadline is applied: a wait whose items
  -- are present never times out on stale evidence.
  local timed_out = game.tick - plan.wait_started_tick >= wait_timeout_ticks(step)
  -- The read is inspect_entity's: within 30 tiles of the body, or beyond
  -- them an own-force entity the force has charted (a parked wait the body
  -- left for other work keeps reading its machine from afar).
  local response = inspect.inspect({ targets = { { x = step.x, y = step.y } } })
  local entity = response.entities and response.entities[1]
  local c = companion.require_companion()
  local dx, dy = c.position.x - step.x, c.position.y - step.y
  if (not entity or entity.error) and dx * dx + dy * dy > 900 then
    if timed_out then
      plan.wait_started_tick, plan.next_check_tick = nil, nil
      return wait_timeout_result(step)
    end
    local distance = math.sqrt(dx * dx + dy * dy)
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    -- A target read before lies in charted land, which stays charted: the
    -- refusal there means no own machine is left at it, which walking back
    -- cannot fix.
    if step._starting_count ~= nil and surfaces.charted(c.force, c.surface, math.floor(step.x / 32), math.floor(step.y / 32)) then
      return { status = "failed",
        detail = string.format("WAIT_TARGET_GONE: no own machine is left at (%.1f, %.1f), %.1f tiles away", step.x, step.y, distance),
        outcome = { code = "WAIT_TARGET_GONE", distance = distance,
          corrective_hint = "The machine was removed or replaced: inspect the spot before waiting on it again." } }
    end
    return { status = "failed",
      detail = string.format("TARGET_OUT_OF_OBSERVATION_RANGE: wait target is %.1f tiles away and not readable from here; maximum is 30", distance),
      outcome = { code = "TARGET_OUT_OF_OBSERVATION_RANGE", distance = distance,
        max_distance = 30, corrective_hint = "Physically approach with walk_to, or put this wait after a movement predecessor." } }
  end
  if not entity or entity.error then return { status = "failed", detail = entity and entity.error or "inspect returned no entity" } end
  local found = entity.inventories and entity.inventories[step.inventory] and entity.inventories[step.inventory][step.item] or 0
  if step._starting_count == nil then step._starting_count = found end
  step._current_count = found
  if found >= step.count then
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    local detail = step.inventory .. " has " .. found .. " " .. step.item
    local outcome = wait_progress(step)
    outcome.detail = detail
    return { status = "done", detail = detail, outcome = outcome }
  end
  if timed_out then
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    return wait_timeout_result(step)
  end
  plan.next_check_tick = game.tick + 30
end
local function expire_parked_waits(tasks)
  for index = #tasks.queue, 1, -1 do
    local plan = tasks.queue[index]
    local step = plan.type == "plan" and plan.status == "waiting" and plan.steps[plan.current_step] or nil
    local due = step and (step.action == "wait_for_item" or step.action == "wait_for_research") and plan.wait_started_tick
      and game.tick - plan.wait_started_tick >= wait_timeout_ticks(step)
    if due and (not tasks.active or tasks.active.source == "upkeep") then
      -- The body is free, or upkeep holds it and gives way at its next step
      -- boundary (after its walk back): the dispatcher reads the condition
      -- once more before the deadline is applied, so a met wait never expires.
      plan.next_check_tick = nil
    elseif due then
      table.remove(tasks.queue, index)
      local detail = step.action == "wait_for_item" and wait_timeout_detail(step)
        or string.format("timed out waiting for research %s after %d ticks", step.technology, game.tick - plan.wait_started_tick)
      plan.outcomes[#plan.outcomes + 1] = {
        step = plan.current_step, action = step.action, status = "failed", error = detail,
        code = step.action == "wait_for_research" and "RESEARCH_WAIT_TIMEOUT" or "ITEM_WAIT_TIMEOUT",
        result = step.action == "wait_for_research" and { code = "RESEARCH_WAIT_TIMEOUT",
          technology = step.technology, elapsed_ticks = game.tick - plan.wait_started_tick } or wait_timeout_result(step).outcome,
      }
      plan.current_task = nil
      plan.wait_started_tick, plan.next_check_tick = nil, nil
      -- This queued plan owns no physical state. Finalize only its record; an
      -- unrelated active action keeps the sole body and FIFO lane unchanged.
      finish(plan, "failed", detail, true)
    end
  end
end
-- Deterministic recoveries: at most one bounded physical fix per step, then
-- the same step runs again from scratch; a fix that fails returns the
-- step's original result. A place step whose body stands in its footprint
-- walks clear to up to MAX_EXITS different spots instead, the step running
-- again after each walk that arrives.
-- A place step still in its footprint walks to up to this many different
-- spots beside it (build_plan's bound), the step running again after each.
local MAX_EXITS = 3
-- Walks to a spot beside the placement footprint, clear for the body,
-- nearest first and not one already tried; false when none is left.
local function walk_clear(plan, recovery)
  if #recovery.exits >= MAX_EXITS then return false end
  local c, place = companion.get(), recovery.place
  local item = c and prototypes.item[place.item]
  local proto = item and item.place_result
  if not proto then return false end
  local ok, exit = pcall(build.footprint_exit, c, proto, place.position, place.direction, recovery.exits)
  if not ok or not exit then return false end
  recovery.exits[#recovery.exits + 1] = exit
  recovery.fix = { type = "walk_to", target = exit, arrival_mode = "exact", arrival_radius = 1, id = plan.id }
  return pcall(runners.walk_to.start, recovery.fix)
end
local function try_recover(plan, step, result)
  if result.status == "done" then return false end
  local prior = plan._recovery and plan._recovery.step == plan.current_step and plan._recovery or nil
  if prior then
    -- One fix per step, except a place step still in its footprint after
    -- walking clear: another spot beside it, up to MAX_EXITS in all.
    if not (prior.exits and result_code(result) == "CODEX_BODY_OVERLAP") or not walk_clear(plan, prior) then return false end
    prior.phase, prior.fix_error = "fixing", nil
    plan.current_task = prior.fix
    return true
  end
  local failed, code = plan.current_task, result_code(result)
  local recovery = { step = plan.current_step, code = code, first = result, started_tick = failed and failed.started_tick }
  if code == "BODY_ENCLOSED" then
    -- Take up the named own blocker, walk out toward where the step was
    -- going, put it back (move_entity's escape), then run the step again.
    -- A supply that already ran (or could not start) its own step-out has
    -- used this step's fix.
    if type(result.outcome) == "table" and type(result.outcome.step_out) == "table" then return false end
    local ok, path = pcall(function() return result.outcome.diagnostics.path end)
    local suggested = ok and type(path) == "table" and path.suggested_recovery or nil
    if type(suggested) ~= "table" or type(suggested.x) ~= "number" or type(suggested.y) ~= "number" then return false end
    local goal = path.resolved_goal or path.requested_goal or failed and (failed.target or failed.position)
    if type(goal) ~= "table" or type(goal.x) ~= "number" or type(goal.y) ~= "number" then return false end
    local at = { x = suggested.x, y = suggested.y }
    recovery.fix = { type = "move_entity", from = at, to = at, through = { x = goal.x, y = goal.y },
      expected_name = suggested.expected_name }
  elseif code == "CODEX_BODY_OVERLAP" and failed and failed.type == "place" then
    recovery.exits, recovery.place = {}, { item = failed.item, position = failed.position, direction = failed.direction }
    if not walk_clear(plan, recovery) then return false end
    recovery.phase = "fixing"
    plan._recovery = recovery
    plan.current_task = recovery.fix
    return true
  elseif code == "TARGET_OUT_OF_REACH" and failed and runners[failed.type] then
    recovery.resume_tick = game.tick
  elseif code == "PARTIAL_INSERT" and step.action == "insert_items" then
    local items
    for _, row in ipairs(result.outcome.transfers or {}) do
      if (tonumber(row.remainder) or 0) > 0 then items = items or {}; items[row.item] = row.remainder end
    end
    if not items then return false end
    -- The first attempt's transfers really happened.
    factory_activity.record("insert", result.outcome)
    recovery.items, recovery.resume_tick = items, game.tick + 60
  else
    return false
  end
  if recovery.fix then
    recovery.fix.id = plan.id
    if not pcall(runners[recovery.fix.type].start, recovery.fix) then return false end
  end
  recovery.phase = "fixing"
  plan._recovery = recovery
  plan.current_task = recovery.fix or { type = "recovery_pause" }
  return true
end
-- The retry of a partial insert's remainder ended: its result joins the
-- first attempt's, so the step reports what both inserted, against the
-- original request. An item still short keeps the retry's reason, except
-- that one the first attempt inserted some of was capped, not refused or
-- missing (TARGET_CAPACITY, INSUFFICIENT_CARRIED_ITEMS).
local CAPPED_REASON = { TARGET_REJECTED_ITEM = "TARGET_CAPACITY", NO_CARRIED_ITEMS = "INSUFFICIENT_CARRIED_ITEMS" }
local function merge_retry(first, retry)
  local before = type(first.outcome) == "table" and first.outcome or {}
  local after = type(retry.outcome) == "table" and retry.outcome or {}
  local again = {}
  for _, row in ipairs(type(after.transfers) == "table" and after.transfers or {}) do again[row.item] = row end
  local transfers, total, problems = {}, 0, {}
  for _, row in ipairs(type(before.transfers) == "table" and before.transfers or {}) do
    local second = again[row.item]
    local first_inserted = tonumber(row.inserted) or 0
    -- A retry that ended done inserted the whole remainder.
    local again_inserted = second and tonumber(second.inserted)
      or retry.status == "done" and (tonumber(row.remainder) or 0) or 0
    local inserted = first_inserted + again_inserted
    local requested = tonumber(row.requested) or inserted
    local remainder = math.max(0, requested - inserted)
    local reason
    if remainder > 0 then
      reason = second and second.reason or row.reason
      if first_inserted > 0 and CAPPED_REASON[reason] then reason = CAPPED_REASON[reason] end
      problems[#problems + 1] = string.format("requested %d %s, inserted %d, remainder %d (%s)", requested,
        tostring(row.item), inserted, remainder, tostring(reason))
    end
    total = total + inserted
    transfers[#transfers + 1] = { item = row.item, requested = requested, available = row.available,
      inserted = inserted, remainder = remainder, reason = reason }
  end
  local target = before.target or after.target
  local name = type(target) == "table" and target.name or "target"
  local outcome = { total_inserted = total, transfers = transfers, target = target, inventory = before.inventory,
    first_inserted = tonumber(before.total_inserted),
    retry = { status = retry.status, code = after.code, transfers = after.transfers } }
  if #problems == 0 then
    return { status = "done", outcome = outcome, detail = string.format(
      "inserted everything requested into the %s: %d at first, the rest on a retry", name, outcome.first_inserted or 0) }
  end
  outcome.code = "PARTIAL_INSERT"
  return { status = "partial", outcome = outcome, detail = string.format(
    "partial insert into the %s over two attempts — %s; the retry: %s", name, table.concat(problems, "; "),
    tostring(retry.detail)) }
end
local function step_recovery(plan)
  local recovery = plan._recovery
  local result
  if recovery.fix then
    local ok, value = pcall(runners[recovery.fix.type].tick, recovery.fix)
    result = ok and value or not ok and { status = "failed",
      detail = errors.record("task:" .. tostring(recovery.fix.type) .. ":recovery", value) } or nil
  elseif game.tick >= recovery.resume_tick then
    result = { status = "done" }
  end
  if not result then return true end
  plan.current_task = nil
  if result.status ~= "done" then
    recovery.fix_error = result.detail
    -- A walk clear of a footprint that failed: another spot may still work.
    if recovery.exits and walk_clear(plan, recovery) then
      plan.current_task = recovery.fix
      return true
    end
    recovery.phase = "failed"
    finish_step(plan, recovery.first)
    return true
  end
  recovery.phase, recovery.fix_detail, recovery.fix_error = "retrying", result.detail, nil
  return false
end
-- The status a plan's after_plan_id predecessor counts as: its own, or the
-- final status it handed this plan when it ended (finish keeps it on the
-- dependent, so pruning its record after RECORD_TTL loses nothing). A plan
-- that already started passed its predecessor check: it counts completed.
local function predecessor_status(plan)
  if plan.started_tick then return "completed" end
  if plan.predecessor_final then return plan.predecessor_final end
  local id = plan.after_plan_id
  local record = storage.tasks.records[id]
  if record and record.plan then return M.chain_status(record.plan) end
  if storage.tasks.active and storage.tasks.active.id == id then return storage.tasks.active.status end
  for _, queued in ipairs(storage.tasks.queue) do if queued.id == id then return queued.status end end
end
-- Upkeep beside pending work. The mod's upkeep (chores.lua) takes the body
-- while nothing queued would: with the FIFO empty, while it holds only
-- parked waits or plans whose predecessor is pending, and while the running
-- plan's step only waits on hand-crafting (a craft_items step). Such a plan
-- lends the body: it goes back to the queue head (still running, its step
-- kept) and only upkeep runs before it, and only while the crafting does.
-- Upkeep gives way at its next step boundary to work that takes the body,
-- and never moves what the lending craft makes or uses (upkeep_room).
local function crafting_busy()
  local c = companion.get()
  return c ~= nil and c.valid and (c.crafting_queue_size or 0) > 0
end
local function lends_body(plan)
  return plan.type == "plan" and plan.source ~= "upkeep" and plan.current_task ~= nil
    and plan.current_task.type == "craft" and crafting_busy()
end
local function upkeep_queued()
  for _, queued in ipairs(storage.tasks.queue) do
    if queued.type == "plan" and queued.source == "upkeep" then return true end
  end
  return false
end
-- A queued plan that would take the body now: not upkeep, not a parked wait
-- (but one due for its last read), not waiting on a pending predecessor.
local function takes_body(queued)
  if queued.source == "upkeep" then return false end
  if queued.status == "waiting" then return queued.next_check_tick == nil end
  return not queued.after_plan_id or predecessor_status(queued) == "completed"
end
-- Beside a travel wait. A travel step that waits for a rocket, an arrival or
-- the end of a ride holds the body, but a build package whose every step
-- acts on a space platform without the body (an extension's remote(step))
-- needs none: the travel plan lends the FIFO (lent = "travel", back at the
-- queue head, still running) and such packages run beside it, one at a
-- time, in queue order; the travel step takes the FIFO back when none is
-- left. Its arrival is an event it reads when it ticks again, and its
-- deadline is its own. Nothing else runs beside it, upkeep included.
local function remote_only(plan)
  if plan.type ~= "plan" or plan.completed_steps >= #plan.steps then return false end
  for index = plan.completed_steps + 1, #plan.steps do
    local step = plan.steps[index]
    local extension = extensions[step.action]
    if not (extension and extension.remote and extension.remote(step)) then return false end
  end
  return true
end
-- The queue index of the first package that may run beside a travel wait:
-- queued (not parked or lent), its predecessor done, every step remote.
local function beside_guest(queue)
  for index, queued in ipairs(queue) do
    if queued.type == "plan" and queued.status == "queued" and not queued.lent
      and type(queued.source) == "string" and queued.source:sub(1, 8) == "package:"
      and (not queued.after_plan_id or predecessor_status(queued.after_plan_id) == "completed")
      and remote_only(queued) then
      return index
    end
  end
end
-- Queued work that would take the body from upkeep now. Behind a lending
-- plan nothing else does: that plan takes it back once its crafting ends
-- (a travel wait holds the body throughout).
local function work_waiting()
  local queue = storage.tasks.queue
  if queue[1] and queue[1].lent then return queue[1].lent == "travel" or not crafting_busy() end
  for _, queued in ipairs(queue) do
    if queued.type == "plan" and takes_body(queued) then return true end
  end
  return false
end
-- The items a craft step's recipe makes or uses, as a set: the craft counts
-- its products as carried, so upkeep beside it must leave them alone.
local function craft_items(task)
  local items = {}
  local c = companion.get()
  local ok, recipe = pcall(function() return c.force.recipes[task.recipe] end)
  if not (ok and recipe) then return items end
  for _, key in ipairs({ "products", "ingredients" }) do
    local read_ok, list = pcall(function() return recipe[key] end)
    for _, row in ipairs(read_ok and list or {}) do
      if row.type == "item" then items[row.name] = true end
    end
  end
  return items
end
-- A craft lends the body only to a queued upkeep plan that moves none of
-- its items (one queued at a time: upkeep_room).
local function upkeep_spares(reserved)
  for _, queued in ipairs(storage.tasks.queue) do
    if queued.type == "plan" and queued.source == "upkeep" then
      for _, step in ipairs(queued.steps) do
        for name in pairs(step.action == "insert_items" and step.items or {}) do
          if reserved[name] then return false end
        end
      end
      return true
    end
  end
  return false
end
-- The items a plan step names, added to the set `items`: its items,
-- per_target and insert maps, its item, each entity's starter items, and
-- what a craft makes or uses.
local function step_items(step, items)
  local function add(map)
    for name, value in pairs(type(map) == "table" and map or {}) do
      local item = type(name) == "string" and name or type(value) == "table" and value.name
      if type(item) == "string" then items[item] = true end
    end
  end
  add(step.items); add(step.per_target); add(step.insert)
  if type(step.item) == "string" then items[step.item] = true end
  for _, entity in ipairs(type(step.entities) == "table" and step.entities or {}) do
    if type(entity) == "table" then add(entity.insert) end
  end
  if step.action == "craft_items" then add(craft_items(step)) end
end
-- Whether upkeep may queue a plan now: "idle" with the FIFO empty, "busy"
-- beside pending work as above, else nil; with it, the items upkeep must
-- spare: what a lending craft makes or uses (`true`: never moved) and what
-- parked wait_for_item steps count ("carried": only what the body carries,
-- so no holder the wait reads is emptied). Never while an upkeep plan is
-- pending, nor after an emergency stop before some plan has finished.
-- `boundary` asks for the plan-boundary pass (dispatch, nothing active): queued
-- work that takes the body does not refuse it, the room is "boundary", and
-- every item the plan about to start (the queue head) names is spared `true`.
function M.upkeep_room(boundary)
  local tasks = storage.tasks
  if not tasks or tasks.last_finished_tick == nil or upkeep_queued() then return nil end
  local active = tasks.active
  local reserved = {}
  if boundary and active then return nil end
  -- Queued work waits behind a running plan anyway.
  if active then
    if not lends_body(active) then return nil end
    reserved = craft_items(active.current_task)
  end
  for _, queued in ipairs(tasks.queue) do
    if not (active or boundary) and (queued.type ~= "plan" or queued.lent or takes_body(queued)) then return nil end
    local step = queued.type == "plan" and queued.status == "waiting" and queued.steps[queued.current_step]
    if step and step.action == "wait_for_item" and step.item then reserved[step.item] = reserved[step.item] or "carried" end
  end
  if boundary then
    local head = tasks.queue[1]
    for _, step in ipairs(head and head.type == "plan" and head.steps or {}) do step_items(step, reserved) end
    return "boundary", reserved
  end
  return (active or #tasks.queue > 0) and "busy" or "idle", reserved
end
-- An upkeep plan the plan-boundary pass queued: it runs to its end (it went
-- ahead of the plan that takes the body next), walk back included.
local function boundary_plan(plan)
  return plan.upkeep_selection ~= nil and plan.upkeep_selection.room == "boundary"
end
local function tick_plan(plan)
  local budget = math.max(PLAN_BUDGET_TICKS, (plan.budget_steps or #plan.steps) * STEP_BUDGET_TICKS)
  if game.tick - plan.started_tick >= budget then
    local detail = string.format("PLAN_BUDGET_EXCEEDED: plan exceeded its %d-second active budget", budget / 60)
    -- Queued hand-crafts are not cancelled (finish cancels them only for a
    -- cancelled plan): they keep running.
    local crafting = crafting_summary()
    if crafting then
      detail = detail .. string.format("; hand-crafting continues: %g s queued", crafting.queue_s)
    end
    if plan.current_task then
      local supplying = supply_state(plan.current_task)
      local note = step_cancelled(plan)
      if plan._recovery and plan._recovery.phase == "fixing" then plan._recovery.phase = "failed" end
      -- The budget ended the plan: its code, not the cancelled step's note's.
      finish_step(plan, { status = "failed", detail = detail,
        outcome = { code = "PLAN_BUDGET_EXCEEDED", cancelled = note, supply = supplying, crafting = crafting } })
    else finish(plan, "failed", detail) end
    return
  end
  if plan._recovery and plan._recovery.phase == "fixing" and step_recovery(plan) then return end
  if not plan.current_task then
    -- The mod's own upkeep gives way at a step boundary to queued work that
    -- would take the body now (not a parked wait or a blocked plan), after
    -- its walk back when it has one.
    if plan.source == "upkeep" and plan.completed_steps > 0 and not plan.ending and not boundary_plan(plan)
      and plan.completed_steps + 1 ~= return_step(plan) and work_waiting() then
      plan.preempted = true
      local detail = "PREEMPTED: queued work takes the body"
      if not walk_back(plan, "cancelled", detail) then finish(plan, "cancelled", detail); return end
    end
    plan.current_step = plan.ending and return_step(plan) or plan.completed_steps + 1
    local step = plan.steps[plan.current_step]
    if REMOVED_ACTIONS[step.action] then
      -- A step saved by an older version ends without running.
      plan.wait_started_tick, plan.next_check_tick = nil, nil
      finish_step(plan, removed_result(step.action))
      return
    end
    -- A positional step never starts on another surface than its own (a body
    -- with no surface at all fails in the step, naming its state).
    local tag, here = step_surface(plan, plan.current_step), body_surface()
    if tag and here and tag ~= here then
      finish_step(plan, { status = "failed",
        detail = string.format("SURFACE_MISMATCH: step %d (%s) acts on %s but the body is on %s", plan.current_step,
          step.action, tag, here), outcome = { code = "SURFACE_MISMATCH", expected = tag, actual = here } })
      return
    end
    plan.current_task = (PARKED_ACTIONS[step.action] or step.action == "inspect_entities")
      and { type = step.action } or make_step_task(step)
    local recovery = plan._recovery
    if recovery and recovery.step == plan.current_step and recovery.items then plan.current_task.items = recovery.items end
    if not PARKED_ACTIONS[step.action] and step.action ~= "inspect_entities" then
      -- Async action events are delivered to the one active queue entry. Give
      -- the nested runner its owning plan ID so it uses that same mailbox.
      plan.current_task.id = plan.id
      plan.current_task.started_tick = recovery and recovery.step == plan.current_step and recovery.started_tick
        or game.tick
      local ok, err = pcall(runners[plan.current_task.type].start, plan.current_task)
      if not ok then finish_step(plan, { status = "failed", detail = caught("task:" .. tostring(plan.current_task.type) .. ":start", err) }); return end
    end
  end
  local step, ok, result = plan.steps[plan.current_step]
  if step.action == "wait_for_item" then ok, result = pcall(wait_for_item, plan, step)
  elseif step.action == "wait_for_research" then ok, result = pcall(wait_for_research, plan, step)
  elseif REMOVED_ACTIONS[step.action] then
    ok, result = true, removed_result(step.action)
    plan.wait_started_tick, plan.next_check_tick = nil, nil
  elseif step.action == "inspect_entities" then
    ok, result = pcall(function()
      -- At most INSPECT_PER_TICK positions a tick; the read's state is kept
      -- on the step's task (a step begun by 0.21.1 starts it here).
      local task = plan.current_task
      task._inspect = task._inspect or inspect.job.start({ targets = step.positions })
      local response = inspect.job.step(task._inspect, { left = INSPECT_PER_TICK * inspect.PER_TARGET })
      if not response then return nil end
      task._inspect = nil
      local errors, remote = 0, 0
      for _, entity in ipairs(response.entities or {}) do
        if entity.error then errors = errors + 1 elseif entity.remote then remote = remote + 1 end
      end
      -- The read names its own evidence class and scope, which differ once
      -- any entity lies beyond the body's 30 tiles.
      local beyond = remote > 0 or (response.scope ~= nil and response.scope ~= "within_30_tiles_of_codex_at_source_tick")
      return {
        status = errors > 0 and "partial" or "done",
        detail = string.format("inspected %d/%d entities%s at tick %d", #step.positions - errors, #step.positions,
          beyond and string.format(" (%d remote, beyond 30 tiles of Codex)", remote) or " locally", response.tick),
        outcome = { tick = response.tick, entities = response.entities, omitted_entities = errors,
          evidence_class = response.evidence_class,
          scope = beyond and (response.scope or "within_30_tiles_or_own_force_charted_at_source_tick")
            or "within_30_tiles_after_prior_physical_steps" },
      }
    end)
  else ok, result = pcall(runners[plan.current_task.type].tick, plan.current_task) end
  if ok and PARKED_ACTIONS[step.action] and result == nil then
    -- A read-only condition must not occupy the physical body while an
    -- independent action is ready. Park this plan at the tail of the same FIFO;
    -- its elapsed timeout and current step remain intact.
    set_plan_status(plan, "waiting")
    storage.tasks.active = nil
    storage.tasks.queue[#storage.tasks.queue + 1] = plan
    stop_body()
    return
  end
  if ok and result == nil and lends_body(plan) and upkeep_spares(craft_items(plan.current_task)) then
    plan.lent = true
    storage.tasks.active = nil
    table.insert(storage.tasks.queue, 1, plan)
    return
  end
  -- A travel step that waits (for a rocket, an arrival or the end of a
  -- ride) lends the FIFO to a queued platform-only package (beside_guest).
  if ok and result == nil and step.action == "travel" and travel.action.runner.waiting(plan.current_task)
    and beside_guest(storage.tasks.queue) then
    plan.lent = "travel"
    storage.tasks.active = nil
    table.insert(storage.tasks.queue, 1, plan)
    return
  end
  if not ok then result = { status = "failed", detail = caught("task:" .. tostring(step.action) .. ":tick", result) } end
  -- A partial insert's retry: the step reports both attempts' transfers.
  local recovery = plan._recovery
  if result and recovery and recovery.step == plan.current_step and recovery.items and recovery.phase == "retrying"
    and not recovery.merged then
    recovery.merged = true
    result = merge_retry(recovery.first, result)
  end
  if result and not try_recover(plan, step, result) then finish_step(plan, result) end
end
-- The work sites, newest first, at most WORK_SITES: a start within
-- WORK_SITE_RADIUS (upkeep's radius) of a kept site on its surface moves
-- that site to the front instead, so work at one outpost never pushes the
-- base out of the list.
local WORK_SITES = 4
local WORK_SITE_RADIUS = 96
local function note_work_site(tasks, c)
  local x, y = c.position.x, c.position.y
  local sites, near = {}, nil
  for _, site in ipairs(tasks.work_sites or {}) do
    local dx, dy = site.x - x, site.y - y
    if not near and site.surface_index == c.surface_index and dx * dx + dy * dy <= WORK_SITE_RADIUS * WORK_SITE_RADIUS then
      near = site
    else sites[#sites + 1] = site end
  end
  table.insert(sites, 1, near or { surface_index = c.surface_index, x = x, y = y })
  sites[WORK_SITES + 1] = nil
  tasks.work_sites = sites
end
local function dispatch(tasks)
  local task = tasks.active
  if not task then
    if #tasks.queue == 0 then return end
    local head = tasks.queue[1]
    -- A plan lending the body keeps its place: only upkeep goes first; a
    -- travel wait lends the FIFO only to a platform-only package.
    local guest
    if head.lent == "travel" then
      guest = beside_guest(tasks.queue)
    elseif head.lent and crafting_busy() then
      for index, queued in ipairs(tasks.queue) do
        if queued.type == "plan" and queued.source == "upkeep" then guest = index; break end
      end
    end
    local beside = head.lent == "travel" and guest ~= nil
    if head.lent then task = table.remove(tasks.queue, guest or 1) end
    local attempts = task and 0 or #tasks.queue
    for _ = 1, attempts do
      local candidate = table.remove(tasks.queue, 1)
      local parked = candidate.type == "plan" and candidate.status == "waiting"
        and candidate.next_check_tick and game.tick < candidate.next_check_tick
      local predecessor_blocked = false
      if candidate.type == "plan" and candidate.after_plan_id then
        local status = predecessor_status(candidate)
        if status ~= "completed" then
          if status == "queued" or status == "running" or status == "waiting" then
            predecessor_blocked = true
          else
            finish(candidate, "cancelled", string.format("predecessor plan %d did not complete successfully (%s)",
              candidate.after_plan_id, status and ("it ended " .. status) or "no record of it is left"), true)
          end
        end
      end
      -- A candidate the predecessor check just cancelled leaves the queue,
      -- even while it is parked.
      if candidate.status == "cancelled" then -- dropped
      elseif parked or predecessor_blocked then tasks.queue[#tasks.queue + 1] = candidate
      else task = candidate; break end
    end
    if not task then return end
    -- The plan-boundary upkeep pass: before a pilot or package plan starts,
    -- chores.lua may queue one upkeep plan (at the tail), which runs first;
    -- back-to-back plans never starve a long-dry burner. Not beside a
    -- travel wait, which holds the body.
    if boundary_upkeep and not beside and task.type == "plan" and task.source ~= "upkeep" and task.status == "queued" then
      table.insert(tasks.queue, 1, task)
      local ok, id = pcall(boundary_upkeep, game.tick)
      if not ok then errors.record("task:boundary_upkeep", id) end
      local tail = tasks.queue[#tasks.queue]
      task = table.remove(tasks.queue, ok and id and tail.id == id and #tasks.queue or 1)
    end
    task.lent = nil
    -- Where the body stands as a pilot or package plan begins: idle upkeep
    -- also serves machines near these work sites (chores.lua).
    if task.type == "plan" and task.source ~= "upkeep" and not task.started_tick and not beside then
      local c = companion.get()
      if c and c.valid then note_work_site(tasks, c) end
    end
    if task.type == "plan" then set_plan_status(task, "running") else task.status = "running" end
    task.started_tick, tasks.active = task.started_tick or game.tick, task
    if task.type == "plan" and task.start_inventory == nil then task.start_inventory = inventory_snapshot() end
    if task.type ~= "plan" then local ok, err = pcall(runners[task.type].start, task); if not ok then finish(task, "failed", caught("task:" .. task.type .. ":start", err)); return end end
  end
  if task.type == "plan" then tick_plan(task); return end
  local ok, result = pcall(runners[task.type].tick, task)
  if not ok then finish(task, "failed", caught("task:" .. task.type .. ":tick", result)) elseif result then
    factory_activity.record(task.type, result.outcome)
    if TOPOLOGY_TASKS[task.type] then autonomy.mark_dirty() end
    -- No game event names the mod's own rotation.
    if task.type == "rotate" and result.status == "done" and type(task.target) == "table" then
      journal_step(nil, { action = "rotate_entity", x = task.target.x, y = task.target.y })
    end
    finish(task, result.status, result.detail, nil, result.outcome)
  end
end
-- The step watchdog. No single step may hold the FIFO for minutes: a running
-- plan step or direct task fails with STEP_STALLED once the body's position,
-- its inventory, its hand-crafting and mining, and the step's own progress
-- have all stood still for STALL_TICKS. Deliberate waits are exempt:
-- wait_for_item and wait_for_research park the plan (it is not running), a
-- crafting queue that advances is progress while the step waits on it, and a
-- human hold stops the watchdog and restarts its clock. Background crafts are
-- not the progress of a step that waits on something else: for it the
-- crafting queue and the carried counts of what that queue made during the
-- step are left out. Its state (storage.tasks.stall) is made when first
-- needed, so a save from before it needs no migration.
local NESTED_STEPS = { "_plan", "_layout", "_supply", "_sub", "_clear", "_exit", "_launch" }
-- What a step shows of its own progress, read from its plain task state: the
-- phase names go to the failure, the scalars to the progress signature. A
-- walker's state is left out: a walk that re-plans without the body getting
-- anywhere is exactly what the watchdog must see as standing still.
local function describe_step(task, phases, progress, depth)
  if type(task) ~= "table" or depth > 6 then return end
  local keys = {}
  for key, value in pairs(task) do
    local kind = type(value)
    if type(key) == "string" and key:sub(1, 1) == "_" and not key:find("poll", 1, true)
      and (kind == "number" or kind == "string" or kind == "boolean") then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do progress[#progress + 1] = key .. "=" .. tostring(task[key]) end
  if task._search then phases[#phases + 1] = "site_search" end
  local frame = type(task._stack) == "table" and task._stack[#task._stack]
  if type(frame) == "table" then
    phases[#phases + 1] = string.format("supply %s:%s", tostring(frame.name), tostring(frame.phase))
    local smelt = type(frame.smelt) == "table" and frame.smelt or {}
    progress[#progress + 1] = string.format("stack=%d:%s:%s:%s:%s:%s:%s", #task._stack, tostring(frame.name),
      tostring(frame.phase), tostring(frame.takes), tostring(frame.gathers), tostring(smelt.left), tostring(smelt.made))
  end
  if task._mining_started then phases[#phases + 1] = "mining" end
  local walker = type(task._approach) == "table" and task._approach.walk or task._walk
  if type(walker) == "table" then
    phases[#phases + 1] = (task._walk and "walk:" or "approach:") .. tostring(walker.phase)
  end
  for _, field in ipairs(NESTED_STEPS) do
    local nested = task[field]
    if type(nested) == "table" then
      phases[#phases + 1] = field:sub(2) .. (type(nested.type) == "string" and ("(" .. nested.type .. ")") or "")
      describe_step(nested, phases, progress, depth + 1)
    end
  end
end
-- `crafted`, for a step that does not wait on crafting: the set of items the
-- crafting queue made during the step, grown here from every queue entry
-- (prerequisites too); their counts and the queue itself are left out.
local function body_signature(c, progress, crafted)
  local parts = {}
  if crafted then
    for _, entry in ipairs(c.crafting_queue or {}) do
      local recipe = type(entry.recipe) == "string" and c.force.recipes[entry.recipe]
      for _, product in ipairs(recipe and recipe.products or {}) do
        if product.type == "item" then crafted[product.name] = true end
      end
    end
  end
  for _, item in ipairs(c.get_main_inventory and c.get_main_inventory() and c.get_main_inventory().get_contents() or {}) do
    if not (crafted and crafted[item.name]) then
      parts[#parts + 1] = tostring(item.name) .. ":" .. tostring(item.quality or "") .. "=" .. tostring(item.count)
    end
  end
  table.sort(parts)
  local members = crafted and { "character_mining_progress" }
    or { "crafting_queue_size", "crafting_queue_progress", "character_mining_progress" }
  for _, member in ipairs(members) do
    local ok, value = pcall(function() return c[member] end)
    parts[#parts + 1] = member .. "=" .. tostring(ok and value or nil)
  end
  for _, row in ipairs(progress) do parts[#parts + 1] = row end
  return table.concat(parts, ";")
end
-- True when it failed the active step this tick.
local function watchdog(tasks)
  local task = tasks.active
  local plan = task.type == "plan" and task or nil
  local step = plan and plan.current_step or 0
  local stall = tasks.stall
  if not stall or stall.id ~= task.id or stall.step ~= step then
    stall = { id = task.id, step = step, next_check = game.tick }
    tasks.stall = stall
  end
  if game.tick < stall.next_check then return false end
  stall.next_check = game.tick + STALL_SAMPLE_TICKS
  local c = companion.get()
  local current = plan and plan.current_task or not plan and task or nil
  if not (c and c.valid and current) then tasks.stall = nil; return false end
  -- A deliberate wait (a travel step waiting for a rocket or an arrival).
  local runner = runners[current.type]
  if runner and runner.waiting and runner.waiting(current) then tasks.stall = nil; return false end
  local phases, progress = {}, { "outcomes=" .. (plan and #plan.outcomes or 0) }
  describe_step(current, phases, progress, 0)
  -- A step that waited on the crafting queue since the last sample (craft.lua
  -- marks it) counts the queue as progress.
  local crafted
  local craft_wait = storage.craft_wait_tick
  if not (craft_wait and game.tick - craft_wait <= STALL_SAMPLE_TICKS) then
    stall.crafted = stall.crafted or {}
    crafted = stall.crafted
  end
  local ok, signature = pcall(body_signature, c, progress, crafted)
  if not ok then tasks.stall = nil; return false end
  local p = c.position
  local function beyond(anchor)
    return not anchor or (p.x - anchor.x) ^ 2 + (p.y - anchor.y) ^ 2 > STALL_MOVE_SQ
  end
  local moved = beyond(stall.anchor) and beyond(stall.previous)
  if beyond(stall.anchor) then stall.previous, stall.anchor = stall.anchor, { x = p.x, y = p.y } end
  if moved or signature ~= stall.signature or not stall.since then
    stall.since, stall.signature = game.tick, signature
    stall.deadline = game.tick + STALL_TICKS -- walk.lua ends its diagnosis before it
    return false
  end
  if game.tick - stall.since < STALL_TICKS then return false end
  tasks.stall = nil
  local action = plan and plan.steps[step] and plan.steps[step].action or task.type
  local phase = #phases > 0 and table.concat(phases, " > ") or "running"
  local stalled = game.tick - stall.since
  local detail = string.format("STEP_STALLED: %s made no progress for %d seconds in phase %s: the body stayed at (%.1f, %.1f) with"
    .. " its inventory, crafting and step state unchanged; re-read the body position and choose a reachable target",
    tostring(action), math.floor(stalled / 60), phase, p.x, p.y)
  local outcome = { code = "STEP_STALLED", action = action, phase = phase, stalled_ticks = stalled,
    position = { x = p.x, y = p.y } }
  -- A step-out stalled mid way: the taken-up entity goes back or is named.
  local note = task_cancelled(current, true)
  if type(note) == "table" then
    outcome.cancelled = note
    if type(note.detail) == "string" then detail = detail .. "; " .. note.detail end
  end
  -- A stalled recovery fix is over: it must not tick again once its entity
  -- is back (a walk back after this step would otherwise rerun it).
  if plan and plan._recovery and plan._recovery.phase == "fixing" then plan._recovery.phase = "failed" end
  storage.path_request, task._path_result = nil, nil
  if plan then finish_step(plan, { status = "failed", detail = detail, outcome = outcome })
  else finish(task, "failed", detail, nil, outcome) end
  return true
end
-- Human takeover. While the player's input holds the body the dispatcher is parked:
-- no step starts or ticks, nothing is cancelled or reordered, and the mod
-- writes no walking, mining or picking state after one release on entry, so
-- they can move freely. Hold ticks are not charged to any deadline.
local function mark_held(task)
  if task and task.type == "plan" then task.human_control = true end
end
-- Each hold is an episode in storage.tasks.holds (state.lua): count, every
-- one begun; total_ticks, those that ended; recent, the last HOLD_EPISODES
-- {start_tick, end_tick (nil while open), cause}, oldest first.
local HOLD_EPISODES = 16
local function enter_hold(tasks, cause)
  tasks.human_hold = { since = game.tick }
  local holds = tasks.holds
  if holds then
    holds.count = holds.count + 1
    holds.recent[#holds.recent + 1] = { start_tick = game.tick, cause = cause }
    while #holds.recent > HOLD_EPISODES do table.remove(holds.recent, 1) end
  end
  tasks.stall = nil
  if tasks.active then stop_body() end
  mark_held(tasks.active)
  for _, queued in ipairs(tasks.queue) do mark_held(queued) end
end
-- The body may stand anywhere after a hold. The interrupted step keeps its
-- place and re-plans from the current position: its approach and any pending
-- path request are dropped, and a runner with body-bound progress resets it.
-- The hold is charged neither to a started plan's active budget nor to a
-- parked wait's timeout, whose condition nothing evaluated meanwhile.
local function release_plan(plan, held_ticks)
  if plan.started_tick then plan.started_tick = plan.started_tick + held_ticks end
  local step = plan.type == "plan" and plan.current_task and plan.steps[plan.current_step] or nil
  if not step then return end
  if plan.wait_started_tick then plan.wait_started_tick = plan.wait_started_tick + held_ticks end
  if step._wait_started_tick then step._wait_started_tick = step._wait_started_tick + held_ticks end
  -- A running step's own deadline (a travel phase's).
  local current = plan.current_task
  if current._deadline_tick then current._deadline_tick = current._deadline_tick + held_ticks end
  -- A hold is the player's time, never a line's hand service.
  if current.started_tick then current.started_tick = current.started_tick + held_ticks end
  local recovery = plan._recovery
  if recovery and recovery.started_tick then recovery.started_tick = recovery.started_tick + held_ticks end
end
-- The active step re-plans from where the body stands (after a hold, and
-- after a load whose state.init dropped the pending path request).
local function resume_active(tasks)
  local task = tasks.active
  if not task then return end
  storage.path_request, task._path_result = nil, nil
  local current = task.type == "plan" and task.current_task or task
  if not current then return end
  current._approach, current._approach_close, current._approach_guard = nil, nil, nil
  local runner = runners[current.type]
  if runner and runner.resume then
    local ok, err = pcall(runner.resume, current)
    if not ok then
      local result = { status = "failed", detail = caught("task:" .. tostring(current.type) .. ":resume", err) }
      if task.type == "plan" then finish_step(task, result) else finish(task, "failed", result.detail) end
    end
  end
end
local function leave_hold(tasks)
  local held_ticks = game.tick - tasks.human_hold.since
  tasks.human_hold = nil
  local open = tasks.holds and tasks.holds.recent[#tasks.holds.recent]
  if open and open.end_tick == nil then
    open.end_tick, tasks.holds.total_ticks = game.tick, tasks.holds.total_ticks + held_ticks
  end
  for _, queued in ipairs(tasks.queue) do release_plan(queued, held_ticks) end
  if tasks.active then release_plan(tasks.active, held_ticks) end
  resume_active(tasks)
end
-- After state.init (a load with a configuration change). A held body resumes
-- when the hold ends.
function M.resume_active()
  if storage.tasks.human_hold then return end
  resume_active(storage.tasks)
end
-- The one cancel rule (multi-surface rule 4). The body's surface changed
-- (event-driven: companion.note_body_surface); the dispatcher applies it at
-- its next run, never during a hold. Every queued or active plan whose next
-- unfinished positional step is tagged with another surface is cancelled
-- with SURFACE_LEFT and leaves the FIFO; it never parks. A plan that still
-- holds a travel step, and a plan for the destination of a travel step
-- pending ahead of it in the FIFO, are exempt. Hand-crafting is never
-- cancelled.
function M.on_body_surface_changed(change)
  storage.tasks.surface_changed = change or true
end
local function cancel_off_surface(plan, tag, here, queued)
  local index = plan.current_task and plan.current_step or plan.completed_steps + 1
  local step = plan.steps[index] or {}
  local detail = string.format("SURFACE_LEFT: the body is on %s; step %d (%s) acts on %s", here, index,
    tostring(step.action), tag)
  local note = step_cancelled(plan)
  plan.outcomes[#plan.outcomes + 1] = { step = index, action = step.action, status = "cancelled", error = detail,
    result = { code = "SURFACE_LEFT", expected = tag, actual = here, relocation = note } }
  plan.current_task, plan._recovery = nil, nil
  if not queued then storage.path_request, plan._path_result = nil, nil end
  finish(plan, "cancelled", detail, queued, nil, true)
end
local function surface_left(tasks)
  tasks.surface_changed = nil
  local here = body_surface()
  if not here then return end
  -- FIFO order: the active plan, then the queue; `ahead` holds the travel
  -- destinations pending before the plan looked at.
  local ahead = {}
  local function stale(plan)
    if plan.type ~= "plan" then return nil end
    local travels = pending_travel(plan, {})
    if #travels > 0 then
      for _, destination in ipairs(travels) do ahead[destination] = true end
      return nil
    end
    local tag = next_surface(plan)
    if tag and tag ~= here and not ahead[tag] then return tag end
  end
  local active = tasks.active
  local tag = active and stale(active)
  if tag then cancel_off_surface(active, tag, here, false) end
  local kept = {}
  for _, plan in ipairs(tasks.queue) do
    tag = stale(plan)
    if tag then cancel_off_surface(plan, tag, here, true) else kept[#kept + 1] = plan end
  end
  tasks.queue = kept
end
-- A dead body pauses the dispatcher until it respawns: no step ticks or
-- starts (each would fail for want of a body), and the plans resume after
-- the respawn rebinds the character. The pause is charged to no deadline,
-- like a hold, but it is no hold: human_control stays false.
local function body_dead()
  local ok, dead = pcall(companion.is_dead)
  return ok and dead == true
end
local function leave_death(tasks)
  local paused = game.tick - tasks.dead_since
  tasks.dead_since = nil
  for _, queued in ipairs(tasks.queue) do release_plan(queued, paused) end
  if tasks.active then release_plan(tasks.active, paused) end
  resume_active(tasks)
end
for _, name in ipairs({ "on_robot_pre_mined", "on_robot_mined_entity", "on_robot_built_entity" }) do
  M[name] = function(event)
    local plan = storage.tasks and storage.tasks.active
    local task = plan and plan.current_task
    local runner = task and runners[task.type]
    if runner and runner[name] then runner[name](task, event) end
  end
end
-- Body time (run telemetry): what the body did, tick by tick, as one state:
-- a task of a source (pilot for pilot plans and direct tools, package,
-- upkeep), a travel step waiting for a rocket, the platform's arrival or
-- its ride (traveling), hand-crafting with no task, a human hold, a dead
-- body with work waiting, or idle. storage.tasks.body_time (state.lua) keeps the ticks per
-- state and the idle gaps, keyed by the state that ended them. The state
-- is read once as each tick begins (a plan dispatched in tick t counts from
-- t + 1) and written only when it changes; run_snapshot reads it. A gap
-- open at the recorder's window mark (mark_body_window) counts from the
-- mark, so the gaps closed after a run's baseline hold only its own time.
-- A travel step's waiting phases (actions/travel.lua): the body is carried
-- or waits for its ride, doing no work of its own.
local TRAVEL_WAITS = { board_wait = true, wait_arrival = true, ride = true }
local function body_state(tasks)
  if tasks.human_hold then return "hold" end
  if tasks.dead_since then return "dead" end
  local active = tasks.active
  if active then
    local current = active.type == "plan" and active.current_task
    if current and current.type == "travel" and TRAVEL_WAITS[current._phase] then return "traveling" end
    local source = active.type == "plan" and active.source or "pilot"
    if source == "upkeep" then return "upkeep" end
    return source:sub(1, 8) == "package:" and "package" or "pilot"
  end
  local rec = storage.companion
  local character = rec and rec.entity
  if character and character.valid and (character.crafting_queue_size or 0) > 0 then return "crafting" end
  -- waiting: a pilot or package plan is queued but none can take the body
  -- now (parked waits, plans behind a pending predecessor). Work the
  -- dispatcher starts this tick leaves the state idle, so the idle gap is
  -- still keyed by that work.
  local waiting = false
  for _, queued in ipairs(tasks.queue) do
    if queued.type ~= "plan" or queued.source == "upkeep" or takes_body(queued) then return "idle" end
    waiting = true
  end
  return waiting and "waiting" or "idle"
end
local function account_body_time(tasks)
  local time = tasks.body_time
  if not time then return end
  local state = body_state(tasks)
  if state == time.state then return end
  local span = game.tick - time.state_since
  time.ticks[time.state] = (time.ticks[time.state] or 0) + span
  if time.state == "idle" then
    local gap = time.gaps[state] or { count = 0, ticks = 0, longest = 0 }
    time.gaps[state] = gap
    span = game.tick - math.max(time.state_since, time.window_tick or 0)
    gap.count, gap.ticks = gap.count + 1, gap.ticks + span
    if span >= gap.longest then gap.longest, gap.longest_end_tick = span, game.tick end
  end
  time.state, time.state_since = state, game.tick
end
-- Body phases: each tick a task holds the body (body_state pilot, package
-- or upkeep, or a travel wait) is one phase. An upkeep tick is upkeep and a
-- tick with the body aboard a platform or in a cargo pod is aboard; any
-- other is checked in this order: walk (the body moved since the last tick;
-- the distance adds to tiles), mine (the character is mining), smelt_wait
-- (the step's supply waits on a furnace), craft_wait (a step waited on the
-- crafting queue within the last poll) or other. The running plan keeps its
-- own walk ticks, tiles and craft_wait ticks (walk_s, tiles, craft_wait_s).
-- O(1) reads of the body and the running task; nothing on the surface.
-- A move longer than MAX_STEP_TILES in one tick (a landing, a respawn) is no walk.
local MAX_STEP_TILES, CRAFT_WAIT_TICKS = 2, 30
local PHASED_STATES = { pilot = true, package = true, upkeep = true, traveling = true }
local AWAY_STATES = { aboard_platform = true, in_transit = true }
local function supply_frame(task)
  local stack = type(task._stack) == "table" and task._stack
    or type(task._supply) == "table" and type(task._supply._stack) == "table" and task._supply._stack or nil
  return stack and stack[#stack]
end
local function account_phase(tasks)
  local time = tasks.body_time
  if not (time and time.phases) then return end
  if not PHASED_STATES[time.state] then time.last_position = nil; return end
  local c = companion.get()
  if not (c and c.valid) then
    time.last_position = nil
    -- Aboard or in a pod there is no character on a surface: the tick is
    -- the trip's.
    local ok, body = pcall(companion.body)
    if ok and AWAY_STATES[body.state] then time.phases.aboard = (time.phases.aboard or 0) + 1 end
    return
  end
  local p, last = c.position, time.last_position
  local surface = c.surface_index
  local moved = 0
  if last and last.surface == surface then
    moved = math.sqrt((p.x - last.x) ^ 2 + (p.y - last.y) ^ 2)
    if moved > MAX_STEP_TILES then moved = 0 end
  end
  if last then last.x, last.y, last.surface = p.x, p.y, surface
  else time.last_position = { x = p.x, y = p.y, surface = surface } end
  local active = tasks.active
  local current = active and (active.type == "plan" and active.current_task or active.type ~= "plan" and active) or nil
  local mining = c.mining_state
  local frame = current and supply_frame(current)
  local craft_wait = storage.craft_wait_tick
  local phase = "other"
  if moved > 0 then
    phase = "walk"
  elseif type(mining) == "table" and mining.mining then
    phase = "mine"
  elseif frame and frame.phase == "smelt_wait" then
    phase = "smelt_wait"
  elseif (c.crafting_queue_size or 0) > 0 and craft_wait and game.tick - craft_wait <= CRAFT_WAIT_TICKS then
    phase = "craft_wait"
  end
  local plan = active and active.type == "plan" and active or nil
  if plan and phase == "walk" then
    plan.walk_ticks, plan.tiles = (plan.walk_ticks or 0) + 1, (plan.tiles or 0) + moved
  elseif plan and phase == "craft_wait" then
    plan.craft_wait_ticks = (plan.craft_wait_ticks or 0) + 1
  end
  if time.state == "upkeep" then phase = "upkeep"
  elseif phase == "walk" then time.tiles = (time.tiles or 0) + moved end
  time.phases[phase] = (time.phases[phase] or 0) + 1
end
-- The run recorder's baseline (run_snapshot {window = true}) marks its
-- window start: the idle gap open now counts from here when it closes.
function M.mark_body_window()
  local time = storage.tasks and storage.tasks.body_time
  if time then time.window_tick = game.tick end
end
-- {since_tick, window_tick?, state, state_since, ticks = {[state] = n},
-- gaps = {[ended_by] = {count, ticks, longest, longest_end_tick}},
-- phases = {[phase] = n}, tiles}, cumulative since since_tick with the
-- current state's open interval included (phases and tiles: the pilot,
-- package and upkeep ticks by body phase (account_phase) and the tiles the
-- pilot and package walked, rounded to a tenth); nil before state.init made
-- it.
function M.body_time()
  local time = storage.tasks and storage.tasks.body_time
  if not time then return nil end
  local ticks, gaps = {}, {}
  for state, n in pairs(time.ticks) do ticks[state] = n end
  ticks[time.state] = (ticks[time.state] or 0) + game.tick - time.state_since
  for state, gap in pairs(time.gaps) do
    gaps[state] = { count = gap.count, ticks = gap.ticks, longest = gap.longest, longest_end_tick = gap.longest_end_tick }
  end
  local phases
  if time.phases then
    phases = {}
    for phase, n in pairs(time.phases) do phases[phase] = n end
  end
  return { since_tick = time.since_tick, window_tick = time.window_tick, state = time.state, state_since = time.state_since,
    ticks = ticks, gaps = gaps, phases = phases, tiles = time.phases and math.floor((time.tiles or 0) * 10 + 0.5) / 10 or nil }
end
-- The hold episodes for run_snapshot: {count, total_ticks (an open hold's
-- ticks so far included), recent}, a copy; nil before state.init made them.
function M.holds()
  local holds = storage.tasks and storage.tasks.holds
  if not holds then return nil end
  local recent, total = {}, holds.total_ticks
  for i, episode in ipairs(holds.recent) do
    recent[i] = { start_tick = episode.start_tick, end_tick = episode.end_tick, cause = episode.cause }
  end
  local open = recent[#recent]
  if storage.tasks.human_hold and open and open.end_tick == nil then total = total + game.tick - open.start_tick end
  return { count = holds.count, total_ticks = total, recent = recent }
end
function M.on_tick()
  if game.tick % PRUNE_INTERVAL_TICKS == 0 then
    for id, record in pairs(storage.tasks.records) do
      local ttl = (record.status == "failed" or record.status == "partial") and FAILED_RECORD_TTL_TICKS or RECORD_TTL_TICKS
      if game.tick - record.finished_tick > ttl then storage.tasks.records[id] = nil end
    end
  end
  local tasks = storage.tasks
  account_body_time(tasks)
  account_phase(tasks)
  local current = tasks.active and tasks.active.current_task
  local runner = current and runners[current.type]
  -- Pure bounded cargo observation continues through holds; native robots
  -- keep working while the body is parked. This never orders any action.
  if runner and runner.observe then runner.observe(current) end
  pcall(companion.poll_human_activity, tasks.human_hold ~= nil)
  local held, _, cause = human_control()
  if held then
    if not tasks.human_hold then enter_hold(tasks, cause) end
    -- A human playing the body is not idle time.
    if tasks.last_finished_tick then tasks.last_finished_tick = game.tick end
    if tasks.last_pilot_finished_tick then tasks.last_pilot_finished_tick = game.tick end
    return
  end
  if tasks.human_hold then leave_hold(tasks) end
  if tasks.active or #tasks.queue > 0 or tasks.dead_since then
    if body_dead() then
      if not tasks.dead_since then tasks.dead_since, tasks.stall = game.tick, nil end
      return
    end
    if tasks.dead_since then leave_death(tasks) end
  end
  if tasks.surface_changed then surface_left(tasks) end
  expire_parked_waits(storage.tasks)
  -- Hand-crafting is body work: idle time starts when it ends, not when the
  -- asynchronous craft task that queued it finished.
  local body = storage.tasks.last_finished_tick and companion.get()
  if body and body.valid and (body.crafting_queue_size or 0) > 0 then storage.tasks.last_finished_tick = game.tick end
  if storage.tasks.active and watchdog(storage.tasks) then return end
  if storage.tasks.active or #storage.tasks.queue > 0 then dispatch(storage.tasks) end
end
return M
