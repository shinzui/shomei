# Notifications: sending account-lifecycle email

Shōmei emits notifications — it does **not** send email. The account-lifecycle workflows
(email verification, password reset) produce a `Notification` value and hand it to the
`Notifier` effect; *delivering* it is your responsibility. The toolkit ships one built-in
interpreter, a development sender that writes a line to the server log (with the one-time token
redacted — see below). To send real email through your provider (SendGrid, Resend, SES, an SMTP
relay, an internal mail service, …), you supply your own `Notifier` interpreter.

This keeps Shōmei transport-agnostic: the core defines only the *effect*; the only code that
knows about your provider is your interpreter.

## The contract

One effect, one operation (`shomei-core/src/Shomei/Effect/Notifier.hs`):

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
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

Accessors and config you'll use:

- `Shomei.Domain.Email.emailText :: Email -> Text` — the recipient address.
- `Shomei.Domain.OneTimeToken.oneTimeTokenText :: OneTimeToken -> Text` — the raw one-time
  token (a secret; it appears only in the link you send to the user, never persisted).
- `cfg.notifierConfig.publicBaseUrl :: Text` — the base URL for building confirm links.

The confirm links the user must reach (the same ones the dev log sender prints):

```text
<publicBaseUrl>/v1/auth/verify-email/confirm?token=<token>
<publicBaseUrl>/v1/auth/password-reset/confirm?token=<token>
```

## Writing a sender interpreter

An interpreter is a function `Eff (Notifier : es) a -> Eff es a`. Pattern-match the two
notification variants and call your provider. The shipped log sender
(`shomei-server/src/Shomei/Notify.hs`) is the reference implementation of this exact shape.

```haskell
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)

import Shomei.Domain.Email (emailText)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (oneTimeTokenText)
import Shomei.Effect.Notifier (Notifier (..))

-- | Send account-lifecycle email through your provider. `baseUrl` is
-- `cfg.notifierConfig.publicBaseUrl`.
runNotifierMyProvider :: (IOE :> es) => MyClient -> Text -> Eff (Notifier : es) a -> Eff es a
runNotifierMyProvider client baseUrl = interpret_ \case
    SendNotification n -> liftIO $ case n of
        EmailVerificationRequested email token _expiresAt ->
            sendEmail client (emailText email) "Verify your email"
                (baseUrl <> "/v1/auth/verify-email/confirm?token=" <> oneTimeTokenText token)
        PasswordResetRequested email token _expiresAt ->
            sendEmail client (emailText email) "Reset your password"
                (baseUrl <> "/v1/auth/password-reset/confirm?token=" <> oneTimeTokenText token)
```

`sendEmail`/`MyClient` are yours — your provider's SDK call or an HTTP request.

## Wiring it in

The server's effect stack is assembled in `Shomei.Server.App.runAppIO`
(`shomei-server/src/Shomei/Server/App.hs`). It currently selects the built-in sender:

```haskell
        . runNotifierFromConfig env.envConfig      -- ships only the dev log sender
```

Replace that single line with your interpreter:

```haskell
        . runNotifierMyProvider client env.envConfig.notifierConfig.publicBaseUrl
```

`Notifier` is one entry in the canonical `AppEffects` stack; nothing else changes.

## Webhook variant (for non-Haskell senders)

If the actual sending lives in another service or language, write an interpreter that POSTs the
notification to your own HTTP endpoint. `Notification` derives `ToJSON`, so this is a few lines:

```haskell
runNotifierWebhook :: (IOE :> es) => Manager -> Text -> Eff (Notifier : es) a -> Eff es a
runNotifierWebhook mgr url = interpret_ \case
    SendNotification n -> liftIO (postJson mgr url n)   -- n encodes to JSON directly
```

The JSON includes the raw one-time `token`, so this endpoint must be an internal call over TLS
that you trust — the token has to reach the user regardless of transport.

## The log sender redacts tokens

By default `LogNotifier` does **not** print a usable link. It prints the recipient, the expiry,
and the first 8 hex characters of the token's SHA-256:

```text
[shomei:log] password_reset email=a@example.com token_sha256=f6dd8191 expires_at=2026-07-09 03:44:27 UTC (set SHOMEI_NOTIFIER_LOG_SECRETS=true to log the full link in development)
```

The prefix is for correlation, not redemption: one-time tokens are stored as the SHA-256 of the
token (base64url), so `token_sha256` ties a log line to its `token_hash` row while the log itself
carries nothing an attacker could use.

For local development, where the logged link is how you actually complete a signup or reset,
set `SHOMEI_NOTIFIER_LOG_SECRETS=true` and the full link comes back:

```text
[shomei:log] password_reset email=a@example.com link=http://localhost:8080/v1/auth/password-reset/confirm?token=7Hu0OCr… expires_at=2026-07-09 03:44:40 UTC
```

Never set it in a shared or production environment: anyone who can read the log can then complete
a password reset for any account. It is an environment variable only — there is deliberately no
Dhall-file key — so it cannot linger unnoticed in a committed config.

## Two things to know

1. **This is an in-process Haskell API.** Plugging in a sender means composing Shōmei as a
   library and building your own server assembly (replacing the one line above). The prebuilt
   `shomei-server` / `shomei-admin` binaries hardcode the dev log sender — there is no config
   flag or plugin hook to inject an external sender into the stock binary. If you run the stock
   binary, your only built-in option is to scrape the log line — but note that by default it
   carries the recipient, the expiry, and only a **hash prefix** of the token, not the link
   (see "The log sender redacts tokens" below). Scraping the log to deliver real mail means
   running with `SHOMEI_NOTIFIER_LOG_SECRETS=true`, which puts redeemable tokens in your log;
   supplying your own `Notifier` interpreter is the supported path.

2. **Sending is fire-and-forget.** `SendNotification` returns `()`, and the workflows ignore
   the result — the request endpoints return a generic `202 Accepted` whether or not the account
   exists, to avoid leaking which addresses are registered (see [security.md](security.md)).
   Provider failures therefore never surface to the HTTP caller; your interpreter owns
   retry / queue / dead-letter handling.

## Testing

`shomei-core/src/Shomei/Effect/InMemory.hs` provides `runNotifier`, a list-capturing interpreter
that records each `Notification` in the `World` instead of sending it — use it to assert that a
workflow emitted the expected notification with the expected token, with no network.
