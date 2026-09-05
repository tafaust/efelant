# Self-host

Run Efelant on hardware or a VM you control. Core is PostgreSQL. The Flutter web client and WebSocket gateway are optional adapters for browsers. There is no application server to operate.

| piece | image | when |
| ----- | ----- | ---- |
| Postgres + SQL + REST/gRPC workers | `ghcr.io/tafaust/efelant/postgres` | always |
| WebSocket adapter | `ghcr.io/tafaust/efelant/web-gateway` | browsers |
| Flutter web | `ghcr.io/tafaust/efelant/web` | standalone messenger UI |
| This docs site | `ghcr.io/tafaust/efelant/site` | optional |

Each image is tagged `0`, `0.1`, `0.1.0`, and `latest`. Commands below pin `0.1.0`. See [GHCR](#ghcr).

Native clients can talk PostgreSQL directly (`efelant_app`, function EXECUTE only). REST `:18080` and gRPC-JSON `:18081` are background workers inside Postgres.

Do **not** invent custom PostgreSQL HA. For production failover use StackGres, CloudNativePG, Patroni, or a managed PostgreSQL service.

## Docker

Single machine, no Compose file. Generate passwords with `./scripts/new-secrets.sh` (or set them yourself). The image entrypoint mints a self-signed cert; pass the same `-c` flags Compose uses so REST/gRPC load.

```bash
docker network create efelant
docker volume create efelant_pgdata

docker run -d --name efelant-postgres --network efelant \
  --restart unless-stopped \
  -v efelant_pgdata:/var/lib/postgresql/data \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e POSTGRES_DB=efelant \
  -e EFELANT_APP_PASSWORD="$EFELANT_APP_PASSWORD" \
  -e EFELANT_MIGRATOR_PASSWORD="$EFELANT_MIGRATOR_PASSWORD" \
  -e EFELANT_SEED=0 \
  -p 5432:5432 -p 18080:18080 -p 18081:18081 \
  ghcr.io/tafaust/efelant/postgres:0.1.0 \
  postgres \
  -c listen_addresses=* \
  -c ssl=on \
  -c ssl_cert_file=/var/lib/postgresql/certs/server.crt \
  -c ssl_key_file=/var/lib/postgresql/certs/server.key \
  -c password_encryption=scram-sha-256 \
  -c shared_preload_libraries=pg_cron,efelant_rest,efelant_grpc \
  -c cron.database_name=efelant

docker run -d --name efelant-web-gateway --network efelant \
  --restart unless-stopped \
  -e EFELANT_DB_HOST=efelant-postgres \
  -e EFELANT_DB_PORT=5432 \
  -e EFELANT_DB_NAME=efelant \
  -e EFELANT_DB_USER=efelant_app \
  -e EFELANT_DB_PASSWORD="$EFELANT_APP_PASSWORD" \
  -e EFELANT_DB_SSLMODE=disable \
  -e EFELANT_WS_PORT=5433 \
  -e EFELANT_WS_ORIGINS=https://chat.example.com \
  -p 5433:5433 \
  ghcr.io/tafaust/efelant/web-gateway:0.1.0

docker run -d --name efelant-web --network efelant \
  --restart unless-stopped \
  -p 8080:80 \
  ghcr.io/tafaust/efelant/web:0.1.0
```

Init SQL in the image runs on first empty volume. Later schema changes: `./scripts/migrate.sh` against that Postgres. Do not publish `5432` on a public NIC.

## Docker Compose

Fastest path on a VM. From the repository root:

```bash
cp .env.example .env          # local trial only
./scripts/up.sh
```

That builds and starts Postgres, web-gateway, and Flutter web. Open `http://localhost:8080`.

Your VM with TLS (Postgres unpublished):

```bash
./scripts/new-secrets.sh
# edit .env: EFELANT_DOMAIN, EFELANT_WS_ORIGINS
docker compose -f docker-compose.yml -f docker-compose.caddy.yml up -d --build
```

Caddy listens on 80/443 for `EFELANT_DOMAIN`. Traefik instead of Caddy:

```bash
docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d --build
```

Set `EFELANT_SEED=0` so development users are not created. Users register in the app.

## Docker Swarm

Same three services, as a stack. Swarm does not build images: pull from GHCR first. `depends_on` conditions and `container_name` are ignored.

```bash
docker pull ghcr.io/tafaust/efelant/postgres:0.1.0
docker pull ghcr.io/tafaust/efelant/web-gateway:0.1.0
docker pull ghcr.io/tafaust/efelant/web:0.1.0
docker tag ghcr.io/tafaust/efelant/postgres:0.1.0 efelant-postgres:0.1.0
docker tag ghcr.io/tafaust/efelant/web-gateway:0.1.0 efelant-web-gateway:0.1.0
docker tag ghcr.io/tafaust/efelant/web:0.1.0 efelant-web:0.1.0
docker stack deploy -c docker-compose.yml efelant
```

Do **not** run a homemade Postgres primary/replica on Swarm. Put the database on a dedicated VM, StackGres, or a managed service, and keep the stack as gateway + web. The Caddy/Traefik overlays use Compose `!reset` for ports; that merge is for Compose, not `docker stack deploy`. For TLS on Swarm, add a published proxy service yourself or run Compose on a single node.

## Kubernetes — Helm

Chart: `deploy/helm/efelant` (also OCI on GHCR). It applies SQL via a Job and can start the browser gateway. It does **not** install PostgreSQL.

```bash
kubectl create namespace efelant
kubectl create secret generic efelant-postgres \
  --namespace efelant \
  --from-literal=password="$POSTGRES_PASSWORD"

helm install efelant oci://ghcr.io/tafaust/efelant/charts/efelant --version 0.1.0 \
  --namespace efelant \
  --set postgres.host=efelant-postgres \
  --set postgres.existingSecret=efelant-postgres \
  --set gateway.enabled=true
```

From a checkout: `helm install efelant ./deploy/helm/efelant -n efelant …`. Values live in `deploy/helm/efelant/values.yaml`. Point `postgres.host` at StackGres, CloudNativePG, or any Postgres that has `pgcrypto`, `citext`, and `pg_trgm`.

## Kubernetes — Kustomize

Manifests in `deploy/kustomize`. Base is namespace, config, secret, migration Job, gateway, and web.

```bash
kubectl apply -k deploy/kustomize/overlays/dev
# single Postgres Deployment + gateway + web

kubectl apply -k deploy/kustomize/overlays/prod
# StackGres component + Traefik, 2 replicas

kubectl apply -k deploy/kustomize/overlays/prod-no-stackgres
# Traefik + 2 replicas, you bring Postgres
```

`deploy/kustomize/components/stackgres` is a component, not an overlay. Edit `secret.yaml` / overlay patches before applying — the checked-in secret is a placeholder.

## Extensions and roles

Required: `pgcrypto`, `citext`, `pg_trgm`. Optional: `pg_cron`. REST/gRPC: `shared_preload_libraries=pg_cron,efelant_rest,efelant_grpc` (already in the Efelant Postgres image command). See [api.md](api.md).

Do not put PostgREST, FastAPI, or a gRPC microservice in front of Core.

| role | purpose |
| ---- | ------- |
| `efelant_owner` | owns objects, DEFINER |
| `efelant_migrator` | applies SQL |
| `efelant_app` | client login, function EXECUTE only |

## GHCR

Push to `main` or a `v*` tag publishes the four images and the Helm chart. Workflow: `.github/workflows/ghcr.yml`. Every image gets these tags:

| tag | tracks |
| --- | ------ |
| `0.1.0` | this patch — pin this |
| `0.1` | current `0.1.x` |
| `0` | current `0.x` |
| `latest` | current `main` |

```bash
docker pull ghcr.io/tafaust/efelant/postgres:0.1.0
docker pull ghcr.io/tafaust/efelant/postgres:0.1
docker pull ghcr.io/tafaust/efelant/postgres:0
docker pull ghcr.io/tafaust/efelant/postgres:latest

docker pull ghcr.io/tafaust/efelant/web-gateway:0.1.0   # also :0.1 :0 :latest
docker pull ghcr.io/tafaust/efelant/web:0.1.0
docker pull ghcr.io/tafaust/efelant/site:0.1.0
```

Helm chart is the patch only: `--version 0.1.0` (`oci://ghcr.io/tafaust/efelant/charts/efelant`). A `v*` git tag republishes the same four image tags as that semver. The first push may create private packages; make them public under GitHub → Packages if the repo is public. Local Compose still builds on your machine.

## Docs site only

Static HTML in `site/`. GitHub Pages: Settings → Pages → GitHub Actions (`.github/workflows/pages.yml`). Custom domain: [efelant.de](https://efelant.de) (`site/CNAME`). `www.efelant.de` redirects once DNS matches.

Rootless nginx:

```bash
docker compose -f docker-compose.site.yml up --build
# http://localhost:8090
```
