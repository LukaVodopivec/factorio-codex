-- Offline tests for inserter throughput (scripts/inserter_rate.lua): the
-- upper bound from rotation and extension speed, pickup and drop vectors and
-- hand size with the force's bonus. Prototype values are Factorio 2.0.77's.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local rate = require("scripts.inserter_rate")

-- An inserter prototype as 2.0.77 reports it: vectors as {x, y} arrays and
-- quality-dependent speed methods (legendary turns 2.5 times as fast).
local function inserter(rotation, extension, pickup, drop, bulk, bonus)
  local factor = { normal = 1, legendary = 2.5 }
  return { inserter_pickup_position = pickup or { 0, -1 }, inserter_drop_position = drop or { 0, 1.2 },
    bulk = bulk or false, inserter_stack_size_bonus = bonus or 0,
    get_inserter_rotation_speed = function(quality) return rotation * factor[quality or "normal"] end,
    get_inserter_extension_speed = function(quality) return extension * factor[quality or "normal"] end }
end
local burner = inserter(0.013, 0.035)
local basic = inserter(0.014, 0.035)
local long = inserter(0.02, 0.05, { 0, -2 }, { 0, 2.2 })
local fast = inserter(0.04, 0.1)
local bulk = inserter(0.04, 0.1, nil, nil, true, 0)
local stack = inserter(0.04, 0.1, nil, nil, true, 4)
local force = { inserter_stack_size_bonus = 0, bulk_inserter_capacity_bonus = 0 }

-- Half a turn is 35.7 ticks for the basic inserter: a leg takes 35, a swing
-- 70, 0.86 items a second; a fast inserter's 12.5 make 24 ticks a swing, 2.5
-- a second (2.0.77 measured chest to chest: 0.865 and 2.496).
check(rate.max_items_per_second(basic, force) == 0.86, "an inserter moves at most 0.86 items a second")
check(rate.max_items_per_second(burner, force) == 0.79, "a burner inserter at most 0.79")
check(rate.max_items_per_second(long, force) == 1.25, "a long-handed inserter at most 1.25")
check(rate.max_items_per_second(fast, force) == 2.5, "a fast inserter at most 2.5")
check(rate.max_items_per_second(fast, force, "legendary") == 7.5, "quality speeds the swing")

-- Hand size: the force's inserter bonus for ordinary inserters, its bulk
-- capacity bonus for bulk ones, plus the prototype's own stack bonus.
force.inserter_stack_size_bonus, force.bulk_inserter_capacity_bonus = 1, 3
check(rate.max_items_per_second(fast, force) == 5 and rate.hand_size(fast, force) == 2,
  "the force's inserter stack bonus doubles a fast inserter's hand")
check(rate.hand_size(bulk, force) == 4 and rate.max_items_per_second(bulk, force) == 10,
  "a bulk inserter takes the bulk capacity bonus, not the inserter one")
check(rate.hand_size(stack, force) == 8, "a prototype's own stack bonus adds to the hand")
check(rate.hand_size(bulk, force, 2) == 2 and rate.max_items_per_second(bulk, force, "normal", 2) == 5,
  "a placed inserter's stack size override caps its hand")

-- A rotation the arm's extension outlasts: the extension sets the swing.
local stretched = inserter(0.5, 0.035, { 0, -1 }, { 0, 3 })
check(rate.max_items_per_second(stretched, { inserter_stack_size_bonus = 0 }) == 0.53,
  "an extension longer than the rotation sets the swing time")

check(rate.max_items_per_second({ name = "assembling-machine-1" }, force) == nil, "a non-inserter has no rate")

local placed = { prototype = fast, force = force, quality = { name = "legendary" }, inserter_stack_size_override = 0 }
check(rate.of_entity(placed) == 15, "a placed inserter uses its quality and force")

os.exit(failures == 0 and 0 or 1)
