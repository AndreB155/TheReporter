[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$KeepData
)
$ErrorActionPreference = 'Stop'
if (-not $InstallDir) { $InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

if (-not (Test-Path (Join-Path $InstallDir 'app\reporter'))) { Write-Host "No installation found in $InstallDir"; exit 1 }
if (-not $KeepData) {
    $a = Read-Host "This DELETES all imported client data in $InstallDir. Type YES to continue"
    if ($a -ne 'YES') { Write-Host 'Cancelled.'; exit 0 }
}

$stop = Join-Path $InstallDir 'Stop-MySQL.ps1'
if (Test-Path $stop) { try { & $stop } catch { } ; Start-Sleep 3 }

Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'TheReporter Admin.lnk') -Force -ErrorAction SilentlyContinue

if ($KeepData) {
    foreach ($d in 'app', 'venv', 'mysql') { Remove-Item (Join-Path $InstallDir $d) -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "Application removed. Data kept in $InstallDir\mysql-data"
} else {
    # This script lives inside the folder, so delete it after this process exits
    Start-Process powershell -WorkingDirectory $env:TEMP -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', "Start-Sleep 4; Remove-Item -LiteralPath '$InstallDir' -Recurse -Force"
    Write-Host 'TheReporter is being removed.'
}
