-- inspect: detailed view of an entity at an exact local map position
-- (1.5-tile search, non-characters preferred). Beyond the local radius it
-- reads only own-force entities in charted chunks and marks them remote.
-- inspect {surface?} reads another surface the same way: there everything is
-- remote (no body stands there). Heated machines add temperature and frozen.
local companion = require("scripts.companion")
local surfaces = require("scripts.surfaces")
local items = require("scripts.items")
local fluid_connections = require("scripts.fluid_connections")
local inventory_roles = require("scripts.inventory_roles")
local entity_settings = require("scripts.entity_settings")
local jobs = require("scripts.jobs")
local rocket = require("scripts.actions.rocket")
local requests = require("scripts.requests")

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

-- Inventories by role (inventory_roles), by item key (a non-normal quality
-- is "name@quality"). input, output and fuel show when the entity has them,
-- empty or not; the other roles only when they hold something.
local ALWAYS_SHOWN = { input = true, output = true, fuel = true }

local function collect_inventories(entity)
  local result, found = {}, false
  for _, role in ipairs(inventory_roles.ORDER) do
    local inventories = inventory_roles.get(entity, role)
    local bucket, any = {}, false
    for _, inventory in ipairs(inventories) do
      for key, count in pairs(items.sum_contents(inventory)) do
        bucket[key] = (bucket[key] or 0) + count
        any = true
      end
    end
    if any or (#inventories > 0 and ALWAYS_SHOWN[role]) then result[role], found = bucket, true end
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

  local surface = c.surface
  -- Player parity: the map view shows a player their own machines anywhere the
  -- force has charted. Beyond the local radius (or on a surface the body is
  -- not on) only such entities are read; the chart is checked before the
  -- surface is queried, and one refusal covers uncharted, foreign and empty
  -- positions so it reveals nothing about them.
  local remote = c.position == nil or distance(c.position, target) > 30
  if remote then
    local refusal = "inspect positions must be within 30 tiles of Codex, or on an own-force entity in a charted chunk"
    local platform = surfaces.is_platform(surface)
    local function is_charted(position)
      return surfaces.charted(c.force, surface, math.floor(position.x / 32), math.floor(position.y / 32), platform)
    end
    if not is_charted(target) then error(refusal) end
    local best, best_d = nil, math.huge
    for _, e in ipairs(surface.find_entities_filtered({ position = target, radius = SEARCH_RADIUS, force = c.force })) do
      if e.valid and e.force == c.force and e.type ~= "character" and is_charted(e.position) then
        local d = distance(e.position, target)
        if d < best_d then best, best_d = e, d end
      end
    end
    if not best then error(refusal) end
    return best, true
  end

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
  local e, remote = locate(position, c)

  local out = {
    name = e.name,
    type = e.type,
    position = { x = round1(e.position.x), y = round1(e.position.y) },
    direction = e.direction,
  }
  -- Read through the chart, not from within reach: acting still needs reach.
  if remote then out.remote = true end

  local ok, health = pcall(function() return e.health end)
  if ok and health then out.health = round1(health) end

  -- Heat on planets that freeze (Aquilo): a machine's heat buffer and
  -- whether it froze.
  local ok_freezable, freezable = pcall(function() return e.is_freezable end)
  if ok_freezable and freezable then
    local ok_frozen, frozen = pcall(function() return e.frozen end)
    if ok_frozen then out.frozen = frozen == true end
  end
  local ok_temperature, temperature = pcall(function() return e.temperature end)
  if ok_temperature and type(temperature) == "number" then out.temperature = round1(temperature) end

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
      local ok_name, name = pcall(function() return current.name.name end)
      if ok_name and type(name) == "string" then facts.currently_burning = name end
      local ok_value, value = pcall(function() return current.name.fuel_value end)
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
    -- Factorio 2.0 flow limits are quality-dependent prototype methods.
    electrical_number("input_flow_limit", function() return source.get_input_flow_limit(e.quality) end)
    electrical_number("output_flow_limit", function() return source.get_output_flow_limit(e.quality) end)
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

  -- What the entity's window would show as set (non-default values only).
  local ok_settings, settings = pcall(entity_settings.read, e)
  if ok_settings and settings then out.settings = settings end
  local ok_mirror, mirroring = pcall(function() return e.mirroring end)
  if ok_mirror and mirroring == true then out.mirror = true end

  -- A silo's rocket (parts, cargo, weight, automatic requests) and a landing
  -- pad's stock and requests: their windows. A platform's hub, collectors and
  -- thrusters are read with platform_status.
  if e.type == "rocket-silo" then
    local ok_silo, silo = pcall(rocket.silo_block, e)
    if ok_silo then out.silo = silo end
  elseif e.type == "cargo-landing-pad" then
    local ok_pad, main = pcall(function() return e.get_inventory(defines.inventory.cargo_landing_pad_main) end)
    local stock = {}
    for _, item in ipairs(ok_pad and main and main.get_contents() or {}) do
      stock[#stock + 1] = { item = item.name, count = item.count }
    end
    table.sort(stock, function(a, b) return a.item < b.item end)
    out.landing_pad = { inventory = stock, requests = requests.read(e) }
  end

  local belt = collect_belt_contents(e)
  if belt then out.belt_contents = belt end

  collect_fluids(e, out)
  local connections = fluid_connections.live(e)
  if #connections > 0 then out.fluid_connections = connections end

  return out
end

-- Positions one call reads. Each costs about PER_TARGET work items (an area
-- query, a few dozen reads and the inventories), so a job reads about 15 a
-- tick and a call of 64 spreads over a few ticks.
M.MAX_TARGETS = 64
M.PER_TARGET = 40

-- inspect as a job (jobs.lua) of up to MAX_TARGETS entities in ONE call —
-- reading machines one at a time costs the brain a full round of thinking per
-- machine. Positions past the limit are not read; `omitted` counts them.
-- What the reads stand on: the surface (kept in the state by index), the
-- force, and the body's position when it is on that surface (else none:
-- every read there is remote).
local function context(state)
  local body = companion.require_present()
  -- A read a 0.22.2 save left running read the body's surface.
  if state.surface_index == nil then state.surface_index, state.surface = body.surface.index, body.surface_ref end
  local surface = surfaces.stored(state.surface_index, body)
  if not surface then error("SURFACE_GONE: surface " .. tostring(state.surface) .. " no longer exists", 0) end
  local here = body.surface ~= nil and body.surface.index == state.surface_index
  return { surface = surface, force = body.force, position = here and body.position or nil }
end

M.job = {
  start = function(params)
    local target = surfaces.target(type(params) == "table" and params.surface or nil)
    local targets = type(params) == "table" and params.targets or nil
    if type(targets) ~= "table" or #targets == 0 then
      error("targets must be a non-empty array of {x, y}")
    end
    local omitted = math.max(0, #targets - M.MAX_TARGETS)
    local list = {}
    for i = 1, #targets - omitted do list[i] = targets[i] end
    return { targets = list, omitted = omitted, index = 1, entities = {}, first_tick = game.tick,
      surface_index = target.surface.index, surface = target.ref,
      evidence_class = "fresh_local_exact", scope = "within_30_tiles_of_codex_at_source_tick" }
  end,
  step = function(state, budget)
    local c = context(state)
    while state.index <= #state.targets do
      if budget.left <= 0 then return nil end
      local i, target = state.index, state.targets[state.index]
      local ok, res = pcall(inspect_one, target, c)
      if ok then
        state.entities[i] = res
        -- A remote entity is read through the chart: the envelope must not
        -- claim the whole result is local.
        if res.remote then
          state.evidence_class = "fresh_exact_local_and_charted_remote"
          state.scope = "within_30_tiles_or_own_force_charted_at_source_tick"
        end
      else
        local position = nil
        if type(target) == "table" then
          position = { x = tonumber(target.x), y = tonumber(target.y) }
        end
        state.entities[i] = {
          error = tostring(res):gsub("^.-:%d+:%s*", ""),
          position = position,
        }
      end
      state.index, budget.left = i + 1, budget.left - M.PER_TARGET
    end
    return {
      tick = game.tick, surface = state.surface,
      -- Reads spread over ticks name the tick they began.
      first_tick = state.first_tick ~= game.tick and state.first_tick or nil,
      evidence_class = state.evidence_class,
      scope = state.scope,
      entities = state.entities,
      omitted = state.omitted > 0 and state.omitted or nil,
    }
  end,
}

-- All targets read within this call (one target, or tests).
function M.inspect(params)
  return (jobs.run_now(M.job, params))
end

return M
