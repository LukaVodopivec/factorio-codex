-- Heavy reads run as jobs. Every RCON command and every on_tick handler runs
-- inside one game tick on the server and every client, so a read whose work
-- grows with the factory or the searched area (map_summary, observe_local
-- beyond what one tick holds, route and site searches) is spread over ticks.
--
-- The RPC starts a job and works on it at once with what is left of this
-- tick's budget: a small read finishes there and returns its result
-- directly. Otherwise it returns {job_id, job_status = "pending"} and on_tick
-- advances the oldest pending job with the tick's budget until it is done;
-- get_job {job_id} returns the result once and then forgets it.
--
-- Budgets count work items (an engine call and the Lua work around it),
-- never time: Lua has no clock. One per-tick allowance is shared with the
-- physical build search (charge), so reads and a build together stay within
-- it, except that reads always get MIN_WORK.
--
-- A job is plain data in storage.jobs (no closures, no upvalues): its kind
-- names a definition registered at load, so a save made mid-job loads and
-- continues. A definition is {start = function(params) -> state,
-- step = function(state, budget) -> result | nil, defer_encode?}; step
-- spends from budget.left (it may overrun by its last item) and returns the
-- result once done. An error in start is the RPC's error; an error in step
-- fails the job. A large result (defer_encode = true) never returns from the
-- RPC, which would encode it whole in one tick: the RPC answers pending and
-- get_job returns it, encoded over ticks like any result finished on a tick.
local M = {}

M.WORK_PER_TICK = 600
M.MIN_WORK = 100
M.MAX_JOBS = 8
M.RESULT_TTL_TICKS = 5 * 60 * 60
local rpc = require("scripts.rpc")
M.RAW_JSON = rpc.RAW_JSON
local errors = require("scripts.errors")

local kinds = {}

function M.register(kind, definition) kinds[kind] = definition end

local function data()
  local jobs = storage.jobs
  if not jobs then
    jobs = { next_id = 1, by_id = {}, order = {}, tick = nil, used = 0 }
    storage.jobs = jobs
  end
  return jobs
end

local function now() return game and game.tick or 0 end

-- Work items already spent in this tick (by builds and jobs).
local function used(jobs)
  if jobs.tick ~= now() then jobs.tick, jobs.used = now(), 0 end
  return jobs.used
end

-- The physical build search reports what it spent this tick.
function M.charge(n)
  local jobs = data()
  jobs.used = used(jobs) + math.max(0, n or 0)
end

local function allowance(jobs)
  return math.max(M.MIN_WORK, M.WORK_PER_TICK - used(jobs))
end

-- Work items spent in this tick so far (by builds, jobs and reads).
function M.spent() return used(data()) end

-- A result finished on a tick is encoded to JSON on the ticks after it, so
-- get_job only copies a string: one table_to_json of a large result is a
-- long frame. The encoder walks the result from an explicit stack kept in
-- storage, charging every node it looks at: a table of at most ENCODE_NODES
-- nodes (tables and values) is one table_to_json call costing 1 + its nodes;
-- a larger list goes out in slices of at most ENCODE_SLICE elements and
-- ENCODE_NODES nodes, and a larger object key by key, so no tick's encoding
-- outgrows the allowance by more than one such call.
M.ENCODE_SLICE = 16
M.ENCODE_NODES = 48 -- below MIN_WORK, so a slice always fits a fresh tick
local SCAN_PER_ITEM = 16 -- table entries a pure-Lua scan (counting, keys) visits per work item

local function list_length(value)
  if type(value) ~= "table" or value[1] == nil then return 0 end
  local n, count = #value, 0
  for _ in pairs(value) do
    count = count + 1
    if count > n then return 0 end
  end
  return count == n and n or 0
end

-- Sorted string keys, or nil when the table is empty or has another key.
local function object_keys(value)
  if type(value) ~= "table" or next(value) == nil then return nil end
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then return nil end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- Nodes in value (the table itself, each value and nested table), counting
-- no further than past cap.
local function count_nodes(value, cap)
  if type(value) ~= "table" then return 1 end
  local count, pending = 1, { value }
  while #pending > 0 do
    local t = table.remove(pending)
    for _, v in pairs(t) do
      count = count + 1
      if count > cap then return count end
      if type(v) == "table" then pending[#pending + 1] = v end
    end
  end
  return count
end
M.count_nodes = count_nodes

local JSON_ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function json_string(text)
  return '"' .. text:gsub('[%c"\\]', function(c) return JSON_ESCAPES[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function strip(json) return string.sub(json, 2, -2) end
local function value_json(value)
  if type(value) == "table" then return rpc.to_json(value) end
  return strip(rpc.to_json({ value }))
end

local function child_path(path, key)
  local child = { table.unpack(path) }
  child[#child + 1] = key
  return child
end

local function resolve(result, path)
  local value = result
  for _, key in ipairs(path) do value = value[key] end
  return value
end

-- The encoder's state: a stack of frames {path} (a value not yet looked
-- at), {path, keys, i} (an object) or {path, n, i} (a list). Paths, not
-- references, keep it plain data in storage.
local function encoding(result)
  return { stack = { { path = {} } }, pieces = {} }
end

-- One table_to_json of `cost` work items: deferred once to a fresh tick when
-- it does not fit what is left, then written whatever its size.
local function fits(frame, cost, budget)
  if cost <= budget.left or frame.waited then frame.waited = nil; return true end
  frame.waited = true
  return false
end

-- Writes JSON pieces while budget is left; the JSON once all are written.
local function encode_step(e, result, budget)
  local stack, pieces = e.stack, e.pieces
  while #stack > 0 do
    if budget.left <= 0 then return nil end
    local f = stack[#stack]
    local value = resolve(result, f.path)
    if f.keys then
      if f.i > #f.keys then
        pieces[#pieces + 1], stack[#stack] = "}", nil
      else
        local key = f.keys[f.i]
        pieces[#pieces + 1] = (f.i > 1 and "," or "") .. json_string(key) .. ":"
        f.i = f.i + 1
        stack[#stack + 1] = { path = child_path(f.path, key) }
        budget.left = budget.left - 1
      end
    elseif f.n then
      if f.i > f.n then
        pieces[#pieces + 1], stack[#stack] = "]", nil
      else
        if not f.sized then
          -- The next slice, element by element: up to ENCODE_SLICE elements
          -- and ENCODE_NODES nodes.
          f.to, f.size = f.to or f.i - 1, f.size or 0
          while f.to < f.n and f.to - f.i + 1 < M.ENCODE_SLICE do
            if budget.left <= 0 then return nil end
            local nodes = count_nodes(value[f.to + 1], M.ENCODE_NODES)
            budget.left = budget.left - math.ceil(nodes / SCAN_PER_ITEM)
            if f.to >= f.i and f.size + nodes > M.ENCODE_NODES then break end
            f.to, f.size = f.to + 1, f.size + nodes
            if f.size > M.ENCODE_NODES then break end
          end
          f.sized = true
        end
        if f.to == f.i and f.size > M.ENCODE_NODES then
          -- One element too large for a slice is taken apart.
          pieces[#pieces + 1] = f.i > 1 and "," or ""
          stack[#stack + 1] = { path = child_path(f.path, f.i) }
          f.i, f.to, f.size, f.sized = f.i + 1, nil, nil, nil
          budget.left = budget.left - 1
        else
          if not fits(f, 1 + f.size, budget) then return nil end
          local slice = {}
          for k = f.i, f.to do slice[#slice + 1] = value[k] end
          pieces[#pieces + 1] = (f.i > 1 and "," or "") .. strip(rpc.to_json(slice))
          budget.left = budget.left - 1 - f.size
          f.i, f.to, f.size, f.sized = f.to + 1, nil, nil, nil
        end
      end
    elseif type(value) ~= "table" then
      pieces[#pieces + 1], stack[#stack] = value_json(value), nil
      budget.left = budget.left - 1
    else
      if not f.size then
        f.size = count_nodes(value, M.ENCODE_NODES)
        budget.left = budget.left - math.ceil(f.size / SCAN_PER_ITEM)
      end
      local n, keys = 0, nil
      if f.size > M.ENCODE_NODES then
        -- Telling a list from an object scans every entry.
        if not fits(f, 1 + math.ceil(#value / SCAN_PER_ITEM), budget) then return nil end
        n = list_length(value)
        keys = n == 0 and object_keys(value) or nil
        budget.left = budget.left - 1 - math.ceil(n / SCAN_PER_ITEM)
      end
      if n > 0 then
        pieces[#pieces + 1], f.n, f.i = "[", n, 1
      elseif keys then
        pieces[#pieces + 1], f.keys, f.i = "{", keys, 1
        budget.left = budget.left - math.ceil(#keys / SCAN_PER_ITEM)
      else
        -- Small, or a table that is neither list nor object: one call,
        -- charged by its real size.
        if f.size > M.ENCODE_NODES and not f.counted then
          f.size, f.counted = count_nodes(value, math.huge), true
          budget.left = budget.left - math.ceil(f.size / SCAN_PER_ITEM)
        end
        if not fits(f, 1 + f.size, budget) then return nil end
        pieces[#pieces + 1], stack[#stack] = value_json(value), nil
        budget.left = budget.left - 1 - f.size
      end
    end
  end
  return table.concat(pieces)
end

-- Advances one job by the budget; true once it is finished (done or failed).
-- encode: a finished result is encoded before the job is done.
local function work(jobs, job, budget, encode)
  local definition = kinds[job.kind]
  local before = budget.left
  local ok, result
  if job.encoding then
    ok, result = pcall(encode_step, job.encoding, job.result, budget)
    if ok and result ~= nil then job.json, job.encoding, result = result, nil, job.result end
  elseif not definition then
    ok, result = false, "job kind " .. tostring(job.kind) .. " is not known to this mod version"
  else
    ok, result = pcall(definition.step, job.state, budget)
    if ok and result ~= nil and encode and type(result) == "table" then
      job.state, job.result, job.encoding = nil, result, encoding(result)
      ok, result = pcall(encode_step, job.encoding, job.result, budget)
      if ok and result ~= nil then job.json, job.encoding, result = result, nil, job.result end
    end
  end
  jobs.used = used(jobs) + math.max(0, before - budget.left)
  job.ticks = (job.ticks or 0) + 1
  if ok and result == nil then return false end
  job.state, job.encoding = nil, nil
  job.finished_tick = now()
  if ok then
    job.status, job.result = "done", result
  else
    local deliberate, message = errors.deliberate(result)
    if not deliberate then message = errors.record("job:" .. tostring(job.kind), result) end
    job.status, job.result, job.json, job.error = "failed", nil, nil, message
  end
  return true
end

local function forget(jobs, id)
  jobs.by_id[id] = nil
  for index, other in ipairs(jobs.order) do
    if other == id then table.remove(jobs.order, index); break end
  end
end

-- Unread results expire; pending jobs keep running.
local function prune(jobs)
  for _, id in ipairs({ table.unpack(jobs.order) }) do
    local job = jobs.by_id[id]
    if job and job.status ~= "pending" and now() - job.finished_tick > M.RESULT_TTL_TICKS then forget(jobs, id) end
  end
end

local function public(job)
  local out = { job_id = job.id, kind = job.kind, job_status = job.status, started_tick = job.started_tick,
    ticks = job.ticks }
  if job.status == "done" then
    out.result = job.result
    -- The RPC sends the encoded copy (rpc.lua splices raw JSON fields).
    if job.json then out[M.RAW_JSON] = { result = job.json } end
  elseif job.status == "failed" then out.error = job.error end
  if job.finished_tick then out.finished_tick = job.finished_tick end
  return out
end

-- Starts a job of this kind and works on it with what is left of this tick.
-- Returns the result when it finished here, else the pending marker.
function M.start(kind, params)
  local definition = assert(kinds[kind], "unknown job kind " .. tostring(kind))
  local jobs = data()
  prune(jobs)
  if #jobs.order >= M.MAX_JOBS then
    -- JOBS_BUSY is the stable code the bridge retries on.
    error(string.format("JOBS_BUSY: %d jobs are pending or unread; read their results with get_job before starting another",
      #jobs.order), 0)
  end
  local state = definition.start(type(params) == "table" and params or {})
  local id = jobs.next_id
  jobs.next_id = id + 1
  local job = { id = id, kind = kind, status = "pending", state = state, started_tick = now(), ticks = 0 }
  jobs.by_id[id] = job
  jobs.order[#jobs.order + 1] = id
  -- A queued job goes first: this one starts at once only when none waits.
  local waiting = false
  for _, other in ipairs(jobs.order) do
    if other ~= id and jobs.by_id[other].status == "pending" then waiting = true end
  end
  -- A defer_encode result is never encoded whole in this tick by rpc.lua:
  -- the encoder takes it over ticks and get_job returns it.
  local defer = definition.defer_encode == true
  if not waiting and work(jobs, job, { left = allowance(jobs) }, defer) then
    if job.status == "failed" then
      forget(jobs, id)
      error(job.error, 0)
    end
    if not defer then
      forget(jobs, id)
      return job.result
    end
  end
  return { job_id = id, job_status = "pending", kind = kind }
end

-- An RPC handler that starts this kind.
function M.rpc(kind)
  return function(params) return M.start(kind, params) end
end

-- get_job {job_id}: a finished job's result (or error) once, then it is
-- forgotten; a pending job's progress. {job_id, forget = true} drops the job
-- whatever its state (a caller that stopped waiting frees its slot).
function M.get(params)
  local jobs = data()
  local id = tonumber(type(params) == "table" and (params.job_id or params.id))
  if id and params.forget == true then
    local known = jobs.by_id[id] ~= nil
    forget(jobs, id)
    return { job_id = id, forgotten = known }
  end
  local job = id and jobs.by_id[id]
  if not job then
    error("unknown job id " .. tostring(id) .. ": a result is kept until it is read once, or for 5 minutes", 0)
  end
  -- Simulation is frozen at a trial boundary. A read still progresses in
  -- bounded RPC slices, without resuming entities or physical tasks.
  if job.status == "pending" and game.tick_paused then
    work(jobs, job, { left = M.MIN_WORK }, true)
  end
  local out = public(job)
  if job.status ~= "pending" then forget(jobs, id) end
  return out
end

-- Advances pending jobs, oldest first, with this tick's allowance.
function M.on_tick()
  local jobs = storage.jobs
  if not (jobs and #jobs.order > 0) then return end
  local budget = { left = allowance(jobs) }
  for _, id in ipairs({ table.unpack(jobs.order) }) do
    if budget.left <= 0 then break end
    local job = jobs.by_id[id]
    if job and job.status == "pending" then work(jobs, job, budget, true) end
  end
end

-- Runs a job definition within this call, a tick's worth of budget at a
-- time; it returns the result or raises the job's error, and ticks counts
-- the budget slices it took. Tests run whole jobs this way. In the game a
-- caller passes max_work: once that much is spent the job stops and
-- definition.truncated(state) is the result (or nil without one), and the
-- work counts against this tick's allowance.
function M.run_now(definition, params, per_tick, max_work)
  local state = definition.start(type(params) == "table" and params or {})
  local ticks, spent = 0, 0
  per_tick = per_tick or M.WORK_PER_TICK
  while true do
    if max_work and spent >= max_work then
      M.charge(spent)
      return definition.truncated and definition.truncated(state) or nil, ticks
    end
    ticks = ticks + 1
    local slice = max_work and math.min(per_tick, max_work - spent) or per_tick
    local budget = { left = slice }
    local result = definition.step(state, budget)
    spent = spent + (slice - budget.left)
    if result ~= nil then
      if max_work then M.charge(spent) end
      return result, ticks
    end
  end
end

-- ------------------------------------------------------ step helpers
-- A step that sorts or caps a list whose length grows with the factory or
-- the area uses these, so no tick sorts it whole.

-- Elements a merge sort moves per work item.
local SORT_PER_ITEM = 2

-- A stable bottom-up merge sort spread over ticks: its state lives in
-- owner[slot] between calls, and `list` must not change meanwhile. Returns
-- the sorted list once done (a new table, or `list` itself when it is
-- short), else nil.
function M.sort_step(owner, slot, list, less, budget)
  local s = owner[slot]
  if not s then
    if #list < 2 then return list end
    s = { src = list, dst = {}, width = 1, lo = 1, n = #list }
    owner[slot] = s
  end
  local n = s.n
  while s.width < n do
    local src, dst, width = s.src, s.dst, s.width
    while s.lo <= n do
      local lo = s.lo
      local mid, hi = math.min(lo + width, n + 1), math.min(lo + 2 * width, n + 1)
      local i, j, k = s.i or lo, s.j or mid, s.k or lo
      while k < hi do
        if budget.left <= 0 then s.i, s.j, s.k = i, j, k; return nil end
        budget.left = budget.left - 1
        local stop = math.min(hi, k + SORT_PER_ITEM)
        while k < stop do
          if j >= hi or (i < mid and not less(src[j], src[i])) then dst[k], i = src[i], i + 1
          else dst[k], j = src[j], j + 1 end
          k = k + 1
        end
      end
      s.i, s.j, s.k, s.lo = nil, nil, nil, hi
    end
    s.src, s.dst, s.width, s.lo = dst, src, width * 2, 1
  end
  owner[slot] = nil
  return s.src
end

-- Keeps in heap the `cap` rows that sort first by `less` (heap[1] is the
-- last of them), so a capped list never sorts every row it saw.
function M.keep_first(heap, cap, row, less)
  local n = #heap
  local i
  if n < cap then
    heap[n + 1], i = row, n + 1
    while i > 1 do
      local parent = math.floor(i / 2)
      if not less(heap[parent], heap[i]) then break end
      heap[parent], heap[i], i = heap[i], heap[parent], parent
    end
    return
  end
  if not less(row, heap[1]) then return end
  heap[1], i = row, 1
  while true do
    local child = 2 * i
    if child > n then break end
    if child < n and less(heap[child], heap[child + 1]) then child = child + 1 end
    if not less(heap[i], heap[child]) then break end
    heap[child], heap[i], i = heap[i], heap[child], child
  end
end

-- Pending and unread counts for diagnostics.
function M.counts()
  local jobs = storage.jobs
  local counts = { pending = 0, unread = 0 }
  for _, id in ipairs(jobs and jobs.order or {}) do
    if jobs.by_id[id].status == "pending" then counts.pending = counts.pending + 1 else counts.unread = counts.unread + 1 end
  end
  return counts
end

return M
