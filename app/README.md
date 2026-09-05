# efelant Flutter client

The supported way to run web is the compose stack: Postgres, the WebSocket adapter, and a built Flutter web client behind nginx.

```bash
# from the repository root
./scripts/up.sh
# open http://localhost:8080
```

Native builds still talk to PostgreSQL over the wire protocol:

```bash
cd app
flutter run
```

`flutter run -d chrome` against a running stack uses `ws://localhost:5433` (the published adapter). The packaged web client uses same-origin `/ws`.

See the root [README](../README.md) for company deploy, credentials, and tests.

License: [AGPL-3.0-or-later](../LICENSE).
