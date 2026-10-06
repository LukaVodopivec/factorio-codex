package.path = "mod/agentic-companion/?.lua;" .. package.path
local calls, values, consumed, hand, held = 0, {}, {}, {}, false
local body = { state = "on_surface", surface_ref = "nauvis", character = { crafting_queue_size = 0 }, force = { get_item_production_statistics = function(surface)
  assert(surface == "nauvis")
  return { get_input_count = function(name) calls = calls + 1; return values[name] or 0 end,
    get_output_count = function(name) calls = calls + 1; return consumed[name] or 0 end }
end } }
package.loaded["scripts.companion"] = { require_present = function() return body end,
  human_control = function() return held end }
local refreshes = 0
package.loaded["scripts.thoughts"] = { refresh = function() refreshes = refreshes + 1 end }
game = { tick = 100, speed = 1, get_surface = function(name) return name end }
storage = { tasks = { queue = {} }, factory_activity = { hand_crafted = hand } }
local b = require("scripts.benchmark")
b.on_freeze = function() refreshes = refreshes + 1 end
local function rejects(fn, message)
  local ok, err = pcall(fn); assert(not ok and tostring(err):find(message, 1, true), tostring(err))
end
storage.tasks.queue = { {} }
rejects(function() b.control({ action = "prepare", run_id = "test" }) end, "empty physical queue")
assert(storage.benchmark == nil and game.tick_paused == nil)
storage.tasks.queue = {}; body.character.crafting_queue_size = 1
rejects(function() b.control({ action = "prepare", run_id = "test" }) end, "no character crafting")
body.character.crafting_queue_size = 0
values["iron-ore"] = 10
b.control({ action = "prepare", run_id = "test", duration_seconds = 10, label = "test profile" })
assert(game.tick_paused and b.display().remaining_seconds == 10)
for _, method in ipairs({"queue_plan", "enqueue", "start_research", "blueprint_capture"}) do
  rejects(function() b.assert_action(method) end, "BENCHMARK_CLOSED")
end
b.assert_action("run_snapshot")
rejects(function() b.control({ action = "begin", run_id = "wrong" }) end, "identity differs")
b.control({ action = "begin", run_id = "test" })
assert(not game.tick_paused and storage.benchmark.deadline_tick == 700)
b.assert_action("queue_plan")
rejects(function() b.control({ action = "begin", run_id = "test" }) end, "released twice")
values["iron-ore"] = 47; values["iron-plate"] = 25; values["iron-gear-wheel"] = 12; hand["iron-gear-wheel"] = 5
values["automation-science-pack"] = 6; hand["automation-science-pack"] = 2; consumed["automation-science-pack"] = 4
held = true; game.tick = 699
assert(not b.on_tick(game.tick) and storage.benchmark.assisted)
game.tick = 700; calls = 0
assert(b.on_tick(game.tick) and game.tick_paused and calls == 13 and refreshes == 1)
assert(storage.benchmark.metrics["iron-ore"] == 37 and storage.benchmark.metrics["iron-plate"] == 25)
-- Hand-crafts never score: 7 machine gears and 4 packs, of which labs consumed
-- 4 but 2 were hand-made, so research is 2.
local shown = b.display()
assert(shown.research == 2 and shown.made == 25 + 7 + 4 and shown.raw == 37, shown.research .. " " .. shown.made)
assert(storage.benchmark.freeze_reason == "tick_deadline" and storage.benchmark.frozen_tick == 700)
values["iron-ore"] = 90; game.tick = 710
b.control({ action = "freeze", run_id = "test" })
assert(storage.benchmark.metrics["iron-ore"] == 37 and storage.benchmark.frozen_tick == 700)
rejects(function() b.assert_action("queue_plan") end, "BENCHMARK_CLOSED")
rejects(function() b.control({ action = "prepare", run_id = "next" }) end, "fresh save")
storage.benchmark = nil
b.control({ action = "prepare", run_id = "cancelled", duration_seconds = 10 })
b.control({ action = "freeze", run_id = "cancelled" })
assert(game.tick_paused and b.display().remaining_seconds == 0 and b.display().made_per_minute == 0)
-- A save frozen by an older release keeps only its old counters: still shown.
storage.benchmark.metrics = { ["iron-ore"] = 3, ["copper-ore"] = 0, coal = 0, stone = 0, ["iron-plate"] = 2, ["copper-plate"] = 0 }
local old = b.display()
assert(old.research == 0 and old.made == 2 and old.raw == 3)
print("ok benchmark preparation, admission, native cutoff, automation score without hand-crafts, bounded statistics and idempotent freeze")
