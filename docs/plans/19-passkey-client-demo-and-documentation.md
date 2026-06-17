---
id: 19
slug: passkey-client-demo-and-documentation
title: "Passkey client, demo, and documentation"
kind: exec-plan
created_at: 2026-06-17T14:38:15Z
intention: "intention_01kvazmabnevhva7cq6ap01g95"
master_plan: "docs/masterplans/3-webauthn-passkey-multi-factor-authentication.md"
---

# Passkey client, demo, and documentation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. By the time this plan runs, four sibling plans
have already added **passkeys** (a passkey is a public-key credential held by the user's
device — a phone's Touch ID/Face ID, a Windows Hello sensor, a hardware key such as a
YubiKey, or a synced provider such as iCloud Keychain or 1Password) to the server. The
server can now enroll passkeys against an account, challenge for one as a second factor at
login (this is **multi-factor authentication**, "MFA": proving who you are with two
independent things — a password you *know* plus a device you *have*), and accept a passkey
on its own as a passwordless login. Those four plans are:

- **EP-1** (`docs/plans/15-webauthn-ceremony-port-and-shomei-webauthn-interpreter-package.md`)
  — the WebAuthn ceremony port, the passkey domain types, the new `shomei-webauthn` package,
  and the `webauthnConfig` sub-record on `ShomeiConfig`.
- **EP-2** (`docs/plans/16-passkey-and-pending-ceremony-persistence.md`) — the PostgreSQL and
  in-memory stores for passkeys and the short-lived ceremony state.
- **EP-3** (`docs/plans/17-passkey-enrollment-workflow-and-management-api.md`) — the
  authenticated enrollment/management HTTP routes (`POST /auth/passkeys/register/begin`,
  `…/register/complete`, `GET /auth/passkeys`, `DELETE /auth/passkeys/{passkeyId}`).
- **EP-4** (`docs/plans/18-passkey-login-mfa-step-up-and-passwordless.md`) — the MFA step-up
  login, the passwordless passkey login, and the widened login response.

This plan, **EP-5**, is the *adoption* layer. It does **not** add server behavior. It makes
that finished behavior usable and discoverable in three ways, each user-visible:

1. **A typed Haskell client.** A developer who depends on `shomei-client` gets new functions
   `passkeyRegisterBegin`, `passkeyRegisterComplete`, `listPasskeys`, `deletePasskey`,
   `mfaComplete`, `passkeyLoginBegin`, and `passkeyLoginComplete`, and an updated `login`
   whose return type now reflects that a password login may yield an MFA challenge instead of
   a token. After this milestone a developer can, in a few lines of Haskell, drive every
   passkey route against a running server.

2. **A runnable demo with a browser page.** The `examples/embedded-servant-app` demo gains a
   small static HTML+JavaScript page that runs the actual browser ceremonies
   (`navigator.credentials.create()` to enroll, `navigator.credentials.get()` to step up at
   login) against the demo's mounted `/auth` routes. After this milestone a human, in a real
   browser with a real authenticator, can enroll a passkey and then log in with password +
   passkey end to end.

3. **Documentation.** A new `docs/passkeys.md` explains passkeys/MFA in plain terms, walks
   the three ceremonies (enroll, step-up login, passwordless), documents every
   `webauthnConfig` setting with a copy-pasteable example, states the operator caveats
   (`rpId`/`origins` must match the real domain), and describes the security properties and
   the recovery story. `docs/api.md` gains the new endpoints with request/response JSON and
   status codes; `docs/security.md` gains the passkey threat model; `README.md` links the new
   guide.

To see the whole initiative working after this plan: build the client and call
`passkeyRegisterBegin`; open the demo page in a browser, enroll a passkey, log out, log in
with email + password, observe the `mfa_required` response, complete the assertion with your
device, and receive a token pair — then confirm that *not* completing the assertion yields no
usable token.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

**Preflight — confirm the consumed surface before writing anything:**

- [x] Confirm EP-1..EP-4 have landed on `master`: `ShomeiAPI` contains the seven new fields
      (`passkeyRegisterBegin`, `passkeyRegisterComplete`, `passkeyList`, `passkeyDelete`,
      `mfaComplete`, `passkeyLoginBegin`, `passkeyLoginComplete`) and `LoginResponse` is the
      tagged sum (`LoginCompleteResponse`/`LoginMfaRequiredResponse`). All DTO names and every
      `webauthnConfig` field match the plan verbatim. **One drift found:** `passkeyLoginComplete`
      returns `TokenPairResponse`, not `LoginResponse` (recorded in the Decision Log). No
      `mfaBegin` field exists (as expected). — 2026-06-17

**Milestone 1 — `shomei-client` passkey + MFA functions, updated `login`:**

- [x] Add the new DTO imports to `Shomei.Client` (`PasskeyRegisterBeginResponse`,
      `PasskeyRegisterCompleteRequest`, `PasskeyResponse`, `MfaCompleteRequest`,
      `PasskeyLoginBeginResponse`, `PasskeyLoginCompleteRequest`, and `PasskeyId` from
      `Shomei.Id`). — 2026-06-17
- [x] Add `passkeyRegisterBegin`, `passkeyRegisterComplete`, `listPasskeys`, `deletePasskey`
      (Bearer/`bearer`) to the module body and export list. — 2026-06-17
- [x] Add `mfaComplete`, `passkeyLoginBegin`, `passkeyLoginComplete` (unauthenticated) to the
      body and export list. `passkeyLoginComplete` returns `TokenPairResponse` (drift; see
      Decision Log). — 2026-06-17
- [x] Update `login`'s comment to note callers must handle the `mfa_required` arm; its
      signature is unchanged in Haskell (still returns `LoginResponse`) but `LoginResponse` is
      now a sum — confirmed and noted in the Decision Log. — 2026-06-17
- [x] Documented usage inline: each new wrapper carries a doc comment explaining when/how to
      call it, and `login`'s comment spells out the `mfa_required` → `mfaComplete` follow-up.
      A separate `shomei-client` test was not added (the end-to-end client/demo path is the
      human-run M3 walkthrough; EP-3/EP-4 already cover the server wire shapes in-process). — 2026-06-17
- [x] `cabal build all` green. — 2026-06-17

**Milestone 2 — documentation:**

- [x] Write `docs/passkeys.md` (the complete guide): concepts, the three ceremonies, the
      `webauthnConfig` table (Dhall keys + env vars + defaults), the rpId/origins operator
      caveat, security properties, recovery, browser glue, and the demo walkthrough. — 2026-06-17
- [x] Add the passkey/MFA endpoints to `docs/api.md` with request/response JSON and statuses,
      and update the `POST /auth/login` entry for the tagged response. — 2026-06-17
- [x] Add the passkey threat model to `docs/security.md`. — 2026-06-17
- [x] Link `docs/passkeys.md` from `README.md`'s docs list and mention passkeys/MFA in the
      README intro/feature list. Also added the `SHOMEI_WEBAUTHN_*` env vars and Dhall keys to
      `docs/deployment.md` (since EP-5 wired them). — 2026-06-17
- [x] Cross-check every endpoint, field name, status code, and config field in the docs
      against the merged code — all route fields, `webauthn*` Dhall keys, `SHOMEI_WEBAUTHN_*`
      env vars, and error codes (`ceremony_not_found`, `webauthn_verification_failed`,
      `passkey_not_found`, `mfa_failed`) report OK. — 2026-06-17

**Milestone 3 — demo enroll/login page:**

- [x] Created `examples/embedded-servant-app/www/` with `index.html`, `passkeys.js`,
      `style.css`, and a pointer `README.md`. — 2026-06-17
- [x] `passkeys.js` drives enroll + step-up login against the demo's `/auth` routes via
      `@github/webauthn-json` (CDN); `/auth/mfa/complete` returns a token pair directly. — 2026-06-17
- [x] Served the static directory from the demo: `Embedded.App.AppAPI` gains a trailing `Raw`
      route via `serveDirectoryWebApp`; the directory is `embeddedApplicationWith`'s parameter,
      read from `SHOMEI_DEMO_WWW` (default `www`) by the executable. — 2026-06-17
- [x] Wrote the manual end-to-end walkthrough into `docs/passkeys.md` (and a pointer in
      `www/README.md`). — 2026-06-17
- [x] `cabal build all` green; the demo test now also asserts `GET /index.html` → `200`,
      proving the `Raw` static route serves the page (and that the typed routes still work). — 2026-06-17


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **EP-4 (`docs/plans/18-…`) was still a skeleton when this plan was authored (2026-06-17).**
  At authoring time, `docs/plans/18-passkey-login-mfa-step-up-and-passwordless.md` contained
  only the empty section skeleton — its concrete route names, DTO names, and the exact shape
  of the widened `LoginResponse` were *not* yet written. The authoritative source for the
  MFA/login surface this plan documents and wraps is therefore the master plan
  (`docs/masterplans/3-webauthn-passkey-multi-factor-authentication.md`, sections Vision &
  Scope and Integration Points IP-4/IP-8) plus EP-3's confirmed enrollment DTO conventions.
  **Before implementing this plan, re-read EP-4 as merged and reconcile** the names used below
  (`mfaComplete`, `passkeyLoginBegin`, `passkeyLoginComplete`, `MfaCompleteRequest`,
  `PasskeyLoginBeginResponse`, `PasskeyLoginCompleteRequest`, and the `LoginResponse` tag
  field name) against what EP-4 actually shipped, fixing any drift in the client, the docs,
  and the demo, and recording it in the Decision Log. EP-1 (config) and EP-3 (enrollment)
  *were* fully written and their names are used verbatim below.

- **EP-4 reconciliation (the surface as merged matches this plan, with one drift).** Greps of
  the merged `shomei-servant/src/Shomei/Servant/API.hs`, `…/DTO.hs`, and
  `shomei-core/src/Shomei/Config.hs` (2026-06-17) confirm: the seven route fields, all DTO type
  names (`PasskeyRegisterBeginResponse`, `PasskeyRegisterCompleteRequest`, `PasskeyResponse`,
  `MfaCompleteRequest`, `PasskeyLoginBeginResponse`, `PasskeyLoginCompleteRequest`), the tagged
  `LoginResponse` (`LoginCompleteResponse`/`LoginMfaRequiredResponse` with the `status`
  discriminator), and every `WebAuthnConfig` field (`rpId`, `rpName`, `origins`,
  `userVerification`, `attestation`, `ceremonyTimeout`, `pendingCeremonyTTL`, `mfaRequired`)
  match this plan's assumptions verbatim. **The one drift:** `passkeyLoginComplete` returns
  `TokenPairResponse`, not `LoginResponse` (API.hs:185) — passwordless login IS the strong
  factor, so EP-4 returns tokens directly and never re-challenges. Handled in the Decision Log.
  `passkeyLoginBegin` is parameterless (no account-hint body) and there is no `mfaBegin` route.

- **`webauthnConfig` was never wired into the server config loader (a gap in EP-1).** Although
  EP-1 added the `WebAuthnConfig` record and `defaultWebAuthnConfig` to `shomei-core`, the
  server's `Shomei.Server.Config` loader (`FileConfig`, the Dhall schema
  `config/shomei-types.dhall`, and the `SHOMEI_*` env overlay) had **no** webauthn fields, so
  the effective RP identity was always the compiled `localhost` default — an operator could not
  set `rpId`/`origins` for a real domain without recompiling. This contradicts the MasterPlan
  Vision ("an operator can configure the Relying Party identity … loaded the same Dhall/env
  way as every other setting"). Per the user's decision (2026-06-17), EP-5 closed the gap:
  eight `webauthn*` fields added to `FileConfig` + the Dhall schema + `config/shomei.example.dhall`,
  a `mergeWebAuthn` Dhall-merge step, and a `SHOMEI_WEBAUTHN_*` env overlay (`overlayWebAuthnFromEnv`).
  Verified by an extended `shomei-server-config-test` (loads `rpId`/`origins`/`mfaRequired` from
  a Dhall file and proves a `SHOMEI_WEBAUTHN_*` env var overrides it). This is recorded as a
  cross-plan discovery in the MasterPlan too.

- **`serveDirectoryWebApp "www"` resolves relative to the process CWD, which the plan's
  walkthrough got wrong.** The plan hard-coded `serveDirectoryWebApp "www"` and a walkthrough
  that runs `cabal run embedded-servant-app` from the repository root — but `cabal run` launches
  the executable with CWD = the directory it was invoked from, so `./www` would resolve to
  `<repo-root>/www` (which does not exist) rather than `examples/embedded-servant-app/www`.
  Resolution: the www directory is now a parameter (`embeddedApplicationWith`), the executable
  reads it from `SHOMEI_DEMO_WWW` (default `www`), and the walkthrough instructs running from the
  package directory (or setting the env var to an absolute path). The `cabal test` harness runs
  with CWD = the package directory, so the default `www` resolves there — confirmed by the new
  `GET /index.html` → `200` assertion in `embedded-servant-app-test`.

- (Record further concrete evidence — compiler output, browser console transcripts — as you
  implement.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The Haskell type of `Shomei.Client.login` does **not** change, but its *meaning*
  does, because EP-4 widens the `LoginResponse` DTO (the value `login` returns) from the flat
  record `{ user, token }` to a tagged sum with a `status` discriminator: either
  `{ "status":"complete", "user":…, "token":… }` or
  `{ "status":"mfa_required", "ceremonyId":…, "options":… }`. `login :: ClientEnv ->
  LoginRequest -> IO (Either ClientError LoginResponse)` stays the same signature; callers must
  now pattern-match the `LoginResponse` sum and, on `mfa_required`, run the WebAuthn assertion
  in the browser and call `mfaComplete` with the `ceremonyId` and the browser's `assertion`
  JSON to obtain the token pair.
  Rationale: Deriving the client from `ShomeiAPI` via `genericClient` means the wire format is
  fixed by the server; the client function's Haskell signature only mentions the DTO type
  name, so widening the DTO (an EP-4 change in `Shomei.Servant.DTO`) automatically flows
  through `genericClient` without any change to `Shomei.Client`'s `login` definition. We update
  the doc comment and exports, not the signature. If EP-4 instead introduced a *new* response
  type for `login` (e.g. renamed the field to `LoginResult`), update the import and the
  `login` wrapper's return type accordingly and re-record here.
  Date: 2026-06-17

- Decision: Wire `webauthnConfig` into the server config loader as part of EP-5 (a scope
  expansion beyond "EP-5 adds no server behavior"), rather than only documenting the gap.
  EP-1 shipped the `WebAuthnConfig` type + default but never connected it to
  `Shomei.Server.Config`, so the RP identity was unconfigurable at runtime. The change adds the
  eight `webauthn*` optional fields to `FileConfig`, a pure `mergeWebAuthn :: WebAuthnConfig ->
  FileConfig -> WebAuthnConfig` applied in `baseFromFile`, an `overlayWebAuthnFromEnv` reading
  `SHOMEI_WEBAUTHN_RP_ID`/`RP_NAME`/`ORIGINS` (comma-separated)/`USER_VERIFICATION`/`ATTESTATION`/
  `CEREMONY_TIMEOUT`/`PENDING_TTL`/`MFA_REQUIRED`, plus the same eight fields on the Dhall schema
  `config/shomei-types.dhall` and `config/shomei.example.dhall`. WebAuthnConfig is read via
  record destructuring (its fields do not support `value.field` dot syntax under
  `DuplicateRecordFields`). `docs/passkeys.md` and `docs/deployment.md` therefore document a
  **working** config surface (both the Dhall keys and the env vars), not a non-functional one.
  Rationale: The user chose "Wire it now" when asked; the MasterPlan Vision promises operator
  configuration of the RP identity, and documenting non-functional config would violate the
  docs' implemented-behavior voice. Validated by the extended `shomei-server-config-test`.
  Date: 2026-06-17

- Decision: `passkeyLoginComplete` wraps a route returning `TokenPairResponse`, not
  `LoginResponse` as this plan originally assumed. EP-4 as merged declares
  `passkeyLoginComplete :: … :> Post '[JSON] TokenPairResponse` (`shomei-servant/src/Shomei/Servant/API.hs`),
  with the rationale (in EP-4's own route comment) that "the passkey IS the strong factor, so
  this returns a token pair directly (never an MFA challenge)." The client wrapper's return
  type is therefore `IO (Either ClientError TokenPairResponse)`, and `docs/api.md`/`docs/passkeys.md`
  document `POST /auth/login/passkey/complete` as returning a token pair
  (`{"accessToken","refreshToken","expiresIn"}`), not a tagged `LoginResponse`.
  Rationale: Prefer the merged EP-4 wire shape over the authoring-time assumption, per this
  plan's reconciliation rule. A passwordless passkey login cannot yield `mfa_required` (the
  passkey already satisfies the factor), so a flat token pair is the correct and simpler shape.
  Date: 2026-06-17

- Decision: The new authenticated client functions (`passkeyRegisterBegin`,
  `passkeyRegisterComplete`, `listPasskeys`, `deletePasskey`) take a `Token` and use the
  existing `bearer` helper, exactly like `me`/`session`/`logout`; the new unauthenticated
  functions (`mfaComplete`, `passkeyLoginBegin`, `passkeyLoginComplete`) take only their
  request body, exactly like `login`/`refresh`.
  Rationale: This mirrors the server's auth combinators: enrollment/management routes are
  `Authenticated` (Bearer), while the MFA-complete and passwordless routes are part of the
  login flow and therefore unauthenticated (the caller does not yet hold a token). The pattern
  is already established in `Shomei.Client` and must not diverge.
  Date: 2026-06-17

- Decision: Scope the demo (Milestone 3) to a **committed static HTML+JS page served by the
  demo, plus a documented manual browser walkthrough** — not an automated headless-browser
  test.
  Rationale: A WebAuthn ceremony fundamentally requires a real (or virtual) authenticator and
  a browser; it cannot be driven from Haskell or `curl` (the device signs a challenge the
  server picks). Shōmei is a server-side toolkit, so the server wiring already exists from
  EP-1..EP-4; what is missing for a human to *see* it is the browser glue. We deliver that glue
  as a small static page adapted from the `tweag/webauthn` library's own example
  (`server/www/unauthenticated.js`), retargeted to Shōmei's endpoints and bearer-token model,
  using the `@github/webauthn-json` browser helper (loaded from a CDN so the demo needs no
  bundler). An automated end-to-end test is explicitly out of scope; the acceptance is a human
  following the walkthrough with their own device (or a browser's virtual-authenticator
  devtools). The server-side request/response shapes are already covered by EP-3's and EP-4's
  in-process HTTP tests, so the demo adds no new server assertions.
  Date: 2026-06-17

- Decision: Serve the demo's static assets from a new directory
  `examples/embedded-servant-app/www/` via a `Raw` catch-all route mounted last in
  `Embedded.App.AppAPI` using `Servant.serveDirectoryWebApp`. If adding `wai-app-static` to the
  demo's dependencies is undesirable, fall back to documenting "serve `www/` with any static
  file server (e.g. `python3 -m http.server`) on the same origin as the demo" — but prefer the
  in-app `Raw` route so the page and the API share one origin (WebAuthn requires the page
  origin to match the configured `origins`/`rpId`).
  Rationale: WebAuthn ties the credential to the page's *origin*; serving the page from the
  same warp process as `/auth` guarantees the origin matches `webauthnConfig.origins` without
  extra proxy configuration. `serveDirectoryWebApp` is the standard Servant way to mount a
  static directory and adds only `wai-app-static`, already in the Shōmei dependency closure
  transitively. Mounting `Raw` *last* keeps it from shadowing the typed routes.
  Date: 2026-06-17

- Decision: Structure `docs/passkeys.md` as: (1) "What passkeys and MFA are" in plain terms;
  (2) "The three flows" (enroll, step-up login, passwordless) each as a numbered ceremony with
  the request/response at each step; (3) "Configuration" — every `webauthnConfig` field with a
  Dhall and an env example, and the `rpId`/`origins` operator caveat; (4) "Security
  properties"; (5) "Recovery" (password stays the first factor, so password-reset still
  recovers an account that has lost its passkey); (6) "Browser glue" (the `webauthn-json`
  helper and the demo page). It matches the tone of `docs/security.md` (implemented behavior,
  prose-first, fenced examples) and `docs/api.md` (per-endpoint request/response/status).
  Rationale: Mirrors the existing docs so the new guide reads as part of the same set, and
  orders the material from concept → usage → operator config → security → recovery, which is
  what an adopter reads top to bottom.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-17): all three milestones delivered; `cabal build all` and `cabal test all`
(11 suites) green.** The adoption layer is complete and matches the original purpose:

- **M1 — typed client.** `Shomei.Client` exports seven new derived wrappers
  (`passkeyRegisterBegin`, `passkeyRegisterComplete`, `listPasskeys`, `deletePasskey`,
  `mfaComplete`, `passkeyLoginBegin`, `passkeyLoginComplete`) plus a re-documented `login` whose
  `LoginResponse` is now a tagged sum. A developer can drive every passkey route from Haskell.
- **M2 — documentation.** `docs/passkeys.md` (concepts → three ceremonies → config → caveat →
  security → recovery → demo), the passkey/MFA section of `docs/api.md`, the threat model in
  `docs/security.md`, the env/Dhall reference in `docs/deployment.md`, and the README link/feature
  mention. Every endpoint, DTO field, status code, env var, and config key was grep-checked
  against the merged code.
- **M3 — demo.** A static enroll + step-up-login page (`examples/embedded-servant-app/www/`)
  served by the demo via a `Raw` `serveDirectoryWebApp` route, with a human walkthrough. The
  demo test asserts `GET /index.html` → `200`.

**Gaps / deviations from the original plan:**

- The plan declared "EP-5 adds no server behavior," but EP-1 had never wired `webauthnConfig`
  into the server config loader, so the documented config would have been non-functional. With
  the user's go-ahead, EP-5 closed that gap (FileConfig + Dhall schema + `SHOMEI_WEBAUTHN_*` env
  overlay), validated by an extended `shomei-server-config-test`. See the Decision Log.
- Two reconciliations against EP-4 as merged: `passkeyLoginComplete` returns `TokenPairResponse`
  (not `LoginResponse`), and `serveDirectoryWebApp "www"` needed a CWD-independent path
  (`SHOMEI_DEMO_WWW`). Both are recorded in the Decision Log / Surprises.

**Lessons:** (1) Reconcile a wrapper plan against the *merged* upstream surface before writing —
two assumptions had drifted. (2) `serveDirectoryWebApp` with a bare relative path is a footgun
for a demo launched from an arbitrary directory; make the path explicit. (3) A plan that only
"documents" a feature still has to verify the feature is actually wired end to end — the config
gap would have shipped as misleading docs otherwise.


## Context and Orientation

Shōmei is a Haskell authentication toolkit organized as a set of Cabal packages following a
**hexagonal** (ports-and-adapters) architecture: a transport-agnostic core (`shomei-core`),
infrastructure interpreters (`shomei-jwt`, `shomei-postgres`, and — added by EP-1 —
`shomei-webauthn`), the HTTP surface (`shomei-servant`), the assembled server
(`shomei-server`), and the adoption layer (`shomei-client`, `examples/`, `docs/`). This plan
touches only the adoption layer. You do not need to understand the WebAuthn library; you only
consume the finished routes and DTOs.

Key terms used below, defined once:

- *WebAuthn.* The browser standard for public-key login. The browser exposes two JavaScript
  calls: `navigator.credentials.create()` (make a new credential — enrollment) and
  `navigator.credentials.get()` (sign a challenge with an existing credential — login).
- *Ceremony.* One round-trip of WebAuthn: the server sends *options* (a JSON object including
  a random *challenge*), the browser calls `create`/`get`, and the browser returns a JSON
  *credential* (enrollment) or *assertion* (login) the server verifies. A registration
  ceremony enrolls; an authentication ceremony proves possession.
- *`webauthn-json`.* A tiny browser helper library (`@github/webauthn-json`) that converts
  between the base64url JSON the server speaks and the binary objects
  `navigator.credentials` expects. The demo loads it from a CDN. Its `create({publicKey: …})`
  and `get({publicKey: …})` wrap the raw browser calls and return plain JSON ready to POST.
- *Relying Party (RP).* The server's WebAuthn identity: an `rpId` (a registrable domain such
  as `auth.example.com`) and the allowed page `origins` (such as `https://auth.example.com`).
  These are set in `webauthnConfig` (EP-1). The browser refuses a ceremony whose page origin
  does not match.
- *Bearer token.* The access JWT the server returns from `/auth/login` (or `/auth/mfa/complete`
  for the MFA path). Authenticated routes require an `Authorization: Bearer <jwt>` header. In
  the client this is the `Token` newtype.
- *MFA step-up.* When a user who has a passkey logs in with email + password, the server does
  *not* return tokens immediately; it returns an MFA challenge (a `ceremonyId` plus WebAuthn
  authentication *options*). The browser runs `navigator.credentials.get()` and posts the
  result to `/auth/mfa/complete`; only then are tokens issued.

The files this plan reads and edits:

- `shomei-client/src/Shomei/Client.hs` — the typed client. Read it fully (it is short): it
  derives a `ShomeiClient` record from `ShomeiAPI` via `genericClient`, defines the `Token`
  newtype and the `bearer` helper for Bearer auth, and exposes thin `IO`-returning wrappers
  (`signup`, `login`, `refresh`, `logout`, `me`, `session`). New wrappers are added here in
  the identical style.
- `shomei-client/shomei-client.cabal` — its dependencies (`servant`, `servant-client`,
  `servant-client-core`, `shomei-core`, `shomei-servant`, `text`). No new dependency is
  needed; the new DTO names already live in `shomei-servant`.
- `examples/embedded-servant-app/` — the demo. `src/Embedded/App.hs` defines `AppAPI`
  (the whole `ShomeiAPI` mounted under `/auth` plus a guarded `/projects`), `app/Main.hs`
  boots it with warp, `test/Main.hs` drives `/projects` via the real client. The demo reuses
  `shomei-server`'s real assembly, so its `/auth` routes already include every passkey route.
- `docs/api.md`, `docs/security.md`, `docs/architecture.md`, `docs/deployment.md`,
  `README.md` — the existing docs. Read `docs/api.md` and `docs/security.md` first to match
  tone: implemented-behavior prose, per-endpoint request/response/status, fenced JSON.
- `docs/passkeys.md` — **new**, created by this plan.
- `examples/embedded-servant-app/www/` — **new** static-assets directory, created by this plan.

### The consumed contract (the finished EP-1..EP-4 surface)

This section is the single source of truth this plan wraps. It is reproduced verbatim from
EP-1 (config), EP-3 (enrollment, fully written) and the master plan IP-4/IP-8 (MFA/login,
because EP-4 was a skeleton at authoring time — see Surprises). **Reconcile against EP-4 as
merged before implementing.**

**Config — `Shomei.Config.WebAuthnConfig` (EP-1, `docs/plans/15-…`).** A sub-record
`webauthnConfig :: WebAuthnConfig` on `ShomeiConfig`, defaulted so old config still parses:

```haskell
data UserVerificationPolicy = UVRequired | UVPreferred | UVDiscouraged
data AttestationPolicy = AttestationNone | AttestationDirect

data WebAuthnConfig = WebAuthnConfig
    { rpId             :: !Text              -- registrable domain, e.g. "auth.example.com"
    , rpName           :: !Text              -- human label, e.g. "Example"
    , origins          :: ![Text]            -- allowed page origins, e.g. ["https://auth.example.com"]
    , userVerification :: !UserVerificationPolicy
    , attestation      :: !AttestationPolicy
    , ceremonyTimeout  :: !NominalDiffTime   -- browser ceremony timeout
    , pendingCeremonyTTL :: !NominalDiffTime -- how long a begun ceremony stays valid server-side
    , mfaRequired      :: !Bool              -- enforce MFA for accounts that have a passkey
    }
```

The default (`defaultWebAuthnConfig`): `rpId = "localhost"`, `rpName = "Shōmei"`,
`origins = ["http://localhost:8080"]`, `userVerification = UVPreferred`,
`attestation = AttestationNone`, `ceremonyTimeout = 300`, `pendingCeremonyTTL = 300`,
`mfaRequired = True`.

**Enrollment routes & DTOs (EP-3, `docs/plans/17-…`, all `Authenticated`/Bearer):**

- `POST /auth/passkeys/register/begin` → 200 `PasskeyRegisterBeginResponse
  { ceremonyId :: Text, options :: Value }` (empty request body; the principal is the bearer).
- `POST /auth/passkeys/register/complete` body `PasskeyRegisterCompleteRequest
  { ceremonyId :: Text, credential :: Value, label :: Maybe Text }` → 200 `PasskeyResponse`.
- `GET /auth/passkeys` → 200 `[PasskeyResponse]`.
- `DELETE /auth/passkeys/{passkeyId}` → 204 No Content.
- `PasskeyResponse { passkeyId :: Text, label :: Maybe Text, transports :: [Text],
  createdAt :: Text, lastUsedAt :: Maybe Text }` (never the public-key bytes).
- Error bodies: `404 {"error":"ceremony_not_found",…}` (missing/expired/consumed ceremony),
  `404 {"error":"passkey_not_found",…}` (delete of a passkey not owned by the caller),
  `400 {"error":"webauthn_verification_failed",…}` (verification failed).

**MFA/login routes & DTOs (EP-4, master-plan IP-4/IP-8 — reconcile against EP-4 as merged):**

- `POST /auth/login` now returns a **tagged** `LoginResponse`, one of:
  `{ "status":"complete", "user":{…}, "token":{"accessToken","refreshToken","expiresIn"} }` or
  `{ "status":"mfa_required", "ceremonyId":"webauthn_ceremony_…", "options":{…WebAuthn get options…} }`.
- `POST /auth/mfa/complete` body `MfaCompleteRequest { ceremonyId :: Text, assertion :: Value }`
  → 200 token pair (`TokenPairResponse { accessToken, refreshToken, expiresIn }`).
- `POST /auth/login/passkey/begin` → 200 `PasskeyLoginBeginResponse { ceremonyId :: Text,
  options :: Value }` (passwordless; empty body, may include an account hint per EP-4).
- `POST /auth/login/passkey/complete` body `PasskeyLoginCompleteRequest { ceremonyId :: Text,
  assertion :: Value }` → 200 the completed `LoginResponse` (`status:"complete"`).
- The master plan also names `POST /auth/mfa/begin` (re-issue the challenge); the client wraps
  `mfaComplete` and the begin/complete passwordless pair; wire `mfaBegin` too if EP-4 exposes
  it as a field (one extra wrapper mirroring `passkeyLoginBegin`).

The exact `options`/`credential`/`assertion` JSON values are the standard `webauthn-json`
browser payloads; the client and the demo pass them through verbatim as `aeson` `Value`s.


## Plan of Work

The work is three milestones in the order: **client** (M1), then **docs** (M2), then **demo**
(M3). Docs depend only on the finalized surface and so are written once EP-1..EP-4 land; the
client functions need the extended `ShomeiAPI` to compile, so M1 comes first to surface any
field-name drift early. The demo is last because it is the only piece requiring a real
browser and authenticator and is validated by a human, not by `cabal test`.


### Milestone 1 — `shomei-client` passkey + MFA functions and the updated `login`

**Scope.** At the end of this milestone, `shomei-client` exports seven new functions and an
updated-meaning `login`, all derived (so they "cannot disagree with the server"), and
`cabal build all` is green. What exists that did not before: a developer can drive every
passkey route from Haskell.

**Why this is "derived" and automatic.** `Shomei.Client` does **not** hand-write request
encoders. It defines `type ShomeiClient = ShomeiAPI (AsClientT ClientM)` and
`shomeiClient = genericClient`. `genericClient` (from `servant-client`'s `Servant.Client.Generic`)
inspects the `ShomeiAPI` `NamedRoutes` record *type* and produces one client function per
field, each with exactly the request/response types that field's route declares. So the moment
EP-3/EP-4 added the seven new fields to `ShomeiAPI`, `shomeiClient` *already* contains the
seven matching client functions — there is nothing to generate by hand. This plan only adds
thin `IO`-returning wrappers around them (for ergonomics and to attach the bearer token),
mirroring the existing `signup`/`me`/etc. wrappers, and adds the new symbols to the export
list and the DTO import list. Because the functions come from the API type, they cannot drift
from the server's wire format.

**Step 1.1 — extend the imports.** In `shomei-client/src/Shomei/Client.hs`, extend the
`Shomei.Servant.DTO` import with the new DTO names and add a `Shomei.Id (PasskeyId)` import
(needed for the `deletePasskey` capture). The full import edit:

```haskell
import Shomei.Id (PasskeyId)
import Shomei.Servant.DTO (
    LoginRequest,
    LoginResponse,
    MfaCompleteRequest,
    PasskeyLoginBeginResponse,
    PasskeyLoginCompleteRequest,
    PasskeyRegisterBeginResponse,
    PasskeyRegisterCompleteRequest,
    PasskeyResponse,
    RefreshRequest,
    SessionResponse,
    SignupRequest,
    SignupResponse,
    TokenPairResponse,
    UserResponse,
 )
```

If EP-4 named the MFA request DTO differently (e.g. `MfaCompletionRequest`) or used a
distinct passwordless-complete response type, adjust these names and record it in the Decision
Log. The `PasskeyLoginBeginResponse`/`PasskeyLoginCompleteRequest` names mirror EP-3's
`PasskeyRegisterBeginResponse`/`PasskeyRegisterCompleteRequest` convention; keep whatever EP-4
shipped.

**Step 1.2 — extend the export list.** Add the seven new names to the module's export list,
next to the existing client wrappers:

```haskell
module Shomei.Client (
    Token (..),
    ShomeiClient,
    shomeiClient,
    shomeiClientEnv,
    runClient,
    ClientEnv,
    ClientError,
    signup,
    login,
    refresh,
    logout,
    me,
    session,
    -- passkey enrollment / management (Bearer):
    passkeyRegisterBegin,
    passkeyRegisterComplete,
    listPasskeys,
    deletePasskey,
    -- passkey login / MFA (unauthenticated):
    mfaComplete,
    passkeyLoginBegin,
    passkeyLoginComplete,
) where
```

**Step 1.3 — add the authenticated passkey wrappers.** After the existing `session` wrapper,
add the four enrollment/management wrappers. They follow `me`/`session`/`logout` exactly:
they take a `Token`, build the `AuthenticatedRequest` with `bearer`, and call the
correspondingly-named field selector on `shomeiClient`. Field selectors are reached via the
qualified `API.` prefix (the existing file explains why: a `NamedRoutes` field type is a
`(:-)` type-family application that record-dot's `HasField` cannot see through, so selector
application is used instead of `OverloadedRecordDot`).

```haskell
-- | Begin enrolling a passkey (authenticated). Returns the ceremony id and the WebAuthn
-- creation @options@ the browser feeds to @navigator.credentials.create()@.
passkeyRegisterBegin ::
    ClientEnv -> Token -> IO (Either ClientError PasskeyRegisterBeginResponse)
passkeyRegisterBegin env tok =
    runClient env (API.passkeyRegisterBegin shomeiClient (bearer tok))

-- | Complete passkey enrollment (authenticated): submit the browser's credential JSON and an
-- optional label. Returns the stored passkey.
passkeyRegisterComplete ::
    ClientEnv -> Token -> PasskeyRegisterCompleteRequest -> IO (Either ClientError PasskeyResponse)
passkeyRegisterComplete env tok body =
    runClient env (API.passkeyRegisterComplete shomeiClient (bearer tok) body)

-- | List the caller's enrolled passkeys (authenticated). Never includes public-key bytes.
listPasskeys ::
    ClientEnv -> Token -> IO (Either ClientError [PasskeyResponse])
listPasskeys env tok =
    runClient env (API.passkeyList shomeiClient (bearer tok))

-- | Remove one of the caller's passkeys by id (authenticated). 404 if it is not theirs.
deletePasskey ::
    ClientEnv -> Token -> PasskeyId -> IO (Either ClientError ())
deletePasskey env tok pid =
    fmap (fmap (const ())) (runClient env (API.passkeyDelete shomeiClient (bearer tok) pid))
```

The `deletePasskey` wrapper drops the `NoContent` result to `()`, mirroring how `logout`
collapses its result. The `passkeyDelete` route field on `ShomeiClient` returns
`ClientM NoContent`; `fmap (const ())` over the `Either` yields `()`.

**Step 1.4 — add the MFA / passwordless wrappers.** These are unauthenticated (the caller
does not yet hold a token), so they take only their request body and mirror `login`/`refresh`:

```haskell
-- | Complete an MFA step-up: after @login@ returned @status:"mfa_required"@, the browser runs
-- @navigator.credentials.get()@ and this submits the @ceremonyId@ + the @assertion@ JSON.
-- Returns the access/refresh token pair.
mfaComplete ::
    ClientEnv -> MfaCompleteRequest -> IO (Either ClientError TokenPairResponse)
mfaComplete env body = runClient env (API.mfaComplete shomeiClient body)

-- | Begin a passwordless passkey login. Returns the ceremony id and the WebAuthn @options@
-- the browser feeds to @navigator.credentials.get()@.
passkeyLoginBegin ::
    ClientEnv -> IO (Either ClientError PasskeyLoginBeginResponse)
passkeyLoginBegin env = runClient env (API.passkeyLoginBegin shomeiClient)

-- | Complete a passwordless passkey login: submit the @ceremonyId@ + the browser's
-- @assertion@ JSON. Returns a completed login response (@status:"complete"@).
passkeyLoginComplete ::
    ClientEnv -> PasskeyLoginCompleteRequest -> IO (Either ClientError LoginResponse)
passkeyLoginComplete env body = runClient env (API.passkeyLoginComplete shomeiClient body)
```

If EP-4's `POST /auth/login/passkey/begin` takes a body (an account hint), give
`passkeyLoginBegin` a body parameter matching that DTO; otherwise it is parameterless as
shown. If EP-4 exposes a `mfaBegin` route field, add a parallel `mfaBegin` wrapper. Record the
final shape in the Decision Log when reconciling.

**Step 1.5 — update the `login` comment.** `login`'s definition is unchanged:

```haskell
-- | Log in with email + password.
--
-- IMPORTANT: the returned 'LoginResponse' is a tagged sum (EP-4). On @status:"complete"@ it
-- carries @user@ + @token@. On @status:"mfa_required"@ it carries a @ceremonyId@ and WebAuthn
-- @options@: the account has a passkey, so the caller must run the assertion in the browser and
-- call 'mfaComplete' with the @ceremonyId@ and the browser's @assertion@ JSON to obtain tokens.
login :: ClientEnv -> LoginRequest -> IO (Either ClientError LoginResponse)
login env body = runClient env (API.login shomeiClient body)
```

**Step 1.6 — a usage snippet (acceptance evidence).** The `shomei-client` test suite already
boots the embedded demo over an ephemeral PostgreSQL and drives signup/login through the real
client (see `examples/embedded-servant-app/test/Main.hs` for the pattern). Either (a) add a
test there that calls `passkeyRegisterBegin` and asserts a 200 + a non-empty `ceremonyId`
(enrollment *begin* needs no authenticator — only *complete* does), and that a fresh login for
a passkey-less account still returns `status:"complete"`; or (b) if extending the harness is
out of scope for M1, embed this copy-pasteable snippet in the `Shomei.Client` module haddock so
the usage is documented:

```haskell
-- Usage (against a running shomei-server at http://localhost:8080):
--
-- > env <- shomeiClientEnv "http://localhost:8080"
-- > Right lr  <- login env (LoginRequest "ada@example.com" "…")
-- > -- inspect lr: on mfa_required, drive the browser, then:
-- > Right tok <- mfaComplete env (MfaCompleteRequest ceremonyId assertionValue)
-- >
-- > -- enrollment (with a bearer Token from a completed login):
-- > Right beginR <- passkeyRegisterBegin env (Token access)
-- > -- feed beginR.options to navigator.credentials.create() in a browser, then:
-- > Right pk <- passkeyRegisterComplete env (Token access)
-- >                 (PasskeyRegisterCompleteRequest beginR.ceremonyId credentialValue (Just "YubiKey"))
-- > Right pks <- listPasskeys env (Token access)
-- > Right ()  <- deletePasskey env (Token access) pk.passkeyId   -- pk.passkeyId parsed to PasskeyId
```

(The snippet's `pk.passkeyId` is `Text` in `PasskeyResponse`; to call `deletePasskey` parse it
to `PasskeyId` with `Shomei.Id.parseId`, or keep the id from a prior typed source. State this
in the doc comment.)

**Acceptance for Milestone 1.** From the repository root `/Users/shinzui/Keikaku/bokuno/shomei`
inside `nix develop`, `cabal build all` is green. The seven new symbols are exported from
`Shomei.Client` (confirm with `cabal repl shomei-client` then `:browse Shomei.Client`, which
lists `passkeyRegisterBegin`, `passkeyRegisterComplete`, `listPasskeys`, `deletePasskey`,
`mfaComplete`, `passkeyLoginBegin`, `passkeyLoginComplete`). If a client test was added, the
`shomei-client` suite passes and shows `passkeyRegisterBegin` returning a 200 with a
non-empty `ceremonyId` against the in-process demo server.

**Every changed export (enumerated, as required):** added to the `Shomei.Client` export list —
`passkeyRegisterBegin`, `passkeyRegisterComplete`, `listPasskeys`, `deletePasskey`,
`mfaComplete`, `passkeyLoginBegin`, `passkeyLoginComplete`. Unchanged but re-documented:
`login` (same signature, widened-meaning `LoginResponse`). No export is removed.


### Milestone 2 — documentation (`docs/passkeys.md` + `api.md`/`security.md` + README)

**Scope.** At the end of this milestone, a developer can read `docs/passkeys.md` and
correctly use every passkey/MFA endpoint and config field; `docs/api.md` lists the new
endpoints with copy-pasteable `curl`; `docs/security.md` states the passkey threat model; and
`README.md` links the guide and mentions the feature. What exists that did not before: the
finished feature is documented and discoverable. Acceptance is that every endpoint, field,
status code, and config name in the docs matches EP-1..EP-4 as merged (cross-checked).

**Step 2.1 — create `docs/passkeys.md`.** Use the structure from the Decision Log. Write it in
the existing docs' voice (implemented behavior, prose-first, fenced examples). The complete
content to author:

The opening, in plain terms:

```text
# Passkeys & Multi-Factor Authentication

A *passkey* is a public-key credential your device holds — Touch ID/Face ID on a phone or
Mac, Windows Hello, a hardware key like a YubiKey, or a synced provider like iCloud Keychain
or 1Password. The private key never leaves the device; Shōmei stores only the matching public
key. *Multi-factor authentication* (MFA) means proving who you are with two independent
things: a password you know, plus a device you have. After enrolling a passkey, a Shōmei
account is protected by both — a stolen password alone no longer grants a session.

Shōmei uses passkeys two ways: as a **second factor** on top of the password (the default,
"step-up"), and as a **passwordless** login on their own. Enrollment always happens while
already logged in.
```

Then "The three flows", each a numbered ceremony. Enrollment (note: begin is authenticated,
empty body; the browser turns `options` into a credential; complete stores it):

```text
## 1. Enrolling a passkey (authenticated)

1. The browser POSTs to `/auth/passkeys/register/begin` with the user's bearer token and an
   empty body. The server replies with `{ "ceremonyId": "...", "options": { ... } }`. `options`
   is the WebAuthn *creation options* — a random challenge, the relying-party id, the user's
   handle, and the list of already-enrolled credentials to exclude.
2. The browser calls `navigator.credentials.create({ publicKey: options.publicKey })` (via the
   `@github/webauthn-json` helper, which handles the base64url ↔ binary conversion). The device
   prompts the user (a fingerprint, a PIN, a tap) and mints a fresh key pair.
3. The browser POSTs to `/auth/passkeys/register/complete` with the bearer token and
   `{ "ceremonyId": "<from step 1>", "credential": <the create() output>, "label": "Ada's
   YubiKey" }`. The server verifies the credential and stores the public key, returning the
   stored passkey `{ "passkeyId", "label", "transports", "createdAt", "lastUsedAt" }`.

List with `GET /auth/passkeys`; remove one with `DELETE /auth/passkeys/{passkeyId}` (204).
```

Step-up login:

```text
## 2. Logging in with password + passkey (MFA step-up)

1. POST `/auth/login` with `{ "email", "password" }` as usual. If the account has a passkey
   (and `mfaRequired` is on), the response is **not** tokens — it is
   `{ "status": "mfa_required", "ceremonyId": "...", "options": { ... } }`, where `options` is
   the WebAuthn *authentication options* (a fresh challenge plus the allowed credentials).
   An account *without* a passkey still gets `{ "status": "complete", "user", "token" }`.
2. The browser calls `navigator.credentials.get({ publicKey: options.publicKey })`. The device
   signs the challenge with the passkey's private key.
3. POST `/auth/mfa/complete` with `{ "ceremonyId": "<from step 1>", "assertion": <the get()
   output> }`. The server verifies the signature and returns the access/refresh token pair.

If step 3 is never performed (or fails), no usable token is ever issued — possession of the
password alone does not grant a session.
```

Passwordless:

```text
## 3. Passwordless passkey login

1. POST `/auth/login/passkey/begin` (no password). The response is
   `{ "ceremonyId": "...", "options": { ... } }` — WebAuthn authentication options for
   discoverable credentials.
2. The browser calls `navigator.credentials.get({ publicKey: options.publicKey })`.
3. POST `/auth/login/passkey/complete` with `{ "ceremonyId": "...", "assertion": <get()
   output> }`. On success the response is `{ "status": "complete", "user", "token" }`.
```

Configuration — every `webauthnConfig` field, with examples. Match the env/Dhall style of
`docs/deployment.md`. Dhall example:

```dhall
-- in your Shōmei config (the webauthnConfig sub-record)
{ rpId = "auth.example.com"          -- your registrable domain (no scheme, no port)
, rpName = "Example"                 -- shown by the authenticator UI
, origins = [ "https://auth.example.com" ]  -- exact page origins allowed to run ceremonies
, userVerification = "UVPreferred"   -- UVRequired | UVPreferred | UVDiscouraged
, attestation = "AttestationNone"    -- AttestationNone | AttestationDirect
, ceremonyTimeout = 300.0            -- seconds the browser ceremony may take
, pendingCeremonyTTL = 300.0         -- seconds a begun ceremony stays valid server-side
, mfaRequired = True                 -- require the second factor for accounts that have a passkey
}
```

Env-var example (matching how `docs/deployment.md` documents other settings):

```bash
SHOMEI_WEBAUTHN_RP_ID=auth.example.com
SHOMEI_WEBAUTHN_RP_NAME=Example
SHOMEI_WEBAUTHN_ORIGINS=https://auth.example.com
SHOMEI_WEBAUTHN_USER_VERIFICATION=preferred
SHOMEI_WEBAUTHN_ATTESTATION=none
SHOMEI_WEBAUTHN_MFA_REQUIRED=true
```

(When writing this, read `shomei-server/src/Shomei/Server/Config.hs` as merged to use the
*actual* env-var names EP-1's loader added; the names above are the convention to confirm. If
EP-1 wired only Dhall loading and not env overrides for these fields, document Dhall only and
note it.)

The operator caveat (call it out prominently):

```text
## Operator caveat: rpId and origins must match your real domain

The defaults (`rpId = "localhost"`, `origins = ["http://localhost:8080"]`) work only for local
development. In production you **must** set `rpId` to your registrable domain (e.g.
`auth.example.com`) and `origins` to the exact origin(s) your login page is served from (e.g.
`https://auth.example.com`). The browser refuses any ceremony whose page origin is not in
`origins`, and a passkey enrolled under one `rpId` cannot be used under another. Set these
before enrolling any passkeys; changing `rpId` later invalidates every existing passkey.
```

Security properties (cross-link to `docs/security.md`):

```text
## Security properties

- **Phishing resistance.** The signature is bound to the page origin and the rpId, so a
  credential created for `auth.example.com` cannot be replayed against a look-alike site.
- **Consume-once challenge.** Each ceremony's challenge is stored once (PostgreSQL-backed) and
  deleted when consumed; a replayed `complete` finds nothing and fails.
- **Clone detection.** Each credential carries a signature counter that must increase; a
  decrease signals a cloned authenticator and is rejected.
- **No secrets stored.** Shōmei stores only public keys; a database leak reveals nothing that
  can impersonate a user.
```

Recovery (the required recovery story):

```text
## Recovery: losing a passkey

The **password remains the first factor**. A user who loses their only passkey is not locked
out of recovery: the existing password-reset flow
(`POST /auth/password-reset/request` → `…/confirm`) still works, because reset is gated on the
password/email, not the passkey. After a reset, the user can remove the lost passkey
(`DELETE /auth/passkeys/{passkeyId}`) and enroll a new one. Backup/recovery codes are not part
of this release (deferred); having **two** passkeys enrolled is the recommended hedge.
```

Browser glue (point to the demo):

```text
## Browser glue

The browser side uses `@github/webauthn-json`, which converts between the base64url JSON
Shōmei speaks and the binary objects `navigator.credentials` needs. A complete, runnable
enroll + step-up-login page lives in `examples/embedded-servant-app/www/` — see the demo
walkthrough below.
```

**Step 2.2 — extend `docs/api.md`.** Add a section after "Account lifecycle (EP-1)" (match
that file's per-endpoint one-line style). Include the `mfa_required` login note and the JSON
shapes:

```markdown
## Passkeys & MFA (MasterPlan 3)

`POST /auth/login` now returns a **tagged** response: either `{"status":"complete","user":{…},
"token":{…}}` (accounts with no passkey, unchanged behavior) or `{"status":"mfa_required",
"ceremonyId":"…","options":{…}}` (the account has a passkey — complete the WebAuthn assertion to
get tokens). All `options`/`credential`/`assertion` values are standard `webauthn-json` JSON.

### `POST /auth/passkeys/register/begin` *(authenticated)*
Empty body. → `200` `{"ceremonyId":"webauthn_ceremony_…","options":{…creation options…}}`.

### `POST /auth/passkeys/register/complete` *(authenticated)*
Body `{"ceremonyId","credential",label?}`. → `200` `{"passkeyId","label","transports",
"createdAt","lastUsedAt"}`. `404 ceremony_not_found` (missing/expired/consumed);
`400 webauthn_verification_failed` (verification failed).

### `GET /auth/passkeys` *(authenticated)*
→ `200` an array of the `PasskeyResponse` object above (never the public-key bytes).

### `DELETE /auth/passkeys/{passkeyId}` *(authenticated)*
→ `204`. `404 passkey_not_found` if the passkey is not owned by the caller.

### `POST /auth/mfa/complete`
Body `{"ceremonyId","assertion"}`. → `200` `{"accessToken","refreshToken","expiresIn"}`.
`404 ceremony_not_found`; `400 webauthn_verification_failed`.

### `POST /auth/login/passkey/begin`
Empty body (passwordless). → `200` `{"ceremonyId","options"}`.

### `POST /auth/login/passkey/complete`
Body `{"ceremonyId","assertion"}`. → `200` `{"status":"complete","user","token"}`.
```

(Confirm exact error codes/status against EP-3/EP-4 as merged; reconcile if they differ.)

**Step 2.3 — extend `docs/security.md`.** Add a "Passkeys & MFA" section after "Session
revocation", in that file's implemented-behavior voice:

```markdown
## Passkeys & MFA (MasterPlan 3)

- **Phishing-resistant second factor.** A passkey signs a server challenge bound to the page
  origin and the configured `rpId`; the signature cannot be replayed against another origin, so
  a phished password alone never yields a session. Accounts that have a passkey are challenged
  for it at login when `webauthnConfig.mfaRequired` is set.
- **Consume-once challenge.** The pending-ceremony state (the challenge/options blob) is
  **PostgreSQL-backed** and consumed exactly once: `complete` deletes the row, so a replayed or
  duplicated completion finds nothing and is rejected (`404 ceremony_not_found`). Ceremonies
  expire via a TTL (`pendingCeremonyTTL`).
- **Signature-counter clone check.** Each stored credential keeps a signature counter; a
  verification whose counter does not advance past the stored value signals a cloned
  authenticator and is rejected.
- **Public keys only.** Shōmei stores only the credential's public key and metadata — never a
  private key or any reusable secret. A database leak cannot impersonate a user.
- **MFA enforcement policy.** Enforcement is gated on per-account enrollment *and*
  `mfaRequired`: an account with no passkey (or with `mfaRequired = False`) logs in exactly as
  before. The password remains the first factor, so password-reset still recovers an account
  whose passkey was lost.
```

**Step 2.4 — README.** Add a doc link in the docs list and a feature mention:

```markdown
- [docs/passkeys.md](docs/passkeys.md) — passkeys & multi-factor login: the enroll, step-up,
  and passwordless ceremonies, the `webauthnConfig` settings, and the security model.
```

And in the intro/feature list, add "passkey enrollment and WebAuthn multi-factor (step-up and
passwordless) login" alongside the existing account-lifecycle features.

**Acceptance for Milestone 2.** `docs/passkeys.md` exists and is internally consistent;
`docs/api.md` and `docs/security.md` carry the new sections; `README.md` links the guide.
Every endpoint path, DTO field name, status code, and `webauthnConfig` field in the docs
matches the merged EP-1..EP-4 code (verify by grepping the merged `Shomei.Servant.API`,
`Shomei.Servant.DTO`, and `Shomei.Config` for each name you wrote). A reader can copy a `curl`
from `docs/api.md` and a config block from `docs/passkeys.md` and have them be correct.


### Milestone 3 — the demo enroll/login page (browser glue + walkthrough)

**Scope.** At the end of this milestone, the `examples/embedded-servant-app` demo serves a
static page that runs the real enroll and step-up-login ceremonies in a browser against its
own mounted `/auth` routes, and `docs/passkeys.md` carries a manual end-to-end walkthrough.
What exists that did not before: a human with a real (or virtual) authenticator can see the
whole MasterPlan-3 feature working in a browser. This milestone is validated by a human, not
by `cabal test` (a WebAuthn ceremony needs a real device).

**Step 3.1 — create the static directory and page.** Create
`examples/embedded-servant-app/www/` with three files. The JavaScript is adapted from the
`tweag/webauthn` library's `server/www/unauthenticated.js`, retargeted to Shōmei's endpoints,
its bearer-token model, and the `{ceremonyId, credential|assertion}` body shape, loading
`@github/webauthn-json` from a CDN (so no bundler is needed).

`examples/embedded-servant-app/www/index.html`:

```html
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Shōmei Passkey Demo</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <h1>Shōmei passkey demo</h1>

  <section>
    <h2>1. Log in (password)</h2>
    <input id="email" placeholder="email" autocomplete="username">
    <input id="password" type="password" placeholder="password" autocomplete="current-password">
    <button id="loginBtn">Log in</button>
  </section>

  <section>
    <h2>2. Enroll a passkey (needs a logged-in token)</h2>
    <input id="label" placeholder="label (optional), e.g. My YubiKey">
    <button id="enrollBtn" disabled>Enroll passkey</button>
  </section>

  <section>
    <h2>3. Step-up login (password → passkey)</h2>
    <p>Logging in above for an account that has a passkey returns <code>mfa_required</code>;
       this page then runs the assertion automatically.</p>
  </section>

  <pre id="log"></pre>
  <script type="module" src="passkeys.js"></script>
</body>
</html>
```

`examples/embedded-servant-app/www/passkeys.js` (adapted from the library example; comments
explain each retargeting):

```javascript
// @github/webauthn-json from a CDN: create()/get() wrap navigator.credentials and do the
// base64url <-> binary conversion, returning plain JSON ready to POST.
import { create, get, supported }
  from "https://unpkg.com/@github/webauthn-json@2.1.1/dist/esm/webauthn-json.js";

const logEl = document.getElementById("log");
const log = (m) => { logEl.textContent += m + "\n"; };

// The bearer access token from a completed login, held in memory for the enroll step.
let accessToken = null;

async function postJSON(path, body, auth) {
  const headers = { "Content-Type": "application/json" };
  if (auth) headers["Authorization"] = "Bearer " + auth;
  const res = await fetch(path, { method: "POST", headers, body: JSON.stringify(body) });
  return { ok: res.ok, status: res.status, json: res.ok ? await res.json() : await res.text() };
}

// --- Step 1 + 3: log in with password; if MFA is required, run the assertion (step-up). ---
document.getElementById("loginBtn").addEventListener("click", async () => {
  if (!supported()) { alert("WebAuthn is not supported on this device"); return; }
  const email = document.getElementById("email").value;
  const password = document.getElementById("password").value;

  const r = await postJSON("/auth/login", { email, password });
  if (!r.ok) { log("login failed: " + r.json); return; }

  if (r.json.status === "complete") {
    accessToken = r.json.token.accessToken;
    log("logged in (no passkey on this account). Enroll one below.");
  } else if (r.json.status === "mfa_required") {
    log("password ok — passkey required, running assertion…");
    // r.json.options is the WebAuthn get() options the server chose.
    const assertion = await get({ publicKey: r.json.options.publicKey });
    const c = await postJSON("/auth/mfa/complete",
      { ceremonyId: r.json.ceremonyId, assertion });
    if (!c.ok) { log("mfa complete failed: " + c.json); return; }
    accessToken = c.json.accessToken;
    log("MFA complete — tokens issued.");
  }
  document.getElementById("enrollBtn").disabled = (accessToken === null);
});

// --- Step 2: enroll a passkey (authenticated with the bearer token). ---
document.getElementById("enrollBtn").addEventListener("click", async () => {
  if (!supported()) { alert("WebAuthn is not supported on this device"); return; }
  if (!accessToken) { log("log in first"); return; }
  const label = document.getElementById("label").value;

  const b = await postJSON("/auth/passkeys/register/begin", {}, accessToken);
  if (!b.ok) { log("register/begin failed: " + b.json); return; }

  // b.json.options is the WebAuthn create() options the server chose.
  const credential = await create({ publicKey: b.json.options.publicKey });

  const c = await postJSON("/auth/passkeys/register/complete",
    { ceremonyId: b.json.ceremonyId, credential, label }, accessToken);
  if (!c.ok) { log("register/complete failed: " + c.json); return; }
  log("passkey enrolled: " + c.json.passkeyId + " (" + (c.json.label ?? "no label") + ")");
});
```

`examples/embedded-servant-app/www/style.css` (minimal, adapted from the library example):

```css
body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; }
section { border: 1px solid #ddd; border-radius: 6px; padding: 1rem; margin: 1rem 0; }
input { display: block; margin: 0.25rem 0; padding: 0.4rem; width: 100%; box-sizing: border-box; }
button { padding: 0.5rem 1rem; }
#log { background: #111; color: #0f0; padding: 1rem; border-radius: 6px; min-height: 4rem; white-space: pre-wrap; }
```

**Step 3.2 — serve the page from the demo.** In
`examples/embedded-servant-app/src/Embedded/App.hs`, mount the `www/` directory as a `Raw`
catch-all *after* the typed routes so it does not shadow them. Add to `AppAPI`:

```haskell
import Servant (Raw)
import Servant.Server.StaticFiles (serveDirectoryWebApp)

type AppAPI =
    NamedRoutes ShomeiAPI
        :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
        :<|> Raw   -- static demo assets from ./www, served last

embeddedApplication :: Env -> Application
embeddedApplication env =
    serveWithContext (Proxy @AppAPI) (authContext senv)
        (shomeiServer senv :<|> projectsHandler :<|> serveDirectoryWebApp "www")
  where
    senv = seamEnv env
```

Add `wai-app-static` (for `serveDirectoryWebApp`, re-exported by `servant-server`'s
`Servant.Server.StaticFiles`) to the demo library's `build-depends` in
`examples/embedded-servant-app/embedded-servant-app.cabal` if not already present (it is in
the `servant-server` closure; add it explicitly if the build complains). The page is then at
`http://localhost:8080/index.html` when the demo runs, on the same origin as `/auth`.

Confirm the existing `embedded-servant-app-test` still passes (it drives `/projects`; the new
`Raw` route is mounted last and does not affect it). If `serveWithContext` arity or the
`:<|>` nesting needs adjusting for the third handler, follow the existing two-handler pattern
and append the third.

**Step 3.3 — the manual walkthrough.** Add a "Demo walkthrough" section to `docs/passkeys.md`
(and a pointer from the demo's directory). It must let a human reproduce the whole feature:

```text
## Demo walkthrough (real browser + authenticator)

1. Start the demo against your dev database (it reuses the real shomei-server assembly, so
   every /auth route — including passkeys — is live):

     PG_CONNECTION_STRING="host=$PGHOST dbname=shomei user=$(id -un)" \
       cabal run embedded-servant-app

   The default webauthnConfig has rpId="localhost" and origins=["http://localhost:8080"], which
   matches the demo's own origin, so no config change is needed for localhost.

2. Open http://localhost:8080/index.html in a browser that supports passkeys (Chrome, Safari,
   Firefox). If you have no hardware authenticator, enable Chrome DevTools → "WebAuthn" →
   "Add virtual authenticator" to simulate one.

3. Create an account first (the demo has no signup form; use curl):

     curl -s -X POST http://localhost:8080/auth/signup -H 'content-type: application/json' \
       -d '{"email":"ada@example.com","password":"correct horse battery staple","displayName":"Ada"}'

4. On the page, log in with that email + password. Because the account has no passkey yet, you
   see "logged in (no passkey…)" and the Enroll button enables.

5. Click "Enroll passkey", approve the device prompt (or the virtual authenticator), and see
   "passkey enrolled: passkey_…".

6. Reload the page and log in again with the same email + password. This time the server
   returns mfa_required, the page runs the assertion automatically, your device prompts, and
   you see "MFA complete — tokens issued." That is the second factor working: the password
   alone did not issue a token until the passkey signed the challenge.
```

**Acceptance for Milestone 3.** `cabal build all` is green and `cabal run embedded-servant-app`
serves `http://localhost:8080/index.html`. A human following the walkthrough with a real or
virtual authenticator can: log in by password, enroll a passkey, then on a second login observe
`mfa_required` and complete the assertion to receive tokens — and observe that abandoning the
assertion yields no usable token. The existing `embedded-servant-app-test` still passes.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside
`nix develop` (the project's GHC 9.12.4 toolchain).

Preflight — confirm the consumed surface is merged:

```bash
# The seven new ShomeiAPI fields and the tagged LoginResponse must exist.
grep -nE 'passkeyRegisterBegin|passkeyRegisterComplete|passkeyList|passkeyDelete|mfaComplete|passkeyLoginBegin|passkeyLoginComplete' \
  shomei-servant/src/Shomei/Servant/API.hs
grep -nE 'PasskeyRegisterBeginResponse|PasskeyRegisterCompleteRequest|PasskeyResponse|MfaCompleteRequest|PasskeyLoginBeginResponse|PasskeyLoginCompleteRequest|LoginResponse' \
  shomei-servant/src/Shomei/Servant/DTO.hs
grep -n 'WebAuthnConfig\|webauthnConfig' shomei-core/src/Shomei/Config.hs
```

Reconcile any name drift against `docs/plans/17-…` and `docs/plans/18-…` and record it in the
Decision Log before editing.

Milestone 1:

```bash
# After editing shomei-client/src/Shomei/Client.hs:
cabal build shomei-client
cabal build all
# Confirm the new exports:
echo ':browse Shomei.Client' | cabal repl shomei-client 2>/dev/null | \
  grep -E 'passkeyRegisterBegin|passkeyLoginComplete|mfaComplete'
```

Expected (abbreviated) on success:

```text
Build profile: -w ghc-9.12.4 -O1
... (shomei-client builds clean)
passkeyRegisterBegin :: ClientEnv -> Token -> IO (Either ClientError PasskeyRegisterBeginResponse)
mfaComplete :: ClientEnv -> MfaCompleteRequest -> IO (Either ClientError TokenPairResponse)
passkeyLoginComplete :: ClientEnv -> PasskeyLoginCompleteRequest -> IO (Either ClientError LoginResponse)
```

Milestone 2:

```bash
# After authoring docs/passkeys.md and editing docs/api.md, docs/security.md, README.md:
# Cross-check every name you wrote actually exists in the merged code:
for name in passkeyRegisterBegin passkeyRegisterComplete passkeyList passkeyDelete \
            mfaComplete passkeyLoginBegin passkeyLoginComplete; do
  grep -q "$name" shomei-servant/src/Shomei/Servant/API.hs && echo "OK $name" || echo "MISSING $name"
done
grep -c 'webauthnConfig\|rpId\|origins\|mfaRequired' docs/passkeys.md   # > 0
```

Milestone 3:

```bash
# After creating examples/embedded-servant-app/www/* and editing Embedded/App.hs (+ cabal):
cabal build all
# Serve and load the page (separate terminal for the server):
PG_CONNECTION_STRING="host=$PGHOST dbname=shomei user=$(id -un)" cabal run embedded-servant-app &
sleep 2
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/index.html   # -> 200
```

Expected:

```text
200
```


## Validation and Acceptance

Acceptance is observable behavior, not just compilation:

- **Client (M1).** `cabal build all` is green; `Shomei.Client` exports the seven new
  functions (confirm via `:browse`). Against a running server, `passkeyRegisterBegin env tok`
  returns `Right` a `PasskeyRegisterBeginResponse` with a non-empty `ceremonyId` and a
  non-null `options` (the *begin* step needs no authenticator, only a valid bearer token), and
  `login` for a passkey-less account returns a `LoginResponse` whose `status` is `complete`.
  If the optional client test was added, the `shomei-client` suite passes and asserts these.
- **Docs (M2).** Every endpoint path, DTO field, status code, and `webauthnConfig` field in
  `docs/passkeys.md`, `docs/api.md`, and `docs/security.md` matches the merged
  `Shomei.Servant.API`, `Shomei.Servant.DTO`, and `Shomei.Config` (the preflight/cross-check
  greps all report `OK`). A reader can copy a `curl` from `docs/api.md` and a config block from
  `docs/passkeys.md` and have them work. `README.md` links `docs/passkeys.md`.
- **Demo (M3).** `cabal run embedded-servant-app` serves `http://localhost:8080/index.html`
  (HTTP 200). A human with a real or virtual authenticator follows the walkthrough and:
  (i) logs in by password (account with no passkey → "logged in"); (ii) enrolls a passkey
  (device prompt → "passkey enrolled: passkey_…"); (iii) logs in again and observes
  `mfa_required` then the automatic assertion → "MFA complete — tokens issued"; and
  (iv) confirms that closing the device prompt at step (iii) leaves them without a usable token.
  This end-to-end run is the proof the whole MasterPlan-3 initiative works.

These are user-visible: a developer calls the client, a reader follows the docs, a human runs
the demo. The server-side wire shapes are already covered by EP-3's and EP-4's in-process HTTP
tests, so this plan adds no new server assertions — it proves *adoption*.


## Idempotence and Recovery

Every edit in this plan is additive and safe to re-apply:

- The client wrappers (M1) only *add* functions and exports; re-running the steps re-states
  the same code. If EP-4's DTO names differ from those assumed here, the recovery is mechanical:
  fix the import names, the wrapper signatures, and re-run `cabal build all`; record the rename
  in the Decision Log. The `login` definition does not change, so there is nothing to roll back
  there.
- The docs (M2) are new or appended sections; re-writing them is idempotent. If a name in the
  docs turns out wrong, edit that one line — no build or data is affected by documentation.
- The demo page (M3) is static files plus one additive `Raw` route mounted *last*; it cannot
  shadow or break the typed routes, and the existing `embedded-servant-app-test` (which drives
  `/projects`) is unaffected. To roll back, remove the `:<|> Raw` arm and the `www/` directory.
- No migration, no schema change, no destructive operation is introduced by this plan. The
  server behavior is entirely owned by EP-1..EP-4; this plan only consumes it.

If a milestone is interrupted, the Progress checklist records exactly which sub-step is done;
resume from the first unchecked box. Implement M1 fully (so the build stays green) before M2,
and M2 before M3, but the three are otherwise independent.


## Interfaces and Dependencies

This plan adds no new package and no new Haskell third-party dependency for the client
(`shomei-client` already depends on `servant-client`, `servant-client-core`, `shomei-servant`,
`shomei-core`, `text`). The demo gains at most `wai-app-static` (via
`Servant.Server.StaticFiles.serveDirectoryWebApp`) in
`examples/embedded-servant-app/embedded-servant-app.cabal`. The browser page depends on
`@github/webauthn-json` loaded from a CDN (no build step, no npm).

**Functions that must exist at the end of Milestone 1** (in `Shomei.Client`, all exported):

```haskell
passkeyRegisterBegin    :: ClientEnv -> Token -> IO (Either ClientError PasskeyRegisterBeginResponse)
passkeyRegisterComplete :: ClientEnv -> Token -> PasskeyRegisterCompleteRequest -> IO (Either ClientError PasskeyResponse)
listPasskeys            :: ClientEnv -> Token -> IO (Either ClientError [PasskeyResponse])
deletePasskey           :: ClientEnv -> Token -> PasskeyId -> IO (Either ClientError ())
mfaComplete             :: ClientEnv -> MfaCompleteRequest -> IO (Either ClientError TokenPairResponse)
passkeyLoginBegin       :: ClientEnv -> IO (Either ClientError PasskeyLoginBeginResponse)
passkeyLoginComplete    :: ClientEnv -> PasskeyLoginCompleteRequest -> IO (Either ClientError LoginResponse)
login                   :: ClientEnv -> LoginRequest -> IO (Either ClientError LoginResponse)  -- unchanged signature, widened-meaning LoginResponse
```

These wrap the corresponding `ShomeiClient` fields produced by `genericClient` from `ShomeiAPI`:
`passkeyRegisterBegin`, `passkeyRegisterComplete`, `passkeyList`, `passkeyDelete`, `mfaComplete`,
`passkeyLoginBegin`, `passkeyLoginComplete`, and `login`. The authenticated ones attach the
Bearer token via the existing `bearer :: Token -> AuthenticatedRequest (AuthProtect "shomei-jwt")`
helper.

**Consumed DTOs** (defined by EP-3/EP-4 in `Shomei.Servant.DTO`): `PasskeyRegisterBeginResponse`,
`PasskeyRegisterCompleteRequest`, `PasskeyResponse`, `MfaCompleteRequest`,
`PasskeyLoginBeginResponse`, `PasskeyLoginCompleteRequest`, and the widened `LoginResponse`.
**Consumed config** (defined by EP-1 in `Shomei.Config`): `WebAuthnConfig` and its fields,
documented in M2. **Consumed routes** (defined by EP-3/EP-4 in `Shomei.Servant.API.ShomeiAPI`):
the seven passkey/MFA routes plus the widened `login`. If any of these landed under a different
name, the reconciliation rule is: prefer the name in the merged EP-1..EP-4 code, update this
plan's references and the Decision Log, and rebuild.
