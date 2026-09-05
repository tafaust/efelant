#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "created .env from .env.example (development passwords)"
fi

echo "starting postgres, web-gateway, and the web client..."
docker compose up -d --build

PORT="$(grep -E '^EFELANT_WEB_PORT=' .env 2>/dev/null | cut -d= -f2- || true)"
PORT="${PORT:-8080}"
echo "web:  http://localhost:${PORT}"
echo "db:   localhost:${EFELANT_DB_PORT:-5432}"
