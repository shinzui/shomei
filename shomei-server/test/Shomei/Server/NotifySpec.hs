-- | The 'LogNotifier' must not write a usable one-time token to the log. These tests pin
-- both halves of that contract: the default redacted line carries no raw token and no
-- @token=@ URL parameter, and the @logRawTokens@ escape hatch restores the full dev link.
module Shomei.Server.NotifySpec (tests) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (bracket, finally)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import Data.Char (toUpper)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Network.Socket
import Shomei.Config (NotifierConfig (..), ShomeiConfig (..), SmtpConfig (..), SmtpTlsMode (..), defaultShomeiConfig)
import Shomei.Crypto (sha256Hex)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event (AuthEvent (NotificationDeliveryFailed), NotificationDeliveryFailedData (..))
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher (..))
import Shomei.Effect.Notifier (sendNotification)
import Shomei.Notify (renderNotification, runNotifierSmtp)
import Shomei.Postgres.Clock (runClockIO)
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
      smtpFailureTest
    ]
  where
    expires = fixtureExpiry
    expectedPrefix = Text.take 8 (sha256Hex rawToken)
    render raw n = renderNotification (notifierCfg raw) n
    notifierCfg raw =
      (defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")).notifierConfig
        {logRawTokens = raw}

testEmail :: IO Email
testEmail = either (\e -> assertFailure ("bad email: " <> show e)) pure (mkEmail "a@example.com")

-- SMTP interpreter (EP-8 M2) --------------------------------------------------

fixtureExpiry :: UTCTime
fixtureExpiry = UTCTime (fromGregorian 2026 7 8) 0

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
      password = Nothing,
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
  runEff . runClockIO . runAuthEventCapture events . runNotifierSmtp baseNotifierCfg sc $ sendNotification n
  readIORef events

-- | The delivered message reaches a sink with the right recipient, subject, and confirm link, and
-- a successful send publishes no failure event.
smtpDeliversTest :: TestTree
smtpDeliversTest = testCase "SMTP: delivers the message to a sink with the confirm link" do
  email <- testEmail
  bracket openSink (close . sinkSocket) \sink -> do
    _ <- forkIO (acceptLoop sink)
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
  events <- deliverViaSmtp (plainSmtpConfig port) {- unreachable -} (PasswordResetRequested email (OneTimeToken rawToken) fixtureExpiry)
  case events of
    [NotificationDeliveryFailed d] -> do
      d.channel @?= "smtp"
      d.notificationType @?= "password_reset_requested"
      d.recipient @?= "a@example.com"
      assertBool "the failure carries some error text" (not (Text.null d.errorText))
      assertBool
        ("the token must not appear in the audit error: " <> Text.unpack d.errorText)
        (not (Text.unpack rawToken `isInfixOf` Text.unpack d.errorText))
    _ -> assertFailure ("expected exactly one delivery-failure event, got: " <> show events)

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
acceptLoop :: Sink -> IO ()
acceptLoop sink = forever do
  (conn, _) <- accept (sinkSocket sink)
  h <- socketToHandle conn ReadWriteMode
  _ <- forkIO (serveSmtp (sinkTranscript sink) h `finally` hClose h)
  pure ()

-- | The sink SMTP dialogue: greet, answer EHLO/MAIL/RCPT with 250, DATA with 354 then 250 after
-- the terminating dot, and QUIT with 221. Every command line and DATA body line is recorded.
serveSmtp :: MVar [String] -> Handle -> IO ()
serveSmtp transcript h = do
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
            "DATA" -> respond "354 end with .\r\n" >> readData >> respond "250 OK queued\r\n" >> loop
            "QUIT" -> respond "221 Bye\r\n"
            _ -> respond "250 OK\r\n" >> loop
    readData = do
      line <- stripCR <$> hGetLine h
      record ("DATA> " <> line)
      if line == "." then pure () else readData
    verb = map toUpper . take 4
    stripCR s = if not (null s) && last s == '\r' then init s else s
