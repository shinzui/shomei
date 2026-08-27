---
id: 57
slug: notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump
title: "Notifier and Log Hygiene: No Token or Secret Reaches a Log, Audit Row, or Config Dump"
kind: exec-plan
created_at: 2026-08-27T03:23:49Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
master_plan: "docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md"
---

# Notifier and Log Hygiene: No Token or Secret Reaches a Log, Audit Row, or Config Dump

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This is **EP-7** (Phase 3) of MasterPlan 8
(`docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md`).
No hard dependency; the soft dependency on EP-6 (`docs/plans/56-…`) concerns only the Dhall schema, and this
plan adds its one key as `Optional` either way.


## Purpose / Big Picture

Shōmei (this repository, a Haskell authentication toolkit) sends two kinds of *notification* — "verify your
email" and "reset your password" — each carrying a raw one-time token that, until it expires, *is* the
account. The August 2026 review found four ways that token or an operator secret escapes the process: a
relay rejecting at the `DATA` stage (greylisting `451`, content rejection `550`–`554`, routine at real
relays) makes `smtp-mail` raise an exception whose text embeds the *entire rendered message*, and
`Shomei.Notify` keeps its first 500 characters on stderr and in a persisted audit row — the link begins at
offset 368 of 620 with the documented example addresses, so the 43-character token is inside the cap and
anyone with log or audit access holds an account-takeover token for its TTL; delivery runs *inside* the
HTTP request, so a reset request for a registered address waits up to 10 s (SMTP) or ~20 s (webhook
retries) while an unknown address returns at once — an existence oracle by time; the SMTP password and
webhook secret live inside `ShomeiConfig`, the record `security.md` says is kept secret-free because it
derives `Show`/`ToJSON`, and env-supplied secrets are not trimmed; and raw tokens derive `Show`/`ToJSON`,
the `login_failed` audit row stores whatever was typed into the login field, and `shomei-admin users
create` takes the password on `argv`.

After this plan: point the server at a relay that answers `451` at `DATA`, request a reset, and read
`reason=rejected_at_data:451` — nothing else — on stderr and in the audit row;
`POST /v1/auth/password-reset/request` answers `202` in milliseconds while a slow receiver is still asleep,
and the delivery arrives afterwards with an `X-Shomei-Timestamp` header and a signature over
`<timestamp>.<body>`; `show` of a `TokenPair` prints `<redacted>`; `shomei-admin audit events --type
login_failed --json` shows a hashed `accountKey` and, when the credential resolved, a `userId`; and
`shomei-admin users create` reads the password from stdin or a file, honours the Dhall password policy and
breach setting, and can mark the bootstrap admin's email verified.


## Progress

- [x] (2026-08-27T21:27:00Z) M1: `DeliveryReason` vocabulary, `classifySmtpFailure`/`classifyWebhookFailure`, `redactDeliveryText`; `publishDeliveryFailed` takes a reason, never `displayException`
- [x] (2026-08-27T21:27:00Z) M1: NotifySpec — `451` at `DATA`, webhook connection-refused with a query-string secret, webhook `500` echoing the body, classifier table; both pre-fix failures pasted into Surprises & Discoveries
- [x] (2026-08-27T21:27:00Z) M1: [ADR-9](../adr/0009-transport-exception-text-is-never-persisted.md) added to the existing profile-governed bundle; `just adr-validate` and all four `shomei-server` suites green
- [x] (2026-08-27T21:42:36Z) M2: `Shomei.Notify.Queue` (bounded `TBQueue`, drop-with-audit, close/drain); `Env.envNotifierQueue`; request path enqueues
- [x] (2026-08-27T21:42:36Z) M2: `installNotifierWorker` on `supervisedLoopMicros` beside `installSweeper`; drained within `gracefulShutdownTimeoutSeconds` before the pool is released; `notifierQueueSize` in loader, `config/shomei-types.dhall`, `deployment.md`
- [x] (2026-08-27T21:42:36Z) M2: E2E webhook scenario installs the worker and polls; sub-second `202` against a receiver that sleeps 3 s; core `CostSpec` pins the hit/miss delta; [ADR-10](../adr/0010-notification-delivery-is-a-bounded-background-responsibility.md) records the queue and shutdown boundary
- [x] (2026-08-27T21:58:23Z) M3: `password`/`secret` removed from `SmtpConfig`/`WebhookConfig` (shomei-core 0.2.0.0); `NotifierSecrets` in `Env`; env values stripped; `https://` unless `SHOMEI_WEBHOOK_ALLOW_INSECURE`; `plain` + username refused unless `SHOMEI_SMTP_ALLOW_PLAINTEXT_AUTH`; [ADR-11](../adr/0011-runtime-secrets-stay-outside-printable-configuration.md)
- [x] (2026-08-27T21:58:23Z) M3: signature over `<unix-seconds>.<body>` with `X-Shomei-Timestamp`; NotifySpec, E2E, `notifications.md` updated with the 5-minute replay window; [ADR-12](../adr/0012-webhook-signatures-bind-a-bounded-attempt-time.md)
- [ ] M4: redacting `Show`, no JSON, on `RefreshToken`, `AccessToken`, `TokenPair`, client `Token`; `LoginFailedData` carries `accountKey`/`userId`; codec, workflow, tests, runbook
- [ ] M5: `users create` from stdin/`--password-file`, Dhall policy, HIBP interpreter, `--email-verified`; `Admin/Keys.hs` summarises `UsageError`; `BreachChecker` logs one line
- [ ] Final: `nix fmt`, `cabal build all`, `TASTY_NUM_THREADS=1 cabal test all` green; CHANGELOGs; MasterPlan 8 row and Progress; Outcomes; ADR distillation pass


## Surprises & Discoveries

- The regression-first SMTP case reproduced the persisted-token leak. smtp-mail quoted-printable-encoded and
  split the raw token, but the first 500 characters still retained both halves of the account-takeover
  credential:

  ```text
  SMTP: a 451 at DATA audits a reason code, never the message: FAIL
    expected: "rejected_at_data:451"
     but got: "user error (Unexpected reply to: DATA ... confirm?token=3Ds3cr3t-one-tim=\\r\\ne-token-do-not-log-me ..."
  ```

- The regression-first webhook case confirmed that http-client's request rendering persisted the configured
  URL query string, along with transport metadata and the request signature:

  ```text
  webhook: a transport failure never persists the request: FAIL
    expected: "connect_failed"
     but got: "HttpExceptionRequest Request { host = \"127.0.0.1\" ... path = \"/hook\" queryString = \"?key=url-secret-hunter2\" ... }"
  ```

- smtp-mail delegates connection establishment to crypton-connection, whose current released source throws
  `HostCannotConnect` rather than an `IOException` for a refused socket. The classifier therefore recognizes
  that constructor's rendering only to select `connect_failed`; it still discards the rendering before any
  output. The focused refused-connection test pins this dependency seam.


## Decision Log

- Decision: Failures are reported through a closed vocabulary, `DeliveryReason`, rendered as `connect_failed`,
  `tls_failed`, `auth_failed`, `timeout`, `rejected_at_<ehlo|starttls|mail|rcpt|data>:<code>`, `data_refused`,
  `invalid_url`, `http_status:<code>`, `redirect_loop`, `transport_error`, `queue_full`, `shutting_down`,
  `expired_in_queue`, `unknown`. Exception text is *inspected* to pick a reason, then discarded. The `errorText`
  JSON key of `NotificationDeliveryFailedData` is kept (renaming would change every historical row).
  Rationale: truncation is offset-dependent and `token=` stripping is encoding-dependent — `mime-mail`
  quoted-printable-encodes the body (`token=3D…`) and a soft line break can split the token; only a closed set
  is safe by construction. Matching `IOException` types, smtp-mail 0.5.0.1's message fragments,
  `HttpException`'s constructors, and the `show` text of TLS exceptions keeps `tls` out of the dependencies.
  The durable rule is recorded in
  [ADR-9](../adr/0009-transport-exception-text-is-never-persisted.md).
  Date: 2026-08-27

- Decision: Delivery moves to a bounded in-memory queue (`Control.Concurrent.STM.TBQueue`; `stm` is already a
  dependency), default capacity 1024 (`notifierQueueSize` / `SHOMEI_NOTIFIER_QUEUE_SIZE`, a `ServerSettings`
  knob like the sweep settings), drained by one worker on `supervisedLoopMicros`. Overflow is **drop with
  audit**: the request path never blocks; a full queue publishes `notification_delivery_failed` with
  `queue_full` and one stderr line. The worker skips a notification whose `expiresAt` has passed
  (`expired_in_queue`). On shutdown the queue is closed (late enqueues audit `shutting_down`), drained for at
  most `gracefulShutdownTimeoutSeconds`, and any remainder is one summary log line, not per-item audits.
  Rationale: delivery is already fire-and-forget (plan 45); blocking would reintroduce the stall; 1024 items
  at the 10 s SMTP timeout is roughly three hours of a dead relay before a drop. No persistent queue.
  Date: 2026-08-27

- Decision: The miss path is **not** padded with a sentinel; the residual is accepted and pinned. A hit costs
  `findUserByEmail`, token generation, one token insert, one enqueue, one audit insert; a miss costs
  `findUserByEmail`. `Shomei.Account.Lifecycle.CostSpec` asserts exactly that delta; an E2E case asserts the
  `202` arrives in under a second while the receiver sleeps three.
  Rationale: equal counts need fake rows in the token and audit tables on every miss; a no-op `Notification`
  constructor would leak into the webhook JSON and break every bring-your-own interpreter, to save
  microseconds. The 10–20 s wait was the oracle; two inserts are noise.
  Date: 2026-08-27

- Decision: `SmtpConfig.password` and `WebhookConfig.secret` are **removed** from shomei-core (PVP major: next
  version 0.2.0.0) and live in `Shomei.Notify.NotifierSecrets` on the server `Env` (`envNotifierSecrets`),
  loaded in `buildEnv` as `envKek`/`envTotpKey` are; `SmtpPassword`/`WebhookSecret` have no `Show`, `Eq`, or JSON
  instances, on the `KeyEncryptionKey` model.
  Rationale: MasterPlan 8 Integration Point 7 names this move; a redacting newtype *inside* `ShomeiConfig`
  would still let `toJSON cfg` emit a placeholder and keep the secret in the record `Seam.Env.config` hands
  every embedding host. Completeness validation moves to boot.
  Date: 2026-08-27

- Decision: The webhook signature covers `<unix-seconds>.<raw body>`; the timestamp travels in
  `X-Shomei-Timestamp`; `X-Shomei-Signature: sha256=<hex>` keeps its format; each retry re-stamps and re-signs;
  receivers reject `|now − timestamp| > 300 s` and de-duplicate by token. Breaking for receivers, documented
  as such, with no version header.
  Rationale: the Stripe/Svix shape every webhook library implements; a captured POST currently replays
  forever; the transport is pre-1.0 and the receiver change is one line.
  Date: 2026-08-27

- Decision: `webhookUrl` must be `https://` unless `SHOMEI_WEBHOOK_ALLOW_INSECURE=true`; `smtpTlsMode = plain`
  with a username refuses to boot unless `SHOMEI_SMTP_ALLOW_PLAINTEXT_AUTH=true`; `plain` without credentials
  only warns. Both flags are env-only with no Dhall key, on the `SHOMEI_NOTIFIER_LOG_SECRETS` precedent; no
  loopback carve-out.
  Rationale: an insecure escape hatch must be a per-process decision, not a line that lingers in a committed
  file (plan 30); a carve-out means URL parsing and a second rule.
  Date: 2026-08-27

- Decision: `LoginFailedData` becomes `{accountKey :: Maybe AccountKey, userId :: Maybe UserId, occurredAt}`;
  `loginId` is removed; the `user_id` column is set when the credential resolved. `accountKey` is `Maybe` only
  so pre-change rows (which carry `loginId`) still decode — aeson's derived `FromJSON` reads a missing `Maybe`
  field as `Nothing` and ignores the unknown key, as `SessionRevokedData.revokedBy` already relies on.
  Rationale: a password typed into the login field must not land in an append-only table retained forever;
  the hashed key is the one `account_locked` carries, so the two now join directly.
  Date: 2026-08-27

- Decision: `docs/adr/` does not exist and `mori.dhall` declares no ADR bundle, so this plan creates it as
  the profile-governed OKF bundle the MasterPlan's Integration Points prescribe: copy the frozen descriptor
  `blueprints/adopt-architecture-decisions/files/architecture-decisions-profile.dhall` from the
  `shinzui/okf-profiles` checkout (`mori path shinzui/okf-profiles`) to `docs/adr/profile.dhall`, run
  `okf index docs/adr --write --okf-version 0.2`, add a `log.md`, an `adrs` `okfBundles` entry in `mori.dhall`,
  and a `just adr-validate` recipe; records are `NNNN-<slug>.md` with the profile's frontmatter and a `docId`
  allocated by `okf id next docs/adr --profile docs/adr/profile.dhall ADR`. If a sibling plan lands first and
  has created the bundle, allocate the next handle instead.
  Rationale: `.claude/skills/exec-plan/ADR.md` forbids inventing OKF identity as an *incidental* edit, but every
  documentation bundle in this repository is profile-governed and the MasterPlan makes the bootstrap a named,
  coordinated step with a `dhall freeze`-hashed pin, so nothing is guessed.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation; distill durable decisions into `docs/adr/` first, and record
the deliberate leftovers: `IdToken` still derives `Show`; the missing `SHOMEI_SMTP_*`/`SHOMEI_WEBHOOK_*` rows in
`deployment.md` are EP-10's job.)


## Context and Orientation

The repository is a multi-package Haskell Cabal workspace at `/Users/shinzui/Keikaku/bokuno/shomei` (GHC 9.12.4;
work inside `nix develop`; `cabal build all`; `cabal test all`; `nix fmt`, reverting files you did not touch).
Tests are tasty + tasty-hunit. Line numbers are at HEAD `5dfd2a6` (code identical to the reviewed `ee00382`).
No `docs/adr/` exists (checked 2026-08-27) and `mori.dhall` declares only `improvement-requests`,
`capabilities`, and `reviews`, so no local ADR applies.

**The pipeline.** The *port* (an `effectful` effect a workflow calls without knowing its implementation) is
`Notifier` in `shomei-core/src/Shomei/Account/Notification/Store.hs`, one operation `SendNotification ::
Notification -> Notifier m ()`. The payload (`Notification/Domain.hs:11-23`) has two constructors, each
`{email, token :: OneTimeToken, expiresAt}`, deriving `Show`, `Eq`, `FromJSON`, `ToJSON` — it **does** carry the
raw token and must: the email body and webhook JSON are built from it. The producers
`requestEmailVerification` (`shomei-core/src/Shomei/Account/Lifecycle/Workflow.hs:71-89`) and
`requestPasswordReset` (130–148) look the user up and, only when found, generate a token, insert its hash,
call `sendNotification` **inline**, publish an audit event, and return `Right ()` regardless. The server
interprets the port inside each request: `shomei-server/src/Shomei/Server/App.hs:184` composes
`runNotifierFromConfig env.envHttpManager env.envConfig` into `runAppIO`, above
`runAuthEventPublisherPostgres` (175) and `runClockIO` (172), so a notifier interpreter may publish audit
events. `Env` (134–153) holds the pool, config, keys, `envKek`, `envTotpKey` (secrets deliberately outside
`ShomeiConfig`), `envHttpManager`, and hashing knobs.

**The interpreters** (`shomei-server/src/Shomei/Notify.hs`). `runNotifierFromConfig` (89–105) dispatches per
transport and implements the `alsoLogNotifications` tee; `deliverSmtp` (188–201) catches `SomeException` from
`sendViaSmtp` (207–223) and calls `publishDeliveryFailed "smtp" n (truncateError err)`; `publishDeliveryFailed`
(287–323) writes `[shomei:smtp] delivery_failed type=… recipient=… error=<text>` to stderr and publishes
`NotificationDeliveryFailed {channel, notificationType, recipient, errorText, occurredAt}`
(`shomei-core/src/Shomei/Audit/Event/Domain.hs:476-484`, persisted through `Codec.hs:189-190`);
`truncateError` (327–333) is `Text.take 500 . Text.unwords . Text.words . Text.pack . displayException`.
`attemptWebhook` (371–404) POSTs `encode n` with `X-Shomei-Signature = webhookSignature secret body` (409–411:
HMAC-SHA256 over the body **only**); a non-2xx passes `"webhook returned HTTP <code>"`, an exception
`truncateError err`.

**The leak, exactly.** smtp-mail 0.5.0.1 `Network/Mail/SMTP.hs:167-177`:

```haskell
tryCommand tries st cmd expectedReply = do
    (code, msg) <- tryCommandNoFail tries st cmd expectedReply
    if code == expectedReply then return msg else do
        closeSMTP st
        fail $ "Unexpected reply to: " ++ show cmd ++
          ", Expected reply code: " ++ show expectedReply ++
          ", Got this instead: " ++ show code ++ " " ++ show msg
```

`Command` derives `Show` (`Types.hs:20-34`) and `DATA ByteString` carries the whole rendered message;
`sendRenderedMail` (`SMTP.hs:319-323`) sends `DATA dat` through `tryOnce`. Rendered with the real libraries
(the reviewer's `smtpfail.hs`, re-run while writing this plan) the exception is 620 characters, `token=`
begins at offset 368, and the 500 characters `truncateError` keeps include:

```text
user error (Unexpected reply to: DATA "From: <auth@example.com>\nTo: <alice@example.com>\nSubject: Verify your email address\n…Please confirm your email address by opening this link:\r\n\r\nhttps://auth=2Eexample=2Ecom/v1/auth/verify-email/confirm?token=3DAbCdEfGhI=\r\njKlMnOpQrStUvWxYz0123456789abcdefg\r\n\r\nThis link expires at 2026-08-26T12:00:00Z (UTC)=2E If you did not re
```

The body is quoted-printable (`=` → `=3D`, `.` → `=2E`) and a soft line break `=\r\n` (four literal characters,
since `show` escaped them) fell inside the token. A test that only checks `rawToken isInfixOf errorText` can
therefore pass on the unfixed code by accident; M1's assertions undo the encoding first. The existing
`NotifySpec.hs:145-159` covers only a refused connection. For the webhook, http-client 0.7.19's `HttpException`
derives `Show` (`Network/HTTP/Client/Types.hs:119-131`) and `instance Show Request` prints host, port, headers
(only `Authorization` redacted), `path`, and **`queryString`** — a receiver URL like
`https://hooks.example.com/shomei?key=…` writes its key into the audit row on every connection failure or
timeout; `TooManyRedirects [Response L.ByteString]` shows response bodies; `InvalidUrlException` shows the
URL. Today's non-2xx branch emits only the status, so a `500` echoing the body does *not* leak — M1 pins that.

**Background threads.** `shomei-server/src/Shomei/Server/Supervisor.hs:56-103` defines `supervisedLoop taskName
intervalSeconds cycle` and `supervisedLoopMicros taskName intervalMicros initialBackoff maxBackoff cycle`
(catch a synchronous exception, log a JSON line, back off 5 s doubling to 300 s, rethrow asynchronous ones so
`killThread` works). `Boot.main` (`Boot.hs:86-148`) calls `installKeyReload` and `installSweeper settings env`
(235–276, the template: `forkIO (supervisedLoop "sweeper" interval oneCycle)`), runs warp, and after
`Warp.runSettings` returns releases the pool (146–148); `buildEnv` (282–328) loads `envKek`, `envTotpKey`,
`newTlsManager`, and assembles `Env`. `installHostBackgroundTasks` from `docs/plans/59-…` has **not** landed
(that file is a skeleton), so this plan installs its worker beside `installSweeper` in a form EP-9 lifts verbatim.

**Configuration.** `shomei-core/src/Shomei/Config.hs`: `SmtpConfig` (170–184, `password :: Maybe Text`),
`WebhookConfig` (189–199, `secret :: Text`), `ShomeiConfig` (418–449) all derive `Show`/`ToJSON`;
`docs/user/security.md:183-184` gives that derivation as the reason the KEK is kept out.
`shomei-server/src/Shomei/Server/Config.hs`: `SHOMEI_SMTP_PASSWORD` is read at 779, `SHOMEI_WEBHOOK_SECRET` at 832,
`PG_CONNECTION_STRING` at 434, all through `textEnv`/`textEnvMaybe` (1005–1030), which do not `strip`;
`validateNotifierConfig` (867–890) accepts `http://` via `isHttpUrl` (888–890) and is silent on `plain` with
credentials. `config/shomei-types.dhall` is a closed record whose notifier keys (22–32) are `Optional`;
`docs/user/deployment.md:14-63` is the env-var table and 140–170 the Dhall key list.

**Tokens, audit shapes, tests.** `shomei-core/src/Shomei/Session/RefreshToken/Domain.hs:21-23`,
`Token/Domain.hs:16-26`, `Authentication/Workflow.hs:113-116` (`LoginResult`), and
`shomei-client/src/Shomei/Client.hs:132-133` all derive `Show` (the first three JSON too); the model is
`shomei-core/src/Shomei/Account/Password/Domain.hs:23-28` (`show _ = "PlainPassword <redacted>"`, no JSON).
`LoginFailedData` (`Audit/Event/Domain.hs:82-87`) is `{loginId, occurredAt}`, projected at `Codec.hs:95-96` with
`user_id = NULL`, published at `Authentication/Workflow.hs:325` inside `failLogin` (307–334), whose callers are
`failLoginTimed` (299–301) and the wrong-password branch at 252 where `user` is in scope; `ctx.accountKey`
(SHA-256 hex of the normalized login id, built at `shomei-servant/src/Shomei/Session/Handler.hs:73-77`) is
always available. The CLI and breach-checker sites are cited in M5. `NotifySpec.hs` has an in-process SMTP
sink (`serveSmtp`, 201–229) and a Warp webhook stub (`webhookStub`, 254–263); `E2ESpec.hs` builds an `Env`
literal at 107, 116, 128, 139, 172, and 198 (also `test-health/Main.hs:80-88`,
`examples/embedded-servant-app/test/Main.hs:62`, `examples/microservice-auth-stack/test/Main.hs:88`) and its
webhook scenario (208–229) states at 215 that delivery is synchronous; `ConfigSpec.hs:338-431` holds the
notifier loader cases; `shomei-core/test/Shomei/LockoutSpec.hs:103-108` shows the `interpose`/`passthrough`
idiom for counting port operations over `Shomei.Test.InMemory.runInMemoryWith` (`InMemory.hs:1327-1350`).


## Plan of Work

Five milestones, each green and committed on its own; M1 closes the persisted-token hole and lands first if
the plan is interrupted.

### Milestone M1 — reason codes instead of exception text

Scope: no `displayException` text reaches stderr or an audit row from the notifier; a `451` at `DATA` audits
`rejected_at_data:451`; the ADR exists. Add to and export from `Shomei.Notify`:

```haskell
data DeliveryReason
  = ConnectFailed | TlsFailed | AuthFailed | Timeout
  | RejectedAt SmtpStage Int   -- SMTP reply code at a stage, e.g. RejectedAt AtData 451
  | DataRefused                -- smtp-mail's "this server cannot accept any data."
  | InvalidUrl | HttpStatus Int | RedirectLoop | TransportError
  | QueueFull | ShuttingDown | ExpiredInQueue | Unknown
  deriving stock (Eq, Show)

data SmtpStage = AtEhlo | AtStartTls | AtMail | AtRcpt | AtData deriving stock (Eq, Show)

reasonText :: DeliveryReason -> Text                    -- "rejected_at_data:451" and so on
classifySmtpFailure, classifyWebhookFailure :: SomeException -> DeliveryReason
redactDeliveryText :: Notification -> Text -> Text       -- defence in depth
```

`classifySmtpFailure` tries `fromException` to an `IOException`: a non-`UserError` `ioeGetErrorType` (socket
connect, `getAddrInfo`) is `ConnectFailed`; otherwise match `ioeGetErrorString` — `"timed out"` (our own
`sendViaSmtp` message) → `Timeout`; `"authentication failed"` → `AuthFailed`; `"cannot connect to the server"` →
`ConnectFailed`; `"cannot accept any data"` → `DataRefused`; a prefix of `"Unexpected reply to: "` (21
characters) → the verb that follows (`EHLO`/`HELO` → `AtEhlo`, `STARTTLS`, `MAIL`, `RCPT`, `DATA`) plus the three
digits after `"Got this instead: "` (18 characters) via `readMaybe`, giving `RejectedAt`; else `Unknown`. A
non-`IOException` whose `show` contains `HandshakeFailed` or `TLSException` is `TlsFailed`, else `Unknown`.
`classifyWebhookFailure` matches `HttpException` (constructors from `Network.HTTP.Client`): `InvalidUrlException`
→ `InvalidUrl`; `HttpExceptionRequest _ c` with `ResponseTimeout`/`ConnectionTimeout` → `Timeout`, `ConnectionFailure
_` → `ConnectFailed`, `TooManyRedirects _` → `RedirectLoop`, `StatusCodeException r _` → `HttpStatus (statusCode
(responseStatus r))`, `InternalException e` with a TLS-looking `show` → `TlsFailed`, else `TransportError`; a
non-`HttpException` → `TransportError`. `redactDeliveryText n t` replaces every occurrence of `oneTimeTokenText
n.token` with `<redacted>`, rewrites any `token=<run of non-space, non-&, non-quote characters>` to
`token=<redacted>`, then applies `truncateText`. `publishDeliveryFailed` takes a `DeliveryReason`, renders it,
passes it through `redactDeliveryText n` (so free text threaded through by a future contributor still cannot
leak), and writes `reason=` instead of `error=`. Delete `truncateError`; `deliverSmtp` does `Left err ->
publishDeliveryFailed "smtp" n (classifySmtpFailure err)`; `attemptWebhook` does `failed (classifyWebhookFailure
err)`, the non-2xx arm `failed (HttpStatus code)`, a `parseRequest` failure `InvalidUrl`.

Tests in `NotifySpec.hs`. Give `serveSmtp` a `dataReply :: String` parameter (existing tests pass `"250 OK
queued"`). Add: (1) `SMTP: a 451 at DATA audits a reason code, never the message` — the sink answers `451 4.7.1
greylisted, try again later`; assert exactly one event, `d.errorText @?= "rejected_at_data:451"`, no `"token="`
infix, and the raw token absent from `unfoldQp d.errorText`, where `unfoldQp` removes each `=\r\n` (literal and
real CRLF forms) and decodes `=3D`/`=2E`; (2) `webhook: a transport failure never persists the request` —
`webhookConfigFor` at `closedPort` with URL `http://127.0.0.1:<port>/hook?key=url-secret-hunter2`; assert
`"connect_failed"` and `"hunter2"` absent; (3) `webhook: a 500 that echoes the body audits only the status` — the
stub answers 500 with the request body as its body; assert `"http_status:500"` and the token absent (passes
before the fix; pins the behavior); (4) a `classifySmtpFailure` table over synthetic exceptions: the
`Unexpected reply to: DATA … Got this instead: 451 …` message → `RejectedAt AtData 451`, `"authentication failed."`
→ `AuthFailed`, `mkIOError NoSuchThing …` → `ConnectFailed`, the timeout message → `Timeout`, `ErrorCall` → `Unknown`.
**Run cases 1 and 2 against the unfixed code first** and paste the output into Surprises & Discoveries:

```text
SMTP: a 451 at DATA audits a reason code, never the message: FAIL
  expected: "rejected_at_data:451"
   but got: "user error (Unexpected reply to: DATA \"From: <auth@example.com>\\nTo: <a@example.com>\\nSubject: Reset your password\\n…confirm?token=3Ds3cr3t-one-time-token-do-not-log-me\\r\\n…, Got this instead: 451 \"4.7.1 greylisted, try again later\")"
webhook: a transport failure never persists the request: FAIL
  expected: "connect_failed"
   but got: "HttpExceptionRequest Request { host = \"127.0.0.1\" port = 5xxxx secure = False requestHeaders = [(\"Content-Type\",\"application/json\"),(\"X-Shomei-Signature\",\"sha256=…\"),…] path = \"/hook\" queryString = \"?key=url-secret-hunter2\" method = \"POST\" … } (ConnectionFailure Network.Socket.connect: <socket: 14>: does not exist (Connection refused))"
```

Then bootstrap `docs/adr/` as the Decision Log describes (or allocate the next handle if a sibling created it)
and write `docs/adr/NNNN-transport-exception-text-is-never-persisted.md` with the profile's frontmatter
(`type: Architecture Decision Record`, `title`, `description`, `generated`, `docId: ADR-N`, `status: Accepted`,
`date`): Context —
the two renderings above and the rule that a third-party exception may embed the payload; Decision — server
code maps transport failures to `DeliveryReason` before logging or persisting, `displayException` text never
reaches stderr or an audit row, the payload's own secret is scrubbed as defence in depth, and the rule covers
every outbound transport including the breach checker; Consequences — reason codes are the operator's signal
and relay diagnosis uses the relay's logs, and a new transport means a classifier plus its table test;
Alternatives rejected — truncation and `token=` stripping, with the quoted-printable evidence. Acceptance:
`cabal test shomei-server` green; the two pre-fix failures recorded. Commit:

```text
fix(notify): map SMTP and webhook failures to reason codes; never persist exception text

smtp-mail's tryCommand embedded the rendered message (and its token) in the audit row;
http-client's Show Request embedded the receiver URL. Both reduce to DeliveryReason now.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M2 — delivery off the request path

Scope: the request path enqueues and returns; one supervised worker delivers; shutdown drains. Create
`shomei-server/src/Shomei/Notify/Queue.hs` (add to `exposed-modules`):

```haskell
data NotifierQueue   -- TBQueue Notification, TVar Bool "closed", TVar Int "in flight"
data EnqueueOutcome = Enqueued | QueueFull | QueueClosed
newNotifierQueue :: Int -> IO NotifierQueue                           -- capacity, clamped >= 1
enqueueNotification :: NotifierQueue -> Notification -> IO EnqueueOutcome  -- never blocks
withDequeued :: NotifierQueue -> (Notification -> IO ()) -> IO ()   -- blocks for an item; in-flight++ … finally --
closeNotifierQueue :: NotifierQueue -> IO ()
drainNotifierQueue :: NotifierQueue -> Int -> IO Int                 -- wait <= N s for empty+idle; items left
```

`enqueueNotification` is one `atomically`: closed → `QueueClosed`; `isFullTBQueue` → `QueueFull`; else
`writeTBQueue`. `drainNotifierQueue` polls every 50 ms. In `Shomei.Notify` (so `Queue.hs` stays import-free of it)
add `runNotifierEnqueue :: (IOE, AuthEventPublisher, Clock) => NotifierQueue -> Text -> Eff (Notifier : es) a ->
Eff es a`, which publishes `QueueFull`/`ShuttingDown` through `publishDeliveryFailed` on the two failure
outcomes, and pull the per-notification dispatch out of `runNotifierFromConfig` as `deliverNotification :: …
=> Manager -> ShomeiConfig -> Notification -> Eff es ()` (M3 adds the secrets argument); it first checks
`expiresAt <= now` and publishes `ExpiredInQueue` instead of sending. `runNotifierFromConfig` stays as a thin
synchronous wrapper for embedders and existing tests. Add `transportChannel :: NotifierTransport -> Text`. `Env`
gains `envNotifierQueue :: !NotifierQueue`; `runAppIO` line 184 becomes `. runNotifierEnqueue env.envNotifierQueue
(transportChannel env.envConfig.notifierConfig.notifierTransport)`. `ServerSettings` gains
`serverNotifierQueueSize :: !Int` (default 1024; `FileConfig.notifierQueueSize`; env `SHOMEI_NOTIFIER_QUEUE_SIZE`;
non-positive refused in the sweep knobs' style); `buildEnv` creates the queue. In the **same commit** add `,
notifierQueueSize : Optional Natural` after `webhookMaxAttempts` in `config/shomei-types.dhall`,
`notifierQueueSize = None Natural` in `config/shomei.example.dhall`, and a `SHOMEI_NOTIFIER_QUEUE_SIZE` row plus
the key in `deployment.md`'s Dhall list (Integration Point 7).

In `Boot.hs`, beside `installSweeper`, add and export `newtype NotifierWorker = NotifierWorker
{drainNotifierWorker :: Int -> IO ()}` and `installNotifierWorker :: Env -> IO NotifierWorker`. It forks
`supervisedLoopMicros "notifier" 0 (5 * 1_000_000) (300 * 1_000_000) oneCycle` (interval 0: the cycle itself
blocks on the queue) where `oneCycle = withDequeued q \n -> runEff . runErrorNoCallStack @AuthError .
runDatabasePool env.envPool . runClockIO . runAuthEventPublisherPostgres $ deliverNotification
env.envHttpManager env.envConfig n`, logging a `Left` (the publisher's database failure) as one JSON line; the
returned `drainNotifierWorker secs` closes the queue, waits `drainNotifierQueue q secs`, logs
`{"msg":"notifier drained","dropped":n}` (level `warn` when `n > 0`), and `killThread`s the worker —
`ThreadKilled` is asynchronous, so the loop rethrows it and the thread ends even mid-`atomically`. Haddock it
"EP-9's installHostBackgroundTasks lifts this call verbatim". In `main`: `worker <- installNotifierWorker env`
after `installSweeper`; after `Warp.runSettings` returns and before `Pool.release`, `drainNotifierWorker worker
obs.gracefulShutdownTimeoutSeconds`.

Tests. `NotifySpec.hs`: capacity 2, three enqueues, the third audits `queue_full` without blocking; a closed
queue audits `shutting_down`; drain returns 0 once a consumer empties it and the remainder after the timeout
when nothing consumes. `E2ESpec.hs`: every `Env` literal (and the three outside the suite) gains
`envNotifierQueue = q` from `newNotifierQueue 64`; the webhook scenario calls `worker <- installNotifierWorker
env` before `testWithApplication`, replaces the line-215 comment with a poll of `captured` every 100 ms up to
10 s, and drains afterwards. Add `E2E: password-reset/request answers 202 in under a second while the receiver
sleeps 3 s` — the stub does `threadDelay 3_000_000` before 200; time the POST with `GHC.Clock.getMonotonicTime`;
assert `< 1.0`; then poll for the capture. In `shomei-core`, add `test/Shomei/Account/Lifecycle/CostSpec.hs`
(register in the cabal `other-modules` and `test/Main.hs`): wrap `runInMemory` with `interpose` counters on
`UserStore`, `PasswordResetTokenStore`/`VerificationTokenStore`, `Notifier`, and `AuthEventPublisher` and assert a
hit issues `(1, 1, 1, 1)` and a miss `(1, 0, 0, 0)` for both request workflows, with a comment that this pins
the documented residual. Docs: `notifications.md` "Fire-and-forget and observability" (197–209) gains the queue
paragraph (bounded, `notifierQueueSize`, `queue_full`/`shutting_down`/`expired_in_queue`, drained on shutdown
within `gracefulShutdownTimeoutSeconds`) and the reason vocabulary replaces "truncated error"; the
bring-your-own section (272–283) shows the enqueue line as the one to replace. `security.md:186-193` says the
difference is invisible "in bytes and in network work: delivery runs on a background worker; the residual is
two inserts". Acceptance: `cabal test shomei-server shomei-core` green, including the latency case. Commit:

```text
feat(notify): deliver notifications from a supervised background worker

Bounded queue with drop-with-audit; one worker on supervisedLoopMicros; drained on
shutdown. Adds notifierQueueSize to the loader, the Dhall schema, and deployment.md.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M3 — secrets out of `ShomeiConfig`; webhook and SMTP posture

Scope: `toJSON cfg` cannot contain a secret; env values are trimmed; insecure transports need an explicit flag;
the signature is timestamped. Core: delete `password` from `SmtpConfig` (`Config.hs:177-178`) and `secret` from
`WebhookConfig` (191–192); fix the haddocks; add `## Unreleased (0.2.0.0)` to `shomei-core/CHANGELOG.md` naming
these removals and M4's changes. Server, in `Shomei.Notify`:

```haskell
newtype SmtpPassword = SmtpPassword Text      -- no Show, Eq, or JSON: a leak is a type error
newtype WebhookSecret = WebhookSecret Text
data NotifierSecrets = NotifierSecrets {smtpPassword :: !(Maybe SmtpPassword), webhookSecret :: !(Maybe WebhookSecret)}
noNotifierSecrets :: NotifierSecrets
smtpPasswordText :: SmtpPassword -> Text;  webhookSecretBytes :: WebhookSecret -> ByteString
```

and in `Shomei.Server.Config` `loadNotifierSecretsFromEnv :: ShomeiConfig -> IO NotifierSecrets`, which reads
`SHOMEI_SMTP_PASSWORD` and `SHOMEI_WEBHOOK_SECRET` with `Text.strip` and refuses to boot (an `ioError` naming the
variable) when transport is `smtp` and `username` is present without a password or vice versa, or transport is
`webhook` and the secret is absent or empty. `Env` gains `envNotifierSecrets`; `buildEnv` calls the loader after
`loadTotpKeyFromEnv`. `runNotifierSmtp nc sc mPassword`, `runNotifierWebhook mgr wc secret`,
`runNotifierFromConfig mgr secrets cfg`, and `deliverNotification mgr secrets cfg n` take the secrets
explicitly; every `Env` literal gains `envNotifierSecrets = noNotifierSecrets` (the E2E webhook scenario:
`NotifierSecrets Nothing (Just (WebhookSecret whSecret))`). Loader: `overlaySmtpFromEnv`/`overlayWebhookFromEnv`
stop reading the two secrets and `emptyWebhook` loses `secret`; `textEnv`/`textEnvMaybe` apply `Text.strip` — this
covers hosts, URLs, `SHOMEI_SMTP_USERNAME`, and the secrets that motivated it: `SHOMEI_SMTP_PASSWORD`,
`SHOMEI_WEBHOOK_SECRET`, `PG_CONNECTION_STRING`, and `shomei-admin`'s `DATABASE_URL` (`Admin/Env.hs:69-74`);
`SHOMEI_KEY_ENCRYPTION_KEY` and `SHOMEI_TOTP_ENCRYPTION_KEY` already strip. `validateNotifierConfig` requires
`https://` unless `SHOMEI_WEBHOOK_ALLOW_INSECURE=true` (message: `webhookUrl must be https:// (set
SHOMEI_WEBHOOK_ALLOW_INSECURE=true for a lab receiver)`), refuses `SmtpPlain` with a username unless
`SHOMEI_SMTP_ALLOW_PLAINTEXT_AUTH=true`, and returns warnings `Boot.main` prints (`plain` without credentials:
`[shomei] WARNING: smtpTlsMode=plain sends mail in the clear; lab sinks only`).

Signature: `webhookSignature :: ByteString -> ByteString -> ByteString -> ByteString` (secret, timestamp, body)
is HMAC-SHA256 over `timestamp <> "." <> body`; `attemptWebhook` takes the time from `Clock.now` per attempt
(`show (floor (utcTimeToPOSIXSeconds t) :: Integer)`) and sends `X-Shomei-Timestamp`. `NotifySpec.webhookDeliversTest`
and `E2ESpec.webhookScenario` recompute over `ts <> "." <> body` from the captured header. ConfigSpec: drop the
two assertions that read secrets out of the config (388, 415); re-target the two "missing secret" cases at
`loadNotifierSecretsFromEnv`; add cases for stripping (`SHOMEI_WEBHOOK_SECRET="s3\n"` loads as `"s3"`), the two
flags (refused without, accepted with), a non-positive queue size, and `encode cfg` for a full SMTP+webhook
config containing no `password`/`secret` key. Docs: `notifications.md` — the
headers block (108–115) gains `X-Shomei-Timestamp`; the pseudo-code (139–145) becomes `expected = "sha256=" +
hmac(secret, ts + "." + raw_body)` with `abs(now - int(ts)) <= 300` under a **Breaking change** callout; the
HTTPS advice (128–131) becomes the rule and names the flag; the SMTP section names the plaintext-auth
refusal; the config table marks both secrets "env-only, stripped, held in the server `Env`, never in
`ShomeiConfig`". `security.md:183-184` extends the sentence to the TOTP key, SMTP password, and webhook secret.
`deployment.md` gains rows for the two flags and adds them to the "deliberately no Dhall key" paragraph
(168–170). Commit:

```text
feat(config)!: move notifier secrets into the server Env; timestamped webhook signature

Removes SmtpConfig.password and WebhookConfig.secret (shomei-core 0.2.0.0); stripped env
secrets in Env.envNotifierSecrets; https-only webhooks and no plaintext SMTP auth without
a lab flag; X-Shomei-Signature over <timestamp>.<body> with X-Shomei-Timestamp.

BREAKING CHANGE: receivers must verify the timestamped payload; SmtpConfig and
WebhookConfig lose their secret fields.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M4 — redacting `Show`; hashed `login_failed`

In `RefreshToken/Domain.hs:21-23` and `Token/Domain.hs:16-18` derive only `Eq` via newtype and write `instance Show
RefreshToken where show _ = "RefreshToken <redacted>"` (likewise `AccessToken`); drop `FromJSON`/`ToJSON` from both
and from `TokenPair` (20–26; keep `Generic, Eq, Show`). `LoginResult` and `MfaChallenge` need no change — their
derived `Show` now goes through the redacting instances. `Client.hs:132-133`: `deriving stock (Eq)` plus
`instance Show Token where show _ = "Token <redacted>"`. `cabal build all --enable-tests` lists any site that
relied on the JSON instances (none expected — `shomei-servant/src/Shomei/Session/Dto.hs` has its own DTOs); tests
using `@?=` keep compiling because `Show` still exists and `Eq` is untouched. Note `IdToken` as a follow-up.

Audit: `LoginFailedData` becomes `{accountKey :: !(Maybe AccountKey), userId :: !(Maybe UserId), occurredAt}`
(`AccountKey` is already imported at `Domain.hs:63`); `Codec.hs:95-96` becomes `LoginFailed d -> (userIdToUUID <$>
d.userId, Nothing, "login_failed", toJSON d, d.occurredAt)`. In `Authentication/Workflow.hs`, `failLogin` swaps its
`LoginId` parameter for `Maybe UserId` and publishes `Event.LoginFailed (Event.LoginFailedData (Just
ctx.accountKey) mUserId ts)`; line 252 passes `(Just user.userId)`, `failLoginTimed` passes `Nothing`. Fix the
sites the compiler lists: `shomei-core/test/Shomei/Audit/Event/CodecSpec.hs:99`, `shomei-postgres/test/Main.hs:1127,
1142, 1144, 1184`, `shomei-server/test/Admin/Main.hs:592`. Add to `CodecSpec` a legacy case — `reconstructAuthEvent
"login_failed" (object ["loginId" .= "alice", "occurredAt" .= t0])` equals `Right (LoginFailed (LoginFailedData
Nothing Nothing t0))` — and to `Authentication/WorkflowSpec` that after a wrong password the `LoginFailed` event
carries `accountKey == Just ctx.accountKey` and `userId == Just alice.userId`, after an unknown login id `userId ==
Nothing`, and the typed text appears nowhere in `encode` of the event. Docs: `security.md` "Logging hygiene"
(330–352) lists the redacting types and the reason-code rule; the runbook (675–696) says `login_failed` rows
now carry `accountKey` (the same SHA-256 hex `account_locked` carries, so they join), a `user_id` when the
identifier resolved (so `audit user <id>` lists them), and that SIEM filters on `payload.loginId` must move to
`payload.accountKey`. Commit:

```text
fix(core)!: redact tokens in Show, drop their JSON instances; hash the login_failed subject

BREAKING CHANGE: LoginFailedData's shape and the token types' JSON instances.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M5 — CLI and breach-checker hygiene

`shomei-server/app/Admin.hs:83-92` takes `--password` on `argv` and dispatches (136–138) to
`Shomei.Admin.Users.createUserAction` (`app/Shomei/Admin/Users.hs:51-73`), which uses
`runPasswordBreachCheckerNoCheck` (147–152) and `env.config` built by `Admin/Env.hs:41-51` from
`defaultShomeiConfig` (the *default* password policy); `Admin/Keys.hs:168-171` prints `tshow e` of a hasql
`UsageError` (SQL plus parameters — encrypted key envelopes); `Server/BreachChecker.hs:42-44` maps any exception
to `BreachCheckUnavailable` silently. Replace `--password` with `optional (strOption (long "password-file" <>
metavar "PATH"))` and add `switch (long "email-verified")`; in `run` read the password with `readPasswordSecret ::
Maybe FilePath -> IO PlainPassword` (the file, or stdin — when `hIsTerminalDevice stdin` prompt `Password: ` with
`hSetEcho stdin False`; strip one trailing newline; refuse empty). `createUserAction env email (PlainPassword pw)
mDisplay verified`: replace `runPasswordBreachCheckerNoCheck` with `runPasswordBreachCheckerHibp mgr
env.config.passwordPolicy.breachCheckTimeoutMs` over a `newTlsManager` (the workflow's `enforceBreachPolicy`
already consults `breachCheckEnabled`, so the CLI now matches the server exactly), and when `verified` run `now
>>= markUserEmailVerified user.userId` through `runUserStorePostgres` after signup succeeds. `Admin/Env.hs`:
replace the hand-built config with `loadCoreConfig`, a new `Shomei.Server.Config` export running defaults →
`SHOMEI_CONFIG` Dhall → `overlayCoreFromEnv` with no connection-string requirement, so `passwordPolicy`,
`defaultRoles`, and `notifierConfig` are the deployment's. Update the `createUserAction` calls in
`test/Admin/Main.hs` (392, 406, 461, 488, 498) and add a case asserting `--email-verified` sets
`email_verified_at`. `Admin/Keys.hs`: print `summarizeUsageError e` — `ConnectionUsageError` → "could not connect
to PostgreSQL", `AcquisitionTimeoutUsageError` → "timed out acquiring a connection", `SessionUsageError
(QueryError _ _ (ResultError (ServerError code _ _ _ _)))` → "statement failed (SQLSTATE <code>)", other →
"statement failed"; never the SQL or its parameters; reuse it at `Boot.hs:266`. `BreachChecker.hs`: on `Left e`
write `[shomei:breach-check] unavailable reason=<reasonText (classifyWebhookFailure e)>` to stderr before
returning `BreachCheckUnavailable`. `deployment.md`'s `shomei-admin` synopsis (172–) shows the new flags;
`security.md:213-219` notes `--email-verified` for the bootstrap admin. Update `shomei-server/CHANGELOG.md` and
`shomei-client/CHANGELOG.md`. Commit:

```text
feat(admin): read the bootstrap password from stdin or a file; honour the Dhall policy

users create loses --password, loads the deployment config through loadCoreConfig, runs the
HIBP interpreter, and gains --email-verified; keys and the breach checker log safely.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`; the server suites provision
their own ephemeral PostgreSQL. M1 — write the two NotifySpec cases, run them against the unfixed `Notify.hs`,
and keep the output:

```bash
cabal test shomei-server --test-show-details=direct --test-options='-p /451/' 2>&1 | tee /private/tmp/claude-501/-Users-shinzui-Keikaku-bokuno-shomei/8ce5b697-fc49-45fc-a32f-1c0f5cf6c7dc/scratchpad/prefix-451.txt
cabal test shomei-server --test-show-details=direct --test-options='-p /never persists the request/' 2>&1 | tail -8
```

Both must **FAIL** with the transcripts shaped as in M1 (`s3cr3t-one-time-token-do-not-log-me` and `hunter2`
visible under `but got:`). Paste the real lines into Surprises & Discoveries, implement M1, and re-run `cabal
test shomei-server --test-show-details=direct --test-options='-p /Notify/'`:

```text
  Notify
    SMTP: a 451 at DATA audits a reason code, never the message:   OK
    webhook: a transport failure never persists the request:       OK
    webhook: a 500 that echoes the body audits only the status:    OK
    classifySmtpFailure maps smtp-mail's messages to reasons:      OK
```

M2 — the latency case, the core pin, and the schema:

```bash
cabal test shomei-server --test-show-details=direct --test-options='-p /under a second/'
cabal test shomei-core --test-show-details=direct --test-options='-p /CostSpec/'
dhall-to-json --file config/shomei.example.dhall > /dev/null && echo dhall-ok
```

Expected: `E2E: password-reset/request answers 202 in under a second while the receiver sleeps 3 s: OK`, four
`CostSpec` cases `OK`, `dhall-ok`. Then a live check (`just create-database` first; the package has two
executables, so the `cabal run` target must be qualified). Terminal 1, a receiver that prints the raw request,
then the server:

```bash
( printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n' | nc -l 9999 ) &
SHOMEI_NOTIFIER_TRANSPORT=webhook SHOMEI_WEBHOOK_URL=http://127.0.0.1:9999/hook \
SHOMEI_WEBHOOK_ALLOW_INSECURE=true SHOMEI_WEBHOOK_SECRET=dev-secret \
SHOMEI_KEY_ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)" \
PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
  cabal run shomei-server:exe:shomei-server
```

Terminal 2, sign up and request a reset, timing the request:

```bash
curl -s -X POST localhost:8080/v1/auth/signup -H 'Content-Type: application/json' \
  -d '{"loginId":"alice@example.com","email":"alice@example.com","password":"correct horse battery staple","displayName":""}' > /dev/null
curl -s -o /dev/null -w 'status=%{http_code} time=%{time_total}s\n' -X POST \
  localhost:8080/v1/auth/password-reset/request -H 'Content-Type: application/json' -d '{"email":"alice@example.com"}'
```

Expected (the timestamp header appears after M3; terminal 1 shows the delivery):

```text
status=202 time=0.014s

POST /hook HTTP/1.1
Host: 127.0.0.1:9999
Content-Type: application/json
X-Shomei-Signature: sha256=9f2c…(64 hex)
X-Shomei-Timestamp: 1756260000
X-Shomei-Notification-Type: password_reset_requested
User-Agent: shomei

{"tag":"PasswordResetRequested","email":"alice@example.com","token":"7Hu0OCr…","expiresAt":"2026-08-27T04:12:09Z"}
```

Verify the signature by hand with the printed timestamp and the exact body bytes — `printf '%s.%s' "$TS" "$BODY"
| openssl dgst -sha256 -hmac dev-secret` — and the hex must equal the header's. Press Ctrl-C on the server
during a delivery and expect, in order, `[shomei] received SIGINT; draining in-flight requests`,
`{"dropped":0,"level":"info","msg":"notifier drained"}`, then `drain complete; closing connection pool`. M3 —
booting with `SHOMEI_NOTIFIER_TRANSPORT=webhook SHOMEI_WEBHOOK_URL=http://hooks.example.com/x
SHOMEI_WEBHOOK_SECRET=s PG_CONNECTION_STRING=x` must print `shomei-server: user error (webhookUrl must be https://
(set SHOMEI_WEBHOOK_ALLOW_INSECURE=true for a lab receiver))` and exit; then `cabal test
shomei-server:shomei-server-config-test`. M4 and M5 — compiler-driven sweeps, the suites, and the CLI:

```bash
rg -n "LoginFailedData|--password" --type haskell
cabal build all --enable-tests && cabal test shomei-core shomei-postgres shomei-server shomei-client
printf 'correct horse battery staple\n' | DATABASE_URL="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
  cabal run shomei-server:exe:shomei-admin -- users create --email bob@example.com --email-verified
```

Expected last line: `created user user_01… <bob@example.com> (email verified)`. Finish with `nix fmt` (revert
unrelated drift), `cabal build all`, `TASTY_NUM_THREADS=1 cabal test all`.


## Validation and Acceptance

1. **No token in a log or audit row.** With the sink answering `451` at `DATA`, exactly one
   `notification_delivery_failed` event whose `errorText` is `rejected_at_data:451`, the raw token absent even
   after undoing quoted-printable, and a stderr line ending in `reason=rejected_at_data:451`; a webhook URL with
   a query-string secret and a refused connection audits `connect_failed` and nothing of the URL. Both fail on
   the unfixed code (recorded) and pass after M1.
2. **Nothing waits on a relay.** A reset request for a registered address answers `202` in under one second
   while the receiver sleeps three, and the delivery arrives afterwards; `CostSpec` shows hit and miss differ by
   exactly one token insert, one enqueue, and one audit insert; overflow audits `queue_full` without blocking;
   shutdown logs `notifier drained` with `dropped` equal to what the timeout left.
3. **No secret in `ShomeiConfig`; timestamped signatures.** `encode cfg` for a full SMTP+webhook deployment
   contains neither `password` nor `secret`; `SHOMEI_WEBHOOK_SECRET` with a trailing newline verifies a signature
   computed with the trimmed value; `http://` receivers and `plain`+username relays refuse to boot without their
   flags, and the messages name the flag; the captured request carries `X-Shomei-Timestamp` and a `sha256=` HMAC
   over `<timestamp>.<body>` that the openssl one-liner reproduces.
4. **Redaction.** `show (TokenPair (AccessToken "a") (RefreshToken "r") 900)` shows only `<redacted>` for both;
   `shomei-admin audit events --type login_failed --json` shows `accountKey` and `userId`, never the typed
   identifier; a legacy `login_failed` payload still decodes.
5. **CLI.** `users create` refuses `--password`, reads stdin or `--password-file`, rejects what the Dhall policy
   rejects (set `passwordMinLength = 40` in a test file and observe `signup rejected: WeakPassword …`), and
   `--email-verified` sets `email_verified_at`. `keys activate nope` against a refused connection prints `could
   not connect to PostgreSQL` and nothing else.
6. **Suite health.** `TASTY_NUM_THREADS=1 cabal test all` green; `dhall-to-json` on the example succeeds;
   `rg -n "displayException|truncateError" shomei-server/src/Shomei/Notify.hs` finds no persisted use.


## Idempotence and Recovery

Every change is a compiler-checked source edit or an additive config key; `cabal build`/`cabal test` re-run
safely. No migration: the audit table stores `event_type` plus a JSONB payload, and both payload changes decode
old rows unchanged. If M2 misbehaves in production, `SHOMEI_NOTIFIER_QUEUE_SIZE=1` degrades to "one at a time,
drop the rest with audit"; there is deliberately no switch back to in-request delivery, because that is the
oracle. A receiver not yet on the timestamped signature can verify both schemes for one release. Removing the
two secret fields breaks embedders who construct `SmtpConfig`/`WebhookConfig` by hand; the compiler names every
site and the CHANGELOG says where the secrets went. Each commit leaves `cabal test all` green, and M1 alone
closes the persisted-token hole. If a sibling plan created `docs/adr/` first, allocate the next handle with `okf id next`
and run `just adr-validate`.


## Interfaces and Dependencies

No new third-party dependency: `stm`, `crypton`/`ram`, `smtp-mail`, `mime-mail`, `http-client`, and `time` are
already in `shomei-server`'s `build-depends`; the TLS classifier matches `show` text so `tls` is not added.
Definitions that must exist at the end of each milestone:

- M1 — `Shomei.Notify.DeliveryReason (..)`, `SmtpStage (..)`, `reasonText`, `classifySmtpFailure`,
  `classifyWebhookFailure :: SomeException -> DeliveryReason`, `redactDeliveryText :: Notification -> Text -> Text`;
  `publishDeliveryFailed :: … => Text -> Notification -> DeliveryReason -> Eff es ()`;
  `docs/adr/NNNN-transport-exception-text-is-never-persisted.md` (handle from `okf id next`; `just adr-validate` green).
- M2 — `Shomei.Notify.Queue.{NotifierQueue, EnqueueOutcome (..), newNotifierQueue, enqueueNotification, withDequeued,
  closeNotifierQueue, drainNotifierQueue}`; `Shomei.Notify.{runNotifierEnqueue, deliverNotification, transportChannel}`;
  `Env.envNotifierQueue`; `Shomei.Server.Boot.{NotifierWorker (..), installNotifierWorker :: Env -> IO NotifierWorker}`;
  `ServerSettings.serverNotifierQueueSize`, `FileConfig.notifierQueueSize`, Dhall `notifierQueueSize : Optional
  Natural`; `Shomei.Account.Lifecycle.CostSpec`.
- M3 — `Shomei.Notify.{SmtpPassword, WebhookSecret, NotifierSecrets (..), noNotifierSecrets, smtpPasswordText,
  webhookSecretBytes}`; `Shomei.Server.Config.loadNotifierSecretsFromEnv :: ShomeiConfig -> IO NotifierSecrets`;
  `Env.envNotifierSecrets`; `runNotifierSmtp :: … => NotifierConfig -> SmtpConfig -> Maybe SmtpPassword -> …`;
  `runNotifierWebhook :: … => Manager -> WebhookConfig -> WebhookSecret -> …`; `runNotifierFromConfig :: … => Manager
  -> NotifierSecrets -> ShomeiConfig -> …`; `webhookSignature :: ByteString -> ByteString -> ByteString -> ByteString`
  (secret, timestamp, body); `SmtpConfig`/`WebhookConfig` without `password`/`secret`.
- M4 — redacting `Show` on `RefreshToken`, `AccessToken`, `TokenPair`, `Shomei.Client.Token`, no JSON on the first
  three; `LoginFailedData {accountKey :: Maybe AccountKey, userId :: Maybe UserId, occurredAt :: UTCTime}`;
  `failLogin :: … => RateLimitConfig -> ClientContext -> Maybe UserId -> UTCTime -> Eff es a`.
- M5 — `Shomei.Server.Config.loadCoreConfig :: IO ShomeiConfig`; `Shomei.Admin.Users.createUserAction :: AdminEnv ->
  Text -> PlainPassword -> Maybe Text -> Bool -> IO ()`; `Shomei.Admin.Keys.summarizeUsageError :: UsageError ->
  Text`; `users create --password-file PATH | stdin`, `--email-verified`.

Sibling plans (all soft): EP-9 (`docs/plans/59-…`) lifts `installNotifierWorker` into `installHostBackgroundTasks`
and must call `drainNotifierWorker` in its shutdown story; EP-8 (`docs/plans/58-…`) owns client-IP rendering and
is untouched here; EP-6 (`docs/plans/56-…`) widens the Dhall schema — this plan's `notifierQueueSize` is already
`Optional`; EP-10 reconciles the remaining `deployment.md` notifier rows.
