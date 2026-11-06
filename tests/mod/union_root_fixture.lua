-- Plain retained flow states shared by offline and disposable native proofs.
local M = {}
function M.build(stage, n, generators)
  local F = { nodes = {}, edges = {}, parent = {}, run_parent = {}, run_consumed = {},
    generators = {}, by_root = {}, component_list = {}, node_by_id = {}, incoming = {}, outgoing = {},
    edges_of = {}, pickup_of = {}, retained = {}, seen_edges = {}, diagnostics = {}, activity = { events = {} } }
  for _, prefix in ipairs({ "a", "b" }) do
    for i = 1, n do
      local id = prefix .. i
      local node = { id = id, role = "transport", status = "working" }
      F.nodes[#F.nodes + 1], F.node_by_id[id] = node, node
      F.parent[id], F.run_parent[id] = prefix .. math.min(i + 1, n), prefix .. math.min(i + 1, n)
      F.incoming[id], F.outgoing[id], F.edges_of[id] = {}, {}, {}
    end
    F.by_root[prefix .. n] = { _edges = {}, _electrical = {}, _diagnostics = {}, edge_count = 0,
      character_transfer_actions = 0 }
  end
  if stage == 10 or stage == 11 or stage == 13 or stage == 15 then
    F.edges = { { from = "a1", to = "b1", kind = stage == 10 and "belt_direction"
      or stage == 15 and "electrical_dependency" or "inserter_pickup" } }
    if stage == 13 and generators then
      F.edges = {}
      F.generators[101] = { F.nodes[1], F.nodes[n + 1] }
    end
  elseif stage == 12 then F.nodes[1]._belt_outputs = 0
  elseif stage == 14 then F.by_root = {}
  elseif stage == 16 then
    local target = { name = "transport-belt", type = "transport-belt", position = { x = 0, y = 0 } }
    F.retained[string.format("%s\0%s\0%.17g\0%.17g", target.name, target.type, 0, 0)] = F.nodes[1]
    F.activity.events = { { target = target, tick = 27 } }
  elseif stage == 23 then F.diagnostics = { { node_id = "a1", reason = "fixture" } } end
  return F
end

-- Observe every representative and each stage's material result, without
-- exposing incidental compression shape or pending implementation fields.
function M.result(F, stage, n)
  local out = { representatives = {}, diagnostics = F.diagnostics }
  local parent = stage <= 11 and F.run_parent or stage == 12 and nil or F.parent
  if parent then
    local resolved = {}
    for _, prefix in ipairs({ "a", "b" }) do for i = 1, n do
      local id, r, path = prefix .. i, prefix .. i, {}
      while parent[r] ~= r and not resolved[r] do path[#path + 1] = r; r = parent[r] end
      r = resolved[r] or r
      for _, entry in ipairs(path) do resolved[entry] = r end
      out.representatives[id] = r
    end end
  end
  if stage == 11 then out.consumed = F.run_consumed
  elseif stage == 14 then out.components = F.component_list
  elseif stage == 15 then
    out.incoming, out.outgoing, out.edges_of, out.by_root = F.incoming, F.outgoing, F.edges_of, F.by_root
  elseif stage == 16 or stage == 23 then out.by_root = F.by_root end
  return out
end
return M
