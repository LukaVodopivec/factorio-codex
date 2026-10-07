-- Every approach walk ends, and no step holds the FIFO for minutes. Offline:
-- the real dispatcher, walker, approach, insert, build plan and build layout
-- over a small physical world. The body moves only through walking_state, at
-- 0.15 tiles a tick, where the world lets it. Water fills the rows y >= 0;
-- like the game's tile transitions, the world lets the body's centre stand
-- up to 0.45 tiles into a water tile, where the start check reads "blocked".
-- That the native game moves and collides this way is live evidence.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

_G.defines = {
  direction = { north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14 },
  build_check_type = { manual = 1, ghost_revive = 2 },
  inventory = { chest = 1 },
  events = setmetatable({}, { __index = function(_, key) return key end }),
}
local function box(half) return { left_top = { x = -half, y = -half }, right_bottom = { x = half, y = half } } end
local solid = { layers = { player = true, object = true } }
local chest_proto = { name = "wooden-chest", type = "container", tile_width = 1, tile_height = 1,
  collision_box = box(0.35), collision_mask = solid }
_G.prototypes = {
  entity = {
    character = { name = "character", collision_box = box(0.2),
      collision_mask = { layers = { player = true }, consider_tile_transitions = true } },
    ["wooden-chest"] = chest_proto,
  },
  item = { coal = { name = "coal", stack_size = 50 },
    ["wooden-chest"] = { name = "wooden-chest", stack_size = 50, place_result = chest_proto } },
  tile = {},
}

-- ------------------------------------------------------------------ world
local SPEED, MARGIN = 0.15, 0.45
local VECTORS = { [0] = { 0, -1 }, [2] = { 1, -1 }, [4] = { 1, 0 }, [6] = { 1, 1 }, [8] = { 0, 1 },
  [10] = { -1, 1 }, [12] = { -1, 0 }, [14] = { -1, -1 } }
local entities, inventory = {}, {}
local pinned = false                 -- the world refuses every movement
local wall = function() return false end -- positions the world refuses, unseen by any evidence
local held = false                   -- the owner holds the body
local path_requests = 0
local function water(_, y) return y >= 0 end
local function overlaps(a, b)
  return a.left_top.x < b.right_bottom.x and a.right_bottom.x > b.left_top.x
    and a.left_top.y < b.right_bottom.y and a.right_bottom.y > b.left_top.y
end
local function listed(filter, value)
  if filter == nil then return true end
  if type(filter) == "string" then return filter == value end
  for _, v in ipairs(filter) do if v == value then return true end end
  return false
end
local body
local surface = {
  name = "nauvis",
  request_path = function(request)
    path_requests = path_requests + 1
    surface_request = { id = path_requests, start = { x = request.start.x, y = request.start.y },
      goal = { x = request.goal.x, y = request.goal.y } }
    return path_requests
  end,
  get_tile = function(x, y)
    local wet = water(math.floor(x), math.floor(y))
    return { name = wet and "water" or "grass", collides_with = function(layer) return layer == "player" and wet end }
  end,
  find_entities_filtered = function(filter)
    local out = {}
    for _, e in ipairs(entities) do
      local ok = e.valid and listed(filter.type, e.type) and listed(filter.name, e.name)
      if ok and filter.area then ok = overlaps(filter.area, e.bounding_box) end
      if ok and filter.position then
        local dx, dy = e.position.x - filter.position.x, e.position.y - filter.position.y
        ok = dx * dx + dy * dy <= (filter.radius or 0) ^ 2
      end
      if ok then out[#out + 1] = e end
      if filter.limit and #out >= filter.limit then break end
    end
    return out
  end,
  find_tiles_filtered = function() return {} end,
  find_non_colliding_position = function(_, goal) return { x = goal.x, y = goal.y } end,
  can_place_entity = function() return true end,
  create_entity = function(args)
    local e = { valid = true, name = args.name, type = "container", force = body.force,
      position = { x = args.position.x, y = args.position.y }, prototype = chest_proto,
      bounding_box = { left_top = { x = args.position.x - 0.35, y = args.position.y - 0.35 },
        right_bottom = { x = args.position.x + 0.35, y = args.position.y + 0.35 } } }
    entities[#entities + 1] = e
    return e
  end,
}
local function count_of(name) return inventory[type(name) == "table" and name.name or name] or 0 end
body = {
  valid = true, name = "character", position = { x = 0.5, y = -0.5 }, walking_state = {}, mining_state = {},
  picking_state = false, surface = surface, reach_distance = 6, build_distance = 6,
  crafting_queue = {}, crafting_queue_size = 0, crafting_queue_progress = 0, character_mining_progress = 0,
  force = { recipes = {}, is_chunk_charted = function() return true end },
  get_item_count = count_of,
  remove_item = function(stack)
    local n = math.min(stack.count, count_of(stack.name))
    inventory[stack.name] = count_of(stack.name) - n
    return n
  end,
  get_main_inventory = function()
    return {
      get_contents = function()
        local out = {}
        for name, count in pairs(inventory) do if count > 0 then out[#out + 1] = { name = name, count = count } end end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
      end,
      get_insertable_count = function() return 1000 end,
      get_item_count = count_of,
    }
  end,
  cancel_crafting = function() end,
}
body.can_reach_entity = function(e)
  local dx, dy = e.position.x - body.position.x, e.position.y - body.position.y
  return dx * dx + dy * dy <= body.reach_distance ^ 2
end
local function furnace(x, y)
  local e = { valid = true, name = "stone-furnace", type = "furnace", force = body.force, position = { x = x, y = y },
    prototype = { collision_mask = solid }, inserted = 0,
    bounding_box = { left_top = { x = x - 0.8, y = y - 0.8 }, right_bottom = { x = x + 0.8, y = y + 0.8 } } }
  e.insert = function(stack) e.inserted = e.inserted + stack.count; return stack.count end
  return e
end

package.loaded["scripts.companion"] = {
  get = function() return body end, require_companion = function() return body end,
  -- Any body state but absent (remote actions, reads, queue_plan); no surface tag.
  require_present = function() return { state = "on_surface", force = body.force, surface = body.surface } end,
  anchor = function() return nil end,
  human_control = function() return held, held and 0 or 100000 end,
  poll_human_activity = function() end,
}
package.loaded["scripts.factory_activity"] = { record = function() end }
package.loaded["scripts.autonomy"] = { mark_dirty = function() end, on_body_time = function() end, producing = function() return 0 end }
package.loaded["scripts.registry"] = { add = function() end, machines = function() return {} end,
  stock_totals = function() return {} end, holders_with = function() return {} end }
local inspect_count = 0
package.loaded["scripts.inspect"] = { MAX_TARGETS = 64, PER_TARGET = 40,
  inspect = function() inspect_count = inspect_count + 1
    return { entities = { { inventories = { output = { coal = 0 } } } } } end }

local walk = require("scripts.actions.walk")
local approach = require("scripts.actions.approach")
local tasks = require("scripts.tasks")

-- The body's physics: one walking_state step a tick, refused by the world
-- where it says so. The pathfinder answers the tick after a request with a
-- route that hugs the shore on the water margin, as the native one does.
local shore_route = true
local detour -- waypoints the pathfinder puts before the goal instead
local function physics()
  local state = body.walking_state
  if not (state and state.walking) or pinned then return end
  local v = VECTORS[state.direction]
  local scale = (v[1] ~= 0 and v[2] ~= 0) and SPEED / math.sqrt(2) or SPEED
  local to = { x = body.position.x + v[1] * scale, y = body.position.y + v[2] * scale }
  if to.y > MARGIN or wall(to) then return end
  body.position = to
end
local function answer_path()
  local request = surface_request
  if not request or not storage.path_request or storage.path_request.id ~= request.id then return end
  surface_request = nil
  local path = {}
  if detour then
    for _, p in ipairs(detour) do path[#path + 1] = { position = { x = p.x, y = p.y } } end
  elseif shore_route then
    local x = request.start.x + 1
    while x < request.goal.x do
      path[#path + 1] = { position = { x = x, y = 0.4 } }
      x = x + 1
    end
  end
  path[#path + 1] = { position = { x = request.goal.x, y = request.goal.y } }
  walk.on_path_finished({ id = request.id, path = path })
end
local function reset(x, y)
  entities, inventory, pinned, held, path_requests, surface_request = {}, {}, false, false, 0, nil
  wall, shore_route, detour = function() return false end, true, nil
  body.position, body.walking_state, body.mining_state = { x = x, y = y }, {}, {}
  body.crafting_queue, body.crafting_queue_size, body.crafting_queue_progress = {}, 0, 0
  _G.game = { tick = 0 }
  _G.storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
end
local function tick()
  game.tick = game.tick + 1
  answer_path()
  tasks.on_tick()
  physics()
end
-- Runs until the plan leaves the FIFO or `limit` ticks passed; the ticks run.
local function run(id, limit)
  local start = game.tick
  while game.tick - start < limit do
    tick()
    local record = storage.tasks.records[id]
    if record then return record, game.tick - start end
  end
  return nil, limit
end
local function last_outcome(record) return record.plan.outcomes[#record.plan.outcomes] end

-- ------------------------------------------- shoreline start: insert_items
-- The body stands on the water margin (a start the check reads as blocked);
-- the machine is 20 tiles along the shore and every native route to it runs
-- along the margin. 0.22.0 escaped, walked back onto the margin, renewed its
-- escape allowance and repeated that until the plan budget.
reset(0.5, 0.1)
local machine = furnace(20.5, -2.5)
entities = { machine }
inventory = { coal = 5 }
local plan = tasks.queue_plan({ steps = { { action = "insert_items", x = 20.5, y = -2.5, items = { coal = 5 },
  auto_supply = false } } }).plan_id
tick()
check(storage.tasks.active and storage.tasks.active.current_task._approach.walk.phase == "escaping"
  and body.walking_state.walking and body.walking_state.direction == defines.direction.north,
  "a start on the water margin first walks to the nearest dry tile centre")
local record, took = run(plan, 1200)
check(record ~= nil and record.status == "completed" and machine.inserted == 5 and inventory.coal == 0,
  "insert_items from a shoreline start escapes, follows the shore route and inserts")
check(record ~= nil and took < 400 and body.position.y < 0 and path_requests <= 3,
  "the shoreline approach ends in seconds, on dry land, without renewing its path request for ever")

-- ------------------------------------------- shoreline start: build_layout
reset(0.5, 0.1)
inventory = { ["wooden-chest"] = 1 }
plan = tasks.queue_plan({ steps = { { action = "build_layout", anchor = { x = 20, y = -3 },
  entities = { { name = "wooden-chest", dx = 0.5, dy = 0.5 } } } } }).plan_id
record, took = run(plan, 1200)
check(record ~= nil and record.status == "completed" and last_outcome(record).result.code == "LAYOUT_BUILT"
  and #entities == 1 and entities[1].position.x == 20.5 and inventory["wooden-chest"] == 0,
  "build_layout from a shoreline start escapes, walks the shore route and builds")
check(record ~= nil and took < 400, "the build_layout approach ends in seconds")

-- --------------------------------------- an escape tries other directions
-- The dry tile to the north cannot be entered here (a collider no evidence
-- shows); the body tries the next free tile centres in other directions.
reset(0.5, 0.1)
machine = furnace(20.5, -2.5)
entities = { machine }
inventory = { coal = 5 }
wall = function(p) return p.y < 0 and p.x >= 0 and p.x < 1 end
plan = tasks.queue_plan({ steps = { { action = "insert_items", x = 20.5, y = -2.5, items = { coal = 5 },
  auto_supply = false } } }).plan_id
local directions, seen = 0, {}
for _ = 1, 150 do
  tick()
  local active = storage.tasks.active
  local a = active and active.current_task and active.current_task._approach
  if a and a.walk.phase == "escaping" and body.walking_state.walking and not seen[body.walking_state.direction] then
    seen[body.walking_state.direction] = true
    directions = directions + 1
  end
end
record, took = run(plan, 1200)
check(directions >= 3 and record ~= nil and record.status == "completed" and machine.inserted == 5,
  "an escape whose first direction makes no progress tries other directions, then the walk goes on")

-- ------------------------------------------------ an unescapable start
-- A collider pins the body: no direction moves it. The step fails with
-- START_COLLISION in seconds, never by waiting for the plan budget.
local function pin()
  entities[#entities + 1] = { valid = true, name = "solid-fixture", type = "simple-entity",
    position = { x = 0.5, y = -0.5 }, prototype = { collision_mask = solid, mineable_properties = { minable = false } },
    bounding_box = { left_top = { x = 0.2, y = -0.8 }, right_bottom = { x = 0.8, y = -0.2 } } }
  pinned = true
end
reset(0.5, -0.5)
machine = furnace(20.5, -2.5)
entities = { machine }
inventory = { coal = 5 }
pin()
plan = tasks.queue_plan({ steps = { { action = "insert_items", x = 20.5, y = -2.5, items = { coal = 5 },
  auto_supply = false } } }).plan_id
record, took = run(plan, 1200)
local outcome = record and last_outcome(record)
check(record ~= nil and record.status == "failed" and took <= 400 and outcome.action == "insert_items"
  and type(outcome.result) == "table" and outcome.result.code == "START_COLLISION"
  and outcome.error:match("START_COLLISION") and outcome.error:match("no physical progress")
  and machine.inserted == 0 and body.position.x == 0.5 and body.position.y == -0.5,
  "an unescapable start fails insert_items fast with START_COLLISION in the step outcome")
check(outcome and outcome.result.diagnostics and outcome.result.diagnostics.path_start
  and outcome.result.diagnostics.path_start.collisions[1].name == "solid-fixture"
  and #outcome.result.diagnostics.escape_targets >= 2,
  "the START_COLLISION outcome names the collider and the escape cells tried")

reset(0.5, -0.5)
inventory = { ["wooden-chest"] = 2 }
pin()
plan = tasks.queue_plan({ steps = { { action = "build_layout", anchor = { x = 20, y = -3 },
  entities = { { name = "wooden-chest", dx = 0.5, dy = 0.5 }, { name = "wooden-chest", dx = 2.5, dy = 0.5 } } } } }).plan_id
record, took = run(plan, 1200)
outcome = record and last_outcome(record)
check(record ~= nil and record.status == "failed" and took <= 400 and outcome.result.code == "LAYOUT_FAILED"
  and #outcome.result.failed == 2 and outcome.result.failed[1].reason:match("START_COLLISION")
  and outcome.result.failed[2].reason:match("START_COLLISION") and inventory["wooden-chest"] == 2,
  "an unescapable start fails build_layout fast, START_COLLISION in every failed placement")

-- Auto-supply does not walk to one source after another from a start it
-- cannot leave: the first START_COLLISION ends the fetching.
reset(0.5, -0.5)
machine = furnace(20.5, -2.5)
entities = { machine }
local stores = {}
for i = 1, 4 do
  local chest = { valid = true, name = "wooden-chest", type = "container", force = body.force,
    position = { x = 30.5 + 2 * i, y = -6.5 }, prototype = chest_proto,
    bounding_box = { left_top = { x = 30.15 + 2 * i, y = -6.85 }, right_bottom = { x = 30.85 + 2 * i, y = -6.15 } },
    get_inventory = function() return { get_item_count = function() return 50 end } end }
  entities[#entities + 1], stores[i] = chest, { entity = chest, position = chest.position }
end
local registry = package.loaded["scripts.registry"]
registry.stock_totals = function() return { coal = 200 } end
registry.holders_with = function(_, _, limit, skip)
  local out = {}
  for _, entry in ipairs(stores) do
    if #out < limit and not skip(entry) then out[#out + 1] = entry end
  end
  return out
end
pin()
plan = tasks.queue_plan({ steps = { { action = "insert_items", x = 20.5, y = -2.5, items = { coal = 5 } } } }).plan_id
record, took = run(plan, 1200)
outcome = record and last_outcome(record)
check(record ~= nil and record.status == "failed" and took <= 300 and outcome.result.code == "START_COLLISION"
  and outcome.error:match("START_COLLISION"),
  "auto-supply from an unescapable start stops at its first START_COLLISION and the step fails with it")
registry.stock_totals, registry.holders_with = function() return {} end, function() return {} end

-- A walk that fails for any other reason ends its step with that code too.
reset(0.5, -0.5)
machine = furnace(20.5, -2.5)
entities = { machine }
inventory = { coal = 5 }
plan = tasks.queue_plan({ steps = { { action = "insert_items", x = 20.5, y = -2.5, items = { coal = 5 },
  auto_supply = false } } }).plan_id
local function silent_pathfinder() surface_request = nil end
for _ = 1, 700 do
  silent_pathfinder()
  tick()
  if storage.tasks.records[plan] then break end
end
record = storage.tasks.records[plan]
outcome = record and last_outcome(record)
check(record ~= nil and record.status == "failed" and game.tick <= 620 and outcome.result.code == "PATH_TIMEOUT"
  and outcome.error:match("couldn't get in range: PATH_TIMEOUT"),
  "a path request nobody answers fails the step with PATH_TIMEOUT in about ten seconds")

-- A slow native search that fails, then frontier probes nobody answers: the
-- probes share one deadline, so the step ends with its PATH_NOT_FOUND
-- diagnosis well before the 60 s stall watchdog would call it STEP_STALLED.
reset(0.5, 0.1)
machine = furnace(20.5, -2.5)
entities = { machine }
inventory = { coal = 5 }
plan = tasks.queue_plan({ steps = { { action = "insert_items", x = 20.5, y = -2.5, items = { coal = 5 },
  auto_supply = false } } }).plan_id
local asked = {}
for _ = 1, 4000 do
  local request = surface_request
  local active = storage.tasks.active
  local a = active and active.current_task and active.current_task._approach
  local phase = a and a.walk and a.walk.phase
  if request and phase == "frontier_waiting" then
    surface_request = nil -- probes never answer
  elseif request then
    asked[request.id] = asked[request.id] or game.tick
    if game.tick - asked[request.id] >= 500 then -- a slow search that fails
      surface_request = nil
      walk.on_path_finished({ id = request.id })
    end
  end
  game.tick = game.tick + 1
  tasks.on_tick()
  physics()
  if storage.tasks.records[plan] then break end
end
record = storage.tasks.records[plan]
outcome = record and last_outcome(record)
check(record ~= nil and record.status == "failed" and game.tick < 3600
  and outcome.error:match("PATH_NOT_FOUND") ~= nil and not outcome.error:match("STEP_STALLED"),
  string.format("silent frontier probes end in PATH_NOT_FOUND by tick %d, not STEP_STALLED: %s", game.tick, tostring(outcome and outcome.error)))

-- Worse: each walk's first slow path is found but the body cannot follow
-- it, its re-plan fails slowly, then the probes stay silent, and the
-- approach walks twice. The probes stop short of the stall watchdog's own
-- deadline, so the diagnosis still survives.
reset(0.5, 0.1)
machine = furnace(20.5, -2.5)
entities = { machine }
inventory = { coal = 5 }
plan = tasks.queue_plan({ steps = { { action = "insert_items", x = 20.5, y = -2.5, items = { coal = 5 },
  auto_supply = false } } }).plan_id
asked = {}
for _ = 1, 4000 do
  local request = surface_request
  local active = storage.tasks.active
  local a = active and active.current_task and active.current_task._approach
  local w = a and a.walk
  pinned = w ~= nil and w.phase == "following"
  if request and w and w.phase == "frontier_waiting" then
    surface_request = nil
  elseif request then
    asked[request.id] = asked[request.id] or game.tick
    if game.tick - asked[request.id] >= 500 then
      surface_request = nil
      local found = w and (w.recoveries or 0) == 0
      walk.on_path_finished({ id = request.id, path = found and { { position = { x = 20.5, y = -2.5 } } } or nil })
    end
  end
  game.tick = game.tick + 1
  tasks.on_tick()
  physics()
  if storage.tasks.records[plan] then break end
end
pinned = false
record = storage.tasks.records[plan]
outcome = record and last_outcome(record)
check(record ~= nil and record.status == "failed" and not outcome.error:match("STEP_STALLED"),
  string.format("a stuck path, slow re-plan and silent probes still end in a diagnosis by tick %d: %s",
    game.tick, tostring(outcome and outcome.error):sub(1, 60)))

-- ------------------------------------------------- approach escape budget
-- One approach never renews its escape allowance: the start may clear and
-- block again only a bounded number of times before the approach fails.
reset(0.5, 0.1)
storage.tasks.active = { id = 1 }
local owner = storage.tasks.active
local flaps, result = 0, nil
for _ = 1, 400 do
  game.tick = game.tick + 1
  result = approach.ensure(owner, body, { x = 20.5, y = -2.5 }, 6)
  physics()
  if result then break end
  -- No path is ever answered; the world drags the body back onto the margin
  -- as soon as an escape cleared the start and the walk asked for its path.
  if owner._approach and owner._approach.walk.phase == "waiting" then
    body.position, flaps = { x = 0.5, y = 0.1 }, flaps + 1
  end
end
check(type(result) == "table" and result.status == "failed" and result.outcome.code == "START_COLLISION"
  and result.detail:match("blocked again") and flaps == 4 and game.tick < 200,
  "a start that blocks again after every escape fails the approach after a bounded number of escapes")

-- ------------------------------------------------------------- watchdog
-- A runner that never returns and never moves the body.
local stuck_ticks = 0
local stuck = { start = function() end, tick = function() stuck_ticks = stuck_ticks + 1 end }
tasks.register_action("test_stuck", { runner = stuck, make_task = function() return { _mining_started = true } end })
reset(0.5, -0.5)
stuck_ticks = 0
plan = tasks.queue_plan({ steps = { { action = "test_stuck" }, { action = "walk_to", x = 3.5, y = -0.5 } } }).plan_id
local second = tasks.queue_plan({ steps = { { action = "walk_to", x = 1.5, y = -0.5 } } }).plan_id
record, took = run(plan, 5000)
outcome = record and last_outcome(record)
check(record ~= nil and record.status == "failed" and took >= 3600 and took <= 3720
  and outcome.step == 1 and outcome.action == "test_stuck" and outcome.result.code == "STEP_STALLED"
  and outcome.result.action == "test_stuck" and outcome.result.phase == "mining"
  and outcome.error:match("^STEP_STALLED: test_stuck") and outcome.error:match("mining"),
  "a step with no body, inventory, crafting or task progress fails with STEP_STALLED after 60 seconds")
local row = storage.activity_log[#storage.activity_log]
check(row.plan_id == plan and row.code == "STEP_STALLED", "the activity log names the stalled plan's code")
record = run(second, 600)
check(record ~= nil and record.status == "completed", "the next queued plan runs once the stalled step is gone")

-- A direct task is watched the same way.
reset(0.5, -0.5)
local direct = tasks.enqueue({ task = { type = "test_stuck" } }).task_id
for _ = 1, 3720 do tick() end
record = storage.tasks.records[direct]
check(record ~= nil and record.status == "failed" and record.outcome.code == "STEP_STALLED"
  and record.detail:match("^STEP_STALLED: test_stuck"), "a direct task that stalls fails with STEP_STALLED")

-- A step-out that stalls: the watchdog calls the step's cancelled hook for
-- the body's taken-up entity only (body_only), and the record keeps its note.
local stall_hook_args = {}
tasks.register_action("test_stuck_escape", { runner = { start = function() end, tick = function() end,
  cancelled = function(_, body_only)
    stall_hook_args[#stall_hook_args + 1] = body_only
    return { code = "ESCAPE_CANCELLED", put_back = true, detail = "the plan ended mid step-out: put the inserter back at (2.5, 0.5)" }
  end }, make_task = function() return { _mining_started = true } end })
reset(0.5, -0.5)
plan = tasks.queue_plan({ steps = { { action = "test_stuck_escape" } } }).plan_id
record = run(plan, 5000)
outcome = record and last_outcome(record)
check(record ~= nil and outcome.result.code == "STEP_STALLED" and outcome.result.cancelled
  and outcome.result.cancelled.code == "ESCAPE_CANCELLED" and outcome.result.cancelled.put_back
  and outcome.error:match("^STEP_STALLED: test_stuck_escape") and outcome.error:match("put the inserter back at %(2%.5, 0%.5%)$")
  and #stall_hook_args == 1 and stall_hook_args[1] == true,
  "a stalled step-out lets go of its taken-up entity through the body-only cancelled hook and records the note")
reset(0.5, -0.5)
direct = tasks.enqueue({ task = { type = "test_stuck_escape" } }).task_id
for _ = 1, 3720 do tick() end
record = storage.tasks.records[direct]
check(record ~= nil and record.outcome.code == "STEP_STALLED" and record.outcome.cancelled
  and record.outcome.cancelled.code == "ESCAPE_CANCELLED" and #stall_hook_args == 2 and stall_hook_args[2] == true,
  "a stalled direct step-out records the body-only cancelled note too")

-- A recovery fix that stalls is over: the watchdog marks the recovery failed,
-- so nothing reruns the fix after its entity went back.
reset(0.5, -0.5)
plan = tasks.queue_plan({ steps = { { action = "test_stuck_escape" } } }).plan_id
tick()
local active = storage.tasks.active
active._recovery = { step = active.current_step, phase = "fixing", fix = active.current_task,
  first = { status = "failed", detail = "BODY_ENCLOSED" } }
record = run(plan, 5000)
check(record ~= nil and active._recovery.phase == "failed" and #record.plan.outcomes == 1,
  "a stalled recovery fix ends its recovery, so it never ticks again")

-- A hand-crafting queue that advances is progress for a step that waits on
-- it: the step is not stalled.
local craft = require("scripts.actions.craft")
body.force.recipes = {
  ["iron-gear-wheel"] = { products = { { type = "item", name = "iron-gear-wheel", amount = 1 } } },
  ["transport-belt"] = { products = { { type = "item", name = "transport-belt", amount = 2 } } },
}
tasks.register_action("test_craft_wait", { runner = { start = function() end,
  tick = function() if craft.awaits(body, "iron-gear-wheel", 1) then return nil end end },
  make_task = function() return {} end })
reset(0.5, -0.5)
plan = tasks.queue_plan({ steps = { { action = "test_craft_wait" } } }).plan_id
body.crafting_queue, body.crafting_queue_size = { { recipe = "iron-gear-wheel", count = 1 } }, 1
for _ = 1, 7200 do
  body.crafting_queue_progress = (body.crafting_queue_progress + 0.01) % 1
  tick()
end
check(storage.tasks.active and storage.tasks.active.id == plan and not storage.tasks.records[plan],
  "a step waiting on a crafting queue that advances is never stalled")
body.crafting_queue_progress = 0
record, took = run(plan, 5000)
check(record ~= nil and last_outcome(record).result.code == "STEP_STALLED" and took >= 3600 and took <= 3720,
  "once the crafting queue stands still the 60 seconds start")

-- Background crafts are not the progress of a step that waits on something
-- else: a queue that advances and drops belts into the inventory every half
-- second, its entries draining one by one, still lets the step stall.
reset(0.5, -0.5)
plan = tasks.queue_plan({ steps = { { action = "test_stuck" } } }).plan_id
body.crafting_queue = { { recipe = "iron-gear-wheel", count = 10, prerequisite = true },
  { recipe = "transport-belt", count = 40 }, { recipe = "iron-gear-wheel", count = 30 } }
body.crafting_queue_size = 3
for i = 1, 3800 do
  body.crafting_queue_progress = (body.crafting_queue_progress + 0.01) % 1
  if i % 30 == 0 then inventory["transport-belt"] = (inventory["transport-belt"] or 0) + 2 end
  if i == 1000 or i == 2000 then table.remove(body.crafting_queue, 1); body.crafting_queue_size = #body.crafting_queue end
  if i == 3000 then inventory["iron-gear-wheel"] = 30 end
  tick()
  if storage.tasks.records[plan] then break end
end
record = storage.tasks.records[plan]
check(record ~= nil and last_outcome(record).result.code == "STEP_STALLED" and game.tick <= 3720,
  "background hand-crafting never keeps a step that waits on something else from stalling")
body.crafting_queue, body.crafting_queue_size, body.crafting_queue_progress = {}, 0, 0

-- A real craft_items step with wait_for_completion polls its own queue: a
-- queue longer than 60 seconds that advances and hands over its products is
-- that step's progress.
body.force.recipes["electronic-circuit"] = { name = "electronic-circuit", enabled = true,
  ingredients = { { type = "item", name = "copper-cable", amount = 3 } },
  products = { { type = "item", name = "electronic-circuit", amount = 1 } } }
body.begin_crafting = function(args)
  body.crafting_queue, body.crafting_queue_size = { { recipe = args.recipe, count = args.count } }, 1
  return args.count
end
reset(0.5, -0.5)
plan = tasks.queue_plan({ steps = { { action = "craft_items", recipe = "electronic-circuit", crafts = 100,
  wait_for_completion = true } } }).plan_id
for i = 1, 7500 do
  if body.crafting_queue_size > 0 then
    body.crafting_queue_progress = (body.crafting_queue_progress + 0.01) % 1
    if i % 75 == 0 then inventory["electronic-circuit"] = (inventory["electronic-circuit"] or 0) + 1 end
  end
  tick()
end
check(storage.tasks.active and storage.tasks.active.id == plan and not storage.tasks.records[plan],
  "a craft step waiting on its own long crafting queue is never stalled")
body.crafting_queue, body.crafting_queue_size, body.crafting_queue_progress = {}, 0, 0
inventory["electronic-circuit"] = 100
record = run(plan, 100)
check(record ~= nil and record.status == "completed", "the waiting craft step ends once its queue empties")
body.begin_crafting, body.force.recipes["electronic-circuit"] = nil, nil

-- Inventory change and movement are progress.
reset(0.5, -0.5)
plan = tasks.queue_plan({ steps = { { action = "test_stuck" } } }).plan_id
for i = 1, 7200 do
  if i % 1800 == 0 then inventory.coal = (inventory.coal or 0) + 1 end
  tick()
end
check(not storage.tasks.records[plan], "a step whose inventory changes within each minute is not stalled")
reset(0.5, -0.5)
plan = tasks.queue_plan({ steps = { { action = "test_stuck" } } }).plan_id
for i = 1, 7200 do
  if i % 1800 == 0 then body.position = { x = body.position.x + 3, y = -0.5 } end
  tick()
end
check(not storage.tasks.records[plan], "a step whose body keeps moving on is not stalled")
-- Pacing between two spots is not progress.
reset(0.5, -0.5)
plan = tasks.queue_plan({ steps = { { action = "test_stuck" } } }).plan_id
for i = 1, 3800 do
  if i % 120 == 0 then body.position = { x = body.position.x == 0.5 and 3.5 or 0.5, y = -0.5 } end
  tick()
  if storage.tasks.records[plan] then break end
end
record = storage.tasks.records[plan]
check(record ~= nil and last_outcome(record).result.code == "STEP_STALLED" and game.tick <= 3800,
  "a body pacing between the same two spots is stalled all the same")

-- wait_for_item is a deliberate wait: it parks, and ends by its own timeout.
reset(0.5, -0.5)
plan = tasks.queue_plan({ steps = { { action = "wait_for_item", x = 1.5, y = -0.5, item = "coal",
  inventory = "output", count = 1, timeout_seconds = 200 } } }).plan_id
record, took = run(plan, 15000)
outcome = record and last_outcome(record)
check(record ~= nil and took >= 12000 and outcome.error:match("timed out waiting") and not outcome.error:match("STEP_STALLED"),
  "wait_for_item waits its own 200 seconds and is never stalled")
-- wait_for_research likewise.
reset(0.5, -0.5)
body.force.technologies = { automation = { researched = false } }
body.force.current_research = { name = "automation" }
plan = tasks.queue_plan({ steps = { { action = "wait_for_research", technology = "automation",
  timeout_seconds = 200 } } }).plan_id
record, took = run(plan, 15000)
outcome = record and last_outcome(record)
check(record ~= nil and took >= 12000 and outcome.result.code == "RESEARCH_WAIT_TIMEOUT",
  "wait_for_research waits its own 200 seconds and is never stalled")

-- A human hold is neither progress nor a stall: the watchdog does not run
-- during it and counts a fresh 60 seconds after it.
reset(0.5, -0.5)
plan = tasks.queue_plan({ steps = { { action = "test_stuck" } } }).plan_id
for _ = 1, 3000 do tick() end
held = true
for _ = 1, 6000 do tick() end
check(storage.tasks.active and storage.tasks.active.id == plan and not storage.tasks.records[plan],
  "a step is never stalled while the owner holds the body")
held = false
for _ = 1, 3000 do tick() end
check(not storage.tasks.records[plan], "the ticks before a hold do not count after it")
record, took = run(plan, 1000)
check(record ~= nil and last_outcome(record).result.code == "STEP_STALLED",
  "the stalled step still fails 60 seconds after the hold ended")

-- ------------------------------------------------------ an upgraded save
-- A step a 0.22.0 save left in flight: no watchdog state, and an approach
-- in the middle of its (single-target) escape. Both are adopted lazily.
reset(0.5, -0.5)
machine = furnace(20.5, -2.5)
entities = { machine }
inventory = { coal = 5 }
pin()
local old_walk = { requested_goal = { x = 20.5, y = -2.5 }, target = { x = 20.5, y = -2.5 }, arrival_mode = "reach",
  arrival_radius = 5.5, arrive_within = 5.5, phase = "escaping", retries = 0, recoveries = 0, frontier_segments = 0,
  visited_frontiers = {}, recovery_history = {}, escape_attempted = true, escape_target = { x = 0.5, y = -1.5 },
  escape_started_tick = 0, escape_check_tick = 0, escape_check_position = { x = 0.5, y = -0.5 },
  settle_anchor = { x = 20.5, y = -2.5 }, settle_limit = 6 }
storage.tasks.next_id = 8
storage.tasks.active = { id = 7, type = "plan", status = "running", source = "pilot", started_tick = 0,
  current_step = 1, completed_steps = 0, outcomes = {}, observation_detail = "none",
  transitions = { { status = "running", tick = 0 } },
  steps = { { action = "insert_items", x = 20.5, y = -2.5, items = { coal = 5 }, auto_supply = false } },
  current_task = { id = 7, type = "insert", target = { x = 20.5, y = -2.5 }, items = { coal = 5 }, auto_supply = false,
    _items = { { name = "coal", count = 5 } }, _supplied = true,
    _approach = { target = { x = 20.5, y = -2.5 }, reach = 6, walk = old_walk } } }
local no_stall_state = storage.tasks.stall == nil
local upgraded_ok, upgraded_error = pcall(function()
  tick()
  no_stall_state = no_stall_state and type(storage.tasks.stall) == "table" and storage.tasks.stall.id == 7
  record, took = run(7, 600)
end)
outcome = upgraded_ok and record and last_outcome(record)
check(upgraded_ok and record ~= nil and record.status == "failed" and took <= 200
  and outcome.result.code == "START_COLLISION",
  "a step in flight from a 0.22.0 save runs on without a crash: " .. tostring(upgraded_error))
check(no_stall_state, "the watchdog makes its state on the first tick of a save that has none")

-- ------------------------------------------- a body standing on belts
-- Belts never collide with the body, but carry it: an approach ends off them,
-- on a tile from which the target is still in reach.
local function belts(x1, y1, x2, y2)
  return { valid = true, name = "transport-belt", type = "transport-belt", direction = 0,
    position = { x = (x1 + x2) / 2, y = (y1 + y2) / 2 }, prototype = { collision_mask = { layers = { transport_belt = true } } },
    bounding_box = { left_top = { x = x1, y = y1 }, right_bottom = { x = x2, y = y2 } } }
end

-- A dense block: every tile within 8 of the body is belt, and the only free
-- tiles within reach of the furnace lie past it, 9 tiles from the body. The
-- search covers the whole reach over a few ticks and a native path leads
-- there; 0.29.1 failed BODY_ON_CONVEYOR at once.
reset(-0.5, -10.5)
body.reach_distance, body.build_distance = 10, 10
shore_route = false
machine = furnace(8.5, -10.5)
entities = { belts(-12, -25, 7.7, -1), machine }
inventory = { coal = 5 }
plan = tasks.queue_plan({ steps = { { action = "insert_items", x = 8.5, y = -10.5, items = { coal = 5 },
  auto_supply = false } } }).plan_id
record, took = run(plan, 600)
outcome = record and last_outcome(record)
check(record ~= nil and record.status == "completed" and machine.inserted == 5 and body.position.x >= 7.9
  and (body.position.x - 8.5) ^ 2 + (body.position.y + 10.5) ^ 2 <= 100,
  "an approach in a dense belt block walks to an off-belt tile anywhere within reach and inserts: "
    .. tostring(outcome and outcome.error))
body.reach_distance, body.build_distance = 6, 6

-- The off-belt tile beside the body is diagonal, past a chest's corner that
-- ordinary walking cannot pass; a native path around the corner leads there
-- (0.29.1 failed "ordinary walking did not leave transport-belt").
reset(0.5, -5.5)
local function chest(x, y)
  return { valid = true, name = "wooden-chest", type = "container", force = body.force, position = { x = x, y = y },
    prototype = chest_proto, bounding_box = { left_top = { x = x - 0.35, y = y - 0.35 },
      right_bottom = { x = x + 0.35, y = y + 0.35 } } }
end
local corners = { chest(-0.5, -5.5), chest(1.5, -5.5) }
entities = { belts(0, -9, 1, -2), corners[1], corners[2] }
wall = function(p)
  local moved = { left_top = { x = p.x - 0.2, y = p.y - 0.2 }, right_bottom = { x = p.x + 0.2, y = p.y + 0.2 } }
  return overlaps(moved, corners[1].bounding_box) or overlaps(moved, corners[2].bounding_box)
end
detour = { { x = 0.5, y = -6.5 } }
inventory = { ["wooden-chest"] = 1 }
plan = tasks.queue_plan({ steps = { { action = "build_layout", anchor = { x = 3, y = -6 },
  entities = { { name = "wooden-chest", dx = 0.5, dy = 0.5 } } } } }).plan_id
record, took = run(plan, 600)
outcome = record and last_outcome(record)
check(record ~= nil and record.status == "completed" and outcome.result.code == "LAYOUT_BUILT"
  and entities[#entities].position.x == 3.5 and body.position.x <= -0.2 and body.position.y < -6,
  "a settle step blocked by a corner walks to its off-belt tile by a native path and builds: "
    .. tostring(outcome and (outcome.error or outcome.result and outcome.result.code)))

print(failures == 0 and "\nALL APPROACH BOUNDS TESTS PASSED" or ("\n" .. failures .. " APPROACH BOUNDS TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
