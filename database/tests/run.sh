#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

export EFELANT_DB_HOST="${EFELANT_DB_HOST:-localhost}"
export EFELANT_DB_PORT="${EFELANT_DB_PORT:-5432}"
export EFELANT_DB_NAME="${EFELANT_DB_NAME:-efelant}"
export EFELANT_DB_USER="${EFELANT_DB_USER:-efelant_app}"
export EFELANT_DB_PASSWORD="${EFELANT_DB_PASSWORD:-efelant_app_dev_password}"
export POSTGRES_USER="${POSTGRES_USER:-postgres}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-efelant_dev_postgres}"

echo "waiting for PostgreSQL on ${EFELANT_DB_HOST}:${EFELANT_DB_PORT}..."
for _ in $(seq 1 60); do
  if docker compose exec -T postgres pg_isready -U postgres -d efelant >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

VENV="${ROOT}/database/tests/.venv"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "${VENV}/bin/activate"
python3 -m pip install --quiet -r database/tests/requirements.txt
python3 database/tests/run_tests.py
