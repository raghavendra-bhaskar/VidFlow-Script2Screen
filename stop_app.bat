@echo off
:: stop_app.bat — Stop a running VidFlow instance started by start_app.bat.
setlocal enabledelayedexpansion
title VidFlow — Stop

set "ROOT=%~dp0"
pushd "%ROOT%"

if not exist "vidflow.pid" (
    echo [WARN] vidflow.pid not found — no process was stopped to avoid affecting other Python apps.
    goto :end
)

set /p PID=<vidflow.pid
echo %PID% | findstr /r "^[0-9][0-9]*$" >nul
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Invalid PID in vidflow.pid. Check it manually before removing the file.
    goto :end
)

echo [INFO] Stopping VidFlow (PID %PID%)...
taskkill /pid %PID% /t /f >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [INFO] VidFlow stopped.
) else (
    echo [WARN] Process %PID% was not running (already stopped?).
)

del /f vidflow.pid >nul 2>&1
echo [INFO] Done.

:end
popd
