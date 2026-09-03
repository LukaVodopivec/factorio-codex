local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local force = {}
local tree = {
  valid = true, name = "tree-01", type = "tree", position = { x = 3, y = 4 },
  selection_box = { left_top = { x = 2.5, y = 3.5 }, right_bottom = { x = 3.5, y = 4.5 } },
  prototype = { mineable_properties = { minable = true, products = {
    { type = "item", name = "wood", amount = 4 },
  } } },
}
local inventory = { { valid_for_read = false } }
inventory.get_bar = function() return 2 end
inventory.get_filter = function() return nil end
inventory.get_item_count = function() return 0 end
local body = {
  valid = true, position = { x = 2, y = 4 }, force = force,
  mining_state = { mining = false }, crafting_queue_size = 0,
  can_reach_entity = function(entity) return entity == tree end,
  get_main_inventory = function() return inventory end,
  surface = { find_entities_filtered = function() return { tree } end },
}
-- Model a Factorio selection rejection independently of reach: assignments to
-- LuaControl.selected are ignored while all other physical state stays normal.
setmetatable(body, {
  __index = function(_, key) if key == "selected" then return nil end end,
  __newindex = function(target, key, value) if key ~= "selected" then rawset(target, key, value) end end,
})
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure_entity = function() return "ok" end }
_G.defines = { inventory = {} }
_G.prototypes = { item = { wood = { stack_size = 100 } } }
_G.game = { tick = 100 }

local mine = require("scripts.actions.mine")
local task = { target = { x = 3, y = 4 }, count = 1, expected_name = "tree-01", observed_tick = 90 }
mine.start(task)
local result = mine.tick(task)
check(result and result.status == "failed" and result.outcome.code == "TARGET_NOT_SELECTABLE"
  and result.outcome.stage == "initial_selection"
  and result.outcome.can_reach_entity == true
  and result.outcome.requested_position.x == 3 and result.outcome.requested_position.y == 4
  and result.outcome.target.name == "tree-01" and result.outcome.selected == nil
  and result.outcome.expected_name == "tree-01" and result.outcome.observed_tick == 90
  and result.outcome.observation_age_ticks == 10,
  "exact mining distinguishes engine selection rejection from coordinate resolution and physical reach")

local missing = { target = { x = 3.51, y = 4 }, count = 1, expected_name = "tree-01", observed_tick = 75 }
mine.start(missing)
local missing_result = mine.tick(missing)
check(missing_result and missing_result.outcome.code == "TARGET_NOT_FOUND_AT_START"
  and missing_result.outcome.stage == "initial_resolution"
  and missing_result.outcome.observation_age_ticks == 25
  and missing_result.detail:match("no natural minable entity occupies exact coordinate"),
  "exact mining distinguishes an outside-footprint coordinate from a resolved target")

local mismatch = { target = { x = 3, y = 4 }, count = 1, expected_name = "tree-02", observed_tick = 99 }
mine.start(mismatch)
local mismatch_result = mine.tick(mismatch)
check(mismatch_result and mismatch_result.outcome.code == "TARGET_IDENTITY_MISMATCH"
  and mismatch_result.outcome.target.name == "tree-01"
  and mismatch_result.outcome.expected_name == "tree-02",
  "exact mining refuses a different prototype at the observed coordinate")

local removed = { target = { x = 3, y = 4 }, count = 1, expected_name = "tree-01", observed_tick = 100 }
tree.valid = true
mine.start(removed)
tree.valid = false
local removed_result = mine.tick(removed)
check(removed_result and removed_result.outcome.code == "TARGET_GONE_AFTER_RESOLUTION"
  and removed_result.outcome.target.name == "tree-01",
  "exact mining reports invalidation after resolution without selecting a replacement")

tree.valid = true
body.can_reach_entity = function() return false end
local unreachable = { target = { x = 3, y = 4 }, count = 1, expected_name = "tree-01", observed_tick = 100 }
mine.start(unreachable)
local unreachable_result = mine.tick(unreachable)
check(unreachable_result and unreachable_result.outcome.code == "TARGET_OUT_OF_REACH"
  and unreachable_result.outcome.stage == "after_approach",
  "exact mining distinguishes authoritative reach failure after approach")

tree.valid = true
body.can_reach_entity = function(entity) return entity == tree end
package.loaded["scripts.actions.approach"].ensure_entity = function()
  tree.valid = false
  return { status = "failed", detail = "the selected entity is gone" }
end
local gone_during_approach = { target = { x = 3, y = 4 }, count = 1, expected_name = "tree-01", observed_tick = 100 }
mine.start(gone_during_approach)
local gone_during_result = mine.tick(gone_during_approach)
check(gone_during_result and gone_during_result.outcome.code == "TARGET_GONE_AFTER_RESOLUTION"
  and gone_during_result.outcome.stage == "during_approach",
  "exact mining maps approach-time invalidation to the target lifecycle diagnostic")

os.exit(failures == 0 and 0 or 1)
