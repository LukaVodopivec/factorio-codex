-- Factory lines kept by the mod (autonomy.lua), the factory_status and
-- event_state reads built on them, and the 0.21 storage upgrade. Machines are
-- strict LuaEntity mocks advanced by a small tick simulation.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local RAW = { working = 1, no_fuel = 2, no_ingredients = 3, item_ingredient_shortage = 4,
  waiting_for_space_in_destination = 5, full_output = 6, normal = 7, no_power = 8, no_minable_resources = 9,
  waiting_to_launch_rocket = 10 }
_G.defines = { entity_status = RAW, inventory = { crafter_input = 2, lab_input = 3 },
  rocket_silo_status = { building_rocket = 1, rocket_ready = 10 } }
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
local surface = { index = 1, find_entities_filtered = function(filter)
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
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)

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
    force = force, surface = surface, status = RAW.working }
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
-- The recorder's machine groups name their recipe and the products the
-- sampler last read, so tooling tells machine-made from hand-made output.
local snapshot_groups = require("scripts.map_summary").registry_factory().groups
local furnace_group, finished_total
for _, group in ipairs(snapshot_groups) do if group.entity == "stone-furnace" then furnace_group = group end end
finished_total = 0
for _, f in ipairs({ f1, f2, f3, far }) do finished_total = finished_total + mock.state(f).products_finished end
check(furnace_group and furnace_group.recipe == "iron-plate" and furnace_group.machine_count == 4
  and finished_total > 50 and furnace_group.products_finished >= finished_total - 3
  and furnace_group.products_finished <= finished_total,
  "run_snapshot groups carry the recipe and products_finished (" .. tostring(furnace_group and furnace_group.products_finished)
    .. " of " .. finished_total .. ")")

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
run(30)
local problem_cursor = game.tick
local immature = autonomy.problems(problem_cursor)
local immature_fuel = false
for _, row in ipairs(immature) do if row.status == "no_fuel" then immature_fuel = true end end
check(not immature_fuel, "a new raw problem remains hidden before its debounce completes")
run(630)
local matured_fuel = false
for _, row in ipairs(autonomy.problems(problem_cursor)) do
  if row.status == "no_fuel" then matured_fuel = row.count == 2 end
end
check(matured_fuel, "a problem maturing after the cursor is returned even when it began before the cursor")
local after_announcement = autonomy.problems(storage.autonomy.last_problem_tick + 1)
local repeated_fuel = false
for _, row in ipairs(after_announcement) do if row.status == "no_fuel" then repeated_fuel = true end end
check(not repeated_fuel, "a cursor after announcement does not repeat the same problem episode")
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
local good_units = registry.machine_units
registry.machine_units = function() error("registry read failed") end
local lines_before = #autonomy.lines()
storage.autonomy.dirty_tick = game.tick - 300
run(1)
check(#autonomy.lines() == lines_before and storage.autonomy.refresh_error:match("registry read failed"),
  "a failed refresh keeps the previous lines and reports its error")
registry.machine_units = good_units

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

-- factory_status composes the sections; event_state stays cheap. Power rows
-- are map_summary.build_power's (map_summary tests cover them); stock is
-- the registry's per-item aggregate with its largest holder.
local power_reads = {}
local summary_stub = {
  build_power = function(target, limit)
    power_reads[#power_reads + 1] = { surface = target, limit = limit }
    return { { network_id = 7, satisfaction = 0.5, production_w = 900000, capacity_w = 900000, demand_w = 1800000,
      sustained_w = 900000, headroom_w = -900000, sources = { { kind = "steam", count = 1, nameplate_w = 900000, production_w = 900000 } },
      night_s = 125, add_to_cover = { steam_engine = 1 } } }, 0
  end,
  patches = function() return { { name = "iron-ore", amount = 5000, tiles = 20, centroid = { x = 30, y = 40 } } } end,
}
package.loaded["scripts.map_summary"] = summary_stub
storage.registry.entries[9001] = { unit = 9001, name = "wooden-chest", type = "container", position = { x = 1, y = 1 }, surface = 1 }
storage.registry.stock[1] = { coal = { total = 50, unit = 9001, count = 40 }, ["iron-plate"] = { total = 0, count = 0 } }
storage.registry.pass_tick = 5
-- Research: the available set is built once from the force's technologies
-- and kept by research events (a finished research checks its successors).
local technology_reads = 0
local function technology(name, researched, prerequisites, enabled)
  return setmetatable({ name = name, researched = researched, enabled = enabled ~= false, prerequisites = prerequisites or {},
    successors = {}, force = { name = "player" } }, { __index = function(_, key) if key == "read" then technology_reads = technology_reads + 1 end end })
end
local automation = technology("automation", true)
local logistics = technology("logistics", false, { automation = automation })
local electronics = technology("electronics", false, { logistics = logistics })
local disabled = technology("hidden-tech", false, {}, false)
local triggered = technology("steam-power", false, {})
logistics.successors = { electronics = electronics }
local technology_walks = 0
force.technologies = setmetatable({}, { __pairs = function()
  technology_walks = technology_walks + 1
  return next, { automation = automation, logistics = logistics, electronics = electronics, ["hidden-tech"] = disabled,
    ["steam-power"] = triggered }, nil
end })
local research_stub = { research_trigger = function(tech) return tech == triggered and { type = "craft-item" } or nil end,
  unit_time_s = function() return nil end }
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
check(status.tick == game.tick and type(status.lines) == "table" and status.power[1].add_to_cover.steam_engine == 1
  and power_reads[1].surface == surface and power_reads[1].limit == 1 and status.omitted_power == nil
  and status.stock[1].item == "coal" and status.stock[1].total == 50 and #status.stock == 1
  and #status.stock[1].holders == 1 and status.stock[1].holders[1].kind == "chest" and status.stock[1].holders[1].count == 40
  and status.stock_power_tick == 5 and status.stock_power_ready == true and status.logistics == nil
  and status.research.progress == 0.25 and status.research.queue[1] == "automation"
  and status.research.current == "automation" and status.research.available[1] == "logistics"
  and status.body.queue_depth == 1 and status.body.active_step.source == "package:p1"
  and status.body.inventory_summary["iron-plate"] == 9 and status.body.human_control == false
  and status.patches[1].name == "iron-ore" and status.patches[1].distance == 50,
  "factory_status composes lines, problems, power, stock, research, body and patches")
check(#status.research.available == 1 and technology_walks == 1,
  "available research is enabled, unresearched, with every prerequisite done and no trigger")
defines.events = defines.events or {}
defines.events.on_research_finished, defines.events.on_research_started = 77, 78
defines.events.on_research_reversed = 79
factory_status.factory_status({ sections = { "research" } })
factory_status.on_research_changed({ name = 78, tick = 600, research = logistics })
check(technology_walks == 1, "research reads reuse the kept set; starting a research changes nothing")
logistics.researched = true
factory_status.on_research_changed({ name = 77, tick = 601, research = logistics })
local after_finish = factory_status.factory_status({ sections = { "research" } }).research.available
check(technology_walks == 1 and #after_finish == 1 and after_finish[1] == "electronics",
  "a finished research leaves the set and adds the successors it unlocked, without a walk")
factory_status.on_research_changed({ name = 79, tick = 602, research = logistics })
logistics.researched = false
local reversed = factory_status.factory_status({ sections = { "research" } }).research.available
check(technology_walks == 2 and reversed[1] == "logistics",
  "a reversed research rebuilds the set once on the next read")
-- A levelled (infinite) technology finishing a level stays unresearched and
-- researchable: it stays in the kept set, as a rebuild would list it.
factory_status.on_research_changed({ name = 77, tick = 603, research = logistics })
local levelled = factory_status.factory_status({ sections = { "research" } }).research.available
check(technology_walks == 2 and #levelled == 1 and levelled[1] == "logistics",
  "a finished level of an infinite technology keeps it available without a walk")
storage.last_research_finished = nil
force.logistic_networks = { nauvis = {} }
surface.name = "nauvis"
local robots = factory_status.factory_status({ sections = { "logistics" } })
check(robots.logistics and #robots.logistics.networks == 0 and robots.lines == nil and robots.body == nil,
  "logistics is read only when named in sections")
local only = factory_status.factory_status({ sections = { "body" }, since_tick = game.tick })
check(only.body and only.lines == nil and only.stock == nil, "sections limits what factory_status reads")
check(status.platforms == nil, "platforms is absent until the force has a platform")
defines.space_platform_state = { waiting_for_starter_pack = 0 }
force.platforms = { [1] = mock.space_platform({ valid = true, index = 1, name = "alpha", scheduled_for_deletion = 0,
  state = defines.space_platform_state.waiting_for_starter_pack, speed = 0 }) }
local with_platform = factory_status.factory_status({ sections = { "platforms" } })
check(#with_platform.platforms == 1 and with_platform.platforms[1].name == "alpha"
  and with_platform.platforms[1].state == "waiting_for_starter_pack" and with_platform.lines == nil,
  "factory_status lists the force's platforms, one compact line each")
force.platforms = nil
check(not pcall(factory_status.factory_status, { sections = { "orders" } })
  and not pcall(factory_status.factory_status, { since_tick = -1 }), "factory_status validates its parameters")
local events = factory_status.event_state()
check(events.last_plan_ended.plan_id == 3 and events.active_plan_id == 4 and events.queue_depth == 1
  and events.fifo_empty == false and type(events.problem_count) == "number" and events.human_hold == false,
  "event_state reports the last ended plan, queue, problems and hold")
check(events.last_space_event_tick == nil and events.space_events == nil, "no space event yet: none reported")
require("scripts.platforms").record("rocket_launched", { silo = { x = 1, y = 2 } })
local spaced = factory_status.event_state()
check(spaced.last_space_event_tick == game.tick and spaced.space_events[1].kind == "rocket_launched",
  "event_state reports the newest space event's tick and the last entries")
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
factory_status.on_research_changed({ name = 78, tick = 500, research = { name = "logistics", force = { name = force.name } } })
local not_finished = factory_status.event_state().last_research_finished
factory_status.on_research_changed({ name = 77, tick = 501, research = { name = "logistics", force = { name = "enemy" } } })
local other_force = factory_status.event_state().last_research_finished
factory_status.on_research_changed({ name = 77, tick = 502, research = { name = "automation", force = { name = force.name } } })
local finished = factory_status.event_state().last_research_finished
check(not_finished == nil and other_force == nil and finished.technology == "automation" and finished.tick == 502,
  "event_state names the last research the body's force finished")
local real_labs = registry.labs
local no_labs = factory_status.event_state().research_idle
registry.labs = function() return { count = 2, speed = 2, pack_rate = 0, progress_rate = 0 } end
local researching = factory_status.event_state().research_idle
local running_research = force.current_research
force.current_research = nil
local idle_research = factory_status.event_state().research_idle
registry.labs = real_labs
local idle_without_labs = factory_status.event_state().research_idle
force.current_research = running_research
check(researching == false and idle_research == true,
  "event_state says whether the body's force has labs and no research running (labs idle)")
check(no_labs == false and idle_without_labs == false,
  "with no lab, event_state never reports idle labs (a trigger technology may finish first)")
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
-- The refresh identifies 32 machines a tick and swaps the lines in on its
-- last tick; until then the previous (here: no) lines stay.
local recipe_reads, most_identified, refresh_ticks = 0, 0, 0
for _, entity in ipairs(entities) do
  local get_recipe = entity.get_recipe
  entity.get_recipe = function() recipe_reads = recipe_reads + 1; return get_recipe() end
end
repeat
  local before = recipe_reads
  autonomy.on_tick(game.tick)
  most_identified = math.max(most_identified, recipe_reads - before)
  refresh_ticks = refresh_ticks + 1
  local pending = storage.autonomy.refresh_job ~= nil
  if pending then
    check(#autonomy.lines() == 0, "while a refresh runs the previous lines stay")
    game.tick = game.tick + 1
  end
until not pending or refresh_ticks > 20
check(refresh_ticks == 7 and most_identified <= 32 and #autonomy.lines() > 0,
  "200 machines are identified over " .. refresh_ticks .. " ticks, at most " .. most_identified .. " a tick")
queries, reads = 0, 0
for _ = 1, 60 do game.tick = game.tick + 1; autonomy.on_tick(game.tick) end
check(queries == 0 and reads <= 200 * 2 * 2, "200 machines cost no entity query per tick and about 7 machine samples a tick (" .. reads .. " reads in 60 ticks)")
-- 200 single-furnace lines starving at once: at most 16 causes are worked
-- out per evaluate, the rest keep theirs and go first next time.
local cause_reads = 0
for _, entity in ipairs(entities) do
  local get_inventory = entity.get_inventory
  entity.get_inventory = function(id) cause_reads = cause_reads + 1; return get_inventory(id) end
  mock.state(entity).status = RAW.no_ingredients
end
-- (They count as running until 600 ticks after their last progress.)
local most_causes, evaluates, stalled_evaluates = 0, 0, 0
local with_cause = 0
repeat
  game.tick = game.tick + 1
  local before = cause_reads
  autonomy.on_tick(game.tick)
  if game.tick % 30 == 29 then
    evaluates = evaluates + 1
    most_causes = math.max(most_causes, cause_reads - before)
    with_cause = 0
    for _, row in ipairs(autonomy.lines()) do if row.cause == "iron-ore" then with_cause = with_cause + 1 end end
    if with_cause > 0 then stalled_evaluates = stalled_evaluates + 1 end
  end
until with_cause == 200 or evaluates > 60
check(with_cause == 200 and most_causes <= 16 and stalled_evaluates == 13,
  "200 lines stalling together get their causes " .. most_causes .. " an evaluate, all within " .. stalled_evaluates .. " evaluates")
local phases = {}
for _, id in ipairs(storage.autonomy.line_order) do phases[storage.autonomy.lines[id].cause_tick % 600] = true end
local phase_count = 0
for _ in pairs(phases) do phase_count = phase_count + 1 end
check(phase_count > 1, "their causes age from " .. phase_count .. " phases, not one")
for _, entity in ipairs(entities) do mock.state(entity).status = RAW.working end
for _ = 1, 30 do game.tick = game.tick + 1; autonomy.on_tick(game.tick) end
storage.tasks = { queue = {}, records = {} }
local json_size = 0
-- JSON length estimate: objects count each quoted key, colon and comma;
-- arrays (helpers.table_to_json writes sequences as arrays) only commas.
local function size(value)
  if type(value) == "table" then
    local n, count = 2, 0
    for _ in pairs(value) do count = count + 1 end
    local array = count > 0 and count == #value
    for key, item in pairs(value) do n = n + (array and 1 or #tostring(key) + 4) + size(item) end
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
storage.registry.stock[1], storage.registry.pass_tick = {}, game.tick
for i = 1, 40 do
  storage.registry.entries[20000 + i] = { unit = 20000 + i, name = "steel-chest", type = "container",
    position = { x = -1000.5 - i, y = 1000.5 + i }, surface = 1 }
  storage.registry.stock[1][long(i)] = { total = 14400 + i, unit = 20000 + i, count = 4800 }
end
-- The widest power row (steam, turbines and solar on one network) up to the
-- cap, with 6 more networks left out.
summary_stub.build_power = function(_, limit)
  local rows = {}
  for i = 1, limit do rows[i] = { network_id = 1000 + i, satisfaction = 0.123, production_w = 123456789,
    capacity_w = 987654321 - i, demand_w = 1234567890, sustained_w = 987654321, headroom_w = -246913569,
    night_s = 124.9, sources = {}, accumulators = { count = 9999, stored_j = 49995000000, capacity_j = 49995000000, charge = 0.999 },
    add_to_cover = { solar_panel = 99999, accumulator = 99999 } }
    for _, kind in ipairs({ "nuclear", "solar", "steam" }) do
      rows[i].sources[#rows[i].sources + 1] = { kind = kind, count = 9999, nameplate_w = 987654321, production_w = 123456789 }
    end
  end
  return rows, 6
end
summary_stub.patches = function()
  local rows = {}
  for i = 1, 20 do rows[i] = { name = long(i), amount = 123456789, tiles = 9999, centroid = { x = -1234.5, y = 1234.5 } } end
  return rows, true
end
local many_technologies = {}
for i = 1, 40 do many_technologies[long(i)] = technology(long(i), false) end
force.technologies = many_technologies
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

-- A machine mined while a refresh is still identifying the snapshot is left
-- out; the refresh completes and the removal's dirty mark is kept.
_G.storage = {}
state.init()
storage.registry.ready = true
entities = {}
for i = 1, 40 do furnace((i % 8) * 8, math.floor(i / 8) * 8) end
local mined = entities[#entities]
local mined_unit = mined.unit_number
game.tick = game.tick + 1
autonomy.on_tick(game.tick)
local job_running = storage.autonomy.refresh_job ~= nil
game.tick = game.tick + 1
autonomy.on_entity_changed({ entity = mined })
local removal_tick = storage.autonomy.dirty_tick
registry.remove(mined_unit)
mined.valid = false
mock.unreadable(mined, "type")
autonomy.on_tick(game.tick)
local identified = 0
for _ in pairs(storage.autonomy.machines) do identified = identified + 1 end
check(job_running and storage.autonomy.refresh_job == nil and storage.autonomy.refresh_error == nil
  and storage.autonomy.machines[mined_unit] == nil and identified == 39 and #autonomy.lines() > 0,
  "a machine mined during a refresh is left out and the refresh completes")
check(removal_tick == game.tick and storage.autonomy.dirty_tick == removal_tick,
  "the removal's dirty mark survives the refresh that was running")
-- A refresh that fails mid-job keeps a dirty mark set while it ran, so the
-- next refresh is 300 ticks away, not the safety refresh's minute.
local broken = furnace(200, 200)
mock.unreadable(broken, "type")
storage.autonomy.dirty_tick = game.tick - 300
game.tick = game.tick + 1
autonomy.on_tick(game.tick)
game.tick = game.tick + 1
autonomy.mark_dirty()
local mark = storage.autonomy.dirty_tick
autonomy.on_tick(game.tick)
check(storage.autonomy.refresh_error ~= nil and storage.autonomy.refresh_job == nil and mark == game.tick
  and storage.autonomy.dirty_tick == mark, "a refresh failing mid-job keeps the dirty mark set while it ran")
mock.unreadable(broken, "type", false)

-- A silo's rocket becoming ready is recorded in the space event ring by the
-- sampler's own reads: once per transition, never for a silo first seen
-- ready. A ready silo's idle line says why.
local silo = machine("rocket-silo", "rocket-silo", 300, 300, { products_finished = 0,
  get_recipe = function() return nil end, get_inventory = function() return inventory({}) end })
mock.state(silo).rocket_status = defines.rocket_silo_status.rocket_ready
mock.read(silo, "rocket_silo_status", function() return mock.state(silo).rocket_status end)
autonomy.refresh()
local function sample_silo(times)
  for _ = 1, times * 30 do game.tick = game.tick + 1; autonomy.on_tick(game.tick) end
end
local function ready_events()
  local n = 0
  for _, row in ipairs(storage.space.events) do if row.kind == "rocket_ready" then n = n + 1 end end
  return n
end
sample_silo(2)
check(ready_events() == 0, "a silo first sampled with a ready rocket is not news")
mock.state(silo).rocket_status = defines.rocket_silo_status.building_rocket
sample_silo(1)
mock.state(silo).rocket_status = defines.rocket_silo_status.rocket_ready
mock.state(silo).status = RAW.waiting_to_launch_rocket
sample_silo(3)
local event = storage.space.events[#storage.space.events]
check(ready_events() == 1 and event.silo.x == 300 and storage.space.last_event_tick == event.tick,
  "the rocket becoming ready is one rocket_ready event naming the silo")
sample_silo(30)
local silo_line
for _, line in ipairs(autonomy.lines()) do if line.entity == "rocket-silo" then silo_line = line end end
check(silo_line and silo_line.state == "idle" and silo_line.cause == "rocket_ready",
  "a silo waiting to launch is idle with cause rocket_ready")

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
