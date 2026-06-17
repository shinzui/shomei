-- | Account lifecycle workflows for email verification and password management.
module Shomei.Workflow.Account (
    RequestEmailVerification (..),
    ConfirmEmailVerification (..),
    RequestPasswordReset (..),
    ConfirmPasswordReset (..),
    ChangePassword (..),
    requestEmailVerification,
    confirmEmailVerification,
    requestPasswordReset,
    confirmPasswordReset,
    changePassword,
) where

import Shomei.Prelude

import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)

import Shomei.Config (NotifierConfig (..), ShomeiConfig (..))
import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Email (Email, emailText)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken (..), OneTimeTokenHash (..), OneTimeTokenStatus (..))
import Shomei.Domain.Password (PasswordContext (..), PlainPassword, validatePassword)
import Shomei.Domain.PasswordResetToken (NewPasswordResetToken (..), PersistedPasswordResetToken (..))
import Shomei.Domain.RefreshToken (RefreshToken (..), RefreshTokenHash (..))
import Shomei.Domain.User (User (..), UserStatus (UserActive))
import Shomei.Domain.VerificationToken (NewVerificationToken (..), PersistedVerificationToken (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.CredentialStore (CredentialStore, findPasswordCredentialByLoginId, updatePasswordHash)
import Shomei.Effect.Notifier (Notifier, sendNotification)
import Shomei.Effect.PasswordBreachChecker (PasswordBreachChecker)
import Shomei.Effect.PasswordHasher (PasswordHasher, hashPassword, verifyPassword)
import Shomei.Effect.PasswordResetTokenStore (
    PasswordResetTokenStore,
    createPasswordResetToken,
    findPasswordResetTokenByHash,
    markPasswordResetTokenConsumed,
 )
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore, revokeAllUserRefreshTokens)
import Shomei.Effect.SessionStore (SessionStore, revokeAllUserSessions)
import Shomei.Effect.TokenGen (TokenGen, generateOpaqueToken, hashRefreshToken)
import Shomei.Effect.UserStore (UserStore, findUserByEmail, findUserById, markUserEmailVerified)
import Shomei.Effect.VerificationTokenStore (
    VerificationTokenStore,
    createVerificationToken,
    findVerificationTokenByHash,
    markVerificationTokenConsumed,
 )

import Shomei.Workflow.Breach (enforceBreachPolicy)

newtype RequestEmailVerification = RequestEmailVerification {email :: Email}
    deriving stock (Generic, Show)

newtype ConfirmEmailVerification = ConfirmEmailVerification {token :: OneTimeToken}
    deriving stock (Generic, Show)

newtype RequestPasswordReset = RequestPasswordReset {email :: Email}
    deriving stock (Generic, Show)

data ConfirmPasswordReset = ConfirmPasswordReset
    { token :: !OneTimeToken
    , newPassword :: !PlainPassword
    }
    deriving stock (Generic, Show)

data ChangePassword = ChangePassword
    { userId :: !UserId
    , currentPassword :: !PlainPassword
    , newPassword :: !PlainPassword
    }
    deriving stock (Generic, Show)

requestEmailVerification ::
    ( UserStore :> es
    , VerificationTokenStore :> es
    , Notifier :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    RequestEmailVerification ->
    Eff es (Either AuthError ())
requestEmailVerification cfg cmd = do
    ts <- now
    mUser <- findUserByEmail cmd.email
    forM_ mUser \user ->
        forM_ user.email \email ->
            when (user.status == UserActive && isNothing user.emailVerifiedAt) do
                let expires = addUTCTime cfg.notifierConfig.verificationTokenTTL ts
                (raw, h) <- generateOneTimeToken
                _ <-
                    createVerificationToken
                        NewVerificationToken
                            { userId = user.userId
                            , tokenHash = h
                            , createdAt = ts
                            , expiresAt = expires
                            }
                sendNotification (EmailVerificationRequested email raw expires)
                publishAuthEvent (Event.EmailVerificationRequested (Event.EmailVerificationRequestedData user.userId email ts))
    pure (Right ())

confirmEmailVerification ::
    ( VerificationTokenStore :> es
    , UserStore :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    ConfirmEmailVerification ->
    Eff es (Either AuthError ())
confirmEmailVerification _cfg cmd = runErrorNoCallStack do
    ts <- now
    h <- hashOneTimeToken cmd.token
    tok <- maybe (throwError VerificationTokenInvalid) pure =<< findVerificationTokenByHash h
    either throwError pure (ensureUsableVerification tok ts)
    user <- maybe (throwError VerificationTokenInvalid) pure =<< findUserById tok.userId
    -- A verification token only ever exists for an account that had an email; a missing
    -- email here means the token cannot belong to a verifiable account.
    email <- maybe (throwError VerificationTokenInvalid) pure user.email
    when (isJust user.emailVerifiedAt) (throwError EmailAlreadyVerified)
    markVerificationTokenConsumed tok.verificationTokenId ts
    markUserEmailVerified user.userId ts
    publishAuthEvent (Event.EmailVerified (Event.EmailVerifiedData user.userId email ts))

requestPasswordReset ::
    ( UserStore :> es
    , PasswordResetTokenStore :> es
    , Notifier :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    RequestPasswordReset ->
    Eff es (Either AuthError ())
requestPasswordReset cfg cmd = do
    ts <- now
    mUser <- findUserByEmail cmd.email
    forM_ mUser \user ->
        forM_ user.email \email ->
            when (user.status == UserActive) do
                let expires = addUTCTime cfg.notifierConfig.passwordResetTokenTTL ts
                (raw, h) <- generateOneTimeToken
                _ <-
                    createPasswordResetToken
                        NewPasswordResetToken
                            { userId = user.userId
                            , tokenHash = h
                            , createdAt = ts
                            , expiresAt = expires
                            }
                sendNotification (PasswordResetRequested email raw expires)
                publishAuthEvent (Event.PasswordResetRequested (Event.PasswordResetRequestedData user.userId email ts))
    pure (Right ())

confirmPasswordReset ::
    ( UserStore :> es
    , PasswordResetTokenStore :> es
    , CredentialStore :> es
    , PasswordHasher :> es
    , PasswordBreachChecker :> es
    , SessionStore :> es
    , RefreshTokenStore :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    ConfirmPasswordReset ->
    Eff es (Either AuthError ())
confirmPasswordReset cfg cmd = runErrorNoCallStack do
    ts <- now
    h <- hashOneTimeToken cmd.token
    tok <- maybe (throwError PasswordResetTokenInvalid) pure =<< findPasswordResetTokenByHash h
    either throwError pure (ensureUsableReset tok ts)
    user <- maybe (throwError PasswordResetTokenInvalid) pure =<< findUserById tok.userId
    let pwContext =
            PasswordContext
                { contextEmail = emailText <$> user.email
                , contextDisplayName = user.displayName
                }
    either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy pwContext cmd.newPassword)
    enforceBreachPolicy cfg.passwordPolicy cmd.newPassword
    newHash <- hashPassword cmd.newPassword
    updatePasswordHash tok.userId newHash
    markPasswordResetTokenConsumed tok.passwordResetTokenId ts
    revokeAllUserSessions tok.userId ts
    revokeAllUserRefreshTokens tok.userId ts
    publishAuthEvent (Event.PasswordResetCompleted (Event.PasswordResetCompletedData tok.userId ts))

changePassword ::
    ( UserStore :> es
    , CredentialStore :> es
    , PasswordHasher :> es
    , PasswordBreachChecker :> es
    , SessionStore :> es
    , RefreshTokenStore :> es
    , AuthEventPublisher :> es
    , Clock :> es
    ) =>
    ShomeiConfig ->
    ChangePassword ->
    Eff es (Either AuthError ())
changePassword cfg cmd = runErrorNoCallStack do
    user <- maybe (throwError InvalidCredentials) pure =<< findUserById cmd.userId
    let pwContext =
            PasswordContext
                { contextEmail = emailText <$> user.email
                , contextDisplayName = user.displayName
                }
    either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy pwContext cmd.newPassword)
    enforceBreachPolicy cfg.passwordPolicy cmd.newPassword
    cred <- maybe (throwError InvalidCredentials) pure =<< findPasswordCredentialByLoginId user.loginId
    ok <- verifyPassword cmd.currentPassword cred.passwordHash
    unless ok (throwError InvalidCredentials)
    ts <- now
    newHash <- hashPassword cmd.newPassword
    updatePasswordHash user.userId newHash
    revokeAllUserSessions user.userId ts
    revokeAllUserRefreshTokens user.userId ts
    publishAuthEvent (Event.PasswordChanged (Event.PasswordChangedData user.userId ts))

generateOneTimeToken :: (TokenGen :> es) => Eff es (OneTimeToken, OneTimeTokenHash)
generateOneTimeToken = do
    raw@(RefreshToken t) <- generateOpaqueToken
    RefreshTokenHash h <- hashRefreshToken raw
    pure (OneTimeToken t, OneTimeTokenHash h)

hashOneTimeToken :: (TokenGen :> es) => OneTimeToken -> Eff es OneTimeTokenHash
hashOneTimeToken (OneTimeToken t) = do
    RefreshTokenHash h <- hashRefreshToken (RefreshToken t)
    pure (OneTimeTokenHash h)

ensureUsableVerification :: PersistedVerificationToken -> UTCTime -> Either AuthError ()
ensureUsableVerification tok ts =
    if tok.status == OneTimeTokenActive && tok.expiresAt > ts
        then Right ()
        else Left VerificationTokenInvalid

ensureUsableReset :: PersistedPasswordResetToken -> UTCTime -> Either AuthError ()
ensureUsableReset tok ts =
    if tok.status == OneTimeTokenActive && tok.expiresAt > ts
        then Right ()
        else Left PasswordResetTokenInvalid
