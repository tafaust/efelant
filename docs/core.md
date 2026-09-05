# Core internals

Architecture, security, the function API, and how clients stay in sync. Product shape: [platform.md](platform.md). HTTP for third parties: [api.md](api.md).

## Architecture

```text
Native Flutter
   │ PostgreSQL wire protocol + TLS
   ▼
PostgreSQL 17
   ├── RLS + FORCE RLS
   ├── stored functions (the API)
   ├── efelant_rest :18080 / efelant_grpc :18081  (extensions; transport only)
   ├── application sessions (not one DB role per human)
   ├── LISTEN / NOTIFY on channel efelant_events
   └── ciphertext + wrapped conversation keys
```

```text
Browser
   │ https://your.domain/          Flutter web (static)
   │ wss://your.domain/ws          same origin
   ▼
nginx or Caddy
   ├── static Flutter build
   └── /ws → web-gateway           protocol adapter only; no business logic
         │ one asyncpg session per tab
         ▼
      PostgreSQL 17
```

Browsers cannot open a raw PostgreSQL TCP socket. `database/web-gateway` is a dumb adapter: one database session per WebSocket so session GUCs and `LISTEN` still work. The client still calls the same SQL functions. Do not put application logic there.

Local compose publishes `:8080` (web) and `:5432` (native). Production compose puts Caddy or Traefik on 80/443 and keeps Postgres off the internet. Apply later SQL with `./scripts/migrate.sh`. Helm: `deploy/helm/efelant`. Kustomize: `deploy/kustomize/overlays/{dev,prod,prod-no-stackgres}` — StackGres is a Kustomize component on prod. Reverse proxy: Caddy (`docker-compose.caddy.yml`) or Traefik (`docker-compose.traefik.yml`). Core is a migration Job, not a permanent app pod.

Clients sync with `conversation_id` + `last_sequence`. LISTEN/NOTIFY only wakes the client.

## End-to-end encryption

This is a first step toward E2EE, not Signal.

| piece | where it lives |
| ----- | -------------- |
| Device X25519 private key | client secure storage only |
| Device X25519 public key | `auth.device_keys` |
| Conversation AES-256-GCM key | client memory after unwrap |
| Per-device wrap of that key | `chat.conversation_key_wraps` |
| Message / attachment bodies | `encrypted_content` / attachment `bytea` |

Wrap format: `1 || eph_pub(32) || nonce(12) || ciphertext+mac`.  
Message format: `1 || nonce(12) || ciphertext+mac`.

PostgreSQL stores ciphertext and wraps. It never sees private keys. The web gateway does not decrypt. A new device must receive a wrap from a device that already has the conversation key; until then the client shows that it is waiting.

This is **not** a Double Ratchet: the conversation key is static, web keys live in browser storage, and database tests may still send plaintext. Treat it as the direction, not a finished cryptosystem.

## Security model

### Roles

| role               | login | used by Flutter | purpose                                      |
| ------------------ | ----- | --------------- | -------------------------------------------- |
| `efelant_owner`    | no    | no              | owns objects, `BYPASSRLS` for DEFINER funcs  |
| `efelant_migrator` | yes   | no              | migrations via `SET ROLE efelant_owner`      |
| `efelant_app`      | yes   | yes             | least-privilege login role                   |

`efelant_app` cannot create objects, cannot bypass RLS, and has **no table DML grants**. It may `USAGE` the `auth`, `chat`, and `realtime` schemas and `EXECUTE` the function API below.

### Trust boundary

The Flutter binary contains the `efelant_app` password. Treat that password as a **public connection credential**, like a published API key.

Real identity is an application session:

1. `auth.login` / `auth.register` returns a raw session token **once**.
2. Only the SHA-256 hash of that token is stored.
3. `auth.resume_session(token)` stores the raw token in the connection GUC `efelant.session_token`.
4. `auth.current_user_id()` hashes that GUC and looks up `auth.sessions`. It does **not** trust a client-supplied `efelant.user_id`.

Anyone who can connect as `efelant_app` can `LISTEN efelant_events`. Notify payloads are metadata only (`type`, ids). Message bodies, tokens, and passwords never go through `NOTIFY`. Authorization is enforced inside functions (and RLS as defense in depth), not by the client filtering events.

### Function API

```text
auth.register
auth.login
auth.logout
auth.resume_session
auth.current_user_id
auth.current_tenant_id
auth.select_tenant
auth.list_tenants
auth.publish_device_key
auth.device_public_keys

efelant.open_context
efelant.get_context
efelant.sync_events
efelant.sync_context_events
efelant.publish_status
efelant.publish_event

chat.create_direct_conversation
chat.create_group
chat.add_member
chat.remove_member
chat.leave_conversation
chat.send_message
chat.edit_message
chat.edit_encrypted_message
chat.delete_message
chat.get_conversations
chat.get_messages
chat.get_messages_after
chat.get_message
chat.get_ciphertexts
chat.mark_read
chat.add_reaction
chat.remove_reaction
chat.upload_attachment
chat.get_attachment
chat.search_users
chat.heartbeat
chat.set_typing
chat.current_device
chat.member_device_keys
chat.put_conversation_key_wrap
chat.get_conversation_key_wrap
chat.has_conversation_key_wraps
```

`SECURITY DEFINER` functions are owned by `efelant_owner`, use a fixed `search_path`, and check membership themselves.

## Synchronization

`LISTEN` is a hint. PostgreSQL remains the source of truth.

Cursor is `(created_at, id)`, not `created_at` alone.

On reconnect the client:

1. resumes the session
2. issues `LISTEN efelant_events` again
3. loads conversations
4. calls `chat.get_messages_after(conversation_id, created_at, id)`
5. upserts by message id
6. drains events that arrived during sync

If a notify is lost, the next cursor fetch still converges. If a notify arrives during sync, it is queued and applied after the cursor fetch so neither side depends on race order.

`client_id` (UUIDv7 from the device) makes `chat.send_message` idempotent across retries.

## Tests

```bash
docker compose up -d --build
./database/tests/run.sh
```

The suite connects as `efelant_app` and covers register/login, RLS-style authorization, idempotent sends, edits, read cursors, LISTEN/NOTIFY, attachment limits, group removal, ciphertext access, and key wraps.

```bash
cd app && flutter test
```

## PostgreSQL extensions

| extension  | why                                      |
| ---------- | ---------------------------------------- |
| `pgcrypto` | bcrypt password hashes, SHA-256, random  |
| `citext`   | case-insensitive usernames               |
| `pg_trgm`  | username search ranking                  |
| `pg_cron`  | expired session / presence / orphan GC   |

If `pg_cron` cannot load, `auth.login` and `chat.heartbeat` still call `internal.purge_expired()` opportunistically.

UUIDv7 is provided as `public.uuidv7()`. PostgreSQL 18 has this built in; on 17 the image ships a pgcrypto-backed polyfill. Passwords use SCRAM-SHA-256 at the protocol layer and bcrypt (`pgcrypto` `bf`) for application passwords.

## Connection scaling

Every interactive Flutter instance holds a PostgreSQL session for queries **and** `LISTEN`. There is no PgBouncer in this project because LISTEN and session GUCs are connection-scoped, and the challenge is PostgreSQL-only.

The web gateway holds one PostgreSQL session per browser tab for the same reason.

Expect on the order of `max_connections` concurrent devices (compose sets 200; `efelant_app` is limited to 100). Mobile networks drop sockets; the client reconnects with exponential backoff (capped at 20 attempts) and restores `LISTEN`. This architecture will not silently scale to millions of always-on clients.

## Production risks

Exposing PostgreSQL to the internet is dangerous. Mitigate inside PostgreSQL; do not add an application server to "fix" the premise. The web gateway is a protocol adapter, not that application server.

| risk                         | mitigation                                              |
| ---------------------------- | ------------------------------------------------------- |
| connection exhaustion        | `CONNECTION LIMIT`, `max_connections`                   |
| credential stuffing          | SCRAM, login throttle (`internal.auth_failures`)        |
| SQL attack surface           | function-only API, no table grants, empty `search_path` |
| long queries                 | `statement_timeout`, `lock_timeout` on `efelant_app`    |
| idle mobile sessions         | `idle_in_transaction_session_timeout`                   |
| DDoS / abuse                 | `pg_hba.conf`, TLS, host firewall                       |
| schema compatibility         | treat functions as the public API                       |
| upgrades                     | migrate via `efelant_migrator`, never the app role      |
| web private keys             | browser storage is weaker than a secure enclave         |

Production **must** use TLS verification (`EFELANT_DB_SSLMODE=verifyFull`) for native clients and `wss://` for web. Do not ship the development passwords.

The image enables `ssl=on` with a self-signed certificate so the stack is TLS-ready. Local compose defaults to `sslmode=disable` for convenience.

## Flutter targets

Supported: Android, iOS, macOS, Windows, Linux (PostgreSQL wire protocol) and web (same-origin `/ws` through nginx/Caddy). `flutter run -d chrome` against a running stack uses the published adapter on `:5433`.
