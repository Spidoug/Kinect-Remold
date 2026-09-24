[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SampleRoot,
    [Parameter(Mandatory=$true)][string]$TransportHeader,
    [Parameter(Mandatory=$true)][string]$ScannerPortHeader,
    [Parameter(Mandatory=$true)][string]$CameraControlsHeader,
    [Parameter(Mandatory=$true)][string]$CameraKsHeader,
    [Parameter(Mandatory=$true)][string]$ControlProtocolHeader,
    [Parameter(Mandatory=$true)][string]$VirtualCameraIdentityHeader,
    [Parameter(Mandatory=$true)][string]$SmartTiltHeader,
    [Parameter(Mandatory=$true)][string]$PlatformToolset,
    [Parameter(Mandatory=$true)][string]$WindowsSdkVersion,
    [Parameter(Mandatory=$true)][hashtable]$RuntimeLibraryPolicy,
    [Parameter(Mandatory=$true)][int]$StartupTiltDegrees,
    [Parameter(Mandatory=$true)][int]$TiltMinimum,
    [Parameter(Mandatory=$true)][int]$TiltMaximum,
    [Parameter(Mandatory=$true)][int]$FacePeriodMs,
    [Parameter(Mandatory=$true)][int]$TiltCommandPeriodMs,
    [Parameter(Mandatory=$true)][int]$FaceVerticalDeadZonePixels,
    [Parameter(Mandatory=$true)][double]$FaceErrorFilterAlpha,
    [Parameter(Mandatory=$true)][double]$AccelFilterAlpha,
    [Parameter(Mandatory=$true)][double]$AccelCorrectionFilterAlpha,
    [Parameter(Mandatory=$true)][int]$MinCommandDeltaDegrees,
    [Parameter(Mandatory=$true)][int]$MotorSettleToleranceDegrees,
    [Parameter(Mandatory=$true)][int]$MotorSettleMs
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\..\..\..\build\Common.ps1')
function Require([bool]$Condition,[string]$Message){ if(!$Condition){ throw $Message } }
function Write-Utf8Bom([string]$Path,[string]$Text){ [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($true))) }
Require ($TiltMinimum -le $StartupTiltDegrees -and $StartupTiltDegrees -le $TiltMaximum) 'Startup Tilt must be inside the declared physical Tilt range.'
Require ($FacePeriodMs -ge 20 -and $FacePeriodMs -le 200) 'Face period must be between 20 and 200 ms.'
Require ($TiltCommandPeriodMs -ge 60 -and $TiltCommandPeriodMs -le 500) 'Tilt command period must protect the physical motor from command flooding.'
Require ($FaceErrorFilterAlpha -gt 0 -and $FaceErrorFilterAlpha -le 1) 'Face error filter alpha must be in (0,1].'
Require ($AccelFilterAlpha -gt 0 -and $AccelFilterAlpha -le 1) 'Accelerometer filter alpha must be in (0,1].'
Require ($AccelCorrectionFilterAlpha -gt 0 -and $AccelCorrectionFilterAlpha -le 1) 'Accelerometer correction filter alpha must be in (0,1].'

$generatorH=Join-Path $SampleRoot 'SimpleFrameGenerator.h'
$generatorCpp=Join-Path $SampleRoot 'SimpleFrameGenerator.cpp'
$streamCpp=Join-Path $SampleRoot 'SimpleMediaStream.cpp'
$streamH=Join-Path $SampleRoot 'SimpleMediaStream.h'
$sourceCpp=Join-Path $SampleRoot 'SimpleMediaSource.cpp'
$vcamH=Join-Path $SampleRoot 'VirtualCameraMediaSource.h'
$activateH=Join-Path $SampleRoot 'VirtualCameraMediaSourceActivate.h'
$activateCpp=Join-Path $SampleRoot 'VirtualCameraMediaSourceActivate.cpp'
$project=Join-Path $SampleRoot 'VirtualCameraMediaSource.vcxproj'
foreach($f in @($generatorH,$generatorCpp,$streamCpp,$streamH,$sourceCpp,$vcamH,$activateH,$activateCpp,$project,$TransportHeader,$CameraControlsHeader,$CameraKsHeader,$ControlProtocolHeader,$VirtualCameraIdentityHeader,$ScannerPortHeader,$SmartTiltHeader)){
    Require (Test-Path -LiteralPath $f -PathType Leaf) "Required virtual-camera source was not found: $f"
}

# Verify the Microsoft source layout before applying the product-specific adaptation.
$stream=[IO.File]::ReadAllText($streamCpp)
Require ($stream.Contains('#include "pch.h"')) 'SimpleMediaStream include layout is incompatible.'
if($stream -notmatch '(?m)^#include "Kinect360RemoldScannerPort.h"\r?$') {
    $stream=$stream.Replace('#include "pch.h"','#include "pch.h"' + [Environment]::NewLine + '#include "Kinect360RemoldScannerPort.h"')
}
Require ($stream.Contains('const uint32_t NUM_MEDIATYPES = 2;')) 'Microsoft SimpleMediaStream source is incompatible (media-type count marker missing).'
Require ($stream.Contains('MFVideoFormat_NV12')) 'Microsoft SimpleMediaStream source is incompatible (NV12 marker missing).'
Require ($stream.Contains('MFVideoFormat_RGB32')) 'Microsoft SimpleMediaStream source is incompatible (RGB32 marker missing).'

$sourceBlock=@'
        auto queryRemoldDriverSettings = [&](const std::wstring& deviceId) -> uint32_t {
            using namespace Kinect360RemoldScannerPort;
            const std::wstring pipeName = std::wstring(kPipePrefix) + deviceId;
            HANDLE pipe = CreateFileW(pipeName.c_str(), GENERIC_READ | GENERIC_WRITE,
                0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (pipe == INVALID_HANDLE_VALUE) return 0;
            Request request{};
            request.command = Command::GetDriverSettings;
            request.streamMask = 0;
            Reply reply{};
            DWORD written = 0;
            DWORD read = 0;
            const BOOL ok = WriteFile(pipe, &request, sizeof(request), &written, nullptr) &&
                written == sizeof(request) &&
                ReadFile(pipe, &reply, sizeof(reply), &read, nullptr) &&
                read == sizeof(reply) && reply.magic == kMagic && reply.version == kVersion && reply.result == 0;
            CloseHandle(pipe);
            return ok ? (reply.acceptedMask & DriverSettingSupported) : 0u;
        };

        const bool remoldRgbHq =
            (queryRemoldDriverSettings(remoldDeviceId) & Kinect360RemoldScannerPort::DriverSettingRgbHighQuality) != 0;
        const uint32_t NUM_MEDIATYPES = remoldRgbHq ? 6u : 3u;
        wil::unique_cotaskmem_array_ptr<wil::com_ptr_nothrow<IMFMediaType>> mediaTypeList =
            wilEx::make_unique_cotaskmem_array<wil::com_ptr_nothrow<IMFMediaType>>(NUM_MEDIATYPES);

        auto addMediaType = [&](uint32_t index, const GUID& subtype, uint32_t width, uint32_t height,
                                uint32_t frameRate, uint32_t bytesPerPixelNumerator,
                                uint32_t bytesPerPixelDenominator) -> HRESULT {
            wil::com_ptr_nothrow<IMFMediaType> mediaType;
            RETURN_IF_FAILED(MFCreateMediaType(&mediaType));
            mediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
            mediaType->SetGUID(MF_MT_SUBTYPE, subtype);
            mediaType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
            mediaType->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
            MFSetAttributeSize(mediaType.get(), MF_MT_FRAME_SIZE, width, height);
            MFSetAttributeRatio(mediaType.get(), MF_MT_FRAME_RATE, frameRate, 1);
            const uint64_t bitsPerSecond = static_cast<uint64_t>(width) * height *
                bytesPerPixelNumerator * 8ull * frameRate / bytesPerPixelDenominator;
            mediaType->SetUINT32(MF_MT_AVG_BITRATE, static_cast<uint32_t>(bitsPerSecond));
            MFSetAttributeRatio(mediaType.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
            mediaTypeList[index] = mediaType.detach();
            return S_OK;
        };

        // The first media type is the stream default, so it always matches the
        // RGB mode CameraBridge is producing: RGB HQ first when enabled, VGA
        // otherwise. Every type accepts either sensor mode and scales it.
        uint32_t nextMediaType = 0;
        if (remoldRgbHq) {
            RETURN_IF_FAILED(addMediaType(nextMediaType++, MFVideoFormat_NV12, 1280, 1024, 15, 3, 2));
            RETURN_IF_FAILED(addMediaType(nextMediaType++, MFVideoFormat_YUY2, 1280, 1024, 15, 2, 1));
            RETURN_IF_FAILED(addMediaType(nextMediaType++, MFVideoFormat_RGB32, 1280, 1024, 15, 4, 1));
        }
        RETURN_IF_FAILED(addMediaType(nextMediaType++, MFVideoFormat_NV12, 640, 480, 30, 3, 2));
        RETURN_IF_FAILED(addMediaType(nextMediaType++, MFVideoFormat_YUY2, 640, 480, 30, 2, 1));
        RETURN_IF_FAILED(addMediaType(nextMediaType++, MFVideoFormat_RGB32, 640, 480, 30, 4, 1));

'@
$pattern='(?s)\s*const uint32_t NUM_MEDIATYPES = 2;.*?(?=\s*RETURN_IF_FAILED\(MFCreateAttributes\(&m_spAttributes, 10\)\);)'
$mediaTypeMatches=[regex]::Matches($stream,$pattern)
Require ($mediaTypeMatches.Count -eq 1) "Expected exactly one SimpleMediaStream media-type block, found $($mediaTypeMatches.Count)."
$stream=[regex]::Replace($stream,$pattern,"`r`n$sourceBlock",1)
Require ($stream -match 'const uint32_t NUM_MEDIATYPES = remoldRgbHq \? 6u : 3u;') 'Per-device RGB HQ media-type policy was not inserted.'
Require ($stream -match 'MFVideoFormat_YUY2') 'YUY2 media type was not inserted.'
Require ($stream -match 'MFVideoFormat_RGB32') 'RGB32 media type was not inserted.'
Write-Utf8Bom $streamCpp $stream

# Bind each media stream to the device ID supplied by its IMFVirtualCamera
# activation. The source copies the immutable ID during initialization and passes
# it directly to the stream and frame generator.
$streamHText=[IO.File]::ReadAllText($streamH)
$streamInitializeDecl='HRESULT Initialize(_In_ SimpleMediaSource* pSource, _In_ DWORD streamId, _In_ MFSampleAllocatorUsage allocatorUsage);'
Require ($streamHText.Contains($streamInitializeDecl)) 'SimpleMediaStream Initialize declaration is incompatible.'
$streamHText=$streamHText.Replace($streamInitializeDecl,'HRESULT Initialize(_In_ SimpleMediaSource* pSource, _In_ DWORD streamId, _In_ MFSampleAllocatorUsage allocatorUsage, _In_ const std::wstring& remoldDeviceId);')
$mediaTypeMember='wil::com_ptr_nothrow<IMFMediaType> m_spMediaType;'
Require ($streamHText.Contains($mediaTypeMember)) 'SimpleMediaStream media-type member is incompatible.'
$streamHText=$streamHText.Replace($mediaTypeMember,$mediaTypeMember + [Environment]::NewLine + '        std::wstring m_remoldDeviceId;')
if($streamHText -notmatch '(?m)^#include <string>\r?$') {
    $streamHText=$streamHText.Replace('#define SIMPLEMEDIASTREAM_H','#define SIMPLEMEDIASTREAM_H' + [Environment]::NewLine + [Environment]::NewLine + '#include <string>')
}
Require ($streamHText.Contains('std::wstring m_remoldDeviceId;')) 'Per-Kinect stream identity member was not inserted.'
Write-Utf8Bom $streamH $streamHText

$streamInitializePattern='(?s)(HRESULT SimpleMediaStream::Initialize\(\s*_In_ SimpleMediaSource\* pSource,\s*_In_ DWORD dwStreamId,\s*_In_ MFSampleAllocatorUsage allocatorUsage)(\s*\))'
$streamInitializeMatches=[regex]::Matches($stream,$streamInitializePattern)
Require ($streamInitializeMatches.Count -eq 1) "Expected one SimpleMediaStream Initialize definition, found $($streamInitializeMatches.Count)."
$stream=[regex]::Replace($stream,$streamInitializePattern,'$1,' + [Environment]::NewLine + '            _In_ const std::wstring& remoldDeviceId$2',1)
$allocatorMarker='m_allocatorUsage = allocatorUsage;'
Require ($stream.Contains($allocatorMarker)) 'SimpleMediaStream allocator assignment is incompatible.'
$stream=$stream.Replace($allocatorMarker,$allocatorMarker + [Environment]::NewLine + '        RETURN_HR_IF(E_INVALIDARG, remoldDeviceId.empty());' + [Environment]::NewLine + '        m_remoldDeviceId = remoldDeviceId;')

# Locate the single frame-generator initialization call by its semantic shape.
# The check remains strict: adaptation stops unless exactly one site is present.
$generatorInitPattern='(?m)^(?<indent>[ \t]*)RETURN_IF_FAILED\(m_spFrameGenerator->Initialize\((?<mediaExpr>[A-Za-z_][A-Za-z0-9_]*\.get\(\))\)\);[ \t]*\r?$'
$generatorInitMatches=[regex]::Matches($stream,$generatorInitPattern)
Require ($generatorInitMatches.Count -eq 1) "Expected exactly one SimpleMediaStream frame-generator initialization call, found $($generatorInitMatches.Count)."
$generatorInitMatch=$generatorInitMatches[0]
$generatorMediaExpr=$generatorInitMatch.Groups['mediaExpr'].Value
$boundInit=$generatorInitMatch.Groups['indent'].Value + "RETURN_IF_FAILED(m_spFrameGenerator->Initialize($generatorMediaExpr, m_remoldDeviceId));"
$stream=$stream.Substring(0,$generatorInitMatch.Index) + $boundInit + $stream.Substring($generatorInitMatch.Index + $generatorInitMatch.Length)
Require ($stream.Contains("m_spFrameGenerator->Initialize($generatorMediaExpr, m_remoldDeviceId)")) 'Per-Kinect generator initialization was not inserted.'
Write-Utf8Bom $streamCpp $stream

$source=[IO.File]::ReadAllText($sourceCpp)
Require ($source.Contains('#include "pch.h"')) 'SimpleMediaSource include layout is incompatible.'
$source=$source.Replace('#include "pch.h"', '#include "pch.h"' + [Environment]::NewLine + '#include <string>' + [Environment]::NewLine + '#include "Kinect360RemoldVirtualCameraIdentity.h"')
$sourceAttrMarker='RETURN_IF_FAILED(_CreateSourceAttributes(pAttributes));'
Require ($source.Contains($sourceAttrMarker)) 'SimpleMediaSource activation-attribute layout is incompatible.'
$deviceIdExtract=@'

        LPWSTR remoldRawDeviceId = nullptr;
        UINT32 remoldDeviceIdChars = 0;
        RETURN_IF_FAILED(m_spAttributes->GetAllocatedString(
            Kinect360RemoldVirtualCamera::kDeviceIdAttribute,
            &remoldRawDeviceId,
            &remoldDeviceIdChars));
        RETURN_HR_IF(E_INVALIDARG, remoldRawDeviceId == nullptr);
        std::wstring remoldDeviceId(remoldRawDeviceId, remoldDeviceIdChars);
        CoTaskMemFree(remoldRawDeviceId);
        RETURN_HR_IF(E_INVALIDARG, remoldDeviceId.empty());
'@
$source=$source.Replace($sourceAttrMarker,$sourceAttrMarker + $deviceIdExtract)
$streamCreateCall='RETURN_IF_FAILED(m_streamList[i]->Initialize(this, i, MFSampleAllocatorUsage_UsesProvidedAllocator));'
Require ($source.Contains($streamCreateCall)) 'SimpleMediaSource stream initialization call is incompatible.'
$source=$source.Replace($streamCreateCall,'RETURN_IF_FAILED(m_streamList[i]->Initialize(this, i, MFSampleAllocatorUsage_UsesProvidedAllocator, remoldDeviceId));')
Require ($source.Contains('Kinect360RemoldVirtualCamera::kDeviceIdAttribute')) 'Per-Kinect activation identity extraction was not inserted.'
Require ($source.Contains('MFSampleAllocatorUsage_UsesProvidedAllocator, remoldDeviceId')) 'Per-Kinect stream identity propagation was not inserted.'
Write-Utf8Bom $sourceCpp $source

$sourceDir=Split-Path -Parent $MyInvocation.MyCommand.Path
Copy-Item -LiteralPath (Join-Path $sourceDir 'SimpleFrameGenerator.h.template') -Destination $generatorH -Force
$generatorText=[IO.File]::ReadAllText((Join-Path $sourceDir 'SimpleFrameGenerator.cpp.template'))
$cameraControlsText=[IO.File]::ReadAllText($CameraControlsHeader)
$cameraKsText=[IO.File]::ReadAllText($CameraKsHeader)
foreach($pair in @(
    [pscustomobject]@{Token='__REMOLD_STARTUP_TILT__';Value=[string]$StartupTiltDegrees},
    [pscustomobject]@{Token='__REMOLD_TILT_MIN__';Value=[string]$TiltMinimum},
    [pscustomobject]@{Token='__REMOLD_TILT_MAX__';Value=[string]$TiltMaximum},
    [pscustomobject]@{Token='__REMOLD_FACE_PERIOD_MS__';Value=[string]$FacePeriodMs},
    [pscustomobject]@{Token='__REMOLD_TILT_COMMAND_PERIOD_MS__';Value=[string]$TiltCommandPeriodMs},
    [pscustomobject]@{Token='__REMOLD_FACE_VERTICAL_DEAD_ZONE_PIXELS__';Value=[string]$FaceVerticalDeadZonePixels},
    [pscustomobject]@{Token='__REMOLD_FACE_ERROR_FILTER_ALPHA__';Value=$FaceErrorFilterAlpha.ToString([Globalization.CultureInfo]::InvariantCulture)},
    [pscustomobject]@{Token='__REMOLD_ACCEL_FILTER_ALPHA__';Value=$AccelFilterAlpha.ToString([Globalization.CultureInfo]::InvariantCulture)},
    [pscustomobject]@{Token='__REMOLD_ACCEL_CORRECTION_FILTER_ALPHA__';Value=$AccelCorrectionFilterAlpha.ToString([Globalization.CultureInfo]::InvariantCulture)},
    [pscustomobject]@{Token='__REMOLD_MIN_COMMAND_DELTA_DEGREES__';Value=[string]$MinCommandDeltaDegrees},
    [pscustomobject]@{Token='__REMOLD_MOTOR_SETTLE_TOLERANCE_DEGREES__';Value=[string]$MotorSettleToleranceDegrees},
    [pscustomobject]@{Token='__REMOLD_MOTOR_SETTLE_MS__';Value=[string]$MotorSettleMs}
)){
    $generatorText=$generatorText.Replace($pair.Token,$pair.Value)
    $cameraControlsText=$cameraControlsText.Replace($pair.Token,$pair.Value)
    $cameraKsText=$cameraKsText.Replace($pair.Token,$pair.Value)
}
Require ($generatorText -notmatch '__REMOLD_[A-Z_]+__') 'Virtual-camera generator contains an unresolved product token.'
Require ($cameraControlsText -notmatch '__REMOLD_[A-Z_]+__') 'Camera-control header contains an unresolved product token.'
Require ($cameraKsText -notmatch '__REMOLD_[A-Z_]+__') 'Camera KS header contains an unresolved product token.'
Write-Utf8Bom $generatorCpp $generatorText
Write-Utf8Bom (Join-Path $SampleRoot 'Kinect360RemoldCameraControls.h') $cameraControlsText
Write-Utf8Bom (Join-Path $SampleRoot 'Kinect360RemoldCameraKs.h') $cameraKsText
Copy-Item -LiteralPath $TransportHeader -Destination (Join-Path $SampleRoot 'Kinect360RemoldFrameTransport.h') -Force
Copy-Item -LiteralPath $ScannerPortHeader -Destination (Join-Path $SampleRoot 'Kinect360RemoldScannerPort.h') -Force
Copy-Item -LiteralPath $ControlProtocolHeader -Destination (Join-Path $SampleRoot 'Kinect360RemoldControlProtocol.h') -Force
Copy-Item -LiteralPath $VirtualCameraIdentityHeader -Destination (Join-Path $SampleRoot 'Kinect360RemoldVirtualCameraIdentity.h') -Force
Copy-Item -LiteralPath $SmartTiltHeader -Destination (Join-Path $SampleRoot 'Kinect360RemoldSmartTilt.h') -Force

# Route standard PTZ and Remold smart-camera properties through the media
# source IKsControl implementation. Unknown properties continue to the
# Microsoft handler.
$source=[IO.File]::ReadAllText($sourceCpp)
Require ($source.Contains('#include "pch.h"')) 'SimpleMediaSource include layout is incompatible.'
Require ($source.Contains('#include "Kinect360RemoldVirtualCameraIdentity.h"')) 'Virtual-camera identity include disappeared before KS adaptation.'
$source=$source.Replace('#include "Kinect360RemoldVirtualCameraIdentity.h"', '#include "Kinect360RemoldVirtualCameraIdentity.h"' + [Environment]::NewLine + '#include "Kinect360RemoldCameraKs.h"')
$validationPattern='(?s)(if \(ulPropertyLength < sizeof\(KSPROPERTY\)\)\s*\{\s*return E_INVALIDARG;\s*\})'
$validationMatches=[regex]::Matches($source,$validationPattern)
Require ($validationMatches.Count -eq 1) "Expected one SimpleMediaSource KsProperty validation block, found $($validationMatches.Count)."
$dispatch=@'

        HRESULT remoldControlHr = Kinect360RemoldCameraControls::HandleKsProperty(
            pProperty, ulPropertyLength, pPropertyData, ulDataLength, pBytesReturned);
        if (remoldControlHr != HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND))
        {
            return remoldControlHr;
        }
'@
$validationMatch=$validationMatches[0]
$source=$source.Substring(0,$validationMatch.Index+$validationMatch.Length) + $dispatch + $source.Substring($validationMatch.Index+$validationMatch.Length)
Require ($source.Contains('Kinect360RemoldCameraControls::HandleKsProperty')) 'Smart camera IKsControl dispatch was not inserted.'
Write-Utf8Bom $sourceCpp $source

$oldGuid='7B89B92E-FE71-42D0-8A41-E137D06EA184'
$newGuid='D0C8E936-5A2B-4C0D-936F-281501A73691'
foreach($f in @($vcamH,$activateH)){
    $t=[IO.File]::ReadAllText($f)
    Require ($t.Contains($oldGuid)) "Virtual-camera CLSID marker is missing in $f"
    $t=$t.Replace($oldGuid,$newGuid).Replace($oldGuid.ToLowerInvariant(),$newGuid.ToLowerInvariant())
    if($f -eq $vcamH){
        $oldDefine='0x7b89b92e, 0xfe71, 0x42d0, 0x8a, 0x41, 0xe1, 0x37, 0xd0, 0x6e, 0xa1, 0x84'
        $newDefine='0xd0c8e936, 0x5a2b, 0x4c0d, 0x93, 0x6f, 0x28, 0x15, 0x01, 0xa7, 0x36, 0x91'
        Require ($t.Contains($oldDefine)) 'Virtual-camera DEFINE_GUID body is incompatible.'
        $t=$t.Replace($oldDefine,$newDefine)
        $t=$t.Replace('VIRTUALCAMERAMEDIASOURCE_FRIENDLYNAME = L"VirtualCameraMediaSource"','VIRTUALCAMERAMEDIASOURCE_FRIENDLYNAME = L"Kinect360RemoldCameraSource"')
    }
    Write-Utf8Bom $f $t
}
foreach($sourceFile in Get-ChildItem -LiteralPath $SampleRoot -Recurse -File -Include *.h,*.cpp,*.idl,*.vcxproj){
    $remaining=[IO.File]::ReadAllText($sourceFile.FullName)
    Require ($remaining -notmatch [regex]::Escape($oldGuid)) "Microsoft sample CLSID was not replaced in $($sourceFile.FullName)"
}

$proj=[IO.File]::ReadAllText($project)
$packagesConfig=Join-Path $SampleRoot 'packages.config'
if(Test-Path -LiteralPath $packagesConfig -PathType Leaf){
    $packagesText=[IO.File]::ReadAllText($packagesConfig)
    # The project consumes the platform projection shipped by the selected Windows SDK.
    $packagesText=[regex]::Replace($packagesText,'(?im)^\s*<package\s+id="Microsoft\.Windows\.CppWinRT"[^>]*/>\s*\r?\n?','')
    Require ($packagesText -notmatch 'Microsoft\.Windows\.CppWinRT') 'C++/WinRT NuGet package entry was not removed.'
    Write-Utf8Bom $packagesConfig $packagesText
}

# Use the C++/WinRT projection supplied by the selected Windows SDK. Remove
# package imports and checks from the Microsoft project before compilation.
$proj=[regex]::Replace($proj,'(?is)<Import\b[^>]*Microsoft\.Windows\.CppWinRT[^>]*/>\s*','')
$proj=[regex]::Replace($proj,'(?is)<Error\b[^>]*Microsoft\.Windows\.CppWinRT[^>]*/>\s*','')
Require ($proj -notmatch 'Microsoft\.Windows\.CppWinRT') 'C++/WinRT NuGet import/check remains in the project after rewrite.'

$proj=[regex]::Replace($proj,'(?i)<WindowsTargetPlatformVersion>[^<]+</WindowsTargetPlatformVersion>',"<WindowsTargetPlatformVersion>$WindowsSdkVersion</WindowsTargetPlatformVersion>")
$proj=[regex]::Replace($proj,'(?i)<PlatformToolset>v\d+</PlatformToolset>',"<PlatformToolset>$PlatformToolset</PlatformToolset>")

# Use only the C++/WinRT headers from the exact SDK selected by Toolchain.ps1.
# Do not include GeneratedFilesDir: mixing generated NuGet base.h with SDK projections
$projectionInclude='<AdditionalIncludeDirectories>$(RemoldSdkCppWinRTDir);%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>'
if(!$proj.Contains('$(RemoldSdkCppWinRTDir)')){
    $proj=[regex]::Replace($proj,'(?i)<ClCompile>','<ClCompile>'+$projectionInclude)
}
Require ($proj.Contains('$(RemoldSdkCppWinRTDir)')) 'Windows SDK C++/WinRT include was not inserted.'
Require ($proj -notmatch '\$\(GeneratedFilesDir\)') 'GeneratedFilesDir remains in the C++/WinRT include path.'
if($proj -notmatch '(?i)<LanguageStandard>'){
    $proj=[regex]::Replace($proj,'(?i)<ClCompile>','<ClCompile><LanguageStandard>stdcpp17</LanguageStandard>')
}else{
    $proj=[regex]::Replace($proj,'(?i)<LanguageStandard>[^<]+</LanguageStandard>','<LanguageStandard>stdcpp17</LanguageStandard>')
}
Require ($proj.Contains('<LanguageStandard>stdcpp17</LanguageStandard>')) 'C++17 language standard was not configured.'

# windows.h exposes min/max macros unless NOMINMAX is defined before pch.h.
# The Remold generator uses std::min/std::max and must remain valid with every
# supported WDK/SDK combination, so define NOMINMAX at the project level.
if($proj -notmatch '(?i)<PreprocessorDefinitions>[^<]*NOMINMAX') {
    $proj=[regex]::Replace($proj,'(?i)<ClCompile>','<ClCompile><PreprocessorDefinitions>NOMINMAX;%(PreprocessorDefinitions)</PreprocessorDefinitions>')
}
Require ($proj -match '(?i)<PreprocessorDefinitions>[^<]*NOMINMAX') 'NOMINMAX was not configured for the virtual-camera project.'

# Only WIL remains as a NuGet build dependency. Route its import/check through
# the external package root supplied by Build.ps1 so downloads stay out of the source tree.
$solutionPackagePrefix='$(SolutionDir)packages\'
$externalPackagePrefix='$(RemoldNuGetPackages)\'
$solutionPackageCount=[regex]::Matches($proj,[regex]::Escape($solutionPackagePrefix)).Count
Require ($solutionPackageCount -ge 1) "Virtual-camera WIL package reference was not found."
$proj=$proj.Replace($solutionPackagePrefix,$externalPackagePrefix)
Require ($proj -notmatch [regex]::Escape($solutionPackagePrefix)) 'SolutionDir-dependent NuGet package path remains after preparation.'
Require ($proj.Contains($externalPackagePrefix)) 'External WIL package root was not inserted.'

# Serialize shared-PDB writes with /FS and keep source/PDB paths within
# conservative Win32 limits. Anchor the activation source to the project
# directory while the build stages the Microsoft source under a short work path.
$activateCompileItem='<ClCompile Include="VirtualCameraMediaSourceActivate.cpp" />'
$activateCompileItemAnchored='<ClCompile Include="$(MSBuildThisFileDirectory)VirtualCameraMediaSourceActivate.cpp" />'
Require ($proj.Contains($activateCompileItem)) 'Virtual-camera activation-source project item is incompatible.'
$proj=$proj.Replace($activateCompileItem,$activateCompileItemAnchored)
Require ($proj.Contains($activateCompileItemAnchored)) 'Activation source was not anchored to the vcxproj directory.'
# Keep shared-PDB serialization and large C++/WinRT translation units explicit,
# but do not use RuntimeLibrary as a textual insertion anchor. Runtime policy is
# normalized semantically after all textual sample adaptations are persisted.
$fsTag='<AdditionalOptions>/FS /bigobj /await:strict %(AdditionalOptions)</AdditionalOptions>'
if($proj -notmatch '(?i)<AdditionalOptions>[^<]*/FS(?:\s|<)'){
    $compileBlocks=[regex]::Matches($proj,'(?i)<ClCompile>')
    Require ($compileBlocks.Count -gt 0) 'Virtual-camera project has no ClCompile item-definition block.'
    $proj=[regex]::Replace($proj,'(?i)<ClCompile>','<ClCompile>'+$fsTag)
}
Require ($proj -match '(?i)<AdditionalOptions>[^<]*/FS[^<]*/bigobj[^<]*/await:strict') 'MSVC C++/WinRT compile options were not inserted.'
Require ($proj -notmatch '(?i)<ClCompile Include="[\\/]VirtualCameraMediaSourceActivate\.cpp"') 'Activation source acquired a rooted path.'
Write-Utf8Bom $project $proj
Set-MsBuildRuntimeLibraryPolicy $project $RuntimeLibraryPolicy

Write-Host 'Virtual camera source preparation applied: RGB-only Windows camera -> NV12 + YUY2 + RGB32, activity-gated motor Tilt, FaceTracker RGB auto-framing and smart controls.' -ForegroundColor Green
