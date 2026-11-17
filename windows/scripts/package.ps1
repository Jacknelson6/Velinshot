# Publishes a release build to dist/.
#   Default: one self-contained Velinshot.exe (no .NET install needed), zipped.
#   -FrameworkDependent: a small exe that needs the .NET 10 Desktop Runtime.
#   -Runtime win-arm64: Windows on Arm.
# The exe is not code-signed, so Windows SmartScreen warns on first run until it is signed.
param(
    [ValidateSet("win-x64", "win-arm64")][string]$Runtime = "win-x64",
    [switch]$FrameworkDependent
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"
$kind = if ($FrameworkDependent) { "framework" } else { "standalone" }
$output = Join-Path $root "dist/$Runtime-$kind"
if (Test-Path $output) { Remove-Item -Recurse -Force $output }

$arguments = @(
    "publish", (Join-Path $root "src/Velinshot/Velinshot.csproj"), "-c", "Release", "-r", $Runtime, "-o", $output,
    "-p:PublishSingleFile=true", "-p:DebugType=none", "-p:GenerateDocumentationFile=false", "-nologo", "-v", "quiet"
)
if ($FrameworkDependent) { $arguments += "--self-contained", "false" }
# Uncompressed on purpose: a compressed bundle is decompressed into memory and idles at ~120 MB
# private instead of ~44 MB. The zip still compresses the download.
else { $arguments += "--self-contained", "true", "-p:EnableCompressionInSingleFile=false", "-p:IncludeNativeLibrariesForSelfExtract=true" }
& dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw "Publish failed." }

$version = (Select-Xml -Path (Join-Path $root "Directory.Build.props") -XPath "//InformationalVersion").Node.InnerText
$zip = Join-Path $root "dist/Velinshot-$version-$Runtime$(if ($FrameworkDependent) { '-framework' }).zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
# The license lives at the repository root, shared with the macOS app.
Copy-Item (Join-Path (Split-Path -Parent $root) "LICENSE") $output
Compress-Archive -Path (Join-Path $output "*") -DestinationPath $zip
$exe = Get-Item (Join-Path $output "Velinshot.exe")
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
Write-Host ("Velinshot.exe {0:N1} MB -> {1}" -f ($exe.Length / 1MB), $zip)
Write-Host "SHA-256 $hash"
