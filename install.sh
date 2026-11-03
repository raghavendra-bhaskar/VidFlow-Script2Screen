#!/usr/bin/env bash
# VidFlow — Script2Screen  |  Linux / macOS Installer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "============================================================"
echo " VidFlow - Script2Screen  |  Installer"
echo "============================================================"
echo ""
echo " Choose a deployment mode:"
echo ""
echo "   1) Regular VM  — Python venv + start/stop scripts"
echo "                    Best for: single VM, LAN access, localhost"
echo ""
echo "   2) Kubernetes  — Docker image build + kubectl apply"
echo "                    Best for: k8s cluster, hclswl2learninghub, production"
echo ""
read -rp " Enter choice [1 or 2, default 1]: " DEPLOY_CHOICE
DEPLOY_CHOICE="${DEPLOY_CHOICE:-1}"

if [[ "$DEPLOY_CHOICE" != "1" && "$DEPLOY_CHOICE" != "2" ]]; then
    echo "ERROR: Invalid choice. Run the script again and enter 1 or 2."
    exit 1
fi

echo ""
if [[ "$DEPLOY_CHOICE" == "1" ]]; then
    echo ">>> Mode: Regular VM install"
else
    echo ">>> Mode: Kubernetes install"
fi
echo ""

# ════════════════════════════════════════════════════════════════════
# MODE 1 — REGULAR VM INSTALL
# ════════════════════════════════════════════════════════════════════
if [[ "$DEPLOY_CHOICE" == "1" ]]; then

    # ── 1. Install FFmpeg ─────────────────────────────────────────
    echo "[1/5] Installing FFmpeg..."
    if command -v ffmpeg &>/dev/null; then
        echo "INFO: FFmpeg already installed: $(ffmpeg -version 2>&1 | head -1)"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &>/dev/null; then
            brew install ffmpeg
        else
            echo "ERROR: Homebrew not found. Install from https://brew.sh"
            exit 1
        fi
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y ffmpeg
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y ffmpeg
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm ffmpeg
    else
        echo "ERROR: Cannot detect package manager. Install FFmpeg manually: https://ffmpeg.org/download.html"
        exit 1
    fi
    echo "INFO: FFmpeg OK — $(ffmpeg -version 2>&1 | head -1)"

    # ── 2. Detect Python ──────────────────────────────────────────
    echo ""
    echo "[2/5] Detecting Python 3.10+..."
    PYTHON=""
    for cmd in python3.12 python3.11 python3.10 python3 python; do
        if command -v "$cmd" &>/dev/null; then
            VER=$($cmd -c "import sys; print(sys.version_info >= (3,10))" 2>/dev/null || echo "False")
            if [[ "$VER" == "True" ]]; then PYTHON="$cmd"; break; fi
        fi
    done
    if [[ -z "$PYTHON" ]]; then
        echo "ERROR: Python 3.10 or later is required. Install from https://python.org"
        exit 1
    fi
    echo "INFO: Using $PYTHON ($($PYTHON --version))"

    # ── 3. Python virtual environment + dependencies ──────────────
    echo ""
    echo "[3/5] Creating Python virtual environment (.venv)..."
    [[ -d ".venv" ]] && echo "INFO: .venv already exists — skipping." || $PYTHON -m venv .venv
    source .venv/bin/activate
    pip install --upgrade pip --quiet
    echo "INFO: Installing Python dependencies..."
    pip install -r requirements.txt

    # ── 4. .env template ──────────────────────────────────────────
    echo ""
    echo "[4/5] Setting up .env..."
    if [[ ! -f ".env" ]]; then
        cp .env.example .env
        echo "INFO: .env created from .env.example"
        echo "      Edit .env to set VIDFLOW_DOMAIN, API keys, etc."
    else
        echo "INFO: .env already exists — skipping."
    fi

    # ── 5. TLS certificate ────────────────────────────────────────
    echo ""
    echo "[5/5] Generating self-signed HTTPS certificate..."
    read -rp "      Enter hostname(s) for the cert [default: localhost]: " CERT_DOMAIN
    CERT_DOMAIN="${CERT_DOMAIN:-localhost}"
    if [[ -f "cert.pem" ]]; then
        read -rp "      cert.pem already exists. Regenerate? [y/N]: " REGEN
        REGEN="${REGEN:-N}"
    else
        REGEN="y"
    fi
    if [[ "${REGEN,,}" == "y" ]]; then
        VIDFLOW_DOMAIN="$CERT_DOMAIN" .venv/bin/python gen_cert.py \
            && echo "INFO: Certificate generated for: $CERT_DOMAIN" \
            || echo "WARNING: Cert generation failed — app will run HTTP."
    else
        echo "INFO: Keeping existing cert.pem."
    fi

    # ── Done (Mode 1) ─────────────────────────────────────────────
    echo ""
    echo "============================================================"
    echo " Regular VM install complete!"
    echo "============================================================"
    echo ""
    echo " Start the app:"
    echo "   chmod +x start_app.sh stop_app.sh"
    echo "   ./start_app.sh"
    echo ""
    echo " Stop the app:"
    echo "   ./stop_app.sh"
    echo ""
    echo " Open: https://${CERT_DOMAIN}:8501"
    echo " (Accept the self-signed certificate warning on first visit.)"
    echo ""
    echo " For a public domain with Let's Encrypt TLS:"
    echo "   1. Set NO_SSL=1 in .env"
    echo "   2. Copy nginx.conf to /etc/nginx/sites-available/ and adjust"
    echo "   3. Run: sudo certbot --nginx -d ${CERT_DOMAIN}"
    echo ""

fi  # end MODE 1


# ════════════════════════════════════════════════════════════════════
# MODE 2 — KUBERNETES INSTALL
# ════════════════════════════════════════════════════════════════════
if [[ "$DEPLOY_CHOICE" == "2" ]]; then

    # ── Pre-flight checks ─────────────────────────────────────────
    echo "[k8s 1/4] Checking prerequisites..."

    # Detect podman (preferred on RHEL/CentOS/Fedora) or fall back to docker
    if command -v podman &>/dev/null; then
        BUILD_CMD="podman"
        echo "INFO: podman detected — using podman for image build/push."
    elif command -v docker &>/dev/null; then
        BUILD_CMD="docker"
        echo "INFO: docker detected."
    else
        echo "ERROR: Neither podman nor docker is installed."
        echo "       Install podman: https://podman.io/getting-started/installation"
        echo "       Or docker:      https://docs.docker.com/get-docker/"
        exit 1
    fi

    if ! command -v kubectl &>/dev/null; then
        echo "ERROR: kubectl is not installed."
        echo "       https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi

    echo "INFO: ${BUILD_CMD} OK — $(${BUILD_CMD} --version)"
    echo "INFO: kubectl OK — $(kubectl version --client 2>/dev/null | head -1)"

    # ── Collect configuration ─────────────────────────────────────
    echo ""
    echo "[k8s 2/4] Configuration..."
    echo ""
    echo "  Image name rules:"
    echo "    Docker Hub    : yourusername/vidflow:latest"
    echo "    Local registry: registry.example.com:5000/vidflow:latest"
    echo "    Skip push     : just press Enter — image will be imported locally"
    echo ""
    read -rp "  Image name [default: localhost/vidflow:latest]: " IMAGE_NAME
    IMAGE_NAME="${IMAGE_NAME:-localhost/vidflow:latest}"

    # ── Validate: reject bare names that map to docker.io/library/ ───
    # A bare name like 'vidflow' or 'vidflow:latest' has no '/' and no hostname.
    # Pushing to docker.io/library/* requires Docker official maintainer access.
    if [[ "$IMAGE_NAME" != *"/"* ]]; then
        echo ""
        echo "ERROR: Image name '$IMAGE_NAME' has no registry or username prefix."
        echo "       docker.io/library/* requires special Docker Hub access."
        echo ""
        echo "  Use one of these formats instead:"
        echo "    yourdockerhubuser/vidflow:latest"
        echo "    registry.hclswl2learninghub:5000/vidflow:latest"
        echo "    localhost/vidflow:latest  (no push, import directly into k8s)"
        exit 1
    fi

    read -rp "  Public hostname (e.g. hclswl2learninghub): " K8S_DOMAIN
    K8S_DOMAIN="${K8S_DOMAIN:-hclswl2learninghub}"

    read -rp "  Kubernetes namespace [default: vidflow]: " K8S_NS
    K8S_NS="${K8S_NS:-vidflow}"

    echo ""
    echo "  Registry push options:"
    echo "    y  = tag & push to a remote registry (Docker Hub, private registry)"
    echo "    n  = skip push; import image directly into k8s node (no registry needed)"
    read -rp "  Push image to registry? [y/N]: " DO_PUSH
    DO_PUSH="${DO_PUSH:-N}"

    # ── Build image ───────────────────────────────────────────────
    echo ""
    echo "[k8s 3/4] Building image: ${IMAGE_NAME}..."
    ${BUILD_CMD} build -t "${IMAGE_NAME}" .
    echo "INFO: Image built successfully."

    if [[ "${DO_PUSH,,}" == "y" ]]; then
        echo "INFO: Pushing image to registry..."
        ${BUILD_CMD} push "${IMAGE_NAME}"
        echo "INFO: Push complete."
        PULL_POLICY="Always"
    else
        echo "INFO: Skipping registry push — importing image directly into k8s..."
        # Import into the local container runtime used by the k8s node.
        # Supports k3s, standard containerd, and microk8s.
        if command -v k3s &>/dev/null; then
            echo "INFO: k3s detected — importing via k3s ctr..."
            ${BUILD_CMD} save "${IMAGE_NAME}" | sudo k3s ctr images import -
        elif command -v ctr &>/dev/null; then
            echo "INFO: containerd (ctr) detected — importing via ctr..."
            ${BUILD_CMD} save "${IMAGE_NAME}" | sudo ctr -n k8s.io images import -
        elif command -v microk8s &>/dev/null; then
            echo "INFO: microk8s detected — importing via microk8s ctr..."
            ${BUILD_CMD} save "${IMAGE_NAME}" | microk8s ctr images import -
        else
            echo "WARN: Could not detect k3s/ctr/microk8s."
            echo "      Import manually: ${BUILD_CMD} save ${IMAGE_NAME} | sudo ctr -n k8s.io images import -"
        fi
        # Never pull from registry — always use the locally imported image
        PULL_POLICY="Never"
    fi

    # ── Patch and apply k8s manifests ────────────────────────────
    echo ""
    echo "[k8s 4/4] Deploying to Kubernetes (namespace: ${K8S_NS})..."

    TMP_MANIFEST="$(mktemp /tmp/vidflow-k8s-XXXX.yaml)"
    sed \
        -e "s|your-registry/vidflow:latest|${IMAGE_NAME}|g" \
        -e "s|hclswl2learninghub|${K8S_DOMAIN}|g" \
        -e "s|imagePullPolicy: Always|imagePullPolicy: ${PULL_POLICY}|g" \
        k8s/deployment.yaml > "$TMP_MANIFEST"

    kubectl apply -f "$TMP_MANIFEST"
    rm -f "$TMP_MANIFEST"

    BUILD_CMD_DISPLAY="${BUILD_CMD}"
    echo ""
    echo "============================================================"
    echo " Kubernetes deployment complete!"
    echo "============================================================"
    echo ""
    echo " Monitor:"
    echo "   kubectl -n ${K8S_NS} get pods -w"
    echo "   kubectl -n ${K8S_NS} logs deploy/vidflow -f"
    echo ""
    echo " Access (once DNS resolves to your Ingress LoadBalancer IP):"
    echo "   https://${K8S_DOMAIN}"
    echo ""
    echo " Update image after a code change:"
    if [[ "${DO_PUSH,,}" == "y" ]]; then
        echo "   ${BUILD_CMD_DISPLAY} build -t ${IMAGE_NAME} . && ${BUILD_CMD_DISPLAY} push ${IMAGE_NAME}"
    else
        echo "   ${BUILD_CMD_DISPLAY} build -t ${IMAGE_NAME} ."
        echo "   ${BUILD_CMD_DISPLAY} save ${IMAGE_NAME} | sudo k3s ctr images import -   # (adjust for your k8s)"
    fi
    echo "   kubectl -n ${K8S_NS} rollout restart deploy/vidflow"
    echo ""

fi  # end MODE 2
