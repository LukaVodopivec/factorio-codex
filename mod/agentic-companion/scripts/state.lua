local M = {}

-- Initializes/migrates the storage schema. Safe to call repeatedly.
-- All fields any module needs MUST be declared here (single owner of the schema).
function M.init()

  -- Tasks: one fixed lane (queue + active) for the sole Codex body.
  storage.tasks = storage.tasks or {}
  storage.tasks.next_id = storage.tasks.next_id or 1
  storage.tasks.records = storage.tasks.records or {}
  -- chain id -> failure tick: late enqueues of a failed plan cancel instantly
  storage.tasks.failed_chains = storage.tasks.failed_chains or {}
  storage.tasks.lane = storage.tasks.lane or { queue = {}, active = nil }
  storage.tasks.lane.queue = storage.tasks.lane.queue or {}

  -- pathfinder bookkeeping: request id -> {task_id} (see actions/walk.lua)
  storage.path_requests = {}
  -- chunked RPC responses: { next_id, by_id = { [id] = { parts = {...}, created_tick } } }
  storage.rpc_outbox = storage.rpc_outbox or { next_id = 1, by_id = {} }
end

return M
