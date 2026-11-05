---
type: Architecture Decision Record
title: TOTP envelopes bind row identity and require offline conversion
description: TOTP AES-GCM envelopes authenticate both persisted identifiers and legacy rows require explicit resumable offline conversion before runtime startup.
docId: ADR-20
status: Accepted
date: 2026-11-05
timestamp: 2026-11-05T13:18:00Z
originatingPlan: docs/plans/62-bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes.md
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-05T13:18:00Z
---

# TOTP envelopes bind row identity and require offline conversion

## Context

Encryption with an empty authenticated context prevents reading a database dump but lets a
database writer copy a valid secret into another credential. Pending enrollments carry the
same secret material as confirmed factors. Re-enrollment replaces the persisted credential ID,
so the authenticated identity must match the upsert result rather than an earlier row.

## Decision

The authoritative `envelope_version` column distinguishes legacy version 0 from bound version 1.
Version 1 also carries the six-byte `STOTP` plus byte 1 marker. AES-256-GCM authenticates
`shomei:totp:aes256gcm:v1:` followed by the canonical credential and user TypeIDs in that order.
Both identifiers have a fixed width of 31 ASCII bytes. Every write draws a fresh 96-bit nonce;
the remaining envelope is nonce, ciphertext, and a 128-bit tag. Marker, version and authentication
failures never trigger legacy decoding. Pending and confirmed rows follow the same rules.

Normal interpreters read version 1 only. Shared server assembly refuses startup if legacy or
unknown versions remain. `shomei-admin totp migrate-envelopes --check` reads only version counts
and needs no encryption key. Conversion requires stopped writers, a matching database/key backup,
and the existing deployment key. It decrypts and encrypts at most 100 rows outside a transaction,
then acquires a transaction-scoped converter lock and compares the original identities, version
and ciphertext before replacing each row. Only this explicit converter can decrypt version 0.

## Consequences

Copying ciphertext between accounts or credentials fails authentication. Conversion is resumable
between batches and repeated runs leave version 1 rows untouched. A wrong key or unreadable row
aborts preparation before any writes in that batch. Concurrent changes cannot be overwritten by
a stale converter snapshot. Operators must stop every writer; the lock coordinates converters
and does not claim to fence older binaries.

Conversion cannot detect a transplant that happened before this binding existed: it binds the
associations in the chosen database snapshot. Backup provenance matters. Old binaries cannot
read bound envelopes; rollback requires restoring the matching pre-conversion backup while
writers remain stopped. A permanent permissive fallback was rejected because it preserves the
transplant vulnerability and makes a partially migrated deployment silently unsafe.
