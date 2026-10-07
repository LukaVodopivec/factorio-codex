-- Timelapse: 4K frames of the growing factory for the owner's video, from GO to
-- the first rocket launch. The Codex client renders each frame
-- (take_screenshot by_player; a headless server renders nothing) into its
-- script-output/timelapse/<folder>/. Output only: no frame or camera state
-- reaches the MCP tools, and the supervisor starts it over RPC.
--
-- The camera frames the largest cluster of production machines on Nauvis
-- (outposts, pipes and pole lines never count), and only ever zooms out:
-- when the cluster passes 90% of the view it eases out until it fills 80%,
-- between zoom 1 and 0.25. The first rocket launch is caught at about 15
-- frames a second, closer on the silo, then a few overview frames end it.
local registry = require("scripts.registry")
local M = {}

local PLAYER = "Codex"
local WIDTH, HEIGHT, TILE = 3840, 2160, 32
local PERIOD = 300            -- one frame every 5 game seconds
local LAUNCH_PERIOD = 4       -- the first rocket launch, about 15 frames a second
local LAUNCH_TICKS = 1200     -- a launch takes about 1,163 ticks to leave the screen
local ENDING_FRAMES = 36      -- overview frames after the launch, then capture ends
local MAX_ZOOM, MIN_ZOOM, SILO_ZOOM = 1.0, 0.25, 0.6
local CELL = 48               -- machines in touching 48-tile cells are one cluster
local JOIN_MACHINES, JOIN_GAP = 8, 80 -- a cluster this big this close joins the frame
local GROW_AT, FIT_TO = 0.9, 0.8
local EASE, MAX_STEP = 0.194, 0.02    -- per frame, in log zoom
local ENDING_STEP = 0.06              -- the pull-back after the launch, in log zoom
local CENTRE_EASE = 0.1
local MAX_MOVE = 0.03                 -- the centre moves at most this share of the view a frame
local SWITCH_RATIO = 1.5              -- another cluster becomes the main one only this much bigger

local TYPES = {}
for kind in pairs(registry.PRODUCTIVE_TYPES) do TYPES[#TYPES + 1] = kind end
table.sort(TYPES)

local function data() return storage and storage.timelapse end

-- The box (with padding) of the largest machine cluster plus any cluster of
-- JOIN_MACHINES or more within JOIN_GAP tiles of it; nil without machines.
function M.core_box(machines, previous)
  local cells, keys = {}, {}
  for _, m in ipairs(machines) do
    local cx, cy = math.floor(m.position.x / CELL), math.floor(m.position.y / CELL)
    local key = cx .. ":" .. cy
    local cell = cells[key]
    if not cell then
      cell = { cx = cx, cy = cy, count = 0 }
      cells[key], keys[#keys + 1] = cell, key
    end
    cell.count = cell.count + 1
    local x, y = m.position.x, m.position.y
    cell.l, cell.r = math.min(cell.l or x, x), math.max(cell.r or x, x)
    cell.t, cell.b = math.min(cell.t or y, y), math.max(cell.b or y, y)
  end
  if #keys == 0 then return nil end
  table.sort(keys)
  local clusters, seen = {}, {}
  for _, start in ipairs(keys) do
    if not seen[start] then
      local c = { count = 0, keys = {} }
      local stack = { start }
      seen[start] = true
      while #stack > 0 do
        local key = table.remove(stack)
        local cell = cells[key]
        c.keys[key] = true
        c.count = c.count + cell.count
        c.l, c.r = math.min(c.l or cell.l, cell.l), math.max(c.r or cell.r, cell.r)
        c.t, c.b = math.min(c.t or cell.t, cell.t), math.max(c.b or cell.b, cell.b)
        for dx = -1, 1 do
          for dy = -1, 1 do
            local key = (cell.cx + dx) .. ":" .. (cell.cy + dy)
            if cells[key] and not seen[key] then seen[key] = true; stack[#stack + 1] = key end
          end
        end
      end
      clusters[#clusters + 1] = c
    end
  end
  -- The main cluster stays the one sharing a cell with the previous main
  -- cluster until another is SWITCH_RATIO times bigger: no cutting back and forth.
  local main = clusters[1]
  for _, c in ipairs(clusters) do if c.count > main.count then main = c end end
  local incumbent
  for _, c in ipairs(clusters) do
    for key in pairs(previous or {}) do
      if c.keys[key] and (not incumbent or c.count > incumbent.count) then incumbent = c end
    end
  end
  if incumbent and incumbent.count * SWITCH_RATIO > main.count then main = incumbent end
  local box = { l = main.l, r = main.r, t = main.t, b = main.b }
  for _, c in ipairs(clusters) do
    if c ~= main and c.count >= JOIN_MACHINES then
      local gx = math.max(0, c.l - main.r, main.l - c.r)
      local gy = math.max(0, c.t - main.b, main.t - c.b)
      if gx <= JOIN_GAP and gy <= JOIN_GAP then
        box.l, box.r = math.min(box.l, c.l), math.max(box.r, c.r)
        box.t, box.b = math.min(box.t, c.t), math.max(box.b, c.b)
      end
    end
  end
  -- Positions are machine centres: pad for their size and some ground.
  local w, h = box.r - box.l, box.b - box.t
  local px, py = math.max(12, 0.05 * w), math.max(12, 0.05 * h)
  return { l = box.l - px, r = box.r + px, t = box.t - py, b = box.b + py }, main.keys
end

local function fit(box, fill)
  local w, h = box.r - box.l, box.b - box.t
  return math.min(WIDTH * fill / (TILE * w), HEIGHT * fill / (TILE * h))
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- One frame's camera: the overview zoom target only falls, the launch closes
-- in on the silo (never wider than the overview), and the zoom eases toward
-- its target in log space. The centre eases toward the box centre, kept so
-- the box stays in view, and never moves more than MAX_MOVE of the view a
-- frame: a switch of cluster or the pull-back after the launch glides.
function M.camera(s, box, focus)
  if box then
    local vw, vh = WIDTH / (TILE * s.zoom), HEIGHT / (TILE * s.zoom)
    local base = s.overview_target or MAX_ZOOM
    if s.phase ~= "launch" and ((box.r - box.l) > GROW_AT * vw or (box.b - box.t) > GROW_AT * vh) then
      base = math.min(base, clamp(fit(box, FIT_TO), MIN_ZOOM, MAX_ZOOM))
    end
    s.overview_target = base
  end
  local overview = s.overview_target or MAX_ZOOM
  s.target = s.phase == "launch" and math.max(SILO_ZOOM, overview) or overview
  local cap = s.phase == "ending" and ENDING_STEP or MAX_STEP
  local step = clamp((math.log(s.target) - math.log(s.zoom)) * EASE, -cap, cap)
  if s.phase == "ending" then step = clamp(math.log(s.target) - math.log(s.zoom), -cap, cap) end
  s.zoom = clamp(math.exp(math.log(s.zoom) + step), MIN_ZOOM, MAX_ZOOM)
  local goal = focus
  if not goal and box then goal = { x = (box.l + box.r) / 2, y = (box.t + box.b) / 2 } end
  if not goal then return end
  if not s.centre then s.centre = { x = goal.x, y = goal.y }; return end
  local want = { x = s.centre.x + (goal.x - s.centre.x) * CENTRE_EASE, y = s.centre.y + (goal.y - s.centre.y) * CENTRE_EASE }
  local vw, vh = WIDTH / (TILE * s.zoom), HEIGHT / (TILE * s.zoom)
  if box and s.phase ~= "launch" then
    want.x = (box.r - box.l <= vw) and clamp(want.x, box.r - vw / 2, box.l + vw / 2) or goal.x
    want.y = (box.b - box.t <= vh) and clamp(want.y, box.b - vh / 2, box.t + vh / 2) or goal.y
  end
  -- Before the first machine the camera keeps up with the walking body; the
  -- first box after that is where the body built it.
  if not box and s.phase ~= "launch" then s.centre = { x = goal.x, y = goal.y }; return end
  if not s.had_box and box then s.had_box = true; s.centre = { x = want.x, y = want.y }; return end
  s.centre.x = s.centre.x + clamp(want.x - s.centre.x, -MAX_MOVE * vw, MAX_MOVE * vw)
  s.centre.y = s.centre.y + clamp(want.y - s.centre.y, -MAX_MOVE * vh, MAX_MOVE * vh)
end

-- The file name carries the game tick, so the video can show the time each
-- frame was taken (the frame number alone says nothing about the gaps).
local function shoot(s, player, surface)
  s.frame = s.frame + 1
  game.take_screenshot({ by_player = player, surface = surface, position = { x = s.centre.x, y = s.centre.y },
    resolution = { WIDTH, HEIGHT }, zoom = s.zoom,
    path = string.format("timelapse/%s/frame_%06d_t%d.jpg", s.folder, s.frame, game.tick), quality = 90,
    daytime = 0, hide_clouds = true, hide_fog = true, show_gui = false, show_entity_info = false,
    anti_alias = false, force_render = true })
end

function M.on_tick(tick)
  local s = data()
  if not (s and s.active) or tick < s.next_tick then return end
  local launching = s.phase == "launch" and tick < s.launch_until
  if s.phase == "launch" and not launching then s.phase, s.ending = "ending", ENDING_FRAMES end
  s.next_tick = tick + (launching and LAUNCH_PERIOD or PERIOD)
  local player = game.get_player(PLAYER)
  local surface = game.surfaces.nauvis
  -- Nobody to render it: this frame is skipped, not numbered.
  if not (player and player.connected and surface) then return end
  -- The launch only looks at the silo: no machine pass every 4 ticks.
  local box
  if not launching then box, s.main_keys = M.core_box(registry.machines(TYPES, surface.index), s.main_keys) end
  local focus = launching and s.silo or nil
  if not box and not focus then
    local body = player.character
    focus = body and body.valid and body.surface == surface and body.position or nil
  end
  M.camera(s, box, focus)
  if not s.centre then return end
  shoot(s, player, surface)
  if s.phase == "ending" then
    s.ending = s.ending - 1
    if s.ending <= 0 then s.active, s.phase, s.finished_tick = false, "done", tick end
  end
end

-- The first launch an own silo orders (a rocket carrying the body counts).
function M.on_rocket_launch_ordered(event)
  local s = data()
  if not (s and s.active and s.phase == "overview") then return end
  local silo = event.rocket_silo
  local player = game.get_player(PLAYER)
  if not (silo and silo.valid and player and silo.force == player.force
    and silo.surface.index == game.surfaces.nauvis.index) then return end
  s.phase, s.launch_until, s.next_tick = "launch", game.tick + LAUNCH_TICKS, game.tick
  s.silo = { x = silo.position.x, y = silo.position.y }
end

local function status(s)
  if not s then return { active = false } end
  return { active = s.active, folder = s.folder, phase = s.phase, frames = s.frame, zoom = s.zoom,
    centre = s.centre, started_tick = s.started_tick, finished_tick = s.finished_tick }
end

-- Supervisor RPC: {action = "start", folder} begins (or keeps) a capture,
-- "status" reads it, "stop" ends it.
function M.rpc(params)
  params = params or {}
  local action = params.action or "status"
  local s = data()
  if action == "start" then
    local folder = params.folder
    if type(folder) ~= "string" or not folder:match("^[%w_%-]+$") or #folder > 64 then
      error("timelapse start needs folder: letters, digits, _ or -", 0)
    end
    -- The same folder resumes (or stays finished); a folder used before in
    -- this game is refused: its frames are never overwritten.
    if s and s.folder == folder then
      if s.phase ~= "done" then s.active = true end
      return status(s)
    end
    storage.timelapse_folders = storage.timelapse_folders or {}
    if storage.timelapse_folders[folder] then error("timelapse folder " .. folder .. " was used before in this game", 0) end
    storage.timelapse_folders[folder] = true
    storage.timelapse = { active = true, folder = folder, frame = 0, zoom = MAX_ZOOM, target = MAX_ZOOM,
      phase = "overview", next_tick = game.tick, started_tick = game.tick }
    return status(storage.timelapse)
  elseif action == "stop" then
    if s then s.active = false end
    return status(s)
  elseif action == "status" then
    return status(s)
  end
  error("timelapse action must be start, stop or status", 0)
end

return M
