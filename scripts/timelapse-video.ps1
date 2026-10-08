param(
  [Parameter(Mandatory = $true)][string]$Run,
  [int]$Fps = 30,
  [int]$Every = 1,
  [switch]$SkipIdle,
  [switch]$NoClock,
  [string]$Captions,
  [string[]]$Music,
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
# -Captions names a JSON list of {"from": "H:MM:SS", "to": "H:MM:SS", "text"}
# on that same clock: each frame in [from, to) gets the text, wrapped to two
# centred lines at the bottom, and the video goes to <run>-timelapse-captions.mp4
# so the plain video is kept. The frames themselves are only read.
# -Music takes audio files played in order with 3 s crossfades, trimmed to the
# video with a 4 s fade-out and loudness-normalised; the name gains -music.
$ErrorActionPreference = "Stop"
$frames = Join-Path $StateRoot "script-output\timelapse\$Run"
if (-not (Test-Path -LiteralPath $frames -PathType Container)) { throw "No timelapse frames for run ${Run}: $frames" }
if ($Every -lt 1 -or $Fps -lt 1) { throw "-Fps and -Every must be at least 1" }
if (-not $Out) { $Out = Join-Path $frames ("..\$Run-timelapse" + $(if ($Captions) { "-captions" } else { "" }) + $(if ($Music) { "-music" } else { "" }) + ".mp4") }
# powershell -File passes "a.ogg,b.ogg" as one string.
if ($Music.Count -eq 1 -and $Music[0] -like "*,*") { $Music = $Music[0].Split(",") }
foreach ($track in $Music) { if (-not (Test-Path -LiteralPath $track -PathType Leaf)) { throw "No music file: $track" } }

$files = @(Get-ChildItem -LiteralPath $frames -Filter "frame_*.jpg" -File | Sort-Object Name)
if ($files.Count -eq 0) { throw "No frame_*.jpg files in $frames" }
$kept = @(for ($i = 0; $i -lt $files.Count; $i += $Every) { $files[$i] })
$list = Join-Path $frames "frames.txt"
$pattern = '^frame_\d+_t(\d+)\.jpg$'
$timed = (-not $NoClock) -or $Captions
if ($timed) {
  $untimed = @($kept | Where-Object { $_.Name -notmatch $pattern })
  if ($untimed.Count -gt 0) { throw "$($untimed[0].Name) has no tick in its name; the clock and captions need it" }
  $t0 = [long][regex]::Match($kept[0].Name, $pattern).Groups[1].Value
}

function Seconds([string]$hms) {
  $p = $hms.Split(":")
  if ($p.Count -ne 3) { throw "caption time '$hms' is not H:MM:SS" }
  [long]$p[0] * 3600 + [long]$p[1] * 60 + [long]$p[2]
}
# Two lines of at most 90 characters, split at spaces.
function Wrap([string]$text) {
  $lines = @(""); foreach ($word in $text.Split(" ")) {
    if ($lines[-1].Length -gt 0 -and ($lines[-1].Length + 1 + $word.Length) -gt 90) { $lines += $word }
    else { $lines[-1] = ($lines[-1] + " " + $word).Trim() }
  }
  if ($lines.Count -gt 2) { throw "caption longer than two 90-character lines: $text" }
  $lines
}
$chapters = @()
if ($Captions) {
  foreach ($c in (Get-Content -LiteralPath $Captions -Raw -Encoding UTF8 | ConvertFrom-Json)) {
    $chapters += [pscustomobject]@{ from = Seconds $c.from; to = Seconds $c.to; lines = @(Wrap $c.text) }
  }
}
# ffconcat strings: single-quoted, a quote written as '\''.
function Quote([string]$s) { "'" + ($s -replace "'", "'\''") + "'" }
function Entry($file) {
  $entry = @("file $(Quote $file.FullName)", "duration $(1.0 / $Fps)")
  if ($timed) {
    $s = [long][math]::Floor(([long][regex]::Match($file.Name, $pattern).Groups[1].Value - $t0) / 60)
    if (-not $NoClock) {
      $entry += "file_packet_meta clock {0:00}:{1:00}:{2:00}" -f [math]::Floor($s / 3600), ([math]::Floor($s / 60) % 60), ($s % 60)
    }
    $chapter = $chapters | Where-Object { $s -ge $_.from -and $s -lt $_.to } | Select-Object -First 1
    if ($chapter) {
      # A one-line caption sits on the bottom line.
      $bottom = $chapter.lines[-1]; $top = if ($chapter.lines.Count -gt 1) { $chapter.lines[0] } else { $null }
      if ($top) { $entry += "file_packet_meta caption1 $(Quote $top)" }
      $entry += "file_packet_meta caption2 $(Quote $bottom)"
    }
  }
  $entry
}
$lines = @("ffconcat version 1.0") + @(foreach ($file in $kept) { Entry $file })
# The concat demuxer ignores the last entry's duration unless the file repeats.
$lines += Entry $kept[-1]
[IO.File]::WriteAllLines($list, $lines)

# The list's durations set the pace; -SkipIdle then re-times what is left.
# Text is drawn after mpdecimate, or its changing clock digits would keep
# every frame; Consolas Bold is monospace, so the digits never shift. A frame
# without a caption line draws neither text nor box.
$chain = @()
if ($SkipIdle) { $chain += "mpdecimate,setpts=N/($Fps*TB)" }
if (-not $NoClock) {
  $chain += "drawtext=fontfile='C\:/Windows/Fonts/consolab.ttf':text='%{metadata\:clock}':fontsize=120:fontcolor=white:borderw=5:bordercolor=black:box=1:boxcolor=black@0.55:boxborderw=24:x=192:y=108"
}
if ($Captions) {
  $style = "fontfile='C\:/Windows/Fonts/seguisb.ttf':fontsize=68:fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=22:x=(w-tw)/2"
  $chain += "drawtext=$style`:text='%{metadata\:caption1}':y=h-330"
  $chain += "drawtext=$style`:text='%{metadata\:caption2}':y=h-230"
}
$filterFile = Join-Path $frames "filter.txt"
[IO.File]::WriteAllText($filterFile, ($chain -join ","))
$filter = if ($chain.Count -gt 0) { @("-/filter:v", $filterFile) } else { @() }
$audio = @()
if ($Music) {
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $length = ($kept.Count / $Fps).ToString("0.###", $inv)
  $fadeAt = ([math]::Max(0, $kept.Count / $Fps - 4)).ToString("0.###", $inv)
  $graph = if ($Music.Count -eq 1) { "[1:a]anull[m0]" } else {
    $parts = @("[1:a][2:a]acrossfade=d=3[m1]")
    for ($i = 3; $i -le $Music.Count; $i++) { $parts += "[m$($i - 2)][$($i):a]acrossfade=d=3[m$($i - 1)]" }
    $parts -join ";"
  }
  $last = if ($Music.Count -eq 1) { "m0" } else { "m$($Music.Count - 1)" }
  $graph += ";[$last]atrim=0:$length,afade=t=out:st=$($fadeAt):d=4,loudnorm=I=-16:TP=-1.5:LRA=11[a]"
  $audioFile = Join-Path $frames "audio-filter.txt"
  [IO.File]::WriteAllText($audioFile, $graph)
  $audio = @(foreach ($track in $Music) { "-i"; $track }) + @("-/filter_complex", $audioFile, "-map", "0:v", "-map", "[a]", "-c:a", "aac", "-b:a", "192k", "-ar", "48000")
}
# Windows PowerShell treats ffmpeg's stderr progress as errors: judge by exit code.
$ErrorActionPreference = "Continue"
& ffmpeg -hide_banner -y -f concat -safe 0 -i $list @audio @filter -r $Fps `
  -c:v hevc_nvenc -preset p7 -rc vbr -cq 19 -b:v 0 -pix_fmt yuv420p -tag:v hvc1 $Out
$code = $LASTEXITCODE
$ErrorActionPreference = "Stop"
if ($code -ne 0) { throw "ffmpeg failed with exit code $code" }
Write-Output ("{0} frames of {1} -> {2} ({3:N1} s at {4} fps)" -f $kept.Count, $files.Count, (Resolve-Path $Out), ($kept.Count / $Fps), $Fps)
