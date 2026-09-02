local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local resources = {
  { valid = true, name = "iron-ore", type = "resource", amount = 20, position = { x = 8, y = 1 } },
  { valid = true, name = "iron-ore", type = "resource", amount = 10, position = { x = 3, y = 1 } },
  { valid = true, name = "copper-ore", type = "resource", amount = 999, position = { x = 33, y = 1 } },
}
local force = {
  get_charted_chunks = function() local done = false; return function() if done then return nil end; done = true; return { x = 0, y = 0 } end end,
  is_chunk_charted = function(_, chunk) return chunk.x == 0 and chunk.y == 0 end,
}
local machine = { valid = true, name = "assembling-machine-1", type = "assembling-machine", position = { x = 5, y = 5 }, direction = 4, status = 1, get_recipe = function() return { name = "gear" } end }
local body = { position = { x = 0, y = 0 }, force = force }
local surface = {
  get_tile = function(x) return { collides_with = function(layer) return (layer == "water_tile" or layer == "player") and x >= 16 end } end,
  find_entities_filtered = function(filter) if filter.type == "resource" then return resources end; return { machine, body } end,
}
body.surface = surface
package.loaded["scripts.companion"] = { require_companion = function() return body end }
_G.game = { tick = 777 }
_G.defines = { entity_status = { no_power = 1 } }
local summary = require("scripts.map_summary").map_summary({})
check(summary.tick == 777 and summary.charted_chunks == 1, "map summary carries source tick and charted chunk count")
check(#summary.resources == 1 and summary.resources[1].total_amount == 30 and summary.resources[1].nearest.x == 3,
  "resource totals and nearest target are deterministic and exclude uncharted entity centers")
check(#summary.water_edges > 0 and summary.water_edges[1].land.x == 15 and summary.water_edges[1].water.x == 16,
  "water edge samples stay inside charted terrain")
check(#summary.factory_landmarks == 1 and summary.factory_landmarks[1].status == "no_power"
  and summary.factory_landmarks[1].recipe == "gear" and summary.factory_landmarks[1].observed_tick == 777,
  "factory landmarks include machine facts and observation ticks without characters or ghosts")
check(force.chart == nil and surface.request_to_generate_chunks == nil, "summary exposes no terrain generation path")
os.exit(failures == 0 and 0 or 1)
