---
type: Architecture Decision Record
title: Migration components do not mutate shared namespace state
description: Shomei migration SQL schema-qualifies owned objects and confines lookup-path changes to each migration transaction.
docId: ADR-19
status: Accepted
date: 2026-08-27
timestamp: 2026-08-28T03:03:26Z
originatingPlan: docs/plans/61-make-shomei-migrations-schema-qualified-and-composition-safe.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-28T03:03:26Z
---

# Migration components do not mutate shared namespace state

## Context

Shōmei exposes its database history as a reusable pg-migrate `MigrationComponent`. A host may place
its own components before and after Shōmei in one ordered plan. pg-migrate intentionally runs that
complete plan on one dedicated connection, as defined by
`mori://shinzui/pg-migrate/packages/pg-migrate`. PostgreSQL's ordinary `SET search_path` survives a
transaction commit on that connection, so a component that changes it can silently alter how later
host migrations resolve unqualified names.

Shōmei originally selected `shomei, pg_catalog` and used unqualified relation names. Besides leaking
state across the component boundary, that order allowed application-owned objects in `shomei` to
shadow PostgreSQL built-ins. The issue was found before adoption, when rewriting the embedded SQL
history and its checksums did not invalidate a durable consumer ledger.

## Decision

Every Shōmei migration schema-qualifies every Shōmei-owned table, view, sequence, type, function,
foreign-key target, data-manipulation target, and dropped index. A `CREATE INDEX` qualifies its
parent table rather than its new index name because PostgreSQL creates the index in the table's
schema and rejects a schema-qualified new index name.

Every transactional SQL file contains exactly one canonical preamble after its leading description
comments:

```sql
SET LOCAL search_path = pg_catalog, pg_temp;
```

The local setting ends at commit or rollback. It excludes the application-owned `shomei` schema,
puts PostgreSQL built-ins first, and retains `pg_temp` for temporary objects. Qualification fixes
owned-object identity while the restricted path fixes remaining built-in lookup; neither replaces
the other.

A nontransactional file may omit the preamble only when it uses pg-migrate's leading
`-- pg-migrate: no-transaction` directive. It must contain the one statement required by
pg-migrate, must not mutate `search_path`, and must qualify every non-built-in object directly.

Repository authoring and CI enforce this policy through `just new-migration` and
`just migration-check`. A real PostgreSQL integration test composes a hostile host component before
Shōmei and an unqualified host statement after it, proving the public component boundary rather
than relying only on source scans.

## Consequences

Hosts can compose Shōmei without running it on a separate connection or restoring namespace state
afterward. Shōmei SQL resolves owned relations consistently even when a host leaves a hostile
ambient path, and later host components recover their prior session path after each Shōmei
transaction.

The pre-adoption rewrite changes the exact SQL bytes and pg-migrate checksums for migrations `0001`
through `0036` while preserving their names, order, and resulting schema. Once any released history
has been adopted by a durable database, checksum-bearing migration files are append-only; future
corrections must use new migrations instead of rewriting applied payloads.

The repository checker is deliberately a narrow authoring guard, not a PostgreSQL parser. The
composed-plan integration test remains the behavioral proof, and reviewers still inspect SQL grammar
where relation, index, and constraint qualification rules differ.

## Alternatives rejected

Ordinary session-scoped `SET search_path` was rejected because it leaks across component commits.
Relying on the ambient host path was rejected because object identity would depend on component
order and connection configuration. Adding `shomei` to a transaction-local path without qualifying
objects was rejected because it permits shadowing and obscures ownership. Requiring hosts to apply
Shōmei separately was rejected because the public API promises one explicit, composable migration
plan.
