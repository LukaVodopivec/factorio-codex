-- Engine calls per tick of each read job. Every read of a LuaObject field
-- (entity, surface, force, inventory, tile) is one engine call; a job run a
-- tick at a time must stay within a fixed number of calls per tick however
-- large the factory or the area, while its total work grows with it.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local calls = 0
-- A LuaObject stand-in: every field read is an engine call.
local function object(values)
  return setmetatable({}, {
    __index = function(_, key) calls = calls + 1; return values[key] end,
    __newindex = function(_, key, value) calls = calls + 1; values[key] = value end,
    __eq = function(a, b) return rawequal(a, b) end,
  })
end

_G.game = { tick = 1000 }
_G.storage = {}
_G.defines = { entity_status = { working = 1, no_power = 2, waiting_for_source_items = 3 },
  flow_precision_index = { one_minute = 1, five_seconds = 0 }, inventory = { chest = 1, character_ammo = 2 },
  build_check_type = { manual = 1, ghost_revive = 2 } }
_G.prototypes = { tile = { water = { collision_mask = { layers = { water_tile = true } } },
  grass = { collision_mask = { layers = {} } } }, entity = {}, item = {}, recipe = {}, fluid = {} }

local force = object({ name = "player",
  is_chunk_charted = function() return true end, is_chunk_visible = function() return true end,
  get_item_production_statistics = function() return object({ input_counts = {}, output_counts = {},
    get_flow_count = function() return 0 end }) end,
  get_fluid_production_statistics = function() return object({ input_counts = {}, output_counts = {},
    get_flow_count = function() return 0 end }) end,
  current_research = nil, recipes = {} })

local world = {}   -- chunk key -> own entities
local resources = {} -- chunk key -> resources
local function chunk_of(x, y) return math.floor(x / 32) .. "," .. math.floor(y / 32) end
local function in_area(position, area)
  local lt, rb = area.left_top or { x = area[1][1], y = area[1][2] }, area.right_bottom or { x = area[2][1], y = area[2][2] }
  return position.x >= lt.x and position.x < rb.x and position.y >= lt.y and position.y < rb.y
end
local surface = object({
  index = 1,
  find_entities_filtered = function(filter)
    local out = {}
    local area = filter.area
    if not area then return out end
    local lt = area.left_top or { x = area[1][1], y = area[1][2] }
    local rb = area.right_bottom or { x = area[2][1], y = area[2][2] }
    for cy = math.floor(lt.y / 32), math.floor((rb.y - 0.001) / 32) do
      for cx = math.floor(lt.x / 32), math.floor((rb.x - 0.001) / 32) do
        local key = cx .. "," .. cy
        local lists = filter.type == "resource" and { resources[key] or {} } or filter.force and { world[key] or {} }
          or { world[key] or {}, resources[key] or {} }
        for _, list in ipairs(lists) do
          for _, e in ipairs(list) do
            if in_area(rawget(e, "_position"), area) then out[#out + 1] = e end
          end
        end
      end
    end
    return out
  end,
  find_tiles_filtered = function() return {} end,
  get_tile = function() return object({ collides_with = function() return false end }) end,
  get_chunks = function()
    -- Full summaries discover the current force chart as budgeted work;
    -- aggregate summaries retain the seeded patch index below.
    local x, y = -3, -2
    return function()
      x = x + 1
      if x > 6 then x, y = -2, y + 1 end
      if y <= 6 then return { x = x, y = y } end
    end
  end,
})
local body_position = { x = 0.5, y = 0.5 }
local body = object({ valid = true, name = "character", type = "character", force = force, surface = surface,
  position = body_position, health = 250, reach_distance = 10, build_distance = 10,
  crafting_queue_size = 0, crafting_queue_progress = 0, crafting_queue = {},
  get_main_inventory = function() return object({ get_contents = function() return {} end }) end,
  get_inventory = function() return object({ get_contents = function() return {} end }) end })
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end,
  human_control = function() return false end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
package.loaded["scripts.tasks"] = { active_summary = function() return nil end, queue_length = function() return 0 end }

local function own(values)
  local e = object(values)
  rawset(e, "_position", values.position)
  local key = chunk_of(values.position.x, values.position.y)
  world[key] = world[key] or {}
  table.insert(world[key], e)
  return e
end
local function ore(x, y)
  local values = { valid = true, name = "iron-ore", type = "resource", amount = 500, position = { x = x, y = y },
    selection_box = { left_top = { x = x - 0.5, y = y - 0.5 }, right_bottom = { x = x + 0.5, y = y + 0.5 } } }
  local e = object(values)
  rawset(e, "_position", values.position)
  local key = chunk_of(x, y)
  resources[key] = resources[key] or {}
  table.insert(resources[key], e)
end

-- A factory of n assembler cells: assembler, inserter, chest and a belt.
local unit = 0
local function factory(n)
  world = {}
  local recipe = { name = "iron-gear-wheel", energy = 0.5, ingredients = { { name = "iron-plate", type = "item", amount = 2 } },
    products = { { name = "iron-gear-wheel", type = "item", amount = 1 } } }
  for i = 0, n - 1 do
    local x, y = (i % 40) * 4 + 0.5, math.floor(i / 40) * 4 + 0.5
    local function next_unit() unit = unit + 1; return unit end
    local chest_inventory = object({ get_contents = function() return { { name = "iron-plate", count = 5 } } end,
      get_item_count = function() return 5 end, can_insert = function() return true end })
    local chest = own({ valid = true, name = "iron-chest", type = "container", force = force, unit_number = next_unit(),
      position = { x = x, y = y }, direction = 0, get_inventory = function() return chest_inventory end })
    local machine = own({ valid = true, name = "assembling-machine-1", type = "assembling-machine", force = force,
      unit_number = next_unit(), position = { x = x + 2, y = y + 1 }, direction = 0, status = 1,
      electric_network_id = 1, crafting_speed = 0.5, products_finished = 3,
      get_recipe = function() return recipe end,
      get_output_inventory = function() return object({ get_contents = function() return {} end }) end })
    own({ valid = true, name = "inserter", type = "inserter", force = force, unit_number = next_unit(),
      position = { x = x + 1, y = y }, direction = 4, status = 1, electric_network_id = 1,
      pickup_target = chest, drop_target = machine })
    own({ valid = true, name = "transport-belt", type = "transport-belt", force = force, unit_number = next_unit(),
      position = { x = x, y = y + 2 }, direction = 4, status = 1, belt_neighbours = { inputs = {}, outputs = {} },
      get_max_transport_line_index = function() return 2 end,
      get_transport_line = function() return object({ get_contents = function() return {} end }) end })
  end
  -- The surface's patch cache lists every charted chunk (map_summary keeps it).
  local charted, set = {}, {}
  for cy = -2, 6 do for cx = -2, 6 do
    charted[#charted + 1] = { x = cx, y = cy }
    set[cx .. "," .. cy] = true
  end end
  storage.patch_caches = { [1] = { version = 1, surface_index = 1, seeded = true, charted = charted, charted_set = set,
    chunks = {}, known = {}, queued = {}, pending = {}, head = 1, refresh = {}, dirty = true } }
end

local jobs = require("scripts.jobs")
local map_summary = require("scripts.map_summary")
local spatial = require("scripts.spatial")

-- Lua work is counted in VM instructions (debug.sethook, in steps of 100):
-- sorting, union-find and clustering make no engine call, so the call count
-- alone cannot see a tick that does them over the whole factory.
local INSTRUCTION_STEP = 100
-- Runs a job a tick at a time: {result, ticks, most calls in one tick, total
-- calls, most instructions in one tick}.
local function measure(definition, params)
  calls = 0
  local state = definition.start(params)
  local start_calls = calls
  local ticks, worst, total, result, most_instructions = 0, start_calls, start_calls, nil, 0
  local stages = {}
  while result == nil and ticks < (params.max_ticks or 5000) do
    calls = 0
    local stage = state.stage .. (state.flow and state.stage == "flow" and tostring(state.flow.stage) or "")
    local counted = 0
    debug.sethook(function() counted = counted + 1 end, "", INSTRUCTION_STEP)
    result = definition.step(state, { left = params.work or jobs.WORK_PER_TICK })
    debug.sethook()
    ticks, worst, total = ticks + 1, math.max(worst, calls), total + calls
    most_instructions = math.max(most_instructions, counted * INSTRUCTION_STEP)
    stages[stage] = math.max(stages[stage] or 0, calls)
  end
  if os.getenv("JOB_BUDGET_DEBUG") then for k, v in pairs(stages) do print("  stage", k, v) end end
  return result, ticks, worst, total, most_instructions
end

-- A tick's Lua work must not grow with the factory or the area: the worst
-- tick of a large job stays near a small one's, and under a fixed ceiling.
local INSTRUCTION_BOUND = 300000
local function flat(small, large) return large <= INSTRUCTION_BOUND and large <= 1.5 * small + 50000 end

-- An engine call per work item, and a few for the item that ends a tick.
local BOUND = 3 * jobs.WORK_PER_TICK

for _, detail in ipairs({ "aggregate", "full" }) do
  local params = { detail = detail, include = { "stockpiles", "sites", "power", "problems" } }
  factory(40)
  local small, small_ticks, small_worst, _, small_lua = measure(map_summary.summary_job, params)
  factory(600)
  local large, large_ticks, large_worst, large_total, large_lua = measure(map_summary.summary_job, params)
  check(flat(small_lua, large_lua), string.format(
    "map_summary %s does no tick of Lua work that grows with the factory (small %d, large %d instructions)",
    detail, small_lua, large_lua))
  -- map_summary counts inserters among its machine groups.
  check(small and large and large.factory.machine_count == 1200 and small.factory.machine_count == 80,
    "map_summary " .. detail .. " counts every machine of a small and a large factory")
  check(small_worst <= BOUND and large_worst <= BOUND,
    string.format("map_summary %s stays within %d engine calls a tick (small %d, large %d)", detail, BOUND,
      small_worst, large_worst))
  check(large_ticks > 5 * small_ticks and large_total > 10 * BOUND,
    string.format("map_summary %s spreads a large factory's %d calls over %d ticks", detail, large_total, large_ticks))
end

-- The consumer touch index and undelivering-generator diagnostics used to
-- scan the entire graph before checking the first work allowance. Exercise
-- those passes directly: disconnected edges and generators still grow even
-- when no engine relationship or later reachability walk needs to be read.
-- The component pass also checks every node and each newly split adjacency index.
do
  local function pass(stage, n)
    local definition = {
      start = function()
        local state = map_summary.summary_job.start({ detail = "aggregate" })
        state.stage = "flow"
        local flow = { stage = stage, nodes = {}, edges = {}, diagnostics = {} }
        for i = 1, n do
          if stage == 5 then
            flow.edges[i] = { from = "from-" .. i, to = "to-" .. i,
              kind = i % 4 == 0 and "fluid_connection" or "belt_direction" }
          else flow.nodes[i] = { id = "node-" .. i, type = "generator" } end
        end
        if stage == 14 then
          flow.parent, flow.by_root, flow.component_list = {}, {}, {}
          flow.node_by_id, flow.incoming, flow.outgoing, flow.edges_of = {}, {}, {}, {}
          for _, node in ipairs(flow.nodes) do
            node.role, node.status = "power", "working"
            flow.parent[node.id] = node.id
          end
        end
        state.flow = flow
        return state
      end,
      step = function(state, budget)
        map_summary.summary_job.step(state, budget)
        local flow = state.flow
        if stage == 5 and flow.touches then
          return { touches = flow.touches }
        elseif stage == 6 and flow.demand then
          return { diagnostics = flow.diagnostics }
        elseif stage == 14 and flow.stage > 14 then
          return { flow = flow }
        end
      end,
    }
    return measure(definition, {})
  end
  factory(40)
  for _, stage in ipairs({ 5, 6, 14 }) do
    local small, small_ticks, small_calls, _, small_lua = pass(stage, 2400)
    local large, large_ticks, large_calls, _, large_lua = pass(stage, 24000)
    local exact = true
    for index, result in ipairs({ small, large }) do
      local n = index == 1 and 2400 or 24000
      if stage == 5 then
        local count = 0
        for _ in pairs(result.touches) do count = count + 1 end
        exact = exact and count == n * 1.5
        for i = 1, n do
          local expected = i % 4 ~= 0 or nil
          exact = exact and result.touches["from-" .. i] == expected
            and result.touches["to-" .. i] == expected
        end
      elseif stage == 14 then
        local flow = result.flow
        exact = exact and #flow.component_list == n
        for i, node in ipairs(flow.nodes) do
          local component = flow.component_list[i]
          exact = exact and flow.node_by_id[node.id] == node
            and #flow.incoming[node.id] == 0 and #flow.outgoing[node.id] == 0 and #flow.edges_of[node.id] == 0
            and #component.node_ids == 1 and component.node_ids[1] == node.id
            and component.roles.power == 1 and component.status_counts.working == 1
        end
      else
        exact = exact and #result.diagnostics == n
        for i, row in ipairs(result.diagnostics) do
          exact = exact and row.node_id == "node-" .. i
            and row.reason == "electrical_material_consumer_unproven"
        end
      end
    end
    check(exact, "flow pass " .. stage .. " produces every expected entry with its exact identity")
    check(flat(small_lua, large_lua) and small_calls <= BOUND and large_calls <= BOUND
      and large_ticks >= 9 * small_ticks,
      string.format("flow pass %d bounds each slice as its graph grows (small %d, large %d instructions)",
        stage, small_lua, large_lua))
  end
end

-- Isolate the two generator fan-outs through their existing stage functions.
-- No production export or test-only execution path is needed.
do
  local function upvalue(fn, wanted)
    for i = 1, 100 do
      local name, value = debug.getupvalue(fn, i)
      if name == wanted then return value end
      if not name then break end
    end
    error("missing upvalue " .. wanted)
  end
  local stages = upvalue(upvalue(map_summary.summary_job.step, "flow_step"), "FLOW_STAGES")
  local function fixture(stage, n, networks, edges)
    local F = { nodes = {}, edges = {}, generators = {}, parent = {}, touches = {},
      retained = {}, seen_edges = {}, diagnostics = {} }
    for i = 1, n do
      local network = (i - 1) % networks + 1
      local node = { id = "generator-" .. i, type = "generator" }
      node._entity = object({ valid = true, name = "steam-engine", type = "generator", position = { x = i, y = 0 } })
      local list = F.generators[network] or {}
      F.generators[network] = list
      list[#list + 1], F.parent[node.id] = node, node.id
    end
    if stage == 5 then
      -- Duplicate consumers must not restart or repeat a network's marking.
      for i = 1, networks + 2 do
        F.nodes[i] = { id = "consumer-" .. i, type = "assembling-machine", role = "processor",
          _entity = object({ valid = true, electric_network_id = (i - 1) % networks + 1,
            prototype = { electric_energy_source_prototype = { usage_priority = "primary-input" } },
            name = "assembler", type = "assembling-machine", position = { x = i, y = 1 } }) }
      end
    end
    if edges then F.edges[1] = { from = "generator-1", to = "generator-1", kind = "fluid_connection" } end
    return F
  end
  local function run(stage, n, networks, work, edges)
    local definition = {
      start = function() return { stage = "generator-" .. stage, F = fixture(stage, n, networks, edges) } end,
      step = function(state, budget) if stages[stage](state.F, budget) then return state.F end end,
    }
    return measure(definition, { work = work, max_ticks = 200000 })
  end
  for _, stage in ipairs({ 5, 13 }) do
    for _, shape in ipairs({ "shared", "pairs", "singletons" }) do
      for _, work in ipairs({ 7, jobs.WORK_PER_TICK }) do
        local values = {}
        for _, n in ipairs({ 2400, 24000 }) do
          local networks = shape == "shared" and 1 or shape == "pairs" and n / 2 or n
          local F, ticks, engine, _, instructions = run(stage, n, networks, work, true)
          local exact = F ~= nil
          if F then
            for network, list in pairs(F.generators) do
              for _, node in ipairs(list) do
                exact = exact and (stage == 5 and node._power_delivery == true
                  or stage == 13 and F.parent[node.id] == list[1].id)
              end
              if stage == 5 then exact = exact and F.delivering[network] == true end
            end
          end
          check(exact, string.format("generator stage %d %s %d work %g preserves every identity", stage, shape, n, work))
          values[#values + 1] = { ticks = ticks, engine = engine, instructions = instructions }
        end
        local a, b = values[1], values[2]
        -- This isolated fixture consists entirely of electrical consumers;
        -- each three-work consumer reads up to fifteen engine fields.
        local engine_bound = 5 * work + 30
        check(flat(a.instructions, b.instructions) and b.instructions <= 1.5 * a.instructions + 1000
          and a.engine <= engine_bound and b.engine <= engine_bound
          and b.ticks >= 5 * a.ticks,
          string.format("generator stage %d %s work %g bounds slices: %d/%d instructions, %d/%d calls, %d/%d steps",
            stage, shape, work, a.instructions, b.instructions, a.engine, b.engine, a.ticks, b.ticks))
      end
    end
  end
  -- The edge consumes the entire allowance; generators must wait. Empty-edge
  -- graphs must also yield before finishing a growing network.
  for _, edges in ipairs({ false, true }) do
    local F = fixture(13, 2400, 1, edges)
    local done = stages[13](F, { left = edges and 0.5 or 1 })
    local exact = not done and F.parent["generator-2400"] == "generator-2400"
    if edges then
      for id, parent in pairs(F.parent) do exact = exact and parent == id end
    end
    check(exact,
      "generator joins yield at transition, edge present=" .. tostring(edges))
  end
end

-- observe_local: a dense ore field under the body, compact and full, small
-- and large radius.
world = {}
for x = -30, 30 do for y = -30, 30 do ore(x + 0.5, y + 0.5) end end
for _, detail in ipairs({ "compact", "full" }) do
  local small, small_ticks, small_worst, _, small_lua = measure(spatial.observe_job, { radius = 5, detail = detail })
  local large, large_ticks, large_worst, large_total, large_lua = measure(spatial.observe_job, { radius = 30, detail = detail })
  check(flat(small_lua, large_lua), string.format(
    "observe_local %s clusters and caps an ore field without a tick that grows with it (radius 5: %d, radius 30: %d instructions)",
    detail, small_lua, large_lua))
  -- A full observation paints a grid, so it stops at radius 20 and says so.
  local side = detail == "full" and 41 or 61
  check(small and large and large.resource_patches[1].entity_count >= side * side
    and large.radius == (detail == "full" and 20 or 30)
    and large.requested_radius == (detail == "full" and 30 or nil),
    "observe_local " .. detail .. " reads the whole ore field within radius " .. large.radius)
  check(small_worst <= BOUND and large_worst <= BOUND,
    string.format("observe_local %s stays within %d engine calls a tick (radius 5: %d, radius 30: %d)", detail, BOUND,
      small_worst, large_worst))
  check(large_ticks > 5 * small_ticks and large_total > 10 * BOUND,
    string.format("observe_local %s spreads radius 30's %d calls over %d ticks (radius 5: %d)", detail, large_total,
      large_ticks, small_ticks))
end

-- A plan's compact observation runs within one call: over an ore field it
-- stops at its work ceiling and still carries the character's state.
storage.jobs = nil
calls = 0
local compact = spatial.observe_compact({ radius = 15 })
check(compact.truncated and compact.character and compact.character.position and #compact.entities == 0
  and storage.jobs.used >= spatial.COMPACT_MAX_WORK and storage.jobs.used < spatial.COMPACT_MAX_WORK + jobs.WORK_PER_TICK,
  "observe_compact over an ore field stops at its work ceiling, charges this tick and keeps the character's state")
world, resources = {}, {}
local plain = spatial.observe_compact({ radius = 5 })
check(not plain.truncated and plain.character, "observe_compact of an empty area finishes within the ceiling")

print(failures == 0 and "\nALL JOB BUDGET TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
