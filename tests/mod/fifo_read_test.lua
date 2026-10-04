-- Offline tests: read-only RPC results carry the body's FIFO state from the same read.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

_G.storage = { rpc_outbox = { next_id = 1, by_id = {} } }
_G.game = { tick = 6000 }
_G.defines = { events = setmetatable({}, { __index = function(_, key) return key end }) }
_G.script = {
  active_mods = { ["agentic-companion"] = "0.21.0", base = "2.0.0" },
  on_init = function() end, on_configuration_changed = function() end,
  on_event = function() end, on_nth_tick = function() end,
}
local registered
_G.remote = { add_interface = function(_, value) registered = value end }
local responded
_G.helpers = { table_to_json = function(value) responded = value; return "{}" end, json_to_table = function() return {} end }
_G.rcon = { print = function() end }

local body = { valid = true, crafting_queue_size = 0 }
local function stub(name, value) package.loaded[name] = value end
stub("scripts.state", { init = function() end })
local reads = {}
local function reader(name, value)
  return function() reads[#reads + 1] = name; return value and value() or { source = name } end
end
stub("scripts.tasks", { set_observer = function() end, on_tick = function() end,
  plan_status = reader("plan_status"), enqueue = reader("enqueue"), get = reader("get_task"),
  queue_plan = reader("queue_plan"), cancel = reader("cancel") })
stub("scripts.inspect", { inspect = reader("inspect") })
stub("scripts.research", { start_research = reader("start_research"), progression_status = reader("progression_status") })
stub("scripts.actions.walk", { on_path_finished = function() end })
stub("scripts.spatial", { observe_local = reader("observe_local"), can_place = reader("can_place"),
  describe_prototype = reader("describe_prototype") })
stub("scripts.find_placement", { find_placement = reader("find_placement") })
stub("scripts.map_summary", { map_summary = reader("map_summary") })
stub("scripts.production_requirements", { production_requirements = reader("production_requirements") })
stub("scripts.connect_entities", { connect_entities = reader("connect_entities") })
stub("scripts.run_snapshot", { capture = reader("run_snapshot") })
stub("scripts.companion", { get = function() return body end, record = function() return {} end,
  connect = reader("spawn_companion"), enforce_peaceful_world = function() end, enforce_normal_speed = function() end,
  update_map_tag = function() end, follow_spectators = function() end, on_player_available = function() end,
  on_player_left = function() end, on_player_died = function() end, on_player_respawned = function() end,
  on_player_removed = function() end })
assert(loadfile(here .. "/../../mod/agentic-companion/control.lua"))()

local function call(method)
  responded = nil
  registered.rpc(method, "")
  return responded and responded.ok and responded.data
end

local READS = { "ping", "observe_local", "inspect", "can_place", "find_placement", "map_summary",
  "production_requirements", "describe_prototype", "progression_status", "plan_status", "get_task" }

-- Idle: nothing active or queued, last task finished 45 s ago.
storage.tasks = { queue = {}, records = {}, last_finished_tick = game.tick - 45 * 60 }
local all_idle = true
for _, method in ipairs(READS) do
  local data = call(method)
  local fifo = data and data.fifo
  if not (fifo and fifo.queue_depth == 0 and fifo.idle_seconds == 45 and fifo.active_plan_id == nil) then
    all_idle = false
    print("     " .. method .. " lacks idle fifo state")
  end
end
check(all_idle, "every read-only RPC carries fifo {queue_depth=0, idle_seconds=45} without an extra call")
check(#reads == #READS - 1, "fifo decoration adds no handler call beyond the read itself")

for _, method in ipairs({ "enqueue", "queue_plan", "cancel", "run_snapshot", "connect_entities", "start_research" }) do
  local data = call(method)
  check(data and data.fifo == nil, method .. " result stays undecorated")
end

-- Busy: an active plan with a queued successor.
storage.tasks = { queue = { { id = 8, type = "plan" } }, records = {}, active = { id = 7, type = "plan" },
  last_finished_tick = game.tick - 45 * 60 }
local fifo = call("observe_local").fifo
check(fifo.active_plan_id == 7 and fifo.queue_depth == 1 and fifo.idle_seconds == 0,
  "an active plan reports its id, the queue depth, and zero idle seconds")

storage.tasks = { queue = {}, records = {}, active = { id = 9, type = "place" }, last_finished_tick = game.tick - 600 }
fifo = call("map_summary").fifo
check(fifo.active_plan_id == nil and fifo.queue_depth == 0 and fifo.idle_seconds == 0,
  "a single physical task is busy work without a plan id")

storage.tasks = { queue = {}, records = {}, last_finished_tick = game.tick - 600 }
body.crafting_queue_size = 2
check(call("can_place").fifo.idle_seconds == 0, "hand-crafting is not idle time")
body.crafting_queue_size = 0

storage.tasks = { queue = {}, records = {} }
fifo = call("plan_status").fifo
check(fifo.queue_depth == 0 and fifo.idle_seconds == nil, "unknown idle time stays absent after load or emergency stop")

storage.tasks = nil
check(call("ping").fifo == nil, "a read before storage init carries no fifo")

if failures > 0 then os.exit(1) end
