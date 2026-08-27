---
title: "shomei-admin operations CLI"
type: Capability
description: "Bootstrap and operate a deployment from the box: run migrations, rotate and rewrap signing keys, create users, define and grant roles, manage OAuth and service-account credentials, query the audit log, and sweep dead rows."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-19
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-server
interface:
  - shomei-admin
  - shomei-migrate
requires:
  - CAP-6
evidence:
  - kind: test
    resource: shomei-server/test/Admin/Main.hs
    proves: Every command family driven against a real database - migrate, the key lifecycle and rewrap, users create with default roles, the roles round-trip, service accounts, OAuth clients, audit queries, and sweep - including that each refusal path writes nothing.
  - kind: guide
    resource: docs/user/deployment.md
    proves: The command reference and the operator runbook.
---

# `shomei-admin` operations CLI

**Builds on:** [CAP-6 — postgreSQL persistence with embedded, composable migrations](postgresql-persistence-and-migrations.md).

The bootstrap path for a deployment that has no users, no roles, and no signing key yet — and the
break-glass path afterwards.

```bash
export DATABASE_URL="host=$PGHOST dbname=shomei user=$(id -un)"
shomei-admin migrate
shomei-admin keys generate          # prints a kid
shomei-admin keys activate <kid>
printf '%s\n' "$BOOTSTRAP_PASSWORD" | shomei-admin users create --email admin@example.com --email-verified
shomei-admin roles grant --user <user-id> --role admin
```

Eight command families: `migrate`, `keys` (generate/activate/retire/revoke/list/rewrap), `users`,
`roles` (define/list-defined/allow/disallow/show/grant/revoke/list), `service-accounts`,
`oauth-clients`, `audit` (events/user/session/count), and `sweep`. `shomei-migrate` is a separate,
smaller executable for pipelines that only need the schema applied.

Refusals are loud and atomic: granting an undefined role, creating a user with an undefined
default role, rotating an unknown client id, or rewrapping with the wrong old KEK all exit
non-zero **having written nothing**.

User creation reads its password from stdin or `--password-file`, never `argv`, and applies the
same Dhall password/breach policy as server signup. Database diagnostics retain only a safe
category and optional SQLSTATE.

## Limits

- It talks to the **database directly**, not to a running server, so it needs `DATABASE_URL` and
  network access to PostgreSQL — and it bypasses whatever the HTTP layer would have enforced.
- Secrets it prints (a service-account secret, an OAuth client secret, recovery-style material)
  are shown exactly once and land in the operator's terminal and shell history. There is no
  `--output-file` or vault integration.
- Only `audit` has a `--json` flag (NDJSON). Every other command prints for humans, so scripting
  against them means parsing formatted text.
- `users create` is the only user operation here; suspend, reinstate, and delete are HTTP-only
  ([CAP-18](admin-http-api.md)).
