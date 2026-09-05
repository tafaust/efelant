# Efelant is a PostgreSQL-native communication platform

**The communication layer for PostgreSQL applications.**

Efelant Core runs entirely in PostgreSQL. Platform adapters may be deployed where a client cannot speak the PostgreSQL wire protocol directly. REST and gRPC for third-party apps are PostgreSQL extensions (`efelant_rest`, `efelant_grpc`) that call `api.handle_http` / `api.handle_grpc`. See [api.md](api.md).

This is not only a standalone messenger. The same core supports embedded discussion next to a domain object, activity feeds, and transactional status events that commit with the host application's data.

## What Core owns

PostgreSQL owns:

- tenants and tenant membership
- conversations, members, messages, attachments
- generic **contexts** (`type` + `external_id` + `metadata`)
- a durable per-conversation **event** sequence
- authentication, authorization, RLS
- LISTEN/NOTIFY as a wake-up signal only

Clients synchronize with `conversation_id` + `last_sequence`. Timestamps and NOTIFY are not the source of truth.

## Security order

```text
tenant isolation
→ tenant membership
→ conversation / context authorization
```

`efelant_app` has no table DML grants. Host applications that share the database may call `efelant.publish_status` from their own role inside an existing transaction. Browser clients still go through the session API and RLS.

## Product shapes

| Shape | How you use it |
| ----- | -------------- |
| Standalone messenger | Flutter app in `app/`, default tenant `standalone` |
| Embedded conversation | `EfelantConversation` / `<efelant-conversation>` on a domain object |
| Activity feed | `EfelantContextFeed` / `<efelant-context-feed>` |
| Transactional status | `efelant.publish_status` in the same SQL transaction as the business update |

See [use cases](use-cases.md), [embedding](embedding.md), [sdk](sdk.md), [styles](styles.md), [deployment](deployment.md), [core](core.md), and [readiness](readiness.md). Folder map: [repository.md](repository.md). Marketing / docs HTML (no React): `site/`.
