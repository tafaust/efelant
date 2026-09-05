#!/bin/bash
set -euo pipefail

CERT_DIR="${PGDATA:-/var/lib/postgresql/data}/../certs"
CERT_DIR="/var/lib/postgresql/certs"

mkdir -p "$CERT_DIR"

if [ ! -f "$CERT_DIR/server.crt" ] || [ ! -f "$CERT_DIR/server.key" ]; then
  openssl req -new -x509 -days 3650 -nodes -text \
    -out "$CERT_DIR/server.crt" \
    -keyout "$CERT_DIR/server.key" \
    -subj "/CN=efelant-postgres"
fi

chmod 600 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"
chown postgres:postgres "$CERT_DIR/server.crt" "$CERT_DIR/server.key"

exec docker-entrypoint.sh "$@"
