[CmdletBinding()]
param([ValidateSet('Release')][string]$Configuration='Release',[string]$LogPath='')
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$Product=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Product.psd1')
$ProjectRoot=(Resolve-Path (Join-Path $Root '..\..\..')).Path
$ProjectVersion=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'VERSION')).Trim()
if($Product.Version -ne $ProjectVersion){throw "Product.psd1 Version '$($Product.Version)' does not match repository VERSION '$ProjectVersion'."}
$Dist=Join-Path $ProjectRoot 'binaries\windows\drivers'
$SdkDist=Join-Path $ProjectRoot 'binaries\windows\sdk'
$CameraRoot=Join-Path $Root 'components\camera'
$DeviceRoot=Join-Path $Root 'components\device'
. (Join-Path $PSScriptRoot 'Common.ps1')
$ExternalWork=Get-RemoldExternalWorkRoot
$CameraStage=Join-Path $ExternalWork 'driver\camera\stage'
$DeviceStage=Join-Path $ExternalWork 'driver\device\stage'
function Copy-Dir([string]$Source,[string]$Destination){if(Test-Path $Destination){Remove-Item $Destination -Recurse -Force};Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force}
if([string]::IsNullOrWhiteSpace($LogPath)){
    $logDir=Join-Path ([IO.Path]::GetTempPath()) 'Kinect360Remold\Build\logs';New-Item -ItemType Directory -Force $logDir|Out-Null
    $LogPath=Join-Path $logDir ("build-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force (Split-Path -Parent $LogPath)|Out-Null
$transcript=$false;$failed=$false
try{
    Start-Transcript -LiteralPath $LogPath -Force|Out-Null;$transcript=$true
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (" {0}" -f $Product.Name) -ForegroundColor Cyan
    Write-Host (" Program version: {0}" -f $Product.Version) -ForegroundColor DarkGray
    Write-Host (" by {0} - {1}" -f $Product.Author,$Product.Handle) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    $developmentCert=Get-OrCreateDevelopmentCertificate $Product
    Remove-Item -LiteralPath $Dist -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $SdkDist -Recurse -Force -ErrorAction SilentlyContinue

    Write-BuildStage '[1/4] Building camera and virtual webcam...'
    $cameraLog=Join-Path ([IO.Path]::GetTempPath()) 'Kinect360Remold\Build\logs\camera.log'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $CameraRoot 'Build.ps1') -Configuration $Configuration -LogPath $cameraLog -SigningThumbprint $developmentCert.Thumbprint
    if($LASTEXITCODE){throw "Camera build failed. See $cameraLog"}

    Write-BuildStage '[2/4] Building WinUSB Motor and WinUSB NUI Audio transport...'
    $deviceLog=Join-Path ([IO.Path]::GetTempPath()) 'Kinect360Remold\Build\logs\device.log'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DeviceRoot 'Build.ps1') -Configuration $Configuration -LogPath $deviceLog -SigningThumbprint $developmentCert.Thumbprint
    if($LASTEXITCODE){throw "Device build failed. See $deviceLog"}

    Write-BuildStage '[3/4] Building setup utility...'
    $Tools=& (Join-Path $PSScriptRoot 'Toolchain.ps1')
    $setupProject=Join-Path $Root 'source\setup\Kinect360RemoldSetup.vcxproj'
    $setupOut=Join-Path $ExternalWork 'driver\setup\out';$setupInt=Join-Path $ExternalWork 'driver\setup\obj';Remove-Item -LiteralPath (Join-Path $ExternalWork 'driver\setup') -Recurse -Force -ErrorAction SilentlyContinue;New-Item -ItemType Directory -Force $setupOut,$setupInt|Out-Null
    & $Tools.MSBuild $setupProject /m /t:Rebuild /p:Configuration=$Configuration /p:Platform=x64 /p:RemoldPlatformToolset=$($Tools.PlatformToolset) /p:PlatformToolset=$($Tools.PlatformToolset) /p:WindowsTargetPlatformVersion=$($Tools.WdkVersion) "/p:OutDir=$setupOut\" "/p:IntDir=$setupInt\"
    if($LASTEXITCODE){throw 'Kinect360RemoldSetup build failed.'}
    $setup=Get-ChildItem -LiteralPath $setupOut -Recurse -File -Filter Kinect360RemoldSetup.exe|Sort-Object LastWriteTime -Descending|Select-Object -First 1
    if(!$setup){throw 'Kinect360RemoldSetup.exe not found after build.'};Assert-NoExternalVcRuntime $setup.FullName $Tools

    Write-BuildStage '[4/4] Creating unified distribution...'
    New-Item -ItemType Directory -Force $Dist|Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Dist 'drivers'),(Join-Path $Dist 'tools'),(Join-Path $Dist 'system'),(Join-Path $Dist 'runtime')|Out-Null
    Copy-Dir (Join-Path $CameraStage 'camera') (Join-Path $Dist 'drivers\camera')
    Copy-Dir (Join-Path $CameraStage 'webcam') (Join-Path $Dist 'webcam')
    Copy-Dir (Join-Path $CameraStage 'runtime') (Join-Path $Dist 'runtime')
    Copy-Dir (Join-Path $DeviceStage 'device') (Join-Path $Dist 'drivers\device')
    Copy-Dir (Join-Path $DeviceStage 'nui') (Join-Path $Dist 'drivers\nui')
    Copy-Dir (Join-Path $DeviceStage 'audio') (Join-Path $Dist 'drivers\audio')
    Copy-Dir (Join-Path $DeviceStage 'control1473') (Join-Path $Dist 'drivers\control1473')
    Copy-Dir (Join-Path $DeviceStage 'tools') (Join-Path $Dist 'tools')
    Copy-Item -LiteralPath $setup.FullName -Destination (Join-Path $Dist 'tools\Kinect360RemoldSetup.exe') -Force
    Copy-Item -LiteralPath (Join-Path $Root 'install\KINECT.cmd') -Destination (Join-Path $Dist 'KINECT.cmd') -Force
    foreach($file in @('Kinect.ps1','Install.ps1','Uninstall.ps1','Common.ps1')){Copy-Item -LiteralPath (Join-Path $Root "install\$file") -Destination (Join-Path $Dist "system\$file") -Force}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Product.psd1') -Destination (Join-Path $Dist 'system\Product.psd1') -Force
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $Root) 'README.md') -Destination (Join-Path $Dist 'README.txt') -Force
    @($Product.Name,("Program version: {0}" -f $Product.Version),"by $($Product.Author)",$Product.Handle) | Set-Content -LiteralPath (Join-Path $Dist 'VERSION.txt') -Encoding ASCII

    # Publish the SDK contract separately from the native driver payload.
    New-Item -ItemType Directory -Force $SdkDist|Out-Null
    Copy-Item -LiteralPath (Join-Path $DeviceRoot 'shared\Kinect360RemoldControlProtocol.h') -Destination (Join-Path $SdkDist 'Kinect360RemoldControlProtocol.h') -Force
    Copy-Item -LiteralPath (Join-Path $DeviceRoot 'shared\Kinect360RemoldAudioControlProtocol.h') -Destination (Join-Path $SdkDist 'Kinect360RemoldAudioControlProtocol.h') -Force
    $sdkReadme=@(
        '# Kinect Xbox 360 Remold SDK endpoint',
        '',
        ("Program version: {0}" -f $Product.Version),
        '',
        'Windows SDK pipe: `\\.\pipe\Kinect360RemoldSdk`.',
        '',
        'Text commands: `LIST`, `GET <deviceId>`, `INDEX <sensorIndex>`.',
        'Returned rows: `id, label, state, control, camera, audio, audio-control, virtual-camera, sdk`.',
        '',
        'SynKinect Studio and external clients discover devices through this endpoint. The runtime manifest is internal and is not part of the SDK surface.',
        '',
        'The C++ headers in this directory define the public binary control and audio-control contracts.'
    )
    $sdkReadme | Set-Content -LiteralPath (Join-Path $SdkDist 'README.md') -Encoding UTF8

    # The development signer covers the PnP catalogs. Camera and Motor keep
    # Microsoft's inbox winusb.sys; NUI Audio uses no authored kernel binary.
    # 02AD is WinUSB for UAC firmware. 02BB/02C3 MI_00 keeps an already working
    # Microsoft WinUSB package or uses the dedicated Remold WinUSB fallback;
    # 02BB/02C3 MI_02 remains inbox USB Audio/WASAPI. 02C2 remains hub-owned.
    # The build/installer never mutates BCD, Secure Boot, or Code Integrity policy.
    $catalogs=@(Get-ChildItem -LiteralPath (Join-Path $Dist 'drivers') -Recurse -File -Filter '*.cat' | Sort-Object FullName | Select-Object -ExpandProperty FullName)
    if($catalogs.Count -ne $Product.DriverPackages.Count){throw "Expected $($Product.DriverPackages.Count) PnP catalogs, found $($catalogs.Count)."}
    foreach($catalog in $catalogs){Require-File $catalog 'PnP catalog';Sign-CodeArtifact $catalog $developmentCert $Tools 'PnP catalog'}
    $publicCert=Join-Path $Dist 'Kinect360RemoldDevelopment.cer'
    Export-Certificate -Cert $developmentCert -FilePath $publicCert -Type CERT -Force|Out-Null
    Require-File $publicCert 'Development public certificate'
    Write-Host ("Development package certificate: {0}" -f $developmentCert.Subject) -ForegroundColor Yellow
    Write-Host ("Development certificate thumbprint: {0}" -f $developmentCert.Thumbprint) -ForegroundColor DarkGray
    Write-Host 'PnP catalogs: DEVELOPMENT-SIGNED; 1414 motor/camera and 02AD boot use WinUSB; 1473 MI_00 preserves healthy Microsoft WinUSB or uses Remold fallback; 02C2 remains inbox hub; MI_02 remains USB Audio/WASAPI' -ForegroundColor Green

    $expected=@{
        'drivers\camera'=@('Kinect360RemoldCamera.inf','Kinect360RemoldCamera.cat','Kinect360RemoldCameraBridge.exe');
        'webcam'=@('Kinect360RemoldCameraSource.dll','Kinect360RemoldWebcam.exe');
        'runtime'=@('Kinect360RemoldCameraIp.exe');
        'drivers\device'=@('Kinect360RemoldDevice.inf','Kinect360RemoldDevice.cat','Kinect360RemoldBroker.exe');
        'drivers\nui'=@('Kinect360RemoldNui.inf','Kinect360RemoldNui.cat');
        'drivers\audio'=@('Kinect360RemoldAudio.inf','Kinect360RemoldAudio.cat','Kinect360RemoldAudioBridge.exe');
        'drivers\control1473'=@('Kinect360Remold1473Control.inf','Kinect360Remold1473Control.cat');
        'tools'=@('Kinect360RemoldNui.exe','Kinect360RemoldSetup.exe');
        'system'=@('Kinect.ps1','Install.ps1','Uninstall.ps1','Common.ps1','Product.psd1');
        '.'=@('KINECT.cmd','Kinect360RemoldDevelopment.cer')
    }
    foreach($folder in $expected.Keys){foreach($file in $expected[$folder]){Require-File (Join-Path (Join-Path $Dist $folder) $file) "$folder\$file"}}
    Write-Host '';Write-Host ("{0} BUILD COMPLETE" -f $Product.Name) -ForegroundColor Green
    Write-Host "Driver output: $Dist" -ForegroundColor Green
    Write-Host "SDK output: $SdkDist" -ForegroundColor Green
    Write-Host 'Open binaries\windows\drivers\KINECT.cmd and choose Install / Reinstall. The installer trusts the packaged development certificate before PnP staging.' -ForegroundColor Yellow
}catch{
    $failed=$true;Write-Host '';Write-Host ("{0} BUILD FAILED" -f $Product.Name) -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red;Write-Host "Full log: $LogPath" -ForegroundColor Yellow
}finally{if($transcript){try{Stop-Transcript|Out-Null}catch{Write-Warning ("Could not stop build transcript cleanly: {0}" -f $_.Exception.Message)}}}
if($failed){exit 1};exit 0
