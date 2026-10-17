@echo off
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0.") do set "SCRIPT_DIR=%%~fI"
set "SCRIPT=%SCRIPT_DIR%\Package-Application.ps1"
if not exist "%SCRIPT%" (
  echo ERROR: Package-Application.ps1 was not found next to this launcher.
  echo   "%SCRIPT%"
  pause
  exit /b 2
)
where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo ERROR: powershell.exe was not found.
  pause
  exit /b 3
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "BUILD_RC=%ERRORLEVEL%"
exit /b %BUILD_RC%
