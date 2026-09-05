# packages/

Shared design system and clients. Core stays in PostgreSQL. These packages are how hosts embed Efelant.

```text
tokens  →  Style Dictionary
   │         CSS / JS / Dart
   │         site/css/tokens.css
   │         web-components/src/global/tokens.css
   ▼
ts-client  →  @efelant/client
js-client  →  @efelant/client-js   (bundles ts-client)
   ▼
web-components  →  Stencil <efelant-*>
   │                 + Flutter facades
   ▼
flutter  →  efelant_flutter
```

## One command

From the repository root (Node 20+):

```bash
./scripts/packages.sh
```

| target | command | output |
| ------ | ------- | ------ |
| Style Dictionary | `./scripts/packages.sh tokens` | CSS, JS, `tokens.g.dart`, copies into Stencil + `site/` |
| SDKs | `./scripts/packages.sh clients` | `@efelant/client` + `@efelant/client-js` |
| Web components | `./scripts/packages.sh components` | Stencil build + Flutter facades (runs tokens first) |

`./scripts/packages.sh` with no argument runs **tokens → clients → components**.

## Manual (same order)

```bash
cd packages/tokens && npm i && npm run build
cd ../ts-client && npm i && npm run build
cd ../js-client && npm i && npm run build
cd ../web-components && npm i && npm run build
```

Edit sources, never generated files:

| edit | leave alone |
| ---- | ----------- |
| `tokens/tokens/*.json` | `tokens/dist/`, `site/css/tokens.css`, `flutter/lib/src/generated/tokens.g.dart` |
| `web-components/src/` | `web-components/dist/`, `flutter/lib/src/generated/stencil_widgets.g.dart` |
| `ts-client/src/` | `ts-client/dist/`, `js-client/dist/` |

Themes: `data-efelant-theme="primary"` (navy) or `"secondary"` (paper / copper).

`createMemoryTransport()` in `@efelant/client` is the same function API without PostgreSQL (used by the landing-page demo).

See [docs/embedding.md](../docs/embedding.md), [docs/sdk.md](../docs/sdk.md), and [docs/styles.md](../docs/styles.md). The HTML catalog is `site/docs/styles.html` — there is no Storybook.

License: [AGPL-3.0-or-later](../LICENSE).
