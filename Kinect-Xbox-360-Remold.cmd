@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
set "DRIVER_BUILD=%ROOT%drivers\windows\BUILD.cmd"
set "STUDIO_BUILD=%ROOT%scripts\windows\BUILD-STUDIO.cmd"
set "STUDIO_HOME=%ROOT%binaries\windows\applications\SynKinectStudio"
set "STUDIO_VBS=%STUDIO_HOME%\SynKinectStudio.vbs"
set "STUDIO_CMD=%STUDIO_HOME%\SynKinectStudio.cmd"
set "FORCE_BUILD=0"
set "BUILD_ONLY=0"

:parse_args
if "%~1"=="" goto :args_done
if /I "%~1"=="--rebuild" set "FORCE_BUILD=1"
if /I "%~1"=="--build-only" set "BUILD_ONLY=1"
shift
goto :parse_args
:args_done

set "READY=1"
for %%F in (
  "%ROOT%binaries\windows\drivers\KINECT.cmd"
  "%ROOT%binaries\windows\drivers\drivers\camera\Kinect360RemoldCameraBridge.exe"
  "%ROOT%binaries\windows\drivers\drivers\device\Kinect360RemoldBroker.exe"
  "%ROOT%binaries\windows\drivers\drivers\audio\Kinect360RemoldAudioBridge.exe"
  "%ROOT%binaries\windows\drivers\webcam\Kinect360RemoldCameraSource.dll"
  "%ROOT%binaries\windows\drivers\webcam\Kinect360RemoldWebcam.exe"
  "%ROOT%binaries\windows\drivers\runtime\Kinect360RemoldCameraIp.exe"
  "%ROOT%binaries\windows\drivers\tools\Kinect360RemoldSetup.exe"
  "%STUDIO_HOME%\SynKinectStudio.cmd"
  "%STUDIO_HOME%\SynKinectStudio.vbs"
  "%STUDIO_HOME%\lib\SynKinectStudio.jar"
  "%STUDIO_HOME%\java\bin\javaw.exe"
) do if not exist "%%~F" set "READY=0"

if "%FORCE_BUILD%"=="0" if "%READY%"=="1" if "%BUILD_ONLY%"=="1" exit /b 0
if "%FORCE_BUILD%"=="0" if "%READY%"=="1" goto :launch

if not exist "%DRIVER_BUILD%" goto :incomplete
if not exist "%STUDIO_BUILD%" goto :incomplete

title Kinect Xbox 360 Remold - Build
color 07
echo ============================================================
echo  Kinect Xbox 360 Remold
echo  Building Windows driver/runtime and SynKinect Studio
echo ============================================================
echo.
echo One or more required binaries are missing, or a rebuild was requested.
echo The complete project will be compiled now.
echo.

set "REMOLD_BUILD_PARENT=1"
call "%DRIVER_BUILD%"
if errorlevel 1 goto :build_failed

set "REMOLD_FULL_BUILD=1"
call "%STUDIO_BUILD%"
if errorlevel 1 goto :build_failed

for %%F in (
  "%ROOT%binaries\windows\drivers\KINECT.cmd"
  "%ROOT%binaries\windows\drivers\drivers\camera\Kinect360RemoldCameraBridge.exe"
  "%ROOT%binaries\windows\drivers\drivers\device\Kinect360RemoldBroker.exe"
  "%ROOT%binaries\windows\drivers\drivers\audio\Kinect360RemoldAudioBridge.exe"
  "%ROOT%binaries\windows\drivers\webcam\Kinect360RemoldCameraSource.dll"
  "%ROOT%binaries\windows\drivers\webcam\Kinect360RemoldWebcam.exe"
  "%ROOT%binaries\windows\drivers\runtime\Kinect360RemoldCameraIp.exe"
  "%ROOT%binaries\windows\drivers\tools\Kinect360RemoldSetup.exe"
  "%STUDIO_HOME%\SynKinectStudio.vbs"
  "%STUDIO_HOME%\SynKinectStudio.cmd"
  "%STUDIO_HOME%\lib\SynKinectStudio.jar"
  "%STUDIO_HOME%\java\bin\javaw.exe"
) do if not exist "%%~F" (
  echo.
  echo ERROR: build completed without required artifact:
  echo   %%~F
  goto :build_failed
)

echo.
echo Build completed successfully.
if "%BUILD_ONLY%"=="1" exit /b 0

goto :launch

:launch
if not exist "%STUDIO_CMD%" goto :incomplete
rem Prefer the windowless VBScript launcher only when its first bytes are safe for WSH.
rem If the VBS was damaged by an archive/editor, fall back to the CMD launcher instead
rem of showing a line-1 VBScript compilation error.
set "VBS_SAFE=0"
if exist "%STUDIO_VBS%" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:STUDIO_VBS; try{$b=[IO.File]::ReadAllBytes($p); if($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF){exit 2}; $t=[IO.File]::ReadAllText($p,[Text.Encoding]::ASCII); if($t.TrimStart().StartsWith('Option Explicit')){exit 0}; exit 3}catch{exit 4}" >nul 2>&1
  if not errorlevel 1 set "VBS_SAFE=1"
)
if "%VBS_SAFE%"=="1" (
  start "" wscript.exe //nologo "%STUDIO_VBS%"
  exit /b 0
)
rem Recovery path: bypass VBS recursion and launch the CMD hidden through PowerShell.
set "REMOLD_STUDIO_HIDDEN=1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -FilePath $env:STUDIO_CMD -WorkingDirectory $env:STUDIO_HOME -WindowStyle Hidden" >nul 2>&1
if errorlevel 1 (
  echo ERROR: SynKinect Studio could not be started by either launcher.
  echo   VBS: "%STUDIO_VBS%"
  echo   CMD: "%STUDIO_CMD%"
  pause
  exit /b 3
)
exit /b 0

:incomplete
echo ============================================================
echo  Kinect Xbox 360 Remold
echo ============================================================
echo.
echo ERROR: the project tree is incomplete or required build scripts are missing.
echo Extract the complete project to a normal folder and run this launcher again.
echo.
pause
exit /b 2

:build_failed
echo.
echo ============================================================
echo  BUILD FAILED
echo ============================================================
echo.
echo Review the messages above. Build logs are normally under:
echo   %TEMP%\Kinect360Remold\Build\logs
echo.
pause
exit /b 1
