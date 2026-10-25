#!/usr/bin/env bash
# Starts Kokoro, a free local neural text-to-speech server, for Miss Minute's natural voice.
# Serves an OpenAI-compatible API at http://localhost:8880/v1 (Kokoro-FastAPI).
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker isn't installed. Get Docker Desktop (free for personal use): https://www.docker.com/products/docker-desktop/" >&2
  exit 1
fi

NAME=miss-minute-kokoro
if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "Kokoro is already running on http://localhost:8880"
  exit 0
fi
docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "==> starting Kokoro (first run downloads the model, ~1-2 GB)"
docker run -d --name "$NAME" --restart unless-stopped -p 8880:8880 ghcr.io/remsky/kokoro-fastapi-cpu:latest
echo "Kokoro is starting on http://localhost:8880 — give it a minute, then click Check in Miss Minute → Settings → Voice."
