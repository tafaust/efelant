# Repository

Everything sits in one of seven places.

```text
efelant/
├── app/                 Flutter messenger (uses packages/flutter)
├── database/            Core SQL, extensions, web-gateway, tests
├── packages/            tokens, clients, Stencil, Flutter SDK
├── site/                static landing + HTML docs (no React)
├── deploy/              nginx, Caddy, Traefik, Helm, Kustomize
├── docs/                markdown source of truth
├── LICENSE              GNU AGPL-3.0-or-later
└── scripts/             how you start and regenerate things
```

Compose files stay at the root so `docker compose` is one hop:

```text
docker-compose.yml           local stack (:8080 web, :5432 postgres)
docker-compose.caddy.yml     company overlay (Caddy TLS, Postgres unpublished)
docker-compose.traefik.yml   same split with Traefik
docker-compose.site.yml      marketing site only (:8090)
```

## Where to look

| you want | go here |
| -------- | ------- |
| Start the messenger | `./scripts/up.sh` → http://localhost:8080 |
| SQL API / RLS / events | `database/init/`, `database/migrations/` |
| REST / gRPC workers | `database/extensions/` · spec catalog [api.md](api.md) |
| Browser transport | `database/web-gateway/` (no business logic) |
| Style Dictionary | `packages/tokens/` then `./scripts/packages.sh tokens` — catalog: [styles.md](styles.md) |
| Web components | `packages/web-components/` then `./scripts/packages.sh components` |
| TypeScript / JS SDKs | `packages/ts-client/`, `packages/js-client/` — [sdk.md](sdk.md) |
| Embeddable Flutter widgets | `packages/flutter/` |
| Brand tiles | `media/brand/tiles/` |
| Production cluster | `deploy/kustomize/overlays/{dev,prod,prod-no-stackgres}` |

Do not add an application server. Do not put tenant rules in the gateway.
