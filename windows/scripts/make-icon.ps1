# Builds windows/Resources/Velinshot.ico (PNG-compressed entries, 16-256 px) from the shared Resources/AppIcon.png.
# Run from the windows folder: powershell -ExecutionPolicy Bypass -File scripts/make-icon.ps1
param(
    [string]$Source = "../Resources/AppIcon.png",
    [string]$Output = "Resources/Velinshot.ico"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$image = [System.Drawing.Image]::FromFile((Resolve-Path $Source))
$entries = @()
foreach ($size in $sizes) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.DrawImage($image, 0, 0, $size, $size)
    $graphics.Dispose()
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $entries += , @($size, $stream.ToArray())
}
$image.Dispose()
$file = [System.IO.File]::Create((Join-Path (Get-Location) $Output))
$writer = New-Object System.IO.BinaryWriter $file
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($entry in $entries) {
    $size = $entry[0]; $data = $entry[1]
    $writer.Write([byte]($size % 256)); $writer.Write([byte]($size % 256))
    $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$data.Length); $writer.Write([uint32]$offset)
    $offset += $data.Length
}
foreach ($entry in $entries) { $writer.Write([byte[]]$entry[1]) }
$writer.Close()
Write-Host "Wrote $Output with $($entries.Count) sizes."
