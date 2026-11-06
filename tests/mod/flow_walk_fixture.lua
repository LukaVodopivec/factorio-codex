-- Plain-data graphs shared by offline and disposable native traversal probes.
-- Graph construction is setup work, outside the measured invocation.
local M = {}

function M.build(kind, n, shape)
  local F = { nodes = {}, node_by_id = {}, incoming = {}, outgoing = {}, pickup_of = {},
    edges_of = {}, diagnostics = {}, edges = {}, components = {} }
  local function add(id, role, entity_type)
    local node = { id = id, _key = id, name = entity_type, type = entity_type, role = role,
      position = { x = 0, y = 0 }, direction = 0, status = "working", products = {}, ingredients = {} }
    F.node_by_id[id], F.incoming[id], F.outgoing[id], F.edges_of[id] = node, {}, {}, {}
    return node
  end
  local root = add("root", "transport", "transport-belt")
  local downstream = kind == "reaches_downstream" or kind == "first_reached"
  local function edge(from, to)
    F.outgoing[from][#F.outgoing[from] + 1] = to
    F.incoming[to][#F.incoming[to] + 1] = from
  end
  for i = 1, n do add("path-" .. i, "transport", "transport-belt") end
  local function link(a, b)
    if downstream then edge(a, b) else edge(b, a) end
  end
  if shape == "fanout" then
    for i = 1, n do link("root", "path-" .. i) end
  else
    link("root", "path-1")
    for i = 1, n - 1 do
      link("path-" .. i, "path-" .. (i + 1))
      if shape == "branch" and i + 2 <= n then link("path-" .. i, "path-" .. (i + 2)) end
    end
  end
  local tail = F.node_by_id["path-" .. n]
  if shape == "cycle" then
    link(tail.id, "path-1")
  elseif downstream then
    tail.role, tail.type, tail.name = "sink", "lab", "lab"
  else
    tail.role, tail.type, tail.name = "source", "mining-drill", "burner-mining-drill"
    tail.products = { { name = "coal", type = "item", fuel_category = "chemical" },
      { name = "iron-ore", type = "item" } }
  end
  if kind == "ancestors" then
    -- Product traversal stops at this transformation boundary, but ancestry
    -- still crosses it. A direct terminal forces the caller's ancestry query.
    F.node_by_id["path-1"].role = "processor"
    root.role, root.type, root.name = "buffer", "container", "iron-chest"
    local target = add("target", "source", "mining-drill")
    target.requires_fuel, target.fuel_categories = true, { chemical = true }
    edge("root", "target")
  elseif kind == "first_reached" then
    root.role, root.type, root.name = "buffer", "container", "iron-chest"
  elseif kind == "upstream_products" then
    root.role, root.type, root.name = "sink", "lab", "lab"
    root._raw_status = "no_research_in_progress"
  elseif kind == "reaches_downstream" or kind == "material_upstream" then
    root.role, root.type, root.name = "processor", "furnace", "stone-furnace"
    root._source_production = { working = true }
    if kind == "reaches_downstream" then root.products = { { name = "iron-plate", type = "item" } } end
  end
  F.nodes[1] = root
  F.components[1] = { node_ids = { "root" }, _edges = {}, _electrical = {}, _diagnostics = {},
    roles = { source = 1 }, status_counts = { working = 1 } }
  return F
end

return M
