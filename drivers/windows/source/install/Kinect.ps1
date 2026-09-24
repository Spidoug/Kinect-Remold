[CmdletBinding()]
param(
    [ValidateSet('Menu','Install','Status','OpenCamera','Tilt','StartupTilt','RgbHqStatus','RgbHqOn','RgbHqOff','RgbHqToggle','IpStatus','IpCredentials','IpReset','IpLocal','IpLan','IpDevice','IpToggle','OpenStudio','Restart','Uninstall')]
    [string]$Action='Menu',
    [string]$DeviceId='',
    [switch]$NoPause
)
$ErrorActionPreference='Continue'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Common.ps1')
$Product=Import-RemoldProductConfig $PSScriptRoot
$Nui=Join-Path $Root 'tools\Kinect360RemoldNui.exe'
$Setup=Join-Path $Root 'tools\Kinect360RemoldSetup.exe'
$WebcamCtl=Join-Path $Root 'webcam\Kinect360RemoldWebcam.exe'
$CameraIpCtl=Join-Path (Join-Path $env:ProgramFiles $Product.Name) 'Kinect360RemoldCameraIp.exe'
$Install=Join-Path $PSScriptRoot 'Install.ps1'
$Uninstall=Join-Path $PSScriptRoot 'Uninstall.ps1'

function Find-RepositoryRoot{
    $dir=[IO.DirectoryInfo](Split-Path -Parent $PSScriptRoot)
    for($i=0;$i -lt 12 -and $null -ne $dir;$i++){
        $version=Join-Path $dir.FullName 'VERSION'
        $drivers=Join-Path $dir.FullName 'drivers'
        $apps=Join-Path $dir.FullName 'applications'
        if((Test-Path -LiteralPath $version -PathType Leaf) -and (Test-Path -LiteralPath $drivers -PathType Container) -and (Test-Path -LiteralPath $apps -PathType Container)){
            return $dir.FullName
        }
        $dir=$dir.Parent
    }
    return $null
}

function Find-StudioLauncher{
    $repo=Find-RepositoryRoot
    $candidates=@()
    if(![string]::IsNullOrWhiteSpace($repo)){
        $candidates += (Join-Path $repo 'binaries\windows\applications\SynKinectStudio\SynKinectStudio.vbs')
        $candidates += (Join-Path $repo 'binaries\windows\applications\SynKinectStudio\SynKinectStudio.cmd')
    }
    $candidates += @(
        (Join-Path $Root 'studio\SynKinectStudio.vbs'),
        (Join-Path $Root 'SynKinectStudio\SynKinectStudio.vbs'),
        (Join-Path $Root '..\applications\SynKinectStudio\SynKinectStudio.vbs'),
        (Join-Path $Root 'studio\SynKinectStudio.cmd'),
        (Join-Path $Root 'SynKinectStudio\SynKinectStudio.cmd'),
        (Join-Path $Root '..\applications\SynKinectStudio\SynKinectStudio.cmd')
    )
    foreach($candidate in $candidates){
        try{
            $full=[IO.Path]::GetFullPath($candidate)
            if(Test-Path -LiteralPath $full -PathType Leaf){return $full}
        }catch{}
    }
    return $null
}
function Start-StandardUserProcess([string]$FilePath,[string]$Arguments='',[string]$WorkingDirectory=''){
    if(!(Test-IsAdministrator)){
        $params=@{FilePath=$FilePath}
        if(![string]::IsNullOrWhiteSpace($Arguments)){$params.ArgumentList=$Arguments}
        if(![string]::IsNullOrWhiteSpace($WorkingDirectory)){$params.WorkingDirectory=$WorkingDirectory}
        Start-Process @params | Out-Null
        return
    }
    # Shell.Application is brokered by the desktop shell.  When Explorer is
    # running as the normal interactive user this deliberately drops the
    # elevated token instead of propagating administrator rights to Studio.
    $shell=New-Object -ComObject Shell.Application
    $shell.ShellExecute($FilePath,$Arguments,$WorkingDirectory,'open',1)
}
function Open-Studio{
    $studio=Find-StudioLauncher
    if([string]::IsNullOrWhiteSpace($studio)){
        Write-Host 'SynKinect Studio Windows launcher was not found in this distribution.' -ForegroundColor Yellow
        Write-Host 'Expected binaries\windows\applications\SynKinectStudio\SynKinectStudio.vbs.' -ForegroundColor DarkGray
        return $false
    }
    try{
        $working=Split-Path -Parent $studio
        if([IO.Path]::GetExtension($studio).Equals('.vbs',[StringComparison]::OrdinalIgnoreCase)){
            Start-StandardUserProcess (Join-Path $env:WINDIR 'System32\wscript.exe') ('//nologo "{0}"' -f $studio) $working
        }else{
            Start-StandardUserProcess $studio '' $working
        }
        Write-Host ("SynKinect Studio opened as the standard desktop user: {0}" -f $studio) -ForegroundColor Green
        return $true
    }catch{
        Write-Host 'Could not open SynKinect Studio as a standard user.' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        return $false
    }
}

function Get-DeviceManifest{
    $path=Join-Path $env:ProgramData 'Kinect360Remold\devices.tsv'
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){return @()}

    $rows=@()
    foreach($line in @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)){
        if([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')){continue}
        $parts=$line -split "`t",9
        if($parts.Count -lt 9){continue}
        $rows += [pscustomobject]@{Id=$parts[0];Label=$parts[1];State=$parts[2];Control=$parts[3];Camera=$parts[4];Audio=$parts[5];AudioControl=$parts[6];VirtualCamera=$parts[7];Sdk=$parts[8]}
    }
    return $rows
}
function Resolve-DeviceId([object[]]$Rows=$null){
    if(![string]::IsNullOrWhiteSpace($DeviceId)){return $DeviceId.Trim()}
    if($null -eq $Rows){$Rows=@(Get-DeviceManifest)}
    $ready=@($Rows|Where-Object{$_.State -eq 'Ready'})
    if($ready.Count){return [string]$ready[0].Id}
    if($Rows.Count){return [string]$Rows[0].Id}
    return ''
}
function Pause-Menu{Write-Host '';[void](Read-Host 'Press Enter to continue')}
function Header{
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (" {0}" -f $Product.Name) -ForegroundColor Cyan
    Write-Host (" Program version: {0}" -f $Product.Version) -ForegroundColor DarkGray
    Write-Host '============================================================' -ForegroundColor Cyan
}
function Start-ElevatedAction([string]$RequestedAction){
    if(Test-IsAdministrator){return $false}
    $elevationArgs=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-Action',$RequestedAction)
    if(![string]::IsNullOrWhiteSpace($DeviceId)){$elevationArgs+=@('-DeviceId',$DeviceId)}
    try{
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $elevationArgs | Out-Null
        return $true
    }catch{
        Write-Host ("Administrator permission was not granted for {0}." -f $RequestedAction) -ForegroundColor Yellow
        return $false
    }
}
function Invoke-SelfAction([string]$RequestedAction){
    if([string]::IsNullOrWhiteSpace($DeviceId)){& $PSCommandPath -Action $RequestedAction}
    else{& $PSCommandPath -Action $RequestedAction -DeviceId $DeviceId}
}
function Need-Tools{
    if(!(Test-Path -LiteralPath $Nui -PathType Leaf) -or !(Test-Path -LiteralPath $Setup -PathType Leaf)){
        Write-Host 'Kinect tools were not found. Run Kinect-Xbox-360-Remold.cmd --rebuild again.' -ForegroundColor Red
        return $false
    }
    return $true
}
function Open-Camera{
    if(!(Need-Tools)){return}
    $id=Resolve-DeviceId
    if([string]::IsNullOrWhiteSpace($id)){Write-Host 'No Kinect virtual camera is available.' -ForegroundColor Yellow;return}
    try{
        if((Invoke-NativeCode $WebcamCtl @('status',$id)) -eq 0){Start-Process 'microsoft.windows.camera:'}
        else{Write-Host ('Virtual camera for '+$id+' is not ready.') -ForegroundColor Yellow}
    }catch{Write-Host 'Could not open Windows Camera.' -ForegroundColor Yellow}
}
function Show-State([string]$Name,[bool]$Ready,[string]$Detail=''){
    $state=if($Ready){'READY'}else{'NOT READY'}
    $color=if($Ready){'Green'}else{'Yellow'}
    $suffix=if([string]::IsNullOrWhiteSpace($Detail)){''}else{" - $Detail"}
    Write-Host (("{0,-26}: {1}{2}" -f $Name,$state,$suffix)) -ForegroundColor $color
}
function Test-ServiceReady([string]$Name){
    $service=Get-Service $Name -ErrorAction SilentlyContinue
    return ($null -ne $service -and $service.Status -eq 'Running')
}
function Get-AudioBridgeRuntimeStatus{
    $path=Join-Path $env:ProgramData 'Kinect360Remold\audio-bridge-status.txt'
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{Ready=$false;Detail='no runtime status file'}}
    try{
        $item=Get-Item -LiteralPath $path -ErrorAction Stop
        $ageSeconds=[Math]::Max(0,([datetime]::UtcNow-$item.LastWriteTimeUtc).TotalSeconds)
        $values=@{}
        foreach($line in @(Get-Content -LiteralPath $path -ErrorAction Stop)){
            $parts=$line -split '=',2
            if($parts.Count -eq 2){$values[$parts[0].Trim()]=$parts[1].Trim()}
        }
        $stage=[string]$values['stage']
        $mode=[string]$values['capture_mode']
        $channels=0;$rate=0;$frames=0L
        [void][int]::TryParse([string]$values['capture_channels'],[ref]$channels)
        [void][int]::TryParse([string]$values['stream_sample_rate'],[ref]$rate)
        [void][long]::TryParse([string]$values['published_frames'],[ref]$frames)
        $fresh=($ageSeconds -le 5)
        $ready=($fresh -and $stage -eq 'uac-runtime-capturing' -and $channels -ge 4 -and $rate -eq 16000 -and $frames -gt 0)
        $detail=("stage={0}; mode={1}; channels={2}; stream={3} Hz; frames={4}; status-age={5:N1}s" -f $stage,$mode,$channels,$rate,$frames,$ageSeconds)
        return [pscustomobject]@{Ready=$ready;Detail=$detail}
    }catch{return [pscustomobject]@{Ready=$false;Detail=('status read failed: '+$_.Exception.Message)}}
}
function Get-CameraIpConfig{
    $result=[ordered]@{Enabled=[bool]$Product.CameraIpPolicy.Enabled;Bind=[string]$Product.CameraIpPolicy.Bind;Port=[int]$Product.CameraIpPolicy.Port;User=[string]$Product.CameraIpPolicy.User;Device=''}
    $cfg=Join-Path (Join-Path $env:ProgramData $Product.Name) 'camera-ip-public.ini'
    if(Test-Path -LiteralPath $cfg -PathType Leaf){
        try{
            foreach($line in @(Get-Content -LiteralPath $cfg -ErrorAction Stop)){
                if($line -match '^\s*enabled\s*=\s*(.+?)\s*$'){$result.Enabled=($Matches[1] -match '^(?i:true|1)$')}
                elseif($line -match '^\s*bind\s*=\s*(.+?)\s*$'){$result.Bind=$Matches[1].Trim()}
                elseif($line -match '^\s*port\s*=\s*(\d+)\s*$'){$result.Port=[int]$Matches[1]}
                elseif($line -match '^\s*user\s*=\s*(.+?)\s*$'){$result.User=$Matches[1].Trim()}
                elseif($line -match '^\s*deviceId\s*=\s*(.*?)\s*$'){$result.Device=$Matches[1].Trim()}
            }
        }catch{}
    }
    return [pscustomobject]$result
}
function Get-CameraIpEnabled{return [bool](Get-CameraIpConfig).Enabled}
function Sync-CameraIpFirewall{
    $cfg=Get-CameraIpConfig
    $rule=[string]$Product.CameraIpPolicy.FirewallRuleName
    if([string]::IsNullOrWhiteSpace($rule)){return}
    [void](Invoke-NativeCode 'netsh.exe' @('advfirewall','firewall','delete','rule',("name={0}" -f $rule)))
    if($cfg.Enabled -and $cfg.Bind -ne '127.0.0.1'){
        $exe=$CameraIpCtl
        $firewallArgs=@(
            'advfirewall','firewall','add','rule',("name={0}" -f $rule),
            'dir=in','action=allow','protocol=TCP',("localport={0}" -f $cfg.Port),
            ("profile={0}" -f $Product.CameraIpPolicy.FirewallProfile),
            ("program={0}" -f $exe),
            ("remoteip={0}" -f $Product.CameraIpPolicy.FirewallRemoteIp),'enable=yes'
        )
        [void](Invoke-NativeCode 'netsh.exe' $firewallArgs)
    }
}

function Show-Status{
    if(!(Need-Tools)){return}
    $brokerReady=Test-ServiceReady $Product.Services.Broker
    $cameraBridgeReady=Test-ServiceReady $Product.Services.CameraBridge
    $audioServiceReady=Test-ServiceReady $Product.Services.AudioBridge
    $audioRuntime=Get-AudioBridgeRuntimeStatus
    $cameraIpConfig=Get-CameraIpConfig
    $cameraIpEnabled=[bool]$cameraIpConfig.Enabled
    $cameraIpReady=Test-ServiceReady $Product.Services.CameraIp
    $devices=@(Get-DeviceManifest)
    $selectedId=Resolve-DeviceId -Rows $devices
    $selected=$devices|Where-Object{$_.Id -eq $selectedId}|Select-Object -First 1
    $controlReady=($null -ne $selected -and ![string]::IsNullOrWhiteSpace([string]$selected.Control))
    $cameraReady=($null -ne $selected -and ![string]::IsNullOrWhiteSpace([string]$selected.VirtualCamera))
    $scannerReady=($null -ne $selected -and ![string]::IsNullOrWhiteSpace([string]$selected.Camera))
    $audioManifestReady=($null -ne $selected -and ![string]::IsNullOrWhiteSpace([string]$selected.Audio))
    $audioReady=($audioServiceReady -and $audioRuntime.Ready -and $audioManifestReady)
    $systemReady=$brokerReady -and $cameraBridgeReady -and ($null -ne $selected) -and (!$cameraIpEnabled -or $cameraIpReady)
    Show-State 'Kinect core system' $systemReady $(if($null -ne $selected){('device='+$selected.Id+'; state='+$selected.State)}else{'no Kinect in device manifest'})
    Show-State 'Physical Tilt / LED' $controlReady $(if($null -ne $selected -and $controlReady){[string]$selected.Control}else{'control transport not published'})
    Show-State 'Virtual camera' $cameraReady $(if($null -ne $selected){[string]$selected.VirtualCamera}else{'not published'})
    Show-State 'Scanner transport' $scannerReady $(if($null -ne $selected){[string]$selected.Camera}else{'not published'})
    if($cameraIpEnabled){
        $mode=if($cameraIpConfig.Bind -eq '127.0.0.1'){'LOCAL ONLY'}else{'LAN PRIVATE'}
        $source=if([string]::IsNullOrWhiteSpace($cameraIpConfig.Device)){'auto'}else{$cameraIpConfig.Device}
        $detail="{0}:{1}; {2}; source={3}; credential protected" -f $cameraIpConfig.Bind,$cameraIpConfig.Port,$mode,$source
        Show-State 'IP camera runtime' $cameraIpReady $detail
    }else{
        Show-State 'IP camera runtime' $true 'DISABLED; secure default'
    }
    $audioDetail=if($null -eq $selected){'not published'}elseif(!$audioManifestReady){'not published; '+$audioRuntime.Detail}else{([string]$selected.Audio)+'; '+$audioRuntime.Detail}
    Show-State 'Raw microphone pipe' $audioReady $audioDetail
}
function Restart-Runtime{
    $ipEnabled=Get-CameraIpEnabled
    $order=@($Product.ServiceOrder)
    for($i=$order.Count-1;$i -ge 0;$i--){
        $name=$Product.Services[$order[$i]]
        $service=Get-Service $name -ErrorAction SilentlyContinue
        if($null -ne $service -and $service.Status -ne 'Stopped'){Stop-Service -Name $name -Force -ErrorAction SilentlyContinue}
    }
    foreach($key in $order){
        if($key -eq 'CameraIp' -and !$ipEnabled){continue}
        $name=$Product.Services[$key]
        if($null -eq (Get-Service $name -ErrorAction SilentlyContinue)){continue}
        try{Start-Service -Name $name -ErrorAction Stop}
        catch{Write-Host ("Could not start {0}: {1}" -f $name,$_.Exception.Message) -ForegroundColor Yellow}
    }
    Show-Status
}
function Show-CameraIp{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
    [void](Invoke-NativeCode $CameraIpCtl @('status') -Show)
    Write-Host ''
    Write-Host 'Credentials are intentionally hidden from status output.' -ForegroundColor DarkGray
    Write-Host 'HTTP Basic is not encrypted. Use LAN mode only on a trusted private network or behind a VPN/TLS reverse proxy.' -ForegroundColor Yellow
}
function Show-CameraIpCredentials{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
    [void](Invoke-NativeCode $CameraIpCtl @('credentials') -Show)
}
function Reset-CameraIpPassword{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
    [void](Stop-ServiceBounded $Product.Services.CameraIp 4000 -ForceProcess -Quiet)
    $code=Invoke-NativeCode $CameraIpCtl @('reset-password') -Show
    if($code -eq 0){if(Get-CameraIpEnabled){[void](Start-ServiceBounded $Product.Services.CameraIp 6000 -Quiet)};Start-Sleep -Milliseconds 400;Show-CameraIp}
}
function Set-CameraIpNetworkMode([bool]$Lan){
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
    [void](Stop-ServiceBounded $Product.Services.CameraIp 4000 -ForceProcess -Quiet)
    $command=if($Lan){'lan'}else{'local-only'}
    $code=Invoke-NativeCode $CameraIpCtl @($command) -Show
    if($code -ne 0){return}
    Sync-CameraIpFirewall
    if(Get-CameraIpEnabled){[void](Start-ServiceBounded $Product.Services.CameraIp 6000 -Quiet)}
    if($Lan){
        Write-Host 'IP camera is now in LAN PRIVATE mode. Only private/link-local peers are accepted by the runtime, and the Windows rule is Private + LocalSubnet.' -ForegroundColor Green
        Write-Host 'HTTP Basic is still plaintext. Do not expose port 8088 directly to the internet; use a VPN or TLS reverse proxy.' -ForegroundColor Yellow
    }else{
        Write-Host 'IP camera is now LOCAL ONLY on 127.0.0.1. No inbound firewall rule is required.' -ForegroundColor Green
    }
    Show-CameraIp
}
function Set-CameraIpDevice{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
    $id=Resolve-DeviceId
    if([string]::IsNullOrWhiteSpace($id)){Write-Host 'No Kinect deviceId is available to bind.' -ForegroundColor Yellow;return}
    [void](Stop-ServiceBounded $Product.Services.CameraIp 4000 -ForceProcess -Quiet)
    $code=Invoke-NativeCode $CameraIpCtl @('device',$id) -Show
    if($code -ne 0){return}
    if(Get-CameraIpEnabled){[void](Start-ServiceBounded $Product.Services.CameraIp 6000 -Quiet)}
    Write-Host ("IP camera source pinned to Kinect {0}. It will not silently switch to another Kinect." -f $id) -ForegroundColor Green
}
function Set-CameraIpEnabled([bool]$Enabled){
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
    [void](Stop-ServiceBounded $Product.Services.CameraIp 4000 -ForceProcess -Quiet)
    if($Enabled){
        $cfg=Get-CameraIpConfig
        if([string]::IsNullOrWhiteSpace($cfg.Device)){
            $id=Resolve-DeviceId
            if(![string]::IsNullOrWhiteSpace($id)){[void](Invoke-NativeCode $CameraIpCtl @('device',$id) -Show)}
        }
    }
    $command=if($Enabled){'enable'}else{'disable'}
    $code=Invoke-NativeCode $CameraIpCtl @($command) -Show
    if($code -ne 0){return}
    if($Enabled){[void](Invoke-NativeCode 'sc.exe' @('config',$Product.Services.CameraIp,'start=','delayed-auto'))}
    else{[void](Invoke-NativeCode 'sc.exe' @('config',$Product.Services.CameraIp,'start=','demand'))}
    Sync-CameraIpFirewall
    if($Enabled){
        [void](Start-ServiceBounded $Product.Services.CameraIp 6000 -Quiet);Start-Sleep -Milliseconds 400
        Write-Host 'IP camera enabled. The current LOCAL/LAN bind mode is preserved.' -ForegroundColor Green
        Show-CameraIp
    }else{
        Write-Host 'IP camera disabled. Service autostart and firewall exposure are disabled; no IP-camera RGB consumer remains.' -ForegroundColor Green
    }
}
function Toggle-CameraIp{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
    if(Get-CameraIpEnabled){Set-CameraIpEnabled $false}else{Set-CameraIpEnabled $true}
}

function Invoke-RgbHq([ValidateSet('status','on','off','toggle')][string]$Mode){
    if(!(Test-Path -LiteralPath $WebcamCtl -PathType Leaf)){
        Write-Host 'Virtual-camera control tool was not found. Run Kinect-Xbox-360-Remold.cmd --rebuild again.' -ForegroundColor Red
        return $false
    }
    $id=Resolve-DeviceId
    if([string]::IsNullOrWhiteSpace($id)){Write-Host 'No Kinect is available for RGB HQ configuration.' -ForegroundColor Yellow;return $false}
    $command=if($Mode -eq 'status'){'rgb-hq-status'}elseif($Mode -eq 'on'){'rgb-hq-on'}elseif($Mode -eq 'off'){'rgb-hq-off'}else{'rgb-hq-toggle'}
    $code=Invoke-NativeCode $WebcamCtl @($command,$id) -Show
    if($code -ne 0){return $false}
    if($Mode -ne 'status'){
        Write-Host ("RGB HQ driver setting updated for Kinect {0}." -f $id) -ForegroundColor Green
    }
    return $true
}
function Toggle-RgbHq{return (Invoke-RgbHq 'toggle')}

function Invoke-TiltDegrees([int]$Degrees,[string]$SuccessText=''){
    if(!(Need-Tools)){return $false}
    $id=Resolve-DeviceId
    if([string]::IsNullOrWhiteSpace($id)){
        Write-Host 'No Kinect device is available for physical Tilt control.' -ForegroundColor Yellow
        return $false
    }
    $value=[Math]::Max($Product.TiltMinDegrees,[Math]::Min($Product.TiltMaxDegrees,$Degrees))
    $code=Invoke-NativeCode $Nui @('--device',$id,'tilt',[string]$value) -Show
    if($code -ne 0){
        Write-Host ("Tilt command failed for Kinect {0} (exit code {1})." -f $id,$code) -ForegroundColor Red
        return $false
    }
    if([string]::IsNullOrWhiteSpace($SuccessText)){
        Write-Host ("Tilt set to {0} degrees on Kinect {1}." -f $value,$id) -ForegroundColor Green
    }else{
        Write-Host ($SuccessText -f $value,$id) -ForegroundColor Green
    }
    return $true
}
function Set-Tilt{
    $text=Read-Host ("Tilt angle in degrees ({0} to {1}; 0 is geometric center)" -f $Product.TiltMinDegrees,$Product.TiltMaxDegrees)
    $value=0
    if(![int]::TryParse($text,[ref]$value)){Write-Host 'Invalid value.' -ForegroundColor Yellow;return}
    [void](Invoke-TiltDegrees $value)
}
function Set-StartupTilt{
    [void](Invoke-TiltDegrees ([int]$Product.StartupTiltDegrees) 'Tilt returned to the startup pose ({0:+#;-#;0} degrees) on Kinect {1}.')
}

# The control panel itself is intentionally a standard-user process.  Only
# operations that mutate machine state cross the UAC boundary.
# When the Studio is launched directly from the repository there is no
# native binary distribution yet.  Install/Reinstall owns that bootstrap:
# build the Windows runtime first, then delegate to the generated control panel
# so installation always consumes the exact artifacts that were just built.
if($Action -eq 'Install' -and (!(Test-Path -LiteralPath $Nui -PathType Leaf) -or !(Test-Path -LiteralPath $Setup -PathType Leaf))){
    $sourceBuild=Join-Path $Root 'BUILD.cmd'
    $builtControl=[IO.Path]::GetFullPath((Join-Path $Root '..\..\..\binaries\windows\drivers\system\Kinect.ps1'))
    if(Test-Path -LiteralPath $sourceBuild -PathType Leaf){
        Header
        Write-Host 'Native driver/runtime is not built yet. Building the clean distribution first...' -ForegroundColor Cyan
        $previousParent=$env:REMOLD_BUILD_PARENT
        try{
            $env:REMOLD_BUILD_PARENT='1'
            & cmd.exe /d /c ('"{0}"' -f $sourceBuild)
            $buildCode=$LASTEXITCODE
        }finally{
            if($null -eq $previousParent){Remove-Item Env:REMOLD_BUILD_PARENT -ErrorAction SilentlyContinue}else{$env:REMOLD_BUILD_PARENT=$previousParent}
        }
        if($buildCode -ne 0){Write-Host ("Native build failed with code {0}." -f $buildCode) -ForegroundColor Red;Pause-Menu;return}
        if(!(Test-Path -LiteralPath $builtControl -PathType Leaf)){Write-Host 'Build completed but the generated Kinect control script was not found.' -ForegroundColor Red;Pause-Menu;return}
        & $builtControl -Action Install
        return
    }
}
$PrivilegedActions=@('Install','IpCredentials','IpReset','IpLocal','IpLan','IpDevice','IpToggle','Restart','Uninstall')
if($Action -ne 'Menu' -and ($PrivilegedActions -contains $Action) -and !(Test-IsAdministrator)){
    Header
    Write-Host ("{0} changes Windows system state and will now request administrator permission." -f $Action) -ForegroundColor Cyan
    if(Start-ElevatedAction $Action){
        Write-Host 'The elevated operation was started in a separate window. This control panel remains non-administrator.' -ForegroundColor DarkGray
    }
    return
}
if($Action -ne 'Menu'){
    Header
    $actionSucceeded=$true
    switch($Action){
        'Install'{try{& $Install -DistributionRoot $Root -Simple}catch{Write-Host '';Write-Host 'INSTALLATION FAILED' -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red}}
        'Status'{Show-Status}
        'OpenCamera'{Open-Camera}
        'Tilt'{Set-Tilt}
        'StartupTilt'{Set-StartupTilt}
        'RgbHqStatus'{$actionSucceeded=Invoke-RgbHq 'status'}
        'RgbHqOn'{$actionSucceeded=Invoke-RgbHq 'on'}
        'RgbHqOff'{$actionSucceeded=Invoke-RgbHq 'off'}
        'RgbHqToggle'{$actionSucceeded=Toggle-RgbHq}
        'IpStatus'{Show-CameraIp}
        'IpCredentials'{Show-CameraIpCredentials}
        'IpReset'{Reset-CameraIpPassword}
        'IpLocal'{Set-CameraIpNetworkMode $false}
        'IpLan'{Set-CameraIpNetworkMode $true}
        'IpDevice'{Set-CameraIpDevice}
        'IpToggle'{Toggle-CameraIp}
        'OpenStudio'{[void](Open-Studio)}
        'Restart'{Restart-Runtime}
        'Uninstall'{$confirm=Read-Host 'Type REMOVE to confirm';if($confirm -ceq 'REMOVE'){try{& $Uninstall -DistributionRoot $Root}catch{Write-Host '';Write-Host 'UNINSTALL FAILED' -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red}}else{Write-Host 'Canceled.'}}
    }
    if($Action -eq 'OpenStudio'){return}
    if($NoPause){if($actionSucceeded){exit 0}else{exit 1}}
    Write-Host '';Write-Host 'Command completed. You can close this window.' -ForegroundColor DarkGray
    Pause-Menu
    if(!$actionSucceeded){exit 1}
    return
}
while($true){
    Header
    Write-Host '1  Install / Reinstall'
    Write-Host '2  Status'
    Write-Host '3  Open Windows Camera (RGB only)'
    Write-Host '4  Set manual Tilt'
    Write-Host ("5  Return Tilt to startup pose ({0:+#;-#;0} degrees)" -f $Product.StartupTiltDegrees)
    Write-Host '6  RGB HQ'
    Write-Host '7  Show IP camera status / URLs (credentials hidden)'
    Write-Host '8  Show IP camera credentials (administrator)'
    Write-Host '9  Reset IP camera password'
    Write-Host '10 Set IP camera LOCAL ONLY (127.0.0.1)'
    Write-Host '11 Set IP camera LAN PRIVATE mode'
    Write-Host '12 Bind IP camera to selected Kinect (administrator)'
    Write-Host '13 Enable / Disable IP camera'
    Write-Host '14 Open SynKinect Studio'
    Write-Host '15 Restart Kinect runtime (administrator)'
    Write-Host '16 Uninstall'
    Write-Host '0  Exit'
    Write-Host ''
    $choice=(Read-Host 'Choose').Trim().ToUpperInvariant()
    switch($choice){
        '1'{Header;Invoke-SelfAction 'Install';Pause-Menu}
        '2'{Header;Show-Status;Pause-Menu}
        '3'{Header;Open-Camera;Start-Sleep -Milliseconds 500}
        '4'{Header;Set-Tilt;Pause-Menu}
        '5'{Header;Set-StartupTilt;Pause-Menu}
        '6'{Header;[void](Toggle-RgbHq);Pause-Menu}
        '7'{Header;Show-CameraIp;Pause-Menu}
        '8'{Header;Invoke-SelfAction 'IpCredentials';Pause-Menu}
        '9'{Header;Invoke-SelfAction 'IpReset';Pause-Menu}
        '10'{Header;Invoke-SelfAction 'IpLocal';Pause-Menu}
        '11'{Header;Invoke-SelfAction 'IpLan';Pause-Menu}
        '12'{Header;Invoke-SelfAction 'IpDevice';Pause-Menu}
        '13'{Header;Invoke-SelfAction 'IpToggle';Pause-Menu}
        '14'{Header;if(Open-Studio){return};Start-Sleep -Milliseconds 500}
        '15'{Header;Invoke-SelfAction 'Restart';Pause-Menu}
        '16'{Header;Invoke-SelfAction 'Uninstall';Pause-Menu}
        '0'{return}
        default{Write-Host 'Invalid option.' -ForegroundColor Yellow;Start-Sleep -Milliseconds 700}
    }
}
