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
    MISSING=()
    command -v docker   &>/dev/null || MISSING+=("docker")
    command -v kubectl  &>/dev/null || MISSING+=("kubectl")
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "ERROR: The following tools are required but not installed:"
        for m in "${MISSING[@]}"; do echo "  - $m"; done
        echo ""
        echo "  Docker  : https://docs.docker.com/get-docker/"
        echo "  kubectl : https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
    echo "INFO: docker OK — $(docker --version)"
    echo "INFO: kubectl OK — $(kubectl version --client --short 2>/dev/null || kubectl version --client)"

    # ── Collect configuration ─────────────────────────────────────
    echo ""
    echo "[k8s 2/4] Configuration..."
    read -rp "  Docker image name (e.g. myregistry/vidflow:latest): " IMAGE_NAME
    IMAGE_NAME="${IMAGE_NAME:-vidflow:latest}"

    read -rp "  Public hostname (e.g. hclswl2learninghub): " K8S_DOMAIN
    K8S_DOMAIN="${K8S_DOMAIN:-hclswl2learninghub}"

    read -rp "  Kubernetes namespace [default: vidflow]: " K8S_NS
    K8S_NS="${K8S_NS:-vidflow}"

    read -rp "  Push image to registry? [Y/n]: " DO_PUSH
    DO_PUSH="${DO_PUSH:-Y}"

    # ── Build Docker image ────────────────────────────────────────
    echo ""
    echo "[k8s 3/4] Building Docker image: ${IMAGE_NAME}..."
    docker build -t "${IMAGE_NAME}" .
    echo "INFO: Image built successfully."

    if [[ "${DO_PUSH,,}" == "y" ]]; then
        echo "INFO: Pushing image to registry..."
        docker push "${IMAGE_NAME}"
        echo "INFO: Push complete."
    fi

    # ── Patch and apply k8s manifests ────────────────────────────
    echo ""
    echo "[k8s 4/4] Deploying to Kubernetes (namespace: ${K8S_NS})..."

    # Substitute domain and image into a temporary copy of the manifest
    TMP_MANIFEST="$(mktemp /tmp/vidflow-k8s-XXXX.yaml)"
    sed \
        -e "s|your-registry/vidflow:latest|${IMAGE_NAME}|g" \
        -e "s|hclswl2learninghub|${K8S_DOMAIN}|g" \
        -e "s|name: vidflow$|name: ${K8S_NS}|" \
        k8s/deployment.yaml > "$TMP_MANIFEST"

    kubectl apply -f "$TMP_MANIFEST"
    rm -f "$TMP_MANIFEST"

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
    echo "   docker build -t ${IMAGE_NAME} . && docker push ${IMAGE_NAME}"
    echo "   kubectl -n ${K8S_NS} rollout restart deploy/vidflow"
    echo ""

fi  # end MODE 2
