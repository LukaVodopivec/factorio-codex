-- Bot-set watches (watches.lua): set_watch and clear_watch per role, the
-- three conditions evaluated on the line sampler's evaluate tick from kept
-- rates, firing once, hysteresis re-arm, the per-role cap, and event_state
-- handing a role its firings. Force statistics and machines are strict
-- Factorio API mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local function raises(fn, pattern)
  local ok, err = pcall(fn)
  return not ok and tostring(err):match(pattern) ~= nil
end

local RAW = { working = 1, no_ingredients = 3 }
_G.defines = { entity_status = RAW, inventory = { crafter_input = 2 }, flow_precision_index = { one_minute = 1 },
  direction = { north = 0, east = 4, south = 8, west = 12 } }
local PLATE = { name = "iron-plate", ingredients = { { name = "iron-ore", type = "item", amount = 1 } },
  products = { { name = "iron-plate", type = "item", amount = 1 } } }
_G.prototypes = { recipe = { ["iron-plate"] = PLATE }, item = { ["iron-plate"] = {}, ["iron-gear-wheel"] = {} },
  fluid = { water = {} } }
_G.game = { tick = 0 }
_G.storage = {}
_G.script = { register_on_object_destroyed = function() return 1 end }

-- Per minute, by category and name: what the mocked statistics report.
local rates = { input = {}, output = {} }
local flow_reads, stats_reads = 0, 0
local function statistics(kind)
  return mock.flow_statistics({ get_flow_count = function(args)
    flow_reads = flow_reads + 1
    assert(args.precision_index == defines.flow_precision_index.one_minute and args.count == false)
    return rates[args.category][kind .. ":" .. args.name] or 0
  end })
end
local surface
local force = mock.force({ name = "player", is_chunk_charted = function() return true end,
  get_item_production_statistics = function(s) stats_reads = stats_reads + 1; assert(s == surface); return statistics("item") end,
  get_fluid_production_statistics = function(s) stats_reads = stats_reads + 1; assert(s == surface); return statistics("fluid") end })
surface = mock.surface({ index = 1, name = "nauvis", valid = true, find_entities_filtered = function() return {} end })
game.forces = { player = force }
game.get_surface = function(index) return (index == 1 or index == "nauvis") and surface or nil end
local body = { valid = true, position = { x = 0, y = 0 }, force = force, surface = surface }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end,
  human_control = function() return false, 999 end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)

local state = require("scripts.state")
local registry = require("scripts.registry")
local autonomy = require("scripts.autonomy")
local watches = require("scripts.watches")
state.init()
check(storage.watches and storage.watches.next_id == 1 and #storage.watches.list == 0,
  "state.init declares an empty watch store")
storage.registry.ready = true

local next_unit = 100
local furnaces = {}
local function furnace(x, y)
  next_unit = next_unit + 1
  local entity = mock.entity({ valid = true, name = "stone-furnace", type = "furnace", position = { x = x, y = y },
    unit_number = next_unit, force = force, surface = surface, status = RAW.working, products_finished = 0,
    get_recipe = function() return PLATE end })
  mock.state(entity).products_finished = 0
  mock.read(entity, "products_finished", function() return mock.state(entity).products_finished end)
  registry.add(entity)
  furnaces[#furnaces + 1] = entity
  return entity
end
furnace(10, 10); furnace(10, 12)

-- Each furnace finishes a plate every `period` ticks (0: none).
local period = 60
local function run(ticks)
  for _ = 1, ticks do
    game.tick = game.tick + 1
    if period > 0 and game.tick % period == 0 then
      for _, f in ipairs(furnaces) do mock.state(f).products_finished = mock.state(f).products_finished + 1 end
    end
    autonomy.on_tick(game.tick)
    watches.on_tick(game.tick)
  end
end
game.tick = 1
autonomy.on_tick(1)
run(3700)
local line = autonomy.lines()[1]
check(line and line.rate_per_min > 100, "the furnaces form one running line (" .. tostring(line and line.rate_per_min) .. "/min)")
-- A steady line reads its true rate (two furnaces, a plate a second each)
-- at every phase of a rate bin, with no sawtooth for a watch to cross.
local low, high = math.huge, 0
for _ = 1, 20 do
  run(60)
  local rate = autonomy.lines()[1].rate_per_min
  low, high = math.min(low, rate), math.max(high, rate)
end
check(low >= 114 and high <= 126, "a steady line's rate holds across rate bins (" .. low .. " to " .. high .. "/min)")

-- Validation.
check(raises(function() watches.set({ condition = { kind = "rate_below", item = "iron-plate", per_min = 1 } }) end, "^WATCH_ROLE"),
  "a watch needs the session's role")
check(raises(function() watches.set({ role = "pilot", condition = { kind = "below", item = "iron-plate", per_min = 1 } }) end, "^WATCH_CONDITION"),
  "an unknown condition kind is refused")
check(raises(function() watches.set({ role = "pilot", condition = { kind = "rate_below", item = "iron-plate" } }) end, "^WATCH_CONDITION"),
  "rate_below needs per_min")
check(raises(function() watches.set({ role = "pilot", condition = { kind = "rate_below", item = "unobtainium", per_min = 5 } }) end, "^WATCH_UNKNOWN_ITEM"),
  "an unknown item is refused")
check(raises(function() watches.set({ role = "pilot", condition = { kind = "line_below", line = { x = 99, y = 99 }, per_min = 5 } }) end, "^WATCH_NO_LINE"),
  "a line position with no line is refused")

-- rate_below: set while the rate is safe, it is armed at once.
rates.input["item:iron-plate"] = 120
local set = watches.set({ role = "pilot", condition = { kind = "rate_below", item = "iron-plate", per_min = 60 } })
check(set.watch.id == 1 and set.watch.armed == true and set.watch.value == 120 and set.watch.surface == "nauvis"
  and #set.watches == 1 and set.limit == 16, "a rate watch reads its value once and arms while it is on the safe side")
-- Setting the same condition again replaces the threshold and keeps the id.
local again = watches.set({ role = "pilot", condition = { kind = "rate_below", item = "iron-plate", per_min = 90 } })
check(again.watch.id == 1 and again.replaced == true and #again.watches == 1 and again.watch.condition.per_min == 90,
  "the same kind on the same item and surface replaces the threshold and keeps its id")
-- A watch set while already past its threshold stays quiet until it is not.
rates.input["item:iron-gear-wheel"] = 0
local gears = watches.set({ role = "pilot", condition = { kind = "rate_below", item = "iron-gear-wheel", per_min = 10 } })
check(gears.watch.armed == false, "a watch already past its threshold does not arm")
local before = game.tick
run(60)
check(storage.watches.fired_tick.pilot == nil, "an unarmed watch never fires")
rates.input["item:iron-gear-wheel"] = 12
run(30)
check(storage.watches.list[2].armed == true, "it arms once the value is on the safe side")

-- The plate rate drops: fires once.
rates.input["item:iron-plate"] = 40
flow_reads, stats_reads = 0, 0
run(30)
local fired = watches.fired_since("pilot", before)
check(fired and #fired == 1 and fired[1].id == 1 and fired[1].value == 40 and fired[1].condition.kind == "rate_below"
  and fired[1].condition.item == "iron-plate" and fired[1].condition.per_min == 90 and fired[1].surface == "nauvis"
  and fired[1].tick == storage.watches.fired_tick.pilot, "crossing fires once with id, condition, value and tick")
check(flow_reads <= 2 and stats_reads <= 1, "an evaluate reads each watched flow once from one statistics object per surface ("
  .. flow_reads .. " flows, " .. stats_reads .. " statistics)")
run(600)
check(#watches.fired_since("pilot", before) == 1, "a fired watch stays quiet while the value stays below")
check(watches.fired_since("strategist", before) == nil and watches.fired_since("pilot", game.tick) == nil,
  "firings are per role and after the tick asked")
-- Hysteresis: back just above the threshold does not re-arm; 10% above for 60 s does.
rates.input["item:iron-plate"] = 95
run(3700)
check(storage.watches.list[1].armed == false, "back above the threshold but within 10% does not re-arm")
rates.input["item:iron-plate"] = 100
run(1800)
check(storage.watches.list[1].armed == false, "10% above for less than 60 s does not re-arm yet")
rates.input["item:iron-plate"] = 50
run(30)
rates.input["item:iron-plate"] = 100
run(3540)
check(storage.watches.list[1].armed == false and #watches.fired_since("pilot", before) == 1,
  "a dip below the re-arm level restarts the 60 s")
run(90)
check(storage.watches.list[1].armed == true, "10% above the threshold for 60 s re-arms the watch")
rates.input["item:iron-plate"] = 10
run(30)
check(#watches.fired_since("pilot", before) == 2, "a re-armed watch fires again")

-- consumption_above_production, on a fluid.
rates.input["fluid:water"], rates.output["fluid:water"] = 1200, 600
local water = watches.set({ role = "strategist", condition = { kind = "consumption_above_production", item = "water" } })
check(water.watch.armed == true and water.watch.value == 600 and water.watch.produced_per_min == 1200
  and #water.watches == 1, "consumption_above_production reads consumed (value) and produced; the strategist keeps its own list")
local strategist_since = game.tick
rates.output["fluid:water"] = 1300
run(30)
local wet = watches.fired_since("strategist", strategist_since)
check(wet and #wet == 1 and wet[1].value == 1300 and wet[1].produced_per_min == 1200,
  "consuming more than is made fires with both rates")

-- line_below by the line's position and by a member machine's position.
local by_position = watches.set({ role = "pilot", condition = { kind = "line_below", line = line.position, per_min = 60 } })
check(by_position.watch.condition.line == line.id and by_position.watch.armed == true and by_position.watch.value > 60,
  "a line watch finds the line by its factory_status position")
local by_machine = watches.set({ role = "pilot", condition = { kind = "line_below", line = { x = 10, y = 12 }, per_min = 30 } })
check(by_machine.replaced == true and by_machine.watch.id == by_position.watch.id,
  "a member machine's position names the same line")
local line_since = game.tick
period = 0
run(3700)
local stalled
for _, row in ipairs(watches.fired_since("pilot", line_since) or {}) do
  if row.condition.kind == "line_below" then stalled = row end
end
check(stalled and stalled.condition.line == line.id and stalled.value < 30, "a stalled line fires its watch")

-- The cap: 16 per role; clear by id and all.
local w = storage.watches
for i = #watches.clear({ role = "pilot", all = true }).watches, 15 do
  prototypes.item["item-" .. i] = {}
  watches.set({ role = "pilot", condition = { kind = "rate_below", item = "item-" .. i, per_min = 1 } })
end
check(#watches.clear({ role = "strategist", id = water.watch.id }).watches == 0, "clear_watch removes one watch by id")
local count = 0
for _, watch in ipairs(w.list) do if watch.role == "pilot" then count = count + 1 end end
check(count == 16, "a role keeps up to 16 watches")
prototypes.item["item-extra"] = {}
check(raises(function() watches.set({ role = "pilot", condition = { kind = "rate_below", item = "item-extra", per_min = 1 } }) end, "^WATCH_LIMIT"),
  "a seventeenth watch is refused")
check(#watches.set({ role = "strategist", condition = { kind = "rate_below", item = "item-extra", per_min = 1 } }).watches == 1,
  "another role has its own 16")
check(raises(function() watches.clear({ role = "strategist", id = w.list[1].id }) end, "^WATCH_UNKNOWN"),
  "a role cannot clear another role's watch")
-- At most 16 watches are evaluated a sample.
flow_reads = 0
run(30)
check(flow_reads == 16, "one evaluate reads at most 16 watches (" .. flow_reads .. ")")

-- event_state hands a role its firings after watch_since.
local factory_status = require("scripts.factory_status")
storage.tasks.queue = storage.tasks.queue or {}
local probe = factory_status.event_state({ role = "pilot", watch_since = before })
check(probe.watch_fired and #probe.watch_fired >= 2 and probe.watch_fired[1].id == 1,
  "event_state carries the role's firings after watch_since")
check(factory_status.event_state().watch_fired == nil and factory_status.event_state({ role = "pilot", watch_since = game.tick }).watch_fired == nil,
  "event_state carries no firings without a role or when none are newer")

-- A save from before watches gains the store; an existing store is kept.
local kept = storage.watches
state.init()
check(storage.watches.next_id == kept.next_id and #storage.watches.list == #kept.list, "state.init keeps the watch store")
storage.watches = nil
state.init()
check(storage.watches and #storage.watches.list == 0, "an older save gains an empty watch store")

check(#mock.violations == 0, "no Factorio API member outside 2.0.77 was used")
if failures > 0 then error(failures .. " watches test(s) failed") end
