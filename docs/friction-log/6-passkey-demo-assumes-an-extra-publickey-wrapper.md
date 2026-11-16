---
type: Friction Entry
title: "Passkey demo assumes an extra publicKey wrapper"
description: "The demo and browser-check instructions expected options.publicKey although HTTP begin responses contain the creation or request options directly."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-16T15:56:20Z"
frictionId: FRIC-6
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/shomei"
affects: "mori://shinzui/shomei"
plan: "docs/plans/74-require-discoverable-credentials-for-passwordless-passkey-login.md"
workaround: "Pass the unchanged response options as publicKey to the JSON wrapper; correct the demo and documentation as part of browser acceptance."
resolution: "Corrected demo enrollment and step-up calls, user documentation, and the plan browser snippet to pass direct server options into the wrapper."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-16T15:56:52Z"
    change: "Resolve the extra-wrapper mismatch encountered during browser acceptance."
---
# Passkey demo assumes an extra publicKey wrapper

## Attempted

Run browser enrollment against raw registration begin options using the documented demo wrapper.

## Encountered

The browser failed before credential creation because options.publicKey was undefined; handler and interpreter inspection confirmed the direct options shape.

```text
TypeError: Cannot read properties of undefined (reading authenticatorSelection)
```

## Workaround

Pass the unchanged response options as publicKey to the JSON wrapper; correct the demo and documentation as part of browser acceptance.
