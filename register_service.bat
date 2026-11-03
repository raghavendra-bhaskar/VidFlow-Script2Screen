@echo off
:: register_service.bat — Register VidFlow as a Windows Task Scheduler service.
::
:: This task starts VidFlow automatically when the VM boots,
:: even if no user is logged in.  Run this script ONCE as Administrator.
::
:: Usage:
::   Right-click register_service.bat → Run as Administrator
::
:: After registration:
::   - VidFlow starts automatically on every Windows boot
::   - Manage it in Task Scheduler: taskschd.msc → Task Scheduler Library → VidFlow
::   - Use start_app.bat / stop_app.bat to manually start/stop
::   - Use unregister_service.bat to remove the task
setlocal enabledelayedexpansion

:: ── Admin check ───────────────────────────────────────────────────────────────
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: This script must be run as Administrator.
    echo        Right-click the file and choose "Run as Administrator".
    pause
    exit /b 1
)

set "TASK_NAME=VidFlow-Script2Screen"
set "APP_DIR=%~dp0"
:: Strip trailing backslash
if "!APP_DIR:~-1!"=="\" set "APP_DIR=!APP_DIR:~0,-1!"

set "PYTHON=!APP_DIR!\.venv\Scripts\python.exe"
set "SCRIPT=!APP_DIR!\app.py"

if not exist "!PYTHON!" (
    echo ERROR: .venv not found in !APP_DIR!
    echo        Run install.bat first to create the virtual environment.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  Registering VidFlow as a Windows Scheduled Task
echo ============================================================
echo.
echo  App directory : !APP_DIR!
echo  Task name     : !TASK_NAME!
echo.

:: ── Delete existing task (idempotent) ────────────────────────────────────────
schtasks /delete /tn "!TASK_NAME!" /f >nul 2>&1

:: ── Create the task ──────────────────────────────────────────────────────────
:: ONSTART  = runs at system startup (no login required)
:: HIGHEST  = highest privileges so Streamlit can bind 0.0.0.0
:: /RU SYSTEM = runs as SYSTEM account (survives logoff / no user session)
schtasks /create ^
  /tn "!TASK_NAME!" ^
  /tr "\"!PYTHON!\" -m streamlit run \"!SCRIPT!\" --server.port 8501 --server.address 0.0.0.0 --server.headless true" ^
  /sc ONSTART ^
  /ru SYSTEM ^
  /rl HIGHEST ^
  /f ^
  /sd 01/01/2020 ^
  /delay 0001:00

if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Failed to create the scheduled task.
    echo        Check the error above and ensure you are running as Administrator.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  Task registered successfully!
echo ============================================================
echo.
echo  VidFlow will now start automatically every time the VM boots.
echo.
echo  To start it RIGHT NOW without rebooting:
echo    start_app.bat
echo.
echo  To check if it is running:
echo    tasklist /fi "imagename eq python.exe"
echo.
echo  To remove the auto-start task:
echo    unregister_service.bat
echo.
echo  To manage the task manually:
echo    taskschd.msc  (Task Scheduler → Task Scheduler Library → VidFlow-Script2Screen)
echo.

:: ── Start it immediately ──────────────────────────────────────────────────────
set /p START_NOW="  Start VidFlow right now? [Y/n]: "
if "!START_NOW!"=="" set "START_NOW=Y"
if /i "!START_NOW!"=="Y" (
    echo.
    echo  Starting VidFlow...
    schtasks /run /tn "!TASK_NAME!"
    echo  VidFlow is starting in the background.
    echo  Open https://localhost:8501 in your browser (may take 10-15 seconds).
)

echo.
pause
