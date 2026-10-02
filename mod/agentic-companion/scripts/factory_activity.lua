-- Run-local character transfer telemetry. This records only physical transfers
-- performed through the sole task queue; it is not a second coordination store.
local M = {}
local MAX_EVENTS = 128
local MAX_RETURNED_EVENTS = 8
local MAX_TARGET_ROWS = 16
local MAX_VALIDATIONS = 32

local function ensure()
  storage.factory_activity = storage.factory_activity or {
    epoch_tick = game and game.tick or 0, events = {}, events_omitted = 0,
    validations = {}, validations_omitted = 0,
  }
  storage.factory_activity.validations = storage.factory_activity.validations or {}
  storage.factory_activity.validations_omitted = storage.factory_activity.validations_omitted or 0
  return storage.factory_activity
end

function M.record_validation(result, signature)
  local native = type(result) == "table" and (result.native_source_activity_samples ~= nil
    or result.fluid_activity_samples ~= nil or result.power_delivery_samples ~= nil
    or result.mining_sources_present ~= nil or result.native_power_required ~= nil)
  local source_proven = type(result) == "table" and (tonumber(result.source_cycles_observed) or 0) >= 3
  if native then
    local water_proven = (tonumber(result.native_source_activity_samples) or 0) >= 3
    source_proven = (source_proven or water_proven and (result.mining_sources_present == false
      or (tonumber(result.fuel_source_cycles_observed) or 0) >= 1))
      and (result.native_source_activity_samples == nil or water_proven)
      and (tonumber(result.fluid_activity_samples) or 0) >= 3
      and type(result.mining_sources_present) == "boolean"
      and type(result.native_power_required) == "boolean"
      and (not result.native_power_required or (tonumber(result.power_delivery_samples) or 0) >= 3)
  end
  if type(signature) ~= "string" or type(result) ~= "table" or type(result.component_signature) ~= "string"
    or result.proven ~= true or (tonumber(result.duration_ticks) or 0) < 1
    -- The parked validator checks every processor present. Source-only proof
    -- has source cycles and acceptance evidence without crafting production.
    or (tonumber(result.products_finished_delta) or -1) < 0
    or (tonumber(result.downstream_acceptance_samples) or 0) < 3
    or not source_proven
    or (tonumber(result.character_transfer_actions) or 0) ~= 0 then return end
  local activity = ensure()
  activity.validations[#activity.validations + 1] = {
    component_signature = result.component_signature, _signature = signature,
    downstream_kind = result.downstream_kind, downstream_acceptance_samples = result.downstream_acceptance_samples,
    source_cycles_observed = result.source_cycles_observed,
    native_source_activity_samples = result.native_source_activity_samples,
    fluid_activity_samples = result.fluid_activity_samples, power_delivery_samples = result.power_delivery_samples,
    mining_sources_present = result.mining_sources_present, native_power_required = result.native_power_required,
    fuel_source_cycles_observed = result.fuel_source_cycles_observed,
    start_tick = result.start_tick, end_tick = result.end_tick,
    duration_ticks = result.duration_ticks, products_finished_delta = result.products_finished_delta,
    character_transfer_actions = result.character_transfer_actions,
    proven = true, evidence_class = "bounded_multi_tick_component_validation",
  }
  if #activity.validations > MAX_VALIDATIONS then
    table.remove(activity.validations, 1)
    activity.validations_omitted = activity.validations_omitted + 1
  end
end

local function target_identity(target)
  if type(target) ~= "table" or type(target.position) ~= "table" then return nil end
  return {
    name = target.name, type = target.type,
    position = { x = target.position.x, y = target.position.y },
  }
end

function M.record(kind, outcome)
  if kind ~= "insert" and kind ~= "extract" then return end
  if type(outcome) ~= "table" or type(outcome.transfers) ~= "table" then return end
  local moved, items = 0, {}
  for _, row in ipairs(outcome.transfers) do
    local count = tonumber(kind == "insert" and row.inserted or row.extracted) or 0
    if type(row.item) == "string" and count > 0 then
      moved = moved + count
      items[#items + 1] = { name = row.item, count = count }
    end
  end
  if moved == 0 then return end
  table.sort(items, function(a, b) return a.name < b.name end)
  local activity = ensure()
  activity.events[#activity.events + 1] = {
    tick = game.tick, action = kind, item_count = moved,
    target = target_identity(outcome.target), items = items,
  }
  if #activity.events > MAX_EVENTS then
    local evicted = table.remove(activity.events, 1)
    activity.latest_evicted_tick = evicted.tick
    activity.events_omitted = activity.events_omitted + 1
  end
end

function M.snapshot(since_tick, internal)
  local activity = ensure()
  since_tick = tonumber(since_tick) or activity.epoch_tick
  if since_tick < activity.epoch_tick or since_tick > game.tick then
    error("activity_since_tick must be within the current run-local activity epoch")
  end
  local inserted, extracted, events, targets, action_count, item_count = {}, {}, {}, {}, 0, 0
  local oldest = activity.events[1] and activity.events[1].tick or game.tick
  for _, event in ipairs(activity.events) do
    if event.tick >= since_tick then
      events[#events + 1] = event
      action_count = action_count + 1
      item_count = item_count + event.item_count
      local bucket = event.action == "insert" and inserted or extracted
      for _, item in ipairs(event.items) do bucket[item.name] = (bucket[item.name] or 0) + item.count end
      if event.target and event.target.position then
        local key = string.format("%s\0%s\0%.17g\0%.17g", event.target.name or "", event.target.type or "",
          event.target.position.x, event.target.position.y)
        local row = targets[key] or { target = event.target, transfer_actions = 0, transferred_items = 0,
          last_transfer_tick = event.tick }
        targets[key] = row; row.transfer_actions = row.transfer_actions + 1; row.transferred_items = row.transferred_items + event.item_count
        row.last_transfer_tick = math.max(row.last_transfer_tick or event.tick, event.tick)
      end
    end
  end
  local function item_rows(bucket)
    local rows = {}; for name, count in pairs(bucket) do rows[#rows + 1] = { name = name, count = count } end
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
  end
  local complete = activity.events_omitted == 0 or since_tick > (activity.latest_evicted_tick or oldest)
  local target_rows = {}; for _, row in pairs(targets) do target_rows[#target_rows + 1] = row end
  table.sort(target_rows, function(a, b)
    local ap, bp = a.target.position, b.target.position
    return ap.y == bp.y and (ap.x == bp.x and (a.target.name or "") < (b.target.name or "") or ap.x < bp.x) or ap.y < bp.y
  end)
  local omitted_targets = math.max(0, #target_rows - MAX_TARGET_ROWS)
  if not internal then while #target_rows > MAX_TARGET_ROWS do table.remove(target_rows) end end
  local omitted_events = math.max(0, #events - MAX_RETURNED_EVENTS)
  while #events > MAX_RETURNED_EVENTS do table.remove(events, 1) end
  local validations = {}
  for _, validation in ipairs(activity.validations) do
    if validation.end_tick >= since_tick then
      if internal then validations[#validations + 1] = validation
      else
        local public = {}; for key, value in pairs(validation) do if key ~= "_signature" then public[key] = value end end
        validations[#validations + 1] = public
      end
    end
  end
  return {
    epoch_tick = activity.epoch_tick, since_tick = since_tick, end_tick = game.tick,
    transfer_actions = action_count, transferred_items = item_count,
    inserted_items = item_rows(inserted), extracted_items = item_rows(extracted),
    target_actions = target_rows, target_actions_omitted = omitted_targets,
    events = events, events_omitted_in_window = omitted_events,
    events_omitted_before_window = complete and 0 or activity.events_omitted,
    validations = validations, validations_omitted = activity.validations_omitted,
    history_complete = complete,
  }
end

return M
