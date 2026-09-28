@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "REMOLD_CALLER=%REMOLD_BUILD_PARENT%"
set "REMOLD_BUILD_PARENT=1"
for %%I in ("%~dp0.") do set "SCRIPT_DIR=%%~fI"
set "ROOT="
set "SCAN=%SCRIPT_DIR%"
set /a DEPTH=0
:scan_root
if exist "%SCAN%\VERSION" if exist "%SCAN%\drivers\modules\" if exist "%SCAN%\scripts\windows\BUILD-DRIVER.cmd" set "ROOT=%SCAN%"
if defined ROOT goto :root_ok
if !DEPTH! GEQ 8 goto :root_fail
for %%I in ("%SCAN%\..") do set "PARENT=%%~fI"
if /I "!PARENT!"=="!SCAN!" goto :root_fail
set "SCAN=!PARENT!"
set /a DEPTH+=1
goto :scan_root
:root_ok
set "MODULES=%ROOT%\drivers\modules"
set "BUILD_RC=0"
set "COUNT=0"

echo [drivers] Building Windows driver modules...
echo Project root: "%ROOT%"
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
if "!COUNT!"=="0" (
    echo ERROR: no Windows driver module build entry point was found.
    set "BUILD_RC=2"
)
goto :finish

:root_fail
set "BUILD_RC=2"
echo ERROR: Kinect Remold project root was not found from:
echo   "%SCRIPT_DIR%"
echo The complete extracted project tree is required.

:finish
echo.
if not "%BUILD_RC%"=="0" echo DRIVER MODULE BUILD FAILED - error code %BUILD_RC%.
if "%BUILD_RC%"=="0" echo DRIVER MODULE BUILD FINISHED SUCCESSFULLY.
echo.
if not defined REMOLD_CALLER pause
exit /b %BUILD_RC%
