param(
  [Parameter(Mandatory = $true)][string]$Address,
  [string]$FactorioBinary = "$env:LOCALAPPDATA\factorio-codex\standalone-space-age\bin\x64\factorio.exe",
  [string]$StateRoot = "$env:LOCALAPPDATA\factorio-codex\native-client",
  [switch]$PrepareOnly
)

# Couch-PC-only visual launcher. The server-and-agent workstation has no
# dedicated GPU and must never run a Factorio GUI or client.
# The very-low preset and low video memory were inherited from the retired
# workstation launcher, which had no GPU; the couch PC renders at the highest
# 2.0 quality in 4K, where the owner watches and may take over the Codex body.
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath $FactorioBinary -PathType Leaf)) {
  throw "Standalone Factorio executable not found: $FactorioBinary"
}
$version = (& $FactorioBinary --version | Select-Object -First 1)
if ($version -match ', steam[,)]') {
  throw "The Steam Factorio build replaces the isolated Codex identity; use the full standalone build."
}

$installRoot = Split-Path (Split-Path (Split-Path $FactorioBinary -Parent) -Parent) -Parent
$dataRoot = Join-Path $installRoot "data"
# The version line never names the expansion; its data directory does.
if (-not (Test-Path -LiteralPath (Join-Path $dataRoot "space-age") -PathType Container)) {
  throw "Factorio Codex runs Space Age; install the standalone Space Age build: $installRoot has no data\space-age"
}
$configRoot = Join-Path $StateRoot "config"
$modsRoot = Join-Path $StateRoot "mods"
New-Item -ItemType Directory -Force -Path $configRoot, $modsRoot | Out-Null

$config = @"
; factorio-codex isolated native couch client
[path]
read-data=$dataRoot
write-data=$StateRoot
[general]
locale=en
[graphics]
graphics-quality=high
video-memory-usage=all
texture-compression-level=none
high-quality-animations=true
high-quality-shadows=true
high-quality-terrain=true
show-animated-water=true
show-tree-distortion=true
"@
$configTmp = Join-Path $configRoot "config.ini.tmp"
[IO.File]::WriteAllText($configTmp, $config + "`n")
Move-Item -Force $configTmp (Join-Path $configRoot "config.ini")

$playerTmp = Join-Path $StateRoot "player-data.json.tmp"
[IO.File]::WriteAllText($playerTmp, '{"service-username":"Codex"}' + "`n")
Move-Item -Force $playerTmp (Join-Path $StateRoot "player-data.json")

$modListTmp = Join-Path $modsRoot "mod-list.json.tmp"
$modList = '{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},{"name":"quality","enabled":true},{"name":"space-age","enabled":true},{"name":"agentic-companion","enabled":true}]}'
[IO.File]::WriteAllText($modListTmp, $modList + "`n")
Move-Item -Force $modListTmp (Join-Path $modsRoot "mod-list.json")

$archive = Join-Path $repoRoot "dist\agentic-companion_0.26.1.zip"
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
  throw "Build the 0.26.1 mod archive before launching: $archive"
}
Get-ChildItem -LiteralPath $modsRoot -Filter "agentic-companion_*.zip" -File |
  Where-Object Name -ne "agentic-companion_0.26.1.zip" |
  Remove-Item -Force
Copy-Item -Force $archive (Join-Path $modsRoot "agentic-companion_0.26.1.zip")

if ($PrepareOnly) {
  Write-Output "Prepared isolated native Codex couch client at $StateRoot"
  exit 0
}

& $FactorioBinary `
  --config (Join-Path $configRoot "config.ini") `
  --mod-directory $modsRoot `
  --mp-connect $Address `
  --force-graphics-preset extreme `
  --graphics-quality high `
  --video-memory-usage all `
  --window-size 3840x2160 `
  --nogamepad
exit $LASTEXITCODE
