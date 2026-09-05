# scripts/

One folder for every day-to-day command.

| command | what it does |
| ------- | ------------ |
| `./scripts/up.sh` | start Postgres, the WebSocket adapter, and the web client |
| `./scripts/migrate.sh` | apply `database/migrations/*.sql` to a running database |
| `./scripts/new-secrets.sh` | write a company `.env` (no demo passwords) |
| `./scripts/packages.sh` | Style Dictionary, SDKs, Stencil, Flutter facades, API specs |

```bash
./scripts/up.sh
./scripts/packages.sh            # everything
./scripts/packages.sh tokens     # Style Dictionary only
./scripts/packages.sh clients    # TypeScript + JavaScript
./scripts/packages.sh components # tokens, then web components
./scripts/packages.sh api        # REST / gRPC specs → site/docs/specs/
```

Details: [packages/README.md](../packages/README.md).

License: [AGPL-3.0-or-later](../LICENSE). Catalog: [docs/sdk.md](../docs/sdk.md), [docs/styles.md](../docs/styles.md). API page: [docs/api.md](../docs/api.md).
