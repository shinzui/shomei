# Notifications: sending account-lifecycle email

Shōmei emits notifications — it does **not** send email. The account-lifecycle workflows
(email verification, password reset) produce a `Notification` value and hand it to the
`Notifier` effect; *delivering* it is your responsibility. The toolkit ships one built-in
interpreter, a development sender that writes the link to the server log. To send real email
through your provider (SendGrid, Resend, SES, an SMTP relay, an internal mail service, …), you
supply your own `Notifier` interpreter.

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
<publicBaseUrl>/auth/verify-email/confirm?token=<token>
<publicBaseUrl>/auth/password-reset/confirm?token=<token>
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
                (baseUrl <> "/auth/verify-email/confirm?token=" <> oneTimeTokenText token)
        PasswordResetRequested email token _expiresAt ->
            sendEmail client (emailText email) "Reset your password"
                (baseUrl <> "/auth/password-reset/confirm?token=" <> oneTimeTokenText token)
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

## Two things to know

1. **This is an in-process Haskell API.** Plugging in a sender means composing Shōmei as a
   library and building your own server assembly (replacing the one line above). The prebuilt
   `shomei-server` / `shomei-admin` binaries hardcode the dev log sender — there is no config
   flag or plugin hook to inject an external sender into the stock binary. If you run the stock
   binary, your only built-in option is to scrape the structured log line (it carries the
   recipient, the confirm link, and the expiry).

2. **Sending is fire-and-forget.** `SendNotification` returns `()`, and the workflows ignore
   the result — the request endpoints return a generic `202 Accepted` whether or not the account
   exists, to avoid leaking which addresses are registered (see [security.md](security.md)).
   Provider failures therefore never surface to the HTTP caller; your interpreter owns
   retry / queue / dead-letter handling.

## Testing

`shomei-core/src/Shomei/Effect/InMemory.hs` provides `runNotifier`, a list-capturing interpreter
that records each `Notification` in the `World` instead of sending it — use it to assert that a
workflow emitted the expected notification with the expected token, with no network.
