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
local function observe_terminal(plan)
  if plan.observation or plan.observation_error or not observer then return end
  local ok, value = pcall(observer, { radius = plan.final_observation_radius, detail = plan.observation_detail })
  if ok then plan.observation = value else plan.observation_error = tostring(value) end
end
local function finish(task, status, detail, preserve_body)
  if status == "cancelled" and task_crafts(task) then cancel_crafting() end
  if storage.tasks.active and storage.tasks.active.id == task.id then storage.tasks.active = nil end
  if not preserve_body then stop_body() end
  if task.type == "plan" then
    task.status = status == "done" and "completed" or status
    task.finished_tick = game.tick
    observe_terminal(task)
    if task.status == "completed" and task.observation_error then task.status = "failed" end
  end
  storage.tasks.records[task.id] = {
    status = task.type == "plan" and task.status or status, detail = detail or "",
    finished_tick = game.tick, plan = task.type == "plan" and task or nil,
  }
end
local function assign(task)
  local tasks = storage.tasks
  task.id, task.status = tasks.next_id, "queued"
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
    if kind == "mine" then task.target_kind = step.target_kind end
  end
  if kind == "pickup" then task.target, task.item, task.count = { x = step.x, y = step.y }, step.item, step.count end
  if kind == "place" then
    task.item, task.position, task.direction = step.name, { x = step.x, y = step.y }, step.direction
    task.input_target = step.input_target
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
    observation_detail = params.observation_detail == "full" and "full" or "compact",
    after_plan_id = predecessor,
  }
  return { plan_id = assign(plan) }
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
      }
    end
    local target = plan.current_task.target or plan.current_task.position
    if target then diagnostics.machine = { position = { x = target.x, y = target.y } } end
  elseif plan.status == "failed" and plan.outcomes[#plan.outcomes] then
    diagnostics = { failure = plan.outcomes[#plan.outcomes].error }
  end
  return {
    plan_id = plan.id, status = plan.status, source_tick = game.tick,
    position = c and { x = c.position.x, y = c.position.y } or nil,
    current_step = plan.current_step, completed_steps = plan.completed_steps,
    total_steps = #plan.steps, outcomes = plan.outcomes, queue_depth = #storage.tasks.queue,
    observation = plan.observation, observation_error = plan.observation_error,
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
  if record then return { status = record.status, detail = record.detail } end
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
    for _, queued in ipairs(tasks.queue) do
      record_cancelled_step(queued)
      if queued.type == "plan" then queued.status, queued.finished_tick = "cancelled", game.tick end
      tasks.records[queued.id] = { status = "cancelled", detail = "", finished_tick = game.tick, plan = queued.type == "plan" and queued or nil }
      n = n + 1
    end
    tasks.queue = {}
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
    if queued.type == "plan" then queued.status, queued.finished_tick = "cancelled", game.tick end
    tasks.records[id] = { status = "cancelled", detail = "", finished_tick = game.tick, plan = queued.type == "plan" and queued or nil }
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
    result = status == "completed" and (result.detail or "done") or nil,
    error = status ~= "completed" and (result.detail or status) or nil,
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
  return "timed out waiting for " .. step.count .. " " .. step.item .. " in " .. step.inventory
end
local function wait_for_item(plan, step)
  plan.wait_started_tick = plan.wait_started_tick or game.tick
  if game.tick - plan.wait_started_tick >= wait_timeout_ticks(step) then
    plan.wait_started_tick, plan.next_check_tick = nil, nil
    return { status = "failed", detail = wait_timeout_detail(step) }
  end
  local c = companion.require_companion()
  local dx, dy = c.position.x - step.x, c.position.y - step.y
  if dx * dx + dy * dy > 900 then
    plan.next_check_tick = game.tick + 30
    return nil
  end
  local response = inspect.inspect({ targets = { { x = step.x, y = step.y } } })
  local entity = response.entities and response.entities[1]
  if not entity or entity.error then return { status = "failed", detail = entity and entity.error or "inspect returned no entity" } end
  local found = entity.inventories and entity.inventories[step.inventory] and entity.inventories[step.inventory][step.item] or 0
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
    plan.status = "waiting"
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
            candidate.status = "cancelled"
            finish(candidate, "cancelled", "predecessor plan did not complete successfully")
          end
        end
      end
      if parked or predecessor_blocked then tasks.queue[#tasks.queue + 1] = candidate
      elseif candidate.status ~= "cancelled" then task = candidate; break end
    end
    if not task then return end
    task.status, task.started_tick, tasks.active = "running", task.started_tick or game.tick, task
    if task.type ~= "plan" then local ok, err = pcall(runners[task.type].start, task); if not ok then finish(task, "failed", tostring(err)); return end end
  end
  if task.type == "plan" then tick_plan(task); return end
  local ok, result = pcall(runners[task.type].tick, task)
  if not ok then finish(task, "failed", tostring(result)) elseif result then finish(task, result.status, result.detail) end
end
function M.on_tick()
  if game.tick % PRUNE_INTERVAL_TICKS == 0 then for id, record in pairs(storage.tasks.records) do if game.tick - record.finished_tick > RECORD_TTL_TICKS then storage.tasks.records[id] = nil end end end
  expire_parked_waits(storage.tasks)
  if storage.tasks.active or #storage.tasks.queue > 0 then dispatch(storage.tasks) end
end
return M
