-- Bot-set watches (set_watch, clear_watch): a role names a rate and is told
-- through next_event when it crosses a threshold, so nobody has to keep
-- reading factory_status to notice. Facts only: the mod compares the
-- numbers the role chose; it never chooses a threshold or says what to do.
--
-- Conditions (one per watch, on one surface):
--   rate_below                    the force's production of an item (all
--                                 qualities) or fluid on the surface, per
--                                 minute over the last minute, is below per_min
--   consumption_above_production  the force consumes more of it there than
--                                 it makes (per minute over the last minute)
--   line_below                    a factory line (autonomy.lua; by id, or
--                                 the position of a member machine or the
--                                 line's own) makes less than per_min
-- A watch arms once its value is on the safe side (a new watch whose value
-- is already past the threshold stays quiet until it is not), fires once
-- when crossed, and re-arms only after REARM_TICKS with the value at least
-- 10% clear of the threshold (production at least 1.1 times consumption).
--
-- Evaluated on the line sampler's evaluate tick (every SAMPLE_PERIOD
-- ticks), at most PER_SAMPLE watches a time from a cursor: a line watch
-- reads the sampler's kept rate (pure Lua), a force watch one or two
-- get_flow_count reads of the engine's own statistics. Nothing is scanned.
-- Firings go to a ring per role that event_state hands next_event.
local autonomy = require("scripts.autonomy")
local surfaces = require("scripts.surfaces")

local M = {}

M.MAX_PER_ROLE = 16
local PER_SAMPLE = 16
local RING = 16
local REARM_FACTOR, REARM_TICKS = 1.1, 3600
local KINDS = { rate_below = true, consumption_above_production = true, line_below = true }

local function data()
  storage.watches = storage.watches or { next_id = 1, list = {}, cursor = 1, fired = {}, fired_tick = {} }
  return storage.watches
end

local function round(value) return value and math.floor(value * 10 + 0.5) / 10 end

local function check_role(role)
  if type(role) ~= "string" or not role:match("^[a-z][a-z_]*$") or #role > 16 then
    error("WATCH_ROLE: role must be a session role name such as pilot or strategist", 0)
  end
  return role
end

-- The force's production statistics of a watch's item or fluid on its
-- surface, kept per force, surface and kind for one evaluate (cache).
local function statistics(watch, cache)
  local key = watch.force .. "|" .. watch.surface .. "|" .. (watch.fluid and "fluid" or "item")
  local found = cache and cache[key]
  if found == nil then
    local ok, value = pcall(function()
      local force, surface = game.forces[watch.force], game.get_surface(watch.surface)
      if not (force and surface) then return nil end
      if watch.fluid then return force.get_fluid_production_statistics(surface) end
      return force.get_item_production_statistics(surface)
    end)
    found = ok and value or false
    if cache then cache[key] = found end
  end
  return found or nil
end

-- Per minute over the last minute: "input" is what the force made, "output"
-- what it consumed; nil when it cannot be read. An item's flow is summed
-- over every quality: a plain name counts normal only, and a quality is
-- named inside name ({name, quality}; a separate quality field is ignored).
-- A fluid has none.
local function flow(watch, category, cache)
  local stats = statistics(watch, cache)
  if not stats then return nil end
  local function read(quality)
    local ok, value = pcall(function()
      local name = quality and { name = watch.item, quality = quality } or watch.item
      return stats.get_flow_count({ name = name, category = category,
        precision_index = defines.flow_precision_index.one_minute, count = false })
    end)
    return ok and type(value) == "number" and value or nil
  end
  if watch.fluid then return read(nil) end
  local ok, qualities = pcall(function() return prototypes.quality end)
  if not (ok and qualities) then return read(nil) end
  local total
  for quality in pairs(qualities) do
    local value = read(quality)
    if value then total = (total or 0) + value end
  end
  return total
end

-- A line watch's rate; a line id that is gone (lines merged or regrouped)
-- is found again through the member machine position it kept.
local function line_value(watch)
  local rate, surface, at = autonomy.line_rate(watch.line)
  if rate == nil and watch.at then
    local id = autonomy.line_at(watch.surface, watch.at, true)
    if id then
      watch.line = id
      rate, surface, at = autonomy.line_rate(id)
    end
  end
  if rate == nil then return nil end
  watch.surface, watch.at = surface or watch.surface, at or watch.at
  return rate
end

-- Reads a watch's value (and, for consumption_above_production, what was
-- made) onto it; returns whether the condition holds, or nil unread.
local function read(watch, cache)
  local value, made
  if watch.kind == "line_below" then value = line_value(watch)
  elseif watch.kind == "rate_below" then value = flow(watch, "input", cache)
  else made, value = flow(watch, "input", cache), flow(watch, "output", cache) end
  watch.value, watch.made = round(value), round(made)
  if value == nil or watch.kind == "consumption_above_production" and made == nil then return nil end
  if watch.kind == "consumption_above_production" then return value > made, made >= value * REARM_FACTOR end
  return value < watch.per_min, value >= watch.per_min * REARM_FACTOR
end

-- The condition as set_watch took it.
local function condition(watch)
  return { kind = watch.kind, item = watch.item, per_min = watch.per_min,
    line = watch.kind == "line_below" and watch.line or nil }
end

local function surface_ref(index)
  local surface = surfaces.by_index(index)
  return surface and surfaces.ref(surface) or nil
end

local function row(watch)
  return { id = watch.id, condition = condition(watch), surface = surface_ref(watch.surface), armed = watch.armed,
    value = watch.value, produced_per_min = watch.made, fired_tick = watch.fired_tick,
    line_gone = watch.kind == "line_below" and watch.value == nil and autonomy.line_rate(watch.line) == nil or nil }
end

local function fire(w, watch, tick)
  watch.armed, watch.fired_tick, watch.clear_since = false, tick, nil
  local ring = w.fired[watch.role] or {}
  w.fired[watch.role] = ring
  ring[#ring + 1] = { id = watch.id, condition = condition(watch), surface = surface_ref(watch.surface),
    value = watch.value, produced_per_min = watch.made, tick = tick }
  while #ring > RING do table.remove(ring, 1) end
  w.fired_tick[watch.role] = tick
end

-- One watch at the evaluate tick (see the header).
local function step(w, watch, tick, cache)
  local met, clear = read(watch, cache)
  if met == nil then watch.clear_since = nil; return end
  if watch.armed then
    if met then fire(w, watch, tick) end
    return
  end
  if not watch.fired_tick then
    -- Never fired: arms as soon as the condition does not hold.
    watch.armed = not met
    return
  end
  if not clear then watch.clear_since = nil
  elseif not watch.clear_since then watch.clear_since = tick
  elseif tick - watch.clear_since >= REARM_TICKS then watch.armed, watch.clear_since = true, nil end
end

local function evaluate(tick)
  local w = storage.watches
  local n = w and #w.list or 0
  if n == 0 then return end
  local start, cache = (w.cursor - 1) % n + 1, {}
  local count = math.min(n, PER_SAMPLE)
  for k = 0, count - 1 do
    local watch = w.list[(start + k - 1) % n + 1]
    local ok = pcall(step, w, watch, tick, cache)
    if not ok then watch.value, watch.clear_since = nil, nil end
  end
  w.cursor = (start + count - 1) % n + 1
end

-- Called every tick after the line sampler: works on its evaluate tick.
function M.on_tick(tick)
  if tick % autonomy.SAMPLE_PERIOD == autonomy.SAMPLE_PERIOD - 1 then evaluate(tick) end
end

local function of_role(w, role)
  local rows = {}
  for _, watch in ipairs(w.list) do if watch.role == role then rows[#rows + 1] = row(watch) end end
  return rows
end

-- set_watch {role, condition, surface?}: the watch (a new one, or the same
-- kind on the same item or line and surface with its new threshold, keeping
-- its id), read once now, and the role's watches.
function M.set(params)
  local w = data()
  local role = check_role(params.role)
  local c = params.condition
  if type(c) ~= "table" or not KINDS[c.kind] then
    error("WATCH_CONDITION: condition.kind must be rate_below, consumption_above_production or line_below", 0)
  end
  local per_min = tonumber(c.per_min)
  if c.kind ~= "consumption_above_production" and not (per_min and per_min > 0) then
    error("WATCH_CONDITION: " .. c.kind .. " needs per_min above 0", 0)
  end
  local target = surfaces.target(params.surface)
  local watch = { role = role, kind = c.kind, per_min = c.kind ~= "consumption_above_production" and per_min or nil,
    force = target.force.name, surface = target.surface.index }
  if c.kind == "line_below" then
    local id = type(c.line) == "number" and c.line or nil
    if id and not autonomy.line_rate(id) then id = nil end
    if not id and type(c.line) == "table" then id = autonomy.line_at(watch.surface, c.line) end
    if not id then
      error("WATCH_NO_LINE: no factory line " .. (type(c.line) == "table"
        and ("at (" .. tostring(c.line.x) .. ", " .. tostring(c.line.y) .. ") on " .. target.ref)
        or tostring(c.line)) .. "; factory_status lines give each line's id and position", 0)
    end
    local _, surface, at = autonomy.line_rate(id)
    watch.line, watch.surface, watch.at = id, surface or watch.surface, at
  else
    local item = c.item
    local is_item = type(item) == "string" and prototypes.item[item] ~= nil
    local is_fluid = not is_item and type(item) == "string" and prototypes.fluid[item] ~= nil
    if not (is_item or is_fluid) then error("WATCH_UNKNOWN_ITEM: no item or fluid named " .. tostring(item), 0) end
    watch.item, watch.fluid = item, is_fluid or nil
  end
  local same, count = nil, 0
  for _, other in ipairs(w.list) do
    if other.role == role then
      count = count + 1
      if other.kind == watch.kind and other.surface == watch.surface
        and (watch.kind == "line_below" and other.line == watch.line or watch.kind ~= "line_below" and other.item == watch.item) then
        same = other
      end
    end
  end
  if not same and count >= M.MAX_PER_ROLE then
    error("WATCH_LIMIT: " .. role .. " already has " .. M.MAX_PER_ROLE .. " watches; clear_watch one first", 0)
  end
  if same then
    for key, value in pairs(watch) do same[key] = value end
    same.armed, same.fired_tick, same.clear_since = false, nil, nil
    watch = same
  else
    watch.id, watch.armed = w.next_id, false
    w.next_id = w.next_id + 1
    w.list[#w.list + 1] = watch
  end
  local ok, met = pcall(read, watch)
  if ok and met ~= nil then watch.armed = not met end
  return { watch = row(watch), replaced = same ~= nil or nil, watches = of_role(w, role), limit = M.MAX_PER_ROLE }
end

-- clear_watch {role, id | all}: removes one of the role's watches, or all of
-- them; firings already made stay in the ring.
function M.clear(params)
  local w = data()
  local role = check_role(params.role)
  local id = tonumber(params.id)
  if not id and params.all ~= true then error("WATCH_CLEAR: give id or all: true", 0) end
  local kept, cleared = {}, {}
  for _, watch in ipairs(w.list) do
    if watch.role == role and (params.all == true or watch.id == id) then cleared[#cleared + 1] = watch.id
    else kept[#kept + 1] = watch end
  end
  if id and #cleared == 0 then error("WATCH_UNKNOWN: " .. role .. " has no watch " .. tostring(params.id), 0) end
  w.list, w.cursor = kept, 1
  return { cleared = cleared, watches = of_role(w, role), limit = M.MAX_PER_ROLE }
end

-- For event_state: the role's firings at or after since_tick, oldest first, or nil.
function M.fired_since(role, since_tick)
  local w = storage.watches
  local ring = w and type(role) == "string" and w.fired[role]
  since_tick = tonumber(since_tick)
  -- RCON commands run before the tick's on_tick, so a read at tick T has
  -- seen firings up to T - 1 only: a firing stamped since_tick is new.
  if not (ring and since_tick) or (w.fired_tick[role] or -1) < since_tick then return nil end
  local rows = {}
  for _, firing in ipairs(ring) do if firing.tick >= since_tick then rows[#rows + 1] = firing end end
  return rows
end

return M
