-- Task queue + per-tick dispatcher. RCON calls enqueue; execution happens in
-- on_tick (always registered, early-exit when idle); the companion app polls
-- get_task for completion.
local companion = require("scripts.companion")
local walk = require("scripts.actions.walk")
local mine = require("scripts.actions.mine")
local build = require("scripts.actions.build")
local craft = require("scripts.actions.craft")
local transfer = require("scripts.actions.transfer")
local build_plan = require("scripts.actions.build_plan")

local M = {}

local RECORD_TTL_TICKS = 5 * 60 * 60 -- keep finished-task records for 5 minutes
local PRUNE_INTERVAL_TICKS = 3600

local runners = {
  walk_to = walk,
  mine = mine,
  place = build.place,
  rotate = build.rotate,
  set_recipe = build.set_recipe,
  craft = craft,
  insert = transfer.insert,
  extract = transfer.extract,
  build_plan = build_plan,
}

-- The retained storage shape has one fixed lane for the sole Codex body.
local function lane()
  local l = storage.tasks.lane
  if not l then
    l = { queue = {}, active = nil }
    storage.tasks.lane = l
  end
  return l
end

local function stop_body()
  local c = companion.get()
  if c then
    c.walking_state = { walking = false }
    c.mining_state = { mining = false }
    pcall(function()
      c.shooting_state = { state = defines.shooting.not_shooting }
    end)
  end
end

-- finish() runs with the companion context already set to the task's owner.
local function finish(task, status, detail)
  storage.tasks.records[task.id] = {
    status = status,
    detail = detail or "",
    finished_tick = game.tick,
  }
  local l = lane()
  if l.active and l.active.id == task.id then
    l.active = nil
  end
  stop_body()

  -- A failed step of a plan takes its dependent siblings down with it: later
  -- steps of the same chain are cancelled so the brain gets ONE failure event
  -- instead of a cascade ("insert the plates" can't work if the craft failed).
  -- The chain is also remembered as failed: a fast failure can beat the
  -- remaining enqueue RPCs to the punch, so late arrivals of the same chain
  -- are cancelled at enqueue time (see M.enqueue).
  if status == "failed" and task.chain then
    storage.tasks.failed_chains = storage.tasks.failed_chains or {}
    storage.tasks.failed_chains[task.chain] = game.tick
    local l2 = lane()
    local kept = {}
    for _, q in ipairs(l2.queue) do
      if q.chain == task.chain then
        storage.tasks.records[q.id] = {
          status = "cancelled",
          detail = "skipped: an earlier step of the same plan failed",
          finished_tick = game.tick,
        }
      else
        kept[#kept + 1] = q
      end
    end
    l2.queue = kept
  end

end

local function cancel_lane()
  local l = lane()
  local n = 0
  for _, q in ipairs(l.queue) do
    storage.tasks.records[q.id] = { status = "cancelled", detail = "", finished_tick = game.tick }
    n = n + 1
  end
  l.queue = {}
  if l.active then
    finish(l.active, "cancelled", "")
    n = n + 1
  end
  return n
end

function M.enqueue(params)
  local task = params.task
  if type(task) ~= "table" or not runners[task.type] then
    error("unknown task type: " .. tostring(type(task) == "table" and task.type or task))
  end
  companion.require_companion()
  local t = storage.tasks
  task.id = t.next_id
  t.next_id = t.next_id + 1
  task.status = "queued"
  if params.chain ~= nil then task.chain = tostring(params.chain) end

  -- Late arrival of an already-failed plan: cancel silently right here (the
  -- failure that killed the chain already produced its one event).
  local fc = storage.tasks.failed_chains
  if task.chain and fc and fc[task.chain] then
    t.records[task.id] = {
      status = "cancelled",
      detail = "skipped: an earlier step of the same plan failed",
      finished_tick = game.tick,
    }
    return { task_id = task.id, cancelled = true }
  end

  local l = lane()
  l.queue[#l.queue + 1] = task
  return { task_id = task.id }
end

function M.get(params)
  local id = tonumber(params.task_id)
  if not id then error("get_task requires task_id") end
  local l = lane()
  if l.active and l.active.id == id then
    return { status = "running", detail = "" }
  end
  for _, q in ipairs(l.queue) do
    if q.id == id then return { status = "queued", detail = "" } end
  end
  local rec = storage.tasks.records[id]
  if rec then return { status = rec.status, detail = rec.detail } end
  error("unknown task_id: " .. id)
end

function M.cancel(params)
  local n = 0
  if params.all then
    n = cancel_lane()
  else
    local id = tonumber(params.task_id)
    if not id then error("cancel requires task_id or all=true") end
    local l = lane()
    if l.active and l.active.id == id then
      finish(l.active, "cancelled", "")
      n = 1
    else
      for i, q in ipairs(l.queue) do
        if q.id == id then
          table.remove(l.queue, i)
          storage.tasks.records[id] = { status = "cancelled", detail = "", finished_tick = game.tick }
          n = 1
          break
        end
      end
    end
  end
  return { cancelled = n }
end

-- Serializable summary of a companion's active task for get_state.
function M.active_summary()
  local a = lane().active
  if not a then return nil end
  return { id = a.id, type = a.type, status = "running" }
end

function M.queue_length()
  return #lane().queue
end

local function prune_records()
  local t = storage.tasks
  for id, rec in pairs(t.records) do
    if game.tick - rec.finished_tick > RECORD_TTL_TICKS then
      t.records[id] = nil
    end
  end
  for chain, tick in pairs(t.failed_chains or {}) do
    if game.tick - tick > RECORD_TTL_TICKS then
      t.failed_chains[chain] = nil
    end
  end
end

local function step_lane(l)
  local task = l.active
  if not task then
    if #l.queue == 0 then return end
    task = table.remove(l.queue, 1)
    task.status = "running"
    l.active = task
    local ok, err = pcall(runners[task.type].start, task)
    if not ok then
      finish(task, "failed", tostring(err))
      return
    end
  end

  local ok, result = pcall(runners[task.type].tick, task)
  if not ok then
    finish(task, "failed", tostring(result))
  elseif result then
    finish(task, result.status, result.detail)
  end
end

function M.on_tick()
  if game.tick % PRUNE_INTERVAL_TICKS == 0 then
    prune_records()
  end
  local l = lane()
  if l.active or #l.queue > 0 then
    step_lane(l)
  end
end

return M
