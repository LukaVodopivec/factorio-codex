-- Offline tests for building on space platforms (stage B, remote: no body):
-- build_layout {platform} checks foundation tiles (already laid, touching
-- foundation or a planned tile) and entity ghosts (the engine's manual-ghost
-- check; over planned tiles they wait for them) before anything is placed,
-- as a check_only job in bounded work per tick, then creates native ghosts
-- (recipes and collector filters ride along) on the platform's
-- surface with every ghost read back; blueprint_place and deconstruct_area
-- with platform; configure_entity (collector filters, silo requests) and
-- set_recipe on a platform entity without walking. Strict 2.0.77 mocks for
-- tiles, ghosts and blueprint items.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end
local function raises(fn, pattern)
  local ok, err = pcall(fn)
  return not ok and tostring(err):match(pattern) ~= nil, err
end

local bp = dofile(here .. "/blueprint_mock.lua")
local mock = bp.mock

_G.storage = {}
_G.defines = { build_check_type = { manual = 1, ghost_revive = 2, manual_ghost = 3 },
  inventory = { chest = 1, hub_main = 2 }, build_mode = { normal = 0, forced = 1, superforced = 2 },
  direction = { north = 0, east = 4, south = 8, west = 12 } }
_G.game = { tick = 100, create_inventory = function(size) return bp.inventory(size) end }

local function box(w, h) return { left_top = { x = -w / 2 + 0.15, y = -h / 2 + 0.15 }, right_bottom = { x = w / 2 - 0.15, y = h / 2 - 0.15 } } end
local function proto(name, kind, w, h, extra)
  local p = { name = name, type = kind, tile_width = w, tile_height = h, collision_box = box(w, h),
    items_to_place_this = { { name = name, count = 1 } }, mineable_properties = { minable = true } }
  for k, v in pairs(extra or {}) do p[k] = v end
  return p
end
local entities = {
  crusher = proto("crusher", "assembling-machine", 2, 3, { crafting_categories = { crushing = true } }),
  ["asteroid-collector"] = proto("asteroid-collector", "asteroid-collector", 3, 3),
  inserter = proto("inserter", "inserter", 1, 1, { filter_count = 5 }),
  ["rocket-silo"] = proto("rocket-silo", "rocket-silo", 9, 9),
  ["space-platform-hub"] = proto("space-platform-hub", "space-platform-hub", 8, 8),
}
local items = {}
for name, p in pairs(entities) do items[name] = { name = name, place_result = p, stack_size = 10 } end
items.blueprint = { name = "blueprint" }
items["space-platform-foundation"] = { name = "space-platform-foundation", stack_size = 50,
  place_as_tile_result = { result = { name = "space-platform-foundation" }, condition_size = 1 } }
_G.prototypes = { item = items, entity = entities, shortcut = {},
  tile = { ["space-platform-foundation"] = { name = "space-platform-foundation",
    items_to_place_this = { { name = "space-platform-foundation", count = 1 } } }, ["empty-space"] = { name = "empty-space" } },
  asteroid_chunk = { ["metallic-asteroid-chunk"] = { name = "metallic-asteroid-chunk" },
    ["carbonic-asteroid-chunk"] = { name = "carbonic-asteroid-chunk" }, ["oxide-asteroid-chunk"] = { name = "oxide-asteroid-chunk" } } }

local own = { name = "player", technologies = {} }
own.recipes = {
  ["metallic-asteroid-crushing"] = { name = "metallic-asteroid-crushing", enabled = true, category = "crushing" },
  ["carbonic-asteroid-crushing"] = { name = "carbonic-asteroid-crushing", enabled = true, category = "crushing" },
  ["iron-gear-wheel"] = { name = "iron-gear-wheel", enabled = true, category = "crafting" },
}
own.is_chunk_charted = function() error("a platform is never checked for charting") end

local geometry = require("scripts.placement_geometry")

-- The platform: foundation x, y in [-6, 9] around a hub at (2, 2); its own
-- entities by list; every tile read and ghost check is counted.
local foundation = {}
for x = -6, 9 do for y = -6, 9 do foundation[x * 2097152 + y] = true end end
local world, reads = {}, { tiles = 0, can_place = {}, finds = 0 }
local function live()
  local out = {}
  for _, e in ipairs(world) do if e.valid then out[#out + 1] = e end end
  return out
end
local hub_stock = { ["space-platform-foundation"] = 4 }
local hub_main = mock.inventory({
  get_item_count = function(item) return hub_stock[type(item) == "table" and item.name or item] or 0 end,
  insert = function(stack) hub_stock[stack.name] = (hub_stock[stack.name] or 0) + stack.count; return stack.count end,
})
local function spawn(name, position, extra)
  local p = entities[name]
  local e = { valid = true, name = name, type = p.type, position = position, direction = 0, force = own, prototype = p }
  e.bounding_box = geometry.footprint(p, position, 0)
  for k, v in pairs(extra or {}) do e[k] = v end
  world[#world + 1] = e
  return e
end
local hub = spawn("space-platform-hub", { x = 2, y = 2 }, {
  get_inventory = function(id) return id == defines.inventory.hub_main and hub_main or nil end })

local inside = function(area, p)
  return p.x > area.left_top.x and p.x < area.right_bottom.x and p.y > area.left_top.y and p.y < area.right_bottom.y
end
local platform_surface = mock.surface({ valid = true, name = "platform-1", index = 9,
  get_tile = function(x, y)
    reads.tiles = reads.tiles + 1
    local name = foundation[x * 2097152 + y] and "space-platform-foundation" or "empty-space"
    return mock.tile({ name = name, collides_with = function(layer) return layer == "empty_space" and name == "empty-space" end })
  end,
  can_place_entity = function(args)
    reads.can_place[#reads.can_place + 1] = args
    assert(entities[args.name] and args.build_check_type == defines.build_check_type.manual_ghost)
    local area = geometry.footprint(entities[args.name], args.position, args.direction)
    for y = math.floor(area.left_top.y), math.ceil(area.right_bottom.y) - 1 do
      for x = math.floor(area.left_top.x), math.ceil(area.right_bottom.x) - 1 do
        if not foundation[x * 2097152 + y] then return false end
      end
    end
    for _, e in ipairs(live()) do if geometry.overlaps(area, e.bounding_box) then return false end end
    return true
  end,
  find_entities_filtered = function(filter)
    reads.finds = reads.finds + 1
    assert(filter.area or filter.position, "no entity query may search the whole surface")
    local out = {}
    for _, e in ipairs(live()) do
      local hit = filter.area and geometry.overlaps(filter.area, e.bounding_box)
        or filter.position and filter.radius and (e.position.x - filter.position.x) ^ 2 + (e.position.y - filter.position.y) ^ 2
          <= filter.radius ^ 2
      if hit and (not filter.force or filter.force == e.force) and (not filter.name or filter.name == e.name) then out[#out + 1] = e end
      if filter.limit and #out >= filter.limit then break end
    end
    return out
  end,
  spill_item_stack = function() error("the hub takes what fits") end,
})
local platform = { valid = true, index = 1, name = "Forge", scheduled_for_deletion = 0, hub = hub, surface = platform_surface }
own.platforms = { [1] = platform }

-- The body stands on Nauvis, far away, and never walks for a platform.
local walked = 0
local planet_target
local body = { valid = true, name = "character", position = { x = 500.5, y = 500.5 }, force = own,
  surface = { name = "nauvis", valid = true }, reach_distance = 10, build_distance = 10 }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
package.loaded["scripts.actions.approach"] = {
  ensure = function() walked = walked + 1; return "ok" end,
  ensure_entity = function() walked = walked + 1; return "ok" end,
  find_entity_near = function() return planet_target end,
}
package.loaded["scripts.factory_activity"] = { record = function() end }
package.loaded["scripts.registry"] = { add = function() end, any = function() return false end }

require("scripts.state").init()
local blueprints = require("scripts.blueprints")
local layout = require("scripts.actions.build_layout")
local area_ops = require("scripts.actions.area_ops")
local configure = require("scripts.actions.configure")
local build = require("scripts.actions.build")
local settings = require("scripts.entity_settings")
local jobs = require("scripts.jobs")

-- The transient blueprint: a strict item stack; build_blueprint aligns an
-- absolutely snapped 1x1 blueprint's box (the top-left tile of its entities'
-- footprints and its tiles, not its (0, 0)) to the cell under position (or
-- `shift` tiles off, to prove the read-back) and returns its ghosts.
local built, created, destroyed, shift = {}, {}, 0, 0
local fail_create
platform_surface.create_entity = function(args)
  created[#created + 1] = args
  assert(args.name == "entity-ghost" or args.name == "tile-ghost", "only ghosts, never free machines or foundation")
  assert(args.force == own and args.raise_built and args.player == nil, "ghosts do not affect the player or undo queue")
  if fail_create and #created == fail_create then return nil end
  return mock.entity({ valid = true, type = args.name, name = args.name, ghost_name = args.inner_name,
    position = { x = args.position.x + shift, y = args.position.y }, direction = args.direction or 0,
    destroy = function() destroyed = destroyed + 1; return true end })
end
local scratch_state = {}
local scratch
scratch = mock.item_stack({
  set_blueprint_entities = function(list) scratch_state.entities = list end,
  set_blueprint_tiles = function(list) scratch_state.tiles = list end,
  build_blueprint = function(args)
    assert(scratch.blueprint_absolute_snapping == true and scratch.blueprint_snap_to_grid.x == 1
      and scratch.blueprint_position_relative_to_grid.x == 0, "the blueprint is aligned to the world grid")
    built[#built + 1] = { args = args, entities = scratch_state.entities or {}, tiles = scratch_state.tiles or {} }
    local left, top = math.huge, math.huge
    for _, e in ipairs(scratch_state.entities or {}) do
      local area = geometry.footprint(entities[e.name], e.position, e.direction or 0)
      left, top = math.min(left, area.left_top.x), math.min(top, area.left_top.y)
    end
    for _, t in ipairs(scratch_state.tiles or {}) do left, top = math.min(left, t.position.x), math.min(top, t.position.y) end
    local ox = math.floor(args.position.x) - math.floor(left + 0.01) + shift
    local oy = math.floor(args.position.y) - math.floor(top + 0.01)
    local ghosts = {}
    local function ghost(kind, name, x, y)
      local g = mock.entity({ valid = true, type = kind, ghost_name = name, name = kind, position = { x = x, y = y },
        destroy = function() destroyed = destroyed + 1; return true end })
      ghosts[#ghosts + 1] = g
    end
    for _, e in ipairs(scratch_state.entities or {}) do ghost("entity-ghost", e.name, ox + e.position.x, oy + e.position.y) end
    for _, t in ipairs(scratch_state.tiles or {}) do ghost("tile-ghost", t.name, ox + t.position.x + 0.5, oy + t.position.y + 0.5) end
    return ghosts
  end,
})
blueprints.scratch = function() scratch_state = {}; return scratch end

local function run(spec, step, max_ticks)
  spec.validate(step, 1)
  local task = spec.make_task(step)
  task.id = 11
  spec.runner.start(task)
  for tick = 1, max_ticks or 50 do
    game.tick = game.tick + 1
    local result = spec.runner.tick(task)
    if result then return result, task, tick end
  end
end

-- -------------------------------------------------------------- validation

local L = layout.layout_action
local ghost_step = { action = "build_layout", platform = "Forge", anchor = { x = 0, y = 0 },
  entities = { { name = "crusher", dx = 6, dy = 0.5, recipe = "metallic-asteroid-crushing" },
    { name = "asteroid-collector", dx = 0.5, dy = 7.5, settings = { collector = { filters = { "metallic-asteroid-chunk" } } } } },
  tile_rects = { { name = "space-platform-foundation", from = { dx = -2, dy = 8 }, to = { dx = 1, dy = 8 } } } }
check(pcall(L.validate, ghost_step, 1), "a platform layout with entities, settings and foundation validates")
check(L.remote(ghost_step) and not L.remote({ entities = {} }), "a platform layout is remote; a planet one is not")
check(raises(function() L.validate({ platform = "Forge", mode = "hand", anchor = { x = 0, y = 0 },
  entities = { { name = "crusher", dx = 0, dy = 0 } } }, 2) end, "^NO_BODY_ON_SURFACE"),
  "hand mode on a platform is refused: the body is not there")
check(raises(function() L.validate({ platform = 1, site = { near = { x = 0, y = 0 } },
  entities = { { name = "crusher", dx = 0, dy = 0 } } }, 2) end, "anchor relative to the hub"), "a platform takes no site")
check(raises(function() L.validate({ anchor = { x = 0, y = 0 }, entities = { { name = "crusher", dx = 0, dy = 0 } },
  tiles = { { name = "space-platform-foundation", dx = 0, dy = 0 } } }, 2) end, "place_tiles"),
  "tiles without a platform are refused (planets use place_tiles)")
check(raises(function() L.validate({ platform = 1, anchor = { x = 0, y = 0 }, entities = {},
  tile_rects = { { name = "space-platform-foundation", from = { dx = 0, dy = 0 }, to = { dx = 39, dy = 25 } } } }, 2) end,
  "more than 1000 tiles"), "more than 1000 tiles are refused")
check(raises(function() L.validate({ platform = 1, anchor = { x = 0, y = 0 }, entities = {},
  tiles = { { name = "lava", dx = 0, dy = 0 } } }, 2) end, "^UNKNOWN_TILE"), "an unknown tile is refused")
check(raises(function() L.validate({ mode = "ghosts", anchor = { x = 0, y = 0 },
  entities = { { name = "crusher", dx = 0, dy = 0, insert = { coal = 1 } } } }, 2) end, "ghosts take no starter items"),
  "ghosts take no starter items")
check(pcall(L.validate, { platform = 1, anchor = { x = 0, y = 0 }, entities = {},
  tiles = { { name = "space-platform-foundation", dx = 0, dy = 8 } } }, 2), "a foundation-only platform layout validates")
check(raises(function() L.validate({ platform = 0, anchor = { x = 0, y = 0 }, entities = {},
  tiles = { { name = "space-platform-foundation", dx = 0, dy = 8 } } }, 2) end, "platform name or index"),
  "a bad platform selector is refused at queue time")

-- --------------------------------------------------------------- check_only

local function check_params(extra)
  local params = { check_only = true }
  for k, v in pairs(ghost_step) do params[k] = v end
  for k, v in pairs(extra or {}) do params[k] = v end
  return params
end
local far = check_params({ tiles = { { name = "space-platform-foundation", dx = 20, dy = 20 },
  { name = "space-platform-foundation", dx = 0, dy = 0 } } })
local dry = jobs.run_now(layout.layout_check_job, far)
local tile_failure
for _, row in ipairs(dry.failed) do if row.code == "TILE_NOT_ADJACENT" then tile_failure = row end end
check(not dry.ok and tile_failure and tile_failure.tile.x == 22 and tile_failure.tile.y == 22 and #built == 0,
  "a foundation tile touching nothing fails (at its absolute tile, hub-relative anchor) and nothing is placed")
check(dry.tiles.already == 1 and dry.platform.name == "Forge" and dry.surface == "platform:1" and dry.hub.x == 2,
  "a tile that is foundation already is counted, and the result names the platform and its hub")

local ok_dry = jobs.run_now(layout.layout_check_job, check_params())
local ghost_checks = 0
for _, args in ipairs(reads.can_place) do
  if args.name == "crusher" and args.force == own and args.position.x == 8 and args.position.y == 2.5 then
    ghost_checks = ghost_checks + 1
  end
end
check(ok_dry.ok and ok_dry.tiles.would_place == 4 and #built == 0 and ghost_checks >= 1,
  "check_only passes: the crusher is checked as an entity ghost (manual_ghost) at hub + offset, nothing placed")
check(ok_dry.needs_planned_tiles and ok_dry.needs_planned_tiles[1] == 1 and not ok_dry.failed[1],
  "the collector over planned foundation waits for those tiles instead of failing")
local missing = {}
for _, row in ipairs(ok_dry.missing or {}) do missing[row.item] = row.count end
check(missing.crusher == 1 and missing["asteroid-collector"] == 1 and missing["space-platform-foundation"] == nil
  and walked == 0, "missing is what the hub lacks (it holds the 4 foundation); the body never walked")

-- A footprint half over planned foundation and half over empty space is
-- refused; one over laid and planned foundation waits for the tiles.
local edge = { { name = "space-platform-foundation", from = { dx = 8, dy = -2 }, to = { dx = 8, dy = 0 } } }
local overhang = jobs.run_now(layout.layout_check_job, { check_only = true, platform = 1, anchor = { x = 0, y = 0 },
  entities = { { name = "asteroid-collector", dx = 9.5, dy = -0.5 } }, tile_rects = edge })
check(not overhang.ok and overhang.failed[1] and overhang.failed[1].reason:match("part of the footprint has no foundation")
  and #overhang.failed == 1, "a footprint overhanging empty space past planned foundation fails the check")
local covered = jobs.run_now(layout.layout_check_job, { check_only = true, platform = 1, anchor = { x = 0, y = 0 },
  entities = { { name = "asteroid-collector", dx = 7.5, dy = -0.5 } }, tile_rects = edge })
check(covered.ok and covered.needs_planned_tiles and #covered.needs_planned_tiles == 1,
  "a footprint over laid and planned foundation waits for the planned tiles")

-- Foundation adjacency is connectivity: a 2x2 island three tiles off the
-- platform touches only itself and is refused, tile by tile.
local island = jobs.run_now(layout.layout_check_job, { check_only = true, platform = 1, anchor = { x = 0, y = 0 },
  entities = {}, tile_rects = { { name = "space-platform-foundation", from = { dx = 11, dy = 0 }, to = { dx = 12, dy = 1 } } } })
local not_adjacent = 0
for _, row in ipairs(island.failed) do if row.code == "TILE_NOT_ADJACENT" then not_adjacent = not_adjacent + 1 end end
check(not island.ok and not_adjacent == 4 and island.tiles.would_place == 0, "an island of requested tiles is not connected")
local bridge = jobs.run_now(layout.layout_check_job, { check_only = true, platform = 1, anchor = { x = 0, y = 0 },
  entities = {}, tile_rects = { { name = "space-platform-foundation", from = { dx = 11, dy = 0 }, to = { dx = 12, dy = 1 } },
    { name = "space-platform-foundation", from = { dx = 8, dy = 0 }, to = { dx = 10, dy = 0 } } } })
check(bridge.ok and bridge.tiles.would_place == 7, "the same island joined by a row of tiles to the platform is connected")

-- ------------------------------------------------------------------- build

local result, task, ticks = run(L, ghost_step)
check(result and result.status == "done" and result.outcome.code == "GHOSTS_PLACED" and ticks == 2
  and result.outcome.ghosts_placed == 2 and result.outcome.tiles_placed == 4,
  "the platform layout places 2 entity ghosts and 4 foundation ghosts on the tick after checking")
check(#built == 0 and #created == 6, "platform placement uses native ghosts; a blueprint cannot place entities over pending floor")
local rows = {}
for _, args in ipairs(created) do rows[args.inner_name] = args end
check(rows.crusher.recipe == "metallic-asteroid-crushing" and rows.crusher.position.x == 8
  and rows.crusher.position.y == 2.5 and rows["asteroid-collector"]["chunk-filter"][1].name == "metallic-asteroid-chunk",
  "world coordinates, crusher recipe and collector filters ride along in native ghost creation")
check(created[1].inner_name == "space-platform-foundation" and created[1].position.x == 0.5
  and created[1].position.y == 10.5 and created[4].name == "tile-ghost" and created[5].name == "entity-ghost",
  "foundation ghosts use tile centers and are created before entity ghosts")
check(walked == 0 and body.position.x == 500.5 and hub_stock["space-platform-foundation"] == 4,
  "no body, no walking, no items moved")

local wrong = run(L, { action = "build_layout", platform = 1, anchor = { x = 0, y = 0 },
  entities = { { name = "crusher", dx = 4, dy = 0.5, recipe = "iron-gear-wheel" } } })
check(wrong.status == "failed" and wrong.outcome.code == "LAYOUT_CHECK_FAILED" and wrong.outcome.failed[1].code == "RECIPE_NOT_SETTABLE"
  and #created == 6 and #built == 0, "a recipe the crusher cannot craft fails before anything is placed")

shift = 1
local count_before = #created
local misplaced = run(L, { action = "build_layout", platform = 1, anchor = { x = 0, y = 0 },
  entities = { { name = "inserter", dx = -7.5, dy = -7.5 } } })
check(misplaced.status == "failed" and misplaced.outcome.code == "GHOSTS_MISPLACED" and destroyed == 1
  and #created == count_before + 1, "a ghost off its spot removes every ghost again and fails")
shift = 0

-- Native creation can refuse one entry after creating others. It must fail
-- honestly with a useful position/reason and remove only its own new ghosts.
local removed_before = destroyed
fail_create = #created + 2
local incomplete = run(L, { action = "build_layout", platform = 1, anchor = { x = 0, y = 0 },
  entities = { { name = "inserter", dx = -7.5, dy = -6.5 }, { name = "inserter", dx = 6.5, dy = -7.5 } } })
check(incomplete.status == "failed" and incomplete.outcome.code == "GHOSTS_NOT_PLACED"
  and incomplete.outcome.ghosts_placed == 0 and destroyed == removed_before + 1
  and incomplete.outcome.failed[1].code == "GHOST_NOT_PLACED" and incomplete.outcome.failed[1].position
  and incomplete.outcome.failed[1].reason:match("returned no ghost"),
  "an incomplete batch reports its failed entry and rolls back the other new ghosts")
fail_create = nil

-- A layout around its anchor (negative offsets) lands where it was checked:
-- the snapped blueprint is aligned by its box, not by the anchor.
local around = run(L, { action = "build_layout", platform = 1, anchor = { x = 0, y = 0 },
  entities = { { name = "inserter", dx = -7.5, dy = -6.5 }, { name = "inserter", dx = 6.5, dy = -7.5 } } })
check(around.status == "done" and around.outcome.code == "GHOSTS_PLACED" and around.outcome.ghosts_placed == 2,
  "a layout with negative offsets is placed on its checked spots")

-- Work per tick: 1000 tiles are checked over ticks, each within the budget.
local strip = check_params({ entities = {}, tiles = nil,
  tile_rects = { { name = "space-platform-foundation", from = { dx = -8, dy = 8 }, to = { dx = 7, dy = 69 } } } })
local job = layout.layout_check_job
local state = job.start(strip)
local steps, worst, answer = 0, 0, nil
repeat
  local before = reads.tiles
  answer = job.step(state, { left = jobs.WORK_PER_TICK })
  steps = steps + 1
  worst = math.max(worst, reads.tiles - before)
until answer or steps > 100
check(answer and answer.ok and answer.tiles.would_place == 992 and steps > 1 and worst <= jobs.WORK_PER_TICK + 5,
  "992 foundation tiles are checked over several ticks, never more tile reads than a tick's work")

-- A large platform layout: its ghosts are never placed on the tick the
-- check finishes, and go down in batches over ticks, foundation first.
local big_step = { action = "build_layout", platform = 1, anchor = { x = 0, y = 0 },
  entities = { { name = "inserter", dx = -7.5, dy = 67.5 } },
  tile_rects = { { name = "space-platform-foundation", from = { dx = -8, dy = 8 }, to = { dx = 7, dy = 69 } } } }
L.validate(big_step, 1)
local big_task = L.make_task(big_step)
big_task.id = 12
L.runner.start(big_task)
local built_at_search_end, big_result, big_ticks = nil, nil, 0
local first_build = #created + 1
local batches = {}
repeat
  game.tick = game.tick + 1
  big_ticks = big_ticks + 1
  local searching = big_task._search ~= nil
  local before = #created
  big_result = L.runner.tick(big_task)
  if #created > before then batches[#batches + 1] = #created - before end
  if searching and not big_task._search then built_at_search_end = #created - before end
until big_result or big_ticks > 100
local batches_ok, tiles_first = true, true
for _, count in ipairs(batches) do batches_ok = batches_ok and count <= 120 end
for i = first_build, #created - 1 do tiles_first = tiles_first and created[i].name == "tile-ghost" end
check(big_result and big_result.status == "done" and big_result.outcome.tiles_placed == 992
  and big_result.outcome.ghosts_placed == 1 and built_at_search_end == 0 and #batches == 9 and batches_ok and tiles_first,
  "992 tiles and an entity are placed in 9 batches of at most 120, foundation first, from the tick after checking")

-- ---------------------------------------------------------- blueprint_place

blueprints.create({ name = "cell", entities = { { name = "crusher", dx = 0, dy = 0.5, recipe = "carbonic-asteroid-crushing" } } })
check(raises(function() area_ops.place_action.validate({ name = "cell", position = { x = 0, y = 0 }, platform = 1,
  mode = "hand" }, 1) end, "^NO_BODY_ON_SURFACE"), "blueprint_place by hand on a platform is refused")
local built_before = #built
local dry_place = jobs.run_now(area_ops.place_check_job, { name = "cell", position = { x = -6, y = 0 }, platform = 1,
  check_only = true })
check(dry_place.ok and dry_place.surface == "platform:1" and dry_place.missing[1].item == "crusher" and #built == built_before
  and bp.built[1] == nil, "blueprint_place {platform} check_only checks ghosts on the platform and names what the hub lacks")
bp.built = {}
local placed = run(area_ops.place_action, { name = "cell", position = { x = -4, y = 0 }, platform = "Forge" })
local args = bp.built[1]
check(placed.status == "done" and placed.outcome.surface == "platform:1" and args.surface == platform_surface
  and args.build_mode == defines.build_mode.normal and args.position.x == -2 and args.position.y == 2 and walked == 0,
  "blueprint_place {platform} builds the ghosts on the platform at hub + position, remotely")
check(area_ops.place_action.remote({ platform = 1 }) and area_ops.place_action.budget_steps({ name = "cell", platform = 1 }) == 1,
  "blueprint_place {platform} is a remote one-tick step")

-- --------------------------------------------------------- deconstruct_area

local orders = {}
local crusher = spawn("crusher", { x = 7, y = 6.5 }, {
  order_deconstruction = function(force) orders[#orders + 1] = force; return true end })
hub.order_deconstruction = function() error("the hub is never ordered") end
local D = area_ops.deconstruct_action
check(raises(function() D.validate({ area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 9, y = 9 } }, platform = 1,
  mode = "hand" }, 1) end, "^NO_BODY_ON_SURFACE"), "deconstruct_area by hand on a platform is refused")
local cleared = run(D, { area = { left_top = { x = -3, y = -3 }, right_bottom = { x = 9, y = 9 } }, platform = 1 })
check(cleared.status == "done" and cleared.outcome.code == "DECONSTRUCTION_ORDERED" and #orders == 1 and orders[1] == own
  and cleared.outcome.platform.name == "Forge" and cleared.outcome.note:match("hub") and walked == 0,
  "deconstruct_area {platform} orders the platform's entities for the hub (never the hub itself), remotely")

-- ----------------------------------------------------------- configure_entity

local chunks = {}
local collector = spawn("asteroid-collector", { x = -3.5, y = 7.5 }, { filter_slot_count = 2,
  get_filter = function(i) return chunks[i] and prototypes.asteroid_chunk[chunks[i]] or nil end,
  set_filter = function(i, name) chunks[i] = name end })
local C = configure.action
local configured = run(C, { action = "configure_entity", platform = 1, x = -3.5, y = 7.5,
  collector = { filters = { "carbonic-asteroid-chunk", "oxide-asteroid-chunk" } } })
check(configured.status == "done" and chunks[1] == "carbonic-asteroid-chunk" and chunks[2] == "oxide-asteroid-chunk"
  and configured.outcome.settings.collector.filters[2] == "oxide-asteroid-chunk"
  and configured.outcome.entity.surface == "platform:1" and walked == 0,
  "configure_entity {platform} sets a collector's chunk filters remotely and reads them back")
local again = run(C, { action = "configure_entity", platform = 1, x = -3.5, y = 7.5,
  collector = { filters = { "carbonic-asteroid-chunk", "oxide-asteroid-chunk" } } })
check(again.status == "done" and #again.outcome.changed == 0, "repeating it changes nothing")
local cleared_filters = configure.rpc({ platform = "Forge", x = -3.5, y = 7.5, collector = { filters = {} } })
check(cleared_filters.code == "CONFIGURED" and chunks[1] == nil and chunks[2] == nil, "over RPC, [] clears the filters at once")
local too_many = run(C, { action = "configure_entity", platform = 1, x = -3.5, y = 7.5,
  collector = { filters = { "carbonic-asteroid-chunk", "oxide-asteroid-chunk", "metallic-asteroid-chunk" } } })
check(too_many.status == "failed" and too_many.outcome.code == "CONFIG_NOT_APPLICABLE" and chunks[1] == nil,
  "more filters than the collector has slots are refused before any write")
check(raises(function() C.validate({ platform = 1, x = 0, y = 0, collector = { filters = { "ice-chunk" } } }, 3) end,
  "^UNKNOWN_CHUNK"), "an unknown asteroid chunk is refused at queue time")
check(raises(function() configure.rpc({ x = 0, y = 0, inserter = { stack_size = 1 } }) end, "needs the body"),
  "configure_entity over RPC is for platform entities only")
check(C.remote({ platform = 1 }) and not C.remote({}), "configure_entity on a platform is remote; on a planet it is not")

-- A silo on the planet: its automatic requests, within reach.
local silo = mock.entity({ valid = true, name = "rocket-silo", type = "rocket-silo", force = own, position = { x = 10.5, y = 10.5 },
  use_transitional_requests = false, filter_slot_count = 0,
  prototype = mock.entity_prototype({ name = "rocket-silo", type = "rocket-silo" }) })
planet_target = silo
local before_walks = walked
local silo_set = run(C, { action = "configure_entity", x = 10.5, y = 10.5, silo = { auto_requests = true } })
check(silo_set.status == "done" and silo.use_transitional_requests == true and silo_set.outcome.settings.silo.auto_requests
  and walked > before_walks, "configure_entity silo.auto_requests sets the silo's automatic requests within reach")
local wrong_group = run(C, { action = "configure_entity", x = 10.5, y = 10.5, collector = { filters = {} } })
check(wrong_group.status == "failed" and wrong_group.outcome.code == "CONFIG_NOT_APPLICABLE",
  "collector settings on a silo are not applicable")

-- ----------------------------------------------------------------- set_recipe

local recipe
crusher.get_recipe = function() return recipe and own.recipes[recipe] or nil end
crusher.set_recipe = function(name)
  local removed = recipe and { { name = "metallic-asteroid-chunk", count = 3, quality = "normal" } } or {}
  recipe = name
  return removed
end
recipe = "metallic-asteroid-crushing"
local R = build.set_recipe_action
local walks_before_recipe = walked
local set = run(R, { action = "set_recipe", platform = 1, x = 7, y = 6.5, recipe = "carbonic-asteroid-crushing" })
check(set.status == "done" and recipe == "carbonic-asteroid-crushing" and hub_stock["metallic-asteroid-chunk"] == 3
  and set.outcome.entity.surface == "platform:1" and walked == walks_before_recipe,
  "set_recipe {platform} sets the crusher's recipe remotely and what it held goes to the hub")
local refused = run(R, { action = "set_recipe", platform = 1, x = 7, y = 6.5, recipe = "iron-gear-wheel" })
check(refused.status == "failed" and refused.outcome.code == "RECIPE_NOT_SETTABLE" and recipe == "carbonic-asteroid-crushing",
  "a crusher takes only crushing recipes")
check(R.remote({ platform = 1 }) and not R.remote({}) and raises(function() R.validate({ x = 0, y = 0, recipe = "x", platform = 0 }, 1) end,
  "platform name or index"), "set_recipe with platform is remote and its selector is checked at queue time")
local unknown = run(R, { action = "set_recipe", platform = "Nowhere", x = 7, y = 6.5, recipe = "carbonic-asteroid-crushing" })
check(unknown.status == "failed" and unknown.outcome.code == "UNKNOWN_PLATFORM", "an unknown platform fails the step")
-- Over RPC (the direct tool): at once, platform machines only.
local direct = build.set_recipe_rpc({ platform = 1, x = 7, y = 6.5, recipe = "metallic-asteroid-crushing" })
check(direct.code == "RECIPE_SET" and direct.recipe == "metallic-asteroid-crushing" and recipe == "metallic-asteroid-crushing"
  and direct.entity.surface == "platform:1" and walked == walks_before_recipe,
  "set_recipe over RPC sets a platform machine at once without the body")
check(raises(function() build.set_recipe_rpc({ x = 7, y = 6.5, recipe = "metallic-asteroid-crushing" }) end, "needs the body")
  and raises(function() build.set_recipe_rpc({ platform = 1, x = 7, y = 6.5, recipe = "iron-gear-wheel" }) end, "RECIPE_NOT_SETTABLE")
  and recipe == "metallic-asteroid-crushing", "set_recipe over RPC refuses a planet machine and a wrong recipe, changing nothing")

-- A platform still waiting for its starter pack has no surface: remote
-- configure, set_recipe and deconstruct refuse with NO_HUB, never a Lua error.
own.platforms[2] = { valid = true, index = 2, name = "Bare", scheduled_for_deletion = 0 }
local bare_config = run(C, { action = "configure_entity", platform = "Bare", x = 0, y = 0, collector = { filters = {} } })
local bare_recipe = run(R, { action = "set_recipe", platform = "Bare", x = 0, y = 0, recipe = "carbonic-asteroid-crushing" })
local ok_bare, bare_error = pcall(run, area_ops.deconstruct_action,
  { area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 2, y = 2 } }, platform = "Bare" })
check(bare_config.outcome.code == "NO_HUB" and bare_recipe.outcome.code == "NO_HUB" and bare_recipe.detail:match("no surface yet")
  and not ok_bare and tostring(bare_error):match("^NO_HUB"), "a platform without a surface yet is refused with NO_HUB")
own.platforms[2] = nil

-- On a planet, ghosts mode marks the layout for robots (trees and rocks
-- marked for deconstruction), on charted ground only, with no item used.
local planet_checks = {}
body.surface = mock.surface({ name = "nauvis", valid = true,
  can_place_entity = function(args) planet_checks[#planet_checks + 1] = args; return true end,
  find_entities_filtered = function() return {} end })
own.is_chunk_charted = function() return true end
local robots_built = run(L, { action = "build_layout", mode = "ghosts", anchor = { x = 100, y = 100 },
  entities = { { name = "inserter", dx = 0.5, dy = 0.5, direction = 4 } } })
local planet_args = built[#built].args
check(robots_built.status == "done" and planet_args.surface == body.surface and planet_args.build_mode == defines.build_mode.forced
  and planet_args.skip_fog_of_war == true and planet_checks[1].forced == true and robots_built.outcome.missing == nil
  and not L.remote({ mode = "ghosts" }) and walked == walks_before_recipe,
  "ghosts mode on a planet places robot ghosts on the body's surface without walking or items")

-- ------------------------------------------------------- blueprint settings

local row = settings.to_blueprint({ collector = { filters = { "metallic-asteroid-chunk" } } }, {}, "asteroid-collector")
local silo_row = settings.to_blueprint({ silo = { auto_requests = true } }, {}, "rocket-silo")
check(row["chunk-filter"][1].index == 1 and row["chunk-filter"][1].name == "metallic-asteroid-chunk"
  and silo_row.use_transitional_requests == true, "collector filters and silo requests become blueprint fields")
local back = settings.from_blueprint({ name = "asteroid-collector", ["chunk-filter"] = { { index = 2, name = "oxide-asteroid-chunk" },
  { index = 1, name = "metallic-asteroid-chunk" } } }, "asteroid-collector")
check(back.collector.filters[1] == "metallic-asteroid-chunk" and back.collector.filters[2] == "oxide-asteroid-chunk",
  "a blueprint's chunk filters read back as collector settings in slot order")

-- A route's underground ends keep their end (input/output) in a hand build.
local steps_out = layout._plan_steps({ placements = {}, routes = { { route = { kind = "belt", index = 0 },
  steps = { { name = "underground-belt", x = 1.5, y = 0.5, direction = 4, belt_to_ground_type = "input" },
    { name = "underground-belt", x = 4.5, y = 0.5, direction = 4, belt_to_ground_type = "output" } } } } })
check(steps_out[1].belt_to_ground_type == "input" and steps_out[2].belt_to_ground_type == "output",
  "routed underground belt ends keep their input/output end")

-- ------------------------------------------------------------------ aboard

-- The body aboard the platform (companion.lua's body model): physical
-- runners get no character and fail BODY_ABOARD, while every platform
-- window (steps and direct tools) still works with the body's force.
local stub = package.loaded["scripts.companion"]
local on_planet = { get = stub.get, require_companion = stub.require_companion, require_present = stub.require_present }
local aboard = { state = "aboard_platform", force = own, surface = platform_surface, surface_ref = "platform:1",
  position = { x = 2, y = 2 } }
stub.get = function() return nil end
stub.require_companion = function() error("BODY_ABOARD: the body is aboard platform Forge (platform:1)", 0) end
stub.require_present = function() return aboard end
local walks_aboard = walked
local aboard_layout = run(L, ghost_step)
check(aboard_layout.status == "done" and aboard_layout.outcome.surface == "platform:1",
  "aboard, a build_layout {platform} step runs (its ghosts stand already)")
local aboard_dry = jobs.run_now(layout.layout_check_job, { check_only = true, platform = 1, anchor = { x = 0, y = 0 },
  entities = { { name = "crusher", dx = -10, dy = 6.5 } } })
check(aboard_dry.check_only and aboard_dry.platform.name == "Forge", "aboard, a platform layout dry run works")
bp.built = {}
local aboard_place = run(area_ops.place_action, { name = "cell", position = { x = -8, y = 4 }, platform = 1 })
local aboard_place_dry = jobs.run_now(area_ops.place_check_job, { name = "cell", position = { x = -8, y = 4 }, platform = 1,
  check_only = true })
check(aboard_place.status == "done" and bp.built[1] ~= nil and aboard_place_dry.surface == "platform:1",
  "aboard, blueprint_place {platform} and its dry run work")
local aboard_orders = #orders
local aboard_clear = run(D, { area = { left_top = { x = 6, y = 5.5 }, right_bottom = { x = 8, y = 8 } }, platform = 1 })
check(aboard_clear.status == "done" and #orders > aboard_orders, "aboard, deconstruct_area {platform} orders the hub's work")
local aboard_config = run(C, { action = "configure_entity", platform = 1, x = -3.5, y = 7.5,
  collector = { filters = { "oxide-asteroid-chunk" } } })
check(aboard_config.status == "done" and chunks[1] == "oxide-asteroid-chunk"
  and configure.rpc({ platform = 1, x = -3.5, y = 7.5, collector = { filters = {} } }).code == "CONFIGURED" and chunks[1] == nil,
  "aboard, configure_entity {platform} works as a step and over RPC")
local aboard_recipe = run(R, { action = "set_recipe", platform = 1, x = 7, y = 6.5, recipe = "carbonic-asteroid-crushing" })
check(aboard_recipe.status == "done" and recipe == "carbonic-asteroid-crushing"
  and build.set_recipe_rpc({ platform = 1, x = 7, y = 6.5, recipe = "metallic-asteroid-crushing" }).code == "RECIPE_SET",
  "aboard, set_recipe {platform} works as a step and over RPC")
local planet_step = C.make_task({ x = 10.5, y = 10.5, silo = { auto_requests = false } })
check(raises(function() C.runner.start(planet_step) end, "^BODY_ABOARD") and walked == walks_aboard,
  "aboard, a planet entity's settings fail BODY_ABOARD and nothing walks")
stub.get, stub.require_companion, stub.require_present = on_planet.get, on_planet.require_companion, on_planet.require_present

mock.assert_clean()
if failures > 0 then
  print(failures .. " PLATFORM BUILDING TEST(S) FAILED")
  os.exit(1)
end
print("ALL PLATFORM BUILDING TESTS PASSED")
