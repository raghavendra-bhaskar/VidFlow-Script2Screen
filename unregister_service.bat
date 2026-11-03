@echo off
:: unregister_service.bat — Remove the VidFlow auto-start scheduled task.
:: Run as Administrator.
setlocal enabledelayedexpansion

net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: Run as Administrator.
    pause
    exit /b 1
)

set "TASK_NAME=VidFlow-Script2Screen"

echo Removing scheduled task: !TASK_NAME!...
schtasks /delete /tn "!TASK_NAME!" /f
if %ERRORLEVEL% equ 0 (
    echo Done. VidFlow will no longer auto-start on boot.
) else (
    echo Task not found or already removed.
)
pause
