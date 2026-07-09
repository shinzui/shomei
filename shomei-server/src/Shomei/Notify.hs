-- | Notification interpreters for the standalone server.
--
-- Shōmei does not deliver email. The core defines the 'Notifier' effect and emits a
-- 'Notification' (recipient, one-time link/token, expiry); turning that into a delivered
-- message is the operator's concern. This module provides the one built-in interpreter the
-- shipped server uses — 'runNotifierLog', which writes the link to the server log — selected by
-- 'runNotifierFromConfig'. Operators who want real delivery supply their own 'Notifier'
-- interpreter that forwards the 'Notification' to their existing provider (SendGrid, Resend,
-- SMTP relay, …); a future @shomei-email@ package may package such senders in-tree.
module Shomei.Notify
  ( runNotifierFromConfig,
    runNotifierLog,
    renderNotification,
  )
where

import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Config (NotifierConfig (..), NotifierTransport (..), ShomeiConfig (..))
import Shomei.Crypto (sha256Hex)
import Shomei.Domain.Email (emailText)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken, oneTimeTokenText)
import Shomei.Effect.Notifier (Notifier (..))
import Shomei.Prelude
import System.IO (hPutStrLn, stderr)

runNotifierFromConfig :: (IOE :> es) => ShomeiConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierFromConfig cfg =
  case cfg.notifierConfig.notifierTransport of
    LogNotifier -> runNotifierLog cfg.notifierConfig

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
    line "email_verification" "/auth/verify-email/confirm" email token expires
  PasswordResetRequested email token expires ->
    line "password_reset" "/auth/password-reset/confirm" email token expires
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
