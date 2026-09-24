[CmdletBinding()]
param([string]$DistributionRoot='', [switch]$Simple)
$ErrorActionPreference='Stop'
$Root=if([string]::IsNullOrWhiteSpace($DistributionRoot)){Split-Path -Parent $PSScriptRoot}else{[IO.Path]::GetFullPath($DistributionRoot)}
. (Join-Path $PSScriptRoot 'Common.ps1')
$Product=Import-RemoldProductConfig $PSScriptRoot
$ProductName=$Product.Name

function Stage([string]$Text){Write-Host $Text -ForegroundColor Cyan}
function Need([string]$Path){if(!(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Missing build output: $Path"}}
function Get-DriverPackage([string]$Key){
    $spec=$Product.DriverPackages|Where-Object{$_.Key -eq $Key}|Select-Object -First 1
    if(!$spec){throw "Driver package definition not found: $Key"}
    $hardwareIds=@()
    if($null -ne $spec.HardwareIds){$hardwareIds=@($spec.HardwareIds|Where-Object{![string]::IsNullOrWhiteSpace([string]$_)})}
    elseif(![string]::IsNullOrWhiteSpace([string]$spec.HardwareId)){$hardwareIds=@([string]$spec.HardwareId)}
    $primaryHardwareId=if($hardwareIds.Count){$hardwareIds[0]}else{$null}
    return [pscustomobject]@{
        Key=$spec.Key
        DisplayName=$spec.DisplayName
        Inf=(Get-DistributionArtifact $Root $spec.Inf)
        Cat=(Get-DistributionArtifact $Root $spec.Cat)
        HardwareId=$primaryHardwareId
        HardwareIds=$hardwareIds
        RootHardwareId=$spec.RootHardwareId
    }
}
function Invoke-SetupInteractive([string[]]$Arguments=@()){
    # Route the native setup helper through Invoke-Native so redirected stderr
    # remains ordinary process output while the caller handles the exit code.
    $result=Invoke-Native $Setup $Arguments
    Show-Native $result
    return [int]$result.ExitCode
}
function Assert-DevelopmentSignature([string]$Path,[string]$Thumbprint,[switch]$RequireTrusted){
    $sig=Get-AuthenticodeSignature -LiteralPath $Path
    if($null -eq $sig.SignerCertificate){throw "Unsigned development artifact: $Path"}
    if($sig.SignerCertificate.Thumbprint.ToUpperInvariant() -ne $Thumbprint){throw "Development signer mismatch: $Path"}
    if($sig.Status -eq [System.Management.Automation.SignatureStatus]::HashMismatch){throw "Development signature hash mismatch: $Path"}
    if($RequireTrusted -and $sig.Status -ne [System.Management.Automation.SignatureStatus]::Valid){throw "Development signature is not trusted after certificate import: $Path ($($sig.Status))"}
}
function Initialize-DevelopmentPackageTrust([string]$CertPath,[string[]]$Catalogs){
    $cert=Get-CertificateFromFile $CertPath
    if($null -eq $cert -or [string]::IsNullOrWhiteSpace($cert.Thumbprint)){throw 'Development package certificate is invalid.'}
    $thumb=$cert.Thumbprint.ToUpperInvariant()
    $artifacts=@($Catalogs)
    foreach($artifact in $artifacts){Assert-DevelopmentSignature $artifact $thumb}
    foreach($storeName in @('Root','TrustedPublisher')){Add-CertificateToMachineStore $cert $storeName}
    foreach($artifact in $artifacts){Assert-DevelopmentSignature $artifact $thumb -RequireTrusted}
    Write-Host ("  Development signer : {0}" -f $cert.Subject) -ForegroundColor Yellow
    Write-Host ("  Signer thumbprint  : {0}" -f $thumb) -ForegroundColor DarkGray
    Write-Host '  PnP catalog trust  : VALID' -ForegroundColor Green
}
function Stage-DriverPackage([string]$Inf,[string]$Name){
    $r=Invoke-Native 'pnputil.exe' @('/add-driver',$Inf)
    if($r.ExitCode -ne 0){
        Show-Native $r
        throw ("Pre-staging failed for {0} (PnPUtil exit {1}). No device bindings have been changed." -f $Name,$r.ExitCode)
    }
    if(!$Simple){Show-Native $r}
    Write-Host ("  STAGED {0}" -f $Name) -ForegroundColor Green
}
function Restore-1473InboxHubIfNeeded {
    # 045E:02C2 is the Kinect 1473 parent USB hub/controller. It must never use
    # the Remold WinUSB transport. This preflight is version-agnostic: if a
    # machine presents 02C2 on WINUSB, remove only the conflicting Remold NUI
    # package, rebuild the devnode and require the Microsoft inbox USB stack
    # before any current package is staged.
    $hubId=[string]$Product.Kinect1473HubHardwareId
    $nodes=@()
    try{
        $nodes=@(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object {$_.PNPDeviceID -like ($hubId+'*')})
    }catch{
        Note-Issue ("Could not inspect the Kinect 1473 parent hub: {0}" -f $_.Exception.Message)
        return
    }
    if($nodes.Count -eq 0){return}
    $bad=@($nodes|Where-Object{[string]$_.Service -ieq 'WINUSB'})
    if($bad.Count -eq 0){return}

    Stage 'Preflight: restoring Kinect 1473 parent hub to the Microsoft inbox USB stack...'
    foreach($service in @($Product.Services.CameraIp,$Product.Services.CameraBridge,$Product.Services.AudioBridge,$Product.Services.Broker)){
        [void](Stop-ServiceBounded $service 4000 -ForceProcess -Quiet)
    }

    $packages=@()
    try{
        $packages=@(Get-WindowsDriver -Online -All -ErrorAction Stop | Where-Object {
            if($_.Inbox){return $false}
            $leaf=''
            try{$leaf=[IO.Path]::GetFileName([string]$_.OriginalFileName)}catch{}
            return ($leaf -ieq 'Kinect360RemoldNui.inf')
        })
    }catch{
        throw ("Could not enumerate Driver Store packages while restoring 02C2: {0}" -f $_.Exception.Message)
    }
    foreach($pkg in $packages){
        $published=[string]$pkg.Driver
        if([string]::IsNullOrWhiteSpace($published)){continue}
        Write-Host ("  Removing conflicting Remold NUI package {0}" -f $published) -ForegroundColor Yellow
        $r=Invoke-Native 'pnputil.exe' @('/delete-driver',$published,'/uninstall','/force')
        if($r.ExitCode -ne 0){
            Show-Native $r
            throw ("Could not remove conflicting Kinect360RemoldNui package {0}." -f $published)
        }
        if(!$Simple){Show-Native $r}
    }

    foreach($node in $bad){
        $id=[string]$node.PNPDeviceID
        if([string]::IsNullOrWhiteSpace($id)){continue}
        $r=Invoke-Native 'pnputil.exe' @('/remove-device',$id)
        if($r.ExitCode -ne 0 -and !$Simple){Show-Native $r}
    }
    [void](Invoke-Native 'pnputil.exe' @('/scan-devices'))

    $healthy=$false
    for($attempt=1;$attempt -le 30;$attempt++){
        Start-Sleep -Milliseconds 500
        try{
            $fresh=@(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object {$_.PNPDeviceID -like ($hubId+'*')})
            if($fresh.Count -eq 0){continue}
            $healthy=$true
            foreach($node in $fresh){
                $service=[string]$node.Service
                $problem=try{[int]$node.ConfigManagerErrorCode}catch{-1}
                if($service -ieq 'WINUSB' -or $problem -ne 0){$healthy=$false;break}
            }
            if($healthy){break}
        }catch{}
    }
    if(!$healthy){
        throw 'Kinect 1473 02C2 did not recover on the Microsoft inbox USB hub stack.'
    }
    Write-Host '  Kinect 1473 parent hub restored on the Microsoft inbox USB stack.' -ForegroundColor Green
}
function Show-SetupApiDiagnostic([string]$HardwareId){
    $setupLog=Join-Path $env:WINDIR 'INF\setupapi.dev.log'
    if(!(Test-Path -LiteralPath $setupLog -PathType Leaf)){return}
    try{
        $lines=@(Get-Content -LiteralPath $setupLog -ErrorAction Stop)
        if($lines.Count -eq 0){return}
        $pattern=[regex]::Escape($HardwareId)
        $last=-1
        for($j=0;$j -lt $lines.Count;$j++){if($lines[$j] -match $pattern){$last=$j}}
        $start=[Math]::Max(0,$lines.Count-120)
        if($last -ge 0){$start=[Math]::Max(0,$last-35)}
        $end=[Math]::Min($lines.Count-1,$start+119)
        Write-Host ("--- setupapi.dev.log status for {0} ---" -f $HardwareId) -ForegroundColor DarkYellow
        for($i=$start;$i -le $end;$i++){Write-Host $lines[$i]}
        Write-Host '--- end setupapi.dev.log status ---' -ForegroundColor DarkYellow
    }catch{
        Write-Host ("Could not read setupapi.dev.log: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}
$script:ProbeText=''
$script:ProbeLines=@()
$script:Issues=New-Object 'System.Collections.Generic.List[string]'
$script:State=[ordered]@{
    Device='PENDING'
    Broker='PENDING'
    Motor='PENDING'
    Camera='PENDING'
    CameraIp='PENDING'
    Audio='PENDING'
    WindowsCamera='PENDING'
}
$script:Motor1414Required=$false
$script:Motor1414Ready=$false
$script:Motor1473Required=$false
$script:Motor1473HubReady=$false
$script:Motor1473PnpReady=$false
$script:MotorFatal=$false
$script:Usb1473PolicyChanged=$false
$script:Audio1473RecoveryAttempted=$false

function Set-UsbDeviceFlagByte([string]$UsbFlagsKey,[string]$ValueName,[byte]$Value=1){
    $path="HKLM:\SYSTEM\CurrentControlSet\Control\usbflags\$UsbFlagsKey"
    if(!(Test-Path -LiteralPath $path)){
        New-Item -Path $path -Force|Out-Null
    }
    $same=$false
    try{
        $current=(Get-ItemProperty -LiteralPath $path -Name $ValueName -ErrorAction Stop).$ValueName
        if($current -is [byte[]] -and $current.Length -ge 1 -and [byte]$current[0] -eq $Value){$same=$true}
    }catch{}
    if($same){return $false}
    New-ItemProperty -LiteralPath $path -Name $ValueName -PropertyType Binary -Value ([byte[]]@($Value)) -Force|Out-Null
    return $true
}
function Initialize-1473UsbIdentityAndResumePolicy {
    [void](Read-UsbInventory)
    $hubId=[string]$Product.Kinect1473HubHardwareId
    if(!(Has-HardwareId $hubId)){return $false}

    # Kinect 1473 cameras report the placeholder USB serial 0000000000000000.
    # Windows normally uses a USB serial as part of the device-instance identity;
    # with more than one 1473 (or after reconnect/re-enumeration) that placeholder
    # can create unstable or colliding identities. Scope only the known 1473
    # camera identity (VID 045E, PID 02AE, bcdDevice 02.05) to its physical USB
    # port instead. Model 1414 reports a distinct bcdDevice value and keeps its serial.
    $changed=$false
    if(Set-UsbDeviceFlagByte '045E02AE0205' 'IgnoreHWSerNum' 1){$changed=$true}
    if(Set-UsbDeviceFlagByte '045E02AE0205' 'ResetOnResume' 1){$changed=$true}

    # 02C2 is the 1473 internal hub (bcdDevice 00.01). A reset on resume is a
    # targeted recovery policy for that hub only; no global USB selective-
    # suspend or power-management policy is changed.
    if(Set-UsbDeviceFlagByte '045E02C20001' 'ResetOnResume' 1){$changed=$true}

    $script:Usb1473PolicyChanged=$changed
    if($changed){
        Write-Host '  Kinect 1473 USB identity/power policy: UPDATED (02AE port-scoped identity; reset-on-resume enabled).' -ForegroundColor Green
    }else{
        Write-Host '  Kinect 1473 USB identity/power policy: READY.' -ForegroundColor Green
    }
    return $changed
}

function Note-Issue([string]$Message){
    if(!$script:Issues.Contains($Message)){
        $script:Issues.Add($Message)
        Write-Warning $Message
    }
}
function Try-Bind([string]$HardwareId,[string]$Inf,[string]$Name){
    $exit=Invoke-SetupInteractive @('bind',$HardwareId,$Inf)
    if($exit -ne 0){
        Show-SetupApiDiagnostic $HardwareId
        Note-Issue ("{0} could not be bound to the current driver (Setup exit {1})." -f $Name,$exit)
        return $false
    }
    return $true
}
function Try-EnsureRoot([string]$HardwareId,[string]$Inf,[string]$Name){
    $exit=Invoke-SetupInteractive @('ensure-root',$HardwareId,$Inf,$Name)
    if($exit -eq 5){
        Show-SetupApiDiagnostic $HardwareId
        throw ("Windows has a pending restart for the {0} service/root-device update. Reboot Windows once, then run Install / Reinstall again. No further Kinect driver changes were attempted in this run." -f $Name)
    }
    if($exit -ne 0){
        Show-SetupApiDiagnostic $HardwareId
        Note-Issue ("{0} root device could not be created (Setup exit {1})." -f $Name,$exit)
        return $false
    }
    return $true
}
function Read-UsbInventory{
    $r=Invoke-Native $Setup @('probe')
    if($r.ExitCode -ne 0){
        $script:ProbeText=''
        $script:ProbeLines=@()
        return $false
    }
    $script:ProbeLines=@($r.StdOutLines)
    $script:ProbeText=$r.StdOutLines -join "`n"
    return $true
}
function Has-HardwareId([string]$HardwareId){
    return (![string]::IsNullOrWhiteSpace($script:ProbeText) -and
        [regex]::IsMatch($script:ProbeText,"(?im)^PRESENT\s+$([regex]::Escape($HardwareId))\s*$"))
}
function Has-AnyHardwareId([string[]]$HardwareIds){
    foreach($id in @($HardwareIds)){if(Has-HardwareId $id){return $true}}
    return $false
}
function Get-PresentHardwareIds([string[]]$HardwareIds){
    return @($HardwareIds|Where-Object{Has-HardwareId $_})
}
function Show-UsbInventory{
    if(Read-UsbInventory){
        if($script:ProbeLines.Count -eq 0 -or ($script:ProbeLines.Count -eq 1 -and $script:ProbeLines[0] -eq 'PRESENT NONE')){
            Write-Host '  (no Kinect NUI USB function currently visible)' -ForegroundColor Yellow
        }else{
            $script:ProbeLines|ForEach-Object{Write-Host "  $_"}
        }
    }
}
function Rescan{
    $r=Invoke-Native 'pnputil.exe' @('/scan-devices')
    if($r.ExitCode -ne 0 -and !$Simple){Show-Native $r}
    Start-Sleep -Milliseconds 400
    [void](Read-UsbInventory)
}
function Wait-HardwareId([string]$HardwareId,[int]$MaxAttempts=30){
    for($i=1;$i -le $MaxAttempts;$i++){
        if($i -eq 1 -or ($i % 6) -eq 0){Rescan}else{[void](Read-UsbInventory)}
        if(Has-HardwareId $HardwareId){return $true}
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Wait-AnyHardwareId([string[]]$HardwareIds,[int]$MaxAttempts=30){
    for($i=1;$i -le $MaxAttempts;$i++){
        if($i -eq 1 -or ($i % 6) -eq 0){Rescan}else{[void](Read-UsbInventory)}
        if(Has-AnyHardwareId $HardwareIds){return $true}
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Wait-HardwarePresentStable([string]$HardwareId,[int]$MaxAttempts=24,[int]$StableSamples=6){
    # Require consecutive 02AE observations after a Kinect 1473 hub restart
    # before asking SetupAPI to replace the function driver. The native helper
    # tolerates devnode recreation during the bind operation.
    $stable=0
    for($i=1;$i -le $MaxAttempts;$i++){
        if($i -eq 1 -or ($i % 6) -eq 0){Rescan}else{[void](Read-UsbInventory)}
        if(Has-HardwareId $HardwareId){
            $stable++
            if($stable -ge $StableSamples){return $true}
        }else{
            $stable=0
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}
function Test-PhysicalDeviceReady([string]$HardwareId){
    $r=Invoke-Native $Setup @('device-status',$HardwareId)
    return [pscustomobject]@{Ready=($r.ExitCode -eq 0);Result=$r}
}
function Get-DeviceProblem([object]$Result){
    $text=if($null -eq $Result){''}else{@($Result.Lines) -join ' '}
    $match=[regex]::Match($text,'(?i)\bproblem=(\d+)\b')
    if(!$match.Success){return [pscustomobject]@{Code=$null;Name='UNKNOWN'}}
    $code=[int]$match.Groups[1].Value
    $name=switch($code){
        0 {'NONE'}
        10 {'CM_PROB_FAILED_START'}
        31 {'CM_PROB_FAILED_ADD'}
        37 {'CM_PROB_FAILED_DRIVER_ENTRY'}
        39 {'CM_PROB_DRIVER_FAILED_LOAD'}
        48 {'CM_PROB_DRIVER_BLOCKED'}
        52 {'CM_PROB_UNSIGNED_DRIVER'}
        default {'CM_PROB_' + $code}
    }
    return [pscustomobject]@{Code=$code;Name=$name}
}
function Wait-DeviceStarted([string]$HardwareId,[int]$MaxAttempts=24){
    $last=$null
    for($i=1;$i -le $MaxAttempts;$i++){
        if($i -eq 1 -or ($i % 6) -eq 0){Rescan}
        $probe=Test-PhysicalDeviceReady $HardwareId
        $last=$probe.Result
        if($probe.Ready){return [pscustomobject]@{Ready=$true;Result=$last;Problem=(Get-DeviceProblem $last)}}
        Start-Sleep -Milliseconds 400
    }
    return [pscustomobject]@{Ready=$false;Result=$last;Problem=(Get-DeviceProblem $last)}
}
function Wait-PhysicalStable([string]$HardwareId,[int]$MaxAttempts=20,[int]$StableSamples=3,[int]$MinAttempts=1){
    $stable=0
    $last=$null
    for($i=1;$i -le $MaxAttempts;$i++){
        if(($i % 6) -eq 0){Rescan}else{[void](Read-UsbInventory)}
        if(!(Has-HardwareId $HardwareId)){
            $stable=0
        }else{
            $probe=Test-PhysicalDeviceReady $HardwareId
            $last=$probe.Result
            if($probe.Ready){$stable++}else{$stable=0}
            if($i -ge $MinAttempts -and $stable -ge $StableSamples){
                return [pscustomobject]@{Ready=$true;Result=$last}
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return [pscustomobject]@{Ready=$false;Result=$last}
}
function Bind-And-Stabilize([string]$HardwareId,[string]$Inf,[string]$Name,[string]$StateKey){
    if(!(Wait-HardwarePresentStable $HardwareId 30 5)){
        $script:State[$StateKey]='PENDING'
        Write-Host ("{0}: PENDING ({1} did not remain present long enough to bind safely)" -f $Name,$HardwareId) -ForegroundColor Yellow
        return $false
    }
    $existing=Test-StartedWinUsb $HardwareId
    if($existing.Ready){
        $script:State[$StateKey]='READY'
        Write-Host ("{0}: READY ({1} instance(s), existing WinUSB preserved)" -f $Name,$existing.Instances) -ForegroundColor Green
        return $true
    }
    if(!(Try-Bind $HardwareId $Inf $Name)){
        Rescan
        $afterFailure=Test-StartedWinUsb $HardwareId
        if($afterFailure.Ready){
            $script:State[$StateKey]='READY'
            Write-Host ("{0}: READY ({1} instance(s), WinUSB became active during reconciliation)" -f $Name,$afterFailure.Instances) -ForegroundColor Green
            return $true
        }
        $script:State[$StateKey]='FAILED'
        return $false
    }
    $stable=Wait-PhysicalStable $HardwareId 16 3 3
    if($stable.Ready){
        $script:State[$StateKey]='READY'
        Write-Host ("{0}: READY" -f $Name) -ForegroundColor Green
        return $true
    }
    if($null -ne $stable.Result){Show-Native $stable.Result}
    $problem=Get-DeviceProblem $stable.Result
    if($problem.Code -eq 52 -or $problem.Code -eq 48){
        $script:State[$StateKey]=('BLOCKED-CODE'+$problem.Code)
        Note-Issue ("{0} is bound but Windows Code Integrity blocked its function driver: Code {1} ({2})." -f $Name,$problem.Code,$problem.Name)
    }else{
        $script:State[$StateKey]='PENDING'
        Note-Issue ("{0} is present/bound but its PnP devnode did not reach a stable STARTED state." -f $Name)
    }
    return $false
}
function Bind-And-StabilizeMany([string[]]$HardwareIds,[string]$Inf,[string]$Name,[string]$StateKey){
    $ids=@($HardwareIds|Where-Object{![string]::IsNullOrWhiteSpace([string]$_)}|Select-Object -Unique)
    if($ids.Count -eq 0){throw "No hardware IDs configured for $Name"}
    if(!(Wait-AnyHardwareId $ids 20)){
        $script:State[$StateKey]='PENDING'
        Write-Host ("{0}: PENDING (no supported USB function visible: {1})" -f $Name,($ids -join ', ')) -ForegroundColor Yellow
        return $false
    }
    [void](Read-UsbInventory)
    $present=@(Get-PresentHardwareIds $ids)
    $allReady=$true
    $blockedState=$null
    foreach($id in $present){
        $ok=Bind-And-Stabilize $id $Inf ("{0} [{1}]" -f $Name,$id) $StateKey
        if(!$ok){
            $allReady=$false
            $candidate=[string]$script:State[$StateKey]
            if($candidate -like 'BLOCKED-CODE*'){$blockedState=$candidate}
        }
    }
    if($allReady -and $present.Count -gt 0){
        $script:State[$StateKey]='READY'
        Write-Host ("{0}: READY ({1} supported hardware ID(s), all present instances STARTED)" -f $Name,$present.Count) -ForegroundColor Green
        return $true
    }
    $script:State[$StateKey]=if($blockedState){$blockedState}else{'FAILED'}
    return $false
}
function Test-PresentHardwareIdNative([string]$HardwareId){
    $r=Invoke-Native $Setup @('device-status',$HardwareId)
    $text=@($r.Lines) -join "`n"
    $present=($text -match '(?im)^SUMMARY\s+hardware-id=')
    return [pscustomobject]@{Present=$present;Ready=($r.ExitCode -eq 0 -and $present);Result=$r}
}
function Update-MotorState {
    if($script:MotorFatal){$script:State.Motor='FAILED';return}
    $required=0;$ready=0
    if($script:Motor1414Required){$required++;if($script:Motor1414Ready){$ready++}}
    # 1473 install readiness is transport readiness only. LED/tilt replies are
    # runtime I/O and must never gate camera/audio installation.
    if($script:Motor1473Required){$required++;if($script:Motor1473HubReady -and $script:Motor1473PnpReady){$ready++}}
    if($required -eq 0){$script:State.Motor='PENDING'}
    elseif($ready -eq $required){$script:State.Motor='READY'}
    else{$script:State.Motor='PENDING'}
}
function Initialize-MotorTopology {
    [void](Read-UsbInventory)
    $script:Motor1414Required=Has-HardwareId $MotorPackage.HardwareId
    $script:Motor1473Required=Has-HardwareId ([string]$Product.Kinect1473HubHardwareId)

    if($script:Motor1414Required){
        Write-Host '  Kinect 1414 detected: stabilizing dedicated 02B0 motor function on WinUSB.' -ForegroundColor Cyan
        $existing1414=Test-StartedWinUsb $MotorPackage.HardwareId
        if($existing1414.Ready){
            $script:Motor1414Ready=$true
            Write-Host '  Kinect 1414 motor: READY (existing WinUSB preserved).' -ForegroundColor Green
        }elseif(Try-Bind $MotorPackage.HardwareId $NuiInf $MotorPackage.DisplayName){
            $stable=Wait-PhysicalStable $MotorPackage.HardwareId 16 3 3
            $script:Motor1414Ready=$stable.Ready
            if(!$stable.Ready){
                if($null -ne $stable.Result){Show-Native $stable.Result}
                Note-Issue 'Kinect 1414 02B0 motor function did not reach a stable STARTED state.'
            }
        }else{$script:MotorFatal=$true}
    }

    if($script:Motor1473Required){
        Write-Host '  Kinect 1473 detected: preserving 02C2 on the Microsoft inbox USB hub driver.' -ForegroundColor Cyan
        $stable=Wait-PhysicalStable ([string]$Product.Kinect1473HubHardwareId) 20 3 2
        $script:Motor1473HubReady=$stable.Ready
        if($stable.Ready){
            Write-Host '  Kinect 1473 parent hub: READY (02C2 was not rebound to WinUSB)' -ForegroundColor Green
        }else{
            if($null -ne $stable.Result){Show-Native $stable.Result}
            $script:MotorFatal=$true
            Note-Issue 'Kinect 1473 02C2 parent hub is not STARTED. Do not bind this PID to WinUSB.'
        }
    }

    if(!$script:Motor1414Required -and !$script:Motor1473Required){
        Write-Host 'Xbox NUI Motor/control: PENDING (no 1414 02B0 or 1473 02C2 topology visible)' -ForegroundColor Yellow
    }
    Update-MotorState
}
function Test-StartedWinUsb([string]$HardwareId){
    $r=Invoke-Native $Setup @('device-status',$HardwareId)
    $text=@($r.Lines) -join "`n"
    $summaries=[regex]::Matches($text,'(?im)^SUMMARY\s+hardware-id=.*?instances=(\d+)\s+ready=(\d+)\s*$')
    if($r.ExitCode -ne 0 -or $summaries.Count -eq 0){return [pscustomobject]@{Ready=$false;Result=$r;Instances=0}}
    $instances=[int]$summaries[$summaries.Count-1].Groups[1].Value
    $ready=[int]$summaries[$summaries.Count-1].Groups[2].Value
    $deviceLines=@($r.Lines|Where-Object{$_ -match '^(READY|NOT_READY)\s+hardware-id='})
    $allWinUsb=($deviceLines.Count -eq $instances -and $instances -gt 0)
    foreach($line in $deviceLines){if($line -notmatch '(?i)\bservice=WINUSB\b'){$allWinUsb=$false;break}}
    return [pscustomobject]@{Ready=($allWinUsb -and $ready -eq $instances);Result=$r;Instances=$instances}
}
function Get-PresentUacHardwareId([object[]]$HardwareIds){
    [void](Read-UsbInventory)
    foreach($candidate in @($HardwareIds)){
        $id=[string]$candidate
        if(![string]::IsNullOrWhiteSpace($id) -and (Has-HardwareId $id)){return $id}
    }
    return $null
}
function Wait-PresentUacHardwareId([object[]]$HardwareIds,[int]$MaxAttempts=35){
    for($i=1;$i -le $MaxAttempts;$i++){
        $id=Get-PresentUacHardwareId $HardwareIds
        if($null -ne $id){return $id}
        Start-Sleep -Milliseconds 500
        if(($i % 5) -eq 0){Rescan}
    }
    return (Get-PresentUacHardwareId $HardwareIds)
}

function Stabilize-1473RuntimeControl([int]$MaxAttempts=35) {
    if(!$script:Motor1473Required){Update-MotorState;return $true}
    if(!$script:Motor1473HubReady){$script:Motor1473PnpReady=$false;Update-MotorState;return $false}
    $id=Wait-PresentUacHardwareId @($Product.KinectUacRuntimeControlHardwareIds) $MaxAttempts
    if($null -eq $id){
        $script:Motor1473PnpReady=$false
        Update-MotorState
        Write-Host 'Kinect 1473 motor/control transport: PENDING (no 02BB/02C3 MI_00 control interface visible yet)' -ForegroundColor Yellow
        return $false
    }

    # Preserve an already healthy WinUSB binding. Otherwise prefer Microsoft's
    # Audio Array Control package and use the Remold package only as fallback.
    # Do not send LED/tilt/status commands during setup. Physical protocol I/O
    # belongs to the runtime and must not gate camera/audio installation.
    $existing=Test-StartedWinUsb $id
    if(!$existing.Ready){
        $official=Invoke-Native $Setup @('bind-provider',$id,'Microsoft','Audio Array Control')
        if($official.ExitCode -eq 0){
            [void](Wait-PhysicalStable $id 18 2 2)
            $existing=Test-StartedWinUsb $id
        }
    }
    if(!$existing.Ready){
        Write-Host 'Kinect 1473 motor/control: applying the dedicated MI_00 WinUSB fallback package...' -ForegroundColor DarkCyan
        if(Try-Bind $id $Control1473Inf 'Kinect 1473 Audio Array Control fallback'){
            [void](Wait-PhysicalStable $id 22 2 2)
        }
        $existing=Test-StartedWinUsb $id
    }

    $script:Motor1473PnpReady=$existing.Ready
    if($existing.Ready){
        Write-Host ("Kinect 1473 motor/control transport: READY ({0} WinUSB instance(s); protocol is handled at runtime)" -f $existing.Instances) -ForegroundColor Green
    }else{
        Note-Issue 'Kinect 1473 MI_00 is present but did not reach a healthy WinUSB transport. Camera and audio setup continue independently.'
    }
    Update-MotorState
    return $script:Motor1473PnpReady
}

function Get-KinectUacAudioDevice{
    try{
        $captureIds=@($Product.KinectUacRuntimeCaptureHardwareIds)
        $audioDevices=@(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object{
                $pnp=[string]$_.PNPDeviceID
                $matched=$false
                foreach($candidate in $captureIds){
                    $prefix=[string]$candidate
                    if(!$matched -and ![string]::IsNullOrWhiteSpace($prefix) -and $pnp.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$matched=$true}
                }
                $matched
            })
        if($audioDevices.Count -eq 0){return $null}
        $ready=@($audioDevices|Where-Object{try{[int]$_.ConfigManagerErrorCode -eq 0}catch{$false}})
        if($ready.Count){return $ready[0]}
        return $audioDevices[0]
    }catch{return $null}
}
function Test-1473AudioRuntimeVisible {
    [void](Read-UsbInventory)
    return ($null -ne (Get-KinectUacAudioDevice))
}
function Get-AudioBridgeDiagnostics {
    $path=Join-Path $env:ProgramData 'Kinect360Remold\audio-bridge-status.txt'
    $values=@{}
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){return $values}
    try{
        foreach($line in Get-Content -LiteralPath $path -ErrorAction Stop){
            if([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.IndexOf('=') -lt 1){continue}
            $parts=$line -split '=',2
            $values[$parts[0].Trim()]=$parts[1].Trim()
        }
    }catch{}
    return $values
}
function Wait-AudioRuntimeTransition([int]$MaxAttempts=60){
    $lastStage='waiting-for-uac-runtime'
    $lastError='0'
    for($i=1;$i -le $MaxAttempts;$i++){
        if($i -eq 1 -or ($i % 6) -eq 0){Rescan}else{[void](Read-UsbInventory)}
        $uacDevice=Get-KinectUacAudioDevice
        if($null -ne $uacDevice){
            $ready=$false
            try{$ready=([int]$uacDevice.ConfigManagerErrorCode -eq 0)}catch{}
            if($ready){return [pscustomobject]@{Ready=$true;Failed=$false;Stage='uac-runtime-ready';LastError='0'}}
        }
        $diag=Get-AudioBridgeDiagnostics
        if($diag.ContainsKey('stage') -and ![string]::IsNullOrWhiteSpace([string]$diag.stage)){$lastStage=[string]$diag.stage}
        if($diag.ContainsKey('last_error')){$lastError=[string]$diag.last_error}
        if($lastStage -eq 'uac-firmware-error'){
            return [pscustomobject]@{Ready=$false;Failed=$true;Stage=$lastStage;LastError=$lastError}
        }
        Start-Sleep -Milliseconds 500
    }
    return [pscustomobject]@{Ready=$false;Failed=$false;Stage=$lastStage;LastError=$lastError}
}
function Recover-1473IncompleteAudioRuntime {
    # Detect a partial 1473 runtime without cycling the live composite device.
    # restart or cycle the live 02BB/02C3 device automatically. Real 1473
    # firmware can expose a topology that differs from the Kinect-for-Windows
    # MI_00/MI_01/MI_02 layout. Destructive PnP recovery here can interrupt the
    # independent 02AE camera and turn an audio mismatch into RGB/IR/Depth churn.
    if(!$script:Motor1473Required -or $script:Audio1473RecoveryAttempted){return $false}
    $script:Audio1473RecoveryAttempted=$true
    [void](Read-UsbInventory)
    if(Test-1473AudioRuntimeVisible){return $true}

    $controlId=Get-PresentUacHardwareId @($Product.KinectUacRuntimeControlHardwareIds)
    if($null -eq $controlId){return $false}

    $control=Test-StartedWinUsb $controlId
    $script:Motor1473PnpReady=$control.Ready
    Update-MotorState
    Write-Host 'Kinect 1473 audio runtime: control interface is present without a usable 02AD/MI_02 capture path; preserving the live USB topology. Audio remains PENDING and the camera continues independently.' -ForegroundColor Yellow
    return $false
}

function Configure-AudioBridgeRuntime{
    $service=$Product.Services.AudioBridge
    if(!(Get-Service -Name $service -ErrorAction SilentlyContinue)){return $false}
    # The Kinect audio firmware re-enumerates 02AD -> the 02BB/02C3 UAC family. A trigger tied only to
    # the 02AD boot interface is therefore not a sufficient lifetime policy. Keep
    # the user-mode bridge alive so its raw Processing pipes remain available.
    # Reassert the Program Files binary path too: binding 02AD can execute the INF
    # AddService section and point ImagePath back at DriverStore. The product
    # runtime must remain independent of whether the transient boot devnode is
    # currently present.
    if((Get-Variable -Name RuntimeAudioBridge -Scope Script -ErrorAction SilentlyContinue) -and
       (Test-Path -LiteralPath $script:RuntimeAudioBridge -PathType Leaf)){
        $binary=('"{0}"' -f $script:RuntimeAudioBridge)
        [void](Invoke-Native 'sc.exe' @('config',$service,'binPath=',$binary))
    }
    [void](Invoke-Native 'sc.exe' @('config',$service,'start=','delayed-auto'))
    [void](Invoke-Native 'sc.exe' @('failure',$service,'reset=','60','actions=','restart/2000/restart/5000/restart/10000'))
    [void](Invoke-Native 'sc.exe' @('failureflag',$service,'1'))
    if(!(Start-ServiceBounded $service 6000 -Quiet)){
        Note-Issue 'AudioBridge is installed but did not reach RUNNING yet; audio setup will remain pending and retry at runtime startup.'
        return $false
    }
    return $true
}
function Stabilize-AudioFunction{
    $id=$AudioPackage.HardwareId
    [void](Read-UsbInventory)

    if(!(Get-Service -Name $Product.Services.AudioBridge -ErrorAction SilentlyContinue)){
        $script:State.Audio='FAILED'
        Note-Issue 'The persistent AudioBridge service is missing.'
        return $false
    }

    # If the Microsoft UAC runtime is already present, keep MI_02 on the inbox
    # audio stack and only ensure the resident WASAPI/raw-pipe bridge is running.
    $uacDevice=Get-KinectUacAudioDevice
    $uacReady=$false
    if($null -ne $uacDevice){
        try{$uacReady=([int]$uacDevice.ConfigManagerErrorCode -eq 0)}catch{$uacReady=$false}
    }
    if($uacReady){
        $bridgeReady=Configure-AudioBridgeRuntime
        if($bridgeReady){
            $script:State.Audio='READY'
            Write-Host 'Xbox NUI Audio runtime: READY (02BB/02C3 MI_02 present; AudioBridge running)' -ForegroundColor Green
        }else{
            $script:State.Audio='PENDING'
            Write-Host 'Xbox NUI Audio runtime: PENDING (MI_02 is present; AudioBridge will retry at runtime startup)' -ForegroundColor Yellow
        }
        return $true
    }

    # Bind the transient 02AD boot function before starting AudioBridge. Once the
    # bridge starts it may immediately upload firmware and make 02AD disappear, so
    # capture this state before service startup instead of treating that gap as a
    # missing device.
    $bootWasPresent=Has-HardwareId $id
    if($bootWasPresent){
        $bootExisting=Test-StartedWinUsb $id
        if(!$bootExisting.Ready){
            [void](Try-Bind $id $AudioInf $AudioPackage.DisplayName)
            Rescan
            $bootExisting=Test-StartedWinUsb $id
        }
        if(!$bootExisting.Ready){
            $probe=Wait-DeviceStarted $id 5
            if($probe.Problem.Code -eq 52 -or $probe.Problem.Code -eq 48){
                $script:State.Audio=('BLOCKED-CODE'+$probe.Problem.Code)
                Note-Issue ("Xbox NUI Audio boot package was blocked by Windows Code Integrity: Code {0}." -f $probe.Problem.Code)
                return $false
            }
            $script:State.Audio='PENDING'
            Note-Issue 'Xbox NUI Audio 02AD is present but has not reached a started WinUSB state yet; AudioBridge remains installed and will retry.'
            return $true
        }
    }

    $bridgeReady=Configure-AudioBridgeRuntime
    if(!$bridgeReady){
        $script:State.Audio='PENDING'
        return $true
    }

    if($bootWasPresent){
        Write-Host 'Xbox NUI Audio boot transport: READY; waiting for 02AD -> 02BB/02C3 UAC re-enumeration...' -ForegroundColor Green
        $transition=Wait-AudioRuntimeTransition 60
        if($transition.Ready){
            $script:State.Audio='READY'
            Write-Host 'Xbox NUI Audio runtime: READY (firmware launched, MI_02 present, AudioBridge running)' -ForegroundColor Green
            return $true
        }
        $script:State.Audio='PENDING'
        if($transition.Failed){
            Note-Issue ("Xbox NUI Audio firmware transition failed in AudioBridge (stage={0}, error={1}); the resident service will retry after a physical reconnect." -f $transition.Stage,$transition.LastError)
        }else{
            Write-Host ("Xbox NUI Audio runtime: PENDING (firmware transition stage={0}; AudioBridge remains armed for reconnect)" -f $transition.Stage) -ForegroundColor Yellow
        }
        return $true
    }

    # A running AudioBridge may already have consumed 02AD between two installer
    # observations. If runtime status shows an active firmware transition, wait for the
    # corresponding UAC runtime instead of reporting the transient enumeration gap.
    $diag=Get-AudioBridgeDiagnostics
    $stage=if($diag.ContainsKey('stage')){[string]$diag.stage}else{''}
    if($stage -eq 'uac-firmware-uploading' -or $stage -eq 'uac-firmware-launched'){
        $transition=Wait-AudioRuntimeTransition 50
        if($transition.Ready){
            $script:State.Audio='READY'
            Write-Host 'Xbox NUI Audio runtime: READY (02BB/02C3 MI_02 present; AudioBridge running)' -ForegroundColor Green
            return $true
        }
    }

    if($script:Motor1473Required -and !$script:Audio1473RecoveryAttempted){
        if(Recover-1473IncompleteAudioRuntime){return (Stabilize-AudioFunction)}
    }

    $script:State.Audio='PENDING'
    Write-Host 'Xbox NUI Audio: no boot or MI_02 endpoint is currently visible; persistent AudioBridge remains armed for reconnect.' -ForegroundColor Yellow
    return $true
}

function Stop-Runtime{
    $allStopped=$true
    foreach($serviceKey in @($Product.ServiceOrder)){
        $service=$Product.Services[$serviceKey]
        if(!(Stop-ServiceBounded $service 4500 -ForceProcess -Quiet)){
            $allStopped=$false
            Note-Issue ("Service {0} could not be stopped cleanly; its process was not released." -f $service)
        }
    }
    Start-Sleep -Milliseconds 250
    return $allStopped
}
function Install-AudioBridgeRuntime([string]$Source,[string]$Runtime){
    # AudioBridge is a product runtime service, not merely a side effect of the
    # 02AD boot INF. Kinect 1473 often remains in a post-firmware 02BB/02C3 state
    # across a driver reinstall; in that state 02AD is absent and SetupAPI never
    # executes the INF AddService section. Install/configure the bridge directly
    # so Microphones/Acoustic always get the raw audio pipe even when firmware is
    # already resident. The same executable still owns the 02AD firmware worker
    # whenever a boot interface appears later.
    Need $Source
    New-Item -ItemType Directory -Force $Runtime|Out-Null
    $destination=Join-Path $Runtime 'Kinect360RemoldAudioBridge.exe'
    [void](Stop-ServiceBounded $Product.Services.AudioBridge 4000 -ForceProcess -Quiet)
    $staleStatus=Join-Path $env:ProgramData 'Kinect360Remold\audio-bridge-status.txt'
    if(Test-Path -LiteralPath $staleStatus -PathType Leaf){Remove-Item -LiteralPath $staleStatus -Force -ErrorAction SilentlyContinue}
    Copy-Item -LiteralPath $Source -Destination $destination -Force

    $service=$Product.Services.AudioBridge
    $binary=('"{0}"' -f $destination)
    if($null -eq (Get-Service -Name $service -ErrorAction SilentlyContinue)){
        $create=Invoke-Native 'sc.exe' @('create',$service,'binPath=',$binary,'start=','auto','obj=','LocalSystem','DisplayName=','Xbox NUI Audio Remold Bridge')
        if($create.ExitCode -ne 0){Show-Native $create;throw "Could not create service $service."}
    }else{
        $config=Invoke-Native 'sc.exe' @('config',$service,'binPath=',$binary,'start=','auto','obj=','LocalSystem','DisplayName=','Xbox NUI Audio Remold Bridge')
        if($config.ExitCode -ne 0){Show-Native $config;throw "Could not update service $service."}
    }
    [void](Invoke-Native 'sc.exe' @('config',$service,'start=','delayed-auto'))
    [void](Invoke-Native 'sc.exe' @('description',$service,'Uploads Kinect UACFirmware 01.02.709.00 when 02AD is present, shares the native 02BB/02C3 Windows USB Audio endpoint through WASAPI and publishes the Remold raw microphone pipe without taking exclusive ownership.'))
    [void](Invoke-Native 'sc.exe' @('failure',$service,'reset=','60','actions=','restart/2000/restart/5000/restart/10000'))
    [void](Invoke-Native 'sc.exe' @('failureflag',$service,'1'))
    return $destination
}

function Install-CameraIpRuntime([string]$Source,[string]$Runtime){
    $policy=$Product.CameraIpPolicy
    if($null -eq $policy){throw 'CameraIpPolicy is missing from Product.psd1.'}
    New-Item -ItemType Directory -Force $Runtime|Out-Null
    $destination=Join-Path $Runtime 'Kinect360RemoldCameraIp.exe'
    Copy-Item -LiteralPath $Source -Destination $destination -Force

    $initArgs=@('init','--enabled',[string][bool]$policy.Enabled,'--bind',[string]$policy.Bind,'--port',[string]$policy.Port,'--user',[string]$policy.User,
        '--fps',[string]$policy.Fps,'--quality',[string]$policy.JpegQuality,'--max-clients',[string]$policy.MaxClients)
    $init=Invoke-Native $destination $initArgs
    if($init.ExitCode -ne 0){Show-Native $init;throw 'Native IP-camera runtime configuration failed.'}
    if(!$Simple){Show-Native $init}

    $service=$Product.Services.CameraIp
    $binary=('"{0}"' -f $destination)
    if($null -eq (Get-Service -Name $service -ErrorAction SilentlyContinue)){
        $create=Invoke-Native 'sc.exe' @('create',$service,'binPath=',$binary,'start=','demand','obj=','NT AUTHORITY\LocalService','DisplayName=','Kinect Xbox 360 Remold IP Camera')
        if($create.ExitCode -ne 0){Show-Native $create;throw "Could not create service $service."}
    }else{
        $config=Invoke-Native 'sc.exe' @('config',$service,'binPath=',$binary,'start=','demand','obj=','NT AUTHORITY\LocalService','DisplayName=','Kinect Xbox 360 Remold IP Camera')
        if($config.ExitCode -ne 0){Show-Native $config;throw "Could not update service $service."}
    }
    [void](Invoke-Native 'sc.exe' @('description',$service,'Optional authenticated HTTP/MJPEG camera over the shared Kinect RGB runtime. Disabled after install; the user explicitly enables it when wanted. LAN exposure is a separate explicit action.'))
    [void](Invoke-Native 'sc.exe' @('failure',$service,'reset=','60','actions=','restart/2000/restart/5000/restart/10000'))
    [void](Invoke-Native 'sc.exe' @('failureflag',$service,'1'))

    # Read the effective protected configuration after init. Installation applies
    # Product.psd1 network defaults while retaining a valid generated credential
    # and explicit device binding.
    $cfgPath=Join-Path (Join-Path $env:ProgramData $Product.Name) 'camera-ip-public.ini'
    $effectiveEnabled=$false
    $effectiveBind='127.0.0.1'
    if(Test-Path -LiteralPath $cfgPath -PathType Leaf){
        foreach($line in @(Get-Content -LiteralPath $cfgPath -ErrorAction SilentlyContinue)){
            if($line -match '^\s*enabled\s*=\s*(.+?)\s*$'){$effectiveEnabled=($Matches[1] -match '^(?i:true|1)$')}
            elseif($line -match '^\s*bind\s*=\s*(.+?)\s*$'){$effectiveBind=$Matches[1].Trim()}
        }
    }
    if($effectiveEnabled){[void](Invoke-Native 'sc.exe' @('config',$service,'start=','delayed-auto'))}
    else{[void](Invoke-Native 'sc.exe' @('config',$service,'start=','demand'))}

    $rule=[string]$policy.FirewallRuleName
    if(![string]::IsNullOrWhiteSpace($rule)){
        [void](Invoke-Native 'netsh.exe' @('advfirewall','firewall','delete','rule',("name={0}" -f $rule)))
        if($effectiveEnabled -and $effectiveBind -ne '127.0.0.1'){
            $firewallArgs=@(
                'advfirewall','firewall','add','rule',("name={0}" -f $rule),
                'dir=in','action=allow','protocol=TCP',("localport={0}" -f $policy.Port),
                ("profile={0}" -f $policy.FirewallProfile),("program={0}" -f $destination),
                ("remoteip={0}" -f $policy.FirewallRemoteIp),'enable=yes'
            )
            $firewall=Invoke-Native 'netsh.exe' $firewallArgs
            if($firewall.ExitCode -ne 0){Show-Native $firewall;Note-Issue 'IP-camera service was installed, but the Private/LocalSubnet firewall rule could not be created.'}
        }
    }
    return $destination
}
function Test-CameraIpRuntimeEnabled{
    $cfg=Join-Path (Join-Path $env:ProgramData $Product.Name) 'camera-ip-public.ini'
    if(!(Test-Path -LiteralPath $cfg -PathType Leaf)){return [bool]$Product.CameraIpPolicy.Enabled}
    try{
        $line=Get-Content -LiteralPath $cfg -ErrorAction Stop|Where-Object{$_ -match '^\s*enabled\s*='}|Select-Object -First 1
        if($null -ne $line){return (($line -split '=',2)[1].Trim() -match '^(?i:true|1)$')}
    }catch{}
    return $false
}
function Start-Runtime{
    $serviceKeys=@('Broker')
    if($script:State.Camera -eq 'READY'){$serviceKeys+='CameraBridge'}
    if((Test-CameraIpRuntimeEnabled) -and $null -ne (Get-Service -Name $Product.Services.CameraIp -ErrorAction SilentlyContinue)){$serviceKeys+='CameraIp'}
    if($null -ne (Get-Service -Name $Product.Services.AudioBridge -ErrorAction SilentlyContinue)){$serviceKeys+='AudioBridge'}
    $ok=$true
    foreach($serviceKey in $serviceKeys){
        $service=$Product.Services[$serviceKey]
        $installed=Get-Service -Name $service -ErrorAction SilentlyContinue
        if($null -eq $installed){
            $ok=$false
            Note-Issue ("Service {0} is expected for {1}, but it is not installed." -f $service,$serviceKey)
            continue
        }
        [void](Invoke-Native 'sc.exe' @('failure',$service,'reset=','60','actions=','restart/2000/restart/5000/restart/10000'))
        [void](Invoke-Native 'sc.exe' @('failureflag',$service,'1'))
        if(!(Start-ServiceBounded $service 7000 -Quiet)){
            $ok=$false
            Note-Issue ("Service {0} could not be started or did not reach RUNNING." -f $service)
        }
    }
    return $ok
}
function Install-VirtualCameraRuntime([string]$DllSource,[string]$CtlSource,[string]$RuntimeDirectory){
    New-Item -ItemType Directory -Force $RuntimeDirectory|Out-Null
    $sourceHash=(Get-FileHash -LiteralPath $DllSource -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $runtimeDll=Join-Path $RuntimeDirectory ("Kinect360RemoldCameraSource-{0}.dll" -f $sourceHash)
    $runtimeCtl=Join-Path $RuntimeDirectory 'Kinect360RemoldWebcam.exe'
    if(!(Test-Path -LiteralPath $runtimeDll -PathType Leaf)){
        Copy-Item -LiteralPath $DllSource -Destination $runtimeDll -ErrorAction Stop
    }else{
        $deployedHash=(Get-FileHash -LiteralPath $runtimeDll -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if($deployedHash -ne $sourceHash){throw "Virtual camera source hash mismatch: $runtimeDll"}
    }
    Copy-Item -LiteralPath $CtlSource -Destination $runtimeCtl -Force -ErrorAction Stop
    $registration=Invoke-Native $runtimeCtl @('register-source',$runtimeDll)
    if($registration.ExitCode -ne 0){
        Show-Native $registration
        throw 'Virtual camera COM source registration failed.'
    }
    # Windows Camera Frame Server keeps a loaded media source until it stops.
    # Stop it so the next camera open loads the source registered above; it is
    # a demand-start service in a shared svchost and is never force-killed.
    foreach($frameServer in @('FrameServerMonitor','FrameServer')){
        if(!(Stop-ServiceBounded $frameServer 8000 -Quiet)){
            Write-Host ("  {0} is still running; close camera applications or reboot to load the new virtual-camera source." -f $frameServer) -ForegroundColor Yellow
        }
    }
    Get-ChildItem -LiteralPath $RuntimeDirectory -File -Filter 'Kinect360RemoldCameraSource*.dll' -ErrorAction SilentlyContinue |
        Where-Object{$_.FullName -ne $runtimeDll} |
        ForEach-Object{
            try{Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop}
            catch{Write-Host ("  Virtual camera source cleanup deferred while Windows still maps {0}." -f $_.Name) -ForegroundColor DarkGray}
        }
    return [pscustomobject]@{Dll=$runtimeDll;Ctl=$runtimeCtl;Hash=$sourceHash}
}

function Test-WindowsCameraPnP([string]$DeviceId=''){
    try{
        $wantedPrefix=$Product.WindowsCameraNamePrefix
        $exactName=$null
        if(![string]::IsNullOrWhiteSpace($DeviceId)){$exactName=$wantedPrefix+$DeviceId+']'}
        $d=Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object{
                $_.PNPDeviceID -like 'SWD\VCAMDEVAPI*' -and
                (($null -ne $exactName -and $_.Name -eq $exactName) -or ($null -eq $exactName -and $_.Name -like ($wantedPrefix+'*')))
            } | Select-Object -First 1
        return $null -ne $d
    }catch{return $false}
}
function Wait-WindowsCameraReady([string]$DeviceId,[int]$MaxAttempts=40){
    $last=$null
    for($i=1;$i -le $MaxAttempts;$i++){
        $r=Invoke-Native $runtimeCtl @('status',$DeviceId)
        $last=$r
        if($r.ExitCode -eq 0 -or (Test-WindowsCameraPnP $DeviceId)){
            return [pscustomobject]@{Ready=$true;Result=$r}
        }
        Start-Sleep -Milliseconds 250
    }
    return [pscustomobject]@{Ready=$false;Result=$last}
}


$LogDir=Join-Path $env:ProgramData 'Kinect360Remold\logs'
$LogFile=Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:InstallTranscript=$false
$script:InstallFailed=$false

try{
    New-Item -ItemType Directory -Force $LogDir|Out-Null
    try{Start-Transcript -LiteralPath $LogFile -Force|Out-Null;$script:InstallTranscript=$true}catch{Write-Warning ("Could not start install transcript: {0}" -f $_.Exception.Message)}
    Require-Administrator 'Administrator privileges are required for driver installation.'
    if([Environment]::OSVersion.Version.Major -lt 10 -or [Environment]::OSVersion.Version.Build -lt $Product.MinimumWindowsBuild){
        throw ("Windows build {0} or newer is required." -f $Product.MinimumWindowsBuild)
    }

    $DriverPackages=@($Product.DriverPackages|ForEach-Object{Get-DriverPackage $_.Key})
    $PackagesByKey=@{}
    foreach($package in $DriverPackages){$PackagesByKey[$package.Key]=$package}
    $DevicePackage=$PackagesByKey.Device
    $MotorPackage=$PackagesByKey.Motor
    $CameraPackage=$PackagesByKey.Camera
    $AudioPackage=$PackagesByKey.Audio
    $Control1473Package=$PackagesByKey.Control1473

    $DeviceInf=$DevicePackage.Inf
    $NuiInf=$MotorPackage.Inf
    $CameraInf=$CameraPackage.Inf
    $AudioInf=$AudioPackage.Inf
    $Control1473Inf=$Control1473Package.Inf
    $DevelopmentCert=Join-Path $Root 'Kinect360RemoldDevelopment.cer'
    $Setup=Join-Path $Root 'tools\Kinect360RemoldSetup.exe'
    $NuiCtl=Join-Path $Root 'tools\Kinect360RemoldNui.exe'
    $Webcam=Join-Path $Root 'webcam'
    $WebcamCtlSource=Join-Path $Webcam 'Kinect360RemoldWebcam.exe'
    $WebcamDllSource=Join-Path $Webcam 'Kinect360RemoldCameraSource.dll'
    $CameraIpSource=Join-Path $Root 'runtime\Kinect360RemoldCameraIp.exe'
    $AudioBridgeSource=Join-Path (Split-Path -Parent $AudioInf) 'Kinect360RemoldAudioBridge.exe'
    $required=@($DevelopmentCert,$Setup,$NuiCtl,$WebcamCtlSource,$WebcamDllSource,$CameraIpSource,$AudioBridgeSource)
    foreach($package in $DriverPackages){$required+=@($package.Inf,$package.Cat)}
    foreach($path in $required){Need $path}

    Stage 'Preflight: validating development package trust...'
    Write-Host '  Driver Store rule   : third-party PnP catalogs must carry a trusted digital signature' -ForegroundColor Yellow
    Write-Host '  Package policy      : local development certificate; imported automatically for this machine' -ForegroundColor Yellow
    Write-Host '  1414 Motor/Camera   : Microsoft winusb.sys on 02B0 / 02AE' -ForegroundColor Yellow
    Write-Host '  1473 parent 02C2    : Microsoft inbox USB hub driver (NEVER WinUSB)' -ForegroundColor Yellow
    Write-Host '  1473 motor runtime  : 02BB/02C3&MI_00 -> preserve working Microsoft WinUSB; Remold fallback if needed' -ForegroundColor Yellow
    Write-Host '  Audio boot          : 02AD -> Microsoft winusb.sys -> UACFirmware 01.02.709.00 (Runtime 1.8; 1414 + 1473)' -ForegroundColor Yellow
    Write-Host '  Audio runtime       : 02BB/02C3&MI_02 -> inbox Microsoft USB Audio -> WASAPI capture endpoint' -ForegroundColor Yellow
    Write-Host '  1473 camera identity: ignore placeholder 0000000000000000 serial at bcdDevice 02.05; bind identity to USB port' -ForegroundColor Yellow
    Write-Host '  System policy       : no BCD/Secure Boot/Code Integrity changes; only targeted Kinect 1473 usbflags are managed' -ForegroundColor DarkGray
    $catalogs=@($DriverPackages|ForEach-Object{$_.Cat})
    Initialize-DevelopmentPackageTrust $DevelopmentCert $catalogs
    [void](Initialize-1473UsbIdentityAndResumePolicy)
    [void](Restore-1473InboxHubIfNeeded)

    Stage 'Preflight: staging every current PnP package...'
    foreach($package in $DriverPackages){Stage-DriverPackage $package.Inf $package.DisplayName}
    Write-Host ("  Driver Store preflight: PASS ({0}/{0})" -f $DriverPackages.Count) -ForegroundColor Green

    $Runtime=Join-Path $env:ProgramFiles $ProductName
    $RuntimeCameraIp=Join-Path $Runtime 'Kinect360RemoldCameraIp.exe'
    $runtimeDll=$null
    $runtimeCtl=$null
    $script:RuntimeAudioBridge=Join-Path $Runtime 'Kinect360RemoldAudioBridge.exe'
    $virtualCameraConfigDir=Join-Path $env:ProgramData 'Kinect360Remold'
    $virtualCameraConfig=Join-Path $virtualCameraConfigDir 'virtual-camera.ini'
    New-Item -ItemType Directory -Force $virtualCameraConfigDir|Out-Null
    # Virtual-camera consumers never control the physical Kinect mode.
    # Write the scanner policy explicitly on every install.
    [IO.File]::WriteAllText($virtualCameraConfig,"[virtual-camera]`r`nmode=stable`r`ntarget_fps=30`r`n",(New-Object Text.UTF8Encoding($false)))
    $runtimeCtl=$null

    [void](Stop-Runtime)
    Stage 'Preflight: installing persistent Kinect raw-audio runtime...'
    $script:RuntimeAudioBridge=Install-AudioBridgeRuntime $AudioBridgeSource $Runtime
    Write-Host '  AudioBridge runtime : INSTALLED independently of current 02AD/02BB/02C3 firmware state' -ForegroundColor Green
    Rescan

    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' Kinect Xbox 360 Remold - driver installation' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host 'Primary entries after installation:'
    Write-Host '  Kinect Xbox 360 -> Kinect Xbox 360 Remold'
    Write-Host ("  Cameras         -> {0}" -f $Product.WindowsCameraNamePrefix+'device-id]')
    Write-Host '  1414 Motor/Camera  -> Microsoft inbox WinUSB transport'
    Write-Host '  1473 02C2          -> Microsoft inbox USB hub (preserved)'
    Write-Host '  1473 Control       -> 02BB/02C3&MI_00 WinUSB (independent runtime LED/motor/status)'
    Write-Host '  Audio boot         -> 045E:02AD on Microsoft WinUSB'
    Write-Host '  Windows microphone -> active Kinect USB Audio/WASAPI capture endpoint'
    Write-Host '  Microphones        -> WASAPI 4-channel capture + raw AudioBridge pipe'
    Write-Host ("  IP camera          -> secure default: disabled, loopback-only ({0}:{1}); explicit LAN opt-in" -f $Product.CameraIpPolicy.Bind,$Product.CameraIpPolicy.Port)
    Write-Host ("  Raw audio pipe     -> {0} (4 x PCM S32LE for Processing)" -f ($Product.AudioPipePrefix+'<device-id>'))
    Write-Host '  Custom audio .sys  -> none'
    Write-Host ''

    Stage 'Preflight: deploying the current virtual-camera media source...'
    $virtualCameraDeployment=Install-VirtualCameraRuntime $WebcamDllSource $WebcamCtlSource $Runtime
    $runtimeDll=$virtualCameraDeployment.Dll
    $runtimeCtl=$virtualCameraDeployment.Ctl
    Write-Host ("  Virtual camera source : READY ({0})" -f (Split-Path $runtimeDll -Leaf)) -ForegroundColor Green
    Stage 'Preflight: detecting Kinect USB functions...'
    Show-UsbInventory

    Stage '[1/8] Installing the visible Kinect device and control broker (trusted development package path)...'
    # Updating a Win32 service binary through a PnP INF while the running Broker is
    # still RUNNING/STOP_PENDING makes SetupAPI return NEEDREBOOT. Enforce a
    # bounded stop immediately before the root-device transaction.
    if(!(Stop-ServiceBounded $Product.Services.Broker 5000 -ForceProcess)){
        throw 'Kinect360RemoldBroker could not be stopped even after forced process termination. Reboot Windows once before reinstalling.'
    }
    if(Try-EnsureRoot $DevicePackage.RootHardwareId $DeviceInf $DevicePackage.DisplayName){$script:State.Device='READY'}
    else{$script:State.Device='FAILED'}
    Rescan

    Stage '[2/8] Stabilizing Kinect 1414/1473 motor topology without rebinding the 1473 hub...'
    Initialize-MotorTopology

    if($script:Motor1473Required){
        Stage '[3/8] Configuring Kinect 1473 control and audio transports independently...'
        [void](Stabilize-1473RuntimeControl 1)
    }else{
        Stage '[3/8] Preparing Kinect audio transport...'
    }
    [void](Stabilize-AudioFunction)
    if($script:Motor1473Required -and !$script:Motor1473PnpReady){[void](Stabilize-1473RuntimeControl)}

    Stage '[4/8] Waiting for and stabilizing Xbox NUI Camera on Microsoft WinUSB...'
    # CameraBridge is a shared trigger-start service whose binary lives in Driver
    # Store. Stop an older running instance before the camera package is updated,
    # otherwise an in-place reinstall can keep executing the previous binary even
    # after SetupAPI stages the new package.
    [void](Stop-ServiceBounded $Product.Services.CameraBridge 5000 -ForceProcess -Quiet)
    # Camera setup is independent from 1473 LED/motor acknowledgement.
    [void](Bind-And-Stabilize $CameraPackage.HardwareId $CameraInf $CameraPackage.DisplayName 'Camera')

    Stage '[5/8] Ensuring persistent NUI Audio firmware/WASAPI runtime...'
    [void](Stabilize-AudioFunction)
    if($script:Motor1473Required -and !$script:Motor1473PnpReady){[void](Stabilize-1473RuntimeControl)}

    Stage '[6/8] Installing optional IP-camera runtime (disabled until explicitly enabled)...'
    $RuntimeCameraIp=Install-CameraIpRuntime $CameraIpSource $Runtime
    Write-Host ("Native IP camera: INSTALLED; secure default disabled + loopback-only; Private/LocalSubnet firewall is added only for explicit LAN mode") -ForegroundColor Green

    Stage '[7/8] Starting Remold runtime after physical transports are stable...'
    Rescan
    if($script:State.Motor -ne 'READY' -and !$script:MotorFatal){
        if($script:Motor1414Required -and !$script:Motor1414Ready){Initialize-MotorTopology}
        Update-MotorState
    }
    if($script:State.Camera -ne 'READY' -and $script:State.Camera -notlike 'BLOCKED-CODE*' -and (Has-HardwareId $CameraPackage.HardwareId)){
        [void](Bind-And-Stabilize $CameraPackage.HardwareId $CameraInf $CameraPackage.DisplayName 'Camera')
    }
    if($script:State.Audio -ne 'READY' -and $script:State.Audio -notlike 'BLOCKED-CODE*'){[void](Stabilize-AudioFunction)}
    if($script:Motor1473Required -and !$script:Motor1473PnpReady){[void](Stabilize-1473RuntimeControl)}
    [void](Start-Runtime)
    if(Test-Path -LiteralPath $RuntimeCameraIp -PathType Leaf){
        if(!(Test-CameraIpRuntimeEnabled)){
            $script:State.CameraIp='DISABLED'
            $ipStatus=Invoke-Native $RuntimeCameraIp @('status')
            if(!$Simple){Show-Native $ipStatus}
            Write-Host 'Native IP camera: DISABLED (secure default; enable explicitly when streaming is required)' -ForegroundColor Green
        }else{
            $ipStatus=$null
            for($ipProbe=1;$ipProbe -le 20;$ipProbe++){
                $ipStatus=Invoke-Native $RuntimeCameraIp @('status')
                if($ipStatus.ExitCode -eq 0){break}
                Start-Sleep -Milliseconds 250
            }
            if($null -ne $ipStatus -and $ipStatus.ExitCode -eq 0){
                $script:State.CameraIp='READY'
                if(!$Simple){Show-Native $ipStatus}
            }else{
                $script:State.CameraIp='PENDING'
                Note-Issue 'Native IP-camera service is enabled but did not reach RUNNING.'
            }
        }
    }

    $broker=$null
    for($i=1;$i -le 30;$i++){
        $broker=Invoke-Native $NuiCtl @('broker-status')
        if($broker.ExitCode -eq 0){break}
        Start-Sleep -Milliseconds 300
    }
    if($null -ne $broker -and $broker.ExitCode -eq 0){
        $script:State.Broker='READY'
        if(!$Simple){Show-Native $broker}
    }else{
        $script:State.Broker='PENDING'
        Note-Issue 'The control broker is not reachable.'
    }

    # Physical LED/tilt/status are runtime operations and do not gate installation.

    Stage '[8/8] Verifying one Windows virtual camera per physical Kinect...'
    try{
        if([string]::IsNullOrWhiteSpace([string]$runtimeDll) -or !(Test-Path -LiteralPath $runtimeDll -PathType Leaf)){throw 'Virtual camera source deployment is missing.'}
        if([string]::IsNullOrWhiteSpace([string]$runtimeCtl) -or !(Test-Path -LiteralPath $runtimeCtl -PathType Leaf)){throw 'Virtual camera registrar deployment is missing.'}
        $manifest=Join-Path $env:ProgramData 'Kinect360Remold\devices.tsv'
        $ids=@()
        for($attempt=0;$attempt -lt 40 -and $ids.Count -eq 0;$attempt++){
            if(Test-Path -LiteralPath $manifest -PathType Leaf){
                $ids=@(Get-Content -LiteralPath $manifest -ErrorAction SilentlyContinue|Where-Object{$_ -and !$_.StartsWith('#')}|ForEach-Object{($_ -split "`t",9)[0]}|Where-Object{$_}|Select-Object -Unique)
            }
            if($ids.Count -eq 0){Start-Sleep -Milliseconds 250}
        }
        if($ids.Count -eq 0){
            $script:State.WindowsCamera='PENDING'
            Note-Issue 'No physical Kinect identity is currently published; CameraBridge will publish its virtual camera automatically on hot-plug.'
        }else{
            $failed=New-Object System.Collections.Generic.List[string]
            foreach($id in $ids){
                $ready=Wait-WindowsCameraReady $id 40
                if(!$ready.Ready){[void]$failed.Add($id)}
            }

            # CameraBridge alone owns virtual-camera lifecycle. If an update raced
            # service/PnP startup, restart that owner once and let it reconcile the
            # complete physical set again; never create cameras from the installer.
            if($failed.Count -gt 0){
                Write-Host ("  CameraBridge reconciliation retry for: {0}" -f ($failed -join ', ')) -ForegroundColor Yellow
                [void](Stop-ServiceBounded $Product.Services.CameraBridge 5000 -ForceProcess -Quiet)
                if(Start-ServiceBounded $Product.Services.CameraBridge 7000 -Quiet){
                    $retryFailed=New-Object System.Collections.Generic.List[string]
                    foreach($id in @($failed)){
                        $ready=Wait-WindowsCameraReady $id 60
                        if(!$ready.Ready){
                            [void]$retryFailed.Add($id)
                            if(!$Simple -and $null -ne $ready.Result){Show-Native $ready.Result}
                        }
                    }
                    $failed=$retryFailed
                }
            }

            if($failed.Count -eq 0){$script:State.WindowsCamera='READY';Write-Host ("Windows virtual cameras: READY ({0}/{0}, one per Kinect; owned by CameraBridge)" -f $ids.Count) -ForegroundColor Green}
            else{
                $script:State.WindowsCamera='FAILED'
                $bridgeService=Get-Service -Name $Product.Services.CameraBridge -ErrorAction SilentlyContinue
                if($null -eq $bridgeService){Note-Issue 'CameraBridge service is not installed.'}
                elseif($bridgeService.Status -ne 'Running'){Note-Issue ("CameraBridge service state is {0}." -f $bridgeService.Status)}
                Note-Issue ("CameraBridge did not publish/verify virtual cameras for: {0}" -f ($failed -join ', '))
                Write-Host ("  Registrar runtime : {0}" -f $runtimeCtl) -ForegroundColor DarkGray
                Write-Host ("  Media source      : {0}" -f $runtimeDll) -ForegroundColor DarkGray
            }
        }
    }catch{
        $script:State.WindowsCamera='FAILED'
        Note-Issue $_.Exception.Message
    }

    if($script:State.Audio -eq 'READY'){
        for($i=$script:Issues.Count-1;$i -ge 0;$i--){
            $issue=[string]$script:Issues[$i]
            if($issue -like 'Xbox NUI Audio transport could not be bound*' -or
               $issue -like 'Xbox NUI Audio 02AD is present but has not reached a started WinUSB state yet*'){
                $script:Issues.RemoveAt($i)
            }
        }
    }

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' Installation summary' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host 'READY means the transport/runtime is configured; DISABLED is the healthy secure state for an optional service that is intentionally off.' -ForegroundColor DarkGray
    foreach($key in $script:State.Keys){Write-Host ("{0,-24}: {1}" -f $key,$script:State[$key])}
    if($script:State.Audio -eq 'PENDING'){
        $diag=Get-AudioBridgeDiagnostics
        $stage=if($diag.ContainsKey('stage')){[string]$diag.stage}else{'unknown'}
        $error=if($diag.ContainsKey('last_error')){[string]$diag.last_error}else{'unknown'}
        Write-Host ("Audio runtime status    : stage={0}; last_error={1}" -f $stage,$error) -ForegroundColor DarkYellow
        Write-Host ("Audio runtime status  : {0}" -f (Join-Path $env:ProgramData 'Kinect360Remold\audio-bridge-status.txt')) -ForegroundColor DarkGray
    }
    if($script:Motor1473Required -and $script:State.Motor -eq 'PENDING'){
        Write-Host '1473 control note       : MI_00 becomes available only after the 02AD -> 02BB/02C3 firmware transition.' -ForegroundColor DarkYellow
    }
    if($script:Issues.Count){
        Write-Host ''
        Write-Host 'Warnings:' -ForegroundColor Yellow
        foreach($issue in $script:Issues){Write-Host ("  - {0}" -f $issue) -ForegroundColor Yellow}
    }
    $failedStates=@($script:State.GetEnumerator()|Where-Object{([string]$_.Value -eq 'FAILED') -or ([string]$_.Value -like 'BLOCKED-CODE*')})
    if($failedStates.Count){
        throw ("Installation is incomplete because required components failed or were blocked by Windows: {0}" -f (($failedStates|ForEach-Object{$_.Key}) -join ', '))
    }
    Write-Host ''
    Write-Host ("{0} INSTALLATION COMPLETE" -f $ProductName) -ForegroundColor Green
    Write-Host 'No Windows restart is requested by the Remold installer.' -ForegroundColor Green
    if(!$Simple){Write-Host 'Technical utility: tools\Kinect360RemoldNui.exe status|broker-status|tilt|led'}
    [Environment]::ExitCode=0
}catch{
    $script:InstallFailed=$true
    [Environment]::ExitCode=1
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host ' INSTALLATION FAILED' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ("Log: {0}" -f $LogFile) -ForegroundColor Yellow
}finally{
    if($script:InstallTranscript){try{Stop-Transcript|Out-Null}catch{Write-Warning ("Could not stop install transcript cleanly: {0}" -f $_.Exception.Message)}}
}
if($script:InstallFailed -and !$Simple){
    Write-Host ''
    [void](Read-Host 'Press Enter to close this installer')
}
return
