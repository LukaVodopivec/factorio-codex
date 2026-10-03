local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local body
package.loaded["scripts.companion"] = {
  require_companion = function()
    if not (body and body.valid) then error("companion 'Codex' does not exist — call connect_status first") end
    return body
  end,
}

local entity = mock.entity({
  valid = true, name = "stone-furnace", type = "furnace", direction = 0,
  position = { x = 30, y = 0 }, electric_network_id = 17, energy = 2400,
  power_usage = 90, power_production = 0,
  burner = { remaining_burning_fuel = 1250, currently_burning = { name = { name = "coal", fuel_value = 4000 }, quality = { name = "normal" } } },
  prototype = { burner_prototype = { effectivity = 0.8 }, electric_energy_source_prototype = {
    buffer_capacity = 5000,
    get_input_flow_limit = function(quality) return quality and quality.name == "uncommon" and 156 or nil end,
    get_output_flow_limit = function(quality) return quality and quality.name == "uncommon" and 0 or nil end,
  } },
  quality = { name = "uncommon" },
})
local found_entity = entity
local inspection_queries = 0
local surface = {
  find_entities_filtered = function(filter)
    inspection_queries = inspection_queries + 1
    check(filter.position.x == found_entity.position.x and filter.position.y == found_entity.position.y,
      "inspection searches only the accepted target coordinate")
    return { found_entity }
  end,
}
entity.surface = surface
_G.defines = { inventory = { fuel = 1, chest = 1, furnace_source = 2, furnace_result = 3,
  assembling_machine_input = 4, assembling_machine_output = 5 }, entity_status = {} }
_G.game = { connected_players = { { surface = surface, position = { x = 1000, y = 1000 } } } }

local inspect = require("scripts.inspect")

body = nil
local pre_spawn, pre_spawn_error = pcall(inspect.inspect, {})
check(not pre_spawn and tostring(pre_spawn_error):match("does not exist") ~= nil,
  "pre-spawn inspection requires the Codex body before validating targets")

body = mock.entity({ valid = false, position = { x = 0, y = 0 }, surface = surface })
local dead, dead_error = pcall(inspect.inspect, { targets = { { x = 0, y = 0 } } })
check(not dead and tostring(dead_error):match("does not exist") ~= nil,
  "dead-body inspection cannot fall back to a connected player")

body = mock.entity({ valid = true, position = { x = 0, y = 0 }, surface = surface })
entity.position = { x = 30, y = 0 }
local at_limit, at_limit_result = pcall(inspect.inspect, { targets = { entity.position } })
check(at_limit and type(at_limit_result.entities) == "table"
  and at_limit_result.evidence_class == "fresh_local_exact"
  and at_limit_result.scope == "within_30_tiles_of_codex_at_source_tick"
  and at_limit_result.entities[1].name == "stone-furnace"
  and at_limit_result.entities[1].electrical.network_id == 17
  and at_limit_result.entities[1].electrical.energy == 2400
  and at_limit_result.entities[1].electrical.buffer_capacity == 5000
  and at_limit_result.entities[1].electrical.input_flow_limit == 156
  and at_limit_result.entities[1].electrical.output_flow_limit == 0
  and at_limit_result.entities[1].burner.remaining_burning_fuel == 1250
  and at_limit_result.entities[1].burner.currently_burning == "coal"
  and at_limit_result.entities[1].burner.current_fuel_value == 4000
  and at_limit_result.entities[1].burner.effectivity == 0.8
  and at_limit_result.name == nil and at_limit_result.position == nil,
  "batched inspection accepts an exact target and reports electrical network, energy, and limits")

local current_fuel = entity.burner.currently_burning
local function checks_unreadable_fuel(label, current, expected_name, expected_value)
  entity.burner.currently_burning = current
  local ok, result = pcall(inspect.inspect, { targets = { entity.position } })
  local facts = ok and result.entities[1].burner
  check(facts and facts.remaining_burning_fuel == 1250 and facts.effectivity == 0.8
    and facts.currently_burning == expected_name and facts.current_fuel_value == expected_value, label)
  entity.burner.currently_burning = current_fuel
end
checks_unreadable_fuel("missing current fuel preserves other burner facts", nil)
checks_unreadable_fuel("unreadable current item prototype preserves other burner facts",
  setmetatable({}, { __index = function() error("unreadable item prototype") end }))
checks_unreadable_fuel("unreadable item name cannot leak a prototype into inspection",
  { name = setmetatable({}, { __index = function() error("unreadable item name") end }) })
checks_unreadable_fuel("unreadable fuel value preserves the readable item name",
  { name = setmetatable({ name = "coal" }, { __index = function() error("unreadable fuel value") end }) }, "coal")
entity.burner.currently_burning = nil
mock.unreadable(entity.burner, "currently_burning")
checks_unreadable_fuel("unreadable current fuel preserves other burner facts", nil)
mock.unreadable(entity.burner, "currently_burning", false)
entity.burner.currently_burning = current_fuel

entity.position = { x = 30.000001, y = 0 }
local beyond = inspect.inspect({ targets = { entity.position } })
check(beyond.entities[1].error:match("within 30 tiles") ~= nil,
  "batched inspection rejects a target beyond 30 tiles by epsilon")

local batch = inspect.inspect({ targets = { { x = 0, y = 30.000001 } } })
check(batch.entities[1].error:match("within 30 tiles") ~= nil,
  "batched public inspection reports an over-range target as a physical rejection")

entity.position = { x = 1, y = 0 }
entity.valid = false
local absent = inspect.inspect({ targets = { entity.position } })
check(absent.entities[1].error:match("call observe_local first") ~= nil
  and absent.entities[1].error:match("look_around") == nil,
  "missing-entity guidance names only the public observe_local tool")
entity.valid = true

local pickup = mock.entity({ valid = true, name = "transport-belt", type = "transport-belt", position = { x = 0.5, y = -1.5 } })
local drop = mock.entity({ valid = true, name = "stone-furnace", type = "furnace", position = { x = 0.5, y = 1.5 } })
local inserter = mock.entity({
  valid = true, name = "burner-inserter", type = "inserter", direction = 0,
  position = { x = 0.5, y = 0.5 }, pickup_position = { x = 0.5, y = -0.7 },
  drop_position = { x = 0.5, y = 1.3 }, pickup_target = pickup, drop_target = drop,
  prototype = {},
})
found_entity = inserter
local inserter_result = inspect.inspect({ targets = { inserter.position } }).entities[1]
check(inserter_result.pickup_position.x == 0.5 and inserter_result.pickup_position.y == -0.7
  and inserter_result.drop_position.x == 0.5 and inserter_result.drop_position.y == 1.3
  and inserter_result.pickup_target.name == "transport-belt"
  and inserter_result.pickup_target.type == "transport-belt"
  and inserter_result.pickup_target.position.y == -1.5
  and inserter_result.drop_target.name == "stone-furnace"
  and inserter_result.drop_target.position.y == 1.5,
  "inserter inspection reports exact runtime endpoints and valid target identities")

inserter.pickup_target = mock.entity({ valid = false })
inserter.drop_target = nil
local no_targets = inspect.inspect({ targets = { inserter.position } }).entities[1]
check(no_targets.pickup_target == nil and no_targets.drop_target == nil,
  "inserter inspection omits invalid and absent targets")

local connected_pipe = mock.entity({ valid = true, name = "pipe", type = "pipe", position = { x = 2, y = 1 } })
local fluidbox = { [1] = {} }
fluidbox.get_pipe_connections = function(index)
  check(index == 1, "fluid endpoint inspection requests the exact fluidbox index")
  return { { position = { x = 1, y = 0.5 }, target_position = { x = 1.5, y = 0.5 }, connection_type = "normal",
    flow_direction = "input-output", target = mock.fluidbox({ owner = connected_pipe }) } }
end
fluidbox.get_prototype = function(index)
  return { index = index, production_type = "output", filter = { name = "water" } }
end
local pump = mock.entity({ valid = true, name = "offshore-pump", type = "offshore-pump", direction = 4,
  position = { x = 1, y = 1 }, prototype = {}, fluidbox = fluidbox })
found_entity = pump
local pump_result = inspect.inspect({ targets = { pump.position } }).entities[1]
check(pump_result.fluid_connections[1]
  and pump_result.fluid_connections[1].position.x == 1
  and pump_result.fluid_connections[1].position.y == 0.5
  and pump_result.fluid_connections[1].target_position.x == 1.5
  and pump_result.fluid_connections[1].target_position.y == 0.5
  and pump_result.fluid_connections[1].production_type == "output"
  and pump_result.fluid_connections[1].filter == "water"
  and pump_result.fluid_connections[1].connected_target.name == "pipe",
  "entity inspection exposes live fluid endpoints and their connected target")
local native_prototype = fluidbox.get_prototype
for _, unreadable in ipairs({
  function(index) return { native_prototype(index), native_prototype(index) } end,
  function() error("unreadable native prototype") end,
}) do
  fluidbox.get_prototype = unreadable
  local endpoint = inspect.inspect({ targets = { pump.position } }).entities[1].fluid_connections[1]
  check(endpoint and endpoint.position.x == 1 and endpoint.filter == nil and endpoint.production_type == nil,
    "unproven native prototype preserves observed endpoint geometry without inventing filter or direction")
end
fluidbox.get_prototype = native_prototype

local ore = mock.entity({ valid = true, name = "iron-ore", type = "resource", position = { x = 2.25, y = 0.25 }, amount = 873 })
local drill = mock.entity({
  valid = true, name = "burner-mining-drill", type = "mining-drill", direction = 4,
  position = { x = 2, y = 0 }, mining_target = ore,
  drop_position = { x = 3.3, y = -0.5 }, drop_target = drop, prototype = {},
})
found_entity = drill
local drill_result = inspect.inspect({ targets = { drill.position } }).entities[1]
check(drill_result.mining_target.name == "iron-ore"
  and drill_result.mining_target.type == "resource"
  and drill_result.mining_target.position.x == 2.25
  and drill_result.mining_target.amount == 873
  and drill_result.drop_position.x == 3.3 and drill_result.drop_position.y == -0.5
  and drill_result.drop_target.name == "stone-furnace"
  and drill_result.drop_target_bound == true,
  "mining drill inspection reports its runtime output endpoint, recipient, and valid current resource target")

drill.drop_target = nil
local unbound_drill = inspect.inspect({ targets = { drill.position } }).entities[1]
check(unbound_drill.drop_position.x == 3.3 and unbound_drill.drop_target == false
  and unbound_drill.drop_target_bound == false,
  "mining drill inspection preserves the endpoint and explicit unbound recipient sentinel")

drill.drop_target = mock.entity({ valid = false })
local invalid_recipient_drill = inspect.inspect({ targets = { drill.position } }).entities[1]
check(invalid_recipient_drill.drop_target == false
  and invalid_recipient_drill.drop_target_bound == false
  and type(invalid_recipient_drill.drop_target) ~= "table",
  "an invalid drill recipient is explicitly unbound and never encoded as an empty object")

drill.mining_target = mock.entity({ valid = false })
local no_mining_target = inspect.inspect({ targets = { drill.position } }).entities[1]
check(no_mining_target.mining_target == nil, "mining drill inspection omits an invalid resource target")

local belt = mock.entity({
  valid = true, name = "transport-belt", type = "transport-belt", direction = 4,
  position = { x = 3.5, y = 0.5 }, prototype = {},
  get_max_transport_line_index = function() return 2 end,
  get_transport_line = function(index)
    return { get_contents = function()
      if index == 1 then return { { name = "iron-ore", count = 3 } } end
      return { ["iron-ore"] = 2, ["coal"] = 1 }
    end }
  end,
})
found_entity = belt
local belt_result = inspect.inspect({ targets = { belt.position } }).entities[1]
check(belt_result.belt_contents["iron-ore"] == 5 and belt_result.belt_contents.coal == 1,
  "belt inspection retains contents from every transport line")

found_entity = entity
entity.type = "furnace"
entity.burner = { remaining_burning_fuel = 0 }
entity.get_inventory = function(index)
  local contents = index == defines.inventory.fuel and { { name = "coal", count = 1 } } or {}
  return { is_empty = function() return #contents == 0 end, get_contents = function() return contents end }
end
local furnace_buffers = inspect.inspect({ targets = { entity.position } }).entities[1].inventories
check(furnace_buffers.fuel.coal == 1 and next(furnace_buffers.input) == nil and next(furnace_buffers.output) == nil,
  "furnace inspection exposes fuel, input, and output buffers even when relevant compartments are empty")

entity.burner = nil
local probed = {}
entity.get_inventory = function(index)
  probed[#probed + 1] = index
  if index == defines.inventory.furnace_source or index == defines.inventory.furnace_result then
    return { is_empty = function() return true end, get_contents = function() return {} end }
  end
  return nil
end
local electric_buffers = inspect.inspect({ targets = { entity.position } }).entities[1].inventories
check(electric_buffers.fuel == nil and next(electric_buffers.input) == nil and next(electric_buffers.output) == nil
  and #probed == 2 and probed[1] == defines.inventory.furnace_source
  and probed[2] == defines.inventory.furnace_result,
  "furnace inspection exposes only inventory compartments that actually exist")

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

mock.assert_clean()
os.exit(failures == 0 and 0 or 1)
