local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

local body = { valid = true, reach_distance = 6, received = {}, capacity = 100 }
local function received_total()
  local total = 0
  for _, count in pairs(body.received) do total = total + count end
  return total
end
function body.insert(stack)
  local inserted = math.min(stack.count, math.max(body.capacity - received_total(), 0))
  body.received[stack.name] = (body.received[stack.name] or 0) + inserted
  return inserted
end
function body.remove_item(stack)
  local removed = math.min(stack.count, body.received[stack.name] or 0)
  body.received[stack.name] = (body.received[stack.name] or 0) - removed
  return removed
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
  ensure_entity = function() return "ok" end,
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
body.received = {}
local named_task = { target = { x = 1, y = 2 }, items = { coal = 2 } }
extract.start(named_task)
local named_result = extract.tick(named_task)
check(named_result.status == "done" and body.received.coal == 2 and contents.coal == 3,
  "named extraction moves only the requested exact count")

contents.coal = 0
body.received = {}
local empty_task = { target = { x = 1, y = 2 }, items = { coal = 2 } }
extract.start(empty_task)
local empty_result = extract.tick(empty_task)
check(empty_result.status == "failed" and empty_result.detail:match("it has no coal") ~= nil,
  "named extraction reports an empty source honestly")

contents.coal = 5
body.capacity = 0
body.received = {}
local full_task = { target = { x = 1, y = 2 }, items = { coal = 2 } }
extract.start(full_task)
local full_result = extract.tick(full_task)
check(full_result.status == "failed" and full_result.detail:match("my inventory is full") ~= nil,
  "named extraction distinguishes a full Codex inventory from an empty source")
check(contents.coal == 5 and (body.received.coal or 0) == 0,
  "failed full-inventory extraction restores every removed source item")

contents.coal, contents.stone = 7, 3
body.capacity = 8
body.received = {}
local partial_all_task = { target = { x = 1, y = 2 }, all = true }
extract.start(partial_all_task)
local partial_all = extract.tick(partial_all_task)
check(partial_all.status == "failed" and partial_all.detail:match("nothing was taken") ~= nil,
  "all extraction reports aggregate capacity shortfall instead of partial success")
check(contents.coal == 7 and contents.stone == 3 and received_total() == 0,
  "failed all extraction restores every source item and every earlier transfer")
body.capacity = 100

local missing, missing_error = pcall(extract.start, { target = { x = 1, y = 2 } })
check(not missing and tostring(missing_error):match("requires items") ~= nil,
  "Lua rejects extraction without items unless all=true is explicit")

os.exit(failures == 0 and 0 or 1)
