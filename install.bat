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
echo  Uninstall the VM install:
echo    uninstall.bat
echo.
echo  Ollama auto-narration:
echo    Install Ollama separately and pull a vision model, e.g. ollama pull llava:7b
echo    Same machine: OLLAMA_BASE_URL=http://localhost:11434 in .env
echo    Kubernetes: set OLLAMA_BASE_URL to the VM private address in k8s/deployment.yaml
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

:: Detect podman first (common on RHEL/CentOS VMs), fall back to docker
set "BUILD_CMD="
where podman >nul 2>&1
if %ERRORLEVEL% equ 0 (
    set "BUILD_CMD=podman"
    echo INFO: podman detected.
)
if "!BUILD_CMD!"=="" (
    where docker >nul 2>&1
    if %ERRORLEVEL% equ 0 (
        set "BUILD_CMD=docker"
        echo INFO: docker detected.
    )
)
if "!BUILD_CMD!"=="" (
    echo ERROR: Neither podman nor docker is installed or in PATH.
    echo        podman: https://podman.io/getting-started/installation
    echo        docker: https://docs.docker.com/get-docker/
    exit /b 1
)
where kubectl >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: kubectl is not installed or not in PATH.
    echo        https://kubernetes.io/docs/tasks/tools/
    exit /b 1
)
echo INFO: !BUILD_CMD! and kubectl found.

:: ── Collect configuration ─────────────────────────────────
echo.
echo [k8s 2/4] Configuration...
echo.
echo   Image name rules:
echo     Docker Hub    : yourusername/vidflow:latest
echo     Local registry: registry.hclswl2learninghub:5000/vidflow:latest
echo     Skip push     : press Enter -- image imported directly into k8s
echo.
set /p IMAGE_NAME="  Image name [default: localhost/vidflow:latest]: "
if "!IMAGE_NAME!"=="" set "IMAGE_NAME=localhost/vidflow:latest"

:: Validate: bare name (no /) maps to docker.io/library/* -- access denied
echo !IMAGE_NAME! | findstr "/" >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Image name '!IMAGE_NAME!' has no registry or username prefix.
    echo        docker.io/library/* requires special Docker Hub access.
    echo.
    echo   Use one of these formats:
    echo     yourdockerhubuser/vidflow:latest
    echo     registry.hclswl2learninghub:5000/vidflow:latest
    echo     localhost/vidflow:latest   (no push, import directly into k8s)
    exit /b 1
)

set /p K8S_DOMAIN="  Public hostname (e.g. hclswl2learninghub): "
if "!K8S_DOMAIN!"=="" set "K8S_DOMAIN=hclswl2learninghub"

set /p K8S_NS="  Kubernetes namespace [default: vidflow]: "
if "!K8S_NS!"=="" set "K8S_NS=vidflow"

echo.
echo   Push options:
echo     y = push to remote registry (Docker Hub / private registry)
echo     n = skip push; import image directly into k8s node (no registry needed)
echo.
set /p DO_PUSH="  Push image to registry? [y/N]: "
if "!DO_PUSH!"=="" set "DO_PUSH=N"

:: ── Build image ────────────────────────────────────────────
echo.
echo [k8s 3/4] Building image: !IMAGE_NAME!...
!BUILD_CMD! build -t "!IMAGE_NAME!" .
if %ERRORLEVEL% neq 0 (
    echo ERROR: Image build failed.
    exit /b 1
)
echo INFO: Image built successfully.

set "PULL_POLICY=Never"
if /i "!DO_PUSH!"=="y" (
    echo INFO: Pushing image to registry...
    !BUILD_CMD! push "!IMAGE_NAME!"
    if %ERRORLEVEL% neq 0 (
        echo ERROR: Push failed. Check registry login: !BUILD_CMD! login docker.io
        exit /b 1
    )
    echo INFO: Push complete.
    set "PULL_POLICY=Always"
) else (
    echo INFO: Skipping registry push -- import the image into k8s manually if needed:
    echo       !BUILD_CMD! save !IMAGE_NAME! ^| sudo k3s ctr images import -
    echo       (or: sudo ctr -n k8s.io images import -)
)

:: ── Apply k8s manifests ────────────────────────────────────
echo.
echo [k8s 4/4] Deploying to Kubernetes (namespace: !K8S_NS!)...
set "TMP_MANIFEST=%TEMP%\vidflow-k8s.yaml"
powershell -Command ^
  "(Get-Content 'k8s\deployment.yaml') ^
   -replace 'your-registry/vidflow:latest','!IMAGE_NAME!' ^
   -replace 'hclswl2learninghub','!K8S_DOMAIN!' ^
   -replace 'imagePullPolicy: Always','imagePullPolicy: !PULL_POLICY!' ^
   | Set-Content '!TMP_MANIFEST!'"
kubectl apply -f "!TMP_MANIFEST!"
del /f "!TMP_MANIFEST!" >nul 2>&1

echo.
echo ============================================================
echo  Kubernetes deployment complete!
echo ============================================================
echo.
echo  Monitor:
echo    kubectl -n !K8S_NS! get pods -w
echo    kubectl -n !K8S_NS! logs deploy/vidflow -f
echo.
echo  Access (once DNS points to Ingress LoadBalancer IP):
echo    https://!K8S_DOMAIN!
echo  Use the Ingress URL (without :30501) for browser recording and editor uploads.
echo  Ollama must be reachable from the VidFlow pod; see README.md, Tab 6.
echo.
echo  Update after a code change:
echo    !BUILD_CMD! build -t !IMAGE_NAME! .
if /i "!DO_PUSH!"=="y" (
    echo    !BUILD_CMD! push !IMAGE_NAME!
)
echo    kubectl -n !K8S_NS! rollout restart deploy/vidflow
echo.
pause
goto :EOF
