# Multi-factor authentication: TOTP and recovery codes

Shōmei supports two second factors on top of the password:

- **Passkeys** (WebAuthn) — see [passkeys.md](passkeys.md).
- **TOTP** (RFC 6238, the six-digit codes from Google Authenticator, 1Password, Authy, …) —
  this document.

and one lockout escape hatch:

- **Recovery codes** — single-use codes that complete an MFA challenge when the user has lost
  their authenticator (or passkey).

When `webauthnConfig.mfaRequired` is on (the default), an account that has **any** confirmed
second factor — a passkey *or* a confirmed TOTP credential — must complete MFA at login. The
field keeps its name for backward compatibility; its meaning is now "require the second factor
for accounts that have one".

## TOTP parameters

Fixed and **not configurable**, because these are what every mainstream authenticator app
implements: **SHA-1**, a **30-second** period, **6 digits**, and a **±1 step** acceptance window
(tolerating ~30 s of clock skew each way). A verified code is never accepted twice: each
credential remembers the highest time-step counter it has accepted, and only a strictly greater
counter is admitted (RFC 6238 §5.2).

## Enrolling TOTP (authenticated)

Enrollment is two steps: mint a secret, then activate it with a first valid code.

1. `POST /v1/auth/totp/enroll` (bearer token). The response carries the shared secret **once**:

   ```json
   {"secret":"JBSWY3DPEHPK3PXP…","otpauthUri":"otpauth://totp/shomei:alice?secret=JBSWY3DPEHPK3PXP…&issuer=shomei"}
   ```

   `secret` is the RFC 4648 Base32 secret to type by hand; `otpauthUri` is what a QR code encodes
   (render it and let the user scan it). Neither is ever retrievable again — if the user loses it
   before activating, enroll again (an unconfirmed enrollment is replaced).

2. The authenticator app now shows a rotating six-digit code. `POST /v1/auth/totp/verify` with
   that code activates the credential:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' -d '{"code":"492039"}' \
     http://localhost:8080/v1/auth/totp/verify        # -> 200
   ```

   A wrong or stale code returns `401 totp_code_invalid`. Until this step succeeds, login is not
   challenged for TOTP.

Enrollment and removal are refused under a delegated (impersonation) token
(`403 impersonation_action_blocked`) — an operator acting on behalf of a user must not change
that user's factors.

## Logging in with TOTP

1. `POST /v1/auth/login` returns the `mfa_required` arm, now with a `methods` list:

   ```json
   {"status":"mfa_required","ceremonyId":"webauthn_ceremony_01…","options":{},"methods":["totp","recovery_code"]}
   ```

   `methods` tells the client which factors can complete this challenge (`"passkey"`, `"totp"`,
   `"recovery_code"`). For a TOTP-only user `options` is the empty object `{}` (there is no
   WebAuthn ceremony); a passkey holder still gets WebAuthn options and `methods` simply gains the
   entries for any other factors they have enrolled.

2. `POST /v1/auth/mfa/complete` with the ceremony id and the code:

   ```json
   {"ceremonyId":"webauthn_ceremony_01…","totpCode":"719402"}
   ```

   → `200` with the token pair `{"accessToken","refreshToken","expiresIn"}`.

The completion body carries **exactly one** of `assertion` (passkey), `totpCode`, or
`recoveryCode`; sending zero or more than one is `400`. The legacy `{"ceremonyId","assertion"}`
shape is unchanged, so existing passkey-only clients keep working.

**One guess per challenge.** A failed completion spends the consume-once ceremony, exactly as
the passkey flow does — the client logs in again to get a fresh one. Brute force is therefore
bounded to one code guess per password proof.

## Removing TOTP

`DELETE /v1/auth/totp` requires **proof of possession** in the body — a currently valid code, or
an unused recovery code — not merely a fresh session:

```json
{"code":"492039"}                 // or {"recoveryCode":"7Q2FK-9XPRD"}
```

→ `204`. Proving possession of the factor (or its designated fallback) is a stronger gate than
token freshness and matches what major providers do. Removal is also blocked under a delegated
token.

## Recovery codes

`POST /v1/auth/recovery-codes` generates **ten** single-use codes, shown **once**:

```json
{"codes":["7Q2FK-9XPRD","J8M4C-2VNHT", … 10 total]}
```

Regeneration **invalidates the previous set**. Because this prints new secrets, it requires a
recently issued access token: if the presented token is older than
`impersonationConfig.actorFreshnessWindow` (default 5 minutes), it is refused with
`403 reauthentication_required` — log in again and retry. Codes are stored only as SHA-256
hashes; `psql` shows `shomei_recovery_codes.code_hash` as hex, never a plaintext code.

- `GET /v1/auth/recovery-codes` returns `{"remaining":9}` — how many are unused.
- Any code completes an MFA challenge exactly once (`{"ceremonyId","recoveryCode":"…"}`), after
  which the count drops. A spent or unknown code is `401 recovery_code_invalid`.

Recovery codes back up **any** second factor, including passkey-only users, so a user with a
passkey but no TOTP can still generate them.

## Encryption at rest and the key (`SHOMEI_TOTP_ENCRYPTION_KEY`)

A TOTP verifier must recompute `HMAC(secret, counter)` on every login, so the secret must be
stored **retrievably** — it is encrypted (AES-256-GCM), never hashed. The 32-byte key lives
outside the database, read from the environment:

```bash
export SHOMEI_TOTP_ENCRYPTION_KEY=$(openssl rand -base64 32)
```

- When `totpEnabled` is set and this variable is absent or malformed, the server **refuses to
  boot** — an enabled factor whose secrets cannot be encrypted is a silent data-loss trap.
- The key is deliberately not part of the Dhall config file: it is a secret.
- **Losing the key** makes stored TOTP secrets undecryptable. Affected users complete MFA with a
  recovery code or a passkey, remove TOTP, and re-enroll. Recovery-code hashes and passkeys are
  unaffected (they are not encrypted with this key).
- Each stored `secret_enc` is `nonce (12 bytes) || ciphertext || GCM tag (16 bytes)` in one
  `bytea`. When a key-encryption-key (KEK) for signing keys lands, it becomes the natural source
  for this key and the column format will not change.

## Configuration

| Setting | Dhall field | Env var | Default | Meaning |
|---|---|---|---|---|
| enable TOTP | `totpEnabled` | `SHOMEI_TOTP_ENABLED` | `false` | enrollment + login challenge for the factor |
| enrollment TTL | `totpEnrollmentTtlSeconds` | `SHOMEI_TOTP_ENROLLMENT_TTL` | `900` | how long an unconfirmed enrollment stays activatable |
| encryption key | *(env only)* | `SHOMEI_TOTP_ENCRYPTION_KEY` | *(required when enabled)* | base64 of 32 bytes; encrypts stored secrets |
| require MFA | `webauthnMfaRequired` | `SHOMEI_WEBAUTHN_MFA_REQUIRED` | `true` | challenge accounts that have any enrolled factor |

See [api.md](api.md#totp--recovery-codes-masterplan-7-ep-7) for the endpoint reference and
[security.md](security.md) for how these fit the threat model.
