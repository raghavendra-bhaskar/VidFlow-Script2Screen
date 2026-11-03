@echo off
:: start_app.bat — Start VidFlow on a Windows VM.
::
:: Usage
::   start_app.bat                  (default port 8501 with HTTPS)
::   set PORT=8080 & start_app.bat  (custom port)
::   set NO_SSL=1  & start_app.bat  (plain HTTP, for behind IIS/nginx)
::
:: Writes PID to vidflow.pid so stop_app.bat can cleanly kill it.
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

start "VidFlow" /b "%PYTHON%" -m streamlit run app.py ^
    --server.port %APP_PORT% ^
    --server.address 0.0.0.0 ^
    --server.headless true

:: Capture PID of the most recently started background process
:: (Streamlit starts a uvicorn subprocess; we capture the parent python PID)
for /f "tokens=2" %%P in ('tasklist /fi "imagename eq python.exe" /fo list ^| findstr "PID:"') do (
    set "LAST_PID=%%P"
)
echo !LAST_PID! > vidflow.pid

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
echo.
popd
