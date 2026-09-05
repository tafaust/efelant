# Production readiness

Honest snapshot before you use it: what is solid, what is schema-only, and what is missing before B2B production.

## Verdict

**Local / single-tenant preview: usable.**  
**B2B production: not yet.** Tenancy exists in SQL. The product around it does not.

| Area | State |
| ---- | ----- |
| Function API + RLS | Ready for a guarded company deploy |
| Standalone messenger | Ready as a trial, not a finished cryptosystem |
| Multitenancy | Schema + isolation tests. No tenant switcher, invites, or billing |
| Embed SDKs | Contracts exist. Stencil shells still need a host-supplied client |
| REST / gRPC extensions | SQL handlers + BGWorkers. Connect JSON, not HTTP/2 protobuf framing |
| E2EE | First step. Static conversation key. Web keys in browser storage |
| Scale | Connection-per-device. No LISTEN-safe pooler. Hundreds, not millions |
| Ops | Compose + Caddy or Traefik. Helm Job + Kustomize overlays. HA is StackGres / CNPG / managed Postgres |

## B2B

`docs/use-cases.md` §8 is the intended shape: one `platform.tenants` row per customer organization, `auth.select_tenant`, RLS rejection of cross-tenant access.

What exists today:

- `platform.tenants`, `tenant_members`, `contexts`, `events`
- `tenant_id` on conversations and direct pairs
- `auth.list_tenants` / `select_tenant` / `current_tenant_id`
- DB tests for standalone + cross-tenant isolation

What does not:

- Tenant admin UI or switcher in `app/` (the Flutter app can set the host; it cannot switch tenants)
- Per-tenant usernames (usernames are still global)
- Invites, SCIM, SSO, audit export (API clients exist; no admin UI)
- Billing / entitlements
- A host-app cookbook beyond `docs/embedding.md` and `docs/api.md`

You can use Efelant **inside** a B2B host that already has orgs, if that host maps `org_id → tenant_id` and calls `open_context` / `publish_status`. You cannot treat “Efelant for Teams” as a finished product yet.

Security notes (gateway, keys, tenants, E2EE status): [security.md](security.md).

## Multitenancy progress

Done in `013_platform.sql`: tenant table, membership roles (`owner`, `admin`, `member`), session GUC, function checks, event stream scoped by conversation (and thus tenant).

Still open: global username uniqueness, no tenant provisioning API for a host without SQL access, no default-tenant picker after login in Flutter.

## What besides a landing page

Shipped in `site/` (static HTML, no React): landing, quickstart, use cases, this status page.

Still needed before a public B2B launch:

1. SQL function reference (generated from comments)
2. Embedding cookbook with a real host example
3. A CISO-ready threat model beyond [security.md](security.md)
4. Versioned function API (see [changelog.md](changelog.md) / GitHub Releases)
5. Tenant admin + switcher
6. Observability defaults (the gateway already has `/health`; no metrics contract)
