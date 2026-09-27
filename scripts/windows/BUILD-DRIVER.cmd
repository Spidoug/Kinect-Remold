@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "REMOLD_CALLER=%REMOLD_BUILD_PARENT%"
set "REMOLD_BUILD_PARENT=1"
set "ROOT=%~dp0\..\.."
set "MODULES=%ROOT%\drivers\modules"
set "BUILD_RC=0"
set "COUNT=0"

echo ============================================================
echo  Kinect Remold - Driver modules build
echo ============================================================
echo.
if not exist "%MODULES%\" (
    echo ERROR: driver modules directory was not found:
    echo   "%MODULES%"
    set "BUILD_RC=2"
    goto :finish
)
for /d %%D in ("%MODULES%\*") do (
    if exist "%%~fD\windows\BUILD.cmd" (
        set /a COUNT+=1
        echo [module] %%~nxD
        call "%%~fD\windows\BUILD.cmd" %*
        if errorlevel 1 (
            set "BUILD_RC=!ERRORLEVEL!"
            goto :finish
        )
    )
)
if "%COUNT%"=="0" (
    echo ERROR: no Windows driver module build entry point was found.
    set "BUILD_RC=2"
)

:finish
echo.
if not "%BUILD_RC%"=="0" echo DRIVER MODULE BUILD FAILED - error code %BUILD_RC%.
if "%BUILD_RC%"=="0" echo DRIVER MODULE BUILD FINISHED SUCCESSFULLY.
echo.
if not defined REMOLD_CALLER pause
exit /b %BUILD_RC%
