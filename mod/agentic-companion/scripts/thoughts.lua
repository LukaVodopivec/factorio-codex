-- Thought feed: the roles' reasoning shown in game. Output only: it fills a
-- small left-side panel on the Codex client (never chat, which would show
-- every line twice), and nothing here reads chat or controls the body. The panel lives in player.gui.left and is
-- never assigned to player.opened, so opened_gui_type stays none and it raises
-- no on_gui_opened: it cannot start a human hold (companion.human_control).
local benchmark = require("scripts.benchmark")
local M = {}

local CODEX_NAME = "Codex"
local PANEL = "agentic_companion_thoughts"
local MAX_TEXT_CHARS = 600
local MAX_LINES = 8
local PANEL_LINE_CHARS = 200
local PANEL_WIDTH = 420

local ROLES = {
  strategist = { label = "Strategist", color = { r = 1.00, g = 0.70, b = 0.25 } },
  pilot = { label = "Pilot", color = { r = 0.45, g = 0.78, b = 1.00 } },
  mining = { label = "Mining advisor", color = { r = 0.65, g = 1.00, b = 0.50 } },
  logistics = { label = "Logistics advisor", color = { r = 0.95, g = 0.55, b = 0.90 } },
  supervisor = { label = "Supervisor", color = { r = 0.75, g = 0.75, b = 0.75 } },
}

local function data()
  storage.thoughts = storage.thoughts or { now = nil, lines = {} }
  return storage.thoughts
end

-- Character count of UTF-8 text: every byte that is not a continuation byte.
local function char_count(text)
  return select(2, text:gsub("[^\128-\191]", ""))
end

-- The first n characters, cut on a UTF-8 boundary.
local function head(text, n)
  if char_count(text) <= n then return text end
  local seen = 0
  for i = 1, #text do
    local byte = text:byte(i)
    if byte < 128 or byte >= 192 then
      seen = seen + 1
      if seen > n then return text:sub(1, i - 1) .. "..." end
    end
  end
  return text
end

local function clean_text(params, allow_empty)
  local text = params.text
  if type(text) ~= "string" then error("text must be a string") end
  text = text:gsub("[\r\n\t]+", " ")
  if text == "" and not allow_empty then error("text must not be empty") end
  if char_count(text) > MAX_TEXT_CHARS then
    error("text must be at most " .. MAX_TEXT_CHARS .. " characters; split longer text")
  end
  return text
end

-- The panel's labels, built once in this order: four trial lines, NOW, then
-- the recent thought lines. A refresh only rewrites captions that changed and
-- hides empty slots; clearing and re-adding every label each second made the
-- panel flicker while the trial counters moved.
local TRIAL_SLOTS = 4
local SLOTS = TRIAL_SLOTS + 1 + MAX_LINES
local function slot_name(index) return "slot_" .. index end

-- caption "" hides the slot. The role label is part of the caption, so an
-- unchanged caption keeps its colour.
local function set_slot(frame, index, caption, color)
  local label = frame[slot_name(index)]
  if label.caption == caption then return end
  label.caption = caption
  label.visible = caption ~= ""
  if color then label.style.font_color = color end
end

-- Builds or updates the panel for one player; only the connected player named
-- Codex (or a spectator) has one.
local function render(player)
  if not (player and player.valid and player.connected
    and (player.name == CODEX_NAME or player.controller_type == defines.controllers.spectator)) then return end
  local left = player.gui.left
  local frame = left[PANEL]
  if not (frame and frame.valid) then
    frame = left.add({ type = "frame", name = PANEL, caption = "Codex thinking", direction = "vertical" })
  end
  if not frame[slot_name(SLOTS)] then
    -- New, or built by an older version: lay out the slots once.
    frame.clear()
    frame.style.width = PANEL_WIDTH + 24
    for index = 1, SLOTS do
      local label = frame.add({ type = "label", name = slot_name(index), caption = "" })
      label.style.single_line = false
      label.style.maximal_width = PANEL_WIDTH
      label.visible = false
    end
  end
  local t = data()
  local trial = benchmark.display()
  local rows = {}
  if trial then
    rows[1] = head(trial.label, PANEL_LINE_CHARS) .. " | " .. trial.status .. " | "
      .. math.floor(trial.remaining_seconds / 60) .. ":" .. string.format("%02d", trial.remaining_seconds % 60)
    local m = setmetatable({}, { __index = function(_, key) return trial.metrics[key] or 0 end })
    rows[2] = "Research: " .. trial.research .. " packs | machine-made " .. trial.made
      .. " (" .. string.format("%.1f", trial.made_per_minute) .. "/min) | raw " .. trial.raw
    rows[3] = "Plates: Fe " .. m["iron-plate"] .. ", Cu " .. m["copper-plate"] .. ", steel " .. m["steel-plate"]
      .. " | gears " .. m["iron-gear-wheel"] .. ", circuits " .. m["electronic-circuit"]
    rows[4] = storage.benchmark.summary and head(storage.benchmark.summary, PANEL_LINE_CHARS) or nil
  end
  for index = 1, TRIAL_SLOTS do set_slot(frame, index, rows[index] or "") end
  set_slot(frame, TRIAL_SLOTS + 1, "NOW: " .. head(t.now or "-", PANEL_LINE_CHARS), ROLES.strategist.color)
  for index = 1, MAX_LINES do
    local line = t.lines[index]
    local role = line and ROLES[line.role]
    set_slot(frame, TRIAL_SLOTS + 1 + index,
      line and ("[" .. role.label .. "] " .. head(line.text, PANEL_LINE_CHARS)) or "", role and role.color)
  end
end

local function render_all()
  for _, player in pairs(game.connected_players) do render(player) end
end
M.refresh = render_all

-- say {role, text}: one panel line.
function M.say(params)
  local role = ROLES[params.role]
  if not role then error("role must be strategist, pilot, mining, logistics or supervisor") end
  local text = clean_text(params, false)
  local lines = data().lines
  lines[#lines + 1] = { role = params.role, text = text, tick = game.tick }
  while #lines > MAX_LINES do table.remove(lines, 1) end
  render_all()
  return { tick = game.tick, lines = #lines }
end

-- say_now {text}: The strategist's current NOW line at the top of the panel; empty
-- text clears it.
function M.say_now(params)
  local text = clean_text(params, true)
  data().now = text ~= "" and text or nil
  render_all()
  return { tick = game.tick }
end

-- on_init / on_configuration_changed: create storage and rebuild the panel
-- (an upgrade keeps the old version's GUI elements).
function M.init()
  data()
  render_all()
end

-- on_player_joined_game / on_player_created: the Codex client gets its panel.
function M.on_player_joined(event)
  render(game.get_player(event.player_index))
end

function M.register_rpcs(rpc)
  rpc.register("say", M.say)
  rpc.register("say_now", M.say_now)
end

return M
