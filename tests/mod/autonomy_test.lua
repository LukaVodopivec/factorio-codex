-- Factory lines kept by the mod (autonomy.lua), the factory_status and
-- event_state reads built on them, and the 0.21 storage upgrade. Machines are
-- strict LuaEntity mocks advanced by a small tick simulation.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local RAW = { working = 1, no_fuel = 2, no_ingredients = 3, item_ingredient_shortage = 4,
  waiting_for_space_in_destination = 5, full_output = 6, normal = 7, no_power = 8, no_minable_resources = 9 }
_G.defines = { entity_status = RAW, inventory = { furnace_source = 2, assembling_machine_input = 2, lab_input = 3 } }
local PLATE = { name = "iron-plate", ingredients = { { name = "iron-ore", type = "item", amount = 1 } },
  products = { { name = "iron-plate", type = "item", amount = 1 } } }
local GEAR = { name = "iron-gear-wheel", ingredients = { { name = "iron-plate", type = "item", amount = 2 } },
  products = { { name = "iron-gear-wheel", type = "item", amount = 1 } } }
_G.prototypes = { recipe = { ["iron-plate"] = PLATE, ["iron-gear-wheel"] = GEAR } }
_G.game = { tick = 0 }
_G.storage = {}
_G.script = { register_on_object_destroyed = function() return 1 end }

local entities, queries, reads = {}, 0, 0
local force = { name = "player", is_chunk_charted = function() return true end }
local surface = { find_entities_filtered = function(filter)
  queries = queries + 1
  local wanted = {}
  for _, name in ipairs(filter.type or {}) do wanted[name] = true end
  local found = {}
  for _, entity in ipairs(entities) do
    if entity.valid and (not filter.type or wanted[entity.type]) then found[#found + 1] = entity end
  end
  return found
end }
local body = { valid = true, position = { x = 0, y = 0 }, force = force, surface = surface }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end,
  human_control = function() return false, 999 end }

local next_unit = 100
local state = require("scripts.state")
local registry = require("scripts.registry")
local autonomy = require("scripts.autonomy")
state.init()
-- The bootstrap is covered by registry_test; here every machine is built.
storage.registry.ready = true
local ore = mock.entity({ valid = true, name = "iron-ore", type = "resource", position = { x = 0, y = 0 },
  prototype = { mineable_properties = { products = { { name = "iron-ore", type = "item", amount = 1 } } } } })
local function machine(kind, name, x, y, extra)
  next_unit = next_unit + 1
  local values = { valid = true, name = name, type = kind, position = { x = x, y = y }, unit_number = next_unit,
    force = force, status = RAW.working }
  for key, value in pairs(extra or {}) do values[key] = value end
  local initial = { status = values.status, products_finished = values.products_finished,
    mining_progress = values.mining_progress }
  local entity = mock.entity(values)
  for key, value in pairs(initial) do mock.state(entity)[key] = value end
  for _, key in ipairs({ "status", "products_finished", "mining_progress" }) do
    mock.read(entity, key, function() reads = reads + 1; return mock.state(entity)[key] end)
  end
  entities[#entities + 1] = entity
  -- Built: the registry learns it from the build event (registry_test).
  registry.add(entity)
  return entity
end
local function inventory(counts)
  return { get_item_count = function(name) return counts[name] or 0 end }
end
local function furnace(x, y, input)
  return machine("furnace", "stone-furnace", x, y, { products_finished = 0,
    get_recipe = function() return PLATE end, get_inventory = function() return inventory(input or {}) end })
end
local function drill(x, y)
  return machine("mining-drill", "burner-mining-drill", x, y, { mining_progress = 0, mining_target = ore })
end
local belt = mock.entity({ valid = true, name = "transport-belt", type = "transport-belt", position = { x = 50, y = 50 },
  unit_number = 1, force = force })
entities[#entities + 1] = belt

-- Two furnace columns side by side are one line; a far furnace is another;
-- drills make a different product.
local f1, f2, f3 = furnace(0, 0), furnace(0, 2), furnace(3, 0)
local far = furnace(40, 0)
local d1, d2 = drill(0, -4), drill(2, -4)
game.tick = 1
autonomy.on_tick(game.tick)
local lines = autonomy.lines()
local by_product = {}
for _, line in ipairs(lines) do by_product[line.product] = by_product[line.product] or {}; table.insert(by_product[line.product], line) end
check(#lines == 3 and #by_product["iron-plate"] == 2 and by_product["iron-plate"][1].machines == 3
  and by_product["iron-plate"][2].machines == 1 and by_product["iron-ore"][1].machines == 2,
  "machines making one product within six tiles of each other form one line")
check(queries == 0, "a refresh reads the registry with no entity query, and belts are never lines")

-- The sampler reads each machine once per 30 ticks and never a belt.
reads = 0
for tick = 2, 31 do game.tick = tick; autonomy.on_tick(tick) end
local machine_count = 6
check(reads >= machine_count and reads <= machine_count * 2 and queries == 0,
  "each machine is sampled once per 30 ticks without new entity queries (" .. reads .. " reads)")

-- Producing furnaces and drills: running with a rate.
local function run(ticks, step)
  for _ = 1, ticks do
    game.tick = game.tick + 1
    if step then step(game.tick) end
    autonomy.on_tick(game.tick)
  end
end
local function smelt(tick)
  for _, f in ipairs({ f1, f2, f3 }) do
    if tick % 192 == 0 then mock.state(f).products_finished = mock.state(f).products_finished + 1 end
  end
  for _, d in ipairs({ d1, d2 }) do mock.state(d).mining_progress = (tick % 240) / 240 end
end
run(1200, smelt)
local plate_line, ore_line
for _, line in ipairs(autonomy.lines()) do
  if line.product == "iron-plate" and line.machines == 3 then plate_line = line end
  if line.product == "iron-ore" then ore_line = line end
end
check(plate_line.state == "running" and ore_line.state == "running" and plate_line.rate_per_min > 50
  and plate_line.rate_per_min < 60 and ore_line.rate_per_min > 25 and ore_line.rate_per_min < 35,
  "running lines report a per-minute rate (plates " .. plate_line.rate_per_min .. ", ore " .. ore_line.rate_per_min .. ")")
check(not plate_line.self_sustaining and not plate_line.hand_fed,
  "a line is not self-sustaining before a minute of running")
run(2500, smelt)
for _, line in ipairs(autonomy.lines()) do if line.id == plate_line.id then plate_line = line end end
check(plate_line.self_sustaining and not plate_line.hand_fed,
  "60 s running with no character transfer and no stall is self-sustaining")

-- A character transfer marks the line hand-fed for a minute.
local since = game.tick
autonomy.on_transfer({ x = 0, y = 2 })
run(30, smelt)
local changed = autonomy.lines(since)
check(#changed == 1 and changed[1].id == plate_line.id and changed[1].hand_fed and not changed[1].self_sustaining,
  "a transfer into a machine makes its line hand-fed and since_tick returns only that line")
run(3540, smelt)
for _, line in ipairs(autonomy.lines()) do if line.id == plate_line.id then plate_line = line end end
check(plate_line.hand_fed and not plate_line.self_sustaining, "the line stays hand-fed for the minute after the transfer")
run(90, smelt)
for _, line in ipairs(autonomy.lines()) do if line.id == plate_line.id then plate_line = line end end
check(not plate_line.hand_fed and plate_line.self_sustaining,
  "a running line is self-sustaining again once a minute has passed without a transfer")
check(plate_line.hand_transfers == nil, "one hand transfer is not yet a repeat")

-- Taking a machine's output by hand does not feed it, but serving a line by
-- hand again (in or out) is flagged: it needs a connection.
since = game.tick
autonomy.on_transfer({ x = 0, y = 2 }, "extract")
run(30, smelt)
changed = autonomy.lines(since)
check(#changed == 1 and changed[1].id == plate_line.id and not changed[1].hand_fed and changed[1].self_sustaining
  and changed[1].hand_transfers == 2,
  "a second hand transfer within ten minutes flags the line, and taking output does not make it hand-fed")
local rate, making = autonomy.producing("iron-plate")
check(making == 2 and rate >= plate_line.rate_per_min and select(2, autonomy.producing("copper-plate")) == 0,
  "producing sums the rate of every own line making an item (" .. rate .. "/min)")
run(10 * 3600, smelt)
for _, line in ipairs(autonomy.lines()) do if line.id == plate_line.id then plate_line = line end end
check(plate_line.hand_transfers == nil, "hand transfers older than ten minutes no longer count")

-- Starved furnaces name the missing input and where.
for _, f in ipairs({ f1, f2, f3 }) do mock.state(f).status = RAW.no_ingredients end
local starve_since = game.tick
run(660)
local starved
for _, line in ipairs(autonomy.lines(starve_since)) do if line.id == plate_line.id then starved = line end end
check(starved and starved.state == "starved" and starved.cause == "iron-ore" and starved.cause_position
  and not starved.self_sustaining,
  "a stalled line is starved of the item it lacks, with the machine position")

mock.state(f1).status = RAW.working
run(60)
for _, line in ipairs(autonomy.lines()) do if line.id == plate_line.id then plate_line = line end end
check(plate_line.state == "running" and plate_line.working == 1 and plate_line.machines == 3,
  "a line with one producing machine is running, and working counts it")
mock.state(f1).status = RAW.no_ingredients
run(630)

-- A dry drill is a problem after a second and the line says no_fuel.
mock.state(d1).status, mock.state(d2).status = RAW.no_fuel, RAW.no_fuel
local before_problem = storage.autonomy.last_problem_tick
run(660)
local problems = autonomy.problems()
local fuel_row
for _, row in ipairs(problems) do if row.status == "no_fuel" then fuel_row = row end end
for _, line in ipairs(autonomy.lines()) do if line.product == "iron-ore" then ore_line = line end end
check(ore_line.state == "no_fuel" and fuel_row and fuel_row.count == 2 and fuel_row.name == "burner-mining-drill"
  and storage.autonomy.problem_count >= 2 and storage.autonomy.last_problem_tick ~= before_problem,
  "dry drills are a grouped problem with a new problem tick and their line is no_fuel")
local output_full = furnace(40, 3)
mock.state(output_full).status = RAW.full_output

-- Building marks topology dirty; the refresh waits 300 ticks.
autonomy.on_entity_changed({ entity = belt })
check(storage.autonomy.dirty_tick == nil, "building a belt does not refresh lines")
autonomy.on_entity_changed({ entity = output_full })
local dirty = storage.autonomy.dirty_tick
run(299)
local count_before = #autonomy.lines()
run(1)
check(dirty and count_before == #autonomy.lines() - 0 and storage.autonomy.dirty_tick == nil
  and storage.autonomy.last_refresh_tick == dirty + 300,
  "a build refreshes the lines once, 300 ticks later")
local far_line
for _, line in ipairs(autonomy.lines()) do if line.position.x == 40 then far_line = line end end
check(far_line and far_line.machines == 2, "the new furnace joins the nearby line, which keeps its id")

-- Backpressure that flaps (700 ticks output full, then a 30-tick working
-- burst) is one problem: next_event is not woken once per episode.
mock.state(output_full).status = RAW.working
run(700)
local before_flap, first_flap = storage.autonomy.last_problem_tick, nil
for episode = 1, 4 do
  mock.state(output_full).status = RAW.full_output
  run(700)
  if episode == 1 then first_flap = storage.autonomy.last_problem_tick end
  mock.state(output_full).status = RAW.working
  run(30)
end
check(first_flap ~= before_flap and storage.autonomy.last_problem_tick == first_flap,
  "a machine flapping between output full and short working bursts sets last_problem_tick once")
run(630)
local flap_rows = 0
for _, row in ipairs(autonomy.problems()) do if row.status == "full_output" and row.position.x == 40 then flap_rows = flap_rows + 1 end end
check(flap_rows == 0, "the problem clears after ten seconds without it")
mock.state(output_full).status = RAW.full_output
run(630)
check(storage.autonomy.last_problem_tick ~= first_flap, "a problem after a full recovery is announced again")

-- A machine removed between refreshes forces a refresh instead of an error.
f3.valid = false
for i, entity in ipairs(entities) do if entity == f3 then table.remove(entities, i) end end
run(60)
check(storage.autonomy.dirty_tick ~= nil, "an invalid machine schedules a refresh")
run(300)
for _, line in ipairs(autonomy.lines()) do if line.id == plate_line.id then plate_line = line end end
check(plate_line.machines == 2, "the refresh drops the removed machine from its line")
local counts, expected = autonomy.counts(), 0
for _, line in ipairs(autonomy.lines()) do if line.self_sustaining then expected = expected + 1 end end
check(counts.line_count == #autonomy.lines() and counts.self_sustaining_line_count == expected
  and counts.running_line_count < counts.line_count, "line counts summarise every line")

-- A refresh that fails keeps the previous lines and names the error.
local good_machines = registry.machines
registry.machines = function() error("registry read failed") end
local lines_before = #autonomy.lines()
storage.autonomy.dirty_tick = game.tick - 300
run(1)
check(#autonomy.lines() == lines_before and storage.autonomy.refresh_error:match("registry read failed"),
  "a failed refresh keeps the previous lines and reports its error")
registry.machines = good_machines

-- Until the registry's bootstrap is ready, lines wait instead of refreshing
-- from a partial registry.
storage.registry.ready = false
storage.autonomy.dirty_tick = game.tick - 300
local refreshed_before = storage.autonomy.last_refresh_tick
run(1)
check(storage.autonomy.last_refresh_tick == refreshed_before and storage.autonomy.dirty_tick ~= nil,
  "a due refresh waits for the registry bootstrap")
storage.registry.ready = true
run(1)
check(storage.autonomy.dirty_tick == nil, "the refresh runs once the registry is ready")

-- 0.20 saves: proofs are dropped and line storage is created.
_G.storage = { tasks = { next_id = 9, records = {}, queue = {} },
  factory_activity = { epoch_tick = 0, events = {}, events_omitted = 0, validations = { { proven = true } },
    validations_omitted = 2, supply_proof_tick = { x = 1 }, target_last_tick = {} } }
state.init()
check(storage.factory_activity.validations == nil and storage.factory_activity.supply_proof_tick == nil
  and storage.autonomy and storage.autonomy.version == state.AUTONOMY_VERSION and storage.activity_log
  and storage.tasks.next_id == 9, "upgrading a 0.20 save drops proofs and creates line storage")
local kept = storage.autonomy
state.init()
check(storage.autonomy == kept, "a repeated init keeps line storage")

-- factory_status composes the sections; event_state stays cheap.
local summary_stub = {
  status_sections = function() return {
    stockpiles = { { item = "coal", total = 50, holders = { { entity = "wooden-chest", position = { x = 1, y = 1 }, count = 40, kind = "chest" },
      { entity = "transport-belt", position = { x = 2, y = 1 }, count = 8, kind = "belt" },
      { entity = "stone-furnace", position = { x = 3, y = 1 }, count = 2, kind = "machine_output" } } } },
    power = { { id = 7, satisfaction = 0.5, production_w = 900000, capacity_w = 900000, demand_w = 1800000, engines_needed = 2 } },
    updated_tick = 5, ready = true,
  } end,
  patches = function() return { { name = "iron-ore", amount = 5000, tiles = 20, centroid = { x = 30, y = 40 } } } end,
}
package.loaded["scripts.map_summary"] = summary_stub
local research_scans = 0
local research_stub = { progression_status = function()
  research_scans = research_scans + 1
  return { available = { { name = "logistics" } } }
end }
package.loaded["scripts.research"] = research_stub
force.current_research, force.research_progress, force.research_queue = { name = "automation" }, 0.25, { { name = "automation" } }
local active_plan = { id = 4, type = "plan", status = "running", current_step = 2, steps = { {}, { action = "walk_to" } }, source = "package:p1" }
package.loaded["scripts.tasks"] = { queue_length = function() return 1 end,
  active_summary = function() return { id = 4, type = "plan", current_step = 2, total_steps = 2, action = "walk_to", source = "package:p1" } end }
body.get_main_inventory = function() return { get_contents = function() return { { name = "coal", count = 5 }, { name = "iron-plate", count = 9 } } end } end
body.crafting_queue_size = 0
storage.tasks.active, storage.tasks.queue = active_plan, { {} }
storage.tasks.last_plan_ended = { plan_id = 3, status = "completed", tick = 10 }
local factory_status = require("scripts.factory_status")
game.tick = game.tick + 30
local status = factory_status.factory_status({})
check(status.tick == game.tick and type(status.lines) == "table" and status.power[1].engines_needed == 2
  and status.stock[1].item == "coal" and #status.stock[1].holders == 1 and status.stock[1].holders[1].kind == "chest"
  and status.stock_power_tick == 5 and status.stock_power_ready == true
  and status.research.progress == 0.25 and status.research.queue[1] == "automation"
  and status.research.current == "automation" and status.research.available[1] == "logistics"
  and status.body.queue_depth == 1 and status.body.active_step.source == "package:p1"
  and status.body.inventory_summary["iron-plate"] == 9 and status.body.human_control == false
  and status.patches[1].name == "iron-ore" and status.patches[1].distance == 50,
  "factory_status composes lines, problems, power, stock, research, body and patches")
factory_status.factory_status({ sections = { "research" } })
local scans_cached = research_scans
factory_status.on_research_changed()
factory_status.factory_status({ sections = { "research" } })
check(scans_cached == 1 and research_scans == 2,
  "research is scanned once and again only after a research event, never per read")
local only = factory_status.factory_status({ sections = { "body" }, since_tick = game.tick })
check(only.body and only.lines == nil and only.stock == nil, "sections limits what factory_status reads")
check(not pcall(factory_status.factory_status, { sections = { "orders" } })
  and not pcall(factory_status.factory_status, { since_tick = -1 }), "factory_status validates its parameters")
local events = factory_status.event_state()
check(events.last_plan_ended.plan_id == 3 and events.active_plan_id == 4 and events.queue_depth == 1
  and events.fifo_empty == false and type(events.problem_count) == "number" and events.human_hold == false,
  "event_state reports the last ended plan, queue, problems and hold")
local upkeep_plan = { id = 6, type = "plan", status = "running", current_step = 1, steps = { {} }, source = "upkeep" }
storage.tasks.active, storage.tasks.queue = upkeep_plan, {}
local during_upkeep = factory_status.event_state()
storage.tasks.active, storage.tasks.queue = nil, { { id = 7, type = "plan", source = "upkeep", steps = { {} } } }
local queued_upkeep = factory_status.event_state()
storage.tasks.active, storage.tasks.queue = nil, {}
check(during_upkeep.fifo_empty and during_upkeep.queue_depth == 0 and during_upkeep.active_plan_id == nil
  and queued_upkeep.fifo_empty and queued_upkeep.queue_depth == 0,
  "an upkeep plan, active or queued, leaves event_state's FIFO empty, so it never fires queue_empty")
body.crafting_queue_size = 3
check(factory_status.event_state().fifo_empty == true,
  "hand-crafting in the background leaves the FIFO empty: the body is free for queued work")
body.crafting_queue_size = 0
storage.tasks.active, storage.tasks.queue = active_plan, { {} }
-- next_event's research_finished: the last research the body's force finished.
defines.events = defines.events or {}
defines.events.on_research_finished, defines.events.on_research_started = 77, 78
factory_status.on_research_changed({ name = 78, tick = 500, research = { name = "logistics", force = { name = force.name } } })
local not_finished = factory_status.event_state().last_research_finished
factory_status.on_research_changed({ name = 77, tick = 501, research = { name = "logistics", force = { name = "enemy" } } })
local other_force = factory_status.event_state().last_research_finished
factory_status.on_research_changed({ name = 77, tick = 502, research = { name = "automation", force = { name = force.name } } })
local finished = factory_status.event_state().last_research_finished
check(not_finished == nil and other_force == nil and finished.technology == "automation" and finished.tick == 502,
  "event_state names the last research the body's force finished")
storage.tasks.last_cancel_all_tick = 450
check(factory_status.event_state().last_cancel_all_tick == 450, "event_state carries the last cancel-all tick")
storage.tasks.last_cancel_all_tick = nil

-- Cost and size at 200 machines: about seven machine samples a tick, no
-- entity query, and a status read under 6 KB.
_G.storage = {}
state.init()
storage.registry.ready = true
entities, next_unit = {}, 1000
for i = 1, 200 do furnace((i % 20) * 8, math.floor(i / 20) * 8) end
game.tick = 100000
autonomy.on_tick(game.tick)
queries, reads = 0, 0
for _ = 1, 60 do game.tick = game.tick + 1; autonomy.on_tick(game.tick) end
check(queries == 0 and reads <= 200 * 2 * 2, "200 machines cost no entity query per tick and about 7 machine samples a tick (" .. reads .. " reads in 60 ticks)")
storage.tasks = { queue = {}, records = {} }
local json_size = 0
local function size(value)
  if type(value) == "table" then
    local n = 2
    for key, item in pairs(value) do n = n + #tostring(key) + 4 + size(item) end
    return n
  end
  return #tostring(value) + 2
end
-- Worst case: every section past its cap with long names, many problems, and
-- one starved line with the highest id among 200 running ones.
local furnaces_by_unit = {}
for _, entity in ipairs(entities) do furnaces_by_unit[#furnaces_by_unit + 1] = entity end
local last_furnace = furnaces_by_unit[#furnaces_by_unit]
mock.state(last_furnace).status = RAW.no_ingredients
for i = 1, 4 do mock.state(furnaces_by_unit[i]).status = RAW.no_fuel end
for i = 5, 12 do mock.state(furnaces_by_unit[i]).status = RAW.full_output end
for _ = 1, 700 do
  game.tick = game.tick + 1
  for i = 13, #furnaces_by_unit - 1 do
    if game.tick % 192 == 0 then mock.state(furnaces_by_unit[i]).products_finished = mock.state(furnaces_by_unit[i]).products_finished + 1 end
  end
  autonomy.on_tick(game.tick)
end
-- 28 characters: the longest vanilla Space Age names (electromagnetic-science-pack).
local long = function(i) return string.format("electromagnetic-science-%03d", i) end
summary_stub.status_sections = function()
  local stockpiles, power = {}, {}
  for i = 1, 40 do
    local holders = {}
    for j = 1, 3 do holders[j] = { entity = "steel-chest", position = { x = -1000.5 - j, y = 1000.5 + i }, count = 4800, kind = "chest" } end
    stockpiles[i] = { item = long(i), total = 14400, holders = holders }
  end
  for i = 1, 8 do power[i] = { id = i, satisfaction = 0.123, production_w = 123456789, capacity_w = 987654321 - i,
    demand_w = 123456789, engines_needed = 99 } end
  return { stockpiles = stockpiles, power = power, updated_tick = game.tick, ready = true }
end
summary_stub.patches = function()
  local rows = {}
  for i = 1, 20 do rows[i] = { name = long(i), amount = 123456789, tiles = 9999, centroid = { x = -1234.5, y = 1234.5 } } end
  return rows, true
end
research_stub.progression_status = function()
  local available = {}
  for i = 1, 40 do available[i] = { name = long(i) } end
  return { available = available }
end
factory_status.on_research_changed()
force.research_queue = { { name = long(1) }, { name = long(2) }, { name = long(3) }, { name = long(4) }, { name = long(5) } }
body.get_main_inventory = function() return { get_contents = function()
  local contents = {}
  for i = 1, 40 do contents[i] = { name = long(i), count = 100 + i } end
  return contents
end } end
storage.tasks.active = { id = 4, type = "plan", status = "running", current_step = 2, steps = { {}, { action = "build_layout" } },
  source = "package:" .. long(1) }
local full = factory_status.factory_status({})
json_size = size(full)
local starved_line
for _, line in ipairs(full.lines) do if line.state == "starved" then starved_line = line end end
local max_id = 0
for _, line in ipairs(autonomy.lines()) do if line.id > max_id then max_id = line.id end end
check(full.omitted_lines and full.omitted_lines > 0 and full.omitted_problems and full.omitted_problems > 0
  and full.omitted_stock and full.omitted_power and full.omitted_patches and full.research.omitted_available
  and full.body.inventory_omitted, "the worst-case read fills every section past its cap")
check(starved_line and starved_line.id == max_id and full.lines[#full.lines].state ~= "running" or false,
  "lines needing attention come first, so a starved line with the highest id survives the cap")
check(json_size < 6144, "a worst-case factory_status at 200 machines stays under 6 KB (" .. json_size .. " bytes)")

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
