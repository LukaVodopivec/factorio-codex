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

local mine = require("scripts.actions.mine")
local task = { target = { x = 3, y = 4 }, count = 1 }
mine.start(task)
local result = mine.tick(task)
check(result and result.status == "failed" and result.outcome.code == "TARGET_NOT_SELECTABLE"
  and result.outcome.stage == "initial_selection"
  and result.outcome.can_reach_entity == true
  and result.outcome.requested_position.x == 3 and result.outcome.requested_position.y == 4
  and result.outcome.target.name == "tree-01" and result.outcome.selected == nil,
  "exact mining distinguishes engine selection rejection from coordinate resolution and physical reach")

local imprecise_ok, imprecise_error = pcall(mine.start, { target = { x = 3.51, y = 4 }, count = 1 })
check(not imprecise_ok and tostring(imprecise_error):match("no natural minable entity occupies exact coordinate"),
  "exact mining distinguishes an outside-footprint coordinate from a resolved target")

os.exit(failures == 0 and 0 or 1)
