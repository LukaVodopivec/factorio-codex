-- Entity settings: what a player sets in an entity's window, as the one
-- Settings object of configure_entity, build_layout entities,
-- build_plan steps, move_entity and blueprints:
--   { inserter?: {filters?: [item] (at most 5; [] clears), mode?: whitelist|blacklist,
--                 stack_size?: int >= 0 (0 = the game's default), spoil_priority?: fresh_first|spoiled_first|none},
--     splitter?: {input_priority?, output_priority?: left|none|right, filter?: item | false},
--     chest?:    {slots?: int >= 0 | false (usable slots; false removes the limit), storage_filter?: item | false},
--     collector?: {filters?: [asteroid chunk] ([] clears)},
--     silo?:     {auto_requests?: boolean} }
-- false is "none" (a Lua table cannot hold JSON null). validate checks the
-- shape and item names; check says whether an entity takes them, before
-- any write; apply writes only what differs and reads it back; read is
-- what an entity has set (non-default values only). Nothing here touches a
-- cursor, a GUI or a player.
local M = {}

local GROUP_ORDER = { "inserter", "splitter", "chest", "collector", "silo" }
local FIELDS = { inserter = { "filters", "mode", "stack_size", "spoil_priority" },
  splitter = { "input_priority", "output_priority", "filter" }, chest = { "slots", "storage_filter" },
  collector = { "filters" }, silo = { "auto_requests" } }
-- The entity type each group (other than splitter and chest) belongs to.
local GROUP_TYPE = { inserter = "inserter", collector = "asteroid-collector", silo = "rocket-silo" }
local MODES = { whitelist = true, blacklist = true }
local SPOIL = { fresh_first = true, spoiled_first = true, none = true }
local SIDES = { left = true, none = true, right = true }
local SPLITTERS = { splitter = true, ["lane-splitter"] = true }
local CHESTS = { container = true, ["logistic-container"] = true }
local MAX_FILTERS = 5

local function fail(code, text) error(code .. ": " .. text, 0) end
local function plain(err) return (tostring(err):gsub("^.-:%d+:%s*", "")) end

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

-- An item name from an ItemFilter, an ItemIDAndQualityIDPair or a string.
local function filter_name(filter)
  if type(filter) == "string" then return filter end
  if type(filter) == "userdata" then return read(function() return filter.name end) end
  if type(filter) ~= "table" then return nil end
  local name = filter.name
  if type(name) == "table" then name = name.name end
  return type(name) == "string" and name or nil
end

local function chest_inventory(e)
  local ok, inventory = pcall(e.get_inventory, defines.inventory.chest)
  return ok and inventory or nil
end

local function is_list(value)
  if type(value) ~= "table" then return false end
  local n = 0
  for _ in pairs(value) do n = n + 1 end
  return n == #value
end

local function same(a, b)
  if type(a) == "table" and type(b) == "table" then
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
  end
  return a == b
end

-- ------------------------------------------------------------- validation

local function item_name(label, value)
  if type(value) ~= "string" or value == "" then fail("CONFIG_INVALID", label .. " must be an item name") end
  if not prototypes.item[value] then fail("UNKNOWN_ITEM", label .. ": no item called '" .. value .. "'") end
end

local function count_field(label, value)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    fail("CONFIG_INVALID", label .. " must be an integer from 0")
  end
end

-- Raises CONFIG_INVALID or UNKNOWN_ITEM on a malformed Settings object.
function M.validate(settings, label)
  if type(settings) ~= "table" or next(settings) == nil then
    fail("CONFIG_INVALID", label .. " needs at least one of inserter, splitter, chest, collector or silo")
  end
  for group, value in pairs(settings) do
    local fields = FIELDS[group]
    if not fields then
      fail("CONFIG_INVALID", string.format("%s has no setting group '%s' (%s)", label, tostring(group),
        table.concat(GROUP_ORDER, ", ")))
    end
    if type(value) ~= "table" or next(value) == nil then
      fail("CONFIG_INVALID", string.format("%s.%s must name at least one of %s", label, group, table.concat(fields, ", ")))
    end
    for key in pairs(value) do
      local known = false
      for _, field in ipairs(fields) do known = known or field == key end
      if not known then
        fail("CONFIG_INVALID", string.format("%s.%s has no setting '%s' (%s)", label, group, tostring(key),
          table.concat(fields, ", ")))
      end
    end
  end
  local i = settings.inserter
  if i then
    if i.filters ~= nil then
      if not is_list(i.filters) or #i.filters > MAX_FILTERS then
        fail("CONFIG_INVALID", label .. ".inserter.filters must list at most 5 item names ([] clears them)")
      end
      for k, name in ipairs(i.filters) do item_name(string.format("%s.inserter.filters[%d]", label, k - 1), name) end
    end
    if i.mode ~= nil and not MODES[i.mode] then fail("CONFIG_INVALID", label .. '.inserter.mode must be "whitelist" or "blacklist"') end
    if i.stack_size ~= nil then count_field(label .. ".inserter.stack_size", i.stack_size) end
    if i.spoil_priority ~= nil and not SPOIL[i.spoil_priority] then
      fail("CONFIG_INVALID", label .. '.inserter.spoil_priority must be "fresh_first", "spoiled_first" or "none"')
    end
  end
  local s = settings.splitter
  if s then
    for _, side in ipairs({ "input_priority", "output_priority" }) do
      if s[side] ~= nil and not SIDES[s[side]] then
        fail("CONFIG_INVALID", string.format('%s.splitter.%s must be "left", "none" or "right"', label, side))
      end
    end
    if s.filter ~= nil and s.filter ~= false then item_name(label .. ".splitter.filter", s.filter) end
  end
  local c = settings.chest
  if c then
    if c.slots ~= nil and c.slots ~= false then count_field(label .. ".chest.slots", c.slots) end
    if c.storage_filter ~= nil and c.storage_filter ~= false then item_name(label .. ".chest.storage_filter", c.storage_filter) end
  end
  local a = settings.collector
  if a and a.filters ~= nil then
    if not is_list(a.filters) then fail("CONFIG_INVALID", label .. ".collector.filters must list asteroid chunk names ([] clears them)") end
    local seen = {}
    for k, name in ipairs(a.filters) do
      local at = string.format("%s.collector.filters[%d]", label, k - 1)
      if type(name) ~= "string" or name == "" then fail("CONFIG_INVALID", at .. " must be an asteroid chunk name") end
      if not read(function() return prototypes.asteroid_chunk[name] end) then
        fail("UNKNOWN_CHUNK", at .. ": no asteroid chunk called '" .. name .. "'")
      end
      if seen[name] then fail("CONFIG_INVALID", at .. " repeats " .. name) end
      seen[name] = true
    end
  end
  local r = settings.silo
  if r and r.auto_requests ~= nil and type(r.auto_requests) ~= "boolean" then
    fail("CONFIG_INVALID", label .. ".silo.auto_requests must be true or false")
  end
end

-- ---------------------------------------------------------- applicability

-- What a {type, filter_count, logistic_mode} cannot take, or nil. A
-- collector's filter count is known only on the standing entity.
local function refusal(facts, settings)
  for _, group in ipairs(GROUP_ORDER) do
    local kind = GROUP_TYPE[group]
    if kind and settings[group] and facts.type ~= kind then return group .. " settings" end
  end
  local i = settings.inserter
  if i and (i.filters ~= nil or i.mode ~= nil) and (tonumber(facts.filter_count) or 0) == 0 then
    return "inserter filters (it has no filter slots)"
  end
  local a = settings.collector
  if a and a.filters and facts.filter_slots and #a.filters > facts.filter_slots then
    return string.format("%d chunk filters (it has %d filter slots)", #a.filters, facts.filter_slots)
  end
  if settings.splitter and not SPLITTERS[facts.type] then return "splitter settings" end
  local c = settings.chest
  if c then
    if not CHESTS[facts.type] then return "chest settings" end
    if c.storage_filter ~= nil and facts.logistic_mode ~= "storage" then return "a storage filter (only a storage chest has one)" end
  end
end

local function not_applicable(name, kind, what)
  return "CONFIG_NOT_APPLICABLE", string.format("CONFIG_NOT_APPLICABLE: the %s (%s) takes no %s", name, kind, what)
end

-- For a layout entity before it is built: code, message or nil.
function M.check_prototype(proto, settings)
  local what = refusal({ type = proto.type, filter_count = read(function() return proto.filter_count end),
    logistic_mode = read(function() return proto.logistic_mode end) }, settings)
  if what then return not_applicable(proto.name, proto.type, what) end
end

-- For a standing entity, before any write: code, message or nil.
function M.check(e, settings)
  local slots_count = read(function() return e.filter_slot_count end)
  local what = refusal({ type = e.type, filter_count = slots_count, filter_slots = slots_count,
    logistic_mode = read(function() return e.prototype.logistic_mode end) }, settings)
  if what then return not_applicable(e.name, e.type, what) end
  local slots = settings.chest and settings.chest.slots
  if slots ~= nil then
    local inventory = chest_inventory(e)
    if not (inventory and read(function() return inventory.supports_bar() end)) then
      return not_applicable(e.name, e.type, "slot limit")
    end
    if slots ~= false and slots > #inventory then
      return "SLOTS_OUT_OF_RANGE", string.format("SLOTS_OUT_OF_RANGE: the %s has %d slots; slots must be 0-%d",
        e.name, #inventory, #inventory)
    end
  end
end

-- ----------------------------------------------------------------- reading

-- Every setting of the groups this entity has, defaults included.
function M.current(e)
  local out = {}
  if e.type == "inserter" then
    local i = { stack_size = read(function() return e.inserter_stack_size_override end) or 0,
      spoil_priority = read(function() return e.inserter_spoil_priority end) or "none" }
    local slots = read(function() return e.filter_slot_count end) or 0
    if slots > 0 then
      local names = {}
      if read(function() return e.use_filters end) == true then
        for index = 1, slots do
          local name = filter_name(read(function() return e.get_filter(index) end))
          if name then names[#names + 1] = name end
        end
      end
      i.filters, i.mode = names, read(function() return e.inserter_filter_mode end) or "whitelist"
    end
    out.inserter = i
  elseif SPLITTERS[e.type] then
    out.splitter = { input_priority = read(function() return e.splitter_input_priority end) or "none",
      output_priority = read(function() return e.splitter_output_priority end) or "none",
      filter = filter_name(read(function() return e.splitter_filter end)) or false }
  elseif CHESTS[e.type] then
    local chest = {}
    local inventory = chest_inventory(e)
    if inventory and read(function() return inventory.supports_bar() end) then
      local bar = read(function() return inventory.get_bar() end)
      chest.slots = type(bar) == "number" and bar <= #inventory and bar - 1 or false
    end
    if e.type == "logistic-container" and read(function() return e.prototype.logistic_mode end) == "storage" then
      chest.storage_filter = filter_name(read(function() return e.storage_filter end)) or false
    end
    if next(chest) then out.chest = chest end
  elseif e.type == "asteroid-collector" then
    local names = {}
    for index = 1, read(function() return e.filter_slot_count end) or 0 do
      local name = filter_name(read(function() return e.get_filter(index) end))
      if name then names[#names + 1] = name end
    end
    out.collector = { filters = names }
  elseif e.type == "rocket-silo" then
    out.silo = { auto_requests = read(function() return e.use_transitional_requests end) == true }
  end
  return out
end

local DEFAULTS = { mode = "whitelist", stack_size = 0, spoil_priority = "none", input_priority = "none",
  output_priority = "none", filter = false, slots = false, storage_filter = false, auto_requests = false }

-- The settings an entity has (non-default values only), or nil.
function M.read(e)
  local out, any = {}, false
  for group, values in pairs(M.current(e)) do
    local kept = {}
    for field, value in pairs(values) do
      local default = field == "filters" and {} or DEFAULTS[field]
      if not same(value, default) then kept[field] = value end
    end
    if next(kept) then out[group], any = kept, true end
  end
  return any and out or nil
end

-- The current values of the fields settings names.
function M.readback(e, settings)
  local now, out = M.current(e), {}
  for _, group in ipairs(GROUP_ORDER) do
    if settings[group] then
      out[group] = {}
      for field in pairs(settings[group]) do
        if now[group] and now[group][field] ~= nil then out[group][field] = now[group][field] end
      end
    end
  end
  return out
end

-- ----------------------------------------------------------------- writing

local WRITERS = {
  inserter = {
    filters = function(e, names)
      for index = 1, e.filter_slot_count do e.set_filter(index, names[index]) end
      e.use_filters = #names > 0
    end,
    mode = function(e, value) e.inserter_filter_mode = value end,
    stack_size = function(e, value) e.inserter_stack_size_override = value end,
    spoil_priority = function(e, value) e.inserter_spoil_priority = value end,
  },
  splitter = {
    input_priority = function(e, value) e.splitter_input_priority = value end,
    output_priority = function(e, value) e.splitter_output_priority = value end,
    filter = function(e, name) e.splitter_filter = name and { name = name } or nil end,
  },
  chest = {
    slots = function(e, slots)
      local inventory = chest_inventory(e)
      if slots then inventory.set_bar(slots + 1) else inventory.set_bar() end
    end,
    storage_filter = function(e, name) e.storage_filter = name and { name = name, quality = "normal" } or nil end,
  },
  collector = {
    filters = function(e, names)
      for index = 1, e.filter_slot_count do e.set_filter(index, names[index]) end
    end,
  },
  silo = {
    auto_requests = function(e, value) e.use_transitional_requests = value end,
  },
}

-- 0.21.1 kept blueprint fields as settings (build_layout entities,
-- build_plan steps, move_entity snapshots); a plan saved then still holds them.
local function legacy(s)
  for _, group in ipairs(GROUP_ORDER) do
    if s[group] ~= nil then return false end
  end
  return true
end
M.legacy = legacy

-- Writes settings onto an entity. Returns the fields that changed (as
-- "group.field"), notes, and the refusal code when the entity takes none of
-- it (nothing written then). A field the game does not keep is a note.
function M.apply(e, settings)
  if type(settings) ~= "table" or not e.valid then return {}, {} end
  local notes = {}
  if legacy(settings) then
    if settings.mirror ~= nil and not pcall(function() e.mirroring = settings.mirror == true end) then
      notes[#notes + 1] = "couldn't mirror the " .. e.name
    end
    settings = M.from_blueprint(settings, e.type, true)
    if not settings then return {}, notes end
  end
  local code, message = M.check(e, settings)
  if code then return {}, { message }, code end
  local now = M.current(e)
  local want = {}
  for _, group in ipairs(GROUP_ORDER) do
    if settings[group] then
      want[group] = {}
      for field, value in pairs(settings[group]) do want[group][field] = value end
    end
  end
  local split = want.splitter
  if split and split.filter and (split.output_priority or now.splitter.output_priority) == "none" then
    split.output_priority = "left"
    notes[#notes + 1] = "a splitter filter needs an output side: output_priority is left"
  end
  local changed = {}
  for _, group in ipairs(GROUP_ORDER) do
    for _, field in ipairs(FIELDS[group]) do
      local value = want[group] and want[group][field]
      if value ~= nil and not same(value, now[group] and now[group][field]) then
        local ok, err = pcall(WRITERS[group][field], e, value)
        if ok then changed[#changed + 1] = group .. "." .. field
        else notes[#notes + 1] = string.format("couldn't set %s.%s on the %s: %s", group, field, e.name, plain(err)) end
      end
    end
  end
  -- Read back: what the game did not keep is not a change.
  local after, kept = M.current(e), {}
  for _, path in ipairs(changed) do
    local group, field = path:match("^(%a+)%.([%a_]+)$")
    if same(want[group][field], after[group] and after[group][field]) then kept[#kept + 1] = path
    else notes[#notes + 1] = string.format("the %s kept its %s", e.name, path) end
  end
  return kept, notes
end

-- -------------------------------------------------------------- blueprints

local SPOIL_TO_BLUEPRINT = { fresh_first = "fresh-first", spoiled_first = "spoiled-first" }
local SPOIL_FROM_BLUEPRINT = { ["fresh-first"] = "fresh_first", ["spoiled-first"] = "spoiled_first" }

-- Settings as BlueprintEntity fields on row (for an entity of type kind).
function M.to_blueprint(settings, row, kind)
  local i = settings.inserter
  if i and kind == "inserter" then
    if i.filters then
      local filters = {}
      for index, name in ipairs(i.filters) do filters[index] = { index = index, name = name, quality = "normal", comparator = "=" } end
      row.filters, row.use_filters = #filters > 0 and filters or nil, #filters > 0 or nil
    end
    if i.mode == "blacklist" then row.filter_mode = "blacklist" end
    if i.stack_size and i.stack_size > 0 then row.override_stack_size = i.stack_size end
    row.spoil_priority = SPOIL_TO_BLUEPRINT[i.spoil_priority]
  end
  local s = settings.splitter
  if s and SPLITTERS[kind] then
    row.input_priority = s.input_priority ~= "none" and s.input_priority or nil
    row.output_priority = s.output_priority ~= "none" and s.output_priority or nil
    if s.filter then
      row.filter = { name = s.filter, quality = "normal", comparator = "=" }
      row.output_priority = row.output_priority or "left"
    end
  end
  local c = settings.chest
  if c and CHESTS[kind] then
    if c.slots then row.bar = c.slots end
    if c.storage_filter then row.filters = { { index = 1, name = c.storage_filter, quality = "normal", comparator = "=" } } end
  end
  local a = settings.collector
  if a and a.filters and kind == "asteroid-collector" then
    local filters = {}
    for index, name in ipairs(a.filters) do filters[index] = { index = index, name = name } end
    row["chunk-filter"] = #filters > 0 and filters or nil
  end
  local r = settings.silo
  if r and r.auto_requests ~= nil and kind == "rocket-silo" then row.use_transitional_requests = r.auto_requests end
  return row
end

-- A blueprint entity's (or a 0.21.1 settings table's) fields as Settings for
-- an entity of type kind, or nil. A 0.21.1 bar is the inventory's bar index;
-- a blueprint's is the number of usable slots.
function M.from_blueprint(bp, kind, old_bar)
  local out = {}
  local names = {}
  local rows = {}
  for _, f in ipairs(type(bp.filters) == "table" and bp.filters or {}) do rows[#rows + 1] = f end
  table.sort(rows, function(a, b) return (tonumber(a.index) or 0) < (tonumber(b.index) or 0) end)
  for _, f in ipairs(rows) do
    local name = filter_name(f)
    if name then names[#names + 1] = name end
  end
  if kind == "inserter" then
    local i = {}
    -- Filters count only when switched on: a blueprint (and 0.21.1) omits
    -- use_filters when they are off.
    if bp.use_filters == true and #names > 0 then i.filters = names end
    if bp.filter_mode == "blacklist" then i.mode = "blacklist" end
    if tonumber(bp.override_stack_size) and bp.override_stack_size > 0 then i.stack_size = bp.override_stack_size end
    i.spoil_priority = SPOIL_FROM_BLUEPRINT[bp.spoil_priority]
    if next(i) then out.inserter = i end
  elseif SPLITTERS[kind] then
    local s = {}
    if SIDES[bp.input_priority] and bp.input_priority ~= "none" then s.input_priority = bp.input_priority end
    if SIDES[bp.output_priority] and bp.output_priority ~= "none" then s.output_priority = bp.output_priority end
    s.filter = filter_name(bp.filter)
    if next(s) then out.splitter = s end
  elseif CHESTS[kind] then
    local c = {}
    local bar = tonumber(bp.bar)
    if bar then c.slots = math.max(0, old_bar and bar - 1 or bar) end
    local proto = type(bp.name) == "string" and prototypes.entity[bp.name]
    if names[1] and proto and read(function() return proto.logistic_mode end) == "storage" then c.storage_filter = names[1] end
    if next(c) then out.chest = c end
  elseif kind == "asteroid-collector" then
    local chunks = {}
    for _, f in ipairs(type(bp["chunk-filter"]) == "table" and bp["chunk-filter"] or {}) do chunks[#chunks + 1] = f end
    table.sort(chunks, function(a, b) return (tonumber(a.index) or 0) < (tonumber(b.index) or 0) end)
    local list = {}
    for _, f in ipairs(chunks) do if type(f.name) == "string" then list[#list + 1] = f.name end end
    if #list > 0 then out.collector = { filters = list } end
  elseif kind == "rocket-silo" then
    if bp.use_transitional_requests == true then out.silo = { auto_requests = true } end
  end
  return next(out) and out or nil
end

return M
