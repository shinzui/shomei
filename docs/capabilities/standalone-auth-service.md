---
title: "Standalone authentication service"
type: Capability
description: "Run Shomei as its own HTTP service - a warp binary with twelve-factor typed configuration, boot-time validation, a reproducible OCI image, and a one-command local stack."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-20
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-server
interface:
  - shomei-server
  - Shomei.Server.Boot
  - Shomei.Server.Config
requires:
  - CAP-6
  - CAP-7
evidence:
  - kind: test
    resource: shomei-server/test/Shomei/Server/E2ESpec.hs
    proves: The real binary's assembly booted in-process and driven end to end - signup, login, refresh, reuse detection, logout, JWKS, health - plus the OAuth, token-exchange, TOTP, and webhook paths.
  - kind: test
    resource: shomei-server/test/Shomei/Server/ConfigSpec.hs
    proves: A Dhall file is loaded and individual environment variables override it.
  - kind: module
    resource: flake.module.nix
    proves: The reproducible OCI image built from the same pinned dependency closure as the dev shell, with no Docker daemon needed.
  - kind: example
    resource: process-compose.yaml
    proves: A one-command local stack - PostgreSQL on a Unix socket, database creation and migration, a bootstrapped signing key, then the server.
  - kind: guide
    resource: docs/user/deployment.md
    proves: The full configuration reference, the container startup path, and the operator runbook.
---

# Standalone authentication service

**Builds on:** [CAP-6 — postgreSQL persistence with embedded, composable migrations](postgresql-persistence-and-migrations.md), [CAP-7 — embeddable Servant auth API](embeddable-servant-auth-api.md).

```bash
PG_CONNECTION_STRING="host=$PGHOST dbname=shomei user=$(id -un)" shomei-server
```

Configuration is twelve-factor with three layers, lowest to highest: built-in defaults, a typed
**Dhall** file at `$SHOMEI_CONFIG`, then individual `SHOMEI_*` environment variables. Environment
always wins, and the file step is skipped entirely when `SHOMEI_CONFIG` is unset — so the turnkey
path stays a single connection string.

Boot validation is deliberately loud. The server refuses to start when `oidcEnabled` is set
without an absolute issuer, when `totpEnabled` is set without a valid TOTP encryption key, when a
configured default role is not in the registry, or when a pool setting is non-positive. An
invalid configuration fails at boot rather than at the first request that depends on it.

Two container paths ship: `nix build .#dockerImage` produces a reproducible layered image from the
same pinned closure as the dev shell, and a plain `Dockerfile` covers the non-Nix case. The
entrypoint computes `GHCRTS` from the cgroup CPU quota at start-up, because GHC's `-N` sizes
capabilities from the affinity mask and would otherwise run 32 capabilities in a 2-CPU container.

For local work, `process-compose up --no-server` brings up PostgreSQL on a Unix socket, creates
and migrates the database, ensures an active signing key, and runs the server.

## Limits

- **Single instance.** The per-IP request-rate limiter is in-process and in-memory
  ([CAP-21](abuse-protection.md)), so running several replicas multiplies the effective limit.
  There is no shared or distributed rate-limit store.
- Dhall is rendered by shelling out to the **`dhall-to-json` binary**, which must therefore be on
  the path in the container. The image bundles it; a hand-rolled image that omits it will fail to
  read a config file.
- The plain `Dockerfile` is a runtime-only image: it expects the binaries and `dhall-to-json` to
  come from a build stage or a bind-mount. It does not build the workspace.
- `process-compose up` needs `--no-server`, because process-compose's own REST API also defaults
  to port 8080 and would take it first.
- Nothing here provisions TLS. Shōmei speaks plain HTTP and expects a terminating proxy.
