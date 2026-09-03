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
    if kind == "mine" then
      task.target_kind, task.allow_fluid_loss = step.target_kind, step.allow_fluid_loss
      task.expected_name, task.observed_tick = step.expected_name, step.observed_tick
    end
  end
  if kind == "pickup" then task.target, task.item, task.count = { x = step.x, y = step.y }, step.item, step.count end
  if kind == "place" then
    task.item, task.position, task.direction = step.name, { x = step.x, y = step.y }, step.direction
    task.output_target = step.output_target
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
    if type(step) ~= "table" or (step.action ~= "wait_for_item" and not ACTIONS[step.action]) then
      error("unknown plan action at step " .. i .. ": " .. tostring(type(step) == "table" and step.action or step))
    end
    if step.action == "craft_items" then
      if step.count ~= nil then error("queue_plan craft_items step " .. i .. " uses removed field count; use crafts") end
      local crafts = tonumber(step.crafts)
      if not crafts or crafts % 1 ~= 0 or crafts < 1 or crafts > 100 then
        error("queue_plan craft_items step " .. i .. " requires crafts as an integer from 1 to 100")
      end
    end
  end
  local predecessor = params.after_plan_id and tonumber(params.after_plan_id) or nil
  if params.after_plan_id ~= nil and (not predecessor or predecessor < 1) then error("after_plan_id must be a positive plan ID") end
  local plan = {
    type = "plan", steps = params.steps, current_step = 0, completed_steps = 0, outcomes = {},
    final_observation_radius = tonumber(params.final_observation_radius) or 15,
    observation_detail = params.observation_detail == "full" and "full"
      or params.observation_detail == "compact" and "compact" or "none",
    after_plan_id = predecessor,
  }
  return { plan_id = assign(plan), after_plan_id = predecessor }
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
    position = c and { x = c.position.x, y = c.position.y } or nil,
    current_step = plan.current_step, completed_steps = plan.completed_steps,
    total_steps = #plan.steps, outcomes = plan.outcomes, queue_depth = #storage.tasks.queue,
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
  local step = plan.steps[plan.current_step]
  local status = result.status == "done" and "completed" or result.status
  plan.outcomes[#plan.outcomes + 1] = {
    step = plan.current_step, action = step.action, status = status,
    result = (status == "completed" or status == "partial") and (result.outcome or result.detail or status) or nil,
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
  if game.tick - plan.wait_started_tick >= wait_timeout_ticks(step) then
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    return { status = "failed", detail = wait_timeout_detail(step) }
  end
  local c = companion.require_companion()
  local dx, dy = c.position.x - step.x, c.position.y - step.y
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
  plan.next_check_tick = game.tick + 30
end
local function expire_parked_waits(tasks)
  for index = #tasks.queue, 1, -1 do
    local plan = tasks.queue[index]
    local step = plan.type == "plan" and plan.status == "waiting" and plan.steps[plan.current_step] or nil
    if step and step.action == "wait_for_item" and plan.wait_started_tick
      and game.tick - plan.wait_started_tick >= wait_timeout_ticks(step) then
      table.remove(tasks.queue, index)
      local detail = wait_timeout_detail(step)
      plan.outcomes[#plan.outcomes + 1] = {
        step = plan.current_step, action = step.action, status = "failed", error = detail,
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
    plan.current_task = step.action == "wait_for_item" and { type = "wait_for_item" } or make_step_task(step)
    if step.action ~= "wait_for_item" then
      -- Async action events are delivered to the one active queue entry. Give
      -- the nested runner its owning plan ID so it uses that same mailbox.
      plan.current_task.id = plan.id
      local ok, err = pcall(runners[plan.current_task.type].start, plan.current_task)
      if not ok then finish_step(plan, { status = "failed", detail = tostring(err) }); return end
    end
  end
  local step, ok, result = plan.steps[plan.current_step]
  if step.action == "wait_for_item" then ok, result = pcall(wait_for_item, plan, step)
  else ok, result = pcall(runners[plan.current_task.type].tick, plan.current_task) end
  if ok and step.action == "wait_for_item" and result == nil then
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
  if not ok then finish(task, "failed", tostring(result)) elseif result then finish(task, result.status, result.detail, nil, result.outcome) end
end
function M.on_tick()
  if game.tick % PRUNE_INTERVAL_TICKS == 0 then for id, record in pairs(storage.tasks.records) do if game.tick - record.finished_tick > RECORD_TTL_TICKS then storage.tasks.records[id] = nil end end end
  expire_parked_waits(storage.tasks)
  if storage.tasks.active or #storage.tasks.queue > 0 then dispatch(storage.tasks) end
end
return M
