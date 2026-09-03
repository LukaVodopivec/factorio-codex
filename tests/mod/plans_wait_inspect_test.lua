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
package.loaded["scripts.actions.build"] = { place = runner(), rotate = runner(), set_recipe = runner() }
package.loaded["scripts.actions.transfer"] = { insert = runner(), extract = runner() }
package.loaded["scripts.actions.build_plan"] = runner()
local component_sample_count, component_ready = 0, true
package.loaded["scripts.map_summary"] = { factory_component_sample = function(params)
  component_sample_count = component_sample_count + 1
  return { tick = game.tick, source_tick = params.source_tick, component_id = "component-1",
    component_signature = "source:0:0|processor:1:0|sink:2:0", selected_node_ids = { "node-1" },
    products_finished_total = component_sample_count == 1 and 10 or 12,
    character_transfer_actions = 0, character_history_complete = true,
    topology_ready = component_ready, blockers = component_ready and {} or { "material_input_provenance_unresolved:item:ore" },
    graph_omissions = { nodes = 0, edges = 0, diagnostics = 0 }, exact_remote_inventories = false,
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
game.tick = 160; tasks.on_tick()
check(tasks.plan_status({ plan_id = validation.plan_id }).status == "waiting",
  "factory validation does not sample before its requested interval")
game.tick = 161; tasks.on_tick()
local validation_done = tasks.plan_status({ plan_id = validation.plan_id })
check(validation_done.status == "completed" and validation_done.outcomes[1].result.proven
  and validation_done.outcomes[1].result.products_finished_delta == 2
  and validation_done.outcomes[1].result.character_transfer_actions == 0
  and validation_done.outcomes[1].result.exact_remote_inventories == false,
  "factory validation proves bounded production without remote inventory access")
local activity = require("scripts.factory_activity").snapshot(100)
check(#activity.validations == 1 and activity.validations[1].component_signature == validation_done.outcomes[1].result.component_signature,
  "successful validation is retained in the existing bounded activity evidence")

storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
component_sample_count, component_ready = 0, false
local rejected = tasks.queue_plan({ steps = { { action = "validate_factory_component", source_tick = 161,
  positions = { { x = 0, y = 0 } }, duration_seconds = 1 } } })
game.tick = 162; tasks.on_tick(); game.tick = 222; tasks.on_tick()
local rejected_status = tasks.plan_status({ plan_id = rejected.plan_id })
check(rejected_status.status == "failed" and rejected_status.outcomes[1].result.proven == false
  and rejected_status.outcomes[1].result.blockers[1].reason:match("material_input_provenance_unresolved"),
  "unproven material provenance fails with its structured diagnostic instead of advancing successors")
os.exit(failures == 0 and 0 or 1)
