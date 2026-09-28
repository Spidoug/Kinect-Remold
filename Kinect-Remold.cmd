@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
set "DRIVER_BUILD=%ROOT%scripts\windows\BUILD-DRIVER.cmd"
set "STUDIO_BUILD=%ROOT%scripts\windows\BUILD-STUDIO.cmd"
set "STUDIO_HOME=%ROOT%binaries\windows\applications\SynKinectStudio"
set "STUDIO_EXE=%STUDIO_HOME%\SynKinectStudio.exe"
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
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\KINECT.cmd"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\drivers\camera\Kinect360RemoldCameraBridge.exe"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\drivers\device\Kinect360RemoldBroker.exe"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\drivers\audio\Kinect360RemoldAudioBridge.exe"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\webcam\Kinect360RemoldCameraSource.dll"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\webcam\Kinect360RemoldWebcam.exe"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\runtime\Kinect360RemoldCameraIp.exe"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\tools\Kinect360RemoldSetup.exe"
  "%STUDIO_EXE%"
  "%STUDIO_HOME%\app\SynKinectStudio.jar"
  "%STUDIO_HOME%\runtime\bin\javaw.exe"
) do if not exist "%%~F" set "READY=0"


if exist "%ROOT%drivers\modules\kinect-one-remold\windows\BUILD.cmd" (
  if not exist "%ROOT%binaries\windows\drivers\kinect-one-remold\KinectOneRemoldService.exe" set "READY=0"
  if not exist "%ROOT%binaries\windows\drivers\kinect-one-remold\KinectOneRemoldWinUSB.inf" set "READY=0"
)
if "%FORCE_BUILD%"=="0" if "%READY%"=="1" if "%BUILD_ONLY%"=="1" exit /b 0
if "%FORCE_BUILD%"=="0" if "%READY%"=="1" goto :launch

if not exist "%DRIVER_BUILD%" goto :incomplete
if not exist "%STUDIO_BUILD%" goto :incomplete

title Kinect Remold - Build
color 07
echo ============================================================
echo  Kinect Remold
echo  by Douglas Santana - @spidoug
echo ============================================================
echo.
echo Building Windows driver/runtime and SynKinect Studio
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
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\KINECT.cmd"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\drivers\camera\Kinect360RemoldCameraBridge.exe"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\drivers\device\Kinect360RemoldBroker.exe"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\drivers\audio\Kinect360RemoldAudioBridge.exe"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\webcam\Kinect360RemoldCameraSource.dll"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\webcam\Kinect360RemoldWebcam.exe"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\runtime\Kinect360RemoldCameraIp.exe"
  "%ROOT%binaries\windows\drivers\kinect-xbox-360-remold\tools\Kinect360RemoldSetup.exe"
  "%STUDIO_EXE%"
  "%STUDIO_HOME%\app\SynKinectStudio.jar"
  "%STUDIO_HOME%\runtime\bin\javaw.exe"
) do if not exist "%%~F" (
  echo.
  echo ERROR: build completed without required artifact:
  echo   %%~F
  goto :build_failed
)

if exist "%ROOT%drivers\modules\kinect-one-remold\windows\BUILD.cmd" (
  for %%F in (
    "%ROOT%binaries\windows\drivers\kinect-one-remold\KinectOneRemoldService.exe"
    "%ROOT%binaries\windows\drivers\kinect-one-remold\KinectOneRemoldWinUSB.inf"
  ) do if not exist "%%~F" (
    echo.
    echo ERROR: Kinect Remold Xbox One build completed without required artifact:
    echo   %%~F
    goto :build_failed
  )
)

echo.
echo Build completed successfully.
if "%BUILD_ONLY%"=="1" exit /b 0

:launch
if not exist "%STUDIO_EXE%" goto :incomplete
start "" /D "%STUDIO_HOME%" "%STUDIO_EXE%"
if errorlevel 1 (
  echo ERROR: SynKinect Studio could not be started:
  echo   "%STUDIO_EXE%"
  pause
  exit /b 3
)
exit /b 0

:incomplete
echo ============================================================
echo  Kinect Remold
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
echo   %LOCALAPPDATA%\Kinect Remold\Work\windows\logs
echo.
pause
exit /b 1
