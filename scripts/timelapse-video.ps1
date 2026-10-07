param(
  [Parameter(Mandatory = $true)][string]$Run,
  [int]$Fps = 30,
  [int]$Every = 1,
  [switch]$SkipIdle,
  [switch]$NoClock,
  [string]$StateRoot = "$env:LOCALAPPDATA\factorio-codex\native-client",
  [string]$Out
)

# Couch-PC-only: joins the 4K timelapse frames the mod saved for run $Run
# (script-output\timelapse\<run>\frame_NNNNNN_t<tick>.jpg) into an HEVC
# video with the GPU encoder. -Every 2 keeps every second frame (twice as
# fast); -SkipIdle drops frames where nothing changed. Frames the client could
# not render leave gaps in the numbering, so the frame list is read from disk.
# Each frame shows the time since the first frame (HH:MM:SS from its tick, at
# 60 ticks a second) at a fixed spot in a monospace font; -NoClock leaves it out.
$ErrorActionPreference = "Stop"
$frames = Join-Path $StateRoot "script-output\timelapse\$Run"
if (-not (Test-Path -LiteralPath $frames -PathType Container)) { throw "No timelapse frames for run ${Run}: $frames" }
if ($Every -lt 1 -or $Fps -lt 1) { throw "-Fps and -Every must be at least 1" }
if (-not $Out) { $Out = Join-Path $frames "..\$Run-timelapse.mp4" }

$files = @(Get-ChildItem -LiteralPath $frames -Filter "frame_*.jpg" -File | Sort-Object Name)
if ($files.Count -eq 0) { throw "No frame_*.jpg files in $frames" }
$kept = @(for ($i = 0; $i -lt $files.Count; $i += $Every) { $files[$i] })
$list = Join-Path $frames "frames.txt"
$pattern = '^frame_\d+_t(\d+)\.jpg$'
if (-not $NoClock) {
  $untimed = @($kept | Where-Object { $_.Name -notmatch $pattern })
  if ($untimed.Count -gt 0) { throw "$($untimed[0].Name) has no tick in its name; pass -NoClock" }
  $t0 = [long][regex]::Match($kept[0].Name, $pattern).Groups[1].Value
}
function Entry($file) {
  $entry = @("file '$($file.FullName -replace "'", "'\''")'", "duration $(1.0 / $Fps)")
  if (-not $NoClock) {
    $s = [long][math]::Floor(([long][regex]::Match($file.Name, $pattern).Groups[1].Value - $t0) / 60)
    $entry += "file_packet_meta clock {0:00}:{1:00}:{2:00}" -f [math]::Floor($s / 3600), ([math]::Floor($s / 60) % 60), ($s % 60)
  }
  $entry
}
$lines = @("ffconcat version 1.0") + @(foreach ($file in $kept) { Entry $file })
# The concat demuxer ignores the last entry's duration unless the file repeats.
$lines += Entry $kept[-1]
[IO.File]::WriteAllLines($list, $lines)

# The list's durations set the pace; -SkipIdle then re-times what is left.
# The clock is drawn after mpdecimate, or its changing digits would keep
# every frame; Consolas Bold is monospace, so the digits never shift.
$chain = @()
if ($SkipIdle) { $chain += "mpdecimate,setpts=N/($Fps*TB)" }
if (-not $NoClock) {
  $chain += "drawtext=fontfile='C\:/Windows/Fonts/consolab.ttf':text='%{metadata\:clock}':fontsize=120:fontcolor=white:borderw=5:bordercolor=black:box=1:boxcolor=black@0.55:boxborderw=24:x=192:y=108"
}
$filterFile = Join-Path $frames "filter.txt"
[IO.File]::WriteAllText($filterFile, ($chain -join ","))
$filter = if ($chain.Count -gt 0) { @("-/filter:v", $filterFile) } else { @() }
# Windows PowerShell treats ffmpeg's stderr progress as errors: judge by exit code.
$ErrorActionPreference = "Continue"
& ffmpeg -hide_banner -y -f concat -safe 0 -i $list @filter -r $Fps `
  -c:v hevc_nvenc -preset p7 -rc vbr -cq 19 -b:v 0 -pix_fmt yuv420p -tag:v hvc1 $Out
$code = $LASTEXITCODE
$ErrorActionPreference = "Stop"
if ($code -ne 0) { throw "ffmpeg failed with exit code $code" }
Write-Output ("{0} frames of {1} -> {2} ({3:N1} s at {4} fps)" -f $kept.Count, $files.Count, (Resolve-Path $Out), ($kept.Count / $Fps), $Fps)
