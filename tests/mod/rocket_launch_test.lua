-- Offline tests for launch_rocket (actions/rocket.lua): every refusal is
-- decided before the body walks (no silo, unknown platform, rocket not
-- ready with its part count, a starter pack already sent or missing, a
-- platform not over this planet, cargo over the rocket's weight or slots);
-- cargo "requests" is what the hub's manual requests still lack, greedy as
-- far as it fits; the cargo comes through auto-supply, goes in through the
-- insert sub-action with the rocket inventory, and the launch names the
-- destination the platform's state calls for. Strict 2.0.77 mocks; supply
-- and the nested insert are stubs over a small simulated inventory.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local mock = dofile(here .. "/factorio_api_mock.lua")
_G.storage, _G.game = { space = { created = {}, events = {} } }, { tick = 50 }
_G.defines = {
  inventory = { rocket_silo_rocket = 5, hub_main = 1 },
  rocket_silo_status = { building_rocket = 1, rocket_ready = 10, launch_starting = 12 },
  cargo_destination = { space_platform = 2, station = 3 },
  space_platform_state = { waiting_for_starter_pack = 0, starter_pack_requested = 1, starter_pack_on_the_way = 2,
    waiting_at_station = 4, on_the_path = 5 },
  logistic_section_type = { manual = 0, request_missing_materials_controlled = 2 },
}
_G.prototypes = { item = {
  ["space-platform-starter-pack"] = { stack_size = 1, weight = 1000000 },
  ["iron-plate"] = { stack_size = 100, weight = 1000 },
  ["space-platform-foundation"] = { stack_size = 50, weight = 20000 },
  ["iron-gear-wheel"] = { stack_size = 100, weight = 1000 },
  satellite = { stack_size = 1, weight = 10 },
}, utility_constants = { rocket_lift_weight = 1000000 }, space_location = { nauvis = {}, vulcanus = {} } }

-- The body's inventory and the rocket's.
local carried, rocket_items = {}, {}
local function inventory(items, free, max)
  local inv = mock.inventory({})
  inv.get_item_count = function(item) return items[type(item) == "table" and item.name or item] or 0 end
  inv.count_empty_stacks = function()
    local used = 0
    for name, count in pairs(items) do used = used + math.ceil(count / prototypes.item[name].stack_size) end
    return (free or 20) - used
  end
  mock.read(inv, "weight", function()
    local w = 0
    for name, count in pairs(items) do w = w + count * prototypes.item[name].weight end
    return w
  end)
  mock.read(inv, "max_weight", function() return max end)
  inv.get_contents = function()
    local rows = {}
    for name, count in pairs(items) do rows[#rows + 1] = { name = name, quality = "normal", count = count } end
    return rows
  end
  return inv
end

local own = mock.force({ name = "player" })
local nauvis_planet = mock.planet({ name = "nauvis" })
local planet_surface = mock.surface({ index = 1, name = "nauvis", planet = nauvis_planet })
local launches = {}
local silo_state = { status = defines.rocket_silo_status.rocket_ready, parts = 50, launch = true, rocket = true }
local silo = mock.entity({ valid = true, name = "rocket-silo", type = "rocket-silo", force = own, position = { x = 20.5, y = 30.5 },
  surface = planet_surface, prototype = mock.entity_prototype({ rocket_parts_required = 50 }) })
mock.read(silo, "rocket_silo_status", function() return silo_state.status end)
mock.read(silo, "rocket_parts", function() return silo_state.parts end)
silo.get_inventory = function(id)
  assert(id == defines.inventory.rocket_silo_rocket)
  return silo_state.rocket and inventory(rocket_items, 20, 1000000) or nil
end
silo.launch_rocket = function(destination, character)
  assert(character == nil, "stage B never boards")
  launches[#launches + 1] = destination
  if silo_state.launch then silo_state.status = defines.rocket_silo_status.launch_starting end
  return silo_state.launch
end
local silos = { silo }
local finds = 0
planet_surface.find_entities_filtered = function(filter)
  finds = finds + 1
  assert(filter.type == "rocket-silo" and filter.force == own and filter.position and filter.limit == 1)
  return silos
end

-- Hub requests: one manual section.
local function section(slots)
  local s = mock.logistic_section({ index = 1, type = defines.logistic_section_type.manual, is_manual = true, active = true,
    group = "", filters_count = #slots })
  s.get_slot = function(i) return slots[i] or {} end
  return s
end
local hub_slots = {}
local hub_items = { ["iron-plate"] = 50 }
local hub = mock.entity({ valid = true, name = "space-platform-hub", type = "space-platform-hub", force = own,
  position = { x = 0, y = 0 } })
hub.get_inventory = function() return inventory(hub_items, 59) end
hub.get_logistic_sections = function()
  local sections = mock.logistic_sections({})
  local auto = mock.logistic_section({ index = 2, type = defines.logistic_section_type.request_missing_materials_controlled,
    is_manual = false, active = true, filters_count = 1 })
  auto.get_slot = function() return { value = { type = "item", name = "satellite", quality = "normal" }, min = 9 } end
  mock.read(sections, "sections", function() return { section(hub_slots), auto } end)
  return sections
end
local function platform(values)
  values.valid, values.scheduled_for_deletion, values.force = true, 0, own
  return mock.space_platform(values)
end
local nauvis = mock.space_location_prototype({ name = "nauvis" })
local built = platform({ index = 1, name = "alpha", state = defines.space_platform_state.waiting_at_station,
  space_location = nauvis, hub = hub })
local waiting = platform({ index = 2, name = "beta", state = defines.space_platform_state.waiting_for_starter_pack,
  starter_pack = { name = { name = "space-platform-starter-pack" } } })
local sent = platform({ index = 3, name = "gamma", state = defines.space_platform_state.starter_pack_on_the_way })
local away = platform({ index = 4, name = "delta", state = defines.space_platform_state.waiting_at_station,
  space_location = mock.space_location_prototype({ name = "vulcanus" }), hub = hub })
own.platforms = { [1] = built, [2] = waiting, [3] = sent, [4] = away }
storage.space.created[2] = "nauvis"

local body = mock.entity({ valid = true, force = own, surface = planet_surface, position = { x = 0, y = 0 }, reach_distance = 10 })
body.get_item_count = function(name) return carried[name] or 0 end
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
local walked, at_silo = 0, nil
package.loaded["scripts.actions.approach"] = { ensure = function()
    walked = walked + 1
    if at_silo then at_silo(); at_silo = nil end
    return "ok"
  end,
  ensure_entity = function() return "ok" end, find_entity_near = function() end }
-- Auto-supply fetches up to `stock` of each item; the nested insert moves
-- carried items into the rocket.
local stock, supplied, inserts = {}, {}, {}
package.loaded["scripts.actions.supply"] = {
  ensure = function(owner, needs)
    supplied[#supplied + 1] = needs
    local short = false
    for _, need in ipairs(needs) do
      local got = math.min(need.count - (carried[need.name] or 0), stock[need.name] or 0)
      carried[need.name] = (carried[need.name] or 0) + got
      if carried[need.name] < need.count then short = true end
    end
    if short then
      return { status = "partial", detail = "SUPPLY_SHORTFALL: missing some", outcome = { code = "SUPPLY_SHORTFALL",
        missing = { { item = needs[1].name, missing = needs[1].count - carried[needs[1].name] } } } }
    end
    return { status = "done", detail = "carrying", outcome = { code = "SUPPLIED" } }
  end,
  begin = function(owner, field, sub)
    assert(sub.type == "insert" and sub.inventory == "rocket" and sub.auto_supply == false and sub.target.x == 20.5)
    inserts[#inserts + 1] = sub
    owner[field] = sub
  end,
  step = function(owner, field)
    local sub = owner[field]
    owner[field] = nil
    local transfers = {}
    for name, count in pairs(sub.items) do
      local n = math.min(count, carried[name] or 0)
      carried[name] = (carried[name] or 0) - n
      rocket_items[name] = (rocket_items[name] or 0) + n
      transfers[#transfers + 1] = { item = name, inserted = n }
    end
    return { status = "done", detail = "inserted", outcome = { transfers = transfers } }
  end,
  resume = function() end,
}
package.loaded["scripts.actions.transfer"] = {}
package.loaded["scripts.actions.craft"] = { queued = function() return 0 end }
local rocket = require("scripts.actions.rocket")

local function reset()
  carried, rocket_items, stock, supplied, inserts, launches = {}, {}, {}, {}, {}, {}
  walked, finds, at_silo = 0, 0, nil
  silo_state.status, silo_state.parts, silo_state.launch, silo_state.rocket = defines.rocket_silo_status.rocket_ready, 50, true, true
end
local function run(step)
  step.silo = step.silo or { x = 20.5, y = 30.5 }
  rocket.action.validate(step, 1)
  local task = rocket.action.make_task(step)
  task.id = 4
  rocket.action.runner.start(task)
  for _ = 1, 20 do
    local result = rocket.action.runner.tick(task)
    if result then return result end
  end
  error("launch_rocket did not finish")
end
local function refused(result, code)
  return result.status == "failed" and result.outcome.code == code and walked == 0 and #supplied == 0 and #launches == 0
end

-- Refusals, all before any walking or supplying.
reset()
silos = {}
check(refused(run({ platform = "alpha" }), "NO_SILO"), "no own silo there: NO_SILO")
silos = { silo }
check(refused(run({ platform = "nope" }), "UNKNOWN_PLATFORM"), "an unknown platform: UNKNOWN_PLATFORM")
silo_state.status, silo_state.parts = defines.rocket_silo_status.building_rocket, 10
local not_ready = run({ platform = "alpha", cargo = { ["iron-plate"] = 10 } })
check(refused(not_ready, "ROCKET_NOT_READY") and not_ready.outcome.rocket.parts == 10
  and not_ready.outcome.rocket.parts_required == 50 and not_ready.outcome.rocket.status == "building_rocket"
  and not_ready.detail:match("10/50"), "a rocket not built yet fails at once with its parts")
reset()
check(refused(run({ platform = "gamma", cargo = { ["space-platform-starter-pack"] = 1 } }), "STARTER_PACK_ALREADY_SENT"),
  "a pack already on its way is never sent twice")
check(refused(run({ platform = "beta", cargo = { ["iron-plate"] = 5 } }), "STARTER_PACK_REQUIRED")
  and refused(run({ platform = "beta", cargo = "requests" }), "STARTER_PACK_REQUIRED"),
  "a platform waiting for its pack needs the pack in the cargo")
local away_result = run({ platform = "delta", cargo = { ["iron-plate"] = 5 } })
check(refused(away_result, "DESTINATION_NOT_IN_ORBIT") and away_result.outcome.location == "vulcanus"
  and away_result.outcome.silo_planet == "nauvis", "a platform over another planet is out of reach")
local heavy = run({ platform = "beta", cargo = { ["space-platform-starter-pack"] = 2 } })
check(refused(heavy, "OVERWEIGHT") and heavy.detail:match("2000"), "two starter packs are over the rocket's 1,000 kg")
check(refused(run({ platform = "alpha", cargo = { satellite = 21 } }), "NO_FREE_SLOTS"), "21 single stacks need more than 20 slots")
rocket_items = { ["iron-plate"] = 950 }
check(refused(run({ platform = "alpha", cargo = { ["iron-gear-wheel"] = 60 } }), "OVERWEIGHT"),
  "what inserters already loaded counts against the lift")
reset()
hub_slots = {}
check(refused(run({ platform = "alpha", cargo = "requests" }), "NOTHING_REQUESTED"), "nothing requested: nothing launched")

-- The starter pack: supplied, loaded into the rocket, launched to the platform.
reset()
stock["space-platform-starter-pack"] = 1
local pack = run({ platform = "beta", cargo = { ["space-platform-starter-pack"] = 1 } })
check(pack.status == "done" and #supplied == 1 and supplied[1][1].name == "space-platform-starter-pack"
  and #inserts == 1 and rocket_items["space-platform-starter-pack"] == 1 and #launches == 1
  and launches[1].type == defines.cargo_destination.space_platform and launches[1].space_platform == waiting,
  "the pack goes to a platform waiting for it as a starter-pack destination")
check(pack.outcome.launched and pack.outcome.destination.kind == "starter_pack" and pack.outcome.destination.platform.name == "beta"
  and pack.outcome.loaded[1].item == "space-platform-starter-pack" and pack.outcome.loaded[1].count == 1
  and pack.outcome.cargo_weight_kg == 1000 and pack.outcome.max_weight_kg == 1000 and pack.outcome.launch_tick == 50
  and pack.outcome.rocket.status == "launch_starting" and walked >= 1, "the result names what went up and where")

-- requests: what the hub lacks, greedy in request order as far as it fits.
reset()
hub_slots = {
  { value = { type = "item", name = "iron-plate", quality = "normal" }, min = 200 },
  { value = { type = "item", name = "space-platform-foundation", quality = "normal" }, min = 50, import_from = "nauvis" },
  { value = { type = "item", name = "iron-gear-wheel", quality = "normal" }, min = 10, import_from = "vulcanus" },
}
stock["iron-plate"], stock["space-platform-foundation"] = 500, 500
local requested = run({ platform = "alpha", cargo = "requests" })
check(requested.status == "done" and rocket_items["iron-plate"] == 150 and rocket_items["space-platform-foundation"] == 42
  and rocket_items["iron-gear-wheel"] == nil and rocket_items.satellite == nil,
  "requests: 150 plates the hub lacks, then the 42 foundation that still fit; another planet's import and the game's own section are left")
check(launches[1].type == defines.cargo_destination.station and launches[1].station == hub
  and requested.outcome.destination.kind == "hub", "a built platform's cargo goes to its hub")

-- A shortfall fails unless partial; partial loads what is carried.
reset()
stock["iron-plate"] = 30
local short = run({ platform = "alpha", cargo = { ["iron-plate"] = 100 } })
check(short.status == "failed" and short.outcome.code == "SUPPLY_SHORTFALL" and #inserts == 0 and #launches == 0,
  "a shortfall loads nothing and launches nothing")
reset()
stock["iron-plate"] = 30
local partial = run({ platform = "alpha", cargo = { ["iron-plate"] = 100 }, partial = true })
check(partial.status == "done" and rocket_items["iron-plate"] == 30 and partial.outcome.shortfall[1].missing == 70
  and #launches == 1, "partial: loads the 30 carried and names the 70 missing")

-- No cargo: the body walks to the silo and presses the button.
reset()
local empty = run({ platform = "alpha" })
check(empty.status == "done" and #supplied == 0 and #inserts == 0 and walked >= 1 and #launches == 1,
  "without cargo it launches what is loaded, from the silo")
reset()
silo_state.launch = false
local refused_launch = run({ platform = "alpha" })
check(refused_launch.status == "failed" and refused_launch.outcome.code == "LAUNCH_REFUSED", "a refused launch is named")

-- The button checks the destination again: the platform may have moved or
-- got its pack while the body supplied, loaded and walked.
reset()
stock["iron-plate"] = 10
at_silo = function() built.space_location = nil; built.state = defines.space_platform_state.on_the_path end
local moved = run({ platform = "alpha", cargo = { ["iron-plate"] = 10 } })
check(moved.status == "failed" and moved.outcome.code == "DESTINATION_NOT_IN_ORBIT" and #launches == 0
  and rocket_items["iron-plate"] == 10 and moved.detail:match("cargo stays in the rocket"),
  "a platform that left orbit after loading is not launched to; the cargo stays loaded")
built.space_location, built.state = nauvis, defines.space_platform_state.waiting_at_station
reset()
stock["space-platform-starter-pack"] = 1
at_silo = function() waiting.state = defines.space_platform_state.starter_pack_on_the_way end
local raced = run({ platform = "beta", cargo = { ["space-platform-starter-pack"] = 1 } })
check(raced.status == "failed" and raced.outcome.code == "STARTER_PACK_ALREADY_SENT" and #launches == 0,
  "a pack another silo sent meanwhile is never sent twice")
reset()
stock["space-platform-starter-pack"] = 1
at_silo = function() waiting.state = defines.space_platform_state.waiting_at_station; waiting.hub = hub end
local applied = run({ platform = "beta", cargo = { ["space-platform-starter-pack"] = 1 } })
check(applied.status == "failed" and applied.outcome.code == "STARTER_PACK_ALREADY_SENT" and #launches == 0,
  "a platform that got its pack meanwhile takes no starter-pack launch")
waiting.state, waiting.hub = defines.space_platform_state.waiting_for_starter_pack, nil

-- A pack already in the rocket (an earlier launch that failed at the
-- button, an inserter) launches on a retry, with or without naming it.
reset()
stock["space-platform-starter-pack"] = 1
silo_state.launch = false
local first = run({ platform = "beta", cargo = { ["space-platform-starter-pack"] = 1 } })
check(first.status == "failed" and first.outcome.code == "LAUNCH_REFUSED" and rocket_items["space-platform-starter-pack"] == 1,
  "a refused launch leaves the pack in the rocket")
silo_state.launch, supplied, inserts, launches = true, {}, {}, {}
local retry = run({ platform = "beta", cargo = { ["space-platform-starter-pack"] = 1 } })
check(retry.status == "done" and #supplied == 0 and #inserts == 0 and #launches == 1
  and launches[1].type == defines.cargo_destination.space_platform, "the retry launches the loaded pack without loading another")
reset()
rocket_items = { ["space-platform-starter-pack"] = 1 }
local bare_retry = run({ platform = "beta" })
check(bare_retry.status == "done" and #inserts == 0 and #launches == 1, "a loaded pack needs no cargo")
reset()
rocket_items = { ["iron-plate"] = 40 }
stock["iron-plate"] = 500
local topped = run({ platform = "alpha", cargo = { ["iron-plate"] = 100 } })
check(topped.status == "done" and supplied[1][1].count == 60 and rocket_items["iron-plate"] == 100,
  "explicit cargo loads only what the rocket does not hold yet")

-- Validation at queue time.
local function invalid(step, pattern)
  if step.silo == false then step.silo = nil else step.silo = step.silo or { x = 0, y = 0 } end
  local ok, err = pcall(rocket.action.validate, step, 3)
  return not ok and tostring(err):match(pattern) ~= nil
end
check(invalid({ silo = false, platform = "alpha" }, "needs silo"), "silo is required")
check(invalid({ platform = {} }, "platform name or index"), "the platform is a name or index")
check(invalid({ platform = "alpha", cargo = { mud = 1 } }, "^UNKNOWN_ITEM"), "cargo items must exist")
check(invalid({ platform = "alpha", cargo = { ["iron-plate"] = 0 } }, "integers from 1"), "cargo counts are positive")
check(invalid({ platform = "alpha", cargo = "everything" }, "requests"), "cargo is a map or \"requests\"")
check(invalid({ platform = "alpha", partial = "yes" }, "partial"), "partial is a boolean")

-- inspect_entity's silo block: rocket state, parts, cargo, weight, auto requests.
reset()
rocket_items = { ["iron-plate"] = 200, ["space-platform-foundation"] = 10 }
mock.read(silo, "use_transitional_requests", function() return true end)
mock.read(silo, "transitional_request_target", function() return built end)
local block = rocket.silo_block(silo)
check(block.status == "rocket_ready" and block.parts == 50 and block.parts_required == 50
  and #block.cargo == 2 and block.cargo[1].item == "iron-plate" and block.cargo[1].count == 200
  and block.cargo[2].item == "space-platform-foundation" and block.cargo_weight_kg == 400 and block.max_weight_kg == 1000
  and block.auto_requests == true and block.request_target.index == 1 and block.request_target.name == "alpha",
  "the silo block names the rocket, its cargo and weight, and the platform it requests for")
silo_state.rocket = false
local bare = rocket.silo_block(silo)
check(#bare.cargo == 0 and bare.cargo_weight_kg == nil, "a silo with no rocket yet reports no cargo")

mock.assert_clean()
print(failures == 0 and "\nALL ROCKET LAUNCH TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
