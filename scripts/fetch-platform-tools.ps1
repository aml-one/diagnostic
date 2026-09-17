#Requires -Version 5.1
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutRoot = Join-Path $RepoRoot 'third_party\platform-tools'

$Targets = @(
  @{ Os='windows'; Url='https://dl.google.com/android/repository/platform-tools-latest-windows.zip'; Keep=@('adb.exe','AdbWinApi.dll','AdbWinUsbApi.dll','NOTICE.txt','source.properties'); Required=@('adb.exe','AdbWinApi.dll','AdbWinUsbApi.dll') },
  @{ Os='darwin'; Url='https://dl.google.com/android/repository/platform-tools-latest-darwin.zip'; Keep=@('adb','NOTICE.txt','source.properties'); Required=@('adb') },
  @{ Os='linux'; Url='https://dl.google.com/android/repository/platform-tools-latest-linux.zip'; Keep=@('adb','NOTICE.txt','source.properties'); Required=@('adb') }
)

function Test-BundleComplete($Dir, $Required) {
  foreach ($name in $Required) {
    if (-not (Test-Path (Join-Path $Dir $name))) { return $false }
  }
  return $true
}

New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
$TempRoot = Join-Path $env:TEMP ('aml-pt-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

try {
  foreach ($t in $Targets) {
    $dest = Join-Path $OutRoot $t.Os
    if (-not $Force -and (Test-BundleComplete $dest $t.Required)) {
      Write-Host "OK  $($t.Os) already present"
      continue
    }
    Write-Host "GET $($t.Url)"
    $zipPath = Join-Path $TempRoot ($t.Os + '.zip')
    Invoke-WebRequest -Uri $t.Url -OutFile $zipPath -UseBasicParsing
    $extract = Join-Path $TempRoot $t.Os
    if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
    Expand-Archive -Path $zipPath -DestinationPath $extract -Force
    $src = Join-Path $extract 'platform-tools'
    if (-not (Test-Path $src)) { throw "No platform-tools folder for $($t.Os)" }
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($name in $t.Keep) {
      $from = Join-Path $src $name
      if (Test-Path $from) { Copy-Item -Force $from (Join-Path $dest $name) }
      else { Write-Warning "Missing $name" }
    }
    if (-not (Test-BundleComplete $dest $t.Required)) { throw "Incomplete $($t.Os)" }
    Write-Host "OK  $($t.Os) -> $dest"
  }
  $stamp = Join-Path $OutRoot 'FETCHED.txt'
  Set-Content -Path $stamp -Encoding ascii -Value @(
    ('Fetched: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    'Source: https://developer.android.com/tools/releases/platform-tools'
    'Script: scripts/fetch-platform-tools.ps1'
  )
}
finally {
  if (Test-Path $TempRoot) { Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue }
}
Write-Host 'Done.'
