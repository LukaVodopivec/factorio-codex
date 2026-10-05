-- Inventory transfer actions: insert (companion → entity) and extract
-- (entity → companion). Both approach within reach_distance first and report
-- per-item results including shortfalls. insert takes one target or several
-- (targets: positions, or every own entity of a name around a point), each
-- receiving the same items.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local supply = require("scripts.actions.supply")
local craft = require("scripts.actions.craft")
local factory_activity = require("scripts.factory_activity")

local M = {}

local MAX_TARGETS = 32
local MAX_TARGET_RADIUS = 32

local function gone()
  return { status = "failed", detail = "the companion character is gone" }
end

local function validate_target(task, action)
  local t = task.target
  if type(t) ~= "table" or type(t.x) ~= "number" or type(t.y) ~= "number" then
    error(action .. " requires target = {x, y}")
  end
end

-- {"coal":10} → sorted list of {name, count} for deterministic messages.
local function validate_items(items, action)
  if type(items) ~= "table" then
    error(action .. " requires items = {\"item-name\": count}")
  end
  local list = {}
  for name, count in pairs(items) do
    if type(name) ~= "string" or type(count) ~= "number" or count < 1 then
      error(action .. " items must map item names to positive counts")
    end
    if not prototypes.item[name] then
      error("no item called '" .. name .. "'")
    end
    list[#list + 1] = { name = name, count = math.floor(count) }
  end
  if #list == 0 then
    error(action .. " needs at least one item")
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local function no_entity(task, action)
  return {
    status = "failed",
    detail = string.format("nothing at (%.1f, %.1f) to %s — check the position with inspect",
      task.target.x, task.target.y, action),
  }
end

local function target_identity(e)
  local identity = { name = e.name, type = e.type }
  if type(e.position) == "table" then identity.position = { x = e.position.x, y = e.position.y } end
  return identity
end

-- Moves each listed {name, count} from the companion into the entity,
-- removing exactly what was accepted. Returns problem strings (empty when
-- everything went in), the total inserted and per-item transfer rows.
function M.insert_list(c, e, list)
  local problems, total, transfers = {}, 0, {}
  for _, it in ipairs(list) do
    if not prototypes.item[it.name] then
      problems[#problems + 1] = "no item called '" .. it.name .. "'"
    else
      local have = c.get_item_count(it.name)
      local n = math.min(it.count, have)
      local inserted = 0
      if n > 0 then
        inserted = e.insert({ name = it.name, count = n })
        if inserted > 0 then
          c.remove_item({ name = it.name, count = inserted })
        end
      end
      total = total + inserted
      transfers[#transfers + 1] = { item = it.name, requested = it.count,
        available = have, inserted = inserted, remainder = it.count - inserted }
      if inserted < it.count then
        if have == 0 then
          problems[#problems + 1] = "I have no " .. it.name .. " to insert"
        elseif inserted == 0 then
          problems[#problems + 1] = "the " .. e.name .. " wouldn't accept " .. it.name
        elseif inserted < n then
          problems[#problems + 1] = string.format("the %s only took %d of %d %s",
            e.name, inserted, it.count, it.name)
        else
          problems[#problems + 1] = string.format("only inserted %d of %d %s (that's all I had)",
            inserted, it.count, it.name)
        end
      end
    end
  end
  return problems, total, transfers
end

-- True while some listed item is short and still in the crafting queue.
function M.awaits_crafting(c, list)
  for _, it in ipairs(list) do
    if craft.awaits(c, it.name, it.count) then return true end
  end
  return false
end

-- ----------------------------------------------------------------- insert

M.insert = {}

local function point(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

-- targets = [{x, y}, ...] or {name, near = {x, y}, radius}: the positions to
-- fill, in order (an own-entity search nearest to `near` first).
local function resolve_targets(c, targets)
  if type(targets) ~= "table" then error("insert targets must be positions or {name, near, radius}") end
  local list = {}
  if targets.name ~= nil then
    local radius = tonumber(targets.radius) or 10
    if type(targets.name) ~= "string" or not point(targets.near) or radius <= 0 or radius > MAX_TARGET_RADIUS then
      error(string.format("insert targets {name, near, radius} needs an entity name, near = {x, y} and radius up to %d",
        MAX_TARGET_RADIUS))
    end
    local near = targets.near
    local found = c.surface.find_entities_filtered({ position = near, radius = radius, name = targets.name, force = c.force })
    local rows = {}
    for _, e in ipairs(found) do
      if e.valid then
        local dx, dy = e.position.x - near.x, e.position.y - near.y
        rows[#rows + 1] = { x = e.position.x, y = e.position.y, d = dx * dx + dy * dy }
      end
    end
    table.sort(rows, function(a, b)
      if a.d ~= b.d then return a.d < b.d end
      if a.y ~= b.y then return a.y < b.y end
      return a.x < b.x
    end)
    for i = 1, math.min(#rows, MAX_TARGETS) do list[i] = { x = rows[i].x, y = rows[i].y } end
    if #list == 0 then
      error(string.format("no own %s within %g tiles of (%.1f, %.1f)", targets.name, radius, near.x, near.y))
    end
  else
    if #targets < 1 or #targets > MAX_TARGETS then error("insert targets must list 1-" .. MAX_TARGETS .. " positions") end
    for i, target in ipairs(targets) do
      if not point(target) then error("insert targets[" .. (i - 1) .. "] must be {x, y}") end
      list[i] = { x = target.x, y = target.y }
    end
  end
  return list
end

function M.insert.start(task)
  local c = companion.require_companion()
  if task.targets ~= nil then
    task._targets = resolve_targets(c, task.targets)
    task.target, task._target_index, task._rows = task._targets[1], 1, {}
  else
    validate_target(task, "insert")
  end
  task._items = validate_items(task.items, "insert")
end

M.insert.resume = supply.resume

local function shortfall_note(task)
  return task._shortfall and ("; " .. task._shortfall) or ""
end

-- One target: approach it, wait for queued crafts, insert. nil while working.
local function insert_one(task, c)
  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local e = approach.find_entity_near(c, task.target)
  if not e then return no_entity(task, "insert into") end

  local entity_reached = approach.ensure_entity(task, c, e)
  if type(entity_reached) == "table" then return entity_reached end
  if entity_reached ~= "ok" then return nil end
  if M.awaits_crafting(c, task._items) then return nil end

  local moved, problems, total, transfers = {}, {}, 0, {}
  for _, it in ipairs(task._items) do
    local have = c.get_item_count(it.name)
    local n = math.min(it.count, have)
    local inserted = 0
    if n > 0 then
      inserted = e.insert({ name = it.name, count = n })
      if inserted > 0 then
        c.remove_item({ name = it.name, count = inserted })
      end
    end
    total = total + inserted
    local reason
    if inserted >= it.count then
      moved[#moved + 1] = string.format("%d %s", inserted, it.name)
    elseif inserted > 0 then
      local why = inserted < n and ("the " .. e.name .. " wouldn't take more")
        or string.format("I only had %d", have)
      reason = inserted < n and "TARGET_CAPACITY" or "INSUFFICIENT_CARRIED_ITEMS"
      moved[#moved + 1] = string.format("%d of %d %s (%s)", inserted, it.count, it.name, why)
      problems[#problems + 1] = string.format("requested %d %s, inserted %d, remainder %d",
        it.count, it.name, inserted, it.count - inserted)
    elseif have == 0 then
      reason = "NO_CARRIED_ITEMS"
      problems[#problems + 1] = string.format("requested %d %s, inserted 0, remainder %d — I have none",
        it.count, it.name, it.count)
    else
      reason = "TARGET_REJECTED_ITEM"
      problems[#problems + 1] = string.format("requested %d %s, inserted 0, remainder %d — the %s wouldn't accept it",
        it.count, it.name, it.count, e.name)
    end
    transfers[#transfers + 1] = { item = it.name, requested = it.count,
      available = have, inserted = inserted, remainder = it.count - inserted,
      reason = reason }
  end

  if total == 0 then
    return {
      status = "failed",
      detail = string.format("couldn't insert anything into the %s — %s%s",
        e.name, table.concat(problems, "; "), shortfall_note(task)),
      outcome = { code = "ZERO_PROGRESS", total_inserted = 0, transfers = transfers, target = target_identity(e) },
    }
  end
  if #problems > 0 then
    return {
      status = "partial",
      detail = string.format("partial insert into the %s — %s%s", e.name, table.concat(problems, "; "),
        shortfall_note(task)),
      outcome = { code = "PARTIAL_INSERT", total_inserted = total, transfers = transfers, target = target_identity(e) },
    }
  end
  -- Automation nudge: hand-feeding smelters is a treadmill.
  local tip = ""
  if e.type == "furnace" then
    tip = " — tip: a burner drill placed facing this furnace (or an inserter from a belt) would feed it automatically"
  end
  return {
    status = "done",
    detail = string.format("inserted %s into the %s%s", table.concat(moved, ", "), e.name, tip),
    outcome = { total_inserted = total, transfers = transfers, target = target_identity(e) },
  }
end

-- Several targets: every one gets the same items, in order; a target that
-- fails is reported and the rest still get theirs.
local function multi_result(task)
  local rows, total, failed, problems = task._rows, 0, 0, {}
  for _, row in ipairs(rows) do
    total = total + row.inserted
    if row.status ~= "done" then
      failed = failed + 1
      if #problems < 4 then problems[#problems + 1] = string.format("(%.1f, %.1f): %s", row.x, row.y, row.detail) end
    end
  end
  local per = {}
  for _, it in ipairs(task._items) do per[#per + 1] = string.format("%d %s", it.count, it.name) end
  local outcome = { total_inserted = total, targets = rows }
  if failed == 0 then
    outcome.code = "INSERTED_ALL_TARGETS"
    return { status = "done", detail = string.format("inserted %s into each of %d targets%s", table.concat(per, ", "),
      #rows, shortfall_note(task)), outcome = outcome }
  end
  outcome.code = total > 0 and "PARTIAL_INSERT_TARGETS" or "ZERO_PROGRESS"
  return { status = total > 0 and "partial" or "failed",
    detail = string.format("%d of %d targets did not take all of %s — %s%s", failed, #rows, table.concat(per, ", "),
      table.concat(problems, "; "), shortfall_note(task)), outcome = outcome }
end

function M.insert.tick(task)
  local c = companion.get()
  if not c then return gone() end

  -- Auto-supply (default on): fetch what is not carried, once, never from the
  -- target itself. A shortfall still inserts what is carried and is named.
  if task.auto_supply ~= false and not task._supplied then
    local needs, targets = {}, task._targets and #task._targets or 1
    for _, it in ipairs(task._items) do
      local total = it.count * targets
      if c.get_item_count(it.name) < total then needs[#needs + 1] = { name = it.name, count = total } end
    end
    if #needs > 0 then
      local result = supply.ensure(task, needs, { exclude = not task._targets and task.target or nil })
      if not result then return nil end
      if result.status ~= "done" then task._shortfall = result.detail end
    end
    task._supplied = true
  end

  if not task._targets then return insert_one(task, c) end
  local result = insert_one(task, c)
  if not result then return nil end
  -- The plan step's own outcome lists targets, not transfers: each target's
  -- transfer is recorded here (hand-fed lines, factory activity).
  factory_activity.record("insert", result.outcome)
  local row = { x = task.target.x, y = task.target.y, status = result.status,
    inserted = result.outcome and tonumber(result.outcome.total_inserted) or 0 }
  if result.status ~= "done" then row.detail = result.detail end
  task._rows[#task._rows + 1] = row
  task._approach, task._approach_close = nil, nil
  task._target_index = task._target_index + 1
  task.target = task._targets[task._target_index]
  if not task.target then
    task.target = task._targets[#task._targets]
    return multi_result(task)
  end
  return nil
end

-- ---------------------------------------------------------------- extract

M.extract = {}

function M.extract.start(task)
  companion.require_companion()
  validate_target(task, "extract")
  if task.all then
    task._all = true
  else
    task._items = validate_items(task.items, "extract")
  end
end

-- Move `count` of `name` from an entity/inventory into the companion;
-- overflow that doesn't fit goes straight back. Returns kept, removed.
-- (LuaObjects error on unknown members, so the source kind is explicit.)
-- Moves up to count of name from source into the body. Never removes more
-- than the body has room for: an entity's insert works like an inserter and
-- cannot put a furnace's or assembler's products back into its output, so
-- an overflow would be lost. What still fails to go back is spilled at the
-- body, never deleted. Returns kept, removed, and whether room capped it.
local function pull(c, source, is_inventory, name, count)
  local inventory = c.get_main_inventory()
  local room = inventory and inventory.get_insertable_count(name) or 0
  local full = room < count
  if room <= 0 then return 0, 0, true end
  if full then count = room end
  local removed
  if is_inventory then
    removed = source.remove({ name = name, count = count })
  else
    removed = source.remove_item({ name = name, count = count })
  end
  if removed == 0 then return 0, 0, full end
  local kept = c.insert({ name = name, count = removed })
  if kept < removed then
    local back = source.insert({ name = name, count = removed - kept })
    if back < removed - kept then
      pcall(c.surface.spill_item_stack, { position = c.position,
        stack = { name = name, count = removed - kept - back }, force = c.force, allow_belts = false })
    end
  end
  return kept, removed, full
end

local function extract_all(task, c, e)
  local inv = e.get_output_inventory() or e.get_inventory(defines.inventory.chest)
  if not inv then
    return {
      status = "failed",
      detail = "the " .. e.name .. " has no output inventory I can empty",
    }
  end
  local sums = {}
  for _, s in ipairs(inv.get_contents()) do
    sums[s.name] = (sums[s.name] or 0) + s.count
  end
  if next(sums) == nil then
    return { status = "failed", detail = "the " .. e.name .. " is empty — nothing to take" }
  end

  local names = {}
  for name in pairs(sums) do names[#names + 1] = name end
  table.sort(names)

  local moved = {}
  local function restore_moved()
    for i = #moved, 1, -1 do
      local stack = moved[i]
      local removed = c.remove_item(stack)
      local restored = removed > 0 and inv.insert({ name = stack.name, count = removed }) or 0
      if removed ~= stack.count or restored ~= removed then
        error("full extraction could not restore the source inventory")
      end
    end
  end

  local taken, transfers = {}, {}
  for _, name in ipairs(names) do
    local count = sums[name]
    local kept = pull(c, inv, true, name, count)
    if kept > 0 then
      moved[#moved + 1] = { name = name, count = kept }
      taken[#taken + 1] = string.format("%d %s", kept, name)
      transfers[#transfers + 1] = { item = name, extracted = kept }
    end
    if kept < count then
      restore_moved()
      return {
        status = "failed",
        detail = "couldn't empty the " .. e.name .. " — my inventory lacks room for every output; nothing was taken",
      }
    end
  end
  return {
    status = "done",
    detail = string.format("took %s from the %s", table.concat(taken, ", "), e.name),
    outcome = { total_extracted = #moved > 0 and (function()
      local total = 0; for _, row in ipairs(transfers) do total = total + row.extracted end; return total
    end)() or 0, transfers = transfers, target = target_identity(e) },
  }
end

local function extract_items(task, c, e)
  local taken, problems, total, transfers = {}, {}, 0, {}
  for _, it in ipairs(task._items) do
    local kept, removed, full = pull(c, e, false, it.name, it.count)
    total = total + kept
    transfers[#transfers + 1] = { item = it.name, requested = it.count, extracted = kept,
      remainder = it.count - kept }
    if kept >= it.count then
      taken[#taken + 1] = string.format("%d %s", kept, it.name)
    elseif kept > 0 then
      local why = (full or kept < removed) and "my inventory is full" or "that's all it had"
      taken[#taken + 1] = string.format("%d of %d %s (%s)", kept, it.count, it.name, why)
    elseif full or removed > 0 then
      problems[#problems + 1] = "my inventory is full"
    else
      problems[#problems + 1] = "it has no " .. it.name
    end
  end
  if total == 0 then
    return {
      status = "failed",
      detail = string.format("couldn't take anything from the %s — %s", e.name, table.concat(problems, "; ")),
    }
  end
  local extra = #problems > 0 and ("; " .. table.concat(problems, "; ")) or ""
  return {
    status = "done",
    detail = string.format("took %s from the %s%s", table.concat(taken, ", "), e.name, extra),
    outcome = { total_extracted = total, transfers = transfers, target = target_identity(e) },
  }
end

function M.extract.tick(task)
  local c = companion.get()
  if not c then return gone() end

  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local e = approach.find_entity_near(c, task.target)
  if not e then return no_entity(task, "extract from") end

  local entity_reached = approach.ensure_entity(task, c, e)
  if type(entity_reached) == "table" then return entity_reached end
  if entity_reached ~= "ok" then return nil end

  if task._all then
    return extract_all(task, c, e)
  end
  return extract_items(task, c, e)
end

-- Auto-supply takes from chests and machine outputs through extract and
-- loads furnaces through insert.
supply.register_runner("extract", M.extract)
supply.register_runner("insert", M.insert)

return M
