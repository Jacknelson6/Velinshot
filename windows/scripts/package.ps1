# Packages a clean, provenance-bound Windows release. Signing keys never enter this script or CI.
param(
    [ValidateSet("win-x64", "win-arm64")][string]$Runtime = "win-x64",
    [ValidateRange(1, 65535)][int]$BuildNumber = 3,
    [string]$DisplayVersion = "1.0.0-preview.3",
    [string]$UpdatePublicKey = "",
    [switch]$Fixture,
    [switch]$PortableOnly,
    [switch]$FrameworkDependent,
    [string]$OutputDirectory = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $root
if ($OutputDirectory) { $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory) }
Push-Location $root
try {
    $requiredSdk = (Get-Content -Raw (Join-Path $root 'global.json') | ConvertFrom-Json).sdk.version
    $selectedSdk = (& dotnet --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $selectedSdk -ne $requiredSdk) {
        throw "The Windows build requires exactly .NET SDK $requiredSdk; selected '$selectedSdk'."
    }
    Write-Host "Using .NET SDK $selectedSdk"
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
    $env:DOTNET_NOLOGO = "1"
    $env:MSBUILDDISABLENODEREUSE = "1"
    $env:DOTNET_CLI_USE_MSBUILD_SERVER = "0"
    $publicFixtureKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
    if ($DisplayVersion -notmatch '^1\.0\.0-preview\.[1-9][0-9]*$' -or [int]($DisplayVersion.Split('.')[-1]) -ne $BuildNumber) {
        throw "Display version and numeric update build must agree."
    }
    $commit = (& git -C $repo rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw "Cannot establish the exact source commit." }
    $dirty = & git -C $repo status --porcelain --untracked-files=normal
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw "Release source must be clean, including untracked files. Commit the accepted feature before packaging." }
    if ($Fixture) { $UpdatePublicKey = $publicFixtureKey }
    elseif (-not $UpdatePublicKey) {
        $publicKeyFile = Join-Path $root 'updates/windows-ed25519.pub'
        if (-not (Test-Path $publicKeyFile)) { throw "The Windows release public key has not been configured." }
        $UpdatePublicKey = (Get-Content -Raw $publicKeyFile).Trim()
    }
    try { $key = [Convert]::FromBase64String($UpdatePublicKey) } catch { throw "The public key is not canonical Base64." }
    if ($key.Length -ne 32 -or [Convert]::ToBase64String($key) -ne $UpdatePublicKey -or -not ($key | Where-Object { $_ -ne 0 })) { throw "The public key is invalid." }
    if (-not $Fixture -and $UpdatePublicKey -eq $publicFixtureKey) { throw "A public test key can never authenticate a production release." }
    if ($FrameworkDependent -and -not $PortableOnly) { throw "Framework-dependent builds are portable-only; the standard installer is self-contained." }
    $dist = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root 'dist' }
    $asset = "Velinshot-$DisplayVersion-$Runtime"
    foreach ($name in @("$asset.zip", "$asset-setup.exe", "$asset-BUILD-INFO.json")) {
        if (Test-Path (Join-Path $dist $name)) { throw "A release artifact already exists: $name" }
    }
    $output = Join-Path $dist "publish-$Runtime"
    if (Test-Path $output) { throw "Output already exists. Use a fresh output directory so no release bytes are silently replaced." }
    New-Item -ItemType Directory -Force $output | Out-Null
    $arguments = @(
        'publish', (Join-Path $root 'src/Velinshot/Velinshot.csproj'), '-c', 'Release', '-r', $Runtime, '-o', $output,
        '--disable-build-servers', '-m:2', '-p:UseSharedCompilation=false', '-nodeReuse:false',
        '-p:RestoreLockedMode=true',
        '-p:PublishSingleFile=true', '-p:PublishTrimmed=false', '-p:DebugType=none', '-p:GenerateDocumentationFile=false',
        "-p:WindowsBuildNumber=$BuildNumber", "-p:InformationalVersion=$DisplayVersion", "-p:WindowsSourceCommit=$commit",
        '-p:WindowsSourceClean=true', "-p:WindowsUpdatePublicKey=$UpdatePublicKey", "-p:VelinshotUpdateTests=$($Fixture.ToString().ToLowerInvariant())",
        "-p:VelinshotProductionRelease=$((-not $Fixture).ToString().ToLowerInvariant())", '-nologo', '-v', 'quiet'
    )
    if ($FrameworkDependent) { $arguments += '--self-contained', 'false' }
    else { $arguments += '--self-contained', 'true', '-p:EnableCompressionInSingleFile=false', '-p:IncludeNativeLibrariesForSelfExtract=true' }
    if (-not $IsWindows) { $arguments += '-p:EnableWindowsTargeting=true' }
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) { throw "Publish failed." }
    $afterPublish = & git -C $repo status --porcelain --untracked-files=normal
    if ($LASTEXITCODE -ne 0 -or $afterPublish) { throw "Publishing changed source inputs. Freeze and recheck the source before packaging." }
    Copy-Item (Join-Path $repo 'LICENSE') $output
    $assets = Get-Content -Raw (Join-Path $root 'src/Velinshot/obj/project.assets.json') | ConvertFrom-Json -AsHashtable
    $notices = Join-Path $output 'ThirdPartyNotices'
    New-Item -ItemType Directory $notices | Out-Null
    $noticeManifest = [Collections.Generic.List[object]]::new()
    function Copy-PackageNotices([string]$id, [string]$version, [string]$relativePath, [switch]$RuntimePack) {
        $package = $null
        foreach ($folder in $assets.packageFolders.Keys) {
            $candidate = Join-Path $folder $relativePath
            if (Test-Path $candidate) { $package = $candidate; break }
        }
        if (-not $package) { throw "The restored license source is missing for $id/$version." }
        $destination = Join-Path $notices "$id/$version"
        New-Item -ItemType Directory -Force $destination | Out-Null
        $official = @(Get-ChildItem $package -File | Where-Object { $_.Name -match '(?i)license|notice|\.nuspec$|\.versions\.txt$' })
        $licenses = @($official | Where-Object { $_.Name -match '(?i)license' })
        if ($id -in 'NetSparkleUpdater.SparkleUpdater', 'NetSparkleUpdater.UI.WPF') {
            # These pinned NuGet packages declare MIT but omit its text. Preserve the official tagged text.
            $upstream = Join-Path $root 'Resources/Notices/NetSparkle-3.1.0-LICENSE.md'
            if ($version -ne '3.1.0' -or -not (Test-Path $upstream)) { throw 'The pinned NetSparkle license source is missing.' }
            Copy-Item $upstream (Join-Path $destination 'LICENSE.md')
        }
        elseif ($licenses.Count -eq 0) { throw "The official package license is missing for $id/$version." }
        if ($RuntimePack -and $id -like 'Microsoft.NETCore.App.Runtime.*' -and -not ($official | Where-Object { $_.Name -match '(?i)third.party.notices' })) {
            throw 'The self-contained .NET runtime third-party notices are missing.'
        }
        $official | Copy-Item -Destination $destination
        $nuspec = $official | Where-Object { $_.Extension -eq '.nuspec' } | Select-Object -First 1
        if (-not $nuspec) { throw "The official package metadata is missing for $id/$version." }
        [xml]$packageMetadata = Get-Content -Raw $nuspec.FullName
        $repository = $packageMetadata.SelectSingleNode("//*[local-name()='metadata']/*[local-name()='repository']")
        $files = @(Get-ChildItem $destination -File | Sort-Object Name | ForEach-Object {
            [ordered]@{ file = "$id/$version/$($_.Name)"; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
        $noticeManifest.Add([ordered]@{ package = $id; version = $version; runtimePack = [bool]$RuntimePack
            repository = if ($repository) { $repository.GetAttribute('url') } else { '' }
            sourceCommit = if ($repository) { $repository.GetAttribute('commit') } else { '' }; files = $files })
    }
    foreach ($entry in ($assets.libraries.GetEnumerator() | Sort-Object Key)) {
        if ($entry.Value.type -ne 'package') { continue }
        # Include every redistributed package. SDK analysis/build tools have no assets inside the app.
        $hasRuntimeAssets = $false
        foreach ($target in $assets.targets.Values) {
            $resolved = $target[$entry.Key]
            if ($resolved.runtime -or $resolved.native -or $resolved.runtimeTargets -or $resolved.contentFiles) { $hasRuntimeAssets = $true; break }
        }
        if (-not $hasRuntimeAssets) { continue }
        $identity = $entry.Key.Split('/')
        Copy-PackageNotices $identity[0] $identity[1] $entry.Value.path
    }
    if (-not $FrameworkDependent) {
        foreach ($id in @("Microsoft.NETCore.App.Runtime.$Runtime", "Microsoft.WindowsDesktop.App.Runtime.$Runtime")) {
            $dependencies = @($assets.project.frameworks.Values | ForEach-Object { $_.downloadDependencies } | Where-Object { $_.name -eq $id })
            if ($dependencies.Count -ne 1 -or $dependencies[0].version -notmatch '^\[([^,]+),\s*([^\]]+)\]$' -or $Matches[1] -ne $Matches[2]) {
                throw "Cannot establish the exact bundled runtime license version for $id."
            }
            $runtimeVersion = $Matches[1]
            Copy-PackageNotices $id $runtimeVersion ($id.ToLowerInvariant() + '/' + $runtimeVersion) -RuntimePack
        }
    }
    $noticeManifestPath = Join-Path $notices 'manifest.json'
    $noticeManifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8NoBOM $noticeManifestPath
    $exe = Get-Item (Join-Path $output 'Velinshot.exe')
    $numericVersion = "1.0.0.$BuildNumber"
    if ($exe.VersionInfo.FileVersion -ne $numericVersion -or $exe.VersionInfo.ProductVersion -ne $DisplayVersion) { throw "Executable versions do not match the release." }
    $metadata = [ordered]@{
        schemaVersion = 1; product = 'Velinshot.Windows'; displayVersion = $DisplayVersion; version = $numericVersion; build = $BuildNumber
        sourceCommit = $commit; sourceClean = $true; runtime = $Runtime; minimumWindowsBuild = 19041
        fixtureBuild = [bool]$Fixture; updatePublicKey = $UpdatePublicKey; updaterVersion = '3.1.0'; dotnetSdk = $selectedSdk
        executableSha256 = (Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        thirdPartyNoticesSha256 = (Get-FileHash $noticeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        signing = 'Ed25519 update signatures are prepared locally; this executable has no Authenticode signature.'
    }
    $metadata | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM (Join-Path $output 'BUILD-INFO.json')
    $zip = Join-Path $dist "$asset.zip"
    if (Test-Path $zip) { throw "The archive already exists." }
    Compress-Archive -Path (Join-Path $output '*') -DestinationPath $zip
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        if (-not ($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq 'ThirdPartyNotices/manifest.json' })) {
            throw 'The portable archive omitted its third-party notices.'
        }
    } finally { $archive.Dispose() }
    if (-not $PortableOnly) {
        $iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
        $compiler = if ($iscc) { $iscc.Source } else { Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe' }
        if (-not (Test-Path $compiler)) { throw "Inno Setup 6 is required to create the standard installer." }
        & $compiler "/DPublishDir=$output" "/DOutputDir=$dist" "/DDisplayVersion=$DisplayVersion" "/DBuildNumber=$BuildNumber" "/DRuntime=$Runtime" "/DFixtureBuild=$(if ($Fixture) { '1' } else { '0' })" (Join-Path $root 'installer/Velinshot.iss')
        if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed." }
        $installer = Get-Item (Join-Path $dist "$asset-setup.exe")
        $metadata['installerSha256'] = (Get-FileHash $installer.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $metadata['installerLength'] = $installer.Length
    }
    $metadata['archiveSha256'] = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $metadata | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM (Join-Path $dist "$asset-BUILD-INFO.json")
    Get-ChildItem $dist -File | Where-Object { $_.Extension -in '.exe', '.zip', '.json' } | ForEach-Object {
        Write-Host "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)"
    }
} finally { Pop-Location }
