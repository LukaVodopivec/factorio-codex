-- Offline tests for build_layout / build_block: every block expands to a
-- collision-free, connected layout in every rotation; sites are found on a
-- resource patch and at a shore; check_only has no side effects; a build
-- places recipients first and reports {anchor, placed, failed}.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

_G.storage = {}
_G.game = { tick = 100 }
_G.defines = { build_check_type = { manual = 1, ghost_revive = 2 }, inventory = { chest = 1 } }

-- Factorio 2.0.77 base geometry for the block entities.
local function box(w, h) return { left_top = { x = -w / 2, y = -h / 2 }, right_bottom = { x = w / 2, y = h / 2 } } end
local function entity(name, type, w, h, extra)
  local proto = { name = name, type = type, tile_width = w, tile_height = h, collision_box = box(w - 0.3, h - 0.3) }
  for k, v in pairs(extra or {}) do proto[k] = v end
  return proto
end
local pole_reach = function() return 7.5 end
local entities = {
  ["burner-mining-drill"] = entity("burner-mining-drill", "mining-drill", 2, 2,
    { mining_drill_radius = 0.99, vector_to_place_result = { -0.5, -1.3 }, resource_categories = { ["basic-solid"] = true },
      burner_prototype = { fuel_categories = { chemical = true } }, items_to_place_this = { { name = "burner-mining-drill", count = 1 } } }),
  ["electric-mining-drill"] = entity("electric-mining-drill", "mining-drill", 3, 3,
    { mining_drill_radius = 2.49, vector_to_place_result = { 0, -1.85 }, electric = true,
      resource_categories = { ["basic-solid"] = true }, items_to_place_this = { { name = "electric-mining-drill", count = 1 } } }),
  ["stone-furnace"] = entity("stone-furnace", "furnace", 2, 2),
  ["steel-furnace"] = entity("steel-furnace", "furnace", 2, 2),
  ["electric-furnace"] = entity("electric-furnace", "furnace", 3, 3, { electric = true }),
  ["burner-inserter"] = entity("burner-inserter", "inserter", 1, 1, { pickup = { 0, -1 }, drop = { 0, 1.2 } }),
  ["inserter"] = entity("inserter", "inserter", 1, 1, { pickup = { 0, -1 }, drop = { 0, 1.2 }, electric = true }),
  ["transport-belt"] = entity("transport-belt", "transport-belt", 1, 1),
  ["wooden-chest"] = entity("wooden-chest", "container", 1, 1),
  ["iron-chest"] = entity("iron-chest", "container", 1, 1),
  ["assembling-machine-1"] = entity("assembling-machine-1", "assembling-machine", 3, 3, { electric = true }),
  ["assembling-machine-2"] = entity("assembling-machine-2", "assembling-machine", 3, 3, { electric = true }),
  ["lab"] = entity("lab", "lab", 3, 3, { electric = true }),
  ["small-electric-pole"] = entity("small-electric-pole", "electric-pole", 1, 1,
    { get_max_wire_distance = pole_reach, supply = 2.5 }),
  ["offshore-pump"] = entity("offshore-pump", "offshore-pump", 1, 1),
  ["boiler"] = entity("boiler", "boiler", 3, 2),
  ["steam-engine"] = entity("steam-engine", "generator", 3, 5, { electric = true }),
  ["pipe"] = entity("pipe", "pipe", 1, 1),
}
local items = {}
for name, proto in pairs(entities) do items[name] = { name = name, place_result = proto, stack_size = 50 } end
items["iron-plate"] = { name = "iron-plate", stack_size = 100 }
_G.prototypes = { item = items, entity = { ["iron-ore"] = { name = "iron-ore", type = "resource", resource_category = "basic-solid" } },
  tile = { water = { collision_mask = { layers = { water_tile = true } }, fluid = { name = "water" } },
    grass = { collision_mask = { layers = { ground_tile = true } } } },
  -- Nauvis's map generation places water (power blocks need it).
  space_location = { nauvis = { name = "nauvis", map_gen_settings = { autoplace_settings = { tile = { settings = { water = {} } } } } } },
  space_connection = {} }
for name, proto in pairs(entities) do prototypes.entity[name] = proto end
function prototypes.get_entity_filtered(filters)
  local wanted = {}
  for _, kind in ipairs(type(filters[1].type) == "table" and filters[1].type or { filters[1].type }) do wanted[kind] = true end
  local found = {}
  for name, proto in pairs(prototypes.entity) do if wanted[proto.type] then found[name] = proto end end
  return mock.custom_table(found)
end

-- The world: a resource patch, a lake west of x = 0, and a body far away.
local created, crafted = {}, 0
local reverse_underground = false
local inventory = {}
-- Power comes from the event-maintained registry (registry.lua), never an
-- entity query: a steam engine is registered or not.
storage.registry = { entries = {}, machines = {}, electric = {}, holders = {}, burners = {}, poles = {},
  belts = {}, belt_count = 0, ready = true, order = {}, networks = {}, stock = {}, types = {} }
local function set_powered(on)
  local r = storage.registry
  if on then
    r.entries[900] = { entity = { valid = true }, unit = 900, name = "steam-engine", type = "generator",
      position = { x = 0, y = 0 } }
    r.machines.generator, r.electric[900] = { [900] = true }, true
  else
    r.entries[900], r.machines.generator, r.electric[900] = nil, nil, nil
  end
end
local resources = {}
for x = 40, 79 do for y = 40, 59 do resources[#resources + 1] = { valid = true, name = "iron-ore", type = "resource",
  position = { x = x + 0.5, y = y + 0.5 } } end end
local water = {}
for x = -20, -1 do for y = -20, 20 do water[#water + 1] = { position = { x = x, y = y } } end end
local function is_water(x, y) return x < 0 and x >= -20 and y >= -20 and y <= 20 end
local blockers = {}
local permissive = false -- the expansion tests check geometry only
local character
local crowded = false     -- a built-up base: every land tile holds a wall
local engine = { can_place = 0, find = 0 }
local surface = {
  index = 1, name = "nauvis", planet = { name = "nauvis" },
  can_place_entity = function(args)
    engine.can_place = engine.can_place + 1
    if permissive then return true end
    if crowded then return false end
    local proto = entities[args.name]
    local area = require("scripts.placement_geometry").footprint(proto, args.position, args.direction)
    local land = true
    for y = math.floor(area.left_top.y), math.ceil(area.right_bottom.y) - 1 do
      for x = math.floor(area.left_top.x), math.ceil(area.right_bottom.x) - 1 do
        if is_water(x, y) then land = false end
      end
    end
    if proto.type == "offshore-pump" then
      -- Land under the pump, water on the side it takes water from.
      local back = ({ [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } })[args.direction]
      local x, y = math.floor(args.position.x), math.floor(args.position.y)
      return land and is_water(x + back[1], y + back[2])
    end
    if not land then return false end
    if proto.type == "mining-drill" then
      local r = proto.mining_drill_radius
      for _, e in ipairs(resources) do
        if math.abs(e.position.x - args.position.x) < r and math.abs(e.position.y - args.position.y) < r then return true end
      end
      return false
    end
    for _, b in ipairs(blockers) do
      if b.position.x > area.left_top.x and b.position.x < area.right_bottom.x
        and b.position.y > area.left_top.y and b.position.y < area.right_bottom.y then return false end
    end
    return true
  end,
  find_entities_filtered = function(filter)
    engine.find = engine.find + 1
    if crowded and filter.area then
      return { { valid = true, name = "stone-wall", type = "wall", position = filter.area.left_top } }
    end
    if filter.type == "resource" then
      -- The site search reads its window in strips of rows.
      assert(filter.area and filter.area.right_bottom.y - filter.area.left_top.y <= 8, "a resource window is read in strips")
      engine.resource_reads = (engine.resource_reads or 0) + 1
      local out = {}
      for _, e in ipairs(resources) do
        local p = e.position
        if p.x >= filter.area.left_top.x and p.x < filter.area.right_bottom.x
          and p.y >= filter.area.left_top.y and p.y < filter.area.right_bottom.y then out[#out + 1] = e end
      end
      return out
    end
    assert(filter.area or filter.position, "no entity query may search the whole surface")
    if filter.area then
      local out = {}
      for _, b in ipairs(blockers) do
        if b.position.x > filter.area.left_top.x and b.position.x < filter.area.right_bottom.x
          and b.position.y > filter.area.left_top.y and b.position.y < filter.area.right_bottom.y then out[#out + 1] = b end
      end
      return out
    end
    return {}
  end,
  find_tiles_filtered = function(filter)
    assert(filter.area and filter.area.right_bottom.y - filter.area.left_top.y <= 8, "a water window is read in strips")
    local out = {}
    for _, t in ipairs(water) do
      local p = t.position
      if p.x >= filter.area.left_top.x and p.x < filter.area.right_bottom.x
        and p.y >= filter.area.left_top.y and p.y < filter.area.right_bottom.y then out[#out + 1] = t end
    end
    return out
  end,
  create_entity = function(args)
    created[#created + 1] = args
    local e = { valid = true, name = args.name, type = entities[args.name].type, position = args.position,
      direction = args.direction, inserted = {} }
    if e.type == "underground-belt" then
      e.belt_to_ground_type = args.type or "input"
      if reverse_underground then e.direction, e.belt_to_ground_type = 8, "input" end
    end
    e.insert = function(stack) e.inserted[stack.name] = (e.inserted[stack.name] or 0) + stack.count; return stack.count end
    args.entity = e
    return e
  end,
}
local recipes = {}
for name in pairs(items) do recipes[name] = { name = name, enabled = true,
  products = { { type = "item", name = name, amount = 1 } }, ingredients = {} } end
recipes["iron-gear-wheel"] = { name = "iron-gear-wheel", enabled = true }
recipes["locked-thing"] = { name = "locked-thing", enabled = false }
character = {
  valid = true, name = "character", position = { x = 500.5, y = 500.5 },
  bounding_box = { left_top = { x = 500.3, y = 500.3 }, right_bottom = { x = 500.7, y = 500.7 } },
  force = { recipes = recipes, is_chunk_charted = function() return true end },
  surface = surface, build_distance = 10, crafting_queue_size = 0,
  get_item_count = function(name) return inventory[type(name) == "table" and name.name or name] or 0 end,
  get_main_inventory = function() return { get_insertable_count = function() return 1000 end } end,
  remove_item = function(args) inventory[args.name] = (inventory[args.name] or 0) - args.count; return args.count end,
  begin_crafting = function() crafted = crafted + 1; return 0 end,
  can_reach_entity = function() return true end,
}
package.loaded["scripts.companion"] = { require_companion = function() return character end, get = function() return character end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return character end)
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end, ensure_entity = function() return "ok" end }
package.loaded["scripts.factory_activity"] = { record = function() end }

local geometry = require("scripts.placement_geometry")
local layout = require("scripts.actions.build_layout")
local blocks = require("scripts.blocks")
local jobs = require("scripts.jobs")
-- The RPC dry runs are jobs; these run one to its end, a tick's budget at a time.
local function check_layout(params) return jobs.run_now(layout.layout_check_job, params) end
local function check_block(params) return jobs.run_now(layout.block_check_job, params) end

-- ---------------------------------------------------------------- helpers

local function turn(v, direction)
  local x, y = v[1], v[2]
  for _ = 1, direction / 4 do x, y = -y, x end
  return { x = x, y = y }
end
local function inside(area, p)
  return p.x > area.left_top.x and p.x < area.right_bottom.x and p.y > area.left_top.y and p.y < area.right_bottom.y
end
local function placements_of(result)
  local out = {}
  for _, p in ipairs(result.placements) do
    out[#out + 1] = { proto = p.entity.proto, position = p.position, direction = p.entity.direction, area = p.area }
  end
  return out
end
local function at(list, point, exclude)
  for _, p in ipairs(list) do
    if p ~= exclude and inside(geometry.footprint(p.proto, p.position, p.direction), point) then return p end
  end
end
local function no_overlaps(list)
  for i = 1, #list do for j = i + 1, #list do
    if geometry.overlaps(list[i].area, list[j].area) then return false end
  end end
  return true
end
-- Every inserter takes from and drops into layout entities (or one end is
-- open for the bot); every drill drops onto a belt or chest; every
-- electric entity is inside a pole's supply area.
local function connected(list, open_inserter_ends)
  for _, p in ipairs(list) do
    if p.proto.type == "inserter" then
      local pick = turn(p.proto.pickup, p.direction)
      local drop = turn(p.proto.drop, p.direction)
      local from = at(list, { x = p.position.x + pick.x, y = p.position.y + pick.y }, p)
      local to = at(list, { x = p.position.x + drop.x, y = p.position.y + drop.y }, p)
      if not (from and to) and not open_inserter_ends then return false, "inserter at " .. p.position.x .. "," .. p.position.y end
    end
    if p.proto.type == "mining-drill" then
      local v = turn(p.proto.vector_to_place_result, p.direction)
      local to = at(list, { x = p.position.x + v.x, y = p.position.y + v.y }, p)
      if not to or (to.proto.type ~= "transport-belt" and to.proto.type ~= "container") then return false, "drill output" end
    end
    if p.proto.electric then
      local powered = false
      for _, pole in ipairs(list) do
        if pole.proto.type == "electric-pole" then
          local s = pole.proto.supply
          local area = { left_top = { x = pole.position.x - s, y = pole.position.y - s },
            right_bottom = { x = pole.position.x + s, y = pole.position.y + s } }
          if geometry.overlaps(area, p.area) then powered = true end
        end
      end
      if not powered then return false, p.proto.name .. " unpowered" end
    end
  end
  return true
end

local function block_variants(params)
  local request = layout._block_request(character, params)
  local results = {}
  for q = 1, 4 do
    local one = { anchor = { x = 1000, y = 1000 }, layouts = { request.layouts[q] } }
    results[q] = layout._resolve(character, one)
  end
  return results, request
end

-- ------------------------------------------------------------------ blocks

permissive = true
local cases = {
  { block = "mining", count = 1, resource = "iron-ore" },
  { block = "mining", count = 5, resource = "iron-ore" },
  { block = "smelting", count = 4 },
  { block = "assembly", count = 3, recipe = "iron-gear-wheel" },
  { block = "labs", count = 3 },
  { block = "power", count = 3 },
}
for _, powered in ipairs({ false, true }) do
  set_powered(powered)
  for _, case in ipairs(cases) do
    local label = string.format("%s x%d (%s)", case.block, case.count, powered and "electric" or "burner")
    local results = block_variants(case)
    for q, result in ipairs(results) do
      local list = placements_of(result)
      local ok, why = connected(list)
      check(#result.failed == 0 and no_overlaps(list) and ok,
        string.format("block %s rotation %d expands to a collision-free connected layout%s", label, q - 1,
          #result.failed > 0 and (": " .. result.failed[1].reason) or why and (": " .. why) or ""))
    end
  end
end

set_powered(false)
permissive = false
local burner_mining = layout._block_request(character, { block = "mining", count = 4, resource = "iron-ore" })
check(burner_mining.tiers.drill == "burner-mining-drill" and burner_mining.tiers.output == "transport-belt",
  "mining picks burner drills without power and a belt for three or more drills")
set_powered(true)
local electric_mining = layout._block_request(character, { block = "mining", count = 2, resource = "iron-ore" })
check(electric_mining.tiers.drill == "electric-mining-drill" and electric_mining.tiers.output == "iron-chest",
  "mining picks electric drills once the force generates power, and chests for one or two drills")
recipes["electric-mining-drill"].enabled = false
local fallback = layout._block_request(character, { block = "mining", count = 1, resource = "iron-ore" })
check(fallback.tiers.drill == "burner-mining-drill", "a tier the force cannot craft and the body lacks is skipped")
inventory["electric-mining-drill"] = 1
check(layout._block_request(character, { block = "mining", count = 1, resource = "iron-ore" }).tiers.drill == "electric-mining-drill",
  "a tier the body already carries is used")
inventory["electric-mining-drill"] = nil
recipes["electric-mining-drill"].enabled = true
set_powered(false)

local power = layout._block_request(character, { block = "power", count = 2 })
local engines, boilers, pumps = 0, 0, 0
for _, e in ipairs(power.layouts[1].entities) do
  if e.name == "steam-engine" then engines = engines + 1 end
  if e.name == "boiler" then boilers = boilers + 1 end
  if e.name == "offshore-pump" then pumps = pumps + 1 end
end
check(pumps == 1 and boilers == 2 and engines == 4, "power keeps one pump and two steam engines per boiler")
local pump, first_boiler
for _, e in ipairs(power.layouts[1].entities) do
  if e.name == "offshore-pump" then pump = e end
  if e.name == "boiler" and not first_boiler then first_boiler = e end
end
-- Pump facing 0 outputs south (0, 1); boiler facing 0 has its west water port at (-1, 0.5).
local out = turn({ 0, 1 }, pump.direction)
check(pump.dx + out.x == first_boiler.dx - 1 and pump.dy + out.y == first_boiler.dy + 0.5,
  "the offshore pump outputs straight into the first boiler's water port")

local bad = pcall(blocks.validate, { block = "rocket", count = 1 })
local too_many = pcall(blocks.validate, { block = "power", count = 99 })
local no_resource = pcall(blocks.validate, { block = "mining", count = 2 })
check(not bad and not too_many and not no_resource, "build_block validation rejects unknown blocks, oversized counts, mining without resource")

-- ------------------------------------------------------------- site search

local mined = check_block({ block = "mining", count = 4, resource = "iron-ore", near = { x = 30, y = 50 }, check_only = true })
local on_patch = mined.ok
for _, row in ipairs(mined.placed) do
  if row.name == "burner-mining-drill" and not (row.x > 40 and row.x < 80 and row.y > 40 and row.y < 60) then on_patch = false end
end
check(on_patch and #mined.failed == 0, "a mining block finds a site with every drill on the resource patch")
-- The resource window is a phase of the search: starting one reads nothing,
-- and the window is read a strip of rows per query.
engine.resource_reads = 0
local window = layout.block_check_job.start({ block = "mining", count = 4, resource = "iron-ore", near = { x = 60, y = 50 },
  check_only = true })
check(engine.resource_reads == 0, "starting a site search reads no resource: the window is read in the search's ticks")
local window_result, window_slices = nil, 0
repeat
  window_slices = window_slices + 1
  window_result = layout.block_check_job.step(window, { left = jobs.WORK_PER_TICK })
until window_result or window_slices > 200
check(window_result and window_result.ok and engine.resource_reads == 8,
  "a 64-row resource window is read in 8 strips (" .. engine.resource_reads .. " reads) and the site is found")
local nowhere = check_block({ block = "mining", count = 2, resource = "iron-ore", near = { x = -300, y = -300 }, check_only = true })
check(not nowhere.ok and nowhere.failed[1].code == "SITE_NOT_FOUND", "no resource near the site is SITE_NOT_FOUND")

local shore = check_block({ block = "power", count = 2, near = { x = 5, y = 3 }, check_only = true })
local pump_row
for _, row in ipairs(shore.placed) do if row.name == "offshore-pump" then pump_row = row end end
check(shore.ok and pump_row and not is_water(math.floor(pump_row.x), math.floor(pump_row.y))
  and is_water(math.floor(pump_row.x) - 1, math.floor(pump_row.y)),
  "a power block turns to fit the shore: pump on land with water behind it")
local landlocked = check_block({ block = "power", count = 1, near = { x = 300, y = 300 }, check_only = true })
check(not landlocked.ok and landlocked.failed[1].code == "SITE_NOT_FOUND", "no water near the site is SITE_NOT_FOUND")

local smelt = check_block({ block = "smelting", count = 2, near = { x = 10.5, y = 10.5 }, check_only = true })
local nearest = math.huge
for _, row in ipairs(smelt.placed) do nearest = math.min(nearest, (row.x - 10.5) ^ 2 + (row.y - 10.5) ^ 2) end
check(smelt.ok and nearest < 25, "a smelting block is sited around near")

-- ----------------------------------------------------------- layout checks

local function dry(params)
  params.check_only = true
  return check_layout(params)
end
local overlap = dry({ anchor = { x = 10, y = 10 }, entities = {
  { name = "stone-furnace", dx = 1, dy = 1 }, { name = "wooden-chest", dx = 1.5, dy = 1.5 } } })
check(not overlap.ok and overlap.failed[1].code == "LAYOUT_OVERLAP" and overlap.failed[1].index == 1,
  "overlapping layout entities are LAYOUT_OVERLAP with a 0-based index")
local unknown = dry({ anchor = { x = 10, y = 10 }, entities = { { name = "warp-drive", dx = 0, dy = 0 } } })
check(not unknown.ok and unknown.failed[1].code == "UNKNOWN_ENTITY", "an unknown entity is UNKNOWN_ENTITY")
local locked = dry({ anchor = { x = 10, y = 10 }, entities = {
  { name = "assembling-machine-1", dx = 1.5, dy = 1.5, recipe = "locked-thing" },
  { name = "stone-furnace", dx = 5, dy = 1, recipe = "iron-gear-wheel" } } })
check(not locked.ok and locked.failed[1].code == "RECIPE_LOCKED" and locked.failed[2].code == "RECIPE_NOT_SETTABLE",
  "locked recipes and recipes on furnaces are named before anything is built")
-- Settings and mirror: checked by prototype before anything is built, then
-- carried to each placement with the underground end.
local misfit = dry({ anchor = { x = 10, y = 10 }, entities = {
  { name = "stone-furnace", dx = 1, dy = 1, settings = { inserter = { stack_size = 1 } } },
  { name = "inserter", dx = 3.5, dy = 0.5, settings = { inserter = { stack_size = 1 } } } } })
check(not misfit.ok and #misfit.failed == 1 and misfit.failed[1].code == "CONFIG_NOT_APPLICABLE" and misfit.failed[1].index == 0,
  "settings an entity cannot take are CONFIG_NOT_APPLICABLE before anything is built")
local bad_settings = pcall(layout.layout_action.validate, { anchor = { x = 0, y = 0 },
  entities = { { name = "inserter", dx = 0, dy = 0, settings = { inserter = { filters = { "nope" } } } } } }, 1)
local bad_mirror = pcall(layout.layout_action.validate, { anchor = { x = 0, y = 0 },
  entities = { { name = "pipe", dx = 0, dy = 0, mirror = "yes" } } }, 1)
check(not bad_settings and not bad_mirror, "queue_plan validation checks entity settings and mirror")
local turned_layout = layout._rotated({ entities = { { name = "assembling-machine-1", dx = 1, dy = 0, mirror = true,
  settings = { inserter = { stack_size = 2 } }, belt_to_ground_type = "output" } } }, 1)
local turned_entity = turned_layout.entities[1]
check(turned_entity.mirror == true and turned_entity.settings.inserter.stack_size == 2 and turned_entity.belt_to_ground_type == "output"
  and turned_entity.direction == 4, "a turned layout keeps mirror, settings and the underground end")
local carried_steps = layout._plan_steps({ routes = {}, placements = { { position = { x = 1.5, y = 1.5 },
  entity = { index = 0, item = "assembling-machine-1", proto = entities["assembling-machine-1"], direction = 0, mirror = true,
    settings = { chest = { slots = 1 } } } } } })
check(carried_steps[1].mirror == true and carried_steps[1].settings.chest.slots == 1,
  "each placement step carries its mirror and settings")
local saved_steps = layout._plan_steps({ routes = {}, placements = { { position = { x = 0.5, y = 0.5 },
  entity = { index = 0, item = "underground-belt", proto = { type = "underground-belt" }, direction = 0,
    settings = { type = "output" } } } } })
check(saved_steps[1].belt_to_ground_type == "output", "a layout search saved by 0.21.1 keeps its underground end")
-- A layout written for 0.21.1 (free-form blueprint settings) is upgraded when
-- validated: its end, mirror and blueprint fields become typed fields.
local old_layout = { anchor = { x = 0, y = 0 }, entities = {
  { name = "iron-chest", dx = 0.5, dy = 0.5, settings = { bar = 5 } },
  { name = "inserter", dx = 1.5, dy = 0.5, settings = { use_filters = true, filter_mode = "blacklist",
    filters = { { index = 2, name = "wooden-chest" }, { index = 1, name = "iron-plate" } } } },
  { name = "burner-inserter", dx = 2.5, dy = 0.5, settings = { mirror = true, type = "output" } },
  { name = "inserter", dx = 3.5, dy = 0.5, settings = { filters = { { index = 1, name = "coal" } } } } } }
local upgraded_ok, upgraded_err = pcall(layout.layout_action.validate, old_layout, 1)
local up = old_layout.entities
check(upgraded_ok and up[1].settings.chest.slots == 4 and up[2].settings.inserter.filters[1] == "iron-plate"
  and up[2].settings.inserter.filters[2] == "wooden-chest" and up[2].settings.inserter.mode == "blacklist"
  and up[3].mirror == true and up[3].belt_to_ground_type == "output" and up[3].settings == nil and up[4].settings == nil,
  "a 0.21.1 layout's blueprint settings are upgraded to typed settings when validated (" .. tostring(upgraded_err) .. ")")
check(not pcall(layout.layout_action.validate, { anchor = { x = 0, y = 0 },
  entities = { { name = "inserter", dx = 0, dy = 0, settings = {} } } }, 1), "empty settings are still refused")
local wet = dry({ anchor = { x = -5, y = 0 }, entities = { { name = "wooden-chest", dx = 0.5, dy = 0.5 } } })
check(not wet.ok and wet.failed[1].code == "BLOCKED", "a placement on water is BLOCKED")
blockers = { { valid = true, name = "tree-01", type = "tree", position = { x = 20.5, y = 20.5 } } }
local trees = dry({ anchor = { x = 20, y = 20 }, entities = { { name = "wooden-chest", dx = 0.5, dy = 0.5 } } })
check(trees.ok and trees.clears == 1, "trees in a footprint pass the check: placing clears them")
blockers = { { valid = true, name = "stone-wall", type = "wall", position = { x = 20.5, y = 20.5 } } }
local walled = dry({ anchor = { x = 20, y = 20 }, entities = { { name = "wooden-chest", dx = 0.5, dy = 0.5 } } })
check(not walled.ok and walled.failed[1].reason:match("blocked by stone%-wall") ~= nil, "an owned blocker is named")
blockers = {}

local routed = dry({ anchor = { x = 100, y = 100 }, entities = {
  { name = "wooden-chest", dx = 0.5, dy = 0.5 }, { name = "stone-furnace", dx = 4, dy = 1 },
  { name = "wooden-chest", dx = 8.5, dy = 0.5 } },
  connections = { { kind = "belt", prototype = "transport-belt", from = { dx = 0.5, dy = 0.5 }, to = { dx = 8.5, dy = 0.5 } },
    { kind = "power", prototype = "small-electric-pole", from = { dx = 0.5, dy = 3.5 }, to = { dx = 20.5, dy = 3.5 } } } })
local belts, poles, around = 0, 0, true
for _, row in ipairs(routed.placed) do
  if row.name == "transport-belt" then
    belts = belts + 1
    if row.x >= 103 and row.x <= 105 and row.y >= 100 and row.y <= 102 then around = false end
    if (row.x == 100.5 or row.x == 108.5) and row.y == 100.5 then around = false end
  end
  if row.name == "small-electric-pole" then poles = poles + 1 end
end
check(routed.ok and belts >= 7 and around, "a belt route between planned endpoints goes around planned footprints, not onto them")
check(poles == 4, "a power route places endpoint poles and spans within wire reach")
local order_ok, seen_pole = true, false
for _, row in ipairs(routed.placed) do
  if row.name == "small-electric-pole" then seen_pole = true elseif seen_pole then order_ok = false end
end
check(order_ok, "poles are placed last")

local bad_layout = pcall(layout.layout_action.validate, { action = "build_layout", entities = {} }, 1)
local both = pcall(layout.layout_action.validate, { anchor = { x = 0, y = 0 }, site = { near = { x = 0, y = 0 } },
  entities = { { name = "pipe", dx = 0, dy = 0 } } }, 1)
check(not bad_layout and not both, "queue_plan validation rejects empty layouts and anchor plus site")
local rpc_build = pcall(check_layout, { anchor = { x = 0, y = 0 }, entities = { { name = "pipe", dx = 0, dy = 0 } } })
check(not rpc_build, "the RPC only dry-runs: without check_only it refuses")

-- ---------------------------------------------------- check_only is read-only

created, crafted = {}, 0
local storage_before = next(storage)
local inventory_before = {}
for k, v in pairs(inventory) do inventory_before[k] = v end
check_block({ block = "smelting", count = 3, near = { x = 10, y = 10 }, check_only = true })
check_block({ block = "power", count = 1, near = { x = 5, y = 3 }, check_only = true })
dry({ anchor = { x = 100, y = 100 }, entities = { { name = "wooden-chest", dx = 0.5, dy = 0.5 } } })
local same = true
for k, v in pairs(inventory) do if inventory_before[k] ~= v then same = false end end
check(#created == 0 and crafted == 0 and next(storage) == storage_before and same,
  "check_only creates nothing, crafts nothing, and touches no storage or inventory")

-- ------------------------------------------------- site search work budget

-- Every tick of a search stays within its work budget (a candidate started
-- may reach twice the tick share; an uncached ground check costs 4 items for
-- at most two can_place_entity calls and one blocker query), the
-- anchor-independent overlap check runs once per rotation, and a dry run
-- takes one tick.
local per_tick_engine = 2 * (2 * layout.WORK_PER_TICK / 4)
local overlap_calls = 0
local real_overlaps = geometry.overlaps
geometry.overlaps = function(a, b) overlap_calls = overlap_calls + 1; return real_overlaps(a, b) end
crowded = true
local big = { block = "assembly", count = 16, recipe = "iron-gear-wheel", near = { x = 10.5, y = 10.5 } }
local entity_count = #layout._block_request(character, big).layouts[1].entities
overlap_calls, engine.can_place, engine.find = 0, 0, 0
local search_task = { id = 30, block = big.block, count = big.count, recipe = big.recipe, near = big.near }
-- tasks.lua runs start and the first tick in one game tick: they share one
-- tick's budget, so the counters are reset only after that first tick.
layout.block_action.runner.start(search_task)
local worst, ticks, outcome = 0, 0, nil
while not outcome and ticks < 100 do
  outcome = layout.block_action.runner.tick(search_task)
  worst, ticks = math.max(worst, engine.can_place), ticks + 1
  engine.can_place = 0
end
check(entity_count > 150 and outcome and outcome.status == "failed" and outcome.outcome.failed[1].code == "SITE_NOT_FOUND",
  "a 16-assembler block in a built-up base fails as SITE_NOT_FOUND")
check(worst <= per_tick_engine and ticks <= layout.MAX_WORK / layout.WORK_PER_TICK + 2,
  string.format("the site search spreads over ticks within its budget (worst tick %d placement checks, %d ticks)", worst, ticks))
check(overlap_calls <= 4 * entity_count * 4,
  string.format("layout overlaps are checked once per rotation, not per candidate (%d footprint comparisons)", overlap_calls))
-- The dry run is a job with the same per-tick budget: it searches as far as
-- the build would and gives the same definite answer.
local dry_job = layout.block_check_job.start({ block = big.block, count = big.count, recipe = big.recipe,
  near = big.near, check_only = true })
local dry_big, dry_ticks, dry_worst = nil, 0, 0
while not dry_big and dry_ticks < 200 do
  engine.can_place = 0
  dry_big = layout.block_check_job.step(dry_job, { left = layout.WORK_PER_TICK })
  dry_ticks, dry_worst = dry_ticks + 1, math.max(dry_worst, engine.can_place)
end
check(dry_big and not dry_big.ok and dry_big.failed[1].code == "SITE_NOT_FOUND"
  and dry_big.failed[1].reason == outcome.outcome.failed[1].reason and dry_worst <= per_tick_engine,
  string.format("a dry run searches over ticks within the same budget and answers like the build (%d ticks, worst %d checks)",
    dry_ticks, dry_worst))
crowded = false
geometry.overlaps = real_overlaps

-- A connection whose goal is walled in by planned entities fails as a route
-- within its own budget, not after the whole area within its length.
engine.can_place = 0
local walled_route = dry({ anchor = { x = 300, y = 300 }, entities = {
  { name = "wooden-chest", dx = 0.5, dy = 0.5 }, { name = "wooden-chest", dx = 20.5, dy = 0.5 },
  { name = "wooden-chest", dx = 19.5, dy = 0.5 }, { name = "wooden-chest", dx = 21.5, dy = 0.5 },
  { name = "wooden-chest", dx = 20.5, dy = -0.5 }, { name = "wooden-chest", dx = 20.5, dy = 1.5 } },
  connections = { { kind = "belt", prototype = "transport-belt", from = { dx = 0.5, dy = 0.5 }, to = { dx = 20.5, dy = 0.5 } } } })
check(not walled_route.ok and walled_route.failed[1].code == "ROUTE_FAILED" and engine.can_place <= per_tick_engine,
  string.format("a walled-in route fails as ROUTE_FAILED within one tick's work (%d placement checks)", engine.can_place))
engine.can_place = 0
-- A route-only layout joins what already stands: no entities, connections from an anchor.
local route_only = dry({ anchor = { x = 600, y = 600 }, entities = {},
  connections = { { kind = "belt", prototype = "transport-belt", from = { dx = 0.5, dy = 0.5 }, to = { dx = 10.5, dy = 0.5 } } } })
local route_belts = 0
for _, row in ipairs(route_only.placed or {}) do if row.name == "transport-belt" then route_belts = route_belts + 1 end end
check(route_only.ok and route_belts >= 10, "a layout of connections only (from an anchor) plans its route (" .. route_belts .. " belts)")
check(not pcall(layout.layout_check_job.start, { site = { near = { x = 0, y = 0 } }, entities = {}, check_only = true,
  connections = { { kind = "belt", prototype = "transport-belt", from = { dx = 0, dy = 0 }, to = { dx = 1, dy = 0 } } } })
  and not pcall(layout.layout_check_job.start, { anchor = { x = 0, y = 0 }, entities = {}, check_only = true }),
  "no entities needs connections and an anchor")
engine.can_place = 0
local long_route = dry({ anchor = { x = 400, y = 400 }, entities = {
  { name = "wooden-chest", dx = 0.5, dy = 0.5 }, { name = "wooden-chest", dx = 25.5, dy = 6.5 } },
  connections = { { kind = "belt", prototype = "transport-belt", from = { dx = 0.5, dy = 0.5 }, to = { dx = 25.5, dy = 6.5 } } } })
local long_belts = 0
for _, row in ipairs(long_route.placed) do if row.name == "transport-belt" then long_belts = long_belts + 1 end end
check(long_route.ok and long_belts == 30 and engine.can_place < 200,
  string.format("an open 31-tile route is found by its shortest path without searching the whole area (%d placement checks)",
    engine.can_place))

-- Connections reach 200 tiles; the search resumes over ticks and hops a
-- planned wall with an underground pair when the belt tier has one.
local far = layout.layout_check_job.start({ check_only = true, anchor = { x = 600, y = 600 }, entities = {
  { name = "wooden-chest", dx = 0.5, dy = 0.5 }, { name = "wooden-chest", dx = 150.5, dy = 0.5 } },
  connections = { { kind = "belt", prototype = "transport-belt", from = { dx = 0.5, dy = 0.5 }, to = { dx = 150.5, dy = 0.5 } } } })
local far_result, far_ticks, far_worst = nil, 0, 0
while not far_result and far_ticks < 500 do
  engine.can_place = 0
  far_result = layout.layout_check_job.step(far, { left = layout.WORK_PER_TICK })
  far_ticks, far_worst = far_ticks + 1, math.max(far_worst, engine.can_place)
end
local far_belts = 0
for _, row in ipairs(far_result and far_result.placed or {}) do if row.name == "transport-belt" then far_belts = far_belts + 1 end end
check(far_result and far_result.ok and far_belts == 149 and far_ticks > 1 and far_worst <= per_tick_engine,
  string.format("a 150-tile layout connection is routed over %d ticks (worst %d placement checks)", far_ticks, far_worst))
items["underground-belt"] = { name = "underground-belt", stack_size = 50,
  place_result = entity("underground-belt", "underground-belt", 1, 1, { max_underground_distance = 5 }) }
entities["underground-belt"] = items["underground-belt"].place_result
entities["transport-belt"].related_underground_belt = entities["underground-belt"]
recipes["underground-belt"] = { name = "underground-belt", enabled = true,
  products = { { type = "item", name = "underground-belt", amount = 2 } }, ingredients = {} }
local wall = { { name = "wooden-chest", dx = 0.5, dy = 0.5 }, { name = "wooden-chest", dx = 20.5, dy = 0.5 } }
for dy = -40, 40 do wall[#wall + 1] = { name = "iron-chest", dx = 10.5, dy = dy + 0.5 } end
local hopped = check_layout({ check_only = true, anchor = { x = 700, y = 700 }, entities = wall,
  connections = { { kind = "belt", prototype = "transport-belt", from = { dx = 0.5, dy = 0.5 }, to = { dx = 20.5, dy = 0.5 } } } })
local unders = 0
for _, row in ipairs(hopped.placed) do if row.name == "underground-belt" then unders = unders + 1 end end
check(hopped.ok and unders == 2, "a layout belt hops a planned wall of chests with one underground pair")
local walled_off = check_layout({ check_only = true, anchor = { x = 800, y = 800 }, entities = wall,
  connections = { { kind = "belt", prototype = "transport-belt", underground = false,
    from = { dx = 0.5, dy = 0.5 }, to = { dx = 20.5, dy = 0.5 } } } })
local detour_belts, detour_unders = 0, 0
for _, row in ipairs(walled_off.placed) do
  if row.name == "transport-belt" then detour_belts = detour_belts + 1 end
  if row.name == "underground-belt" then detour_unders = detour_unders + 1 end
end
check(walled_off.ok and detour_unders == 0 and detour_belts >= 100,
  "underground = false keeps a layout route above ground: it goes round the wall")
entities["transport-belt"].related_underground_belt = nil

-- ------------------------------------------------------------------ build

-- Physical results must read native underground orientation, even when the
-- entity was paid for but failed its requested configuration.
inventory = { ["underground-belt"] = 1 }
reverse_underground = true
local reversed = { id = 6, anchor = { x = 190, y = 200 }, entities = {
  { name = "underground-belt", dx = 0.5, dy = 0.5, direction = 0, belt_to_ground_type = "output" } } }
layout.layout_action.runner.start(reversed)
local reversed_result
for _ = 1, 20 do
  reversed_result = layout.layout_action.runner.tick(reversed)
  if reversed_result then break end
end
check(reversed_result and reversed_result.status == "partial" and reversed_result.outcome.code == "LAYOUT_PARTIAL"
  and #reversed_result.outcome.failed == 1 and #reversed_result.outcome.placed == 1
  and reversed_result.outcome.placed[1].direction == 8
  and reversed_result.outcome.placed[1].belt_to_ground_type == "input"
  and reversed_result.outcome.placed[1].underground.direction == 8
  and reversed_result.outcome.failed[1].reason:match("UNDERGROUND_CONFIGURATION_MISMATCH")
  and inventory["underground-belt"] == 0 and created[#created].entity.valid,
  "a coerced underground end reports actual paid construction and an honest partial layout")
reverse_underground = false
created = {}

inventory = { ["wooden-chest"] = 1, ["burner-inserter"] = 1, ["stone-furnace"] = 1 }
local task = { id = 7, anchor = { x = 200, y = 200 }, entities = {
  { name = "burner-inserter", dx = 2.5, dy = 0.5, direction = 12 },
  { name = "stone-furnace", dx = 4, dy = 1 },
  { name = "wooden-chest", dx = 1.5, dy = 0.5 } } }
layout.layout_action.runner.start(task)
local result
for _ = 1, 20 do
  result = layout.layout_action.runner.tick(task)
  if result then break end
end
check(result and result.status == "done" and result.outcome.code == "LAYOUT_BUILT" and #result.outcome.placed == 3
  and result.outcome.anchor.x == 200, "a layout builds through build_plan and reports anchor and placed")
check(#created == 3 and created[3].name == "burner-inserter", "recipients are built before the inserter that feeds them")

inventory = { ["wooden-chest"] = 1 }
created = {}
local short = { id = 8, anchor = { x = 210, y = 200 }, entities = {
  { name = "wooden-chest", dx = 0.5, dy = 0.5 }, { name = "lab", dx = 3.5, dy = 1.5 } } }
recipes.lab.enabled = false
layout.layout_action.runner.start(short)
for _ = 1, 40 do
  result = layout.layout_action.runner.tick(short)
  if result then break end
end
recipes.lab.enabled = true
check(result and result.status == "failed" and result.outcome.code == "LAYOUT_CHECK_FAILED"
  and result.outcome.failed[1].code == "ITEM_UNOBTAINABLE" and result.outcome.failed[1].item == "lab"
  and #result.outcome.placed == 0 and #created == 0 and inventory["wooden-chest"] == 1,
  "a layout whose bill cannot be had fails before any placement and names the short item")
-- A placement that fails on the ground leaves the rest of a layout placed.
inventory = { ["wooden-chest"] = 2 }
created = {}
local rest = { id = 17, anchor = { x = 240, y = 200 }, entities = {
  { name = "wooden-chest", dx = 0.5, dy = 0.5 }, { name = "wooden-chest", dx = 3.5, dy = 0.5 } } }
layout.layout_action.runner.start(rest)
result = layout.layout_action.runner.tick(rest)
local first_chest = rest._plan and rest._plan.steps[1]
blockers = first_chest and { { valid = true, name = "stone-wall", type = "wall",
  position = { x = first_chest.position.x, y = first_chest.position.y } } } or {}
for _ = 1, 40 do
  result = layout.layout_action.runner.tick(rest)
  if result then break end
end
blockers = {}
check(result and result.status == "partial" and result.outcome.code == "LAYOUT_PARTIAL" and #created == 1
  and #result.outcome.placed == 1 and result.outcome.failed[1].index == 0 and result.outcome.failed[1].code == "PLACE_FAILED",
  "a layout whose first placement is blocked still places the rest")

created = {}
local blocked_task = { id = 9, anchor = { x = -5, y = 0 }, entities = { { name = "wooden-chest", dx = 0.5, dy = 0.5 } } }
layout.layout_action.runner.start(blocked_task)
local refused = layout.layout_action.runner.tick(blocked_task)
check(refused.status == "failed" and refused.outcome.code == "LAYOUT_CHECK_FAILED" and #created == 0,
  "a layout that fails its check builds nothing")
local held = { id = 10, anchor = { x = 220, y = 200 }, entities = { { name = "wooden-chest", dx = 0.5, dy = 0.5 } } }
inventory = { ["wooden-chest"] = 1 }
layout.layout_action.runner.start(held)
layout.layout_action.runner.tick(held) -- the first tick decides the site and starts the nested build
held._plan._approach, held._plan._approach_close = { phase = "walking" }, true
layout.layout_action.runner.resume(held)
check(held._plan._approach == nil and held._plan._approach_close == nil,
  "after a takeover hold the nested build approaches again from where the body stands")
-- Starter items: an entity's insert map goes in after it is placed, and a
-- block fuels its burner machines without being asked.
items.coal = { name = "coal", stack_size = 50 }
entities["burner-mining-drill"].burner_prototype = { fuel_categories = { chemical = true } }
created = {}
inventory = { ["stone-furnace"] = 1, coal = 4 }
local fuelled = { id = 11, anchor = { x = 230, y = 200 }, entities = {
  { name = "stone-furnace", dx = 1, dy = 1, insert = { coal = 4 } } } }
check(pcall(layout.layout_action.validate, fuelled, 1)
  and not pcall(layout.layout_action.validate, { anchor = { x = 0, y = 0 }, entities = {
    { name = "stone-furnace", dx = 1, dy = 1, insert = { coal = 0 } } } }, 1),
  "a layout entity's insert maps item names to positive counts")
layout.layout_action.runner.start(fuelled)
for _ = 1, 20 do
  result = layout.layout_action.runner.tick(fuelled)
  if result then break end
end
check(result and result.status == "done" and created[1].entity.inserted.coal == 4 and inventory.coal == 0,
  "a layout entity's insert map is put into the placed entity")
check(layout._rotated({ entities = { { name = "stone-furnace", dx = 1, dy = 0, insert = { coal = 2 } } } }, 1).entities[1].insert.coal == 2,
  "a turned layout keeps each entity's insert map")
set_powered(false)
created = {}
inventory = { ["burner-mining-drill"] = 1, ["iron-chest"] = 1, coal = 10 }
local drill_block = { id = 12, block = "mining", count = 1, resource = "iron-ore", near = { x = 50.5, y = 50.5 } }
layout.block_action.runner.start(drill_block)
for _ = 1, 60 do
  result = layout.block_action.runner.tick(drill_block)
  if result then break end
end
local drill, chest_built
for _, args in ipairs(created) do
  if args.name == "burner-mining-drill" then drill = args.entity elseif args.name == "iron-chest" then chest_built = args.entity end
end
check(result and result.status == "done" and drill and drill.inserted.coal == 5 and chest_built and next(chest_built.inserted) == nil,
  "build_block fuels its burner drill by default and puts nothing in the chest")
local steps = require("scripts.actions.build_plan").fuel_burners(character, {
  { item = "burner-mining-drill" }, { item = "burner-mining-drill", insert = { wood = 2 } }, { item = "wooden-chest" } })
check(steps[1].insert.coal == 5 and steps[2].insert.wood == 2 and steps[2].insert.coal == nil and steps[3].insert == nil,
  "only burner steps without starter items get fuel")

-- A save made by 0.21.0 mid-search loads into this version: its search kept
-- a boolean deferral and connections without underground facts.
created = {}
inventory = { ["wooden-chest"] = 2, ["transport-belt"] = 10 }
local loaded = { id = 13, anchor = { x = 240, y = 200 }, entities = {
  { name = "wooden-chest", dx = 0.5, dy = 0.5 }, { name = "wooden-chest", dx = 6.5, dy = 0.5 } },
  connections = { { kind = "belt", prototype = "transport-belt", from = { dx = 0.5, dy = 0.5 }, to = { dx = 6.5, dy = 0.5 } } } }
layout.layout_action.runner.start(loaded)
loaded._search.deferred = true
for _, variant in ipairs(loaded._search.variants) do
  for _, route in ipairs(variant.connections) do route.under = nil end
end
for _ = 1, 40 do
  result = layout.layout_action.runner.tick(loaded)
  if result then break end
end
check(result and result.status == "done" and #result.outcome.placed == 7,
  "an in-flight 0.21.0 layout search continues after the upgrade and builds")

check(layout.layout_action.budget_steps({ entities = { {}, {} },
  connections = { { from = { dx = 0, dy = 0 }, to = { dx = 3, dy = 4 } } } }) == 10,
  "a layout's plan budget counts placements and route tiles")

-- Liquids (C6): a site near a liquid reads only that liquid's tiles; this
-- map's lake is water, so lava finds no site, and near_water is water.
prototypes.tile.lava = { collision_mask = { layers = { water_tile = true, player = true } }, fluid = { name = "lava" } }
local read_names = {}
local find_tiles = surface.find_tiles_filtered
surface.find_tiles_filtered = function(filter)
  read_names[#read_names + 1] = table.concat(filter.name or {}, ",")
  for _, name in ipairs(filter.name or {}) do if name == "water" then return find_tiles(filter) end end
  return {}
end
permissive, crowded, blockers = false, false, {}
local pump = { { name = "offshore-pump", dx = 0, dy = 0 } }
local lava = check_layout({ check_only = true, site = { near = { x = 2, y = 0 }, near_liquid = "lava" }, entities = pump })
check(not lava.ok and lava.failed[1].code == "SITE_NOT_FOUND" and lava.failed[1].reason:match("^no lava within")
  and read_names[#read_names] == "lava", "a site near lava reads lava tiles only, and says when there is none")
local wet = check_layout({ check_only = true, site = { near = { x = 2, y = 0 }, near_liquid = "water" }, entities = pump })
local wet_legacy = check_layout({ check_only = true, site = { near = { x = 2, y = 0 }, near_water = true }, entities = pump })
check(wet.ok and wet_legacy.ok and wet.anchor.x == wet_legacy.anchor.x and wet.anchor.y == wet_legacy.anchor.y
  and read_names[#read_names] == "water", "near_liquid water finds the same site near_water does")
check(not pcall(layout.validate_layout, { site = { near = { x = 0, y = 0 }, near_liquid = "mud" }, entities = pump }, "build_layout"),
  "an unknown liquid is refused")
surface.find_tiles_filtered = find_tiles

-- Surface conditions (C10): an entity the planet forbids fails the layout's
-- name checks, before any site is searched.
surface.get_property = function(name) return name == "pressure" and 1000 or 0 end
entities["big-mining-drill"] = entity("big-mining-drill", "mining-drill", 5, 5,
  { surface_conditions = { { property = "pressure", min = 4000, max = 4000 } } })
prototypes.entity["big-mining-drill"] = entities["big-mining-drill"]
items["big-mining-drill"] = { name = "big-mining-drill", place_result = entities["big-mining-drill"], stack_size = 50 }
local before_checks = engine.can_place
local forbidden = check_layout({ check_only = true, anchor = { x = 60, y = 60 }, entities = { { name = "big-mining-drill", dx = 0, dy = 0 } } })
check(not forbidden.ok and forbidden.failed[1].code == "SURFACE_CONDITION"
  and forbidden.failed[1].reason:match("needs pressure = 4000; this surface has 1000") and engine.can_place == before_checks,
  "an entity whose surface conditions the planet breaks fails SURFACE_CONDITION before any placement check")

-- Another planet's ground (C7): a dry run with `surface` checks there from
-- a body-less viewpoint, while the body stays where it is.
local vulcanus_checks = 0
local vulcanus = { index = 2, name = "vulcanus", valid = true, planet = { name = "vulcanus" },
  get_property = function(name) return name == "pressure" and 4000 or 0 end,
  can_place_entity = function() vulcanus_checks = vulcanus_checks + 1; return true end,
  find_entities_filtered = function() return {} end }
game.planets = { vulcanus = { surface = vulcanus } }
character.force.is_space_location_unlocked = function() return true end
local before_nauvis = engine.can_place
local remote = check_layout({ check_only = true, surface = "vulcanus", anchor = { x = 0, y = 0 },
  entities = { { name = "big-mining-drill", dx = 0, dy = 0 }, { name = "iron-chest", dx = 4, dy = 0 } } })
check(remote.ok and vulcanus_checks > 0 and engine.can_place == before_nauvis and remote.materials[1].carried == 0,
  "a dry run on another planet checks that planet's ground and conditions; the body there carries nothing")
check(not pcall(jobs.run_now, layout.layout_check_job, { check_only = true, surface = "vulcanus", platform = 1,
  anchor = { x = 0, y = 0 }, entities = {} }), "a dry run names a platform or a surface, not both")

-- Feasibility (fix 6): a dry run on the body's surface is not ok when an
-- item is neither carried nor obtainable now, and names it; a block build
-- checks the same before spending anything and is all or nothing.
surface.get_property = nil
set_powered(false)
permissive, crowded, blockers = false, false, {}
local plate = { type = "item", name = "iron-plate", amount = 1 }
recipes["iron-plate"] = { name = "iron-plate", enabled = true, category = "smelting",
  ingredients = { { type = "item", name = "iron-ore", amount = 1 } }, products = { plate } }
-- Quality's hidden recycling recipe also makes plates and sorts first.
recipes["iron-chest-recycling"] = { name = "iron-chest-recycling", enabled = true, hidden = true,
  category = "recycling", ingredients = { { type = "item", name = "iron-chest", amount = 1 } },
  products = { { type = "item", name = "iron-plate", amount = 4 } } }
recipes["burner-mining-drill"] = { name = "burner-mining-drill", enabled = true, category = "crafting",
  ingredients = { { type = "item", name = "iron-plate", amount = 9 } },
  products = { { type = "item", name = "burner-mining-drill", amount = 1 } } }
character.prototype = { crafting_categories = { crafting = true } }
-- The engine's product filter, as supply reads it for smelting recipes: a
-- LuaCustomTable, which is userdata like the engine's.
function prototypes.get_recipe_filtered(filters)
  local wanted, found = filters[1].elem_filters[1].name, {}
  for name, recipe in pairs(recipes) do
    for _, product in ipairs(recipe.products or {}) do if product.name == wanted then found[name] = recipe end end
  end
  return mock.custom_table(found)
end
recipes.lab.enabled = false
inventory = { ["burner-mining-drill"] = 1, ["iron-plate"] = 8, ["wooden-chest"] = 2, coal = 10 }
created, crafted = {}, 0
local lab_dry = dry({ anchor = { x = 100, y = 100 }, entities = { { name = "lab", dx = 1.5, dy = 1.5 } } })
check(not lab_dry.ok and lab_dry.failed[1].code == "ITEM_UNOBTAINABLE" and lab_dry.failed[1].item == "lab"
  and lab_dry.failed[1].reason:match("^lab can't be carried now") and lab_dry.failed[1].reason:match("not researched")
  and #lab_dry.placed == 1, "a layout dry run naming a locked item nobody carries fails ITEM_UNOBTAINABLE naming it")
inventory.lab = 1
check(dry({ anchor = { x = 100, y = 100 }, entities = { { name = "lab", dx = 1.5, dy = 1.5 } } }).ok,
  "the same layout is ok once the body carries the item")
inventory.lab = nil
local two = check_block({ block = "mining", count = 2, resource = "iron-ore", near = { x = 50.5, y = 50.5 }, check_only = true })
local short_drill = two.failed[1]
check(not two.ok and short_drill and short_drill.code == "ITEM_UNOBTAINABLE" and short_drill.item == "burner-mining-drill"
  and short_drill.missing == 1 and short_drill.short.item == "iron-plate" and short_drill.short.missing == 1
  and short_drill.reason:match("needs 1 more iron%-plate") and short_drill.reason:match("no own furnace"),
  "a two-drill opening block with one drill and 8 of the 9 plates the second needs fails, naming the drill and the plate")
inventory["iron-plate"] = 9
check(check_block({ block = "mining", count = 2, resource = "iron-ore", near = { x = 50.5, y = 50.5 }, check_only = true }).ok,
  "with the ninth plate the second drill can be crafted: the dry run is ok")
inventory["iron-plate"] = 8
-- A furnace of its own lets the body smelt the ninth plate from gatherable ore.
prototypes.entity["iron-ore"].mineable_properties = { minable = true, products = { { name = "iron-ore" } } }
storage.registry.entries[901] = { entity = { valid = true, prototype = { crafting_categories = { smelting = true } } },
  unit = 901, name = "stone-furnace", type = "furnace", position = { x = 0, y = 0 } }
storage.registry.machines.furnace = { [901] = true }
local supply = require("scripts.actions.supply")
local smeltable = supply.unobtainable(character, { { name = "burner-mining-drill", count = 2 } })
storage.registry.entries[901], storage.registry.machines.furnace = nil, nil
check(#smeltable == 0, "an own furnace and gatherable ore make the missing plate obtainable")
check(#supply.unobtainable(character, { { name = "iron-ore", count = 500 } }) == 0
  and supply.unobtainable(character, { { name = "iron-plate", count = 9 } })[1].missing == 1,
  "anything natural can be gathered; a plate without a furnace is short by what is not carried")
-- Ore an own drill mines is hand-gathered like any natural item, as supply
-- does while the drill's output cannot be taken (it feeds a furnace).
storage.registry.entries[902] = { entity = { valid = true, mining_target = { valid = true,
  prototype = prototypes.entity["iron-ore"] } }, unit = 902, name = "burner-mining-drill", type = "mining-drill",
  position = { x = 0, y = 0 } }
storage.registry.machines["mining-drill"] = { [902] = true }
local find_entities = surface.find_entities_filtered
local surface_reads = 0
surface.find_entities_filtered = function(filter) surface_reads = surface_reads + 1; return find_entities(filter) end
check(#supply.unobtainable(character, { { name = "iron-ore", count = 5 } }) == 0 and surface_reads == 0,
  "ore an own drill mines stays obtainable in the dry run, with no surface read")
surface.find_entities_filtered = find_entities
storage.registry.entries[902], storage.registry.machines["mining-drill"] = nil, nil
prototypes.entity["iron-ore"].mineable_properties = nil
-- The blueprint dry run (hand mode) says the same.
local blueprint_report = layout.check_report(character, layout._resolve(character,
  { anchor = { x = 100, y = 100 }, layouts = { { entities = { { name = "lab", dx = 1.5, dy = 1.5 } }, connections = {} } } }))
check(blueprint_report.ok and blueprint_report.unobtainable and blueprint_report.unobtainable[1].item == "lab",
  "check_report keeps the geometry's ok and carries the unobtainable rows to blueprint_place")
-- The block build: nothing fetched, crafted or placed when the block cannot be had.
local infeasible = { id = 14, block = "mining", count = 2, resource = "iron-ore", near = { x = 50.5, y = 50.5 } }
layout.block_action.runner.start(infeasible)
for _ = 1, 60 do
  result = layout.block_action.runner.tick(infeasible)
  if result then break end
end
check(result and result.status == "failed" and result.outcome.code == "LAYOUT_CHECK_FAILED"
  and result.outcome.failed[1].code == "ITEM_UNOBTAINABLE" and result.outcome.failed[1].item == "burner-mining-drill"
  and #created == 0 and crafted == 0 and inventory["iron-plate"] == 8 and inventory["burner-mining-drill"] == 1,
  "an infeasible block build fails before spending the starting kit")
-- A layout is checked the same way: belts the body carries are not placed
-- when the inserter after them needs plates it cannot have.
recipes["burner-inserter"] = { name = "burner-inserter", enabled = true, category = "crafting",
  ingredients = { { type = "item", name = "iron-plate", amount = 3 } },
  products = { { type = "item", name = "burner-inserter", amount = 1 } } }
inventory = { ["transport-belt"] = 10, ["iron-plate"] = 2 }
created, crafted = {}, 0
local belts = {}
for i = 0, 9 do belts[#belts + 1] = { name = "transport-belt", dx = i + 0.5, dy = 0.5, direction = 4 } end
belts[#belts + 1] = { name = "burner-inserter", dx = 10.5, dy = 0.5, direction = 4 }
local feed = { id = 18, anchor = { x = 100, y = 100 }, entities = belts }
layout.layout_action.runner.start(feed)
for _ = 1, 60 do
  result = layout.layout_action.runner.tick(feed)
  if result then break end
end
check(result and result.status == "failed" and result.outcome.code == "LAYOUT_CHECK_FAILED"
  and result.outcome.failed[1].code == "ITEM_UNOBTAINABLE" and result.outcome.failed[1].item == "burner-inserter"
  and result.outcome.failed[1].short.item == "iron-plate" and result.outcome.failed[1].short.missing == 1
  and #result.outcome.placed == 0 and #created == 0 and crafted == 0
  and inventory["transport-belt"] == 10 and inventory["iron-plate"] == 2,
  "a layout one plate short of its last inserter places none of its belts and names the inserter and the plate")
-- A layout fetches its whole bill in one supply before the first placement,
-- so items that share ingredients (a stone furnace inside a drill) are
-- claimed together, not spent by whichever is placed first.
local furnace_recipe, drill_recipe = recipes["stone-furnace"], recipes["burner-mining-drill"]
recipes["stone-furnace"] = { name = "stone-furnace", enabled = true, category = "crafting",
  ingredients = { { type = "item", name = "stone", amount = 5 } },
  products = { { type = "item", name = "stone-furnace", amount = 1 } } }
recipes["burner-mining-drill"] = { name = "burner-mining-drill", enabled = true, category = "crafting",
  ingredients = { { type = "item", name = "iron-plate", amount = 9 }, { type = "item", name = "stone-furnace", amount = 1 } },
  products = { { type = "item", name = "burner-mining-drill", amount = 1 } } }
inventory = { ["iron-plate"] = 9, stone = 10 }
created = {}
local supplied = {}
local real_ensure = supply.ensure
supply.ensure = function(_, needs)
  supplied[#supplied + 1] = { needs = needs, placed = #created }
  for _, need in ipairs(needs) do inventory[need.name] = need.count end
  return { status = "done" }
end
local pair = { id = 19, anchor = { x = 50, y = 50 }, entities = {
  { name = "burner-mining-drill", dx = 1, dy = 1 }, { name = "stone-furnace", dx = 1, dy = -1 } } }
layout.layout_action.runner.start(pair)
for _ = 1, 60 do
  result = layout.layout_action.runner.tick(pair)
  if result then break end
end
supply.ensure = real_ensure
recipes["stone-furnace"], recipes["burner-mining-drill"] = furnace_recipe, drill_recipe
local wanted = {}
for _, need in ipairs(supplied[1] and supplied[1].needs or {}) do wanted[need.name] = need.count end
check(result and result.status == "done" and #created == 2 and #supplied == 1 and supplied[1].placed == 0
  and wanted["burner-mining-drill"] == 1 and wanted["stone-furnace"] == 1,
  "a layout's drill and furnace are fetched in one supply before the first placement, and both are placed")
-- A layout whose whole bill does not fit in the inventory at once (two free
-- slots, three kinds of item) carries what fits and fetches the rest at its
-- step, once placements have freed room; a block fails with nothing placed.
local SLOTS = 2
local function free_slots()
  local used = 0
  for name, count in pairs(inventory) do
    if count > 0 then used = used + math.ceil(count / (items[name] and items[name].stack_size or 50)) end
  end
  return SLOTS - used
end
local real_main_inventory = character.get_main_inventory
character.get_main_inventory = function()
  return { get_insertable_count = function(name)
    local stack = items[name] and items[name].stack_size or 50
    local count = inventory[name] or 0
    local partial = count > 0 and (stack - (count - 1) % stack - 1) or 0
    return math.max(0, free_slots()) * stack + partial
  end }
end
local crafts = {}
supply.register_runner("craft", { start = function() end, tick = function(task)
  crafts[#crafts + 1] = { recipe = task.recipe, placed = #created }
  inventory[task.recipe] = (inventory[task.recipe] or 0) + task.count
  return { status = "done", detail = "crafted" }
end })
local function tight_run(task, action, carried)
  inventory, created, crafts = carried or {}, {}, {}
  action.runner.start(task)
  for _ = 1, 120 do
    local out = action.runner.tick(task)
    if out then return out end
  end
end
local tight = { id = 20, anchor = { x = 150, y = 150 }, entities = {
  { name = "wooden-chest", dx = 0.5, dy = 0.5 }, { name = "iron-chest", dx = 2.5, dy = 0.5 },
  { name = "transport-belt", dx = 4.5, dy = 0.5, direction = 4 } } }
result = tight_run(tight, layout.layout_action)
local belt_crafted_at
for _, row in ipairs(crafts) do if row.recipe == "transport-belt" then belt_crafted_at = row.placed end end
check(result and result.status == "done" and #created == 3 and belt_crafted_at == 2 and free_slots() == SLOTS,
  "a layout whose whole bill does not fit fetches the rest at its step and places everything")
local tight_block = { id = 21, block = "mining", count = 1, resource = "iron-ore", near = { x = 50.5, y = 50.5 } }
result = tight_run(tight_block, layout.block_action, { ["burner-mining-drill"] = 1, coal = 10 })
check(result and result.status == "failed" and #created == 0 and #crafts == 0
  and result.detail:match("placed nothing: SUPPLY_SHORTFALL.*my inventory is full"),
  "a block whose bill does not fit in the inventory places nothing")
supply.register_runner("craft", require("scripts.actions.craft"))
character.get_main_inventory = real_main_inventory
-- A block whose outlet cannot be placed stops there: its drill is never placed.
inventory = { ["burner-mining-drill"] = 1, ["wooden-chest"] = 1, coal = 10 }
created = {}
local outlet = { id = 15, block = "mining", count = 1, resource = "iron-ore", near = { x = 50.5, y = 50.5 } }
layout.block_action.runner.start(outlet)
for _ = 1, 20 do
  result = layout.block_action.runner.tick(outlet)
  if result or outlet._plan then break end
end
local chest_step = outlet._plan and outlet._plan.steps[1]
check(chest_step and chest_step.item == "wooden-chest", "a mining block places its outlet chest first")
blockers = { { valid = true, name = "stone-wall", type = "wall", position = { x = chest_step.position.x, y = chest_step.position.y } } }
for _ = 1, 60 do
  result = layout.block_action.runner.tick(outlet)
  if result then break end
end
blockers = {}
local drills_built = 0
for _, args in ipairs(created) do if args.name == "burner-mining-drill" then drills_built = drills_built + 1 end end
check(result and result.status == "failed" and drills_built == 0 and inventory["burner-mining-drill"] == 1
  and result.outcome.failed[1].code == "PLACE_FAILED" and result.outcome.failed[2].code == "NOT_ATTEMPTED",
  "a block stops at its failed outlet and never places the drill")
-- supply_all: a plan that cannot carry everything places nothing, not its first steps.
inventory = { ["wooden-chest"] = 1 }
created = {}
local build_plan = require("scripts.actions.build_plan")
local all = { id = 16, supply_all = true, stop_on_error = true, steps = {
  { item = "wooden-chest", position = { x = 300.5, y = 300.5 } }, { item = "lab", position = { x = 303.5, y = 301.5 } } } }
build_plan.start(all)
for _ = 1, 60 do
  result = build_plan.tick(all)
  if result then break end
end
check(result and result.status == "failed" and #created == 0 and inventory["wooden-chest"] == 1
  and result.detail:match("^placed nothing: SUPPLY_SHORTFALL") and all._short.lab,
  "a supply_all plan short of an item fails before its first placement")
recipes.lab.enabled = true
character.prototype = nil

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
