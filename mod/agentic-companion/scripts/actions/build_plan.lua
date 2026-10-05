-- build_plan: place many entities in one task. Walks within build reach of
-- each step, places the item, then
-- optionally mirrored, sets a recipe, settings (entity_settings: inserter
-- filters, splitter priorities, chest limits) and inserts starter items — mirroring the exact
-- validation rules of the single-step place/set_recipe/insert actions
-- (scripts/actions/build.lua, scripts/actions/transfer.lua). A failed step is
-- recorded and skipped unless stop_on_error. Output-target verification keeps
-- the exact placed entity. Mining-drill starter insertion happens once before
-- waiting for first output to expose Factorio's authoritative runtime target.
-- Auto-supply (default on) fetches what the rest of the plan needs of a
-- step's items in one trip; trees and rocks in a footprint are mined first.
-- Bounded recoveries, once per step: walk out of a footprint the body
-- overlaps, re-approach a placed entity out of reach, retry a partial
-- starter insert after a second. Placement is idempotent: the same entity
-- already standing there counts as placed (turned when it faces another
-- way), and its recipe and starter items are still applied.
local companion = require("scripts.companion")
local registry = require("scripts.registry")
local approach = require("scripts.actions.approach")
local output_targets = require("scripts.output_target")
local placement_geometry = require("scripts.placement_geometry")
local factory_activity = require("scripts.factory_activity")
local build = require("scripts.actions.build")
local entity_settings = require("scripts.entity_settings")
local supply = require("scripts.actions.supply")
local transfer = require("scripts.actions.transfer")
local craft = require("scripts.actions.craft")

local M = {}

local MAX_STEPS = 200
local INSERT_RETRY_TICKS = 60
local MAX_FAILURES_LISTED = 5
local FUEL_PER_BURNER = 5

-- Burner machines among steps (by their placed entity) that name no starter
-- items get fuel: the first fuel the body carries or the force stores, else
-- coal (supply fetches or gathers it).
function M.fuel_burners(c, steps)
  local fuel
  for _, step in ipairs(steps) do
    local item = prototypes.item[step.item]
    local proto = item and item.place_result
    local ok, burner = pcall(function() return proto and proto.burner_prototype end)
    if step.insert == nil and ok and burner then
      fuel = fuel or supply.fuel_item(c) or "coal"
      step.insert = { [fuel] = FUEL_PER_BURNER }
    end
  end
  return steps
end

-- ------------------------------------------------------------- validation

-- Returns nil when the step is well-formed, else a human-readable reason.
local function malformed(step)
  if type(step) ~= "table" then
    return 'each step must be an object like {"item":"transport-belt","position":{"x":1,"y":2}}'
  end
  if type(step.item) ~= "string" then
    return "item must be an item name string"
  end
  local p = step.position
  if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number" then
    return "position must be {x, y} with numeric coordinates"
  end
  if step.direction ~= nil and type(step.direction) ~= "number" then
    return "direction must be a number (16-way: 0=N, 4=E, 8=S, 12=W)"
  end
  if step.output_target ~= nil then
    local target = step.output_target
    if type(target) ~= "table" or type(target.x) ~= "number" or type(target.y) ~= "number" then
      return "output_target must be {x, y} with numeric coordinates"
    end
  end
  if step.input_target ~= nil then
    local target = step.input_target
    if type(target) ~= "table" or type(target.x) ~= "number" or type(target.y) ~= "number" then
      return "input_target must be {x, y} with numeric coordinates"
    end
  end
  if step.belt_to_ground_type ~= nil and step.belt_to_ground_type ~= "input" and step.belt_to_ground_type ~= "output" then
    return 'belt_to_ground_type must be "input" or "output"'
  end
  if step.recipe ~= nil and type(step.recipe) ~= "string" then
    return "recipe must be a recipe name string"
  end
  if step.settings ~= nil and type(step.settings) ~= "table" then
    return "settings must be an object of inserter, splitter or chest settings"
  end
  -- Settings are checked before anything is built, as build_layout does; a
  -- 0.21.1 step still queued keeps its blueprint-style settings unchecked.
  if step.settings ~= nil and not entity_settings.legacy(step.settings) then
    local ok, err = pcall(entity_settings.validate, step.settings, "settings")
    if not ok then return tostring(err) end
    local item = prototypes.item[step.item]
    local result = item and item.place_result
    local code, message
    if result then code, message = entity_settings.check_prototype(result, step.settings) end
    if code then return message end
  end
  if step.mirror ~= nil and type(step.mirror) ~= "boolean" then
    return "mirror must be true or false"
  end
  if step.insert ~= nil then
    if type(step.insert) ~= "table" then
      return 'insert must map item names to counts, e.g. {"coal":5}'
    end
    for name, count in pairs(step.insert) do
      if type(name) ~= "string" or type(count) ~= "number" or count < 1 then
        return "insert must map item names to positive counts"
      end
    end
  end
  return nil
end

function M.start(task)
  companion.require_companion()
  if type(task.steps) ~= "table" or #task.steps == 0 then
    error('build_plan requires steps = a non-empty array like [{"item":"transport-belt","position":{"x":1,"y":2}}]')
  end
  if #task.steps > MAX_STEPS then
    error(string.format("build_plan takes at most %d steps (you sent %d) — split the plan into smaller batches",
      MAX_STEPS, #task.steps))
  end
  for i, step in ipairs(task.steps) do
    local why = malformed(step)
    if why then
      error(string.format("step %d is malformed: %s", i, why))
    end
  end

  local c = companion.require_companion()
  for index, step in ipairs(task.steps) do
    step.direction = math.floor(tonumber(step.direction) or 0) % 16
    local proto = prototypes.item[step.item]
    if step.belt_to_ground_type ~= nil and proto and proto.place_result then
      local belt_error = build.belt_to_ground_error(step.item, proto.place_result, step.belt_to_ground_type)
      if belt_error then error(string.format("step %d is malformed: %s", index, belt_error)) end
    end
    -- Nothing is placed when any entity's surface conditions fail here.
    local refused = proto and proto.place_result
      and placement_geometry.condition_refusal(c.surface, "entity", proto.place_result.name)
    if refused then error(string.format("step %d: %s", index, refused.reason), 0) end
    local function prepare_target(target, kind)
      local result = proto and proto.place_result
      if kind == "input" and (not result or result.type ~= "inserter") then
        error(step.item .. " has no deterministic input target")
      end
      local label = "build_plan " .. kind .. "_target"
      local function earlier_matches(endpoint)
        local count, match_index = 0, nil
        for earlier = 1, index - 1 do
          local candidate = task.steps[earlier]
          local item = prototypes.item[candidate.item]
          local target_proto = item and item.place_result
          local dx, dy = candidate.position.x - c.position.x, candidate.position.y - c.position.y
          if target_proto and dx * dx + dy * dy <= 900
            and c.force.is_chunk_charted(c.surface, { x = math.floor(candidate.position.x / 32), y = math.floor(candidate.position.y / 32) })
            and output_targets.can_target_type(target_proto.type, kind)
            and output_targets.recipient_contains(placement_geometry.footprint(target_proto,
              candidate.position, candidate.direction), endpoint, result.type, kind) then
            count, match_index = count + 1, earlier
          end
        end
        return count, match_index
      end
      local ok, resolved = pcall(output_targets.resolve, c, target, label, kind)
      if ok then
        step["_" .. kind .. "_target"] = resolved
        local matches, endpoint
        if result then
          if kind == "input" then
            matches, endpoint = output_targets.input_geometry_matches(c, result,
              step.position, step.direction, resolved.entity)
          else
            matches, endpoint = output_targets.geometry_matches(c, result,
              step.position, step.direction, resolved.entity)
          end
        end
        if endpoint and earlier_matches(endpoint) > 0 then error(label .. " is ambiguous among existing and earlier placements") end
        if not matches then
          error(string.format("%s is not at the exact provisional %s endpoint%s", label, kind,
            endpoint and string.format(" (%.1f, %.1f)", endpoint.x, endpoint.y) or ""))
        end
      else
        local planned_index, planned
        for earlier = 1, index - 1 do
          local candidate = task.steps[earlier]
          if candidate.position.x == target.x and candidate.position.y == target.y then
            if planned then error(label .. " is ambiguous among earlier placements") end
            planned_index, planned = earlier, candidate
          end
        end
        local target_item = planned and prototypes.item[planned.item]
        local target_proto = target_item and target_item.place_result
        if not target_proto then error(tostring(resolved)) end
        if not output_targets.can_target_type(target_proto.type, kind) then
          error(label .. " identifies planned " .. target_proto.name .. ", which is not a supported "
            .. (kind == "input" and "pickup source" or "drop recipient"))
        end
        local endpoint
        if result then
          if kind == "input" then
            endpoint = output_targets.input_position(result, step.position, step.direction)
          else
            endpoint = output_targets.output_position(result, step.position, step.direction)
          end
        end
        local footprint = placement_geometry.footprint(target_proto, planned.position, planned.direction)
        if not endpoint or not output_targets.recipient_contains(footprint, endpoint, result.type, kind) then
          error(string.format("%s is not at the exact provisional %s endpoint%s", label, kind,
            endpoint and string.format(" (%.1f, %.1f)", endpoint.x, endpoint.y) or ""))
        end
        local _, _, state = output_targets.recipient_at(c, endpoint, kind, result.type)
        local count, match_index = earlier_matches(endpoint)
        if state ~= "none" or count ~= 1 or match_index ~= planned_index then
          error(label .. " is ambiguous or unavailable among existing and earlier placements")
        end
        step["_planned_" .. kind .. "_target"] = { step = planned_index }
      end
    end
    if step.input_target ~= nil then prepare_target(step.input_target, "input") end
    if step.output_target ~= nil then prepare_target(step.output_target, "output") end
    if step.insert ~= nil then
      -- {"coal":10} → sorted {name, count} list for deterministic messages.
      local list = {}
      for name, count in pairs(step.insert) do
        list[#list + 1] = { name = name, count = math.floor(count) }
      end
      table.sort(list, function(a, b) return a.name < b.name end)
      if #list > 0 then step._insert = list end
    end
  end

  -- auto_craft is the 0.20 name of auto_supply.
  task.auto_supply = task.auto_supply ~= false and task.auto_craft ~= false
  task._short, task._supplied_index = {}, nil
  task._built = nil

  task.stop_on_error = task.stop_on_error ~= false
  task._index = 1
  task._placed = 0
  task._results = {}
  task._failures = {}
end

-- What the rest of the plan needs of this step's item and starter items,
-- for each one the body carries too few of: fetched in one trip.
local function step_needs(task, c, step)
  local names = { step.item }
  for _, it in ipairs(step._insert or {}) do names[#names + 1] = it.name end
  local needs, seen = {}, {}
  for _, name in ipairs(names) do
    if not seen[name] and not task._short[name] then
      seen[name] = true
      local total = 0
      for index = task._index, #task.steps do
        local later = task.steps[index]
        if later.item == name then total = total + 1 end
        for _, it in ipairs(later._insert or {}) do if it.name == name then total = total + it.count end end
      end
      if c.get_item_count(name) < total then needs[#needs + 1] = { name = name, count = total } end
    end
  end
  return needs
end

-- ------------------------------------------------------------ step pieces

-- Why can_place_entity said no: build.lua's own answer.
local blocked_reason = build.blocked_reason

-- Same rules as build.lua's set_recipe, applied to the freshly placed entity.
-- Returns nil on success, else a reason string.
local function apply_recipe(c, e, recipe_name)
  local r = c.force.recipes[recipe_name]
  if not r then
    return "unknown recipe: '" .. recipe_name .. "'"
  end
  if not r.enabled then
    return "recipe " .. recipe_name .. " isn't unlocked yet — research it first"
  end
  if e.type ~= "assembling-machine" then
    if e.type == "furnace" then
      return "the " .. e.name .. " is a furnace — it picks its recipe automatically from what you insert"
    end
    return "the " .. e.name .. " can't have a recipe set — only crafting machines can"
  end
  -- An entity already in place may already craft it: nothing to change.
  local has_ok, current = pcall(e.get_recipe)
  if has_ok and current and current.name == recipe_name then return nil end
  local ok, removed = pcall(e.set_recipe, recipe_name)
  if not ok then
    return string.format("couldn't set recipe %s on the %s — that machine probably can't craft it",
      recipe_name, e.name)
  end
  -- Anything the recipe change hands back goes to us; overflow spills.
  if type(removed) == "table" then
    for _, stack in ipairs(removed) do
      if stack.name and (stack.count or 0) > 0 then
        local kept = c.insert({ name = stack.name, count = stack.count })
        if kept < stack.count then
          pcall(c.surface.spill_item_stack, {
            position = c.position,
            stack = { name = stack.name, count = stack.count - kept },
            force = c.force,
          })
        end
      end
    end
  end
  local read_ok, assigned = pcall(e.get_recipe)
  if not read_ok or not assigned or assigned.name ~= recipe_name then
    return string.format("couldn't set recipe %s on the %s — that machine probably can't craft it",
      recipe_name, e.name)
  end
  return nil
end

-- --------------------------------------------------------------- progress

local function summary(task)
  local s = string.format("placed %d/%d", task._placed, #task.steps)
  local f = task._failures
  if #f > 0 then
    local parts = {}
    for i = 1, math.min(#f, MAX_FAILURES_LISTED) do
      parts[#parts + 1] = string.format("step %d failed: %s", f[i].index, f[i].why)
    end
    s = s .. " — " .. table.concat(parts, "; ")
    if #f > MAX_FAILURES_LISTED then
      s = s .. string.format("; … and %d more failures", #f - MAX_FAILURES_LISTED)
    end
  end
  local notes = {}
  for i, result in ipairs(task._results) do
    if result.ok and result.detail then notes[#notes + 1] = string.format("step %d: %s", i, result.detail) end
  end
  if #notes > 0 then s = s .. " — " .. table.concat(notes, "; ") end
  return s
end

-- A failed build names its own code, so the dispatcher never reruns the
-- whole plan from its first placement.
local function failure(task, detail)
  return { status = "failed", detail = detail, outcome = { code = "BUILD_PLAN_STEP_FAILED",
    placed = task._placed, total = #task.steps, failures = task._failures } }
end

local function finished(task)
  -- A later native pairing may also change a previously completed end.
  for i, step in ipairs(task.steps) do
    local result = task._results[i]
    local mismatch = result and result.ok and build.underground_error(step._placed_entity,
      step.direction, step.belt_to_ground_type)
    if mismatch then
      task._underground_mismatch = true
      task._results[i] = { ok = false, why = mismatch }
      task._failures[#task._failures + 1] = { index = i, why = mismatch }
    end
  end
  if task._placed == 0 or task._underground_mismatch then
    return failure(task, summary(task))
  end
  return { status = "done", detail = summary(task) }
end

-- Record the current step's outcome and move to the next. Returns the task
-- result when the plan is over (or stop_on_error tripped), else nil.
local function advance(task, ok, why)
  local i = task._index
  task._results[i] = ok and { ok = true, detail = why } or { ok = false, why = why }
  if not ok then
    task._failures[#task._failures + 1] = { index = i, why = why }
  end
  task._built, task._interactions_applied, task._recipe_applied, task._note = nil, nil, nil, nil
  task._settings_applied = nil
  task._insert_remainder, task._insert_first, task._retry_tick = nil, nil, nil
  task._expected_input, task._expected_output, task._output_verification_tick = nil, nil, nil
  task._index = i + 1
  if not ok and task.stop_on_error then
    return failure(task, summary(task) .. " — stopped at the first failure (stop_on_error)")
  end
  if task._index > #task.steps then
    return finished(task)
  end
  return nil
end

-- Finish optional interactions on an entity that was already placed. Building
-- uses build_distance; recipe/inventory mutations use Factorio's authoritative
-- entity-reach check through the shared physical approach state machine.
local function finish_placed_step(task, c, step, built)
  local mismatch = build.underground_error(built, step.direction, step.belt_to_ground_type)
  if mismatch then
    task._underground_mismatch = true
    return advance(task, false, mismatch)
  end
  local input_binding, output_binding = "matched", "matched"
  if task._expected_input then
    input_binding = output_targets.binding_status(built, task._expected_input,
      task._output_verification_tick, "input")
  end
  if task._expected_output then
    output_binding = output_targets.binding_status(built, task._expected_output,
      task._output_verification_tick, "output")
  end
  local binding, binding_kind = input_binding ~= "matched" and input_binding or output_binding,
    input_binding ~= "matched" and "input" or "output"
  if task._expected_input or task._expected_output then
    if binding == "invalid" then
      task._built = nil
      return advance(task, false, "the exact placed entity vanished before runtime binding could be verified")
    end
    if binding == "target-invalid" then
      task._built = nil
      return advance(task, false, "the exact expected " .. binding_kind .. " target vanished before runtime binding could be verified")
    end
    if binding == "mismatch" then
      task._built = nil
      return advance(task, false, string.format(
        "placed %s at (%.1f, %.1f), but Factorio exposed a different runtime %s target; recover the exact placed entity before retrying",
        step.item, built.position.x, built.position.y, binding_kind))
    end
    if binding ~= "pending" and binding ~= "pending-output" and binding ~= "matched" then
      task._built = nil
      return advance(task, false, string.format(
        "placed %s at (%.1f, %.1f), but Factorio did not bind the expected runtime %s target (%s); recover the exact placed entity before retrying",
        step.item, built.position.x, built.position.y, binding_kind, binding))
    end
  end

  if (step.recipe or step._insert or step.settings) and not task._interactions_applied then
    local reached = approach.ensure_entity(task, c, built)
    if type(reached) == "table" and task._reach_index ~= task._index then
      -- Out of reach once: approach the placed entity again from scratch.
      task._reach_index, task._approach, task._approach_close = task._index, nil, nil
      return nil
    end
    if type(reached) == "table" then
      task._built = nil
      return advance(task, false, string.format("placed the %s, but %s", step.item, reached.detail))
    end
    if reached ~= "ok" then return nil end
  end

  if not task._interactions_applied then
    if task._retry_tick and game.tick < task._retry_tick then return nil end
    -- Starter items still in the crafting queue are waited for.
    if transfer.awaits_crafting(c, task._insert_remainder or step._insert or {}) then return nil end
    local issues = {}
    if not built.valid then
      issues[#issues + 1] = "the placed entity vanished immediately (another mod removed it?)"
    else
      if step.recipe and not task._recipe_applied then
        task._recipe_applied = true
        local why = apply_recipe(c, built, step.recipe)
        if why then issues[#issues + 1] = why end
      end
      if step.settings and not task._settings_applied then
        -- A setting the entity does not take is a note, never a failure.
        task._settings_applied = true
        local _, notes = entity_settings.apply(built, step.settings)
        if #notes > 0 then
          task._note = (task._note and (task._note .. "; ") or "") .. table.concat(notes, "; ")
        end
      end
      local list = task._insert_remainder or step._insert
      if list then
        local problems, inserted, transfers = transfer.insert_list(c, built, list)
        factory_activity.record("insert", { target = {
          name = built.name, type = built.type, position = built.position,
        }, transfers = transfers })
        local first = task._insert_first
        if first then
          -- The retry's rows join the first attempt's: requested stays the original.
          for _, row in ipairs(first.transfers) do
            for _, again in ipairs(transfers) do
              if again.item == row.item then row.inserted, row.remainder = row.inserted + again.inserted, row.remainder - again.inserted end
            end
          end
          inserted, transfers = first.inserted + inserted, first.transfers
        elseif #problems > 0 and inserted > 0 and #issues == 0 then
          -- Partial once: retry the remainder after a second.
          local remainder = {}
          for _, row in ipairs(transfers) do
            if row.remainder > 0 then remainder[#remainder + 1] = { name = row.item, count = row.remainder } end
          end
          task._insert_first, task._insert_remainder = { inserted = inserted, transfers = transfers }, remainder
          task._retry_tick = game.tick + INSERT_RETRY_TICKS
          return nil
        end
        for _, problem in ipairs(problems) do issues[#issues + 1] = problem end
        if #problems > 0 and inserted > 0 then
          task._built = nil
          return { status = "partial", detail = string.format("placed the %s, then partially inserted starter items — %s",
            step.item, table.concat(problems, "; ")),
            outcome = { code = "PARTIAL_INSERT", total_inserted = inserted, transfers = transfers } }
        end
      end
    end
    if #issues > 0 then
      task._built = nil
      return advance(task, false, string.format("placed the %s, but %s",
        step.item, table.concat(issues, "; ")))
    end
    task._interactions_applied = true
  end

  if task._expected_input or task._expected_output then
    if input_binding == "pending" or output_binding == "pending" then return nil end
    if output_binding == "pending-output" and built.type == "mining-drill" and step._insert then return nil end
    task._expected_input, task._expected_output, task._output_verification_tick = nil, nil, nil
  end
  task._built, task._interactions_applied = nil, nil
  local detail = output_binding == "pending-output"
    and "provisional output geometry is valid; Factorio's runtime output target is pending first output" or task._note
  local pairing = build.underground_pairing(built)
  if pairing then
    local note = "placed " .. step.item .. build.pairing_note(pairing)
    detail = detail and (detail .. "; " .. note) or note
  end
  return advance(task, true, detail)
end

-- ------------------------------------------------------------------- tick

M.resume = supply.resume

function M.tick(task)
  local c = companion.get()
  if not c then
    return { status = "failed", detail = summary(task) .. " — the companion character is gone" }
  end
  -- A build started by 0.20 before an in-place upgrade has auto_craft and no
  -- supply state: give it what start() gives a new one. Crafts it already
  -- queued finish in the crafting queue; supply tops up what is missing.
  if task._short == nil then
    task._short = {}
    task.auto_supply = task.auto_supply ~= false and task.auto_craft ~= false
  end

  local step = task.steps[task._index]
  if not step then return finished(task) end
  if task._built then return finish_placed_step(task, c, step, task._built) end
  if task._exit then
    local walked = supply.step(task, "_exit")
    if not walked then return nil end
    if walked.status ~= "done" then
      return advance(task, false, string.format("can't place %s at (%.1f, %.1f) — CODEX_BODY_OVERLAP and walking clear failed: %s",
        step.item, step.position.x, step.position.y, tostring(walked.detail)))
    end
  end

  -- Checks that walking can never fix (mirrors place.start, which also runs
  -- before any walking): unknown item, unplaceable item, none in inventory.
  local proto = prototypes.item[step.item]
  if not proto then
    return advance(task, false, "no item called '" .. step.item .. "'")
  end
  local place_result = proto.place_result
  if not place_result then
    return advance(task, false, step.item .. " is not a placeable item")
  end
  -- The same entity already standing there is this step's placement.
  if task._existing_index ~= task._index then
    task._existing_index = task._index
    task._existing = build.existing(c, place_result, step.position, step.direction, step.belt_to_ground_type)
  end
  if task._existing then
    local e = task._existing
    local how = build.adopt(task, c, e, step.direction, step.mirror, step.belt_to_ground_type)
    if how == nil then return nil end
    task._existing = nil
    if type(how) == "table" then
      if how.outcome and how.outcome.code == "UNDERGROUND_CONFIGURATION_MISMATCH" then
        task._underground_mismatch = true
      end
      return advance(task, false, how.detail)
    end
    if how ~= "gone" then
      step._placed_entity = e
      task._placed = task._placed + 1
      task._note, task._built = build.adopted_note(e, how), e
      return finish_placed_step(task, c, step, e)
    end
  end
  if task.auto_supply and task._supplied_index ~= task._index then
    local needs = step_needs(task, c, step)
    if #needs > 0 then
      local result = supply.ensure(task, needs)
      if not result then return nil end
      if result.status ~= "done" then
        -- An item once short is not fetched again in this build; its reason stays.
        for _, row in ipairs(result.outcome and result.outcome.missing or {}) do task._short[row.item] = result.detail end
      end
    end
    task._supplied_index = task._index
  end
  -- Still in the crafting queue: walk on, wait for it at the placement.
  if c.get_item_count(step.item) == 0 and craft.queued(c, step.item) == 0 then
    return advance(task, false, "I don't have any " .. step.item .. " left in my inventory"
      .. (task._short[step.item] and (" — " .. task._short[step.item]) or ""))
  end

  -- A tree or rock being cleared moves the body: finish that first.
  if task._clear then
    local cleared = build.clear_footprint(task, c, place_result, step.position, step.direction)
    if cleared == nil then return nil end
    if cleared ~= "ok" then return advance(task, false, cleared.detail) end
  end
  local reached = approach.ensure(task, c, step.position, c.build_distance)
  if type(reached) == "table" then
    return advance(task, false, reached.detail)
  end
  if reached ~= "ok" then return nil end
  local cleared = build.clear_footprint(task, c, place_result, step.position, step.direction)
  if cleared == nil then return nil end
  if cleared ~= "ok" then return advance(task, false, cleared.detail) end
  if craft.awaits(c, step.item, 1) then return nil end
  if c.get_item_count(step.item) == 0 then
    return advance(task, false, "I don't have any " .. step.item .. " left in my inventory")
  end

  local entity_name = place_result.name

  local expected_input, expected_output
  if step.input_target then
    local current = output_targets.resolve(c, step.input_target, "build_plan input_target", "input")
    if step._input_target and current.entity ~= step._input_target.entity then
      return advance(task, false, "input_target changed before placement; observe again")
    end
    if step._planned_input_target and current.entity ~= task.steps[step._planned_input_target.step]._placed_entity then
      return advance(task, false, "planned input_target has the wrong runtime identity; observe again")
    end
    local matches = output_targets.input_geometry_matches(c, place_result,
      step.position, step.direction, current.entity)
    if not matches then
      return advance(task, false, "provisional input geometry changed before placement; observe again")
    end
    expected_input = current.entity
  end
  if step.output_target then
    local current = output_targets.resolve(c, step.output_target, "build_plan output_target")
    if step._output_target and current.entity ~= step._output_target.entity then
      return advance(task, false, "output_target changed before placement; observe again")
    end
    if step._planned_output_target and current.entity ~= task.steps[step._planned_output_target.step]._placed_entity then
      return advance(task, false, "planned output_target has the wrong runtime identity; observe again")
    end
    local matches = output_targets.geometry_matches(c, place_result, step.position, step.direction, current.entity)
    if not matches then
      return advance(task, false, "provisional output geometry changed before placement; observe again")
    end
    expected_output = current.entity
  end

  local can_place, placement_reason = placement_geometry.can_place(c, place_result, step.position, step.direction)
  if not can_place and placement_reason == "CODEX_BODY_OVERLAP" and task._exit_index ~= task._index then
    -- Standing in the footprint once: walk clear of it, then try again.
    task._exit_index = task._index
    local exit = build.footprint_exit(c, place_result, step.position, step.direction)
    if exit and pcall(supply.begin, task, "_exit", { type = "walk_to", target = exit, arrival_mode = "exact", arrival_radius = 1 }) then
      return nil
    end
  end
  if not can_place then
    return advance(task, false, string.format("can't place %s at (%.1f, %.1f) — %s",
      step.item, step.position.x, step.position.y,
      placement_reason == "CODEX_BODY_OVERLAP" and "CODEX_BODY_OVERLAP — walk clear of the exact collision footprint" or blocked_reason(c, step.position)))
  end

  local built = c.surface.create_entity({
    name = entity_name,
    position = step.position,
    direction = step.direction,
    mirror = step.mirror or nil,
    type = step.belt_to_ground_type,
    force = c.force,
    raise_built = true,
  })
  if not built then
    return advance(task, false, string.format(
      "placing %s at (%.1f, %.1f) failed unexpectedly — try a slightly different spot",
      step.item, step.position.x, step.position.y))
  end
  c.remove_item({ name = step.item, count = 1 })
  -- raise_built also reaches the registry; add is idempotent.
  pcall(registry.add, built)
  step._placed_entity = built
  task._placed = task._placed + 1
  if expected_input or expected_output then
    task._expected_input, task._expected_output = expected_input, expected_output
    task._output_verification_tick = game.tick
  end
  task._built = built
  return finish_placed_step(task, c, step, built)
end

return M
