-- Offline tests for jobs.lua: heavy reads spread over ticks with a shared
-- per-tick allowance, results kept until read once, a bounded number of jobs,
-- and job state that is plain data (it lives in storage across save/load).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

_G.game = { tick = 100 }
_G.storage = {}
_G.helpers = { table_to_json = dofile(here .. "/table_to_json.lua") }
local jobs = require("scripts.jobs")

-- A counting job: `work` items, one per budget item; spent records each
-- slice's use.
local spent = {}
jobs.register("count", {
  start = function(params)
    if params.bad then error("count needs a number", 0) end
    return { left = params.work, done = 0 }
  end,
  step = function(state, budget)
    local used = 0
    while state.left > 0 and budget.left > 0 do
      if state.fail_at and state.done >= state.fail_at then error("broke at " .. state.done) end
      state.left, state.done, budget.left, used = state.left - 1, state.done + 1, budget.left - 1, used + 1
    end
    spent[#spent + 1] = used
    if state.left == 0 then return { counted = state.done } end
    return nil
  end,
})

local small = jobs.start("count", { work = 50 })
check(small.counted == 50 and #storage.jobs.order == 0,
  "a read that fits this tick's work returns its result at once and keeps nothing")

local pending = jobs.start("count", { work = 2000 })
check(pending.job_status == "pending" and type(pending.job_id) == "number" and pending.kind == "count",
  "a larger read returns a pending job id")
local progress = jobs.get({ job_id = pending.job_id })
check(progress.job_status == "pending" and progress.result == nil, "get_job reports a pending job without a result")

-- The tick's allowance is shared: what a build search charged is not
-- available to reads, which still get MIN_WORK.
game.tick = 101
spent = {}
jobs.charge(jobs.WORK_PER_TICK)
jobs.on_tick()
check(spent[1] == jobs.MIN_WORK, "reads get only MIN_WORK in a tick a build search used up (" .. tostring(spent[1]) .. ")")
local ticks = 1
repeat
  game.tick = game.tick + 1
  spent = {}
  jobs.on_tick()
  ticks = ticks + 1
  check(spent[1] == nil or spent[1] <= jobs.WORK_PER_TICK, "a tick never spends more than its allowance")
until jobs.get({ job_id = pending.job_id }).job_status ~= "pending" or ticks > 20
local finished = storage.jobs.by_id[pending.job_id]
check(finished == nil, "a finished result is forgotten once read")
local unknown_ok, unknown_err = pcall(jobs.get, { job_id = pending.job_id })
check(not unknown_ok and tostring(unknown_err):match("unknown job id"), "a result is returned once only")

-- Results stay until read; a failure is a result too.
local job = jobs.start("count", { work = 1000 })
storage.jobs.by_id[job.job_id].state.fail_at = 700
for _ = 1, 5 do game.tick = game.tick + 1; jobs.on_tick() end
local failed = jobs.get({ job_id = job.job_id })
check(failed.job_status == "failed" and failed.error:match("broke at") and failed.result == nil,
  "an error inside a job fails that job and is reported once")
local bad_ok, bad_err = pcall(jobs.start, "count", { bad = true })
check(not bad_ok and bad_err == "count needs a number" and #storage.jobs.order == 0,
  "a start error is the RPC's error and leaves no job behind")

-- A bounded number of pending or unread jobs.
local ids = {}
for i = 1, jobs.MAX_JOBS do ids[i] = jobs.start("count", { work = 5000 }).job_id end
local full_ok, full_err = pcall(jobs.start, "count", { work = 1 })
check(not full_ok and tostring(full_err):match("^JOBS_BUSY: ") and tostring(full_err):match("pending or unread"),
  "starting past MAX_JOBS is refused with the JOBS_BUSY code the bridge retries on")
-- A caller that stopped waiting drops its job: the slot is free at once.
local dropped = jobs.get({ job_id = ids[#ids], forget = true })
check(dropped.forgotten == true and storage.jobs.by_id[ids[#ids]] == nil and #storage.jobs.order == jobs.MAX_JOBS - 1
  and jobs.get({ job_id = ids[#ids], forget = true }).forgotten == false,
  "get_job with forget drops a pending job and frees its slot; forgetting again is harmless")
ids[#ids] = jobs.start("count", { work = 5000 }).job_id
-- Oldest first, one allowance per tick for all of them together.
game.tick = game.tick + 1
spent = {}
jobs.on_tick()
local total = 0
for _, n in ipairs(spent) do total = total + n end
check(#spent == 1 and total == jobs.WORK_PER_TICK, "all pending jobs share one tick's allowance, oldest first")
-- Unread results expire.
for _ = 1, 200 do game.tick = game.tick + 1; jobs.on_tick() end
check(jobs.counts().pending == 0 and jobs.counts().unread == jobs.MAX_JOBS, "every job finished and waits to be read")
game.tick = game.tick + jobs.RESULT_TTL_TICKS + 1
local after = jobs.start("count", { work = 1 })
check(after.counted == 1 and #storage.jobs.order == 0, "unread results expire after the TTL")

-- A queued job goes first: a new start waits its turn instead of jumping in.
local first = jobs.start("count", { work = 3000 })
local second = jobs.start("count", { work = 1 })
check(second.job_status == "pending", "a read started behind a pending job waits for it")
for _ = 1, 10 do game.tick = game.tick + 1; jobs.on_tick() end
check(jobs.get({ job_id = second.job_id }).result.counted == 1 and jobs.get({ job_id = first.job_id }).result.counted == 3000,
  "both finish in order")

-- Job state is plain data: no functions anywhere, so storage serializes it.
local function plain(value, seen)
  seen = seen or {}
  if type(value) == "function" or type(value) == "thread" or type(value) == "userdata" then return false end
  if type(value) ~= "table" or seen[value] then return true end
  seen[value] = true
  for k, v in pairs(value) do if not plain(k, seen) or not plain(v, seen) then return false end end
  return true
end
local held = jobs.start("count", { work = 4000 })
check(plain(storage.jobs), "a pending job is plain data in storage")
-- A loaded save: the module's code is the same, its storage is a copy.
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[copy(k)] = copy(v) end
  return out
end
storage = copy(storage)
for _ = 1, 10 do game.tick = game.tick + 1; jobs.on_tick() end
check(jobs.get({ job_id = held.job_id }).result.counted == 4000, "a job continues from a copied storage after load")

-- A mod upgrade keeps jobs in flight (and the id counter); a kind the new
-- version does not know fails with its reason instead of vanishing.
local kept = jobs.start("count", { work = 4000 })
local orphan_id = storage.jobs.next_id
storage.jobs.by_id[orphan_id] = { id = orphan_id, kind = "retired_kind", status = "pending", state = {}, started_tick = game.tick, ticks = 0 }
storage.jobs.order[#storage.jobs.order + 1] = orphan_id
storage.jobs.next_id = orphan_id + 1
_G.defines = {}
require("scripts.state").init()
check(storage.jobs.next_id == orphan_id + 1 and storage.jobs.by_id[kept.job_id] ~= nil,
  "state.init keeps the jobs in flight and the id counter")
for _ = 1, 10 do game.tick = game.tick + 1; jobs.on_tick() end
local finished, retired = jobs.get({ job_id = kept.job_id }), jobs.get({ job_id = orphan_id })
check(finished.result.counted == 4000 and retired.job_status == "failed" and retired.error:match("not known to this mod version"),
  "a job kept across an upgrade finishes; one of a retired kind fails with its reason")

-- A result finished on a tick is encoded over the ticks after it, a field
-- or a slice of a list at a time within the allowance, and the RPC sends
-- that string instead of encoding the result again.
local encode = helpers.table_to_json
jobs.register("big", {
  start = function(params) return { rows = params.rows, array = params.array } end,
  step = function(state, budget)
    -- A large read takes the whole first slice, as a search would.
    if state.rows > 0 and not state.searched then state.searched, budget.left = true, 0; return nil end
    budget.left = budget.left - 1
    local rows = {}
    for i = 1, state.rows do rows[i] = { name = "row-" .. i, position = { x = i + 0.5, y = -i }, note = 'a "quoted"\nline' } end
    if state.array then return rows end
    local nodes = {}
    for i = 1, state.rows // 2 do nodes[i] = { id = i, edges = { i, i + 1 } } end
    return { rows = rows, count = state.rows, truncated = false, empty = {}, ['a "key"\tname'] = 1,
      nested = { list = { 1, 2, 3 }, flow = { nodes = nodes, sparse = { [3] = "x" } } } }
  end,
})
for _, case in ipairs({ { rows = 3000 }, { rows = 2000, array = true } }) do
  storage.jobs = nil
  local started = jobs.start("big", { rows = 0 })
  check(started.count == 0 and #storage.jobs.order == 0, "a result that fits the RPC's tick returns at once, unencoded")
  local queued = jobs.start("big", { rows = case.rows, array = case.array })
  check(queued.job_status == "pending", "a large read answers pending")
  local most, encode_ticks, biggest = 0, 0, 0
  local recorded = helpers.table_to_json
  helpers.table_to_json = function(value)
    local n = 0
    for _ in pairs(value) do n = n + 1 end
    biggest = math.max(biggest, n)
    return recorded(value)
  end
  repeat
    game.tick = game.tick + 1
    jobs.on_tick()
    most = math.max(most, storage.jobs.used)
    encode_ticks = encode_ticks + 1
  until storage.jobs.by_id[queued.job_id].status ~= "pending" or encode_ticks > 100
  helpers.table_to_json = recorded
  local done = storage.jobs.by_id[queued.job_id]
  check(done.status == "done" and done.json == encode(done.result),
    "the encoded result equals one whole encoding (" .. (case.array and "a list" or "an object") .. ")")
  check(encode_ticks > 2 and most <= jobs.WORK_PER_TICK + jobs.ENCODE_SLICE + 1 and biggest <= jobs.ENCODE_SLICE,
    "encoding spreads over " .. encode_ticks .. " ticks, at most " .. most .. " work items and "
      .. biggest .. " rows per table_to_json")
  -- The RPC splices the encoded result into the envelope.
  local rpc = require("scripts.rpc")
  local printed
  _G.rcon = { print = function(text) printed = text end }
  storage.rpc_outbox = { next_id = 1, by_id = {} }
  rpc.register("get_job", jobs.get)
  _G.helpers.json_to_table = function() return { job_id = queued.job_id } end
  local reencoded = false
  helpers.table_to_json = function(value)
    if value == done.result or (type(value) == "table" and type(value.data) == "table" and value.data.result) then reencoded = true end
    return encode(value)
  end
  rpc.dispatch("get_job", "{}")
  helpers.table_to_json = encode
  local stored = storage.rpc_outbox.by_id[1]
  local text = stored and table.concat(stored.parts) or printed
  local result_json = encode(done.result)
  check(not reencoded and text:sub(1, 19) == '{"ok":true,"data":{'
    and text:find('"result":' .. result_json, 1, true) and text:find('"job_status":"done"', 1, true)
    and not text:find("__json", 1, true),
    "get_job sends the stored encoding spliced into its envelope, never encoding the result again")
end
-- Rich rows (find_placement candidates with build steps) and a subtree
-- deeper than four levels are taken apart too: no table_to_json call gets
-- more than ENCODE_NODES nodes and no tick more than its allowance.
jobs.register("rich", {
  start = function() return {} end,
  step = function(_, budget)
    budget.left = budget.left - 1
    local candidates = {}
    for i = 1, 48 do
      local steps = {}
      for k = 1, 30 do steps[k] = { name = "transport-belt", position = { x = i + k, y = -k }, direction = 4 } end
      candidates[i] = { position = { x = i, y = i }, build_steps = steps, terrain = { water = 0, cliffs = i } }
    end
    local deep = { leaf = {} }
    local cursor = deep
    for d = 1, 8 do cursor.next = { level = d, items = {} }; cursor = cursor.next end
    for k = 1, 400 do cursor.items[k] = { k, k + 1 } end
    return { candidates = candidates, deep = deep }
  end,
})
storage.jobs = nil
local function nodes_in(value)
  if type(value) ~= "table" then return 1 end
  local n = 1
  for _, v in pairs(value) do n = n + nodes_in(v) end
  return n
end
do
  -- A job waiting ahead makes the rich read go pending, so on_tick finishes
  -- and encodes it.
  jobs.register("hold", { start = function() return {} end, step = function(_, budget) budget.left = 0; return nil end })
  local hold = jobs.start("hold", {})
  local id = jobs.start("rich", {}).job_id
  jobs.get({ job_id = hold.job_id, forget = true })
  local most, ticks, largest = 0, 0, 0
  local recorded = helpers.table_to_json
  helpers.table_to_json = function(value) largest = math.max(largest, nodes_in(value)); return recorded(value) end
  repeat
    game.tick = game.tick + 1
    jobs.on_tick()
    most = math.max(most, storage.jobs.used)
    ticks = ticks + 1
  until storage.jobs.by_id[id].status ~= "pending" or ticks > 200
  helpers.table_to_json = recorded
  local done = storage.jobs.by_id[id]
  check(done.status == "done" and done.json == encode(done.result) and ticks > 3
    and most <= jobs.WORK_PER_TICK + jobs.ENCODE_NODES + 1 and largest <= jobs.ENCODE_NODES + 1,
    "rich nested rows encode over " .. ticks .. " ticks, at most " .. most .. " work items a tick and "
      .. largest .. " nodes per table_to_json")
  storage.jobs = nil
end

-- run_now (provably small reads and tests): the same steps until done.
local result, slices = jobs.run_now({ start = function() return { left = 1500, done = 0 } end,
  step = function(state, budget)
    while state.left > 0 and budget.left > 0 do state.left, state.done, budget.left = state.left - 1, state.done + 1, budget.left - 1 end
    if state.left == 0 then return state.done end
  end }, {})
check(result == 1500 and slices == 3, "run_now runs a job to its end a tick's budget at a time")

-- run_now with a work ceiling stops there, charges the tick and returns the
-- definition's truncated result.
storage.jobs = nil
local endless = { start = function() return { n = 0 } end,
  step = function(state, budget) state.n = state.n + budget.left; budget.left = 0 end,
  truncated = function(state) return { stopped_at = state.n } end }
local cut = jobs.run_now(endless, {}, nil, 1000)
check(cut and cut.stopped_at == 1000 and storage.jobs.used == 1000,
  "run_now stops at its work ceiling, charges what it spent and returns the truncated result")

-- sort_step: a stable merge sort spread over budget slices.
math.randomseed(7)
local list, reference = {}, {}
for i = 1, 1000 do
  local row = { key = math.random(1, 50), at = i }
  list[i], reference[i] = row, row
end
local function by_key(a, b) return a.key < b.key end
table.sort(reference, function(a, b) if a.key ~= b.key then return a.key < b.key end return a.at < b.at end)
local owner, sorted, sort_slices = {}, nil, 0
repeat
  sort_slices = sort_slices + 1
  sorted = jobs.sort_step(owner, "_sort", list, by_key, { left = 50 })
until sorted or sort_slices > 1000
local same = sorted ~= nil and #sorted == 1000
for i = 1, 1000 do if not same or sorted[i] ~= reference[i] then same = false; break end end
check(same and owner._sort == nil and sort_slices > 20,
  "sort_step sorts stably over " .. sort_slices .. " slices and clears its state")
check(jobs.sort_step({}, "_sort", { list[1] }, by_key, { left = 0 })[1] == list[1], "a one-row list is already sorted")

-- keep_first keeps the rows that sort first, whatever order they come in.
local heap = {}
for i = 1000, 1, -1 do jobs.keep_first(heap, 8, { key = (i * 37) % 1000 }, by_key) end
table.sort(heap, by_key)
local firsts = {}
for i, row in ipairs(heap) do firsts[i] = row.key end
check(table.concat(firsts, ",") == "0,1,2,3,4,5,6,7", "keep_first keeps the first rows of a stream in a bounded heap")

print(failures == 0 and "\nALL JOB TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
