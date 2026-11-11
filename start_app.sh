#!/usr/bin/env bash
# start_app.sh — Start VidFlow on a Linux VM or inside a Kubernetes pod.
#
# Usage
# -----
#   ./start_app.sh                         # default port 8501, HTTP/HTTPS
#   PORT=8080 ./start_app.sh               # custom port
#   NO_SSL=1 ./start_app.sh               # disable self-signed SSL (behind nginx/Ingress)
#
# The script:
#   1. Optionally generates a self-signed TLS cert for VIDFLOW_DOMAIN.
#   2. Starts Streamlit bound to 0.0.0.0 in the background.
#   3. Writes the PID to vidflow.pid so stop_app.sh can cleanly kill it.
#
# Environment variables (override from .env or shell export):
#   VIDFLOW_DOMAIN        Comma-separated hostnames/IPs to add to the TLS cert
#   VIDFLOW_INTERNAL_BASE_URL Full browser URL for the helper API, e.g. https://host/api
#   VIDFLOW_INTERNAL_HOST Hostname/IP browsers use to reach the API server (port 8502)
#   VIDFLOW_INTERNAL_PORT Port for the internal API server (default 8502)
#   PORT                  Streamlit port (default 8501)
#   NO_SSL                Set to 1 to run plain HTTP (use behind nginx/Traefik/Ingress)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Load .env if it exists ────────────────────────────────────────────────────
if [[ -f ".env" ]]; then
    # Export every non-commented variable from .env into the current shell
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

APP_PORT="${PORT:-8501}"
PYTHON="${SCRIPT_DIR}/.venv/bin/python"
APP_SCRIPT="${SCRIPT_DIR}/app.py"
if [[ ! -x "$PYTHON" ]]; then
    echo "ERROR: .venv not found. Run ./install.sh first."
    exit 1
fi

# ── Step 1: TLS Certificate ──────────────────────────────────────────────────
if [[ "${NO_SSL:-0}" == "1" ]]; then
    echo "[INFO] NO_SSL=1 — skipping certificate; running plain HTTP behind reverse proxy."
    # Comment out SSL lines in config.toml for this session via env override
    export STREAMLIT_SERVER_SSL_CERT_FILE=""
    export STREAMLIT_SERVER_SSL_KEY_FILE=""
else
    if [[ ! -f "cert.pem" ]] || [[ -n "${VIDFLOW_DOMAIN:-}" ]]; then
        echo "[INFO] Generating TLS certificate (VIDFLOW_DOMAIN=${VIDFLOW_DOMAIN:-localhost})..."
        VIDFLOW_DOMAIN="${VIDFLOW_DOMAIN:-}" "$PYTHON" gen_cert.py
    else
        echo "[INFO] cert.pem already present — skipping cert generation."
    fi
fi

# ── Step 2: Start Streamlit ───────────────────────────────────────────────────
echo "[INFO] Starting VidFlow on port ${APP_PORT}..."

"$PYTHON" -m streamlit run "$APP_SCRIPT" \
    --server.port "${APP_PORT}" \
    --server.address "0.0.0.0" \
    --server.headless true \
    &

STREAMLIT_PID=$!
echo "$STREAMLIT_PID" > vidflow.pid
echo "[INFO] VidFlow started (PID ${STREAMLIT_PID})."
echo "[INFO] PID saved to vidflow.pid — run ./stop_app.sh to stop."
echo ""

if [[ "${NO_SSL:-0}" == "1" ]]; then
    echo "  → http://$(hostname -I | awk '{print $1}'):${APP_PORT}"
else
    DOMAIN="${VIDFLOW_DOMAIN%%,*}"
    DOMAIN="${DOMAIN:-localhost}"
    echo "  → https://${DOMAIN}:${APP_PORT}"
    echo "  → Accept the self-signed certificate warning on first visit."
fi
echo ""
echo "  Internal API server (trim / screen recorder) will start on port ${VIDFLOW_INTERNAL_PORT:-8502}."
echo "  Browser API URL: ${VIDFLOW_INTERNAL_BASE_URL:-http://${VIDFLOW_INTERNAL_HOST:-localhost}:${VIDFLOW_INTERNAL_PORT:-8502}}"
echo "  Ollama URL: ${OLLAMA_BASE_URL:-http://localhost:11434}"
echo "  In Docker/Kubernetes set OLLAMA_BASE_URL to a VM/private service address reachable from the container."
