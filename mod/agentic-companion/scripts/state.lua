local M = {}

-- Initializes the v6-compatible single-body storage schema. Safe to call repeatedly.
-- All fields any module needs MUST be declared here (single owner of the schema).
function M.init()
  -- Tasks: one flat queue and one optional active task for the sole Codex
  -- body. Rebuild only the canonical flat shape while retaining its data.
  local tasks = storage.tasks or {}
  storage.tasks = {
    next_id = tasks.next_id or 1,
    records = tasks.records or {},
    queue = tasks.queue or {},
    active = tasks.active,
  }

  -- At most one path request exists because only the sole active task runs.
  storage.path_request = nil
  -- chunked RPC responses: { next_id, by_id = { [id] = { parts = {...}, created_tick } } }
  storage.rpc_outbox = storage.rpc_outbox or { next_id = 1, by_id = {} }
end

return M
