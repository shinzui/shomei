# MasterPlan 9 finding ledger

This ledger belongs to [MasterPlan 9](../masterplans/9-close-all-security-and-performance-review-findings.md). Original reviews remain immutable. Initial rows are **Open**: historical completion is not current verification. EP-7 M1 must inspect every clause and add any missing subrows before accepting inventory. Owners are registry numbers in the MasterPlan; each links to its full child plan below.

Closing a row requires a named test or exact documented decision, a tested commit, command/result, and residual exposure. Allowed terminal dispositions are Fixed, Existing decision verified, Owner-approved decision, or Inapplicable with proof. Open, Pending verification, and Deferred are never final closure. A parent closes only when all its subrows close. A known defect cannot be accepted by the implementing agent merely to finish the plan.

## Owners

- EP-1: [62-bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes](../plans/62-bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes.md)
- EP-2: [63-bound-authentication-inputs-and-passkey-enrollment](../plans/63-bound-authentication-inputs-and-passkey-enrollment.md)
- EP-3: [64-complete-oauth-and-jwt-wire-validation](../plans/64-complete-oauth-and-jwt-wire-validation.md)
- EP-4: [65-bound-database-work-and-make-bulk-session-revocation-atomic](../plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md)
- EP-5: [66-prove-webauthn-ceremonies-and-document-attestation-trust](../plans/66-prove-webauthn-ceremonies-and-document-attestation-trust.md)
- EP-6: [67-bound-runtime-costs-and-complete-operational-diagnostics](../plans/67-bound-runtime-costs-and-complete-operational-diagnostics.md)
- EP-7: [68-verify-every-review-finding-and-publish-closure-evidence](../plans/68-verify-every-review-finding-and-publish-closure-evidence.md)

## Original numbered findings

| Handle | Finding | Owner | State | Evidence / decision / commit |
|---|---|---|---|---|
| [REV-1.1](../reviews/project-security-and-performance-baseline.md) | Critical — a delegated or machine token is laundered into a full user session through `GET /oauth/authorize`. | EP-7 | Open | Pending verification |
| [REV-1.2](../reviews/project-security-and-performance-baseline.md) | High — an SMTP relay that rejects at the DATA stage writes the live one-time token into stderr and the audit trail. | EP-7 | Open | Pending verification |
| [REV-1.3](../reviews/project-security-and-performance-baseline.md) | High — `HashPassword`'s Argon2 derivation escapes the hashing limiter and runs while a pool connection is held. | EP-7 | Open | Pending verification |
| [REV-1.4](../reviews/project-security-and-performance-baseline.md) | High — the second factor is unthrottled and uncounted. | EP-7 | Open | Pending verification |
| [REV-1.5](../reviews/project-security-and-performance-baseline.md) | High — the downstream verification template cannot fetch its JWKS over TLS. | EP-7 | Open | Pending verification |
| [REV-1.6](../reviews/project-security-and-performance-baseline.md) | High — every per-IP control is keyed on the TCP peer, so behind a reverse proxy twenty wrong passwords from anyone block every login. | EP-7 | Open | Pending verification |
| [REV-1.7](../reviews/project-security-and-performance-baseline.md) | High — an embedding host gets none of the standalone server's runtime protections and is not told. | EP-7 | Open | Pending verification |
| [REV-1.8](../reviews/project-security-and-performance-baseline.md) | Medium — RFC 8693 token exchange and delegation verify tokens statelessly. | EP-7 | Open | Pending verification |
| [REV-1.9](../reviews/project-security-and-performance-baseline.md) | Medium — OAuth-client scopes become principal privilege. | EP-7 | Open | Pending verification |
| [REV-1.10](../reviews/project-security-and-performance-baseline.md) | Medium — three read-then-write sequences that the docs describe as atomic. | EP-7 | Open | Pending verification |
| [REV-1.11](../reviews/project-security-and-performance-baseline.md) | Medium — the "blind" reset and verification request endpoints leak existence by time. | EP-7 | Open | Pending verification |
| [REV-1.12](../reviews/project-security-and-performance-baseline.md) | Medium — the security documentation has drifted from the code in ways an integrator would act on. | EP-7 | Open | Pending verification |
| [REV-2.1](../reviews/shomei-core-security-and-performance.md) | Critical — `authorize` never inspects `claims.actor`, so any verifying token becomes a full session. | EP-7 | Open | Pending verification |
| [REV-2.2](../reviews/shomei-core-security-and-performance.md) | High — second-factor failures are counted nowhere. | EP-7 | Open | Pending verification |
| [REV-2.3](../reviews/shomei-core-security-and-performance.md) | Medium (high under `VerifyTokenAndSession`) — token exchange and delegation verify statelessly. | EP-7 | Open | Pending verification |
| [REV-2.4](../reviews/shomei-core-security-and-performance.md) | Medium — OAuth-client scopes are minted into the user's own token and the privilege gates are ordinary scopes. | EP-7 | Open | Pending verification |
| [REV-2.5](../reviews/shomei-core-security-and-performance.md) | Medium — the per-account lockout is a non-atomic read-then-act. | EP-7 | Open | Pending verification |
| [REV-2.6](../reviews/shomei-core-security-and-performance.md) | Medium — the reset and verification request workflows do unequal work on hit and miss. | EP-7 | Open | Pending verification |
| [REV-2.7](../reviews/shomei-core-security-and-performance.md) | Medium — `changePassword`'s current-password check has no throttle, lockout, or audit on failure | EP-7 | Open | Pending verification |
| [REV-2.8](../reviews/shomei-core-security-and-performance.md) | Medium — a duplicate email at signup is a `503`, not the documented `409`. | EP-7 | Open | Pending verification |
| [REV-2.9](../reviews/shomei-core-security-and-performance.md) | Medium — scopes granted by the authorization-code flow are not persisted with the session | EP-7 | Open | Pending verification |
| [REV-2.10](../reviews/shomei-core-security-and-performance.md) | Medium — refresh tokens minted for OAuth clients are client-bound only at `/oauth/token`. | EP-7 | Open | Pending verification |
| [REV-2.11](../reviews/shomei-core-security-and-performance.md) | Medium — TOTP replay protection is read-then-write. | EP-7 | Open | Pending verification |
| [REV-2.12](../reviews/shomei-core-security-and-performance.md) | Low — the locked-account branch performs zero password verifications | EP-7 | Open | Pending verification |
| [REV-2.13](../reviews/shomei-core-security-and-performance.md) | Low — outstanding reset and verification tokens are never revoked. | EP-7 | Open | Pending verification |
| [REV-2.14](../reviews/shomei-core-security-and-performance.md) | Low — login attempts against suspended or deleted accounts are invisible to the lockout, the IP throttle, and the audit trail | EP-7 | Open | Pending verification |
| [REV-2.15](../reviews/shomei-core-security-and-performance.md) | Low — `LoginFailedData` stores the submitted identifier verbatim with `user_id = NULL` | EP-7 | Open | Pending verification |
| [REV-2.16](../reviews/shomei-core-security-and-performance.md) | Low — the freshness gates measure from the access token's `iat` | EP-7 | Open | Pending verification |
| [REV-2.17](../reviews/shomei-core-security-and-performance.md) | Low — replay of a consumed authorization code is not detected as such | EP-7 | Open | Pending verification |
| [REV-2.18](../reviews/shomei-core-security-and-performance.md) | Low — `emailVerificationRequired` is not applied to the authorization-code exchange | EP-7 | Open | Pending verification |
| [REV-2.19](../reviews/shomei-core-security-and-performance.md) | Low — TOTP secret ciphertexts have empty AEAD data | EP-1 | Open | Pending verification |
| [REV-2.20](../reviews/shomei-core-security-and-performance.md) | Low — audit fidelity. | EP-4 | Open | Pending verification |
| [REV-2.21](../reviews/shomei-core-security-and-performance.md) | Low — the in-memory fake mutates the `World` non-atomically in three handlers | EP-7 | Open | Pending verification |
| [REV-2.22](../reviews/shomei-core-security-and-performance.md) | Low — configuration. | EP-7 | Open | Pending verification |
| [REV-2.23](../reviews/shomei-core-security-and-performance.md) | Info — interop and shape. | EP-3 | Open | Pending verification |
| [REV-3.1](../reviews/shomei-jwt-security-and-performance.md) | Medium — `verifyToken` pins `allowedSkew` to zero with `checkIssuedAt` on, and `iat` is serialized with sub-second precision | EP-7 | Open | Pending verification |
| [REV-3.2](../reviews/shomei-jwt-security-and-performance.md) | Medium (plausible) — ES256, the default, signs with crypton's generic ECDSA. | EP-7 | Open | Pending verification |
| [REV-3.3](../reviews/shomei-jwt-security-and-performance.md) | Low — "exactly one active key" is not enforced anywhere and activation is not atomic. | EP-7 | Open | Pending verification |
| [REV-3.4](../reviews/shomei-jwt-security-and-performance.md) | Low — issuer or audience text containing `:` that is not a parseable URI makes every mint and every verify throw. | EP-7 | Open | Pending verification |
| [REV-3.5](../reviews/shomei-jwt-security-and-performance.md) | Low — the accepted `alg` set is jose's full default and there is no `typ` header. | EP-7 | Open | Pending verification |
| [REV-3.6](../reviews/shomei-jwt-security-and-performance.md) | Low — `kid` does not select the verification key. | EP-7 | Open | Pending verification |
| [REV-3.7](../reviews/shomei-jwt-security-and-performance.md) | Low — lenient claim shapes. | EP-3 | Open | Pending verification |
| [REV-3.8](../reviews/shomei-jwt-security-and-performance.md) | Low — `keys rewrap`'s write pass is not one transaction. | EP-7 | Open | Pending verification |
| [REV-3.9](../reviews/shomei-jwt-security-and-performance.md) | Info. | EP-3 | Open | Pending verification |
| [REV-3.10](../reviews/shomei-jwt-security-and-performance.md) | Info — test coverage. | EP-7 | Open | Pending verification |
| [REV-4.1](../reviews/shomei-webauthn-security.md) | Medium — passwordless login accepts assertions without user verification under the default policy. | EP-7 | Open | Pending verification |
| [REV-4.2](../reviews/shomei-webauthn-security.md) | Low — an empty `origins` list crashes every ceremony completion. | EP-7 | Open | Pending verification |
| [REV-4.3](../reviews/shomei-webauthn-security.md) | Low — `attestation = direct` yields no trust decision. | EP-5 | Open | Pending verification |
| [REV-4.4](../reviews/shomei-webauthn-security.md) | Info — documentation. | EP-7 | Open | Pending verification |
| [REV-4.5](../reviews/shomei-webauthn-security.md) | Info — test coverage. | EP-5 | Open | Pending verification |
| [REV-5.1](../reviews/shomei-postgres-security-and-performance.md) | High — `HashPassword`'s derivation escapes the limiter and runs inside `Pool.use`. | EP-7 | Open | Pending verification |
| [REV-5.2](../reviews/shomei-postgres-security-and-performance.md) | Medium — TOTP replay protection is read-then-write. | EP-7 | Open | Pending verification |
| [REV-5.3](../reviews/shomei-postgres-security-and-performance.md) | Medium — the password-reset and password-change tails are autocommit sequences. | EP-7 | Open | Pending verification |
| [REV-5.4](../reviews/shomei-postgres-security-and-performance.md) | Medium — boot admits Argon2 parameters that make every derivation throw. | EP-7 | Open | Pending verification |
| [REV-5.5](../reviews/shomei-postgres-security-and-performance.md) | Medium — `shomei_password_credentials.user_id` has no index | EP-7 | Open | Pending verification |
| [REV-5.6](../reviews/shomei-postgres-security-and-performance.md) | Low — signing-key status updates discard their timestamp. | EP-7 | Open | Pending verification |
| [REV-5.7](../reviews/shomei-postgres-security-and-performance.md) | Low — the reuse-detection and logout tails are three separate autocommits | EP-7 | Open | Pending verification |
| [REV-5.8](../reviews/shomei-postgres-security-and-performance.md) | Low — audit payload PII. | EP-7 | Open | Pending verification |
| [REV-5.9](../reviews/shomei-postgres-security-and-performance.md) | Low — operational gaps. | EP-4 | Open | Pending verification |
| [REV-5.10](../reviews/shomei-postgres-security-and-performance.md) | Info — minor interpreter inconsistencies. | EP-4 | Open | Pending verification |
| [REV-5.11](../reviews/shomei-postgres-security-and-performance.md) | Info — documentation. | EP-7 | Open | Pending verification |
| [REV-5.12](../reviews/shomei-postgres-security-and-performance.md) | Info — test coverage. | EP-4 | Open | Pending verification |
| [REV-6.1](../reviews/shomei-migrations-schema-review.md) | Medium — no index on `shomei_password_credentials (user_id)`. | EP-7 | Open | Pending verification |
| [REV-6.2](../reviews/shomei-migrations-schema-review.md) | Medium — "exactly one active signing key" is not a database invariant. | EP-7 | Open | Pending verification |
| [REV-6.3](../reviews/shomei-migrations-schema-review.md) | Low — text statuses without `CHECK`, and case-insensitive uniqueness enforced only in the application. | EP-7 | Open | Pending verification |
| [REV-6.4](../reviews/shomei-migrations-schema-review.md) | Low — index builds and backfills take locks a populated host will feel. | EP-7 | Open | Pending verification |
| [REV-7.1](../reviews/shomei-servant-security-and-performance.md) | Critical (shared with REV-2) — `GET /oauth/authorize` authenticates with `resolveAuthUser`, which returns an `AuthUser` for any verifying token. | EP-7 | Open | Pending verification |
| [REV-7.2](../reviews/shomei-servant-security-and-performance.md) | Medium — OAuth-issued refresh tokens rotate at `POST /v1/auth/refresh` with no client authentication | EP-7 | Open | Pending verification |
| [REV-7.3](../reviews/shomei-servant-security-and-performance.md) | Medium — every per-IP control is keyed by the TCP peer. | EP-7 | Open | Pending verification |
| [REV-7.4](../reviews/shomei-servant-security-and-performance.md) | Low — `POST /oauth/revoke` revokes whatever token is presented once the caller client-authenticates | EP-7 | Open | Pending verification |
| [REV-7.5](../reviews/shomei-servant-security-and-performance.md) | Low — the "recent authentication" gate is satisfied by any refresh. | EP-7 | Open | Pending verification |
| [REV-7.6](../reviews/shomei-servant-security-and-performance.md) | Low — `GET /oauth/userinfo` returns `email`, `email_verified`, `roles`, and `scopes` regardless of granted scopes | EP-7 | Open | Pending verification |
| [REV-7.7](../reviews/shomei-servant-security-and-performance.md) | Low — invalid UTF-8 in `Authorization`, `Cookie`, `Origin`, or `Referer` escapes the RFC 9457 envelope. | EP-7 | Open | Pending verification |
| [REV-7.8](../reviews/shomei-servant-security-and-performance.md) | Low — no length caps on inbound text. | EP-2 | Open | Pending verification |
| [REV-7.9](../reviews/shomei-servant-security-and-performance.md) | Low — cookie names carry no `__Host-`/`__Secure-` prefix | EP-7 | Open | Pending verification |
| [REV-7.10](../reviews/shomei-servant-security-and-performance.md) | Low — no boot-time warning when cookie transport is on with the default `http://localhost:8080` allow-list | EP-7 | Open | Pending verification |
| [REV-7.11](../reviews/shomei-servant-security-and-performance.md) | Low — `POST /v1/auth/login/passkey/begin` is unauthenticated, unthrottled, and writes a pending-ceremony row per call | EP-7 | Open | Pending verification |
| [REV-7.12](../reviews/shomei-servant-security-and-performance.md) | Low — `refresh_token` grant responds with `"scope": ""` | EP-7 | Open | Pending verification |
| [REV-7.13](../reviews/shomei-servant-security-and-performance.md) | Info — interop and shape. | EP-3 | Open | Pending verification |
| [REV-7.14](../reviews/shomei-servant-security-and-performance.md) | Info — performance. | EP-6 | Open | Pending verification |
| [REV-7.15](../reviews/shomei-servant-security-and-performance.md) | Info — documentation. | EP-7 | Open | Pending verification |
| [REV-7.16](../reviews/shomei-servant-security-and-performance.md) | Info — test coverage gaps. | EP-3 | Open | Pending verification |
| [REV-8.1](../reviews/shomei-server-security-and-performance.md) | High — an SMTP relay that rejects at the DATA stage persists the live one-time token. | EP-7 | Open | Pending verification |
| [REV-8.2](../reviews/shomei-server-security-and-performance.md) | High — behind a reverse proxy the per-IP defences collapse into one bucket. | EP-7 | Open | Pending verification |
| [REV-8.3](../reviews/shomei-server-security-and-performance.md) | High — the embedding entry point ships none of the runtime stack. | EP-7 | Open | Pending verification |
| [REV-8.4](../reviews/shomei-server-security-and-performance.md) | Medium — synchronous SMTP and webhook delivery on the request thread. | EP-7 | Open | Pending verification |
| [REV-8.5](../reviews/shomei-server-security-and-performance.md) | Medium — chunked request bodies bypass the 1 MiB cap. | EP-7 | Open | Pending verification |
| [REV-8.6](../reviews/shomei-server-security-and-performance.md) | Medium — the `http_requests_total{method=…}` label is attacker-controlled, unescaped, and unbounded. | EP-7 | Open | Pending verification |
| [REV-8.7](../reviews/shomei-server-security-and-performance.md) | Medium — SMTP password and webhook secret live inside the `Show`/`ToJSON` `ShomeiConfig` | EP-7 | Open | Pending verification |
| [REV-8.8](../reviews/shomei-server-security-and-performance.md) | Medium — the throttled-path list is literal and partial, and `RateLimited` enforces nothing. | EP-7 | Open | Pending verification |
| [REV-8.9](../reviews/shomei-server-security-and-performance.md) | Low — `shomei-admin users create --password` takes the secret on argv | EP-7 | Open | Pending verification |
| [REV-8.10](../reviews/shomei-server-security-and-performance.md) | Low — the Dhall path silently weakens two WebAuthn policies on typos | EP-7 | Open | Pending verification |
| [REV-8.11](../reviews/shomei-server-security-and-performance.md) | Low — env secrets are not trimmed. | EP-7 | Open | Pending verification |
| [REV-8.12](../reviews/shomei-server-security-and-performance.md) | Low — webhook posture. | EP-7 | Open | Pending verification |
| [REV-8.13](../reviews/shomei-server-security-and-performance.md) | Low — wall-clock time drives the token bucket and the latency histogram | EP-7 | Open | Pending verification |
| [REV-8.14](../reviews/shomei-server-security-and-performance.md) | Low — `/health/ready` runs an untimed, unthrottled pool checkout and query per unauthenticated GET | EP-7 | Open | Pending verification |
| [REV-8.15](../reviews/shomei-server-security-and-performance.md) | Low — two error bodies escape the RFC 9457 envelope | EP-7 | Open | Pending verification |
| [REV-8.16](../reviews/shomei-server-security-and-performance.md) | Info — configuration surface. | EP-7 | Open | Pending verification |
| [REV-8.17](../reviews/shomei-server-security-and-performance.md) | Info — smaller observations. | EP-6 | Open | Pending verification |
| [REV-9.1](../reviews/shomei-client-security.md) | Low — `Token` derives `Show` | EP-7 | Open | Pending verification |
| [REV-9.2](../reviews/shomei-client-security.md) | Info — `Client.hs:52`'s comment on admin access | EP-7 | Open | Pending verification |
| [REV-10.1](../reviews/microservice-auth-stack-jwks-template.md) | High — the manager cannot speak TLS. | EP-7 | Open | Pending verification |
| [REV-10.2](../reviews/microservice-auth-stack-jwks-template.md) | Medium — `Cache-Control: max-age` is honoured unclamped, and the staleness check is reachable only from the refresh window. | EP-7 | Open | Pending verification |
| [REV-10.3](../reviews/microservice-auth-stack-jwks-template.md) | Medium — an unrecognized signing key never triggers a refresh. | EP-7 | Open | Pending verification |
| [REV-10.4](../reviews/microservice-auth-stack-jwks-template.md) | Medium — the README's en recipe cannot work against any en-server since 2026-07-08. | EP-7 | Open | Pending verification |
| [REV-10.5](../reviews/microservice-auth-stack-jwks-template.md) | Low — the runbook cannot boot as written. | EP-7 | Open | Pending verification |
| [REV-10.6](../reviews/microservice-auth-stack-jwks-template.md) | Low — impersonation guidance is prose only. | EP-6 | Open | Pending verification |
| [REV-10.7](../reviews/microservice-auth-stack-jwks-template.md) | Info. | EP-7 | Open | Pending verification |

## Explicit compound subitems

These initial subrows are not an exhaustive substitute for reading all original paragraphs. EP-7 M1 splits the remaining compound items, including documentation and configuration findings, before implementation expands.

| Handle | Subitem | Owner | State | Evidence / decision / commit |
|---|---|---|---|---|
| REV-2.20.1 | logout/reuse audit distinction | EP-4 | Open | Pending verification |
| REV-2.20.2 | concurrent admin lifecycle winner-only audit | EP-4 | Open | Pending verification |
| REV-2.20.3 | machine/delegated row-per-mint cost | EP-4 | Open | Pending verification |
| REV-2.23.1 | actor object interoperability | EP-3 | Open | Pending verification |
| REV-2.23.2 | PKCE verifier shape | EP-3 | Open | Pending verification |
| REV-2.23.3 | refresh token diagnostic redaction | EP-7 | Open | Pending verification |
| REV-2.23.4 | dead clone-warning branch | EP-5 | Open | Pending verification |
| REV-2.23.5 | passkey count ceiling | EP-2 | Open | Pending verification |
| REV-2.23.6 | library suspended-account error distinction | EP-7 | Open | Pending verification |
| REV-3.7.1 | strict list claims | EP-3 | Open | Pending verification |
| REV-3.7.2 | single audience semantics | EP-3 | Open | Pending verification |
| REV-3.7.3 | maximum exp minus iat | EP-3 | Open | Pending verification |
| REV-3.7.4 | reserved nbf and jti | EP-3 | Open | Pending verification |
| REV-3.9.1 | JWKS alg metadata | EP-3 | Open | Pending verification |
| REV-3.9.2 | jti correlation disposition | EP-3 | Open | Pending verification |
| REV-3.9.3 | public-key projection fails closed | EP-3 | Open | Pending verification |
| REV-3.10.1 | alg none | EP-7 | Open | Pending verification |
| REV-3.10.2 | HMAC with public key | EP-7 | Open | Pending verification |
| REV-3.10.3 | RSA algorithm over EC key | EP-7 | Open | Pending verification |
| REV-3.10.4 | missing and unknown kid | EP-7 | Open | Pending verification |
| REV-3.10.5 | revoked key rejection | EP-7 | Open | Pending verification |
| REV-3.10.6 | future iat | EP-7 | Open | Pending verification |
| REV-3.10.7 | nbf | EP-7 | Open | Pending verification |
| REV-3.10.8 | ill-typed roles | EP-7 | Open | Pending verification |
| REV-3.10.9 | multi-audience | EP-7 | Open | Pending verification |
| REV-3.10.10 | key rotation workflow | EP-7 | Open | Pending verification |
| REV-5.9.1 | statement timeout | EP-4 | Open | Pending verification |
| REV-5.9.2 | idle transaction timeout | EP-4 | Open | Pending verification |
| REV-5.9.3 | isolated paced sweeper | EP-4 | Open | Pending verification |
| REV-5.9.4 | whole-transaction retry budget | EP-4 | Open | Pending verification |
| REV-5.10.1 | idempotent revoked_at | EP-4 | Open | Pending verification |
| REV-5.10.2 | user updated_at clock | EP-4 | Open | Pending verification |
| REV-5.10.3 | user and credential direct clock calls | EP-4 | Open | Pending verification |
| REV-5.10.4 | password updated_at | EP-4 | Open | Pending verification |
| REV-5.10.5 | unused unbatched code expiry | EP-4 | Open | Pending verification |
| REV-5.12.1 | database refresh rotation race | EP-4 | Open | Pending verification |
| REV-5.12.2 | database reset/verification consume races | EP-4 | Open | Pending verification |
| REV-5.12.3 | database recovery-code race | EP-4 | Open | Pending verification |
| REV-5.12.4 | database ceremony consume race | EP-4 | Open | Pending verification |
| REV-5.12.5 | TOTP and passkey counter races | EP-4 | Open | Pending verification |
| REV-5.12.6 | sweeper versus live rotation | EP-4 | Open | Pending verification |
| REV-7.13.1 | case-insensitive bearer scheme and spacing | EP-3 | Open | Pending verification |
| REV-7.13.2 | form-decoded Basic credentials | EP-3 | Open | Pending verification |
| REV-7.13.3 | trusted-client consent policy | EP-3 | Open | Pending verification |
| REV-7.13.4 | token-exchange discovery | EP-3 | Open | Pending verification |
| REV-7.13.5 | refresh introspection without hint | EP-3 | Open | Pending verification |
| REV-7.13.6 | missing credential challenge | EP-3 | Open | Pending verification |
| REV-7.13.7 | capture parsing before authentication | EP-3 | Open | Pending verification |
| REV-7.16.1 | Origin null | EP-3 | Open | Pending verification |
| REV-7.16.2 | disallowed Origin and allowed Referer | EP-3 | Open | Pending verification |
| REV-7.16.3 | HEAD and OPTIONS | EP-3 | Open | Pending verification |
| REV-7.16.4 | OAuth token at bespoke refresh | EP-3 | Open | Pending verification |
| REV-7.16.5 | cross-client revoke | EP-3 | Open | Pending verification |
| REV-7.16.6 | lowercase bearer | EP-3 | Open | Pending verification |
| REV-7.16.7 | invalid UTF-8 headers | EP-3 | Open | Pending verification |
| REV-7.16.8 | chunked body cap | EP-3 | Open | Pending verification |
| REV-7.16.9 | plain PKCE refusal | EP-3 | Open | Pending verification |
| REV-7.16.10 | UserInfo scopes | EP-3 | Open | Pending verification |
| REV-7.16.11 | freshness after refresh | EP-3 | Open | Pending verification |
| REV-8.17.1 | atomic key activation | EP-6 | Open | Pending verification |
| REV-8.17.2 | atomic key rewrap | EP-6 | Open | Pending verification |
| REV-8.17.3 | multiple active keys fail closed | EP-6 | Open | Pending verification |
| REV-8.17.4 | audit CLI TypeID consistency | EP-6 | Open | Pending verification |
| REV-8.17.5 | request severity policy | EP-6 | Open | Pending verification |
| REV-8.17.6 | HIBP failure visibility | EP-6 | Open | Pending verification |
| REV-8.17.7 | sanitized admin database errors | EP-6 | Open | Pending verification |
| REV-8.17.8 | redundant boot migrations | EP-6 | Open | Pending verification |
| REV-8.17.9 | connection admission cap | EP-6 | Open | Pending verification |
| REV-8.17.10 | explicit bind host | EP-6 | Open | Pending verification |
| REV-10.7.1 | JWKS cache-control documentation | EP-6 | Open | Pending verification |
| REV-10.7.2 | safe Authorization decoding | EP-3 | Open | Pending verification |
| REV-10.7.3 | 401 Bearer challenge | EP-3 | Open | Pending verification |
| REV-10.7.4 | skew and algorithm policy | EP-3 | Open | Pending verification |

## Unnumbered costs and retained decisions

| Handle | Observation | Owner | State | Evidence / decision / commit |
|---|---|---|---|---|
| EXTRA-1 | REV-1 Performance: session enumeration and admin per-row revoke | EP-4 | Open | Pending verification |
| EXTRA-2 | REV-1 Performance: machine/delegated retained state | EP-4 | Open | Pending verification |
| EXTRA-3 | REV-1 Performance: OpenAPI repeated encoding | EP-6 | Open | Pending verification |
| EXTRA-4 | REV-1 Performance: Argon2 load bound remains true | EP-7 | Open | Pending verification |
| EXTRA-5 | REV-1 Performance: indexed credential updates and exact kid verification | EP-7 | Open | Pending verification |
| EXTRA-6 | REV-5 Index coverage: admin users/client list and per-user audit index evidence | EP-4 | Open | Pending verification |
| EXTRA-7 | REV-6: migration locks/version floor and noncritical foreign-key index disposition | EP-7 | Open | Pending verification |
| EXTRA-8 | ADR-13 follow-up: ID-token diagnostic instances | EP-7 | Open | Pending verification |
| EXTRA-9 | REV-3.2: ES256 risk and RS256 mitigation | EP-7 | Open | Pending verification |
| EXTRA-10 | REV-2.6 and REV-1.11: residual reset/verification work | EP-7 | Open | Pending verification |
| EXTRA-11 | REV-5.8: PII retention default and controls | EP-7 | Open | Pending verification |
| EXTRA-12 | REV-1 trust model: signup disclosure and trusted-client consent | EP-7 | Open | Pending verification |
