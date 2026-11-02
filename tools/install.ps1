# Copies Live Drum Groove Monitor into your REAPER resource folder.
# Writes only to its own two LiveDrumGrooveMonitor folders, plus
# reaper_www_root\drums.html for the phone page.
#
#   powershell -ExecutionPolicy Bypass -File tools\install.ps1

$repo = Split-Path -Parent $PSScriptRoot
$res = Join-Path $env:APPDATA "REAPER"

if (-not (Test-Path $res)) {
    Write-Error "No REAPER resource folder at $res. In REAPER: Options > Show REAPER resource path."
    exit 1
}

$scripts = Join-Path $res "Scripts\LiveDrumGrooveMonitor"
$effects = Join-Path $res "Effects\LiveDrumGrooveMonitor"
$www = Join-Path $res "reaper_www_root"
New-Item -ItemType Directory -Force $scripts, $effects, $www | Out-Null

Copy-Item (Join-Path $repo "lua\*.lua") $scripts -Force
Copy-Item (Join-Path $repo "jsfx\Live Drum Onset Detector.jsfx") $effects -Force
Copy-Item (Join-Path $repo "web\drums.html") $www -Force

Write-Host "Installed to:"
Write-Host "  $scripts"
Write-Host "  $effects"
Write-Host "  $www\drums.html"
Write-Host ""
Write-Host "In REAPER: Actions > Show action list > New action > Load ReaScript, and pick"
Write-Host "  $scripts\Live Drum Groove Monitor.lua"
