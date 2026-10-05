local autonomy = require("scripts.autonomy")
local companion = require("scripts.companion")
local map_summary = require("scripts.map_summary")
local research = require("scripts.research")
local spatial = require("scripts.spatial")

local M = {}

-- Rocks and wrecks (simple-entity) also drop manufactured items, so they are
-- not raw-resource sources; rock stone and coal are already resource products.
local NATURAL_SOURCE_TYPES = {
  resource = true, tree = true, fish = true, plant = true,
}
local PRIMARY_UTILITY_FLUIDS = { water = true }

local function sorted_counts(counts)
  local rows = {}
  for name, count in pairs(counts or {}) do
    count = tonumber(count) or 0
    if count ~= 0 then rows[#rows + 1] = { name = name, count = count } end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

local function raw_resource_products()
  local found = {}
  for _, prototype in pairs(prototypes and prototypes.entity or {}) do
    if NATURAL_SOURCE_TYPES[prototype.type] then
      local ok, mineable = pcall(function() return prototype.mineable_properties end)
      for _, product in ipairs(ok and mineable and mineable.products or {}) do
        local name = product.name
        local kind = product.type or "item"
        if type(name) == "string" and not (kind == "fluid" and PRIMARY_UTILITY_FLUIDS[name]) then
          found[kind .. "\0" .. name] = { type = kind, name = name }
        end
      end
    end
  end
  local rows = {}
  for _, row in pairs(found) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.type == b.type and a.name < b.name or a.type < b.type end)
  return rows
end

local function statistics(force, surface, getter)
  local ok, value = pcall(function() return force[getter](surface) end)
  if not ok or not value then return { produced = {}, consumed = {}, unavailable = true } end
  return {
    produced = sorted_counts(value.input_counts),
    consumed = sorted_counts(value.output_counts),
  }
end

function M.capture()
  local body = companion.require_companion()
  -- A compact observation of radius 5 is bounded by its small area.
  local observation = spatial.observe_compact({ radius = 5 })
  return {
    tick = game.tick,
    character = observation.character,
    progression = research.progression_status({}),
    -- What the mod maintains (registry, line sampler, power cache): no chunk
    -- walk and no entity read per sample.
    factory = map_summary.registry_factory(),
    -- Production lines (autonomy.lua): how many run, self-sustain or are hand-fed.
    lines = autonomy.counts(),
    statistics = {
      items = statistics(body.force, body.surface, "get_item_production_statistics"),
      fluids = statistics(body.force, body.surface, "get_fluid_production_statistics"),
      raw_resources = raw_resource_products(),
      semantics = { produced = "force_surface_input_counts", consumed = "force_surface_output_counts" },
    },
  }
end

return M
