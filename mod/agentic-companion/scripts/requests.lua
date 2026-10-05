-- set_requests {target:{x, y}, section?: index | group, mode?: "merge" | "set",
-- requests:[{item, min, max?, quality?}], remove?:[item], request_from_buffers?}:
-- what a requester or buffer chest asks the logistic robots for, written the
-- way its window does: into one manual logistic section (by index, by group
-- name, else the first manual section without a group, else a new one).
-- merge (default) updates an item's slot or takes the first free one; set
-- clears the section first; remove clears an item's slots. Sections the game
-- controls are never written. The body walks within reach; no items move:
-- only robots deliver, and the result says whether any network covers it.
-- Result: {target:{kind, name, position, surface}, sections:[{index, group, type,
-- active, items:[{item, quality, min, max?}]}], network?:{id,
-- in_logistic_range, logistic_robots_available}, notes?}.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")

local M = {}

local MAX_REQUESTS = 60
local REQUESTERS = { requester = true, buffer = true }

local function point(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

local function count_field(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

local function validate(step, label)
  if not point(step.target) then error(label .. " needs target = {x, y}", 0) end
  local section = step.section
  if section ~= nil and not (type(section) == "string" and section ~= "" or count_field(section) and section >= 1) then
    error(label .. " section must be a section index from 1 or a logistic group name", 0)
  end
  if step.mode ~= nil and step.mode ~= "merge" and step.mode ~= "set" then error(label .. ' mode must be "merge" or "set"', 0) end
  local requests = step.requests or {}
  if type(requests) ~= "table" or #requests > MAX_REQUESTS then
    error(string.format("%s requests must list at most %d {item, min, max?}", label, MAX_REQUESTS), 0)
  end
  local seen = {}
  for i, r in ipairs(requests) do
    local at = string.format("%s requests[%d]", label, i - 1)
    if type(r) ~= "table" or type(r.item) ~= "string" then error(at .. " must be {item, min, max?}", 0) end
    if not prototypes.item[r.item] then error(string.format("UNKNOWN_ITEM: %s: no item called '%s'", at, r.item), 0) end
    if not count_field(r.min) then error(at .. " min must be an integer from 0", 0) end
    if r.max ~= nil and not (count_field(r.max) and r.max >= r.min) then error(at .. " max must be an integer from min", 0) end
    if r.quality ~= nil and r.quality ~= "normal" then error(at .. ' quality must be "normal"', 0) end
    if r.import_from ~= nil or r.minimum_delivery_count ~= nil then
      error(at .. " import_from and minimum_delivery_count are for platform hubs", 0)
    end
    if seen[r.item] then error(at .. " repeats " .. r.item, 0) end
    seen[r.item] = true
  end
  if step.remove ~= nil then
    if type(step.remove) ~= "table" or #step.remove < 1 or #step.remove > MAX_REQUESTS then
      error(string.format("%s remove must list 1-%d item names", label, MAX_REQUESTS), 0)
    end
    for i, name in ipairs(step.remove) do
      if type(name) ~= "string" then error(string.format("%s remove[%d] must be an item name", label, i - 1), 0) end
    end
  end
  if step.request_from_buffers ~= nil and type(step.request_from_buffers) ~= "boolean" then
    error(label .. " request_from_buffers must be true or false", 0)
  end
  if #requests == 0 and step.remove == nil and step.request_from_buffers == nil and step.mode ~= "set" then
    error(label .. " needs requests, remove, request_from_buffers or mode set", 0)
  end
end

-- ----------------------------------------------------------------- reading

local function type_name(value)
  for name, v in pairs(defines.logistic_section_type) do if v == value then return name end end
  return tostring(value)
end

-- Item and quality of a slot's filter, or nil for an empty slot.
local function slot_item(filter)
  local value = type(filter) == "table" and filter.value
  if type(value) == "string" then return value, "normal" end
  if type(value) ~= "table" or (value.type ~= nil and value.type ~= "item") then return nil end
  local quality = value.quality
  if type(quality) == "table" then quality = quality.name end
  return value.name, quality or "normal"
end

local function section_row(section)
  local items = {}
  for i = 1, section.filters_count do
    local filter = section.get_slot(i)
    local item, quality = slot_item(filter)
    if item then
      items[#items + 1] = { item = item, quality = quality, min = filter.min or 0, max = filter.max,
        import_from = filter.import_from }
    end
  end
  return { index = section.index, group = section.group or "", type = type_name(section.type), active = section.active,
    items = items }
end

local function network_of(e)
  local net = e.logistic_network
  if not net then return nil end
  local cell = net.find_cell_closest_to(e.position)
  return { id = net.network_id, in_logistic_range = cell ~= nil and cell.is_in_logistic_range(e.position),
    logistic_robots_available = net.available_logistic_robots }
end

-- ----------------------------------------------------------------- writing

-- The manual section the step writes, or nil and the failure.
local function pick_section(sections, wanted)
  if type(wanted) == "number" then
    local section = sections.get_section(wanted)
    if not section then return nil, "NO_SECTION", string.format("there is no section %d (it has %d)", wanted, sections.sections_count) end
    if not section.is_manual then
      return nil, "NOT_MANUAL_SECTION", string.format("section %d is controlled by the game (%s)", wanted, type_name(section.type))
    end
    return section
  end
  for _, section in ipairs(sections.sections) do
    local group = section.group or ""
    if section.is_manual and (type(wanted) == "string" and group == wanted or wanted == nil and group == "") then
      return section
    end
  end
  local section = sections.add_section(wanted)
  if not section then return nil, "SECTION_NOT_ADDED", "the game added no section" end
  return section
end

local function filter_of(r)
  return { value = { type = "item", name = r.item, quality = r.quality or "normal", comparator = "=" }, min = r.min, max = r.max }
end

-- One read of the section's slots, then only the writes the step names.
local function apply(task, section)
  local removed = {}
  for _, name in ipairs(task.remove or {}) do removed[name] = true end
  local by_item, free, last = {}, {}, section.filters_count
  for i = 1, last do
    local item, quality = slot_item(section.get_slot(i))
    if item and (task.mode == "set" or removed[item]) then
      section.clear_slot(i)
      item = nil
    end
    if item then by_item[item .. "@" .. quality] = by_item[item .. "@" .. quality] or i else free[#free + 1] = i end
  end
  local next_free = 1
  for _, r in ipairs(task.requests) do
    local key = r.item .. "@" .. (r.quality or "normal")
    local index = by_item[key]
    if not index then
      index = free[next_free]
      if index then next_free = next_free + 1 else last = last + 1; index = last end
    end
    section.set_slot(index, filter_of(r))
    by_item[key] = index
  end
end

local Runner = {}

function Runner.start(task)
  companion.require_companion()
  validate(task, "set_requests")
end

local function failed(code, detail, e)
  return { status = "failed", detail = code .. ": " .. detail, outcome = { code = code,
    target = e and { kind = e.type, name = e.name, position = { x = e.position.x, y = e.position.y } } or nil } }
end

function Runner.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end
  local e = task._entity
  if not (e and e.valid) then e = approach.find_entity_near(c, task.target) end
  if not (e and e.valid and e.force == c.force) then
    return failed("NO_ENTITY", string.format("no own chest at (%.1f, %.1f)", task.target.x, task.target.y))
  end
  task._entity = e
  local entity_reached = approach.ensure_entity(task, c, e)
  if type(entity_reached) == "table" then return entity_reached end
  if entity_reached ~= "ok" then return nil end
  local mode = e.type == "logistic-container" and e.prototype.logistic_mode or nil
  if not REQUESTERS[mode] then
    return failed("NOT_A_REQUESTER", string.format("the %s requests nothing; requester and buffer chests do%s", e.name,
      mode == "storage" and " (a storage chest's filter is configure_entity chest.storage_filter)" or ""), e)
  end
  if task.request_from_buffers ~= nil and mode ~= "requester" then
    return failed("CONFIG_NOT_APPLICABLE", "only a requester chest requests from buffers", e)
  end
  local sections = e.get_logistic_sections()
  local section, code, why = pick_section(sections, task.section)
  if not section then return failed(code, why, e) end
  apply(task, section)
  if task.request_from_buffers ~= nil then e.request_from_buffers = task.request_from_buffers end
  local rows = {}
  for _, s in ipairs(sections.sections) do rows[#rows + 1] = section_row(s) end
  local network = network_of(e)
  local notes = not network and { "no roboport covers this point; nothing will be delivered" } or nil
  return { status = "done",
    detail = string.format("set_requests: the %s's section %d now asks for %d items%s", e.name, section.index,
      #section_row(section).items, notes and (" — " .. notes[1]) or ""),
    outcome = { code = "REQUESTS_SET",
      target = { kind = e.type, name = e.name, position = { x = e.position.x, y = e.position.y },
        surface = e.surface and e.surface.name or nil },
      sections = rows, network = network, request_from_buffers = mode == "requester" and e.request_from_buffers or nil,
      notes = notes } }
end

-- The plan action for tasks.register_action.
M.action = {
  runner = Runner,
  make_task = function(step)
    return { target = step.target, section = step.section, mode = step.mode or "merge", requests = step.requests or {},
      remove = step.remove, request_from_buffers = step.request_from_buffers }
  end,
  validate = function(step, index) validate(step, "queue_plan set_requests step " .. index) end,
}

return M
