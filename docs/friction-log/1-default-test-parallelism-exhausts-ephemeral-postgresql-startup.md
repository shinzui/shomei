---
type: Friction Entry
title: "Default test parallelism exhausts ephemeral PostgreSQL startup"
description: "The PostgreSQL suite inherited all RTS capabilities and timed out nine ephemeral servers before tests could run."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-05T13:18:28Z"
frictionId: FRIC-1
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/shomei"
affects: "mori://shinzui/shomei"
plan: "docs/plans/62-bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes.md"
workaround: "Set Tasty concurrency explicitly with --test-options=-j2, independently of the Cabal build job count."
resolution: "Run database acceptance with explicit Tasty -j2; Cabal build parallelism does not bound test-case parallelism."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-05T13:31:37Z"
    change: "The capped-concurrency PostgreSQL suite passed; retain the reproducible command in plan evidence."
---
# Default test parallelism exhausts ephemeral PostgreSQL startup

## Attempted

cabal test shomei-postgres --test-show-details=failures -j1

## Encountered

Nine of 79 cases failed at ephemeral PostgreSQL startup with ConnectionTimeout durationSeconds=60; completed TOTP regressions passed.

## Workaround

Set Tasty concurrency explicitly with --test-options=-j2, independently of the Cabal build job count.
