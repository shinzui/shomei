---
id: 13
slug: documentation-and-adoption-guides
title: "Documentation and adoption guides"
kind: exec-plan
created_at: 2026-06-04T02:42:05Z
intention: "intention_01kt8847mre3wa36x0s0k9j6pm"
master_plan: "docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md"
---

# Documentation and adoption guides

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-6**, the sixth and final child plan of the MasterPlan
`docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md`. It produces the
five documents the original specification (`docs/initial-spec.md`, section "Suggested Repo
Layout") promised but no prior plan wrote: a top-level getting-started `README.md`, plus
`docs/architecture.md`, `docs/api.md`, `docs/security.md`, and `docs/deployment.md`. It
writes **no code**; it only writes prose, and every fact it states must be **verified against
the shipped behavior of the running system** at authoring time.


## Purpose / Big Picture

Shōmei (Japanese 証明, "proof / verification / certification") is a Haskell authentication
toolkit. It can run two ways: as a **standalone authentication microservice**
(`shomei-server`, which issues ES256-signed JWT access tokens and publishes a JWKS document
so downstream services verify those tokens locally without calling back), or as an
**embedded Servant library** linked directly into a monolithic Haskell web application. Both
modes are built from the same transport-agnostic core. Today, after MasterPlan 1 and
MasterPlan 2's EP-1 through EP-5 land, all of that *works* — but a developer evaluating
Shōmei has nothing to read. There is no README, no architecture overview, no API reference,
no security model writeup, and no deployment guide. The four `docs/*.md` files the spec's
repo layout lists do not exist on disk (confirmed: `docs/` contains only `initial-spec.md`,
`masterplans/`, and `plans/`), and there is no top-level `README.md` (confirmed: none at the
repository root).

After this change, a newcomer can:

- Read `README.md` at the repository root, understand in two minutes what Shōmei is and which
  of the two deployment modes they want, and run a **5-minute quickstart**: `docker compose
  up` brings up `shomei-server` plus PostgreSQL, and a handful of `curl` commands sign a user
  up, log in, fetch the current user, refresh the token pair, and fetch the JWKS — each
  returning the documented response.
- Read `docs/architecture.md` to understand the library-first, transport-agnostic-core
  design; the package dependency layering; the effects-and-workflows model; the domain model;
  and the two deployment-model diagrams.
- Read `docs/api.md` as a complete HTTP reference for every endpoint the standalone server
  exposes, with method, path, authentication requirement, request and response JSON, status
  codes, and copy-pasteable `curl` transcripts.
- Read `docs/security.md` to understand exactly what Shōmei does to keep credentials and
  sessions safe, with a short threat-model table and the list of deliberately deferred
  protections.
- Read `docs/deployment.md` to deploy the server: the typed Dhall/environment configuration
  reference, the container image and `docker compose` stack, the `shomei-admin` operator
  runbook, migrations, health/readiness probes and graceful shutdown, and how a downstream
  service verifies JWTs locally from the JWKS endpoint.

The observable, human-verifiable outcome of this plan is simple and strict: **a reader who
follows each document succeeds.** The quickstart boots. Every `curl` example returns the
response the document shows. Every `shomei-admin` command in the runbook runs and produces
the documented effect. Every configuration field the deployment doc lists actually exists in
`Shomei.Config` and its loader. If any of these drift from reality, the document is wrong and
the milestone is not done. This is the non-negotiable acceptance criterion for the entire
plan, restated in every milestone.

Definitions used throughout (so a reader new to the codebase is not lost):

- **Standalone / microservice mode** — running the `shomei-server` executable as its own
  HTTP service. Clients call it to sign up, log in, refresh, and log out. It signs JWT access
  tokens with a private ES256 key and publishes the matching public key at
  `/.well-known/jwks.json`. Other ("downstream") services verify those JWTs locally using
  that published key and never call `shomei-server` on the normal request path.
- **Embedded mode** — using the `shomei-servant` library to mount Shōmei's authentication
  routes and route-protection combinators directly inside another Servant application, so
  auth and application logic share one process and one PostgreSQL database.
- **JWT (JSON Web Token)** — a signed, self-describing access token. The bearer presents it;
  the verifier checks the signature and the claims (issuer, audience, expiry) without a
  database lookup.
- **JWKS (JSON Web Key Set)** — a JSON document listing the public keys (each with a key id,
  `kid`) that can verify the service's JWTs. Published at `/.well-known/jwks.json`.
- **ES256** — an asymmetric JWT signing algorithm (ECDSA over the NIST P-256 curve with
  SHA-256). The server holds the private key; anyone with the public key (from JWKS) can
  verify but not forge.
- **Argon2id** — the password-hashing algorithm Shōmei uses. Memory-hard and slow on
  purpose, to resist offline cracking.
- **Refresh-token rotation with reuse detection** — each refresh exchanges the presented
  opaque refresh token for a brand-new one and marks the old one used; presenting an
  already-used token is treated as theft and revokes the whole session's token family.
- **Effect interface** — an abstract capability the transport-agnostic core needs from the
  outside world (store a user, hash a password, sign a token, send an email), expressed as an
  `effectful` effect under `Shomei.Effect.*`. Concrete behavior is supplied by an
  **interpreter** (in-memory for tests; real PostgreSQL/JWT for production; the `Notifier`
  effect's only built-in interpreter logs the notification — Shōmei does not send email).
- **`effectful`** — the Haskell effect-system library Shōmei uses to express effects and wire
  interpreters; "an effect" here means one of those abstract capabilities.
- **codd** — the migration tool that applies the SQL files in `shomei-migrations`
  to bring a PostgreSQL database to the current schema.
- **Dhall** — a typed, non-Turing-complete configuration language; Shōmei's runtime settings
  can be loaded from a Dhall file (or environment variables) instead of ad-hoc flags.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0: Verification pass — the real surface was enumerated directly from the implemented
  code (routes in `ShomeiAPI`, `ShomeiConfig` fields + env vars in `Shomei.Server.Config`, and
  the `shomei-admin` subcommands), since EP-1..EP-5 were implemented in the same effort.
  Completed 2026-06-10.
- [x] M1: `README.md` written — what Shōmei is, the two modes, the package table, and a
  `nix develop` + `curl` / `shomei-admin` quickstart. Completed 2026-06-10.
- [x] M1: `docs/architecture.md` written — library-first/transport-agnostic design, package
  layering, the ports-and-interpreters model, the workflows, the HTTP/middleware layer, and
  persistence. Completed 2026-06-10.
- [x] M2: `docs/api.md` written — every endpoint (account/session, the account-lifecycle 202
  routes, `/health`, `/ready`, `/metrics`, JWKS) with bodies, status codes, the generic-error
  rule, and the `X-Request-Id` correlation id. Completed 2026-06-10.
- [x] M3: `docs/security.md` written — Argon2id, opaque hashed tokens + rotation/reuse, the
  zero-downtime key lifecycle, the no-account-existence-leak guarantees, the EP-2 abuse-protection
  defaults, session revocation, and logging hygiene. Completed 2026-06-10.
- [x] M4: `docs/deployment.md` written — the config reference (every env var + Dhall field and
  the precedence), the `shomei-admin` runbook, the OCI image + `docker compose` flow (with the
  honest "not built in sandbox" note), probes, graceful shutdown, and CI. Completed 2026-06-10.
- [x] Final: the five docs are cross-linked (README → the four `docs/*`; api/security/deployment
  reference each other). Outcomes recorded below.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence. In particular, this is where the implementer
records **every place the shipped system differs from what this plan assumed** (an endpoint
named differently, a config field that did not land, a CLI subcommand that changed), since
this plan was authored ahead of the implementation it documents.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The deliverable doc set is exactly five files — top-level `README.md` and
  `docs/architecture.md`, `docs/api.md`, `docs/security.md`, `docs/deployment.md` — matching
  the spec's "Suggested Repo Layout" plus the getting-started README the MasterPlan's Vision
  promised. No other docs (no per-package READMEs, no generated Haddock site) are in scope.
  Rationale: These five are what the spec and MasterPlan 2 Vision name; keeping scope tight
  avoids documentation sprawl that drifts out of date.
  Date: 2026-06-04

- Decision: Every documented endpoint, flag, command, and config field must be
  **verified against the actual code at authoring time**, and verification-against-reality is
  an explicit acceptance criterion for each milestone. Where reality differs from this plan's
  pre-written assumptions, the implementer fixes the prose to match reality (not the other
  way around) and records the drift in Surprises & Discoveries.
  Rationale: This plan is authored ahead of EP-1..EP-5's implementation. Docs that lie are
  worse than no docs. The only defense against drift is to run the commands shown and confirm
  the responses before publishing.
  Date: 2026-06-04

- Decision: The configuration reference in `docs/deployment.md` is generated **from the
  source of truth** — `Shomei.Config` (`shomei-core/src/Shomei/Config.hs`) and the
  Dhall/env loader EP-5 builds (its IP-6 module plus the on-disk Dhall schema, e.g.
  `config/shomei.dhall`) — by reading those modules and the loader's env-var bindings, not
  from memory. Each documented field names its `ShomeiConfig` field, its Dhall path, its
  environment-variable name, its type, and its default.
  Rationale: A config reference is the most drift-prone document; tying each row to a concrete
  source location makes it auditable and re-derivable.
  Date: 2026-06-04

- Decision: Documents are illustrative-but-honest about example values: JWTs, refresh tokens,
  and TypeID identifiers in transcripts are shown as truncated/placeholder strings (e.g.
  `eyJhbGciOi...`, `user_01h...`), with a sentence noting the real values are long and
  opaque. Status codes, field names, and JSON shapes are exact.
  Rationale: Pasting a 600-character JWT into a doc helps no one; the *shape* and the *status
  code* are what the reader verifies.
  Date: 2026-06-04


- Decision: Update this ExecPlan for the 2026-06-04 package-layout and effect-namespace refactor.
  Rationale: The packages now live as top-level directories rather than under the old nested packages directory, and the core effect interfaces now live under `Shomei.Effect.*` rather than the old Port namespace. This revision also removes stale bootstrap-placeholder assumptions and points implementation steps at the current real modules.
  Date: 2026-06-04

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository is the Shōmei monorepo at `/Users/shinzui/Keikaku/bokuno/shomei`. It is a
multi-package Haskell (Cabal) workspace; package identity is declared in `mori.dhall` (run
`mori show --full` to see it). The seven first-party packages are top-level directories:

- **shomei-core** (`shomei-core`) — the transport-agnostic domain: types, commands,
  events, errors, and effect interfaces, expressed as `effectful` effects. It deliberately depends on no
  Servant, no WAI, no PostgreSQL, no JWT library, and no HTTP. This is where `Shomei.Config`
  (the `ShomeiConfig` record), the domain modules (`Shomei.Domain.*`), the effect interfaces
  (`Shomei.Effect.*`), and the auth workflows (`Shomei.Workflow`) live.
- **shomei-jwt** (`shomei-jwt`) — JWT access-token signing and verification plus
  JWKS publishing; the only package that knows about the `jose` library and ES256.
- **shomei-migrations** (`shomei-migrations`) — codd-managed PostgreSQL schema
  migrations (embedded SQL under `sql-migrations/`) plus a test-support sublibrary for
  ephemeral databases.
- **shomei-postgres** (`shomei-postgres`) — PostgreSQL (hasql) implementations of
  the core store effects plus the audit-event publisher.
- **shomei-servant** (`shomei-servant`) — Servant combinators and handlers: the
  `Authenticated` combinator, `RequireRole`/`RequireScope`, and the `ShomeiAPI` route record.
- **shomei-server** (`shomei-server`) — the standalone authentication service: a
  thin application layer over the libraries, plus (per MasterPlan 2) the `shomei-admin`
  operator CLI and the WAI middleware stack (rate limiting, logging, metrics).
- **shomei-client** (`shomei-client`) — a Haskell client for the standalone service.

The authoritative source of truth for *intended* behavior is `docs/initial-spec.md`. Read its
sections "Standalone HTTP API", "Configuration", "Security Requirements", "Microservice
Deployment Model", and "Embedded Monolith Model" before writing — the docs this plan produces
must describe the system that spec describes, refined by what actually shipped.

**Soft-dependency precondition (read carefully).** This plan documents the *finished* behavior
of the entire MasterPlan 2 surface. It carries no hard code dependency, but it
**soft-depends on EP-1 through EP-5 being Complete** and on all of MasterPlan 1 being
Complete. Concretely, by the time this plan executes:

- MasterPlan 1 has shipped the working vertical slice: `shomei-server` boots against
  PostgreSQL and serves `POST /auth/signup`, `/auth/login`, `/auth/refresh`, `/auth/logout`,
  `GET /auth/me`, `GET /auth/session`, `GET /.well-known/jwks.json`, and `GET /health`; it
  signs and verifies ES256 JWTs; it publishes JWKS; and the two demo apps
  (`examples/embedded-servant-app`, `examples/microservice-auth-stack`) run.
- EP-1 (`docs/plans/8-account-lifecycle-email-verification-and-password-reset.md`) added
  `POST /auth/verify-email/request`, `POST /auth/verify-email/confirm`,
  `POST /auth/password-reset/request`, `POST /auth/password-reset/confirm`, and an
  authenticated `POST /auth/password/change`, plus the `Shomei.Effect.Notifier` notification
  effect (dev log sender only — Shōmei emits notifications, operators deliver them) and the
  single-use token machinery.
- EP-2 (`docs/plans/9-abuse-protection-rate-limiting-and-brute-force-lockout.md`) added
  per-IP and per-account login throttling, account lockout after repeated failures, and
  generic responses that do not leak account existence; rejected/locked requests return
  HTTP 429.
- EP-3 (`docs/plans/10-observability-structured-logging-metrics-and-health-probes.md`) added
  structured JSON logging with per-request correlation IDs, a Prometheus `GET /metrics`
  endpoint, a `GET /ready` readiness probe distinct from the liveness `GET /health`, and
  graceful shutdown.
- EP-4 (`docs/plans/11-operational-cli-and-signing-key-rotation-tooling.md`) delivered the
  `shomei-admin` CLI (migrate; signing-key generate/activate/retire/revoke; bootstrap user
  creation) and the signing-key rotation lifecycle (pending → active → retired → revoked,
  with JWKS reflecting overlapping keys during rotation).
- EP-5 (`docs/plans/12-packaging-configuration-and-deployment.md`) delivered the typed
  Dhall/environment configuration loader that assembles the fully-extended `ShomeiConfig`, the
  OCI container image, and the `docker compose` stack (server + PostgreSQL), plus CI.

Because this plan is authored *before* those plans run, **treat every endpoint, flag, command,
and field this plan names as a claim to be checked, not a fact to be trusted.** The first
milestone (M0) is a verification pass that enumerates the real surface; the prose milestones
then describe exactly what M0 found, correcting any drift and logging it.

Files this plan creates (all paths relative to `/Users/shinzui/Keikaku/bokuno/shomei`):

```text
README.md               (new — top-level getting-started)
docs/architecture.md    (new)
docs/api.md             (new)
docs/security.md        (new)
docs/deployment.md      (new)
```

No source code, build files, or migrations are touched.


## Plan of Work

The work is five documents grouped into one verification milestone (M0) and four authoring
milestones (M1–M4), each independently verifiable by following the document it produces
against the running system. The golden rule, repeated in every milestone: **do not write a
sentence you have not confirmed against the code or a running instance.** When this plan's
pre-written content disagrees with reality, reality wins; fix the prose and log the drift.

### Milestone M0 — Verify the real surface before writing a word

Scope: stand up the system and enumerate exactly what it exposes, so the prose milestones
describe reality rather than this plan's forward-looking assumptions. Nothing is written to
the doc files yet; the output is a set of confirmed facts recorded in Surprises & Discoveries.

What to do, from the repository root inside `nix develop` (the dev shell):

1. Boot the stack the way the README will tell readers to:

   ```bash
   docker compose up -d
   ```

   Confirm the server and PostgreSQL containers reach a healthy state (the exact service
   names come from EP-5's compose file; inspect it with `docker compose config --services`).
   If the container entrypoint runs migrations and ensures an active signing key via
   `shomei-admin`, confirm those steps succeed in the logs (`docker compose logs shomei` or
   the real service name).

2. Enumerate every route the server actually serves. The fastest honest way is to probe each
   endpoint this plan documents and confirm its method, path, and status code, and to read
   the `ShomeiAPI` route record in `shomei-servant` plus the server's WAI assembly in
   `shomei-server` for `/ready`, `/metrics`, `/health`, and the JWKS path. List the
   full set and compare it against the union of MasterPlan 1's eight endpoints and MasterPlan
   2's additions named in Context above.

3. Enumerate every `ShomeiConfig` field and its loader binding. Read
   `shomei-core/src/Shomei/Config.hs` for the record (including the sub-records EP-1,
   EP-2, EP-3 appended) and EP-5's configuration loader (IP-6) for the Dhall paths and
   environment-variable names. Build the field → Dhall-path → env-var → type → default table
   that `docs/deployment.md` will publish.

4. Enumerate every `shomei-admin` subcommand and its flags by running its `--help`:

   ```bash
   shomei-admin --help
   shomei-admin migrate --help
   shomei-admin keys --help
   shomei-admin users --help
   ```

   (Run via `cabal run shomei-admin -- --help` if the binary is not on `PATH`; the exact
   invocation surfaces from EP-4.) Record the actual subcommand names and flags — they are
   the runbook's backbone.

Acceptance for M0: the implementer has a written, evidence-backed inventory (in Surprises &
Discoveries) of the real routes, config fields, and CLI commands, and has noted every
divergence from this plan's assumptions. Only then do the prose milestones begin.

### Milestone M1 — `README.md` and `docs/architecture.md`

Scope: the entry points. At the end of M1, a newcomer can read the README, grasp what Shōmei
is and which mode they want, run the quickstart successfully, and click through to a coherent
architecture document. The exact required content for both files is specified verbatim in
"Concrete Steps" below; write those files, then verify by following them.

Acceptance for M1: a reader (or the implementer simulating one) runs `docker compose up`,
then the README's `curl` sequence (signup → login → me → refresh → jwks), and observes each
documented response. The architecture doc's package table matches `mori.dhall`; its diagrams
render; its claims about layering and the domain model match `shomei-core`'s modules. Confirm
the quickstart on a clean checkout (`docker compose down -v` first, to prove it works from an
empty database).

### Milestone M2 — `docs/api.md`

Scope: the complete HTTP reference. At the end of M2, every endpoint the standalone server
serves is documented with method, path, authentication requirement, request JSON, response
JSON, status codes, and a verified `curl` transcript. This is the most drift-sensitive
document after the config reference; every example must be run.

Acceptance for M2: for each endpoint, the implementer runs the documented `curl` against the
live `docker compose` server and confirms the status code and JSON shape match the document.
The 429/lockout behavior (EP-2) is exercised by deliberately failing login repeatedly until a
429 (or lockout) response appears, and that response is documented. `/ready`, `/metrics`,
`/health`, and `/.well-known/jwks.json` are all probed and documented from their real output.

### Milestone M3 — `docs/security.md`

Scope: the security model. At the end of M3, a reader understands precisely what Shōmei does
to protect credentials and sessions, why, and what it deliberately does not do. Content is
prose-first with one short threat-model table and one deferred-features list.

Acceptance for M3: every claim is cross-checked against code — Argon2id usage in the password
hasher interpreter, "only hashes persisted" against the schema and the refresh/one-time-token
stores, the rotation/reuse-revokes-the-family behavior against `Shomei.Workflow`, the generic
login error against the login workflow, the lockout/rate-limit defaults against EP-2's config
sub-record, the ES256/JWKS/key-rotation lifecycle against `shomei-jwt` and EP-4, the cookie
flags against EP-5/Servant cookie settings, and the session-check modes against
`SessionCheckMode`. The single-use semantics of verification/reset tokens (EP-1) are confirmed
by attempting to reuse a token and observing rejection.

### Milestone M4 — `docs/deployment.md`

Scope: the operator's guide. At the end of M4, an operator can configure, run, migrate,
rotate keys for, and health-check a Shōmei deployment, and a downstream service author can
verify JWTs locally. Content includes the full config reference table (derived in M0), the
image/compose section, the `shomei-admin` runbook, the migrations section, the probes and
graceful-shutdown section, and the downstream local-verification section.

Acceptance for M4: every config field documented exists in `Shomei.Config`/the loader (the M0
table); every `shomei-admin` command in the runbook runs and produces its documented effect
against the live stack (generate a key, activate it, confirm it appears in JWKS, retire and
revoke it); the probes return their documented codes; and the downstream-verification recipe
actually verifies a token issued by the running server using only the JWKS document.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside
`nix develop`. The five files below are written **as specified here**, then verified by
running the commands they contain. Where a value depends on EP-1..EP-5's final choices (a
service name, a flag, a field), M0's inventory supplies the real value and the prose is
corrected to match.

The content blocks below are the **required substance** of each file. The implementer writes
each file with at least this content, in this order, adjusting only to match verified reality.
Every fenced block in the produced documents must carry a language tag (`markdown`, `bash`,
`json`, `text`, `dhall`, or `haskell`).

### Step 1 — Write `README.md` (M1)

Create `README.md` at the repository root with these sections in order:

1. **Title and one-liner.** A heading "Shōmei (証明)" and the spec's one-line summary: a
   Haskell authentication toolkit that runs as a standalone auth service or embeds into
   Servant applications, with password login, sessions, refresh-token rotation, JWT
   verification, JWKS publishing, and PostgreSQL persistence.

2. **What it is / the two modes.** Two short paragraphs: standalone microservice mode
   (`shomei-server` issues ES256 JWTs and publishes JWKS for downstream local verification)
   and embedded mode (`shomei-servant` mounted inside a Servant app). One sentence each on
   when to choose which.

3. **Package table.** A table of the seven packages and their one-line descriptions, taken
   from `mori.dhall` so it stays accurate:

   ```markdown
   | Package | Description |
   |---|---|
   | `shomei-core` | Transport-agnostic domain: types, commands, events, errors, effects (no Servant/WAI/PostgreSQL/JWT/HTTP). |
   | `shomei-jwt` | JWT access-token signing/verification and JWKS publishing. |
   | `shomei-migrations` | codd-managed PostgreSQL schema migrations plus a test-support sublibrary. |
   | `shomei-postgres` | PostgreSQL implementations of the core store effects plus the audit-event publisher. |
   | `shomei-servant` | Servant combinators and handlers: `Authenticated`, `RequireRole`/`RequireScope`, `ShomeiAPI`. |
   | `shomei-server` | Standalone authentication service (and the `shomei-admin` CLI) — a thin layer over the libraries. |
   | `shomei-client` | Haskell client for the standalone Shōmei auth service. |
   ```

4. **5-minute quickstart.** The headline experience. Spell it out so it works from a clean
   checkout:

   ```bash
   # From the repository root. Brings up shomei-server + PostgreSQL.
   # The entrypoint runs database migrations and ensures an active ES256 signing key.
   docker compose up -d

   # Wait for readiness (HTTP 200 once migrations have run and a key is active).
   curl -fsS http://localhost:8080/ready
   ```

   Then the `curl` walkthrough. Show signup, login, me, refresh, and jwks. Use a here-doc or
   `-d` JSON for request bodies and show the expected response shape. Example (the implementer
   confirms the exact port number, paths, and field names against M0):

   ```bash
   # 1) Sign up. Returns the user and a token pair (access + refresh).
   curl -fsS -X POST http://localhost:8080/auth/signup \
     -H 'Content-Type: application/json' \
     -d '{"email":"nadeem@example.com","password":"correct horse battery staple","displayName":"Nadeem"}'
   ```

   ```json
   {
     "user": {
       "userId": "user_01h...",
       "email": "nadeem@example.com",
       "displayName": "Nadeem",
       "status": "active"
     },
     "token": {
       "accessToken": "eyJhbGciOi...",
       "refreshToken": "rt_9f2a...opaque...",
       "expiresIn": 900
     }
   }
   ```

   ```bash
   # 2) Log in with the same credentials. Same response shape as signup.
   curl -fsS -X POST http://localhost:8080/auth/login \
     -H 'Content-Type: application/json' \
     -d '{"email":"nadeem@example.com","password":"correct horse battery staple"}'

   # 3) Fetch the current user. Bearer the access token from step 1 or 2.
   ACCESS='eyJhbGciOi...'   # paste the accessToken value
   curl -fsS http://localhost:8080/auth/me -H "Authorization: Bearer $ACCESS"

   # 4) Refresh the token pair. Rotates the refresh token; old one becomes invalid.
   curl -fsS -X POST http://localhost:8080/auth/refresh \
     -H 'Content-Type: application/json' \
     -d '{"refreshToken":"rt_9f2a...opaque..."}'

   # 5) Fetch the JWKS that downstream services use to verify these JWTs locally.
   curl -fsS http://localhost:8080/.well-known/jwks.json
   ```

   Note in prose that the `accessToken` and `refreshToken` values are long and opaque and must
   be copied from the previous response; the JSON shown is truncated for readability.

5. **Where to go next.** Links to the four docs: `docs/architecture.md` (design), `docs/api.md`
   (full API reference), `docs/security.md` (security model), `docs/deployment.md` (operating
   it). Mention `docs/initial-spec.md` as the original specification.

6. **Building from source.** One short block: enter `nix develop`, then `cabal build all` and
   `cabal test all`. Note GHC 9.12.4 and the Cabal multi-package workspace.

Verify M1's README half: from a clean state (`docker compose down -v` then `docker compose up
-d`), run every command in the quickstart in order and confirm each returns the documented
response. If a port number, path, or field differs, correct the README and record the drift.

### Step 2 — Write `docs/architecture.md` (M1)

Create `docs/architecture.md` with these sections:

1. **Library-first, transport-agnostic core.** Explain that the standalone service is a thin
   application layer over reusable libraries, and that `shomei-core` defines domain types,
   commands, events, errors, and effects while depending on no Servant, WAI, PostgreSQL, JWT
   library, or HTTP. State why: the same core powers both deployment modes, and the rules of
   authentication are testable in isolation with no infrastructure.

2. **Package dependency layering.** Reproduce the spec's layering as a diagram, refined to the
   real seven packages:

   ```text
   shomei-core
     ├── shomei-jwt        (JWT signing/verification + JWKS; depends on shomei-core)
     ├── shomei-migrations (SQL schema; depends on shomei-core)
     └── shomei-postgres   (store-effect implementations; depends on shomei-core, shomei-migrations)
            │
         shomei-servant    (Servant combinators + ShomeiAPI; depends on shomei-core, shomei-jwt)
            │
         shomei-server     (standalone service + shomei-admin CLI; depends on core, jwt, postgres, servant)
            │
         shomei-client     (Haskell client; depends on shomei-core)
   ```

   Explain in prose that dependencies point strictly downward toward `shomei-core`, which is
   the only package every other one shares, and that nothing below `shomei-servant` knows
   about HTTP.

3. **Effects and workflows.** Define "effect interface" (an abstract capability as an `effectful` effect)
   and "interpreter" (the concrete behavior). List the core effects by name and one-line purpose
   (user store, credential store, session store, refresh-token store, password hasher, token
   signer, token verifier, auth-event publisher, signing-key store, clock, token generator,
   and the EP-1 notifier/one-time-token stores), and explain the two interpreter families: an
   **in-memory** interpreter (`Shomei.Effect.InMemory`) used by the pure test suite, and the
   **real** interpreters (`shomei-postgres` for stores, `shomei-jwt` for signing/verifying,
   the log-only notifier from EP-1 — Shōmei does not send email). Then describe the workflows in `Shomei.Workflow` — signup,
   login, refresh (with rotation + reuse detection), logout, token verification — and the
   account-lifecycle workflows EP-1 added (email verification, password reset, password
   change). Emphasize that the workflows are written purely against effects, so swapping
   interpreters changes nothing about the rules.

4. **Domain model summary.** A short prose tour of the central types from `shomei-core`:
   `User` (with `UserStatus`), `Session` (with `SessionStatus`), `PersistedRefreshToken` (with
   `RefreshTokenStatus`, only the hash persisted), `Credential` (password credential),
   `StoredSigningKey` (with `SigningKeyStatus`: pending/active/retired/revoked), and
   `AuthClaims` (subject, session id, issuer, audience, issued/expires, scopes, roles). Note
   that identifiers are TypeIDs (UUIDv7 with a type prefix, e.g. `user_…`, `session_…`).

5. **Deployment models.** Adapt the spec's two ASCII diagrams.

   Microservice mode (downstream services verify JWTs locally from JWKS):

   ```text
                 ┌────────────────────┐
                 │   shomei-server    │
                 │ authentication svc │
                 └─────────┬──────────┘
                           │ publishes JWKS
                           ▼
                 /.well-known/jwks.json

   ┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐
   │ project-service    │   │ billing-service    │   │ notification-svc   │
   │ verifies JWT local │   │ verifies JWT local │   │ verifies JWT local │
   └────────────────────┘   └────────────────────┘   └────────────────────┘
   ```

   Explain the request paths: on the normal path a client sends its access token to a
   downstream service, which verifies the JWT locally using the cached JWKS and uses the
   claims as the authenticated user, with no call back to `shomei-server`; only login,
   refresh, and logout talk to `shomei-server` directly.

   Embedded monolith mode:

   ```text
   ┌──────────────────────────────────────┐
   │ Servant application                  │
   │   ┌──────────────┐                   │
   │   │ App API      │                   │
   │   └──────┬───────┘                   │
   │   ┌──────▼───────┐                   │
   │   │ shomei       │  (shomei-servant) │
   │   │ embedded auth│                   │
   │   └──────┬───────┘                   │
   │   ┌──────▼───────┐                   │
   │   │ PostgreSQL   │                   │
   │   └──────────────┘                   │
   └──────────────────────────────────────┘
   ```

   Explain that in embedded mode the app mounts `ShomeiAPI` under a path prefix and protects
   its own routes with the `Authenticated` combinator, sharing one process and database.

Verify M1's architecture half: confirm the package table/diagram against `mori.dhall`; confirm
the listed effects and domain types exist in `shomei-core/src/Shomei/`; confirm the two
deployment models match the demo apps under `examples/`.

### Step 3 — Write `docs/api.md` (M2)

Create `docs/api.md` as the complete HTTP reference. Open with a short preamble: base URL
(`http://localhost:8080` for the local stack), the JSON content type, the bearer-token
authentication scheme (`Authorization: Bearer <access-token>`), and a note that cookie
transport is available when configured (see `docs/security.md`). Then document every endpoint.
For each, give: method and path; whether authentication is required; the request body JSON
(with field types); the response body JSON; the possible status codes; and a runnable `curl`
transcript.

Document, at minimum, these endpoints — MasterPlan 1's eight and MasterPlan 2's additions:

- `POST /auth/signup` — no auth. Body `{email, password, displayName?}`. Returns
  `{user, token}` (201 or 200; confirm against M0). Errors: 409 if the email is already
  registered, 422/400 on invalid email or weak password.
- `POST /auth/login` — no auth. Body `{email, password}`. Returns `{user, token}`. **Always
  returns the same generic error** (401 with a generic message) for both unknown email and
  wrong password. May return **429** when rate-limited or locked out (EP-2).
- `POST /auth/refresh` — no auth (the refresh token *is* the credential). Body
  `{refreshToken}`. Returns `{accessToken, refreshToken, expiresIn}`. Presenting an
  already-used refresh token returns an error and revokes the session (reuse detection).
- `POST /auth/logout` — auth required (bearer). No body. Returns **204 No Content** and
  revokes the session and its refresh tokens.
- `GET /auth/me` — auth required. Returns the current `User`.
- `GET /auth/session` — auth required. Returns the current `Session`.
- `GET /.well-known/jwks.json` — no auth. Returns the JWKS (the set of public keys, each with
  a `kid`). Used by downstream services for local verification.
- `GET /health` — no auth. Liveness probe. Returns 200 with a small body.
- `POST /auth/verify-email/request` — EP-1. Confirm auth requirement against M0 (likely
  authenticated or by email). Body and response per EP-1; triggers a notification carrying a
  single-use token.
- `POST /auth/verify-email/confirm` — EP-1. Body `{token}`. Confirms the address; the token is
  single-use (a second attempt fails).
- `POST /auth/password-reset/request` — EP-1, no auth. Body `{email}`. **Returns the same
  response whether or not the email exists** (no account-existence leak); sends a reset link if
  it does.
- `POST /auth/password-reset/confirm` — EP-1, no auth. Body `{token, newPassword}`. On success
  resets the password **and revokes all existing sessions**. Token is single-use.
- `POST /auth/password/change` — EP-1, auth required. Body `{currentPassword, newPassword}`.
  Confirm against M0 whether it revokes other sessions.
- `GET /ready` — EP-3, no auth. Readiness probe (distinct from `/health`): 200 only when the
  server can serve traffic (database reachable, an active signing key present); otherwise 503.
- `GET /metrics` — EP-3, no auth. Prometheus exposition format (text, not JSON).

For each endpoint show a `curl` example and its expected response, following the README's
style. For the bodies and shapes, reuse the spec's examples for signup/login/refresh and
confirm the rest against M0. Explicitly document the **429 / lockout** response: include a
transcript that fails login enough times to trigger it and show the resulting status code and
body. Include a short "Status codes" subsection summarizing the conventions (200/201 success,
204 for logout, 401 unauthenticated/invalid credentials, 403 forbidden, 409 conflict, 422/400
validation, 429 throttled/locked, 503 not ready).

Verify M2: run every documented `curl` against the live `docker compose` server and confirm
status codes and JSON shapes. Drive the 429 path deliberately. Probe `/ready`, `/metrics`,
`/health`, and `/.well-known/jwks.json` and paste their real (truncated) output.

### Step 4 — Write `docs/security.md` (M3)

Create `docs/security.md` as a prose-first explanation of the security model, with one
threat-model table and one deferred-features list. Cover:

1. **Password handling.** Argon2id hashing (memory-hard, slow on purpose); plaintext passwords
   are never logged, serialized, or persisted (the `PlainPassword` type has a redacting `Show`
   and no JSON instances); password strength is validated against the configured policy;
   verification is fail-closed. State that the password hasher interpreter lives in the adapter
   layer, not the core.

2. **Generic login errors.** Login returns the *same* error for an unknown email and a wrong
   password, so the API never reveals whether an account exists. The same applies to the
   password-reset request, which responds identically whether or not the email is registered.

3. **Refresh tokens.** Opaque random tokens; only the **hash** is persisted (the plaintext is
   returned once and never stored). Rotated on every refresh; the old token is marked used.
   Presenting an already-used token is treated as theft: the whole session's token family is
   revoked, the session is revoked, and a `RefreshTokenReuseDetected` event is published.

4. **Brute-force and rate-limit defaults (EP-2).** Per-IP and per-account login throttling and
   account lockout after a configured number of failed attempts; throttled or locked requests
   return HTTP 429 with a generic body that does not reveal lockout state to an attacker
   probing accounts. Document the **actual default thresholds** from EP-2's `ShomeiConfig`
   sub-record (max attempts, window, lockout duration) — read them from the code, do not guess.

5. **Access tokens and key rotation.** ES256 asymmetric signing: the server holds the private
   key and publishes only the public key via JWKS, so downstream services verify but cannot
   forge. Each JWT carries a `kid`; verifiers select the matching JWKS key. Access tokens are
   short-lived (default 15 minutes); verification validates issuer, audience, and expiry. The
   signing-key lifecycle (EP-4) is **pending → active → retired → revoked**: a new key is
   generated as pending, activated to start signing, retired so it stops signing but its public
   key remains in JWKS to verify already-issued tokens during the overlap window, then revoked
   once no live tokens reference it. JWKS reflects overlapping keys during rotation.

6. **Cookie transport.** When configured for cookie transport (`HttpOnlyCookie` or
   `BearerAndCookie`), cookies are `HttpOnly`, `Secure`, and `SameSite=Lax` or `Strict`, with
   configurable domain and path, and CSRF protection for unsafe methods. Document the real
   defaults from EP-5/Servant cookie settings.

7. **Session-check modes.** `VerifyTokenOnly` (default for standalone downstream services:
   verify the JWT signature/claims and trust them, no database lookup) versus
   `VerifyTokenAndSession` (default for the embedded monolith: additionally check the session
   row is still active on each protected request, so a logout or revocation takes effect
   immediately). Explain the tradeoff: local-only verification scales without round-trips but
   cannot see an instant revocation until the short-lived access token expires.

8. **Single-use account tokens (EP-1).** Email-verification and password-reset tokens are
   opaque, only their hashes are persisted, they carry a TTL, and they are single-use — a
   confirmed or expired token cannot be replayed. A successful password reset revokes all
   existing sessions.

9. **Threat-model table.** A short table mapping threats to mitigations, for example:

   ```markdown
   | Threat | Mitigation |
   |---|---|
   | Offline password cracking | Argon2id memory-hard hashing; never store plaintext. |
   | Account enumeration | Generic login + password-reset responses; uniform timing/status. |
   | Stolen refresh token (replay) | Rotation + reuse detection revokes the whole session family. |
   | Forged access token | ES256 asymmetric signing; public key only in JWKS. |
   | Brute-force login | Per-IP/per-account throttling + lockout (HTTP 429). |
   | XSS stealing cookies | HttpOnly + Secure cookies; CSRF protection on unsafe methods. |
   | Token leak after logout | VerifyTokenAndSession mode; short access-token TTL. |
   | Replay of reset/verify link | Single-use, hashed, TTL-bounded one-time tokens. |
   ```

10. **Deferred protections.** State plainly what Shōmei does *not* yet do, drawn from the
    spec's deferred list: OAuth, OIDC, social login, magic links, passkeys/WebAuthn, MFA,
    device management, anomaly/risk scoring, and a distributed (multi-instance) rate-limit
    store. Note that rate-limit and lockout state is single-instance (PostgreSQL + in-process),
    sufficient for the single-container deployment this toolkit targets.

Verify M3: cross-check each claim against code (the hasher interpreter, the schema/stores, the
refresh workflow, the login workflow, EP-2's defaults, `shomei-jwt`/EP-4, the cookie settings,
`SessionCheckMode`). Confirm single-use semantics by reusing a verification or reset token
against the live server and observing rejection.

### Step 5 — Write `docs/deployment.md` (M4)

Create `docs/deployment.md` as the operator's guide. Cover:

1. **Configuration reference.** Open with how configuration is loaded (EP-5's typed Dhall file
   and/or environment variables, IP-6) and where the Dhall schema lives (e.g.
   `config/shomei.dhall`; confirm the path from EP-5). Then a complete reference table — built
   in M0 from `Shomei.Config` and the loader — with one row per setting: the `ShomeiConfig`
   field, the Dhall path, the environment-variable name, the type, the default, and a one-line
   meaning. Cover the base fields (issuer, audience, access/refresh/session TTLs, password
   policy, token transport, signing-key config, session-check mode) **and** the MasterPlan 2
   extensions: EP-1's notifier/verification settings (email-verification-required toggle,
   verification/reset token TTLs, notifier config — log sender only, no SMTP), EP-2's rate-limit/lockout sub-record,
   and EP-3's observability sub-record (log level/format, metrics toggle). Include
   deployment-only settings the loader adds (database URL, bind host/port, signing-key source).
   Show a minimal example Dhall config:

   ```dhall
   -- config/shomei.dhall (illustrative; confirm field names against the EP-5 schema).
   { issuer = "https://auth.example.com"
   , audience = "https://api.example.com"
   , accessTokenTtlSeconds = 900
   , refreshTokenTtlSeconds = 2592000
   , sessionTtlSeconds = 2592000
   , tokenTransport = "BearerToken"
   , sessionCheckMode = "VerifyTokenOnly"
   -- ... rate-limit, lockout, notifier, observability sub-records ...
   }
   ```

   And the equivalent environment-variable form for the same handful of settings (confirm the
   real names against the loader):

   ```bash
   export SHOMEI_ISSUER="https://auth.example.com"
   export SHOMEI_AUDIENCE="https://api.example.com"
   export SHOMEI_DATABASE_URL="postgres://shomei:shomei@db:5432/shomei"
   export SHOMEI_BIND_HOST="0.0.0.0"
   export SHOMEI_BIND_PORT="8080"
   ```

2. **Container image and `docker compose` stack (EP-5).** How to build/pull the OCI image and
   what the compose stack contains (server + PostgreSQL). The headline commands:

   ```bash
   docker compose up -d         # start server + PostgreSQL
   docker compose logs -f shomei # follow server logs (confirm the service name)
   docker compose down          # stop; add -v to also drop the database volume
   ```

   Explain that the container entrypoint runs migrations and ensures an active signing key on
   startup by invoking `shomei-admin`, so a fresh `up` reaches readiness without manual steps.

3. **`shomei-admin` operator runbook (EP-4).** A subsection per command, each with the exact
   invocation and its effect (confirm names/flags from M0):

   ```bash
   # Apply database migrations (idempotent; safe to re-run).
   shomei-admin migrate

   # Signing-key lifecycle.
   shomei-admin keys generate            # create a new pending key
   shomei-admin keys activate <kid>      # promote pending -> active (starts signing)
   shomei-admin keys retire <kid>        # active -> retired (stops signing; stays in JWKS to verify)
   shomei-admin keys revoke <kid>        # retired -> revoked (removed from JWKS)

   # Bootstrap user creation (for the first admin/operator account).
   shomei-admin users create --email operator@example.com
   ```

   Document the recommended **key-rotation procedure**: generate a new key, activate it (now
   signing new tokens), retire the previous key (it stops signing but its public key stays in
   JWKS so already-issued tokens still verify during the overlap), wait out the access-token
   TTL, then revoke the old key. Note that this is the safe, zero-downtime rotation path.

4. **Migrations.** Explain that schema migrations live in `shomei-migrations` and are
   applied by codd via `shomei-admin migrate` (or automatically by the container entrypoint).
   Migrations are append-only and immutable; re-running `migrate` is idempotent.

5. **Health, readiness, and graceful shutdown (EP-3).** Document `GET /health` (liveness: the
   process is up) versus `GET /ready` (readiness: database reachable and an active signing key
   present — gate load-balancer traffic on this). Show example probes:

   ```bash
   curl -i http://localhost:8080/health   # 200 when the process is alive
   curl -i http://localhost:8080/ready    # 200 when ready to serve; 503 otherwise
   ```

   Explain graceful shutdown: on SIGTERM the server stops accepting new connections, drains
   in-flight requests, and exits, so a rolling deploy loses no requests. Mention structured
   JSON logs with per-request correlation IDs and the Prometheus `/metrics` endpoint for
   scraping.

6. **Microservice mode: downstream local JWT verification.** A concrete recipe for a downstream
   service author: fetch and cache `/.well-known/jwks.json` (respecting a 5–30 minute cache
   TTL), then verify each incoming access token's signature against the JWKS key whose `kid`
   matches the token header, validate issuer/audience/expiry, and use the resulting claims as
   the authenticated user — with **no** call back to `shomei-server` on the normal path. Point
   to `shomei-jwt`'s verifier and the `examples/microservice-auth-stack` demo as the reference
   implementation, and note that only login/refresh/logout require talking to the auth service.

Verify M4: confirm every config field documented exists in `Shomei.Config`/the loader (the M0
table is the checklist); run each `shomei-admin` command against the live stack and confirm its
effect (generate a key, activate it, confirm it appears in `/.well-known/jwks.json`, retire and
revoke it, confirm JWKS changes); probe `/health` and `/ready` for their documented codes; and
verify a token issued by the running server using only the JWKS document (the downstream
recipe).

### Step 6 — Cross-link and final pass

Add a short "Documentation" links section to `README.md` (if not already present from Step 1)
and a one-line back-link at the top of each `docs/*.md` to the README and the other three docs.
Then re-run the full README quickstart end-to-end and one representative example from each of
`api.md`, `security.md`, and `deployment.md` against a freshly booted stack. Record the outcome
in Outcomes & Retrospective.


## Validation and Acceptance

Validation is behavioral: **a reader following each document succeeds against the real running
system.** The acceptance criteria, each phrased as observable behavior:

1. **Quickstart boots (README).** From a clean state (`docker compose down -v` then
   `docker compose up -d`), `curl http://localhost:8080/ready` eventually returns 200, and the
   README's signup → login → me → refresh → jwks `curl` sequence each returns the documented
   status code and JSON shape. Observable: five successful `curl` invocations with bodies
   matching the doc.

2. **Architecture matches reality (architecture.md).** The package table equals the seven
   packages in `mori.dhall`; every effect and domain type named in the doc exists under
   `shomei-core/src/Shomei/`; the two deployment diagrams match the demos under
   `examples/`. Observable: a side-by-side check passes with no missing or invented entries.

3. **Every API example returns its documented response (api.md).** For each endpoint, the
   documented `curl` run against the live server returns the documented status code and JSON
   shape, including the 429/lockout path driven by repeated failed logins, and the `/ready`,
   `/metrics`, `/health`, and JWKS probes. Observable: each transcript reproduces against the
   running server.

4. **Every security claim is code-backed (security.md).** Each statement is traceable to a
   specific module or config field (Argon2id in the hasher interpreter, hashes-only in the
   schema/stores, reuse-revokes-family in `Shomei.Workflow`, generic login in the login
   workflow, the real lockout/rate-limit defaults in EP-2's config, ES256/JWKS/rotation in
   `shomei-jwt`/EP-4, cookie flags in EP-5/Servant, `SessionCheckMode`), and reusing a
   one-time token against the live server is rejected. Observable: the cross-reference holds
   and the replay attempt fails.

5. **Every deployment instruction works (deployment.md).** Every config field documented
   exists in `Shomei.Config`/the loader; every `shomei-admin` command runs and produces its
   documented effect (a generated key, activated, visible in JWKS, then retired and revoked);
   `/health` and `/ready` return their documented codes; and a token issued by the running
   server verifies using only the JWKS document. Observable: the full operator runbook
   executes successfully against the live stack.

A milestone is **not** complete until its document's commands have been run and observed to
produce the documented output. Documentation that has not been verified against the running
system is treated as failing, regardless of how complete the prose looks.


## Idempotence and Recovery

Every step in this plan is safe to repeat. Writing the five Markdown files is idempotent:
re-running an edit overwrites the same file with the same content; nothing accumulates. The
documents touch no source code, no build files, and no migrations, so there is no schema or
build drift to recover from.

The verification commands are read-only or self-cleaning. `curl` probes mutate only
application state (a user row, a session, a signing key) in the **local** `docker compose`
database, never anything outside it; to reset to a pristine database, run `docker compose down
-v` (drops the volume) and `docker compose up -d` again. `shomei-admin migrate` is idempotent
(codd applies only pending migrations). The key-rotation runbook is reversible in the sense
that you can always generate a fresh key and activate it; a key accidentally revoked cannot be
un-revoked, so the doc must instruct operators to verify the `kid` before `keys revoke` — and
the implementer, when validating, should exercise revoke only against a throwaway key in the
local stack, never a key needed to verify live tokens.

If the quickstart or any example fails to reproduce, the recovery is the same as the
acceptance: the document is wrong, not the system. Correct the prose to match the observed
reality, record the divergence in Surprises & Discoveries, and re-verify. Because each document
is independent, a failure in one milestone does not block the others; fix and re-verify that
document in isolation.


## Interfaces and Dependencies

This plan writes prose, so it introduces no new libraries, modules, or types. Its "interfaces"
are the surfaces it documents, every one of which is **owned and finalized by an earlier plan**;
this plan must read those surfaces and describe them faithfully. The sources of truth, by
document:

- **README.md & docs/architecture.md** — `mori.dhall` (package list and descriptions);
  `docs/initial-spec.md` (design principles, layering, deployment models, domain model);
  `shomei-core/src/Shomei/` (the real effects, domain types, and `Shomei.Workflow`);
  `examples/` (the two demo apps that embody the two deployment modes); EP-5's `docker
  compose` stack (the quickstart).

- **docs/api.md** — the `ShomeiAPI` route record in `shomei-servant` plus the
  server's WAI assembly in `shomei-server` (the full route set, including EP-1's
  account-lifecycle routes and EP-3's `/ready` and `/metrics`); the request/response DTOs that
  follow the `SignupRequest`/`LoginRequest` JSON conventions; EP-2's 429/lockout responses; the
  live `docker compose` server (to run every example).

- **docs/security.md** — the password hasher interpreter (Argon2id); the PostgreSQL schema and
  the refresh/one-time-token stores ("only hashes persisted"); `Shomei.Workflow` (rotation,
  reuse detection, generic login error); EP-2's rate-limit/lockout config sub-record (real
  defaults); `shomei-jwt` and EP-4 (ES256, JWKS, key-rotation lifecycle); EP-5/Servant cookie
  settings; `SessionCheckMode` in `Shomei.Config`; EP-1's single-use token semantics; the
  spec's deferred-features list.

- **docs/deployment.md** — `Shomei.Config` (`shomei-core/src/Shomei/Config.hs`) and
  EP-5's configuration loader (IP-6) and Dhall schema (the config reference); EP-5's OCI image
  and `docker compose` stack; EP-4's `shomei-admin` CLI (every subcommand and flag);
  `shomei-migrations` (codd migrations); EP-3's `/health`, `/ready`, structured
  logging, `/metrics`, and graceful shutdown; `shomei-jwt`'s verifier and the
  `examples/microservice-auth-stack` demo (downstream local verification).

The binding obligation on this plan is the verification mandate stated throughout: each of
these surfaces must be **read at authoring time and confirmed by running the relevant
commands**, and any divergence between what this plan pre-wrote and what shipped is reconciled
in favor of reality, with the divergence logged in Surprises & Discoveries.

**Cross-plan concern (for the other plans to honor).** Because these docs describe the
finished public surface, several surfaces must stay stable once this plan is finalized, or the
docs silently drift: the route paths and JSON DTO shapes in `shomei-servant`/`shomei-server`
(api.md), the `ShomeiConfig` field names plus their Dhall paths and environment-variable names
in the EP-5 loader (deployment.md), the `shomei-admin` subcommand and flag names from EP-4
(deployment.md), the rate-limit/lockout default values from EP-2 (security.md and api.md), and
the signing-key lifecycle status names and JWKS overlap behavior from EP-4 (security.md and
deployment.md). Any change to those after EP-6 is finalized must update the corresponding
document in the same change.


## Revision Notes

2026-06-04: Updated after the package-layout refactor and MasterPlan audit. Documentation
requirements now describe top-level package directories and the `Shomei.Effect.*`
effect-interface namespace instead of the old nested package tree and the old Port namespace modules.

2026-06-17: Corrected the notifier descriptions to reflect that email sending was descoped from
EP-1 (`docs/plans/8-…` and MasterPlan 2's Decision Log): Shōmei emits notifications via the
`Notifier` effect and ships only the dev log-only sender; operators deliver them. Removed the
"SMTP sender" / "real PostgreSQL/JWT/SMTP" phrasings from the adoption-doc requirements. The
shipped docs (`docs/{architecture,api}.md`) already describe the log sender, so this is a
plan-prose correction only.

2026-06-17: Added a fifth adoption guide, `docs/notifications.md`, documenting how a downstream
service sends account-lifecycle email through its own provider by implementing a custom
`Notifier` effect interpreter (with the `Notification`/`Notifier` contract, a worked
provider-call example, the webhook variant, the wiring point in `Shomei.Server.App.runAppIO`,
and the fire-and-forget / in-process-Haskell caveats). Linked from `README.md` and
cross-referenced from `docs/architecture.md` and `docs/api.md`. This is the operator-facing
counterpart to the EP-1 descoping decision.
