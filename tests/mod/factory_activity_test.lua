local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.game = { tick = 100 }
_G.storage = {}
local transfers_seen = {}
package.loaded["scripts.autonomy"] = { on_transfer = function(position, kind)
  transfers_seen[#transfers_seen + 1] = { position = position, kind = kind }
end }
local activity = require("scripts.factory_activity")
activity.record("insert", { target = { name = "furnace", type = "furnace", position = { x = 1, y = 2 } },
  transfers = { { item = "ore", inserted = 3 }, { item = "fuel", inserted = 2 } } })
game.tick = 120
activity.record("extract", { target = { name = "furnace", type = "furnace", position = { x = 1, y = 2 } },
  transfers = { { item = "plate", extracted = 3 } } })
activity.record("craft", { transfers = { { item = "plate", extracted = 99 } } })
activity.record("build_plan", { transfers = { { item = "ore", inserted = 99 } } })
activity.record("insert", { transfers = { { item = "ore", inserted = 0 } } })
local snapshot = activity.snapshot(100)
check(#transfers_seen == 2 and transfers_seen[1].position.x == 1 and transfers_seen[1].position.y == 2
  and transfers_seen[1].kind == "insert" and transfers_seen[2].kind == "extract",
  "each successful character transfer with a target reaches the factory lines with its kind (insert or extract)")
check(snapshot.validations == nil and storage.factory_activity.validations == nil,
  "activity keeps no component proofs")
check(snapshot.transfer_actions == 2 and snapshot.transferred_items == 8,
  "activity counts only successful queued character transfers")
check(snapshot.inserted_items[1].name == "fuel" and snapshot.inserted_items[2].name == "ore"
  and snapshot.extracted_items[1].name == "plate", "activity item rows are deterministic")
check(snapshot.events[1].target.position.x == 1 and snapshot.target_actions[1].last_transfer_tick == 120
  and snapshot.history_complete,
  "activity retains bounded target identity and run-local completeness")

for i = 1, 129 do
  game.tick = 200 + i
  activity.record("insert", { target = { name = "chest", type = "container", position = { x = i, y = 0 } },
    transfers = { { item = "ore", inserted = 1 } } })
end
local capped = activity.snapshot(100)
check(#capped.events == 8 and capped.events_omitted_in_window > 0 and capped.events_omitted_before_window > 0
  and not capped.history_complete and #capped.target_actions == 16 and capped.target_actions_omitted > 0,
  "activity history is capped and reports omissions instead of pretending completeness")
local internal = activity.snapshot(100, true)
check(#internal.events == 128 and #internal.target_actions == 128
  and internal.events[1].action == "insert" and internal.events[1].items[1].name == "ore",
  "internal attribution retains action and items beyond both public presentation caps")
storage = {}; game.tick = 500
activity.record("insert", { target = { name = "selected", type = "furnace", position = { x = 0, y = 0 } },
  transfers = { { item = "ore", inserted = 1 } } })
for i = 1, 128 do
  activity.record("insert", { target = { name = "other", type = "container", position = { x = i, y = 0 } },
    transfers = { { item = "ore", inserted = 1 } } })
end
check(not activity.snapshot(500, true).history_complete and activity.snapshot(500, true).events_omitted_before_window == 1,
  "eviction of a same-tick transfer keeps the selected interval's history incomplete")
game.tick = 501
check(activity.snapshot(501, true).history_complete,
  "a later interval beyond the latest evicted tick remains complete")
os.exit(failures == 0 and 0 or 1)
