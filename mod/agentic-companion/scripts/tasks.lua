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

local function cancel_task_crafting(task)
  if task.type ~= "craft" and task.type ~= "build_plan" then return end
  local c = companion.get()
  if not c then return end
  local queue = c.crafting_queue or {}
  for index = #queue, 1, -1 do
    c.cancel_crafting({ index = index, count = queue[index].count })
  end
end

local function finish(task, status, detail)
  if status == "cancelled" then cancel_task_crafting(task) end
  storage.tasks.records[task.id] = {
    status = status,
    detail = detail or "",
    finished_tick = game.tick,
  }
  local tasks = storage.tasks
  if tasks.active and tasks.active.id == task.id then
    tasks.active = nil
  end
  stop_body()
end

local function cancel_all()
  local tasks = storage.tasks
  local n = 0
  for _, q in ipairs(tasks.queue) do
    tasks.records[q.id] = { status = "cancelled", detail = "", finished_tick = game.tick }
    n = n + 1
  end
  tasks.queue = {}
  if tasks.active then
    finish(tasks.active, "cancelled", "")
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
  t.queue[#t.queue + 1] = task
  return { task_id = task.id }
end

function M.get(params)
  local id = tonumber(params.task_id)
  if not id then error("get_task requires task_id") end
  local tasks = storage.tasks
  if tasks.active and tasks.active.id == id then
    return { status = "running", detail = "" }
  end
  for _, q in ipairs(tasks.queue) do
    if q.id == id then return { status = "queued", detail = "" } end
  end
  local rec = tasks.records[id]
  if rec then return { status = rec.status, detail = rec.detail } end
  error("unknown task_id: " .. id)
end

function M.cancel(params)
  local n = 0
  if params.all then
    n = cancel_all()
  else
    local id = tonumber(params.task_id)
    if not id then error("cancel requires task_id or all=true") end
    local tasks = storage.tasks
    if tasks.active and tasks.active.id == id then
      finish(tasks.active, "cancelled", "")
      n = 1
    else
      for i, q in ipairs(tasks.queue) do
        if q.id == id then
          table.remove(tasks.queue, i)
          tasks.records[id] = { status = "cancelled", detail = "", finished_tick = game.tick }
          n = 1
          break
        end
      end
    end
  end
  return { cancelled = n }
end

-- Serializable summary of Codex's active task for observe_local.
function M.active_summary()
  local a = storage.tasks.active
  if not a then return nil end
  return { id = a.id, type = a.type, status = "running" }
end

function M.queue_length()
  return #storage.tasks.queue
end

local function prune_records()
  local t = storage.tasks
  for id, rec in pairs(t.records) do
    if game.tick - rec.finished_tick > RECORD_TTL_TICKS then
      t.records[id] = nil
    end
  end
end

local function step_task_queue(tasks)
  local task = tasks.active
  if not task then
    if #tasks.queue == 0 then return end
    task = table.remove(tasks.queue, 1)
    task.status = "running"
    tasks.active = task
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
  local tasks = storage.tasks
  if tasks.active or #tasks.queue > 0 then
    step_task_queue(tasks)
  end
end

return M
