---
title: "Transport-agnostic authentication core"
type: Capability
description: "Build authentication on domain types, effect ports, and workflows that carry no HTTP, database, or JWT dependency, with an in-memory interpreter for every port."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-1
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
interface:
  - Shomei.Session.Authentication.Workflow
  - Shomei.Account.Lifecycle.Workflow
  - Shomei.Session.Workflow
  - Shomei.Account.User.Store
  - Shomei.Session.Store
  - Shomei.Test.InMemory
evidence:
  - kind: test
    resource: shomei-core/test/Shomei/AccountSpec.hs
    proves: The signup/login/refresh workflows run end to end against the in-memory interpreter with no database, HTTP server, or signing key present.
  - kind: module
    resource: shomei-core/src/Shomei/Test/InMemory.hs
    proves: An interpreter for every port Shomei defines, exposed from the library so a consumer's own tests can use it as a double.
  - kind: guide
    resource: docs/user/architecture.md
    proves: The port/interpreter layering and which package is allowed to depend on what.
---

# Transport-agnostic authentication core

`shomei-core` holds the whole authentication domain — users, login identifiers, credentials,
sessions, refresh tokens, signing keys, audit events — plus the workflows over them, expressed
against `effectful` ports rather than any concrete backend. The library depends on no Servant,
WAI, PostgreSQL, or JWT package.

A consumer adopts this when they want Shōmei's authentication *decisions* but their own
transport or storage: call the workflow, supply interpreters for the ports it uses.

```haskell
import Shomei.Session.Authentication.Workflow (login)
import Shomei.Test.InMemory (emptyWorld, runInMemory)

-- Every port `login` demands is an effect; `runInMemory` supplies all of them at once.
ref <- newIORef (emptyWorld startTime)
result <- runInMemory ref (login config clientContext loginCommand)
```

`Shomei.Test.InMemory` is a shipped module, not test-suite scaffolding: it exports a `World`
plus a `run*` interpreter for each of the ~20 ports (`runUserStore`, `runSessionStore`,
`runRoleStore`, `runPasskeyStore`, `runTotpCredentialStore`, `runNotifier`, `runTokenSigner`, …),
so a host can exercise its own code against Shōmei's workflows with no PostgreSQL.

## Limits

- The in-memory interpreters are for tests and demos. They hold state in `IORef`s, are lost on
  process exit, and make no attempt at the concurrency guarantees the PostgreSQL interpreters
  provide — the compare-and-swap semantics that make refresh-token reuse detection safe are a
  property of [CAP-6](postgresql-persistence-and-migrations.md), not of the port.
- PostgreSQL is the only production interpreter set that ships. The ports are pluggable in
  principle, but nobody has proven a second backend here.
- The password hasher and breach checker are ports; `shomei-core` on its own gives you a stub
  hasher. Real Argon2id hashing arrives with `shomei-postgres`.
