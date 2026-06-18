-- | Pure conversions between Shōmei domain values and their stored text forms, shared by
-- the PostgreSQL port interpreters. Status enums are stored as @text@; the
-- 'Shomei.Domain.Email.Email' smart constructor is reused to rebuild an 'Email' from a
-- (trusted, already-normalized) database value.
module Shomei.Postgres.Codec
  ( userStatusToText,
    userStatusFromText,
    sessionStatusToText,
    sessionStatusFromText,
    refreshTokenStatusToText,
    refreshTokenStatusFromText,
    oneTimeTokenStatusToText,
    oneTimeTokenStatusFromText,
    signingKeyStatusToText,
    signingKeyStatusFromText,
    loginOutcomeToText,
    loginOutcomeFromText,
    emailFromDb,
    maybeEmailFromDb,
    loginIdFromDb,
    tshow,
  )
where

import Data.Text qualified as Text
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.LoginAttempt (LoginOutcome (..))
import Shomei.Domain.LoginId (LoginId, mkLoginId)
import Shomei.Domain.OneTimeToken (OneTimeTokenStatus (..))
import Shomei.Domain.RefreshToken (RefreshTokenStatus (..))
import Shomei.Domain.Session (SessionStatus (..))
import Shomei.Domain.SigningKey (SigningKeyStatus (..))
import Shomei.Domain.User (UserStatus (..))
import Shomei.Prelude

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

userStatusToText :: UserStatus -> Text
userStatusToText = \case
  UserActive -> "active"
  UserSuspended -> "suspended"
  UserDeleted -> "deleted"

userStatusFromText :: Text -> Either Text UserStatus
userStatusFromText = \case
  "active" -> Right UserActive
  "suspended" -> Right UserSuspended
  "deleted" -> Right UserDeleted
  t -> Left ("unknown user status: " <> t)

sessionStatusToText :: SessionStatus -> Text
sessionStatusToText = \case
  SessionActive -> "active"
  SessionRevoked -> "revoked"
  SessionExpired -> "expired"

sessionStatusFromText :: Text -> Either Text SessionStatus
sessionStatusFromText = \case
  "active" -> Right SessionActive
  "revoked" -> Right SessionRevoked
  "expired" -> Right SessionExpired
  t -> Left ("unknown session status: " <> t)

refreshTokenStatusToText :: RefreshTokenStatus -> Text
refreshTokenStatusToText = \case
  RefreshTokenActive -> "active"
  RefreshTokenUsed -> "used"
  RefreshTokenRevoked -> "revoked"
  RefreshTokenExpired -> "expired"

refreshTokenStatusFromText :: Text -> Either Text RefreshTokenStatus
refreshTokenStatusFromText = \case
  "active" -> Right RefreshTokenActive
  "used" -> Right RefreshTokenUsed
  "revoked" -> Right RefreshTokenRevoked
  "expired" -> Right RefreshTokenExpired
  t -> Left ("unknown refresh-token status: " <> t)

oneTimeTokenStatusToText :: OneTimeTokenStatus -> Text
oneTimeTokenStatusToText = \case
  OneTimeTokenActive -> "active"
  OneTimeTokenConsumed -> "consumed"
  OneTimeTokenRevoked -> "revoked"
  OneTimeTokenExpired -> "expired"

oneTimeTokenStatusFromText :: Text -> Either Text OneTimeTokenStatus
oneTimeTokenStatusFromText = \case
  "active" -> Right OneTimeTokenActive
  "consumed" -> Right OneTimeTokenConsumed
  "revoked" -> Right OneTimeTokenRevoked
  "expired" -> Right OneTimeTokenExpired
  t -> Left ("unknown one-time-token status: " <> t)

signingKeyStatusToText :: SigningKeyStatus -> Text
signingKeyStatusToText = \case
  KeyPending -> "pending"
  KeyActive -> "active"
  KeyRetired -> "retired"
  KeyRevoked -> "revoked"

signingKeyStatusFromText :: Text -> Either Text SigningKeyStatus
signingKeyStatusFromText = \case
  "pending" -> Right KeyPending
  "active" -> Right KeyActive
  "retired" -> Right KeyRetired
  "revoked" -> Right KeyRevoked
  t -> Left ("unknown signing-key status: " <> t)

loginOutcomeToText :: LoginOutcome -> Text
loginOutcomeToText = \case
  LoginSuccess -> "success"
  LoginFailure -> "failure"

loginOutcomeFromText :: Text -> Either Text LoginOutcome
loginOutcomeFromText = \case
  "success" -> Right LoginSuccess
  "failure" -> Right LoginFailure
  t -> Left ("unknown login outcome: " <> t)

-- | Rebuild an 'Email' from a stored value. The column only ever holds emails that were
-- already normalized through 'mkEmail' on the way in, so this should never fail; a 'Left'
-- here signals a corrupt row.
emailFromDb :: Text -> Either Text Email
emailFromDb t = case mkEmail t of
  Right e -> Right e
  Left _ -> Left ("invalid email in database: " <> t)

-- | Rebuild an optional 'Email' from a nullable stored value: a NULL column decodes to
-- 'Nothing', a present value is rebuilt through 'emailFromDb'.
maybeEmailFromDb :: Maybe Text -> Either Text (Maybe Email)
maybeEmailFromDb = traverse emailFromDb

-- | Rebuild a 'LoginId' from a stored value. The column only ever holds identifiers that
-- were already normalized through 'mkLoginId' on the way in, so this should never fail; a
-- 'Left' here signals a corrupt row.
loginIdFromDb :: Text -> Either Text LoginId
loginIdFromDb t = case mkLoginId t of
  Right l -> Right l
  Left _ -> Left ("invalid login id in database: " <> t)
