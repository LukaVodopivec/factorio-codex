-- Offline tests for the mod's own chores (scripts/chores.lua): upkeep
-- refuelling of dry burner machines by fuel category on the body's surface,
-- lab feeding that asks the lab first, and charting around the body on
-- planets.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.game = { tick = 1000 }
-- Fuels by category come from the engine's item filter, once per category.
local FUELS = { chemical = { coal = {}, wood = {} }, nutrients = { nutrients = {}, ["yumako-mash"] = {} } }
local filter_calls = {}
_G.prototypes = { item = { coal = { stack_size = 50 }, wood = { stack_size = 100 } },
  get_item_filtered = function(filters)
    filter_calls[#filter_calls + 1] = filters[1]["fuel-category"]
    assert(filters[1].filter == "fuel-category")
    return mock.custom_table(FUELS[filters[1]["fuel-category"]] or {})
  end }
_G.defines = { inventory = { lab_input = 2 } }
_G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil, last_finished_tick = 900 } }

local carried, stocked, holding = { coal = 0 }, { coal = 30 }, false
local charted, requested, charts = {}, {}, {}
local nauvis = { index = 1, name = "nauvis", planet = { name = "nauvis" } }
local body = { valid = true, position = { x = 0, y = 0 }, surface = nauvis, surface_index = 1,
  get_item_count = function(name) return carried[name] or 0 end }
body.force = {
  is_chunk_charted = function(_, chunk) return charted[chunk.x .. "," .. chunk.y] == true end,
  is_chunk_requested_for_charting = function(_, chunk) return requested[chunk.x .. "," .. chunk.y] == true end,
  chart = function(_, area) charts[#charts + 1] = area end,
}
package.loaded["scripts.companion"] = { get = function() return body end,
  human_control = function() return holding, 0 end }
-- Stock comes from the registry's holders in one pass for every fuel.
local stock_passes = {}
package.loaded["scripts.registry"] = { stock_totals = function(names)
  stock_passes[#stock_passes + 1] = table.concat(names, ",")
  local totals = {}
  for _, name in ipairs(names) do totals[name] = stocked[name] or 0 end
  return totals
end }
local queued = {}
-- tasks.upkeep_room owns when upkeep may take the body (plans_test covers it).
local room, reserved = "idle", nil
local boundary_asked
package.loaded["scripts.tasks"] = { upkeep_room = function(boundary) boundary_asked = boundary; return room, reserved end, queue_plan = function(params, selection)
  params.selection = selection; queued[#queued + 1] = params; return { plan_id = #queued } end }
-- The queued plan's first `count` steps ran to their end (tasks' upkeep
-- listener); the plan ID is its place in `queued`.
local chores_ref
local function steps_ended(plan_id, count, status)
  for index = 1, count do chores_ref.on_upkeep_step({ id = plan_id }, index, status or "completed") end
end

local chores = require("scripts.chores")
chores_ref = chores
require("scripts.state").init()
check(type(storage.chores.refueled) == "table" and type(storage.chores.fed_labs) == "table",
  "state.init creates the chores storage")
check(type(storage.thoughts.lines) == "table", "state.init creates the thoughts storage")

local CHEMICAL = { fuel_categories = { chemical = true } }
local function machine(unit, x, raw, burner, surface_index)
  return { unit = unit, raw = raw, position = { x = x, y = 0 },
    entity = { valid = true, surface_index = surface_index or 1, burner = burner or CHEMICAL } }
end
-- The line sampler keeps machines by unit and, per chore status and
-- surface, the units in it (autonomy.lua); upkeep reads only the body's
-- surface's set.
local function sampled(machines)
  local waiting = {}
  for unit, rec in pairs(machines) do
    local surface = rec.entity.surface_index
    for _, set in ipairs({ rec.raw, rec.low_fuel and "low_fuel" or nil }) do
      waiting[set] = waiting[set] or {}
      waiting[set][surface] = waiting[set][surface] or {}
      waiting[set][surface][unit] = true
    end
  end
  storage.autonomy = { machines = machines, waiting = waiting }
end
sampled({ [1] = machine(1, 20, "no_fuel"), [2] = machine(2, 5, "no_fuel"), [3] = machine(3, 8, "working") })

chores.upkeep(game.tick)
local plan = queued[1]
check(plan and plan.source == "upkeep" and #plan.steps == 2 and plan.steps[1].action == "insert_items"
  and plan.steps[1].x == 5 and plan.steps[2].x == 20 and plan.steps[1].items.coal == 10,
  "an idle body refuels dry burner machines nearest first, as an upkeep plan")
check(#stock_passes == 1 and stock_passes[1] == "coal,wood" and #filter_calls == 1 and filter_calls[1] == "chemical",
  "the fuel stock is one registry pass for the burner's fuel category, found through the item filter")

check(next(storage.chores.refueled) == nil, "selecting a machine does not start its refuel cooldown")
game.tick = 1100
steps_ended(1, 1)
check(storage.chores.refueled[2] == 1100 and storage.chores.refueled[1] == nil,
  "a refuel step that ended starts its machine's cooldown; the step not reached yet does not")
game.tick = 1300
chores.upkeep(game.tick)
check(#queued == 2 and #queued[2].steps == 1 and queued[2].steps[1].x == 20,
  "a machine a pre-empted plan never reached is chosen again at the next pass, the refuelled one is not")
steps_ended(2, 1, "failed")
game.tick = 1600
chores.upkeep(game.tick)
check(#queued == 2 and storage.chores.refueled[1] == 1300,
  "a failed refuel attempt also waits out the cooldown, so one unreachable machine never holds up the rest")
steps_ended(1, 2)
check(storage.chores.refueled[1] == 1300, "only the newest upkeep plan's steps stamp a cooldown")
queued[3] = nil

game.tick = 5000
room = nil
chores.upkeep(game.tick)
check(#queued == 2, "upkeep waits while tasks.upkeep_room gives it no room")
room = "idle"
holding = true
chores.upkeep(game.tick)
check(#queued == 2, "upkeep never starts while the owner holds the body")
holding = false
-- Beside pending work (parked waits, a running craft) the plan ends with a
-- walk back to where the body stood.
body.position = { x = 1, y = -2 }
room = "busy"
chores.upkeep(game.tick)
local busy = queued[3]
check(busy and #busy.steps == 3 and busy.steps[1].action == "insert_items" and busy.steps[2].action == "insert_items"
  and busy.steps[3].action == "walk_to" and busy.steps[3].x == 1 and busy.steps[3].y == -2
  and busy.steps[3].arrival_mode == "vicinity" and busy.steps[3].upkeep_return == true
  and storage.chores.last_selection.room == "busy",
  "beside pending work upkeep refuels, then walks back to where the body stood")
steps_ended(3, 3, "cancelled")
check(next(storage.chores.refueled) == nil, "a cancelled refuel step starts no cooldown")
queued[2], queued[3] = nil, nil
room, body.position = "idle", { x = 0, y = 0 }

stocked.coal = 3
chores.upkeep(game.tick)
check(#queued == 2 and #queued[2].steps == 2 and queued[2].steps[1].items.coal == 1 and queued[2].steps[2].items.coal == 1,
  "scarce fuel is shared among the dry machines")
stocked.coal, game.tick = 0, 9000
storage.chores.refueled = {}
chores.upkeep(game.tick)
check(#queued == 2, "with no fuel carried or stored, upkeep queues nothing")
carried.coal = 0
stocked.wood = 40
chores.upkeep(game.tick)
check(#queued == 3 and queued[3].steps[1].items.wood == 10, "another fuel is used when there is no coal")
chores.upkeep(10000)
check(#filter_calls == 1, "fuels of a category are looked up once")

-- Fuel by category: a biochamber takes nutrients, never coal; a burner
-- whose category the body has nothing of is skipped. Machines on another
-- surface are not the body's to refuel.
local NUTRIENTS = { fuel_categories = { nutrients = true } }
sampled({ [21] = machine(21, 4, "no_fuel", NUTRIENTS), [22] = machine(22, 6, "no_fuel"),
  [23] = machine(23, 1, "no_fuel", nil, 2) })
storage.chores.refueled, carried, stocked = {}, { nutrients = 25 }, { coal = 7 }
game.tick = 15000
chores.upkeep(game.tick)
local mixed = queued[#queued]
check(#mixed.steps == 2 and mixed.steps[1].x == 4 and mixed.steps[1].items.nutrients == 10 and mixed.steps[1].items.coal == nil
  and mixed.steps[2].x == 6 and mixed.steps[2].items.coal == 7 and storage.chores.refueled[23] == nil,
  "each burner gets a fuel of its own category, nearest first; another surface's machine is left alone")
carried, stocked = { coal = 0 }, {}
sampled({ [24] = machine(24, 3, "no_fuel", NUTRIENTS) })
storage.chores.refueled = {}
local count_before = #queued
chores.upkeep(16000)
check(#queued == count_before, "with no fuel of the burner's category nothing is queued")

-- A working burner on its last fuel item is refuelled before it runs dry,
-- after the dry ones; at most 8 machines a pass, the low ones left out first.
local function low(unit, x)
  local rec = machine(unit, x, "working")
  rec.low_fuel = true
  return rec
end
local mix = { [31] = low(31, 2), [32] = machine(32, 9, "no_fuel"), [33] = machine(33, 4, "working") }
sampled(mix)
storage.chores.refueled, carried, stocked = {}, { coal = 0 }, { coal = 100 }
game.tick, count_before = 17000, #queued
chores.upkeep(game.tick)
local topped = queued[#queued]
check(#queued == count_before + 1 and #topped.steps == 2 and topped.steps[1].x == 2 and topped.steps[1].items.coal == 10
  and topped.steps[2].x == 9, "a working burner low on fuel is refuelled with the dry ones, nearest first")
check(storage.chores.last_selection.refuel.candidates[2].low_fuel == true,
  "the selection readback names the low-fuel candidate")
for unit = 41, 50 do mix[unit] = (unit <= 46) and machine(unit, unit, "no_fuel") or low(unit, unit - 40) end
sampled(mix)
storage.chores.refueled = {}
chores.upkeep(17100)
local capped_mix, lows = queued[#queued], 0
for _, step in ipairs(capped_mix.steps) do if step.x < 10 and step.x ~= 9 then lows = lows + 1 end end
check(#capped_mix.steps == 8 and lows == 1,
  "with more than 8 to serve, the 7 dry machines come first and one low one fills the last place")

-- A burner still burning keeps its fuel: its single fuel slot holds wood and
-- takes no coal, so it gets more wood, or nothing when there is none.
local function holding_slot(name)
  return { fuel_categories = { chemical = true }, inventory = {
    can_insert = function(item) return item.name == name end,
    get_contents = function() return { { name = name, count = 1, quality = "normal" } } end } }
end
local wooded = machine(51, 3, "working", holding_slot("wood"))
wooded.low_fuel = true
sampled({ [51] = wooded, [52] = machine(52, 7, "no_fuel") })
storage.chores.refueled, carried, stocked = {}, { coal = 0 }, { coal = 100, wood = 20 }
game.tick, count_before = 17200, #queued
chores.upkeep(game.tick)
local kept = queued[#queued]
check(#queued == count_before + 1 and #kept.steps == 2 and kept.steps[1].x == 3 and kept.steps[1].items.wood == 10
  and kept.steps[1].items.coal == nil and kept.steps[2].x == 7 and kept.steps[2].items.coal == 10,
  "a low burner whose slot holds wood gets wood, not the coal a dry one gets")
stocked.wood, storage.chores.refueled = 0, {}
chores.upkeep(17300)
local without = queued[#queued]
local wooded_row
for _, row in ipairs(storage.chores.last_selection.refuel.candidates) do if row.unit == 51 then wooded_row = row end end
check(#without.steps == 1 and without.steps[1].x == 7 and wooded_row.decision == "no_fuel_selected",
  "with none of its slot's fuel at hand the low burner is skipped and the dry one is still refuelled")
-- Beside a lending craft, what it makes or uses is never moved: with coal
-- reserved the dry burner gets wood.
room, reserved, stocked, storage.chores.refueled = "busy", { coal = true }, { coal = 100, wood = 20 }, {}
sampled({ [52] = machine(52, 7, "no_fuel") })
chores.upkeep(17400)
check(queued[#queued].steps[1].items.wood == 10 and queued[#queued].steps[1].items.coal == nil,
  "upkeep beside a lending craft never takes an item that craft makes or uses as fuel")
-- Beside a parked wait counting coal, upkeep refuels only from the coal the
-- body carries, never from a holder the wait may read.
room, reserved, carried, stocked, storage.chores.refueled = "busy", { coal = "carried" }, { coal = 6 }, { coal = 100 }, {}
sampled({ [53] = machine(53, 7, "no_fuel") })
chores.upkeep(17500)
check(queued[#queued].steps[1].items.coal == 6,
  "beside a parked coal wait the dry burner gets the carried coal, none from stock")
carried, storage.chores.refueled = { coal = 0 }, {}
local before_wait = #queued
chores.upkeep(17600)
check(#queued == before_wait or queued[#queued].steps[1].items.coal == nil,
  "with no coal carried, a parked coal wait's stock is left alone")
room, reserved = "idle", nil

-- Labs missing the current research's packs get the packs each lab takes
-- (its inputs, room in its input inventory) from carried or stored packs, in
-- the same upkeep plan as refuelling. A lab that would take nothing is
-- skipped, and a lab and pack tried are not tried again for 600 ticks.
local lab_inputs = { "automation-science-pack", "logistic-science-pack" }
local function lab(unit, x, raw, room)
  local inventory = {
    can_insert = function(item) return (room[item.name] or 0) > 0 end,
    get_insertable_count = function(item) assert(item.quality == "normal"); return room[item.name] or 0 end,
  }
  return { unit = unit, type = "lab", raw = raw, position = { x = x, y = 4 }, entity = { valid = true, surface_index = 1,
    prototype = { lab_inputs = lab_inputs },
    get_inventory = function(id) assert(id == defines.inventory.lab_input); return inventory end } }
end
sampled({ [7] = lab(7, 3, "missing_science_packs", { ["automation-science-pack"] = 200, ["logistic-science-pack"] = 3 }),
  [8] = lab(8, 9, "missing_science_packs", { ["automation-science-pack"] = 200 }),
  [11] = lab(11, 5, "missing_science_packs", {}),
  [9] = lab(9, 6, "working", { ["automation-science-pack"] = 200 }), [10] = machine(10, 2, "no_fuel") })
storage.chores.refueled = {}
carried = { coal = 0 }
stocked = { coal = 20, ["automation-science-pack"] = 30, ["logistic-science-pack"] = 5 }
prototypes.item["automation-science-pack"], prototypes.item["logistic-science-pack"] = { stack_size = 200 }, { stack_size = 200 }
body.force.current_research = { name = "logistics", research_unit_ingredients = {
  { type = "item", name = "automation-science-pack", amount = 1 }, { type = "item", name = "logistic-science-pack", amount = 1 } } }
game.tick = 12000
local before = #queued
chores.upkeep(game.tick)
local fed = queued[#queued]
steps_ended(#queued, 1)
check(#queued == before + 1 and #fed.steps == 3 and fed.steps[1].x == 2 and fed.steps[1].items.coal == 10
  and fed.steps[2].x == 3 and fed.steps[2].items["automation-science-pack"] == 10 and fed.steps[2].items["logistic-science-pack"] == 3
  and fed.steps[3].x == 9 and fed.steps[3].items["automation-science-pack"] == 10 and fed.steps[3].items["logistic-science-pack"] == nil,
  "upkeep brings each starved lab only the packs it takes, as much as it has room for, nearest first, after refuelling")
check(storage.chores.fed_labs["11:automation-science-pack"] == nil and storage.chores.fed_labs["7:logistic-science-pack"] == 12000,
  "a lab that would take nothing is skipped, not marked as tried")
game.tick = 12300
chores.upkeep(game.tick)
check(#queued == before + 1, "the same lab and pack are not tried again within 600 ticks")
storage.tasks.last_finished_tick = 12300
game.tick = 12600
chores.upkeep(game.tick)
check(#queued == before + 2 and #queued[#queued].steps == 2 and queued[#queued].steps[1].x == 3,
  "after 600 ticks the labs that still miss packs are tried again")
room, reserved, storage.chores.fed_labs = "busy", { ["automation-science-pack"] = true }, {}
chores.upkeep(13300)
local beside_craft = queued[#queued]
check(#queued == before + 3 and beside_craft.steps[1].x == 3 and beside_craft.steps[1].items["logistic-science-pack"] == 3
  and beside_craft.steps[1].items["automation-science-pack"] == nil and storage.chores.fed_labs["7:automation-science-pack"] == nil,
  "beside a craft making automation packs, labs get only the other packs")
room, reserved = "idle", nil
body.force.current_research = nil


before = #queued
chores.upkeep(game.tick)
check(#queued == before, "with no research active no lab is fed")

-- Bounded: 2,000 sampled machines, 300 of them dry. One pass reads at most
-- 64 machine records (the dry ones it looks at) and never walks the rest.
body.force.current_research = nil
local many, reads = {}, 0
for unit = 1, 2000 do many[unit] = machine(unit, unit, unit <= 300 and "no_fuel" or "working") end
sampled(many)
storage.autonomy.machines = setmetatable({}, { __index = function(_, unit) reads = reads + 1; return many[unit] end })
storage.chores.refueled, stocked = {}, { coal = 1000 }
game.tick, before = 30000, #queued
chores.upkeep(game.tick)
check(#queued == before + 1 and #queued[#queued].steps == 8 and reads <= 64,
  "an upkeep pass over 300 dry machines among 2,000 reads at most 64 of them (" .. reads .. " reads)")

-- Dry burners elsewhere never use up the candidate cap: 100 on another
-- surface and one on the body's.
local elsewhere = {}
for unit = 1, 100 do elsewhere[unit] = machine(unit, unit, "no_fuel", nil, 2) end
elsewhere[500] = machine(500, 7, "no_fuel")
sampled(elsewhere)
storage.chores.refueled, stocked = {}, { coal = 50 }
game.tick, before = 31000, #queued
chores.upkeep(game.tick)
check(#queued == before + 1 and #queued[#queued].steps == 1 and queued[#queued].steps[1].x == 7,
  "100 dry burners on another surface leave the cap to the one on the body's surface")

-- Fuel order: coal first, even when the factory holds more solid fuel or
-- rocket fuel (a fresh module: fuels are cached per category).
FUELS.chemical = { coal = {}, wood = {}, ["solid-fuel"] = {}, ["rocket-fuel"] = {}, ["nuclear-fuel"] = {} }
package.loaded["scripts.chores"] = nil
chores = require("scripts.chores")
sampled({ [600] = machine(600, 3, "no_fuel") })
storage.chores.refueled, carried = {}, { coal = 20 }
stocked = { ["solid-fuel"] = 60, ["rocket-fuel"] = 90, wood = 120 }
game.tick, before = 32000, #queued
chores.upkeep(game.tick)
check(#queued == before + 1 and queued[#queued].steps[1].items.coal == 10,
  "a dry burner gets coal before solid fuel, rocket fuel or wood the factory holds more of")
carried = { coal = 0 }
storage.chores.refueled = {}
chores.upkeep(33000)
check(queued[#queued].steps[1].items.wood == 10, "without coal, wood comes before solid fuel and rocket fuel")
stocked, storage.chores.refueled = { ["rocket-fuel"] = 30 }, {}
chores.upkeep(34000)
check(queued[#queued].steps[1].items["rocket-fuel"] == 10, "rocket fuel is used only when no coal, wood or solid fuel is at hand")

-- Scarce packs go to the nearest labs: 8 labs need automation packs and
-- 5 are at hand, so the 5 nearest get one each.
body.force.current_research = { name = "automation", research_unit_ingredients = {
  { type = "item", name = "automation-science-pack", amount = 1 } } }
local eight = {}
for unit = 701, 708 do eight[unit] = lab(unit, unit - 700, "missing_science_packs", { ["automation-science-pack"] = 200 }) end
sampled(eight)
storage.chores.fed_labs, carried, stocked = {}, { coal = 0 }, { ["automation-science-pack"] = 5 }
game.tick, before = 35000, #queued
chores.upkeep(game.tick)
local scarce = queued[#queued]
check(#queued == before + 1 and #scarce.steps == 5 and scarce.steps[1].x == 1 and scarce.steps[5].x == 5
  and scarce.steps[5].items["automation-science-pack"] == 1 and storage.chores.fed_labs["706:automation-science-pack"] == nil,
  "5 packs for 8 labs feed the 5 nearest one each; the others are not marked as tried")

-- Labs tried lately are left out before the nearest are taken: of 16
-- labs, the 8 nearest were tried; the next 8 get their turn.
local sixteen = {}
for unit = 801, 816 do sixteen[unit] = lab(unit, unit - 800, "missing_science_packs", { ["automation-science-pack"] = 200 }) end
sampled(sixteen)
storage.chores.fed_labs, stocked = {}, { ["automation-science-pack"] = 200 }
for unit = 801, 808 do storage.chores.fed_labs[unit .. ":automation-science-pack"] = 35000 end
game.tick, before = 35200, #queued
chores.upkeep(game.tick)
local turn = queued[#queued]
check(#queued == before + 1 and #turn.steps == 8 and turn.steps[1].x == 9 and turn.steps[8].x == 16,
  "labs tried within the retry time are skipped before the nearest 8 are taken")
body.force.current_research = nil

-- Selection is queue-time evidence, including a skipped cooldown target;
-- observing it must not claim that a queued transfer already happened.
sampled({ [901] = machine(901, 1, "no_fuel"), [902] = machine(902, 2, "no_fuel") })
storage.chores.refueled, stocked = { [901] = 36000 }, { coal = 30 }
game.tick, before = 36100, #queued
chores.upkeep(game.tick)
local evidence = storage.chores.last_selection
local skipped
for _, row in ipairs(evidence.refuel.candidates) do if row.unit == 901 then skipped = row end end
check(evidence.plan_id == #queued and queued[#queued].selection == evidence and evidence.tick == 36100
  and evidence.queue_status == "queued" and evidence.surface_index == 1,
  "upkeep retains the same exact queue-time selection on its plan and last-pass readback")
check(skipped.decision == "cooldown" and skipped.last_attempt_tick == 36000 and skipped.retry_tick == 39600
  and evidence.refuel.selected[1].unit == 902 and evidence.refuel.selected[1].count == 10
  and evidence.refuel.selected[1].available_snapshot == 30,
  "cooldown attempt timing and selected indexed fuel are evidence, not successful refuelling")
sampled({ [903] = machine(903, 3, "no_fuel") })
storage.chores.refueled, carried, stocked = {}, {}, {}
chores.upkeep(36200)
check(storage.chores.last_selection.queue_status == "no_steps"
  and storage.chores.last_selection.refuel.candidates[1].decision == "no_fuel_selected"
  and #queued == before + 1, "a no-fuel-selection pass remains visible without fabricating a plan")
sampled(many)
storage.chores.refueled, stocked = {}, { coal = 1000 }
chores.upkeep(36300)
check(#storage.chores.last_selection.refuel.candidates == 64
  and #storage.chores.last_selection.refuel.selected == 8
  and storage.chores.last_selection.refuel.scan_complete == false,
  "selection readback explicitly caps candidates and does not claim a complete whole-factory scan")
sampled(many)
storage.chores.refueled = {}
for unit=1,300 do storage.chores.refueled[unit]=36300 end
chores.upkeep(36400)
local capped=storage.chores.last_selection.refuel
check(capped.observed_candidates==64 and #capped.candidates==64 and capped.candidates_capped
  and #capped.selected==0 and capped.scan_complete,
  "new audit bookkeeping stops at64 cooldown observations while the existing selector finishes its traversal")
game.tick = 13300
storage.chores.fed_labs = {}
sampled({ [7] = lab(7, 3, "missing_science_packs", { ["automation-science-pack"] = 200 }) })

local ok = pcall(chores.on_nth[300], { tick = 9300 })
check(ok and chores.on_nth[3600] ~= nil, "chores run on their periods")
body.get_item_count = function() error("native read failed") end
check(pcall(chores.on_nth[300], { tick = 20000 }), "a failing chore never raises into the game")

-- Charting: only chunks not charted or requested yet, around the body.
charted["0,0"], requested["1,0"] = true, true
body.position = { x = 10, y = 10 }
chores.chart(game.tick)
check(#charts == 11 * 11 - 2, "charting requests every uncharted chunk within five chunks of the body")
local first = charts[1]
check(first[1][1] == -5 * 32 and first[1][2] == -5 * 32 and first[2][1] == -5 * 32 + 31,
  "each request is one chunk's area")
charts = {}
body.surface = { index = 7, name = "platform-1", platform = { index = 1 } }
chores.chart(game.tick)
check(#charts == 0, "a platform surface is never charted around")
body.surface = nauvis
chores.on_arrival({ state = "on_surface" })
check(#charts == 11 * 11 - 2, "arriving on a planet charts around the body once")
charts = {}
chores.on_arrival({ state = "aboard_platform" })
check(#charts == 0, "arriving aboard a platform charts nothing")

-- A far outpost is not upkeep's: only machines within 96 tiles of the body.
sampled({ [4] = machine(4, 200, "no_fuel"), [5] = machine(5, 90, "no_fuel") })
room, reserved, carried, stocked, storage.chores.refueled = "idle", nil, { coal = 50 }, {}, {}
body.get_item_count = function(name) return carried[name] or 0 end
local far_count = #queued
game.tick = game.tick + 100000
chores.upkeep(game.tick)
local far_row
for _, row in ipairs(storage.chores.last_selection.refuel.candidates) do if row.unit == 4 then far_row = row end end
check(#queued == far_count + 1 and #queued[#queued].steps == 1 and queued[#queued].steps[1].x == 90
  and far_row and far_row.decision == "too_far",
  "upkeep never walks to a machine more than 96 tiles from the body; the readback says it was too far")
local outpost = {}
for unit = 100, 199 do outpost[unit] = machine(unit, 500 + unit, "no_fuel") end
outpost[500] = machine(500, 12, "no_fuel")
sampled(outpost)
storage.chores.refueled = {}
game.tick = game.tick + 100000
chores.upkeep(game.tick)
check(queued[#queued].steps[1].x == 12, "a hundred dry machines far away never hide the dry one beside the body")

-- While idle, upkeep also serves machines within 96 tiles of the work sites
-- where recent pilot or package plans began (tasks' work_sites, on the
-- body's surface): an idle body at a far site never leaves the base dry,
-- even after several plans began there. Beside pending work only the body's
-- own 96 tiles count.
sampled({ [6] = machine(6, 120, "no_fuel") })
storage.chores.refueled = {}
storage.tasks.work_sites = { { surface_index = 1, x = 400, y = 0 }, { surface_index = 1, x = 110, y = 0 } }
game.tick = game.tick + 100000
local anchor_count = #queued
room = "busy"
chores.upkeep(game.tick)
check(#queued == anchor_count and storage.chores.last_selection.refuel.candidates[1].decision == "too_far",
  "beside pending work a machine 120 tiles away stays too far, wherever plans began")
room = "idle"
chores.upkeep(game.tick)
check(#queued == anchor_count + 1 and queued[#queued].steps[1].x == 120 and #queued[#queued].steps == 1
  and #storage.chores.last_selection.sites == 2 and storage.chores.last_selection.sites[2].x == 110,
  "an idle body serves a dry machine 120 tiles away near an older work site after later plans began far off")
storage.tasks.work_sites[2].surface_index = 2
storage.chores.refueled = {}
chores.upkeep(game.tick)
check(#queued == anchor_count + 1 and #storage.chores.last_selection.sites == 1,
  "a work site on another surface widens nothing")
storage.tasks.work_sites = nil

-- The plan-boundary pass (tasks' dispatcher calls it just before a queued
-- pilot or package plan starts): a machine near the body dry for a minute
-- gets one ordinary pass, with the walk back, whatever is queued.
local function dry(unit, x, since)
  local rec = machine(unit, x, "no_fuel")
  rec.problem, rec.problem_since = "no_fuel", since
  return rec
end
game.tick = game.tick + 100000
sampled({ [7] = dry(7, 50, game.tick - 1800) })
storage.chores.refueled, storage.chores.step_tick, storage.chores.boundary_tick = {}, nil, nil
room, body.position = "boundary", { x = 0, y = 0 }
local boundary_count = #queued
check(chores.boundary_upkeep(game.tick) == nil and #queued == boundary_count and storage.chores.boundary_tick == nil,
  "a machine dry for only 30 s calls no boundary pass")
sampled({ [7] = dry(7, 50, game.tick - 3600) })
local boundary_id = chores.boundary_upkeep(game.tick)
local edge = queued[#queued]
check(boundary_id == #queued and #queued == boundary_count + 1 and boundary_asked == true
  and #edge.steps == 2 and edge.steps[1].x == 50 and edge.steps[2].upkeep_return == true
  and edge.steps[2].x == 0 and edge.selection.room == "boundary",
  "a machine dry for a minute calls one boundary pass: refuel, then the walk back")
sampled({ [8] = dry(8, 40, game.tick - 3600) })
game.tick = game.tick + 600
check(chores.boundary_upkeep(game.tick) == nil and #queued == boundary_count + 1,
  "the boundary pass looks at most once in two minutes")
storage.chores.boundary_tick = nil
steps_ended(boundary_id, 1)
game.tick = game.tick + 600
check(chores.boundary_upkeep(game.tick) == nil and #queued == boundary_count + 1,
  "nor within two minutes after an upkeep step ended")
game.tick = game.tick + 7200
check(chores.boundary_upkeep(game.tick) ~= nil and queued[#queued].steps[1].x == 40,
  "after two minutes the next long-dry machine gets its boundary pass")
sampled({ [9] = dry(9, 120, game.tick - 3600) })
storage.chores.boundary_tick = nil
game.tick = game.tick + 7200
check(chores.boundary_upkeep(game.tick) == nil, "a long-dry machine beyond 96 tiles of the body calls no boundary pass")
os.exit(failures == 0 and 0 or 1)
