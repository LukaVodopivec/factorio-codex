local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

package.loaded["scripts.companion"] = { require_companion = function() return { valid = true } end }
package.loaded["scripts.actions.approach"] = {}
_G.prototypes = { item = {} }

local task = { target = { x = tonumber(arg[1]), y = tonumber(arg[2]) } }
if arg[3] == "true" then task.all = true end
assert(task.items == nil, "omitted extract payload unexpectedly contains items")
require("scripts.actions.transfer").extract.start(task)
assert(task._all == true, "extract.start did not select all-output extraction")
print("ok   mapped omission reaches extract.start as all=true")
