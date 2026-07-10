{-# LANGUAGE PackageImports #-}

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
    runNotifierWebhook,
    renderNotification,
    notificationTypeText,
    webhookSignature,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Data.Aeson (encode)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy qualified as TL
import Data.Time.Format.ISO8601 (iso8601Show)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Network.HTTP.Client
  ( Manager,
    RequestBody (RequestBodyBS),
    httpLbs,
    method,
    parseRequest,
    requestBody,
    requestHeaders,
    responseStatus,
    responseTimeout,
    responseTimeoutMicro,
  )
import Network.HTTP.Types.Status (statusCode, statusIsSuccessful)
import Network.Mail.Mime (Address (..), Mail, simpleMail')
import Network.Mail.SMTP
  ( sendMail',
    sendMailSTARTTLS',
    sendMailTLS',
    sendMailWithLogin',
    sendMailWithLoginSTARTTLS',
    sendMailWithLoginTLS',
  )
import Shomei.Config (NotifierConfig (..), NotifierTransport (..), ShomeiConfig (..), SmtpConfig (..), SmtpTlsMode (..), WebhookConfig (..))
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
-- Pin to cryptonite: smtp-mail (0.3) drags cryptonite into this package's plan alongside the
-- repo's usual crypton, and both expose the same @Crypto.*@ modules. Only cryptonite's
-- @ByteArrayAccess (Digest a)@ instance ends up in scope here (crypton's is shadowed by the
-- module-name collision), so the HMAC digest must come from cryptonite to hex-encode it. This is
-- the one place shomei-server touches cryptonite directly; everywhere else uses crypton.
import "cryptonite" Crypto.Hash.Algorithms (SHA256)
import "cryptonite" Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)

-- | Select the notifier interpreter from configuration and run it, reusing the server's shared
-- TLS 'Manager' for the webhook transport. A single dispatching handler both implements the
-- @alsoLogNotifications@ tee (log first, then deliver — no double delivery) and guards against a
-- selected transport whose sub-config is somehow absent by falling back to the log sender with a
-- one-line warning (boot validation makes that unreachable in the standalone server).
--
-- This is written as one 'interpret_' rather than the plan's @interpose@-based tee: forwarding to
-- an underlying handler by re-'send'ing inside an 'interpose' handler would re-enter the tee
-- handler and loop. Dispatching per notification is unambiguous and runs each delivery once.
runNotifierFromConfig ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  Manager ->
  ShomeiConfig ->
  Eff (Notifier : es) a ->
  Eff es a
runNotifierFromConfig mgr cfg = interpret_ \case
  SendNotification n -> do
    when tee (logNotification nc n)
    deliver n
  where
    nc = cfg.notifierConfig
    tee = nc.alsoLogNotifications && nc.notifierTransport /= LogNotifier
    deliver = case nc.notifierTransport of
      LogNotifier -> logNotification nc
      SmtpNotifier -> maybe (logFallback "smtp" nc) (deliverSmtp nc) nc.smtpConfig
      WebhookNotifier -> maybe (logFallback "webhook" nc) (deliverWebhook mgr) nc.webhookConfig

-- | Fallback used only if a transport is selected with no sub-config (boot validation prevents
-- this): warn once and log the notification rather than silently dropping it.
logFallback :: (IOE :> es) => Text -> NotifierConfig -> Notification -> Eff es ()
logFallback which nc n = do
  liftIO (hPutStrLn stderr ("[shomei:" <> Text.unpack which <> "] no configuration; falling back to the log sender"))
  logNotification nc n

runNotifierLog :: (IOE :> es) => NotifierConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierLog cfg = interpret_ \case
  SendNotification n -> logNotification cfg n

-- | Write one notification to stderr through 'renderNotification' (token redacted unless
-- 'NotifierConfig.logRawTokens'). The per-notification primitive shared by the log sender and the
-- @alsoLogNotifications@ tee.
logNotification :: (IOE :> es) => NotifierConfig -> Notification -> Eff es ()
logNotification cfg n = liftIO (hPutStrLn stderr (renderNotification cfg n))

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
  SendNotification n -> deliverSmtp nc sc n

-- | Deliver one notification over SMTP: build the message, send it under a timeout, and on any
-- failure publish the redacted 'NotificationDeliveryFailed' event. The per-notification primitive
-- shared by 'runNotifierSmtp' and the config dispatcher.
deliverSmtp ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  NotifierConfig ->
  SmtpConfig ->
  Notification ->
  Eff es ()
deliverSmtp nc sc n = do
  let (subject, body) = renderEmail nc n
      recipient = notificationRecipient n
      mail = simpleMail' (Address Nothing recipient) (Address Nothing sc.fromAddress) subject body
  outcome <- liftIO (try @SomeException (sendViaSmtp sc mail))
  case outcome of
    Right () -> pure ()
    Left err -> publishDeliveryFailed "smtp" n (truncateError err)

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
-- single-line error (the caller passes the already-truncated text).
publishDeliveryFailed ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  -- | channel: @"smtp"@ | @"webhook"@
  Text ->
  Notification ->
  -- | truncated, single-line error text (never a token)
  Text ->
  Eff es ()
publishDeliveryFailed channel n errText = do
  let recipient = notificationRecipient n
      kind = notificationTypeText n
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
truncateError = truncateText . Text.pack . displayException

-- | Collapse whitespace (including newlines) to single spaces and cap at 500 characters, so an
-- error string is one safe line for a log and an audit payload.
truncateText :: Text -> Text
truncateText = Text.take 500 . Text.unwords . Text.words

-- Webhook interpreter (EP-8) --------------------------------------------------

-- | Deliver notifications as a signed JSON POST to a configured URL, reusing the server's shared
-- TLS 'Manager'. Same fire-and-forget hardening as 'runNotifierSmtp': all exceptions caught, a
-- non-2xx response counts as a failure, bounded retries with backoff, then one redacted log line
-- plus a 'NotificationDeliveryFailed' audit event. The JSON body is the notification's derived
-- 'ToJSON' (so it carries the raw token — the receiver builds the link), signed over the exact
-- bytes sent with @X-Shomei-Signature: sha256=<hex HMAC-SHA256>@.
runNotifierWebhook ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  Manager ->
  WebhookConfig ->
  Eff (Notifier : es) a ->
  Eff es a
runNotifierWebhook mgr wc = interpret_ \case
  SendNotification n -> deliverWebhook mgr wc n

-- | Deliver one notification over the webhook and, on ultimate failure, publish the redacted
-- 'NotificationDeliveryFailed' event. The per-notification primitive shared by
-- 'runNotifierWebhook' and the config dispatcher.
deliverWebhook ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  Manager ->
  WebhookConfig ->
  Notification ->
  Eff es ()
deliverWebhook mgr wc n = do
  result <- liftIO (attemptWebhook mgr wc n)
  case result of
    Nothing -> pure ()
    Just errText -> publishDeliveryFailed "webhook" n errText

-- | POST the notification, retrying up to 'WebhookConfig.maxAttempts' with @4^(k-1)@-second
-- backoff (1 s, 4 s, …) between attempts, each under the configured per-attempt timeout. Returns
-- 'Nothing' on the first 2xx, or @Just errText@ after the last attempt fails. All exceptions are
-- caught here; nothing escapes to the interpreter.
attemptWebhook :: Manager -> WebhookConfig -> Notification -> IO (Maybe Text)
attemptWebhook mgr wc n = do
  let WebhookConfig {url = u, secret = s, timeoutSeconds = to, maxAttempts = maxA} = wc
      body = BSL.toStrict (encode n)
      sig = webhookSignature (TE.encodeUtf8 s) body
      kind = notificationTypeText n
      attempts = max 1 maxA
  reqE <- try @SomeException (parseRequest (Text.unpack u))
  case reqE of
    Left err -> pure (Just (truncateError err))
    Right req0 -> do
      let req =
            req0
              { method = "POST",
                requestBody = RequestBodyBS body,
                requestHeaders =
                  [ ("Content-Type", "application/json"),
                    ("X-Shomei-Signature", sig),
                    ("X-Shomei-Notification-Type", TE.encodeUtf8 kind),
                    ("User-Agent", "shomei")
                  ],
                responseTimeout = responseTimeoutMicro (max 1 to * 1_000_000)
              }
          go k = do
            outcome <- try @SomeException (httpLbs req mgr)
            let failed errText
                  | k >= attempts = pure (Just errText)
                  | otherwise = threadDelay (4 ^ (k - 1) * 1_000_000) >> go (k + 1)
            case outcome of
              Right resp
                | statusIsSuccessful (responseStatus resp) -> pure Nothing
                | otherwise -> failed ("webhook returned HTTP " <> Text.pack (show (statusCode (responseStatus resp))))
              Left err -> failed (truncateError err)
      go 1

-- | The @X-Shomei-Signature@ header value for a raw body: @sha256=@ followed by the lowercase-hex
-- HMAC-SHA256 of the exact bytes under the shared secret. Signing the strict body that is sent
-- (never a re-encoding) is what lets a receiver verify byte-for-byte.
webhookSignature :: ByteString -> ByteString -> ByteString
webhookSignature secret body =
  "sha256=" <> convertToBase Base16 (hmacGetDigest (hmac secret body :: HMAC SHA256))
