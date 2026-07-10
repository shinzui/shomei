# Passkeys & Multi-Factor Authentication

A *passkey* is a public-key credential your device holds — Touch ID/Face ID on a phone or Mac,
Windows Hello, a hardware key like a YubiKey, or a synced provider like iCloud Keychain or
1Password. The private key never leaves the device; Shōmei stores only the matching public key.
*Multi-factor authentication* (MFA) means proving who you are with two independent things: a
password you know, plus a device you have. After enrolling a passkey, a Shōmei account is
protected by both — a stolen password alone no longer grants a session.

Shōmei uses passkeys two ways: as a **second factor** on top of the password (the default,
"step-up"), and as a **passwordless** login on their own. Enrollment always happens while
already logged in.

The browser side uses [`@github/webauthn-json`](https://github.com/github/webauthn-json), which
converts between the base64url JSON Shōmei speaks and the binary objects
`navigator.credentials` needs. Shōmei passes every `options`/`credential`/`assertion` value
through verbatim as JSON; the cryptographic verification is entirely server-side. The complete
HTTP surface is in [api.md](api.md); the security properties are summarized in
[security.md](security.md).

## 1. Enrolling a passkey (authenticated)

1. The browser POSTs to `/v1/auth/passkeys/register/begin` with the user's bearer token and an
   empty body. The server replies with `{ "ceremonyId": "...", "options": { ... } }`. `options`
   is the WebAuthn *creation options* — a random challenge, the relying-party id, the user's
   handle, and the list of already-enrolled credentials to exclude.
2. The browser calls `navigator.credentials.create({ publicKey: options.publicKey })` (via the
   `@github/webauthn-json` helper, which handles the base64url ↔ binary conversion). The device
   prompts the user (a fingerprint, a PIN, a tap) and mints a fresh key pair.
3. The browser POSTs to `/v1/auth/passkeys/register/complete` with the bearer token and
   `{ "ceremonyId": "<from step 1>", "credential": <the create() output>, "label": "Ada's
   YubiKey" }`. The server verifies the credential and stores the public key, returning the
   stored passkey `{ "passkeyId", "label", "transports", "createdAt", "lastUsedAt" }`.

List with `GET /v1/auth/passkeys`; remove one with `DELETE /v1/auth/passkeys/{passkeyId}` (`204`).

## 2. Logging in with password + passkey (MFA step-up)

1. POST `/v1/auth/login` with `{ "email", "password" }` as usual. If the account has a passkey
   (and `mfaRequired` is on), the response is **not** tokens — it is
   `{ "status": "mfa_required", "ceremonyId": "...", "options": { ... } }`, where `options` is
   the WebAuthn *authentication options* (a fresh challenge plus the allowed credentials).
   An account *without* a passkey still gets `{ "status": "complete", "user", "token" }`.
2. The browser calls `navigator.credentials.get({ publicKey: options.publicKey })`. The device
   signs the challenge with the passkey's private key.
3. POST `/v1/auth/mfa/complete` with `{ "ceremonyId": "<from step 1>", "assertion": <the get()
   output> }`. The server verifies the signature and returns the access/refresh token pair
   `{ "accessToken", "refreshToken", "expiresIn" }`.

   In cookie transport (`SHOMEI_TOKEN_TRANSPORT=cookie`) this response sets the
   `shomei_session`/`shomei_refresh` cookies instead and the body carries only `expiresIn` — see
   [Token transport](api.md#token-transport).

If step 3 is never performed (or fails), no usable token is ever issued — possession of the
password alone does not grant a session. A failed assertion returns `401 mfa_failed`; a
missing/expired/already-consumed ceremony returns `404 ceremony_not_found`.

## 3. Passwordless passkey login

1. POST `/v1/auth/login/passkey/begin` (no password). The response is
   `{ "ceremonyId": "...", "options": { ... } }` — WebAuthn authentication options for
   discoverable credentials.
2. The browser calls `navigator.credentials.get({ publicKey: options.publicKey })`.
3. POST `/v1/auth/login/passkey/complete` with `{ "ceremonyId": "...", "assertion": <get()
   output> }`. On success the response is the token pair `{ "accessToken", "refreshToken",
   "expiresIn" }` directly (the passkey is the strong factor, so there is no second challenge).
   As above, cookie transport moves the tokens into cookies and omits them from the body.

## Configuration

The WebAuthn policy lives in the `webauthnConfig` sub-record of `ShomeiConfig`. Like every other
setting it is loaded with twelve-factor precedence: built-in defaults → the Dhall config file at
`$SHOMEI_CONFIG` (if set) → individual `SHOMEI_WEBAUTHN_*` environment variables (env always
wins). See [deployment.md](deployment.md) for the loader overview.

| Field (`webauthnConfig`) | Dhall key | Env var | Default | Meaning |
|---|---|---|---|---|
| `rpId` | `webauthnRpId` | `SHOMEI_WEBAUTHN_RP_ID` | `localhost` | the registrable domain a passkey is bound to (no scheme, no port) |
| `rpName` | `webauthnRpName` | `SHOMEI_WEBAUTHN_RP_NAME` | `Shōmei` | human label shown by the authenticator UI |
| `origins` | `webauthnOrigins` | `SHOMEI_WEBAUTHN_ORIGINS` | `["http://localhost:8080"]` | exact page origins allowed to run ceremonies (env: comma-separated) |
| `userVerification` | `webauthnUserVerification` | `SHOMEI_WEBAUTHN_USER_VERIFICATION` | `preferred` | `required` \| `preferred` \| `discouraged` |
| `attestation` | `webauthnAttestation` | `SHOMEI_WEBAUTHN_ATTESTATION` | `none` | `none` \| `direct` |
| `ceremonyTimeout` | `webauthnCeremonyTimeoutSeconds` | `SHOMEI_WEBAUTHN_CEREMONY_TIMEOUT` | `300` | browser ceremony timeout (seconds) |
| `pendingCeremonyTTL` | `webauthnPendingCeremonyTtlSeconds` | `SHOMEI_WEBAUTHN_PENDING_TTL` | `300` | how long a begun ceremony stays valid server-side (seconds) |
| `mfaRequired` | `webauthnMfaRequired` | `SHOMEI_WEBAUTHN_MFA_REQUIRED` | `true` | require the second factor for accounts that have a passkey |

Dhall example (the keys are part of the schema in `config/shomei-types.dhall`; a full example is
`config/shomei.example.dhall`):

```dhall
{ -- … the other Shōmei settings …
, webauthnRpId = "auth.example.com"
, webauthnRpName = "Example"
, webauthnOrigins = [ "https://auth.example.com" ]
, webauthnUserVerification = "preferred"   -- required | preferred | discouraged
, webauthnAttestation = "none"             -- none | direct
, webauthnCeremonyTimeoutSeconds = 300
, webauthnPendingCeremonyTtlSeconds = 300
, webauthnMfaRequired = True
}
```

Environment-variable example:

```bash
SHOMEI_WEBAUTHN_RP_ID=auth.example.com
SHOMEI_WEBAUTHN_RP_NAME=Example
SHOMEI_WEBAUTHN_ORIGINS=https://auth.example.com,https://www.example.com
SHOMEI_WEBAUTHN_USER_VERIFICATION=preferred
SHOMEI_WEBAUTHN_ATTESTATION=none
SHOMEI_WEBAUTHN_CEREMONY_TIMEOUT=300
SHOMEI_WEBAUTHN_PENDING_TTL=300
SHOMEI_WEBAUTHN_MFA_REQUIRED=true
```

## Operator caveat: rpId and origins must match your real domain

The defaults (`rpId = "localhost"`, `origins = ["http://localhost:8080"]`) work only for local
development. In production you **must** set `rpId` to your registrable domain (e.g.
`auth.example.com`) and `origins` to the exact origin(s) your login page is served from (e.g.
`https://auth.example.com`). The browser refuses any ceremony whose page origin is not in
`origins`, and a passkey enrolled under one `rpId` cannot be used under another. Set these
**before** enrolling any passkeys; changing `rpId` later invalidates every existing passkey.

## Security properties

- **Phishing resistance.** The signature is bound to the page origin and the `rpId`, so a
  credential created for `auth.example.com` cannot be replayed against a look-alike site.
- **Consume-once challenge.** Each ceremony's challenge is stored once (PostgreSQL-backed) and
  deleted when consumed; a replayed `complete` finds nothing and fails (`404 ceremony_not_found`).
- **Clone detection.** Each credential carries a signature counter that must increase; a decrease
  signals a cloned authenticator and is rejected (`401 mfa_failed`).
- **No secrets stored.** Shōmei stores only public keys; a database leak reveals nothing that can
  impersonate a user.

See [security.md](security.md) for how these fit the wider threat model.

## Recovery: losing a passkey

The **password remains the first factor**. A user who loses their only passkey is not locked out
of recovery: the existing password-reset flow (`POST /v1/auth/password-reset/request` →
`…/confirm`) still works, because reset is gated on the password/email, not the passkey. After a
reset, the user can remove the lost passkey (`DELETE /v1/auth/passkeys/{passkeyId}`) and enroll a new
one. Backup/recovery codes are not part of this release (deferred); having **two** passkeys
enrolled is the recommended hedge.

## Browser glue and the demo

A complete, runnable enroll + step-up-login page lives in
[`examples/embedded-servant-app/www/`](../../examples/embedded-servant-app/www/). It loads
`@github/webauthn-json` from a CDN (no bundler) and drives the real ceremonies against the demo's
own mounted `/auth` routes. Because WebAuthn ties a credential to the page origin, the page is
served from the same warp process as `/auth`, so its origin matches the default
`origins = ["http://localhost:8080"]` with no extra configuration.

### Demo walkthrough (real browser + authenticator)

1. Start the demo against your dev database (it reuses the real `shomei-server` assembly, so
   every `/auth` route — including passkeys — is live). The demo serves its static assets from
   a `www/` directory resolved relative to the current directory, so launch it **from the demo
   package directory** (or point `SHOMEI_DEMO_WWW` at an absolute path):

   ```bash
   cd examples/embedded-servant-app
   PG_CONNECTION_STRING="host=$PGHOST dbname=shomei user=$(id -un)" \
     cabal run embedded-servant-app
   # …or, from the repository root:
   # SHOMEI_DEMO_WWW=examples/embedded-servant-app/www \
   #   PG_CONNECTION_STRING="…" cabal run embedded-servant-app
   ```

   The default `webauthnConfig` has `rpId="localhost"` and `origins=["http://localhost:8080"]`,
   which matches the demo's own origin, so no config change is needed for localhost.

2. Open <http://localhost:8080/index.html> in a browser that supports passkeys (Chrome, Safari,
   Firefox). If you have no hardware authenticator, enable Chrome DevTools → "WebAuthn" → "Add
   virtual authenticator" to simulate one.

3. Create an account first (the demo has no signup form; use `curl`):

   ```bash
   curl -s -X POST http://localhost:8080/v1/auth/signup -H 'content-type: application/json' \
     -d '{"email":"ada@example.com","password":"correct horse battery staple","displayName":"Ada"}'
   ```

4. On the page, log in with that email + password. Because the account has no passkey yet, you
   see "logged in (no passkey…)" and the Enroll button enables.

5. Click "Enroll passkey", approve the device prompt (or the virtual authenticator), and see
   "passkey enrolled: passkey_…".

6. Reload the page and log in again with the same email + password. This time the server returns
   `mfa_required`, the page runs the assertion automatically, your device prompts, and you see
   "MFA complete — tokens issued." That is the second factor working: the password alone did not
   issue a token until the passkey signed the challenge. Abandoning the device prompt at this
   step leaves you with no usable token.
