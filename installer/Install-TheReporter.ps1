<#
.SYNOPSIS
  Installs TheReporter and everything it needs on a consultant's PC/laptop.

.DESCRIPTION
  1. Python 3.10+      (uses an existing one, else packages\python-*.exe, else downloads it)
  2. TheReporter app   (private virtual environment, no admin rights needed)
  3. MySQL             (a private, portable MySQL 8.4 instance on its own port, bound to
                        localhost, so it never clashes with other MySQL installs;
                        or point at an existing server with -UseExistingMySql)
  4. Launchers         (Start/Stop scripts + desktop shortcut)

  Offline use: put the files below in <package>\packages before running.
    mysql-*-winx64.zip, python-*-amd64.exe, vc_redist.x64.exe, wheels\*.whl
  (Build-Package.ps1 -Offline fetches these for you while you are online.)
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'TheReporter'),
    [int]$MySqlPort = 3316,
    [int]$WebPort = 5000,
    [string]$MySqlVersion = '8.4.9',
    [string]$MySqlZip,
    [switch]$UseExistingMySql,
    [string]$DbHost = '127.0.0.1',
    [int]$DbPort = 3306,
    [string]$DbUser = 'root',
    [string]$DbPassword,
    [switch]$NoShortcuts
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Source = Split-Path -Parent $PSScriptRoot
$Packages = Join-Path $Source 'packages'
$AppDir = Join-Path $InstallDir 'app'
$VenvDir = Join-Path $InstallDir 'venv'
$MySqlHome = Join-Path $InstallDir 'mysql'
$DataDir = Join-Path $InstallDir 'mysql-data'

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Get-File($url, $dest) {
    Write-Host "    downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

function Test-Port($port) {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $port); return $true } catch { return $false } finally { $c.Close() }
}

function Find-Python {
    $cands = @()
    foreach ($n in 'py', 'python') {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notmatch 'WindowsApps') { $cands += $cmd.Source }
    }
    $cands += Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | ForEach-Object FullName
    $cands += Get-ChildItem "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | ForEach-Object FullName
    # The Microsoft Store alias is acceptable only if it really runs
    $store = Get-Command python -ErrorAction SilentlyContinue
    if ($store) { $cands += $store.Source }
    foreach ($p in $cands) {
        try {
            $extra = @()
            if ((Split-Path $p -Leaf) -eq 'py.exe') { $extra += '-3' }
            $v = & $p @extra -c "import sys;print('%d.%d' % sys.version_info[:2])" 2>$null
            if ($LASTEXITCODE -eq 0 -and [version]$v -ge [version]'3.10') { return ,(@($p) + $extra) }
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------- 1. Python
Step 'Checking Python 3.10+'
$py = Find-Python
if (-not $py) {
    Write-Host '    Python not found - installing for the current user'
    $exe = Get-ChildItem $Packages -Filter 'python-*-amd64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { $exePath = $exe.FullName }
    else {
        $exePath = Join-Path $env:TEMP 'python-3.12.10-amd64.exe'
        Get-File 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' $exePath
    }
    $p = Start-Process $exePath -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_test=0', 'Include_launcher=0' -Wait -PassThru
    if ($p.ExitCode -ne 0) { Fail "Python installer failed (exit $($p.ExitCode))" }
    $py = Find-Python
    if (-not $py) { Fail 'Python was installed but could not be located' }
}
Write-Host "    using $($py -join ' ')"
$pyExe = $py[0]
$pyArgs = @($py | Select-Object -Skip 1)

# ---------------------------------------------------------------- 2. App
Step "Installing application into $InstallDir"
New-Item -ItemType Directory -Force $InstallDir, $AppDir | Out-Null
foreach ($item in 'reporter', 'samples') {
    $src = Join-Path $Source $item
    if (Test-Path $src) { Copy-Item $src $AppDir -Recurse -Force }
}
foreach ($f in 'pyproject.toml', 'README.md', '.env.example') {
    $src = Join-Path $Source $f
    if (Test-Path $src) { Copy-Item $src $AppDir -Force }
}
Get-ChildItem $AppDir -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force

if (-not (Test-Path (Join-Path $VenvDir 'Scripts\python.exe'))) {
    & $pyExe @pyArgs -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { Fail 'Could not create virtual environment' }
}
$venvPy = Join-Path $VenvDir 'Scripts\python.exe'
$wheels = Join-Path $Packages 'wheels'
$pipArgs = @('-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', $AppDir)
if (Test-Path $wheels) { $pipArgs += @('--no-index', '--find-links', $wheels) }
$ErrorActionPreference = 'Continue'
& $venvPy @pipArgs
$pipCode = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($pipCode -ne 0) { Fail 'pip install failed (no internet and no packages\wheels folder?)' }

# ---------------------------------------------------------------- 3. MySQL
$envFile = Join-Path $AppDir '.env'
if ($UseExistingMySql) {
    Step "Using existing MySQL at ${DbHost}:$DbPort"
    if (-not $DbPassword) {
        $sec = Read-Host "Password for MySQL user '$DbUser'" -AsSecureString
        $DbPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }
} else {
    $DbHost = '127.0.0.1'; $DbPort = $MySqlPort; $DbUser = 'root'

    Step 'Checking Visual C++ runtime (needed by MySQL)'
    $vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
    if (-not $vc -or $vc.Installed -ne 1) {
        $vcExe = Join-Path $Packages 'vc_redist.x64.exe'
        if (-not (Test-Path $vcExe)) {
            $vcExe = Join-Path $env:TEMP 'vc_redist.x64.exe'
            Get-File 'https://aka.ms/vs/17/release/vc_redist.x64.exe' $vcExe
        }
        Write-Host '    installing (Windows may ask for administrator approval)'
        Start-Process $vcExe -ArgumentList '/install', '/quiet', '/norestart' -Wait -Verb RunAs | Out-Null
    }

    Step "Setting up private MySQL $MySqlVersion on port $MySqlPort"
    $mysqld = Join-Path $MySqlHome 'bin\mysqld.exe'
    if (-not (Test-Path $mysqld)) {
        if (-not $MySqlZip) {
            $z = Get-ChildItem $Packages -Filter 'mysql-*-winx64.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($z) { $MySqlZip = $z.FullName }
        }
        if (-not $MySqlZip) {
            $MySqlZip = Join-Path $env:TEMP "mysql-$MySqlVersion-winx64.zip"
            Get-File "https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-$MySqlVersion-winx64.zip" $MySqlZip
        }
        Write-Host '    extracting (this takes a minute)'
        $tmp = Join-Path $InstallDir 'mysql-extract'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive $MySqlZip -DestinationPath $tmp -Force
        $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
        if (Test-Path $MySqlHome) { Remove-Item $MySqlHome -Recurse -Force }
        Move-Item $inner.FullName $MySqlHome
        Remove-Item $tmp -Recurse -Force
    }

    $fresh = -not (Test-Path (Join-Path $DataDir 'mysql'))
    if ((Test-Port $MySqlPort) -and $fresh) {
        Fail "Port $MySqlPort is already in use by another program. Re-run with -MySqlPort <free port>."
    }

    $ini = Join-Path $InstallDir 'my.ini'
    $bd = $MySqlHome.Replace('\', '/'); $dd = $DataDir.Replace('\', '/')
    @"
[mysqld]
basedir=$bd
datadir=$dd
port=$MySqlPort
bind-address=127.0.0.1
mysqlx=OFF
character-set-server=utf8mb4
"@ | Set-Content $ini -Encoding ASCII

    if ($fresh) {
        $alphabet = [char[]]'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
        $DbPassword = -join (1..24 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
        Write-Host '    initialising data directory'
        if (Test-Path $DataDir) { Remove-Item $DataDir -Recurse -Force }
        $ip = Start-Process $mysqld -ArgumentList "--defaults-file=`"$ini`"", '--initialize-insecure' -Wait -PassThru -WindowStyle Hidden
        if ($ip.ExitCode -ne 0) { Fail 'MySQL initialisation failed' }
        $init = Join-Path $InstallDir 'init.sql'
        "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DbPassword';" | Set-Content $init -Encoding ASCII
        Start-Process $mysqld -ArgumentList "--defaults-file=`"$ini`"", "--init-file=`"$init`"", '--console' -WindowStyle Hidden
    } else {
        Write-Host '    existing data directory kept; root password left unchanged'
        if (Test-Path $envFile) {
            $old = (Get-Content $envFile | Where-Object { $_ -like 'MYSQL_PASSWORD=*' }) -replace '^MYSQL_PASSWORD=', ''
            if ($old) { $DbPassword = $old }
        }
        if (-not (Test-Port $MySqlPort)) {
            Start-Process $mysqld -ArgumentList "--defaults-file=`"$ini`"", '--console' -WindowStyle Hidden
        }
    }
    Write-Host '    waiting for MySQL to start'
    $ok = $false
    for ($i = 0; $i -lt 90; $i++) { if (Test-Port $MySqlPort) { $ok = $true; break }; Start-Sleep 1 }
    if (-not $ok) { Fail 'MySQL did not start within 90 seconds' }
    Start-Sleep 3
    Remove-Item (Join-Path $InstallDir 'init.sql') -Force -ErrorAction SilentlyContinue
}

Step 'Writing configuration'
@"
MYSQL_HOST=$DbHost
MYSQL_PORT=$DbPort
MYSQL_USER=$DbUser
MYSQL_PASSWORD=$DbPassword
"@ | Set-Content $envFile -Encoding ASCII

# ---------------------------------------------------------------- 4. Launchers
Step 'Creating launchers'
$start = @'
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = @{}
Get-Content (Join-Path $root 'app\.env') | ForEach-Object { if ($_ -match '^([^=]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] } }
function Test-Port($p) { $c = New-Object Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1', $p); $true } catch { $false } finally { $c.Close() } }
$mysqld = Join-Path $root 'mysql\bin\mysqld.exe'
if ((Test-Path $mysqld) -and -not (Test-Port ([int]$cfg['MYSQL_PORT']))) {
    Write-Host 'Starting MySQL...'
    Start-Process $mysqld -ArgumentList "--defaults-file=`"$(Join-Path $root 'my.ini')`"", '--console' -WindowStyle Hidden
    for ($i = 0; $i -lt 90 -and -not (Test-Port ([int]$cfg['MYSQL_PORT'])); $i++) { Start-Sleep 1 }
}
$env:REPORTER_PORT = '@WEBPORT@'
Set-Location (Join-Path $root 'app')
Start-Process 'http://127.0.0.1:@WEBPORT@'
Write-Host 'TheReporter admin is running on http://127.0.0.1:@WEBPORT@  (close this window to stop it)'
& (Join-Path $root 'venv\Scripts\python.exe') -m reporter.web
'@.Replace('@WEBPORT@', "$WebPort")
Set-Content (Join-Path $InstallDir 'Start-TheReporter.ps1') $start -Encoding ASCII

$stop = @'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = @{}
Get-Content (Join-Path $root 'app\.env') | ForEach-Object { if ($_ -match '^([^=]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] } }
$admin = Join-Path $root 'mysql\bin\mysqladmin.exe'
if (Test-Path $admin) {
    & $admin -h 127.0.0.1 -P $cfg['MYSQL_PORT'] -u $cfg['MYSQL_USER'] "-p$($cfg['MYSQL_PASSWORD'])" shutdown
    Write-Host 'MySQL stopped.'
} else { Write-Host 'No private MySQL to stop.' }
'@
Set-Content (Join-Path $InstallDir 'Stop-MySQL.ps1') $stop -Encoding ASCII

foreach ($n in 'Start-TheReporter', 'Stop-MySQL') {
    "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$n.ps1`"`r`npause" |
        Set-Content (Join-Path $InstallDir "$n.cmd") -Encoding ASCII
}
Copy-Item (Join-Path $PSScriptRoot 'Uninstall-TheReporter.ps1') $InstallDir -Force

if (-not $NoShortcuts) {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'TheReporter Admin.lnk'))
    $lnk.TargetPath = Join-Path $InstallDir 'Start-TheReporter.cmd'
    $lnk.WorkingDirectory = $InstallDir
    $lnk.Save()
}

# ---------------------------------------------------------------- Verify
Step 'Verifying installation'
Push-Location $AppDir
$ErrorActionPreference = 'Continue'
$ver = & $venvPy -c "from reporter.db import connect,install_procedures;c=connect();install_procedures(c);cur=c.cursor();cur.execute('select version()');print(cur.fetchone()[0])" 2>$null
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Pop-Location
if ($code -ne 0) { Fail 'The application could not connect to MySQL / initialise its control schema' }

Write-Host "`nInstallation complete." -ForegroundColor Green
Write-Host "  MySQL         : $ver on ${DbHost}:$DbPort"
Write-Host "  Install folder: $InstallDir"
Write-Host "  Start         : 'TheReporter Admin' desktop shortcut (or $InstallDir\Start-TheReporter.cmd)"
Write-Host "  CLI           : cd $AppDir ; $venvPy -m reporter.cli --help"
