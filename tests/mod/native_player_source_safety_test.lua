local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
local root = here .. "/../../mod/agentic-companion/scripts/"
local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end
local function read(path)
  local file = assert(io.open(path, "r"))
  local value = file:read("*a")
  file:close()
  return value
end

local companion = read(root .. "companion.lua")
local walk = read(root .. "actions/walk.lua")
local approach = read(root .. "actions/approach.lua")
local owned = companion .. walk .. approach

check(not companion:match("create_entity") and not companion:match("create_character"),
  "native player lifecycle contains no standalone character creation")
check(not companion:match("game%.players"),
  "native body lookup never scans or adopts another player")
check(not companion:match("entity%.teleport") and not companion:match("character%.teleport")
  and not companion:match("rec%.entity%.teleport"),
  "Codex character has no teleport path")
check(not walk:match('phase%s*=%s*"straight"') and not walk:match("straight%-line fallback"),
  "walker contains no blind straight-line fallback")
check(not owned:match("insert%s*%(") and not owned:match("insert_stack") and not owned:match("give_item"),
  "native lifecycle and walking contain no free-resource grant")
check(not owned:match("shooting_state") and not owned:match("attack_parameters")
  and not owned:match("set_command"),
  "native lifecycle and walking expose no combat behavior")
check(not owned:match("remote%.call") and not owned:match("rcon") and not owned:match("loadstring"),
  "native lifecycle and walking add no second writer, console, or Lua execution path")

os.exit(failures == 0 and 0 or 1)
