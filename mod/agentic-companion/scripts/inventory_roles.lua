-- Inventories by role, as extract_items, insert_items and inspect_entity name
-- them: main, input, output, fuel, burnt_result, modules, trash, robots,
-- material, rocket (a silo's rocket cargo). Each role comes from a typed getter or, where none exists, the
-- inventory define of the entity's type (never by probing aliases: several
-- defines share an index across types, and the furnace_*, assembling_machine_*
-- and rocket_silo_* input/output/trash defines are deprecated).
local M = {}

local INPUT = { furnace = "crafter_input", ["assembling-machine"] = "crafter_input", ["rocket-silo"] = "crafter_input",
  lab = "lab_input", ["agricultural-tower"] = "agricultural_tower_input" }
local TRASH = { furnace = { "crafter_trash" }, ["assembling-machine"] = { "crafter_trash", "assembling_machine_dump" },
  ["rocket-silo"] = { "rocket_silo_trash" }, lab = { "lab_trash" }, ["logistic-container"] = { "logistic_container_trash" } }
local MAIN = { container = { "chest" }, ["logistic-container"] = { "chest" }, ["infinity-container"] = { "chest" },
  ["temporary-container"] = { "chest" }, ["linked-container"] = { "linked_container_main" },
  ["cargo-wagon"] = { "cargo_wagon" }, car = { "car_trunk" }, ["spider-vehicle"] = { "spider_trunk" },
  ["character-corpse"] = { "character_corpse" }, ["cargo-landing-pad"] = { "cargo_landing_pad_main" } }
local ROBOPORT = { robots = { "roboport_robot" }, material = { "roboport_material" } }
local ROCKET = { ["rocket-silo"] = { "rocket_silo_rocket" } }
local GETTERS = { output = "get_output_inventory", fuel = "get_fuel_inventory", burnt_result = "get_burnt_result_inventory",
  modules = "get_module_inventory" }

M.ORDER = { "main", "input", "output", "fuel", "burnt_result", "modules", "trash", "robots", "material", "rocket" }
M.ROLES = {}
for _, role in ipairs(M.ORDER) do M.ROLES[role] = true end

-- The entity's inventories for one role (empty when it has none; trash on an
-- assembling machine is two).
function M.get(entity, role)
  local kind = entity.type
  local defines_of
  if role == "main" then defines_of = MAIN[kind]
  elseif role == "input" then defines_of = INPUT[kind] and { INPUT[kind] }
  elseif role == "trash" then defines_of = TRASH[kind]
  elseif kind == "roboport" and ROBOPORT[role] then defines_of = ROBOPORT[role]
  elseif role == "rocket" then defines_of = ROCKET[kind]
  elseif GETTERS[role] and not (role == "output" and (MAIN[kind] or kind == "roboport")) then
    local ok, inventory = pcall(function() return entity[GETTERS[role]]() end)
    if not (ok and inventory) then return {} end
    -- A burner drill's output getter returns its fuel inventory: that is fuel
    -- only, so output reads and extractions never take its reserve fuel.
    if role == "output" and kind == "mining-drill" then
      local has_fuel, fuel = pcall(function() return entity.get_fuel_inventory() end)
      if has_fuel and fuel and (fuel == inventory or (inventory.index ~= nil and inventory.index == fuel.index)) then return {} end
    end
    return { inventory }
  end
  local found = {}
  for _, name in ipairs(defines_of or {}) do
    local index = defines.inventory[name]
    local ok, inventory = false, nil
    if index then ok, inventory = pcall(entity.get_inventory, index) end
    if ok and inventory then found[#found + 1] = inventory end
  end
  return found
end

-- The roles this entity has, in ORDER.
function M.present(entity)
  local roles = {}
  for _, role in ipairs(M.ORDER) do
    if #M.get(entity, role) > 0 then roles[#roles + 1] = role end
  end
  return roles
end

return M
