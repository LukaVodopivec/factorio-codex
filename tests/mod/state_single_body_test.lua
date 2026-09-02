local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local body_record = { entity = { valid = false } }
local queued = { { id = 2, type = "mine" } }
_G.storage = { companion = body_record, tasks = { next_id = 3, records = {}, queue = queued, active = { id = 1, type = "walk_to" } } }

require("scripts.state").init()
check(storage.companion == body_record, "initialization retains one persistent body record")
check(storage.tasks.active.id == 1 and storage.tasks.queue == queued,
  "initialization retains the sole active task and queue")
local task_keys = {}; for key in pairs(storage.tasks) do task_keys[#task_keys + 1] = key end; table.sort(task_keys)
check(table.concat(task_keys, ",") == "active,next_id,queue,records", "task storage has only the fresh single-body shape")

require("scripts.state").init()
check(storage.companion == body_record and storage.tasks.queue == queued, "single-body storage initialization is idempotent")

os.exit(failures == 0 and 0 or 1)
