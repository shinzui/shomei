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

## Logging hygiene

The structured request logger reads only the method, path, response status, duration, and peer
IP — never request/response bodies or the `Authorization`/`Cookie` headers — so no password,
token, or cookie can appear in a log line.
