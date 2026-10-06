-- Thought feed: say adds a coloured panel line (never chat) and keeps the last 8 lines,
-- say_now sets the strategist's NOW line, and only the connected Codex player gets the
-- left-side panel. The panel is never player.opened, so the human-hold
-- detector stays released. Offline: the real thoughts and companion modules
-- over mocked LuaPlayer and LuaGui.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end

_G.defines = {
  controllers = { character = 1, spectator = 4, remote = 7 },
  gui_type = { none = 0 },
  print_sound = { never = 1 },
  print_skip = { never = 1 },
}

-- A GUI element: add/clear/destroy, children by name, and a style table.
-- caption_writes counts every caption change, to show a refresh with nothing
-- new rewrites nothing (that rebuild made the panel flicker).
local caption_writes = 0
local function element(spec, parent)
  local fields = { valid = true, type = spec.type, name = spec.name, caption = spec.caption, style = {}, children = {} }
  local el = setmetatable({}, { __index = fields, __newindex = function(_, key, value)
    if key == "caption" then caption_writes = caption_writes + 1 end
    fields[key] = value
  end })
  function fields.add(child_spec)
    local child = element(child_spec, el)
    fields.children[#fields.children + 1] = child
    if child_spec.name then fields[child_spec.name] = child end
    return child
  end
  function fields.clear()
    for _, child in ipairs(fields.children) do
      child.valid = false
      if child.name then fields[child.name] = nil end
    end
    fields.children = {}
  end
  return el
end
-- The panel's visible captions, top to bottom.
local function shown(panel)
  local rows = {}
  for _, child in ipairs(panel.children) do if child.visible ~= false then rows[#rows + 1] = child.caption end end
  return rows
end

local opened_writes = 0
local function make_player(index, name, connected)
  local state = { index = index, valid = true, connected = connected, name = name,
    controller_type = defines.controllers.character, opened_gui_type = defines.gui_type.none,
    cursor_stack = { valid_for_read = false }, gui = { left = element({ type = "root" }) } }
  state.character = { valid = true, walking_state = {}, mining_state = {} }
  return setmetatable({}, {
    __index = state,
    __newindex = function(_, key, value)
      if key == "opened" then opened_writes = opened_writes + 1 end
      state[key] = value
    end,
  })
end

local codex = make_player(1, "Codex", true)
local viewer = make_player(2, "The owner", true)
local players = { codex, viewer }
local printed = {}
_G.game = {
  tick = 100,
  connected_players = players,
  get_player = function(index) return players[index] end,
  print = function(message, settings) printed[#printed + 1] = { message = message, settings = settings } end,
}
_G.storage = { tasks = { queue = {} }, companion = { player_index = 1, entity = codex.character } }

local thoughts = require("scripts.thoughts")
local companion = require("scripts.companion")
local PANEL = "agentic_companion_thoughts"

local registered = {}
thoughts.register_rpcs({ register = function(name, fn) registered[name] = fn end })
check(registered.say == thoughts.say and registered.say_now == thoughts.say_now,
  "register_rpcs registers say and say_now")

-- Lazy storage: say works before init created it.
local result = thoughts.say({ role = "pilot", text = "walking to the iron patch" })
check(storage.thoughts and #storage.thoughts.lines == 1 and result.lines == 1, "say creates storage lazily")
check(#printed == 0, "say prints nothing to chat: the panel alone shows the line")

local panel = codex.gui.left[PANEL]
check(panel and panel.valid and panel.type == "frame", "Codex gets a left-side frame")
check(viewer.gui.left[PANEL] == nil, "other players get no panel")
local rows = shown(panel)
check(#rows == 2 and rows[1] == "NOW: -" and rows[2] == "[Pilot] walking to the iron patch"
  and panel.children[6].style.font_color.b == 1.00,
  "panel shows the NOW line then the recent lines, coloured per role")
local writes = caption_writes
thoughts.refresh()
check(caption_writes == writes and codex.gui.left[PANEL] == panel and panel.children[1].valid,
  "a refresh with nothing new rewrites no label and keeps the panel's elements")

thoughts.say_now({ text = "smelt iron plates" })
panel = codex.gui.left[PANEL]
check(storage.thoughts.now == "smelt iron plates" and shown(panel)[1] == "NOW: smelt iron plates",
  "say_now sets the strategist's NOW line on top")
check(#printed == 0, "say_now prints nothing to chat")

for i = 1, 10 do thoughts.say({ role = "strategist", text = "thought " .. i }) end
panel = codex.gui.left[PANEL]
check(#storage.thoughts.lines == 8 and storage.thoughts.lines[1].text == "thought 3"
  and storage.thoughts.lines[8].text == "thought 10", "storage keeps the last 8 lines")
check(#shown(panel) == 9 and shown(panel)[9] == "[Strategist] thought 10", "panel shows NOW plus 8 lines")

-- Validation.
check(not pcall(thoughts.say, { role = "bob", text = "x" }), "unknown role is rejected")
check(not pcall(thoughts.say, { role = "pilot", text = "" }), "empty text is rejected")
check(not pcall(thoughts.say, { role = "pilot", text = string.rep("a", 601) }), "text over 600 characters is rejected")
check(pcall(thoughts.say, { role = "pilot", text = string.rep("\195\169", 600) }),
  "600 multibyte characters are accepted")
local long_line = panel and shown(codex.gui.left[PANEL])[9]
check(long_line and #long_line < 600 and long_line:sub(-3) == "...", "panel truncates long lines on a character boundary")
thoughts.say({ role = "supervisor", text = "line one\nline two" })
check(storage.thoughts.lines[8].text == "line one line two", "newlines become spaces")
thoughts.say_now({ text = "" })
check(storage.thoughts.now == nil, "empty say_now clears the NOW line")

-- Upgrade and join rebuild the panel from storage.
codex.gui.left[PANEL].valid = false
codex.gui.left[PANEL] = nil
thoughts.init()
check(codex.gui.left[PANEL] and #shown(codex.gui.left[PANEL]) == 9, "init rebuilds the panel from storage")
local joiner = make_player(3, "Codex", true)
players[3] = joiner
thoughts.on_player_joined({ player_index = 3 })
check(joiner.gui.left[PANEL] and #shown(joiner.gui.left[PANEL]) == 9, "player join rebuilds the panel")
players[3] = nil
thoughts.on_player_joined({ player_index = 2 })
check(viewer.gui.left[PANEL] == nil, "a joining viewer gets no panel")

-- The panel never starts a human hold.
companion.poll_human_activity(false)
check(opened_writes == 0 and codex.opened_gui_type == defines.gui_type.none, "panel never sets player.opened")
check(companion.human_control() == false, "showing thoughts does not start a human hold")

os.exit(failures == 0 and 0 or 1)
