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
  )
where

import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Config (NotifierConfig (..), NotifierTransport (..), ShomeiConfig (..))
import Shomei.Domain.Email (emailText)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (oneTimeTokenText)
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

renderNotification :: NotifierConfig -> Notification -> String
renderNotification cfg = \case
  EmailVerificationRequested email token expires ->
    "[shomei:log] email_verification email="
      <> Text.unpack (emailText email)
      <> " link="
      <> Text.unpack cfg.publicBaseUrl
      <> "/auth/verify-email/confirm?token="
      <> Text.unpack (oneTimeTokenText token)
      <> " expires_at="
      <> show expires
  PasswordResetRequested email token expires ->
    "[shomei:log] password_reset email="
      <> Text.unpack (emailText email)
      <> " link="
      <> Text.unpack cfg.publicBaseUrl
      <> "/auth/password-reset/confirm?token="
      <> Text.unpack (oneTimeTokenText token)
      <> " expires_at="
      <> show expires
