-- can_place reports where each planned output and pickup lands, inside the
-- batch or on an existing entity, without reading beyond Codex's 30-tile range.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local HALF = 179 / 256
local function box(half) return { left_top = { x = -half, y = -half }, right_bottom = { x = half, y = half } } end
_G.defines = { build_check_type = { manual = 1 } }
_G.prototypes = { item = {
  ["burner-mining-drill"] = { place_result = { name = "burner-mining-drill", type = "mining-drill", tile_width = 2, tile_height = 2,
    vector_to_place_result = { x = -0.5, y = -1.3 }, collision_box = box(HALF) } },
  ["stone-furnace"] = { place_result = { name = "stone-furnace", type = "furnace", tile_width = 2, tile_height = 2, collision_box = box(HALF) } },
  ["burner-inserter"] = { place_result = { name = "burner-inserter", type = "inserter", tile_width = 1, tile_height = 1,
    inserter_pickup_position = { 0, -1 }, inserter_drop_position = { 0, 1.2 }, collision_box = box(0.15) } },
}, entity = {} }

local geometry = require("scripts.placement_geometry")
local force = { is_chunk_charted = function() return true end }
local chest = { valid = true, name = "wooden-chest", type = "container", force = force,
  position = { x = 40.5, y = -50.5 }, bounding_box = { left_top = { x = 40.15, y = -50.85 }, right_bottom = { x = 40.85, y = -50.15 } } }
local lookups = 0
local surface = {
  can_place_entity = function() return true end,
  find_entities_filtered = function(args)
    lookups = lookups + 1
    local a = args.area
    if a and chest.bounding_box.left_top.x < a.right_bottom.x and chest.bounding_box.right_bottom.x > a.left_top.x
      and chest.bounding_box.left_top.y < a.right_bottom.y and chest.bounding_box.right_bottom.y > a.left_top.y then
      return { chest }
    end
    return {}
  end,
}
local body = { valid = true, position = { x = 40, y = -40 }, surface = surface, force = force, name = "character" }
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
dofile(here .. "/body_stub.lua")(package.loaded["scripts.companion"], function() return body end)
package.loaded["scripts.tasks"] = { active_summary = function() return nil end }
local spatial = require("scripts.spatial")

local result = spatial.can_place({ placements = {
  { item = "stone-furnace", position = { x = 45, y = -30 } },
  { item = "burner-mining-drill", position = { x = 45, y = -32 }, direction = 8 },
  { item = "stone-furnace", position = { x = 45.5, y = -30.5 } },
  { item = "burner-inserter", position = { x = 40.5, y = -49.5 }, direction = 0 },
} }).results
check(result[2].output_lands_on and result[2].output_lands_on.state == "ambiguous",
  "overlapping planned recipient boxes are ambiguous instead of selecting the first")
local unique = spatial.can_place({ placements = {
  { item = "stone-furnace", position = { x = 45, y = -30 } },
  { item = "burner-mining-drill", position = { x = 45, y = -32 }, direction = 8 },
} }).results
check(unique[2].output_lands_on and unique[2].output_lands_on.batch_index == 0,
  "a unique planned drill output lands on the earlier furnace")
local overlaps = result[1].overlaps_batch or {}
check(#overlaps == 1 and overlaps[1] == 2, "two planned furnaces on overlapping footprints report each other")
check(result[4].pickup_from and result[4].pickup_from.name == "wooden-chest",
  "an inserter pickup on an existing chest names that chest")
check(result[1].output_lands_on == nil and result[1].pickup_from == nil,
  "entities without endpoints carry no endpoint fields")

body.position = { x = 40, y = -40 }
local far = spatial.can_place({ placements = {
  { item = "burner-inserter", position = { x = 40.5, y = -49.5 }, direction = 8 },
} }).results[1]
check(far.drop_position == nil and far.output_lands_on ~= nil, "nearby endpoints are resolved")
body.position = { x = 40, y = -40 }
local before = lookups
local remote = spatial.can_place({ placements = {
  { item = "burner-inserter", position = { x = 40.5, y = -80.5 }, direction = 8 },
} }).results[1]
check(remote.pickup_from and remote.pickup_from.state == "out_of_range"
  and remote.output_lands_on and remote.output_lands_on.state == "out_of_range",
  "endpoints beyond 30 tiles of Codex are reported as out of range, not resolved")
check(lookups - before <= 1, "out-of-range endpoints do not query entities")
local clear = spatial.can_place({ placements = {
  { item = "burner-inserter", position = { x = 50.5, y = -45.5 }, direction = 0 },
} }).results[1]
check(clear.output_lands_on == false and clear.pickup_from == false, "endpoints with nothing there are false (null over MCP)")
check(geometry.NON_BLOCKING_TYPES.fish and geometry.NON_BLOCKING_TYPES["item-entity"] and not geometry.NON_BLOCKING_TYPES.container,
  "placement tools share one list of entity types that never block building")

body.position = { x = 0.5, y = 0.5 }
for _, direction in ipairs({ 0, 4, 8, 12 }) do
  local proto = prototypes.item["burner-inserter"].place_result
  local resolver = require("scripts.output_target")
  local point = resolver.output_position(proto, body.position, direction)
  local target = { x = math.floor(point.x) + 0.5, y = math.floor(point.y) + 0.5 }
  local rows = spatial.can_place({ placements = {
    { item = "burner-inserter", position = target },
    { item = "burner-inserter", position = body.position, direction = direction },
  } }).results
  check(rows[2].output_lands_on and rows[2].output_lands_on.batch_index == 0,
    "batch resolves narrow planned fuel recipient facing " .. direction)
  local ambiguous = spatial.can_place({ placements = {
    { item = "burner-inserter", position = target },
    { item = "burner-inserter", position = target },
    { item = "burner-inserter", position = body.position, direction = direction },
  } }).results
  check(ambiguous[3].output_lands_on and ambiguous[3].output_lands_on.state == "ambiguous",
    "batch never chooses the first of ambiguous narrow fuel recipients facing " .. direction)
end

local range_edge = spatial.can_place({ placements = {
  { item = "burner-inserter", position = { x = 30.75, y = 0.5 } },
  { item = "burner-inserter", position = { x = 29, y = 0.5 }, direction = 12 },
} }).results
check(range_edge[1].can_place and range_edge[2].output_lands_on and range_edge[2].output_lands_on.batch_index == 0,
  "a planned recipient beyond 30 tiles of Codex still resolves: can_place works anywhere charted")
force.is_chunk_charted = function(_, chunk) return chunk.x == 0 end
local chart_edge = spatial.can_place({ placements = {
  { item = "burner-inserter", position = { x = -0.05, y = 0.5 } },
  { item = "burner-inserter", position = { x = -0.5, y = 0.5 }, direction = 12 },
} }).results
check(chart_edge[2].output_lands_on == false,
  "planned recipient centre in an uncharted adjacent chunk remains omitted")
force.is_chunk_charted = function() return true end

if failures > 0 then error(failures .. " can_place relation checks failed") end
