-- The 0.22 stage A, B and C modules never touch the cursor, a GUI or a player:
-- The owner's undo queue and the human-hold detector stay untouched (contract 0.2).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local root = here .. "/../../mod/agentic-companion/scripts/"
local FORBIDDEN = { "cursor_stack", "build_from_cursor", "can_build_from_cursor", "centered_on", "%.opened", "by_player",
  "player%s*=", "undo_index" }
local failures = 0
for _, file in ipairs({ "entity_settings.lua", "inventory_roles.lua", "actions/configure.lua", "actions/tiles.lua",
  "actions/equip.lua", "requests.lua", "actions/transfer.lua", "logistics.lua",
  -- stage B: platform building and remote settings
  "actions/build_layout.lua", "actions/area_ops.lua", "actions/build.lua", "blueprints.lua", "platforms.lua",
  "actions/rocket.lua", "inspect.lua", "research.lua",
  -- stage C: travel and upkeep
  "actions/travel.lua", "chores.lua" }) do
  local handle = assert(io.open(root .. file, "r"))
  local source = handle:read("a")
  handle:close()
  for _, pattern in ipairs(FORBIDDEN) do
    for line in source:gmatch("[^\n]+") do
      if not line:match("^%s*%-%-") and line:match(pattern) then
        failures = failures + 1
        print("FAIL " .. file .. " uses " .. pattern .. ": " .. line)
      end
    end
  end
end
print(failures == 0 and "ok   stage A, B and C modules use no cursor, GUI or player" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
