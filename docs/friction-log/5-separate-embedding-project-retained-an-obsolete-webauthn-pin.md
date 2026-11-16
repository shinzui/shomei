---
type: Friction Entry
title: "Separate embedding project retained an obsolete WebAuthn pin"
description: "The separately solved en embedding project retained a fork pin incompatible with the current Shomei library, blocking the required embedding build."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-16T15:08:50Z"
frictionId: FRIC-5
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shomei"
affects: "mori://shinzui/shomei"
plan: "docs/plans/72-make-oauth-errors-protocol-consistent-across-handlers-and-middleware.md"
workaround: "Mirror the root cabal.project released WebAuthn configuration and narrow time relaxation into the separate example project."
resolution: "The separate example now mirrors the root released WebAuthn settings and just build-embedded-with-en passes."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-16T15:11:25Z"
    change: "Removed the stale fork pin and mirrored the root narrow time relaxation; the required embedding build succeeds."
---
# Separate embedding project retained an obsolete WebAuthn pin

## Attempted

nix develop --command just build-embedded-with-en

## Encountered

The example selected webauthn 0.11.0.0 while shomei-webauthn requires webauthn >=0.12 && <0.13.

```text
Cabal-7107: rejecting webauthn-0.12.0.0 (constraint from user target requires ==0.11.0.0); rejecting webauthn-0.11.0.0 (conflict: shomei-webauthn => webauthn>=0.12 && <0.13)
```

## Workaround

Mirror the root cabal.project released WebAuthn configuration and narrow time relaxation into the separate example project.
