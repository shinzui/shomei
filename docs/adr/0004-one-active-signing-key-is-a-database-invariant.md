---
type: Architecture Decision Record
title: One active signing key is a database invariant
description: PostgreSQL enforces one active signing key, and every replacement retires and activates atomically while retaining retired overlap keys.
docId: ADR-4
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T17:02:48Z
originatingPlan: docs/plans/53-harden-jwt-verification-and-make-the-signing-key-state-machine-atomic.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T17:02:48Z
---

# One active signing key is a database invariant

## Context

Signing-key rotation must change the signer without interrupting verification of tokens minted by
the previous key. The old implementation inserted or activated one row and retired prior rows in
separate statements. A crash or concurrent command could therefore leave zero or multiple active
keys, forcing the server to guess which private key represented operator intent.

Application-only checks cannot protect against hand-written SQL, another process, or a failure
between statements. The invariant belongs with the shared signing-key table, while the domain port
must make the same atomic operation available to non-SQL interpreters.

## Decision

PostgreSQL enforces at most one row whose status is `active` with the partial unique index
`shomei_signing_keys_one_active`. Migration `0032-shomei-signing-keys-one-active.sql` first makes
legacy data conform: it retains the row the old loader would have selected by activation time,
creation time, and key ID, and retires every other active row.

`SigningKeyStore.ReplaceActiveSigningKey` retires every active key with one timestamp, then inserts
or promotes the replacement with that same activation timestamp. The PostgreSQL interpreter runs
both statements in one transaction; the in-memory interpreter performs one strict world update.
The admin CLI uses an equivalent transaction for `keys activate`, and rewrap writes every
pre-encrypted row in one transaction.

Every lifecycle transition stamps its corresponding nullable column: `activated_at`, `retired_at`,
or `revoked_at`. Retired keys remain published and trusted for the overlap window; revoked and
pending keys do not. The server refuses to assemble key material if it observes multiple active
rows and names the missing invariant instead of choosing a winner.

## Consequences

A database statement that attempts to create a second active row fails with SQLSTATE `23505`, even
when it bypasses Shōmei. Activation either retires the previous signer and promotes the new one in
full or changes nothing. Outstanding tokens continue to verify because retirement does not remove
the old public key from the JWKS.

The invariant is “at most one”; a deliberate retirement can still leave no active signer. Startup
then fails, while a running server keeps its last known-good key material and fails readiness until
an operator activates a pending key. Lifecycle timestamps provide an auditable state history but
are not themselves an event log.

## Alternatives rejected

Selecting the newest active row was rejected because it hides corruption and makes application
ordering the security boundary. A table-wide lock without a unique index was rejected because
hand-written writes could still violate the invariant after the lock holder exits.

Publishing pending keys to stage a future activation was left for a separate change. This decision
preserves the existing zero-downtime contract by publishing active and retired keys only.
