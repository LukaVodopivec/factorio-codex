-- set_requests {target:{x, y} | {platform}, section?: index | group, mode?: "merge" | "set",
-- requests:[{item, min, max?, quality?, import_from?, minimum_delivery_count?}], remove?:[item],
-- request_from_buffers?}: what a requester or buffer chest asks the logistic
-- robots for, what a cargo landing pad asks platforms in orbit to drop, or
-- what a platform hub keeps stocked, written the way its window does: into
-- one manual logistic section (by index, by group name, else the first manual
-- section without a group, else a new one). merge (default) updates an item's
-- slot or takes the first free one; set clears the section first; remove
-- clears an item's slots. Sections the game controls (a hub's missing
-- construction materials, a silo's transitional requests) are never written.
-- A chest or pad is on the body's planet: the body walks within reach. A hub
-- is remote (its platform's window, no body): it is written in the tick the
-- step runs, or at once over RPC. import_from (an unlocked planet) and
-- minimum_delivery_count are hub-only. No items move: robots and platforms
-- deliver, and a chest's result says whether any network covers it.
-- target "character" sets the body's own personal logistic requests (no
-- reach, wherever the body stands, once logistic robotics is researched),
-- with trash?:[item] (requests of at most 0, which robots carry away; needs
-- trash slots) and trash_unrequested? (the point's auto-trash).
-- Result: {target:{kind, name, position, surface, platform_name?}, sections:[{index, group, type,
-- active, items:[{item, quality, min, max?, import_from?, have?}]}], network?:{id,
-- in_logistic_range, logistic_robots_available}, notes?}.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local platforms = require("scripts.platforms")

local M = {}

local MAX_REQUESTS = 60
local REQUESTERS = { requester = true, buffer = true }
-- The inventory a target's `have` counts come from.
local STOCK_INVENTORY = { ["space-platform-hub"] = "hub_main", ["cargo-landing-pad"] = "cargo_landing_pad_main" }

local function point(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

local function count_field(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

local function hub_target(target)
  return type(target) == "table" and target.platform ~= nil
end

local function character_target(target) return target == "character" end

local function validate(step, label)
  local hub, character = hub_target(step.target), character_target(step.target)
  if hub then
    platforms.check_selector(step.target.platform, label .. " target.platform")
  elseif not (character or point(step.target)) then
    error(label .. ' needs target = {x, y} (a chest or landing pad), {platform} (its hub) or "character" (your own requests)', 0)
  end
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
    if not hub and (r.import_from ~= nil or r.minimum_delivery_count ~= nil) then
      error(at .. " import_from and minimum_delivery_count are for platform hubs", 0)
    end
    if r.import_from ~= nil and not (type(r.import_from) == "string" and prototypes.space_location[r.import_from]) then
      error(string.format("UNKNOWN_LOCATION: %s import_from names no planet or space location", at), 0)
    end
    if r.minimum_delivery_count ~= nil and not (count_field(r.minimum_delivery_count) and r.minimum_delivery_count >= 1) then
      error(at .. " minimum_delivery_count must be an integer from 1", 0)
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
  if step.request_from_buffers ~= nil and (hub or character or type(step.request_from_buffers) ~= "boolean") then
    error(label .. " request_from_buffers must be true or false, and only for a requester chest", 0)
  end
  if (step.trash ~= nil or step.trash_unrequested ~= nil) and not character then
    error(label .. ' trash and trash_unrequested are for target "character"', 0)
  end
  if step.trash ~= nil then
    if type(step.trash) ~= "table" or #step.trash < 1 or #step.trash + #requests > MAX_REQUESTS then
      error(string.format("%s trash must list 1-%d item names (with the requests)", label, MAX_REQUESTS), 0)
    end
    for i, name in ipairs(step.trash) do
      local at = string.format("%s trash[%d]", label, i - 1)
      if type(name) ~= "string" or not prototypes.item[name] then error(string.format("UNKNOWN_ITEM: %s: no item called '%s'", at, tostring(name)), 0) end
      if seen[name] then error(at .. " repeats " .. name .. " (an item is requested or trashed, not both)", 0) end
      seen[name] = true
    end
  end
  if step.trash_unrequested ~= nil and type(step.trash_unrequested) ~= "boolean" then
    error(label .. " trash_unrequested must be true or false", 0)
  end
  if #requests == 0 and step.remove == nil and step.request_from_buffers == nil and step.mode ~= "set"
    and step.trash == nil and step.trash_unrequested == nil then
    error(label .. " needs requests, remove, request_from_buffers, trash, trash_unrequested or mode set", 0)
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

local function location_name(value)
  if type(value) == "table" or type(value) == "userdata" then
    local ok, name = pcall(function() return value.name end)
    return ok and name or nil
  end
  return value
end

local function stock_of(entity)
  local id = STOCK_INVENTORY[entity.type]
  local ok, inventory = pcall(function() return id and entity.get_inventory(defines.inventory[id]) end)
  return ok and inventory or nil
end

-- A section's items; `have` counts the target's own stock (hub, pad). Also
-- the engine reads it took.
local function section_row(section, inventory)
  local items, reads = {}, 1
  for i = 1, section.filters_count do
    reads = reads + 1
    local filter = section.get_slot(i)
    local item, quality = slot_item(filter)
    if item then
      local row = { item = item, quality = quality, min = filter.min or 0, max = filter.max,
        import_from = location_name(filter.import_from) }
      if inventory then
        row.have = inventory.get_item_count({ name = item, quality = quality })
        reads = reads + 1
      end
      items[#items + 1] = row
    end
  end
  return { index = section.index, group = section.group or "", type = type_name(section.type), active = section.active,
    items = items }, reads
end

-- Every logistic section of an entity, read back ({} when it has none), and
-- the engine reads it took.
function M.read(entity)
  local ok, sections = pcall(entity.get_logistic_sections)
  local rows, reads = {}, 1
  if not (ok and sections) then return rows, reads end
  local inventory = stock_of(entity)
  for _, s in ipairs(sections.sections) do
    local row, n = section_row(s, inventory)
    rows[#rows + 1], reads = row, reads + n
  end
  return rows, reads
end

-- Items requested in the entity's manual sections (one filters read per
-- section), and the reads it took.
function M.count(entity)
  local ok, sections = pcall(entity.get_logistic_sections)
  local n, reads = 0, 1
  if not (ok and sections) then return n, reads end
  for _, s in ipairs(sections.sections) do
    reads = reads + 1
    if s.is_manual then
      reads = reads + 1
      for _, filter in pairs(s.filters) do if slot_item(filter) then n = n + 1 end end
    end
  end
  return n, reads
end

-- What a hub's active manual requests still lack: [{name, count}] in
-- request order, the hub's own stock subtracted. A request that imports from
-- another planet is not this planet's to send. The game's own sections
-- (missing construction materials) are left to it.
function M.unmet(hub, planet)
  local inventory = stock_of(hub)
  local ok, sections = pcall(hub.get_logistic_sections)
  local wanted, order = {}, {}
  for _, s in ipairs(ok and sections and sections.sections or {}) do
    if s.is_manual and s.active then
      for i = 1, s.filters_count do
        local filter = s.get_slot(i)
        local item, quality = slot_item(filter)
        local from = item and location_name(filter.import_from)
        if item and quality == "normal" and (filter.min or 0) > 0 and (from == nil or from == planet) then
          if not wanted[item] then wanted[item], order[#order + 1] = 0, item end
          wanted[item] = wanted[item] + filter.min
        end
      end
    end
  end
  local rows = {}
  for _, item in ipairs(order) do
    local have = inventory and inventory.get_item_count({ name = item, quality = "normal" }) or 0
    if wanted[item] > have then rows[#rows + 1] = { name = item, count = wanted[item] - have } end
  end
  return rows
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
  return { value = { type = "item", name = r.item, quality = r.quality or "normal", comparator = "=" }, min = r.min, max = r.max,
    import_from = r.import_from, minimum_delivery_count = r.minimum_delivery_count }
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

local function failed(code, detail, e)
  return { status = "failed", detail = code .. ": " .. detail, outcome = { code = code,
    target = e and { kind = e.type, name = e.name, position = { x = e.position.x, y = e.position.y } } or nil } }
end

-- Writes the step into the target (reach and kind already settled); the
-- step's result.
local function write(task, e, target)
  local sections = e.get_logistic_sections()
  if not sections then return failed("NO_SECTION", "the " .. e.name .. " has no logistic sections", e) end
  local section, code, why = pick_section(sections, task.section)
  if not section then return failed(code, why, e) end
  apply(task, section)
  if task.request_from_buffers ~= nil then e.request_from_buffers = task.request_from_buffers end
  local rows = M.read(e)
  local chest = e.type == "logistic-container"
  local network = chest and network_of(e) or nil
  local notes = chest and not network and { "no roboport covers this point; nothing will be delivered" } or nil
  local count = 0
  for _, row in ipairs(rows) do if row.index == section.index then count = #row.items end end
  return { status = "done",
    detail = string.format("set_requests: the %s's section %d now asks for %d items%s", e.name, section.index,
      count, notes and (" — " .. notes[1]) or ""),
    outcome = { code = "REQUESTS_SET", target = target, sections = rows, network = network,
      request_from_buffers = chest and e.prototype.logistic_mode == "requester" and e.request_from_buffers or nil,
      notes = notes } }
end

-- import_from must name a planet the force has unlocked
-- (platforms.location_unlocked: the engine's answer when it gives a
-- boolean, else the researched discovery technologies).
local function locked_import(force, task)
  for _, r in ipairs(task.requests) do
    if r.import_from ~= nil and not platforms.location_unlocked(force, r.import_from) then return r.import_from end
  end
end

-- A platform hub: remote, in this tick.
local function write_hub(task, force)
  local p, code, why = platforms.resolve(force, task.target.platform)
  if not p then return failed(code, why) end
  local hub = p.hub
  if not (hub and hub.valid) then
    return failed("NO_HUB", string.format("platform %s has no hub yet: launch its starter pack first", p.name))
  end
  local location = locked_import(force, task)
  if location then return failed("LOCATION_LOCKED", "import_from " .. location .. " is not unlocked yet", hub) end
  local target = { kind = hub.type, name = hub.name, position = { x = hub.position.x, y = hub.position.y },
    surface = platforms.surface_ref(p), platform_name = p.name }
  return write(task, hub, target)
end

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

-- The body's own requester point: no reach. Trash entries are requests of
-- at most 0. Personal requests need the force's logistic robotics research
-- (set_slot does nothing without it), trash its trash slots.
local function write_character(task, c)
  local force = c.force
  if read(function() return force.character_logistic_requests end) ~= true then
    return failed("LOGISTICS_NOT_RESEARCHED", "personal logistic requests need logistic robotics researched first")
  end
  if task.trash and (tonumber(read(function() return force.character_trash_slot_count end)) or 0) <= 0 then
    return failed("LOGISTICS_NOT_RESEARCHED", "trash needs trash slots (logistic robotics research) first")
  end
  local requester = read(function() return c.get_requester_point() end)
  if not requester then return failed("NO_REQUESTER_POINT", "the body has no personal logistic point") end
  local section, code, why = pick_section(requester, task.section)
  if not section then return failed(code, why) end
  local rows = {}
  for _, r in ipairs(task.requests) do rows[#rows + 1] = r end
  for _, name in ipairs(task.trash or {}) do rows[#rows + 1] = { item = name, min = 0, max = 0 } end
  apply({ mode = task.mode, remove = task.remove, requests = rows }, section)
  if task.trash_unrequested ~= nil then requester.trash_not_requested = task.trash_unrequested end
  local sections = {}
  for _, s in ipairs(requester.sections) do sections[#sections + 1] = (section_row(s)) end
  local network = requester.logistic_network
  local count = 0
  for _, row in ipairs(sections) do if row.index == section.index then count = #row.items end end
  local notes = not network and { "no roboport network covers the body; nothing is delivered until one does" } or nil
  return { status = "done",
    detail = string.format("set_requests: your own section %d now holds %d requests%s", section.index, count,
      notes and (" — " .. notes[1]) or ""),
    outcome = { code = "REQUESTS_SET", target = { kind = "character", name = c.name, surface = companion.surface_ref(c.surface) },
      sections = sections, trash_unrequested = requester.trash_not_requested, enabled = requester.enabled,
      network = network and { id = network.network_id, logistic_robots_available = network.available_logistic_robots } or nil,
      notes = notes } }
end

local Runner = {}

-- A hub target needs only a connected body (aboard or in transit too); a
-- chest, a landing pad and the body's own requests need the character.
function Runner.start(task)
  if hub_target(task.target) then companion.require_present() else companion.require_companion() end
  validate(task, "set_requests")
end

function Runner.tick(task)
  if hub_target(task.target) then return write_hub(task, companion.require_present().force) end
  if character_target(task.target) then
    local c = companion.get()
    if not c then return { status = "failed", detail = "the companion character is gone" } end
    return write_character(task, c)
  end
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end
  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end
  local e = task._entity
  if not (e and e.valid) then e = approach.find_entity_near(c, task.target) end
  if not (e and e.valid and e.force == c.force) then
    return failed("NO_ENTITY", string.format("no own chest or landing pad at (%.1f, %.1f)", task.target.x, task.target.y))
  end
  task._entity = e
  local entity_reached = approach.ensure_entity(task, c, e)
  if type(entity_reached) == "table" then return entity_reached end
  if entity_reached ~= "ok" then return nil end
  if e.type == "rocket-silo" then
    return failed("NOT_MANUAL_SECTION", "a rocket silo's requests are controlled by the game (transitional requests);"
      .. " configure_entity silo.auto_requests turns them on or off", e)
  end
  local pad = e.type == "cargo-landing-pad"
  local mode = e.type == "logistic-container" and e.prototype.logistic_mode or nil
  if not (pad or REQUESTERS[mode]) then
    return failed("NOT_A_REQUESTER", string.format("the %s requests nothing; requester and buffer chests and landing pads do%s",
      e.name, mode == "storage" and " (a storage chest's filter is configure_entity chest.storage_filter)" or ""), e)
  end
  if task.request_from_buffers ~= nil and mode ~= "requester" then
    return failed("CONFIG_NOT_APPLICABLE", "only a requester chest requests from buffers", e)
  end
  return write(task, e, { kind = e.type, name = e.name, position = { x = e.position.x, y = e.position.y },
    surface = e.surface and e.surface.name or nil })
end

-- The plan action for tasks.register_action. A hub target is remote: no
-- body, no reach, done in the tick the FIFO reaches it. The body's own
-- requests need no reach either; neither carries a surface tag.
local function make_task(step)
  return { target = step.target, section = step.section, mode = step.mode or "merge", requests = step.requests or {},
    remove = step.remove, request_from_buffers = step.request_from_buffers, trash = step.trash,
    trash_unrequested = step.trash_unrequested }
end
M.action = {
  runner = Runner,
  make_task = make_task,
  validate = function(step, index) validate(step, "queue_plan set_requests step " .. index) end,
  remote = function(step) return hub_target(step.target) or character_target(step.target) end,
}

-- set_requests over RPC: a hub's requests, or the body's own, at once (no
-- reach). A chest or landing pad needs the body: a plan step.
function M.rpc(params)
  local body = companion.require_present()
  if type(params) ~= "table" or not (hub_target(params.target) or character_target(params.target)) then
    error("set_requests over RPC writes a platform hub's requests ({platform}) or your own (\"character\"); a chest or"
      .. " landing pad needs the body: queue it as a plan step", 0)
  end
  validate(params, "set_requests")
  if character_target(params.target) then
    local result = write_character(make_task(params), companion.require_companion())
    if result.status ~= "done" then error(result.detail, 0) end
    return result.outcome
  end
  local result = write_hub(make_task(params), body.force)
  if result.status ~= "done" then error(result.detail, 0) end
  return result.outcome
end

-- platform_status reads hub requests through this module.
platforms.set_requests_reader(M)

return M
