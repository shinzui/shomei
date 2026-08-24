---
title: "OAuth2 client-credentials machine tokens"
type: Capability
description: "Issue scoped machine tokens through the standard OAuth2 client_credentials grant, backed by service accounts an operator creates, rotates, and revokes at runtime."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-13
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
  - shomei-postgres
  - shomei-servant
interface:
  - Shomei.ServiceAccount.ClientCredentials.Workflow
  - Shomei.ServiceAccount.Store
  - Shomei.OAuth.Api
requires:
  - CAP-4
  - CAP-6
evidence:
  - kind: test
    resource: shomei-core/test/Shomei/ServiceAccount/ClientCredentials/WorkflowSpec.hs
    proves: Scope narrowing, the omitted-scope default, and what a revoked or wrongly-authenticated account gets.
  - kind: test
    resource: shomei-servant/test/Main.hs
    proves: POST /oauth/token over both client_secret_basic and client_secret_post, answering RFC 6749 errors rather than problem documents.
  - kind: test
    resource: shomei-server/test/Shomei/Server/E2ESpec.hs
    proves: A service account created through the CLI gets a token from the live server that authenticates a request and lands a service_token_issued audit event.
  - kind: test
    resource: shomei-server/test/Admin/Main.hs
    proves: create yields a working secret while storing only its digest; rotate kills the old secret immediately; revoke refuses everything after.
  - kind: guide
    resource: docs/user/machine-tokens.md
    proves: The end-to-end recipe for a connector or agent, including the security checklist.
---

# OAuth2 client-credentials machine tokens

**Builds on:** [CAP-4 — jWT access tokens with a published JWKS](jwt-access-tokens-and-jwks.md), [CAP-6 — postgreSQL persistence with embedded, composable migrations](postgresql-persistence-and-migrations.md).

```bash
curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d 'grant_type=client_credentials' -d 'scope=kawa:ingest' \
  http://localhost:8080/oauth/token
```

This is RFC 6749 §4.4 at the conventional unversioned path, accepting
`application/x-www-form-urlencoded` and both standard client-authentication methods
(`client_secret_basic` and `client_secret_post`), so a stock OAuth2 client — Spring, ASP.NET,
Go's `clientcredentials`, `curl` — fetches a token with zero Shōmei-specific code. Omitting
`scope` grants every scope the account is allowed; the response always echoes what was granted.

The accounts behind it are **database-backed and managed at runtime**, not static configuration:

```bash
# prints the generated client id and the secret, once
shomei-admin service-accounts create --display-name 'rei connector' --scope kawa:ingest
shomei-admin service-accounts rotate-secret <client-id>
shomei-admin service-accounts revoke <client-id>
```

The secret is 32 bytes of CSPRNG output shown **exactly once**; only its SHA-256 digest is
stored. The issued token is refresh-less, signed by the same key machinery as any other Shōmei
token, and verifies against the same JWKS.

## Limits

- Errors here are RFC 6749 `{"error", "error_description"}` objects, **not** the problem-details
  envelope every other endpoint uses ([CAP-11](problem-details-and-openapi.md)). That boundary is
  permanent.
- The secret cannot be recovered. A lost secret means `rotate-secret`, which invalidates the old
  one immediately with no overlap window — plan the rollout.
- Tokens are refresh-less by design: a machine re-authenticates with its credentials rather than
  refreshing. There is no revocation of an outstanding machine token short of revoking the
  signing key; revoking the account stops the *next* issuance.
- The earlier `POST /v1/auth/service-token` path with config-defined accounts is **gone** from
  the served tree, not merely deprecated. `/oauth/token` is the only issuance path.
- `--scope` on `create` fixes the account's allowed set. Widening it later means editing the row
  directly; there is no `service-accounts allow` command.
