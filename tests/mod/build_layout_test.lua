-- Offline tests for build_layout: sites are found on a resource patch and
-- at a shore; the dry run reports inserters, belt ends, power, ore under
-- footprints, mixed ore and open fluid ports as data; check_only has no
-- side effects; a build places recipients first and reports {anchor,
-- placed, failed}.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local stacks = dofile(here .. "/item_stack_mock.lua")

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

_G.storage = {}
_G.game = { tick = 100, create_inventory = stacks.create_inventory }
_G.defines = { build_check_type = { manual = 1, ghost_revive = 2 }, inventory = { chest = 1 } }

-- Factorio 2.0.77 base geometry for the layout entities.
local function box(w, h) return { left_top = { x = -w / 2, y = -h / 2 }, right_bottom = { x = w / 2, y = h / 2 } } end
local function entity(name, type, w, h, extra)
  local proto = { name = name, type = type, tile_width = w, tile_height = h, collision_box = box(w - 0.3, h - 0.3) }
  for k, v in pairs(extra or {}) do proto[k] = v end
  -- The live prototype fields the dry run's survey reads.
  if proto.pickup then proto.inserter_pickup_position, proto.inserter_drop_position = proto.pickup, proto.drop end
  if proto.electric then
    proto.electric_energy_source_prototype = { usage_priority = type == "generator" and "secondary-output" or "secondary-input" }
  end
  if proto.supply then proto.get_supply_area_distance = function() return proto.supply end end
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
  ["pipe-to-ground"] = entity("pipe-to-ground", "pipe-to-ground", 1, 1),
  ["pumpjack"] = entity("pumpjack", "mining-drill", 3, 3, { mining_drill_radius = 0.99, electric = true,
    resource_categories = { ["basic-fluid"] = true } }),
  ["oil-refinery"] = entity("oil-refinery", "assembling-machine", 5, 5, { electric = true }),
}
-- 2.0 pipe connections: a tile inside the north-facing entity and the
-- direction leading out of it; the four positions turn with the entity.
local function fluid_box(index, connections)
  local list = {}
  for i, c in ipairs(connections) do
    local positions = {}
    for q = 0, 3 do
      local x, y = c[1], c[2]
      for _ = 1, q do x, y = -y, x end
      positions[q + 1] = { x = x, y = y }
    end
    list[i] = { connection_type = "normal", direction = c[3], positions = positions }
  end
  return { index = index, production_type = "input-output", pipe_connections = list }
end
entities["offshore-pump"].fluidbox_prototypes = { fluid_box(1, { { 0, 0, 8 } }) }
entities["boiler"].fluidbox_prototypes = { fluid_box(1, { { -1, 0.5, 12 }, { 1, 0.5, 4 } }), fluid_box(2, { { 0, -0.5, 0 } }) }
entities["steam-engine"].fluidbox_prototypes = { fluid_box(1, { { 0, 2, 8 }, { 0, -2, 0 } }) }
entities["pipe"].fluidbox_prototypes = { fluid_box(1, { { 0, 0, 0 }, { 0, 0, 4 }, { 0, 0, 8 }, { 0, 0, 12 } }) }
-- A box of one production type: a drill's optional input (acid for
-- uranium), a pumpjack's output, an assembler's recipe boxes.
local function typed_box(production_type, index, connections)
  local b = fluid_box(index, connections)
  b.production_type = production_type
  return b
end
entities["electric-mining-drill"].fluidbox_prototypes = {
  typed_box("input", 1, { { -1, 0, 12 }, { 1, 0, 4 }, { 0, 1, 8 } }) }
-- The pumpjack as the game data has it: production_type "none", an output
-- pipe connection.
entities["pumpjack"].fluidbox_prototypes = { typed_box("none", 1, { { 1, -1, 0 } }) }
entities["pumpjack"].fluidbox_prototypes[1].pipe_connections[1].flow_direction = "output"
entities["assembling-machine-2"].fluidbox_prototypes = { typed_box("input", 1, { { 0, -1, 0 } }),
  typed_box("output", 2, { { 0, 1, 8 } }) }
-- The oil refinery as 2.0.77 has it: inputs 1 and 2 south, outputs 3 to 5
-- north (which fluid sits in which comes from the recipe).
entities["oil-refinery"].fluidbox_prototypes = { typed_box("input", 1, { { -1, 2, 8 } }), typed_box("input", 2, { { 1, 2, 8 } }),
  typed_box("output", 3, { { -2, -2, 0 } }), typed_box("output", 4, { { 0, -2, 0 } }), typed_box("output", 5, { { 2, -2, 0 } }) }
-- A pipe-to-ground: a normal side north, the underground side south.
entities["pipe-to-ground"].fluidbox_prototypes = { fluid_box(1, { { 0, 0, 0 }, { 0, 0, 8 } }) }
entities["pipe-to-ground"].fluidbox_prototypes[1].pipe_connections[2].connection_type = "underground"
local items = {}
for name, proto in pairs(entities) do items[name] = { name = name, place_result = proto, stack_size = 50 } end
items["iron-plate"] = { name = "iron-plate", stack_size = 100 }
_G.prototypes = { item = items, entity = { ["iron-ore"] = { name = "iron-ore", type = "resource", resource_category = "basic-solid" },
  ["copper-ore"] = { name = "copper-ore", type = "resource", resource_category = "basic-solid" },
  ["crude-oil"] = { name = "crude-oil", type = "resource", resource_category = "basic-fluid",
    mineable_properties = { products = { { type = "fluid", name = "crude-oil", amount = 10 } } } } },
  tile = { water = { collision_mask = { layers = { water_tile = true } }, fluid = { name = "water" } },
    grass = { collision_mask = { layers = { ground_tile = true } } } },
  -- Nauvis's map generation places water (power blocks need it).
  space_location = { nauvis = { name = "nauvis", map_gen_settings = { autoplace_settings = { tile = { settings = { water = {} } } } } } },
  space_connection = {},
  -- What the survey reads of a recipe: whether it takes or makes a fluid.
  recipe = { ["iron-gear-wheel"] = { ingredients = { { type = "item", name = "iron-plate", amount = 2 } },
      products = { { type = "item", name = "iron-gear-wheel", amount = 1 } } },
    ["advanced-oil-processing"] = { ingredients = { { type = "fluid", name = "water", amount = 50 },
      { type = "fluid", name = "crude-oil", amount = 100 } }, products = { { type = "fluid", name = "heavy-oil", amount = 25 },
      { type = "fluid", name = "light-oil", amount = 45 }, { type = "fluid", name = "petroleum-gas", amount = 55 } } },
    ["basic-oil-processing"] = { ingredients = { { type = "fluid", name = "crude-oil", amount = 100, fluidbox_index = 2 } },
      products = { { type = "fluid", name = "petroleum-gas", amount = 45, fluidbox_index = 3 } } },
    ["water-barrel"] = { ingredients = { { type = "fluid", name = "water", amount = 50 }, { type = "item", name = "barrel", amount = 1 } },
      products = { { type = "item", name = "water-barrel", amount = 1 } } } } }
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
-- A query's type filter: one type or a list of them.
local function of_type(e, filter)
  if type(filter.type) ~= "table" then return filter.type == nil or e.type == filter.type end
  for _, t in ipairs(filter.type) do if e.type == t then return true end end
  return false
end
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
      -- A full strip is 8 rows; the dry run's survey reads footprints.
      if filter.area.right_bottom.y - filter.area.left_top.y == 8 then engine.strip_reads = (engine.strip_reads or 0) + 1 end
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
          and b.position.y > filter.area.left_top.y and b.position.y < filter.area.right_bottom.y
          and of_type(b, filter) then out[#out + 1] = b end
        if filter.limit and #out >= filter.limit then break end
      end
      return out
    end
    if filter.radius then
      local out = {}
      for _, b in ipairs(blockers) do
        local dx, dy = b.position.x - filter.position.x, b.position.y - filter.position.y
        if dx * dx + dy * dy <= filter.radius * filter.radius and of_type(b, filter) then
          out[#out + 1] = b
        end
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
recipes["water-barrel"] = { name = "water-barrel", enabled = true }
recipes["advanced-oil-processing"] = { name = "advanced-oil-processing", enabled = true }
recipes["basic-oil-processing"] = { name = "basic-oil-processing", enabled = true }
character = {
  valid = true, name = "character", position = { x = 500.5, y = 500.5 },
  bounding_box = { left_top = { x = 500.3, y = 500.3 }, right_bottom = { x = 500.7, y = 500.7 } },
  force = { recipes = recipes, is_chunk_charted = function() return true end },
  surface = surface, build_distance = 10, crafting_queue_size = 0,
  get_item_count = function(name) return inventory[type(name) == "table" and name.name or name] or 0 end,
  -- Inserts hand over real stacks (item_stack_mock), one per name over `inventory`.
  get_main_inventory = function() return stacks.view(inventory, function() return 1000 end) end,
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
local jobs = require("scripts.jobs")
-- The RPC dry runs are jobs; these run one to its end, a tick's budget at a time.
local function check_layout(params) return jobs.run_now(layout.layout_check_job, params) end

-- ------------------------------------------------------------- site search

-- A layout sited on a resource puts every drill's mining area mostly on the
-- patch.
local function drills_with_chests(site)
  return { check_only = true, site = site, entities = {
    { name = "burner-mining-drill", dx = 1, dy = 1 }, { name = "burner-mining-drill", dx = 3, dy = 1 },
    { name = "wooden-chest", dx = 0.5, dy = -0.5 }, { name = "wooden-chest", dx = 2.5, dy = -0.5 } } }
end
local mined = check_layout(drills_with_chests({ near = { x = 30, y = 50 }, on_resource = "iron-ore" }))
local on_patch, drills_sited = mined.ok, 0
for _, row in ipairs(mined.placed) do
  if row.name == "burner-mining-drill" then
    drills_sited = drills_sited + 1
    if not (row.x > 40 and row.x < 80 and row.y > 40 and row.y < 60) then on_patch = false end
  end
end
check(on_patch and drills_sited == 2 and #mined.failed == 0, "a layout sited on a resource puts every drill on the patch")
-- The resource window is a phase of the search: starting one reads nothing,
-- and the window is read a strip of rows per query.
engine.resource_reads, engine.strip_reads = 0, 0
local window = layout.layout_check_job.start(drills_with_chests({ near = { x = 60, y = 50 }, on_resource = "iron-ore" }))
check(engine.resource_reads == 0, "starting a site search reads no resource: the window is read in the search's ticks")
local window_result, window_slices = nil, 0
repeat
  window_slices = window_slices + 1
  window_result = layout.layout_check_job.step(window, { left = jobs.WORK_PER_TICK })
until window_result or window_slices > 200
local window_reads, survey_reads = engine.strip_reads, engine.resource_reads - engine.strip_reads
check(window_result and window_result.ok and window_reads == 8 and survey_reads == 4,
  "a 64-row resource window is read in 8 strips (" .. window_reads .. "), the dry run's survey reads one footprint "
    .. "per placement (" .. survey_reads .. "), and the site is found")
local nowhere = check_layout(drills_with_chests({ near = { x = -300, y = -300 }, on_resource = "iron-ore" }))
check(not nowhere.ok and nowhere.failed[1].code == "SITE_NOT_FOUND", "no resource near the site is SITE_NOT_FOUND")

-- A shore site: the pump on land with water behind it.
local shore = check_layout({ check_only = true, site = { near = { x = 5, y = 3 }, near_water = true },
  entities = { { name = "offshore-pump", dx = 0.5, dy = 0.5, direction = 12 } } })
local pump_row
for _, row in ipairs(shore.placed) do if row.name == "offshore-pump" then pump_row = row end end
check(shore.ok and pump_row and not is_water(math.floor(pump_row.x), math.floor(pump_row.y))
  and is_water(math.floor(pump_row.x) - 1, math.floor(pump_row.y)),
  "a layout sited near water puts its pump on land with water behind it")
local landlocked = check_layout({ check_only = true, site = { near = { x = 300, y = 300 }, near_water = true },
  entities = { { name = "offshore-pump", dx = 0.5, dy = 0.5, direction = 12 } } })
check(not landlocked.ok and landlocked.failed[1].code == "SITE_NOT_FOUND", "no water near the site is SITE_NOT_FOUND")

local smelt = check_layout({ check_only = true, site = { near = { x = 10.5, y = 10.5 } }, entities = {
  { name = "stone-furnace", dx = 1, dy = 1 }, { name = "stone-furnace", dx = 3, dy = 1 } } })
local nearest = math.huge
for _, row in ipairs(smelt.placed) do nearest = math.min(nearest, (row.x - 10.5) ^ 2 + (row.y - 10.5) ^ 2) end
check(smelt.ok and nearest < 25, "a layout sited near a point is placed around it")

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
-- Ore under every tile of a 9x9 footprint, read before a belt on it: the
-- capped blocker search still reaches the belt.
entities["test-silo"] = entity("test-silo", "container", 9, 9)
items["test-silo"] = { name = "test-silo", place_result = entities["test-silo"], stack_size = 1 }
prototypes.entity["test-silo"] = entities["test-silo"]
blockers = {}
for x = 16, 24 do for y = 16, 24 do
  blockers[#blockers + 1] = { valid = true, name = "iron-ore", type = "resource", position = { x = x + 0.5, y = y + 0.5 } }
end end
blockers[#blockers + 1] = { valid = true, name = "transport-belt", type = "transport-belt", position = { x = 24.5, y = 24.5 } }
local on_ore = dry({ anchor = { x = 16, y = 16 }, entities = { { name = "test-silo", dx = 4.5, dy = 4.5 } } })
check(not on_ore.ok and on_ore.failed[1].reason:match("blocked by transport%-belt") ~= nil,
  "a belt under a large footprint on ore is named, not hidden behind the ore")
entities["test-silo"], items["test-silo"], prototypes.entity["test-silo"] = nil, nil, nil
blockers = {}
-- An own belt already standing on a layout tile, facing another way: the
-- build takes it as placed and turns it, so the check passes it too.
local standing = { valid = true, name = "transport-belt", type = "transport-belt", force = character.force,
  position = { x = 30.5, y = 30.5 }, direction = 4 }
blockers = { standing }
surface.find_entity = function(name, position)
  if name == standing.name and math.abs(position.x - 30.5) < 0.5 and math.abs(position.y - 30.5) < 0.5 then return standing end
end
local adopted = dry({ anchor = { x = 30, y = 30 }, entities = { { name = "transport-belt", dx = 0.5, dy = 0.5, direction = 0 } } })
check(adopted.ok, "an own entity of the same kind on a layout tile passes the check: the build adopts and turns it")
check(#adopted.materials == 0, "an adopted entity is not in the bill: it stands already")
-- Only a layout at a given anchor adopts: a site search never lands on what
-- already stands there, so a second layout is not reported on top of the first.
local sited = dry({ site = { near = { x = 30.5, y = 30.5 } }, entities = { { name = "transport-belt", dx = 0.5, dy = 0.5, direction = 0 } } })
check(sited.ok and not (sited.anchor.x == 30 and sited.anchor.y == 30),
  "a site search does not take an own entity's tile as free")
surface.find_entity, blockers = nil, {}

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

-- The dry run reports, as data, what each inserter picks from and drops
-- into, what each belt run's last belt faces, unpowered machines and
-- planned poles no wire reaches.
local existing, belt_run
do
  function existing(name, kind, x, y, w, extra)
    local e = { valid = true, name = name, type = kind, position = { x = x, y = y },
      bounding_box = { left_top = { x = x - w / 2, y = y - w / 2 }, right_bottom = { x = x + w / 2, y = y + w / 2 } } }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
  end
  blockers = { existing("wooden-chest", "container", 900.5, 897.5, 0.7) }
  local function feeder(direction)
    return dry({ anchor = { x = 900, y = 900 }, entities = { { name = "stone-furnace", dx = 0, dy = 0 },
      { name = "burner-inserter", dx = 0.5, dy = -1.5, direction = direction },
      { name = "transport-belt", dx = 1.5, dy = -0.5, direction = 12 }, { name = "transport-belt", dx = 2.5, dy = -0.5, direction = 12 } } })
  end
  local north, south = feeder(0), feeder(8)
  local fed, unfed = north.inserters and north.inserters[1], south.inserters and south.inserters[1]
  check(north.ok and fed and fed.x == 900.5 and fed.y == 898.5 and fed.picks_from == "wooden-chest" and fed.drops_into == "stone-furnace",
    "a dry run names what an inserter picks from (an existing chest) and drops into (a planned furnace)")
  check(south.ok and unfed and unfed.picks_from == "stone-furnace" and unfed.drops_into == "wooden-chest",
    "turning the inserter round swaps its pickup and drop targets in the dry run")
  local belt_end = north.belt_ends and north.belt_ends[1]
  check(north.belt_ends and #north.belt_ends == 1 and belt_end.x == 901.5 and belt_end.faces == "stone-furnace",
    "a belt run's last belt names what it faces; a belt facing the next belt of its run is no end")
  blockers = {}
  local open_end = dry({ anchor = { x = 900, y = 920 }, entities = { { name = "transport-belt", dx = 0.5, dy = 0.5, direction = 4 } } })
  check(open_end.ok and open_end.belt_ends and open_end.belt_ends[1].faces == "nothing" and open_end.inserters == nil,
    "a belt facing open ground faces nothing; a layout without inserters lists none")
  local routed_end
  for _, row in ipairs(routed.belt_ends or {}) do if row.faces == "wooden-chest" then routed_end = row end end
  check(routed_end ~= nil, "a routed belt's last belt faces the chest it was routed to")

  -- A belt reversed in the middle of a run: the belt running head-on into
  -- it and the reversed belt itself are both ends, beside the run's last.
  function belt_run(...)
    local list = {}
    for i, e in ipairs({ ... }) do
      list[i] = { name = e[1], dx = i - 0.5, dy = 0.5, direction = e[2], belt_to_ground_type = e[3] }
    end
    local out = dry({ anchor = { x = 900, y = 930 }, entities = list })
    local ends = {}
    for _, row in ipairs(out.belt_ends or {}) do ends[#ends + 1] = string.format("%g:%s", row.x, row.faces) end
    table.sort(ends)
    return out.ok and table.concat(ends, " ") or "failed"
  end
  local belt = "transport-belt"
  local reversed = belt_run({ belt, 4 }, { belt, 4 }, { belt, 12 }, { belt, 4 }, { belt, 4 })
  check(reversed == "901.5:transport-belt 902.5:transport-belt 904.5:nothing",
    "a belt facing a reversed belt and the reversed belt are belt ends (" .. reversed .. ")")
  local sideload = belt_run({ belt, 4 }, { belt, 0 })
  check(sideload == "901.5:nothing", "a belt side-loading onto another is no end (" .. sideload .. ")")

  -- belt_joins: a drill on the iron patch drops onto a planned belt that
  -- runs into a standing copper-ore belt; the joined left lane mixes.
  prototypes.entity["iron-ore"].mineable_properties = { products = { { type = "item", name = "iron-ore", amount = 1 } } }
  local copper = existing("transport-belt", "transport-belt", 62.5, 49.5, 0.8, { direction = 0,
    belt_neighbours = { inputs = {}, outputs = {} }, get_max_transport_line_index = function() return 2 end,
    get_transport_line = function(index)
      return { get_contents = function() return index == 1 and { { name = "copper-ore", quality = "normal", count = 3 } } or {} end }
    end })
  blockers = { copper }
  local joined = dry({ anchor = { x = 60, y = 50 }, entities = { { name = "burner-mining-drill", dx = 1, dy = 1, direction = 4 },
    { name = "transport-belt", dx = 2.5, dy = 0.5, direction = 0 } } })
  local onto, dropped
  for _, row in ipairs(joined.belt_joins or {}) do
    if row.standing then onto = row elseif row.join == "drop" then dropped = row end
  end
  local left = onto and onto.lanes[1]
  check(joined.ok and onto and onto.join == "straight" and left.lane == "left" and left.items[1] == "copper-ore"
    and left.adds[1] == "iron-ore" and left.mixes == true and dropped and dropped.lanes[1].lane == "left",
    "a layout dry run lists belt_joins: the drill's iron ore joins a standing copper-ore lane and mixes")
  prototypes.entity["iron-ore"].mineable_properties = nil
  blockers = {}

  local assembler = { name = "assembling-machine-1", dx = 0.5, dy = 0.5, recipe = "iron-gear-wheel" }
  local bare = dry({ anchor = { x = 950, y = 950 }, entities = { assembler } })
  check(bare.ok and bare.unpowered and bare.unpowered[1].name == "assembling-machine-1" and bare.isolated_poles == nil,
    "an electric machine no pole covers is reported unpowered, and the dry run stays ok")
  local poled = dry({ anchor = { x = 950, y = 950 }, entities = { assembler, { name = "small-electric-pole", dx = 3.5, dy = 0.5 } } })
  check(poled.ok and poled.unpowered == nil and poled.isolated_poles and poled.isolated_poles[1].x == 953.5,
    "a planned pole within supply distance powers the machine; with no pole in wire reach it is isolated")
  local pole = existing("small-electric-pole", "electric-pole", 959.5, 950.5, 0.3, { prototype = entities["small-electric-pole"] })
  blockers = { pole }
  local wired = dry({ anchor = { x = 950, y = 950 }, entities = { assembler, { name = "small-electric-pole", dx = 3.5, dy = 0.5 } } })
  check(wired.ok and wired.unpowered == nil and wired.isolated_poles == nil, "a planned pole in wire reach of an existing pole is not isolated")
  pole.position, pole.bounding_box = { x = 953.5, y = 950.5 }, nil
  local existing_supply = dry({ anchor = { x = 950, y = 950 }, entities = { assembler } })
  check(existing_supply.ok and existing_supply.unpowered == nil, "an existing pole whose supply area covers the machine powers it")
  -- The pole query reaches past the chart: what stands on charted chunks
  -- still counts; a pole on an uncharted chunk never does.
  local is_charted = character.force.is_chunk_charted
  character.force.is_chunk_charted = function(_, chunk) return chunk.x < 30 end
  pole.position = { x = 959.5, y = 950.5 }
  local edge = dry({ anchor = { x = 956, y = 950 }, entities = { assembler } })
  check(edge.ok and edge.unpowered == nil, "a charted pole covers a machine whose pole query reaches an uncharted chunk")
  pole.position = { x = 960.5, y = 950.5 }
  local beyond = dry({ anchor = { x = 957, y = 950 }, entities = { assembler } })
  check(beyond.ok and beyond.unpowered and beyond.unpowered[1].x == 957.5, "a pole on an uncharted chunk powers nothing in the report")
  character.force.is_chunk_charted = is_charted
  blockers = {}
  -- The survey is spread over ticks within the job's budget.
  local row = {}
  for i = 0, 19 do row[#row + 1] = { name = "burner-inserter", dx = i + 0.5, dy = 0.5 } end
  local survey_job = layout.layout_check_job.start({ check_only = true, anchor = { x = 1000, y = 1000 }, entities = row })
  local surveyed, survey_ticks, survey_worst = nil, 0, 0
  while not surveyed and survey_ticks < 200 do
    local surveying = survey_job.survey ~= nil
    local budget = { left = 20 }
    surveyed = layout.layout_check_job.step(survey_job, budget)
    if surveying then survey_ticks, survey_worst = survey_ticks + 1, math.max(survey_worst, 20 - budget.left) end
  end
  check(surveyed and surveyed.ok and #surveyed.inserters == 20 and survey_ticks > 1 and survey_worst <= 26,
    string.format("the dry run's survey of 20 inserters takes %d ticks (worst %d work for a 20 budget)", survey_ticks, survey_worst))
  -- A survey saved by 0.29.1 has no fluid-mix state (mixes, seeds, unders)
  -- or items: it finishes after the upgrade instead of raising.
  local old_job = layout.layout_check_job.start({ check_only = true, anchor = { x = 1000, y = 1000 }, entities = row })
  local old_done, old_ok, old_ticks = nil, true, 0
  while old_ok and not old_done and old_ticks < 200 do
    old_ticks = old_ticks + 1
    local s = old_job.survey
    if s and s.mixes then
      s.mixes, s.seeds, s.unders = nil, nil, nil
      for k = #s.items, 1, -1 do if s.items[k].kind == "seed" or s.items[k].kind == "mix" then table.remove(s.items, k) end end
    end
    old_ok, old_done = pcall(layout.layout_check_job.step, old_job, { left = 20 })
  end
  check(old_ok and old_done and old_done.ok and #old_done.inserters == 20,
    "a dry-run survey saved by 0.29.1 without fluid-mix state finishes after the upgrade: " .. tostring(old_ok or old_done))
  -- A hand-written steam layout at the shore: the pump feeds the boiler's
  -- west water port, the boiler's steam goes north into the engine.
  local function steam(engine_x, extra)
    local list = { { name = "offshore-pump", dx = 0.5, dy = 0.5, direction = 12 }, { name = "boiler", dx = 2.5, dy = 0 },
      { name = "steam-engine", dx = engine_x, dy = -3.5 }, { name = "small-electric-pole", dx = 5.5, dy = -3.5 } }
    for _, e in ipairs(extra or {}) do list[#list + 1] = e end
    return dry({ anchor = { x = 0, y = 0 }, entities = list })
  end
  local power = steam(2.5)
  check(power.ok and power.isolated_poles == nil and power.unpowered == nil,
    "poles that cover a planned generator are not isolated")
  check(power.open_fluid_ports == nil,
    "a steam layout whose pump, boiler and engine meet port to port has no open fluid ports (a box fed on one side is fed)")
  local shifted = steam(3.5)
  local open = {}
  for _, row in ipairs(shifted.open_fluid_ports or {}) do open[row.name] = row end
  check(shifted.ok and open.boiler and open.boiler.x == 2.5 and open.boiler.port.x == 2.5 and open.boiler.port.y == -1.5
    and open["steam-engine"] and open["steam-engine"].x == 3.5 and open["offshore-pump"] == nil,
    "an engine a tile off the boiler's steam port: both open ports are reported, the fed pump is not, and the dry run stays ok")
  local piped = steam(2.5, { { name = "pipe", dx = 4.5, dy = 0.5 }, { name = "pipe", dx = 5.5, dy = 0.5 } })
  local pipe_end = piped.open_fluid_ports and piped.open_fluid_ports[1]
  check(piped.ok and #(piped.open_fluid_ports or {}) == 1 and pipe_end.name == "pipe" and pipe_end.x == 5.5
    and pipe_end.port.x == 6.5 and pipe_end.port.y == 0.5,
    "a pipe run from the boiler's other water port ends open straight ahead of its last pipe")
  -- An own pipe already standing that connects back meets the planned one.
  local links = { { connection_type = "normal", position = { x = 952.5, y = 970.5 }, target_position = { x = 951.5, y = 970.5 } } }
  local standing_pipe = existing("pipe", "pipe", 952.5, 970.5, 0.7)
  standing_pipe.fluidbox = setmetatable({ get_prototype = function() return { production_type = "input-output" } end,
    get_pipe_connections = function() return links end }, { __len = function() return 1 end })
  blockers = { standing_pipe }
  local joined = dry({ anchor = { x = 950, y = 970 }, entities = { { name = "pipe", dx = 0.5, dy = 0.5 }, { name = "pipe", dx = 1.5, dy = 0.5 } } })
  blockers = {}
  check(joined.ok and joined.open_fluid_ports and #joined.open_fluid_ports == 1 and joined.open_fluid_ports[1].x == 950.5
    and joined.open_fluid_ports[1].port.x == 949.5,
    "a planned pipe an existing pipe connects back to is fed; only the far end of the run is open")
  -- A pumpjack's output box delivers its oil, so an unpiped one is open; a
  -- drill's input box is optional, so an electric drill alone is not.
  resources[#resources + 1] = { valid = true, name = "crude-oil", type = "resource", position = { x = 70.5, y = 30.5 } }
  local pumped = dry({ anchor = { x = 70, y = 30 }, entities = { { name = "pumpjack", dx = 0.5, dy = 0.5 } } })
  resources[#resources] = nil
  local oil_out = pumped.open_fluid_ports and pumped.open_fluid_ports[1]
  check(pumped.ok and #(pumped.open_fluid_ports or {}) == 1 and oil_out.name == "pumpjack"
    and oil_out.port.x == 71.5 and oil_out.port.y == 28.5,
    "a pumpjack with no pipe at its output reports that open port")
  local drilled = dry({ anchor = { x = 60, y = 50 }, entities = { { name = "electric-mining-drill", dx = 0.5, dy = 0.5 } } })
  check(drilled.ok and drilled.open_fluid_ports == nil, "an electric drill's optional input box is never an open port")
  -- An assembler's fluid boxes count only for a recipe that takes or makes a
  -- fluid, and then one met port is enough: unmet, it is one row.
  local gears = dry({ anchor = { x = 930, y = 930 }, entities = {
    { name = "assembling-machine-2", dx = 1.5, dy = 1.5, recipe = "iron-gear-wheel" } } })
  check(gears.ok and gears.open_fluid_ports == nil, "an assembler whose recipe uses no fluid has no open fluid ports")
  local barrels = dry({ anchor = { x = 930, y = 930 }, entities = {
    { name = "assembling-machine-2", dx = 1.5, dy = 1.5, recipe = "water-barrel" } } })
  check(barrels.ok and #(barrels.open_fluid_ports or {}) == 1 and barrels.open_fluid_ports[1].name == "assembling-machine-2",
    "an assembler on a fluid recipe with no port met is one open row, not one per box")
  -- A pipe-to-ground's normal side must meet; its underground side is not a port.
  local tunnel = dry({ anchor = { x = 940, y = 930 }, entities = { { name = "pipe-to-ground", dx = 0.5, dy = 0.5 } } })
  local tunnel_open = tunnel.open_fluid_ports and tunnel.open_fluid_ports[1]
  check(tunnel.ok and #(tunnel.open_fluid_ports or {}) == 1 and tunnel_open.name == "pipe-to-ground"
    and tunnel_open.port.x == 940.5 and tunnel_open.port.y == 929.5,
    "a pipe-to-ground whose normal side meets nothing reports that side open")

  -- Fluids the layout's own pipes carry once built: a run from a standing
  -- lubricant pipe to a standing petroleum-gas pipe places its first pipes
  -- (they take the lubricant) and is refused its last, which would join
  -- both. No single placement touches both, so only the build order shows it.
  local function standing_fluid_pipe(x, y, fluid)
    local e = existing("pipe", "pipe", x, y, 0.7)
    local links = {}
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      links[#links + 1] = { connection_type = "normal", position = { x = x, y = y }, target_position = { x = x + d[1], y = y + d[2] } }
    end
    e.fluidbox = setmetatable({ get_prototype = function() return { production_type = "input-output" } end,
      get_pipe_connections = function() return links end },
      { __len = function() return 1 end, __index = function(_, k) if k == 1 and fluid then return { name = fluid, amount = 100 } end end })
    return e
  end
  local function pipe_run(n)
    local list = {}
    for k = 0, n - 1 do list[#list + 1] = { name = "pipe", dx = k + 0.5, dy = 0.5 } end
    return list
  end
  blockers = { standing_fluid_pipe(959.5, 970.5, "lubricant"), standing_fluid_pipe(964.5, 970.5, "petroleum-gas") }
  local mixing = dry({ anchor = { x = 960, y = 970 }, entities = pipe_run(4) })
  local mix_row = mixing.failed and mixing.failed[1]
  check(not mixing.ok and #mixing.failed == 1 and mix_row.index == 3 and mix_row.code == "BLOCKED"
    and mix_row.reason:match("^pipe at %(963%.5, 970%.5%): it would join lubricant and petroleum%-gas pipes") ~= nil,
    "a dry run fails the pipe that would join the lubricant its own earlier pipes carry to standing petroleum gas")
  blockers = { standing_fluid_pipe(959.5, 970.5, "lubricant"), standing_fluid_pipe(964.5, 970.5, "lubricant") }
  local same = dry({ anchor = { x = 960, y = 970 }, entities = pipe_run(4) })
  check(same.ok and #same.failed == 0, "a run between two pipes of one fluid joins nothing that mixes")
  blockers = { standing_fluid_pipe(959.5, 970.5, "lubricant"), standing_fluid_pipe(965.5, 970.5, "petroleum-gas") }
  local apart = dry({ anchor = { x = 960, y = 970 }, entities = pipe_run(4) })
  check(apart.ok and #apart.failed == 0, "a standing pipe of another fluid a tile past the run's end is not joined")
  -- A pipe-to-ground pair carries the fluid under the gap to the far side.
  local underground = entities["pipe-to-ground"].fluidbox_prototypes[1].pipe_connections[2]
  underground.max_underground_distance = 10
  blockers = { standing_fluid_pipe(959.5, 970.5, "lubricant"), standing_fluid_pipe(967.5, 970.5, "petroleum-gas") }
  local tunnelled = dry({ anchor = { x = 960, y = 970 }, entities = { { name = "pipe", dx = 0.5, dy = 0.5 },
    { name = "pipe-to-ground", dx = 1.5, dy = 0.5, direction = 12 }, { name = "pipe-to-ground", dx = 5.5, dy = 0.5, direction = 4 },
    { name = "pipe", dx = 6.5, dy = 0.5 } } })
  -- A planned entrance whose underground partner already stands: the
  -- petroleum gas the standing exit carries meets the lubricant the
  -- entrance takes from its normal side.
  local function standing_exit(x, y, fluid)
    local e = existing("pipe-to-ground", "pipe-to-ground", x, y, 0.7, { direction = 4 })
    e.fluidbox = setmetatable({ get_prototype = function() return { production_type = "input-output" } end,
      get_pipe_connections = function() return {} end },
      { __len = function() return 1 end, __index = function(_, k) if k == 1 then return { name = fluid, amount = 100 } end end })
    return e
  end
  blockers = { standing_fluid_pipe(959.5, 975.5, "lubricant"), standing_exit(964.5, 975.5, "petroleum-gas") }
  local to_standing = dry({ anchor = { x = 960, y = 975 }, entities = {
    { name = "pipe-to-ground", dx = 0.5, dy = 0.5, direction = 12 } } })
  blockers = { standing_fluid_pipe(959.5, 975.5, "lubricant"), standing_exit(964.5, 975.5, "lubricant") }
  local to_same = dry({ anchor = { x = 960, y = 975 }, entities = {
    { name = "pipe-to-ground", dx = 0.5, dy = 0.5, direction = 12 } } })
  underground.max_underground_distance = nil
  blockers = {}
  check(not to_standing.ok and #to_standing.failed == 1 and to_standing.failed[1].index == 0
    and to_standing.failed[1].reason:match("^pipe%-to%-ground at %(960%.5, 975%.5%): it would join lubricant and petroleum%-gas pipes") ~= nil,
    "a planned pipe-to-ground fed lubricant fails when its standing underground partner carries petroleum gas")
  check(to_same.ok and #to_same.failed == 0, "a standing underground partner of the same fluid joins nothing that mixes")

  -- Recipe-aware ports (port_fluids): a refinery on advanced oil processing
  -- takes water south-west (980.5 + -1) and crude oil south-east; a
  -- standing pipe at the crude inlet holding heavy oil is a mismatch row,
  -- the same pipe holding crude oil is none. Data, never a failure.
  local function refinery(recipe, extra)
    local list = { { name = "oil-refinery", dx = 0.5, dy = 0.5, recipe = recipe } }
    for _, e in ipairs(extra or {}) do list[#list + 1] = e end
    return dry({ anchor = { x = 980, y = 980 }, entities = list })
  end
  local function port_row(report, x, y)
    for _, row in ipairs(report.port_fluids or {}) do if row.port.x == x and row.port.y == y then return row end end
  end
  local function mismatches(report)
    local n = 0
    for _, row in ipairs(report.port_fluids or {}) do if row.mismatch then n = n + 1 end end
    return n
  end
  blockers = { standing_fluid_pipe(981.5, 983.5, "heavy-oil") }
  local swapped = refinery("advanced-oil-processing")
  local crude_in = port_row(swapped, 981.5, 983.5)
  check(swapped.ok and #(swapped.port_fluids or {}) == 5 and crude_in and crude_in.role == "input"
    and crude_in.fluid == "crude-oil" and crude_in.meets == "pipe" and crude_in.carries and crude_in.carries[1] == "heavy-oil"
    and #crude_in.carries == 1 and crude_in.mismatch == true and mismatches(swapped) == 1,
    "a standing heavy-oil pipe at a refinery's crude-oil inlet is a port_fluids mismatch row, and the dry run stays ok")
  local water_in, gas_out = port_row(swapped, 979.5, 983.5), port_row(swapped, 982.5, 977.5)
  check(water_in and water_in.fluid == "water" and water_in.meets == "nothing" and water_in.mismatch == nil
    and gas_out and gas_out.role == "output" and gas_out.fluid == "petroleum-gas",
    "each refinery port names the fluid its recipe puts there, and what it meets")
  blockers = { standing_fluid_pipe(981.5, 983.5, "crude-oil") }
  local correct = refinery("advanced-oil-processing")
  check(correct.ok and mismatches(correct) == 0 and port_row(correct, 981.5, 983.5).meets == "pipe",
    "the same pipe holding crude oil at the crude-oil inlet is no mismatch")
  blockers = {}
  -- A planned pumpjack's crude oil into the water inlet: its source fluid
  -- (the resource under it) meets the port the recipe gives water.
  resources[#resources + 1] = { valid = true, name = "crude-oil", type = "resource", position = { x = 70.5, y = 30.5 } }
  local piped_wrong = dry({ anchor = { x = 70, y = 30 }, entities = { { name = "pumpjack", dx = 0.5, dy = 0.5 },
    { name = "oil-refinery", dx = 2.5, dy = -3.5, recipe = "advanced-oil-processing" } } })
  -- Without a crafter on a fluid recipe no port_fluids row exists, so the
  -- planned pumpjack's resource is not read for one: the refinery adds its
  -- own on_ore read and that one, the layout without it neither.
  local function resource_reads(list)
    local before = engine.resource_reads or 0
    local report = dry({ anchor = { x = 70, y = 30 }, entities = list })
    return (engine.resource_reads or 0) - before, report
  end
  local jack = { name = "pumpjack", dx = 0.5, dy = 0.5 }
  local alone_reads, alone = resource_reads({ jack })
  local with_reads = resource_reads({ jack, { name = "oil-refinery", dx = 2.5, dy = -3.5, recipe = "advanced-oil-processing" } })
  resources[#resources] = nil
  check(alone.ok and alone.port_fluids == nil and with_reads == alone_reads + 2,
    "a layout without a crafter on a fluid recipe reads no planned source for port_fluids")
  local wrong_row = port_row(piped_wrong, 71.5, 29.5)
  check(piped_wrong.ok and wrong_row and wrong_row.fluid == "water" and wrong_row.meets == "pumpjack"
    and wrong_row.carries and wrong_row.carries[1] == "crude-oil" and wrong_row.mismatch == true and mismatches(piped_wrong) == 1,
    "a planned pumpjack piped into a refinery's water inlet is a mismatch: crude oil meets the water port")
  -- Basic oil processing uses only the crude-oil inlet (box 2) and the gas
  -- outlet (box 5): the game removes the other boxes, so a pipe at the
  -- water inlet meets a closed port and its own end is open.
  local basic = refinery("basic-oil-processing", { { name = "pipe", dx = -0.5, dy = 3.5 } })
  local closed = port_row(basic, 979.5, 983.5)
  local open_pipe
  for _, row in ipairs(basic.open_fluid_ports or {}) do if row.name == "pipe" then open_pipe = row end end
  check(basic.ok and #basic.port_fluids == 3 and closed and closed.closed == true and closed.fluid == nil
    and closed.meets == "pipe" and port_row(basic, 981.5, 983.5).fluid == "crude-oil"
    and port_row(basic, 982.5, 977.5).fluid == "petroleum-gas" and port_row(basic, 980.5, 977.5) == nil and open_pipe,
    "a basic-oil refinery's unused water inlet is a closed row when a pipe meets it, and that pipe is an open end")
  check(not tunnelled.ok and #tunnelled.failed == 1 and tunnelled.failed[1].index == 3
    and tunnelled.failed[1].reason:match("would join lubricant and petroleum%-gas pipes") ~= nil,
    "the lubricant a planned pipe-to-ground pair carries under a gap meets petroleum gas past its exit")

  -- Ore under footprints: every placement but a drill reports the resource
  -- tiles it covers; a drill reports other resources it would mine.
  local on_ore = dry({ anchor = { x = 45, y = 45 }, entities = { { name = "stone-furnace", dx = 0, dy = 0 },
    { name = "burner-mining-drill", dx = 3, dy = 0 } } })
  local furnace_row = on_ore.on_ore and on_ore.on_ore[1]
  check(on_ore.ok and #(on_ore.on_ore or {}) == 1 and furnace_row.name == "stone-furnace" and furnace_row.x == 45 and furnace_row.y == 45
    and furnace_row.ore["iron-ore"] == 4 and on_ore.mixed_ore == nil,
    "a furnace on the patch reports the 4 ore tiles under it; a drill on one resource is neither on_ore nor mixed_ore")
  local off_ore = dry({ anchor = { x = 100, y = 100 }, entities = { { name = "stone-furnace", dx = 0, dy = 0 } } })
  check(off_ore.ok and off_ore.on_ore == nil, "a furnace off the patch reports no ore")
  local extra_resources = { { valid = true, name = "copper-ore", type = "resource", position = { x = 58.5, y = 48.5 } },
    { valid = true, name = "copper-ore", type = "resource", position = { x = 59.5, y = 48.5 } },
    { valid = true, name = "crude-oil", type = "resource", position = { x = 62.5, y = 52.5 } } }
  for _, e in ipairs(extra_resources) do resources[#resources + 1] = e end
  local mixed = dry({ anchor = { x = 60, y = 50 }, entities = { { name = "electric-mining-drill", dx = 0.5, dy = 0.5 } } })
  for _ = 1, #extra_resources do resources[#resources] = nil end
  local mixed_row = mixed.mixed_ore and mixed.mixed_ore[1]
  check(mixed.ok and mixed_row and mixed_row.name == "electric-mining-drill" and mixed_row.mines == "iron-ore"
    and mixed_row.also["copper-ore"] == 2 and mixed_row.also["crude-oil"] == nil and mixed.on_ore == nil,
    "a drill whose mining area holds copper beside iron reports mixed ore it can mine, never a fluid it cannot")
  -- Resource reads stay on the chart: copper on an uncharted chunk inside a
  -- drill's mining area is not reported, and is once that chunk is charted.
  resources[#resources + 1] = { valid = true, name = "copper-ore", type = "resource", position = { x = 64.5, y = 50.5 } }
  local edge_drill = { anchor = { x = 62, y = 50 }, entities = { { name = "electric-mining-drill", dx = 0.5, dy = 0.5 } } }
  local is_charted_now = character.force.is_chunk_charted
  character.force.is_chunk_charted = function(_, chunk) return chunk.x ~= 2 end
  local unseen = dry(edge_drill)
  character.force.is_chunk_charted = is_charted_now
  local seen = dry(edge_drill)
  resources[#resources] = nil
  check(unseen.ok and unseen.mixed_ore == nil and seen.mixed_ore and seen.mixed_ore[1].also["copper-ore"] == 1,
    "copper on an uncharted chunk under a drill's mining area is never reported; charted, it is")
end

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
check_layout({ check_only = true, site = { near = { x = 10, y = 10 } }, entities = { { name = "stone-furnace", dx = 1, dy = 1 } } })
check_layout({ check_only = true, site = { near = { x = 5, y = 3 }, near_water = true },
  entities = { { name = "offshore-pump", dx = 0.5, dy = 0.5, direction = 12 } } })
dry({ anchor = { x = 100, y = 100 }, entities = { { name = "wooden-chest", dx = 0.5, dy = 0.5 } } })
local same = true
for k, v in pairs(inventory) do if inventory_before[k] ~= v then same = false end end
check(#created == 0 and crafted == 0 and next(storage) == storage_before and same,
  "check_only creates nothing, crafts nothing, and touches no storage or inventory")

-- ------------------------------------------------- site search work budget

-- Every tick of a search stays within its work budget (a candidate started
-- may reach twice the tick share; an uncached ground check costs 4 items for
-- at most two can_place_entity calls and one blocker query), the
-- anchor-independent overlap check runs once, and a dry run takes one tick.
local per_tick_engine = 2 * (2 * layout.WORK_PER_TICK / 4)
local overlap_calls = 0
local real_overlaps = geometry.overlaps
geometry.overlaps = function(a, b) overlap_calls = overlap_calls + 1; return real_overlaps(a, b) end
crowded = true
local chests = {}
for i = 0, 99 do chests[#chests + 1] = { name = "wooden-chest", dx = i % 10 + 0.5, dy = math.floor(i / 10) + 0.5 } end
local big = { site = { near = { x = 10.5, y = 10.5 } }, entities = chests }
local entity_count = #chests
overlap_calls, engine.can_place, engine.find = 0, 0, 0
local search_task = { id = 30, site = big.site, entities = big.entities }
-- tasks.lua runs start and the first tick in one game tick: they share one
-- tick's budget, so the counters are reset only after that first tick.
layout.layout_action.runner.start(search_task)
local worst, ticks, outcome = 0, 0, nil
while not outcome and ticks < 100 do
  outcome = layout.layout_action.runner.tick(search_task)
  worst, ticks = math.max(worst, engine.can_place), ticks + 1
  engine.can_place = 0
end
check(entity_count == 100 and outcome and outcome.status == "failed" and outcome.outcome.failed[1].code == "SITE_NOT_FOUND",
  "a 100-chest layout in a built-up base fails as SITE_NOT_FOUND")
check(worst <= per_tick_engine and ticks <= layout.MAX_WORK / layout.WORK_PER_TICK + 2,
  string.format("the site search spreads over ticks within its budget (worst tick %d placement checks, %d ticks)", worst, ticks))
check(overlap_calls <= 16 * entity_count,
  string.format("layout overlaps are checked once, not per candidate (%d footprint comparisons)", overlap_calls))
-- The dry run is a job with the same per-tick budget: it searches as far as
-- the build would and gives the same definite answer.
local dry_job = layout.layout_check_job.start({ site = big.site, entities = big.entities, check_only = true })
local dry_big, dry_ticks, dry_worst = nil, 0, 0
while not dry_big and dry_ticks < 200 do
  engine.can_place = 0
  dry_big = layout.layout_check_job.step(dry_job, { left = layout.WORK_PER_TICK })
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
check(not walled_route.ok and walled_route.failed[1].code == "ROUTE_BLOCKED" and walled_route.failed[1].connection == 0
  and walled_route.failed[1].reason:match("walled in") and engine.can_place <= per_tick_engine,
  string.format("a walled-in route fails as ROUTE_BLOCKED within one tick's work (%d placement checks)", engine.can_place))
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
local hop_ends = {}
for _, row in ipairs(hopped.belt_ends or {}) do hop_ends[#hop_ends + 1] = row.name end
check(table.concat(hop_ends, " ") == "transport-belt", "a routed underground pair ends no belt run in the dry run")
-- Underground ends in a dry run's belt_ends: an exit's back is closed, and
-- an entrance with no exit in reach (planned, else an own exit) ends its run.
do
  local belt, under = "transport-belt", "underground-belt"
  local closed_back = belt_run({ belt, 4 }, { under, 4, "output" }, { belt, 4 })
  check(closed_back == "900.5:underground-belt 902.5:nothing",
    "a belt facing an underground exit's closed back is an end (" .. closed_back .. ")")
  local dangling = belt_run({ belt, 4 }, { under, 4, "input" })
  check(dangling == "901.5:nothing", "an underground entrance with no exit is its run's end (" .. dangling .. ")")
  local paired = belt_run({ belt, 4 }, { under, 4, "input" }, { "wooden-chest" }, { under, 4, "output" }, { belt, 4 })
  check(paired == "904.5:nothing", "an underground entrance with its exit in reach is no end (" .. paired .. ")")
  blockers = { existing(under, "underground-belt", 903.5, 930.5, 0.8, { direction = 4, belt_to_ground_type = "output" }) }
  local existing_exit = belt_run({ belt, 4 }, { under, 4, "input" })
  check(existing_exit == "", "an underground entrance whose own exit already stands in reach is no end (" .. existing_exit .. ")")
  blockers = {}
end
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
-- A drill is built after the outlet it drops into, never before it: the
-- chests listed last are placed first.
inventory = { ["burner-mining-drill"] = 2, ["wooden-chest"] = 2 }
created = {}
local mine_block = drills_with_chests(nil)
mine_block.id, mine_block.check_only, mine_block.site, mine_block.anchor = 18, nil, nil, { x = 50, y = 50 }
layout.layout_action.runner.start(mine_block)
for _ = 1, 40 do
  result = layout.layout_action.runner.tick(mine_block)
  if result then break end
end
local built_order = {}
for _, args in ipairs(created) do built_order[#built_order + 1] = args.name end
check(#created == 4 and created[1].name == "wooden-chest" and created[2].name == "wooden-chest"
  and created[3].name == "burner-mining-drill" and created[4].name == "burner-mining-drill",
  "a drill's outlet chests are placed before the drills (" .. table.concat(built_order, ", ") .. ")")

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
-- Starter items: an entity's insert map goes in after it is placed.
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
-- item is neither carried nor obtainable now, and names it; a build checks
-- the same before spending anything.
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
local two = check_layout(drills_with_chests({ near = { x = 50.5, y = 50.5 }, on_resource = "iron-ore" }))
local short_drill = two.failed[1]
check(not two.ok and short_drill and short_drill.code == "ITEM_UNOBTAINABLE" and short_drill.item == "burner-mining-drill"
  and short_drill.missing == 1 and short_drill.short.item == "iron-plate" and short_drill.short.missing == 1
  and short_drill.reason:match("needs 1 more iron%-plate") and short_drill.reason:match("no idle own furnace"),
  "a two-drill layout with one drill and 8 of the 9 plates the second needs fails, naming the drill and the plate")
inventory["iron-plate"] = 9
check(check_layout(drills_with_chests({ near = { x = 50.5, y = 50.5 }, on_resource = "iron-ore" })).ok,
  "with the ninth plate the second drill can be crafted: the dry run is ok")
inventory["iron-plate"] = 8
-- A furnace of its own lets the body smelt the ninth plate from gatherable ore.
prototypes.entity["iron-ore"].mineable_properties = { minable = true, products = { { name = "iron-ore" } } }
storage.registry.entries[901] = { entity = { valid = true, prototype = { crafting_categories = { smelting = true } },
  is_crafting = function() return false end, get_inventory = function() return { get_item_count = function() return 0 end } end },
  unit = 901, name = "stone-furnace", type = "furnace", position = { x = 0, y = 0 } }
storage.registry.machines.furnace = { [901] = true }
local supply = require("scripts.actions.supply")
local smeltable = supply.unobtainable(character, { { name = "burner-mining-drill", count = 2 } })
local too_long = supply.unobtainable(character, { { name = "iron-plate", count = 1000 } })[1]
storage.registry.entries[901], storage.registry.machines.furnace = nil, nil
check(too_long and too_long.item == "iron-plate" and too_long.reason:match("would smelt %d+ first"),
  "smelting more than one plan can wait for is short, with a reason that says to get it first")
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
-- The build: nothing fetched, crafted or placed when the layout cannot be had.
local infeasible = drills_with_chests({ near = { x = 50.5, y = 50.5 }, on_resource = "iron-ore" })
infeasible.id, infeasible.check_only = 14, nil
layout.layout_action.runner.start(infeasible)
for _ = 1, 60 do
  result = layout.layout_action.runner.tick(infeasible)
  if result then break end
end
check(result and result.status == "failed" and result.outcome.code == "LAYOUT_CHECK_FAILED"
  and result.outcome.failed[1].code == "ITEM_UNOBTAINABLE" and result.outcome.failed[1].item == "burner-mining-drill"
  and #created == 0 and crafted == 0 and inventory["iron-plate"] == 8 and inventory["burner-mining-drill"] == 1,
  "an infeasible layout build fails before spending the starting kit")
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
-- step, once placements have freed room.
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
supply.register_runner("craft", require("scripts.actions.craft"))
character.get_main_inventory = real_main_inventory
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

-- A layout step ended mid build hands over to its build's nested escape
-- (move_entity's cancelled hook, covered by move_entity_test).
local nested = require("scripts.actions.supply")
nested.register_runner("escape_probe", { start = function() end, tick = function() end,
  cancelled = function(sub, body_only) return { code = "ESCAPE_CANCELLED", from = sub.from, body_only = body_only } end })
local layout_runner = layout.layout_action.runner
local forwarded = layout_runner.cancelled and layout_runner.cancelled({ _plan = { _escape = { type = "escape_probe", from = { x = 3, y = 4 } } } })
check(forwarded and forwarded.code == "ESCAPE_CANCELLED" and forwarded.from.x == 3
  and layout_runner.cancelled({ _search = {} }) == nil
  and layout_runner.cancelled({ _plan = { _escape = { type = "escape_probe", from = { x = 3, y = 4 } } } }, true).body_only == true,
  "a cancelled layout step reports its nested build's escape note, body-only passed on; a search has none")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
