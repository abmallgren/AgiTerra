<#
.SYNOPSIS
    Idempotent Automated Deployment Script for Windows.
.DESCRIPTION
    Safely creates structures, skips cached downloads/installations, handles smart 
    conditional service registration, prevents duplicate firewall rules, and updates PATH.
.PARAMETER DriveLetter
    The target drive letter where the environment will be installed (default: D).
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidatePattern("^[a-zA-Z]$")]
    [string]$DriveLetter = "D"
)

# 1. Elevate & Initialize Transcript Logging
If (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator! Please restart PowerShell as Administrator."
    Exit 1
}

$DriveLetter = $DriveLetter.ToUpper()
$ProgramDir = "${DriveLetter}:\Program"
$InstallersDir = "$ProgramDir\Installers"

if (-not (Test-Path $ProgramDir)) { New-Item -ItemType Directory -Path $ProgramDir -Force | Out-Null }
Start-Transcript -Path "$ProgramDir\EnvironmentSetup.log" -Force | Out-Null

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " IDEMPOTENT DEPLOYMENT ENGINE STARTING (${ProgramDir}) " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 2. Directory Matrix Initialization (Idempotent)
$Dirs = @(
    $InstallersDir,
    "$ProgramDir\VSCode",
    "$ProgramDir\VisualStudio",
    "$ProgramDir\PostgreSQL",
    "$ProgramDir\MongoDB\Development\data",
    "$ProgramDir\MongoDB\Development\log",
    "$ProgramDir\MongoDB\Assurance\data",
    "$ProgramDir\MongoDB\Assurance\log",
    "$ProgramDir\MongoDB\Default\data",
    "$ProgramDir\MongoDB\Default\log",
    "$ProgramDir\NGINX",
    "$ProgramDir\PHP",
    "$ProgramDir\WinACME",
    "$ProgramDir\PowerBI",
    "$ProgramDir\PowerAutomate",
    "$ProgramDir\Git",
    "$ProgramDir\Python",
    "$ProgramDir\NodeJS"
)

foreach ($dir in $Dirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "[CREATED DIRECTORY] $dir" -ForegroundColor Green
    }
}

function Download-File {
    param ($Url, $OutFile)
    if (-not (Test-Path $OutFile)) {
        Write-Host "Downloading: $Url ..." -ForegroundColor Yellow
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Error "Failed to download $Url. Details: $_"
            Exit 1
        }
    } else {
        Write-Host "[CACHED] Already downloaded: $OutFile" -ForegroundColor DarkGreen
    }
}

# Download WinSW service wrapper utility bundle
$winSwExe = "$InstallersDir\WinSW-x64.exe"
Download-File "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe" $winSwExe

# -----------------------------------------------------------------------------
# 3. Core Tools & Services Installation (Conditional / Idempotent)
# -----------------------------------------------------------------------------

# Visual Studio Code
if (-not (Test-Path "$ProgramDir\VSCode\Code.exe")) {
    Write-Host "`n--- Installing Visual Studio Code ---" -ForegroundColor Cyan
    $vsCodeInstaller = "$InstallersDir\VSCodeSetup.exe"
    Download-File "https://update.code.visualstudio.com/latest/win32-x64-user/stable" $vsCodeInstaller
    Start-Process -FilePath $vsCodeInstaller -ArgumentList "/verysilent /mergetasks='addtopath,runcode' /dir=$ProgramDir\VSCode" -Wait
} else {
    Write-Host "[SKIPPED] Visual Studio Code already installed." -ForegroundColor DarkGreen
}

# Visual Studio 2026 Community
if (-not (Test-Path "$ProgramDir\VisualStudio\Common7\IDE\devenv.exe")) {
    Write-Host "`n--- Installing Visual Studio 2026 Community ---" -ForegroundColor Cyan
    $vsCommunityInstaller = "$InstallersDir\vs_community.exe"
    Download-File "https://aka.ms/vs/release/vs_community.exe" $vsCommunityInstaller
    Start-Process -FilePath $vsCommunityInstaller -ArgumentList "--installPath $ProgramDir\VisualStudio --add Microsoft.VisualStudio.Workload.ManagedDesktop --add Microsoft.VisualStudio.Workload.NetWeb --passive --norestart" -Wait
} else {
    Write-Host "[SKIPPED] Visual Studio Community already installed." -ForegroundColor DarkGreen
}

# PostgreSQL
if (-not (Test-Path "$ProgramDir\PostgreSQL\bin\psql.exe")) {
    Write-Host "`n--- Installing PostgreSQL ---" -ForegroundColor Cyan
    $pgInstaller = "$InstallersDir\postgresql-installer.exe"
    Download-File "https://get.enterprisedb.com/postgresql/postgresql-16.4-1-windows-x64.exe" $pgInstaller
    Start-Process -FilePath $pgInstaller -ArgumentList "--mode unattended --prefix $ProgramDir\PostgreSQL --datadir $ProgramDir\PostgreSQL\data --superpassword 'AdminPassword123!' --serverport 5432 --unattendedmodeui none" -Wait
} else {
    Write-Host "[SKIPPED] PostgreSQL already installed." -ForegroundColor DarkGreen
}

# MongoDB (3 Instances: Development, Assurance, Default)
Write-Host "`n--- Checking MongoDB & Multi-Instance Setup ---" -ForegroundColor Cyan
$mongoInstaller = "$InstallersDir\mongodb.msi"
Download-File "https://fastdl.mongodb.org/windows/mongodb-windows-x86_64-7.0.14-signed.msi" $mongoInstaller

if (-not (Test-Path "$ProgramDir\MongoDB\Server\bin\mongod.exe")) {
    Start-Process "msiexec.exe" -ArgumentList "/i `"$mongoInstaller`" /quiet /norestart INSTALLLOCATION=`"$ProgramDir\MongoDB\Server`" ADDLOCAL=`"ServerService,Client`" SHOULD_INSTALL_COMPASS=0" -Wait
}

$devConfig  = "$ProgramDir\MongoDB\Development\mongod.cfg"
$assConfig  = "$ProgramDir\MongoDB\Assurance\mongod.cfg"
$defConfig  = "$ProgramDir\MongoDB\Default\mongod.cfg"

"storage:`n  dbPath: $ProgramDir\MongoDB\Development\data`nsystemLog:`n  destination: file`n  path: $ProgramDir\MongoDB\Development\log\mongod.log`nnet:`n  port: 27018" | Set-Content $devConfig
"storage:`n  dbPath: $ProgramDir\MongoDB\Assurance\data`nsystemLog:`n  destination: file`n  path: $ProgramDir\MongoDB\Assurance\log\mongod.log`nnet:`n  port: 27019" | Set-Content $assConfig
"storage:`n  dbPath: $ProgramDir\MongoDB\Default\data`nsystemLog:`n  destination: file`n  path: $ProgramDir\MongoDB\Default\log\mongod.log`nnet:`n  port: 27017" | Set-Content $defConfig

$mongodPath = "$ProgramDir\MongoDB\Server\bin\mongod.exe"
$mongoInstances = @(
    @{ Name = "MongoDB_Development"; Config = $devConfig },
    @{ Name = "MongoDB_Assurance"; Config = $assConfig },
    @{ Name = "MongoDB_Default"; Config = $defConfig }
)

foreach ($inst in $mongoInstances) {
    if (-not (Get-Service -Name $inst.Name -ErrorAction SilentlyContinue)) {
        & $mongodPath --config $inst.Config --install --serviceName $inst.Name --serviceDisplayName "$($inst.Name)"
        Write-Host "[REGISTERED SERVICE] $($inst.Name)" -ForegroundColor Green
    }
    if ((Get-Service -Name $inst.Name).Status -ne 'Running') {
        Start-Service $inst.Name
    }
}

# NGINX via WinSW (Idempotent check)
Write-Host "`n--- Checking NGINX & WinSW Service ---" -ForegroundColor Cyan
if (-not (Test-Path "$ProgramDir\NGINX\nginx.exe")) {
    $nginxZip = "$InstallersDir\nginx.zip"
    Download-File "https://nginx.org/download/nginx-1.26.2.zip" $nginxZip
    Expand-Archive -Path $nginxZip -DestinationPath "$ProgramDir\NGINX-temp" -Force
    Move-Item -Path "$ProgramDir\NGINX-temp\nginx-1.26.2\*" -Destination "$ProgramDir\NGINX" -Force
    Remove-Item -Path "$ProgramDir\NGINX-temp" -Recurse -Force
}

Copy-Item $winSwExe "$ProgramDir\NGINX\service.exe" -Force
$nginxXml = @"
<service>
  <id>nginx</id>
  <name>NGINX Web Server</name>
  <description>NGINX HTTP Server managed via WinSW</description>
  <executable>$ProgramDir\NGINX\nginx.exe</executable>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>8</keepFiles>
  </log>
</service>
"@
$nginxXml | Set-Content "$ProgramDir\NGINX\service.xml"

if (-not (Get-Service -Name "nginx" -ErrorAction SilentlyContinue)) {
    Start-Process "$ProgramDir\NGINX\service.exe" -ArgumentList "install" -Wait
}
if ((Get-Service -Name "nginx").Status -ne 'Running') { Start-Service "nginx" }

# PHP & PHP FastCGI via WinSW (Idempotent check)
Write-Host "`n--- Checking PHP & PHP FastCGI Service ---" -ForegroundColor Cyan
if (-not (Test-Path "$ProgramDir\PHP\php.exe")) {
    $phpZip = "$InstallersDir\php.zip"
    Download-File "https://windows.php.net/downloads/releases/php-8.3.12-nts-Win32-vs16-x64.zip" $phpZip
    Expand-Archive -Path $phpZip -DestinationPath "$ProgramDir\PHP" -Force
}

Copy-Item $winSwExe "$ProgramDir\PHP\service.exe" -Force
$phpCgiXml = @"
<service>
  <id>php-cgi</id>
  <name>PHP FastCGI Service</name>
  <description>PHP FastCGI Binary Wrapper on Port 9000</description>
  <executable>$ProgramDir\PHP\php-cgi.exe</executable>
  <arguments>-b 127.0.0.1:9000</arguments>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>8</keepFiles>
  </log>
</service>
"@
$phpCgiXml | Set-Content "$ProgramDir\PHP\service.xml"

if (-not (Get-Service -Name "php-cgi" -ErrorAction SilentlyContinue)) {
    Start-Process "$ProgramDir\PHP\service.exe" -ArgumentList "install" -Wait
}
if ((Get-Service -Name "php-cgi").Status -ne 'Running') { Start-Service "php-cgi" }

# Win-ACME
if (-not (Test-Path "$ProgramDir\WinACME\wacs.exe")) {
    Write-Host "`n--- Installing Win-ACME ---" -ForegroundColor Cyan
    $winAcmeZip = "$InstallersDir\winacme.zip"
    Download-File "https://github.com/win-acme/win-acme/releases/download/v2.2.9/win-acme.v2.2.9.1x64.trimmed.zip" $winAcmeZip
    Expand-Archive -Path $winAcmeZip -DestinationPath "$ProgramDir\WinACME" -Force
}

# Winget Deployments (Idempotent check built into winget)
Write-Host "`n--- Ensuring Winget Packages are Up-to-Date ---" -ForegroundColor Cyan
winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements --override "/VERYSILENT /DIR=$ProgramDir\Git"
winget install --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements --override "/quiet InstallAllUsers=1 TargetDir=$ProgramDir\Python"
winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.PowerBI --silent --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.PowerAutomate.Desktop --silent --accept-package-agreements --accept-source-agreements


# -----------------------------------------------------------------------------
# 4. Idempotent Environment PATH Injection
# -----------------------------------------------------------------------------
Write-Host "`n--- Checking System Environment PATH ---" -ForegroundColor Cyan
$targetPaths = @(
    "$ProgramDir\Git\bin",
    "$ProgramDir\Python",
    "$ProgramDir\Python\Scripts",
    "$ProgramDir\NodeJS",
    "$ProgramDir\PostgreSQL\bin",
    "$ProgramDir\PHP",
    "$ProgramDir\NGINX"
)

$envPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
foreach ($p in $targetPaths) {
    if ($envPath -notlike "*$p*") {
        $envPath += ";$p"
        Write-Host "[PATH ADDED] $p" -ForegroundColor Green
    }
}
[Environment]::SetEnvironmentVariable("Path", $envPath, "Machine")


# -----------------------------------------------------------------------------
# 5. Idempotent Windows Firewall Configuration
# -----------------------------------------------------------------------------
Write-Host "`n--- Ensuring Windows Firewall Rules Exist ---" -ForegroundColor Cyan
$rules = @(
    @{ Name = "PostgreSQL"; Port = 5432 },
    @{ Name = "MongoDB Instances"; Port = "27017,27018,27019" },
    @{ Name = "NGINX Web Server"; Port = "80,443" },
    @{ Name = "PHP FastCGI"; Port = 9000 }
)

foreach ($r in $rules) {
    if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol TCP -LocalPort $r.Port -Action Allow | Out-Null
        Write-Host "[FIREWALL RULE CREATED] $($r.Name)" -ForegroundColor Green
    } else {
        Write-Host "[FIREWALL RULE EXISTS] $($r.Name)" -ForegroundColor DarkGreen
    }
}


# -----------------------------------------------------------------------------
# 6. Service Self-Healing Recovery Policies
# -----------------------------------------------------------------------------
Write-Host "`n--- Ensuring Service Auto-Recovery Policies ---" -ForegroundColor Cyan
$servicesToProtect = @("nginx", "php-cgi", "MongoDB_Default", "MongoDB_Development", "MongoDB_Assurance", "postgresql-x64-16")
foreach ($svc in $servicesToProtect) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        sc.exe failure $svc reset= 86400 actions= restart/5000/restart/5000/restart/10000 | Out-Null
    }
}

Stop-Transcript | Out-Null

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " IDEMPOTENT DEPLOYMENT COMPLETED SUCCESSFULLY!      " -ForegroundColor Cyan
Write-Host " Log file saved to: ${ProgramDir}\EnvironmentSetup.log" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan