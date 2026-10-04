-- Inventory transfer actions: insert (companion → entity) and extract
-- (entity → companion). Both approach within reach_distance first and report
-- per-item results including shortfalls.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local supply = require("scripts.actions.supply")

local M = {}

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

-- ----------------------------------------------------------------- insert

M.insert = {}

function M.insert.start(task)
  companion.require_companion()
  validate_target(task, "insert")
  task._items = validate_items(task.items, "insert")
end

M.insert.resume = supply.resume

local function shortfall_note(task)
  return task._shortfall and ("; " .. task._shortfall) or ""
end

function M.insert.tick(task)
  local c = companion.get()
  if not c then return gone() end

  -- Auto-supply (default on): fetch what is not carried, once, never from the
  -- target itself. A shortfall still inserts what is carried and is named.
  if task.auto_supply ~= false and not task._supplied then
    local needs = {}
    for _, it in ipairs(task._items) do
      if c.get_item_count(it.name) < it.count then needs[#needs + 1] = { name = it.name, count = it.count } end
    end
    if #needs > 0 then
      local result = supply.ensure(task, needs, { exclude = task.target })
      if not result then return nil end
      if result.status ~= "done" then task._shortfall = result.detail end
    end
    task._supplied = true
  end

  local reached = approach.ensure(task, c, task.target, c.reach_distance)
  if type(reached) == "table" then return reached end
  if reached ~= "ok" then return nil end

  local e = approach.find_entity_near(c, task.target)
  if not e then return no_entity(task, "insert into") end

  local entity_reached = approach.ensure_entity(task, c, e)
  if type(entity_reached) == "table" then return entity_reached end
  if entity_reached ~= "ok" then return nil end

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

-- Auto-supply takes from chests and machine outputs through extract.
supply.register_runner("extract", M.extract)

return M
