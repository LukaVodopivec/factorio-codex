local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local function canonical(value)
  if type(value) ~= "table" then return type(value) == "string" and string.format("%q", value) or tostring(value) end
  local is_array, count = true, 0
  for key in pairs(value) do if type(key) ~= "number" then is_array = false end; count = count + 1 end
  if is_array then local out = {}; for i = 1, count do out[i] = canonical(value[i]) end; return "[" .. table.concat(out, ",") .. "]" end
  local keys = {}; for key in pairs(value) do keys[#keys + 1] = key end; table.sort(keys)
  local out = {}; for _, key in ipairs(keys) do out[#out + 1] = string.format("%q", key) .. ":" .. canonical(value[key]) end
  return "{" .. table.concat(out, ",") .. "}"
end
local player_force, enemy_force, neutral_force = {}, {}, {}
local character
local entities = {}
local next_unit = 1
local function entity(name, x, y, width, height)
  local result = { valid = true, name = name, type = "assembling-machine", force = player_force, unit_number = next_unit, position = { x = x, y = y }, selection_box = { left_top = { x = x - width / 2, y = y - height / 2 }, right_bottom = { x = x + width / 2, y = y + height / 2 } } }
  next_unit = next_unit + 1
  return result
end
local function resource(name, x, y, amount)
  return { valid = true, name = name, type = "resource", force = neutral_force, amount = amount, position = { x = x, y = y }, selection_box = { left_top = { x = x - 0.49, y = y - 0.49 }, right_bottom = { x = x + 0.49, y = y + 0.49 } } }
end
local function ground_item(item, count, x, y)
  return { valid = true, name = "item-on-ground", type = "item-entity", force = player_force,
    position = { x = x, y = y }, stack = { valid_for_read = true, name = item, count = count },
    selection_box = { left_top = { x = x - 0.2, y = y - 0.2 }, right_bottom = { x = x + 0.2, y = y + 0.2 } } }
end
entities[1] = entity("z-machine", 0, 0, 1, 1)
entities[2] = entity("a-machine", 0, 0, 2, 2)
entities[2].status = 1
entities[2].get_recipe = function() return { name = "iron-gear-wheel" } end
entities[3] = resource("iron-ore", 5, 0, 100)
entities[4] = resource("iron-ore", 6, 0, 200)
entities[5] = resource("iron-ore", 12, 0, 50)
entities[6] = resource("copper-ore", -5, 0, 75)
entities[7] = resource("coal", 0, 8, 30)
entities[8] = resource("stone", 0, -8, 40)
entities[9] = resource("uranium-ore", -0.5, 0, 10)
entities[10] = resource("uranium-ore", 0.5, 0, 20)
entities[11] = ground_item("iron-ore", 3, 2.25, -1.75)
entities[12] = ground_item("nearest-ground", 1, 0.25, 0.25)
for i = 1, 256 do
  local x, y = -10 + ((i - 1) % 16) * 1.25, -10 + math.floor((i - 1) / 16) * 1.25
  entities[#entities + 1] = ground_item("ground-" .. i, 1, x, y)
end
entities[#entities + 1] = ground_item("farthest-ground", 1, 14.4, 14.4)
local corners = { { -14, -14 }, { 14, -14 }, { -14, 14 }, { 14, 14 } }
for i = 1, 258 do local point = corners[(i - 1) % #corners + 1]; entities[#entities + 1] = entity("machine-" .. i, point[1], point[2], 1, 1) end
local edge = entity("edge-machine", 16.5, 0, 3, 3)
edge.bounding_box = { left_top = { x = 16, y = -0.5 }, right_bottom = { x = 17, y = 0.5 } }
edge.selection_box = { left_top = { x = 14.75, y = -1.75 }, right_bottom = { x = 18.25, y = 1.75 } }
entities[#entities + 1] = edge
local entity_order = entities
local surface = {
  get_tile = function() return { collides_with = function() return false end } end,
  find_entities_filtered = function(filter)
    local area, result = filter.area, {}
    local left, top, right, bottom = area[1][1], area[1][2], area[2][1], area[2][2]
    for _, candidate in ipairs(entity_order) do
      local box = candidate.bounding_box or {
        left_top = { x = candidate.position.x - 0.5, y = candidate.position.y - 0.5 },
        right_bottom = { x = candidate.position.x + 0.5, y = candidate.position.y + 0.5 },
      }
      if box.right_bottom.x > left and box.left_top.x < right
        and box.right_bottom.y > top and box.left_top.y < bottom then
        result[#result + 1] = candidate
      end
    end
    return result
  end,
}
local inventory = { get_contents = function() return { { name = "iron-plate", count = 3 } } end }
local ammo_inventory = { get_contents = function() return { { name = "firearm-magazine", count = 7 } } end }
character = { valid = true, name = "character", type = "character", force = player_force, surface = surface, position = { x = 0, y = 0 }, health = 250, reach_distance = 10, build_distance = 10, get_main_inventory = function() return inventory end,
  get_inventory = function(index) if index == 1 then return ammo_inventory end end }
entities[#entities + 1] = character
package.loaded["scripts.companion"] = { require_companion = function() return character end }
package.loaded["scripts.tasks"] = { active_summary = function() return nil end, queue_length = function() return 0 end }
_G.game = { tick = 123, forces = { enemy = enemy_force } }
_G.defines = { entity_status = { no_power = 1 }, inventory = { character_ammo = 1 } }
_G.prototypes = { entity = {
  ["edge-machine"] = {
    collision_box = { left_top = { x = -0.5, y = -0.5 }, right_bottom = { x = 0.5, y = 0.5 } },
    selection_box = { left_top = { x = -1.75, y = -1.75 }, right_bottom = { x = 1.75, y = 1.75 } },
  },
} }
local spatial = require("scripts.spatial")
local parse_require = require
_G.require = function()
  error("require can't be used after control-stage parsing")
end
local observation = spatial.observe_local({ radius = 15, detail = "full" })
check(observation.tick == 123 and observation.radius == 15, "observation includes current tick and radius")
check(observation.character.active_task == nil,
  "observation uses its parse-time task dependency when runtime require is prohibited")
check(observation.grid.origin.x == -15 and observation.grid.origin.y == -15, "observation is centered on sole Codex character")
local injected_center = spatial.observe_local({ radius = 15, detail = "full", center = { x = 999, y = -999 } })
check(injected_center.grid.origin.x == observation.grid.origin.x
  and injected_center.grid.origin.y == observation.grid.origin.y
  and canonical(injected_center) == canonical(observation),
  "caller center is ignored and origin derives solely from Codex")
check(observation.character.inventory["iron-plate"] == 3, "observation includes character inventory")
check(observation.character.inventory_scope == "main"
  and observation.character.ammo_inventory["firearm-magazine"] == 7
  and observation.character.inventory["firearm-magazine"] == nil,
  "observation distinguishes main inventory from equipped ammunition")
local ground_by_name = {}
for _, item in ipairs(observation.ground_items) do ground_by_name[item.item] = item end
check(#observation.ground_items == 256 and observation.omitted_ground_items == 3
  and ground_by_name["nearest-ground"] and not ground_by_name["farthest-ground"],
  "observation retains the nearest 256 exact ground targets before presentation sorting")
check(ground_by_name["iron-ore"] and ground_by_name["iron-ore"].count == 3
  and ground_by_name["iron-ore"].position.x == 2.25,
  "observation exposes exact item/count/position pickup evidence")
check(observation.grid.rows[15]:sub(15, 16) == "aa" and observation.grid.rows[16]:sub(15, 16) == "a@", "full 2x2 footprint is painted beneath higher-priority Codex")
check(observation.grid.rows[15]:sub(15, 15) == "a", "equal-priority overlap deterministically paints the lexical-name glyph")
check(observation.grid.legend.a == "a-machine" and observation.grid.legend.b == "edge-machine", "building glyphs are assigned lexically")
check(#observation.entities == 256 and observation.omitted_entities == 6,
  "nearest 256 entity cap and omission count cover only non-resource details")
local has_resource_detail = false
for _, detail in ipairs(observation.entities) do if detail.type == "resource" then has_resource_detail = true end end
check(not has_resource_detail, "resource rows are omitted from entity details and represented only as patches")
local ordered = true
for i = 2, #observation.entities do
  local a, b = observation.entities[i - 1], observation.entities[i]
  if a.position.y > b.position.y or (a.position.y == b.position.y and (a.position.x > b.position.x or (a.position.x == b.position.x and a.name > b.name))) then ordered = false end
end
check(ordered, "retained nearest entities are finally sorted by stable y/x/name")
check(observation.grid.coordinate_rule:match("north%-to%-south") ~= nil, "coordinate rule is explicit")
check(observation.grid.legend.A == "coal" and observation.grid.legend.B == "copper-ore"
  and observation.grid.legend.C == "iron-ore" and observation.grid.legend.D == "stone",
  "resource glyphs are assigned lexically")
local iron_patches = {}
for _, patch in ipairs(observation.resource_patches) do if patch.name == "iron-ore" then iron_patches[#iron_patches + 1] = patch end end
table.sort(iron_patches, function(a, b) return a.entity_count > b.entity_count end)
check(#iron_patches == 2 and iron_patches[1].entity_count == 2 and iron_patches[1].total_amount == 300 and iron_patches[2].entity_count == 1 and iron_patches[2].total_amount == 50,
  "connected resource tiles become deterministic amount-bearing patches")
check(iron_patches[1].nearest_target.x == 5 and iron_patches[1].nearest_target.y == 0
  and iron_patches[1].nearest_target.amount == 100 and iron_patches[1].nearest_target.distance == 5,
  "resource patches expose the deterministic nearest exact mining target without an identity")
check(iron_patches[1].nearest_target.unit_number == nil,
  "nearest resource targets never expose unit numbers")
local uranium_patch
for _, patch in ipairs(observation.resource_patches) do if patch.name == "uranium-ore" then uranium_patch = patch end end
check(uranium_patch and uranium_patch.nearest_target.x == -0.5 and uranium_patch.nearest_target.distance == 0.5,
  "equal-distance nearest resource targets use the stable y/x tiebreak")
local coal_index, stone_index
for index, patch in ipairs(observation.resource_patches) do
  if patch.name == "coal" then coal_index = index elseif patch.name == "stone" then stone_index = index end
end
check(coal_index and stone_index and coal_index < stone_index
  and observation.resource_patches[coal_index].distance == observation.resource_patches[stone_index].distance,
  "equal-distance resource patches use the lexical-name tiebreak")
local a_detail, edge_detail
for _, detail in ipairs(observation.entities) do if detail.name == "a-machine" then a_detail = detail elseif detail.name == "edge-machine" then edge_detail = detail end end
check(a_detail and a_detail.status == "no_power" and a_detail.recipe == "iron-gear-wheel", "entity details include named runtime status and recipe")
check(edge_detail and edge_detail.bounds.left_top.x == 14.75 and edge_detail.bounds.right_bottom.x == 18.25 and edge_detail.footprint.width == 3.5,
  "selection-only overlap with center and collision outside grid is queried and retained with precise union bounds")
local reversed = {}; for i = #entities, 1, -1 do reversed[#reversed + 1] = entities[i] end; entity_order = reversed
local shuffled_observation = spatial.observe_local({ radius = 15, detail = "full" })
check(canonical(observation) == canonical(shuffled_observation), "shuffled entity input produces byte-identical canonical output")
local compact = spatial.observe_local({ radius = 15 })
check(compact.detail == "compact" and compact.grid == nil and compact.character.crafting.queue_size == 0,
  "compact is the default and omits the grid while retaining actionable character state")
check(#compact.ground_items == 12 and compact.omitted_ground_items == 247
  and #compact.entities == 12 and compact.omitted_entities == 250
  and compact.omitted_resource_patches == 0,
  "compact observation bounds nearest grounded targets and reports every omission count")
check(compact.entities[1].bounds == nil and compact.entities[1].selection_box == nil
  and compact.entities[1].collision_box == nil and compact.entities[1].footprint == nil,
  "compact entity rows omit placement geometry retained by full observations")
check(#canonical(compact) < 10000,
  "dense compact observation remains below the bounded serialized response budget")
local position_reads, dense = 0, {}
for x = -14, 15 do for y = -14, 15 do
  local raw = resource("dense-ore", x + 0.5, y + 0.5, 10)
  local pos = raw.position; raw.position = nil
  dense[#dense + 1] = setmetatable(raw, { __index = function(_, key) if key == "position" then position_reads = position_reads + 1; return pos end end })
end end
entity_order = dense
local dense_observation = spatial.observe_local({ radius = 15 })
check(#dense_observation.resource_patches == 1 and dense_observation.resource_patches[1].entity_count == 900
  and dense_observation.resource_patches[1].total_amount == 9000,
  "a dense ore field clusters into one exact patch")
check(position_reads < 20 * 900,
  "patch clustering reads each ore position a bounded number of times, not once per pair")
_G.require = parse_require
os.exit(failures == 0 and 0 or 1)
