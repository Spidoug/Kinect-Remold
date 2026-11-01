[CmdletBinding()]
param([ValidateSet('Detect','Install','Status','Start','Stop','Repair','Uninstall')][string]$Action='Install',[switch]$NoBanner,[switch]$NoPause)

$ErrorActionPreference='Stop'
$Dir=Split-Path -Parent $MyInvocation.MyCommand.Path
$Svc='KinectOneRemold'
$Inf=Join-Path $Dir 'KinectOneRemoldWinUSB.inf'
$Cat=Join-Path $Dir 'KinectOneRemoldWinUSB.cat'
$Exe=Join-Path $Dir 'KinectOneRemoldService.exe'
$Cer=Join-Path $Dir 'KinectRemoldDriver.cer'
$InstallDir=Join-Path (Join-Path $env:ProgramFiles 'Kinect Remold') 'kinect-one-remold'
$InstalledExe=Join-Path $InstallDir 'KinectOneRemoldService.exe'
$InstalledScript=Join-Path $InstallDir 'Install.ps1'
$InstalledInf=Join-Path $InstallDir 'KinectOneRemoldWinUSB.inf'
$InstalledCat=Join-Path $InstallDir 'KinectOneRemoldWinUSB.cat'
$InstalledCer=Join-Path $InstallDir 'KinectRemoldDriver.cer'

if(!$NoBanner){
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' Kinect Remold' -ForegroundColor Cyan
    Write-Host ' by Douglas Santana - @spidoug' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' Control panel - Windows' -ForegroundColor DarkGray
    Write-Host ''
}

function Require-Administrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator privileges are required for this action.'}
}

function Invoke-Native {
    param([Parameter(Mandatory=$true)][string]$FilePath,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    $output=@(& $FilePath @Arguments 2>&1)
    $code=$LASTEXITCODE
    if($code -ne 0){
        $output | ForEach-Object { Write-Host $_ }
        throw "Command failed with exit code $code`: $FilePath $($Arguments -join ' ')"
    }
    if(!$NoBanner){$output | ForEach-Object { Write-Host $_ }}
    return $output
}
function Stage([string]$Text){Write-Host $Text -ForegroundColor Cyan}

function Get-ServiceProcessId {
    try{
        $escaped=$Svc.Replace("'","''")
        $service=Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $escaped) -ErrorAction Stop
        if($null -eq $service){return 0}
        return [int]$service.ProcessId
    }catch{return 0}
}

function Wait-ServiceStopped([int]$TimeoutMs=5000){
    $deadline=[DateTime]::UtcNow.AddMilliseconds([Math]::Max(0,$TimeoutMs))
    do{
        $service=Get-Service -Name $Svc -ErrorAction SilentlyContinue
        if($null -eq $service -or $service.Status -eq 'Stopped'){return $true}
        Start-Sleep -Milliseconds 150
    }while([DateTime]::UtcNow -lt $deadline)
    $service=Get-Service -Name $Svc -ErrorAction SilentlyContinue
    return ($null -eq $service -or $service.Status -eq 'Stopped')
}

function Stop-RemoldServiceBounded([switch]$ForceProcess){
    $service=Get-Service -Name $Svc -ErrorAction SilentlyContinue
    if($null -eq $service -or $service.Status -eq 'Stopped'){return $true}
    & sc.exe stop $Svc 2>$null | Out-Null
    if(Wait-ServiceStopped 5000){return $true}
    if($ForceProcess){
        $pid=Get-ServiceProcessId
        if($pid -gt 0){
            Write-Host ("Service did not stop cleanly; terminating PID {0} to release installed files." -f $pid) -ForegroundColor Yellow
            & taskkill.exe /PID $pid /T /F 2>$null | Out-Null
            if(Wait-ServiceStopped 4000){return $true}
        }
    }
    return $false
}

function Remove-ServiceRegistration {
    [void](Stop-RemoldServiceBounded -ForceProcess)
    & sc.exe delete $Svc 2>$null | Out-Null
    # SCM can retain a deleted service record briefly. It no longer owns the
    # executable after the process exits, but a short bounded wait makes repair
    # and reinstall deterministic.
    $deadline=[DateTime]::UtcNow.AddSeconds(4)
    do{
        if($null -eq (Get-Service -Name $Svc -ErrorAction SilentlyContinue)){break}
        Start-Sleep -Milliseconds 150
    }while([DateTime]::UtcNow -lt $deadline)
}

function Install-PackageCertificate {
    if(!(Test-Path -LiteralPath $Cer -PathType Leaf)){throw 'Driver signing certificate is missing from the built package.'}
    foreach($store in @('Root','TrustedPublisher')){
        Import-Certificate -FilePath $Cer -CertStoreLocation ("Cert:\LocalMachine\{0}" -f $store) | Out-Null
    }
}

function Remove-PackageCertificate {
    $certPath=$Cer
    if(!(Test-Path -LiteralPath $certPath -PathType Leaf) -and (Test-Path -LiteralPath $InstalledCer -PathType Leaf)){$certPath=$InstalledCer}
    if(!(Test-Path -LiteralPath $certPath -PathType Leaf)){return}
    $cert=New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath)
    foreach($store in @('Root','TrustedPublisher')){
        $path=("Cert:\LocalMachine\{0}\{1}" -f $store,$cert.Thumbprint)
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}
    }
}

function Remove-DriverPackage {
    $drivers=@()
    if(Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue){
        $drivers=Get-WindowsDriver -Online -All | Where-Object {
            $_.OriginalFileName -and [IO.Path]::GetFileName($_.OriginalFileName) -ieq 'KinectOneRemoldWinUSB.inf'
        }
    }
    foreach($driver in $drivers){
        if($driver.Driver){[void](Invoke-Native 'pnputil.exe' '/delete-driver' $driver.Driver '/uninstall' '/force')}
    }
}

function Copy-IfDifferent([string]$Source,[string]$Destination,[switch]$Required){
    if(!(Test-Path -LiteralPath $Source -PathType Leaf)){
        if($Required){throw "Required installation file is missing: $Source"}
        return
    }
    $sourceFull=[IO.Path]::GetFullPath($Source)
    $destinationFull=[IO.Path]::GetFullPath($Destination)
    if($sourceFull.Equals($destinationFull,[StringComparison]::OrdinalIgnoreCase)){return}
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Assert-FileCopy([string]$Source,[string]$Destination,[switch]$Required){
    if(!(Test-Path -LiteralPath $Source -PathType Leaf)){if($Required){throw "Required source is missing: $Source"};return}
    if(!(Test-Path -LiteralPath $Destination -PathType Leaf)){throw "Installed runtime file is missing: $Destination"}
    $sourceHash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $destinationHash=(Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if($sourceHash -ne $destinationHash){throw "Installed runtime verification failed: $Destination"}
}

function Stage-PersistentRuntime {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-IfDifferent $Exe $InstalledExe -Required
    Copy-IfDifferent (Join-Path $Dir 'Install.ps1') $InstalledScript -Required
    Copy-IfDifferent $Inf $InstalledInf
    Copy-IfDifferent $Cat $InstalledCat
    Copy-IfDifferent $Cer $InstalledCer
    Assert-FileCopy $Exe $InstalledExe -Required
    Assert-FileCopy (Join-Path $Dir 'Install.ps1') $InstalledScript -Required
    Assert-FileCopy $Inf $InstalledInf
    Assert-FileCopy $Cat $InstalledCat
    Assert-FileCopy $Cer $InstalledCer
}

function Remove-PersistentRuntime {
    if(!(Test-Path -LiteralPath $InstallDir -PathType Container)){return}
    foreach($attempt in 1..4){
        try{
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
            if(!(Test-Path -LiteralPath $InstallDir)){return}
        }catch{
            if($attempt -eq 4){Write-Warning ("Installed runtime remains in use: {0}. A Windows restart may be required to finish cleanup." -f $InstallDir);return}
        }
        Start-Sleep -Milliseconds (250*$attempt)
    }
}

function Get-ServiceImagePath {
    try{
        $escaped=$Svc.Replace("'","''")
        $service=Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $escaped) -ErrorAction Stop
        if($null -eq $service){return ''}
        return [string]$service.PathName
    }catch{return ''}
}

function Assert-ServiceDetachedFromSource {
    $image=Get-ServiceImagePath
    if([string]::IsNullOrWhiteSpace($image)){throw 'Runtime service was created without an image path.'}
    $expected=[IO.Path]::GetFullPath($InstalledExe)
    $normalized=$image.Trim().Trim('"')
    try{$normalized=[IO.Path]::GetFullPath($normalized)}catch{}
    if(!$normalized.Equals($expected,[StringComparison]::OrdinalIgnoreCase)){
        throw ("Runtime service is not detached from the build/repository tree. Expected: {0}; actual: {1}" -f $expected,$image)
    }
}

function Show-State([string]$Name,[bool]$Ready,[string]$Detail=''){
    $state=if($Ready){'READY'}else{'NOT READY'}
    $color=if($Ready){'Green'}else{'Yellow'}
    $suffix=if([string]::IsNullOrWhiteSpace($Detail)){''}else{" - $Detail"}
    Write-Host (("{0,-26} : {1}{2}" -f $Name,$state,$suffix)) -ForegroundColor $color
}

function Test-SdkPipe {
    try{return Test-Path -LiteralPath '\\.\pipe\KinectOneRemoldSdk'}catch{return $false}
}

function Test-DevicePresent {
    $found=$false
    foreach($usbPid in @('02C4','02D8')){
        $text=& pnputil.exe /enum-devices /connected /deviceid ("USB\VID_045E&PID_{0}" -f $usbPid) 2>&1
        if($LASTEXITCODE -eq 0 -and ($text -join "`n") -match 'VID_045E'){$found=$true}
    }
    return $found
}
function Show-RemoldStatus {
    $service=Get-Service -Name $Svc -ErrorAction SilentlyContinue
    $serviceReady=$null -ne $service -and $service.Status -eq 'Running'
    $serviceDetail=if($null -eq $service){'NOT INSTALLED'}else{[string]$service.Status.ToString().ToUpperInvariant()}
    $pathReady=Test-Path -LiteralPath $InstalledExe -PathType Leaf
    $deviceReady=Test-DevicePresent
    $sdkReady=Test-SdkPipe
    Show-State 'Runtime service' $serviceReady $serviceDetail
    Show-State 'Runtime path' $pathReady $InstalledExe
    Show-State 'Device' $deviceReady $(if($deviceReady){'detected'}else{'not detected'})
    Show-State 'SDK socket' $sdkReady '\\.\pipe\KinectOneRemoldSdk'
    return $serviceReady
}
function Install-Remold {
    if(!(Test-Path -LiteralPath $Exe -PathType Leaf)){throw 'Build the Kinect Remold Xbox One module before installation.'}
    if(!(Test-Path -LiteralPath $Inf -PathType Leaf)){throw 'Kinect Remold Xbox One WinUSB INF is missing from the built package.'}
    Stage '[1/4] Installing Kinect Remold - Xbox One driver package...'
    Install-PackageCertificate
    [void](Invoke-Native 'pnputil.exe' '/add-driver' $Inf '/install')

    Stage '[2/4] Installing persistent runtime files...'
    Remove-ServiceRegistration
    Stage-PersistentRuntime

    Stage '[3/4] Registering and starting runtime service...'
    [void](Invoke-Native 'sc.exe' 'create' $Svc 'binPath=' ('"{0}"' -f $InstalledExe) 'start=' 'auto' 'DisplayName=' 'Kinect Remold - Xbox One Runtime')
    [void](Invoke-Native 'sc.exe' 'description' $Svc 'Kinect Remold - Xbox One native USB runtime')
    & sc.exe failure $Svc 'reset=' 86400 'actions=' 'restart/5000/restart/15000/none/0' 2>$null | Out-Null
    Assert-ServiceDetachedFromSource
    [void](Invoke-Native 'sc.exe' 'start' $Svc)
    Assert-ServiceDetachedFromSource

    Stage '[4/4] Verifying installed runtime...'
    $service=Get-Service -Name $Svc -ErrorAction SilentlyContinue
    if($null -eq $service -or $service.Status -ne 'Running'){throw 'Kinect Remold - Xbox One runtime service did not reach RUNNING.'}
    Write-Host ("Runtime service: RUNNING") -ForegroundColor Green
    Write-Host ("Runtime path   : {0}" -f $InstalledExe) -ForegroundColor DarkGray
}

if($Action -in @('Install','Repair','Uninstall','Start','Stop')){Require-Administrator}

if($Action -eq 'Install'){
    Install-Remold
}elseif($Action -eq 'Uninstall'){
    Stage '[1/4] Stopping and removing runtime service...'
    Remove-ServiceRegistration
    Stage '[2/4] Removing Kinect Remold - Xbox One driver package...'
    Remove-DriverPackage
    Stage '[3/4] Removing package trust and persistent runtime...'
    Remove-PackageCertificate
    Remove-PersistentRuntime
    Stage '[4/4] Verifying removal...'
    if($null -eq (Get-Service -Name $Svc -ErrorAction SilentlyContinue) -and !(Test-Path -LiteralPath $InstallDir)){Write-Host 'Runtime service: NOT INSTALLED' -ForegroundColor Green}
    else{throw 'Kinect Remold - Xbox One removal is incomplete.'}
}elseif($Action -eq 'Start'){
    [void](Invoke-Native 'sc.exe' 'start' $Svc)
}elseif($Action -eq 'Stop'){
    if(!(Stop-RemoldServiceBounded -ForceProcess)){throw 'Kinect Remold Xbox One service could not be stopped.'}
}elseif($Action -eq 'Repair'){
    Install-Remold
}elseif($Action -eq 'Detect'){
    $present=Test-DevicePresent
    Show-State 'Device' $present $(if($present){'detected'}else{'not detected'})
}else{
    [void](Show-RemoldStatus)
}
