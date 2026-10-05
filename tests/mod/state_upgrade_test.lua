-- A 0.21.0 save upgraded in place: state.init adds the 0.21.1 storage
-- (the patch cache's charted chunk list, the jobs table) and keeps what the
-- live run holds (plans, the patch cache's chunks).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local created_inventories = {}
_G.game = { tick = 500000, create_inventory = function(size)
  local inventory = setmetatable({ valid = true, size = size }, { __len = function(self) return self.size end })
  created_inventories[#created_inventories + 1] = inventory
  return inventory
end }
local active = { id = 243, type = "plan", steps = { { action = "walk_to" } }, source = "pilot" }
local cached_chunk = { cx = 1, cy = 0, cells = { ["iron-ore"] = { cx = 1, cy = 0, amount = 900, tiles = 9 } } }
-- What 0.21.0 kept.
_G.storage = {
  tasks = { next_id = 300, records = { [243] = active }, queue = { { id = 244, type = "plan" } }, active = active,
    -- The owner held the body when the save was made.
    human_hold = { since = 499000 } },
  patch_cache = { version = 1, seeded = true, filled = true,
    chunks = { ["1,0"] = cached_chunk }, known = { ["0,0"] = true, ["1,0"] = true, ["-1,-2"] = true },
    pending = { { x = 3, y = 4 } }, head = 1, queued = { ["3,4"] = true }, refresh = {}, dirty = false },
  chores = { refueled = { [17] = 499000 } },
  autonomy = { version = 1, lines = { [1] = { id = 1, product = "iron-plate" } }, line_order = { 1 }, transfer_tick = {} },
  activity_log = { { plan_id = 242, source = "pilot", status = "completed", start_tick = 1, end_tick = 2 } },
}
local state = require("scripts.state")
state.init()

local cache = storage.patch_cache
local listed = {}
for _, chunk in ipairs(cache.charted) do listed[#listed + 1] = chunk.x .. "," .. chunk.y end
check(table.concat(listed, " ") == "-1,-2 0,0 1,0 3,4" and cache.charted_set["3,4"] and cache.charted_set["-1,-2"],
  "the charted chunk list is built from the known and queued chunks, in (y, x) order")
check(cache.chunks["1,0"] == cached_chunk and cache.filled and cache.seeded,
  "the patch cache keeps its chunks: nothing is read again")
check(storage.tasks.active == active and #storage.tasks.queue == 1 and storage.tasks.next_id == 300,
  "in-flight plans survive the upgrade")
check(storage.tasks.human_hold and storage.tasks.human_hold.since == 499000,
  "a hold in progress survives the upgrade, so its ticks are credited when it ends")
check(type(storage.jobs) == "table" and storage.jobs.next_id == 1 and #storage.jobs.order == 0,
  "the jobs table is created")
check(storage.chores.refueled[17] == 499000 and type(storage.chores.fed_labs) == "table"
  and storage.tasks.last_cancel_all_tick == nil and storage.last_research_finished == nil,
  "upkeep keeps its refuel record and gains the lab record; no stop or research is invented")
check(storage.autonomy.lines[1].product == "iron-plate" and #storage.activity_log == 1,
  "the factory lines and the activity log are kept")
local blueprint_inventory = storage.blueprints and storage.blueprints.inventory
check(#created_inventories == 1 and blueprint_inventory == created_inventories[1] and #blueprint_inventory == state.BLUEPRINT_SLOTS
  and next(storage.blueprints.by_name) == nil,
  "the blueprint inventory is created once, empty, with every slot")

-- A newly charted chunk joins the list once.
package.loaded["scripts.companion"] = { get = function()
  return { valid = true, force = { name = "player" }, surface = { index = 1 } }
end }
local map_summary = require("scripts.map_summary")
map_summary.on_chunk_charted({ position = { x = 7, y = 7 }, force = { name = "player" }, surface_index = 1 })
map_summary.on_chunk_charted({ position = { x = 0, y = 0 }, force = { name = "player" }, surface_index = 1 })
check(#cache.charted == 5 and cache.charted[5].x == 7 and cache.charted_set["7,7"],
  "a chunk charted later is appended once; a known one is not listed again")

check(type(storage.space) == "table" and next(storage.space.created) == nil and #storage.space.events == 0,
  "the space platform store and event ring are created")
check(type(storage.world_policy) == "table" and #storage.world_policy.errors == 0,
  "the world policy's error list is created")
storage.space.created[3] = "nauvis"
storage.space.events[1] = { tick = 1, kind = "rocket_ready" }
storage.world_policy.errors[1] = { tick = 2, surface = "nauvis", write = "peaceful_mode", error = "x" }

-- Calling init again (a later configuration change) leaves the list alone.
storage.blueprints.by_name.smelter = { slot = 1 }
storage.jobs.next_id = 9
state.init()
check(#storage.patch_cache.charted == 5, "state.init keeps an existing charted list")
check(#created_inventories == 1 and storage.blueprints.inventory == blueprint_inventory
  and storage.blueprints.by_name.smelter ~= nil and storage.jobs.next_id == 9,
  "a later configuration change keeps the blueprints and never reuses a job id")
check(storage.space.created[3] == "nauvis" and #storage.space.events == 1,
  "a later configuration change keeps the platforms' planets and the event ring")
check(#storage.world_policy.errors == 1, "a later configuration change keeps the world policy's errors")

print(failures == 0 and "\nALL STATE UPGRADE TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
