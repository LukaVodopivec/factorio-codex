-- Single RPC entry point for the companion app.
-- Params arrive as a JSON string; the response is printed to the RCON
-- connection as a {ok, data|error} JSON envelope. Envelopes larger than
-- CHUNK_SIZE are stored in storage.rpc_outbox and streamed back to the
-- app part by part via get_chunk.
-- Measured against 2.0.77 through the companion's RCON client: a 4 MB reply
-- arrives intact in one command, and rcon.print of 1 MB takes about 0.26 ms
-- of Lua time (256 KB: 0.06 ms), so nearly every reply goes in one piece.
local timing = require("scripts.profiler")
local benchmark = require("scripts.benchmark")
local errors = require("scripts.errors")

local M = {}

M.handlers = {}

M.CHUNK_SIZE = 256 * 1024
-- A handler's result may carry, under this key, {field = JSON string}:
-- fields already encoded (a job's result, encoded over earlier ticks) that
-- replace the same fields of the result, so they are not encoded again.
M.RAW_JSON = "__json"
local OUTBOX_TTL_TICKS = 5 * 60 * 60 -- stored chunked responses expire after 5 minutes

function M.register(name, fn)
  M.handlers[name] = fn
end

-- never_chunk: get_chunk replies must always arrive whole — chunking a chunk
-- would recurse from the companion's point of view. A single part plus the
-- envelope stays well within what RCON's multi-packet responses handle.
-- helpers.table_to_json writes NaN and infinities as bare nan/inf, which no
-- JSON parser reads: one such number would make the whole reply unreadable.
-- They become null.
function M.to_json(value)
  local json = helpers.table_to_json(value)
  if not (json:find("nan", 1, true) or json:find("inf", 1, true)) then return json end
  return (json:gsub("([%[,:])%-?nan([,%]}])", "%1null%2"):gsub("([%[,:])%-?inf([,%]}])", "%1null%2"))
end

local function encode(tbl)
  local data = tbl.data
  local raw = type(data) == "table" and data[M.RAW_JSON]
  if not raw then return M.to_json(tbl) end
  data[M.RAW_JSON] = nil
  local fields = {}
  for field, json in pairs(raw) do
    data[field] = nil
    fields[#fields + 1] = string.format("%q", field) .. ":" .. json
  end
  table.sort(fields)
  local body = M.to_json(data)
  body = body == "{}" and "{" .. table.concat(fields, ",") .. "}"
    or string.sub(body, 1, -2) .. "," .. table.concat(fields, ",") .. "}"
  return '{"ok":true,"data":' .. body .. "}"
end

-- Returns the encoded reply's size in bytes (the profiler logs it).
local function respond(tbl, never_chunk)
  local json = encode(tbl)
  if never_chunk or #json <= M.CHUNK_SIZE then
    rcon.print(json)
    return #json
  end
  local parts = {}
  for i = 1, #json, M.CHUNK_SIZE do
    parts[#parts + 1] = string.sub(json, i, i + M.CHUNK_SIZE - 1)
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
  return #json
end

local function prune_outbox()
  local box = storage.rpc_outbox
  for id, entry in pairs(box.by_id) do
    if game.tick - entry.created_tick > OUTBOX_TTL_TICKS then
      box.by_id[id] = nil
    end
  end
end

-- The writer fence. claim_writer gives the pilot's MCP process a new writer
-- generation, which it sends with each of its writes (writer_generation): a
-- write carrying an older generation is refused WRITER_RETIRED, so a
-- replaced pilot can no longer write. The writes are benchmark.MUTATIONS and
-- cancel; reads are never fenced. A write without a generation (an older
-- companion, an unlabelled session) passes while none was ever claimed;
-- after a claim only cancel still does, so an emergency stop always works,
-- and so does every write of the supervisor's process, which labels its
-- writes writer_role = "supervisor" and claims nothing.
local function fence(method, params)
  local stamp = params.writer_generation
  local supervisor = params.writer_role == "supervisor"
  params.writer_generation, params.writer_role = nil, nil
  if not (benchmark.MUTATIONS[method] or method == "cancel") then return end
  local writer = storage.writer
  if stamp == nil then
    if writer.generation > 0 and method ~= "cancel" and not supervisor then
      error("WRITER_RETIRED: " .. method .. " carries no writer generation; generation "
        .. writer.generation .. " holds the writes", 0)
    end
    return
  end
  if type(stamp) ~= "number" or stamp % 1 ~= 0 or stamp < 1 then
    error("writer_generation must be a positive integer", 0)
  end
  if stamp < writer.generation then
    error("WRITER_RETIRED: writer generation " .. stamp .. " was replaced by generation " .. writer.generation, 0)
  end
  -- A save from before that claim was loaded: the newer generation becomes
  -- current, so the next claim is newer than every one handed out.
  writer.generation = stamp
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
  local unfenced, fence_error = pcall(fence, method, params)
  if not unfenced then respond({ ok = false, error = errors.plain(fence_error) }); return end
  local allowed, admission_error = pcall(benchmark.assert_action, method)
  -- An error reaches the app without its Lua source location; a handler's
  -- fault (not a deliberate refusal) is also kept in the error ring
  -- (errors.lua).
  if not allowed then respond({ ok = false, error = errors.plain(admission_error) }); return end
  local ok, result = pcall(handler, params)
  if ok then
    return respond({ ok = true, data = result or {} }, method == "get_chunk")
  else
    local deliberate, message = errors.deliberate(result)
    return respond({ ok = false, error = deliberate and message or errors.record("rpc:" .. tostring(method), result) })
  end
end

-- Each command's whole Lua time (decode, handler, encode) and its reply's size go
-- to the game log; get_chunk only replays stored parts and is not logged.
function M.dispatch(method, params_json)
  local profiler = method ~= "get_chunk" and timing.start() or nil
  local bytes = run(method, params_json)
  timing.log_rpc(method, profiler, bytes)
end

-- Built-in transport helpers; everything else registers from control.lua.

-- A new writer generation (the fence above), claimed once by the pilot's
-- MCP process as it first connects. floor (the host's clock in seconds)
-- keeps generations rising when a save from before a claim is reloaded:
-- the next claim is then still newer than the one the earlier process holds.
M.register("claim_writer", function(params)
  local floor = params.floor
  if floor ~= nil and (type(floor) ~= "number" or floor % 1 ~= 0 or floor < 1) then
    error("floor must be a positive integer", 0)
  end
  local writer = storage.writer
  local previous, previous_tick = writer.generation, writer.claimed_tick
  writer.generation = math.max(previous + 1, floor or 0)
  writer.claimed_tick = game.tick
  log("writer generation " .. writer.generation .. " claimed by " .. tostring(params.role):sub(1, 40)
    .. "; generation " .. previous .. " was claimed at tick " .. tostring(previous_tick))
  return { generation = writer.generation }
end)

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
