---
type: Friction Entry
title: "Mori registry requires an unavailable local PostgreSQL service"
description: "Registry discovery failed because the local Sungkyung PostgreSQL socket refused connections."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-16T21:43:25Z"
frictionId: FRIC-8
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/shomei"
affects: "mori://shinzui/mori"
plan: "docs/plans/75-align-the-public-error-catalog-with-served-oauth-responses.md"
workaround: "Used repository-local sources and existing test APIs; this plan needs no dependency API or version changes."
resolution: "No dependency lookup is needed for this plan; local repository APIs suffice. Registry use requires restoring the local database service."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-16T21:43:59Z"
    change: "Accept the local registry outage for this documentation and regression-only plan."
---
# Mori registry requires an unavailable local PostgreSQL service

## Attempted

mori registry list

## Encountered

NotifierConnectError: local PostgreSQL socket connection refused

## Workaround

Used repository-local sources and existing test APIs; this plan needs no dependency API or version changes.
