-- Test-only blueprint items: a script inventory of LuaItemStack proxies whose
-- members are checked against the documented 2.0.77 API (factorio_api_mock).
-- A stack holds {item, entities, tiles}; create_blueprint reads `world`
-- (entities with name, type, position, direction, force, recipe?) inside the
-- area for the given force, positions made relative to the area's centre
-- tile corner; build_blueprint makes ghost tables and records its arguments.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local mock = dofile(here .. "/factorio_api_mock.lua")

local M = { mock = mock, built = {}, created = {}, world = {} }
local states = setmetatable({}, { __mode = "k" })

local function copy_list(list)
  if not list then return nil end
  local out = {}
  for i, v in ipairs(list) do
    local row = {}
    for k, x in pairs(v) do row[k] = x end
    out[i] = row
  end
  return out
end

local function turn(p, direction)
  local x, y = p.x, p.y
  for _ = 1, math.floor((direction or 0) / 4) do x, y = -y, x end
  return { x = x, y = y }
end

function M.stack()
  local st = {}
  local s
  s = mock.item_stack({
    set_stack = function(v)
      if v == nil then st.item, st.entities, st.tiles = nil, nil, nil; return true end
      local other = states[v]
      if other then
        st.item, st.entities, st.tiles = other.item, copy_list(other.entities), copy_list(other.tiles)
      else
        st.item, st.entities, st.tiles = v.name, nil, nil
      end
      return true
    end,
    clear = function() st.item, st.entities, st.tiles = nil, nil, nil end,
    is_blueprint_setup = function() return st.item == "blueprint" and st.entities ~= nil and #st.entities > 0 end,
    get_blueprint_entity_count = function() return st.entities and #st.entities or 0 end,
    get_blueprint_entities = function() return copy_list(st.entities) end,
    set_blueprint_entities = function(list) assert(st.item == "blueprint"); st.entities = copy_list(list) end,
    get_blueprint_tiles = function() return copy_list(st.tiles) end,
    set_blueprint_tiles = function(list) st.tiles = copy_list(list) end,
    export_stack = function() return "0eNo" .. tostring(st.entities and #st.entities or 0) end,
    create_blueprint = function(args)
      assert(st.item == "blueprint", "create_blueprint on a blueprint item")
      M.created[#M.created + 1] = args
      local a = args.area
      local cx = math.floor((a.left_top.x + a.right_bottom.x) / 2)
      local cy = math.floor((a.left_top.y + a.right_bottom.y) / 2)
      local list = {}
      for _, e in ipairs(M.world) do
        if e.force == args.force and e.position.x > a.left_top.x and e.position.x < a.right_bottom.x
          and e.position.y > a.left_top.y and e.position.y < a.right_bottom.y then
          list[#list + 1] = { entity_number = #list + 1, name = e.name, recipe = e.recipe,
            position = { x = e.position.x - cx, y = e.position.y - cy },
            direction = e.direction ~= 0 and e.direction or nil }
        end
      end
      st.entities = #list > 0 and list or nil
      return {}
    end,
    build_blueprint = function(args)
      M.built[#M.built + 1] = args
      local ghosts = {}
      for _, e in ipairs(st.entities or {}) do
        local p = turn(e.position, args.direction)
        ghosts[#ghosts + 1] = { valid = true, type = "entity-ghost", ghost_name = e.name, name = "entity-ghost",
          position = { x = args.position.x + p.x, y = args.position.y + p.y },
          direction = ((e.direction or 0) + (args.direction or 0)) % 16 }
      end
      return ghosts
    end,
  })
  states[s] = st
  mock.read(s, "valid_for_read", function() return st.item ~= nil end)
  mock.read(s, "cost_to_build", function()
    local counts, rows = {}, {}
    for _, e in ipairs(st.entities or {}) do counts[e.name] = (counts[e.name] or 0) + 1 end
    for name, count in pairs(counts) do rows[#rows + 1] = { name = name, count = count, quality = "normal" } end
    return rows
  end)
  return s
end

function M.state(stack) return states[stack] end

-- A LuaInventory of `size` blueprint slots (game.create_inventory).
function M.inventory(size)
  local slots = {}
  for i = 1, size do slots[i] = M.stack() end
  local values = { valid = true, resize = function(n) for i = #slots + 1, n do slots[i] = M.stack() end end }
  for i = 1, size do values[i] = slots[i] end
  local inventory = mock.inventory(values)
  mock.length(inventory, function() return #slots end)
  for i = 1, size do mock.read(inventory, i, function() return slots[i] end) end
  return inventory
end

return M
