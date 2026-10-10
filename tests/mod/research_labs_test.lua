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
  target_type = { entity = 7 }, flow_precision_index = { five_seconds = 0, one_minute = 1 } }
_G.storage = {}
_G.script = { register_on_object_destroyed = function() return 1 end }
_G.prototypes = { item = {}, recipe = {}, space_location = {} }

local finds = 0
local found_inserters = {}
local nauvis = mock.surface({ index = 1, name = "nauvis", valid = true,
  find_entities_filtered = function() finds = finds + 1; return found_inserters end })
local automation = { name = "automation", research_unit_energy = 600, research_unit_count = 10,
  research_unit_ingredients = { { type = "item", name = "automation-science-pack", amount = 1 } } }
-- Packs made: the force's one-minute flow statistics per factory surface.
local made_rates, flow_reads = {}, {}
local force = mock.force({ name = "player", technologies = {}, research_queue = {}, research_progress = 0.3,
  laboratory_productivity_bonus = 0, is_chunk_charted = function() return true end,
  is_space_location_unlocked = function() return false end,
  get_item_production_statistics = function(surface)
    return mock.flow_statistics({ get_flow_count = function(spec)
      flow_reads[#flow_reads + 1] = { surface = surface, name = spec.name, category = spec.category,
        precision_index = spec.precision_index, count = spec.count }
      return (made_rates[surface] or {})[spec.name] or 0
    end })
  end })
local vulcanus = mock.surface({ index = 2, name = "vulcanus", valid = true })
_G.game = { tick = 0, forces = { player = force },
  get_surface = function(index) return index == 1 and nauvis or index == 2 and vulcanus or nil end }

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

-- Packs made next to packs needed: one one-minute production read per
-- needed pack and factory surface, summed (hand-crafting counts).
made_rates[1] = { ["automation-science-pack"] = 4.25 }
flow_reads = {}
local made = read()
check(made.packs_per_minute_made["automation-science-pack"] == 4.25 and #flow_reads == 1
  and flow_reads[1].surface == 1 and flow_reads[1].category == "input" and flow_reads[1].precision_index == 1
  and flow_reads[1].count == false,
  "packs_per_minute_made reads the one-minute production of each needed pack on each factory surface")

-- Labs lacking packs: the line sampler's labs whose status misses packs and
-- that have not progressed in 10 s, each one's input inventory read.
local three = { name = "military", research_unit_energy = 900, research_unit_count = 100, research_unit_ingredients = {
  { type = "item", name = "automation-science-pack", amount = 1 }, { type = "item", name = "logistic-science-pack", amount = 1 },
  { type = "item", name = "military-science-pack", amount = 1 } } }
force.current_research = three
local inventory_reads = 0
local function stocked(x, surface_index, holds, status, productive_tick)
  next_unit = next_unit + 1
  local e = mock.entity({ valid = true, name = "lab", type = "lab", position = { x = x, y = 7 }, unit_number = next_unit,
    get_inventory = function(id)
      assert(id == 3, "only a lab's input inventory is read")
      inventory_reads = inventory_reads + 1
      return mock.inventory({ get_item_count = function(name) return holds[name] or 0 end })
    end })
  return { unit = next_unit, type = "lab", name = "lab", entity = e, position = { x = x, y = 7 }, surface = surface_index,
    raw = status or "missing_science_packs", productive_tick = productive_tick }
end
local function sampled(recs)
  local machines, waiting = {}, {}
  for _, rec in ipairs(recs) do
    machines[rec.unit] = rec
    if rec.raw == "missing_science_packs" then
      waiting[rec.surface] = waiting[rec.surface] or {}
      waiting[rec.surface][rec.unit] = true
    end
  end
  storage.autonomy = { line_order = {}, lines = {}, machines = machines, waiting = { missing_science_packs = waiting } }
end
local red, green, mil = "automation-science-pack", "logistic-science-pack", "military-science-pack"
game.tick = 10000
sampled({
  stocked(0, 1, { [red] = 2, [mil] = 1 }),
  stocked(3, 1, { [red] = 2 }),
  stocked(6, 2, { [red] = 1, [mil] = 3 }),
  stocked(9, 1, {}, nil, game.tick - 300), -- progressed 5 s ago: still busy
  stocked(12, 1, { [red] = 1, [green] = 1, [mil] = 1 }), -- holds every pack
  stocked(15, 1, {}, "working"),
})
local lacking = read().labs
check(lacking.starved_by[green] == 3 and lacking.starved_by[mil] == 1 and lacking.starved_by[red] == nil
  and #lacking.starved_at[green] == 3 and lacking.starved_at[green][1].x == 0
  and lacking.starved_at[green][3].surface == "vulcanus" and lacking.starved_at[green][1].surface == nil
  and lacking.starved_at[mil][1].x == 3 and lacking.starved_unread == nil and inventory_reads == 4,
  "starved_by counts the stalled labs lacking each pack with their positions (another surface named), "
    .. "reading only stalled labs (" .. inventory_reads .. " inventories)")
local many = {}
for i = 1, 50 do many[i] = stocked(i * 3, 1, {}) end
sampled(many)
inventory_reads = 0
local crowded = read().labs
check(crowded.starved_by[red] == 48 and crowded.starved_by[mil] == 48 and crowded.starved_unread == 2
  and #crowded.starved_at[green] == 4 and #crowded.starved_at[red] == 4 and crowded.starved_at[mil] == nil
  and inventory_reads == 48,
  "at most 48 labs are read (starved_unread counts the rest); four positions a pack, eight in all")
-- A starved lab whose feeding inserter's whitelist leaves the missing pack
-- out names that inserter; a blacklist listing it does too; an inserter
-- feeding another entity, or one whose filter lets the pack in, is no cause.
do
  local filtered = stocked(30, 1, { [red] = 1, [mil] = 1 })
  filtered.entity = mock.entity({ valid = true, name = "lab", type = "lab", position = { x = 30, y = 7 },
    unit_number = filtered.unit, surface = nauvis, force = force,
    bounding_box = { left_top = { x = 28.5, y = 5.5 }, right_bottom = { x = 31.5, y = 8.5 } },
    get_inventory = function() return mock.inventory({ get_item_count = function(name) return name == green and 0 or 1 end }) end })
  local function inserter(x, target, mode, filters)
    return mock.entity({ valid = true, name = "inserter", type = "inserter", position = { x = x, y = 9.5 },
      drop_target = target, filter_slot_count = 5, use_filters = true, inserter_filter_mode = mode,
      inserter_stack_size_override = 0, inserter_spoil_priority = "none",
      get_filter = function(index) return filters[index] and { name = filters[index] } or nil end })
  end
  local other = mock.entity({ valid = true, unit_number = 9999 })
  found_inserters = { inserter(29.5, other, "whitelist", { red }), inserter(30.5, filtered.entity, "whitelist", { red, green }),
    inserter(31.5, filtered.entity, "whitelist", { red, mil }) }
  sampled({ filtered })
  local named = read().labs.starved_at[green][1]
  check(named.x == 30 and named.filtered_out_by and named.filtered_out_by.position.x == 31.5
    and named.filtered_out_by.mode == "whitelist" and named.filtered_out_by.filters[1] == red
    and named.filtered_out_by.filters[2] == mil and named.filtered_out_by.name == "inserter",
    "a starved lab names the feeding inserter whose whitelist leaves the missing pack out")
  found_inserters = { inserter(30.5, filtered.entity, "blacklist", { green }) }
  check(read().labs.starved_at[green][1].filtered_out_by.mode == "blacklist",
    "a feeding inserter whose blacklist lists the missing pack is named too")
  found_inserters = { inserter(30.5, filtered.entity, "whitelist", { green }), inserter(29.5, other, "whitelist", { red }) }
  check(read().labs.starved_at[green][1].filtered_out_by == nil,
    "no filtered_out_by while every feeding filter lets the pack in")
  found_inserters, finds = {}, 0
end
sampled({ stocked(0, 1, { [red] = 1, [green] = 1, [mil] = 1 }) })
local stocked_up = read().labs
check(stocked_up.starved_by == nil and stocked_up.starved_at == nil, "no lab lacking a pack: no starved_by or starved_at")
storage.autonomy = nil
force.current_research = automation

-- No current research: labs only.
force.current_research = nil
local idle = read()
check(idle.labs.count == 1 and idle.unit_time_s == nil and idle.packs_per_minute_needed == nil and idle.eta_seconds == nil,
  "without current research only labs are shown")
check(finds == 0, "with no lab starved the research section queries no entity")

-- Float leftovers after the last lab goes never show demand or an eta.
local real_labs = registry.labs
registry.labs = function() return { count = 0, speed = 2.2e-16, pack_rate = 2.2e-16, progress_rate = 2.2e-16 } end
force.current_research = automation
local leftover = read()
registry.labs = real_labs
check(leftover.labs == nil and leftover.packs_per_minute_needed == nil and leftover.eta_seconds == nil,
  "a float leftover with no labs shows no lab demand and no eta")

-- The research queue's time at today's labs: remaining units x unit time /
-- the labs' progress rate (one lab at 1.5), one technology after another;
-- the first counts its live progress (0.3), a later one its saved progress.
do
  local queued_three = setmetatable({ saved_progress = 0.5 }, { __index = three })
  force.current_research = automation
  force.research_queue = { automation, queued_three }
  force.recipes = {}
  local eta = research.progression_status().queue_eta_seconds
  check(eta and #eta == 2 and eta[1].name == "automation" and eta[1].seconds == math.ceil(7 * 10 / 1.5)
    and eta[1].cumulative_seconds == math.ceil(7 * 10 / 1.5)
    and eta[2].name == "military" and eta[2].seconds == 500
    and eta[2].cumulative_seconds == math.ceil(7 * 10 / 1.5 + 500),
    "queue_eta_seconds gives each queued technology's seconds and the running total at the labs' progress rate")
  registry.labs = function() return { count = 0, speed = 0, pack_rate = 0, progress_rate = 0 } end
  check(research.progression_status().queue_eta_seconds == nil, "no labs: no queue_eta_seconds")
  registry.labs = real_labs
  force.research_queue = {}
  check(research.progression_status().queue_eta_seconds == nil, "an empty queue: no queue_eta_seconds")
end

if failures > 0 then error(failures .. " research labs check(s) failed") end
print("research_labs_test: all checks passed")
