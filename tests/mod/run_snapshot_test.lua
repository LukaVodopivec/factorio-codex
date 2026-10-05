local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. here .. "/../../mod/agentic-companion/?/init.lua;" .. package.path

local function check(value, message) if not value then error("FAIL: " .. message, 2) end end

local item_stats = { input_counts = { ["iron-ore"] = 12, ["copper-ore"] = 4 }, output_counts = { ["iron-ore"] = 5 } }
local fluid_stats = { input_counts = { ["crude-oil"] = 100, water = 1000 }, output_counts = {} }
local body = {
  force = {
    get_item_production_statistics = function() return item_stats end,
    get_fluid_production_statistics = function() return fluid_stats end,
  },
  surface = {},
}
package.loaded["scripts.companion"] = { require_companion = function() return body end }
package.loaded["scripts.spatial"] = { observe_compact = function(params)
  check(params.radius == 5, "snapshot reuses a bounded compact observation")
  return { character = { inventory = { ["iron-ore"] = 7 } } }
end }
package.loaded["scripts.map_summary"] = {
  map_summary = function() error("a snapshot never walks the charted chunks") end,
  registry_factory = function() return { scope = "registry", machine_count = 2 } end,
}
package.loaded["scripts.research"] = { progression_status = function() return { researched = { "automation" } } end }

_G.game = { tick = 18000 }
_G.prototypes = { entity = {
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
local snapshot = require("scripts.run_snapshot").capture()
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
check(snapshot.statistics.items.produced[1].name == "copper-ore" and snapshot.statistics.items.produced[2].name == "iron-ore", "nonzero counters are sorted")
check(#snapshot.statistics.raw_resources == 3, "natural resource products are derived and utility water is excluded")
check(snapshot.statistics.raw_resources[1].name == "crude-oil" and snapshot.statistics.raw_resources[2].name == "iron-ore"
  and snapshot.statistics.raw_resources[3].name == "wood", "raw resource identities are deterministic")
check(snapshot.statistics.semantics.produced == "force_surface_input_counts", "native production semantics are explicit")

-- Prototypes are walked once: a later snapshot reuses the rows.
local walked = 0
local entities = prototypes.entity
_G.prototypes = { entity = setmetatable({}, { __pairs = function() walked = walked + 1; return next, entities, nil end }) }
local again = require("scripts.run_snapshot").capture()
check(walked == 0 and #again.statistics.raw_resources == 3, "a later snapshot reuses the raw resource rows without a prototype walk")

print("ok   run snapshots retain cumulative resources and bounded diagnostic context")
print("ok   run snapshots count the Codex player's hand-crafted items from the upgrade tick")
