---
id: 74
slug: require-discoverable-credentials-for-passwordless-passkey-login
title: "Require discoverable credentials for passwordless passkey login"
kind: exec-plan
created_at: 2026-11-16T05:10:41Z
intention: "intention_01m7hc6hpcevfbe2y2f6kzqza1"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-16T05:10:41Z
---

# Require discoverable credentials for passwordless passkey login


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Follow `agents/skills/exec-plan/PLANS.md`, `ADR.md`, and `FRICTION.md` when implementing.

## Purpose / Big Picture


Fix [issue #13](https://github.com/shinzui/shomei/issues/13): a newly enrolled passkey must support login without first supplying a username or password. Registration currently requests `residentKey: "discouraged"`, allowing credentials that the authenticator cannot find when login supplies no credential IDs. Request discoverable credentials instead and prove that the server's unmodified options support enrollment followed by passwordless login.

A discoverable credential (historically a resident key) is one an authenticator can select without the server naming its ID. An authenticator is the device or credential provider that holds the private key. User verification (UV) is its local PIN or biometric check; it is separate from credential discoverability.

## Progress


- [ ] Milestone 1: registration emits required residency in both browser JSON and persisted options, with failing-before/passing-after regression coverage.
- [ ] Milestone 2: enrollment followed by passwordless login is verified through the real interpreter and a browser authenticator; existing step-up behavior remains valid.
- [ ] Milestone 3: compatibility guidance, changelog, and durable policy documentation are complete and relevant project checks pass.

Planning is complete; implementation has not begun. The intention was created with `mina ci --json` and is recorded in frontmatter. The working tree already contains unrelated edits and untracked plans 71–73; preserve them and stage only this work.

## Surprises & Discoveries


## Decision Log


2026-11-15: Require discoverable credentials for every new enrollment through the built-in interpreter. `WebAuthnConfig` has no passwordless enablement switch and the shared enrollment feeds both login modes. Adding a residency knob alone would permit the same broken combination. This repair changes enrollment capability requirements without expanding the configuration API. A separately designed step-up-only deployment mode is outside scope.

2026-11-15: Use `WA.ResidentKeyRequirementRequired`, letting the existing library encoder produce both residency fields. `preferred` still permits non-discoverable credentials. Do not patch the JSON after encoding, add a dependency workaround, weaken UV, or add an account lookup to passwordless begin.

2026-11-15: Preserve stored credentials and the existing verifier contract. This fix requests browser behavior; it does not establish a server-verifiable guarantee of credential storage modality. No database migration, credential deletion, or mandatory `credProps` response is required.

## Outcomes & Retrospective


## Context and Orientation


`shomei-webauthn/src/Shomei/WebAuthn/Ceremony.hs` implements the core ceremony port with the WebAuthn library. `beginRegistration` sets `WA.ascResidentKey` to `Discouraged`; the same encoded options become `BeginCeremony.optionsJson` and `optionsBlob` (bytes retained for completion). `beginAuthentication` maps a supplied credential list into `allowCredentials`.

`shomei-core/src/Shomei/Passkey/Workflow.hs` owns authenticated enrollment. `shomei-core/src/Shomei/Mfa/Workflow.hs` calls `beginAuthenticationCeremony UVRequired []` for passwordless begin, stores no associated user yet, then resolves the user from the signed response on completion. Password step-up already knows the account and supplies its credential IDs. `shomei-core/src/Shomei/Config.hs` defines `WebAuthnConfig`; its UV preference must remain independent of the residency repair.

`shomei-webauthn/test/Shomei/WebAuthn/CeremonySpec.hs` checks encoded options and signed verification. `shomei-webauthn/test/Shomei/WebAuthn/WorkflowSpec.hs` exercises enrollment, step-up and passwordless with the real interpreter and in-memory persistence. `shomei-webauthn/test/Shomei/WebAuthn/SoftwareAuthenticator.hs` constructs signed responses, but does not model a browser's credential discovery: its existing successful roundtrip does not disprove issue #13.

`shomei-servant/src/Shomei/Passkey/Api.hs`, `Dto.hs`, and `Handler.hs` expose registration and `/v1/auth/login/passkey/{begin,complete}`. `examples/embedded-servant-app/www/passkeys.js` provides enrollment and step-up using a JSON wrapper for browser WebAuthn; it currently has no passwordless button. `docs/user/passkeys.md` describes deployment and the demo. `Justfile`, `cabal.project`, and `.github/workflows/ci.yml` define development checks.

Relevant decisions consulted are [ADR-25](../adr/0025-attestation-conveyance-does-not-establish-device-trust.md), which preserves challenge/origin/signature/binding checks and mandatory passwordless UV without implying trusted hardware, and [ADR-21](../adr/0021-passkey-enrollment-spends-an-atomic-account-quota.md), which preserves existing credentials and enforces enrollment quotas atomically. Neither currently decides residency.

The dependency was located through Mori as `mori://tweag/webauthn/packages/webauthn`. Its source repository is `mori://tweag/webauthn/repos/webauthn`; project-relative source `webauthn/src/Crypto/WebAuthn/Encoding/Internal/WebAuthnJson.hs` (artifact-level URI pending) implements `Encode AuthenticatorSelectionCriteria` by emitting `residentKey` and setting `requireResidentKey` to whether residency is required. No new dependency bounds or pins are proposed. The [W3C selection criteria](https://www.w3.org/TR/webauthn-3/#dictdef-authenticatorselectioncriteria) specify the legacy Boolean, and the [residency enumeration](https://www.w3.org/TR/webauthn-3/#enumdef-residentkeyrequirement) distinguishes required from preferred. Required fails creation when discovery cannot be supported; preferred permits fallback.

## Plan of Work


### Milestone 1: Correct the registration contract


Extend `shomei-webauthn/test/Shomei/WebAuthn/CeremonySpec.hs` to inspect the actual `optionsJson` and independently decode `optionsBlob` as JSON. Assert `authenticatorSelection.residentKey == "required"`, `requireResidentKey == true`, and semantic equality between browser and persisted options. Cover default configuration and non-default UV preferences so discoverability cannot accidentally depend on UV. Keep the existing roundtrip assertions. Observe the residency test fail under the old implementation, then change `WA.ascResidentKey` in `shomei-webauthn/src/Shomei/WebAuthn/Ceremony.hs` to `WA.ResidentKeyRequirementRequired` and explain the passwordless invariant in a comment. The focused test suite must pass, including existing signed verification negatives.

### Milestone 2: Prove the consumer path and compatibility


Extend the signed workflow test in `shomei-webauthn/test/Shomei/WebAuthn/WorkflowSpec.hs` to assert residency in enrollment options before constructing a response; assert passwordless options have no credential restriction (absent or empty `allowCredentials`) and UV is required. Retain the successful same-user resolution, advancing counter, replay rejection and failure audit assertions. Assert the known-account step-up options include the enrolled credential ID. Do not claim the software fixture proves browser discovery.

Perform the browser check below with fresh credentials and raw server options. A one-off console invocation is sufficient; no new browser framework or UI feature is required. Exercise a resident-capable virtual authenticator first, then an authenticator with resident-key support disabled: the latter must fail enrollment rather than silently creating a credential unsuitable for passwordless login. Record browser version, capabilities, emitted selection fields and outcome without tokens or private credential data. The signed workflow and browser checks together establish this milestone.

### Milestone 3: Explain compatibility and finish validation


Update `docs/user/passkeys.md` to distinguish residency from UV, describe both emitted fields, and explain that old non-discoverable credentials can still serve known-account step-up but need new enrollment for passwordless use. Updating the server cannot convert them. Enrollment now requires resident-capable authenticators; document the visible failure for unsupported devices. Recommend enrolling and verifying a replacement before removing an old credential, respecting the existing quota. Do not suggest password reset bypasses MFA. Add a fix entry to `shomei-webauthn/CHANGELOG.md` and the root `CHANGELOG.md`, preserving concurrent edits. Avoid release/version changes in this task.

Record the shared-enrollment residency decision in a new ADR through `agents/skills/exec-plan/ADR.md`: inspect `mori show --full` and `docs/adr/profile.dhall`, allocate the next `ADR-N` with OKF, maintain the bundle log, and run `just adr-validate`. Do not repurpose ADR-25's attestation decision. Complete the checks below, triage any recorded friction and fill Outcomes & Retrospective before marking the plan complete.

## Concrete Steps


All shell commands start at the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`, unless stated otherwise. For dependency rediscovery use:

```bash
export MORI_PG_CONNECTION_STRING='host=/Users/shinzui/.local/state/postgresql dbname=mori user=shinzui connect_timeout=5'
mori registry search webauthn
mori registry show tweag/webauthn --full
mori registry docs tweag/webauthn
```

Read source only from the returned checkout, never `/nix/store`. If implementation unexpectedly needs dependency changes, verify current releases against Hackage and upstream tags first.

After adding the regression tests and again after the fix, run:

```bash
nix develop --command cabal test shomei-webauthn-test --test-show-details=direct
```

Before the fix the new assertion must report discouraged rather than required; afterwards all tests in that suite must pass. At the final coherent boundary run:

```bash
nix develop --command cabal build all
nix develop --command cabal test all --test-options='-j2'
nix fmt -- --fail-on-change
nix develop --command just adr-validate
git diff --check
```

Expect exit zero, passing test suites and no formatting changes. Diagnose unrelated dirty-tree failures separately; do not overwrite others' work to obtain a clean run. Full tests may launch disposable PostgreSQL instances through the existing test infrastructure.

For the browser check, enter `nix develop`, retain a development `SHOMEI_KEY_ENCRYPTION_KEY` for the database as described in `README.md`, and start `process-compose up --no-server` for local PostgreSQL/migrations. In a second terminal with the same development environment and key run:

```bash
SHOMEI_DEMO_WWW=examples/embedded-servant-app/www cabal run embedded-servant-app
```

Use the shell's development database settings; never point this check at production. Ensure port 8080 is free before starting the demo. Open `http://localhost:8080/index.html`. In Chrome DevTools enable WebAuthn and add a CTAP2 virtual authenticator with resident keys, user verification, verified-user status and automatic presence enabled. Create a fresh disposable user through `/v1/auth/signup` using the curl example in `docs/user/passkeys.md`, log in on the page and enroll. Inspect registration begin in the network panel: the selection must be required/true with no page override.

Then use the page's developer console to complete passwordless authentication using the same browser JSON wrapper as the demo:

```javascript
const wa = await import('https://unpkg.com/@github/webauthn-json@2.1.1/dist/esm/webauthn-json.js');
const beginResponse = await fetch('/v1/auth/login/passkey/begin', {method: 'POST'});
if (!beginResponse.ok) throw new Error('passwordless begin failed');
const begun = await beginResponse.json();
const assertion = await wa.get({publicKey: begun.options.publicKey});
const completed = await fetch('/v1/auth/login/passkey/complete', {
  method: 'POST', headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({ceremonyId: begun.ceremonyId, assertion, remember: false})
});
if (!completed.ok) throw new Error('passwordless completion failed');
const pair = await completed.json();
console.assert(typeof pair.accessToken === 'string');
```

Do not print the token pair. Check that passwordless begin has empty/absent `allowCredentials` and required UV. Repeat password login through the demo to prove step-up remains usable. Repeat enrollment with a separate fresh account and only a virtual authenticator lacking resident-key support active; creation must reject and registration completion must not run. Error names vary by browser, so accept the rejected creation rather than a specific exception string. Save only concise, sanitized evidence in this plan.

## Validation and Acceptance


Acceptance requires both emitted JSON fields in browser and stored options, a regression that fails before the fix, and successful real-interpreter tests. The browser must enroll and then discover the newly created credential without a username or credential list supplied to passwordless begin. Passwordless completion must issue tokens; existing step-up, UV, signature, origin, challenge, user binding, replay and counter checks must still pass. An unsupported authenticator must not silently enroll a non-discoverable credential under the new request.

No requirement is added to reject previously issued registration options or stored credentials. No server claim of proven residency is made. Documentation must state the enrollment compatibility change and recovery path through an already usable login/factor. If the browser environment is unavailable, record the blocker and leave milestone 2 incomplete; signed fixtures alone do not establish discovery behavior.

## Idempotence and Recovery


Tests and builds are repeatable. Use fresh disposable users for browser repeats to avoid exclusion lists and account quotas. Stop only processes started for this work, through their own terminal or recorded PID. No database or credential migration is needed. Reverting the code change restores the old enrollment request; already enrolled discoverable credentials remain usable. Preserve the development encryption key while reusing its database. Never delete a user's only usable credential to test reenrollment.

## Interfaces and Dependencies


The only production behavior change is `beginRegistration`'s authenticator selection in `shomei-webauthn/src/Shomei/WebAuthn/Ceremony.hs`. Preserve `BeginCeremony`, `WebAuthnConfig`, registration/authentication port signatures, HTTP DTOs and persistence schema. The existing dependency encoder must emit the legacy flag; verify through output tests rather than hand-writing duplicate JSON. No parent MasterPlan prerequisite applies.

Every implementation commit uses Conventional Commits and includes `ExecPlan: docs/plans/74-require-discoverable-credentials-for-passwordless-passkey-login.md` and `Intention: intention_01m7hc6hpcevfbe2y2f6kzqza1` trailers. Record a provenance revision with the bundled script when implementation first edits this plan.
