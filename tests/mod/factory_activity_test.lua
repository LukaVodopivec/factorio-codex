local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.game = { tick = 100 }
_G.storage = {}
local activity = require("scripts.factory_activity")
activity.record("insert", { target = { name = "furnace", type = "furnace", position = { x = 1, y = 2 } },
  transfers = { { item = "ore", inserted = 3 }, { item = "fuel", inserted = 2 } } })
game.tick = 120
activity.record("extract", { target = { name = "furnace", type = "furnace", position = { x = 1, y = 2 } },
  transfers = { { item = "plate", extracted = 3 } } })
activity.record("craft", { transfers = { { item = "plate", extracted = 99 } } })
local snapshot = activity.snapshot(100)
check(snapshot.transfer_actions == 2 and snapshot.transferred_items == 8,
  "activity counts only successful queued character transfers")
check(snapshot.inserted_items[1].name == "fuel" and snapshot.inserted_items[2].name == "ore"
  and snapshot.extracted_items[1].name == "plate", "activity item rows are deterministic")
check(snapshot.events[1].target.position.x == 1 and snapshot.history_complete,
  "activity retains bounded target identity and run-local completeness")

for i = 1, 129 do
  game.tick = 200 + i
  activity.record("insert", { target = { name = "chest", type = "container", position = { x = i, y = 0 } },
    transfers = { { item = "ore", inserted = 1 } } })
end
local capped = activity.snapshot(100)
check(#capped.events == 16 and capped.events_omitted_in_window > 0 and capped.events_omitted_before_window > 0
  and not capped.history_complete and #capped.target_actions == 64 and capped.target_actions_omitted > 0,
  "activity history is capped and reports omissions instead of pretending completeness")
os.exit(failures == 0 and 0 or 1)
