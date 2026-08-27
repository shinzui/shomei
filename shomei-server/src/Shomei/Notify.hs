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
-- 'Shomei.Audit.Event.Domain.NotificationDeliveryFailed' audit event, and the triggering HTTP request
-- still succeeds. Their operational log lines never contain the one-time token. Operators who
-- want a provider Shōmei does not ship supply their own 'Notifier' interpreter.
module Shomei.Notify
  ( DeliveryReason (..),
    SmtpStage (..),
    reasonText,
    classifySmtpFailure,
    classifyWebhookFailure,
    redactDeliveryText,
    runNotifierEnqueue,
    runNotifierFromConfig,
    runNotifierLog,
    runNotifierSmtp,
    runNotifierWebhook,
    renderNotification,
    notificationTypeText,
    transportChannel,
    deliverNotification,
    webhookSignature,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, SomeException, fromException, try)
import Crypto.Hash.Algorithms (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Aeson (encode)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isSpace)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy qualified as TL
import Data.Time.Format.ISO8601 (iso8601Show)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Network.HTTP.Client
  ( HttpException (..),
    HttpExceptionContent (..),
    Manager,
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
import Shomei.Account.Email.Domain (emailText)
import Shomei.Account.Notification.Domain (Notification (..))
import Shomei.Account.Notification.Store (Notifier (..))
import Shomei.Account.OneTimeToken.Domain (OneTimeToken, oneTimeTokenText)
import Shomei.Account.Password.Hash.Postgres (sha256Hex)
import Shomei.Audit.Event.Domain (AuthEvent (NotificationDeliveryFailed), NotificationDeliveryFailedData (..))
import Shomei.Audit.Publisher.Store (AuthEventPublisher, publishAuthEvent)
import Shomei.Config (NotifierConfig (..), NotifierTransport (..), ShomeiConfig (..), SmtpConfig (..), SmtpTlsMode (..), WebhookConfig (..))
import Shomei.Notify.Queue (NotifierQueue)
import Shomei.Notify.Queue qualified as Queue
import Shomei.Prelude
import Shomei.Time.Store (Clock, now)
import System.IO (hPutStrLn, stderr)
import System.IO.Error (ioeGetErrorString, isUserError)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | Stable, secret-free reasons that may be written to logs and persisted audit rows.
-- Third-party exception text is inspected only long enough to select one of these values.
data DeliveryReason
  = ConnectFailed
  | TlsFailed
  | AuthFailed
  | Timeout
  | RejectedAt SmtpStage Int
  | DataRefused
  | InvalidUrl
  | HttpStatus Int
  | RedirectLoop
  | TransportError
  | QueueFull
  | ShuttingDown
  | ExpiredInQueue
  | Unknown
  deriving stock (Eq, Show)

data SmtpStage = AtEhlo | AtStartTls | AtMail | AtRcpt | AtData
  deriving stock (Eq, Show)

reasonText :: DeliveryReason -> Text
reasonText = \case
  ConnectFailed -> "connect_failed"
  TlsFailed -> "tls_failed"
  AuthFailed -> "auth_failed"
  Timeout -> "timeout"
  RejectedAt stage code -> "rejected_at_" <> smtpStageText stage <> ":" <> Text.pack (show code)
  DataRefused -> "data_refused"
  InvalidUrl -> "invalid_url"
  HttpStatus code -> "http_status:" <> Text.pack (show code)
  RedirectLoop -> "redirect_loop"
  TransportError -> "transport_error"
  QueueFull -> "queue_full"
  ShuttingDown -> "shutting_down"
  ExpiredInQueue -> "expired_in_queue"
  Unknown -> "unknown"

smtpStageText :: SmtpStage -> Text
smtpStageText = \case
  AtEhlo -> "ehlo"
  AtStartTls -> "starttls"
  AtMail -> "mail"
  AtRcpt -> "rcpt"
  AtData -> "data"

-- | Collapse smtp-mail failures into a vocabulary that cannot contain the rendered message.
classifySmtpFailure :: SomeException -> DeliveryReason
classifySmtpFailure err =
  case fromException err :: Maybe IOException of
    Just ioe
      | not (isUserError ioe) -> ConnectFailed
      | otherwise -> classifyUserError (Text.pack (ioeGetErrorString ioe))
    Nothing
      | looksLikeTls (Text.pack (show err)) -> TlsFailed
      | looksLikeConnectFailure (Text.pack (show err)) -> ConnectFailed
      | otherwise -> Unknown
  where
    classifyUserError msg
      | "timed out" `Text.isInfixOf` lower = Timeout
      | "authentication failed" `Text.isInfixOf` lower = AuthFailed
      | "cannot connect to the server" `Text.isInfixOf` lower = ConnectFailed
      | "connection refused" `Text.isInfixOf` lower = ConnectFailed
      | "failed to connect" `Text.isInfixOf` lower = ConnectFailed
      | "cannot accept any data" `Text.isInfixOf` lower = DataRefused
      | Just rejected <- parseRejected msg = rejected
      | otherwise = Unknown
      where
        lower = Text.toLower msg

-- | Collapse http-client failures without retaining the request, URL, headers, or response body.
classifyWebhookFailure :: SomeException -> DeliveryReason
classifyWebhookFailure err =
  case fromException err of
    Just (InvalidUrlException _ _) -> InvalidUrl
    Just (HttpExceptionRequest _ content) -> classifyHttpContent content
    Nothing -> TransportError
  where
    classifyHttpContent = \case
      ResponseTimeout -> Timeout
      ConnectionTimeout -> Timeout
      ConnectionFailure _ -> ConnectFailed
      TooManyRedirects _ -> RedirectLoop
      StatusCodeException response _ -> HttpStatus (statusCode (responseStatus response))
      InternalException inner
        | looksLikeTls (Text.pack (show inner)) -> TlsFailed
      _ -> TransportError

looksLikeTls :: Text -> Bool
looksLikeTls rendered =
  any (`Text.isInfixOf` rendered) ["HandshakeFailed", "TLSException", "TlsException"]

looksLikeConnectFailure :: Text -> Bool
looksLikeConnectFailure rendered =
  any
    (`Text.isInfixOf` rendered)
    ["HostCannotConnect", "Network.Socket.connect", "Connection refused"]

parseRejected :: Text -> Maybe DeliveryReason
parseRejected msg = do
  commandAndRest <- Text.stripPrefix "Unexpected reply to: " msg
  stage <- parseStage commandAndRest
  let (_, reply) = Text.breakOn "Got this instead: " commandAndRest
  guard (not (Text.null reply))
  code <- readMaybe (Text.unpack (Text.take 3 (Text.drop (Text.length "Got this instead: ") reply)))
  pure (RejectedAt stage code)
  where
    parseStage command
      | "EHLO" `Text.isPrefixOf` command || "HELO" `Text.isPrefixOf` command = Just AtEhlo
      | "STARTTLS" `Text.isPrefixOf` command = Just AtStartTls
      | "MAIL" `Text.isPrefixOf` command = Just AtMail
      | "RCPT" `Text.isPrefixOf` command = Just AtRcpt
      | "DATA" `Text.isPrefixOf` command = Just AtData
      | otherwise = Nothing

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
  SendNotification notification -> deliverNotification mgr cfg notification

-- | The standalone request-path interpreter. Enqueueing is one bounded STM transaction and
-- never waits for a relay. Overflow and shutdown are still observable through the audit port.
runNotifierEnqueue ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  NotifierQueue ->
  Text ->
  Eff (Notifier : es) a ->
  Eff es a
runNotifierEnqueue notifierQueue channel = interpret_ \case
  SendNotification notification -> do
    outcome <- liftIO (Queue.enqueueNotification notifierQueue notification)
    case outcome of
      Queue.Enqueued -> pure ()
      Queue.QueueFull -> publishDeliveryFailed channel notification QueueFull
      Queue.QueueClosed -> publishDeliveryFailed channel notification ShuttingDown

-- | Deliver one dequeued notification. Expired work is audited and skipped before any network
-- operation; otherwise this is exactly the synchronous interpreter's former dispatch path.
deliverNotification ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  Manager ->
  ShomeiConfig ->
  Notification ->
  Eff es ()
deliverNotification mgr cfg notification = do
  currentTime <- now
  if notificationExpiresAt notification <= currentTime
    then publishDeliveryFailed (transportChannel nc.notifierTransport) notification ExpiredInQueue
    else do
      when tee (logNotification nc notification)
      deliver notification
  where
    nc = cfg.notifierConfig
    tee = nc.alsoLogNotifications && nc.notifierTransport /= LogNotifier
    deliver = case nc.notifierTransport of
      LogNotifier -> logNotification nc
      SmtpNotifier -> maybe (logFallback "smtp" nc) (deliverSmtp nc) nc.smtpConfig
      WebhookNotifier -> maybe (logFallback "webhook" nc) (deliverWebhook mgr) nc.webhookConfig

transportChannel :: NotifierTransport -> Text
transportChannel = \case
  LogNotifier -> "log"
  SmtpNotifier -> "smtp"
  WebhookNotifier -> "webhook"

notificationExpiresAt :: Notification -> UTCTime
notificationExpiresAt = \case
  EmailVerificationRequested _ _ expires -> expires
  PasswordResetRequested _ _ expires -> expires

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
    Left err -> publishDeliveryFailed "smtp" n (classifySmtpFailure err)

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
-- token appears __nowhere__: only channel, notification type, recipient, and a closed reason
-- code are emitted. The defence-in-depth redactor makes a future free-text reason safe too.
publishDeliveryFailed ::
  (IOE :> es, AuthEventPublisher :> es, Clock :> es) =>
  -- | channel: @"smtp"@ | @"webhook"@
  Text ->
  Notification ->
  DeliveryReason ->
  Eff es ()
publishDeliveryFailed channel n reason = do
  let recipient = notificationRecipient n
      kind = notificationTypeText n
      safeReason = redactDeliveryText n (reasonText reason)
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
                <> " reason="
                <> safeReason
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
            errorText = safeReason,
            occurredAt = occ
          }
    )

-- | Defence in depth for text associated with a delivery. The public failure path uses only
-- 'DeliveryReason', but this also removes the notification's token and any @token=@ parameter
-- before bounding the text in case a future transport threads richer context through here.
redactDeliveryText :: Notification -> Text -> Text
redactDeliveryText notification =
  truncateText
    . redactTokenParameters
    . Text.replace (oneTimeTokenText (notificationToken notification)) "<redacted>"

notificationToken :: Notification -> OneTimeToken
notificationToken = \case
  EmailVerificationRequested _ token _ -> token
  PasswordResetRequested _ token _ -> token

redactTokenParameters :: Text -> Text
redactTokenParameters input =
  case Text.breakOn "token=" input of
    (_, rest) | Text.null rest -> input
    (prefix, rest) ->
      let valueAndSuffix = Text.drop (Text.length "token=") rest
          suffix = Text.dropWhile isTokenCharacter valueAndSuffix
       in prefix <> "token=<redacted>" <> redactTokenParameters suffix
  where
    isTokenCharacter c = not (isSpace c || c `elem` ['&', '\'', '"'])

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
    Just reason -> publishDeliveryFailed "webhook" n reason

-- | POST the notification, retrying up to 'WebhookConfig.maxAttempts' with @4^(k-1)@-second
-- backoff (1 s, 4 s, …) between attempts, each under the configured per-attempt timeout. Returns
-- 'Nothing' on the first 2xx, or a secret-free reason after the last attempt fails. All exceptions are
-- caught here; nothing escapes to the interpreter.
attemptWebhook :: Manager -> WebhookConfig -> Notification -> IO (Maybe DeliveryReason)
attemptWebhook mgr wc n = do
  let WebhookConfig {url = u, secret = s, timeoutSeconds = to, maxAttempts = maxA} = wc
      body = BSL.toStrict (encode n)
      sig = webhookSignature (TE.encodeUtf8 s) body
      kind = notificationTypeText n
      attempts = max 1 maxA
  reqE <- try @SomeException (parseRequest (Text.unpack u))
  case reqE of
    Left _ -> pure (Just InvalidUrl)
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
                | otherwise -> failed (HttpStatus (statusCode (responseStatus resp)))
              Left err -> failed (classifyWebhookFailure err)
      go 1

-- | The @X-Shomei-Signature@ header value for a raw body: @sha256=@ followed by the lowercase-hex
-- HMAC-SHA256 of the exact bytes under the shared secret. Signing the strict body that is sent
-- (never a re-encoding) is what lets a receiver verify byte-for-byte.
webhookSignature :: ByteString -> ByteString -> ByteString
webhookSignature secret body =
  "sha256=" <> convertToBase Base16 (hmacGetDigest (hmac secret body :: HMAC SHA256))
