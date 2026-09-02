local M = {}

-- Initializes/migrates the storage schema. Safe to call repeatedly.
-- All fields any module needs MUST be declared here (single owner of the schema).
function M.init()

  -- Tasks: one queue and one active task for the sole Codex body.
  storage.tasks = storage.tasks or {}
  storage.tasks.next_id = storage.tasks.next_id or 1
  storage.tasks.records = storage.tasks.records or {}
  storage.tasks.queue = storage.tasks.queue or {}

  -- pathfinder bookkeeping: request id -> {task_id} (see actions/walk.lua)
  storage.path_requests = {}
  -- chunked RPC responses: { next_id, by_id = { [id] = { parts = {...}, created_tick } } }
  storage.rpc_outbox = storage.rpc_outbox or { next_id = 1, by_id = {} }
end

return M
