local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local body_record = { entity = { valid = false } }
_G.storage = { companion = body_record }

require("scripts.state").init()
check(storage.companion == body_record, "initialization retains one persistent body record")
check(storage.tasks.lane.next_id == 1 and #storage.tasks.lane.queue == 0
  and storage.tasks.lane.active == nil,
  "initialization creates the fresh single task lane")
local task_keys = {}; for key in pairs(storage.tasks) do task_keys[#task_keys + 1] = key end; table.sort(task_keys)
check(table.concat(task_keys, ",") == "lane", "task storage exposes only the sole fresh lane")
check(storage.path_request == nil and storage.path_requests == nil,
  "path routing has one optional request slot rather than per-body maps")

local lane = storage.tasks.lane
lane.active = { id = 1, type = "walk_to" }
lane.queue[1] = { id = 2, type = "mine" }
require("scripts.state").init()
check(storage.companion == body_record and storage.tasks.lane == lane
  and storage.tasks.lane.active.id == 1 and storage.tasks.lane.queue[1].id == 2,
  "fresh single-lane initialization is idempotent")

os.exit(failures == 0 and 0 or 1)
