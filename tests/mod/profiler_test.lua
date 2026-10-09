-- Per-RPC and per-600-tick Lua time logging (profiler.lua, rpc.dispatch).
-- LuaProfiler is simulated: only its documented stop/restart/reset are used,
-- and the value reaches the log, never the game.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local created, logged, printed = {}, {}, {}
local function profiler(stopped)
  local p = { running = not stopped, calls = {} }
  for _, method in ipairs({ "stop", "restart", "reset" }) do
    p[method] = function()
      p.calls[#p.calls + 1] = method
      p.running = method ~= "stop"
    end
  end
  created[#created + 1] = p
  return p
end
_G.helpers = { create_profiler = profiler, table_to_json = function(t) return t.ok and "ok" or "err" end,
  json_to_table = function() return {} end }
_G.log = function(message) logged[#logged + 1] = message end
_G.rcon = { print = function(text) printed[#printed + 1] = text end }
_G.game = { tick = 10 }
_G.storage = { rpc_outbox = { next_id = 1, by_id = {} } }

local rpc = require("scripts.rpc")
local timing = require("scripts.profiler")
rpc.register("probe", function() return { done = true } end)
rpc.register("broken", function() error("handler failed") end)

rpc.dispatch("probe", "")
local entry = logged[1]
check(#logged == 1 and entry[1] == "" and entry[2] == "rpc " and entry[3] == "probe" and entry[4] == " tick "
  and entry[5] == 10 and entry[6] == " " and entry[7] == created[1] and not created[1].running and printed[1] == "ok",
  "each RPC logs its method, its tick (the host sums a tick's RPCs) and a stopped profiler after replying")
rpc.dispatch("broken", "")
check(#logged == 2 and logged[2][3] == "broken" and printed[2] == "err", "a failing RPC is still logged")
storage.rpc_outbox.by_id[1] = { parts = { "a" }, created_tick = 10 }
rpc.dispatch("get_chunk", "")
check(#logged == 2, "get_chunk replays are not logged")

-- Tick handlers: one aggregate resumed around each handler, logged and reset
-- every 600 ticks.
local ran = 0
for tick = 1, 600 do
  timing.measure(function(n) ran = ran + n end, 1)
  timing.log_ticks(tick)
end
local aggregate = created[#created]
local restarts = 0
for _, call in ipairs(aggregate.calls) do if call == "restart" then restarts = restarts + 1 end end
check(ran == 600 and restarts == 600 and #logged == 3 and logged[3][2] == "on_tick " and logged[3][3] == 600
  and logged[3][5] == aggregate and not aggregate.running,
  "tick handlers add to one aggregate that is logged once per 600 ticks and stopped again")
timing.log_ticks(601)
check(#logged == 3, "no tick log between periods")

-- Without helpers.create_profiler (or log) nothing is logged and nothing fails.
helpers.create_profiler = nil
rpc.dispatch("probe", "")
check(#logged == 3 and printed[#printed] == "ok", "an RPC without a profiler still replies")

os.exit(failures == 0 and 0 or 1)
