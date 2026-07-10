---
id: 45
slug: smtp-and-webhook-notifier-interpreters
title: "SMTP and Webhook Notifier Interpreters"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
intention: "intention_01kx254gy7e429sh8erv1hee3n"
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# SMTP and Webhook Notifier Interpreters

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei (this repository, a Haskell authentication toolkit) emits *notifications* — today
exactly two kinds, "verify your email" and "reset your password", each carrying the
recipient address and a one-time link token — through an effect port called `Notifier`.
The standalone server ships exactly one interpreter for that port: `LogNotifier`, which
prints the notification to stderr. That makes email verification and password reset
production-inert for anyone running the stock binary: the message never leaves the
process unless the operator writes Haskell (the bring-your-own-interpreter path that
`docs/user/notifications.md` documents).

After this plan, the stock server can actually deliver. Two new interpreters become
selectable purely through configuration: an SMTP interpreter and a webhook interpreter
that POSTs the notification as JSON to a configured URL, signed with an HMAC-SHA256 header
so the receiver can authenticate it.

The SMTP interpreter is deliberately a **provider-relay client**, not a raw/self-hosted mail
sender. Its intended and documented use is to point at a provider's authenticated submission
endpoint — `email-smtp.<region>.amazonaws.com` (SES), `smtp.sendgrid.net`, `smtp.resend.com`,
Postmark, etc. — over implicit-TLS (465) or STARTTLS (587) with PLAIN/LOGIN auth. It speaks
SMTP because relay-to-provider over SMTP is still one of the most common config-only email
integrations in the ecosystem (Rails ActionMailer, Django's SMTP backend, and nodemailer all
default to it), which is exactly what makes "paste provider credentials, stock email leaves the
process" a zero-Haskell, near-zero-infrastructure path. It is **not** a way to run your own
mail server, and it does not do direct-to-MX delivery; the plaintext-port-25 mode exists solely
as a lab/test sink and must be documented as such, never as a production configuration. (Per
the MasterPlan Decision Log, 2026-07-10: "no one uses SMTP *directly* anymore" is true of
self-hosted MTAs and dead for transactional deliverability — but SMTP relay to a provider is
alive and is precisely what this interpreter targets.)

The webhook doubles as Shōmei's lightweight eventing hook —
the sanctioned place for hosts to attach side effects (their own templated email, chat
alerts, analytics) without writing a Haskell interpreter. Deliberately *not* built, per
the MasterPlan (`docs/masterplans/7-interop-wave-standards-based-auth-surface.md`): any
templating or i18n system — Shōmei emits fixed, minimal English content, and operators
who want branded copy own it via the webhook or a custom interpreter.

Observable outcome: with `notifierTransport = smtp` configured against a local sink
server, `POST /auth/verify-email/request` results in a real SMTP session delivering a
message containing the confirm link; with `webhook` configured, the same request delivers
a signed JSON POST whose signature verifies against the shared secret; delivery failures
are logged and audited but never fail the triggering HTTP request.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-10): `NotifierTransport` gains `SmtpNotifier`/`WebhookNotifier`; `SmtpTlsMode`/`SmtpConfig`/`WebhookConfig` sub-records + `smtpConfig`/`webhookConfig`/`alsoLogNotifications` on `NotifierConfig`, all defaulted in `defaultShomeiConfig`. Temporary log-fallback arms added to `runNotifierFromConfig`.
- [x] M1 (2026-07-10): Server `FileConfig`/env wiring (`SHOMEI_NOTIFIER_TRANSPORT`, `SHOMEI_NOTIFIER_ALSO_LOG`, `SHOMEI_SMTP_*`, `SHOMEI_WEBHOOK_*`; password/secret from env only); `validateNotifierConfig` boot-time validation; Dhall schema + example updated (new fields `Optional`, example keeps `log`); six `ConfigSpec` cases. `shomei-server-config-test` green; `dhall-to-json` on the example succeeds.
- [x] M2 (2026-07-10): deps added to `shomei-server` (`smtp-mail`, `mime-mail`, `crypton`, `memory`; test stanza `network`); the pinned set resolved them with __no__ `flake.module.nix` override — but `smtp-mail` is __0.3.0.0__, not the ≥0.5 the plan assumed (see Surprises). `cabal build shomei-server` green.
- [x] M2 (2026-07-10): SMTP interpreter `runNotifierSmtp` with the enumerated copy (on `/v1` paths), TLS-mode dispatch over smtp-mail 0.3's `sendMail'`/`sendMailSTARTTLS'`/`sendMailTLS'` (+ `WithLogin` variants), `System.Timeout` guard, `try @SomeException` catch-all, one redacted stderr line, and a `NotificationDeliveryFailed` audit event. Shared `publishDeliveryFailed`/`truncateError` helpers (reused by M3).
- [x] M2 (2026-07-10): `NotificationDeliveryFailed` event + `EventCodec` (both directions) + round-trip spec (count 39→40); socket-based SMTP sink test (`NotifySpec`) asserts RCPT/subject/link; refused-port failure test asserts the audit event, no throw, and no token in the error. Both green.
- [x] M3 (2026-07-10): `runNotifierWebhook` — derived-`ToJSON` body, `X-Shomei-Signature: sha256=<hex HMAC-SHA256>` over the exact bytes (exported `webhookSignature`), `X-Shomei-Notification-Type`/`Content-Type`/`User-Agent` headers, per-attempt `responseTimeout`, `max maxAttempts` attempts with `4^(k-1)`-second backoff, non-2xx counts as failure, all exceptions caught → shared `publishDeliveryFailed`. Reuses the passed `Manager` (M4 wires `Env.envHttpManager`).
- [x] M3 (2026-07-10): Warp stub-server tests — one asserting body round-trips to the `Notification`, the type header, and the signature verifies over the captured bytes; a retry-then-succeed test (no failure event); an exhaust-then-audit test (exactly `maxAttempts` attempts, redacted failure event, no token). All green.
- [x] M4 (2026-07-10): `runNotifierFromConfig` widened to `(IOE, AuthEventPublisher, Clock) => Manager -> ShomeiConfig -> …`, now a single dispatching `interpret_` that selects log/smtp/webhook per notification and implements the `alsoLogNotifications` tee inline (log-then-deliver, once) — **not** the plan's `interpose` tee, which would loop on re-`send` (see Decision Log). `runNotifierSmtp`/`runNotifierWebhook` refactored to delegate to shared `deliverSmtp`/`deliverWebhook`. `App.runAppIO` call site updated to pass `env.envHttpManager`. Also added a `SHOMEI_PUBLIC_BASE_URL` env override (the smtp transport needs `publicBaseUrl`, and env is the twelve-factor path) + a ConfigSpec assertion.
- [x] M4 (2026-07-10): `docs/user/notifications.md` fully rewritten — transports table, provider-relay framing with a per-provider host/port/TLS table and the verbatim copy, plaintext-25 called out as lab-only, webhook headers + payload JSON + `sha256=` signature scheme + verification pseudo-code + at-most-once-ish retry/idempotency guidance, full Dhall/env config reference (secrets env-only), `alsoLogNotifications` rollout, fire-and-forget + `notification_delivery_failed` observability, and the retained BYO interpreter as the third option ("stock binaries hardcode the log sender" deleted).
- [x] M4 (2026-07-10): E2E (`E2ESpec`) — a nested Warp stub receives the signed `email_verification_requested` POST driven through the real server over HTTP; the test verifies the signature over the captured bytes and replays the delivered token at `/v1/auth/verify-email/confirm` (→ 200), proving the token is live. Delivery is synchronous within the request handler, so no race.
- [x] Final (2026-07-10): `nix fmt` (my files only; reverted 9 unrelated pre-existing drift files per the EP-4 caveat), `cabal build all` clean, `TASTY_NUM_THREADS=1 cabal test all` green (all suites, exit 0); Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**2026-07-10 (M1) — the tree moved on since this plan was written: plan 30 (token redaction)
and EP-3 (the `/v1` move) both landed.** `NotifierConfig` already carries a `logRawTokens`
field, and `renderNotification`/`runNotifierLog` already redact the token by default (env
`SHOMEI_NOTIFIER_LOG_SECRETS` restores the full link). Two consequences for the rest of this
plan: (a) the confirm-link paths the current `LogNotifier` prints are `/v1/auth/verify-email/confirm`
and `/v1/auth/password-reset/confirm` — **the M2 SMTP copy must use the `/v1` paths**, not the
un-versioned paths the plan text quotes, so the emailed link matches the live route; (b) the M1
env overlay folds the pre-existing `logRawTokens` read into the new `overlayNotifierFromEnv`
rather than a standalone record update.

**2026-07-10 (M2; corrected post-M4) — `smtp-mail` unbounded defaults to 0.3.0.0, but a `>=0.5`
bound gets the maintained crypton-based 0.5.0.1 with no override.** The note below described the
0.3.0.0 path (cryptonite); it was superseded when the dependency was bounded to `>=0.5` (see the
top Decision Log entry). The 0.3.0.0-specific detail is retained for the record:** `cabal build` pulled `smtp-mail-0.3.0.0`
and `mime-mail-0.5.2` straight from the index into the dev shell's GHC 9.12.4 set; `crypton`/`memory`
were already present. No `flake.module.nix` override was needed. 0.3.0.0 still exports every function
this plan uses — `sendMail'`, `sendMailSTARTTLS'`, `sendMailTLS'` and their `sendMailWithLogin*'`
authenticated variants (`UserName`/`Password` are `String`) — plus `mime-mail`'s pure
`simpleMail' :: Address -> Address -> Text -> LText -> Mail`, so the interpreter is unchanged from the
plan's intent; only the version number differs. **M3's `crypton` HMAC is unaffected.**

**2026-07-10 (M2) — `AuthEvent` already has `EmailVerificationRequested`/`PasswordResetRequested`
constructors that collide with `Notification`'s.** `Shomei.Notify` and `NotifySpec` both pattern-match
`Notification`, so `import Shomei.Domain.Event (..)` is ambiguous — import it selectively
(`AuthEvent (NotificationDeliveryFailed)`, `NotificationDeliveryFailedData (..)`). Likewise a
test-local `expiresAt` binding clashes with the `Notification` field `expiresAt` under
`DuplicateRecordFields`; rename the fixture. **M3 imports the same modules and hits both.**

**2026-07-10 (M1) — the new Dhall config fields are `Optional`, not required.** Unlike the
existing scalar schema fields (`totpEnabled : Bool`, …), the EP-8 notifier fields
(`notifierTransport`, `smtpHost`, `webhookUrl`, …) are `Optional` in `config/shomei-types.dhall`
so a `log` deployment omits them entirely (`None Text` / absent → `Nothing` → defaults). Secrets
(`SHOMEI_SMTP_PASSWORD`, `SHOMEI_WEBHOOK_SECRET`) have no schema field at all — env-only, matching
how `SHOMEI_NOTIFIER_LOG_SECRETS` is already treated. `dhall-to-json` renders `None` as `null`,
which the all-`Maybe` `FileConfig` decodes as absent.


## Decision Log

Record every decision made while working on the plan.

- Decision: The SMTP interpreter is framed and documented as a **provider-relay client**, not
  a raw/self-hosted SMTP sender. Docs lead with the relay use case and give per-provider
  host/port/auth examples (SES, SendGrid, Resend, Postmark); implicit-TLS (465) and STARTTLS
  (587) with PLAIN/LOGIN are the production modes; the `SmtpPlain`/port-25 mode is presented
  strictly as a lab/test sink, never as a production option. The interpreter's code surface is
  unchanged by this decision — it is a positioning/documentation constraint that binds M2's
  copy comments and the M4 docs rewrite.
  Rationale: MasterPlan Decision Log, 2026-07-10. The user directed that a "pure SMTP notifier"
  has no place because "no one uses SMTP directly anymore." That is correct for self-hosted
  MTAs / direct-to-MX transactional mail (dead for deliverability), but not for SMTP relay to a
  provider, which is a mainstream config-only integration. Keeping the interpreter but reframing
  it preserves the zero-Haskell, near-zero-infrastructure delivery path (EP-8's whole purpose)
  while removing the misleading "run your own mail server" reading. Webhook-only was rejected
  (re-opens the zero-infrastructure gap); a provider-specific HTTP interpreter was rejected
  (couples Shōmei to one provider's API — the webhook already covers HTTP-API delegation).
  Date: 2026-07-10

- Decision (2026-07-10, post-M4): **upgrade `smtp-mail` to 0.5 and use crypton; the cryptonite
  workaround is removed.** At the user's direction ("don't use the obsolete Hackage package; upgrade
  if it's easy"), `shomei-server` now depends on `smtp-mail >=0.5`. Version 0.5.0.1 is on Hackage
  (published by `haskell-github-trust`, where development moved per jhickner/smtp-mail PR #42) and
  depends on `crypton` + `crypton-connection` + `ram` — **no cryptonite**. cabal had silently
  defaulted to the stale `0.3.0.0` only because the dependency was unbounded; a `>=0.5` bound is the
  entire fix (the solver picks `smtp-mail-0.5.0.1` + `crypton-connection-0.4.6` with no conflict,
  confirmed by `cabal build --dry-run`). No `source-repository-package` pin or `flake.module.nix`
  override is needed. With cryptonite gone from the plan, the webhook HMAC uses plain `crypton`
  imports like the rest of the repo, and the `PackageImports`-pinned cryptonite hack (and the
  `cryptonite` build-dep) are deleted. This **supersedes the M3 cryptonite decision below**, which
  existed only to work around the 0.3.0.0 collision. One follow-on: the `convertToBase Base16` for
  the HMAC hex must come from **`ram`**, not `memory` — crypton's `ByteArrayAccess (Digest)` instance
  is defined against `ram` (the repo's maintained `memory` fork, already used by shomei-core/
  shomei-postgres), so `shomei-server` depends on `ram` here, not `memory`.
  Rationale: an in-index, maintained, crypton-based release is not "obsolete" and carries no ongoing
  fork-maintenance burden — the exact condition the user set for keeping SMTP.
  Date: 2026-07-10

- Decision (2026-07-10, M4): the `alsoLogNotifications` tee is a single dispatching `interpret_`,
  not the plan's `interpose` wrapper. `interpose` re-handles an effect in place; forwarding to the
  underlying delivery by re-`send`ing `SendNotification` inside the interpose handler re-enters the
  same handler and loops. Instead `runNotifierFromConfig` is one handler that, per notification,
  optionally logs and then calls the selected per-notification delivery function
  (`logNotification`/`deliverSmtp`/`deliverWebhook`) exactly once. Same observable behavior (log +
  one real delivery), no loop hazard, and the delivery primitives are shared with the standalone
  `runNotifierSmtp`/`runNotifierWebhook` used by the tests.
  Rationale: correctness over matching the plan's suggested mechanism; the plan explicitly allows
  resolving such ambiguities autonomously.
  Date: 2026-07-10

- Decision (2026-07-10, M3): the webhook HMAC-SHA256 is computed with **cryptonite**, not
  crypton, in `Shomei.Notify` — the one place shomei-server touches cryptonite. `smtp-mail`
  0.3.0.0 depends on `cryptonite`, so both crypton (the repo standard) and cryptonite land in
  this package's plan exposing identical `Crypto.*` module names. Empirically only cryptonite's
  `ByteArrayAccess (Digest a)` instance reaches the type checker here; `convertToBase Base16` on a
  crypton digest fails to resolve even with a `PackageImports` crypton pin (the collision shadows
  crypton's instance module). The HMAC imports are therefore `PackageImports`-pinned to
  `"cryptonite"`, and `shomei-server`'s `build-depends` lists `cryptonite` instead of `crypton`.
  Rationale: the standards-conforming alternative (patch `smtp-mail` onto crypton via a
  `flake.module.nix` override) is disproportionate for one HMAC that a transitively-present,
  well-tested library computes correctly; the signature is the GitHub-style `sha256=<hex>` either
  way. Recorded rather than hidden because a future reader will wonder why this module alone uses
  cryptonite.
  Date: 2026-07-10

- Decision: SMTP dependency: `smtp-mail` (>= 0.5) for the wire protocol plus `mime-mail`
  for message construction — not `HaskellNet`/`HaskellNet-SSL`.
  Rationale: `smtp-mail` 0.5+ covers all three connection modes this plan needs
  (`sendMail'` plaintext, `sendMailSTARTTLS'`, `sendMailTLS'`) with AUTH LOGIN/PLAIN, has
  seen releases in the current ecosystem, and composes with `mime-mail`'s well-maintained
  `Mail` builder (`simpleMail'` for plain text). HaskellNet-SSL is older, split across
  two packages, and pulls a legacy connection stack. Verify both build in the pinned
  nixpkgs GHC 9.12.4 set before committing (Concrete Steps M2); if either is missing or
  broken there, add an override in `flake.module.nix` (the repo's designated
  conflict-free Nix extension point — there are currently zero Haskell overrides, so
  this creates the pattern) and record it here.
  Date: 2026-07-07

- Decision: Fire-and-forget delivery semantics are preserved and *hardened*: the new
  interpreters catch **all** exceptions internally; a delivery failure logs one redacted
  line and publishes a `NotificationDeliveryFailed` audit event, and the triggering HTTP
  request still succeeds.
  Rationale: The verified current contract: `Notifier`'s single operation returns `()`,
  the two workflow call sites (`requestEmailVerification` and `requestPasswordReset` in
  `shomei-core/src/Shomei/Workflow/Account.hs`) ignore it and unconditionally return
  `Right ()`, and `docs/user/notifications.md` promises "provider failures never surface
  to the HTTP caller". But today's `LogNotifier` cannot fail, so nothing actually catches
  IO exceptions — a throwing interpreter would propagate to Warp. SMTP/webhook *will*
  fail sometimes, so the catch becomes load-bearing now. The audit event gives operators
  the missing observability without breaking the contract; retry/queue/dead-letter
  remains the operator's job (webhook receivers, or a custom interpreter).
  Date: 2026-07-07

- Decision: Add a `NotificationDeliveryFailed` audit event (channel, notification type,
  recipient email, truncated error text, timestamp — never the token). No
  "delivery succeeded" event.
  Rationale: The workflows already audit the *request* (`email_verification_requested`,
  `password_reset_requested`); a success event would double-write on every send. Failures
  are the actionable signal. The event is possible because in the server's interpreter
  stack (`Shomei.Server.App.runAppIO`) `Notifier` is peeled while `AuthEventPublisher`
  is still in the residual effect row, so the interpreter can legally carry an
  `AuthEventPublisher :> es` constraint — verified against the current composition order.
  Date: 2026-07-07

- Decision: Fixed English copy, enumerated in this plan (see Plan of Work M2), one plain
  text body per notification type. No templating, no i18n, no HTML part.
  Rationale: MasterPlan decision. Operators who need branding/localization take the
  webhook (receiving the structured payload and rendering their own message) or a custom
  interpreter. Plain text only also sidesteps HTML-injection concerns entirely.
  Date: 2026-07-07

- Decision: Webhook signature: header `X-Shomei-Signature: sha256=<lowercase hex>` where
  the digest is HMAC-SHA256 over the exact raw request body bytes with the configured
  secret; plus `X-Shomei-Notification-Type: email_verification_requested |
  password_reset_requested` and `Content-Type: application/json`. Secret comes only from
  an environment variable (`SHOMEI_WEBHOOK_SECRET`), never Dhall.
  Rationale: The `sha256=`-prefixed hex-HMAC-over-raw-body convention is the one webhook
  consumers already know (GitHub popularized it), so receiver libraries exist in every
  language. Signing raw bytes (not re-serialized JSON) makes verification exact.
  Keeping the secret out of config files matches how the repo already treats passwords.
  Date: 2026-07-07

- Decision: Webhook delivery is best-effort at-most-once *per attempt window*: 3 total
  attempts (initial + 2 retries) with 1 s and 4 s backoff, 5-second per-attempt timeout,
  then give up with the failure log + audit event. No persistent queue; a non-2xx
  response counts as failure. Consequently a receiver may see a notification 0 times
  (all attempts failed) or, rarely, more than once (a timeout after the receiver
  processed it) — receivers must treat deliveries as idempotent-by-token.
  Rationale: A durable at-least-once queue is a real subsystem (table, sweeper,
  ordering) that the fire-and-forget contract does not justify; bounded in-process
  retries fix the dominant failure mode (transient network/receiver restart) at near-zero
  complexity. The duplicate caveat is inherent to any retry-on-timeout scheme and is
  documented rather than hidden.
  Date: 2026-07-07

- Decision: Transport selection stays a single `notifierTransport` value (`log | smtp |
  webhook`), plus a new independent boolean `alsoLogNotifications` (default `False`)
  that tees every notification through the log interpreter in addition to the selected
  transport.
  Rationale: The requested "log + one real transport for staged rollout" capability
  without turning the field into a list — `NotifierConfig` is an append-only record
  (house rule), and a list-valued replacement field would orphan the existing scalar. A
  boolean tee is the smallest surface that covers the rollout story; multiple *real*
  transports simultaneously remains out of scope (a custom interpreter can fan out).
  Date: 2026-07-07

- Decision: This plan does not change what `LogNotifier` prints. The log-redaction work
  (tokens in log lines) belongs to
  `docs/plans/30-login-timing-oracle-fix-email-verification-enforcement-and-notifier-token-redaction.md`
  (unwritten skeleton as of 2026-07-07). This plan's own obligation is negative: the
  *new* interpreters' operational logs (delivery attempts, failures) must never contain
  the one-time token — only recipient, type, and error.
  Rationale: Related-but-independent scope; duplicating plan 30's redaction here would
  create merge conflicts, but reintroducing raw tokens into fresh log lines would
  actively worsen what plan 30 sets out to fix. Note the webhook *payload* necessarily
  carries the raw token (that is its function — the receiver builds the link); the docs
  say so and require HTTPS/internal endpoints, as the current notifications guide
  already warns for the sketched webhook variant.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-07-10): delivered in full.** The stock `shomei-server` binary can now deliver
verification/reset email through configuration alone. `notifierTransport = smtp` relays a
fixed plain-text message through a provider's submission endpoint (implicit-TLS / STARTTLS /
lab-plaintext); `notifierTransport = webhook` POSTs an HMAC-signed JSON body a receiver can verify
and use as an eventing hook; both are fire-and-forget and hardened (all exceptions caught, one
redacted log line + a `notification_delivery_failed` audit event on failure, the triggering HTTP
request always succeeds). The default stays `log`, so an unconfigured deployment is byte-identical
in behavior. The observable acceptance in Purpose — request over HTTP → signed payload whose token,
replayed at `/v1/auth/verify-email/confirm`, verifies the email — is proven by the M4 E2E test.

**Deviations from the plan as written, all recorded in the Decision Log / Surprises:**

1. The tree had moved on: plan 30 (token redaction) and EP-3 (the `/v1` move) both landed before
   this plan ran. `NotifierConfig` already carried `logRawTokens`; the SMTP copy uses the live
   `/v1/...` confirm paths, not the un-versioned paths the plan text quoted.
2. `smtp-mail` was first taken unbounded, which cabal defaulted to the stale **0.3.0.0**
   (cryptonite-based); on the user's direction this was corrected to a `>=0.5` bound, resolving to
   the maintained **0.5.0.1** on Hackage (crypton + crypton-connection + ram), with no Nix override
   and no fork pin. 0.5 exports the same send functions, so the interpreter is unchanged.
3. Consequently the webhook HMAC uses plain **crypton** like the rest of the repo. The temporary
   `PackageImports`-pinned cryptonite hack (only needed while 0.3.0.0 forced cryptonite into the
   plan) is gone. See the top Decision Log entry.
4. The `alsoLogNotifications` tee is a single dispatching `interpret_`, not the plan's `interpose`
   wrapper (which would loop on re-`send`). Same behavior, no loop hazard.
5. Added a `SHOMEI_PUBLIC_BASE_URL` env override (the smtp transport requires `publicBaseUrl`, and
   env is the twelve-factor path). Small, in-spirit addition with a ConfigSpec assertion.

**Gaps / non-goals honored:** no templating/i18n/HTML (fixed English copy); no persistent queue
(bounded in-process retries, duplicates-by-timeout documented as idempotent-by-token); TLS-handshake
SMTP sinks are not exercised in tests (mode-selection is unit-tested; the plaintext sink covers the
wire framing) — noted in the plan and docs as intended.

**Lessons for later plans (see Surprises):** the `AuthEvent` vs `Notification` constructor-name
collision and the `expiresAt` field-vs-fixture clash bite any module importing both; the
crypton/cryptonite coexistence is a real hazard whenever a new dep drags cryptonite in; and
`nix fmt` still sweeps unrelated files — revert them, format only your own.


## Context and Orientation

The repository is a multi-package Haskell Cabal project at
`/Users/shinzui/Keikaku/bokuno/shomei` (GHC 9.12.4; work inside `nix develop`;
`cabal build all`; `cabal test all`; format `nix fmt`; the dev database — needed only for
the E2E part of this plan — via `just create-database`).

The notification pipeline, verified end to end in the working tree:

*The port.* `shomei-core/src/Shomei/Effect/Notifier.hs` — one operation:

```haskell
data Notifier :: Effect where
  SendNotification :: Notification -> Notifier m ()

type instance DispatchOf Notifier = Dynamic

sendNotification :: (Notifier :> es) => Notification -> Eff es ()
```

*The payload.* `shomei-core/src/Shomei/Domain/Notification.hs` — exactly two
constructors with identical fields, and it derives `ToJSON`/`FromJSON` (the webhook body
therefore needs no bespoke encoder, and the JSON includes the raw token):

```haskell
data Notification
  = EmailVerificationRequested { email :: !Email, token :: !OneTimeToken, expiresAt :: !UTCTime }
  | PasswordResetRequested    { email :: !Email, token :: !OneTimeToken, expiresAt :: !UTCTime }
```

Accessors: `Shomei.Domain.Email.emailText`, `Shomei.Domain.OneTimeToken.oneTimeTokenText`.

*The producers.* Exactly one module calls `sendNotification`:
`shomei-core/src/Shomei/Workflow/Account.hs`, in `requestEmailVerification` (expiry from
`cfg.notifierConfig.verificationTokenTTL`) and `requestPasswordReset` (from
`passwordResetTokenTTL`). Both guard on an active user (and unverified email for the
former), both fire the notification then publish their audit event, and both return
`Right ()` unconditionally — enumeration-safe 202-style endpoints. No other workflow
notifies.

*The current interpreter and its selector.*
`shomei-server/src/Shomei/Notify.hs` exports `runNotifierFromConfig` and
`runNotifierLog`:

```haskell
runNotifierFromConfig :: (IOE :> es) => ShomeiConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierFromConfig cfg =
    case cfg.notifierConfig.notifierTransport of
        LogNotifier -> runNotifierLog cfg.notifierConfig
```

`runNotifierLog` is an `interpret_ \case SendNotification n -> liftIO (hPutStrLn stderr ...)`
that renders the recipient, the confirm link
(`publicBaseUrl <> "/auth/verify-email/confirm?token=" <> ...` or the
`/auth/password-reset/confirm` variant), and the expiry. Note it currently prints the
raw token (see the Decision Log entry about plan 30).

*Config.* `NotifierTransport` and `NotifierConfig` live in *shomei-core*
(`shomei-core/src/Shomei/Config.hs`), not the server package:

```haskell
data NotifierTransport = LogNotifier

data NotifierConfig = NotifierConfig
  { emailVerificationRequired :: !Bool,
    verificationTokenTTL :: !NominalDiffTime,
    passwordResetTokenTTL :: !NominalDiffTime,
    notifierTransport :: !NotifierTransport,
    publicBaseUrl :: !Text
  }
```

`defaultShomeiConfig` sets `LogNotifier`. Crucially, the server's config loader
(`shomei-server/src/Shomei/Server/Config.hs`: defaults → Dhall file at `$SHOMEI_CONFIG`
rendered through `dhall-to-json` → `SHOMEI_*` env overrides) currently exposes **no**
file key or env var for `notifierTransport` at all — the transport is effectively
hardwired to log. The loader's enum-parsing pattern to copy is `transportEnv`/
`sessionCheckEnv` (~lines 489-526): parse a string, `ioError` loudly on bad input.

*Where the interpreter is wired.* `shomei-server/src/Shomei/Server/App.hs`, `runAppIO`:
a right-to-left composition of interpreters over the `AppEffects` row; the line
`. runNotifierFromConfig env.envConfig` sits *above* `runAuthEventPublisherPostgres` in
the composition, meaning `AuthEventPublisher` (and `Clock`, and `Database`) are still
available in the residual row when `Notifier` is interpreted — an interpreter here may
publish audit events. `Env` already carries `envHttpManager :: Manager`, a shared TLS
manager built with `newTlsManager` in `Shomei.Server.Boot` and used by the HIBP breach
checker — the webhook interpreter must reuse it, not allocate its own.

*Existing dependencies.* `shomei-server`'s library already depends on `http-client` and
`http-client-tls`; it does **not** depend on `crypton`, `memory`, or any base-16
encoder (all needed for HMAC hex — add them), nor on any SMTP/MIME package (none exists
anywhere in the workspace). There is no HMAC usage anywhere in the repo yet; the closest
idiom is plain SHA-256 hashing via `Crypto.Hash.hashWith` in
`shomei-core/src/Shomei/Workflow/ServiceToken.hs` and
`shomei-postgres/src/Shomei/Crypto.hs`.

*Nix.* `flake.nix` delegates to `nix/haskell.nix`, which builds against the plain
nixpkgs set `pkgs.haskell.packages.ghc9124` via `callCabal2nix`, with **zero** Haskell
overrides today. Project-specific Nix extensions belong in `flake.module.nix` (it
already adds `dhall-json` to the shell and defines the docker image) — that is where an
override would go if a Hackage package is missing/broken in the pinned set.

*Tests.* `shomei-server/test/Shomei/Server/E2ESpec.hs` boots the real WAI app in-process
with `Network.Wai.Handler.Warp.testWithApplication` against an ephemeral migrated
Postgres (`Shomei.Migrations.TestSupport.withShomeiMigratedDatabase`) and drives it with
`http-client`; its `postJSON`/`getJSON`/`dig` helpers are reusable. No test currently
runs a *second* stub server, but nesting another `testWithApplication` whose app captures
requests into an `MVar` is the intended pattern for the webhook test. The in-memory
`runNotifier` in `shomei-core/src/Shomei/Effect/InMemory.hs` records notifications into
`World.sentNotifications` — unchanged by this plan.

*The docs page to rewrite.* `docs/user/notifications.md` currently teaches: the
`Notifier` contract, a custom-provider interpreter example, "wiring it in" by editing
`runAppIO`, a sketched webhook variant, and two facts — no plugin hook in stock binaries
(this plan changes that fact) and fire-and-forget semantics (this plan keeps it).

A note on vocabulary: SMTP connection security comes in three modes. *Implicit TLS*
(port 465): the TCP connection is TLS from the first byte. *STARTTLS* (port 587): the
connection starts plaintext, the client issues `STARTTLS`, and the channel upgrades
before authentication. *Plaintext* (port 25, lab use only). AUTH PLAIN and AUTH LOGIN
are the two ubiquitous password mechanisms; `smtp-mail` handles both.


## Plan of Work

Four milestones. Everything is config-gated: the default transport remains `log`, so no
existing deployment changes behavior.

### Milestone M1 — Configuration surface

Scope: types, loading, validation. At the end, a config test proves every new knob
parses from Dhall and env, and a bad combination fails boot loudly. No delivery code yet.

In `shomei-core/src/Shomei/Config.hs`, extend the enum and add two sub-records:

```haskell
data NotifierTransport = LogNotifier | SmtpNotifier | WebhookNotifier

data SmtpTlsMode = SmtpPlain | SmtpStartTls | SmtpImplicitTls

data SmtpConfig = SmtpConfig
  { host :: !Text,
    port :: !Int,                 -- conventional: 25 plain, 587 starttls, 465 implicit
    tlsMode :: !SmtpTlsMode,
    username :: !(Maybe Text),    -- Nothing = unauthenticated (lab sinks)
    password :: !(Maybe Text),    -- populated from env only; never from Dhall
    fromAddress :: !Text,
    timeoutSeconds :: !Int        -- default 10
  }

data WebhookConfig = WebhookConfig
  { url :: !Text,
    secret :: !Text,              -- populated from env only; never from Dhall
    timeoutSeconds :: !Int,       -- default 5
    maxAttempts :: !Int           -- default 3
  }
```

Append to `NotifierConfig` (append-only record; every existing construction site keeps
compiling because the new fields get defaults in `defaultShomeiConfig`):
`smtpConfig :: !(Maybe SmtpConfig)`, `webhookConfig :: !(Maybe WebhookConfig)`,
`alsoLogNotifications :: !Bool` (default `False`). Extending `NotifierTransport` makes
the single-arm `case` in `Shomei.Notify.runNotifierFromConfig` non-exhaustive —
`-Wall` (on everywhere via the shared warnings stanza) flags it; add temporary arms that
fall back to `runNotifierLog` so the tree stays green until M2/M3 replace them.

In `shomei-server/src/Shomei/Server/Config.hs`: add `FileConfig` fields
(`notifierTransport :: Maybe Text`, `alsoLogNotifications :: Maybe Bool`, and flat
optional SMTP/webhook fields — `smtpHost`, `smtpPort`, `smtpTlsMode`, `smtpUsername`,
`smtpFromAddress`, `smtpTimeoutSeconds`, `webhookUrl`, `webhookTimeoutSeconds`,
`webhookMaxAttempts` — but deliberately no password/secret keys); merge them in
`baseFromFile`; add env overrides `SHOMEI_NOTIFIER_TRANSPORT` (`log|smtp|webhook`,
parsed with the `transportEnv`-style loud-failure helper), `SHOMEI_NOTIFIER_ALSO_LOG`,
`SHOMEI_SMTP_HOST/PORT/TLS_MODE/USERNAME/FROM/TIMEOUT`, `SHOMEI_SMTP_PASSWORD`,
`SHOMEI_WEBHOOK_URL/TIMEOUT/MAX_ATTEMPTS`, `SHOMEI_WEBHOOK_SECRET`. Validation at load
time, in the loud style of the existing service-token validation: transport `smtp`
requires a complete `SmtpConfig` (host, from-address; username and password must be both
present or both absent); transport `webhook` requires `url` (http/https) and a non-empty
secret; `publicBaseUrl` must be non-empty for `smtp` (the copy embeds links). Update
`config/shomei-types.dhall` and `config/shomei.example.dhall` (example keeps `log`).

Extend `shomei-server/test/Shomei/Server/ConfigSpec.hs`: Dhall + env round-trips for
each transport, and the failure cases (webhook without secret; smtp without host)
asserting the error text.

Acceptance for M1: `cabal test shomei-server:shomei-server-config-test` green;
`dhall-to-json --file config/shomei.example.dhall` still succeeds.

### Milestone M2 — SMTP interpreter

Scope: real email. At the end, a test SMTP sink receives a correctly framed message with
the exact copy below, and a refused connection produces the redacted failure log plus
audit event while the workflow still succeeds.

Nix/deps first. Check the pinned package set:

```bash
nix eval .#legacyPackages 2>/dev/null || true
nix develop --command ghc-pkg list 2>/dev/null | grep -Ei 'smtp-mail|mime-mail' || true
nix build --no-link nixpkgs#haskellPackages.smtp-mail nixpkgs#haskellPackages.mime-mail 2>&1 | tail -5
```

(The decisive check is simply adding `smtp-mail` and `mime-mail` to
`shomei-server/shomei-server.cabal` `build-depends` and running
`cabal build shomei-server` inside the dev shell — the shell's GHC package set comes from
the same pin.) If either fails to resolve or build, add an override in
`flake.module.nix` — e.g. a `haskellPackages.extend` with
`markUnbroken`/`callHackageDirect` for the affected package — and record exactly what was
needed in Surprises & Discoveries. Also add `crypton` and `memory` to `shomei-server`
(needed in M3, convenient to do once).

Add the audit event: `NotificationDeliveryFailed NotificationDeliveryFailedData` in
`shomei-core/src/Shomei/Domain/Event.hs` with
`{ channel :: Text, notificationType :: Text, recipient :: Text, errorText :: Text, occurredAt :: UTCTime }`
(`channel` = `"smtp"`/`"webhook"`; `errorText` truncated to ~500 chars by the publisher
call site; never a token). Map to event type `notification_delivery_failed` in
`Shomei.Domain.EventCodec` (both directions) and extend the codec round-trip spec.

Implement in `shomei-server/src/Shomei/Notify.hs` (keeping this module the home of all
notifier interpreters):

```haskell
runNotifierSmtp ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  NotifierConfig -> SmtpConfig -> Eff (Notifier : es) a -> Eff es a
```

For `SendNotification n`: build the message with `mime-mail`'s `simpleMail'` (to,
from = `fromAddress`, subject, plain-text body), pick the send function by `tlsMode`
(`sendMail'`/`sendMailSTARTTLS'`/`sendMailTLS'`, the authenticated variants when
credentials are configured), run it under `System.Timeout.timeout` (from
`timeoutSeconds`), and wrap the whole attempt in `try @SomeException`. On failure: one
stderr line `"[shomei:smtp] delivery_failed type=... recipient=... error=..."` (no
token anywhere) and publish `NotificationDeliveryFailed`. On success: nothing extra.

The exact copy — fixed, English, plain text (the only bodies Shōmei ever sends; the
`{...}` placeholders are filled from the payload and `publicBaseUrl`):

For `EmailVerificationRequested` — subject `Verify your email address`, body:

```text
Hello,

Please confirm your email address by opening this link:

{publicBaseUrl}/auth/verify-email/confirm?token={token}

This link expires at {expiresAt} (UTC). If you did not request this,
you can ignore this message.
```

For `PasswordResetRequested` — subject `Reset your password`, body:

```text
Hello,

A password reset was requested for your account. Open this link to
choose a new password:

{publicBaseUrl}/auth/password-reset/confirm?token={token}

This link expires at {expiresAt} (UTC). If you did not request this,
you can ignore this message and your password will remain unchanged.
```

(`{expiresAt}` rendered ISO-8601. These two links reuse the exact URL shapes the current
`LogNotifier` prints, so host confirm pages keep working unchanged.)

Test: a minimal SMTP *sink* in the test suite — a `Network.Socket`-based line server
(the `network` package is available transitively; add it to the test stanza) bound to
`127.0.0.1:0` that speaks just enough plaintext SMTP (`220` greeting; answer `250` to
`EHLO`/`MAIL FROM`/`RCPT TO`; `354` to `DATA`; collect lines until `.`; `250`; `221` on
`QUIT`) and stores the transcript in an `MVar`. Run `runNotifierSmtp` (via
`runEff . <stubs> . runNotifierSmtp ...` directly — no HTTP needed) with `SmtpPlain`
pointed at the sink's port; assert the captured `RCPT TO`, subject, and that the body
contains the confirm link. Failure test: point at a closed port; assert the workflow
value is unaffected, the stderr line appears (capture via a handle swap or just assert
the audit event), and `NotificationDeliveryFailed` was published (use a small in-test
event-collecting interpreter for `AuthEventPublisher`, mirroring the pattern in
`shomei-postgres/test/Main.hs`'s local capturing fake). STARTTLS/implicit-TLS paths are
exercised for construction only (mode selection unit test) — a full TLS handshake sink
is out of scope; note that in the docs.

Acceptance for M2: `cabal test shomei-server` green including the sink test; the failure
test proves fire-and-forget.

### Milestone M3 — Webhook interpreter

Scope: the signed JSON POST with retries. At the end, a stub Warp server run by the test
receives the body and a verifiable signature; a failing receiver triggers exactly
`maxAttempts` attempts then the redacted failure path.

Implement in `Shomei.Notify`:

```haskell
runNotifierWebhook ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  Manager -> WebhookConfig -> Eff (Notifier : es) a -> Eff es a
```

For `SendNotification n`: `body = BSL.toStrict (Aeson.encode n)` (the derived `ToJSON` —
constructor-tagged by aeson's default sum encoding; document the exact JSON in the docs
rewrite, taken from a captured test transcript); signature =
`"sha256=" <> lowercase hex (HMAC-SHA256 secret body)` using crypton
(`Crypto.MAC.HMAC.hmac`, `Data.ByteArray.Encoding.convertToBase Base16` — first HMAC use
in the repo; keep it local to this module); POST with headers `Content-Type:
application/json`, `X-Shomei-Signature`, `X-Shomei-Notification-Type` (the event-style
type string: `email_verification_requested` / `password_reset_requested`), and
`User-Agent: shomei`. Per attempt: `httpLbs` through the passed `Manager` with
`responseTimeout` set from `timeoutSeconds`; success = 2xx status. On failure sleep
1 s, retry; on second failure sleep 4 s, final attempt (generalize: backoff `4^(k-1)` s
capped by `maxAttempts`); after the last failure, the same redacted stderr line
(`channel=webhook`) and `NotificationDeliveryFailed`. All exceptions caught inside the
interpreter.

Embed receiver verification pseudo-code (also destined for the docs):

```python
# Receiver-side verification (pseudo-code)
import hmac, hashlib
def verify(raw_body: bytes, header: str, secret: bytes) -> bool:
    expected = "sha256=" + hmac.new(secret, raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)   # constant-time compare
```

Test, in `shomei-server`'s test suite: nest
`testWithApplication (pure stubApp) \port -> ...` where `stubApp` is a tiny WAI app that
appends `(headers, raw body)` to an `MVar [(RequestHeaders, ByteString)]` and returns
200. Drive `runNotifierWebhook` at it; assert exactly one delivery, the body decodes
back to the original `Notification` (round-trip through the derived `FromJSON`), the
type header matches, and recomputing the HMAC over the captured raw body with the test
secret equals the signature header. Retry test: a stub that answers 500 twice then 200 —
assert three attempts and ultimate success with no failure event; and a stub that always
500s — assert exactly `maxAttempts` attempts, then the failure event. Assert no attempt
log line contains the token text.

Acceptance for M3: `cabal test shomei-server` green including the stub-server tests.

### Milestone M4 — Selection wiring, docs, E2E

Scope: make configuration actually select the interpreters, rewrite the guide, prove it
through the real server.

Wiring. `runNotifierFromConfig` needs the manager and the wider constraints now; change
its signature and call site together:

```haskell
runNotifierFromConfig ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  Manager -> ShomeiConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierFromConfig mgr cfg =
    let nc = cfg.notifierConfig
        base = case nc.notifierTransport of
            LogNotifier -> runNotifierLog nc
            SmtpNotifier -> runNotifierSmtp nc (fromJust-with-boot-guarantee nc.smtpConfig)
            WebhookNotifier -> runNotifierWebhook mgr (…nc.webhookConfig)
     in if nc.alsoLogNotifications && nc.notifierTransport /= LogNotifier
            then teeToLog nc . base   -- see below
            else base
```

Do not literally use a partial `fromJust`: boot validation (M1) guarantees the
sub-config's presence, but pattern-match with a defensive fallback to `runNotifierLog`
plus a startup warning anyway. The tee: implement `teeToLog` as an *interposing*
wrapper — `interpose` from `Effectful.Dispatch.Dynamic` re-handles `SendNotification`
by first printing the log line (`renderNotification`) and then re-`send`ing to the
underlying handler; this composes without running the effect twice. In
`Shomei.Server.App.runAppIO`, update the composition line to
`runNotifierFromConfig env.envHttpManager env.envConfig` — its position (above the
event publisher) is load-bearing and stays.

Docs. Rewrite `docs/user/notifications.md`: a transports table (`log` — dev default;
`smtp` — built-in delivery via a **provider relay**, fixed English copy reproduced verbatim
from M2 — lead with the relay framing, give a short per-provider host/port/auth table
(SES `email-smtp.<region>.amazonaws.com:587` STARTTLS, `smtp.sendgrid.net:587`,
`smtp.resend.com:465` implicit-TLS, Postmark), state plainly that the plaintext/port-25 mode
is a lab-only sink and not for production, and note that Shōmei does *not* run a mail server or
deliver direct-to-MX;
`webhook` — signed JSON POST, positioned explicitly as *both* the notification transport
*and* the lightweight eventing hook for hosts that want to own copy/branding, attach
side effects, or call their provider's HTTP API from their own receiver); full config
reference (Dhall keys + env vars, secrets env-only); the
webhook payload JSON (captured from the test), the signature scheme, the verification
pseudo-code, the retry/at-most-once-ish semantics and idempotency guidance; the
fire-and-forget + `notification_delivery_failed` observability contract; the security
warning that webhook payloads carry live one-time tokens (HTTPS, internal endpoints,
secret rotation); `alsoLogNotifications` for staged rollout; and the retained
bring-your-own-interpreter section (still valid, now the *third* option, with the
"stock binaries hardcode the log sender" sentence deleted as no longer true).

E2E. Extend `shomei-server/test/Shomei/Server/E2ESpec.hs`: build the `Env` with a config
whose transport is `WebhookNotifier` pointed at a nested stub (as in M3, but now the
notification is triggered over HTTP through the real app): signup with an email → POST
`/auth/verify-email/request` → assert 202-style success *and* the stub captured a signed
`email_verification_requested` payload whose token, when used against
`/auth/verify-email/confirm`, verifies the email — proving the delivered token is the
live one. (SMTP through the full server is covered by the M2 interpreter-level sink
test; running the sink under the E2E app too is optional — add it only if cheap.)

Acceptance for M4: `cabal test all` green; manual Validation transcript reproduces.


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`. Baseline:

```bash
cabal build all
cabal test shomei-server
```

M1:

```bash
cabal test shomei-server:shomei-server-config-test
dhall-to-json --file config/shomei.example.dhall > /dev/null && echo dhall-ok
```

Expected: suite green; `dhall-ok`.

M2 (dependency probe first — record the outcome either way):

```bash
# add smtp-mail, mime-mail, crypton, memory to shomei-server.cabal, then:
cabal build shomei-server
```

If resolution fails inside the dev shell, the pinned nixpkgs set lacks the package; add
an override in flake.module.nix and re-enter the shell:

```bash
nix develop --command cabal build shomei-server
```

Then:

```bash
cabal test shomei-server
```

M3:

```bash
cabal test shomei-server
```

M4 and final:

```bash
nix fmt
cabal build all
cabal test all
```

Expected: all suites pass; a second `nix fmt` is a no-op. No migrations and no OpenAPI
changes are involved in this plan (no new routes; the audit event needs no schema
change because the events table stores type + JSONB payload).

Manual smoke against a throwaway webhook receiver:

```bash
# terminal 1: a dump server
nix run nixpkgs#python3 -- -m http.server 9999 &
SHOMEI_NOTIFIER_TRANSPORT=webhook SHOMEI_WEBHOOK_URL=http://127.0.0.1:9999/hook \
SHOMEI_WEBHOOK_SECRET=dev-secret cabal run shomei-server
# terminal 2:
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com"}' http://localhost:8080/auth/verify-email/request
```


## Validation and Acceptance

Acceptance is behavioral, per transport.

Webhook: with the server configured as in the smoke test above and a signed-up,
unverified user `alice@example.com`, `POST /auth/verify-email/request` returns its usual
success (enumeration-safe, unchanged), and the receiver logs a POST whose headers
include:

```text
Content-Type: application/json
X-Shomei-Notification-Type: email_verification_requested
X-Shomei-Signature: sha256=6f4c1a... (64 hex chars)
```

and whose body is the `Notification` JSON (tag + `email`/`token`/`expiresAt` fields).
Recomputing `HMAC-SHA256("dev-secret", raw_body)` and hex-encoding it reproduces the
header digest (the pseudo-code in the docs does exactly this). Killing the receiver and
repeating the request: the HTTP response is *still* success; stderr shows three attempt
failures ending in `"[shomei:webhook] delivery_failed type=email_verification_requested
recipient=alice@example.com error=..."` with **no token substring present**; and the
audit table gains a `notification_delivery_failed` row.

SMTP: with `SHOMEI_NOTIFIER_TRANSPORT=smtp SHOMEI_SMTP_HOST=127.0.0.1 SHOMEI_SMTP_PORT=<sink>
SHOMEI_SMTP_TLS_MODE=plain SHOMEI_SMTP_FROM=auth@example.com` (the automated sink test
covers this end to end; manually, `nix run nixpkgs#python3 -- -m smtpd -n -c
DebuggingServer 127.0.0.1:1025`-style sinks work), the same request produces a delivered
message whose subject is `Verify your email address` and whose body contains
`{publicBaseUrl}/auth/verify-email/confirm?token=...`; pasting that URL into
`POST /auth/verify-email/confirm` verifies the email — proving the delivered link is
live, not a rendering.

Staged rollout: setting `SHOMEI_NOTIFIER_ALSO_LOG=true` with the webhook transport
produces *both* the stderr `[shomei:log]` line and the webhook delivery for one request.

Regression guard: with no notifier configuration at all, the server boots, the transport
is `log`, and the pre-existing E2E suite passes unchanged — the default deployment is
byte-identical in behavior. Automated acceptance: `cabal test all` green, specifically
the config spec (M1), the SMTP sink + failure tests (M2), the webhook
signature/retry/failure tests (M3), and the E2E webhook round-trip (M4), plus the event
codec round-trip including `notification_delivery_failed`.


## Idempotence and Recovery

Everything is additive and config-gated; the default transport remains `log`, so merging
mid-plan is safe at every milestone boundary. Re-running tests and `nix fmt` is safe.
There are no migrations; the new audit event needs none (type + JSONB payload table).

The two risky edges and their recovery paths: (1) Dependency resolution — if
`smtp-mail`/`mime-mail` are broken in the pinned nixpkgs set even with a
`flake.module.nix` override, fall back to implementing the SMTP dialogue directly over
`network`/`tls` in `Shomei.Notify` (the protocol subset needed — EHLO, AUTH, MAIL, RCPT,
DATA — is small, and the sink test already exercises it); record the fallback as a
Decision Log entry before taking it. (2) The `runNotifierFromConfig` signature change —
it has exactly one production call site (`Shomei.Server.App.runAppIO`) and one
documented mention (`docs/user/notifications.md`); if other call sites appear (grep
before assuming), update them in the same commit or the build breaks loudly, which is
the desired failure mode.

If the webhook test flakes on attempt counting, the cause is almost always the stub
returning before the body is fully consumed — drain the request body in the stub before
responding. If a captured signature mismatches, verify the HMAC is computed over the
*exact* bytes sent (sign the strict body you pass to the request builder, never
re-encode).

Never fail the triggering request from an interpreter — if a change makes
`requestEmailVerification` return anything but `Right ()` on delivery failure, that is a
contract regression; the fire-and-forget tests exist to catch it. And never log the
one-time token from the new code paths (Decision Log; plan 30 owns the pre-existing
`LogNotifier` line).


## Interfaces and Dependencies

Project-local interfaces (verified): `Shomei.Effect.Notifier` (unchanged port),
`Shomei.Domain.Notification` (unchanged payload; its derived `ToJSON` is the webhook
wire format), `Shomei.Workflow.Account` (unchanged producers; fire-and-forget contract),
`Shomei.Notify` (extended: `runNotifierSmtp`, `runNotifierWebhook`, `teeToLog`, widened
`runNotifierFromConfig`), `Shomei.Server.App.runAppIO` (one-line call-site update;
interpreter position above `runAuthEventPublisherPostgres` is load-bearing),
`Shomei.Server.Boot`/`Env.envHttpManager` (shared TLS manager reused by the webhook),
`Shomei.Config` (extended `NotifierTransport`/`NotifierConfig`, new
`SmtpConfig`/`WebhookConfig`), `Shomei.Server.Config` (new file/env keys + validation),
`Shomei.Domain.Event`/`EventCodec` (new `NotificationDeliveryFailed`).

End-of-milestone signatures: after M1 — the extended config types above, loading, and
validation; after M2 —
`runNotifierSmtp :: (IOE :> es, AuthEventPublisher :> es, Clock :> es) => NotifierConfig -> SmtpConfig -> Eff (Notifier : es) a -> Eff es a`
and the `NotificationDeliveryFailed` event; after M3 —
`runNotifierWebhook :: (IOE :> es, AuthEventPublisher :> es, Clock :> es) => Manager -> WebhookConfig -> Eff (Notifier : es) a -> Eff es a`;
after M4 — the widened
`runNotifierFromConfig :: (IOE :> es, AuthEventPublisher :> es, Clock :> es) => Manager -> ShomeiConfig -> Eff (Notifier : es) a -> Eff es a`.

Third-party dependencies added to `shomei-server`: `smtp-mail` (SMTP dialogue, all three
TLS modes, AUTH PLAIN/LOGIN), `mime-mail` (message building), `crypton` (HMAC-SHA256),
`memory` (byte-array conversions + Base16 encoding); test stanza additionally `network`
(the SMTP sink). All standard Hackage packages expected in the pinned
`pkgs.haskell.packages.ghc9124` set; the Nix-override procedure via `flake.module.nix`
is specified in M2 for the case they are not.

This plan has no dependencies on other plans in the MasterPlan and nothing depends on
it; it is safe to implement at any point. Related-but-independent: plan 30 (LogNotifier
token redaction — untouched here), plan 44 (if TOTP ever wants notification of factor
changes, it would add `Notification` constructors and the fixed copy table here — out of
scope now).
