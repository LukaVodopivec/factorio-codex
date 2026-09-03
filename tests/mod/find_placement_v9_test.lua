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
local surface = {
  can_place_entity = function(args) placement_calls = placement_calls + 1; return args.position.x ~= 3.5 end,
  get_tile = function(x) return { collides_with = function(layer) return (layer == "water_tile" or layer == "player") and x >= 2 end } end,
}
local recipient = { valid = true, name = "stone-furnace", type = "furnace", force = force,
  position = { x = 5.5, y = 1.5 }, unit_number = 9,
  selection_box = { left_top = { x = 5, y = 1 }, right_bottom = { x = 6, y = 2 } } }
local pole = { valid = true, name = "small-electric-pole", type = "electric-pole", force = force,
  position = { x = 5.5, y = 1.5 }, selection_box = recipient.selection_box }
local source = { valid = true, name = "wooden-chest", type = "container", force = force,
  position = { x = 1.5, y = 0.5 },
  selection_box = { left_top = { x = 1, y = 0 }, right_bottom = { x = 2, y = 1 } } }
local sink = { valid = true, name = "iron-chest", type = "container", force = force,
  position = { x = 1.5, y = 2.5 },
  selection_box = { left_top = { x = 1, y = 2 }, right_bottom = { x = 2, y = 3 } } }
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
surface.find_entities_filtered = function(args)
  if args.type == "resource" then resource_calls = resource_calls + 1; return resources end
  local x, y = args.area[1][1], args.area[1][2]
  if x == 1.5 and y == 0.5 then return { source } end
  if x == 1.5 and y == 2.5 then return { sink } end
  return target_matches
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
    mining_drill_radius = 2, resource_categories = { ["basic-solid"] = true },
    collision_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } } } },
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
check(diagonal_inserter.candidates[1].pickup_position == nil and diagonal_inserter.candidates[1].drop_position == nil,
  "non-cardinal inserter placements omit endpoint claims")
local aligned = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 4.5, y = 1.5 }, radius = 2,
  directions = { 12, 8, 4, 0 }, limit = 8, output_target = { x = 5.5, y = 1.5 } })
check(aligned.output_target.name == "stone-furnace" and #aligned.candidates > 0,
  "output target resolves one exact player-owned recipient")
for _, candidate in ipairs(aligned.candidates) do
  check(candidate.output_position.x >= 5 and candidate.output_position.x < 6
    and candidate.output_position.y >= 1 and candidate.output_position.y < 2,
    "every returned direction deposits inside the requested recipient")
  check(candidate.resource_coverage[1].name == "iron-ore"
    and candidate.resource_coverage[1].entity_count == 2
    and candidate.resource_coverage[1].total_amount == 950,
    "mining drill candidates expose deterministic resource coverage")
end
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
  radius = 1, directions = { 0 }, limit = 1 })
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
