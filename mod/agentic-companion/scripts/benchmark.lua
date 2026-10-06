-- Finite trial clock and frozen counters. Supervisor/recorder RPC only, never
-- a gameplay tool. Six statistic reads; no entity or surface scan.
local companion = require("scripts.companion")
local M = {}
local ITEMS = { "iron-ore", "copper-ore", "coal", "stone", "iron-plate", "copper-plate" }
local MUTATIONS = { enqueue = true, queue_plan = true, start_research = true, travel = true,
  create_platform = true, set_platform_route = true, set_requests = true, configure_entity = true,
  set_recipe = true, blueprint_capture = true, blueprint_create = true, blueprint_delete = true }

local function counts()
  local body = companion.require_present()
  local surface = game.get_surface("nauvis")
  local statistics = body.force.get_item_production_statistics(surface)
  local out = {}
  for _, name in ipairs(ITEMS) do out[name] = statistics.get_input_count(name) end
  return out
end

local function measured(b)
  local current, out = counts(), {}
  for _, name in ipairs(ITEMS) do out[name] = current[name] - b.baseline[name] end
  return out
end

function M.assert_action(method)
  local b = storage.benchmark
  if b and b.status ~= "running" and MUTATIONS[method] then
    error("BENCHMARK_CLOSED: no physical or package writes before GO or after cutoff", 0)
  end
end

function M.freeze(reason)
  local b = storage.benchmark
  if not b then error("no benchmark is prepared", 0) end
  if b.status == "frozen" then return b end
  game.tick_paused = true
  b.start_tick = b.start_tick or game.tick
  b.deadline_tick = b.deadline_tick or game.tick
  b.metrics = measured(b)
  b.frozen_tick, b.freeze_reason, b.status = game.tick, reason, "frozen"
  if M.on_freeze then M.on_freeze() end
  return b
end

function M.control(params)
  if params.action == "prepare" then
    if storage.benchmark then error("a fresh save is required for another trial", 0) end
    if game.speed ~= 1 then error("benchmark requires normal game speed", 0) end
    if type(params.run_id) ~= "string" or not params.run_id:match("^[a-zA-Z0-9_-]+$") or #params.run_id > 160 then
      error("benchmark run_id must be 1-160 letters, digits, underscores or dashes", 0)
    end
    local duration = params.duration_seconds or 1200
    if type(duration) ~= "number" or duration % 1 ~= 0 or duration < 1 or duration > 1200 then
      error("benchmark duration_seconds must be an integer from 1 to 1200", 0)
    end
    local body = companion.require_present()
    if body.state ~= "on_surface" or body.surface_ref ~= "nauvis" or not body.character then
      error("benchmark preparation requires a living character on Nauvis", 0)
    end
    local baseline = counts()
    if storage.tasks and (storage.tasks.active or #(storage.tasks.queue or {}) > 0) then
      error("benchmark preparation requires an empty physical queue", 0)
    end
    if (companion.require_present().character.crafting_queue_size or 0) > 0 then
      error("benchmark preparation requires no character crafting", 0)
    end
    if type(params.label) ~= "nil" and (type(params.label) ~= "string" or #params.label > 600) then
      error("benchmark label must be at most 600 bytes", 0)
    end
    if type(params.summary) ~= "nil" and (type(params.summary) ~= "string" or #params.summary > 600) then
      error("benchmark summary must be at most 600 bytes", 0)
    end
    game.tick_paused = true
    storage.benchmark = { run_id = params.run_id, status = "prepared", duration_seconds = duration,
      baseline = baseline, label = params.label or params.run_id, summary = params.summary }
  else
    local b = storage.benchmark
    if not b or params.run_id ~= b.run_id then error("benchmark run identity differs", 0) end
    if params.action == "begin" then
      if b.status ~= "prepared" then error("benchmark GO cannot be released twice", 0) end
      b.baseline, b.start_tick, b.status = counts(), game.tick, "running"
      b.deadline_tick = game.tick + b.duration_seconds * 60
      game.tick_paused = false
    elseif params.action == "freeze" then M.freeze("recorder")
    elseif params.action ~= "status" then error("benchmark action must be prepare, begin, freeze or status", 0) end
  end
  return storage.benchmark
end

function M.on_tick(tick)
  local b = storage.benchmark
  if b and b.status == "running" and companion.human_control() then b.assisted = true end
  if b and b.status == "running" and tick >= b.deadline_tick then M.freeze("tick_deadline") end
  return b and b.status ~= "running"
end

function M.display()
  local b = storage.benchmark
  if not b then return nil end
  local metrics = b.status == "frozen" and b.metrics or measured(b)
  local remaining = b.status == "prepared" and b.duration_seconds
    or math.max(0, math.ceil((b.deadline_tick - game.tick) / 60))
  local elapsed = b.status == "prepared" and 0 or math.max(0, ((b.frozen_tick or game.tick) - b.start_tick) / 60)
  local total, plates = 0, metrics["iron-plate"] + metrics["copper-plate"]
  for i = 1, 4 do total = total + metrics[ITEMS[i]] end
  return { label = b.label, status = b.status, remaining_seconds = remaining, metrics = metrics,
    input_per_minute = elapsed > 0 and total * 60 / elapsed or 0,
    output_per_minute = elapsed > 0 and plates * 60 / elapsed or 0 }
end

return M
