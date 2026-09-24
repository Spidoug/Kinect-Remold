[CmdletBinding()]
param(
    [ValidateSet('Release')][string]$Configuration='Release',
    [string]$LogPath='',
    [string]$SigningThumbprint=''
)
$ErrorActionPreference='Stop'
$Root=$PSScriptRoot
$ProjectRoot=Split-Path -Parent (Split-Path -Parent $Root)
$Product=Import-PowerShellDataFile (Join-Path $ProjectRoot 'build\Product.psd1')
$CameraDriverSpec=$Product.DriverPackages|Where-Object{$_.Key -eq 'Camera'}|Select-Object -First 1
if(!$CameraDriverSpec){throw 'Camera driver package definition is missing from Product.psd1.'}
. (Join-Path $ProjectRoot 'build\Common.ps1')

$Work=Join-Path (Get-RemoldExternalWorkRoot) 'driver\camera'
$Dist=Join-Path $Work 'stage'
$Cache=Join-Path (Get-RemoldExternalCacheRoot) 'driver\camera'
$NuGetCache=Join-Path $Cache 'nuget'

if([string]::IsNullOrWhiteSpace($LogPath)){ $LogPath=Get-DefaultLogPath $Root }
New-Item -ItemType Directory -Force (Split-Path -Parent $LogPath) | Out-Null
$failed=$false; $failure=''; $transcript=$false
try {
    Start-Transcript -LiteralPath $LogPath -Force | Out-Null; $transcript=$true
    Write-Host "Build log: $LogPath" -ForegroundColor Yellow
    Write-BuildStage 'Cleaning generated outputs...'; Remove-NativeBuildOutputs $Root @($Dist,$Work)
    Write-BuildStage 'Detecting Visual Studio and WDK toolchain...'
    $Tools=& (Join-Path $ProjectRoot 'build\Toolchain.ps1')
    $developmentCert=Get-OrCreateDevelopmentCertificate $Product $SigningThumbprint
    $CameraPackage=Join-Path $Dist 'camera'
    $WebcamPackage=Join-Path $Dist 'webcam'
    $RuntimePackage=Join-Path $Dist 'runtime'
    New-Item -ItemType Directory -Force $CameraPackage,$WebcamPackage,$RuntimePackage,$Work,$Cache,$NuGetCache | Out-Null

    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (' {0} - camera' -f $Product.Name) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host 'Targets:'
    Write-Host ('  Xbox NUI Camera : {0} -> Microsoft WinUSB' -f $CameraDriverSpec.HardwareId)
    Write-Host '  Virtual Camera   : RGB; FaceTracker + accelerometer + Tilt only while frames are consumed'
    Write-Host '  Scanner port     : per-device raw VGA/HQ Bayer / packed IR10 / packed Depth11; Studio converts in user-space'
    Write-Host '  Native IP camera : HTTP/MJPEG service over the shared RGB runtime transport'
    Write-Host '  Transport        : Global\Kinect360RemoldFrame-<device-id>, double buffered/seqlock'
    Write-Host ''

    # 1. Physical camera bridge + inbox WinUSB package.
    Write-BuildStage '[1/4] Building camera USB bridge...'
    $bridgeProj=Join-Path $Root 'source\bridge\Kinect360RemoldCameraBridge.vcxproj'
    $bridgeOut=Join-Path $Work 'native\camera-bridge\out';$bridgeInt=Join-Path $Work 'native\camera-bridge\obj';New-Item -ItemType Directory -Force $bridgeOut,$bridgeInt|Out-Null
    & $Tools.MSBuild $bridgeProj /m /t:Rebuild /p:Configuration=$Configuration /p:Platform=x64 /p:RemoldPlatformToolset=$($Tools.PlatformToolset) /p:PlatformToolset=$($Tools.PlatformToolset) /p:WindowsTargetPlatformVersion=$($Tools.WdkVersion) "/p:OutDir=$bridgeOut\" "/p:IntDir=$bridgeInt\"
    if($LASTEXITCODE){ throw 'Kinect360RemoldCameraBridge build failed.' }
    $bridge=Get-ChildItem -LiteralPath $bridgeOut -Recurse -File -Filter Kinect360RemoldCameraBridge.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if(!$bridge){ throw 'Kinect360RemoldCameraBridge.exe not found after build.' }
    Assert-NoExternalVcRuntime $bridge.FullName $Tools
    Copy-Item -LiteralPath $bridge.FullName -Destination (Join-Path $CameraPackage 'Kinect360RemoldCameraBridge.exe') -Force
    Stage-Inf (Join-Path $Root 'driver\Kinect360RemoldCamera.inf') (Join-Path $CameraPackage 'Kinect360RemoldCamera.inf') $Product
    Build-PackageCatalog $CameraPackage 'Kinect360RemoldCamera.inf' $Tools $Product.Inf2CatOs $Product.DriverTargetPlatform
    Write-Host 'Physical camera USB + bridge service: PASS' -ForegroundColor Green

    # 2. Native password-protected IP-camera runtime. It is deliberately user-mode
    # and consumes the CameraBridge shared transport instead of opening USB/ScannerPort.
    Write-BuildStage '[2/4] Building native IP-camera runtime service...'
    $ipProj=Join-Path $Root 'source\ip-camera\Kinect360RemoldCameraIp.vcxproj'
    $ipOut=Join-Path $Work 'native\ip-camera\out';$ipInt=Join-Path $Work 'native\ip-camera\obj';New-Item -ItemType Directory -Force $ipOut,$ipInt|Out-Null
    & $Tools.MSBuild $ipProj /m /t:Rebuild /p:Configuration=$Configuration /p:Platform=x64 /p:RemoldPlatformToolset=$($Tools.PlatformToolset) /p:PlatformToolset=$($Tools.PlatformToolset) /p:WindowsTargetPlatformVersion=$($Tools.WdkVersion) "/p:OutDir=$ipOut\" "/p:IntDir=$ipInt\"
    if($LASTEXITCODE){ throw 'Kinect360RemoldCameraIp build failed.' }
    $ipExe=Get-ChildItem -LiteralPath $ipOut -Recurse -File -Filter Kinect360RemoldCameraIp.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if(!$ipExe){ throw 'Kinect360RemoldCameraIp.exe not found after build.' }
    Assert-NoExternalVcRuntime $ipExe.FullName $Tools
    Copy-Item -LiteralPath $ipExe.FullName -Destination (Join-Path $RuntimePackage 'Kinect360RemoldCameraIp.exe') -Force
    Write-Host 'Native IP-camera runtime service: PASS' -ForegroundColor Green

    # 3. Registrar/control tool using MFCreateVirtualCamera.
    Write-BuildStage '[3/4] Building Windows virtual-camera registrar...'
    $ctlProj=Join-Path $Root 'source\webcam\Kinect360RemoldWebcam.vcxproj'
    $ctlOut=Join-Path $Work 'native\webcam-tool\out';$ctlInt=Join-Path $Work 'native\webcam-tool\obj';New-Item -ItemType Directory -Force $ctlOut,$ctlInt|Out-Null
    & $Tools.MSBuild $ctlProj /m /t:Rebuild /p:Configuration=$Configuration /p:Platform=x64 /p:RemoldPlatformToolset=$($Tools.PlatformToolset) /p:PlatformToolset=$($Tools.PlatformToolset) /p:WindowsTargetPlatformVersion=$($Tools.WdkVersion) "/p:OutDir=$ctlOut\" "/p:IntDir=$ctlInt\"
    if($LASTEXITCODE){ throw 'Kinect360RemoldWebcam build failed.' }
    $ctl=Get-ChildItem -LiteralPath $ctlOut -Recurse -File -Filter Kinect360RemoldWebcam.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if(!$ctl){ throw 'Kinect360RemoldWebcam.exe not found after build.' }
    Assert-NoExternalVcRuntime $ctl.FullName $Tools
    Copy-Item -LiteralPath $ctl.FullName -Destination (Join-Path $WebcamPackage 'Kinect360RemoldWebcam.exe') -Force
    Write-Host 'Virtual-camera registrar: PASS' -ForegroundColor Green

    # 4. Microsoft Windows-Camera source -> shared-memory Kinect media source.
    Write-BuildStage '[4/4] Building Microsoft Media Foundation virtual-camera source...'
    $cameraDependency=Get-PinnedDependency $Product 'WindowsCamera'
    $sampleRef=[string]$cameraDependency.Commit
    $sampleUrls=@(Get-PinnedDependencyArchiveUrls $Product 'WindowsCamera')
    $archive=Join-Path $Cache "Windows-Camera-$sampleRef.zip"
    $extract=Join-Path $Work 'x'
    $shortTree=Join-Path $Work 'wc'
    Write-BuildStage 'Ensuring Microsoft Windows-Camera source archive is available...'
    Invoke-ResilientDownload $sampleUrls $archive -ZipArchive
    try { Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force }
    catch { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue; throw "Could not extract '$archive'. The cached ZIP was removed; rerun Kinect-Xbox-360-Remold.cmd --rebuild. $($_.Exception.Message)" }
    $top=Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if(!$top){ throw 'Microsoft Windows-Camera archive did not contain a root directory.' }

    # Keep the Microsoft source in a short path for MSVC path safety.
    Move-Item -LiteralPath $top.FullName -Destination $shortTree
    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    $virtualRoot=Join-Path $shortTree 'Samples\VirtualCamera'
    $sample=Join-Path $virtualRoot 'VirtualCameraMediaSource'
    $solution=Join-Path $virtualRoot 'VirtualCameraSample.sln'
    $vcamProj=Join-Path $sample 'VirtualCameraMediaSource.vcxproj'
    Require-File $solution 'Microsoft VirtualCameraSample.sln'
    Require-File $vcamProj 'Microsoft VirtualCameraMediaSource.vcxproj'
    $activateCpp=Join-Path $sample 'VirtualCameraMediaSourceActivate.cpp'
    Require-File $activateCpp 'Microsoft VirtualCameraMediaSourceActivate.cpp'
    # Guard the longest source and PDB paths before invoking MSVC.
    $pdbPathProbe=Join-Path $sample 'VirtualC.5C0C46DA\x64\Release\vc145.pdb'
    $longestProbe=[Math]::Max($activateCpp.Length,$pdbPathProbe.Length)
    if($longestProbe -ge 240){
        throw "Virtual-camera staging path is too long for MSVC path safety (source=$($activateCpp.Length), pdb=$($pdbPathProbe.Length)): $sample"
    }
    Write-Host "Virtual-camera short staging path: PASS (source=$($activateCpp.Length), pdb=$($pdbPathProbe.Length))" -ForegroundColor Green

    & (Join-Path $Root 'source\virtual-camera\Prepare-VirtualCamera.ps1') -SampleRoot $sample `
        -TransportHeader (Join-Path $Root 'shared\Kinect360RemoldFrameTransport.h') `
        -ScannerPortHeader (Join-Path $Root 'shared\Kinect360RemoldScannerPort.h') `
        -CameraControlsHeader (Join-Path $Root 'shared\Kinect360RemoldCameraControls.h.template') `
        -CameraKsHeader (Join-Path $Root 'shared\Kinect360RemoldCameraKs.h.template') `
        -ControlProtocolHeader (Join-Path $ProjectRoot 'components\device\shared\Kinect360RemoldControlProtocol.h') `
        -VirtualCameraIdentityHeader (Join-Path $Root 'shared\Kinect360RemoldVirtualCameraIdentity.h') `
        -SmartTiltHeader (Join-Path $Root 'shared\Kinect360RemoldSmartTilt.h') `
        -PlatformToolset $Tools.PlatformToolset -WindowsSdkVersion $Tools.WdkVersion `
        -RuntimeLibraryPolicy $Product.UserModeRuntimeLibraryPolicy `
        -StartupTiltDegrees $Product.StartupTiltDegrees -TiltMinimum $Product.TiltMinDegrees -TiltMaximum $Product.TiltMaxDegrees `
        -FacePeriodMs $Product.SmartTiltPolicy.FacePeriodMs `
        -TiltCommandPeriodMs $Product.SmartTiltPolicy.CommandPeriodMs -FaceVerticalDeadZonePixels $Product.SmartTiltPolicy.FaceVerticalDeadZonePixels `
        -FaceErrorFilterAlpha $Product.SmartTiltPolicy.FaceErrorFilterAlpha -AccelFilterAlpha $Product.SmartTiltPolicy.AccelFilterAlpha `
        -AccelCorrectionFilterAlpha $Product.SmartTiltPolicy.AccelCorrectionFilterAlpha -MinCommandDeltaDegrees $Product.SmartTiltPolicy.MinCommandDeltaDegrees `
        -MotorSettleToleranceDegrees $Product.SmartTiltPolicy.MotorSettleToleranceDegrees -MotorSettleMs $Product.SmartTiltPolicy.MotorSettleMs

    # Keep the MSVC build deterministic: serialize shared-PDB access and reject a rooted
    # /VirtualCameraMediaSourceActivate.cpp item.
    $adaptedProjectText=[IO.File]::ReadAllText($vcamProj)
    if($adaptedProjectText -notmatch '(?i)<AdditionalOptions>[^<]*/FS(?:\s|<)'){
        throw 'Virtual-camera project is missing /FS for shared-PDB serialization.'
    }
    $anchoredActivate='<ClCompile Include="$(MSBuildThisFileDirectory)VirtualCameraMediaSourceActivate.cpp" />'
    if(!$adaptedProjectText.Contains($anchoredActivate)){
        throw 'Virtual-camera activation source is not anchored to MSBuildThisFileDirectory.'
    }
    if($adaptedProjectText -match '(?i)<ClCompile Include="[\\/]VirtualCameraMediaSourceActivate\.cpp"'){
        throw 'Virtual-camera activation source is incorrectly rooted.'
    }
    Write-Host 'Virtual-camera project hardening validation: PASS' -ForegroundColor Green

    Write-BuildStage 'Restoring WIL dependency for the Microsoft virtual-camera source...'
    # Restore only the media-source project.  A forward slash is intentionally used
    # as the final SolutionDir separator: a native Windows command-line argument that
    # ends in a backslash can consume the closing quote when the path contains spaces.
    # SolutionDir is supplied only for NuGet restore; package imports use RemoldNuGetPackages.
    $solutionDirForMsBuild=$virtualRoot.TrimEnd('\','/') + '/'
    & $Tools.MSBuild $vcamProj /t:Restore /p:RestorePackagesConfig=true /p:RestoreIgnoreFailedSources=false "/p:SolutionDir=$solutionDirForMsBuild" "/p:RestorePackagesPath=$NuGetCache" "/p:RestoreRepositoryPath=$NuGetCache" "/p:RemoldNuGetPackages=$NuGetCache"
    if($LASTEXITCODE){ throw 'NuGet/package restore for Microsoft VirtualCamera media-source project failed.' }

    $packagesConfig=Join-Path $sample 'packages.config'
    Require-File $packagesConfig 'Prepared virtual-camera packages.config'
    [xml]$packagesXml=[IO.File]::ReadAllText($packagesConfig)
    $wilPackages=@($packagesXml.packages.package | Where-Object { [string]$_.id -eq 'Microsoft.Windows.ImplementationLibrary' })
    if($wilPackages.Count -ne 1){throw "Expected exactly one WIL package in packages.config, found $($wilPackages.Count)."}
    $wilVersion=[string]$wilPackages[0].version
    if([string]::IsNullOrWhiteSpace($wilVersion)){throw 'WIL package version is empty in packages.config.'}
    $wilTargets=Join-Path $NuGetCache ("Microsoft.Windows.ImplementationLibrary.{0}\build\native\Microsoft.Windows.ImplementationLibrary.targets" -f $wilVersion)
    Require-File $wilTargets 'Restored WIL build asset'

    $sdkCppWinRTDir=$null
    foreach($kitsRoot in @($Tools.KitsRoots)){
        if([string]::IsNullOrWhiteSpace($kitsRoot)){continue}
        $candidate=Join-Path $kitsRoot ("Include\{0}\cppwinrt" -f $Tools.WdkVersion)
        if(Test-Path -LiteralPath (Join-Path $candidate 'winrt\base.h') -PathType Leaf){$sdkCppWinRTDir=$candidate;break}
    }
    if(!$sdkCppWinRTDir){throw "C++/WinRT headers for Windows SDK $($Tools.WdkVersion) were not found."}
    Require-File (Join-Path $sdkCppWinRTDir 'winrt\base.h') 'Windows SDK C++/WinRT base header'
    Require-File (Join-Path $sdkCppWinRTDir 'winrt\Windows.ApplicationModel.h') 'Windows SDK C++/WinRT Windows.ApplicationModel header'
    Write-Host "Windows SDK C++/WinRT projection: PASS ($sdkCppWinRTDir)" -ForegroundColor Green

    Write-BuildStage 'Compiling Kinect virtual camera media source DLL...'
    & $Tools.MSBuild $vcamProj /m /t:Rebuild /p:Configuration=$Configuration /p:Platform=x64 /p:PlatformToolset=$($Tools.PlatformToolset) /p:WindowsTargetPlatformVersion=$($Tools.WdkVersion) "/p:RemoldSdkCppWinRTDir=$sdkCppWinRTDir" "/p:RemoldNuGetPackages=$NuGetCache"
    if($LASTEXITCODE){ throw 'VirtualCameraMediaSource build failed.' }
    $dll=Get-ChildItem -LiteralPath $sample -Recurse -File -Filter VirtualCameraMediaSource.dll | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if(!$dll){ throw 'VirtualCameraMediaSource.dll not found after build.' }
    Assert-NoExternalVcRuntime $dll.FullName $Tools
    $exports=@(& $Tools.DumpBin /nologo /exports $dll.FullName 2>&1) -join "`n"
    if($LASTEXITCODE -or $exports -notmatch '(?im)\bDllGetClassObject\b'){ throw 'Virtual camera DLL does not export DllGetClassObject.' }
    Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $WebcamPackage 'Kinect360RemoldCameraSource.dll') -Force
    Write-Host 'Media Foundation virtual camera source: PASS' -ForegroundColor Green

    # Deterministic final package gate.
    $expected=@(
        [pscustomobject]@{Path=$CameraPackage;Files=@('Kinect360RemoldCamera.inf','Kinect360RemoldCamera.cat','Kinect360RemoldCameraBridge.exe')},
        [pscustomobject]@{Path=$WebcamPackage;Files=@('Kinect360RemoldCameraSource.dll','Kinect360RemoldWebcam.exe')},
        [pscustomobject]@{Path=$RuntimePackage;Files=@('Kinect360RemoldCameraIp.exe')}
    )
    foreach($packageSpec in $expected){Assert-PackageContents $packageSpec.Path $packageSpec.Files}

    Write-Host ''
    Write-Host 'BUILD COMPLETE' -ForegroundColor Green
    Write-Host "Output: $Dist" -ForegroundColor Green
    Write-Host 'Camera module complete; the master build creates the installer.'
    Write-Host 'This build does not disable Secure Boot or Windows signature enforcement.' -ForegroundColor Yellow
}
catch {
    $failed=$true; $failure=$_.Exception.Message
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host 'BUILD FAILED' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host "Error: $failure" -ForegroundColor Red
    if($_.InvocationInfo -and $_.InvocationInfo.PositionMessage){ Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkYellow }
    if($_.ScriptStackTrace){ Write-Host 'PowerShell stack:' -ForegroundColor DarkYellow; Write-Host $_.ScriptStackTrace -ForegroundColor DarkYellow }
    Write-Host "Full log: $LogPath" -ForegroundColor Yellow
}
finally { if($transcript){ try { Stop-Transcript | Out-Null } catch { Write-Warning ("Could not stop build transcript cleanly: {0}" -f $_.Exception.Message) } } }
if($failed){ exit 1 }
exit 0
