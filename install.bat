@echo off
setlocal enabledelayedexpansion
title VidFlow — Script2Screen Installer (Windows)

pushd "%~dp0"

echo.
echo ============================================================
echo  VidFlow - Script2Screen  ^|  Installer
echo ============================================================
echo.
echo  Choose a deployment mode:
echo.
echo    1) Regular VM  -- Python venv + start/stop scripts
echo                      Best for: single VM, LAN access, localhost
echo.
echo    2) Kubernetes  -- Docker image build + kubectl apply
echo                      Best for: k8s cluster, hclswl2learninghub, production
echo.
set /p DEPLOY_CHOICE=" Enter choice [1 or 2, default 1]: "
if "%DEPLOY_CHOICE%"=="" set "DEPLOY_CHOICE=1"

if "%DEPLOY_CHOICE%"=="1" goto MODE1
if "%DEPLOY_CHOICE%"=="2" goto MODE2
echo ERROR: Invalid choice. Enter 1 or 2.
exit /b 1


:: ════════════════════════════════════════════════════════════
:: MODE 1 — REGULAR VM INSTALL
:: ════════════════════════════════════════════════════════════
:MODE1
echo.
echo ^>^>^> Mode: Regular VM install
echo.

:: ── 1. Install FFmpeg ─────────────────────────────────────
echo [1/5] Installing FFmpeg via winget...
winget install --id Gyan.FFmpeg -e --source winget --accept-source-agreements --accept-package-agreements
if %ERRORLEVEL% neq 0 (
    echo WARNING: winget FFmpeg install returned a non-zero exit code.
    echo          FFmpeg may already be installed or winget is unavailable.
    echo          Continuing — the app will locate FFmpeg via the registry.
)

echo [INFO] Refreshing PATH from registry...
for /f "tokens=2*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SYS_PATH=%%B"
for /f "tokens=2*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul') do set "USR_PATH=%%B"
set "PATH=%SYS_PATH%;%USR_PATH%"

:: ── 2. Python virtual environment ─────────────────────────
echo.
echo [2/5] Creating Python virtual environment (.venv)...
python -m venv .venv
if %ERRORLEVEL% neq 0 (
    echo ERROR: 'python' not found. Install Python 3.10+ from https://python.org
    exit /b 1
)

:: ── 3. Python dependencies ────────────────────────────────
echo.
echo [3/5] Installing Python dependencies...
.venv\Scripts\python.exe -m pip install --upgrade pip --quiet
.venv\Scripts\python.exe -m pip install -r requirements.txt
if %ERRORLEVEL% neq 0 (
    echo ERROR: pip install failed. Check requirements.txt and your internet connection.
    exit /b 1
)

:: ── 4. .env template ──────────────────────────────────────
echo.
echo [4/5] Setting up .env...
if not exist .env (
    copy .env.example .env >nul
    echo INFO: .env created from .env.example
    echo       Edit .env to set VIDFLOW_DOMAIN, API keys, etc.
) else (
    echo INFO: .env already exists — skipping.
)

:: ── 5. TLS certificate ────────────────────────────────────
echo.
echo [5/5] Generating self-signed HTTPS certificate...
set /p CERT_DOMAIN="      Enter hostname for the cert [default: localhost]: "
if "!CERT_DOMAIN!"=="" set "CERT_DOMAIN=localhost"

if exist cert.pem (
    set /p REGEN="      cert.pem already exists. Regenerate? [y/N]: "
) else (
    set "REGEN=y"
)

if /i "!REGEN!"=="y" (
    set "VIDFLOW_DOMAIN=!CERT_DOMAIN!"
    .venv\Scripts\python.exe gen_cert.py
    if %ERRORLEVEL% neq 0 (
        echo WARNING: Cert generation failed — app will run HTTP only.
    ) else (
        echo INFO: Certificate generated for: !CERT_DOMAIN!
    )
) else (
    echo INFO: Keeping existing cert.pem.
)

:: ── Done (Mode 1) ─────────────────────────────────────────
echo.
echo ============================================================
echo  Regular VM install complete!
echo ============================================================
echo.
echo  Start the app:
echo    start_app.bat
echo.
echo  Stop the app:
echo    stop_app.bat
echo.
echo  Open: https://!CERT_DOMAIN!:8501
echo  (Accept the self-signed certificate warning on first visit.)
echo.
echo  For a public domain with nginx + Let's Encrypt:
echo    1. Set NO_SSL=1 in .env
echo    2. Configure nginx.conf with your domain
echo    3. Use certbot for a proper TLS certificate
echo.
pause
goto :EOF


:: ════════════════════════════════════════════════════════════
:: MODE 2 — KUBERNETES INSTALL
:: ════════════════════════════════════════════════════════════
:MODE2
echo.
echo ^>^>^> Mode: Kubernetes install
echo.

:: ── Pre-flight checks ─────────────────────────────────────
echo [k8s 1/4] Checking prerequisites...
where docker >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: Docker is not installed or not in PATH.
    echo        Install from https://docs.docker.com/get-docker/
    exit /b 1
)
where kubectl >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: kubectl is not installed or not in PATH.
    echo        Install from https://kubernetes.io/docs/tasks/tools/
    exit /b 1
)
echo INFO: docker and kubectl found.

:: ── Collect configuration ─────────────────────────────────
echo.
echo [k8s 2/4] Configuration...
set /p IMAGE_NAME="  Docker image name (e.g. myregistry/vidflow:latest): "
if "!IMAGE_NAME!"=="" set "IMAGE_NAME=vidflow:latest"

set /p K8S_DOMAIN="  Public hostname (e.g. hclswl2learninghub): "
if "!K8S_DOMAIN!"=="" set "K8S_DOMAIN=hclswl2learninghub"

set /p K8S_NS="  Kubernetes namespace [default: vidflow]: "
if "!K8S_NS!"=="" set "K8S_NS=vidflow"

set /p DO_PUSH="  Push image to registry? [Y/n]: "
if "!DO_PUSH!"=="" set "DO_PUSH=Y"

:: ── Build Docker image ────────────────────────────────────
echo.
echo [k8s 3/4] Building Docker image: !IMAGE_NAME!...
docker build -t "!IMAGE_NAME!" .
if %ERRORLEVEL% neq 0 (
    echo ERROR: Docker build failed.
    exit /b 1
)
echo INFO: Image built successfully.

if /i "!DO_PUSH!"=="Y" (
    echo INFO: Pushing image to registry...
    docker push "!IMAGE_NAME!"
    if %ERRORLEVEL% neq 0 (
        echo ERROR: docker push failed. Check your registry login.
        exit /b 1
    )
    echo INFO: Push complete.
)

:: ── Apply k8s manifests (via PowerShell sed substitute) ───
echo.
echo [k8s 4/4] Deploying to Kubernetes (namespace: !K8S_NS!)...
set "TMP_MANIFEST=%TEMP%\vidflow-k8s.yaml"
powershell -Command ^
  "(Get-Content k8s\deployment.yaml) ^
   -replace 'your-registry/vidflow:latest','!IMAGE_NAME!' ^
   -replace 'hclswl2learninghub','!K8S_DOMAIN!' ^
   | Set-Content '%TMP_MANIFEST%'"
kubectl apply -f "%TMP_MANIFEST%"
del /f "%TMP_MANIFEST%" >nul 2>&1

echo.
echo ============================================================
echo  Kubernetes deployment complete!
echo ============================================================
echo.
echo  Monitor:
echo    kubectl -n !K8S_NS! get pods -w
echo    kubectl -n !K8S_NS! logs deploy/vidflow -f
echo.
echo  Access (once DNS points to your Ingress LoadBalancer IP):
echo    https://!K8S_DOMAIN!
echo.
echo  Update after a code change:
echo    docker build -t !IMAGE_NAME! . ^& docker push !IMAGE_NAME!
echo    kubectl -n !K8S_NS! rollout restart deploy/vidflow
echo.
pause
goto :EOF
