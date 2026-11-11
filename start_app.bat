@echo off
:: start_app.bat — Start VidFlow on a Windows VM.
::
:: Usage
::   start_app.bat                  (default port 8501 with HTTPS)
::   set PORT=8080 & start_app.bat  (custom port)
::   set NO_SSL=1  & start_app.bat  (plain HTTP, for behind IIS/nginx)
::
:: Writes the exact Streamlit PID to vidflow.pid so stop_app.bat can stop its process tree.
setlocal enabledelayedexpansion
title VidFlow Text-to-Video AI

set "ROOT=%~dp0"
pushd "%ROOT%"

:: ── Load .env ───────────────────────────────────────────────────────────────
if exist ".env" (
    for /f "usebackq tokens=1* delims==" %%A in (".env") do (
        set "line=%%A"
        if not "!line:~0,1!"=="#" if not "%%B"=="" (
            set "%%A=%%B"
        )
    )
)

set "APP_PORT=%PORT%"
if "%APP_PORT%"=="" set "APP_PORT=8501"

if exist "vidflow.pid" (
    echo [WARN] vidflow.pid already exists. Run stop_app.bat first, or remove it if the process is gone.
    exit /b 1
)

set "PYTHON=%ROOT%.venv\Scripts\python.exe"
if not exist "%PYTHON%" (
    echo ERROR: .venv not found. Run install.bat first.
    exit /b 1
)

:: ── Step 1: TLS Certificate ─────────────────────────────────────────────────
if "%NO_SSL%"=="1" (
    echo [INFO] NO_SSL=1 — skipping certificate; running plain HTTP.
) else (
    if not exist "cert.pem" (
        echo [INFO] Generating TLS certificate...
        "%PYTHON%" gen_cert.py
        if %ERRORLEVEL% neq 0 (
            echo [WARN] Certificate generation failed. App will run on HTTP.
        )
    ) else (
        echo [INFO] cert.pem already present — skipping cert generation.
    )
)

:: ── Step 2: Start Streamlit in background ───────────────────────────────────
echo [INFO] Starting VidFlow on port %APP_PORT%...
powershell -NoProfile -Command "$p=Start-Process -FilePath '%PYTHON%' -ArgumentList '-m streamlit run app.py --server.port %APP_PORT% --server.address 0.0.0.0 --server.headless true' -WorkingDirectory '%ROOT%' -WindowStyle Hidden -PassThru; $p.Id | Set-Content -Encoding ascii '%ROOT%vidflow.pid'"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to start VidFlow. Check Python and port %APP_PORT%.
    exit /b 1
)

echo [INFO] VidFlow started.
echo [INFO] PID written to vidflow.pid — run stop_app.bat to stop.
echo.
if "%NO_SSL%"=="1" (
    echo   URL: http://localhost:%APP_PORT%
) else (
    echo   URL: https://localhost:%APP_PORT%
    echo   Accept the self-signed certificate warning on first visit.
)
echo.
echo   Internal API server also starts on port %VIDFLOW_INTERNAL_PORT%
if "%VIDFLOW_INTERNAL_PORT%"=="" echo   (default 8502)
echo   Browser API URL: %VIDFLOW_INTERNAL_BASE_URL%
if "%VIDFLOW_INTERNAL_BASE_URL%"=="" echo   (default http://localhost:8502; use a reverse-proxy URL for remote browsers)
echo   Ollama URL: %OLLAMA_BASE_URL%
if "%OLLAMA_BASE_URL%"=="" echo   (default http://localhost:11434; use a reachable VM URL in containers)
echo.
popd
