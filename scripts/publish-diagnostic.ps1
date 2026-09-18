<#
.SYNOPSIS
    Publishes a built Diagnostic artifact to Frankfurt and verifies the result.

.EXAMPLE
    ./scripts/publish-diagnostic.ps1 -FilePath dist/diagnostic-windows-x64-v1.0.3-260917.zip -Platform diagnosticWindows

.EXAMPLE
    ./scripts/publish-diagnostic.ps1 -Latest -Platform diagnosticLinux
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, ParameterSetName = 'Path')]
    [string]$FilePath,

    [Parameter(Mandatory, ParameterSetName = 'Latest')]
    [switch]$Latest,

    [Parameter(Mandatory)]
    [ValidateSet(
        'diagnosticAndroid', 'diagnosticWindows', 'diagnosticMacos',
        'diagnosticMacosIntel', 'diagnosticLinux'
    )]
    [string]$Platform,

    [string]$SshTarget,
    [int]$SshPort,
    [string]$RemoteReleasesDir = '/home/ambrus/www/aml/diagnostic.aml.one/downloads',
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'publish-lib.ps1')

$RepoRoot = Split-Path $PSScriptRoot -Parent

if ($Latest) {
    $prefix = switch ($Platform) {
        'diagnosticAndroid' { 'diagnostic-android-' }
        'diagnosticWindows' { 'diagnostic-windows-' }
        'diagnosticMacos' { 'diagnostic-macos-silicon-' }
        'diagnosticMacosIntel' { 'diagnostic-macos-intel-' }
        'diagnosticLinux' { 'diagnostic-linux-' }
    }
    $candidate = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'dist') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix) -and $_.Name -notlike '*.deb.uploading' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        throw "No $Platform artifact in dist/. Build it first."
    }
    $FilePath = $candidate.FullName
    Write-Host "Publishing the newest $Platform artifact: $($candidate.Name)" -ForegroundColor Cyan
}

$fileName = Split-Path -Leaf $FilePath
if (-not $PSCmdlet.ShouldProcess("$fileName -> $RemoteReleasesDir", 'Publish to Frankfurt')) {
    return
}

$publishArgs = @{
    FilePath          = $FilePath
    Platform          = $Platform
    RemoteReleasesDir = $RemoteReleasesDir
}
if ($SshTarget) { $publishArgs.SshTarget = $SshTarget }
if ($SshPort) { $publishArgs.SshPort = $SshPort }
if ($SkipVerify) { $publishArgs.SkipVerify = $true }

Publish-ClientRelease @publishArgs
