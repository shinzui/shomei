---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Admit base64 2.0 in shomei-core](admit-base64-2-in-shomei-core.md) - Widen shomei-core's base64 bound so consumers whose cohort already resolves base64 2.0 through tls can depend on shomei-core and shomei-jwt without an allow-newer.
- [Close residual findings from the August security and performance reviews](close-residual-review-findings.md) - Give every residual review subitem a fix with evidence or an explicit documented disposition.
- [Add diagnostic broker and probe identities and coarse scopes to Shomei](diagnostic-identities-and-scopes.md) - Authenticate diagnostic protocol participants and bound broker and per-cluster probe capabilities.
- [Stop revoking sessions when a rotated refresh token never reached the client](recover-undelivered-refresh-rotations.md) - Treat a replay of a spent refresh token whose replacement was never used as a retry, while keeping theft detection.
- [Add scoped service-token issuance](scoped-service-token-issuance.md) - Issue service tokens with bounded coarse scopes for authenticated Kikan service hops.

