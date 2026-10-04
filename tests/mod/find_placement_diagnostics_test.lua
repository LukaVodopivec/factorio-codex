-- Endpoint binding measured in Factorio 2.0.77 and the placement-search
-- diagnostics that let an agent act on an empty result instead of retrying.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local ENGINE_HALF = 179 / 256 -- collision boxes as the engine reports them (0.7 rounded to 1/256)
local function box_at(position, half)
  return { left_top = { x = position.x - half, y = position.y - half },
    right_bottom = { x = position.x + half, y = position.y + half } }
end
local function burner(name) return { name = name } end
local protos = {
  ["burner-mining-drill"] = { name = "burner-mining-drill", type = "mining-drill", tile_width = 2, tile_height = 2,
    vector_to_place_result = { x = -0.5, y = -1.3 }, mining_drill_radius = 0.99,
    resource_categories = { ["basic-solid"] = true }, burner_prototype = burner("burner"),
    collision_box = { left_top = { x = -ENGINE_HALF, y = -ENGINE_HALF }, right_bottom = { x = ENGINE_HALF, y = ENGINE_HALF } } },
  ["stone-furnace"] = { name = "stone-furnace", type = "furnace", tile_width = 2, tile_height = 2,
    burner_prototype = burner("burner"),
    collision_box = { left_top = { x = -ENGINE_HALF, y = -ENGINE_HALF }, right_bottom = { x = ENGINE_HALF, y = ENGINE_HALF } } },
  ["burner-inserter"] = { name = "burner-inserter", type = "inserter", tile_width = 1, tile_height = 1,
    inserter_pickup_position = { 0, -1 }, inserter_drop_position = { 0, 1.2 }, burner_prototype = burner("burner"),
    collision_box = { left_top = { x = -0.15, y = -0.15 }, right_bottom = { x = 0.15, y = 0.15 } } },
  ["long-handed-inserter"] = { name = "long-handed-inserter", type = "inserter", tile_width = 1, tile_height = 1,
    inserter_pickup_position = { 0, -2 }, inserter_drop_position = { 0, 2.2 },
    collision_box = { left_top = { x = -0.15, y = -0.15 }, right_bottom = { x = 0.15, y = 0.15 } } },
  ["wooden-chest"] = { name = "wooden-chest", type = "container", tile_width = 1, tile_height = 1,
    collision_box = { left_top = { x = -0.35, y = -0.35 }, right_bottom = { x = 0.35, y = 0.35 } } },
}
_G.defines = { build_check_type = { manual = 1 } }
_G.prototypes = { item = {}, entity = {} }
for name, proto in pairs(protos) do prototypes.item[name] = { place_result = proto } end

local output_targets = require("scripts.output_target")
local placement_geometry = require("scripts.placement_geometry")

-- 1. The live 2.0.77 probe: every flush burner drill whose output bound to a
-- stone furnace, and the nearest flush furnaces that did not bind.
local drill_cases = {
  { dir = 0, drill = { x = -110, y = -96 }, furnace = { x = -111, y = -98 }, bound = true },
  { dir = 0, drill = { x = -12, y = -96 }, furnace = { x = -12, y = -98 }, bound = true },
  { dir = 4, drill = { x = -12, y = -40 }, furnace = { x = -10, y = -41 }, bound = true },
  { dir = 4, drill = { x = 2, y = -40 }, furnace = { x = 4, y = -40 }, bound = true },
  { dir = 8, drill = { x = 72, y = -12 }, furnace = { x = 72, y = -10 }, bound = true },
  { dir = 8, drill = { x = -54, y = 2 }, furnace = { x = -53, y = 4 }, bound = true },
  { dir = 12, drill = { x = 86, y = 16 }, furnace = { x = 84, y = 16 }, bound = true },
  { dir = 12, drill = { x = 100, y = 16 }, furnace = { x = 98, y = 17 }, bound = true },
  { dir = 0, drill = { x = 44, y = -110 }, furnace = { x = 42, y = -110 }, bound = false },
  { dir = 0, drill = { x = 44, y = -96 }, furnace = { x = 44, y = -94 }, bound = false },
  { dir = 0, drill = { x = -12, y = -82 }, furnace = { x = -10, y = -82 }, bound = false },
  { dir = 4, drill = { x = 58, y = -68 }, furnace = { x = 56, y = -68 }, bound = false },
  { dir = 4, drill = { x = 2, y = -54 }, furnace = { x = 2, y = -56 }, bound = false },
  { dir = 4, drill = { x = 58, y = -54 }, furnace = { x = 58, y = -52 }, bound = false },
  { dir = 8, drill = { x = 72, y = -26 }, furnace = { x = 70, y = -26 }, bound = false },
  { dir = 8, drill = { x = 16, y = -12 }, furnace = { x = 16, y = -14 }, bound = false },
  { dir = 8, drill = { x = 16, y = 2 }, furnace = { x = 18, y = 2 }, bound = false },
  { dir = 12, drill = { x = 30, y = 30 }, furnace = { x = 30, y = 28 }, bound = false },
  { dir = 12, drill = { x = 86, y = 30 }, furnace = { x = 86, y = 32 }, bound = false },
  { dir = 12, drill = { x = 30, y = 44 }, furnace = { x = 32, y = 44 }, bound = false },
}
local drill_agree = true
for _, case in ipairs(drill_cases) do
  local point = output_targets.output_position(protos["burner-mining-drill"], case.drill, case.dir)
  if output_targets.box_contains(box_at(case.furnace, ENGINE_HALF), point) ~= case.bound then drill_agree = false end
end
check(drill_agree, "endpoint containment reproduces every probed burner-drill binding and non-binding")
local inserter_cases = {
  { dir = 0, inserter = { x = 29.5, y = 298.5 }, furnace = { x = 30, y = 300 }, bound = true },
  { dir = 0, inserter = { x = -69.5, y = 308.5 }, furnace = { x = -70, y = 310 }, bound = true },
  { dir = 4, inserter = { x = 41.5, y = 329.5 }, furnace = { x = 40, y = 330 }, bound = true },
  { dir = 4, inserter = { x = -108.5, y = 340.5 }, furnace = { x = -110, y = 340 }, bound = true },
  { dir = 8, inserter = { x = -20.5, y = 351.5 }, furnace = { x = -20, y = 350 }, bound = true },
  { dir = 8, inserter = { x = 40.5, y = 351.5 }, furnace = { x = 40, y = 350 }, bound = true },
  { dir = 12, inserter = { x = -61.5, y = 369.5 }, furnace = { x = -60, y = 370 }, bound = true },
  { dir = 12, inserter = { x = -51.5, y = 370.5 }, furnace = { x = -50, y = 370 }, bound = true },
  { dir = 0, inserter = { x = -102.5, y = 297.5 }, furnace = { x = -100, y = 300 }, bound = false },
  { dir = 0, inserter = { x = -92.5, y = 298.5 }, furnace = { x = -90, y = 300 }, bound = false },
  { dir = 0, inserter = { x = -82.5, y = 299.5 }, furnace = { x = -80, y = 300 }, bound = false },
  { dir = 0, inserter = { x = -72.5, y = 300.5 }, furnace = { x = -70, y = 300 }, bound = false },
  { dir = 0, inserter = { x = -41.5, y = 297.5 }, furnace = { x = -40, y = 300 }, bound = false },
  { dir = 0, inserter = { x = -31.5, y = 298.5 }, furnace = { x = -30, y = 300 }, bound = false },
}
local inserter_agree = true
for _, case in ipairs(inserter_cases) do
  local point = output_targets.output_position(protos["burner-inserter"], case.inserter, case.dir)
  if output_targets.box_contains(box_at(case.furnace, ENGINE_HALF), point) ~= case.bound then inserter_agree = false end
end
check(inserter_agree, "endpoint containment reproduces every probed burner-inserter binding and non-binding")

-- 2. Planned recipients sit flush beside the producer, never inside it.
local planned_ok = true
for _, dir in ipairs({ 0, 4, 8, 12 }) do
  local drill = { x = 45, y = -32 }
  local point = output_targets.output_position(protos["burner-mining-drill"], drill, dir)
  local drill_area = placement_geometry.footprint(protos["burner-mining-drill"], drill, dir)
  local chosen
  for _, position in ipairs(output_targets.planned_recipient_positions(protos["stone-furnace"], point, drill)) do
    if not placement_geometry.overlaps(drill_area, placement_geometry.footprint(protos["stone-furnace"], position, 0)) then
      chosen = position; break
    end
  end
  if not (chosen and output_targets.box_contains(placement_geometry.footprint(protos["stone-furnace"], chosen, 0), point)) then
    planned_ok = false
  end
end
check(planned_ok, "every drill direction has a flush, non-overlapping planned furnace containing the output point")

-- 3. find_placement against a small fake world.
local force = { is_chunk_charted = function() return true end }
local entities, ore, blocked_areas = {}, {}, {}
local function overlap(a, b)
  return a.left_top.x < b.right_bottom.x and a.right_bottom.x > b.left_top.x
    and a.left_top.y < b.right_bottom.y and a.right_bottom.y > b.left_top.y
end
local surface = {}
function surface.find_entities_filtered(args)
  if args.type == "resource" then
    local out = {}
    for _, resource in ipairs(ore) do
      local p, a = resource.position, args.area
      if p.x >= a.left_top.x and p.x < a.right_bottom.x and p.y >= a.left_top.y and p.y < a.right_bottom.y then out[#out + 1] = resource end
    end
    return out
  end
  local out = {}
  for _, entity in ipairs(entities) do
    if args.position then
      if output_targets.box_contains(entity.bounding_box, args.position) then out[#out + 1] = entity end
    elseif overlap(entity.bounding_box, args.area) then
      out[#out + 1] = entity
    end
  end
  return out
end
function surface.can_place_entity(args)
  local area = placement_geometry.footprint(protos[args.name], args.position, args.direction)
  for _, entity in ipairs(entities) do if overlap(area, entity.bounding_box) then return false end end
  for _, blocked in ipairs(blocked_areas) do if overlap(area, blocked) then return false end end
  return true
end
local function add_entity(name, position)
  local proto = protos[name]
  local entity = { valid = true, name = name, type = proto.type, force = force,
    position = position, bounding_box = placement_geometry.footprint(proto, position, 0) }
  entities[#entities + 1] = entity
  return entity
end
local function lay_ore(cx, cy, r)
  ore = {}
  for x = cx - r, cx + r do for y = cy - r, cy + r do
    ore[#ore + 1] = { valid = true, name = "iron-ore", type = "resource", amount = 100,
      position = { x = x + 0.5, y = y + 0.5 }, prototype = { resource_category = "basic-solid" } }
  end end
end
local body = { position = { x = 60, y = -30 }, force = force, surface = surface }
package.loaded["scripts.companion"] = { require_companion = function() return body end }
local finder = require("scripts.find_placement")

lay_ore(45, -30, 6)
for _, dir in ipairs({ 0, 4, 8, 12 }) do
  local result = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 45, y = -30 }, radius = 4,
    directions = { dir }, limit = 3, output_recipient_item = "stone-furnace" })
  local first = result.candidates[1]
  local steps = first and first.build_steps
  check(first and #steps == 2 and steps[1].name == "stone-furnace" and steps[1].fuel_inlet == true
    and steps[2].name == "burner-mining-drill" and steps[2].fuel_inlet == true
    and steps[2].output_target.x == steps[1].x and steps[2].output_target.y == steps[1].y
    and not placement_geometry.overlaps(placement_geometry.footprint(protos["stone-furnace"], { x = steps[1].x, y = steps[1].y }, 0),
      placement_geometry.footprint(protos["burner-mining-drill"], first.position, dir)),
    "burner drill with output_recipient_item=stone-furnace finds a flush furnace pair facing " .. dir)
end

add_entity("stone-furnace", { x = 45, y = -30 })
local flush = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 45, y = -32 }, radius = 1,
  directions = { 8 }, limit = 1, output_target = { x = 45, y = -30 } })
check(flush.candidates[1] and flush.candidates[1].position.x == 45 and flush.candidates[1].position.y == -32,
  "a drill flush against an existing furnace is found by output_target, as the engine binds it")

-- 4. Diagnostics: the live-run impossible inserter request explains itself.
entities = {}
lay_ore(0, 0, 0); ore = {}
add_entity("wooden-chest", { x = 38.5, y = -47.5 })
add_entity("stone-furnace", { x = 40, y = -48 })
body.position = { x = 39.5, y = -45 }
local adjacent = finder.find_placement({ item = "burner-inserter", preferred = { x = 39.5, y = -46.5 }, radius = 4,
  limit = 10, input_target = { x = 38.5, y = -47.5 }, output_target = { x = 40, y = -48 } })
check(#adjacent.candidates == 0 and adjacent.hint and adjacent.hint:find("adjacent (0 free tiles)", 1, true)
  and adjacent.hint:find("exactly 1 free tile", 1, true),
  "an inserter between adjacent endpoints returns an actionable endpoint-gap hint")
local fixed_keys = { uncharted = true, pickup_not_on_source = true, output_endpoint_unknown = true,
  output_not_on_recipient = true, planned_recipient_unplaceable = true, codex_body_overlap = true, blocked = true,
  no_compatible_resource = true }
local keys_ok, total = true, 0
for key, count in pairs(adjacent.rejections or {}) do keys_ok = keys_ok and fixed_keys[key] == true; total = total + count end
check(keys_ok and total == adjacent.evaluated, "every evaluation has exactly one fixed rejection reason")

entities = {}
add_entity("wooden-chest", { x = 36.5, y = -47.5 })
add_entity("stone-furnace", { x = 40, y = -48 })
local far = finder.find_placement({ item = "burner-inserter", preferred = { x = 38, y = -47.5 }, radius = 4,
  limit = 10, input_target = { x = 36.5, y = -47.5 }, output_target = { x = 40, y = -48 } })
check(#far.candidates == 0 and far.hint and far.hint:find("have 2 free tiles", 1, true),
  "an inserter between endpoints two tiles apart reports the gap it has and needs")
local long = finder.find_placement({ item = "long-handed-inserter", preferred = { x = 38, y = -47.5 }, radius = 4,
  limit = 10, input_target = { x = 36.5, y = -47.5 }, output_target = { x = 40, y = -48 } })
check(long.candidates[1] and long.candidates[1].position.x == 38.5 and long.hint == nil,
  "a long-handed inserter reaches the far tile of a 2x2 recipient across two free tiles")
entities = {}
add_entity("wooden-chest", { x = 33.5, y = -47.5 })
add_entity("stone-furnace", { x = 40, y = -48 })
local too_far = finder.find_placement({ item = "long-handed-inserter", preferred = { x = 37, y = -47.5 }, radius = 4,
  limit = 10, input_target = { x = 33.5, y = -47.5 }, output_target = { x = 40, y = -48 } })
check(#too_far.candidates == 0 and too_far.hint and too_far.hint:find("have 5 free tiles", 1, true)
  and too_far.hint:find("2-3 free tiles", 1, true),
  "a long-handed inserter too far from its endpoints reports the gaps that would work")

entities = {}
add_entity("wooden-chest", { x = 37.5, y = -47.5 })
add_entity("stone-furnace", { x = 40, y = -48 })
local fits = finder.find_placement({ item = "burner-inserter", preferred = { x = 38.5, y = -47.5 }, radius = 2,
  limit = 4, input_target = { x = 37.5, y = -47.5 }, output_target = { x = 40, y = -48 } })
check(fits.candidates[1] and fits.candidates[1].position.x == 38.5 and fits.candidates[1].position.y == -47.5
  and fits.candidates[1].direction == 12 and fits.hint == nil,
  "endpoints one free tile apart yield the exact inserter placement and no hint")

entities, blocked_areas = {}, {}
body.position = { x = 0.5, y = 20.5 }
blocked_areas[1] = { left_top = { x = -5, y = -5 }, right_bottom = { x = 5, y = 5 } }
add_entity("wooden-chest", { x = 0.5, y = 0.5 })
local blocked = finder.find_placement({ item = "wooden-chest", preferred = { x = 0.5, y = 0.5 }, radius = 1, limit = 1 })
check(#blocked.candidates == 0 and blocked.closest_rejected and blocked.closest_rejected.reason == "blocked"
  and blocked.closest_rejected.blocker and blocked.closest_rejected.blocker.name == "wooden-chest"
  and blocked.hint:find("wooden-chest", 1, true),
  "an all-blocked search names the blocker nearest the preferred position")

blocked_areas = {}
entities = {}
body.position = { x = 0.5, y = 0.5 }
local wide = finder.find_placement({ item = "wooden-chest", preferred = { x = 0.5, y = 0.5 }, radius = 30, limit = 4 })
check(#wide.candidates == 4 and wide.evaluated <= 8 and wide.truncated == nil
  and wide.candidates[1].position.x == 0.5 and wide.candidates[1].position.y == 0.5,
  "a search stops as soon as the nearest limit candidates are found")
blocked_areas[1] = { left_top = { x = -40, y = -40 }, right_bottom = { x = 40, y = 40 } }
local capped = finder.find_placement({ item = "wooden-chest", preferred = { x = 0.5, y = 0.5 }, radius = 30, limit = 4 })
check(#capped.candidates == 0 and capped.truncated == true and capped.evaluated == 600
  and capped.closest_rejected.reason == "blocked" and capped.hint:find("blocked", 1, true),
  "an all-blocked radius-30 search stops at the engine-call budget and says why")
blocked_areas = {}
local far_body = finder.find_placement({ item = "wooden-chest", preferred = { x = 0.5, y = 50.5 }, radius = 2, limit = 4 })
check(#far_body.candidates == 4 and far_body.candidates[1].position.y == 50.5,
  "find_placement searches charted terrain however far it is from Codex")

-- 2.0.77: adjacent narrow burner recipients accept fuel in every cardinal
-- rotation although the 1.2-tile drop lies outside their collision box.
blocked_areas, entities = {}, {}
body.position = { x = 0.5, y = 0.5 }
for _, dir in ipairs({ 0, 4, 8, 12 }) do
  entities = {}
  local producer = { x = 0.5, y = 0.5 }
  local point = output_targets.output_position(protos["burner-inserter"], producer, dir)
  local target_position = { x = math.floor(point.x) + 0.5, y = math.floor(point.y) + 0.5 }
  local target = add_entity("burner-inserter", target_position)
  check(not output_targets.box_contains(target.bounding_box, point)
    and output_targets.recipient_at(body, point, "output", "inserter") == target,
    "narrow native fuel recipient resolves beyond collision containment facing " .. dir)
  local existing = finder.find_placement({ item = "burner-inserter", preferred = producer,
    radius = 1, directions = { dir }, limit = 1, output_target = target_position })
  check(existing.geometry == "provisional" and existing.candidates[1]
    and existing.candidates[1].position.x == producer.x and existing.candidates[1].position.y == producer.y,
    "search finds the native adjacent existing fuel recipient facing " .. dir)
  entities = {}
  local planned = finder.find_placement({ item = "burner-inserter", preferred = producer,
    radius = 1, directions = { dir }, limit = 1, output_recipient_item = "burner-inserter" })
  local candidate = planned.candidates[1]
  check(candidate and candidate.output_recipient_placement.position.x == target_position.x
    and candidate.output_recipient_placement.position.y == target_position.y,
    "search proposes the native adjacent planned fuel recipient facing " .. dir)
end

-- The inset is a native boundary, not an entire-tile or selection-box fallback.
entities = {}
local point = { x = 1, y = 0.5 }
for _, case in ipairs({ { x = 1.0390625, bound = false }, { x = 1.04296875, bound = true },
  { x = 1.95703125, bound = true }, { x = 1.9609375, bound = false } }) do
  local target = { valid = true, name = "tiny-chest", type = "container", force = force,
    position = { x = case.x, y = 0.5 }, bounding_box = box_at({ x = case.x, y = 0.5 }, 1 / 256),
    selection_box = box_at({ x = case.x, y = 0.5 }, 0.5) }
  -- Native queries include boxes touching the closed inset edges.
  local old_query = surface.find_entities_filtered
  surface.find_entities_filtered = function(args)
    if args.area and target.bounding_box.right_bottom.x >= args.area.left_top.x
      and target.bounding_box.left_top.x <= args.area.right_bottom.x then return { target } end
    return {}
  end
  local found = output_targets.recipient_at(body, point, "output", "inserter")
  check((found == target) == case.bound, "native closed inset boundary at " .. case.x)
  surface.find_entities_filtered = old_query
end
entities = {}
local target = add_entity("burner-inserter", { x = 1.5, y = 0.5 })
add_entity("burner-inserter", { x = 2.5, y = 0.5 })
check(output_targets.recipient_at(body, { x = 1.7, y = 0.5 }, "output", "inserter") == target,
  "nearby next-tile burner is not a recipient")
local _, _, pickup_state = output_targets.recipient_at(body, { x = 1.7, y = 0.5 }, "input", "inserter")
check(pickup_state == "none", "native inserter geometry does not enable burner pickup inventories")
add_entity("wooden-chest", { x = 1.5, y = 0.5 })
local _, _, ambiguous = output_targets.recipient_at(body, { x = 1.7, y = 0.5 }, "output", "inserter")
check(ambiguous == "ambiguous", "multiple native geometry matches remain ambiguous")
entities = {}; local foreign = add_entity("burner-inserter", { x = 1.5, y = 0.5 }); foreign.force = {}
check(select(3, output_targets.recipient_at(body, { x = 1.7, y = 0.5 }, "output", "inserter")) == "none",
  "foreign-force native geometry cannot become a recipient")
entities = {}; add_entity("burner-inserter", { x = 30.75, y = 0.5 })
check(select(3, output_targets.recipient_at(body, { x = 30.2, y = 0.5 }, "output", "inserter")) == "none",
  "expanded query does not expose a recipient centre beyond local range")
force.is_chunk_charted = function() return false end
check(select(3, output_targets.recipient_at(body, point, "output", "inserter")) == "uncharted",
  "native endpoint tile must remain force-charted")
force.is_chunk_charted = function() return true end

if failures > 0 then error(failures .. " find_placement diagnostics checks failed") end
