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

- **Access tokens** are ES256 (P-256) JWTs signed by the active signing key, carrying the subject
  (user id), session id, issuer, audience, and expiry. They are verified offline against the
  published JWKS.
- **Refresh tokens** and the single-use **email-verification** / **password-reset** tokens are
  opaque random strings of which only the **SHA-256 hash** is persisted — a database leak never
  reveals a usable token. Refresh tokens rotate on every use; presenting an already-used token is
  treated as theft and **revokes the entire token family and the session**. The one-time tokens
  are single-use with a TTL.

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
keys during the overlap window.

## No account-existence leakage

Login returns a single generic `401 invalid_login` for a wrong password, an unknown account, and
a **locked** account — they are byte-for-byte identical at the boundary, and the core `login`
workflow itself returns `InvalidCredentials` for all three so even a direct caller cannot
distinguish them. The `verify-email/request` and `password-reset/request` endpoints always return
`202` whether or not the email exists; the only difference (a notification side effect) is
invisible to the requester.

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
