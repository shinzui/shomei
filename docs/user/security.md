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
  it, `POST /auth/refresh` returns `401 session_expired` and — when `sessionCheckMode` is
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

`POST /auth/signup` answers `409 email_taken` / `409 login_id_taken` when the identifier is
already registered, which does tell the caller that an account exists. This is accepted product
behavior — signup forms need to say "that address is already registered" — and it is the reason
the reset and verification flows are deliberately blind: they always answer `202`, so an attacker
cannot use *them* to enumerate. The asymmetry is intentional, not an oversight.

## Email verification enforcement

`notifierConfig.emailVerificationRequired` (Dhall key `emailVerificationRequired`; default off)
gates **token issuance** on a verified email address. With it on:

- password login, refresh, MFA completion, and passwordless passkey login all refuse an account
  whose email is present but unverified, with `403 email_not_verified`;
- `POST /auth/signup` still returns its initial token pair. The gate closes at the first refresh,
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

## Reading the audit trail (EP-7)

Every security-significant action is written as one row in the append-only
`shomei_auth_events` table (`event_id`, denormalized `user_id`/`session_id`, an `event_type`
string, a JSONB `payload`, and `created_at`). There are two ways to read it back; both sit on
the same query layer (`Shomei.Effect.AuthEventReader`), so filtering, ordering, and pagination
behave identically.

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

- **HTTP — `GET /admin/audit/events`.** The same filters as query parameters
  (`?user=&session=&type=&type=&since=&until=&limit=&before=`), returning
  `{ "events": [ … ], "nextCursor": … }`; pass `nextCursor` back as `?before=` to page. The
  endpoint is gated by `requireRole (Role "admin")`: a non-admin token gets `403`, no token
  `401`.

**Known limitation — the `admin` role.** Shōmei's signup/login workflows do **not** issue roles
in tokens, so there is currently no production flow that mints an `admin`-roled token. The HTTP
endpoint is therefore exercised today only by tests (and by deployments that mint admin tokens
out of band); the **CLI is the working operator retrieval path**. The endpoint is gated
correctly now so it is safe and immediately usable the moment a role-granting mechanism exists —
a natural follow-up (e.g. a `shomei-admin users grant-role` command and a claim source), not
implemented here.

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
