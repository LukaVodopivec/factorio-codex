local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local mock = dofile(here .. "/factorio_api_mock.lua")
local function rejection(action, label)
  local before = #mock.violations
  local ok, err = pcall(action)
  assert(not ok and tostring(err):find("has no member", 1, true), label .. " must raise")
  assert(#mock.violations == before + 1, label .. " must leave evidence")
end
for _, class in ipairs({ "entity", "fluidbox", "burner" }) do
  local object = mock[class]({})
  rejection(function() return object.invented_method() end, class .. " method read")
  rejection(function() return mock[class]({ invented = true }) end, class .. " constructor")
  rejection(function() object.invented = true end, class .. " assignment")
  rejection(function() object.invented = nil end, class .. " nil assignment")
end
local entity = mock.entity({ valid = true, burner = { remaining_burning_fuel = 0 } }, { fuel = 5 })
assert(entity.fluidbox == nil and entity.burner.currently_burning == nil, "supported optional reads return nil")
entity.burner.remaining_burning_fuel = 100
entity.burner.remaining_burning_fuel = nil
assert(entity.burner.remaining_burning_fuel == nil, "supported assignments remain mutable including nil")
mock.state(entity).fuel = 4
assert(mock.state(entity).fuel == 4, "simulation state is separate and mutable")
rejection(function() return entity.fuel end, "simulation name is not native")
rejection(function() return entity.get_fluid_box_prototype(1) end, "unsupported entity fluid method")
rejection(function() entity.burner = { invented = true } end, "nested burner update")
rejection(function() entity.fluidbox = { invented = true } end, "nested fluidbox update")
local fluidbox = mock.fluidbox({ [1] = { name = "water", amount = 5 }, [2] = {},
  get_prototype = function() return { production_type = "input" } end })
assert(#fluidbox == 2 and fluidbox[1].name == "water" and fluidbox[3] == nil)
fluidbox[1] = nil
fluidbox[1] = { name = "steam", amount = 1 }
assert(fluidbox[1].name == "steam" and fluidbox.get_prototype(1).production_type == "input")
mock.length(fluidbox, function() return 3 end)
assert(#fluidbox == 3, "empty fluidboxes still have a native length")
mock.read(fluidbox, 3, function() return { name = "water", amount = 2 } end)
assert(fluidbox[3].amount == 2, "native indexed state can be simulated")
local before = #mock.violations
mock.unreadable(entity.burner, "currently_burning")
local readable, err = pcall(function() return entity.burner.currently_burning end)
assert(not readable and tostring(err):find("unreadable native", 1, true))
assert(#mock.violations == before, "supported native failure is not invalid membership")
mock.unreadable(entity.burner, "currently_burning", false)
assert(entity.burner.currently_burning == nil)
-- A production-style pcall may swallow the read error but cannot clear evidence.
local fresh = dofile(here .. "/factorio_api_mock.lua")
fresh.assert_clean()
local caught = fresh.entity({})
pcall(function() return caught.another_invented_method() end)
assert(#fresh.violations == 1, "caught read records new evidence in a clean suite")
assert(not pcall(fresh.assert_clean), "suite guard detects a swallowed invalid read")
print("ok   strict native membership, mutable values, indexing and sticky failure evidence")
