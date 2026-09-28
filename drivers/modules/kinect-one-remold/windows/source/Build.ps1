[CmdletBinding()]
param([switch]$Clean)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# CMake reserves RC as the resource-compiler environment variable. Batch wrappers
# must not leak an exit-code variable with that name into this process.
if (Test-Path Env:RC) { Remove-Item Env:RC -ErrorAction SilentlyContinue }

Write-Host '[module] Kinect Remold - Xbox One' -ForegroundColor Cyan

$Root  = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
$LocalRoot=$env:LOCALAPPDATA
if([string]::IsNullOrWhiteSpace($LocalRoot)){$LocalRoot=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)}
if([string]::IsNullOrWhiteSpace($LocalRoot)){$LocalRoot=[IO.Path]::GetTempPath()}
$Work  = Join-Path $LocalRoot 'Kinect Remold\Work\windows\kinect-one-remold'

function Invoke-Native {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
    }
}

function Get-ApplicationPath {
    param([Parameter(Mandatory=$true)][string]$Name)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    return $null
}

function Get-WinGetPath {
    $path = Get-ApplicationPath 'winget.exe'
    if ($path) { return $path }
    if ($env:LOCALAPPDATA) {
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $alias -PathType Leaf) { return $alias }
    }
    return $null
}

function Get-CMakePath {
    $path = Get-ApplicationPath 'cmake.exe'
    if ($path) { return $path }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'CMake\bin\cmake.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'CMake\bin\cmake.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

function Ensure-CMake {
    $cmake = Get-CMakePath
    if ($cmake) { return $cmake }

    $winget = Get-WinGetPath
    if (-not $winget) {
        throw 'CMake is required but was not found. WinGet is also unavailable, so CMake cannot be installed automatically. Install Microsoft App Installer (WinGet) or CMake and rerun the build.'
    }

    Write-Host '[toolchain] CMake not found; installing Kitware CMake with WinGet...' -ForegroundColor Cyan
    Invoke-Native $winget 'install' '--id' 'Kitware.CMake' '--exact' '--source' 'winget' '--accept-package-agreements' '--accept-source-agreements' '--disable-interactivity'
    $cmake = Get-CMakePath
    if (-not $cmake) {
        throw 'CMake installation completed, but cmake.exe could not be located. Open a new terminal or restart Windows, then rerun Kinect-Remold.cmd --rebuild.'
    }
    return $cmake
}

function Find-WindowsKitTool {
    param([Parameter(Mandatory=$true)][string]$Name)

    # Prefer tools already exposed by the current VS/SDK environment.
    $pathTool = Get-ApplicationPath $Name
    if ($pathTool) { return $pathTool }

    $roots = @()
    if ($env:WindowsSdkDir) {
        $roots += (Join-Path $env:WindowsSdkDir 'bin')
    }
    if (${env:ProgramFiles(x86)}) {
        $roots += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin')
    }
    if ($env:ProgramFiles) {
        $roots += (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
    }
    $roots = $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique

    # Inf2Cat has existed in x86-only WDK layouts as well as newer x64 layouts.
    # Search both architectures and choose the newest kit version available.
    foreach ($root in $roots) {
        $tools = Get-ChildItem -LiteralPath $root -Filter $Name -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match '\\(x64|amd64|x86)(\\|$)' } |
            Sort-Object @{Expression={
                $m = [regex]::Match($_.FullName, '\\bin\\(\d+\.\d+\.\d+\.\d+)\\')
                if ($m.Success) { try { [version]$m.Groups[1].Value } catch { [version]'0.0' } } else { [version]'0.0' }
            }; Descending=$true}, @{Expression={ if ($_.DirectoryName -match '\\(x64|amd64)(\\|$)') { 1 } else { 0 } }; Descending=$true}, FullName
        $tool = $tools | Select-Object -First 1
        if ($tool) { return $tool.FullName }
    }
    return $null
}

function Ensure-WindowsDriverKitTools {
    $inf2cat = Find-WindowsKitTool 'Inf2Cat.exe'
    $signtool = Find-WindowsKitTool 'signtool.exe'
    if ($inf2cat -and $signtool) {
        return @($inf2cat, $signtool)
    }

    $winget = Get-WinGetPath
    if (-not $winget) {
        throw 'Windows Driver Kit (WDK) tools are missing (Inf2Cat.exe/SignTool.exe), and WinGet is unavailable. Install the WDK matching your Windows SDK, then rerun the build.'
    }

    Write-Host '[toolchain] Windows Driver Kit tools are missing; installing WDK 10.0.28000 with WinGet...' -ForegroundColor Cyan
    Invoke-Native $winget 'install' '--id' 'Microsoft.WindowsWDK.10.0.28000' '--exact' '--source' 'winget' '--accept-package-agreements' '--accept-source-agreements' '--disable-interactivity'

    # Refresh discovery after installation. The WDK installer writes directly under Windows Kits,
    # so a new PowerShell process should not be required for this search.
    $inf2cat = Find-WindowsKitTool 'Inf2Cat.exe'
    $signtool = Find-WindowsKitTool 'signtool.exe'
    if (-not $inf2cat) {
        throw 'WDK installation completed, but Inf2Cat.exe still could not be located. Verify that Windows Driver Kit 10.0.28000 is installed, then rerun the build.'
    }
    if (-not $signtool) {
        throw 'WDK installation completed, but signtool.exe still could not be located. Verify the Windows SDK/WDK installation, then rerun the build.'
    }
    return @($inf2cat, $signtool)
}

function Get-SigningCertificate {
    param([Parameter(Mandatory=$true)][string]$Stage)
    $requested = $env:KINECT_REMOLD_SIGNING_THUMBPRINT
    if ($requested) {
        $thumb = ($requested -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
        $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1
        if (-not $cert) { throw "KINECT_REMOLD_SIGNING_THUMBPRINT was set, but that certificate is not available in Cert:\CurrentUser\My." }
    } else {
        if (-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
            throw 'New-SelfSignedCertificate is required to create the local Kinect Remold driver certificate.'
        }
        $subject = 'CN=Kinect Remold Development'
        $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if (-not $cert) {
            $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(3)
        }
    }
    $cer = Join-Path $Stage 'KinectRemoldDriver.cer'
    Export-Certificate -Cert $cert -FilePath $cer -Force | Out-Null
    return $cert
}

function Ensure-NativeToolchain {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'Visual Studio 2022 or Build Tools with the Desktop development with C++ workload is required.'
    }
    $installation = (& $vswhere -latest -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath | Select-Object -First 1)
    if (-not $installation) {
        throw 'Visual Studio C++ x64 build tools are not installed.'
    }
}

if ($Clean -and (Test-Path -LiteralPath $Work)) {
    Remove-Item -LiteralPath $Work -Recurse -Force
}
New-Item -ItemType Directory -Path $Work -Force | Out-Null

Ensure-NativeToolchain
$CMake = Ensure-CMake
Write-Host ("CMake: {0}" -f $CMake) -ForegroundColor DarkGray

$Build = Join-Path $Work 'build'

$cache = Join-Path $Build 'CMakeCache.txt'
if (Test-Path -LiteralPath $cache -PathType Leaf) {
    $resetCache = $false

    $homeEntry = Select-String -LiteralPath $cache -Pattern '^CMAKE_HOME_DIRECTORY:INTERNAL=(.*)$' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($homeEntry) {
        $cachedSource = $homeEntry.Matches[0].Groups[1].Value
        try {
            $cachedSource = [IO.Path]::GetFullPath($cachedSource).TrimEnd('\', '/')
            $currentSource = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/')
            if (-not $cachedSource.Equals($currentSource, [StringComparison]::OrdinalIgnoreCase)) {
                $resetCache = $true
            }
        } catch {
            $resetCache = $true
        }
    }

    if (-not $resetCache) {
        $badRc = Select-String -LiteralPath $cache -Pattern '^CMAKE_RC_COMPILER(?::FILEPATH)?=(0|RC-NOTFOUND)$' -Quiet -ErrorAction SilentlyContinue
        if ($badRc) { $resetCache = $true }
    }

    if ($resetCache) {
        Remove-Item -LiteralPath $Build -Recurse -Force
    }
}
New-Item -ItemType Directory -Path $Build -Force | Out-Null
Write-Host '[build] Configuring Kinect Remold...' -ForegroundColor Cyan
Invoke-Native $CMake '-S' $PSScriptRoot '-B' $Build '-A' 'x64'
Write-Host '[build] Compiling Kinect Remold...' -ForegroundColor Cyan
Invoke-Native $CMake '--build' $Build '--config' 'Release'

$ServiceExe = Join-Path $Build 'Release\KinectOneRemoldService.exe'
if (-not (Test-Path -LiteralPath $ServiceExe -PathType Leaf)) {
    throw "Build completed without the expected service executable: $ServiceExe"
}

$Stage = Join-Path $Root 'binaries\windows\drivers\kinect-one-remold'
New-Item -ItemType Directory -Path $Stage -Force | Out-Null
Copy-Item -LiteralPath $ServiceExe -Destination $Stage -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'KinectOneRemoldWinUSB.inf') -Destination $Stage -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install.ps1') -Destination $Stage -Force

$driverKitTools = Ensure-WindowsDriverKitTools
$inf2cat = $driverKitTools[0]
$signtool = $driverKitTools[1]
Write-Host ("Inf2Cat: {0}" -f $inf2cat) -ForegroundColor DarkGray
Write-Host ("SignTool: {0}" -f $signtool) -ForegroundColor DarkGray

Write-Host '[driver] Generating catalog with Inf2Cat...' -ForegroundColor Cyan
Invoke-Native $inf2cat "/driver:$Stage" '/os:10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64'

$Certificate = Get-SigningCertificate $Stage
Write-Host ("[driver] Signing package with {0}" -f $Certificate.Thumbprint) -ForegroundColor Cyan
$StageExe = Join-Path $Stage 'KinectOneRemoldService.exe'
$Catalog = Join-Path $Stage 'KinectOneRemoldWinUSB.cat'
Invoke-Native $signtool 'sign' '/fd' 'SHA256' '/sha1' $Certificate.Thumbprint $StageExe
Invoke-Native $signtool 'sign' '/fd' 'SHA256' '/sha1' $Certificate.Thumbprint $Catalog
foreach($signedFile in @($StageExe,$Catalog)){
    $signature=Get-AuthenticodeSignature -FilePath $signedFile
    if(-not $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ne $Certificate.Thumbprint){
        throw "Signing did not attach the expected certificate: $signedFile"
    }
}

Write-Host ''
Write-Host ("Kinect Remold Xbox One build complete: {0}" -f $Stage) -ForegroundColor Green
