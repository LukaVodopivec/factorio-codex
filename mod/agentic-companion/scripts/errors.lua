-- Error hygiene for every result. A raised Lua error starts with its chunk
-- location ("__agentic-companion__/scripts/actions/mine.lua:294: "): the
-- mod's source, never part of a message, so plain() drops it wherever it
-- stands. Errors the dispatchers catch (an RPC handler, a step runner, an
-- event handler) are kept, plain, in a ring in storage.handler_errors
-- (state.init): the last RING_SIZE and the count since the save gained the
-- ring, which ping (connect_status) shows.
local M = {}

M.RING_SIZE = 20
M.SHOWN = 3 -- the newest errors ping shows
local MAX_MESSAGE = 300 -- characters kept per error in the ring

-- Only a token ending in .lua:<line>: goes: the older "^.-:%d+:%s*" strip
-- would also eat a detail's own words in front of an embedded location.
function M.plain(err)
  return (tostring(err):gsub("%S-%.lua:%d+:%s*", ""))
end

-- Keeps a caught error, where naming its handler (rpc:<method>,
-- task:<type>:<phase>, event:<name>); returns the plain message.
function M.record(where, err)
  local message = M.plain(err)
  storage.handler_errors = storage.handler_errors or { count = 0, recent = {} }
  local ring = storage.handler_errors
  ring.count = ring.count + 1
  ring.recent[#ring.recent + 1] = { tick = game and game.tick, where = where, error = message:sub(1, MAX_MESSAGE) }
  while #ring.recent > M.RING_SIZE do table.remove(ring.recent, 1) end
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
