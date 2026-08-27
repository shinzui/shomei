---
type: Review
title: Shōmei security and performance baseline at the first Hackage release
description: >-
  The password, refresh-rotation, JWT, and SQL fundamentals hold, but a delegated or machine
  token can be laundered through /oauth/authorize into a full 30-day session, an SMTP relay
  rejection persists live reset tokens, Argon2 work escapes its limiter, second factors are
  unthrottled, and the downstream JWKS template cannot use TLS — so changes are requested.
generated:
  by: process:claude-code
  at: "2026-08-27T02:56:01Z"
reviewId: REV-1
subject: mori://shinzui/shomei
subjectKind: project
reviewedSha: ee00382509c6cf4b3db2a3c87ff0bd029932c770
coverage: full
reviewedAt: "2026-08-27T02:56:01Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: xhigh
outcome: changes-requested
dimensions:
  - security
  - performance
  - correctness
  - design
  - operability
  - test-coverage
  - documentation
context: >-
  Seven parallel reader agents each read one package (or the examples, client, and user
  docs) in full at the reviewed commit, with instructions to verify every finding against
  the callers and against dependency source located through mori (jose 0.13, crypton
  1.1.4, hasql 1.10, hasql-pool 1.4, hasql-transaction 1.2, pg-migrate 1.1, warp 3.4.15,
  servant-server 0.20.3, smtp-mail 0.5.0.1, the pinned shinzui/webauthn fork). The review
  of record re-read the code behind every critical and high finding before grading it.
  `cabal build all --enable-tests` and `cabal test all` (13 suites, 500 cases) passed at
  the commit. Nothing was exploited dynamically: the timing oracles are argued from code
  paths, not measured. The sibling en repository was consulted at
  bf8ffa24b33de328ed7c6b19f02e9e3ad035d57f for the integration claims. Per-package depth
  is recorded in REV-2 through REV-10; this record carries the cross-cutting analysis.
---

# Shōmei security and performance baseline at the first Hackage release

## Verdict

Changes requested. The July 2026 hardening did what it set out to do: refresh rotation is a
single compare-and-swap inside a transaction, reuse revokes family and session, absolute
session expiry is enforced, the login timing oracle is closed on the paths that reach a stored
hash, private signing keys are envelope-encrypted with the `kid` as AEAD data, the JWKS carries
only public members, `alg: none` and cross-family key confusion are structurally impossible in
jose 0.13, every SQL statement is parameterized, and `sessionCheckMode` is now genuinely wired.
Those are the things that would have made this review a different document, and they hold.

What does not hold is the *composition* of the newer surfaces with the old guarantees. One
critical and six high findings survived verification, and every one of them is a seam between
two features that are each individually correct.

This review was asked to weigh security and performance because Shōmei is the authentication
half of a two-tier story whose authorization half is
[en](mori://shinzui/en). That framing matters: en maps every subject to `user:<JWT sub>` and
trusts Shōmei for `sub`, `act`, `roles`, `scopes`, `permissions`, and for the reach of session
revocation. The findings below are graded against exactly that trust.

## Granularity

The profile asks for one subject per record. This record is the project read as one: the
threat model, the cross-package findings, and the overall grade. The nine component records
carry the per-package depth, positive verifications, and the areas each reader did not open:

- [REV-2 shomei-core](shomei-core-security-and-performance.md)
- [REV-3 shomei-jwt](shomei-jwt-security-and-performance.md)
- [REV-4 shomei-webauthn](shomei-webauthn-security.md)
- [REV-5 shomei-postgres](shomei-postgres-security-and-performance.md)
- [REV-6 shomei-migrations](shomei-migrations-schema-review.md)
- [REV-7 shomei-servant](shomei-servant-security-and-performance.md)
- [REV-8 shomei-server](shomei-server-security-and-performance.md)
- [REV-9 shomei-client](shomei-client-security.md)
- [REV-10 microservice-auth-stack](microservice-auth-stack-jwks-template.md)

The two embedded examples (`examples/embedded-servant-app`, `examples/embedded-with-en`) were
read in full but have no record of their own; what was found in them is either a `shomei-server`
packaging gap (finding 7) or documentation, and is recorded here.

## The trust model the findings are graded against

A Shōmei deployment that follows the paved road has three trust edges:

1. **JWKS integrity.** Every downstream verifies offline against `/.well-known/jwks.json`.
   Whoever controls that document mints any identity.
2. **Claim integrity.** `sub` is the en subject; `act` is the only record that an operator, not
   the user, is acting; `roles`/`permissions`/`scopes` gate Shōmei's own `/v1/admin` surface and
   every `Require*` route in a host.
3. **Revocation reach.** Access tokens are stateless for 15 minutes by default; everything
   session-aware (refresh, introspection, `VerifyTokenAndSession`) must see a revocation at once.

en-server, as of bf8ffa2, authenticates its own callers with static API keys and explicitly
decided *not* to verify Shōmei JWTs (en plan 33, complete 2026-07-08). Shōmei's
`docs/user/authorization.md` and `security.md` still say the opposite; see finding 12.

## Findings that cross package boundaries

Severity is the review of record's; the component records carry the per-file evidence.

**1. Critical — a delegated or machine token is laundered into a full user session through
`GET /oauth/authorize`.** `Shomei.OAuth.Authorize.Workflow.authorize` stores
`userId = claims.subject` and never reads `claims.actor`
(`shomei-core/src/Shomei/OAuth/Authorize/Workflow.hs:151`); the servant handler authenticates
with `resolveAuthUser`, which accepts any token that verifies
(`shomei-servant/src/Shomei/Servant/Auth.hs:253-256`,
`shomei-servant/src/Shomei/OAuth/Handler.hs:167-173`); the exchange then calls
`issueSessionWith` — a new session row with `actor = Nothing`, a refresh token, and
`buildEnrichedClaims` (`shomei-core/src/Shomei/OAuth/TokenGrant/Workflow.hs:170-175`,
`shomei-core/src/Shomei/Session/Workflow.hs:182-207`). With OIDC enabled and one registered
client (a public client suffices; the attacker generates the PKCE pair and reads the 302
themselves), an operator holding a 30-minute, refresh-less, `roles=∅` impersonation token for
customer C obtains a 30-day refreshable session *as C* with C's full roles and permissions and
no `act`. `denyUnderDelegation` no longer applies, so password change, passkey enrollment, TOTP
removal, and — if C is an administrator — every `/v1/admin` mutation succeed. The same chain
turns a narrowed on-behalf-of token (any service holding `token-exchange:subject`) or a
five-minute `client_credentials` token into a 30-day session of the backing user. It contradicts
`docs/user/security.md` "Two identities, always" and "Short-lived, no refresh". No test presents a
delegated or machine token at `/oauth/authorize`. Remedy: refuse `actor /= Nothing` in
`authorize`, and persist an interactive/non-interactive session kind so machine sessions cannot
authorize either.

**2. High — an SMTP relay that rejects at the DATA stage writes the live one-time token into
stderr and the audit trail.** smtp-mail's `tryCommand` fails with
`"Unexpected reply to: " ++ show cmd`, and for the final command `cmd` is `DATA <whole rendered
message>`; `deliverSmtp` catches it, `truncateError` keeps the first 500 characters — the
password-reset link and its 43-character token sit around offset 368 with the documented
example addresses — and `publishDeliveryFailed` prints it and persists it as
`NotificationDeliveryFailed.errorText` (`shomei-server/src/Shomei/Notify.hs:194-201, 287-333`).
Greylisting (451) is routine at real relays. Anyone with log access, `shomei-admin audit --json`,
or `GET /v1/admin/audit/events` then holds an account-takeover token for its TTL.
`docs/user/notifications.md` promises "never the token". Remedy: never persist
`displayException` of a transport error verbatim; map to a reason code and add a NotifySpec case
for a 451 at DATA.

**3. High — `HashPassword`'s Argon2 derivation escapes the hashing limiter and runs while a pool
connection is held.** `hashPasswordArgon2id` returns `PasswordHash (phcEncode …)` as an unforced
thunk and the `HashPassword` arm is the only one without `evaluate`
(`shomei-postgres/src/Shomei/Account/Password/Hash/Postgres.hs:168-173, 290-298`); the 64 MiB,
~100 ms derivation is forced when hasql serializes the row inside `Pool.use`
(`shomei-postgres/src/Shomei/Account/Credential/Postgres.hs:37-38`). Ten concurrent signups
saturate the ten-connection pool for the hash duration, memory grows by 64 MiB per in-flight
signup with no cap, and the limiter regression test never forces the hash it measures
(`shomei-postgres/test/Main.hs:1878-1896`). The `Verify*` arms are correct. Remedy: force inside
the permit; make the test force its results.

**4. High — the second factor is unthrottled and uncounted.** Login records `LoginSuccess` and
clears the lockout *before* branching to MFA
(`shomei-core/src/Shomei/Session/Authentication/Workflow.hs:253-280`); `completeMfa` failures
publish an audit event only (`shomei-core/src/Shomei/Mfa/Workflow.hs:235-244`); the WAI limiter's
literal path list omits `/v1/auth/mfa/complete`, `/v1/auth/login/passkey/*`, and `/oauth/token`
(`shomei-server/src/Shomei/Server/Middleware/RateLimit.hs:162-172`). A password-holder guesses
TOTP codes bounded only by the login bucket (about 92 hours from one IP at three accepted codes
per step, linearly faster with more IPs). Worse, `DELETE /v1/auth/totp` verifies a code on an
authenticated route the limiter never sees, so a stolen access token is an unbounded TOTP
oracle that ends in factor removal and re-enrollment. Remedy: count second-factor failures
against the account key with lockout, throttle the completion routes, and do not clear the
lockout until the second factor passes.

**5. High — the downstream verification template cannot fetch its JWKS over TLS.**
`examples/microservice-auth-stack/app/Main.hs:34` builds `defaultManagerSettings`, whose TLS hook
throws `TlsNotSupported`; an integrator who copies the file — the docs say to — discovers
`https://` fails and points it at `http://`, at which point an on-path attacker serves a JWKS
containing their own key and forges any `sub`, `roles`, and `permissions` the downstream will
accept. The cache also honours `Cache-Control: max-age` unclamped, so one such response with a
large `max-age` pins the attacker's keys for the process lifetime and disables the documented
24-hour fail-closed bound (`examples/microservice-auth-stack/src/Downstream/Service.hs:156-158,
186, 227, 276`). Remedy: `newTlsManager`; clamp `effectiveTtl` at `maxStaleness`; say in
`docs/user/client-and-examples.md` that a plaintext JWKS is a token-forgery vector.

**6. High — every per-IP control is keyed on the TCP peer, so behind a reverse proxy twenty
wrong passwords from anyone block every login.** The limiter and the login handler both use
`remoteHost` and nothing reads `Forwarded`/`X-Forwarded-For`
(`shomei-server/src/Shomei/Server/Middleware/RateLimit.hs:174-181`,
`shomei-servant/src/Shomei/Session/Handler.hs:134-138`); warp serves plaintext only and
`cookieSecure` defaults on, so production sits behind a TLS terminator by construction. There
the per-IP failure counter (20, never reset by success) makes every user's login answer `429` for
the window, sustained by 20 requests per 15 minutes. The capability catalog admits this; neither
`deployment.md` nor `security.md` does. Remedy: a trusted-proxy CIDR list with rightmost-untrusted
`X-Forwarded-For` (or PROXY protocol), applied before both the limiter and the handlers.

**7. High — an embedding host gets none of the standalone server's runtime protections and is
not told.** Key reload (so `keys revoke` never propagates to an embedded host until restart),
the body cap, the request-rate limiter, the sweeper, `defaultRoles` validation, and graceful
shutdown all live in `Boot.main`; `Boot.application` and both embedded examples are
`serveWithContext` alone (`shomei-server/src/Shomei/Server/Boot.hs:86-148, 370-374`,
`examples/embedded-servant-app/src/Embedded/App.hs:62-66`). The `RateLimited` and
`CsrfProtected` combinators are no-op markers, so an embedded host's OpenAPI advertises 429s it
cannot produce. `security.md`'s "takes effect on a live server with no restart" is true only of
`shomei-server`. Remedy: export the background-task installer and middleware stack from
`shomei-server`, use them in the examples, and add an embedding checklist to the docs.

**8. Medium — RFC 8693 token exchange and delegation verify tokens statelessly.** Subject and
actor tokens go through `verifyAccessToken` only; session revocation, absolute expiry,
`sessionCheckMode`, and the actor's account status are never consulted
(`shomei-core/src/Shomei/OAuth/TokenExchange/Workflow.hs:272-277`,
`shomei-core/src/Shomei/Delegation/Workflow.hs:67-79`). After a password reset revokes every
session, a service can still exchange the dead token for up to one access-token TTL.

**9. Medium — OAuth-client scopes become principal privilege.** Granted client scopes are
unioned into the user's own access token
(`shomei-core/src/Shomei/Session/Workflow.hs:204-206`), and `impersonate:user`,
`shomei:admin`, and `token-exchange:subject` are ordinary scopes with no reserved-name check at
client or service-account registration; a client registered with `--scope shomei:admin` makes
every user who authorizes through it an administrator at `RequireAdmin`.

**10. Medium — three read-then-write sequences that the docs describe as atomic.** The
per-account lockout reads state before hashing and records after, so parallel guesses exceed the
threshold; the password-reset and password-change tails (consume → update hash → revoke sessions
→ revoke tokens → event) are four autocommit statements, so a failure after the hash update
leaves stolen sessions alive; the TOTP `last_used_counter` and passkey `sign_counter` updates
are unconditional, so two concurrent completions with one observed code both succeed. Each is
one `WHERE … RETURNING` away from the shape the refresh-token store already uses.

**11. Medium — the "blind" reset and verification request endpoints leak existence by time.**
A registered email costs a token insert, a synchronous SMTP or webhook delivery inside the
request (10 s / up to 20 s timeouts), and an audit insert; an unknown email costs one `SELECT`.
`security.md` claims the side effect is "invisible to the requester". The locked-account login
branch is a smaller instance of the same class: it answers before any hashing, against the
documented "exactly one password verification".

**12. Medium — the security documentation has drifted from the code in ways an integrator
would act on.** `security.md` cites `shomei-postgres/src/Shomei/Crypto.hs` (gone since plan 48)
and the hash format `argon2id$<salt>$<hash>` (only PHC strings verify; the three-part form is
rejected without hashing); it says the account key is a hash of the email (it is the login id);
`authorization.md`'s "current en-side gaps" were false on the day they were written (en-postgres
already had `runDatabasePool`) and are falser now (en uses pg-migrate and API-key auth; only the
`subjectFromUserId` gap survives); `README.md`'s quick start posts to `/auth/signup`, a `404`
since the `/v1` move; MasterPlan 6 still records "legacy hashes still verify" and 7/3
round-trips where the pinned budget is 10/5. The capability catalog, by contrast, checked clean:
all 58 evidence paths exist and the en story is correctly kept out of it.

## Performance

The hot paths are bounded and indexed. Login is ten port round-trips (one transaction for the
session, first token, and two events) and refresh is five (one transaction for the CAS, child
insert, and event); both are pinned by tests. Every hot lookup — user by login id or email,
credential by login id, session by id, refresh token by hash, login attempts by account key or IP
within the window, role grants and permissions, service account and OAuth client by id, passkey
by credential id, pending ceremony, TOTP by user, recovery codes by user, audit keyset — hits a
matching index, and every sweeper predicate does too. `VerifyTokenOnly` performs no query per
request; the verifier key set and the JWKS body are one immutable value behind one `IORef`.

The costs that are not bounded: the Argon2 escape (finding 3); `shomei_password_credentials`
has no index on `user_id`, so every password change sequentially scans the table; every login
mints a fresh session row (never reused) while `ListSessionsForUser` is unpaginated and admin
revocation issues two statements per row; machine and delegated mints insert a never-reused
session per token (~288 rows/day per five-minute workload) retained thirty days past expiry;
jose's `JWKSet` store ignores `kid`, so an invalid token costs one signature check per published
key; `GET /openapi.json` re-encodes a 7.6k-line document per request; the sweeper drains on the
request pool without pause; and `verifyToken` pins `allowedSkew` to zero with `checkIssuedAt`
on and sub-second `iat`, so a downstream whose clock trails the issuer by a few hundred
milliseconds rejects every fresh token as `iat in the future`.

Two performance-adjacent security notes: ES256, the default, signs through crypton's
`Crypto.PubKey.ECC.ECDSA`, whose module header warns that signature operations may leak the
private key (nonce-dependent branching in `pointMul`); RS256 goes through the blinded
`PKCS15.signSafer`. Exploitability over the network through GHC scheduling noise is unverified,
which is why it is graded medium in REV-3 rather than here. And the Prometheus `method` label
is the raw request-line method, unescaped and unbounded.

## What holds

Verified by reading, with line-level evidence in the component records: Argon2id 64 MiB/3/1
with PHC self-description and constant-time compare; exactly one verification on the unknown-id,
missing-user, wrong-password, and suspended paths with a dummy hash carrying the *configured*
parameters; 32-byte CSPRNG opaque tokens stored only as SHA-256; refresh rotation CAS, family
revocation, absolute expiry, rotated-token cap; one-time tokens single-use by CAS with reset
revoking all sessions and tokens; email-verification gate on login, refresh, and MFA
completion; jose 0.13 refusing `none`, HMAC-with-public-key, and cross-curve/cross-family
verification; iss/aud exact match and required `sub`/`sid` parsed as typed TypeIDs; JWKS
public members only, active + retired, hot-reloaded with last-good retention; ChaCha20-Poly1305
envelope with fresh nonce, `kid` as AAD, 32-byte KEK validated at boot, rewrap decrypt-all-first;
authorization code CAS bound to client, redirect URI, and S256 PKCE; client secrets
constant-time; ID tokens unusable as access tokens; token-exchange chain refusal and gate-scope
stripping; `act` unforgeable through `extraClaims` or the enricher; TOTP RFC 6238 with strict
counter and AES-256-GCM secrets; recovery codes CAS; pending ceremonies consumed once; passkey
ownership re-checked and counter clones failed closed; fully parameterized SQL including the
dynamic audit filters; search_path never leaking past pg-migrate's dedicated connection;
embedding an unlisted migration is a compile error; middleware order as documented; logs
carrying no headers or bodies; HIBP k-anonymity with padding; outbound TLS validating
certificates with no STARTTLS downgrade; CSRF origin check exact with the `.evil.com` suffix
rejected; cookies `HttpOnly`/`Secure`/`Lax` with the refresh cookie path-scoped; bearer mode
ignoring cookies; every admin mutation refusing delegated tokens and self-target
suspend/delete; `sessionCheckMode` wired through the one HTTP verifier; en subject mapping in
both examples using TypeID text and failing closed on every en error.

## Evidence

- `cabal build all --enable-tests` succeeded at ee00382 (GHC 9.12.4).
- `cabal test all --test-options='-j2'`: 13 of 13 suites passed — shomei-core (228 + 62 + 44 +
  35 + 6 + 1 + 1), shomei-jwt, shomei-webauthn (3), shomei-postgres, shomei-servant,
  shomei-servant-openapi, shomei-server (56 + 30 + 25 + 8), shomei-server-config (1),
  shomei-health, shomei-admin, shomei-client, embedded-servant-app, microservice-auth-stack —
  500 cases in total, against an ephemeral PostgreSQL 17.10.
- The review of record re-read `Authorize/Workflow.hs:138-200`, `TokenGrant/Workflow.hs:150-200`,
  `Session/Workflow.hs:175-215`, `OAuth/Handler.hs:155-180`, `Servant/Auth.hs:240-260`,
  `Hash/Postgres.hs:95-125, 160-175, 265-300`, `Credential/Postgres.hs:30-52`,
  `RateLimit.hs:150-185`, `Mfa/Workflow.hs:200-250`, `Authentication/Workflow.hs:250-282`,
  `Notify.hs:188-205, 285-335`, smtp-mail 0.5.0.1 `SMTP.hs:160-180, 310-325`,
  `microservice-auth-stack/app/Main.hs:25-45`, `Embedded/App.hs:55-70`, and `Boot.hs:86-125`
  before grading findings 1–7.

## Coverage and limits

Read in full: every module under `shomei-core`, `shomei-jwt`, `shomei-webauthn`,
`shomei-postgres`, `shomei-migrations` (all 28 migrations), `shomei-servant`, `shomei-server`
(library and executables), `shomei-client`, the three examples, `docs/user/security.md`,
`authorization.md`, `architecture.md`, `deployment.md`, `client-and-examples.md`, the
capability catalog's evidence paths, `README.md`, and `CHANGELOG.md`. Test suites were read
selectively (named scenarios and inventories) rather than line by line; the component records
say which. Not done: dynamic exploitation, latency measurement, a load test, or a build of
`examples/embedded-with-en` from its own `cabal.project` (which has drifted from the root file
it names as its source of truth and lacks the `crypton-x509-validation >= 1.9.1` constraint that
guards CVE-2026-9648).

## Records this review should produce

No bug reports or improvement requests were filed; `produced` is empty because filing them is a
separate decision. The candidates, in the order they should be taken: findings 1–7 as bug
reports; findings 8–11 as bug reports; finding 12 and the documentation items in each component
record as one documentation improvement request; the proxy-awareness, second-factor accounting,
and embedding-checklist work as improvement requests that a MasterPlan can pick up.
