# Shōmei Security Model

This document describes the security-relevant behaviors of Shōmei and the guarantees they
provide. It reflects the implemented code, not aspirations.

## Password hashing

Passwords are hashed with **Argon2id** (`crypton`, in `shomei-postgres/src/Shomei/Crypto.hs`),
stored as `argon2id$<b64 salt>$<b64 hash>`. Verification re-derives from the stored salt and
compares in **constant time** (`Data.ByteArray.constEq`). Plaintext passwords cross the system
only inside a redacting `PlainPassword` newtype (no `Show`/JSON exposure) and never appear in
logs. The minimum-length / policy check runs before hashing.

## Tokens

- **Access tokens** are JWTs signed by the active signing key, carrying the subject (user id),
  session id, issuer, audience, and expiry. They are verified offline against the published JWKS.
  The signing algorithm is configurable: **ES256** (ECDSA P-256, the default) or **RS256**
  (RSASSA-PKCS1-v1_5) — see `SHOMEI_SIGNING_ALG` in [deployment.md](deployment.md). The choice is
  reflected in the key, the JWT header's `alg`, and the JWKS; the `kid` keeps identifying which
  key signed a token, so rotation and multi-key verification work unchanged.
- **Custom claims.** A service embedding Shōmei as a library can attach arbitrary top-level JSON
  claims to every token via `AuthClaims.extraClaims` (e.g. `buildClaimsWith`). They serialize
  alongside the standard claims and are returned on verification. Reserved standard claims (`iss`,
  `sub`, `aud`, `iat`, `exp`, `sid`, `scopes`, `roles`, `act`) **cannot be forged** through the
  bag: `mkExtraClaims` drops them at construction, the signer always writes Shōmei's own value
  last, and `jose` filters the registered claims from the custom map on both sign and verify.
- **Refresh tokens** and the single-use **email-verification** / **password-reset** tokens are
  opaque random strings of which only the **SHA-256 hash** is persisted — a database leak never
  reveals a usable token. Refresh tokens rotate on every use; presenting an already-used token is
  treated as theft and **revokes the entire token family and the session**. The one-time tokens
  are single-use with a TTL.
- **Rotation is a compare-and-swap.** Marking a refresh token used is a single conditional
  statement (`UPDATE … WHERE … AND status = 'active' RETURNING`), so two concurrent
  presentations of the same refresh token can **never both succeed**: exactly one rotates, and
  the loser is treated as reuse — family and session revoked, `401 token_reuse`. The same
  single-winner guarantee holds for the one-time password-reset and email-verification tokens:
  of two concurrent confirmations, exactly one changes the password (or verifies the email);
  the other is rejected as an invalid token.
- **Sessions have an absolute lifetime.** A session dies at `sessionTTL` (default 30 days) after
  it was created, no matter how often it is refreshed: refreshing extends nothing past
  `session.expiresAt`, and every rotated refresh token's expiry is capped at that deadline. Past
  it, `POST /v1/auth/refresh` returns `401 session_expired` and — when `sessionCheckMode` is
  `VerifyTokenAndSession` — so does access-token verification. There is no sliding session.
- **Service tokens** are short-lived access tokens minted through a separate machine-credential
  endpoint. Service account secrets are configured as SHA-256 hex digests, request secrets are
  compared in constant time, requested scopes must be a subset of the account allow-list, and no
  refresh token is issued. See [service-tokens.md](service-tokens.md).

## Signing-key rotation (zero downtime)

Keys move through `pending → active → retired → revoked` (managed by `shomei-admin keys …`):

- `pending` keys exist but are neither used to sign nor published.
- exactly one `active` key signs new tokens and is published.
- activating a new key auto-**retires** the previous active key: it stops signing but **stays in
  the JWKS and stays trusted**, so tokens minted just before the rotation keep verifying until
  they expire. This is what makes rotation zero-downtime.
- `revoked` keys leave the JWKS and are immediately distrusted — the emergency lever for a
  compromised key, deliberately breaking its outstanding tokens.

The published JWKS (`GET /.well-known/jwks.json`) therefore lists both `active` and `retired`
keys during the overlap window. Rotation is also how you **switch signing algorithm** on a live
deployment: `shomei-admin keys generate --alg RS256` then `keys activate <kid>` moves signing to
RS256 while the retired ES256 key keeps verifying its outstanding tokens until they expire.

`shomei-admin` writes to the database; a running server picks the change up by reloading its key
material — the signer, the verifier's key set, and the served JWKS together. It reloads on two
triggers:

- **periodically**, every `SHOMEI_KEY_REFRESH_INTERVAL` seconds (default `60`; `0` disables the
  periodic reload); and
- **on `SIGHUP`** (`kill -HUP <pid>`), for a deterministic "apply now" in a runbook.

So `keys activate` and `keys revoke` take effect on a live server with **no restart**: within one
reload the server signs with the new key while still trusting the retired one, and a revoked key
leaves the JWKS and stops verifying. Because a retired key stays trusted anyway, the only latency
that matters operationally is revocation — tighten the interval or send `SIGHUP` when that
matters.

If a reload fails (the database is unreachable, or an operator retired the only active key so
there is nothing left to sign with), the server logs the failure and **keeps the last good key
material** rather than crashing or serving an empty JWKS. It keeps signing and verifying
meanwhile; the `/ready` probe, which checks for an active key, starts failing so orchestration
notices. Fix the key table with `shomei-admin` and send `SIGHUP` (or wait one interval) to
recover.

## Cookie transport & CSRF

By default Shōmei speaks bearer tokens: the client stores the access token and sends
`Authorization: Bearer …`. That is simple and CSRF-immune, but it means the token lives somewhere
JavaScript can read it, so an XSS bug becomes a session compromise.

Setting `SHOMEI_TOKEN_TRANSPORT=cookie` moves both tokens into **`HttpOnly` cookies**, which page
JavaScript cannot read at all, and stops the JSON bodies from carrying them — an XSS payload
cannot exfiltrate what was never serialized.

- `shomei_session` — the access token. `Path=/`, `Max-Age` = `accessTokenTTL`.
- `shomei_refresh` — the refresh token. `Path=/v1/auth/refresh`, `Max-Age` = `refreshTokenTTL`, so
  the browser presents this long-lived credential to exactly one endpoint.

Both carry `HttpOnly`, `Secure` (`SHOMEI_COOKIE_SECURE`, default on — browsers exempt localhost
from the HTTPS requirement), and `SameSite` (`SHOMEI_COOKIE_SAMESITE`, default `Lax`).

**Cookies buy XSS resistance and hand you a CSRF problem.** A browser attaches cookies to a
request automatically, even one triggered by a page on an attacker's site. The attacker cannot
read the response — CORS forbids it — but does not need to: the *side effect* (a logout, a
password change, a deleted passkey) is the attack. Shōmei defends in two layers:

1. **`SameSite=Lax`** tells the browser not to attach these cookies to cross-site POSTs at all.
2. **An `Origin` allow-list**, checked server-side on every **cookie-authenticated mutating
   request** (anything but `GET`/`HEAD`/`OPTIONS`). Browsers set `Origin` to the initiating page's
   origin and JavaScript cannot forge it. If `Origin` is absent, a `Referer` under an allowed
   origin is accepted; the prefix must end at a `/` or the string's end, so
   `http://localhost:8080.evil.com` does not satisfy an allow-list containing
   `http://localhost:8080`. With neither header the request is **refused** —
   `403` with `code: "csrf_rejected"` — because a cookie-only mutating request with no origin
   information is either a non-browser client that should be sending a bearer token, or an attack.

Set the allow-list with `SHOMEI_CSRF_ALLOWED_ORIGINS`. It defaults to `http://localhost:8080` for
the turnkey dev experience; **production deployments must set their real origins.**

There is deliberately no double-submit CSRF token: Shōmei's mutating surface is JSON-over-POST,
not HTML forms, so `SameSite` plus the `Origin` check covers it without requiring every embedder's
frontend to mirror a token into a header.

**Bearer credentials are never CSRF-gated**, in any transport. A foreign page cannot set an
`Authorization` header, so there is nothing to defend against — and gating them would break curl,
native clients, and the service-token flow.

**Bearer mode does not accept cookies.** A deployment configured for `bearer` ignores
`shomei_session` entirely; presenting it yields `401`. (Before this was fixed, the cookie was read
as a credential in *every* deployment regardless of configuration — a live read path for a feature
nothing else implemented.)

## Signing-key encryption at rest

**The threat.** The private signing key is the most powerful secret Shōmei holds: whoever has
it can mint a valid token for any user of any downstream service that trusts the JWKS. By
default it is stored as plaintext JWK JSON in `shomei_signing_keys.private_key_jwk`, so a
database read — a dump, a backup, a misconfigured replica, a `SELECT` from a compromised
reporting account — is enough to forge tokens indefinitely. Passwords and refresh tokens in
this database are protected at rest; without the setting below, this key is not.

**The fix.** Set `SHOMEI_KEY_ENCRYPTION_KEY` to a 32-byte base64 key-encryption key (KEK) that
lives outside the database, and Shōmei envelope-encrypts every private key under it:

```text
private_key_jwk = "enc:v1:" <base64url nonce> ":" <base64url ciphertext+tag>
```

The cipher is ChaCha20-Poly1305 with a fresh 12-byte nonce per encryption. The AEAD
*associated data* is the key's `kid`, which binds each ciphertext to its own row: an attacker
with database **write** access cannot relabel an old, compromised key as the active one,
because it no longer authenticates under the new `kid`. Forging tokens now requires the
database **and** the application environment.

There is no schema change — the format is versioned inside the existing `text` column — so
plaintext and encrypted rows coexist and a backfill can run against a live server.

**Only signing depends on the KEK.** The published JWKS and the verifier's key set are built
from the `public_key_jwk` column, which is never encrypted. A missing or wrong KEK can
therefore stop Shōmei minting *new* tokens, but can never break verification of outstanding
ones, and never changes what `/.well-known/jwks.json` serves.

**Boot policy.**

| Rows | KEK set? | Behavior |
|------|----------|----------|
| encrypted | no | **refuses to start**: `signing keys are encrypted at rest but SHOMEI_KEY_ENCRYPTION_KEY is not set` |
| encrypted | wrong | **refuses to start**, naming the key that failed to decrypt |
| encrypted | yes | starts; new keys are written encrypted |
| plaintext | no | starts, with a warning recommending encryption (nothing breaks on upgrade) |
| plaintext | yes | starts, warns, and writes all *new* keys encrypted; run `keys encrypt-at-rest` |

Refusing is the only safe response to encrypted-rows-without-a-KEK: the alternatives are a
server that cannot sign, or one that silently generates a replacement key and orphans every
outstanding token.

**Operating it.** See [deployment.md](deployment.md) for the migration and KEK-rotation
runbooks. Two commands matter:

- `shomei-admin keys encrypt-at-rest` — encrypt every plaintext row. Idempotent; safe to run
  against a live server (each row is one atomic `UPDATE`, and a running server reads both
  forms).
- `shomei-admin keys rewrap` — rotate the KEK itself, decrypting with
  `SHOMEI_KEY_ENCRYPTION_KEY_OLD` and re-encrypting with `SHOMEI_KEY_ENCRYPTION_KEY`. It runs
  the full decrypt pass in memory before its first write, so a wrong old KEK aborts having
  modified nothing.

**Losing the KEK loses the keys.** There is no recovery path — that is the point of the
scheme. Back the KEK up exactly as carefully as the database, and separately from it. If it is
truly lost, the honest remedy is to delete the encrypted rows and generate a fresh signing key;
every outstanding token dies.

**KMS/HSM** integration is the operator's layer: inject the KEK from your secret manager
(Vault, AWS KMS, GCP Secret Manager, …) into the process environment. Shōmei deliberately
knows nothing about where it came from.

Note that `SHOMEI_KEY_ENCRYPTION_KEY` is **not** part of `ShomeiConfig`. That record derives
`Show` and `ToJSON` and is logged; a secret in it would be one debug line from disclosure.

## No account-existence leakage

Login returns a single generic `401 invalid_login` for a wrong password, an unknown account, and
a **locked** account — they are byte-for-byte identical at the boundary, and the core `login`
workflow itself returns `InvalidCredentials` for all three so even a direct caller cannot
distinguish them. The `verify-email/request` and `password-reset/request` endpoints always return
`202` whether or not the email exists; the only difference (a notification side effect) is
invisible to the requester.

Identical bytes are not enough on their own: a response that arrives sooner is just as much a
disclosure. Verifying a password with Argon2id deliberately costs ~100 ms, so a login that
short-circuits before hashing — an unknown identifier, a credential row whose user is gone, a
suspended account — would answer in microseconds and thereby announce that the account does not
exist (or exists and is suspended). Every failing login therefore performs **exactly one**
password verification: the paths that never reach a stored hash verify against a fixed dummy
Argon2id hash instead, so all of them pay the same cost.

### Signup deliberately discloses existence

`POST /v1/auth/signup` answers `409 email_taken` / `409 login_id_taken` when the identifier is
already registered, which does tell the caller that an account exists. This is accepted product
behavior — signup forms need to say "that address is already registered" — and it is the reason
the reset and verification flows are deliberately blind: they always answer `202`, so an attacker
cannot use *them* to enumerate. The asymmetry is intentional, not an oversight.

## Email verification enforcement

`notifierConfig.emailVerificationRequired` (Dhall key `emailVerificationRequired`; default off)
gates **token issuance** on a verified email address. With it on:

- password login, refresh, MFA completion, and passwordless passkey login all refuse an account
  whose email is present but unverified, with `403 email_not_verified`;
- `POST /v1/auth/signup` still returns its initial token pair. The gate closes at the first refresh,
  so an unverified account keeps working for at most one access-token lifetime (default 15
  minutes) and cannot renew silently;
- an account with **no** email address is exempt — it could never complete verification, so
  gating it would permanently lock out login-id-only accounts;
- confirming the verification token unblocks the account immediately.

`403 email_not_verified` is deliberately distinct from the generic `401 invalid_login`, and that
is not an enumeration leak: every path that can return it has already proven control of the
account (a correct password, a valid refresh token, or a verified passkey assertion). A generic
`401` would instead strand a legitimate user who has no way to learn they must click the link.

## Abuse protection (EP-2)

- **Per-account brute-force lockout** (PostgreSQL-backed, survives restarts): after
  `maxFailedLoginsPerAccount` failures (default 5) within `lockoutWindow` (default 15 min) an
  account is locked for `lockoutDuration` (default 15 min). The account key stored in the abuse
  tables is a SHA-256 of the normalized email, never the plaintext. Counting is "failures since
  the most recent success", so a successful login resets the counter.
- **Per-IP failure throttle**: after `maxFailedLoginsPerIp` failures (default 20) from one IP the
  next attempt returns `429`. This count does **not** reset on a successful login (so an attacker
  cannot clear it by logging into their own account).
- **Per-IP request-rate limit**: an in-process token bucket (default 60 req/min, burst 60) on the
  unauthenticated POST endpoints rejects over-rate requests with `429` before they reach the
  application or the database.

These protections target a single-instance deployment; the lockout state is durable (PostgreSQL)
while the request-rate buckets are in-memory and reset on restart.

## Session revocation

A successful password reset or change revokes **all** of the user's sessions and refresh tokens,
so a stolen session is immediately useless after the legitimate owner recovers the account.

**Revocation visibility with stateless tokens.** Revoking a session (via
[`POST /oauth/revoke`](oidc.md#introspection-and-revocation), an admin action, or a password reset)
takes effect immediately for anything session-aware: `POST /oauth/introspect` reports the token
inactive, refresh stops, and a deployment running `sessionCheckMode = VerifyTokenAndSession` rejects
the access token on the next request. But under the default `sessionCheckMode = VerifyTokenOnly`, an
already-issued **access token is a stateless JWT** and keeps being accepted until its `exp` — access
tokens are short-lived (15 minutes by default) precisely to bound this window. This is the honest
semantics of a stateless-JWT provider; it is documented rather than hidden. Deployments that need
immediate access-token rejection set `VerifyTokenAndSession` and pay a session read per request.

## Passkeys & MFA (MasterPlan 3)

- **Phishing-resistant second factor.** A passkey signs a server challenge bound to the page
  origin and the configured `rpId`; the signature cannot be replayed against another origin, so a
  phished password alone never yields a session. Accounts that have a passkey are challenged for
  it at login when `webauthnConfig.mfaRequired` is set (the default).
- **Consume-once challenge.** The pending-ceremony state (the challenge/options blob) is
  **PostgreSQL-backed** and consumed exactly once: a completion deletes the row, so a replayed or
  duplicated completion finds nothing and is rejected (`404 ceremony_not_found`). Ceremonies
  expire via a TTL (`webauthnConfig.pendingCeremonyTTL`).
- **Signature-counter clone check.** Each stored credential keeps a signature counter; a
  verification whose counter does not advance past the stored value signals a cloned authenticator
  and fails closed (`401 mfa_failed`).
- **Public keys only.** Shōmei stores only the credential's public key and metadata — never a
  private key or any reusable secret. A database leak cannot impersonate a user.
- **No factor-failure leak.** A failed assertion returns a generic `401 mfa_failed`; the response
  never discloses why a factor failed.
- **MFA enforcement policy.** Enforcement is gated on per-account enrollment *and*
  `webauthnConfig.mfaRequired`: an account with no passkey (or with `mfaRequired = False`) logs in
  exactly as before. The password remains the first factor, so the existing password-reset flow
  still recovers an account whose passkey was lost. See [passkeys.md](passkeys.md).

## Impersonation / delegated tokens

Shōmei can mint a **delegated token** so an authorized operator acts on behalf of a customer
without shedding their own identity.

- **Two identities, always.** The delegated access token carries the customer as `sub` and the
  real operator as `act` (RFC 8693 token-exchange convention). Every downstream service reads both
  out of the verified token to drive write-attribution, a UI banner, and business-action gating.
  The `act` claim is present **only** on delegated tokens; ordinary login tokens never carry it.
- **Short-lived, no refresh.** A delegated session is a brand-new, separately-revocable row with a
  short TTL (`impersonationConfig.impersonationSessionTTL`, default 30 minutes) and **no refresh
  token**, so it cannot be silently renewed and dies at its TTL. The customer's own session is
  never reused or copied.
- **Scope + freshness gate.** Starting impersonation requires the `impersonate:user` scope and a
  recently-issued caller token (`impersonationConfig.actorFreshnessWindow`, default 5 minutes).
  *(Recent authentication is enforced as a token-freshness window, not yet as an interactive MFA
  re-prompt — a future plan can add a step-up ceremony and require it here.)*
- **Credential endpoints refuse delegated tokens.** Password change and passkey
  enrollment/removal return `403 impersonation_action_blocked` for any delegated token: an operator
  can look but cannot change the customer's credentials. Each blocked attempt is audited.
- **Everything is audited with both ids.** `impersonation_started` (with reason, ticket id, and
  client IP), `impersonation_action_blocked`, and `impersonation_stopped` are written to
  `shomei_auth_events` carrying both the actor and subject user ids.
- **Out of scope, by design.** Who-may-impersonate-whom policy (e.g. "no impersonating another
  admin"), the support console UI, ticket-workflow validation, and blocking of *business* actions
  live in the services that embed Shōmei. Only the token mint/verify layer can guarantee the
  two-identity invariant and refuse its own credential changes, so that is exactly what lives here.

**Standards surface (RFC 8693).** The same delegated-token machinery is reachable as a standard OAuth
2.0 token-exchange grant at `POST /oauth/token`
(`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`), so stock tooling can drive it. In
impersonation mode the operator sends the target as a bare user id
(`subject_token_type=urn:shomei:params:oauth:token-type:user-id`) with their own access token as the
`actor_token`; the grant enforces the *same* scope gate, freshness gate, refresh-less session, and
`impersonation_started` audit event as `POST /v1/auth/impersonate`, because both share one workflow
core (`mintDelegatedToken`) and cannot drift. The grant additionally offers a **service on-behalf-of**
mode — a service account exchanges a user's access token for a narrowed token that acts for the user
across service hops, gated by the dedicated `token-exchange:subject` scope (see
[service-tokens.md](service-tokens.md#acting-on-behalf-of-a-user)). `POST /v1/auth/impersonate` is now
deprecated in favor of the grant; it keeps working through a deprecation window, and
`DELETE /v1/auth/impersonate` still stops an exchanged impersonation token. Chained exchanges are
refused: a token already carrying `act` cannot be re-exchanged.

## Logging hygiene

The structured request logger reads only the method, path, response status, duration, and peer
IP — never request/response bodies or the `Authorization`/`Cookie` headers — so no password,
token, or cookie can appear in a log line.

The built-in `LogNotifier` (which writes password-reset and email-verification notifications to
the server log) redacts the one-time token. It logs the first 8 hex characters of the token's
SHA-256 instead, and no link:

```text
[shomei:log] password_reset email=a@example.com token_sha256=f6dd8191 expires_at=… (set SHOMEI_NOTIFIER_LOG_SECRETS=true to log the full link in development)
```

That prefix is a correlation handle, not a secret: the token is 32 random bytes, and the stored
`token_hash` column is the SHA-256 of the same token (base64url rather than hex), so a log line
can be tied to its database row without the log ever carrying anything redeemable.

Setting `SHOMEI_NOTIFIER_LOG_SECRETS=true` restores the full clickable link. It exists because
`LogNotifier` is a **development** interpreter, where the logged link is how you complete the
flow. There is deliberately no Dhall-file key for it: enabling it must be an explicit
per-process decision, not a line that lingers unnoticed in a committed config file. Anyone who
can read the log of a server running with it can take over any account mid-reset.

## Roles and authorization

Shōmei has a **two-tier authorization story**, and it matters which tier you are in.

**Tier 1 — Shōmei's built-in roles.** Flat, `(user, role)` grants stored in Shōmei's own
database and copied into the `roles` claim of every access token it mints. They need no extra
infrastructure, they are what gates Shōmei's own `/admin` surface, and they are the right tool
for coarse questions: *is this principal an administrator? a support agent? a paying member?*

**Tier 2 — fine-grained authorization.** Questions of the form *is this user an editor **of
this project**?* — resource-scoped permissions, access derived from relationships, revocation
that takes effect immediately, conditional access. Shōmei deliberately does **not** grow into
this, because a JWT claim is the wrong transport for it (see [Staleness](#staleness-role-changes-apply-at-the-next-mint)).
The recommended graduation path is **en**, the sibling Zanzibar-style ReBAC toolkit. Its
integration guide will live at `docs/user/authorization.md`; until it lands, the design is in
[plan 47](../plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md).

Within tier 1, permission indirection (so services never hard-code role names) and time-bound
grants are planned in
[plan 46](../plans/46-role-definitions-permissions-and-time-bound-grants.md). The built-in tier
grows; it is not deprecated in favor of en.

The two tiers compose rather than compete. Even a deployment that adopts en keeps Shōmei's flat
roles: en's server authenticates its callers by verifying Shōmei JWTs, so *something* outside en
has to say who the administrator is. Shōmei's built-in tier is that something, and it is never
removed in favor of en.

### The role registry

A role must be **declared** before it can be granted. The registry is the `shomei_roles` table,
seeded with `admin` when you migrate:

```text
$ shomei-admin roles list-defined
admin — Full access to the shomei /admin surface and admin CLI-equivalent HTTP routes

$ shomei-admin roles define auditor --description "read the audit trail"
defined role auditor
```

This exists to close a silent failure mode. Without a catalog, `roles grant --role adminn` (a
typo) would succeed and mint a role nothing ever checks — the request looks like it worked, and
the account quietly has no access. With one, it fails loudly:

```text
$ shomei-admin roles grant --user user_01ABC… --role adminn
shomei-admin: role not defined: adminn (define it first: shomei-admin roles define adminn)
$ echo $?
1
```

A foreign key from `shomei_role_grants.role` into the registry enforces the same invariant for
any code that bypasses the workflow. The registry is append-only: there is no `roles undefine`.

### Granting roles

```text
$ shomei-admin roles grant  --user user_01ABC… --role admin     # or a bare UUID
granted admin to user_01ABC…
$ shomei-admin roles list   --user user_01ABC…
admin
$ shomei-admin roles revoke --user user_01ABC… --role admin
revoked admin from user_01ABC…
```

This is the **bootstrap path for your first administrator**: `/v1/admin/*` is gated on the `admin`
role, so the first grant has to come from outside HTTP. After that, roles can be granted over HTTP
with `PUT /v1/admin/users/{userId}/roles/{role}` (see the [Admin API](api.md#admin-api)).

Grants and revocations are audited as `role_granted` / `role_revoked`; a CLI grant records no
acting admin (there is no authenticated principal on the box), while an HTTP grant records the
admin who performed it. Both `grant` and `revoke` are idempotent at the CLI, and only a real state
change publishes an audit event. (Over HTTP, `PUT` is likewise idempotent, but `DELETE` of a role
the user does not hold is a `404`, so a typo in the role name is visible rather than silent.)

### Administering over HTTP

The `/v1/admin/*` surface accepts the `admin` **role** or the `shomei:admin` **scope**. The role is
for humans; the scope is minted onto a service token so a database-less support console can
administer without a role grant. Two refusals are worth knowing about:

- A **delegated (impersonation) token cannot administer.** An operator impersonating a customer
  gets `403 impersonation_action_blocked` on every admin mutation, and the refusal is itself
  audited. Otherwise impersonation would launder privilege: act as the customer, then act as an
  admin "as" them.
- An **administrator cannot suspend or delete their own account** (`403 self_target_forbidden`).
  One mistyped user id must not be able to lock the last administrator out of a deployment. The
  CLI on the box remains the escape hatch for genuinely removing an admin. Revoking your *own*
  sessions is allowed.

Suspending or deleting a user revokes their sessions at once, so they cannot refresh. Their
outstanding **access** tokens keep working until they expire (default 15 minutes) unless you set
`sessionCheckMode = VerifyTokenAndSession`, which re-reads the session on every request. If you
need a suspension to bite instantly, that is the setting; the cost is one database read per
authenticated request.

### Default roles for new users

Set `defaultRoles` in the Dhall config (or `SHOMEI_DEFAULT_ROLES=member,beta-tester`) and every
new user receives them at signup — applied *inside* the signup workflow, before the first token
is minted, so that token already carries them. `shomei-admin users create` drives the same
workflow and behaves identically.

Every name must already be in the registry. The server **refuses to start** otherwise, rather
than failing at each signup:

```text
shomei-server: defaultRoles names undefined roles: nosuchrole
define them first: shomei-admin roles define nosuchrole
```

### Enforcing a role or scope on a route

`RequireRole` and `RequireScope` are Servant combinators that authenticate the caller and check
the claim before the handler runs:

```haskell
type AdminAPI = RequireRole "admin" :> "admin" :> "users" :> Get '[JSON] [User]
```

No token → `401`. Token without the role → `403`. The handler receives the `AuthUser` and needs
no authorization code of its own — which is the point: a guard you can forget to call is a
route that silently ships unprotected.

`RequireRole` **replaces** `Authenticated`; do not write both. For a condition a single symbol
cannot express (role `admin` *or* scope `shomei:admin`), the handler guards `requireRole` and
`requireScope` remain available.

### Staleness: role changes apply at the next mint

An access token is self-contained. Shōmei does **not** re-read the role store when it verifies
one, which is exactly why verification needs no database round-trip. So:

> **A granted or revoked role takes effect on the next token mint — the next login or refresh —
> never on an access token that has already been issued.**

The access-token TTL (15 minutes by default) bounds the window. If you have just revoked a role
from a compromised account and cannot wait, **revoke its sessions**: that kills the refresh path
so no further tokens can be minted, and the outstanding access token expires on its own.

This is also the reason not to mirror a live authorization decision into a claim: a copied
decision is stale the moment the underlying fact changes, silently granting revoked access until
the token expires. Check fine-grained permissions live, in the handler.

### The claims-enrichment hook (embedding hosts)

Hosts that embed Shōmei can add claims to every user-session token through the `ClaimsEnricher`
effect, the same way they supply a `Notifier`:

```haskell
runClaimsEnricherPure \userId rolesFromStore ->
  emptyClaimsDelta { extraClaims = KeyMap.fromList [("tenant", toJSON tenantId)] }
```

The hook returns a *delta* — extra roles, extra scopes, an extra-claims object — which Shōmei
merges into the standard claims. It cannot rewrite them: the object is filtered through
`mkExtraClaims`, so `iss`, `sub`, `aud`, `iat`, `exp`, `sid`, `scopes`, `roles`, and `act` can
never be forged through it. The standalone server uses `runClaimsEnricherNull` and adds nothing.

Use it for coarse, slow-moving facts: tenant ids, plan tiers, extra scopes. **Do not** use it to
mirror per-resource permissions from a live authorization system — see the staleness note above.

## Reading the audit trail (EP-7)

Every security-significant action is written as one row in the append-only
`shomei_auth_events` table (`event_id`, denormalized `user_id`/`session_id`, an `event_type`
string, a JSONB `payload`, and `created_at`). There are two ways to read it back; both sit on
the same query layer (`Shomei.Effect.AuthEventReader`), so filtering, ordering, and pagination
behave identically.

The trail is **retained forever by default.** Shōmei's background sweeper deletes expired rows
from every other table but will not touch audit history unless you set
`SHOMEI_AUTH_EVENT_RETENTION_DAYS` — regulatory retention floors and data-minimization ceilings
pull in opposite directions, and only you can resolve that. See
[deployment.md](deployment.md#audit-event-retention-is-off-by-default).

- **CLI — the supported operator path.** `shomei-admin audit …` queries the trail directly
  (no HTTP, no token), reading the same `DATABASE_URL`/`PG_CONNECTION_STRING` the other admin
  subcommands use:

  ```text
  shomei-admin audit events  [--user UUID] [--session UUID] [--type T ...] [--since TS] [--until TS] [--limit N] [--json]
  shomei-admin audit user    <UUID>    # shortcut for --user
  shomei-admin audit session <UUID>    # shortcut for --session
  shomei-admin audit count   [filters]
  ```

  Default output is one tab-separated line per event
  (`created_at⇥event_type⇥user_id⇥session_id⇥event_id`), newest first; `--json` emits one JSON
  object per line (NDJSON) including the raw payload. Results are keyset-ordered on
  `(created_at, event_id)`; `--limit` defaults to 50 and is clamped to 1000.

- **HTTP — `GET /v1/admin/audit/events`.** The same filters as query parameters
  (`?user=&session=&type=&type=&since=&until=&limit=&before=`), returning
  `{ "events": [ … ], "nextCursor": … }`; pass `nextCursor` back as `?before=` to page. The
  route type carries `RequireRole "admin"`, so a request with no token gets `401` and one whose
  token lacks the role gets `403` — before the handler runs. Grant the role with
  [`shomei-admin roles grant`](#granting-roles).

### Operator runbook: investigate a suspected brute-force attempt

```text
# How many failed logins in total, and recently?
$ shomei-admin audit count --type login_failed
42
$ shomei-admin audit count --type login_failed --since 2026-06-17T00:00:00Z
8

# List the most recent failures (tab-separated: created_at, type, user_id, session_id, event_id)
$ shomei-admin audit events --type login_failed --limit 5
2026-06-17T10:00:00Z    login_failed    -    -    26629df2-1479-4867-8c5e-cca398277cb0
...

# Did the account ultimately get locked or throttled? Pull its whole timeline.
$ shomei-admin audit user 019eb2eb-ac04-747e-9e70-ea4db1bd446e
2026-06-17T10:05:00Z    account_locked     019eb2eb-…  -           …
2026-06-17T10:01:00Z    login_succeeded    019eb2eb-…  019eb2ec-…  …

# Feed structured rows into jq / a SIEM:
$ shomei-admin audit events --type account_locked --json | jq -c '{at: .createdAt, user: .userId, payload}'
```
