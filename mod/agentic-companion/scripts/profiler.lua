-- Lua time of each RPC, and of all tick handlers together per 600 ticks,
-- written to the game log (factorio-current.log): "rpc <method> Duration: …"
-- and "on_tick 600 ticks Duration: …". LuaProfiler values can only be
-- logged, never read, so nothing here can steer the game. Profilers cannot be
-- serialized, so they live in this module, not in storage. Without
-- helpers.create_profiler (tests) every call is a no-op.
local M = {}

M.TICK_LOG_PERIOD = 600

local function create(stopped)
  local ok, profiler = pcall(function() return helpers.create_profiler(stopped) end)
  return ok and profiler or nil
end

-- A running profiler for one RPC, or nil.
function M.start() return create(false) end

function M.log_rpc(method, profiler)
  if not profiler then return end
  pcall(function()
    profiler.stop()
    log({ "", "rpc ", tostring(method), " ", profiler })
  end)
end

local ticks -- the stopped aggregate; resumed around each tick handler

-- Runs fn(...) with its time added to the tick aggregate.
function M.measure(fn, ...)
  if ticks == nil then ticks = create(true) or false end
  if not ticks then return fn(...) end
  -- An error in fn is a game error anyway; the clock needs no stop then.
  ticks.restart()
  fn(...)
  ticks.stop()
end

-- Every TICK_LOG_PERIOD ticks: log the aggregate and start a new one.
function M.log_ticks(tick)
  if not ticks or tick % M.TICK_LOG_PERIOD ~= 0 then return end
  pcall(function()
    log({ "", "on_tick ", M.TICK_LOG_PERIOD, " ticks ", ticks })
    ticks.reset()
    ticks.stop()
  end)
end

return M
