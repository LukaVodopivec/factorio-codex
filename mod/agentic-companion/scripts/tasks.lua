-- Sole-body FIFO dispatcher. Plans are atomic queue entries whose steps run
-- contiguously on tick, so RCON cannot interleave physical work.
local companion = require("scripts.companion")
local inspect = require("scripts.inspect")
local walk = require("scripts.actions.walk")
local mine = require("scripts.actions.mine")
local pickup = require("scripts.actions.pickup")
local build = require("scripts.actions.build")
local craft = require("scripts.actions.craft")
local transfer = require("scripts.actions.transfer")
local build_plan = require("scripts.actions.build_plan")
local factory_activity = require("scripts.factory_activity")
local map_summary = require("scripts.map_summary")
local M = {}
local RECORD_TTL_TICKS, PRUNE_INTERVAL_TICKS = 5 * 60 * 60, 3600
local PLAN_BUDGET_TICKS = 570 * 60
local runners = {
  walk_to = walk, mine = mine, pickup = pickup, place = build.place, rotate = build.rotate,
  set_recipe = build.set_recipe, craft = craft, insert = transfer.insert,
  extract = transfer.extract, build_plan = build_plan,
}
local observer
function M.set_observer(fn) observer = fn end

local function stop_body()
  local c = companion.get()
  if not c then return end
  c.walking_state, c.mining_state, c.picking_state = { walking = false }, { mining = false }, false
end
-- The owner's real input on the Codex client holds the body (companion.human_control
-- owns the rule). A failed read never holds.
local function human_control()
  local ok, held, idle = pcall(companion.human_control)
  if not ok then return false end
  return held == true, idle
end
local function cancel_crafting()
  local c = companion.get()
  if not c then return end
  local queue = c.crafting_queue or {}
  for i = #queue, 1, -1 do c.cancel_crafting({ index = i, count = queue[i].count }) end
end
local function task_crafts(task)
  local current = task.type == "plan" and task.current_task or task
  return current and (current.type == "craft" or current.type == "build_plan")
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
  local ok, value = pcall(observer, { radius = plan.final_observation_radius, detail = plan.observation_detail })
  if ok then plan.observation = value else plan.observation_error = tostring(value) end
end
local function inventory_snapshot(c)
  local out, inv = {}, c and c.get_main_inventory and c.get_main_inventory()
  if not inv then return out end
  for _, item in ipairs(inv.get_contents()) do out[item.name] = (out[item.name] or 0) + item.count end
  return out
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
local function finish(task, status, detail, preserve_body, outcome)
  if status == "cancelled" and task_crafts(task) then cancel_crafting() end
  if storage.tasks.active and storage.tasks.active.id == task.id then storage.tasks.active = nil end
  storage.tasks.last_finished_tick = game.tick
  if not preserve_body then stop_body() end
  if task.type == "plan" then
    task.finished_tick = game.tick
    task.final_inventory = inventory_snapshot(companion.get())
    observe_terminal(task)
    local final_status = status == "done" and "completed" or status
    if final_status == "completed" and task.observation_error then final_status = "failed" end
    set_plan_status(task, final_status)
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

local ACTIONS = {
  walk_to = "walk_to", mine = "mine", pickup_items = "pickup", place_entity = "place", craft_items = "craft",
  insert_items = "insert", extract_items = "extract", set_recipe = "set_recipe", rotate_entity = "rotate",
}
local function make_step_task(step)
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
    task.belt_to_ground_type = step.belt_to_ground_type
  end
  if kind == "craft" then task.recipe, task.count, task.wait_for_completion = step.recipe, step.crafts, step.wait_for_completion end
  if kind == "insert" then task.target, task.items = { x = step.x, y = step.y }, step.items end
  if kind == "extract" then task.target, task.items, task.all = { x = step.x, y = step.y }, step.items, step.items == nil end
  if kind == "set_recipe" then task.target, task.recipe = { x = step.x, y = step.y }, step.recipe end
  if kind == "rotate" then task.target, task.direction = { x = step.x, y = step.y }, step.direction end
  return task
end
function M.queue_plan(params)
  companion.require_companion()
  if type(params.steps) ~= "table" or #params.steps < 1 or #params.steps > 25 then error("queue_plan requires 1-25 steps") end
  if params.observation_detail ~= nil and params.observation_detail ~= "none"
    and params.observation_detail ~= "compact" and params.observation_detail ~= "full" then
    error("observation_detail must be none, compact, or full")
  end
  for i, step in ipairs(params.steps) do
    if type(step) ~= "table" or (step.action ~= "wait_for_item" and step.action ~= "wait_for_research"
      and step.action ~= "validate_factory_component" and step.action ~= "inspect_entities" and not ACTIONS[step.action]) then
      error("unknown plan action at step " .. i .. ": " .. tostring(type(step) == "table" and step.action or step))
    end
    if step.action == "craft_items" then
      if step.count ~= nil then error("queue_plan craft_items step " .. i .. " uses removed field count; use crafts") end
      local crafts = tonumber(step.crafts)
      if not crafts or crafts % 1 ~= 0 or crafts < 1 or crafts > 100 then
        error("queue_plan craft_items step " .. i .. " requires crafts as an integer from 1 to 100")
      end
    end
    if step.action == "inspect_entities" then
      if type(step.positions) ~= "table" or #step.positions < 1 or #step.positions > 16 then
        error("queue_plan inspect_entities step " .. i .. " requires 1-16 positions")
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
    if step.action == "validate_factory_component" then
      if type(step.source_tick) ~= "number" or step.source_tick % 1 ~= 0 or step.source_tick < 0
        or type(step.duration_seconds) ~= "number" or step.duration_seconds % 1 ~= 0
        or step.duration_seconds < 1 or step.duration_seconds > 300
        or type(step.positions) ~= "table" or #step.positions < 1 or #step.positions > 16 then
        error("queue_plan validate_factory_component step " .. i .. " requires source_tick, 1-16 exact node positions (one identifies the whole component), and duration_seconds from 1 to 300")
      end
      for _, position in ipairs(step.positions) do
        if type(position) ~= "table" or type(position.x) ~= "number" or type(position.y) ~= "number" then
          error("queue_plan validate_factory_component step " .. i .. " positions require numeric x and y")
        end
      end
    end
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
    observation_detail = params.observation_detail == "full" and "full"
      or params.observation_detail == "compact" and "compact" or "none",
    after_plan_id = predecessor,
  }
  -- Ticks the FIFO sat empty before this plan: the body's idle time while the
  -- caller reasoned, so a short plan's cost is visible in the next result.
  local tasks, body = storage.tasks, companion.get()
  local crafting = body and body.valid and (body.crafting_queue_size or 0) > 0
  local body_idle_ticks = (not tasks.active and #tasks.queue == 0 and not crafting and tasks.last_finished_tick)
    and math.max(0, game.tick - tasks.last_finished_tick) or 0
  return { plan_id = assign(plan), after_plan_id = predecessor, body_idle_ticks = body_idle_ticks,
    human_control = plan.human_control }
end
local function plan_payload(plan)
  local c = companion.get()
  local diagnostics
  if plan.current_task then
    diagnostics = { action = plan.steps[plan.current_step] and plan.steps[plan.current_step].action,
      next_check_tick = plan.next_check_tick }
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
    plan_id = plan.id, after_plan_id = plan.after_plan_id,
    status = plan.status, source_tick = game.tick,
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
    execution = { mode = "sequential_nontransactional", rollback = "none",
      committed_steps = committed_steps, incomplete_step = incomplete_step },
    diagnostics = diagnostics,
  }
end
function M.plan_status(params)
  local id = tonumber(params.plan_id)
  if not id then error("plan_status requires plan_id") end
  local tasks = storage.tasks
  if tasks.active and tasks.active.id == id and tasks.active.type == "plan" then return plan_payload(tasks.active) end
  for _, queued in ipairs(tasks.queue) do if queued.id == id and queued.type == "plan" then return plan_payload(queued) end end
  local record = tasks.records[id]
  if record and record.plan then observe_terminal(record.plan); return plan_payload(record.plan) end
  error("unknown plan_id: " .. id)
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
function M.cancel(params)
  local tasks, n = storage.tasks, 0
  local function record_cancelled_step(plan)
    if plan.type == "plan" and plan.current_task then
      local step = plan.steps[plan.current_step]
      plan.outcomes[#plan.outcomes + 1] = {
        step = plan.current_step, action = step.action,
        status = "cancelled", error = "cancelled",
      }
      plan.current_task = nil
    end
  end
  if params.all then
    local queued_tasks = tasks.queue
    tasks.queue = {}
    for _, queued in ipairs(queued_tasks) do
      record_cancelled_step(queued)
      finish(queued, "cancelled", "", true)
      n = n + 1
    end
    if tasks.active then
      record_cancelled_step(tasks.active)
      finish(tasks.active, "cancelled", ""); n = n + 1
    end
    cancel_crafting()
    -- Emergency cancellation is not the next plan's idle time.
    tasks.last_finished_tick = nil
    return { cancelled = n }
  end
  local id = tonumber(params.task_id or params.plan_id)
  if not id then error("cancel requires task_id, plan_id, or all=true") end
  if tasks.active and tasks.active.id == id then
    record_cancelled_step(tasks.active)
    finish(tasks.active, "cancelled", ""); return { cancelled = 1 }
  end
  for i, queued in ipairs(tasks.queue) do if queued.id == id then
    table.remove(tasks.queue, i)
    record_cancelled_step(queued)
    finish(queued, "cancelled", "", true)
    return { cancelled = 1 }
  end end
  return { cancelled = 0 }
end
function M.active_summary()
  local active = storage.tasks.active
  if not active then return nil end
  if active.type == "plan" then return { id = active.id, type = "plan", status = "running", current_step = active.current_step, total_steps = #active.steps } end
  return { id = active.id, type = active.type, status = "running" }
end
function M.queue_length() return #storage.tasks.queue end

local function finish_step(plan, result)
  factory_activity.record(plan.current_task and plan.current_task.type, result.outcome)
  local step = plan.steps[plan.current_step]
  local status = result.status == "done" and "completed" or result.status
  plan.outcomes[#plan.outcomes + 1] = {
    step = plan.current_step, action = step.action, status = status,
    result = result.outcome or ((status == "completed" or status == "partial") and (result.detail or status) or nil),
    error = (status == "failed" or status == "cancelled") and (result.detail or status) or nil,
  }
  plan.current_task = nil
  if status ~= "completed" then finish(plan, status, result.detail); return end
  plan.completed_steps = plan.current_step
  if plan.completed_steps == #plan.steps then finish(plan, "done", "") end
end
local function wait_timeout_ticks(step)
  return math.floor((tonumber(step.timeout_seconds) or 120) * 60)
end
local function wait_for_research(plan, step)
  plan.wait_started_tick = plan.wait_started_tick or game.tick
  step._wait_started_tick = step._wait_started_tick or plan.wait_started_tick
  local force = companion.require_companion().force
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

-- Validation judges throughput, never a single status sample. A component
-- passes on several downstream/production events with no character transfer
-- and unchanged topology; it fails structurally early only when a producer
-- stays nonproductive while nothing has moved for the stall interval, and it
-- never ends proven while stalled.
local VALIDATION_MIN_EVENTS = 3
local VALIDATION_STALL_TICKS = 20 * 60
local VALIDATION_STRUCTURAL_NONPRODUCTIVE_SHARE = 0.9
-- Drift across common machine periods to reduce aliasing. Short swings may
-- still fall between samples; uniquely attributable fuel rises also prove
-- return activity without requiring a sampled swing.
local VALIDATION_MAX_SAMPLE_TICKS = 29
local VALIDATION_MAX_ROWS = 12
local VALIDATION_MAX_TRANSIENT_ROWS = 8
local VALIDATION_MAX_DURATION_SECONDS = 300
-- An inserter tops up a burner's fuel inventory only below this stock, and
-- answers a draw within about a swing, or within the supply interval its
-- return has already shown; a younger unrefilled draw at the end of the window
-- is still in flight.
local VALIDATION_FUEL_TOP_UP_ITEMS = 5
local VALIDATION_REFILL_GRACE_TICKS = 180
-- A path that kept a regular event period is stopped once its last event is
-- older than this many of its own periods.
local VALIDATION_RECENCY_PERIODS = 4
-- Statuses of an external electrical dependent that is waiting, not
-- starved of power.
local IDLE_DEPENDENT_STATUSES = { idle = true, insufficient_input = true, full_output = true }
local NONPRODUCTIVE_STATUSES = {
  insufficient_input = true, full_output = true, no_fuel = true, no_power = true,
  low_power = true, no_resources = true, disabled = true,
}
-- A stalled producer out of fuel, power, resources or enabled state is the
-- cause; its neighbours' input and output waits are symptoms.
local VALIDATION_CAUSE_STATUSES = { no_fuel = true, no_power = true, no_resources = true, disabled = true }
-- Any node held in one of these for nearly the whole window is dead on its
-- own path, whatever the rest of the component did.
local VALIDATION_DEAD_STATUSES = { no_fuel = true, no_power = true, low_power = true, no_resources = true, disabled = true }
-- An inserter or belt on low power still moves items, only slower; its
-- throughput, not its status, decides.
local function dead_status(role, status)
  return VALIDATION_DEAD_STATUSES[status] and not (role == "transport" and status == "low_power") or false
end

-- Non-transient graph rows, plus transfer evidence. Older or stubbed samples
-- carry bare blocker names, which are treated as structural.
local function hard_rows(sample)
  local rows = {}
  if sample._blocker_rows then
    for _, row in ipairs(sample._blocker_rows) do if row.class ~= "transient" then rows[#rows + 1] = row end end
  else
    for _, blocker in ipairs(sample.blockers or {}) do
      rows[#rows + 1] = type(blocker) == "table" and blocker or { reason = blocker, class = "structural" }
    end
  end
  if (sample.character_transfer_actions or 0) > 0 then rows[#rows + 1] = { reason = "character_transfer_observed", class = "evidence" } end
  if not sample.character_history_complete then rows[#rows + 1] = { reason = "character_transfer_history_incomplete", class = "evidence" } end
  return rows
end

-- The signature rows a changed component lost and gained, at most four each
-- way, with the private key separators made readable.
local function topology_diff(before, after)
  local function rows(signature)
    local list, set = {}, {}
    for row in string.gmatch(signature, "[^|]+") do list[#list + 1], set[row] = row, true end
    return list, set
  end
  local old, old_set = rows(before)
  local new, new_set = rows(after)
  local diff = { removed = {}, added = {}, omitted = 0 }
  for _, side in ipairs({ { old, new_set, diff.removed }, { new, old_set, diff.added } }) do
    for _, row in ipairs(side[1]) do
      if not side[2][row] then
        if #side[3] < 4 then side[3][#side[3] + 1] = (string.gsub(row, "\0", ",")):sub(1, 160)
        else diff.omitted = diff.omitted + 1 end
      end
    end
  end
  return diff
end

-- Readiness rows first, one row per (reason, position), bounded for plan_status.
-- Rows are copied without internal graph ids; the third result says whether
-- the first row is a readiness row.
local function outcome_rows(rows, limit)
  local ordered, seen, readiness_first = {}, {}, false
  for pass = 1, 2 do
    for _, row in ipairs(rows) do
      local key = row.reason .. (row.position and string.format("\0%.17g\0%.17g", row.position.x, row.position.y) or "")
      if (row.gate == "readiness") == (pass == 1) and not seen[key] then
        seen[key] = true
        if #ordered == 0 then readiness_first = pass == 1 end
        ordered[#ordered + 1] = { reason = row.reason, class = row.class, position = row.position, entity = row.entity,
          related_edge = row.related_edge, samples = row.samples, nonproductive_samples = row.nonproductive_samples,
          last_event_tick = row.last_event_tick, fuel_items = row.fuel_items, fuel_draws = row.fuel_draws,
          fuel_demand_watts = row.fuel_demand_watts, fuel_supply_watts = row.fuel_supply_watts,
          suggested_duration_seconds = row.suggested_duration_seconds, projected_seconds = row.projected_seconds }
      end
    end
  end
  local omitted = math.max(0, #ordered - limit)
  while #ordered > limit do table.remove(ordered) end
  return ordered, omitted, readiness_first
end

-- Each counter keeps whole-window counts and a stall interval reset by any
-- progress, so a segment that worked early and then stopped is judged on the
-- stop. Burner producers also track stored fuel: a rise in energy or items is
-- a refill, a fall is consumption (the burning remainder counts, so a burner
-- with an empty fuel inventory still consumes). Consumption below the top-up
-- stock owes a refill until one arrives. A supply-limited return answers once
-- per supply period: while each refill still leaves the burner below the
-- top-up stock, demand is continuous, and the gap since the previous refill
-- (or since the first unanswered draw) is the longest wait it has shown.
local function observe_statuses(step, sample, progressed)
  step._samples = step._samples + 1
  for key, info in pairs(sample._node_status or {}) do
    local counter = step._status_counts[key] or { samples = 0, nonproductive = 0, statuses = {} }
    step._status_counts[key] = counter
    if progressed or not counter.stall then counter.stall = { samples = 0, nonproductive = 0, statuses = {} } end
    counter.role, counter.position, counter.entity = info.role, info.position, info.entity
    counter.fuel_sources, counter.fuel_supply_unmodelled = info.fuel_sources, info.fuel_supply_unmodelled
    counter.fuel_unreadable = counter.fuel_unreadable or info.fuel_unreadable
    counter.drop_to = info.drop_to
    -- A fuel-only feeder waiting at a burner still holding its top-up stock
    -- owes it nothing in this sample; the streak starts once it falls below.
    local fed = info.fuel_feed_to and ((sample._node_status or {})[info.fuel_feed_to] or {}).fuel_items
    local satisfied = info.saturated or type(fed) == "number" and fed >= VALIDATION_FUEL_TOP_UP_ITEMS
    for _, counts in ipairs({ counter, counter.stall }) do
      counts.samples = counts.samples + 1
      if NONPRODUCTIVE_STATUSES[info.status] and not satisfied then
        counts.nonproductive = counts.nonproductive + 1
        counts.statuses[info.status] = (counts.statuses[info.status] or 0) + 1
      end
    end
    -- The current dead streak: the tick the node entered a dead status,
    -- reset by any sample outside that set.
    if dead_status(info.role, info.status) then
      counter.dead_since, counter.dead_status = counter.dead_since or game.tick, info.status
    else counter.dead_since, counter.dead_status = nil, nil end
    -- The current starved streak: waiting for source items since this tick.
    -- The whole wait is kept too, in case the burner's stock only hid it.
    if info.status == "insufficient_input" then
      counter.waiting_since = counter.waiting_since or game.tick
    else counter.waiting_since = nil end
    if info.status == "insufficient_input" and not satisfied then
      counter.starved_since = counter.starved_since or game.tick
    else counter.starved_since = nil end
    counter.fuel_feed_to = info.fuel_feed_to
    if type(info.fuel_energy) == "number" and type(info.fuel_items) == "number" then
      if counter.fuel_energy then
        if info.fuel_energy > counter.fuel_energy + 1 or info.fuel_items > counter.fuel_items then
          local since = counter.refill_left_demand and counter.refill_tick or counter.refill_owed_tick
          if since then counter.refill_interval = math.max(counter.refill_interval or 0, game.tick - since) end
          counter.refill_tick, counter.refill_left_demand = game.tick, info.fuel_items < VALIDATION_FUEL_TOP_UP_ITEMS
          counter.refuelled, counter.refill_owed_tick = true, nil
        else
          counter.burn_energy = (counter.burn_energy or 0) + counter.fuel_energy - info.fuel_energy
          counter.burn_ticks = (counter.burn_ticks or 0) + game.tick - counter.fuel_tick
          if info.fuel_items < counter.fuel_items then counter.fuel_draws = (counter.fuel_draws or 0) + 1 end
          if info.fuel_energy < counter.fuel_energy or info.fuel_items < counter.fuel_items then
            counter.consumed = true
            if info.fuel_items < VALIDATION_FUEL_TOP_UP_ITEMS then
              counter.refill_owed_tick, counter.demanded = counter.refill_owed_tick or game.tick, true
            end
          end
        end
      end
      counter.fuel_energy, counter.fuel_items, counter.fuel_tick = info.fuel_energy, info.fuel_items, game.tick
      counter.first_fuel_items = counter.first_fuel_items or info.fuel_items
      counter.fuel_item_energy = info.fuel_item_energy or counter.fuel_item_energy
    end
  end
  -- A supplied return inserter holding compatible fuel and waiting at a
  -- working burner with fuel inventory space is the return, already loaded.
  for _, info in pairs(sample._node_status or {}) do
    local counter = info.fuel_return_to and step._status_counts[info.fuel_return_to]
    if counter then counter.return_waiting = true end
  end
  -- A fuel rise delivered through the burner's unique supplied inlet is
  -- physical activity on that exact return, even if its short swing fell
  -- between status samples. Do not borrow another inlet's replenishment.
  for key, info in pairs(sample._node_status or {}) do
    local burner = step._status_counts[key]
    local inlet = info.fuel_refill_via and step._status_counts[info.fuel_refill_via]
    if inlet and burner.refill_tick == game.tick then inlet.starved_since = nil end
  end
end

local function status_row(counter, class, counts)
  counts = counts or counter
  local dominant, most
  for status, count in pairs(counts.statuses) do
    if not most or count > most or count == most and status < dominant then dominant, most = status, count end
  end
  return { reason = (class == "structural" and "persistent_nonproductive_status:" or "nonproductive_status:") .. dominant,
    class = class, position = counter.position, entity = counter.entity,
    samples = counts.samples, nonproductive_samples = counts.nonproductive }, dominant
end

-- Seconds a window started from the current stock needs, whatever the
-- burning phase, for this burner to fall below the top-up limit and be
-- answered at its observed burn rate; capped at the longest window. The
-- second result is the uncapped projection, when a burn rate is known.
local function refill_due_seconds(counter, requested, wait)
  local rate = (counter.burn_ticks or 0) > 0 and (counter.burn_energy or 0) / counter.burn_ticks or 0
  local item = counter.fuel_item_energy
  if rate <= 0 or not item then return VALIDATION_MAX_DURATION_SECONDS end
  local draws = math.max(1, counter.fuel_items - VALIDATION_FUEL_TOP_UP_ITEMS + 1)
  local ticks = draws * item / rate + math.max(VALIDATION_REFILL_GRACE_TICKS, wait or 0) + 2 * VALIDATION_MAX_SAMPLE_TICKS
  local seconds = math.ceil(ticks / 60)
  return math.min(VALIDATION_MAX_DURATION_SECONDS, math.max(requested, seconds)), seconds
end

-- The first, last and number of sampled event ticks per path (endpoint
-- acceptance, processor crafts, source cycles), at most one per sample.
local function note_event(step, key)
  local stats = step._events[key] or { count = 0 }
  step._events[key] = stats
  if stats.last == game.tick then return end
  stats.first, stats.last, stats.count = stats.first or game.tick, game.tick, stats.count + 1
end

-- Rises of sampled stock between consecutive samples, and the tick of the
-- last fall.
local function track_stock(current, previous, inflow, outflow)
  for key, stock in pairs(current or {}) do
    local before = (previous or {})[key]
    for product, count in pairs(stock) do
      if before and before[product] and count > before[product] then
        inflow[key] = inflow[key] or {}
        inflow[key][product] = true
      elseif before and before[product] and count < before[product] then outflow[key] = game.tick end
    end
  end
end

local function by_position(a, b)
  if not a.position or not b.position then return a.position ~= nil and b.position == nil end
  if a.position.y ~= b.position.y then return a.position.y < b.position.y end
  return a.position.x < b.position.x
end

-- Native last-tick fields are integrated only over consecutive observed
-- ticks. Three bounded bursts share this validator and its exact private graph;
-- gaps never become inferred pump/generator cycles: a skipped tick restarts
-- the consecutive run inside its burst. Balances run over fluid
-- domains (a segment plus any out-of-segment box piped into it, such as a
-- boiler output or a pump). get_fluid_segment_contents is documented as
-- uint32, so each burst's mass balance reserves one unit per segment of the
-- domain; 2.0.77 returns fractional stock, so that reserve is conservative,
-- and a burst lasts enough consecutive ticks for low-demand transformation to
-- clear it. A boiler unproven only in a shortened burst (a window too short
-- for full bursts, or one clamped after a recovered flicker) with its input
-- held names a strictly longer window that fits three full bursts and the
-- ticks between them, when the maximum window leaves one.
local NATIVE_BURST_TICKS = 120
local NATIVE_BURST_FULL_SECONDS = math.ceil((NATIVE_BURST_TICKS * 3 + 2) / 60)
local function native_required(sample)
  for _, info in pairs(sample._native_activity or {}) do
    if info.source or info.type == "boiler" or info.generator or info.consumer or info.type == "pump" and not info.electrical_only then return true end
  end
  return false
end

local function observe_native(step, sample)
  local burst = step._native_burst
  if not burst then return end
  local previous = burst.previous
  local consecutive = previous and sample.tick == previous.tick + 1
  local current = sample._native_activity or {}
  local function event(key, field)
    local counts = step._native_counts[key]
    counts[field] = (counts[field] or 0) + 1
    note_event(step, key .. ":" .. field)
  end
  -- A boiler's mass balance closes over one run of consecutive ticks, from
  -- burst.start to `last`. Each run stands alone on its own readings; a
  -- boiler proves at most once per burst.
  local function close_run(last)
    if last.tick == burst.start.tick then return end
    burst.runs = true
    local activity, producers = last._native_activity or {}, {}
    for key, info in pairs(activity) do
      if info.type == "boiler" and info.output and info.boxes then
        local domain = info.boxes[info.output].domain
        producers[domain] = producers[domain] or {}
        producers[domain][#producers[domain] + 1] = key
      end
    end
    for domain, keys in pairs(producers) do
      for _, key in ipairs(keys) do
        local info, before = activity[key], burst.start._native_activity[key]
        local counts = step._native_counts[key]
        if #keys ~= 1 then counts.ambiguous = true
        elseif before and burst.burning[key] and not burst.proved[key] then
          local output, start_output = info.boxes[info.output], before.boxes[before.output]
          local input, start_input = info.boxes[info.input], before.boxes[before.input]
          if output.domain ~= start_output.domain or input.domain ~= start_input.domain then counts.unreadable = true
          elseif input.domain_amount >= start_input.domain_amount - input.domain_rounding then
            if output.domain_amount - start_output.domain_amount + (burst.draw[domain] or 0) - (burst.feed[domain] or 0)
                - output.domain_rounding > 0 then
              burst.proved[key] = true
              event(key, "flow")
            -- Only a held input whose production bound fell short in a
            -- shortened run is evidence for a longer window.
            elseif last.tick - burst.start.tick < NATIVE_BURST_TICKS then burst.short[key] = true end
          end
        end
      end
    end
  end
  -- A skipped tick ends the run at the previous sample and starts a new one
  -- here. Nothing is integrated or inferred across the gap.
  if previous and sample.tick ~= previous.tick and not consecutive then
    close_run(previous)
    burst.start, burst.draw, burst.feed, burst.burning = sample, {}, {}, {}
  end
  local observed_generation, networks = {}, {}
  for key, info in pairs(current) do
    local before = previous and previous._native_activity[key]
    local counts = step._native_counts[key]
    if consecutive and before then
      if info.type == "offshore-pump" or info.type == "pump" and not info.electrical_only then
        if type(info.pumped) == "number" and info.pumped > 0 then
          event(key, "flow")
          local input, output = info.input and info.boxes[info.input], info.boxes[info.output or 1]
          if input then burst.draw[input.domain] = (burst.draw[input.domain] or 0) + info.pumped end
          if output then burst.feed[output.domain] = (burst.feed[output.domain] or 0) + info.pumped end
        elseif info.pumped == nil then counts.unreadable = true end
      elseif info.generator then
        if type(info.generated) == "number" and info.generated > 0 then
          event(key, "flow")
          local box, generator = info.boxes[1], info.generator
          local per_unit = (generator.maximum_temperature - generator.default_temperature)
            * generator.heat_capacity * generator.effectivity
          if per_unit > 0 then
            burst.draw[box.domain] = (burst.draw[box.domain] or 0) + info.generated / per_unit
          else counts.unreadable = true end
        elseif info.generated == nil then counts.unreadable = true end
      end
      if info.type == "boiler" then
        if type(info.fuel_energy) ~= "number" or type(info.burning_energy) ~= "number" then counts.unreadable = true
        elseif type(before.fuel_energy) ~= "number" or type(before.burning_energy) ~= "number" then counts.unreadable = true
        elseif info.fuel_energy < before.fuel_energy or info.burning_energy < before.burning_energy then
          burst.burning[key] = true
        end
      end
      if info.consumer then
        local now = type(info.network_consumption) == "table" and info.network_consumption[info.name]
        local was = type(before.network_consumption) == "table" and before.network_consumption[info.name]
        if type(info.energy) ~= "number" or type(before.energy) ~= "number" then counts.unreadable = true
        elseif info.energy < before.energy then counts.used = true
        elseif info.energy > before.energy then event(key, "delivery")
        elseif info.energy > 0 and before.energy > 0 and (type(info.drain) == "number" and info.drain > 0
          or info.working and type(now) == "number" and type(was) == "number" and now > was) then
          -- Natively the network refills a supplied buffer before scripts read
          -- it, so it can read full every tick. A positive, nondecreasing own
          -- buffer under a native drain, or on a working drain-free consumer
          -- while its network's consumption for its prototype rose, proves
          -- consumption and replacement.
          counts.used = true
          event(key, "delivery")
        end
        -- An external dependent idle at a full drain-free buffer draws
        -- nothing: it neither proves nor disproves its supplying plant. A
        -- brownout (low or no power) or a partial buffer is not idle.
        if info.electrical_only and IDLE_DEPENDENT_STATUSES[info.status] and info.drain == 0
          and type(info.energy) == "number" and info.energy > 0 and info.energy == before.energy
          and type(info.buffer) == "number" and info.buffer > 0 and info.energy >= info.buffer then
          counts.idle_drain_free = true
        else counts.not_idle = true end
      end
      if info.generator and info.power_network then
        local network = info.power_network
        observed_generation[network] = observed_generation[network] or {}
        local counts_by_name = observed_generation[network]
        local earlier = burst.earlier and burst.earlier._native_activity[key]
        if type(info.generated) ~= "number" or type(info.network_generation) ~= "table"
          or type(before.network_generation) ~= "table" then counts.unreadable = true
        elseif earlier and burst.earlier.tick + 1 == previous.tick and type(earlier.network_generation) == "table" then
          -- Network statistics reflect the current update; the generator field
          -- explicitly reports the last tick. Compare the preceding interval.
          counts_by_name[info.name] = (counts_by_name[info.name] or 0) + info.generated
          networks[network] = { current = before.network_generation, previous = earlier.network_generation, key = key }
        end
      end
    end
  end
  -- Compare whole-network generation with the sum of actual observed entity
  -- generation for the preceding statistics interval. Unknown producers (even of the same name),
  -- accumulator discharge, resets and unreadable statistics cannot be attributed.
  for network, info in pairs(networks) do
    local names = {}
    for name in pairs(info.current) do names[name] = true end
    for name in pairs(info.previous) do names[name] = true end
    for name in pairs(observed_generation[network]) do names[name] = true end
    for name in pairs(names) do
      local now, before = info.current[name] or 0, info.previous[name] or 0
      -- Native counters quantize each increment to 1/65536 J and carry each
      -- tick's flow at float32 precision; allow exactly those roundings of the
      -- observed amount, not a workload-sized attribution tolerance.
      local observed = observed_generation[network][name] or 0
      if type(now) ~= "number" or type(before) ~= "number"
        or math.abs(now - before - observed) > math.max(1 / 65536, math.abs(observed) * 2 ^ -20) + 0.000001 then
        step._native_counts[info.key].attribution_failed = true
      end
    end
  end
  burst.earlier, burst.previous = previous, sample
  if sample.tick < burst.finish_tick then return end
  close_run(sample)
  -- Aliased only when the burst held no consecutive run at all: gap-separated
  -- single ticks prove nothing.
  for key, info in pairs(current) do
    if info.type == "boiler" and info.output and info.boxes then
      local counts = step._native_counts[key]
      if not burst.runs then counts.aliased = true
      elseif burst.short[key] and not burst.proved[key] then counts.short_burst = true end
    end
  end
  step._native_burst = nil
  step._native_burst_index = step._native_burst_index + 1
end

local function validate_factory_component(plan, step)
  plan.wait_started_tick = plan.wait_started_tick or game.tick
  step._wait_started_tick = step._wait_started_tick or plan.wait_started_tick
  if step.source_tick > game.tick then return { status = "failed", detail = "SOURCE_TICK_IN_FUTURE",
    outcome = { code = "SOURCE_TICK_IN_FUTURE", source_tick = step.source_tick, current_tick = game.tick } } end
  if not step._baseline then
    -- Bootstrap insertions queued before this step (fuel, input packets) are
    -- historical debt; the transfer window opens when validation starts.
    step._window_tick = math.max(step.source_tick, game.tick)
    step._drill_products = {}
    local baseline = map_summary.factory_component_sample({ source_tick = step._window_tick, positions = step.positions,
      drill_products = step._drill_products })
    if baseline.code == "FACTORY_COMPONENT_SPLIT" then
      return { status = "failed", detail = baseline.code, outcome = baseline }
    end
    step._baseline = baseline
    local rows = hard_rows(step._baseline)
    if not step._baseline.topology_ready or #rows > 0 then
      -- Preflight is topology only. A missing fuel edge or downstream path is
      -- a readiness refusal naming what to build, not a geometry defect.
      local blockers, omitted_blockers, not_ready = outcome_rows(rows, VALIDATION_MAX_ROWS)
      local first = blockers[1]
      plan.wait_started_tick, plan.next_check_tick = nil, nil
      return { status = "failed", detail = not_ready and (first.position
          and string.format("factory component not ready for validation: %s at %.1f,%.1f", first.reason, first.position.x, first.position.y)
          or "factory component not ready for validation: " .. first.reason)
          or "factory component autonomy preflight not proven", outcome = {
        code = not_ready and "FACTORY_COMPONENT_NOT_READY" or "FACTORY_COMPONENT_AUTONOMY_NOT_PROVEN", proven = false,
        stage = not_ready and "readiness" or "preflight", refused = not_ready or nil,
        source_tick = step.source_tick, transfer_window_start_tick = step._window_tick, component_signature = step._baseline.component_signature,
        selected_node_ids = step._baseline.selected_node_ids, start_tick = step._baseline.tick,
        end_tick = step._baseline.tick, requested_duration_seconds = step.duration_seconds, duration_ticks = 0,
        products_finished_before = step._baseline.products_finished_total,
        products_finished_after = step._baseline.products_finished_total, products_finished_delta = 0,
        character_transfer_actions = step._baseline.character_transfer_actions,
        downstream_kind = step._baseline.downstream_kind, blocked_output = step._baseline.blocked_output,
        source_cycles_observed = 0, downstream_acceptance_samples = 0, topology_ready = false, blockers = blockers, omitted_blockers = omitted_blockers,
        evidence_class = "charted_component_preflight", exact_remote_inventories = false, exact_remote_fluids = false,
      } }
    end
    step._validation_due_tick = game.tick + math.floor(step.duration_seconds * 60)
    step._sample_interval = math.max(1, math.min(VALIDATION_MAX_SAMPLE_TICKS, math.floor(step.duration_seconds * 60 / 3)))
    step._sample_phase = 0
    step._previous, step._acceptance_counts = step._baseline, {}
    for key, downstream in pairs(step._baseline._downstream) do
      step._acceptance_counts[key] = {}
      if downstream.kind == "consumer" then
        for product in pairs(downstream.products) do step._acceptance_counts[key][product] = 0 end
      else for product in pairs(downstream.stock) do step._acceptance_counts[key][product] = 0 end end
    end
    step._source_cycles = {}
    for key in pairs(step._baseline._source_production) do step._source_cycles[key] = 0 end
    step._buffer_inflow, step._buffer_outflow, step._input_inflow, step._input_outflow = {}, {}, {}, {}
    step._samples, step._status_counts, step._last_progress_tick = 0, {}, game.tick
    -- Per-path recency: when each endpoint accepted, each processor finished
    -- a product and each source cycled, so one live branch cannot hide
    -- another branch that stopped.
    step._events = {}
    if native_required(step._baseline) then
      step._native_counts, step._native_burst_index = {}, 1
      for key in pairs(step._baseline._native_activity) do step._native_counts[key] = {} end
      local third = math.floor(step.duration_seconds * 60 / 3)
      local length = math.min(NATIVE_BURST_TICKS, third)
      step._native_burst_length = length
      step._native_burst_starts = { game.tick,
        game.tick + math.floor(step.duration_seconds * 60 / 2) - length,
        step._validation_due_tick - length }
      step._native_burst = { start = step._baseline, previous = step._baseline,
        finish_tick = game.tick + length, draw = {}, feed = {}, burning = {}, proved = {}, short = {} }
    end
    observe_statuses(step, step._baseline, false)
    plan.next_check_tick = math.min(step._validation_due_tick, game.tick + (step._native_burst and 1 or step._sample_interval))
    return nil
  end
  local final = map_summary.factory_component_sample({ source_tick = step._window_tick, positions = step.positions,
    drill_products = step._drill_products })
  if final.code == "FACTORY_COMPONENT_SPLIT" then
    return { status = "failed", detail = final.code, outcome = final }
  end
  -- A sample whose topology or hard rows differ from the window's may be one
  -- flickering runtime read: skip it, and end the window only when the next
  -- sample confirms the difference. A recovered flicker is reported.
  local differs = final._signature ~= step._baseline._signature or #hard_rows(final) > 0
  if differs and not step._flicker_tick then
    step._flicker_tick, step._native_burst = game.tick, nil
    plan.next_check_tick = game.tick + step._sample_interval
    return nil
  elseif not differs and step._flicker_tick then
    step._flickers = step._flickers or { count = 0, first_tick = step._flicker_tick }
    step._flickers.count, step._flicker_tick = step._flickers.count + 1, nil
  end
  if step._native_counts and final._signature == step._baseline._signature then
    local start = step._native_burst_starts[step._native_burst_index]
    if not step._native_burst and start and game.tick >= start then
      step._native_burst = { start = final, previous = final,
        finish_tick = math.min(step._validation_due_tick, game.tick + step._native_burst_length),
        draw = {}, feed = {}, burning = {}, proved = {}, short = {} }
    end
    observe_native(step, final)
  end
  local delta = final.products_finished_total - step._baseline.products_finished_total
  local progressed = final.products_finished_total > step._previous.products_finished_total
  local blockers, diff = hard_rows(final), nil
  if final._signature ~= step._baseline._signature then
    blockers[#blockers + 1] = { reason = "component_topology_changed_during_validation", class = "evidence" }
    diff = topology_diff(step._baseline._signature, final._signature)
  end
  for key, downstream in pairs(final._downstream) do
    local previous, counts = step._previous._downstream[key], step._acceptance_counts[key]
    if counts and downstream.accepting then
      if downstream.kind == "consumer" then
        -- A lab counts acceptance only once this window has seen it working:
        -- a lab that only ever waits for packs proves nothing consumes them.
        if downstream.lab and ((final._node_status or {})[key] or {}).status == "working" then
          step._labs_working = step._labs_working or {}
          step._labs_working[key] = true
        end
        local lab_idle = downstream.lab and not (step._labs_working or {})[key]
        for product, accepting in pairs(lab_idle and {} or downstream.products) do
          local native = (final._native_activity or {})[key]
          local active = not native or not native.generator or type(native.generated) == "number" and native.generated > 0
          if counts[product] and accepting and active then counts[product] = counts[product] + 1; note_event(step, key) end
        end
      elseif previous then
        for product, count in pairs(downstream.stock) do
          if counts[product] and previous.stock[product] and count > previous.stock[product] then
            counts[product] = counts[product] + 1
            note_event(step, key)
            progressed = true
          end
        end
      end
    end
  end
  -- products_finished is a CraftingMachine counter, not a drill counter.
  -- A progress wrap plus depletion of the same charted mining target proves
  -- at least one completed source cycle, whatever the sampled status was;
  -- aliased/unsupported samples do not.
  local function cycled(source, previous)
    return previous and source.resource_key and source.resource_key == previous.resource_key
      and type(source.progress) == "number" and type(previous.progress) == "number"
      and source.progress < previous.progress
      and type(source.remaining) == "number" and type(previous.remaining) == "number"
      and source.remaining < previous.remaining
  end
  for key, source in pairs(final._source_production) do
    if cycled(source, step._previous._source_production[key]) then
      step._source_cycles[key] = step._source_cycles[key] + 1
      note_event(step, key)
      progressed = true
    end
  end
  -- A supplying component's fuel source only bounds this window's refill waits.
  step._supply_cycles = step._supply_cycles or {}
  for key, source in pairs(final._supply_sources or {}) do
    if cycled(source, (step._previous._supply_sources or {})[key]) then
      step._supply_cycles[key] = (step._supply_cycles[key] or 0) + 1
    end
  end
  for key, count in pairs(final._production) do
    local before = step._previous._production[key]
    if type(count) == "number" and type(before) == "number" and count > before then note_event(step, key) end
  end
  track_stock(final._buffers, step._previous._buffers, step._buffer_inflow, step._buffer_outflow)
  track_stock(final._inputs, step._previous._inputs, step._input_inflow, step._input_outflow)
  step._previous = final
  if progressed then step._last_progress_tick = game.tick end
  observe_statuses(step, final, progressed)
  local persistent, stalled = {}, game.tick - step._last_progress_tick >= VALIDATION_STALL_TICKS
  -- A stall once seen stays seen: later trickle progress cannot erase it.
  if stalled then step._stalled_once = true end
  if stalled then
    local causes, waits = {}, {}
    for _, counter in pairs(step._status_counts) do
      local stall = counter.stall
      if (counter.role == "source" or counter.role == "processor") and stall.samples >= VALIDATION_MIN_EVENTS
        and stall.nonproductive / stall.samples >= VALIDATION_STRUCTURAL_NONPRODUCTIVE_SHARE then
        local row, dominant = status_row(counter, "structural", stall)
        local list = VALIDATION_CAUSE_STATUSES[dominant] and causes or waits
        list[#list + 1] = { counter = counter, row = row }
      end
    end
    -- Wait-only producers carry the row only when no stalled producer has a cause.
    for _, entry in ipairs(#causes > 0 and causes or waits) do
      entry.counter.persistent = true
      persistent[#persistent + 1] = entry.row
    end
    table.sort(persistent, by_position)
  end
  if game.tick < step._validation_due_tick and #blockers == 0 and #persistent == 0 then
    -- Alternate adjacent intervals so a mining period dividing the nominal
    -- cadence does not keep every sample at the same phase indefinitely.
    step._sample_phase = 1 - step._sample_phase
    plan.next_check_tick = math.min(step._validation_due_tick, game.tick + math.max(1, step._sample_interval - step._sample_phase))
    if step._native_counts then
      local start = step._native_burst_starts[step._native_burst_index]
      if step._native_burst then plan.next_check_tick = math.min(plan.next_check_tick, game.tick + 1)
      elseif start then plan.next_check_tick = math.min(plan.next_check_tick, start) end
    end
    return nil
  end
  for _, row in ipairs(persistent) do blockers[#blockers + 1] = row end
  local pending = {}
  local function throughput(reason, key, related_edge, fields)
    -- External electrical dependents are located by their native entry.
    local info = key and (final._node_status and final._node_status[key] or (final._supply_sources or {})[key]
      or (final._native_activity or {})[key])
    local row = { reason = reason, class = "throughput", position = info and info.position, entity = info and info.entity,
      related_edge = related_edge }
    for field, value in pairs(fields or {}) do row[field] = value end
    if key and row.class == "evidence" then pending[key] = true end
    blockers[#blockers + 1] = row
  end
  -- A supply-limited source hands its burners one fuel item per mining
  -- period, so an unanswered draw may first wait for every other burner on
  -- that source: the wait bound is their count times the source's nominal
  -- period (its observed cycle interval when no nominal is known), plus the
  -- swing and transport grace, or the longest supply interval its return has
  -- already shown plus a sample. A younger unanswered draw is still in flight.
  local sharing = {}
  for _, counter in pairs(step._status_counts) do
    for _, source in ipairs(counter.fuel_sources or {}) do sharing[source] = (sharing[source] or 0) + 1 end
  end
  local window_ticks = math.max(1, final.tick - step._baseline.tick)
  local function source_period(key)
    local production = final._source_production[key] or (final._supply_sources or {})[key] or {}
    if production.mining_period_ticks then return production.mining_period_ticks end
    local cycles = step._source_cycles[key] or step._supply_cycles[key] or 0
    if cycles > 0 then return window_ticks / cycles end
  end
  local function supply_wait(counter)
    local best
    for _, source in ipairs(counter.fuel_sources or {}) do
      local period = source_period(source)
      if period then best = math.min(best or math.huge, sharing[source] * period + VALIDATION_REFILL_GRACE_TICKS) end
    end
    return best or VALIDATION_REFILL_GRACE_TICKS
  end
  local function refill_wait(counter)
    return math.max(supply_wait(counter), (counter.refill_interval or 0) + step._sample_interval)
  end
  -- A source, transport or processor out of fuel, power, resources or enabled
  -- state in nearly every window sample, or still in one at the end for
  -- longer than an inserter swing and a few samples, is dead on its own path
  -- although another branch kept the component progressing (an inserter on an
  -- unpowered pole island, say). A burner out of fuel no longer than its
  -- refill bound is waiting for a refill in flight. Full output stays a
  -- throughput question.
  local dead, dead_limit = {}, math.max(VALIDATION_REFILL_GRACE_TICKS, 3 * step._sample_interval)
  for _, counter in pairs(step._status_counts) do
    if not counter.persistent and counter.role ~= "buffer" and counter.role ~= "sink" then
      local caused, dominant, most = 0, nil, nil
      for status, count in pairs(counter.statuses) do
        if dead_status(counter.role, status) then
          caused = caused + count
          if not most or count > most or count == most and status < dominant then dominant, most = status, count end
        end
      end
      local streak = counter.dead_since and final.tick - counter.dead_since or 0
      local refilling = counter.dead_status == "no_fuel" and counter.fuel_energy ~= nil
        and final.tick - (counter.refill_owed_tick or counter.dead_since) <= refill_wait(counter)
      if counter.samples < VALIDATION_MIN_EVENTS or caused / counter.samples < VALIDATION_STRUCTURAL_NONPRODUCTIVE_SHARE then
        dominant = streak >= dead_limit and not refilling and counter.dead_status or nil
      end
      if dominant then
        counter.persistent = true
        dead[#dead + 1] = { reason = "persistent_nonproductive_status:" .. dominant, class = "structural",
          position = counter.position, entity = counter.entity, samples = counter.samples, nonproductive_samples = caused }
      end
    end
  end
  -- Unreadable burner fuel cannot show the fuel supply continuing.
  for _, counter in pairs(step._status_counts) do
    if counter.fuel_unreadable then
      dead[#dead + 1] = { reason = "fuel_stock_unreadable", class = "evidence", position = counter.position, entity = counter.entity }
    end
  end
  table.sort(dead, by_position)
  for _, row in ipairs(dead) do blockers[#blockers + 1] = row end
  if step._stalled_once and #persistent == 0 then throughput("progress_stalled") end
  -- Starter fuel can outlast the window. A burner that consumed fuel must be
  -- seen refilled; one whose consumption left it below the top-up stock with
  -- no refill for longer than its refill bound has a starved fuel loop. One
  -- that never fell below the top-up stock has not exercised its return yet
  -- unless its supplied return was seen loaded and waiting: that is
  -- inconclusive, not a geometry defect, and names a longer window, or the
  -- projected time when no window reaches the draw.
  --
  -- Takeoffs on a belt are served in belt order, so a burner may wait for
  -- every burner ahead of it to reach the top-up stock: one that never ran
  -- out while others on its source were refilled and gained stock, none of
  -- them out of fuel, is behind a loop still converging, evidence naming a
  -- window that lets them fill.
  local function converging(counter)
    local ticks
    for _, other in pairs(step._status_counts) do
      local shared = false
      for _, source in ipairs(other ~= counter and other.fuel_sources or {}) do
        for _, mine in ipairs(counter.fuel_sources or {}) do shared = shared or source == mine end
      end
      if shared then
        if other.statuses.no_fuel then return nil end
        local rise = other.refuelled and other.fuel_items and other.first_fuel_items and other.fuel_items - other.first_fuel_items or 0
        if rise > 0 then
          ticks = math.max(ticks or 0, (math.max(0, VALIDATION_FUEL_TOP_UP_ITEMS - other.fuel_items) + 1) * window_ticks / rise)
        end
      end
    end
    return ticks
  end
  for key, counter in pairs(step._status_counts) do
    local supply = supply_wait(counter)
    if counter.refill_owed_tick and final.tick - counter.refill_owed_tick > refill_wait(counter) then
      local filling = not counter.statuses.no_fuel and converging(counter)
      if filling then
        throughput("fuel_return_not_yet_exercised", key, nil, { class = "evidence", fuel_items = counter.fuel_items,
          fuel_draws = counter.fuel_draws or 0,
          suggested_duration_seconds = math.min(VALIDATION_MAX_DURATION_SECONDS, math.ceil(filling / 60) + step.duration_seconds) })
      else
        throughput("fuel_replenishment_not_observed", key, { kind = "fuel_input" },
          { fuel_items = counter.fuel_items, fuel_draws = counter.fuel_draws or 0 })
      end
    elseif counter.consumed and not counter.refuelled
      and not (counter.return_waiting and counter.fuel_items >= VALIDATION_FUEL_TOP_UP_ITEMS) then
      local due, projected = refill_due_seconds(counter, step.duration_seconds, supply)
      if projected and projected > VALIDATION_MAX_DURATION_SECONDS then
        throughput("fuel_return_beyond_window", key, nil, { class = "evidence", fuel_items = counter.fuel_items,
          fuel_draws = counter.fuel_draws or 0, projected_seconds = projected })
      else
        throughput("fuel_return_not_yet_exercised", key, nil, { class = "evidence", fuel_items = counter.fuel_items,
          fuel_draws = counter.fuel_draws or 0, suggested_duration_seconds = due })
      end
    end
  end
  -- A fuel loop must also be able to sustain itself: the observed burn rate
  -- of every burner a source fuels (split evenly among that burner's
  -- sources) cannot exceed what the source can mine at full duty. Starter
  -- stock and loaded returns hide a deficit only until the stock runs out.
  -- A supplying component's sources are judged the same way.
  local demand = {}
  for _, counter in pairs(step._status_counts) do
    if counter.fuel_sources and not counter.fuel_supply_unmodelled and (counter.burn_ticks or 0) > 0 then
      local rate = (counter.burn_energy or 0) / counter.burn_ticks
      for _, source in ipairs(counter.fuel_sources) do demand[source] = (demand[source] or 0) + rate / #counter.fuel_sources end
    end
  end
  for key, need in pairs(demand) do
    local production, supply = final._source_production[key] or (final._supply_sources or {})[key] or {}, nil
    local cycles = step._source_cycles[key] or step._supply_cycles[key] or 0
    if production.fuel_value and production.mining_period_ticks then
      supply = production.fuel_value / production.mining_period_ticks
    elseif production.fuel_value and cycles > 0
      and not ((step._status_counts[key] or {}).statuses or {}).full_output then
      supply = production.fuel_value * cycles / window_ticks
    end
    if supply and need > supply then
      throughput("fuel_supply_deficit", key, { kind = "fuel_input" },
        { fuel_demand_watts = math.floor(need * 60), fuel_supply_watts = math.floor(supply * 60) })
    end
  end
  -- Every endpoint and processor must still be moving near the end: within
  -- the stall interval, or the last third of a shorter window. A component
  -- stall already names the stop.
  -- A path with a regular period must also have moved within a few of its
  -- own periods.
  local recency = math.min(VALIDATION_STALL_TICKS, math.max(1, math.floor(step.duration_seconds * 60 / 3)))
  local function recent(key, count, event_key)
    if step._stalled_once or count < VALIDATION_MIN_EVENTS or (step._status_counts[key] or {}).persistent then return end
    local stats = step._events[event_key or key] or { count = 0 }
    local last, limit = stats.last or step._baseline.tick, recency
    if stats.count >= VALIDATION_MIN_EVENTS then
      local period = (stats.last - stats.first) / (stats.count - 1)
      limit = math.min(recency, math.max(VALIDATION_REFILL_GRACE_TICKS, math.ceil(VALIDATION_RECENCY_PERIODS * period)))
    end
    if final.tick - last > limit then
      throughput("path_stalled_before_end", key, nil, { last_event_tick = last })
    end
  end
  local fluid_samples, power_samples, native_source_samples
  for key, counts in pairs(step._native_counts or {}) do
    local info = (final._native_activity or {})[key] or {}
    if counts.unreadable then throughput("native_activity_unreadable", key, nil, { class = "evidence" }) end
    if counts.aliased then throughput("native_activity_aliased", key, nil, { class = "evidence" }) end
    if counts.ambiguous then throughput("boiler_transformation_attribution_unproven", key, nil, { class = "evidence" }) end
    if counts.attribution_failed then throughput("electrical_generation_attribution_unproven", key, nil, { class = "evidence" }) end
    if info.source or info.type == "boiler" or info.generator or info.type == "pump" and not info.electrical_only then
      local count = counts.flow or 0
      fluid_samples = math.min(fluid_samples or count, count)
      if info.source then native_source_samples = math.min(native_source_samples or count, count) end
      -- A maximum-length window has no strictly longer one to name.
      if count < VALIDATION_MIN_EVENTS and counts.short_burst and step.duration_seconds < VALIDATION_MAX_DURATION_SECONDS then
        throughput("bounded_fluid_activity_not_observed", key, nil, { class = "evidence",
          suggested_duration_seconds = math.min(VALIDATION_MAX_DURATION_SECONDS,
            math.max(NATIVE_BURST_FULL_SECONDS, step.duration_seconds + 1)) })
      elseif count < VALIDATION_MIN_EVENTS then throughput("bounded_fluid_activity_not_observed", key)
      else recent(key, count, key .. ":flow") end
      local before = step._baseline._native_activity[key]
      if before and info.boxes and before.boxes then
        for index, box in ipairs(info.boxes) do
          local start_box = before.boxes[index]
          if not start_box or box.domain ~= start_box.domain then
            throughput("fluid_segment_attribution_unproven", key); break
          elseif box.domain_amount < start_box.domain_amount - box.domain_rounding then
            throughput("fluid_supply_draining", key); break
          end
        end
      end
      if info.type == "boiler" then
        local fuel = step._status_counts[key] or {}
        if not fuel.consumed or not fuel.refuelled then throughput("boiler_fuel_replenishment_not_observed", key) end
      end
    end
    if info.consumer then
      -- An external dependent idle throughout at a full drain-free buffer is
      -- neutral; its buffer must still hold.
      if not (info.electrical_only and counts.idle_drain_free and not counts.not_idle) then
        local count = counts.delivery or 0
        power_samples = math.min(power_samples or count, count)
        if count < VALIDATION_MIN_EVENTS or not counts.used then throughput("bounded_power_delivery_not_observed", key)
        else recent(key, count, key .. ":delivery") end
      end
      local before = step._baseline._native_activity[key]
      if type(info.energy) ~= "number" or info.energy <= 0 or not before or type(before.energy) ~= "number" or info.energy < before.energy then
        throughput("electrical_store_draining", key)
      end
    end
  end
  local acceptance_samples
  for key, counts in pairs(step._acceptance_counts) do
    local endpoint
    for _, count in pairs(counts) do
      acceptance_samples = math.min(acceptance_samples or count, count)
      endpoint = math.min(endpoint or count, count)
    end
    if (endpoint or 0) < VALIDATION_MIN_EVENTS then
      -- A terminal fuel buffer behind fuel takeoffs gets only their surplus:
      -- while a burner it sits behind was refilled and gained stock, the
      -- loop is still converging, which is evidence naming a longer window.
      local filling
      for _, consumer in ipairs((step._baseline._downstream[key] or {}).fuel_takeoffs or {}) do
        local counter = step._status_counts[consumer]
        local rise = counter and counter.refuelled and counter.fuel_items and counter.first_fuel_items
          and counter.fuel_items - counter.first_fuel_items or 0
        if rise > 0 then
          local remaining = math.max(0, VALIDATION_FUEL_TOP_UP_ITEMS - counter.fuel_items) + 1
          filling = math.max(filling or 0, remaining * window_ticks / rise)
        end
      end
      if filling then
        throughput("surplus_fuel_endpoint_not_yet_reached", key, nil, { class = "evidence",
          suggested_duration_seconds = math.min(VALIDATION_MAX_DURATION_SECONDS, math.ceil(filling / 60) + step.duration_seconds) })
      else throughput("bounded_downstream_acceptance_not_observed", key) end
    else recent(key, endpoint) end
  end
  if not acceptance_samples then throughput("bounded_downstream_acceptance_not_observed") end
  acceptance_samples = acceptance_samples or 0
  -- A source that only refuels other producers cycles at their burn rate: one
  -- cycle suffices when every producer it fuels shows several cycles. Such a
  -- source is reported separately and never lowers source_cycles_observed.
  local function producer_cycles(key)
    if step._native_counts and step._native_counts[key] then return step._native_counts[key].flow or 0 end
    if step._source_cycles[key] then return step._source_cycles[key] end
    local count, before = final._production[key], step._baseline._production[key]
    return type(count) == "number" and type(before) == "number" and count - before or 0
  end
  -- When none of its consumers drew below the top-up stock, or every draw was
  -- met from fuel already downstream while the source sat output-blocked,
  -- nothing has needed it to cycle yet: inconclusive evidence naming a window
  -- that reaches a draw. A source that showed a cause status stays a defect.
  local source_cycles, fuel_source_cycles
  for key, count in pairs(step._source_cycles) do
    local fuel_consumers = (final._source_production[key] or {}).fuel_consumers
    local fuelled = fuel_consumers ~= nil and count >= 1 and count < VALIDATION_MIN_EVENTS
    local demanded, due = false, nil
    for _, consumer in ipairs(fuel_consumers or {}) do
      if producer_cycles(consumer) < VALIDATION_MIN_EVENTS then fuelled = false end
      local counter = step._status_counts[consumer]
      if counter and (counter.demanded or counter.refuelled) then demanded = true end
      due = math.max(due or 0, counter and refill_due_seconds(counter, step.duration_seconds, supply_wait(counter))
        or VALIDATION_MAX_DURATION_SECONDS)
    end
    local statuses = (step._status_counts[key] or {}).statuses or {}
    local caused, backpressured = false, (statuses.full_output or 0) > 0
    for status in pairs(statuses) do
      if VALIDATION_CAUSE_STATUSES[status] then caused = true end
      if status ~= "full_output" then backpressured = false end
    end
    if fuelled then fuel_source_cycles = math.min(fuel_source_cycles or count, count)
    elseif fuel_consumers and count < VALIDATION_MIN_EVENTS and not caused and (not demanded or backpressured) then
      throughput("fuel_demand_not_yet_exercised", key, nil, { class = "evidence", suggested_duration_seconds = due })
    else
      source_cycles = math.min(source_cycles or count, count)
      if count < VALIDATION_MIN_EVENTS then throughput("several_source_cycles_not_observed", key)
      elseif not fuel_consumers then recent(key, count) end
    end
  end
  if not source_cycles and (native_source_samples or 0) < VALIDATION_MIN_EVENTS then throughput("several_source_cycles_not_observed") end
  source_cycles = source_cycles or 0
  if next(step._baseline._production) and delta <= 0 then throughput("bounded_production_delta_not_observed") end
  -- Starter stock in an intermediate buffer, or a packet in a processor's
  -- input, can carry its consumers through a window: a stage whose stock fell
  -- with no inflow is draining, not fed. A non-fuel intermediate buffer that
  -- gained stock and released none within the path recency limit before the
  -- end has a dead outlet.
  local function draining(current, baseline, inflow, reason)
    for key, stock in pairs(current or {}) do
      local before = (baseline or {})[key]
      for product, count in pairs(stock) do
        if before and before[product] and count < before[product] and not (inflow[key] or {})[product] then
          throughput(reason, key)
          break
        end
      end
    end
  end
  draining(final._buffers, step._baseline._buffers, step._buffer_inflow, "intermediate_buffer_draining")
  draining(final._inputs, step._baseline._inputs, step._input_inflow, "processor_input_draining")
  for key, stock in pairs(final._buffers or {}) do
    local before = (step._baseline._buffers or {})[key]
    if before and step._buffer_inflow[key] and final.tick - (step._buffer_outflow[key] or step._baseline.tick) > recency
      and not (final._fuel_buffers or {})[key] then
      for product, count in pairs(stock) do
        if before[product] and count > before[product] then throughput("intermediate_buffer_outflow_not_observed", key); break end
      end
    end
  end
  for key, count in pairs(final._production) do
    local before = step._baseline._production[key]
    if type(count) ~= "number" or type(before) ~= "number" or count - before < VALIDATION_MIN_EVENTS then
      throughput("several_processor_cycles_not_observed", key)
    else recent(key, count - before) end
  end
  -- An inserter still waiting for source items past the path recency limit
  -- at the end carries nothing: growth beyond it came from stock. A wait at
  -- a drop target whose own evidence row names a longer window is a loop
  -- still filling in belt order, not a dead edge.
  -- A sole fuel feeder whose burner's draw stays unanswered past its refill
  -- bound was not satisfied but stopped: the stock only hid its whole wait.
  for key, counter in pairs(step._status_counts) do
    local burner = counter.fuel_feed_to and step._status_counts[counter.fuel_feed_to]
    local starved_since = counter.starved_since
    if burner and burner.refill_owed_tick and counter.waiting_since
      and final.tick - burner.refill_owed_tick > refill_wait(burner) then
      starved_since = counter.waiting_since
    end
    if counter.role == "transport" and not counter.persistent and counter.samples >= VALIDATION_MIN_EVENTS
      and starved_since and final.tick - starved_since > recency
      and not (counter.drop_to and pending[counter.drop_to]) then
      throughput("transport_starved_before_end", key, { kind = "inserter_pickup" },
        { samples = counter.samples, nonproductive_samples = counter.nonproductive })
    end
  end
  local proven = final.topology_ready and #blockers == 0
  local transient = {}
  for _, counter in pairs(step._status_counts) do
    if counter.nonproductive > 0 and not counter.persistent then transient[#transient + 1] = status_row(counter, "transient") end
  end
  table.sort(transient, function(a, b)
    local share_a, share_b = a.nonproductive_samples / a.samples, b.nonproductive_samples / b.samples
    if share_a ~= share_b then return share_a > share_b end
    return by_position(a, b)
  end)
  if step._flickers then
    table.insert(transient, 1, { reason = "topology_sample_flicker", class = "transient",
      samples = step._flickers.count, first_tick = step._flickers.first_tick })
  end
  local omitted_blockers
  blockers, omitted_blockers = outcome_rows(blockers, VALIDATION_MAX_ROWS)
  while #transient > VALIDATION_MAX_TRANSIENT_ROWS do table.remove(transient) end
  local outcome = {
    code = proven and "FACTORY_COMPONENT_AUTONOMY_PROVEN" or "FACTORY_COMPONENT_AUTONOMY_NOT_PROVEN",
    proven = proven, stage = "window", source_tick = step.source_tick, transfer_window_start_tick = step._window_tick,
    component_signature = final.component_signature, selected_node_ids = final.selected_node_ids,
    start_tick = step._baseline.tick, end_tick = final.tick,
    requested_duration_seconds = step.duration_seconds,
    duration_ticks = final.tick - step._baseline.tick,
    products_finished_before = step._baseline.products_finished_total,
    products_finished_after = final.products_finished_total,
    products_finished_delta = delta,
    character_transfer_actions = final.character_transfer_actions,
    downstream_kind = final.downstream_kind, blocked_output = final.blocked_output,
    source_cycles_observed = source_cycles, fuel_source_cycles_observed = fuel_source_cycles,
    native_source_activity_samples = native_source_samples,
    fluid_activity_samples = fluid_samples, power_delivery_samples = power_samples,
    mining_sources_present = step._native_counts and (next(step._source_cycles) ~= nil),
    native_power_required = step._native_counts and (power_samples ~= nil),
    downstream_acceptance_samples = acceptance_samples,
    topology_ready = final.topology_ready, blockers = blockers, omitted_blockers = omitted_blockers,
    topology_diff = diff, transient_conditions = #transient > 0 and transient or nil,
    samples_observed = step._samples, last_progress_tick = step._last_progress_tick,
    human_control_restarts = step._human_restarts,
    evidence_class = "bounded_multi_tick_component_validation",
    exact_remote_inventories = false, exact_remote_fluids = false,
  }
  plan.wait_started_tick, plan.next_check_tick = nil, nil
  if proven then factory_activity.record_validation(outcome, final._signature, final._supplies_power) end
  return { status = proven and "done" or "failed",
    detail = proven and "factory component autonomy proven" or "factory component autonomy not proven", outcome = outcome }
end

local PARKED_ACTIONS = { wait_for_item = true, wait_for_research = true, validate_factory_component = true }
local function wait_timeout_detail(step)
  local start = tonumber(step._starting_count) or 0
  local current = tonumber(step._current_count) or start
  local elapsed = step._wait_started_tick and game.tick - step._wait_started_tick or 0
  return string.format("timed out waiting for %d %s in %s: starting %d, current %d, observed delta %d after %d ticks",
    step.count, step.item, step.inventory, start, current, current - start, elapsed)
end
local function wait_for_item(plan, step)
  plan.wait_started_tick = plan.wait_started_tick or game.tick
  step._wait_started_tick = step._wait_started_tick or plan.wait_started_tick
  -- The condition is read before the deadline is applied: a wait whose items
  -- are present never times out on stale evidence.
  local timed_out = game.tick - plan.wait_started_tick >= wait_timeout_ticks(step)
  local c = companion.require_companion()
  local dx, dy = c.position.x - step.x, c.position.y - step.y
  if dx * dx + dy * dy > 900 and timed_out then
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    return { status = "failed", detail = wait_timeout_detail(step) }
  end
  if dx * dx + dy * dy > 900 then
    local distance = math.sqrt(dx * dx + dy * dy)
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    return { status = "failed",
      detail = string.format("TARGET_OUT_OF_OBSERVATION_RANGE: wait target is %.1f tiles away; maximum is 30", distance),
      outcome = { code = "TARGET_OUT_OF_OBSERVATION_RANGE", distance = distance,
        max_distance = 30, corrective_hint = "Physically approach with walk_to, or put this wait after a movement predecessor." } }
  end
  local response = inspect.inspect({ targets = { { x = step.x, y = step.y } } })
  local entity = response.entities and response.entities[1]
  if not entity or entity.error then return { status = "failed", detail = entity and entity.error or "inspect returned no entity" } end
  local found = entity.inventories and entity.inventories[step.inventory] and entity.inventories[step.inventory][step.item] or 0
  if step._starting_count == nil then step._starting_count = found end
  step._current_count = found
  if found >= step.count then
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    return { status = "done", detail = step.inventory .. " has " .. found .. " " .. step.item }
  end
  if timed_out then
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    return { status = "failed", detail = wait_timeout_detail(step) }
  end
  plan.next_check_tick = game.tick + 30
end
local function expire_parked_waits(tasks)
  for index = #tasks.queue, 1, -1 do
    local plan = tasks.queue[index]
    local step = plan.type == "plan" and plan.status == "waiting" and plan.steps[plan.current_step] or nil
    local due = step and (step.action == "wait_for_item" or step.action == "wait_for_research") and plan.wait_started_tick
      and game.tick - plan.wait_started_tick >= wait_timeout_ticks(step)
    if due and not tasks.active then
      -- The body is free: the dispatcher reads the condition once more this
      -- tick before the deadline is applied, so a met wait never expires.
      plan.next_check_tick = nil
    elseif due then
      table.remove(tasks.queue, index)
      local detail = step.action == "wait_for_item" and wait_timeout_detail(step)
        or string.format("timed out waiting for research %s after %d ticks", step.technology, game.tick - plan.wait_started_tick)
      plan.outcomes[#plan.outcomes + 1] = {
        step = plan.current_step, action = step.action, status = "failed", error = detail,
        result = step.action == "wait_for_research" and { code = "RESEARCH_WAIT_TIMEOUT",
          technology = step.technology, elapsed_ticks = game.tick - plan.wait_started_tick } or nil,
      }
      plan.current_task = nil
      plan.wait_started_tick, plan.next_check_tick = nil, nil
      -- This queued plan owns no physical state. Finalize only its record; an
      -- unrelated active action keeps the sole body and FIFO lane unchanged.
      finish(plan, "failed", detail, true)
    end
  end
end
local function tick_plan(plan)
  if game.tick - plan.started_tick >= PLAN_BUDGET_TICKS then
    if plan.current_task then finish_step(plan, { status = "failed", detail = "plan exceeded its 570-second active budget" })
    else finish(plan, "failed", "plan exceeded its 570-second active budget") end
    return
  end
  if not plan.current_task then
    plan.current_step = plan.completed_steps + 1
    local step = plan.steps[plan.current_step]
    plan.current_task = (PARKED_ACTIONS[step.action] or step.action == "inspect_entities")
      and { type = step.action } or make_step_task(step)
    if not PARKED_ACTIONS[step.action] and step.action ~= "inspect_entities" then
      -- Async action events are delivered to the one active queue entry. Give
      -- the nested runner its owning plan ID so it uses that same mailbox.
      plan.current_task.id = plan.id
      local ok, err = pcall(runners[plan.current_task.type].start, plan.current_task)
      if not ok then finish_step(plan, { status = "failed", detail = tostring(err) }); return end
    end
  end
  local step, ok, result = plan.steps[plan.current_step]
  if step.action == "wait_for_item" then ok, result = pcall(wait_for_item, plan, step)
  elseif step.action == "wait_for_research" then ok, result = pcall(wait_for_research, plan, step)
  elseif step.action == "validate_factory_component" then ok, result = pcall(validate_factory_component, plan, step)
  elseif step.action == "inspect_entities" then
    ok, result = pcall(function()
      local response = inspect.inspect({ targets = step.positions })
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
  if not ok then finish_step(plan, { status = "failed", detail = tostring(result) }) elseif result then finish_step(plan, result) end
end
local function predecessor_status(id)
  local record = storage.tasks.records[id]
  if record and record.plan then return record.plan.status end
  if storage.tasks.active and storage.tasks.active.id == id then return storage.tasks.active.status end
  for _, queued in ipairs(storage.tasks.queue) do if queued.id == id then return queued.status end end
end
local function dispatch(tasks)
  local task = tasks.active
  if not task then
    if #tasks.queue == 0 then return end
    local attempts = #tasks.queue
    for _ = 1, attempts do
      local candidate = table.remove(tasks.queue, 1)
      local parked = candidate.type == "plan" and candidate.status == "waiting"
        and candidate.next_check_tick and game.tick < candidate.next_check_tick
      local predecessor_blocked = false
      if candidate.type == "plan" and candidate.after_plan_id then
        local status = predecessor_status(candidate.after_plan_id)
        if status ~= "completed" then
          if status == "queued" or status == "running" or status == "waiting" then
            predecessor_blocked = true
          else
            finish(candidate, "cancelled", "predecessor plan did not complete successfully", true)
          end
        end
      end
      if parked or predecessor_blocked then tasks.queue[#tasks.queue + 1] = candidate
      elseif candidate.status ~= "cancelled" then task = candidate; break end
    end
    if not task then return end
    if task.type == "plan" then set_plan_status(task, "running") else task.status = "running" end
    task.started_tick, tasks.active = task.started_tick or game.tick, task
    if task.type == "plan" and task.start_inventory == nil then task.start_inventory = inventory_snapshot(companion.get()) end
    if task.type ~= "plan" then local ok, err = pcall(runners[task.type].start, task); if not ok then finish(task, "failed", tostring(err)); return end end
  end
  if task.type == "plan" then tick_plan(task); return end
  local ok, result = pcall(runners[task.type].tick, task)
  if not ok then finish(task, "failed", tostring(result)) elseif result then
    factory_activity.record(task.type, result.outcome)
    finish(task, result.status, result.detail, nil, result.outcome)
  end
end
-- Human takeover. While the owner's input holds the body the dispatcher is parked:
-- no step starts or ticks, nothing is cancelled or reordered, and the mod
-- writes no walking, mining or picking state after one release on entry, so
-- he can move freely. Hold ticks are not charged to any deadline.
local function mark_held(task)
  if task and task.type == "plan" then task.human_control = true end
end
local function enter_hold(tasks)
  tasks.human_hold = { since = game.tick }
  if tasks.active then stop_body() end
  mark_held(tasks.active)
  for _, queued in ipairs(tasks.queue) do mark_held(queued) end
end
-- The body may stand anywhere after a hold. The interrupted step keeps its
-- place and re-plans from the current position: its approach and any pending
-- path request are dropped, and a runner with body-bound progress resets it.
-- The hold is charged neither to a started plan's active budget nor to a
-- parked wait's timeout, whose condition nothing evaluated meanwhile. A
-- validation window the hold overlapped proves nothing about autonomy (the owner's
-- own transfers are invisible to the mod), so it starts over from a fresh
-- baseline after the hold, and the window time it discards is given back to
-- the plan's active budget. At most two restarts: a third hold inside the
-- window ends the step unproven, returned here as its result.
local MAX_WINDOW_RESTARTS = 2
local function release_plan(plan, held_ticks, hold_tick)
  if plan.started_tick then plan.started_tick = plan.started_tick + held_ticks end
  local step = plan.type == "plan" and plan.current_task and plan.steps[plan.current_step] or nil
  if not step then return end
  if step.action == "validate_factory_component" then
    if not step._baseline then return end
    local restarts = (step._human_restarts or 0) + 1
    if restarts > MAX_WINDOW_RESTARTS then
      plan.wait_started_tick, plan.next_check_tick = nil, nil
      return { status = "failed",
        detail = string.format("human_control_during_window: human control interrupted the validation window %d times; autonomy not proven", restarts),
        outcome = { code = "human_control_during_window", proven = false, stage = "window", source_tick = step.source_tick,
          transfer_window_start_tick = step._window_tick, start_tick = step._baseline.tick, end_tick = hold_tick,
          requested_duration_seconds = step.duration_seconds, human_control_restarts = MAX_WINDOW_RESTARTS,
          human_control_holds = restarts, evidence_class = "bounded_multi_tick_component_validation" } }
    end
    local window_start = step._wait_started_tick or step._baseline.tick
    if plan.started_tick then plan.started_tick = plan.started_tick + math.max(0, hold_tick - window_start) end
    for key in pairs(step) do
      if type(key) == "string" and key:sub(1, 1) == "_" then step[key] = nil end
    end
    step._human_restarts = restarts
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    return
  end
  if plan.wait_started_tick then plan.wait_started_tick = plan.wait_started_tick + held_ticks end
  if step._wait_started_tick then step._wait_started_tick = step._wait_started_tick + held_ticks end
end
local function leave_hold(tasks)
  local hold_tick = tasks.human_hold.since
  local held_ticks = game.tick - hold_tick
  tasks.human_hold = nil
  for index = #tasks.queue, 1, -1 do
    local queued = tasks.queue[index]
    local ended = release_plan(queued, held_ticks, hold_tick)
    if ended then
      -- A parked window owns no physical state: only its record is finalized.
      table.remove(tasks.queue, index)
      finish_step(queued, ended)
    end
  end
  local task = tasks.active
  if not task then return end
  local ended = release_plan(task, held_ticks, hold_tick)
  if ended then finish_step(task, ended); return end
  storage.path_request, task._path_result = nil, nil
  local current = task.type == "plan" and task.current_task or task
  if not current then return end
  current._approach, current._approach_close = nil, nil
  local runner = runners[current.type]
  if runner and runner.resume then
    local ok, err = pcall(runner.resume, current)
    if not ok then
      local result = { status = "failed", detail = tostring(err) }
      if task.type == "plan" then finish_step(task, result) else finish(task, "failed", result.detail) end
    end
  end
end
function M.on_tick()
  if game.tick % PRUNE_INTERVAL_TICKS == 0 then for id, record in pairs(storage.tasks.records) do if game.tick - record.finished_tick > RECORD_TTL_TICKS then storage.tasks.records[id] = nil end end end
  local tasks = storage.tasks
  if human_control() then
    if not tasks.human_hold then enter_hold(tasks) end
    -- The owner playing the body is not idle time.
    if tasks.last_finished_tick then tasks.last_finished_tick = game.tick end
    return
  end
  if tasks.human_hold then leave_hold(tasks) end
  expire_parked_waits(storage.tasks)
  -- Hand-crafting is body work: idle time starts when it ends, not when the
  -- asynchronous craft task that queued it finished.
  local body = storage.tasks.last_finished_tick and companion.get()
  if body and body.valid and (body.crafting_queue_size or 0) > 0 then storage.tasks.last_finished_tick = game.tick end
  if storage.tasks.active or #storage.tasks.queue > 0 then dispatch(storage.tasks) end
end
return M
