local M = {}
M.AUTONOMY_VERSION = 1
M.REGISTRY_VERSION = 1
M.PATCH_CACHE_VERSION = 1

-- Initializes the v7-compatible single-body storage schema. Safe to call repeatedly.
-- All fields any module needs MUST be declared here (single owner of the schema).
function M.init()
  -- Tasks: one flat queue and one optional active task for the sole Codex
  -- body. Rebuild only the canonical flat shape while retaining its data.
  local tasks = storage.tasks or {}
  storage.tasks = {
    next_id = tasks.next_id or 1,
    records = tasks.records or {},
    queue = tasks.queue or {},
    active = tasks.active,
    last_finished_tick = tasks.last_finished_tick,
    -- Human takeover (companion.human_control): the last real control input
    -- on the Codex client, absent when there never was one, and the walking
    -- state the mod last commanded.
    human_activity_tick = tasks.human_activity_tick,
    commanded_walk = tasks.commanded_walk,
    -- The last pilot or package plan to reach a terminal status:
    -- {plan_id, status, tick}; upkeep plans are not kept here.
    last_plan_ended = tasks.last_plan_ended,
  }
  -- Recent plan outcomes, oldest first (tasks.activity_log).
  storage.activity_log = storage.activity_log or {}

  -- At most one path request exists because only the sole active task runs.
  storage.path_request = nil
  -- chunked RPC responses: { next_id, by_id = { [id] = { parts = {...}, created_tick } } }
  storage.rpc_outbox = storage.rpc_outbox or { next_id = 1, by_id = {} }
  storage.factory_activity = storage.factory_activity or {
    epoch_tick = game and game.tick or 0, events = {}, events_omitted = 0,
  }
  -- 0.20 component proofs and their bookkeeping are gone.
  local activity = storage.factory_activity
  activity.validations, activity.validations_omitted, activity.supply_proof_tick = nil, nil, nil
  activity.target_last_tick, activity.target_last_tick_after = nil, nil
  -- Upkeep (chores.lua): unit_number -> tick of the last refuel attempt.
  storage.chores = storage.chores or {}
  storage.chores.refueled = storage.chores.refueled or {}
  -- Thought feed (thoughts.lua): Astra's NOW line and the last shown lines.
  storage.thoughts = storage.thoughts or { now = nil, lines = {} }
  -- Factory lines (autonomy.lua). Rebuilt from the map on any version change;
  -- entity references stay valid across save and load.
  local autonomy = storage.autonomy
  if not autonomy or autonomy.version ~= M.AUTONOMY_VERSION then
    storage.autonomy = {
      version = M.AUTONOMY_VERSION,
      dirty_tick = game and game.tick or 0, last_refresh_tick = nil,
      next_line_id = 1, lines = {}, line_order = {},
      -- Sampled machines by unit_number, per sampler bucket (tick % 30), and
      -- by position key.
      machines = {}, buckets = {}, machine_at = {},
      -- position key -> tick of the last character transfer into it.
      transfer_tick = {},
      problem_count = 0, last_problem_tick = nil,
      -- The last refresh failure, if any.
      refresh_error = nil,
    }
  end
  storage.autonomy.patches = nil -- replaced by storage.patch_cache
  -- Own entities (registry.lua), kept by build/remove events. A new game or
  -- an upgrade from a save without it starts the bootstrap, which reads the
  -- charted chunks a few per tick until ready.
  local registry = storage.registry
  if not registry or registry.version ~= M.REGISTRY_VERSION then
    storage.registry = {
      version = M.REGISTRY_VERSION, ready = false, force = nil,
      started_tick = game and game.tick or 0, ready_tick = nil,
      -- unit_number -> {entity, unit, name, type, position, surface}
      entries = {},
      -- machines[type][unit]; the other sets are unit -> true.
      machines = {}, holders = {}, burners = {}, electric = {}, poles = {},
      -- Belts are counted, never listed.
      belts = {}, belt_count = 0,
      -- chunks: charted chunk positions to read (listed on the first tick);
      -- cursor: the next one. nil once ready.
      bootstrap = { chunks = nil, cursor = 1 },
    }
  end
  -- Resource patches per charted chunk (map_summary.patches): chunk key ->
  -- {cx, cy, cells = {[resource] = cell}} for chunks holding resources;
  -- known: every chunk read once. Pending chunks are (re)read a few per tick
  -- from head, seeded with every charted chunk on the first tick.
  -- factory_status stock and power (map_summary.status_tick): the last
  -- finished sections and the refresh job in progress, restarted on load.
  local status_cache = storage.status_cache or {}
  status_cache.job = nil
  storage.status_cache = status_cache
  -- factory_status research: the available technologies, dropped by every
  -- research event (factory_status.on_research_changed).
  storage.research_cache = nil
  local patch_cache = storage.patch_cache
  if not patch_cache or patch_cache.version ~= M.PATCH_CACHE_VERSION then
    storage.patch_cache = {
      version = M.PATCH_CACHE_VERSION, seeded = false, filled = false,
      chunks = {}, known = {}, pending = {}, head = 1, queued = {}, refresh = {}, dirty = true, rows = nil, updated_tick = nil,
    }
  end
end

return M
