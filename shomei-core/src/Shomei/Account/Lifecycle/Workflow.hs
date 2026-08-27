-- | Account lifecycle workflows for email verification and password management.
module Shomei.Account.Lifecycle.Workflow
  ( RequestEmailVerification (..),
    ConfirmEmailVerification (..),
    RequestPasswordReset (..),
    ConfirmPasswordReset (..),
    ChangePassword (..),
    requestEmailVerification,
    confirmEmailVerification,
    requestPasswordReset,
    confirmPasswordReset,
    changePassword,
  )
where

import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Shomei.Account.Credential.Domain (Credential (..))
import Shomei.Account.Credential.Store (CredentialStore, findPasswordCredentialByLoginId)
import Shomei.Account.Email.Domain (Email, emailText)
import Shomei.Account.LoginId.Domain (loginIdText)
import Shomei.Account.Notification.Domain (Notification (..))
import Shomei.Account.Notification.Store (Notifier, sendNotification)
import Shomei.Account.OneTimeToken.Domain (OneTimeToken (..), OneTimeTokenHash (..), OneTimeTokenStatus (..))
import Shomei.Account.Password.Breach.Store (PasswordBreachChecker)
import Shomei.Account.Password.Breach.Workflow (enforceBreachPolicy)
import Shomei.Account.Password.Domain (PasswordContext (..), PlainPassword, validatePassword)
import Shomei.Account.Password.Hash.Store (PasswordHasher, hashPassword, verifyPassword, verifyPasswordDummy)
import Shomei.Account.PasswordReset.Domain (NewPasswordResetToken (..), PersistedPasswordResetToken (..))
import Shomei.Account.PasswordReset.Store
  ( PasswordResetTokenStore,
    createPasswordResetToken,
    findPasswordResetTokenByHash,
  )
import Shomei.Account.User.Domain (User (..), UserStatus (UserActive))
import Shomei.Account.User.Store (UserStore, findUserByEmail, findUserById, markUserEmailVerified)
import Shomei.Account.Verification.Domain (NewVerificationToken (..), PersistedVerificationToken (..))
import Shomei.Account.Verification.Store
  ( VerificationTokenStore,
    createVerificationToken,
    findVerificationTokenByHash,
    markVerificationTokenConsumed,
    revokeUserVerificationTokens,
  )
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Audit.Publisher.Store (AuthEventPublisher, publishAuthEvent)
import Shomei.Config (NotifierConfig (..), ShomeiConfig (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId)
import Shomei.Prelude
import Shomei.Session.Command (ProofContext, proofContextFor)
import Shomei.Session.LoginAttempt.Domain (AttemptFactor (FactorPasswordChange))
import Shomei.Session.LoginAttempt.Store (LoginAttemptStore)
import Shomei.Session.LoginAttempt.Workflow (AbuseGate (..), guardAbuse, recordProofFailure, recordProofSuccess)
import Shomei.Session.RefreshToken.Domain (RefreshToken (..), RefreshTokenHash (..))
import Shomei.Session.Token.Generator (TokenGen, generateOpaqueToken, hashRefreshToken)
import Shomei.Session.UnitOfWork.Store (AuthUnitOfWork, completePasswordChange, completePasswordReset)
import Shomei.Time.Store (Clock, now)

newtype RequestEmailVerification = RequestEmailVerification {email :: Email}
  deriving stock (Generic, Show)

newtype ConfirmEmailVerification = ConfirmEmailVerification {token :: OneTimeToken}
  deriving stock (Generic, Show)

newtype RequestPasswordReset = RequestPasswordReset {email :: Email}
  deriving stock (Generic, Show)

data ConfirmPasswordReset = ConfirmPasswordReset
  { token :: !OneTimeToken,
    newPassword :: !PlainPassword
  }
  deriving stock (Generic, Show)

data ChangePassword = ChangePassword
  { userId :: !UserId,
    currentPassword :: !PlainPassword,
    newPassword :: !PlainPassword
  }
  deriving stock (Generic, Show)

requestEmailVerification ::
  ( UserStore :> es,
    VerificationTokenStore :> es,
    Notifier :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    TokenGen :> es
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
              { userId = user.userId,
                tokenHash = h,
                createdAt = ts,
                expiresAt = expires
              }
        sendNotification (EmailVerificationRequested email raw expires)
        publishAuthEvent (Event.EmailVerificationRequested (Event.EmailVerificationRequestedData user.userId email ts))
  pure (Right ())

confirmEmailVerification ::
  ( VerificationTokenStore :> es,
    UserStore :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    TokenGen :> es
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
  -- Consume before acting: the compare-and-swap is the linearization point, so of two
  -- concurrent confirmations of one token exactly one proceeds. The loser sees precisely what
  -- a stale-token presenter sees.
  won <- markVerificationTokenConsumed tok.verificationTokenId ts
  unless won (throwError VerificationTokenInvalid)
  markUserEmailVerified user.userId ts
  revokeUserVerificationTokens user.userId ts
  publishAuthEvent (Event.EmailVerified (Event.EmailVerifiedData user.userId email ts))

requestPasswordReset ::
  ( UserStore :> es,
    PasswordResetTokenStore :> es,
    Notifier :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    TokenGen :> es
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
              { userId = user.userId,
                tokenHash = h,
                createdAt = ts,
                expiresAt = expires
              }
        sendNotification (PasswordResetRequested email raw expires)
        publishAuthEvent (Event.PasswordResetRequested (Event.PasswordResetRequestedData user.userId email ts))
  pure (Right ())

confirmPasswordReset ::
  ( UserStore :> es,
    PasswordResetTokenStore :> es,
    PasswordHasher :> es,
    PasswordBreachChecker :> es,
    AuthUnitOfWork :> es,
    Clock :> es,
    TokenGen :> es
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
          { contextEmail = emailText <$> user.email,
            contextDisplayName = user.displayName
          }
  either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy pwContext cmd.newPassword)
  enforceBreachPolicy cfg.passwordPolicy cmd.newPassword
  newHash <- hashPassword cmd.newPassword
  -- Consume before acting, but after validating the new password: the compare-and-swap is the
  -- linearization point (exactly one of two concurrent confirmations proceeds), while a
  -- pure-read policy check ahead of it cannot widen the race and spares the user's token when
  -- the new password is merely too weak.
  won <-
    completePasswordReset
      tok.passwordResetTokenId
      tok.userId
      newHash
      ts
      [Event.PasswordResetCompleted (Event.PasswordResetCompletedData tok.userId ts)]
  unless won (throwError PasswordResetTokenInvalid)

changePassword ::
  ( UserStore :> es,
    CredentialStore :> es,
    PasswordHasher :> es,
    PasswordBreachChecker :> es,
    AuthUnitOfWork :> es,
    AuthEventPublisher :> es,
    LoginAttemptStore :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  ProofContext ->
  ChangePassword ->
  Eff es (Either AuthError ())
changePassword cfg pctx cmd = runErrorNoCallStack do
  user <- maybe (throwError InvalidCredentials) pure =<< findUserById cmd.userId
  ts <- now
  let ctx = proofContextFor pctx (loginIdText user.loginId)
  gate <- guardAbuse cfg.rateLimitConfig ctx ts
  when gate.locked do
    verifyPasswordDummy cmd.currentPassword
    throwError InvalidCredentials
  let pwContext =
        PasswordContext
          { contextEmail = emailText <$> user.email,
            contextDisplayName = user.displayName
          }
  either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy pwContext cmd.newPassword)
  enforceBreachPolicy cfg.passwordPolicy cmd.newPassword
  cred <- maybe (throwError InvalidCredentials) pure =<< findPasswordCredentialByLoginId user.loginId
  ok <- verifyPassword cmd.currentPassword cred.passwordHash
  unless ok do
    recordProofFailure cfg.rateLimitConfig ctx FactorPasswordChange ts
    publishAuthEvent (Event.PasswordChangeFailed (Event.PasswordChangeFailedData user.userId ts))
    throwError InvalidCredentials
  recordProofSuccess ctx FactorPasswordChange gate.standingLockout ts
  newHash <- hashPassword cmd.newPassword
  completePasswordChange
    user.userId
    newHash
    ts
    [Event.PasswordChanged (Event.PasswordChangedData user.userId ts)]

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
