-- Offline tests for set_requests (requests.lua): a requester or
-- buffer chest's manual logistic section is written the way its window does
-- (merge updates an item's slot or takes the first free one, set clears
-- first, remove clears), sections the game controls are never written, the
-- result reads every section back and says whether a robot network covers
-- the chest. Nothing is moved. Strict 2.0.77 mocks.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

local mock = dofile(here .. "/factorio_api_mock.lua")
_G.storage, _G.game = {}, { tick = 1 }
_G.defines = { inventory = {}, logistic_section_type = { manual = 0, circuit_controlled = 1,
  request_missing_materials_controlled = 2, transitional_request_controlled = 3 } }
_G.prototypes = { item = { ["iron-plate"] = {}, ["copper-plate"] = {}, ["iron-gear-wheel"] = {}, coal = {} } }

local function section(index, kind, group)
  local slots, count = {}, 0
  local s = mock.logistic_section({ index = index, type = kind, is_manual = kind == defines.logistic_section_type.manual,
    group = group, active = true })
  mock.read(s, "filters_count", function() return count end)
  s.get_slot = function(i) return slots[i] or {} end
  s.set_slot = function(i, filter)
    assert(s.is_manual, "a game-controlled section is never written")
    assert(filter.value.quality == "normal" and filter.value.type == "item" and filter.value.comparator == "=")
    slots[i], count = filter, math.max(count, i)
    return i
  end
  s.clear_slot = function(i) assert(s.is_manual); slots[i] = nil end
  return s, slots
end

local function chest(mode, network)
  local list = {}
  local sections = mock.logistic_sections({})
  mock.read(sections, "sections", function() local out = {}; for i, s in ipairs(list) do out[i] = s end; return out end)
  mock.read(sections, "sections_count", function() return #list end)
  sections.get_section = function(i) return list[i] end
  sections.add_section = function(group)
    local s = section(#list + 1, defines.logistic_section_type.manual, group or "")
    list[#list + 1] = s
    return s
  end
  local e = mock.entity({ valid = true, name = mode .. "-chest", type = "logistic-container", force = "own",
    position = { x = 2.5, y = 2.5 }, prototype = mock.entity_prototype({ logistic_mode = mode }),
    get_logistic_sections = function() return sections end, logistic_network = network, request_from_buffers = false })
  return e, list
end

local covered = mock.logistic_network({ network_id = 7, available_logistic_robots = 10,
  find_cell_closest_to = function() return mock.logistic_cell({ is_in_logistic_range = function() return true end }) end })

local body = { valid = true, reach_distance = 10, force = "own" }
local target
local reached = 0
package.loaded["scripts.companion"] = { require_companion = function() return body end, get = function() return body end }
package.loaded["scripts.actions.approach"] = { ensure = function() return "ok" end,
  ensure_entity = function() reached = reached + 1; return "ok" end, find_entity_near = function() return target end }
local requests = require("scripts.requests")

local function run(step)
  step.target = step.target or { x = 2.5, y = 2.5 }
  requests.action.validate(step, 1)
  local task = requests.action.make_task(step)
  task.id = 3
  requests.action.runner.start(task)
  return requests.action.runner.tick(task)
end

local requester, list = chest("requester", covered)
target = requester
local first = run({ requests = { { item = "iron-plate", min = 50 }, { item = "copper-plate", min = 20, max = 100 } } })
local items = first.outcome.sections[1].items
check(first.status == "done" and reached == 1 and #list == 1 and #items == 2 and items[1].item == "iron-plate" and items[1].min == 50
  and items[2].max == 100 and items[1].quality == "normal", "merge into a new manual section, read back")
check(first.outcome.network.id == 7 and first.outcome.network.in_logistic_range and first.outcome.network.logistic_robots_available == 10
  and first.outcome.notes == nil, "the chest's network is named")
local merged = run({ requests = { { item = "iron-plate", min = 80 }, { item = "coal", min = 5 } } })
local rows = merged.outcome.sections[1].items
check(#list == 1 and #rows == 3 and rows[1].item == "iron-plate" and rows[1].min == 80 and rows[3].item == "coal",
  "merge updates an item's own slot and adds a new item after the others")
local removed = run({ remove = { "copper-plate" } })
check(#removed.outcome.sections[1].items == 2 and removed.outcome.sections[1].items[2].item == "coal",
  "remove clears the item's slot")
local refilled = run({ requests = { { item = "iron-gear-wheel", min = 10 } } })
check(refilled.outcome.sections[1].items[2].item == "iron-gear-wheel", "a freed slot is the first free one")
local set = run({ mode = "set", requests = { { item = "coal", min = 1 } } })
check(#set.outcome.sections[1].items == 1 and set.outcome.sections[1].items[1].item == "coal", "set replaces the section")
local grouped = run({ section = "mall", requests = { { item = "iron-plate", min = 1 } } })
check(#list == 2 and list[2].group == "mall" and #grouped.outcome.sections == 2, "a group name adds that group's section")
run({ section = "mall", requests = { { item = "coal", min = 1 } } })
check(#list == 2, "and reuses it")
local buffers = run({ request_from_buffers = true })
check(buffers.status == "done" and requester.request_from_buffers == true and buffers.outcome.request_from_buffers == true,
  "a requester can request from buffers")

-- Game-controlled and missing sections are refused.
list[3] = section(3, defines.logistic_section_type.request_missing_materials_controlled, "")
local auto = run({ section = 3, requests = { { item = "coal", min = 1 } } })
check(auto.status == "failed" and auto.outcome.code == "NOT_MANUAL_SECTION", "a game-controlled section is never written")
check(run({ section = 9, requests = { { item = "coal", min = 1 } } }).outcome.code == "NO_SECTION", "a missing index is refused")

-- A section with no group reads as "" or nil: both are the default.
local nil_group, nil_list = chest("buffer", nil)
nil_list[1] = section(1, defines.logistic_section_type.manual, nil)
target = nil_group
local outside = run({ requests = { { item = "coal", min = 4 } } })
check(#nil_list == 1 and outside.outcome.sections[1].items[1].item == "coal" and outside.outcome.network == nil
  and outside.outcome.notes[1]:match("no roboport covers"), "an ungrouped section is the default; no network is said")
check(run({ request_from_buffers = true }).outcome.code == "CONFIG_NOT_APPLICABLE", "a buffer chest does not request from buffers")
target = chest("storage", covered)
local storage_chest = run({ requests = { { item = "coal", min = 4 } } })
check(storage_chest.outcome.code == "NOT_A_REQUESTER" and storage_chest.detail:match("storage_filter"),
  "a storage chest is NOT_A_REQUESTER, pointing at its storage filter")

local function refused(step, pattern)
  step.target = step.target or { x = 0, y = 0 }
  local ok, err = pcall(requests.action.validate, step, 2)
  return not ok and tostring(err):match(pattern) ~= nil
end
check(refused({ requests = { { item = "coal", min = 1, import_from = "vulcanus" } } }, "platform hubs"), "import_from is for hubs")
check(refused({ requests = { { item = "coal", min = 1, quality = "rare" } } }, "quality"), "only normal quality")
check(refused({ requests = { { item = "coal", min = 5, max = 2 } } }, "max must be"), "max below min is refused")
check(refused({ requests = { { item = "coal", min = 1 }, { item = "coal", min = 2 } } }, "repeats"), "an item once per step")
check(refused({ requests = { { item = "mud", min = 1 } } }, "^UNKNOWN_ITEM"), "an unknown item is refused")
check(refused({ requests = {} }, "needs requests"), "an empty step is refused")

mock.assert_clean()
print(failures == 0 and "\nALL SET REQUESTS TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
