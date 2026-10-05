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
  get_chunks = function() error("a seeded patch cache lists the charted chunks") end,
})
local body_position = { x = 0.5, y = 0.5 }
local body = object({ valid = true, name = "character", type = "character", force = force, surface = surface,
  position = body_position, health = 250, reach_distance = 10, build_distance = 10,
  crafting_queue_size = 0, crafting_queue_progress = 0, crafting_queue = {},
  get_main_inventory = function() return object({ get_contents = function() return {} end }) end,
  get_inventory = function() return object({ get_contents = function() return {} end }) end })
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end,
  human_control = function() return false end }
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
  -- The patch cache lists every charted chunk (state.init/map_summary keep it).
  local charted, set = {}, {}
  for cy = -2, 6 do for cx = -2, 6 do
    charted[#charted + 1] = { x = cx, y = cy }
    set[cx .. "," .. cy] = true
  end end
  storage.patch_cache = { seeded = true, charted = charted, charted_set = set, chunks = {}, known = {}, queued = {},
    pending = {}, head = 1, refresh = {}, dirty = true }
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
  while result == nil and ticks < 5000 do
    calls = 0
    local stage = state.stage .. (state.flow and state.stage == "flow" and tostring(state.flow.stage) or "")
    local counted = 0
    debug.sethook(function() counted = counted + 1 end, "", INSTRUCTION_STEP)
    result = definition.step(state, { left = jobs.WORK_PER_TICK })
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
  check(small and large and large.resource_patches[1].entity_count >= 61 * 61,
    "observe_local " .. detail .. " reads the whole ore field at radius 30")
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
