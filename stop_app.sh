#!/usr/bin/env bash
# stop_app.sh — Stop a running VidFlow instance started by start_app.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PID_FILE="vidflow.pid"

if [[ ! -f "$PID_FILE" ]]; then
    echo "[WARN] vidflow.pid not found — trying to find Streamlit process by name..."
    pkill -f "streamlit run app.py" 2>/dev/null && echo "[INFO] Stopped." || echo "[WARN] No running VidFlow process found."
    exit 0
fi

PID=$(cat "$PID_FILE")

if kill -0 "$PID" 2>/dev/null; then
    echo "[INFO] Stopping VidFlow (PID ${PID})..."
    kill "$PID"
    # Wait up to 10 seconds for graceful shutdown
    for i in $(seq 1 10); do
        if ! kill -0 "$PID" 2>/dev/null; then
            echo "[INFO] VidFlow stopped."
            break
        fi
        sleep 1
    done
    # Force kill if still running
    if kill -0 "$PID" 2>/dev/null; then
        echo "[WARN] Graceful stop timed out — sending SIGKILL..."
        kill -9 "$PID" 2>/dev/null || true
    fi
else
    echo "[WARN] Process ${PID} is not running (already stopped?)."
fi

rm -f "$PID_FILE"
echo "[INFO] Done."
