local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local body_record = { entity = { valid = false }, unit_number = 17 }
local queued = { { id = 2, type = "mine" } }
_G.storage = {
  tasks = {
    next_id = 3,
    records = {},
    failed_chains = {},
    by_companion = { Codex = { queue = queued, active = { id = 1, type = "walk_to" } } },
  },
  companions = { Codex = body_record },
}

require("scripts.state").init()
check(storage.companion == body_record and storage.companions == nil,
  "released named body record migrates to one persistent body")
check(storage.tasks.lane.active.id == 1 and storage.tasks.lane.queue == queued,
  "released named task lane migrates without losing active or queued work")
check(storage.tasks.by_companion == nil and storage.tasks.queue == nil and storage.tasks.active == nil,
  "named and legacy task storage paths are removed after migration")

require("scripts.state").init()
check(storage.companion == body_record and storage.tasks.lane.queue == queued,
  "single-body storage initialization is idempotent")

os.exit(failures == 0 and 0 or 1)
