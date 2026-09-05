#!/usr/bin/env bash
# Rebuild design tokens (Style Dictionary), SDKs, web components, and API specs.
#   ./scripts/packages.sh              tokens → clients → stencil → flutter facades → API specs
#   ./scripts/packages.sh tokens       Style Dictionary only
#   ./scripts/packages.sh clients      @efelant/client + @efelant/client-js
#   ./scripts/packages.sh components   tokens first, then Stencil + Flutter facades
#   ./scripts/packages.sh api          REST / gRPC specs from 015_api.sql
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Rebuild design tokens, SDKs, web components, and API specs. Requires Node 20+.

  ./scripts/packages.sh              tokens → clients → stencil → Flutter facades → API specs
  ./scripts/packages.sh tokens       Style Dictionary only
  ./scripts/packages.sh clients      TypeScript + JavaScript clients
  ./scripts/packages.sh components   tokens, then Stencil + Flutter facades
  ./scripts/packages.sh api          REST / gRPC specs for site/docs

Style Dictionary writes:
  packages/tokens/dist/{css,js}/
  packages/web-components/src/global/tokens.css
  packages/flutter/lib/src/generated/tokens.g.dart
  site/css/tokens.css

Stencil also writes:
  packages/flutter/lib/src/generated/{stencil_widgets,catalog}.g.dart

API specs (from database/init/015_api.sql):
  site/docs/specs/{openapi.json,efelant.proto,api.json}
EOF
}

npm_build() {
  local dir="$1"
  echo "==> ${dir}"
  (
    cd "$dir"
    if [ -f package-lock.json ]; then
      npm ci
    else
      npm install
    fi
    npm run build
  )
}

build_tokens() {
  npm_build packages/tokens
}

build_clients() {
  npm_build packages/ts-client
  npm_build packages/js-client
}

build_components() {
  npm_build packages/web-components
}

build_api() {
  echo "==> api spec"
  node "$ROOT/scripts/gen-api-spec.mjs"
}

TARGET="${1:-all}"
case "${TARGET}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

if ! command -v node >/dev/null 2>&1; then
  echo "need Node 20+ (npm) to build packages" >&2
  exit 1
fi

case "${TARGET}" in
  all)
    build_tokens
    build_clients
    build_components
    build_api
    ;;
  tokens)
    build_tokens
    ;;
  clients)
    build_clients
    ;;
  components)
    build_tokens
    build_components
    ;;
  api)
    build_api
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

echo "packages: done (${TARGET})"
