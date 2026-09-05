#!/bin/bash
set -euo pipefail

# Named 002z_* so locale-aware glob order stays after 002_roles.sql
# (underscore is ignored in en_US.utf8, so 002b_* ran first).

APP_PASSWORD="${EFELANT_APP_PASSWORD:-efelant_app_dev_password}"
MIGRATOR_PASSWORD="${EFELANT_MIGRATOR_PASSWORD:-efelant_migrator_dev_password}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=app_password="$APP_PASSWORD" \
  --set=migrator_password="$MIGRATOR_PASSWORD" <<'SQL'
ALTER ROLE efelant_app PASSWORD :'app_password';
ALTER ROLE efelant_migrator PASSWORD :'migrator_password';
SQL
