# Sync Diagnostic to Nova (Apple Silicon) and build Intel + Silicon DMGs.
[CmdletBinding()]
param(
    [string]$Nova = 'ambrus@192.168.31.230',
    [string]$Mini = 'ambrus@192.168.31.232',
    [switch]$CopyIntelToMini
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$GaRoot = (Resolve-Path (Join-Path $RepoRoot '..\global-assets')).ProviderPath
$RemoteRepo = '/Users/ambrus/src/diagnostic'
$RemoteGa = '/Users/ambrus/src/global-assets'

function Convert-ToScpPath([string]$WindowsPath) {
    $full = [System.IO.Path]::GetFullPath($WindowsPath).Replace('\', '/')
    if ($full -match '^(?i)([A-Z]):/(.*)$') {
        return "/$($Matches[1].ToLower())/$($Matches[2])"
    }
    return $full
}

$ssh = Join-Path $env:WINDIR 'System32/OpenSSH/ssh.exe'
$scp = Join-Path $env:WINDIR 'System32/OpenSSH/scp.exe'
if (-not (Test-Path $ssh)) { $ssh = 'ssh' }
if (-not (Test-Path $scp)) { $scp = 'scp' }

Write-Host "==> Sync Diagnostic + aml_ui to Nova" -ForegroundColor Cyan
& $ssh $Nova "mkdir -p '$RemoteRepo' '$RemoteGa/packages'"
$sourceArchive = Join-Path $env:TEMP 'diagnostic-nova.tgz'
$uiArchive = Join-Path $env:TEMP 'aml_ui-nova.tgz'
$wslRoot = ((wsl.exe -d Ubuntu wslpath -a ($RepoRoot -replace '\\', '/')) -replace "`0", '').Trim()
$wslSrc = ((wsl.exe -d Ubuntu wslpath -a ($sourceArchive -replace '\\', '/')) -replace "`0", '').Trim()
$wslUi = ((wsl.exe -d Ubuntu wslpath -a ($uiArchive -replace '\\', '/')) -replace "`0", '').Trim()
$wslPackages = ((wsl.exe -d Ubuntu wslpath -a ((Join-Path $GaRoot 'packages') -replace '\\', '/')) -replace "`0", '').Trim()
if (-not $wslRoot -or -not $wslSrc -or -not $wslUi) {
    throw 'WSL path conversion failed for the Nova source archives.'
}
$pack = @"
set -euo pipefail
cd '$wslRoot'
tar -czf '$wslSrc' \
  --ignore-failed-read \
  --exclude=.git \
  --exclude=build \
  --exclude=dist \
  --exclude=graphify-out \
  --exclude=.dart_tool \
  --exclude=windows/flutter/ephemeral \
  --exclude=linux/flutter/ephemeral \
  --exclude=macos/Flutter/ephemeral \
  --exclude=.plugin_symlinks \
  .
cd '$wslPackages'
tar -czf '$wslUi' --exclude=aml_ui/.dart_tool --exclude=aml_ui/build aml_ui
"@
$pack = ($pack -replace "`r`n", "`n").Trim()
& wsl.exe -d Ubuntu -- bash -lc $pack
if ($LASTEXITCODE -ne 0) { throw 'Could not package Diagnostic macOS sources.' }
& $scp $sourceArchive "${Nova}:/tmp/diagnostic.tgz"
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic source upload to Nova failed.' }
& $scp $uiArchive "${Nova}:/tmp/aml_ui.tgz"
if ($LASTEXITCODE -ne 0) { throw 'aml_ui upload to Nova failed.' }
& $ssh $Nova "rm -rf '$RemoteRepo' && mkdir -p '$RemoteRepo' '$RemoteGa/packages' && tar -xzf /tmp/diagnostic.tgz -C '$RemoteRepo' && tar -xzf /tmp/aml_ui.tgz -C '$RemoteGa/packages'"
if ($LASTEXITCODE -ne 0) { throw 'Nova extract failed.' }

Write-Host "==> Build Intel + Silicon DMGs on Nova" -ForegroundColor Cyan
$remote = @'
set -euo pipefail
export PATH="$HOME/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd /Users/ambrus/src/diagnostic
find . -name '*.sh' -print0 | xargs -0 sed -i '' $'s/\r$//'
find . -name '*.sh' -exec chmod +x {} \;
bash scripts/build-macos-dmgs.sh
'@
$remote = $remote -replace "`r`n", "`n"
& $ssh $Nova $remote
if ($LASTEXITCODE -ne 0) { throw "Nova macOS build failed ($LASTEXITCODE)" }

$Dist = Join-Path $RepoRoot 'dist'
New-Item -ItemType Directory -Path $Dist -Force | Out-Null
Write-Host "==> Copy DMGs back to Windows dist/" -ForegroundColor Cyan
& $scp "${Nova}:${RemoteRepo}/dist/diagnostic-macos-*.dmg" $Dist
if ($LASTEXITCODE -ne 0) { throw "scp DMGs from Nova failed" }

if ($CopyIntelToMini) {
    $intel = Get-ChildItem -LiteralPath $Dist -Filter 'diagnostic-macos-intel-*.dmg' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($intel) {
        Write-Host "==> Copy Intel DMG to Mac Mini Desktop" -ForegroundColor Cyan
        & $scp $intel.FullName "${Mini}:Desktop/"
    }
}

Get-ChildItem -LiteralPath $Dist -Filter 'diagnostic-macos-*.dmg' | ForEach-Object {
    Write-Host "  $($_.Name)  $([math]::Round($_.Length/1MB,1)) MB"
}
