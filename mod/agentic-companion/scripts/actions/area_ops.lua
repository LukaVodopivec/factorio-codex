-- Plan actions over blueprints and areas. Hand modes are the character's own
-- work (walking, reach, inventory, mining time); robot modes are orders for
-- construction robots, which never give free items. Each tick does at most
-- one physical act, or at most ORDERS_PER_TICK robot orders.
--
--   blueprint_place {name, position, direction?, flip?, mode: hand | ghosts,
--     platform?}
--     hand:   the stored blueprint as a build_layout at position (auto-supply,
--             auto-clear, recipes, settings, starter items, poles wire up;
--             wires_ignored counts the pole copper wires left to that);
--     ghosts: LuaItemStack.build_blueprint places ghosts for robots, each at
--             position + its turned dx/dy as by hand (blueprints.ghost_stack);
--             a partial placement lists the entities with no ghost
--             (missing_ghosts, with what stands there);
--     platform (ghosts only, remote: no body): position is relative to the
--             platform's hub, and the hub builds the ghosts.
--     As an RPC it is the check_only dry run (place_check_job).
--   build_ghosts {area | center+radius}: the character builds own ghosts by
--     hand from its inventory, reviving each so its settings apply.
--   deconstruct_area {area | center+radius, mode: hand | robots | cancel,
--     filter?, platform?}: hand mines each own entity (and trees and rocks);
--     on a platform (robots or cancel only, remote: no body) the area is on
--     its surface and the hub carries the orders out, its items back to it.
--   upgrade_area {area | center+radius, from, to, mode: hand | robots}: hand
--     fast-replaces same-footprint entities in place (direction and recipe
--     kept); anything else is reported, to be mined and placed instead.
--   copy_settings {from, to:[...]}: LuaEntity.copy_settings, within reach.
local companion = require("scripts.companion")
local registry = require("scripts.registry")
local blueprints = require("scripts.blueprints")
local approach = require("scripts.actions.approach")
local placement_geometry = require("scripts.placement_geometry")
local surfaces = require("scripts.surfaces")
local build = require("scripts.actions.build")
local build_layout = require("scripts.actions.build_layout")
local supply = require("scripts.actions.supply")
local craft = require("scripts.actions.craft")
local platforms = require("scripts.platforms")
local items = require("scripts.items")

local M = {}

local MAX_AREA_ENTITIES = 300 -- entities one area action reads
local MAX_GHOSTS = 100
local ORDERS_PER_TICK = 50
local MAX_ROWS = 10           -- failure rows listed in a result
local MAX_PICKED_ROWS = 32    -- ground stacks taken up, listed in a result
-- The dry-run survey rows a hand or planet-ghost blueprint_place check reports.
local SURVEYED = { on_ore = true, mixed_ore = true, open_fluid_ports = true, fluid_mixes = true, belt_joins = true, port_fluids = true }
local MAX_TARGETS = 32
local NATURAL_TYPES = { "tree", "simple-entity", "plant" } -- natural entities the body may clear
-- Own-force entities that are never mined by an area action.
local NEVER = { character = true, ["entity-ghost"] = true, ["tile-ghost"] = true, ["item-request-proxy"] = true,
  ["item-entity"] = true, ["deconstructible-tile-proxy"] = true, ["character-corpse"] = true,
  ["space-platform-hub"] = true, ["cargo-pod"] = true }

-- A platform step names its platform; the body never goes there.
local function check_platform(step, label, modes, named)
  if step.platform == nil then return end
  platforms.check_selector(step.platform, label .. " platform")
  if step.mode ~= nil and not modes[step.mode] then
    error(string.format("NO_BODY_ON_SURFACE: %s on a platform takes mode %s: the body is not there", label, named), 0)
  end
end

local plain = require("scripts.errors").plain

local function point(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

local function row(e) return { name = e.name, x = e.position.x, y = e.position.y } end

local function add_failure(task, e, reason)
  task._failed_count = (task._failed_count or 0) + 1
  task._failed = task._failed or {}
  if #task._failed < MAX_ROWS then
    -- A LuaEntity is userdata in 2.0; a plain {name, position} is a table.
    local live = type(e) == "table" or type(e) == "userdata" and e.valid
    local r = live and e.name and e.position and row(e) or {}
    r.reason = reason
    task._failed[#task._failed + 1] = r
    return r
  end
end

-- Queue-time shape checks for area | center+radius (the chart check runs at
-- start, with the body's force).
-- A refusal leads with AREA_INVALID.
local function validate_area(step, label)
  if step.area == nil and not (point(step.center) and type(step.radius) == "number" and step.radius > 0) then
    error("AREA_INVALID: " .. label .. " takes area {left_top, right_bottom} or center {x, y} with radius", 0)
  end
  local area = step.area
  if area ~= nil and not (type(area) == "table" and point(area.left_top) and point(area.right_bottom)
    and area.right_bottom.x > area.left_top.x and area.right_bottom.y > area.left_top.y) then
    error("AREA_INVALID: " .. label .. " area must be {left_top:{x,y}, right_bottom:{x,y}}"
      .. " with right_bottom below and right of left_top", 0)
  end
end

local function area_params(step) return { area = step.area, center = step.center, radius = step.radius } end

local function centre_of(area)
  return { x = (area.left_top.x + area.right_bottom.x) / 2, y = (area.left_top.y + area.right_bottom.y) / 2 }
end

-- The entity a name places: an item or entity name -> entity name, prototype
-- and the item that places it.
local function placeable(name)
  local item = prototypes.item[name]
  if item and item.place_result then return item.place_result.name, item.place_result, name end
  local proto = prototypes.entity[name]
  if not proto then return nil end
  local ok, items = pcall(function() return proto.items_to_place_this end)
  local first = ok and type(items) == "table" and items[1] or nil
  local item_name = type(first) == "string" and first or type(first) == "table" and first.name or nil
  return proto.name, proto, item_name
end

-- The nearest still-valid entry of list (entries {entity}) to the body;
-- invalid ones are dropped. Linear in what is left.
local function nearest(c, list)
  local best, best_d, best_i
  local i = 1
  while i <= #list do
    local e = list[i].entity
    if not (e and e.valid) then
      table.remove(list, i)
    else
      local dx, dy = e.position.x - c.position.x, e.position.y - c.position.y
      local d = dx * dx + dy * dy
      if not best or d < best_d then best, best_d, best_i = list[i], d, i end
      i = i + 1
    end
  end
  if best then table.remove(list, best_i) end
  return best
end

local function finish(task, status, code, detail, extra)
  local outcome = { code = code, failed = task._failed, failed_count = task._failed_count }
  for k, v in pairs(extra or {}) do outcome[k] = v end
  if task._failed and task._failed[1] then detail = detail .. " — first failure: " .. tostring(task._failed[1].reason) end
  return { status = status, detail = detail, outcome = outcome }
end

-- --------------------------------------------------------- blueprint_place

local function validate_place(step, label)
  if type(step.name) ~= "string" or step.name == "" then error(label .. " needs name = a stored blueprint", 0) end
  if not point(step.position) then error(label .. " needs position = {x, y}", 0) end
  local d = step.direction
  if d ~= nil and (type(d) ~= "number" or d % 4 ~= 0 or d < 0 or d > 12) then
    error(label .. " direction must be 0, 4, 8 or 12 (the blueprint turned clockwise)", 0)
  end
  blueprints.check_flip(step.flip, label)
  if step.mode ~= nil and step.mode ~= "hand" and step.mode ~= "ghosts" then
    error(label .. ' mode must be "hand" or "ghosts"', 0)
  end
  check_platform(step, label, { ghosts = true }, "ghosts")
end

local function anchor_of(position)
  return { x = math.floor(position.x + 0.5), y = math.floor(position.y + 0.5) }
end

-- The blueprint as a layout at the requested turn.
local function placed_layout(task, label)
  local layout = task.mode == "ghosts" and blueprints.layout(task.name, task.flip, label)
    or blueprints.hand_layout(task.name, task.flip, label)
  return build_layout._rotated(layout, math.floor((task.direction or 0) / 4))
end

local Place = {}

-- A platform placement: its hub and the absolute anchor (position is
-- relative to the hub).
local function platform_anchor(c, task)
  local space = build_layout.platform_space(c, task.platform)
  local hub = space.hub_position
  return space, anchor_of({ x = hub.x + task.position.x, y = hub.y + task.position.y })
end

-- A platform step needs only a connected body (aboard or in transit too):
-- its window reads the force; a planet step needs the character.
local function actor(platform)
  if platform ~= nil then return companion.require_present() end
  return companion.require_companion()
end

function Place.start(task)
  local c = actor(task.platform)
  local label = "blueprint_place " .. tostring(task.name)
  validate_place(task, label)
  if task.platform ~= nil then
    local space
    space, task._anchor = platform_anchor(c, task)
    task.mode, task._platform = "ghosts", { index = space.platform, name = space.name }
    local layout = blueprints.platform_layout(task.name, task.flip, math.floor((task.direction or 0) / 4), label)
    local nested = { id = task.id, anchor = { x = task._anchor.x - space.hub_position.x,
      y = task._anchor.y - space.hub_position.y }, entities = layout.entities, tiles = layout.tiles,
      connections = {}, mode = "ghosts", platform = task._platform.index }
    build_layout.validate_layout(nested, label)
    build_layout.layout_action.runner.start(nested)
    task._layout = nested
    return
  end
  task.mode = task.mode or "hand"
  task._anchor = anchor_of(task.position)
  if task.mode == "hand" then
    local layout = placed_layout(task, label)
    -- Pole copper wires the poles' own connection remakes (blueprints.hand_layout).
    task._wires_ignored = layout.wires_ignored
    local nested = { id = task.id, anchor = task._anchor, entities = layout.entities, connections = {} }
    build_layout.validate_layout(nested, label)
    build_layout.layout_action.runner.start(nested)
    task._layout = nested
  else
    -- Ghosts go only on charted land.
    blueprints.area(c, { center = task._anchor, radius = 0.5 }, label)
    blueprints.layout(task.name, task.flip, label)
  end
end

function Place.resume(task)
  if task._layout then build_layout.layout_action.runner.resume(task._layout) end
end

-- Ended mid build: the nested layout's escape puts its entity back or names it.
function Place.cancelled(task, body_only)
  if task._layout then return build_layout.layout_action.runner.cancelled(task._layout, body_only) end
end

local function ghost_key(name, x, y) return string.format("%s@%.2f,%.2f", tostring(name), x, y) end

-- The blueprint entities that got no ghost, as {name, x, y, blocked_by?,
-- uncharted?} (at most MAX_ROWS; blocked_by: what stands at that spot, as
-- build_layout names a blocker, read only on charted land: the ghosts skip
-- fog of war, and a spot the force has not charted is uncharted = true,
-- never read), and how many there are. origin + each entity's position is
-- where its ghost lands (blueprints.ghost_stack's cell).
local function missing_ghosts(c, origin, planned, ghosts)
  local got = {}
  for _, ghost in ipairs(ghosts or {}) do
    if ghost.valid then
      local ok, name = pcall(function() return ghost.ghost_name end)
      local key = ghost_key(ok and name or ghost.name, ghost.position.x, ghost.position.y)
      got[key] = (got[key] or 0) + 1
    end
  end
  local rows, count = {}, 0
  for _, e in ipairs(planned) do
    local x, y = origin.x + e.position.x, origin.y + e.position.y
    local key = ghost_key(e.name, x, y)
    if (got[key] or 0) > 0 then
      got[key] = got[key] - 1
    else
      count = count + 1
      if #rows < MAX_ROWS then
        local row = { name = e.name, x = x, y = y }
        local ok, found = false, nil
        if surfaces.charted(c.force, c.surface, math.floor(x / 32), math.floor(y / 32)) then
          ok, found = pcall(c.surface.find_entities_filtered, { position = { x = x, y = y }, limit = 4 })
        else
          row.uncharted = true
        end
        for _, other in ipairs(ok and found or {}) do
          if other.valid and not placement_geometry.NON_BLOCKING_TYPES[other.type] then
            row.blocked_by = { name = other.name, x = other.position.x, y = other.position.y }
            break
          end
        end
        rows[#rows + 1] = row
      end
    end
  end
  return rows, count
end

local function place_ghosts(task, c)
  local label = "blueprint_place " .. task.name
  -- Each ghost lands at the anchor + its turned dx/dy (blueprints.ghost_stack).
  local stack, cell = blueprints.ghost_stack(task.name, task.flip, math.floor((task.direction or 0) / 4), label)
  local planned = stack.get_blueprint_entities() or {}
  local expected = #planned + #(stack.get_blueprint_tiles() or {})
  if expected > 1100 then
    blueprints.clear_scratch()
    return { status = "failed", detail = "GHOSTS_NOT_PLACED: blueprint exceeds the bounded ghost count",
      outcome = { code = "GHOSTS_NOT_PLACED" } }
  end
  local position = cell and { x = task._anchor.x + cell.x, y = task._anchor.y + cell.y } or task._anchor
  local ok, ghosts = pcall(stack.build_blueprint, { surface = c.surface, force = c.force, position = position,
    direction = not cell and task.direction or 0, build_mode = defines.build_mode.forced,
    skip_fog_of_war = true, raise_built = true })
  blueprints.clear_scratch()
  if not ok then return { status = "failed", detail = "GHOSTS_NOT_PLACED: " .. plain(ghosts),
    outcome = { code = "GHOSTS_NOT_PLACED" } } end
  local rows, count = {}, 0
  for _, ghost in ipairs(ghosts or {}) do
    if ghost.valid then count = count + 1 end
    if ghost.valid and #rows < 20 then
      -- Entity and tile ghosts both name what they hold.
      local ok_name, name = pcall(function() return ghost.ghost_name end)
      if not ok_name then name = ghost.name end
      rows[#rows + 1] = { name = name, x = ghost.position.x, y = ghost.position.y, direction = ghost.direction }
    end
  end
  -- Where a ghost lands is known only for the pre-turned copy (cell); a
  -- blueprint with its own grid snapping keeps the native placement.
  local missing, missing_count
  if cell and count < expected then missing, missing_count = missing_ghosts(c, position, planned, ghosts) end
  local readiness = blueprints.robot_readiness(c, task._anchor)
  local robots = readiness.construction_robots or 0
  local complete = count == expected and expected > 0
  local outcome = { code = complete and "GHOSTS_PLACED" or count > 0 and "GHOSTS_PARTIAL" or "GHOSTS_NOT_PLACED",
    blueprint = task.name, expected = expected, submission_complete = complete, construction_complete = false,
    anchor = task._anchor, ghosts = count, placed = rows, construction_robots = robots, readiness = readiness,
    tool_unlock = blueprints.tool_unlock(c, "blueprint"),
    missing_ghosts = missing and #missing > 0 and missing or nil,
    missing_ghost_count = missing_count and missing_count > 0 and missing_count or nil }
  -- The first entity with no ghost, and what stands there.
  local first = outcome.missing_ghosts and outcome.missing_ghosts[1]
  local first_missing = first and string.format("; no ghost for %s at (%.1f, %.1f)%s", first.name, first.x, first.y,
    first.blocked_by and string.format(", blocked by %s at (%.1f, %.1f)", first.blocked_by.name, first.blocked_by.x,
      first.blocked_by.y) or first.uncharted and ", on uncharted land" or "") or ""
  if count == 0 then
    return { status = "failed", outcome = outcome,
      detail = string.format("GHOSTS_NOT_PLACED: %s placed no ghosts at (%d, %d) — something stands in its way%s",
        task.name, task._anchor.x, task._anchor.y, first_missing) }
  end
  local detail = string.format("blueprint_place %s: %d ghosts at (%d, %d); observed construction robots at anchor: %d",
    task.name, count, task._anchor.x, task._anchor.y, robots)
  if robots == 0 and readiness.counts_complete then
    outcome.note = "no construction robots cover the spot: build_ghosts builds them by hand"
    detail = detail .. " — " .. outcome.note
  elseif not readiness.counts_complete then
    outcome.note = "construction coverage/counts are incomplete: inspect the pending targets"
    detail = detail .. " — " .. outcome.note
  end
  if not complete then
    detail = detail .. string.format(" — only %d/%d requested ghosts observed; inspect retained work", count, expected) .. first_missing
  end
  return { status = complete and "done" or "partial", detail = detail, outcome = outcome }
end

function Place.tick(task)
  local c = task._platform and companion.require_present() or companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  if task.mode == "ghosts" and not task._layout then return place_ghosts(task, c) end
  local result = build_layout.layout_action.runner.tick(task._layout)
  if not result then return nil end
  if task._platform and result.outcome and result.outcome.already and #result.outcome.already > 0 then
    -- Layout checks establish footprint/name/direction, not the stored
    -- blueprint's native settings or outstanding item requests.
    if result.status == "done" then result.status = "partial"; result.outcome.code = "BLUEPRINT_EXISTING_UNVERIFIED" end
    result.outcome.configuration_verified = false
    result.detail = result.detail .. "; existing targets were left unchanged: inspect their settings and requests"
  end
  result.detail = "blueprint_place " .. task.name .. ": " .. tostring(result.detail)
  if type(result.outcome) == "table" then
    result.outcome.blueprint, result.outcome.wires_ignored = task.name, task._wires_ignored
  end
  return result
end

M.place_action = {
  runner = Place,
  make_task = function(step)
    return { name = step.name, position = step.position, direction = step.direction, flip = step.flip, mode = step.mode,
      platform = step.platform }
  end,
  validate = function(step, index)
    local label = "queue_plan blueprint_place step " .. index
    validate_place(step, label)
    if step.check_only then error(label .. ": check_only is the blueprint_place dry run, not a plan step", 0) end
  end,
  remote = function(step) return step.platform ~= nil end,
  budget_steps = function(step)
    return (step.mode == "ghosts" or step.platform ~= nil) and 1 or (blueprints.entity_count(step.name) or 1)
  end,
}

-- blueprint_place {.., check_only = true} over RPC: the placement at the
-- position (collisions), else the first free position near it, and the
-- materials against what the body carries; in hand mode an item the body
-- cannot obtain now (unobtainable) makes it not ok. A placement that fits
-- (here or at the free position) also reports build_layout's survey rows
-- on_ore, mixed_ore, open_fluid_ports, belt_joins and port_fluids (a platform has no
-- ore). A place
-- whose pipes the build would be refused for mixing fluids is not free: no
-- free_position, free_reason names the pipe (and at the position it is a
-- collision). A job: the same search and per-tick budget as build_layout's
-- dry run.
M.place_check_job = {
  start = function(params)
    local label = "blueprint_place"
    if type(params) ~= "table" or params.check_only ~= true then
      error("blueprint_place over RPC is a dry run: pass check_only = true, and queue it as a plan step to place", 0)
    end
    validate_place(params, label)
    local c = actor(params.platform)
    if params.platform ~= nil then
      local space, anchor = platform_anchor(c, params)
      local layout = blueprints.platform_layout(params.name, params.flip, math.floor((params.direction or 0) / 4), label)
      local nested = { anchor = { x = anchor.x - space.hub_position.x, y = anchor.y - space.hub_position.y },
        platform = space.platform, mode = "ghosts", entities = layout.entities, tiles = layout.tiles,
        check_only = true }
      return { name = params.name, platform = { index = space.platform, name = space.name }, hub = space.hub_position,
        anchor = anchor, layout_check = build_layout.layout_check_job.start(nested) }
    end
    local layout = placed_layout(params, label)
    local anchor = anchor_of(params.position)
    -- reserved: earlier package steps' placements, standing for this dry
    -- run (build_layout's); list_placed: the answer lists placed, as
    -- build_layout's does, for the package check's later steps.
    build_layout.validate_reserved(params.reserved, label)
    return { name = params.name, mode = params.mode or "hand", anchor = anchor, layout = layout, phase = "at",
      reserved = params.reserved, list_placed = params.list_placed == true or nil,
      search = build_layout.search_start(c, { anchor = anchor, layouts = { layout }, check_only = true,
        reserved = params.reserved }) }
  end,
  step = function(job, budget)
    if job.layout_check then
      local report = build_layout.layout_check_job.step(job.layout_check, budget)
      if not report then return nil end
      local collisions = {}
      for i = 1, math.min(MAX_ROWS, #report.failed) do collisions[i] = report.failed[i] end
      return { check_only = true, blueprint = job.name, mode = "ghosts", platform = job.platform, hub = job.hub,
        surface = "platform:" .. job.platform.index, position = job.anchor, ok = report.ok, collisions = collisions,
        already = report.already, needs_planned_tiles = report.needs_planned_tiles, materials = report.materials,
        tiles = report.tiles, configuration_verified = false, missing = report.missing or {},
        open_fluid_ports = report.open_fluid_ports, belt_joins = report.belt_joins, port_fluids = report.port_fluids }
    end
    local c = actor(job.platform)
    local s = job.search
    -- Both steps take their (scaled) work from budget.
    if job.out then
      -- The placement found is surveyed (data, never a failure).
      s.ctx.c = c
      if not build_layout.survey_step(s.ctx, job.survey, budget) then return nil end
      for k, v in pairs(build_layout.survey_rows(job.survey)) do job.out[k] = v end
      -- A placement the build would be refused for mixing fluids is not
      -- free: at the position it collides (the list holds nothing else
      -- there), near it the free position goes and free_reason says why.
      local mixes = build_layout.survey_failed(job.survey)
      if #mixes > 0 then
        job.out.free_position, job.out.free_reason = nil, mixes[1].reason
        if job.phase == "at" then
          job.out.ok = false
          for i = 1, math.min(MAX_ROWS, #mixes) do job.out.collisions[i] = mixes[i] end
        end
      end
      return job.out
    end
    local result = build_layout.search_step(c, s, budget)
    if not result then return nil end
    local report = build_layout.check_report(c, result)
    if job.phase == "at" and not report.ok then
      -- Blocked here: look for the first free position near it.
      job.collisions = report.failed
      job.phase = "near"
      job.search = build_layout.search_start(c, { site = { near = job.anchor }, layouts = { job.layout }, check_only = true,
        reserved = job.reserved })
      return nil
    end
    local missing = {}
    for _, m in ipairs(report.materials or {}) do
      if m.count > m.carried then missing[#missing + 1] = { item = m.item, missing = m.count - m.carried } end
    end
    local collisions = {}
    for i = 1, math.min(MAX_ROWS, #(job.collisions or {})) do collisions[i] = job.collisions[i] end
    -- Hand mode needs every item from the body; robots take ghosts' items
    -- from the logistic network.
    local unobtainable = job.mode ~= "ghosts" and report.unobtainable or nil
    local out = { check_only = true, blueprint = job.name, mode = job.mode, position = job.anchor,
      ok = job.phase == "at" and unobtainable == nil, collisions = collisions, materials = report.materials,
      missing = missing, unobtainable = unobtainable,
      free_position = report.ok and report.anchor or nil,
      free_reason = not report.ok and report.failed[1] and report.failed[1].reason or nil,
      tool_unlock = blueprints.tool_unlock(c, "blueprint"), wires_ignored = job.layout.wires_ignored,
      recipe_locked = s.recipe_locked,
      placed = job.list_placed and job.phase == "at" and report.placed or nil }
    if job.mode == "ghosts" then out.construction_robots = blueprints.construction_robots(c, job.anchor) end
    if not report.ok then return out end
    -- What stands on ore, drills over mixed ore, fluid ports that meet
    -- nothing and belt joins, as build_layout's dry run reports them, from
    -- the next tick.
    local started = s.ctx.calls
    job.out, job.survey = out, build_layout.survey_start(s.ctx, result, SURVEYED)
    budget.left = budget.left - build_layout.CHECK_COST * (s.ctx.calls - started)
    return nil
  end,
}

-- ------------------------------------------------------------ build_ghosts

local Ghosts = {}
Ghosts.resume = supply.resume

function Ghosts.start(task)
  local c = companion.require_companion()
  local label = "build_ghosts"
  local area = blueprints.area(c, task, label)
  local found = c.surface.find_entities_filtered({ area = area, type = "entity-ghost", force = c.force,
    limit = MAX_GHOSTS + 1 })
  task._list, task._built, task._truncated = {}, 0, #found > MAX_GHOSTS
  for i = 1, math.min(#found, MAX_GHOSTS) do task._list[i] = { entity = found[i] } end
  task._total = #task._list
end

-- Items of this ghost's item still needed by the remaining ghosts.
local function ghost_need(task, item)
  local n = 1
  for _, entry in ipairs(task._list) do if entry.item == item then n = n + 1 end end
  return n
end

local function ghost_result(task)
  local status = task._built == task._total and "done" or task._built > 0 and "partial" or "failed"
  if task._total == 0 then
    return { status = "done", detail = "build_ghosts: no own ghosts stand in that area",
      outcome = { code = "NOTHING_TO_BUILD", built = 0 } }
  end
  local code = status == "done" and "GHOSTS_BUILT" or status == "partial" and "GHOSTS_PARTIAL" or "GHOSTS_NOT_BUILT"
  return finish(task, status, code, string.format("build_ghosts: built %d/%d ghosts by hand%s", task._built, task._total,
    task._truncated and " (the area holds more: build_ghosts again)" or ""),
    { built = task._built, total = task._total, truncated = task._truncated or nil,
      item_requests_pending = task._pending, shortfall = task._shortfall,
      picked_up = task._picked_rows, picked_up_omitted = task._picked_omitted,
      spilled = task._spilled and task._spilled.count and task._spilled or nil })
end

function Ghosts.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  if task._exit then
    local walked = supply.step(task, "_exit")
    if not walked then return nil end
  end
  local entry = task._current
  if not entry then
    entry = nearest(c, task._list)
    if not entry then return ghost_result(task) end
    task._current = entry
    local ghost = entry.entity
    local proto = ghost.ghost_prototype
    local _, _, item = placeable(proto.name)
    entry.proto, entry.item, entry.position, entry.direction = proto, item, ghost.position, ghost.direction
    for _, other in ipairs(task._list) do
      if other.item == nil and other.entity.valid then
        local _, _, other_item = placeable(other.entity.ghost_name)
        other.item = other_item
      end
    end
  end
  local ghost = entry.entity
  -- Ground stacks clear_footprint took up from this ghost's footprint:
  -- {item, count, x, y} rows in the result's picked_up, built or not.
  local function keep_picked()
    local picked = entry.position and build.picked_up(task, entry.position)
    task._picked_up = nil
    for _, row in ipairs(picked or {}) do
      task._picked_rows = task._picked_rows or {}
      if #task._picked_rows < MAX_PICKED_ROWS then task._picked_rows[#task._picked_rows + 1] = row
      else task._picked_omitted = (task._picked_omitted or 0) + 1 end
    end
    return picked
  end
  local function skip(reason, code)
    task._current = nil
    local picked = keep_picked()
    if reason then
      local r = add_failure(task, { name = entry.proto and entry.proto.name, position = entry.position }, reason)
      if r then r.code, r.picked_up = code, picked end
    end
    return nil
  end
  if not ghost.valid then return skip(nil) end
  if not entry.item then return skip("no item places a " .. entry.proto.name) end
  if not entry.supplied then
    -- An item once short is not fetched again in this action.
    local short = task._shortfall and task._shortfall[entry.item]
    if not short and c.get_item_count(entry.item) == 0 and craft.queued(c, entry.item) == 0 then
      local result = supply.ensure(task, { { name = entry.item, count = ghost_need(task, entry.item) } }, { bulk = true })
      if not result then return nil end
      if result.status ~= "done" then task._shortfall = task._shortfall or {}; task._shortfall[entry.item] = result.detail end
    end
    entry.supplied = true
  end
  if c.get_item_count(entry.item) == 0 and craft.queued(c, entry.item) == 0 then
    return skip("I have no " .. entry.item)
  end
  if task._clear then
    local cleared = build.clear_footprint(task, c, entry.proto, entry.position, entry.direction)
    if cleared == nil then return nil end
    if cleared ~= "ok" then return skip(cleared.detail, cleared.outcome and cleared.outcome.code) end
  end
  local reached = approach.ensure(task, c, entry.position, c.build_distance)
  if type(reached) == "table" then return skip(reached.detail) end
  if reached ~= "ok" then return nil end
  local cleared = build.clear_footprint(task, c, entry.proto, entry.position, entry.direction)
  if cleared == nil then return nil end
  if cleared ~= "ok" then return skip(cleared.detail, cleared.outcome and cleared.outcome.code) end
  if craft.awaits(c, entry.item, 1) then return nil end
  if placement_geometry.overlaps_character(c, entry.proto, entry.position, entry.direction) then
    if entry.exited then return skip("CODEX_BODY_OVERLAP: I stand in its footprint") end
    entry.exited = true
    local exit = build.footprint_exit(c, entry.proto, entry.position, entry.direction)
    if exit and pcall(supply.begin, task, "_exit", { type = "walk_to", target = exit, arrival_mode = "exact", arrival_radius = 1 }) then
      return nil
    end
    return skip("CODEX_BODY_OVERLAP: I stand in its footprint and found no tile beside it")
  end
  if c.get_item_count(entry.item) == 0 then return skip("I have no " .. entry.item) end
  local had_requests = false
  pcall(function() had_requests = #ghost.item_requests > 0 end)
  local ok, collided, built, proxy = pcall(ghost.revive, { raise_revive = true })
  if not ok or not built then
    return skip(ok and "something stands in its footprint" or plain(collided))
  end
  c.remove_item({ name = entry.item, count = 1 })
  pcall(registry.add, built)
  -- Items lying in the footprint are the body's now.
  for _, stack in ipairs(type(collided) == "table" and collided or {}) do
    local item = { name = stack.name, count = stack.count, quality = items.quality_name(stack.quality) }
    local kept = c.insert(item)
    if kept < stack.count then
      item.count = stack.count - kept
      task._spilled = task._spilled or {}
      items.spill(c.surface, c.position, item, task._spilled)
    end
  end
  if had_requests and proxy then task._pending = (task._pending or 0) + 1 end
  task._built = task._built + 1
  task._current = nil
  keep_picked()
  return nil
end

M.ghosts_action = {
  runner = Ghosts,
  make_task = function(step) return area_params(step) end,
  validate = function(step, index) validate_area(step, "queue_plan build_ghosts step " .. index) end,
  budget_steps = function() return MAX_GHOSTS end,
}

-- ------------------------------------------------------- deconstruct_area

local function validate_names(list, label)
  if list == nil then return end
  if type(list) ~= "table" or #list < 1 or #list > MAX_TARGETS then error(label .. " must list 1-32 names", 0) end
  for _, name in ipairs(list) do if type(name) ~= "string" then error(label .. " must list names", 0) end end
end

local Deconstruct = {}
Deconstruct.resume = supply.resume

function Deconstruct.start(task)
  local c = actor(task.platform)
  local label = "deconstruct_area"
  local surface = c.surface
  if task.platform ~= nil then
    -- Remote: the platform's own entities, ordered for its hub.
    local p, code, why = platforms.resolve(c.force, task.platform)
    if not p then error(code .. ": " .. why, 0) end
    surface, code, why = platforms.surface_of(p)
    if not surface then error(code .. ": " .. why, 0) end
    task._platform = { index = p.index, name = p.name }
    task.mode = task.mode or "robots"
  end
  task.mode = task.mode or "hand"
  local area = blueprints.area(c, task, label, task._platform and surface)
  task._centre = centre_of(area)
  -- Only candidates are read, own first, each query with its own limit: an
  -- unfiltered query on an ore field fills its limit with resources.
  local limit = MAX_AREA_ENTITIES + 1
  local own_found = surface.find_entities_filtered({ area = area, force = c.force, name = task.filter, limit = limit })
  local natural_found = task._platform and {} or surface.find_entities_filtered({ area = area, type = NATURAL_TYPES,
    name = task.filter, limit = limit })
  task._list, task._done = {}, 0
  task._truncated = #own_found > MAX_AREA_ENTITIES or #natural_found > MAX_AREA_ENTITIES
  task._by_name = {}
  for _, found in ipairs({ own_found, natural_found }) do
    for _, e in ipairs(found) do
      if #task._list >= MAX_AREA_ENTITIES then task._truncated = true; break end
      local own = found == own_found
      if e.valid and not (own and NEVER[e.type]) then
        local ok, minable = pcall(function() return e.prototype.mineable_properties.minable end)
        if ok and minable then task._list[#task._list + 1] = { entity = e, own = own } end
      end
    end
  end
  task._total = #task._list
end

local function deconstruct_result(task, c)
  local hand = task.mode == "hand"
  local status = task._done == task._total and "done" or task._done > 0 and "partial" or "failed"
  if task._total == 0 then status = "done" end
  local code = task.mode == "cancel" and "DECONSTRUCTION_CANCELLED"
    or not hand and "DECONSTRUCTION_ORDERED"
    or status == "done" and "AREA_CLEARED" or status == "partial" and "AREA_PARTIAL" or "AREA_NOT_CLEARED"
  local verb = task.mode == "cancel" and "cancelled deconstruction of" or hand and "mined" or "ordered deconstruction of"
  local extra = { done = task._done, total = task._total, by_name = task._by_name, truncated = task._truncated or nil,
    stopped = task._stopped }
  if task._platform then
    extra.platform, extra.surface = task._platform, "platform:" .. task._platform.index
    extra.note = task.mode == "robots" and "the hub deconstructs them; their items go to the hub" or nil
  elseif not hand then
    extra.construction_robots = blueprints.construction_robots(c, task._centre)
    extra.tool_unlock = blueprints.tool_unlock(c, "deconstruction-planner")
  end
  return finish(task, status, code, string.format("deconstruct_area: %s %d/%d entities%s%s", verb, task._done, task._total,
    task._platform and (" on platform " .. task._platform.name) or "",
    task._truncated and " (the area holds more: run it again)" or ""), extra)
end

local function count_name(task, name) task._by_name[name] = (task._by_name[name] or 0) + 1 end

function Deconstruct.tick(task)
  local c = task._platform and companion.require_present() or companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  if task.mode ~= "hand" then
    -- Orders: a bounded batch per tick, in area order.
    task._cursor = task._cursor or 1
    local last = math.min(#task._list, task._cursor + ORDERS_PER_TICK - 1)
    for i = task._cursor, last do
      local entry = task._list[i]
      local e = entry.entity
      if e.valid then
        local ok, done
        if task.mode == "cancel" then
          ok, done = pcall(function()
            if not e.to_be_deconstructed() then return false end
            e.cancel_deconstruction(c.force)
            return true
          end)
        else
          ok, done = pcall(e.order_deconstruction, c.force)
        end
        if ok and done then task._done = task._done + 1; count_name(task, e.name)
        elseif task.mode ~= "cancel" then add_failure(task, e, ok and "the game refused the order" or plain(done)) end
      end
    end
    task._cursor = last + 1
    if task._cursor <= #task._list then return nil end
    return deconstruct_result(task, c)
  end
  if task._sub then
    local result = supply.step(task, "_sub")
    if not result then return nil end
    local entry = task._current
    task._current = nil
    if result.status == "done" then
      task._done = task._done + 1
      count_name(task, entry.name)
    else
      add_failure(task, { name = entry.name, position = entry.position }, result.detail)
      -- A full inventory stops the clearing: nothing more fits.
      if type(result.detail) == "string" and result.detail:find("inventory", 1, true) and result.detail:find("room", 1, true)
        or type(result.detail) == "string" and result.detail:find("inventory is full", 1, true) then
        task._stopped = "my inventory is full"
        return deconstruct_result(task, c)
      end
    end
  end
  local entry = nearest(c, task._list)
  if not entry then return deconstruct_result(task, c) end
  local e = entry.entity
  entry.name, entry.position = e.name, { x = e.position.x, y = e.position.y }
  local sub = { type = "mine", target = entry.position, count = 1, expected_name = e.name }
  if entry.own then
    sub.target_kind, sub.allow_fluid_loss = "owned", true
  else
    sub.target_kind, sub.entity = "natural", e
  end
  task._current = entry
  local ok, err = pcall(supply.begin, task, "_sub", sub)
  if not ok then
    task._current = nil
    add_failure(task, e, plain(err))
  end
  return nil
end

M.deconstruct_action = {
  runner = Deconstruct,
  make_task = function(step)
    local task = area_params(step)
    task.mode, task.filter, task.platform = step.mode, step.filter, step.platform
    return task
  end,
  validate = function(step, index)
    local label = "queue_plan deconstruct_area step " .. index
    validate_area(step, label)
    if step.mode ~= nil and step.mode ~= "hand" and step.mode ~= "robots" and step.mode ~= "cancel" then
      error(label .. ' mode must be "hand", "robots" or "cancel"', 0)
    end
    check_platform(step, label, { robots = true, cancel = true }, "robots or cancel")
    validate_names(step.filter, label .. " filter")
  end,
  remote = function(step) return step.platform ~= nil end,
  budget_steps = function(step) return (step.platform == nil and (step.mode == nil or step.mode == "hand")) and 60 or 1 end,
}

-- ------------------------------------------------------------ upgrade_area

local Upgrade = {}
Upgrade.resume = supply.resume

-- Same footprint and fast-replace group: only then a hand fast-replace.
local function same_footprint(a, b)
  return tonumber(a.tile_width) == tonumber(b.tile_width) and tonumber(a.tile_height) == tonumber(b.tile_height)
    and a.fast_replaceable_group ~= nil and a.fast_replaceable_group == b.fast_replaceable_group
end

function Upgrade.start(task)
  local c = companion.require_companion()
  task.mode = task.mode or "hand"
  local label = "upgrade_area"
  local from_name, from_proto = placeable(task.from)
  local to_name, to_proto, to_item = placeable(task.to)
  if not from_name then error(label .. ": no entity called '" .. tostring(task.from) .. "'", 0) end
  if not to_name then error(label .. ": no entity called '" .. tostring(task.to) .. "'", 0) end
  if from_name == to_name then error(label .. ": from and to are the same entity", 0) end
  task._to_name, task._to_item = to_name, to_item
  if task.mode == "hand" then
    if not same_footprint(from_proto, to_proto) then
      task._refused = string.format("UPGRADE_NOT_FAST_REPLACEABLE: %s and %s differ in footprint or fast-replace group;"
        .. " mine each %s and place a %s instead", from_name, to_name, from_name, to_name)
    elseif not to_item then
      task._refused = "UPGRADE_NOT_FAST_REPLACEABLE: no item places a " .. to_name
    end
  end
  local area = blueprints.area(c, task, label)
  task._centre = centre_of(area)
  local found = c.surface.find_entities_filtered({ area = area, name = from_name, force = c.force,
    limit = MAX_AREA_ENTITIES + 1 })
  task._list, task._done, task._truncated = {}, 0, #found > MAX_AREA_ENTITIES
  for i = 1, math.min(#found, MAX_AREA_ENTITIES) do task._list[i] = { entity = found[i] } end
  task._total = #task._list
end

local function upgrade_result(task, c)
  local status = (task._done == task._total or task._total == 0) and "done" or task._done > 0 and "partial" or "failed"
  local hand = task.mode == "hand"
  local code = not hand and "UPGRADE_ORDERED" or status == "done" and "UPGRADED" or status == "partial"
    and "UPGRADE_PARTIAL" or "UPGRADE_FAILED"
  local extra = { done = task._done, total = task._total, from = task.from, to = task._to_name,
    truncated = task._truncated or nil, shortfall = task._shortfall }
  if not hand then
    extra.construction_robots = blueprints.construction_robots(c, task._centre)
    extra.tool_unlock = blueprints.tool_unlock(c, "upgrade-planner")
  end
  return finish(task, status, code, string.format("upgrade_area: %s %d/%d %s to %s", hand and "replaced" or "ordered",
    task._done, task._total, task.from, task._to_name), extra)
end

-- One fast-replace by the body, in build reach: the old entity and its
-- contents go into the inventory (the engine's fast-replace by this
-- character; no player's undo queue or last_user).
local function replace(task, c, e)
  local args = { name = task._to_name, position = e.position, direction = e.direction, force = c.force }
  local ok_check, can = pcall(c.surface.can_fast_replace, args)
  if not (ok_check and can) then return "the game will not fast-replace it here" end
  local recipe
  pcall(function() local r = e.get_recipe(); recipe = r and r.name end)
  args.fast_replace, args.character, args.raise_built = true, c, true
  if e.type == "underground-belt" then args.type = e.belt_to_ground_type end
  local ok, built = pcall(c.surface.create_entity, args)
  if not (ok and built) then return ok and "the fast-replace failed" or plain(built) end
  c.remove_item({ name = task._to_item, count = 1 })
  pcall(registry.add, built)
  if recipe then
    local same = false
    pcall(function() local r = built.get_recipe(); same = r ~= nil and r.name == recipe end)
    if not same then pcall(built.set_recipe, recipe) end
  end
  return nil
end

function Upgrade.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  if task._refused then
    return { status = "failed", detail = task._refused,
      outcome = { code = "UPGRADE_NOT_FAST_REPLACEABLE", total = task._total, from = task.from, to = task._to_name } }
  end
  if task.mode == "robots" then
    task._cursor = task._cursor or 1
    local last = math.min(#task._list, task._cursor + ORDERS_PER_TICK - 1)
    for i = task._cursor, last do
      local e = task._list[i].entity
      if e.valid then
        local ok, ordered = pcall(e.order_upgrade, { force = c.force, target = task._to_name })
        if ok and ordered then task._done = task._done + 1
        else add_failure(task, e, ok and "the game refused the upgrade order" or plain(ordered)) end
      end
    end
    task._cursor = last + 1
    if task._cursor <= #task._list then return nil end
    return upgrade_result(task, c)
  end
  local entry = task._current
  if not entry then
    entry = nearest(c, task._list)
    if not entry then return upgrade_result(task, c) end
    task._current = entry
  end
  local e = entry.entity
  local function skip(reason)
    task._current = nil
    if reason then add_failure(task, e.valid and e or { name = task.from, position = entry.position }, reason) end
    return nil
  end
  if not e.valid then return skip(nil) end
  entry.position = { x = e.position.x, y = e.position.y }
  local item = task._to_item
  if not entry.supplied then
    if c.get_item_count(item) == 0 and craft.queued(c, item) == 0 then
      local result = supply.ensure(task, { { name = item, count = #task._list + 1 } }, { bulk = true })
      if not result then return nil end
      if result.status ~= "done" then task._shortfall = result.detail end
    end
    entry.supplied = true
  end
  if c.get_item_count(item) == 0 and craft.queued(c, item) == 0 then
    -- Nothing left to replace with: the rest are short too.
    add_failure(task, e, "I have no " .. item)
    task._list, task._current = {}, nil
    return upgrade_result(task, c)
  end
  local reached = approach.ensure(task, c, e.position, c.build_distance)
  if type(reached) == "table" then return skip(reached.detail) end
  if reached ~= "ok" then return nil end
  if craft.awaits(c, item, 1) then return nil end
  local why = replace(task, c, e)
  if why then return skip(why) end
  task._done = task._done + 1
  task._current = nil
  return nil
end

M.upgrade_action = {
  runner = Upgrade,
  make_task = function(step)
    local task = area_params(step)
    task.from, task.to, task.mode = step.from, step.to, step.mode
    return task
  end,
  validate = function(step, index)
    local label = "queue_plan upgrade_area step " .. index
    validate_area(step, label)
    if type(step.from) ~= "string" or type(step.to) ~= "string" then error(label .. " needs from and to entity names", 0) end
    if step.mode ~= nil and step.mode ~= "hand" and step.mode ~= "robots" then
      error(label .. ' mode must be "hand" or "robots"', 0)
    end
  end,
  budget_steps = function(step) return (step.mode == nil or step.mode == "hand") and 60 or 1 end,
}

-- ----------------------------------------------------------- copy_settings

-- The own entity standing on a position.
local function own_entity_at(c, position)
  local ok, found = pcall(c.surface.find_entities_filtered, { position = position, force = c.force })
  for _, e in ipairs(ok and found or {}) do
    if e.valid and not NEVER[e.type] then return e end
  end
end

local Copy = {}
Copy.resume = supply.resume

function Copy.start(task)
  local c = companion.require_companion()
  task._source = own_entity_at(c, task.from)
  if not task._source then
    error(string.format("copy_settings: no own entity stands at (%.1f, %.1f)", task.from.x, task.from.y), 0)
  end
  task._index, task._copied, task._returned = 0, 0, {}
end

function Copy.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  local source = task._source
  if not source.valid then
    return finish(task, task._copied > 0 and "partial" or "failed", "SOURCE_GONE",
      string.format("copy_settings: the source vanished after %d copies", task._copied), { copied = task._copied })
  end
  if task._index == 0 then
    local reached = approach.ensure_entity(task, c, source)
    if type(reached) == "table" then return reached end
    if reached ~= "ok" then return nil end
    task._index = 1
  end
  local target_pos = task.to[task._index]
  if not target_pos then
    local status = task._copied == #task.to and "done" or task._copied > 0 and "partial" or "failed"
    return finish(task, status, status == "done" and "SETTINGS_COPIED" or "SETTINGS_PARTIAL",
      string.format("copy_settings: copied %s's settings to %d/%d entities", source.name, task._copied, #task.to),
      { source = row(source), copied = task._copied, returned = next(task._returned) and task._returned or nil,
        spilled = task._spilled and task._spilled.count and task._spilled or nil })
  end
  local target = task._target
  if not target then
    target = own_entity_at(c, target_pos)
    if not target then
      add_failure(task, { name = "nothing", position = target_pos }, "no own entity stands there")
      task._index = task._index + 1
      return nil
    end
    task._target = target
  end
  local reached = approach.ensure_entity(task, c, target)
  if type(reached) == "table" then
    add_failure(task, target.valid and target or { name = "gone", position = target_pos }, reached.detail)
    task._target, task._index = nil, task._index + 1
    return nil
  end
  if reached ~= "ok" then return nil end
  local ok, removed = pcall(target.copy_settings, source)
  if ok then
    task._copied = task._copied + 1
    -- What the new settings pushed out (old recipe ingredients) is the body's.
    for _, stack in ipairs(type(removed) == "table" and removed or {}) do
      local item = { name = stack.name, count = stack.count, quality = items.quality_name(stack.quality) }
      local kept = c.insert(item)
      task._returned[stack.name] = (task._returned[stack.name] or 0) + stack.count
      if kept < stack.count then
        item.count = stack.count - kept
        task._spilled = task._spilled or {}
        items.spill(c.surface, c.position, item, task._spilled)
      end
    end
  else
    add_failure(task, target, plain(removed))
  end
  task._target, task._index = nil, task._index + 1
  return nil
end

M.copy_action = {
  runner = Copy,
  make_task = function(step) return { from = step.from, to = step.to } end,
  validate = function(step, index)
    local label = "queue_plan copy_settings step " .. index
    if not point(step.from) then error(label .. " needs from = {x, y}", 0) end
    if type(step.to) ~= "table" or #step.to < 1 or #step.to > MAX_TARGETS then error(label .. " to must list 1-32 positions", 0) end
    for _, p in ipairs(step.to) do if not point(p) then error(label .. " to positions need numeric x and y", 0) end end
  end,
  budget_steps = function(step) return type(step.to) == "table" and #step.to or 1 end,
}

M.MAX_AREA_ENTITIES, M.ORDERS_PER_TICK, M.MAX_GHOSTS = MAX_AREA_ENTITIES, ORDERS_PER_TICK, MAX_GHOSTS

return M
