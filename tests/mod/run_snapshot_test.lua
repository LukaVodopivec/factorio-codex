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
package.loaded["scripts.spatial"] = { observe_compact = function(params)
  check(params.radius == 5, "snapshot reuses a bounded compact observation")
  return { character = { inventory = { ["iron-ore"] = 7 } } }
end }
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
local snapshot, snapshot_ticks = jobs.run_now(run_snapshot.job, {}, 1)
check(snapshot_ticks == 5, "the snapshot reads one surface's statistics of one kind a step (" .. snapshot_ticks .. " ticks)")
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

print("ok   run snapshots retain cumulative resources and bounded diagnostic context")
print("ok   run snapshots count the Codex player's hand-crafted items from the upgrade tick")
print("ok   run snapshots attest game speed, cheat mode, controllers, active mods and modifiers research does not explain")
print("ok   only the recorder baseline marks the body-time window, at its own tick")
