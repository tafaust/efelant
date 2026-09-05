# Use cases

Efelant is a PostgreSQL-native communication platform. These are supported shapes of the same core — not separate products.

## 1. Standalone messenger

People sign in, start direct or group conversations, and exchange messages. The built-in `standalone` tenant is created automatically. The Flutter app in `app/` is this product.

## 2. Embedded communication

An existing application shows a conversation next to a ticket, claim, meter, or order. Efelant does not need the host's tables. The host passes a context:

```text
tenant_id + type + external_id
```

## 3. Contextual discussion

Same as embedding, with a durable timeline so status changes, assignments, and human messages share one sequence.

Typical context types: `ticket`, `project`, `claim`, `meter`, `access_request`, `work_order`, `order`.

## 4. Activity feed

`EfelantContextFeed` / `efelant.sync_context_events` renders the timeline without requiring a full chat chrome.

## 5. Customer support

A support workspace is a tenant. Each ticket is a context. Agents and customers are tenant members. Messages stay in the conversation; status events (`open`, `waiting`, `resolved`) are `status.changed`.

## 6. Operational collaboration

Field or plant systems attach a context to a work order or meter. Presence, receipts, and the event stream stay in PostgreSQL so operators can resume from `last_sequence` after a reconnect.

## 7. Transactional status communication

The business update and the user-visible event commit together:

```sql
BEGIN;

UPDATE access_requests
SET status = 'approved'
WHERE id = 'AR-123';

SELECT efelant.publish_status(
  p_tenant_id => '...',
  p_context_type => 'access_request',
  p_external_id => 'AR-123',
  p_status => 'approved',
  p_message => 'Access request approved',
  p_metadata => '{}'::jsonb
);

COMMIT;
```

If the update rolls back, the Efelant event is not visible. LISTEN/NOTIFY only announces that durable rows exist.

A host that cannot share the database transaction uses the REST or gRPC extensions with an API client token. Same functions, separate request. See [api.md](api.md).

## 8. B2B organization messaging

Each customer organization is a `platform.tenants` row. Users may belong to several tenants. `auth.select_tenant` sets the session GUC. Cross-tenant reads and writes are rejected by functions and RLS.
