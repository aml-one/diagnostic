# Regenerates Diagnostic launcher mipmaps from the opaque Android plate.
# HyperOS caches @mipmap/ic_launcher — the v4 name is what makes a new
# icon show up after replacing the Flutter default.
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    python (Join-Path $PSScriptRoot 'make-android-launcher-icon.py')
    if ($LASTEXITCODE -ne 0) { throw "make-android-launcher-icon.py failed ($LASTEXITCODE)" }
    dart run flutter_launcher_icons
    if ($LASTEXITCODE -ne 0) { throw "flutter_launcher_icons failed ($LASTEXITCODE)" }
    $anydpi = Join-Path $root 'android\app\src\main\res\mipmap-anydpi-v26'
    if (Test-Path -LiteralPath $anydpi) {
        Remove-Item -LiteralPath $anydpi -Recurse -Force
    }
    Get-ChildItem -LiteralPath (Join-Path $root 'android\app\src\main\res') -Recurse -Filter 'ic_launcher.png' |
        Where-Object { $_.Directory.Name -like 'mipmap-*' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
} finally {
    Pop-Location
}
Write-Host 'App icons regenerated: Android from app_icon_launcher.png'
