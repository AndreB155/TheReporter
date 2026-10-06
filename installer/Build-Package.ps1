<#
.SYNOPSIS
  Builds dist\TheReporter-Setup.zip - the file a consultant carries to a client site.

.DESCRIPTION
  With -Offline the package also contains MySQL, the Visual C++ runtime, the Python installer
  and the Python wheels, so the target PC needs no internet access. Run while online.
#>
[CmdletBinding()]
param(
    [switch]$Offline,
    [string]$MySqlVersion = '8.4.9'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $root 'dist\TheReporter-Setup'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null

foreach ($d in 'reporter', 'installer', 'samples', 'docs') { Copy-Item (Join-Path $root $d) $stage -Recurse }
foreach ($f in 'pyproject.toml', 'README.md', '.env.example') { Copy-Item (Join-Path $root $f) $stage }
Get-ChildItem $stage -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
Remove-Item (Join-Path $stage 'installer\Build-Package.ps1')

"@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0installer\Install-TheReporter.ps1`" %*`r`npause" |
    Set-Content (Join-Path $stage 'Install.cmd') -Encoding ASCII

if ($Offline) {
    $pk = Join-Path $stage 'packages'
    New-Item -ItemType Directory -Force $pk, (Join-Path $pk 'wheels') | Out-Null
    Write-Host 'Downloading MySQL...'
    Invoke-WebRequest "https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-$MySqlVersion-winx64.zip" -OutFile (Join-Path $pk "mysql-$MySqlVersion-winx64.zip") -UseBasicParsing
    Write-Host 'Downloading Python installer...'
    Invoke-WebRequest 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' -OutFile (Join-Path $pk 'python-3.12.10-amd64.exe') -UseBasicParsing
    Write-Host 'Downloading Visual C++ runtime...'
    Invoke-WebRequest 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile (Join-Path $pk 'vc_redist.x64.exe') -UseBasicParsing
    Write-Host 'Downloading Python wheels (for Python 3.12)...'
    python -m pip download --disable-pip-version-check -d (Join-Path $pk 'wheels') --only-binary=:all: --python-version 3.12 --platform win_amd64 --platform any setuptools wheel PyMySQL Flask
    if ($LASTEXITCODE -ne 0) { throw 'pip download failed' }
}

$zip = Join-Path $root 'dist\TheReporter-Setup.zip'
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Write-Host "Package created: $zip"
