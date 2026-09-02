local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local body
package.loaded["scripts.companion"] = {
  require_companion = function()
    if not (body and body.valid) then error("companion 'Codex' does not exist — call spawn_companion first") end
    return body
  end,
}

local entity = { valid = true, name = "stone-furnace", type = "furnace", direction = 0, position = { x = 30, y = 0 } }
local inspection_queries = 0
local surface = {
  find_entities_filtered = function(filter)
    inspection_queries = inspection_queries + 1
    check(filter.position.x == entity.position.x and filter.position.y == entity.position.y,
      "inspection searches only the accepted target coordinate")
    return { entity }
  end,
}
entity.surface = surface
_G.defines = { inventory = {}, entity_status = {} }
_G.game = { connected_players = { { surface = surface, position = { x = 1000, y = 1000 } } } }

local inspect = require("scripts.inspect")

body = nil
local pre_spawn, pre_spawn_error = pcall(inspect.inspect, {})
check(not pre_spawn and tostring(pre_spawn_error):match("does not exist") ~= nil,
  "pre-spawn inspection requires the Codex body before validating targets")

body = { valid = false, position = { x = 0, y = 0 }, surface = surface }
local dead, dead_error = pcall(inspect.inspect, { targets = { { x = 0, y = 0 } } })
check(not dead and tostring(dead_error):match("does not exist") ~= nil,
  "dead-body inspection cannot fall back to a connected player")

body = { valid = true, position = { x = 0, y = 0 }, surface = surface }
entity.position = { x = 30, y = 0 }
local at_limit, at_limit_result = pcall(inspect.inspect, { targets = { entity.position } })
check(at_limit and at_limit_result.entities[1].name == "stone-furnace",
  "batched inspection accepts an exact 30.0-tile target")

entity.position = { x = 30.000001, y = 0 }
local beyond = inspect.inspect({ targets = { entity.position } })
check(beyond.entities[1].error:match("within 30 tiles") ~= nil,
  "batched inspection rejects a target beyond 30 tiles by epsilon")

local batch = inspect.inspect({ targets = { { x = 0, y = 30.000001 } } })
check(batch.entities[1].error:match("within 30 tiles") ~= nil,
  "batched public inspection reports an over-range target as a physical rejection")

local queries_before_single = inspection_queries
local single, single_error = pcall(inspect.inspect, { position = { x = 0, y = 0 } })
check(not single and tostring(single_error):match("targets must be a non%-empty array") ~= nil
  and inspection_queries == queries_before_single,
  "removed single-target inspection shape is rejected before a surface query")

local empty, empty_error = pcall(inspect.inspect, { targets = {} })
check(not empty and tostring(empty_error):match("targets must be a non%-empty array") ~= nil,
  "inspection rejects an empty targets array")

local too_many = {}
for i = 1, 17 do too_many[i] = { x = 0, y = 0 } end
local oversized, oversized_error = pcall(inspect.inspect, { targets = too_many })
check(not oversized and tostring(oversized_error):match("at most 16 targets") ~= nil,
  "inspection rejects more than 16 targets")

os.exit(failures == 0 and 0 or 1)
