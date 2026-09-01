local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local body_record = { entity = { valid = false } }
local queued = { { id = 2, type = "mine" } }
_G.storage = { companion = body_record, tasks = { next_id = 3, records = {}, failed_chains = {}, lane = { queue = queued, active = { id = 1, type = "walk_to" } } } }

require("scripts.state").init()
check(storage.companion == body_record, "initialization retains one persistent body record")
check(storage.tasks.lane.active.id == 1 and storage.tasks.lane.queue == queued,
  "initialization retains the one active task lane")

require("scripts.state").init()
check(storage.companion == body_record and storage.tasks.lane.queue == queued, "single-body storage initialization is idempotent")

os.exit(failures == 0 and 0 or 1)
