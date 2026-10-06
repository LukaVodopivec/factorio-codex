-- Offline test: a pipe the game refuses because it would join two fluids
-- says so, naming them, instead of naming a neighbouring pipe as in the way.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.defines = { build_check_type = { manual = 0, ghost_revive = 1 }, direction = { north = 0 } }
local pipe = { name = "pipe", type = "pipe", fluidbox_prototypes = { {} },
  collision_box = { left_top = { x = -0.29, y = -0.29 }, right_bottom = { x = 0.29, y = 0.29 } } }
local chest = { name = "wooden-chest", type = "container",
  collision_box = { left_top = { x = -0.35, y = -0.35 }, right_bottom = { x = 0.35, y = 0.35 } } }
_G.prototypes = { item = { pipe = { place_result = pipe } }, entity = { pipe = pipe, character = { collision_mask = {} } } }

-- A pipe at x with one fluid, whose connections point east and west.
local function pipe_at(x, y, fluid)
  local box = { { name = fluid } }
  box.get_pipe_connections = function()
    return { { connection_type = "normal", target_position = { x = x - 1, y = y } },
      { connection_type = "normal", target_position = { x = x + 1, y = y } } }
  end
  return { valid = true, name = "pipe", type = "pipe", position = { x = x, y = y }, fluidbox = box }
end
local world = { pipe_at(116.5, -90.5, "water"), pipe_at(118.5, -90.5, "sulfuric-acid") }
local surface = {
  find_entities_filtered = function() return world end,
  can_place_entity = function() return false end,
  get_tile = function() return { name = "grass-1", collides_with = function() return false end } end,
}

local geometry = require("scripts.placement_geometry")
local mix = geometry.fluid_mix(surface, pipe, { x = 117.5, y = -90.5 }, 0)
check(mix and mix[1] == "sulfuric-acid" and mix[2] == "water", "a pipe between water and acid would join both fluids")
check(geometry.fluid_mix(surface, pipe, { x = 114.5, y = -90.5 }, 0) == nil,
  "a pipe no neighbour connects to joins nothing")
check(geometry.fluid_mix(surface, chest, { x = 117.5, y = -90.5 }, 0) == nil, "a building without fluid boxes never mixes")
local tank = { name = "storage-tank", type = "storage-tank", fluidbox_prototypes = { {} }, collision_box = pipe.collision_box }
check(geometry.fluid_mix(surface, tank, { x = 117.5, y = -90.5 }, 0) == nil,
  "only a plain pipe connects on every side; other fluid entities are not judged")
local connected = pipe_at(118.5, -90.5, "sulfuric-acid")
connected.fluidbox.get_pipe_connections = function()
  return { { connection_type = "normal", target_position = { x = 117.5, y = -90.5 }, target = {} },
    { connection_type = "underground", target_position = { x = 117.5, y = -90.5 } } }
end
world[2] = connected
check(geometry.fluid_mix(surface, pipe, { x = 117.5, y = -90.5 }, 0) == nil,
  "connections already joined, or underground, are not ones the new pipe would join")
world[2] = pipe_at(118.5, -90.5, "sulfuric-acid")
world[2] = pipe_at(118.5, -90.5, "water")
check(geometry.fluid_mix(surface, pipe, { x = 117.5, y = -90.5 }, 0) == nil, "joining one fluid twice is not mixing")
world[2] = pipe_at(118.5, -90.5, "sulfuric-acid")

local body = { valid = true, name = "character", position = { x = 110, y = -90.5 }, surface = surface, force = {} }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
local build = require("scripts.actions.build")
local why = build.blocked_reason(body, { x = 117.5, y = -90.5 }, pipe, 0)
check(why:match("would join sulfuric%-acid and water pipes") ~= nil and not why:match("in the way"),
  "the refusal names the two fluids, not a neighbouring pipe")
os.exit(failures == 0 and 0 or 1)
