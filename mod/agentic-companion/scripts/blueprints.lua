-- Blueprints: the game's real blueprint items, held by the mod in a script
-- inventory (storage.blueprints.inventory, made by game.create_inventory in
-- state.init) and indexed by name. They belong to this run: nothing is
-- imported, and export is a string for the notebook only.
--
--   capture  {name, area | center+radius}: own entities in a charted area
--            (LuaItemStack.create_blueprint); the world is only read.
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

-- Width and height in tiles of what a blueprint's entities cover.
local function size_of(entities)
  local min_x, min_y, max_x, max_y
  for _, e in ipairs(entities) do
    local w, h = prototype_size(e.name, e.direction)
    local x, y = e.position.x, e.position.y
    min_x, max_x = math.min(min_x or x - w / 2, x - w / 2), math.max(max_x or x + w / 2, x + w / 2)
    min_y, max_y = math.min(min_y or y - h / 2, y - h / 2), math.max(max_y or y + h / 2, y + h / 2)
  end
  if not min_x then return { w = 0, h = 0 } end
  return { w = math.ceil(max_x - min_x - 0.01), h = math.ceil(max_y - min_y - 0.01) }
end

-- {left_top, right_bottom} from area | center+radius, at most MAX_SIDE a side,
-- every chunk under it charted by the body's force.
function M.area(c, params, label)
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
  local ok, networks = pcall(c.surface.find_logistic_networks_by_construction_area, position, c.force)
  local robots = 0
  for _, network in ipairs(ok and networks or {}) do
    local ok_count, n = pcall(function() return network.all_construction_robots end)
    if ok_count and type(n) == "number" then robots = robots + n end
  end
  return robots
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

local function summary(c, name, stack, entry)
  return { name = name, entities = entry.entities, tiles = entry.tiles, size = entry.size,
    wires = entry.wires > 0 and entry.wires or nil, cost = cost_of(stack),
    tool_unlock = M.tool_unlock(c, "blueprint") }
end

-- Moves the finished scratch blueprint to its named slot.
local function store(c, name, label, source, built)
  local slot = slot_for(name, label)
  local stack = inventory()[slot]
  stack.set_stack(built)
  built.clear()
  pcall(function() stack.label = name end)
  local entry = meta(stack, source)
  entry.slot = slot
  data().by_name[name] = entry
  log(source, name, { entities = entry.entities })
  return summary(c, name, stack, entry)
end

-- ------------------------------------------------------------------ capture

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
    return store(c, job.name, "blueprint_capture", "capture", built)
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

function M.create(params)
  local c = companion.require_companion()
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
      source = entry.source, created_tick = entry.created_tick }
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return { blueprints = rows, capacity = capacity(),
    tool_unlock = M.tool_unlock(companion.require_companion(), "blueprint") }
end

M.describe_job = {
  start = function(params)
    stack_of(params.name, "blueprint_describe")
    return { name = params.name }
  end,
  step = function(job, budget)
    local c = companion.require_companion()
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

-- A blueprint entity flipped about the blueprint's centre (before any turn).
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

-- The stack to build ghosts from: the stored blueprint, or a flipped copy of
-- it in the scratch slot (tiles flipped too).
function M.build_stack(name, flip, label)
  check_flip(flip, label)
  local stack = stack_of(name, label)
  if not flip then return stack end
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

function M.clear_scratch()
  pcall(function() inventory()[scratch_slot()].clear() end)
end

M._size_of, M._layout_entity, M._flipped = size_of, layout_entity, flipped

return M
