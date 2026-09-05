# Embedding Efelant

Host applications do not model tickets, claims, or orders inside Efelant. They attach communication to an opaque context.

```text
Conversation + Context + Event
```

## Flutter

```dart
EfelantConversation(
  tenantId: tenantId,
  context: EfelantContext(
    type: 'access_request',
    externalId: accessRequestId,
  ),
)
```

Activity feed:

```dart
EfelantContextFeed(
  tenantId: tenantId,
  context: EfelantContext(type: 'access_request', externalId: accessRequestId),
  events: events,
)
```

`EfelantClient` in `packages/flutter` (`efelant_flutter`) calls the same SQL functions as the standalone app. The messenger in `app/` depends on that package and on Style Dictionary tokens.

Stencil has no official Flutter output target ([framework wrappers](https://stenciljs.com/docs/overview) are React / Angular / Vue / Ember). This repo generates Dart facades from Stencil `docs-json` (`packages/web-components/scripts/generate-flutter.mjs`) so host apps keep the same prop names as `<efelant-*>`.

```bash
./scripts/packages.sh              # tokens → clients → Stencil → Flutter facades
./scripts/packages.sh tokens       # Style Dictionary only
./scripts/packages.sh components   # tokens, then Stencil + Flutter facades
```

Package surfaces and component props: [sdk.md](sdk.md). Tokens and themes: [styles.md](styles.md). Regen: [packages/README.md](../packages/README.md).

The messenger in `app/` remains a first-class product.

## Web components

```html
<efelant-conversation tenant-id="..." context-type="access_request" external-id="AR-123">
</efelant-conversation>
<efelant-context-feed tenant-id="..." context-type="access_request" external-id="AR-123">
</efelant-context-feed>
```

Components consume `@efelant/client` and `@efelant/tokens` CSS variables. They work from plain HTML, Vue, Angular, and Svelte as custom elements (and React if you wrap them yourself — this repo does not ship a React layer). Set `data-efelant-theme="primary"` or `"secondary"` on a parent.

```html
<script type="module" src="@efelant/client-js/dist/efelant.esm.js"></script>
```

A vanilla JS bundle lives in `packages/js-client` (`@efelant/client-js`) next to the TypeScript client.

Stencil UI is not pixel-shared with Flutter. Shared contracts are event names, models, and generated tokens.

## TypeScript

```ts
import { EfelantClient, createGatewayTransport } from "@efelant/client";

const client = new EfelantClient({
  transport: createGatewayTransport("/ws"),
});
await client.resume(token);
const opened = await client.openContext(tenantId, {
  type: "access_request",
  externalId: "AR-123",
});
const events = await client.syncEvents({
  conversationId: opened.conversationId,
  lastSequence: 0,
});
```

Browsers cannot speak the PostgreSQL wire protocol. Use the gateway. Native Flutter and other server-side clients may connect to PostgreSQL directly.

`createMemoryTransport()` implements the same SQL function names in memory. The landing-page demo switches Memory, local `createGatewayTransport('ws://127.0.0.1:8080/ws')`, or a custom self-hosted URL. After login it lists tenants from `auth.list_tenants`.

## REST and gRPC

Third-party runtimes that cannot speak PostgreSQL use the `efelant_rest` and `efelant_grpc` extensions. They are background workers, not an application server. See [api.md](api.md).

```bash
curl -s http://localhost:18080/v1/contexts \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tenant_id":"…","type":"access_request","external_id":"AR-123"}'
```

In-process hosts should still call `efelant.open_context` / `efelant.publish_status` in the same SQL transaction as the business update.

## Gateway policy

The WebSocket adapter in `database/web-gateway` is optional transport. REST/gRPC are optional PostgreSQL extensions. None of them contain tenant rules or business logic. Authorization stays in PostgreSQL.
