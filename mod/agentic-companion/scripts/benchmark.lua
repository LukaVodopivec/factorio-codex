-- Finite trial clock and frozen counters. Supervisor/recorder RPC only, never
-- a gameplay tool. Thirteen statistic reads; no entity or surface scan.
-- The score is automation: science packs labs consumed, then machine-made
-- plates, intermediates and packs (hand-crafts subtracted), then raw input.
local companion = require("scripts.companion")
local M = {}
local RAW = { "iron-ore", "copper-ore", "coal", "stone" }
local MADE = { "iron-plate", "copper-plate", "steel-plate", "iron-gear-wheel", "electronic-circuit",
  "automation-science-pack", "logistic-science-pack" }
local PACKS = { "automation-science-pack", "logistic-science-pack" }
local MUTATIONS = { enqueue = true, queue_plan = true, start_research = true, travel = true,
  create_platform = true, set_platform_route = true, set_requests = true, configure_entity = true,
  set_recipe = true, blueprint_capture = true, blueprint_create = true, blueprint_delete = true }

-- Native counters by key: an item name is produced, consumed:<pack> is a
-- lab's consumption and hand:<item> the Codex body's hand-crafts of it
-- (factory_activity's run-long counter, read from storage: requiring that
-- module would close a require cycle through jobs).
local function counts()
  local body = companion.require_present()
  local statistics = body.force.get_item_production_statistics(game.get_surface("nauvis"))
  local hand = storage.factory_activity and storage.factory_activity.hand_crafted or {}
  local out = {}
  for _, name in ipairs(RAW) do out[name] = statistics.get_input_count(name) end
  for _, name in ipairs(MADE) do out[name], out["hand:" .. name] = statistics.get_input_count(name), hand[name] or 0 end
  for _, name in ipairs(PACKS) do out["consumed:" .. name] = statistics.get_output_count(name) end
  return out
end

local function measured(b)
  local current, out = counts(), {}
  for key, value in pairs(current) do out[key] = value - (b.baseline[key] or 0) end
  return out
end

-- research: lab consumption of packs not made by hand; made: machine output.
-- A save frozen by an older release lacks newer keys: they read as zero.
local function score(m)
  local s, v = { research = 0, made = 0, raw = 0 }, function(key) return m[key] or 0 end
  for _, name in ipairs(PACKS) do s.research = s.research + math.max(0, v("consumed:" .. name) - v("hand:" .. name)) end
  for _, name in ipairs(MADE) do s.made = s.made + math.max(0, v(name) - v("hand:" .. name)) end
  for _, name in ipairs(RAW) do s.raw = s.raw + v(name) end
  return s
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
    or math.max(0, math.ceil((b.deadline_tick - (b.frozen_tick or game.tick)) / 60))
  local elapsed = b.status == "prepared" and 0 or math.max(0, ((b.frozen_tick or game.tick) - b.start_tick) / 60)
  local s = score(metrics)
  return { label = b.label, status = b.status, remaining_seconds = remaining, elapsed_seconds = elapsed,
    metrics = metrics, research = s.research, made = s.made, raw = s.raw,
    made_per_minute = elapsed > 0 and s.made * 60 / elapsed or 0 }
end

-- factory_status's compact trial clock for both roles (nil without a
-- benchmark): the panel's numbers, plus the seconds until the scored final
-- five minutes begin (0 once inside them).
function M.trial()
  local d = M.display()
  if not d then return nil end
  return { status = d.status, remaining_seconds = d.remaining_seconds, elapsed_seconds = math.floor(d.elapsed_seconds),
    final_window_in_seconds = math.max(0, d.remaining_seconds - 300),
    score = { research = d.research, made = d.made, raw = d.raw },
    made_per_minute = math.floor(d.made_per_minute * 10 + 0.5) / 10 }
end

return M
