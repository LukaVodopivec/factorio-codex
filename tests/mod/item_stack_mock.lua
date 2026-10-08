-- Test-only real item stacks: strict LuaInventory and LuaItemStack mocks
-- whose stacks carry name, count, quality, spoil_percent, durability and
-- ammo. Inserting a stack copies all of them and never changes its source;
-- merging averages spoil and adds durability and ammo the way the game does
-- (two partly used packs may fold into one fewer), so nothing is created.
-- transfer_stack splits as the engine does: the moved part is whole items
-- and the source keeps its partly used top item, unless all of it moves.
--   M.inventory(size)        empty slots; M.put(inv, i, stack) fills one
--   M.view(map, room)        a {name = count} map as one stack per name, for
--                            fixtures that count by name; room(name) caps
--                            inserts (unbounded when nil)
--   M.counted(names, count_of, remove)
--                            the same over a fixture's count and remove stubs
--   M.stack(get, set, alive) one stack over get()/set(rec); while alive()
--                            is false (a belt's stack once its line changed)
--                            every member but valid errors
--   M.create_inventory(n)    game.create_inventory
--   M.durability(stacks...)  the durability units the stacks hold
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local api = dofile(here .. "/factorio_api_mock.lua")
local M = { stack_sizes = {}, max_durability = {}, magazine = {}, created = 0, destroyed = 0 }

local function stack_size(name) return M.stack_sizes[name] or 50 end
local function quality_of(q)
  if q == nil then return "normal" end
  if type(q) == "string" then return q end
  return q.name
end

-- Units of a record: (count - 1) whole items plus the top's durability or ammo.
local function units(rec, field, full)
  return (rec.count - 1) * full + (rec[field] or full)
end

-- Merges k items of `incoming` (all of it when k == incoming.count, else k
-- whole items) into rec (same name and quality); returns the merged record.
local function merge(rec, incoming, k)
  local out = {}
  for key, value in pairs(rec) do out[key] = value end
  local total = rec.count + k
  if rec.spoil_percent or incoming.spoil_percent then
    out.spoil_percent = ((rec.spoil_percent or 0) * rec.count + (incoming.spoil_percent or 0) * k) / total
  end
  out.count = total
  for field, fulls in pairs({ durability = M.max_durability, ammo = M.magazine }) do
    local full = fulls[rec.name]
    if full then
      local moved = k == incoming.count and units(incoming, field, full) or k * full
      local sum = units(rec, field, full) + moved
      out.count = math.ceil(sum / full - 1e-9)
      out[field] = sum - (out.count - 1) * full
    end
  end
  return out
end

local records = setmetatable({}, { __mode = "k" })

-- A LuaItemStack over get()/set(rec): set(nil) empties it. alive() (always
-- true when nil) is its valid; an invalid stack's other members error.
local function stack_proxy(get, set, alive)
  local proxy = api.item_stack({})
  local function valid() return alive == nil or alive() end
  local function on(key, fn)
    api.read(proxy, key, function() assert(valid(), "read of an invalid item stack: " .. key); return fn() end)
  end
  local function rec() return get() end
  local function need() return assert(rec(), "read of an empty item stack") end
  api.read(proxy, "valid", valid)
  on("valid_for_read", function() return rec() ~= nil end)
  on("name", function() return need().name end)
  on("count", function() local r = rec(); return r and r.count or 0 end)
  on("quality", function() return { name = need().quality } end)
  on("spoil_percent", function() return need().spoil_percent or 0 end)
  on("durability", function() local r = need(); return r.durability or M.max_durability[r.name] end)
  on("ammo", function() local r = need(); return r.ammo or M.magazine[r.name] end)
  api.write(proxy, "count", function(value)
    assert(valid(), "write of an invalid item stack")
    local r = need()
    assert(value <= r.count, "a count write never adds items")
    if value == 0 then set(nil) else
      local out = {}
      for key, v in pairs(r) do out[key] = v end
      out.count = value
      set(out)
    end
  end)
  on("clear", function() return function() set(nil) end end)
  on("transfer_stack", function()
    return function(source, amount)
      local from = assert(records[source], "transfer_stack takes a mock stack")
      assert(from.valid(), "transfer_stack from an invalid item stack")
      local src = from.get()
      if not src then return false end
      amount = math.min(amount or src.count, src.count)
      local dst = rec()
      local k
      if not dst then
        k = math.min(amount, stack_size(src.name))
        local out = {}
        for key, v in pairs(src) do out[key] = v end
        out.count = k
        if k < src.count then out.durability, out.ammo = nil, nil end
        set(out)
      elseif dst.name == src.name and dst.quality == src.quality then
        k = math.min(amount, stack_size(src.name) - dst.count)
        if k > 0 then set(merge(dst, src, k)) end
      else
        return false
      end
      if k >= src.count then from.set(nil) elseif k > 0 then
        local rest = {}
        for key, v in pairs(src) do rest[key] = v end
        rest.count = src.count - k
        from.set(rest)
      end
      return k == amount
    end
  end)
  records[proxy] = { get = get, set = set, valid = valid }
  return proxy
end
M.stack = stack_proxy

-- What an insert offers: a mock stack's record or an ItemStackDefinition.
local function offered(items)
  if records[items] then
    assert(records[items].valid(), "insert of an invalid item stack")
    return records[items].get()
  end
  return { name = items.name, count = items.count or 1, quality = quality_of(items.quality),
    spoil_percent = items.spoil_percent, durability = items.durability, ammo = items.ammo }
end

local function matches(rec, filter)
  if rec == nil then return false end
  if filter == nil then return true end
  if type(filter) == "string" then return rec.name == filter end
  return rec.name == filter.name and (filter.quality == nil or rec.quality == quality_of(filter.quality))
end

-- Common inventory members over a slot list: slots() returns the records in
-- order, get(i)/set(i, rec) read and write one.
local function inventory_proxy(n, get, set, extra)
  local values = {}
  local proxies = {}
  setmetatable(values, {
    __index = function(_, key)
      if type(key) == "number" then
        proxies[key] = proxies[key] or stack_proxy(function() return get(key) end, function(rec) set(key, rec) end)
        return proxies[key]
      end
    end,
    __len = function() return n() end,
  })
  local function each(fn) for i = 1, n() do local r = get(i); if r then fn(r, i) end end end
  values.get_item_count = function(filter)
    local total = 0
    each(function(r) if matches(r, filter) then total = total + r.count end end)
    return total
  end
  values.get_contents = function()
    local rows, by = {}, {}
    each(function(r)
      local key = r.name .. "@" .. r.quality
      if not by[key] then by[key] = { name = r.name, quality = r.quality, count = 0 }; rows[#rows + 1] = by[key] end
      by[key].count = by[key].count + r.count
    end)
    return rows
  end
  values.remove = function(items)
    local want, q, removed = items.count or 1, quality_of(items.quality), 0
    for i = n(), 1, -1 do
      local r = get(i)
      if removed < want and r and r.name == items.name and r.quality == q then
        local k = math.min(want - removed, r.count)
        removed = removed + k
        if k == r.count then set(i, nil) else
          local out = {}
          for key, v in pairs(r) do out[key] = v end
          out.count = r.count - k
          set(i, out)
        end
      end
    end
    return removed
  end
  for key, value in pairs(extra) do values[key] = value end
  return api.inventory(values)
end

function M.inventory(size)
  local slots = {}
  local inv
  local function room(name, q)
    local free = 0
    for i = 1, size do
      local r = slots[i]
      if not r then free = free + stack_size(name)
      elseif r.name == name and r.quality == q then free = free + stack_size(name) - r.count end
    end
    return free
  end
  inv = inventory_proxy(function() return size end, function(i) return slots[i] end,
    function(i, rec) slots[i] = rec end, {
    get_insertable_count = function(item)
      local name = type(item) == "string" and item or item.name
      return room(name, type(item) == "string" and "normal" or quality_of(item.quality))
    end,
    can_insert = function(items) local rec = offered(items); return room(rec.name, rec.quality) > 0 end,
    is_empty = function() return next(slots) == nil end,
    -- Merges into stacks of the same item first, then fills empty slots;
    -- the incoming partly used top item lands last.
    insert = function(items)
      local rec = offered(items)
      if not rec or rec.count < 1 then return 0 end
      local left = rec.count
      for pass = 1, 2 do
        for i = 1, size do
          if left == 0 then break end
          local r = slots[i]
          local part = { name = rec.name, quality = rec.quality, spoil_percent = rec.spoil_percent, count = left,
            durability = rec.durability, ammo = rec.ammo }
          if pass == 1 and r and r.name == rec.name and r.quality == rec.quality and r.count < stack_size(rec.name) then
            local k = math.min(left, stack_size(rec.name) - r.count)
            slots[i] = merge(r, part, k)
            left = left - k
          elseif pass == 2 and not r then
            local k = math.min(left, stack_size(rec.name))
            local out = {}
            for key, v in pairs(part) do out[key] = v end
            out.count = k
            if k < left then out.durability, out.ammo = nil, nil end
            slots[i] = out
            left = left - k
          end
        end
      end
      return rec.count - left
    end,
    destroy = function() M.destroyed = M.destroyed + 1; for i in pairs(slots) do slots[i] = nil end end,
  })
  return inv
end

-- Fills slot i with a stack {name, count, quality?, spoil_percent?, durability?, ammo?}.
function M.put(inv, i, stack)
  local proxy = inv[i]
  records[proxy].set({ name = stack.name, count = stack.count, quality = quality_of(stack.quality),
    spoil_percent = stack.spoil_percent, durability = stack.durability, ammo = stack.ammo })
end

-- One stack per name of a {name = count} map (normal quality, sorted names).
function M.view(map, room)
  local function names()
    local list = {}
    for name, count in pairs(map) do if count > 0 then list[#list + 1] = name end end
    table.sort(list)
    return list
  end
  local bound = {}
  local function name_at(i)
    bound[i] = bound[i] or names()[i]
    return bound[i]
  end
  local function get(i)
    local name = name_at(i)
    if not name or (map[name] or 0) <= 0 then return nil end
    return { name = name, count = map[name], quality = "normal" }
  end
  local function set(i, rec)
    local name = name_at(i) or rec.name
    bound[i] = name
    map[name] = rec and rec.count or 0
  end
  local function capacity(name) return room and room(name) or math.huge end
  return inventory_proxy(function() bound = {}; return #names() end, get, set, {
    get_insertable_count = function(item) return capacity(type(item) == "string" and item or item.name) end,
    can_insert = function(items) return capacity(offered(items).name) > 0 end,
    is_empty = function() return #names() == 0 end,
    insert = function(items)
      local rec = offered(items)
      local k = math.max(0, math.min(rec.count, capacity(rec.name)))
      map[rec.name] = (map[rec.name] or 0) + k
      return k
    end,
  })
end

-- A view whose counts come from count_of(name) for the names listed, for a
-- fixture body that counts and removes by name: each change of a stack is
-- remove({name, count, quality}) of the difference (negative when a part
-- goes back onto it). A stub whose count ignores its removals (a constant)
-- is kept consistent within the view.
function M.counted(names, count_of, remove)
  local unseen = {}
  local function count(name) return count_of(name) - (unseen[name] or 0) end
  local map = setmetatable({}, {
    __index = function(_, name) return count(name) end,
    __newindex = function(_, name, value)
      local raw = count_of(name)
      local old = raw - (unseen[name] or 0)
      if value == old then return end
      remove({ name = name, count = old - value, quality = "normal" })
      unseen[name] = (unseen[name] or 0) + (old - value) - (raw - count_of(name))
    end,
    __pairs = function()
      local i = 0
      return function()
        i = i + 1
        if names[i] then return names[i], count(names[i]) end
      end
    end,
  })
  return M.view(map, function() return 0 end)
end

function M.create_inventory(size)
  M.created = M.created + 1
  return M.inventory(size)
end

function M.durability(...)
  local total = 0
  for _, stack in ipairs({ ... }) do
    if stack.valid_for_read then
      local full = M.max_durability[stack.name]
      total = total + (stack.count - 1) * full + stack.durability
    end
  end
  return total
end

M.assert_clean = api.assert_clean
return M
