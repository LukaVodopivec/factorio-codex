local M = {}
M.AUTONOMY_VERSION = 1
M.REGISTRY_VERSION = 1
M.PATCH_CACHE_VERSION = 2
-- Machine types the registry gained in 0.22 (a 0.21 registry holds these
-- entities in its other sets, not yet as machines).
M.MACHINE_TYPES_0_22 = { reactor = true, beacon = true, roboport = true }
-- Stores the registry gained in 0.22.2: an older registry never kept them,
-- so it rescans the charted chunks for them once.
M.STORE_TYPES_0_22_2 = { "cargo-landing-pad" }
-- Planet machine types the registry gained in 0.22.3. Every one of them is
-- electric (or a reactor), so an older registry already holds them in its
-- electric set: they only join the machine sets.
M.MACHINE_TYPES_0_22_3 = { ["fusion-reactor"] = true, ["fusion-generator"] = true, ["lightning-attractor"] = true,
  ["agricultural-tower"] = true, ["asteroid-collector"] = true }
-- Machine types the registry keeps only with a burner (burner inserters),
-- gained after 0.26.2: an older registry holds them in its burner set.
M.BURNER_MACHINE_TYPES = { inserter = true }
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
    -- What that input was (companion.note_activity): the linked control's
    -- name, gui, cursor, walking or mining.
    human_activity_cause = tasks.human_activity_cause,
    -- A human hold in progress (tasks.enter_hold): {since}. Kept across a
    -- load so its ticks are still credited when it ends.
    human_hold = tasks.human_hold,
    -- Hold episodes (tasks.enter_hold): count, every one begun; total_ticks,
    -- those that ended; recent, the last 16 {start_tick, end_tick, cause}.
    -- A save from before them starts with none.
    holds = tasks.holds or { count = 0, total_ticks = 0, recent = {} },
    -- The tick the body died while work was queued (tasks.on_tick pauses
    -- the dispatcher until it respawns), absent otherwise.
    dead_since = tasks.dead_since,
    -- The last pilot or package plan to reach a terminal status:
    -- {plan_id, status, tick}; upkeep plans are not kept here.
    last_plan_ended = tasks.last_plan_ended,
    -- The tick of the last cancel-all (emergency stop), absent before one.
    last_cancel_all_tick = tasks.last_cancel_all_tick,
    -- The body changed surface and the dispatcher has not applied the
    -- surface cancel rule yet (tasks.on_body_surface_changed): the change.
    surface_changed = tasks.surface_changed,
    -- Where the body stood as recent pilot or package plans began, newest
    -- first, at most four {surface_index, x, y} (tasks.note_work_site),
    -- absent before one: idle upkeep serves near them.
    work_sites = tasks.work_sites,
    -- The last few pilot queue_plan client keys (tasks.queue_plan), oldest
    -- first: {key, plan_id, tick}, so a retried call returns the plan it
    -- queued; absent before the first.
    client_keys = tasks.client_keys,
    -- Run telemetry (tasks.body_time): ticks per body state and idle gaps
    -- since since_tick, and the state in force since state_since.
    body_time = tasks.body_time or { since_tick = game and game.tick or 0, state = "idle",
      state_since = game and game.tick or 0, ticks = {}, gaps = {} },
  }
  -- Recent plan outcomes, oldest first (tasks.activity_log).
  storage.activity_log = storage.activity_log or {}
  -- The repeat counter (tasks.lua): "<action>|<target>" -> {code, count,
  -- tick} of the last step ending failed or partial there, at most
  -- tasks.MAX_REPEAT_KEYS keys (size), the oldest evicted first.
  storage.repeats = storage.repeats or { by_key = {}, size = 0 }
  -- Recent draws (tasks.lua): a ring ({rows, n}: n rows ever written) of
  -- the items plans took from own stores or ended with fewer of.
  storage.draws = storage.draws or { rows = {}, n = 0 }
  -- The change journal and own entity losses (journal.lua): rings of the
  -- last journal.SIZE changes and journal.LOSS_SIZE losses, and the tick of
  -- the newest loss.
  storage.journal = storage.journal or { rows = {}, n = 0 }
  storage.losses = storage.losses or { rows = {}, n = 0, last_tick = nil }

  -- At most one path request exists because only the sole active task runs.
  storage.path_request = nil
  -- chunked RPC responses: { next_id, by_id = { [id] = { parts = {...}, created_tick } } }
  storage.rpc_outbox = storage.rpc_outbox or { next_id = 1, by_id = {} }
  -- The writer fence (rpc.lua): generation, the newest writer generation
  -- (0 before the first claim_writer), and claimed_tick, when it was claimed.
  storage.writer = storage.writer or { generation = 0 }
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
  -- Upkeep (chores.lua): unit_number -> tick the last refuel step for it
  -- ended, and "<unit>:<pack>" -> tick of the last delivery of that pack to
  -- a lab (0.22.2 keyed labs by unit alone; those keys expire like the
  -- others); refuel_plan (absent until the first) maps the newest upkeep
  -- plan's refuel steps to their machines; step_tick (absent until the
  -- first) is when an upkeep step last ended and boundary_tick when the
  -- plan-boundary pass last looked (each gates that pass).
  storage.chores = storage.chores or {}
  storage.chores.refueled = storage.chores.refueled or {}
  storage.chores.fed_labs = storage.chores.fed_labs or {}
  -- The last finished research of the body's force (factory_status
  -- .on_research_changed): {technology, tick}, absent before the first.
  storage.last_research_finished = storage.last_research_finished
  -- Thought feed (thoughts.lua): The strategist's NOW line and the last shown lines.
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
  -- and per chore status (no_fuel, missing_science_packs) and surface the
  -- units in it, so upkeep reads those machines without walking every one
  -- (0.22).
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
  -- 0.22.3: the planet machine types join the machine sets (a pure Lua pass
  -- over the entries, once), and the lines are regrouped by surface at once;
  -- the chore status sets become per surface (waiting[raw][surface][unit]),
  -- filled again by that refresh.
  if not r.planet_machines then
    storage.autonomy.waiting = {}
    r.planet_machines = true
    for unit, entry in pairs(r.entries) do
      if M.MACHINE_TYPES_0_22_3[entry.type] then
        r.machines[entry.type] = r.machines[entry.type] or {}
        r.machines[entry.type][unit] = true
      end
    end
    storage.autonomy.dirty_tick = storage.autonomy.dirty_tick or (game and game.tick or 0)
  end
  -- Burner inserters join the machine sets (sampled for problems only): an
  -- older registry holds them in its burner set (a pure Lua pass, once).
  if not r.burner_inserters then
    r.burner_inserters = true
    for unit, entry in pairs(r.entries) do
      if M.BURNER_MACHINE_TYPES[entry.type] and r.burners[unit] then
        entry.burner = true
        r.machines[entry.type] = r.machines[entry.type] or {}
        r.machines[entry.type][unit] = true
      end
    end
    storage.autonomy.dirty_tick = storage.autonomy.dirty_tick or (game and game.tick or 0)
  end
  -- 0.21 kept factory_status stock and power in a refresh cache; the
  -- registry's aggregates replace it.
  storage.status_cache = nil
  -- factory_status research: the available technologies, rebuilt on the
  -- next read after a load or upgrade and kept by the research events
  -- (factory_status.on_research_changed).
  storage.research_cache = nil
  -- Resource patches per planet surface (map_summary.patches):
  -- storage.patch_caches[surface index] = {chunks: chunk key -> {cx, cy,
  -- cells = {[resource] = cell}} for chunks holding resources; known: every
  -- chunk read once; pending chunks (re)read a few per tick from head;
  -- charted: every charted chunk once, in the order it became known, and
  -- charted_set its keys (map_summary's chunk list, read without a query)}.
  -- Version 2 cells also keep initial, base_amount, base_tick and rate
  -- (map_summary's depletion); a version 1 cache gains them from its
  -- current amounts, so its patches count as unmined from the upgrade on.
  -- map_summary makes a surface's cache when the body first stands there or
  -- the force charts a chunk of it. Up to 0.22.2 the one cache
  -- (storage.patch_cache) was Nauvis's: it is kept as Nauvis's.
  storage.patch_caches = storage.patch_caches or {}
  local legacy = storage.patch_cache
  if legacy then
    if legacy.version == 1 then
      if not legacy.charted then
        -- A 0.21.0 cache: its known and queued chunks are the charted ones.
        local keys = {}
        for key in pairs(legacy.known) do keys[key] = true end
        for key in pairs(legacy.queued) do keys[key] = true end
        local list = {}
        for key in pairs(keys) do
          local x, y = key:match("^(-?%d+),(-?%d+)$")
          if x then list[#list + 1] = { x = tonumber(x), y = tonumber(y) } end
        end
        table.sort(list, function(a, b) return a.y == b.y and a.x < b.x or a.y < b.y end)
        legacy.charted, legacy.charted_set = list, {}
        for _, chunk in ipairs(list) do legacy.charted_set[chunk.x .. "," .. chunk.y] = true end
      end
      local ok, nauvis = pcall(function() return game.surfaces["nauvis"].index end)
      legacy.surface_index = ok and nauvis or 1
      storage.patch_caches[legacy.surface_index] = storage.patch_caches[legacy.surface_index] or legacy
    end
    storage.patch_cache = nil
  end
  for index, cache in pairs(storage.patch_caches) do
    if cache.version == 1 then
      local tick = game and game.tick or 0
      for _, chunk in pairs(cache.chunks or {}) do
        for _, cell in pairs(chunk.cells or {}) do
          cell.initial, cell.base_amount, cell.base_tick = cell.amount, cell.amount, tick
        end
      end
      -- The rows are rebuilt with the new fields; a build under way restarts.
      cache.version, cache.dirty, cache.build = M.PATCH_CACHE_VERSION, true, nil
    end
    if cache.version ~= M.PATCH_CACHE_VERSION then storage.patch_caches[index] = nil end
  end
  -- Space platforms (platforms.lua): the planet of each platform
  -- create_platform made while it waits for its starter pack, and the ring
  -- of the last space events (launches ordered and launched, platform
  -- states, landed cargo, ready rockets) with the tick of the newest.
  storage.space = storage.space or {}
  storage.space.created = storage.space.created or {}
  storage.space.events = storage.space.events or {}
  -- Run milestones, the first tick of each (the run recorder samples them):
  -- rocket_ready_tick, rocket_launch_ordered_tick and rocket_launched_tick
  -- (platforms.lua), and research: technology -> the tick the body's force
  -- first finished it (run_snapshot.on_research_finished). A save from
  -- before them records from the upgrade on.
  storage.milestones = storage.milestones or {}
  storage.milestones.research = storage.milestones.research or {}
  -- Travel (actions/travel.lua): the launch or landing a travel step started
  -- ({to, since_tick, cancelled?}; companion.lua counts the cutscene as
  -- transit meanwhile), and per platform index the last arrival at a station
  -- ({location, tick}, written by the platform state event). The body's last
  -- seen surface is storage.companion.surface_ref (companion.lua).
  storage.travel = storage.travel or {}
  storage.travel.arrivals = storage.travel.arrivals or {}
  -- World policy write failures per surface (companion.lua), shown by ping.
  storage.world_policy = storage.world_policy or {}
  storage.world_policy.errors = storage.world_policy.errors or {}
  -- Errors a handler raised and a dispatcher caught (errors.lua): count
  -- since the save gained the ring, and recent, the last few {tick, where,
  -- error}, oldest first. An older save starts it empty.
  storage.handler_errors = storage.handler_errors or { count = 0, recent = {} }
  -- Bot-set watches (watches.lua): next_id; list, every role's watches in
  -- the order set ({id, role, kind, item, fluid, per_min, line, at, force,
  -- surface, armed, value, made, fired_tick, clear_since});
  -- cursor, the next one to evaluate; per role, fired: a ring of the last
  -- firings ({id, condition, surface, value, produced_per_min, tick}, oldest
  -- first) and fired_tick: the newest one's tick. A save from before
  -- watches starts with none.
  local watches = storage.watches or {}
  storage.watches = { next_id = watches.next_id or 1, list = watches.list or {}, cursor = watches.cursor or 1,
    fired = watches.fired or {}, fired_tick = watches.fired_tick or {} }
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
