-- Offline tests for the mod's own chores (scripts/chores.lua): upkeep
-- refuelling of dry burner machines and charting around the body.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.game = { tick = 1000 }
_G.prototypes = { item = { coal = { stack_size = 50 }, wood = { stack_size = 100 } } }
_G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil, last_finished_tick = 900 } }

local carried, stocked, holding = { coal = 0 }, { coal = 30 }, false
local charted, requested, charts = {}, {}, {}
local body = { valid = true, position = { x = 0, y = 0 }, surface = {},
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
package.loaded["scripts.tasks"] = { queue_plan = function(params) queued[#queued + 1] = params; return { plan_id = #queued } end }

local chores = require("scripts.chores")
require("scripts.state").init()
check(type(storage.chores.refueled) == "table" and type(storage.chores.fed_labs) == "table",
  "state.init creates the chores storage")
check(type(storage.thoughts.lines) == "table", "state.init creates the thoughts storage")

local function machine(unit, x, raw)
  return { unit = unit, raw = raw, position = { x = x, y = 0 }, entity = { valid = true } }
end
-- The line sampler keeps machines by unit and, per chore status, the units
-- in it (autonomy.lua); upkeep reads only those sets.
local function sampled(machines)
  local waiting = {}
  for unit, rec in pairs(machines) do
    waiting[rec.raw] = waiting[rec.raw] or {}
    waiting[rec.raw][unit] = true
  end
  storage.autonomy = { machines = machines, waiting = waiting }
end
sampled({ [1] = machine(1, 20, "no_fuel"), [2] = machine(2, 5, "no_fuel"), [3] = machine(3, 8, "working") })

chores.upkeep(game.tick)
local plan = queued[1]
check(plan and plan.source == "upkeep" and #plan.steps == 2 and plan.steps[1].action == "insert_items"
  and plan.steps[1].x == 5 and plan.steps[2].x == 20 and plan.steps[1].items.coal == 10,
  "an idle body refuels dry burner machines nearest first, as an upkeep plan")
check(#stock_passes == 1 and stock_passes[1] == "coal,wood", "the fuel stock is one registry pass for every fuel")

game.tick = 1300
chores.upkeep(game.tick)
check(#queued == 1, "a machine refuelled in the last minute is not refuelled again")

game.tick = 5000
storage.tasks.active = { id = 9 }
chores.upkeep(game.tick)
check(#queued == 1, "upkeep waits while the FIFO has work")
storage.tasks.active = nil
holding = true
chores.upkeep(game.tick)
check(#queued == 1, "upkeep never starts while the owner holds the body")
holding = false
storage.tasks.last_finished_tick = nil
chores.upkeep(game.tick)
check(#queued == 1, "upkeep does not undo an emergency stop")
storage.tasks.last_finished_tick = 4900

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

-- Labs missing the current research's packs get them from carried or stored
-- packs, in the same upkeep plan as refuelling.
local function lab(unit, x, raw)
  return { unit = unit, type = "lab", raw = raw, position = { x = x, y = 4 }, entity = { valid = true } }
end
sampled({ [7] = lab(7, 3, "missing_science_packs"), [8] = lab(8, 9, "missing_science_packs"),
  [9] = lab(9, 6, "working"), [10] = machine(10, 2, "no_fuel") })
storage.chores.refueled = {}
stocked = { coal = 20, ["automation-science-pack"] = 30, ["logistic-science-pack"] = 1 }
prototypes.item["automation-science-pack"], prototypes.item["logistic-science-pack"] = { stack_size = 200 }, { stack_size = 200 }
body.force.current_research = { name = "logistics", research_unit_ingredients = {
  { type = "item", name = "automation-science-pack", amount = 1 }, { type = "item", name = "logistic-science-pack", amount = 1 } } }
game.tick = 12000
local before = #queued
chores.upkeep(game.tick)
local fed = queued[#queued]
check(#queued == before + 1 and #fed.steps == 3 and fed.steps[1].x == 2 and fed.steps[1].items.wood == nil
  and fed.steps[2].x == 3 and fed.steps[3].x == 9 and fed.steps[2].items["automation-science-pack"] == 10
  and fed.steps[2].items["logistic-science-pack"] == nil and fed.steps[3].action == "insert_items",
  "upkeep brings the current research's packs to starved labs, nearest first, after refuelling")
game.tick = 12300
chores.upkeep(game.tick)
check(#queued == before + 1, "a lab fed in the last minute is not fed again")
body.force.current_research = nil

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

os.exit(failures == 0 and 0 or 1)
