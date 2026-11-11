# Dockerfile — Build a VidFlow container image for Kubernetes / VM deployment.
#
# Build:
#   docker build -t your-registry/vidflow:latest .
#
# Run locally (HTTP, no SSL — use behind nginx/Ingress):
#   docker run -d --name vidflow \
#     -p 8501:8501 -p 8502:8502 \
#     -e NO_SSL=1 \
#     -e VIDFLOW_INTERNAL_BASE_URL=http://localhost:8502 \
#     -v $(pwd)/screen_recordings:/app/screen_recordings \
#     your-registry/vidflow:latest
#
# Run with self-signed HTTPS on a VM:
#   docker run -d --name vidflow \
#     -p 8501:8501 -p 8502:8502 \
#     -e VIDFLOW_DOMAIN=hclswl2learninghub \
#     -e VIDFLOW_INTERNAL_BASE_URL=https://hclswl2learninghub/api \
#     -v $(pwd)/screen_recordings:/app/screen_recordings \
#     your-registry/vidflow:latest

FROM python:3.12-slim

# ── System dependencies ───────────────────────────────────────────────────────
# ffmpeg     : core video/audio processing
# espeak-ng  : offline TTS fallback on Linux (pyttsx3 backend)
# libsndfile1: audio file I/O (some TTS libs need it)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        espeak-ng \
        libsndfile1 \
        curl \
    && rm -rf /var/lib/apt/lists/*

# ── Application directory ─────────────────────────────────────────────────────
WORKDIR /app

# ── Python dependencies ───────────────────────────────────────────────────────
# Copy only requirements first to leverage Docker layer cache:
# as long as requirements.txt doesn't change, this layer is reused.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ── Copy application code ─────────────────────────────────────────────────────
COPY app.py video_core.py ollama_client.py media_import.py gen_cert.py ./
COPY .streamlit/ ./.streamlit/

# ── Pre-create output directories so volume mounts work correctly ─────────────
RUN mkdir -p \
        screen_recordings \
        trimmed_videos \
        merged_videos \
        "video+narrated" \
        audio \
        audio_edits \
        uploads \
        voice_library \
        video_webcam_overlay

# ── Expose ports ──────────────────────────────────────────────────────────────
# 8501 — Streamlit UI
# 8502 — Internal API server (trim drag-handle + screen recording save)
EXPOSE 8501 8502
ENV VIDFLOW_INTERNAL_BIND=0.0.0.0

# ── Entrypoint ────────────────────────────────────────────────────────────────
# Use a small entrypoint script so we can:
#   1. Conditionally generate a TLS cert (skipped when NO_SSL=1)
#   2. Start Streamlit bound to 0.0.0.0

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
