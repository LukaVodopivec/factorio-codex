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
local function runner() return { start = function() end, tick = function() return { status = "done" } end } end
local physical_starts, physical_ticks = 0, 0
local physical_runner = {
  start = function() physical_starts = physical_starts + 1; body.walking_state = { walking = true } end,
  tick = function() physical_ticks = physical_ticks + 1 end,
}
package.loaded["scripts.actions.walk"], package.loaded["scripts.actions.mine"], package.loaded["scripts.actions.craft"] = physical_runner, runner(), runner()
local place_runner = runner()
package.loaded["scripts.actions.build"] = { place = place_runner, rotate = runner(), set_recipe = runner() }
package.loaded["scripts.actions.transfer"] = { insert = runner(), extract = runner() }
package.loaded["scripts.actions.build_plan"] = runner()
local component_sample_count, component_ready, component_transfers, sampled_since = 0, true, 0, {}
local source_only = false
package.loaded["scripts.map_summary"] = { factory_component_sample = function(params)
  component_sample_count = component_sample_count + 1
  sampled_since[#sampled_since + 1] = params.source_tick
  return { tick = game.tick, source_tick = params.source_tick, component_id = "component-1",
    component_signature = "source:0:0|processor:1:0|sink:2:0", selected_node_ids = { "node-1" },
    products_finished_total = source_only and 0 or 9 + component_sample_count,
    _signature = "exact", _production = source_only and {} or { processor = 9 + component_sample_count },
    _source_production = { source = { working = true, progress = 1 - component_sample_count / 10, remaining = 100 - component_sample_count, resource_key = "ore" } },
    _downstream = { sink = { kind = "consumer", accepting = true, products = { ["item:plate"] = true } } }, downstream_kind = "consumer", blocked_output = false,
    character_transfer_actions = component_transfers, character_history_complete = true,
    topology_ready = component_ready, blockers = component_ready and {} or { "material_input_provenance_unresolved:item:ore" },
    graph_omissions = { nodes = 20, edges = 30, diagnostics = 40 }, exact_remote_inventories = false,
  }
end }
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

-- Research and component validation use the same parked read-only queue path,
-- leaving independent physical work runnable while their next sample is due.
storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil },
  factory_activity = { epoch_tick = 100, events = {}, events_omitted = 0, validations = {}, validations_omitted = 0 } }
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
tasks.cancel({ plan_id = useful_plan.plan_id })
technology.researched = true; game.tick = 100; tasks.on_tick()
local research_done = tasks.plan_status({ plan_id = research_wait.plan_id })
check(research_done.status == "completed" and research_done.outcomes[1].result.code == "RESEARCH_COMPLETED"
  and research_done.outcomes[1].result.technology == "automation",
  "wait_for_research completes with a compact authoritative DTO")

storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil },
  factory_activity = { epoch_tick = 100, events = {}, events_omitted = 0, validations = {}, validations_omitted = 0 } }
component_sample_count, component_ready = 0, true
local validation = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 100,
  positions = { { x = 0, y = 0 }, { x = 2, y = 0 } }, duration_seconds = 1 } } })
game.tick = 101; tasks.on_tick()
check(tasks.plan_status({ plan_id = validation.plan_id }).status == "waiting",
  "factory validation parks between bounded charted counter samples")
game.tick = 121; tasks.on_tick(); game.tick = 141; tasks.on_tick()
game.tick = 160; tasks.on_tick()
check(tasks.plan_status({ plan_id = validation.plan_id }).status == "waiting",
  "factory validation remains pending until its full requested interval")
game.tick = 161; tasks.on_tick()
local validation_done = tasks.plan_status({ plan_id = validation.plan_id })
check(validation_done.status == "completed" and validation_done.outcomes[1].result.proven
  and validation_done.outcomes[1].result.products_finished_delta == 3
  and validation_done.outcomes[1].result.character_transfer_actions == 0
  and validation_done.outcomes[1].result.exact_remote_inventories == false,
  "consumer validation proves several cycles despite serialization omissions, without remote inventory access")
check(sampled_since[1] == 101 and sampled_since[#sampled_since] == 101
  and validation_done.outcomes[1].result.source_tick == 100
  and validation_done.outcomes[1].result.transfer_window_start_tick == 101,
  "the transfer window opens when validation starts, so earlier bootstrap insertions are historical debt")
local activity = require("scripts.factory_activity").snapshot(100)
check(#activity.validations == 1 and activity.validations[1].component_signature == validation_done.outcomes[1].result.component_signature,
  "successful validation is retained in the existing bounded activity evidence")

source_only, component_sample_count = true, 0
storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
local source_validation = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 161,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
for _, tick in ipairs({ 162, 182, 202, 222 }) do game.tick = tick; tasks.on_tick() end
local source_done = tasks.plan_status({ plan_id = source_validation.plan_id })
check(source_done.status == "completed" and source_done.outcomes[1].result.products_finished_delta == 0
  and source_done.outcomes[1].result.source_cycles_observed == 3,
  "source-only parked proof requires source cycles and acceptance without processor counters")
check(#storage.factory_activity.validations == 1 and storage.factory_activity.validations[1].products_finished_delta == 0,
  "existing validation recorder retains source-only proof with zero crafting production")
source_only = false
game.tick = 161

storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
component_sample_count, component_ready = 0, false
local rejected = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 161,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
game.tick = 162; tasks.on_tick(); game.tick = 222; tasks.on_tick()
local rejected_status = tasks.plan_status({ plan_id = rejected.plan_id })
check(rejected_status.status == "failed" and rejected_status.outcomes[1].result.proven == false
  and rejected_status.outcomes[1].result.blockers[1].reason:match("material_input_provenance_unresolved"),
  "unproven material provenance fails with its structured diagnostic instead of advancing successors")
check(rejected_status.outcomes[1].result.blockers[1].class == "structural"
  and rejected_status.outcomes[1].result.stage == "preflight" and rejected_status.outcomes[1].result.refused == nil,
  "bare blocker names from an older sample shape are wrapped as structural preflight rows")

storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
component_sample_count, component_ready, component_transfers = 0, false, 2
local fed = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 222,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
game.tick = 223; tasks.on_tick()
local fed_blockers = {}
for _, blocker in ipairs(tasks.plan_status({ plan_id = fed.plan_id }).outcomes[1].result.blockers) do fed_blockers[blocker.reason] = true end
check(fed_blockers.character_transfer_observed, "a preflight refused for character transfers names that blocker")
game.tick = 400
local idle_queued = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 400,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
local busy_queued = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 400,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
check(idle_queued.body_idle_ticks == 400 - 223 and busy_queued.body_idle_ticks == 0,
  "queue_plan reports how long the FIFO sat empty before it, and zero while work is pending")
storage.tasks.queue, storage.tasks.last_finished_tick = {}, 500
game.tick, body.crafting_queue_size = 700, 2
local crafting_queued = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 700,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
storage.tasks.queue = {}
tasks.on_tick()
body.crafting_queue_size = nil
game.tick = 760
local after_craft = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 760,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
check(after_craft.body_idle_ticks == 60,
  "idle time after asynchronous hand-crafting counts from when crafting ended, not from the task that queued it")
storage.tasks.queue, storage.tasks.last_finished_tick = {}, nil
local fresh_queued = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 700,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
check(crafting_queued.body_idle_ticks == 0 and fresh_queued.body_idle_ticks == 0,
  "hand-crafting in progress and a cleared or pre-upgrade clock are not idle time")
tasks.cancel({ all = true })
game.tick = 900
check(tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 900,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } }).body_idle_ticks == 0,
  "emergency cancel-all clears the idle clock, so the first plan after it is not blamed")
local emptied = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 900,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
check(tasks.plan_status({ plan_id = emptied.plan_id }).fifo_empty == false, "a queued plan keeps the FIFO non-empty")
tasks.cancel({ all = true })
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
os.exit(failures == 0 and 0 or 1)
