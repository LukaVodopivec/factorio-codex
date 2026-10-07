param(
  [Parameter(Mandatory = $true)][string]$Run,
  [int]$Fps = 30,
  [int]$Every = 1,
  [switch]$SkipIdle,
  [string]$StateRoot = "$env:LOCALAPPDATA\factorio-codex\native-client",
  [string]$Out
)

# Couch-PC-only: joins the 4K timelapse frames the mod saved for run $Run
# (script-output\timelapse\<run>\frame_NNNNNN.jpg) into an HEVC video with
# the GPU encoder. -Every 2 keeps every second frame (twice as fast);
# -SkipIdle drops frames where nothing changed. Frames the client could not
# render leave gaps in the numbering, so the frame list is read from disk.
$ErrorActionPreference = "Stop"
$frames = Join-Path $StateRoot "script-output\timelapse\$Run"
if (-not (Test-Path -LiteralPath $frames -PathType Container)) { throw "No timelapse frames for run ${Run}: $frames" }
if ($Every -lt 1 -or $Fps -lt 1) { throw "-Fps and -Every must be at least 1" }
if (-not $Out) { $Out = Join-Path $frames "..\$Run-timelapse.mp4" }

$files = @(Get-ChildItem -LiteralPath $frames -Filter "frame_*.jpg" -File | Sort-Object Name)
if ($files.Count -eq 0) { throw "No frame_*.jpg files in $frames" }
$kept = @(for ($i = 0; $i -lt $files.Count; $i += $Every) { $files[$i] })
$list = Join-Path $frames "frames.txt"
$lines = foreach ($file in $kept) { "file '$($file.FullName -replace "'", "'\''")'"; "duration $(1.0 / $Fps)" }
# The concat demuxer ignores the last entry's duration unless the file repeats.
$lines += "file '$($kept[-1].FullName -replace "'", "'\''")'"
[IO.File]::WriteAllLines($list, $lines)

# The list's durations set the pace; -SkipIdle then re-times what is left.
$filter = if ($SkipIdle) { @("-vf", "mpdecimate,setpts=N/($Fps*TB)") } else { @() }
# Windows PowerShell treats ffmpeg's stderr progress as errors: judge by exit code.
$ErrorActionPreference = "Continue"
& ffmpeg -hide_banner -y -f concat -safe 0 -i $list @filter -r $Fps `
  -c:v hevc_nvenc -preset p7 -rc vbr -cq 19 -b:v 0 -pix_fmt yuv420p -tag:v hvc1 $Out
$code = $LASTEXITCODE
$ErrorActionPreference = "Stop"
if ($code -ne 0) { throw "ffmpeg failed with exit code $code" }
Write-Output ("{0} frames of {1} -> {2} ({3:N1} s at {4} fps)" -f $kept.Count, $files.Count, (Resolve-Path $Out), ($kept.Count / $Fps), $Fps)
