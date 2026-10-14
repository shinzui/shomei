---
id: 8
slug: account-lifecycle-email-verification-and-password-reset
title: "Account lifecycle: email verification and password reset"
kind: exec-plan
created_at: 2026-06-04T02:42:05Z
intention: "intention_01kt8847mre3wa36x0s0k9j6pm"
master_plan: "docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md"
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T14:43:18Z
      mode: "update"
      note: "Validated current lifecycle APIs and tests; corrected HTTP, persistence, notifier, migration, and revocation contracts."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T14:44:08Z
      verdict: "comments"
      note: "Reconciled current APIs and verified eight passing suites; documented remaining verification atomicity and expiry limits."
---

# Account lifecycle: email verification and password reset


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current. It is EP-1 of
[MasterPlan 2](docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md).
The original four milestones were completed in June 2026. This 2026-10-14 revision reconciles
the plan with the current implementation at commit `0eedad1`; it is a maintenance and
validation contract, not an instruction to recreate already shipped modules or migrations.
Historical completion does not assert that every later security concern is resolved.

## Purpose / Big Picture


Shōmei provides email verification, forgotten-password reset, and authenticated password
change. A developer can register an account with an email, request a one-time verification
token, confirm it, request a password reset, and confirm the reset with a new password.
Verification sets `emailVerifiedAt`; reset changes the password and revokes every existing
session and refresh token belonging to the user. Password change requires the current password
and also revokes **all** sessions, including the caller's session.

The five routes are under `/v1/auth`. Verification and reset **requests** return 202 with an
empty body for well-formed emails whether or not an eligible account exists. Their
**confirmations** return 200 with an empty body on success; password change returns 204.
Malformed input, rate limiting, and dependency failures can still return errors. A 202 means
accepted for processing, not proof that notification delivery succeeded.

The core emits a `Notification` through the `Notifier` effect, an abstract capability whose
interpreter supplies the actual behavior. The standalone server queues notifications for a
background worker. It now supports log, SMTP relay, and signed webhook delivery. SMTP was
excluded from this plan's June completion scope, then introduced by later work; that historical
scope decision must not be mistaken for a present-day absence of SMTP support.

The default log transport redacts tokens. For the local walkthrough only, set
`SHOMEI_NOTIFIER_LOG_SECRETS=true` to expose the one-time token in the log. The emitted URL is
a token carrier: the API confirmation route accepts a JSON **POST**, not a browser GET.
A host UI must read the token and submit the POST, or the developer can copy it into `curl`.

Session revocation immediately prevents refresh. Immediate rejection of an existing access
JWT additionally requires a session-aware verifier, such as the standalone server with
`SHOMEI_SESSION_CHECK=token-and-session`. The default `VerifyTokenOnly` policy and external
stateless JWT verifiers continue accepting a valid access token until its expiry. This plan
must not promise immediate revocation at those consumers.

An opaque token is an unpredictable secret whose hash alone is stored in its token table.
A single-use token may transition from active to consumed only once. TTL means its lifetime:
the workflow rejects `expiresAt <= now`. A compare-and-swap (CAS) is a conditional write that
reports whether this caller changed the row. A unit of work is one persistence operation that
commits several related writes together or rolls all of them back.

## Progress


The completed entries retain the original delivery dates. The old individual M1.1–M1.16,
M2.1–M2.10, M3.1–M3.4, and M4 entries are consolidated here because their create-file
instructions referenced modules and migration machinery that have since been replaced.

- [x] (2026-06-04) M1: identifiers, token and notification domain types, store effects,
  configuration, account workflows, in-memory interpreters, and core tests delivered.
- [x] (2026-06-04) M2: verified-at column, verification/reset token tables, PostgreSQL
  interpreters, and database-backed lifecycle tests delivered.
- [x] (2026-06-04) M3: five account lifecycle routes, DTOs, handlers, and in-process HTTP
  lifecycle coverage delivered.
- [x] (2026-06-04) M4 server wiring and development log notifier delivered.
- [x] (2026-06-10) Original live curl walkthrough completed against development PostgreSQL.
- [x] (2026-06-17) Original M4 SMTP sender and dependency tasks explicitly descoped; original
  EP-1 delivery marked complete. Later transport work is outside that historical decision.
- [x] (2026-10-14) Reconciled current module ownership, APIs, HTTP results, notification
  behavior, migration tooling, ADR context, and revocation guarantees against source.
- [x] (2026-10-14) Ran the core, PostgreSQL, Servant, and server package tests: all eight
  test suites passed. Updated the walkthrough from the passing HTTP contract; the revised
  standalone curl walkthrough was not executed in this review.
- [x] (2026-10-14) `nix develop --command just migration-check` passed manifest validation
  and the migration namespace policy check.

## Surprises & Discoveries


The original June implementation reused `TokenGen` by rewrapping `RefreshToken` and
`RefreshTokenHash` text into one-time-token types; no second generator was needed. Original
M1/M2 evidence recorded 15 core tests and 14 PostgreSQL tests. Those counts describe the old
suites, not today's suite sizes. The June codd embedding problem, formerly worked around by
changing the migrations module, no longer describes the manifest-based migration implementation.

The June SMTP dependency searches were empty and the requirement was removed on 2026-06-17.
Today `shomei-server/src/Shomei/Notify.hs` exports `runNotifierSmtp`, `runNotifierWebhook`,
and `runNotifierEnqueue` as well as `runNotifierLog`. Both `Notification` and `OneTimeToken`
currently have JSON instances; `Notification`'s field is named `email`, not `recipient`.
The former plan's claims that notifications never serialize and only a log interpreter ships
were false for the current code.

The June walkthrough reported 200 at signup and 202 at both confirmations. The current
`shomei-servant/src/Shomei/Account/Result.hs` declares 201 for signup, 202 for requests,
200 for confirmations, and 204 for password change. `Shomei.Servant.Api` mounts the account
routes under `/v1/auth`. Signup requires `loginId`, has an optional `email`, and returns
`token`, not `tokenPair`. Login accepts `loginId`, not `email`.

`consumeVerificationToken` and `consumePasswordResetToken` from the old proposed listing do
not exist. The public operations are `markVerificationTokenConsumed` and
`markPasswordResetTokenConsumed`, both returning `Bool`. The reset workflow uses
`completePasswordReset` instead of a series of independent credential and session writes.
`changePassword` additionally takes a `ProofContext`, uses the shared abuse budget, and
calls `completePasswordChange`. Copying the old listings would regress both APIs and safety.

Two correctness limits remain visible in current source. Email confirmation first CAS-consumes
the token, then separately marks the user verified, revokes sibling tokens, and publishes its
event. A database failure between these operations can leave partial state; the token CAS
proves one winner for the **same token**, not an atomic whole-account verification transition
across different sibling tokens. Neither the verification nor reset token CAS statement checks
expiry in SQL: expiry is checked against a workflow clock sample before the write (and, for
reset, before password hashing). Do not describe these as transaction-time expiry enforcement
or as a fully atomic verification operation. Stronger guarantees require a separate corrective
implementation with failure-injection and concurrent-sibling tests, not just edited prose.

Password reset assumes an existing password credential. Its persistence operation updates a
credential; it does not create one for a passwordless account. Password change does not revoke
outstanding reset links, whereas completing a reset revokes its sibling reset links. These
boundaries must remain explicit when adding new account types or changing recovery policy.

The no-enumeration guarantee concerns normal response status/body and avoidance of inline
transport latency. A hit still does more database work than a miss, as
`shomei-core/test/Shomei/Account/Lifecycle/CostSpec.hs` deliberately records. It is not a
constant-time claim, a byte-identical-all-headers claim, or an unconditional success guarantee
when infrastructure fails.

## Decision Log


2026-06-04: Store verification as nullable `email_verified_at` on the user. A timestamp records
both whether and when verification occurred. Use separate verification and reset token tables,
with typed UUID identifiers, unique hashes, status, and expiry. Reuse the token generator and
hashing capability. Keep ordinary request responses generic. Revoke all sessions and refresh
tokens on successful reset/change. Define notification delivery as an interpreter outside core.

2026-06-04: The initial package-layout revision moved packages to top-level directories and
used the then-current effect namespace. That namespace is historical; the current concept-owned
module paths in Context and Orientation supersede it.

2026-06-17: Remove SMTP sending from the original EP-1 completion requirement and complete
that scope with the log notifier and operator-provided interpreters. Preserve this as a
historical scope decision. Later built-in SMTP/webhook and background-queue functionality is
part of today's runtime and must be retained during maintenance.

2026-10-14: Replace obsolete greenfield code listings with contracts grounded in the current
implementation. Keep the four original milestones as independently testable maintenance
boundaries. No new dependency, pin, compatibility workaround, or migration is selected by this
revision. Existing source and current package test compilation validate the APIs actually used.

2026-10-14: Describe password mutations using `AuthUnitOfWork`, conditional token consumption,
shared abuse protection, and current breach-policy enforcement. Qualify session revocation by
the verifier policy and document the verification transaction/expiry limitations. Do not claim
that an update to this completed plan fixes those implementation limits. The relevant durable
policies already live in the ADRs cited below; this review creates no new architecture decision.

## Outcomes & Retrospective


The original lifecycle delivery was completed on 2026-06-17 after the live demonstration on
2026-06-10 and explicit removal of SMTP from that delivery scope. Subsequent repository work
added optional-email/login-ID accounts, stronger password policies, atomic password write tails,
versioned concept-owned HTTP APIs, additional transports, and bounded background delivery.

The plan had no provenance block when this review began; its original model authorship and
prior review history are unknown. This session records its own revision and review only.

The 2026-10-14 validation found the old plan unsafe to follow literally: nonexistent module and
function names, obsolete migration commands, wrong HTTP examples, and overstated revocation
and atomicity promises. This revision reconciles those instructions and preserves the original
completion history. The current four-package test command exited 0: `shomei-core-test`,
`shomei-postgres-test`, `shomei-servant-test`, `shomei-servant-openapi-test`,
`shomei-server-config-test`, `shomei-server-test`, `shomei-health-test`, and
`shomei-admin-test` passed. Those tests are evidence for their covered cases, not proof of the
unimplemented stronger guarantees described in Surprises & Discoveries. The current
`just migration-check` command also passed manifest and SQL namespace validation.

## Context and Orientation


The repository root is `/Users/shinzui/Keikaku/bokuno/shomei`. It is a Cabal workspace using
GHC 9.12.4 and GHC2024. Use the Nix development environment for builds and tests. Follow the
existing Cabal common stanzas, module exports, formatting, and local import conventions rather
than copying the old four-space-format examples from this plan.

The core workflow is `shomei-core/src/Shomei/Account/Lifecycle/Workflow.hs`. Commands are
defined there. Domain modules are
`shomei-core/src/Shomei/Account/OneTimeToken/Domain.hs`,
`shomei-core/src/Shomei/Account/Verification/Domain.hs`,
`shomei-core/src/Shomei/Account/PasswordReset/Domain.hs`,
`shomei-core/src/Shomei/Account/Notification/Domain.hs`, and
`shomei-core/src/Shomei/Account/User/Domain.hs`. Their persistence/notification capabilities
are in the corresponding `Store.hs` files. `shomei-core/src/Shomei/Id.hs` defines the typed
identifiers, `shomei-core/src/Shomei/Error.hs` the errors, and
`shomei-core/src/Shomei/Config.hs` the policy defaults.

Shared dependencies within core include
`shomei-core/src/Shomei/Session/Token/Generator.hs`,
`shomei-core/src/Shomei/Account/Password/Hash/Store.hs`,
`shomei-core/src/Shomei/Account/Password/Breach/Workflow.hs`,
`shomei-core/src/Shomei/Session/LoginAttempt/Workflow.hs`, and
`shomei-core/src/Shomei/Session/UnitOfWork/Store.hs`.
`shomei-core/src/Shomei/Test/InMemory.hs` implements the test world and effect stack.
Audit types and persistence projections live in
`shomei-core/src/Shomei/Audit/Event/Domain.hs` and
`shomei-core/src/Shomei/Audit/Event/Codec.hs`.

The PostgreSQL implementations are
`shomei-postgres/src/Shomei/Account/Verification/Postgres.hs`,
`shomei-postgres/src/Shomei/Account/PasswordReset/Postgres.hs`,
`shomei-postgres/src/Shomei/Account/User/Postgres.hs`, and
`shomei-postgres/src/Shomei/Session/UnitOfWork/Postgres.hs`.
They use `shomei-postgres/src/Shomei/Persistence/Database/Postgres.hs` for pool execution
and transactions, `shomei-postgres/src/Shomei/Persistence/Codec/Postgres.hs` for codecs,
and `shomei-postgres/src/Shomei/Account/Password/Hash/Postgres.hs` for hashing/token generation.

The HTTP layer is owned by `shomei-servant/src/Shomei/Account/Api.hs`,
`shomei-servant/src/Shomei/Account/Dto.hs`,
`shomei-servant/src/Shomei/Account/Handler.hs`, and
`shomei-servant/src/Shomei/Account/Result.hs`.
`shomei-servant/src/Shomei/Servant/Api.hs` composes these routes;
`shomei-servant/src/Shomei/Servant/Seam.hs` supplies the effect runner;
`shomei-servant/src/Shomei/Servant/Error.hs` maps errors to problem responses.
There is no current monolithic `ShomeiAPI` record or account `Servant.Handlers` module to extend.
A DTO is the JSON request/response record at this transport boundary.

`shomei-server/src/Shomei/Server/App.hs` installs store interpreters and
`runNotifierEnqueue`. `shomei-server/src/Shomei/Server/Boot.hs` owns worker and queue lifetime.
`shomei-server/src/Shomei/Notify.hs` implements transports, while
`shomei-server/src/Shomei/Notify/Queue.hs` implements the bounded queue.
`shomei-server/src/Shomei/Server/Config.hs`, `config/shomei-types.dhall`, and
`config/shomei.example.dhall` are the runtime configuration surfaces.

Migrations are manifest-ordered SQL under `shomei-migrations/migrations/shomei/`.
The lifecycle migrations already exist as `0008-shomei-users-email-verified.sql`,
`0009-shomei-email-verification-tokens.sql`, and `0010-shomei-password-reset-tokens.sql`
in that directory. `shomei-migrations/src/Shomei/Migrations.hs` embeds the manifest through
pg-migrate. Later migrations make email optional, add login IDs, and enforce status/identity
constraints. Do not reconstruct the current schema from just the original three files.

The relevant ADRs were discovered by scanning `docs/adr/` filenames and headings, then reading
these records. [ADR-5](docs/adr/0005-every-credential-proof-participates-in-one-abuse-budget.md)
requires password-change proof failures to join the shared abuse budget and routes to carry
`RateLimited`. [ADR-7](docs/adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md)
requires conditional single-use transitions and transactional credential write tails.
[ADR-8](docs/adr/0008-runtime-configuration-is-open-strict-and-synchronized.md) requires strict,
synchronized configuration decoding and defaults.
[ADR-10](docs/adr/0010-notification-delivery-is-a-bounded-background-responsibility.md)
defines bounded, nonblocking, best-effort queue delivery and accepts residual database hit/miss
cost. [ADR-11](docs/adr/0011-runtime-secrets-stay-outside-printable-configuration.md) keeps SMTP
and webhook secrets outside printable policy configuration.
[ADR-13](docs/adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md)
records diagnostic redaction policy; do not infer that every one-time-token type has a redacted
`Show` instance, because the current types still derive it.
[ADR-19](docs/adr/0019-migration-components-do-not-mutate-shared-namespace-state.md)
requires schema-qualified SQL and transaction-local search paths.

The parent integration responsibilities remain: IP-1 is notification emission, IP-2 is the
one-time-token model and storage, IP-3 is configuration, IP-5 is the account HTTP surface,
and IP-7 is schema evolution. These are summaries of the responsibilities, not purported
verbatim quotations of obsolete parent module names.

## Plan of Work


### Milestone M1 — core domain, effects, workflows, and tests


Maintain the existing lifecycle workflow and its concept-owned domain/store modules. Keep
commands, effect constraints, nullable user email, password policy/breach checking, and event
payloads consistent with Interfaces and Dependencies. Use the atomic in-memory transitions
already provided by `Shomei.Test.InMemory`; a read followed by an unguarded mutable write is
not an equivalent implementation of CAS. Run `cabal test shomei-core` inside `nix develop`.
Acceptance is observable: requests emit only for eligible users, confirmation changes the
appropriate state, replays fail, sibling tokens are revoked after successful confirmation,
reset/change revoke sessions, and failed password-change proofs count toward lockout.

### Milestone M2 — persistence and migrations


Maintain the current Hasql adapters and `AuthUnitOfWork` interpreter. Reset must consume its
token, update the existing password credential, revoke sessions/refresh tokens and sibling
reset tokens, and persist completion events in one transaction. Change must update the
password, revoke sessions/refresh tokens, and persist its event in one transaction. Preserve
conditional token consumption with a returned winner result. Use existing migrations; append
new ones only for an actual schema change. Run `cabal test shomei-postgres` and, for schema
changes, `just migration-check` and `cabal test shomei-migrations`. Acceptance includes real
PostgreSQL token CAS round trips, verification, password reset, sibling-token rejection, and
revocation. Email verification's separate writes remain the documented limitation.

### Milestone M3 — typed HTTP contract


Keep `AccountApi`, DTOs, handlers, and response alternatives synchronized. The current API
uses Servant `MultiVerb`: each route names its success and error response alternatives;
`ApplicationEmptyResponses` encodes an empty success with `RespondEmpty`. Preserve
`RateLimited`, input-error declarations, and password change's authenticated/CSRF-protected
boundary. The handler takes client address information into `ProofContext` and forbids
password change under delegation. Run `cabal test shomei-servant`; acceptance is the
in-process lifecycle flow plus OpenAPI contract tests with the statuses and JSON below.

### Milestone M4 — runtime notification delivery and demonstration


Maintain the queue interpreter in the request path and the supervised delivery worker in
boot. The queue defaults to 1024 entries, does not wait for transport delivery, drops new work
when full, and audits overflow/shutdown/expired queued work. Shutdown closes and drains it
up to the configured deadline. The queue is not durable. Keep default logs token-free and
runtime credentials outside `ShomeiConfig`. Run `cabal test shomei-server`; acceptance includes
notification redaction, queue overflow/shutdown, transport failure handling, and config tests.
The optional local curl demonstration below proves the public workflow using emitted tokens.

## Concrete Steps


All commands start at the repository root. For ordinary validation, run the same command used
successfully in this review; it compiles the relevant APIs as well as exercising behavior:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop --command cabal test shomei-core shomei-postgres shomei-servant shomei-server --test-show-details=failures
```

Expected: all eight suites report `PASS` and the command exits 0. The PostgreSQL suite uses
`withShomeiMigratedDatabase` from
`shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs`, which provisions isolated
ephemeral PostgreSQL and applies the embedded plan. A running development database is not
required for those tests. Test package compilation is the primary check that the named APIs
and effect constraints compose with the resolved dependencies.

For a subsequent implementation change, inspect the files for the owning milestone, edit them
and their meaningful behavioral tests together, and rerun the affected suite. Add exposed/test
modules to the corresponding `.cabal` only if a new module is introduced. Run `nix fmt` for
source edits. Recheck the other suites when an effect, DTO, or shared config change crosses
package boundaries. This documentation-only revision does not recreate the completed feature.

For a real schema addition, use a positional slug (the old `name=...` commands are invalid):

```bash
nix develop --command just new-migration account-lifecycle-followup
nix develop --command just migration-check
nix develop --command cabal test shomei-migrations shomei-postgres
```

Run that scaffold command only when adding a migration. It creates the next numbered SQL file
and appends manifest membership. Fill its SQL with schema-qualified objects and preserve
`SET LOCAL search_path = pg_catalog, pg_temp;`. It is not codd SQL and must not use the old
session-scoped `SET search_path TO shomei, pg_catalog`. Do not add duplicate lifecycle tables.

For the local live demonstration, use the complete development stack defined in
`process-compose.yaml`. It starts PostgreSQL, creates/migrates the development database,
ensures an active signing key, and starts the server. The Nix shell supplies
`PG_CONNECTION_STRING`. `just migration-status` is read-only; `just migrate` applies pending
manifest migrations to that selected database. In the stack terminal run:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop
export SHOMEI_TOKEN_TRANSPORT=bearer
export SHOMEI_NOTIFIER_TRANSPORT=log
export SHOMEI_NOTIFIER_LOG_SECRETS=true
export SHOMEI_SESSION_CHECK=token-and-session
export SHOMEI_EMAIL_VERIFICATION_REQUIRED=false
export SHOMEI_PUBLIC_BASE_URL=http://localhost:8080
process-compose up --no-server
```

The `--no-server` flag disables process-compose's own REST listener, which would otherwise
compete with Shōmei for port 8080. Do not start a second standalone server alongside this stack.
Wait for `create_schema` and `bootstrap_keys` to complete and for the server to become ready.
These overrides describe an isolated local test with body tokens, visible notification tokens,
and session-aware route authentication. Use port 8080 or set `BASE` below to the configured
address. If `SHOMEI_CONFIG` selects another environment, use a dedicated development shell
with the appropriate database and runtime configuration. Stop the server with Ctrl-C after
the demonstration and clear `SHOMEI_NOTIFIER_LOG_SECRETS` before reusing the shell elsewhere.

## Validation and Acceptance


### Automated behavior


`shomei-core/test/Shomei/AccountSpec.hs` covers verification, replay/sibling rejection,
unknown-email reset requests, reset revocation, wrong-current-password rejection and lockout,
and new-password policy/breach handling. `shomei-core/test/Shomei/Session/Authentication/ConcurrencySpec.hs`
covers racing confirmations of the same reset token.
`shomei-core/test/Shomei/Account/Verification/WorkflowSpec.hs` covers the verification gate
for login/refresh/passkeys and the no-email exemption.
`shomei-core/test/Shomei/Account/Lifecycle/CostSpec.hs` distinguishes hit/miss operation costs.

`shomei-postgres/test/Main.hs` covers the real store CAS operations and lifecycle workflows,
including password-reset sibling rejection and its three database-round-trip budget.
`shomei-servant/test/Main.hs` exercises account lifecycle JSON/status behavior end to end
in-process. The Servant OpenAPI suite verifies the served API's documented contract.
`shomei-server/test/Shomei/Server/NotifySpec.hs` exercises redacted/default and explicit
raw-token logging, queue behavior, and transport handling. Configuration tests check defaults
and strict input validation. Do not relabel these existing tests as fault-injection proof of
the whole email verification sequence; no such proof was established in this review.

### Local HTTP demonstration


Use a new login/email on each run to avoid duplicate-account conflicts. The commands require
`curl` and `jq`. They use a password-bearing account with no enrolled MFA. The chosen sample
passphrases must satisfy the deployment's password policy; a stricter local policy may require
replacement. These are expected results, not a new live-run transcript from this review.

```bash
BASE=http://localhost:8080/v1/auth
DEMO_ID="lifecycle-$(date +%s)"
DEMO_EMAIL="$DEMO_ID@example.com"
OLD_PASSWORD='violet nebula cedar lantern 907!'
NEW_PASSWORD='cobalt meadow quartz river 608!'
CHANGED_PASSWORD='amber glacier willow comet 319!'

SIGNUP=$(curl -sS --fail-with-body "$BASE/signup" \
  -H 'content-type: application/json' \
  --data "$(jq -nc --arg i "$DEMO_ID" --arg e "$DEMO_EMAIL" --arg p "$OLD_PASSWORD" \
    '{loginId:$i,email:$e,password:$p,displayName:"Lifecycle Demo"}')")
OLD_REFRESH=$(printf '%s' "$SIGNUP" | jq -er '.token.refreshToken')
OLD_ACCESS=$(printf '%s' "$SIGNUP" | jq -er '.token.accessToken')

curl -sS -i "$BASE/verify-email/request" -H 'content-type: application/json' \
  --data "$(jq -nc --arg e "$DEMO_EMAIL" '{email:$e}')"
```

Signup returns **201** with `{user,token}`; the request returns **202** and an empty body.
Wait for the background worker's line containing `email_verification`, the selected email,
and `link=.../v1/auth/verify-email/confirm?token=...`. Copy only its token value:

```bash
VTOKEN='replace-with-verification-token-from-local-log'
curl -sS -i "$BASE/verify-email/confirm" -H 'content-type: application/json' \
  --data "$(jq -nc --arg t "$VTOKEN" '{token:$t}')"
psql "$PG_CONNECTION_STRING" -v demo_email="$DEMO_EMAIL" <<'SQL'
SELECT email_verified_at FROM shomei.shomei_users WHERE email = :'demo_email';
SQL
```

Expect **200**, an empty confirmation body, and a non-null timestamp from the database.
Run this terminal inside the Nix shell too so it has `psql` and the database connection.
`GET /v1/auth/me` returns `UserResponse`, which does not expose `emailVerifiedAt`.
Repeating the confirmation yields **400** with problem code `verification_token_invalid`.
Request a reset for both a known and a new unknown address:

```bash
curl -sS -i "$BASE/password-reset/request" -H 'content-type: application/json' \
  --data "$(jq -nc --arg e "$DEMO_EMAIL" '{email:$e}')"
curl -sS -i "$BASE/password-reset/request" -H 'content-type: application/json' \
  --data "$(jq -nc --arg e "unknown-$DEMO_EMAIL" '{email:$e}')"
```

Both return **202** with empty bodies. Only the eligible known account produces a notification.
Copy the reset token from its `password_reset` log line and confirm:

```bash
RTOKEN='replace-with-reset-token-from-local-log'
curl -sS -i "$BASE/password-reset/confirm" -H 'content-type: application/json' \
  --data "$(jq -nc --arg t "$RTOKEN" --arg p "$NEW_PASSWORD" '{token:$t,newPassword:$p}')"
curl -sS -i "$BASE/refresh" -H 'content-type: application/json' \
  --data "$(jq -nc --arg t "$OLD_REFRESH" '{refreshToken:$t}')"
curl -sS -i "$BASE/me" -H "Authorization: Bearer $OLD_ACCESS"
```

Expect **200** for reset, **401** for the old refresh token, and **401** for the old access
token at `me` with the explicitly selected session-check policy. Replaying the reset token
returns **400** with `password_reset_token_invalid`. Login with the old password returns
**401**; login with the new password returns **200**, `status:"complete"`, and a fresh `token`:

```bash
LOGIN=$(curl -sS --fail-with-body "$BASE/login" -H 'content-type: application/json' \
  --data "$(jq -nc --arg i "$DEMO_ID" --arg p "$NEW_PASSWORD" '{loginId:$i,password:$p}')")
ACCESS=$(printf '%s' "$LOGIN" | jq -er '.token.accessToken')
REFRESH=$(printf '%s' "$LOGIN" | jq -er '.token.refreshToken')

curl -sS -i "$BASE/password/change" -H 'content-type: application/json' \
  -H "Authorization: Bearer $ACCESS" \
  --data "$(jq -nc --arg c "$NEW_PASSWORD" --arg n "$CHANGED_PASSWORD" \
    '{currentPassword:$c,newPassword:$n}')"
curl -sS -i "$BASE/refresh" -H 'content-type: application/json' \
  --data "$(jq -nc --arg t "$REFRESH" '{refreshToken:$t}')"
```

Expect **204** for change and **401** for its now-revoked refresh token. A subsequent login
with `CHANGED_PASSWORD` succeeds. The authenticated password-change route uses CSRF checks
for cookie authentication; the demonstration uses bearer authentication and sends no cookies.
The route is throttled, so rapid repeated demonstrations may return 429; allow the bucket to
refill before retrying rather than interpreting that as a lifecycle failure.

## Idempotence and Recovery


This completed plan is not replayed by overwriting source files. Inspect the current tree and
make the smallest owning-module changes for any subsequent maintenance. Test databases are
isolated. The manual walkthrough creates a fresh account each time and leaves its records in
the selected development database; never point it at production.

Repeated request calls can issue multiple active tokens. Successful verification revokes active
sibling verification tokens; successful reset revokes active sibling reset tokens. Repeated
confirmation of the same consumed token is an error, not an idempotent success. Invalid or
weak replacement passwords are rejected before reset consumption, so the user can retry with
a compliant password while the token remains valid.

Migration application uses the manifest and pg-migrate ledger. Already-applied migrations are
skipped; checksum disagreements require investigation, not ledger deletion or editing applied
SQL to force acceptance. New migrations are append-only. The embed/recompile integration in
`Shomei.Migrations` replaces the old touch-the-Cabal-file workaround. After adding a migration,
rebuild and run the manifest check before applying it to a selected development database.

A reset transaction failure rolls back its password/token/session/event writes; report the
dependency error and retry according to the resulting token state. A failure midway through
verification may leave a consumed token without all later writes. Request a new token if the
account is still unverified, and investigate incomplete verification/audit state; do not assume
the whole confirmation rolled back or repair production rows ad hoc. Queue loss on crash,
overflow, or shutdown deadline is best-effort delivery behavior; users can request another link.

## Interfaces and Dependencies


### Core contracts


`VerificationTokenId = KindID "verification_token"` and
`PasswordResetTokenId = KindID "password_reset_token"` are already exported by `Shomei.Id`,
with `genVerificationTokenId`, `genPasswordResetTokenId`, and each `...ToUUID`/`...FromUUID`
converter. `Data.KindID.V7.genKindID`, `getUUID`, and `decorateKindID` support this UUIDv7
mapping. They do not make the token secret; the separate opaque token carries that secret.

`PersistedVerificationToken` and `PersistedPasswordResetToken` contain their typed ID,
`userId`, `tokenHash`, `status`, `createdAt`, `expiresAt`, `consumedAt`, and `revokedAt`.
Each `New...Token` contains `userId`, `tokenHash`, `createdAt`, and `expiresAt`.
`User.email :: Maybe Email` and `User.emailVerifiedAt :: Maybe UTCTime`; a new user is unverified.
`mkEmail` validates/normalizes wire text before constructing the request commands.

`Notification` has `EmailVerificationRequested` and `PasswordResetRequested`, each carrying
`email :: Email`, `token :: OneTimeToken`, and `expiresAt :: UTCTime`. JSON serialization is
used by the webhook sender and therefore deliberately includes the raw token. Do not log
`show notification` or serialized notification bodies as operational diagnostics.
The effect still has the following interface:

```haskell
sendNotification :: (Notifier :> es) => Notification -> Eff es ()
```

It is a dynamic effect with `SendNotification :: Notification -> Notifier m ()`,
`DispatchOf Notifier = Dynamic`, a `send` smart constructor, and first-order `interpret_`
handlers. A smart constructor here dispatches an operation; validation constructors such as
`mkEmail` serve a different role by enforcing a value's invariants.

Both token stores export `create...Token`, `find...TokenByHash`, `mark...TokenConsumed`, and
`revokeUser...Tokens`. The exact consume and unit-of-work interfaces are:

```haskell
markVerificationTokenConsumed ::
  (VerificationTokenStore :> es) => VerificationTokenId -> UTCTime -> Eff es Bool
markPasswordResetTokenConsumed ::
  (PasswordResetTokenStore :> es) => PasswordResetTokenId -> UTCTime -> Eff es Bool

completePasswordReset ::
  (AuthUnitOfWork :> es) =>
  PasswordResetTokenId -> UserId -> PasswordHash -> UTCTime -> [AuthEvent] -> Eff es Bool
completePasswordChange ::
  (AuthUnitOfWork :> es) =>
  UserId -> PasswordHash -> UTCTime -> [AuthEvent] -> Eff es ()
```

The workflow commands remain `RequestEmailVerification Email`,
`ConfirmEmailVerification OneTimeToken`, `RequestPasswordReset Email`,
`ConfirmPasswordReset OneTimeToken PlainPassword`, and
`ChangePassword UserId PlainPassword PlainPassword`, with the named fields in
`Shomei.Account.Lifecycle.Workflow`. All five return `Eff es (Either AuthError ())`.
The exact effect constraints and arguments are:

```haskell
requestEmailVerification ::
  (UserStore :> es, VerificationTokenStore :> es, Notifier :> es,
   AuthEventPublisher :> es, Clock :> es, TokenGen :> es) =>
  ShomeiConfig -> RequestEmailVerification -> Eff es (Either AuthError ())

confirmEmailVerification ::
  (VerificationTokenStore :> es, UserStore :> es, AuthEventPublisher :> es,
   Clock :> es, TokenGen :> es) =>
  ShomeiConfig -> ConfirmEmailVerification -> Eff es (Either AuthError ())

requestPasswordReset ::
  (UserStore :> es, PasswordResetTokenStore :> es, Notifier :> es,
   AuthEventPublisher :> es, Clock :> es, TokenGen :> es) =>
  ShomeiConfig -> RequestPasswordReset -> Eff es (Either AuthError ())

confirmPasswordReset ::
  (UserStore :> es, PasswordResetTokenStore :> es, PasswordHasher :> es,
   PasswordBreachChecker :> es, AuthUnitOfWork :> es, Clock :> es, TokenGen :> es) =>
  ShomeiConfig -> ConfirmPasswordReset -> Eff es (Either AuthError ())

changePassword ::
  (UserStore :> es, CredentialStore :> es, PasswordHasher :> es,
   PasswordBreachChecker :> es, AuthUnitOfWork :> es, AuthEventPublisher :> es,
   LoginAttemptStore :> es, Clock :> es) =>
  ShomeiConfig -> ProofContext -> ChangePassword -> Eff es (Either AuthError ())
```

Request workflows notify only active users with an email; verification also requires that
email to be unverified. Unknown/ineligible users produce `Right ()` without notification.
Confirmation hashes the presented token, checks active status and expiry, and resolves its
user. Verification rejects a missing email, returns `EmailAlreadyVerified` if already verified,
and proceeds only after a successful token CAS. It then marks the user, revokes sibling
verification tokens, and publishes `EmailVerified` as separate operations.

Reset validates the replacement password with email/display-name context and applies the
configured breach check before hashing. `completePasswordReset` owns its entire write tail;
a false result becomes `PasswordResetTokenInvalid`. Change derives the abuse key from
`ProofContext` and the user's login ID, performs a dummy password check when locked, checks
new-password policy/breach status, verifies the existing credential by login ID, records proof
success/failure, hashes the replacement, and calls `completePasswordChange`. The audit payloads
are the existing `Event.*Data` constructors in `Shomei.Audit.Event.Domain`, not the obsolete
four-record sketch from the initial plan.

### Persistence and expiry


The token table row mappings include both optional `consumed_at` and `revoked_at` timestamps.
A successful consume statement has the shape below; the reset store uses its own table/id.
`D.rowMaybe` returns `Maybe UUID`, which the interpreter turns into the public `Bool`.

```sql
UPDATE shomei.shomei_email_verification_tokens
SET status = 'consumed', consumed_at = $2
WHERE verification_token_id = $1 AND status = 'active'
RETURNING verification_token_id;
```

This statement does not recheck TTL or user state. The workflow's earlier `expiresAt > ts`
check is the current expiry contract. `AuthUnitOfWork` runs its writes with
`Hasql.Transaction.statement` under `runTransaction`; `runDatabasePool` selects
`Tx.transaction Tx.ReadCommitted Tx.Write`. Hasql statements use `preparable` with `Text`
SQL and applicative row decoders. Database errors are translated through
`postgresUnavailable` to `DependencyUnavailable PostgreSQL`, not exposed as driver strings
inside `InternalAuthError`. The standard HTTP mapping reports a 503 dependency problem.

### Configuration and runtime assembly


`cfg.notifierConfig` contains `emailVerificationRequired`, `verificationTokenTTL`,
`passwordResetTokenTTL`, `notifierTransport`, `publicBaseUrl`, `logRawTokens`, `smtpConfig`,
`webhookConfig`, and `alsoLogNotifications`. Defaults are a 24-hour verification TTL, one-hour
reset TTL, `LogNotifier`, `http://localhost:8080`, false flags, and absent optional transport
sub-configs. The notifier default is constructed inside `defaultShomeiConfig`; there is no
exported `defaultNotifierConfig` or `linkBaseUrl` field.

`emailVerificationRequired` controls token-issuance gates through
`shomei-core/src/Shomei/Session/Workflow.hs` and its callers. It is not a general check on
every protected operation: signup still issues its initial pair, subsequent gated login and
refresh reject unverified email accounts, and accounts with no email are exempt. The default
is false. Preserve the dedicated verification-gate tests when modifying this behavior.

Current notifier assembly signatures include:

```haskell
runNotifierLog ::
  (IOE :> es) => NotifierConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierEnqueue ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  NotifierQueue -> Text -> Eff (Notifier : es) a -> Eff es a
runNotifierFromConfig ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  Manager -> NotifierSecrets -> ShomeiConfig -> Eff (Notifier : es) a -> Eff es a
```

`runNotifierFromConfig` is a synchronous dispatch interpreter useful for explicit embedding;
the standalone request path uses `runNotifierEnqueue`, and its worker calls
`deliverNotification`. `NotifierSecrets` supplies SMTP/webhook credentials separately from
public policy. Default logs contain a token hash prefix, not the secret or full link.

### Dependency API evidence


This update selected no new versions or bounds. Existing package manifests and the successful
Cabal test build determine the resolved APIs. Dependency source was discovered with
`mori registry list`, `mori registry search`, `mori registry show --full`, and
`mori registry docs`, and read directly from the registered source checkouts.

The checked dependencies are `mori://effectful/effectful/packages/effectful-core` for
`Effectful.Dispatch.Dynamic.interpret_` and dynamic effects;
`mori://MMZK1526/mmzk-typeid/packages/mmzk-typeid` for `Data.KindID.V7`;
`mori://hasql/hasql/packages/hasql` and
`mori://hasql/hasql/packages/hasql-transaction` for statement construction and transactions;
`mori://haskell-servant/servant/packages/servant` for `NamedRoutes`, `MultiVerb`, and
`RespondEmpty`; and `mori://shinzui/pg-migrate/packages/pg-migrate-embed` for
`embedMigrationManifest`. The Hasql API migration guidance was read through
`mori://hasql/hasql/docs/hasql-1.10-migration` and confirmed against source and current imports.
These references locate API evidence, not assertions that the local corpus is the latest release.
Any future dependency-bound or compatibility decision must first verify released versions
against the authoritative registry and upstream tags, as required by the repository instructions.

## Revision Notes


2026-06-04: Updated after the package-layout refactor and MasterPlan audit; replaced nested
package paths and bootstrap-placeholder assumptions with the then-current implemented modules.

2026-06-17: Descoped SMTP delivery from this plan and marked original EP-1 complete after the
log-based live walkthrough. Removed the then-vestigial SMTP constructor/stub. This historical
entry does not describe the transports introduced by later work.

2026-10-14: Validated correctness and APIs against the current working tree and Mori-discovered
dependency source. Replaced obsolete creation listings and codd commands with concept-owned
module contracts and manifest-based migration instructions; corrected DTOs, statuses, `/v1`
routing, notifier signatures/default redaction, credential transactions, proof context, and
session-aware revocation. Added relevant ADR context, explicit verification atomicity/expiry
limits, current acceptance commands and a corrected local demonstration. Consolidated historical
completion entries without claiming a new implementation or a rerun of the manual walkthrough.
All eight test suites in the four relevant packages passed.
