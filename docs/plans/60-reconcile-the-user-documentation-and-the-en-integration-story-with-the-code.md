---
id: 60
slug: reconcile-the-user-documentation-and-the-en-integration-story-with-the-code
title: "Reconcile the User Documentation and the en Integration Story with the Code"
kind: exec-plan
created_at: 2026-08-27T03:23:49Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
master_plan: "docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md"
---

# Reconcile the User Documentation and the en Integration Story with the Code

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The August 2026 review ([REV-1](../reviews/project-security-and-performance-baseline.md) finding 12, plus the
documentation findings in REV-2 through REV-10) found that an integrator reading `docs/user/` would act on sentences
that are false: the password-hash format and module path, the claim that en-server has no caller authentication and
will verify Shōmei JWTs, a quick start that posts to a `404`, a changelog naming modules that never existed at
release, an audit-route combinator that is not the one in the type, a sweeper log example missing two tables, and a
dozen smaller drifts. This plan is EP-10 of MasterPlan 8: it fixes only the drift no behavior change fixes and,
because it runs last, verifies that EP-1 through EP-9 each updated the documentation their change touched. Afterwards
every flagged sentence is true or gone; a docs-wide link check and an `api.md`-versus-`docs/api/openapi.json` path
diff are repeatable commands that pass; `docs/user/security.md` says when it was last reconciled; and the five ADRs
the MasterPlan asked the siblings to write are confirmed to exist and to be linked from the pages stating their rules.


## Progress

- [x] (2026-08-27) M1: `security.md` reconciled (hash format and module, four collapsed login cases, account key and per-IP window, counter zero case, `RequireAdmin`, runbook transcript, stamp); `LoginAttempt/Domain.hs:21` Haddock corrected
- [x] (2026-08-27) M1: EP-4 had landed; `TimingSpec` contains the locked-account hash case, so `security.md`'s "exactly one" guarantee remains accurate
- [ ] M2: `authorization.md` en-side section rewritten against en `bf8ffa2`; circularity paragraph re-grounded; topology item 1 corrected; `security.md:382-385`, `:629-636` and `microservice-auth-stack/README.md` §4 fixed
- [ ] M3: `architecture.md:21`, `README.md:53-57`, `index.md:33`, both changelogs, MasterPlan 6 addendum, CAP-9 evidence and `docs/capabilities/log.md`, `www/README.md:12`
- [ ] M4: `deployment.md` (pool sentence, sweep examples and table, lockout paragraph), `api.md` (cookie mount caveat, delegation-blocked list, audit route), `oidc.md:77-79` and `:95-97`, `passkeys.md:129`
- [ ] M5: per-sibling probes run and recorded; deferred sentences listed in Outcomes; link check and OpenAPI diff clean
- [ ] M6: the five MasterPlan 8 ADRs exist, are linked from the pages stating their rules, and the bundle validates


## Surprises & Discoveries

Found while researching at HEAD `5dfd2a6` (code identical to reviewed `ee00382`):

- `okf validate docs/capabilities --strict --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce`
  exits 1 **before any change**, printing exactly 24 lines of `missing profile-recommended field: reviews`, one per
  capability. Without `--strict` it prints `OK: 24 concepts (okf_version 0.2)` and exits 0.
- `deployment.md`'s lockout paragraph is inverted, not mis-numbered: the workflow writes a lockout row only when it
  locks (`Authentication/Workflow.hs:329-331` always passes `Just lockedUntil`), and the running failure count is
  counted from `shomei_login_attempts`. The review cited `:376-379`; the paragraph is at `:364-367` today.
- `README.md`'s quick start is wrong twice on one line: `/auth/signup` (a `404` since the `/v1` move) and a body with
  no `loginId`, which `api.md:121` says is required. `CHANGELOG.md:179` links `docs/user/service-tokens.md`, which
  does not exist (the page is `machine-tokens.md`); the review's link check did not cover the changelog.
- en-client has no API-key support (`en-client/src/En/Client.hs` is `genericClient` with no header handling), so a
  downstream following the microservice recipe must add `Authorization: Bearer <en key>` itself; that code change is
  EP-9's. A dry run of the CAP-9 edit on a scratch copy showed `okf log add` prepends a dated section with one
  `* **Update**:` bullet and the bundle validates afterwards.


## Decision Log

- Decision: Correct `CHANGELOG.md:44-50` and `shomei-servant/CHANGELOG.md:21` in place under a one-sentence dated
  editorial note, rather than appending a corrections entry.
  Rationale: Both describe 0.1.0.0 (2026-08-24) behavior under names (`Shomei.Workflow.verifyToken`,
  `Shomei.Jwt.Verify`) that plan 48 renamed on 2026-08-23 (`994f947`); they never existed at release, so a reader who
  greps for them finds nothing. `CHANGELOG.md:178-179` differs: `POST /v1/auth/service-token` existed when written and
  was removed before release (`e566bcb`), so it keeps its text and gains a note and a retargeted link.
  Date: 2026-08-27
- Decision: MasterPlan 6 gets a dated addendum under Outcomes & Retrospective; its Progress lines stay.
  Rationale: `:151-152` ("11 → 7", "5 → 3") and `:159` ("legacy hashes still verify") were true when checked off;
  later plans changed the facts. Rewriting a record erases when the drift began.
  Date: 2026-08-27
- Decision: `security.md` gains a "last reconciled" line after its opening sentence, dated, naming the reviewed
  commit, and linking REV-1 and this plan by relative path.
  Rationale: "It reflects the implemented code, not aspirations" was unverifiable; a stamp makes it falsifiable and
  obliges the next behavior change to move it. It names the *reviewed* commit because the fixing commit's hash does
  not exist when the file is written.
  Date: 2026-08-27
- Decision: Acceptance greps are scoped to `docs/user`, `docs/capabilities`, `docs/reviews`, `README.md`,
  `CHANGELOG.md`, and the example READMEs; `docs/plans` and `docs/masterplans` are excluded except for the
  MasterPlan 6 addendum.
  Rationale: `docs/masterplans/4-…:21` cites `Shomei/Crypto.hs` and `7-…:701` repeats "no caller authentication yet";
  both were true when written, and rewriting them is the MasterPlan 6 mistake.
  Date: 2026-08-27
- Decision: The capability gate is the non-strict `okf validate docs/capabilities …` (exit 0) plus "the strict form
  reports only the 24 baseline `reviews` lines"; filling `reviews` on all 24 records is out of scope.
  Rationale: The strict form fails at HEAD for a reason unrelated to this plan (Surprises).
  Date: 2026-08-27
- Decision: In `examples/microservice-auth-stack/README.md` this plan owns §4 (the prose about en-server's posture)
  and EP-9 owns line 133 (the `runClientM` snippet) and the runbook; in `docs/user/client-and-examples.md` EP-9 owns
  every sentence about the cache's behavior (TLS, `max-age` clamp, `kid` refresh, the `Cache-Control` sentence at
  `:131-135`) and this plan verifies.
  Rationale: MasterPlan 8 Integration Point 10 assigns "the READMEs and client-and-examples.md" to EP-10, while its
  EP-9 Progress lines and REV-1 finding 5's remedy assign the TLS warning and the runbooks to EP-9. "Does the sentence
  describe code EP-9 changes" resolves the overlap.
  Date: 2026-08-27
- Decision: Remove the absolute path `/Users/shinzui/Keikaku/bokuno/en` from `security.md:630` in favor of the GitHub
  URL `authorization.md:9` already uses.
  Rationale: A user document must not depend on the author's filesystem.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation. At completion, list every sentence deferred because a sibling had not
landed, each with the grep that detects it, so the next contributor can finish the sweep without re-reading the review.)


## Context and Orientation

Shōmei is a Haskell authentication toolkit: eight packages, a standalone server (`shomei-server`), and three examples
under `examples/`. User documentation is `docs/user/` (fifteen pages; `index.md` is the table of contents) plus
`README.md` and `CHANGELOG.md` at the root. Two OKF bundles matter: `docs/capabilities/` (24 capability records;
`index.md` and `log.md` are reserved files) and `docs/reviews/` (REV-1 through REV-10, the review this plan closes).
OKF is the structured-documentation format the `okf` CLI validates; a bundle is a directory of one-concept-per-file
records with a `profile.dhall` naming the schema.

The sibling project **en** (a relationship-based authorization toolkit) is checked out at
`/Users/shinzui/Keikaku/bokuno/en`, HEAD `bf8ffa24b33de328ed7c6b19f02e9e3ad035d57f` (2026-08-26); every en fact here
was read at that commit. `docs/user/authorization.md` was written on 2026-07-10 against en `d3209cb`, which
`examples/embedded-with-en/cabal.project:41` still pins.

Architecture Decision Records: this repository has no `docs/adr/` (`ls docs/adr` fails; `mori.dhall` declares only
`improvement-requests`, `capabilities`, and `reviews`), so no local ADR applies. MasterPlan 8 asks five siblings to
create `docs/adr/` on first use, following `.claude/skills/exec-plan/ADR.md`: session provenance (EP-1, plan 51),
reserved privilege scopes (EP-2, plan 52), "a transport library's exception text is never persisted" (EP-7, plan 57),
the trusted-proxy policy (EP-8, plan 58), and the embedding contract (EP-9, plan 59). This plan creates no ADR; M6
verifies those five. Plans 51–59 are skeletons at the time of writing, so M5's probes derive from MasterPlan 8's
Progress lines; re-derive a probe from a sibling's own Progress section if it named things differently.

House style: `docs/plans/13-documentation-and-adoption-guides.md` (verify every fact against the running system before
writing it) and `docs/plans/30-…`'s Surprises ("grep for downstream docs before changing a log format" — M4's sweeper
example is that lesson). Evidence, all repository-relative: REV-1 finding 12 and "Coverage and limits"; REV-2 findings
12, 13, 22; REV-3 findings 6 and 9; REV-4 finding 4; REV-5 finding 11; REV-6 finding 4; REV-7 findings 13 and 15; REV-8
findings 16, 17 and "Defaults assessed"; REV-10 findings 4 and 7. Tools in the Nix dev shell: `rg`, `python3`, `okf`
0.8, `just`, `cabal`, `git`. Commands run from the repository root.


## Plan of Work

Six milestones, one commit each. Every commit message carries the trailers
`MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md`,
`ExecPlan: docs/plans/60-reconcile-the-user-documentation-and-the-en-integration-story-with-the-code.md`, and
`Intention: intention_01m10kwqt9eedbjvk91rn726mq`; M1 shows the full form and the others give the subject. Line numbers
are those of HEAD `5dfd2a6`; if a sibling landed first, find the sentence by its quoted text.

### Milestone M1 — `docs/user/security.md`

Scope: every flagged sentence in `security.md` that no behavior plan owns, plus the stamp. At the end the hashing,
login-collapse, abuse-key, passkey-counter, audit-route, and runbook paragraphs match the code and the page says when
it was last checked.

Lines 8-9 read `Passwords are hashed with **Argon2id** (\`crypton\`, in \`shomei-postgres/src/Shomei/Crypto.hs\`),
stored as \`argon2id$<b64 salt>$<b64 hash>\`.` Replace both lines with the following (the sentence then continues at
"compares in **constant time**"); evidence `Hash/Postgres.hs:134-148` (`phcEncode`) and `:185-192`:

```text
Passwords are hashed with **Argon2id** (`crypton`, in
`shomei-postgres/src/Shomei/Account/Password/Hash/Postgres.hs`) and stored as a PHC-style string carrying
its own parameters: `$argon2id$v=19$m=<KiB>,t=<iterations>,p=<lanes>$<b64 salt>$<b64 digest>`. Only that
form verifies; anything else — including the older unparameterized three-part form — is rejected without
hashing (`verifyPasswordArgon2id`). Verification re-derives from the stored parameters and salt and
```

After line 4 ("It reflects the implemented code, not aspirations.") insert:

```text
Last reconciled with the code on <YYYY-MM-DD> against
[REV-1](../reviews/project-security-and-performance-baseline.md) (reviewed commit `ee00382`), by
[plan 60](../plans/60-reconcile-the-user-documentation-and-the-en-integration-story-with-the-code.md).
A plan that changes a behavior described here moves this line in the same commit.
```

Lines 188-190 say login returns one generic `401` for "a wrong password, an unknown account, and a **locked** account"
and that the workflow "returns `InvalidCredentials` for all three". There are four cases: a suspended or deleted
account is `UserNotActive`, collapsed to `invalid_login` only at the HTTP boundary
(`shomei-servant/src/Shomei/Servant/Error.hs:545-547`). Replace with:

```text
Login returns a single generic `401 invalid_login` for a wrong password, an unknown account, a **locked**
account, and a **suspended or deleted** account — byte-for-byte identical at the HTTP boundary. Inside the
library the `login` workflow returns `InvalidCredentials` for the first three and `UserNotActive` for the
fourth; `shomei-servant` maps both to the same problem, so only a host calling the workflow directly can tell
a suspended account from a wrong password.
```

Lines 199-201 ("Every failing login therefore performs **exactly one** password verification") are false for the
locked branch today (`Authentication/Workflow.hs:236-237` throws before `:244`); EP-4 owns making it true. Probe
`rg -n "locked" shomei-core/test --glob '*TimingSpec*'`: a locked-account case means EP-4 landed and the sentence
stands; nothing means leave it unchanged and record "deferred to EP-4" in Progress.

Lines 235-236 say the account key "is a SHA-256 of the normalized email". It is the login identifier:
`shomei-server/src/Shomei/Server/Boot.hs:398` sets `accountKeyOf = AccountKey . sha256Hex` and
`shomei-servant/src/Shomei/Session/Handler.hs:76` applies it to `loginIdText loginId`. Write "a SHA-256 (hex) of the
normalized login identifier", and make the same correction in the Haddock at
`shomei-core/src/Shomei/Session/LoginAttempt/Domain.hs:21` ("normalized email presented at login" → "normalized login
identifier presented at login"); `cabal build shomei-core` confirms nothing else moved. Lines 237-239 omit the per-IP
throttle's window (`Workflow.hs:220, 230-233`); replace the bullet with:

```text
- **Per-IP failure throttle**: after `maxFailedLoginsPerIp` failures (default 20) from one IP within
  `lockoutWindow` (the same 15-minute window as the account lockout) the next attempt returns `429`. A
  successful login does **not** reset this count (an attacker cannot clear it by logging into their own
  account); it only ages out of the window.
```

EP-8 rewrites the paragraph after it (`:244-245`, "target a single-instance deployment"); if EP-8 has landed, keep its
text and apply only the window wording. Lines 277-279 say a counter that "does not advance past the stored value"
fails closed, omitting the specification's zero case. Replace the bullet with:

```text
- **Signature-counter clone check.** Each stored credential keeps a signature counter; an assertion whose
  counter is not greater than the stored value signals a cloned authenticator and fails closed
  (`401 mfa_failed`). The one exception is the specification's zero case: an authenticator reporting `0`
  against a stored `0` does not implement counters and is accepted
  (`shomei-webauthn/src/Shomei/Webauthn/Ceremony.hs:171`, `SignatureCounterZero`).
```

Lines 671-673 say the audit route "carries `RequireRole "admin"`". The type is
`"audit" :> "events" :> RequireAdmin :> …` (`shomei-servant/src/Shomei/Audit/Api.hs:13`), and `RequireAdmin` accepts
the `admin` role *or* the `shomei:admin` scope. Replace "The route type carries `RequireRole "admin"`, so a request
with no token gets `401` and one whose token lacks the role gets `403`" with "The route type carries `RequireAdmin` —
the `admin` **role** or the `shomei:admin` **scope** — so a request with no token gets `401` and one whose token has
neither gets `403`".

Lines 689-692 show `shomei-admin audit user <uuid>` returning an `account_locked` row. It cannot: those events are
encoded with `user_id = NULL` (`shomei-core/src/Shomei/Audit/Event/Codec.hs:125-126`,
`(Nothing, Nothing, "account_locked", …)`) because the account may not exist. Replace with:

```text
# Did the account get locked? Lock events carry no user id (the account may not exist), so list them by
# type; the payload's accountKey is the SHA-256 of the login identifier.
$ shomei-admin audit events --type account_locked --limit 5
2026-06-17T10:05:00Z    account_locked     -           -           7c1f2f0e-…

# Then pull the account's own timeline (logins, refreshes, resets) by its user id.
$ shomei-admin audit user 019eb2eb-ac04-747e-9e70-ea4db1bd446e
2026-06-17T10:01:00Z    login_succeeded    019eb2eb-…  019eb2ec-…  …
```

The JWT/JWKS sentences at lines 19-21 were assigned to EP-3. EP-3 has now made `kid` select
exactly one key and made every JWKS entry carry `alg`; M5 re-probes those guarantees instead of
rewriting them. Lines 382-385 and 629-636 (the en premise) are done in M2. Commit:

```text
docs(security): reconcile security.md with the code and stamp the reconciliation

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/60-reconcile-the-user-documentation-and-the-en-integration-story-with-the-code.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M2 — the en integration story, against en HEAD

Scope: `authorization.md:34-38`, `:128-135`, `:145-162`; `security.md:382-385`, `:629-636`;
`examples/microservice-auth-stack/README.md:145-157`. At the end every en claim in Shōmei's documentation is true at
en `bf8ffa2`, with the surviving gap named precisely. Re-verify each fact with the commands in Concrete Steps first.

The facts, which the rewritten section states in this order. en-server authenticates every caller with static bearer
API keys in two tiers — `EN_API_KEYS_READ_WRITE` (every endpoint) and `EN_API_KEYS_READ_ONLY` (query endpoints only; a
read-only key answers `403` on tuple writes) — compared in constant time, with a per-key token bucket
(`EN_RATE_LIMIT_RPS`, `EN_RATE_LIMIT_BURST`; `429` with `Retry-After`) and fail-closed startup: no key means it refuses
to boot unless `EN_AUTH_DISABLED=true`, which is ignored when any key is set (`en-server/app/Middleware.hs:1-9, 45-62`;
`en-server/app/Config.hs:370-372, 458-474`; `docs/user/service-and-operations.md:669-688`). en plan 33 completed on
2026-07-08 (`d6fee32`, `dcb13af`), two days *before* `authorization.md` called it unimplemented; because en-client adds
no header, a downstream must send `Authorization: Bearer <en key>` itself (the microservice recipe shows the shape). en
explicitly decided **not** to verify Shōmei JWTs — plan 33's first Decision Log entry: "nothing in this repository
provides a shomei verifier … shomei therefore stays an extension point, not a dependency" (`Middleware.hs:7-9` keeps
the seam as a future option only); one sentence points up to the rewritten circularity paragraph. en-postgres has a
pooled runner, `runDatabasePool :: (IOE :> es) => Pool.Pool -> Eff (Database : es) a -> Eff es a`
(`en-postgres/src/En/Postgres/Database.hs:43`), present at the pinned `d3209cb` too (plan 34, 2026-07-08), so the "no
pooled runner" gap was false the day it was written; `embedded-with-en` stays in-memory for build weight (en-postgres
drags hasql and biscuit pins, `examples/embedded-with-en/cabal.project:26-34`), not for lack of a runner. en moved to
pg-migrate on 2026-08-24 (`b734f48`, plan 62): `en-migrations/en-migrations.cabal:47-48` depends on
`pg-migrate ^>=1.1.0.0`, `en-migrations/migrations/` holds `0001-en-bootstrap.sql` and a `manifest`, the CLI is
`cabal run en-migrate -- up`, and its tables stay in `public`. `subjectFromUserId` is still not exported (only
`en-biscuit/test/Main.hs:843-844` and `docs/user/biscuit-decision-tokens.md:81-83`) — the one surviving gap. The
example pins en-core at `d3209cb`, 96 commits behind; `TupleStore` grew from 14 to 15 constructors, so a bump breaks
`runTupleStoreIORef` (`EmbeddedEn/Authz.hs:175-244`) — plan 47's follow-up, not ours. A closing "en-side follow-ups
(not edited here)" paragraph names the `subjectFromUserId` export and en's `docs/user/biscuit-decision-tokens.md:71`,
which still cites `Shomei.Domain.Claims.AuthClaims` (now `Shomei.Authorization.Claims.Domain`). Keep the final pointer
to plan 47's External Companion Work, reworded to "were tracked in".

`authorization.md:34-38` argues the built-in tier stays because "en-server's future caller authentication will itself
verify Shōmei JWTs … circular at bootstrap". The premise is gone; the conclusion survives on other grounds. Replace
the paragraph with:

```text
**The built-in tier is never removed in favor of en, and Shōmei's own role grants always stay in Shōmei.**
en-server authenticates its callers with static API keys and deliberately does not verify Shōmei JWTs (en
plan 33, complete 2026-07-08), so it has no notion of a Shōmei user's roles: en could only answer "is this
user an administrator?" if something already authorized to write tuples had said so first. Three things
follow. Shōmei's `/v1/admin` surface must work on a fresh database with no en deployed, because en is
optional and the standalone server has no en dependency. The first administrator is granted from the box
(`shomei-admin roles grant`), outside both HTTP surfaces, and an en deployment would copy *from* that grant,
never the other way round. And a live authorization decision must not be frozen into a JWT claim (see
[Consistency](#consistency)), so Shōmei's coarse gate and en's live check are different tiers by
construction. The two tiers compose rather than compete.
```

`authorization.md:128-135` (topology reason 1, "**But it takes two.** en has not moved to `pg-migrate`") becomes:

```text
1. **Both projects now run on `pg-migrate`, so one ledger is possible — but still not the default.**
   `shomei-migrations` exports `shomeiMigrationComponent`; en's `en-migrations` (pg-migrate since
   2026-08-24, one bootstrap migration plus a manifest, applied by `cabal run en-migrate -- up`) can be
   composed with it into one ordered `MigrationPlan`. Composition is supported, not verified here, and
   reason 2 is the stronger argument.
```

Replace the whole section at `:145-162` with `## Current en-side facts (as of en bf8ffa2, 2026-08-26)` carrying the
facts above in prose. `security.md:382-385` repeats the dead premise ("en's server authenticates its callers by
verifying Shōmei JWTs"); replace with: "The two tiers compose rather than compete. Even a deployment that adopts en
keeps Shōmei's flat roles: en-server authenticates its callers with API keys and does not verify Shōmei JWTs, so
nothing in en can say who a Shōmei administrator is — the built-in tier is that something, and it is never removed in
favor of en (see [Authorization](authorization.md#the-two-tiers))." Lines 629-636 repeat it and add "The integration
guide and examples will live at `docs/user/authorization.md`; until then the design is in plan 47". Replace from "en
(`/Users/shinzui/…`" to the paragraph's end with: "en (<https://github.com/shinzui/en>, a Zanzibar-style ReBAC toolkit)
is built for them, and the paved road is "**Shōmei for authentication, en for authorization**"; the integration guide,
the identity-mapping conventions, and both runnable examples are in [Authorization](authorization.md)."

`examples/microservice-auth-stack/README.md:145-157` becomes "### 4. Security posture — en-server requires an API
key": the two key tiers; that the downstream should hold a **read-only** key (it only asks questions), sent as a bearer
header the §3 snippet must add; and that the private-network or TLS posture still applies because a bearer key is only
as secret as its transport (en offers `EN_TLS_CERT_FILE`/`EN_TLS_KEY_FILE` or a terminating proxy). If EP-9 has not yet
changed line 133, add "the snippet above does not yet send the header". Commit as `docs(authorization): rewrite the
en-side story against en bf8ffa2` with the standard trailers.

### Milestone M3 — paths, the quick start, the changelogs, MasterPlan 6, the capability catalog

`architecture.md:21-25` says each effect lives in `shomei-core/src/Shomei/Effect/*` and lists fifteen names. Since
plan 48 each interface lives beside its concept: `rg -n ":: Effect" shomei-core/src` finds them at
`shomei-core/src/Shomei/<Concept>/…/Store.hs` (e.g. `Shomei.Session.Store`, `Shomei.Account.User.Store`,
`Shomei.SigningKey.Store`) plus `Shomei.SigningKey.Signer`, `Shomei.SigningKey.Verifier`,
`Shomei.Session.Token.Generator`, `Shomei.Time.Store`, and `Shomei.Audit.Publisher.Store`. Rewrite the paragraph to say
that, name those examples, and drop the `Effect/*` path (the surviving `Shomei/Effect` directory holds shared
machinery, not interfaces).

`README.md:53-57`: both `curl` lines post to `localhost:8080/auth/signup` (a `404`; `api.md:28`) and line 54's body
omits the required `loginId`. Change both paths to `/v1/auth/signup` and make the first body
`{"loginId":"alice","email":"alice@example.com","password":"correct horse battery staple","displayName":"Alice"}`.
`docs/user/index.md:33-34`: "the two runnable example applications" → "the three runnable example applications"
(`client-and-examples.md:3` already says three).

`CHANGELOG.md:44` and `:50` name `Shomei.Workflow.verifyToken`, `:46` names `Shomei.Jwt.Verify`, and
`shomei-servant/CHANGELOG.md:21` names `Shomei.Workflow.verifyToken`. Replace with
`Shomei.Session.Authentication.Workflow.verifyToken` and `Shomei.SigningKey.Verify.Jwt`, and insert directly under
`CHANGELOG.md:40`'s `### Fixed — security: …` heading (and under the servant changelog's `## 0.1.0.0` heading) the
italic note *Editorial note, <date>: module names corrected to the ones shipped in 0.1.0.0; the entry originally used
pre-plan-48 names that never existed at release.* At `CHANGELOG.md:178-179` keep the sentence, retarget the link to
`docs/user/machine-tokens.md`, and append "(removed before the 0.1.0.0 release in `e566bcb`)".

MasterPlan 6: under `## Outcomes & Retrospective` append a paragraph headed **Addendum, <date> (REV-5, plan 60)**
stating that Progress `:151-152` ("11 → 7", "5 → 3") are superseded — the pinned budgets are login 10 and refresh 5
(`shomei-postgres/test/Main.hs:1247`, `:1270`) after later plans added the passkey and TOTP lookups, the role and
permission reads, and the email gate — and that `:159` "legacy hashes still verify" ceased to be true in `e566bcb`
(2026-08-23), which dropped the unparameterized form; such values are now rejected without hashing
(`Hash/Postgres.hs:177-192`).

`docs/capabilities/type-level-authorization-guards.md:27-29` offers `EmbeddedEn/Authz.hs` as evidence that a host
reuses "the same fail-closed guard shape"; `requireProjectPermission` (`Authz.hs:269-281`) is a term-level `Handler ()`
guard, not a combinator. Set `proves:` to "A host reusing the same fail-closed outcome mapping (Allowed proceeds, Denied
and Conditional are 403, an engine error is 503) as a term-level `Handler` guard for its own fine-grained checks; it
is not a type-level combinator.", advance `generated.at` to today, then:

```bash
okf log add docs/capabilities -m "CAP-9: the embedded-with-en evidence entry now says the host guard is term-level; the combinators themselves are unchanged."
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
```

```text
Wrote log.md for <date>
OK: 24 concepts (okf_version 0.2)
```

`examples/embedded-servant-app/www/README.md:12` links `../../../docs/passkeys.md`; the page is `docs/user/passkeys.md`
and its demo section is `## Browser glue and the demo` (line 159). Retarget the link and the quoted heading unless
EP-9 already did. Commit as `docs: fix stale module paths, the quick start, the changelog names, and CAP-9's
evidence` with the standard trailers.

### Milestone M4 — `deployment.md`, `api.md`, `oidc.md`, `passkeys.md`

`deployment.md:68-69` ("Token verification … takes no connection at all") is true only under the default mode; append
"under the default `SHOMEI_SESSION_CHECK=token-only`; `token-and-session` adds one session read per authenticated
request, so size for it if you enable it."

`deployment.md:315` (the JSON sweep line) and `:327-334` (the CLI block) omit two of the ten keys the sweeper reports
(`Persistence/Maintenance/Postgres.hs:136-148`, in order: `refresh_tokens, sessions, verification_tokens,
reset_tokens, ceremonies, authorization_codes, lockouts, login_attempts, role_grants, auth_events`). Rewrite both in
that order: the JSON line gains `"authorization_codes":0` after `"ceremonies":1` and `"role_grants":0` after
`"login_attempts":0`; the CLI block gains `authorization_codes: 0` and `role_grants:         0` at the same positions
(labels are padded to the longest name plus two). Add two rows to the table at `:344-353`:
`shomei_oauth_authorization_codes` — expired longer ago than the ceremony grace — `60 minutes`; `shomei_role_grants` —
`expires_at` passed longer ago than the one-time-token grace (forever grants are never touched) — `7 days`. Replace
`:364-367` ("Rows … with no active lock are never swept. They carry the running failure count") with:

```text
**Lockout rows are written only when an account locks.** The running failure count is not stored in
`shomei_account_lockouts` at all — it is counted from `shomei_login_attempts` inside the lockout window on
every failure — so a lockout row always carries a `locked_until`, and the sweeper deletes it once that instant
is a grace period in the past. A successful login clears an elapsed lock immediately; the sweeper is only hygiene.
```

`deployment.md:160-166` (the "closed record type" note) and the key list at `:141-158` (missing the notifier, TOTP,
OIDC, OAuth, and `defaultRoles` keys) are EP-6's; M5 probes them. If EP-6 has not landed, add after `:158`:
"`config/shomei-types.dhall` is the authoritative key list; this paragraph names the most common ones."

`api.md:97-104` documents the refresh cookie's `Path=/v1/auth/refresh` without the caveat only `Cookie.hs:72-79`
carries. After line 104 add: "The refresh cookie's `Path` is the served path of `ShomeiRoutes`' refresh route under
`/v1`. A host that mounts `ShomeiAPI` at another prefix breaks the match — the browser never sends the cookie — and
with it cookie-mode refresh." `api.md:385-388` omits three routes that also refuse delegated tokens
(`shomei-servant/src/Shomei/Mfa/Handler.hs:51, 63, 69`): add `POST /v1/auth/totp/enroll`, `DELETE /v1/auth/totp`, and
`POST /v1/auth/recovery-codes`. `POST /v1/auth/totp/verify` is not refused (`:56-59`); leave it off and do not claim it
is. `api.md:485-488` "Gated by the `RequireRole "admin"` route combinator" → `RequireAdmin` with M1's role-or-scope
wording; delete the block-quote at `:490-492` ("Admin-role limitation … no production flow yields an admin token
yet"), since roles are issued by `shomei-admin roles grant` and `PUT /v1/admin/users/{userId}/roles/{role}`
(`:463-466`). `api.md:174` (`scope` always present), `:197` (`/oauth/token` "is **not** rate-limited"), and `:354`
(freshness) belong to EP-2, EP-4, and EP-4; M5 probes them.

`oidc.md:77-79` ("a Shōmei bearer token today, and the cookie transport once `tokenTransport` includes cookies") and
`:95-97` ("once the cookie transport is enabled; until then the login-redirect path covers it") are future tense for a
feature plan 31 shipped: `GET /oauth/authorize` authenticates through `resolveAuthUser`, the same machinery as every
authenticated route, which reads the `shomei_session` cookie when `tokenTransport` is `cookie` or `both` and ignores
it under `bearer`. Rewrite in the present: "a Shōmei bearer token, or the `shomei_session` cookie when `tokenTransport`
is `cookie` or `both`" and "and carries the session cookie when the cookie transport is on; under bearer transport the
login-redirect path covers it". `oidc.md:123-125` is EP-2's; M5 probes it.

`passkeys.md:129-130` ("The browser refuses any ceremony whose page origin is not in `origins`") names the wrong
party: Shōmei's server-side verification refuses it (webauthn's `Authentication.hs:311-313`,
`Registration.hs:411-413`); the browser enforces `rpId`. Replace with: "Shōmei refuses, server-side, any ceremony whose
page origin is not in `origins`; the browser, for its part, will not use a passkey enrolled under one `rpId` for
another." Commit as `docs(api,deployment): reconcile the endpoint and operations references with the code` with the
standard trailers.

### Milestone M5 — the per-sibling verification sweep, the link check, and the OpenAPI diff

This milestone edits nothing by design; it runs probes and records results. Each sibling has a *landed probe* (a code
grep that is non-empty only after it merged) and *doc probes* (what its pages must say afterwards). Landed probe empty:
leave its sentences, list them under Outcomes as deferred with the doc probe, move on. Landed probe non-empty but a
doc probe fails: the sibling forgot its documentation — fix the sentence in this milestone's commit and say so in
Surprises. Each probe below is one command; `#` comments state the expectation (`empty` means no output). The block
is copy-pasteable as a whole; read the results sibling by sibling.

```bash
# EP-1 (plan 51) — landed:
rg -n "SessionKind|sessionKind" shomei-core/src/Shomei/Session/Domain.hs
rg -n -i "non-interactive|interactive session" docs/user/oidc.md docs/user/security.md   # non-empty: refusal at /oauth/authorize stated
# EP-2 (plan 52) — landed:
rg -n "grantedScopes|granted_scopes" shomei-core/src/Shomei/Session/Domain.hs
rg -n -i "client-bound|bound to the client" docs/user/oidc.md docs/user/api.md          # non-empty; api.md:174 true of refresh_token too
rg -n -i "reserved" docs/user/machine-tokens.md docs/user/oidc.md                        # non-empty: the reserved scope list
rg -n -i "consent" docs/user/oidc.md                                                     # non-empty: the trust-model statement
# EP-3 (plan 53) — landed:
rg -n "allowedClockSkew" shomei-core/src/Shomei/Config.hs
rg -n -i "clock skew" docs/user/deployment.md docs/user/security.md                      # non-empty
rg -n -i "ES256.*timing|timing.*ES256" docs/user/security.md                             # non-empty: the trade-off
rg -n "jwkAlg" shomei-jwt/src; rg -n "kid" shomei-jwt/src/Shomei/SigningKey/Verify/Jwt.hs  # both non-empty: security.md:19-21 true
rg -n -i "unique.*active|active.*unique" shomei-migrations/migrations/shomei/*.sql        # non-empty: security.md:55 enforced
# EP-4 (plan 54) — landed:
rg -n "authTime|auth_time" shomei-core/src/Shomei/Authorization/Claims/Domain.hs
rg -n "locked" shomei-core/test --glob '*TimingSpec*'                                    # non-empty: security.md:199 "exactly one" true
rg -n "is \*\*not\*\* rate-limited" docs/user/api.md                                     # empty
rg -n "mfa/complete" docs/user/security.md; rg -n "auth_time" docs/user/api.md docs/user/mfa.md   # non-empty
rg -n -i "second.factor" docs/user/security.md                                           # a hit inside "Abuse protection"
# EP-5 (plan 55) — landed:
rg -n "CompletePasswordReset" shomei-core/src/Shomei/Session/UnitOfWork/Store.hs
rg -n "PostgreSQL 17" docs/user/deployment.md                                            # non-empty: the version floor
rg -n "EmailAlreadyRegistered" shomei-core/src/Shomei/Session/Authentication/Workflow.hs # non-empty: api.md:124 409 email_taken true
# EP-6 (plan 56) — landed:
rg -n "rejectUnknownFields" shomei-server/src/Shomei/Server/Config.hs
rg -n "closed\* record type" docs/user/deployment.md                                     # empty
rg -n -i "refuse.* to boot|refuses to start" docs/user/deployment.md                     # non-empty, near Argon2
rg -n "notifierTransport|oidcEnabled|defaultRoles" docs/user/deployment.md               # non-empty
# EP-7 (plan 57) — landed when EMPTY (the secret left ShomeiConfig):
rg -n "smtpPassword" shomei-core/src/Shomei/Config.hs
rg -n "451" shomei-server/test --glob '*NotifySpec*'                                     # non-empty: notifications.md:204-207 true
rg -n -i "background|worker" docs/user/notifications.md; rg -n "http://" docs/user/notifications.md   # non-empty; a refusal, not advice
rg -n "SHOMEI_SMTP_PASSWORD|SHOMEI_WEBHOOK_SECRET" docs/user/deployment.md               # non-empty; security.md:183-184 names them
# EP-8 (plan 58) — landed:
rg -n "trustedProxies" shomei-core/src/Shomei/Config.hs shomei-server/src/Shomei/Server/Config.hs
rg -n "SHOMEI_TRUSTED_PROXIES|maxFailedLoginsPerIp|SHOMEI_MAX_FAILED_LOGINS_PER_IP" docs/user/deployment.md   # non-empty
rg -n -i "X-Forwarded-For|trusted prox" docs/user/security.md                            # non-empty
rg -n "single-instance deployment" docs/user/security.md                                 # empty
rg -n "payload_too_large" docs/user/problem-details.md                                   # non-empty: the 413 is problem-shaped
# EP-9 (plan 59) — landed:
rg -n "hostMiddleware|installHostBackgroundTasks" shomei-server/src/Shomei/Server/Boot.hs
rg -n -i "embedding checklist" docs/user/client-and-examples.md docs/user/architecture.md   # non-empty
rg -n "newTlsManager" examples/microservice-auth-stack/app/Main.hs                        # non-empty
rg -n -i "forgery|plaintext" docs/user/client-and-examples.md                             # non-empty
rg -n "does not currently" docs/user/client-and-examples.md                               # empty: Shōmei sends max-age=300
rg -n "EN_API_KEYS_READ_ONLY" examples/microservice-auth-stack/README.md                  # non-empty
rg -n -i "embedded host|embedding host" docs/user/security.md                             # non-empty: the "no restart" claim qualified
rg -n "docs/passkeys.md" examples                                                         # empty
```

Then the two mechanical checks, written to `$SCRATCH` so nothing new enters the tree. The link check walks
`README.md`, `CHANGELOG.md`, `docs/user`, `docs/capabilities`, `docs/reviews`, and every `examples/**/README.md`,
resolves each relative Markdown link against its file's directory (fragments stripped, URL schemes skipped), and checks
that every capability `resource:` exists — the check REV-1 ran by hand:

```bash
cat > "$SCRATCH/linkcheck.py" <<'EOF'
import re, sys, pathlib
files = [pathlib.Path('README.md'), pathlib.Path('CHANGELOG.md')]
for d in ('docs/user', 'docs/capabilities', 'docs/reviews'):
    files += sorted(pathlib.Path(d).glob('*.md'))
files += sorted(pathlib.Path('.').glob('examples/**/README.md'))
link = re.compile(r'\]\(([^)\s#]+)(#[^)]*)?\)')
bad = 0
for f in files:
    for n, line in enumerate(f.read_text().splitlines(), 1):
        for target, _ in link.findall(line):
            if not re.match(r'^[a-z]+:', target) and not (f.parent / target).exists():
                print(f'{f}:{n}: missing {target}'); bad += 1
        m = re.match(r'\s*resource: (\S+)', line)
        if m and f.parent.name == 'capabilities' and not pathlib.Path(m.group(1)).exists():
            print(f'{f}:{n}: missing resource {m.group(1)}'); bad += 1
print(f'{bad} broken link(s)'); sys.exit(1 if bad else 0)
EOF
python3 "$SCRATCH/linkcheck.py"
```

At HEAD it prints `CHANGELOG.md:179: missing docs/user/service-tokens.md`,
`examples/embedded-servant-app/www/README.md:12: missing ../../../docs/passkeys.md`, and `2 broken link(s)`; after M3
it prints `0 broken link(s)` and exits 0. The OpenAPI diff compares every `` `METHOD /path` `` in `api.md` with the
`paths` of `docs/api/openapi.json`, allowing the three paths `api.md` names on purpose: `/auth/login` (the `404`
example at `:28`), `/metrics` (a WAI middleware, never in the router), and `/v1/admin/users/{userId}/roles/admin` (a
prose instance of the `{role}` route):

```bash
python3 - <<'EOF'
import json, re
allow = {'/auth/login', '/metrics', '/v1/admin/users/{userId}/roles/admin'}
spec = set(json.load(open('docs/api/openapi.json'))['paths'])
doc = {m.group(1) for m in re.finditer(r'`(?:GET|POST|PUT|DELETE) (/[^`\s|]+)`', open('docs/user/api.md').read())}
print('api.md only:', sorted(doc - spec - allow)); print('openapi only:', sorted(spec - doc))
EOF
```

Expected at HEAD and after: `api.md only: []` and `openapi only: []` — the review found no real drift, and this makes it
repeatable. A sibling's new route shows under `openapi only`; add its `api.md` section here and record the omission.
Update Progress and Outcomes, then commit as `docs(plans): record the EP-10 verification sweep over the sibling plans`
with the standard trailers.

### Milestone M6 — verify the MasterPlan 8 ADRs exist and are linked

Last because the ADRs are the siblings' deliverables. If `docs/adr/` does not exist, no sibling that owes one has
landed; record that and stop. Otherwise confirm each decision has a record and that the page stating its rule links to
it:

```bash
ls docs/adr
rg -n -i "provenance|interactive" docs/adr/*.md | head -3                 # EP-1
rg -n -i "reserved.*scope|privilege scope" docs/adr/*.md | head -3        # EP-2
rg -n -i "exception text|never persisted" docs/adr/*.md | head -3         # EP-7
rg -n -i "trusted prox" docs/adr/*.md | head -3                           # EP-8
rg -n -i "embedding contract|embedding host" docs/adr/*.md | head -3      # EP-9
rg -n "\.\./adr/|docs/adr/" docs/user/security.md docs/user/oidc.md docs/user/machine-tokens.md docs/user/notifications.md docs/user/deployment.md docs/user/client-and-examples.md
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

The link grep must show one link per landed decision: provenance from `oidc.md` or `security.md`, reserved scopes from
`machine-tokens.md` or `oidc.md`, the exception-text rule from `notifications.md`, the trusted-proxy policy from
`deployment.md`, the embedding contract from `client-and-examples.md`. Add any missing link (one relative link in the
paragraph stating the rule). Run the strict `okf validate` only if `mori.dhall` (or `mori show --full`) lists an OKF
bundle at `docs/adr` with a profile; expected `OK: <n> concepts (okf_version 0.2)`, exit 0. If the bundle has no
profile, preserve the siblings' convention and record it in Outcomes. Commit as `docs(adr): verify the MasterPlan 8
decision records are linked from the user docs` with the standard trailers.


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/shomei`; set `SCRATCH` to a directory outside the tree. Confirm the baseline
first so the later greps mean something:

```bash
git rev-parse --short HEAD
rg -n "Shomei/Crypto.hs|argon2id\\$" docs/user/security.md
rg -n "no caller authentication|plan 33 \(unimplemented\)" docs/user/authorization.md examples/microservice-auth-stack/README.md
rg -n "/auth/signup" README.md
rg -n "Shomei.Workflow.verifyToken|Shomei.Jwt.Verify" CHANGELOG.md shomei-servant/CHANGELOG.md
```

Expected at `5dfd2a6`: `security.md:8`, `:9`; `authorization.md:149-150` and the README's `:145`; `README.md:53`,
`:56`; `CHANGELOG.md:44`, `:46`, `:50`, `shomei-servant/CHANGELOG.md:21`. For each milestone: make the edits named in
Plan of Work; before each, open the cited code line and confirm it still says what the plan quotes (if not, a sibling
changed it — find the sentence by the quoted "before" text); run the milestone's acceptance greps; commit with the
message given. Before M2, re-verify en:

```bash
cd /Users/shinzui/Keikaku/bokuno/en && git rev-parse --short HEAD
sed -n '43p' en-postgres/src/En/Postgres/Database.hs
sed -n '47,48p' en-migrations/en-migrations.cabal && ls en-migrations/migrations
rg -n "EN_API_KEYS_READ_WRITE|EN_API_KEYS_READ_ONLY" en-server/app/Config.hs | head -3
rg -n "subjectFromUserId" --glob '!docs/plans/*' . | cut -d: -f1 | sort -u
```

Expected: `bf8ffa2`; `runDatabasePool :: (IOE :> es) => Pool.Pool -> …`; the two `pg-migrate` lines and
`0001-en-bootstrap.sql manifest`; `Config.hs:370-371`; exactly `./docs/user/biscuit-decision-tokens.md` and
`./en-biscuit/test/Main.hs`. If en has moved past `bf8ffa2`, re-read plan 33's Decision Log and `Middleware.hs:1-9`
before claiming the JWT rejection still stands, and update the section title's hash. Finally tick Progress, fill
Outcomes with the deferred list, and append a revision note at the bottom of this file.


## Validation and Acceptance

One block per milestone; the expected output follows it. After M1:

```bash
rg -n "Shomei/Crypto.hs|argon2id\\$<b64|normalized email|RequireRole \"admin\"\`, so a request" docs/user/security.md
rg -n "Last reconciled with the code on" docs/user/security.md
rg -n "SignatureCounterZero|suspended or deleted" docs/user/security.md | wc -l
cabal build shomei-core 2>&1 | tail -1
```

```text
(no output)
5:Last reconciled with the code on 2026-…
2
(a successful build's last line; no new warnings)
```

After M2:

```bash
rg -n -i "no caller authentication|authenticates nobody|plan 33 \(unimplemented\)|will itself verify|by verifying Shōmei JWTs|single-\`Connection\`|has not moved to" docs/user examples/*/README.md
rg -n "EN_API_KEYS_READ_ONLY|runDatabasePool|en-migrate|subjectFromUserId|d3209cb" docs/user/authorization.md | wc -l
rg -n "/Users/shinzui" docs/user
```

```text
(no output)
5
(no output)
```

After M3 and M4:

```bash
rg -n "Effect/\*" docs/user/architecture.md; rg -n "two runnable" docs/user/index.md
rg -n "localhost:8080/auth/|\"email\":\"alice@example.com\",\"password\"" README.md
rg -n "Shomei.Workflow.verifyToken|Shomei.Jwt.Verify|service-tokens.md" CHANGELOG.md shomei-servant/CHANGELOG.md
rg -n "Addendum" docs/masterplans/6-operational-and-performance-hardening.md | wc -l
rg -n "term-level" docs/capabilities/type-level-authorization-guards.md | wc -l
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf validate docs/capabilities --strict --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce 2>&1 | grep -vc "missing profile-recommended field: reviews"
rg -n "authorization_codes|role_grants" docs/user/deployment.md | wc -l
rg -n "with no active lock are never swept|running failure count for an account" docs/user/deployment.md
rg -n "mounts \`ShomeiAPI\` at another prefix|totp/enroll|RequireAdmin" docs/user/api.md | wc -l
rg -n "no production flow|once \`tokenTransport\` includes cookies|until then the login-redirect" docs/user/api.md docs/user/oidc.md
rg -n "The browser refuses" docs/user/passkeys.md
```

```text
(no output from the first three lines)
1
1
OK: 24 concepts (okf_version 0.2)
0
5
(no output)
4
(no output)
(no output)
```

The `5` is the JSON line, two CLI lines, and two table rows; the `4` is the `totp/enroll` route heading, its new
blocked-list entry, `RequireAdmin`, and the mount caveat. After M5 the link check prints `0 broken link(s)` and exits
0, the OpenAPI diff prints two empty lists, every landed sibling's doc probes hold, and every un-landed sibling's
sentences are listed in Outcomes with their probe. After M6 each `docs/adr` probe prints a filename for every landed
decision, the link grep prints one line per landed decision, and the strict `okf validate docs/adr` exits 0 if the
bundle is profiled. Throughout, `just reviews-validate` keeps printing `OK: 10 concepts (okf_version 0.2)`:
`docs/reviews/index.md` is deliberately untouched, because a review describes a commit and does not change when the
commit is fixed.


## Idempotence and Recovery

Every edit is a text replacement keyed on quoted "before" text, so re-running a milestone on a tree where it already
landed finds nothing to replace and the acceptance greps already pass; nothing is destructive. The one generated
artifact is the `docs/capabilities/log.md` entry: run `okf log add` once per bundle change; if it ran twice, delete
the duplicate bullet by hand and re-validate. If a sibling lands between milestones and moves a quoted line, find it
by text (`rg -n -F '<before text>' <file>`), not by number; if the sibling already fixed it, skip and note it.
`git revert <sha>` of any milestone commit is safe: no milestone depends on another's file state except M6 on the
siblings' ADRs. The stamp date in `security.md` is the date of the M1 commit; if M1 is re-run later, update it.


## Interfaces and Dependencies

No Haskell interface changes. The one source edit is the Haddock at
`shomei-core/src/Shomei/Session/LoginAttempt/Domain.hs:21`; `cabal build shomei-core` must succeed with no new
warnings. Documentation targets, all of which must exist at the end with the sentences above: `docs/user/security.md`,
`authorization.md`, `architecture.md`, `deployment.md`, `api.md`, `oidc.md`, `passkeys.md`, `index.md`; `README.md`;
`CHANGELOG.md`; `shomei-servant/CHANGELOG.md`; `docs/masterplans/6-operational-and-performance-hardening.md`;
`docs/capabilities/type-level-authorization-guards.md` and `log.md`; `examples/embedded-servant-app/www/README.md`;
`examples/microservice-auth-stack/README.md`. Read-only inputs: `docs/reviews/*.md`, the code lines cited beside each
edit, and en at `bf8ffa2` (`en-server/app/Middleware.hs`, `en-server/app/Config.hs`,
`docs/user/service-and-operations.md`, `en-postgres/src/En/Postgres/Database.hs`, `en-migrations/en-migrations.cabal`,
`en-migrations/migrations/`, `docs/plans/33-…`). Cross-repository references in prose use the project URI
`mori://shinzui/en` beside a repository-relative path, because en's artifact-level URIs for plans and user pages are
pending; never the path alone.
