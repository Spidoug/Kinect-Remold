@echo off
setlocal EnableExtensions
set "ROOT=%~dp0"
set "SCRIPT=%ROOT%Build-Studio.ps1"
set "BUILD_RC=0"

echo ============================================================
echo  SynKinect Studio - BUILD
echo ============================================================
echo.
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
:finish
echo.
if "%BUILD_RC%"=="0" (echo STUDIO BUILD FINISHED SUCCESSFULLY.) else (echo STUDIO BUILD FAILED - error code %BUILD_RC%.)
if not defined REMOLD_BUILD_PARENT (
  echo This window will not close automatically.
  echo.
  pause
)
exit /b %BUILD_RC%
