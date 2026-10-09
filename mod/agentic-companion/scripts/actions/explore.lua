-- explore {resource?, direction?, max_distance}: the body scouts on foot.
-- It walks legs of up to LEG_TILES toward the frontier (the given heading,
-- else the heading whose uncharted land is nearest), charts the land around
-- itself after each leg, and stops once a charted patch of the resource lies
-- in view (the land it charts: VIEW_RADIUS tiles around the start and each
-- leg's end) or it has walked max_distance. Every leg is an ordinary walk; a
-- heading the body cannot walk is turned by 45 degrees, at most MAX_TURNS
-- times in a row. Work per tick is bounded: one chart pass around the body,
-- one bounded resource query per leg.
local companion = require("scripts.companion")
local supply = require("scripts.actions.supply")

local M = {}

local LEG_TILES = 64
local ARRIVAL_RADIUS = 4
local CHART_RADIUS_CHUNKS = 4      -- 9 x 9 chunks around the body
local FRONTIER_CHUNKS = 8          -- uncharted land looked for along each heading
local VIEW_RADIUS = CHART_RADIUS_CHUNKS * 32 -- resource search around the body: what it charts
local VIEW_LIMIT = 64
local CHART_POLL_TICKS = 15
local CHART_WAIT_TICKS = 600
local MAX_TURNS = 3
local MIN_DISTANCE, MAX_DISTANCE = 32, 3000
-- Eight headings, clockwise from north (map +y is south).
local HEADINGS = { { 0, -1 }, { 1, -1 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 } }
local HEADING_NAMES = { "north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest" }

local function chunk_of(position)
  return { x = math.floor(position.x / 32), y = math.floor(position.y / 32) }
end

local function charted(c, position)
  local ok, value = pcall(c.force.is_chunk_charted, c.surface, chunk_of(position))
  return ok and value == true
end

-- Charts the chunks within radius_chunks of the body that are neither
-- charted nor already requested.
function M.chart_around(c, radius_chunks)
  local force, surface = c.force, c.surface
  local centre = chunk_of(c.position)
  for y = centre.y - radius_chunks, centre.y + radius_chunks do
    for x = centre.x - radius_chunks, centre.x + radius_chunks do
      local chunk = { x = x, y = y }
      if not force.is_chunk_charted(surface, chunk) and not force.is_chunk_requested_for_charting(surface, chunk) then
        force.chart(surface, { { x * 32, y * 32 }, { x * 32 + 31, y * 32 + 31 } })
      end
    end
  end
end

-- Whether the outer ring of the chunks chart_around requested around centre
-- is charted (at most 8 * CHART_RADIUS_CHUNKS chunk reads).
local function ring_charted(c, centre)
  local r = CHART_RADIUS_CHUNKS
  for y = centre.y - r, centre.y + r do
    local step = (y == centre.y - r or y == centre.y + r) and 1 or 2 * r
    for x = centre.x - r, centre.x + r, step do
      if not charted(c, { x = x * 32, y = y * 32 }) then return false end
    end
  end
  return true
end

-- The heading whose first uncharted chunk is nearest (1-based index).
local function frontier_heading(c)
  local best, best_k
  for index, h in ipairs(HEADINGS) do
    for k = 1, FRONTIER_CHUNKS do
      if best_k and k >= best_k then break end
      local point = { x = c.position.x + h[1] * k * 32, y = c.position.y + h[2] * k * 32 }
      if not charted(c, point) then best, best_k = index, k; break end
    end
  end
  return best or 1
end

-- The nearest charted entity of the resource within view, or nil.
local function patch_in_view(c, resource)
  local ok, found = pcall(c.surface.find_entities_filtered,
    { position = c.position, radius = VIEW_RADIUS, name = resource, limit = VIEW_LIMIT })
  local best, best_d, seen = nil, nil, 0
  for _, e in ipairs(ok and type(found) == "table" and found or {}) do
    if e.valid and charted(c, e.position) then
      seen = seen + 1
      local dx, dy = e.position.x - c.position.x, e.position.y - c.position.y
      local d = dx * dx + dy * dy
      if not best or d < best_d then best, best_d = e, d end
    end
  end
  if not best then return nil end
  return { name = best.name, position = { x = best.position.x, y = best.position.y },
    distance = math.floor(math.sqrt(best_d) * 10 + 0.5) / 10, entities_seen = seen }
end

local function validate(params, label)
  local distance = tonumber(params.max_distance)
  if not distance or distance < MIN_DISTANCE or distance > MAX_DISTANCE then
    error(string.format("%s requires max_distance from %d to %d tiles", label, MIN_DISTANCE, MAX_DISTANCE), 0)
  end
  if params.resource ~= nil then
    local proto = type(params.resource) == "string" and prototypes.entity[params.resource]
    if not (proto and proto.type == "resource") then
      error(label .. " resource must be a resource name such as crude-oil", 0)
    end
  end
  local d = params.direction
  if d ~= nil and (type(d) ~= "number" or d % 1 ~= 0 or d < 0 or d > 15) then
    error(label .. " direction must be an integer 0-15 (0 = north, 4 = east, 8 = south, 12 = west)", 0)
  end
end

function M.start(task)
  local c = companion.require_companion()
  validate(task, "explore")
  task.max_distance = tonumber(task.max_distance)
  task._heading = task.direction and (math.floor(task.direction / 2 + 0.5) % 8) + 1 or nil
  task._walked, task._legs, task._turns, task._phase = 0, 0, 0, "look"
  task._start = { x = c.position.x, y = c.position.y }
end

M.resume = supply.resume

local function finish(task, c, status, code, detail, patch)
  local outcome = { code = code, walked = math.floor(task._walked + 0.5), legs = task._legs,
    max_distance = task.max_distance, resource = task.resource, patch = patch,
    position = { x = c.position.x, y = c.position.y } }
  return { status = status, detail = detail, outcome = outcome }
end

-- Turns a heading that could not be walked: +45, -45, +90 ... degrees.
local function turn(task)
  task._turns = task._turns + 1
  local offset = math.ceil(task._turns / 2) * (task._turns % 2 == 1 and 1 or -1)
  task._heading = (task._base_heading - 1 + offset) % 8 + 1
end

local function leg(task, c)
  if task.resource then
    local patch = patch_in_view(c, task.resource)
    if patch then
      return finish(task, c, "done", "PATCH_FOUND", string.format("found %s at (%.1f, %.1f), %.0f tiles away, after walking %d tiles",
        patch.name, patch.position.x, patch.position.y, patch.distance, math.floor(task._walked + 0.5)), patch)
    end
  end
  -- A leg ends within ARRIVAL_RADIUS of its end, so a shorter one gets
  -- nowhere: the budget is spent.
  local left = task.max_distance - task._walked
  if left < 2 * ARRIVAL_RADIUS then
    if task.resource then
      return finish(task, c, "failed", "EXPLORE_NOT_FOUND", string.format(
        "EXPLORE_NOT_FOUND: no charted %s within %d tiles of the start or any leg's end after walking %d of %d tiles",
        task.resource, VIEW_RADIUS, math.floor(task._walked + 0.5), task.max_distance))
    end
    return finish(task, c, "done", "EXPLORED", string.format("walked %d tiles in %d legs and charted around each",
      math.floor(task._walked + 0.5), task._legs))
  end
  if not task._heading then task._heading = frontier_heading(c) end
  task._base_heading = task._base_heading or task._heading
  local h = HEADINGS[task._heading]
  local length = math.min(LEG_TILES, left) / math.sqrt(h[1] * h[1] + h[2] * h[2])
  task._target = { x = math.floor(c.position.x + h[1] * length) + 0.5, y = math.floor(c.position.y + h[2] * length) + 0.5 }
  M.chart_around(c, CHART_RADIUS_CHUNKS)
  task._phase, task._deadline, task._next_poll = "chart_wait", game.tick + CHART_WAIT_TICKS, game.tick
  return nil
end

function M.tick(task)
  local c = companion.get()
  if not c then return { status = "failed", detail = "the companion character is gone" } end

  if task._phase == "walk" then
    local from = task._leg_from
    local result = supply.step(task, "_sub")
    if not result then return nil end
    local dx, dy = c.position.x - from.x, c.position.y - from.y
    task._walked = task._walked + math.sqrt(dx * dx + dy * dy)
    task._legs = task._legs + 1
    if result.status == "done" then
      task._turns, task._base_heading = 0, task._heading
    else
      task._last_failure = result.detail
      if task._turns >= MAX_TURNS then
        return finish(task, c, "failed", "EXPLORE_BLOCKED", string.format(
          "EXPLORE_BLOCKED: heading %s and its neighbours cannot be walked after %d tiles: %s",
          HEADING_NAMES[task._base_heading], math.floor(task._walked + 0.5), tostring(result.detail)))
      end
      turn(task)
    end
    -- Chart what the leg brought into view, then look once all of it (its
    -- outer ring last) is charted, or the deadline passes.
    M.chart_around(c, CHART_RADIUS_CHUNKS)
    task._phase, task._deadline, task._next_poll = "settle", game.tick + CHART_WAIT_TICKS, game.tick
    task._settle_centre = chunk_of(c.position)
    return nil
  end

  if task._phase == "settle" then
    if game.tick < task._next_poll then return nil end
    task._next_poll = game.tick + CHART_POLL_TICKS
    local centre = task._settle_centre or chunk_of(c.position)
    if game.tick < task._deadline and not (charted(c, c.position) and ring_charted(c, centre)) then return nil end
    task._phase = "look"
  end

  if task._phase == "look" then return leg(task, c) end

  -- chart_wait: the leg's end must be charted before the walk aims at it.
  if game.tick < task._next_poll then return nil end
  task._next_poll = game.tick + CHART_POLL_TICKS
  if not charted(c, task._target) then
    if game.tick < task._deadline then return nil end
    if task._turns >= MAX_TURNS then
      return finish(task, c, "failed", "EXPLORE_BLOCKED", "EXPLORE_BLOCKED: the land ahead was never charted")
    end
    turn(task)
    task._phase = "look"
    return nil
  end
  task._leg_from = { x = c.position.x, y = c.position.y }
  local ok, err = pcall(supply.begin, task, "_sub", { type = "walk_to", target = task._target,
    arrival_mode = "vicinity", arrival_radius = ARRIVAL_RADIUS })
  if not ok then return { status = "failed", detail = tostring(err) } end
  task._phase = "walk"
  return nil
end

-- The plan action for tasks.register_action.
M.action = {
  runner = M,
  make_task = function(step)
    return { resource = step.resource, direction = step.direction, max_distance = step.max_distance }
  end,
  validate = function(step, index) validate(step, "queue_plan explore step " .. index) end,
  -- A plan's budget: one ordinary step's worth per 32 tiles, plus charting.
  budget_steps = function(step) return math.ceil((tonumber(step.max_distance) or MIN_DISTANCE) / 32) + 2 end,
}

M.LEG_TILES, M.VIEW_RADIUS = LEG_TILES, VIEW_RADIUS

return M
