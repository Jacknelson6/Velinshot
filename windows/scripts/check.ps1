# Builds everything in Release and runs every automated check:
#   1. engine checks (tests/Velinshot.Checks): layout, pixels, JSON, history, presets, OCR
#   2. the app's in-process interaction check (editor gestures, undo, keys, capture selection)
#   3. the app's platform self-check (live screen snapshot, hotkeys, OCR, export, share interop)
#   4. rendered window snapshots (light/dark, default/minimum size) for visual review
# Artifacts land in artifacts/ (git-ignored). Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File scripts/check.ps1 [-SkipPlatform] [-SkipRender]
param([switch]$SkipPlatform, [switch]$SkipRender)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $root "artifacts"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"
New-Item -ItemType Directory -Force $artifacts | Out-Null

Write-Host "Building (Release)..."
dotnet build (Join-Path $root "Velinshot.sln") -c Release -v quiet -nologo
if ($LASTEXITCODE -ne 0) { throw "Build failed." }

$failed = 0
Write-Host "`nEngine checks"
dotnet run --project (Join-Path $root "tests/Velinshot.Checks") -c Release --no-build -- --out (Join-Path $artifacts "engine")
if ($LASTEXITCODE -ne 0) { $failed++ }

$exe = Join-Path $root "src/Velinshot/bin/Release/net10.0-windows10.0.19041.0/Velinshot.exe"
function Invoke-AppCheck([string]$flag, [string]$folder, [string]$report) {
    $target = Join-Path $artifacts $folder
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    $process = Start-Process -FilePath $exe -ArgumentList $flag, "`"$target`"" -PassThru -Wait
    # Write-Host keeps report lines out of the function's return value.
    if ($report -and (Test-Path (Join-Path $target $report))) { Get-Content (Join-Path $target $report) | ForEach-Object { Write-Host "  $_" } }
    if (Test-Path (Join-Path $target "error.txt")) { Get-Content (Join-Path $target "error.txt") | Select-Object -First 10 | ForEach-Object { Write-Host $_ } }
    return [int]$process.ExitCode
}

Write-Host "`nInteraction check (off-screen, temporary settings)"
if ((Invoke-AppCheck "--interaction-check" "interaction" "interaction-check.txt") -ne 0) { $failed++ }

if (-not $SkipPlatform) {
    Write-Host "`nPlatform self-check (reads the live screen; never shows the share sheet)"
    if ((Invoke-AppCheck "--self-check" "platform" "self-check.txt") -ne 0) { $failed++ }
}
if (-not $SkipRender) {
    Write-Host "`nRendering window snapshots to artifacts/docs"
    if ((Invoke-AppCheck "--render-docs" "docs" $null) -ne 0) { $failed++ }
}

if ($failed -gt 0) { Write-Host "`n$failed check group(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll checks passed. Artifacts: $artifacts" -ForegroundColor Green
