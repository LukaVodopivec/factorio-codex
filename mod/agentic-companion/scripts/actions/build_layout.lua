-- build_layout and build_block: the bot gives a layout as offsets (dx, dy)
-- from an anchor, or a site request (near a point, on a resource, near
-- water or another liquid: near_liquid water, lava, heavy-oil or
-- ammoniacal-solution); the mod finds the site, checks every placement and connection
-- route, then builds it all through build_plan (auto-supply, auto-clear,
-- recipes) in dependency order: recipients first, then the drills and
-- inserters that feed them, poles last. check_only is the same resolution
-- without any side effect, run as a job (jobs.lua) over as many ticks as the
-- build's own search would take, so it returns the site or a definite
-- SITE_NOT_FOUND; it may name another planet's `surface` to check a layout
-- there while the body is away (nothing counts as the body in the way).
-- An entity or recipe whose surface conditions the surface breaks fails
-- SURFACE_CONDITION before any site is searched. build_block expands a parametric block
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
--
-- mode "ghosts" places the layout as ghosts instead: a transient blueprint
-- on a planet, checked native ghosts on a platform. Recipes and settings ride
-- along; robots build them on a planet. `platform` (implies ghosts) builds
-- on a space platform remotely, with no body: the anchor is relative to the
-- hub, `tiles`/`tile_rects` add foundation tile ghosts (each must touch
-- existing or planned foundation), and the hub builds everything from its
-- own inventory. Ghosts never give items. Everything is checked first and
-- nothing is placed when anything fails. Result {anchor, platform,
-- ghosts_placed, tiles_placed, already, failed, missing (what the hub lacks
-- for these ghosts)}.
local companion = require("scripts.companion")
local placement_geometry = require("scripts.placement_geometry")
local connect_entities = require("scripts.connect_entities")
local build_plan = require("scripts.actions.build_plan")
local build = require("scripts.actions.build")
local blocks = require("scripts.blocks")
local entity_settings = require("scripts.entity_settings")
local jobs = require("scripts.jobs")
local blueprints = require("scripts.blueprints")
local platforms = require("scripts.platforms")
local surfaces = require("scripts.surfaces")

-- The liquids a site may be near (site.near_liquid); near_water is water.
local LIQUIDS = { water = true, lava = true, ["heavy-oil"] = true, ["ammoniacal-solution"] = true }
local function site_liquid(site)
  return site.near_liquid or (site.near_water and "water") or nil
end

local M = {}

local MAX_ENTITIES, MAX_CONNECTIONS, MAX_ROUTE, MAX_STEPS = 100, 32, connect_entities.MAX_LENGTH, 200
local SITE_RADIUS = 24        -- anchors tried around site.near
local SEARCH_RADIUS = 32      -- resource and liquid read around site.near
local MAX_CANDIDATES = 600
local ROUTE_TYPES = { belt = "transport-belt", pipe = "pipe", power = "electric-pole" }
local NATURAL = { tree = true, ["simple-entity"] = true }
-- Build order: recipients (rank 1) before what feeds them, poles last.
local RANK = { inserter = 2, ["mining-drill"] = 2, ["electric-pole"] = 3 }
-- Platform foundation a layout adds: entries in tiles, and tiles in all.
local MAX_TILE_ENTRIES, MAX_TILES = 400, 1000
local MAX_TILE_ROWS = 16      -- tile failures listed in a result
local EMPTY = 0               -- a tile_state: empty space (never a tile name)

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

-- The tile a tile or tile-placing item name lays, and the item that lays
-- it; nil when neither names one.
local function tile_of(name)
  local item = prototypes.item[name]
  local ok, result = pcall(function() return item and item.place_as_tile_result end)
  local tile = ok and result and result.result
  if tile then return tile.name, name end
  local proto = prototypes.tile[name]
  local ok_items, places = pcall(function() return proto and proto.items_to_place_this end)
  local first = ok_items and type(places) == "table" and places[1] or nil
  local item_name = type(first) == "table" and first.name or type(first) == "string" and first or nil
  if item_name then return name, item_name end
end

local function integer(value) return type(value) == "number" and value % 1 == 0 end

-- tiles: [{name, dx, dy}] and tile_rects: [{name, from:{dx,dy}, to:{dx,dy}}]
-- (corners inclusive). Returns how many tiles they name.
local function validate_tiles(params, label)
  local tiles, rects, total = params.tiles, params.tile_rects, 0
  if tiles ~= nil then
    if type(tiles) ~= "table" or #tiles > MAX_TILE_ENTRIES then
      error(string.format("%s tiles must list at most %d {name, dx, dy}", label, MAX_TILE_ENTRIES), 0)
    end
    for i, t in ipairs(tiles) do
      if type(t) ~= "table" or type(t.name) ~= "string" or not integer(t.dx) or not integer(t.dy) then
        error(string.format("%s tiles[%d] must be {name, dx, dy} with integer offsets", label, i - 1), 0)
      end
      if not tile_of(t.name) then
        error(string.format("UNKNOWN_TILE: %s tiles[%d] names no tile or tile item '%s'", label, i - 1, t.name), 0)
      end
    end
    total = #tiles
  end
  if rects ~= nil then
    if type(rects) ~= "table" then error(label .. " tile_rects must be a list", 0) end
    for i, r in ipairs(rects) do
      local at = string.format("%s tile_rects[%d]", label, i - 1)
      if type(r) ~= "table" or type(r.name) ~= "string" or type(r.from) ~= "table" or type(r.to) ~= "table"
        or not (integer(r.from.dx) and integer(r.from.dy) and integer(r.to.dx) and integer(r.to.dy)) then
        error(at .. " must be {name, from:{dx,dy}, to:{dx,dy}} with integer offsets (corners included)", 0)
      end
      if not tile_of(r.name) then error(string.format("UNKNOWN_TILE: %s names no tile or tile item '%s'", at, r.name), 0) end
      total = total + (math.abs(r.to.dx - r.from.dx) + 1) * (math.abs(r.to.dy - r.from.dy) + 1)
      if total > MAX_TILES then break end
    end
  end
  if total > MAX_TILES then error(string.format("%s tiles and tile_rects name more than %d tiles", label, MAX_TILES), 0) end
  return total
end

local function validate_layout(params, label)
  local entities = params.entities
  local mode, platform = params.mode, params.platform
  if mode ~= nil and mode ~= "hand" and mode ~= "ghosts" then error(label .. ' mode must be "hand" or "ghosts"', 0) end
  local tile_count = 0
  if platform ~= nil then
    platforms.check_selector(platform, label .. " platform")
    if mode == "hand" then
      error("NO_BODY_ON_SURFACE: " .. label .. " on a platform is built from ghosts (mode ghosts): the body is not there", 0)
    end
    if params.site ~= nil then error(label .. " on a platform takes an anchor relative to the hub, not a site", 0) end
    tile_count = validate_tiles(params, label)
  elseif params.tiles ~= nil or params.tile_rects ~= nil then
    error(label .. " tiles and tile_rects are platform foundation (with platform); on a planet place_tiles lays tiles", 0)
  end
  local ghosts = mode == "ghosts" or platform ~= nil
  -- A route-only layout (no entities, connections from an anchor) joins
  -- what already stands; a platform layout may lay foundation only.
  local route_only = type(entities) == "table" and #entities == 0 and params.anchor ~= nil
    and (type(params.connections) == "table" and #params.connections > 0 or tile_count > 0)
  if type(entities) ~= "table" or (#entities < 1 and not route_only) or #entities > MAX_ENTITIES then
    error(string.format("%s entities must be 1-%d placements (none only for connections or tiles from an anchor)", label,
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
    if e.insert ~= nil and ghosts then
      error(string.format("%s entities[%d].insert is for hand builds: ghosts take no starter items", label, i - 1), 0)
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
    if site.near_liquid ~= nil and not LIQUIDS[site.near_liquid] then
      error(label .. " site.near_liquid must be water, lava, heavy-oil or ammoniacal-solution", 0)
    end
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
-- A numeric tile key (no tile is a million tiles from the origin).
local function cell(x, y) return x * 2097152 + y end

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

-- Name-level checks no site can fix, on the surface the layout goes on
-- (its surface conditions too). Returns the variant and its failures.
local function prepare(c, layout, surface)
  local variant, failed = { entities = {}, connections = {} }, {}
  for i, e in ipairs(layout.entities) do
    local item, proto = placeable(e.name)
    if not item then
      failed[#failed + 1] = { index = i - 1, code = "UNKNOWN_ENTITY", reason = "no placeable item or entity called '" .. e.name .. "'" }
    else
      local refused = placement_geometry.condition_refusal(surface, "entity", proto.name)
        or e.recipe and placement_geometry.condition_refusal(surface, "recipe", e.recipe)
      if refused then failed[#failed + 1] = { index = i - 1, code = refused.code, reason = refused.reason } end
      if e.recipe then
        local recipe = c.force.recipes[e.recipe]
        local why
        if not recipe then why = { "RECIPE_UNKNOWN", "unknown recipe '" .. e.recipe .. "'" }
        elseif not recipe.enabled then why = { "RECIPE_LOCKED", "recipe " .. e.recipe .. " isn't unlocked yet — research it first" }
        elseif proto.type ~= "assembling-machine" then
          why = { "RECIPE_NOT_SETTABLE", proto.type == "furnace" and (e.name .. " is a furnace; it picks its recipe from what it is fed")
            or (e.name .. " can't have a recipe set — only assembling machines can") }
        else
          local ok, categories = pcall(function() return proto.crafting_categories end)
          if ok and type(categories) == "table" and not categories[recipe.category] then
            why = { "RECIPE_NOT_SETTABLE", string.format("%s can't craft %s (a %s recipe)", e.name, e.recipe,
              tostring(recipe.category)) }
          end
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

-- The surface and force a search builds on: a platform's (ghosts, no body)
-- or the body's.
local function where(ctx)
  local space = ctx.space
  return space and space.surface or ctx.c.surface, ctx.c.force
end

-- Every chunk under the area is charted (chunk answers cached per search).
-- A platform is the force's own and always readable.
local function charted(ctx, area)
  if ctx.space then return true end
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

-- What lies at a tile: EMPTY (empty space), its tile name, or nil when it
-- cannot be read. One work item per tile read; cached per search.
local function tile_state(ctx, x, y)
  local states = ctx.tile_states
  local key = cell(x, y)
  local value = states[key]
  if value == nil then
    ctx.calls = ctx.calls + 1
    local surface = where(ctx)
    local ok, name, empty = pcall(function()
      local tile = surface.get_tile(x, y)
      return tile.name, tile.collides_with("empty_space")
    end)
    if not ok then value = "?" elseif empty then value = EMPTY else value = name end
    states[key] = value
  end
  if value == "?" then return nil end
  return value
end

local function same_spot(a, b) return math.abs(a.x - b.x) < 0.01 and math.abs(a.y - b.y) < 0.01 end

-- Whether a ghost of proto can go at pos: the engine's manual-ghost check;
-- a footprint over planned foundation tiles (not laid yet) counts as fine
-- unless an own entity stands in it. The same entity or its ghost already
-- there is "ALREADY". Returns ok, reason, note.
local function ghost_ground(ctx, proto, pos, direction)
  local surface, force = where(ctx)
  local area = placement_geometry.footprint(proto, pos, direction)
  if not charted(ctx, area) then return false, "the footprint is not charted" end
  local planned = false
  if ctx.planned then each_tile(area, function(x, y) planned = planned or ctx.planned[cell(x, y)] == true end) end
  if planned then
    -- Over planned foundation every other footprint tile must be laid.
    local bare = false
    each_tile(area, function(x, y)
      if not bare and not ctx.planned[cell(x, y)] then
        local now = tile_state(ctx, x, y)
        bare = now == nil or now == EMPTY
      end
    end)
    if bare then return false, "part of the footprint has no foundation or planned foundation" end
  else
    ctx.calls = ctx.calls + 1
    local ok, placeable = pcall(surface.can_place_entity, { name = proto.name,
      position = pos, direction = direction, force = force, build_check_type = defines.build_check_type.manual_ghost,
      forced = not ctx.space or nil })
    if ok and placeable then return true end
  end
  ctx.calls = ctx.calls + 1
  local found_ok, found = pcall(surface.find_entities_filtered, { area = area, force = force, limit = 9 })
  local blocker
  for _, e in ipairs(found_ok and found or {}) do
    if e.valid and e.type ~= "tile-ghost" and not placement_geometry.NON_BLOCKING_TYPES[e.type] then
      local name = e.type == "entity-ghost" and e.ghost_name or e.name
      if name == proto.name and same_spot(e.position, pos) and (e.direction or 0) == direction then return true, nil, "ALREADY" end
      blocker = blocker or e
    end
  end
  if blocker then
    return false, string.format("blocked by %s at (%.1f, %.1f)", blocker.type == "entity-ghost" and blocker.ghost_name
      .. " (ghost)" or blocker.name, blocker.position.x, blocker.position.y)
  end
  if planned then return true, nil, "NEEDS_PLANNED_TILES" end
  return false, ctx.space and "nothing it can stand on there: no foundation, or a spot this entity refuses"
    or "the ground there is water or otherwise unbuildable"
end

-- Whether proto can stand at pos for this build: placeable now, or only
-- Codex's body (it steps aside) or trees and rocks (placing mines them) are
-- in the way. Ghosts: ghost_ground. Returns ok, reason, clears, note.
-- Cached per search.
local function ground(ctx, proto, pos, direction)
  if not spend(ctx, 1) then return false, BUDGET_SPENT end
  local key = string.format("%s|%.2f|%.2f|%d", proto.name, pos.x, pos.y, direction)
  local hit = ctx.cache[key]
  if hit then return hit[1], hit[2], hit[3], hit[4] end
  if not spend(ctx, 3) then return false, BUDGET_SPENT end
  local c = ctx.c
  local area = placement_geometry.footprint(proto, pos, direction)
  local ok, reason, clears, note
  if ctx.ghosts then
    ok, reason, note = ghost_ground(ctx, proto, pos, direction)
  elseif not charted(ctx, area) then
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
  ctx.cache[key] = { ok, reason, clears, note }
  return ok, reason, clears, note
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
  local surface, force = where(ctx)
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
        local found_ok, found = pcall(surface.find_entities_filtered,
          { position = pos, radius = 0.5, type = "electric-pole", force = force })
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
          local found_ok, found = pcall(surface.find_entities_filtered, { area = area, name = under.proto.name })
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
    local ok, reason, clears, note = ground(ctx, e.proto, position, e.direction)
    if ctx.out_of_budget then return result end
    if ok then
      result.passed = result.passed + 1
      if clears then result.clears = result.clears + 1 end
      -- Ghosts: standing already, or waiting for planned foundation.
      if note then
        result.notes = result.notes or {}
        result.notes[i] = { note = note, index = e.index }
      end
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

-- The liquid tiles of a fluid (water, lava, heavy-oil,
-- ammoniacal-solution): tiles on the water_tile layer whose fluid it is
-- (placement_geometry's liquid rule), listed once per load.
local liquid_names = {}
local function liquid_tile_names(fluid)
  if liquid_names[fluid] then return liquid_names[fluid] end
  local names = {}
  for name, proto in pairs(prototypes.tile) do
    local ok, layers = pcall(function() return proto.collision_mask.layers end)
    local fluid_ok, tile_fluid = pcall(function() return proto.fluid.name end)
    if ok and type(layers) == "table" and layers.water_tile and fluid_ok and tile_fluid == fluid then names[#names + 1] = name end
  end
  table.sort(names)
  liquid_names[fluid] = names
  return names
end

-- The resource or liquid window around site.near (SEARCH_RADIUS) is read as
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
  return { kind = site.on_resource and "resource" or "liquid", liquid = site_liquid(site), row = math.floor(site.near.y - SEARCH_RADIUS),
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
      local ok, found = pcall(ctx.c.surface.find_tiles_filtered, { area = area, name = liquid_tile_names(L.liquid or "water") })
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
      or string.format("no %s within %d tiles of (%.1f, %.1f)", L.liquid or "water", SEARCH_RADIUS, near.x, near.y) } } }
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

-- ------------------------------------------------------ platform foundation

local NEIGHBOURS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }

local function tile_failed(F, t, code, reason)
  F.failed_count = F.failed_count + 1
  if #F.failed < MAX_TILE_ROWS then F.failed[#F.failed + 1] = { tile = { x = t.x, y = t.y }, code = code, reason = reason } end
end

-- Checks the layout's foundation tiles within the work up to limit (true
-- once done), resumable over ticks in three passes:
--   read  every tile: already this foundation is skipped; anything but
--         empty space is refused; an empty tile is a candidate, and one that
--         touches laid foundation (4 sides) seeds the next pass
--   grow  from the seeds through touching candidates (a flood fill): only
--         what it reaches is connected to the platform and becomes
--         ctx.planned (which the entity checks count as foundation), in the
--         order reached, so each new tile touches laid foundation or one
--         before it
--   keep  the candidates it did not reach are an island that touches no
--         foundation, and fail
-- F.empty maps a candidate's cell to its index in F.list; the queue holds
-- indices, so the state stays plain data.
local function foundation_step(s, limit)
  local F, ctx = s.foundation, s.ctx
  F.pass, F.empty, F.queue, F.qi, F.reached = F.pass or "read", F.empty or {}, F.queue or {}, F.qi or 1, F.reached or {}
  if F.pass == "read" then
    while F.i <= #F.list do
      if ctx.calls >= limit then return false end
      local t = F.list[F.i]
      local now = tile_state(ctx, t.x, t.y)
      if now == nil then
        tile_failed(F, t, "TILE_UNREADABLE", "the tile could not be read")
      elseif now == t.tile then
        F.already = F.already + 1
      elseif now ~= EMPTY then
        tile_failed(F, t, "TILE_OCCUPIED", string.format("(%d, %d) is %s already", t.x, t.y, now))
      else
        F.empty[cell(t.x, t.y)] = F.i
        for _, d in ipairs(NEIGHBOURS) do
          local next_to = tile_state(ctx, t.x + d[1], t.y + d[2])
          if next_to ~= nil and next_to ~= EMPTY then F.queue[#F.queue + 1] = F.i; break end
        end
      end
      F.i = F.i + 1
    end
    F.pass = "grow"
  end
  if F.pass == "grow" then
    while F.qi <= #F.queue do
      if ctx.calls >= limit then return false end
      local i = F.queue[F.qi]
      F.qi = F.qi + 1
      ctx.calls = ctx.calls + 1
      if not F.reached[i] then
        F.reached[i] = true
        local t = F.list[i]
        ctx.planned[cell(t.x, t.y)] = true
        F.new[#F.new + 1] = t
        for _, d in ipairs(NEIGHBOURS) do
          local j = F.empty[cell(t.x + d[1], t.y + d[2])]
          if j and not F.reached[j] then F.queue[#F.queue + 1] = j end
        end
      end
    end
    F.pass, F.ki = "keep", 1
  end
  while F.ki <= #F.list do
    if ctx.calls >= limit then return false end
    local i = F.ki
    F.ki = F.ki + 1
    local t = F.list[i]
    if not F.reached[i] and F.empty[cell(t.x, t.y)] == i then
      tile_failed(F, t, "TILE_NOT_ADJACENT", string.format("(%d, %d) touches no foundation and no planned tile that does", t.x, t.y))
    end
    if F.ki % LOAD_PER_ITEM == 0 then ctx.calls = ctx.calls + 1 end
  end
  F.empty, F.queue, F.reached, F.done = nil, nil, nil, true
  return true
end

-- The foundation's verdicts join the entity checks' result.
local function with_foundation(s, result)
  local F = s.foundation
  if not F or result.foundation then return result end
  local failed = {}
  for i, row in ipairs(F.failed) do failed[i] = row end
  for _, row in ipairs(result.failed) do failed[#failed + 1] = row end
  result.failed = failed
  result.foundation = { new = F.new, already = F.already, failed = F.failed_count,
    omitted_failed = F.failed_count > #F.failed and F.failed_count - #F.failed or nil }
  return result
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
  local ctx = { c = c, calls = 0, ceiling = 0, cache = {}, chunks = {}, ghosts = request.ghosts, space = request.space }
  local s = { ctx = ctx, tried = 0, ti = 1, vi = 1 }
  if request.tiles and #request.tiles > 0 then
    -- Platform foundation: checked first (foundation_step), over ticks.
    ctx.calls = ctx.calls + math.ceil(#request.tiles / LOAD_PER_ITEM)
    ctx.planned, ctx.tile_states = {}, {}
    s.foundation = { list = request.tiles, i = 1, new = {}, already = 0, failed = {}, failed_count = 0 }
  end
  local base = { x = 0, y = 0 }
  if request.anchor then
    local ax, ay = tonumber(request.anchor.x), tonumber(request.anchor.y)
    s.anchor = { x = ax, y = ay }
    base = { x = ax - math.floor(ax), y = ay - math.floor(ay) }
  end
  local variants = {}
  for v, layout in ipairs(request.layouts) do
    local variant, problems = prepare(c, layout, request.space and request.space.surface or c.surface)
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
  if site.on_resource or site_liquid(site) then
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
  if ctx.space and not ctx.space.surface.valid then
    s.result = { failed = { { code = "UNKNOWN_PLATFORM", reason = "the platform is gone" } } }
    return s.result
  end
  if s.foundation and not s.foundation.done then
    if not foundation_step(s, soft) then return nil end
  end
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
      s.result = with_foundation(s, result)
      return s.result
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
        belt_to_ground_type = s.belt_to_ground_type, _source = { connection = r.route.index } }
    end
  end
  local steps = {}
  for _, list in ipairs(ranked) do for _, step in ipairs(list) do steps[#steps + 1] = step end end
  return steps
end

local function placed_row(step)
  local built = step._placed_entity
  local row = { name = step.item, x = step.position.x, y = step.position.y, direction = step.direction }
  if built and built.valid then
    row.x, row.y, row.direction = built.position.x, built.position.y, built.direction
    row.underground = build.underground_pairing(built)
    if row.underground then row.belt_to_ground_type = row.underground.belt_to_ground_type end
  end
  return row
end

local function materials(c, steps)
  local counts, names = {}, {}
  for _, step in ipairs(steps) do
    if not counts[step.item] then names[#names + 1] = step.item end
    counts[step.item] = (counts[step.item] or 0) + 1
  end
  table.sort(names)
  local out = {}
  -- A viewpoint on another surface carries nothing.
  for _, name in ipairs(names) do
    out[#out + 1] = { item = name, count = counts[name], carried = c.get_item_count and c.get_item_count(name) or 0 }
  end
  return out
end

-- ---------------------------------------------------------------- ghosts

local function ghost_key(name, position) return string.format("%s|%.2f|%.2f", name, position.x, position.y) end

-- The ghosts a decided layout places: blueprint entity and tile rows at
-- their world positions (each entity's footprint corner in corners), the
-- {name, position} keys they must land on, the items they take, and placed
-- rows. Entities already standing are left out (so is foundation already
-- laid). Tiles keep the foundation check's order: each touches laid
-- foundation or a tile before it.
local function ghost_plan(result)
  local plan = { entities = {}, corners = {}, tiles = {}, expected = {}, items = {}, order = {}, placed = {} }
  local function take(item)
    if not plan.items[item] then plan.order[#plan.order + 1] = item end
    plan.items[item] = (plan.items[item] or 0) + 1
  end
  local function add(name, item, proto, position, direction, extra)
    local row = { name = name, position = { x = position.x, y = position.y } }
    if direction ~= 0 then row.direction = direction end
    for k, v in pairs(extra or {}) do row[k] = v end
    plan.entities[#plan.entities + 1] = row
    plan.corners[#plan.entities] = placement_geometry.footprint(proto, position, direction).left_top
    plan.expected[ghost_key(name, position)] = true
    plan.placed[#plan.placed + 1] = { name = item, x = position.x, y = position.y, direction = direction }
    take(item)
  end
  for i, p in ipairs(result.placements or {}) do
    if not (result.notes and result.notes[i] and result.notes[i].note == "ALREADY") then
      local e = p.entity
      local row = { recipe = e.recipe, mirror = e.mirror or nil,
        type = e.proto.type == "underground-belt" and belt_end(e) or nil }
      if e.settings then entity_settings.to_blueprint(e.settings, row, e.proto.type) end
      add(e.proto.name, e.item, e.proto, p.position, e.direction, row)
    end
  end
  for _, routed in ipairs(result.routes or {}) do
    local proto = routed.route.proto
    for _, step in ipairs(routed.steps) do
      local item = prototypes.item[step.name]
      local entity = item and item.place_result or proto
      add(entity.name, step.name, entity, { x = step.x, y = step.y }, step.direction or 0, { type = step.belt_to_ground_type })
    end
  end
  for _, t in ipairs(result.foundation and result.foundation.new or {}) do
    plan.tiles[#plan.tiles + 1] = { name = t.tile, position = { x = t.x, y = t.y } }
    plan.expected["tile|" .. t.tile .. "|" .. cell(t.x, t.y)] = true
    take(t.item)
  end
  return plan
end

-- What the ghosts take against what the hub holds (platforms): materials
-- [{item, count, in_hub?}] and missing [{item, count}] (nil on a planet,
-- where robots bring them from the network).
local function ghost_materials(ctx, plan)
  local hub = ctx.space and ctx.space.hub
  local main = hub and hub.valid and hub.get_inventory(defines.inventory.hub_main) or nil
  local materials, missing = {}, ctx.space and {} or nil
  local names = {}
  for _, item in ipairs(plan.order) do names[#names + 1] = item end
  table.sort(names)
  for _, item in ipairs(names) do
    local count = plan.items[item]
    local have = main and main.get_item_count({ name = item, quality = "normal" }) or nil
    materials[#materials + 1] = { item = item, count = count, in_hub = have }
    if missing and count > (have or 0) then missing[#missing + 1] = { item = item, count = count - (have or 0) } end
  end
  return materials, missing
end

-- Layout indexes the ghost checks noted (ALREADY, NEEDS_PLANNED_TILES).
local function noted(result, note)
  local out = {}
  for _, value in pairs(result.notes or {}) do
    if value.note == note then out[#out + 1] = value.index end
  end
  table.sort(out)
  return #out > 0 and out or nil
end

local function platform_row(ctx)
  local space = ctx.space
  return space and { index = space.platform, name = space.name } or nil
end

-- Ghosts one tick places: each is built, raises its built event and is read
-- back (GHOST_WORK work items). Platform entity rechecks cost up to two
-- more calls, so its smaller batch stays within a tick's allowance.
local GHOST_BATCH, PLATFORM_GHOST_BATCH, GHOST_WORK = 200, 120, 3

-- Starts placing the decided layout's ghosts: the plan, what they take and
-- the outcome so far; place_batch places them over ticks. Plain data plus
-- the ghosts placed so far.
local function begin_ghosts(ctx, result)
  local plan = ghost_plan(result)
  local materials, missing = ghost_materials(ctx, plan)
  local outcome = { anchor = result.given_anchor or result.anchor, platform = platform_row(ctx),
    surface = ctx.space and ("platform:" .. ctx.space.platform) or nil, hub = ctx.space and ctx.space.hub_position or nil,
    ghosts_placed = 0, tiles_placed = 0, already = noted(result, "ALREADY"),
    tiles_already = result.foundation and result.foundation.already or nil, failed = {}, materials = materials,
    missing = missing and #missing > 0 and missing or nil }
  return { ctx = ctx, plan = plan, outcome = outcome, next = 1, placed = {} }
end

local function remove_placed(g)
  for _, ghost in ipairs(g.placed) do if ghost.valid then pcall(ghost.destroy) end end
  g.outcome.ghosts_placed, g.outcome.tiles_placed = 0, 0
end

-- Places the next batch (foundation tiles first, in the order the check
-- connected them, then entities). On a platform create the checked ghosts
-- directly: build_blueprint rejects entities over pending foundation even
-- when that blueprint includes the tiles. The hub still builds each ghost
-- from its own stock; no foundation or machine is supplied here.
-- On a planet one transient blueprint is aligned to the
-- world grid (absolute snapping, 1x1) and built at its box's corner (a
-- snapped blueprint is aligned by its box, so positions are relative to the
-- batch's top-left tile), forced on a planet (trees and rocks are marked for
-- deconstruction). Every ghost is read back: one off its spot means the
-- blueprint landed elsewhere, so all of them, earlier batches' too, are
-- removed again and the step fails; so does an incomplete batch.
-- Returns the step result once the last batch is placed (or one failed),
-- else nil, and the ghosts this call handled.
local function place_batch(c, g, label)
  local ctx, plan, outcome = g.ctx, g.plan, g.outcome
  local surface, force = where(ctx)
  local n_tiles, total = #plan.tiles, #plan.tiles + #plan.entities
  if total == 0 then
    outcome.code = "LAYOUT_ALREADY_PLACED"
    return { status = "done", detail = label .. ": everything in the layout stands or is ghosted already", outcome = outcome }, 0
  end
  local batch = ctx.space and PLATFORM_GHOST_BATCH or GHOST_BATCH
  local from, to = g.next, math.min(g.next + batch - 1, total)
  g.next = to + 1
  local ghosts, ok = {}, true
  if ctx.space then
    for k = from, to do
      local tile = k <= n_tiles
      local source = tile and plan.tiles[k] or plan.entities[k - n_tiles]
      local args = {}
      for key, value in pairs(source) do args[key] = value end
      args.name, args.inner_name = tile and "tile-ghost" or "entity-ghost", source.name
      args.position = { x = source.position.x + (tile and 0.5 or 0), y = source.position.y + (tile and 0.5 or 0) }
      args.force, args.raise_built = force, true
      local allowed, why, note = true, nil, nil
      if not tile then
        allowed, why, note = ghost_ground(ctx, prototypes.entity[source.name], source.position, source.direction or 0)
        if note == "ALREADY" then allowed, why = false, "the entity appeared after the layout check" end
      end
      local created, ghost = false, nil
      if allowed then created, ghost = pcall(surface.create_entity, args) end
      if created and ghost and ghost.valid then ghosts[#ghosts + 1] = ghost else
        outcome.failed[#outcome.failed + 1] = { name = source.name, position = source.position,
          code = "GHOST_NOT_PLACED", reason = why or (created and "the game returned no ghost" or plain(ghost)) }
        break
      end
    end
  else
    local left, top = math.huge, math.huge
    for k = from, to do
      local corner = k <= n_tiles and plan.tiles[k].position or plan.corners[k - n_tiles]
      left, top = math.min(left, corner.x), math.min(top, corner.y)
    end
    local origin = { x = math.floor(left + 0.01), y = math.floor(top + 0.01) }
    local entities, tiles = {}, {}
    for k = from, to do
      local source = k <= n_tiles and plan.tiles[k] or plan.entities[k - n_tiles]
      local row = {}
      for key, value in pairs(source) do row[key] = value end
      row.position = { x = source.position.x - origin.x, y = source.position.y - origin.y }
      if k <= n_tiles then tiles[#tiles + 1] = row else
        row.entity_number = #entities + 1
        entities[#entities + 1] = row
      end
    end
    local stack = blueprints.scratch()
    if #entities > 0 then stack.set_blueprint_entities(entities) end
    if #tiles > 0 then stack.set_blueprint_tiles(tiles) end
    stack.blueprint_snap_to_grid = { x = 1, y = 1 }
    stack.blueprint_absolute_snapping = true
    stack.blueprint_position_relative_to_grid = { x = 0, y = 0 }
    ok, ghosts = pcall(stack.build_blueprint, { surface = surface, force = force, position = origin,
      build_mode = defines.build_mode.forced, skip_fog_of_war = true, raise_built = true })
    blueprints.clear_scratch()
  end
  local misplaced, placed = nil, 0
  for _, ghost in ipairs(ok and ghosts or {}) do
    if ghost.valid then
      local tile = ghost.type == "tile-ghost"
      local key = tile and ("tile|" .. ghost.ghost_name .. "|" .. cell(math.floor(ghost.position.x), math.floor(ghost.position.y)))
        or ghost_key(ghost.ghost_name, ghost.position)
      if not plan.expected[key] then misplaced = misplaced or ghost end
      g.placed[#g.placed + 1] = ghost
      placed = placed + 1
      if tile then outcome.tiles_placed = outcome.tiles_placed + 1 else outcome.ghosts_placed = outcome.ghosts_placed + 1 end
    end
  end
  local handled = to - from + 1
  if misplaced then
    local name, at = misplaced.ghost_name, misplaced.position
    remove_placed(g)
    outcome.code = "GHOSTS_MISPLACED"
    return { status = "failed", outcome = outcome,
      detail = string.format("GHOSTS_MISPLACED: %s: the game put a %s ghost at (%.1f, %.1f), off the layout; all removed again",
        label, name, at.x, at.y) }, handled
  end
  if placed ~= handled then
    remove_placed(g)
    outcome.code = "GHOSTS_NOT_PLACED"
    return { status = "failed", outcome = outcome,
      detail = string.format("GHOSTS_NOT_PLACED: %s: the game placed %d/%d requested ghosts; all removed again%s", label,
        placed, handled, ok and (#outcome.failed > 0 and (": " .. outcome.failed[1].reason) or "") or (": " .. plain(ghosts))) }, handled
  end
  if g.next <= total then return nil, handled end
  outcome.code = "GHOSTS_PLACED"
  local detail = string.format("%s: %d ghosts and %d foundation tiles placed%s", label, outcome.ghosts_placed,
    outcome.tiles_placed, ctx.space and (" on platform " .. ctx.space.name .. "; its hub builds them") or "; robots build them")
  if outcome.missing then
    local items = {}
    for _, row in ipairs(outcome.missing) do items[#items + 1] = row.count .. " " .. row.item end
    detail = detail .. " — the hub lacks " .. table.concat(items, ", ")
  end
  return { status = "done", detail = detail, outcome = outcome }, handled
end

-- ------------------------------------------------------------- requests

-- A platform layout: its hub (anchors are relative to it) and surface.
local function platform_space(c, selector)
  local p, code, why = platforms.resolve(c.force, selector)
  if not p then error(code .. ": " .. why, 0) end
  local hub = p.hub
  if not (hub and hub.valid) then
    error("NO_HUB: platform " .. p.name .. " has no hub yet: launch its starter pack to it first", 0)
  end
  return { platform = p.index, name = p.name, surface = p.surface, hub = hub,
    hub_position = { x = hub.position.x, y = hub.position.y } }
end

-- Platform foundation as absolute tiles {tile, item, x, y}, each once.
local function expand_tiles(params, anchor)
  local list, seen = {}, {}
  local function add(name, dx, dy)
    local x, y = math.floor(anchor.x + dx), math.floor(anchor.y + dy)
    if seen[cell(x, y)] then return end
    seen[cell(x, y)] = true
    local tile, item = tile_of(name)
    list[#list + 1] = { tile = tile, item = item, x = x, y = y }
  end
  for _, t in ipairs(params.tiles or {}) do add(t.name, t.dx, t.dy) end
  for _, r in ipairs(params.tile_rects or {}) do
    for dy = math.min(r.from.dy, r.to.dy), math.max(r.from.dy, r.to.dy) do
      for dx = math.min(r.from.dx, r.to.dx), math.max(r.from.dx, r.to.dx) do add(r.name, dx, dy) end
    end
  end
  return list
end

local function layout_request(c, params)
  local request = { anchor = params.anchor, site = params.site,
    layouts = { { entities = params.entities, connections = params.connections or {} } },
    ghosts = params.mode == "ghosts" or params.platform ~= nil or nil }
  if params.platform ~= nil then
    local space = platform_space(c, params.platform)
    local at = space.hub_position
    request.space, request.given_anchor = space, params.anchor
    request.anchor = { x = at.x + params.anchor.x, y = at.y + params.anchor.y }
    request.tiles = expand_tiles(params, request.anchor)
  end
  return request
end

-- A block may be turned to fit its site: all four rotations are variants.
local function block_request(c, params)
  local expanded = blocks.expand(c, params)
  local layouts = {}
  for q = 0, 3 do layouts[q + 1] = rotated(expanded.layout, q) end
  return { site = expanded.site, layouts = layouts, tiers = expanded.tiers }
end

-- The check_only answer of a ghost layout: what would be ghosted, what
-- stands already, what waits for planned foundation, and the items.
local function ghost_report(ctx, result, extra)
  local ok = #result.failed == 0
  local plan = ok and ghost_plan(result) or { placed = {}, tiles = {}, order = {}, items = {} }
  local materials, missing = ghost_materials(ctx, plan)
  local out = { check_only = true, ok = ok, mode = "ghosts", anchor = result.given_anchor or result.anchor,
    platform = platform_row(ctx), surface = ctx.space and ("platform:" .. ctx.space.platform) or nil,
    hub = ctx.space and ctx.space.hub_position or nil, placed = plan.placed,
    tiles = result.foundation and { would_place = #plan.tiles, already = result.foundation.already,
      failed = result.foundation.failed, omitted_failed = result.foundation.omitted_failed } or nil,
    already = noted(result, "ALREADY"), needs_planned_tiles = noted(result, "NEEDS_PLANNED_TILES"),
    failed = result.failed, materials = materials, missing = missing and #missing > 0 and missing or nil }
  for k, v in pairs(extra or {}) do out[k] = v end
  return out
end

local function report(c, result, extra, s)
  if s and s.ctx.ghosts then return ghost_report(s.ctx, result, extra) end
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
-- Who a search works for: a platform layout needs only a connected body
-- (aboard or in transit too; its window reads the force), anything on a
-- planet the character.
local function actor(platform)
  if platform ~= nil then return companion.require_present() end
  return companion.require_companion()
end

-- What a dry run searches for: the body (actor), or on another surface
-- named by `surface` a body-less viewpoint there, which the job keeps.
local function check_viewer(params)
  if params.surface == nil then return actor(params.platform), nil end
  if params.platform ~= nil then error("check_only takes platform or surface, not both", 0) end
  local target = surfaces.target(params.surface)
  if target.here then return actor(nil), nil end
  local at = params.anchor or params.near or (type(params.site) == "table" and params.site.near) or nil
  local view = surfaces.viewpoint(target, type(at) == "table" and at or nil)
  return view, view
end

local function check_job(label, make_request)
  return {
    start = function(params)
      require_check_only(params, label)
      local c, view = check_viewer(params)
      local request, extra = make_request(c, params)
      local s = new_search(c, request)
      s.given_anchor = request.given_anchor
      return { search = s, extra = extra, view = view }
    end,
    step = function(state, budget)
      local c = state.view or actor(state.search.ctx.space)
      local s = state.search
      local before = s.ctx.calls
      local result = advance(c, s, math.max(1, budget.left))
      budget.left = budget.left - (s.ctx.calls - before)
      if not result then return nil end
      result.given_anchor = s.given_anchor
      return report(c, result, state.extra, s)
    end,
  }
end

M.layout_check_job = check_job("build_layout", function(c, params)
  validate_layout(params, "build_layout")
  return layout_request(c, params)
end)
M.block_check_job = check_job("build_block", function(c, params)
  local request = block_request(c, params)
  return request, { block = params.block, tiers = request.tiers }
end)

-- ----------------------------------------------------------------- runner

local Runner = {}

-- Advances the site search by budget; once decided, starts the build (or
-- holds the ghosts to place from the next tick).
local function search(task, c, budget)
  local s = task._search
  local result = advance(c, s, budget)
  if not result then return end
  task._search = nil
  task._anchor, task._rotation = result.anchor, result.rotation
  if #result.failed > 0 then
    task._check_failed = result.failed
    return
  end
  if s.ctx.ghosts then
    result.given_anchor = s.given_anchor
    task._ghosts = begin_ghosts(s.ctx, result)
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
  local c = actor(task.platform)
  local request = task.block and block_request(c, task) or layout_request(c, task)
  task.tiers = request.tiers
  task._search = new_search(c, request)
  task._search.given_anchor = request.given_anchor
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
    search(task, actor(task.platform), budget)
    jobs.charge(s.ctx.calls - before)
    -- Ghosts are placed from the next tick: this one spent its share.
    if task._search or task._plan or task._ghosts then return nil end
  end
  if task._check_failed then
    local first = task._check_failed[1]
    return { status = "failed",
      detail = string.format("LAYOUT_CHECK_FAILED: %s — %s", label, first.code .. ": " .. tostring(first.reason)),
      outcome = { code = "LAYOUT_CHECK_FAILED", anchor = task._anchor, placed = {}, failed = task._check_failed,
        platform = task.platform } }
  end
  if task._ghosts then
    local before = task._ghosts.ctx.calls
    local result, handled = place_batch(actor(task.platform), task._ghosts, label)
    jobs.charge(handled * GHOST_WORK + task._ghosts.ctx.calls - before)
    if result then task._ghosts = nil end
    return result
  end
  local plan = task._plan
  local done = build_plan.tick(plan)
  if not done then return nil end
  local placed, failed = {}, {}
  for i, step in ipairs(plan.steps) do
    local r = plan._results[i]
    if (r and r.ok) or (step._placed_entity and step._placed_entity.valid) then
      placed[#placed + 1] = placed_row(step)
    end
    if not (r and r.ok) then
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
    return { anchor = step.anchor, site = step.site, entities = step.entities, connections = step.connections,
      mode = step.mode, platform = step.platform, tiles = step.tiles, tile_rects = step.tile_rects }
  end,
  validate = function(step, index) validate_layout(step, "queue_plan build_layout step " .. index) end,
  -- A platform layout is remote: no body, no reach, placed in the tick its
  -- checks finish.
  remote = function(step) return step.platform ~= nil end,
  -- Each placement and route tile is a step's worth of plan budget; ghosts
  -- are placed at once.
  budget_steps = function(step)
    if step.mode == "ghosts" or step.platform ~= nil then return 1 end
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
M.validate_layout, M.platform_space = validate_layout, platform_space
M.WORK_PER_TICK, M.MAX_WORK = WORK_PER_TICK, MAX_WORK

return M
