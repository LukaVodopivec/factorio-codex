-- Which surface a read describes (multi-surface rules 1 and 6). Reads work
-- in every body state but absent, on any surface the force has charted:
--   target(ref)       the surface a read's `surface` parameter names (a
--                     planet name, "platform:<index>" or {platform = name or
--                     index}, resolved by platforms.resolve_surface), else
--                     the body's anchor: its physical surface, the hub
--                     aboard, the pod in transit
--   viewpoint(t, at)  what a placement check stands on: the character when
--                     it stands on that surface, else a body-less viewpoint
--                     at `at` (an empty box overlaps nothing)
--   charted(...)      the force's chart, where a space platform's surface
--                     counts as charted (the platform window shows all of it)
--   footprint_charted whether every chunk an area touches is charted
-- Factory surfaces (every surface with own entities) come from the registry
-- (registry.surfaces); this module reads no entity.
local companion = require("scripts.companion")
local platforms = require("scripts.platforms")

local M = {}

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

-- Whether a surface is a space platform's, by surface index (a surface's
-- kind never changes; a deleted surface's index is forgotten).
local platform_index = {}
function M.is_platform(surface)
  local index = read(function() return surface.index end)
  if index == nil then return false end
  local known = platform_index[index]
  if known == nil then
    known = read(function() return surface.platform ~= nil end) == true
    platform_index[index] = known
  end
  return known
end

-- on_surface_deleted: the index may be reused by a new surface.
function M.on_surface_deleted(event)
  if event and event.surface_index then platform_index[event.surface_index] = nil end
end

-- Whether the force has charted chunk (cx, cy) of the surface; all of a
-- platform's surface counts as charted. A caller that checks many chunks of
-- one surface may pass whether it is a platform's (is_platform), once.
function M.charted(force, surface, cx, cy, platform)
  if platform == nil then platform = M.is_platform(surface) end
  if platform then return true end
  return read(function() return force.is_chunk_charted(surface, { x = cx, y = cy }) end) == true
end

-- Whether every chunk an area ({left_top, right_bottom}) touches is charted:
-- its four corners, which cover all of an area at most 32 tiles a side.
function M.footprint_charted(force, surface, area, platform)
  local corners = {
    { x = area.left_top.x, y = area.left_top.y },
    { x = area.right_bottom.x - 0.001, y = area.left_top.y },
    { x = area.left_top.x, y = area.right_bottom.y - 0.001 },
    { x = area.right_bottom.x - 0.001, y = area.right_bottom.y - 0.001 },
  }
  for _, corner in ipairs(corners) do
    if not M.charted(force, surface, math.floor(corner.x / 32), math.floor(corner.y / 32), platform) then return false end
  end
  return true
end

-- The canonical reference of a surface ("nauvis", "platform:3").
function M.ref(surface) return companion.surface_ref(surface) end

-- The surface with this index, or nil.
function M.by_index(index)
  local surface = index and read(function() return game.get_surface(index) end)
  if surface and read(function() return surface.valid end) ~= false then return surface end
  return nil
end

-- The surface with this index for a read that stored it: the body's own
-- surface when it is that one, else the lookup; nil once it is gone.
function M.stored(index, body)
  local surface = body and body.surface
  if surface and read(function() return surface.index end) == index then return surface end
  return M.by_index(index)
end

-- {surface, force, ref, here, body}: the surface a read describes. `here`
-- says whether it is the body's anchor surface. Errors: BODY_UNAVAILABLE
-- without a connected Codex player; SURFACE_UNKNOWN, SURFACE_NOT_CREATED,
-- UNKNOWN_PLATFORM, AMBIGUOUS_PLATFORM or NO_HUB for a ref that names no
-- surface (platforms.resolve_surface).
function M.target(ref)
  local body = companion.require_present()
  if not body.surface then
    error("BODY_UNAVAILABLE: the body has no surface to read (state " .. tostring(body.state) .. ")", 0)
  end
  if ref == nil or ref == body.surface_ref then
    return { surface = body.surface, force = body.force, ref = body.surface_ref, here = true, body = body }
  end
  local surface, canonical_or_code, why = platforms.resolve_surface(body.force, ref)
  if not surface then error(tostring(canonical_or_code) .. ": " .. tostring(why), 0) end
  local here = canonical_or_code == body.surface_ref
  return { surface = surface, force = body.force, ref = canonical_or_code, here = here, body = body }
end

-- What a placement check stands on (placement_geometry.can_place and
-- output_target.recipient_at read surface, force, position and the body's
-- box): the character standing on the target surface, else a viewpoint at
-- `at` whose box is empty (inside out), so no body overlaps anything there.
-- The viewpoint is plain data (a dry-run job may keep it in storage); it
-- carries nothing (no get_item_count).
local NO_BOX = { left_top = { x = 1e9, y = 1e9 }, right_bottom = { x = -1e9, y = -1e9 } }
function M.viewpoint(target, at)
  local c = companion.get()
  if target.here and c and c.valid then return c end
  local position = at or target.body.position or { x = 0, y = 0 }
  return { valid = true, surface = target.surface, force = target.force,
    position = { x = position.x, y = position.y }, bounding_box = NO_BOX }
end

return M
