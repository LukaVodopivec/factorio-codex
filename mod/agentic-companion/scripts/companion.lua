-- The sole persistent physical body is Factorio's real connected LuaPlayer
-- named Codex. The mod never creates, replaces or teleports that character.
local M = {}

local CODEX_LABEL = "Codex"
local COLOR = { r = 0.30, g = 0.79, b = 0.69, a = 1 }

local LABEL_OFFSET = { 0, -2.9 }
local MAP_TAG_MOVE_SQ = 9

local function get_player(index)
  if not index then return nil end
  return game.get_player(index)
end

local function is_native_codex(player)
  return player and player.valid ~= false and player.connected ~= false
    and player.name == CODEX_LABEL
    -- In map or remote view the client's input drives the view, not the
    -- body, and the character stays script-controllable (native 2.0.77).
    and (player.controller_type == defines.controllers.character
      or player.controller_type == defines.controllers.remote)
    and player.character and player.character.valid
end

local function enforce_normal_speed(ent)
  if not (ent and ent.valid) then return end
  if ent.character_running_speed_modifier ~= 0 then ent.character_running_speed_modifier = 0 end
end

function M.enforce_normal_speed()
  enforce_normal_speed(M.get())
end

-- Spectators have no character to move. Keep their cameras on Codex while
-- leaving the native Codex player's physical movement untouched.
function M.follow_spectators()
  local ent = M.get()
  if not ent then return end
  for _, player in pairs(game.connected_players) do
    if player.controller_type == defines.controllers.spectator then
      pcall(function() player.teleport(ent.position, ent.surface) end)
    end
  end
end

function M.get()
  local rec = storage.companion
  if not rec then return nil end

  local player = get_player(rec.player_index)
  local ent = rec.entity
  if is_native_codex(player) and player.character == ent then
    enforce_normal_speed(ent)
    return ent
  end
  return nil
end

function M.record()
  return storage.companion
end

-- Human takeover. Real control input on the Codex client holds the body until
-- 300 ticks after the last of it; storage.tasks.human_activity_tick is that
-- last input. Input is a linked custom input (scripts/human_inputs.lua), an
-- open GUI, an item in the cursor, or walking the mod did not command; during
-- a hold, any walking or mining. Mouse hover, camera movement and afk_time are
-- not input: afk_time also resets when the bot's own walking scrolls the view
-- under a resting cursor (native 2.0.77). Everything counts only for the
-- connected Codex player in its character: map or remote view moves the view,
-- so the bot keeps working while the owner looks around.
local HUMAN_RELEASE_IDLE_TICKS = 300
local NEVER_ACTIVE_IDLE_TICKS = 2147483647

local function codex_player()
  local rec = storage.companion
  local player = rec and get_player(rec.player_index)
  if player and player.valid ~= false and player.connected then return player end
  return nil
end
local function in_character(player)
  return player.controller_type == defines.controllers.character and player.character and player.character.valid
end
local function note_activity()
  if storage.tasks then storage.tasks.human_activity_tick = game.tick end
end

-- A linked custom input or on_gui_opened (the mod never opens a GUI).
function M.on_human_input(event)
  local rec = storage.companion
  if not (rec and rec.player_index and event.player_index == rec.player_index) then return end
  local player = codex_player()
  if player and in_character(player) then note_activity() end
end

-- Called once per tick before the dispatcher decides the hold and before the
-- mod writes any body state. A press event marks only the moment of a press;
-- this keeps the hold alive while a key is held down or a GUI stays open.
function M.poll_human_activity(holding)
  local player = codex_player()
  if not (player and in_character(player)) then return end
  local body = player.character
  local cursor = player.cursor_stack
  local active = player.opened_gui_type ~= defines.gui_type.none or (cursor and cursor.valid_for_read) or false
  local walking = body.walking_state
  if walking and walking.walking then
    -- The mod is the only script writer of walking_state and records each
    -- write (human_inputs.set_walking): walking it did not command, or in
    -- another direction, is the client's movement keys.
    local commanded = storage.tasks and storage.tasks.commanded_walk
    if holding or not (commanded and commanded.walking) or commanded.direction ~= walking.direction then active = true end
  end
  if holding and body.mining_state and body.mining_state.mining then active = true end
  if active then note_activity() end
end

-- Returns held, idle ticks. A missing character or any controller other than
-- character or remote keeps the hold, so queued work stays parked instead of
-- failing for want of a body. Unreadable state and a disconnected player
-- never hold.
function M.human_control()
  local ok, held, idle = pcall(function()
    local player = codex_player()
    if not player then return false end
    local last = storage.tasks and storage.tasks.human_activity_tick
    local idle = last and math.max(0, game.tick - last) or NEVER_ACTIVE_IDLE_TICKS
    local has_body = player.character and player.character.valid
    if has_body and player.controller_type == defines.controllers.remote then return false, idle end
    if not in_character(player) then return true, idle end
    return idle < HUMAN_RELEASE_IDLE_TICKS, idle
  end)
  if not ok then return false end
  return held, idle
end

function M.require_companion()
  local ent = M.get()
  if not ent then
    error("companion 'Codex' does not exist — call connect_status first")
  end
  return ent
end

-- Floating name tag that follows the character; self-healed periodically.
local function attach_label(rec, ent)
  pcall(function()
    if rec.label and rec.label.valid then rec.label.destroy() end
  end)
  rec.label = nil
  local args = {
    text = CODEX_LABEL,
    surface = ent.surface,
    color = COLOR,
    scale = 1.4,
    alignment = "center",
    scale_with_zoom = true,
  }
  local ok, obj = pcall(function()
    args.target = { entity = ent, offset = LABEL_OFFSET }
    return rendering.draw_text(args)
  end)
  if not ok or not obj then
    ok, obj = pcall(function()
      args.target = ent
      args.target_offset = LABEL_OFFSET
      return rendering.draw_text(args)
    end)
  end
  if ok and obj then rec.label = obj end
end

local function bind_native_player(player)
  if not is_native_codex(player) then return false end

  local rec = storage.companion or {}
  local previous = rec.entity
  if previous and previous.valid and previous ~= player.character then
    if rec.player_index then
      error("refusing a second Codex body")
    end
    -- One-time old-save migration: remove the prior standalone body rather
    -- than retaining a second character beside the native player.
    previous.destroy()
  end
  storage.companion = rec
  rec.player_index = player.index
  rec.entity = player.character
  rec.dead = nil
  rec.disconnected = nil
  rec.removed = nil
  rec.entity.color = COLOR
  enforce_normal_speed(rec.entity)
  attach_label(rec, rec.entity)
  M.update_map_tag()
  return true
end

-- All non-Codex clients are viewers. Factorio owns the controller change;
-- destroying the detached join character prevents a second physical body or
-- a second inventory from surviving the transition.
local function make_viewer(player)
  if not player or player.valid == false or player.name == CODEX_LABEL then return end
  local detached = player.character
  if player.controller_type ~= defines.controllers.spectator then
    player.set_controller({ type = defines.controllers.spectator })
  end
  if detached and detached.valid then detached.destroy() end
end

function M.on_player_available(event)
  local player = get_player(event.player_index)
  if not player then return end
  if player.name == CODEX_LABEL then
    bind_native_player(player)
  else
    make_viewer(player)
  end
end

function M.on_player_left(event)
  local rec = storage.companion
  if not rec or rec.player_index ~= event.player_index then return end
  rec.entity = nil
  rec.disconnected = true
  M.update_map_tag()
end

function M.on_player_removed(event)
  local rec = storage.companion
  if not rec or rec.player_index ~= event.player_index then return end
  rec.entity = nil
  rec.player_index = nil
  rec.disconnected = nil
  rec.removed = true
  M.update_map_tag()
end

function M.on_player_died(event)
  local rec = storage.companion
  if not rec or rec.player_index ~= event.player_index then return end
  rec.dead = true
  rec.entity = nil
  rec.disconnected = nil
  M.update_map_tag()
end

-- A respawn is accepted only after Factorio has created the native player's
-- character and raised its lifecycle event. This mod has no respawn path.
function M.on_player_respawned(event)
  M.on_player_available(event)
end

-- The map/minimap marker can't move, so re-pin it after the body drifts.
-- Runs on_nth_tick (wired in control.lua) and must never raise.
function M.update_map_tag()
  local rec = storage.companion
  if rec then
    local ent = rec.entity
    local alive = ent and ent.valid
    local tag = rec.map_tag
    local tag_valid = false
    pcall(function() tag_valid = tag and tag.valid end)

    if not alive then
      if tag_valid then pcall(function() tag.destroy() end) end
      rec.map_tag = nil
    else
      local label_valid = false
      pcall(function() label_valid = rec.label and rec.label.valid end)
      if not label_valid then attach_label(rec, ent) end

      local keep = false
      if tag_valid then
        local p = tag.position
        local dx, dy = p.x - ent.position.x, p.y - ent.position.y
        keep = dx * dx + dy * dy < MAP_TAG_MOVE_SQ
        if not keep then pcall(function() tag.destroy() end) end
      end
      if not keep then
        rec.map_tag = nil
        pcall(function()
          rec.map_tag = ent.force.add_chart_tag(ent.surface, {
            position = ent.position,
            text = CODEX_LABEL,
            icon = { type = "virtual", name = "signal-A" },
          })
        end)
      end
    end
  end
end


function M.connect()
  local existing = M.get()
  if existing then
    return {
      position = { x = existing.position.x, y = existing.position.y },
    }
  end
  for _, player in pairs(game.connected_players) do
    if is_native_codex(player) then
      bind_native_player(player)
      local ent = player.character
      return { position = { x = ent.position.x, y = ent.position.y } }
    end
  end
  error("native player 'Codex' is not connected with a living character")
end

-- Kept for old control.lua/save rollback compatibility. Despite the legacy
-- name it only binds the native player and can never create a character.
M.spawn = M.connect

-- Fresh and existing surfaces remain peaceful and generate no enemy bases.
-- Shared wiring calls this on init/configuration and surface creation.
function M.enforce_peaceful_world()
  game.map_settings.enemy_expansion.enabled = false
  for _, surface in pairs(game.surfaces) do
    surface.peaceful_mode = true
    local settings = surface.map_gen_settings
    settings.autoplace_controls = settings.autoplace_controls or {}
    settings.autoplace_controls["enemy-base"] = {
      frequency = 0,
      size = 0,
      richness = 0,
    }
    surface.map_gen_settings = settings
  end
end

return M
