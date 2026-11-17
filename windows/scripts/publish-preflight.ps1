# Exercise the real locked single-file packaging graph without requiring Inno Setup.
# Run before pushing: pwsh -File windows/scripts/check.ps1 -BuildOnly -PublishPreflight
param(
    [ValidateSet('win-x64', 'win-arm64')][string[]]$Runtime = @('win-x64', 'win-arm64'),
    [string]$OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $root
if ($OutputDirectory) { $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory) }
else { $OutputDirectory = Join-Path $root ('artifacts/publish-preflight-' + [guid]::NewGuid().ToString('N')) }
if (Test-Path $OutputDirectory) { throw 'Publish preflight requires a fresh output directory.' }
Push-Location $root
try {
    $requiredSdk = (Get-Content -Raw (Join-Path $root 'global.json') | ConvertFrom-Json).sdk.version
    $selectedSdk = (& dotnet --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $selectedSdk -ne $requiredSdk) { throw "Publish preflight requires exactly .NET SDK $requiredSdk." }
    $commit = (& git -C $repo rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot establish preflight source identity.' }
    $dirty = & git -C $repo status --porcelain --untracked-files=normal
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Commit the reviewed source before running the production publish preflight.' }
    $lock = Join-Path $root 'src/Velinshot/packages.lock.json'
    $lockBefore = (Get-FileHash $lock -Algorithm SHA256).Hash.ToLowerInvariant()
    New-Item -ItemType Directory $OutputDirectory | Out-Null
    $proof = [ordered]@{
        schemaVersion = 1; sourceCommit = $commit; sourceClean = $true; sdk = $selectedSdk
        restoreLockedMode = $true; packageScriptSha256 = (Get-FileHash (Join-Path $PSScriptRoot 'package.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
        lockBeforeSha256 = $lockBefore; lockAfterSha256 = $lockBefore; cases = @()
        scope = 'Actual self-contained single-file production/fixture publish and portable packaging; no Inno execution or WPF runtime claim.'
    }
    foreach ($rid in $Runtime) {
        foreach ($mode in @('production3', 'fixture3', 'fixture4')) {
            $fixture = $mode -ne 'production3'
            $build = if ($mode -eq 'fixture4') { 4 } else { 3 }
            $name = "$rid-$mode"
            $output = Join-Path $OutputDirectory $name
            Write-Host "Publish preflight: $name (locked restore, single-file, self-contained)"
            & (Join-Path $PSScriptRoot 'package.ps1') -Runtime $rid -BuildNumber $build -DisplayVersion "1.0.0-preview.$build" -Fixture:$fixture -PortableOnly -OutputDirectory $output *> (Join-Path $OutputDirectory "$name.log")
            $metadataPath = Join-Path $output "Velinshot-1.0.0-preview.$build-$rid-BUILD-INFO.json"
            $metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
            $published = Join-Path $output "publish-$rid"
            if ($metadata.sourceCommit -ne $commit -or -not $metadata.sourceClean -or $metadata.fixtureBuild -ne $fixture -or
                $metadata.runtime -ne $rid -or $metadata.version -ne "1.0.0.$build" -or $metadata.dotnetSdk -ne $selectedSdk -or
                -not (Test-Path (Join-Path $published 'Velinshot.exe')) -or (Test-Path (Join-Path $published 'Velinshot.dll'))) {
                throw "Preflight output does not match its single-file provenance: $name"
            }
            $notices = Join-Path $published 'ThirdPartyNotices/manifest.json'
            if (-not (Test-Path $notices)) { throw "Preflight notices are missing: $name" }
            $lockAfter = (Get-FileHash $lock -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($lockAfter -ne $lockBefore) { throw "A locked publish changed packages.lock.json: $name" }
            $proof.cases += [ordered]@{ name = $name; runtime = $rid; fixtureBuild = $fixture; build = $build
                metadata = $metadata; metadataSha256 = (Get-FileHash $metadataPath -Algorithm SHA256).Hash.ToLowerInvariant()
                noticesManifestSha256 = (Get-FileHash $notices -Algorithm SHA256).Hash.ToLowerInvariant(); lockSha256 = $lockAfter }
            $proof.lockAfterSha256 = $lockAfter
            $proof | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8NoBOM (Join-Path $OutputDirectory 'publish-preflight.json')
        }
    }
    Write-Host "PASS $($proof.cases.Count) actual locked single-file publish/ZIP configurations. Evidence: $OutputDirectory"
} finally { Pop-Location }
