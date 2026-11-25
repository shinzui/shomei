---
type: Friction Entry
title: "The local plan registry cannot resolve the existing IR-1 target"
description: "The request reference validator cannot verify the plan registered in IR-1, requiring verification against the checkout."
generated:
  by: "codex-cli/gpt-6.2-astra"
  at: "2026-11-25T14:39:43Z"
frictionId: FRIC-10
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/shomei"
affects: "mori://shinzui/shomei"
plan: "docs/plans/76-expose-session-kind-through-oauth-token-introspection.md"
workaround: "Verify the targetPlan path, frontmatter id and slug in the checkout. Preserve the canonical reference."
resolution: "The checked-in IR-1 target links to the matching plan ID and slug. The provider contract can be accepted independently of local registry coverage."
amended:
  - by: "codex-cli/gpt-6.2-astra"
    at: "2026-11-25T14:40:04Z"
    change: "Verified the repository target and retained its canonical reference."
---
# The local plan registry cannot resolve the existing IR-1 target

## Attempted

Run mori improvement-requests validate --path . after recording provider acceptance.

## Encountered

Mori reports that the IR-1 target plan is not exactly registered even after mori register --local. Registration reported no extensions.

```text
targetPlan is not an exactly registered plan: mori://shinzui/shomei/plans/76-expose-session-kind-through-oauth-token-introspection
```

## Workaround

Verify the targetPlan path, frontmatter id and slug in the checkout. Preserve the canonical reference.
