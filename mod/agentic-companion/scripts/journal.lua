-- The change journal and own entity losses, both kept from events the mod
-- already receives (no entity is searched for):
--   journal  a fixed ring of the last SIZE changes to own entities: built,
--            removed, rotated, changed or died, each naming who did it (by:
--            the running plan's source, pilot, package:<id> or upkeep, with
--            its plan_id; pilot for a direct tool; human for a player's own
--            input; robot; platform; script for another script; for a died
--            row what killed it). Consecutive rows of the same op, name and
--            actor merge into one with a count and the area they cover.
--   losses   a ring of the last LOSS_SIZE own entity deaths (merged the same
--            way within MERGE_TICKS), with what killed it when the game
--            names it; next_event's entities_lost and factory_status's
--            destroyed problem rows read it.
-- Rows keep the surface index; reads name the surface.
local companion = require("scripts.companion")
local surfaces = require("scripts.surfaces")

local M = {}

M.SIZE = 200
M.LOSS_SIZE = 16
-- Rows merge only with one of the newest few, and without a plan only
-- within this many ticks of its last change.
M.MERGE_TICKS = 600
local MERGE_BACK = 3
M.MAX_CHANGES = 64 -- rows one read returns at most
-- factory_status shows losses this recent without since_tick.
M.LOSS_WINDOW_TICKS = 5 * 3600
M.SHOWN_LOSSES = 4 -- the newest losses event_state carries

-- A ring {rows, n}: slot (n - 1) % size + 1 holds the newest of n written.
local function push(ring, size, row)
  ring.n = ring.n + 1
  ring.rows[(ring.n - 1) % size + 1] = row
end
-- The row `back` places before the newest (0: the newest), or nil.
local function get(ring, size, back)
  if back >= math.min(ring.n, size) then return nil end
  return ring.rows[(ring.n - 1 - back) % size + 1]
end

-- A merge moves a row's tick forward, so reads order rows (given oldest
-- slot first, at most a ring's size) by tick, keeping slot order on a tie.
local function by_tick(rows)
  local slot = {}
  for index, row in ipairs(rows) do slot[row] = index end
  table.sort(rows, function(a, b) return a.tick < b.tick or a.tick == b.tick and slot[a] < slot[b] end)
  return rows
end

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

-- Who runs now: the active plan's source and id, or pilot for a direct task.
local function running()
  local active = storage.tasks and storage.tasks.active
  if not active then return nil end
  if active.type == "plan" then return active.source or "pilot", active.id end
  return "pilot"
end

-- Who made the change an event reports: by, plan_id. The mod never builds,
-- mines or rotates through a player's cursor, so a player event is a
-- human's, except the Codex body's own mining while a plan or task runs and
-- no human holds the body.
function M.actor(event)
  if event.player_index then
    local rec = storage.companion
    if rec and rec.player_index == event.player_index then
      local ok, held = pcall(companion.human_control)
      if ok and held ~= true then
        local by, plan_id = running()
        if by then return by, plan_id end
      end
    end
    return "human"
  end
  if event.robot then return "robot" end
  if event.platform then return "platform" end
  local by, plan_id = running()
  if by then return by, plan_id end
  return "script"
end

-- The own force's name as the registry keeps it (no engine read).
local function own_force()
  return storage.registry and storage.registry.force or "player"
end

local function grow(row, position)
  row.l, row.t = math.min(row.l, position.x), math.min(row.t, position.y)
  row.r, row.b = math.max(row.r, position.x), math.max(row.b, position.y)
end

-- Adds one change. name or action says what changed (action: the plan step
-- that changed it, when no event names the entity).
function M.note(op, name, position, surface_index, by, plan_id, action)
  local ring = storage.journal
  if not (ring and position) then return end
  local tick = game.tick
  for back = 0, MERGE_BACK - 1 do
    local row = get(ring, M.SIZE, back)
    if not row then break end
    if row.op == op and row.name == name and row.action == action and row.by == by and row.plan_id == plan_id
      and row.s == surface_index and (plan_id ~= nil or tick - row.tick <= M.MERGE_TICKS) then
      grow(row, position)
      row.count, row.tick = row.count + 1, tick
      return
    end
  end
  push(ring, M.SIZE, { tick = tick, op = op, name = name, action = action, by = by, plan_id = plan_id,
    s = surface_index, l = position.x, t = position.y, r = position.x, b = position.y, count = 1 })
end

-- Records an own entity an event built, removed, rotated or changed.
local SKIPPED = { ["entity-ghost"] = true, ["tile-ghost"] = true }
function M.record(op, entity, event)
  local ok, name, kind, position, surface = pcall(function()
    return entity.name, entity.type, entity.position, entity.surface.index
  end)
  if not ok or SKIPPED[kind] then return end
  if read(function() return entity.force.name end) ~= own_force() then return end
  local by, plan_id = M.actor(event)
  M.note(op, name, position, surface, by, plan_id)
end

-- The built, mined and destroy events (event.entity, or a clone's
-- destination is not journaled).
function M.on_built(event)
  if event.entity then M.record("built", event.entity, event) end
end
function M.on_removed(event)
  if event.entity then M.record("removed", event.entity, event) end
end
-- on_player_rotated_entity, on_player_flipped_entity (a flip is a rotated
-- row too): always a player's.
function M.on_rotated(event)
  if event.entity then M.record("rotated", event.entity, event) end
end
-- on_entity_settings_pasted: the destination changed.
function M.on_settings_pasted(event)
  if event.destination then M.record("changed", event.destination, event) end
end

-- on_entity_died (no ghosts): an own entity was destroyed. Kept as a loss and a journal row whose by is what
-- killed it (the cause's name, else the killing force, else unknown).
function M.on_entity_died(event)
  local entity = event.entity
  local ok, name, kind, position, surface, own = pcall(function()
    return entity.name, entity.type, entity.position, entity.surface.index, entity.force.name
  end)
  if not ok or SKIPPED[kind] or own ~= own_force() then return end
  local cause = event.cause
  local killed_by = { name = read(function() return cause and cause.valid and cause.name end) or nil,
    type = read(function() return cause and cause.valid and cause.type end) or nil,
    force = read(function() return event.force and event.force.name end) or nil }
  if not next(killed_by) then killed_by = nil end
  local losses, tick = storage.losses, game.tick
  M.note("died", name, position, surface, killed_by and (killed_by.name or killed_by.force) or "unknown")
  if not losses then return end
  losses.last_tick = tick
  for back = 0, MERGE_BACK - 1 do
    local row = get(losses, M.LOSS_SIZE, back)
    if not row then break end
    local same = row.killed_by and killed_by and row.killed_by.name == killed_by.name
      and row.killed_by.force == killed_by.force or row.killed_by == nil and killed_by == nil
    if row.name == name and row.s == surface and same and tick - row.tick <= M.MERGE_TICKS then
      row.count, row.tick, row.x, row.y = row.count + 1, tick, position.x, position.y
      return
    end
  end
  push(losses, M.LOSS_SIZE, { tick = tick, name = name, s = surface, x = position.x, y = position.y, count = 1,
    killed_by = killed_by })
end

local function surface_ref(index, names)
  if names[index] == nil then names[index] = surfaces.ref(surfaces.by_index(index)) or false end
  return names[index] or nil
end

-- A loss as a reader sees it: {name, position, surface, count, tick,
-- killed_by?}.
local function loss_row(row, names)
  return { name = row.name, position = { x = row.x, y = row.y }, surface = surface_ref(row.s, names),
    count = row.count, tick = row.tick, killed_by = row.killed_by }
end

-- Losses newer than since_tick, oldest first; with surface_index only
-- that surface's.
function M.losses(since_tick, surface_index)
  local ring, rows, names = storage.losses, {}, {}
  if not ring then return rows end
  for back = math.min(ring.n, M.LOSS_SIZE) - 1, 0, -1 do
    local row = get(ring, M.LOSS_SIZE, back)
    if row.tick > since_tick and (surface_index == nil or row.s == surface_index) then
      rows[#rows + 1] = loss_row(row, names)
    end
  end
  return by_tick(rows)
end

-- event_state's fields: the newest loss's tick and the last few losses.
function M.loss_state()
  local ring = storage.losses
  if not (ring and ring.last_tick) then return nil, nil end
  local rows, names = {}, {}
  for back = math.min(ring.n, M.SHOWN_LOSSES) - 1, 0, -1 do rows[#rows + 1] = loss_row(get(ring, M.LOSS_SIZE, back), names) end
  return ring.last_tick, by_tick(rows)
end

-- factory_status problem rows for one surface's losses: status destroyed,
-- at or after since_tick as autonomy's problems (else the last
-- LOSS_WINDOW_TICKS), the newest
-- `limit` (default all) newest first, killed_by the killer's name (else its
-- force). Returns the rows and how many were left out.
function M.problem_rows(surface_index, since_tick, limit)
  local rows, losses = {}, M.losses(since_tick and since_tick - 1 or math.max(-1, game.tick - M.LOSS_WINDOW_TICKS),
    surface_index)
  for index = #losses, math.max(1, #losses - (limit or #losses) + 1), -1 do
    local row = losses[index]
    rows[#rows + 1] = { status = "destroyed", name = row.name, position = row.position, count = row.count,
      tick = row.tick, killed_by = row.killed_by and (row.killed_by.name or row.killed_by.force) or nil }
  end
  return rows, #losses - #rows
end

local function parse_area(area)
  if area == nil then return nil end
  local lt, rb = type(area) == "table" and area.left_top, type(area) == "table" and area.right_bottom
  if not (type(lt) == "table" and type(rb) == "table" and type(lt.x) == "number" and type(lt.y) == "number"
    and type(rb.x) == "number" and type(rb.y) == "number") then
    error("changes.area must be {left_top = {x, y}, right_bottom = {x, y}}", 0)
  end
  return { l = math.min(lt.x, rb.x), t = math.min(lt.y, rb.y), r = math.max(lt.x, rb.x), b = math.max(lt.y, rb.y) }
end

-- The journal read: changes {since_tick?, area?, surface?, limit?} ->
-- {rows, omitted, size}: rows (oldest first, at most limit, the newest kept)
-- that changed after since_tick, touching area, on surface (a planet name or
-- "platform:<index>"; else every surface); omitted counts the matches left
-- out; size is the ring's capacity, so a reader knows how far back it goes.
function M.changes(params)
  if type(params) ~= "table" then error("changes must be an object", 0) end
  local since = params.since_tick
  if since ~= nil and (type(since) ~= "number" or since % 1 ~= 0 or since < 0) then
    error("changes.since_tick must be a non-negative integer tick", 0)
  end
  local limit = params.limit == nil and 16 or params.limit
  if type(limit) ~= "number" or limit % 1 ~= 0 or limit < 1 or limit > M.MAX_CHANGES then
    error("changes.limit must be an integer from 1 to " .. M.MAX_CHANGES, 0)
  end
  local area = parse_area(params.area)
  if params.surface ~= nil and type(params.surface) ~= "string" then error("changes.surface must be a surface name", 0) end
  local ring, matched, names = storage.journal or { rows = {}, n = 0 }, {}, {}
  for back = math.min(ring.n, M.SIZE) - 1, 0, -1 do
    local row = get(ring, M.SIZE, back)
    local inside = not area or row.l <= area.r and row.r >= area.l and row.t <= area.b and row.b >= area.t
    if (since == nil or row.tick > since) and inside
      and (params.surface == nil or surface_ref(row.s, names) == params.surface) then
      matched[#matched + 1] = row
    end
  end
  by_tick(matched)
  local omitted = math.max(0, #matched - limit)
  local rows = {}
  for index = omitted + 1, #matched do
    local row = matched[index]
    local out = { tick = row.tick, op = row.op, name = row.name, action = row.action, by = row.by,
      plan_id = row.plan_id, surface = surface_ref(row.s, names) }
    if row.count == 1 then out.position = { x = row.l, y = row.t }
    else
      out.count = row.count
      out.area = { left_top = { x = row.l, y = row.t }, right_bottom = { x = row.r, y = row.b } }
    end
    rows[#rows + 1] = out
  end
  return { rows = rows, omitted = omitted, size = M.SIZE }
end

return M
