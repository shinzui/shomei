---
type: Architecture Decision Record
title: Runtime configuration is open strict and synchronized
description: Dhall record completion keeps partial files evolvable while unknown keys fail closed and a test keeps the schema equal to the loader.
docId: ADR-8
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T20:50:03Z
originatingPlan: docs/plans/56-bound-password-hashing-for-real-and-refuse-to-boot-on-unsafe-configuration.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T20:50:03Z
---

# Runtime configuration is open strict and synchronized

## Context

Shōmei accepts a partial Dhall file and overlays environment variables on its built-in defaults.
The original schema was a closed record whose required fields made extension breaking, so the
loader grew twenty settings the schema could not express. At the same time, Aeson's default record
decoder ignored unknown keys. An operator could misspell a security-sensitive setting, receive no
error, and boot with an unintended default.

The loader's Haskell `FileConfig`, the Dhall schema, its example, and the deployment guide are all
views of the same public configuration surface. Relying on review to keep those views synchronized
already failed.

## Decision

The Dhall schema exports `{ Type, default }`. Every `Type` field is `Optional`, and `default`
contains the corresponding `None`. Configuration files use record completion such as
`Shomei::{ port = Some 8080 }`; omitted fields inherit `None`, including keys added by later
versions. The Haskell loader then supplies the runtime defaults, preserving one authoritative
location for behavior defaults.

`FileConfig` rejects unknown JSON fields. Enumerated security policies are parsed strictly, and
cross-field invariants that cannot be represented by the flat schema are checked before database
pool acquisition. Every loader key must be added to `config/shomei-types.dhall` and documented in
the same commit.

The configuration suite renders the schema's completed default with `dhall-to-json
--preserve-null` and compares its field names with the JSON representation of an empty
`FileConfig`. This both type-checks `default` against `Type` and makes schema/loader drift a failing
test. Normal config loading does not preserve nulls, so completed `None` fields remain absent from
the rendered deployment JSON.

## Consequences

Existing unannotated partial files continue to work. Files annotated with the old closed record
must switch once to the `Shomei::{ ... }` completion form and wrap supplied values in `Some`.
Thereafter, adding another optional key does not require editing those files.

Misspelled or obsolete keys now stop startup instead of silently selecting a default. Changes to
the configuration surface require coordinated schema and documentation edits, and the focused
configuration test provides a mechanical guard for the schema half of that rule.

The schema intentionally describes shape, not every semantic invariant. Numeric ranges, enum
membership, non-empty origin sets, and relationships between settings remain named boot checks in
the loader.

## Alternatives rejected

Keeping the closed schema and periodically copying new fields into it was rejected because it had
already drifted and every added record field broke annotated files. Removing the schema annotation
was rejected because it would give up Dhall's type checking at the operator boundary.

Duplicating all Haskell runtime defaults in Dhall was rejected because two authoritative default
sets could diverge. Allowing unknown fields for forward compatibility was rejected because the
usual failure is a typo in a security control, and an older binary cannot safely infer the meaning
of a newer key. Reflection-free source parsing was rejected for the drift test because
`--preserve-null` exposes the checked completed record through the converter's stable JSON surface.
