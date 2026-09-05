# Styles

Design tokens live in `packages/tokens/tokens/*.json`. Style Dictionary writes CSS variables, a JS module, and Dart constants, then copies CSS into Stencil and the marketing site.

There is no Storybook. `site/docs/styles.html` is the visual catalog: colors, type, space, radius, and component chrome against the live tokens.

```bash
./scripts/packages.sh tokens
```

| edit | leave alone |
| ---- | ----------- |
| `packages/tokens/tokens/*.json` | `packages/tokens/dist/` |
| | `site/css/tokens.css` |
| | `packages/web-components/src/global/tokens.css` |
| | `packages/flutter/lib/src/generated/tokens.g.dart` |

Pipeline: [packages/README.md](../packages/README.md). SDKs that consume these tokens: [sdk.md](sdk.md).

## Themes

Two themes, one variable set. Name is `data-efelant-theme`.

| value | look |
| ----- | ---- |
| `primary` (default) | navy, indigo accent |
| `secondary` | paper, copper accent |

```html
<body data-efelant-theme="primary">
  …
  <section data-efelant-theme="secondary">copper island</section>
</body>
```

Flutter: `buildEfelantTheme(theme: EfelantThemeId.primary)` or `EfelantThemeId.secondary`.

The site header Light / Dark toggle maps Light → `secondary` and Dark → `primary`.

## CSS variables

Paths become `--ef-*`. `color.bg` → `--ef-color-bg`. Dimensions gain `px` at build time.

### Color (theme)

| token | CSS | primary | secondary |
| ----- | --- | ------- | --------- |
| `color.bg` | `--ef-color-bg` | `#1B263B` | `#F4EFE6` |
| `color.bg-raised` | `--ef-color-bg-raised` | `#243447` | `#E8DFD0` |
| `color.bg-overlay` | `--ef-color-bg-overlay` | `#2F4156` | `#DDD2BE` |
| `color.text` | `--ef-color-text` | `#F2F3F5` | `#1F1A14` |
| `color.text-muted` | `--ef-color-text-muted` | `#B8C0CC` | `#5C5348` |
| `color.border` | `--ef-color-border` | `#3A4A63` | `#C9BBA6` |
| `color.accent` | `--ef-color-accent` | `#5C7CFA` | `#C4622D` |
| `color.accent-soft` | `--ef-color-accent-soft` | `#748FFC` | `#D4844F` |
| `color.accent-contrast` | `--ef-color-accent-contrast` | `#FFFFFF` | `#FFF8F0` |
| `color.mine` | `--ef-color-mine` | `#3B5BDB` | `#C4622D` |
| `color.theirs` | `--ef-color-theirs` | `#2C3A4F` | `#E8DFD0` |
| `color.danger` | `--ef-color-danger` | `#E03131` | `#B42318` |
| `color.ok` | `--ef-color-ok` | `#37B24D` | `#2F6F3E` |

### Space, radius, stroke (shared)

| token | CSS | value |
| ----- | --- | ----- |
| `space.2xs` … `space.3xl` | `--ef-space-2xs` … `--ef-space-3xl` | 4, 8, 12, 16, 24, 32, 48, 72 |
| `radius.sm` / `md` / `lg` / `pill` | `--ef-radius-*` | 8, 16, 24, 999 |
| `stroke.hair` / `thick` | `--ef-stroke-*` | 1, 2 |

### Type (shared)

| token | CSS | value |
| ----- | --- | ----- |
| `font.sans` | `--ef-font-sans` | EfelantSans, IBM Plex Sans, system |
| `font.mono` | `--ef-font-mono` | IBM Plex Mono |
| `font.size.xs` … `3xl` | `--ef-font-size-*` | 12, 14, 16, 20, 28, 40, 56 |
| `font.weight.regular` … `bold` | `--ef-font-weight-*` | 400, 500, 600, 700 |
| `font.line.tight` / `snug` / `body` | `--ef-font-line-*` | 1.15, 1.35, 1.55 |

## Other outputs

| file | consumers |
| ---- | --------- |
| `packages/tokens/dist/css/tokens.css` | both themes concatenated |
| `packages/tokens/dist/js/tokens.js` | `efelantCore`, `efelantPrimary`, `efelantSecondary`, `themes` |
| `packages/flutter/lib/src/generated/tokens.g.dart` | `EfelantTokens`, `EfelantTokensSecondary` |

Do not hand-edit those files. Change JSON, then `./scripts/packages.sh tokens`.
