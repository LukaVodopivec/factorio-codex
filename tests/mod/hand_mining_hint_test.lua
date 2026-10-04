-- A completed hand-mining result names the better source when own mining
-- drills already mine that resource: drill_produced, the drill count, and the
-- drill-fed stock from map_summary.stock_total when that reader is available.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

_G.game = { tick = 100 }
_G.defines = { inventory = { chest = 1 } }
_G.prototypes = { item = { ["iron-ore"] = { stack_size = 50 }, wood = { stack_size = 100 } } }

local own, foreign = {}, {}
local function minable(name, kind, product)
  return { valid = true, name = name, type = kind, amount = kind == "resource" and 100 or nil, position = { x = 0, y = 0 },
    selection_box = { left_top = { x = -0.49, y = -0.49 }, right_bottom = { x = 0.49, y = 0.49 } },
    prototype = { mineable_properties = { minable = true, products = { { type = "item", name = product, amount = 1 } } } } }
end
local function drill(force, target_name)
  return { valid = true, type = "mining-drill", name = "burner-mining-drill", force = force,
    mining_target = target_name and { valid = true, name = target_name } or nil }
end

local held, slots = {}, {}
for index = 1, 4 do slots[index] = { valid_for_read = false } end
slots.get_item_count = function(name) return held[name] or 0 end
slots.get_bar = function() return #slots + 1 end
slots.get_filter = function() return nil end

local target, drills, drill_queries = nil, {}, 0
local body = {
  valid = true, position = { x = 0, y = 0 }, force = own, crafting_queue_size = 0,
  mining_state = { mining = false }, selected = nil,
  can_reach_entity = function(entity) return entity.valid end,
  get_main_inventory = function() return slots end,
}
body.surface = { find_entities_filtered = function(filter)
  if filter.type == "mining-drill" then
    drill_queries = drill_queries + 1
    check(filter.force == own and filter.area ~= nil, "the drill search is limited to the character's own force")
    return drills
  end
  return { target }
end }
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure_entity = function() return "ok" end }

-- One physical cycle: the game, not the action, lowers the amount and adds
-- the product while mining_state points at the selected target.
local function mine_once(mine, entity, product)
  target, held = entity, {}
  local task = { target = { x = 0, y = 0 }, count = 1 }
  mine.start(task)
  check(mine.tick(task) == nil and body.mining_state.mining == true, "fixture: physical mining started on " .. entity.name)
  if entity.type == "resource" then entity.amount = entity.amount - 1 else entity.valid = false end
  held[product] = 1
  return mine.tick(task)
end
local function load_mine(map_summary)
  package.loaded["scripts.actions.mine"], package.loaded["scripts.map_summary"] = nil, map_summary
  return require("scripts.actions.mine")
end

local stock_requests = {}
local mine = load_mine({ stock_total = function(item) stock_requests[#stock_requests + 1] = item; return 730 end })

-- Three own drills mine iron ore; an idle own drill, an own copper drill and
-- a foreign iron drill do not count.
drills = { drill(own, "iron-ore"), drill(own, "iron-ore"), drill(own, "iron-ore"), drill(own, nil),
  drill(own, "copper-ore"), drill(foreign, "iron-ore") }
local result = mine_once(mine, minable("iron-ore", "resource", "iron-ore"), "iron-ore")
check(result.status == "done" and result.outcome and result.outcome.drill_produced == true and result.outcome.drills == 3,
  "hand-mining a resource own drills mine reports drill_produced with the drill count")
check(result.outcome.stockpile_total == 730 and stock_requests[1] == "iron-ore" and #stock_requests == 1,
  "the result carries stockpile_total for the mined item from map_summary.stock_total")
check(result.detail:match("^mined iron%-ore at exact coordinate: requested 1 cycles, completed 1, actual gain 1 items")
  and result.detail:match("3 own mining drill%(s%) already mine iron%-ore, stockpile_total 730"),
  "the detail keeps the mining result and names the better source")

-- No drill on that resource: an ordinary result with no hint.
drills = { drill(own, "copper-ore"), drill(foreign, "iron-ore"), drill(own, nil) }
result = mine_once(mine, minable("iron-ore", "resource", "iron-ore"), "iron-ore")
check(result.status == "done" and result.outcome == nil and not result.detail:match("drill"),
  "a resource no own drill mines carries no drill_produced hint")

-- Trees and rocks are never drill-produced; no drill search runs.
drills, drill_queries = { drill(own, "tree-01") }, 0
result = mine_once(mine, minable("tree-01", "tree", "wood"), "wood")
check(result.status == "done" and result.outcome == nil and drill_queries == 0,
  "hand-mining a tree neither searches for drills nor reports a hint")

-- The stock reader failing or missing never breaks the mining result.
drills = { drill(own, "iron-ore") }
mine = load_mine({ stock_total = function() error("stock reader failed") end })
result = mine_once(mine, minable("iron-ore", "resource", "iron-ore"), "iron-ore")
check(result.status == "done" and result.outcome.drill_produced == true and result.outcome.drills == 1
  and result.outcome.stockpile_total == nil, "a failing stock reader leaves the hint without a stockpile total")
mine = load_mine({})
result = mine_once(mine, minable("iron-ore", "resource", "iron-ore"), "iron-ore")
check(result.status == "done" and result.outcome.drills == 1 and result.outcome.stockpile_total == nil,
  "a map_summary without stock_total is tolerated")
body.surface.find_entities_filtered = function(filter)
  if filter.type == "mining-drill" then error("native search failed") end
  return { target }
end
result = mine_once(mine, minable("iron-ore", "resource", "iron-ore"), "iron-ore")
check(result.status == "done" and result.outcome == nil, "a failing drill search leaves an ordinary mining result")

os.exit(failures == 0 and 0 or 1)
