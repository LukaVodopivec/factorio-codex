-- Patch depletion from the patch cache (map_summary, after YARM's resource
-- monitor): each cell keeps the amount it had when first read and a rate
-- measured between two reads at least PATCH_RATE_TICKS apart, so a mined
-- patch gains minutes_left and remaining_fraction; a part mined out keeps
-- its initial amount; an infinite resource gives yield_percent instead; a
-- version 1 cache is upgraded in place. Surfaces, forces and prototypes are
-- strict 2.0.77 mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.game = { tick = 1000 }
_G.storage = {}
_G.defines = { flow_precision_index = { one_minute = 1 } }
_G.prototypes = { entity = {
  ["iron-ore"] = mock.entity_prototype({ infinite_resource = false, normal_resource_amount = 1 }),
  ["crude-oil"] = mock.entity_prototype({ infinite_resource = true, normal_resource_amount = 300000 }),
} }

-- Resources by chunk key; amounts change as the test mines them.
local resources = { ["0,0"] = {}, ["1,0"] = {}, ["5,5"] = {} }
-- How often each chunk was read.
local reads = {}
local function resource(key, name, x, y, amount)
  local entity = mock.entity({ valid = true, name = name, type = "resource", position = { x = x, y = y }, amount = amount })
  table.insert(resources[key], entity)
  return entity
end
-- One iron patch over two chunks (100 tiles of 1000 each), and an oil field.
for i = 0, 49 do resource("0,0", "iron-ore", 10 + i % 10, 10 + math.floor(i / 10), 1000) end
for i = 0, 49 do resource("1,0", "iron-ore", 33 + i % 10, 10 + math.floor(i / 10), 1000) end
resource("5,5", "crude-oil", 170, 170, 450000)
resource("5,5", "crude-oil", 175, 172, 150000)
local nauvis = mock.surface({ index = 1, name = "nauvis", valid = true,
  find_entities_filtered = function(filter)
    local area = filter.area
    local key = math.floor(area[1][1] / 32) .. "," .. math.floor(area[1][2] / 32)
    reads[key] = (reads[key] or 0) + 1
    return resources[math.floor(area[1][1] / 32) .. "," .. math.floor(area[1][2] / 32)] or {}
  end,
  get_chunks = function()
    local list, i = { { x = 0, y = 0 }, { x = 1, y = 0 }, { x = 5, y = 5 } }, 0
    return function() i = i + 1; return list[i] end
  end })
local force = mock.force({ name = "player", is_chunk_charted = function() return true end })
game.get_surface = function(index) return index == 1 and nauvis or nil end
package.loaded["scripts.companion"] = {
  get = function() return { valid = true, force = force, surface = nauvis } end,
  anchor = function() return { force = force, surface = nauvis, position = { x = 0, y = 0 }, state = "on_surface" } end,
  surface_ref = function() return "nauvis" end,
}
local state = require("scripts.state")
local map_summary = require("scripts.map_summary")

local function run(ticks)
  for _ = 1, ticks do game.tick = game.tick + 1; map_summary.patch_tick(game.tick) end
end
local function row(name)
  local rows = map_summary.patches(1)
  for _, patch in ipairs(rows) do if patch.name == name then return patch end end
end

storage.patch_caches = {}
run(200)
local iron, oil = row("iron-ore"), row("crude-oil")
check(iron and iron.amount == 100000 and iron.tiles == 100 and iron.minutes_left == nil and iron.remaining_fraction == nil,
  "an unmined patch has neither minutes_left nor remaining_fraction")
check(oil and oil.yield_percent == 200 and oil.minutes_left == nil and oil.remaining_fraction == nil,
  "an oil field gives the summed yield of its wells (450000 + 150000 of 300000 each: 200 %)")

-- Drills take 300 ore a minute from each chunk (600 a minute from the patch)
-- for five minutes, as the cache's round robin re-reads the chunks.
local mined = { resources["0,0"][1], resources["1,0"][1] }
for _ = 1, 5 do
  for _, entity in ipairs(mined) do entity.amount = entity.amount - 300 end
  run(3600)
end
iron = row("iron-ore")
check(iron and iron.amount == 97000, "the patch's amount follows mining (" .. tostring(iron and iron.amount) .. ")")
check(iron and iron.minutes_left and math.abs(iron.minutes_left - 97000 / 600) <= 2,
  "minutes_left is the amount over the measured rate, 600 a minute (" .. tostring(iron and iron.minutes_left) .. ")")
check(iron and iron.remaining_fraction == 0.97, "remaining_fraction is amount over the initial amount, in hundredths")

-- One chunk's ore runs out: its part keeps the initial amount, so the
-- fraction falls, and the outline shrinks to the ore still there.
resources["1,0"] = {}
map_summary.on_resource_depleted({ entity = mock.entity({ valid = true, surface_index = 1, position = { x = 40, y = 12 } }) })
run(3700)
iron = row("iron-ore")
check(iron and iron.tiles == 50 and iron.remaining_fraction == 0.49 and iron.bbox.right_bottom.x <= 20,
  "a mined-out chunk keeps its initial amount: 48.5 % remain, and the bbox covers only standing ore")
local empty = storage.patch_caches[1].chunks["1,0"].cells["iron-ore"]
check(empty.tiles == 0 and empty.rate == nil, "the mined-out part stays as an empty cell, with no rate")
do
  -- A depletion in a chunk the force never charted adds nothing to the
  -- charted land or the read queue.
  local cache = storage.patch_caches[1]
  local listed, pending = #cache.charted, #cache.pending
  map_summary.on_resource_depleted({ entity = mock.entity({ valid = true, surface_index = 1, position = { x = 900, y = 900 } }) })
  check(cache.charted_set["28,28"] == nil and #cache.charted == listed and #cache.pending == pending,
    "a depletion outside the charted chunks charts nothing and queues no read")
end
local read_empty, read_mined = reads["1,0"], reads["0,0"]
run(1200)
check(reads["1,0"] == read_empty and reads["0,0"] > read_mined, "a chunk mined out everywhere leaves the refresh round robin")
resources["0,0"] = {}
run(3700)
check(row("iron-ore") == nil, "a patch mined out everywhere is no row")

-- A first sliver mined rounds to a whole patch: no remaining_fraction yet.
-- No mining: the rate falls to zero at the next read past the window.
resources["0,0"] = { mock.entity({ valid = true, name = "iron-ore", type = "resource", position = { x = 3, y = 3 }, amount = 500 }) }
storage.patch_caches = {}
run(200)
resources["0,0"][1].amount = 499
for _ = 1, 2 do run(3700) end
iron = row("iron-ore")
check(iron and iron.amount == 499 and iron.minutes_left == nil and iron.remaining_fraction == nil,
  "a patch nobody mines any more has no minutes_left; 499 of 500 is no remaining_fraction")

do
  -- A newly charted chunk makes the list fill again until it is read and
  -- the rows rebuilt from it: a reader (explore) never takes a patch there
  -- as uncharted meanwhile.
  storage.patch_caches = {}
  run(200)
  local _, filled_before = map_summary.patches(1)
  resources["4,0"] = { mock.entity({ valid = true, name = "copper-ore", type = "resource", position = { x = 140, y = 5 }, amount = 700 }) }
  map_summary.on_chunk_charted({ surface_index = 1, position = { x = 4, y = 0 }, force = force })
  local _, filling = map_summary.patches(1)
  local filled_again
  for _ = 1, 50 do
    run(1)
    local _, filled = map_summary.patches(1)
    if filled then filled_again = filled; break end
  end
  check(filled_before == true and filling == false and filled_again and row("copper-ore") ~= nil,
    "a newly charted chunk is still filling until its patch is in the rows")
end

-- A version 1 cache (0.31 and older) keeps its chunks and gains the
-- depletion fields from its current amounts.
local cell = { cx = 0, cy = 0, amount = 900, tiles = 9, x = 0, y = 0, left = 0, right = 2, top = 0, bottom = 2 }
storage.patch_caches = { [1] = { version = 1, surface_index = 1, seeded = true, filled = true, rows = {},
  chunks = { ["0,0"] = { cx = 0, cy = 0, cells = { ["iron-ore"] = cell } } }, known = { ["0,0"] = true },
  pending = {}, head = 1, queued = {}, refresh = {}, dirty = false, charted = { { x = 0, y = 0 } },
  charted_set = { ["0,0"] = true } } }
state.init()
local upgraded = storage.patch_caches[1]
check(upgraded and upgraded.version == state.PATCH_CACHE_VERSION and upgraded.dirty
  and upgraded.chunks["0,0"].cells["iron-ore"] == cell and cell.initial == 900 and cell.base_tick == game.tick,
  "a version 1 cache is upgraded in place: its cells start counting from the upgrade")

mock.assert_clean()
if failures > 0 then error(failures .. " patch depletion checks failed") end
