-- Error hygiene for every result. A raised Lua error starts with its chunk
-- location ("__agentic-companion__/scripts/actions/mine.lua:294: "): the
-- mod's source, never part of a message, so plain() drops it wherever it
-- stands. Errors the dispatchers catch (an RPC handler or a job: a fault,
-- not a deliberate refusal; a step runner, an event handler) are kept,
-- plain, in a ring in storage.handler_errors (state.init): the last
-- RING_SIZE and the count since the save gained the ring, which ping
-- (connect_status) shows and run_snapshot samples; each also leaves one
-- line in the server log.
local M = {}

M.RING_SIZE = 20
M.SHOWN = 3 -- the newest errors ping shows
local MAX_MESSAGE = 300 -- characters kept per error in the ring

-- Only a token ending in .lua:<line>: goes: the older "^.-:%d+:%s*" strip
-- would also eat a detail's own words in front of an embedded location.
function M.plain(err)
  return (tostring(err):gsub("%S-%.lua:%d+:%s*", ""))
end

-- A result table's strings, plain, in place: a runner's outcome can carry an
-- inner error deep down (build_plan's failures[i].why). Bounded: SCRUB_DEPTH
-- levels of tables, and userdata (a LuaEntity) is never entered.
local SCRUB_DEPTH = 4
function M.scrub(value, depth)
  if type(value) == "string" then return M.plain(value) end
  depth = depth or SCRUB_DEPTH
  if type(value) ~= "table" or depth <= 0 then return value end
  for key, item in pairs(value) do
    if type(item) == "string" then
      if item:find(".lua:", 1, true) then value[key] = M.plain(item) end
    elseif type(item) == "table" then
      M.scrub(item, depth - 1)
    end
  end
  return value
end

-- A refusal raised on purpose (error(msg, 0): no location of its own, or a
-- message that leads with a code, such as JOBS_BUSY), not a fault: the
-- request dispatchers (rpc, jobs) answer it without filling the ring.
-- Returns that verdict and the plain message.
function M.deliberate(err)
  local text = tostring(err)
  local message = M.plain(text)
  return message == text or message:match("^[A-Z][A-Z0-9_]+[A-Z0-9]:") ~= nil, message
end

-- text cut to at most limit bytes, never inside a UTF-8 character (the
-- mod's reasons carry "—").
function M.cut(text, limit)
  if #text <= limit then return text end
  local cut = limit
  while cut > 0 and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do cut = cut - 1 end
  return text:sub(1, cut)
end

-- Keeps a caught error, where naming its handler (rpc:<method>,
-- task:<type>:<phase>, event:<name>), and logs one line for it; returns
-- the plain message.
function M.record(where, err)
  local message = M.plain(err)
  storage.handler_errors = storage.handler_errors or { count = 0, recent = {} }
  local ring = storage.handler_errors
  local kept = M.cut(message, MAX_MESSAGE)
  ring.count = ring.count + 1
  ring.recent[#ring.recent + 1] = { tick = game and game.tick, where = where, error = kept }
  while #ring.recent > M.RING_SIZE do table.remove(ring.recent, 1) end
  if log then
    pcall(log, string.format("[agentic-companion] handler fault %s tick=%s: %s", tostring(where),
      tostring(game and game.tick), (kept:gsub("%s*\n%s*", " "))))
  end
  return message
end

-- For ping: {count, recent = the newest SHOWN, oldest first}; nil before the
-- first error.
function M.summary()
  local ring = storage.handler_errors
  if not ring or ring.count == 0 then return nil end
  local recent = {}
  for i = math.max(1, #ring.recent - M.SHOWN + 1), #ring.recent do recent[#recent + 1] = ring.recent[i] end
  return { count = ring.count, recent = recent }
end

-- The code of a step or task that ended failed or partial: its outcome's,
-- else the one its detail leads with, else STEP_FAILED_UNCLASSIFIED
-- (STEP_PARTIAL_UNCLASSIFIED), which the caller reports beside the action.
function M.code(status, outcome, detail)
  if type(outcome) == "table" and type(outcome.code) == "string" then return outcome.code end
  local led = type(detail) == "string" and detail:match("^([A-Z][A-Z0-9_]+[A-Z0-9])")
  return led or ("STEP_" .. string.upper(tostring(status)) .. "_UNCLASSIFIED")
end

return M
