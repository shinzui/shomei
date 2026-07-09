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
selectable purely through configuration: an SMTP interpreter that sends plain-text email
(TLS, STARTTLS, or plaintext; PLAIN/LOGIN auth) and a webhook interpreter that POSTs the
notification as JSON to a configured URL, signed with an HMAC-SHA256 header so the
receiver can authenticate it. The webhook doubles as Shōmei's lightweight eventing hook —
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

- [ ] M1: `NotifierTransport` gains `SmtpNotifier`/`WebhookNotifier`; `SmtpConfig`/`WebhookConfig` sub-records + defaults in `Shomei.Config`; `alsoLogNotifications` flag.
- [ ] M1: Server `FileConfig`/env wiring (`SHOMEI_NOTIFIER_TRANSPORT`, SMTP/webhook fields, secrets from env only); boot-time validation; Dhall schema + example updated; `ConfigSpec` cases.
- [ ] M2: Nix availability check for `smtp-mail`/`mime-mail` recorded; deps added to `shomei-server`.
- [ ] M2: SMTP interpreter (`runNotifierSmtp`) with the enumerated copy; failure semantics (catch-all, redacted log, `NotificationDeliveryFailed` audit event).
- [ ] M2: `NotificationDeliveryFailed` event + codec + spec; SMTP sink-server test green.
- [ ] M3: Webhook interpreter (`runNotifierWebhook`): HMAC-SHA256 signature, timeout, bounded retries with backoff; reuses `Env.envHttpManager`.
- [ ] M3: Warp stub-server test asserting body, headers, and signature; retry/failure tests.
- [ ] M4: `runNotifierFromConfig` selection + log-tee wiring in `Shomei.Server.App.runAppIO`; constraint widening.
- [ ] M4: `docs/user/notifications.md` rewritten (transports, copy table, webhook verification pseudo-code, eventing-hook positioning, BYO path retained).
- [ ] M4: E2E: webhook transport driven through the real server.
- [ ] Final: `nix fmt`, `cabal build all`, `cabal test all` green; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

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

(To be filled during and after implementation.)


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
`smtp` — built-in delivery, fixed English copy reproduced verbatim from M2;
`webhook` — signed JSON POST, positioned explicitly as *both* the notification transport
*and* the lightweight eventing hook for hosts that want to own copy/branding or attach
side effects); full config reference (Dhall keys + env vars, secrets env-only); the
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
