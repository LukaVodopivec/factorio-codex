-- The writer fence (rpc.lua): claim_writer hands out writer generations; a
-- write carrying an older one is refused WRITER_RETIRED, reads never are,
-- and an unstamped write passes only before the first claim (cancel always).
-- Also the reply size: replies up to CHUNK_SIZE go in one piece.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.game, _G.defines = { tick = 7 }, { shooting = { not_shooting = 0 } }
_G.log = function() end
_G.storage = { rpc_outbox = { next_id = 1, by_id = {} }, writer = { generation = 0 } }
-- Params arrive as JSON: here each test string names the table it decodes to.
local decoded = {}
local printed
_G.helpers = { table_to_json = dofile(here .. "/table_to_json.lua"), json_to_table = function(json) return decoded[json] end }
_G.rcon = { print = function(text) printed = text end }
local rpc = require("scripts.rpc")
local received = {}
for _, method in ipairs({ "queue_plan", "cancel", "start_research", "factory_status" }) do
  rpc.register(method, function(params) received[#received + 1] = { method = method, params = params }; return { done = method } end)
end
local function call(method, params)
  local json = "params" .. (#received + 1) .. method .. tostring(params and params.writer_generation)
  decoded[json] = params
  printed, received = nil, {}
  rpc.dispatch(method, params and json or "")
  return printed, received[1]
end
local function retired(text) return text:find('"ok":false', 1, true) and text:find("WRITER_RETIRED", 1, true) end

local text, got = call("queue_plan", { steps = {} })
check(got and text:find('"ok":true', 1, true), "before any claim a write without a generation passes (an older companion)")

rpc.dispatch("claim_writer", "")
local first = printed
rpc.dispatch("claim_writer", "")
check(first:find('"generation":1', 1, true) and printed:find('"generation":2', 1, true) and storage.writer.generation == 2,
  "each claim_writer hands out the next generation")

text, got = call("queue_plan", { steps = {}, writer_generation = 2 })
check(got and got.params.writer_generation == nil and text:find('"done":"queue_plan"', 1, true),
  "a write with the current generation runs; the handler never sees the stamp")
text, got = call("queue_plan", { steps = {}, writer_generation = 1 })
check(not got and retired(text) and text:find("writer generation 1 was replaced by generation 2", 1, true),
  "a write with an older generation is refused WRITER_RETIRED and never reaches its handler")
text, got = call("cancel", { all = true, writer_generation = 1 })
check(not got and retired(text), "a retired writer cannot cancel either")
text, got = call("start_research", { technology = "automation" })
check(not got and retired(text), "after a claim a write without a generation is refused")
text, got = call("cancel", { all = true, origin = "stop/supervisor" })
check(got and got.params.origin == "stop/supervisor", "an unstamped cancel (the supervisor's stop) always runs")
text, got = call("queue_plan", { steps = {}, writer_role = "supervisor" })
check(got and got.params.writer_role == nil and text:find('"ok":true', 1, true),
  "the supervisor's labelled write passes without a generation; the handler never sees the label")
text, got = call("queue_plan", { steps = {}, writer_role = "pilot" })
check(not got and retired(text), "only the supervisor label passes unstamped")
text, got = call("queue_plan", { steps = {}, writer_generation = 1, writer_role = "supervisor" })
check(not got and retired(text), "a retired generation stays refused whatever label it carries")
text, got = call("factory_status", { writer_generation = 1 })
check(got and got.params.writer_generation == nil and text:find('"ok":true', 1, true), "reads are never fenced")
text, got = call("queue_plan", { steps = {}, writer_generation = "2" })
check(not got and text:find("writer_generation must be a positive integer", 1, true), "a malformed generation is refused")

-- A save from before the newest claim: the newer stamp becomes current, so
-- the next claim is newer than any handed out.
storage.writer.generation = 1
text, got = call("queue_plan", { steps = {}, writer_generation = 2 })
rpc.dispatch("claim_writer", "")
check(got and printed:find('"generation":3', 1, true), "a stamp newer than the save's generation becomes current")

-- floor (the host clock) keeps generations rising across a reloaded save:
-- P1 claims, the save is rolled back to before that claim, P2 claims later.
decoded.floor100 = { role = "pilot", floor = 100 }
rpc.dispatch("claim_writer", "floor100")
check(printed:find('"generation":100', 1, true), "a claim takes the floor when it is above the next generation")
storage.writer.generation = 3
decoded.floor101 = { role = "pilot", floor = 101 }
rpc.dispatch("claim_writer", "floor101")
text, got = call("queue_plan", { steps = {}, writer_generation = 100 })
check(storage.writer.generation == 101 and not got and retired(text),
  "after a rollback the next claim is still newer, so the earlier pilot is fenced")
decoded.floor5 = { role = "pilot", floor = 5 }
rpc.dispatch("claim_writer", "floor5")
check(printed:find('"generation":102', 1, true), "a floor below the next generation changes nothing")
decoded.badfloor = { floor = "7" }
rpc.dispatch("claim_writer", "badfloor")
check(printed:find("floor must be a positive integer", 1, true) and storage.writer.generation == 102, "a malformed floor is refused")

-- Reply size: one piece up to CHUNK_SIZE, chunked parts beyond it.
check(rpc.CHUNK_SIZE == 256 * 1024, "replies go in one piece up to 256 KiB")
local big = string.rep("a", rpc.CHUNK_SIZE - 100)
rpc.register("big", function() return { text = big } end)
rpc.dispatch("big", "")
check(printed:find('"ok":true', 1, true) and not printed:find('"chunked"', 1, true) and #printed > rpc.CHUNK_SIZE - 100,
  "a reply under CHUNK_SIZE is printed whole")
big = string.rep("b", rpc.CHUNK_SIZE + 100)
rpc.dispatch("big", "")
local head = printed
decoded.part2 = { id = 1, part = 2 }
rpc.dispatch("get_chunk", "part2")
check(head:find('"chunked":true', 1, true) and head:find('"parts":2', 1, true) and printed:find('"ok":true', 1, true)
  and #storage.rpc_outbox.by_id[1].parts[1] == rpc.CHUNK_SIZE, "a larger reply is stored in CHUNK_SIZE parts for get_chunk")

os.exit(failures == 0 and 0 or 1)
