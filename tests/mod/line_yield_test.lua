-- What a line counts per cycle (autonomy.lua): a drill finishing more than
-- one cycle a sample, its productivity products, a chance or ranged
-- product's average yield, and the recipe's productivity cap in the
-- nameplate. Machines are strict LuaEntity mocks advanced tick by tick.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local RAW = { working = 1, low_power = 2 }
_G.defines = { entity_status = RAW, inventory = { crafter_input = 2, lab_input = 3 },
  rocket_silo_status = { building_rocket = 1, rocket_ready = 10 }, direction = { north = 0, east = 4, south = 8, west = 12 } }
-- A ranged chance product: 1 to 3 at one half, 1 on average a craft.
local SCRAP = { name = "scrap-sorting", energy = 1, maximum_productivity = 0.25,
  ingredients = { { name = "scrap", type = "item", amount = 1 } },
  products = { { name = "gear", type = "item", amount_min = 1, amount_max = 3, probability = 0.5 },
    { name = "plate", type = "item", amount = 1 } } }
_G.prototypes = { recipe = { ["scrap-sorting"] = SCRAP },
  entity = { ["big-mining-drill"] = { mining_speed = 2.5 },
    ["assembler"] = { get_crafting_speed = function() return 1 end, effect_receiver = { base_effect = { productivity = 0.5 } } } },
  get_entity_filtered = function()
    return { ["iron-ore"] = { mineable_properties = { mining_time = 1, products = { { type = "item", name = "iron-ore", amount = 1 } } } } }
  end }
_G.game = { tick = 0 }
_G.storage = {}
_G.script = { register_on_object_destroyed = function() return 1 end }

local force = { name = "player", is_chunk_charted = function() return true end, mining_drill_productivity_bonus = 0.1,
  recipes = { ["scrap-sorting"] = { productivity_bonus = 0.5 } } }
local surface = { index = 1 }
local body = { valid = true, position = { x = 0, y = 0 }, force = force, surface = surface }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end,
  human_control = function() return false, 999 end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
local state = require("scripts.state")
local registry = require("scripts.registry")
local autonomy = require("scripts.autonomy")
state.init()
storage.registry.ready = true

local ore = mock.entity({ valid = true, name = "iron-ore", type = "resource", position = { x = 0, y = 0 },
  prototype = { mineable_properties = { mining_time = 1, products = { { name = "iron-ore", type = "item", amount = 1 } } } } })
local next_unit = 100
local function machine(kind, name, x, y, extra)
  next_unit = next_unit + 1
  local values = { valid = true, name = name, type = kind, position = { x = x, y = y }, unit_number = next_unit,
    force = force, surface = surface }
  for key, value in pairs(extra or {}) do values[key] = value end
  local entity = mock.entity(values)
  local sim = mock.state(entity)
  sim.status, sim.mining_progress, sim.bonus_mining_progress, sim.products_finished = RAW.working, 0, 0, 0
  for _, key in ipairs({ "status", "mining_progress", "bonus_mining_progress", "products_finished" }) do
    mock.read(entity, key, function() return sim[key] end)
  end
  registry.add(entity)
  return entity
end

-- A big drill (2.5 / 1 s iron ore, 150 a minute) with +10% productivity
-- (15 more): 1.25 cycles a 30-tick sample, so its progress shows a quarter
-- more each sample and wraps on only some of them.
local drill = machine("mining-drill", "big-mining-drill", 0, 0, { mining_target = ore, speed_bonus = 0, productivity_bonus = 0.1,
  prototype = prototypes.entity["big-mining-drill"] })
local assembler = machine("assembling-machine", "assembler", 40, 0, { get_recipe = function() return SCRAP end })
local base, extra, crafts = 0, 0, 0
local function run(ticks)
  for _ = 1, ticks do
    game.tick = game.tick + 1
    local sim, made = mock.state(drill), mock.state(assembler)
    if sim.status == RAW.working then
      base, extra = base + 2.5 / 60, extra + 2.5 / 60 * 0.1
      sim.mining_progress, sim.bonus_mining_progress = base % 1, extra % 1
    end
    if game.tick % 60 == 0 then crafts = crafts + 1; made.products_finished = crafts end
    autonomy.on_tick(game.tick)
  end
end
-- The rate covers the last six 10 s bins, the current one partial: read
-- just before a bin closes.
run(3 * 3600 + 595)
local function line(product) for _, row in ipairs(autonomy.lines()) do if row.product == product then return row end end end
local ore_line, gear_line = line("iron-ore"), line("gear")
check(ore_line and ore_line.rate_per_min >= 160 and ore_line.rate_per_min <= 170,
  "a drill finishing more than one cycle a sample counts each, productivity products included ("
    .. tostring(ore_line and ore_line.rate_per_min) .. " of 165)")
check(select(3, autonomy.producing("iron-ore", nil, true)) == 165, "its nameplate agrees with the count")
check(gear_line and gear_line.rate_per_min >= 59 and gear_line.rate_per_min <= 61 and line("plate") == nil,
  "a ranged chance product counts its average yield, and a line is its recipe's first product only")
check(select(3, autonomy.producing("gear", nil, true)) == 75,
  "built-in and researched productivity stop at the recipe's maximum in the nameplate")

-- At low power the drill advances less than nominal: only seen wraps count.
mock.state(drill).status = RAW.low_power
local before = base
for _ = 1, 3600 do
  game.tick = game.tick + 1
  local sim = mock.state(drill)
  base, extra = base + 0.5 / 60, extra + 0.5 / 60 * 0.1
  sim.mining_progress, sim.bonus_mining_progress = base % 1, extra % 1
  autonomy.on_tick(game.tick)
end
ore_line = line("iron-ore")
check(base - before > 29 and ore_line.rate_per_min >= 30 and ore_line.rate_per_min <= 34,
  "a drill not at full power counts the wraps it shows (" .. ore_line.rate_per_min .. " of 33)")

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
