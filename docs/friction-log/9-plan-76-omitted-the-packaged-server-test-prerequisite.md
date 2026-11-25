---
type: Friction Entry
title: "Plan 76 omitted the packaged server test prerequisite"
description: "The validation commands ran the PostgreSQL cases but failed the packaged OAuth check on a checkout without a built server executable."
generated:
  by: "codex-cli/gpt-6.2-astra"
  at: "2026-11-25T14:32:31Z"
frictionId: FRIC-9
status: "resolved"
impact: detour
kind: documentation
origin: "mori://shinzui/shomei"
affects: "mori://shinzui/shomei/plans/76-expose-session-kind-through-oauth-token-introspection"
plan: "docs/plans/76-expose-session-kind-through-oauth-token-introspection.md"
workaround: "Build shomei-server:exe:shomei-server in the same Cabal configuration before running the server suite."
resolution: "Plan 76 now builds the server executable before running the packaged OAuth check, and the complete server suite passed."
amended:
  - by: "codex-cli/gpt-6.2-astra"
    at: "2026-11-25T14:37:24Z"
    change: "Documented and verified the missing executable build prerequisite."
---
# Plan 76 omitted the packaged server test prerequisite

## Attempted

Run cabal test shomei-server:test:shomei-server-test in the project shell as directed by the plan.

## Encountered

The packaged Hurl test could not start its server.

```text
Build exe:shomei-server before running the packaged OAuth test
```

## Workaround

Build shomei-server:exe:shomei-server in the same Cabal configuration before running the server suite.
