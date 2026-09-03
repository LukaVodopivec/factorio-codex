local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local function canonical(value)
  if type(value) ~= "table" then return tostring(value) end
  local array = #value > 0; local out = {}
  if array then for i, item in ipairs(value) do out[i] = canonical(item) end
  else local keys = {}; for key in pairs(value) do keys[#keys + 1] = key end; table.sort(keys); for _, key in ipairs(keys) do out[#out + 1] = key .. "=" .. canonical(value[key]) end end
  return "{" .. table.concat(out, ",") .. "}"
end
local charted_calls, placement_calls = 0, 0
local force = { is_chunk_charted = function(_, chunk) charted_calls = charted_calls + 1; return chunk.x == 0 and chunk.y == 0 end }
local only_position
local surface = {
  can_place_entity = function(args) placement_calls = placement_calls + 1
    return args.position.x ~= 3.5 and (not only_position
      or (args.position.x == only_position.x and args.position.y == only_position.y))
  end,
  get_tile = function(x) return { collides_with = function(layer) return (layer == "water_tile" or layer == "player") and x >= 2 end } end,
}
local recipient = { valid = true, name = "stone-furnace", type = "furnace", force = force,
  position = { x = 5.5, y = 1.5 }, unit_number = 9,
  selection_box = { left_top = { x = 5, y = 1 }, right_bottom = { x = 6, y = 2 } },
  bounding_box = { left_top = { x = 4.999, y = 0.999 }, right_bottom = { x = 6, y = 2 } } }
local pole = { valid = true, name = "small-electric-pole", type = "electric-pole", force = force,
  position = { x = 5.5, y = 1.5 }, selection_box = recipient.selection_box }
local source = { valid = true, name = "wooden-chest", type = "container", force = force,
  position = { x = 1.5, y = 0.5 },
  selection_box = { left_top = { x = 1, y = 0 }, right_bottom = { x = 2, y = 1 } },
  bounding_box = { left_top = { x = 1, y = 0 }, right_bottom = { x = 2, y = 1 } } }
local sink = { valid = true, name = "iron-chest", type = "container", force = force,
  position = { x = 1.5, y = 2.5 },
  selection_box = { left_top = { x = 1, y = 2 }, right_bottom = { x = 2, y = 3 } },
  bounding_box = { left_top = { x = 1, y = 2 }, right_bottom = { x = 2, y = 3 } } }
local ore = {
  { valid = true, name = "iron-ore", type = "resource", amount = 500, position = { x = 3.25, y = 1 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "iron-ore", type = "resource", amount = 450, position = { x = 3.5, y = 1 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "iron-ore", type = "resource", amount = 500, position = { x = 5, y = -0.75 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "iron-ore", type = "resource", amount = 450, position = { x = 5, y = -0.5 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "iron-ore", type = "resource", amount = 500, position = { x = 6.5, y = 1 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "iron-ore", type = "resource", amount = 450, position = { x = 6.75, y = 1 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "iron-ore", type = "resource", amount = 500, position = { x = 5, y = 2.5 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "iron-ore", type = "resource", amount = 450, position = { x = 5, y = 2.75 },
    prototype = { resource_category = "basic-solid" } },
}
local resource_calls, resources = 0, ore
local target_matches = { recipient }
local output_tile_override = false
surface.find_entities_filtered = function(args)
  if args.type == "resource" then resource_calls = resource_calls + 1; return resources end
  if args.position then
    if args.position.x == 1.5 and args.position.y == 2.5 then return { sink } end
    return target_matches
  end
  local left_top = args.area.left_top or { x = args.area[1][1], y = args.area[1][2] }
  local x, y = left_top.x, left_top.y
  local width = args.area.right_bottom and args.area.right_bottom.x - args.area.left_top.x
    or args.area[2][1] - args.area[1][1]
  if width > 0.5 and output_tile_override ~= false then return output_tile_override end
  if width > 0.5 and x == 1 and y == 2 then return { sink } end
  if x == 1.5 and y == 0.5 then return { source } end
  if x == 1.5 and y == 2.5 then return { sink } end
  local matches = {}
  local right_bottom = args.area.right_bottom or { x = args.area[2][1], y = args.area[2][2] }
  for _, entity in ipairs(target_matches) do
    local box = entity.bounding_box
    if box and box.right_bottom.x > x and box.left_top.x < right_bottom.x
      and box.right_bottom.y > y and box.left_top.y < right_bottom.y then
      matches[#matches + 1] = entity
    end
  end
  return matches
end
local body = { position = { x = 1.5, y = 1.5 }, force = force, surface = surface }
package.loaded["scripts.companion"] = { require_companion = function() return body end }
_G.defines = { build_check_type = { manual = 1 } }
_G.prototypes = { item = {
  pipe = { place_result = { name = "pipe", type = "pipe", tile_width = 1, tile_height = 1, collision_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } } } },
  ["offshore-pump"] = { place_result = { name = "offshore-pump", type = "offshore-pump", tile_width = 1, tile_height = 1, collision_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } } } },
  ["burner-mining-drill"] = { place_result = { name = "burner-mining-drill", type = "mining-drill", tile_width = 2, tile_height = 2,
    vector_to_place_result = { x = 1, y = 0 }, mining_drill_radius = 1, resource_categories = { ["basic-solid"] = true },
    collision_box = { left_top = { x = -0.9, y = -0.9 }, right_bottom = { x = 0.9, y = 0.9 } } } },
  ["burner-inserter"] = { place_result = { name = "burner-inserter", type = "inserter", tile_width = 1, tile_height = 1,
    inserter_pickup_position = { 0, -1 }, inserter_drop_position = { 0, 1 },
    collision_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } } } },
  ["electric-mining-drill"] = { place_result = { name = "electric-mining-drill", type = "mining-drill", tile_width = 1, tile_height = 1,
    vector_to_place_result = { 0, -1.85 }, mining_drill_radius = 2, resource_categories = { ["basic-solid"] = true },
    collision_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } } } },
  ["broken-mining-drill"] = { place_result = { name = "broken-mining-drill", type = "mining-drill", tile_width = 2, tile_height = 2,
    mining_drill_radius = 1, resource_categories = { ["basic-solid"] = true },
    collision_box = { left_top = { x = -0.9, y = -0.9 }, right_bottom = { x = 0.9, y = 0.9 } } } },
} }
local finder = require("scripts.find_placement")
local first = finder.find_placement({ item = "pipe", preferred = { x = 1.5, y = 1.5 }, radius = 3, directions = { 12, 0, 4 }, limit = 8 })
local second = finder.find_placement({ item = "pipe", preferred = { x = 1.5, y = 1.5 }, radius = 3, directions = { 4, 12, 0 }, limit = 8 })
check(canonical(first) == canonical(second), "placement search is stable across direction input order")
check(first.candidates[1].position.x == 1.5 and first.candidates[1].position.y == 1.5 and first.candidates[1].direction == 0,
  "nearest tuple uses distance then y x direction")
local saw_shoreline = false; for _, candidate in ipairs(first.candidates) do if candidate.terrain == "shoreline" then saw_shoreline = true end end
check(saw_shoreline, "placement search classifies shoreline candidates")
local offshore = finder.find_placement({ item = "offshore-pump", preferred = { x = 2.5, y = 1.5 }, radius = 1, directions = { 0 }, limit = 1 })
check(offshore.candidates[1] and offshore.candidates[1].terrain == "offshore", "offshore pumps retain their shoreline-specific identity")
local edge = finder.find_placement({ item = "pipe", preferred = { x = 31.5, y = 1.5 }, radius = 1, directions = { 0 }, limit = 24 })
local leaked = false; for _, candidate in ipairs(edge.candidates) do if candidate.position.x >= 32 then leaked = true end end
check(not leaked and charted_calls > 0, "uncharted candidate footprints are never passed through as placements")
check(placement_calls > 0, "charted candidates use Factorio can_place_entity")
local inserter = finder.find_placement({ item = "burner-inserter", preferred = { x = 1.5, y = 1.5 }, radius = 1,
  directions = { 4, 0 }, limit = 2 })
check(inserter.candidates[1].pickup_position.x == 1.5 and inserter.candidates[1].pickup_position.y == 0.5
  and inserter.candidates[1].drop_position.x == 1.5 and inserter.candidates[1].drop_position.y == 2.5,
  "cardinal inserter placements expose deterministic prototype-derived endpoints")
check(inserter.candidates[2].direction == 4
  and inserter.candidates[2].pickup_position.x == 2.5 and inserter.candidates[2].pickup_position.y == 1.5
  and inserter.candidates[2].drop_position.x == 0.5 and inserter.candidates[2].drop_position.y == 1.5,
  "inserter endpoint evidence rotates with candidate direction")
local bound_inserter = finder.find_placement({ item = "burner-inserter", preferred = { x = 1.5, y = 1.5 }, radius = 1,
  directions = { 0 }, limit = 1, output_target = { x = 1.5, y = 2.5 } })
check(bound_inserter.output_target.name == "iron-chest" and bound_inserter.output_target.type == "container"
  and #bound_inserter.candidates == 1,
  "inserter search uses its drop offset when vector_to_place_result is absent and binds the exact recipient")
local diagonal_inserter = finder.find_placement({ item = "burner-inserter", preferred = { x = 1.5, y = 1.5 }, radius = 1,
  directions = { 2 }, limit = 1 })
check(#diagonal_inserter.candidates == 0,
  "output-capable non-cardinal placements are not returned without exact endpoint evidence")
local diagonal_drill = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 4, y = 4 }, radius = 1,
  directions = { 2 }, limit = 1 })
check(#diagonal_drill.candidates == 0,
  "mining-drill candidates never omit output endpoint and recipient evidence")
local missing_vector_drill = finder.find_placement({ item = "broken-mining-drill", preferred = { x = 4, y = 4 }, radius = 1,
  directions = { 0 }, limit = 1 })
check(#missing_vector_drill.candidates == 0,
  "mining drills with missing output-vector metadata are rejected rather than returned with omitted evidence")
local aligned = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 4.5, y = 1.5 }, radius = 2,
  directions = { 12, 8, 4, 0 }, limit = 8, output_target = { x = 5.5, y = 1.5 } })
check(aligned.output_target.name == "stone-furnace" and #aligned.candidates > 0,
  "output target resolves one exact player-owned recipient")
local selection_only_target, selection_only_error = pcall(finder.find_placement, {
  item = "burner-mining-drill", preferred = { x = 4.5, y = 1.5 }, radius = 1,
  directions = { 0 }, limit = 1, output_target = { x = 5.25, y = 1.5 },
})
check(not selection_only_target and tostring(selection_only_error):match("does not identify") ~= nil,
  "output target identity cannot be resolved from selection-box point containment")
for _, candidate in ipairs(aligned.candidates) do
  local tx, ty = math.floor(candidate.output_position.x), math.floor(candidate.output_position.y)
  check(recipient.bounding_box.right_bottom.x > tx and recipient.bounding_box.left_top.x < tx + 1
    and recipient.bounding_box.right_bottom.y > ty and recipient.bounding_box.left_top.y < ty + 1,
    "every returned direction has an output tile colliding with the requested recipient")
  check(candidate.resource_coverage[1].name == "iron-ore"
    and candidate.resource_coverage[1].entity_count == 2
    and candidate.resource_coverage[1].total_amount == 950,
    "mining drill candidates expose deterministic resource coverage")
end
local real_vector = prototypes.item["burner-mining-drill"].place_result.vector_to_place_result
local real_recipient = { valid = true, name = "stone-furnace", type = "furnace", force = force,
  position = { x = 20, y = 20 },
  selection_box = { left_top = { x = 17.5, y = 18.5 }, right_bottom = { x = 22, y = 22.5 } },
  bounding_box = { left_top = { x = 19.3, y = 19.3 }, right_bottom = { x = 20.7, y = 20.7 } } }
prototypes.item["burner-mining-drill"].place_result.vector_to_place_result = { x = -0.5, y = -1.3 }
target_matches, resources = { real_recipient }, {
  { valid = true, name = "iron-ore", type = "resource", amount = 500, position = { x = 19, y = 22 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "iron-ore", type = "resource", amount = 500, position = { x = 17, y = 21 },
    prototype = { resource_category = "basic-solid" } },
}
only_position = { x = 19, y = 22 }
output_tile_override = {}
local false_north = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 19, y = 22 },
  radius = 1, directions = { 0 }, limit = 1, output_target = { x = 20, y = 20 } })
only_position = { x = 17, y = 21 }
local false_east = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 17, y = 21 },
  radius = 1, directions = { 4 }, limit = 1, output_target = { x = 20, y = 20 } })
check(#false_north.candidates == 0 and #false_east.candidates == 0,
  "drill targeting rejects both live-failure orientations whose endpoints only touch the furnace selection box")
local tile_overlap_recipient = { valid = true, name = "stone-furnace", type = "furnace", force = force,
  position = { x = 20, y = 20 },
  selection_box = { left_top = { x = 19.2, y = 19.2 }, right_bottom = { x = 20.8, y = 20.8 } },
  bounding_box = { left_top = { x = 18.8, y = 20.2 }, right_bottom = { x = 20.7, y = 20.7 } } }
target_matches, output_tile_override = { tile_overlap_recipient }, { tile_overlap_recipient }
only_position = { x = 19, y = 22 }
local tile_overlap = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 19, y = 22 },
  radius = 1, directions = { 0 }, limit = 1, output_target = { x = 20, y = 20 } })
check(tile_overlap.candidates[1]
  and tile_overlap.candidates[1].output_position.x == 18.5
  and tile_overlap.candidates[1].output_position.y == 20.7
  and tile_overlap.candidates[1].output_position.x < tile_overlap_recipient.bounding_box.left_top.x,
  "output tile overlap binds even when the exact output point lies outside the recipient collision box")
only_position = { x = 19, y = 22 }
output_tile_override = {}
local ground_output = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 19, y = 22 },
  radius = 1, directions = { 0 }, limit = 1 })
check(ground_output.candidates[1]
  and ground_output.candidates[1].output_position.x == 18.5
  and ground_output.candidates[1].output_position.y == 20.7
  and ground_output.candidates[1].output_target == false,
  "untargeted drill candidate exposes its exact endpoint and an explicit unbound recipient sentinel")
local overlapping_recipient = { valid = true, name = "wooden-chest", type = "container", force = force,
  position = { x = 18.5, y = 20.5 },
  selection_box = { left_top = { x = 18, y = 20 }, right_bottom = { x = 19, y = 21 } },
  bounding_box = { left_top = { x = 18.1, y = 20.1 }, right_bottom = { x = 18.9, y = 20.9 } } }
target_matches = { overlapping_recipient, { valid = true, name = "iron-chest", type = "container", force = force,
  position = overlapping_recipient.position, selection_box = overlapping_recipient.selection_box,
  bounding_box = overlapping_recipient.bounding_box } }
output_tile_override = target_matches
local ambiguous_output = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 19, y = 22 },
  radius = 1, directions = { 0 }, limit = 1 })
check(#ambiguous_output.candidates == 0,
  "multiple eligible output recipients are rejected rather than mislabeled as unbound ground output")
prototypes.item["burner-mining-drill"].place_result.vector_to_place_result = real_vector
only_position = nil
target_matches, resources, output_tile_override = { recipient }, ore, false
resources = {
  { valid = true, name = "iron-ore", type = "resource", amount = 500, position = { x = 8, y = 8 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "crude-oil", type = "resource", amount = 100000, position = { x = 8, y = 8 },
    prototype = { resource_category = "basic-fluid" } },
  { valid = true, name = "iron-ore", type = "resource", amount = 700, position = { x = 9.1, y = 8 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "mystery-resource", type = "resource", amount = 900, position = { x = 8, y = 8 },
    prototype = {} },
  { valid = true, name = "iron-ore", type = "resource", amount = 800, position = { x = "8", y = 8 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "iron-ore", type = "resource", amount = 600,
    prototype = { resource_category = "basic-solid" } },
}
local mixed_drill = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 8, y = 8 },
  radius = 1, directions = { 0 }, limit = 1 })
check(mixed_drill.candidates[1]
  and #mixed_drill.candidates[1].resource_coverage == 1
  and mixed_drill.candidates[1].resource_coverage[1].name == "iron-ore"
  and mixed_drill.candidates[1].resource_coverage[1].total_amount == 500,
  "mixed coverage excludes incompatible, unknown-category, malformed-position, and overlap-only resources")
resources = {
  { valid = true, name = "iron-ore", type = "resource", amount = 500, position = { x = 8, y = 8 },
    prototype = { resource_category = "basic-solid" } },
  { valid = true, name = "copper-ore", type = "resource", amount = 400, position = { x = 8, y = 8 },
    prototype = { resource_category = "basic-solid" } },
}
local lexical_drill = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 8, y = 8 },
  radius = 1, directions = { 0 }, limit = 1 })
check(lexical_drill.candidates[1].resource_coverage[1].name == "copper-ore"
  and lexical_drill.candidates[1].resource_coverage[2].name == "iron-ore",
  "compatible resource coverage keeps lexical presentation order")
resources = {}
local empty_drill = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 8, y = 8 },
  radius = 1, directions = { 0 }, limit = 1 })
check(#empty_drill.candidates == 0 and empty_drill.rejected_no_compatible_resource == 5,
  "fully charted empty coverage rejects candidates with a deterministic count")
resources = { { valid = true, name = "crude-oil", type = "resource", amount = 100000, position = { x = 8, y = 8 },
  prototype = { resource_category = "basic-fluid" } } }
local incompatible_drill = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 8, y = 8 },
  radius = 1, directions = { 0 }, limit = 1 })
check(#incompatible_drill.candidates == 0 and incompatible_drill.rejected_no_compatible_resource == 5,
  "fully charted incompatible-only coverage rejects candidates with a deterministic count")
resources = ore
local resource_calls_before_edge = resource_calls
local chart_edge_drill = finder.find_placement({ item = "electric-mining-drill", preferred = { x = 30.5, y = 1.5 },
  radius = 1, directions = { 8 }, limit = 1 })
check(chart_edge_drill.candidates[1] and chart_edge_drill.candidates[1].resource_coverage == nil
  and chart_edge_drill.rejected_no_compatible_resource == 0
  and resource_calls == resource_calls_before_edge,
  "drill candidates with uncharted coverage omit the field without a resource query")
target_matches = { pole }
local invalid, invalid_error = pcall(finder.find_placement, { item = "burner-mining-drill", preferred = { x = 4.5, y = 1.5 },
  radius = 2, directions = { 0 }, limit = 1, output_target = { x = 5.5, y = 1.5 } })
check(not invalid and tostring(invalid_error):match("cannot receive placed output") ~= nil,
  "output target rejects an invalid pole recipient")
target_matches = { recipient, pole }
local ambiguous, ambiguous_error = pcall(finder.find_placement, { item = "burner-mining-drill", preferred = { x = 4.5, y = 1.5 },
  radius = 2, directions = { 0 }, limit = 1, output_target = { x = 5.5, y = 1.5 } })
check(not ambiguous and tostring(ambiguous_error):match("ambiguous") ~= nil,
  "output target rejects every multiple match")
os.exit(failures == 0 and 0 or 1)
