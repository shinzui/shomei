-- | Notification interpreters for the standalone server.
module Shomei.Notify (
    runNotifierFromConfig,
    runNotifierLog,
    runNotifierSmtp,
) where

import Shomei.Prelude

import "base" System.IO (hPutStrLn, stderr)
import "effectful-core" Effectful (Eff, IOE, (:>))
import "effectful-core" Effectful.Dispatch.Dynamic (interpret_)
import "text" Data.Text qualified as Text

import Shomei.Config (NotifierConfig (..), NotifierTransport (..), ShomeiConfig (..))
import Shomei.Domain.Email (emailText)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (oneTimeTokenText)
import Shomei.Effect.Notifier (Notifier (..))

runNotifierFromConfig :: (IOE :> es) => ShomeiConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierFromConfig cfg =
    case cfg.notifierConfig.notifierTransport of
        LogNotifier -> runNotifierLog cfg.notifierConfig
        SmtpNotifier -> runNotifierSmtp cfg.notifierConfig

runNotifierLog :: (IOE :> es) => NotifierConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierLog cfg = interpret_ \case
    SendNotification n -> liftIO (hPutStrLn stderr (renderNotification "log" cfg n))

runNotifierSmtp :: (IOE :> es) => NotifierConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierSmtp cfg = interpret_ \case
    SendNotification n -> liftIO (hPutStrLn stderr (renderNotification "smtp" cfg n))

renderNotification :: String -> NotifierConfig -> Notification -> String
renderNotification transport cfg = \case
    EmailVerificationRequested email token expires ->
        "[shomei:"
            <> transport
            <> "] email_verification email="
            <> Text.unpack (emailText email)
            <> " link="
            <> Text.unpack cfg.publicBaseUrl
            <> "/auth/verify-email/confirm?token="
            <> Text.unpack (oneTimeTokenText token)
            <> " expires_at="
            <> show expires
    PasswordResetRequested email token expires ->
        "[shomei:"
            <> transport
            <> "] password_reset email="
            <> Text.unpack (emailText email)
            <> " link="
            <> Text.unpack cfg.publicBaseUrl
            <> "/auth/password-reset/confirm?token="
            <> Text.unpack (oneTimeTokenText token)
            <> " expires_at="
            <> show expires
