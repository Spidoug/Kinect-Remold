@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Resolve the launcher directory to an absolute path. Never depend on %%CD%%.
for %%I in ("%~dp0.") do set "SCRIPT_DIR=%%~fI"
set "ROOT="
set "ROOT_SCAN=%SCRIPT_DIR%"
set /a ROOT_DEPTH=0

:find_root_up
call :is_project_root "%ROOT_SCAN%"
if defined ROOT goto :root_found
if %ROOT_DEPTH% GEQ 8 goto :find_root_down
for %%I in ("%ROOT_SCAN%\..") do set "ROOT_PARENT=%%~fI"
if /I "%ROOT_PARENT%"=="%ROOT_SCAN%" goto :find_root_down
set "ROOT_SCAN=%ROOT_PARENT%"
set /a ROOT_DEPTH+=1
goto :find_root_up

:find_root_down
rem Recovery for archives that introduced wrapper directories around the tree.
for /f "delims=" %%V in ('dir /b /s /a:-d "%SCRIPT_DIR%\VERSION" 2^>nul') do if not defined ROOT call :root_from_version "%%~fV"
if not defined ROOT goto :root_missing

:root_found
for %%I in ("%ROOT%.") do set "ROOT=%%~fI\"
set "DRIVER_BUILD=%ROOT%scripts\windows\BUILD-DRIVER.cmd"
set "STUDIO_BUILD=%ROOT%scripts\windows\BUILD-STUDIO.cmd"
set "STUDIO_HOME=%ROOT%binaries\windows\applications\SynKinectStudio"
set "STUDIO_EXE=%STUDIO_HOME%\SynKinectStudio.exe"
set "FORCE_BUILD=0"
set "BUILD_ONLY=0"

goto :parse_args

:is_project_root
set "CANDIDATE=%~1"
if not exist "%CANDIDATE%\VERSION" exit /b 0
if not exist "%CANDIDATE%\scripts\windows\BUILD-DRIVER.cmd" exit /b 0
if not exist "%CANDIDATE%\scripts\windows\BUILD-STUDIO.cmd" exit /b 0
if not exist "%CANDIDATE%\applications\processing\SynKinectStudio\" exit /b 0
if not exist "%CANDIDATE%\drivers\modules\" exit /b 0
set "ROOT=%CANDIDATE%"
exit /b 0

:root_from_version
for %%I in ("%~dp1.") do set "VERSION_DIR=%%~fI"
call :is_project_root "%VERSION_DIR%"
exit /b 0

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
echo Project root: "%ROOT%"
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

:root_missing
echo ============================================================
echo  Kinect Remold
echo ============================================================
echo.
echo ERROR: the Kinect Remold project root could not be located.
echo Launcher directory:
echo   "%SCRIPT_DIR%"
echo.
echo Extract the complete project before running it. Wrapper folders created
echo by repeated ZIP/7z compression are supported, but the project tree must
echo remain complete.
echo.
pause
exit /b 2

:incomplete
echo ============================================================
echo  Kinect Remold
echo ============================================================
echo.
echo ERROR: the project tree is incomplete or required build scripts are missing.
echo Project root:
echo   "%ROOT%"
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
