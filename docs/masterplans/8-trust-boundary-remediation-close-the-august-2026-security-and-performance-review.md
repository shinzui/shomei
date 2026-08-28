---
id: 8
slug: trust-boundary-remediation-close-the-august-2026-security-and-performance-review
title: "Trust-Boundary Remediation: Close the August 2026 Security and Performance Review"
kind: master-plan
created_at: 2026-08-27T03:23:36Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
---

# Trust-Boundary Remediation: Close the August 2026 Security and Performance Review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

On 2026-08-27 a full security-and-performance review of Shōmei at commit
`ee00382509c6cf4b3db2a3c87ff0bd029932c770` was recorded under the `assurance.reviews` OKF
profile as `docs/reviews/` REV-1 (the project read as one) and REV-2 through REV-10 (one record
per shipped package plus the downstream verification template). Its verdict was
*changes-requested*: the fundamentals the July 2026 hardening restored still hold — refresh
rotation is a compare-and-swap, sessions have an absolute deadline, private keys are
envelope-encrypted, the JWKS is public-only, jose refuses every algorithm-confusion path, every
SQL statement is parameterized, `sessionCheckMode` is wired — but the surfaces added since
(OIDC, token exchange, TOTP, notifiers, the embedding entry point, the downstream template)
compose with those fundamentals in ways that break them. One critical and six high findings
survived verification, and every one is a seam between two features that are each correct on
their own.

The framing that matters is the trust model in
[REV-1](../reviews/project-security-and-performance-baseline.md): Shōmei is the authentication
half of a two-tier story whose authorization half is [en](mori://shinzui/en), and en maps every
subject to `user:<JWT sub>`. Everything downstream trusts three edges — the integrity of the
published JWKS, the integrity of `sub`/`act`/`roles`/`scopes`/`permissions`, and the reach of
session revocation. This initiative makes those three edges hold again everywhere, and it
pays down the performance and operability debt the same review found beside them.

After the initiative is complete: a delegated, on-behalf-of, or machine token cannot be turned
into an ordinary session through `GET /oauth/authorize`, because sessions carry their
provenance and non-interactive tokens are refused there; RFC 8693 exchange and delegation see
a revoked session and a suspended operator immediately; OAuth-minted refresh tokens rotate only
through the client that minted them, and a client cannot revoke another client's tokens; a
second-factor guess is counted against the account and throttled like a password guess, and a
stolen access token is not a TOTP oracle; the lockout, the TOTP and passkey counters, and the
password-reset tail are atomic; `HashPassword` runs inside the hashing limiter and a bad Argon2
parameter set refuses to boot; no SMTP or webhook failure can write a one-time token into a log
or an audit row, and no request waits on a mail relay; the per-IP defences work behind a
reverse proxy; a JWT verifier tolerates a few seconds of clock skew, accepts only the two
configured algorithms, and selects its key by `kid`; exactly one signing key can be active;
an embedding host gets the same key reload, body cap, and rate limiter the standalone server
has, and the downstream template fetches its JWKS over TLS; and every sentence in
`docs/user/security.md` and `docs/user/authorization.md` that the review found false is true
again.

Out of scope: new features (a consent screen for OIDC, a permission catalog, a `pending`-key
publication policy — each is noted where it arises but not built here); anything the review
graded plausible rather than confirmed and could not be reproduced (the measurability of the
ES256 timing channel is *documented* by EP-3, not engineered around); and the two accepted
product behaviors the review restated — signup discloses existence (MasterPlan 5's Decision
Log) and `/oauth/authorize` issues codes without a consent step (recorded in EP-2's Decision Log
as a trust-model statement, not a change).


## Decomposition Strategy

The findings were clustered by the *invariant* each restores, not by the package that
happens to hold the code — the same principle
`docs/masterplans/5-security-correctness-hardening-make-existing-guarantees-hold.md` used, and
for the same reason: a package-sliced plan would not be an independently verifiable behavior,
because most findings span shomei-core, shomei-postgres, shomei-servant, and shomei-server at
once. Ten plans is above the two-to-seven guideline, so they are grouped into three phases that
are also priority tiers: Phase 1 restores the token and session integrity that en and every
downstream trust, Phase 2 restores abuse-protection and atomicity guarantees, and Phase 3
hardens the edges, the notifiers, the embedding story, and the documentation. Within a phase
the plans are parallelizable; across phases the ordering is priority, not a build dependency,
except where the Dependency Graph says otherwise.

EP-1 and EP-2 split the OAuth findings along one line: EP-1 is about *who* may obtain a session
(provenance — the critical laundering finding, plus the two "verified statelessly" findings that
share its root cause of trusting a verified token without asking what kind of token it is), and
EP-2 is about *which client* a session belongs to and what a client's scopes may confer
(binding and scope policy). Merging them would make one plan that edits the `Session` record
twice for two reasons; splitting them any further would put two plans into
`Shomei.OAuth.TokenGrant.Workflow` for the same function.

EP-3 collects everything in shomei-jwt: it is the one package whose findings do not touch a
workflow, and the signing-key state machine belongs with the verifier because both are
"what the trust root accepts".

EP-4 and EP-5 split the abuse-protection findings the way MasterPlan 5 split EP-1 and EP-3:
EP-4 changes *what is counted and throttled* (second-factor failures, password-change guesses,
the throttled-path list, the freshness gate), and EP-5 changes *how the counting and the
state transitions are made atomic* (the lockout increment, the counters, the transactional
credential tails). They meet at the login-attempt store, which is documented as an integration
point rather than merged, because EP-4 is a policy change with new tests for every proof
endpoint while EP-5 is a statement-shape change with concurrency tests — different work,
different verification.

EP-6 is the performance plan: the Argon2 escape is the review's one genuinely operational
high, and it sits beside the boot-time validation the same interpreter lacks. The
configuration-strictness findings (unknown Dhall keys, lenient enum parsing, the lagging Dhall
schema) are folded in because "refuse to boot on a bad configuration" is one behavior with one
test style, and because the lagging schema is a MasterPlan 5 follow-up that every later plan
here adding a config key depends on.

EP-7, EP-8, and EP-9 are the three edge concerns: what leaves the process (logs, audit rows,
notifications), what enters it (client IP, request bodies, the metrics scrape), and how a host
other than `shomei-server` assembles it (embedding, the downstream template). EP-10 is the
documentation reconciliation for the drift that no behavior change fixes; the plans that change
behavior each update their own documentation, so EP-10 is deliberately last and small.

An alternative decomposition into "one plan per review record" (REV-2 through REV-10) was
rejected for the reason given above: the critical finding alone has evidence in REV-2 and
REV-7, and its fix spans three packages. A decomposition into fewer, larger plans ("OAuth",
"abuse", "ops") was rejected because each would exceed five milestones and would put unrelated
concurrency work behind a security fix that should land first.

Architecture Decision Records: at drafting time this repository had no `docs/adr/` bundle.
EP-1 bootstrapped the profile-governed bundle, and EP-1 through EP-6 have now added ADR-1 through
ADR-8. The cross-repository records that also constrain this initiative are
`mori://shinzui/shomei/okf/improvement-requests/concepts/IR-1`
(scoped service-token issuance, which EP-2's privilege-scope policy must not break — the Kikan
contract it carries treats `impersonate:user`-class scopes as Shōmei-owned and coarse) and
`mori://shinzui/shomei/okf/improvement-requests/concepts/IR-2` (diagnostic identities, same
constraint). Further durable decisions are listed at the end of Integration Points; the owning
plan adds each record to the established bundle following the exec-plan ADR workflow.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Bind Sessions to Their Provenance and Refuse Non-Interactive Tokens at OAuth Authorize | docs/plans/51-bind-sessions-to-their-provenance-and-refuse-non-interactive-tokens-at-oauth-authorize.md | None | None | Complete |
| 2 | Bind OAuth Sessions to Their Client and Govern Privilege Scopes | docs/plans/52-bind-oauth-sessions-to-their-client-and-govern-privilege-scopes.md | None | EP-1 | Complete |
| 3 | Harden JWT Verification and Make the Signing-Key State Machine Atomic | docs/plans/53-harden-jwt-verification-and-make-the-signing-key-state-machine-atomic.md | None | None | Complete |
| 4 | Count Second-Factor and Credential-Oracle Failures and Throttle Every Unauthenticated Proof | docs/plans/54-count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof.md | None | EP-5 | Complete |
| 5 | Atomic State Transitions, Round Two: Lockout, Counters, and Transactional Credential Tails | docs/plans/55-atomic-state-transitions-round-two-lockout-counters-and-transactional-credential-tails.md | None | None | Complete |
| 6 | Bound Password Hashing for Real and Refuse to Boot on Unsafe Configuration | docs/plans/56-bound-password-hashing-for-real-and-refuse-to-boot-on-unsafe-configuration.md | None | None | Complete |
| 7 | Notifier and Log Hygiene: No Token or Secret Reaches a Log, Audit Row, or Config Dump | docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md | None | EP-6 | Complete |
| 8 | Proxy-Aware WAI Edge: Trusted Forwarded Headers, Metered Bodies, and Bounded Metrics | docs/plans/58-proxy-aware-wai-edge-trusted-forwarded-headers-metered-bodies-and-bounded-metrics.md | None | EP-4, EP-6 | Complete |
| 9 | Embedding Parity and a Trustworthy Downstream Verification Template | docs/plans/59-embedding-parity-and-a-trustworthy-downstream-verification-template.md | None | EP-3, EP-7, EP-8 | Complete |
| 10 | Reconcile the User Documentation and the en Integration Story with the Code | docs/plans/60-reconcile-the-user-documentation-and-the-en-integration-story-with-the-code.md | None | EP-1 through EP-9 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Phases (priority tiers, not build gates): Phase 1 — EP-1, EP-2, EP-3 (token and session
integrity); Phase 2 — EP-4, EP-5, EP-6 (abuse protection, atomicity, hashing); Phase 3 — EP-7,
EP-8, EP-9, EP-10 (edges, notifiers, embedding, documentation).


## Dependency Graph

No plan has a hard dependency: none produces a type or module another needs to compile, and
each was written so that its tests pass with the others absent. The soft dependencies encode
either priority (do the trust-root fix first) or "the later plan is cheaper once the earlier
one has landed".

EP-2 after EP-1 (soft). Both extend the `Session`/`NewSession` records and add a column to
`shomei_sessions`; EP-1 adds `kind` (interactive / machine / delegated) and EP-2 adds
`granted_scopes`. EP-1 also introduces the "refuse non-interactive at authorize" check that
EP-2's client-binding tests assume is present when they assert what a *legitimate* interactive
session can do. Implementing EP-2 first works — it would simply carry a `kind`-less session —
but the migrations then land out of the order the columns are discussed in, and EP-2's tests
would need a second pass once EP-1 adds the refusal. If both are in flight, reconcile on the
`NewSession` field set before either merges (Integration Points, item 1).

EP-4 and EP-5 meet at the login-attempt store (Integration Points, item 4). EP-5 is listed as a
soft dependency of EP-4 because EP-4's new second-factor accounting is written against the
store's operations, and EP-5 replaces the read-then-write lockout decision with a
compare-and-swap increment; if EP-5 lands first, EP-4 records its failures through the atomic
path from day one. In the other order EP-4's rows are counted by the non-atomic path until EP-5
lands, which is no worse than today for password failures.

EP-7 and EP-8 after EP-6 (soft). EP-6 widens `config/shomei-types.dhall` to `Optional` fields
and makes the loader reject unknown keys; EP-7 (moving secrets out of `ShomeiConfig`) and EP-8
(the trusted-proxy list and the per-IP knobs) both add configuration keys and are simpler once
the schema is no longer closed. Either can land first by adding its keys to the current file.

EP-8 after EP-4 (soft). EP-4 owns *which* paths the rate limiter guards (it derives the list
from the API type); EP-8 owns *who* a request is attributed to (the trusted-proxy client key).
They edit the same module in different functions; landing EP-4 first means EP-8 rebases one
function.

EP-9 after EP-3, EP-7, and EP-8 (soft). EP-9 exports the runtime stack for embedding hosts and
rewrites the downstream template; the stack must include EP-7's background notifier worker and
EP-8's proxy-aware middleware, and the template inherits EP-3's skew and `kid`-aware verifier.
EP-9 can land first with the stack as it is today, but then each of the three later plans must
remember to update the exported assembly, which is exactly the omission EP-9 exists to prevent.

EP-10 after everything (soft). It fixes only documentation the other plans do not touch; running
it last lets it verify that each behavior plan updated its own pages, and its final step is a
docs-wide grep for every sentence the review flagged.

Parallelism: within Phase 1, EP-1 and EP-3 are disjoint (core/servant versus jwt/server-keys)
and EP-2 waits on EP-1 only for the migration order. Within Phase 2, EP-6 is disjoint from
EP-4/EP-5. Within Phase 3, EP-7 and EP-8 are disjoint and EP-9 should follow both.


## Integration Points

1. **The session record and its table** — `shomei-core/src/Shomei/Session/Domain.hs`
   (`Session`, `NewSession`), `shomei-core/src/Shomei/Session/UnitOfWork/Store.hs`
   (`persistNewSession`), `shomei-postgres/src/Shomei/Session/Postgres.hs`,
   `shomei-postgres/src/Shomei/Session/UnitOfWork/Postgres.hs`,
   `shomei-core/src/Shomei/Test/InMemory.hs`, and the `shomei_sessions` table. Involved: EP-1
   (adds `kind`), EP-2 (adds `grantedScopes`), and EP-4 (adds `authenticatedAt`, the persisted
   `auth_time`). EP-1 owns the shape: a new field is added to *both* `Session` and `NewSession`,
   decoded and encoded in the Postgres interpreter and the in-memory fake, and carried through
   `persistNewSession`; the column carries a default so every existing row reads as the
   pre-change value (`interactive` for EP-1, `'{}'` for EP-2, `created_at` for EP-4). Field order
   is *landing order*: each plan appends its field at the end as of the moment it lands, updates
   every `NewSession` literal in the tree (login, passkey, MFA completion, OAuth exchange, client
   credentials, delegation, the tests — grep for `NewSession {` before and after), and never
   reorders or renames another plan's field. Migrations are allocated with
   `just new-migration <slug>` (never hand-numbered), so the columns land in whichever order the
   plans do; every child plan writes `0029` for its migration because that is the next number at
   the time of writing, and only the slug is meaningful.

2. **`AuthClaims`** — `shomei-core/src/Shomei/Authorization/Claims/Domain.hs` and the
   signer/verifier pair `shomei-jwt/src/Shomei/SigningKey/Sign/Jwt.hs` /
   `shomei-jwt/src/Shomei/SigningKey/Verify/Jwt.hs`. Involved: EP-1 (reads `actor`, adds
   nothing), EP-3 (adds `nbf` and `jti` to `reservedClaimKeys`, rejects ill-typed claim shapes,
   emits `typ`), EP-4 (adds `authTime :: UTCTime`, serialized as `auth_time`, set at login and
   at MFA completion and *preserved* across refresh, which the freshness gates then read
   instead of `iat`). EP-4 owns the new field and its round trip; EP-3 owns the verifier's
   settings and the reserved-name list, and must include `auth_time` in the set of names the
   signer writes last so `extraClaims` cannot forge it. Whichever lands second adds one line to
   the other's list.

3. **The one session-aware verifier** —
   `Shomei.Session.Authentication.Workflow.verifyToken` (config-aware: consults the session
   store under `VerifyTokenAndSession`) versus `Shomei.SigningKey.Verify.Jwt.verifyToken`
   (pure JWS verification). Involved: EP-1 (makes token exchange and delegation call the
   session-aware one and adds an actor-status check), EP-3 (changes the jose settings under the
   pure one: skew, algorithm set, `kid` store, claim shapes), EP-9 (the downstream template
   calls the pure one and must gain the skew and `kid` behavior for free). EP-3 owns the pure
   verifier's configuration surface (a `VerifierSettings`-style record with the skew as a
   field, defaulting to 30 s); EP-1 owns which workflows call which verifier — token exchange and
   delegation go through the session-aware verifier *with the session check forced on* (a
   `verifyTokenWith :: SessionCheckMode -> …` variant of the same function), because a merely
   config-aware call would make the fix vanish under the default `VerifyTokenOnly` — and must
   not add a third verification path.

4. **The login-attempt store and lockout** — `shomei-core/src/Shomei/Session/LoginAttempt/{Domain,Store}.hs`,
   `shomei-postgres/src/Shomei/Session/LoginAttempt/Postgres.hs`, the
   `shomei_login_attempts` and `shomei_account_lockouts` tables, and the
   `failLogin`/`countRecentFailuresByAccount`/`setAccountLockout` sequence in
   `shomei-core/src/Shomei/Session/Authentication/Workflow.hs`. Involved: EP-4 (records
   second-factor, password-change, and suspended-account failures; defers the lockout clear
   until the second factor passes) and EP-5 (replaces the read-then-write lockout decision with
   an atomic record-and-count). EP-4 owns the *vocabulary*: it extends `LoginOutcome` (or adds a
   `factor` discriminator) so that a TOTP failure and a password failure are distinguishable in
   the table and in the audit trail, while both count toward the same account lockout. EP-5
   owns the *statement shape*: a per-account-key transaction serialized by
   `pg_advisory_xact_lock` around the existing insert and count statements, exposed as one port
   operation that the workflow calls once per failure *before* hashing (a provisional failure row
   that a correct password converts to a success), replacing `recordLoginAttempt` +
   `countRecentFailuresByAccount`. A bare `INSERT … RETURNING (SELECT count(*) …)` is not atomic
   under READ COMMITTED — concurrent inserts do not conflict and a statement's snapshot excludes
   the others' uncommitted rows — which is why the lock is needed. Whichever lands second must keep the
   other's contract: EP-4's new outcomes must flow through EP-5's atomic path, and EP-5's path
   must accept EP-4's outcomes. The partial indexes in migration `0011` are on
   `outcome = 'failure'`/`'success'`; a new outcome value needs its own partial index or must
   reuse `'failure'` with a separate column — EP-4 decides and records it.

5. **The transactional unit of work** — `Shomei.Session.UnitOfWork.Store.AuthUnitOfWork`.
   Involved: EP-5 (adds `CompletePasswordReset`, `CompletePasswordChange`, and
   `RevokeSessionWithTokens` operations lifting the existing per-table statements into one
   transaction) and EP-6 (must keep Argon2 hashing *outside* any transaction — the hash is
   computed and forced before the unit of work begins). EP-5 owns the port; the in-memory
   interpreter's operations must use `casWorld`/`modifyWorld` (MasterPlan 5's convention), and
   EP-5 also fixes the three non-atomic handlers the review found in the fake.

6. **The rate limiter and the throttled-path list** —
   `shomei-server/src/Shomei/Server/Middleware/RateLimit.hs` and the no-op
   `RateLimited`/`CsrfProtected` markers in `shomei-servant/src/Shomei/Servant/PreHandler.hs`.
   Involved: EP-4 (owns *what* is throttled: derives the path set from the routes that carry the
   `RateLimited` marker, so the marker becomes true, and adds the second-factor, passkey,
   password-change, confirm, `/oauth/token`, and `DELETE /v1/auth/totp` routes;
   `/oauth/introspect` and `/oauth/revoke` stay unthrottled because they are client-authenticated
   calls, not proofs), EP-8 (owns *who*: the client key,
   trusted-proxy resolution, and the monotonic clock), EP-9 (packages the resulting middleware
   into the exported host stack). The middleware's constructor signature is the contract:
   EP-4 must not change how the limiter derives the client key, and EP-8 must not change how it
   decides whether a path is limited.

7. **Configuration** — `shomei-core/src/Shomei/Config.hs`, `shomei-server/src/Shomei/Server/Config.hs`,
   `config/shomei-types.dhall`, and `docs/user/deployment.md`'s key tables. Involved: EP-3
   (`allowedClockSkewSeconds`), EP-6 (rejects unknown Dhall keys, strict enum parsing, widens
   the Dhall schema to `Optional` fields and syncs the twenty lagging keys, validates Argon2
   parameters), EP-7 (moves the SMTP password and webhook secret out of `ShomeiConfig` into the
   server `Env`, trims env secrets), EP-8 (`trustedProxies`, and env/Dhall exposure of
   `maxFailedLoginsPerIp`, `perIpBurst`, `lockoutWindow`, `lockoutDuration`, `rateLimitEnabled`).
   All additive and order-independent. Rule for every plan: a key added to the loader is added
   to `config/shomei-types.dhall`, to `config/shomei.example.dhall` (which annotates itself with
   the schema), and to `deployment.md` in the same commit. EP-6 turns the schema into a
   `{ Type, default }` record-completion type so a `Schema::{ … }` file may omit any key and this
   stops being a breaking edit — a plain `Optional` field would still have to be present as
   `None`. The one sanctioned exception is an env-only lab escape flag (EP-7's allow-insecure
   switches), which deliberately has no Dhall key so it cannot linger in a committed file; the
   precedent is `SHOMEI_NOTIFIER_LOG_SECRETS`.

8. **The standalone assembly and the embedding entry point** —
   `shomei-server/src/Shomei/Server/Boot.hs` (`main`, `application`, `authContext`,
   `installKeyReload`, `installSweeper`), `shomei-server/src/Shomei/Server/App.hs` (`Env`).
   Involved: EP-7 (adds a background notifier worker installed beside the sweeper), EP-8 (changes
   the middleware stack), EP-9 (owns the exported `installHostBackgroundTasks` and
   `hostMiddleware`, and makes both embedded examples use them). EP-9 owns the shape; EP-7
   (`installNotifierWorker` and its post-`runSettings` `drainNotifierWorker`) and EP-8
   (`edgeMiddleware`, with the trusted-proxy rewrite outermost) install their work through the
   same two functions or, if they land first, through `main` in a way EP-9 lifts verbatim —
   including the drain step in the shutdown story. After EP-9, everything a host needs is those
   two functions plus `application`; `main` keeps only what is standalone-specific (stream
   buffering, warp settings, signal handling, the graceful drain).

9. **The notifier** — `shomei-server/src/Shomei/Notify.hs` and the `Notifier` port. EP-7 only,
   but its worker becomes a background task under item 8, and its "fixed-cost miss path" is what
   closes the request-timing oracle that EP-5's core workflow would otherwise need to pad.

10. **The downstream template and the examples** — `examples/microservice-auth-stack/**`,
    `examples/embedded-servant-app/**`, `examples/embedded-with-en/**`. EP-9 for code and for
    every documentation sentence that describes code EP-9 changes (README §4's en recipe, the
    `Cache-Control` paragraph, the embedding checklist, the KEK runbook lines); EP-10 for
    everything else in those files and for the drift no plan's code touches. EP-9 must not change the cache's
    tested properties (lock-free read, single-flight, refresh-ahead, stale-on-error, staleness
    bound) while adding TLS, clamping, and `kid`-triggered refresh.

Decisions that deserve an ADR once made (the owning plan creates `docs/adr/` on first use):
session provenance as the boundary between interactive and non-interactive credentials and
the rule that only interactive sessions may authorize (EP-1); the reserved privilege-scope list
and where it is enforced (EP-2); strict JWT verification and the database-backed one-active-key
invariant (EP-3); `auth_time`, not `iat`, as the freshness clock (EP-4); the open
`{ Type, default }` configuration schema and the same-commit rule for configuration keys (EP-6);
"a transport library's exception text is never persisted" (EP-7); the trusted-proxy policy and
its default, and the cookie-name prefixes (EP-8); the embedding contract — what a host must
install to get the standalone server's guarantees — and the downstream template's unknown-key
refresh policy (EP-9).

**How `docs/adr/` is bootstrapped.** The repository has no ADR corpus and no filesystem
convention to preserve, and its three documentation bundles are all profile-governed, so the
first plan to land an ADR creates `docs/adr/` as a profile-governed OKF bundle the same way
`docs/reviews/` was bootstrapped in commit `ee00382`: copy the frozen descriptor
`blueprints/adopt-architecture-decisions/files/architecture-decisions-profile.dhall` from the
`shinzui/okf-profiles` checkout (`mori path shinzui/okf-profiles`) to `docs/adr/profile.dhall`
— it pins `v0.8.0/package.dhall` with a `dhall freeze` hash, so nothing is guessed; run
`okf index docs/adr --write --okf-version 0.2`; add `log.md`; add an `okfBundles` entry named
`adrs` to `mori.dhall` beside `reviews`; add a `just adr-validate` recipe
(`okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce
--log-enforce`). Records are `NNNN-<slug>.md` with the profile's frontmatter (`type:
Architecture Decision Record`, `title`, `description`, `generated`, `docId`, `status`, `date`)
and a `docId` allocated with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` —
never by counting files. Every later plan allocates the next handle the same way and runs
`just adr-validate` before committing.


## Progress

- [x] EP-1: `Session.kind` column and record field; every mint site names its kind
- [x] EP-1: `authorize` refuses `act` and non-interactive sessions in core and at the handler; tests for all three token kinds
- [x] EP-1: token exchange and delegation verify through the session-aware verifier and check actor status; email gate on code exchange
- [x] EP-2: granted scopes persisted on the session and re-applied on every refresh path
- [x] EP-2: bespoke `/v1/auth/refresh` refuses client-bound sessions; `/oauth/revoke` checks ownership; refresh grant echoes `scope`
- [x] EP-2: reserved privilege scopes refused on OAuth clients and warned on service accounts (their intended holders); userinfo honours scopes; consumed-code replay revokes
- [x] EP-2: Basic credentials form-decoded; discovery advertises token exchange; hint-less refresh introspection and missing-bearer challenge corrected; trust model documented
- [x] EP-3: verifier skew, whole-second times, pinned algorithm set, `typ`, `kid`-selecting key store, strict claim shapes, reserved `nbf`/`jti`, issuer/audience validated at boot
- [x] EP-3: single-active-key partial unique index; transactional activate and rewrap; `retired_at`/`revoked_at` stamped; `assembleKeys` refuses two active rows; JWKS `alg`
- [x] EP-3: ES256 timing trade-off documented; negative tests for `none`, HS256, cross-family, unknown `kid`, revoked key
- [x] EP-4: second-factor, recovery-code, passkey, password-change, and suspended-account failures counted against the account; lockout clear deferred to second-factor success
- [x] EP-4: `auth_time` claim; freshness gates read it; TOTP removal requires fresh authentication
- [x] EP-4: throttled-path set derived from `RateLimited` routes; completion, passkey, password-change, confirm, and `/oauth/token` routes limited; passwordless login requires user verification
- [x] EP-5: record-before-hash lockout under a per-account advisory lock; concurrency test proving real hash evaluations ≤ threshold under 100 parallel wrong passwords
- [x] EP-5: TOTP and passkey counter updates are compare-and-swap; concurrent same-code completion test
- [x] EP-5: reset, change, reuse-detection, and logout tails in one transaction; admin status CAS; outstanding one-time tokens revoked; duplicate email is `409`; in-memory fake atomic
- [x] EP-5: schema hygiene — `CHECK` constraints on status columns, `lower()` unique indexes, PostgreSQL 17/18 floor documented
- [x] EP-6: `HashPassword` forced inside the permit; limiter test forces its results and measures overlap
- [x] EP-6: Argon2 parameters validated at boot (`m ≥ max 8 (8·p)`); unknown Dhall keys rejected; strict enum parsing; empty WebAuthn origins refused
- [x] EP-6: `config/shomei-types.dhall` widened to `Optional` fields and synced; `shomei_password_credentials (user_id)` unique index; statement and idle-transaction timeouts; sweeper isolated from request capacity
- [x] EP-7: transport exceptions mapped to reason codes; NotifySpec case for a DATA-stage `451`; ADR-9 records that exception text never crosses the persistence boundary
- [x] EP-7: notifier delivery moved to a supervised background worker; the request path answers `202` in sub-second bounded work with the hit/miss residual pinned by test; ADR-10 records the bounded queue and drain policy
- [x] EP-7: SMTP password and webhook secret out of `ShomeiConfig`; env secrets trimmed; `http://` webhooks refused by default; timestamped HMAC; redacting `Show` for tokens; `LoginFailed` carries the hashed key
- [x] EP-7: administrative bootstrap reads passwords outside argv, shares the deployment password/breach policy, can explicitly verify email, and reduces PostgreSQL and breach diagnostics to safe categories
- [x] EP-8: trusted-proxy list with rightmost-untrusted `X-Forwarded-For`; dotted-quad IPs; per-IP knobs configurable
- [x] EP-8: chunked bodies metered; metrics method label bounded and escaped; monotonic clock; readiness timed and cached; problem-shaped 413 and 500; lenient header decoding
- [x] EP-9: `installHostBackgroundTasks` and `hostMiddleware` exported and used by both embedded examples; embedding checklist documented
- [x] EP-9: downstream template uses TLS, clamps `max-age`, refreshes on an unknown key, sends an en API key; runbooks boot as written
- [x] EP-10: `security.md`, `authorization.md`, `architecture.md`, `deployment.md`, `api.md`, `README.md`, `CHANGELOG.md`, MasterPlan 6, and the capability catalog reconciled; every sibling probe, source-document link, OpenAPI path, review record, capability record, and ADR verified


## Surprises & Discoveries

- EP-1's regression-first Servant transcript reproduced the critical review finding exactly: both
  delegated and `client_credentials` credentials received a `302` carrying an authorization code
  before the authorize guard. The same scenarios now receive `401 login_required` and leave the
  code store unchanged.

- The architecture-decision profile's local Mori metadata lagged at `v0.8.0`; authoritative
  upstream tags and a successful frozen import confirmed `v0.13.1`, which now governs Shōmei's
  first ADR bundle at `docs/adr/`.

- EP-2's regression-first cases reproduced five distinct boundary failures before correction: the
  bespoke refresh endpoint spent a client-bound token; another client revoked the owner's token;
  a consumed authorization code left its first session active; an `openid`-only UserInfo response
  leaked email; and OAuth-client registration accepted `shomei:admin`. Keeping each assertion at
  the core workflow or HTTP boundary made the resulting ownership and scope policy independently
  observable.

- EP-3 reproduced the clock-skew, permissive claim-shape, multi-audience, fractional-time, and
  extension-claim weaknesses before correction; the algorithm-confusion controls already held.
  RFC 3986 also corrected the draft's assumption: `shomei:prod` is a valid StringOrURI, while
  `https://bad host` is the malformed boot-time case.

- Hasql keeps transaction composition and execution in separate modules, and a partial unique
  index is checked per statement. Retiring the current key before promoting its replacement inside
  one transaction therefore gives both atomicity and a usable non-deferrable database invariant.
  The final serial `cabal test all` run passed all 13 suites.

- EP-5's pre-fix races made the missing persistence linearization points observable: 100 wrong
  passwords exceeded the stored-hash budget, 100 refreshes emitted 55 reuse events, and 100
  suspends produced five winners in the recorded runs. Per-account transaction locks, conditional
  writes, and unit-of-work tails reduced each property to its exact bound in both interpreters.

- Migration identifiers moved while sibling plans landed: EP-5's schema-hygiene slug was forecast
  as 0029 but the live allocator returned 0035 after session provenance, OAuth, signing-key, factor,
  and authentication-time migrations. The slug remains the planned identity; the manifest and
  deployment contract now name the allocated number.

- EP-6 confirmed the Argon2 limiter regression was a false pass caused by laziness. Forcing the
  digest and returned hash under the permit reduced the eight-loop signup load's peak RSS from
  626 MB to 237 MB; the lower throughput is the configured concurrency bound taking effect.

- Strict configuration changed both failure behavior and schema evolution. A misspelled Dhall key
  previously reached listening state; it now exits before migration or pool acquisition. The
  loader/schema equality test grew from the reviewed 49-key schema to 70 synchronized fields, then
  to 71 when EP-6 added the statement timeout. `dhall-to-json --preserve-null` is required only by
  the drift probe because ordinary conversion intentionally omits completed `None` values.

- The live migration allocator assigned EP-6's uniqueness migration 0036. The installed `hasql`
  exposes `Session.script` rather than the newer corpus example's `Session.sql`, and erases the
  idle-timeout SQLSTATE after PostgreSQL closes the connection; reading both session settings back
  before exercising their failure paths made the regression independent of that rendering detail.

- EP-7 reproduced both diagnostic disclosure paths before correction: smtp-mail's DATA exception
  retained the quoted-printable one-time token inside the 500-character cap, while http-client's
  request rendering retained the configured webhook query string. A closed reason vocabulary now
  discards both renderings before output or persistence.

- EP-7 made EP-9's background-task integration concrete: embeddings must carry `NotifierSecrets`
  and `NotifierQueue`, install `installNotifierWorker`, and run `drainNotifierWorker` during bounded
  shutdown. The standalone server already follows that lifecycle, and the slow-receiver E2E case
  proves the request path remains sub-second while delivery continues asynchronously.

- EP-8 reproduced the proxy-attribution, chunked-body, and hostile-header findings against a clean
  local database before correction. Its final focused suites passed 26 middleware and 8 health
  cases; a live hostile method collapsed to the bounded `other` metrics series; and the serialized
  workspace gate built every package and passed all 13 test suites. The readiness timeout was
  verified with an injected five-second dependency stall rather than by stopping the shared
  PostgreSQL service.

- EP-9 reproduced the downstream TLS failure as `TlsNotSupported` and the embedding key-reload gap
  as an old token remaining `200` after database revocation. The shared host contract changed that
  token to `401` after `SIGHUP`; the middleware case proved 100 oversized `413`s did not consume the
  limiter's 60-request budget. Its TLS, cache, and unknown-key suite passed all 11 cases.

- The isolated en example's stale `hs-jose` pin could not solve against Shōmei's current `ram`
  bound. Removing the obsolete pin, mirroring the root X.509 security floor, implementing en HEAD's
  `ReadRelationshipPage`, and pinning the verified upstream commit `bf8ffa24` produced a clean
  independent build that CI now runs explicitly.

- EP-10 found six documentation probes stale after their owning behavior plans had landed: clock-skew
  terminology, the literal MFA-completion path, strict-configuration examples, notifier secret
  variables, distributed rate-limit wording, and the embedding-checklist heading. The behavior was
  present in every case; the final reconciliation repaired the user pages and now makes those probes
  part of the closeout evidence.

- The documentation link checker initially traversed an ignored Cabal `dist-newstyle` copy of an
  external package README. Restricting the check to authored source documents produced zero broken
  links without deleting or treating build output as project documentation.


## Decision Log

- Decision: Decompose by restored invariant into ten plans in three priority phases rather
  than by review record or by package.
  Rationale: The critical finding spans shomei-core and shomei-servant and its evidence is split
  across REV-2 and REV-7; a package-sliced plan would not be an independently verifiable
  behavior. Ten exceeds the two-to-seven guideline, so phases group them into priority tiers;
  the phases are not build gates because no plan produces an artifact another needs to compile.
  Date: 2026-08-27

- Decision: EP-1 (provenance) and EP-2 (client binding and scope policy) are two plans that
  both add a column to `shomei_sessions`, with EP-1 owning the record shape.
  Rationale: "Who may obtain a session" and "which client a session belongs to" are different
  invariants with different tests; the critical finding must not wait on the medium ones.
  The shared record is an integration point with a named owner, the same device MasterPlan 5
  used for the key-loading seam.
  Date: 2026-08-27

- Decision: The ES256 timing channel is documented and offered as a configuration choice, not
  engineered around, in this initiative.
  Rationale: The review graded it plausible, not confirmed; RS256 through the blinded
  `PKCS15.signSafer` already exists as a one-flag alternative; a constant-time ES256 is a
  dependency change (jose/crypton) outside this repository's control. EP-3 records the
  trade-off in `security.md` and adds the recommendation; a later plan may change the default.
  Date: 2026-08-27

- Decision: JWT verification is a strict application policy over jose's general-purpose
  primitives: ES256/RS256 only, exact `kid` selection, owned claim shapes, bounded clock skew,
  and explicit token type. The policy is recorded in
  [ADR-3](../adr/0003-jwt-verification-is-an-explicit-strict-trust-boundary.md).
  Rationale: The issuer always emits this narrower vocabulary. Making it explicit prevents
  representational flexibility from becoming security surface or unauthenticated work that grows
  with the JWKS.
  Date: 2026-08-27

- Decision: At most one signing key may be active, enforced by PostgreSQL, and replacement is one
  transaction through both the domain port and operator CLI. The invariant is recorded in
  [ADR-4](../adr/0004-one-active-signing-key-is-a-database-invariant.md).
  Rationale: Application ordering cannot protect against concurrency, process failure, or
  out-of-band writes. Retired keys remain published, so the stronger invariant preserves the
  existing zero-downtime overlap.
  Date: 2026-08-27

- Decision: Every unauthenticated credential proof participates in one per-account failure budget,
  regardless of factor or workflow; only a fully authenticated success clears it. The invariant is
  recorded in [ADR-5](../adr/0005-every-credential-proof-participates-in-one-abuse-budget.md).
  Rationale: Separate workflow-local budgets leave second-factor and credential-management oracles
  unbounded and let a challenged password reset the counter before an attacker guesses the second
  factor. One vocabulary and one accounting seam make the security boundary reviewable.
  Date: 2026-08-27

- Decision: Authentication freshness is the time of the last credential proof, carried as managed
  `auth_time` and preserved across refresh, rather than a token's issuance time. The invariant is
  recorded in [ADR-6](../adr/0006-authentication-freshness-is-based-on-credential-proof-time.md).
  Rationale: A refresh token proves session continuity, not recent credential possession. Letting
  refresh advance the freshness clock would silently bypass recovery, impersonation, and factor
  removal step-up gates.
  Date: 2026-08-27

- Decision: The OIDC consent step stays out of scope; EP-2 records "every registered client is
  fully trusted with every user's identity" as the stated trust model.
  Rationale: A consent UI is a feature with its own product decisions; the review's finding was
  that the trust model is undocumented, not that it is wrong for a single-organization
  deployment.
  Date: 2026-08-27

- Decision: The configured impersonation scope, `shomei:admin`, and
  `token-exchange:subject` are reserved principal privileges. OAuth-client registration refuses
  them, authorize is the backstop for legacy or hand-written rows, and service accounts may hold
  them as their own authority with an operator warning. The policy and its single domain owner are
  recorded in [ADR-2](../adr/0002-reserved-privilege-scopes-are-service-account-authority.md).
  Rationale: An OAuth-client allow-list is copied into a human user's token, while a service-account
  allow-list is authority of the machine principal itself. Treating those lists alike either
  escalates every authorizing user or breaks the intended scoped service-token contract.
  Date: 2026-08-27

- Decision: One rei intention (`intention_01m10kwqt9eedbjvk91rn726mq`) for the initiative,
  inherited by every child plan, following the convention of MasterPlans 1 through 7.
  Rationale: The corpus links every child plan to its MasterPlan's intention; a per-plan
  intention would be the first departure from that convention and would fragment the rei view.
  Date: 2026-08-27

- Decision: The lockout is made atomic with a per-account `pg_advisory_xact_lock` transaction
  that records the failure *before* hashing, not with the `INSERT … RETURNING (SELECT count(*) …)`
  shape the first draft of this MasterPlan suggested.
  Rationale: Drafting EP-5 established that the single-statement shape is not atomic under READ
  COMMITTED (concurrent inserts do not conflict; a statement's snapshot excludes the others'
  uncommitted rows), and that recording after the hash still lets every guess in a burst reach
  the stored hash. Integration Point 4 was corrected before any plan was committed.
  Date: 2026-08-27

- Decision: Every single-use or monotonic security transition is a conditional persistence write
  that reports whether it won; multi-row credential tails commit through an explicit unit of
  work, and serialization that must enclose a read uses a transaction-scoped advisory lock. The
  policy is recorded in
  [ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md).
  Rationale: Application pre-reads and process-local locks cannot linearize several requests or
  several replicas. The database is the shared trust boundary, while typed compare-and-swap losses
  let workflows distinguish normal contention from dependency failure.
  Date: 2026-08-27

- Decision: `docs/adr/` is bootstrapped once, by whichever plan first lands an ADR, as a
  profile-governed OKF bundle using the frozen descriptor shipped by the okf-profiles
  `adopt-architecture-decisions` blueprint; later plans allocate handles with `okf id next`.
  Rationale: The exec-plan ADR guide says to preserve an established filesystem convention when
  no profiled bundle exists, but this repository has no ADR convention at all, every one of its
  documentation bundles is profile-governed, and two child plans had drafted incompatible bare-file
  conventions. Naming one convention here, with a non-guessed pin, is what keeps ten plans from
  producing two corpora.
  Date: 2026-08-27

- Decision: Migration numbers in the child plans are illustrative; the slug is the identity.
  Rationale: Six plans add a migration and each was written against the same HEAD, so each names
  `0029`. `just new-migration` allocates the real number at landing time and the manifest orders
  by landing, so the plans state the rule rather than pre-assigning numbers.
  Date: 2026-08-27

- Decision: Runtime file configuration is an evolvable Dhall record-completion schema whose fields
  are all optional, while the loader rejects unknown keys and a test keeps its field set equal to
  the schema. The contract is recorded in
  [ADR-8](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md).
  Rationale: Adding optional behavior must not break every completed deployment file, but accepting
  misspelled or newer keys in an older binary silently changes security policy. Record completion
  supplies forward evolution, strict decoding supplies fail-closed intent, and mechanical equality
  removes the hand-maintained schema gap found by the review.
  Date: 2026-08-27

- Decision: An embedded host installs the complete runtime boundary through
  `installHostBackgroundTasks` and `hostMiddleware`, keeps the cleanup handle, and wraps its whole
  application. The contract is recorded in
  [ADR-17](../adr/0017-embedded-hosts-install-the-complete-runtime-boundary.md).
  Rationale: A bare route tree cannot own process workers or protect host-owned routes. Reusing the
  standalone assembly prevents signing-key reload, maintenance, notification, and WAI-edge policy
  from drifting between deployment models.
  Date: 2026-08-27

- Decision: Downstream JWKS refresh remains bounded by the resource service's local policy: TLS for
  production transport, a hard staleness cap, and one single-flight retry under a rate cap only for
  `TokenKeyNotFound`. The policy is recorded in
  [ADR-18](../adr/0018-downstream-jwks-refresh-is-bounded-by-local-policy.md).
  Rationale: Prompt rotation recovery must not turn attacker-chosen key identifiers or publisher
  cache headers into unbounded network work or an extension of revocation trust.
  Date: 2026-08-27

- Decision: MasterPlan 8's completion distillation adds no nineteenth ADR. EP-10 links ADR-1,
  ADR-2, ADR-9, ADR-15, and ADR-17 from the user-facing rules they govern, while ADR-1 through
  ADR-18 already cover every durable decision found across the ten child plans.
  Rationale: The only new EP-10 discoveries concern documentation probes and exclusion of generated
  build artifacts from a source link check. Those are execution lessons, not new architecture
  boundaries, persistent constraints, or deliberate product exclusions.
  Date: 2026-08-27


## Outcomes & Retrospective

EP-1 through EP-10 are complete, closing all three phases and every work stream.
Session provenance is persisted and
compile-time-required at every mint; authorize admits only live interactive sessions; token
exchange and impersonation see
revocation and operator suspension immediately; and authorization-code exchange applies the email
gate. OAuth sessions retain their granted scopes, refresh and revocation obey client ownership,
reserved principal privileges cannot be conferred through OAuth clients, UserInfo honours its
claim scopes, and consumed-code replay ends the first session. ADR-1 and ADR-2 record the two trust
boundaries. JWT verification now pins its algorithm and claim policy, selects exactly by `kid`,
tolerates configured clock skew, and emits whole-second dates plus explicit metadata. Signing-key
replacement is atomic, PostgreSQL enforces at most one active key, lifecycle timestamps persist,
and JWKS entries carry `alg`. ADR-3 and ADR-4 record those trust-root decisions. Every credential
proof now shares one account failure budget, suspended and locked paths preserve the timing and
audit contract, and a challenged password does not clear the budget. Credential freshness is
persisted as `authenticated_at`, carried as `auth_time`, and preserved across refresh. The runtime
limiter derives its exact thirteen-route coverage from `RateLimited`, and passwordless WebAuthn
always requires user verification. Lockout recording and counting now serialize per account before
hashing; TOTP, passkey, session, and user-status transitions have one compare-and-swap winner; and
password reset/change and revocation tails commit atomically. Identity conflicts retain their 409
domain meaning, while migration 0035 constrains persisted vocabulary and case-insensitive identity
uniqueness. ADR-5 through ADR-7 record the accounting, freshness, and persistence-atomicity
boundaries. EP-6 now forces password hashing inside the real limiter, rejects invalid Argon2 and
trust-boundary configuration before serving work, and keeps an evolvable 71-field Dhall schema
synchronized with the strict loader. Migration 0036 enforces one password credential per user;
pooled work has statement and idle-transaction bounds; and maintenance no longer occupies request
capacity. ADR-8 records the configuration contract. EP-7 now maps outbound failures to a closed
reason vocabulary, moves delivery behind a bounded supervised queue, carries notifier credentials
outside printable config, binds webhook signatures to attempt time, redacts bearer credentials,
hashes failed-login subjects, and makes administrative bootstrap share the deployment password and
breach policy without putting secrets in argv. ADR-9 through ADR-14 record those boundaries. Each
child's final serialized workspace suite is green. EP-8 now resolves client identity only through
declared proxies, meters streamed bodies, preserves problem documents at the WAI/warp boundary,
prefixes secure cookies, bounds metrics labels and time sources, and makes readiness timed,
single-flight, and briefly cached. ADR-15 and ADR-16 record its proxy and cookie trust policies. EP-9
now gives embedded hosts the same key reload, maintenance, notification, proxy, logging, metrics,
body, and limiter boundary as the standalone executable, including bounded cleanup. Its downstream
template fetches keys over TLS, caps publisher freshness at local staleness, and rate-limits one
unknown-key refresh and retry; the example runbooks and independently pinned en build are executable
CI inputs. ADR-17 and ADR-18 record those contracts. EP-10 completed the final documentation and
capability-catalog reconciliation: every flagged sentence is corrected or superseded, every
sibling documentation probe passes, source links and OpenAPI paths are clean, and the governing
ADRs are linked from the user pages. All ten child plans and all three phases are complete.


Revision note (2026-08-27): Reconciled EP-5 as complete, carried its concurrency and migration
results into initiative state, and added ADR-7's atomic-persistence policy. The MasterPlan remains
in progress with EP-6 through EP-10 open.

Revision note (2026-08-27): Reconciled EP-6 as complete, recorded its load, strict-config, schema,
migration, timeout, and isolated-sweeper evidence, and added ADR-8's synchronized-configuration
policy. Phase 2 is complete; the MasterPlan remains in progress with EP-7 through EP-10 open.

Revision note (2026-08-27): Reconciled EP-7 as complete, recorded its redaction, bounded-delivery,
runtime-secret, timestamped-signature, audit-identity, and safe-bootstrap boundaries, and added ADR-9
through ADR-14. The MasterPlan remains in progress with EP-8 through EP-10 open.

Revision note (2026-08-27): Reconciled EP-8 as complete, recorded its proxy attribution, body and
exception envelope, cookie-prefix, bounded-metrics, monotonic-time, and readiness policies, and added
ADR-15 and ADR-16. The MasterPlan remains in progress with EP-9 and EP-10 open.

Revision note (2026-08-27): Reconciled EP-9 as complete, recorded the shared embedding runtime,
bounded downstream JWKS policy, executable runbooks, and independent en build, and added ADR-17 and
ADR-18. The MasterPlan remains in progress with EP-10 open.

Revision note (2026-08-27): Reconciled EP-10 as complete, recorded the documentation-sweep and
source-link-check discoveries, linked the five governing ADRs from user documentation, completed
the cross-plan ADR distillation pass, and closed all ten child plans and all three phases.
