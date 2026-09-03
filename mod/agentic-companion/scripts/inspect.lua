-- inspect: detailed view of an entity at an exact local map position
-- (1.5-tile search, non-characters preferred).
local companion = require("scripts.companion")
local fluid_connections = require("scripts.fluid_connections")

local M = {}

local SEARCH_RADIUS = 1.5

local function round1(v)
  return math.floor(v * 10 + 0.5) / 10
end

local function round2(v)
  return math.floor(v * 100 + 0.5) / 100
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function entity_identity(entity)
  local ok, identity = pcall(function()
    if not entity or not entity.valid then return nil end
    return {
      name = entity.name,
      type = entity.type,
      position = { x = entity.position.x, y = entity.position.y },
    }
  end)
  if ok then return identity end
  return nil
end

-- Probe order matters: several defines.inventory values share the same numeric
-- index across entity types (e.g. fuel and chest), so each index is probed
-- once. The fuel slot is relabeled "main" when the entity has no burner.
local INVENTORY_PROBES = {
  { "fuel", "fuel" },
  { "chest", "main" },
  { "furnace_source", "input" },
  { "furnace_result", "output" },
  { "assembling_machine_input", "input" },
  { "assembling_machine_output", "output" },
}

local function collect_inventories(entity)
  local ok_burner, burner = pcall(function() return entity.burner end)
  local has_burner = ok_burner and burner ~= nil

  local function contents(inv)
    local bucket = {}
    for _, item in ipairs(inv.get_contents()) do
      bucket[item.name] = (bucket[item.name] or 0) + item.count
    end
    return bucket
  end

  -- A furnace's three buffers are gameplay evidence in their own right. Probe
  -- the exact furnace inventory IDs rather than the generic alias order, and
  -- expose an empty bucket only when Factorio says that compartment exists.
  if entity.type == "furnace" then
    local result, found = {}, false
    local probes = {}
    if has_burner then probes[#probes + 1] = { defines.inventory.fuel, "fuel" } end
    probes[#probes + 1] = { defines.inventory.furnace_source, "input" }
    probes[#probes + 1] = { defines.inventory.furnace_result, "output" }
    for _, probe in ipairs(probes) do
      if probe[1] then
        local ok, inv = pcall(entity.get_inventory, probe[1])
        if ok and inv then
          result[probe[2]] = contents(inv)
          found = true
        end
      end
    end
    if found then return result end
    return nil
  end

  local result = {}
  local seen = {}
  local found = false
  for _, probe in ipairs(INVENTORY_PROBES) do
    local index = defines.inventory[probe[1]]
    if index and not seen[index] then
      seen[index] = true
      local ok, inv = pcall(entity.get_inventory, index)
      if ok and inv then
        local label = probe[2]
        if probe[1] == "fuel" and not has_burner then label = "main" end
        if not inv.is_empty() then
          local bucket = result[label] or {}
          result[label] = bucket
          for _, item in ipairs(inv.get_contents()) do
            bucket[item.name] = (bucket[item.name] or 0) + item.count
          end
          found = true
        end
      end
    end
  end
  if found then return result end
  return nil
end

-- Items sitting on belt-like entities. Transport line contents come back as
-- an array of {name, count, quality} in 2.x (dict in older styles) — handle both.
local BELT_TYPES = {
  ["transport-belt"] = true,
  ["underground-belt"] = true,
  ["splitter"] = true,
  ["loader"] = true,
  ["loader-1x1"] = true,
  ["linked-belt"] = true,
}

local function collect_belt_contents(e)
  if not BELT_TYPES[e.type] then return nil end
  local totals = {}
  local found = false
  local max_index = 2
  pcall(function() max_index = e.get_max_transport_line_index() end)
  for i = 1, max_index do
    local ok, line = pcall(e.get_transport_line, i)
    if ok and line then
      local ok2, contents = pcall(line.get_contents)
      if ok2 and type(contents) == "table" then
        for k, v in pairs(contents) do
          if type(v) == "table" and v.name then
            totals[v.name] = (totals[v.name] or 0) + (v.count or 0)
            found = true
          elseif type(v) == "number" then
            totals[k] = (totals[k] or 0) + v
            found = true
          end
        end
      end
    end
  end
  if found then return totals end
  return nil
end

-- Fluids in pipes, tanks, boilers, engines, crafting machines with fluid boxes.
local function collect_fluids(e, out)
  -- Integer amounts: x.1 fluid precision isn't useful to an LLM, and rounded
  -- decimals serialize as long floats (87.299999…) in JSON.
  local fluids = nil
  local ok, contents = pcall(e.get_fluid_contents)
  if ok and type(contents) == "table" and next(contents) ~= nil then
    fluids = {}
    for name, amount in pairs(contents) do
      fluids[name] = math.floor(amount + 0.5)
    end
  end
  if not fluids then
    local count = 0
    pcall(function() count = #e.fluidbox end)
    if count > 0 then
      for i = 1, count do
        local ok2, f = pcall(function() return e.fluidbox[i] end)
        if ok2 and f and f.name then
          fluids = fluids or {}
          fluids[f.name] = math.floor((fluids[f.name] or 0) + f.amount + 0.5)
        end
      end
      if not fluids then
        out.no_fluids = true -- has a fluid system, but it's dry
      end
    end
  end
  if fluids then out.fluids = fluids end
end

local function locate(pos, c)
  if type(pos) ~= "table" or tonumber(pos.x) == nil or tonumber(pos.y) == nil then
    error("inspect targets must contain {x, y}")
  end
  local target = { x = tonumber(pos.x), y = tonumber(pos.y) }

  if distance(c.position, target) > 30 then error("inspect positions must be within 30 tiles of Codex") end
  local surface = c.surface

  -- Preference order: buildings/machines > resources > characters. A chest
  -- standing on an ore tile must resolve to the chest, not the ore under it.
  local best, best_d = nil, math.huge
  local best_res, best_res_d = nil, math.huge
  local best_char, best_char_d = nil, math.huge
  for _, e in ipairs(surface.find_entities_filtered({ position = target, radius = SEARCH_RADIUS })) do
    if e.valid then
      local d = distance(e.position, target)
      if e.type == "character" then
        if d < best_char_d then best_char, best_char_d = e, d end
      elseif e.type == "resource" then
        if d < best_res_d then best_res, best_res_d = e, d end
      elseif d < best_d then
        best, best_d = e, d
      end
    end
  end
  local entity = best or best_res or best_char
  if not entity then
    error(string.format(
      "nothing to inspect within %.1f tiles of (%.1f, %.1f) — check the position or call observe_local first",
      SEARCH_RADIUS, target.x, target.y))
  end
  return entity
end

local function inspect_one(position, c)
  local e = locate(position, c)

  local out = {
    name = e.name,
    type = e.type,
    position = { x = round1(e.position.x), y = round1(e.position.y) },
    direction = e.direction,
  }

  local ok, health = pcall(function() return e.health end)
  if ok and health then out.health = round1(health) end

  -- entity.status can throw or be nil on some types
  local ok_status, status = pcall(function() return e.status end)
  if ok_status and status ~= nil then
    for name, value in pairs(defines.entity_status) do
      if value == status then
        out.status = name
        break
      end
    end
  end

  local ok_recipe, recipe = pcall(e.get_recipe)
  if ok_recipe and recipe then out.recipe = recipe.name end

  local ok_progress, progress = pcall(function() return e.crafting_progress end)
  if ok_progress and type(progress) == "number" then
    out.crafting_progress = round2(progress)
  end

  local ok_energy, energy = pcall(function() return e.energy end)
  if ok_energy and type(energy) == "number" and energy > 0 then
    out.energy = math.floor(energy)
  end

  local ok_burner, burner = pcall(function() return e.burner end)
  if ok_burner and burner then
    local facts = {}
    local ok_remaining, remaining = pcall(function() return burner.remaining_burning_fuel end)
    if ok_remaining and type(remaining) == "number" then facts.remaining_burning_fuel = remaining end
    local ok_current, current = pcall(function() return burner.currently_burning end)
    if ok_current and current then
      facts.currently_burning = current.name
      local ok_value, value = pcall(function() return current.fuel_value end)
      if ok_value and type(value) == "number" then facts.current_fuel_value = value end
    end
    local ok_effectivity, effectivity = pcall(function() return e.prototype.burner_prototype.effectivity end)
    if ok_effectivity and type(effectivity) == "number" then facts.effectivity = effectivity end
    if next(facts) ~= nil then out.burner = facts end
  end

  local electrical = {}
  local function electrical_number(key, read)
    local ok, value = pcall(read)
    if ok and type(value) == "number" then electrical[key] = value end
  end
  electrical_number("network_id", function() return e.electric_network_id end)
  electrical_number("energy", function() return e.energy end)
  electrical_number("power_usage", function() return e.power_usage end)
  electrical_number("power_production", function() return e.power_production end)
  local ok_source, source = pcall(function() return e.prototype.electric_energy_source_prototype end)
  if ok_source and source then
    electrical_number("buffer_capacity", function() return source.buffer_capacity end)
    electrical_number("input_flow_limit", function() return source.input_flow_limit end)
    electrical_number("output_flow_limit", function() return source.output_flow_limit end)
  end
  if next(electrical) ~= nil then out.electrical = electrical end

  if e.type == "resource" then out.amount = e.amount end

  if e.type == "inserter" then
    local ok_pickup_position, pickup_position = pcall(function() return e.pickup_position end)
    if ok_pickup_position and pickup_position then
      out.pickup_position = { x = pickup_position.x, y = pickup_position.y }
    end
    local ok_drop_position, drop_position = pcall(function() return e.drop_position end)
    if ok_drop_position and drop_position then
      out.drop_position = { x = drop_position.x, y = drop_position.y }
    end

    local ok_pickup_target, pickup_target = pcall(function() return e.pickup_target end)
    if ok_pickup_target then out.pickup_target = entity_identity(pickup_target) end
    local ok_drop_target, drop_target = pcall(function() return e.drop_target end)
    if ok_drop_target then out.drop_target = entity_identity(drop_target) end
  end

  if e.type == "mining-drill" then
    local drop_position = e.drop_position
    if drop_position then
      out.drop_position = { x = drop_position.x, y = drop_position.y }
    end
    local drop_target = entity_identity(e.drop_target)
    out.drop_target_bound = drop_target ~= nil
    out.drop_target = drop_target or false
    local ok_target, target = pcall(function() return e.mining_target end)
    if ok_target then
      local identity = entity_identity(target)
      if identity then
        local ok_amount, amount = pcall(function() return target.amount end)
        if ok_amount and type(amount) == "number" then identity.amount = amount end
        out.mining_target = identity
      end
    end
  end

  local inventories = collect_inventories(e)
  if inventories then out.inventories = inventories end

  local belt = collect_belt_contents(e)
  if belt then out.belt_contents = belt end

  collect_fluids(e, out)
  local connections = fluid_connections.live(e)
  if #connections > 0 then out.fluid_connections = connections end

  return out
end

local MAX_TARGETS = 16

-- Inspect up to MAX_TARGETS entities in ONE call — reading machines one at a
-- time costs the brain a full round of thinking per machine.
function M.inspect(params)
  local c = companion.require_companion()
  local targets = type(params) == "table" and params.targets or nil
  if type(targets) ~= "table" or #targets == 0 then
    error("targets must be a non-empty array of {x, y}")
  end
  if #targets > MAX_TARGETS then
    error("inspect takes at most " .. MAX_TARGETS .. " targets per call — split the list")
  end
  local out = {}
  for i, target in ipairs(targets) do
    local ok, res = pcall(inspect_one, target, c)
    if ok then
      out[i] = res
    else
      local position = nil
      if type(target) == "table" then
        position = { x = tonumber(target.x), y = tonumber(target.y) }
      end
      out[i] = {
        error = tostring(res):gsub("^.-:%d+:%s*", ""),
        position = position,
      }
    end
  end
  return { tick = game.tick, entities = out }
end

return M
