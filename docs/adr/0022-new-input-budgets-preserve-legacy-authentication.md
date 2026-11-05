---
type: Architecture Decision Record
title: New input budgets preserve legacy authentication
description: New identity writes have finite size budgets while compatibility readers preserve existing identities and malformed password requests consume no proof budget.
docId: ADR-22
status: Accepted
date: 2026-11-05
timestamp: 2026-11-05T14:56:07Z
originatingPlan: docs/plans/63-bound-authentication-inputs-and-passkey-enrollment.md
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-05T14:56:07Z
---

# New input budgets preserve legacy authentication

## Context

Unlimited text increases normalization, hashing and storage cost. Applying a new limit to
persisted principals would strand existing accounts. The owner explicitly chose legacy login
compatibility on 2026-11-05.

## Decision

New login IDs and display names have a 256 Unicode code point ceiling; new emails have a
254 UTF-8 byte ceiling. Passkey labels, roles and scopes have a 128 code point ceiling, with
existing character vocabularies retained. New identity constructors and JSON decoders enforce
the limit. Signup revalidates identities even when supplied by a compatibility parser.
Persisted user, credential and audit snapshots use explicit compatibility decoders. Password
login and recovery lookup also accept existing long identities, without truncation or rename.

PostgreSQL triggers validate new or changed fields. Unchanged legacy values remain valid
when security state, password hashes, counters or verification timestamps change. This avoids
the PostgreSQL behavior where even a NOT VALID CHECK rejects an unchanged legacy field on
an unrelated update. A read-only report returns aggregate counts without identity values.

Passwords have a hard ceiling of 256 code points, including login and current-password proof
at change. Oversized login passwords fail with the existing HTTP 400 weak_password code before
lookup, real/dummy hashing, attempt accounting or audit. ADR-5 applies to credential proofs;
malformed request shapes are not proofs. Edge throttling still applies. Normal-sized failed
proofs retain their constant hashing work and abuse accounting. Legacy passwords beyond the
ceiling require a normal password reset; password bytes are never truncated.

## Consequences

New-value JSON is intentionally stricter. Snapshot decoders are separate compatibility APIs
and must never be used as validation for new writes. Operators should run the count report
before rollout. Rolling code back retains the additive trigger migration and its write limits.
