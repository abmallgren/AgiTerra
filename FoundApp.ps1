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

# MongoDB cannot use FAT/exFAT for its config file, data, or logs (mongod reports the config as "not found").
# If the target drive is not NTFS, keep those on the system drive; the binaries can stay on the target drive.
$driveFs = (Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue).FileSystemType
if ($driveFs -eq 'NTFS') { $MongoDataRoot = "$ProgramDir\MongoDB" } else { $MongoDataRoot = "$env:ProgramData\MongoDB" }

if (-not (Test-Path $ProgramDir)) { New-Item -ItemType Directory -Path $ProgramDir -Force | Out-Null }
try { Stop-Transcript | Out-Null } catch {}
Start-Transcript -Path "$ProgramDir\EnvironmentSetup.log" -Force | Out-Null

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " IDEMPOTENT DEPLOYMENT ENGINE STARTING (${ProgramDir}) " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
if ($MongoDataRoot -ne "$ProgramDir\MongoDB") {
    Write-Warning "${DriveLetter}: is $driveFs, not NTFS. MongoDB config, data, and logs will live in $MongoDataRoot (binaries stay in $ProgramDir\MongoDB\Server)."
}

# 2. Directory Matrix Initialization (Idempotent)
$Dirs = @(
    $InstallersDir,
    "$ProgramDir\VSCode",
    "$ProgramDir\VisualStudio",
    "$ProgramDir\PostgreSQL",
    "$MongoDataRoot\Development\data",
    "$MongoDataRoot\Development\log",
    "$MongoDataRoot\Assurance\data",
    "$MongoDataRoot\Assurance\log",
    "$MongoDataRoot\Default\data",
    "$MongoDataRoot\Default\log",
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
    # $Url may be a single URL or a list of fallback URLs (tried in order).
    # Downloads to a .part file and renames on success, so an interrupted or failed
    # download can never be mistaken for a cached, complete file on the next run.
    param ([string[]]$Url, $OutFile)
    if (Test-Path $OutFile) {
        Write-Host "[CACHED] Already downloaded: $OutFile" -ForegroundColor DarkGreen
        return
    }
    $part = "$OutFile.part"
    foreach ($u in $Url) {
        try {
            Write-Host "Downloading: $u ..." -ForegroundColor Yellow
            if (Test-Path $part) { Remove-Item $part -Force }
            Invoke-WebRequest -Uri $u -OutFile $part -UseBasicParsing -ErrorAction Stop
            Move-Item $part $OutFile -Force
            return
        } catch {
            Write-Warning "Download failed from $u : $_"
            if (Test-Path $part) { Remove-Item $part -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-Error "Failed to download $OutFile from all sources."
    try { Stop-Transcript | Out-Null } catch {}
    Exit 1
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

# Visual Studio 2026 Community (bootstrapper is downloaded into the Installers folder,
# validated, then launched; install target is $ProgramDir\VisualStudio)
$vsTargetExe = "$ProgramDir\VisualStudio\Common7\IDE\devenv.exe"
$vsUrl       = "https://aka.ms/vs/18/stable/vs_community.exe"

if (-not (Test-Path $vsTargetExe)) {
    Write-Host "`n--- Installing Visual Studio 2026 Community ---" -ForegroundColor Cyan
    $vsInstaller = "$InstallersDir\vs_community.exe"

    # Always start clean: never reuse a stale or corrupt bootstrapper
    if (Test-Path $vsInstaller) {
        Remove-Item $vsInstaller -Force -ErrorAction SilentlyContinue
    }

    $vsReady = $false
    try {
        Write-Host "Downloading VS Community to $InstallersDir ..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $vsUrl -OutFile $vsInstaller -UseBasicParsing -ErrorAction Stop

        # Validate before launching: size, "MZ" header, and Microsoft signature
        $vsSize = (Get-Item $vsInstaller).Length
        $vsHead = [System.IO.File]::ReadAllBytes($vsInstaller)[0..1]
        $vsSig  = Get-AuthenticodeSignature $vsInstaller

        if ($vsSize -lt 1MB -or $vsHead[0] -ne 0x4D -or $vsHead[1] -ne 0x5A -or $vsSig.Status -ne 'Valid') {
            Write-Warning "VS installer failed validation (size: $vsSize bytes, signature: $($vsSig.Status)). Skipping Visual Studio."
        } else {
            $vsReady = $true
        }
    } catch {
        Write-Warning "VS installer download/validation failed: $_"
    }

    if ($vsReady) {
        Write-Host "Launching Visual Studio installer..." -ForegroundColor Yellow
        $vsArgs = "--installPath `"$ProgramDir\VisualStudio`" --add Microsoft.VisualStudio.Workload.ManagedDesktop --add Microsoft.VisualStudio.Workload.NetWeb --passive --norestart --wait"
        # Don't use Start-Process -Wait here: it also waits on every child process the
        # bootstrapper spawns (vs_installer / setup), which can outlive the install and hang the script.
        # --wait makes the bootstrapper itself block until the install completes.
        $vsProc = Start-Process -FilePath $vsInstaller -ArgumentList $vsArgs -PassThru
        $vsProc.WaitForExit()

        if ($vsProc.ExitCode -eq 0) {
            Write-Host "[INSTALLED] Visual Studio Community" -ForegroundColor Green
        } elseif ($vsProc.ExitCode -eq 3010) {
            Write-Host "[INSTALLED] Visual Studio Community (reboot required to finish)" -ForegroundColor Yellow
        } else {
            Write-Warning "Visual Studio installer exited with code $($vsProc.ExitCode)."
        }
        Remove-Item $vsInstaller -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "[SKIPPED] Visual Studio Community already installed." -ForegroundColor DarkGreen
}

# PostgreSQL
if (-not (Test-Path "$ProgramDir\PostgreSQL\bin\psql.exe")) {
    Write-Host "`n--- Installing PostgreSQL ---" -ForegroundColor Cyan
    $pgInstaller = "$InstallersDir\postgresql-installer.exe"
    
    # Updated to PostgreSQL 18.7
    Download-File "https://get.enterprisedb.com/postgresql/postgresql-18.7-1-windows-x64.exe" $pgInstaller
    
    Start-Process -FilePath $pgInstaller -ArgumentList "--mode unattended --prefix $ProgramDir\PostgreSQL --datadir $ProgramDir\PostgreSQL\data --superpassword 'AdminPassword123!' --serverport 5432 --unattendedmodeui none" -Wait
} else {
    Write-Host "[SKIPPED] PostgreSQL already installed." -ForegroundColor DarkGreen
}

# MongoDB (3 Instances: Development, Assurance, Default)
Write-Host "`n--- Checking MongoDB & Multi-Instance Setup ---" -ForegroundColor Cyan
$mongoInstaller = "$InstallersDir\mongodb.msi"
$mongodPath     = "$ProgramDir\MongoDB\Server\bin\mongod.exe"

# A cached MSI from an interrupted download fails silently under /quiet, so verify its signature first
if ((Test-Path $mongoInstaller) -and ((Get-AuthenticodeSignature $mongoInstaller).Status -ne 'Valid')) {
    Write-Warning "Cached mongodb.msi failed signature check; re-downloading."
    Remove-Item $mongoInstaller -Force
}
Download-File "https://fastdl.mongodb.org/windows/mongodb-windows-x86_64-7.0.14-signed.msi" $mongoInstaller

if (-not (Test-Path $mongodPath)) {
    Write-Host "Installing MongoDB binaries..." -ForegroundColor Yellow
    $msiLog = "$InstallersDir\mongodb-install.log"
    # ServerNoService = mongod.exe only. The three services are registered below, so the MSI must not
    # create its own default "MongoDB" service on 27017 (it would collide with MongoDB_Default).
    # "Client" is not a valid MSI feature name for MongoDB 7.0 Community.
    $msiArgs = "/i `"$mongoInstaller`" /quiet /norestart /l*v `"$msiLog`" INSTALLLOCATION=`"$ProgramDir\MongoDB\Server`" ADDLOCAL=`"ServerNoService`" SHOULD_INSTALL_COMPASS=0"
    $msiProc = Start-Process "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
    if ($msiProc.ExitCode -notin 0, 3010) {
        Write-Warning "MongoDB MSI exited with code $($msiProc.ExitCode). See $msiLog (search for 'Return value 3')."
    }
}

if (-not (Test-Path $mongodPath)) {
    Write-Warning "mongod.exe not found at $mongodPath - skipping MongoDB service setup."
} else {
    $devConfig  = "$MongoDataRoot\Development\mongod.cfg"
    $assConfig  = "$MongoDataRoot\Assurance\mongod.cfg"
    $defConfig  = "$MongoDataRoot\Default\mongod.cfg"

    "storage:`n  dbPath: $MongoDataRoot\Development\data`nsystemLog:`n  destination: file`n  path: $MongoDataRoot\Development\log\mongod.log`nnet:`n  port: 27018" | Set-Content $devConfig
    "storage:`n  dbPath: $MongoDataRoot\Assurance\data`nsystemLog:`n  destination: file`n  path: $MongoDataRoot\Assurance\log\mongod.log`nnet:`n  port: 27019" | Set-Content $assConfig
    "storage:`n  dbPath: $MongoDataRoot\Default\data`nsystemLog:`n  destination: file`n  path: $MongoDataRoot\Default\log\mongod.log`nnet:`n  port: 27017" | Set-Content $defConfig

    $mongoInstances = @(
        @{ Name = "MongoDB_Development"; Config = $devConfig },
        @{ Name = "MongoDB_Assurance"; Config = $assConfig },
        @{ Name = "MongoDB_Default"; Config = $defConfig }
    )

    foreach ($inst in $mongoInstances) {
        if (-not (Test-Path $inst.Config)) {
            Write-Warning "Config file not found after writing it: $($inst.Config) - skipping $($inst.Name)."
            continue
        }
        Write-Host "[CONFIG OK] $($inst.Config) ($((Get-Item $inst.Config).Length) bytes)" -ForegroundColor DarkGreen

        # Same registration "mongod --install" performs, done directly through the Service Control Manager
        $binPath = "`"$mongodPath`" --config `"$($inst.Config)`" --service --serviceName $($inst.Name) --serviceDisplayName $($inst.Name)"
        $svcInfo = Get-CimInstance Win32_Service -Filter "Name='$($inst.Name)'" -ErrorAction SilentlyContinue

        if (-not $svcInfo) {
            try {
                New-Service -Name $inst.Name -BinaryPathName $binPath -DisplayName $inst.Name -StartupType Automatic -ErrorAction Stop | Out-Null
                Write-Host "[REGISTERED SERVICE] $($inst.Name)" -ForegroundColor Green
            } catch {
                Write-Warning "Failed to register service $($inst.Name): $_"
                continue
            }
        } elseif ($svcInfo.PathName -ne $binPath) {
            # e.g. a service registered earlier against a config path that no longer applies
            $chg = Invoke-CimMethod -InputObject $svcInfo -MethodName Change -Arguments @{ PathName = $binPath }
            if ($chg.ReturnValue -ne 0) {
                Write-Warning "Could not update the command line of $($inst.Name) (code $($chg.ReturnValue))."
                continue
            }
            Write-Host "[UPDATED SERVICE PATH] $($inst.Name)" -ForegroundColor Green
        }

        if ((Get-Service -Name $inst.Name).Status -ne 'Running') {
            try {
                Start-Service $inst.Name -ErrorAction Stop
            } catch {
                $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                Write-Warning "Service $($inst.Name) did not start: $why (see the instance's log\mongod.log under $MongoDataRoot)"
            }
        }
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

if (-not (Test-Path "$ProgramDir\NGINX\service.exe")) { Copy-Item $winSwExe "$ProgramDir\NGINX\service.exe" -Force }
$nginxXml = @"
<service>
  <id>nginx</id>
  <name>NGINX Web Server</name>
  <description>NGINX HTTP Server managed via WinSW</description>
  <executable>D:\Program\NGINX\nginx.exe</executable>
  <arguments>-p D:\Program\NGINX</arguments>
  <workingdirectory>D:\Program\NGINX</workingdirectory>
  <stopexecutable>D:\Program\NGINX\nginx.exe</stopexecutable>
  <stoparguments>-p D:\Program\NGINX -s quit</stoparguments>
  <startmode>Automatic</startmode>
  <logpath>D:\Program\NGINX\logs\winsw</logpath>
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
    # 8.3.14 was moved out of /releases/ (404). The "-latest" file always points at the newest 8.3.x build.
    Download-File @(
        "https://windows.php.net/downloads/releases/latest/php-8.3-nts-Win32-vs16-x64-latest.zip",
        "https://www.php.net/~windows/releases/latest/php-8.3-nts-Win32-vs16-x64-latest.zip",
        "https://windows.php.net/downloads/releases/archives/php-8.3.14-nts-Win32-vs16-x64.zip"
    ) $phpZip
    Expand-Archive -Path $phpZip -DestinationPath "$ProgramDir\PHP" -Force
}

if (-not (Test-Path "$ProgramDir\PHP\service.exe")) { Copy-Item $winSwExe "$ProgramDir\PHP\service.exe" -Force }
$phpCgiXml = @"
<service>
  <id>php-cgi</id>
  <name>PHP FastCGI Service</name>
  <description>PHP FastCGI Binary Wrapper on Port 9000</description>
  <executable>D:\Program\PHP\php-cgi.exe</executable>
  <arguments>-b 127.0.0.1:9000</arguments>
  <workingdirectory>D:\Program\PHP</workingdirectory>
  <env name="PHPRC" value="D:\Program\PHP"/>
  <env name="PHP_FCGI_MAX_REQUESTS" value="500"/>
  <startmode>Automatic</startmode>
  <logpath>D:\Program\PHP\logs</logpath>
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

$phpIni = @"
extension_dir="D:/Program/PHP/ext"
extension=curl
extension=openssl
extension=pdo_pgsql
extension=pgsql
extension=zip

"@
$phpIni | Set-Content "$ProgramDir\PHP\php.ini"

# Composer
Write-Host "`n--- Composer" -ForegroundColor Cyan

if (-not (Test-Path -Path "$ProgramDir\Composer" -PathType Container)) {
    New-Item -ItemType Directory -Path "$ProgramDir\Composer"
}
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php composer-setup.php --install-dir="$ProgramDir\Composer" --filename=composer
php -r "unlink('composer-setup.php');"

Set-Content -Path "$ProgramDir\Composer\composer.bat" -Value '@php "%~dp0composer" %*'

$currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($currentPath -notlike "*$ProgramDir\Composer*") {
    [Environment]::SetEnvironmentVariable("Path", "$currentPath;$ProgramDir\Composer", "User")
}

# Win-ACME
if (-not (Test-Path "$ProgramDir\WinACME\wacs.exe")) {
    Write-Host "`n--- Installing Win-ACME ---" -ForegroundColor Cyan
    $winAcmeZip = "$InstallersDir\winacme.zip"
    Download-File "https://github.com/win-acme/win-acme/releases/download/v2.2.9.1701/win-acme.v2.2.9.1701.x64.trimmed.zip" $winAcmeZip
    Expand-Archive -Path $winAcmeZip -DestinationPath "$ProgramDir\WinACME" -Force
}

# Winget Deployments (Idempotent check built into winget)
# --source winget: the msstore source fails certificate pinning (0x8a15005e) on networks/AV that inspect TLS,
# and winget refuses to proceed unless a single source is named.
Write-Host "`n--- Ensuring Winget Packages are Up-to-Date ---" -ForegroundColor Cyan
winget install --id Git.Git --source winget --silent --accept-package-agreements --accept-source-agreements --override "/VERYSILENT /DIR=$ProgramDir\Git"
winget install --id Python.Python.3.12 --source winget --silent --accept-package-agreements --accept-source-agreements --override "/quiet InstallAllUsers=1 TargetDir=$ProgramDir\Python"
winget install --id OpenJS.NodeJS.LTS --source winget --silent --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.PowerBI --source winget --silent --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.PowerAutomateDesktop --source winget --silent --accept-package-agreements --accept-source-agreements
winget install --id PostgreSQL.pgAdmin --source winget --silent --accept-package-agreements --accept-source-agreements

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

foreach ($r in $rules) {
    if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
        try {
            # -LocalPort takes an array of ports, not one comma-separated string
            $ports = [string[]]("$($r.Port)" -split ',')
            New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol TCP -LocalPort $ports -Action Allow -ErrorAction Stop | Out-Null
            Write-Host "[FIREWALL RULE CREATED] $($r.Name)" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to create firewall rule $($r.Name): $_"
        }
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