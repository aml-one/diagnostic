<#
.SYNOPSIS
    Builds AOW Diagnostic for Windows. Portable zip of AmLDiagnostic.exe + DLLs + data/.
#>
[CmdletBinding()]
param(
    [switch]$SkipPubGet,
    [switch]$SkipBuild,
    [switch]$NoZip,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $RepoRoot 'scripts/version-lib.ps1')

$ReleaseDir = Join-Path $RepoRoot 'build/windows/x64/runner/Release'
$DistDir = Join-Path $RepoRoot 'dist'
$PortableDir = Join-Path $DistDir 'AOW Diagnostic'

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutterCommand) { throw 'flutter not found on PATH.' }
$flutter = $flutterCommand.Source

Sync-PubspecVersion
$version = Get-ProjectVersion
$buildDate = Get-BuildDateStamp
$label = Get-BuildLabel -SemVer $version -BuildDate $buildDate
$defines = Get-FlutterVersionDefines -SemVer $version -BuildDate $buildDate

Write-Host "Diagnostic Windows build  $label"

Push-Location $RepoRoot
try {
    Write-Step 'platform-tools (adb)'
    & (Join-Path $PSScriptRoot 'fetch-platform-tools.ps1')

    if ($Clean -and -not $SkipBuild) {
        Write-Step 'flutter clean'
        & $flutter clean
        if ($LASTEXITCODE -ne 0) { throw "flutter clean failed ($LASTEXITCODE)" }
        $SkipPubGet = $false
    }

    if (-not $SkipPubGet) {
        Write-Step 'flutter pub get'
        & $flutter pub get
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed ($LASTEXITCODE)" }
    }

    if ($SkipBuild) {
        if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir 'AmLDiagnostic.exe'))) {
            throw "No existing release build at $ReleaseDir."
        }
        Write-Host 'Reusing the existing release build.' -ForegroundColor Yellow
    } else {
        Write-Step 'flutter_launcher_icons'
        & dart run flutter_launcher_icons
        Write-Step "flutter build windows --release"
        & $flutter build windows --release @defines
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }
    }

    Write-Step 'Packaging the portable folder'
    if (Test-Path -LiteralPath $PortableDir) {
        Remove-Item -LiteralPath $PortableDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $PortableDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $ReleaseDir 'AmLDiagnostic.exe') -Destination $PortableDir
    Get-ChildItem -LiteralPath $ReleaseDir -Filter '*.dll' |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $PortableDir }
    Copy-Item -LiteralPath (Join-Path $ReleaseDir 'data') -Destination $PortableDir -Recurse
    $pt = Join-Path $ReleaseDir 'platform-tools'
    if (Test-Path -LiteralPath $pt) {
        Copy-Item -LiteralPath $pt -Destination $PortableDir -Recurse
    }
    Write-VersionFileToDir -Directory $PortableDir -SemVer $version -BuildDate $buildDate

    if (-not (Test-Path -LiteralPath $DistDir)) {
        New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
    }
    $zipPath = Join-Path $DistDir "diagnostic-windows-x64-$label.zip"
    if (-not $NoZip) {
        Write-Step 'Creating the zip'
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Compress-Archive -Path (Join-Path $PortableDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
        Write-Host "Windows zip: $zipPath"
    }
} finally {
    Pop-Location
}
