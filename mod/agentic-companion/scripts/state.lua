local M = {}

-- Initializes the fresh v5 storage schema. Safe to call repeatedly.
-- All fields any module needs MUST be declared here (single owner of the schema).
function M.init()
  -- Tasks: one lane for the sole Codex body. Fresh v5 has no migration
  -- consumer; preserve only an already-current lane on repeated init.
  local lane = storage.tasks and storage.tasks.lane
  storage.tasks = { lane = lane or {
    next_id = 1,
    records = {},
    queue = {},
  } }

  -- At most one path request exists because only the sole active task runs.
  storage.path_request = nil
  -- chunked RPC responses: { next_id, by_id = { [id] = { parts = {...}, created_tick } } }
  storage.rpc_outbox = storage.rpc_outbox or { next_id = 1, by_id = {} }
end

return M
