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
-- step = function(state, budget) -> result | nil}; step spends from
-- budget.left (it may overrun by its last item) and returns the result once
-- done. An error in start is the RPC's error; an error in step fails the job.
local M = {}

M.WORK_PER_TICK = 600
M.MIN_WORK = 100
M.MAX_JOBS = 8
M.RESULT_TTL_TICKS = 5 * 60 * 60

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

-- Advances one job by the budget; true once it is finished (done or failed).
local function work(jobs, job, budget)
  local definition = kinds[job.kind]
  local before = budget.left
  local ok, result
  if not definition then
    ok, result = false, "job kind " .. tostring(job.kind) .. " is not known to this mod version"
  else
    ok, result = pcall(definition.step, job.state, budget)
  end
  jobs.used = used(jobs) + math.max(0, before - budget.left)
  job.ticks = (job.ticks or 0) + 1
  if ok and result == nil then return false end
  job.state = nil
  job.finished_tick = now()
  if ok then
    job.status, job.result = "done", result
  else
    job.status, job.error = "failed", (tostring(result):gsub("^.-:%d+:%s*", ""))
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
  if job.status == "done" then out.result = job.result
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
  if not waiting and work(jobs, job, { left = allowance(jobs) }) then
    forget(jobs, id)
    if job.status == "failed" then error(job.error, 0) end
    return job.result
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
    if job and job.status == "pending" then work(jobs, job, budget) end
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
