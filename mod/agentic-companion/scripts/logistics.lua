-- factory_status sections:['logistics']: the force's robot networks on the
-- body's surface, as the logistic-network view shows them, from
-- LuaForce.logistic_networks (no area query). The NEAREST_NETWORKS networks
-- whose closest cell is nearest the body, each with its robots, the robots
-- waiting to charge, where its roboports reach (the nearest MAX_COVERAGE
-- cells) and what it holds (the MAX_CONTENTS largest stacks). Every list is
-- capped and every read is counted: at most MAX_CELLS_READ cells a network
-- (cells_read says when there were more), so the section stays under about
-- 900 bytes and one call's work does not grow with the factory.
local jobs = require("scripts.jobs")

local M = {}

local NEAREST_NETWORKS, MAX_COVERAGE, MAX_CONTENTS, MAX_CELLS_READ = 3, 12, 8, 64

local function distance_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function network_row(network, body)
  local row = { network_id = network.network_id,
    robots = { logistic = { all = network.all_logistic_robots, available = network.available_logistic_robots },
      construction = { all = network.all_construction_robots, available = network.available_construction_robots } } }
  local cells = network.cells
  row.cells = #cells
  local coverage, queue, read = {}, 0, math.min(#cells, MAX_CELLS_READ)
  local function nearer(a, b)
    if a._d ~= b._d then return a._d < b._d end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return a.position.x < b.position.x
  end
  for index = 1, read do
    local cell = cells[index]
    queue = queue + (cell.to_charge_robot_count or 0)
    local position = cell.owner.position
    jobs.keep_first(coverage, MAX_COVERAGE, { position = { x = position.x, y = position.y },
      logistic_radius = cell.logistic_radius, construction_radius = cell.construction_radius,
      _d = distance_sq(position, body) }, nearer)
  end
  table.sort(coverage, nearer)
  for _, cell in ipairs(coverage) do cell._d = nil end
  row.charging_queue, row.coverage = queue, coverage
  if read < #cells then row.cells_read = read end
  local contents = {}
  local function larger(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.item < b.item
  end
  local by_name = {}
  for _, stack in ipairs(network.get_contents()) do by_name[stack.name] = (by_name[stack.name] or 0) + stack.count end
  for item, count in pairs(by_name) do jobs.keep_first(contents, MAX_CONTENTS, { item = item, count = count }, larger) end
  table.sort(contents, larger)
  row.contents = contents
  return row
end

-- {networks = [...], omitted_networks?} for the body's surface.
function M.section(c)
  local body = { x = c.position.x, y = c.position.y }
  local candidates = {}
  for _, network in ipairs(c.force.logistic_networks[c.surface.name] or {}) do
    local ok, cell = pcall(network.find_cell_closest_to, body)
    if ok and cell then
      candidates[#candidates + 1] = { network = network, id = network.network_id,
        d = distance_sq(cell.owner.position, body) }
    end
  end
  table.sort(candidates, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.id < b.id
  end)
  local networks = {}
  for index = 1, math.min(#candidates, NEAREST_NETWORKS) do
    local ok, row = pcall(network_row, candidates[index].network, body)
    if ok then networks[#networks + 1] = row end
  end
  local omitted = #candidates - math.min(#candidates, NEAREST_NETWORKS)
  return { networks = networks, omitted_networks = omitted > 0 and omitted or nil }
end

return M
