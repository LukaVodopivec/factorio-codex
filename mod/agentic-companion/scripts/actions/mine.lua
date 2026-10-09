-- Mine exactly the visible entity occupying the requested coordinate. count
-- > 1 on a tree or rock mines it and then the nearest others of its kind. An
-- own entity with contents is mined the way a player mines it: its contents
-- go into the inventory with it, after a check that they all fit. The body's
-- own corpse (a character-corpse of the Codex player) is an own entity too:
-- mining it (target_kind "owned") takes back what the body carried.
local companion = require("scripts.companion")
local approach = require("scripts.actions.approach")
local walk = require("scripts.actions.walk")
local craft = require("scripts.actions.craft")
-- Optional: the charted-stock reader may be absent or fail to load.
local registry = require("scripts.registry")
local M = {}
local NATURAL_MINABLE_TYPES = { resource = true, tree = true, ["simple-entity"] = true, plant = true }
-- The next tree or rock of a count > 1 mine: nearest to the requested
-- coordinate, small radii first, at most NEXT_LIMIT read per query.
local NEXT_RADII = { 8, 16, 32 }
local NEXT_LIMIT = 100

local function table_empty(value)
  if type(value) ~= "table" then return true end
  return next(value) == nil
end

-- Items an own entity holds that mining hands to the miner: every
-- inventory and, for belts, the items on them.
local function entity_contents(e)
  local contents, seen = {}, {}
  local function add(rows)
    for _, row in ipairs(rows or {}) do
      if type(row.name) == "string" then contents[row.name] = (contents[row.name] or 0) + (tonumber(row.count) or 0) end
    end
  end
  for _, inventory_id in pairs(defines.inventory or {}) do
    if type(inventory_id) == "number" and not seen[inventory_id] then
      seen[inventory_id] = true
      local ok, inv = pcall(e.get_inventory, inventory_id)
      if ok and inv and not inv.is_empty() then add(inv.get_contents()) end
    end
  end
  local ok_lines, lines = pcall(e.get_max_transport_line_index)
  for index = 1, ok_lines and tonumber(lines) or 0 do
    local ok, line = pcall(e.get_transport_line, index)
    if ok and line then add(line.get_contents()) end
  end
  return contents
end


local function fluid_contents(e)
  local ok, fluids = pcall(e.get_fluid_contents)
  if not ok or table_empty(fluids) then return {} end
  local copy = {}
  for name, amount in pairs(fluids) do copy[name] = tonumber(amount) or 0 end
  return copy
end

local function recoverable(e, allow_fluid_loss)
  return allow_fluid_loss or table_empty(fluid_contents(e))
end

local function fluid_loss_detail(fluids)
  local names, parts = {}, {}
  for name in pairs(fluids or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do parts[#parts + 1] = string.format("%.1f %s", fluids[name], name) end
  return #parts > 0 and ("; discarded contained fluid through ordinary dismantling: " .. table.concat(parts, ", ")) or ""
end

local function expected_item_names(e)
  local names, seen = {}, {}
  for _, product in ipairs(e.prototype.mineable_properties.products or {}) do
    if (product.type == nil or product.type == "item") and product.name and not seen[product.name] then
      seen[product.name] = true
      names[#names + 1] = product.name
    end
  end
  table.sort(names)
  return names
end

local function occupies(e, target)
  local box = e.selection_box or e.bounding_box
  if box then
    return target.x >= box.left_top.x and target.x < box.right_bottom.x
      and target.y >= box.left_top.y and target.y < box.right_bottom.y
  end
  return math.floor(e.position.x) == math.floor(target.x) and math.floor(e.position.y) == math.floor(target.y)
end

local function entity_amount(e)
  if not (e and e.valid) then return nil end
  local ok, amount = pcall(function() return e.amount end)
  if ok and type(amount) == "number" then return amount end
  return nil
end

local function entity_snapshot(e)
  if not (e and e.valid) then return nil end
  return { name = e.name, type = e.type,
    position = { x = e.position.x, y = e.position.y } }
end

local function observation_age(task)
  if task.observed_tick == nil then return nil end
  return math.max(0, game.tick - task.observed_tick)
end

local function target_failure(task, c, code, stage, detail, actual)
  return {
    status = "failed",
    detail = code .. ": " .. detail,
    outcome = {
      code = code, stage = stage,
      requested_position = { x = task.target.x, y = task.target.y },
      expected_name = task.expected_name,
      observed_tick = task.observed_tick,
      observation_age_ticks = observation_age(task),
      target = actual,
      character_position = c and { x = c.position.x, y = c.position.y } or nil,
    },
  }
end

local function quality_name(quality)
  if type(quality) == "string" then return quality end
  if quality == nil then return nil end
  local ok, name = pcall(function() return quality.name end)
  if ok and type(name) == "string" then return name end
  return nil
end

local function normal_filter_name(filter)
  if type(filter) == "string" then return filter end
  if type(filter) ~= "table" or type(filter.name) ~= "string" then return nil end
  if filter.quality == nil then return filter.name end
  if quality_name(filter.quality) ~= "normal" then return nil end
  if filter.comparator == nil or filter.comparator == "=" then return filter.name end
  return nil
end

-- Physical character mining cannot complete when its inventory cannot accept
-- the entity's products. Fail before starting the mining state instead of
-- waiting until the bridge timeout or bypassing the character with scripted
-- entity mining.
local function character_accepts_products(inv, e, contents)
  local required = {}
  for name, count in pairs(contents or {}) do required[name] = (required[name] or 0) + count end
  local products = e.prototype.mineable_properties.products or {}
  for _, product in ipairs(products) do
    if (product.type == nil or product.type == "item") and product.name then
      local count = tonumber(product.amount) or tonumber(product.amount_max)
        or tonumber(product.amount_min) or 1
      required[product.name] = (required[product.name] or 0) + math.max(1, math.ceil(count))
    end
  end
  local names = {}
  for name in pairs(required) do names[#names + 1] = name end
  table.sort(names)

  -- LuaControl.can_insert only means that some of a stack fits, and separate
  -- queries can double-count shared empty slots. Simulate allocation from the
  -- read-only inventory slot state so the preflight neither creates nor moves
  -- any item. Existing partial stacks are consumed first, followed by matching
  -- filtered slots and then shared unfiltered slots in deterministic order.
  local available, filtered_empty, shared_empty = {}, {}, {}
  local last = #inv
  local ok_bar, bar = pcall(function() return inv.get_bar() end)
  if ok_bar and type(bar) == "number" and bar > 0 then last = math.min(last, bar - 1) end
  for index = 1, last do
    local stack = inv[index]
    local ok_filter, filter = pcall(function() return inv.get_filter(index) end)
    if not ok_filter then filter = nil end
    if stack and stack.valid_for_read then
      if required[stack.name] and quality_name(stack.quality) == "normal" then
        local stack_size = tonumber(stack.prototype and stack.prototype.stack_size) or stack.count
        available[stack.name] = (available[stack.name] or 0) + math.max(0, stack_size - stack.count)
      end
    elseif filter then
      local filter_name = normal_filter_name(filter)
      if filter_name then
        filtered_empty[filter_name] = (filtered_empty[filter_name] or 0) + 1
      end
    else
      shared_empty[#shared_empty + 1] = index
    end
  end

  for _, name in ipairs(names) do
    local remaining = required[name] - (available[name] or 0)
    local proto = prototypes and prototypes.item and prototypes.item[name]
    local stack_size = tonumber(proto and proto.stack_size)
    if remaining > 0 and not stack_size then return false end
    local reserved = filtered_empty[name] or 0
    if remaining > 0 and reserved > 0 then
      local used = math.min(reserved, math.ceil(remaining / stack_size))
      filtered_empty[name] = reserved - used
      remaining = remaining - used * stack_size
    end
    while remaining > 0 and #shared_empty > 0 do
      table.remove(shared_empty)
      remaining = remaining - stack_size
    end
    if remaining > 0 then return false end
  end
  return true
end

function M.start(task)
  local c = companion.require_companion()
  local target = task.target
  if type(target) ~= "table" or type(target.x) ~= "number" or type(target.y) ~= "number" then error("mine requires target = {x, y}") end
  local count = tonumber(task.count) or 1
  if count ~= math.floor(count) or count < 1 or count > 200 then error("mine count must be an integer from 1 to 200") end
  local requested_target_kind = task.target_kind
  local target_kind = requested_target_kind or "natural"
  if target_kind ~= "natural" and target_kind ~= "owned" then
    error("mine target_kind must be natural or owned")
  end
  if target_kind == "owned" and count ~= 1 then
    error("mine target_kind=owned requires exactly one physical mining cycle")
  end
  if task.expected_name ~= nil and (type(task.expected_name) ~= "string" or task.expected_name == "") then
    error("mine expected_name must be a nonempty prototype name")
  end
  if task.observed_tick ~= nil then
    local observed_tick = tonumber(task.observed_tick)
    if not observed_tick or observed_tick ~= math.floor(observed_tick) or observed_tick < 0 or observed_tick > game.tick then
      error("mine observed_tick must be an integer from 0 through the current game tick")
    end
    task.observed_tick = observed_tick
  end
  task.allow_fluid_loss = task.allow_fluid_loss == true
  if task.allow_fluid_loss and target_kind ~= "owned" then
    error("mine allow_fluid_loss=true is valid only with target_kind=owned")
  end
  -- The mod's own supply and footprint clearing name the exact natural entity
  -- (a tree on an ore tile shares its coordinate with the resource).
  local exact = task.entity
  if exact ~= nil then
    local ok, natural_entity = pcall(function()
      return exact.valid and NATURAL_MINABLE_TYPES[exact.type] and exact.force ~= c.force
    end)
    if not (ok and natural_entity) or target_kind ~= "natural" then
      error("mine entity must be a valid natural minable entity")
    end
  end
  local candidates = exact and { exact }
    or c.surface.find_entities_filtered({ area = { { target.x, target.y }, { target.x + 0.001, target.y + 0.001 } } })
  local natural, owned
  local rec_ok, rec = pcall(companion.record)
  local codex_index = rec_ok and rec and rec.player_index or nil
  for _, e in ipairs(candidates) do
    local own_corpse = e.type == "character-corpse" and codex_index ~= nil
      and e.character_corpse_player_index == codex_index
    local is_owned = own_corpse
      or e.force == c.force and e.type ~= "character" and e.type ~= "character-corpse" and not NATURAL_MINABLE_TYPES[e.type]
    local mineable = e.prototype and e.prototype.mineable_properties
    if e.valid and (NATURAL_MINABLE_TYPES[e.type] or is_owned)
      and mineable and mineable.minable and occupies(e, target) then
      if is_owned then
        if owned then error("more than one minable entity of the same priority occupies that coordinate; observe again and choose an unambiguous point") end
        owned = e
      else
        if natural then error("more than one minable entity of the same priority occupies that coordinate; observe again and choose an unambiguous point") end
        natural = e
      end
    end
  end
  -- Never infer overlap priority. Natural mining is the unchanged default;
  -- recovering an overlapping machine is an explicit one-cycle operation.
  local found
  if target_kind == "owned" then found = owned else found = natural end
  task._target_kind = target_kind
  task._requested, task._completed, task._actual_gain = count, 0, 0
  if natural and owned and requested_target_kind == nil then
    task._initial_failure = target_failure(task, c, "TARGET_KIND_REQUIRED", "initial_resolution",
      "both a natural and player-owned minable entity occupy the exact coordinate; specify target_kind explicitly")
    task._initial_failure.outcome.candidates = { entity_snapshot(natural), entity_snapshot(owned) }
    return
  end
  if not found then
    task._initial_failure = target_failure(task, c, "TARGET_NOT_FOUND_AT_START", "initial_resolution",
      string.format("no %s minable entity occupies exact coordinate (%.3f, %.3f)", target_kind, target.x, target.y))
    return
  end
  if task.expected_name and found.name ~= task.expected_name then
    task._initial_failure = target_failure(task, c, "TARGET_IDENTITY_MISMATCH", "initial_resolution",
      string.format("expected %s but exact coordinate contains %s", task.expected_name, found.name), entity_snapshot(found))
    return
  end
  if count > 1 and found == owned then error("mine count greater than 1 is only valid for resources, trees and rocks") end
  if found == owned and not recoverable(found, task.allow_fluid_loss) then
    error("refusing to recover a player-owned entity with fluids; set allow_fluid_loss=true to discard fluids through ordinary dismantling")
  end
  task._entity, task._entity_name = found, found.name
  task._resolved_target = entity_snapshot(found)
  task._expected_items = expected_item_names(found)
  task._discarded_fluids = task.allow_fluid_loss and fluid_contents(found) or {}
end

-- Hand-mining a resource that own mining drills already mine spends body time
-- on something the factory produces. Name the drills and the drill-fed stock
-- so the caller sees the better source. Drills and stock come from the
-- event-maintained registry: no entity query at the end of a mine task.
local function drill_hint(c, task)
  if task._resolved_target.type ~= "resource" then return nil end
  local ok, found = pcall(registry.machines, { "mining-drill" })
  if not ok or type(found) ~= "table" then return nil end
  local drills = 0
  for _, entry in ipairs(found) do
    local ok_target, target = pcall(function() return entry.entity.mining_target end)
    if ok_target and target and target.valid and target.name == task._entity_name then drills = drills + 1 end
  end
  if drills == 0 then return nil end
  local hint = { drill_produced = true, drills = drills }
  local item = task._expected_items[1]
  if item then
    local ok_stock, totals = pcall(registry.stock_totals, { item })
    if ok_stock and type(totals) == "table" and type(totals[item]) == "number" then hint.stockpile_total = totals[item] end
  end
  return hint
end

local function partial_failure(task, reason)
  return {
    status = "failed",
    detail = string.format("mining %s stopped: requested %d cycles, completed %d, actual gain %d items — %s",
      task._entity_name, task._requested, task._completed, task._actual_gain, reason),
  }
end

local function selection_failure(task, c, e, stage, code)
  local selected = c.selected
  local can_reach = false
  if e and e.valid then
    local ok, value = pcall(c.can_reach_entity, e)
    can_reach = ok and value == true
  end
  local actual
  if selected and selected.valid then actual = {
    name = selected.name, type = selected.type,
    position = { x = selected.position.x, y = selected.position.y },
  } end
  return {
    status = "failed",
    detail = code .. ": could not select the exact mining target",
    outcome = {
      code = code, stage = stage,
      requested_position = { x = task.target.x, y = task.target.y },
      expected_name = task.expected_name,
      observed_tick = task.observed_tick,
      observation_age_ticks = observation_age(task),
      target = entity_snapshot(e) or task._resolved_target,
      character_position = { x = c.position.x, y = c.position.y },
      can_reach_entity = can_reach, selected = actual,
    },
  }
end

-- After a human hold the interrupted cycle starts over: approach from the
-- current position, then take fresh amount and inventory baselines. Completed
-- cycles keep their count.
function M.resume(task)
  task._mining_started = false
end

-- Ticks one physical cycle may take before the mod calls it stalled: three
-- times the target's mining time at the character's base mining speed (bonuses
-- only make it faster), plus a second. The engine holds a cycle it cannot
-- finish without saying so; nothing else ends that wait.
local function cycle_ticks(c, e)
  local ok_time, mining_time = pcall(function() return e.prototype.mineable_properties.mining_time end)
  local ok_speed, speed = pcall(function() return c.prototype.mining_speed end)
  mining_time = ok_time and tonumber(mining_time) or 1
  speed = ok_speed and tonumber(speed) or 0
  return 3 * math.ceil(mining_time / math.max(speed, 0.01) * 60) + 60
end

local function charted(c, position)
  local ok, value = pcall(c.force.is_chunk_charted, c.surface,
    { x = math.floor(position.x / 32), y = math.floor(position.y / 32) })
  return ok and value == true
end

-- The nearest charted tree or rock (not own) of the first one's kind to
-- the requested coordinate, for the next cycle of a count > 1 mine.
local function next_natural(c, task)
  for _, radius in ipairs(NEXT_RADII) do
    local ok, found = pcall(c.surface.find_entities_filtered, { position = task.target, radius = radius,
      type = task._resolved_target.type, limit = NEXT_LIMIT })
    local best, best_d
    for _, e in ipairs(ok and type(found) == "table" and found or {}) do
      local ok_minable, minable = pcall(function()
        return e.valid and e.force ~= c.force and e.prototype.mineable_properties.minable
      end)
      if ok_minable and minable and charted(c, e.position) then
        local dx, dy = e.position.x - task.target.x, e.position.y - task.target.y
        local d = dx * dx + dy * dy
        if not best or d < best_d or (d == best_d and (e.position.y < best.position.y
          or e.position.y == best.position.y and e.position.x < best.position.x)) then
          best, best_d = e, d
        end
      end
    end
    if best then return best end
  end
end

function M.tick(task)
  local c, e = companion.get(), task._entity
  if task._initial_failure then return task._initial_failure end
  if not c then return partial_failure(task, "the Codex character is gone") end
  -- Hand-crafting changes the inventory an owned entity's gain is measured
  -- on only when a queued recipe makes or uses what mining it hands over:
  -- its expected items or its contents (task._craft_names, from the first
  -- check). Other crafts never hold the mine.
  local crafting = task._target_kind == "owned" and (tonumber(c.crafting_queue_size) or 0) > 0
  if crafting then
    if not task._craft_names and e and e.valid then
      local names = {}
      for _, name in ipairs(task._expected_items or {}) do names[name] = true end
      for name in pairs(entity_contents(e)) do names[name] = true end
      task._craft_names = names
    end
    local ok, touches = pcall(craft.queue_touches, c, task._craft_names or {})
    crafting = not ok or touches
  end
  if task._target_kind == "owned" and crafting and task._mining_started then
    c.mining_state = { mining = false }
    return partial_failure(task, "refusing owned recovery while a queued hand-craft makes or uses its items")
  end
  if not task._mining_started then
    if not (e and e.valid) then
      if task._completed > 0 then return partial_failure(task, "the initially selected resource was exhausted") end
      return target_failure(task, c, "TARGET_GONE_AFTER_RESOLUTION", task._approach and "during_approach" or "before_approach",
        "the exact target was removed after resolution and before mining started", task._resolved_target)
    end
    -- A walk's start blocker is mined from where the body stands.
    local reached = task.from_here and "ok" or approach.ensure_entity(task, c, e)
    if type(reached) == "table" then
      if not (e and e.valid) then
        return target_failure(task, c, "TARGET_GONE_AFTER_RESOLUTION", "during_approach",
          "the exact target was removed during physical approach", task._resolved_target)
      end
      if type(reached.detail) == "string" and reached.detail:match("physical reach") then
        return target_failure(task, c, "TARGET_OUT_OF_REACH", "after_approach",
          "the resolved exact target remains outside physical character reach", entity_snapshot(e) or task._resolved_target)
      end
      return reached
    end
    if reached ~= "ok" then return nil end
    local reach_ok, can_reach = pcall(c.can_reach_entity, e)
    if not reach_ok or can_reach ~= true then
      return target_failure(task, c, "TARGET_OUT_OF_REACH", "after_approach",
        "the resolved exact target is outside physical character reach", entity_snapshot(e) or task._resolved_target)
    end
    if task._target_kind == "owned" and not recoverable(e, task.allow_fluid_loss) then
      c.mining_state = { mining = false }
      return partial_failure(task, "refusing to recover a player-owned entity that gained fluid contents")
    end
    -- An owned entity is mined once no queued craft touches its items.
    if task._target_kind == "owned" and crafting then craft.mark_wait(); return nil end
    local inv = c.get_main_inventory()
    if not inv then return { status = "failed", detail = "the Codex character has no inventory" } end
    local contents = task._target_kind == "owned" and entity_contents(e) or nil
    if not character_accepts_products(inv, e, contents) then
      return partial_failure(task, contents and next(contents) and "Codex inventory has no room for the entity and its contents"
        or "Codex inventory is full")
    end
    task._target_amount = entity_amount(e)
    task._inventory_before = {}
    for _, name in ipairs(task._expected_items) do
      task._inventory_before[name] = inv.get_item_count(name)
    end
    -- mining_state targets the control's selected entity; the position alone
    -- does not select one for a script-created character. Select through the
    -- physical LuaControl API and refuse to mine a different overlapping
    -- entity.
    c.selected = e
    if c.selected ~= e then
      return selection_failure(task, c, e, "initial_selection", "TARGET_NOT_SELECTABLE")
    end
    task._mining_started = true
    task._cycle_deadline = game.tick + cycle_ticks(c, e)
    c.mining_state = { mining = true, position = e.position }
    return nil
  end

  if task._target_kind == "owned" and e and e.valid then
    if not recoverable(e, task.allow_fluid_loss) then
      c.mining_state = { mining = false }
      return partial_failure(task, "refusing to continue recovery after the player-owned entity gained fluid contents")
    end
    local inv = c.get_main_inventory()
    if inv and not character_accepts_products(inv, e, entity_contents(e)) then
      c.mining_state = { mining = false }
      return partial_failure(task, "the entity's contents grew past the room in Codex inventory")
    end
  end
  local current_amount = entity_amount(e)
  local target_changed = not (e and e.valid)
    or (task._target_amount ~= nil and current_amount ~= nil and current_amount < task._target_amount)
  if not target_changed then
    if task._cycle_deadline and game.tick > task._cycle_deadline then
      c.mining_state = { mining = false }
      return partial_failure(task, string.format(
        "MINING_STALLED: the physical mining cycle of %s did not finish within %d ticks", task._entity_name,
        cycle_ticks(c, e)))
    end
    -- The engine holds a natural cycle whose products no longer fit (finished
    -- hand-crafts can fill the last slots mid-cycle).
    if task._target_kind ~= "owned" then
      local inv = c.get_main_inventory()
      if inv and not character_accepts_products(inv, e, nil) then
        c.mining_state = { mining = false }
        return partial_failure(task, "Codex inventory is full: it filled during the mining cycle")
      end
    end
    -- A real connected client can clear LuaPlayer.selected from its native
    -- input state between ticks. Reassert the already-resolved exact entity
    -- and physical mining state; never resolve or switch to a nearby target.
    if c.selected ~= e then c.selected = e end
    if c.selected ~= e then
      c.mining_state = { mining = false }
      return selection_failure(task, c, e, "reselection", "TARGET_NOT_SELECTABLE")
    end
    c.mining_state = { mining = true, position = e.position }
    return nil
  end

  c.mining_state = { mining = false }
  local inv = c.get_main_inventory()
  local gained = 0
  if inv then
    for _, name in ipairs(task._expected_items) do
      gained = gained + math.max(0, inv.get_item_count(name) - (task._inventory_before[name] or 0))
    end
  end
  if gained <= 0 then
    return partial_failure(task, "the exact target changed without mined items reaching Codex inventory")
  end
  task._completed = task._completed + 1
  task._actual_gain = task._actual_gain + gained
  task._mining_started = false
  if task._completed >= task._requested then
    local hint = drill_hint(c, task)
    return {
      status = "done",
      detail = string.format("mined %s at exact coordinate: requested %d cycles, completed %d, actual gain %d items%s%s",
        task._entity_name, task._requested, task._completed, task._actual_gain,
        fluid_loss_detail(task._discarded_fluids),
        hint and string.format("; drill_produced: %d own mining drill(s) already mine %s%s - take it from their chests and belts",
          hint.drills, task._entity_name,
          hint.stockpile_total and string.format(", stockpile_total %d", math.floor(hint.stockpile_total)) or "") or ""),
      outcome = hint,
    }
  end
  if not (e and e.valid) then
    if task._resolved_target.type == "resource" then
      return partial_failure(task, "the initially selected resource was exhausted")
    end
    local nxt = next_natural(c, task)
    if not nxt then
      return partial_failure(task, string.format("no other %s within %d tiles", task._resolved_target.type,
        NEXT_RADII[#NEXT_RADII]))
    end
    task._entity, task._entity_name, task._expected_items = nxt, nxt.name, expected_item_names(nxt)
    task._approach, task._approach_close = nil, nil
  end
  return nil
end

-- A walk whose start a tree or rock blocks mines it through this runner.
walk.start_clearer = M

return M
