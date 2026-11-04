#!/bin/sh
# Runs LiteLLM locally in Docker, exposing Vertex AI Claude on http://localhost:4000/v1
#
# Requires docker/.env containing:  LITELLM_MASTER_KEY=sk-...
#   echo "LITELLM_MASTER_KEY=sk-$(openssl rand -hex 32)" > docker/.env
set -e
cd "$(dirname "$0")"

CREDS="${GOOGLE_CREDS_FILE:-$HOME/.config/gcloud/application_default_credentials.json}"
[ -f .env ] || { echo "Missing docker/.env with LITELLM_MASTER_KEY" >&2; exit 1; }
[ -f "$CREDS" ] || { echo "Missing Google credentials at $CREDS (run: gcloud auth application-default login)" >&2; exit 1; }

docker rm -f litellm 2>/dev/null || true
docker run -d --name litellm --restart unless-stopped -p 4000:4000 \
  --env-file .env \
  -e GOOGLE_APPLICATION_CREDENTIALS=/creds/adc.json \
  -v "$CREDS:/creds/adc.json:ro" \
  -v "$PWD/config.yaml:/app/config.yaml:ro" \
  ghcr.io/berriai/litellm:main-stable --config /app/config.yaml --port 4000
