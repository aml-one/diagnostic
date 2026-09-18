<#
.SYNOPSIS
    Builds the Diagnostic Android APK into dist/ with a real semver name.
#>
[CmdletBinding()]
param(
    [int]$BuildNumber,
    [switch]$SkipPubGet
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $RepoRoot 'scripts/version-lib.ps1')

$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutterCommand) { throw 'flutter not found on PATH.' }
$flutter = $flutterCommand.Source

Sync-PubspecVersion
$version = Get-ProjectVersion
$buildDate = Get-BuildDateStamp
$label = Get-BuildLabel -SemVer $version -BuildDate $buildDate
$defines = Get-FlutterVersionDefines -SemVer $version -BuildDate $buildDate
if (-not $BuildNumber) { $BuildNumber = Get-AndroidVersionCode -SemVer $version }

Write-Host "Diagnostic Android build  $label  versionCode $BuildNumber"

Push-Location $RepoRoot
try {
    if (-not $SkipPubGet) {
        & $flutter pub get
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed ($LASTEXITCODE)" }
    }
    & $flutter build apk --release --target-platform android-arm64 `
        --build-name=$version --build-number=$BuildNumber `
        @defines
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed ($LASTEXITCODE)" }

    $dist = Join-Path $RepoRoot 'dist'
    if (-not (Test-Path -LiteralPath $dist)) {
        New-Item -ItemType Directory -Path $dist | Out-Null
    }
    $name = "diagnostic-android-arm64-v$version-$buildDate.apk"
    $dest = Join-Path $dist $name
    $flutterApkDir = Join-Path $RepoRoot 'build/app/outputs/flutter-apk'
    $built = @(
        (Join-Path $flutterApkDir 'app-release.apk'),
        (Join-Path $flutterApkDir 'app-arm64-v8a-release.apk')
    ) | Where-Object { Test-Path -LiteralPath $_ } |
        Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending |
        Select-Object -First 1
    if (-not $built) { throw "No Flutter APK under $flutterApkDir" }
    Copy-Item -LiteralPath $built -Destination $dest -Force
    Write-Host "Wrote $dest from $built"
    $dest
}
finally {
    Pop-Location
}
