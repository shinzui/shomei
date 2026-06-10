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
container image alongside PostgreSQL with one `docker compose up`; load all runtime
settings (issuer, audience, TTLs, password policy, rate limits, SMTP, log level) from a
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
password. These flows are delivered behind a pluggable notification effect so the toolkit
ships a development log-only sender out of the box and an SMTP sender for production,
without baking any particular email provider into the core.

Finally, a developer evaluating Shōmei can read the documentation the spec's repo layout
promised but the bootstrap never wrote — `docs/architecture.md`, `docs/api.md`,
`docs/security.md`, `docs/deployment.md`, and a top-level getting-started `README.md` — and
stand up the toolkit in either deployment mode by following them.

**In scope.** Email verification and password-reset/change workflows with a notification
(mailer) effect; a development log sender and a production SMTP sender; brute-force and
rate-limit protection (per-IP and per-account login throttling, account lockout, and
generic responses that do not leak account existence); structured logging, Prometheus
metrics, readiness/liveness probes, request correlation IDs, and graceful shutdown; an
operational CLI (`shomei-admin`) for migrations, signing-key generation/rotation/retirement,
and bootstrap user creation; a typed Dhall + environment configuration layer; an
OCI/Docker image and a `docker compose` stack; a CI pipeline (build, test, format check);
and the four `docs/*.md` files plus a getting-started README.

**Explicitly out of scope (still deferred, consistent with MasterPlan 1 and the spec).**
OAuth, OIDC, social login, magic links, passkeys/WebAuthn, MFA, device management, an admin
UI, organization/team management, a full authorization policy engine, risk scoring, and
anomaly detection. Event-sourcing the audit log (MessageDB) remains deferred. This plan
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
  effect interfaces, new codd migrations, a `Shomei.Effect.Notifier` mailer effect with a dev log sender and
  an SMTP sender, new core workflows, new `ShomeiAPI` routes and handlers, and server wiring.
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
  overlapping keys during rotation). EP-5 (plan 12) packages everything: the OCI image, the
  `docker compose` stack, the typed Dhall/env configuration loader that assembles the
  fully-extended `ShomeiConfig`, and CI. EP-5 hard-depends on EP-4 because the container
  entrypoint runs migrations and ensures an active signing key *through the CLI*.

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
| 1 | Account lifecycle: email verification and password reset | docs/plans/8-account-lifecycle-email-verification-and-password-reset.md | None | None | In Progress |
| 2 | Abuse protection: rate limiting and brute-force lockout | docs/plans/9-abuse-protection-rate-limiting-and-brute-force-lockout.md | None | EP-1 | In Progress |
| 3 | Observability: structured logging, metrics, and health probes | docs/plans/10-observability-structured-logging-metrics-and-health-probes.md | None | None | Not Started |
| 4 | Operational CLI and signing-key rotation tooling | docs/plans/11-operational-cli-and-signing-key-rotation-tooling.md | None | None | Not Started |
| 5 | Packaging, configuration, and deployment | docs/plans/12-packaging-configuration-and-deployment.md | EP-4 | EP-1, EP-2, EP-3 | Not Started |
| 6 | Documentation and adoption guides | docs/plans/13-documentation-and-adoption-guides.md | None | EP-1, EP-2, EP-3, EP-4, EP-5 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The single hard ordering inside this MasterPlan is **EP-5 → EP-4**: the container image and
`docker compose` stack from EP-5 (plan 12) run database migrations and ensure an active
signing key exists at startup by invoking the `shomei-admin` CLI that EP-4 (plan 11)
builds, so EP-5 cannot ship a working entrypoint until the CLI exists. Everything else is
soft.

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

Parallelism summary: after MasterPlan 1 completes, EP-1 and EP-4 can start immediately and
in parallel. Once EP-1 lands, EP-2 and EP-3 run in parallel. EP-5 starts once EP-4 is done
(and is most efficient once EP-1/EP-2/EP-3 are done). EP-6 is finalized last.


## Integration Points

**IP-1 — `Shomei.Effect.Notifier` (the notification/mailer effect).** A new dynamic `effectful`
effect in `shomei-core/src/Shomei/Effect/Notifier.hs` with a smart constructor such
as `sendNotification :: Notification -> Eff es ()`, where `Notification` is a core domain
type (e.g. an `EmailVerificationRequested`/`PasswordResetRequested` sum carrying the
recipient `Email`, a one-time link/token, and an expiry). Owner: **EP-1** (defines the
effect, a `Notification` domain type, an in-memory/list interpreter for tests mirroring
`Shomei.Effect.InMemory`, a development "log only" interpreter, and an SMTP interpreter in a
new `Shomei.Notify.*` module — decide in EP-1 whether SMTP lives in `shomei-server` or a new
`shomei-notify` package; default: a `Shomei.Notify` module inside `shomei-server` to avoid a
new package, recorded in EP-1's Decision Log). Consumers: **EP-2** may publish an
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
**EP-1** an SMTP/email library; **EP-2** a rate-limiter or token-bucket library (or none, if
implemented in-process); **EP-3** a Prometheus client and structured-logging libraries;
**EP-4** `optparse-applicative` for the CLI; **EP-5** typically none new. Rule:
no Shōmei package may depend on the deprecated `memory` package (use `ram`), consistent with
MasterPlan 1. Each plan must verify its new dependencies build on GHC 9.12.4 inside
`nix develop` and add any required `allow-newer` entry in its own block. If EP-4's CLI is a
new executable, decide its home (default: a `shomei-admin` executable stanza inside the
existing `shomei-server` package, avoiding a new mori.dhall package registration —
see Decision Log); if a new `shomei-cli`/`shomei-notify` package is introduced instead,
register it in `mori.dhall` as MasterPlan 1 EP-3 did for `shomei-migrations`.


## Progress

Milestone-level tracking across all child plans. Updated as each plan's milestones land.

- [~] EP-1: `Notifier` effect + dev-log sender done; verification/reset token types, stores, and migrations done. **Production SMTP sender remains blocked** on a vetted SMTP dependency being registered in `mori` (re-checked 2026-06-10).
- [x] EP-1: email-verification and password-reset/change workflows pass pure in-memory tests
- [x] EP-1: new `ShomeiAPI` routes + handlers pass in-process lifecycle HTTP tests
- [x] EP-1: new `ShomeiAPI` routes + handlers; `curl` walkthrough of verify-email and password-reset against the live server (2026-06-10, log-only notifier)
- [~] EP-2: rate-limit + lockout policy in `ShomeiConfig` done; per-IP/per-account login throttling wired into the workflow (M1–M3). The per-IP **request-rate WAI middleware** remains (M4).
- [x] EP-2: account lockout after N failed logins with generic responses; pure + PostgreSQL integration tests pass (`cabal test all` green, 2026-06-10)
- [ ] EP-3: structured JSON logging + request correlation IDs; graceful shutdown
- [ ] EP-3: Prometheus `/metrics` and `/ready` readiness probe distinct from `/health`
- [ ] EP-4: `shomei-admin` CLI runs migrations and creates a bootstrap user
- [ ] EP-4: signing-key generate → activate → retire → revoke lifecycle; JWKS reflects overlapping keys during rotation
- [ ] EP-5: typed Dhall/env config loader assembles the fully-extended `ShomeiConfig`
- [ ] EP-5: OCI image + `docker compose up` brings up server + PostgreSQL; CI pipeline green
- [ ] EP-6: `docs/{architecture,api,security,deployment}.md` + getting-started `README.md` written and followed end-to-end


## Surprises & Discoveries

Cross-plan insights, dependency changes, and scope adjustments discovered during
implementation. Provide concise evidence.

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

- **2026-06-04 EP-1 SMTP dependency remains unresolved.** `mori registry search smtp`,
  `mori registry search HaskellNet`, and `mori registry search mime-mail` did not return a
  registered SMTP/email package source to audit. EP-1 therefore added the `Shomei.Notify`
  assembly module and explicit `SmtpNotifier` config path, but kept it log-backed until a
  vetted dependency is registered/resolved. The MasterPlan should not treat EP-1's production
  SMTP sender or live curl acceptance as complete yet.


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
  with a development log-only sender and a production SMTP sender; the toolkit bakes in no
  specific email provider.
  Rationale: Preserves the transport-agnostic-core principle (the core defines the effect; only
  the sender adapter knows SMTP), mirrors the existing store-effect pattern, and keeps the dev
  experience friction-free (logs the link instead of sending mail).
  Date: 2026-06-04

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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare
the result against the original vision.

(To be filled during and after implementation.)

- 2026-06-04: EP-1 M3 is complete and M4 is partially complete. The servant API now exposes
  the verify-email, password-reset, and password-change routes, and the server assembly wires
  the PostgreSQL token stores plus config-selected notifier interpreter. The in-process HTTP
  suite covers signup, email verification, password reset, login, refresh, JWKS, and role
  checks; `nix develop --command cabal test all` passes. Remaining EP-1 work is a real SMTP
  sender and the live-server `curl` walkthrough.

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
  routes. EP-1 stays **In Progress** in the registry solely because the *production SMTP
  sender* (M4.1b/M4.3) is blocked: `mori registry search` for `smtp`/`mail`/`HaskellNet`
  returns nothing, so per the repo's dependency-lookup rule the real sender cannot be written
  without guessing at an unaudited library. The `SmtpNotifier` transport is wired and
  log-backed until such a dependency is registered. All EP-1 user-visible behaviour is
  delivered; only the SMTP transport remains, and it blocks nothing downstream (EP-2 only needs
  the `Notifier` effect, which exists).


## Revision Notes

2026-06-04: Updated this MasterPlan after the package-layout refactor. The package paths now
refer to top-level directories, the effect interfaces now use
the `Shomei.Effect.*` namespace, and the global precondition now reflects that MasterPlan 1's
vertical slice is implemented and passing `cabal build all` / `cabal test all`.
