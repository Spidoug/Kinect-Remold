[CmdletBinding()]
param([string]$DistributionRoot='', [switch]$NoBanner)
$ErrorActionPreference='Stop'
$Root=if([string]::IsNullOrWhiteSpace($DistributionRoot)){Split-Path -Parent $PSScriptRoot}else{[IO.Path]::GetFullPath($DistributionRoot)}
. (Join-Path $PSScriptRoot 'Common.ps1')
$Product=Import-RemoldProductConfig $PSScriptRoot
$ProductName=$Product.Name

function Remove-VirtualCameraDevices{
    try{
        $devices=@(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object{
                $_.PNPDeviceID -like 'SWD\VCAMDEVAPI*' -and
                ![string]::IsNullOrWhiteSpace([string]$_.Name) -and
                $_.Name.StartsWith([string]$Product.WindowsCameraNamePrefix,[StringComparison]::OrdinalIgnoreCase)
            })
        foreach($device in $devices){
            $result=Invoke-Native 'pnputil.exe' @('/remove-device',$device.PNPDeviceID)
            if($result.ExitCode -ne 0){Show-Native $result;Write-Warning ("Could not remove virtual camera device {0}." -f $device.PNPDeviceID)}
        }
    }catch{Write-Warning ("Could not enumerate Remold virtual camera devices: {0}" -f $_.Exception.Message)}
}

function Remove-DriverStorePackages{
    $names=@($Product.DriverPackages|ForEach-Object{Split-Path $_.Inf -Leaf})
    try{
        $drivers=@(Get-WindowsDriver -Online -All -ErrorAction Stop |
            Where-Object{$_.OriginalFileName -and ((Split-Path $_.OriginalFileName -Leaf) -in $names)})
        foreach($driver in $drivers){
            if(!$driver.Driver){continue}
            Write-Host ("Removing {0}..." -f $driver.Driver) -ForegroundColor Cyan
            $result=Invoke-Native 'pnputil.exe' @('/delete-driver',$driver.Driver,'/uninstall','/force')
            if($result.ExitCode -ne 0){Show-Native $result;Write-Warning ("Could not delete {0}." -f $driver.Driver)}
        }
    }catch{Write-Warning ("Could not enumerate driver packages: {0}" -f $_.Exception.Message)}
}

function Stop-RemoldRuntimeProcesses{
    $names=@(
        'Kinect360RemoldCameraBridge','Kinect360RemoldCameraIp','Kinect360RemoldAudioBridge',
        'Kinect360RemoldBroker','Kinect360RemoldWebcam','Kinect360RemoldNui','Kinect360RemoldSetup'
    )
    foreach($name in $names){
        foreach($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)){
            try{
                if(!$process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction Stop}
                [void]$process.WaitForExit(3000)
            }catch{Write-Warning ("Could not stop process {0} (PID {1}): {2}" -f $name,$process.Id,$_.Exception.Message)}
        }
    }
}
function Remove-DirectoryBounded([string]$Path,[string]$Description){
    if(!(Test-Path -LiteralPath $Path)){return $true}
    foreach($attempt in 1..4){
        try{
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if(!(Test-Path -LiteralPath $Path)){return $true}
        }catch{
            if($attempt -eq 4){
                Write-Warning ("{0} remains in use: {1}. A Windows restart may be required to finish cleanup." -f $Description,$Path)
                return $false
            }
        }
        Start-Sleep -Milliseconds (250*$attempt)
    }
    return !(Test-Path -LiteralPath $Path)
}

if(!$NoBanner){
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' Kinect Xbox 360 Remold ' -ForegroundColor Cyan
    Write-Host ' by Douglas Santana - @spidoug' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
}

Require-Administrator 'Administrator privileges are required for driver removal.'
$Setup=Join-Path $Root 'tools\Kinect360RemoldSetup.exe'
$Runtime=Join-Path $env:ProgramFiles $ProductName
$PackagedCtl=Join-Path $Root 'webcam\Kinect360RemoldWebcam.exe'
$RuntimeCtl=Join-Path $Runtime 'Kinect360RemoldWebcam.exe'
$Ctl=if(Test-Path -LiteralPath $PackagedCtl -PathType Leaf){$PackagedCtl}else{$RuntimeCtl}

$servicesStillRunning=New-Object System.Collections.Generic.List[string]
foreach($serviceKey in @($Product.ServiceOrder)){
    $service=$Product.Services[$serviceKey]
    if(!(Stop-ServiceBounded $service 4500 -ForceProcess)){[void]$servicesStillRunning.Add($service)}
}
if($servicesStillRunning.Count){
    Write-Warning ("Some Remold services could not be stopped and may require one Windows restart to finish file cleanup: {0}" -f ($servicesStillRunning -join ', '))
}
Stop-RemoldRuntimeProcesses
if($null -ne $Product.CameraIpPolicy -and ![string]::IsNullOrWhiteSpace([string]$Product.CameraIpPolicy.FirewallRuleName)){
    [void](Invoke-Native 'netsh.exe' @('advfirewall','firewall','delete','rule',("name={0}" -f $Product.CameraIpPolicy.FirewallRuleName)))
}
if(Test-NativeVirtualCameraSupport $Product){
    if(Test-Path -LiteralPath $Ctl -PathType Leaf){
        $result=Invoke-Native $Ctl @('remove-all')
        if($result.ExitCode -ne 0){Show-Native $result;Write-Warning 'Native camera removal returned an error; PnP cleanup will continue.'}
    }
    Remove-VirtualCameraDevices
}

if(Test-Path -LiteralPath $Setup -PathType Leaf){
    foreach($package in @($Product.DriverPackages|Where-Object{!([string]::IsNullOrWhiteSpace($_.RootHardwareId))})){
        $result=Invoke-Native $Setup @('remove',$package.RootHardwareId)
        if($result.ExitCode -ne 0){Show-Native $result;Write-Warning ("Could not remove root device {0}." -f $package.RootHardwareId)}
    }
}
Remove-DriverStorePackages
Stop-RemoldRuntimeProcesses

try{
    $services=@(Get-CimInstance Win32_Service -ErrorAction Stop|Where-Object{$_.Name -like ($Product.Prefix+'*')})
    foreach($service in $services){[void](Invoke-Native 'sc.exe' @('delete',$service.Name))}
}catch{Write-Warning ("Could not enumerate product services: {0}" -f $_.Exception.Message)}

[void](Remove-DirectoryBounded $Runtime 'Runtime folder')
foreach($programData in @((Join-Path $env:ProgramData $ProductName),(Join-Path $env:ProgramData 'Kinect Remold\Runtime\kinect-xbox-360-remold'))){
    [void](Remove-DirectoryBounded $programData 'Runtime configuration folder')
}

$DevelopmentCert=Join-Path $Root 'Kinect360RemoldDevelopment.cer'
if(Test-Path -LiteralPath $DevelopmentCert -PathType Leaf){
    try{
        $cert=Get-CertificateFromFile $DevelopmentCert
        foreach($storeName in @('TrustedPublisher','Root')){Remove-CertificateFromMachineStore $cert $storeName}
        Write-Host 'Removed Kinect Remold development trust certificate.' -ForegroundColor DarkCyan
    }catch{Write-Warning ("Could not remove development trust certificate: {0}" -f $_.Exception.Message)}
}

Write-Host ("{0} UNINSTALL COMPLETE" -f $ProductName) -ForegroundColor Green
