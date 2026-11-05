# Historical finding verification

Initial code candidate: `ea5d942`; provenance follow-up: `195f114` (2026-11-05). The historical checks below inspect current source and actual test assertions, independently of earlier plan completion. Every EP-7 row still open after the behavior children has an explicit group below; rows sharing an invariant share evidence. Previously accepted EP-7 diagnostics/library-policy rows retain their original evidence. Documentation clarifications in this evidence commit complete the guide checks. The provenance follow-up passed core/PostgreSQL/migration suites; the closure review records the combined candidate gate.

`cabal build all` and `cabal test all --test-show-details=failures --test-options=-j2 -j1` passed all 14 suites at this code candidate. `just build-embedded-with-en` passed its separate project. [Integration evidence](integration-evidence.md) records exact gates, loads, upgrade fixtures and limits. Unless a row says otherwise, Fixed means the specified regression passes with the inspected enforcement present; it does not imply absence of all possible vulnerabilities. No new risk exception was approved by the implementing agent.

Test paths are package-relative below: core tests are in `shomei-core/test/Shomei`, PostgreSQL in `shomei-postgres/test/Main.hs`, JWT in `shomei-jwt/test/Shomei/SigningKey`, HTTP in `shomei-servant/test/Main.hs`, and server tests in `shomei-server/test` plus `test-health/Main.hs`. Each group names the production module, exact test name or scenario/assertion and retained exposure.

## authorize-provenance

Rows: REV-1.1, REV-2.1, REV-7.1. Disposition: **Fixed**.

`shomei-core/src/Shomei/OAuth/Authorize/Workflow.hs` refuses actor-bearing claims before lookup and requires a live interactive session. Core `interactive session is accepted`, the three delegated/machine refusals, `an act claim is refused before an unknown session is read`, and revoked/expired/unknown session tests assert no code is created. HTTP `GET /oauth/authorize accepts only a live interactive session` and `an impersonation token cannot be laundered into a user session through authorize + code exchange` exercise the wire boundary. Migration 0043 additionally repairs the earlier interactive default using actor/service-account associations and persisted refresh-token evidence; a populated pre-0043 fixture verifies this upgrade and omitted-kind writes default conservatively. Core `a stored actor is refused even when the token omits act`, migration `provenance upgrade repairs legacy machine and actor rows and defaults unknown writers safely`, and PostgreSQL `NULL session provenance is rejected by the schema and fails closed after constraint bypass` pass at 195f114. The migration preserves only the human fixture with a persisted refresh record as interactive; all other per-row kinds and the omitted-write default are asserted.

## smtp-redaction

Rows: REV-1.2, REV-8.1. Disposition: **Fixed**.

`shomei-server/src/Shomei/Server/Notify.hs` classifies SMTP exceptions into bounded reasons. Server `SMTP: a 451 at DATA audits a reason code, never the message` uses a real rejecting SMTP fixture and inspects stderr and the audit payload for the link/token; connection-refusal and classifier cases also pass. Explicit development raw-token logging remains opt-in and documented.

## hash-bound

Rows: REV-1.3, REV-5.1, EXTRA-4. Disposition: **Fixed**.

`shomei-postgres/src/Shomei/Account/Password/Hash/Postgres.hs` forces each derivation within `withHashingPermit`; hashing precedes persistence and no Database operation encloses it. PostgreSQL `hashing limiter: the interpreter forces HashPassword inside its permit`, `hashing limiter: the dummy verification path is bounded too`, the saturating concurrency test, PHC/parameter tests and boot hard-floor test pass. Server config `argon2Settings` rejects invalid costs and zero permits. The isolated default-cost workload and three aggregate reports in [load evidence](integration-evidence.md) check continued bounded operation; latency is a local measurement, not an SLO or equal-cost guarantee for differently parameterized historical hashes.

## mfa-abuse

Rows: REV-1.4, REV-2.2. Disposition: **Fixed**.

Core `five bad passkey assertions lock the account`, `second-factor success clears an expired standing lockout`, and `wrong TOTP removal codes count and a locked account cannot remove the factor` inspect the shared account budget. HTTP `EP-4: a TOTP guessing loop is locked out after maxFailedLoginsPerAccount wrong codes` exercises the real handler. `Shomei.Mfa.Workflow` and `Shomei.Mfa.Totp.Workflow` route failures through the shared proof accounting; password proof does not clear the account budget before the second factor. Credential proof endpoints are included in the derived HTTP throttle set.

## downstream-tls

Rows: REV-1.5, REV-10.1. Disposition: **Fixed**.

`examples/microservice-auth-stack/src/Downstream/Service.hs` selects a TLS manager for HTTPS, with certificate verification supplied by http-client-tls. `an https JWKS URL selects a TLS-capable manager` verifies the transport reaches TLS rather than TlsNotSupported. Public `docs/user/client-and-examples.md` explicitly identifies plaintext JWKS as a token-forgery vector; non-loopback HTTP emits a warning. This test establishes manager capability, not certification of a deployed TLS/proxy configuration (ADR-18).

## proxy-identity

Rows: REV-1.6, REV-7.3, REV-8.2. Disposition: **Fixed**.

`Shomei.Server.Middleware.TrustedProxy` rewrites `remoteHost` only behind configured trusted peers, walking X-Forwarded-For from the right. Tests `an untrusted peer's X-Forwarded-For is ignored`, `a trusted peer yields the rightmost untrusted hop`, `a spoofed hop behind a trusted proxy is not the client`, every-hop-trusted fallback, invalid CIDR rejection, and IPv4/IPv6 rendering pass. Shared host middleware installs it before rate/proof accounting. `deployment.md` specifies trusted networks and PROXY protocol topology; configuring a trusted range remains the operator's responsibility.

## embedded-runtime

Rows: REV-1.7, REV-8.3. Disposition: **Fixed**.

Standalone and both embedded mains build shared `Env`, health checks, background supervision, host middleware and `hostWarpSettings`. Embedded `/projects is 401 without a token and 200 with one` and `a revoked signing key stops verifying after SIGHUP once background tasks are installed` pass. Server host-order, admission, body-cap and exception tests cover the shared implementation; `just build-embedded-with-en` passes its independent solver. The whole host application must be wrapped; root mount and refresh-cookie prefix constraints are documented in `client-and-examples.md` (ADR-17).

## live-mint-principals

Rows: REV-1.8, REV-2.3. Disposition: **Fixed**.

`Shomei.Delegation.Workflow` and `Shomei.OAuth.TokenExchange.Workflow` require live source sessions and active operators/subjects before minting authority, regardless of the ordinary request session-check mode. Core `caller with a revoked session is forbidden`, `suspended caller is forbidden`, revoked/suspended operator and revoked/inactive subject token-exchange cases pass. HTTP `POST /oauth/token: privilege-minting exchanges require live, active principals in the default auth mode` confirms the stronger mint boundary. Stateless ordinary request verification remains the explicit default.

## privilege-scopes

Rows: REV-1.9, REV-2.4. Disposition: **Fixed**.

Core OAuth-client `all built-in privilege scopes are refused`, configured-impersonation refusal, and ordinary-capability acceptance pass. `Shomei.OAuth.Client.Workflow` rejects the three reserved privilege gates and authorize filters legacy/manual rows. HTTP `scenarioOAuthScopeIsolation` checks forged stored allow-lists cannot amplify privilege. Admin tests show OAuth-client registration refuses privilege scopes while service-account registration deliberately accepts them as the machine principal's own authority. `security.md` explains that distinction.

## atomic-security

Rows: REV-1.10, REV-1.10.1, REV-1.10.2, REV-1.10.3, REV-2.5, REV-2.11, REV-5.2, REV-5.3, REV-5.7. Disposition: **Fixed**.

ADR-7 and [database evidence](database-evidence.md) describe the persistence boundary. PostgreSQL `lockout: eight racing failures count 1..8 and lock once`, `totp counter: eight racing updates have one winner`, `passkey counter: eight racing nonzero updates have one winner`, `real reset and verification workflows each consume once and audit one winner`, and session-scoped revoke winner tests inspect persisted outcomes. The unit-of-work code encloses password/reset consumption, sibling revocation, credential update, session/refresh revocation and audit in one transaction; hash work is outside. Core 100-racer wrong-password/refresh/reset/TOTP tests also pass. Injected audit failure/transaction rollback and live refresh-versus-sweep evidence are mapped separately in the database evidence. Counterless authenticators intentionally accept (0,0).

## reset-cost-policy

Rows: REV-1.11, REV-2.6, EXTRA-10. Disposition: **Existing decision verified**.

Existing `docs/user/security.md` section “No account-existence leakage” explicitly accepts the small remaining database-cost difference. Core `email-verification hit costs lookup + token + enqueue + audit`, its one-lookup miss test, and both analogous password-reset tests pin that distinction. Server `E2E: password-reset/request answers 202 in under a second while the receiver sleeps 3 s` and queue overflow/shutdown test prove delivery is off the request thread. A caller can still statistically distinguish token generation/insert/queue/audit on a hit from lookup-only on a miss; this is retained documented policy, not a claim of constant time.

## documentation-baseline

Rows: REV-1.12, REV-1.12.1, REV-1.12.2, REV-1.12.3, REV-1.12.4, REV-1.12.5, REV-5.11, REV-5.11.1, REV-5.11.2, REV-5.11.3, REV-5.11.4. Disposition: **Fixed**.

`security.md` points to `Shomei/Account/Password/Hash/Postgres.hs`, documents parameter-bearing PHC strings and SHA-256 of normalized login IDs. PHC format/old-parameter/malformed/three-part rejection tests pass; `Shomei.Session.LoginAttempt.Domain` hashes normalized identifiers and the audit codec no longer reproduces legacy raw identifiers. Quick starts use `/v1/auth/*`; HTTP `the /v1 boundary: application routes are versioned, probes and JWKS are not` proves old `/auth` routes are absent. Current en API-key documentation is checked in the en-recipe group below. MasterPlan 6 now carries a prominent historical notice and current compatibility/query-budget corrections without rewriting its original outcomes. `deployment.md` sweep JSON and tab examples include all ten report counters; `Shomei.Persistence.Maintenance.Postgres`/CLI/supervisor render those same fields. It explains lockout rows exist only once locked and running failures live in login_attempts. PostgreSQL sweep tests exercise lockout deletion and every report field. Query-budget tests count logical interpreter operations (10/4/5/2/3), not physical wire round trips; the bounded transaction layer executes additional SQL.

## password-change-abuse

Rows: REV-2.7. Disposition: **Fixed**.

`Shomei.Account.Lifecycle.Workflow.changePassword` validates proof size before hashing and uses the shared failure-budget reservation and LoginFailed audit path for current-password failures. Core `five wrong current passwords lock and audit the account` and `change password with wrong current password is rejected` assert lock/audits and unchanged credentials. The HTTP route carries RateLimited and is covered by the exact derived-throttle-set test. Successful changes still require the credential proof and applicable freshness/delegation gates.

## identity-conflict

Rows: REV-2.8. Disposition: **Fixed**.

Signup prechecks email and login ID; `Shomei.Persistence.Database.Postgres` maps only known identity unique constraints with SQLSTATE 23505 to typed conflicts. HTTP `signup reports duplicate email and login-id conflicts as 409` passes. Direct-SQL identity collision and unique-credential tests confirm the final database boundary; no raw driver diagnostic is serialized. The common precheck alone is not relied on to resolve races.

## refresh-binding-and-scopes

Rows: REV-2.9, REV-2.10, REV-7.2, REV-7.12. Disposition: **Fixed**.

Session grants and original authentication time are persisted, and refresh reconstructs claims from them. Core `bespoke refresh refuses a client-bound session without spending its token` and HTTP `POST /oauth/token: refresh_token is bound to the client that minted the session` test both directions and wrong-client attempts. `scenarioOAuthCodeExchange` refreshes the original grant and compares its scopes, including the OAuth response `scope`; subsequent `/userinfo` still sees its authorized scopes. No failed bespoke attempt consumes the client-bound refresh proof.

## login-failure-accounting

Rows: REV-2.12, REV-2.14. Disposition: **Fixed**.

TimingSpec `locked account still verifies a password` and `suspended account still verifies a password` assert exactly one dummy/real proof call. LockoutSpec `attempts against a suspended account count and publish LoginFailed` checks all three failure events and one lock. The same non-active branch covers soft-deleted users; `Servant.Error` maps library UserNotActive to the generic login problem. Per-IP counting uses all recorded failures. The deliberate direct-library error distinction is separately retained at REV-2.23.6.

## sibling-token-revocation

Rows: REV-2.13. Disposition: **Fixed**.

Core `confirming email revokes the user's other verification links`, `confirming a reset revokes the user's other reset links`, and password change/reset cases inspect the resulting World. PostgreSQL reset/verification unit-of-work tests exercise actual sibling revocations and session/refresh shutdown. `Shomei.Session.UnitOfWork.Postgres` puts sibling consumption/revocation and credential/audit writes in the same transaction. Unconsumed sibling links cannot remain valid after a successful confirmation/change.

## identifier-diagnostics

Rows: REV-2.15. Disposition: **Fixed**.

`Shomei.Audit.Event.Domain` LoginFailedData carries an opaque account key and optional resolved user, not submitted identifier text. Core `wrong-password audit identifies the hashed account and resolved user` and codec `a legacy login_failed payload decodes without reproducing the raw identifier` pass. AccountKey is SHA-256 of normalized login ID; a low-entropy login ID can still be dictionary-correlated, as documented. Other audit PII remains governed by the retention policy below.

## fresh-authentication

Rows: REV-2.16, REV-7.5. Disposition: **Fixed**.

`AuthClaims.authTime` originates in the session's `authenticatedAt` and survives refresh; the enrichment hook cannot override it. Delegation and MFA freshness checks read authTime, not issuedAt. HTTP `scenarioTotp` advances the fake clock, refreshes to obtain a new iat, and asserts recovery-code generation remains `403 fresh_authentication_required`. JWT legacy-no-auth_time fallback test passes under the finite lifetime policy. A legacy token can only fall back to its original iat, not gain freshness through a new refresh.

## authorization-code-replay

Rows: REV-2.17. Disposition: **Fixed**.

`Shomei.OAuth.TokenGrant.Workflow.exchangeAuthorizationCode` looks up consumed codes, revokes the session bound to the first successful exchange and audits replay while retaining generic invalid_grant on the wire. HTTP `POST /oauth/token: authorization_code + PKCE + ID token; replay, wrong verifier, and a stolen code are one invalid_grant` checks the resulting session revocation and audit. PostgreSQL two-consumer CAS test proves one consumption winner. The existing consume-before-PKCE burn-on-failure contract is documented.

## verified-email

Rows: REV-2.18. Disposition: **Fixed**.

Core TokenGrant tests cover enabled+unverified refusal, disabled acceptance, verified acceptance and login-ID-only exemption. `ensureEmailVerified` runs before code-session issuance. HTTP configured verification tests and real verification workflow pass. Signup's initial token behavior and the no-email exemption remain explicit product contracts in `security.md`.

## atomic-fake

Rows: REV-2.21. Disposition: **Fixed**.

`shomei-core/src/Shomei/Test/InMemory.hs` uses atomicModifyIORef' in modifyWorld, casWorld, token/ceremony generation, consumes and multi-table units of work. No writeIORef/modifyIORef' read-then-write store mutation remains. Core ConcurrencySpec runs 100-racer refresh/reset/wrong-password/TOTP workflows; Admin 100-suspend and eight bulk-revoker tests also pass. Fake semantics are specifications; independent PostgreSQL races provide actual persistence proof.

## configuration-diagnostics

Rows: REV-2.22, REV-2.22.1, REV-2.22.2, REV-2.22.3, REV-8.7. Disposition: **Fixed**.

`NotifierSecrets` is separate from serializable ShomeiConfig; ConfigSpec `notifierSecretsAreStrippedAndConfigIsSecretFree` checks no SMTP password/webhook secret fields appear in encoded config. Algorithm parsing returns a named error rather than falling back; JWT `configSigningAlgorithm parses RS256 and rejects unknown text` passes and Config.hs normalizes both file/env values strictly. reservedClaimKeys includes nbf/jti; JWT `drops nbf and jti from the extension claim bag` and `a direct extension bag cannot inject actor or jti` pass. ADR-13 governs credential diagnostics; deliberate public config URLs are not secret storage.

## jwt-time-and-shape

Rows: REV-3.1, REV-3.4, REV-3.5, REV-3.6, REV-3.10, REV-3.10.1, REV-3.10.2, REV-3.10.3, REV-3.10.4, REV-3.10.5, REV-3.10.6, REV-3.10.7, REV-3.10.8, REV-3.10.9, REV-3.10.10. Disposition: **Fixed**.

In `shomei-jwt/test/Shomei/SigningKey/Verify/JwtSpec.hs`: `accepts an iat within the configured 30-second skew`, beyond-skew refusal, integral iat/exp, signed-future-nbf/skew, malformed roles, multi-audience, unknown/missing kid, typ JWT refusal, typ absence compatibility, typ at+jwt minting, alg none, HS256-with-public-bytes and RS256-under-EC-kid all pass. `Rotation/JwtSpec.hs` actually signs and verifies before revocation, removes the key, then asserts TokenKeyNotFound; its rotation workflow checks exactly one active key, old retirement timestamp and both overlap alg values. ConfigSpec `verifierSettings` checks valid scheme URIs and early issuer/audience parse failures; Verify.Jwt uses total StringOrURI parsing for direct callers. Algorithms are pinned to ES256/RS256 and lookup returns only the uniquely matching kid (ADR-3). Missing typ remains the documented compatibility policy; maximum lifetime and actors are covered by EP-3 evidence. The nbf regression was added at ea5d942; prior extension-bag tests were not substituted for signature-valid temporal rejection.

## es256-existing-risk

Rows: REV-3.2, EXTRA-9. Disposition: **Existing decision verified**.

Existing `security.md` Tokens section documents crypton's generic ECC timing exposure, retains ES256 as default and recommends RS256 with blinded RSA for deployments exposed to many co-located signing requests. JWT `an RS256 token verifies via the RSA public JWKS` and protected RS256 sign/verify round trip pass; the rotation runbook explains generating/activating an RS256 key while retaining old verification overlap. No constant-time ES256 or exploitability proof is claimed. Mint load remains attacker-influenced and the plausible side channel is retained, not newly waived.

## key-lifecycle

Rows: REV-3.3, REV-3.8, REV-5.6, REV-6.2. Disposition: **Fixed**.

Migration 0034's partial unique index, ReplaceActiveSigningKey and CLI activation/rewrap transaction boundaries enforce one active key. PostgreSQL `one-active index rejects a second insert and atomic replacement retires the old key` and `signing-key transitions stamp activated, retired, and revoked times` pass. Admin `key activation and rewrap roll back every write on an injected later failure` and `key material loader rejects multiple active keys even after index bypass` pass; current loader fails closed rather than choosing newest. ADR-4 and [operational evidence](operational-evidence.md) cover finite retries, pending-row revalidation and no mixed-KEK partial writes.

## webauthn-policy

Rows: REV-4.1, REV-4.2, REV-4.4, REV-4.4.1, REV-4.4.2. Disposition: **Fixed**.

EP-5 signed software-authenticator tests at 522abcc exercise actual cryptographic verification. Passwordless ceremonies force UV required even when global policy is preferred/discouraged; step-up retains its configured policy. Empty origins yield a typed failure and boot rejects them. `docs/user/passkeys.md` and `security.md` state server-side origin/rpId enforcement and the (0,0) counterless exception; nonzero rollback/clone counters fail closed. Direct conveyance is explicitly not device trust enforcement (ADR-25); signed fixtures are public test keys and do not certify physical authenticator models.

## credential-index

Rows: REV-5.5, REV-6.1, REV-6.1.1. Disposition: **Fixed**.

Migration 0036 creates the unique user_id index for password credentials. PostgreSQL `one password credential per user is a database invariant` rejects a second credential and checks the index; hash-update predicates use user_id. Update work can no longer require a whole-table scan due to a missing index. The migration preflight query and populated-table SHARE-lock warning are in deployment.md. The noncritical FK subrow is assessed separately.

## argon2-boot

Rows: REV-5.4. Disposition: **Fixed**.

ConfigSpec `argon2Settings` checks the memory≥8×lanes relation, representability/positive values and nonzero permits. Boot runs trialArgon2Derivation before serving. PostgreSQL `argon2: the boot hard floor matches the implementation` verifies boundary costs with the actual library; format/parameter tests prove changing new-write parameters does not invalidate old PHC hashes. The warning floor remains separate from hard implementation limits.

## audit-retention-policy

Rows: REV-5.8, EXTRA-11. Disposition: **Existing decision verified**.

Existing `security.md` audit section and deployment.md “Audit-event retention is off by default” state events contain PII and are kept forever unless SHOMEI_AUTH_EVENT_RETENTION_DAYS is configured. PostgreSQL `maintenance sweep: audit events go only when a retention window is configured` and Admin `sweep deletes dead rows; audit events need an explicit window` prove default preservation and explicit deletion. Removing raw login identifiers reduces accidental secret capture; emails, client IPs and identity/audit metadata still require deployment access controls and a retention policy. Indefinite default retention is retained documented policy.

## noncritical-fk-indexes

Rows: REV-6.1.2. Disposition: **Inapplicable with proof**.

The original observation names pending-ceremony user_id, role-grant granted_by and authorization-code user_id only for parent hard deletes. User lifecycle SQL changes status; it does not DELETE users, and the sweeper deletes child records rather than parents. Current hot lookups use ceremony/code keys or other existing indexes. The deployment guide and ADR-7 state a future hard-delete feature must measure/add its own indexes. These are not missing indexes for a currently executed parent-delete path; no claim is made about hypothetical hard-delete latency.

## schema-contract

Rows: REV-6.3, REV-6.3.1, REV-6.3.2. Disposition: **Fixed**.

Migration 0035 installs eleven CHECK vocabularies matching domain codecs for user/session/refresh/key/one-time-token/client status, ceremony kind, client type and login outcome, plus four lower(...) identity unique indexes. PostgreSQL `schema rejects invalid user status and case-variant identities` bypasses domain constructors and asserts 23514/23505; field-budget and normal store tests use the migrated schema. Haskell and database Unicode/collation normalization may disagree; the existing plan-55 policy is distilled into ADR-7 and deployment.md: preflight/import normalization is required, and a database collision maps to typed 409. This is not a universal Unicode case-fold equivalence guarantee.

## migration-operations

Rows: REV-6.4, REV-6.4.1, REV-6.4.2, EXTRA-7. Disposition: **Existing decision verified**.

Existing deployment.md now names PostgreSQL 17/18, maintenance windows, the credential uniqueness preflight and backfill/index lock costs, including 0016/0018/0020 and 0040–0042. The dependency compatibility contract is `mori://shinzui/pg-migrate/docs/compatibility`; its discovered Runner.Connection validates major 17 or 18 before ledger changes. `just migration-check` passes manifest and namespace policy; migration `composition preserves a host component's namespace state` and all ephemeral PostgreSQL suites pass on 17. Ordinary transactional backfills/index builds still take table locks, so operators must schedule upgrades; online DDL and testing on PostgreSQL 18 in this run are not claimed. Noncritical indexes are assessed above.

## revoke-ownership

Rows: REV-7.4. Disposition: **Fixed**.

`Shomei.OAuth.Revocation.Domain` checks OAuth client binding, service-account subject/actor ownership, or explicit shomei:admin authority. Six core ownership tests and HTTP `POST /oauth/revoke: callers can revoke only sessions they own, except shomei:admin` pass, inspecting introspection after allowed and denied attempts. Unknown/unauthorized tokens retain the RFC blind revocation response without performing the mutation.

## userinfo-scopes

Rows: REV-7.6. Disposition: **Fixed**.

HTTP `GET /oauth/userinfo: email and roles appear only under the email and profile scopes` exercises real handlers. Email/email_verified require email; roles/scopes require profile; sub remains the stable identity. Refresh preserves the original grant. Introspection's authorized machine-oriented claim output is a separate contract.

## hostile-header-bytes

Rows: REV-7.7. Disposition: **Fixed**.

HTTP `hostile auth header bytes answer in the problem envelope` sends invalid UTF-8 in Authorization, Cookie, Origin and Referer. Auth extraction uses total decoding/strict bearer parsing, and malformed authorization cannot fall back to cookies. The shared Warp exception response also renders unexpected synchronous failures as sanitized problem documents. No raw exception reaches the body.

## cookie-boundary

Rows: REV-7.9, REV-7.10, REV-7.10.1, REV-7.10.2. Disposition: **Fixed**.

Secure cookies use __Host-shomei_session (Path=/, no Domain) and __Secure-shomei_refresh (refresh-only path). HTTP cookie transport, refresh/CSRF and `cookieSecure=false keeps the bare names` assert attributes, rotation/clearing and opt-out behavior. ConfigSpec `rateLimitAndCookieEdgeSettings` asserts the development-origin boot warning, normalizes uppercase host/trailing slash, rejects paths and accepts configured production origin. Configured origins are normalized once; incoming Origin/Referer must still represent that allow-listed origin. The explicitly insecure development mode has no browser prefix protection.

## derived-throttling

Rows: REV-7.11, REV-8.8. Disposition: **Fixed**.

`RateLimited` metadata derives shomeiThrottledRoutes; host middleware enforces the resulting set. Server `the derived throttled set matches every credential proof` covers public passkey begin/completion, MFA, lifecycle and OAuth routes; `hostMiddleware refuses oversized bodies outside the limiter and throttles inside it` exercises enforcement. Passkey begin still creates a pending row, but per-IP request rate and sweeper expiry bound the supplied hosts. Direct library or bespoke embedding callers must install the documented whole-host runtime boundary.

## admin-and-route-docs

Rows: REV-7.15, REV-7.15.1, REV-7.15.2, REV-7.15.3, REV-7.15.4, REV-7.15.5, REV-9.2. Disposition: **Fixed**.

`api.md` audit docs name RequireAdmin = admin role OR shomei:admin scope, and admin bootstrap uses the role store or service-account client_credentials at /oauth/token. There is no advertised service-token HTTP route. The refresh-cookie fixed /v1/auth/refresh Path and root-mount caveat appear in api.md and client-and-examples.md. The delegation-blocked inventory includes password changes, both registration operations, passkey deletion, TOTP enrollment/removal and recovery generation; TOTP verify is documented as having no delegation denial. `Shomei.Servant.Api`, Authz and route handlers agree. HTTP admin gate, mutation-refusal, cookie, route-version and TOTP scenarios pass. `shomei-client/src/Shomei/Client.hs` describes RequireAdmin's actual role-or-scope semantics.

## queued-delivery

Rows: REV-8.4. Disposition: **Fixed**.

`Shomei.Notify.Queue` uses bounded STM enqueue and a background worker. Server `queue: overflow and shutdown audit without blocking; drain reports remainder` and slow-receiver reset E2E pass. Shared withBackgroundTasks installs the worker in standalone and both embedded examples. Queue saturation can drop delivery with a bounded audit reason; it does not block the credential request, and this behavior is documented.

## body-cap

Rows: REV-8.5, REV-8.15, REV-8.15.1, REV-8.15.2. Disposition: **Fixed**.

Middleware tests cover known-length 2 MiB refusal, a streamed chunked body crossing the cap, small pass-through, `an escaped exception renders a problem document`, invalid Warp requests and async cancellation rethrow. The 413 and escaped synchronous 500 bodies have application/problem+json with sanitized RFC 9457 fields. Body buffering remains bounded at the configured cap; independent field limits handle smaller malicious payloads.

## metrics-clock

Rows: REV-8.6, REV-8.13. Disposition: **Fixed**.

`Shomei.Server.Observability.Metrics` maps methods to a finite vocabulary plus other and escapes label values; `a hostile method is labelled other and escaped`, normal accounting and throwing-handler gauge cleanup tests pass. RateLimit and Metrics use GHC monotonic nanoseconds for elapsed refill/duration; request wall-clock timestamps remain presentation data. Bucket eviction and 10k-one-shot-IP bound tests pass. Source inspection confirms no wall-clock duration/refill subtraction remains.

## admin-password-input

Rows: REV-8.9, REV-8.9.1, REV-8.9.2, REV-8.9.3, REV-8.9.4. Disposition: **Fixed**.

`shomei-server/app/Admin.hs` has no --password option: it reads stdin with terminal echo restored in finally, or --password-file, removes exactly one line ending and refuses empty input before database access. Actual CLI --help/obsolete-option/empty-input checks are recorded in integration evidence. `Shomei.Admin.Users` passes env.config to signup, configured Argon2 and the TLS HIBP interpreter with deployment timeout; core breach enabled/disabled/fail-open/fail-closed tests cover that workflow. Admin `users create applies config.passwordPolicy` refuses a short candidate without writing; `users create --email-verified stamps email_verified_at` verifies bootstrap. The breach service is not contacted in a live external acceptance call; injected core/adapter tests and the inspected CLI wiring establish that contract.

## strict-file-config

Rows: REV-8.10, REV-8.10.1, REV-8.10.2, REV-8.16, REV-8.16.1, REV-8.16.2, REV-8.16.3. Disposition: **Fixed**.

ConfigSpec's serial `Dhall file is loaded and env vars override it` invokes strictConfigurationSettings, dhallSchemaMatchesFileConfig, rateLimitAndCookieEdgeSettings and all per-policy assertions. It rejects unknown Dhall keys, invalid attestation/empty origins, validates schema completion and exact FileConfig key parity, then checks file/environment precedence and tunable account/IP/rate/window/lock duration values. Config.hs strictly parses both user-verification and attestation from either source. config/shomei-types.dhall and example plus deployment.md cover optional completion, rate/lockout, notifier, TOTP, OIDC, OAuth, roles and new capacity settings (ADR-8). The complete example is type-checked in integration evidence; semantic cross-field rules remain boot validation.

## trimmed-secrets

Rows: REV-8.11, REV-8.11.1, REV-8.11.2. Disposition: **Fixed**.

ConfigSpec `notifierSecretsAreStrippedAndConfigIsSecretFree` supplies surrounding spaces/newlines and asserts stripped SMTP/webhook values and database connection string. Secrets are loaded separately from ShomeiConfig; the runtime adapter receives the stripped bytes. Password inputs intentionally use their own exact-byte policy rather than generic secret trimming.

## webhook-posture

Rows: REV-8.12, REV-8.12.1, REV-8.12.2, REV-8.12.3, REV-8.12.4. Disposition: **Fixed**.

ConfigSpec notifierInsecureTransportFlags rejects HTTP/default plaintext-auth posture and checks fixed secret-free warnings for explicit HTTP and plaintext SMTP-credential lab overrides, including a non-loopback HTTP URL. Notify tests `webhook: signed JSON POST the receiver can verify` and retry test compare timestamp.bound HMAC signatures and fresh retry timestamps. notifications.md requires receiver validation of timestamp ±300 seconds and constant-time HMAC; replay within that window still needs receiver deduplication by event/token. It documents inherited http_proxy/https_proxy/no_proxy behavior from the discovered http-client source. Bypassing transport protections remains an explicit lab setting, not a production recommendation.

## bounded-readiness

Rows: REV-8.14. Disposition: **Fixed**.

`Shomei.Health.Server` caches positive and negative readiness verdicts under one MVar with monotonic expiry and wraps dependency work in a two-second timeout. Health `readiness is evaluated at most once per window`, `readiness times out as a postgres failure`, missing-key/unavailable classifications and failure-onset reset tests pass. Shared assemblies build checks once at boot; connection/statement/transaction budgets also apply. Readiness can lag recovery or failure by its one-second cache window.

## client-token-diagnostics

Rows: REV-9.1. Disposition: **Fixed**.

`client bearer diagnostics redact the credential` passes at 1e3bbae and in the full candidate suite. Client Token has an explicit redacted Show instance; only its explicit auth-header operation extracts the raw value. ADR-13 defines this diagnostic boundary.

## jwks-cache

Rows: REV-10.2, REV-10.3. Disposition: **Fixed**.

ADR-18 and Downstream.Service cap effective publisher freshness by maxStaleness, check hard expiry before refresh-ahead, ignore zero max-age and single-flight background/cold refresh. Tests `max-age is clamped and max-age=0 does not loop`, hard-stale 503, cold-start 10-caller/one-fetch, failure-burst and stale-on-error pass. `an unknown key triggers one capped refresh and retry` rotates real signing keys and checks fetch counts; malformed/bad-signature tokens do not spend refresh budget. The five-second minimum age/30-second interval mean a fresh rotation may still have a short documented availability gap, rather than request-volume-driven network work.

## en-recipe

Rows: REV-10.4. Disposition: **Fixed**.

The microservice README builds a TLS ClientEnv with a read-only en service Bearer key and explicitly says the user's Shomei JWT is not en's service credential. `authorization.md` describes EN_API_KEYS_READ_ONLY/READ_WRITE and stable TypeID subject mapping. Mori-discovered `mori://shinzui/en` source confirms En.Client/En.Check.Api/En.Servant.Wire types and server Bearer-key middleware; the recipe now imports RelationName used by its SubjectSet arm. `just build-embedded-with-en` independently compiles the real in-process en-core integration. The reader-applied standalone en-client snippet is not claimed as an end-to-end run against a deployed en-server.

## runnable-example-config

Rows: REV-10.5. Disposition: **Fixed**.

process-compose.yaml uses the dev socket connection string rather than forcing TCP localhost; the standalone and microservice runbooks set the required signing KEK and TOTP key. The server boot/config and embedded full builds pass. Isolated load provisions the same migrated interpreter stack without deployment credentials. Example commands requiring a real deployment are not executed against external systems.

## downstream-small-clauses

Rows: REV-10.7. Disposition: **Fixed**.

`client-and-examples.md` and microservice README now document actual public,max-age=300 JWKS caching, which HTTP scenarioVersionBoundary asserts. Downstream auth uses total Authorization decoding and supplies WWW-Authenticate: Bearer; microservice test sends hostile bytes and checks 401 challenge. JWT shared tests prove configured skew and pinned algorithms; the downstream uses the same finite verifier policy. Existing missing-typ/legacy actor compatibility and bounded cache outage exposure remain documented; [operational evidence](operational-evidence.md) separately covers durable actor/subject auditing.

## credential-and-kid-cost

Rows: EXTRA-5. Disposition: **Fixed**.

The unique password-credential user_id index and exact kid filtering are verified in the credential-index and jwt-time-and-shape groups. Unknown/missing kid tests refuse without trialing other published keys. Ordered session/admin/audit query-plan evidence is separately recorded by EP-4; no claim of a fixed physical-wire query count follows from logical interpreter counters.

## signup-and-consent-policy

Rows: EXTRA-12. Disposition: **Existing decision verified**.

Existing security.md “Signup deliberately discloses existence” explicitly retains 409 email_taken/login_id_taken; HTTP conflict tests pass. oidc.md “Trust model” states active registered clients are trusted with every user's identity and authorization is immediate without a consent UI. Exact redirect matching, active-client checks, allow-list scope restrictions and live-interactive-session tests verify mitigations. Operators must register only controlled applications and revoke untrusted clients. Account enumeration via signup and lack of per-user consent remain deliberate product boundaries, not newly approved defects.
