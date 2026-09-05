# Security policy

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/tafaust/efelant/security/advisories/new) so the report stays private until a fix is ready.

Do not open a public issue for a security problem.

We aim to acknowledge reports within a few days.

## Scope

This repository is the self-hosted Efelant stack: PostgreSQL, the web-gateway, the Flutter client, and deploy manifests.

Please report:

- Authentication or session bypass
- Cross-tenant data access
- Secret or private-key exposure
- Remote code execution in the gateway or in default deploy configs
- Supply-chain issues in published images or Helm charts

Please do not report:

- Missing features listed in [docs/readiness.md](../docs/readiness.md)
- Issues that only exist after treating the `efelant_app` database password as a secret (that credential is a public connection key; see [docs/security.md](../docs/security.md))

Product security model: [docs/security.md](../docs/security.md).
