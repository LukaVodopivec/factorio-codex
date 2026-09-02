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
surface.find_entities_filtered = function() return { recipient } end
local body = { position = { x = 1.5, y = 1.5 }, force = force, surface = surface }
package.loaded["scripts.companion"] = { require_companion = function() return body end }
_G.defines = { build_check_type = { manual = 1 } }
_G.prototypes = { item = {
  pipe = { place_result = { name = "pipe", type = "pipe", tile_width = 1, tile_height = 1, collision_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } } } },
  ["offshore-pump"] = { place_result = { name = "offshore-pump", type = "offshore-pump", tile_width = 1, tile_height = 1, collision_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } } } },
  ["burner-mining-drill"] = { place_result = { name = "burner-mining-drill", type = "mining-drill", tile_width = 2, tile_height = 2,
    vector_to_place_result = { x = 1, y = 0 }, collision_box = { left_top = { x = -0.9, y = -0.9 }, right_bottom = { x = 0.9, y = 0.9 } } } },
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
local aligned = finder.find_placement({ item = "burner-mining-drill", preferred = { x = 4.5, y = 1.5 }, radius = 2,
  directions = { 12, 8, 4, 0 }, limit = 8, output_target = { x = 5.5, y = 1.5 } })
check(aligned.output_target.name == "stone-furnace" and #aligned.candidates > 0,
  "output target resolves one exact player-owned recipient")
for _, candidate in ipairs(aligned.candidates) do
  check(candidate.output_position.x >= 5 and candidate.output_position.x < 6
    and candidate.output_position.y >= 1 and candidate.output_position.y < 2,
    "every returned direction deposits inside the requested recipient")
end
os.exit(failures == 0 and 0 or 1)
