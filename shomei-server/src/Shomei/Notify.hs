-- | Notification interpreters for the standalone server.
--
-- The core defines the 'Notifier' effect and emits a 'Notification' (recipient, one-time
-- link/token, expiry); turning that into a delivered message is this module's job. It provides
-- three built-in interpreters, selected by 'runNotifierFromConfig' from the operator's
-- 'Shomei.Config.NotifierTransport':
--
-- * 'runNotifierLog' writes the link to the server log (the default; development / log-scraping).
--
-- * 'runNotifierSmtp' delivers a plain-text email through a __provider relay__ (SES, SendGrid,
--   Resend, Postmark) over implicit-TLS / STARTTLS / plaintext-lab modes. Not a mail server.
--
-- * 'runNotifierWebhook' POSTs the notification as HMAC-signed JSON to a configured URL.
--
-- Both delivering interpreters are __fire-and-forget and hardened__: every exception is caught
-- inside the interpreter, a failed delivery logs one redacted line and publishes a
-- 'Shomei.Domain.Event.NotificationDeliveryFailed' audit event, and the triggering HTTP request
-- still succeeds. Their operational log lines never contain the one-time token. Operators who
-- want a provider Shōmei does not ship supply their own 'Notifier' interpreter.
module Shomei.Notify
  ( runNotifierFromConfig,
    runNotifierLog,
    runNotifierSmtp,
    renderNotification,
    notificationTypeText,
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as TL
import Data.Time.Format.ISO8601 (iso8601Show)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Network.Mail.Mime (Address (..), Mail, simpleMail')
import Network.Mail.SMTP
  ( sendMail',
    sendMailSTARTTLS',
    sendMailTLS',
    sendMailWithLogin',
    sendMailWithLoginSTARTTLS',
    sendMailWithLoginTLS',
  )
import Shomei.Config (NotifierConfig (..), NotifierTransport (..), ShomeiConfig (..), SmtpConfig (..), SmtpTlsMode (..))
import Shomei.Crypto (sha256Hex)
import Shomei.Domain.Email (emailText)
import Shomei.Domain.Event (AuthEvent (NotificationDeliveryFailed), NotificationDeliveryFailedData (..))
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken, oneTimeTokenText)
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.Notifier (Notifier (..))
import Shomei.Prelude
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)

runNotifierFromConfig :: (IOE :> es) => ShomeiConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierFromConfig cfg =
  case cfg.notifierConfig.notifierTransport of
    LogNotifier -> runNotifierLog cfg.notifierConfig
    -- Temporary until M2/M3 land the real interpreters and M4 rewires selection; the config
    -- surface (M1) is complete but the delivery code is not, so both selectable transports fall
    -- back to the log sender for now. The default transport stays 'LogNotifier', so no deployment
    -- behaves differently.
    SmtpNotifier -> runNotifierLog cfg.notifierConfig
    WebhookNotifier -> runNotifierLog cfg.notifierConfig

runNotifierLog :: (IOE :> es) => NotifierConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierLog cfg = interpret_ \case
  SendNotification n -> liftIO (hPutStrLn stderr (renderNotification cfg n))

-- | Render a notification as one log line.
--
-- By default the one-time token is __redacted__: the line carries only the first 8 hex
-- characters of its SHA-256, which is enough to correlate a log line with the token's
-- stored hash trail but useless for taking the account over (the token itself is 32 random
-- bytes). No link is printed either — a link without its token is noise.
--
-- Setting 'NotifierConfig.logRawTokens' (env @SHOMEI_NOTIFIER_LOG_SECRETS=true@) restores
-- the full clickable link. That is for local development, where the logged link is how you
-- complete the flow; in any shared environment it hands account takeover to whoever can
-- read the log.
renderNotification :: NotifierConfig -> Notification -> String
renderNotification cfg = \case
  EmailVerificationRequested email token expires ->
    line "email_verification" "/v1/auth/verify-email/confirm" email token expires
  PasswordResetRequested email token expires ->
    line "password_reset" "/v1/auth/password-reset/confirm" email token expires
  where
    line kind path email token expires =
      "[shomei:log] "
        <> kind
        <> " email="
        <> Text.unpack (emailText email)
        <> secretPart path token
        <> " expires_at="
        <> show expires
        <> hint
    secretPart path token
      | cfg.logRawTokens =
          " link="
            <> Text.unpack cfg.publicBaseUrl
            <> path
            <> "?token="
            <> Text.unpack (oneTimeTokenText token)
      | otherwise = " token_sha256=" <> Text.unpack (tokenPrefix token)
    hint
      | cfg.logRawTokens = ""
      | otherwise = " (set SHOMEI_NOTIFIER_LOG_SECRETS=true to log the full link in development)"

-- | The first 8 hex characters of the token's SHA-256 — a correlation handle, not a secret.
-- One-time tokens are stored as SHA-256 too (base64url rather than hex), so this prefix
-- ties a log line to its @token_hash@ row.
tokenPrefix :: OneTimeToken -> Text
tokenPrefix = Text.take 8 . sha256Hex . oneTimeTokenText

-- SMTP interpreter (EP-8) -----------------------------------------------------

-- | Deliver notifications as plain-text email through a __provider relay__ (SES, SendGrid,
-- Resend, Postmark). Fire-and-forget and hardened: every exception (including a timeout) is
-- caught, a failed send logs one redacted line and publishes a 'NotificationDeliveryFailed'
-- audit event, and the triggering workflow still returns success. This interpreter sits above
-- 'AuthEventPublisher'/'Clock' in the server stack, so it may publish and read the clock.
runNotifierSmtp ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  NotifierConfig ->
  SmtpConfig ->
  Eff (Notifier : es) a ->
  Eff es a
runNotifierSmtp nc sc = interpret_ \case
  SendNotification n -> do
    let (subject, body) = renderEmail nc n
        recipient = notificationRecipient n
        mail = simpleMail' (Address Nothing recipient) (Address Nothing sc.fromAddress) subject body
    outcome <- liftIO (try @SomeException (sendViaSmtp sc mail))
    case outcome of
      Right () -> pure ()
      Left err -> publishDeliveryFailed "smtp" n err

-- | Run the SMTP dialogue for one message under a timeout, choosing the connection mode from
-- 'SmtpTlsMode' and using the authenticated variant when credentials are present. Boot
-- validation guarantees username and password are both present or both absent, so a lone
-- credential never silently downgrades to an unauthenticated send here.
sendViaSmtp :: SmtpConfig -> Mail -> IO ()
sendViaSmtp sc mail = do
  let SmtpConfig {host = h, port = p, tlsMode = tls, username = mu, password = mp, timeoutSeconds = to} = sc
      host' = Text.unpack h
      port' = fromIntegral p
      creds = (,) <$> mu <*> mp
      send = case (tls, creds) of
        (SmtpPlain, Just (u, pw)) -> sendMailWithLogin' host' port' (Text.unpack u) (Text.unpack pw) mail
        (SmtpPlain, Nothing) -> sendMail' host' port' mail
        (SmtpStartTls, Just (u, pw)) -> sendMailWithLoginSTARTTLS' host' port' (Text.unpack u) (Text.unpack pw) mail
        (SmtpStartTls, Nothing) -> sendMailSTARTTLS' host' port' mail
        (SmtpImplicitTls, Just (u, pw)) -> sendMailWithLoginTLS' host' port' (Text.unpack u) (Text.unpack pw) mail
        (SmtpImplicitTls, Nothing) -> sendMailTLS' host' port' mail
  result <- timeout (max 1 to * 1_000_000) send
  case result of
    Just () -> pure ()
    Nothing -> ioError (userError ("SMTP delivery to " <> host' <> " timed out after " <> show to <> "s"))

-- Shared rendering + failure reporting ----------------------------------------

-- | The event-style type string for a notification, used both in the failure audit event and as
-- the webhook @X-Shomei-Notification-Type@ header (M3). Kept identical to the audit @event_type@
-- vocabulary so a reader correlates the two.
notificationTypeText :: Notification -> Text
notificationTypeText = \case
  EmailVerificationRequested {} -> "email_verification_requested"
  PasswordResetRequested {} -> "password_reset_requested"

-- | The recipient address of a notification.
notificationRecipient :: Notification -> Text
notificationRecipient = \case
  EmailVerificationRequested e _ _ -> emailText e
  PasswordResetRequested e _ _ -> emailText e

-- | The fixed English subject and plain-text body for a notification. These are the only two
-- bodies Shōmei ever emails; there is no templating, i18n, or HTML part (operators who want
-- branded copy take the webhook or a custom interpreter). The confirm links reuse the exact
-- @\/v1@ routes 'renderNotification' logs, so host confirm pages keep working unchanged.
renderEmail :: NotifierConfig -> Notification -> (Text, TL.Text)
renderEmail nc = \case
  EmailVerificationRequested _ token expires ->
    ( "Verify your email address",
      TL.fromStrict
        ( body
            [ "Hello,",
              "",
              "Please confirm your email address by opening this link:",
              "",
              link "/v1/auth/verify-email/confirm" token,
              "",
              "This link expires at " <> isoUtc expires <> " (UTC). If you did not request this,",
              "you can ignore this message."
            ]
        )
    )
  PasswordResetRequested _ token expires ->
    ( "Reset your password",
      TL.fromStrict
        ( body
            [ "Hello,",
              "",
              "A password reset was requested for your account. Open this link to",
              "choose a new password:",
              "",
              link "/v1/auth/password-reset/confirm" token,
              "",
              "This link expires at " <> isoUtc expires <> " (UTC). If you did not request this,",
              "you can ignore this message and your password will remain unchanged."
            ]
        )
    )
  where
    body = Text.intercalate "\n"
    link path token = nc.publicBaseUrl <> path <> "?token=" <> oneTimeTokenText token
    isoUtc = Text.pack . iso8601Show

-- | Log one redacted line and publish a 'NotificationDeliveryFailed' audit event for a delivery
-- that failed after exhausting its attempts. Shared by the SMTP and webhook interpreters. The
-- token appears __nowhere__: only channel, notification type, recipient, and a truncated,
-- single-line error.
publishDeliveryFailed ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  -- | channel: @"smtp"@ | @"webhook"@
  Text ->
  Notification ->
  SomeException ->
  Eff es ()
publishDeliveryFailed channel n err = do
  let recipient = notificationRecipient n
      kind = notificationTypeText n
      errText = truncateError err
  liftIO
    ( hPutStrLn
        stderr
        ( Text.unpack
            ( "[shomei:"
                <> channel
                <> "] delivery_failed type="
                <> kind
                <> " recipient="
                <> recipient
                <> " error="
                <> errText
            )
        )
    )
  occ <- now
  publishAuthEvent
    ( NotificationDeliveryFailed
        NotificationDeliveryFailedData
          { channel = channel,
            notificationType = kind,
            recipient = recipient,
            errorText = errText,
            occurredAt = occ
          }
    )

-- | A single-line, length-capped rendering of an exception for a log line and audit payload:
-- whitespace (including newlines) is collapsed, then the result is truncated to 500 characters.
truncateError :: SomeException -> Text
truncateError = Text.take 500 . Text.unwords . Text.words . Text.pack . displayException
