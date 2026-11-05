---
type: Friction Entry
title: "SMTP dependency no longer builds with current network"
description: "The existing SMTP release failed to compile after dependency resolution selected network 3.2.11."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-05T13:21:23Z"
frictionId: FRIC-2
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shomei"
affects: "https://github.com/haskell-github-trust/smtp-mail"
plan: "docs/plans/62-bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes.md"
workaround: "Verified Hackage latest 0.5.0.2 and its released source fixing network >=3.2.10; upstream has no matching release tag. Update the lower bound and package index instead of constraining network backwards."
resolution: "The server build and runtime tests pass with released smtp-mail 0.5.0.2; the dependency lower bound requires that fix."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-05T13:31:38Z"
    change: "Select the released build fix verified against Hackage source and upstream history."
---
# SMTP dependency no longer builds with current network

## Attempted

cabal build shomei-admin shomei-server -j1

## Encountered

smtp-mail 0.5.0.1 imports getHostName from both Network.Socket and Network.BSD under network 3.2.11.

```text
Network/Mail/SMTP.hs:116:68: Ambiguous occurrence getHostName
```

## Workaround

Verified Hackage latest 0.5.0.2 and its released source fixing network >=3.2.10; upstream has no matching release tag. Update the lower bound and package index instead of constraining network backwards.
