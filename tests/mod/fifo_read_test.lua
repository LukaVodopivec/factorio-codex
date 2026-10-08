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
local body_state = "on_surface"
local function stub(name, value) package.loaded[name] = value end
stub("scripts.state", { init = function() end })
local reads = {}
local function reader(name, value)
  return function() reads[#reads + 1] = name; return value and value() or { source = name } end
end
-- A heavy read is a job (jobs.lua); a small one finishes in its RPC's tick.
local function job_reader(name)
  return { start = function() return {} end, step = reader(name) }
end
local fifo_demand
stub("scripts.tasks", { queued_demand = function() return fifo_demand end, set_observer = function() end, set_upkeep_listener = function() end, set_boundary_upkeep = function() end, on_tick = function() end, bound_for = function() return nil end,
  plan_status = reader("plan_status"), enqueue = reader("enqueue"), get = reader("get_task"),
  queue_plan = reader("queue_plan"), cancel = reader("cancel") })
stub("scripts.inspect", { job = job_reader("inspect") })
stub("scripts.research", { start_research = reader("start_research"), progression_status = reader("progression_status"),
  set_logger = function() end })
stub("scripts.actions.walk", { on_path_finished = function() end })
stub("scripts.spatial", { observe_job = job_reader("observe_local"), observe_compact = reader("observe_compact"),
  can_place = reader("can_place"), describe_prototype = reader("describe_prototype") })
stub("scripts.find_placement", { find_placement = reader("find_placement") })
stub("scripts.map_summary", { summary_job = job_reader("map_summary") })
stub("scripts.production_requirements", { production_requirements = reader("production_requirements") })
stub("scripts.connect_entities", { job = job_reader("connect_entities") })
stub("scripts.run_snapshot", { job = job_reader("run_snapshot") })
stub("scripts.companion", { get = function() return body end, record = function() return {} end,
  connect = reader("spawn_companion"), enforce_peaceful_world = function() end, enforce_normal_speed = function() end,
  update_map_tag = function() end, follow_spectators = function() end, on_player_available = function() end,
  on_player_left = function() end, on_player_died = function() end, on_player_respawned = function() end,
  on_player_removed = function() end, world_policy_errors = function() end,
  body = function() return { state = body_state } end,
  body_summary = function() return { state = body_state, surface_ref = "nauvis" } end,
  rebind = function() end, note_body_surface = function() end })
assert(loadfile(here .. "/../../mod/agentic-companion/control.lua"))()

local function call(method)
  responded = nil
  registered.rpc(method, "")
  return responded and responded.ok and responded.data
end

local READS = { "ping", "observe_local", "inspect", "can_place", "find_placement", "map_summary",
  "production_requirements", "describe_prototype", "progression_status", "plan_status", "get_task", "connect_entities" }

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
local pinged = call("ping")
check(pinged.protocol_version == 29 and pinged.body.state == "on_surface" and pinged.body.surface_ref == "nauvis"
  and call("plan_status").fifo.body.surface_ref == "nauvis",
  "ping (protocol 29) and every fifo block name the body's state and surface")
body_state = "aboard_platform"
local away = call("ping")
body_state = "dead"
local dead = call("ping")
body_state = "on_surface"
check(away.companion_exists == true and away.companion_dead == false and dead.companion_exists == false
  and dead.companion_dead == true, "a body aboard a platform exists (connected, away); a dead one does not")
reads = {}

for _, method in ipairs({ "enqueue", "queue_plan", "cancel", "run_snapshot", "start_research" }) do
  local data = call(method)
  check(data and data.fifo == nil, method .. " result stays undecorated")
end

-- Busy: an active plan with a queued successor.
storage.tasks = { queue = { { id = 8, type = "plan" } }, records = {}, active = { id = 7, type = "plan" },
  last_finished_tick = game.tick - 45 * 60 }
local fifo = call("observe_local").fifo
check(fifo.active_plan_id == 7 and fifo.queue_depth == 1 and fifo.idle_seconds == 0,
  "an active plan reports its id, the queue depth, and zero idle seconds")
fifo_demand = { queued_demand = { coal = 23 }, short_by = { coal = 3 }, omitted_queued_demand = 2 }
fifo = call("observe_local").fifo
fifo_demand = nil
check(fifo.queued_demand.coal == 23 and fifo.short_by.coal == 3 and fifo.omitted_queued_demand == 2
  and fifo.omitted_short_by == nil, "with plans queued the fifo block carries queued_demand and short_by")

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
check(fifo.upkeep_off_since_tick == nil, "without a stop upkeep is not reported off")
storage.tasks = { queue = {}, records = {}, last_cancel_all_tick = game.tick - 60 }
check(call("observe_local").fifo.upkeep_off_since_tick == game.tick - 60,
  "after an emergency stop the fifo block says upkeep is off since that stop")
storage.tasks = { queue = {}, records = {}, last_cancel_all_tick = game.tick - 60, last_finished_tick = game.tick - 30 }
check(call("observe_local").fifo.upkeep_off_since_tick == nil, "once a plan finishes (or keep_upkeep) upkeep is not reported off")

storage.tasks = nil
check(call("ping").fifo == nil, "a read before storage init carries no fifo")

if failures > 0 then os.exit(1) end
