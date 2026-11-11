@echo off
setlocal
title VidFlow - Uninstaller
pushd "%~dp0"

echo.
echo ============================================================
echo  VidFlow - Script2Screen ^| Windows Uninstaller
echo ============================================================
echo.
echo   1) VM install only
echo   2) Kubernetes namespace only
echo   3) Both
set /p CHOICE="Choose [1/2/3, default 1]: "
if "%CHOICE%"=="" set "CHOICE=1"
if not "%CHOICE%"=="1" if not "%CHOICE%"=="2" if not "%CHOICE%"=="3" (
    echo ERROR: Enter 1, 2, or 3.
    goto :end
)

if "%CHOICE%"=="2" call :k8s
if "%CHOICE%"=="2" goto :end
if "%CHOICE%"=="3" call :k8s
if "%CHOICE%"=="1" call :vm
if "%CHOICE%"=="3" call :vm
goto :end

:k8s
where kubectl >nul 2>&1
if errorlevel 1 (
    echo [WARN] kubectl not found; Kubernetes cleanup skipped.
    exit /b
)
set /p K8S_NS="Kubernetes namespace [vidflow]: "
if "%K8S_NS%"=="" set "K8S_NS=vidflow"
echo WARNING: deleting namespace "%K8S_NS%" removes all resources in that namespace.
choice /c YN /n /m "Delete this namespace? [Y/N] "
if errorlevel 2 goto :eof
kubectl delete namespace "%K8S_NS%" --wait=true
exit /b

:vm
echo.
echo [VM] Stopping the VidFlow instance tracked by vidflow.pid...
call stop_app.bat

choice /c YN /n /m "Remove .venv and installed Python packages? [Y/N] "
if errorlevel 1 if not errorlevel 2 rmdir /s /q ".venv"

choice /c YN /n /m "Remove cert.pem and key.pem? [Y/N] "
if errorlevel 1 if not errorlevel 2 del /q cert.pem key.pem 2>nul

choice /c YN /n /m "Remove .env (may contain API keys)? [Y/N] "
if errorlevel 1 if not errorlevel 2 del /q .env 2>nul

echo This removes generated media and uploaded videos from the project directories.
choice /c YN /n /m "Remove all project media? [Y/N] "
if errorlevel 1 if not errorlevel 2 (
    for %%D in (audio audio_edits voice_library screen_recordings trimmed_videos merged_videos video_webcam_overlay uploads "video+narrated") do (
        if exist "%%~D" rmdir /s /q "%%~D"
    )
)
exit /b

:end
echo.
echo VidFlow uninstall finished. Ollama and its downloaded models were not removed.
echo To remove source code, delete this project directory manually.
popd
pause
exit /b