-- Offline tests for the timelapse camera (scripts/timelapse.lua): frames
-- only for the connected Codex client and only once started, the frame box
-- is the main machine cluster (an outpost far off never widens it), the zoom
-- only falls and eases, staying in [0.25, 1], the first own rocket launch is
-- caught every 4 ticks near the silo, and a few overview frames end it.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local machines = {}
package.loaded["scripts.registry"] = {
  PRODUCTIVE_TYPES = { ["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true },
  machines = function() return machines end,
}
local force = {}
local player = { connected = true, force = force, character = { valid = true, position = { x = 5, y = 5 } } }
local shots = {}
_G.storage = {}
_G.game = { tick = 0, get_player = function() return player end,
  take_screenshot = function(args) shots[#shots + 1] = args end }
local nauvis = { index = 1 }
game.surfaces = { nauvis = nauvis }
player.character.surface = nauvis
local timelapse = require("scripts.timelapse")

local function run_to(tick)
  while game.tick < tick do game.tick = game.tick + 1; timelapse.on_tick(game.tick) end
end

timelapse.on_tick(0)
check(#shots == 0, "nothing is captured before the supervisor starts it")
check(not pcall(timelapse.rpc, { action = "start", folder = "../x" }), "a folder outside timelapse/ is refused")
local started = timelapse.rpc({ action = "start", folder = "run-1" })
check(started.active and started.frames == 0, "start begins an active capture")
run_to(1)
check(#shots == 1 and shots[1].by_player == player and shots[1].path == "timelapse/run-1/frame_000001_t1.jpg"
  and shots[1].resolution[1] == 3840 and shots[1].resolution[2] == 2160 and shots[1].zoom == 1
  and shots[1].position.x == 5 and shots[1].daytime == 0 and shots[1].show_gui == false,
  "before any machine the first 4K frame centres on the body at zoom 1, daylight, no GUI")
run_to(300)
check(#shots == 1, "the next frame waits five game seconds")
player.connected = false
run_to(301)
check(#shots == 1, "with the Codex client away no frame is taken and none is numbered")
player.connected = true
player.character.position = { x = 205, y = 5 }
run_to(601)
check(shots[#shots].position.x == 205, "before the first machine the camera keeps up with the walking body")

-- A 300 x 100 base of machines and a far outpost of 5 machines.
for x = 0, 300, 10 do for y = 0, 100, 25 do machines[#machines + 1] = { position = { x = x, y = y } } end end
for i = 1, 5 do machines[#machines + 1] = { position = { x = 1000 + i, y = 0 } } end
local box = timelapse.core_box(machines)
check(box.r < 400 and box.l > -40, "a small far outpost never widens the frame box")
local zooms = {}
for _ = 1, 200 do run_to(game.tick + 300); zooms[#zooms + 1] = shots[#shots].zoom end
local falling, eased = true, true
for i = 2, #zooms do
  if zooms[i] > zooms[i - 1] + 1e-9 then falling = false end
  if math.abs(math.log(zooms[i]) - math.log(zooms[i - 1])) > 0.0201 then eased = false end
end
local view_w = 3840 / (32 * zooms[#zooms])
check(falling and eased and zooms[#zooms] >= 0.25 and view_w >= box.r - box.l,
  string.format("the zoom only falls, in small steps, until the base fits (zoom %.3f)", zooms[#zooms]))
check(shots[#shots].path == string.format("timelapse/run-1/frame_%06d_t%d.jpg", #shots, game.tick),
  "frames are numbered without gaps and name the tick they were taken")

-- A huge base: the zoom stops at 0.25.
for x = 0, 2000, 40 do machines[#machines + 1] = { position = { x = x, y = 50 } } end
for _ = 1, 200 do run_to(game.tick + 300) end
check(math.abs(shots[#shots].zoom - 0.25) < 1e-9, "the zoom never goes wider than 0.25")

-- Another force's launch is ignored; the first own launch is caught every 4 ticks near the silo.
local before = #shots
timelapse.on_rocket_launch_ordered({ rocket_silo = { valid = true, force = force, surface = { index = 2 }, position = { x = 50, y = 50 } } })
check(timelapse.rpc({ action = "status" }).phase == "overview", "a launch from another planet's silo is not the timelapse's launch")
timelapse.on_rocket_launch_ordered({ rocket_silo = { valid = true, force = {}, surface = nauvis, position = { x = 50, y = 50 } } })
check(timelapse.rpc({ action = "status" }).phase == "overview", "a launch by another force changes nothing")
timelapse.on_rocket_launch_ordered({ rocket_silo = { valid = true, force = force, surface = nauvis, position = { x = 150, y = 60 } } })
run_to(game.tick + 600)
-- A second order mid-launch neither restarts nor extends the burst.
timelapse.on_rocket_launch_ordered({ rocket_silo = { valid = true, force = force, surface = nauvis, position = { x = 900, y = 900 } } })
run_to(game.tick + 600)
local launch = #shots - before
local last = shots[#shots]
check(launch >= 290 and launch <= 302 and last.zoom > 0.5 and math.abs(last.position.x - 150) < 5,
  string.format("the launch is %d frames every 4 ticks, closing in on the silo (zoom %.2f)", launch, last.zoom))
for _ = 1, 40 do run_to(game.tick + 300) end
local done = timelapse.rpc({ action = "status" })
check(done.phase == "done" and not done.active and math.abs(shots[#shots].zoom - 0.25) < 1e-6,
  string.format("after the launch the overview frames pull all the way back (zoom %.3f) and the capture ends", shots[#shots].zoom))
local glide = true
for i = before + 2, #shots do
  local a, b = shots[i - 1], shots[i]
  local vw = 3840 / (32 * b.zoom) -- the cap applies to the frame's own view
  if math.abs(b.position.x - a.position.x) > 0.031 * vw then glide = false end
end
check(glide, "the camera never jumps: into the launch and back out it moves at most 3% of the view a frame")
local again = timelapse.rpc({ action = "start", folder = "run-1" })
check(again.phase == "done" and again.frames == #shots and not again.active,
  "starting a finished folder again keeps it finished: its frames are never overwritten")
local count = #shots
run_to(game.tick + 3000)
check(#shots == count, "nothing more is captured once it is done")

-- A second cluster that briefly outgrows the main one does not steal the
-- camera; one that is clearly bigger takes it, gliding there.
local main_a, main_b = {}, {}
for x = 0, 90, 10 do for y = 0, 40, 10 do main_a[#main_a + 1] = { position = { x = x, y = y } } end end
local box, key = timelapse.core_box(main_a, nil)
for x = 400, 490, 10 do for y = 0, 50, 10 do main_b[#main_b + 1] = { position = { x = x, y = y } } end end
local both = {}
for _, m in ipairs(main_a) do both[#both + 1] = m end
for _, m in ipairs(main_b) do both[#both + 1] = m end
local kept, kept_key = timelapse.core_box(both, key)
check(kept.r < 200 and kept_key["0:0"], "a cluster only a little bigger does not take the frame from the main one")
-- A lone machine in the main cluster's edge cell goes away: the frame stays.
local lone = { position = { x = -30, y = 0 } }
both[#both + 1] = lone
local _, with_lone = timelapse.core_box(both, kept_key)
both[#both] = nil
local still = timelapse.core_box(both, with_lone)
check(with_lone["-1:0"] and still.r < 200, "losing the main cluster's lone edge machine keeps the frame on it")
for x = 400, 490, 10 do for y = 60, 200, 10 do both[#both + 1] = { position = { x = x, y = y } } end end
local moved = timelapse.core_box(both, key)
check(moved.l > 300, "a cluster SWITCH_RATIO times bigger becomes the main one")

-- A small base: the launch closes in, never zooms out.
_G.storage = {}
machines = {}
for x = 0, 30, 10 do machines[#machines + 1] = { position = { x = x, y = 0 } } end
shots = {}
game.tick = 100000
timelapse.rpc({ action = "start", folder = "small" })
run_to(game.tick + 3000)
local base_zoom = shots[#shots].zoom
timelapse.on_rocket_launch_ordered({ rocket_silo = { valid = true, force = force, surface = nauvis, position = { x = 10, y = 0 } } })
run_to(game.tick + 1200)
check(base_zoom == 1 and shots[#shots].zoom >= base_zoom - 1e-9, "with a small base the launch shot never zooms out")
local other_ok = pcall(timelapse.rpc, { action = "start", folder = "small-2" })
local back_ok = pcall(timelapse.rpc, { action = "start", folder = "small" })
check(other_ok and not back_ok, "a folder used before cannot be started again after another: no frame is overwritten")

os.exit(failures == 0 and 0 or 1)
