@echo off
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "SCRIPT=%ROOT%\source\Build.ps1"
set "BUILD_RC=0"

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
if not "%BUILD_RC%"=="0" (
  echo.
  echo ERROR: kinect-one-remold build failed with exit code %BUILD_RC%.
)
exit /b %BUILD_RC%
