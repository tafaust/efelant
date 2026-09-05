# SDKs

Hosts embed Efelant through packages. Core stays in PostgreSQL. There is no application server and no React layer from this repo.

There is no Storybook. The visual catalog for tokens and component chrome is [styles](styles.md) (`site/docs/styles.html`).

| package | import | what it is |
| ------- | ------ | ---------- |
| `@efelant/tokens` | CSS / JS / Dart | Style Dictionary output |
| `@efelant/client` | TypeScript | function API over a transport |
| `@efelant/client-js` | ESM / CJS / `Efelant` global | bundled `@efelant/client` |
| `@efelant/components` | `<efelant-*>` | Stencil custom elements |
| `efelant_flutter` | Dart | widgets + `EfelantClient` |

From the repository root (Node 20+):

```bash
./scripts/packages.sh              # tokens → clients → Stencil → Flutter facades
./scripts/packages.sh clients      # TypeScript + JavaScript only
./scripts/packages.sh components   # tokens, then Stencil + Flutter facades
```

Sources vs generated files: [packages/README.md](../packages/README.md). How to attach a conversation to a domain object: [embedding.md](embedding.md).

## TypeScript — `@efelant/client`

```ts
import { EfelantClient, createGatewayTransport } from "@efelant/client";

const client = new EfelantClient({
  transport: createGatewayTransport("/ws"),
});
await client.resume(token);
```

Browsers cannot speak the PostgreSQL wire protocol. Use `createGatewayTransport`. Native and server-side hosts may supply a transport that runs SQL directly.

`createMemoryTransport()` implements the same function names in memory. `createMemoryHub()` is one store with many `open()` connections. The landing-page demo is an in-memory Alice and Bob pair. The Flutter app sets the live host in settings.

| method | SQL |
| ------ | --- |
| `login` / `resume` / `logout` | `auth.login` / `auth.resume_session` / `auth.logout` |
| `listTenants` / `selectTenant` / `currentTenantId` | `auth.list_tenants` / `auth.select_tenant` / `auth.current_tenant_id` |
| `openContext` | `efelant.open_context` |
| `syncEvents` / `syncContext` | `efelant.sync_events` / `efelant.sync_context_events` |
| `getConversations` / `getMessages` / `sendMessage` | `chat.get_conversations` / `chat.get_messages` / `chat.send_message` |

`cursor(conversationId)` returns `{ conversationId, lastSequence }`. Errors map through `EfelantError`, `EfelantAuthError`, `EfelantForbiddenError`.

## JavaScript — `@efelant/client-js`

Same client, bundled:

```html
<script type="module" src="@efelant/client-js/dist/efelant.esm.js"></script>
```

| file | format |
| ---- | ------ |
| `dist/efelant.esm.js` | ESM |
| `dist/efelant.cjs.js` | CommonJS |
| `dist/efelant.global.js` | browser global |

## Web components — `@efelant/components`

Custom elements. They work from HTML, Vue, Angular, and Svelte. Wrap them yourself for React; this repo does not ship a React package.

Set `data-efelant-theme="primary"` or `"secondary"` on a parent. Components consume `@efelant/tokens` CSS variables.

| tag | props | events |
| --- | ----- | ------ |
| `<efelant-conversation>` | `tenant-id`, `conversation-id`, `context-type`, `external-id` | — |
| `<efelant-conversation-list>` | `tenant-id` | — |
| `<efelant-context-feed>` | `tenant-id`, `context-type`, `external-id` | — |
| `<efelant-composer>` | `placeholder`, `disabled` | `efelantSend` |
| `<efelant-status-event>` | `status`, `message` | — |
| `<efelant-unread-badge>` | `count` | — |

```html
<efelant-conversation tenant-id="…" context-type="access_request" external-id="AR-123">
  <efelant-composer slot="composer" placeholder="Message…"></efelant-composer>
</efelant-conversation>
```

Slots: `header` and `composer` on `<efelant-conversation>`; default slot is the timeline. List and feed are also slot hosts.

Stencil UI is not pixel-shared with Flutter. Shared contracts are event names, models, and generated tokens. Dart facades come from Stencil `docs-json` (`packages/web-components/scripts/generate-flutter.mjs`).

## Flutter — `efelant_flutter`

The messenger in `app/` depends on this package. Host apps import the same widgets.

```dart
EfelantConversation(
  tenantId: tenantId,
  context: EfelantContext(
    type: 'access_request',
    externalId: accessRequestId,
  ),
)
```

| widget | role |
| ------ | ---- |
| `EfelantConversation` | thread around a context or `conversationId` |
| `EfelantConversationList` | list of conversations |
| `EfelantContextFeed` | activity feed for a context |
| `EfelantComposer` | send box (`onSend`, `placeholder`, `enabled`) |
| `EfelantStatusEvent` | status + message |
| `EfelantUnreadBadge` | unread count |

`EfelantClient` takes a query runner. `buildEfelantTheme(theme: EfelantThemeId.primary)` applies Style Dictionary colors. Generated: `tokens.g.dart`, `stencil_widgets.g.dart`, `catalog.g.dart`.

## REST and gRPC

Runtimes that cannot speak PostgreSQL use the `efelant_rest` and `efelant_grpc` extensions. See [api.md](api.md).
