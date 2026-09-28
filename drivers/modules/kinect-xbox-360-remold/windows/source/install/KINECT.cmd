@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0system\Kinect.ps1" %*
set "BUILD_RC=%ERRORLEVEL%"
if not "%BUILD_RC%"=="0" (
  echo.
  echo Kinect control panel exited with error %BUILD_RC%.
  echo This window will remain open so the error can be read.
  set /p "_REMOLD_CONTINUE=Press Enter to continue: "
)
exit /b %BUILD_RC%
