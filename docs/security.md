# Security

Honest snapshot of what the gateway sees, where keys live, how tenants isolate, and how far E2EE has come. Product readiness: [readiness.md](readiness.md). Internals: [core.md](core.md).

## Gateway

Browsers cannot open a raw PostgreSQL socket. `database/web-gateway` is a protocol adapter: one asyncpg session per WebSocket so session GUCs and `LISTEN` still work. It has **no application logic**. It does not decrypt message bodies.

Anyone who can connect as `efelant_app` can `LISTEN efelant_events`. Notify payloads are metadata (`type`, ids). Message bodies, tokens, and passwords do not go through `NOTIFY`.

The Flutter binary contains the `efelant_app` password. Treat that as a **public connection credential**, like a published API key. Real identity is an application session token. Only the SHA-256 hash of the token is stored.

## Keys and E2EE

This is a first step, not Signal and not a Double Ratchet.

| piece | where it lives |
| ----- | -------------- |
| Device X25519 private key | client secure storage only |
| Device X25519 public key | `auth.device_keys` |
| Conversation AES-256-GCM key | client memory after unwrap |
| Per-device wrap of that key | `chat.conversation_key_wraps` |
| Message / attachment bodies | `encrypted_content` / attachment `bytea` |

PostgreSQL stores ciphertext and wraps. It never sees private keys. The web gateway does not decrypt. A new device must receive a wrap from a device that already has the conversation key.

The conversation key is static. Web keys live in browser storage. Database tests may still send plaintext.

## Tenants

`platform.tenants` + membership + session GUC. Functions and RLS reject cross-tenant reads. Usernames are still global. The Flutter app can set the host. It cannot switch tenants, invite members, or do SSO.

## What you should not claim yet

Do not tell a CISO this is a finished cryptosystem, a multi-tenant SaaS, or a hosted product. Self-host under AGPL. There is no cloud signup.
