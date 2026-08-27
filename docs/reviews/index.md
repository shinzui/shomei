---
okf_version: "0.2"
---

# Shōmei Reviews

This bundle records commit-pinned reviews of Shōmei artifacts under the shared
[`assurance.reviews`](mori://shinzui/okf-profiles/profiles/reviews) profile. Each review is one
examination of one subject at one immutable commit. Findings that need action belong in the
owning bug-report or improvement-request bundle; the review records what was examined and its
outcome.

## Files

- [`profile.dhall`](profile.dhall) pins the published shared profile.

## Authoring a review

Allocate the next stable handle before adding a review document:

```sh
okf id list docs/reviews --profile docs/reviews/profile.dhall
okf id next docs/reviews --profile docs/reviews/profile.dhall REV
```

Use the most specific canonical `mori://` URI available for `subject`, record a full 40-character
`reviewedSha`, and state whether the review covered the full subject or only an incremental range.
An incremental review also records `baseSha` and should link `previousReview` so the review history
forms a chain.

After adding or changing a review, update [`log.md`](log.md) and run:

```sh
just reviews-validate
```

## Reviews

The first sweep, at `ee00382509c6cf4b3db2a3c87ff0bd029932c770` (2026-08-27), read every shipped
package with a security and performance emphasis, because Shōmei is the authentication half of
the two-tier story whose authorization half is [en](mori://shinzui/en). REV-1 carries the
cross-cutting analysis and the grade; REV-2 through REV-10 carry per-package depth, so the next
review of one package starts from its own record.

- [REV-1 — Shōmei security and performance baseline at the first Hackage release](project-security-and-performance-baseline.md) — The fundamentals hold, but a delegated or machine token can be laundered through `/oauth/authorize` into a full session, an SMTP rejection persists live reset tokens, Argon2 work escapes its limiter, second factors are unthrottled, and the downstream JWKS template cannot use TLS; changes requested.
- [REV-2 — shomei-core workflows under a security and performance lens](shomei-core-security-and-performance.md) — Session, rotation, one-time-token, and claims invariants hold; `/oauth/authorize` accepts delegated and machine tokens, second-factor failures are uncounted, token exchange ignores session liveness, and lockout is read-then-act; changes requested.
- [REV-3 — shomei-jwt signing, verification, JWKS, and key protection](shomei-jwt-security-and-performance.md) — No forgery or confusion path; zero clock skew, timing-annotated ES256, and an unenforced single-active-key invariant; changes requested.
- [REV-4 — shomei-webauthn ceremony interpreter and the pinned webauthn fork](shomei-webauthn-security.md) — Primitives delegated correctly and the fork's patch is confined; passwordless login inherits the step-up's `preferred` user-verification policy; changes requested.
- [REV-5 — shomei-postgres interpreters, transactions, hashing, and the sweeper](shomei-postgres-security-and-performance.md) — Parameterized, CAS-shaped, and indexed; `HashPassword`'s Argon2 thunk escapes the limiter inside `Pool.use`, counters are unconditional, reset tails are not transactional; changes requested.
- [REV-6 — shomei-migrations schema and the pg-migrate embedding](shomei-migrations-schema-review.md) — Idempotent, search_path-safe, and impossible to leave out of the manifest; missing unique indexes, CHECK constraints, and a version floor; changes requested.
- [REV-7 — shomei-servant combinators, auth handler, CSRF, OAuth endpoints, and admin API](shomei-servant-security-and-performance.md) — Combinators enforce and the verifier honours `sessionCheckMode`; `/oauth/authorize` accepts any verifying token, OAuth refresh rotates unauthenticated at the bespoke endpoint, revoke is cross-client; changes requested.
- [REV-8 — shomei-server runtime, middleware, key loading, notifiers, and the admin CLI](shomei-server-security-and-performance.md) — Key handling and logging hygiene hold; an SMTP DATA-stage rejection persists the raw reset token, per-IP defences collapse behind a proxy, and the embedding entry point ships no runtime stack; changes requested.
- [REV-9 — shomei-client credential handling and admin wrappers](shomei-client-security.md) — Bearer-only, TLS by scheme, routes derived from the API; `Token` derives `Show`; commented.
- [REV-10 — microservice-auth-stack downstream verification template](microservice-auth-stack-jwks-template.md) — The cache's documented properties hold; the manager cannot speak TLS, `max-age` is unclamped, unknown keys never trigger a refresh, and the en recipe sends no API key; changes requested.
