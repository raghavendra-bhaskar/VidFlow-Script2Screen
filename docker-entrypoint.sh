#!/usr/bin/env bash
# docker-entrypoint.sh — Container startup for VidFlow.
# Called by the Dockerfile ENTRYPOINT.
set -euo pipefail

cd /app

# ── Step 1: TLS certificate ───────────────────────────────────────────────────
if [[ "${NO_SSL:-0}" == "1" ]]; then
    echo "[entrypoint] NO_SSL=1 — skipping cert; SSL terminated at Ingress/nginx."
    # Remove SSL lines from Streamlit config so it doesn't fail looking for missing cert files
    sed -i 's/^sslCertFile.*$/# sslCertFile removed (NO_SSL=1)/' .streamlit/config.toml || true
    sed -i 's/^sslKeyFile.*$/# sslKeyFile  removed (NO_SSL=1)/'  .streamlit/config.toml || true
else
    if [[ ! -f "cert.pem" ]]; then
        echo "[entrypoint] Generating TLS cert (VIDFLOW_DOMAIN=${VIDFLOW_DOMAIN:-localhost})..."
        python gen_cert.py
    else
        echo "[entrypoint] cert.pem already present."
    fi
fi

# ── Step 2: Start Streamlit ───────────────────────────────────────────────────
APP_PORT="${PORT:-8501}"
echo "[entrypoint] Starting Streamlit on 0.0.0.0:${APP_PORT}..."

# Do NOT use exec here — keeping the shell as PID 1 means we can kill/restart
# Streamlit (e.g. after a kubectl cp file update) without the container exiting.
# Kubernetes only restarts the pod when PID 1 exits.
while true; do
    python -m streamlit run app.py \
        --server.port "${APP_PORT}" \
        --server.address "0.0.0.0" \
        --server.headless true || true
    echo "[entrypoint] Streamlit stopped — restarting in 3 s…"
    sleep 3
done
