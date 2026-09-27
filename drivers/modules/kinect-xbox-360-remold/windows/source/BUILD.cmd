@echo off
setlocal EnableExtensions
set "REMOLD_CALLER=%REMOLD_BUILD_PARENT%"
set "REMOLD_BUILD_PARENT=1"
set "REMOLD_ROOT=%~dp0"
set "REMOLD_PROJECT_ROOT=%REMOLD_ROOT%..\..\..\..\..\"
set "REMOLD_BUILD=%REMOLD_ROOT%build\Build.ps1"
set "REMOLD_WINDOWS_SMART_TILT=%REMOLD_ROOT%components\camera\shared\Kinect360RemoldSmartTilt.h"
set "REMOLD_LINUX_SMART_TILT=%REMOLD_PROJECT_ROOT%drivers\modules\kinect-xbox-360-remold\linux\source\include\remold\smart_tilt.hpp"
set "BUILD_RC=0"

echo ============================================================
echo  Kinect Xbox 360 Remold - Native Windows build
echo ============================================================
echo Project: "%REMOLD_ROOT%"
echo.

if not exist "%REMOLD_WINDOWS_SMART_TILT%" (
    echo ERROR: Windows Smart Tilt source was not found.
    set "BUILD_RC=2"
    goto :finish
)
if not exist "%REMOLD_LINUX_SMART_TILT%" (
    echo ERROR: Linux Smart Tilt parity source was not found.
    set "BUILD_RC=2"
    goto :finish
)
fc /b "%REMOLD_WINDOWS_SMART_TILT%" "%REMOLD_LINUX_SMART_TILT%" >nul
if errorlevel 1 (
    echo ERROR: Windows and Linux Smart Tilt implementations differ.
    echo Keep the shared control algorithm identical on both platforms before building.
    set "BUILD_RC=2"
    goto :finish
)
set "REMOLD_WINDOWS_CONTROL=%REMOLD_ROOT%components\device\shared\Kinect360RemoldControlProtocol.h"
set "REMOLD_LINUX_CONTROL=%REMOLD_PROJECT_ROOT%drivers\modules\kinect-xbox-360-remold\linux\source\sdk\Kinect360RemoldControlProtocol.hpp"
for %%F in ("%REMOLD_WINDOWS_CONTROL%" "%REMOLD_LINUX_CONTROL%") do (
    if not exist "%%~F" (
        echo ERROR: control protocol definition was not found: %%~F
        set "BUILD_RC=2"
        goto :finish
    )
    findstr /c:"0x54434D52u" "%%~F" >nul || (echo ERROR: control protocol magic mismatch: %%~F& set "BUILD_RC=2"& goto :finish)
    findstr /c:"kVersion = 1" "%%~F" >nul || (echo ERROR: control protocol version mismatch: %%~F& set "BUILD_RC=2"& goto :finish)
    findstr /c:"sizeof(Request) == 80" "%%~F" >nul || (echo ERROR: control request ABI mismatch: %%~F& set "BUILD_RC=2"& goto :finish)
    findstr /c:"sizeof(Reply) == 36" "%%~F" >nul || (echo ERROR: control reply ABI mismatch: %%~F& set "BUILD_RC=2"& goto :finish)
)

if not exist "%REMOLD_BUILD%" (
    echo ERROR: required PowerShell build script was not found:
    echo   "%REMOLD_BUILD%"
    echo.
    echo Extract the COMPLETE project folder from the ZIP first.
    echo Running BUILD.cmd from Windows Explorer's compressed-folder
    echo preview does not make the complete source tree available.
    set "BUILD_RC=2"
    goto :finish
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: Windows PowerShell ^(powershell.exe^) was not found.
    echo This build requires Windows PowerShell 5.1 or a compatible host.
    set "BUILD_RC=3"
    goto :finish
)

pushd "%REMOLD_ROOT%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: could not enter the source directory:
    echo   "%REMOLD_ROOT%"
    set "BUILD_RC=4"
    goto :finish
)

echo [preflight] Detecting/bootstrapping Visual Studio C++ + Windows SDK/WDK...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REMOLD_ROOT%build\Ensure-Toolchain.ps1"
set "BUILD_RC=%ERRORLEVEL%"
if not "%BUILD_RC%"=="0" (
    popd >nul 2>&1
    goto :finish
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REMOLD_BUILD%" %*
set "BUILD_RC=%ERRORLEVEL%"
popd >nul 2>&1

:finish
echo.
if "%BUILD_RC%"=="0" (
    echo Build complete.
    echo Open %REMOLD_PROJECT_ROOT%binaries\windows\drivers\kinect-xbox-360-remold\KINECT.cmd and choose Install / Reinstall.
) else (
    echo BUILD FAILED with error code %BUILD_RC%.
    echo See the error above and the newest file under:
    echo   "%LOCALAPPDATA%\Kinect Remold\Work\windows\logs"
)
echo.
echo This window will not close automatically.
if not defined REMOLD_CALLER pause
exit /b %BUILD_RC%
