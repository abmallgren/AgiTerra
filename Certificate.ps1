<#
.SYNOPSIS
    Fully Dynamic Automated Win-ACME Certificate Generator
.DESCRIPTION
    Scans a web root folder, maps subfolders like 'Production' or 'www' directly to root domains,
    treats other folders as subdomains, and generates SSL certificates using Win-ACME.
    All directories, paths, and configurations are fully dynamic via parameters.
.PARAMETER WebRoot
    The base directory containing your domain folders. Default is 'D:\Web'.
.PARAMETER CertDir
    The directory where generated PEM certificates will be saved. Default is '$WebRoot\Certificate'.
.PARAMETER WacsPath
    The absolute path to the Win-ACME executable (wacs.exe). Default is 'D:\Program\WinACME\wacs.exe'.
.PARAMETER Email
    The contact email address registered with Let's Encrypt. Default is 'admin@domain.com'.
.PARAMETER Validation
    The validation method to use. Options: 'filesystem', 'cloudflare'. Default is 'filesystem'.
.PARAMETER CloudflareToken
    Your Cloudflare API token (required only if Validation is set to 'cloudflare').
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$WebRoot = "D:\Web",

    [Parameter(Mandatory=$false)]
    [string]$CertDir = "",

    [Parameter(Mandatory=$false)]
    [string]$WacsPath = "D:\Program\WinACME\wacs.exe",

    [Parameter(Mandatory=$true)]
    [string]$Email = "admin@domain.com",

    [Parameter(Mandatory=$false)]
    [ValidateSet('filesystem', 'cloudflare')]
    [string]$Validation = 'filesystem',

    [Parameter(Mandatory=$false)]
    [string]$CloudflareToken = ''
)

if ([string]::IsNullOrEmpty($CertDir)) {
    $CertDir = Join-Path $WebRoot "Certificate"
}

if (-not (Test-Path $CertDir)) {
    New-Item -ItemType Directory -Path $CertDir | Out-Null
    Write-Host "[INFO] Created Certificate directory: $CertDir" -ForegroundColor Green
}

if (-not (Test-Path $WacsPath)) {
    Write-Error "Win-ACME executable not found at '$WacsPath'. Please verify your path."
    exit 1
}

if ($Validation -eq 'cloudflare') {
    if ([string]::IsNullOrEmpty($CloudflareToken)) {
        Write-Error "Cloudflare validation selected, but no -CloudflareToken was provided."
        exit 1
    }
    [Environment]::SetEnvironmentVariable("WACS_CLOUDFLARE_API_KEY", $CloudflareToken, "Process")
    Write-Host "[INFO] Injected Cloudflare API token for unattended execution." -ForegroundColor Green
}

$DomainFolders = Get-ChildItem -Path $WebRoot -Directory | Where-Object { 
    $_.Name -ne "Certificate" -and $_.Name -ne "Program" -and $_.Name -ne "Shared" 
}

foreach ($domainFolder in $DomainFolders) {
    $RootDomain = $domainFolder.Name
    $DomainPath = $domainFolder.FullName

    Write-Host "`n----------------------------------------" -ForegroundColor Cyan
    Write-Host "Processing Root Domain Folder: $RootDomain" -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor Cyan

    $RootSourcePath = $DomainPath
    $HasSubFolders = $false

    $SubFolders = Get-ChildItem -Path $DomainPath -Directory
    if ($SubFolders) {
        $HasSubFolders = $true
        foreach ($subFolder in $SubFolders) {
            $SubName = $subFolder.Name
            if ($SubName -eq "Production" -or $SubName -eq "www") {
                $RootSourcePath = $subFolder.FullName
                Write-Host "[+] Found '$SubName' subfolder. Mapping it directly to root domain: $RootDomain" -ForegroundColor Green
                break
            }
        }
    }

    $RootWacsArgs = @(
        "--source", "manual",
        "--host", $RootDomain,
        "--validation", $Validation,
        "--store", "pemfiles",
        "--pemfilespath", "$CertDir\$RootDomain",
        "--emailaddress", $Email,
        "--accepttos",
        "--unattended"
    )

    if ($Validation -eq 'filesystem') {
        $RootWacsArgs += "--webroot"
        $RootWacsArgs += $RootSourcePath
    }

    Write-Host "[+] Requesting certificate for root: $RootDomain (Validation: $Validation)" -ForegroundColor Yellow
    & $WacsPath @RootWacsArgs

    if ($HasSubFolders) {
        foreach ($subFolder in $SubFolders) {
            $SubName = $subFolder.Name
            
            if ($SubName -eq "Production" -or $SubName -eq "www") {
                continue
            }

            $FullDomain = "$SubName.$RootDomain"
            $SubPath = $subFolder.FullName

            $SubWacsArgs = @(
                "--source", "manual",
                "--host", $FullDomain,
                "--validation", $Validation,
                "--store", "pemfiles",
                "--pemfilespath", "$CertDir\$FullDomain",
                "--emailaddress", $Email,
                "--accepttos",
                "--unattended"
            )

            if ($Validation -eq 'filesystem') {
                $SubWacsArgs += "--webroot"
                $SubWacsArgs += $SubPath
            }

            Write-Host "[+] Requesting certificate for subdomain: $FullDomain (Validation: $Validation)" -ForegroundColor Yellow
            & $WacsPath @SubWacsArgs
        }
    }
}

Write-Host "`n[SUCCESS] Certificate generation process completed!" -ForegroundColor Green
Write-Host "Certificates have been stored under: $CertDir" -ForegroundColor Green