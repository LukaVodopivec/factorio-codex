local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local inventory = { ["iron-plate"] = 6, ["transport-belt"] = 0 }
local recipe = { name = "transport-belt", enabled = true,
  ingredients = { { type = "item", name = "iron-plate", amount = 3 } },
  products = { { type = "item", name = "transport-belt", amount = 2 } } }
local body = { force = { recipes = { ["transport-belt"] = recipe } }, crafting_queue_size = 0 }
body.get_item_count = function(name) return name and (inventory[name] or 0) or 0 end
body.begin_crafting = function(args)
  inventory["iron-plate"] = inventory["iron-plate"] - 3 * args.count
  inventory["transport-belt"] = inventory["transport-belt"] + 2 * args.count
  return args.count
end
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
_G.game = { tick = 0 }
local craft = require("scripts.actions.craft")

local task = { recipe = "transport-belt", count = 2 }
craft.start(task)
game.tick = 30
local done = craft.tick(task)
check(done and done.status == "done" and done.detail:match("2 recipe crafts")
  and done.detail:match("%+4 transport%-belt"),
  "craft result distinguishes recipe crafts from actual output item count")
local missing_count_ok = pcall(craft.start, { recipe = "transport-belt" })
check(not missing_count_ok, "craft rejects a missing recipe execution count")
for _, invalid in ipairs({ 0, 1.5, 101 }) do
  local ok = pcall(craft.start, { recipe = "transport-belt", count = invalid })
  check(not ok, "craft rejects missing, noninteger, and out-of-range recipe execution counts")
end
recipe.products = { { type = "item", name = "transport-belt", amount_min = 1, amount_max = 3 } }
inventory["iron-plate"] = 3
local variable = { recipe = "transport-belt", count = 1, wait_for_completion = false }
craft.start(variable)
local accepted = craft.tick(variable)
check(accepted and accepted.detail:match("variable transport%-belt")
  and not accepted.detail:match("expected outputs: 3 transport%-belt"),
  "craft never reports amount_min or amount_max as an exact output")
os.exit(failures == 0 and 0 or 1)
