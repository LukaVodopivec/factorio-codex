-- Protocol-v11 local perception: compact by default; full adds the ASCII grid.
-- observe_local is a job (jobs.lua) spread over ticks by a work budget.
-- (dry-run placement check with blocker naming),
-- clear rectangle) and describe_prototype (geometry/energy facts about items,
-- entities and recipes). All instant methods — no tasks, no side effects.
local companion = require("scripts.companion")
local surfaces = require("scripts.surfaces")
local items = require("scripts.items")
local errors = require("scripts.errors")
local production_requirements = require("scripts.production_requirements")
local tasks = require("scripts.tasks")
local placement_geometry = require("scripts.placement_geometry")
local output_targets = require("scripts.output_target")
local jobs = require("scripts.jobs")

local M = {}

local SCAN_DEFAULT_RADIUS = 15
local SCAN_MIN_RADIUS = 5
local SCAN_MAX_RADIUS = 30
-- A full observation paints a grid: its work grows with the square of the
-- radius, so it stops at 20 (requested_radius says when it was asked more).
local SCAN_MAX_FULL_RADIUS = 20
local DESCRIBE_MAX_NAMES = 10

local UPPER_LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local LOWER_LETTERS = "abcdefghijklmnopqrstuvwxyz"

-- ---------------------------------------------------------------- helpers

local function require_position(pos, message)
  if type(pos) ~= "table" or tonumber(pos.x) == nil or tonumber(pos.y) == nil then
    error(message)
  end
  return { x = tonumber(pos.x), y = tonumber(pos.y) }
end


-- Normalize a Factorio Vector ({x=,y=} or {1,2}) to a plain {x, y} table.
local function vec_xy(v)
  if type(v) ~= "table" then return nil end
  local x = tonumber(v.x) or tonumber(v[1])
  local y = tonumber(v.y) or tonumber(v[2])
  if x == nil or y == nil then return nil end
  return { x = x, y = y }
end

-- Sorted list of the keys of a {name = true} dictionary (nil when empty).
local function sorted_keys(dict)
  if type(dict) ~= "table" then return nil end
  local keys = {}
  for k in pairs(dict) do keys[#keys + 1] = k end
  if #keys == 0 then return nil end
  table.sort(keys)
  return keys
end

-- World-space union of the selection and collision/bounding boxes. Keeping
-- the precise floats in details while using floor/ceil only for grid painting
-- makes edge-overlap behavior observable without shrinking large entities.
local function entity_bounds(e)
  local left, top, right, bottom
  local function include(box)
    if box and box.left_top and box.right_bottom then
      left = left and math.min(left, box.left_top.x) or box.left_top.x
      top = top and math.min(top, box.left_top.y) or box.left_top.y
      right = right and math.max(right, box.right_bottom.x) or box.right_bottom.x
      bottom = bottom and math.max(bottom, box.right_bottom.y) or box.right_bottom.y
    end
  end
  include(e.selection_box)
  include(e.bounding_box)
  if not left then
    left, top, right, bottom = e.position.x, e.position.y, e.position.x + 1, e.position.y + 1
  end
  return { left_top = { x = left, y = top }, right_bottom = { x = right, y = bottom } }
end

local function plain_box(box)
  if not box or not box.left_top or not box.right_bottom then return nil end
  return { left_top = { x = box.left_top.x, y = box.left_top.y },
    right_bottom = { x = box.right_bottom.x, y = box.right_bottom.y } }
end

local function entity_status(e)
  local ok, status = pcall(function() return e.status end)
  if ok and status ~= nil then
    for name, value in pairs((defines and defines.entity_status) or {}) do if value == status then return name end end
    return tostring(status)
  end
  return nil
end

local function entity_recipe(e)
  local ok, recipe = pcall(function() return e.get_recipe and e.get_recipe() end)
  if ok and recipe then return recipe.name end
  return nil
end

-- Area queries are collision-based, while the observation contract reports
-- the union of collision and selection footprints. Expand only the bounded
-- local query by the largest installed prototype extent, then precisely
-- intersect each returned entity with the requested grid below.
local footprint_query_margin
local function max_footprint_extent()
  if footprint_query_margin ~= nil then return footprint_query_margin end
  local margin = 0
  for _, proto in pairs((prototypes and prototypes.entity) or {}) do
    local function include(box)
      if box then
        local lt, rb = vec_xy(box.left_top), vec_xy(box.right_bottom)
        if lt and rb then
          margin = math.max(margin, math.abs(lt.x), math.abs(lt.y), math.abs(rb.x), math.abs(rb.y))
        end
      end
    end
    include(proto.collision_box)
    include(proto.selection_box)
  end
  footprint_query_margin = margin
  return margin
end

-- ----------------------------------------------------------- observe_local

-- Higher paints over lower when several things share a tile.
local PRIORITY = {
  land = 0, water = 1, cliff = 2, rock = 3, tree = 4,
  resource = 5, ground_item = 6, building = 7, player = 8, companion = 9,
}

-- observe_local is a job (jobs.lua): what it reads grows with the radius and
-- with what stands there (an ore field is thousands of entities), so it runs
-- in stages, a budget of work items per tick, its state S plain data:
--   terrain  (full) land and water, a row of tiles at a time
--   query    the area in bands of BAND_ROWS rows; each entity is taken once,
--            from the band its centre lies in, if its footprint touches the grid
--   names    the distinct names, for glyphs assigned lexically
--   paint    footprints (full), details, ground items, resource positions;
--            details and ground items are kept to their caps as they come
--   cluster  resource patches, a resource at a time
--   finish   the capped rows in order and the character's state
-- A compact observation skips the terrain and the painting (it has no grid).
-- The grid and every distance use the body's position when the job started.
local BAND_ROWS = 8
local QUERY_COST, VISIBLE_COST, NAME_COST, PAINT_COST, DETAIL_COST = 2, 6, 6, 8, 8
-- Per resource clustered (25 bucket lookups and its neighbours), and per
-- resource bucketed.
local CLUSTER_COST, BUCKET_COST = 3, 0.5

-- Assigns the next free letter of `alphabet` to a distinct name.
local function letter_for(S, name, assigned, alphabet)
  local legend = S.legend
  local ch = assigned[name]
  if ch then return ch end
  for i = 1, #alphabet do
    local cand = string.sub(alphabet, i, i)
    if legend[cand] == nil then
      assigned[name] = cand
      legend[cand] = name
      return cand
    end
  end
  -- More than the alphabet can hold — extremely unlikely at radius <= 30.
  assigned[name] = "?"
  legend["?"] = "several different things (ran out of letters)"
  return "?"
end

-- What an observation reads with: the body's anchor (its physical surface
-- and position, the hub aboard, the pod in transit), its force, and the
-- character when it has one. A body that changed surface mid-observation
-- ends it.
local function observe_context(S)
  local body = companion.require_present()
  if S and S.surface_index and body.surface and body.surface.index ~= S.surface_index then
    error("SURFACE_CHANGED: the body changed surface during the observation; observe again", 0)
  end
  if not (body.surface and body.position) then
    error("BODY_UNAVAILABLE: the body has no surface to observe (state " .. tostring(body.state) .. ")", 0)
  end
  return { surface = body.surface, force = body.force, position = body.position, character = body.character,
    body = body }
end

-- What "~" means on a surface: water on a planet whose map has no other
-- liquid (from prototype data), else any liquid.
local function liquid_legend(surface)
  local ok, planet = pcall(function() return surface.planet.name end)
  local other = not (ok and planet)
  for _, fluid in ipairs({ "lava", "heavy-oil", "ammoniacal-solution" }) do
    if not other then
      local read_ok, has = pcall(production_requirements.has_liquid, planet, fluid)
      other = not read_ok or has == true
    end
  end
  if not other then return "water" end
  return "liquid (water, lava or an ocean; only oil ocean and shallow water are walkable)"
end

local function observe_start(params)
  local c = observe_context()
  local radius = math.floor(tonumber(params.radius) or SCAN_DEFAULT_RADIUS)
  radius = math.max(SCAN_MIN_RADIUS, math.min(radius, SCAN_MAX_RADIUS))
  local compact = params.detail ~= "full"
  local requested_radius
  if not compact and radius > SCAN_MAX_FULL_RADIUS then requested_radius, radius = radius, SCAN_MAX_FULL_RADIUS end
  local center = { x = c.position.x, y = c.position.y }
  local ox, oy = math.floor(center.x) - radius, math.floor(center.y) - radius
  local size = radius * 2 + 1
  local margin = max_footprint_extent()
  local S = { radius = radius, requested_radius = requested_radius, compact = compact, center = center,
    surface_index = c.surface.index, surface = c.body.surface_ref,
    ox = ox, oy = oy, size = size, margin = margin,
    entity_limit = compact and 12 or 256, ground_limit = compact and 12 or 256, patch_limit = compact and 8 or 256,
    stage = compact and "query" or "terrain", row = 1, band = 0, visible = {},
    -- Fixed symbols are pre-registered so dynamically assigned letters can
    -- never collide with them (T/R/P and lowercase c are reserved).
    legend = {
      ["."] = "buildable land",
      ["~"] = liquid_legend(c.surface),
      ["c"] = "cliff",
      ["T"] = "tree",
      ["R"] = "rock",
      ["@"] = "you",
      ["P"] = "player",
      ["*"] = "item stack on ground",
    },
    resource_letters = {}, building_letters = {}, resource_names = {}, building_names = {},
    seen_resource = {}, seen_building = {},
    details = {}, resources_by_name = {}, ground_items = {}, patches = {},
    detail_total = 0, ground_total = 0, patch_total = 0 }
  if not compact then S.chars, S.prio, S.paint_key = {}, {}, {} end
  return S
end

-- Terrain pass: land / liquid, one row of tiles at a time.
local function observe_terrain(S, budget, c)
  local surface = c.surface
  while S.row <= S.size do
    if budget.left <= 0 then return false end
    local row = S.row
    local crow, prow, krow = {}, {}, {}
    S.chars[row], S.prio[row], S.paint_key[row] = crow, prow, krow
    for col = 1, S.size do
      if placement_geometry.is_liquid(surface, S.ox + col - 1, S.oy + row - 1) then
        crow[col], prow[col], krow[col] = "~", PRIORITY.water, "water"
      else
        crow[col], prow[col], krow[col] = ".", PRIORITY.land, "land"
      end
    end
    budget.left = budget.left - 2 * S.size
    S.row = row + 1
  end
  return true
end

-- Entity pass: the query area (grid plus the largest footprint extent) in
-- bands. Area queries are collision-based, while the observation reports the
-- union of collision and selection footprints, so the area is widened and
-- each returned entity is precisely intersected with the grid. Factorio does
-- not promise entity iteration order: everything is sorted later.
local function observe_query(S, budget, c)
  local ox, oy, size, margin = S.ox, S.oy, S.size, S.margin
  local top, bottom = oy - margin, oy + size + margin
  while true do
    if budget.left <= 0 then return false end
    local found = S.found
    if found and S.fi <= #found then
      local e = found[S.fi]
      S.fi = S.fi + 1
      budget.left = budget.left - VISIBLE_COST
      if e.valid then
        -- Taken from the band holding its centre (the first and last bands
        -- also take centres beyond the area), so once.
        local y = e.position.y
        if (S.band == 1 or y >= S.band_top) and (S.band_top + BAND_ROWS >= bottom or y < S.band_top + BAND_ROWS) then
          local bounds = entity_bounds(e)
          if bounds.right_bottom.x > ox and bounds.left_top.x < ox + size
            and bounds.right_bottom.y > oy and bounds.left_top.y < oy + size then
            S.visible[#S.visible + 1] = { entity = e, bounds = bounds }
          end
        end
      end
    else
      S.found = nil
      local band_top = top + S.band * BAND_ROWS
      if band_top >= bottom then return true end
      S.band, S.band_top = S.band + 1, band_top
      S.found, S.fi = c.surface.find_entities_filtered({
        area = { { ox - margin, band_top }, { ox + size + margin, math.min(bottom, band_top + BAND_ROWS) } },
      }), 1
      budget.left = budget.left - QUERY_COST - math.ceil(#S.found / 8)
    end
  end
end

-- Pre-assign dynamic glyphs from lexical entity names so shuffled engine
-- iteration cannot change the grid or legend.
local function observe_names(S, budget, c)
  local visible = S.visible
  while (S.ni or 1) <= #visible do
    if budget.left <= 0 then return false end
    local e = visible[S.ni or 1].entity
    S.ni = (S.ni or 1) + 1
    budget.left = budget.left - NAME_COST
    if e.valid and e.type == "resource" and not S.seen_resource[e.name] then
      S.seen_resource[e.name] = true; S.resource_names[#S.resource_names + 1] = e.name
    elseif e.valid and e.type == "item-entity" then
    elseif e.valid and e.force == c.force and e ~= c.character and e.type ~= "character" and not S.seen_building[e.name] then
      S.seen_building[e.name] = true; S.building_names[#S.building_names + 1] = e.name
    end
  end
  table.sort(S.resource_names); table.sort(S.building_names)
  for _, name in ipairs(S.resource_names) do letter_for(S, name, S.resource_letters, UPPER_LETTERS) end
  for _, name in ipairs(S.building_names) do letter_for(S, name, S.building_letters, LOWER_LETTERS) end
  return true
end

-- Row orders: details and ground items nearest first (which the caps keep),
-- then by position (how they are listed).
local function detail_by_position(a, b)
  if a.position.y ~= b.position.y then return a.position.y < b.position.y end
  if a.position.x ~= b.position.x then return a.position.x < b.position.x end
  if a.name ~= b.name then return a.name < b.name end
  if a.type ~= b.type then return a.type < b.type end
  return a._unit < b._unit
end
local function detail_nearer(a, b)
  if a._distance ~= b._distance then return a._distance < b._distance end
  return detail_by_position(a, b)
end
local function ground_by_position(a, b)
  if a.position.y ~= b.position.y then return a.position.y < b.position.y end
  if a.position.x ~= b.position.x then return a.position.x < b.position.x end
  if a.item ~= b.item then return a.item < b.item end
  return a.count < b.count
end
local function ground_nearer(a, b)
  if a.distance ~= b.distance then return a.distance < b.distance end
  return ground_by_position(a, b)
end

-- One visible entity: its glyph and footprint (full), and its detail,
-- ground stack or resource position as plain data.
local function observe_paint_one(S, entry, c, budget)
  local e, bounds = entry.entity, entry.bounds
  if not e.valid then return end
  local center = S.center
  local ch, p
  if e == c.character then
    ch, p = "@", PRIORITY.companion
  elseif e.type == "character" then
    ch, p = "P", PRIORITY.player
  elseif e.type == "item-entity" then
    local stack = e.stack
    if stack and stack.valid_for_read then
      ch, p = "*", PRIORITY.ground_item
      local ddx, ddy = e.position.x - center.x, e.position.y - center.y
      S.ground_total = S.ground_total + 1
      jobs.keep_first(S.ground_items, S.ground_limit, {
        item = stack.name, count = stack.count,
        position = { x = e.position.x, y = e.position.y },
        distance = math.sqrt(ddx * ddx + ddy * ddy),
      }, ground_nearer)
    end
  elseif e.force == c.force then
    ch, p = letter_for(S, e.name, S.building_letters, LOWER_LETTERS), PRIORITY.building
  elseif e.type == "resource" then
    ch, p = letter_for(S, e.name, S.resource_letters, UPPER_LETTERS), PRIORITY.resource
  elseif e.type == "tree" then
    ch, p = "T", PRIORITY.tree
  elseif e.type == "simple-entity" then
    ch, p = "R", PRIORITY.rock
  elseif e.type == "cliff" then
    ch, p = "c", PRIORITY.cliff
  end
  if not ch then return end
  if not S.compact then
    local ox, oy, size = S.ox, S.oy, S.size
    local chars, prio, paint_key = S.chars, S.prio, S.paint_key
    local x1, y1 = math.floor(bounds.left_top.x), math.floor(bounds.left_top.y)
    local x2, y2 = math.ceil(bounds.right_bottom.x), math.ceil(bounds.right_bottom.y)
    local key = string.format("%s\0%s\0%.17g\0%.17g\0%d", e.name, e.type,
      e.position.y, e.position.x, tonumber(e.unit_number) or -1)
    for py = y1, y2 - 1 do for px = x1, x2 - 1 do
      local rr, cc = py - oy + 1, px - ox + 1
      if rr >= 1 and rr <= size and cc >= 1 and cc <= size
        and (p > prio[rr][cc] or (p == prio[rr][cc] and key < paint_key[rr][cc])) then
        chars[rr][cc], prio[rr][cc], paint_key[rr][cc] = ch, p, key
      end
    end end
    budget.left = budget.left - math.ceil((x2 - x1) * (y2 - y1) / 16)
  end
  if e.type == "resource" then
    -- Each engine position and amount is read once; the clustering in
    -- finish runs on plain tables.
    local pos = e.position
    local list = S.resources_by_name[e.name] or {}
    S.resources_by_name[e.name] = list
    list[#list + 1] = { x = pos.x, y = pos.y, amount = e.amount or 0, unit = tonumber(e.unit_number) or -1 }
  elseif e.type ~= "item-entity" then
    budget.left = budget.left - DETAIL_COST
    local ddx, ddy = e.position.x - center.x, e.position.y - center.y
    S.detail_total = S.detail_total + 1
    jobs.keep_first(S.details, S.entity_limit, { symbol = ch, name = e.name, type = e.type, position = { x = e.position.x, y = e.position.y }, direction = e.direction, status = entity_status(e), recipe = entity_recipe(e), bounds = bounds, selection_box = plain_box(e.selection_box), collision_box = plain_box(e.bounding_box), footprint = { width = bounds.right_bottom.x - bounds.left_top.x, height = bounds.right_bottom.y - bounds.left_top.y }, _distance = ddx * ddx + ddy * ddy, _unit = tonumber(e.unit_number) or -1 }, detail_nearer)
  end
end

local function observe_paint(S, budget, c)
  local visible = S.visible
  while (S.pi or 1) <= #visible do
    if budget.left <= 0 then return false end
    local entry = visible[S.pi or 1]
    S.pi = (S.pi or 1) + 1
    budget.left = budget.left - PAINT_COST
    observe_paint_one(S, entry, c, budget)
  end
  S.visible = nil
  return true
end

-- Resource patches: connected tiles of one name (within 1.1 on both axes),
-- nearest first; the first patch_limit are kept as they are completed. The
-- exact member list is only the final tie-break; it is built on demand.
local function resource_order(a, b)
  if a.y ~= b.y then return a.y < b.y end
  if a.x ~= b.x then return a.x < b.x end
  if a.amount ~= b.amount then return a.amount < b.amount end
  return a.unit < b.unit
end
local function patch_members_key(patch)
  if type(patch._members) == "table" then
    local parts = {}
    for i, e in ipairs(patch._members) do parts[i] = string.format("%.17g,%.17g,%.17g,%d", e.x, e.y, e.amount, e.unit) end
    patch._members = table.concat(parts, ";")
  end
  return patch._members
end
local function patch_order(a, b)
  if a.distance ~= b.distance then return a.distance < b.distance end
  if a.name ~= b.name then return a.name < b.name end
  if a.center.y ~= b.center.y then return a.center.y < b.center.y end
  if a.center.x ~= b.center.x then return a.center.x < b.center.x end
  if a.entity_count ~= b.entity_count then return a.entity_count < b.entity_count end
  if a.total_amount ~= b.total_amount then return a.total_amount < b.total_amount end
  return patch_members_key(a) < patch_members_key(b)
end

-- One resource of the patch being grown: its totals, the nearest target,
-- and its unvisited neighbours queued in index order.
local function cluster_visit(K, P, center)
  local resources, buckets, visited = K.list, K.buckets, K.visited
  local index = P.queue[P.head]
  P.head = P.head + 1
  local e = resources[index]
  P.count, P.amount, P.sx, P.sy = P.count + 1, P.amount + e.amount, P.sx + e.x, P.sy + e.y
  local ndx, ndy = e.x - center.x, e.y - center.y
  local distance_sq = ndx * ndx + ndy * ndy
  local nearest = P.nearest
  if not nearest or distance_sq < P.nearest_distance_sq
    or (distance_sq == P.nearest_distance_sq and (e.y < nearest.y
      or (e.y == nearest.y and (e.x < nearest.x
        or (e.x == nearest.x and (e.amount < nearest.amount
          or (e.amount == nearest.amount and e.unit < nearest.unit))))))) then
    P.nearest, P.nearest_distance_sq = e, distance_sq
  end
  P.members[#P.members + 1] = e
  -- Neighbours lie within 1.1 tiles on both axes, so they share a bucket
  -- within two of each other; the exact distance test still decides.
  local found, bx, by = {}, math.floor(e.x), math.floor(e.y)
  for gx = bx - 2, bx + 2 do
    local column = buckets[gx]
    if column then for gy = by - 2, by + 2 do
      local bucket = column[gy]
      if bucket then for _, other in ipairs(bucket) do
        local o = resources[other]
        if not visited[other] and math.abs(e.x - o.x) <= 1.1 and math.abs(e.y - o.y) <= 1.1 then found[#found + 1] = other end
      end end
    end end
  end
  table.sort(found)
  for _, other in ipairs(found) do visited[other] = true; P.queue[#P.queue + 1] = other end
end

local function observe_cluster(S, budget)
  local K = S.cluster
  if not K then
    local names = {}
    for name in pairs(S.resources_by_name) do names[#names + 1] = name end
    table.sort(names)
    K = { names = names, n = 1, phase = "sort" }
    S.cluster = K
  end
  while K.n <= #K.names do
    local name = K.names[K.n]
    if K.phase == "sort" then
      local sorted = jobs.sort_step(K, "_sort", S.resources_by_name[name], resource_order, budget)
      if not sorted then return false end
      K.list, K.buckets, K.visited, K.bucketed, K.start, K.phase = sorted, {}, {}, 0, 1, "bucket"
    end
    if K.phase == "bucket" then
      while K.bucketed < #K.list do
        if budget.left <= 0 then return false end
        budget.left = budget.left - BUCKET_COST
        local index = K.bucketed + 1
        local r = K.list[index]
        local bx, by = math.floor(r.x), math.floor(r.y)
        local column = K.buckets[bx]
        if not column then column = {}; K.buckets[bx] = column end
        local bucket = column[by]
        if not bucket then bucket = {}; column[by] = bucket end
        bucket[#bucket + 1] = index
        K.bucketed = index
      end
      K.phase = "grow"
    end
    while true do
      if budget.left <= 0 then return false end
      local P = K.patch
      if P and P.head <= #P.queue then
        budget.left = budget.left - CLUSTER_COST
        cluster_visit(K, P, S.center)
      elseif P then
        local center = { x = P.sx / P.count, y = P.sy / P.count }
        local dx, dy = center.x - S.center.x, center.y - S.center.y
        S.patch_total = S.patch_total + 1
        jobs.keep_first(S.patches, S.patch_limit, { name = name, entity_count = P.count, total_amount = P.amount,
          center = center, distance = math.sqrt(dx * dx + dy * dy),
          nearest_target = { x = P.nearest.x, y = P.nearest.y, amount = P.nearest.amount,
            distance = math.sqrt(P.nearest_distance_sq) }, _members = P.members }, patch_order)
        K.patch = nil
      else
        while K.start <= #K.list and K.visited[K.start] do K.start = K.start + 1 end
        if K.start > #K.list then break end
        K.visited[K.start] = true
        K.patch = { queue = { K.start }, head = 1, count = 0, amount = 0, sx = 0, sy = 0, members = {} }
      end
    end
    K.n, K.phase, K.list, K.buckets, K.visited = K.n + 1, "sort", nil, nil, nil
  end
  S.cluster = nil
  return true
end

-- The character's state, which every observation carries.
function M.character_state(c)
  -- By item key: a non-normal quality is "name@quality".
  local function inventory_contents(source)
    local contents = {}
    if not source then return contents end
    for _, item in ipairs(source.get_contents()) do
      local key = items.key(item.name, item.quality)
      contents[key] = (contents[key] or 0) + item.count
    end
    return contents
  end
  local inventory = inventory_contents(c.get_main_inventory())
  local ammo_inventory = inventory_contents(c.get_inventory(defines.inventory.character_ammo))
  local crafting = { queue_size = c.crafting_queue_size or 0, progress = c.crafting_queue_progress or 0, queue = {} }
  for _, entry in ipairs(c.crafting_queue or {}) do
    local recipe = entry.recipe
    pcall(function() recipe = entry.recipe.name end)
    crafting.queue[#crafting.queue + 1] = { recipe = recipe, count = entry.count }
  end
  local path_start = placement_geometry.path_start(c)
  -- A belt under the body carries it while idle; the recorder samples this too.
  local conveyor = placement_geometry.conveyor_under(c)
  -- The player's input holds the body and parks the FIFO; a failed read never holds.
  local human_ok, human_control, human_idle_ticks = pcall(companion.human_control)
  human_control = human_ok and human_control == true
  if not human_ok then human_idle_ticks = nil end
  return { position = { x = c.position.x, y = c.position.y }, health = c.health,
    inventory = inventory, inventory_scope = "main", ammo_inventory = ammo_inventory,
    active_task = tasks.active_summary(), queue_depth = tasks.queue_length(),
    human_control = human_control, human_idle_ticks = human_idle_ticks,
    crafting = crafting, reach_distance = c.reach_distance, build_distance = c.build_distance,
    collision_box = plain_box(placement_geometry.character_box(c)),
    path_start = path_start,
    standing_on = conveyor and { name = conveyor.name, type = conveyor.type, direction = conveyor.direction,
      position = { x = conveyor.position.x, y = conveyor.position.y } } or nil }
end

-- The body's state for an observation: the character's, with where the body
-- is (state, surface); without a character (in a cargo pod) where it is and
-- its work only.
local function body_state(c)
  local body = c.body
  local ok, state = false, nil
  if c.character and c.character.valid then ok, state = pcall(M.character_state, c.character) end
  if not ok then
    local held_ok, held = pcall(companion.human_control)
    state = { position = body.position and { x = body.position.x, y = body.position.y } or nil,
      active_task = tasks.active_summary(), queue_depth = tasks.queue_length(),
      human_control = held_ok and held == true }
  end
  state.state, state.surface = body.state, body.surface_ref
  return state
end

local function observe_finish(S, c)
  -- Every list was kept to its cap as it was collected.
  local details, ground_items, patches = S.details, S.ground_items, S.patches
  table.sort(details, detail_by_position)
  for _, detail in ipairs(details) do
    detail._distance, detail._unit = nil, nil
    if S.compact then
      detail.bounds, detail.selection_box, detail.collision_box, detail.footprint = nil, nil, nil, nil
    end
  end
  table.sort(ground_items, ground_by_position)
  table.sort(patches, patch_order)
  for _, patch in ipairs(patches) do patch._members = nil end
  local result = {
    tick = game.tick, radius = S.radius, requested_radius = S.requested_radius, detail = S.compact and "compact" or "full",
    surface = S.surface, character = body_state(c),
    entities = details, resource_patches = patches, ground_items = ground_items,
    omitted_entities = S.detail_total - #details, omitted_ground_items = S.ground_total - #ground_items,
    omitted_resource_patches = S.patch_total - #patches,
  }
  if not S.compact then
    local grid = {}
    for row = 1, S.size do grid[row] = table.concat(S.chars[row]) end
    result.grid = { origin = { x = S.ox, y = S.oy }, width = S.size, height = S.size, rows = grid, legend = S.legend,
      coordinate_rule = "rows north-to-south; columns west-to-east; x=origin.x+column, y=origin.y+row" }
  end
  return result
end

-- What an observation stopped by its work ceiling (observe_compact) says:
-- the character's state only.
local function observe_truncated(S)
  local c = observe_context(S)
  return { tick = game.tick, radius = S.radius, detail = "compact", surface = S.surface, character = body_state(c),
    entities = {}, resource_patches = {}, ground_items = {},
    truncated = "the area holds more than one tick may read: call observe_local for its entities and patches" }
end

local OBSERVE_NEXT = { terrain = "query", query = "names", names = "paint", paint = "cluster", cluster = "finish" }

local function observe_step(S, budget)
  local c = observe_context(S)
  while budget.left > 0 do
    local stage, done = S.stage, nil
    if stage == "terrain" then done = observe_terrain(S, budget, c)
    elseif stage == "query" then done = observe_query(S, budget, c)
    elseif stage == "names" then done = observe_names(S, budget, c)
    elseif stage == "paint" then done = observe_paint(S, budget, c)
    elseif stage == "cluster" then done = observe_cluster(S, budget)
    else return observe_finish(S, c) end
    if done then S.stage = OBSERVE_NEXT[stage] end
  end
  return nil
end

-- observe_local {radius? (5-30, default 15; full at most 20), detail?
-- (compact | full)}: the job definition (jobs.lua registers it).
M.observe_job = { start = observe_start, step = observe_step, truncated = observe_truncated }

-- A compact observation at radius at most the default, within this call:
-- what a plan's final observation and the run recorder take. It stops at
-- COMPACT_MAX_WORK (an ore field or a dense factory can hold more) and then
-- carries the character's state and says it was truncated.
local COMPACT_MAX_WORK = 2 * jobs.WORK_PER_TICK
M.COMPACT_MAX_WORK = COMPACT_MAX_WORK
function M.observe_compact(params)
  local radius = math.min(tonumber(params and params.radius) or SCAN_DEFAULT_RADIUS, SCAN_DEFAULT_RADIUS)
  return (jobs.run_now(M.observe_job, { radius = radius, detail = "compact" }, nil, COMPACT_MAX_WORK))
end

-- --------------------------------------------------------------- can_place

-- The first liquid under a footprint ({fluid, walkable}), or nil.
local function footprint_liquid(surface, area)
  local x1, y1 = area.left_top.x, area.left_top.y
  local x2, y2 = area.right_bottom.x, area.right_bottom.y
  for ty = math.floor(y1), math.max(math.ceil(y2) - 1, math.floor(y1)) do
    for tx = math.floor(x1), math.max(math.ceil(x2) - 1, math.floor(x1)) do
      local liquid = placement_geometry.liquid_at(surface, tx, ty)
      if liquid then return liquid end
    end
  end
  return nil
end

local function liquid_name(liquid)
  if liquid.fluid == "water" or liquid.fluid == nil then return "water" end
  if liquid.fluid == "lava" then return "lava" end
  return liquid.fluid .. " ocean"
end

local function can_place_one(c, surface, item, position, direction)
  if type(item) ~= "string" then
    error("can_place requires item = <item name>")
  end
  local pos = require_position(position, "can_place requires position = {x, y}")
  -- Anywhere the force has charted; building there still needs the body.
  if not surfaces.charted(c.force, surface, math.floor(pos.x / 32), math.floor(pos.y / 32)) then
    error("can_place positions must be in charted terrain")
  end
  direction = math.floor(tonumber(direction) or 0) % 16

  local item_proto = prototypes.item[item]
  if not item_proto then
    error("no item called '" .. item .. "' — check the spelling with describe_prototype")
  end
  local entity_proto = item_proto.place_result
  if not entity_proto then
    error(item .. " is not a placeable item — it doesn't turn into a building")
  end

  local identity = {
    item = item,
    entity = entity_proto.name,
    position = { x = pos.x, y = pos.y },
    direction = direction,
  }
  -- Everything the check reads, not only the centre, must be charted: an
  -- answer about a box or a pump's water reaching into uncharted land would
  -- reveal its terrain.
  if not surfaces.footprint_charted(c.force, surface, placement_geometry.placement_area(entity_proto, pos, direction)) then
    identity.can_place, identity.code = false, "UNCHARTED"
    identity.reason = "the footprint reaches uncharted terrain — chart it first"
    return identity
  end
  -- The planet's (or platform's) conditions come first: no spot there helps.
  local broken = placement_geometry.surface_condition(surface, entity_proto.surface_conditions)
  if broken then
    identity.can_place, identity.code, identity.condition = false, "SURFACE_CONDITION", broken
    identity.reason = placement_geometry.condition_text(entity_proto.name, broken)
    return identity
  end
  -- What an offshore pump pumps there.
  if entity_proto.type == "offshore-pump" then
    identity.fluid = placement_geometry.pumped_fluid(surface, entity_proto, pos, direction)
  end
  local ok, placement_reason = placement_geometry.can_place(c, entity_proto, pos, direction)
  if ok then
    identity.can_place = true
    identity.reason = "placeable"
    return identity
  end

  if placement_reason == "CODEX_BODY_OVERLAP" then
    identity.can_place = false
    identity.reason = "CODEX_BODY_OVERLAP — walk clear of the exact collision footprint"
    return identity
  end

  -- Best-effort explanation: name whatever occupies the would-be footprint.
  local area = placement_geometry.footprint(entity_proto, pos, direction)
  local blocker, companion_in_way, only_natural = nil, nil, true
  local near = placement_geometry.touching(area)
  for _, e in ipairs(surface.find_entities_filtered({ area = near, limit = 65 + placement_geometry.tile_count(near) })) do
    if e.valid then
      if e == c then
        companion_in_way = true
      elseif not placement_geometry.NON_BLOCKING_TYPES[e.type] then
        blocker = blocker or e
        if e.type ~= "tree" and e.type ~= "simple-entity" then only_natural = false end
      end
    end
  end

  local reason
  local liquid = footprint_liquid(surface, area)
  local mix = placement_geometry.fluid_mix(surface, entity_proto, pos, direction)
  if mix then
    reason = placement_geometry.fluid_mix_reason(mix)
  elseif blocker then
    reason = string.format("blocked by %s at (%.1f, %.1f)",
      blocker.name, blocker.position.x, blocker.position.y)
    if only_natural and not liquid then
      reason = reason .. " — only trees or rocks: placing mines them first"
      identity.clears_natural = true
    end
    if companion_in_way then
      reason = reason .. " — and I'm standing in the footprint too, I'll need to step aside"
    end
  elseif liquid then
    -- Landfill covers water; lava and the oceans take foundation or ice platform.
    reason = "the footprint touches " .. liquid_name(liquid) .. " — pick dry land or "
      .. (liquid_name(liquid) == "water" and "place landfill first" or "cover it with place_tiles first")
    if companion_in_way then
      reason = reason .. " (I'm also standing there)"
    end
  elseif companion_in_way then
    reason = "I'm standing there — I'll need to step aside before this can be placed"
  else
    reason = "blocked (terrain or overlap)"
  end
  identity.can_place = false
  identity.reason = reason
  return identity
end

local MAX_PLACEMENTS = 24

-- placements = [{item, position = {x,y}, direction?}, ...] checks up to
-- MAX_PLACEMENTS spots in one call, on the body's surface or the `surface`
-- named (reading is not reach: another surface has no body to step aside).
function M.can_place(params)
  if type(params) ~= "table" then error("placements must be a non-empty array") end
  local target = surfaces.target(params.surface)
  local first = type(params.placements) == "table" and params.placements[1]
  local c = surfaces.viewpoint(target, type(first) == "table" and type(first.position) == "table"
    and tonumber(first.position.x) and tonumber(first.position.y)
    and { x = tonumber(first.position.x), y = tonumber(first.position.y) } or nil)
  local surface = target.surface

  if type(params) ~= "table" or type(params.placements) ~= "table" or #params.placements == 0 then
    error("placements must be a non-empty array")
  end
  if #params.placements > MAX_PLACEMENTS then
    error("can_place takes at most " .. MAX_PLACEMENTS .. " placements per call — split the list")
  end
  for i, p in ipairs(params.placements) do
    if type(p) ~= "table" or type(p.item) ~= "string" then
      error("placements[" .. i .. "].item must be an item name")
    end
  end
  local out = {}
  for i, p in ipairs(params.placements) do
    local ok, res = pcall(can_place_one, c, surface, p.item, p.position, p.direction)
    if not ok then
      res = { can_place = false, reason = errors.plain(res) }
    end
    res.item = res.item or p.item
    res.direction = res.direction or math.floor(tonumber(p.direction) or 0) % 16
    res.position = {
      x = tonumber(type(p.position) == "table" and p.position.x or nil),
      y = tonumber(type(p.position) == "table" and p.position.y or nil),
    }
    out[i] = res
  end
  -- Relations inside the batch and to existing entities, so a multi-entity
  -- design can be checked before anything is built (indexes are 0-based).
  local planned = {}
  local platform = surfaces.is_platform(surface)
  for i, p in ipairs(params.placements) do
    local item = prototypes.item[p.item]
    local proto = item and item.place_result
    local position = out[i].position
    if proto and position.x and position.y then
      planned[i] = { proto = proto, position = position, direction = out[i].direction,
        area = placement_geometry.footprint(proto, position, out[i].direction) }
    end
  end
  local function lands_on(point, kind, self_index, producer_type)
    local match, count = nil, 0
    for j = 1, #params.placements do
      local other = planned[j]
      if j ~= self_index and other
        and surfaces.charted(c.force, surface, math.floor(other.position.x / 32), math.floor(other.position.y / 32), platform)
        and output_targets.can_target_type(other.proto.type, kind)
        and output_targets.recipient_contains(other.area, point, producer_type, kind) then
        match, count = { batch_index = j - 1, name = other.proto.name }, count + 1
      end
    end
    local ok, _, identity, state = pcall(output_targets.recipient_at, c, point, kind, producer_type)
    if not ok then return { state = "unknown" } end
    if state == "ambiguous" or count > 1 or (count == 1 and state == "bound") then
      return { state = "ambiguous" }
    end
    if state ~= "bound" and state ~= "none" then return { state = state } end
    if match then return match end
    if identity then return identity end
    return false
  end
  for i = 1, #params.placements do
    local entry = planned[i]
    if entry then
      local overlaps = {}
      for j = 1, #params.placements do
        local other = planned[j]
        if j ~= i and other and placement_geometry.overlaps(entry.area, other.area) then overlaps[#overlaps + 1] = j - 1 end
      end
      if #overlaps > 0 then out[i].overlaps_batch = overlaps end
      local output = output_targets.output_position(entry.proto, entry.position, entry.direction)
      if output then out[i].output_position, out[i].output_lands_on = output, lands_on(output, "output", i, entry.proto.type) end
      local pickup = output_targets.input_position(entry.proto, entry.position, entry.direction)
      if pickup then out[i].pickup_position, out[i].pickup_from = pickup, lands_on(pickup, "input", i, entry.proto.type) end
    end
  end
  return { results = out }
end

-- -------------------------------------------------------- describe_prototype

local function describe_entity(ent, item_name)
  local out = { kind = "entity", entity = ent.name }

  if not item_name then
    -- Which item places this entity (nice to know when the caller asked by
    -- entity name).
    local ok, items = pcall(function() return ent.items_to_place_this end)
    if ok and type(items) == "table" and type(items[1]) == "table" and items[1].name then
      item_name = items[1].name
    end
  end
  if item_name then out.placed_by_item = item_name end

  local ok, v

  ok, v = pcall(function() return ent.tile_width end)
  if ok and type(v) == "number" then out.tile_width = v end
  ok, v = pcall(function() return ent.tile_height end)
  if ok and type(v) == "number" then out.tile_height = v end

  -- Mining drills: where the ore comes out, at direction 0 (rotate with the
  -- entity — 4:(x,y)->(-y,x), 8:(-x,-y), 12:(y,-x)).
  ok, v = pcall(function() return ent.vector_to_place_result end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.drop_offset = offset end
  end

  local burner, electric
  ok, v = pcall(function() return ent.burner_prototype end)
  if ok then burner = v end
  ok, v = pcall(function() return ent.electric_energy_source_prototype end)
  if ok then electric = v end
  out.energy = (burner and "burner") or (electric and "electric") or "none"
  if burner then
    ok, v = pcall(function() return burner.fuel_categories end)
    if ok then out.fuel_categories = sorted_keys(v) end
    ok, v = pcall(function() return burner.effectivity end)
    if ok and type(v) == "number" then out.burner_effectivity = v end
    ok, v = pcall(function() return burner.fuel_inventory_size end)
    if ok and type(v) == "number" then out.fuel_inventory_size = v end
  end

  ok, v = pcall(function() return ent.mining_speed end)
  if ok and type(v) == "number" then out.mining_speed = v end
  ok, v = pcall(function() return ent.get_crafting_speed() end)
  if ok and type(v) == "number" then out.crafting_speed = v end
  ok, v = pcall(function() return ent.get_max_energy_usage() end)
  if ok and type(v) == "number" then out.max_energy_usage = v end
  ok, v = pcall(function() return ent.get_max_energy_production() end)
  if ok and type(v) == "number" then out.max_energy_production = v end

  ok, v = pcall(function() return ent.mineable_properties end)
  if ok and type(v) == "table" then
    if type(v.mining_time) == "number" then out.mining_time = v.mining_time end
    local products = {}
    for _, product in ipairs(v.products or {}) do
      if product.name then
        local amount = tonumber(product.amount)
        if amount == nil and product.amount_min == product.amount_max then amount = tonumber(product.amount_min) end
        if amount ~= nil and (product.probability == nil or product.probability == 1) then
          products[product.name] = (products[product.name] or 0) + amount
        end
      end
    end
    if next(products) ~= nil then out.mining_products = products end
  end

  local fuel_item = prototypes.item[item_name or ent.name]
  if fuel_item then
    ok, v = pcall(function() return fuel_item.fuel_value end)
    if ok and type(v) == "number" and v > 0 then out.fuel_value = v end
    ok, v = pcall(function() return fuel_item.fuel_category end)
    if ok and type(v) == "string" then out.fuel_category = v end
  end

  ok, v = pcall(function() return ent.crafting_categories end)
  if ok then out.crafting_categories = sorted_keys(v) end

  -- Gun range lives on the ITEM prototype; turrets carry theirs on the entity.
  if item_name then
    local it = prototypes.item[item_name]
    if it then
      ok, v = pcall(function() return it.attack_parameters end)
      if ok and type(v) == "table" and type(v.range) == "number" then out.range = v.range end
    end
  end
  if out.range == nil then
    ok, v = pcall(function() return ent.attack_parameters end)
    if ok and type(v) == "table" and type(v.range) == "number" then out.range = v.range end
  end

  ok, v = pcall(function() return ent.inserter_pickup_position end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.inserter_pickup_offset = offset end
  end
  ok, v = pcall(function() return ent.inserter_drop_position end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.inserter_drop_offset = offset end
  end

  ok, v = pcall(function() return ent.belt_speed end)
  if ok and type(v) == "number" then out.belt_speed = v end

  return out
end

local function describe_recipe(rec, force)
  local ingredients, products = {}, {}
  for _, ing in ipairs(rec.ingredients or {}) do
    if ing.name then
      ingredients[ing.name] = (ingredients[ing.name] or 0) + (ing.amount or 1)
    end
  end
  for _, p in ipairs(rec.products or {}) do
    if p.name then
      local amount = tonumber(p.amount)
      if amount == nil and p.amount_min == p.amount_max then amount = tonumber(p.amount_min) end
      if amount ~= nil and (p.probability == nil or p.probability == 1) then
        products[p.name] = (products[p.name] or 0) + amount
      end
    end
  end
  local force_recipe = force.recipes[rec.name]
  return {
    kind = "recipe",
    ingredients = ingredients,
    products = products,
    energy = rec.energy,
    category = rec.category,
    enabled = (force_recipe and force_recipe.enabled) or false,
  }
end

local function describe_item(item)
  local out = { kind = "item", item = item.name, stack_size = item.stack_size }
  local ok, value = pcall(function() return item.fuel_value end)
  if ok and type(value) == "number" and value > 0 then out.fuel_value = value end
  ok, value = pcall(function() return item.fuel_category end)
  if ok and type(value) == "string" then out.fuel_category = value end
  ok, value = pcall(function() return item.place_result end)
  if ok and value then out.place_result = value.name end
  return out
end

function M.describe_prototype(params)
  local names = params.names
  local kind = params.kind or "auto"
  if type(names) ~= "table" or #names == 0 then
    error('describe_prototype requires names = ["burner-mining-drill", ...]')
  end
  if #names > DESCRIBE_MAX_NAMES then
    error(string.format(
      "describe_prototype takes at most %d names per call — split the list and call again",
      DESCRIBE_MAX_NAMES))
  end
  if kind ~= "auto" and kind ~= "entity" and kind ~= "recipe" and kind ~= "item" then
    error("describe_prototype kind must be auto, entity, recipe, or item")
  end

  local force = companion.require_present().force

  local out = {}
  for _, name in ipairs(names) do
    if type(name) == "string" then
      local item = prototypes.item[name]
      local placed = item and item.place_result
      local key = kind ~= "auto" and (kind .. ":" .. name) or name
      if kind == "recipe" and prototypes.recipe[name] then
        out[key] = describe_recipe(prototypes.recipe[name], force)
      elseif kind == "item" and item then
        out[key] = describe_item(item)
      elseif kind == "entity" and prototypes.entity[name] then
        out[key] = describe_entity(prototypes.entity[name], nil)
      elseif kind == "entity" and placed then
        out[key] = describe_entity(placed, name)
      elseif kind == "auto" and placed then
        out[key] = describe_entity(placed, name)
      elseif kind == "auto" and prototypes.entity[name] then
        out[key] = describe_entity(prototypes.entity[name], nil)
      elseif kind == "auto" and item then
        out[key] = describe_item(item)
      elseif kind == "auto" and prototypes.recipe[name] then
        out[key] = describe_recipe(prototypes.recipe[name], force)
      else
        out[key] = { kind = "unknown" }
      end
    end
  end
  return out
end

return M
