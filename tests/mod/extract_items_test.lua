local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local body = { valid = true, reach_distance = 6, received = {} }
function body.insert(stack)
  body.received[stack.name] = (body.received[stack.name] or 0) + stack.count
  return stack.count
end

local contents = { coal = 7, stone = 3 }
local inventory = {}
function inventory.get_contents()
  local result = {}
  for name, count in pairs(contents) do
    result[#result + 1] = { name = name, count = count }
  end
  return result
end
function inventory.remove(stack)
  local removed = math.min(contents[stack.name] or 0, stack.count)
  contents[stack.name] = (contents[stack.name] or 0) - removed
  return removed
end
function inventory.insert(stack)
  contents[stack.name] = (contents[stack.name] or 0) + stack.count
  return stack.count
end

local entity = { valid = true, name = "wooden-chest" }
function entity.get_output_inventory() return nil end
function entity.get_inventory() return inventory end
function entity.remove_item(stack) return inventory.remove(stack) end
function entity.insert(stack) return inventory.insert(stack) end

package.loaded["scripts.companion"] = {
  require_companion = function() return body end,
  get = function() return body end,
}
package.loaded["scripts.actions.approach"] = {
  ensure = function() return "ok" end,
  find_entity_near = function() return entity end,
}
_G.prototypes = { item = { coal = {}, stone = {} } }
_G.defines = { inventory = { chest = 1 } }

local extract = require("scripts.actions.transfer").extract
local all_task = { target = { x = 1, y = 2 }, all = true }
extract.start(all_task)
local all_result = extract.tick(all_task)
check(all_task._all == true, "all=true selects full output extraction")
check(all_result.status == "done" and body.received.coal == 7 and body.received.stone == 3,
  "all extraction moves every output item into Codex inventory")

contents.coal = 5
body.received.coal = 0
local named_task = { target = { x = 1, y = 2 }, items = { coal = 2 } }
extract.start(named_task)
local named_result = extract.tick(named_task)
check(named_result.status == "done" and body.received.coal == 2 and contents.coal == 3,
  "named extraction moves only the requested exact count")

local missing, missing_error = pcall(extract.start, { target = { x = 1, y = 2 } })
check(not missing and tostring(missing_error):match("requires items") ~= nil,
  "Lua rejects extraction without items unless all=true is explicit")

os.exit(failures == 0 and 0 or 1)
