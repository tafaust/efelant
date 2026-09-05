#!/usr/bin/env bash
# Apply incremental SQL in database/migrations/ to a running PostgreSQL.
# Safe to re-run: each file is recorded in internal.schema_migrations.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

DB_NAME="${POSTGRES_DB:-efelant}"
DB_USER="${POSTGRES_USER:-postgres}"

run_psql() {
  if docker compose ps --status running postgres >/dev/null 2>&1; then
    docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" "$@"
  else
    psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" "$@"
  fi
}

run_psql <<'SQL'
CREATE TABLE IF NOT EXISTS internal.schema_migrations (
  id text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
SQL

shopt -s nullglob
for file in "$ROOT"/database/migrations/*.sql; do
  id="$(basename "$file" .sql)"
  already="$(run_psql -Atqc "SELECT 1 FROM internal.schema_migrations WHERE id = '${id}'" || true)"
  if [[ "$already" == "1" ]]; then
    echo "skip ${id}"
    continue
  fi
  echo "apply ${id}"
  run_psql -f - < "$file"
done

echo "migrations up to date"
