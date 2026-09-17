@echo off
setlocal EnableExtensions
set "REMOLD_BUILD_PARENT=1"
set "ROOT=%~dp0"
set "REMOLD_VERSION="
if exist "%ROOT%VERSION" set /p REMOLD_VERSION=<"%ROOT%VERSION"
if not "%REMOLD_VERSION%"=="1" (echo ERROR: VERSION must be 1.& exit /b 2)
set "STUDIO=%ROOT%scripts\windows\BUILD-STUDIO.cmd"
set "TARGET=%ROOT%drivers\windows\BUILD.cmd"
set "RC=0"

title Kinect Xbox 360 Remold - BUILD
color 07

echo ============================================================
echo  Kinect Xbox 360 Remold
echo  Software version: %REMOLD_VERSION%
echo  BUILD - SynKinect Studio + Windows Driver and Runtime
echo ============================================================
echo.
echo Interactive builds keep the window open at the end.
echo.

if not exist "%STUDIO%" (
    echo ERROR: the project is incomplete. Missing:
    echo   "%STUDIO%"
    set "RC=2"
    goto :finish
)
if not exist "%TARGET%" (
    echo ERROR: the project is incomplete. Missing:
    echo   "%TARGET%"
    echo.
    echo Extract the entire ZIP to a normal folder first.
    set "RC=2"
    goto :finish
)

echo [1/2] Building self-contained SynKinect Studio...
call "%STUDIO%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto :finish

echo.
echo [2/2] Building Windows native driver/runtime...
call "%TARGET%" %*
set "RC=%ERRORLEVEL%"

:finish
echo.
echo ============================================================
if "%RC%"=="0" (
    echo  BUILD FINISHED SUCCESSFULLY
) else (
    echo  BUILD FAILED - ERROR CODE %RC%
    echo.
    echo Read the messages above. The build logs are normally in:
    echo   "%ROOT%drivers\windows\source\logs"
)
echo ============================================================
echo.
if not "%REMOLD_NO_PAUSE%"=="1" pause
exit /b %RC%
