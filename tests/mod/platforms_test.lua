-- Offline tests for space platforms (platforms.lua): the one resolver
-- (names, indices, ambiguity, platforms pending deletion invisible),
-- platform_status compact lines (attribute reads only) and the full screen
-- as a job (foundation runs read chunk by chunk, entities searched chunk by
-- chunk over the foundation's box and counted once, ghosts and what they
-- still miss, thrusters' fuel, hub stock and requests, tile damage),
-- create_platform (remote, validated before its one write) and the space
-- event ring. Strict 2.0.77 mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local mock = dofile(here .. "/factorio_api_mock.lua")
_G.storage, _G.game = { space = { created = {}, events = {} } }, { tick = 100 }
_G.defines = {
  inventory = { hub_main = 1, hub_trash = 2, asteroid_collector_output = 3 },
  entity_status = { working = 1, no_power = 2, waiting_for_source_items = 3 },
  space_platform_state = { waiting_for_starter_pack = 0, starter_pack_requested = 1, starter_pack_on_the_way = 2,
    on_the_path = 3, waiting_at_station = 4, no_schedule = 5 },
  logistic_section_type = { manual = 0, request_missing_materials_controlled = 2 },
}
_G.prototypes = { quality = { normal = {}, rare = {} } }
_G.helpers = { table_to_json = function() return "{}" end }

local function inventory(items, free)
  local inv = mock.inventory({})
  inv.get_contents = function()
    local rows = {}
    for name, count in pairs(items) do rows[#rows + 1] = { name = name, quality = "normal", count = count } end
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
  end
  inv.get_item_count = function(item)
    if item == nil then local n = 0; for _, c in pairs(items) do n = n + c end; return n end
    return items[type(item) == "table" and item.name or item] or 0
  end
  inv.count_empty_stacks = function() return free or 0 end
  return inv
end

-- A world of own entities on one platform surface; every query is counted.
-- Searches are inclusive at the area's far edges, as an entity's box
-- overlapping a chunk edge is found from both chunks.
local queries, tile_reads, tile_areas = {}, 0, {}
local entities = {}
local function inside(area, x, y)
  return x >= area[1][1] and x <= area[2][1] and y >= area[1][2] and y <= area[2][2]
end
local function chunks_of(tiles, extra)
  local seen, list = {}, {}
  for _, t in ipairs(tiles) do
    local cx, cy = math.floor(t.x / 32), math.floor(t.y / 32)
    if not seen[cx .. "," .. cy] then seen[cx .. "," .. cy] = true; list[#list + 1] = { x = cx, y = cy } end
  end
  for _, c in ipairs(extra or {}) do list[#list + 1] = c end
  return list
end
local function surface_of(tiles, extra_chunks)
  return mock.surface({ valid = true, index = 7, name = "platform-7",
    get_chunks = function()
      local list, i = chunks_of(tiles, extra_chunks), 0
      return function()
        i = i + 1
        local c = list[i]
        return c and { x = c.x, y = c.y, area = { left_top = { x = c.x * 32, y = c.y * 32 } } } or nil
      end
    end,
    find_tiles_filtered = function(filter)
      tile_reads = tile_reads + 1
      tile_areas[#tile_areas + 1] = filter.area
      assert(filter.name == "space-platform-foundation" and filter.area)
      local found = {}
      for _, t in ipairs(tiles) do
        if inside(filter.area, t.x, t.y) then found[#found + 1] = mock.tile({ position = { x = t.x, y = t.y } }) end
      end
      return found
    end,
    find_entities_filtered = function(filter)
      queries[#queries + 1] = filter
      assert(filter.area and filter.force, "each search names its area and the force")
      local found = {}
      for _, e in ipairs(entities) do
        if inside(filter.area, e.position.x, e.position.y) then found[#found + 1] = e end
      end
      return found
    end })
end

-- Foundation: rows y = -2..1 from x = -2..1, and a separate strip at y = 0
-- x = 4..5 (a gap at 2..3).
local tiles = {}
for y = -2, 1 do for x = -2, 1 do tiles[#tiles + 1] = { x = x, y = y } end end
tiles[#tiles + 1] = { x = 5, y = 0 }
tiles[#tiles + 1] = { x = 4, y = 0 }

local own = mock.force({ name = "player" })
local hub_items = { ["space-platform-foundation"] = 10, ["iron-plate"] = 3 }
local sections = mock.logistic_sections({})
local hub = mock.entity({ valid = true, name = "space-platform-hub", type = "space-platform-hub", position = { x = 0, y = 0 },
  force = own })
hub.get_inventory = function(id)
  if id == defines.inventory.hub_main then return inventory(hub_items, 50) end
  if id == defines.inventory.hub_trash then return inventory({ ["iron-ore"] = 2 }) end
end
local platform_surface = surface_of(tiles, { { x = 3, y = 3 } })
local function platform(values)
  values.valid = values.valid ~= false
  values.scheduled_for_deletion = values.scheduled_for_deletion or 0
  values.force = own
  values.speed = values.speed or 0
  return mock.space_platform(values)
end
local nauvis = mock.space_location_prototype({ name = "nauvis" })
local alpha = platform({ index = 1, name = "alpha", state = defines.space_platform_state.waiting_at_station,
  space_location = nauvis, hub = hub, surface = platform_surface, damaged_tiles = { { position = { x = 1, y = 1 }, damage = 12.5 },
    { position = { x = 0, y = 1 }, damage = 2.5 } } })
local waiting = platform({ index = 2, name = "beta", state = defines.space_platform_state.waiting_for_starter_pack,
  starter_pack = { name = { name = "space-platform-starter-pack" }, quality = "normal" } })
local twin_a = platform({ index = 3, name = "twin", state = defines.space_platform_state.no_schedule })
local twin_b = platform({ index = 4, name = "twin", state = defines.space_platform_state.no_schedule })
local deleted = platform({ index = 5, name = "gone", state = defines.space_platform_state.no_schedule,
  scheduled_for_deletion = 600 })
own.platforms = { [1] = alpha, [2] = waiting, [3] = twin_a, [4] = twin_b, [5] = deleted }

local body = mock.entity({ valid = true, force = own, surface = mock.surface({ index = 1, name = "nauvis",
  planet = mock.planet({ name = "nauvis" }) }), position = { x = 0, y = 0 } })
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end,
  -- Any body state but absent (remote actions, reads, queue_plan); no surface tag.
  require_present = function() return { state = "on_surface", force = body.force, surface = body.surface } end,
  anchor = function() return nil end, body = function() return { state = "on_surface", force = body.force } end }
local platforms = require("scripts.platforms")
local jobs = require("scripts.jobs")
-- The hub's requests come from requests.lua (set_requests_test covers it).
platforms.set_requests_reader({ count = function(e) assert(e == hub); return 2 end,
  read = function(e) assert(e == hub); return { { index = 1, group = "", type = "manual", active = true, items = {} } } end })

-- Resolver.
check(platforms.resolve(own, "alpha") == alpha and platforms.resolve(own, 2) == waiting, "a platform resolves by name or index")
local p, code = platforms.resolve(own, "twin")
check(p == nil and code == "AMBIGUOUS_PLATFORM" and platforms.resolve(own, 4) == twin_b, "a shared name is ambiguous; its index is not")
p, code = platforms.resolve(own, "gone")
check(p == nil and code == "UNKNOWN_PLATFORM" and platforms.resolve(own, 5) == nil, "a platform pending deletion is invisible")
check(not pcall(platforms.check_selector, {}, "x") and not pcall(platforms.check_selector, 1.5, "x")
  and pcall(platforms.check_selector, "alpha", "x"), "a selector is a name or an index")

-- Compact: attribute reads only.
local compact = jobs.run_now(platforms.status_job, {})
local rows = compact.platforms
check(#rows == 4 and rows[1].name == "alpha" and rows[1].state == "waiting_at_station" and rows[1].location == "nauvis"
  and rows[1].hub_free_slots == 50 and rows[1].requests_count == 2 and rows[2].state == "waiting_for_starter_pack"
  and rows[2].hub_free_slots == nil and rows[2].starter_pack == "space-platform-starter-pack" and compact.omitted_platforms == nil,
  "compact lists every visible platform: state, location, hub slots, request count, starter pack")
check(#queries == 0 and tile_reads == 0, "compact makes no query")
local one = jobs.run_now(platforms.status_job, { platform = "beta" })
check(#one.platforms == 1 and one.platforms[1].index == 2, "compact for one platform")
check(not pcall(jobs.run_now, platforms.status_job, { detail = "full" }), "full needs a platform")
local ok_missing, missing_error = pcall(jobs.run_now, platforms.status_job, { platform = "nope" })
check(not ok_missing and tostring(missing_error):match("^UNKNOWN_PLATFORM"), "an unknown platform is named")

-- Full: the foundation read chunk by chunk, entities searched chunk by chunk.
local function entity(values)
  values.valid, values.force = true, own
  return mock.entity(values)
end
local collector = entity({ name = "asteroid-collector", type = "asteroid-collector", position = { x = 1, y = -2 },
  status = defines.entity_status.working, direction = 0, filter_slot_count = 3 })
collector.get_filter = function(i) return i == 1 and { name = "metallic-asteroid-chunk" } or nil end
collector.get_inventory = function(id) assert(id == defines.inventory.asteroid_collector_output); return inventory({ ["metallic-asteroid-chunk"] = 4 }) end
local crusher = entity({ name = "crusher", type = "assembling-machine", position = { x = -1, y = 0 },
  status = defines.entity_status.no_power, direction = 4 })
crusher.get_recipe = function() return { name = "metallic-asteroid-crushing" } end
local function fluidbox(fuel, oxidizer)
  local box = mock.fluidbox({})
  local fluids = { fuel and { name = "thruster-fuel", amount = fuel } or nil, { name = "thruster-oxidizer", amount = oxidizer } }
  mock.length(box, function() return 2 end)
  box.get_capacity = function() return 1000 end
  box.get_filter = function(i) return { name = i == 1 and "thruster-fuel" or "thruster-oxidizer" } end
  -- Indexing reads the fluid in that box (nil when empty).
  mock.read(box, 1, function() return fluids[1] end)
  mock.read(box, 2, function() return fluids[2] end)
  return box
end
local thruster_a = entity({ name = "thruster", type = "thruster", position = { x = 0, y = 1 }, status = defines.entity_status.working })
mock.read(thruster_a, "fluidbox", function() return fluidbox(500, 1000) end)
local thruster_b = entity({ name = "thruster", type = "thruster", position = { x = -2, y = 1 },
  status = defines.entity_status.waiting_for_source_items })
mock.read(thruster_b, "fluidbox", function() return fluidbox(nil, 0) end)
local function ghost(kind, item, count)
  local proto = kind == "tile-ghost" and mock.tile_prototype({ items_to_place_this = { { name = item, count = count } } })
    or mock.entity_prototype({ items_to_place_this = { { name = item, count = count } } })
  return entity({ name = kind, type = kind, position = { x = 0, y = -1 }, ghost_prototype = proto })
end
entities = { hub, collector, crusher, thruster_a, thruster_b, ghost("tile-ghost", "space-platform-foundation", 1),
  ghost("tile-ghost", "space-platform-foundation", 1), ghost("entity-ghost", "inserter", 1),
  ghost("entity-ghost", "iron-plate", 2), ghost("entity-ghost", "space-platform-foundation", 9) }

local slices = 0
local full_job = platforms.status_job.start({ platform = "alpha", detail = "full" })
local full
-- Small slices: the job is resumable from plain state at every phase.
for _ = 1, 400 do
  slices = slices + 1
  full = platforms.status_job.step(full_job, { left = 2 })
  if full then break end
end
check(full ~= nil and slices > 3, "full detail runs as a job over several slices")
local chunk_reads = true
for _, area in ipairs(tile_areas) do
  chunk_reads = chunk_reads and area[2][1] - area[1][1] == 32 and area[2][2] - area[1][2] == 32
end
local box_searches = #queries == 4
for _, q in ipairs(queries) do
  box_searches = box_searches and q.area[1][1] >= -2 and q.area[1][2] >= -2 and q.area[2][1] <= 6 and q.area[2][2] <= 2
    and q.area[2][1] - q.area[1][1] <= 32 and q.area[2][2] - q.area[1][2] <= 32
end
check(tile_reads == 5 and chunk_reads and box_searches,
  "one tile read per generated chunk; one entity search per chunk of the foundation's box, clipped to it")
local f = full.foundation
local runs = {}
for _, row in ipairs(f.rows) do runs[#runs + 1] = table.concat(row, ",") end
check(f.tiles == 18 and table.concat(runs, " ") == "-2,-2,1 -1,-2,1 0,-2,1 0,4,5 1,-2,1"
  and f.bbox.left_top.x == -2 and f.bbox.right_bottom.x == 6, "the foundation as runs per row, with its box")
check(#full.entities == 4 and full.entities[1].name == "asteroid-collector" and full.entities[1].filters[1] == "metallic-asteroid-chunk"
  and #full.entities[1].filters == 1 and full.entities[1].output == 4 and full.entities[1].direction == nil
  and full.entities[2].recipe == "metallic-asteroid-crushing" and full.entities[2].status == "no_power"
  and full.entities[2].direction == 4, "entities in (y, x) order with collector filters and output, crusher recipe and status")
check(full.ghosts.entities == 3 and full.ghosts.tiles == 2 and #full.ghosts.missing == 2
  and full.ghosts.missing[1].item == "inserter" and full.ghosts.missing[1].count == 1
  and full.ghosts.missing[2].item == "space-platform-foundation" and full.ghosts.missing[2].count == 1,
  "ghosts counted; missing is what the hub's stock does not cover (10 foundation for 11, 3 plates for 2)")
check(full.thrusters.count == 2 and full.thrusters.working == 1 and full.thrusters.fuel_fill == 0.25
  and full.thrusters.oxidizer_fill == 0.5, "thrusters: count, working and fuel and oxidizer fill")
check(full.hub.free_slots == 50 and full.hub.inventory[1].item == "space-platform-foundation"
  and full.hub.inventory[1].count == 10 and full.hub.trash[1].item == "iron-ore" and #full.requests == 1,
  "hub stock, trash and requests")
check(full.damage.damaged_tiles == 2 and full.damage.total == 15 and full.surface == "platform:1"
  and full.platform.name == "alpha", "tile damage as a count and sum; the platform's surface is named")
check(#full.thrusters.by_name == 1 and full.thrusters.by_name[1].name == "thruster" and full.thrusters.by_name[1].count == 2
  and full.thrusters.by_name[1].working == 1 and full.turrets == nil and full.trip == nil
  and full.damage.damaged_entities == 0, "thrusters by name; no turrets, trip or entity damage to report")

-- Turrets and thrusters are counted by name whatever the entity rows' cap
-- leaves out, with each ammo turret's ammo; damage carried now and the
-- losses of the trip since the last departure.
defines.inventory.turret_ammo = 4
local function turret(name, kind, x, ammo, health)
  local e = entity({ name = name, type = kind, position = { x = x, y = 1 }, status = ammo == false and defines.entity_status.no_power
    or defines.entity_status.working, health = health or 400, max_health = 400 })
  e.get_inventory = function(id) assert(id == defines.inventory.turret_ammo); return inventory(ammo or {}) end
  return e
end
local saved_cap, saved_entities, saved_reads = platforms.MAX_ENTITIES, entities, tile_reads
platforms.MAX_ENTITIES = 2
entities = { hub, thruster_a, thruster_b, turret("gun-turret", "ammo-turret", -1, { ["firearm-magazine"] = 10 }, 250),
  turret("gun-turret", "ammo-turret", 1, nil), turret("laser-turret", "electric-turret", 0, false) }
local defended = jobs.run_now(platforms.status_job, { platform = "alpha", detail = "full" })
platforms.MAX_ENTITIES, entities, tile_reads = saved_cap, saved_entities, saved_reads
local gun, laser = defended.turrets[1], defended.turrets[2]
check(#defended.entities == 2 and defended.omitted_entities == 3 and #defended.turrets == 2
  and gun.name == "gun-turret" and gun.count == 2 and gun.working == 2 and gun.no_ammo == 1
  and gun.ammo[1].item == "firearm-magazine" and gun.ammo[1].count == 10
  and laser.name == "laser-turret" and laser.count == 1 and laser.working == 0 and laser.ammo == nil and laser.no_ammo == nil
  and defended.thrusters.by_name[1].count == 2,
  "every turret and thruster is counted by name past the entity cap, with ammo held and turrets without ammo")
check(defended.damage.damaged_entities == 1 and defended.damage.entity_health_missing == 150,
  "the damage entities carry now: how many and the health they miss")
-- A departure starts a trip; own losses on that platform count on it.
alpha.last_visited_space_location = nauvis
alpha.state = defines.space_platform_state.on_the_path
platforms.on_platform_state_changed({ platform = alpha, old_state = defines.space_platform_state.waiting_at_station })
alpha.state = defines.space_platform_state.waiting_at_station
local function died(name, surface, force)
  local e = entity({ name = name, type = "ammo-turret", position = { x = 0, y = 0 }, surface = surface })
  if force then e.force = force end
  platforms.on_entity_died({ entity = e })
end
platform_surface.platform = alpha
died("gun-turret", platform_surface)
died("gun-turret", platform_surface)
died("thruster", platform_surface)
died("stone-furnace", mock.surface({ name = "nauvis" }))
died("gun-turret", platform_surface, mock.force({ name = "enemy" }))
local trip = platforms.trip(alpha)
check(trip and trip.departed_tick == game.tick and trip.from == "nauvis" and #trip.lost == 2 and trip.lost[1].name == "gun-turret"
  and trip.lost[1].count == 2 and trip.lost[2].name == "thruster" and trip.lost[2].count == 1
  and jobs.run_now(platforms.status_job, { platform = "alpha" }).platforms[1].trip.lost[1].count == 2,
  "a departure starts a trip; own entities lost on that platform since count by name (compact and full)")
platforms.on_platform_state_changed({ platform = alpha, old_state = defines.space_platform_state.on_the_path })
alpha.state = defines.space_platform_state.on_the_path
platforms.on_platform_state_changed({ platform = alpha, old_state = defines.space_platform_state.waiting_at_station })
alpha.state = defines.space_platform_state.waiting_at_station
check(#platforms.trip(alpha).lost == 0, "the next departure starts a fresh trip")
storage.space.events = {}

-- Before its starter pack lands a platform has no hub: identity only.
local bare = jobs.run_now(platforms.status_job, { platform = 2, detail = "full" })
check(bare.platform.index == 2 and bare.hub == nil and bare.foundation == nil and tile_reads == 5, "no hub: identity and state only")

-- A grown platform: 16 full chunks of foundation. No step holds a tile
-- list, each read covers one chunk, and no slice overruns its budget by
-- more than one chunk's read.
local big = {}
for y = -64, 63 do for x = -64, 63 do big[#big + 1] = { x = x, y = y } end end
own.platforms[6] = platform({ index = 6, name = "big", state = defines.space_platform_state.waiting_at_station,
  space_location = nauvis, hub = hub, surface = surface_of(big) })
entities, queries, tile_reads, tile_areas = {}, {}, 0, {}
local big_job = platforms.status_job.start({ platform = "big", detail = "full" })
local big_full, worst, held_tiles = nil, 0, false
for _ = 1, 400 do
  local budget = { left = 600 }
  big_full = platforms.status_job.step(big_job, budget)
  worst = math.max(worst, -budget.left)
  for _, value in pairs(big_job) do if type(value) == "table" and #value > 1024 then held_tiles = true end end
  if big_full then break end
end
check(big_full and big_full.foundation.tiles == 128 * 128 and #big_full.foundation.rows == 128 and tile_reads == 16
  and not held_tiles and worst <= 65, "a large foundation is read a chunk at a time within the budget")
own.platforms[6] = nil

-- create_platform: remote and validated before its one write.
local created_calls = {}
own.is_space_platforms_unlocked = function() return false end
own.create_space_platform = function(params)
  created_calls[#created_calls + 1] = params
  local new = platform({ index = 9, name = params.name, state = defines.space_platform_state.waiting_for_starter_pack })
  own.platforms[9] = new
  return new
end
local ok_locked, locked = pcall(platforms.create_platform, { name = "gamma" })
check(not ok_locked and tostring(locked):match("^PLATFORMS_LOCKED") and #created_calls == 0, "locked platforms refuse")
own.is_space_platforms_unlocked = function() return true end
local ok_taken, taken = pcall(platforms.create_platform, { name = "alpha" })
check(not ok_taken and tostring(taken):match("^NAME_TAKEN") and #created_calls == 0, "a taken name refuses")
storage.space.created[77] = "nauvis"
local made = platforms.create_platform({ name = "gamma" })
check(#created_calls == 1 and created_calls[1].planet == "nauvis" and created_calls[1].starter_pack.name == "space-platform-starter-pack"
  and created_calls[1].starter_pack.quality == "normal" and made.platform.index == 9 and made.platform.state == "waiting_for_starter_pack"
  and made.platform.planet == "nauvis" and storage.space.created[9] == "nauvis" and storage.space.created[77] == nil,
  "create_platform makes the platform over the body's planet and remembers it while the pack is due")
check(platforms.planet(own.platforms[9]) == "nauvis", "a waiting platform's planet is the one it was made over")
check(storage.milestones.platform_created_tick == game.tick, "the first platform made is a milestone")
check(not pcall(platforms.create_action.validate, { name = "" }, 1) and not pcall(platforms.create_action.validate,
  { name = "x", quality = "shiny" }, 1) and platforms.create_action.remote({}), "plan step: validated at queue time, remote")
local ok_rare, rare = pcall(platforms.create_platform, { name = "delta", quality = "rare" })
check(not ok_rare and tostring(rare):match('quality must be "normal"') and #created_calls == 1
  and not pcall(platforms.create_action.validate, { name = "x", quality = "rare" }, 1),
  "a starter pack of another quality is refused: launch_rocket only ever sends a normal one")

-- A platform still waiting for its pack has no surface: remote targets on
-- it are refused with a code.
local no_entity, no_code, no_why = platforms.entity_at(waiting, own, { x = 0, y = 0 })
check(no_entity == nil and no_code == "NO_HUB" and no_why:match("no surface yet"), "no surface yet: NO_HUB, not a Lua error")
local task = platforms.create_action.make_task({ name = "alpha" })
platforms.create_action.runner.start(task)
local step = platforms.create_action.runner.tick(task)
check(step.status == "failed" and step.outcome.code == "NAME_TAKEN", "the plan step fails with the code")

-- Events: handlers append to a ring of 32; event_state shows the last 4.
local silo = entity({ name = "rocket-silo", type = "rocket-silo", position = { x = 10.5, y = 20.5 } })
local station = { surface = mock.surface({ platform = alpha }) }
local rocket = entity({ name = "rocket-silo-rocket", type = "rocket-silo-rocket", position = { x = 10.5, y = 20.5 },
  attached_cargo_pod = entity({ name = "cargo-pod", type = "cargo-pod", position = { x = 0, y = 0 },
    cargo_pod_destination = { type = 3, station = station } }) })
platforms.on_rocket_launch_ordered({ rocket = rocket, rocket_silo = silo, tick = 100 })
local event = storage.space.events[1]
check(event.kind == "rocket_launch_ordered" and event.silo.x == 10.5 and event.platform.name == "alpha" and event.tick == 100,
  "an ordered launch names its silo and destination platform, read while the pod is still attached")
check(storage.milestones.rocket_launch_ordered_tick == 100 and storage.milestones.rocket_launched_tick == nil,
  "the first ordered launch is a milestone; the rocket has not left yet")
game.tick = 190
-- The starter pack's landing is no trip's end: no arrived milestone (the
-- trip tests above already ended one).
storage.milestones.arrived_tick = nil
platforms.on_platform_state_changed({ platform = alpha, old_state = defines.space_platform_state.starter_pack_on_the_way })
check(storage.milestones.arrived_tick == nil and storage.space.events[3].kind == "platform_arrived",
  "a platform that got its starter pack is waiting at a station, but no trip arrived")
table.remove(storage.space.events, 3); table.remove(storage.space.events, 2)
game.tick = 200
platforms.on_platform_state_changed({ platform = alpha, old_state = defines.space_platform_state.on_the_path })
check(storage.milestones.arrived_tick == 200, "the first trip's arrival is a milestone")
platforms.milestone("boarded_tick")
game.tick = 201
platforms.milestone("boarded_tick")
check(storage.milestones.boarded_tick == 200, "a milestone keeps its first tick")
game.tick = 200
event = storage.space.events[2]
check(event.kind == "platform_state_changed" and event.old == "on_the_path" and event.new == "waiting_at_station",
  "a platform state change names old and new")
event = storage.space.events[3]
check(event.kind == "platform_arrived" and event.platform.name == "alpha" and event.location == "nauvis"
  and storage.travel.arrivals[1].location == "nauvis" and storage.travel.arrivals[1].tick == 200,
  "waiting at a station is also platform_arrived, and the arrival a waiting travel step reads")
local pad_surface = mock.surface({ name = "nauvis", platform = nil })
platforms.on_cargo_pod_finished_descending({ cargo_pod = entity({ name = "cargo-pod", type = "cargo-pod",
  position = { x = 0, y = 0 }, surface = pad_surface }) })
check(storage.space.events[4].kind == "cargo_delivered" and storage.space.events[4].surface == "nauvis",
  "a pod landing on a planet names the planet")
local enemy = mock.force({ name = "enemy" })
platforms.on_rocket_launch_ordered({ rocket = rocket, rocket_silo = entity({ name = "rocket-silo", type = "rocket-silo",
  position = { x = 0, y = 0 } }) })
local foreign = entity({ name = "rocket-silo", type = "rocket-silo", position = { x = 0, y = 0 } })
mock.read(foreign, "force", function() return enemy end)
local before = #storage.space.events
platforms.on_rocket_launch_ordered({ rocket = rocket, rocket_silo = foreign })
check(#storage.space.events == before, "another force's launch is not recorded")
-- The rocket leaves after its ascent: rocket_launched, the first a milestone.
game.tick = 250
platforms.on_rocket_launched({ rocket = rocket, rocket_silo = silo, tick = 250 })
event = storage.space.events[#storage.space.events]
check(event.kind == "rocket_launched" and event.tick == 250 and event.silo.x == 10.5
  and storage.milestones.rocket_launched_tick == 250, "a launched rocket is recorded with its tick and is a milestone")
game.tick = 260
platforms.on_rocket_launched({ rocket = rocket, tick = 260 })
event = storage.space.events[#storage.space.events]
check(event.kind == "rocket_launched" and event.tick == 260 and event.silo == nil
  and storage.milestones.rocket_launched_tick == 250,
  "a rocket whose silo is gone is recorded by the rocket's force; the milestone keeps the first tick")
before = #storage.space.events
platforms.on_rocket_launched({ rocket = rocket, rocket_silo = foreign, tick = 270 })
check(#storage.space.events == before, "another force's rocket is not recorded")
for i = 1, 40 do game.tick = 300 + i; platforms.on_rocket_ready(silo) end
check(storage.milestones.rocket_ready_tick == 301, "the first ready rocket is a milestone")
local last_tick, recent = platforms.event_state()
check(#storage.space.events == 32 and last_tick == 340 and #recent == 4 and recent[4].tick == 340
  and recent[1].kind == "rocket_ready", "the ring keeps 32 entries; event_state returns the newest tick and the last 4")
platforms.on_rocket_launch_ordered({})
check(#storage.space.events == 32, "a malformed event is ignored, never an error")

-- Surface references: one resolver for planets and platforms.
local nauvis_surface = mock.surface({ valid = true, index = 1, name = "nauvis" })
game.planets = { nauvis = mock.planet({ name = "nauvis", surface = nauvis_surface }), vulcanus = mock.planet({ name = "vulcanus" }),
  gleba = mock.planet({ name = "gleba" }) }
local ref, code, _, named = platforms.canonical_ref(own, { platform = "alpha" })
check(ref == "platform:1" and named == alpha and platforms.canonical_ref(own, "platform:1") == "platform:1"
  and platforms.canonical_ref(own, "vulcanus") == "vulcanus", "a planet name, platform:<index> or {platform} is canonical")
_, code = platforms.canonical_ref(own, "mars")
local _, twin_code = platforms.canonical_ref(own, { platform = "twin" })
local _, gone_code = platforms.canonical_ref(own, "platform:5")
check(code == "SURFACE_UNKNOWN" and twin_code == "AMBIGUOUS_PLATFORM" and gone_code == "UNKNOWN_PLATFORM",
  "unknown, ambiguous and deleted references have their codes")
local surface, resolved = platforms.resolve_surface(own, "nauvis")
local _, not_created = platforms.resolve_surface(own, "vulcanus")
local _, no_hub = platforms.resolve_surface(own, { platform = "beta" })
check(surface == nauvis_surface and resolved == "nauvis" and not_created == "SURFACE_NOT_CREATED" and no_hub == "NO_HUB"
  and platforms.resolve_surface(own, { platform = 1 }) == platform_surface,
  "a planet nobody reached is SURFACE_NOT_CREATED; a platform without its pack is NO_HUB")

-- Unlocked locations: the method documents no return value, so only a
-- boolean answer is taken; else researched unlock technologies decide, and
-- a location no technology unlocks (home) when its surface exists.
_G.prototypes.technology = { ["planet-discovery-vulcanus"] = { effects = { { type = "unlock-space-location", space_location = "vulcanus" } } },
  ["planet-discovery-gleba"] = { effects = { { type = "unlock-space-location", space_location = "gleba" } } } }
local discovered = { ["planet-discovery-vulcanus"] = { researched = true }, ["planet-discovery-gleba"] = { researched = false } }
own.technologies = discovered
own.is_space_location_unlocked = function() end
check(platforms.location_unlocked(own, "vulcanus") and not platforms.location_unlocked(own, "gleba")
  and platforms.location_unlocked(own, "nauvis"), "without an answer, researched discoveries and the home planet are unlocked")
own.is_space_location_unlocked = function(name) return name == "gleba" end
check(platforms.location_unlocked(own, "gleba") and not platforms.location_unlocked(own, "vulcanus"),
  "a boolean answer from the game decides")
own.is_space_location_unlocked = function(name) return name ~= "gleba" end

-- set_platform_route: through the platform's schedule object only.
_G.prototypes.space_location = { nauvis = {}, vulcanus = {}, gleba = {} }
local sched_records, sched_calls, rejects = {}, {}, {}
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end
local schedule = { current = 1 }
schedule.get_records = function() return copy(sched_records) end
schedule.clear_records = function() sched_calls[#sched_calls + 1] = "clear"; sched_records = {} end
schedule.set_records = function(records) sched_calls[#sched_calls + 1] = "set"; sched_records = copy(records) end
schedule.go_to_station = function(i) sched_calls[#sched_calls + 1] = "go_to"; schedule.current = i end
schedule.add_record = function(data)
  sched_calls[#sched_calls + 1] = "add"
  local waits = {}
  -- The game keeps conditions it takes, compare_type always read back.
  for _, w in ipairs(rejects[data.station] and {} or data.wait_conditions or {}) do
    local kept = copy(w)
    kept.compare_type = kept.compare_type or "and"
    -- As 2.0.77 reads a condition back: an item signal's type is nil, the
    -- comparator and a pair's quality are filled in, a missing constant is 0.
    local condition = kept.condition
    if condition then
      for _, key in ipairs({ "first_signal", "second_signal" }) do
        local signal = condition[key]
        if signal and signal.type == "item" then signal.type = nil end
      end
      if condition.first_signal then
        condition.comparator = condition.comparator or "<"
        condition.constant = condition.constant or 0
      end
      if condition.name then condition.quality = condition.quality or "normal" end
    end
    waits[#waits + 1] = kept
  end
  sched_records[#sched_records + 1] = { station = data.station, wait_conditions = waits, allows_unloading = data.allows_unloading }
  return #sched_records
end
local rho = platform({ index = 6, name = "rho", state = defines.space_platform_state.waiting_at_station, space_location = nauvis,
  hub = hub, surface = platform_surface, paused = false, get_schedule = function() return schedule end })
own.platforms[6] = rho
local function bad(params, pattern)
  local ok_bad, why = pcall(platforms.set_platform_route, params)
  return not ok_bad and tostring(why):match(pattern) ~= nil and #sched_calls == 0
end
check(bad({ platform = "rho" }, "needs stops, go_to or paused")
  and bad({ platform = "rho", stops = {} }, "1%-10 stops")
  and bad({ platform = "rho", stops = { { location = "mars" } } }, "^UNKNOWN_LOCATION")
  and bad({ platform = "rho", stops = { { location = "nauvis", wait = { { type = "forever" } } } } }, "WaitConditionType")
  and bad({ platform = "rho", stops = { { location = "nauvis", wait = { { type = "time", seconds = 5 } } } } }, "no field seconds")
  and bad({ platform = "rho", stops = { { location = "nauvis", wait = { { type = "time", compare_type = "xor" } } } } }, "compare_type")
  and bad({ platform = "rho", stops = { { location = "nauvis" } }, go_to = 2 }, "go_to")
  and bad({ platform = "rho", paused = "yes" }, "paused"), "a bad route is refused before anything is written")
check(bad({ platform = "rho", stops = { { location = "gleba" } } }, "^LOCATION_LOCKED"), "a locked location is refused")
local route = { platform = "rho", go_to = 2, paused = false, stops = {
  { location = "nauvis", wait = { { type = "time", ticks = 600 } } },
  { location = "vulcanus", unloading = false, wait = { { type = "all_requests_satisfied" }, { type = "time", ticks = 300, compare_type = "or" } } } } }
local set = platforms.set_platform_route(route)
check(table.concat(sched_calls, ",") == "clear,add,add,go_to" and set.code == "ROUTE_SET" and set.schedule.current == 2
  and #set.schedule.records == 2 and set.schedule.records[2].station == "vulcanus" and set.schedule.records[2].allows_unloading == false
  and set.schedule.records[2].wait_conditions[2].compare_type == "or" and table.concat(set.changed, ",") == "stops,go_to"
  and rho.schedule == nil, "the stops replace the records through the schedule object, read back; go_to heads for stop 2")
sched_calls = {}
local again = platforms.set_platform_route(route)
check(#sched_calls == 0 and #again.changed == 0, "the same route again changes nothing")
local paused = platforms.set_platform_route({ platform = "rho", paused = true })
check(rho.paused == true and table.concat(paused.changed, ",") == "paused" and #sched_calls == 0, "paused holds the platform")
rejects.vulcanus = true
local ok_rejected, rejected = pcall(platforms.set_platform_route, { platform = "rho", stops = { { location = "vulcanus",
  wait = { { type = "time", ticks = 60 } } } } })
check(not ok_rejected and tostring(rejected):match("^ROUTE_REJECTED") and #sched_records == 2
  and sched_records[1].station == "nauvis" and sched_calls[#sched_calls] == "set",
  "stops the game does not keep as given put the old route back")
rejects.vulcanus = nil
sched_calls = {}
local counted = platforms.set_platform_route({ platform = "rho", stops = { { location = "vulcanus", wait = {
  { type = "item_count", condition = { first_signal = { type = "item", name = "iron-plate" }, comparator = ">=", constant = 100 } },
  { type = "fluid_count", condition = { first_signal = { type = "fluid", name = "water" } } },
  { type = "request_satisfied", condition = { name = "iron-plate" } } } } } })
check(counted.code == "ROUTE_SET" and table.concat(sched_calls, ",") == "clear,add",
  "conditions the game reads back with its defaults filled in (item signal type, comparator, quality) are kept")
sched_calls = {}
local again_counted = platforms.set_platform_route({ platform = "rho", stops = { { location = "vulcanus", wait = {
  { type = "item_count", condition = { first_signal = { type = "item", name = "iron-plate" }, comparator = ">=", constant = 100 } },
  { type = "fluid_count", condition = { first_signal = { type = "fluid", name = "water" } } },
  { type = "request_satisfied", condition = { name = "iron-plate" } } } } } })
check(#sched_calls == 0 and #again_counted.changed == 0, "the same conditions again change nothing")
platforms.set_platform_route(route)
sched_calls = {}
check(bad({ platform = "rho", go_to = 5 }, "^NO_SUCH_STOP"), "go_to alone must name an existing stop")
local route_task = platforms.route_action.make_task({ platform = "rho", paused = false })
platforms.route_action.runner.start(route_task)
local route_step = platforms.route_action.runner.tick(route_task)
check(platforms.route_action.remote({}) and route_step.status == "done" and route_step.outcome.code == "ROUTE_SET"
  and rho.paused == false, "the plan step is remote and done in one tick")

-- The platform lines show where it heads: travel, schedule and pause.
mock.read(rho, "space_connection", function() return { from = { name = "nauvis" }, to = { name = "vulcanus" }, length = 15000 } end)
mock.read(rho, "distance", function() return 0.25 end)
local row = platforms.compact_row(rho)
check(row.travel.from == "nauvis" and row.travel.to == "vulcanus" and row.travel.distance_fraction == 0.25
  and row.travel.length_km == 15000 and row.paused == false and row.schedule.current == 2
  and row.schedule.records[2].station == "vulcanus" and row.schedule.records[2].waits == 2,
  "a platform line names its connection, how far along, its schedule and pause")

-- create_platform over a named planet.
local over = platforms.create_platform({ name = "omega", planet = "vulcanus" })
local ok_unknown, unknown = pcall(platforms.create_platform, { name = "psi", planet = "mars" })
local ok_planet_locked, planet_locked = pcall(platforms.create_platform, { name = "chi", planet = "gleba" })
check(over.platform.planet == "vulcanus" and created_calls[#created_calls].planet == "vulcanus"
  and not ok_unknown and tostring(unknown):match("^UNKNOWN_PLANET")
  and not ok_planet_locked and tostring(planet_locked):match("^LOCATION_LOCKED"),
  "create_platform makes a platform over a named unlocked planet")

mock.assert_clean()
print(failures == 0 and "\nALL PLATFORM TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
