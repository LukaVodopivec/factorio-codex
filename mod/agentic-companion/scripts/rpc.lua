-- Single RPC entry point for the companion app.
-- Params arrive as a JSON string; the response is printed to the RCON
-- connection as a {ok, data|error} JSON envelope. Envelopes larger than
-- CHUNK_SIZE are stored in storage.rpc_outbox and streamed back to the
-- app part by part via get_chunk.
local timing = require("scripts.profiler")

local M = {}

M.handlers = {}

local CHUNK_SIZE = 3400
local OUTBOX_TTL_TICKS = 5 * 60 * 60 -- stored chunked responses expire after 5 minutes

function M.register(name, fn)
  M.handlers[name] = fn
end

-- never_chunk: get_chunk replies must always arrive whole — chunking a chunk
-- would recurse from the companion's point of view. A single part plus the
-- envelope stays well within what RCON's multi-packet responses handle.
local function respond(tbl, never_chunk)
  local json = helpers.table_to_json(tbl)
  if never_chunk or #json <= CHUNK_SIZE then
    rcon.print(json)
    return
  end
  local parts = {}
  for i = 1, #json, CHUNK_SIZE do
    parts[#parts + 1] = string.sub(json, i, i + CHUNK_SIZE - 1)
  end
  local box = storage.rpc_outbox
  local id = box.next_id
  box.next_id = id + 1
  box.by_id[id] = { parts = parts, created_tick = game.tick }
  rcon.print(helpers.table_to_json({
    ok = true,
    chunked = true,
    id = id,
    parts = #parts,
    data = parts[1],
  }))
end

local function prune_outbox()
  local box = storage.rpc_outbox
  for id, entry in pairs(box.by_id) do
    if game.tick - entry.created_tick > OUTBOX_TTL_TICKS then
      box.by_id[id] = nil
    end
  end
end

local function run(method, params_json)
  prune_outbox()
  local handler = M.handlers[method]
  if not handler then
    respond({ ok = false, error = "unknown method: " .. tostring(method) })
    return
  end
  local params = {}
  if params_json ~= nil and params_json ~= "" then
    local decoded = helpers.json_to_table(params_json)
    if type(decoded) ~= "table" then
      respond({ ok = false, error = "params must be a JSON object string" })
      return
    end
    params = decoded
  end
  local ok, result = pcall(handler, params)
  if ok then
    respond({ ok = true, data = result or {} }, method == "get_chunk")
  else
    respond({ ok = false, error = tostring(result) })
  end
end

-- Each command's whole Lua time (decode, handler, encode) goes to the game
-- log; get_chunk only replays stored parts and is not logged.
function M.dispatch(method, params_json)
  local profiler = method ~= "get_chunk" and timing.start() or nil
  run(method, params_json)
  timing.log_rpc(method, profiler)
end

-- Built-in transport helpers; everything else registers from control.lua.

M.register("get_chunk", function(params)
  local id = tonumber(params.id)
  local entry = id and storage.rpc_outbox.by_id[id]
  if not entry then
    error("unknown chunk id " .. tostring(params.id)
      .. " — chunked responses expire after 5 minutes, re-run the original call")
  end
  local part = tonumber(params.part)
  local data = part and entry.parts[part]
  if not data then
    error("chunk " .. id .. " has " .. #entry.parts
      .. " parts; there is no part " .. tostring(params.part))
  end
  return { data = data }
end)

return M
