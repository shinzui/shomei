# Notifications: delivering account-lifecycle email

Shōmei emits notifications — today exactly two, "verify your email" and "reset your password".
Each account-lifecycle workflow produces a `Notification` value (recipient, one-time link token,
expiry) and hands it to the `Notifier` effect. The stock server can turn that into a delivered
message three ways, chosen purely by configuration:

| `notifierTransport` | What it does | When to use it |
|---------------------|--------------|----------------|
| `log` (default)     | Writes the link to the server log (one-time token redacted unless you opt in). | Development, or log-scraping pipelines. |
| `smtp`              | Sends a fixed plain-text email through a **provider relay** (SES, SendGrid, Resend, Postmark). | Turnkey email with only provider credentials to configure. |
| `webhook`           | POSTs the notification as HMAC-signed JSON to a URL you own. | You render your own copy, call a provider's HTTP API, or attach other side effects. |

The default remains `log`, so an existing deployment's behavior is unchanged until you switch
transports. For a provider Shōmei does not ship, you can still supply your own `Notifier`
interpreter (see [Bring your own interpreter](#bring-your-own-interpreter)).

Secrets never live in the Dhall config file. The SMTP relay password comes from
`SHOMEI_SMTP_PASSWORD` and the webhook signing secret from `SHOMEI_WEBHOOK_SECRET`, both
environment-only.

## SMTP: a provider relay, not a mail server

The SMTP transport is deliberately a **relay client** aimed at a provider's authenticated
submission endpoint. It is **not** a way to run your own mail server, and it does **not** deliver
direct-to-MX. "No one sends transactional mail direct over raw SMTP anymore" is true — and this
transport does not; it does exactly what Rails' ActionMailer, Django's SMTP backend, and
nodemailer do by default: hand the message to a provider over an authenticated SMTP submission
connection. That is still one of the most common config-only email integrations, and it is what
makes "paste provider credentials, real email leaves the process" work with zero Haskell.

Point it at your provider's submission endpoint:

| Provider  | Host                                    | Port | `smtpTlsMode` |
|-----------|-----------------------------------------|------|---------------|
| Amazon SES| `email-smtp.<region>.amazonaws.com`     | 587  | `starttls`    |
| SendGrid  | `smtp.sendgrid.net`                     | 587  | `starttls`    |
| Resend    | `smtp.resend.com`                       | 465  | `implicit`    |
| Postmark  | `smtp.postmarkapp.com`                  | 587  | `starttls`    |

`smtpTlsMode` is one of:

- `starttls` (port 587) — connect in plaintext, then upgrade to TLS with `STARTTLS` before
  authenticating. The most common submission mode.
- `implicit` (port 465) — TLS from the first byte.
- `plain` (port 25) — **plaintext, no TLS. A lab/test sink only** (e.g. a local debugging
  server). Never use it in production: it sends your credentials and mail in the clear.

Authentication uses `AUTH PLAIN`/`AUTH LOGIN` when a username and password are configured;
`SHOMEI_SMTP_USERNAME` and `SHOMEI_SMTP_PASSWORD` must be set together (both, for an authenticated
relay) or neither (a lab sink). Because the email body embeds confirm links, `publicBaseUrl` must
be set for the `smtp` transport.

### The email copy

Shōmei sends fixed, minimal English, plain text only — no templating, no i18n, no HTML part.
(If you need branded or localized copy, take the `webhook` transport and render your own, or
write a custom interpreter.) The two bodies are:

**`Verify your email address`**

```text
Hello,

Please confirm your email address by opening this link:

{publicBaseUrl}/v1/auth/verify-email/confirm?token={token}

This link expires at {expiresAt} (UTC). If you did not request this,
you can ignore this message.
```

**`Reset your password`**

```text
Hello,

A password reset was requested for your account. Open this link to
choose a new password:

{publicBaseUrl}/v1/auth/password-reset/confirm?token={token}

This link expires at {expiresAt} (UTC). If you did not request this,
you can ignore this message and your password will remain unchanged.
```

### Example (SES via STARTTLS)

```bash
SHOMEI_NOTIFIER_TRANSPORT=smtp \
SHOMEI_SMTP_HOST=email-smtp.us-east-1.amazonaws.com \
SHOMEI_SMTP_PORT=587 \
SHOMEI_SMTP_TLS_MODE=starttls \
SHOMEI_SMTP_USERNAME=AKIA... \
SHOMEI_SMTP_PASSWORD=... \
SHOMEI_SMTP_FROM=auth@example.com \
SHOMEI_PUBLIC_BASE_URL=https://auth.example.com \
  shomei-server
```

## Webhook: transport and eventing hook

The webhook transport POSTs the notification as JSON to a URL you own. It doubles as Shōmei's
lightweight **eventing hook**: it is the sanctioned place to own copy and branding, call your
provider's HTTP API from your own receiver, or attach other side effects (chat alerts, analytics)
— all without writing a Haskell interpreter.

Each delivery is a `POST` with these headers:

```text
Content-Type: application/json
X-Shomei-Notification-Type: email_verification_requested   (or password_reset_requested)
X-Shomei-Signature: sha256=<64 lowercase hex chars>
User-Agent: shomei
```

The body is the `Notification`'s JSON (a tagged object carrying `email`, `token`, `expiresAt`):

```json
{
  "tag": "EmailVerificationRequested",
  "email": "alice@example.com",
  "token": "7Hu0OCr...",
  "expiresAt": "2026-07-11T03:44:27Z"
}
```

The body **carries the raw one-time token** — that is its purpose; your receiver builds the link
the user clicks. Treat the endpoint accordingly: **HTTPS only, an internal/trusted receiver, and
rotate the secret**. This is the same warning that has always applied to sending tokens over any
transport.

### Verifying the signature

`X-Shomei-Signature` is `sha256=` followed by the lowercase-hex HMAC-SHA256 of the **exact raw
request body bytes** under `SHOMEI_WEBHOOK_SECRET`. Verify over the raw bytes, not a re-serialized
copy, and compare in constant time:

```python
# Receiver-side verification (pseudo-code)
import hmac, hashlib
def verify(raw_body: bytes, header: str, secret: bytes) -> bool:
    expected = "sha256=" + hmac.new(secret, raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)   # constant-time compare
```

### Delivery semantics (at-most-once-ish)

Delivery is best-effort with bounded in-process retries: `maxAttempts` total (default 3) with
1 s and 4 s backoff, each under a per-attempt timeout (`timeoutSeconds`, default 5). A non-2xx
response counts as a failure. There is no persistent queue, so a receiver may see a notification
**0 times** (every attempt failed) or, rarely, **more than once** (a timeout after the receiver
had already processed it). **Treat deliveries as idempotent by token** — the token is stable
across retries, so de-duplicate on it.

### Example

```bash
SHOMEI_NOTIFIER_TRANSPORT=webhook \
SHOMEI_WEBHOOK_URL=https://hooks.internal.example.com/shomei \
SHOMEI_WEBHOOK_SECRET=... \
  shomei-server
```

## Configuration reference

Non-secret keys can be set in the Dhall config file (`config/shomei-types.dhall`) or overridden
by environment variables; the two secrets are environment-only.

| Dhall key              | Env var                       | Applies to | Notes |
|------------------------|-------------------------------|------------|-------|
| `notifierTransport`    | `SHOMEI_NOTIFIER_TRANSPORT`   | all        | `log` \| `smtp` \| `webhook`. |
| `alsoLogNotifications` | `SHOMEI_NOTIFIER_ALSO_LOG`    | all        | Also tee through the log sender. See below. |
| `smtpHost`             | `SHOMEI_SMTP_HOST`            | smtp       | Provider submission host. |
| `smtpPort`             | `SHOMEI_SMTP_PORT`           | smtp       | 587 (starttls) / 465 (implicit) / 25 (lab). |
| `smtpTlsMode`          | `SHOMEI_SMTP_TLS_MODE`       | smtp       | `starttls` \| `implicit` \| `plain`. |
| `smtpUsername`         | `SHOMEI_SMTP_USERNAME`       | smtp       | With password, both or neither. |
| _(none)_               | `SHOMEI_SMTP_PASSWORD`       | smtp       | **Env-only secret.** |
| `smtpFromAddress`      | `SHOMEI_SMTP_FROM`          | smtp       | Envelope/from address. |
| `smtpTimeoutSeconds`   | `SHOMEI_SMTP_TIMEOUT`       | smtp       | Per-send timeout (default 10). |
| `webhookUrl`           | `SHOMEI_WEBHOOK_URL`        | webhook    | `http(s)://…`. |
| _(none)_               | `SHOMEI_WEBHOOK_SECRET`     | webhook    | **Env-only secret.** |
| `webhookTimeoutSeconds`| `SHOMEI_WEBHOOK_TIMEOUT`    | webhook    | Per-attempt timeout (default 5). |
| `webhookMaxAttempts`   | `SHOMEI_WEBHOOK_MAX_ATTEMPTS`| webhook   | Total attempts, initial + retries (default 3). |

The server refuses to boot if the selected transport is not fully configured: `smtp` needs a host
and from-address (and a username/password pair, both or neither) plus a non-empty `publicBaseUrl`;
`webhook` needs an `http(s)` URL and a non-empty secret.

### Staged rollout

`alsoLogNotifications` (default `false`) tees **every** notification through the log sender in
addition to the selected transport. Set it while you cut over to `smtp` or `webhook` so you can
confirm deliveries against the log without giving up the real transport. It has no effect when the
transport is already `log`.

## Fire-and-forget and observability

`SendNotification` returns `()`, and the workflows ignore the result — the request endpoints
answer a generic `202 Accepted` whether or not the account exists, to avoid leaking which
addresses are registered (see [security.md](security.md)). Provider failures therefore **never**
surface to the HTTP caller.

The delivering interpreters are hardened accordingly: every exception is caught internally. When
a delivery ultimately fails, the interpreter writes one **redacted** log line — recipient, type,
and error, **never the token** — and publishes a `notification_delivery_failed` audit event
(channel, notification type, recipient, truncated error, timestamp — again, no token). That is
your operational signal; retry/queue/dead-letter beyond the webhook's bounded in-process retries
is the operator's job (a webhook receiver, or a custom interpreter).

The log sender's own redaction is unchanged: by default it prints only the first 8 hex characters
of the token's SHA-256 (a correlation handle, not a secret), and `SHOMEI_NOTIFIER_LOG_SECRETS=true`
restores the full clickable link for local development. Never set that in a shared environment.

## Bring your own interpreter

For a provider none of the built-in transports covers, compose Shōmei as a library and supply your
own `Notifier` interpreter — a function `Eff (Notifier : es) a -> Eff es a` that pattern-matches the
two notification variants and calls your provider. This is the third option, alongside `smtp` and
`webhook`.

The contract — one effect, one operation (`shomei-core/src/Shomei/Effect/Notifier.hs`):

```haskell
data Notifier :: Effect where
    SendNotification :: Notification -> Notifier m ()

sendNotification :: (Notifier :> es) => Notification -> Eff es ()
```

The payload (`shomei-core/src/Shomei/Domain/Notification.hs`):

```haskell
data Notification
    = EmailVerificationRequested { email :: !Email, token :: !OneTimeToken, expiresAt :: !UTCTime }
    | PasswordResetRequested     { email :: !Email, token :: !OneTimeToken, expiresAt :: !UTCTime }
```

Accessors: `Shomei.Domain.Email.emailText`, `Shomei.Domain.OneTimeToken.oneTimeTokenText`, and
`cfg.notifierConfig.publicBaseUrl` for the confirm-link base. The confirm links the user must
reach (the same ones every built-in transport uses):

```text
<publicBaseUrl>/v1/auth/verify-email/confirm?token=<token>
<publicBaseUrl>/v1/auth/password-reset/confirm?token=<token>
```

A minimal interpreter:

```haskell
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)

import Shomei.Domain.Email (emailText)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (oneTimeTokenText)
import Shomei.Effect.Notifier (Notifier (..))

runNotifierMyProvider :: (IOE :> es) => MyClient -> Text -> Eff (Notifier : es) a -> Eff es a
runNotifierMyProvider client baseUrl = interpret_ \case
    SendNotification n -> liftIO $ case n of
        EmailVerificationRequested email token _ ->
            sendEmail client (emailText email) "Verify your email"
                (baseUrl <> "/v1/auth/verify-email/confirm?token=" <> oneTimeTokenText token)
        PasswordResetRequested email token _ ->
            sendEmail client (emailText email) "Reset your password"
                (baseUrl <> "/v1/auth/password-reset/confirm?token=" <> oneTimeTokenText token)
```

Wire it into the effect stack in `Shomei.Server.App.runAppIO`
(`shomei-server/src/Shomei/Server/App.hs`) by replacing the one selection line:

```haskell
        . runNotifierFromConfig env.envHttpManager env.envConfig   -- the built-in transports
```

with your interpreter:

```haskell
        . runNotifierMyProvider client env.envConfig.notifierConfig.publicBaseUrl
```

`Notifier` is one entry in the canonical `AppEffects` stack; nothing else changes. If your
interpreter can fail, catch inside it and preserve the fire-and-forget contract above — never let
a delivery failure propagate to the HTTP request.

## Testing

`shomei-core/src/Shomei/Effect/InMemory.hs` provides `runNotifier`, a list-capturing interpreter
that records each `Notification` in the `World` instead of sending it — use it to assert that a
workflow emitted the expected notification with the expected token, with no network.
