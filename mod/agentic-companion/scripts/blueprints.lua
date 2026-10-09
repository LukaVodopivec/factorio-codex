-- Blueprints: the game's real blueprint items, held by the mod in a script
-- inventory (storage.blueprints.inventory, made by game.create_inventory in
-- state.init) and indexed by name. They belong to this run: nothing is
-- imported, and export is a string for the notebook only.
--
--   capture  {name, area | center+radius}: own entities in a charted area
--            (LuaItemStack.create_blueprint); the world is only read. The
--            engine keeps their world positions; the capture shifts them by
--            an even whole vector, its `origin`, so the block sits about
--            (0, 0): world position = origin + dx/dy.
--   create   {name, entities:[{name, dx, dy, direction?, recipe?, mirror?,
--            settings?}]}: a layout spec set as the blueprint's entities
--            (settings as BlueprintEntity fields), nothing in the world.
--   list, describe {name}, delete {name}, export {name}.
--
-- A blueprint holds at most MAX_ENTITIES entities, so the character can build
-- any of them by hand through build_layout (blueprint_place, area_ops.lua).
-- capture and describe are jobs (jobs.lua): their work counts against the
-- tick's allowance like every other read. Captures, creations and deletions
-- are rows in activity_log.
local companion = require("scripts.companion")
local state = require("scripts.state")
local entity_settings = require("scripts.entity_settings")

local M = {}

M.MAX_ENTITIES = 100
M.MAX_SIDE = 64 -- tiles: a capture or area action covers at most 64 x 64
-- state.BLUEPRINT_SLOTS: the named blueprints, then the scratch slot (a
-- capture or a flipped copy in progress).
local function capacity() return state.BLUEPRINT_SLOTS - 1 end
local function scratch_slot() return state.BLUEPRINT_SLOTS end
local MAX_NAME = 64
-- Work items (jobs.lua): an entity read or written, and the engine's area
-- read per this many tiles.
local TILES_PER_WORK = 64

-- ------------------------------------------------------------- activity log

-- tasks.log_event, set by control.lua (tasks.lua requires this module's
-- users, so it cannot be required here).
local log_event
function M.set_logger(fn) log_event = fn end

local function log(action, name, extra)
  local row = { kind = "blueprint", action = action, name = name, tick = game.tick }
  for k, v in pairs(extra or {}) do row[k] = v end
  if log_event then pcall(log_event, row) end
end

-- ------------------------------------------------------------------ storage

local function data()
  local bp = storage.blueprints
  if not bp then
    bp = { inventory = nil, by_name = {} }
    storage.blueprints = bp
  end
  return bp
end

-- The script inventory; made again if it is gone (its blueprints with it).
local function inventory()
  local bp = data()
  local ok, valid = pcall(function() return bp.inventory and bp.inventory.valid end)
  if not (ok and valid) then
    bp.inventory = game.create_inventory(state.BLUEPRINT_SLOTS)
    bp.by_name = {}
  end
  return bp.inventory
end

local function check_name(name, label)
  if type(name) ~= "string" or name == "" or #name > MAX_NAME or not name:match("^[%w][%w%-_ .]*$") then
    error(label .. " name must be 1-64 letters, digits, spaces, dots, dashes or underscores", 0)
  end
end

-- The stored blueprint's stack, or an error naming what exists.
local function stack_of(name, label)
  check_name(name, label)
  local entry = data().by_name[name]
  local stack = entry and inventory()[entry.slot]
  if not (stack and stack.valid_for_read and stack.is_blueprint_setup()) then
    data().by_name[name] = nil
    local names = {}
    for known in pairs(data().by_name) do names[#names + 1] = known end
    table.sort(names)
    error(string.format("%s: no blueprint called '%s'%s", label, name,
      #names > 0 and (" (stored: " .. table.concat(names, ", ") .. ")") or " (none stored)"), 0)
  end
  return stack, entry
end

-- The slot a new or replaced blueprint goes to.
local function slot_for(name, label)
  local bp = data()
  if bp.by_name[name] then return bp.by_name[name].slot end
  local used = {}
  for _, entry in pairs(bp.by_name) do used[entry.slot] = true end
  for slot = 1, capacity() do if not used[slot] then return slot end end
  error(string.format("%s: %d blueprints are stored; delete one first", label, capacity()), 0)
end

-- A clean blueprint in the scratch slot.
local function scratch()
  local stack = inventory()[scratch_slot()]
  stack.set_stack({ name = "blueprint", count = 1 })
  return stack
end

-- ----------------------------------------------------------------- geometry

local function prototype_size(name, direction)
  local proto = prototypes.entity[name]
  local w, h = tonumber(proto and proto.tile_width) or 1, tonumber(proto and proto.tile_height) or 1
  if (direction or 0) % 8 == 4 then w, h = h, w end
  return w, h
end

-- The box a blueprint's entities cover: min_x, min_y, max_x, max_y (nil
-- when there are none).
local function bounds(entities)
  local min_x, min_y, max_x, max_y
  for _, e in ipairs(entities) do
    local w, h = prototype_size(e.name, e.direction)
    local x, y = e.position.x, e.position.y
    min_x, max_x = math.min(min_x or x - w / 2, x - w / 2), math.max(max_x or x + w / 2, x + w / 2)
    min_y, max_y = math.min(min_y or y - h / 2, y - h / 2), math.max(max_y or y + h / 2, y + h / 2)
  end
  return min_x, min_y, max_x, max_y
end

-- Width and height in tiles of what a blueprint's entities cover.
local function size_of(entities)
  local min_x, min_y, max_x, max_y = bounds(entities)
  if not min_x then return { w = 0, h = 0 } end
  return { w = math.ceil(max_x - min_x - 0.01), h = math.ceil(max_y - min_y - 0.01) }
end

-- {left_top, right_bottom} from area | center+radius, at most MAX_SIDE a side,
-- every chunk under it charted by the body's force. On a platform's surface
-- (the force's own, always readable) nothing is checked for charting.
function M.area(c, params, label, platform_surface)
  local area
  if params.area ~= nil then
    local a = params.area
    local lt, rb = type(a) == "table" and a.left_top, type(a) == "table" and a.right_bottom
    if not (type(lt) == "table" and type(rb) == "table" and type(lt.x) == "number" and type(lt.y) == "number"
      and type(rb.x) == "number" and type(rb.y) == "number" and rb.x > lt.x and rb.y > lt.y) then
      error(label .. " area must be {left_top:{x,y}, right_bottom:{x,y}} with right_bottom below and right of left_top", 0)
    end
    area = { left_top = { x = lt.x, y = lt.y }, right_bottom = { x = rb.x, y = rb.y } }
  else
    local center, radius = params.center, tonumber(params.radius)
    if not (type(center) == "table" and type(center.x) == "number" and type(center.y) == "number"
      and radius and radius > 0) then
      error(label .. " takes area {left_top, right_bottom} or center {x, y} with radius", 0)
    end
    area = { left_top = { x = center.x - radius, y = center.y - radius },
      right_bottom = { x = center.x + radius, y = center.y + radius } }
  end
  local w, h = area.right_bottom.x - area.left_top.x, area.right_bottom.y - area.left_top.y
  if w > M.MAX_SIDE or h > M.MAX_SIDE then
    error(string.format("%s area is %.0f x %.0f tiles; at most %d x %d", label, w, h, M.MAX_SIDE, M.MAX_SIDE), 0)
  end
  if platform_surface then return area end
  for cy = math.floor(area.left_top.y / 32), math.floor((area.right_bottom.y - 0.001) / 32) do
    for cx = math.floor(area.left_top.x / 32), math.floor((area.right_bottom.x - 0.001) / 32) do
      local ok, charted = pcall(c.force.is_chunk_charted, c.surface, { x = cx, y = cy })
      if not (ok and charted) then error(label .. " area reaches uncharted land", 0) end
    end
  end
  return area
end

-- ------------------------------------------------------------ tool unlocks

-- The technology a tool's shortcut names (prototypes.shortcut; base 2.0
-- names construction-robotics for the blueprint, deconstruction and upgrade
-- planners). Script blueprints work without it; reported, never assumed,
-- and the result says the tool is usable meanwhile.
local tool_technology
function M.tool_unlock(c, tool)
  if not tool_technology then
    tool_technology = {}
    for _, shortcut in pairs(prototypes.shortcut or {}) do
      local ok, item, technology = pcall(function()
        local spawn = shortcut.item_to_spawn
        local tech = shortcut.technology_to_unlock
        return spawn and spawn.name, tech and tech.name
      end)
      if ok and item and technology and not tool_technology[item] then tool_technology[item] = technology end
    end
  end
  local technology = tool_technology[tool]
  if not technology then return { tool = tool } end
  local ok, researched = pcall(function() return c.force.technologies[technology].researched end)
  researched = ok and researched == true or false
  return { tool = tool, technology = technology, researched = researched, usable = true,
    note = not researched and ("usable now: the mod works this tool by script, so " .. technology
      .. " is not needed; only construction robots, which build ghosts and carry out orders, wait for it") or nil }
end

-- Construction robots of the networks whose construction area covers the
-- position: who builds ghosts and carries out orders there.
function M.construction_robots(c, position)
  return M.robot_readiness(c, position).construction_robots or 0
end

-- Readiness at an exact target, never inferred from the area centre or the
-- capped nearest-network display. Native robots still decide dispatch and
-- consume stock; these counts are observations, not reservations/promises.
function M.robot_readiness(c, position, item, quality, count)
  local space_ok, platform = pcall(function() return c.surface.platform end)
  if space_ok and platform then
    local row = { mechanism = "platform_hub", counts_complete = true }
    if item then
      local ok_stock, stock = pcall(function()
        return platform.hub.get_inventory(defines.inventory.hub_main).get_item_count({ name = item, quality = quality or "normal" })
      end)
      row.counts_complete = ok_stock and type(stock) == "number"
      row.material = { item = item, quality = quality or "normal", needed = count or 1,
        observed_stock = row.counts_complete and stock or nil, counts_complete = row.counts_complete }
      if row.counts_complete then row.material.can_supply = stock >= (count or 1) end
    end
    return row
  end
  local ok, networks = pcall(c.surface.find_logistic_networks_by_construction_area, position, c.force)
  if not ok or networks == nil then return { coverage = "unknown", counts_complete = false } end
  local total = #networks
  local row = { coverage = total > 0 and "covered" or "uncovered", networks = total,
    construction_robots = 0, available_construction_robots = 0, counts_complete = total <= 4 }
  if total > 4 then row.omitted_networks = total - 4 end
  local stock, can_supply, stock_complete = 0, false, total <= 4
  for i = 1, math.min(total, 4) do
    local network = networks[i]
    local robots_ok, all, available = pcall(function()
      return network.all_construction_robots, network.available_construction_robots
    end)
    if robots_ok and type(all) == "number" then row.construction_robots = row.construction_robots + all
    else row.counts_complete = false end
    if robots_ok and type(available) == "number" then row.available_construction_robots = row.available_construction_robots + available
    else row.counts_complete = false end
    if item then
      local id = { name = item, quality = quality or "normal" }
      local have_ok, have = pcall(network.get_item_count, id)
      local supply_ok, supplied = pcall(network.can_satisfy_request, id, count or 1, true)
      if have_ok and type(have) == "number" then stock = stock + have else stock_complete = false end
      if supply_ok then can_supply = can_supply or supplied == true else stock_complete = false end
    end
  end
  if item then
    local supply = can_supply
    if not can_supply and not stock_complete then supply = nil end
    row.material = { item = item, quality = quality or "normal", needed = count or 1,
      observed_stock = stock, can_supply = supply,
      counts_complete = stock_complete }
  end
  return row
end

-- ---------------------------------------------------------------- reading

local function cost_of(stack)
  local rows = {}
  local ok, cost = pcall(function() return stack.cost_to_build end)
  for _, row in ipairs(ok and cost or {}) do rows[#rows + 1] = { item = row.name, count = row.count } end
  table.sort(rows, function(a, b) return a.item < b.item end)
  return rows
end

-- A blueprint entity as a build_layout entity: {name, dx, dy, direction,
-- recipe?, insert? (its item requests: modules), mirror?, settings?,
-- belt_to_ground_type?}.
local function layout_entity(bp)
  local proto = prototypes.entity[bp.name]
  local kind = proto and proto.type
  local insert
  for _, plan in ipairs(bp.items or {}) do
    local name = plan.id and plan.id.name
    local count = 0
    for _, at in ipairs(plan.items and plan.items.in_inventory or {}) do count = count + (tonumber(at.count) or 1) end
    count = count + (plan.items and tonumber(plan.items.grid_count) or 0)
    if type(name) == "string" and count > 0 then
      insert = insert or {}
      insert[name] = (insert[name] or 0) + count
    end
  end
  return { name = bp.name, dx = bp.position.x, dy = bp.position.y, direction = bp.direction or 0,
    recipe = bp.recipe, insert = insert, mirror = bp.mirror or nil, settings = entity_settings.from_blueprint(bp, kind),
    belt_to_ground_type = kind == "underground-belt" and bp.type or nil }
end

local function wire_count(entities)
  local n = 0
  for _, e in ipairs(entities) do n = n + (type(e.wires) == "table" and #e.wires or 0) end
  return n
end

-- What list keeps per blueprint, read once when it is stored.
local function meta(stack, source)
  local entities = stack.get_blueprint_entities() or {}
  local tiles = stack.get_blueprint_tiles() or {}
  return { entities = #entities, tiles = #tiles, size = size_of(entities), wires = wire_count(entities),
    source = source, created_tick = game.tick }
end

-- origin: a capture's (see normalise); nil for a created blueprint and for
-- a capture stored before 0.34, whose dx/dy are world positions.
local function summary(c, name, stack, entry)
  return { name = name, entities = entry.entities, tiles = entry.tiles, size = entry.size,
    wires = entry.wires > 0 and entry.wires or nil, origin = entry.origin, cost = cost_of(stack),
    tool_unlock = M.tool_unlock(c, "blueprint") }
end

-- Moves the finished scratch blueprint to its named slot.
local function store(c, name, label, source, built, origin)
  local slot = slot_for(name, label)
  local stack = inventory()[slot]
  stack.set_stack(built)
  built.clear()
  pcall(function() stack.label = name end)
  local entry = meta(stack, source)
  entry.slot, entry.origin = slot, origin
  data().by_name[name] = entry
  log(source, name, { entities = entry.entities })
  return summary(c, name, stack, entry)
end

-- ------------------------------------------------------------------ capture

-- create_blueprint keeps world positions. Shifts the entities and tiles by
-- the even whole vector that brings their box's centre within a tile of
-- (0, 0), so dx/dy mean what blueprint_create's do, turns and flips pivot at
-- the block, and the vector (the origin) places it back where it stood. An
-- even shift keeps tile and rail parity; a blueprint already there stays.
-- Returns the origin and the work items it took.
local function normalise(stack)
  local entities = stack.get_blueprint_entities() or {}
  local min_x, min_y, max_x, max_y = bounds(entities)
  if not min_x then return { x = 0, y = 0 }, #entities end
  local ox = 2 * math.floor((min_x + max_x) / 4 + 0.5)
  local oy = 2 * math.floor((min_y + max_y) / 4 + 0.5)
  if ox == 0 and oy == 0 then return { x = 0, y = 0 }, #entities end
  for _, e in ipairs(entities) do e.position = { x = e.position.x - ox, y = e.position.y - oy } end
  stack.set_blueprint_entities(entities)
  local tiles = stack.get_blueprint_tiles() or {}
  if #tiles > 0 then
    for _, t in ipairs(tiles) do t.position = { x = t.position.x - ox, y = t.position.y - oy } end
    stack.set_blueprint_tiles(tiles)
  end
  return { x = ox, y = oy }, 2 * #entities + #tiles
end

M.capture_job = {
  start = function(params)
    local c = companion.require_companion()
    check_name(params.name, "blueprint_capture")
    local area = M.area(c, params, "blueprint_capture")
    slot_for(params.name, "blueprint_capture")
    return { name = params.name, area = area }
  end,
  step = function(job, budget)
    local c = companion.require_companion()
    local area = job.area
    -- Counted first (bounded by its limit), so a dense area is refused
    -- before the engine builds a blueprint of all of it. The body is own
    -- but never captured.
    local counted = c.surface.count_entities_filtered({ area = area, force = c.force, limit = M.MAX_ENTITIES + 2 })
    local p = c.position
    if p.x >= area.left_top.x and p.x <= area.right_bottom.x and p.y >= area.left_top.y and p.y <= area.right_bottom.y then
      counted = counted - 1
    end
    budget.left = budget.left - 1
    if counted > M.MAX_ENTITIES then
      error(string.format("blueprint_capture: the area holds more than %d entities; a blueprint takes at most %d"
        .. " (capture a smaller area)", M.MAX_ENTITIES, M.MAX_ENTITIES), 0)
    end
    local built = scratch()
    built.create_blueprint({ surface = c.surface, force = c.force, area = area, always_include_tiles = false,
      include_entities = true, include_modules = true, include_station_names = false, include_trains = false,
      include_fuel = false })
    local count = built.is_blueprint_setup() and built.get_blueprint_entity_count() or 0
    local tiles = (area.right_bottom.x - area.left_top.x) * (area.right_bottom.y - area.left_top.y)
    budget.left = budget.left - count - math.ceil(tiles / TILES_PER_WORK)
    if count == 0 then
      built.clear()
      error("blueprint_capture: no own entities stand in that area", 0)
    end
    if count > M.MAX_ENTITIES then
      built.clear()
      error(string.format("blueprint_capture: the area holds %d entities; a blueprint takes at most %d (capture a smaller area)",
        count, M.MAX_ENTITIES), 0)
    end
    local origin, work = normalise(built)
    budget.left = budget.left - work
    return store(c, job.name, "blueprint_capture", "capture", built, origin)
  end,
}

-- ------------------------------------------------------------------- create

-- The entity a layout name places (an item or entity name).
local function entity_name(name)
  local item = prototypes.item[name]
  if item and item.place_result then return item.place_result.name, item.place_result end
  local entity = prototypes.entity[name]
  if entity then return entity.name, entity end
end

-- Made from a list, it needs no body on any surface: the body's force in
-- every state but absent (aboard and in transit too).
function M.create(params)
  local c = companion.require_present()
  check_name(params.name, "blueprint_create")
  local list = params.entities
  if type(list) ~= "table" or #list < 1 or #list > M.MAX_ENTITIES then
    error(string.format("blueprint_create entities must be 1-%d placements", M.MAX_ENTITIES), 0)
  end
  local entities = {}
  for i, e in ipairs(list) do
    local label = string.format("blueprint_create entities[%d]", i - 1)
    if type(e) ~= "table" or type(e.name) ~= "string" or type(e.dx) ~= "number" or type(e.dy) ~= "number" then
      error(label .. " must be {name, dx, dy, direction?, recipe?, mirror?, settings?}", 0)
    end
    if e.mirror ~= nil and type(e.mirror) ~= "boolean" then error(label .. ".mirror must be true or false", 0) end
    local d = e.direction
    if d ~= nil and (type(d) ~= "number" or d % 1 ~= 0 or d < 0 or d > 15) then error(label .. ".direction must be an integer 0-15", 0) end
    local name, proto = entity_name(e.name)
    if not name then error(label .. ": no entity called '" .. e.name .. "'", 0) end
    local row = { entity_number = i, name = name, position = { x = e.dx, y = e.dy } }
    if d and d ~= 0 then row.direction = d end
    if e.recipe ~= nil then
      if type(e.recipe) ~= "string" or not c.force.recipes[e.recipe] then error(label .. ": unknown recipe " .. tostring(e.recipe), 0) end
      if proto.type ~= "assembling-machine" then error(label .. ": a " .. name .. " takes no recipe", 0) end
      row.recipe = e.recipe
    end
    if e.mirror then row.mirror = true end
    if e.settings ~= nil then
      entity_settings.validate(e.settings, label .. ".settings")
      local _, refused = entity_settings.check_prototype(proto, e.settings)
      if refused then error(label .. ": " .. refused, 0) end
      entity_settings.to_blueprint(e.settings, row, proto.type)
    end
    entities[i] = row
  end
  slot_for(params.name, "blueprint_create")
  local built = scratch()
  built.set_blueprint_entities(entities)
  local count = built.is_blueprint_setup() and built.get_blueprint_entity_count() or 0
  if count ~= #entities then
    built.clear()
    error(string.format("blueprint_create: the game kept %d of %d entities (overlapping or unknown placements?)",
      count, #entities), 0)
  end
  return store(c, params.name, "blueprint_create", "create", built)
end

-- ----------------------------------------------------------------- reading

function M.list()
  local rows = {}
  for name, entry in pairs(data().by_name) do
    rows[#rows + 1] = { name = name, entities = entry.entities, tiles = entry.tiles, size = entry.size,
      source = entry.source, created_tick = entry.created_tick, origin = entry.origin }
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return { blueprints = rows, capacity = capacity(),
    tool_unlock = M.tool_unlock(companion.require_present(), "blueprint") }
end

M.describe_job = {
  start = function(params)
    stack_of(params.name, "blueprint_describe")
    return { name = params.name }
  end,
  step = function(job, budget)
    local c = companion.require_present()
    local stack, entry = stack_of(job.name, "blueprint_describe")
    local entities = stack.get_blueprint_entities() or {}
    budget.left = budget.left - #entities
    local rows = {}
    for i, e in ipairs(entities) do
      local row = layout_entity(e)
      if row.direction == 0 then row.direction = nil end
      rows[i] = row
    end
    local out = summary(c, job.name, stack, entry)
    out.entities, out.entity_count = rows, #rows
    return out
  end,
}

function M.delete(params)
  stack_of(params.name, "blueprint_delete").clear()
  data().by_name[params.name] = nil
  log("delete", params.name)
  return { deleted = params.name, stored = M.count() }
end

-- A string for the notebook; it is never imported back.
function M.export(params)
  local stack = stack_of(params.name, "blueprint_export")
  return { name = params.name, blueprint_string = stack.export_stack(),
    note = "for notes only: blueprints are not imported" }
end

function M.count()
  local n = 0
  for _ in pairs(data().by_name) do n = n + 1 end
  return n
end

function M.entity_count(name)
  local entry = type(name) == "string" and data().by_name[name]
  return entry and entry.entities or nil
end

-- ---------------------------------------------------------- transformation

-- Entities whose shape is not symmetric about their direction: a flip
-- mirrors them.
local MIRRORABLE = { ["assembling-machine"] = true, furnace = true, boiler = true, generator = true,
  ["mining-drill"] = true, ["offshore-pump"] = true, pump = true, ["storage-tank"] = true }
local SWAP = { left = "right", right = "left" }

local function check_flip(flip, label)
  if flip ~= nil and flip ~= "horizontal" and flip ~= "vertical" then
    error(label .. ' flip must be "horizontal" or "vertical"', 0)
  end
end
M.check_flip = check_flip

-- A blueprint entity flipped about dx/dy (0, 0), the centre of a captured
-- block (before any turn).
local function flipped(e, flip)
  local out = {}
  for k, v in pairs(e) do out[k] = v end
  local d = e.direction or 0
  if flip == "horizontal" then
    out.position = { x = -e.position.x, y = e.position.y }
    out.direction = (16 - d) % 16
  else
    out.position = { x = e.position.x, y = -e.position.y }
    out.direction = (8 - d) % 16
  end
  local proto = prototypes.entity[e.name]
  if proto and MIRRORABLE[proto.type] then out.mirror = not e.mirror or nil end
  out.input_priority, out.output_priority = SWAP[e.input_priority] or e.input_priority, SWAP[e.output_priority] or e.output_priority
  return out
end

-- The blueprint as a build_layout layout ({entities}), flipped if asked.
-- Raises when there is no such blueprint.
function M.layout(name, flip, label)
  check_flip(flip, label or "blueprint")
  local stack = stack_of(name, label or "blueprint")
  local entities = {}
  for i, e in ipairs(stack.get_blueprint_entities() or {}) do
    entities[i] = layout_entity(flip and flipped(e, flip) or e)
  end
  return { entities = entities }
end

-- Body construction has a smaller settings vocabulary than a native ghost.
-- Refuse blueprint content it would otherwise silently discard.
local HAND_FIELDS = { entity_number = true, name = true, position = true, direction = true,
  recipe = true, recipe_quality = true, mirror = true, type = true, items = true, quality = true, wires = true,
  bar = true, filters = true, filter_mode = true, use_filters = true, override_stack_size = true,
  spoil_priority = true, input_priority = true, output_priority = true, filter = true,
  ["chunk-filter"] = true, use_transitional_requests = true }
-- Copper wires between two electric poles of the blueprint are left to the
-- poles' own connection when they are built (wires_ignored counts them);
-- any other wire (circuit, or a power switch's copper, which never
-- connects by itself) refuses hand placement.
local function wire_refusal(wire, poles)
  local copper = defines.wire_connector_id and defines.wire_connector_id.pole_copper
  if type(wire) ~= "table" or copper == nil or wire[2] ~= copper or wire[4] ~= copper then return "circuit wires" end
  if not (poles[wire[1]] and poles[wire[3]]) then return "power-switch wires" end
  return nil
end

function M.hand_layout(name, flip, label)
  local stack = stack_of(name, label)
  if stack.blueprint_snap_to_grid or #(stack.get_blueprint_tiles() or {}) > 0 then
    error(label .. ": hand placement cannot preserve blueprint tiles or grid snapping; use native ghosts", 0)
  end
  local function normal(filter)
    return type(filter) ~= "table" or ((not filter.quality or filter.quality == "normal")
      and (not filter.comparator or filter.comparator == "="))
  end
  local entities = stack.get_blueprint_entities() or {}
  local poles, ignored, seen = {}, 0, {}
  for _, e in ipairs(entities) do
    local proto = prototypes.entity[e.name]
    if proto and proto.type == "electric-pole" and e.entity_number then poles[e.entity_number] = true end
  end
  for _, e in ipairs(entities) do
    for key in pairs(e) do
      if not HAND_FIELDS[key] then error(label .. ": hand placement cannot preserve blueprint field " .. key .. "; use native ghosts", 0) end
    end
    for _, wire in ipairs(e.wires or {}) do
      local why = wire_refusal(wire, poles)
      if why then error(label .. ": hand placement cannot preserve blueprint " .. why .. "; use native ghosts", 0) end
      -- A wire may be listed at both of its ends: counted once.
      local a, b = wire[1] .. ":" .. wire[2], wire[3] .. ":" .. wire[4]
      local key = a < b and a .. "|" .. b or b .. "|" .. a
      if not seen[key] then seen[key], ignored = true, ignored + 1 end
    end
    if (e.quality and e.quality ~= "normal")
      or (e.recipe_quality and e.recipe_quality ~= "normal") or not normal(e.filter) then
      error(label .. ": hand placement cannot preserve blueprint quality; use native ghosts", 0)
    end
    for i, filter in ipairs(e.filters or {}) do
      if not normal(filter) or filter.index ~= i then
        error(label .. ": hand placement cannot preserve blueprint filter quality or sparse slots; use native ghosts", 0)
      end
    end
    for _, request in ipairs(e.items or {}) do
      if (request.id.quality and request.id.quality ~= "normal") or (request.items and request.items.grid_count) then
        error(label .. ": hand placement cannot preserve blueprint item quality or equipment; use native ghosts", 0)
      end
    end
  end
  local layout = M.layout(name, flip, label)
  layout.wires_ignored = ignored > 0 and ignored or nil
  return layout
end

-- Platform ghosts use the same checked foundation path as build_layout.
-- Keep native settings and insert plans; reject features that path cannot
-- preserve before issuing any construction. Planet ghosts use the native
-- blueprint stack, including its wires and grid settings.
local PLATFORM_FIELDS = { entity_number = true, name = true, position = true, direction = true,
  recipe = true, recipe_quality = true, mirror = true, type = true, items = true, quality = true,
  wires = true, tags = true, control_behavior = true, bar = true, filters = true, filter_mode = true, request_filters = true,
  use_filters = true, override_stack_size = true, spoil_priority = true, filter = true,
  input_priority = true, output_priority = true, ["chunk-filter"] = true }
function M.platform_layout(name, flip, quarters, label)
  if stack_of(name, label).blueprint_snap_to_grid then
    error(label .. ": platform placement cannot preserve blueprint grid snapping", 0)
  end
  local stack = M.build_stack(name, flip, label)
  local ok, result = pcall(function()
    local entities, tiles = stack.get_blueprint_entities() or {}, stack.get_blueprint_tiles() or {}
    if #entities > M.MAX_ENTITIES or #tiles > 400 then error(label .. ": platform blueprint exceeds the layout work bounds", 0) end
    local layout = { entities = {}, tiles = {} }
    local function turn(x, y)
      for _ = 1, quarters do x, y = -y, x end
      return x, y
    end
    for i, e in ipairs(entities) do
      for key in pairs(e) do
        if not PLATFORM_FIELDS[key] then error(label .. ": platform placement cannot preserve blueprint field " .. key, 0) end
      end
      if e.wires and #e.wires > 0 then error(label .. ": platform placement cannot preserve blueprint wires", 0) end
      if (e.quality and e.quality ~= "normal") or (e.recipe_quality and e.recipe_quality ~= "normal") then
        error(label .. ": platform placement currently requires normal entity and recipe quality", 0)
      end
      local requests = e.items or {}
      if #requests > 8 then error(label .. ": at most 8 insert plans per platform blueprint entity", 0) end
      for _, request in ipairs(requests) do
        if #(request.items and request.items.in_inventory or {}) > 32 then
          error(label .. ": platform blueprint insert plan exceeds 32 inventory slots", 0)
        end
      end
      local row, raw = layout_entity(e), {}
      row.dx, row.dy = turn(row.dx, row.dy)
      row.direction = ((row.direction or 0) + 4 * quarters) % 16
      row.insert = nil -- native requests, never starter items from the body
      for key, value in pairs(e) do
        if key ~= "entity_number" and key ~= "name" and key ~= "position" and key ~= "direction"
          and key ~= "wires" and key ~= "items" then raw[key] = value end
      end
      row._blueprint, row._insert_plan = raw, e.items
      layout.entities[i] = row
    end
    for i, tile in ipairs(tiles) do
      local x, y = turn(tile.position.x + 0.5, tile.position.y + 0.5)
      layout.tiles[i] = { name = tile.name, dx = x - 0.5, dy = y - 0.5 }
    end
    return layout
  end)
  if flip then M.clear_scratch() end
  if not ok then error(result, 0) end
  return result
end

-- The stack to build ghosts from: the stored blueprint, or a flipped copy of
-- it in the scratch slot (tiles flipped too).
function M.build_stack(name, flip, label)
  check_flip(flip, label)
  local stack = stack_of(name, label)
  if not flip then return stack end
  if stack.blueprint_snap_to_grid then
    error(label .. ": flipped placement cannot preserve blueprint grid snapping", 0)
  end
  local entities, tiles = {}, {}
  for i, e in ipairs(stack.get_blueprint_entities() or {}) do entities[i] = flipped(e, flip) end
  for i, t in ipairs(stack.get_blueprint_tiles() or {}) do
    local p = t.position
    tiles[i] = { name = t.name, position = flip == "horizontal" and { x = -p.x - 1, y = p.y } or { x = p.x, y = -p.y - 1 } }
  end
  local copy = scratch()
  copy.set_blueprint_entities(entities)
  if #tiles > 0 then copy.set_blueprint_tiles(tiles) end
  return copy
end

-- The blueprint for native ghosts that land where hand and platform
-- placement put them: each entity at anchor + its dx/dy, flipped about
-- (0, 0) if asked, then turned `quarters` clockwise about (0, 0). Unsnapped,
-- build_blueprint centres the blueprint's box on its position and turns it
-- about that centre, up to a tile away from dx/dy (live suite). So the copy in
-- the scratch slot is pre-turned, starts at its box's top-left tile and snaps
-- absolutely to a 1 x 1 grid, as build_layout's ghost batches build: built at
-- anchor + `cell` with direction 0. A blueprint with its own grid snapping
-- keeps the native placement (cell nil). Callers clear the scratch slot.
function M.ghost_stack(name, flip, quarters, label)
  local stored = stack_of(name, label)
  if stored.blueprint_snap_to_grid then return M.build_stack(name, flip, label), nil end
  check_flip(flip, label)
  local function turn(x, y)
    for _ = 1, quarters do x, y = -y, x end
    return x, y
  end
  local entities, tiles = {}, {}
  for i, e in ipairs(stored.get_blueprint_entities() or {}) do
    local out = {}
    if flip then out = flipped(e, flip) else for k, v in pairs(e) do out[k] = v end end
    local x, y = turn(out.position.x, out.position.y)
    out.position = { x = x, y = y }
    if out.direction or quarters > 0 then out.direction = ((out.direction or 0) + 4 * quarters) % 16 end
    entities[i] = out
  end
  for i, t in ipairs(stored.get_blueprint_tiles() or {}) do
    local x, y = t.position.x, t.position.y
    if flip == "horizontal" then x = -x - 1 elseif flip == "vertical" then y = -y - 1 end
    x, y = turn(x + 0.5, y + 0.5)
    tiles[i] = { name = t.name, position = { x = x - 0.5, y = y - 0.5 } }
  end
  local left, top = bounds(entities)
  for _, t in ipairs(tiles) do
    left, top = math.min(left or t.position.x, t.position.x), math.min(top or t.position.y, t.position.y)
  end
  local cell = { x = math.floor((left or 0) + 0.01), y = math.floor((top or 0) + 0.01) }
  for _, row in ipairs(entities) do row.position = { x = row.position.x - cell.x, y = row.position.y - cell.y } end
  for _, row in ipairs(tiles) do row.position = { x = row.position.x - cell.x, y = row.position.y - cell.y } end
  local copy = scratch()
  if #entities > 0 then copy.set_blueprint_entities(entities) end
  if #tiles > 0 then copy.set_blueprint_tiles(tiles) end
  copy.blueprint_snap_to_grid = { x = 1, y = 1 }
  copy.blueprint_absolute_snapping = true
  copy.blueprint_position_relative_to_grid = { x = 0, y = 0 }
  return copy, cell
end

-- A clean blueprint in the scratch slot, for a blueprint built and placed in
-- the same tick (build_layout ghosts); clear_scratch empties it again.
M.scratch = scratch

function M.clear_scratch()
  pcall(function() inventory()[scratch_slot()].clear() end)
end

M._size_of, M._layout_entity, M._flipped = size_of, layout_entity, flipped

return M
