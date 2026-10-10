local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. here .. "/../../mod/agentic-companion/?/init.lua;" .. package.path

local function check(value, message) if not value then error("FAIL: " .. message, 2) end end

-- Two factory surfaces: Nauvis (the body's) and Vulcanus, each with its own
-- statistics; the recorder's items/fluids are their sums.
local nauvis = { index = 1, name = "nauvis" }
local vulcanus = { index = 2, name = "vulcanus" }
local stats = {
  [1] = { item = { input_counts = { ["iron-ore"] = 12, ["copper-ore"] = 4 }, output_counts = { ["iron-ore"] = 5 } },
    fluid = { input_counts = { ["crude-oil"] = 100, water = 1000 }, output_counts = {} } },
  [2] = { item = { input_counts = { ["iron-ore"] = 3, calcite = 9 }, output_counts = {} },
    fluid = { input_counts = { lava = 500 }, output_counts = {} } },
}
local statistics_reads = 0
local body = {
  force = {
    get_item_production_statistics = function(surface) statistics_reads = statistics_reads + 1; return stats[surface.index].item end,
    get_fluid_production_statistics = function(surface) statistics_reads = statistics_reads + 1; return stats[surface.index].fluid end,
  },
  surface = nauvis,
}
package.loaded["scripts.registry"] = { surfaces = function() return { 1, 2 } end }
package.loaded["scripts.companion"] = { require_companion = function() return body end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
-- The attestation facts: the Codex player, the active mods, and the force's
-- and character's modifiers against the researched technologies' effects.
local codex_player = { cheat_mode = false, controller_type = 7, physical_controller_type = 1 }
_G.defines = { controllers = { character = 1, god = 2, editor = 3, remote = 7 } }
local present = package.loaded["scripts.companion"].require_present
package.loaded["scripts.companion"].require_present = function()
  local b = present(); b.player = codex_player; return b
end
_G.script = { active_mods = { base = "2.0.77", ["space-age"] = "2.0.77", ["agentic-companion"] = "0.32.0", extra = "1.0.0" } }
body.force.technologies = {
  toolbelt = { researched = true, level = 1, prototype = { level = 1, max_level = 1 } },
  ["steel-axe"] = { researched = false, level = 1, prototype = { level = 1, max_level = 1 } },
  ["mining-productivity-3"] = { researched = false, level = 5, prototype = { level = 3, max_level = 4294967295 } },
}
body.force.character_inventory_slots_bonus = 10 -- toolbelt explains it
body.force.manual_mining_speed_modifier = 0 -- steel axe not researched, none granted
body.force.mining_drill_productivity_bonus = 0.2 -- two finished infinite levels
body.force.manual_crafting_speed_modifier = 2 -- no research grants it
body.character_reach_distance_bonus = 5 -- no research raises the character's own
body.character_crafting_speed_modifier = 0
package.loaded["scripts.spatial"] = {
  observe_compact = function() error("a snapshot reads the body's state without an observation's entity scan") end,
  body_state = function(c)
    check(c.character == body and c.body.character == body, "the snapshot reads the body's own observation state")
    return { inventory = { ["iron-ore"] = 7 } }
  end,
}
package.loaded["scripts.map_summary"] = {
  map_summary = function() error("a snapshot never walks the charted chunks") end,
  registry_factory = function() return { scope = "registry", machine_count = 2 } end,
}
package.loaded["scripts.research"] = { progression_status = function() return { researched = { "automation" } } end }

_G.game = { tick = 18000, speed = 1, get_surface = function(index) return ({ nauvis, vulcanus })[index] end }
_G.prototypes = { technology = {
  toolbelt = { effects = { { type = "character-inventory-slots-bonus", modifier = 10 } } },
  ["steel-axe"] = { effects = { { type = "character-mining-speed", modifier = 1 } } },
  ["mining-productivity-3"] = { effects = { { type = "mining-drill-productivity-bonus", modifier = 0.1 } } },
  automation = { effects = { { type = "unlock-recipe", recipe = "assembling-machine-1" } } },
}, entity = {
  iron = { type = "resource", mineable_properties = { products = { { name = "iron-ore", type = "item" } } } },
  oil = { type = "resource", mineable_properties = { products = { { name = "crude-oil", type = "fluid" } } } },
  tree = { type = "tree", mineable_properties = { products = { { name = "wood" } } } },
  wreck = { type = "simple-entity", mineable_properties = { products = { { name = "iron-gear-wheel" } } } },
  water = { type = "resource", mineable_properties = { products = { { name = "water", type = "fluid" } } } },
  assembler = { type = "assembling-machine", mineable_properties = { products = { { name = "assembling-machine-1" } } } },
} }

-- Hand-crafts of the Codex player count; another player's do not.
_G.storage = { companion = { player_index = 1 }, factory_activity = { epoch_tick = 0, events = {}, events_omitted = 0 } }
local activity = require("scripts.factory_activity")
activity.on_player_crafted_item({ player_index = 1, item_stack = { name = "iron-gear-wheel", count = 1 } })
activity.on_player_crafted_item({ player_index = 1, item_stack = { name = "iron-gear-wheel", count = 1 } })
activity.on_player_crafted_item({ player_index = 1, item_stack = { name = "transport-belt", count = 2 } })
activity.on_player_crafted_item({ player_index = 2, item_stack = { name = "transport-belt", count = 2 } })
local jobs = require("scripts.jobs")
local run_snapshot = require("scripts.run_snapshot")
-- Phase costs come from counts every peer reads alike (# of a
-- LuaCustomTable), never from the per-load caches the first snapshot
-- builds: a client that joined later has not built them, and its job would
-- take other ticks than the server's.
setmetatable(prototypes.technology, { __len = function() return 4 end })
setmetatable(prototypes.entity, { __len = function() return 6 end })
local function phase_costs()
  return run_snapshot.PHASES.attestation.cost(nil, body) .. "/" .. run_snapshot.PHASES.resources.cost(nil, body)
end
local costs_before = phase_costs()
local snapshot, snapshot_ticks = jobs.run_now(run_snapshot.job, {}, 1)
check(phase_costs() == costs_before, "the per-load caches leave the phase costs as they were ("
  .. costs_before .. " before the first snapshot, " .. phase_costs() .. " after)")
-- Four statistics reads, then the seven phases, each its own tick.
check(snapshot_ticks >= 4 + 7, "the snapshot reads one surface's statistics of one kind a step, then a phase a step ("
  .. snapshot_ticks .. " ticks)")
local hand = snapshot.statistics.hand_crafted
check(hand.since_tick == 0 and #hand.items == 2 and hand.items[1].name == "iron-gear-wheel" and hand.items[1].count == 2
  and hand.items[2].name == "transport-belt" and hand.items[2].count == 2,
  "the snapshot counts the Codex player's hand-crafted items exactly, sorted")
-- A save from before the counter starts it at the upgrade tick.
_G.storage = { factory_activity = { epoch_tick = 0, events = {}, events_omitted = 0 } }
_G.game.tick = 18000
require("scripts.state").init()
check(storage.factory_activity.hand_crafted_since_tick == 18000 and next(storage.factory_activity.hand_crafted) == nil,
  "an upgraded save counts hand-crafts from the upgrade tick")
check(snapshot.tick == 18000 and snapshot.character.inventory["iron-ore"] == 7, "tick and character state are retained")
check(snapshot.factory.machine_count == 2 and snapshot.progression.researched[1] == "automation", "factory and progression context are retained")
check(snapshot.statistics.items.produced[1].name == "calcite" and snapshot.statistics.items.produced[2].name == "copper-ore"
  and snapshot.statistics.items.produced[3].name == "iron-ore" and snapshot.statistics.items.produced[3].count == 15,
  "nonzero counters are summed over the factory surfaces and sorted")
local by_surface = snapshot.statistics.by_surface
check(by_surface.nauvis.items.produced[2].count == 12 and by_surface.vulcanus.items.produced[2].count == 3
  and by_surface.vulcanus.fluids.produced[1].name == "lava" and snapshot.statistics.fluids.produced[2].name == "lava",
  "statistics.by_surface keeps each surface's own counters beside the sums")
check(statistics_reads == 4, "one item and one fluid statistics read per factory surface (" .. statistics_reads .. ")")
check(#snapshot.statistics.raw_resources == 3, "natural resource products are derived and utility water is excluded")
check(snapshot.statistics.raw_resources[1].name == "crude-oil" and snapshot.statistics.raw_resources[2].name == "iron-ore"
  and snapshot.statistics.raw_resources[3].name == "wood", "raw resource identities are deterministic")
check(snapshot.statistics.semantics.produced == "force_surface_input_counts", "native production semantics are explicit")
local attest = snapshot.attestation
check(attest.game_speed == 1 and attest.cheat_mode == false and attest.controller == "remote"
  and attest.physical_controller == "character", "the attestation states game speed, cheat mode and both controllers by name")
check(attest.mods.base == "2.0.77" and attest.mods.extra == "1.0.0" and attest.mods["agentic-companion"] == "0.32.0",
  "the attestation lists every active mod with its version")
check(#attest.bonuses == 2 and attest.bonuses[1].scope == "character" and attest.bonuses[1].name == "character_reach_distance_bonus"
  and attest.bonuses[1].value == 5 and attest.bonuses[1].from_research == 0
  and attest.bonuses[2].scope == "force" and attest.bonuses[2].name == "manual_crafting_speed_modifier"
  and attest.bonuses[2].value == 2 and attest.bonuses[2].from_research == 0,
  "only modifiers research does not explain are listed; researched and infinite levels explain theirs")

-- One surface: its own counters are the sums, with no by_surface copy.
package.loaded["scripts.registry"].surfaces = function() return { 1 } end
statistics_reads = 0
local single = jobs.run_now(run_snapshot.job, {})
check(single.statistics.by_surface == nil and single.statistics.items.produced[2].count == 12 and statistics_reads == 2,
  "a single-surface snapshot has no by_surface: the sums are that surface's")
package.loaded["scripts.registry"].surfaces = function() return { 1, 2 } end

-- Prototypes are walked once: a later snapshot reuses the rows.
local walked = 0
local entities = prototypes.entity
_G.prototypes = { entity = setmetatable({}, { __pairs = function() walked = walked + 1; return next, entities, nil end }) }
local again = jobs.run_now(run_snapshot.job, {})
check(walked == 0 and #again.statistics.raw_resources == 3, "a later snapshot reuses the raw resource rows without a prototype walk")

-- Only the recorder's baseline (window = true) marks the body-time window, at the sample's tick.
storage.tasks = storage.tasks or {}
storage.tasks.body_time = { since_tick = 0, state = "idle", state_since = 100, ticks = {}, gaps = {} }
local plain = jobs.run_now(run_snapshot.job, {})
check(plain.body_time.window_tick == nil and storage.tasks.body_time.window_tick == nil, "an ordinary sample marks no window")
local marked = jobs.run_now(run_snapshot.job, { window = true })
check(marked.body_time.window_tick == marked.tick and storage.tasks.body_time.window_tick == marked.tick,
  "the baseline sample marks the window at its own tick")
check(plain.body_time.phases == nil and plain.body_time.tiles == nil, "a counter without phases exports none")
storage.tasks.body_time.phases, storage.tasks.body_time.tiles = { walk = 30, craft_wait = 12, other = 4 }, 7.26
local phased = jobs.run_now(run_snapshot.job, {})
check(phased.body_time.phases.walk == 30 and phased.body_time.phases.craft_wait == 12 and phased.body_time.phases.other == 4
  and phased.body_time.tiles == 7.3, "the snapshot exports the body phases and the tiles walked, to a tenth")

-- The recorder's strict schemas parse this record as the mod sends it
-- (companion/test/run-telemetry.test.ts reads the fixture): body_time in the
-- waiting state with its phases, tiles and a gap ended by waiting work. The
-- encoding mirrors helpers.table_to_json, an empty table as []. Run with
-- UPDATE_FIXTURES=1 to rewrite the fixture after a deliberate change.
do
  local time = storage.tasks.body_time
  time.state, time.state_since = "waiting", game.tick - 10
  time.ticks = { idle = 40, pilot = 90, package = 20, waiting = 10 }
  time.gaps = { pilot = { count = 1, ticks = 40, longest = 40, longest_end_tick = game.tick - 30 } }
  time.phases, time.tiles = { walk = 60, mine = 10, smelt_wait = 5, craft_wait = 15, other = 20 }, 21.26
  local record = jobs.run_now(run_snapshot.job, {})
  local json = (dofile(here .. "/table_to_json.lua")(record):gsub("{}", "[]")) .. "\n"
  local path = here .. "/fixtures/run-snapshot-0.37.json"
  if os.getenv("UPDATE_FIXTURES") == "1" then
    local file = assert(io.open(path, "w")); file:write(json); file:close()
  end
  local file = assert(io.open(path, "r"))
  local fixture = file:read("a")
  file:close()
  check(fixture == json, "the run snapshot fixture is the record the mod sends (UPDATE_FIXTURES=1 rewrites it)")
end

-- The phases: within a small budget each runs whole in its own tick, one
-- whose cost does not fit what is left waits once for a fresh tick, and
-- the record equals one taken in a single tick.
do
  local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  local whole, whole_ticks = jobs.run_now(run_snapshot.job, {}, 1000000)
  check(whole_ticks == 1, "with a whole tick's budget for it the snapshot finishes in one tick")
  -- 120 technologies: progression costs more than a 30-item tick.
  setmetatable(body.force.technologies, { __len = function() return 120 end })
  local ran, step = {}, 0
  local runs = {}
  for name, phase in pairs(run_snapshot.PHASES) do
    runs[name] = phase.run
    phase.run = function(...) ran[#ran + 1] = { phase = name, step = step }; return runs[name](...) end
  end
  local S = run_snapshot.job.start({})
  local sliced, most = nil, 0
  while sliced == nil and step < 100 do
    step = step + 1
    local budget = { left = 30 }
    sliced = run_snapshot.job.step(S, budget)
    most = math.max(most, 30 - budget.left)
  end
  for name, run in pairs(runs) do run_snapshot.PHASES[name].run = run end
  setmetatable(body.force.technologies, nil)
  local steps_of, order = {}, {}
  for _, row in ipairs(ran) do steps_of[row.phase], order[#order + 1] = row.step, row.phase end
  check(table.concat(order, ",") == "progression,factory,lines,attestation,resources,character,assemble",
    "the phases run once each, in order: " .. table.concat(order, ","))
  local alone = true
  for _, row in ipairs(ran) do
    if row.phase ~= "progression" and row.step == steps_of.progression then alone = false end
  end
  check(alone and steps_of.factory > steps_of.progression and steps_of.progression > 1,
    "progression (120 technologies) waits for a fresh tick after the reads, runs whole alone there, and the next phase waits")
  check(most <= 30 + 1 + 120, "no tick spends more than its budget and one phase (" .. most .. ")")
  check(same(sliced, whole), "a snapshot spread over " .. step .. " ticks equals one taken in a single tick")
  -- A snapshot saved by 0.34 mid-read has no phase: it continues.
  local old = run_snapshot.job.start({})
  old.phase = nil
  check(same(jobs.run_now({ start = function() return old end, step = run_snapshot.job.step }, {}, 5), whole),
    "a snapshot saved by 0.34 without a phase finishes after the upgrade")
end

-- The run's milestones (first ticks: rockets, and each technology the
-- body's force finished), the hold episodes and the handler fault count.
do
  body.force.name = "player"
  local function finished(name, force, tick)
    run_snapshot.on_research_finished({ research = { name = name, force = { name = force } }, tick = tick })
  end
  finished("automation", "player", 600)
  finished("automation", "player", 900)
  finished("logistics", "enemy", 700)
  finished("logistics", "player", 800)
  storage.milestones.rocket_launched_tick = 1200
  storage.milestones.platform_created_tick, storage.milestones.boarded_tick = 1300, 1400
  storage.milestones.arrived_tick, storage.milestones.landed_tick = 1500, 1600
  storage.tasks.holds = { count = 2, total_ticks = 40, recent = { { start_tick = 10, end_tick = 50, cause = "mine" },
    { start_tick = 17990, cause = "gui" } } }
  storage.tasks.human_hold = { since = 17990 }
  storage.handler_errors = { count = 3, recent = {} }
  local sampled = jobs.run_now(run_snapshot.job, {})
  local m = sampled.milestones
  check(m.research.automation == 600 and m.research.logistics == 800 and m.rocket_launched_tick == 1200
    and m.rocket_ready_tick == nil and m ~= storage.milestones and m.research ~= storage.milestones.research,
    "the snapshot copies the milestones: each technology's first finish by the body's force, the rocket ticks")
  check(m.platform_created_tick == 1300 and m.boarded_tick == 1400 and m.arrived_tick == 1500 and m.landed_tick == 1600,
    "the snapshot copies the space milestones: platform created, boarded, arrived, landed")
  local holds = sampled.holds
  check(holds.count == 2 and holds.total_ticks == 40 + sampled.tick - 17990 and holds.recent[1].cause == "mine"
    and holds.recent[2].end_tick == nil and holds.recent[2] ~= storage.tasks.holds.recent[2],
    "the snapshot copies the hold episodes, an open one's ticks so far included in total_ticks")
  check(sampled.handler_errors == 3, "the snapshot carries the count of caught handler faults")
  storage.tasks.holds, storage.tasks.human_hold, storage.handler_errors = nil, nil, nil
  local bare = jobs.run_now(run_snapshot.job, {})
  check(bare.holds == nil and bare.handler_errors == 0, "a save without the stores samples no holds and zero faults")
end

print("ok   run snapshots retain cumulative resources and bounded diagnostic context")
print("ok   run snapshots count the Codex player's hand-crafted items from the upgrade tick")
print("ok   run snapshots attest game speed, cheat mode, controllers, active mods and modifiers research does not explain")
print("ok   only the recorder baseline marks the body-time window, at its own tick")
