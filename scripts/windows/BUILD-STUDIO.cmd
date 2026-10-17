@echo off
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0.") do set "SCRIPT_DIR=%%~fI"
set "ROOT="
set "SCAN=%SCRIPT_DIR%"
set /a DEPTH=0
:scan_root
if exist "%SCAN%\VERSION" if exist "%SCAN%\applications\processing\SynKinectStudio\" if exist "%SCAN%\scripts\windows\Build-Studio.ps1" set "ROOT=%SCAN%"
if defined ROOT goto :root_ok
if %DEPTH% GEQ 8 goto :root_fail
for %%I in ("%SCAN%\..") do set "PARENT=%%~fI"
if /I "%PARENT%"=="%SCAN%" goto :root_fail
set "SCAN=%PARENT%"
set /a DEPTH+=1
goto :scan_root
:root_ok
set "SCRIPT=%ROOT%\scripts\windows\Build-Studio.ps1"
set "BUILD_RC=0"

echo ============================================================
echo  SynKinect Studio - BUILD
echo ============================================================
echo.
echo Project root: "%ROOT%"
if not exist "%SCRIPT%" (
    echo ERROR: build script not found:
    echo   "%SCRIPT%"
    set "BUILD_RC=2"
    goto :finish
)
where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: powershell.exe was not found.
    set "BUILD_RC=3"
    goto :finish
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "BUILD_RC=%ERRORLEVEL%"
goto :finish

:root_fail
set "BUILD_RC=2"
echo ERROR: Kinect Remold project root was not found from:
echo   "%SCRIPT_DIR%"

:finish
echo.
if "%BUILD_RC%"=="0" (echo STUDIO BUILD FINISHED SUCCESSFULLY.) else (echo STUDIO BUILD FAILED - error code %BUILD_RC%.)
if not defined REMOLD_BUILD_PARENT (
  echo This window will not close automatically.
  echo.
  pause
)
exit /b %BUILD_RC%
