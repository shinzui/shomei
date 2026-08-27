---
okf_version: "0.2"
---

# Shōmei Architecture Decisions

This bundle records durable architecture decisions under the shared
[`architecture-decisions`](mori://shinzui/okf-profiles/profiles/architecture-decisions) profile.

## Files

- [`profile.dhall`](profile.dhall) pins the published shared profile.

## Authoring a decision

Allocate the next stable handle before adding a decision:

```sh
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
```

After adding or changing a decision, update [`log.md`](log.md) and run:

```sh
just adr-validate
```

## Architecture decisions

- [ADR-1 — Sessions carry their provenance and only an interactive session may authorize a client](0001-only-an-interactive-session-may-authorize-a-client.md) — Every session records whether a human established it, and OAuth authorization codes are minted only for live interactive sessions.
