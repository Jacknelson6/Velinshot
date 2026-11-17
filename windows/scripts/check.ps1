# Builds everything in Release and runs every automated check:
#   1. engine checks (tests/Velinshot.Checks): layout, pixels, JSON, history, presets, OCR
#   2. the app's in-process interaction check (editor gestures, undo, keys, capture selection)
#   3. the app's platform self-check (live screen snapshot, hotkeys, OCR, export, share interop)
#   4. rendered window snapshots (light/dark, default/minimum size) for visual review
# Artifacts land in artifacts/ (git-ignored). Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File scripts/check.ps1 [-SkipPlatform] [-SkipRender]
param([switch]$SkipPlatform, [switch]$SkipRender, [string]$SignedUpdateFixtures = "", [switch]$BuildOnly, [switch]$PublishPreflight)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if ($SignedUpdateFixtures) { $SignedUpdateFixtures = [IO.Path]::GetFullPath($SignedUpdateFixtures) }
Push-Location $root
try {
    $artifacts = Join-Path $root "artifacts"
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
    $env:DOTNET_NOLOGO = "1"
    $env:MSBUILDDISABLENODEREUSE = "1"
    $env:DOTNET_CLI_USE_MSBUILD_SERVER = "0"
    New-Item -ItemType Directory -Force $artifacts | Out-Null

    if ($SignedUpdateFixtures) {
        $fixtures = [IO.Path]::GetFullPath($SignedUpdateFixtures)
        $install = Join-Path $artifacts ('update-install-' + [Guid]::NewGuid().ToString('N'))
        $data = Join-Path $artifacts ('update-data-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $install, $data | Out-Null
        $env:VELINSHOT_UPDATE_FIXTURE_DATA = $data
        $old = Get-ChildItem $fixtures -Recurse -Filter 'Velinshot-1.0.0-preview.3-win-x64-setup.exe' | Select-Object -First 1
        if (-not $old) { throw 'The isolated build3 fixture installer is missing.' }
        $signed = Split-Path -Parent (Get-ChildItem $fixtures -Recurse -Filter 'appcast.xml' | Select-Object -First 1).FullName
        Get-ChildItem $fixtures -Recurse -Filter '*-setup.exe' | ForEach-Object {
            $target = Join-Path $signed $_.Name
            if ($_.FullName -ne $target) { Copy-Item $_.FullName $target }
        }
        $first = Start-Process $old.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR="' + $install + '"') -PassThru
        if (-not $first.WaitForExit(90000) -or $first.ExitCode -ne 0) { throw 'Fixture first-install failed or timed out.' }
        $noticesPath = Join-Path $install 'ThirdPartyNotices/manifest.json'
        if (-not (Test-Path $noticesPath)) { throw 'The installer omitted third-party notices.' }
        $installedNotices = Get-Content -Raw $noticesPath | ConvertFrom-Json
        foreach ($package in $installedNotices) {
            foreach ($file in $package.files) {
                $path = Join-Path $install ('ThirdPartyNotices/' + $file.file)
                if (-not (Test-Path $path) -or (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) {
                    throw 'Installed third-party notices do not match their package manifest.'
                }
            }
        }
        $exe = Join-Path $install 'Velinshot.exe'
        $check = Start-Process $exe -ArgumentList '--update-check', ('"' + $signed + '"') -PassThru
        try {
            if (-not $check.WaitForExit(180000) -or $check.ExitCode -ne 0) {
                if (Test-Path (Join-Path $signed 'update-error.txt')) { Get-Content (Join-Path $signed 'update-error.txt') | Select-Object -First 16 | Write-Host }
                throw 'Windows strict-signature, tamper or busy-state checks failed.'
            }
        } finally { if (-not $check.HasExited) { Stop-Process -Id $check.Id } }
        Get-Content (Join-Path $signed 'update-check.txt') | ForEach-Object { Write-Host $_ }
        $proofPath = Join-Path $signed 'relaunch-proof.json'
        if (Test-Path $proofPath) { throw 'A stale relaunch proof was present.' }
        $watcher = [IO.FileSystemWatcher]::new($signed, 'relaunch-proof.json')
        $watcher.EnableRaisingEvents = $true
        try {
            $updating = Start-Process $exe -ArgumentList '--update-install-fixture', ('"' + $signed + '"') -PassThru
            if (-not $updating.WaitForExit(120000)) { Stop-Process -Id $updating.Id; throw 'The admitted update did not shut down its fixture parent.' }
            if ($updating.ExitCode -ne 0) { throw 'The real updater handoff failed.' }
            if (-not (Test-Path $proofPath)) {
                $change = $watcher.WaitForChanged([IO.WatcherChangeTypes]::Created, 120000)
                if ($change.TimedOut) { throw 'The standard installer did not install and relaunch build4.' }
            }
            $proof = Get-Content -Raw $proofPath | ConvertFrom-Json
            if ($proof.version -ne '1.0.0.4' -or -not $proof.fixtureBuild -or $proof.filename -ne 'updater-fixture-preserved' -or
                [IO.Path]::GetFullPath($proof.supportDirectory) -ne $data -or [IO.Path]::GetFullPath($proof.executablePath) -ne $exe -or
                $proof.singleFileAssemblyLocation -ne '') { throw 'Relaunch identity, single-file location or preserved data proof is wrong.' }
            if ((Get-Content -Raw (Join-Path $data 'History/preserved-fixture.txt')) -ne 'Updater must preserve AppData.') { throw 'Updater lost the fixture history asset.' }
            Write-Host 'PASS actual signed build3 to build4 installer replacement, relaunch, single-file path and AppData preservation'
        } finally { $watcher.Dispose() }
        exit 0
    }

    $requiredSdk = (Get-Content -Raw (Join-Path $root 'global.json') | ConvertFrom-Json).sdk.version
    $selectedSdk = (& dotnet --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $selectedSdk -ne $requiredSdk) {
        throw "The Windows build requires exactly .NET SDK $requiredSdk; selected '$selectedSdk'."
    }
    Write-Host "Using .NET SDK $selectedSdk"
    Write-Host "Building (Release)..."
    $buildArguments = @('build', (Join-Path $root 'Velinshot.sln'), '-c', 'Release', '-v', 'quiet', '-nologo',
        '--disable-build-servers', '-m:2', '-p:UseSharedCompilation=false', '-nodeReuse:false', '-p:RestoreLockedMode=true')
    if (-not $IsWindows) { $buildArguments += '-p:EnableWindowsTargeting=true' }
    & dotnet @buildArguments
    if ($LASTEXITCODE -ne 0) { throw "Build failed." }
    if ($PublishPreflight) { & (Join-Path $PSScriptRoot 'publish-preflight.ps1') }
    if ($BuildOnly) { return }
    if (-not $IsWindows) { throw 'WPF runtime checks require Windows. Use -BuildOnly for the cross-target build graph.' }

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
} finally { Pop-Location }
