-- Research timing and lab demand: progression_status gives unit_time_s in
-- seconds (research_unit_energy is ticks), and factory_status research gives
-- labs {count, working, speed} from the registry's lab aggregate (kept by the
-- maintenance cursor, never a surface scan) and, for the current research,
-- packs_per_minute_needed and eta_seconds. 2.0 values: automation is 10 units
-- of 10 s, one red pack each; a normal lab researches at speed 1. Labs and
-- the force are strict 2.0.77 mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.defines = { entity_status = { working = 1, missing_science_packs = 2 }, inventory = { chest = 1, lab_input = 3 },
  target_type = { entity = 7 } }
_G.storage = {}
_G.script = { register_on_object_destroyed = function() return 1 end }
_G.prototypes = { item = {}, recipe = {}, space_location = {} }

local finds = 0
local nauvis = mock.surface({ index = 1, name = "nauvis", valid = true,
  find_entities_filtered = function() finds = finds + 1; return {} end })
local automation = { name = "automation", research_unit_energy = 600, research_unit_count = 10,
  research_unit_ingredients = { { type = "item", name = "automation-science-pack", amount = 1 } } }
local force = mock.force({ name = "player", technologies = {}, research_queue = {}, research_progress = 0.3,
  laboratory_productivity_bonus = 0, is_chunk_charted = function() return true end,
  is_space_location_unlocked = function() return false end })
_G.game = { tick = 0, forces = { player = force }, get_surface = function(index) return index == 1 and nauvis or nil end }

local body = mock.entity({ valid = true, name = "character", type = "character", position = { x = 0, y = 0 },
  surface = nauvis, surface_index = 1, force = force })
package.loaded["scripts.companion"] = { human_control = function() return false, 999 end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)

local state = require("scripts.state")
local registry = require("scripts.registry")
local research = require("scripts.research")
local factory_status = require("scripts.factory_status")
state.init()
storage.registry.ready, storage.registry.force = true, "player"

local base_reads = 0
local next_unit = 0
-- A lab (base speed 1, 1.3 at uncommon) or another lab prototype: name,
-- base speed and science_pack_drain_rate_percent, on nauvis or a surface.
local function lab(x, quality, bonus, kind, surface)
  kind = kind or { name = "lab", base = 1 }
  surface = surface or nauvis
  next_unit = next_unit + 1
  local e = mock.entity({ valid = true, name = kind.name, type = "lab", position = { x = x, y = 0 }, unit_number = next_unit,
    force = force, surface = surface, surface_index = surface.index, quality = { name = quality }, speed_bonus = bonus,
    productivity_bonus = 0,
    prototype = mock.entity_prototype({ name = kind.name, electric_energy_source_prototype = nil,
      science_pack_drain_rate_percent = kind.drain or 100,
      get_researching_speed = function(q)
        base_reads = base_reads + 1
        return q == "normal" and kind.base or kind.base * 1.3
      end }) })
  registry.add(e)
  return e
end
local function pass()
  for _ = 1, 4 do game.tick = game.tick + 1; registry.maintain(game.tick) end
end
local function read() return factory_status.factory_status({ sections = { "research" } }).research end

-- progression_status units: 600 ticks a unit is 10 s.
check(research.unit_time_s(automation) == 10 and research.unit_time_s({}) == nil,
  "unit_time_s is research_unit_energy (ticks) / 60; nil without one")

-- No labs: no labs row, the current research's unit time, no demand or eta.
force.current_research = automation
local none = read()
check(none.labs == nil and none.unit_time_s == 10 and none.packs_per_minute_needed == nil and none.eta_seconds == nil,
  "without labs: no labs row, unit_time_s 10, no packs_per_minute_needed and no eta_seconds")

-- One normal lab, no bonus: 6 red packs a minute; 7 of 10 units left take 70 s.
local first = lab(0, "normal", 0)
local one = read()
check(one.labs.count == 1 and one.labs.speed == 1 and one.unit_time_s == 10
  and one.packs_per_minute_needed["automation-science-pack"] == 6 and one.eta_seconds == 70,
  "one lab at speed 1: 6 automation packs a minute, eta 70 s for 7 of 10 units")

-- A second, uncommon lab (base 1.3) with a +100% speed bonus (force research,
-- modules, beacons): 1 + 2.6 = 3.6 speed, 21.6 packs a minute.
local second = lab(5, "uncommon", 1)
local two = read()
check(two.labs.count == 2 and math.abs(two.labs.speed - 3.6) < 1e-9
  and math.abs(two.packs_per_minute_needed["automation-science-pack"] - 21.6) < 1e-9
  and two.eta_seconds == math.ceil(70 / 3.6),
  "quality and speed_bonus count: speed 3.6, 21.6 packs a minute, eta ceil(70 / 3.6)")

-- Productivity adds free units: packs a minute stay, the eta shortens. Each
-- lab's productivity_bonus already holds the force's research bonus plus its
-- modules and beacons, so the force bonus is not applied a second time.
force.laboratory_productivity_bonus = 0.2
first.productivity_bonus, second.productivity_bonus = 0.2, 0.6
pass()
local productive = read()
check(math.abs(productive.packs_per_minute_needed["automation-science-pack"] - 21.6) < 1e-9
  and productive.eta_seconds == math.ceil(70 / (1 * 1.2 + 2.6 * 1.6)),
  "each lab's productivity leaves pack consumption alone and shortens eta_seconds")
force.laboratory_productivity_bonus = 0
first.productivity_bonus, second.productivity_bonus = 0, 0

-- A changed speed bonus is picked up by the maintenance cursor; the base
-- speed is read once per lab name and quality.
first.speed_bonus = 0.5
pass()
local bonus = read()
check(math.abs(bonus.labs.speed - 4.1) < 1e-9 and base_reads == 2,
  "the cursor refreshes speed_bonus (1.5 + 2.6) and reads each base speed once (" .. base_reads .. " reads)")

-- Working labs come from the line sampler's lab lines.
storage.autonomy = { line_order = { 1, 2 }, lines = { { product = "research", working = 1 }, { product = "iron-plate", working = 4 } } }
check(read().labs.working == 1, "working counts lab lines' progressing machines only")
storage.autonomy = nil

-- A removed lab leaves the aggregate.
registry.remove(second.unit_number)
local after = read()
check(after.labs.count == 1 and math.abs(after.labs.speed - 1.5) < 1e-9, "a removed lab leaves count and speed")

-- A biolab (base 2, drains half a pack a unit) researches twice as fast as a
-- lab on the same packs: 1.5 + 2 speed, (1.5 + 1) x 6 packs a minute.
local biolab = lab(10, "normal", 0, { name = "biolab", base = 2, drain = 50 })
local bio = read()
check(math.abs(bio.labs.speed - 3.5) < 1e-9
  and math.abs(bio.packs_per_minute_needed["automation-science-pack"] - 15) < 1e-9
  and bio.eta_seconds == 20,
  "a biolab counts its full speed for eta_seconds and half its packs: 15 a minute, eta 20 s")
registry.remove(biolab.unit_number)

-- Labs on a deleted surface leave the force-wide sums when their entries go
-- after the surface's aggregates; no negative row is left behind.
local platform = mock.surface({ index = 3, name = "platform-1", valid = true })
local aboard = lab(0, "normal", 1, nil, platform)
check(math.abs(read().labs.speed - 3.5) < 1e-9, "a lab on another surface adds to the speed")
registry.on_surface_deleted({ surface_index = 3 })
aboard.valid = false
registry.remove(aboard.unit_number)
local survived = read()
check(survived.labs.count == 1 and math.abs(survived.labs.speed - 1.5) < 1e-9
  and math.abs(survived.packs_per_minute_needed["automation-science-pack"] - 9) < 1e-9
  and storage.registry.types[3] == nil,
  "removing a deleted surface's lab keeps the remaining speed 1.5 and recreates no row")

-- No current research: labs only.
force.current_research = nil
local idle = read()
check(idle.labs.count == 1 and idle.unit_time_s == nil and idle.packs_per_minute_needed == nil and idle.eta_seconds == nil,
  "without current research only labs are shown")
check(finds == 0, "the research section queries no entity")

if failures > 0 then error(failures .. " research labs check(s) failed") end
print("research_labs_test: all checks passed")
