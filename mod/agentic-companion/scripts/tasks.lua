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
        error("queue_plan validate_factory_component step " .. i .. " requires source_tick, 1-16 positions, and duration_seconds from 1 to 300")
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

local function validate_factory_component(plan, step)
  plan.wait_started_tick = plan.wait_started_tick or game.tick
  step._wait_started_tick = step._wait_started_tick or plan.wait_started_tick
  if step.source_tick > game.tick then return { status = "failed", detail = "SOURCE_TICK_IN_FUTURE",
    outcome = { code = "SOURCE_TICK_IN_FUTURE", source_tick = step.source_tick, current_tick = game.tick } } end
  if not step._baseline then
    step._baseline = map_summary.factory_component_sample({ source_tick = step.source_tick, positions = step.positions })
    if not step._baseline.topology_ready then
      local blockers = {}
      for _, blocker in ipairs(step._baseline.blockers or {}) do
        blockers[#blockers + 1] = type(blocker) == "table" and blocker or { reason = blocker }
      end
      local omitted_blockers = math.max(0, #blockers - 24)
      while #blockers > 24 do table.remove(blockers) end
      plan.wait_started_tick, plan.next_check_tick = nil, nil
      return { status = "failed", detail = "factory component autonomy preflight not proven", outcome = {
        code = "FACTORY_COMPONENT_AUTONOMY_NOT_PROVEN", proven = false, stage = "preflight",
        source_tick = step.source_tick, component_signature = step._baseline.component_signature,
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
    step._sample_interval = math.max(1, math.min(30, math.floor(step.duration_seconds * 60 / 3)))
    step._sample_phase = 0
    step._previous, step._acceptance_counts = step._baseline, {}
    for key, downstream in pairs(step._baseline._downstream) do
      step._acceptance_counts[key] = {}
      if downstream.kind == "consumer" then step._acceptance_counts[key].consumer = 0
      else for product in pairs(downstream.stock) do step._acceptance_counts[key][product] = 0 end end
    end
    step._source_cycles = {}
    for key in pairs(step._baseline._source_production) do step._source_cycles[key] = 0 end
    plan.next_check_tick = math.min(step._validation_due_tick, game.tick + step._sample_interval)
    return nil
  end
  local final = map_summary.factory_component_sample({ source_tick = step.source_tick, positions = step.positions })
  local delta = final.products_finished_total - step._baseline.products_finished_total
  local blockers = {}
  for _, blocker in ipairs(final.blockers or {}) do
    blockers[#blockers + 1] = type(blocker) == "table" and blocker or { reason = blocker }
  end
  if final._signature ~= step._baseline._signature then
    blockers[#blockers + 1] = { reason = "component_topology_changed_during_validation" }
  end
  if final.character_transfer_actions > 0 then blockers[#blockers + 1] = { reason = "character_transfer_observed" } end
  if not final.character_history_complete then blockers[#blockers + 1] = { reason = "character_transfer_history_incomplete" } end
  for key, downstream in pairs(final._downstream) do
    local previous, counts = step._previous._downstream[key], step._acceptance_counts[key]
    if counts and downstream.accepting then
      if downstream.kind == "consumer" then counts.consumer = counts.consumer + 1
      elseif previous then
        for product, count in pairs(downstream.stock) do
          if counts[product] and previous.stock[product] and count > previous.stock[product] then
            counts[product] = counts[product] + 1
          end
        end
      end
    end
  end
  for key, source in pairs(final._source_production) do
    local previous = step._previous._source_production[key]
    -- products_finished is a CraftingMachine counter, not a drill counter.
    -- A progress wrap plus depletion of the same charted mining target proves
    -- at least one completed source cycle; aliased/unsupported samples do not.
    if previous and source.working and source.resource_key and source.resource_key == previous.resource_key
      and type(source.progress) == "number" and type(previous.progress) == "number"
      and source.progress < previous.progress
      and type(source.remaining) == "number" and type(previous.remaining) == "number"
      and source.remaining < previous.remaining then
      step._source_cycles[key] = step._source_cycles[key] + 1
    end
  end
  step._previous = final
  if game.tick < step._validation_due_tick and #blockers == 0 then
    -- Alternate adjacent intervals so a mining period dividing the nominal
    -- cadence does not keep every sample at the same phase indefinitely.
    step._sample_phase = 1 - step._sample_phase
    plan.next_check_tick = math.min(step._validation_due_tick, game.tick + math.max(1, step._sample_interval - step._sample_phase))
    return nil
  end
  local acceptance_samples
  for _, counts in pairs(step._acceptance_counts) do
    for _, count in pairs(counts) do acceptance_samples = math.min(acceptance_samples or count, count) end
  end
  acceptance_samples = acceptance_samples or 0
  local source_cycles
  for _, count in pairs(step._source_cycles) do source_cycles = math.min(source_cycles or count, count) end
  source_cycles = source_cycles or 0
  if source_cycles < 3 then blockers[#blockers + 1] = { reason = "several_source_cycles_not_observed" } end
  if acceptance_samples < 3 then blockers[#blockers + 1] = { reason = "bounded_downstream_acceptance_not_observed" } end
  if delta <= 0 then blockers[#blockers + 1] = { reason = "bounded_production_delta_not_observed" } end
  for key, count in pairs(final._production) do
    local before = step._baseline._production[key]
    if type(count) ~= "number" or type(before) ~= "number" or count - before < 3 then
      blockers[#blockers + 1] = { reason = "several_processor_cycles_not_observed" }
    end
  end
  local proven = final.topology_ready and #blockers == 0
  local omitted_blockers = math.max(0, #blockers - 24)
  while #blockers > 24 do table.remove(blockers) end
  local outcome = {
    code = proven and "FACTORY_COMPONENT_AUTONOMY_PROVEN" or "FACTORY_COMPONENT_AUTONOMY_NOT_PROVEN",
    proven = proven, source_tick = step.source_tick,
    component_signature = final.component_signature, selected_node_ids = final.selected_node_ids,
    start_tick = step._baseline.tick, end_tick = final.tick,
    requested_duration_seconds = step.duration_seconds,
    duration_ticks = final.tick - step._baseline.tick,
    products_finished_before = step._baseline.products_finished_total,
    products_finished_after = final.products_finished_total,
    products_finished_delta = delta,
    character_transfer_actions = final.character_transfer_actions,
    downstream_kind = final.downstream_kind, blocked_output = final.blocked_output,
    source_cycles_observed = source_cycles, downstream_acceptance_samples = acceptance_samples,
    topology_ready = final.topology_ready, blockers = blockers, omitted_blockers = omitted_blockers,
    evidence_class = "bounded_multi_tick_component_validation",
    exact_remote_inventories = false, exact_remote_fluids = false,
  }
  plan.wait_started_tick, plan.next_check_tick = nil, nil
  if proven then factory_activity.record_validation(outcome, final._signature) end
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
    if step and (step.action == "wait_for_item" or step.action == "wait_for_research") and plan.wait_started_tick
      and game.tick - plan.wait_started_tick >= wait_timeout_ticks(step) then
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
      local errors = 0
      for _, entity in ipairs(response.entities or {}) do if entity.error then errors = errors + 1 end end
      return {
        status = errors > 0 and "partial" or "done",
        detail = string.format("inspected %d/%d entities locally at tick %d", #step.positions - errors, #step.positions, response.tick),
        outcome = { tick = response.tick, entities = response.entities, omitted_entities = errors,
          evidence_class = response.evidence_class,
          scope = "within_30_tiles_after_prior_physical_steps" },
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
function M.on_tick()
  if game.tick % PRUNE_INTERVAL_TICKS == 0 then for id, record in pairs(storage.tasks.records) do if game.tick - record.finished_tick > RECORD_TTL_TICKS then storage.tasks.records[id] = nil end end end
  expire_parked_waits(storage.tasks)
  if storage.tasks.active or #storage.tasks.queue > 0 then dispatch(storage.tasks) end
end
return M
