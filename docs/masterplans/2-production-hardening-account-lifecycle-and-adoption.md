---
id: 2
slug: production-hardening-account-lifecycle-and-adoption
title: "Production Hardening, Account Lifecycle, and Adoption"
kind: master-plan
created_at: 2026-06-04T02:41:59Z
intention: "intention_01kt8847mre3wa36x0s0k9j6pm"
---


# Production Hardening, Account Lifecycle, and Adoption

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Precondition: MasterPlan 1 must be complete

This initiative is **strictly post-bootstrap**. It builds on the working vertical slice
delivered by MasterPlan 1, `docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md`.
Every child plan here assumes that MasterPlan 1's EP-1 through EP-7 are Complete — in
particular that `shomei-server` boots against PostgreSQL, serves the `ShomeiAPI`
(`POST /auth/signup`, `/auth/login`, `/auth/refresh`, `/auth/logout`, `GET /auth/me`,
`/auth/session`, `GET /.well-known/jwks.json`, `GET /health`), signs/verifies ES256 JWTs,
publishes JWKS, and the two demo apps run. As of the 2026-06-04 layout refactor, that
precondition is satisfied: `cabal build all` and `cabal test all` pass, and `mori show
--full` reports the library and application packages as top-level directories
(`shomei-core`, `shomei-jwt`, `shomei-migrations`, `shomei-postgres`,
`shomei-servant`, `shomei-server`, and `shomei-client`). The child plans should therefore
extend the real modules that now exist rather than waiting for placeholder packages.

Because the dependency on MasterPlan 1 is global and identical for every child plan, it is
stated once here rather than repeated in every registry row. The Hard Deps / Soft Deps
columns in the Exec-Plan Registry below refer only to dependencies *within this* MasterPlan.


## Vision & Scope

MasterPlan 1 proves that Shōmei *works*. This MasterPlan makes Shōmei **usable in
production by real operators and adoptable by other teams** — the gap between "the vertical
slice runs on my laptop" and "I can deploy this, operate it safely, and hand it to a
downstream team."

After this initiative is complete, an operator can: deploy `shomei-server` as a single
reproducible OCI container image against a managed PostgreSQL, and — for local development
and testing — bring up the whole stack with one `process-compose up` against a local
PostgreSQL bound to a Unix-domain socket (no TCP port, so it never conflicts with another
local Postgres); load all runtime
settings (issuer, audience, TTLs, password policy, rate limits, notifier, log level) from a
single typed Dhall configuration file or environment variables; run database migrations and
generate/rotate signing keys through a dedicated `shomei-admin` command-line tool rather
than ad-hoc SQL; watch structured JSON logs with per-request correlation IDs, scrape a
Prometheus `/metrics` endpoint, and gate traffic on a `/ready` readiness probe distinct
from the existing liveness `/health`; and rely on the server to throttle brute-force login
attempts, lock accounts after repeated failures, and rate-limit unauthenticated endpoints.

A new end user of a Shōmei-protected application can, for the first time, complete the
**account lifecycle** the bootstrap omitted: verify their email address after signup via a
single-use tokenized link, and reset a forgotten password through a request/confirm flow
that revokes all existing sessions on success. An authenticated user can change their
password. These flows are delivered behind a pluggable notification effect
(`Shomei.Effect.Notifier`): the toolkit *emits* each notification — recipient, one-time
link/token, and expiry — and ships a development log-only sender that writes the link to the
server log. **Shōmei does not send email itself.** An operator wires delivery to their
existing email provider (SendGrid, Resend, SES, an SMTP relay, …) by supplying their own
`Notifier` interpreter, so no particular email transport is baked into the toolkit.

Finally, a developer evaluating Shōmei can read the documentation the spec's repo layout
promised but the bootstrap never wrote — `docs/architecture.md`, `docs/api.md`,
`docs/security.md`, `docs/deployment.md`, and a top-level getting-started `README.md` — and
stand up the toolkit in either deployment mode by following them.

**In scope.** Email verification and password-reset/change workflows with a notification
effect; a development log-only sender that emits the one-time link (Shōmei does not deliver
email — operators forward the emitted notification to their own provider); brute-force and
rate-limit protection (per-IP and per-account login throttling, account lockout, and
generic responses that do not leak account existence); structured logging, Prometheus
metrics, readiness/liveness probes, request correlation IDs, and graceful shutdown; an
operational CLI (`shomei-admin`) for migrations, signing-key generation/rotation/retirement,
and bootstrap user creation; a typed Dhall + environment configuration layer; a production
OCI/Docker image; a local development/test stack run with `process-compose` against a
Unix-socket PostgreSQL (no `docker compose`); a CI pipeline (build, test, format check);
and the four `docs/*.md` files plus a getting-started README.

**Explicitly out of scope (still deferred, consistent with MasterPlan 1 and the spec).**
OAuth, OIDC, social login, magic links, passkeys/WebAuthn, MFA, device management, an admin
UI, organization/team management, a full authorization policy engine, risk scoring, and
anomaly detection. **Sending email** is out of scope: Shōmei emits a notification through
the `Notifier` effect and ships only the dev log-only sender; delivering it (SMTP, SendGrid,
Resend, SES, …) is the operator's concern, wired by their own `Notifier` interpreter. A
future `shomei-email` package may add in-tree provider senders if the need arises.
Event-sourcing the audit log (MessageDB) remains deferred. This plan
does **not** change the existing signup/login/refresh/logout/verify workflows' semantics; it
*adds* account-lifecycle flows and *wraps* the existing surface with hardening and
operability. It also does not introduce horizontal-scaling concerns beyond what a single
container needs (no distributed rate-limit store, no clustering); the rate limiter and
lockout state are backed by PostgreSQL and in-process structures, which is sufficient for
the single-instance deployment this plan targets, with the distributed story noted as a
future concern.


## Decomposition Strategy

The initiative is decomposed by **functional concern**, mirroring the three themes the
initiative was scoped around (account flows, production hardening/operability, and
adoption) and respecting Shōmei's package layering (`shomei-core` →
`shomei-jwt`/`shomei-postgres` → `shomei-servant` → `shomei-server`). Each child plan
produces an independently demonstrable behavior: a new endpoint you can `curl`, a metric you
can scrape, a CLI command you can run, an image you can boot, or a document you can follow.

Six child plans are grouped into four implementation phases:

- **Phase 1 — Account Lifecycle.** EP-1 (plan 8) adds the email-verification and
  password-reset/change flows end-to-end: new single-use tokenized domain types and their
  effect interfaces, new codd migrations, a `Shomei.Effect.Notifier` notification effect with a
  dev log-only sender (no email transport), new core workflows, new `ShomeiAPI` routes and handlers, and server wiring.
  It is first because it introduces the `Notifier` effect and the `ShomeiConfig`/migration
  extension patterns that later plans reuse, and because it is the largest user-visible
  feature gap.

- **Phase 2 — Hardening & Observability (parallel).** EP-2 (plan 9, abuse protection) and
  EP-3 (plan 10, observability) both wrap the existing HTTP surface with WAI middleware and
  extend `ShomeiConfig`, but touch disjoint concerns (throttling/lockout vs.
  logging/metrics/probes) and can be built concurrently. They share the middleware-assembly
  integration point (IP-4), reconciled there.

- **Phase 3 — Operations.** EP-4 (plan 11) delivers the `shomei-admin` CLI and the
  signing-key rotation lifecycle (pending → active → retired → revoked, with JWKS reflecting
  overlapping keys during rotation). EP-5 (plan 12) packages everything: the production OCI
  image, the local `process-compose` development/test stack (Unix-socket PostgreSQL + server,
  replacing the earlier `docker compose` design), the typed Dhall/env configuration loader
  that assembles the fully-extended `ShomeiConfig`, and CI. EP-5 hard-depends on EP-4 because
  the container entrypoint runs migrations and ensures an active signing key *through the CLI*.

- **Phase 4 — Adoption.** EP-6 (plan 13) writes `docs/architecture.md`, `docs/api.md`,
  `docs/security.md`, `docs/deployment.md`, and the getting-started `README.md`. It is last
  because accurate docs must describe the *finished* behavior of all prior plans; it
  soft-depends on every other plan so each one's surface is final before it is documented.

Alternatives considered. **Folding the three themes into three mega-plans** (one for account
flows, one for all hardening/ops, one for docs) was rejected: the hardening/ops theme alone
spans abuse protection, observability, a CLI, and packaging — four independently verifiable
behaviors that would blow past the ExecPlan size guidance and serialize unrelated work.
**Merging the CLI into packaging** (EP-4 into EP-5) was rejected because the signing-key
rotation lifecycle is a security-sensitive, independently testable behavior (generate →
activate → verify old tokens still validate during overlap → retire) that earns its own
plan, and because packaging consumes the CLI as a dependency rather than containing it.
**Splitting account verification from password reset** was rejected because both share the
same new single-use-token machinery, the same `Notifier` effect, and the same migration and
DTO patterns; verifying them together is cheaper and they form one coherent "account
lifecycle" behavior. **Adding a distributed (Redis) rate-limit store** was rejected as
out of scope for a single-instance deployment; PostgreSQL-backed and in-process state is
sufficient and avoids a new infrastructure dependency.


## Exec-Plan Registry

Every plan below additionally requires **all of MasterPlan 1 to be Complete** (see
Precondition above); that global dependency is omitted from the columns, which list only
intra-MasterPlan-2 dependencies.

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Account lifecycle: email verification and password reset | docs/plans/8-account-lifecycle-email-verification-and-password-reset.md | None | None | Complete |
| 2 | Abuse protection: rate limiting and brute-force lockout | docs/plans/9-abuse-protection-rate-limiting-and-brute-force-lockout.md | None | EP-1 | Complete |
| 3 | Observability: structured logging, metrics, and health probes | docs/plans/10-observability-structured-logging-metrics-and-health-probes.md | None | None | Complete |
| 4 | Operational CLI and signing-key rotation tooling | docs/plans/11-operational-cli-and-signing-key-rotation-tooling.md | None | None | Complete |
| 5 | Packaging, configuration, and deployment | docs/plans/12-packaging-configuration-and-deployment.md | EP-4 | EP-1, EP-2, EP-3 | In Progress |
| 6 | Documentation and adoption guides | docs/plans/13-documentation-and-adoption-guides.md | None | EP-1, EP-2, EP-3, EP-4, EP-5 | Complete |
| 7 | Audit log retrieval API and CLI | docs/plans/14-audit-log-retrieval-api-and-cli.md | None | EP-2, EP-3, EP-4 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The single hard ordering inside this MasterPlan is **EP-5 → EP-4**: the production container
image's entrypoint and the local `process-compose` stack from EP-5 (plan 12) run database
migrations and ensure an active signing key exists at startup by invoking the `shomei-admin`
CLI that EP-4 (plan 11) builds, so EP-5 cannot ship a working entrypoint until the CLI exists.
Everything else is soft.

EP-1 (plan 8) has no intra-plan dependency but is sequenced first because it *introduces*
three things later plans build on: the `Shomei.Effect.Notifier` mailer effect (reused by EP-2's
account-lockout notification), the convention for appending new fields to `ShomeiConfig`
without conflict (IP-3), and the convention for appending new codd migrations (IP-7). Later
plans can technically begin before EP-1 lands by stubbing these, but starting after EP-1 is
cheaper, so EP-2 soft-depends on EP-1.

EP-2 (plan 9, abuse protection) and EP-3 (plan 10, observability) are independent of each
other and run in **parallel** during Phase 2. Both add WAI middleware to the
`shomei-server` `Application` and both extend `ShomeiConfig`, so they must agree on the
middleware ordering and the config-extension mechanism (IP-3, IP-4) but share no code that
forces serialization.

EP-4 (plan 11, CLI + key rotation) is independent of EP-1/EP-2/EP-3 and may proceed any
time after MasterPlan 1; it is grouped into Phase 3 only for narrative flow. EP-5 (plan 12,
packaging) hard-depends on EP-4 and soft-depends on EP-1/EP-2/EP-3 because the Dhall/env
configuration loader it builds must populate the *fully extended* `ShomeiConfig` — including
the notifier/verification fields from EP-1, the rate-limit/lockout fields from EP-2, and the
log-level/observability fields from EP-3 — so it is most efficient once those fields are
finalized.

EP-6 (plan 13, docs) soft-depends on all five others: it documents their finished behavior.
It carries no hard dependency so a first draft can begin early, but it should be *finalized*
last so `docs/api.md` lists the real endpoints, `docs/deployment.md` describes the real
image and CLI, and `docs/security.md` describes the real lockout/rate-limit defaults.

EP-7 (plan 14, audit log retrieval API and CLI) is a late addition (Phase 4). It carries no
intra-MasterPlan *hard* dependency — it builds on the audit-event table and vocabulary that
already exist — but it *soft*-depends on EP-2, EP-3, and EP-4: EP-3 introduced the audit-event
write stream and the `shomei_auth_events` table EP-7 reads, EP-2 added the abuse-protection
events (`account_locked`, `login_throttled`) that EP-7's filters surface, and EP-4 built the
`shomei-admin` CLI that EP-7 extends with an `audit` subcommand group. Because those three are
already Complete, EP-7 can begin immediately. It also reuses the `ShomeiAPI`/authz seam from
MasterPlan 1's EP-5.

Parallelism summary: after MasterPlan 1 completes, EP-1 and EP-4 can start immediately and
in parallel. Once EP-1 lands, EP-2 and EP-3 run in parallel. EP-5 starts once EP-4 is done
(and is most efficient once EP-1/EP-2/EP-3 are done). EP-6 is finalized last. EP-7 can start
any time after EP-2/EP-3/EP-4 are done (all Complete as of this addition).


## Integration Points

**IP-1 — `Shomei.Effect.Notifier` (the notification/mailer effect).** A new dynamic `effectful`
effect in `shomei-core/src/Shomei/Effect/Notifier.hs` with a smart constructor such
as `sendNotification :: Notification -> Eff es ()`, where `Notification` is a core domain
type (e.g. an `EmailVerificationRequested`/`PasswordResetRequested` sum carrying the
recipient `Email`, a one-time link/token, and an expiry). Owner: **EP-1** (defines the
effect, a `Notification` domain type, an in-memory/list interpreter for tests mirroring
`Shomei.Effect.InMemory`, and a development "log only" interpreter in a `Shomei.Notify`
module inside `shomei-server`). **Shōmei ships no email-sending interpreter:** the effect
*is* the integration seam — an operator forwards the emitted `Notification` to their own
provider (SendGrid, Resend, SES, an SMTP relay, …) by supplying their own interpreter, and a
future `shomei-email` package may package in-tree senders. Consumers: **EP-2** may publish an
account-lockout notification through the same effect. Rule: the effect signature is owned by
EP-1; EP-2 must not change it without a Decision Log entry here.

**IP-2 — New single-use-token domain types.** Email-verification and password-reset tokens
are opaque random tokens of which only the **hash** is persisted (exactly like the existing
refresh tokens in `shomei-core/src/Shomei/Domain/RefreshToken.hs`), single-use,
with a TTL and a status. Owner: **EP-1**, which adds `Shomei.Domain.VerificationToken` and
`Shomei.Domain.PasswordResetToken` (or a unified `Shomei.Domain.OneTimeToken`) plus their
`Shomei.Effect.*Store` effects and an in-memory interpreter, reusing the existing
`Shomei.Effect.TokenGen` (`generateOpaqueToken`/`hashRefreshToken`) for generation and
hashing. No other plan defines these types.

**IP-3 — `ShomeiConfig` extension (shared, append-only).** `ShomeiConfig` lives in
`shomei-core/src/Shomei/Config.hs` (MasterPlan 1's IP-5) and is extended by
multiple plans here: **EP-1** adds notification/verification settings (e.g. an
`emailVerificationRequired` toggle, verification/reset token TTLs, a notifier config);
**EP-2** adds a rate-limit and lockout policy sub-record; **EP-3** adds an observability
sub-record (log level/format, metrics toggle). Owner of the *type* remains `shomei-core`.
Rule, mirroring MasterPlan 1's IP-8 `cabal.project` convention: **each plan adds its own
named sub-record field to `ShomeiConfig` (e.g. `notifierConfig`, `rateLimitConfig`,
`observabilityConfig`) and extends `defaultShomeiConfig` with that field's defaults; no plan
rewrites another's field.** Each new field must be `Maybe` or carry a default so older
config files still parse. EP-5's configuration loader (IP-6) reads the fully-extended record.

**IP-4 — WAI middleware stack in `shomei-server`.** The `Network.Wai.Application` assembled
in `shomei-server` (the `shomei-server` executable from MasterPlan 1 EP-6) gains
middleware from two plans: **EP-2** adds rate-limit/throttling middleware; **EP-3** adds
request-ID, structured-logging, and metrics middleware. Both wrap the same `Application`.
Rule: document and agree the **ordering** — the outermost layer must be EP-3's request-ID +
logging middleware (so every request, including those EP-2 rejects with HTTP 429, is logged
with a correlation ID), then EP-2's rate limiter, then the Servant application. The plan that
lands second must insert its middleware into the existing stack without removing the other's;
record the final order in this section as each lands.

**IP-5 — `ShomeiAPI` route additions.** The Servant `ShomeiAPI` NamedRoutes record in
`shomei-servant` (MasterPlan 1's IP-6) is extended with new endpoints: **EP-1** adds
`POST /auth/verify-email/request`, `POST /auth/verify-email/confirm`,
`POST /auth/password-reset/request`, `POST /auth/password-reset/confirm`, and an
authenticated `POST /auth/password/change`; **EP-3** adds `GET /ready` (readiness, distinct
from the existing liveness `GET /health`) and `GET /metrics` (Prometheus exposition — decide
in EP-3 whether this is a Servant route or raw WAI middleware; default: WAI middleware
mounted before Servant so it need not go through the typed API). Owner of the record:
`shomei-servant`. Rule: each plan adds its routes and corresponding handlers/DTOs; neither
removes the other's; the request/response DTOs follow the existing
`SignupRequest`/`LoginRequest` JSON conventions.

**IP-6 — Configuration loading (Dhall + environment).** A single typed configuration loader,
owned by **EP-5**, that reads a Dhall file and/or environment variables and produces the
fully-extended `ShomeiConfig` (IP-3) plus deployment-only settings (database URL, bind
host/port, signing-key source). The repository already contains a `.seihou/config.dhall`
placeholder; EP-5 decides the on-disk schema and location (e.g. `config/shomei.dhall`).
Consumers: the `shomei-server` executable and the `shomei-admin` CLI (EP-4) should load
configuration the same way, so EP-5's loader must be usable by EP-4's binary; if EP-4 lands
first with a minimal env-only loader, EP-5 supersedes it with the Dhall-backed one and
records the migration in the Decision Log.

**IP-7 — codd migrations and the `shomei` schema.** New PostgreSQL tables added under
`shomei-migrations/sql-migrations/` following the existing timestamped naming
convention (`YYYY-MM-DD-HH-MM-SS-<name>.sql`, see the seven existing files): **EP-1** adds
`shomei_email_verification_tokens` and `shomei_password_reset_tokens`; **EP-2** adds
whatever lockout/login-attempt state it persists (e.g. a `shomei_login_attempts` table or
lockout columns on `shomei_users`). Rule: each plan appends new migration files with
later timestamps; **migrations are immutable and append-only — no plan edits another's
applied migration**; all new tables live in the `shomei` schema and use native `uuid`
identifier columns, `text` status enums, and `timestamptz` timestamps, consistent with
MasterPlan 1's IP-7. EP-2 should choose timestamps later than EP-1's if both land.

**IP-8 — `cabal.project` and new package dependencies.** The workspace manifest at
`cabal.project` (MasterPlan 1's IP-8) gains new dependencies, each plan appending its own
block under the existing "each plan appends its own block; none rewrites another's" comment:
**EP-1** none (no email/SMTP transport — the `Notifier` effect is the seam; see Decision Log);
**EP-2** a rate-limiter or token-bucket library (or none, if
implemented in-process); **EP-3** a Prometheus client and structured-logging libraries;
**EP-4** `optparse-applicative` for the CLI; **EP-5** typically none new. Rule:
no Shōmei package may depend on the deprecated `memory` package (use `ram`), consistent with
MasterPlan 1. Each plan must verify its new dependencies build on GHC 9.12.4 inside
`nix develop` and add any required `allow-newer` entry in its own block. If EP-4's CLI is a
new executable, decide its home (default: a `shomei-admin` executable stanza inside the
existing `shomei-server` package, avoiding a new mori.dhall package registration —
see Decision Log); if a new `shomei-cli`/`shomei-notify` package is introduced instead,
register it in `mori.dhall` as MasterPlan 1 EP-3 did for `shomei-migrations`.

**IP-9 — Audit-event read layer over the shared effect stacks.** **EP-7** adds the *read*
counterpart to EP-3's write-only audit-event stream: a new `effectful` effect
`Shomei.Effect.AuthEventReader` in `shomei-core` and its PostgreSQL interpreter
`Shomei.Postgres.AuthEventReader.runAuthEventReaderPostgres`, both consuming the
`shomei_auth_events` table and the `AuthEvent` vocabulary (`shomei-core/src/Shomei/Domain/Event.hs`)
that EP-3 (write path) and EP-2 (lockout/throttle events) populate. No schema change and no new
migration: EP-7 is read-only (`SELECT`/`COUNT` only) and the table is append-only. The concrete
integration surface is the set of shared effect-stack lists that already enumerate
`AuthEventPublisher`: `Shomei.Servant.Seam.AppEffects`, the server's `runAppIO` interpreter
chain in `Shomei.Server.App`, and the `shomei-postgres` test `AppEffects`. **Rule: EP-7 adds
exactly one entry (`AuthEventReader`) plus its interpreter to each such list/chain, mirroring
`AuthEventPublisher`; it must not reorder or remove existing entries.** EP-7 also extends two
MasterPlan-1 surfaces: the `ShomeiAPI` NamedRoutes record (IP-5 convention) with an admin-gated
`GET /admin/audit/events` route, and the EP-4 `shomei-admin` CLI with an `audit` subcommand
group. Known limitation recorded in EP-7's Decision Log: the HTTP route is gated by
`requireRole (Role "admin")`, but no production flow yet issues the `admin` role, so the CLI is
the working operator retrieval path and the API is verified via tokens minted in tests.


## Progress

Milestone-level tracking across all child plans. Updated as each plan's milestones land.

- [x] EP-1: `Notifier` effect + dev-log sender done; verification/reset token types, stores, and migrations done. **Email sending descoped (2026-06-17)** — Shōmei emits notifications via the `Notifier` effect and ships only the log sender; delivery is the operator's concern. EP-1 is Complete.
- [x] EP-1: email-verification and password-reset/change workflows pass pure in-memory tests
- [x] EP-1: new `ShomeiAPI` routes + handlers pass in-process lifecycle HTTP tests
- [x] EP-1: new `ShomeiAPI` routes + handlers; `curl` walkthrough of verify-email and password-reset against the live server (2026-06-10, log-only notifier)
- [x] EP-2: rate-limit + lockout policy in `ShomeiConfig`; per-IP/per-account login throttling in the workflow plus the per-IP request-rate WAI middleware (`Shomei.Server.Middleware.RateLimit`). 120-req burst → ~58 `429`s before Servant (2026-06-10).
- [x] EP-2: account lockout after N failed logins with generic responses; pure + PostgreSQL integration tests pass (`cabal test all` green, 2026-06-10)
- [x] EP-3: structured JSON logging + request correlation IDs (X-Request-Id echo, no secrets); graceful shutdown on SIGTERM/SIGINT (2026-06-10)
- [x] EP-3: Prometheus `/metrics` (HTTP + domain counters, hand-rolled) and `/ready` readiness probe distinct from `/health` (2026-06-10)
- [x] EP-4: `shomei-admin` CLI runs migrations and creates a bootstrap user (live runbook, 2026-06-10)
- [x] EP-4: signing-key generate → activate → retire → revoke lifecycle; JWKS reflects overlapping keys during rotation (integration test proves retired-key tokens still verify, revoked ones don't)
- [x] EP-5: typed Dhall/env config loader assembles the fully-extended `ShomeiConfig` (via `dhall-to-json` + aeson; test green, 2026-06-10)
- [~] EP-5: production OCI image (`flake.module.nix`) + CI workflow authored; image build NOT run in the dev sandbox (deferred to CI/deploy host). Local dev/test stack is `process-compose up --no-server` (Unix-socket PostgreSQL + schema + key bootstrap + server) — `docker compose` was dropped 2026-06-17 (see Decision Log). **Verified live end-to-end 2026-06-17**: clean `process-compose up --no-server` brings the stack to `/ready` 200 (`database:true, signingKey:true`), JWKS serves the active key, signup→login returns an ES256 token, `/metrics` exports counters, and SIGINT drains gracefully. Three regressions in the committed `process-compose.yaml` were found and fixed during this verification (see Surprises & Discoveries, 2026-06-17).
- [x] EP-6: `docs/{architecture,api,security,deployment}.md` + getting-started `README.md` written, grounded in the finished EP-1..EP-5 surface (2026-06-10)
- [x] EP-7: read/query layer — `Shomei.Effect.AuthEventReader` effect + `runAuthEventReaderPostgres` interpreter (filtered, keyset-paginated reads over `shomei_auth_events`) + `Shomei.Domain.EventCodec.reconstructAuthEvent`/`projectAuthEvent` (round-trip spec pins all 24 constructors; interpreter test green, 2026-06-17)
- [x] EP-7: admin-gated `GET /admin/audit/events` HTTP endpoint with filters + keyset pagination (admin token → 200, non-admin → 403, no token → 401, bad UUID → 400); in-memory `AuthEventReader` added so the servant e2e test interprets the effect
- [x] EP-7: `shomei-admin audit` subcommand group (`events`/`user`/`session`/`count`, tab-separated + `--json` NDJSON); integration-tested + live-verified against the dev socket Postgres (2026-06-17)
- [x] EP-7: docs + runbook — `docs/security.md` (runbook + admin-role limitation), `docs/api.md`, and a forward note in EP-3's plan. **EP-7 is Complete.**


## Surprises & Discoveries

Cross-plan insights, dependency changes, and scope adjustments discovered during
implementation. Provide concise evidence.

- **2026-06-17 — live verification of the `process-compose` local stack surfaced three
  regressions in the committed `process-compose.yaml` (commit `1224ca7`), now fixed.** When the
  stack was first run end-to-end it did not boot; each failure was a distinct bug:
  1. **Port 8080 collision.** The new `shomei-server` process binds `SHOMEI_PORT=8080`, but
     process-compose's *own* REST API also defaults to TCP 8080 and **aborts** (`FTL start http
     server on localhost:8080 failed … address already in use`) rather than relocating. In a clean
     environment process-compose grabs 8080 first, so the server can never bind it. Fix (per user
     decision): document/launch the stack as `process-compose up --no-server`, which frees 8080
     (control via the foreground TUI; `process-compose down` from another shell is unavailable
     with `--no-server`).
  2. **`bootstrap_keys` env-var mismatch.** `shomei-admin` requires `DATABASE_URL`
     (`Shomei.Admin.Env.loadAdminEnv`), but the Nix dev shell exports only `PG_CONNECTION_STRING`
     (which `shomei-server` reads directly, `Shomei.Server.Config`). The key-bootstrap step died
     with `user error (DATABASE_URL is not set)`, so `shomei-server` (gated on it) never started.
     Fix (in-scope, local stack only): the `bootstrap_keys` step now bridges
     `export DATABASE_URL="$PG_CONNECTION_STRING"`. **Root-cause follow-up recommended** (not done
     here, out of the process-compose scope): make `shomei-admin` read `PG_CONNECTION_STRING`
     (falling back to `DATABASE_URL`) so the admin CLI and server share one DB var — this would
     also let the production container (`deploy/entrypoint.sh`) and `docs/deployment.md` stop
     requiring operators to set both vars to the same value.
  3. **Ambiguous `cabal run shomei-server`.** Since EP-4 added the `shomei-admin` executable to the
     `shomei-server` package, `cabal run shomei-server` resolves to the *package* (two exes) and
     fails with `Cabal-7070`. Fix: `cabal run exe:shomei-server`. The same stale invocation existed
     in `README.md` and `docs/deployment.md` and was corrected.
  All three fixes are config/doc-only (no Haskell changed); the stack now boots cleanly and was
  verified live (`/ready`, JWKS, signup→login ES256 token, `/metrics`, graceful SIGINT shutdown).

- **2026-06-17 — EP-7: the `AuthEvent` vocabulary grew 16 → 24, and the event→envelope
  projection is now shared.** EP-7 was authored against a 16-constructor `AuthEvent`, but
  MasterPlan-3 work (passkeys, MFA, impersonation) had since added 8 more
  (`passkey_registered`/`removed`, `mfa_challenged`/`succeeded`/`failed`,
  `impersonation_started`/`stopped`/`action_blocked`). EP-7's `reconstructAuthEvent` handles all
  24, guarded by a count assertion in the round-trip spec. To avoid duplicating the
  constructor→`event_type` mapping between the writer and EP-7's in-memory reader, the projection
  was **hoisted** from `Shomei.Postgres.AuthEventPublisher` into
  `Shomei.Domain.EventCodec.projectAuthEvent` (core) as the single source of truth; the writer now
  delegates to it. Anyone touching the audit-event write path should change `projectAuthEvent` in
  `shomei-core`, not the postgres writer. Additive, no migration, `event_type` strings unchanged;
  `cabal test all` green.

The following were surfaced while authoring the child plans (2026-06-04), before any
implementation, by reading the real `shomei-core`/`shomei-postgres` source. They are
recorded here because they cross plan boundaries or touch MasterPlan-1-owned artifacts.

- **EP-1 must extend a MasterPlan-1-owned effect (`RefreshTokenStore`).** The password-reset
  flow needs to revoke *all of a user's* refresh tokens, but the existing
  `Shomei.Effect.RefreshTokenStore` (MasterPlan 1, IP-3) only offers
  `revokeSessionRefreshTokens` (per session). EP-1's plan adds a
  `revokeAllUserRefreshTokens` operation to that effect and updates both the in-memory and
  the PostgreSQL interpreters. This is a change to a MasterPlan-1-owned effect signature;
  it is additive (no existing caller breaks) and is documented in EP-1's Decision Log.
  Anyone tracking the store-effect surface (EP-2/EP-3) should know the effect grew one
  operation. (`SessionStore.revokeAllUserSessions` already exists and is reused as-is.)

- **EP-4 needs a JWKS read the `SigningKeyStore` effect does not provide.** During key
  rotation the published JWKS must list both the `active` and the still-trusted `retired`
  keys so previously-issued tokens keep verifying, but
  `Shomei.Effect.SigningKeyStore`'s `listActiveSigningKeys` interpreter filters
  `WHERE status = 'active'`. Rather than widen the shared effect, EP-4's `shomei-admin` adds
  a binary-local `listPublishableSigningKeys` hasql read (`WHERE status IN
  ('active','retired')`). EP-4 also deliberately does **not** reuse `shomei-jwt`'s
  MasterPlan-1 `rotateSigningKey` (which inserts new keys directly as `active` with no
  `pending` staging); the CLI drives `SigningKeyStore` operations directly to realize the
  fuller `pending → active → retired → revoked` lifecycle, reusing only the key-generation
  and `StoredSigningKey` conversion from `shomei-jwt`. Recorded in EP-4's Decision Log.

- **IP-7 migration timestamps are coordinated.** EP-1 dates its new migrations
  `2026-06-04-*` (later than the seven existing `2026-06-03-*` files); EP-2 dates its
  lockout/attempt migrations `2026-06-05-*` to stay strictly later than EP-1's. If the
  plans land out of this order, the later-landing plan must bump its timestamps so codd
  applies migrations in a stable, append-only order.

- **IP-6 config-loader handoff is concrete.** MasterPlan 1's EP-6 creates a
  `Shomei.Server.Config` module with an env-only loader. EP-4 ships a minimal env-var
  loader (`DATABASE_URL`/issuer/audience) as a single stable entry point; EP-5 supersedes
  it in place with the typed Dhall+env loader, widening it to populate the fully-extended
  `ShomeiConfig` and the deployment settings, without touching any CLI subcommand. Both
  plans record the supersession in their Decision Logs.

- **IP-4 middleware order resolved.** Both EP-2 and EP-3 are written to compose as:
  outermost `request-id + structured logging` (EP-3) → `http metrics` (EP-3) → `rate
  limiter` (EP-2) → Servant app, so even a 429 from EP-2 is logged with a correlation id.
  `GET /metrics` is raw WAI middleware (EP-3) bypassing the typed API; `GET /ready` is a
  typed `ShomeiAPI` route. Whichever of EP-2/EP-3 lands second inserts its middleware
  without removing the other's and records the realized order in the server assembly.

- **2026-06-04 layout/module audit.** The repository no longer has a nested package directory:
  the Cabal packages are top-level directories and `mori show --full` reports those paths.
  The core effect interfaces no longer live under the old Port namespace; their public modules are
  `Shomei.Effect.*`. This audit updated the MasterPlan and child ExecPlans 8-13 to use the
  current paths and module names. A second audit finding affects EP-5: `Shomei.Server.Config`
  already exists as an environment-only loader with `loadConfig :: IO (ShomeiConfig,
  ServerSettings)`, so EP-5 must extend that module in place rather than authoring it from
  scratch. The child packaging plan now says "extend" and explicitly preserves existing
  exports used by `Shomei.Server.Boot`, the executable, and tests.

- **2026-06-04 migration embedding requires a source rebuild.** During EP-1 M2, adding new
  `.sql` files and touching `shomei-migrations/shomei-migrations.cabal` was not enough for
  the PostgreSQL test run to see the new migrations; the embedded migration list still
  reported seven files. A small source change to `shomei-migrations/src/Shomei/Migrations.hs`
  forced the `embedDir` Template Haskell splice to re-run, after which codd reported 10
  migrations and applied the three `2026-06-04-*` files. Later plans that append migrations
  should make sure this module actually recompiles before trusting tests or `just migrate`.

- **2026-06-04 EP-1 SMTP dependency was unresolved — SUPERSEDED 2026-06-17 by descoping email
  sending entirely.** `mori registry search smtp`, `mori registry search HaskellNet`, and
  `mori registry search mime-mail` returned no registered SMTP/email package to audit, so EP-1
  kept the SMTP path log-backed. On 2026-06-17 the user decided Shōmei should **not** be
  responsible for sending email at all: the `Notifier` effect is the integration seam,
  operators forward the emitted `Notification` to their own provider, and a future
  `shomei-email` package may add in-tree senders. The vestigial `SmtpNotifier` transport and
  `runNotifierSmtp` stub were removed from the code (`Shomei.Config.NotifierTransport =
  LogNotifier` is the sole built-in; `Shomei.Notify` exposes only `runNotifierLog`). This
  removes the block — EP-1 is now Complete. See the Decision Log.


## Decision Log

- Decision: Author MasterPlan 2 now, ahead of MasterPlan 1's completion, scoped to
  post-bootstrap productionization rather than the runnable vertical slice.
  Rationale: The user asked to stage the "next" master plan while MasterPlan 1 remains the
  active work. "Make Shōmei usable" splits into two distinct meanings: the runnable slice
  (already decomposed as MasterPlan 1's unstarted EP-4–EP-7) and production/operator/adopter
  readiness (this plan). To avoid duplicating MasterPlan 1's EP-4–EP-7, this plan is strictly
  post-bootstrap and hard-depends on MasterPlan 1 being Complete. Scope confirmed with the
  user as production hardening & ops, account flows, and docs/adoption — explicitly excluding
  advanced/federated auth (OAuth/OIDC/MFA/magic links), which stays deferred.
  Date: 2026-06-04

- Decision: Decompose into six ExecPlans across four phases (Account Lifecycle → Hardening &
  Observability [parallel] → Operations → Adoption), with the only hard intra-plan dependency
  being EP-5 (packaging) on EP-4 (CLI).
  Rationale: Boundaries follow functional concern and package layering; each plan is an
  independently demonstrable behavior (new endpoint, metric, CLI command, bootable image, or
  document). Alternatives (three mega-plans; merging CLI into packaging; splitting
  verification from reset) rejected — see Decomposition Strategy.
  Date: 2026-06-04

- Decision: Account-lifecycle notifications go through a new `Shomei.Effect.Notifier` effect
  with a development log-only sender; the toolkit bakes in no specific email provider.
  (Originally this decision also called for a production SMTP sender — **superseded
  2026-06-17**, see the next entry.)
  Rationale: Preserves the transport-agnostic-core principle (the core defines the effect; only
  a sender adapter knows a transport), mirrors the existing store-effect pattern, and keeps the
  dev experience friction-free (logs the link instead of sending mail).
  Date: 2026-06-04

- Decision: **Shōmei does not send email. Descope the production SMTP sender entirely.** The
  `Shomei.Effect.Notifier` effect is the sole integration seam: the toolkit emits a
  `Notification` (recipient, one-time link/token, expiry) and ships exactly one built-in
  interpreter — `runNotifierLog`, which writes the link to the server log
  (`NotifierTransport = LogNotifier` is now the only constructor). Delivering the message is
  the operator's responsibility, satisfied by supplying their own `Notifier` interpreter that
  forwards the `Notification` to their existing provider. If in-tree senders are ever wanted,
  they belong in a separate `shomei-email` package, not in `shomei-core`/`shomei-server`.
  Rationale: Sending email is an operator concern — virtually every deployment already has a
  provider (SendGrid, Resend, SES, an SMTP relay). Baking a transport into the toolkit adds an
  unaudited dependency, a TLS/secrets surface, and ongoing maintenance for no real benefit,
  and it conflicts with the dependency-lookup rule (no vetted SMTP package is registered in
  `mori`). Shōmei's responsibility ends at emitting the notification. This change removes
  EP-1's only remaining (externally blocked) task, so **EP-1 is now Complete**. Code impact
  (verified `cabal build all` + `cabal test all` green, fourmolu clean): dropped `SmtpNotifier`
  and `runNotifierSmtp`; the Dhall/env loader never wired SMTP fields, so no config change was
  needed.
  Date: 2026-06-17

- Decision: Default the operational CLI to a `shomei-admin` executable stanza inside the
  existing `shomei-server` package rather than a new package.
  Rationale: Avoids registering an eighth package in `mori.dhall` and lets the CLI reuse the
  server's assembly code (pool, key store, config loader). EP-4 may override this and create a
  dedicated `shomei-cli` package if assembly coupling proves awkward, recording the change in
  its own Decision Log and registering the package in `mori.dhall` as MasterPlan 1 EP-3 did
  for `shomei-migrations`.
  Date: 2026-06-04

- Decision: Back rate-limiting and account-lockout state with PostgreSQL and in-process
  structures only; no distributed (Redis) store.
  Rationale: This plan targets a single-instance container deployment, for which
  PostgreSQL-backed and in-process state is sufficient and avoids a new infrastructure
  dependency. The distributed/multi-instance story is noted as a future concern in Vision &
  Scope.
  Date: 2026-06-04

- Decision: Update MasterPlan 2 and its child ExecPlans for the 2026-06-04 package-layout
  and module-namespace refactor.
  Rationale: The project is a Haskell multi-package workspace, not organized around a
  nested package tree. The package directories now live at the repository root, and the
  transport-agnostic effect interfaces formerly exposed under the old Port namespace are now
  exposed under `Shomei.Effect.*`. Plans must point future implementers at the current
  source tree and use the current module names.
  Date: 2026-06-04

- Decision: Keep `shomei-admin` inside the top-level `shomei-server` package unless EP-4
  proves a separate package is necessary.
  Rationale: The earlier decision remains valid, but references to the previous
  `shomei-server` path were stale after the layout refactor. A new package would require a new top-level
  directory and a `mori.dhall` package entry.
  Date: 2026-06-04

- Decision: Add **EP-7 (Audit log retrieval API and CLI)** as a seventh child plan (Phase 4),
  delivered as a single ExecPlan rather than a new MasterPlan or a multi-plan decomposition.
  Rationale: The user asked for a retrieval surface (CLI + API) over the existing audit-event
  trail. The work is one shared read/query layer (`AuthEventReader` effect + PostgreSQL
  interpreter) with two thin surfaces on top; coordination is trivially linear (foundation,
  then two independent leaves), which the MasterPlan spec identifies as the signature of a
  single ExecPlan, not a MasterPlan ("a MasterPlan adds value only when coordination across
  plans is the hard problem"). It slots under MasterPlan 2 because it extends the same
  operator/production theme and reuses EP-3's audit-event stream (IP-9), EP-4's `shomei-admin`
  CLI, and EP-5/MasterPlan-1's `ShomeiAPI` seam. It soft-depends on EP-2/EP-3/EP-4 (all
  Complete), so it can begin immediately and is read-only (no migration).
  Date: 2026-06-17

- Decision: EP-7's HTTP endpoint is gated by the existing `requireRole (Role "admin")` guard,
  and EP-7 does NOT add a flow to grant the `admin` role; the CLI is the working operator
  retrieval path.
  Rationale: Shōmei's login/signup workflows do not issue roles in tokens, so no production
  path yields an admin token today. Gating the endpoint correctly now keeps it safe and ready
  the moment a role-granting mechanism exists (a natural follow-up); meanwhile the trusted-CLI
  path (direct pool access) fully serves operators. The limitation is documented for operators
  in EP-7 M4 and recorded in IP-9.
  Date: 2026-06-17

- Decision: **Local development and testing use `process-compose` + a Unix-socket PostgreSQL,
  not `docker compose`.** EP-5's earlier `docker-compose.yaml` "one-command local stack" was
  removed; the local stack is now `process-compose up` from inside the Nix dev shell, bringing
  up a socket-only PostgreSQL (`pg_ctl … --unix_socket_directories='$PGHOST'`,
  `listen_addresses=''`), then `just create-database` (createdb + migrate), then an
  active-signing-key bootstrap, then `cabal run shomei-server` on `http://localhost:8080`. The
  **production** OCI image (`nix build .#dockerImage` via `flake.module.nix`) and the plain
  `Dockerfile` are **retained unchanged** as the deployment artifact; only `docker compose` is
  gone.
  Rationale: Every other service in the project already runs locally this way — the Nix dev
  shell (`nix/haskell.nix`) provisions the socket Postgres and exports
  `PGHOST`/`PGDATA`/`PGDATABASE`/`PG_CONNECTION_STRING`, `.seihou/config.dhall` sets
  `nix.process-compose = "true"`, and both `process-compose.yaml` and
  `examples/microservice-auth-stack/process-compose.yaml` use it. `docker compose` was the odd
  one out. A Unix socket binds no TCP port, so the local database never conflicts with another
  Postgres on the machine; and local dev/test needs no built container image, shortening the
  loop. This is a change to EP-5's M3 design only; it touches no auth semantics. The change
  cascades to EP-5 (`docs/plans/12-…`, M3 rewritten) and EP-6 (`docs/plans/13-…`, quickstart/
  runbook retargeted), plus the committed setup (`process-compose.yaml` extended; `docs/
  deployment.md`, `README.md`, `CHANGELOG.md`, `flake.module.nix` updated; `docker-compose.yaml`
  deleted).
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare
the result against the original vision.

### 2026-06-17 — EP-7 (audit log retrieval) Complete

EP-7 is delivered and **Complete**. The append-only audit trail (`shomei_auth_events`) is now
readable through one shared query layer — `Shomei.Effect.AuthEventReader` + its PostgreSQL
interpreter (filtered, keyset-paginated, read-only) — with two thin surfaces: the admin-gated
`GET /admin/audit/events` HTTP endpoint and the `shomei-admin audit events|user|session|count`
CLI (tab-separated + `--json`). A pure round-trip spec pins all 24 `AuthEvent` constructors;
the event→envelope projection was hoisted to `Shomei.Domain.EventCodec` as a single source of
truth (writer + in-memory reader + test share it). Read-only: no schema migration. `cabal build
all` / `cabal test all` green (core, postgres, servant, admin suites), fourmolu clean.
Known limitation (documented): the HTTP endpoint's `admin` role has no production grant path yet,
so the CLI is the working operator path; a role-granting mechanism is the natural follow-up. With
EP-7 done, the **only** item left to fully close MasterPlan 2 is EP-5's live container
build/verification on a Nix+Docker host.

### 2026-06-17 — Email-sending descoped; EP-1 Complete

The user decided Shōmei should not be responsible for sending email. EP-1's only outstanding
item — a production SMTP sender, externally blocked on a vetted `mori`-registered dependency —
was **descoped** rather than implemented: the `Notifier` effect is the integration seam and
operators wire delivery to their own provider (a future `shomei-email` package may add in-tree
senders). The vestigial `SmtpNotifier`/`runNotifierSmtp` code was removed; `cabal build all`,
`cabal test all` (incl. PostgreSQL integration + live client round-trip) are green and fourmolu
is clean. **EP-1 is now Complete.** (At the time this was written, EP-5's live container
build/verification and the newly-added EP-7 remained; EP-7 was completed later the same day —
see the entry above.) See the Decision Log entry of the same date.

### 2026-06-10 — MasterPlan 2 implementation retrospective

> Note (2026-06-17): superseded in part — EP-1 is now Complete (email sending descoped, above).

Against the original Vision & Scope, the initiative is **substantially delivered**: five of six
child plans are Complete and the sixth (EP-5 packaging) is Complete except for live container
verification.

- **EP-1 — Account lifecycle.** Functionally complete and live-`curl`-verified (signup →
  verify-email → password-reset with generic non-leaking 202s → session revocation → old refresh
  rejected). The original gap was the *production SMTP sender*; on 2026-06-17 email sending was
  descoped (Shōmei emits notifications; operators deliver them), so EP-1 is now **Complete**.
- **EP-2 — Abuse protection.** Complete: per-account lockout, per-IP failure throttle, and a
  per-IP request-rate WAI token bucket, all proven live (6-login lockout returns a generic 401;
  a 120-request burst yields ~58 429s).
- **EP-3 — Observability.** Complete: structured JSON logs with correlation ids (no secrets),
  hand-rolled Prometheus `/metrics`, `/ready` vs `/health`, and graceful shutdown — all
  demonstrated live.
- **EP-4 — Operational CLI + key rotation.** Complete: `shomei-admin` runbook verified live; the
  zero-downtime `pending → active → retired → revoked` lifecycle proven by a JWKS-overlap
  integration test.
- **EP-5 — Packaging/config/deployment.** Config loader (typed Dhall + env, IP-6) done and
  verified; CI workflow, production OCI image (`flake.module.nix`), entrypoint, and `Dockerfile`
  authored and syntax-validated; the local dev/test stack is `process-compose up` (Unix-socket
  PostgreSQL + schema + key bootstrap + server), replacing the dropped `docker compose` design.
  **Remaining:** a live `nix build .#dockerImage` was not run in the development sandbox (needs a
  Nix+Docker build host).
- **EP-6 — Docs.** Complete: `README.md` and `docs/{architecture,api,security,deployment}.md`
  written against the finished surface.

**Engineering verification.** `cabal build all` and `cabal test all` are green across all
packages (core 21, postgres 16, jwt 9, servant, server, client, admin, server-config, plus the
two example suites); `nix fmt` is clean. Notable deviations, each recorded in the relevant
ExecPlan's Decision Log: metrics and the Dhall loader were hand-rolled / CLI-bridged rather than
pulling unregistered heavy Hackage libraries (`prometheus-client`, `dhall`); per-account vs
per-IP failure counting is asymmetric (success resets the account counter, not the IP one).

**Outstanding work** to call MasterPlan 2 fully closed: (1) build the EP-5 production OCI image
(`nix build .#dockerImage`) on a Nix+Docker host and capture the transcript (the local dev/test
stack now runs via `process-compose` + a Unix-socket PostgreSQL and needs no image); (2) deliver
EP-7 (audit log retrieval API and CLI), Not Started. (EP-1's former SMTP item was descoped on
2026-06-17 — Shōmei does not send email; see the Decision Log.)

- 2026-06-04: EP-1 M3 is complete and M4 is partially complete. The servant API now exposes
  the verify-email, password-reset, and password-change routes, and the server assembly wires
  the PostgreSQL token stores plus config-selected notifier interpreter. The in-process HTTP
  suite covers signup, email verification, password reset, login, refresh, JWKS, and role
  checks; `nix develop --command cabal test all` passes. Remaining EP-1 work is a real SMTP
  sender and the live-server `curl` walkthrough.

- 2026-06-10: **EP-5 (packaging/config/deployment) is partially complete (In Progress).**
  M1 (the typed Dhall + env configuration loader, IP-6) is **done and verified**: it renders the
  Dhall file with the `dhall-to-json` CLI and decodes it with aeson into the fully-extended
  `ShomeiConfig` (a deliberate deviation from the heavy `dhall` Haskell library — see EP-5's
  Decision Log), with env vars overriding file values; a test proves it. M4 (CI workflow) and the
  production deployment artifacts (OCI image in `flake.module.nix`, `entrypoint.sh`, `Dockerfile`,
  `CHANGELOG.md`) are **authored and syntax-validated** but the OCI image build was **not run in
  the development sandbox** (it needs a Nix+Docker build host; documented honestly rather than
  claimed). The local dev/test stack is `process-compose up` (Unix-socket PostgreSQL + schema +
  key bootstrap + server); the original `docker-compose.yaml` was dropped 2026-06-17 (see the
  Decision Log). The flake still evaluates and `nix develop` works. **Handoff to EP-6:**
  `docs/deployment.md` should document the Dhall config schema, the
  `SHOMEI_CONFIG`/`PG_CONNECTION_STRING` precedence, the `process-compose up` local stack, the
  `nix build .#dockerImage` production flow, and that the live container verification is pending.

- 2026-06-10: **EP-4 (operational CLI + key rotation) is Complete.** The `shomei-admin` binary
  (a second executable in `shomei-server`, per the default decision — no new `mori.dhall`
  package) provides `migrate`, `keys generate/activate/retire/revoke/list`, and `users create`.
  The signing-key rotation lifecycle (`pending → active → retired → revoked`) is proven with a
  JWKS-overlap integration test: a token signed by an auto-retired key still verifies during the
  grace window and stops verifying once revoked. **Hard dependency for EP-5 is now satisfied** —
  EP-5's container entrypoint can run `shomei-admin migrate` and ensure an active key via
  `shomei-admin keys generate`/`activate`. **Handoff to EP-5 (IP-6):** `Shomei.Admin.Env.loadAdminEnv`
  is the single env-only config entry point EP-5's typed Dhall/env loader should supersede in
  place; `optparse-applicative` was added (resolves from Hackage, no override needed).

- 2026-06-10: **EP-3 (observability) is Complete.** The server now emits one structured JSON
  log line per request with a correlation id (generated or echoed from `X-Request-Id`, returned
  in the response header) and never logs a secret; serves a Prometheus `GET /metrics` (HTTP
  counters/gauge/histogram + `shomei_logins_succeeded/failed_total` and
  `shomei_tokens_issued_total`); serves `GET /ready` (200 when the DB is reachable and an active
  signing key exists, 503 otherwise) distinct from liveness `GET /health`; and shuts down
  gracefully on SIGTERM/SIGINT (drain → close pool → exit 0). **Cross-plan notes:** (1) EP-3
  added an `observabilityConfig` sub-record to `ShomeiConfig` and a `ready` route + `ReadyResponse`
  DTO to `ShomeiAPI` (EP-6 docs must list `/ready` and `/metrics`; EP-6's `docs/api.md` should
  note `/metrics` is raw WAI, not in the typed client). (2) The **realized IP-4 order** is
  `logging → http-metrics → /metrics-endpoint → rate-limiter (EP-2) → app`. (3) EP-3 added **no
  new external dependency** — logging and metrics are hand-rolled (rationale in EP-3's Decision
  Log: `prometheus-client` is not registered in `mori`); EP-5's Dhall/env loader (IP-6) must
  populate the new `observabilityConfig` fields (`logFormat`, `requestLoggingEnabled`,
  `metricsEnabled`, `gracefulShutdownTimeoutSeconds`).

- 2026-06-10: **EP-2 (abuse protection) is Complete.** The three protections are live and
  demonstrable: per-account brute-force lockout (locks after 5 failures, generic `401`
  indistinguishable from a wrong password, PostgreSQL-backed), a per-IP failure throttle
  (`429`), and a per-IP request-rate WAI token bucket (a 120-request burst yields ~58 `429`s
  before reaching Servant). `cabal build all` / `cabal test all` green. **Cross-plan note for
  EP-3:** EP-2 landed the WAI middleware **first**, so the realized IP-4 stack in
  `Shomei.Server.Boot.main` is `rateLimitMiddleware rl (application env)` — EP-3 must insert
  its request-id + structured-logging middleware **outside** the rate limiter (wrapping that
  whole expression) so even a `429` is logged with a correlation id, without removing the
  limiter. EP-2 also added `LoginAttemptStore` to both the seam and server `AppEffects` and the
  `login` workflow now takes a `ClientContext` (anyone re-deriving the effect stack or calling
  `login` directly must account for both). The optional account-lockout `Notifier` integration
  (IP-1) was left unwired (audit event only) and can be added later without changing the
  effect signature.

- 2026-06-10: EP-1's live `curl` walkthrough (M4.4) is **done** and is the headline acceptance
  for the account-lifecycle theme. Against the dev PostgreSQL with the default log-only
  notifier, the full sequence was demonstrated end-to-end: signup → verify-email request (link
  logged) → confirm (sets `email_verified_at`) → password-reset request returning a generic
  `202` for both a registered and an unknown email with a reset link logged **only** for the
  registered one → confirm (changes the password and revokes all sessions) → the pre-reset
  refresh token rejected with `401` → login with the new password succeeds and the old password
  fails. Discovery worth propagating to EP-3/EP-6: all four lifecycle endpoints (request **and**
  confirm) return `202 Accepted` with a `NoContent` body — a uniform "accepted" status, not the
  `200` the EP-1 prose originally implied; `docs/api.md` (EP-6) must document `202` for these
  routes. (Historical: EP-1 stayed **In Progress** at the time solely because the *production
  SMTP sender* (M4.1b/M4.3) was blocked on a vetted `mori`-registered dependency. **Superseded
  2026-06-17:** email sending was descoped — Shōmei emits notifications via the `Notifier`
  effect and operators deliver them — and the `SmtpNotifier` path was removed. All EP-1
  user-visible behaviour was already delivered, so EP-1 is now **Complete**. The descoping
  blocked nothing downstream; EP-2 only needs the `Notifier` effect, which exists.)


## Revision Notes

2026-06-04: Updated this MasterPlan after the package-layout refactor. The package paths now
refer to top-level directories, the effect interfaces now use
the `Shomei.Effect.*` namespace, and the global precondition now reflects that MasterPlan 1's
vertical slice is implemented and passing `cabal build all` / `cabal test all`.

2026-06-17: Added **EP-7 (Audit log retrieval API and CLI)**, `docs/plans/14-audit-log-retrieval-api-and-cli.md`,
as a seventh child plan (Phase 4, status Not Started). It delivers the read counterpart to
EP-3's write-only audit-event stream: a shared `AuthEventReader` query layer over
`shomei_auth_events`, an admin-gated `GET /admin/audit/events` HTTP endpoint, and a
`shomei-admin audit` CLI subcommand group. Why: the user requested a retrieval surface (CLI +
API) for major-event audit logs, which until now could only be read with hand-written SQL.
The addition updates the Exec-Plan Registry (new row 7), the Dependency Graph (EP-7
soft-depends on the already-Complete EP-2/EP-3/EP-4), Integration Points (new **IP-9** for the
read layer over the shared effect stacks), Progress (four new EP-7 items), and the Decision
Log (single-ExecPlan decomposition rationale and the admin-role gating limitation). EP-7 is
read-only and requires no schema migration.

2026-06-17: **Descoped email sending from EP-1 and marked EP-1 Complete.** Per the user's
decision, Shōmei is no longer responsible for delivering email — the `Shomei.Effect.Notifier`
effect is the integration seam, the toolkit ships only the dev log-only sender, and operators
forward the emitted `Notification` to their own provider (SendGrid, Resend, SES, an SMTP relay,
…); a future `shomei-email` package may add in-tree senders. This removed EP-1's only remaining
(externally blocked) task. The change updates Vision & Scope (account-lifecycle paragraph,
in/out-of-scope), Decomposition Phase 1, the Exec-Plan Registry (EP-1 → Complete), IP-1
(no SMTP interpreter), IP-8 (EP-1 adds no email library), Progress, Surprises (the SMTP-blocker
entry superseded), the Decision Log (original notifier decision annotated + a new descoping
decision), and Outcomes & Retrospective. Code impact: removed the `SmtpNotifier` transport and
`runNotifierSmtp`; `cabal build all` / `cabal test all` green, fourmolu clean. EP-1's child plan
(`docs/plans/8-…`) is updated in lockstep.

2026-06-17: **Implemented EP-7 (audit log retrieval API and CLI) end-to-end; marked it Complete.**
Delivered across four milestones: the shared `Shomei.Effect.AuthEventReader` query layer +
`runAuthEventReaderPostgres` interpreter + `Shomei.Domain.EventCodec`
(`reconstructAuthEvent`/`projectAuthEvent`); the admin-gated `GET /admin/audit/events` endpoint;
the `shomei-admin audit` subcommand group; and docs (`docs/security.md` runbook + limitation,
`docs/api.md`, a forward note in EP-3's plan). The update ticks the Exec-Plan Registry (EP-7 →
Complete), all four EP-7 Progress items, adds a Surprises entry (the `AuthEvent` vocabulary grew
16 → 24 and the event→envelope projection was hoisted to `shomei-core` as a single source of
truth), and adds an Outcomes entry. Read-only — no schema migration. `cabal build all` /
`cabal test all` green, fourmolu clean. The child plan
(`docs/plans/14-audit-log-retrieval-api-and-cli.md`) records the full per-milestone detail.

2026-06-17: **Dropped `docker compose`; local development/testing now uses `process-compose` +
a Unix-socket PostgreSQL.** Per the user's decision, the local dev/test stack matches the
project-wide pattern (the Nix dev shell provisions a socket-only PostgreSQL and exports
`PGHOST`/`PGDATA`/`PGDATABASE`/`PG_CONNECTION_STRING`; `process-compose.yaml` and the example
service already use it). A Unix-domain socket binds no TCP port, so the local database never
conflicts with another Postgres on the machine. EP-5's earlier `docker-compose.yaml` "one-command
local stack" was removed; the local stack is now `process-compose up` (socket Postgres →
`just create-database` → active-key bootstrap → `shomei-server` on `:8080`). The **production**
OCI image (`nix build .#dockerImage`) and the plain `Dockerfile` are retained unchanged as the
deployment artifact. This change updates Vision & Scope, Decomposition Phase 3, Progress, the
Decision Log (new entry), Outcomes & Retrospective, and cascades to EP-5 (`docs/plans/12-…`, M3
rewritten) and EP-6 (`docs/plans/13-…`, quickstart/runbook retargeted). Committed setup updated
in lockstep: `process-compose.yaml` extended with `bootstrap_keys` + `shomei-server`;
`docs/deployment.md`, `README.md`, `CHANGELOG.md`, and `flake.module.nix` corrected;
`docker-compose.yaml` deleted.
