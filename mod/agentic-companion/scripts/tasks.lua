-- Sole-body FIFO dispatcher. Plans are atomic queue entries whose steps run
-- contiguously on tick, so RCON cannot interleave physical work.
local companion = require("scripts.companion")
local items = require("scripts.items")
local inspect = require("scripts.inspect")
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
local placement_geometry = require("scripts.placement_geometry")
local factory_activity = require("scripts.factory_activity")
local autonomy = require("scripts.autonomy")
local M = {}
local RECORD_TTL_TICKS, PRUNE_INTERVAL_TICKS = 5 * 60 * 60, 3600
-- A plan's active budget: 570 s, or 12 s per step for long build packages.
local PLAN_BUDGET_TICKS, STEP_BUDGET_TICKS = 570 * 60, 12 * 60
local MAX_PLAN_STEPS = 200
local ACTIVITY_LOG_SIZE = 64
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
-- Plan actions other modules add (get_items, build_layout, ...): spec is
-- { runner = {start, tick, resume?}, make_task = function(step) -> task,
-- validate = function(step, index) (optional, raises on a bad step),
-- budget_steps = function(step) -> n (optional: the step's share of the
-- plan's active budget, counted in ordinary steps), remote = function(step)
-- -> boolean (optional: the step acts on a space platform without the body,
-- so it carries no surface tag) }. A runner may add waiting(task) -> boolean
-- (a deliberate wait the step watchdog leaves alone) and cancelled(task) ->
-- table (what a cancel of the running step reports).
local extensions = {}
function M.register_action(action, spec)
  assert(type(action) == "string" and type(spec) == "table" and type(spec.runner) == "table"
    and type(spec.make_task) == "function", "register_action requires an action name, runner and make_task")
  extensions[action] = spec
  runners[action] = spec.runner
end
-- Who queued a plan: the pilot (default), the mod's own upkeep, or the
-- bridge for one of Astra's build packages.
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
-- The owner's real control input on the Codex client holds the body (companion.human_control
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
  -- get_items and auto-supply may hand-craft inside any step.
  return current and (current.type == "craft" or current.type == "build_plan" or current.type == "get_items"
    or current.type == "build_layout" or current.type == "build_block" or current.type == "blueprint_place"
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
  if ok then plan.observation = value else plan.observation_error = tostring(value) end
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
-- activity_log: the last ACTIVITY_LOG_SIZE plan outcomes, so a reader sees
-- what the body did without polling each plan.
local function upkeep_readback(plan)
  if plan.source ~= "upkeep" then return nil end
  local targets = {}
  local first = plan.completed_steps + 1
  local stop = math.min(#plan.steps, first + 15)
  for index = first, stop do
    local step, requested, count, capped = plan.steps[index], {}, 0, false
    for name, amount in pairs(step.items or {}) do
      if count >= 8 then capped = true; break end
      requested[name], count = amount, count + 1
    end
    local outcome = plan.outcomes[index]
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
local function log_plan(plan, detail)
  local last = plan.outcomes[#plan.outcomes]
  local result = last and type(last.result) == "table" and last.result or nil
  local reason = last and last.error or detail
  local code = result and type(result.code) == "string" and result.code
    or plan.preempted and "PREEMPTED"
    or type(reason) == "string" and reason:match("^([A-Z][A-Z0-9_]+[A-Z0-9])") or nil
  local summary
  if plan.status == "completed" then
    summary = string.format("completed %d/%d steps", plan.completed_steps, #plan.steps)
  else
    summary = string.format("%s at step %d/%d%s%s", plan.status, last and last.step or plan.current_step, #plan.steps,
      last and last.action and (" " .. last.action) or "",
      type(reason) == "string" and reason ~= "" and (": " .. reason:sub(1, 160)) or "")
  end
  local log = storage.activity_log or {}
  storage.activity_log = log
  log[#log + 1] = { plan_id = plan.id, source = plan.source or "pilot", steps = #plan.steps,
    status = plan.status, code = code, summary = summary, start_tick = plan.started_tick, end_tick = game.tick,
    surface = plan.surface, upkeep = upkeep_readback(plan) }
  while #log > ACTIVITY_LOG_SIZE do table.remove(log, 1) end
  -- next_event wakes the pilot on this: the mod's own upkeep (often
  -- pre-empted) is in activity_log only.
  if plan.source ~= "upkeep" then
    storage.tasks.last_plan_ended = { plan_id = plan.id, status = plan.status, tick = game.tick, surface = plan.surface }
  end
end
-- keep_crafting: a surface change cancels plans but never hand-crafting.
local function finish(task, status, detail, preserve_body, outcome, keep_crafting)
  if status == "cancelled" and not keep_crafting and task_crafts(task) then cancel_crafting() end
  if storage.tasks.active and storage.tasks.active.id == task.id then storage.tasks.active = nil end
  storage.tasks.last_finished_tick = game.tick
  if not preserve_body then stop_body() end
  if task.type == "plan" then
    task.finished_tick = game.tick
    task.final_inventory = inventory_snapshot()
    observe_terminal(task)
    local final_status = status == "done" and "completed" or status
    if final_status == "completed" and task.observation_error then final_status = "failed" end
    set_plan_status(task, final_status)
    log_plan(task, detail)
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
M.register_action("build_block", build_layout.block_action)
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
  -- the body's own; a travel step hands its destination to the steps after it.
  local current
  if params.surface ~= nil then
    local ref, code, why = platforms.canonical_ref(present.force, params.surface)
    if not ref then error(code .. ": queue_plan surface: " .. why, 0) end
    current = ref
  else
    local pending = fifo_travel()
    current = pending[#pending] or body_surface()
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
  return { plan_id = assign(plan), after_plan_id = predecessor, body_idle_ticks = body_idle_ticks,
    human_control = plan.human_control }
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

-- A running step ends from outside (a cancel, the plan's budget): its
-- runner's cancelled hook, if any, lets go of what it holds (a travel step's
-- launch marker). Returns the hook's note, or nil.
local function step_cancelled(plan)
  local task = plan.current_task
  local runner = task and runners[task.type]
  local noted, note = pcall(function() return runner and runner.cancelled and runner.cancelled(task) or nil end)
  return noted and note or nil
end

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
      finish(tasks.active, "cancelled", detail); n = n + 1
    end
    cancel_crafting()
    -- Emergency cancellation is not the next plan's idle time.
    tasks.last_finished_tick = nil
    tasks.last_cancel_all_tick = game.tick
    log_cancel(origin, nil, n)
    return { cancelled = n }
  end
  local id = tonumber(params.task_id or params.plan_id)
  if not id then error("cancel requires task_id, plan_id, or all=true") end
  if tasks.active and tasks.active.id == id then
    record_cancelled_step(tasks.active)
    finish(tasks.active, "cancelled", detail)
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
function M.active_summary()
  local active = storage.tasks.active
  if not active then return nil end
  if active.type == "plan" then
    local step = active.steps[active.current_step]
    return { id = active.id, type = "plan", status = "running", current_step = active.current_step,
      total_steps = #active.steps, action = step and step.action, source = active.source or "pilot" }
  end
  return { id = active.id, type = active.type, status = "running" }
end
-- activity_log {since_plan_id?, limit?}: recent plan outcomes, oldest first.
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
  return { tick = game.tick, entries = rows, omitted = omitted }
end
function M.queue_length() return #storage.tasks.queue end

-- Steps that can add, remove or reconfigure machines refresh the factory
-- lines (script-created entities raise no player build event).
local TOPOLOGY_TASKS = { place = true, mine = true, set_recipe = true, rotate = true, build_plan = true }
local function finish_step(plan, result)
  local kind = plan.current_task and plan.current_task.type
  factory_activity.record(kind, result.outcome)
  if kind and (TOPOLOGY_TASKS[kind] or extensions[kind]) then autonomy.mark_dirty() end
  local step = plan.steps[plan.current_step]
  local status = result.status == "done" and "completed" or result.status
  local recovery = plan._recovery
  plan.outcomes[#plan.outcomes + 1] = {
    step = plan.current_step, action = step.action, status = status,
    upkeep_context = plan.source == "upkeep" and supply.diagnostics(plan.current_task) or nil,
    result = result.outcome or ((status == "completed" or status == "partial") and (result.detail or status) or nil),
    error = (status == "failed" or status == "cancelled") and (result.detail or status) or nil,
    recovery = recovery and recovery.step == plan.current_step and { code = recovery.code,
      fix = recovery.fix and recovery.fix.type or (recovery.items and "retry_remainder" or "retry"),
      fix_error = recovery.fix_error } or nil,
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
-- Actions a save from an older version may still hold.
local REMOVED_ACTIONS = { validate_factory_component = true }
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
-- Deterministic recoveries: at most one bounded physical fix per step, then
-- the same step runs again from scratch; a fix that fails returns the
-- step's original result.
local function result_code(result)
  local outcome = type(result.outcome) == "table" and result.outcome or nil
  if outcome and type(outcome.code) == "string" then return outcome.code end
  local detail = type(result.detail) == "string" and result.detail or ""
  if detail:find("CODEX_BODY_OVERLAP", 1, true) then return "CODEX_BODY_OVERLAP" end
  if detail:find("couldn't get within physical reach", 1, true) then return "TARGET_OUT_OF_REACH" end
  return detail:match("^([A-Z][A-Z0-9_]+[A-Z0-9])")
end
-- A tile beside the placement footprint, clear for the body, nearest first.
local function footprint_exit(task)
  local c = companion.get()
  local item = c and prototypes.item[task.item]
  local proto = item and item.place_result
  if not proto then return nil end
  local area = placement_geometry.footprint(proto, task.position, task.direction)
  local p, lt, rb = c.position, area.left_top, area.right_bottom
  local candidates = { { x = p.x, y = lt.y - 2 }, { x = p.x, y = rb.y + 2 },
    { x = lt.x - 2, y = p.y }, { x = rb.x + 2, y = p.y } }
  table.sort(candidates, function(a, b)
    local da = (a.x - p.x) ^ 2 + (a.y - p.y) ^ 2
    local db = (b.x - p.x) ^ 2 + (b.y - p.y) ^ 2
    if da ~= db then return da < db end
    return a.y == b.y and a.x < b.x or a.y < b.y
  end)
  for _, candidate in ipairs(candidates) do
    local ok, clear = pcall(c.surface.find_non_colliding_position, c.name or "character", candidate, 0.5, 0.1)
    if ok and clear and not placement_geometry.overlaps(area,
      { left_top = { x = clear.x - 1.25, y = clear.y - 1.25 }, right_bottom = { x = clear.x + 1.25, y = clear.y + 1.25 } }) then
      return { x = clear.x, y = clear.y }
    end
  end
end
local function try_recover(plan, step, result)
  if result.status == "done" or plan._recovery and plan._recovery.step == plan.current_step then return false end
  local failed, code = plan.current_task, result_code(result)
  local recovery = { step = plan.current_step, code = code, first = result }
  if code == "BODY_ENCLOSED" then
    local ok, suggested = pcall(function() return result.outcome.diagnostics.path.suggested_recovery end)
    if not ok or type(suggested) ~= "table" then return false end
    recovery.fix = { type = "mine", target = { x = suggested.x, y = suggested.y }, count = 1,
      target_kind = "owned", expected_name = suggested.expected_name }
  elseif code == "CODEX_BODY_OVERLAP" and failed and failed.type == "place" then
    local ok, exit = pcall(footprint_exit, failed)
    if not ok or not exit then return false end
    recovery.fix = { type = "walk_to", target = exit, arrival_mode = "exact", arrival_radius = 1 }
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
local function step_recovery(plan)
  local recovery = plan._recovery
  local result
  if recovery.fix then
    local ok, value = pcall(runners[recovery.fix.type].tick, recovery.fix)
    result = ok and value or not ok and { status = "failed", detail = tostring(value) } or nil
  elseif game.tick >= recovery.resume_tick then
    result = { status = "done" }
  end
  if not result then return true end
  plan.current_task = nil
  if result.status ~= "done" then
    recovery.phase, recovery.fix_error = "failed", result.detail
    finish_step(plan, recovery.first)
    return true
  end
  recovery.phase = "retrying"
  return false
end
local function tick_plan(plan)
  local budget = math.max(PLAN_BUDGET_TICKS, (plan.budget_steps or #plan.steps) * STEP_BUDGET_TICKS)
  if game.tick - plan.started_tick >= budget then
    local detail = string.format("plan exceeded its %d-second active budget", budget / 60)
    if plan.current_task then
      local note = step_cancelled(plan)
      finish_step(plan, { status = "failed", detail = detail, outcome = note })
    else finish(plan, "failed", detail) end
    return
  end
  if plan._recovery and plan._recovery.phase == "fixing" and step_recovery(plan) then return end
  if not plan.current_task then
    -- The mod's own upkeep gives way to any queued plan at a step boundary.
    if plan.source == "upkeep" and plan.completed_steps > 0 then
      for _, queued in ipairs(storage.tasks.queue) do
        if queued.type == "plan" and queued.source ~= "upkeep" then
          plan.preempted = true
          finish(plan, "cancelled", "PREEMPTED: queued work takes the body")
          return
        end
      end
    end
    plan.current_step = plan.completed_steps + 1
    local step = plan.steps[plan.current_step]
    if REMOVED_ACTIONS[step.action] then
      -- A step saved by an older version: complete it as a no-op.
      plan.wait_started_tick, plan.next_check_tick = nil, nil
      finish_step(plan, { status = "done", detail = "REMOVED_ACTION: " .. step.action .. " no longer exists",
        outcome = { code = "REMOVED_ACTION", action = step.action } })
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
      local ok, err = pcall(runners[plan.current_task.type].start, plan.current_task)
      if not ok then finish_step(plan, { status = "failed", detail = tostring(err) }); return end
    end
  end
  local step, ok, result = plan.steps[plan.current_step]
  if step.action == "wait_for_item" then ok, result = pcall(wait_for_item, plan, step)
  elseif step.action == "wait_for_research" then ok, result = pcall(wait_for_research, plan, step)
  elseif REMOVED_ACTIONS[step.action] then
    ok, result = true, { status = "done", detail = "REMOVED_ACTION: " .. step.action .. " no longer exists",
      outcome = { code = "REMOVED_ACTION", action = step.action } }
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
  if not ok then result = { status = "failed", detail = tostring(result) } end
  if result and not try_recover(plan, step, result) then finish_step(plan, result) end
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
      -- A candidate the predecessor check just cancelled leaves the queue,
      -- even while it is parked.
      if candidate.status == "cancelled" then -- dropped
      elseif parked or predecessor_blocked then tasks.queue[#tasks.queue + 1] = candidate
      else task = candidate; break end
    end
    if not task then return end
    if task.type == "plan" then set_plan_status(task, "running") else task.status = "running" end
    task.started_tick, tasks.active = task.started_tick or game.tick, task
    if task.type == "plan" and task.start_inventory == nil then task.start_inventory = inventory_snapshot() end
    if task.type ~= "plan" then local ok, err = pcall(runners[task.type].start, task); if not ok then finish(task, "failed", tostring(err)); return end end
  end
  if task.type == "plan" then tick_plan(task); return end
  local ok, result = pcall(runners[task.type].tick, task)
  if not ok then finish(task, "failed", tostring(result)) elseif result then
    factory_activity.record(task.type, result.outcome)
    if TOPOLOGY_TASKS[task.type] then autonomy.mark_dirty() end
    finish(task, result.status, result.detail, nil, result.outcome)
  end
end
-- The step watchdog. No single step may hold the FIFO for minutes: a running
-- plan step or direct task fails with STEP_STALLED once the body's position,
-- its inventory, its hand-crafting and mining, and the step's own progress
-- have all stood still for STALL_TICKS. Deliberate waits are exempt:
-- wait_for_item and wait_for_research park the plan (it is not running), a
-- crafting queue that advances is progress, and a human hold stops the
-- watchdog and restarts its clock. Its state (storage.tasks.stall) is made
-- when first needed, so a save from before it needs no migration.
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
local function body_signature(c, progress)
  local parts = {}
  for _, item in ipairs(c.get_main_inventory and c.get_main_inventory() and c.get_main_inventory().get_contents() or {}) do
    parts[#parts + 1] = tostring(item.name) .. ":" .. tostring(item.quality or "") .. "=" .. tostring(item.count)
  end
  table.sort(parts)
  for _, member in ipairs({ "crafting_queue_size", "crafting_queue_progress", "character_mining_progress" }) do
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
  local ok, signature = pcall(body_signature, c, progress)
  if not ok then tasks.stall = nil; return false end
  local p = c.position
  local function beyond(anchor)
    return not anchor or (p.x - anchor.x) ^ 2 + (p.y - anchor.y) ^ 2 > STALL_MOVE_SQ
  end
  local moved = beyond(stall.anchor) and beyond(stall.previous)
  if beyond(stall.anchor) then stall.previous, stall.anchor = stall.anchor, { x = p.x, y = p.y } end
  if moved or signature ~= stall.signature or not stall.since then
    stall.since, stall.signature = game.tick, signature
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
  storage.path_request, task._path_result = nil, nil
  if plan then finish_step(plan, { status = "failed", detail = detail, outcome = outcome })
  else finish(task, "failed", detail, nil, outcome) end
  return true
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
      local result = { status = "failed", detail = tostring(err) }
      if task.type == "plan" then finish_step(task, result) else finish(task, "failed", result.detail) end
    end
  end
end
local function leave_hold(tasks)
  local held_ticks = game.tick - tasks.human_hold.since
  tasks.human_hold = nil
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
function M.on_tick()
  if game.tick % PRUNE_INTERVAL_TICKS == 0 then for id, record in pairs(storage.tasks.records) do if game.tick - record.finished_tick > RECORD_TTL_TICKS then storage.tasks.records[id] = nil end end end
  local tasks = storage.tasks
  local current = tasks.active and tasks.active.current_task
  local runner = current and runners[current.type]
  -- Pure bounded cargo observation continues through holds; native robots
  -- keep working while the body is parked. This never orders any action.
  if runner and runner.observe then runner.observe(current) end
  pcall(companion.poll_human_activity, tasks.human_hold ~= nil)
  if human_control() then
    if not tasks.human_hold then enter_hold(tasks) end
    -- The owner playing the body is not idle time.
    if tasks.last_finished_tick then tasks.last_finished_tick = game.tick end
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
