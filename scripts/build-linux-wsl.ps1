# Build Diagnostic Desktop Linux (x64) via WSL Ubuntu.
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$BuildSh = Join-Path $PSScriptRoot 'build-linux.sh'

function Get-WslLinuxDistro {
    $raw = (wsl.exe -l -q 2>&1 | Out-String) -replace "`0", ''
    if ($LASTEXITCODE -ne 0 -and [string]::IsNullOrWhiteSpace($raw)) {
        throw 'WSL is not available. Install WSL + Ubuntu to build Diagnostic Linux on this PC.'
    }

    $distros = @()
    foreach ($line in ($raw -split "`r?`n")) {
        $name = $line.Trim()
        if (-not $name) { continue }
        if ($name -match 'docker-desktop|podman') { continue }
        $distros += $name
    }

    foreach ($preferred in @('Ubuntu', 'Ubuntu-24.04', 'Ubuntu-22.04', 'Debian')) {
        $hit = $distros | Where-Object { $_ -eq $preferred } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    if ($distros.Count -gt 0) { return $distros[0] }
    throw 'No usable WSL Linux distro found (need Ubuntu/Debian with bash + Flutter).'
}

function Convert-ToWslPath {
    param([string]$WindowsPath)
    $resolved = (Resolve-Path -LiteralPath $WindowsPath).ProviderPath
    $drive = $resolved.Substring(0, 1).ToLowerInvariant()
    $rest = $resolved.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

if (-not (Test-Path -LiteralPath $BuildSh)) {
    throw "Missing Linux build script: $BuildSh"
}

$distro = Get-WslLinuxDistro
$wslHome = ((wsl.exe -d $distro -- bash -c 'printf %s "$HOME"') -replace "`0", '').Trim()
if (-not $wslHome) { $wslHome = '/home/ambrus' }

$linuxPath = "$wslHome/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

Write-Host "Building Diagnostic Desktop Linux (x64) via WSL ($distro)..." -ForegroundColor Cyan

$repoWsl = Convert-ToWslPath $RepoRoot
$cmd = @"
set -euo pipefail
export PATH='$linuxPath'
cd '$repoWsl'
sed -i 's/\r`$//' scripts/build-linux.sh scripts/fetch-platform-tools.sh
if ! command -v dpkg-deb >/dev/null; then
  echo 'dpkg-deb not found. In WSL: sudo apt install dpkg-dev' >&2
  exit 1
fi
bash scripts/build-linux.sh
"@
$cmd = ($cmd -replace "`r`n", "`n").Trim()
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$wslOut = & wsl.exe -d $distro -- bash -c $cmd 2>&1
$wslExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
foreach ($line in $wslOut) {
    Write-Host ($line | Out-String).TrimEnd()
}
if ($wslExit -ne 0) {
    throw "Diagnostic Linux build failed in WSL ($wslExit)."
}

Write-Host 'Diagnostic Desktop Linux (linux-x64 via WSL) build complete.' -ForegroundColor Green
