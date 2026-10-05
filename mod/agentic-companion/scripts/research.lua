-- start_research: queue a technology on the companion's force.
local companion = require("scripts.companion")

local M = {}

local function id_filter(value)
  if type(value) == "string" then return value, nil end
  if type(value) ~= "table" or type(value.name) ~= "string" then return nil, nil end
  local filter = { name = value.name }
  if type(value.quality) == "string" then filter.quality = value.quality end
  if type(value.comparator) == "string" then filter.comparator = value.comparator end
  return value.name, filter
end

local function serializable_localised_string(value, depth, seen)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then return value end
  if kind ~= "table" or depth >= 20 or seen[value] then return nil end
  local length = #value
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then return nil end
  end
  local copy, next_seen = {}, {}
  for table_value in pairs(seen) do next_seen[table_value] = true end
  next_seen[value] = true
  for i = 1, length do
    copy[i] = serializable_localised_string(value[i], depth + 1, next_seen)
    if copy[i] == nil then return nil end
  end
  return copy
end

local function research_trigger(technology)
  local ok, trigger = pcall(function() return technology.prototype.research_trigger end)
  if not ok or type(trigger) ~= "table" or type(trigger.type) ~= "string" then return nil end

  local record = { type = trigger.type }
  if trigger.type == "craft-item" then
    record.item, record.item_filter = id_filter(trigger.item)
    if type(trigger.count) == "number" then record.count = trigger.count end
  elseif trigger.type == "mine-entity" then
    if type(trigger.entity) == "string" then record.entity = trigger.entity end
  elseif trigger.type == "craft-fluid" then
    if type(trigger.fluid) == "string" then record.fluid = trigger.fluid end
    if type(trigger.amount) == "number" then record.amount = trigger.amount end
  elseif trigger.type == "send-item-to-orbit" then
    record.item, record.item_filter = id_filter(trigger.item)
  elseif trigger.type == "capture-spawner" then
    if type(trigger.entity) == "string" then record.entity = trigger.entity end
  elseif trigger.type == "build-entity" then
    record.entity, record.entity_filter = id_filter(trigger.entity)
  elseif trigger.type == "scripted" then
    record.trigger_description = serializable_localised_string(trigger.trigger_description, 0, {})
  end
  return record
end

M.research_trigger = research_trigger

local function filter_action(filter)
  if not filter then return "" end
  if filter.quality then
    return " (quality " .. (filter.comparator or "=") .. " " .. filter.quality .. ")"
  end
  if filter.comparator then return " (quality comparator " .. filter.comparator .. ")" end
  return ""
end

local function trigger_action(trigger)
  local target = trigger.item or trigger.entity or trigger.fluid
  local quantity = trigger.count or trigger.amount
  local detail = ""
  if quantity and target then detail = " " .. tostring(quantity) .. " " .. target
  elseif target then detail = " " .. target end
  detail = detail .. filter_action(trigger.item_filter or trigger.entity_filter)
  if trigger.type == "scripted" and trigger.trigger_description then
    if type(trigger.trigger_description) == "string" then detail = " " .. trigger.trigger_description
    else detail = " described by progression_status" end
  end
  return trigger.type .. detail
end

M.trigger_action = trigger_action

-- start_research {technology} or {technologies = [...]}: a list is queued
-- in its order, each name checked as a single one would be; it stops at the
-- first the game refuses and says which were queued.
local MAX_TECHNOLOGIES = 7
local queue_one
function M.start_research(params)
  if params.technologies ~= nil then
    local list = params.technologies
    if params.technology ~= nil or type(list) ~= "table" or #list < 1 or #list > MAX_TECHNOLOGIES then
      error("start_research takes technology or technologies = 1-" .. MAX_TECHNOLOGIES .. " names in queue order")
    end
    local queued = {}
    for _, name in ipairs(list) do
      local ok, err = pcall(queue_one, name)
      if not ok then
        error(string.format("%s%s", tostring(err):gsub("^.-:%d+:%s*", ""),
          #queued > 0 and ("; queued before it: " .. table.concat(queued, ", ")) or ""))
      end
      queued[#queued + 1] = name
    end
    local force = companion.require_companion().force
    local queue = {}
    for _, technology in ipairs(force.research_queue or {}) do queue[#queue + 1] = technology.name end
    return { queued = true, technologies = queued, research_queue = queue }
  end
  return queue_one(params.technology)
end

function queue_one(name)
  if type(name) ~= "string" or name == "" then
    error('start_research needs a technology name, e.g. {"technology": "logistics"}')
  end

  local force = companion.require_companion().force

  local ok, tech = pcall(function() return force.technologies[name] end)
  if not ok or not tech then
    error("unknown technology: " .. name)
  end
  if tech.researched then
    error("already researched: " .. name)
  end
  local requested_trigger = research_trigger(tech)
  if requested_trigger then
    error("cannot queue trigger technology " .. name .. "; complete its in-game "
      .. trigger_action(requested_trigger) .. " trigger, then call progression_status again")
  end
  for _, queued in ipairs(force.research_queue) do
    if queued.name == name then
      error(name .. " is already in the research queue")
    end
  end
  if not force.add_research(name) then
    -- Most common cause: an unresearched trigger-tech prerequisite (2.0 early
    -- techs unlock by doing things in the world, not in a lab).
    local missing = {}
    for prereq_name, prereq in pairs(tech.prerequisites) do
      if not prereq.researched then
        local trigger = research_trigger(prereq)
        missing[#missing + 1] = {
          name = prereq_name,
          message = trigger
            and (prereq_name .. " requires in-game trigger " .. trigger_action(trigger) .. " and cannot be queued")
            or (prereq_name .. " must be researched first"),
        }
      end
    end
    if #missing > 0 then
      table.sort(missing, function(a, b) return a.name < b.name end)
      local messages = {}
      for _, entry in ipairs(missing) do messages[#messages + 1] = entry.message end
      error("can't queue " .. name .. " yet — missing prerequisites: " .. table.concat(messages, ", ")
        .. "; complete them, then call progression_status and retry")
    end
    error("could not queue " .. name .. " — the game refused it")
  end

  return { queued = true, technology = name }
end

function M.progression_status()
  local force = companion.require_companion().force
  local researched, available, trigger_unlocks, enabled_recipes = {}, {}, {}, {}
  local function technology_record(name, technology)
    local prerequisites, ready = {}, true
    for prereq_name, prerequisite in pairs(technology.prerequisites or {}) do
      prerequisites[#prerequisites + 1] = prereq_name
      if not prerequisite.researched then ready = false end
    end
    table.sort(prerequisites)
    local science = {}
    local ok, ingredients = pcall(function() return technology.prototype.research_unit_ingredients end)
    if ok then
      for _, ingredient in ipairs(ingredients or {}) do
        science[#science + 1] = { name = ingredient.name, amount = ingredient.amount }
      end
      table.sort(science, function(a, b) return a.name < b.name end)
    end
    local unlocks = {}
    local effects
    ok, effects = pcall(function() return technology.prototype.effects end)
    if ok then
      for _, effect in ipairs(effects or {}) do
        if effect.type == "unlock-recipe" and effect.recipe then unlocks[#unlocks + 1] = effect.recipe end
      end
    end
    table.sort(unlocks)
    local record = { name = name, prerequisites = prerequisites, science_requirements = science, unlocks = unlocks }
    ok, record.science_count = pcall(function() return technology.prototype.research_unit_count end)
    if not ok or type(record.science_count) ~= "number" then record.science_count = nil end
    ok, record.science_time = pcall(function() return technology.prototype.research_unit_energy end)
    if not ok or type(record.science_time) ~= "number" then record.science_time = nil end
    return ready, record
  end
  for name, technology in pairs(force.technologies) do
    if technology.researched then researched[#researched + 1] = name
    elseif technology.enabled then
      local ready, record = technology_record(name, technology)
      if ready then
        local trigger = research_trigger(technology)
        if trigger then
          record.trigger = trigger
          trigger_unlocks[#trigger_unlocks + 1] = record
        else
          available[#available + 1] = record
        end
      end
    end
  end
  table.sort(researched)
  table.sort(available, function(a, b) return a.name < b.name end)
  table.sort(trigger_unlocks, function(a, b) return a.name < b.name end)
  for name, recipe in pairs(force.recipes or {}) do
    if recipe.enabled then enabled_recipes[#enabled_recipes + 1] = name end
  end
  table.sort(enabled_recipes)
  local queue = {}
  for _, technology in ipairs(force.research_queue or {}) do queue[#queue + 1] = technology.name end
  return {
    force = force.name, current_research = force.current_research and force.current_research.name or nil,
    research_progress = force.research_progress or 0, research_queue = queue,
    researched = researched, available = available, trigger_unlocks = trigger_unlocks,
    enabled_recipes = enabled_recipes,
  }
end

return M
