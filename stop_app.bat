@echo off
:: stop_app.bat — Stop a running VidFlow instance started by start_app.bat.
setlocal enabledelayedexpansion
title VidFlow — Stop

set "ROOT=%~dp0"
pushd "%ROOT%"

if not exist "vidflow.pid" (
    echo [WARN] vidflow.pid not found — attempting to kill by process name...
    taskkill /f /fi "windowtitle eq VidFlow*" >nul 2>&1
    taskkill /f /fi "imagename eq streamlit.exe" >nul 2>&1
    echo [INFO] Done.
    goto :end
)

set /p PID=<vidflow.pid

echo [INFO] Stopping VidFlow (PID %PID%)...
taskkill /pid %PID% /f >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [INFO] VidFlow stopped.
) else (
    echo [WARN] Process %PID% was not running (already stopped?).
)

del /f vidflow.pid >nul 2>&1
echo [INFO] Done.

:end
popd
