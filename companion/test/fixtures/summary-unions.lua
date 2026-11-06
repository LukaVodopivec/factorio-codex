-- Disposable native proof extension; no production exports or RPCs.
local M = require("scripts.walk_equivalence")
local fixture = require("scripts.union_fixture")
local candidate, baseline = require("scripts.map_summary"), require("scripts.walk_baseline")
local rpc = require("scripts.rpc")
local jobs = require("scripts.jobs")
local function source(version) return version == "baseline" and baseline or candidate end
function M.union_input(stage, n, generators)
  storage.union_input = rpc.to_json(fixture.build(stage, n, generators))
  return #storage.union_input
end
function M.union_prepare(version, stage, n, work, label)
  storage.union_state = { F = helpers.json_to_table(storage.union_input), version = version,
    stage = stage, n = n, work = work, steps = 0, label = label }
end
function M.union_batch(limit, measured)
  local S = assert(storage.union_state)
  for i = 1, limit do
    local timer = measured and helpers.create_profiler()
    local done = source(S.version).stage_probe[S.stage](S.F, {left = S.work})
    if timer then timer.stop() log({"", "union_slice ", S.label, " ", S.steps + 1, " ", timer}) end
    S.steps = S.steps + 1
    if done then
      storage.union_json = rpc.to_json(fixture.result(S.F, S.stage, S.n))
      return {done = true, steps = S.steps}
    end
  end
  return {done = false, steps = S.steps, cursor = S.F.cursor, root_cursor = S.F.root_cursor,
    root_first = S.F.root_first, each_pending = S.F.each_pending}
end
function M.union_save(stage, generators, second, legacy)
  M.union_input(stage, 32, generators)
  if legacy then
    -- Finish a real baseline item before saving, with another root still
    -- pending. Entry-only states cannot prove old cursor continuation.
    local F = helpers.json_to_table(storage.union_input)
    if stage == 10 or stage == 11 or stage == 13 or stage == 15 then
      if stage == 13 and generators then
        table.insert(F.generators["101"] or F.generators[101], 1, F.nodes[32])
      else
        table.insert(F.edges, 1, { from = "b32", to = "b32", kind = F.edges[1].kind })
      end
    elseif stage == 12 then table.insert(F.nodes, 1, { id = "ignored" })
    elseif stage == 14 then F.nodes[1], F.nodes[32] = F.nodes[32], F.nodes[1]
    elseif stage == 16 then table.insert(F.activity.events, 1, {})
    elseif stage == 23 then table.insert(F.diagnostics, 1, { node_id = "a32", reason = "fixture" }) end
    storage.union_input = rpc.to_json(F)
  end
  M.union_prepare("baseline", stage, 32, 600, "expected")
  while not M.union_batch(64, false).done do end
  local expected = storage.union_json
  M.union_prepare(legacy and "baseline" or "candidate", stage, 32, 1, "reload")
  if legacy then
    local S = storage.union_state
    local done = baseline.stage_probe[stage](S.F, {left = generators and 1 or 0.5})
    assert(not done and (S.F.cursor == 2 or S.F.join_generator == 3), "baseline pending item was missed")
    assert(not S.F.root_cursor and not S.F.root_first and not S.F.each_pending, "legacy state has new fields")
    S.version = "candidate"
  else
    local found
    for i = 1, 1000 do
      local progress = M.union_batch(1, false)
      assert(not progress.done, "pending root was missed")
      if progress.root_cursor and (not second or progress.root_first) then found = true break end
    end
    assert(found, "pending root not reached")
  end
  storage.union_saved = { expected = expected, state = rpc.to_json(storage.union_state), stage = stage,
    second = second, legacy = legacy, generators = generators }
  return {stage = stage, second = second, legacy = legacy, generators = generators,
    cursor = storage.union_state.F.cursor, join_generator = storage.union_state.F.join_generator,
    root_cursor = storage.union_state.F.root_cursor, root_first = storage.union_state.F.root_first,
    each_pending = storage.union_state.F.each_pending}
end
function M.union_resume()
  local saved = assert(storage.union_saved)
  assert(rpc.to_json(storage.union_state) == saved.state, "pending state changed across reload")
  while not M.union_batch(64, false).done do end
  assert(storage.union_json == saved.expected, "reloaded result differs from uninterrupted baseline")
  return {stage = saved.stage, second = saved.second, legacy = saved.legacy,
    generators = saved.generators, bytes = #storage.union_json, steps = storage.union_state.steps}
end
local function progress(F)
  return rpc.to_json({stage = F.stage, cursor = F.cursor, root_cursor = F.root_cursor,
    root_first = F.root_first, each_pending = F.each_pending})
end
function M.union_full_save(stage)
  local expected = M.new("baseline", "full")
  local json
  repeat json = M.run("baseline", expected, 600) until json
  local S = M.boundary("candidate", "full", stage)
  local found
  for i = 1, 10000 do
    local done = candidate.stage_probe[stage](S.flow, {left = 1})
    assert(not done, "full pending root was missed")
    if S.flow.root_cursor then found = true break end
  end
  assert(found, "full pending root not reached")
  local ticket = jobs.start("map_summary", {detail = "full", surface = "walk-physical"})
  local job = assert(storage.jobs.by_id[ticket.job_id])
  assert(job.status == "pending")
  job.state = S
  storage.union_full = {id = ticket.job_id, expected = json, progress = progress(S.flow)}
  return {id = ticket.job_id, stage = stage, progress = helpers.json_to_table(progress(S.flow))}
end
function M.union_full_resume()
  local saved = assert(storage.union_full)
  if saved.progress then
    assert(progress(storage.jobs.by_id[saved.id].state.flow) == saved.progress, "full pending root changed on reload")
    saved.progress = nil
  end
  for i = 1, 64 do
    local job = jobs.get{job_id = saved.id}
    assert(job.job_status ~= "failed", job.error)
    if job.job_status == "done" then
      storage.union_json = rpc.to_json(job.result)
      assert(storage.union_json == saved.expected, "full resumed summary differs from baseline")
      return {done = true, bytes = #storage.union_json}
    end
  end
  return {done = false}
end
return M
