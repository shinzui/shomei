-- | The 'LogNotifier' must not write a usable one-time token to the log. These tests pin
-- both halves of that contract: the default redacted line carries no raw token and no
-- @token=@ URL parameter, and the @logRawTokens@ escape hatch restores the full dev link.
module Shomei.Server.NotifySpec (tests) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeException, bracket, catch, finally, toException)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (decode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Char (toUpper)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import Network.HTTP.Types (RequestHeaders)
import Network.HTTP.Types.Status (mkStatus)
import Network.Socket
import Network.Wai (Application, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Shomei.Account.Email.Domain (Email, mkEmail)
import Shomei.Account.Notification.Domain (Notification (..))
import Shomei.Account.Notification.Store (sendNotification)
import Shomei.Account.OneTimeToken.Domain (OneTimeToken (..))
import Shomei.Account.Password.Hash.Postgres (sha256Hex)
import Shomei.Audit.Event.Domain (AuthEvent (NotificationDeliveryFailed), NotificationDeliveryFailedData (..))
import Shomei.Audit.Publisher.Store (AuthEventPublisher (..))
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (NotifierConfig (..), ShomeiConfig (..), SmtpConfig (..), SmtpTlsMode (..), WebhookConfig (..), defaultShomeiConfig)
import Shomei.Notify
  ( DeliveryReason (..),
    SmtpStage (..),
    WebhookSecret (..),
    classifySmtpFailure,
    renderNotification,
    runNotifierEnqueue,
    runNotifierSmtp,
    runNotifierWebhook,
    webhookSignature,
  )
import Shomei.Notify.Queue qualified as Queue
import Shomei.Time.Postgres (runClockIO)
import System.IO (BufferMode (LineBuffering), Handle, IOMode (ReadWriteMode), hClose, hFlush, hGetLine, hIsEOF, hPutStr, hSetBuffering)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | A token whose text is distinctive enough that a substring check is meaningful.
rawToken :: Text.Text
rawToken = "s3cr3t-one-time-token-do-not-log-me"

tests :: TestTree
tests =
  testGroup
    "Notify"
    [ testCase "redacts the one-time token by default" do
        email <- testEmail
        let out = render False (PasswordResetRequested email (OneTimeToken rawToken) expires)
        assertBool
          ("raw token must not appear in: " <> out)
          (not (Text.unpack rawToken `isInfixOf` out))
        assertBool
          ("no ?token= URL parameter in: " <> out)
          (not ("?token=" `isInfixOf` out))
        assertBool
          ("hash prefix must appear in: " <> out)
          (("token_sha256=" <> Text.unpack expectedPrefix) `isInfixOf` out)
        assertBool "kind is labelled" ("password_reset" `isInfixOf` out),
      testCase "logs the full link when logRawTokens is set" do
        email <- testEmail
        let out = render True (EmailVerificationRequested email (OneTimeToken rawToken) expires)
        assertBool
          ("full link expected in: " <> out)
          (("/v1/auth/verify-email/confirm?token=" <> Text.unpack rawToken) `isInfixOf` out)
        assertBool "no hash prefix in raw mode" (not ("token_sha256=" `isInfixOf` out)),
      smtpDeliversTest,
      smtpFailureTest,
      smtpDataRejectTest,
      smtpClassifierTest,
      notifierQueueTest,
      webhookDeliversTest,
      webhookRetriesThenSucceeds,
      webhookExhaustsThenAudits,
      webhookResponseBodyNeverAuditedTest,
      webhookTransportFailureRedactsRequestTest
    ]
  where
    expires = fixtureExpiry
    expectedPrefix = Text.take 8 (sha256Hex rawToken)
    render raw n = renderNotification (notifierCfg raw) n
    notifierCfg raw =
      (defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")).notifierConfig
        { logRawTokens = raw
        }

testEmail :: IO Email
testEmail = either (\e -> assertFailure ("bad email: " <> show e)) pure (mkEmail "a@example.com")

-- SMTP interpreter (EP-8 M2) --------------------------------------------------

fixtureExpiry :: UTCTime
fixtureExpiry = UTCTime (fromGregorian 2030 7 8) 0

-- | The stock notifier config; only 'publicBaseUrl' (the link base) matters to these tests.
baseNotifierCfg :: NotifierConfig
baseNotifierCfg = (defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")).notifierConfig

-- | A plaintext SMTP relay pointed at @127.0.0.1:port@, unauthenticated (lab-sink shape).
plainSmtpConfig :: Int -> SmtpConfig
plainSmtpConfig p =
  SmtpConfig
    { host = "127.0.0.1",
      port = p,
      tlsMode = SmtpPlain,
      username = Nothing,
      fromAddress = "auth@example.com",
      timeoutSeconds = 5
    }

-- | Capture published audit events into an 'IORef', standing in for the PostgreSQL publisher.
runAuthEventCapture :: (IOE :> es) => IORef [AuthEvent] -> Eff (AuthEventPublisher : es) a -> Eff es a
runAuthEventCapture ref = interpret_ \case
  PublishAuthEvent e -> liftIO (modifyIORef' ref (<> [e]))

-- | Run @runNotifierSmtp@ for one notification against the given config, collecting any published
-- audit events. Uses the real IO clock; no HTTP or database is involved.
deliverViaSmtp :: SmtpConfig -> Notification -> IO [AuthEvent]
deliverViaSmtp sc n = do
  events <- newIORef []
  runEff . runClockIO . runAuthEventCapture events . runNotifierSmtp baseNotifierCfg sc Nothing $ sendNotification n
  readIORef events

-- | The delivered message reaches a sink with the right recipient, subject, and confirm link, and
-- a successful send publishes no failure event.
smtpDeliversTest :: TestTree
smtpDeliversTest = testCase "SMTP: delivers the message to a sink with the confirm link" do
  email <- testEmail
  bracket openSink (close . sinkSocket) \sink -> bracket (forkIO (acceptLoop sink)) killThread \_ -> do
    events <- deliverViaSmtp (plainSmtpConfig (sinkPort sink)) (EmailVerificationRequested email (OneTimeToken rawToken) fixtureExpiry)
    transcript <- readMVar (sinkTranscript sink)
    assertBool
      ("RCPT TO for the recipient in: " <> show transcript)
      (any (\l -> "RCPT TO" `isInfixOf` map toUpper l && "a@example.com" `isInfixOf` l) transcript)
    assertBool
      ("subject line in: " <> show transcript)
      (any ("Verify your email address" `isInfixOf`) transcript)
    assertBool
      ("confirm link in: " <> show transcript)
      (any ("/v1/auth/verify-email/confirm?token=" `isInfixOf`) transcript)
    assertBool ("no failure event on success, got: " <> show events) (null events)

-- | A refused connection is fire-and-forget: the interpreter never throws, publishes exactly one
-- redacted 'NotificationDeliveryFailed' event, and that event carries no token.
smtpFailureTest :: TestTree
smtpFailureTest = testCase "SMTP: a refused connection audits a failure and never throws" do
  email <- testEmail
  port <- closedPort
  events <- deliverViaSmtp (plainSmtpConfig port {- unreachable -}) (PasswordResetRequested email (OneTimeToken rawToken) fixtureExpiry)
  case events of
    [NotificationDeliveryFailed d] -> do
      d.channel @?= "smtp"
      d.notificationType @?= "password_reset_requested"
      d.recipient @?= "a@example.com"
      d.errorText @?= "connect_failed"
      assertBool
        ("the token must not appear in the audit error: " <> Text.unpack d.errorText)
        (not (Text.unpack rawToken `isInfixOf` Text.unpack d.errorText))
    _ -> assertFailure ("expected exactly one delivery-failure event, got: " <> show events)

-- | smtp-mail includes the entire rendered message in the exception raised when the relay
-- rejects DATA. Persisting that exception therefore persists the one-time token too.
smtpDataRejectTest :: TestTree
smtpDataRejectTest = testCase "SMTP: a 451 at DATA audits a reason code, never the message" do
  email <- testEmail
  bracket openSink (close . sinkSocket) \sink -> bracket (forkIO (acceptLoopWithDataReply "451 4.7.1 greylisted, try again later\r\n" sink)) killThread \_ -> do
    events <- deliverViaSmtp (plainSmtpConfig (sinkPort sink)) (PasswordResetRequested email (OneTimeToken rawToken) fixtureExpiry)
    case events of
      [NotificationDeliveryFailed d] -> do
        d.errorText @?= "rejected_at_data:451"
        assertBool
          ("the rendered message must not appear in the audit reason: " <> Text.unpack d.errorText)
          (not ("token=" `Text.isInfixOf` unfoldQuotedPrintable d.errorText))
        assertBool
          ("the token must not appear in the audit reason: " <> Text.unpack d.errorText)
          (not (rawToken `Text.isInfixOf` unfoldQuotedPrintable d.errorText))
      _ -> assertFailure ("expected exactly one delivery-failure event, got: " <> show events)

unfoldQuotedPrintable :: Text.Text -> Text.Text
unfoldQuotedPrintable =
  Text.replace "=2E" "."
    . Text.replace "=3D" "="
    . Text.replace "=\\r\\n" ""
    . Text.replace "=\r\n" ""

smtpClassifierTest :: TestTree
smtpClassifierTest = testCase "classifySmtpFailure maps smtp-mail messages to reasons" do
  classifySmtpFailure
    ( toException
        ( userError
            "Unexpected reply to: DATA \"rendered message\", Expected reply code: 250, Got this instead: 451 \"greylisted\""
        )
    )
    @?= RejectedAt AtData 451
  classifySmtpFailure (toException (userError "authentication failed.")) @?= AuthFailed
  classifySmtpFailure (toException (userError "SMTP delivery timed out")) @?= Timeout
  classifySmtpFailure (toException (userError "unclassified SMTP failure")) @?= Unknown

notifierQueueTest :: TestTree
notifierQueueTest = testCase "queue: overflow and shutdown audit without blocking; drain reports remainder" do
  email <- testEmail
  let notification = PasswordResetRequested email (OneTimeToken rawToken) fixtureExpiry
      enqueueThroughPort queue = do
        events <- newIORef []
        runEff . runClockIO . runAuthEventCapture events . runNotifierEnqueue queue "webhook" $ sendNotification notification
        readIORef events

  queue <- Queue.newNotifierQueue 2
  enqueueThroughPort queue >>= (@?= [])
  enqueueThroughPort queue >>= (@?= [])
  fullEvents <- enqueueThroughPort queue
  deliveryReason fullEvents @?= Just "queue_full"
  Queue.closeNotifierQueue queue
  closedEvents <- enqueueThroughPort queue
  deliveryReason closedEvents @?= Just "shutting_down"

  drained <- Queue.newNotifierQueue 1
  Queue.enqueueNotification drained notification >>= (@?= Queue.Enqueued)
  consumer <- forkIO (Queue.withDequeued drained (const (pure ())))
  Queue.closeNotifierQueue drained
  Queue.drainNotifierQueue drained 1 >>= (@?= 0)
  killThread consumer

  undrained <- Queue.newNotifierQueue 1
  Queue.enqueueNotification undrained notification >>= (@?= Queue.Enqueued)
  Queue.closeNotifierQueue undrained
  Queue.drainNotifierQueue undrained 0 >>= (@?= 1)
  where
    deliveryReason = \case
      [NotificationDeliveryFailed d] -> Just d.errorText
      _ -> Nothing

-- A minimal in-process SMTP sink -------------------------------------------------

data Sink = Sink
  { sinkSocket :: !Socket,
    sinkPort :: !Int,
    sinkTranscript :: !(MVar [String])
  }

-- | Bind a listening socket on an ephemeral @127.0.0.1@ port and return it with an empty
-- transcript. The caller forks 'acceptLoop' and closes the socket when done.
openSink :: IO Sink
openSink = do
  let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
  addr <- head <$> getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
  sock <- socket (addrFamily addr) Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock (addrAddress addr)
  listen sock 5
  p <- socketPort sock
  transcript <- newMVar []
  pure Sink {sinkSocket = sock, sinkPort = fromIntegral p, sinkTranscript = transcript}

-- | A port with nothing listening: bind then immediately release, so a later connect is refused.
closedPort :: IO Int
closedPort = bracket openSink (close . sinkSocket) (pure . sinkPort)

-- | Accept connections and serve each in its own thread, speaking just enough plaintext SMTP.
-- All exceptions are swallowed: when the test kills this thread or closes the listening socket,
-- the resulting @accept@/@threadWait@ error must not print or fail the suite.
acceptLoop :: Sink -> IO ()
acceptLoop = acceptLoopWithDataReply "250 OK queued\r\n"

acceptLoopWithDataReply :: String -> Sink -> IO ()
acceptLoopWithDataReply dataReply sink = loop `catch` \(_ :: SomeException) -> pure ()
  where
    loop = forever do
      (conn, _) <- accept (sinkSocket sink)
      h <- socketToHandle conn ReadWriteMode
      _ <- forkIO ((serveSmtp dataReply (sinkTranscript sink) h `finally` hClose h) `catch` \(_ :: SomeException) -> pure ())
      pure ()

-- | The sink SMTP dialogue: greet, answer EHLO/MAIL/RCPT with 250, DATA with 354 then 250 after
-- the terminating dot, and QUIT with 221. Every command line and DATA body line is recorded.
serveSmtp :: String -> MVar [String] -> Handle -> IO ()
serveSmtp dataReply transcript h = do
  hSetBuffering h LineBuffering
  respond "220 shomei-test-sink ready\r\n"
  loop
  where
    respond s = hPutStr h s >> hFlush h
    record l = modifyMVar_ transcript (pure . (<> [l]))
    loop = do
      eof <- hIsEOF h
      if eof
        then pure ()
        else do
          line <- stripCR <$> hGetLine h
          record line
          case verb line of
            "EHLO" -> respond "250 shomei-test-sink\r\n" >> loop
            "HELO" -> respond "250 shomei-test-sink\r\n" >> loop
            "MAIL" -> respond "250 OK\r\n" >> loop
            "RCPT" -> respond "250 OK\r\n" >> loop
            "DATA" -> respond "354 end with .\r\n" >> readData >> respond dataReply >> loop
            "QUIT" -> respond "221 Bye\r\n"
            _ -> respond "250 OK\r\n" >> loop
    readData = do
      line <- stripCR <$> hGetLine h
      record ("DATA> " <> line)
      if line == "." then pure () else readData
    verb = map toUpper . take 4
    stripCR s = if not (null s) && last s == '\r' then init s else s

-- Webhook interpreter (EP-8 M3) -----------------------------------------------

webhookSecretText :: Text.Text
webhookSecretText = "test-webhook-secret"

webhookConfigFor :: Int -> Int -> WebhookConfig
webhookConfigFor p maxA =
  WebhookConfig
    { url = Text.pack ("http://127.0.0.1:" <> show p <> "/hook"),
      timeoutSeconds = 5,
      maxAttempts = maxA
    }

deliverViaWebhook :: Manager -> WebhookConfig -> Notification -> IO [AuthEvent]
deliverViaWebhook mgr wc n = do
  events <- newIORef []
  runEff . runClockIO . runAuthEventCapture events . runNotifierWebhook mgr wc (WebhookSecret webhookSecretText) $ sendNotification n
  readIORef events

-- | A stub receiver that records every @(headers, raw body)@ it gets and answers the k-th
-- request (1-indexed) with @statusFor k@. The body is fully drained before responding so an
-- attempt count is never miscounted.
webhookStub ::
  IORef Int ->
  (Int -> Int) ->
  MVar [(RequestHeaders, BS.ByteString)] ->
  Application
webhookStub counter statusFor captured req respond = do
  body <- LBS.toStrict <$> strictRequestBody req
  modifyMVar_ captured (pure . (<> [(requestHeaders req, body)]))
  k <- atomicModifyIORef' counter (\c -> (c + 1, c + 1))
  respond (responseLBS (mkStatus (statusFor k) "") [] "")

-- | A single successful POST carries the JSON body, the type header, and a signature that
-- verifies against the shared secret recomputed over the exact bytes received.
webhookDeliversTest :: TestTree
webhookDeliversTest = testCase "webhook: signed JSON POST the receiver can verify" do
  email <- testEmail
  mgr <- newManager defaultManagerSettings
  captured <- newMVar []
  counter <- newIORef 0
  let n = EmailVerificationRequested email (OneTimeToken rawToken) fixtureExpiry
  testWithApplication (pure (webhookStub counter (const 200) captured)) \port -> do
    events <- deliverViaWebhook mgr (webhookConfigFor port 1) n
    reqs <- readMVar captured
    case reqs of
      [(hdrs, body)] -> do
        lookup "Content-Type" hdrs @?= Just "application/json"
        lookup "X-Shomei-Notification-Type" hdrs @?= Just "email_verification_requested"
        decode (LBS.fromStrict body) @?= Just n
        case lookup "X-Shomei-Timestamp" hdrs of
          Nothing -> assertFailure "missing X-Shomei-Timestamp"
          Just timestamp ->
            lookup "X-Shomei-Signature" hdrs @?= Just (webhookSignature (TE.encodeUtf8 webhookSecretText) timestamp body)
      _ -> assertFailure ("expected exactly one delivery, got " <> show (length reqs))
    assertBool ("no failure event on success, got: " <> show events) (null events)

-- | A 5xx is retried; a later success ends the delivery with no failure event.
webhookRetriesThenSucceeds :: TestTree
webhookRetriesThenSucceeds = testCase "webhook: retries a 5xx then succeeds, no failure event" do
  email <- testEmail
  mgr <- newManager defaultManagerSettings
  captured <- newMVar []
  counter <- newIORef 0
  let n = PasswordResetRequested email (OneTimeToken rawToken) fixtureExpiry
      statusFor k = if k <= 1 then 500 else 200
  testWithApplication (pure (webhookStub counter statusFor captured)) \port -> do
    events <- deliverViaWebhook mgr (webhookConfigFor port 2) n
    reqs <- readMVar captured
    length reqs @?= 2
    let timestamps = map (lookup "X-Shomei-Timestamp" . fst) reqs
    assertBool ("each retry must be re-stamped, got: " <> show timestamps) (case timestamps of [Just first, Just second] -> first /= second; _ -> False)
    mapM_
      ( \(headers, body) -> case lookup "X-Shomei-Timestamp" headers of
          Nothing -> assertFailure "retry missing X-Shomei-Timestamp"
          Just timestamp ->
            lookup "X-Shomei-Signature" headers @?= Just (webhookSignature (TE.encodeUtf8 webhookSecretText) timestamp body)
      )
      reqs
    assertBool ("no failure event on eventual success, got: " <> show events) (null events)

-- | A receiver that always 5xxes is attempted exactly @maxAttempts@ times, then a redacted
-- failure event is published — carrying no token.
webhookExhaustsThenAudits :: TestTree
webhookExhaustsThenAudits = testCase "webhook: exhausts attempts then audits a redacted failure" do
  email <- testEmail
  mgr <- newManager defaultManagerSettings
  captured <- newMVar []
  counter <- newIORef 0
  let n = EmailVerificationRequested email (OneTimeToken rawToken) fixtureExpiry
  testWithApplication (pure (webhookStub counter (const 500) captured)) \port -> do
    events <- deliverViaWebhook mgr (webhookConfigFor port 2) n
    reqs <- readMVar captured
    length reqs @?= 2
    case events of
      [NotificationDeliveryFailed d] -> do
        d.channel @?= "webhook"
        d.notificationType @?= "email_verification_requested"
        d.recipient @?= "a@example.com"
        assertBool
          ("the token must not appear in the audit error: " <> Text.unpack d.errorText)
          (not (Text.unpack rawToken `isInfixOf` Text.unpack d.errorText))
      _ -> assertFailure ("expected exactly one delivery-failure event, got: " <> show events)

webhookResponseBodyNeverAuditedTest :: TestTree
webhookResponseBodyNeverAuditedTest = testCase "webhook: a 500 that echoes the body audits only the status" do
  email <- testEmail
  mgr <- newManager defaultManagerSettings
  captured <- newMVar []
  let n = PasswordResetRequested email (OneTimeToken rawToken) fixtureExpiry
      echoingStub req respond = do
        body <- LBS.toStrict <$> strictRequestBody req
        modifyMVar_ captured (pure . (<> [(requestHeaders req, body)]))
        respond (responseLBS (mkStatus 500 "") [] (LBS.fromStrict body))
  testWithApplication (pure echoingStub) \port -> do
    events <- deliverViaWebhook mgr (webhookConfigFor port 1) n
    case events of
      [NotificationDeliveryFailed d] -> do
        d.errorText @?= "http_status:500"
        assertBool
          ("the response body must not appear in the audit reason: " <> Text.unpack d.errorText)
          (not (rawToken `Text.isInfixOf` d.errorText))
      _ -> assertFailure ("expected exactly one delivery-failure event, got: " <> show events)

-- | http-client's Show instance includes the request query string. A transport exception must
-- therefore be classified before it is persisted.
webhookTransportFailureRedactsRequestTest :: TestTree
webhookTransportFailureRedactsRequestTest = testCase "webhook: a transport failure never persists the request" do
  email <- testEmail
  mgr <- newManager defaultManagerSettings
  port <- closedPort
  let wc =
        (webhookConfigFor port 1)
          { url = Text.pack ("http://127.0.0.1:" <> show port <> "/hook?key=url-secret-hunter2")
          }
  events <- deliverViaWebhook mgr wc (PasswordResetRequested email (OneTimeToken rawToken) fixtureExpiry)
  case events of
    [NotificationDeliveryFailed d] -> do
      d.errorText @?= "connect_failed"
      assertBool
        ("the request URL must not appear in the audit reason: " <> Text.unpack d.errorText)
        (not ("hunter2" `Text.isInfixOf` d.errorText))
    _ -> assertFailure ("expected exactly one delivery-failure event, got: " <> show events)
