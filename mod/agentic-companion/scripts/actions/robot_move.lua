-- Explicit move_entity robots backend: native cut/rebuild, never teleport,
-- revive, inventory transfer or refund. Solid contents outside modules and
-- external wires are refused before ordering; native blueprints own settings.
local blueprints = require("scripts.blueprints")
local approach = require("scripts.actions.approach")
local geometry = require("scripts.placement_geometry")
local settings = require("scripts.entity_settings")
local M = {}
local TYPES = { ["assembling-machine"] = true, furnace = true, container = true,
  ["logistic-container"] = true, ["solar-panel"] = true, accumulator = true, inserter = true }
local POLL, TIMEOUT = 30, 120 * 60

local function quality(e) return e.quality.name end
local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function bounded(value, left)
  if type(value) ~= "table" then return end
  for _, v in pairs(value) do
    left.n = left.n - 1
    if left.n < 0 then error("MOVE_ROBOT_UNSUPPORTED: blueprint state exceeds 512 fields", 0) end
    bounded(v, left)
  end
end
local function clean(task)
  if task._robot_inventory and task._robot_inventory.valid then task._robot_inventory.destroy() end
  task._robot_inventory = nil
end
local function state(task)
  local e, ghost = task._robot_source, task._robot_ghost
  local built = task._robot_built ~= nil and task._robot_built.valid == true
  return { mode = "robots", phase = task._robot_phase, from = task._robot_from, to = task._to,
    quality = task._robot_quality, source_removed = e ~= nil and not e.valid,
    ghost_pending = ghost ~= nil and ghost.valid, network_id = task._robot_network_id, configuration_from_tick = task._robot_snapshot_tick, native_recovery_verified = task._robot_recovered == true,
    native_build_verified = built, destination_built = built,
    native_requests_may_continue = built and not task._robot_completed,
    source_order_pending = e ~= nil and e.valid and e.to_be_deconstructed() or false }
end
function M.diagnostics(task) return state(task) end
local function result(task, code, detail, moved)
  if moved then task._robot_completed = true end
  local out = state(task)
  out.code, out.moved = code, moved == true
  out.identity_changed = moved == true or nil
  if not moved then M.cancelled(task); out = state(task); out.code, out.moved = code, false end
  clean(task)
  return { status = moved and "done" or "failed", detail = code .. ": " .. detail, outcome = out }
end

local function safe_contents(e, owned)
  if not TYPES[e.type] or not e.minable then error("MOVE_ROBOT_UNSUPPORTED: entity cannot use this native rebuild path", 0) end
  if e.to_be_deconstructed() and not owned then error("MOVE_ROBOT_ALREADY_ORDERED: source has another deconstruction order", 0) end
  local max = e.get_max_inventory_index()
  if max > 16 then error("MOVE_ROBOT_UNSUPPORTED: inventory index exceeds bounded read", 0) end
  local modules = e.get_module_inventory()
  for i = 1, max do
    local inv = e.get_inventory(i)
    if inv then
      if #inv > 128 then error("MOVE_ROBOT_UNSUPPORTED: inventory exceeds 128 slots", 0) end
      if inv ~= modules and not inv.is_empty() then
        error("MOVE_ROBOT_CONTENTS: empty non-module inventories first; native blueprints cannot restore their contents", 0)
      end
    end
  end
  if e.type == "inserter" and e.held_stack.valid_for_read then error("MOVE_ROBOT_CONTENTS: inserter holds an item", 0) end
  if #e.fluidbox > 16 then error("MOVE_ROBOT_UNSUPPORTED: fluidbox count exceeds bounded read", 0) end
  for i = 1, #e.fluidbox do
    if e.fluidbox[i] then error("MOVE_ROBOT_FLUID: nonempty fluidboxes cannot be preserved", 0) end
  end
  if (e.type == "assembling-machine" or e.type == "furnace") and e.crafting_progress > 0 then error("MOVE_ROBOT_CONTENTS: crafting is in progress", 0) end
  local connectors, n = e.get_wire_connectors(false), 0
  for _, connector in pairs(connectors) do
    n = n + 1
    if n > 16 then error("MOVE_ROBOT_UNSUPPORTED: connector count exceeds bounded read", 0) end
    if connector.connection_count > 0 then error("MOVE_ROBOT_WIRES: external wire connections cannot be preserved", 0) end
  end
  if e.type == "logistic-container" then
    local sections = e.get_logistic_sections()
    if sections then
      if sections.sections_count > 8 then error("MOVE_ROBOT_UNSUPPORTED: too many logistic sections", 0) end
      for i = 1, sections.sections_count do
        if sections.get_section(i).filters_count > 32 then error("MOVE_ROBOT_UNSUPPORTED: too many logistic filters", 0) end
      end
    end
  end
end

local function item_counts(inv)
  local out = {}
  if inv then
    if #inv > 128 then error("MOVE_ROBOT_UNSUPPORTED: recovery inventory exceeds 128 slots", 0) end
    for _, row in ipairs(inv.get_contents()) do
      local q = type(row.quality) == "table" and row.quality.name or row.quality or "normal"
      local key = row.name .. "/" .. q
      out[key] = (out[key] or 0) + row.count
    end
  end
  return out
end
local function add_counts(out, rows)
  for key, count in pairs(rows) do out[key] = (out[key] or 0) + count end
end
local function observe_cargo(task)
  task._robot_cargo_proof = task._robot_cargo_proof or {}
  for _, entry in ipairs(task._robot_miners or {}) do
    if not entry.observed and entry.robot.valid then
      local inv = entry.robot.get_inventory(defines.inventory.robot_cargo)
      if #inv > 4 then error("native robot cargo exceeds four bounded slots", 0) end
      local now, gained = item_counts(inv), {}
      for key, count in pairs(now) do
        local n = count - (entry.before[key] or 0)
        if n > 0 and task._robot_modules[key] then gained[key] = n end
      end
      if next(gained) then
        add_counts(task._robot_cargo_proof, gained)
        entry.observed = true
      end
    end
  end
end
function M.observe(task)
  local ok, why = pcall(observe_cargo, task)
  if not ok then task._robot_changed = tostring(why) end
end
local function canonical(row)
  row.entity_number, row.position = 1, { x = 0, y = 0 }
  row.direction, row.quality = row.direction or 0, row.quality or "normal"
  if row.recipe then row.recipe_quality = row.recipe_quality or "normal" end
  return row
end
local function guard(e)
  local out = { name = e.name, quality = quality(e), position = e.position,
    direction = e.direction, settings = settings.read(e) }
  if e.type == "assembling-machine" then
    local recipe, q = e.get_recipe()
    out.recipe, out.recipe_quality = recipe and recipe.name, q and q.name
  end
  local ok, mirror = pcall(function() return e.mirroring end)
  if ok then out.mirror = mirror end
  bounded(out, { n = 512 })
  return out
end
local function positions(proto, position, direction)
  local box = geometry.footprint(proto, position, direction)
  local lt, rb = box.left_top, box.right_bottom
  if rb.x - lt.x > 8 or rb.y - lt.y > 8 then error("MOVE_ROBOT_UNSUPPORTED: footprint exceeds 8 by 8 bounded capture", 0) end
  return { position, { x = lt.x, y = lt.y }, { x = rb.x, y = lt.y },
    { x = lt.x, y = rb.y }, { x = rb.x, y = rb.y } }, box
end
local function networks(c, points)
  local common
  for _, p in ipairs(points) do
    local rows = c.surface.find_logistic_networks_by_construction_area(p, c.force)
    if #rows > 4 then error("MOVE_ROBOT_COVERAGE: coverage evidence exceeds four networks", 0) end
    local covered = {}
    for i = 1, #rows do covered[rows[i].network_id] = rows[i] end
    if not common then common = covered else
      for id in pairs(common) do if not covered[id] then common[id] = nil end end
    end
  end
  return common or {}
end
local function ready(task, c, e)
  local from = positions(task._proto, e.position, e.direction)
  local to = positions(task._proto, task._to, task._direction)
  for _, p in ipairs(to) do from[#from + 1] = p end
  local ids, common = {}, networks(c, from)
  for id in pairs(common) do ids[#ids + 1] = id end
  table.sort(ids)
  local recovered = { name = task._item, quality = task._robot_quality, count = 1 }
  for _, id in ipairs(ids) do
    local net = common[id]
    if net.all_construction_robots > 0 and net.available_construction_robots > 0
      and net.select_drop_point({ stack = recovered, members = "storage" }) then
      local modules = e.get_module_inventory()
      local room = true
      for _, row in ipairs(modules and modules.get_contents() or {}) do
        if not net.select_drop_point({ stack = row, members = "storage" }) then room = false end
      end
      if room then task._robot_network_id = id; return end
    end
  end
  error("MOVE_ROBOT_NOT_READY: both footprints need one shared robot network with available robots and recovery storage", 0)
end

local function capture(task, c, e)
  local area = e.bounding_box
  if c.surface.count_entities_filtered({ area = area, force = c.force, limit = 17 }) > 16 then
    error("MOVE_ROBOT_UNSUPPORTED: source footprint has too many entities", 0)
  end
  task._robot_inventory = task._robot_inventory or game.create_inventory(1)
  local stack = task._robot_inventory[1]
  stack.set_stack({ name = "blueprint", count = 1 })
  local map = stack.create_blueprint({ surface = c.surface, force = c.force, area = area,
    include_entities = true, include_modules = true, include_fuel = false,
    include_trains = false, include_station_names = false, always_include_tiles = false })
  for _, row in ipairs(stack.get_blueprint_entities() or {}) do
    if map[row.entity_number] == e then
      bounded(row, { n = 512 })
      canonical(row)
      if row.wires and next(row.wires) then error("MOVE_ROBOT_WIRES: blueprint has external wires", 0) end
      return row
    end
  end
  error("MOVE_ROBOT_UNSUPPORTED: source is not natively blueprintable", 0)
end

function M.start(task, c, e)
  task._robot_source, task._robot_quality = e, quality(e)
  task._robot_surface, task._robot_force = e.surface, e.force
  task._robot_from = { x = e.position.x, y = e.position.y }
  task._robot_phase = "approach"
  local _, from = positions(task._proto, e.position, e.direction)
  local _, to = positions(task._proto, task._to, task._direction)
  blueprints.area(c, { area = from }, "move_entity robots source")
  blueprints.area(c, { area = to }, "move_entity robots destination")
  safe_contents(e)
  ready(task, c, e)
end

local function tick(task, c)
  if task._robot_phase == "approach" then
    local e = task._robot_source
    if not e.valid then return result(task, "MOVE_SOURCE_GONE", "source disappeared before ordering") end
    local reached = approach.ensure_entity(task, c, e)
    if type(reached) == "table" then clean(task); return reached end
    if reached ~= "ok" then return nil end
    safe_contents(e)
    if quality(e) ~= task._robot_quality or not equal(e.position, task._robot_from) then
      return result(task, "MOVE_SOURCE_CHANGED", "source changed before ordering")
    end
    ready(task, c, e)
    if not geometry.can_place(c, task._proto, task._to, task._direction) then
      return result(task, "MOVE_ROBOT_BLOCKED", "destination became blocked before deconstruction")
    end
    local row = capture(task, c, e)
    task._robot_guard, task._robot_snapshot_tick = guard(e), game.tick
    task._robot_modules = item_counts(e.get_module_inventory())
    task._robot_recovery = item_counts(e.get_module_inventory())
    task._robot_recovery[task._item .. "/" .. task._robot_quality] = 1
    row.direction = task._direction
    task._robot_blueprint = row
    if not e.order_deconstruction(c.force) then return result(task, "MOVE_ROBOT_ORDER_FAILED", "native order was refused") end
    task._robot_ordered, task._robot_phase = true, "deconstruction"
    task._deadline_tick = game.tick + TIMEOUT
  end
  if task._robot_next and game.tick < task._robot_next then return nil end
  task._robot_next = game.tick + POLL
  if game.tick >= task._deadline_tick then
    local out = M.cancelled(task)
    return { status = "failed", detail = "MOVE_ROBOT_TIMEOUT: native work did not complete within 120 seconds",
      outcome = { code = "MOVE_ROBOT_TIMEOUT", moved = false, relocation = out } }
  end
  if task._robot_phase == "deconstruction" then
    local e = task._robot_source
    if e.valid then
      if not e.to_be_deconstructed() then return result(task, "MOVE_ROBOT_ORDER_CANCELLED", "native order was removed") end
      return nil
    end
    if not task._robot_mined or task._robot_changed then
      return result(task, "MOVE_ROBOT_RECOVERY_UNPROVEN", task._robot_changed or "source disappeared without matching native robot recovery")
    end
    local recovered = {}
    add_counts(recovered, task._robot_cargo_proof or {})
    add_counts(recovered, task._robot_buffer)
    if not equal(recovered, task._robot_recovery) then return nil end
    task._robot_recovered = true
    if not geometry.can_place(c, task._proto, task._to, task._direction) then
      return result(task, "MOVE_ROBOT_BLOCKED", "source removed; destination is now blocked")
    end
    local _, destination_area = positions(task._proto, task._to, task._direction)
    blueprints.area(c, { area = destination_area }, "move_entity robots destination")
    local row, stack = task._robot_blueprint, task._robot_inventory[1]
    -- Normalise the captured world position to the blueprint's grid phase.
    local x = task._to.x % 1
    local y = task._to.y % 1
    row.position = { x = x, y = y }
    stack.set_blueprint_entities({ row })
    local ghosts = stack.build_blueprint({ surface = c.surface, force = c.force,
      position = { x = task._to.x - x, y = task._to.y - y },
      build_mode = defines.build_mode.normal, skip_fog_of_war = false, raise_built = true })
    if #ghosts ~= 1 or not ghosts[1].valid then return result(task, "MOVE_ROBOT_GHOST_FAILED", "source removed; ghost submission failed") end
    task._robot_ghost, task._robot_phase = ghosts[1], "construction"
    task._deadline_tick = game.tick + TIMEOUT
    return nil
  end
  if task._robot_ghost.valid then return nil end
  local e = c.surface.find_entity({ name = task._robot_blueprint.name, quality = task._robot_quality }, task._to)
  if not e then return result(task, "MOVE_ROBOT_DESTINATION_GONE", "owned ghost disappeared without a matching entity") end
  if task._robot_built ~= e then return result(task, "MOVE_ROBOT_BUILD_UNPROVEN", "destination retained; native robot construction was not observed") end
  local actual, wanted = capture(task, c, e), task._robot_blueprint
  canonical(wanted)
  local items, actual_items = wanted.items, actual.items
  wanted.items, actual.items = nil, nil
  local matched = equal(actual, wanted)
  wanted.items, actual.items = items, actual_items
  if not matched then return result(task, "MOVE_ROBOT_CONFIGURATION_MISMATCH", "paid destination retained; native settings differ") end
  if not equal(items, actual_items) then task._robot_phase = "module_requests"; return nil end
  return result(task, "MOVED_BY_ROBOTS", "source removed and native destination quality, settings and modules verified", true)
end

function M.tick(task, c)
  M.observe(task)
  local ok, out = pcall(tick, task, c)
  if not ok then M.cancelled(task); return result(task, "MOVE_ROBOT_FAILED", tostring(out)) end
  return out
end
function M.waiting(task) return task._robot_phase ~= "approach" end
function M.cancelled(task)
  local e = task._robot_source
  if task._robot_ordered and e and e.valid then pcall(e.cancel_deconstruction, e.force) end
  local ghost = task._robot_ghost
  if ghost and ghost.valid then pcall(ghost.destroy, { raise_destroy = true }) end
  local out = state(task)
  out.code, out.moved = "MOVE_ROBOT_CANCELLED", false
  clean(task)
  return out
end
-- Native events are evidence only: buffers, robot cargo and entities are
-- never edited. Dispatch is limited to the sole active FIFO step.
function M.on_robot_pre_mined(task, event)
  if event.entity ~= task._robot_source or not task._robot_ordered then return end
  local c = { surface = event.entity.surface, force = event.entity.force }
  local ok, why = pcall(function()
    safe_contents(event.entity, true)
    if not equal(guard(event.entity), task._robot_guard) then error("source identity or guarded configuration changed after ordering", 0) end
    -- Native robots remove modules in a separate pass before mining the building.
    -- Observe that exact robot's cargo delta; never infer a paid recovery from
    -- an empty module inventory or a disappearing entity.
    if event.robot then
      observe_cargo(task)
      task._robot_miners = task._robot_miners or {}
      if #task._robot_miners >= 16 then error("native recovery exceeds 16 observed mining passes", 0) end
      task._robot_miners[#task._robot_miners + 1] = { robot = event.robot,
        before = item_counts(event.robot.get_inventory(defines.inventory.robot_cargo)) }
    end
  end)
  if not ok then task._robot_changed = tostring(why) end
end
function M.on_robot_mined_entity(task, event)
  if event.entity ~= task._robot_source or not task._robot_ordered then return end
  local ok, counts = pcall(item_counts, event.buffer)
  if ok then
    for key, count in pairs(counts) do
      if not task._robot_recovery[key] or count > task._robot_recovery[key] then ok = false end
    end
  end
  if ok and counts[task._item .. "/" .. task._robot_quality] == 1 then
    task._robot_buffer, task._robot_mined = counts, true
  else task._robot_changed = "native recovery buffer does not prove one source building of matching quality" end
end
function M.on_robot_built_entity(task, event)
  local e = event.entity
  if task._robot_phase ~= "construction" or not e or not e.valid then return end
  if e.name == task._robot_blueprint.name and quality(e) == task._robot_quality
    and equal(e.position, task._to) and e.surface == task._robot_surface and e.force == task._robot_force then
    task._robot_built = e
  end
end
return M
