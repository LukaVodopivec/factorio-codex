local M = {}
M.AUTONOMY_VERSION = 1
M.REGISTRY_VERSION = 1
M.PATCH_CACHE_VERSION = 1
-- Machine types the registry gained in 0.22 (a 0.21 registry holds these
-- entities in its other sets, not yet as machines).
M.MACHINE_TYPES_0_22 = { reactor = true, beacon = true, roboport = true }
-- Stores the registry gained in 0.22.2: an older registry never kept them,
-- so it rescans the charted chunks for them once.
M.STORE_TYPES_0_22_2 = { "cargo-landing-pad" }
-- Blueprint slots (blueprints.lua): 32 named blueprints and a scratch slot.
M.BLUEPRINT_SLOTS = 33

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
    -- A human hold in progress (tasks.enter_hold): {since}. Kept across a
    -- load so its ticks are still credited when it ends.
    human_hold = tasks.human_hold,
    -- The last pilot or package plan to reach a terminal status:
    -- {plan_id, status, tick}; upkeep plans are not kept here.
    last_plan_ended = tasks.last_plan_ended,
    -- The tick of the last cancel-all (emergency stop), absent before one.
    last_cancel_all_tick = tasks.last_cancel_all_tick,
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
  -- Hand-crafted items by name (factory_activity.on_player_crafted_item),
  -- counted from the tick this version first ran (0.22).
  if not activity.hand_crafted then
    activity.hand_crafted, activity.hand_crafted_since_tick = {}, game and game.tick or 0
  end
  -- Upkeep (chores.lua): unit_number -> tick of the last refuel attempt,
  -- and of the last science-pack delivery to a lab.
  storage.chores = storage.chores or {}
  storage.chores.refueled = storage.chores.refueled or {}
  storage.chores.fed_labs = storage.chores.fed_labs or {}
  -- The last finished research of the body's force (factory_status
  -- .on_research_changed): {technology, tick}, absent before the first.
  storage.last_research_finished = storage.last_research_finished
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
  -- Units of the machines sampled for problems only (beacons, roboports),
  -- and per chore status (no_fuel, missing_science_packs) the units in it,
  -- so upkeep reads those machines without walking every one (0.22).
  -- A 0.21 line store gains them on its next refresh, due at once.
  if not storage.autonomy.waiting then
    storage.autonomy.problem_only, storage.autonomy.waiting = {}, {}
    storage.autonomy.dirty_tick = storage.autonomy.dirty_tick or (game and game.tick or 0)
  end
  -- Own entities (registry.lua), kept by build/remove events. A new game or
  -- an upgrade from a save without it starts the bootstrap, which reads the
  -- charted chunks a few per tick until ready.
  local own = storage.registry
  if not own or own.version ~= M.REGISTRY_VERSION then
    storage.registry = {
      version = M.REGISTRY_VERSION, ready = false, force = nil,
      started_tick = game and game.tick or 0, ready_tick = nil,
      -- unit_number -> {entity, unit, name, type, position, surface, and
      -- the maintenance cursor's role, network, share and stock}
      entries = {},
      -- machines[type][unit]; the other sets are unit -> true.
      machines = {}, holders = {}, burners = {}, electric = {}, poles = {},
      -- Belts are counted, never listed.
      belts = {}, belt_count = 0,
      -- chunks: charted chunk positions to read (listed on the first tick);
      -- cursor: the next one. nil once ready.
      bootstrap = { chunks = nil, cursor = 1 },
      -- Filled below: order, cursor, write, pass_tick, networks, stock, types.
    }
  end
  -- Aggregates and the maintenance cursor (registry.lua, 0.22): the
  -- entries in cursor order, per network shares, per surface stock and type
  -- counts. A 0.21 registry keeps its entries and gains them here (pure
  -- Lua, no engine call), with the machine types 0.22 added; each entry's
  -- network, power role and stock arrive on the cursor's first pass.
  local r = storage.registry
  if not r.order then
    r.order, r.cursor, r.write, r.pass_tick = {}, 1, 1, nil
    r.networks, r.stock, r.types = {}, {}, {}
    for unit, entry in pairs(r.entries) do
      r.order[#r.order + 1] = unit
      local surface = entry.surface or 0
      r.types[surface] = r.types[surface] or {}
      local row = r.types[surface][entry.type] or { count = 0, nameplate_w = 0 }
      r.types[surface][entry.type], row.count = row, row.count + 1
      if M.MACHINE_TYPES_0_22[entry.type] then
        r.machines[entry.type] = r.machines[entry.type] or {}
        r.machines[entry.type][unit] = true
      end
    end
    table.sort(r.order)
  end
  if not r.store_types then
    r.store_types = 2
    -- A registry that read no chunk yet finds the stores in its bootstrap.
    if r.ready or r.bootstrap and r.bootstrap.chunks then
      r.rescan = { types = { table.unpack(M.STORE_TYPES_0_22_2) }, cursor = 1 }
    end
  end
  -- Resource patches per charted chunk (map_summary.patches): chunk key ->
  -- {cx, cy, cells = {[resource] = cell}} for chunks holding resources;
  -- known: every chunk read once. Pending chunks are (re)read a few per tick
  -- from head, seeded with every charted chunk on the first tick.
  -- 0.21 kept factory_status stock and power in a refresh cache; the
  -- registry's aggregates replace it.
  storage.status_cache = nil
  -- factory_status research: the available technologies, rebuilt on the
  -- next read after a load or upgrade and kept by the research events
  -- (factory_status.on_research_changed).
  storage.research_cache = nil
  -- charted: every charted chunk once, in the order it became known, and
  -- charted_set its keys (map_summary's chunk list, read without a query).
  local patch_cache = storage.patch_cache
  if not patch_cache or patch_cache.version ~= M.PATCH_CACHE_VERSION then
    storage.patch_cache = {
      version = M.PATCH_CACHE_VERSION, seeded = false, filled = false,
      chunks = {}, known = {}, pending = {}, head = 1, queued = {}, refresh = {}, dirty = true, rows = nil, updated_tick = nil,
      charted = {}, charted_set = {},
      -- The patch rows being rebuilt over ticks (map_summary.patch_tick), or nil.
      build = nil,
    }
  elseif not patch_cache.charted then
    -- A 0.21.0 cache: its known and queued chunks are the charted ones.
    local keys = {}
    for key in pairs(patch_cache.known) do keys[key] = true end
    for key in pairs(patch_cache.queued) do keys[key] = true end
    local list = {}
    for key in pairs(keys) do
      local x, y = key:match("^(-?%d+),(-?%d+)$")
      if x then list[#list + 1] = { x = tonumber(x), y = tonumber(y) } end
    end
    table.sort(list, function(a, b) return a.y == b.y and a.x < b.x or a.y < b.y end)
    patch_cache.charted, patch_cache.charted_set = list, {}
    for _, chunk in ipairs(list) do patch_cache.charted_set[chunk.x .. "," .. chunk.y] = true end
  end
  -- Space platforms (platforms.lua): the planet of each platform
  -- create_platform made while it waits for its starter pack, and the ring
  -- of the last space events (launches, platform states, landed cargo,
  -- ready rockets) with the tick of the newest.
  storage.space = storage.space or {}
  storage.space.created = storage.space.created or {}
  storage.space.events = storage.space.events or {}
  -- World policy write failures per surface (companion.lua), shown by ping.
  storage.world_policy = storage.world_policy or {}
  storage.world_policy.errors = storage.world_policy.errors or {}
  -- Heavy reads in progress and unread results (jobs.lua). Jobs are plain
  -- data and survive save, load and a mod upgrade: a kind this version no
  -- longer knows fails with its reason when it is next worked on.
  local jobs = storage.jobs or {}
  storage.jobs = { next_id = jobs.next_id or 1, by_id = jobs.by_id or {}, order = jobs.order or {}, tick = nil, used = 0 }
  -- Blueprints (blueprints.lua): real blueprint items in a script inventory,
  -- by_name: name -> {slot, entities, tiles, size, wires, source,
  -- created_tick}. An inventory that is gone takes its names with it.
  local blueprints = storage.blueprints or { by_name = {} }
  storage.blueprints = blueprints
  blueprints.by_name = blueprints.by_name or {}
  local ok, valid = pcall(function() return blueprints.inventory and blueprints.inventory.valid end)
  if not (ok and valid) then
    blueprints.inventory, blueprints.by_name = nil, {}
    if game and game.create_inventory then blueprints.inventory = game.create_inventory(M.BLUEPRINT_SLOTS) end
  elseif #blueprints.inventory < M.BLUEPRINT_SLOTS then
    blueprints.inventory.resize(M.BLUEPRINT_SLOTS)
  end
end

return M
