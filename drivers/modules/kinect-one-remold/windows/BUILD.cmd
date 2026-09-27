@echo off
echo ============================================================
echo  Kinect One Remold - Windows build launcher
echo ============================================================
echo.
setlocal EnableExtensions DisableDelayedExpansion
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0source\Build.ps1" %*
set "BUILD_RC=%ERRORLEVEL%"
if not "%BUILD_RC%"=="0" (
  echo.
  echo ERROR: kinect-one-remold build failed with exit code %BUILD_RC%.
)
exit /b %BUILD_RC%
