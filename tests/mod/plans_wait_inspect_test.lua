local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end
local output_count = 0
local inspect_calls = 0
local output_inventory = { is_empty = function() return output_count == 0 end,
  get_contents = function() return output_count == 0 and {} or { { name = "iron-plate", count = output_count } } end }
local empty_inventory = { is_empty = function() return true end, get_contents = function() return {} end }
local entity = { valid = true, name = "stone-furnace", type = "furnace", direction = 0,
  position = { x = 2, y = 2 }, fluidbox = {},
  get_inventory = function(index) return index == 2 and output_inventory or empty_inventory end,
  get_output_inventory = function() return output_inventory end,
  get_recipe = function() return nil end, get_fluid_contents = function() return {} end }
local surface = { find_entities_filtered = function(filter)
  inspect_calls = inspect_calls + 1
  check(filter.position.x == 2 and filter.position.y == 2,
    "wait_for_item passes its exact position through real batch inspection")
  return { entity }
end }
local technology = { name = "automation", researched = false }
local force = { technologies = { automation = technology }, current_research = technology, research_queue = {} }
local body = { valid = true, position = { x = 0, y = 0 }, surface = surface, force = force,
  walking_state = {}, mining_state = {}, crafting_queue = {} }
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
local all_physical_starts, all_physical_ticks, transfer_effects, placement_effects = 0, 0, 0, {}
local function runner(kind) return {
  start = function(task)
    all_physical_starts = all_physical_starts + 1
    if kind == "place" then
      placement_effects[#placement_effects + 1] = { name = task.item, x = task.position.x, y = task.position.y }
    end
  end,
  tick = function()
    all_physical_ticks = all_physical_ticks + 1
    if kind == "insert" or kind == "extract" then
      transfer_effects = transfer_effects + 1
      return { status = "done", outcome = { transfers = { { item = "iron-plate", inserted = 1, extracted = 1 } } } }
    end
    return { status = "done" }
  end,
} end
local physical_starts, physical_ticks = 0, 0
local physical_runner = {
  start = function() physical_starts = physical_starts + 1; all_physical_starts = all_physical_starts + 1; body.walking_state = { walking = true } end,
  tick = function() physical_ticks = physical_ticks + 1; all_physical_ticks = all_physical_ticks + 1 end,
}
package.loaded["scripts.actions.walk"], package.loaded["scripts.actions.mine"], package.loaded["scripts.actions.craft"] = physical_runner, runner(), runner()
package.loaded["scripts.actions.pickup"] = runner()
local place_runner = runner("place")
package.loaded["scripts.actions.build"] = { place = place_runner, rotate = runner(),
  set_recipe_action = { runner = runner(), make_task = function() return {} end } }
package.loaded["scripts.actions.transfer"] = { insert = runner("insert"), extract = runner("extract"),
  flush_action = { runner = runner("flush_fluid"), make_task = function() return {} end } }
package.loaded["scripts.actions.build_plan"] = runner()
_G.defines = { inventory = { fuel = 1, furnace_result = 2 }, entity_status = {}, shooting = { not_shooting = 0 } }
_G.game = { tick = 0 }
_G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
-- Keep scripts.inspect real: exercise plan -> wait -> batch inspect -> inventory.
package.loaded["scripts.inspect"], package.loaded["scripts.tasks"] = nil, nil
local tasks = require("scripts.tasks")
local queued = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2,
  inventory = "output", item = "iron-plate", count = 2, timeout_seconds = 3 } } })
game.tick = 1; tasks.on_tick()
check(tasks.plan_status({ plan_id = queued.plan_id }).status == "waiting",
  "real wait path parks without occupying the body before the requested count exists")
output_count = 2; game.tick = 2; tasks.on_tick()
check(tasks.plan_status({ plan_id = queued.plan_id }).status == "waiting",
  "parked wait does not re-inspect before its deterministic next_check_tick")
game.tick = 31; tasks.on_tick()
local terminal = tasks.plan_status({ plan_id = queued.plan_id })
check(terminal.status == "completed" and terminal.completed_steps == 1
  and terminal.outcomes[1].status == "completed"
  and terminal.outcomes[1].result:match("output has 2 iron%-plate") ~= nil,
  "real wait path preserves inventory item count and completes on a later tick")

-- A parked read-only wait keeps its own deadline even when the sole physical
-- lane stays occupied. Expiry updates only the queued plan record: it neither
-- re-inspects the target nor stops or replaces the active body action.
storage.tasks = { next_id = 1, records = {}, queue = {}, active = nil }
output_count, inspect_calls, physical_starts, physical_ticks = 0, 0, 0, 0
local expiring = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2,
  inventory = "output", item = "iron-plate", count = 1, timeout_seconds = 1 } } })
game.tick = 1; tasks.on_tick()
local physical = tasks.enqueue({ task = { type = "walk_to", target = { x = 99, y = 99 } } })
local dependent = tasks.queue_plan({ steps = { { action = "walk_to", x = 3, y = 3 } }, after_plan_id = expiring.plan_id })
game.tick = 2; tasks.on_tick()
local active_at_start, walking_at_start, mining_at_start = storage.tasks.active, body.walking_state, body.mining_state
check(storage.tasks.active and storage.tasks.active.id == physical.task_id and body.walking_state.walking,
  "a long physical action owns the sole lane while the read-only wait is parked")
game.tick = 60; tasks.on_tick()
check(tasks.plan_status({ plan_id = expiring.plan_id }).status == "waiting",
  "parked wait remains pending immediately before its original deadline")
game.tick = 61; tasks.on_tick()
local expired = tasks.plan_status({ plan_id = expiring.plan_id })
check(expired.status == "failed" and storage.tasks.records[expiring.plan_id].finished_tick == 61
  and expired.outcomes[1].status == "failed"
  and expired.outcomes[1].error:match("starting 0, current 0, observed delta 0 after 60 ticks") ~= nil,
  "wait parked at tick 1 becomes terminal failed at tick 61")
check(storage.tasks.active and storage.tasks.active.id == physical.task_id
  and storage.tasks.active == active_at_start
  and body.walking_state == walking_at_start and body.mining_state == mining_at_start
  and body.walking_state.walking and physical_starts == 1 and physical_ticks == 3,
  "queued wait expiry leaves the active physical action and body state untouched")
check(inspect_calls == 1,
  "queued wait expiry does not re-inspect its target while another physical task is active")
check(tasks.plan_status({ plan_id = dependent.plan_id }).status == "queued" and tasks.queue_length() == 1,
  "the failed wait's dependent successor stays blocked in the same FIFO lane")

-- Research waits use the same parked read-only queue path, leaving
-- independent physical work runnable while their next check is due.
storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil },
  factory_activity = { epoch_tick = 100, events = {}, events_omitted = 0 } }
technology.researched = false; force.current_research = technology
local research_wait = tasks.queue_plan({ steps = { { action = "wait_for_research",
  technology = "automation", timeout_seconds = 3 } } })
game.tick = 70; tasks.on_tick()
check(tasks.plan_status({ plan_id = research_wait.plan_id }).status == "waiting",
  "wait_for_research parks without occupying the sole body")
local useful_plan = tasks.queue_plan({ steps = { { action = "walk_to", x = 3, y = 3 } } })
game.tick = 71; tasks.on_tick()
check(tasks.plan_status({ plan_id = useful_plan.plan_id }).status == "running",
  "independent physical work runs while research wait is parked")
tasks.cancel({ origin = "stop/supervisor", plan_id = useful_plan.plan_id })
technology.researched = true; game.tick = 100; tasks.on_tick()
local research_done = tasks.plan_status({ plan_id = research_wait.plan_id })
check(research_done.status == "completed" and research_done.outcomes[1].result.code == "RESEARCH_COMPLETED"
  and research_done.outcomes[1].result.technology == "automation",
  "wait_for_research completes with a compact authoritative DTO")

-- A plan that finishes at tick 223 starts the body's idle clock.
storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
game.tick = 222
local finished = tasks.queue_plan({ steps = { { action = "pickup_items", x = 0, y = 0, item = "iron-ore", count = 1 } } })
game.tick = 223; tasks.on_tick()
check(tasks.plan_status({ plan_id = finished.plan_id }).status == "completed", "a short physical plan completes")
game.tick = 400
local idle_queued = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1 } } })
local busy_queued = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1 } } })
check(idle_queued.body_idle_ticks == 400 - 223 and busy_queued.body_idle_ticks == 0,
  "queue_plan reports how long the FIFO sat empty before it, and zero while work is pending")
storage.tasks.queue, storage.tasks.last_finished_tick = {}, 500
game.tick, body.crafting_queue_size = 700, 2
local crafting_queued = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1 } } })
storage.tasks.queue = {}
tasks.on_tick()
body.crafting_queue_size = nil
game.tick = 760
local after_craft = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1 } } })
check(after_craft.body_idle_ticks == 60,
  "idle time after asynchronous hand-crafting counts from when crafting ended, not from the task that queued it")
storage.tasks.queue, storage.tasks.last_finished_tick = {}, nil
local fresh_queued = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1 } } })
check(crafting_queued.body_idle_ticks == 0 and fresh_queued.body_idle_ticks == 0,
  "hand-crafting in progress and a cleared or pre-upgrade clock are not idle time")
tasks.cancel({ origin = "stop/supervisor", all = true })
game.tick = 900
check(tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1 } } }).body_idle_ticks == 0,
  "emergency cancel-all clears the idle clock, so the first plan after it is not blamed")
local emptied = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 2, y = 2, inventory = "output", item = "iron-plate", count = 1 } } })
check(tasks.plan_status({ plan_id = emptied.plan_id }).fifo_empty == false, "a queued plan keeps the FIFO non-empty")
tasks.cancel({ origin = "stop/supervisor", all = true })
check(tasks.plan_status({ plan_id = emptied.plan_id }).fifo_empty == true, "plan_status reports an empty FIFO once nothing is pending")

-- A queued placement carries the underground belt end it asks for into the
-- physical place task; an ordinary placement carries none.
local placed = {}
place_runner.start = function(task) placed[#placed + 1] = task end
body.walking_state = {}
local undergrounds = tasks.queue_plan({ steps = {
  { action = "place_entity", name = "underground-belt", x = 4, y = 0, direction = 4, belt_to_ground_type = "input" },
  { action = "place_entity", name = "underground-belt", x = 4, y = 4, direction = 4, belt_to_ground_type = "output" },
  { action = "place_entity", name = "transport-belt", x = 4, y = 5, direction = 4 },
} })
for tick = 1000, 1010 do game.tick = tick; tasks.on_tick() end
check(tasks.plan_status({ plan_id = undergrounds.plan_id }).status == "completed" and #placed == 3
  and placed[1].belt_to_ground_type == "input" and placed[2].belt_to_ground_type == "output"
  and placed[3].belt_to_ground_type == nil,
  "queued place_entity steps pass belt_to_ground_type through to the place task")
-- An inspect_entities step of 40 positions reads at most 16 a tick.
local same = {}
for i = 1, 40 do same[i] = { x = 2, y = 2 } end
local read40 = tasks.queue_plan({ steps = { { action = "inspect_entities", positions = same } } })
local reads, ticks_reading = {}, 0
for tick = 1100, 1110 do
  game.tick = tick
  local before = inspect_calls
  tasks.on_tick()
  if inspect_calls > before then reads[#reads + 1] = inspect_calls - before end
end
local read_status = tasks.plan_status({ plan_id = read40.plan_id })
check(read_status.status == "completed" and #reads == 3 and reads[1] == 16 and reads[2] == 16 and reads[3] == 8
  and #read_status.outcomes[1].result.entities == 40,
  "an inspect_entities step of 40 positions reads 16, 16 and 8 over three ticks")
-- An inspect_entities step takes as many positions as one inspection reads.
local function positions(n)
  local out = {}
  for i = 1, n do out[i] = { x = i, y = 0 } end
  return out
end
local most_ok = pcall(tasks.queue_plan, { steps = { { action = "inspect_entities", positions = positions(64) } } })
local over_ok, over_err = pcall(tasks.queue_plan, { steps = { { action = "inspect_entities", positions = positions(65) } } })
check(most_ok and not over_ok and tostring(over_err):find("requires 1-64 positions", 1, true),
  "an inspect_entities step takes 1-64 positions")
os.exit(failures == 0 and 0 or 1)
