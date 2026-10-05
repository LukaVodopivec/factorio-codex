-- build_layout and build_block: the bot gives a layout as offsets (dx, dy)
-- from an anchor, or a site request (near a point, on a resource, near
-- water); the mod finds the site, checks every placement and connection
-- route, then builds it all through build_plan (auto-supply, auto-clear,
-- recipes) in dependency order: recipients first, then the drills and
-- inserters that feed them, poles last. check_only is the same resolution
-- without any side effect, run as a job (jobs.lua) over as many ticks as the
-- build's own search would take, so it returns the site or a definite
-- SITE_NOT_FOUND. build_block expands a parametric block
-- (scripts/blocks.lua) into a layout and may turn it to fit the site.
-- Belt and pipe connections are searched by connect_entities' resumable A*
-- (up to 200 tiles, underground hops where the way is blocked), spread over
-- ticks like the site search.
--
-- Offsets are entity centres; each entity snaps to its own tile grid, so a
-- layout written for an integer anchor (top-left tile corner) is exact. An
-- entity's insert map is put in after it is placed (build_plan's starter
-- items); build_block fuels its burner machines that way by default. An
-- entity's settings (entity_settings: inserter filters, splitter priorities,
-- chest limits) are set right after it is placed, while the body is in
-- reach; mirror places it flipped; belt_to_ground_type picks an underground
-- belt's end.
-- Result: {anchor, placed:[{name,x,y,direction}], failed:[{index|connection,
-- code, reason}], shortfall?}; indexes are 0-based into entities/connections.
local companion = require("scripts.companion")
local placement_geometry = require("scripts.placement_geometry")
local connect_entities = require("scripts.connect_entities")
local build_plan = require("scripts.actions.build_plan")
local blocks = require("scripts.blocks")
local entity_settings = require("scripts.entity_settings")
local jobs = require("scripts.jobs")

local M = {}

local MAX_ENTITIES, MAX_CONNECTIONS, MAX_ROUTE, MAX_STEPS = 100, 32, connect_entities.MAX_LENGTH, 200
local SITE_RADIUS = 24        -- anchors tried around site.near
local SEARCH_RADIUS = 32      -- resource and water read around site.near
local MAX_CANDIDATES = 600
local ROUTE_TYPES = { belt = "transport-belt", pipe = "pipe", power = "electric-pole" }
local NATURAL = { tree = true, ["simple-entity"] = true }
-- Build order: recipients (rank 1) before what feeds them, poles last.
local RANK = { inserter = 2, ["mining-drill"] = 2, ["electric-pole"] = 3 }

local function plain(err) return (tostring(err):gsub("^.-:%d+:%s*", "")) end

-- ------------------------------------------------------------ validation

local function point(value, a, b)
  return type(value) == "table" and type(value[a]) == "number" and type(value[b]) == "number"
end

-- The item that places an entity name (the item itself, or the entity's
-- first placing item) and its entity prototype.
local function placeable(name)
  local item = prototypes.item[name]
  if item and item.place_result then return name, item.place_result end
  local entity = prototypes.entity[name]
  local ok, items = pcall(function() return entity and entity.items_to_place_this end)
  local first = ok and type(items) == "table" and items[1] or nil
  local item_name = type(first) == "string" and first or type(first) == "table" and first.name or nil
  item = item_name and prototypes.item[item_name]
  if item and item.place_result then return item_name, item.place_result end
  return nil
end

-- A layout entity written for 0.21.1 kept its underground end
-- (settings.type), mirror and blueprint fields in settings: they move to
-- belt_to_ground_type, mirror and the Settings its type takes (none when
-- nothing applies). Settings naming a group, or none, are left as they are.
local function upgrade_settings(e)
  local s = e.settings
  if type(s) ~= "table" or next(s) == nil or not entity_settings.legacy(s) then return end
  if e.belt_to_ground_type == nil and (s.type == "input" or s.type == "output") then e.belt_to_ground_type = s.type end
  if e.mirror == nil and type(s.mirror) == "boolean" then e.mirror = s.mirror end
  local _, proto = placeable(e.name)
  local fields = {}
  for key, value in pairs(s) do fields[key] = value end
  fields.name = proto and proto.name
  e.settings = proto and entity_settings.from_blueprint(fields, proto.type, true) or nil
end

local function validate_layout(params, label)
  local entities = params.entities
  -- A route-only layout (no entities, connections from an anchor) joins
  -- what already stands.
  local route_only = type(entities) == "table" and #entities == 0 and type(params.connections) == "table"
    and #params.connections > 0 and params.anchor ~= nil
  if type(entities) ~= "table" or (#entities < 1 and not route_only) or #entities > MAX_ENTITIES then
    error(string.format("%s entities must be 1-%d placements (none only for connections from an anchor)", label,
      MAX_ENTITIES), 0)
  end
  for i, e in ipairs(entities) do
    if type(e) ~= "table" or type(e.name) ~= "string" or type(e.dx) ~= "number" or type(e.dy) ~= "number" then
      error(string.format("%s entities[%d] must be {name, dx, dy, direction?, recipe?, insert?, mirror?, settings?}", label, i - 1), 0)
    end
    local d = e.direction
    if d ~= nil and (type(d) ~= "number" or d % 1 ~= 0 or d < 0 or d > 15) then
      error(string.format("%s entities[%d].direction must be an integer 0-15", label, i - 1), 0)
    end
    if e.recipe ~= nil and type(e.recipe) ~= "string" then
      error(string.format("%s entities[%d].recipe must be a recipe name", label, i - 1), 0)
    end
    if e.insert ~= nil then
      local ok = type(e.insert) == "table"
      for name, count in pairs(ok and e.insert or {}) do
        if type(name) ~= "string" or type(count) ~= "number" or count < 1 then ok = false end
      end
      if not ok then error(string.format('%s entities[%d].insert must map item names to counts, e.g. {"coal":5}', label, i - 1), 0) end
    end
    upgrade_settings(e)
    if e.settings ~= nil then entity_settings.validate(e.settings, string.format("%s entities[%d].settings", label, i - 1)) end
    if e.mirror ~= nil and type(e.mirror) ~= "boolean" then
      error(string.format("%s entities[%d].mirror must be true or false", label, i - 1), 0)
    end
    if e.belt_to_ground_type ~= nil and e.belt_to_ground_type ~= "input" and e.belt_to_ground_type ~= "output" then
      error(string.format('%s entities[%d].belt_to_ground_type must be "input" or "output"', label, i - 1), 0)
    end
  end
  local connections = params.connections
  if connections ~= nil then
    if type(connections) ~= "table" or #connections > MAX_CONNECTIONS then
      error(string.format("%s connections must be at most %d routes", label, MAX_CONNECTIONS), 0)
    end
    for j, route in ipairs(connections) do
      if type(route) ~= "table" or not ROUTE_TYPES[route.kind] or type(route.prototype) ~= "string"
        or not point(route.from, "dx", "dy") or not point(route.to, "dx", "dy")
        or (route.underground ~= nil and route.underground ~= false and type(route.underground) ~= "string") then
        error(string.format("%s connections[%d] must be {kind: belt|pipe|power, prototype, from:{dx,dy}, to:{dx,dy}, underground?}",
          label, j - 1), 0)
      end
    end
  end
  if (params.anchor == nil) == (params.site == nil) then error(label .. " takes exactly one of anchor or site", 0) end
  if params.anchor ~= nil and not point(params.anchor, "x", "y") then error(label .. " anchor must be {x, y}", 0) end
  local site = params.site
  if site ~= nil then
    if type(site) ~= "table" or not point(site.near, "x", "y") then error(label .. " site needs near = {x, y}", 0) end
    if site.on_resource ~= nil and type(site.on_resource) ~= "string" then error(label .. " site.on_resource must be a resource name", 0) end
    if site.near_water ~= nil and type(site.near_water) ~= "boolean" then error(label .. " site.near_water must be true or false", 0) end
  end
end

-- ------------------------------------------------------------- geometry

local function snapped(value, tiles)
  local offset = tiles % 2 == 1 and 0.5 or 0
  return math.floor(value - offset + 0.5) + offset
end

local function round(value) return math.floor(value + 0.5) end

local function tiles_of(proto, direction)
  local w, h = tonumber(proto.tile_width) or 1, tonumber(proto.tile_height) or 1
  if direction % 8 == 4 then w, h = h, w end
  return w, h
end

local function tile_key(x, y) return string.format("%d,%d", x, y) end

-- Every tile an area covers.
local function each_tile(area, fn)
  for y = math.floor(area.left_top.y + 0.01), math.ceil(area.right_bottom.y - 0.01) - 1 do
    for x = math.floor(area.left_top.x + 0.01), math.ceil(area.right_bottom.x - 0.01) - 1 do fn(x, y) end
  end
end

-- A layout turned clockwise by quarter turns about the anchor.
local function rotated(layout, quarters)
  local function turn(x, y)
    for _ = 1, quarters do x, y = -y, x end
    return x, y
  end
  local out = { entities = {}, connections = {} }
  for i, e in ipairs(layout.entities) do
    local dx, dy = turn(e.dx, e.dy)
    out.entities[i] = { name = e.name, dx = dx, dy = dy, recipe = e.recipe, insert = e.insert, settings = e.settings,
      mirror = e.mirror, belt_to_ground_type = e.belt_to_ground_type, direction = ((e.direction or 0) + 4 * quarters) % 16 }
  end
  for j, route in ipairs(layout.connections or {}) do
    local fx, fy = turn(route.from.dx, route.from.dy)
    local tx, ty = turn(route.to.dx, route.to.dy)
    out.connections[j] = { kind = route.kind, prototype = route.prototype, underground = route.underground,
      from = { dx = fx, dy = fy }, to = { dx = tx, dy = ty } }
  end
  return out
end

-- An underground belt's end. A layout saved by 0.21.1 kept it as settings.type.
local function belt_end(e)
  return e.belt_to_ground_type or type(e.settings) == "table" and e.settings.type or nil
end

-- Name-level checks no site can fix. Returns the variant and its failures.
local function prepare(c, layout)
  local variant, failed = { entities = {}, connections = {} }, {}
  for i, e in ipairs(layout.entities) do
    local item, proto = placeable(e.name)
    if not item then
      failed[#failed + 1] = { index = i - 1, code = "UNKNOWN_ENTITY", reason = "no placeable item or entity called '" .. e.name .. "'" }
    else
      if e.recipe then
        local recipe = c.force.recipes[e.recipe]
        local why
        if not recipe then why = { "RECIPE_UNKNOWN", "unknown recipe '" .. e.recipe .. "'" }
        elseif not recipe.enabled then why = { "RECIPE_LOCKED", "recipe " .. e.recipe .. " isn't unlocked yet — research it first" }
        elseif proto.type ~= "assembling-machine" then
          why = { "RECIPE_NOT_SETTABLE", proto.type == "furnace" and (e.name .. " is a furnace; it picks its recipe from what it is fed")
            or (e.name .. " can't have a recipe set — only assembling machines can") }
        end
        if why then failed[#failed + 1] = { index = i - 1, code = why[1], reason = why[2] } end
      end
      -- Settings the entity cannot take fail here, before anything is built.
      local code, message = nil, nil
      if e.settings then code, message = entity_settings.check_prototype(proto, e.settings) end
      if code then failed[#failed + 1] = { index = i - 1, code = code, reason = message } end
      variant.entities[#variant.entities + 1] = { index = i - 1, item = item, proto = proto, dx = e.dx, dy = e.dy,
        direction = math.floor(e.direction or 0) % 16, recipe = e.recipe, insert = e.insert, settings = e.settings,
        mirror = e.mirror, belt_to_ground_type = proto.type == "underground-belt" and belt_end(e) or nil }
    end
  end
  for j, route in ipairs(layout.connections or {}) do
    local item = prototypes.item[route.prototype]
    local proto = item and item.place_result
    local under_ok, under = false, nil
    if proto then under_ok, under = pcall(connect_entities.underground, c, route.kind, proto, route.underground) end
    if not proto or proto.type ~= ROUTE_TYPES[route.kind] or (tonumber(proto.tile_width) or 1) ~= 1 then
      failed[#failed + 1] = { connection = j - 1, code = "ROUTE_PROTOTYPE",
        reason = route.prototype .. " is not a one-tile " .. ROUTE_TYPES[route.kind] .. " item for a " .. route.kind .. " route" }
    elseif not under_ok then
      failed[#failed + 1] = { connection = j - 1, code = "ROUTE_PROTOTYPE", reason = plain(under) }
    else
      variant.connections[#variant.connections + 1] = { index = j - 1, kind = route.kind, item = route.prototype,
        proto = proto, under = under, from = route.from, to = route.to }
    end
  end
  return variant, failed
end

-- ---------------------------------------------------------- engine checks

-- Work items, never time (Lua has no clock): one per ground check or route
-- tile tried, plus the engine work each makes (a can_place with its blocker
-- query 3, an uncached chunk lookup 1). Every RCON command and on_tick
-- handler runs inside one game tick on the server and every client, so a
-- search spends at most WORK_PER_TICK per tick (a site's placement checks
-- already started may finish up to twice that; a route search pauses at the
-- tick's share and resumes on the next) and a build's whole search, like a
-- check_only dry run, at most MAX_WORK, spread over ticks.
local WORK_PER_TICK = 600
local MAX_WORK = 60000
local ROUTE_WORK = 20000 -- one connection's route search
local BUDGET_SPENT = "the search's work budget is spent"

-- Charges n work items; false (and out_of_budget) past the ceiling.
local function spend(ctx, n)
  if ctx.calls + n > ctx.ceiling then
    ctx.out_of_budget = true
    return false
  end
  ctx.calls = ctx.calls + n
  return true
end

-- Every chunk under the area is charted (chunk answers cached per search).
local function charted(ctx, area)
  local c = ctx.c
  for _, corner in ipairs({ area.left_top, { x = area.right_bottom.x - 0.001, y = area.left_top.y },
    { x = area.left_top.x, y = area.right_bottom.y - 0.001 },
    { x = area.right_bottom.x - 0.001, y = area.right_bottom.y - 0.001 } }) do
    local cx, cy = math.floor(corner.x / 32), math.floor(corner.y / 32)
    local key = cx .. "," .. cy
    local value = ctx.chunks[key]
    if value == nil then
      ctx.calls = ctx.calls + 1
      local ok, answer = pcall(c.force.is_chunk_charted, c.surface, { x = cx, y = cy })
      value = ok and answer == true
      ctx.chunks[key] = value
    end
    if not value then return false end
  end
  return true
end

-- Whether proto can stand at pos for this build: placeable now, or only
-- Codex's body (it steps aside) or trees and rocks (placing mines them) are
-- in the way. Returns ok, reason, clears. Cached per search.
local function ground(ctx, proto, pos, direction)
  if not spend(ctx, 1) then return false, BUDGET_SPENT end
  local key = string.format("%s|%.2f|%.2f|%d", proto.name, pos.x, pos.y, direction)
  local hit = ctx.cache[key]
  if hit then return hit[1], hit[2], hit[3] end
  if not spend(ctx, 3) then return false, BUDGET_SPENT end
  local c = ctx.c
  local area = placement_geometry.footprint(proto, pos, direction)
  local ok, reason, clears
  if not charted(ctx, area) then
    ok, reason = false, "the footprint is not charted"
  else
    local placeable_now, why = placement_geometry.can_place(c, proto, pos, direction)
    if placeable_now or why == "CODEX_BODY_OVERLAP" then
      ok = true
    else
      local found_ok, found = pcall(c.surface.find_entities_filtered, { area = area, limit = 33 })
      local blocker
      for _, e in ipairs(found_ok and found or {}) do
        if e.valid and e ~= c and not placement_geometry.NON_BLOCKING_TYPES[e.type] then
          if NATURAL[e.type] then clears = true else blocker = blocker or e end
        end
      end
      if blocker then
        ok, clears, reason = false, nil, string.format("blocked by %s at (%.1f, %.1f)", blocker.name, blocker.position.x, blocker.position.y)
      elseif clears then
        ok = true
      else
        ok = false
        reason = proto.type == "mining-drill" and "no resource it can mine under it"
          or proto.type == "offshore-pump" and "it needs a land tile with water behind it"
          or "the ground there is water or otherwise unbuildable"
      end
    end
  end
  ctx.cache[key] = { ok, reason, clears }
  return ok, reason, clears
end

-- Planned placements of a variant at an anchor.
local function place(variant, anchor)
  local out = {}
  for i, e in ipairs(variant.entities) do
    local w, h = tiles_of(e.proto, e.direction)
    local position = { x = snapped(anchor.x + e.dx, w), y = snapped(anchor.y + e.dy, h) }
    out[i] = { entity = e, position = position, area = placement_geometry.footprint(e.proto, position, e.direction) }
  end
  return out
end

-- A placement moved by whole tiles.
local function shifted(p, ox, oy)
  local lt, rb = p.area.left_top, p.area.right_bottom
  return { entity = p.entity, position = { x = p.position.x + ox, y = p.position.y + oy },
    area = { left_top = { x = lt.x + ox, y = lt.y + oy }, right_bottom = { x = rb.x + ox, y = rb.y + oy } } }
end

-- Pairs of placements whose footprints overlap, in (earlier, later) order.
-- Only placements sharing a tile are compared, so the cost follows the
-- layout's area, not the square of its size.
local function overlaps(placements)
  local buckets, pairs_found = {}, {}
  for j, p in ipairs(placements) do
    local near = {}
    for y = math.floor(p.area.left_top.y), math.ceil(p.area.right_bottom.y) - 1 do
      for x = math.floor(p.area.left_top.x), math.ceil(p.area.right_bottom.x) - 1 do
        local key = tile_key(x, y)
        local list = buckets[key]
        if list then
          for _, i in ipairs(list) do near[i] = true end
          list[#list + 1] = j
        else
          buckets[key] = { j }
        end
      end
    end
    for i in pairs(near) do
      if placement_geometry.overlaps(placements[i].area, p.area) then pairs_found[#pairs_found + 1] = { i, j } end
    end
  end
  table.sort(pairs_found, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  local failed = {}
  for _, pair in ipairs(pairs_found) do
    local first, second = placements[pair[1]].entity, placements[pair[2]].entity
    failed[#failed + 1] = { index = second.index, code = "LAYOUT_OVERLAP",
      reason = string.format("%s overlaps entities[%d] %s", second.item, first.index, first.item) }
  end
  return failed
end

-- Critical placements first, so a hopeless site is rejected early.
local function check_order(placements)
  local order = {}
  for i in ipairs(placements) do order[i] = i end
  local function weight(p)
    local t = p.entity.proto.type
    return (t == "offshore-pump" or t == "mining-drill") and 0 or 1
  end
  table.sort(order, function(a, b)
    local wa, wb = weight(placements[a]), weight(placements[b])
    if wa ~= wb then return wa < wb end
    return a < b
  end)
  return order
end

-- What does not depend on the anchor, worked out once per variant: anchors
-- differ from base by whole tiles, so every placement only moves with them.
local function layout_geometry(variant, base)
  variant.base = base
  variant.rel = place(variant, base)
  variant.self_overlap = overlaps(variant.rel)
  variant.order = check_order(variant.rel)
  for _, e in ipairs(variant.entities) do
    if e.proto.type == "mining-drill" then
      local ok, radius = pcall(function() return e.proto.mining_drill_radius end)
      e.radius = ok and tonumber(radius) or nil
    end
  end
end

-- Routing state of a candidate whose placements fit: the planned
-- footprints (and poles) the routes go around, the next connection to route
-- and the routes found so far. Plain data, kept between ticks.
local function routing(placements)
  local occupied, poles = {}, {}
  for _, p in ipairs(placements) do
    each_tile(p.area, function(x, y)
      occupied[tile_key(x, y)] = true
      if p.entity.proto.type == "electric-pole" then poles[tile_key(x, y)] = true end
    end)
  end
  return { next = 1, occupied = occupied, poles = poles, routes = {} }
end

local function route_failed(failed, route, reason)
  failed[#failed + 1] = { connection = route.index, code = "ROUTE_FAILED", reason = reason }
end

-- Routes the connections one after another around the planned footprints
-- and earlier routes, resuming where the last tick stopped. True once every
-- connection is routed or failed; false when work up to soft is spent.
local function route_more(ctx, variant, anchor, result, soft)
  local r = result.routing
  local c = ctx.c
  while r.next <= #variant.connections do
    local route = variant.connections[r.next]
    local function free(pos, direction, proto)
      ctx.calls = ctx.calls + 1
      if r.occupied[tile_key(math.floor(pos.x), math.floor(pos.y))] then return false end
      return (ground(ctx, proto or route.proto, pos, direction or 0))
    end
    local from = { x = snapped(anchor.x + route.from.dx, 1), y = snapped(anchor.y + route.from.dy, 1) }
    local to = { x = snapped(anchor.x + route.to.dx, 1), y = snapped(anchor.y + route.to.dy, 1) }
    local ok, steps
    if route.kind == "power" then
      -- Linear in the poles it places: one step.
      local function has_pole(pos)
        if r.poles[tile_key(math.floor(pos.x), math.floor(pos.y))] then return true end
        ctx.calls = ctx.calls + 1
        local found_ok, found = pcall(c.surface.find_entities_filtered,
          { position = pos, radius = 0.5, type = "electric-pole", force = c.force })
        return found_ok and type(found) == "table" and #found > 0
      end
      ok, steps = pcall(connect_entities.route_poles, route.item, route.proto, from, to, MAX_ROUTE, free, has_pole)
    else
      if not r.search then
        -- An endpoint tile that is not free is the entity the route ends at.
        local include_from, include_to = free(from), free(to)
        r.limit = ctx.calls + ROUTE_WORK
        r.search = connect_entities.new_search({ kind = route.kind, item = route.item, max_length = MAX_ROUTE,
          under = route.under, starts = { { position = from, include = include_from } },
          goals = { { position = to, include = include_to } } })
      end
      local under = route.under
      local env = {
        more = function() return ctx.calls < soft and ctx.calls < r.limit and ctx.calls < MAX_WORK end,
        spend = function(n) ctx.calls = ctx.calls + n end,
        fits = function(pos, direction, role) return free(pos, direction, role == "under" and under.proto or nil) end,
        gap_clear = function(entrance, exit)
          ctx.calls = ctx.calls + 2
          local area = { left_top = { x = math.min(entrance.x, exit.x) - 0.4, y = math.min(entrance.y, exit.y) - 0.4 },
            right_bottom = { x = math.max(entrance.x, exit.x) + 0.4, y = math.max(entrance.y, exit.y) + 0.4 } }
          local found_ok, found = pcall(c.surface.find_entities_filtered, { area = area, name = under.proto.name })
          return found_ok and type(found) == "table" and #found == 0
        end,
      }
      ok, steps = pcall(connect_entities.search_step, r.search, env)
      if ok and steps == nil then
        if ctx.calls < r.limit and ctx.calls < MAX_WORK then return false end
        ok, steps = false, "no route found before its search budget ran out (is an endpoint walled in?)"
      end
      r.search, r.limit = nil, nil
    end
    if not ok then
      route_failed(result.failed, route, plain(steps))
    else
      for _, step in ipairs(steps) do
        local key = tile_key(math.floor(step.x), math.floor(step.y))
        r.occupied[key] = true
        if route.kind == "power" then r.poles[key] = true end
      end
      r.routes[#r.routes + 1] = { route = route, steps = steps }
    end
    r.next = r.next + 1
  end
  result.routes, result.routing = r.routes, nil
  local count = #result.placements
  for _, routed in ipairs(result.routes) do count = count + #routed.steps end
  if count > MAX_STEPS then
    result.failed[#result.failed + 1] = { code = "LAYOUT_TOO_LARGE",
      reason = string.format("the layout needs %d placements; one build takes at most %d", count, MAX_STEPS) }
    result.hard = true
  end
  return true
end

-- Checks one anchor. all = report every failure (else stop at the first).
-- With ctx.out_of_budget set afterwards the result is incomplete.
local function check(ctx, variant, anchor, all)
  local ox, oy = anchor.x - variant.base.x, anchor.y - variant.base.y
  local result = { anchor = anchor, routes = {}, passed = 0, clears = 0, failed = {} }
  if #variant.self_overlap > 0 then
    for i, failure in ipairs(variant.self_overlap) do result.failed[i] = failure end
    result.hard = true
    return result
  end
  for _, i in ipairs(variant.order) do
    local r = variant.rel[i]
    local e = r.entity
    local position = { x = r.position.x + ox, y = r.position.y + oy }
    local ok, reason, clears = ground(ctx, e.proto, position, e.direction)
    if ctx.out_of_budget then return result end
    if ok then
      result.passed = result.passed + 1
      if clears then result.clears = result.clears + 1 end
    else
      result.failed[#result.failed + 1] = { index = e.index, code = "BLOCKED",
        reason = string.format("%s at (%.1f, %.1f): %s", e.item, position.x, position.y, reason) }
      if not all then return result end
    end
  end
  if #result.failed > 0 then return result end
  local placements = {}
  for i, r in ipairs(variant.rel) do placements[i] = shifted(r, ox, oy) end
  result.placements = placements
  -- The routes follow, resumable over ticks (route_more).
  result.routing = routing(placements)
  return result
end

-- ------------------------------------------------------------ site search

local function distance_sorted(list, near)
  for _, p in ipairs(list) do p.d = (p.x + 0.5 - near.x) ^ 2 + (p.y + 0.5 - near.y) ^ 2 end
  table.sort(list, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end)
  return list
end

local water_names
local function water_tile_names()
  if water_names then return water_names end
  water_names = {}
  for name, proto in pairs(prototypes.tile) do
    local ok, layers = pcall(function() return proto.collision_mask.layers end)
    if ok and type(layers) == "table" and (layers.water_tile or layers["water-tile"]) then water_names[#water_names + 1] = name end
  end
  table.sort(water_names)
  return water_names
end

-- The resource or water window around site.near (SEARCH_RADIUS) is read as
-- a phase of the search, a strip of SITE_STRIP rows per query, and ordered
-- nearest first by bucketing on the squared distance, so no tick reads,
-- keys or sorts the whole window. Tile keys are numbers (no tile is a
-- million tiles from the origin on any Factorio map).
local SITE_STRIP = 8
local LOAD_PER_ITEM = 4  -- tiles taken in, or ordered, per work item
local function site_key(x, y) return x * 2097152 + y end

local function by_distance(a, b)
  if a.d ~= b.d then return a.d < b.d end
  if a.y ~= b.y then return a.y < b.y end
  return a.x < b.x
end

local function load_start(site)
  return { kind = site.on_resource and "resource" or "water", row = math.floor(site.near.y - SEARCH_RADIUS),
    set = {}, water = {}, wet = {}, wi = 1, buckets = {}, top_bucket = -1, count = 0, b = 0, tiles = {} }
end

local function load_tile(L, near, x, y)
  local d = (x + 0.5 - near.x) ^ 2 + (y + 0.5 - near.y) ^ 2
  local b = math.floor(d)
  local bucket = L.buckets[b]
  if not bucket then bucket = {}; L.buckets[b] = bucket end
  bucket[#bucket + 1] = { x = x, y = y, d = d }
  L.top_bucket, L.count = math.max(L.top_bucket, b), L.count + 1
end

-- One phase of the load within the work up to limit: true once s.tiles (and
-- for a resource s.set) are ready, or s.result says no site exists.
local function load_step(s, limit)
  local ctx, L, site = s.ctx, s.load, s.site
  local near, radius_sq = site.near, SEARCH_RADIUS * SEARCH_RADIUS
  local left, right = math.floor(near.x - SEARCH_RADIUS), math.ceil(near.x + SEARCH_RADIUS)
  local bottom = math.ceil(near.y + SEARCH_RADIUS)
  while L.row < bottom do
    if ctx.calls >= limit then return false end
    local area = { left_top = { x = left, y = L.row }, right_bottom = { x = right, y = math.min(bottom, L.row + SITE_STRIP) } }
    L.row = L.row + SITE_STRIP
    ctx.calls = ctx.calls + 1
    if L.kind == "resource" then
      local ok, found = pcall(ctx.c.surface.find_entities_filtered, { area = area, type = "resource", name = site.on_resource })
      found = ok and found or {}
      ctx.calls = ctx.calls + math.ceil(#found / LOAD_PER_ITEM)
      for _, e in ipairs(found) do
        local p = e.valid and e.position
        if p and (p.x - near.x) ^ 2 + (p.y - near.y) ^ 2 <= radius_sq then
          local x, y = math.floor(p.x), math.floor(p.y)
          local key = site_key(x, y)
          if not L.set[key] then L.set[key] = true; load_tile(L, near, x, y) end
        end
      end
    else
      local ok, found = pcall(ctx.c.surface.find_tiles_filtered, { area = area, name = water_tile_names() })
      found = ok and found or {}
      ctx.calls = ctx.calls + math.ceil(#found / LOAD_PER_ITEM)
      for _, tile in ipairs(found) do
        local p = tile.position
        if (p.x + 0.5 - near.x) ^ 2 + (p.y + 0.5 - near.y) ^ 2 <= radius_sq then
          L.water[site_key(p.x, p.y)] = true
          L.wet[#L.wet + 1] = { x = p.x, y = p.y }
        end
      end
    end
  end
  -- Water: the land tiles beside it.
  while L.wi <= #L.wet do
    if ctx.calls >= limit then return false end
    ctx.calls = ctx.calls + 1
    local tile = L.wet[L.wi]
    L.wi = L.wi + 1
    for _, d in ipairs({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }) do
      local x, y = tile.x + d[1], tile.y + d[2]
      local key = site_key(x, y)
      if not L.water[key] and not L.set[key] then L.set[key] = true; load_tile(L, near, x, y) end
    end
  end
  -- Nearest first: buckets in order, each (a few tiles) sorted.
  while L.b <= L.top_bucket do
    if ctx.calls >= limit then return false end
    local bucket = L.buckets[L.b]
    L.b = L.b + 1
    if bucket then
      ctx.calls = ctx.calls + math.ceil(#bucket / LOAD_PER_ITEM)
      table.sort(bucket, by_distance)
      for _, tile in ipairs(bucket) do L.tiles[#L.tiles + 1] = { x = tile.x, y = tile.y } end
    end
  end
  s.load = nil
  if #L.tiles == 0 then
    s.result = { failed = { { code = "SITE_NOT_FOUND", reason = site.on_resource
      and string.format("no %s within %d tiles of (%.1f, %.1f)", site.on_resource, SEARCH_RADIUS, near.x, near.y)
      or string.format("no water within %d tiles of (%.1f, %.1f)", SEARCH_RADIUS, near.x, near.y) } } }
    return true
  end
  s.tiles, s.set, s.numeric_keys = L.tiles, L.kind == "resource" and L.set or nil, true
  return true
end

-- Anchor offsets around a site's centre, nearest first (the same for every
-- search, so worked out once).
local site_offsets_list
local function site_offsets()
  if site_offsets_list then return site_offsets_list end
  local offsets = {}
  for dy = -SITE_RADIUS, SITE_RADIUS do
    for dx = -SITE_RADIUS, SITE_RADIUS do
      if dx * dx + dy * dy <= SITE_RADIUS * SITE_RADIUS then offsets[#offsets + 1] = { x = dx, y = dy } end
    end
  end
  site_offsets_list = distance_sorted(offsets, { x = 0.5, y = 0.5 })
  return site_offsets_list
end

-- Every drill's mining area holds at least half resource tiles. Charged per
-- tile tested. (A search from a 0.21.0 save keyed its set by strings.)
local function covered(ctx, variant, anchor, set, numeric_keys)
  local key_of = numeric_keys and site_key or tile_key
  local ox, oy = anchor.x - variant.base.x, anchor.y - variant.base.y
  for i, e in ipairs(variant.entities) do
    local radius = e.radius
    if radius then
      local r = variant.rel[i]
      local cx, cy = r.position.x + ox, r.position.y + oy
      local hits, total = 0, 0
      for y = math.floor(cy - radius + 0.5), math.ceil(cy + radius - 0.5) - 1 do
        for x = math.floor(cx - radius + 0.5), math.ceil(cx + radius - 0.5) - 1 do
          total = total + 1
          if set[key_of(x, y)] then hits = hits + 1 end
        end
      end
      ctx.calls = ctx.calls + math.ceil(total / LOAD_PER_ITEM)
      if hits * 2 < total then return false end
    end
  end
  return true
end

local function key_entity(variant, kind)
  for _, e in ipairs(variant.entities) do if e.proto.type == kind then return e end end
  return variant.entities[1]
end

-- ------------------------------------------------------------- resolution

-- request = {anchor? | site?, layouts = {layout, ...}}; every layout is a
-- variant of the same design (block rotations). Returns the search state:
-- plain tables and prototype references only, so a build keeps it in its
-- task (storage) between ticks. state.result is set once it is decided.
local function new_search(c, request)
  local ctx = { c = c, calls = 0, ceiling = 0, cache = {}, chunks = {} }
  local s = { ctx = ctx, tried = 0, ti = 1, vi = 1 }
  local base = { x = 0, y = 0 }
  if request.anchor then
    local ax, ay = tonumber(request.anchor.x), tonumber(request.anchor.y)
    s.anchor = { x = ax, y = ay }
    base = { x = ax - math.floor(ax), y = ay - math.floor(ay) }
  end
  local variants = {}
  for v, layout in ipairs(request.layouts) do
    local variant, problems = prepare(c, layout)
    if v == 1 and #problems > 0 then s.result = { failed = problems }; return s end
    layout_geometry(variant, base)
    variants[v] = variant
  end
  s.variants = variants
  if s.anchor then return s end
  local site = request.site
  s.site = site
  if #variants[1].self_overlap > 0 then
    s.result = { failed = variants[1].self_overlap, hard = true }
    return s
  end
  if site.on_resource or site.near_water then
    -- The window is read by advance, over ticks (load_step).
    s.load, s.keys = load_start(site), {}
    for v, variant in ipairs(variants) do
      s.keys[v] = key_entity(variant, site.on_resource and "mining-drill" or "offshore-pump")
    end
  else
    s.offsets, s.centres = true, {}
    for v, variant in ipairs(variants) do
      local min_x, min_y, max_x, max_y
      for _, e in ipairs(variant.entities) do
        min_x, max_x = math.min(min_x or e.dx, e.dx), math.max(max_x or e.dx, e.dx)
        min_y, max_y = math.min(min_y or e.dy, e.dy), math.max(max_y or e.dy, e.dy)
      end
      s.centres[v] = { x = round(site.near.x - (min_x + max_x) / 2), y = round(site.near.y - (min_y + max_y) / 2) }
    end
  end
  return s
end

-- The next untried candidate {anchor, v}, most promising first; false when
-- none is left, nil when the work up to limit is spent first.
local function next_candidate(s, limit)
  if s.anchor then
    if s.anchor_taken then return false end
    s.anchor_taken = true
    return { anchor = s.anchor, v = 1 }
  end
  local ctx = s.ctx
  local tiles = s.offsets and site_offsets() or s.tiles
  while s.ti <= #tiles do
    if ctx.calls >= limit then return nil end
    local tile, v = tiles[s.ti], s.vi
    if v >= #s.variants then s.ti, s.vi = s.ti + 1, 1 else s.vi = v + 1 end
    local variant = s.variants[v]
    -- A rotation that collides with itself is never a candidate.
    if #variant.self_overlap == 0 then
      local anchor
      if s.offsets then
        anchor = { x = s.centres[v].x + tile.x, y = s.centres[v].y + tile.y }
      else
        local key = s.keys[v]
        anchor = { x = round(tile.x + 0.5 - key.dx), y = round(tile.y + 0.5 - key.dy) }
      end
      if not s.set or covered(ctx, variant, anchor, s.set, s.numeric_keys) then return { anchor = anchor, v = v } end
    end
  end
  return false
end

-- No site fits: the closest try names what stopped it.
local function not_found(s, out_of_work)
  local site, reason = s.site, nil
  if s.tried == 0 and s.set and not out_of_work then
    reason = "no spot where every drill sits on " .. site.on_resource
  else
    reason = string.format("no site near (%.1f, %.1f) fits after %d tries", site.near.x, site.near.y, s.tried)
    if out_of_work then reason = reason .. " (the search stopped at its work budget; a closer site.near or a smaller count helps)" end
  end
  local failed = s.best and s.best.failed[1]
  if failed then
    reason = string.format("%s; the closest try at anchor (%d, %d) failed: %s", reason, s.best.anchor.x, s.best.anchor.y,
      failed.reason)
  end
  s.result = { failed = { { index = failed and failed.index, connection = failed and failed.connection,
    code = "SITE_NOT_FOUND", reason = reason } } }
  return s.result
end

-- Checks candidates until a site fits or the candidates or work run out
-- (returns the chosen check result: failed empty when buildable), or until
-- this call's budget is spent (returns nil: call again next tick). A
-- candidate whose placement checks are cut off by the budget is checked again
-- from the start of the next call, with the warm cache, while each try gets
-- further; then it fails. Its route searches resume where they stopped.
local function advance(c, s, budget)
  if s.result then return s.result end
  local ctx = s.ctx
  ctx.c = c
  local start = ctx.calls
  local soft = math.min(start + budget, MAX_WORK)
  if s.load then
    if not load_step(s, soft) then
      if ctx.calls >= MAX_WORK then return not_found(s, true) end
      return nil
    end
    if s.result then return s.result end
  end
  while true do
    if not s.pending then
      if ctx.calls >= MAX_WORK then
        if s.anchor then
          s.result = { anchor = s.anchor, failed = { { code = "CHECK_TOO_COSTLY", reason = BUDGET_SPENT } } }
          return s.result
        end
        return not_found(s, true)
      end
      local candidate = next_candidate(s, soft)
      if candidate == nil then return nil end
      if candidate == false then return s.anchor and s.result or not_found(s, false) end
      s.pending, s.deferred, s.checking = candidate, nil, nil
    end
    if ctx.calls >= soft then return nil end
    local candidate = s.pending
    local result = s.checking
    if not result then
      ctx.ceiling, ctx.out_of_budget = math.min(start + 2 * budget, MAX_WORK), false
      result = check(ctx, s.variants[candidate.v], candidate.anchor, s.anchor ~= nil)
      if ctx.out_of_budget then
        -- Checked again next tick with the warm cache, as long as each try
        -- gets further than the last.
        ctx.out_of_budget = false
        local reached = result.passed + #result.failed
        -- (A 0.21.0 search in a loaded save kept a boolean here.)
        if ctx.calls < MAX_WORK and reached > (type(s.deferred) == "number" and s.deferred or -1) then
          s.deferred = reached
          return nil
        end
        result = { anchor = candidate.anchor, passed = 0, failed = { { code = "CHECK_TOO_COSTLY",
          reason = "checking this site needs more work than one tick allows" } } }
      end
    end
    if result.routing then
      -- Routes pause at the tick's share and never fail for it.
      s.checking, ctx.ceiling = result, math.huge
      if not route_more(ctx, s.variants[candidate.v], candidate.anchor, result, soft) then return nil end
    end
    s.pending, s.checking, s.tried = nil, nil, s.tried + 1
    result.rotation = (candidate.v - 1) * 4
    if s.anchor or #result.failed == 0 or result.hard then
      s.result = result
      return result
    end
    if not s.best or result.passed > s.best.passed then s.best = result end
    if s.tried >= MAX_CANDIDATES then return not_found(s, false) end
  end
end

-- build_plan steps in dependency order, each tagged with its layout source.
local function plan_steps(result)
  local ranked = { {}, {}, {} }
  for _, p in ipairs(result.placements) do
    local e = p.entity
    local list = ranked[RANK[e.proto.type] or 1]
    list[#list + 1] = { item = e.item, position = p.position, direction = e.direction, recipe = e.recipe,
      insert = e.insert, settings = e.settings, mirror = e.mirror,
      belt_to_ground_type = e.proto.type == "underground-belt" and belt_end(e) or nil,
      _source = { index = e.index } }
  end
  for _, r in ipairs(result.routes) do
    local list = r.route.kind == "power" and ranked[3] or ranked[1]
    for _, s in ipairs(r.steps) do
      list[#list + 1] = { item = s.name, position = { x = s.x, y = s.y }, direction = s.direction or 0,
        _source = { connection = r.route.index } }
    end
  end
  local steps = {}
  for _, list in ipairs(ranked) do for _, step in ipairs(list) do steps[#steps + 1] = step end end
  return steps
end

local function placed_row(step)
  return { name = step.item, x = step.position.x, y = step.position.y, direction = step.direction }
end

local function materials(c, steps)
  local counts, names = {}, {}
  for _, step in ipairs(steps) do
    if not counts[step.item] then names[#names + 1] = step.item end
    counts[step.item] = (counts[step.item] or 0) + 1
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do out[#out + 1] = { item = name, count = counts[name], carried = c.get_item_count(name) } end
  return out
end

-- ------------------------------------------------------------- requests

local function layout_request(params)
  return { anchor = params.anchor, site = params.site,
    layouts = { { entities = params.entities, connections = params.connections or {} } } }
end

-- A block may be turned to fit its site: all four rotations are variants.
local function block_request(c, params)
  local expanded = blocks.expand(c, params)
  local layouts = {}
  for q = 0, 3 do layouts[q + 1] = rotated(expanded.layout, q) end
  return { site = expanded.site, layouts = layouts, tiers = expanded.tiers }
end

local function report(c, result, extra)
  local steps = result.placements and #result.failed == 0 and plan_steps(result) or {}
  local placed = {}
  for i, step in ipairs(steps) do placed[i] = placed_row(step) end
  local out = { check_only = true, ok = #result.failed == 0, anchor = result.anchor, rotation = result.rotation,
    placed = placed, failed = result.failed, materials = materials(c, steps),
    clears = result.clears and result.clears > 0 and result.clears or nil }
  for k, v in pairs(extra or {}) do out[k] = v end
  return out
end

local function require_check_only(params, label)
  if type(params) ~= "table" or params.check_only ~= true then
    error(label .. " over RPC is a dry run: pass check_only = true, and queue it as a plan step to build", 0)
  end
end

-- RPC build_layout / build_block {.., check_only = true}: a read-only dry run
-- as a job, searching with the build's own budget per tick until it has the
-- site or a definite answer.
local function check_job(label, make_request)
  return {
    start = function(params)
      require_check_only(params, label)
      local c = companion.require_companion()
      local request, extra = make_request(c, params)
      return { search = new_search(c, request), extra = extra }
    end,
    step = function(state, budget)
      local c = companion.require_companion()
      local s = state.search
      local before = s.ctx.calls
      local result = advance(c, s, math.max(1, budget.left))
      budget.left = budget.left - (s.ctx.calls - before)
      if not result then return nil end
      return report(c, result, state.extra)
    end,
  }
end

M.layout_check_job = check_job("build_layout", function(_, params)
  validate_layout(params, "build_layout")
  return layout_request(params)
end)
M.block_check_job = check_job("build_block", function(c, params)
  local request = block_request(c, params)
  return request, { block = params.block, tiers = request.tiers }
end)

-- ----------------------------------------------------------------- runner

local Runner = {}

-- Advances the site search by budget; once decided, starts the build.
local function search(task, c, budget)
  local result = advance(c, task._search, budget)
  if not result then return end
  task._search = nil
  task._anchor, task._rotation = result.anchor, result.rotation
  if #result.failed > 0 then
    task._check_failed = result.failed
    return
  end
  local steps = plan_steps(result)
  if task.block then build_plan.fuel_burners(c, steps) end
  task._plan = { id = task.id, steps = steps, stop_on_error = false }
  build_plan.start(task._plan)
end

-- tasks.lua calls start and then tick in the same game tick, so start only
-- prepares the search; the first tick searches with what the preparation
-- left of one tick's budget.
function Runner.start(task)
  local c = companion.require_companion()
  local request = task.block and block_request(c, task) or layout_request(task)
  task.tiers = request.tiers
  task._search = new_search(c, request)
  task._first_budget = math.max(1, WORK_PER_TICK - task._search.ctx.calls)
end

-- After a human hold the body stands elsewhere: the nested build re-approaches.
function Runner.resume(task)
  local plan = task._plan
  if not plan then return end
  plan._approach, plan._approach_close = nil, nil
  build_plan.resume(plan)
end

function Runner.tick(task)
  local label = task.block and ("build_block " .. task.block) or "build_layout"
  if task._search then
    -- The site search runs over ticks; the build starts on the next one.
    -- What it spends counts against the tick's allowance that read jobs share.
    local budget = task._first_budget or WORK_PER_TICK
    task._first_budget = nil
    local before = task._search.ctx.calls
    local s = task._search
    search(task, companion.require_companion(), budget)
    jobs.charge(s.ctx.calls - before)
    if task._search or task._plan then return nil end
  end
  if task._check_failed then
    local first = task._check_failed[1]
    return { status = "failed",
      detail = string.format("LAYOUT_CHECK_FAILED: %s — %s", label, first.code .. ": " .. tostring(first.reason)),
      outcome = { code = "LAYOUT_CHECK_FAILED", anchor = task._anchor, placed = {}, failed = task._check_failed } }
  end
  local plan = task._plan
  local done = build_plan.tick(plan)
  if not done then return nil end
  local placed, failed = {}, {}
  for i, step in ipairs(plan.steps) do
    local r = plan._results[i]
    if r and r.ok then
      placed[#placed + 1] = placed_row(step)
    else
      failed[#failed + 1] = { index = step._source.index, connection = step._source.connection,
        code = "PLACE_FAILED", reason = r and r.why or done.detail }
    end
  end
  local shortfall
  for item, why in pairs(plan._short or {}) do
    shortfall = shortfall or {}
    shortfall[#shortfall + 1] = { item = item, reason = why }
  end
  if shortfall then table.sort(shortfall, function(a, b) return a.item < b.item end) end
  local status = #failed == 0 and "done" or #placed > 0 and "partial" or "failed"
  local code = status == "done" and "LAYOUT_BUILT" or status == "partial" and "LAYOUT_PARTIAL" or "LAYOUT_FAILED"
  local detail = string.format("%s: placed %d/%d at anchor (%s, %s)", label, #placed, #plan.steps,
    tostring(task._anchor and task._anchor.x), tostring(task._anchor and task._anchor.y))
  if #failed > 0 then detail = detail .. " — first failure: " .. tostring(failed[1].reason) end
  if shortfall then
    local items = {}
    for _, row in ipairs(shortfall) do items[#items + 1] = row.item end
    detail = detail .. " — short of " .. table.concat(items, ", ")
  end
  return { status = status, detail = detail, outcome = { code = code, anchor = task._anchor, rotation = task._rotation,
    tiers = task.tiers, placed = placed, failed = failed, shortfall = shortfall } }
end

-- Plan actions for tasks.register_action.
M.layout_action = {
  runner = Runner,
  make_task = function(step)
    return { anchor = step.anchor, site = step.site, entities = step.entities, connections = step.connections }
  end,
  validate = function(step, index) validate_layout(step, "queue_plan build_layout step " .. index) end,
  -- Each placement and route tile is a step's worth of plan budget.
  budget_steps = function(step)
    local n = type(step.entities) == "table" and #step.entities or 1
    for _, route in ipairs(type(step.connections) == "table" and step.connections or {}) do
      if point(route.from, "dx", "dy") and point(route.to, "dx", "dy") then
        n = n + math.abs(route.to.dx - route.from.dx) + math.abs(route.to.dy - route.from.dy) + 1
      end
    end
    return n
  end,
}

M.block_action = {
  runner = Runner,
  make_task = function(step)
    return { block = step.block, count = step.count, resource = step.resource, recipe = step.recipe, near = step.near,
      blueprint = step.blueprint }
  end,
  validate = function(step, index) blocks.validate(step, "queue_plan build_block step " .. index) end,
  budget_steps = function(step) return blocks.budget_steps(step) end,
}

-- For tests: a whole search, one tick's budget at a time.
local function resolve(c, request)
  local s = new_search(c, request)
  local result
  repeat result = advance(c, s, WORK_PER_TICK) until result
  return result, s
end
M._resolve, M._rotated, M._block_request, M._plan_steps = resolve, rotated, block_request, plan_steps
-- The resumable search for another dry run (blueprint_place check_only):
-- search_start(c, {anchor? | site?, layouts}), search_step(c, s, budget) ->
-- result | nil, check_report(c, result, extra) -> the check_only answer.
M.search_start, M.search_step, M.check_report = new_search, advance, report
M.validate_layout = validate_layout
M.WORK_PER_TICK, M.MAX_WORK = WORK_PER_TICK, MAX_WORK

return M
