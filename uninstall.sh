#!/usr/bin/env bash
# uninstall.sh — Remove VidFlow (VM venv and/or Kubernetes resources)
# Usage:  chmod +x uninstall.sh && ./uninstall.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "============================================================"
echo " VidFlow - Script2Screen  |  Uninstaller"
echo "============================================================"
echo ""
echo " Choose what to remove:"
echo ""
echo "   1) VM mode only   — stop process, remove .venv, cert, media"
echo "   2) k8s mode only  — delete Kubernetes namespace + imported image"
echo "   3) Both           — k8s resources first, then VM cleanup"
echo ""
read -rp " Enter choice [1/2/3, default 2]: " CHOICE
CHOICE="${CHOICE:-2}"

if [[ "$CHOICE" != "1" && "$CHOICE" != "2" && "$CHOICE" != "3" ]]; then
    echo "ERROR: Enter 1, 2, or 3."
    exit 1
fi


# ════════════════════════════════════════════════════════════════════
# KUBERNETES CLEANUP
# ════════════════════════════════════════════════════════════════════
if [[ "$CHOICE" == "2" || "$CHOICE" == "3" ]]; then
    echo ""
    echo "[k8s] Removing VidFlow from Kubernetes..."

    if ! command -v kubectl &>/dev/null; then
        echo "WARN: kubectl not found — skipping Kubernetes cleanup."
    else
        read -rp "  Kubernetes namespace [default: vidflow]: " K8S_NS
        K8S_NS="${K8S_NS:-vidflow}"

        read -rp "  Delete namespace '$K8S_NS' and ALL its resources? [y/N]: " CONFIRM_K8S
        CONFIRM_K8S="${CONFIRM_K8S:-N}"

        if [[ "${CONFIRM_K8S,,}" == "y" ]]; then
            kubectl delete namespace "$K8S_NS" --wait=true \
                && echo "[INFO] Namespace '$K8S_NS' deleted." \
                || echo "[INFO] Namespace '$K8S_NS' not found — already removed."
        else
            echo "[INFO] Kubernetes namespace deletion skipped."
        fi

        # Remove image from local container runtime
        if command -v k3s &>/dev/null; then
            echo "[INFO] Removing imported image from k3s containerd..."
            sudo k3s ctr images rm localhost/vidflow:latest 2>/dev/null \
                && echo "[INFO] Image removed." \
                || echo "[INFO] Image not found — skipping."
        elif command -v ctr &>/dev/null; then
            sudo ctr -n k8s.io images rm localhost/vidflow:latest 2>/dev/null || true
        fi

        # Remove any podman/docker local image
        for TOOL in podman docker; do
            if command -v "$TOOL" &>/dev/null; then
                $TOOL rmi localhost/vidflow:latest 2>/dev/null \
                    && echo "[INFO] $TOOL image removed." || true
                break
            fi
        done
    fi
fi


# ════════════════════════════════════════════════════════════════════
# VM CLEANUP
# ════════════════════════════════════════════════════════════════════
if [[ "$CHOICE" == "1" || "$CHOICE" == "3" ]]; then
    echo ""
    echo "[VM] Removing VM installation..."

    # Stop running VidFlow process
    if [[ -f "vidflow.pid" ]]; then
        PID=$(cat vidflow.pid 2>/dev/null || echo "")
        if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
            echo "[INFO] Stopping VidFlow (PID $PID)..."
            kill "$PID" && sleep 1 || true
        fi
        rm -f vidflow.pid
        echo "[INFO] PID file removed."
    fi

    # Also stop any orphan Streamlit processes
    if pgrep -f "streamlit run app.py" &>/dev/null; then
        echo "[INFO] Stopping orphaned streamlit processes..."
        pkill -f "streamlit run app.py" || true
        sleep 1
    fi

    # Remove virtual environment
    read -rp "  Remove .venv (Python packages)? [y/N]: " RM_VENV
    RM_VENV="${RM_VENV:-N}"
    if [[ "${RM_VENV,,}" == "y" ]]; then
        rm -rf .venv && echo "[INFO] .venv removed."
    fi

    # Remove TLS certificates
    read -rp "  Remove cert.pem and key.pem? [y/N]: " RM_CERTS
    RM_CERTS="${RM_CERTS:-N}"
    if [[ "${RM_CERTS,,}" == "y" ]]; then
        rm -f cert.pem key.pem && echo "[INFO] TLS certificates removed."
    fi

    # Remove .env (contains API keys)
    read -rp "  Remove .env (contains API keys — back up first!)? [y/N]: " RM_ENV
    RM_ENV="${RM_ENV:-N}"
    if [[ "${RM_ENV,,}" == "y" ]]; then
        rm -f .env && echo "[INFO] .env removed."
    fi

    # Remove generated media output
    read -rp "  Remove all generated media (audio/, video+narrated/, etc.)? [y/N]: " RM_MEDIA
    RM_MEDIA="${RM_MEDIA:-N}"
    if [[ "${RM_MEDIA,,}" == "y" ]]; then
        rm -rf audio/* audio_edits/* screen_recordings/* \
                trimmed_videos/* merged_videos/* \
                "video+narrated/"* uploads/* 2>/dev/null || true
        echo "[INFO] Media output directories cleared."
    fi

    # Remove __pycache__
    find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    echo "[INFO] Python cache removed."
fi

echo ""
echo "============================================================"
echo " VidFlow uninstall complete."
echo "============================================================"
echo ""
echo " Source code directory: $SCRIPT_DIR"
echo " To remove it entirely: rm -rf \"$SCRIPT_DIR\""
echo ""
