# Third-party API (REST and gRPC)

Host applications that cannot open a PostgreSQL socket still call the same SQL. REST and gRPC are **PostgreSQL extensions** (`efelant_rest`, `efelant_grpc`). They parse the protocol and run `api.handle_http` / `api.handle_grpc`. There is no FastAPI, Connect-Go, or other application server.

```text
Third-party app
   │ HTTP/1.1 JSON          :18080   efelant_rest
   │ Connect / gRPC-JSON    :18081   efelant_grpc
   ▼
PostgreSQL background workers
   │ SELECT api.handle_* (...)
   ▼
auth.* / efelant.* / api.*     (RLS + SECURITY DEFINER)
```

Native and in-process hosts should keep calling SQL in the same transaction as their business write. Use HTTP/gRPC when the caller is another language runtime or a SaaS integration.

## Listeners

| Extension | Port | Protocol |
| --------- | ---- | -------- |
| `efelant_rest` | `18080` (`EFELANT_REST_PORT`) | REST, OpenAPI at `/v1/openapi.json` |
| `efelant_grpc` | `18081` (`EFELANT_GRPC_PORT`) | Connect / gRPC-JSON over HTTP/1.1 |

Both must be listed in `shared_preload_libraries` (Compose already does this). Proto: `GET /v1/efelant.proto` or `api.protobuf()`.

The REST section on `site/docs/api.html` is a read-only Swagger UI over that OpenAPI file (descriptions, parameters, status codes; no Try it out). Regenerate with:

```bash
./scripts/packages.sh api
```

That writes `site/docs/specs/openapi.json`, `site/docs/specs/efelant.proto`, and `site/docs/specs/api.json`. Live from a running cluster: `GET /v1/openapi.json` and `GET /v1/efelant.proto`.

gRPC here is the Connect JSON mapping (`POST /efelant.v1.Efelant/OpenContext`). Same handler as binary gRPC would use. HTTP/2 + protobuf framing is not implemented; add a framing-only change in the extension if you need it. Do not add a sidecar.

## Auth

```http
Authorization: Bearer <token>
```

- A user session token from `auth.login` / `auth.register` (human integration, full scopes).
- An API client token from `POST /v1/tenants/{tenantId}/clients` (shown once, prefix `efl_`, ten-year session).

API clients are tenant-scoped service users. Only tenant `owner` / `admin` can create or revoke them.

| Scope | Used by |
| ----- | ------- |
| `tenants:read` | list / select tenant |
| `contexts:read` | get context |
| `contexts:write` | open context |
| `events:read` | sync |
| `events:write` | publish event / status |
| `clients:write` | manage API clients (humans) |

## REST

```bash
# public
curl -s http://localhost:18080/health
curl -s http://localhost:18080/v1/openapi.json

# as a person (session token) then as an integration
curl -s http://localhost:18080/v1/contexts \
  -H "Authorization: Bearer $SESSION" \
  -H "Content-Type: application/json" \
  -d "{\"tenant_id\":\"$TENANT\",\"type\":\"ticket\",\"external_id\":\"T-1\"}"

curl -s http://localhost:18080/v1/tenants/$TENANT/clients \
  -H "Authorization: Bearer $SESSION" \
  -H "Content-Type: application/json" \
  -d '{"name":"erp"}'
# store token once

curl -s http://localhost:18080/v1/tenants/$TENANT/contexts/ticket/T-1/status \
  -H "Authorization: Bearer $EFL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status":"approved","message":"ok"}'
```

## gRPC (Connect JSON)

```bash
curl -s http://localhost:18081/efelant.v1.Efelant/Health \
  -H "Content-Type: application/json" \
  -d '{}'

curl -s http://localhost:18081/efelant.v1.Efelant/PublishStatus \
  -H "Authorization: Bearer $EFL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tenant_id":"…","type":"ticket","external_id":"T-1","status":"approved"}'
```

## SQL (same operations, no HTTP)

```sql
SELECT * FROM api.handle_http(
  'GET', '/v1/tenants', '',
  jsonb_build_object('authorization', 'Bearer ' || :token),
  NULL
);

SELECT * FROM api.create_client(:tenant_id, 'erp', NULL);
SELECT * FROM api.handle_grpc(
  'efelant.v1.Efelant', 'OpenContext',
  jsonb_build_object('authorization', 'Bearer ' || :token),
  jsonb_build_object('tenant_id', :tenant_id, 'type', 'ticket', 'external_id', 'T-1')
);
```

`efelant.publish_status` from a host role inside an existing transaction is still the right path when you share the database.
